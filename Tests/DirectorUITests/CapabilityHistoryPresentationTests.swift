import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class CapabilityHistoryPresentationTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        func read() -> Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ value: Date) {
            lock.lock(); defer { lock.unlock() }
            self.value = value
        }
    }

    private actor UsageProbe {
        private(set) var queries: [CapabilityChangeUsageQuery] = []
        func record(_ query: CapabilityChangeUsageQuery) { queries.append(query) }
    }

    private actor PageProbe {
        private(set) var queries: [CapabilityHistoryQuery] = []
        func record(_ query: CapabilityHistoryQuery) { queries.append(query) }
    }

    private actor SummaryAttempts {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor PageReadAttempts {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private final class HistoryWriteFailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func shouldFail() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func failWrites() {
            lock.lock(); value = true; lock.unlock()
        }
    }

    func testEmptyCompletedScopeIsNotPresentedAsPendingBaseline() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 11)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        let scope = CapabilityHistoryScanScope(
            rootID: "test-empty-scope",
            scope: .global,
            rootKind: .agents,
            coverage: .complete
        )
        try await coordinator.submit(CapabilityHistoryScanBatch(
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: [scope],
            observations: []
        ))

        let source = makeSource(coordinator: coordinator)
        let now = referenceDate
        let model = CapabilityHistoryPresentationModel(source: source, nowProvider: { now })
        await model.loadNow()

        XCTAssertEqual(model.status?.isInitialized, true)
        XCTAssertEqual(model.status?.initializedScopeCount, 1)
        XCTAssertFalse(model.isBaselinePending)
        XCTAssertEqual(model.loadState, .empty)
    }

    func testPendingAbsenceAndPartialCoverageExposeExplicitStatus() async throws {
        let page = CapabilityHistoryPage(
            events: [],
            nextBeforeSequence: nil,
            revision: 4,
            epoch: 12,
            truncatedBefore: nil,
            issueCodes: []
        )
        let pendingStatus = CapabilityHistoryStatus(
            accessMode: .readWrite,
            epoch: 12,
            revision: 4,
            eventCount: 0,
            baselineCount: 1,
            isInitialized: true,
            initializedScopeCount: 1,
            latestScanCoverage: .complete,
            pendingMissingCount: 1
        )
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { _ in page },
            statusLoader: { pendingStatus },
            clearLoader: { pendingStatus },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) }
        )
        let model = CapabilityHistoryPresentationModel(source: source)
        await model.loadNow()
        XCTAssertEqual(model.statusIssueKey, "history.state.awaitingConfirmation")

        let partialSource = CapabilityHistoryPresentationSource(
            pageLoader: { _ in page },
            statusLoader: {
                CapabilityHistoryStatus(
                    accessMode: .readWrite,
                    epoch: 12,
                    revision: 4,
                    eventCount: 0,
                    baselineCount: 1,
                    isInitialized: true,
                    initializedScopeCount: 1,
                    latestScanCoverage: .partial
                )
            },
            clearLoader: { pendingStatus },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) }
        )
        let partialModel = CapabilityHistoryPresentationModel(source: partialSource)
        await partialModel.loadNow()
        XCTAssertEqual(partialModel.statusIssueKey, "history.state.partial")
    }

    func testInitializedEmptyMixedCoverageKeepsEmptyStateAndShowsPartialNotice() async throws {
        let source = makeEmptySource(coverage: .partial)
        let model = CapabilityHistoryPresentationModel(source: source)

        await model.loadNow()

        XCTAssertEqual(model.presentationStatus, .partialCoverage)
        XCTAssertEqual(model.statusIssueKey, "history.state.partial")
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.shouldOfferReadRetry)
        XCTAssertTrue(model.shouldShowEmptyState)
        XCTAssertFalse(model.isBaselinePending)
    }

    func testLegacyUnavailableCoverageUsesSourceScanNoticeWithoutRetry() async throws {
        let source = makeEmptySource(coverage: .unavailable)
        let model = CapabilityHistoryPresentationModel(source: source)

        await model.loadNow()

        XCTAssertEqual(model.presentationStatus, .sourceScanIncomplete)
        XCTAssertEqual(model.statusIssueKey, "history.state.sourceScanIncomplete")
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.isUnavailable)
        XCTAssertFalse(model.shouldOfferReadRetry)
        XCTAssertTrue(model.shouldShowEmptyState)
    }

    func testReadOnlyHistoryIsReadableAndDoesNotOfferReadRetry() async throws {
        let page = emptyPage()
        let status = CapabilityHistoryStatus(
            accessMode: .readOnly,
            epoch: 2,
            revision: 1,
            eventCount: 0,
            baselineCount: 0,
            isInitialized: true,
            initializedScopeCount: 1,
            latestScanCoverage: .complete,
            issueCodes: [.readOnlyLockConflict]
        )
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { _ in page },
            statusLoader: { status },
            clearLoader: { status },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) }
        )
        let model = CapabilityHistoryPresentationModel(source: source)

        await model.loadNow()

        XCTAssertEqual(model.presentationStatus, .readOnly)
        XCTAssertEqual(model.statusIssueKey, "history.state.readOnly")
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.shouldOfferReadRetry)
        XCTAssertTrue(model.shouldShowEmptyState)
    }

    func testRecordingFailureRetainsReadableRowsAndDoesNotOfferReadRetry() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 37)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let normal = makeSource(coordinator: coordinator)
        let source = CapabilityHistoryPresentationSource(
            pageLoader: normal.pageLoader,
            statusLoader: {
                let status = await normal.statusLoader()
                return CapabilityHistoryStatus(
                    accessMode: status.accessMode,
                    epoch: status.epoch,
                    revision: status.revision,
                    eventCount: status.eventCount,
                    baselineCount: status.baselineCount,
                    isInitialized: status.isInitialized,
                    initializedScopeCount: status.initializedScopeCount,
                    latestScanCoverage: status.latestScanCoverage,
                    pendingMissingCount: status.pendingMissingCount,
                    issueCodes: Array(Set(status.issueCodes + [.fileBudgetExceeded]))
                )
            },
            clearLoader: normal.clearLoader,
            usageLoader: normal.usageLoader,
            now: normal.now,
            statisticsThrough: normal.statisticsThrough,
            identityLoader: normal.identityLoader,
            usageQueryLoader: normal.usageQueryLoader
        )
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained)

        await model.loadNow()

        XCTAssertFalse(model.events.isEmpty)
        XCTAssertEqual(model.presentationStatus, .recordingFailure)
        XCTAssertEqual(model.statusIssueKey, "history.state.recordingFailure")
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.shouldOfferReadRetry)
    }

    func testLatestObservationSaveFailureKeepsReadableEmptyPageWithoutReadRetry() async throws {
        let page = emptyPage()
        let status = CapabilityHistoryStatus(
            accessMode: .readWrite,
            epoch: 38,
            revision: 2,
            eventCount: 0,
            baselineCount: 0,
            isInitialized: true,
            initializedScopeCount: nil,
            latestScanCoverage: .complete,
            issueCodes: [.storageUnavailable],
            latestObservationSaveFailed: true
        )
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { _ in page },
            statusLoader: { status },
            clearLoader: { status },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) }
        )
        let model = CapabilityHistoryPresentationModel(source: source)

        await model.loadNow()

        XCTAssertEqual(model.presentationStatus, .recordingFailure)
        XCTAssertEqual(model.statusIssueKey, "history.state.recordingFailure")
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.isUnavailable)
        XCTAssertFalse(model.shouldOfferReadRetry)
        XCTAssertTrue(model.shouldShowEmptyState)
        XCTAssertEqual(model.events, [])
    }

    func testCoordinatorInjectedWriteFailureSurfacesRecordingFailureWithRetainedRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let failure = HistoryWriteFailureSwitch()
        let store = try CapabilityHistoryStore.faultInjecting(
            url: root.appendingPathComponent("history.json"),
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeReplacement, failure.shouldFail() {
                    throw CapabilityHistoryStore.StoreError.atomicWriteFailed
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        failure.failWrites()

        let scope = CapabilityHistoryScanScope(
            rootID: "test-history-agents",
            scope: .global,
            rootKind: .agents,
            coverage: .complete
        )
        let observation = CapabilityHistoryObservation(
            resourceID: "agent:test-editor",
            sourceRootID: scope.rootID,
            name: "agent test editor",
            kind: .agent,
            scope: .global,
            projectID: nil,
            documents: [.agentConfiguration, .agentBrief],
            signature: String(repeating: "d", count: 64),
            observedAt: referenceDate.addingTimeInterval(900)
        )
        do {
            _ = try await coordinator.submit(CapabilityHistoryScanBatch(
                observedAt: observation.observedAt,
                scopes: [scope],
                observations: [observation]
            ))
            XCTFail("injected observation save failure did not surface")
        } catch CapabilityHistoryStore.StoreError.atomicWriteFailed {
            // Expected.
        }

        let failedStatus = await coordinator.status()
        XCTAssertTrue(failedStatus.latestObservationSaveFailed)
        XCTAssertTrue(failedStatus.issueCodes.contains(.storageUnavailable))

        let model = CapabilityHistoryPresentationModel(
            source: makeSource(coordinator: coordinator),
            recordWindow: .allRetained
        )
        await model.loadNow()

        XCTAssertFalse(model.events.isEmpty)
        XCTAssertEqual(model.presentationStatus, .recordingFailure)
        XCTAssertFalse(model.isHistoryReadFailure)
        XCTAssertFalse(model.shouldOfferReadRetry)
    }

    func testPageReadFailureSuppressesEmptyAndBaselineWhileRetainingRows() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 41)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let normal = makeSource(coordinator: coordinator)
        let attempts = PageReadAttempts()
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in
                if await attempts.next() == 1 {
                    return try await normal.pageLoader(query)
                }
                throw CapabilityHistoryStore.StoreError.storageUnavailable
            },
            statusLoader: normal.statusLoader,
            clearLoader: normal.clearLoader,
            usageLoader: normal.usageLoader,
            now: normal.now,
            statisticsThrough: normal.statisticsThrough,
            identityLoader: normal.identityLoader,
            usageQueryLoader: normal.usageQueryLoader
        )
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained)

        await model.loadNow()
        let retainedIDs = model.events.map(\.id)
        XCTAssertFalse(retainedIDs.isEmpty)

        await model.loadNow()

        XCTAssertEqual(model.events.map(\.id), retainedIDs)
        XCTAssertTrue(model.isHistoryReadFailure)
        XCTAssertTrue(model.isUnavailable)
        XCTAssertTrue(model.shouldOfferReadRetry)
        XCTAssertFalse(model.shouldShowEmptyState)
        XCTAssertFalse(model.isBaselinePending)
    }

    func testSpecificPageReadFailuresKeepTheirWarningAndOfferRetry() async throws {
        let status = CapabilityHistoryStatus(
            accessMode: .readWrite,
            epoch: 2,
            revision: 1,
            eventCount: 0,
            baselineCount: 0,
            isInitialized: true,
            initializedScopeCount: 1,
            latestScanCoverage: .complete
        )
        let failures: [(CapabilityHistoryStore.StoreError, CapabilityHistoryPresentationStatus)] = [
            (.corrupt, .corrupt),
            (.unsupportedVersion(5), .unsupported),
            (.atomicWriteFailed, .failed),
        ]

        for (failure, expectedStatus) in failures {
            let source = CapabilityHistoryPresentationSource(
                pageLoader: { _ in throw failure },
                statusLoader: { status },
                clearLoader: { status },
                usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) }
            )
            let model = CapabilityHistoryPresentationModel(source: source)

            await model.loadNow()

            XCTAssertEqual(model.presentationStatus, expectedStatus)
            XCTAssertTrue(model.shouldOfferReadRetry)
            XCTAssertFalse(model.shouldShowEmptyState)
            XCTAssertFalse(model.isBaselinePending)
            XCTAssertEqual(model.events, [])
        }
    }

    func testPagedHistoryKeepsNewestFirstAndFiltersByKind() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 3)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)

        let source = makeSource(coordinator: coordinator)
        let now = referenceDate
        let model = CapabilityHistoryPresentationModel(
            source: source,
            recordWindow: .allRetained,
            initialPageSize: 1,
            subsequentPageSize: 2,
            nowProvider: { now }
        )
        await model.loadNow()
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events.first?.kind, .reappeared)
        XCTAssertNotNil(model.nextBeforeSequence)

        await model.loadMoreNow()
        XCTAssertEqual(model.events.map(\.kind), [.reappeared, .missing, .modified])

        // Set the published filter directly so this focused test owns the
        // reload it awaits instead of racing the UI-facing async helper.
        model.resourceFilter = .skill
        await model.loadNow()
        XCTAssertTrue(model.events.allSatisfy { $0.resourceKind == .skill })
        XCTAssertEqual(model.loadState, .empty, "A kind filter with no matching rows remains an explicit empty result")
    }

    func testSelectingMissingEventDoesNotCreateUsageQuery() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 5)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let source = makeSource(coordinator: coordinator)
        let now = referenceDate
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained, nowProvider: { now })
        await model.loadNow()
        let missing = try XCTUnwrap(model.events.first(where: { $0.kind == .missing }))

        model.select(missing)

        XCTAssertEqual(model.selectedEventID, missing.id)
        XCTAssertEqual(model.summaryState, .idle)
    }

    func testSelectedSummaryFindsSameResourceSuccessorOutsideFilteredPage() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 17)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        let scope = CapabilityHistoryScanScope(rootID: "test-neighbor", scope: .global, rootKind: .agents, coverage: .complete)
        let first = referenceDate.addingTimeInterval(-5 * 86_400)
        let changed = referenceDate.addingTimeInterval(-4 * 86_400)
        let missingOne = referenceDate.addingTimeInterval(-3 * 86_400)
        let missingTwo = referenceDate.addingTimeInterval(-2 * 86_400)
        let reappeared = referenceDate.addingTimeInterval(-86_400)
        func observation(_ signature: Character, _ date: Date) -> CapabilityHistoryObservation {
            CapabilityHistoryObservation(
                resourceID: "agent:neighbor",
                sourceRootID: scope.rootID,
                name: "Neighbor Agent",
                kind: .agent,
                scope: .global,
                projectID: nil,
                documents: [.agentConfiguration, .agentBrief],
                signature: String(repeating: String(signature), count: 64),
                observedAt: date
            )
        }
        try await coordinator.submit(CapabilityHistoryScanBatch(observedAt: first, scopes: [scope], observations: [observation("a", first)]))
        try await coordinator.submit(CapabilityHistoryScanBatch(observedAt: changed, scopes: [scope], observations: [observation("b", changed)]))
        try await coordinator.submit(CapabilityHistoryScanBatch(observedAt: missingOne, scopes: [scope], observations: []))
        try await coordinator.submit(CapabilityHistoryScanBatch(observedAt: missingTwo, scopes: [scope], observations: []))
        try await coordinator.submit(CapabilityHistoryScanBatch(observedAt: reappeared, scopes: [scope], observations: [observation("c", reappeared)]))

        let probe = UsageProbe()
        let now = referenceDate
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in try await coordinator.page(query) },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { query in
                await probe.record(query)
                return .unavailable(for: query, availability: .indexUnavailable)
            },
            now: { now }
        )
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained, nowProvider: { now })
        // Set the published value directly so the explicit load below is not
        // raced by the UI-facing asynchronous filter reload helper.
        model.changeFilter = .modified
        await model.loadNow()
        let selected = try XCTUnwrap(model.events.first)
        XCTAssertEqual(selected.kind, .modified)
        model.select(selected)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline && model.summaryState == .loading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let queries = await probe.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries[0].nextObservedAt, missingTwo)
    }

    func testSelectedSummaryFailsClosedWhenNeighborReadFails() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 19)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let probe = UsageProbe()
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in
                if query.resourceID != nil {
                    throw CapabilityHistoryStore.StoreError.storageUnavailable
                }
                return try await coordinator.page(query)
            },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { query in
                await probe.record(query)
                return .unavailable(for: query, availability: .indexUnavailable)
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let model = CapabilityHistoryPresentationModel(
            source: source,
            recordWindow: .allRetained,
            nowProvider: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await model.loadNow()
        let selected = try XCTUnwrap(model.events.first(where: { $0.kind == .modified }))
        model.select(selected)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline && model.summaryState == .loading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let queries = await probe.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertNil(queries[0].nextObservedAt)
        XCTAssertNil(queries[0].databaseIdentity)
        XCTAssertNil(queries[0].statisticsThrough)
        guard case let .loaded(summary) = model.summaryState else {
            return XCTFail("A failed neighbor read must surface an unavailable summary")
        }
        XCTAssertEqual(summary.availability, .indexUnavailable)
    }

    func testSyntheticValidationSessionUsesMemoryHistoryWithoutAddingDataset() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()

        let status = await session.model.capabilityHistoryStatus()
        XCTAssertEqual(status.accessMode, .readWrite)
        XCTAssertEqual(status.isInitialized, true)
        XCTAssertGreaterThan(status.eventCount ?? 0, 0)
        XCTAssertEqual(session.historyCoordinator.accessMode, .readWrite)
        XCTAssertFalse(status.issueCodes.contains(.fileBudgetExceeded))
        XCTAssertFalse(status.issueCodes.contains(.invalidObservation))
        let presentation = CapabilityHistoryPresentationModel(
            source: session.historyPresentationSource(for: .representative)
        )
        await presentation.loadNow()
        XCTAssertFalse(presentation.events.isEmpty, "Representative history must be visible in the default 30-day window")
        XCTAssertTrue(presentation.events.contains { $0.resourceID == "agent:validation-global" })
        XCTAssertEqual(UIValidationSession.Dataset.allCases.count, 7)
    }

    func testPresentationClockAdvancesAfterModelCreation() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 23)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let clock = TestClock(referenceDate)
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in try await coordinator.page(query) },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) },
            now: { clock.read() }
        )
        let model = CapabilityHistoryPresentationModel(source: source)

        await model.loadNow()
        XCTAssertFalse(model.events.isEmpty)

        // The model and source are intentionally created before the clock
        // moves. A one-time presentationNow capture would incorrectly keep
        // these records visible after they age out of the live 30-day window.
        clock.set(referenceDate.addingTimeInterval(40 * 86_400))
        await model.loadNow()
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(model.hasNoMatchingEvents)
    }

    func testSummaryFailureDoesNotSurfaceAsPageFailureOrLeakToNextSelection() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 29)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let now = referenceDate
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in try await coordinator.page(query) },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { _ in throw CapabilityHistoryStore.StoreError.storageUnavailable },
            now: { now }
        )
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained)
        await model.loadNow()
        let first = try XCTUnwrap(model.events.first(where: { $0.kind == .modified }))
        model.select(first)
        try await waitForSummaryState(model, matching: { $0 == .failed })

        XCTAssertEqual(model.summaryErrorKey, "history.state.unavailable")
        XCTAssertNil(model.lastErrorKey, "A usage summary failure must not make the history page look unavailable")

        let next = try XCTUnwrap(model.events.first(where: { $0.id != first.id && $0.kind == .reappeared }))
        model.select(next)
        XCTAssertNil(model.summaryErrorKey, "Selecting another event starts with a clean summary state")
    }

    func testCancelledSummaryRestartsWhenTheHistorySheetReopens() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 31)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        try await submitTimeline(to: coordinator)
        let attempts = SummaryAttempts()
        let now = referenceDate
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in try await coordinator.page(query) },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { query in
                let attempt = await attempts.next()
                if attempt == 1 {
                    try await Task.sleep(for: .seconds(30))
                }
                return .unavailable(for: query, availability: .indexUnavailable)
            },
            now: { now }
        )
        let model = CapabilityHistoryPresentationModel(source: source, recordWindow: .allRetained)
        await model.loadNow()
        let event = try XCTUnwrap(model.events.first(where: { $0.kind == .modified }))
        model.select(event)
        try await waitUntil { await attempts.count >= 1 }

        model.cancelAll()
        XCTAssertEqual(model.selectedEventID, event.id)
        XCTAssertEqual(model.summaryState, .idle, "Cancelling a sheet task must not strand its old loading state")

        model.resumeSelectedSummaryIfNeeded()
        try await waitUntil { await attempts.count >= 2 }
        try await waitForSummaryState(model, matching: {
            if case .loaded = $0 { return true }
            return false
        })
    }

    func testTimelineQueryUsesLiveUpperBoundAndExcludesFutureRows() async throws {
        let now = referenceDate
        let past = CapabilityChangeEvent(
            id: "past",
            resourceID: "agent:future-test",
            name: "Future Boundary Agent",
            resourceKind: .agent,
            scope: .global,
            projectID: nil,
            kind: .added,
            changedDocuments: [.agentConfiguration],
            observedAt: now.addingTimeInterval(-86_400),
            previousConfirmedAt: nil,
            sequence: 1
        )
        let future = CapabilityChangeEvent(
            id: "future",
            resourceID: "agent:future-test",
            name: "Future Boundary Agent",
            resourceKind: .agent,
            scope: .global,
            projectID: nil,
            kind: .modified,
            changedDocuments: [.agentConfiguration],
            observedAt: now.addingTimeInterval(86_400),
            previousConfirmedAt: now.addingTimeInterval(-86_400),
            sequence: 2
        )
        let probe = PageProbe()
        let source = CapabilityHistoryPresentationSource(
            pageLoader: { query in
                await probe.record(query)
                let upper = query.observedOnOrBefore ?? .distantFuture
                return CapabilityHistoryPage(
                    events: [past, future].filter { $0.observedAt <= upper },
                    nextBeforeSequence: nil,
                    revision: 1,
                    epoch: 1,
                    truncatedBefore: nil,
                    issueCodes: []
                )
            },
            statusLoader: {
                CapabilityHistoryStatus(
                    accessMode: .readWrite,
                    epoch: 1,
                    revision: 1,
                    eventCount: 2,
                    baselineCount: 1,
                    isInitialized: true,
                    initializedScopeCount: 1,
                    latestScanCoverage: .complete
                )
            },
            clearLoader: { fatalError("not used") },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) },
            now: { now }
        )
        let model = CapabilityHistoryPresentationModel(source: source)
        await model.loadNow()

        XCTAssertEqual(model.events.map(\.id), [past.id])
        let queries = await probe.queries
        let query = try XCTUnwrap(queries.first)
        XCTAssertEqual(query.observedOnOrBefore, now)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func waitForSummaryState(
        _ model: CapabilityHistoryPresentationModel,
        matching predicate: @escaping (CapabilityHistorySummaryState) -> Bool
    ) async throws {
        try await waitUntil {
            predicate(model.summaryState)
        }
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func emptyPage() -> CapabilityHistoryPage {
        CapabilityHistoryPage(
            events: [],
            nextBeforeSequence: nil,
            revision: 1,
            epoch: 1,
            truncatedBefore: nil,
            issueCodes: []
        )
    }

    private func makeEmptySource(coverage: CapabilityHistoryCoverage) -> CapabilityHistoryPresentationSource {
        let page = emptyPage()
        let now = referenceDate
        let status = CapabilityHistoryStatus(
            accessMode: .readWrite,
            epoch: 1,
            revision: 1,
            eventCount: 0,
            baselineCount: 0,
            isInitialized: true,
            initializedScopeCount: nil,
            latestScanCoverage: coverage
        )
        return CapabilityHistoryPresentationSource(
            pageLoader: { _ in page },
            statusLoader: { status },
            clearLoader: { status },
            usageLoader: { query in .unavailable(for: query, availability: .indexUnavailable) },
            now: { now }
        )
    }

    private func makeSource(coordinator: CapabilityHistoryCoordinator) -> CapabilityHistoryPresentationSource {
        let now = referenceDate
        return CapabilityHistoryPresentationSource(
            pageLoader: { query in try await coordinator.page(query) },
            statusLoader: { await coordinator.status() },
            clearLoader: { try await coordinator.clearConfirmed() },
            usageLoader: { query in
                .unavailable(for: query, availability: .indexUnavailable)
            },
            now: { now }
        )
    }

    private func submitTimeline(to coordinator: CapabilityHistoryCoordinator) async throws {
        let scope = CapabilityHistoryScanScope(
            rootID: "test-history-agents",
            scope: .global,
            rootKind: .agents,
            coverage: .complete
        )
        func observation(_ id: String, _ signature: Character, _ date: Date) -> CapabilityHistoryObservation {
            CapabilityHistoryObservation(
                resourceID: id,
                sourceRootID: scope.rootID,
                name: id.replacingOccurrences(of: ":", with: " "),
                kind: .agent,
                scope: .global,
                projectID: nil,
                documents: [.agentConfiguration, .agentBrief],
                signature: String(repeating: String(signature), count: 64),
                observedAt: date
            )
        }
        let first = referenceDate.addingTimeInterval(-3 * 86_400)
        let second = referenceDate.addingTimeInterval(-2 * 86_400)
        let third = referenceDate.addingTimeInterval(-86_400)
        let fourth = referenceDate.addingTimeInterval(-3_600)
        try await coordinator.submit(CapabilityHistoryScanBatch(
            observedAt: first,
            scopes: [scope],
            observations: [observation("agent:test-editor", "a", first), observation("agent:test-reviewer", "c", first)]
        ))
        try await coordinator.submit(CapabilityHistoryScanBatch(
            observedAt: second,
            scopes: [scope],
            observations: [observation("agent:test-editor", "b", second)]
        ))
        try await coordinator.submit(CapabilityHistoryScanBatch(
            observedAt: third,
            scopes: [scope],
            observations: [observation("agent:test-editor", "b", third)]
        ))
        try await coordinator.submit(CapabilityHistoryScanBatch(
            observedAt: fourth,
            scopes: [scope],
            observations: [observation("agent:test-editor", "b", fourth), observation("agent:test-reviewer", "c", fourth)]
        ))
    }
}
