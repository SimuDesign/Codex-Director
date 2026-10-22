import XCTest
@testable import DirectorCore

final class InvocationObservationPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("director-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fixture.sqlite")
    }

    private func call(_ id: String, source: InvocationEvidenceKind?, kind: InvocationKind = .agent, session: String = "child") -> InvocationEvent {
        InvocationEvent(id: id, sessionID: session, parentCallID: nil, ordinal: 0, timestamp: now,
            actorName: nil, resourceID: "agent:sample", kind: kind, status: .completed, durationMs: nil,
            confidence: .inferred, errorCategory: nil, evidenceKind: source)
    }

    private func batch(_ calls: [InvocationEvent], session: String = "child") -> PersistedSessionBatch {
        PersistedSessionBatch(session: TaskSummary(id: session, projectID: "project", startedAt: now, endedAt: now,
            status: .completed, coverage: .complete, parserVersion: "1.4.0", sourceFileID: "source-\(session)", title: nil),
            calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: [])
    }

    func testProvenanceRoundTripsThroughAllCapabilityEvidenceReaders() async throws {
        let store = try DatabaseStore(url: url())
        let original = call("launch", source: .agentDelegation)
        try await store.replaceSession(batch([original]))
        let stored = try await store.fetchCalls(sessionID: "child")
        let bySession = try await store.fetchInvocationsBySession()
        let page = try await store.fetchCapabilityInvocations(resourceID: "agent:sample")
        let companions = try await store.fetchCompanionEvidence(window: .init(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)))
        XCTAssertEqual(stored.first, original)
        XCTAssertEqual(bySession["child"]?.first?.evidenceKind, .agentDelegation)
        XCTAssertEqual(page.items.first?.evidenceKind, .agentDelegation)
        XCTAssertEqual(companions.invocationsBySession["child"]?.first?.evidenceKind, .agentDelegation)
    }

    func testLateDelegationExcludesRequestAndRedundantOwnBriefWithoutDeletingEvidence() async throws {
        let store = try DatabaseStore(url: url())
        try await store.replaceSession(batch([
            call("brief", source: .agentBriefRead), call("structured", source: .structuredInvocation),
            call("request", source: .agentDelegationRequest)]))
        let window = CapabilityQueryWindow(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1))
        let before = try await store.fetchCapabilityUsageStats(window: window)
        XCTAssertEqual(before.first?.callCount, 2)
        try await store.replaceSession(batch([call("launch", source: .agentDelegation)]))
        let after = try await store.fetchCapabilityUsageStats(window: window)
        let periods = try await store.fetchCapabilityUsagePeriodStats(sevenDayWindow: window, thirtyDayWindow: window)
        let history = try await store.fetchCapabilityHistory(through: window.end)
        let raw = try await store.fetchCalls(sessionID: "child")
        XCTAssertEqual(after.first?.callCount, 1)
        XCTAssertEqual(periods.first?.thirtyDay?.callCount, 1)
        XCTAssertEqual(history.first?.callCount, 1)
        XCTAssertEqual(raw.count, 4)
        try await store.replaceSession(batch([call("independent", source: .agentBriefRead, session: "main")], session: "main"))
        let separate = try await store.fetchCapabilityUsageStats(window: window)
        XCTAssertEqual(separate.first?.callCount, 2)
    }

    func testLegacyCallsAndOldCodableRecordsRemainCompatible() async throws {
        let store = try DatabaseStore(url: url())
        let old = call("old", source: nil)
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "evidenceKind")
        let decoded = try JSONDecoder().decode(InvocationEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.evidenceKind)
        try await store.replaceSession(batch([old, call("old2", source: nil)]))
        let usage = try await store.fetchCapabilityUsageStats(window: .init(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)))
        XCTAssertEqual(usage.first?.callCount, 2)
    }

    func testSchemaFiveMigrationPreservesRowsAndAddsOnlyNullableProvenance() throws {
        let location = try url()
        let connection = try XCTUnwrap(SQLiteConnection(url: location))
        for statement in DatabaseSchema.createStatements {
            XCTAssertTrue(connection.exec(statement.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("evidence_kind") }.joined(separator: "\n")))
        }
        XCTAssertTrue(connection.exec("INSERT INTO sessions VALUES ('legacy',NULL,1,2,'completed','complete','1.3.0','legacy-source')"))
        XCTAssertTrue(connection.exec("INSERT INTO calls(id,session_id,ordinal,call_kind,status,confidence) VALUES ('legacy-call','legacy',0,'agent','completed','inferred')"))
        connection.setUserVersion(5)
        try DatabaseSchema.apply(to: connection)
        try DatabaseSchema.apply(to: connection)
        XCTAssertEqual(connection.userVersion(), 6)
        let row = try connection.prepare("SELECT id,evidence_kind FROM calls")
        XCTAssertEqual(try row.step(), .row)
        XCTAssertEqual(row.columnText(0), "legacy-call")
        XCTAssertTrue(row.columnIsNull(1))
    }

    func testFixedProvenanceIsAllowlistedButRawRolePathsAndInputsAreNot() {
        XCTAssertTrue(PersistenceAllowlist.callKeys.contains("evidence_kind"))
        XCTAssertFalse(PersistenceAllowlist.callKeys.contains("agent_type"))
        XCTAssertFalse(PersistenceAllowlist.callKeys.contains("agent_path"))
        XCTAssertFalse(PersistenceAllowlist.callKeys.contains("arguments"))
        XCTAssertFalse(PersistenceAllowlist.callKeys.contains("input"))
    }
}
