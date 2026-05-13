import Foundation
import Combine

/// Retrieval + answer pipeline for the Memory chat panel.
///
/// **Pipeline** (each stage compensates for the previous one's failure
/// mode):
///   1. Embed the question (~50ms).
///   2. Cosine similarity over ALL embeddings (in-Swift; fast through
///      ~10K vectors at 512 dims). Take top 30 by similarity.
///   3. FTS5 BM25 keyword search. Take top 30 by relevance.
///   4. Merge by normalized score, weighted 0.6 semantic + 0.4 lexical.
///      Either source alone is OK but the union has stronger recall.
///   5. Entity boost: if the question mentions a known node label,
///      add +0.3 to every transcript that references it.
///   6. Recency tiebreak (mild — older transcripts decay 1% per day).
///   7. Top 5 → LLM with cited sources.
///
/// **Recency fallback**: if stages 1–6 produce zero candidates with any
/// signal, hand the LLM the 5 most recent transcripts and explicitly
/// tell it "no specific match, just summarize what they're about."
/// Saves the user from the previous "I couldn't find any past
/// transcriptions" wall.
///
/// **LLM provider abstraction**: the chat takes a `chat` closure at
/// construction time. Defaults to `LLMService.shared` for backwards
/// compat; the upcoming `LLMRouter` will swap in either HTTP or CLI
/// behind the same interface.
@MainActor
final class MemoryChatService: ObservableObject {
    nonisolated static let shared = MemoryChatService()

    /// Single LLM call surface. Returns the assistant content, plain
    /// text. Streaming is intentionally not exposed here — the chat UI
    /// is a question/answer pattern, not a continuous conversation,
    /// and adding streaming complicates the CLI subprocess parsing path.
    typealias ChatCall = (_ system: String, _ user: String) async throws -> String

    /// Currently-configured LLM call. Replace via `setChatCall` when
    /// the user picks a different provider in Settings.
    ///
    /// Defaulted at declaration site (instead of in `init`) so the
    /// nonisolated singleton initializer doesn't have to assign it —
    /// Swift's stricter actor checking flags assignment to actor-
    /// isolated stored properties from a nonisolated context.
    private(set) var chatCall: ChatCall = { system, user in
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

    private let memory = MemoryStore.shared
    private let embedder = EmbeddingService.shared

    // MARK: - Tuning

    /// How many candidates we pull from each retrieval channel before
    /// merging. 30 is wider than we need (we take 5 at the end) but
    /// gives the score-merge layer enough headroom to surface a hit
    /// that scored mid-pack on one channel and high on the other.
    private let topKPerChannel: Int = 30
    /// Final number of sources stuffed into the LLM prompt. 5 keeps the
    /// system prompt + context comfortably under 4k tokens on any
    /// backend (CLI or HTTP).
    private let finalK: Int = 5
    /// Daily recency decay applied as multiplier on the final score.
    /// At 1%/day, a 30-day-old transcript is worth 0.74× a same-day one
    /// when scores are otherwise tied. Strong enough to break ties,
    /// mild enough not to bury old-but-relevant content.
    private let recencyDecayPerDay: Double = 0.01

    /// `nonisolated` so the singleton can be initialized from any
    /// thread. The default `chatCall` is supplied at the property
    /// declaration site (just above) which keeps this body empty.
    /// LLMRouter rewires `chatCall` at app launch via `setChatCall`.
    nonisolated private init() {}

    /// Swap in a different LLM call (CLI path, custom HTTP, etc.).
    /// Settings UI calls this whenever the user changes provider.
    func setChatCall(_ call: @escaping ChatCall) {
        self.chatCall = call
    }

    // MARK: - Public API

    /// Answer a question. Returns the assistant turn (text + source
    /// run IDs) so the UI can render citations.
    func ask(_ question: String) async throws -> AssistantTurn {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return AssistantTurn(
                text: "Ask me anything about your past transcriptions.",
                sourceRunIDs: [],
                usedRecencyFallback: false
            )
        }

        let runCount = memory.runCount()
        guard runCount > 0 else {
            return AssistantTurn(
                text: "You haven't dictated anything yet. Hold Fn and speak — once you've got a few transcripts I can answer questions about them.",
                sourceRunIDs: [],
                usedRecencyFallback: false
            )
        }

        // 1. Semantic candidates.
        let semantic = await semanticCandidates(for: q)
        // 2. Lexical candidates.
        let lexical = memory.searchFTS(query: q, limit: topKPerChannel)
        // 3. Merge.
        var merged = mergeScores(semantic: semantic, lexical: lexical)
        // 4. Entity boost.
        applyEntityBoost(question: q, scores: &merged)
        // 5. Recency decay.
        applyRecencyDecay(scores: &merged)

        // 6. Take top-K with positive score; fall back to recency if
        //    nothing scored.
        let usedRecencyFallback: Bool
        let topHits: [(runID: String, score: Double)]
        if merged.isEmpty {
            usedRecencyFallback = true
            topHits = memory.recentRuns(limit: finalK).map { (runID: $0.id, score: 0.0) }
        } else {
            let positive = merged
                .filter { $0.value > 0.001 }
                .sorted { $0.value > $1.value }
                .prefix(finalK)
                .map { (runID: $0.key, score: $0.value) }
            if positive.isEmpty {
                usedRecencyFallback = true
                topHits = memory.recentRuns(limit: finalK).map { (runID: $0.id, score: 0.0) }
            } else {
                usedRecencyFallback = false
                topHits = Array(positive)
            }
        }

        // 7. Hydrate the hits + send to LLM.
        let sources = hydrateSources(topHits)
        guard !sources.isEmpty else {
            return AssistantTurn(
                text: "Your transcript history is empty — try dictating something first.",
                sourceRunIDs: [],
                usedRecencyFallback: false
            )
        }

        let answer = try await callLLM(question: q, sources: sources, usedRecencyFallback: usedRecencyFallback)
        return AssistantTurn(
            text: answer,
            sourceRunIDs: sources.map { $0.runID },
            usedRecencyFallback: usedRecencyFallback
        )
    }

    // MARK: - Retrieval stages

    /// Cosine-similarity ranked candidates. Computed entirely in Swift
    /// against the embeddings table. For corpora below ~10K runs this
    /// is microsecond-fast; beyond that we'd want sqlite-vec / HNSW.
    private func semanticCandidates(for question: String) async -> [(runID: String, score: Double)] {
        // Best-effort: if embeddings aren't ready, just return empty
        // and let lexical carry the retrieval.
        let qVec: [Float]
        do {
            let result = try await embedder.embed(question)
            qVec = result.vec
        } catch {
            return []
        }

        let rows = memory.allEmbeddings()
        guard !rows.isEmpty else { return [] }

        // Only compare against vectors with the SAME dim (different
        // models produce different sizes — mixing them gives garbage
        // scores). Mid-migration moments hit this path.
        let scored: [(String, Double)] = rows.compactMap { row in
            guard row.vec.count == qVec.count else { return nil }
            let sim = Double(EmbeddingService.cosine(qVec, row.vec))
            return sim > 0.05 ? (row.runID, sim) : nil
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topKPerChannel)
            .map { (runID: $0.0, score: $0.1) }
    }

    /// Merge semantic + lexical into a single score per runID. Both
    /// channels' raw scores live on different scales, so we
    /// min-max normalize each to 0-1 first, then take the weighted sum.
    /// Weights favor semantic slightly (0.6) but lexical still pulls
    /// strong literal matches out of the pile.
    private func mergeScores(
        semantic: [(runID: String, score: Double)],
        lexical: [MemoryStore.SearchHit]
    ) -> [String: Double] {
        var scores: [String: Double] = [:]

        // Semantic: already 0-1 (cosine). Just weight it.
        for hit in semantic {
            scores[hit.runID, default: 0] += 0.6 * hit.score
        }

        // Lexical: BM25 is a distance (lower = better). Convert to
        // similarity by max-normalizing and inverting. We use max+1 so
        // the worst-scored item gets ~0 instead of going negative.
        if let worst = lexical.map(\.bm25).max() {
            for hit in lexical {
                // Lower bm25 → larger sim. Floor at 0 in case of
                // pathological inputs.
                let sim = max(0, (worst - hit.bm25) / max(1, worst))
                scores[hit.runID, default: 0] += 0.4 * sim
            }
        }
        return scores
    }

    /// Bonus for transcripts that mention an entity named in the
    /// question. We don't pre-tokenize the entities — they're matched as
    /// case-insensitive substrings, so "kubectl" in the question hits
    /// the "kubectl" entity even if a runQuestion typed "Kubectl".
    private func applyEntityBoost(question: String, scores: inout [String: Double]) {
        let qLower = question.lowercased()
        let entities = memory.allEntities(limit: 500)
        for entity in entities {
            let label = entity.label.lowercased()
            guard label.count >= 3, qLower.contains(label) else { continue }
            for runID in memory.runIDs(forEntity: entity.id) {
                scores[runID, default: 0] += 0.3
            }
        }
    }

    /// Multiply scores by an exponential decay based on age. Acts as a
    /// tiebreak between items with otherwise-equal merged scores.
    private func applyRecencyDecay(scores: inout [String: Double]) {
        let now = Date().timeIntervalSince1970
        for (runID, score) in scores {
            guard let run = memory.getRun(id: runID) else { continue }
            let ageDays = max(0, (now - run.createdAt.timeIntervalSince1970) / 86400)
            let decay = exp(-recencyDecayPerDay * ageDays)
            scores[runID] = score * decay
        }
    }

    private struct HydratedSource {
        let runID: String
        let text: String
        let createdAt: Date
        let score: Double
    }

    private func hydrateSources(_ hits: [(runID: String, score: Double)]) -> [HydratedSource] {
        hits.compactMap { hit in
            guard
                let run = memory.getRun(id: hit.runID),
                let text = memory.transcriptText(for: hit.runID),
                !text.isEmpty
            else { return nil }
            return HydratedSource(
                runID: hit.runID,
                text: text,
                createdAt: run.createdAt,
                score: hit.score
            )
        }
    }

    // MARK: - LLM call

    private func callLLM(
        question: String,
        sources: [HydratedSource],
        usedRecencyFallback: Bool
    ) async throws -> String {
        // Stuff sources into the prompt, numbered for inline citation.
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let context = sources.enumerated().map { idx, s in
            let date = formatter.string(from: s.createdAt)
            let body = s.text.prefix(800)
            return "[Source \(idx + 1) · \(date)]\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        let retrievalNote = usedRecencyFallback
            ? "The user's question didn't strongly match any specific transcript. The sources below are simply their most recent dictations. Give a brief, honest summary of what they appear to be about — don't pretend to directly answer the question."
            : "Answer the user's question using ONLY the transcripts. Be specific. Cite sources inline as [1], [2], etc."

        let system = """
        You are VoiceFlow's memory assistant. You help the user recall \
        what they've dictated.

        \(retrievalNote)

        If the transcripts don't contain enough to answer, say so honestly \
        — never invent details. Keep responses to 2-4 sentences unless the \
        user explicitly asks for more detail.
        """

        let userBlock = """
        Sources:
        \(context)

        Question: \(question)
        """

        let result = try await chatCall(system, userBlock)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no answer returned)" : trimmed
    }

    // MARK: - Types

    struct AssistantTurn {
        let text: String
        let sourceRunIDs: [String]
        let usedRecencyFallback: Bool
    }
}
