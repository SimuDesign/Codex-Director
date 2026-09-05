import XCTest
import Foundation
@testable import DirectorUI
import DirectorCore

final class QuotaOverviewTests: XCTestCase {
    private let tz = TimeZone(secondsFromGMT: 8 * 60 * 60)!

    func testUsesSevenLocalCalendarDaysAndLeavesMissingDaysUnfilled() throws {
        let now = date("2026-08-28 12:00")
        let snapshots = [
            try quota("a", "2026-08-22 09:00", 12),
            try quota("b", "2026-08-24 09:00", 31),
            try quota("c", "2026-08-28 10:00", 43)
        ]
        let model = QuotaOverviewModel(snapshots: snapshots, now: now, calendar: calendar)
        XCTAssertEqual(model.dailySnapshots.count, 7)
        XCTAssertEqual(model.dailySnapshots.compactMap(\.observation).count, 3)
        XCTAssertEqual(model.dailySnapshots[0].observation?.usedPercent, 12)
        XCTAssertNil(model.dailySnapshots[1].observation)
        XCTAssertEqual(model.dailySnapshots.last?.observation?.usedPercent, 43)
        XCTAssertTrue(model.dailySnapshots.allSatisfy { $0.usedPercent == nil })
    }

    func testDailyUsageShowsIncreaseInsteadOfCumulativeSnapshot() throws {
        let now = date("2026-08-28 12:00")
        let reset = "2026-09-04 08:00"
        let snapshots = [
            try quota("prior", "2026-08-27 23:00", 48, resetsAt: reset),
            try quota("start", "2026-08-28 00:05", 48, resetsAt: reset),
            try quota("latest", "2026-08-28 11:00", 66, resetsAt: reset)
        ]

        let model = QuotaOverviewModel(snapshots: snapshots, now: now, calendar: calendar)

        XCTAssertEqual(model.dailySnapshots.last?.observation?.usedPercent, 66)
        XCTAssertEqual(model.dailySnapshots.last?.usedPercent, 18)
    }

    func testFutureObservationsAreExcludedAndLatestObservationWins() throws {
        let now = date("2026-08-28 12:00")
        let past = try quota("past", "2026-08-28 09:00", 25)
        let future = try quota("future", "2026-08-28 13:00", 2)
        let model = QuotaOverviewModel(snapshots: [past, future], now: now, calendar: calendar)
        XCTAssertEqual(model.currentObservation?.id, past.id)
        XCTAssertEqual(model.remainingPercent, 75)
    }

    func testStaleCurrentObservationAwaitsNewDataWithoutClaimingFull() throws {
        let now = date("2026-08-28 12:00")
        let stale = try quota("stale", "2026-08-28 09:00", 72, resetsAt: "2026-08-28 11:00")
        let model = QuotaOverviewModel(snapshots: [stale], now: now, calendar: calendar)
        XCTAssertTrue(model.isCurrentObservationStale)
        XCTAssertTrue(model.isAwaitingNewData)
        XCTAssertNil(model.remainingPercent)
    }

    func testResetAtExactlyNowIsStale() throws {
        let now = date("2026-08-28 12:00")
        let boundary = try quota("boundary", "2026-08-28 09:00", 45, resetsAt: "2026-08-28 12:00")
        let model = QuotaOverviewModel(snapshots: [boundary], now: now, calendar: calendar)
        XCTAssertTrue(model.isCurrentObservationStale)
        XCTAssertNil(model.remainingPercent)
    }

    func testSourcesRemainIndependentAndSelectionIsRetainedOnRefresh() throws {
        let now = date("2026-08-28 12:00")
        let first = try quota("first", "2026-08-28 09:00", 20, limitID: "alpha", limitName: "Alpha account")
        let second = try quota("second", "2026-08-28 10:00", 80, limitID: "beta", limitName: "Beta account")
        let model = QuotaOverviewModel(snapshots: [first, second], now: now, calendar: calendar)
        let selected = model.selectingSource("id:beta")
        XCTAssertEqual(selected.selectedSource?.name, "Beta account")
        XCTAssertEqual(selected.currentObservation?.usedPercent, 80)
        let refreshed = selected.refreshed(with: [first, second, try quota("third", "2026-08-28 11:00", 83, limitID: "beta", limitName: "Beta account")])
        XCTAssertEqual(refreshed.selectedSourceID, "id:beta")
        XCTAssertEqual(refreshed.currentObservation?.usedPercent, 83)
    }

    func testResetBoundaryIsExplicitEvenWhenResetDayHasNoObservation() throws {
        let now = date("2026-08-28 12:00")
        let before = try quota("before", "2026-08-22 09:00", 40, resetsAt: "2026-08-25 08:00")
        let after = try quota("after", "2026-08-26 09:00", 4, resetsAt: "2026-09-02 08:00")
        let model = QuotaOverviewModel(snapshots: [before, after], now: now, calendar: calendar)
        let afterDay = model.dailySnapshots.first { $0.observation?.id == after.id }
        XCTAssertTrue(afterDay?.cycleChanged == true)
        XCTAssertNil(model.dailySnapshots.first { calendar.isDate($0.date, inSameDayAs: date("2026-08-25 12:00")) }?.observation)
    }

    func testSameDayMultipleObservationsRetainResetMarker() throws {
        let now = date("2026-08-28 12:00")
        let old = try quota("old", "2026-08-28 08:00", 66, resetsAt: "2026-08-28 09:00")
        let reset = try quota("reset", "2026-08-28 10:00", 3, resetsAt: "2026-09-04 09:00")
        let later = try quota("later", "2026-08-28 11:00", 7, resetsAt: "2026-09-04 09:00")
        let model = QuotaOverviewModel(snapshots: [old, reset, later], now: now, calendar: calendar)
        XCTAssertTrue(model.dailySnapshots.last?.cycleChanged == true)
        XCTAssertEqual(model.currentObservation?.id, later.id)
    }

    func testPreviousDayObservationAndTwoNewDayObservationsRetainResetMarker() throws {
        let now = date("2026-08-28 12:00")
        let previousDay = try quota("previous-day", "2026-08-27 23:00", 66, resetsAt: "2026-08-28 09:00")
        let newCycle = try quota("new-cycle", "2026-08-28 10:00", 3, resetsAt: "2026-09-04 09:00")
        let latest = try quota("latest", "2026-08-28 11:00", 7, resetsAt: "2026-09-04 09:00")
        let model = QuotaOverviewModel(snapshots: [previousDay, newCycle, latest], now: now, calendar: calendar)
        XCTAssertTrue(model.dailySnapshots.last?.cycleChanged == true)
        XCTAssertEqual(model.currentObservation?.id, latest.id)
        XCTAssertEqual(model.dailySnapshots.last?.usedPercent, 7)
    }

    func testCompactProjectionUsesPersistedDailyUsage() throws {
        let now = date("2026-08-28 12:00")
        let priorDay = date("2026-08-27 00:00")
        let currentDay = date("2026-08-28 00:00")
        let current = try quota("current", "2026-08-28 11:00", 66)
        let identity = PresentationIdentity(databaseEpoch: "epoch", dataGeneration: 1)
        let window = CapabilityQueryWindow(start: priorDay, end: now, timeZone: tz)
        let overview = QuotaOverviewSnapshot(
            identity: identity,
            window: window,
            coverage: .complete,
            sources: [
                QuotaOverviewSourceSnapshot(
                    id: "id:weekly",
                    name: "Weekly",
                    current: current,
                    daily: [
                        QuotaOverviewDay(day: priorDay, observation: nil),
                        QuotaOverviewDay(
                            day: currentDay,
                            observation: current,
                            usedPercentDelta: 18
                        )
                    ]
                )
            ]
        )

        let model = QuotaOverviewModel(snapshot: overview, now: now, calendar: calendar)

        XCTAssertNil(model.dailySnapshots.first?.usedPercent)
        XCTAssertEqual(model.dailySnapshots.last?.usedPercent, 18)
    }

    func testLegacyCompactProjectionDerivesOnlyUnambiguousAdjacentDayIncrease() throws {
        let now = date("2026-08-28 12:00")
        let priorDay = date("2026-08-27 00:00")
        let currentDay = date("2026-08-28 00:00")
        let prior = try quota("prior", "2026-08-27 23:00", 48)
        let current = try quota("current", "2026-08-28 11:00", 66)
        let identity = PresentationIdentity(databaseEpoch: "epoch", dataGeneration: 1)
        let overview = QuotaOverviewSnapshot(
            identity: identity,
            window: CapabilityQueryWindow(start: priorDay, end: now, timeZone: tz),
            coverage: .complete,
            sources: [
                QuotaOverviewSourceSnapshot(
                    id: "id:weekly",
                    name: "Weekly",
                    current: current,
                    daily: [
                        QuotaOverviewDay(day: priorDay, observation: prior),
                        QuotaOverviewDay(day: currentDay, observation: current)
                    ]
                )
            ]
        )

        let model = QuotaOverviewModel(snapshot: overview, now: now, calendar: calendar)

        XCTAssertNil(model.dailySnapshots.first?.usedPercent)
        XCTAssertEqual(model.dailySnapshots.last?.usedPercent, 18)
    }

    func testUnknownResetRemainsUnknownAndUnknownSourceIsSeparate() throws {
        let now = date("2026-08-28 12:00")
        let unknown = try quota("unknown", "2026-08-28 09:00", 20, resetsAt: nil, limitID: nil, limitName: nil)
        let named = try quota("named", "2026-08-28 10:00", 30, resetsAt: nil, limitID: "named", limitName: "Named")
        let model = QuotaOverviewModel(snapshots: [unknown, named], now: now, calendar: calendar)
        XCTAssertEqual(model.sources.map(\.name), ["Named", "Unknown source"])
        XCTAssertNil(model.sources.first { $0.name == "Unknown source" }.flatMap { _ in model.currentObservation?.resetsAt })
    }

    func testQuotaRingMapsRemainingPercentIntoProgressSegments() throws {
        let zero = QuotaRingPresentation.make(remainingPercent: 0)
        XCTAssertEqual(try XCTUnwrap(zero.remainingFraction), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(zero.consumedFraction), 1, accuracy: 0.0001)
        XCTAssertEqual(zero.centerText, "0%")
        XCTAssertFalse(zero.isAwaitingNewRecord)

        let partial = QuotaRingPresentation.make(remainingPercent: 38)
        XCTAssertEqual(try XCTUnwrap(partial.remainingFraction), 0.38, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(partial.consumedFraction), 0.62, accuracy: 0.0001)
        XCTAssertEqual(partial.centerText, "38%")

        let full = QuotaRingPresentation.make(remainingPercent: 100)
        XCTAssertEqual(try XCTUnwrap(full.remainingFraction), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(full.consumedFraction), 0, accuracy: 0.0001)
        XCTAssertEqual(full.centerText, "100%")
    }

    func testQuotaRingUnknownStateNeverInventsAFullAllowance() {
        for value in [Double.nan, .infinity, -.infinity] {
            let ring = QuotaRingPresentation.make(remainingPercent: value)
            XCTAssertNil(ring.remainingFraction)
            XCTAssertNil(ring.consumedFraction)
            XCTAssertEqual(ring.centerText, "—")
            XCTAssertTrue(ring.isAwaitingNewRecord)
        }

        let clamped = QuotaRingPresentation.make(remainingPercent: 162)
        XCTAssertEqual(try XCTUnwrap(clamped.remainingFraction), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(clamped.consumedFraction), 0, accuracy: 0.0001)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = tz
        value.locale = Locale(identifier: "zh_CN")
        return value
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    private func quota(
        _ id: String, _ capturedAt: String, _ used: Double,
        resetsAt: String? = "2026-09-04 08:00", limitID: String? = "weekly", limitName: String? = "Weekly"
    ) throws -> QuotaSnapshot {
        try QuotaSnapshot(
            id: id, capturedAt: date(capturedAt), windowMinutes: 10_080,
            usedPercent: used, resetsAt: resetsAt.map(date), limitID: limitID,
            limitName: limitName, confidence: .exact
        )
    }
}
