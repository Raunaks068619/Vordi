import Foundation

/// Subprocess execution layer for the user's installed AI CLIs
/// (Claude Code, Codex, Gemini). The whole architecture is the article
/// you sent me: we don't touch credentials, we don't proxy through
/// a backend, we spawn the official CLI binary and let it handle auth
/// against its own subscription.
///
/// **What this owns:**
///   - PATH probing (menu-bar apps inherit launchd's minimal PATH, so
///     `/opt/homebrew/bin/claude` won't be found without help).
///   - Process spawning with stdin/stdout pipes.
///   - Timeout handling — 30s default, cancelable via Task cancellation.
///   - Output capture into a String. (JSON parsing lives in `CLIBackend`
///     since the schema differs per CLI.)
///
/// **What this doesn't own:**
///   - Per-CLI argument shaping (CLIBackend has the prompts/args).
///   - Auth detection (we surface stdout/stderr; parsers decide what
///     "please log in" looks like).
final class CLIRunner {
    static let shared = CLIRunner()

    /// Resolved absolute paths to known CLIs. Populated by `probe()`.
    /// nil means "not installed (or not detectable from our search
    /// paths)" — distinct from "installed but not authed."
    private(set) var resolvedPaths: [CLIIdentifier: URL] = [:]

    /// Common locations where Node/Rust/Go CLIs land on macOS.
    /// Ordered by likelihood — homebrew first because that's where the
    /// vast majority of dev tooling sits in 2026.
    private let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/install/global/node_modules/.bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.npm-global/bin",
        NSHomeDirectory() + "/.npm/bin",
        NSHomeDirectory() + "/.cargo/bin",
        NSHomeDirectory() + "/.deno/bin",
        NSHomeDirectory() + "/.volta/bin",
        NSHomeDirectory() + "/.nvm/versions/node/current/bin",
    ]

    private init() {}

    // MARK: - Detection

    /// Find each known CLI. Cheap (just `FileManager` existence checks)
    /// — safe to call at app launch or on every Settings render.
    func probe() async {
        // Resolve each CLI sequentially. Doing this as `for await`
        // inside a TaskGroup would parallelize the shell probes, but
        // they're already ~10ms each (filesystem) + ~150ms for the
        // shell fallback. Sequential keeps the code straight without
        // measurable cost.
        var results: [(CLIIdentifier, URL)] = []
        for cli in CLIIdentifier.allCases {
            if let url = await resolveBinary(named: cli.binaryName) {
                results.append((cli, url))
            }
        }
        let mapping = Dictionary(uniqueKeysWithValues: results)
        await MainActor.run {
            self.resolvedPaths = mapping
        }
    }

    /// Resolve a single binary. Try the static search dirs first; only
    /// shell out to `zsh -ic 'which X'` if that fails — the shell hop
    /// costs ~150ms which is worth avoiding when we don't need it.
    private func resolveBinary(named name: String) async -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // Shell fallback. `-i` loads .zshrc so user-set PATH additions
        // (rtx, mise, asdf, custom dirs) come through. `-c` runs the
        // command and exits. We ask `command -v` because it's POSIX
        // (which is more portable than `which`, weirdly).
        let output = await runShellCommand("command -v \(name) 2>/dev/null")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, fm.isExecutableFile(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    private func runShellCommand(_ command: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.launchPath = "/bin/zsh"
                process.arguments = ["-ic", command]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()  // discard

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Execution

    /// Run a CLI binary with the given args + stdin. Returns combined
    /// stdout once the process exits. Throws on timeout, spawn failure,
    /// or non-zero exit.
    ///
    /// `stdin` is optional — most CLI calls go through `-p "prompt"`
    /// args, but if a prompt is too long for the shell arg buffer
    /// (typically 256KB on macOS) we pipe via stdin instead.
    func run(
        binary: URL,
        arguments: [String],
        stdin: String? = nil,
        timeout: TimeInterval = 30,
        environment: [String: String] = [:]
    ) async throws -> CLIRunResult {
        // Capture only Sendable values so the @Sendable closure below
        // doesn't need self. Without this, CLIRunner being a reference
        // type would trip the Swift 6 concurrency checker.
        let searchDirs = self.searchDirectories
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments

                // Inherit the user's full environment, then override
                // with any explicit values. CLIs often check
                // $ANTHROPIC_API_KEY, $OPENAI_API_KEY, etc. so passing
                // through is important. We also ensure PATH includes
                // our search dirs in case the CLI shells out to other
                // tools internally.
                var env = ProcessInfo.processInfo.environment
                let augmentedPath = ([env["PATH"] ?? ""] + searchDirs)
                    .filter { !$0.isEmpty }
                    .joined(separator: ":")
                env["PATH"] = augmentedPath
                for (k, v) in environment { env[k] = v }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                if stdin != nil {
                    process.standardInput = stdinPipe
                }

                // Accumulate stdout/stderr in background. Doing this
                // via readabilityHandlers avoids the classic deadlock
                // where a large output fills the pipe buffer and the
                // child blocks before `waitUntilExit()` returns.
                var stdoutData = Data()
                var stderrData = Data()
                let stdoutQueue = DispatchQueue(label: "cli.stdout")
                let stderrQueue = DispatchQueue(label: "cli.stderr")
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        stdoutQueue.sync { stdoutData.append(chunk) }
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        stderrQueue.sync { stderrData.append(chunk) }
                    }
                }

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: CLIError.spawnFailed(error.localizedDescription))
                    return
                }

                // Feed stdin if provided.
                if let stdin {
                    stdinPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                    try? stdinPipe.fileHandleForWriting.close()
                }

                // Timeout watchdog. Schedules a SIGTERM after the
                // configured deadline; if the process hasn't exited
                // yet we mark this run as a timeout.
                let deadline = DispatchTime.now() + timeout
                var timedOut = false
                let timeoutSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timeoutSource.schedule(deadline: deadline)
                timeoutSource.setEventHandler {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                timeoutSource.activate()

                process.waitUntilExit()
                timeoutSource.cancel()

                // Stop the readability handlers and flush any final
                // buffered output. Without this final read we lose the
                // last ~0-4KB of stdout depending on pipe-buffer state.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutData.append(stdoutPipe.fileHandleForReading.availableData)
                stderrData.append(stderrPipe.fileHandleForReading.availableData)

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if timedOut {
                    cont.resume(throwing: CLIError.timeout(seconds: timeout))
                    return
                }

                let exitCode = process.terminationStatus
                let result = CLIRunResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: Int(exitCode)
                )

                if exitCode != 0 {
                    // Bubble up exit-code-as-error but include the
                    // captured streams so parsers can still inspect for
                    // auth-needed strings, rate-limit messages, etc.
                    cont.resume(throwing: CLIError.nonZeroExit(result))
                    return
                }

                cont.resume(returning: result)
            }
        }
    }
}

// MARK: - Types

enum CLIIdentifier: String, CaseIterable, Codable {
    case claude
    case codex
    case gemini

    var binaryName: String {
        switch self {
        case .claude:  return "claude"
        case .codex:   return "codex"
        case .gemini:  return "gemini"
        }
    }

    /// Display copy for Settings UI.
    var displayName: String {
        switch self {
        case .claude:  return "Claude Code"
        case .codex:   return "Codex CLI"
        case .gemini:  return "Gemini CLI"
        }
    }

    var settingsCopy: String {
        switch self {
        case .claude:  return "Uses your Claude Pro/Max plan via the Claude Code CLI."
        case .codex:   return "Uses your ChatGPT Plus/Pro plan via the Codex CLI."
        case .gemini:  return "Uses your Gemini quota via the Gemini CLI."
        }
    }
}

struct CLIRunResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int

    /// Convenience — most parsers want stdout, but if stdout is empty
    /// the answer might be on stderr (some CLIs route status/prose
    /// there).
    var combinedOutput: String {
        stdout.isEmpty ? stderr : stdout
    }
}

enum CLIError: LocalizedError {
    case binaryNotFound(name: String)
    case notAuthenticated(cli: CLIIdentifier, hint: String)
    case spawnFailed(String)
    case timeout(seconds: TimeInterval)
    case nonZeroExit(CLIRunResult)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "Couldn't find the `\(name)` binary in any known path."
        case .notAuthenticated(let cli, let hint):
            return "\(cli.displayName) isn't authenticated. \(hint)"
        case .spawnFailed(let message):
            return "Couldn't start the CLI: \(message)"
        case .timeout(let seconds):
            return "The CLI didn't respond within \(Int(seconds))s."
        case .nonZeroExit(let result):
            let snippet = result.stderr.isEmpty
                ? result.stdout.prefix(200)
                : result.stderr.prefix(200)
            return "CLI exited with code \(result.exitCode). \(snippet)"
        case .parseFailed(let message):
            return "Couldn't parse the CLI's response: \(message)"
        }
    }
}
