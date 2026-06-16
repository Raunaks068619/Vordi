import SwiftUI
import AppKit

/// Memory tab — Obsidian-style force-directed graph of entities extracted
/// from the user's transcriptions, plus a chat panel that answers
/// questions over those transcripts (RAG-style).
///
/// **Layout**: 60/40 horizontal split — graph canvas on the left, chat
/// panel on the right. The split is fixed (not user-resizable) at this
/// stage; if users push for it we can graduate to NSSplitView.
///
/// **Force simulation**: pure-Swift Verlet-ish integration ticking at
/// ~30Hz via TimelineView. Repulsion is Coulomb (1/r²), attraction on
/// connected nodes is Hooke (linear in displacement from rest length).
/// No external dependencies — Grape and similar packages would be nicer
/// but pull in 200KB+ for a feature most users will explore once.
///
/// **Performance budget**: 30Hz × O(n²) repulsion = fine through ~150
/// nodes. Beyond that we'd need spatial partitioning. Insights tab math
/// suggests typical users land at 30-80 nodes so we don't optimize
/// pre-emptively.
struct KnowledgeGraphView: View {
    private static let graphFrameRate: TimeInterval = 1.0 / 18.0

    @StateObject private var service = KnowledgeGraphService.shared
    @StateObject private var simulation = ForceSimulation()

    /// Chat panel state. Lives in the view (not the service) because
    /// chat history is session-only — the graph itself is persisted
    /// to disk but the conversation isn't.
    @State private var chatInput: String = ""
    @State private var chatHistory: [KnowledgeChatTurn] = []
    @State private var isAsking: Bool = false
    @State private var pendingAskError: String?

    /// Optional highlight for nodes belonging to the same runs as the
    /// most recent assistant turn. Lets the user see "these are the
    /// memories I used to answer" in the graph.
    @State private var highlightedRunIDs: Set<String> = []
    @State private var selectedNodeID: String?
    @State private var sourcePopoverTurnID: UUID?

    /// Pan offset for the graph canvas. Reset on double-click.
    @State private var pan: CGSize = .zero
    @GestureState private var dragPan: CGSize = .zero

    /// Pinch/scroll zoom. Bounded to a sane range so the graph never
    /// disappears off-screen or becomes pixel-mush.
    @State private var zoom: CGFloat = 1.0

    /// Which node, if any, is currently being dragged by the user. Used
    /// to suppress the canvas pan gesture during node drag — without
    /// this both gestures fight for the same finger movement and the
    /// node lurches alongside the entire view.
    @State private var activeDragNodeID: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            graphPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            chatPane
                .frame(width: 380)
                .frame(maxHeight: .infinity)
        }
        .background(Theme.mainContent)
        .task {
            service.reload()
            simulation.sync(with: service.graph)
        }
        .onChange(of: service.graph.nodes.count) { _ in
            simulation.sync(with: service.graph)
        }
    }

    // MARK: - Graph pane

    private var graphPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            graphHeader
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.lg)

            ZStack(alignment: .topLeading) {
                if service.graph.nodes.isEmpty {
                    emptyGraph
                } else {
                    graphCanvas
                    legendOverlay
                        .padding(Theme.Space.md)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
    }

    /// Floating legend over the graph canvas. Lists only the entity
    /// types that actually appear in the current graph, so we don't
    /// confuse the user with "place" when no places are present.
    private var legendOverlay: some View {
        let typesPresent = Set(service.graph.nodes.map { $0.type })
        let ordered = KnowledgeEntityType.allCases.filter { typesPresent.contains($0) }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(ordered, id: \.self) { type in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: type.rgb.0, green: type.rgb.1, blue: type.rgb.2))
                        .frame(width: 8, height: 8)
                    Text(legendLabel(for: type))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 0.5)
        )
        // Don't intercept gestures — purely decorative. Without this
        // the legend would steal pan-gesture events from the canvas.
        .allowsHitTesting(false)
    }

    private func legendLabel(for type: KnowledgeEntityType) -> String {
        switch type {
        case .person:   return "People"
        case .project:  return "Projects"
        case .tool:     return "Tools"
        case .concept:  return "Concepts"
        case .command:  return "Commands"
        case .place:    return "Places"
        case .other:    return "Other"
        }
    }

    private var graphHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                Text("Memory")
                    .font(.vfPageTitle)
                    .foregroundColor(Theme.textPrimary)
                VFBadge(label: "Local", style: .plan)
                if service.graph.isDisplayLimited {
                    VFBadge(
                        label: "Top \(service.graph.nodes.count) of \(service.graph.totalNodeCount)",
                        style: .plan
                    )
                    .help("The graph renders the highest-signal entities for performance. Search and Ask Memory still use the full Memory corpus.")
                }
                Spacer()
                syncControl
            }
        }
    }

    /// Manual sync keeps expensive Memory work out of launch and dictation.
    @ViewBuilder
    private var syncControl: some View {
        HStack(spacing: 10) {
            switch service.indexerStatus {
            case .idle:
                if service.pendingSyncCount > 0 {
                    Text("\(service.pendingSyncCount) unsynced")
                        .font(.vfCaption)
                        .foregroundColor(Theme.textSecondary)
                }
            case .migrating(let progress):
                ProgressView().controlSize(.small)
                Text("Migrating \(Int(progress * 100))%")
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
            case .indexing(let done, let total):
                ProgressView().controlSize(.small)
                Text("Indexing \(done)/\(total)")
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
            case .error(let message):
                Text(message)
                    .font(.vfCaption)
                    .foregroundColor(Theme.warning)
                    .lineLimit(1)
                    .help(message)
            }

            VFButton(title: "Sync", icon: "arrow.triangle.2.circlepath", style: .secondary, isCompact: true, isLoading: service.isIndexing) {
                Task {
                    await service.syncNow()
                    simulation.sync(with: service.graph)
                }
            }
            .disabled(service.isIndexing)
            .help("Update Memory from saved transcriptions")
        }
    }

    private var emptyGraph: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.cross")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.textSecondary)
            Text(service.isIndexing ? "Building your graph…" : "No graph yet")
                .font(.vfBodyMedium)
                .foregroundColor(Theme.textPrimary)
            Text(service.isIndexing
                 ? "Extracting entities from your transcripts."
                 : "Click Sync after dictating to build Memory on demand.")
                .font(.vfCallout)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .error(let msg) = service.indexerStatus {
                Text("Last error: \(msg)")
                    .font(.vfMicro)
                    .foregroundColor(Theme.warning)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // Background — covers the rounded-card frame AND
                // serves as the pan/zoom hit target. Sits at the back
                // of the ZStack so per-node drag overlays receive
                // events first (SwiftUI hit-tests top-down).
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .gesture(panGesture, including: activeDragNodeID == nil ? .all : .subviews)
                    .onTapGesture(count: 2) {
                        pan = .zero
                        zoom = 1.0
                    }

                // Canvas draws edges + nodes + labels every frame.
                // `allowsHitTesting(false)` so it never blocks the
                // per-node drag overlays layered on top.
                TimelineView(.animation(minimumInterval: Self.graphFrameRate, paused: false)) { _ in
                    Canvas { ctx, _ in
                        simulation.tick(in: size)
                        drawEdges(in: ctx, size: size)
                        drawNodes(in: ctx, size: size)
                    }
                }
                .allowsHitTesting(false)

                // Per-node drag pads. Larger hit area (min 32pt) so
                // the slim 6pt nodes are easy to grab. Gesture is
                // `.highPriorityGesture` so it wins races against
                // the canvas pan gesture below.
                ForEach(simulation.bodies, id: \.id) { body in
                    let p = displayPoint(body.position, size: size)
                    let hit: CGFloat = max(32, body.radius * 2 + 18)
                    Circle()
                        .fill(Color.white.opacity(0.001)) // hit-testable but invisible
                        .frame(width: hit, height: hit)
                        .position(p)
                        .onHover { hovering in
                            simulation.setHover(body.id, hovering: hovering)
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { v in
                                    if activeDragNodeID != body.id {
                                        activeDragNodeID = body.id
                                        simulation.beginDrag(body.id)
                                    }
                                    // Convert display-space drag back to
                                    // simulation-space (cancel pan + zoom).
                                    let target = CGPoint(
                                        x: body.position.x + v.translation.width  / zoom,
                                        y: body.position.y + v.translation.height / zoom
                                    )
                                    simulation.dragTo(body.id, point: target)
                                }
                                .onEnded { v in
                                    let moved = hypot(v.translation.width, v.translation.height)
                                    simulation.endDrag(body.id)
                                    activeDragNodeID = nil
                                    if moved < 4 {
                                        selectedNodeID = body.id
                                    }
                                }
                        )
                        .popover(
                            isPresented: Binding(
                                get: { selectedNodeID == body.id },
                                set: { isPresented in
                                    if !isPresented { selectedNodeID = nil }
                                }
                            ),
                            arrowEdge: .top
                        ) {
                            nodeSummaryPopover(nodeID: body.id)
                        }
                        .help(tooltipFor(body.id))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            // Scroll-wheel zoom. Trackpad pinch arrives as a
            // .magnification gesture on macOS — handle that too.
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = max(0.4, min(2.5, value))
                    }
            )
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragPan) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan.width  += value.translation.width
                pan.height += value.translation.height
            }
    }

    private func displayPoint(_ p: CGPoint, size: CGSize) -> CGPoint {
        // Simulation runs in raw coords centered around `size/2`. Display
        // pipeline: re-center → apply zoom around center → apply pan.
        let cx = size.width  / 2
        let cy = size.height / 2
        let zoomedX = (p.x - cx) * zoom + cx
        let zoomedY = (p.y - cy) * zoom + cy
        return CGPoint(
            x: zoomedX + pan.width  + dragPan.width,
            y: zoomedY + pan.height + dragPan.height
        )
    }

    private func drawEdges(in ctx: GraphicsContext, size: CGSize) {
        for edge in simulation.edges {
            guard
                let a = simulation.body(for: edge.nodeA),
                let b = simulation.body(for: edge.nodeB)
            else { continue }
            var path = Path()
            path.move(to: displayPoint(a.position, size: size))
            path.addLine(to: displayPoint(b.position, size: size))

            let highlighted = a.isHovered || b.isHovered
            let baseOpacity = min(0.18 + Double(edge.weight) * 0.06, 0.55)
            let opacity = highlighted ? min(baseOpacity + 0.3, 0.9) : baseOpacity
            let lineWidth = highlighted
                ? 1.6
                : (1.0 + min(Double(edge.weight - 1), 3) * 0.25)
            ctx.stroke(
                path,
                with: .color(Theme.textPrimary.opacity(opacity)),
                lineWidth: lineWidth
            )
        }
    }

    private func drawNodes(in ctx: GraphicsContext, size: CGSize) {
        for (index, body) in simulation.bodies.enumerated() {
            let p = displayPoint(body.position, size: size)
            let (r, g, b) = body.colorRGB
            let fill = Color(red: r, green: g, blue: b)

            // Node circle. Hovered or run-highlighted nodes get a
            // brighter ring + larger glow.
            let highlighted = body.isHovered || isRunHighlighted(body.runIDs)
            // Apply zoom to the rendered radius so nodes scale with
            // the rest of the layout. Floor at 8pt so they stay
            // grabbable at any zoom level.
            let baseRadius = body.radius * (highlighted ? 1.18 : 1.0)
            let radius = max(8, baseRadius * zoom)
            let rect = CGRect(
                x: p.x - radius,
                y: p.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            // Soft glow halo on highlighted nodes.
            if highlighted {
                let glowRect = rect.insetBy(dx: -6, dy: -6)
                ctx.fill(Path(ellipseIn: glowRect), with: .color(fill.opacity(0.22)))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(highlighted ? 0.9 : 0.55)),
                lineWidth: highlighted ? 1.6 : 1.0
            )

            if shouldDrawLabel(for: body, at: index, highlighted: highlighted) {
                drawLabel(body.label, highlighted: highlighted, at: p, radius: radius, in: ctx)
            }
        }
    }

    private func shouldDrawLabel(for body: ForceSimulation.Body, at index: Int, highlighted: Bool) -> Bool {
        // Always label every node. The graph is meant to look full; labels
        // shrink with zoom (see drawLabel) so a dense, zoomed-out view stays
        // legible rather than hiding the long tail of nodes.
        return true
    }

    private func drawLabel(_ label: String, highlighted: Bool, at point: CGPoint, radius: CGFloat, in ctx: GraphicsContext) {
        // Scale label text with zoom so a full, zoomed-out graph shrinks its
        // labels (less overlap) while zooming in makes them readable. Clamped
        // so they never vanish or balloon. Highlighted/hovered labels get a
        // small bump and always render at a comfortably readable floor.
        let fontSize = max(highlighted ? 9 : 6.5, min(13, 11 * zoom))
        let labelText = Text(label)
            .font(.system(size: fontSize, weight: highlighted ? .semibold : .medium))
            .foregroundColor(Theme.textPrimary)
        let labelAt = CGPoint(x: point.x, y: point.y + radius + fontSize * 0.5 + 5)
        let resolved = ctx.resolve(labelText)
        let textSize = resolved.measure(in: CGSize(width: 200, height: 40))
        let padX: CGFloat = max(3, fontSize * 0.5)
        let padY: CGFloat = 2
        let pillRect = CGRect(
            x: labelAt.x - textSize.width / 2 - padX,
            y: labelAt.y - textSize.height / 2 - padY,
            width: textSize.width + padX * 2,
            height: textSize.height + padY * 2
        )
        let pillPath = Path(roundedRect: pillRect, cornerRadius: 4)
        ctx.fill(pillPath, with: .color(Theme.surface.opacity(0.92)))
        ctx.stroke(
            pillPath,
            with: .color(Theme.divider),
            lineWidth: 0.5
        )
        ctx.draw(resolved, at: labelAt, anchor: .center)
    }

    private func isRunHighlighted(_ runIDs: [String]) -> Bool {
        guard !highlightedRunIDs.isEmpty else { return false }
        return runIDs.contains(where: highlightedRunIDs.contains)
    }

    private func tooltipFor(_ nodeID: String) -> String {
        guard let body = simulation.body(for: nodeID) else { return "" }
        return "\(body.label) · \(body.mentions) mention\(body.mentions == 1 ? "" : "s")"
    }

    // MARK: - Chat pane

    private var chatPane: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Memory")
                    .font(.vfBodyMedium)
                    .foregroundColor(Theme.textPrimary)
                Text("Questions about your past transcriptions.")
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)

            Divider()

            // History
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chatHistory.isEmpty {
                            chatEmptyHints
                        } else {
                            ForEach(chatHistory) { turn in
                                chatBubble(turn)
                                    .id(turn.id)
                            }
                        }
                        if isAsking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Searching your memories…")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .padding(.horizontal, Theme.Space.lg)
                        }
                        if let err = pendingAskError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.warning)
                                .padding(.horizontal, Theme.Space.lg)
                        }
                    }
                    .padding(.vertical, Theme.Space.md)
                }
                .onChange(of: chatHistory.count) { _ in
                    if let last = chatHistory.last {
                        withAnimation { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 8) {
                TextField("Ask anything about what you've dictated…",
                          text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(.vfCallout)
                    .vfInputChrome()
                    .onSubmit { submitChat() }

                Button(action: submitChat) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? Theme.textTertiary
                                      : Theme.textPrimary)
                        )
                }
                .buttonStyle(.plain)
                .vfClickableCursor()
                .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.canvas)
    }

    private var chatEmptyHints: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                hintChip("What was I working on last week?")
                hintChip("Summarize my recent transcripts on Kubernetes.")
                hintChip("Have I mentioned any blockers?")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
    }

    private func hintChip(_ text: String) -> some View {
        Button(action: {
            chatInput = text
            submitChat()
        }) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .vfClickableCursor()
    }

    private func chatBubble(_ turn: KnowledgeChatTurn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if turn.role == .assistant {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(Theme.secondaryButtonFill)
                    )
                    .padding(.top, 2)
            } else {
                Spacer(minLength: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                MemoryMarkdownText(text: turn.text)
                if turn.role == .assistant && !turn.sourceRunIDs.isEmpty {
                    Button {
                        sourcePopoverTurnID = turn.id
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(turn.sourceRunIDs.count) source\(turn.sourceRunIDs.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .vfClickableCursor()
                    .foregroundColor(Theme.textSecondary)
                    .help("Show transcripts used for this answer")
                    .popover(
                        isPresented: Binding(
                            get: { sourcePopoverTurnID == turn.id },
                            set: { isPresented in
                                if !isPresented { sourcePopoverTurnID = nil }
                            }
                        ),
                        arrowEdge: .bottom
                    ) {
                        KnowledgeSourcesPopover(
                            title: "\(turn.sourceRunIDs.count) source\(turn.sourceRunIDs.count == 1 ? "" : "s")",
                            sources: service.sourcePreviews(for: turn.sourceRunIDs)
                        )
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(turn.role == .assistant ? Theme.surface : Theme.secondaryButtonFill.opacity(0.72))
            )

            if turn.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.canvas))
                    .padding(.top, 2)
            } else {
                Spacer(minLength: 24)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
    }

    @ViewBuilder
    private func nodeSummaryPopover(nodeID: String) -> some View {
        if let summary = service.nodeSummary(for: nodeID) {
            KnowledgeNodeSummaryPopover(summary: summary)
        } else {
            Text("No details available.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .padding(14)
        }
    }

    // MARK: - Chat actions

    private func submitChat() {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return }

        let priorConversation = chatHistory
        let userTurn = KnowledgeChatTurn(role: .user, text: trimmed)
        chatHistory.append(userTurn)
        chatInput = ""
        pendingAskError = nil
        isAsking = true

        Task {
            do {
                let answer = try await service.ask(trimmed, conversation: priorConversation)
                await MainActor.run {
                    chatHistory.append(answer)
                    highlightedRunIDs = Set(answer.sourceRunIDs)
                    isAsking = false
                }
            } catch {
                await MainActor.run {
                    let desc = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                    pendingAskError = "Couldn't get an answer: \(desc)"
                    isAsking = false
                }
            }
        }
    }
}

// MARK: - Memory popovers + Markdown

private struct MemoryMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer(minLength: 4)
                } else if let heading = headingText(from: line) {
                    Text(Self.attributed(heading))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.attributed(line))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    private func headingText(from line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let stripped = line.drop { $0 == "#" || $0 == " " }
        return stripped.isEmpty ? nil : String(stripped)
    }

    private static func attributed(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

private struct KnowledgeNodeSummaryPopover: View {
    let summary: KnowledgeNodeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(Color(red: summary.type.rgb.0, green: summary.type.rgb.1, blue: summary.type.rgb.2))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("\(typeLabel(summary.type)) · \(summary.mentions) mention\(summary.mentions == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }

            if !summary.connectedLabels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected to")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    ConnectedChipList(items: summary.connectedLabels)
                }
            }

            Divider().background(Theme.divider)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent sources")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if summary.sources.isEmpty {
                    Text("No source preview available.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    ForEach(summary.sources) { source in
                        KnowledgeSourcePreviewRow(source: source)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.canvas)
    }
}

private struct KnowledgeSourcesPopover: View {
    let title: String
    let sources: [KnowledgeSourcePreview]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("Memory sources")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }

            if sources.isEmpty {
                Text("No memory sources found for this answer.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sources) { source in
                            KnowledgeSourcePreviewRow(source: source)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.canvas)
    }
}

private struct KnowledgeSourcePreviewRow: View {
    let source: KnowledgeSourcePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(source.sourceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.secondaryButtonFill))
                Text(Self.dateFormatter.string(from: source.createdAt))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if let context = sourceContext, !context.isEmpty {
                    Text(context)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(source.wordCount)w")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
            if let title = source.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(source.text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private var sourceContext: String? {
        source.folderDisplayName ?? source.appName ?? source.profile
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}

private struct ConnectedChipList: View {
    let items: [String]

    var body: some View {
        ConnectedChipFlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.surfaceElevated))
                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectedChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (size, _) = computeLayout(maxWidth: maxWidth, subviews: subviews)
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let (_, placements) = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, point) in placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func computeLayout(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> (CGSize, [CGPoint]) {
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        var placements: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }

            let x = rowWidth == 0 ? 0 : rowWidth + spacing
            placements.append(CGPoint(x: x, y: totalHeight))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }

        widest = max(widest, rowWidth)
        return (CGSize(width: widest, height: totalHeight + rowHeight), placements)
    }
}

private func typeLabel(_ type: KnowledgeEntityType) -> String {
    switch type {
    case .person: return "Person"
    case .project: return "Project"
    case .tool: return "Tool"
    case .concept: return "Concept"
    case .command: return "Command"
    case .place: return "Place"
    case .other: return "Entity"
    }
}

// MARK: - Force simulation

/// Minimal 2D physics for an interactive node-link diagram. Verlet-ish
/// integration with three forces: Coulomb repulsion, Hooke spring
/// attraction on connected pairs, and a weak center pull to keep the
/// graph bounded inside the canvas.
///
/// Why I wrote it from scratch instead of pulling in a SwiftPM dep:
///   - 80 lines of math, zero shared state with the rest of the app.
///   - No SwiftPM resolver changes on every clean build.
///   - We own the trade-offs: stiffer springs for clusters, weaker
///     repulsion for dense subgraphs, etc.
///
/// Tuning knobs live as private constants and are documented inline so a
/// future contributor can tweak without re-deriving the math.
@MainActor
final class ForceSimulation: ObservableObject {
    /// One body in the simulation. Mirrors a KnowledgeNode plus mutable
    /// physics state (position, velocity).
    struct Body: Identifiable {
        let id: String
        var label: String
        var position: CGPoint
        var velocity: CGVector
        var radius: CGFloat
        var mentions: Int
        var colorRGB: (Double, Double, Double)
        var runIDs: [String]
        var isHovered: Bool = false
        var isPinned: Bool = false   // user is dragging
    }

    private(set) var bodies: [Body] = []
    private(set) var edges: [KnowledgeEdge] = []
    private var bodyIndex: [String: Int] = [:]
    private var lastTickAt: CFAbsoluteTime = 0

    // MARK: Tuning

    /// Strength of pairwise repulsion. Higher = nodes spread further.
    private let repulsionStrength: CGFloat = 4500
    /// Spring rest length for one-weight edges. Scales DOWN with weight
    /// (heavier edges pull tighter).
    private let springRestLength: CGFloat = 110
    /// Spring stiffness. Higher = snappier attraction.
    private let springStiffness: CGFloat = 0.04
    /// Center-pulling strength. Keeps the graph from drifting off-screen.
    private let centerStrength: CGFloat = 0.012
    /// Velocity decay per tick. Anything > 0.92 keeps wobble going for
    /// too long; < 0.85 looks dead.
    private let damping: CGFloat = 0.88
    /// Max velocity per axis — caps explosions when a fresh graph
    /// settles into shape on the first few ticks.
    private let maxVelocity: CGFloat = 14

    // MARK: Sync with service

    /// Reconcile bodies with the latest graph snapshot. New nodes get a
    /// random initial position near the center; nodes that disappeared
    /// from the graph are removed.
    func sync(with graph: KnowledgeGraph) {
        var newBodies: [Body] = []
        var newIndex: [String: Int] = [:]
        for (i, node) in graph.nodes.enumerated() {
            if let existingIdx = bodyIndex[node.id] {
                // Preserve current position so a refresh doesn't shuffle
                // the user's mental map.
                var existing = bodies[existingIdx]
                existing.label = node.label
                existing.mentions = node.mentions
                existing.radius = Self.radius(forMentions: node.mentions)
                existing.colorRGB = node.type.rgb
                existing.runIDs = node.runIDs
                newBodies.append(existing)
            } else {
                let angle = Double(i) / max(1, Double(graph.nodes.count)) * .pi * 2
                let r: CGFloat = 90
                let pos = CGPoint(
                    x: CGFloat(cos(angle)) * r + 200,
                    y: CGFloat(sin(angle)) * r + 200
                )
                newBodies.append(Body(
                    id: node.id,
                    label: node.label,
                    position: pos,
                    velocity: .zero,
                    radius: Self.radius(forMentions: node.mentions),
                    mentions: node.mentions,
                    colorRGB: node.type.rgb,
                    runIDs: node.runIDs
                ))
            }
            newIndex[node.id] = newBodies.count - 1
        }
        bodies = newBodies
        bodyIndex = newIndex
        edges = graph.edges
    }

    func body(for id: String) -> Body? {
        guard let idx = bodyIndex[id] else { return nil }
        return bodies[idx]
    }

    // MARK: Interaction

    func setHover(_ id: String, hovering: Bool) {
        guard let idx = bodyIndex[id] else { return }
        bodies[idx].isHovered = hovering
    }

    func beginDrag(_ id: String) {
        guard let idx = bodyIndex[id] else { return }
        bodies[idx].isPinned = true
    }

    func dragTo(_ id: String, point: CGPoint) {
        guard let idx = bodyIndex[id] else { return }
        bodies[idx].position = point
        bodies[idx].velocity = .zero
    }

    func endDrag(_ id: String) {
        guard let idx = bodyIndex[id] else { return }
        bodies[idx].isPinned = false
    }

    // MARK: Tick

    /// Advance the simulation by one frame. Called from the Canvas's
    /// TimelineView at ~30Hz. `size` is the canvas size — we use its
    /// center for the centering force.
    func tick(in size: CGSize) {
        guard !bodies.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Bound dt so a pause/resume doesn't blow positions to infinity.
        let dt: CGFloat = lastTickAt == 0 ? 0.033 : CGFloat(min(0.05, now - lastTickAt))
        lastTickAt = now

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // 1. Compute force accumulator per body. Done in a separate pass
        // so the integration step sees consistent state.
        var forces = [CGVector](repeating: .zero, count: bodies.count)

        // Repulsion — O(n²) but n is small (<150 in practice).
        for i in 0..<bodies.count {
            for j in (i + 1)..<bodies.count {
                let pi = bodies[i].position
                let pj = bodies[j].position
                var dx = pi.x - pj.x
                var dy = pi.y - pj.y
                var dist2 = dx * dx + dy * dy
                if dist2 < 0.01 {
                    // Identical positions blow up 1/r². Nudge apart.
                    dx = CGFloat.random(in: -1...1)
                    dy = CGFloat.random(in: -1...1)
                    dist2 = dx * dx + dy * dy
                }
                let dist = sqrt(dist2)
                let force = repulsionStrength / dist2
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[i].dx += fx
                forces[i].dy += fy
                forces[j].dx -= fx
                forces[j].dy -= fy
            }
        }

        // Spring attraction along edges.
        for edge in edges {
            guard
                let i = bodyIndex[edge.nodeA],
                let j = bodyIndex[edge.nodeB]
            else { continue }
            let pa = bodies[i].position
            let pb = bodies[j].position
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let dist = max(sqrt(dx * dx + dy * dy), 0.001)
            // Rest length shrinks as weight grows. Cap at 60pt so heavy
            // co-occurrences don't collapse onto each other.
            let rest = max(60, springRestLength - CGFloat(edge.weight - 1) * 12)
            let displacement = dist - rest
            let force = springStiffness * displacement
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force
            forces[i].dx += fx
            forces[i].dy += fy
            forces[j].dx -= fx
            forces[j].dy -= fy
        }

        // Center pull.
        for i in 0..<bodies.count {
            let p = bodies[i].position
            forces[i].dx += (center.x - p.x) * centerStrength
            forces[i].dy += (center.y - p.y) * centerStrength
        }

        // 2. Integrate. Pinned bodies (currently being dragged) skip the
        // velocity step so the user's pointer is authoritative.
        for i in 0..<bodies.count {
            if bodies[i].isPinned {
                bodies[i].velocity = .zero
                continue
            }
            var vx = (bodies[i].velocity.dx + forces[i].dx * dt) * damping
            var vy = (bodies[i].velocity.dy + forces[i].dy * dt) * damping
            // Clamp velocity to prevent first-frame explosions.
            vx = max(-maxVelocity, min(maxVelocity, vx))
            vy = max(-maxVelocity, min(maxVelocity, vy))
            bodies[i].velocity = CGVector(dx: vx, dy: vy)
            bodies[i].position.x += vx
            bodies[i].position.y += vy
        }

        // Re-publish so Canvas redraws. We mutate `bodies` directly
        // without an ObservableObject change here because the Canvas
        // is in a TimelineView that redraws every tick anyway.
    }

    private static func radius(forMentions mentions: Int) -> CGFloat {
        // Logarithmic scaling so a few high-mention nodes don't dominate.
        // Base bumped 6 → 9 in v0.5.1: a 6pt dot at 1.0 zoom is barely
        // visible and hard to grab. 9pt reads cleanly and stays
        // grabbable down to ~0.5 zoom (where it renders as ~5pt).
        let base: CGFloat = 9
        return base + min(14, CGFloat(log(Double(max(1, mentions))) * 4))
    }
}
