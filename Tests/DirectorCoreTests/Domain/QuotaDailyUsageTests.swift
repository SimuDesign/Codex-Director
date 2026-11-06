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

    func testEarlyResetRequiresUsageDropAndCaptureIntervalEvidence() throws {
        let oldReset = date("2026-09-05 12:00")
        let earlyReset = date("2026-09-12 10:00")
        let observations = try [
            quota("prior", "2026-09-04 23:00", 40, reset: oldReset),
            quota("before-early-reset", "2026-09-05 08:00", 50, reset: oldReset),
            quota("early-reset", "2026-09-05 10:00", 2, reset: earlyReset),
            quota("later", "2026-09-05 11:00", 7, reset: earlyReset)
        ]

        let projection = QuotaDailyUsage.project(
            on: date("2026-09-05 12:00"),
            observations: observations,
            calendar: calendar
        )
        XCTAssertEqual(projection.usedPercent, 17)
        XCTAssertTrue(projection.cycleChanged)
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
            "2026-09-11 12:38",
            1,
            reset: date("2026-09-12 12:38")
        )
        let drifted = try quota(
            "drifted",
            "2026-09-11 12:39",
            2,
            reset: date("2026-09-12 12:39")
        )
        let nextCycle = try quota(
            "next-cycle",
            "2026-09-12 12:40",
            0,
            reset: date("2026-09-19 12:39")
        )

        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(from: observation, to: drifted))
        XCTAssertTrue(QuotaDailyUsage.reportedCycleChanged(from: drifted, to: nextCycle))
    }

    func testFutureResetTimeDriftBeyondFiveMinutesDoesNotInflateDailyUsage() throws {
        // Countdown-derived reset instants can move by more than the legacy
        // five-minute tolerance while still describing the same future
        // cycle. This is the production-shaped 20 -> 23 -> 23 -> 35 replay
        // from the quota audit: the day contains 15 observed points, not a
        // synthetic reset plus 23 additional points.
        let originalReset = date("2026-01-09 00:50")
        let driftedReset = date("2026-01-09 01:02")
        let observations = try [
            quota("prior", "2026-01-03 23:59", 20, reset: originalReset),
            quota("morning", "2026-01-04 08:00", 23, reset: originalReset),
            quota("drift", "2026-01-04 09:00", 23, reset: driftedReset),
            quota("night", "2026-01-04 22:00", 35, reset: driftedReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-01-04 12:00"), observations: observations, calendar: calendar
            ),
            15
        )
        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(
            from: observations[1], to: observations[2]
        ))
        XCTAssertEqual(QuotaDailyUsage.isSameReportedCycle(
            from: observations[1], to: observations[2]
        ), true)
    }

    func testRepeatedCrossDayFutureResetDriftKeepsOneAcceptedAnchor() throws {
        let originalReset = date("2026-01-09 00:50")
        let driftedReset = date("2026-01-09 01:02")
        let laterDriftedReset = date("2026-01-09 01:15")
        let observations = try [
            quota("prior", "2026-01-03 23:59", 20, reset: originalReset),
            quota("day-one", "2026-01-04 08:00", 23, reset: originalReset),
            quota("day-one-drift", "2026-01-04 22:00", 35, reset: driftedReset),
            quota("day-two-drift", "2026-01-05 08:00", 40, reset: laterDriftedReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-01-05 12:00"), observations: observations, calendar: calendar
            ),
            5
        )
        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(
            from: observations[2], to: observations[3]
        ))
    }

    func testNearbyCycleStartDriftAndTemporaryDropDoNotRetireActiveCycle() throws {
        let oldReset = date("2026-09-02 10:00")
        let activeReset = date("2026-09-09 10:00")
        let nearbyReport = date("2026-09-09 10:08")
        let observations = try [
            quota("old-full", "2026-09-02 09:59", 100, reset: oldReset),
            quota("new-zero", "2026-09-02 10:01", 0, reset: activeReset),
            quota("new-one", "2026-09-02 10:09", 1, reset: activeReset),
            quota("drifted-zero", "2026-09-02 10:10", 0, reset: nearbyReport),
            quota("reaffirmed-one", "2026-09-02 10:11", 1, reset: activeReset),
            // The increase above the pre-drop 1, not the equal replay,
            // confirms that this remains the active reported cycle.
            quota("reaffirmed-two", "2026-09-02 10:12", 2, reset: activeReset),
            quota("prior-day", "2026-09-03 23:50", 48, reset: activeReset),
            quota("first-day", "2026-09-04 23:50", 52, reset: activeReset),
            quota("second-day", "2026-09-05 23:50", 69, reset: activeReset)
        ]

        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(
            from: observations[2], to: observations[3]
        ))
        XCTAssertEqual(QuotaDailyUsage.project(
            on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
        ), .init(usedPercent: 4, cycleChanged: false))
        XCTAssertEqual(QuotaDailyUsage.project(
            on: date("2026-09-05 12:00"), observations: observations, calendar: calendar
        ), .init(usedPercent: 17, cycleChanged: false))
    }

    func testNearbyOnePointDropWithoutActiveCycleReaffirmationStaysUnknown() throws {
        let oldReset = date("2026-09-02 10:00")
        let activeReset = date("2026-09-09 10:00")
        let nearbyReport = date("2026-09-09 10:08")
        let observations = try [
            quota("old-full", "2026-09-01 23:50", 100, reset: oldReset),
            quota("new-zero", "2026-09-02 10:01", 0, reset: activeReset),
            quota("new-one", "2026-09-02 10:09", 1, reset: activeReset),
            quota("uncertain-zero", "2026-09-02 10:10", 0, reset: nearbyReport),
            quota("later", "2026-09-02 11:00", 3, reset: nearbyReport)
        ]

        XCTAssertNil(QuotaDailyUsage.project(
            on: date("2026-09-02 12:00"), observations: observations, calendar: calendar
        ).usedPercent)
        XCTAssertNil(QuotaDailyUsage.isSameReportedCycle(
            from: observations[2], to: observations[3]
        ))
    }

    func testEqualValueActiveAnchorReplayDoesNotResolveNearbyDrop() throws {
        let oldReset = date("2026-09-02 10:00")
        let activeReset = date("2026-09-09 10:00")
        let nearbyReport = date("2026-09-09 10:08")
        let observations = try [
            quota("old-full", "2026-09-01 23:50", 100, reset: oldReset),
            quota("new-zero", "2026-09-02 10:01", 0, reset: activeReset),
            quota("new-one", "2026-09-02 10:09", 1, reset: activeReset),
            quota("uncertain-zero", "2026-09-02 10:10", 0, reset: nearbyReport),
            quota("equal-old-value", "2026-09-02 10:11", 1, reset: activeReset),
            quota("later-candidate", "2026-09-02 11:00", 3, reset: nearbyReport)
        ]

        XCTAssertNil(QuotaDailyUsage.project(
            on: date("2026-09-02 12:00"), observations: observations, calendar: calendar
        ).usedPercent)
    }

    func testWellSeparatedSecondEarlyResetWithOnePointDropIsCounted() throws {
        let oldReset = date("2026-09-02 10:00")
        let firstReset = date("2026-09-09 10:00")
        let secondReset = date("2026-09-09 11:00")
        let observations = try [
            quota("prior", "2026-09-01 23:50", 100, reset: oldReset),
            quota("first-zero", "2026-09-02 10:01", 0, reset: firstReset),
            quota("first-one", "2026-09-02 11:02", 1, reset: firstReset),
            quota("second-zero", "2026-09-02 11:03", 0, reset: secondReset),
            quota("second-five", "2026-09-02 11:30", 5, reset: secondReset)
        ]

        XCTAssertEqual(QuotaDailyUsage.project(
            on: date("2026-09-02 12:00"), observations: observations, calendar: calendar
        ), .init(usedPercent: 6, cycleChanged: true))
    }

    func testSameCycleUsesObservedIncreaseForFortyEightToFiftyTwoToSixtyEight() throws {
        let reset = date("2026-09-07 17:38")
        let observations = try [
            quota("prior", "2026-09-03 23:54", 48, reset: reset),
            quota("morning", "2026-09-04 08:00", 52, reset: reset),
            quota("night", "2026-09-04 23:54", 68, reset: reset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-04 12:00"), observations: observations, calendar: calendar
            ),
            20
        )
    }

    func testUnprovenBackwardsFutureResetIsUnknownNotStaleReplay() throws {
        let acceptedAnchor = date("2026-09-10 12:00")
        let backwardsFutureReset = date("2026-09-09 12:00")
        let observations = try [
            quota("prior", "2026-09-07 23:00", 40, reset: acceptedAnchor),
            quota("backwards", "2026-09-08 10:00", 45, reset: backwardsFutureReset)
        ]

        XCTAssertNil(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-08 12:00"), observations: observations, calendar: calendar
            )
        )
        XCTAssertNil(QuotaDailyUsage.isSameReportedCycle(
            from: observations[0], to: observations[1]
        ))
    }

    func testTwoEvidenceBackedEarlyResetsCanExceedOneHundredPercent() throws {
        let oldReset = date("2026-09-12 12:00")
        let firstEarlyReset = date("2026-09-19 11:00")
        let secondEarlyReset = date("2026-09-19 12:00")
        let observations = try [
            quota("prior", "2026-09-11 23:00", 60, reset: oldReset),
            quota("first-reset", "2026-09-12 11:00", 0, reset: firstEarlyReset),
            quota("first-cycle-use", "2026-09-12 12:05", 60, reset: firstEarlyReset),
            quota("second-reset", "2026-09-12 12:10", 0, reset: secondEarlyReset),
            quota("second-cycle-use", "2026-09-12 12:20", 60, reset: secondEarlyReset)
        ]

        let projection = QuotaDailyUsage.project(
            on: date("2026-09-12 18:00"), observations: observations, calendar: calendar
        )
        XCTAssertEqual(projection.usedPercent, 120)
        XCTAssertTrue(projection.cycleChanged)
    }

    func testStalePreviousCycleReplayAfterResetIsIgnored() throws {
        let oldReset = date("2026-09-15 10:02")
        let newReset = date("2026-09-19 16:09")
        let observations = try [
            quota("prior", "2026-09-11 23:59", 51, reset: oldReset),
            quota("before-reset", "2026-09-12 16:09", 81, reset: oldReset),
            quota("after-reset", "2026-09-12 16:10", 0, reset: newReset),
            quota("stale-old-cycle-1", "2026-09-12 16:11", 81, reset: oldReset),
            quota("new-cycle-recovered-1", "2026-09-12 16:12", 0, reset: newReset),
            quota("stale-old-cycle-2", "2026-09-12 16:13", 81, reset: oldReset),
            quota("new-cycle-recovered-2", "2026-09-12 16:14", 0, reset: newReset),
            quota("latest", "2026-09-12 23:58", 32, reset: newReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-12 18:00"), observations: observations, calendar: calendar
            ),
            62
        )
        XCTAssertFalse(QuotaDailyUsage.reportedCycleChanged(
            from: observations[2],
            to: observations[3]
        ))
        XCTAssertNil(QuotaDailyUsage.isSameReportedCycle(
            from: observations[2],
            to: observations[3]
        ))
    }

    func testCrossDayStalePredecessorCannotBecomeDailyBaseline() throws {
        let oldReset = date("2026-09-07 12:00")
        let newReset = date("2026-09-14 13:00")
        let observations = try [
            quota("old-cycle", "2026-09-06 23:00", 80, reset: oldReset),
            quota("new-cycle-zero", "2026-09-07 13:00", 0, reset: newReset),
            // The first raw point on the target day is a replay of the cycle
            // that the sequence has already exited. It must not become either
            // the day's baseline or the day's first accepted observation.
            quota("stale-old-cycle", "2026-09-08 08:00", 80, reset: oldReset),
            quota("new-cycle-ten", "2026-09-08 10:00", 10, reset: newReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-08 12:00"), observations: observations, calendar: calendar
            ),
            10
        )
    }

    func testStalePredecessorOnPreviousDayCannotReplaceAcceptedBaseline() throws {
        let oldReset = date("2026-09-07 12:00")
        let newReset = date("2026-09-14 13:00")
        let observations = try [
            quota("old-cycle", "2026-09-06 23:00", 80, reset: oldReset),
            quota("new-cycle-zero", "2026-09-07 13:00", 0, reset: newReset),
            quota("stale-old-predecessor", "2026-09-07 20:00", 80, reset: oldReset),
            quota("new-cycle-ten", "2026-09-08 10:00", 10, reset: newReset)
        ]

        XCTAssertEqual(
            QuotaDailyUsage.observedUsedPercent(
                on: date("2026-09-08 12:00"), observations: observations, calendar: calendar
            ),
            10
        )
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
