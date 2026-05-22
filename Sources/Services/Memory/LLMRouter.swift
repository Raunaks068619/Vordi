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
/// **CLI discovery policy**:
///   - Never probe local CLIs at launch or on Settings appearance.
///   - The user explicitly clicks "Fetch AI CLIs" to scan for Claude,
///     Codex, and Gemini binaries.
///   - Auth smoke tests stay behind each row's manual Probe button.
@MainActor
final class LLMRouter: ObservableObject {
    nonisolated static let shared = LLMRouter()

    /// What the user picked.
    @Published private(set) var activeProvider: ChatProvider = .builtIn

    /// Currently-detected CLIs (post-probe). Reflects `CLIRunner.resolvedPaths`.
    @Published private(set) var detectedCLIs: Set<CLIIdentifier> = []

    /// Per-CLI probe state — populated by the Settings "Probe" button
    /// after discovery. Lets the UI show a colored status badge per CLI
    /// without re-running probes on every render.
    @Published private(set) var probeStates: [CLIIdentifier: ProbeState] = [:]
    @Published private(set) var isFetchingCLIs: Bool = false
    @Published private(set) var hasFetchedCLIs: Bool = false

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

    /// Boot — wire Memory chat without touching local CLI binaries. CLI
    /// discovery is manual-only via `fetchLocalCLIs()` from Settings.
    func start() {
        loadProvider()
        wireMemoryChatService()
    }

    /// User-triggered CLI discovery. This checks binary presence only; it
    /// does not run any AI prompt through the CLI. Per-provider auth probes
    /// stay behind each row's Probe button.
    func fetchLocalCLIs() async {
        guard !isFetchingCLIs else { return }
        isFetchingCLIs = true
        defer { isFetchingCLIs = false }

        await CLIRunner.shared.probe()
        detectedCLIs = Set(CLIRunner.shared.resolvedPaths.keys)
        hasFetchedCLIs = true

        // Drop stale states for binaries that disappeared. New detections
        // remain unprobed until the user clicks the row's Probe button.
        probeStates = probeStates.filter { detectedCLIs.contains($0.key) }

        if case .cli(let cli) = activeProvider, !detectedCLIs.contains(cli) {
            activeProvider = .builtIn
            persistProvider()
        }

        wireMemoryChatService()
    }

    /// User-driven provider switch from Settings UI.
    func setProvider(_ provider: ChatProvider) {
        guard isProviderValid(provider) else { return }
        activeProvider = provider
        persistProvider()
        wireMemoryChatService()
    }

    /// Single call surface for Memory chat + Knowledge Graph entity
    /// extraction. Both features should respect the same provider picker:
    /// built-in HTTP, Claude Code, Codex, or Gemini.
    func complete(system: String, user: String, timeout: TimeInterval = 60) async throws -> String {
        switch activeProvider {
        case .builtIn:
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

        case .cli(let cli):
            guard let binary = CLIRunner.shared.resolvedPaths[cli] else {
                throw CLIError.binaryNotFound(name: cli.binaryName)
            }
            return try await CLIBackend(identifier: cli, binary: binary)
                .complete(system: system, user: user, timeout: timeout)
        }
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

    /// Wire `MemoryChatService.chatCall` to invoke whatever the user's
    /// chosen provider is. Re-called whenever the provider changes.
    private func wireMemoryChatService() {
        let provider = activeProvider

        // Capture only what the closure needs so it doesn't retain self.
        switch provider {
        case .builtIn:
            MemoryChatService.shared.setChatCall { system, user in
                try await LLMRouter.shared.complete(system: system, user: user)
            }

        case .cli(let cli):
            // Capture the resolved binary path at wire time so the
            // closure doesn't depend on @MainActor state at call time.
            guard CLIRunner.shared.resolvedPaths[cli] != nil else {
                MemoryChatService.shared.setChatCall { _, _ in
                    throw CLIError.binaryNotFound(name: cli.binaryName)
                }
                return
            }
            MemoryChatService.shared.setChatCall { system, user in
                try await LLMRouter.shared.complete(system: system, user: user)
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
