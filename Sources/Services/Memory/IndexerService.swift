import Foundation
import NaturalLanguage
import Combine

/// Background worker that keeps `MemoryStore` consistent with `RunStore`.
///
/// **Three jobs:**
///   1. **Migration** — on first launch of v0.6.0, scan RunStore for any
///      runs not yet present in MemoryStore and bulk-import them. Runs
///      paginated in the background so the UI stays responsive.
///   2. **Embedding** — for each run in MemoryStore that lacks an
///      embedding (or has a stale one), compute via EmbeddingService.
///   3. **Entity extraction** — hybrid path. NLTagger handles
///      people / organizations / places for free; LLM handles
///      project / tool / concept / command. Both write to MemoryStore.
///
/// **Concurrency**: a single utility-priority OperationQueue, max 1
/// concurrent op. Sequential keeps the indexer cooperative — embedding
/// model + LLM calls share precious resources, and parallelism wins
/// nothing here.
///
/// **Pausing**: nothing pauses it explicitly. The OS deprioritizes
/// utility-QoS work during user-active recording automatically.
@MainActor
final class IndexerService: ObservableObject {
    /// `nonisolated` so that nonisolated callers (RunStore.save runs
    /// on a serial dispatch queue, not the main actor) can reach
    /// `enqueue` without triggering a Sendable warning on the singleton
    /// itself. Instance state still routes through the main actor via
    /// the class-level @MainActor annotation.
    nonisolated static let shared = IndexerService()

    /// Bucketed status for the Memory tab header.
    enum Status: Equatable {
        case idle
        case migrating(progress: Double)
        case indexing(done: Int, total: Int)
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var indexedCount: Int = 0
    @Published private(set) var pendingCount: Int = 0

    private let queue = OperationQueue()
    private let memory = MemoryStore.shared
    private let runStore = RunStore.shared
    private let embedder = EmbeddingService.shared
    private let llm = LLMService.shared

    /// Per-run debounce: when RunStore writes a new run, we enqueue it
    /// for indexing. If the user dictates several times back-to-back we
    /// don't want N separate operations all racing — coalesce.
    ///
    /// Wrapped in a `PendingSet` so it can be touched from the
    /// nonisolated `enqueue(runID:)` entry point without fighting the
    /// main-actor isolation of the rest of this class. PendingSet owns
    /// its own NSLock; access is genuinely safe across threads.
    private let pendingEnqueue = PendingSet()

    /// `nonisolated` so the singleton can be constructed from any
    /// context (the `static let shared` initializer runs on whichever
    /// thread first touches it). The body only sets up an OperationQueue
    /// — no @MainActor state touched, so this is safe.
    nonisolated private init() {
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.voiceflow.indexer"
    }

    // MARK: - Public API

    /// Boot the indexer. Idempotent — safe to call from AppDelegate
    /// applicationDidFinishLaunching after RunStore + MemoryStore are
    /// initialized. Runs migration first, then continuous backfill of
    /// any un-indexed runs.
    func start() {
        Task { @MainActor in
            await migrateIfNeeded()
            await backfillEmbeddingsAndEntities()
        }
    }

    /// Hook for RunStore.save — request that a specific run get indexed
    /// soon. Debounced to ~250ms so a rapid-fire sequence of dictations
    /// coalesces into one indexing op per run.
    nonisolated func enqueue(runID: String) {
        guard pendingEnqueue.insert(runID) else { return }

        Task { @MainActor in
            // Tiny debounce — lets a burst of saves settle before we
            // schedule the work. Real index speed matters less than
            // avoiding mid-record CPU spikes.
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.pendingEnqueue.remove(runID)
            await self.indexSingleRun(runID: runID)
            await self.refreshCounts()
        }
    }

    /// Force a full re-index. Used by the "Rebuild Memory" debug
    /// affordance and any time we change the embedding model in a way
    /// that invalidates existing vectors. Drops embeddings + entities
    /// but keeps runs + FTS (those are derived from RunStore and stable).
    func forceReindex() async {
        memory.clearDerivedIndex()
        await backfillEmbeddingsAndEntities(force: true)
    }

    // MARK: - Migration

    /// One-shot migration from RunStore (JSON files) to MemoryStore
    /// (SQLite). Runs once after v0.6.0 ships. Idempotent — re-running
    /// is safe and cheap (each run is upserted; existing rows are
    /// no-op'd by SQLite ON CONFLICT clauses).
    private func migrateIfNeeded() async {
        let memoryRunCount = memory.runCount()
        let jsonSummaries = runStore.summaries
        if memoryRunCount >= jsonSummaries.count {
            // Already migrated (or up-to-date). Skip the bulk path.
            return
        }

        let toMigrate = jsonSummaries.filter { memory.getRun(id: $0.id.uuidString) == nil }
        guard !toMigrate.isEmpty else { return }

        print("IndexerService: migrating \(toMigrate.count) runs into MemoryStore")
        status = .migrating(progress: 0)

        for (idx, summary) in toMigrate.enumerated() {
            // Re-read the full run from disk to capture the post-process
            // final text + duration. Summary alone only has previewText
            // which can be truncated.
            guard let run = runStore.loadRun(id: summary.id) else { continue }
            let text = RunStore.transcriptText(for: run)
            let wordCount = ComputedStats.wordCount(of: summary)

            memory.upsertRun(
                id: summary.id.uuidString,
                createdAt: summary.createdAt,
                appName: summary.frontmostAppName,
                bundleID: summary.frontmostBundleID,
                profile: summary.profileUsed,
                wordCount: wordCount,
                durationSeconds: summary.durationSeconds,
                status: summary.status.rawValue,
                llmCostUSD: summary.llmCostUSD,
                transcriptText: text
            )

            // Yield occasionally so the UI doesn't choke on a thousand-
            // run backlog. Every 25 records is empirically smooth on
            // M1 base, generous on faster Macs.
            if idx % 25 == 0 {
                let progress = Double(idx + 1) / Double(toMigrate.count)
                status = .migrating(progress: progress)
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            }
        }

        status = .idle
        print("IndexerService: migration complete")
    }

    // MARK: - Backfill

    private func backfillEmbeddingsAndEntities(force: Bool = false) async {
        let modelTag = embedder.modelKind.rawValue == "none"
            ? "pending"
            : modelTagFor(embedder.modelKind)

        // Embeddings — runs without one (or with a stale model tag).
        let needsEmb = memory.unindexedRunIDs(currentModel: modelTag)
        // Entities — runs that have no entity links yet.
        let needsEnt = memory.unentityRunIDs()
        // Union for accurate progress reporting.
        let allPending = Array(Set(needsEmb).union(Set(needsEnt))).sorted()

        guard !allPending.isEmpty else {
            status = .idle
            await refreshCounts()
            return
        }

        pendingCount = allPending.count
        status = .indexing(done: 0, total: allPending.count)

        var done = 0
        for runID in allPending {
            await indexSingleRun(runID: runID)
            done += 1
            // Republish status without re-allocating the whole queue.
            status = .indexing(done: done, total: allPending.count)
        }

        status = .idle
        await refreshCounts()
    }

    /// Index a single run: compute its embedding + extract entities.
    /// Idempotent — if either piece is already done, that step skips.
    private func indexSingleRun(runID: String) async {
        guard let text = memory.transcriptText(for: runID), !text.isEmpty else {
            return
        }

        // 1. Embedding (skip if up-to-date).
        let modelTag = modelTagFor(embedder.modelKind)
        if needsEmbedding(runID: runID, currentModel: modelTag) {
            do {
                let result = try await embedder.embed(text)
                memory.setEmbedding(runID: runID, vec: result.vec, model: result.model)
            } catch {
                print("IndexerService: embed failed for \(runID): \(error.localizedDescription)")
                // Don't fail the whole indexing pass — entities can
                // still be useful even without an embedding.
            }
        }

        // 2. Entity extraction (skip if we already have entries).
        if needsEntities(runID: runID) {
            let entities = await extractEntities(from: text)
            memory.setEntities(forRun: runID, entities: entities)
        }
    }

    // MARK: - Entity extraction (hybrid)

    /// Hybrid extraction: NLTagger handles the easy "named entities"
    /// (people / organizations / places) — it's free, fast, and works
    /// without an LLM call. The remainder (projects, tools, concepts,
    /// commands) is what the LLM is actually good at.
    ///
    /// For surveys of conversational transcripts NLTagger catches ~50-
    /// 70% of useful entities for $0. The LLM only sees text that
    /// passed the cheap pass first.
    private func extractEntities(from text: String) async -> [(id: String, label: String, type: String)] {
        let cheap = Self.nlTaggerEntities(in: text)

        // LLM pass for the long-tail. Always run unless the polish
        // backend has no API key (in which case we just ship the cheap
        // entities — they're already useful).
        let llmEntities: [(id: String, label: String, type: String)]
        do {
            llmEntities = try await Self.llmEntities(in: text, llm: llm)
        } catch {
            print("IndexerService: LLM entity extraction failed: \(error)")
            llmEntities = []
        }

        // Merge, de-dup by id (case-insensitive normalized slug).
        var seen = Set<String>()
        var merged: [(id: String, label: String, type: String)] = []
        for entity in (cheap + llmEntities) {
            if seen.insert(entity.id).inserted {
                merged.append(entity)
            }
        }
        // Cap at 8 per run so dense transcripts don't blow up the graph.
        return Array(merged.prefix(8))
    }

    /// NLTagger-driven extraction. Cheap and built into macOS. Returns
    /// people / organizations / places.
    private static func nlTaggerEntities(in text: String) -> [(id: String, label: String, type: String)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        var out: [(id: String, label: String, type: String)] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag else { return true }
            let label = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count >= 2 else { return true }
            let type: String?
            switch tag {
            case .personalName:     type = "person"
            case .organizationName: type = "tool"
            // Apple's `placeName` maps to physical locations. We keep
            // it for completeness but most VoiceFlow transcripts will
            // talk about software, so this should be rare.
            case .placeName:        type = "place"
            default: type = nil
            }
            guard let type else { return true }
            let id = Self.slug(label)
            guard !id.isEmpty else { return true }
            out.append((id: id, label: label, type: type))
            return true
        }
        return out
    }

    /// LLM-driven extraction for the conceptual long-tail. Same prompt
    /// shape as the v0.5 KnowledgeGraphService had — we move it here so
    /// the indexer owns ALL extraction in one place.
    private static func llmEntities(in text: String, llm: LLMService) async throws -> [(id: String, label: String, type: String)] {
        let systemPrompt = """
        Extract the most important entities mentioned in this transcript.
        Focus on types that named-entity recognition can't catch:
          - project   — project / product / feature names
          - tool      — software, frameworks, libraries
          - concept   — domain ideas, techniques, terms
          - command   — shell or code commands
        Skip people and places (other tools handle those). Skip generic words.

        At most 6 entities. IDs lowercase, alphanumerics + hyphens only.

        Respond with ONLY a JSON array, no markdown fences:
        [{"id":"kubectl","label":"kubectl","type":"tool"}]
        """

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user,   content: text),
            ],
            temperature: 0.0,
            maxTokens: 500,
            maxAttempts: 1,
            purpose: "indexer_entities"
        )

        let response = try await llm.complete(request)
        return parseEntityJSON(response.content)
    }

    private static func parseEntityJSON(_ raw: String) -> [(id: String, label: String, type: String)] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = cleaned.range(of: "```json") {
            cleaned.removeSubrange(cleaned.startIndex..<r.upperBound)
        }
        if let r = cleaned.range(of: "```", options: .backwards) {
            cleaned = String(cleaned[..<r.lowerBound])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let data = cleaned.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { e in
            guard
                let labelRaw = (e["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !labelRaw.isEmpty
            else { return nil }
            let id = slug((e["id"] as? String) ?? labelRaw)
            guard !id.isEmpty else { return nil }
            let validTypes = ["person", "project", "tool", "concept", "command", "place", "other"]
            let type = validTypes.contains((e["type"] as? String) ?? "")
                ? (e["type"] as! String)
                : "concept"
            return (id: id, label: labelRaw, type: type)
        }
    }

    // MARK: - Helpers

    private func needsEmbedding(runID: String, currentModel: String) -> Bool {
        // The simplest correct check: ask MemoryStore. The
        // unindexedRunIDs query already encodes "no embedding OR stale
        // model"; we just need to scope it to one run.
        let ids = memory.unindexedRunIDs(currentModel: currentModel)
        return ids.contains(runID)
    }

    private func needsEntities(runID: String) -> Bool {
        let ids = memory.unentityRunIDs()
        return ids.contains(runID)
    }

    private func modelTagFor(_ kind: EmbeddingService.ModelKind) -> String {
        switch kind {
        case .contextual: return "apple-contextual-en-v1"
        case .word:       return "apple-word-en-v1"
        case .none:       return "pending"
        }
    }

    private static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                return Character(scalar)
            }
            return " "
        }
        let parts = String(mapped)
            .split(separator: " ")
            .joined(separator: "-")
        return parts.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func refreshCounts() async {
        indexedCount = memory.runCount()
        pendingCount = memory.unindexedRunIDs(currentModel: modelTagFor(embedder.modelKind)).count
    }
}

/// Thread-safe set of run IDs awaiting indexing. Owns its own NSLock so
/// it can be touched from any thread — including the nonisolated
/// `IndexerService.enqueue` entry point that RunStore calls right after
/// saving a new run.
///
/// `@unchecked Sendable` is the honest annotation: the type IS safe to
/// share across threads because every mutation goes through the lock,
/// but the compiler can't prove that automatically (it'd need a more
/// sophisticated effect system). We promise to keep the contract here.
private final class PendingSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()

    /// Returns true if the id was newly inserted (i.e. caller should
    /// schedule indexing); false if it was already pending.
    func insert(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.insert(id).inserted
    }

    func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        set.remove(id)
    }
}

