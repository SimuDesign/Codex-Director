import XCTest
@testable import DirectorCore

final class QuotaDailyUsageTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

    func testSameCycleReturnsObservedIncreaseAcrossTheDay() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("prior", "2026-09-03 23:54", 20, reset: reset),
            quota("morning", "2026-09-04 00:04", 23, reset: reset),
            quota("night", "2026-09-04 23:54", 35, reset: reset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            ),
            15
        )
    }

    func testConfirmedFlatDayReturnsZero() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("prior", "2026-09-03 23:54", 35, reset: reset),
            quota("morning", "2026-09-04 08:00", 35, reset: reset),
            quota("night", "2026-09-04 20:00", 35, reset: reset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            ),
            0
        )
    }

    func testResetDayRetainsUseBeforeAndAfterTheBoundary() throws {
        let oldReset = date("2026-09-04 09:00")
        let newReset = date("2026-09-11 09:00")
        let observations = try [
            quota("prior", "2026-09-03 23:00", 80, reset: oldReset),
            quota("before-reset", "2026-09-04 08:00", 85, reset: oldReset),
            quota("after-reset", "2026-09-04 10:00", 3, reset: newReset),
            quota("later", "2026-09-04 20:00", 7, reset: newReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            ),
            12
        )
    }

    func testRecoveredSameCycleRegressionsUseTheObservedHighWaterMark() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("prior", "2026-09-04 23:54", 66, reset: reset),
            quota("morning", "2026-09-05 08:00", 70, reset: reset),
            quota("stale-morning", "2026-09-05 08:01", 69, reset: reset),
            quota("recovered-morning", "2026-09-05 08:02", 70, reset: reset),
            quota("latest", "2026-09-05 12:34", 100, reset: reset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-05 12:00"), observations: observations, calendar: calendar
            ),
            34
        )
    }

    func testResetDayHandlesRecoveredStaleSnapshotsAndResetTimeDrift() throws {
        let oldReset = date("2026-09-07 17:38")
        let newReset = date("2026-09-12 12:38")
        let driftedNewReset = date("2026-09-12 12:39")
        let observations = try [
            quota("prior", "2026-09-04 23:54", 66, reset: oldReset),
            quota("before-reset", "2026-09-05 12:34", 100, reset: oldReset),
            quota("after-reset", "2026-09-05 12:38", 1, reset: newReset),
            quota("drifted-reset", "2026-09-05 12:39", 2, reset: driftedNewReset),
            quota("stale-new-cycle", "2026-09-05 12:40", 1, reset: driftedNewReset),
            quota("recovered-new-cycle", "2026-09-05 12:41", 2, reset: driftedNewReset),
            quota("latest", "2026-09-05 13:00", 8, reset: driftedNewReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-05 12:00"), observations: observations, calendar: calendar
            ),
            42
        )
    }

    func testReportedCycleChangeIgnoresResetTimeDriftButDetectsANewCycle() throws {
        let observation = try quota(
            "observation",
            "2026-09-05 12:38",
            1,
            reset: date("2026-09-12 12:38")
        )
        let drifted = try quota(
            "drifted",
            "2026-09-05 12:39",
            2,
            reset: date("2026-09-12 12:39")
        )
        let nextCycle = try quota(
            "next-cycle",
            "2026-09-05 12:40",
            0,
            reset: date("2026-09-19 12:39")
        )

        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(from: observation, to: drifted))
        XCTAssertTrue(QuotaDailyUsage.reportedCycleChanged(from: drifted, to: nextCycle))
    }

    func testDayWithoutObservationIsUnavailable() throws {
        let observations = try [quota("prior", "2026-09-03 23:00", 20)]

        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            )
        )
    }

    func testDayWithoutPredecessorIsUnavailableUnlessItStartsAtZero() throws {
        let unknownBaseline = try [
            quota("first", "2026-09-04 08:00", 30),
            quota("later", "2026-09-04 20:00", 35)
        ]
        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: unknownBaseline, calendar: calendar
            )
        )

        let knownZero = try [
            quota("zero", "2026-09-04 08:00", 0),
            quota("later", "2026-09-04 20:00", 5)
        ]
        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: knownZero, calendar: calendar
            ),
            5
        )
    }

    func testDistantPredecessorDoesNotAllocateUsageAcrossMissingDays() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("distant", "2026-09-02 23:00", 20, reset: reset),
            quota("today", "2026-09-04 12:00", 30, reset: reset)
        ]

        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            )
        )
    }

    func testUnexplainedDecreaseIsUnavailable() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("prior", "2026-09-03 23:00", 40, reset: reset),
            quota("decrease", "2026-09-04 12:00", 30, reset: reset)
        ]

        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            )
        )
    }

    func testMissingResetEvidenceCannotBridgeDifferentReportedStates() throws {
        let observations = try [
            quota("prior", "2026-09-03 23:00", 40, reset: date("2026-09-07 17:38")),
            quota("unknown", "2026-09-04 12:00", 45, reset: nil)
        ]

        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            )
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    private func quota(
        _ id: String,
        _ capturedAt: String,
        _ usedPercent: Double,
        reset: Date? = nil
    ) throws -> QuotaSnapshot {
        try QuotaSnapshot(
            id: id,
            capturedAt: date(capturedAt),
            windowMinutes: 10_080,
            usedPercent: usedPercent,
            resetsAt: reset,
            limitID: "codex",
            limitName: nil,
            confidence: .exact
        )
    }
}
