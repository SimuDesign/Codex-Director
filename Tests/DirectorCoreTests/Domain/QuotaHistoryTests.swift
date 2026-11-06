import XCTest
@testable import DirectorCore

final class QuotaHistoryTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private let identity = PresentationIdentity(databaseEpoch: "synthetic", dataGeneration: 4)

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func snapshot(_ id: String, _ at: String, _ used: Double, reset: String? = nil, source: String = "selected") throws -> QuotaSnapshot {
        try QuotaSnapshot(id: id, capturedAt: date(at), windowMinutes: 10_080, usedPercent: used, resetsAt: reset.map(date), limitID: source, limitName: nil, confidence: .exact)
    }

    private func project(_ rows: [QuotaSnapshot], asOf: String = "2026-11-05 20:00") throws -> QuotaHistorySnapshot {
        try QuotaHistoryUsage.project(query: .init(sourceKey: "id:selected", asOf: date(asOf), timeZone: zone), identity: identity, observations: rows)
    }

    func testPeriodDefaultsAndSixtyCalendarDaysAcrossDST() throws {
        XCTAssertEqual(QuotaHistoryPeriod.preferenceValue(nil), .thirtyDays)
        XCTAssertEqual(QuotaHistoryPeriod.preferenceValue("invalid"), .thirtyDays)
        XCTAssertEqual(QuotaHistoryPeriod.preferenceValue("7d"), .sevenDays)
        let result = try project([])
        XCTAssertEqual(result.days.count, 60)
        XCTAssertEqual(result.days(for: .sevenDays).count, 7)
        XCTAssertEqual(result.days(for: .thirtyDays).count, 30)
        XCTAssertEqual(result.days(for: .sixtyDays).count, 60)
        XCTAssertEqual(result.days.last?.day, date("2026-11-05 00:00"))
        XCTAssertTrue(result.days.contains { $0.day == date("2026-11-01 00:00") })
        let first = try XCTUnwrap(result.days.first)
        XCTAssertEqual(first.state, .noObservation)
        XCTAssertEqual(first.comparisonKey.cutoff, .exclusive)
        XCTAssertEqual(result.days.last?.comparisonKey.cutoff, .inclusive)
        XCTAssertEqual(result.days.last?.comparisonKey.effectiveCutoff, date("2026-11-05 20:00"))
    }

    func testMissingBaselineGapAndConfirmedZeroAreDistinct() throws {
        let rows = try [
            snapshot("first", "2026-11-01 08:00", 30),
            snapshot("flat", "2026-11-01 09:00", 30),
            snapshot("gap", "2026-11-03 08:00", 40),
            snapshot("next", "2026-11-04 08:00", 40)
        ]
        let result = try project(rows)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-01 00:00") }?.state, .missingBaseline)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-02 00:00") }?.state, .noObservation)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-03 00:00") }?.state, .crossDayGap)
        let next = try XCTUnwrap(result.days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(next.state, .available)
        XCTAssertEqual(next.usedPercentDelta, 0)
        XCTAssertEqual(result.recordedDayCount(for: .sevenDays), 3)
        XCTAssertEqual(result.calculableDayCount(for: .sevenDays), 1)
    }

    func testEvidenceBackedResetRetainsBeforeAndAfterUsage() throws {
        let rows = try [
            snapshot("prior", "2026-11-03 23:00", 80, reset: "2026-11-04 09:00"),
            snapshot("before", "2026-11-04 08:00", 85, reset: "2026-11-04 09:00"),
            snapshot("after", "2026-11-04 10:00", 3, reset: "2026-11-11 09:00"),
            snapshot("later", "2026-11-04 20:00", 7, reset: "2026-11-11 09:00")
        ]
        let result = try project(rows)
        let day = try XCTUnwrap(result.days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(day.state, .available)
        XCTAssertEqual(day.usedPercentDelta, 12)
        XCTAssertEqual(day.transitions.count, 1)
        XCTAssertEqual(day.transitions.first?.beforeObservedAt, date("2026-11-04 08:00"))
        XCTAssertEqual(day.transitions.first?.afterObservedAt, date("2026-11-04 10:00"))
        XCTAssertEqual(result.days(for: .sevenDays).first { $0.day == day.day }, day)
    }

    func testInvalidEvidenceDoesNotBecomeZeroOrRecoverOrdinarily() throws {
        let rows = try [
            snapshot("prior", "2026-11-02 23:00", 40, reset: "2026-11-09 23:00"),
            snapshot("bad", "2026-11-03 08:00", 120, reset: "2026-11-09 23:00"),
            snapshot("ordinary", "2026-11-03 12:00", 45, reset: "2026-11-09 23:00"),
            snapshot("next", "2026-11-04 09:00", 48, reset: "2026-11-09 23:00")
        ]
        let result = try project(rows)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-03 00:00") }?.state, .ambiguousCycle)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-04 00:00") }?.state, .ambiguousCycle)
        XCTAssertNil(result.days.first { $0.day == date("2026-11-04 00:00") }?.usedPercentDelta)
    }

    func testConfirmedZeroRecoveryStartsAfterConfirmationWithoutInventingReset() throws {
        let rows = try [
            snapshot("prior", "2026-11-02 23:00", 40, reset: "2026-11-03 09:00"),
            snapshot("conflict", "2026-11-03 10:00", 45, reset: "2026-11-05 09:00"),
            snapshot("zero", "2026-11-03 11:00", 0, reset: "2026-11-11 11:00"),
            snapshot("confirmed", "2026-11-03 12:00", 5, reset: "2026-11-11 11:00"),
            snapshot("next", "2026-11-04 08:00", 8, reset: "2026-11-11 11:00")
        ]
        let result = try project(rows)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-03 00:00") }?.state, .ambiguousCycle)
        let next = try XCTUnwrap(result.days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(next.state, .available)
        XCTAssertEqual(next.usedPercentDelta, 3)
        XCTAssertTrue(result.transitions.isEmpty)
    }

    func testTwoProvenEarlyResetsMayExceedOneHundredPoints() throws {
        let rows = try [
            snapshot("prior", "2026-11-03 23:00", 60, reset: "2026-11-04 12:00"),
            snapshot("first-reset", "2026-11-04 11:00", 0, reset: "2026-11-11 11:00"),
            snapshot("first-use", "2026-11-04 12:05", 60, reset: "2026-11-11 11:00"),
            snapshot("second-reset", "2026-11-04 12:10", 0, reset: "2026-11-11 12:00"),
            snapshot("second-use", "2026-11-04 12:20", 60, reset: "2026-11-11 12:00")
        ]
        let day = try XCTUnwrap(project(rows).days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(day.state, .available)
        XCTAssertEqual(day.usedPercentDelta, 120)
        XCTAssertEqual(day.transitions.count, 2)
    }

    func testInvalidFirstEvidenceCannotBeFollowedByUnconfirmedZero() throws {
        let rows = try [
            snapshot("invalid", "2026-11-02 08:00", -1, reset: "2026-11-09 08:00"),
            snapshot("zero", "2026-11-02 09:00", 0, reset: "2026-11-09 09:00"),
            snapshot("ordinary", "2026-11-03 09:00", 5, reset: "2026-11-09 09:00")
        ]
        let result = try project(rows)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-02 00:00") }?.state, .ambiguousCycle)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-03 00:00") }?.state, .ambiguousCycle)
    }

    func testNextDayReaffirmationCannotResolvePriorDayNarrowLookahead() throws {
        let rows = try [
            snapshot("prior", "2026-11-03 23:00", 95, reset: "2026-11-04 23:45"),
            snapshot("old-full", "2026-11-04 23:44", 100, reset: "2026-11-04 23:45"),
            snapshot("new-zero", "2026-11-04 23:46", 0, reset: "2026-11-11 23:45"),
            snapshot("new-one", "2026-11-04 23:54", 1, reset: "2026-11-11 23:45"),
            snapshot("drifted-zero", "2026-11-04 23:55", 0, reset: "2026-11-11 23:53"),
            snapshot("next-day-reaffirmation", "2026-11-05 00:00", 2, reset: "2026-11-11 23:45")
        ]
        let result = try project(rows)
        let previousDay = try XCTUnwrap(result.days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(previousDay.state, .ambiguousCycle)
        XCTAssertNil(previousDay.usedPercentDelta)
    }

    func testUnrecoveredPriorDayLowValueCannotBecomeNextDayBaseline() throws {
        let rows = try [
            snapshot("prior", "2026-11-02 23:00", 60),
            snapshot("high", "2026-11-03 22:00", 70),
            snapshot("low-replay", "2026-11-03 23:00", 69),
            snapshot("next-day", "2026-11-04 08:00", 75),
            snapshot("later", "2026-11-05 08:00", 80)
        ]
        let result = try project(rows)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-03 00:00") }?.state, .ambiguousCycle)
        let next = try XCTUnwrap(result.days.first { $0.day == date("2026-11-04 00:00") })
        XCTAssertEqual(next.state, .ambiguousCycle)
        XCTAssertNil(next.usedPercentDelta)
        XCTAssertEqual(result.days.first { $0.day == date("2026-11-05 00:00") }?.usedPercentDelta, 5)
    }

    func testPublicProjectionLookaheadRejectsFutureAndOtherSourceEvidence() throws {
        let base = try [
            snapshot("prior", "2026-11-03 23:00", 100, reset: "2026-11-04 10:00"),
            snapshot("new-zero", "2026-11-04 10:01", 0, reset: "2026-11-11 10:00"),
            snapshot("new-one", "2026-11-04 10:09", 1, reset: "2026-11-11 10:00"),
            snapshot("drift", "2026-11-04 10:10", 0, reset: "2026-11-11 10:08")
        ]
        let future = try snapshot("future-reaffirm", "2026-11-04 10:11", 2, reset: "2026-11-11 10:00")
        let sameTimestampEqual = try snapshot("equal-replay", "2026-11-04 10:10", 1, reset: "2026-11-11 10:00")
        let futureResult = try project(base + [sameTimestampEqual, future], asOf: "2026-11-04 10:10")
        XCTAssertEqual(futureResult.days.last?.state, .ambiguousCycle)
        XCTAssertNil(futureResult.days.last?.usedPercentDelta)
        XCTAssertEqual(futureResult.days.last?.observationCount, 4)

        let other = try snapshot("other-reaffirm", "2026-11-04 10:11", 2, reset: "2026-11-11 10:00", source: "other")
        let laterEqual = try snapshot("selected-equal", "2026-11-04 10:12", 1, reset: "2026-11-11 10:00")
        let mixedResult = try project(base + [other, laterEqual], asOf: "2026-11-04 10:12")
        XCTAssertEqual(mixedResult.days.last?.state, .ambiguousCycle)
        XCTAssertNil(mixedResult.days.last?.usedPercentDelta)
        XCTAssertEqual(mixedResult.days.last?.observationCount, 4)
    }
}
