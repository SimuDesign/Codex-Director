import Foundation

/// Actor-isolated SQLite derived index.
///
/// All database access happens on this actor; source files are never opened.
/// The database is disposable: `deleteAllData()` and `destroy(at:)` support a
/// full derived-index reset without touching any source.
public actor DatabaseStore {
    public enum StoreError: Error, Sendable, Equatable, LocalizedError {
        case cannotOpenDatabase(URL)
        case presentationIdentityUnavailable
        /// Thrown when a value fails the persistence privacy allowlist.
        /// The rejected value is never interpolated into the description.
        case persistenceRejected(recordType: String, field: String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpenDatabase(let url):
                return "Cannot open derived database at \(url.path)"
            case .presentationIdentityUnavailable: return "Presentation identity unavailable"
            case .persistenceRejected(let recordType, let field):
                return "Persistence rejected \(recordType).\(field): value violates the privacy allowlist."
            }
        }
    }

    public let url: URL
    private let connection: SQLiteConnection
    private let queryObserver: (@Sendable (PresentationQueryOperation) -> Void)?

    public init(
        url: URL,
        readOnly: Bool = false,
        queryObserver: (@Sendable (PresentationQueryOperation) -> Void)? = nil
    ) throws {
        self.url = url
        self.queryObserver = queryObserver
        guard let connection = SQLiteConnection(url: url, readOnly: readOnly) else {
            throw StoreError.cannotOpenDatabase(url)
        }
        self.connection = connection
        if !readOnly {
            try DatabaseSchema.apply(to: connection)
            try Self.ensurePresentationIdentity(on: connection)
        }
    }

    // MARK: - Locations

    public static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("CodexDirector", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func defaultDatabaseURL() throws -> URL {
        try defaultDirectory().appendingPathComponent("codex-director.sqlite")
    }

    /// Removes the derived database file and its WAL/SHM siblings.
    public static func destroy(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    // MARK: - Transactions

    /// Runs a non-suspending, actor-isolated body inside one transaction.
    public func inTransaction<T>(_ body: @Sendable (isolated DatabaseStore) throws -> T) throws -> T {
        try connection.beginTransactionOrThrow()
        do {
            let value = try body(self)
            try connection.commitOrThrow()
            return value
        } catch {
            connection.rollback()
            throw error
        }
    }

    // MARK: - Writes

    public func insertResources(_ resources: [CapabilityResource]) throws {
        try validateResources(resources)
        try inTransaction { database in
            let statement = try connection.prepare(
                "INSERT OR REPLACE INTO resources (id, name, kind, scope, project_id, availability, confidence, description, source_root_id, relative_source_path, source_path_hash, last_seen_at, ownership, origin, classification_confidence, origin_identifier, source_version, content_fingerprint, source_modified_at, modified) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            )
            for resource in resources {
                statement.bind(resource.id, at: 1)
                statement.bind(resource.name, at: 2)
                statement.bind(resource.kind.rawValue, at: 3)
                statement.bind(resource.scope.rawValue, at: 4)
                statement.bind(resource.projectID, at: 5)
                statement.bind(resource.status.rawValue, at: 6)
                statement.bind(resource.confidence.rawValue, at: 7)
                statement.bind(resource.summary, at: 8)
                statement.bind(resource.sourceRootID, at: 9)
                statement.bind(resource.relativeSourcePath, at: 10)
                statement.bind(resource.sourcePathHash, at: 11)
                statement.bind(resource.lastSeenAt.timeIntervalSince1970, at: 12)
                statement.bind(resource.ownership.rawValue, at: 13)
                statement.bind(resource.origin.rawValue, at: 14)
                statement.bind(resource.classificationConfidence.rawValue, at: 15)
                statement.bind(resource.originIdentifier, at: 16)
                statement.bind(resource.sourceVersion, at: 17)
                statement.bind(resource.contentFingerprint, at: 18)
                statement.bind(resource.sourceModifiedAt?.timeIntervalSince1970, at: 19)
                statement.bind(resource.modified ? 1 : 0, at: 20)
                _ = try statement.step()
                try statement.reset()
            }
            try Self.bumpDataGeneration(on: connection)
        }
    }

    /// Atomically replaces the inventory projection. Deleted or moved source
    /// records disappear only after the complete scan has succeeded.
    public func replaceResourceInventory(
        resources: [CapabilityResource],
        projects: [CapabilityProject] = [],
        provenance: [CapabilityProvenance] = [],
        relations: [ResourceRelation] = []
    ) async throws {
        try validateResources(resources)
        for project in projects {
            try validateRecord(Self.projectFields(project), allowedKeys: PersistenceAllowlist.projectKeys, recordType: "projects")
        }
        for evidence in provenance {
            try validateRecord(Self.provenanceFields(evidence), allowedKeys: PersistenceAllowlist.provenanceKeys, recordType: "resource_provenance")
        }
        try validateRelations(relations)
        try inTransaction { database in
            for table in ["resource_provenance", "resource_relations", "projects", "resources"] {
                guard connection.exec("DELETE FROM \(table)") else {
                    throw SQLiteError.statementFailed(connection.lastErrorMessage())
                }
            }
            try database.insertResourcesInCurrentTransaction(resources)
            try database.insertProjectsInCurrentTransaction(projects)
            try database.insertProvenanceInCurrentTransaction(provenance)
            try database.insertRelationsInCurrentTransaction(relations)
            try Self.bumpDataGeneration(on: connection)
        }
    }

    private func insertResourcesInCurrentTransaction(_ resources: [CapabilityResource]) throws {
        let statement = try connection.prepare(
            "INSERT OR REPLACE INTO resources (id, name, kind, scope, project_id, availability, confidence, description, source_root_id, relative_source_path, source_path_hash, last_seen_at, ownership, origin, classification_confidence, origin_identifier, source_version, content_fingerprint, source_modified_at, modified) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        )
        for resource in resources {
            statement.bind(resource.id, at: 1); statement.bind(resource.name, at: 2)
            statement.bind(resource.kind.rawValue, at: 3); statement.bind(resource.scope.rawValue, at: 4)
            statement.bind(resource.projectID, at: 5); statement.bind(resource.status.rawValue, at: 6)
            statement.bind(resource.confidence.rawValue, at: 7); statement.bind(resource.summary, at: 8)
            statement.bind(resource.sourceRootID, at: 9); statement.bind(resource.relativeSourcePath, at: 10)
            statement.bind(resource.sourcePathHash, at: 11); statement.bind(resource.lastSeenAt.timeIntervalSince1970, at: 12)
            statement.bind(resource.ownership.rawValue, at: 13); statement.bind(resource.origin.rawValue, at: 14)
            statement.bind(resource.classificationConfidence.rawValue, at: 15); statement.bind(resource.originIdentifier, at: 16)
            statement.bind(resource.sourceVersion, at: 17); statement.bind(resource.contentFingerprint, at: 18)
            statement.bind(resource.sourceModifiedAt?.timeIntervalSince1970, at: 19); statement.bind(resource.modified ? 1 : 0, at: 20)
            _ = try statement.step(); try statement.reset()
        }
    }

    private func insertProjectsInCurrentTransaction(_ projects: [CapabilityProject]) throws {
        let statement = try connection.prepare("INSERT OR REPLACE INTO projects (id, name, available, last_seen_at) VALUES (?,?,?,?)")
        for project in projects {
            statement.bind(project.id, at: 1); statement.bind(project.name, at: 2)
            statement.bind(project.available ? 1 : 0, at: 3); statement.bind(project.lastSeenAt.timeIntervalSince1970, at: 4)
            _ = try statement.step(); try statement.reset()
        }
    }

    private func insertProvenanceInCurrentTransaction(_ records: [CapabilityProvenance]) throws {
        let statement = try connection.prepare("INSERT OR REPLACE INTO resource_provenance (id, resource_id, source_type, source_identifier, version, installed_at, updated_at, confidence, modified) VALUES (?,?,?,?,?,?,?,?,?)")
        for record in records {
            statement.bind(record.id, at: 1); statement.bind(record.resourceID, at: 2); statement.bind(record.sourceType.rawValue, at: 3)
            statement.bind(record.sourceIdentifier, at: 4); statement.bind(record.version, at: 5)
            statement.bind(record.installedAt?.timeIntervalSince1970, at: 6); statement.bind(record.updatedAt?.timeIntervalSince1970, at: 7)
            statement.bind(record.confidence.rawValue, at: 8); statement.bind(record.modified ? 1 : 0, at: 9)
            _ = try statement.step(); try statement.reset()
        }
    }

    private func insertRelationsInCurrentTransaction(_ relations: [ResourceRelation]) throws {
        let statement = try connection.prepare("INSERT OR IGNORE INTO resource_relations (id, source_resource_id, target_resource_id, relation_kind, confidence, evidence_summary) VALUES (?,?,?,?,?,?)")
        for relation in relations {
            statement.bind(relation.id, at: 1); statement.bind(relation.sourceResourceID, at: 2); statement.bind(relation.targetResourceID, at: 3)
            statement.bind(relation.relationKind, at: 4); statement.bind(relation.confidence.rawValue, at: 5); statement.bind(relation.evidenceSummary, at: 6)
            _ = try statement.step(); try statement.reset()
        }
    }

    public func insertRelations(_ relations: [ResourceRelation]) async throws {
        try validateRelations(relations)
        try inTransaction { database in
            let statement = try connection.prepare(
                "INSERT OR IGNORE INTO resource_relations (id, source_resource_id, target_resource_id, relation_kind, confidence, evidence_summary) VALUES (?,?,?,?,?,?)"
            )
            for relation in relations {
                statement.bind(relation.id, at: 1)
                statement.bind(relation.sourceResourceID, at: 2)
                statement.bind(relation.targetResourceID, at: 3)
                statement.bind(relation.relationKind, at: 4)
                statement.bind(relation.confidence.rawValue, at: 5)
                statement.bind(relation.evidenceSummary, at: 6)
                _ = try statement.step()
                try statement.reset()
            }
            try Self.bumpDataGeneration(on: connection)
        }
    }

    /// Replaces or merges a session's derived records idempotently.
    ///
    /// - `resetExisting == true`: the file was re-parsed from the beginning,
    ///   so previously indexed calls/tokens for this session are removed
    ///   first (the file's content is authoritative).
    /// - `resetExisting == false`: appends are merged with existing records.
    public func replaceSession(_ batch: PersistedSessionBatch, resetExisting: Bool = false) async throws {
        try validateBatch(batch)
        try inTransaction { _ in
            if resetExisting {
                let deleteCalls = try connection.prepare("DELETE FROM calls WHERE session_id = ?")
                deleteCalls.bind(batch.session.id, at: 1)
                _ = try deleteCalls.step()
                let deleteTokens = try connection.prepare("DELETE FROM token_usage_snapshots WHERE session_id = ?")
                deleteTokens.bind(batch.session.id, at: 1)
                _ = try deleteTokens.step()
            }

            let session = batch.session
            // Upsert WITHOUT delete: INSERT OR REPLACE would delete the old
            // row and fire ON DELETE CASCADE on this session's calls/tokens.
            let sessionStatement = try connection.prepare(
                "INSERT INTO sessions (id, project_id, started_at, ended_at, status, coverage, parser_version, source_file_id) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, started_at = excluded.started_at, ended_at = excluded.ended_at, status = excluded.status, coverage = excluded.coverage, parser_version = excluded.parser_version, source_file_id = excluded.source_file_id"
            )
            sessionStatement.bind(session.id, at: 1)
            sessionStatement.bind(session.projectID, at: 2)
            sessionStatement.bind(session.startedAt?.timeIntervalSince1970, at: 3)
            sessionStatement.bind(session.endedAt?.timeIntervalSince1970, at: 4)
            sessionStatement.bind(session.status.rawValue, at: 5)
            sessionStatement.bind(session.coverage.rawValue, at: 6)
            sessionStatement.bind(session.parserVersion, at: 7)
            sessionStatement.bind(session.sourceFileID, at: 8)
            _ = try sessionStatement.step()

            // Calls: INSERT OR REPLACE by stable call id.
            let callStatement = try connection.prepare(
                "INSERT OR REPLACE INTO calls (id, session_id, parent_call_id, ordinal, timestamp, actor_name, resource_id, call_kind, status, duration_ms, confidence, error_category) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
            )
            for call in batch.calls {
                callStatement.bind(call.id, at: 1)
                callStatement.bind(call.sessionID, at: 2)
                callStatement.bind(call.parentCallID, at: 3)
                callStatement.bind(call.ordinal, at: 4)
                callStatement.bind(call.timestamp?.timeIntervalSince1970, at: 5)
                callStatement.bind(call.actorName, at: 6)
                callStatement.bind(call.resourceID, at: 7)
                callStatement.bind(call.kind.rawValue, at: 8)
                callStatement.bind(call.status.rawValue, at: 9)
                callStatement.bind(call.durationMs, at: 10)
                callStatement.bind(call.confidence.rawValue, at: 11)
                callStatement.bind(call.errorCategory, at: 12)
                _ = try callStatement.step()
                try callStatement.reset()
            }

            // Token snapshots: INSERT OR REPLACE.
            let tokenStatement = try connection.prepare(
                "INSERT OR REPLACE INTO token_usage_snapshots (id, session_id, captured_at, input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, coverage, model_id, model_name, model_confidence) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)"
            )
            for snapshot in batch.tokenSnapshots {
                tokenStatement.bind(snapshot.id, at: 1)
                tokenStatement.bind(snapshot.sessionID, at: 2)
                tokenStatement.bind(snapshot.capturedAt.timeIntervalSince1970, at: 3)
                tokenStatement.bind(snapshot.usage.inputTokens, at: 4)
                tokenStatement.bind(snapshot.usage.cachedInputTokens, at: 5)
                tokenStatement.bind(snapshot.usage.cacheWriteInputTokens, at: 6)
                tokenStatement.bind(snapshot.usage.outputTokens, at: 7)
                tokenStatement.bind(snapshot.usage.reasoningOutputTokens, at: 8)
                tokenStatement.bind(snapshot.usage.totalTokens, at: 9)
                tokenStatement.bind(snapshot.usage.coverage.rawValue, at: 10)
                tokenStatement.bind(snapshot.modelID, at: 11)
                tokenStatement.bind(snapshot.modelName, at: 12)
                tokenStatement.bind(snapshot.modelConfidence.rawValue, at: 13)
                _ = try tokenStatement.step()
                try tokenStatement.reset()
            }

            // Quota snapshots: INSERT OR REPLACE on the unique window key.
            // Using REPLACE keeps the latest parsed entry when multiple snapshots
            // share the same `(captured_at, window_minutes, limit_id)` key.
            let quotaStatement = try connection.prepare(
                "INSERT OR REPLACE INTO quota_snapshots (id, captured_at, window_minutes, used_percent, resets_at, limit_id, limit_name, confidence) VALUES (?,?,?,?,?,?,?,?)"
            )
            for quota in batch.quotaSnapshots {
                quotaStatement.bind(quota.id, at: 1)
                quotaStatement.bind(quota.capturedAt.timeIntervalSince1970, at: 2)
                quotaStatement.bind(quota.windowMinutes, at: 3)
                quotaStatement.bind(quota.usedPercent, at: 4)
                quotaStatement.bind(quota.resetsAt?.timeIntervalSince1970, at: 5)
                quotaStatement.bind(quota.limitID, at: 6)
                quotaStatement.bind(quota.limitName, at: 7)
                quotaStatement.bind(quota.confidence.rawValue, at: 8)
                _ = try quotaStatement.step()
                try quotaStatement.reset()
            }

            // Findings: INSERT OR REPLACE.
            let findingStatement = try connection.prepare(
                "INSERT OR REPLACE INTO review_findings (id, rule_id, resource_id, session_id, severity, confidence, summary, evidence_summary, coverage, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)"
            )
            for finding in batch.findings {
                findingStatement.bind(finding.id, at: 1)
                findingStatement.bind(finding.ruleID, at: 2)
                findingStatement.bind(finding.resourceID, at: 3)
                findingStatement.bind(finding.sessionID, at: 4)
                findingStatement.bind(finding.severity.rawValue, at: 5)
                findingStatement.bind(finding.confidence.rawValue, at: 6)
                findingStatement.bind(finding.summary, at: 7)
                findingStatement.bind(finding.evidenceSummary, at: 8)
                findingStatement.bind(finding.coverage.rawValue, at: 9)
                findingStatement.bind(finding.createdAt.timeIntervalSince1970, at: 10)
                _ = try findingStatement.step()
                try findingStatement.reset()
            }
            try Self.bumpDataGeneration(on: connection)
        }
    }

    private static func bumpDataGeneration(on connection: SQLiteConnection) throws {
        let statement = try connection.prepare("UPDATE presentation_metadata SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'data_generation'")
        _ = try statement.step()
        let verify = try connection.prepare("SELECT value FROM presentation_metadata WHERE key = 'data_generation'")
        guard try verify.step() == .row else { throw SQLiteError.statementFailed("missing presentation generation") }
    }

    public func upsertCheckpoint(_ checkpoint: IndexCheckpoint) throws {
        try validateRecord(
            Self.checkpointFields(checkpoint),
            allowedKeys: PersistenceAllowlist.checkpointKeys,
            recordType: "index_checkpoints"
        )
        let statement = try connection.prepare(
            "INSERT OR REPLACE INTO index_checkpoints (source_file_id, source_size, source_mtime, byte_offset, parser_version, indexed_at) VALUES (?,?,?,?,?,?)"
        )
        statement.bind(checkpoint.sourceFileID, at: 1)
        statement.bind(Int64(checkpoint.sourceSize), at: 2)
        statement.bind(checkpoint.sourceMtime, at: 3)
        statement.bind(Int64(checkpoint.byteOffset), at: 4)
        statement.bind(checkpoint.parserVersion, at: 5)
        statement.bind(checkpoint.indexedAt.timeIntervalSince1970, at: 6)
        _ = try statement.step()
    }

    public func fetchCheckpoint(sourceFileID: String) throws -> IndexCheckpoint? {
        let statement = try connection.prepare(
            "SELECT source_file_id, source_size, source_mtime, byte_offset, parser_version, indexed_at FROM index_checkpoints WHERE source_file_id = ?"
        )
        statement.bind(sourceFileID, at: 1)
        guard try statement.step() == .row else { return nil }
        return IndexCheckpoint(
            sourceFileID: statement.columnText(0) ?? sourceFileID,
            sourceSize: UInt64(statement.columnInt64(1)),
            sourceMtime: statement.columnDouble(2),
            byteOffset: UInt64(statement.columnInt64(3)),
            parserVersion: statement.columnText(4) ?? "",
            indexedAt: Date(timeIntervalSince1970: statement.columnDouble(5))
        )
    }

    public func deleteSession(id: String) throws {
        try connection.beginTransactionOrThrow()
        do {
            let statement = try connection.prepare("DELETE FROM sessions WHERE id = ?")
            statement.bind(id, at: 1); _ = try statement.step()
            try Self.bumpDataGeneration(on: connection)
            try connection.commitOrThrow()
        } catch { connection.rollback(); throw error }
    }

    /// Atomically replaces the full derived findings set. Resolved findings
    /// disappear on the next completed run; a cancelled/failed pass never
    /// calls this method.
    public func replaceFindings(_ findings: [ReviewFinding]) async throws {
        for finding in findings {
            try validateFinding(finding)
        }
        try inTransaction { _ in
            guard connection.exec("DELETE FROM review_findings") else {
                throw SQLiteError.statementFailed(connection.lastErrorMessage())
            }
            let statement = try connection.prepare(
                "INSERT OR REPLACE INTO review_findings (id, rule_id, resource_id, session_id, severity, confidence, summary, evidence_summary, coverage, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)"
            )
            for finding in findings {
                statement.bind(finding.id, at: 1)
                statement.bind(finding.ruleID, at: 2)
                statement.bind(finding.resourceID, at: 3)
                statement.bind(finding.sessionID, at: 4)
                statement.bind(finding.severity.rawValue, at: 5)
                statement.bind(finding.confidence.rawValue, at: 6)
                statement.bind(finding.summary, at: 7)
                statement.bind(finding.evidenceSummary, at: 8)
                statement.bind(finding.coverage.rawValue, at: 9)
                statement.bind(finding.createdAt.timeIntervalSince1970, at: 10)
                _ = try statement.step()
                try statement.reset()
            }
            try Self.bumpDataGeneration(on: connection)
        }
    }

    public func markSourceCheckCompleted(at date: Date) throws {
        try writePresentationMetadata("last_source_check_at", value: date.timeIntervalSince1970)
    }

    public func markIndexCompleted(at date: Date) throws {
        try writePresentationMetadata("last_index_completed_at", value: date.timeIntervalSince1970)
    }

    /// Atomically records a successful source check and completed index.
    /// This deliberately does not advance data generation: no projection rows
    /// changed, only the completion metadata did.
    public func markSuccessfulSourceIndex(at date: Date) throws {
        try inTransaction { database in
            try database.writePresentationMetadata("last_source_check_at", value: date.timeIntervalSince1970)
            try database.writePresentationMetadata("last_index_completed_at", value: date.timeIntervalSince1970)
        }
    }

    private func writePresentationMetadata(_ key: String, value: Double) throws {
        let statement = try connection.prepare("INSERT OR REPLACE INTO presentation_metadata(key,value) VALUES (?,?)")
        statement.bind(key, at: 1); statement.bind(String(value), at: 2); _ = try statement.step()
    }

    public func deleteAllData() throws {
        try connection.beginTransactionOrThrow()
        do {
            for table in ["calls", "token_usage_snapshots", "quota_snapshots", "resource_provenance", "resource_relations", "projects", "discovery_sources", "review_findings", "index_checkpoints", "sessions", "resources", "parser_versions"] {
                guard connection.exec("DROP TABLE IF EXISTS \(table)") else {
                    throw SQLiteError.statementFailed(connection.lastErrorMessage())
                }
            }
            try connection.setUserVersionOrThrow(0)
            try DatabaseSchema.apply(to: connection)
            let newEpoch = UUID().uuidString
            guard connection.exec("INSERT OR REPLACE INTO presentation_metadata(key,value) VALUES ('database_epoch','\(newEpoch)')"),
                  connection.exec("INSERT OR REPLACE INTO presentation_metadata(key,value) VALUES ('data_generation','0')"),
                  connection.exec("DELETE FROM presentation_metadata WHERE key IN ('last_source_check_at','last_index_completed_at')") else {
                throw SQLiteError.statementFailed(connection.lastErrorMessage())
            }
            try connection.commitOrThrow()
        } catch {
            connection.rollback()
            throw error
        }
    }

    // MARK: - Privacy boundary

    /// Validates a normalized field set before any SQL mutation.
    /// Throws `persistenceRejected` with the record type and field name only;
    /// the rejected value is never echoed.
    private func validateRecord(
        _ fields: [String: Any],
        allowedKeys: Set<String>,
        recordType: String
    ) throws {
        for key in fields.keys where !allowedKeys.contains(key) {
            throw StoreError.persistenceRejected(recordType: recordType, field: key)
        }
        for (key, value) in fields {
            if let string = value as? String, PersistenceAllowlist.containsForbiddenValue(string) {
                throw StoreError.persistenceRejected(recordType: recordType, field: key)
            }
        }
    }

    private func validateResources(_ resources: [CapabilityResource]) throws {
        for resource in resources {
            try validateRecord(
                Self.resourceFields(resource),
                allowedKeys: PersistenceAllowlist.resourceKeys,
                recordType: "resources"
            )
        }
    }

    private func validateRelations(_ relations: [ResourceRelation]) throws {
        for relation in relations {
            try validateRecord(
                Self.relationFields(relation),
                allowedKeys: PersistenceAllowlist.relationKeys,
                recordType: "resource_relations"
            )
        }
    }

    private static func projectFields(_ project: CapabilityProject) -> [String: Any] {
        ["id": project.id, "name": project.name, "available": project.available ? 1 : 0, "last_seen_at": project.lastSeenAt.timeIntervalSince1970]
    }

    private static func provenanceFields(_ record: CapabilityProvenance) -> [String: Any] {
        [
            "id": record.id, "resource_id": record.resourceID,
            "source_type": record.sourceType.rawValue, "source_identifier": record.sourceIdentifier ?? "",
            "version": record.version ?? "", "installed_at": record.installedAt?.timeIntervalSince1970 ?? 0,
            "updated_at": record.updatedAt?.timeIntervalSince1970 ?? 0,
            "confidence": record.confidence.rawValue, "modified": record.modified ? 1 : 0,
        ]
    }

    private func validateBatch(_ batch: PersistedSessionBatch) throws {
        try validateRecord(
            Self.sessionFields(batch.session),
            allowedKeys: PersistenceAllowlist.sessionKeys,
            recordType: "sessions"
        )
        for call in batch.calls {
            try validateRecord(
                Self.callFields(call),
                allowedKeys: PersistenceAllowlist.callKeys,
                recordType: "calls"
            )
        }
        for snapshot in batch.tokenSnapshots {
            try validateRecord(
                Self.tokenFields(snapshot),
                allowedKeys: PersistenceAllowlist.tokenKeys,
                recordType: "token_usage_snapshots"
            )
        }
        for quota in batch.quotaSnapshots {
            try validateRecord(
                Self.quotaFields(quota),
                allowedKeys: PersistenceAllowlist.quotaKeys,
                recordType: "quota_snapshots"
            )
        }
        for finding in batch.findings {
            try validateFinding(finding)
        }
    }

    /// Validates findings through the same boundary (used by `replaceFindings`).
    private func validateFinding(_ finding: ReviewFinding) throws {
        try validateRecord(
            Self.findingFields(finding),
            allowedKeys: PersistenceAllowlist.findingKeys,
            recordType: "review_findings"
        )
    }

    // MARK: - Normalized field builders (SQL column names)

    private static func resourceFields(_ resource: CapabilityResource) -> [String: Any] {
        [
            "id": resource.id, "name": resource.name, "kind": resource.kind.rawValue,
            "scope": resource.scope.rawValue, "project_id": resource.projectID ?? "",
            "availability": resource.status.rawValue, "confidence": resource.confidence.rawValue,
            "description": resource.summary ?? "", "source_root_id": resource.sourceRootID,
            "relative_source_path": resource.relativeSourcePath ?? "",
            "source_path_hash": resource.sourcePathHash ?? "",
            "ownership": resource.ownership.rawValue, "origin": resource.origin.rawValue,
            "classification_confidence": resource.classificationConfidence.rawValue,
            "origin_identifier": resource.originIdentifier ?? "", "source_version": resource.sourceVersion ?? "",
            "content_fingerprint": resource.contentFingerprint ?? "",
            "source_modified_at": resource.sourceModifiedAt?.timeIntervalSince1970 ?? 0,
            "modified": resource.modified ? 1 : 0,
            "last_seen_at": resource.lastSeenAt.timeIntervalSince1970,
        ]
    }

    private static func relationFields(_ relation: ResourceRelation) -> [String: Any] {
        [
            "id": relation.id, "source_resource_id": relation.sourceResourceID,
            "target_resource_id": relation.targetResourceID,
            "relation_kind": relation.relationKind,
            "confidence": relation.confidence.rawValue,
            "evidence_summary": relation.evidenceSummary ?? "",
        ]
    }

    private static func sessionFields(_ session: TaskSummary) -> [String: Any] {
        [
            "id": session.id, "project_id": session.projectID ?? "",
            "started_at": session.startedAt?.timeIntervalSince1970 ?? 0,
            "ended_at": session.endedAt?.timeIntervalSince1970 ?? 0,
            "status": session.status.rawValue, "coverage": session.coverage.rawValue,
            "parser_version": session.parserVersion, "source_file_id": session.sourceFileID,
        ]
    }

    private static func callFields(_ call: InvocationEvent) -> [String: Any] {
        [
            "id": call.id, "session_id": call.sessionID, "parent_call_id": call.parentCallID ?? "",
            "ordinal": call.ordinal, "timestamp": call.timestamp?.timeIntervalSince1970 ?? 0,
            "actor_name": call.actorName ?? "", "resource_id": call.resourceID ?? "",
            "call_kind": call.kind.rawValue, "status": call.status.rawValue,
            "duration_ms": call.durationMs ?? -1, "confidence": call.confidence.rawValue,
            "error_category": call.errorCategory ?? "",
        ]
    }

    private static func tokenFields(_ snapshot: TokenUsageSnapshot) -> [String: Any] {
        [
            "id": snapshot.id, "session_id": snapshot.sessionID,
            "captured_at": snapshot.capturedAt.timeIntervalSince1970,
            "input_tokens": snapshot.usage.inputTokens,
            "cached_input_tokens": snapshot.usage.cachedInputTokens,
            "cache_write_input_tokens": snapshot.usage.cacheWriteInputTokens,
            "output_tokens": snapshot.usage.outputTokens,
            "reasoning_output_tokens": snapshot.usage.reasoningOutputTokens,
            "total_tokens": snapshot.usage.totalTokens,
            "coverage": snapshot.usage.coverage.rawValue,
            "model_id": snapshot.modelID ?? "",
            "model_name": snapshot.modelName ?? "",
            "model_confidence": snapshot.modelConfidence.rawValue,
        ]
    }

    private static func quotaFields(_ quota: QuotaSnapshot) -> [String: Any] {
        [
            "id": quota.id, "captured_at": quota.capturedAt.timeIntervalSince1970,
            "window_minutes": quota.windowMinutes, "used_percent": quota.usedPercent,
            "resets_at": quota.resetsAt?.timeIntervalSince1970 ?? 0,
            "limit_id": quota.limitID ?? "", "limit_name": quota.limitName ?? "",
            "confidence": quota.confidence.rawValue,
        ]
    }

    private static func findingFields(_ finding: ReviewFinding) -> [String: Any] {
        [
            "id": finding.id, "rule_id": finding.ruleID,
            "resource_id": finding.resourceID ?? "", "session_id": finding.sessionID ?? "",
            "severity": finding.severity.rawValue, "confidence": finding.confidence.rawValue,
            "summary": finding.summary, "evidence_summary": finding.evidenceSummary,
            "coverage": finding.coverage.rawValue,
            "created_at": finding.createdAt.timeIntervalSince1970,
        ]
    }

    private static func checkpointFields(_ checkpoint: IndexCheckpoint) -> [String: Any] {
        [
            "source_file_id": checkpoint.sourceFileID, "source_size": checkpoint.sourceSize,
            "source_mtime": checkpoint.sourceMtime, "byte_offset": checkpoint.byteOffset,
            "parser_version": checkpoint.parserVersion,
            "indexed_at": checkpoint.indexedAt.timeIntervalSince1970,
        ]
    }

    // MARK: - Queries

    public func fetchAllResources() throws -> [CapabilityResource] {
        return try connection.performReadSnapshot { () -> [CapabilityResource] in
        let statement = try connection.prepare(
            "SELECT id, name, kind, scope, project_id, availability, confidence, description, source_root_id, relative_source_path, source_path_hash, last_seen_at, ownership, origin, classification_confidence, origin_identifier, source_version, content_fingerprint, source_modified_at, modified FROM resources ORDER BY id"
        )
        var results: [CapabilityResource] = []
        while try statement.step() == .row {
            results.append(CapabilityResource(
                id: statement.columnText(0) ?? "",
                name: statement.columnText(1) ?? "",
                kind: ResourceKind(rawValue: statement.columnText(2) ?? "") ?? .unknown,
                status: RuntimeStatus(rawValue: statement.columnText(5) ?? "") ?? .unknown,
                scope: ResourceScope(rawValue: statement.columnText(3) ?? "") ?? .unknown,
                projectID: statement.columnText(4),
                confidence: EvidenceConfidence(rawValue: statement.columnText(6) ?? "") ?? .unknown,
                summary: statement.columnText(7),
                sourceRootID: statement.columnText(8) ?? "",
                relativeSourcePath: statement.columnText(9),
                sourcePathHash: statement.columnText(10),
                lastSeenAt: Date(timeIntervalSince1970: statement.columnDouble(11)),
                ownership: ResourceOwnership(rawValue: statement.columnText(12) ?? "") ?? .unknown,
                origin: ResourceOrigin(rawValue: statement.columnText(13) ?? "") ?? .unknown,
                classificationConfidence: EvidenceConfidence(rawValue: statement.columnText(14) ?? "") ?? .unknown,
                originIdentifier: statement.columnText(15),
                sourceVersion: statement.columnText(16),
                contentFingerprint: statement.columnText(17),
                sourceModifiedAt: statement.columnIsNull(18) ? nil : Date(timeIntervalSince1970: statement.columnDouble(18)),
                modified: statement.columnInt(19) != 0
            ))
        }
        return results }
    }

    public func fetchAllProjects() throws -> [CapabilityProject] {
        return try connection.performReadSnapshot { () -> [CapabilityProject] in
        let statement = try connection.prepare("SELECT id, name, available, last_seen_at FROM projects ORDER BY name, id")
        var results: [CapabilityProject] = []
        while try statement.step() == .row {
            results.append(CapabilityProject(id: statement.columnText(0) ?? "", name: statement.columnText(1) ?? "", available: statement.columnInt(2) != 0, lastSeenAt: Date(timeIntervalSince1970: statement.columnDouble(3))))
        }
        return results }
    }

    public func fetchAllProvenance() throws -> [CapabilityProvenance] {
        return try connection.performReadSnapshot { () -> [CapabilityProvenance] in
        let statement = try connection.prepare("SELECT id, resource_id, source_type, source_identifier, version, installed_at, updated_at, confidence, modified FROM resource_provenance ORDER BY resource_id, id")
        var results: [CapabilityProvenance] = []
        while try statement.step() == .row {
            results.append(CapabilityProvenance(
                id: statement.columnText(0) ?? "", resourceID: statement.columnText(1) ?? "",
                sourceType: ResourceOrigin(rawValue: statement.columnText(2) ?? "") ?? .unknown,
                sourceIdentifier: statement.columnText(3), version: statement.columnText(4),
                installedAt: statement.columnIsNull(5) ? nil : Date(timeIntervalSince1970: statement.columnDouble(5)),
                updatedAt: statement.columnIsNull(6) ? nil : Date(timeIntervalSince1970: statement.columnDouble(6)),
                confidence: EvidenceConfidence(rawValue: statement.columnText(7) ?? "") ?? .unknown,
                modified: statement.columnInt(8) != 0
            ))
        }
        return results }
    }

    public func fetchAllSessions() throws -> [TaskSummary] {
        queryObserver?(.allSessions)
        let statement = try connection.prepare(
            "SELECT id, project_id, started_at, ended_at, status, coverage, parser_version, source_file_id FROM sessions ORDER BY started_at DESC"
        )
        var results: [TaskSummary] = []
        while try statement.step() == .row {
            results.append(TaskSummary(
                id: statement.columnText(0) ?? "",
                projectID: statement.columnText(1),
                startedAt: statement.columnIsNull(2) ? nil : Date(timeIntervalSince1970: statement.columnDouble(2)),
                endedAt: statement.columnIsNull(3) ? nil : Date(timeIntervalSince1970: statement.columnDouble(3)),
                status: TaskStatus(rawValue: statement.columnText(4) ?? "") ?? .unknown,
                coverage: CoverageState(rawValue: statement.columnText(5) ?? "") ?? .unknown,
                parserVersion: statement.columnText(6) ?? "",
                sourceFileID: statement.columnText(7) ?? "",
                title: nil
            ))
        }
        return results
    }

    /// Session id already indexed for a source file (used when resuming).
    public func fetchSessionID(sourceFileID: String) throws -> String? {
        let statement = try connection.prepare(
            "SELECT id FROM sessions WHERE source_file_id = ?"
        )
        statement.bind(sourceFileID, at: 1)
        guard try statement.step() == .row else { return nil }
        return statement.columnText(0)
    }

    public func fetchSessionProjectID(sourceFileID: String) throws -> String? {
        let statement = try connection.prepare("SELECT project_id FROM sessions WHERE source_file_id = ?")
        statement.bind(sourceFileID, at: 1)
        guard try statement.step() == .row else { return nil }
        return statement.columnText(0)
    }

    /// Coverage previously persisted for a source file (used to merge
    /// incremental appends without a schema change).
    public func fetchSessionCoverage(sourceFileID: String) throws -> CoverageState? {
        let statement = try connection.prepare(
            "SELECT coverage FROM sessions WHERE source_file_id = ?"
        )
        statement.bind(sourceFileID, at: 1)
        guard try statement.step() == .row else { return nil }
        return CoverageState(rawValue: statement.columnText(0) ?? "") ?? .unknown
    }

    public func fetchCalls(sessionID: String) throws -> [InvocationEvent] {
        queryObserver?(.allInvocations)
        let statement = try connection.prepare(
            "SELECT id, session_id, parent_call_id, ordinal, timestamp, actor_name, resource_id, call_kind, status, duration_ms, confidence, error_category FROM calls WHERE session_id = ? ORDER BY ordinal"
        )
        statement.bind(sessionID, at: 1)
        var results: [InvocationEvent] = []
        while try statement.step() == .row {
            results.append(InvocationEvent(
                id: statement.columnText(0) ?? "",
                sessionID: statement.columnText(1) ?? sessionID,
                parentCallID: statement.columnText(2),
                ordinal: statement.columnInt(3),
                timestamp: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4)),
                actorName: statement.columnText(5),
                resourceID: statement.columnText(6),
                kind: InvocationKind(rawValue: statement.columnText(7) ?? "") ?? .unknown,
                status: InvocationStatus(rawValue: statement.columnText(8) ?? "") ?? .unknown,
                durationMs: statement.columnIsNull(9) ? nil : statement.columnInt(9),
                confidence: EvidenceConfidence(rawValue: statement.columnText(10) ?? "") ?? .unknown,
                errorCategory: statement.columnText(11)
            ))
        }
        return results
    }

    public func fetchTokenSnapshots(sessionID: String) throws -> [TokenUsageSnapshot] {
        let statement = try connection.prepare(
            "SELECT id, session_id, captured_at, input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, coverage, model_id, model_name, model_confidence FROM token_usage_snapshots WHERE session_id = ? ORDER BY captured_at"
        )
        statement.bind(sessionID, at: 1)
        var results: [TokenUsageSnapshot] = []
        while try statement.step() == .row {
            let usage = try TokenUsage(
                inputTokens: statement.columnInt64(3),
                cachedInputTokens: statement.columnInt64(4),
                cacheWriteInputTokens: statement.columnInt64(5),
                outputTokens: statement.columnInt64(6),
                reasoningOutputTokens: statement.columnInt64(7),
                totalTokens: statement.columnInt64(8),
                coverage: CoverageState(rawValue: statement.columnText(9) ?? "") ?? .unknown
            )
            results.append(TokenUsageSnapshot(
                id: statement.columnText(0) ?? "",
                sessionID: statement.columnText(1) ?? sessionID,
                capturedAt: Date(timeIntervalSince1970: statement.columnDouble(2)),
                usage: usage,
                modelID: statement.columnText(10),
                modelName: statement.columnText(11),
                modelConfidence: EvidenceConfidence(rawValue: statement.columnText(12) ?? "") ?? .unknown
            ))
        }
        return results
    }

    public func fetchAllQuotaSnapshots() throws -> [QuotaSnapshot] {
        queryObserver?(.allQuotas)
        let statement = try connection.prepare(
            "SELECT id, captured_at, window_minutes, used_percent, resets_at, limit_id, limit_name, confidence FROM quota_snapshots ORDER BY captured_at DESC"
        )
        var results: [QuotaSnapshot] = []
        while try statement.step() == .row {
            results.append(try QuotaSnapshot(
                id: statement.columnText(0) ?? "",
                capturedAt: Date(timeIntervalSince1970: statement.columnDouble(1)),
                windowMinutes: statement.columnInt(2),
                usedPercent: statement.columnDouble(3),
                resetsAt: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4)),
                limitID: statement.columnText(5),
                limitName: statement.columnText(6),
                confidence: EvidenceConfidence(rawValue: statement.columnText(7) ?? "") ?? .unknown
            ))
        }
        return results
    }

    public func presentationIdentity() throws -> PresentationIdentity {
        queryObserver?(.identity)
        return try connection.performReadSnapshot { () -> PresentationIdentity in
        func value(_ key: String) throws -> String? {
            let s = try connection.prepare("SELECT value FROM presentation_metadata WHERE key = ?")
            s.bind(key, at: 1)
            return try s.step() == .row ? s.columnText(0) : nil
        }
        if let epoch = try value("database_epoch"), let generation = try value("data_generation"), let number = Int64(generation) {
            return PresentationIdentity(databaseEpoch: epoch, dataGeneration: number)
        }
        throw StoreError.presentationIdentityUnavailable }
    }

    private static func ensurePresentationIdentity(on connection: SQLiteConnection) throws {
        let statement = try connection.prepare("SELECT value FROM presentation_metadata WHERE key = 'database_epoch'")
        if try statement.step() == .row { return }
        let epoch = UUID().uuidString
        guard connection.exec("INSERT OR REPLACE INTO presentation_metadata(key,value) VALUES ('database_epoch','\(epoch)')"),
              connection.exec("INSERT OR REPLACE INTO presentation_metadata(key,value) VALUES ('data_generation','0')") else {
            throw SQLiteError.statementFailed(connection.lastErrorMessage())
        }
    }

    public func fetchQuotaOverview(window: CapabilityQueryWindow, cancellation: SQLiteCancellationToken? = nil) throws -> QuotaOverviewSnapshot {
        queryObserver?(.quota)
        return try connection.performReadSnapshot(cancellation: cancellation) {
            let identity = try presentationIdentity()
            // Read the closed seven-day window plus exactly one predecessor
            // per canonical source.  The previous correlated NOT EXISTS query
            // re-scanned the historical range once for every old row; sources
            // whose histories occupied different time bands could therefore
            // exceed the five-second presentation deadline at real scale.
            // First reduce each source's history to its latest timestamp, then
            // use ROW_NUMBER only to resolve same-timestamp ID ties. Applying
            // the window function to the complete history needlessly sorted
            // hundreds of thousands of rows and could exhaust the bounded
            // presentation-query deadline.
            let statement = try connection.prepare(
                """
                WITH weekly AS (
                    SELECT id, captured_at, window_minutes, used_percent,
                           resets_at, limit_id, limit_name, confidence,
                           CASE
                               WHEN limit_id IS NOT NULL AND limit_id <> '' THEN 'id:' || limit_id
                               WHEN limit_name IS NOT NULL AND limit_name <> '' THEN 'name:' || limit_name
                               ELSE 'unknown'
                           END AS source_key
                    FROM quota_snapshots
                    WHERE window_minutes = 10080 AND captured_at <= ?
                ),
                predecessor_times AS (
                    SELECT source_key, MAX(captured_at) AS captured_at
                    FROM weekly
                    WHERE captured_at < ?
                    GROUP BY source_key
                ),
                ranked_predecessors AS (
                    SELECT weekly.id, weekly.captured_at,
                           weekly.window_minutes, weekly.used_percent,
                           weekly.resets_at, weekly.limit_id,
                           weekly.limit_name, weekly.confidence,
                           ROW_NUMBER() OVER (
                               PARTITION BY weekly.source_key
                               ORDER BY weekly.id DESC
                           ) AS source_rank
                    FROM weekly
                    INNER JOIN predecessor_times
                            ON predecessor_times.source_key = weekly.source_key
                           AND predecessor_times.captured_at = weekly.captured_at
                ),
                selected AS (
                    SELECT id, captured_at, window_minutes, used_percent,
                           resets_at, limit_id, limit_name, confidence
                    FROM weekly
                    WHERE captured_at >= ?
                    UNION ALL
                    SELECT id, captured_at, window_minutes, used_percent,
                           resets_at, limit_id, limit_name, confidence
                    FROM ranked_predecessors
                    WHERE source_rank = 1
                )
                SELECT id, captured_at, window_minutes, used_percent,
                       resets_at, limit_id, limit_name, confidence
                FROM selected
                ORDER BY limit_id, limit_name, captured_at ASC, id ASC
                """
            )
            statement.bind(window.end.timeIntervalSince1970, at: 1)
            statement.bind(window.start.timeIntervalSince1970, at: 2)
            statement.bind(window.start.timeIntervalSince1970, at: 3)
            var values: [QuotaSnapshot] = []
            while try statement.step() == .row {
                values.append(try QuotaSnapshot(id: statement.columnText(0) ?? "", capturedAt: Date(timeIntervalSince1970: statement.columnDouble(1)), windowMinutes: statement.columnInt(2), usedPercent: statement.columnDouble(3), resetsAt: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4)), limitID: statement.columnText(5), limitName: statement.columnText(6), confidence: EvidenceConfidence(rawValue: statement.columnText(7) ?? "") ?? .unknown))
            }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = window.timeZone
            let groups = Dictionary(grouping: values, by: { quota -> String in
                if let id = quota.limitID, !id.isEmpty { return "id:\(id)" }
                if let name = quota.limitName, !name.isEmpty { return "name:\(name)" }
                return "unknown"
            })
            let sources = groups.map { id, rows in
                let ordered = rows.sorted { lhs, rhs in lhs.capturedAt < rhs.capturedAt || (lhs.capturedAt == rhs.capturedAt && lhs.id < rhs.id) }
                let recent = ordered.filter { $0.capturedAt >= window.start }
                let groupedDays = Dictionary(grouping: recent) { (observation: QuotaSnapshot) in calendar.startOfDay(for: observation.capturedAt) }
                var previousObservation: QuotaSnapshot?
                var changes: [Date: Bool] = [:]
                for observation in ordered {
                    let changed = previousObservation.map {
                        QuotaDailyUsage.reportedCycleChanged(from: $0, to: observation)
                    } ?? false
                    let day = calendar.startOfDay(for: observation.capturedAt)
                    if observation.capturedAt >= window.start { changes[day, default: false] = changes[day, default: false] || changed }
                    previousObservation = observation
                }
                let daily = (0..<7).compactMap { offset -> QuotaOverviewDay? in
                    guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: window.start)) else { return nil }
                    let observation = groupedDays[day]?.max { lhs, rhs in lhs.capturedAt < rhs.capturedAt || (lhs.capturedAt == rhs.capturedAt && lhs.id < rhs.id) }
                    let usedPercentDelta = QuotaDailyUsage.observedUsedPercent(
                        on: day,
                        observations: ordered,
                        calendar: calendar
                    )
                    return QuotaOverviewDay(
                        day: day,
                        observation: observation,
                        cycleChanged: changes[day] ?? false,
                        usedPercentDelta: usedPercentDelta
                    )
                }
                let latest = ordered.last
                let displayName = latest?.limitName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? latest?.limitID.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Unknown source"
                let rawName = latest?.limitName.flatMap { $0.isEmpty ? nil : $0 }
                return QuotaOverviewSourceSnapshot(id: id, name: displayName, rawDisplayName: rawName, current: latest, daily: daily)
            }.sorted { $0.id < $1.id }
            return QuotaOverviewSnapshot(identity: identity, window: window, coverage: values.isEmpty ? .unknown : .complete, sources: sources)
        }
    }

    public func fetchTaskCallSummaries(window: CapabilityQueryWindow? = nil, cancellation: SQLiteCancellationToken? = nil) throws -> [PresentationTaskCallSummary] {
        queryObserver?(.taskSummaries)
        var sql = "SELECT s.id,s.project_id,COUNT(c.id),COALESCE(SUM(CASE WHEN c.status IN ('failed','interrupted') THEN 1 ELSE 0 END),0),MAX(c.timestamp) FROM sessions s LEFT JOIN calls c ON c.session_id = s.id"
        if window != nil { sql += " WHERE c.timestamp >= ? AND c.timestamp <= ?" }
        sql += " GROUP BY s.id,s.project_id ORDER BY MAX(c.timestamp) DESC"
        return try connection.performReadSnapshot(cancellation: cancellation) {
            let statement = try connection.prepare(sql)
            if let window { statement.bind(window.start.timeIntervalSince1970, at: 1); statement.bind(window.end.timeIntervalSince1970, at: 2) }
            var result: [PresentationTaskCallSummary] = []
            while try statement.step() == .row {
                result.append(PresentationTaskCallSummary(taskID: statement.columnText(0) ?? "", projectID: statement.columnText(1), callCount: statement.columnInt(2), failureCount: statement.columnInt(3), lastUsedAt: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4))))
            }
            return result
        }
    }

    /// Bounded lookup used by detail pages; intentionally avoids loading the
    /// complete session table into a view model.
    public func fetchSessionProjects(ids: [String], cancellation: SQLiteCancellationToken? = nil) throws -> [String: String?] {
        let requested = Array(ids.prefix(200))
        guard !requested.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: requested.count).joined(separator: ",")
        return try connection.performReadSnapshot(cancellation: cancellation) {
            let statement = try connection.prepare("SELECT id,project_id FROM sessions WHERE id IN (\(placeholders))")
            for (index, id) in requested.enumerated() { statement.bind(id, at: Int32(index + 1)) }
            var result: [String: String?] = [:]
            while try statement.step() == .row { result[statement.columnText(0) ?? ""] = statement.columnText(1) }
            return result
        }
    }

    /// Returns observed project membership for every resource in one bounded
    /// aggregation. It intentionally excludes resources with no project.
    public func fetchCapabilityUsageProjects(through: Date, cancellation: SQLiteCancellationToken? = nil) throws -> [String: Set<String>] {
        try connection.performReadSnapshot(cancellation: cancellation) {
            let statement = try connection.prepare("SELECT c.resource_id, s.project_id FROM calls c JOIN sessions s ON s.id = c.session_id WHERE c.resource_id IS NOT NULL AND s.project_id IS NOT NULL AND c.timestamp IS NOT NULL AND c.timestamp <= ? GROUP BY c.resource_id, s.project_id")
            statement.bind(through.timeIntervalSince1970, at: 1)
            var result: [String: Set<String>] = [:]
            while try statement.step() == .row {
                guard let resourceID = statement.columnText(0), let projectID = statement.columnText(1) else { continue }
                result[resourceID, default: []].insert(projectID)
            }
            return result
        }
    }

    public func fetchPresentationIndexMetadata() throws -> PresentationIndexMetadata {
        try connection.performReadSnapshot { () -> PresentationIndexMetadata in
        let identity = try presentationIdentity()
        func date(_ key: String) throws -> Date? {
            let s = try connection.prepare("SELECT value FROM presentation_metadata WHERE key = ?"); s.bind(key, at: 1)
            guard try s.step() == .row, let value = s.columnText(0), let seconds = Double(value) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return PresentationIndexMetadata(identity: identity, lastSourceCheckAt: try date("last_source_check_at"), lastIndexCompletedAt: try date("last_index_completed_at")) }
    }

    public func fetchPresentationDirectory(cancellation: SQLiteCancellationToken? = nil) throws -> PresentationDirectorySnapshot {
        queryObserver?(.directory)
        return try connection.performReadSnapshot(cancellation: cancellation) {
            PresentationDirectorySnapshot(
                metadata: try self.fetchPresentationIndexMetadata(),
                resources: try self.fetchAllResources(),
                relations: try self.fetchAllRelations(),
                projects: try self.fetchAllProjects(),
                provenance: try self.fetchAllProvenance(),
                indexedSessionCount: try self.count("sessions")
            )
        }
    }

    /// Returns only the directory and bounded recent usage required to upgrade
    /// a legacy Home Top5 cache. Quota, sessions, invocation payloads and
    /// source-index work are intentionally outside this read.
    public func fetchHomeRankingPresentation(window: CapabilityQueryWindow, cancellation: SQLiteCancellationToken? = nil) throws -> HomeRankingPresentationSnapshot {
        queryObserver?(.directory)
        let readCancellation = cancellation ?? SQLiteCancellationToken(timeout: .seconds(5))
        return try connection.performReadSnapshot(cancellation: readCancellation) {
            HomeRankingPresentationSnapshot(
                directory: PresentationDirectorySnapshot(
                    metadata: try self.fetchPresentationIndexMetadata(),
                    resources: try self.fetchAllResources(),
                    relations: try self.fetchAllRelations(),
                    projects: try self.fetchAllProjects(),
                    provenance: try self.fetchAllProvenance(),
                    indexedSessionCount: try self.count("sessions")
                ),
                recentUsage: try self.fetchCapabilityUsageStats(window: window)
            )
        }
    }

    public func fetchStartupPresentation(window: CapabilityQueryWindow, cancellation: SQLiteCancellationToken? = nil) throws -> StartupPresentationSnapshot {
        queryObserver?(.startup)
        return try connection.performReadSnapshot(cancellation: cancellation) {
            StartupPresentationSnapshot(
                directory: try self.fetchPresentationDirectory(cancellation: cancellation),
                recentUsage: try self.fetchCapabilityUsageStats(window: window),
                quota: try self.fetchQuotaOverview(window: window, cancellation: cancellation)
            )
        }
    }

    public func fetchLibraryPresentation(category: CapabilityCategory, window: CapabilityQueryWindow, projectID: String? = nil, cancellation: SQLiteCancellationToken? = nil) throws -> LibraryPresentationSnapshot {
        queryObserver?(.library)
        // Library presentation is one coherent, bounded read.  All of the
        // existing query helpers below are deliberately nested in this
        // snapshot; SQLiteConnection reuses the outer transaction and its
        // cancellation handler when readDepth is already non-zero.
        let readCancellation = cancellation ?? SQLiteCancellationToken(timeout: .seconds(5))
        return try connection.performReadSnapshot(cancellation: readCancellation) {
            let metadata = try self.fetchPresentationIndexMetadata()
            let catalog = try self.fetchCapabilityCatalog()

            // Category membership is a UI projection and can be corrected in
            // memory.  Filtering SQL aggregates by the persisted catalog here
            // would discard valid evidence after a classification override.
            let global = try self.fetchCapabilityUsageStats(window: window)
            let browseUsage = projectID == nil
                ? global
                : try self.fetchCapabilityUsageStats(window: window, projectID: projectID)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = window.timeZone
            let thirtyDayWindow = CapabilityQueryWindow.recent30(now: window.end, calendar: calendar)
            let category30DayUsage = try self.fetchCapabilityUsageStats(window: thirtyDayWindow)
            let browse30DayUsage = projectID == nil
                ? category30DayUsage
                : try self.fetchCapabilityUsageStats(window: thirtyDayWindow, projectID: projectID)
            let categoryHistory = try self.fetchCapabilityHistory(through: window.end)

            // Membership is intentionally one global all-time batch.  It is
            // used by project browsing and must not be narrowed to category.
            let currentPluginIDs = Set(catalog.entries.compactMap { entry in
                entry.category == .installedPlugins && entry.resource.kind == .plugin
                    ? entry.resource.id
                    : nil
            })
            let rawProjects = try self.fetchCapabilityUsageProjects(through: window.end)
            var usageProjects = rawProjects.filter { !currentPluginIDs.contains($0.key) }

            let rawHistory = try self.fetchCapabilityHistory(projectID: projectID, through: window.end)
            var browseHistory = rawHistory.filter { !currentPluginIDs.contains($0.resourceID) }

            var categoryPluginUsage: [PluginUsageResult] = []
            var browsePluginUsage: [PluginUsageResult] = []
            var categoryPlugin30DayUsage: [PluginUsageResult] = []
            var browsePlugin30DayUsage: [PluginUsageResult] = []
            var pluginAttributionUnavailableCount = 0
            if category == .installedPlugins {
                let allTimeWindow = CapabilityQueryWindow(
                    start: .distantPast,
                    end: window.end,
                    timeZone: window.timeZone
                )

                // Plugin rows have two different time semantics: recent
                // counts for the library metric and all-time attribution for
                // last-used/history and project membership.
                categoryPluginUsage = try self.fetchPluginUsageStats(window: window)
                categoryPlugin30DayUsage = try self.fetchPluginUsageStats(window: thirtyDayWindow)
                let globalPluginHistory = try self.fetchPluginUsageStats(window: allTimeWindow)
                if let projectID {
                    browsePluginUsage = try self.fetchPluginUsageStats(window: window, projectID: projectID)
                    browsePlugin30DayUsage = try self.fetchPluginUsageStats(window: thirtyDayWindow, projectID: projectID)
                    let scopedPluginHistory = try self.fetchPluginUsageStats(window: allTimeWindow, projectID: projectID)
                    browseHistory.append(contentsOf: Self.pluginHistory(scopedPluginHistory))
                } else {
                    browsePluginUsage = categoryPluginUsage
                    browsePlugin30DayUsage = categoryPlugin30DayUsage
                    browseHistory.append(contentsOf: Self.pluginHistory(globalPluginHistory))
                }
                pluginAttributionUnavailableCount = categoryPluginUsage.filter { $0.callCount == nil }.count

                // Plugin project membership is global and all-time even when
                // the current browse scope is a concrete project.
                for usage in globalPluginHistory where usage.callCount != nil && !usage.projectIDs.isEmpty {
                    usageProjects[usage.pluginID] = Set(usage.projectIDs)
                }
            }

            return LibraryPresentationSnapshot(
                metadata: metadata,
                categoryUsage: global,
                browseUsage: browseUsage,
                browseHistory: browseHistory.sorted { $0.resourceID < $1.resourceID },
                usageProjects: usageProjects,
                categoryPluginUsage: categoryPluginUsage,
                browsePluginUsage: browsePluginUsage,
                categoryHistory: categoryHistory,
                category30DayUsage: category30DayUsage,
                browse30DayUsage: browse30DayUsage,
                categoryPlugin30DayUsage: categoryPlugin30DayUsage,
                browsePlugin30DayUsage: browsePlugin30DayUsage,
                pluginAttributionUnavailableCount: pluginAttributionUnavailableCount
            )
        }
    }

    private static func pluginHistory(_ results: [PluginUsageResult]) -> [CapabilityHistory] {
        results.compactMap { result in
            guard let callCount = result.callCount else { return nil }
            return CapabilityHistory(resourceID: result.pluginID, callCount: callCount, lastUsedAt: result.lastUsedAt)
        }
    }

    public func fetchAllFindings() throws -> [ReviewFinding] {
        queryObserver?(.findings)
        return try connection.performReadSnapshot { () -> [ReviewFinding] in
        let statement = try connection.prepare(
            "SELECT id, rule_id, resource_id, session_id, severity, confidence, summary, evidence_summary, coverage, created_at FROM review_findings ORDER BY created_at DESC"
        )
        var results: [ReviewFinding] = []
        while try statement.step() == .row {
            results.append(ReviewFinding(
                id: statement.columnText(0) ?? "",
                ruleID: statement.columnText(1) ?? "",
                resourceID: statement.columnText(2),
                sessionID: statement.columnText(3),
                severity: ReviewSeverity(rawValue: statement.columnText(4) ?? "") ?? .info,
                confidence: EvidenceConfidence(rawValue: statement.columnText(5) ?? "") ?? .unknown,
                summary: statement.columnText(6) ?? "",
                evidenceSummary: statement.columnText(7) ?? "",
                coverage: CoverageState(rawValue: statement.columnText(8) ?? "") ?? .unknown,
                createdAt: Date(timeIntervalSince1970: statement.columnDouble(9)),
                remediationStatus: .open
            ))
        }
        return results }
    }

    /// Returns bounded data-quality counts without loading findings or
    /// sessions into the UI model.
    public func fetchPresentationDiagnostics(cancellation: SQLiteCancellationToken? = nil) throws -> PresentationDiagnosticsSummary {
        queryObserver?(.diagnostics)
        let readCancellation = cancellation ?? SQLiteCancellationToken(timeout: .seconds(5))
        return try connection.performReadSnapshot(cancellation: readCancellation) {
            let metadata = try self.fetchPresentationIndexMetadata()
            let statement = try connection.prepare(
                "SELECT (SELECT COUNT(*) FROM review_findings WHERE rule_id = 'rule.parser-coverage'), (SELECT COUNT(*) FROM sessions WHERE coverage = 'partial'), (SELECT COUNT(*) FROM sessions)"
            )
            guard try statement.step() == .row else {
                return PresentationDiagnosticsSummary(metadata: metadata, parserCoverageFindingCount: 0, partialCoverageSessionCount: 0, sessionCount: 0)
            }
            return PresentationDiagnosticsSummary(
                metadata: metadata,
                parserCoverageFindingCount: statement.columnInt(0),
                partialCoverageSessionCount: statement.columnInt(1),
                sessionCount: statement.columnInt(2)
            )
        }
    }

    /// Loads a bounded set of findings for the explicit review/detail path.
    public func fetchReviewFindings(resourceID: String, limit: Int = 100, cancellation: SQLiteCancellationToken? = nil) throws -> [ReviewFinding] {
        queryObserver?(.findings)
        let readCancellation = cancellation ?? SQLiteCancellationToken(timeout: .seconds(5))
        return try connection.performReadSnapshot(cancellation: readCancellation) {
            let statement = try connection.prepare(
                "SELECT id, rule_id, resource_id, session_id, severity, confidence, summary, evidence_summary, coverage, created_at FROM review_findings WHERE resource_id = ? ORDER BY created_at DESC, id DESC LIMIT ?"
            )
            statement.bind(resourceID, at: 1)
            statement.bind(max(1, min(limit, 100)), at: 2)
            var results: [ReviewFinding] = []
            while try statement.step() == .row {
                results.append(ReviewFinding(
                    id: statement.columnText(0) ?? "",
                    ruleID: statement.columnText(1) ?? "",
                    resourceID: statement.columnText(2),
                    sessionID: statement.columnText(3),
                    severity: ReviewSeverity(rawValue: statement.columnText(4) ?? "") ?? .info,
                    confidence: EvidenceConfidence(rawValue: statement.columnText(5) ?? "") ?? .unknown,
                    summary: statement.columnText(6) ?? "",
                    evidenceSummary: statement.columnText(7) ?? "",
                    coverage: CoverageState(rawValue: statement.columnText(8) ?? "") ?? .unknown,
                    createdAt: Date(timeIntervalSince1970: statement.columnDouble(9)),
                    remediationStatus: .open
                ))
            }
            return results
        }
    }

    /// Aggregated call statistics per resource.
    public struct ResourceUsageStats: Sendable, Equatable {
        public let resourceID: String
        public let callCount: Int
        public let failureCount: Int
        public let lastUsedAt: Date?
        public let completedCount: Int
        public let unresolvedCount: Int
        public let evidenceLimitedCount: Int

        public init(
            resourceID: String,
            callCount: Int,
            failureCount: Int,
            lastUsedAt: Date?,
            completedCount: Int = 0,
            unresolvedCount: Int = 0,
            evidenceLimitedCount: Int = 0
        ) {
            self.resourceID = resourceID
            self.callCount = callCount
            self.failureCount = failureCount
            self.lastUsedAt = lastUsedAt
            self.completedCount = completedCount
            self.unresolvedCount = unresolvedCount
            self.evidenceLimitedCount = evidenceLimitedCount
        }
    }

    public func fetchResourceUsageStats() throws -> [ResourceUsageStats] {
        return try connection.performReadSnapshot { () -> [ResourceUsageStats] in
        let statement = try connection.prepare(
            """
            SELECT c.resource_id,
                   COUNT(*),
                   SUM(CASE WHEN c.status IN ('failed','interrupted') THEN 1 ELSE 0 END),
                   MAX(c.timestamp),
                   SUM(CASE WHEN c.status = 'completed' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN c.status IN ('started','unknown') THEN 1 ELSE 0 END),
                   SUM(CASE WHEN c.confidence != 'exact'
                                  OR COALESCE(s.coverage, 'unknown') != 'complete'
                                  OR c.status IN ('started','unknown')
                            THEN 1 ELSE 0 END)
            FROM calls c
            LEFT JOIN sessions s ON s.id = c.session_id
            WHERE c.resource_id IS NOT NULL
            GROUP BY c.resource_id
            """
        )
        var results: [ResourceUsageStats] = []
        while try statement.step() == .row {
            results.append(ResourceUsageStats(
                resourceID: statement.columnText(0) ?? "",
                callCount: statement.columnInt(1),
                failureCount: statement.columnIsNull(2) ? 0 : statement.columnInt(2),
                lastUsedAt: statement.columnIsNull(3) ? nil : Date(timeIntervalSince1970: statement.columnDouble(3)),
                completedCount: statement.columnIsNull(4) ? 0 : statement.columnInt(4),
                unresolvedCount: statement.columnIsNull(5) ? 0 : statement.columnInt(5),
                evidenceLimitedCount: statement.columnIsNull(6) ? 0 : statement.columnInt(6)
            ))
        }
        return results }
    }

    /// Returns bounded, time- and project-filtered usage aggregates. A call
    /// with no timestamp is deliberately excluded from the time window.
    public func fetchCapabilityUsageStats(window: CapabilityQueryWindow, projectID: String? = nil) throws -> [CapabilityUsageStats] {
        return try connection.performReadSnapshot { () -> [CapabilityUsageStats] in
        let sql = """
        SELECT c.resource_id, COUNT(*),
               SUM(CASE WHEN c.confidence = 'inferred' THEN 1 ELSE 0 END),
               MAX(c.timestamp),
               CASE WHEN SUM(CASE WHEN COALESCE(s.coverage, 'unknown') IN ('partial','unavailable','unknown') THEN 1 ELSE 0 END) > 0
                    THEN 'partial' ELSE 'complete' END
        FROM calls c LEFT JOIN sessions s ON s.id = c.session_id
        WHERE c.resource_id IS NOT NULL AND c.timestamp >= ? AND c.timestamp <= ?
          AND (? IS NULL OR s.project_id = ?)
        GROUP BY c.resource_id ORDER BY c.resource_id
        """
        let statement = try connection.prepare(sql)
        statement.bind(window.start.timeIntervalSince1970, at: 1)
        statement.bind(window.end.timeIntervalSince1970, at: 2)
        statement.bind(projectID, at: 3)
        statement.bind(projectID, at: 4)
        var results: [CapabilityUsageStats] = []
        while try statement.step() == .row {
            results.append(CapabilityUsageStats(
                resourceID: statement.columnText(0) ?? "",
                callCount: statement.columnInt(1),
                inferredCount: statement.columnIsNull(2) ? 0 : statement.columnInt(2),
                lastUsedAt: statement.columnIsNull(3) ? nil : Date(timeIntervalSince1970: statement.columnDouble(3)),
                coverage: CoverageState(rawValue: statement.columnText(4) ?? "unknown") ?? .unknown
            ))
        }
        return results }
    }

    /// Fetches invocation evidence using keyset pagination. The cursor is an
    /// opaque timestamp/id pair and remains stable across refreshes.
    public func fetchCapabilityInvocations(
        resourceID: String,
        projectID: String? = nil,
        window: CapabilityQueryWindow? = nil,
        pageSize: Int = 50,
        cursor: String? = nil
    ) throws -> CapabilityInvocationPage {
        queryObserver?(.allInvocations)
        return try connection.performReadSnapshot { () -> CapabilityInvocationPage in
        let limit = max(1, min(pageSize, 200))
        let sql = """
        SELECT c.id, c.session_id, c.parent_call_id, c.ordinal, c.timestamp, c.actor_name,
               c.resource_id, c.call_kind, c.status, c.duration_ms, c.confidence, c.error_category
        FROM calls c LEFT JOIN sessions s ON s.id = c.session_id
        WHERE c.resource_id = ? AND c.timestamp IS NOT NULL
          AND (? IS NULL OR s.project_id = ?)
          AND (? IS NULL OR c.timestamp >= ?) AND (? IS NULL OR c.timestamp <= ?)
          AND (? IS NULL OR (c.timestamp < ? OR (c.timestamp = ? AND c.id < ?)))
        ORDER BY c.timestamp DESC, c.id DESC LIMIT ?
        """
        let statement = try connection.prepare(sql)
        statement.bind(resourceID, at: 1)
        statement.bind(projectID, at: 2); statement.bind(projectID, at: 3)
        let start = window?.start.timeIntervalSince1970
        let end = window?.end.timeIntervalSince1970
        statement.bind(start, at: 4); statement.bind(start, at: 5)
        statement.bind(end, at: 6); statement.bind(end, at: 7)
        let parts = cursor?.split(separator: "|", maxSplits: 1).map(String.init)
        let cursorTime: Double? = parts?.first.flatMap(Double.init)
        let cursorID = parts?.count == 2 ? parts?[1] : nil
        let validCursor = (cursorTime != nil && cursorID != nil) ? cursor : nil
        statement.bind(validCursor, at: 8)
        statement.bind(cursorTime, at: 9); statement.bind(cursorTime, at: 10); statement.bind(cursorID, at: 11)
        statement.bind(limit + 1, at: 12)
        var calls: [InvocationEvent] = []
        while try statement.step() == .row {
            calls.append(InvocationEvent(
                id: statement.columnText(0) ?? "", sessionID: statement.columnText(1) ?? "",
                parentCallID: statement.columnText(2), ordinal: statement.columnInt(3),
                timestamp: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4)),
                actorName: statement.columnText(5), resourceID: statement.columnText(6),
                kind: InvocationKind(rawValue: statement.columnText(7) ?? "") ?? .unknown,
                status: InvocationStatus(rawValue: statement.columnText(8) ?? "") ?? .unknown,
                durationMs: statement.columnIsNull(9) ? nil : statement.columnInt(9),
                confidence: EvidenceConfidence(rawValue: statement.columnText(10) ?? "") ?? .unknown,
                errorCategory: statement.columnText(11)
            ))
        }
        let hasMore = calls.count > limit
        if hasMore { calls.removeLast() }
        let next = hasMore ? calls.last.flatMap { call in
            call.timestamp.map { "\($0.timeIntervalSince1970)|\(call.id)" }
        } : nil
        return CapabilityInvocationPage(items: calls, nextCursor: next) }
    }

    public func fetchAllRelations() throws -> [ResourceRelation] {
        return try connection.performReadSnapshot { () -> [ResourceRelation] in
        let statement = try connection.prepare(
            "SELECT source_resource_id, target_resource_id, relation_kind, confidence, evidence_summary FROM resource_relations ORDER BY source_resource_id, relation_kind"
        )
        var results: [ResourceRelation] = []
        while try statement.step() == .row {
            results.append(ResourceRelation(
                sourceResourceID: statement.columnText(0) ?? "",
                targetResourceID: statement.columnText(1) ?? "",
                relationKind: statement.columnText(2) ?? "",
                confidence: EvidenceConfidence(rawValue: statement.columnText(3) ?? "") ?? .unknown,
                evidenceSummary: statement.columnText(4)
            ))
        }
        return results }
    }

    public func fetchCapabilityCatalog() throws -> CapabilityCatalog {
        CapabilityCatalog(resources: try fetchAllResources(), relations: try fetchAllRelations())
    }

    public func fetchCapabilityHistory(projectID: String? = nil, through: Date = Date()) throws -> [CapabilityHistory] {
        return try connection.performReadSnapshot { () -> [CapabilityHistory] in
        let statement = try connection.prepare("SELECT c.resource_id, COUNT(*), MAX(c.timestamp) FROM calls c LEFT JOIN sessions s ON s.id = c.session_id WHERE c.resource_id IS NOT NULL AND c.timestamp IS NOT NULL AND c.timestamp <= ? AND (? IS NULL OR s.project_id = ?) GROUP BY c.resource_id ORDER BY c.resource_id")
        statement.bind(through.timeIntervalSince1970, at: 1)
        statement.bind(projectID, at: 2); statement.bind(projectID, at: 3)
        var result: [CapabilityHistory] = []
        while try statement.step() == .row {
            result.append(CapabilityHistory(resourceID: statement.columnText(0) ?? "", callCount: statement.columnInt(1), lastUsedAt: statement.columnIsNull(2) ? nil : Date(timeIntervalSince1970: statement.columnDouble(2))))
        }
        return result }
    }

    public func fetchCapabilityUsageProjects(resourceID: String, through: Date = Date()) throws -> [String] {
        return try connection.performReadSnapshot { () -> [String] in
        let statement = try connection.prepare("SELECT DISTINCT s.project_id FROM calls c JOIN sessions s ON s.id = c.session_id WHERE c.resource_id = ? AND c.timestamp IS NOT NULL AND c.timestamp <= ? AND s.project_id IS NOT NULL ORDER BY s.project_id")
        statement.bind(resourceID, at: 1); statement.bind(through.timeIntervalSince1970, at: 2)
        var result: [String] = []
        while try statement.step() == .row { if let id = statement.columnText(0) { result.append(id) } }
        return result }
    }

    /// Aggregates canonical child-Skill calls for current runtime Plugins.
    /// Plugins without a usable current child mapping are represented by nil.
    public func fetchPluginUsageStats(window: CapabilityQueryWindow, projectID: String? = nil) throws -> [PluginUsageResult] {
        return try connection.performReadSnapshot { () -> [PluginUsageResult] in
        let mappings = PluginUsage.mappings(resources: try fetchAllResources(), relations: try fetchAllRelations())
        return try mappings.map { mapping in
            guard !mapping.skillIDs.isEmpty || !mapping.namespaces.isEmpty else {
                return PluginUsageResult(pluginID: mapping.pluginID, callCount: nil)
            }
            let query = try pluginAttributionQuery(mapping: mapping, projectID: projectID, window: window, detail: false, pageSize: 0, cursor: nil)
            let statement = query.statement
            try query.bind(statement)
            guard try statement.step() == .row else { return PluginUsageResult(pluginID: mapping.pluginID, callCount: 0) }
            let count = statement.columnInt(0)
            let projects = (statement.columnText(4) ?? "").split(separator: ",").map(String.init)
            return PluginUsageResult(pluginID: mapping.pluginID, callCount: count, inferredCount: statement.columnIsNull(2) ? 0 : statement.columnInt(2), projectIDs: projects, lastUsedAt: statement.columnIsNull(1) ? nil : Date(timeIntervalSince1970: statement.columnDouble(1)), coverage: CoverageState(rawValue: statement.columnText(3) ?? "unknown") ?? .unknown)
        } }
    }

    public func fetchPluginInvocations(pluginID: String, projectID: String? = nil, window: CapabilityQueryWindow? = nil, pageSize: Int = 50, cursor: String? = nil) throws -> PluginInvocationPage {
        return try connection.performReadSnapshot { () -> PluginInvocationPage in
        guard let mapping = PluginUsage.mappings(resources: try fetchAllResources(), relations: try fetchAllRelations()).first(where: { $0.pluginID == pluginID }) else { return PluginInvocationPage(items: [], nextCursor: nil) }
        let limit = max(1, min(pageSize, 200))
        let query = try pluginAttributionQuery(mapping: mapping, projectID: projectID, window: window, detail: true, pageSize: limit, cursor: cursor)
        let statement = query.statement; try query.bind(statement)
        var items: [AttributedInvocation] = []
        while try statement.step() == .row {
            let event = InvocationEvent(id: statement.columnText(0) ?? "", sessionID: statement.columnText(1) ?? "", parentCallID: statement.columnText(2), ordinal: statement.columnInt(3), timestamp: statement.columnIsNull(4) ? nil : Date(timeIntervalSince1970: statement.columnDouble(4)), actorName: statement.columnText(5), resourceID: statement.columnText(6), kind: InvocationKind(rawValue: statement.columnText(7) ?? "") ?? .unknown, status: InvocationStatus(rawValue: statement.columnText(8) ?? "") ?? .unknown, durationMs: statement.columnIsNull(9) ? nil : statement.columnInt(9), confidence: EvidenceConfidence(rawValue: statement.columnText(10) ?? "") ?? .unknown, errorCategory: statement.columnText(11))
            items.append(AttributedInvocation(original: event, projectID: statement.columnText(12), pluginID: pluginID, confidence: EvidenceConfidence(rawValue: statement.columnText(13) ?? "unknown") ?? .unknown))
        }
        let hasMore = items.count > limit; if hasMore { items.removeLast() }
        let next = hasMore ? items.last?.original.timestamp.map { "\($0.timeIntervalSince1970)|\(items.last!.original.id)" } : nil
        return PluginInvocationPage(items: items, nextCursor: next) }
    }

    private struct PluginAttributionQuery {
        let statement: SQLiteStatement
        let bind: (SQLiteStatement) throws -> Void
    }

    /// One SQL candidate/leaf CTE is used for both aggregates and detail pages.
    /// The recursive tree removes only wrapper/descendant rows attributed to
    /// this same plugin; unrelated sibling calls remain independent evidence.
    private func pluginAttributionQuery(mapping: PluginUsage.Mapping, projectID: String?, window: CapabilityQueryWindow?, detail: Bool, pageSize: Int, cursor: String?) throws -> PluginAttributionQuery {
        guard !mapping.skillIDs.isEmpty || !mapping.namespaces.isEmpty else {
            let statement = try connection.prepare(detail ? "SELECT NULL WHERE 0" : "SELECT 0, NULL, 0, 'unknown', NULL WHERE 0")
            return PluginAttributionQuery(statement: statement, bind: { _ in })
        }
        var matchParts: [String] = []
        if !mapping.skillIDs.isEmpty { matchParts.append("c.resource_id IN (\(Array(repeating: "?", count: mapping.skillIDs.count).joined(separator: ",")))") }
        for _ in mapping.namespaces { matchParts.append("substr(c.resource_id,1,length(?)) = ? AND length(c.resource_id) > length(?)") }
        let match = matchParts.joined(separator: " OR ")
        let base = """
        WITH RECURSIVE candidates AS (
          SELECT c.id,c.session_id,c.parent_call_id,c.ordinal,c.timestamp,c.actor_name,c.resource_id,c.call_kind,c.status,c.duration_ms,c.confidence,c.error_category,s.project_id,
                 ? AS plugin_id,
                 CASE WHEN c.resource_id IN (\(mapping.skillIDs.isEmpty ? "NULL" : Array(repeating: "?", count: mapping.skillIDs.count).joined(separator: ","))) THEN c.confidence ELSE 'inferred' END AS attribution_confidence
          FROM calls c LEFT JOIN sessions s ON s.id=c.session_id
          WHERE (\(match)) AND c.timestamp IS NOT NULL
            AND (? IS NULL OR s.project_id=?)
            AND (? IS NULL OR c.timestamp>=?) AND (? IS NULL OR c.timestamp<=?)
        ), descendants(ancestor_id, descendant_id, session_id, path) AS (
          SELECT p.id,c.id,p.session_id,'|' || p.id || '|' || c.id || '|' FROM calls p JOIN candidates a ON a.id=p.id JOIN calls c ON c.parent_call_id=p.id AND c.session_id=p.session_id
          UNION ALL SELECT d.ancestor_id,c.id,d.session_id,d.path || c.id || '|' FROM descendants d JOIN calls c ON c.parent_call_id=d.descendant_id AND c.session_id=d.session_id
            WHERE instr(d.path, '|' || c.id || '|') = 0
        ), leaves AS (
          SELECT a.* FROM candidates a
          WHERE NOT EXISTS (SELECT 1 FROM descendants d JOIN candidates child ON child.id=d.descendant_id AND child.plugin_id=a.plugin_id WHERE d.ancestor_id=a.id)
        )
        """
        let select: String
        if detail {
            select = "SELECT id,session_id,parent_call_id,ordinal,timestamp,actor_name,resource_id,call_kind,status,duration_ms,confidence,error_category,project_id,attribution_confidence FROM leaves WHERE (? IS NULL OR (timestamp<? OR (timestamp=? AND id<?))) ORDER BY timestamp DESC,id DESC LIMIT ?"
        } else {
            select = "SELECT COUNT(*),MAX(timestamp),SUM(CASE WHEN attribution_confidence='inferred' THEN 1 ELSE 0 END),CASE WHEN SUM(CASE WHEN COALESCE((SELECT coverage FROM sessions WHERE id=leaves.session_id),'unknown')!='complete' THEN 1 ELSE 0 END)>0 THEN 'partial' ELSE 'complete' END,(SELECT GROUP_CONCAT(project_id) FROM (SELECT DISTINCT project_id FROM leaves WHERE project_id IS NOT NULL ORDER BY project_id)) FROM leaves"
        }
        let statement = try connection.prepare(base + select)
        return PluginAttributionQuery(statement: statement) { statement in
            var i: Int32 = 1
            statement.bind(mapping.pluginID, at: i); i += 1
            // The skill IDs occur once in the confidence CASE and once in the
            // candidate predicate.
            for id in mapping.skillIDs { statement.bind(id, at: i); i += 1 }
            for id in mapping.skillIDs { statement.bind(id, at: i); i += 1 }
            for namespace in mapping.namespaces {
                let prefix = "tool:mcp__\(namespace)__"
                statement.bind(prefix, at: i); i += 1; statement.bind(prefix, at: i); i += 1; statement.bind(prefix, at: i); i += 1
            }
            statement.bind(projectID, at: i); i += 1; statement.bind(projectID, at: i); i += 1
            let start = window?.start.timeIntervalSince1970; let end = window?.end.timeIntervalSince1970
            statement.bind(start, at: i); i += 1; statement.bind(start, at: i); i += 1; statement.bind(end, at: i); i += 1; statement.bind(end, at: i); i += 1
            if detail {
                let parts = cursor?.split(separator: "|", maxSplits: 1).map(String.init)
                let time = parts?.first.flatMap(Double.init); let id = parts?.count == 2 ? parts?[1] : nil
                statement.bind(time != nil && id != nil ? cursor : nil, at: i); i += 1; statement.bind(time, at: i); i += 1; statement.bind(time, at: i); i += 1; statement.bind(id, at: i); i += 1
                statement.bind(max(1, min(pageSize, 200)) + 1, at: i)
            }
        }
    }

    /// One-hop relations for a resource (outgoing and incoming).
    public func fetchRelations(for resourceID: String) throws -> [ResourceRelation] {
        let statement = try connection.prepare(
            "SELECT source_resource_id, target_resource_id, relation_kind, confidence, evidence_summary FROM resource_relations WHERE source_resource_id = ? OR target_resource_id = ? ORDER BY relation_kind, source_resource_id"
        )
        statement.bind(resourceID, at: 1)
        statement.bind(resourceID, at: 2)
        var results: [ResourceRelation] = []
        while try statement.step() == .row {
            results.append(ResourceRelation(
                sourceResourceID: statement.columnText(0) ?? "",
                targetResourceID: statement.columnText(1) ?? "",
                relationKind: statement.columnText(2) ?? "",
                confidence: EvidenceConfidence(rawValue: statement.columnText(3) ?? "") ?? .unknown,
                evidenceSummary: statement.columnText(4)
            ))
        }
        return results
    }

    public func fetchAllTokenSnapshots() throws -> [TokenUsageSnapshot] {
        queryObserver?(.allTokens)
        let statement = try connection.prepare(
            "SELECT id, session_id, captured_at, input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, coverage, model_id, model_name, model_confidence FROM token_usage_snapshots ORDER BY captured_at"
        )
        var results: [TokenUsageSnapshot] = []
        while try statement.step() == .row {
            let usage = try TokenUsage(
                inputTokens: statement.columnInt64(3),
                cachedInputTokens: statement.columnInt64(4),
                cacheWriteInputTokens: statement.columnInt64(5),
                outputTokens: statement.columnInt64(6),
                reasoningOutputTokens: statement.columnInt64(7),
                totalTokens: statement.columnInt64(8),
                coverage: CoverageState(rawValue: statement.columnText(9) ?? "") ?? .unknown
            )
            results.append(TokenUsageSnapshot(
                id: statement.columnText(0) ?? "",
                sessionID: statement.columnText(1) ?? "",
                capturedAt: Date(timeIntervalSince1970: statement.columnDouble(2)),
                usage: usage,
                modelID: statement.columnText(10),
                modelName: statement.columnText(11),
                modelConfidence: EvidenceConfidence(rawValue: statement.columnText(12) ?? "") ?? .unknown
            ))
        }
        return results
    }

    public func count(_ table: String) throws -> Int {
        return try connection.performReadSnapshot { () -> Int in
        let statement = try connection.prepare("SELECT COUNT(*) FROM \(table)")
        guard try statement.step() == .row else { return 0 }
        return statement.columnInt(0) }
    }

    /// All (table, column) pairs for schema privacy checks.
    public func schemaColumns() throws -> [(table: String, column: String)] {
        let tableStatement = try connection.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        var columns: [(String, String)] = []
        while try tableStatement.step() == .row {
            guard let table = tableStatement.columnText(0) else { continue }
            let pragma = try connection.prepare("PRAGMA table_info(\(table))")
            while try pragma.step() == .row {
                if let column = pragma.columnText(1) {
                    columns.append((table, column))
                }
            }
        }
        return columns
    }
}
