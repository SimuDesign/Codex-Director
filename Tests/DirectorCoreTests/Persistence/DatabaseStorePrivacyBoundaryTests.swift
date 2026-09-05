import XCTest
@testable import DirectorCore

/// Production write-boundary privacy tests: the SQLite layer must reject
/// credential-like or unredacted-home-path values before any row changes.
/// Synthetic markers only; never real credentials, usernames, or home paths.
final class DatabaseStorePrivacyBoundaryTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> DatabaseStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-priv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DatabaseStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    private func resource(summary: String, relativePath: String = "unsafe/SKILL.md") -> CapabilityResource {
        CapabilityResource(
            id: "skill:unsafe", name: "unsafe", kind: .skill, status: .unknown,
            scope: .global, projectID: nil, confidence: .exact, summary: summary,
            sourceRootID: "root", relativeSourcePath: relativePath,
            sourcePathHash: nil, lastSeenAt: epoch
        )
    }

    private func safeBatch(sessionID: String = "session:1") throws -> PersistedSessionBatch {
        PersistedSessionBatch(
            session: TaskSummary(
                id: sessionID, projectID: nil, startedAt: epoch, endedAt: nil,
                status: .completed, coverage: .complete, parserVersion: "1.0.0",
                sourceFileID: "file-\(sessionID)", title: nil
            ),
            calls: [
                InvocationEvent(id: "call-\(sessionID)-1", sessionID: sessionID, parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: 1, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "call-\(sessionID)-2", sessionID: sessionID, parentCallID: nil, ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "tool:write", kind: .tool, status: .completed, durationMs: 1, confidence: .exact, errorCategory: nil),
            ],
            tokenSnapshots: [],
            quotaSnapshots: [],
            findings: []
        )
    }

    private func assertRejected<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await operation()
            XCTFail("expected persistenceRejected", file: file, line: line)
        } catch let error as DatabaseStore.StoreError {
            guard case .persistenceRejected = error else {
                XCTFail("unexpected error kind: \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    func testInsertResourcesRejectsCredentialLikeValueAtDatabaseBoundary() async throws {
        let store = try makeStore()
        try await assertRejected {
            try await store.insertResources([
                resource(summary: "Authorization: Bearer synthetic-example")
            ])
        }
        let count = try await store.count("resources")
        XCTAssertEqual(count, 0)
    }

    func testInsertRelationsRejectsCredentialLikeEvidenceAtDatabaseBoundary() async throws {
        let store = try makeStore()
        let relation = ResourceRelation(
            sourceResourceID: "agent:a", targetResourceID: "skill:b",
            relationKind: "uses", confidence: .inferred,
            evidenceSummary: "Authorization: Bearer synthetic-example"
        )
        try await assertRejected {
            try await store.insertRelations([relation])
        }
        let count = try await store.count("resource_relations")
        XCTAssertEqual(count, 0)
    }

    func testReplaceSessionRejectsUnsafeCallBeforeAnyRowsChange() async throws {
        let store = try makeStore()
        try await store.replaceSession(safeBatch())

        var unsafe = try safeBatch()
        unsafe = PersistedSessionBatch(
            session: unsafe.session,
            calls: [
                InvocationEvent(id: "call-unsafe", sessionID: "session:1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: 1, confidence: .exact, errorCategory: "Authorization: Bearer synthetic-example"),
            ],
            tokenSnapshots: unsafe.tokenSnapshots,
            quotaSnapshots: unsafe.quotaSnapshots,
            findings: unsafe.findings
        )

        try await assertRejected {
            try await store.replaceSession(unsafe, resetExisting: true)
        }

        // The previously persisted safe rows are untouched.
        let sessions = try await store.count("sessions")
        let calls = try await store.count("calls")
        XCTAssertEqual(sessions, 1)
        XCTAssertEqual(calls, 2)
        let persisted = try await store.fetchCalls(sessionID: "session:1")
        XCTAssertEqual(Set(persisted.map(\.id)), ["call-session:1-1", "call-session:1-2"])
    }

    func testDatabaseBoundaryRejectsUnredactedSyntheticHomePath() async throws {
        let store = try makeStore()
        try await assertRejected {
            try await store.insertResources([
                resource(summary: "ok", relativePath: "/Users/exampleuser/private/SKILL.md")
            ])
        }
        let count = try await store.count("resources")
        XCTAssertEqual(count, 0)
    }

    func testPrivacyErrorNeverEchoesRejectedValue() async throws {
        let store = try makeStore()
        let marker = "Authorization: Bearer synthetic-example"
        do {
            try await store.insertResources([resource(summary: marker)])
            XCTFail("expected rejection")
        } catch let error as DatabaseStore.StoreError {
            guard case .persistenceRejected(let recordType, let field) = error else {
                return XCTFail("unexpected error kind")
            }
            XCTAssertEqual(recordType, "resources")
            XCTAssertEqual(field, "description")
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.localizedCaseInsensitiveContains("bearer"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("synthetic"))
            XCTAssertFalse(description.contains("/Users/"))
            XCTAssertFalse(description.contains("exampleuser"))
        } catch {
            XCTFail("unexpected error")
        }
    }

    func testTokenModelPathIsRejectedAtPersistenceBoundary() async throws {
        let store = try makeStore()
        let base = try safeBatch()
        let usage = try TokenUsage(
            inputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 1, reasoningOutputTokens: 0, totalTokens: 2,
            coverage: .complete
        )
        let unsafe = PersistedSessionBatch(
            session: base.session,
            calls: base.calls,
            tokenSnapshots: [TokenUsageSnapshot(
                id: "unsafe-token",
                sessionID: base.session.id,
                capturedAt: epoch,
                usage: usage,
                modelID: "/Users/exampleuser/model",
                modelName: "model",
                modelConfidence: .exact
            )],
            quotaSnapshots: [],
            findings: []
        )
        try await assertRejected { try await store.replaceSession(unsafe) }
        let snapshotCount = try await store.count("token_usage_snapshots")
        XCTAssertEqual(snapshotCount, 0)
    }
}
