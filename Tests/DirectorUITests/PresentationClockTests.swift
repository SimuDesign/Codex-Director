import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

/// Clock tests exercise the model's real monitor task. They use disposable
/// stores and an injected clock so advancing presentation time never starts a
/// source scan or consults application preferences.
@MainActor
final class PresentationClockTests: XCTestCase {
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

    private actor StickyGate {
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
            waiters.removeAll(keepingCapacity: false)
            pending.forEach { $0.resume() }
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
            guard clock.now < deadline else {
                XCTFail("condition did not become true", file: file, line: line)
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSourceMonitorAdvancesClockWhileSourcePhaseIsBlocked() async throws {
        let root = try temporaryDirectory("director-clock-source")
        defer { try? FileManager.default.removeItem(at: root) }

        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let advanced = initial.addingTimeInterval(3)
        let clock = TestClock(initial)
        let sourceCalls = Counter()
        let projectionCalls = Counter()
        let sourceGate = StickyGate()
        let refreshCoordinator = RefreshCoordinator(
            initialGrace: 0,
            timeout: 0,
            clock: { clock.now },
            sourceOperation: { _ in
                sourceCalls.increment()
                await sourceGate.wait()
                return .succeeded(clock.now)
            },
            operation: { _ in
                projectionCalls.increment()
                return .completed
            }
        )
        let store = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let indexingCoordinator = IndexingCoordinator(store: store)
        let configuration = IndexingCoordinator.Configuration(scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil)
        let preferences = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: store,
            coordinator: indexingCoordinator,
            configuration: configuration,
            classificationOverrides: preferences.0,
            evaluationStore: preferences.1,
            nowProvider: { clock.now },
            previewMode: false,
            presentationRefreshCoordinator: refreshCoordinator
        )

        _ = await model.loadInitialData()
        XCTAssertEqual(sourceCalls.read(), 0)
        projectionCalls.reset()
        refreshCoordinator.setAutomaticSourceEnabled(true)
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        model.stopSourceDataMonitor()
        model.startSourceDataMonitor(pollInterval: 0.01)
        defer {
            model.removeWindow(windowID)
            Task { await sourceGate.release() }
        }

        guard await waitUntil({ sourceCalls.read() == 1 }) else {
            return
        }
        let sourceEntered = await sourceGate.hasEntered()
        XCTAssertTrue(sourceEntered)
        clock.set(advanced)
        guard await waitUntil({ model.presentationNow == advanced }) else {
            return
        }
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 0)

        await sourceGate.release()
        _ = await waitUntil({ projectionCalls.read() == 1 })
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 1)
        model.removeWindow(windowID)
    }

    func testClockCrossingQuotaResetShowsWaitingWithoutRefreshWork() async throws {
        let root = try temporaryDirectory("director-clock-reset")
        defer { try? FileManager.default.removeItem(at: root) }

        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = initial.addingTimeInterval(0.05)
        let afterReset = reset.addingTimeInterval(0.01)
        let clock = TestClock(initial)
        let identity = PresentationIdentity(databaseEpoch: UUID().uuidString, dataGeneration: 1)
        let calendar = Calendar(identifier: .gregorian)
        let window = CapabilityQueryWindow.recent7(now: initial, calendar: calendar)
        let quotaSnapshot = try QuotaSnapshot(
            id: "clock-quota",
            capturedAt: initial,
            windowMinutes: 10_080,
            usedPercent: 25,
            resetsAt: reset,
            limitID: "clock-source",
            limitName: "Clock source",
            confidence: .exact
        )
        let quota = QuotaOverviewSnapshot(
            identity: identity,
            generatedAt: initial,
            window: window,
            coverage: .complete,
            sources: [QuotaOverviewSourceSnapshot(
                id: "clock-source",
                name: "Clock source",
                current: quotaSnapshot,
                daily: [QuotaOverviewDay(day: initial, observation: quotaSnapshot)]
            )]
        )
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: initial,
            lastSourceCheckAt: initial,
            quota: quota,
            home: PresentationHomeSummary(
                customAgents: 0, customAgentsGlobal: 0, customAgentsProject: 0,
                customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let permit = await cache.activate(identity: identity)
        try await cache.write(snapshot, permit: permit)

        let sourceCalls = Counter()
        let projectionCalls = Counter()
        let refreshCoordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in sourceCalls.increment(); return .succeeded(initial) },
            operation: { _ in projectionCalls.increment(); return .completed }
        )
        let preferences = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            classificationOverrides: preferences.0,
            evaluationStore: preferences.1,
            nowProvider: { clock.now },
            previewMode: false,
            presentationSnapshotStore: cache,
            presentationRefreshCoordinator: refreshCoordinator
        )
        let restored = await model.restoreCachedPresentation()
        XCTAssertTrue(restored)
        let before = QuotaOverviewModel(snapshot: quota, now: model.presentationNow, calendar: calendar)
        XCTAssertFalse(before.isAwaitingNewData)

        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        model.stopSourceDataMonitor()
        model.startSourceDataMonitor(pollInterval: 0.01)
        defer { model.removeWindow(windowID) }
        clock.set(afterReset)
        guard await waitUntil({ model.presentationNow == afterReset }) else { return }

        let after = QuotaOverviewModel(snapshot: quota, now: model.presentationNow, calendar: calendar)
        XCTAssertTrue(after.isAwaitingNewData)
        XCTAssertNil(after.remainingPercent)
        XCTAssertEqual(sourceCalls.read(), 0)
        XCTAssertEqual(projectionCalls.read(), 0)
    }

    func testRemovingLastWindowStopsPresentationClockMonitor() async throws {
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(initial)
        let preferences = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            classificationOverrides: preferences.0,
            evaluationStore: preferences.1,
            nowProvider: { clock.now },
            previewMode: false
        )
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        model.stopSourceDataMonitor()
        model.startSourceDataMonitor(pollInterval: 0.01)
        clock.set(initial.addingTimeInterval(1))
        guard await waitUntil({ model.presentationNow == initial.addingTimeInterval(1) }) else { return }

        model.removeWindow(windowID)
        let frozen = model.presentationNow
        clock.set(initial.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.presentationNow, frozen)
    }

    func testVisibleModelCanReleaseWithoutExplicitMonitorStop() async throws {
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(initial)
        weak var weakModel: DirectorAppModel?
        do {
            let preferences = TestMemoryPreferences.makeStores()
            var model: DirectorAppModel? = DirectorAppModel(
                classificationOverrides: preferences.0,
                evaluationStore: preferences.1,
                nowProvider: { clock.now },
                previewMode: false
            )
            weakModel = model
            let windowID = UUID()
            model?.setWindowVisibility(windowID, visible: true)
            model?.stopSourceDataMonitor()
            model?.startSourceDataMonitor(pollInterval: 0.01)
            guard let runningModel = model else {
                model = nil
                return
            }
            clock.set(initial.addingTimeInterval(1))
            guard await waitUntil({ runningModel.presentationNow == initial.addingTimeInterval(1) }) else {
                model = nil
                return
            }
            model = nil
        }
        let released = await waitUntil({ weakModel == nil })
        XCTAssertTrue(released)
    }
}
