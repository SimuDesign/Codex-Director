import Foundation

/// SQLite schema for the disposable derived index (plan §7).
///
/// The database is a rebuildable projection of source files; no table contains
/// prompt text, response text, full arguments/outputs, raw commands, secrets,
/// or unredacted absolute paths.
public enum DatabaseSchema {
    /// Bumped only by an approved migration.
    public static let currentVersion = 5

    public static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS resources (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            scope TEXT NOT NULL,
            project_id TEXT,
            availability TEXT NOT NULL,
            confidence TEXT NOT NULL,
            description TEXT,
            source_root_id TEXT NOT NULL,
            relative_source_path TEXT,
            source_path_hash TEXT,
            last_seen_at REAL NOT NULL,
            ownership TEXT NOT NULL DEFAULT 'unknown',
            origin TEXT NOT NULL DEFAULT 'unknown',
            classification_confidence TEXT NOT NULL DEFAULT 'unknown',
            origin_identifier TEXT,
            source_version TEXT,
            content_fingerprint TEXT,
            source_modified_at REAL,
            modified INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            available INTEGER NOT NULL,
            last_seen_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS resource_provenance (
            id TEXT PRIMARY KEY,
            resource_id TEXT NOT NULL,
            source_type TEXT NOT NULL,
            source_identifier TEXT,
            version TEXT,
            installed_at REAL,
            updated_at REAL,
            confidence TEXT NOT NULL,
            modified INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(resource_id) REFERENCES resources(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS discovery_sources (
            id TEXT PRIMARY KEY,
            source_kind TEXT NOT NULL,
            availability TEXT NOT NULL,
            last_seen_at REAL NOT NULL,
            issue_summary TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS resource_relations (
            id TEXT PRIMARY KEY,
            source_resource_id TEXT NOT NULL,
            target_resource_id TEXT NOT NULL,
            relation_kind TEXT NOT NULL,
            confidence TEXT NOT NULL,
            evidence_summary TEXT,
            UNIQUE(source_resource_id, target_resource_id, relation_kind)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            started_at REAL,
            ended_at REAL,
            status TEXT NOT NULL,
            coverage TEXT NOT NULL,
            parser_version TEXT NOT NULL,
            source_file_id TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS calls (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            parent_call_id TEXT,
            ordinal INTEGER NOT NULL,
            timestamp REAL,
            actor_name TEXT,
            resource_id TEXT,
            call_kind TEXT NOT NULL,
            status TEXT NOT NULL,
            duration_ms INTEGER,
            confidence TEXT NOT NULL,
            error_category TEXT,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS token_usage_snapshots (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            captured_at REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            cache_write_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            coverage TEXT NOT NULL,
            model_id TEXT,
            model_name TEXT,
            model_confidence TEXT NOT NULL DEFAULT 'unknown',
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS quota_snapshots (
            id TEXT PRIMARY KEY,
            captured_at REAL NOT NULL,
            window_minutes INTEGER NOT NULL,
            used_percent REAL NOT NULL,
            resets_at REAL,
            limit_id TEXT,
            limit_name TEXT,
            confidence TEXT NOT NULL,
            UNIQUE(captured_at, window_minutes, limit_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS review_findings (
            id TEXT PRIMARY KEY,
            rule_id TEXT NOT NULL,
            resource_id TEXT,
            session_id TEXT,
            severity TEXT NOT NULL,
            confidence TEXT NOT NULL,
            summary TEXT NOT NULL,
            evidence_summary TEXT NOT NULL,
            coverage TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS index_checkpoints (
            source_file_id TEXT PRIMARY KEY,
            source_size INTEGER NOT NULL,
            source_mtime REAL NOT NULL,
            byte_offset INTEGER NOT NULL,
            parser_version TEXT NOT NULL,
            indexed_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS parser_versions (
            version TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            supported_event_types TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS presentation_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        // Practical indexes for the primary read paths.
        "CREATE INDEX IF NOT EXISTS idx_calls_session ON calls(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_calls_resource ON calls(resource_id)",
        "CREATE INDEX IF NOT EXISTS idx_tokens_session ON token_usage_snapshots(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_relations_source ON resource_relations(source_resource_id)",
        "CREATE INDEX IF NOT EXISTS idx_resources_classification ON resources(ownership, origin, kind, scope)",
        "CREATE INDEX IF NOT EXISTS idx_provenance_resource ON resource_provenance(resource_id)",
        "CREATE INDEX IF NOT EXISTS idx_findings_rule ON review_findings(rule_id)",
        "CREATE INDEX IF NOT EXISTS idx_quota_source_time ON quota_snapshots(limit_id, captured_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_quota_time ON quota_snapshots(captured_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_calls_resource_time ON calls(resource_id, timestamp DESC)",
        "CREATE INDEX IF NOT EXISTS idx_calls_parent_session ON calls(parent_call_id, session_id)",
        "CREATE INDEX IF NOT EXISTS idx_resources_project ON resources(project_id, kind, scope)",
    ]

    /// Applies the schema inside a transaction; idempotent.
    public static func apply(to connection: SQLiteConnection) throws {
        let version = connection.userVersion()
        guard version < currentVersion else { return }
        try connection.beginTransactionOrThrow()
        do {
            if version >= 1 {
                let columns = [
                    "ownership TEXT NOT NULL DEFAULT 'unknown'",
                    "origin TEXT NOT NULL DEFAULT 'unknown'",
                    "classification_confidence TEXT NOT NULL DEFAULT 'unknown'",
                    "origin_identifier TEXT",
                    "source_version TEXT",
                    "content_fingerprint TEXT",
                    "source_modified_at REAL",
                    "modified INTEGER NOT NULL DEFAULT 0",
                ]
                for column in columns {
                    _ = connection.exec("ALTER TABLE resources ADD COLUMN \(column)")
                }
            }
            // v1 databases may already contain the token table without the
            // attribution columns. Upgrade any pre-v4 schema in place so
            // direct v1 -> v4 opens preserve token rows and remain readable.
            if version >= 1 {
                let tokenColumns = [
                    "model_id TEXT",
                    "model_name TEXT",
                    "model_confidence TEXT NOT NULL DEFAULT 'unknown'",
                ]
                for column in tokenColumns {
                    _ = connection.exec("ALTER TABLE token_usage_snapshots ADD COLUMN \(column)")
                }
            }
            for statement in createStatements where !connection.exec(statement) {
                throw SQLiteError.statementFailed(connection.lastErrorMessage())
            }
            try connection.setUserVersionOrThrow(currentVersion)
            try connection.commitOrThrow()
        } catch {
            connection.rollback()
            throw error
        }
    }
}
