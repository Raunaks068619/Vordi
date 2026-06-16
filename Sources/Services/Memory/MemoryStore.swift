import Foundation
import SQLite3

/// Searchable, indexed view of Vordi dictations.
///
/// MemoryStore is a derived index. Vordi runs remain durable in
/// RunStore.
/// If this SQLite database is deleted or migrated, Sync rebuilds it.
final class MemoryStore {
    static let shared = MemoryStore()

    private let queue = DispatchQueue(label: "com.vordi.memorystore", qos: .utility)
    private var db: OpaquePointer?
    private(set) var isOpen: Bool = false

    private static let currentSchemaVersion: Int = 3

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
            .appendingPathComponent("Vordi", isDirectory: true)
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

        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        exec("PRAGMA foreign_keys=ON;")

        ensureSchema()
    }

    func resetSchema() {
        queue.sync {
            dropKnownTables()
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
            print("MemoryStore: schema v\(currentVersion) -> v\(Self.currentSchemaVersion), wiping")
            dropKnownTables(keepSchemaVersion: true)
            exec("DELETE FROM schema_version;")
        }

        exec("""
            CREATE TABLE IF NOT EXISTS memory_items (
                id TEXT PRIMARY KEY,
                source_type TEXT NOT NULL,
                source_app TEXT NOT NULL,
                external_id TEXT NOT NULL,
                folder_path TEXT,
                folder_display_name TEXT,
                title TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER,
                app TEXT,
                bundle_id TEXT,
                profile TEXT,
                word_count INTEGER DEFAULT 0,
                duration_seconds REAL DEFAULT 0,
                status TEXT,
                model TEXT,
                tool_names_json TEXT DEFAULT '[]',
                llm_cost_usd REAL DEFAULT 0,
                UNIQUE(source_app, external_id)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_memory_items_created_at ON memory_items(created_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_memory_items_source_type ON memory_items(source_type);")
        exec("CREATE INDEX IF NOT EXISTS idx_memory_items_folder ON memory_items(folder_path);")

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_text_fts USING fts5(
                item_id UNINDEXED,
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
            CREATE TABLE IF NOT EXISTS entity_items (
                entity_id TEXT NOT NULL,
                item_id TEXT NOT NULL,
                PRIMARY KEY (entity_id, item_id)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entity_items_item ON entity_items(item_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_entity_items_entity ON entity_items(entity_id);")

        exec("""
            CREATE TABLE IF NOT EXISTS entity_indexed_items (
                item_id TEXT PRIMARY KEY,
                indexed_at INTEGER NOT NULL
            );
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                item_id TEXT PRIMARY KEY,
                vec BLOB NOT NULL,
                dim INTEGER NOT NULL,
                model TEXT NOT NULL
            );
        """)

        exec("INSERT OR REPLACE INTO schema_version (version) VALUES (\(Self.currentSchemaVersion));")
    }

    private func dropKnownTables(keepSchemaVersion: Bool = false) {
        exec("DROP TABLE IF EXISTS embeddings;")
        exec("DROP TABLE IF EXISTS entity_runs;")
        exec("DROP TABLE IF EXISTS entity_indexed_runs;")
        exec("DROP TABLE IF EXISTS entity_items;")
        exec("DROP TABLE IF EXISTS entity_indexed_items;")
        exec("DROP TABLE IF EXISTS entities;")
        exec("DROP TABLE IF EXISTS transcripts_fts;")
        exec("DROP TABLE IF EXISTS memory_text_fts;")
        exec("DROP TABLE IF EXISTS runs;")
        exec("DROP TABLE IF EXISTS memory_items;")
        if !keepSchemaVersion {
            exec("DROP TABLE IF EXISTS schema_version;")
        }
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

    struct StoredRun: Equatable {
        let id: String
        let sourceType: String
        let sourceApp: String
        let externalID: String
        let folderPath: String?
        let folderDisplayName: String?
        let title: String?
        let createdAt: Date
        let updatedAt: Date?
        let appName: String?
        let bundleID: String?
        let profile: String?
        let wordCount: Int
        let durationSeconds: Double
        let status: String?
        let model: String?
        let toolNames: [String]
        let llmCostUSD: Double

        var sourceDisplayName: String {
            switch sourceApp {
            case "vordi": return AppBrand.name
            default: return sourceApp
            }
        }
    }

    struct StoredEntity: Equatable {
        let id: String
        let label: String
        let type: String
        let mentions: Int
    }

    struct SearchHit: Equatable {
        let runID: String
        let bm25: Double
    }

    struct EmbeddingRow {
        let runID: String
        let vec: [Float]
        let model: String
    }

    struct FolderReference: Equatable {
        let runID: String
        let folderPath: String
        let folderDisplayName: String
    }

    // MARK: - Write API

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
        upsertMemoryItem(
            id: id,
            sourceType: "dictation",
            sourceApp: "vordi",
            externalID: id,
            folderPath: nil,
            folderDisplayName: nil,
            title: nil,
            createdAt: createdAt,
            updatedAt: nil,
            appName: appName,
            bundleID: bundleID,
            profile: profile,
            wordCount: wordCount,
            durationSeconds: durationSeconds,
            status: status,
            model: nil,
            toolNames: [],
            llmCostUSD: llmCostUSD ?? 0,
            transcriptText: transcriptText
        )
    }

    private func upsertMemoryItem(
        id: String,
        sourceType: String,
        sourceApp: String,
        externalID: String,
        folderPath: String?,
        folderDisplayName: String?,
        title: String?,
        createdAt: Date,
        updatedAt: Date?,
        appName: String?,
        bundleID: String?,
        profile: String?,
        wordCount: Int,
        durationSeconds: Double,
        status: String?,
        model: String?,
        toolNames: [String],
        llmCostUSD: Double,
        transcriptText: String
    ) {
        queue.sync {
            let previousText = transcriptTextLocked(for: id)
            let textChanged = previousText != nil && previousText != transcriptText
            let sql = """
                INSERT INTO memory_items (
                    id, source_type, source_app, external_id,
                    folder_path, folder_display_name, title,
                    created_at, updated_at,
                    app, bundle_id, profile,
                    word_count, duration_seconds, status,
                    model, tool_names_json, llm_cost_usd
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_type=excluded.source_type,
                    source_app=excluded.source_app,
                    external_id=excluded.external_id,
                    folder_path=excluded.folder_path,
                    folder_display_name=excluded.folder_display_name,
                    title=excluded.title,
                    created_at=excluded.created_at,
                    updated_at=excluded.updated_at,
                    app=excluded.app,
                    bundle_id=excluded.bundle_id,
                    profile=excluded.profile,
                    word_count=excluded.word_count,
                    duration_seconds=excluded.duration_seconds,
                    status=excluded.status,
                    model=excluded.model,
                    tool_names_json=excluded.tool_names_json,
                    llm_cost_usd=excluded.llm_cost_usd;
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("MemoryStore.upsertMemoryItem: prepare failed: \(lastError())")
                return
            }

            bindText(stmt, 1, id)
            bindText(stmt, 2, sourceType)
            bindText(stmt, 3, sourceApp)
            bindText(stmt, 4, externalID)
            bindText(stmt, 5, folderPath)
            bindText(stmt, 6, folderDisplayName)
            bindText(stmt, 7, title)
            sqlite3_bind_int64(stmt, 8, Int64(createdAt.timeIntervalSince1970))
            bindDate(stmt, 9, updatedAt)
            bindText(stmt, 10, appName)
            bindText(stmt, 11, bundleID)
            bindText(stmt, 12, profile)
            sqlite3_bind_int(stmt, 13, Int32(wordCount))
            sqlite3_bind_double(stmt, 14, durationSeconds)
            bindText(stmt, 15, status)
            bindText(stmt, 16, model)
            bindText(stmt, 17, Self.encodeJSONString(toolNames))
            sqlite3_bind_double(stmt, 18, llmCostUSD)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("MemoryStore.upsertMemoryItem: step failed: \(lastError())")
                return
            }

            if textChanged {
                clearDerivedData(forItemID: id)
            }
            exec("DELETE FROM memory_text_fts WHERE item_id = '\(escapeForLiteral(id))';")

            var ftsStmt: OpaquePointer?
            defer { sqlite3_finalize(ftsStmt) }
            let ftsSQL = "INSERT INTO memory_text_fts (item_id, text) VALUES (?, ?);"
            guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
                print("MemoryStore.upsertMemoryItem: FTS prepare failed: \(lastError())")
                return
            }
            bindText(ftsStmt, 1, id)
            bindText(ftsStmt, 2, transcriptText)
            if sqlite3_step(ftsStmt) != SQLITE_DONE {
                print("MemoryStore.upsertMemoryItem: FTS step failed: \(lastError())")
            }
        }
    }

    func deleteRun(id: String) {
        queue.sync {
            deleteItem(id: id)
        }
    }

    /// Remove every imported external AI-agent session from the corpus.
    /// Memory is scoped to Vordi's own dictations; this clears rows that
    /// older builds may have written.
    func purgeAgentSessions() {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT id FROM memory_items WHERE source_type = 'agent_session';", -1, &stmt, nil) == SQLITE_OK else {
                return
            }
            var staleIDs: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                staleIDs.append(id)
            }
            for id in staleIDs {
                deleteItem(id: id)
            }
        }
    }

    func setEntities(forRun runID: String, entities: [(id: String, label: String, type: String)]) {
        queue.sync {
            exec("DELETE FROM entity_items WHERE item_id = '\(escapeForLiteral(runID))';")
            exec("DELETE FROM entity_indexed_items WHERE item_id = '\(escapeForLiteral(runID))';")

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

                let linkSQL = "INSERT OR IGNORE INTO entity_items (entity_id, item_id) VALUES (?, ?);"
                var linkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, linkSQL, -1, &linkStmt, nil) == SQLITE_OK {
                    bindText(linkStmt, 1, entity.id)
                    bindText(linkStmt, 2, runID)
                    sqlite3_step(linkStmt)
                }
                sqlite3_finalize(linkStmt)
            }

            recomputeMentionCounts()
            exec("""
                INSERT OR REPLACE INTO entity_indexed_items (item_id, indexed_at)
                VALUES ('\(escapeForLiteral(runID))', \(Int(Date().timeIntervalSince1970)));
            """)
        }
    }

    func setEmbedding(runID: String, vec: [Float], model: String) {
        queue.sync {
            let sql = """
                INSERT INTO embeddings (item_id, vec, dim, model) VALUES (?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET vec=excluded.vec, dim=excluded.dim, model=excluded.model;
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
                    stmt,
                    2,
                    buf.baseAddress,
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

    func runCount(includeAgentContext: Bool = false) -> Int {
        itemCount(includeAgentContext: includeAgentContext)
    }

    func itemCount(includeAgentContext: Bool) -> Int {
        queue.sync {
            let sql = """
                SELECT COUNT(*) FROM memory_items
                WHERE (? = 1 OR source_type = 'dictation');
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func entityCount(includeAgentContext: Bool = false) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT COUNT(*) FROM (
                    SELECT entities.id
                    FROM entities
                    JOIN entity_items ON entity_items.entity_id = entities.id
                    JOIN memory_items ON memory_items.id = entity_items.item_id
                    WHERE (? = 1 OR memory_items.source_type = 'dictation')
                    GROUP BY entities.id
                );
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func folderReferences(includeAgentContext: Bool) -> [FolderReference] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT id, folder_path, folder_display_name
                FROM memory_items
                WHERE folder_path IS NOT NULL
                  AND folder_display_name IS NOT NULL
                  AND (? = 1 OR source_type = 'dictation');
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)

            var rows: [FolderReference] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let pathC = sqlite3_column_text(stmt, 1),
                    let displayC = sqlite3_column_text(stmt, 2)
                else { continue }
                rows.append(FolderReference(
                    runID: String(cString: sqlite3_column_text(stmt, 0)),
                    folderPath: String(cString: pathC),
                    folderDisplayName: String(cString: displayC)
                ))
            }
            return rows
        }
    }

    func transcriptText(for runID: String) -> String? {
        queue.sync {
            transcriptTextLocked(for: runID)
        }
    }

    func getRun(id: String) -> StoredRun? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT \(Self.itemColumnList) FROM memory_items WHERE id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRunRow(stmt)
        }
    }

    func searchFTS(query: String, limit: Int = 50, includeAgentContext: Bool = false) -> [SearchHit] {
        queue.sync {
            let sanitized = Self.sanitizeFTSQuery(query)
            guard !sanitized.isEmpty else { return [] }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT memory_text_fts.item_id, bm25(memory_text_fts) AS score
                FROM memory_text_fts
                JOIN memory_items ON memory_items.id = memory_text_fts.item_id
                WHERE memory_text_fts MATCH ?
                  AND (? = 1 OR memory_items.source_type = 'dictation')
                ORDER BY score
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("MemoryStore.searchFTS: prepare failed: \(lastError())")
                return []
            }
            bindText(stmt, 1, sanitized)
            sqlite3_bind_int(stmt, 2, includeAgentContext ? 1 : 0)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var hits: [SearchHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let runID = String(cString: sqlite3_column_text(stmt, 0))
                let score = sqlite3_column_double(stmt, 1)
                hits.append(SearchHit(runID: runID, bm25: score))
            }
            return hits
        }
    }

    func recentRuns(limit: Int = 20, includeAgentContext: Bool = false) -> [StoredRun] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT \(Self.itemColumnList)
                FROM memory_items
                WHERE (? = 1 OR source_type = 'dictation')
                ORDER BY created_at DESC
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var rows: [StoredRun] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = readRunRow(stmt) { rows.append(row) }
            }
            return rows
        }
    }

    func unindexedRunIDs(currentModel: String, includeAgentContext: Bool = true) -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT memory_items.id FROM memory_items
                LEFT JOIN embeddings ON embeddings.item_id = memory_items.id
                WHERE (? = 1 OR memory_items.source_type = 'dictation')
                  AND (embeddings.item_id IS NULL OR embeddings.model != ?)
                ORDER BY memory_items.created_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)
            bindText(stmt, 2, currentModel)

            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    func unentityRunIDs(includeAgentContext: Bool = true) -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT memory_items.id FROM memory_items
                LEFT JOIN entity_indexed_items ON entity_indexed_items.item_id = memory_items.id
                WHERE (? = 1 OR memory_items.source_type = 'dictation')
                  AND entity_indexed_items.item_id IS NULL
                ORDER BY memory_items.created_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)

            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    func allEmbeddings(includeAgentContext: Bool = false) -> [EmbeddingRow] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT embeddings.item_id, embeddings.vec, embeddings.dim, embeddings.model
                FROM embeddings
                JOIN memory_items ON memory_items.id = embeddings.item_id
                WHERE (? = 1 OR memory_items.source_type = 'dictation');
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)

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

    func allEntities(limit: Int = 200, includeAgentContext: Bool = false) -> [StoredEntity] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT entities.id, entities.label, entities.type, COUNT(entity_items.item_id) AS scoped_mentions
                FROM entities
                JOIN entity_items ON entity_items.entity_id = entities.id
                JOIN memory_items ON memory_items.id = entity_items.item_id
                WHERE (? = 1 OR memory_items.source_type = 'dictation')
                GROUP BY entities.id, entities.label, entities.type
                ORDER BY scoped_mentions DESC
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)
            sqlite3_bind_int(stmt, 2, Int32(limit))

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

    func allEdges(includeAgentContext: Bool = false) -> [(a: String, b: String, weight: Int)] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT MIN(a.entity_id, b.entity_id) AS x,
                       MAX(a.entity_id, b.entity_id) AS y,
                       COUNT(*) AS weight
                FROM entity_items a
                JOIN entity_items b
                  ON a.item_id = b.item_id AND a.entity_id < b.entity_id
                JOIN memory_items
                  ON memory_items.id = a.item_id
                WHERE (? = 1 OR memory_items.source_type = 'dictation')
                GROUP BY x, y;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, includeAgentContext ? 1 : 0)

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

    func edges(forEntityIDs entityIDs: [String], limit: Int, includeAgentContext: Bool = false) -> [(a: String, b: String, weight: Int)] {
        guard !entityIDs.isEmpty, limit > 0 else { return [] }

        return queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let placeholders = Array(repeating: "?", count: entityIDs.count).joined(separator: ",")
            let sql = """
                SELECT MIN(a.entity_id, b.entity_id) AS x,
                       MAX(a.entity_id, b.entity_id) AS y,
                       COUNT(*) AS weight
                FROM entity_items a
                JOIN entity_items b
                  ON a.item_id = b.item_id AND a.entity_id < b.entity_id
                JOIN memory_items
                  ON memory_items.id = a.item_id
                WHERE (? = 1 OR memory_items.source_type = 'dictation')
                  AND a.entity_id IN (\(placeholders))
                  AND b.entity_id IN (\(placeholders))
                GROUP BY x, y
                ORDER BY weight DESC
                LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var bindIndex: Int32 = 1
            sqlite3_bind_int(stmt, bindIndex, includeAgentContext ? 1 : 0)
            bindIndex += 1
            for id in entityIDs {
                bindText(stmt, bindIndex, id)
                bindIndex += 1
            }
            for id in entityIDs {
                bindText(stmt, bindIndex, id)
                bindIndex += 1
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))

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

    func runIDs(forEntity entityID: String, includeAgentContext: Bool = false) -> [String] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT entity_items.item_id
                FROM entity_items
                JOIN memory_items ON memory_items.id = entity_items.item_id
                WHERE entity_items.entity_id = ?
                  AND (? = 1 OR memory_items.source_type = 'dictation')
                ORDER BY memory_items.created_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, entityID)
            sqlite3_bind_int(stmt, 2, includeAgentContext ? 1 : 0)

            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    func clearDerivedIndex() {
        queue.sync {
            exec("DELETE FROM embeddings;")
            exec("DELETE FROM entity_items;")
            exec("DELETE FROM entity_indexed_items;")
            exec("DELETE FROM entities;")
        }
    }

    // MARK: - Helpers

    private func deleteItem(id: String) {
        exec("DELETE FROM memory_items WHERE id = '\(escapeForLiteral(id))';")
        exec("DELETE FROM memory_text_fts WHERE item_id = '\(escapeForLiteral(id))';")
        clearDerivedData(forItemID: id)
        recomputeMentionCounts()
    }

    private func clearDerivedData(forItemID itemID: String) {
        exec("DELETE FROM embeddings WHERE item_id = '\(escapeForLiteral(itemID))';")
        exec("DELETE FROM entity_items WHERE item_id = '\(escapeForLiteral(itemID))';")
        exec("DELETE FROM entity_indexed_items WHERE item_id = '\(escapeForLiteral(itemID))';")
    }

    private func transcriptTextLocked(for itemID: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT text FROM memory_text_fts WHERE item_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, itemID)
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    private func recomputeMentionCounts() {
        exec("""
            UPDATE entities
            SET mentions = (SELECT COUNT(*) FROM entity_items WHERE entity_id = entities.id);
        """)
    }

    private func readRunRow(_ stmt: OpaquePointer?) -> StoredRun? {
        guard let stmt else { return nil }
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let sourceType = String(cString: sqlite3_column_text(stmt, 1))
        let sourceApp = String(cString: sqlite3_column_text(stmt, 2))
        let externalID = String(cString: sqlite3_column_text(stmt, 3))
        let folderPath = optionalString(stmt, 4)
        let folderDisplayName = optionalString(stmt, 5)
        let title = optionalString(stmt, 6)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
        let updatedAt = optionalDate(stmt, 8)
        let app = optionalString(stmt, 9)
        let bundleID = optionalString(stmt, 10)
        let profile = optionalString(stmt, 11)
        let wordCount = Int(sqlite3_column_int(stmt, 12))
        let durationSeconds = sqlite3_column_double(stmt, 13)
        let status = optionalString(stmt, 14)
        let model = optionalString(stmt, 15)
        let toolNames = Self.decodeJSONString(optionalString(stmt, 16))
        let llmCostUSD = sqlite3_column_double(stmt, 17)

        return StoredRun(
            id: id,
            sourceType: sourceType,
            sourceApp: sourceApp,
            externalID: externalID,
            folderPath: folderPath,
            folderDisplayName: folderDisplayName,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            appName: app,
            bundleID: bundleID,
            profile: profile,
            wordCount: wordCount,
            durationSeconds: durationSeconds,
            status: status,
            model: model,
            toolNames: toolNames,
            llmCostUSD: llmCostUSD
        )
    }

    private func optionalString(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let stmt, sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        guard let cstr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cstr)
    }

    private func optionalDate(_ stmt: OpaquePointer?, _ column: Int32) -> Date? {
        guard let stmt, sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, column)))
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
            sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindDate(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date?) {
        guard let stmt else { return }
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value.timeIntervalSince1970))
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

    private static func encodeJSONString(_ values: [String]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: values, options: []),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    private static func decodeJSONString(_ raw: String?) -> [String] {
        guard
            let raw,
            let data = raw.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return values
    }

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
        return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    private static func wordCount(in text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    private static let itemColumnList = """
        id, source_type, source_app, external_id,
        folder_path, folder_display_name, title,
        created_at, updated_at,
        app, bundle_id, profile,
        word_count, duration_seconds, status,
        model, tool_names_json, llm_cost_usd
    """

    private static let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
    private static let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
}
