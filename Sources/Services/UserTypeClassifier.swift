import Foundation
import Combine

/// AI-inferred classification of how the user uses Vordi. Drives the
/// "Your User Type" card on the Insights tab.
///
/// Gating: the card is locked until the user has ≥`minEligibleRuns`
/// transcriptions, each with ≥`minWordsPerRun` words. Both thresholds
/// exist for the same reason — until we see enough substantive content,
/// any classification would be guesswork that miscategorizes new users
/// and damages trust in the feature.
@MainActor
final class UserTypeClassifier: ObservableObject {
    static let shared = UserTypeClassifier()

    @Published private(set) var classification: UserTypeClassification?
    @Published private(set) var isClassifying: Bool = false
    @Published private(set) var lastError: String?

    private let llm: LLMService
    private let runStore: RunStore
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Tuning

    /// Minimum total qualifying transcriptions before the card unlocks.
    /// Below this, sample size is too small to classify reliably.
    let minEligibleRuns: Int = 20
    /// Minimum words per transcription for it to count toward the gate.
    /// Short runs are typically commands or filler — not enough signal
    /// for role inference.
    let minWordsPerRun: Int = 20
    /// How long a classification stays "fresh." Past this we recommend
    /// a refresh but still surface the cached value (no flicker into
    /// the locked state on an old user with valid data).
    let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private init(llm: LLMService = .shared, runStore: RunStore = .shared) {
        self.llm = llm
        self.runStore = runStore
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        loadCache()
    }

    // MARK: - Public API

    /// Compute current eligibility from the run store. Pure function of
    /// the published summaries — callers can call this on every render
    /// without worrying about cost.
    func eligibility() -> UserTypeEligibility {
        let qualifying = runStore.summaries.filter {
            let wc = ComputedStats.wordCount(of: $0)
            return wc >= minWordsPerRun
        }
        return UserTypeEligibility(
            qualifyingRuns: qualifying.count,
            requiredRuns: minEligibleRuns,
            requiredWordsPerRun: minWordsPerRun
        )
    }

    /// True if the cached classification is older than `staleAfter`.
    var isCacheStale: Bool {
        guard let c = classification else { return false }
        return Date().timeIntervalSince(c.computedAt) > staleAfter
    }

    /// Force a fresh classification. No-op if eligibility hasn't been
    /// met yet — the UI gating layer should never get here in that case,
    /// but the guard makes the function safe in isolation.
    func classify(force: Bool = false) async {
        guard eligibility().isUnlocked else { return }
        // Cache short-circuit: keep the existing classification when it
        // exists and is still fresh, unless the caller forced a refresh.
        if !force, classification != nil, !isCacheStale { return }
        guard !isClassifying else { return }

        isClassifying = true
        lastError = nil
        defer { isClassifying = false }

        // Sample up to 30 qualifying transcripts. We don't send the
        // full corpus — token budget + signal vs. noise both favor a
        // representative sample over exhaustive context.
        let qualifying = runStore.summaries
            .filter { ComputedStats.wordCount(of: $0) >= minWordsPerRun }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(30)

        let snippets = qualifying.compactMap { summary -> String? in
            guard let run = runStore.loadRun(id: summary.id) else { return nil }
            let raw = run.postProcessing?.finalText
                ?? run.transcription?.rawText
                ?? summary.previewText
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Cap each transcript to ~400 chars so the classifier can
            // see breadth across many runs instead of depth in a few.
            return String(trimmed.prefix(400))
        }
        guard snippets.count >= minEligibleRuns else {
            lastError = "Not enough usable transcripts to classify."
            return
        }

        // Most-used apps hint — strengthens the signal beyond raw text.
        // (A developer with mostly code-window dictation reads very
        // differently from a developer who mostly drafts emails.)
        let appCounts = Dictionary(grouping: qualifying.filter { $0.frontmostAppName != nil }) {
            $0.frontmostAppName!
        }.mapValues { $0.count }
        let topApps = appCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")

        let snippetsBlock = snippets.enumerated().map { (i, s) in
            "[\(i + 1)] \(s)"
        }.joined(separator: "\n\n")

        let systemPrompt = """
        You classify how a person uses voice dictation by reading their \
        recent transcripts. Choose ONE primary role from this list:
          - developer
          - writer
          - manager
          - researcher
          - designer
          - student
          - other

        Then list 2-4 short signals (3-7 words each) explaining WHY — \
        specific patterns you saw, e.g. "Frequent shell commands", \
        "Discusses sprint planning", "Drafts long-form prose".

        Respond ONLY with JSON, no markdown fences. Shape:
        {
          "role": "developer",
          "confidence": 0.85,
          "headline": "Senior dev shipping infra work",
          "signals": ["Frequent kubectl mentions", "Discusses code reviews"]
        }
        """

        let userPrompt = """
        Most-used apps (with run count): \(topApps.isEmpty ? "n/a" : topApps)

        Recent transcripts:
        \(snippetsBlock)
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: userPrompt),
            ],
            temperature: 0.1,
            maxTokens: 350,
            maxAttempts: 2,
            purpose: "user_type_classification"
        )

        do {
            let response = try await llm.complete(request)
            if let parsed = Self.parseClassification(response.content) {
                classification = UserTypeClassification(
                    role: parsed.role,
                    headline: parsed.headline,
                    signals: parsed.signals,
                    confidence: parsed.confidence,
                    runsAnalyzed: snippets.count,
                    computedAt: Date()
                )
                persist()
            } else {
                lastError = "Couldn't parse the classifier response."
            }
        } catch {
            lastError = (error as? LLMError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clear the cached classification — used by manual "reset" debugging
    /// affordance, not exposed in UI.
    func reset() {
        classification = nil
        try? fileManager.removeItem(at: storeURL)
    }

    // MARK: - Internals

    private static func parseClassification(_ raw: String) -> (role: UserType, headline: String, signals: [String], confidence: Double)? {
        var cleaned = raw
        if let r = cleaned.range(of: "```json") {
            cleaned.removeSubrange(cleaned.startIndex..<r.upperBound)
        }
        if let r = cleaned.range(of: "```", options: .backwards) {
            cleaned = String(cleaned[..<r.lowerBound])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let data = cleaned.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let roleRaw = (obj["role"] as? String) ?? "other"
        let role = UserType(rawValue: roleRaw) ?? .other
        let headline = (obj["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signals = (obj["signals"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let confidence = (obj["confidence"] as? Double).map { max(0, min(1, $0)) } ?? 0.5
        return (role, headline.isEmpty ? role.defaultHeadline : headline, signals, confidence)
    }

    // MARK: - Persistence

    private var storeURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Vordi", isDirectory: true)
            .appendingPathComponent("user_type.json")
    }

    private func loadCache() {
        let dir = storeURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        guard
            let data = try? Data(contentsOf: storeURL),
            let decoded = try? decoder.decode(UserTypeClassification.self, from: data)
        else { return }
        classification = decoded
    }

    private func persist() {
        guard let c = classification, let data = try? encoder.encode(c) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Models

enum UserType: String, Codable {
    case developer, writer, manager, researcher, designer, student, other

    var displayLabel: String {
        switch self {
        case .developer:  return "Developer"
        case .writer:     return "Writer"
        case .manager:    return "Manager"
        case .researcher: return "Researcher"
        case .designer:   return "Designer"
        case .student:    return "Student"
        case .other:      return "Generalist"
        }
    }

    var icon: String {
        switch self {
        case .developer:  return "chevron.left.forwardslash.chevron.right"
        case .writer:     return "highlighter"
        case .manager:    return "person.3.fill"
        case .researcher: return "magnifyingglass"
        case .designer:   return "paintbrush.fill"
        case .student:    return "book.fill"
        case .other:      return "person.fill.questionmark"
        }
    }

    var defaultHeadline: String {
        switch self {
        case .developer:  return "Writes code and ships software."
        case .writer:     return "Crafts long-form prose."
        case .manager:    return "Coordinates people and projects."
        case .researcher: return "Investigates and synthesizes information."
        case .designer:   return "Shapes how products look and feel."
        case .student:    return "Learns across disciplines."
        case .other:      return "Mixes a few different work styles."
        }
    }

    /// RGB tint applied to the user-type card header. Same palette as
    /// KnowledgeEntityType — keeps the design system tight.
    var tintRGB: (Double, Double, Double) {
        switch self {
        case .developer:  return (0.45, 0.70, 0.95)
        case .writer:     return (0.40, 0.80, 0.65)
        case .manager:    return (0.95, 0.55, 0.35)
        case .researcher: return (0.65, 0.55, 0.95)
        case .designer:   return (0.85, 0.45, 0.75)
        case .student:    return (0.95, 0.78, 0.30)
        case .other:      return (0.65, 0.65, 0.70)
        }
    }
}

struct UserTypeClassification: Codable {
    let role: UserType
    let headline: String
    let signals: [String]
    let confidence: Double
    let runsAnalyzed: Int
    let computedAt: Date
}

struct UserTypeEligibility {
    let qualifyingRuns: Int
    let requiredRuns: Int
    let requiredWordsPerRun: Int

    var isUnlocked: Bool { qualifyingRuns >= requiredRuns }
    var progress: Double {
        guard requiredRuns > 0 else { return 1.0 }
        return min(1.0, Double(qualifyingRuns) / Double(requiredRuns))
    }
}
