import Foundation
import SQLite3

/// Searchable, indexed view of the user's transcription history.
///
/// **Why a separate store from RunStore**: RunStore is the system of record
/// — one JSON file per run on disk, durable, easy to debug. MemoryStore is
/// a *derived* index built for query speed: full-text search via FTS5,
/// semantic search via cosine similarity over precomputed embeddings, and
/// entity-level relationships for the knowledge graph. If MemoryStore ever
/// corrupts, delete `memory.db`; `IndexerService` rebuilds from RunStore.
///
/// **Concurrency model**: every public method routes through `queue`, a
/// serial dispatch queue. SQLite is opened with `SQLITE_OPEN_FULLMUTEX` as
/// belt-and-suspenders but the queue is what actually keeps callers honest.
/// Reads + writes from any thread are safe.
///
/// **Why raw C API and not SQLite.swift / GRDB**: zero SwiftPM dependency.
/// The wrapper is ~500 lines for a schema this size, which is cheap. We
/// pay it once; we save the dep resolver, the SwiftPM cache, and the
/// surface area of a third-party library that loves to introduce its own
/// thread model.
final class MemoryStore {
    static let shared = MemoryStore()

    private let queue = DispatchQueue(label: "com.voiceflow.memorystore", qos: .utility)
    private var db: OpaquePointer?
    private(set) var isOpen: Bool = false

    /// Bumped whenever the schema changes in a way that requires migration.
    /// Stored in the `schema_version` table; on app launch we compare and
    /// either run incremental migrations or wipe + rebuild (the index is
    /// derived, never user-authored, so destruction is safe).
    private static let currentSchemaVersion: Int = 1

    private init() {
        open()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Lifecycle

    var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("VoiceFlow", isDirectory: true)
            .appendingPathComponent("memory.db")
    }

    private func open() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(storeURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            print("MemoryStore: failed to open \(storeURL.path): \(result)")
            return
        }
        db = handle
        isOpen = true

        // Pragma tuning. WAL mode lets readers and writers run concurrently
        // without blocking each other — important when the indexer is busy
        // writing while the chat UI queries.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")    // WAL durability is preserved
        exec("PRAGMA temp_store=MEMORY;")
        exec("PRAGMA foreign_keys=ON;")

        ensureSchema()
    }

    /// Nuke + recreate. Called from migration path when the schema version
    /// is incompatible (forward-incompatible breaking change). Safe because
    /// MemoryStore is derived from RunStore — IndexerService will rebuild.
    func resetSchema() {
        queue.sync {
            exec("DROP TABLE IF EXISTS embeddings;")
            exec("DROP TABLE IF EXISTS entity_runs;")
            exec("DROP TABLE IF EXISTS entity_indexed_runs;")
            exec("DROP TABLE IF EXISTS entities;")
            exec("DROP TABLE IF EXISTS transcripts_fts;")
            exec("DROP TABLE IF EXISTS runs;")
            exec("DROP TABLE IF EXISTS schema_version;")
            ensureSchemaInternal()
        }
    }

    private func ensureSchema() {
        queue.sync {
            ensureSchemaInternal()
        }
    }

    private func ensureSchemaInternal() {
        exec("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            );
        """)

        let currentVersion = readSchemaVersion()
        if currentVersion > 0 && currentVersion != Self.currentSchemaVersion {
            // Forward-incompatible — wipe and rebuild. IndexerService picks
            // it up from RunStore on next launch.
            print("MemoryStore: schema v\(currentVersion) → v\(Self.currentSchemaVersion), wiping")
            exec("DROP TABLE IF EXISTS embeddings;")
            exec("DROP TABLE IF EXISTS entity_runs;")
            exec("DROP TABLE IF EXISTS entity_indexed_runs;")
            exec("DROP TABLE IF EXISTS entities;")
            exec("DROP TABLE IF EXISTS transcripts_fts;")
            exec("DROP TABLE IF EXISTS runs;")
            exec("DELETE FROM schema_version;")
        }

        exec("""
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL,
                app TEXT,
                bundle_id TEXT,
                profile TEXT,
                word_count INTEGER DEFAULT 0,
                duration_seconds REAL DEFAULT 0,
                status TEXT,
                llm_cost_usd REAL DEFAULT 0
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at DESC);")

        // FTS5 virtual table. `porter` stemmer + `unicode61` tokenizer is
        // the standard "good defaults" combo — case-insensitive, handles
        // accents, and "running" matches "run". Content lives in this table
        // (no separate content-shadowing) so we don't have to keep the FTS
        // index manually in sync.
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                run_id UNINDEXED,
                text,
                tokenize='porter unicode61'
            );
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                type TEXT NOT NULL,
                mentions INTEGER DEFAULT 0
            );
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS entity_runs (
                entity_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                PRIMARY KEY (entity_id, run_id)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entity_runs_run ON entity_runs(run_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_entity_runs_entity ON entity_runs(entity_id);")

        // Entity extraction can legitimately return zero entities for short
        // dictations. Track completion separately from links so those runs
        // do not retry LLM extraction on every manual sync.
        exec("""
            CREATE TABLE IF NOT EXISTS entity_indexed_runs (
                run_id TEXT PRIMARY KEY,
                indexed_at INTEGER NOT NULL
            );
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                run_id TEXT PRIMARY KEY,
                vec BLOB NOT NULL,
                dim INTEGER NOT NULL,
                model TEXT NOT NULL
            );
        """)

        // Persist current schema version. INSERT OR REPLACE collapses the
        // table to a single row.
        exec("INSERT OR REPLACE INTO schema_version (version) VALUES (\(Self.currentSchemaVersion));")
    }

    private func readSchemaVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT version FROM schema_version LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Stored types

    /// Lightweight projection of a run row for retrieval purposes. Carries
    /// just enough to filter, rank, and render a source chip — full
    /// transcript text is fetched separately when actually needed.
    struct StoredRun: Equatable {
        let id: String
        let createdAt: Date
        let appName: String?
        let bundleID: String?
        let profile: String?
        let wordCount: Int
        let durationSeconds: Double
        let status: String?
    }

    struct StoredEntity: Equatable {
        let id: String
        let label: String
        let type: String
        let mentions: Int
    }

    struct SearchHit: Equatable {
        let runID: String
        /// FTS5's BM25 score. Lower is better (it's a distance, not a
        /// similarity) — we negate when combining with cosine.
        let bm25: Double
    }

    struct EmbeddingRow {
        let runID: String
        let vec: [Float]
        let model: String
    }

    // MARK: - Write API

    /// Upsert a run row + its transcript text into FTS. Idempotent on the
    /// run id — re-indexing the same run is safe and cheap.
    func upsertRun(
        id: String,
        createdAt: Date,
        appName: String?,
        bundleID: String?,
        profile: String?,
        wordCount: Int,
        durationSeconds: Double,
        status: String?,
        llmCostUSD: Double?,
        transcriptText: String
    ) {
        queue.sync {
            let createdAtUnix = Int(createdAt.timeIntervalSince1970)

            // 1. Upsert run row.
            let runSQL = """
                INSERT INTO runs (id, created_at, app, bundle_id, profile, word_count, duration_seconds, status, llm_cost_usd)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    created_at=excluded.created_at,
                    app=excluded.app,
                    bundle_id=excluded.bundle_id,
                    profile=excluded.profile,
                    word_count=excluded.word_count,
                    duration_seconds=excluded.duration_seconds,
                    status=excluded.status,
                    llm_cost_usd=excluded.llm_cost_usd;
            """
            var runStmt: OpaquePointer?
            defer { sqlite3_finalize(runStmt) }
            guard sqlite3_prepare_v2(db, runSQL, -1, &runStmt, nil) == SQLITE_OK else {
                print("MemoryStore.upsertRun: prepare failed: \(lastError())")
                return
            }
            bindText(runStmt, 1, id)
            sqlite3_bind_int64(runStmt, 2, Int64(createdAtUnix))
            bindText(runStmt, 3, appName)
            bindText(runStmt, 4, bundleID)
            bindText(runStmt, 5, profile)
            sqlite3_bind_int(runStmt, 6, Int32(wordCount))
            sqlite3_bind_double(runStmt, 7, durationSeconds)
            bindText(runStmt, 8, status)
            sqlite3_bind_double(runStmt, 9, llmCostUSD ?? 0)
            if sqlite3_step(runStmt) != SQLITE_DONE {
                print("MemoryStore.upsertRun: step failed: \(lastError())")
                return
            }

            // 2. Replace FTS entry. FTS5 doesn't have an UPSERT — delete
            // by run_id and re-insert. Cheap and correct.
            exec("DELETE FROM transcripts_fts WHERE run_id = '\(escapeForLiteral(id))';")

            var ftsStmt: OpaquePointer?
            defer { sqlite3_finalize(ftsStmt) }
            let ftsSQL = "INSERT INTO transcripts_fts (run_id, text) VALUES (?, ?);"
            guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
                print("MemoryStore.upsertRun: FTS prepare failed: \(lastError())")
                return
            }
            bindText(ftsStmt, 1, id)
            bindText(ftsStmt, 2, transcriptText)
            if sqlite3_step(ftsStmt) != SQLITE_DONE {
                print("MemoryStore.upsertRun: FTS step failed: \(lastError())")
            }
        }
    }

    /// Delete a run and everything derived from it. Cascades to FTS,
    /// embeddings, and entity_runs (orphaned entities are NOT removed —
    /// they might still be referenced by other runs).
    func deleteRun(id: String) {
        queue.sync {
            exec("DELETE FROM runs WHERE id = '\(escapeForLiteral(id))';")
            exec("DELETE FROM transcripts_fts WHERE run_id = '\(escapeForLiteral(id))';")
            exec("DELETE FROM embeddings WHERE run_id = '\(escapeForLiteral(id))';")
            exec("DELETE FROM entity_runs WHERE run_id = '\(escapeForLiteral(id))';")
            exec("DELETE FROM entity_indexed_runs WHERE run_id = '\(escapeForLiteral(id))';")
        }
    }

    /// Replace the entity set associated with a run. Used by IndexerService
    /// when entity extraction completes for a run. Old links are dropped,
    /// new ones inserted. Mention counts are recomputed from scratch.
    func setEntities(forRun runID: String, entities: [(id: String, label: String, type: String)]) {
        queue.sync {
            // 1. Drop existing links.
            exec("DELETE FROM entity_runs WHERE run_id = '\(escapeForLiteral(runID))';")
            exec("DELETE FROM entity_indexed_runs WHERE run_id = '\(escapeForLiteral(runID))';")

            // 2. Upsert entities. mentions counter is recomputed below.
            for entity in entities {
                let upsertSQL = """
                    INSERT INTO entities (id, label, type, mentions) VALUES (?, ?, ?, 0)
                    ON CONFLICT(id) DO UPDATE SET label=excluded.label, type=excluded.type;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK {
                    bindText(stmt, 1, entity.id)
                    bindText(stmt, 2, entity.label)
                    bindText(stmt, 3, entity.type)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)

                // Link
                let linkSQL = "INSERT OR IGNORE INTO entity_runs (entity_id, run_id) VALUES (?, ?);"
                var linkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, linkSQL, -1, &linkStmt, nil) == SQLITE_OK {
                    bindText(linkStmt, 1, entity.id)
                    bindText(linkStmt, 2, runID)
                    sqlite3_step(linkStmt)
                }
                sqlite3_finalize(linkStmt)
            }

            // 3. Recompute mention counts. Cheap — it's just a window
            // function over entity_runs. We do it per-write rather than
            // maintaining a denormalized counter because eventually-
            // consistent counters drift in the face of dual-write paths.
            exec("""
                UPDATE entities
                SET mentions = (SELECT COUNT(*) FROM entity_runs WHERE entity_id = entities.id);
            """)
            exec("""
                INSERT OR REPLACE INTO entity_indexed_runs (run_id, indexed_at)
                VALUES ('\(escapeForLiteral(runID))', \(Int(Date().timeIntervalSince1970)));
            """)
        }
    }

    /// Persist the embedding for a run. `model` is a free-form tag so we
    /// can detect when the embedding pipeline changed (e.g. NLEmbedding
    /// → NLContextualEmbedding) and force re-indexing.
    func setEmbedding(runID: String, vec: [Float], model: String) {
        queue.sync {
            let sql = """
                INSERT INTO embeddings (run_id, vec, dim, model) VALUES (?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET vec=excluded.vec, dim=excluded.dim, model=excluded.model;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("MemoryStore.setEmbedding: prepare failed: \(lastError())")
                return
            }
            bindText(stmt, 1, runID)
            vec.withUnsafeBufferPointer { buf in
                _ = sqlite3_bind_blob(
                    stmt, 2, buf.baseAddress,
                    Int32(buf.count * MemoryLayout<Float>.size),
                    Self.SQLITE_TRANSIENT
                )
            }
            sqlite3_bind_int(stmt, 3, Int32(vec.count))
            bindText(stmt, 4, model)
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("MemoryStore.setEmbedding: step failed: \(lastError())")
            }
        }
    }

    // MARK: - Read API

    func runCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM runs;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func transcriptText(for runID: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT text FROM transcripts_fts WHERE run_id = ? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, runID)
            if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
                return String(cString: cstr)
            }
            return nil
        }
    }

    func getRun(id: String) -> StoredRun? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT id, created_at, app, bundle_id, profile, word_count, duration_seconds, status
                FROM runs WHERE id = ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRunRow(stmt)
        }
    }

    /// FTS5 search ordered by BM25 (lower is more relevant). Caller is
    /// responsible for combining with vec scores and entity boosts.
    ///
    /// `query` is passed straight to FTS5's MATCH operator after a light
    /// sanitization pass — quotes are escaped to avoid syntax errors when
    /// the user's question contains them.
    func searchFTS(query: String, limit: Int = 50) -> [SearchHit] {
        queue.sync {
            let sanitized = Self.sanitizeFTSQuery(query)
            guard !sanitized.isEmpty else { return [] }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT run_id, bm25(transcripts_fts) AS score
                FROM transcripts_fts
                WHERE transcripts_fts MATCH ?
                ORDER BY score
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("MemoryStore.searchFTS: prepare failed: \(lastError())")
                return []
            }
            bindText(stmt, 1, sanitized)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var hits: [SearchHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runID = String(cString: sqlite3_column_text(stmt, 0))
                let score = sqlite3_column_double(stmt, 1)
                hits.append(SearchHit(runID: runID, bm25: score))
            }
            return hits
        }
    }

    func recentRuns(limit: Int = 20) -> [StoredRun] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT id, created_at, app, bundle_id, profile, word_count, duration_seconds, status
                FROM runs
                ORDER BY created_at DESC
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [StoredRun] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = readRunRow(stmt) { rows.append(row) }
            }
            return rows
        }
    }

    /// IDs of runs that don't have an embedding yet (or whose embedding
    /// was produced by a stale model). Used by IndexerService to decide
    /// what to work on.
    func unindexedRunIDs(currentModel: String) -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT runs.id FROM runs
                LEFT JOIN embeddings ON embeddings.run_id = runs.id
                WHERE embeddings.run_id IS NULL OR embeddings.model != ?
                ORDER BY runs.created_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, currentModel)

            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    /// IDs of runs whose entity extraction has not completed yet.
    func unentityRunIDs() -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT runs.id FROM runs
                LEFT JOIN entity_indexed_runs ON entity_indexed_runs.run_id = runs.id
                WHERE entity_indexed_runs.run_id IS NULL
                ORDER BY runs.created_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    /// Load all embeddings. Used for whole-corpus cosine search — we
    /// hold all vectors in memory and compute cosine in Swift. At 512
    /// dims and ~10K runs that's ~20MB and ~50ms per search, both
    /// acceptable. Past that scale we'd want sqlite-vec or HNSW.
    func allEmbeddings() -> [EmbeddingRow] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT run_id, vec, dim, model FROM embeddings;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var rows: [EmbeddingRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runID = String(cString: sqlite3_column_text(stmt, 0))
                let blob = sqlite3_column_blob(stmt, 1)
                let byteCount = Int(sqlite3_column_bytes(stmt, 1))
                let dim = Int(sqlite3_column_int(stmt, 2))
                let model = String(cString: sqlite3_column_text(stmt, 3))
                guard let blob, byteCount == dim * MemoryLayout<Float>.size else { continue }
                let buf = blob.assumingMemoryBound(to: Float.self)
                let vec = Array(UnsafeBufferPointer(start: buf, count: dim))
                rows.append(EmbeddingRow(runID: runID, vec: vec, model: model))
            }
            return rows
        }
    }

    /// All entities in the graph, ordered by mention count DESC.
    func allEntities(limit: Int = 200) -> [StoredEntity] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, label, type, mentions FROM entities ORDER BY mentions DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [StoredEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let label = String(cString: sqlite3_column_text(stmt, 1))
                let type = String(cString: sqlite3_column_text(stmt, 2))
                let mentions = Int(sqlite3_column_int(stmt, 3))
                rows.append(StoredEntity(id: id, label: label, type: type, mentions: mentions))
            }
            return rows
        }
    }

    /// Co-occurrence edges across all transcripts, returned as
    /// (entityA, entityB, weight) tuples canonicalized so a < b. Used by
    /// the force-directed graph for layout.
    func allEdges() -> [(a: String, b: String, weight: Int)] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            // Self-join entity_runs on run_id to produce pairs in the
            // same transcript. The min/max enforces canonical order so
            // we don't double-count. GROUP BY tallies the weight.
            let sql = """
                SELECT MIN(a.entity_id, b.entity_id) AS x,
                       MAX(a.entity_id, b.entity_id) AS y,
                       COUNT(*) AS weight
                FROM entity_runs a
                JOIN entity_runs b
                  ON a.run_id = b.run_id AND a.entity_id < b.entity_id
                GROUP BY x, y;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var rows: [(a: String, b: String, weight: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let a = String(cString: sqlite3_column_text(stmt, 0))
                let b = String(cString: sqlite3_column_text(stmt, 1))
                let weight = Int(sqlite3_column_int(stmt, 2))
                rows.append((a, b, weight))
            }
            return rows
        }
    }

    /// Run IDs that mention the given entity. Used by the chat retriever's
    /// entity-boost path AND by the graph's click-to-filter side panel.
    func runIDs(forEntity entityID: String) -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT run_id FROM entity_runs
                WHERE entity_id = ?
                ORDER BY rowid;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, entityID)
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    /// Clear the *derived* tables (embeddings + entities) but keep runs
    /// and FTS intact. Used by IndexerService when forcing a full
    /// re-index (e.g. the embedding model changed). The remaining
    /// tables stay because they're rebuilt from RunStore via the
    /// dual-write path, not from the indexer.
    func clearDerivedIndex() {
        queue.sync {
            exec("DELETE FROM embeddings;")
            exec("DELETE FROM entity_runs;")
            exec("DELETE FROM entity_indexed_runs;")
            exec("DELETE FROM entities;")
        }
    }

    // MARK: - Helpers

    private func readRunRow(_ stmt: OpaquePointer?) -> StoredRun? {
        guard let stmt else { return nil }
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
        let app: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 2))
        let bundleID: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let profile: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let wordCount = Int(sqlite3_column_int(stmt, 5))
        let durationSeconds = sqlite3_column_double(stmt, 6)
        let status: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 7))
        return StoredRun(
            id: id,
            createdAt: createdAt,
            appName: app,
            bundleID: bundleID,
            profile: profile,
            wordCount: wordCount,
            durationSeconds: durationSeconds,
            status: status
        )
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                let msg = String(cString: err)
                print("MemoryStore.exec failed: \(msg)\n  SQL: \(sql)")
                sqlite3_free(err)
            }
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let stmt else { return }
        if let value {
            // SQLITE_TRANSIENT tells SQLite to make its own copy of the
            // string. SQLITE_STATIC would assume the buffer outlives the
            // statement, which Swift's bridging doesn't guarantee.
            sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func lastError() -> String {
        guard let db, let cstr = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: cstr)
    }

    private func escapeForLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    /// Strip FTS5 syntax characters so the user's free-form question
    /// doesn't blow up the parser. We keep alphanumerics + spaces + a few
    /// safe punctuation marks. Multi-word queries become implicit AND-of-
    /// prefix-matches, e.g. "kubectl pods" → `kubectl* pods*`, which is
    /// forgiving enough for conversational input.
    private static func sanitizeFTSQuery(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let tokens = String(stripped)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return "" }
        // Prefix wildcards: "kuber" matches "kubernetes". Reasonable for
        // conversational queries where the user might type a partial.
        return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    /// sqlite3_bind_* sentinels — Swift doesn't import the C macros.
    /// SQLITE_TRANSIENT == -1, SQLITE_STATIC == 0.
    private static let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
    private static let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
}
