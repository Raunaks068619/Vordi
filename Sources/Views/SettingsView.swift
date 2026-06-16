import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @ObservedObject var permissionService: PermissionService
    @StateObject private var localDetector = LocalModelDetector.shared
    @State private var apiKey: String = ""
    @State private var groqApiKey: String = ""
    @State private var provider: String = TranscriptionProvider.openai.rawValue
    @State private var selectedLanguage: String = "hi"
    @State private var outputMode: String = TranscriptOutputStyle.cleanHinglish.rawValue
    @State private var processingMode: String = TranscriptProcessingMode.dictation.rawValue
    @State private var polishBackendId: String = PolishBackend.defaultId
    @State private var noiseGateThreshold: Double = 0.015
    @State private var runLogEnabled: Bool = true
    @State private var runLogCapped: Bool = true
    @State private var feedbackSurfaceStyle: String = FeedbackSurfaceStyle.current.rawValue
    @State private var showSaveConfirmation = false

    /// Cloud polish-model options. `gpt-4.1-nano` is included as an escape
    /// hatch — it's cheaper and empirically less eager to answer questions
    /// than `gpt-4.1-mini`, at the cost of slightly worse Hinglish.
    private let cloudPolishOptions: [(id: String, label: String)] = [
        ("openai::gpt-4.1-mini", "OpenAI · gpt-4.1-mini (default)"),
        ("openai::gpt-4.1-nano", "OpenAI · gpt-4.1-nano (cheaper, stronger role adherence)"),
        (PolishBackend.defaultIdGroq, "Groq · Llama 4 Scout (vision context)")
    ]

    /// Computed dropdown options: cloud first, then discovered local models.
    /// Local models appear only when a server (LM Studio / Ollama) is running
    /// — graceful degradation on no detection.
    private var polishOptions: [(id: String, label: String)] {
        var opts = cloudPolishOptions
        for model in localDetector.models {
            opts.append((model.id, "\(model.provider.label) · \(model.name)"))
        }
        return opts
    }

    let providers = [
        (TranscriptionProvider.openai.rawValue, "OpenAI (Paid · GPT-4 Polish)"),
        (TranscriptionProvider.groq.rawValue, "Groq (Free · Multilingual)")
    ]
    
    let languages = [
        ("hi", "Hindi"),
        ("en", "English"),
        ("auto", "Auto-detect")
    ]

    let outputModes = [
        (TranscriptOutputStyle.verbatim.rawValue, "Original"),
        (TranscriptOutputStyle.cleanHinglish.rawValue, "English output"),
        (TranscriptOutputStyle.translateEnglish.rawValue, "Translate")
    ]

    let processingModes = [
        (TranscriptProcessingMode.dictation.rawValue, "Polish"),
        (TranscriptProcessingMode.rewrite.rawValue, "Rewrite"),
        (TranscriptProcessingMode.promptEngineer.rawValue, "Prompt")
    ]
    
    var body: some View {
        Form {
            Section("Transcription Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(providers, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Text("Both providers support multilingual transcription. Groq is free; OpenAI offers GPT-4 post-processing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Feedback Surface") {
                Picker("Style", selection: $feedbackSurfaceStyle) {
                    ForEach(FeedbackSurfaceStyle.allCases, id: \.self) { style in
                        Label(style.title, systemImage: style.icon)
                            .tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text((FeedbackSurfaceStyle(rawValue: feedbackSurfaceStyle) ?? .dynamicNotch).subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API Key")
                        .font(.headline)

                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Get your API key from openai.com/api-keys")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groq API Key")
                        .font(.headline)

                    SecureField("gsk_...", text: $groqApiKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Free tier: console.groq.com/keys — multilingual supported.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Language") {
                Picker("Transcription Language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .pickerStyle(.segmented)
                
                Text("Select 'Auto-detect' to automatically identify the language")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("About") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(AppBrand.name) v1.0.0")
                        .font(.headline)
                    Text("Voice typing app powered by OpenAI Whisper")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Output Quality") {
                Picker("Text Style", selection: $outputMode) {
                    ForEach(outputModes, id: \.0) { mode, label in
                        Text(label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Romanized writes any spoken language (Hindi, Marathi, etc.) in English letters. English translates everything to English.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Post-Processing Model") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Polish model", selection: $polishBackendId) {
                        ForEach(polishOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            localDetector.detect()
                        } label: {
                            if localDetector.isDetecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Refresh local models")
                            }
                        }
                        .disabled(localDetector.isDetecting)

                        if localDetector.models.isEmpty {
                            Text("No local servers detected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(localDetector.models.count) local model\(localDetector.models.count == 1 ? "" : "s") detected")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    Text("Local models (LM Studio on :1234, Ollama on :11434) run on your machine — no network, no API cost. Start your server, hit Refresh, then pick it above.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Hint when user is on a local model but server might be down
                    if polishBackendId.hasPrefix("lmstudio::") || polishBackendId.hasPrefix("ollama::") {
                        if !polishOptions.contains(where: { $0.id == polishBackendId }) {
                            Text("⚠️ Selected local model is not currently detected. Dictation will fail until you start the server and refresh.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Transcription Mode") {
                Picker("Mode", selection: $processingMode) {
                    ForEach(processingModes, id: \.0) { mode, label in
                        Text(label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose one default transform: Polish, Rewrite, or Prompt Engineer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Run Log") {
                VStack(alignment: .leading, spacing: 8) {
                    VFToggle(label: "Keep run history", isOn: $runLogEnabled)
                    VFToggle(label: "Cap at 20 runs", isOn: $runLogCapped)
                        .disabled(!runLogEnabled)
                        .opacity(runLogEnabled ? 1 : 0.45)
                    Text(runLogCaptionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Microphone Filter") {
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: $noiseGateThreshold, in: 0.001...0.05, step: 0.001)
                    Text("Sensitivity: \(String(format: "%.3f", noiseGateThreshold)) (higher filters more background noise)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Permission Health") {
                if let warning = permissionService.environmentWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                permissionRow(
                    title: "Microphone",
                    state: permissionService.microphoneState,
                    onRequest: { permissionService.requestMicrophoneAccess() },
                    onOpenSettings: { permissionService.openPrivacyPane(.microphone) }
                )
                permissionRow(
                    title: "Accessibility",
                    state: permissionService.accessibilityState,
                    onRequest: { permissionService.requestAccessibilityAccess() },
                    onOpenSettings: { permissionService.openPrivacyPane(.accessibility) }
                )
                permissionRow(
                    title: "Input Monitoring",
                    state: permissionService.inputMonitoringState,
                    onRequest: { permissionService.requestInputMonitoringAccess() },
                    onOpenSettings: { permissionService.openPrivacyPane(.inputMonitoring) }
                )
                permissionRow(
                    title: "Screen Recording",
                    state: permissionService.screenRecordingState,
                    onRequest: { permissionService.requestScreenRecordingAccess() },
                    onOpenSettings: { permissionService.openPrivacyPane(.screenRecording) }
                )

                if !permissionService.allRequiredGranted {
                    Text("Global hotkeys will not work until required permissions are granted.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Button("Re-check permissions") {
                    permissionService.refreshStatus()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 460)
        .padding()
        .onAppear {
            loadSettings()
            permissionService.refreshStatus()
            // Kick off a local-model probe on every Settings open. Cheap (1.5s
            // timeout per provider, runs in parallel) and keeps the picker fresh.
            localDetector.detect()
        }
        .onChange(of: apiKey) { _ in
            saveSettings()
        }
        .onChange(of: groqApiKey) { _ in
            saveSettings()
        }
        .onChange(of: provider) { _ in
            saveSettings()
        }
        .onChange(of: selectedLanguage) { _ in
            saveSettings()
        }
        .onChange(of: outputMode) { _ in
            saveSettings()
        }
        .onChange(of: processingMode) { _ in
            saveSettings()
        }
        .onChange(of: polishBackendId) { _ in
            saveSettings()
        }
        .onChange(of: noiseGateThreshold) { _ in
            saveSettings()
        }
        .onChange(of: runLogEnabled) { _ in
            saveSettings()
        }
        .onChange(of: runLogCapped) { newValue in
            saveSettings()
            // Toggling the cap ON with an over-cap history should feel
            // immediate. Without this, the list would keep showing the
            // extra runs until the next dictation triggered a save().
            if newValue {
                RunStore.shared.applyCap()
            }
        }
        .onChange(of: feedbackSurfaceStyle) { _ in
            saveSettings()
            NotificationCenter.default.post(name: .voiceFlowFeedbackSurfaceStyleChanged, object: nil)
        }
    }

    /// Contextual caption under the Run Log toggles — explains what the
    /// current combination of switches actually does. More useful than a
    /// static string, and cheap to compute.
    private var runLogCaptionText: String {
        if !runLogEnabled {
            return "Run history is off. No audio, transcripts, or prompts are saved to disk."
        }
        if runLogCapped {
            return "Saves audio, transcripts, and prompts locally. Oldest entries are pruned after 20 runs."
        }
        return "Saves audio, transcripts, and prompts locally. No cap — history grows until you clear it manually."
    }
    
    private func loadSettings() {
        apiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
        groqApiKey = UserDefaults.standard.string(forKey: "groq_api_key") ?? ""
        provider = UserDefaults.standard.string(forKey: "transcription_provider") ?? TranscriptionProvider.openai.rawValue
        selectedLanguage = UserDefaults.standard.string(forKey: "language") ?? "hi"
        let storedOutputMode = UserDefaults.standard.string(forKey: "output_mode") ?? TranscriptOutputStyle.cleanHinglish.rawValue
        outputMode = storedOutputMode == TranscriptOutputStyle.clean.rawValue ? TranscriptOutputStyle.translateEnglish.rawValue : storedOutputMode
        processingMode = UserDefaults.standard.string(forKey: "processing_mode") ?? TranscriptProcessingMode.dictation.rawValue
        let storedPolishBackend = UserDefaults.standard.string(forKey: PolishBackend.userDefaultsKey) ?? PolishBackend.defaultId
        polishBackendId = PolishBackend.legacyGroqModelIds.contains(storedPolishBackend)
            ? PolishBackend.defaultIdGroq
            : storedPolishBackend
        let storedThreshold = UserDefaults.standard.double(forKey: "noise_gate_threshold")
        noiseGateThreshold = storedThreshold == 0 ? 0.015 : storedThreshold
        if UserDefaults.standard.object(forKey: "run_log_enabled") != nil {
            runLogEnabled = UserDefaults.standard.bool(forKey: "run_log_enabled")
        } else {
            runLogEnabled = true
        }
        if UserDefaults.standard.object(forKey: "run_log_cap_enabled") != nil {
            runLogCapped = UserDefaults.standard.bool(forKey: "run_log_cap_enabled")
        } else {
            runLogCapped = true
        }
        feedbackSurfaceStyle = FeedbackSurfaceStyle.current.rawValue
    }

    private func saveSettings() {
        UserDefaults.standard.set(apiKey, forKey: "openai_api_key")
        UserDefaults.standard.set(groqApiKey, forKey: "groq_api_key")
        UserDefaults.standard.set(provider, forKey: "transcription_provider")
        UserDefaults.standard.set(selectedLanguage, forKey: "language")
        UserDefaults.standard.set(outputMode, forKey: "output_mode")
        UserDefaults.standard.set(processingMode, forKey: "processing_mode")
        UserDefaults.standard.set(polishBackendId, forKey: PolishBackend.userDefaultsKey)
        UserDefaults.standard.set(noiseGateThreshold, forKey: "noise_gate_threshold")
        UserDefaults.standard.set(runLogEnabled, forKey: "run_log_enabled")
        UserDefaults.standard.set(runLogCapped, forKey: "run_log_cap_enabled")
        UserDefaults.standard.set(feedbackSurfaceStyle, forKey: FeedbackSurfaceStyle.userDefaultsKey)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        state: PermissionState,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            permissionBadge(ok: state.isGranted)
            Button("Request") {
                onRequest()
            }
            Button("Open Settings") {
                onOpenSettings()
            }
        }
    }

    @ViewBuilder
    private func permissionBadge(ok: Bool) -> some View {
        Text(ok ? "Granted" : "Missing")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ok ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundColor(ok ? .green : .orange)
            .clipShape(Capsule())
    }
}

// MARK: - Onboarding Wizard

/// Four-step onboarding flow. First value is a real dictation test, not a
/// separate tutorial mode.
enum OnboardingStep: Int, CaseIterable {
    case features, permissions, preferences, test

    var title: String {
        switch self {
        case .features:    return "Features"
        case .permissions: return "Permissions"
        case .preferences: return "Preferences"
        case .test:        return "Test"
        }
    }
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var currentStep: OnboardingStep

    init(initialStep: OnboardingStep = .features) {
        self.currentStep = initialStep
    }

    func advance() {
        let next = OnboardingStep(rawValue: currentStep.rawValue + 1)
        if let next {
            withAnimation(.easeInOut(duration: 0.22)) { currentStep = next }
        }
    }

    func back() {
        let prev = OnboardingStep(rawValue: currentStep.rawValue - 1)
        if let prev {
            withAnimation(.easeInOut(duration: 0.22)) { currentStep = prev }
        }
    }

    var isFirstStep: Bool { currentStep == .features }
    var isLastStep:  Bool { currentStep == .test }
}

struct OnboardingView: View {
    static let windowSize = NSSize(width: 780, height: 680)

    @ObservedObject var permissionService: PermissionService
    var initialStep: OnboardingStep = .features
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    @StateObject private var coordinator: OnboardingCoordinator
    @ObservedObject private var runStore = RunStore.shared

    init(
        permissionService: PermissionService,
        initialStep: OnboardingStep = .features,
        onOpenSettings: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.permissionService = permissionService
        self.initialStep = initialStep
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        _coordinator = StateObject(wrappedValue: OnboardingCoordinator(initialStep: initialStep))
    }

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .padding(.horizontal, Theme.Layout.contentHPad)
                .padding(.top, Theme.Layout.contentVPad)
                .padding(.bottom, Theme.Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VFDivider(inset: 0)
            navBar
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Theme.canvas)
        .preferredColorScheme(ThemeManager.shared.colorScheme)
        .tint(Theme.textPrimary)
        .onAppear {
            permissionService.refreshStatus()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.currentStep {
        case .features:
            OnboardingFeaturesStep()
        case .permissions:
            OnboardingPermissionsStep(permissionService: permissionService)
        case .preferences:
            OnboardingPreferencesStep()
        case .test:
            OnboardingTestStep(runStore: runStore)
        }
    }

    private var navBar: some View {
        HStack(spacing: Theme.Space.sm) {
            if !coordinator.isFirstStep {
                VFButton(
                    title: "Back",
                    icon: "chevron.left",
                    style: .ghost,
                    isCompact: true
                ) {
                    coordinator.back()
                }
            }

            Spacer()
            compactStepper
            Spacer()

            if !coordinator.isFirstStep && !coordinator.isLastStep {
                VFButton(title: "Skip", style: .ghost, isCompact: true) {
                    coordinator.advance()
                }
            }

            VFButton(
                title: coordinator.isLastStep ? "Finish setup" : "Next",
                icon: coordinator.isLastStep ? "checkmark" : "arrow.right",
                style: .primary
            ) {
                if coordinator.isLastStep {
                    UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
                    onDone()
                } else {
                    coordinator.advance()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Layout.contentHPad)
        .padding(.vertical, Theme.Space.md)
        .background(Theme.mainContent)
    }

    private var compactStepper: some View {
        HStack(spacing: Theme.Space.sm) {
            HStack(spacing: 4) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= coordinator.currentStep.rawValue
                              ? Theme.textPrimary
                              : Theme.dividerStrong)
                        .frame(width: step == coordinator.currentStep ? 18 : 8, height: 3)
                }
            }

            Text("\(coordinator.currentStep.rawValue + 1)/\(OnboardingStep.allCases.count)")
                .font(.vfCaption)
                .foregroundColor(Theme.textSecondary)

            Text(coordinator.currentStep.title)
                .font(.vfCaption)
                .foregroundColor(Theme.textPrimary)
        }
        .frame(minWidth: 156)
    }
}

// MARK: - Shared onboarding components

private struct OnboardingStepHeader: View {
    let eyebrow: String
    let title: String
    let copy: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(eyebrow.uppercased())
                .font(.vfCategoryLabel)
                .foregroundColor(Theme.textTertiary)
                .tracking(0.5)
            Text(title)
                .font(.vfSectionTitle)
                .foregroundColor(Theme.textPrimary)
            Text(copy)
                .font(.vfCallout)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

private struct OnboardingSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }
}

private struct OnboardingFeatureItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let copy: String
}

private struct OnboardingChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String?
}

// MARK: - Step 1: Features

private struct OnboardingFeaturesStep: View {
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 1),
        GridItem(.flexible(minimum: 0), spacing: 1)
    ]

    private let features: [OnboardingFeatureItem] = [
        .init(id: "dictate", icon: "keyboard", title: "Dictate anywhere", copy: "Hold fn, speak, release. Text lands in the app you were using."),
        .init(id: "rewrite", icon: "sparkles", title: "Rewrite polish", copy: "Clean grammar, punctuation, structure, and filler words automatically."),
        .init(id: "magic", icon: "wand.and.stars", title: "Magic Words", copy: "Speak short commands that transform, retry, or route your text."),
        .init(id: "snippets", icon: "text.quote", title: "Snippets", copy: "Drop repeated replies, templates, and phrases without typing them again."),
        .init(id: "vocabulary", icon: "book.closed", title: "Custom vocabulary", copy: "Teach names, brands, and technical words so they survive transcription."),
        .init(id: "runlog", icon: "clock.arrow.circlepath", title: "Run Log", copy: "Recover previous dictations and see what happened during each run."),
        .init(id: "memory", icon: "brain.head.profile", title: "Memory", copy: "Use saved context to make repeated writing patterns feel consistent."),
        .init(id: "insights", icon: "chart.bar", title: "Insights", copy: "Track words, pace, and usage so the tool improves with your habits.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            OnboardingStepHeader(
                eyebrow: "Page 1",
                title: "Everything Vordi gives you.",
                copy: "This is the product surface you are setting up. The next pages only collect the pieces required to make these features work on macOS."
            )

            OnboardingSurface {
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(features) { feature in
                        featureCell(feature)
                    }
                }
                .background(Theme.divider)
            }

            HStack(spacing: Theme.Space.sm) {
                HotkeyBadge(label: "fn")
                Text("is the default trigger. You can change it later in Settings.")
                    .font(.vfCaption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    private func featureCell(_ feature: OnboardingFeatureItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: feature.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.RadiusExtra.sm, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.vfCalloutSemibold)
                    .foregroundColor(Theme.textPrimary)
                Text(feature.copy)
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.surface)
    }
}

// MARK: - Step 2: Permissions

private struct OnboardingPermissionsStep: View {
    @ObservedObject var permissionService: PermissionService

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: Theme.Space.md),
        GridItem(.flexible(minimum: 0), spacing: Theme.Space.md)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            OnboardingStepHeader(
                eyebrow: "Page 2",
                title: "Grant only what macOS requires.",
                copy: "Vordi needs microphone, typing, hotkey detection, and screen context permissions. Each tile shows the current system state."
            )

            if let warning = permissionService.environmentWarning {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.warning)
                    Text(warning)
                        .font(.vfCallout)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                        .fill(Theme.warning.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                        .strokeBorder(Theme.warning.opacity(0.25), lineWidth: 1)
                )
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.md) {
                permissionTile(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "Hear your voice while dictating.",
                    state: permissionService.microphoneState,
                    pane: .microphone,
                    request: { permissionService.requestMicrophoneAccess() }
                )
                permissionTile(
                    icon: "keyboard.fill",
                    title: "Accessibility",
                    subtitle: "Insert the transcript into other apps.",
                    state: permissionService.accessibilityState,
                    pane: .accessibility,
                    request: { permissionService.requestAccessibilityAccess() }
                )
                permissionTile(
                    icon: "command",
                    title: "Input Monitoring",
                    subtitle: "Detect the fn trigger reliably.",
                    state: permissionService.inputMonitoringState,
                    pane: .inputMonitoring,
                    request: { permissionService.requestInputMonitoringAccess() }
                )
                permissionTile(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    subtitle: "Attach the active window as context.",
                    state: permissionService.screenRecordingState,
                    pane: .screenRecording,
                    request: { permissionService.requestScreenRecordingAccess() }
                )
            }

            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: permissionService.allOnboardingPermissionsGranted ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(permissionService.allOnboardingPermissionsGranted ? Theme.success : Theme.textTertiary)
                Text(permissionService.allOnboardingPermissionsGranted
                     ? "All required permissions are enabled."
                     : "If macOS does not show a prompt, use Open Settings and turn the matching toggle on manually.")
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionTile(
        icon: String,
        title: String,
        subtitle: String,
        state: PermissionState,
        pane: PermissionPane,
        request: @escaping () -> Void
    ) -> some View {
        OnboardingSurface {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(state.isGranted ? Theme.success : Theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                                .fill(state.isGranted ? Theme.success.opacity(0.12) : Theme.surfaceElevated)
                        )
                    Spacer()
                    permissionBadge(isGranted: state.isGranted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.vfBodyMedium)
                        .foregroundColor(Theme.textPrimary)
                    Text(subtitle)
                        .font(.vfCaption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Space.xs)

                if state.isGranted {
                    Text("Ready")
                        .font(.vfCaption)
                        .foregroundColor(Theme.textTertiary)
                } else {
                    HStack(spacing: Theme.Space.sm) {
                        VFButton(title: "Grant", style: .primary, isCompact: true) {
                            request()
                        }
                        VFButton(title: "Open Settings", style: .secondary, isCompact: true) {
                            permissionService.openPrivacyPane(pane)
                        }
                    }
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        }
    }

    private func permissionBadge(isGranted: Bool) -> some View {
        Text(isGranted ? "Granted" : "Missing")
            .font(.vfBadge)
            .foregroundColor(isGranted ? Theme.success : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.RadiusExtra.xs, style: .continuous)
                    .fill(isGranted ? Theme.success.opacity(0.12) : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.RadiusExtra.xs, style: .continuous)
                    .strokeBorder(isGranted ? Theme.success.opacity(0.25) : Theme.divider, lineWidth: 1)
            )
    }
}

// MARK: - Step 3: Preferences

private struct OnboardingPreferencesStep: View {
    @State private var selectedLanguage: String
    @State private var outputMode: String
    @State private var processingMode: String

    private let languages: [OnboardingChoice] = [
        .init(id: "auto", title: "Auto-detect", subtitle: "Switches with your speech.", badge: "Recommended"),
        .init(id: "hi", title: "Hindi", subtitle: "Hindi hint for raw transcription.", badge: nil),
        .init(id: "en", title: "English", subtitle: "English hint for raw transcription.", badge: nil)
    ]

    private let outputModes: [OnboardingChoice] = [
        .init(id: TranscriptOutputStyle.cleanHinglish.rawValue, title: "English output", subtitle: "Mixed speech in English letters.", badge: "Default"),
        .init(id: TranscriptOutputStyle.translateEnglish.rawValue, title: "Translate", subtitle: "Translate speech into English.", badge: nil),
        .init(id: TranscriptOutputStyle.verbatim.rawValue, title: "Original", subtitle: "Raw transcript with light cleanup.", badge: nil)
    ]

    private let processingModes: [OnboardingChoice] = [
        .init(id: TranscriptProcessingMode.dictation.rawValue, title: "Polish", subtitle: "Clean, format, and preserve your voice.", badge: "Default"),
        .init(id: TranscriptProcessingMode.rewrite.rawValue, title: "Rewrite", subtitle: "Clean phrasing and structure.", badge: nil),
        .init(id: TranscriptProcessingMode.promptEngineer.rawValue, title: "Prompt", subtitle: "Format dictated intent for AI agents.", badge: nil)
    ]

    init() {
        _selectedLanguage = State(initialValue: UserDefaults.standard.string(forKey: "language") ?? "auto")
        let storedOutputMode = UserDefaults.standard.string(forKey: "output_mode") ?? TranscriptOutputStyle.cleanHinglish.rawValue
        _outputMode = State(initialValue: storedOutputMode == TranscriptOutputStyle.clean.rawValue ? TranscriptOutputStyle.translateEnglish.rawValue : storedOutputMode)
        _processingMode = State(initialValue: UserDefaults.standard.string(forKey: "processing_mode") ?? TranscriptProcessingMode.dictation.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            OnboardingStepHeader(
                eyebrow: "Page 3",
                title: "Choose your language and output.",
                copy: "These defaults decide what lands after you release fn. You can change them anytime from Settings."
            )

            preferenceSection(
                title: "Language",
                description: "Used by Original mode only.",
                options: languages,
                selection: $selectedLanguage
            )
            .onChange(of: selectedLanguage) { newValue in
                UserDefaults.standard.set(newValue, forKey: "language")
            }

            preferenceSection(
                title: "Output style",
                description: "Pick the shape of the final text.",
                options: outputModes,
                selection: $outputMode
            )
            .onChange(of: outputMode) { newValue in
                UserDefaults.standard.set(newValue, forKey: "output_mode")
            }

            preferenceSection(
                title: "Polish mode",
                description: "How much rewriting to allow.",
                options: processingModes,
                selection: $processingMode
            )
            .onChange(of: processingMode) { newValue in
                UserDefaults.standard.set(newValue, forKey: "processing_mode")
            }
        }
    }

    private func preferenceSection(
        title: String,
        description: String,
        options: [OnboardingChoice],
        selection: Binding<String>
    ) -> some View {
        OnboardingSurface {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    Text(title)
                        .font(.vfBodyMedium)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(description)
                        .font(.vfCaption)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340, alignment: .trailing)
                }

                HStack(spacing: Theme.Space.md) {
                    ForEach(options) { option in
                        preferenceChoice(option, selection: selection)
                    }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    private func preferenceChoice(_ option: OnboardingChoice, selection: Binding<String>) -> some View {
        let isSelected = selection.wrappedValue == option.id

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selection.wrappedValue = option.id
            }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .top) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.interactive : Theme.textTertiary)
                    Spacer()
                    if let badge = option.badge {
                        VFBadge(label: badge, style: isSelected ? .promo : .plan)
                    }
                }
                Text(option.title)
                    .font(.vfCalloutSemibold)
                    .foregroundColor(Theme.textPrimary)
                Text(option.subtitle)
                    .font(.vfCaption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                    .fill(isSelected ? Theme.interactiveSoft : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                    .strokeBorder(isSelected ? Theme.interactive.opacity(0.45) : Theme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .vfClickableCursor()
    }
}

// MARK: - Step 4: Test and Sensitivity

/// Final step: invite the user to try dictation and tune the noise gate with
/// the same live meter used by Settings.
private struct OnboardingTestStep: View {
    @ObservedObject var runStore: RunStore

    @StateObject private var microphoneProbe = MicrophoneProbe()
    @State private var initialCount: Int?
    @State private var latestTranscript: String = ""
    @State private var noiseGateThreshold: Double

    init(runStore: RunStore) {
        self.runStore = runStore
        let stored = UserDefaults.standard.object(forKey: "noise_gate_threshold") as? Double
        _noiseGateThreshold = State(initialValue: stored ?? 0.005)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            OnboardingStepHeader(
                eyebrow: "Page 4",
                title: "Test dictation and sensitivity.",
                copy: "First check that your mic crosses the threshold, then hold fn and speak. Your newest onboarding transcript appears below."
            )

            OnboardingSurface {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Mic sensitivity")
                            .font(.vfBodyMedium)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        VFButton(
                            title: microphoneProbe.isProbing ? "Stop" : "Test mic",
                            icon: microphoneProbe.isProbing ? "stop.fill" : "mic.fill",
                            style: microphoneProbe.isProbing ? .destructive : .secondary,
                            isCompact: true
                        ) {
                            if microphoneProbe.isProbing {
                                microphoneProbe.stop()
                            } else {
                                microphoneProbe.start()
                            }
                        }
                    }

                    LevelMeterView(
                        level: microphoneProbe.currentLevel,
                        threshold: MicrophoneProbe.normalizedThreshold(noiseGateThreshold),
                        isActive: microphoneProbe.isProbing
                    )

                    HStack {
                        Text(sensitivityCaption)
                            .font(.vfCaption)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.3f", noiseGateThreshold))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                    }

                    Slider(value: $noiseGateThreshold, in: 0.001...0.05, step: 0.001)
                        .tint(Theme.textPrimary)
                        .onChange(of: noiseGateThreshold) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "noise_gate_threshold")
                        }

                    HStack(spacing: Theme.Space.sm) {
                        sensitivityPresetButton(label: "Sensitive", threshold: 0.003)
                        sensitivityPresetButton(label: "Balanced", threshold: 0.008)
                        sensitivityPresetButton(label: "Strict", threshold: 0.020)
                    }
                }
                .padding(Theme.Space.lg)
            }

            OnboardingSurface {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text("Press and hold")
                            .font(.vfBodyMedium)
                            .foregroundColor(Theme.textPrimary)
                        HotkeyBadge(label: "fn")
                        Text("to dictate")
                            .font(.vfBodyMedium)
                            .foregroundColor(Theme.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("YOUR TRANSCRIPT")
                            .font(.vfCategoryLabel)
                            .foregroundColor(Theme.textTertiary)
                            .tracking(0.5)

                        if latestTranscript.isEmpty {
                            Text("Waiting for your first test run.")
                                .font(.vfCallout)
                                .foregroundColor(Theme.textTertiary)
                                .italic()
                        } else {
                            Text(latestTranscript)
                                .font(.vfBody)
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    )
                }
                .padding(Theme.Space.lg)
            }

            Text("If fn does not trigger, check System Settings > Keyboard > Press Fn key to, and set it to Do Nothing. You can also choose a different hotkey later.")
                .font(.vfCaption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(runStore.$summaries) { summaries in
            if initialCount == nil {
                initialCount = summaries.count
                return
            }
            if let newest = summaries.first, summaries.count > (initialCount ?? 0) {
                latestTranscript = newest.previewText
            }
        }
        .onDisappear {
            microphoneProbe.stop()
        }
    }

    private var sensitivityCaption: String {
        if !microphoneProbe.isProbing {
            return "Start a mic test and speak normally. The level should cross the threshold tick."
        }
        if microphoneProbe.currentLevel >= MicrophoneProbe.normalizedThreshold(noiseGateThreshold) {
            return "Voice is crossing the threshold. This setting should capture you."
        }
        return "Speak normally. Lower the threshold if your voice stays below the tick."
    }

    private func sensitivityPresetButton(label: String, threshold: Double) -> some View {
        let isSelected = abs(noiseGateThreshold - threshold) < 0.0005
        return Button {
            noiseGateThreshold = threshold
            UserDefaults.standard.set(threshold, forKey: "noise_gate_threshold")
        } label: {
            Text(label)
                .font(.vfCaption)
                .foregroundColor(isSelected ? Theme.textOnDark : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.RadiusExtra.sm, style: .continuous)
                        .fill(isSelected ? Theme.textPrimary : Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.RadiusExtra.sm, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Theme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .vfClickableCursor()
    }
}
