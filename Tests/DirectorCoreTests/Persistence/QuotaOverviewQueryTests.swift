import XCTest
@testable import DirectorCore

final class QuotaOverviewQueryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func store() throws -> DatabaseStore { try DatabaseStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString).sqlite")) }
    private func quota(_ id: String, _ date: Date, limitID: String?, name: String?, used: Double = 20, window: Int = 10_080, reset: Date? = nil) throws -> QuotaSnapshot { try QuotaSnapshot(id: id, capturedAt: date, windowMinutes: window, usedPercent: used, resetsAt: reset, limitID: limitID, limitName: name, confidence: .exact) }
    private func insert(_ store: DatabaseStore, _ values: [QuotaSnapshot]) async throws {
        let session = TaskSummary(id: "session:\(UUID().uuidString)", projectID: nil, startedAt: base, endedAt: base, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "file", title: nil)
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [], tokenSnapshots: [], quotaSnapshots: values, findings: []))
    }

    func testWeeklyOnlyCanonicalSourcesStableTiesAndSevenDays() async throws {
        let store = try store(); let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: base); let window = CapabilityQueryWindow(start: start, end: start.addingTimeInterval(6 * 86_400 + 3600), timeZone: calendar.timeZone)
        let values = [
            try quota("a", start.addingTimeInterval(10), limitID: "acct", name: nil, used: 10),
            try quota("b", start.addingTimeInterval(10), limitID: "acct", name: nil, used: 30),
            try quota("name", start.addingTimeInterval(86_400), limitID: nil, name: "Named", used: 40),
            try quota("short", start.addingTimeInterval(100), limitID: "acct", name: nil, window: 300),
            try quota("future", start.addingTimeInterval(8 * 86_400), limitID: "future", name: nil)
        ]
        try await insert(store, values)
        let result = try await store.fetchQuotaOverview(window: window)
        XCTAssertEqual(result.sources.map(\.id), ["id:acct", "name:Named"])
        XCTAssertEqual(result.sources.first?.daily.count, 7)
        XCTAssertEqual(result.sources.first?.daily.first?.observation?.id, "b")
        XCTAssertNil(result.sources.last?.daily[0].observation)
    }

    func testHistoricalOnlySourceKeepsExactlyItsLatestPredecessor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-predecessor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("quota.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: base)
        let window = CapabilityQueryWindow(
            start: start,
            end: start.addingTimeInterval(6 * 86_400 + 3_600),
            timeZone: calendar.timeZone
        )
        let oldTie = start.addingTimeInterval(-7_200)
        try await insert(store, [
            try quota("history-a", start.addingTimeInterval(-10_800), limitID: "history", name: "History", used: 10),
            try quota("history-b", oldTie, limitID: "history", name: "History", used: 20),
            try quota("history-c", oldTie, limitID: "history", name: "History", used: 30),
            try quota("active-before", start.addingTimeInterval(-3_600), limitID: "active", name: "Active", used: 40),
            try quota("active-now", start.addingTimeInterval(3_600), limitID: "active", name: "Active", used: 50)
        ])

        let result = try await store.fetchQuotaOverview(window: window)
        let historical = try XCTUnwrap(result.sources.first(where: { $0.id == "id:history" }))
        XCTAssertEqual(historical.current?.id, "history-c")
        XCTAssertTrue(historical.daily.allSatisfy { $0.observation == nil })
        let active = try XCTUnwrap(result.sources.first(where: { $0.id == "id:active" }))
        XCTAssertEqual(active.current?.id, "active-now")
        XCTAssertEqual(active.daily.compactMap(\.observation).map(\.id), ["active-now"])
    }

    func testDailyUsageIncludesSameCycleGrowthAndResetDayGrowth() async throws {
        let store = try store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: base)
        let oldReset = start.addingTimeInterval(9 * 3_600)
        let newReset = oldReset.addingTimeInterval(7 * 86_400)
        let window = CapabilityQueryWindow(
            start: start,
            end: start.addingTimeInterval(6 * 86_400 + 3_600),
            timeZone: calendar.timeZone
        )
        try await insert(store, [
            try quota("prior", start.addingTimeInterval(-3_600), limitID: "acct", name: "Account", used: 40, reset: oldReset),
            try quota("morning", start.addingTimeInterval(3_600), limitID: "acct", name: "Account", used: 50, reset: oldReset),
            try quota("reset", start.addingTimeInterval(10 * 3_600), limitID: "acct", name: "Account", used: 3, reset: newReset),
            try quota("night", start.addingTimeInterval(20 * 3_600), limitID: "acct", name: "Account", used: 7, reset: newReset)
        ])

        let result = try await store.fetchQuotaOverview(window: window)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.current?.id, "night")
        XCTAssertEqual(source.daily.first?.usedPercentDelta, 17)
        XCTAssertTrue(source.daily.first?.cycleChanged == true)
        XCTAssertNil(source.daily[1].usedPercentDelta)
    }

    func testDailyUsageProjectionSurvivesRecoveredRegressionsAcrossAReset() async throws {
        let store = try store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: base)
        let oldReset = start.addingTimeInterval(3 * 86_400)
        let newReset = start.addingTimeInterval(7 * 86_400 + 12 * 3_600 + 38 * 60)
        let driftedNewReset = newReset.addingTimeInterval(60)
        let window = CapabilityQueryWindow(
            start: start,
            end: start.addingTimeInterval(6 * 86_400 + 3_600),
            timeZone: calendar.timeZone
        )
        try await insert(store, [
            try quota("prior", start.addingTimeInterval(-6 * 60), limitID: "acct", name: "Account", used: 66, reset: oldReset),
            try quota("before-reset", start.addingTimeInterval(12 * 3_600 + 34 * 60), limitID: "acct", name: "Account", used: 100, reset: oldReset),
            try quota("after-reset", start.addingTimeInterval(12 * 3_600 + 38 * 60), limitID: "acct", name: "Account", used: 1, reset: newReset),
            try quota("drifted-reset", start.addingTimeInterval(12 * 3_600 + 39 * 60), limitID: "acct", name: "Account", used: 2, reset: driftedNewReset),
            try quota("stale", start.addingTimeInterval(12 * 3_600 + 40 * 60), limitID: "acct", name: "Account", used: 1, reset: driftedNewReset),
            try quota("recovered", start.addingTimeInterval(12 * 3_600 + 41 * 60), limitID: "acct", name: "Account", used: 2, reset: driftedNewReset),
            try quota("latest", start.addingTimeInterval(13 * 3_600), limitID: "acct", name: "Account", used: 8, reset: driftedNewReset)
        ])

        let result = try await store.fetchQuotaOverview(window: window)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.current?.id, "latest")
        XCTAssertEqual(source.daily.first?.usedPercentDelta, 42)
        XCTAssertTrue(source.daily.first?.cycleChanged == true)
    }

    func testQuotaProjectionDoesNotMarkResetTimeDriftAsACycleChange() async throws {
        let store = try store()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: base)
        let reset = start.addingTimeInterval(7 * 86_400)
        let window = CapabilityQueryWindow(
            start: start,
            end: start.addingTimeInterval(6 * 86_400 + 3_600),
            timeZone: calendar.timeZone
        )
        try await insert(store, [
            try quota("prior", start.addingTimeInterval(-3_600), limitID: "acct", name: "Account", used: 40, reset: reset),
            try quota("drifted", start.addingTimeInterval(3_600), limitID: "acct", name: "Account", used: 45, reset: reset.addingTimeInterval(60))
        ])

        let result = try await store.fetchQuotaOverview(window: window)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.daily.first?.usedPercentDelta, 5)
        XCTAssertFalse(source.daily.first?.cycleChanged == true)
    }
}
