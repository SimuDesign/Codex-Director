import XCTest
@testable import DirectorCore

final class DatabaseStoreTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.sqlite")
    }

    private func makeStore() throws -> DatabaseStore {
        try DatabaseStore(url: tempDatabaseURL())
    }

    private func sampleBatch(sessionID: String = "session:1") throws -> PersistedSessionBatch {
        let usage = try TokenUsage(
            inputTokens: 10, cachedInputTokens: 2, cacheWriteInputTokens: 1,
            outputTokens: 5, reasoningOutputTokens: 3, totalTokens: 21,
            coverage: .complete
        )
        let quota = try QuotaSnapshot(
            id: "quota:1", capturedAt: epoch, windowMinutes: 10_080, usedPercent: 42,
            resetsAt: nil, limitID: "weekly", limitName: "Weekly", confidence: .exact
        )
        return PersistedSessionBatch(
            session: TaskSummary(
                id: sessionID, projectID: nil, startedAt: epoch,
                endedAt: epoch.addingTimeInterval(100), status: .completed,
                coverage: .complete, parserVersion: "1.0.0",
                sourceFileID: "file-\(sessionID)", title: nil
            ),
            calls: [
                InvocationEvent(
                    id: "call-\(sessionID)-1", sessionID: sessionID, parentCallID: nil,
                    ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read",
                    kind: .tool, status: .completed, durationMs: 10,
                    confidence: .exact, errorCategory: nil
                ),
                InvocationEvent(
                    id: "call-\(sessionID)-2", sessionID: sessionID, parentCallID: nil,
                    ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "tool:write",
                    kind: .tool, status: .failed, durationMs: 5,
                    confidence: .exact, errorCategory: "exit_1"
                ),
            ],
            tokenSnapshots: [
                TokenUsageSnapshot(id: "t-\(sessionID)", sessionID: sessionID, capturedAt: epoch, usage: usage),
            ],
            quotaSnapshots: [quota],
            findings: []
        )
    }

    private func sampleBatch(
        sessionID: String,
        quotaSnapshots: [QuotaSnapshot],
        tokenUsage: Int64 = 21
    ) throws -> PersistedSessionBatch {
        let usage = try TokenUsage(
            inputTokens: 10, cachedInputTokens: 2, cacheWriteInputTokens: 1,
            outputTokens: 5, reasoningOutputTokens: 3, totalTokens: tokenUsage,
            coverage: .complete
        )
        return PersistedSessionBatch(
            session: TaskSummary(
                id: sessionID, projectID: nil, startedAt: epoch,
                endedAt: epoch.addingTimeInterval(100), status: .completed,
                coverage: .complete, parserVersion: "1.0.0",
                sourceFileID: "file-\(sessionID)", title: nil
            ),
            calls: [
                InvocationEvent(
                    id: "call-\(sessionID)-1", sessionID: sessionID, parentCallID: nil,
                    ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read",
                    kind: .tool, status: .completed, durationMs: 10,
                    confidence: .exact, errorCategory: nil
                )
            ],
            tokenSnapshots: [
                TokenUsageSnapshot(id: "t-\(sessionID)", sessionID: sessionID, capturedAt: epoch, usage: usage),
            ],
            quotaSnapshots: quotaSnapshots,
            findings: []
        )
    }

    func testFreshMigrationAppliesSchema() async throws {
        let store = try makeStore()
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 0)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 0)
        let count_resources = try await store.count("resources");
        XCTAssertEqual(count_resources, 0)
    }

    func testReopenExistingDatabase() async throws {
        let url = try tempDatabaseURL()
        let first = try DatabaseStore(url: url)
        try await first.replaceSession(sampleBatch())
        let second = try DatabaseStore(url: url)
        let sessions = try await second.fetchAllSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "session:1")
    }

    func testDuplicateIndexingProducesNoDuplicates() async throws {
        let store = try makeStore()
        try await store.replaceSession(sampleBatch())
        try await store.replaceSession(sampleBatch())
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 1)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 2)
        let count_token_usage_snapshots = try await store.count("token_usage_snapshots");
        XCTAssertEqual(count_token_usage_snapshots, 1)
        let count_quota_snapshots = try await store.count("quota_snapshots");
        XCTAssertEqual(count_quota_snapshots, 1)
    }

    func testTransactionRollbackUndoesWrites() async throws {
        let store = try makeStore()
        let resource = sampleResource()
        struct Boom: Error {}
        do {
            try await store.inTransaction { database in
                try database.insertResources([resource])
                throw Boom()
            }
            XCTFail("expected the transaction body to throw")
        } catch is Boom {
            // expected
        }
        let count_resources = try await store.count("resources");
        XCTAssertEqual(count_resources, 0)
    }

    func testCascadeSessionDeletionOnlyInsideDerivedDB() async throws {
        let store = try makeStore()
        try await store.replaceSession(sampleBatch())
        try await store.deleteSession(id: "session:1")
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 0)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 0)
        let count_token_usage_snapshots = try await store.count("token_usage_snapshots");
        XCTAssertEqual(count_token_usage_snapshots, 0)
        // Quota snapshots are not session-scoped and remain untouched.
        let count_quota_snapshots = try await store.count("quota_snapshots");
        XCTAssertEqual(count_quota_snapshots, 1)
    }

    func testSchemaContainsNoForbiddenPrivacyColumns() async throws {
        let store = try makeStore()
        let columns = try await store.schemaColumns()
        let forbidden: Set<String> = [
            "prompt", "response", "message", "arguments", "argument", "output",
            "command", "api_key", "cookie", "authorization", "password",
            "secret", "credential",
        ]
        for (table, column) in columns {
            XCTAssertFalse(forbidden.contains(column), "forbidden column '\(column)' in \(table)")
        }
    }

    func testResourceRoundTrip() async throws {
        let store = try makeStore()
        try await store.insertResources([sampleResource()])
        let fetched = try await store.fetchAllResources()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first, sampleResource())
    }

    func testDeleteAllDataRebuildsSchema() async throws {
        let store = try makeStore()
        try await store.replaceSession(sampleBatch())
        try await store.deleteAllData()
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 0)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 0)
        // Rebuild works after wipe.
        try await store.replaceSession(sampleBatch())
        let count_sessions_after_rebuild = try await store.count("sessions");
        XCTAssertEqual(count_sessions_after_rebuild, 1)
    }

    func testQuotaInsertOrIgnoreDeduplicatesAcrossSessions() async throws {
        let store = try makeStore()
        try await store.replaceSession(sampleBatch(sessionID: "session:1"))
        try await store.replaceSession(sampleBatch(sessionID: "session:2"))
        let count_quota_snapshots = try await store.count("quota_snapshots");
        XCTAssertEqual(count_quota_snapshots, 1)
    }

    func testQuotaInsertOrReplaceKeepsLatestByInputOrderForConflictingWindowKey() async throws {
        let store = try makeStore()
        let first = try QuotaSnapshot(
            id: "quota-collision-1",
            capturedAt: epoch,
            windowMinutes: 10_080,
            usedPercent: 20,
            resetsAt: nil,
            limitID: "weekly",
            limitName: "Weekly",
            confidence: .exact
        )
        let second = try QuotaSnapshot(
            id: "quota-collision-2",
            capturedAt: epoch,
            windowMinutes: 10_080,
            usedPercent: 80,
            resetsAt: nil,
            limitID: "weekly",
            limitName: "Weekly",
            confidence: .exact
        )

        try await store.replaceSession(try sampleBatch(
            sessionID: "session:collision",
            quotaSnapshots: [first, second]
        ))

        let quotas = try await store.fetchAllQuotaSnapshots()
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas.first?.id, "quota-collision-2")
        XCTAssertEqual(quotas.first?.usedPercent, 80)
    }

    func testCheckpointRoundTrip() async throws {
        let store = try makeStore()
        let checkpoint = IndexCheckpoint(
            sourceFileID: "file:1", sourceSize: 100, sourceMtime: 123.0,
            byteOffset: 42, parserVersion: "1.0.0", indexedAt: epoch
        )
        try await store.upsertCheckpoint(checkpoint)
        let fetched = try await store.fetchCheckpoint(sourceFileID: "file:1")
        XCTAssertEqual(fetched, checkpoint)
    }

    func testSessionCallsTokensRoundTrip() async throws {        let store = try makeStore()
        try await store.replaceSession(sampleBatch())
        let calls = try await store.fetchCalls(sessionID: "session:1")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.ordinal), [0, 1])
        XCTAssertEqual(calls[1].status, .failed)
        let tokens = try await store.fetchTokenSnapshots(sessionID: "session:1")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.usage.totalTokens, 21)
        let quotas = try await store.fetchAllQuotaSnapshots()
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas.first?.isWeeklyWindow, true)
    }

    func testTokenModelAttributionRoundTrip() async throws {
        let store = try makeStore()
        let usage = try TokenUsage(
            inputTokens: 10, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 5, reasoningOutputTokens: 0, totalTokens: 15,
            coverage: .complete
        )
        let base = try sampleBatch()
        let batch = PersistedSessionBatch(
            session: base.session,
            calls: base.calls,
            tokenSnapshots: [TokenUsageSnapshot(
                id: "token-model",
                sessionID: base.session.id,
                capturedAt: epoch,
                usage: usage,
                modelID: ModelIdentity.codex53SparkID,
                modelName: ModelIdentity.codex53SparkDisplayName,
                modelConfidence: .exact
            )],
            quotaSnapshots: base.quotaSnapshots,
            findings: []
        )
        try await store.replaceSession(batch)
        let snapshot = try await store.fetchTokenSnapshots(sessionID: base.session.id).first
        XCTAssertEqual(snapshot?.modelID, ModelIdentity.codex53SparkID)
        XCTAssertEqual(snapshot?.modelName, ModelIdentity.codex53SparkDisplayName)
        XCTAssertEqual(snapshot?.modelConfidence, .exact)
    }

    func testVersionTwoDatabaseMigratesTokenModelColumnsAndOldRowsRemainUnknown() async throws {
        let url = try tempDatabaseURL()
        guard let connection = SQLiteConnection(url: url) else {
            return XCTFail("could not open temporary SQLite database")
        }
        XCTAssertTrue(connection.exec("""
            CREATE TABLE token_usage_snapshots (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                captured_at REAL NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                cache_write_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                coverage TEXT NOT NULL
            )
            """))
        XCTAssertTrue(connection.exec("INSERT INTO token_usage_snapshots VALUES ('old-token','old-session',1700000000,1,0,0,2,0,3,'complete')"))
        connection.setUserVersion(2)

        let store = try DatabaseStore(url: url)
        let columns = try await store.schemaColumns()
        let tokenColumns = Set(columns.filter { $0.table == "token_usage_snapshots" }.map(\.column))
        XCTAssertTrue(tokenColumns.isSuperset(of: ["model_id", "model_name", "model_confidence"]))
        let old = try await store.fetchAllTokenSnapshots().first
        XCTAssertNil(old?.modelID)
        XCTAssertEqual(old?.modelConfidence, .unknown)
    }

    func testVersionThreeDatabaseAddsNullableSourceModificationDate() async throws {
        let url = try tempDatabaseURL()
        guard let connection = SQLiteConnection(url: url) else {
            return XCTFail("could not open temporary SQLite database")
        }
        XCTAssertTrue(connection.exec("""
            CREATE TABLE resources (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
                scope TEXT NOT NULL, project_id TEXT, availability TEXT NOT NULL,
                confidence TEXT NOT NULL, description TEXT, source_root_id TEXT NOT NULL,
                relative_source_path TEXT, source_path_hash TEXT, last_seen_at REAL NOT NULL,
                ownership TEXT NOT NULL DEFAULT 'unknown', origin TEXT NOT NULL DEFAULT 'unknown',
                classification_confidence TEXT NOT NULL DEFAULT 'unknown', origin_identifier TEXT,
                source_version TEXT, content_fingerprint TEXT, modified INTEGER NOT NULL DEFAULT 0
            )
            """))
        XCTAssertTrue(connection.exec("INSERT INTO resources (id,name,kind,scope,availability,confidence,description,source_root_id,last_seen_at) VALUES ('agent:old','Old','agent','global','unknown','exact','Old summary','root',1700000000)"))
        connection.setUserVersion(3)

        let store = try DatabaseStore(url: url)
        let columns = try await store.schemaColumns()
        let resourceColumns = Set(columns.filter { $0.table == "resources" }.map(\.column))
        XCTAssertTrue(resourceColumns.contains("source_modified_at"))
        let old = try await store.fetchAllResources().first
        XCTAssertEqual(old?.id, "agent:old")
        XCTAssertNil(old?.sourceModifiedAt)
    }

    func testVersionOneDatabaseMigratesAllResourceFieldsThroughVersionFour() async throws {
        let url = try tempDatabaseURL()
        guard let connection = SQLiteConnection(url: url) else {
            return XCTFail("could not open temporary SQLite database")
        }
        XCTAssertTrue(connection.exec("""
            CREATE TABLE resources (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
                scope TEXT NOT NULL, project_id TEXT, availability TEXT NOT NULL,
                confidence TEXT NOT NULL, description TEXT, source_root_id TEXT NOT NULL,
                relative_source_path TEXT, source_path_hash TEXT, last_seen_at REAL NOT NULL
            )
            """))
        XCTAssertTrue(connection.exec("INSERT INTO resources (id,name,kind,scope,availability,confidence,description,source_root_id,last_seen_at) VALUES ('skill:v1','V1 Skill','skill','global','unknown','exact','Synthetic v1','root',1700000000)"))
        connection.setUserVersion(1)

        let store = try DatabaseStore(url: url)
        let old = try await store.fetchAllResources().first
        XCTAssertEqual(old?.id, "skill:v1")
        XCTAssertEqual(old?.ownership, .unknown)
        XCTAssertNil(old?.sourceModifiedAt)
        let columns = try await store.schemaColumns()
        XCTAssertTrue(columns.contains { $0.table == "resources" && $0.column == "source_modified_at" })
    }

    func testVersionOneDatabaseMigratesExistingTokenTableThroughVersionFour() async throws {
        let url = try tempDatabaseURL()
        guard let connection = SQLiteConnection(url: url) else {
            return XCTFail("could not open temporary SQLite database")
        }
        XCTAssertTrue(connection.exec("""
            CREATE TABLE resources (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
                scope TEXT NOT NULL, project_id TEXT, availability TEXT NOT NULL,
                confidence TEXT NOT NULL, description TEXT, source_root_id TEXT NOT NULL,
                relative_source_path TEXT, source_path_hash TEXT, last_seen_at REAL NOT NULL
            )
            """))
        XCTAssertTrue(connection.exec("""
            CREATE TABLE token_usage_snapshots (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                captured_at REAL NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_input_tokens INTEGER NOT NULL,
                cache_write_input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                reasoning_output_tokens INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                coverage TEXT NOT NULL
            )
            """))
        XCTAssertTrue(connection.exec("INSERT INTO token_usage_snapshots VALUES ('v1-token','old-session',1700000000,1,0,0,2,0,3,'complete')"))
        connection.setUserVersion(1)

        let store = try DatabaseStore(url: url)
        let columns = try await store.schemaColumns()
        let tokenColumns = Set(columns.filter { $0.table == "token_usage_snapshots" }.map(\.column))
        XCTAssertTrue(tokenColumns.isSuperset(of: ["model_id", "model_name", "model_confidence"]))
        let old = try await store.fetchAllTokenSnapshots().first
        XCTAssertEqual(old?.id, "v1-token")
        XCTAssertNil(old?.modelID)
        XCTAssertEqual(old?.modelConfidence, .unknown)
    }

    func testVersionTwoDatabaseMigratesSourceModificationDateAlongsideTokenFields() async throws {
        let url = try tempDatabaseURL()
        guard let connection = SQLiteConnection(url: url) else {
            return XCTFail("could not open temporary SQLite database")
        }
        XCTAssertTrue(connection.exec("""
            CREATE TABLE resources (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
                scope TEXT NOT NULL, project_id TEXT, availability TEXT NOT NULL,
                confidence TEXT NOT NULL, description TEXT, source_root_id TEXT NOT NULL,
                relative_source_path TEXT, source_path_hash TEXT, last_seen_at REAL NOT NULL,
                ownership TEXT NOT NULL DEFAULT 'unknown', origin TEXT NOT NULL DEFAULT 'unknown',
                classification_confidence TEXT NOT NULL DEFAULT 'unknown', origin_identifier TEXT,
                source_version TEXT, content_fingerprint TEXT, modified INTEGER NOT NULL DEFAULT 0
            )
            """))
        XCTAssertTrue(connection.exec("INSERT INTO resources (id,name,kind,scope,availability,confidence,description,source_root_id,last_seen_at) VALUES ('agent:v2','V2 Agent','agent','global','unknown','exact','Synthetic v2','root',1700000000)"))
        connection.setUserVersion(2)

        let store = try DatabaseStore(url: url)
        let old = try await store.fetchAllResources().first
        XCTAssertEqual(old?.id, "agent:v2")
        XCTAssertNil(old?.sourceModifiedAt)
        let resourceColumns = Set((try await store.schemaColumns()).filter { $0.table == "resources" }.map(\.column))
        XCTAssertTrue(resourceColumns.contains("source_modified_at"))
    }

    func testReplaceFindingsIsAtomicAndIdempotent() async throws {
        let store = try makeStore()
        let finding = ReviewFinding(
            id: "finding:1", ruleID: "rule.parser-coverage", resourceID: nil,
            sessionID: "session:1", severity: .info, confidence: .exact,
            summary: "Parser coverage", evidenceSummary: "partial",
            coverage: .partial, createdAt: epoch, remediationStatus: .open
        )
        try await store.replaceFindings([finding])
        let count_before = try await store.count("review_findings");
        XCTAssertEqual(count_before, 1)

        // Replacement clears resolved findings atomically.
        try await store.replaceFindings([])
        let count_after = try await store.count("review_findings");
        XCTAssertEqual(count_after, 0)
    }

    private func sampleResource() -> CapabilityResource {
        CapabilityResource(
            id: "skill:example", name: "example", kind: .skill, status: .success,
            scope: .global, projectID: nil, confidence: .exact, summary: "Example",
            sourceRootID: "global-skills", relativeSourcePath: "example/SKILL.md",
            sourcePathHash: "abc", lastSeenAt: epoch
        )
    }
}
