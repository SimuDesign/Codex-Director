import XCTest
@testable import DirectorCore

final class QuotaHistoryQueryTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    private func quota(_ id: String, _ at: Date, source: String?, name: String? = nil, window: Int = 10_080, used: Double = 10) throws -> QuotaSnapshot {
        try QuotaSnapshot(id: id, capturedAt: at, windowMinutes: window, usedPercent: used, resetsAt: nil, limitID: source, limitName: name, confidence: .exact)
    }

    private func store() throws -> DatabaseStore {
        try DatabaseStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("history-query-\(UUID().uuidString).sqlite"))
    }

    private func insert(_ store: DatabaseStore, _ rows: [QuotaSnapshot]) async throws {
        let session = TaskSummary(id: "session:\(UUID().uuidString)", projectID: nil, startedAt: asOf, endedAt: asOf, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "file", title: nil)
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [], tokenSnapshots: [], quotaSnapshots: rows, findings: []))
    }

    func testSelectedSourceWindowPredecessorAndStableTimestampTie() async throws {
        let store = try store()
        let query = QuotaHistoryQuery(sourceKey: "id:selected", asOf: asOf, timeZone: zone)
        let start = query.contextStart
        try await insert(store, [
            quota("older", start.addingTimeInterval(-3_600), source: "selected", used: 8),
            quota("a", start.addingTimeInterval(-60), source: "selected", used: 10),
            quota("z", start.addingTimeInterval(-60), source: "selected", used: 20),
            quota("first", start.addingTimeInterval(3_600), source: "selected", used: 25),
            quota("other", start.addingTimeInterval(3_600), source: "other", used: 90),
            quota("short", start.addingTimeInterval(3_600), source: "selected", window: 300, used: 90),
            quota("future", asOf.addingTimeInterval(1), source: "selected", used: 90)
        ])
        let result = try await store.fetchQuotaHistory(query: query)
        XCTAssertEqual(result.days.count, 60)
        XCTAssertEqual(result.recordedDayCount(for: .sixtyDays), 1)
        XCTAssertEqual(result.days.first?.baseline?.usedPercent, 20)
        XCTAssertEqual(result.days.first?.usedPercentDelta, 5)
        XCTAssertEqual(result.lastObservedAt, start.addingTimeInterval(3_600))
        XCTAssertEqual(result.sourceKey, "id:selected")
    }

    func testUnknownSourceDoesNotMergeNamelessRowsAndCancellationThrows() async throws {
        let store = try store()
        try await insert(store, [quota("unknown", asOf.addingTimeInterval(-60), source: nil, used: 50)])
        let empty = try await store.fetchQuotaHistory(query: .init(sourceKey: "unknown", asOf: asOf, timeZone: zone))
        XCTAssertEqual(empty.recordedDayCount(for: .sixtyDays), 0)
        let token = SQLiteCancellationToken()
        token.cancel()
        do {
            _ = try await store.fetchQuotaHistory(query: .init(sourceKey: "id:selected", asOf: asOf, timeZone: zone), cancellation: token)
            XCTFail("A cancelled query must not return an empty success")
        } catch SQLiteError.cancelled {
            // expected
        }
    }

    func testNamedLegacySourceNeverIncludesIdentifiedSourceWithSameName() async throws {
        let store = try store()
        let at = asOf.addingTimeInterval(-3_600)
        try await insert(store, [
            quota("legacy", at, source: nil, name: "same-name", used: 0),
            quota("identified", at, source: "current", name: "same-name", used: 80)
        ])
        let result = try await store.fetchQuotaHistory(query: .init(sourceKey: "name:same-name", asOf: asOf, timeZone: zone))
        XCTAssertEqual(result.recordedDayCount(for: .sevenDays), 1)
        XCTAssertEqual(result.days.last?.observationCount, 1)
        XCTAssertEqual(result.days.last?.usedPercentDelta, 0)
    }
}
