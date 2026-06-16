import SwiftUI

/// Settings sub-page for the new context-aware features.
///
/// **Design language**: matches Settings page — ScrollView, padding xl,
/// VStack spacing 20, every group in a `themedCard()` with the same
/// 14pt-semibold section title pattern.
struct DevModeSettingsView: View {
    var showsHeader: Bool = true
    var wrapsInScrollView: Bool = true
    var horizontalPadding: CGFloat = Theme.Space.xl
    var topPadding: CGFloat = Theme.Space.xl

    // Routing toggles — defaults match TransformerRouter.is*Enabled
    @AppStorage(TransformerRouter.Keys.devModeEnabled)
    var devModeEnabled: Bool = true

    @AppStorage(TransformerRouter.Keys.magicWordsEnabled)
    var magicWordsEnabled: Bool = true

    @AppStorage(TransformerRouter.Keys.variableRecognitionEnabled)
    var variableRecognitionEnabled: Bool = true

    @AppStorage(TransformerRouter.Keys.agenticModeEnabled)
    var agenticModeEnabled: Bool = false

    // Context capture
    @AppStorage(ContextProvider.Keys.contextCaptureEnabled)
    var contextCaptureEnabled: Bool = true

    @AppStorage(ContextProvider.Keys.clipboardSelectionEnabled)
    var clipboardSelectionEnabled: Bool = false

    @AppStorage(ContextProvider.Keys.persistSelectionEnabled)
    var persistSelectionEnabled: Bool = false

    @AppStorage(ContextProvider.Keys.screenshotContextEnabled)
    var screenshotContextEnabled: Bool = true

    // Trigger tester
    @State private var triggerInput: String = "vordi create insert mock rows for users table"
    @State private var probeOutput: String = ""

    var body: some View {
        if wrapsInScrollView {
            ScrollView {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showsHeader {
                header
            }
            routingCard
            contextCard
            triggerTesterCard
            probeCard
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Developer Mode")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundColor(Theme.textPrimary)
            Text("Voice-trigger code generation, context-aware profiles, and IDE-aware variable casing.")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Routing card

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Routing", subtitle: "What \(AppBrand.name) does with your dictation")

            toggleRow(
                title: "Enable Dev Mode triggers",
                subtitle: "Allow phrases like \"vordi create...\" and \"vordi prompt...\" to override polish.",
                isOn: $devModeEnabled,
                badge: nil
            )
            divider

            toggleRow(
                title: "Enable Magic Words",
                subtitle: "Match dictation against your saved phrase → expansion registry.",
                isOn: $magicWordsEnabled,
                badge: nil
            )
            divider

            toggleRow(
                title: "Variable recognition in IDEs",
                subtitle: "Convert \u{201C}snake case foo bar\u{201D} → foo_bar; backtick filenames in IDE chat.",
                isOn: $variableRecognitionEnabled,
                badge: nil,
                disabled: !devModeEnabled
            )
            divider

            toggleRow(
                title: "Agentic mode",
                subtitle: "Lets the LLM call internal tools when generating. Slower, occasionally smarter.",
                isOn: $agenticModeEnabled,
                badge: "EXPERIMENTAL",
                disabled: !devModeEnabled
            )
        }
        .themedCard()
    }

    // MARK: - Context capture card

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Context Capture", subtitle: "What \(AppBrand.name) knows about your screen")

            toggleRow(
                title: "Capture frontmost app at hotkey-press",
                subtitle: "Required for surface-aware features. Tracks bundle ID + app name only.",
                isOn: $contextCaptureEnabled
            )
            divider

            toggleRow(
                title: "Capture selection via clipboard fallback",
                subtitle: "Sends an extra Cmd+C to the focused app when accessibility selection fails. Pasteboard is preserved.",
                isOn: $clipboardSelectionEnabled,
                disabled: !contextCaptureEnabled
            )
            divider

            toggleRow(
                title: "Persist captured selection to Run Log",
                subtitle: "Off by default — selections often contain code or secrets.",
                isOn: $persistSelectionEnabled,
                disabled: !contextCaptureEnabled
            )
            divider

            toggleRow(
                title: "Capture screenshot for smart context",
                subtitle: "Uses Screen Recording and Groq Llama 4 Scout to summarize the active window for post-processing.",
                isOn: $screenshotContextEnabled,
                badge: "EXPERIMENTAL",
                disabled: !contextCaptureEnabled
            )
        }
        .themedCard()
    }

    // MARK: - Trigger tester

    private var triggerTesterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Trigger Tester", subtitle: "Preview which profile would handle a given utterance")

            ZStack(alignment: .topLeading) {
                if triggerInput.isEmpty {
                    Text("Type or paste a transcript…")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                TextEditor(text: $triggerInput)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 60)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Detected trigger", value: triggerLabel(for: triggerInput))
                infoRow("Stripped request", value: triggerStrippedDisplay)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
        }
        .themedCard()
    }

    private var triggerStrippedDisplay: String {
        let stripped = TriggerWords.strip(triggerInput)
        return stripped.isEmpty ? "(none)" : "\u{201C}\(stripped)\u{201D}"
    }

    // MARK: - Selection probe

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Selection Probe", subtitle: "Captures the AX selection from your currently-focused app")

            HStack(spacing: 10) {
                Button {
                    runProbe()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope").font(.system(size: 11, weight: .medium))
                        Text("Run probe").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .strokeBorder(Theme.dividerStrong, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .vfClickableCursor()

                Text("Click into another app first, then come back here and press.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            ScrollView {
                Text(probeOutput.isEmpty ? "(no probe run yet)" : probeOutput)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(Theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .fill(Theme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
        }
        .themedCard()
    }

    // MARK: - Building blocks

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        badge: String? = nil,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(disabled ? Theme.textTertiary : Theme.textPrimary)
                    if let badge = badge {
                        VFBadge(label: badge, style: badgeStyle(for: badge))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(disabled ? Theme.textTertiary.opacity(0.7) : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VFSwitch(isOn: isOn)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
    }

    private func badgeStyle(for badge: String) -> VFBadgeStyle {
        switch badge.uppercased() {
        case "EXPERIMENT", "EXPERIMENTAL":
            return .experimental
        case "BETA":
            return .feature
        default:
            return .plan
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11).monospaced())
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Divider().background(Theme.divider)
    }

    // MARK: - Logic

    private func triggerLabel(for transcript: String) -> String {
        if TriggerWords.isDevCreate(transcript) { return "vordi create → DeveloperModeProfile" }
        if TriggerWords.isPromptEngineer(transcript) { return "vordi prompt → PromptEngineerProfile" }
        if TriggerWords.isRewrite(transcript) { return "vordi rewrite → RewriteProfile" }
        return "(none — would route to standard cleanup)"
    }

    private func runProbe() {
        let snap = ContextProvider.shared.snapshot()
        let lines: [String] = [
            "frontmost_bundle_id : \(snap.frontmostBundleID ?? "(nil)")",
            "frontmost_app_name  : \(snap.frontmostAppName ?? "(nil)")",
            "surface             : \(snap.surface.rawValue)",
            "selection_source    : \(snap.selectionSource.rawValue)",
            "selection_chars     : \(snap.selection.count)",
            "selection           : \(snap.selection.isEmpty ? "(empty)" : String(snap.selection.prefix(200)))",
            "captured_at         : \(snap.capturedAt)",
        ]
        probeOutput = lines.joined(separator: "\n")
    }
}
