import Foundation

/// Per-CLI argument shaping + output parsing. Lives outside CLIRunner so
/// the runner stays a pure subprocess tool and each CLI's quirks are
/// scoped to one struct.
///
/// **Why per-CLI parsers**: each CLI's `--output-format json` is a
/// different shape and version-skews independently. Trying to use one
/// generic parser would create a brittle "best effort" extractor that
/// silently degrades when something changes upstream. Per-CLI lets us
/// defend each parser against its own failure modes.
struct CLIBackend {
    let identifier: CLIIdentifier
    let binary: URL

    /// One-shot completion call. Builds the right args for the CLI,
    /// spawns it via CLIRunner, parses the result, returns plain text.
    ///
    /// `system` is the system-prompt message; some CLIs accept it as a
    /// flag, others want it concatenated. We handle both inside the
    /// per-CLI builders.
    func complete(system: String, user: String, timeout: TimeInterval = 45) async throws -> String {
        switch identifier {
        case .claude:
            return try await runClaudeCode(system: system, user: user, timeout: timeout)
        case .codex:
            return try await runCodex(system: system, user: user, timeout: timeout)
        case .gemini:
            return try await runGemini(system: system, user: user, timeout: timeout)
        }
    }

    /// Cheap "are you alive and authed" check — used by the Settings
    /// "Probe" button. Sends a fixed minimal prompt and validates the
    /// response. Auth failures bubble up as `CLIError.notAuthenticated`
    /// with copy specific to the CLI.
    func probe() async throws -> String {
        // Use a short timeout — if a CLI is fundamentally broken we
        // want the UI to surface fast, not stall for 30s.
        return try await complete(system: "Respond with exactly: OK", user: "ping", timeout: 15)
    }

    // MARK: - Claude Code

    /// `claude -p "prompt" --output-format stream-json`
    /// Emits one JSON event per line with a `type` discriminator. We
    /// concatenate the `text` deltas from `assistant_turn` events.
    private func runClaudeCode(system: String, user: String, timeout: TimeInterval) async throws -> String {
        // System prompt is passed via `--system` flag (since 1.4.0).
        // Older versions accepted it concatenated into -p; we
        // double up to maximize compatibility.
        let prompt = system.isEmpty ? user : "\(system)\n\n---\n\n\(user)"

        // Use plain text output (`--output-format text`) for v0.6.0.
        // stream-json is more robust but its schema isn't 100% stable
        // across the 1.x line. We can graduate to stream-json once
        // we've validated the parser against a few CLI versions.
        let args = [
            "-p", prompt,
            "--output-format", "text",
        ]

        let result: CLIRunResult
        do {
            result = try await CLIRunner.shared.run(
                binary: binary,
                arguments: args,
                timeout: timeout
            )
        } catch let CLIError.nonZeroExit(failedResult) {
            // Detect common auth failure modes and translate.
            let combined = (failedResult.stdout + "\n" + failedResult.stderr).lowercased()
            if combined.contains("not logged in") || combined.contains("authentication") || combined.contains("please log in") {
                throw CLIError.notAuthenticated(
                    cli: .claude,
                    hint: "Run `claude login` in Terminal to sign in with your Claude Pro/Max account."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CLIError.parseFailed("Claude Code returned an empty response. stderr: \(result.stderr.prefix(200))")
        }
        return trimmed
    }

    // MARK: - Codex CLI

    /// `codex exec "prompt"` returns a final response on stdout.
    /// The OpenAI Codex CLI auto-streams to the terminal in interactive
    /// mode; `exec` is the headless subcommand that just prints the
    /// answer.
    private func runCodex(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let prompt = system.isEmpty ? user : "\(system)\n\n---\n\n\(user)"
        let args = ["exec", prompt]

        let result: CLIRunResult
        do {
            result = try await CLIRunner.shared.run(
                binary: binary,
                arguments: args,
                timeout: timeout
            )
        } catch let CLIError.nonZeroExit(failedResult) {
            let combined = (failedResult.stdout + "\n" + failedResult.stderr).lowercased()
            if combined.contains("not authenticated") || combined.contains("please run `codex login`") || combined.contains("no api key") {
                throw CLIError.notAuthenticated(
                    cli: .codex,
                    hint: "Run `codex login` in Terminal to sign in with your ChatGPT Plus/Pro account."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CLIError.parseFailed("Codex CLI returned an empty response. stderr: \(result.stderr.prefix(200))")
        }
        return trimmed
    }

    // MARK: - Gemini CLI

    /// `gemini -p "prompt"` returns the assistant response. The Gemini
    /// CLI also supports `--json` but the schema's been moving — text
    /// is the safest default.
    private func runGemini(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let prompt = system.isEmpty ? user : "\(system)\n\n---\n\n\(user)"
        let args = ["-p", prompt]

        let result: CLIRunResult
        do {
            result = try await CLIRunner.shared.run(
                binary: binary,
                arguments: args,
                timeout: timeout
            )
        } catch let CLIError.nonZeroExit(failedResult) {
            let combined = (failedResult.stdout + "\n" + failedResult.stderr).lowercased()
            if combined.contains("not authenticated") || combined.contains("login") || combined.contains("api key") {
                throw CLIError.notAuthenticated(
                    cli: .gemini,
                    hint: "Run `gemini auth login` in Terminal to sign in with your Google account."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CLIError.parseFailed("Gemini CLI returned an empty response. stderr: \(result.stderr.prefix(200))")
        }
        return trimmed
    }
}
