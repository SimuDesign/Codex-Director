import Foundation
import XCTest
@testable import DirectorCore
@testable import DirectorUI

@MainActor
final class QuotaHistoryControllerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_201_200)
    private let zone = TimeZone(secondsFromGMT: 8 * 3_600)!

    @MainActor private final class Gate {
        var requests: [QuotaHistoryQuery] = []
        var tokens: [SQLiteCancellationToken] = []
        private var continuations: [CheckedContinuation<QuotaHistorySnapshot, Error>] = []

        func read(_ query: QuotaHistoryQuery, token: SQLiteCancellationToken) async throws -> QuotaHistorySnapshot {
            requests.append(query)
            tokens.append(token)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }

        func succeed(_ index: Int, snapshot: QuotaHistorySnapshot) {
            continuations[index].resume(returning: snapshot)
        }

        func fail(_ index: Int) {
            continuations[index].resume(throwing: QuotaHistoryControllerError.databaseNotReady)
        }
    }

    @MainActor private final class Generation {
        var value: UInt64 = 0
    }

    @MainActor private final class Clock {
        var now: Date
        var zone: TimeZone
        init(now: Date, zone: TimeZone) {
            self.now = now
            self.zone = zone
        }
    }

    private func makeController(
        gate: Gate,
        generation: Generation = Generation(),
        preferences: QuotaHistoryPreferences = QuotaHistoryPreferences(memoryPeriod: .thirtyDays)
    ) -> QuotaHistoryController {
        QuotaHistoryController(
            preferences: preferences,
            now: { self.now },
            timeZone: { self.zone },
            serviceReady: { true },
            dataGeneration: { generation.value },
            fetch: { query, token in try await gate.read(query, token: token) }
        )
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func snapshot(_ query: QuotaHistoryQuery, used: Double = 12, identity: PresentationIdentity = .init(databaseEpoch: "synthetic", dataGeneration: 1)) -> QuotaHistorySnapshot {
        let days = (0..<60).map { offset -> QuotaHistoryDay in
            let day = query.calendar.date(byAdding: .day, value: offset, to: query.contextStart)!
            return QuotaHistoryDay(
                day: day,
                observationCount: offset == 59 ? 2 : 0,
                state: offset == 59 ? .available : .noObservation,
                usedPercentDelta: offset == 59 ? used : nil,
                firstObservedAt: nil,
                lastObservedAt: nil,
                baseline: nil,
                firstObservation: nil,
                lastObservation: nil,
                transitions: [],
                comparisonKey: .home(identity: identity, sourceKey: query.sourceKey, day: day, timeZone: query.timeZone, asOf: query.asOf)
            )
        }
        return QuotaHistorySnapshot(identity: identity, sourceKey: query.sourceKey, timeZoneIdentifier: query.timeZone.identifier, asOf: query.asOf, contextStart: query.contextStart, readAt: query.asOf, lastObservedAt: query.asOf, days: days, transitions: [])
    }

    func testPeriodAndDayChangesSliceOneReadAndShareOnlyPreference() async {
        let gate = Gate()
        let preferences = QuotaHistoryPreferences(memoryPeriod: .thirtyDays)
        let first = makeController(gate: gate, preferences: preferences)
        let second = makeController(gate: gate, preferences: preferences)
        first.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0]))
        await waitUntil { first.phase == .loaded }
        XCTAssertEqual(first.days.count, 30)
        first.setPeriod(.sevenDays)
        XCTAssertEqual(first.days.count, 7)
        XCTAssertEqual(second.period, .sevenDays)
        let today = first.days.last!.day
        first.selectDay(today)
        XCTAssertEqual(first.expandedDay?.day, today)
        first.setPeriod(.sixtyDays)
        XCTAssertEqual(first.days.count, 60)
        first.retry()
        await waitUntil { gate.requests.count == 2 }
        XCTAssertEqual(first.phase, .updating)
        XCTAssertEqual(gate.requests.count, 2)
        gate.fail(1)
        await waitUntil { first.phase == .failed }
        XCTAssertEqual(first.snapshot?.days.count, 60)
    }

    func testIndexRefreshRejectsLateReadAndDeletionRevokesResult() async {
        let gate = Gate()
        let generation = Generation()
        let controller = makeController(gate: gate, generation: generation)
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        generation.value += 1
        controller.indexedDataDidCommit()
        await waitUntil { gate.requests.count == 2 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0], used: 99))
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        gate.succeed(1, snapshot: snapshot(gate.requests[1], used: 13))
        await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.days.last?.usedPercentDelta, 13)
        controller.retry()
        await waitUntil { gate.requests.count == 3 }
        generation.value += 1
        controller.derivedDataWillDelete()
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.phase, .unavailable)
        XCTAssertTrue(gate.tokens[2].shouldInterrupt)
        gate.succeed(2, snapshot: snapshot(gate.requests[2], used: 77))
        await Task.yield()
        XCTAssertNil(controller.snapshot)
    }

    func testMatchedHomeConflictDowngradesOnlyDisputedDay() async {
        let gate = Gate()
        let controller = makeController(gate: gate)
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        let query = gate.requests[0]
        let history = snapshot(query, used: 12)
        let today = history.days.last!.day
        let overview = QuotaOverviewSnapshot(
            identity: history.identity,
            window: CapabilityQueryWindow(start: today, end: query.asOf, timeZone: zone),
            coverage: .complete,
            sources: [QuotaOverviewSourceSnapshot(id: "id:synthetic", name: "Synthetic", current: nil, daily: [QuotaOverviewDay(day: today, observation: nil, usedPercentDelta: 15)])]
        )
        gate.succeed(0, snapshot: history)
        await waitUntil { controller.phase == .loaded }
        let otherIdentity = QuotaOverviewSnapshot(
            identity: .init(databaseEpoch: "synthetic", dataGeneration: 2),
            window: overview.window,
            coverage: .complete,
            sources: overview.sources
        )
        controller.updateHomeSnapshot(otherIdentity)
        XCTAssertEqual(controller.days.last?.state, .available)
        let otherCutoff = QuotaOverviewSnapshot(
            identity: history.identity,
            window: CapabilityQueryWindow(start: today, end: query.asOf.addingTimeInterval(-3_600), timeZone: zone),
            coverage: .complete,
            sources: overview.sources
        )
        controller.updateHomeSnapshot(otherCutoff)
        XCTAssertEqual(controller.days.last?.state, .available)
        controller.updateHomeSnapshot(overview)
        XCTAssertEqual(controller.days.last?.state, .evidenceConflict)
        XCTAssertNil(controller.days.last?.usedPercentDelta)
        XCTAssertEqual(controller.calculableDayCount, 0)
        controller.updateHomeSnapshot(nil)
        XCTAssertEqual(controller.days.last?.state, .available)
        XCTAssertEqual(controller.calculableDayCount, 1)
        XCTAssertEqual(gate.requests.count, 1)
    }

    func testDuplicateHomeDayFailsClosedWithoutTrappingOrChangingOtherDays() async {
        let gate = Gate()
        let controller = makeController(gate: gate)
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        let query = gate.requests[0]
        let base = snapshot(query, used: 12)
        var days = base.days
        let prior = days[58]
        days[58] = QuotaHistoryDay(
            day: prior.day,
            observationCount: 2,
            state: .available,
            usedPercentDelta: 4,
            firstObservedAt: nil,
            lastObservedAt: nil,
            baseline: nil,
            firstObservation: nil,
            lastObservation: nil,
            transitions: [],
            comparisonKey: prior.comparisonKey
        )
        let history = QuotaHistorySnapshot(
            identity: base.identity,
            sourceKey: base.sourceKey,
            timeZoneIdentifier: base.timeZoneIdentifier,
            asOf: base.asOf,
            contextStart: base.contextStart,
            readAt: base.readAt,
            lastObservedAt: base.lastObservedAt,
            days: days,
            transitions: []
        )
        gate.succeed(0, snapshot: history)
        await waitUntil { controller.phase == .loaded }
        let today = days[59].day
        let overview = QuotaOverviewSnapshot(
            identity: history.identity,
            window: CapabilityQueryWindow(start: prior.day, end: query.asOf, timeZone: zone),
            coverage: .complete,
            sources: [QuotaOverviewSourceSnapshot(
                id: "id:synthetic",
                name: "Synthetic",
                current: nil,
                daily: [
                    QuotaOverviewDay(day: prior.day, observation: nil, usedPercentDelta: 4),
                    QuotaOverviewDay(day: today, observation: nil, usedPercentDelta: 12),
                    QuotaOverviewDay(day: today, observation: nil, usedPercentDelta: 12)
                ]
            )]
        )
        controller.updateHomeSnapshot(overview)
        XCTAssertEqual(controller.days.suffix(2).map(\.state), [.available, .evidenceConflict])
        XCTAssertNil(controller.days.last?.usedPercentDelta)
        XCTAssertEqual(controller.calculableDayCount, 1)
        XCTAssertEqual(gate.requests.count, 1)
        controller.updateHomeSnapshot(QuotaOverviewSnapshot(
            identity: .init(databaseEpoch: "another", dataGeneration: 1),
            window: overview.window,
            coverage: .complete,
            sources: overview.sources
        ))
        XCTAssertEqual(controller.days.suffix(2).map(\.state), [.available, .available])
    }

    func testCloseAndSourceReopenCannotPublishPriorSource() async {
        let gate = Gate()
        let controller = makeController(gate: gate)
        controller.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        controller.close()
        XCTAssertEqual(controller.phase, .idle)
        controller.open(sourceKey: "id:second", sourceName: "Second", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 2 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0], used: 90))
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        gate.succeed(1, snapshot: snapshot(gate.requests[1], used: 4))
        await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.sourceKey, "id:second")
        XCTAssertEqual(controller.days.last?.usedPercentDelta, 4)
    }

    func testLateCloseFromPreviousSheetCannotClearReopenedSession() async {
        let gate = Gate()
        let controller = makeController(gate: gate)
        let firstSession = controller.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)!
        await waitUntil { gate.requests.count == 1 }
        controller.close(sessionID: firstSession)
        let secondSession = controller.open(sourceKey: "id:second", sourceName: "Second", homeSnapshot: nil)!
        await waitUntil { gate.requests.count == 2 }

        // A native sheet may deliver the old view's disappearance after the
        // new presentation has already opened on this window's controller.
        controller.close(sessionID: firstSession)
        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertEqual(controller.sessionID, secondSession)
        XCTAssertEqual(controller.sourceKey, "id:second")
        XCTAssertEqual(controller.sourceName, "Second")
        XCTAssertEqual(controller.phase, .loading)
        XCTAssertFalse(gate.tokens[1].shouldInterrupt)

        gate.succeed(0, snapshot: snapshot(gate.requests[0], used: 90))
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        gate.succeed(1, snapshot: snapshot(gate.requests[1], used: 4))
        await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.snapshot?.sourceKey, "id:second")
        XCTAssertEqual(controller.days.last?.usedPercentDelta, 4)

        controller.close(sessionID: firstSession)
        XCTAssertEqual(controller.snapshot?.sourceKey, "id:second")
        controller.close(sessionID: secondSession)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.sessionID)
    }

    func testClockRechecksOnlyAfterNaturalDayOrTimeZoneChange() async {
        let gate = Gate()
        let clock = Clock(now: now, zone: zone)
        let controller = QuotaHistoryController(
            preferences: QuotaHistoryPreferences(memoryPeriod: .thirtyDays),
            now: { clock.now },
            timeZone: { clock.zone },
            serviceReady: { true },
            dataGeneration: { 0 },
            fetch: { query, token in try await gate.read(query, token: token) }
        )
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0]))
        await waitUntil { controller.phase == .loaded }
        clock.now += 3_600
        controller.checkClockAndRefresh()
        XCTAssertEqual(gate.requests.count, 1)
        clock.now = zoneDayAfter(clock.now)
        controller.checkClockAndRefresh()
        await waitUntil { gate.requests.count == 2 }
        XCTAssertNil(controller.snapshot)
        XCTAssertNotEqual(gate.requests[0].contextStart, gate.requests[1].contextStart)
        gate.succeed(1, snapshot: snapshot(gate.requests[1]))
        await waitUntil { controller.phase == .loaded }
        clock.zone = TimeZone(secondsFromGMT: 0)!
        controller.checkClockAndRefresh()
        await waitUntil { gate.requests.count == 3 }
        XCTAssertEqual(gate.requests[2].timeZone, clock.zone)
        gate.succeed(2, snapshot: snapshot(gate.requests[2]))
        await waitUntil { controller.phase == .loaded }
    }

    private func zoneDayAfter(_ value: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(byAdding: .day, value: 1, to: value)!
    }

    func testExpiredReadFailsWithoutPublishingAndCanRetry() async {
        let gate = Gate()
        let controller = QuotaHistoryController(
            preferences: QuotaHistoryPreferences(memoryPeriod: .thirtyDays),
            now: { self.now },
            timeZone: { self.zone },
            serviceReady: { true },
            dataGeneration: { 0 },
            cancellationTimeout: .zero,
            fetch: { query, token in try await gate.read(query, token: token) }
        )
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0]))
        await waitUntil { controller.phase == .failed }
        XCTAssertNil(controller.snapshot)
        controller.retry()
        await waitUntil { gate.requests.count == 2 }
        XCTAssertEqual(controller.phase, .loading)
        gate.succeed(1, snapshot: snapshot(gate.requests[1]))
        await waitUntil { controller.phase == .failed }
        XCTAssertNil(controller.snapshot)
    }

    func testTwoWindowSessionsKeepSourcesAndDaysIndependent() async {
        let firstGate = Gate()
        let secondGate = Gate()
        let preferences = QuotaHistoryPreferences(memoryPeriod: .thirtyDays)
        let first = makeController(gate: firstGate, preferences: preferences)
        let second = makeController(gate: secondGate, preferences: preferences)
        first.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)
        second.open(sourceKey: "id:second", sourceName: "Second", homeSnapshot: nil)
        await waitUntil { firstGate.requests.count == 1 && secondGate.requests.count == 1 }
        firstGate.succeed(0, snapshot: snapshot(firstGate.requests[0], used: 8))
        secondGate.succeed(0, snapshot: snapshot(secondGate.requests[0], used: 16))
        await waitUntil { first.phase == .loaded && second.phase == .loaded }
        first.selectDay(first.days.last!.day)
        XCTAssertNil(second.expandedDay)
        first.setPeriod(.sevenDays)
        XCTAssertEqual(second.period, .sevenDays)
        first.close()
        XCTAssertEqual(second.sourceKey, "id:second")
        XCTAssertEqual(second.days.last?.usedPercentDelta, 16)
        XCTAssertEqual(firstGate.requests.count, 1)
        XCTAssertEqual(secondGate.requests.count, 1)
    }

    func testExpandedDaySurvivesRangeHideAndSameWindowSourceReopen() async {
        let gate = Gate()
        var preferenceWrites: [String] = []
        let preferences = QuotaHistoryPreferences(
            readPeriod: { "30d" },
            writePeriod: { preferenceWrites.append($0) }
        )
        let controller = makeController(gate: gate, preferences: preferences)
        controller.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 1 }
        gate.succeed(0, snapshot: snapshot(gate.requests[0]))
        await waitUntil { controller.phase == .loaded }
        let oldDay = controller.days.first!.day
        controller.selectDay(oldDay)
        XCTAssertEqual(controller.expandedDay?.day, oldDay)
        controller.setPeriod(.sevenDays)
        XCTAssertNil(controller.expandedDay)
        XCTAssertEqual(controller.selectedDay, oldDay)
        controller.setPeriod(.thirtyDays)
        XCTAssertEqual(controller.expandedDay?.day, oldDay)
        controller.close()
        controller.open(sourceKey: "id:second", sourceName: "Second", homeSnapshot: nil)
        XCTAssertNil(controller.selectedDay)
        await waitUntil { gate.requests.count == 2 }
        gate.succeed(1, snapshot: snapshot(gate.requests[1]))
        await waitUntil { controller.phase == .loaded }
        controller.close()
        controller.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)
        XCTAssertEqual(controller.selectedDay, oldDay)
        await waitUntil { gate.requests.count == 3 }
        gate.succeed(2, snapshot: snapshot(gate.requests[2]))
        await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.expandedDay?.day, oldDay)
        XCTAssertEqual(preferenceWrites, ["7d", "30d"])
    }

    func testNoSourceActivationIsNavigableWithoutInventingARead() async {
        let gate = Gate()
        let controller = makeController(gate: gate)

        let session = controller.open(sourceKey: nil, sourceName: nil, homeSnapshot: nil)

        XCTAssertNotNil(session)
        XCTAssertEqual(controller.sessionID, session)
        XCTAssertNil(controller.sourceKey)
        XCTAssertEqual(controller.phase, .unavailable)
        XCTAssertTrue(gate.requests.isEmpty)
    }

    func testExplicitSourceSwitchKeepsSessionAndReplacesBoundedRead() async {
        let gate = Gate()
        let controller = makeController(gate: gate)
        let session = controller.open(sourceKey: "id:first", sourceName: "First", homeSnapshot: nil)!
        await waitUntil { gate.requests.count == 1 }

        controller.setSource(sourceKey: "id:second", sourceName: "Second", homeSnapshot: nil)
        await waitUntil { gate.requests.count == 2 }
        XCTAssertEqual(controller.sessionID, session)
        XCTAssertEqual(controller.sourceKey, "id:second")
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(gate.tokens[0].shouldInterrupt)

        gate.succeed(0, snapshot: snapshot(gate.requests[0], used: 90))
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        gate.succeed(1, snapshot: snapshot(gate.requests[1], used: 4))
        await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.snapshot?.sourceKey, "id:second")
        XCTAssertEqual(controller.days.last?.usedPercentDelta, 4)
    }
}
