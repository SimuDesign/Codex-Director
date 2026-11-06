import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class QuotaHistoryViewTests: XCTestCase {
    func testInitialSourceResolutionSeedsOnlyAnUninitializedSelection() {
        let first = QuotaOverviewModel.Source(id: "id:first", name: "First", snapshotCount: 1)
        let second = QuotaOverviewModel.Source(id: "id:second", name: "Second", snapshotCount: 1)

        XCTAssertEqual(
            QuotaHistoryViewModel.initialSourceID(rawSelection: nil, sources: [first, second]),
            "id:first"
        )
        XCTAssertEqual(
            QuotaHistoryViewModel.initialSourceID(rawSelection: "id:missing", sources: [first, second]),
            "id:missing"
        )
        XCTAssertNil(QuotaHistoryViewModel.initialSourceID(rawSelection: nil, sources: []))
    }

    func testChartReferenceValuesUseTwentyPointIncrementsAndIncludeLargeObservedDeltas() {
        XCTAssertEqual(QuotaHistoryViewModel.chartReferenceValues(for: [0, 5.5, 97]), [0, 20, 40, 60, 80, 100])
        XCTAssertEqual(QuotaHistoryViewModel.chartReferenceValues(for: [101, 138]), [0, 20, 40, 60, 80, 100, 120, 140])
    }

    func testTransitionSummariesUseSelectedPeriodAndDeduplicate() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = QuotaHistoryController(
            preferences: QuotaHistoryPreferences(memoryPeriod: .thirtyDays),
            now: { now },
            timeZone: { TimeZone(secondsFromGMT: 0)! },
            serviceReady: { true },
            dataGeneration: { 1 },
            fetch: { query, _ in
                let identity = PresentationIdentity(databaseEpoch: "synthetic", dataGeneration: 1)
                let days: [QuotaHistoryDay] = (0..<60).map { (index: Int) in
                    let offset = 59 - index
                    let recorded = [45, 20, 1].contains(offset)
                    let day = query.contextStart.addingTimeInterval(Double(index) * 86_400)
                    let transition = QuotaHistoryTransition(
                        id: "transition-\(offset)",
                        beforeObservedAt: day,
                        afterObservedAt: day.addingTimeInterval(60),
                        acceptedAnchor: day.addingTimeInterval(86_400)
                    )
                    return QuotaHistoryDay(
                        day: day, observationCount: recorded ? 2 : 0,
                        state: recorded ? .available : .noObservation, usedPercentDelta: recorded ? 8 : nil,
                        firstObservedAt: recorded ? day : nil,
                        lastObservedAt: recorded ? day.addingTimeInterval(60) : nil,
                        baseline: nil, firstObservation: nil, lastObservation: nil,
                        transitions: recorded ? (offset == 1 ? [transition, transition] : [transition]) : [],
                        comparisonKey: QuotaHistoryComparisonKey(
                            identity: identity, sourceKey: query.sourceKey,
                            timeZoneIdentifier: query.timeZone.identifier, day: day,
                            effectiveCutoff: day.addingTimeInterval(86_400), cutoff: .exclusive
                        )
                    )
                }
                return QuotaHistorySnapshot(
                    identity: identity, sourceKey: query.sourceKey,
                    timeZoneIdentifier: query.timeZone.identifier, asOf: query.asOf,
                    contextStart: query.contextStart, readAt: query.asOf,
                    lastObservedAt: days.last?.lastObservedAt, days: days,
                    transitions: days.flatMap(\.transitions)
                )
            }
        )
        let model = QuotaHistoryViewModel(controller: controller, homeQuotaModel: QuotaOverviewModel(snapshots: []))
        controller.open(sourceKey: "id:synthetic", sourceName: "Synthetic", homeSnapshot: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.phase == .loading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.phase, .loaded)
        XCTAssertEqual(model.transitionCount, 2)
        XCTAssertEqual(model.visibleTransitions.map(\.id), ["transition-20", "transition-1"])
        model.setPeriod(.sevenDays)
        XCTAssertEqual(model.transitionCount, 1)
        XCTAssertEqual(model.visibleTransitions.map(\.id), ["transition-1"])
        model.setPeriod(.sixtyDays)
        XCTAssertEqual(model.transitionCount, 3)
        XCTAssertEqual(model.visibleTransitions.map(\.id), ["transition-45", "transition-20", "transition-1"])
    }

    func testViewModelUsesRememberedPeriodAndSlicesTransitionsInMemory() async {
        let controller = makeController(period: .thirtyDays)
        let viewModel = QuotaHistoryViewModel(
            controller: controller,
            homeQuotaModel: QuotaOverviewModel(snapshots: [])
        )

        XCTAssertEqual(viewModel.period, .thirtyDays)
        viewModel.setPeriod(.sevenDays)
        XCTAssertEqual(viewModel.period, .sevenDays)

        let day = makeDay(transitionCount: 45)
        XCTAssertEqual(viewModel.transitions(for: day).count, 20)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day), 25)
        XCTAssertEqual(viewModel.transitions(for: day, page: 1).count, 20)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day, page: 1), 5)
        XCTAssertEqual(viewModel.transitions(for: day, page: 2).count, 5)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day, page: 2), 0)
        XCTAssertTrue(viewModel.transitions(for: day, page: 3).isEmpty)
    }

    func testTransitionPagerProvidesDistinctBoundedPages() {
        let controller = makeController()
        let viewModel = QuotaHistoryViewModel(
            controller: controller,
            homeQuotaModel: QuotaOverviewModel(snapshots: [])
        )
        let day = makeDay(transitionCount: 41)

        let firstPage = viewModel.transitions(for: day, page: 0)
        let secondPage = viewModel.transitions(for: day, page: 1)
        let finalPage = viewModel.transitions(for: day, page: 2)

        XCTAssertEqual(firstPage.count, 20)
        XCTAssertEqual(secondPage.count, 20)
        XCTAssertEqual(finalPage.count, 1)
        XCTAssertEqual(Set((firstPage + secondPage + finalPage).map(\.id)).count, 41)
        XCTAssertEqual(viewModel.transitions(for: day, page: -1).map(\.id), firstPage.map(\.id))
        XCTAssertTrue(viewModel.transitions(for: day, page: 3).isEmpty)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day, page: 0), 21)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day, page: 1), 1)
        XCTAssertEqual(viewModel.remainingTransitionCount(for: day, page: 2), 0)
    }

    func testPinnedSourceNeverFallsBackToAnotherHomeSource() {
        let controller = makeController()
        controller.open(sourceKey: "id:missing", sourceName: "Synthetic missing source", homeSnapshot: nil)
        let home = QuotaOverviewModel(snapshots: [snapshot(sourceID: "present", usedPercent: 24)])
        let viewModel = QuotaHistoryViewModel(controller: controller, homeQuotaModel: home)

        XCTAssertNil(viewModel.weeklyObservation)
        XCTAssertNil(viewModel.weeklyRemainingPercent)
        XCTAssertNil(viewModel.shortObservation)
    }

    func testRawPinnedSourceLabelDoesNotUseHomeFirstSourceFallback() {
        let controller = makeController()
        controller.open(sourceKey: "id:missing", sourceName: "Synthetic missing source", homeSnapshot: nil)
        let home = QuotaOverviewModel(snapshots: [snapshot(sourceID: "present", usedPercent: 24)])
        let viewModel = QuotaHistoryViewModel(controller: controller, homeQuotaModel: home)

        XCTAssertEqual(viewModel.sourceKey, "id:missing")
        XCTAssertEqual(viewModel.selectedSourceLabel, "Synthetic missing source")
        XCTAssertNotEqual(viewModel.selectedSourceLabel, home.selectedSource?.name)
    }

    func testCurrentProjectionUpdatesForAccountOnlyRefreshAndMarksSourceRemoval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = makeController()
        let initial = QuotaOverviewModel(
            snapshots: [
                snapshot(sourceID: "present", usedPercent: 30, windowMinutes: 10_080),
                snapshot(sourceID: "present", usedPercent: 50, windowMinutes: 300)
            ],
            now: now,
            selectedSourceID: "id:present"
        )
        controller.open(sourceKey: "id:present", sourceName: "Synthetic source", homeSnapshot: nil)
        let viewModel = QuotaHistoryViewModel(controller: controller, homeQuotaModel: initial)

        XCTAssertEqual(viewModel.weeklyRemainingPercent, 70)
        XCTAssertEqual(viewModel.shortRemainingPercent, 50)
        XCTAssertTrue(viewModel.isSourceAvailable)

        let refreshed = QuotaOverviewModel(
            snapshots: [
                snapshot(sourceID: "present", usedPercent: 65, windowMinutes: 10_080),
                snapshot(sourceID: "present", usedPercent: 80, windowMinutes: 300)
            ],
            now: now,
            selectedSourceID: "id:present"
        )
        viewModel.updateHomeQuotaModel(refreshed)

        XCTAssertEqual(viewModel.weeklyRemainingPercent, 35)
        XCTAssertEqual(viewModel.shortRemainingPercent, 20)
        XCTAssertTrue(viewModel.isSourceAvailable)

        viewModel.updateHomeQuotaModel(QuotaOverviewModel(snapshots: [], now: now))
        XCTAssertNil(viewModel.weeklyObservation)
        XCTAssertNil(viewModel.weeklyRemainingPercent)
        XCTAssertNil(viewModel.shortRemainingPercent)
        XCTAssertFalse(viewModel.isSourceAvailable)
    }

    func testUnknownReasonsRemainDistinctFromNoObservationAndAvailable() {
        let controller = makeController()
        let viewModel = QuotaHistoryViewModel(controller: controller, homeQuotaModel: QuotaOverviewModel(snapshots: []))

        XCTAssertEqual(viewModel.statusReason(for: .available), .available)
        XCTAssertEqual(viewModel.statusReason(for: .noObservation), .noObservation)
        XCTAssertEqual(viewModel.statusReason(for: .missingBaseline), .missingBaseline)
        XCTAssertEqual(viewModel.statusReason(for: .crossDayGap), .crossDayGap)
        XCTAssertEqual(viewModel.statusReason(for: .ambiguousCycle), .ambiguousCycle)
        XCTAssertEqual(viewModel.statusReason(for: .evidenceConflict), .evidenceConflict)
    }

    private func makeController(period: QuotaHistoryPeriod = .thirtyDays) -> QuotaHistoryController {
        QuotaHistoryController(
            preferences: QuotaHistoryPreferences(memoryPeriod: period),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            timeZone: { TimeZone(secondsFromGMT: 0)! },
            serviceReady: { false },
            dataGeneration: { 0 },
            fetch: { _, _ in throw QuotaHistoryControllerError.databaseNotReady }
        )
    }

    private func makeDay(transitionCount: Int) -> QuotaHistoryDay {
        let identity = PresentationIdentity(databaseEpoch: "synthetic", dataGeneration: 1)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let key = QuotaHistoryComparisonKey(
            identity: identity,
            sourceKey: "id:synthetic",
            timeZoneIdentifier: "GMT",
            day: day,
            effectiveCutoff: day,
            cutoff: .inclusive
        )
        let transitions = (0..<transitionCount).map { index in
            QuotaHistoryTransition(
                id: "transition-\(index)",
                beforeObservedAt: day.addingTimeInterval(Double(index) * 60),
                afterObservedAt: day.addingTimeInterval(Double(index + 1) * 60),
                acceptedAnchor: day.addingTimeInterval(86_400)
            )
        }
        return QuotaHistoryDay(
            day: day,
            observationCount: 2,
            state: .available,
            usedPercentDelta: 8,
            firstObservedAt: day,
            lastObservedAt: day.addingTimeInterval(60),
            baseline: nil,
            firstObservation: nil,
            lastObservation: nil,
            transitions: transitions,
            comparisonKey: key
        )
    }

    private func snapshot(sourceID: String, usedPercent: Double, windowMinutes: Int = 10_080) -> QuotaSnapshot {
        try! QuotaSnapshot(
            id: "snapshot-\(sourceID)",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: 1_700_086_400),
            limitID: sourceID,
            limitName: "Synthetic source",
            confidence: .exact
        )
    }
}
