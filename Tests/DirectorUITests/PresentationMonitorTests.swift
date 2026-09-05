import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class PresentationMonitorTests: XCTestCase {
    private actor Gate {
        private var entered = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { waiters.append(continuation) }
            }
        }

        func hasEntered() -> Bool { entered }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func reset() {
            lock.lock()
            value = 0
            lock.unlock()
        }
    }

    private final class OperationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [PresentationQueryOperation] = []

        func append(_ operation: PresentationQueryOperation) {
            lock.lock()
            operations.append(operation)
            lock.unlock()
        }

        func count(_ operation: PresentationQueryOperation) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return operations.filter { $0 == operation }.count
        }

        func reset() {
            lock.lock()
            operations.removeAll()
            lock.unlock()
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            if clock.now >= deadline {
                XCTFail("condition did not become true", file: file, line: line)
                return false
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private func waitForGate(_ gate: Gate) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await gate.hasEntered()) {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func testHiddenWindowCancelsQueuedStartupWithoutRunningProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let operations = OperationCounter()
        let database = try DatabaseStore(
            url: root.appendingPathComponent("derived.sqlite"),
            queryObserver: { operations.append($0) }
        )
        let indexingCoordinator = IndexingCoordinator(store: database)
        let sleeperGate = Gate()
        let projectionCalls = Counter()
        let refreshCoordinator = RefreshCoordinator(
            initialGrace: 5,
            timeout: 0,
            sleeper: { _ in await sleeperGate.wait() },
            operation: { _ in
                projectionCalls.increment()
                return .completed
            }
        )
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: database,
            coordinator: indexingCoordinator,
            configuration: configuration,
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            previewMode: false,
            presentationRefreshCoordinator: refreshCoordinator
        )

        let loaded = await model.loadInitialData()
        XCTAssertFalse(loaded)
        // The initial bounded projection is scheduler-owned; this test only
        // measures the visibility transition that follows it.
        projectionCalls.reset()
        let window = UUID()
        model.setWindowVisibility(window, visible: true)
        let entered = await waitForGate(sleeperGate)
        guard entered else {
            await sleeperGate.release()
            return
        }

        model.setWindowVisibility(window, visible: false)
        await sleeperGate.release()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(projectionCalls.read(), 0)

        model.setWindowVisibility(window, visible: true)
        let reentered = await waitForGate(sleeperGate)
        XCTAssertTrue(reentered)
        await sleeperGate.release()
        _ = await waitUntil { projectionCalls.read() == 1 }
        XCTAssertEqual(projectionCalls.read(), 1)
    }

    func testInitialLoadRestoresPersistedRetryBeforeScheduling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-schedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let identity = try await database.presentationIdentity()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let schedule = PresentationRefreshSchedule(
            revision: 6,
            recordedAt: now.addingTimeInterval(-10),
            lastSourceSuccessAt: now.addingTimeInterval(-1_800),
            sourceRetryAttempt: 2,
            sourceRetryDate: now.addingTimeInterval(120)
        )
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-5),
            lastSourceCheckAt: now.addingTimeInterval(-1),
            quota: QuotaOverviewSnapshot(identity: identity, window: window, coverage: .complete, sources: []),
            home: PresentationHomeSummary(
                customAgents: 0, customAgentsGlobal: 0, customAgentsProject: 0,
                customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            ),
            refreshSchedule: schedule
        )
        let permit = await cache.activate(identity: identity)
        try await cache.write(snapshot, permit: permit)

        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { now },
            previewMode: false,
            presentationSnapshotStore: cache
        )
        let restored = await model.loadInitialData()
        XCTAssertTrue(restored)
        XCTAssertEqual(model.refreshScheduleState?.sourceRetryAttempt, 2)
        XCTAssertEqual(model.refreshScheduleState?.sourceRetryDate, schedule.sourceRetryDate)
        XCTAssertEqual(model.refreshScheduleState?.lastSourceSuccessAt, schedule.lastSourceSuccessAt)
    }

    func testSourceCommitProjectionFailurePersistsAndRestoresRetryAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-retry-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(now)
        let operations = OperationCounter()
        let database = try DatabaseStore(
            url: root.appendingPathComponent("derived.sqlite"),
            queryObserver: { operations.append($0) }
        )
        let seededResource = CapabilityResource(
            id: "agent:controller-seeded",
            name: "Controller seeded agent",
            kind: .agent,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Synthetic controller fixture",
            sourceRootID: "test-root",
            relativeSourcePath: "agent.md",
            sourcePathHash: "hash",
            lastSeenAt: now,
            ownership: .userOwned,
            origin: .local,
            contentFingerprint: "fingerprint"
        )
        try await database.replaceResourceInventory(resources: [seededResource])
        try await database.markSuccessfulSourceIndex(at: now)
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let identity = try await database.presentationIdentity()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let quota = QuotaOverviewSnapshot(
            identity: identity,
            window: window,
            coverage: .complete,
            sources: []
        )
        let home = PresentationHomeSummary(
            customAgents: 1,
            customAgentsGlobal: 1,
            customAgentsProject: 0,
            customSkills: 0,
            customSkillsGlobal: 0,
            customSkillsProject: 0,
            installedSkills: 0,
            installedSkillsIndependent: 0,
            installedSkillsPluginProvided: 0,
            installedPlugins: 0,
            enabledPlugins: 0
        )
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-10),
            lastSourceCheckAt: now,
            lastIndexCompletedAt: now,
            quota: quota,
            home: home,
            refreshSchedule: PresentationRefreshSchedule(revision: 2, recordedAt: now)
        )
        let permit = await cache.activate(identity: identity)
        try await cache.write(snapshot, permit: permit)

        let stores = TestMemoryPreferences.makeStores()
        let indexingCoordinator = IndexingCoordinator(store: database)
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { now },
            previewMode: false,
            presentationSnapshotStore: cache
        )
        model.presentationProjectionTestHook = { throw ProbeError.failed }
        let services = DirectorStartupServices(
            store: database,
            readStore: database,
            coordinator: indexingCoordinator,
            configuration: configuration,
            snapshotStore: cache
        )
        let controller = DirectorStartupController(
            cacheFactory: { cache },
            servicesFactory: { services }
        )
        controller.start(model: model)
        let controllerFinished = await waitUntil { controller.isFinished }
        XCTAssertTrue(controllerFinished)
        XCTAssertEqual(operations.count(.startup), 0)
        // Exercise the real source-commit -> bounded-projection-failure path;
        // the empty synthetic roots keep this test entirely disposable.
        await model.startIndexing()
        XCTAssertEqual(model.refreshScheduleState?.lastSourceSuccessAt, now)
        XCTAssertEqual(model.refreshScheduleState?.projectionRetryAttempt, 1)

        let persisted = await waitForSchedule(cache, projectionRetryAttempt: 1)
        XCTAssertTrue(persisted)
        operations.reset()

        let restartedStores = TestMemoryPreferences.makeStores()
        let restartedCache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let restarted = DirectorAppModel(
            classificationOverrides: restartedStores.0,
            evaluationStore: restartedStores.1,
            nowProvider: { clock.now },
            previewMode: false,
            presentationSnapshotStore: restartedCache
        )
        let restartedServices = DirectorStartupServices(
            store: database,
            readStore: database,
            coordinator: IndexingCoordinator(store: database),
            configuration: configuration,
            snapshotStore: restartedCache
        )
        let restartedController = DirectorStartupController(
            cacheFactory: { restartedCache },
            servicesFactory: { restartedServices }
        )
        restartedController.start(model: restarted)
        let restartedFinished = await waitUntil { restartedController.isFinished }
        XCTAssertTrue(restartedFinished)
        XCTAssertEqual(restarted.refreshScheduleState?.projectionRetryAttempt, 1)
        XCTAssertEqual(operations.count(.startup), 0)

        guard let retryDate = restarted.refreshScheduleState?.projectionRetryDate else {
            XCTFail("projection retry date was not restored")
            return
        }
        clock.set(retryDate.addingTimeInterval(1))
        let visibleWindow = UUID()
        restarted.setWindowVisibility(visibleWindow, visible: true)
        let result = await restarted.requestPresentationRefresh(reason: .automatic)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(operations.count(.startup), 1)
        restarted.removeWindow(visibleWindow)
    }

    func testFirstProjectionFailurePersistsEmptyEnvelopeAndHonorsRetryDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-empty-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let operations = OperationCounter()
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        let database = try DatabaseStore(url: databaseURL)
        let seededResource = CapabilityResource(
            id: "agent:cold-retry",
            name: "Cold retry agent",
            kind: .agent,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Synthetic indexed resource",
            sourceRootID: "test-root",
            relativeSourcePath: "agent.md",
            sourcePathHash: "hash",
            lastSeenAt: clock.now,
            ownership: .userOwned,
            origin: .local,
            contentFingerprint: "fingerprint"
        )
        try await database.replaceResourceInventory(resources: [seededResource])
        try await database.markSuccessfulSourceIndex(at: clock.now)
        let readDatabase = try DatabaseStore(
            url: databaseURL,
            readOnly: true,
            queryObserver: { operations.append($0) }
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: database,
            readStore: readDatabase,
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { clock.now },
            previewMode: false,
            presentationSnapshotStore: cache
        )
        model.presentationProjectionTestHook = { throw ProbeError.failed }

        let firstLoad = await model.loadInitialData()
        XCTAssertFalse(firstLoad)
        let persisted = await waitForSchedule(cache, projectionRetryAttempt: 1)
        XCTAssertTrue(persisted)
        XCTAssertEqual(operations.count(.startup), 1)
        let persistedSnapshot = try await cache.read()
        let retryDate = try XCTUnwrap(persistedSnapshot?.refreshSchedule?.projectionRetryDate)

        let visibleWindow = UUID()
        model.setWindowVisibility(visibleWindow, visible: true)
        clock.set(retryDate.addingTimeInterval(1))
        model.stopSourceDataMonitor()
        model.startSourceDataMonitor(pollInterval: 0.01)
        let retriedInProcess = await waitUntil {
            model.refreshScheduleState?.projectionRetryAttempt == 2
        }
        XCTAssertTrue(retriedInProcess)
        let persistedSecondRetry = await waitForSchedule(cache, projectionRetryAttempt: 2)
        XCTAssertTrue(persistedSecondRetry)
        XCTAssertEqual(operations.count(.startup), 2)
        XCTAssertEqual(model.refreshScheduleState?.projectionRetryAttempt, 2)
        let secondRetrySnapshot = try await cache.read()
        let secondRetryDate = try XCTUnwrap(secondRetrySnapshot?.refreshSchedule?.projectionRetryDate)
        XCTAssertEqual(secondRetryDate, retryDate.addingTimeInterval(1 + 15 * 60))
        XCTAssertEqual(secondRetrySnapshot?.quota, nil)
        XCTAssertEqual(secondRetrySnapshot?.home, nil)
        model.removeWindow(visibleWindow)
        model.stopSourceDataMonitor()

        let restartedStores = TestMemoryPreferences.makeStores()
        let restarted = DirectorAppModel(
            store: database,
            readStore: try DatabaseStore(url: databaseURL, readOnly: true, queryObserver: { operations.append($0) }),
            classificationOverrides: restartedStores.0,
            evaluationStore: restartedStores.1,
            nowProvider: { clock.now },
            previewMode: false,
            presentationSnapshotStore: PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        )
        let restored = await restarted.loadInitialData()
        XCTAssertFalse(restored)
        XCTAssertTrue(restarted.directoryLoaded)
        XCTAssertFalse(restarted.hasComputedStatistics)
        XCTAssertEqual(operations.count(.startup), 2)

        clock.set(secondRetryDate.addingTimeInterval(-1))
        let window = UUID()
        restarted.setWindowVisibility(window, visible: true)
        let deferred = await restarted.requestPresentationRefresh(reason: .automatic)
        XCTAssertEqual(deferred, .deferred)
        XCTAssertEqual(operations.count(.startup), 2)

        clock.set(secondRetryDate.addingTimeInterval(1))
        restarted.stopSourceDataMonitor()
        restarted.startSourceDataMonitor(pollInterval: 0.01)
        let completed = await waitUntil {
            operations.count(.startup) == 3 &&
            restarted.hasComputedStatistics &&
            restarted.refreshScheduleState?.projectionRetryAttempt == 0 &&
            restarted.refreshScheduleState?.projectionRetryDate == nil
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(operations.count(.startup), 3)
        let fullPayloadStore = try XCTUnwrap(restarted.presentationSnapshotStore)
        let persistedFullPayload = await waitForFullPayload(fullPayloadStore)
        XCTAssertTrue(persistedFullPayload)
        let fullPayload = try await fullPayloadStore.read()
        XCTAssertNotNil(fullPayload?.quota)
        XCTAssertNotNil(fullPayload?.home)
        restarted.removeWindow(window)
    }

    func testMonitorReconcilesYesterdayCacheAfterPrebootstrapTodayTick() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-midnight-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 0, minute: 5))!
        let oldNow = now.addingTimeInterval(-10 * 60)
        let clock = TestClock(oldNow.addingTimeInterval(-1))
        let operations = OperationCounter()
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        let database = try DatabaseStore(url: databaseURL)
        let resource = CapabilityResource(
            id: "agent:midnight",
            name: "Midnight agent",
            kind: .agent,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Synthetic midnight fixture",
            sourceRootID: "test-root",
            relativeSourcePath: "agent.md",
            sourcePathHash: "hash",
            lastSeenAt: oldNow,
            ownership: .userOwned,
            origin: .local,
            contentFingerprint: "fingerprint"
        )
        try await database.replaceResourceInventory(resources: [resource])
        try await database.markSuccessfulSourceIndex(at: oldNow)
        let readDatabase = try DatabaseStore(
            url: databaseURL,
            readOnly: true,
            queryObserver: { operations.append($0) }
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let identity = try await database.presentationIdentity()
        let oldWindow = CapabilityQueryWindow.recent7(now: oldNow, calendar: calendar)
        let oldSnapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: oldWindow,
            generatedAt: oldNow,
            lastSourceCheckAt: oldNow,
            lastIndexCompletedAt: oldNow,
            quota: QuotaOverviewSnapshot(identity: identity, window: oldWindow, coverage: .complete, sources: []),
            home: PresentationHomeSummary(
                customAgents: 1, customAgentsGlobal: 1, customAgentsProject: 0,
                customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
        )
        let permit = await cache.activate(identity: identity)
        try await cache.write(oldSnapshot, permit: permit)

        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { clock.now },
            calendar: calendar,
            previewMode: false,
            presentationSnapshotStore: cache
        )
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        clock.set(now)
        let todayTicked = await waitUntil { model.presentationNow == now }
        XCTAssertTrue(todayTicked)
        let restored = await model.restoreCachedPresentation()
        XCTAssertTrue(restored)

        model.setWindowVisibility(windowID, visible: false)
        model.installServices(
            store: database,
            readStore: readDatabase,
            coordinator: nil,
            configuration: nil,
            presentationSnapshotStore: cache
        )
        let loaded = await model.loadInitialData()
        XCTAssertTrue(loaded)
        XCTAssertEqual(operations.count(.startup), 0)

        model.setWindowVisibility(windowID, visible: true)
        model.stopSourceDataMonitor()
        model.startSourceDataMonitor(pollInterval: 0.01)
        let projected = await waitUntil {
            model.statisticsWindow?.end == now && operations.count(.startup) == 1
        }
        XCTAssertTrue(projected)
        XCTAssertEqual(operations.count(.startup), 1)
        XCTAssertEqual(model.sourceDataLastCheckedAt, oldNow)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(operations.count(.startup), 1)
        model.removeWindow(windowID)
    }

    func testTwoVisibleWindowsSleepAndWakeProduceOneAutomaticAction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-monitor-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let indexingCoordinator = IndexingCoordinator(store: database)
        let stores = TestMemoryPreferences.makeStores()
        let sleeperGate = Gate()
        let actions = Counter()
        let refreshCoordinator = RefreshCoordinator(
            initialGrace: 5,
            timeout: 0,
            sleeper: { _ in await sleeperGate.wait() },
            operation: { _ in
                actions.increment()
                return .completed
            }
        )
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let model = DirectorAppModel(
            store: database,
            coordinator: indexingCoordinator,
            configuration: configuration,
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            previewMode: false,
            presentationRefreshCoordinator: refreshCoordinator
        )
        _ = await model.loadInitialData()
        actions.reset()

        let firstWindow = UUID()
        let secondWindow = UUID()
        model.setWindowVisibility(firstWindow, visible: true)
        model.setWindowVisibility(secondWindow, visible: true)
        let startupEntered = await waitForGate(sleeperGate)
        XCTAssertTrue(startupEntered)

        model.setSystemSleeping(true)
        await sleeperGate.release()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(actions.read(), 0)

        model.setSystemSleeping(false)
        _ = await waitUntil { actions.read() == 1 }
        XCTAssertEqual(actions.read(), 1)

        model.removeWindow(firstWindow)
        model.setSystemSleeping(true)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(actions.read(), 1)
        model.removeWindow(secondWindow)
    }

    func testClockChangePublishesLightweightPresentationNowImmediately() async {
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let later = initial.addingTimeInterval(86_400)
        let clock = TestClock(initial)
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { clock.now },
            previewMode: false
        )

        clock.set(later)
        model.presentationClockDidChange(timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(model.presentationNow, later)
        XCTAssertEqual(model.statisticsCalendar.timeZone, TimeZone(secondsFromGMT: 0))
    }

    private func waitForSchedule(
        _ cache: PresentationSnapshotStore,
        projectionRetryAttempt: Int
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let snapshot = try? await cache.read(),
               snapshot.refreshSchedule?.projectionRetryAttempt == projectionRetryAttempt {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func waitForFullPayload(_ cache: PresentationSnapshotStore) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let snapshot = try? await cache.read(),
               snapshot.quota != nil,
               snapshot.home != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private enum ProbeError: Error { case failed }
}
