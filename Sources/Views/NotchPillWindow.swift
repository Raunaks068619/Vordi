import AppKit
import Combine
import QuartzCore
import SwiftUI

enum NotchPillState: Equatable {
    case idle
    case proximity
    case listening
    case thinking
    case done
    case handsFree
    case errorMini(message: String)
    case panelHover
    case panelTranscript(text: String)
    case panelError(title: String, desc: String, tip: String)
}

final class NotchPillModel: ObservableObject {
    @Published var state: NotchPillState = .idle
    @Published var audioLevel: Float = 0
    @Published var hasAllPermissions: Bool = true
    @Published var hardwareNotchSize: CGSize = NotchPillScreenGeometry.fallbackNotchSize
    @Published var liveTranscript: String = ""

    var lastError: (title: String, desc: String, tip: String)?
}

enum NotchPillScreenGeometry {
    static let fallbackNotchSize = CGSize(width: 162, height: 32)
    static let surfaceHeightExtension: CGFloat = 4
    static let defaultVisibleExpansion: CGFloat = 63
    static let maxSurfaceWidth: CGFloat = 420
    static let transcriptStripHeight: CGFloat = 30
    static let expandedPanelHeight: CGFloat = 164
    static let transcriptRevealWordCount = 3
    static let morphDuration: TimeInterval = 0.20

    private static let lanePadding: CGFloat = 10
    private static let statusTrailingPadding: CGFloat = 18
    private static let stateWidthBreathingRoom: CGFloat = 8
    private static let notchMarkWidth: CGFloat = 14
    private static let statusSpacing: CGFloat = 6
    private static let statusFontSize: CGFloat = 10
    private static let recordingMeterWidth: CGFloat = 38
    private static let thinkingDotsWidth: CGFloat = 24
    private static let doneTickWidth: CGFloat = 18
    private static let pulseWidth: CGFloat = 8

    static func notchFrame(on screen: NSScreen) -> CGRect? {
        if #available(macOS 12.0, *),
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let notchWidth = rightArea.minX - leftArea.maxX
            if notchWidth > 0 {
                return CGRect(
                    x: leftArea.maxX,
                    y: min(leftArea.minY, rightArea.minY),
                    width: notchWidth,
                    height: max(leftArea.height, rightArea.height)
                )
            }
        }

        return nil
    }

    static func detect(on screen: NSScreen) -> CGSize {
        notchFrame(on: screen)?.size ?? fallbackNotchSize
    }

    static func anchorX(on screen: NSScreen) -> CGFloat {
        screen.frame.midX
    }

    static func hasHardwareNotch(on screen: NSScreen) -> Bool {
        notchFrame(on: screen) != nil
    }

    static func defaultSurfaceSize(for notchSize: CGSize) -> CGSize {
        let defaultPillWidth = max(248, notchSize.width + defaultVisibleExpansion)
        return CGSize(
            width: defaultPillWidth + 20,
            height: notchSize.height + surfaceHeightExtension
        )
    }

    static func surfaceSize(
        state: NotchPillState,
        notchSize: CGSize,
        liveTranscript: String
    ) -> CGSize {
        let rowHeight = notchSize.height + surfaceHeightExtension
        let defaultPillWidth = max(248, notchSize.width + defaultVisibleExpansion)
        let pillWidth = pillWidth(
            state: state,
            notchWidth: notchSize.width,
            defaultPillWidth: defaultPillWidth
        )
        let width = min(maxSurfaceWidth, pillWidth + backgroundSideExpansion(for: state) * 2)
        let height = rowHeight
            + inlineTranscriptHeight(state: state, liveTranscript: liveTranscript)
            + expandedPanelHeightValue(for: state)

        return CGSize(width: ceil(width), height: ceil(height))
    }

    private static func pillWidth(
        state: NotchPillState,
        notchWidth: CGFloat,
        defaultPillWidth: CGFloat
    ) -> CGFloat {
        switch state {
        case .idle, .proximity:
            return defaultPillWidth
        default:
            let leftContentWidth = lanePadding
                + notchMarkWidth
                + statusSpacing
                + measuredStatusTextWidth(statusLabel(for: state))
                + statusTrailingPadding
            let laneWidth = max(leftContentWidth, rightContentWidth(for: state)) + stateWidthBreathingRoom
            return max(defaultPillWidth, ceil(notchWidth + laneWidth * 2))
        }
    }

    private static func backgroundSideExpansion(for state: NotchPillState) -> CGFloat {
        switch state {
        case .idle, .proximity:
            return 10
        case .thinking:
            return 18
        case .listening, .handsFree, .panelTranscript:
            return 20
        case .done:
            return 18
        case .errorMini, .panelHover, .panelError:
            return 16
        }
    }

    private static func inlineTranscriptHeight(state: NotchPillState, liveTranscript: String) -> CGFloat {
        switch state {
        case .listening, .handsFree, .panelTranscript:
            let wordCount = liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .count
            return wordCount >= transcriptRevealWordCount ? transcriptStripHeight : 0
        default:
            return 0
        }
    }

    private static func expandedPanelHeightValue(for state: NotchPillState) -> CGFloat {
        if case .panelHover = state { return expandedPanelHeight }
        return 0
    }

    private static func rightContentWidth(for state: NotchPillState) -> CGFloat {
        switch state {
        case .listening, .handsFree, .panelTranscript:
            return lanePadding + recordingMeterWidth
        case .thinking:
            return lanePadding + thinkingDotsWidth
        case .done:
            return lanePadding + doneTickWidth
        default:
            return lanePadding + pulseWidth
        }
    }

    private static func statusLabel(for state: NotchPillState) -> String {
        switch state {
        case .listening, .panelTranscript:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .done:
            return "Done"
        case .handsFree:
            return "Hands free"
        case .errorMini(let message):
            return compactErrorLabel(for: message)
        case .panelError(let title, _, _):
            return compactErrorLabel(for: title)
        case .panelHover:
            return "VoiceFlow"
        case .idle, .proximity:
            return "Ready"
        }
    }

    private static func compactErrorLabel(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("microphone") || lower.contains("permission") {
            return "Permissions"
        }
        if lower.contains("input") {
            return "No input"
        }
        if lower.contains("audio") {
            return "No audio"
        }
        return "No output"
    }

    private static func measuredStatusTextWidth(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: statusFontSize, weight: .regular)
        return ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }
}

final class NotchPillHostingView: NSHostingView<NotchPillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPillCanvasView: NSView {
    weak var model: NotchPillModel?
    var onHoverChanged: ((Bool) -> Void)?

    init(frame frameRect: NSRect, model: NotchPillModel) {
        self.model = model
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

}

final class NotchPillWindow: NSPanel {
    let model = NotchPillModel()

    private static let minimumAudioUpdateInterval: TimeInterval = 1.0 / 20.0
    private static let hoverPanelClosePollInterval: TimeInterval = 1.0 / 30.0
    private static let hoverRegionOutset: CGFloat = 2

    private var cancellables = Set<AnyCancellable>()
    private var flashTimer: Timer?
    private var hoverPanelCloseTimer: Timer?
    private var lastAudioLevelUpdate: Date = .distantPast
    private weak var anchoredScreen: NSScreen?
    private weak var canvasView: NotchPillCanvasView?

    init() {
        let initialSize = NotchPillScreenGeometry.defaultSurfaceSize(
            for: NotchPillScreenGeometry.fallbackNotchSize
        )

        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = NSSize(width: 20, height: 24)
        contentMinSize = NSSize(width: 20, height: 24)

        let hosting = NotchPillHostingView(rootView: NotchPillView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        hosting.autoresizingMask = [.width, .height]

        let canvas = NotchPillCanvasView(frame: NSRect(origin: .zero, size: initialSize), model: model)
        canvas.autoresizingMask = [.width, .height]
        canvas.addSubview(hosting)
        canvas.onHoverChanged = { [weak self] hovering in
            self?.handleCanvasHover(hovering)
        }

        contentView = canvas
        canvasView = canvas
        setContentSize(initialSize)
        observeSurfaceBounds()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reposition(animated: false)
            self.alphaValue = 1
            self.orderFrontRegardless()
            self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.orderOut(nil)
        }
    }

    func setRecording() {
        setState(.listening, resetAudio: true, clearTranscript: true)
    }

    func setProcessing() {
        setState(.thinking)
    }

    func setDone() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashTimer?.invalidate()
            self.model.state = .done
            self.model.audioLevel = 0
            self.model.liveTranscript = ""
            self.flashTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.model.state = .idle
            }
        }
    }

    func setIdle() {
        DispatchQueue.main.async { [weak self] in
            self?.flashTimer?.invalidate()
            self?.model.state = .idle
            self?.model.audioLevel = 0
            self?.model.liveTranscript = ""
            self?.lastAudioLevelUpdate = .distantPast
        }
    }

    func setHandsFree() {
        setState(.handsFree)
    }

    func setHandsFreeExitedAnimating() {
        setState(.thinking)
    }

    func setPermissionsAvailable(_ available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.hasAllPermissions != available else { return }
            self.model.hasAllPermissions = available
        }
    }

    func flashPermissionsWarning(durationSeconds: Double = 5.0) {
        flash(
            message: "Microphone access denied - check System Settings",
            title: "Microphone access denied",
            desc: "VoiceFlow needs microphone access to listen. Grant access in System Settings > Privacy.",
            tip: "Go to System Settings > Privacy & Security > Microphone and enable VoiceFlow.",
            durationSeconds: durationSeconds
        )
    }

    func flashNoInputWarning(durationSeconds: Double = 4.5) {
        flash(
            message: "No input field detected - use Cmd+V to paste",
            title: "No input field detected",
            desc: "VoiceFlow couldn't find an active text field. Use Cmd+V to paste the transcription manually.",
            tip: "Click into any text field first, then hold Fn to dictate directly into it.",
            durationSeconds: durationSeconds
        ) {
            NotificationCenter.default.post(
                name: Notification.Name("VoiceFlow.DismissChipWarning"),
                object: nil
            )
        }
    }

    func flashNoAudioWarning(durationSeconds: Double = 3.0) {
        flash(
            message: "No audio detected - adjust mic sensitivity in Settings",
            title: "No audio detected",
            desc: "No voice was captured during the Fn hold. The noise gate may be too aggressive.",
            tip: "Increase mic sensitivity in Settings > Microphone Sensitivity.",
            durationSeconds: durationSeconds
        )
    }

    func flashNoOutputWarning(durationSeconds: Double = 4.0) {
        flash(
            message: "No output was generated - check the logs",
            title: "No output was generated",
            desc: "The flow ran but produced no text output. This may be a flow configuration issue.",
            tip: "Open the run logs to inspect which step failed or returned empty.",
            durationSeconds: durationSeconds
        )
    }

    func updateAudioLevel(_ level: Float) {
        if Thread.isMainThread {
            applyAudioLevel(level)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyAudioLevel(level)
            }
        }
    }

    private func setState(
        _ state: NotchPillState,
        resetAudio: Bool = false,
        clearTranscript: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.flashTimer?.invalidate()
            self?.model.state = state
            if resetAudio {
                self?.model.audioLevel = 0
                self?.lastAudioLevelUpdate = .distantPast
            }
            if clearTranscript {
                self?.model.liveTranscript = ""
            }
        }
    }

    private func applyAudioLevel(_ level: Float) {
        let normalizedLevel = min(max(level, 0), 1)
        let now = Date()
        let levelDelta = abs(normalizedLevel - model.audioLevel)
        guard
            now.timeIntervalSince(lastAudioLevelUpdate) >= Self.minimumAudioUpdateInterval
                || levelDelta > 0.35
        else {
            return
        }

        lastAudioLevelUpdate = now
        model.audioLevel = normalizedLevel
    }

    private func flash(
        message: String,
        title: String,
        desc: String,
        tip: String,
        durationSeconds: Double,
        onDismiss: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashTimer?.invalidate()
            self.model.lastError = (title: title, desc: desc, tip: tip)
            self.model.state = .errorMini(message: message)
            self.model.audioLevel = 0
            self.flashTimer = Timer.scheduledTimer(withTimeInterval: durationSeconds, repeats: false) { [weak self] _ in
                guard let self, case .errorMini = self.model.state else { return }
                self.model.state = .idle
                onDismiss?()
            }
        }
    }

    private func reposition(animated: Bool = true) {
        let screen = preferredScreen()
        guard let screen else { return }

        anchoredScreen = screen
        model.hardwareNotchSize = NotchPillScreenGeometry.detect(on: screen)

        applyFrame(on: screen, animated: animated)
    }

    private func observeSurfaceBounds() {
        Publishers.Merge3(
            model.$state.map { _ in () }.eraseToAnyPublisher(),
            model.$hardwareNotchSize.map { _ in () }.eraseToAnyPublisher(),
            model.$liveTranscript.map { _ in () }.eraseToAnyPublisher()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizeToCurrentSurface()
                self?.syncHoverPanelCloseMonitor()
            }
            .store(in: &cancellables)
    }

    private func applyFrame(on providedScreen: NSScreen? = nil) {
        applyFrame(on: providedScreen, animated: true)
    }

    private func applyFrame(on providedScreen: NSScreen? = nil, animated: Bool) {
        let screen = providedScreen
            ?? anchoredScreen
            ?? preferredScreen()
        guard let screen else { return }

        anchoredScreen = screen
        let windowSize = currentSurfaceSize()
        let targetFrame = surfaceFrame(for: windowSize, on: screen)

        guard animated, isVisible, frame != targetFrame else {
            contentView?.frame = NSRect(origin: .zero, size: windowSize)
            setFrame(targetFrame, display: true)
            canvasView?.updateTrackingAreas()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NotchPillScreenGeometry.morphDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            self.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.contentView?.frame = NSRect(origin: .zero, size: windowSize)
            self?.canvasView?.updateTrackingAreas()
        }
    }

    private func preferredScreen() -> NSScreen? {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        return screenWithHardwareNotch(containing: NSEvent.mouseLocation)
            ?? mouseScreen.flatMap { NotchPillScreenGeometry.hasHardwareNotch(on: $0) ? $0 : nil }
            ?? NSScreen.screens.first(where: NotchPillScreenGeometry.hasHardwareNotch)
            ?? mouseScreen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenWithHardwareNotch(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first {
            NSMouseInRect(point, $0.frame, false)
                && NotchPillScreenGeometry.hasHardwareNotch(on: $0)
        }
    }

    private func handleCanvasHover(_ hovering: Bool) {
        if hovering {
            switch model.state {
            case .idle, .proximity:
                openHoverPanelIfMouseInside()
            default:
                break
            }
        } else {
            if case .panelHover = model.state {
                guard !isMouseInsideHoverRegion(for: .panelHover) else { return }
                model.state = .idle
            } else {
                guard !isMouseInsideHoverRegion(for: model.state) else { return }
            }
        }
    }

    private func openHoverPanelIfMouseInside() {
        guard isMouseInsideHoverRegion(for: model.state) else { return }
        model.state = .panelHover
    }

    private func syncHoverPanelCloseMonitor() {
        if case .panelHover = model.state {
            startHoverPanelCloseMonitor()
        } else {
            stopHoverPanelCloseMonitor()
        }
    }

    private func startHoverPanelCloseMonitor() {
        guard hoverPanelCloseTimer == nil else { return }

        let timer = Timer(timeInterval: Self.hoverPanelClosePollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard case .panelHover = self.model.state else {
                self.stopHoverPanelCloseMonitor()
                return
            }

            if !self.isMouseInsideHoverRegion(for: .panelHover) {
                self.model.state = .idle
                self.stopHoverPanelCloseMonitor()
            }
        }

        hoverPanelCloseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoverPanelCloseMonitor() {
        hoverPanelCloseTimer?.invalidate()
        hoverPanelCloseTimer = nil
    }

    private func isMouseInsideHoverRegion(for state: NotchPillState) -> Bool {
        let screen = anchoredScreen ?? preferredScreen()
        guard let screen else { return false }

        let size = NotchPillScreenGeometry.surfaceSize(
            state: state,
            notchSize: model.hardwareNotchSize,
            liveTranscript: model.liveTranscript
        )
        let hoverFrame = surfaceFrame(for: size, on: screen)
            .insetBy(dx: -Self.hoverRegionOutset, dy: -Self.hoverRegionOutset)

        return hoverFrame.contains(NSEvent.mouseLocation)
    }

    private func surfaceFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let x = NotchPillScreenGeometry.anchorX(on: screen) - size.width / 2
        let y = screen.frame.maxY - size.height + 2
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func resizeToCurrentSurface() {
        applyFrame()
    }

    private func currentSurfaceSize() -> NSSize {
        NotchPillScreenGeometry.surfaceSize(
            state: model.state,
            notchSize: model.hardwareNotchSize,
            liveTranscript: model.liveTranscript
        )
    }

    deinit {
        hoverPanelCloseTimer?.invalidate()
        flashTimer?.invalidate()
    }
}
