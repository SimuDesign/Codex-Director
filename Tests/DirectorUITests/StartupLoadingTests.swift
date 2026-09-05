import XCTest
@testable import DirectorUI
import DirectorCore

/// Startup cache tests use a disposable database/cache pair and in-memory
/// preference stores. They deliberately do not consult application support,
/// UserDefaults, or source/session roots.
@MainActor
final class StartupLoadingTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&stored)
            lock.unlock()
        }
    }

    private final class MemoryData {
        var value: Data?
    }

    private func preferenceStores() -> (ResourceClassificationOverrideStore, InvocationEvaluationStore) {
        let classifications = MemoryData()
        let evaluations = MemoryData()
        return (
            ResourceClassificationOverrideStore(
                readData: { classifications.value },
                writeData: { classifications.value = $0 },
                removeData: { classifications.value = nil }
            ),
            InvocationEvaluationStore(
                readData: { evaluations.value },
                writeData: { evaluations.value = $0; return true },
                removeData: { evaluations.value = nil; return true }
            )
        )
    }

    func testAppModelSourceSkipDoesNotAdvanceSourceTTL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-source-skip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in sourceCalls.update { $0 += 1 }; return .skipped },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )
        let prefs = preferenceStores()
        let model = DirectorAppModel(
            store: store,
            classificationOverrides: prefs.0,
            evaluationStore: prefs.1,
            previewMode: false,
            presentationRefreshCoordinator: coordinator
        )
        let window = UUID()
        model.setWindowVisibility(window, visible: true)
        defer { model.removeWindow(window) }

        let result = await model.requestPresentationRefresh(reason: .automatic, force: true)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 1)
        XCTAssertNil(coordinator.lastSuccessfulAt)
    }

    func testTenRestartsRestoreFreshCacheWithoutBuildingProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-startup-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let directoryResource = CapabilityResource(
            id: "agent:cached-directory",
            name: "Cached directory agent",
            kind: .agent,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Directory-only startup fixture",
            sourceRootID: "startup-test",
            relativeSourcePath: "agent.md",
            sourcePathHash: nil,
            lastSeenAt: now,
            ownership: .userOwned,
            origin: .local
        )
        try await store.insertResources([directoryResource])
        try await store.markSuccessfulSourceIndex(at: now.addingTimeInterval(-120))
        let identity = try await store.presentationIdentity()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let reported = try QuotaSnapshot(
            id: "cached-quota",
            capturedAt: now.addingTimeInterval(-60),
            windowMinutes: 10_080,
            usedPercent: 17,
            resetsAt: now.addingTimeInterval(86_400),
            limitID: "weekly",
            limitName: "Cached weekly",
            confidence: .exact
        )
        let quota = QuotaOverviewSnapshot(
            identity: identity,
            generatedAt: now.addingTimeInterval(-60),
            window: window,
            coverage: .complete,
            sources: [QuotaOverviewSourceSnapshot(
                id: "cached-source",
                name: "Cached source",
                current: reported,
                daily: [QuotaOverviewDay(day: now, observation: reported, cycleChanged: false)]
            )]
        )
        let home = PresentationHomeSummary(
            customAgents: 7,
            customAgentsGlobal: 4,
            customAgentsProject: 3,
            customSkills: 5,
            customSkillsGlobal: 5,
            customSkillsProject: 0,
            installedSkills: 2,
            installedSkillsIndependent: 2,
            installedSkillsPluginProvided: 0,
            installedPlugins: 1,
            enabledPlugins: 1
        )
        let sourceCheck = now.addingTimeInterval(-60)
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-60),
            lastSourceCheckAt: sourceCheck,
            lastIndexCompletedAt: now.addingTimeInterval(-120),
            statisticsThrough: window.end,
            quota: quota,
            home: home
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let permit = await cache.activate(identity: identity)
        try await cache.write(snapshot, permit: permit)

        for _ in 0..<10 {
            let prefs = preferenceStores()
            let model = DirectorAppModel(
                store: store,
                classificationOverrides: prefs.0,
                evaluationStore: prefs.1,
                nowProvider: { now },
                previewMode: false,
                presentationSnapshotStore: cache
            )

            let restored = await model.loadInitialData()
            XCTAssertTrue(restored)
            XCTAssertTrue(model.sourceDataFresh)
            XCTAssertEqual(model.quotaOverviewSnapshot, quota)
            XCTAssertEqual(model.presentationHomeSummary, home)
            XCTAssertEqual(model.lastIndexCompletedAt, now.addingTimeInterval(-120))
            XCTAssertTrue(model.tasks.rows.isEmpty)
            XCTAssertEqual(model.capabilities.allRows.map(\.id), [directoryResource.id])
        }
    }

    func testExpiredAndFutureCachesRemainSourceStale() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let persistedSourceFailure = PresentationRefreshSchedule(
            revision: 2,
            recordedAt: now,
            lastSourceSuccessAt: now.addingTimeInterval(-60),
            sourceRetryAttempt: 1,
            sourceRetryDate: now.addingTimeInterval(5 * 60)
        )
        let cases: [(String, TimeInterval, PresentationRefreshSchedule?, TimeInterval?)] = [
            ("expired", -31 * 60, nil, nil),
            ("future", 1, nil, nil),
            ("persisted-source-failure", -60, persistedSourceFailure, -60),
            ("authoritative-future", -60, nil, 1)
        ]

        for (label, offset, schedule, authoritativeOffset) in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("director-source-freshness-\(label)-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
            if let authoritativeOffset {
                try await store.markSuccessfulSourceIndex(at: now.addingTimeInterval(authoritativeOffset))
            }
            let identity = try await store.presentationIdentity()
            let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
            let quota = QuotaOverviewSnapshot(
                identity: identity,
                generatedAt: now,
                window: window,
                coverage: .complete,
                sources: []
            )
            let home = PresentationHomeSummary(
                customAgents: 0, customAgentsGlobal: 0, customAgentsProject: 0,
                customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
            let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
            let permit = await cache.activate(identity: identity)
            try await cache.write(PresentationSnapshot(
                identity: identity,
                classificationRevision: PresentationClassificationRevision.make([:]),
                window: window,
                generatedAt: now,
                lastSourceCheckAt: now.addingTimeInterval(offset),
                lastIndexCompletedAt: now,
                statisticsThrough: window.end,
                quota: quota,
                home: home,
                refreshSchedule: schedule
            ), permit: permit)

            let prefs = preferenceStores()
            let model = DirectorAppModel(
                store: store,
                classificationOverrides: prefs.0,
                evaluationStore: prefs.1,
                nowProvider: { now },
                previewMode: false,
                presentationSnapshotStore: cache
            )

            let restored = await model.loadInitialData()
            XCTAssertTrue(restored, label)
            XCTAssertFalse(model.sourceDataFresh, label)
        }
    }
}
