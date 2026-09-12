import Foundation

/// JSON side-car helpers. Several columns hold small structured values (tags,
/// citations, retrieval traces, note payloads) where a JSON blob is far simpler
/// than another join table, and the app never queries *inside* them.
public enum JSONText {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func decode<T: Decodable>(_ string: String?, as type: T.Type, fallback: T) -> T {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8) else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(type, from: data)) ?? fallback
    }
}

public struct StoreStats: Sendable {
    public init() {}

    public var notebookCount: Int = 0
    public var sourceCount: Int = 0
    public var chunkCount: Int = 0
    public var messageCount: Int = 0
    public var noteCount: Int = 0
    public var embeddingCount: Int = 0
    public var embeddingModels: [String] = []
    public var contentBytes: Int64 = 0
    public var databaseBytes: Int64 = 0
    public var path: String = ""

    public var totalBytes: Int64 { contentBytes + databaseBytes }
}

/// The single source of truth for everything SourceDesk knows.
///
/// One SQLite file holds notebooks, sources, chunks, vectors, chat, and notes;
/// extracted text and original downloads live beside it on disk. Nothing is
/// uploaded anywhere by this layer — it is the "local-first" half of the promise.
public final class NotebookStore: @unchecked Sendable {

    public let db: SQLiteDatabase
    public let paths: AppPaths
    private let lock = NSRecursiveLock()

    public init(paths: AppPaths) throws {
        self.paths = paths
        try paths.createDirectories()
        self.db = try SQLiteDatabase(path: paths.databaseURL.path)
        try StoreMigrator.migrate(db)
    }

    /// In-memory store, used by the test harness and by previews.
    public static func inMemory() throws -> NotebookStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcedesk-test-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: temp)
        return try NotebookStore(paths: paths)
    }

    // MARK: - Notebooks

    public func notebooks(includeArchived: Bool = true) throws -> [Notebook] {
        let sql = includeArchived
            ? "SELECT * FROM notebooks ORDER BY updated_at DESC;"
            : "SELECT * FROM notebooks WHERE is_archived = 0 ORDER BY updated_at DESC;"
        return try db.query(sql) { Self.notebook(from: $0) }
    }

    public func notebook(id: RecordID) throws -> Notebook? {
        try db.queryOne("SELECT * FROM notebooks WHERE id = ?;", [.text(id)]) { Self.notebook(from: $0) }
    }

    @discardableResult
    public func upsert(notebook: Notebook) throws -> Notebook {
        try db.execute("""
        INSERT INTO notebooks (id, title, summary, created_at, updated_at, last_opened_at,
                               is_favorite, is_archived, default_scope, accent_index)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, summary = excluded.summary, updated_at = excluded.updated_at,
            last_opened_at = excluded.last_opened_at, is_favorite = excluded.is_favorite,
            is_archived = excluded.is_archived, default_scope = excluded.default_scope,
            accent_index = excluded.accent_index;
        """, [
            .text(notebook.id), .text(notebook.title), .text(notebook.summary),
            .date(notebook.createdAt), .date(notebook.updatedAt), .date(notebook.lastOpenedAt),
            .bool(notebook.isFavorite), .bool(notebook.isArchived),
            .text(notebook.defaultScope.rawValue), .int(notebook.accentIndex)
        ])
        return notebook
    }

    public func deleteNotebook(id: RecordID) throws {
        let sourceIDs = try db.query("SELECT id FROM sources WHERE notebook_id = ?;", [.text(id)]) { $0.string(0) ?? "" }
        try db.transaction {
            // FTS5 has no foreign keys, so its rows are removed explicitly.
            for sourceID in sourceIDs {
                try deleteChunksForSource(sourceID)
            }
            try db.execute("DELETE FROM notebooks WHERE id = ?;", [.text(id)])
        }
        for sourceID in sourceIDs {
            FileStore.remove(paths.contentDirectory(for: sourceID))
        }
    }

    public func touchNotebook(id: RecordID, opened: Bool = false) throws {
        let now = Date()
        if opened {
            try db.execute("UPDATE notebooks SET updated_at = ?, last_opened_at = ? WHERE id = ?;",
                           [.date(now), .date(now), .text(id)])
        } else {
            try db.execute("UPDATE notebooks SET updated_at = ? WHERE id = ?;", [.date(now), .text(id)])
        }
    }

    // MARK: - Sources

    public func sources(notebookID: RecordID, includeExcluded: Bool = true) throws -> [Source] {
        let sql = includeExcluded
            ? "SELECT * FROM sources WHERE notebook_id = ? ORDER BY added_at ASC;"
            : "SELECT * FROM sources WHERE notebook_id = ? AND include_in_retrieval = 1 ORDER BY added_at ASC;"
        return try db.query(sql, [.text(notebookID)]) { Self.source(from: $0) }
    }

    public func source(id: RecordID) throws -> Source? {
        try db.queryOne("SELECT * FROM sources WHERE id = ?;", [.text(id)]) { Self.source(from: $0) }
    }

    public func source(matchingURL url: String, notebookID: RecordID) throws -> Source? {
        try db.queryOne(
            "SELECT * FROM sources WHERE notebook_id = ? AND url = ? LIMIT 1;",
            [.text(notebookID), .text(url)]
        ) { Self.source(from: $0) }
    }

    /// Returns the new source plus the total number of sources in the notebook, so
    /// callers can update counters without a second round-trip.
    @discardableResult
    public func upsert(source: Source) throws -> Source {
        var record = source
        record.updatedAt = Date()
        try db.execute("""
        INSERT INTO sources (id, notebook_id, kind, title, url, file_path, content_path, site_name, author,
                             mime_type, plain_text_bytes, original_bytes, word_count, page_count, chunk_count,
                             status, status_detail, error_message, error_recovery, added_at, updated_at,
                             published_at, fetched_at, checksum, tags, notes, extraction_method,
                             fetch_ms, include_in_retrieval)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, url = excluded.url, file_path = excluded.file_path,
            content_path = excluded.content_path, site_name = excluded.site_name, author = excluded.author,
            mime_type = excluded.mime_type, plain_text_bytes = excluded.plain_text_bytes,
            original_bytes = excluded.original_bytes, word_count = excluded.word_count,
            page_count = excluded.page_count, chunk_count = excluded.chunk_count,
            status = excluded.status, status_detail = excluded.status_detail,
            error_message = excluded.error_message, error_recovery = excluded.error_recovery,
            updated_at = excluded.updated_at, published_at = excluded.published_at,
            fetched_at = excluded.fetched_at, checksum = excluded.checksum, tags = excluded.tags,
            notes = excluded.notes, extraction_method = excluded.extraction_method,
            fetch_ms = excluded.fetch_ms, include_in_retrieval = excluded.include_in_retrieval;
        """, [
            .text(record.id), .text(record.notebookID), .text(record.kind.rawValue), .text(record.title),
            .optionalText(record.url), .optionalText(record.filePath), .optionalText(record.contentPath),
            .optionalText(record.siteName), .optionalText(record.author), .optionalText(record.mimeType),
            .int(record.plainTextBytes), .int(record.originalBytes), .int(record.wordCount),
            record.pageCount.map { SQLValue.int(Int64($0)) } ?? .null,
            .int(record.chunkCount), .text(record.status.rawValue),
            .optionalText(record.statusDetail), .optionalText(record.errorMessage),
            .optionalText(record.errorRecovery), .date(record.addedAt), .date(record.updatedAt),
            .date(record.publishedAt), .date(record.fetchedAt), .text(record.checksum),
            .text(JSONText.encode(record.tags)), .text(record.notes),
            .optionalText(record.extractionMethod),
            record.fetchMilliseconds.map { SQLValue.int(Int64($0)) } ?? .null,
            .bool(record.includeInRetrieval)
        ])
        return record
    }

    public func deleteSource(id: RecordID) throws {
        try db.transaction {
            try deleteChunksForSource(id)
            try db.execute("DELETE FROM sources WHERE id = ?;", [.text(id)])
        }
        FileStore.remove(paths.contentDirectory(for: id))
    }

    public func deleteSources(ids: [RecordID]) throws {
        for id in ids { try deleteSource(id: id) }
    }

    public func sourceCount(notebookID: RecordID) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM sources WHERE notebook_id = ?;", [.text(notebookID)])
    }

    // MARK: - Chunks, embeddings, keyword index

    public func chunks(sourceID: RecordID) throws -> [SourceChunk] {
        try db.query("SELECT * FROM chunks WHERE source_id = ? ORDER BY ordinal ASC;", [.text(sourceID)]) {
            Self.chunk(from: $0)
        }
    }

    public func chunks(ids: [RecordID]) throws -> [SourceChunk] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try db.query("SELECT * FROM chunks WHERE id IN (\(placeholders));", ids.map { SQLValue.text($0) }) {
            Self.chunk(from: $0)
        }
    }

    public func chunkCount(notebookID: RecordID) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM chunks WHERE notebook_id = ?;", [.text(notebookID)])
    }

    /// Every chunk in a notebook, in reading order.
    ///
    /// Ordered by source and then ordinal so the result follows the notebook as a reader
    /// would move through it — which matters when a whole-document request ("summarise
    /// this") falls back to breadth rather than relevance, because the model then sees
    /// the material in its natural sequence instead of an arbitrary one.
    public func chunks(notebookID: RecordID, limit: Int? = nil) throws -> [SourceChunk] {
        let sql = """
        SELECT chunks.* FROM chunks
        JOIN sources ON sources.id = chunks.source_id
        WHERE chunks.notebook_id = ?
        ORDER BY sources.added_at ASC, chunks.ordinal ASC
        \(limit.map { "LIMIT \($0)" } ?? "");
        """
        return try db.query(sql, [.text(notebookID)]) { Self.chunk(from: $0) }
    }

    /// Replaces every chunk and vector for a source in one transaction. Used both
    /// on first ingestion and on re-index (for example after the embedding model
    /// changes), so a re-index can never leave a half-updated source.
    public func replaceChunks(
        sourceID: RecordID,
        notebookID: RecordID,
        chunks: [SourceChunk],
        embeddings: [ChunkEmbedding]
    ) throws {
        try db.transaction {
            try deleteChunksForSource(sourceID)
            for chunk in chunks {
                try db.execute("""
                INSERT INTO chunks (id, source_id, notebook_id, ordinal, text, heading_path, page_number,
                                    start_offset, end_offset, char_count, token_count)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .text(chunk.id), .text(chunk.sourceID), .text(chunk.notebookID), .int(chunk.ordinal),
                    .text(chunk.text), .optionalText(chunk.headingPath),
                    chunk.pageNumber.map { SQLValue.int(Int64($0)) } ?? .null,
                    .int(chunk.startOffset), .int(chunk.endOffset), .int(chunk.charCount), .int(chunk.tokenCount)
                ])
                try db.execute(
                    "INSERT INTO chunks_fts (chunk_id, notebook_id, source_id, text) VALUES (?,?,?,?);",
                    [.text(chunk.id), .text(chunk.notebookID), .text(chunk.sourceID), .text(chunk.text)]
                )
            }
            for embedding in embeddings {
                try db.execute(
                    "INSERT OR REPLACE INTO embeddings (chunk_id, source_id, notebook_id, model, dimensions, vector) VALUES (?,?,?,?,?,?);",
                    [.text(embedding.chunkID), .text(embedding.sourceID), .text(embedding.notebookID),
                     .text(embedding.model), .int(embedding.dimensions), .blob(FloatVectorCodec.encode(embedding.vector))]
                )
            }
            try db.execute("UPDATE sources SET chunk_count = ? WHERE id = ?;", [.int(chunks.count), .text(sourceID)])
        }
    }

    public func embeddings(notebookID: RecordID) throws -> [ChunkEmbedding] {
        try db.query(
            "SELECT chunk_id, source_id, notebook_id, model, dimensions, vector FROM embeddings WHERE notebook_id = ?;",
            [.text(notebookID)]
        ) { row in
            ChunkEmbedding(
                chunkID: row.string(0) ?? "",
                sourceID: row.string(1) ?? "",
                notebookID: row.string(2) ?? "",
                model: row.string(3) ?? "",
                vector: row.floatVector(5)
            )
        }
    }

    public func embeddings(sourceID: RecordID) throws -> [ChunkEmbedding] {
        try db.query(
            "SELECT chunk_id, source_id, notebook_id, model, dimensions, vector FROM embeddings WHERE source_id = ?;",
            [.text(sourceID)]
        ) { row in
            ChunkEmbedding(
                chunkID: row.string(0) ?? "",
                sourceID: row.string(1) ?? "",
                notebookID: row.string(2) ?? "",
                model: row.string(3) ?? "",
                vector: row.floatVector(5)
            )
        }
    }

    public func embeddingCount(notebookID: RecordID? = nil) throws -> Int {
        if let notebookID {
            return try db.scalarInt("SELECT COUNT(*) FROM embeddings WHERE notebook_id = ?;", [.text(notebookID)])
        }
        return try db.scalarInt("SELECT COUNT(*) FROM embeddings;")
    }

    public func embeddingModels() throws -> [String] {
        try db.query("SELECT DISTINCT model FROM embeddings ORDER BY model;") { $0.string(0) ?? "" }
    }

    /// FTS5 keyword search. `MATCH` is fed a sanitized query — raw user text with
    /// quotes or operators would otherwise be a syntax error inside FTS5.
    public func keywordSearch(
        query: String,
        notebookID: RecordID,
        sourceIDs: [RecordID]? = nil,
        limit: Int = 50
    ) throws -> [(chunkID: RecordID, score: Double)] {
        let match = FTSQueryBuilder.build(query)
        guard !match.isEmpty else { return [] }
        var sql = """
        SELECT chunk_id, bm25(chunks_fts) AS rank FROM chunks_fts
        WHERE chunks_fts MATCH ? AND notebook_id = ?
        """
        var params: [SQLValue] = [.text(match), .text(notebookID)]
        if let sourceIDs, !sourceIDs.isEmpty {
            let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
            sql += " AND source_id IN (\(placeholders))"
            params.append(contentsOf: sourceIDs.map { SQLValue.text($0) })
        }
        sql += " ORDER BY rank ASC LIMIT ?;"
        params.append(.int(limit))

        return try db.query(sql, params) { row in
            // bm25() returns a negative score where more negative is better.
            let rank = row.double(1)
            return (row.string(0) ?? "", -rank)
        }
    }

    public func chunkCount(forSourceID sourceID: RecordID) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM chunks WHERE source_id = ?;", [.text(sourceID)])
    }

    private func deleteChunksForSource(_ sourceID: RecordID) throws {
        try db.execute("DELETE FROM chunks_fts WHERE source_id = ?;", [.text(sourceID)])
        try db.execute("DELETE FROM embeddings WHERE source_id = ?;", [.text(sourceID)])
        try db.execute("DELETE FROM chunks WHERE source_id = ?;", [.text(sourceID)])
    }

    // MARK: - Chat

    public func sessions(notebookID: RecordID) throws -> [ChatSession] {
        try db.query(
            "SELECT * FROM sessions WHERE notebook_id = ? ORDER BY is_pinned DESC, updated_at DESC;",
            [.text(notebookID)]
        ) { Self.session(from: $0) }
    }

    public func session(id: RecordID) throws -> ChatSession? {
        try db.queryOne("SELECT * FROM sessions WHERE id = ?;", [.text(id)]) { Self.session(from: $0) }
    }

    @discardableResult
    public func upsert(session: ChatSession) throws -> ChatSession {
        try db.execute("""
        INSERT INTO sessions (id, notebook_id, title, created_at, updated_at, scope, provider_id, model_name, is_pinned)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, updated_at = excluded.updated_at, scope = excluded.scope,
            provider_id = excluded.provider_id, model_name = excluded.model_name, is_pinned = excluded.is_pinned;
        """, [
            .text(session.id), .text(session.notebookID), .text(session.title),
            .date(session.createdAt), .date(session.updatedAt), .text(session.scope.rawValue),
            .optionalText(session.providerID), .optionalText(session.modelName), .bool(session.isPinned)
        ])
        return session
    }

    public func deleteSession(id: RecordID) throws {
        try db.execute("DELETE FROM sessions WHERE id = ?;", [.text(id)])
    }

    public func messages(sessionID: RecordID) throws -> [ChatMessage] {
        try db.query("SELECT * FROM messages WHERE session_id = ? ORDER BY created_at ASC;", [.text(sessionID)]) {
            Self.message(from: $0)
        }
    }

    public func messageCount(notebookID: RecordID) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM messages WHERE notebook_id = ?;", [.text(notebookID)])
    }

    @discardableResult
    public func upsert(message: ChatMessage) throws -> ChatMessage {
        try db.execute("""
        INSERT INTO messages (id, session_id, notebook_id, role, content, created_at, citations, retrieval,
                              provider_id, model_name, latency_ms, prompt_tokens, completion_tokens,
                              is_error, error_message, error_recovery)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            content = excluded.content, citations = excluded.citations, retrieval = excluded.retrieval,
            provider_id = excluded.provider_id, model_name = excluded.model_name,
            latency_ms = excluded.latency_ms, prompt_tokens = excluded.prompt_tokens,
            completion_tokens = excluded.completion_tokens, is_error = excluded.is_error,
            error_message = excluded.error_message, error_recovery = excluded.error_recovery;
        """, [
            .text(message.id), .text(message.sessionID), .text(message.notebookID), .text(message.role.rawValue),
            .text(message.content), .date(message.createdAt), .text(JSONText.encode(message.citations)),
            .optionalText(message.retrieval.map { JSONText.encode($0) }),
            .optionalText(message.providerID), .optionalText(message.modelName),
            message.latencyMilliseconds.map { SQLValue.int(Int64($0)) } ?? .null,
            message.promptTokens.map { SQLValue.int(Int64($0)) } ?? .null,
            message.completionTokens.map { SQLValue.int(Int64($0)) } ?? .null,
            .bool(message.isError), .optionalText(message.errorMessage), .optionalText(message.errorRecovery)
        ])
        return message
    }

    public func deleteMessage(id: RecordID) throws {
        try db.execute("DELETE FROM messages WHERE id = ?;", [.text(id)])
    }

    /// Messages newer than `id`, used to rebuild a session after a streaming turn.
    public func messages(sessionID: RecordID, after id: RecordID) throws -> [ChatMessage] {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND created_at > (SELECT created_at FROM messages WHERE id = ?) ORDER BY created_at ASC;",
            [.text(sessionID), .text(id)]
        ) { Self.message(from: $0) }
    }

    // MARK: - Notes

    public func notes(notebookID: RecordID) throws -> [NotebookNote] {
        try db.query(
            "SELECT * FROM notes WHERE notebook_id = ? ORDER BY is_pinned DESC, updated_at DESC;",
            [.text(notebookID)]
        ) { Self.note(from: $0) }
    }

    public func note(id: RecordID) throws -> NotebookNote? {
        try db.queryOne("SELECT * FROM notes WHERE id = ?;", [.text(id)]) { Self.note(from: $0) }
    }

    public func noteCount(notebookID: RecordID) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM notes WHERE notebook_id = ?;", [.text(notebookID)])
    }

    @discardableResult
    public func upsert(note: NotebookNote) throws -> NotebookNote {
        try db.execute("""
        INSERT INTO notes (id, notebook_id, title, body, kind, created_at, updated_at, source_ids,
                           provider_id, model_name, payload, is_pinned)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title, body = excluded.body, kind = excluded.kind,
            updated_at = excluded.updated_at, source_ids = excluded.source_ids,
            provider_id = excluded.provider_id, model_name = excluded.model_name,
            payload = excluded.payload, is_pinned = excluded.is_pinned;
        """, [
            .text(note.id), .text(note.notebookID), .text(note.title), .text(note.body),
            .text(note.kind.rawValue), .date(note.createdAt), .date(note.updatedAt),
            .text(JSONText.encode(note.sourceIDs)), .optionalText(note.providerID),
            .optionalText(note.modelName),
            .optionalText(note.payload.map { JSONText.encode($0) }), .bool(note.isPinned)
        ])
        return note
    }

    public func deleteNote(id: RecordID) throws {
        try db.execute("DELETE FROM notes WHERE id = ?;", [.text(id)])
    }

    // MARK: - Settings

    public func settingValue(_ key: String) throws -> String? {
        try db.scalarString("SELECT value FROM settings WHERE key = ?;", [.text(key)])
    }

    public func setSettingValue(_ key: String, _ value: String) throws {
        try db.execute(
            "INSERT INTO settings (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text(key), .text(value)]
        )
    }

    public func allSettings() throws -> [String: String] {
        var out: [String: String] = [:]
        let rows = try db.query("SELECT key, value FROM settings;") { ($0.string(0) ?? "", $0.string(1) ?? "") }
        for (key, value) in rows { out[key] = value }
        return out
    }

    // MARK: - Statistics

    public func stats() throws -> StoreStats {
        var stats = StoreStats()
        stats.notebookCount = try db.scalarInt("SELECT COUNT(*) FROM notebooks;")
        stats.sourceCount = try db.scalarInt("SELECT COUNT(*) FROM sources;")
        stats.chunkCount = try db.scalarInt("SELECT COUNT(*) FROM chunks;")
        stats.messageCount = try db.scalarInt("SELECT COUNT(*) FROM messages;")
        stats.noteCount = try db.scalarInt("SELECT COUNT(*) FROM notes;")
        stats.embeddingCount = try db.scalarInt("SELECT COUNT(*) FROM embeddings;")
        stats.embeddingModels = try embeddingModels()
        stats.contentBytes = FileStore.totalSize(of: paths.contentRoot)
        stats.databaseBytes = FileStore.size(of: paths.databaseURL)
            + FileStore.size(of: URL(fileURLWithPath: paths.databaseURL.path + "-wal"))
            + FileStore.size(of: URL(fileURLWithPath: paths.databaseURL.path + "-shm"))
        stats.path = paths.root.path
        return stats
    }

    /// Reclaims space and refreshes the query planner. Bound to a Settings button
    /// so users can compact a library that has grown and shrunk a lot.
    public func optimize() throws {
        try db.execute("PRAGMA optimize;")
        try db.execute("VACUUM;")
    }

    public func clearCache() throws -> Int64 {
        let size = FileStore.totalSize(of: paths.cacheRoot)
        try? FileManager.default.removeItem(at: paths.cacheRoot)
        try? FileManager.default.createDirectory(at: paths.cacheRoot, withIntermediateDirectories: true)
        return size
    }

    // MARK: - Row mapping

    static func notebook(from row: SQLiteRow) -> Notebook {
        Notebook(
            id: row.string(0) ?? "",
            title: row.string(1) ?? "Untitled notebook",
            summary: row.string(2) ?? "",
            createdAt: row.nonOptionalDate(3),
            updatedAt: row.nonOptionalDate(4),
            lastOpenedAt: row.date(5),
            isFavorite: row.bool(6),
            isArchived: row.bool(7),
            defaultScope: AnswerScope(rawValue: row.string(8) ?? "") ?? .notebookSources,
            accentIndex: row.int(9)
        )
    }

    static func source(from row: SQLiteRow) -> Source {
        Source(
            id: row.string(0) ?? "",
            notebookID: row.string(1) ?? "",
            kind: SourceKind(rawValue: row.string(2) ?? "") ?? .plainText,
            title: row.string(3) ?? "Untitled source",
            url: row.nonEmptyString(4),
            filePath: row.nonEmptyString(5),
            contentPath: row.nonEmptyString(6),
            siteName: row.nonEmptyString(7),
            author: row.nonEmptyString(8),
            mimeType: row.nonEmptyString(9),
            plainTextBytes: row.int64(10),
            originalBytes: row.int64(11),
            wordCount: row.int(12),
            pageCount: row.isNull(13) ? nil : row.int(13),
            chunkCount: row.int(14),
            status: SourceStatus(rawValue: row.string(15) ?? "") ?? .queued,
            statusDetail: row.nonEmptyString(16),
            errorMessage: row.nonEmptyString(17),
            errorRecovery: row.nonEmptyString(18),
            addedAt: row.nonOptionalDate(19),
            updatedAt: row.nonOptionalDate(20),
            publishedAt: row.date(21),
            fetchedAt: row.date(22),
            checksum: row.string(23) ?? "",
            tags: JSONText.decode(row.string(24), as: [String].self, fallback: []),
            notes: row.string(25) ?? "",
            extractionMethod: row.nonEmptyString(26),
            fetchMilliseconds: row.isNull(27) ? nil : row.int(27),
            includeInRetrieval: row.isNull(28) ? true : row.bool(28)
        )
    }

    static func chunk(from row: SQLiteRow) -> SourceChunk {
        SourceChunk(
            id: row.string(0) ?? "",
            sourceID: row.string(1) ?? "",
            notebookID: row.string(2) ?? "",
            ordinal: row.int(3),
            text: row.string(4) ?? "",
            headingPath: row.nonEmptyString(5),
            pageNumber: row.isNull(6) ? nil : row.int(6),
            startOffset: row.int(7),
            endOffset: row.int(8),
            charCount: row.int(9),
            tokenCount: row.int(10)
        )
    }

    static func session(from row: SQLiteRow) -> ChatSession {
        ChatSession(
            id: row.string(0) ?? "",
            notebookID: row.string(1) ?? "",
            title: row.string(2) ?? "Session",
            createdAt: row.nonOptionalDate(3),
            updatedAt: row.nonOptionalDate(4),
            scope: AnswerScope(rawValue: row.string(5) ?? "") ?? .notebookSources,
            providerID: row.nonEmptyString(6),
            modelName: row.nonEmptyString(7),
            isPinned: row.bool(8)
        )
    }

    static func message(from row: SQLiteRow) -> ChatMessage {
        ChatMessage(
            id: row.string(0) ?? "",
            sessionID: row.string(1) ?? "",
            notebookID: row.string(2) ?? "",
            role: MessageRole(rawValue: row.string(3) ?? "") ?? .user,
            content: row.string(4) ?? "",
            createdAt: row.nonOptionalDate(5),
            citations: JSONText.decode(row.string(6), as: [Citation].self, fallback: []),
            retrieval: JSONText.decode(row.string(7), as: RetrievalTrace?.self, fallback: nil),
            providerID: row.nonEmptyString(8),
            modelName: row.nonEmptyString(9),
            latencyMilliseconds: row.isNull(10) ? nil : row.int(10),
            promptTokens: row.isNull(11) ? nil : row.int(11),
            completionTokens: row.isNull(12) ? nil : row.int(12),
            isError: row.bool(13),
            errorMessage: row.nonEmptyString(14),
            errorRecovery: row.nonEmptyString(15)
        )
    }

    static func note(from row: SQLiteRow) -> NotebookNote {
        NotebookNote(
            id: row.string(0) ?? "",
            notebookID: row.string(1) ?? "",
            title: row.string(2) ?? "Note",
            body: row.string(3) ?? "",
            kind: NoteKind(rawValue: row.string(4) ?? "") ?? .manual,
            createdAt: row.nonOptionalDate(5),
            updatedAt: row.nonOptionalDate(6),
            sourceIDs: JSONText.decode(row.string(7), as: [RecordID].self, fallback: []),
            providerID: row.nonEmptyString(8),
            modelName: row.nonEmptyString(9),
            payload: JSONText.decode(row.string(10), as: NotePayload?.self, fallback: nil),
            isPinned: row.bool(11)
        )
    }
}

// MARK: - FTS query sanitising

public enum FTSQueryBuilder {
    /// Turns free text into a safe FTS5 MATCH expression: quoted terms joined with
    /// OR, so no user input can be read as an operator or break parsing.
    public static func build(_ query: String) -> String {
        let tokens = TextMath.tokens(query)
            .filter { $0.count > 1 && !TextMath.stopWords.contains($0) }
        guard !tokens.isEmpty else {
            let fallback = TextMath.tokens(query).filter { $0.count > 1 }
            return fallback.map { "\"\($0)\"" }.joined(separator: " OR ")
        }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
