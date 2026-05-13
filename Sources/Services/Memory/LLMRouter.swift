import Foundation
import Combine

/// Single dispatch point for Memory + Knowledge Graph LLM calls.
///
/// **Architecture:**
/// ```
/// MemoryChatService / IndexerService entity extractor
///         │
///         ▼
///    LLMRouter
///   /          \
/// HTTP path   CLI path
/// (LLMService) (CLIBackend → CLIRunner → subprocess)
/// ```
///
/// **Scope explicitly limited to Memory + KG**: the dictation polish
/// path still calls `LLMService.shared.complete` directly. Per the
/// product decision, polish stays HTTPS so we don't add subprocess
/// latency to the hot dictation loop.
///
/// **Auto-pick logic** (Q2: "if any CLI is detected, use it"):
///   - On first launch, if `CLIRunner.probe()` finds any CLI, we
///     default to it (prefer Claude > Codex > Gemini for ordering).
///   - User can override in Settings at any time.
///   - If the chosen CLI later disappears (uninstalled), we transparently
///     fall back to `.builtIn` and surface a one-time notice.
@MainActor
final class LLMRouter: ObservableObject {
    nonisolated static let shared = LLMRouter()

    /// What the user picked (or what auto-pick decided).
    @Published private(set) var activeProvider: ChatProvider = .builtIn

    /// Currently-detected CLIs (post-probe). Reflects `CLIRunner.resolvedPaths`.
    @Published private(set) var detectedCLIs: Set<CLIIdentifier> = []

    /// Per-CLI probe state — populated by the Settings "Probe" button
    /// (or auto-probe on Settings open). Lets the UI show a colored
    /// status badge per CLI without re-running probes on every render.
    @Published private(set) var probeStates: [CLIIdentifier: ProbeState] = [:]

    enum ChatProvider: Codable, Hashable {
        case builtIn               // existing LLMService → HTTPS path
        case cli(CLIIdentifier)

        var label: String {
            switch self {
            case .builtIn:    return "Built-in (your polish backend)"
            case .cli(let c): return c.displayName
            }
        }
    }

    enum ProbeState: Equatable {
        case unknown                 // never probed
        case probing
        case ready(version: String?) // CLI responded with "OK"
        case authNeeded(hint: String)
        case error(String)
    }

    private let userDefaultsKey = "memory_chat_provider"

    nonisolated private init() {
        // Bootstrap from UserDefaults without touching @Published state
        // synchronously. The published `activeProvider` gets reassigned
        // here, but since this is the init path nothing else has had a
        // chance to subscribe yet.
        if let raw = UserDefaults.standard.string(forKey: "memory_chat_provider") {
            if raw == "builtIn" {
                Task { @MainActor in self.activeProvider = .builtIn }
            } else if raw.hasPrefix("cli:"),
                      let cli = CLIIdentifier(rawValue: String(raw.dropFirst(4))) {
                Task { @MainActor in self.activeProvider = .cli(cli) }
            }
        }
    }

    // MARK: - Public API

    /// Boot — probe CLIs, auto-pick default if user hasn't chosen one.
    /// Safe to call from AppDelegate.applicationDidFinishLaunching.
    func start() {
        Task {
            await CLIRunner.shared.probe()
            await MainActor.run {
                self.detectedCLIs = Set(CLIRunner.shared.resolvedPaths.keys)
            }
            await autoPickIfNeeded()
            self.wireMemoryChatService()
        }
    }

    /// User-driven provider switch from Settings UI.
    func setProvider(_ provider: ChatProvider) {
        guard isProviderValid(provider) else { return }
        activeProvider = provider
        persistProvider()
        wireMemoryChatService()
    }

    /// Run a probe call against the given CLI. Updates `probeStates`
    /// in-place and returns the resolved state for immediate use.
    @discardableResult
    func probe(_ cli: CLIIdentifier) async -> ProbeState {
        guard let binary = CLIRunner.shared.resolvedPaths[cli] else {
            let state = ProbeState.error("Binary not found.")
            probeStates[cli] = state
            return state
        }

        probeStates[cli] = .probing
        let backend = CLIBackend(identifier: cli, binary: binary)
        do {
            _ = try await backend.probe()
            let state = ProbeState.ready(version: nil)
            probeStates[cli] = state
            return state
        } catch let CLIError.notAuthenticated(_, hint) {
            let state = ProbeState.authNeeded(hint: hint)
            probeStates[cli] = state
            return state
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let state = ProbeState.error(message)
            probeStates[cli] = state
            return state
        }
    }

    // MARK: - Internals

    /// Choose a default provider if the user hasn't picked one yet.
    /// Prefer Claude → Codex → Gemini (rough order of "most users have
    /// this installed in May 2026"; revisit if data says otherwise).
    private func autoPickIfNeeded() async {
        // If user already saved a preference, honor it — even if the
        // chosen CLI isn't currently detected. That's the right call
        // because "I uninstalled my CLI" is much rarer than "I just
        // closed Settings and reopened it." We surface the missing-CLI
        // state in Settings rather than silently switching.
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return
        }

        let order: [CLIIdentifier] = [.claude, .codex, .gemini]
        for cli in order where detectedCLIs.contains(cli) {
            activeProvider = .cli(cli)
            persistProvider()
            return
        }
        // Nothing detected — leave .builtIn (the init default).
    }

    /// Wire `MemoryChatService.chatCall` to invoke whatever the user's
    /// chosen provider is. Re-called whenever the provider changes.
    private func wireMemoryChatService() {
        let provider = activeProvider

        // Capture only what the closure needs so it doesn't retain self.
        switch provider {
        case .builtIn:
            MemoryChatService.shared.setChatCall { system, user in
                let request = LLMRequest(
                    messages: [
                        LLMMessage(role: .system, content: system),
                        LLMMessage(role: .user,   content: user),
                    ],
                    temperature: 0.2,
                    maxTokens: 500,
                    maxAttempts: 2,
                    purpose: "memory_chat"
                )
                let response = try await LLMService.shared.complete(request)
                return response.content
            }

        case .cli(let cli):
            // Capture the resolved binary path at wire time so the
            // closure doesn't depend on @MainActor state at call time.
            guard let binary = CLIRunner.shared.resolvedPaths[cli] else {
                // CLI vanished — fall back to built-in. We mark the
                // active provider as builtIn so Settings UI tells the
                // user honestly, instead of pretending "Claude" is
                // active while quietly using their OpenAI key.
                print("LLMRouter: CLI \(cli.rawValue) not found, falling back to built-in")
                activeProvider = .builtIn
                persistProvider()
                wireMemoryChatService()
                return
            }
            let backend = CLIBackend(identifier: cli, binary: binary)
            MemoryChatService.shared.setChatCall { system, user in
                try await backend.complete(system: system, user: user)
            }
        }
    }

    private func isProviderValid(_ provider: ChatProvider) -> Bool {
        switch provider {
        case .builtIn:        return true
        case .cli(let cli):   return CLIRunner.shared.resolvedPaths[cli] != nil
        }
    }

    // MARK: - Persistence

    private func persistProvider() {
        let raw: String
        switch activeProvider {
        case .builtIn:        raw = "builtIn"
        case .cli(let cli):   raw = "cli:\(cli.rawValue)"
        }
        UserDefaults.standard.set(raw, forKey: userDefaultsKey)
    }

    private func loadProvider() {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey) else { return }
        if raw == "builtIn" {
            activeProvider = .builtIn
        } else if raw.hasPrefix("cli:"), let cli = CLIIdentifier(rawValue: String(raw.dropFirst(4))) {
            activeProvider = .cli(cli)
        }
    }
}
