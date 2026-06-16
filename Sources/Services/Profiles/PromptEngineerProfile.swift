import Foundation

/// "Prompt Engineer" profile — turns a casually-dictated description into
/// a readable, well-formed LLM prompt the user can paste into ChatGPT,
/// Claude, Cursor's chat, etc.
///
/// **Use case**: user is staring at the Cursor chat box. Holds Opt+2,
/// rambles about what they want — vague intent, half-formed requirements,
/// jumping between thoughts. Lets go. Pasted into Cursor: a clean prompt
/// with clear formatting that is proportional to the request.
///
/// **Triggered two ways**:
/// 1. Hotkey identifier `.promptEngineer` (Phase 3 dedicated hotkey).
/// 2. Trigger word "vordi prompt …" on the primary hotkey.
///
/// **Backend selection**: prefers gpt-4.1-mini for prompt structure work —
/// instruction-following matters more than speed here.
final class PromptEngineerProfile: TransformerProfile {
    let kind: ProfileKind = .promptEngineer
    let displayLabel = ProfileKind.promptEngineer.displayLabel
    static let userDefaultsKey = "prompt_engineer_system_prompt"

    private let llm: LLMService
    private let preferredBackend: PolishBackend?

    init(llm: LLMService = .shared, preferredBackend: PolishBackend? = nil) {
        self.llm = llm
        self.preferredBackend = preferredBackend ?? DeveloperModeProfile.defaultBackend()
    }

    func transform(
        _ input: TransformerInput,
        completion: @escaping (Result<TransformerOutput, Error>) -> Void
    ) {
        let stripped = input.triggerStripped
        guard !stripped.isEmpty else {
            let output = TransformerOutput(
                finalText: "",
                summary: "Prompt engineer: empty request",
                modelUsed: nil,
                costUSD: 0,
                llmLatencyMs: 0,
                usedAgentic: false,
                trace: ["Profile: prompt engineer", "Empty request"]
            )
            completion(.success(output))
            return
        }

        let systemPrompt = """
        \(Self.systemPrompt)

        Language output:
        \(Self.languageInstruction(for: input.style))
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: Self.buildUserMessage(request: stripped, context: input.context))
            ],
            backendOverride: preferredBackend,
            temperature: 0.2,
            maxTokens: 1200,
            maxAttempts: 2,
            purpose: "prompt_engineer"
        )

        llm.complete(request: request) { result in
            switch result {
            case .success(let response):
                let trace: [String] = [
                    "Profile: prompt engineer",
                    "Active app: \(input.context.frontmostAppName ?? "(unknown)")",
                    "Selection: \(input.context.selection.isEmpty ? "(none)" : "\(input.context.selection.count) chars")",
                    "Model: \(response.model)",
                    "Latency: \(response.latencyMs)ms",
                    String(format: "Cost: $%.5f", response.costUSD),
                ]
                let output = TransformerOutput(
                    finalText: response.content,
                    summary: "Prompt engineered (\(response.content.count) chars)",
                    modelUsed: response.model,
                    costUSD: response.costUSD,
                    llmLatencyMs: response.latencyMs,
                    usedAgentic: false,
                    trace: trace
                )
                completion(.success(output))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static var systemPrompt: String {
        let stored = (UserDefaults.standard.string(forKey: userDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyStoredPrompt = legacyDefaultSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty || stored == legacyStoredPrompt ? defaultSystemPrompt : stored
    }

    static let defaultSystemPrompt: String = """
    You are Prompt Engineer inside a macOS dictation app.
    The user dictated a rough thought, request, bug note, product idea, or instruction for an AI agent. Rewrite it into a clean, readable prompt that preserves the user's intent and vocabulary.

    Output rules:
    - No preamble, no explanation, no markdown fence.
    - Return only the improved prompt text.
    - Preserve the user's domain words, examples, filenames, quoted text, and constraints.
    - Do not invent requirements, acceptance criteria, tools, or decisions.
    - Keep the result proportional to the input: short input stays short, broad input gets more structure.

    Formatting behavior:
    - Use normal readable formatting: short paragraphs, line breaks, bullets, and numbered lists when they make the prompt easier for an AI agent to follow.
    - If the user gives a list or asks multiple things, keep them as separate bullets or numbered steps.
    - If the user gives a messy sentence with several clauses, split it into clear sentences.
    - If the user is asking an AI agent to do implementation work, make the task direct and actionable.
    - If the user gives follow-up questions, keep them as a small "Follow-up questions" list instead of turning them into a full spec.
    - Only use sections like Goal, Context, Constraints, Output format, and Acceptance criteria when the user explicitly asks for a spec/PRD/task brief/implementation plan, or when the dictated request is clearly large enough to need those sections.

    Style:
    - Clear, compact, and agent-readable.
    - Keep the user's voice where possible.
    - Avoid robotic spec templates for ordinary notes or quick instructions.
    """

    private static let legacyDefaultSystemPrompt: String = """
    You are a prompt-engineering assistant inside a macOS dictation app.
    The user dictated a vague, unstructured request describing what they
    want an AI to do. Output a CLEAN, WELL-STRUCTURED PROMPT they can
    paste directly into ChatGPT, Claude, Cursor, or another LLM chat.

    Output format:
    - No preamble, no explanation, no markdown fences.
    - The output IS the prompt — start writing it directly.
    - Use plain text. Use line breaks for clarity. Use markdown only when it helps the target LLM (lists, headers).
    - When the user's request is concrete, write a focused single-paragraph prompt.
    - When the user's request is broad, structure with: Goal, Context, Constraints, Output format, Acceptance criteria.
    - Preserve the user's domain language verbatim (don't paraphrase technical nouns).
    - If the user described code, include a "what to return" line that asks for explanation or code only — match the apparent intent.

    Do not invent requirements not in the user's description.
    Do not output the meta-instructions you're following.
    """

    static func buildUserMessage(request: String, context: ContextSnapshot) -> String {
        var sections: [String] = ["USER'S DESCRIPTION:", request]
        if !context.selection.isEmpty {
            sections.append("")
            sections.append("SELECTED TEXT (from user's editor — likely relevant):")
            sections.append(context.selection)
        }
        return sections.joined(separator: "\n")
    }

    static func languageInstruction(for style: TranscriptOutputStyle) -> String {
        switch style {
        case .cleanHinglish:
            return "Preserve Hindi, Marathi, or other non-English wording, but write it in English letters only. Do not translate meaning into English."
        case .translateEnglish, .clean:
            return "Translate the user's dictated request to natural English before writing the final prompt. The final prompt must be English."
        case .verbatim:
            return "Preserve the user's language choice. Only clean wording enough to make the final prompt usable."
        }
    }
}
