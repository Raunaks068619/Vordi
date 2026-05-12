import Foundation
import Combine

// MARK: - Data model

/// A node in the user's transcription knowledge graph. Each node represents
/// a deduplicated entity (person, project, tool, concept, command, place)
/// mentioned across one or more transcripts.
struct KnowledgeNode: Identifiable, Codable, Equatable {
    /// Slug used as id — lowercased, normalized label. Stable across
    /// incremental extractions so the graph cache can be merged.
    let id: String
    /// Display label — preserves the user's typical casing of the term.
    var label: String
    var type: KnowledgeEntityType
    /// Total number of transcripts this entity has appeared in. Drives
    /// node size in the force-directed layout (more mentions = bigger).
    var mentions: Int
    /// UUIDs of the runs this entity was extracted from. Used by the chat
    /// retriever to map back to source transcripts.
    var runIDs: [String]
}

/// Weighted, undirected edge. `weight` = number of transcripts in which
/// both endpoints co-occurred. Higher weight = thicker/shorter spring in
/// the force layout.
struct KnowledgeEdge: Codable, Equatable, Hashable {
    let nodeA: String   // node id
    let nodeB: String   // node id
    var weight: Int

    /// Canonicalize endpoint order so {A,B} == {B,A} for hashing/dedup.
    static func canonical(_ a: String, _ b: String) -> KnowledgeEdge {
        a < b
            ? KnowledgeEdge(nodeA: a, nodeB: b, weight: 1)
            : KnowledgeEdge(nodeA: b, nodeB: a, weight: 1)
    }
}

enum KnowledgeEntityType: String, Codable, CaseIterable {
    case person
    case project
    case tool
    case concept
    case command
    case place
    case other

    /// Color for rendering. Returned as RGB tuple to avoid pulling SwiftUI
    /// into the service layer. The view applies it via Color(red:green:blue:).
    var rgb: (Double, Double, Double) {
        switch self {
        case .person:   return (0.95, 0.55, 0.35)   // warm orange
        case .project:  return (0.45, 0.70, 0.95)   // sky blue
        case .tool:     return (0.65, 0.55, 0.95)   // soft purple
        case .concept:  return (0.40, 0.80, 0.65)   // mint teal
        case .command:  return (0.95, 0.45, 0.55)   // coral
        case .place:    return (0.85, 0.80, 0.40)   // sand
        case .other:    return (0.65, 0.65, 0.70)   // neutral grey
        }
    }
}

/// Complete graph snapshot — what the view renders. Layout positions
/// are NOT persisted (force sim re-runs every session for a clean
/// start; users find that more pleasant than restoring stale positions).
struct KnowledgeGraph: Codable {
    var nodes: [KnowledgeNode]
    var edges: [KnowledgeEdge]
    /// IDs of runs already processed. Lets `refresh` skip work on
    /// runs whose entities are already in the cache.
    var indexedRunIDs: Set<String>
    /// Schema version. Bump when changing on-disk shape so the cache
    /// auto-invalidates on app upgrade rather than fighting stale data.
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    static var empty: KnowledgeGraph {
        KnowledgeGraph(nodes: [], edges: [], indexedRunIDs: [], schemaVersion: currentSchemaVersion)
    }
}

/// One turn in the right-side chat panel.
struct KnowledgeChatTurn: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    /// Run IDs the answer referenced — surfaces as "Sources" chips below
    /// the assistant response so the user can verify provenance.
    var sourceRunIDs: [String]
    let createdAt: Date

    enum Role: String { case user, assistant }

    init(role: Role, text: String, sourceRunIDs: [String] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.sourceRunIDs = sourceRunIDs
        self.createdAt = Date()
    }
}

// MARK: - Service

/// Builds, caches, and serves the user's knowledge graph.
///
/// **Build strategy** (matches the user's "on-demand + cached" choice):
/// when `refresh()` is called, the service diffs `RunStore.summaries`
/// against `graph.indexedRunIDs`, batch-extracts entities for the new
/// runs via LLM, then merges into the cached graph. Cache persists to
/// `~/Library/Application Support/VoiceFlow/knowledge_graph.json`.
///
/// **Chat strategy**: keyword-overlap retrieval. Cheap, no embeddings
/// needed. Picks the top-K transcripts whose word set overlaps most with
/// the question, stuffs them into an LLM prompt, returns the answer.
///
/// **Why not embeddings**: a Mac laptop doing 30-300 transcript embeddings
/// per app launch would either spend money on OpenAI calls every cold
/// start, or pull in a 50MB embedding model dependency. Keyword overlap
/// has comparable retrieval quality at conversational lengths and costs $0.
@MainActor
final class KnowledgeGraphService: ObservableObject {
    static let shared = KnowledgeGraphService()

    @Published private(set) var graph: KnowledgeGraph = .empty
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var lastIndexError: String?

    private let llm: LLMService
    private let runStore: RunStore
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Max transcripts to embed in a single extraction call. Each call
    /// sees ~3-4k chars of transcript context so we stay well under the
    /// 8k input budget on every supported backend.
    private let extractionBatchSize = 8

    /// Max transcripts retrieved for a single chat answer. K=5 balances
    /// "broad enough to find the right one" vs "small enough to stay
    /// under prompt budget."
    private let retrievalK = 5

    private init(llm: LLMService = .shared, runStore: RunStore = .shared) {
        self.llm = llm
        self.runStore = runStore
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        loadCache()
    }

    // MARK: - Public API

    /// Idempotent: extract entities from any un-indexed runs and merge
    /// into the cached graph. Reports progress via @Published flags.
    ///
    /// Concurrency: must be called from the main actor (forced by class
    /// isolation). LLM calls happen async on background threads via the
    /// awaiting bridge.
    func refresh() async {
        guard !isIndexing else { return }
        isIndexing = true
        lastIndexError = nil

        defer { isIndexing = false }

        let summaries = runStore.summaries
        let unindexed = summaries.filter { !graph.indexedRunIDs.contains($0.id.uuidString) }
        guard !unindexed.isEmpty else { return }

        // Resolve transcripts for the un-indexed summaries. We load run
        // detail because the summary's previewText may be truncated by
        // older versions of the indexer.
        let transcripts = unindexed.compactMap { summary -> RunTranscript? in
            // Synchronous file IO — these are tiny JSON blobs. Doing it
            // off the main thread would require a serial queue dance
            // for very modest benefit.
            guard let run = runStore.loadRun(id: summary.id) else { return nil }
            let text = run.postProcessing?.finalText
                ?? run.transcription?.rawText
                ?? summary.previewText
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return RunTranscript(runID: summary.id.uuidString, text: trimmed)
        }
        guard !transcripts.isEmpty else {
            // Mark all empty runs as indexed so we don't keep retrying.
            unindexed.forEach { graph.indexedRunIDs.insert($0.id.uuidString) }
            persist()
            return
        }

        // Batch through the transcripts. Failures on a single batch
        // don't poison the whole index — we just skip that batch and
        // try again on the next refresh.
        let batches = stride(from: 0, to: transcripts.count, by: extractionBatchSize).map {
            Array(transcripts[$0..<min($0 + extractionBatchSize, transcripts.count)])
        }

        var anyExtractionSucceeded = false
        for batch in batches {
            do {
                let extracted = try await extractEntities(from: batch)
                merge(extracted)
                anyExtractionSucceeded = true
                // Persist after each batch so a mid-flight failure
                // doesn't lose progress.
                persist()
            } catch {
                lastIndexError = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                // Keep going on later batches — partial progress is
                // better than aborting the whole indexing run.
            }
        }

        if !anyExtractionSucceeded && lastIndexError == nil {
            lastIndexError = "Extraction returned no entities."
        }
    }

    /// Answer a question over the user's transcription history. Uses
    /// keyword-overlap retrieval to find relevant transcripts, then
    /// asks the user's chosen polish backend for the answer.
    func ask(_ question: String) async throws -> KnowledgeChatTurn {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return KnowledgeChatTurn(
                role: .assistant,
                text: "Ask me anything about your past transcriptions.",
                sourceRunIDs: []
            )
        }

        // Retrieve top-K transcripts by keyword overlap with the
        // question. Returns (runID, text, score) tuples.
        let allSummaries = runStore.summaries
        let scored: [(summary: RunSummary, text: String, score: Int)] = allSummaries
            .compactMap { summary -> (summary: RunSummary, text: String, score: Int)? in
                guard let run = runStore.loadRun(id: summary.id) else { return nil }
                let text = run.postProcessing?.finalText
                    ?? run.transcription?.rawText
                    ?? summary.previewText
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let score = Self.keywordOverlapScore(question: q, text: trimmed)
                return score > 0 ? (summary: summary, text: trimmed, score: score) : nil
            }
            .sorted { $0.score > $1.score }
            .prefix(retrievalK)
            .map { $0 }

        if scored.isEmpty {
            return KnowledgeChatTurn(
                role: .assistant,
                text: "I couldn't find any past transcriptions relevant to that question yet. Try dictating something on this topic first.",
                sourceRunIDs: []
            )
        }

        // Build the LLM prompt. Sources are numbered so the model can
        // reference them in the answer.
        let context = scored.enumerated().map { (idx, hit) -> String in
            let dateStr = DateFormatter.kgShort.string(from: hit.summary.createdAt)
            let body = hit.text.prefix(600)
            return "[Source \(idx + 1) · \(dateStr)]\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        let systemPrompt = """
        You are VoiceFlow's memory assistant. You answer the user's questions \
        using ONLY the transcripts provided below. If the answer isn't \
        in the transcripts, say so honestly — do NOT invent. Cite sources \
        inline as "[1]", "[2]" etc. matching the source numbers.

        Keep answers short (2-4 sentences) unless the user explicitly asks \
        for detail.
        """

        let userPrompt = """
        Sources:
        \(context)

        Question: \(q)
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user,   content: userPrompt),
            ],
            temperature: 0.2,
            maxTokens: 400,
            maxAttempts: 2,
            purpose: "knowledge_graph_chat"
        )

        let response = try await llm.complete(request)
        return KnowledgeChatTurn(
            role: .assistant,
            text: response.content.isEmpty
                ? "(no answer returned)"
                : response.content,
            sourceRunIDs: scored.map { $0.summary.id.uuidString }
        )
    }

    /// Reset everything — useful for "rebuild from scratch" UI affordance
    /// and during development. Wipes the cache file and re-extracts.
    func reset() async {
        graph = .empty
        persist()
        await refresh()
    }

    // MARK: - Internals

    private struct RunTranscript {
        let runID: String
        let text: String
    }

    /// LLM-driven entity extraction. Returns one ExtractionResult per
    /// transcript in the input batch — `runID` is propagated through so
    /// the merge step knows which transcript an entity came from.
    private func extractEntities(from batch: [RunTranscript]) async throws -> [ExtractionResult] {
        let transcriptsBlock = batch.enumerated().map { (idx, t) -> String in
            "<transcript id=\"\(idx)\" runID=\"\(t.runID)\">\n\(t.text.prefix(1500))\n</transcript>"
        }.joined(separator: "\n\n")

        let systemPrompt = """
        You extract a compact knowledge graph from voice transcripts.

        For each <transcript>, identify the most important named entities:
          - person   — actual people by name
          - project  — project / product / feature names
          - tool     — software, frameworks, libraries, services
          - command  — shell or code commands (e.g. "kubectl get pods")
          - concept  — domain-specific ideas, techniques, terms
          - place    — physical locations
          - other    — anything important that doesn't fit

        Rules:
          - At most 6 entities per transcript. Pick the most contentful.
          - Skip generic words ("thing", "stuff", "today").
          - Use the user's casing for `label`.
          - `id` MUST be lowercase, alphanumerics + hyphens only.
          - If a transcript has no extractable entity, return an empty
            entities array for it.

        Respond with ONLY a JSON array, no prose, no markdown fences. Shape:
        [
          {
            "transcriptId": 0,
            "runID": "<echo the runID>",
            "entities": [
              { "id": "kubectl", "label": "kubectl", "type": "tool" }
            ]
          }
        ]
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: transcriptsBlock),
            ],
            temperature: 0.0,
            maxTokens: 1200,
            maxAttempts: 2,
            purpose: "knowledge_graph_extract"
        )

        let response = try await llm.complete(request)
        return try Self.parseExtractionResponse(response.content, batch: batch)
    }

    private static func parseExtractionResponse(
        _ raw: String,
        batch: [RunTranscript]
    ) throws -> [ExtractionResult] {
        // LLMs sometimes wrap JSON in ```json fences despite instructions.
        // Strip them defensively before parsing.
        var cleaned = raw
        if let r = cleaned.range(of: "```json") {
            cleaned.removeSubrange(cleaned.startIndex..<r.upperBound)
        }
        if let r = cleaned.range(of: "```", options: .backwards) {
            cleaned = String(cleaned[..<r.lowerBound])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.parseError("extraction output not UTF-8")
        }

        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.parseError("extraction output not a JSON array")
        }

        var results: [ExtractionResult] = []
        for item in outer {
            let runID: String
            if let echoed = item["runID"] as? String, !echoed.isEmpty {
                runID = echoed
            } else if let tid = item["transcriptId"] as? Int, tid < batch.count {
                runID = batch[tid].runID
            } else {
                continue
            }

            let rawEntities = (item["entities"] as? [[String: Any]]) ?? []
            let entities = rawEntities.compactMap { e -> ExtractedEntity? in
                guard
                    let label = (e["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !label.isEmpty
                else { return nil }
                let rawId = (e["id"] as? String) ?? label
                let normalizedID = Self.normalizeID(rawId)
                guard !normalizedID.isEmpty else { return nil }
                let type = KnowledgeEntityType(rawValue: (e["type"] as? String) ?? "other") ?? .other
                return ExtractedEntity(id: normalizedID, label: label, type: type)
            }

            results.append(ExtractionResult(runID: runID, entities: entities))
        }
        return results
    }

    /// Merge an extraction batch into the cached graph. Idempotent on the
    /// runID — re-extracting an already-indexed run is a no-op.
    private func merge(_ results: [ExtractionResult]) {
        var nodeMap: [String: KnowledgeNode] = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var edgeMap: [String: KnowledgeEdge] = Dictionary(uniqueKeysWithValues: graph.edges.map {
            ("\($0.nodeA)::\($0.nodeB)", $0)
        })

        for result in results {
            // Idempotency: skip if we've seen this runID before.
            if graph.indexedRunIDs.contains(result.runID) { continue }

            // Nodes
            for entity in result.entities {
                if var existing = nodeMap[entity.id] {
                    if !existing.runIDs.contains(result.runID) {
                        existing.runIDs.append(result.runID)
                        existing.mentions += 1
                    }
                    // Keep the first-seen label and type stable.
                    nodeMap[entity.id] = existing
                } else {
                    nodeMap[entity.id] = KnowledgeNode(
                        id: entity.id,
                        label: entity.label,
                        type: entity.type,
                        mentions: 1,
                        runIDs: [result.runID]
                    )
                }
            }

            // Edges — every pair of entities in the same transcript.
            let ids = result.entities.map { $0.id }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let edge = KnowledgeEdge.canonical(ids[i], ids[j])
                    let key = "\(edge.nodeA)::\(edge.nodeB)"
                    if var existing = edgeMap[key] {
                        existing.weight += 1
                        edgeMap[key] = existing
                    } else {
                        edgeMap[key] = edge
                    }
                }
            }

            graph.indexedRunIDs.insert(result.runID)
        }

        graph.nodes = Array(nodeMap.values).sorted { $0.mentions > $1.mentions }
        graph.edges = Array(edgeMap.values)
    }

    // MARK: - Persistence

    private var storeURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("VoiceFlow", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    }

    private func loadCache() {
        let dir = storeURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode(KnowledgeGraph.self, from: data)
        else { return }

        // Schema-version guard. If we shipped a breaking change, drop
        // the cache instead of trying to limp along with stale shape.
        if decoded.schemaVersion == KnowledgeGraph.currentSchemaVersion {
            graph = decoded
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(graph) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Retrieval helpers

    /// Lowercased word set with stopwords removed. Used both for
    /// keyword-overlap scoring and as a cheap canonical "shape" of a
    /// transcript. O(n) in characters.
    private static func tokens(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let words = String(mapped)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        return Set(words)
    }

    /// Symmetric token overlap. We weight question tokens slightly higher
    /// because a transcript matching all question tokens is the strongest
    /// retrieval signal.
    private static func keywordOverlapScore(question: String, text: String) -> Int {
        let qTokens = tokens(question)
        guard !qTokens.isEmpty else { return 0 }
        let tTokens = tokens(text)
        guard !tTokens.isEmpty else { return 0 }
        return qTokens.intersection(tTokens).count
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "this", "that",
        "with", "have", "from", "they", "what", "when", "where", "which", "their",
        "would", "could", "should", "about", "into", "more", "than", "some", "out",
        "was", "were", "had", "has", "did", "does", "doing", "been", "being",
        "all", "any", "can", "her", "him", "his", "she", "our", "ours", "ourselves",
        "let", "get", "got", "say", "said", "see", "seen", "way", "ways",
    ]

    private static func normalizeID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == " " || scalar == "_" {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed
    }

    // Intermediate type — LLM extraction output before merging into graph.
    private struct ExtractedEntity {
        let id: String
        let label: String
        let type: KnowledgeEntityType
    }
    private struct ExtractionResult {
        let runID: String
        let entities: [ExtractedEntity]
    }
}

private extension DateFormatter {
    static let kgShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
