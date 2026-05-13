import Foundation
import NaturalLanguage
import Combine

/// On-device sentence-embedding service. The whole point: turn a
/// transcript into a fixed-size vector so we can find "what was I
/// working on with kubernetes?" → transcripts that say "I built a k8s
/// deployment" without any keyword overlap.
///
/// **Model selection** (decided at init time, broadcast via `modelKind`):
///   - macOS 14+: `NLContextualEmbedding` for English. Transformer-based,
///     ~768-dim vectors, captures semantics decently for conversational
///     text. Requires a one-time on-device model download (~50MB).
///   - macOS 13:  `NLEmbedding` word vectors (300-dim, GloVe-style),
///     averaged across the transcript tokens. Weaker than contextual but
///     ships with the OS — zero download.
///
/// **Cost**: ~50ms per transcript on Apple Silicon, ~150ms on Intel.
/// `IndexerService` batches these on a utility queue so the UI stays
/// responsive.
///
/// **Privacy**: everything is on-device. Transcripts never leave the
/// machine for embedding. (The chat LLM call is a separate concern;
/// that's where the user picks HTTPS / CLI.)
@MainActor
final class EmbeddingService: ObservableObject {
    /// `nonisolated` so other singletons (IndexerService) can grab a
    /// reference from their own nonisolated inits. The instance itself
    /// stays @MainActor — only the static reference dodge is nonisolated.
    nonisolated static let shared = EmbeddingService()

    enum ModelKind: String {
        /// `NLContextualEmbedding` — transformer-based, sentence-aware.
        case contextual
        /// `NLEmbedding` word vectors averaged across tokens.
        case word
        /// Initial / failed state. `embed` will throw.
        case none
    }

    /// What we ended up using. Visible to the indexer so it can tag
    /// embeddings with the model and re-index when the model changes.
    @Published private(set) var modelKind: ModelKind = .none

    /// True once the model is fully loaded and ready to embed. The chat
    /// pipeline gates its first embed call on this to avoid trying to
    /// embed mid-download.
    @Published private(set) var isReady: Bool = false

    /// Surfaced for UI — "Preparing Memory…" copy when downloading the
    /// contextual model on first launch.
    @Published private(set) var isPreparing: Bool = false

    @Published private(set) var preparationError: String?

    // MARK: - Underlying models

    /// Loaded lazily based on macOS version. Both can coexist —
    /// contextual is preferred if available.
    private var contextualEmbedding: Any?  // NLContextualEmbedding (typed at use)
    private var wordEmbedding: NLEmbedding?

    /// `nonisolated` so the singleton can be initialized off the main
    /// actor (Swift's `static let` initializer runs on whichever thread
    /// first reaches it). Inner Task hops to the main actor before
    /// touching any @Published state.
    nonisolated private init() {
        Task { @MainActor in
            await self.prepareModel()
        }
    }

    // MARK: - Public API

    /// Compute an embedding for the given text. Returns the raw vector
    /// plus the model tag so callers can persist both.
    ///
    /// Thread-safety: callable from any thread. Internally bounces to a
    /// utility queue for the CPU-bound NLEmbedding work; `await`-resumes
    /// on the original actor.
    func embed(_ text: String) async throws -> (vec: [Float], model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyText }

        // Wait for the model to be ready. Avoids the race where the
        // indexer fires before NLContextualEmbedding finishes loading.
        if !isReady {
            for _ in 0..<60 where !isReady {  // up to ~6s wait
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            guard isReady else { throw EmbeddingError.notReady }
        }

        // Capture state on the actor, then do CPU work off-actor.
        let kind = modelKind
        let contextual = contextualEmbedding
        let word = wordEmbedding

        return try await Task.detached(priority: .utility) {
            switch kind {
            case .contextual:
                if #available(macOS 14.0, *) {
                    guard let emb = contextual as? NLContextualEmbedding else {
                        throw EmbeddingError.noModel
                    }
                    return try Self.embedContextual(emb, text: trimmed)
                }
                throw EmbeddingError.noModel
            case .word:
                guard let emb = word else { throw EmbeddingError.noModel }
                return try Self.embedWord(emb, text: trimmed)
            case .none:
                throw EmbeddingError.noModel
            }
        }.value
    }

    /// Cosine similarity. Used by `MemoryChatService` to rank embedded
    /// transcripts against the question vector. Returns NaN-safe 0 when
    /// either vector is zero or dim-mismatched.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Preparation

    private func prepareModel() async {
        isPreparing = true
        defer { isPreparing = false }

        if #available(macOS 14.0, *) {
            if let contextual = await loadContextualEmbedding() {
                contextualEmbedding = contextual
                modelKind = .contextual
                isReady = true
                print("EmbeddingService: ready with NLContextualEmbedding")
                return
            }
            // Fall through to word embedding if contextual fails — better
            // to ship a lower-quality model than nothing.
            print("EmbeddingService: contextual unavailable, falling back to NLEmbedding")
        }

        if let word = NLEmbedding.wordEmbedding(for: .english) {
            wordEmbedding = word
            modelKind = .word
            isReady = true
            print("EmbeddingService: ready with NLEmbedding word vectors (dim=\(word.dimension))")
            return
        }

        preparationError = "No embedding model available. Memory chat will fall back to keyword search."
        print("EmbeddingService: NO model available")
    }

    @available(macOS 14.0, *)
    private func loadContextualEmbedding() async -> NLContextualEmbedding? {
        guard let emb = NLContextualEmbedding(language: .english) else { return nil }

        // Asset state machine:
        //   .available    → ready to use
        //   .notAvailable → need to request download
        //   .notLoaded    → installed but not in-memory yet, call load()
        if !emb.hasAvailableAssets {
            print("EmbeddingService: requesting contextual model download…")
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    emb.requestAssets { result, error in
                        if let error {
                            cont.resume(throwing: error)
                        } else if result == .available {
                            cont.resume()
                        } else {
                            cont.resume(throwing: EmbeddingError.assetRequestFailed)
                        }
                    }
                }
            } catch {
                print("EmbeddingService: asset download failed: \(error)")
                preparationError = "Couldn't download semantic search model. Using keyword-only retrieval."
                return nil
            }
        }

        do {
            try emb.load()
        } catch {
            print("EmbeddingService: model load failed: \(error)")
            preparationError = "Couldn't load semantic search model."
            return nil
        }

        return emb
    }

    // MARK: - Embedding implementations
    //
    // These are nonisolated because they're pure functions over their
    // inputs — no shared state, no @Published properties. Marking them
    // nonisolated lets us call them from a Task.detached without the
    // compiler complaining about reaching main-actor-isolated code.

    @available(macOS 14.0, *)
    nonisolated private static func embedContextual(_ emb: NLContextualEmbedding, text: String) throws -> (vec: [Float], model: String) {
        let result = try emb.embeddingResult(for: text, language: .english)

        // `result.enumerateTokenVectors` walks each token's contextual
        // vector. We average them to produce a fixed-size sentence
        // representation. Mean pooling is the simplest sentence-level
        // reduction and works well enough for conversational retrieval.
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            if sum.isEmpty {
                sum = vector
            } else if sum.count == vector.count {
                for i in 0..<sum.count {
                    sum[i] += vector[i]
                }
            }
            count += 1
            return true
        }

        guard count > 0, !sum.isEmpty else { throw EmbeddingError.embedFailed }
        let avg = sum.map { Float($0 / Double(count)) }
        return (avg, "apple-contextual-en-v1")
    }

    nonisolated private static func embedWord(_ emb: NLEmbedding, text: String) throws -> (vec: [Float], model: String) {
        let tokens = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count >= 2 }

        var sum = [Double](repeating: 0, count: emb.dimension)
        var hits = 0
        for token in tokens {
            if let v = emb.vector(for: token) {
                for i in 0..<min(v.count, sum.count) {
                    sum[i] += v[i]
                }
                hits += 1
            }
        }
        guard hits > 0 else { throw EmbeddingError.embedFailed }
        let avg = sum.map { Float($0 / Double(hits)) }
        return (avg, "apple-word-en-v1")
    }
}

enum EmbeddingError: LocalizedError {
    case emptyText
    case noModel
    case notReady
    case assetRequestFailed
    case embedFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:            return "Nothing to embed."
        case .noModel:              return "No embedding model is available on this Mac."
        case .notReady:             return "The embedding model is still loading."
        case .assetRequestFailed:   return "Couldn't download the embedding model."
        case .embedFailed:          return "Couldn't produce an embedding for that text."
        }
    }
}
