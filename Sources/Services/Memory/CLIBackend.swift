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
        // Codex and Gemini both pay a cold-start tax: they load auth,
        // plugins/hooks, and sometimes retry a saturated model before the
        // first token. 15s made valid local installs look broken, so the
        // probe uses the same budget as a normal Memory chat request.
        return try await complete(system: "Respond with exactly: OK", user: "ping", timeout: 45)
    }

    // MARK: - Claude Code

    /// `claude -p "prompt" --output-format stream-json`
    /// Emits one JSON event per line with a `type` discriminator. We
    /// concatenate the `text` deltas from `assistant_turn` events.
    private func runClaudeCode(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let args = [
            "-p", user,
            "--system-prompt", system,
            "--output-format", "json",
            "--no-session-persistence",
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
            if combined.contains("not logged in")
                || combined.contains("authentication")
                || combined.contains("please log in")
                || combined.contains("does not have access to claude")
                || combined.contains("api_error_status\":403") {
                throw CLIError.notAuthenticated(
                    cli: .claude,
                    hint: "Run `claude auth login` in Terminal, or switch Claude Code to an account/org with Claude Code access."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = Self.parseClaudeJSON(result.stdout)
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let args = [
            "exec",
            "--json",
            "--color", "never",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-rules",
            prompt,
        ]

        let result: CLIRunResult
        do {
            result = try await CLIRunner.shared.run(
                binary: binary,
                arguments: args,
                timeout: timeout
            )
        } catch let CLIError.nonZeroExit(failedResult) {
            let combined = (failedResult.stdout + "\n" + failedResult.stderr).lowercased()
            if combined.contains("not authenticated")
                || combined.contains("please run `codex login`")
                || combined.contains("codex login")
                || combined.contains("no api key")
                || combined.contains("auth required") {
                throw CLIError.notAuthenticated(
                    cli: .codex,
                    hint: "Run `codex login` in Terminal to sign in with your ChatGPT Plus/Pro account."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = Self.parseCodexJSONL(result.stdout)
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let args = [
            "-m", "gemini-2.5-flash-lite",
            "-p", prompt,
            "--output-format", "json",
        ]

        let result: CLIRunResult
        do {
            result = try await CLIRunner.shared.run(
                binary: binary,
                arguments: args,
                timeout: timeout
            )
        } catch let CLIError.nonZeroExit(failedResult) {
            let combined = (failedResult.stdout + "\n" + failedResult.stderr).lowercased()
            if combined.contains("not authenticated")
                || combined.contains("login")
                || combined.contains("api key")
                || combined.contains("oauth")
                || combined.contains("credentials") {
                throw CLIError.notAuthenticated(
                    cli: .gemini,
                    hint: "Run `gemini auth login` in Terminal to sign in with your Google account."
                )
            }
            throw CLIError.nonZeroExit(failedResult)
        }

        let trimmed = Self.parseGeminiJSON(result.stdout)
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CLIError.parseFailed("Gemini CLI returned an empty response. stderr: \(result.stderr.prefix(200))")
        }
        return trimmed
    }

    // MARK: - Output parsers

    private static func parseClaudeJSON(_ raw: String) -> String? {
        guard let object = parseJSONObject(from: raw),
              let result = object["result"] as? String else { return nil }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCodexJSONL(_ raw: String) -> String? {
        var lastMessage: String?
        for line in raw.split(whereSeparator: \.isNewline) {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "item.completed",
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String
            else { continue }
            lastMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lastMessage?.isEmpty == false ? lastMessage : nil
    }

    private static func parseGeminiJSON(_ raw: String) -> String? {
        guard let object = parseJSONObject(from: raw),
              let response = object["response"] as? String else { return nil }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some CLIs print warnings/status lines before the JSON object. Find the
    /// outer JSON braces and parse only that range.
    private static func parseJSONObject(from raw: String) -> [String: Any]? {
        guard
            let start = raw.firstIndex(of: "{"),
            let end = raw.lastIndex(of: "}"),
            start <= end
        else { return nil }

        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
