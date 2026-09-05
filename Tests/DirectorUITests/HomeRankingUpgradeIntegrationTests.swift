import Foundation
import XCTest
@testable import DirectorCore
@testable import DirectorUI

/// End-to-end Home cache-upgrade coverage. The fixture deliberately exercises
/// the startup controller, a real writer/read-only DatabaseStore pair, and the
/// model's scheduler operation; no application preferences or source roots are
/// consulted.
@MainActor
final class HomeRankingUpgradeIntegrationTests: XCTestCase {
    private actor Gate {
        private var entered = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiters.append(continuation) }
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

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func read() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ newValue: Data?) { lock.lock(); value = newValue; lock.unlock() }
    }

    private final class OperationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PresentationQueryOperation] = []
        func append(_ value: PresentationQueryOperation) { lock.lock(); values.append(value); lock.unlock() }
        func count(_ value: PresentationQueryOperation) -> Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 == value }.count }
        func snapshot() -> [PresentationQueryOperation] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class SourceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SourceIndexPhase] = []
        func append(_ value: SourceIndexPhase) { lock.lock(); values.append(value); lock.unlock() }
        func count(_ value: SourceIndexPhase) -> Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 == value }.count }
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(by interval: TimeInterval) { lock.lock(); value.addTimeInterval(interval); lock.unlock() }
    }

    private struct Fixture {
        let root: URL
        let writer: DatabaseStore
        let reader: DatabaseStore
        let cache: PresentationSnapshotStore
        let counter: OperationCounter
        let sourceCounter: SourceCounter
        let sourceCoordinator: IndexingCoordinator
        let sourceConfiguration: IndexingCoordinator.Configuration
        let snapshot: PresentationSnapshot
        let now: Date
        let clock: ClockBox
    }

    func testLegacyTopFiveRendersImmediatelyThenUpgradesThroughHomeOnlyQuery() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(fixture)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        let wallClock = ContinuousClock()
        let upgradeStart = wallClock.now
        controller.start(model: model)

        let restored = await waitUntil { model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(restored)
        XCTAssertEqual(model.presentationHomeSummary?.customAgentsTop.count, 5)
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)

        let upgraded = await waitUntil(timeout: .seconds(8)) { model.presentationHomeSummary?.rankingCapacity == 10 }
        XCTAssertTrue(upgraded)
        let elapsed = upgradeStart.duration(to: wallClock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(5))
        XCTAssertEqual(model.statisticsWindow, fixture.snapshot.window)
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(model.presentationHomeSummary?.customAgentsTop.count, 10)
        XCTAssertEqual(fixture.sourceCounter.count(.started), 0)
        let cached = try await fixture.cache.read(expectedIdentity: fixture.snapshot.identity)
        XCTAssertEqual(cached?.quota, fixture.snapshot.quota)
        XCTAssertEqual(cached?.lastSourceCheckAt, fixture.snapshot.lastSourceCheckAt)
        XCTAssertEqual(cached?.lastIndexCompletedAt, fixture.snapshot.lastIndexCompletedAt)
        XCTAssertEqual(cached?.statisticsThrough, fixture.snapshot.statisticsThrough)
    }

    func testCapacityTenCacheDoesNotScheduleUpgradeOrAggregate() async throws {
        let fixture = try await makeFixture(capacity: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = makeModel(fixture)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)

        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 10 }
        XCTAssertTrue(loaded)
        try await Task.sleep(for: .seconds(5.3))
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(fixture.counter.count(.directory), 1)
        XCTAssertEqual(fixture.sourceCounter.count(.started), 0)
    }

    func testHomeUpgradeCanBeCancelledAfterQueryStartsWhenHomeLeaves() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = Gate()
        let model = makeModel(fixture)
        model.presentationProjectionTestHook = { await gate.wait() }
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)
        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(loaded)

        let entered = await waitForGate(gate, timeout: .seconds(8))
        XCTAssertTrue(entered)
        model.selection = .capabilities
        model.setWindowVisibility(windowID, visible: false)
        await gate.release()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.presentationHomeSummary?.rankingCapacity, 5)
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(fixture.counter.count(.directory), 2)
        XCTAssertEqual(fixture.sourceCounter.count(.started), 0)
    }

    func testHomeUpgradeFailureRetainsTopFiveAndUsesProjectionRetryWithoutQuotaQuery() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let permit = await fixture.cache.activate(identity: fixture.snapshot.identity)
        try await fixture.cache.write(expiredLegacySnapshot(fixture), permit: permit)
        let model = makeModel(fixture)
        model.presentationProjectionTestHook = { throw SyntheticHomeUpgradeError.failed }
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)

        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(loaded)
        let retried = await waitUntil(timeout: .seconds(8)) { model.refreshScheduleState?.projectionRetryAttempt == 1 }
        XCTAssertTrue(retried)
        XCTAssertEqual(model.presentationHomeSummary?.rankingCapacity, 5)
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertGreaterThanOrEqual(fixture.counter.count(.directory), 2)
    }

    func testExpiredLegacyHideShowReschedulesHomeUpgradeWithoutBroadWork() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let permit = await fixture.cache.activate(identity: fixture.snapshot.identity)
        try await fixture.cache.write(expiredLegacySnapshot(fixture), permit: permit)

        let model = makeModel(fixture)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)
        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(loaded)
        model.setWindowVisibility(windowID, visible: false)
        try await Task.sleep(for: .milliseconds(100))
        model.setWindowVisibility(windowID, visible: true)
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(fixture.sourceCounter.count(.started), 0)
        let upgraded = await waitUntil(timeout: .seconds(8)) { model.presentationHomeSummary?.rankingCapacity == 10 }
        XCTAssertTrue(upgraded)
    }

    func testPersistedHomeRetryWaitsForDeadlineAndRunsHomeOnlyAfterRelaunch() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retryDate = fixture.now.addingTimeInterval(0.25)
        let scheduled = PresentationSnapshot(
            identity: fixture.snapshot.identity,
            classificationRevision: fixture.snapshot.classificationRevision,
            window: fixture.snapshot.window,
            generatedAt: fixture.snapshot.generatedAt,
            lastSourceCheckAt: fixture.snapshot.lastSourceCheckAt,
            lastIndexCompletedAt: fixture.snapshot.lastIndexCompletedAt,
            statisticsThrough: fixture.snapshot.statisticsThrough,
            home: fixture.snapshot.home,
            refreshSchedule: PresentationRefreshSchedule(
                revision: 12, recordedAt: fixture.now,
                lastSourceSuccessAt: fixture.now.addingTimeInterval(-60),
                projectionRetryAttempt: 1, projectionRetryDate: retryDate
            )
        )
        let permit = await fixture.cache.activate(identity: fixture.snapshot.identity)
        try await fixture.cache.write(scheduled, permit: permit)

        let model = makeModel(fixture)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)
        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(loaded)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(fixture.counter.count(.directory), 1)
        XCTAssertEqual(fixture.counter.count(.quota), 0)

        fixture.clock.advance(by: 1)
        let upgraded = await waitUntil(timeout: .seconds(3)) { model.presentationHomeSummary?.rankingCapacity == 10 }
        XCTAssertTrue(upgraded)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertGreaterThanOrEqual(fixture.counter.count(.directory), 2)
    }

    func testExpiredLegacyCacheDefersQueuedBroadStartupUntilHomeUpgradeBatch() async throws {
        let fixture = try await makeFixture(capacity: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expired = PresentationSnapshot(
            identity: fixture.snapshot.identity,
            classificationRevision: fixture.snapshot.classificationRevision,
            window: fixture.snapshot.window,
            generatedAt: fixture.snapshot.generatedAt,
            lastSourceCheckAt: fixture.now.addingTimeInterval(-31 * 60),
            lastIndexCompletedAt: fixture.snapshot.lastIndexCompletedAt,
            statisticsThrough: fixture.snapshot.statisticsThrough,
            quota: fixture.snapshot.quota,
            home: fixture.snapshot.home
        )
        let permit = await fixture.cache.activate(identity: fixture.snapshot.identity)
        try await fixture.cache.write(expired, permit: permit)

        let model = makeModel(fixture)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.stopSourceDataMonitor(); model.removeWindow(windowID) }
        let controller = makeController(fixture, model: model)
        controller.start(model: model)
        let loaded = await waitUntil { controller.isFinished && model.presentationHomeSummary?.rankingCapacity == 5 }
        XCTAssertTrue(loaded)

        // The expired cache must not turn the delayed Home upgrade into a
        // broad startup/source request during its five-second grace period.
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertEqual(fixture.counter.count(.startup), 0)
        XCTAssertEqual(fixture.counter.count(.quota), 0)
        XCTAssertEqual(fixture.sourceCounter.count(.started), 0)
        let upgraded = await waitUntil(timeout: .seconds(8)) { model.presentationHomeSummary?.rankingCapacity == 10 }
        XCTAssertTrue(upgraded)
        // The reader may legitimately emit identity observations around the
        // directory read. Assert the operation contract rather than relying on
        // event positions: the Home upgrade must add a bounded directory read
        // while never using startup/quota aggregation before that batch.
        XCTAssertGreaterThan(fixture.counter.count(.directory), 1)
    }

    private enum SyntheticHomeUpgradeError: Error { case failed }

    private func expiredLegacySnapshot(_ fixture: Fixture) -> PresentationSnapshot {
        PresentationSnapshot(
            identity: fixture.snapshot.identity,
            classificationRevision: fixture.snapshot.classificationRevision,
            window: fixture.snapshot.window,
            generatedAt: fixture.snapshot.generatedAt,
            lastSourceCheckAt: fixture.now.addingTimeInterval(-31 * 60),
            lastIndexCompletedAt: fixture.snapshot.lastIndexCompletedAt,
            statisticsThrough: fixture.snapshot.statisticsThrough,
            quota: fixture.snapshot.quota,
            home: fixture.snapshot.home
        )
    }

    private func makeModel(_ fixture: Fixture) -> DirectorAppModel {
        let classifications = LockedData()
        let evaluations = LockedData()
        return DirectorAppModel(
            store: fixture.writer,
            readStore: fixture.reader,
            coordinator: fixture.sourceCoordinator,
            configuration: fixture.sourceConfiguration,
            classificationOverrides: ResourceClassificationOverrideStore(
                readData: { classifications.read() },
                writeData: { classifications.write($0) },
                removeData: { classifications.write(nil) }
            ),
            evaluationStore: InvocationEvaluationStore(
                readData: { evaluations.read() },
                writeData: { evaluations.write($0); return true },
                removeData: { evaluations.write(nil); return true }
            ),
            nowProvider: { fixture.clock.read() },
            previewMode: false,
            presentationSnapshotStore: fixture.cache
        )
    }

    private func makeController(_ fixture: Fixture, model: DirectorAppModel) -> DirectorStartupController {
        DirectorStartupController(
            cacheFactory: { fixture.cache },
            servicesFactory: {
                DirectorStartupServices(
                    store: fixture.writer, readStore: fixture.reader,
                    coordinator: fixture.sourceCoordinator, configuration: fixture.sourceConfiguration,
                    snapshotStore: fixture.cache
                )
            }
        )
    }

    private func makeFixture(capacity: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-ranking-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let counter = OperationCounter()
        let sourceCounter = SourceCounter()
        let reader = try DatabaseStore(
            url: root.appendingPathComponent("derived.sqlite"), readOnly: true,
            queryObserver: { counter.append($0) }
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceCoordinator = IndexingCoordinator(
            store: writer,
            now: { now },
            sourceObserver: { sourceCounter.append($0) }
        )
        let sourceConfiguration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let resources = (0..<11).map { index in
            CapabilityResource(
                id: "home-agent-\(index)", name: "Home Agent \(index)", kind: .agent,
                status: .success, scope: .global, projectID: nil, confidence: .exact,
                summary: nil, sourceRootID: "synthetic-home", relativeSourcePath: "agent-\(index).md",
                sourcePathHash: nil, lastSeenAt: now, ownership: .userOwned, origin: .local
            )
        }
        try await writer.insertResources(resources)
        try await writer.replaceSession(PersistedSessionBatch(
            session: TaskSummary(id: "home-session", projectID: nil, startedAt: now, endedAt: now,
                                 status: .completed, coverage: .complete, parserVersion: "synthetic",
                                 sourceFileID: "synthetic-home-session", title: nil),
            calls: resources.enumerated().map { index, resource in
                InvocationEvent(id: "home-call-\(index)", sessionID: "home-session", parentCallID: nil,
                                ordinal: index, timestamp: now.addingTimeInterval(-Double(index)), actorName: nil,
                                resourceID: resource.id, kind: .agent, status: .completed,
                                durationMs: nil, confidence: .exact, errorCategory: nil)
            }, tokenSnapshots: [], quotaSnapshots: [], findings: []
        ))
        try await writer.markSuccessfulSourceIndex(at: now.addingTimeInterval(-60))
        let identity = try await writer.presentationIdentity()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let rows = (0..<capacity).map { index in
            PresentationHomeTopRow(resourceID: resources[index].id, name: resources[index].name,
                                    category: .customAgents, count: capacity - index,
                                    inferredCount: index == 0 ? 1 : 0,
                                    lastUsedAt: now.addingTimeInterval(-Double(index)))
        }
        let home = PresentationHomeSummary(
            customAgents: 11, customAgentsGlobal: 11, customAgentsProject: 0,
            customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
            installedSkills: 0, installedSkillsIndependent: 0, installedSkillsPluginProvided: 0,
            installedPlugins: 0, enabledPlugins: 0, rankingCapacity: capacity,
            customAgentsTop: rows
        )
        let snapshot = PresentationSnapshot(
            identity: identity, classificationRevision: PresentationClassificationRevision.make([:]),
            window: window, generatedAt: now.addingTimeInterval(-60),
            lastSourceCheckAt: now.addingTimeInterval(-60), lastIndexCompletedAt: now.addingTimeInterval(-60),
            statisticsThrough: window.end,
            quota: QuotaOverviewSnapshot(identity: identity, generatedAt: now, window: window, coverage: .complete, sources: []),
            home: home
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        try await cache.write(snapshot)
        return Fixture(root: root, writer: writer, reader: reader, cache: cache, counter: counter,
                       sourceCounter: sourceCounter, sourceCoordinator: sourceCoordinator,
                       sourceConfiguration: sourceConfiguration, snapshot: snapshot, now: now, clock: ClockBox(now))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func waitForGate(_ gate: Gate, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await gate.hasEntered()) {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
