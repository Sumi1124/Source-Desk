import Foundation

/// Schema creation and forward-only migrations.
///
/// `PRAGMA user_version` tracks where an on-disk library is. A release that adds
/// tables appends a migration here; older libraries upgrade in place on first
/// open, which is what lets someone keep years of research without exporting and
/// re-importing it.
public enum StoreMigrator {

    public static let currentVersion: Int32 = 1

    public static func migrate(_ db: SQLiteDatabase) throws {
        let version = db.userVersion
        if version > currentVersion {
            throw SourceDeskError.database(
                message: "This library was written by a newer version of SourceDesk (schema \(version), this build supports \(currentVersion)). Update the app to open it."
            )
        }
        if version < 1 {
            try applyInitialSchema(db)
            db.userVersion = 1
        }
    }

    private static func applyInitialSchema(_ db: SQLiteDatabase) throws {
        try db.execute(schemaSQL)
    }

    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS notebooks (
        id              TEXT PRIMARY KEY,
        title           TEXT NOT NULL,
        summary         TEXT NOT NULL DEFAULT '',
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL,
        last_opened_at  REAL,
        is_favorite     INTEGER NOT NULL DEFAULT 0,
        is_archived     INTEGER NOT NULL DEFAULT 0,
        default_scope   TEXT NOT NULL DEFAULT 'notebookSources',
        accent_index    INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS sources (
        id                  TEXT PRIMARY KEY,
        notebook_id         TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        kind                TEXT NOT NULL,
        title               TEXT NOT NULL,
        url                 TEXT,
        file_path           TEXT,
        content_path        TEXT,
        site_name           TEXT,
        author              TEXT,
        mime_type           TEXT,
        plain_text_bytes    INTEGER NOT NULL DEFAULT 0,
        original_bytes      INTEGER NOT NULL DEFAULT 0,
        word_count          INTEGER NOT NULL DEFAULT 0,
        page_count          INTEGER,
        chunk_count         INTEGER NOT NULL DEFAULT 0,
        status              TEXT NOT NULL DEFAULT 'queued',
        status_detail       TEXT,
        error_message       TEXT,
        error_recovery      TEXT,
        added_at            REAL NOT NULL,
        updated_at          REAL NOT NULL,
        published_at        REAL,
        fetched_at          REAL,
        checksum            TEXT NOT NULL DEFAULT '',
        tags                TEXT NOT NULL DEFAULT '[]',
        notes               TEXT NOT NULL DEFAULT '',
        extraction_method   TEXT,
        fetch_ms            INTEGER,
        include_in_retrieval INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS idx_sources_notebook ON sources(notebook_id);
    CREATE INDEX IF NOT EXISTS idx_sources_url ON sources(notebook_id, url);

    CREATE TABLE IF NOT EXISTS chunks (
        id           TEXT PRIMARY KEY,
        source_id    TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
        notebook_id  TEXT NOT NULL,
        ordinal      INTEGER NOT NULL,
        text         TEXT NOT NULL,
        heading_path TEXT,
        page_number  INTEGER,
        start_offset INTEGER NOT NULL DEFAULT 0,
        end_offset   INTEGER NOT NULL DEFAULT 0,
        char_count   INTEGER NOT NULL DEFAULT 0,
        token_count  INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source_id);
    CREATE INDEX IF NOT EXISTS idx_chunks_notebook ON chunks(notebook_id);

    CREATE TABLE IF NOT EXISTS embeddings (
        chunk_id    TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
        source_id   TEXT NOT NULL,
        notebook_id TEXT NOT NULL,
        model       TEXT NOT NULL,
        dimensions  INTEGER NOT NULL,
        vector      BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_embeddings_notebook ON embeddings(notebook_id);
    CREATE INDEX IF NOT EXISTS idx_embeddings_source ON embeddings(source_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        chunk_id UNINDEXED,
        notebook_id UNINDEXED,
        source_id UNINDEXED,
        text,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3'
    );

    CREATE TABLE IF NOT EXISTS sessions (
        id          TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        title       TEXT NOT NULL,
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL,
        scope       TEXT NOT NULL DEFAULT 'notebookSources',
        provider_id TEXT,
        model_name  TEXT,
        is_pinned   INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_sessions_notebook ON sessions(notebook_id);

    CREATE TABLE IF NOT EXISTS messages (
        id                TEXT PRIMARY KEY,
        session_id        TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        notebook_id       TEXT NOT NULL,
        role              TEXT NOT NULL,
        content           TEXT NOT NULL,
        created_at        REAL NOT NULL,
        citations         TEXT NOT NULL DEFAULT '[]',
        retrieval         TEXT,
        provider_id       TEXT,
        model_name        TEXT,
        latency_ms        INTEGER,
        prompt_tokens     INTEGER,
        completion_tokens INTEGER,
        is_error          INTEGER NOT NULL DEFAULT 0,
        error_message     TEXT,
        error_recovery    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
    CREATE INDEX IF NOT EXISTS idx_messages_notebook ON messages(notebook_id);

    CREATE TABLE IF NOT EXISTS notes (
        id          TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
        title       TEXT NOT NULL,
        body        TEXT NOT NULL DEFAULT '',
        kind        TEXT NOT NULL DEFAULT 'manual',
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL,
        source_ids  TEXT NOT NULL DEFAULT '[]',
        provider_id TEXT,
        model_name  TEXT,
        payload     TEXT,
        is_pinned   INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_notes_notebook ON notes(notebook_id);

    CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
}
