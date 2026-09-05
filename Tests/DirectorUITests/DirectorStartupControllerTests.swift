import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class DirectorStartupControllerTests: XCTestCase {
    private actor Latch {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class DataBox: @unchecked Sendable {
        var value: Data?
        init(_ value: Data? = nil) { self.value = value }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    private func model() -> DirectorAppModel {
        let classifications = DataBox()
        let evaluations = DataBox()
        return DirectorAppModel(
            classificationOverrides: ResourceClassificationOverrideStore(
                readData: { classifications.value },
                writeData: { classifications.value = $0 },
                removeData: { classifications.value = nil }
            ),
            evaluationStore: InvocationEvaluationStore(
                readData: { evaluations.value },
                writeData: { evaluations.value = $0; return true },
                removeData: { evaluations.value = nil; return true }
            ),
            previewMode: false,
            bootstrapPending: true
        )
    }

    func testCacheIsRestoredBeforeServicesReleaseAndFailureRetainsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-startup-controller-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let identity = PresentationIdentity(databaseEpoch: "controller-test", dataGeneration: 0)
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-60),
            lastSourceCheckAt: now.addingTimeInterval(-60),
            lastIndexCompletedAt: now.addingTimeInterval(-120),
            statisticsThrough: window.end,
            home: PresentationHomeSummary(
                customAgents: 2, customAgentsGlobal: 2, customAgentsProject: 0,
                customSkills: 3, customSkillsGlobal: 3, customSkillsProject: 0,
                installedSkills: 1, installedSkillsIndependent: 1,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        try await cache.write(snapshot)

        let serviceCalls = Counter()
        let servicesEntered = Latch()
        let releaseServices = Latch()
        defer { Task { await releaseServices.open() } }
        let controller = DirectorStartupController(
            cacheFactory: { cache },
            servicesFactory: {
                await serviceCalls.increment()
                await servicesEntered.open()
                await releaseServices.wait()
                return DirectorStartupServices(
                    store: nil, readStore: nil, coordinator: nil,
                    configuration: nil, snapshotStore: nil,
                    safeError: "bootstrap_failed"
                )
            }
        )
        let appModel = model()
        appModel.selection = .customSkills
        let selectedLibrary = appModel.libraryModels.first { $0.category == .customSkills }!
        selectedLibrary.context = .init(scope: .allProjects, search: "cached", sort: .nameAscending)
        appModel.installPresentationSnapshotStore(cache)
        controller.start(model: appModel)

        await servicesEntered.wait()
        await waitUntil { appModel.cacheStatus == .restoredUnverified }
        XCTAssertEqual(appModel.cacheStatus, .restoredUnverified)
        XCTAssertFalse(appModel.sourceDataFresh)
        XCTAssertEqual(appModel.presentationHomeSummary, snapshot.home)
        XCTAssertEqual(appModel.selection, .customSkills)
        XCTAssertEqual(selectedLibrary.context.search, "cached")
        XCTAssertEqual(selectedLibrary.context.sort, .nameAscending)
        let serviceCallCount = await serviceCalls.value
        XCTAssertEqual(serviceCallCount, 1)

        await releaseServices.open()
        await waitUntil { controller.isFinished }
        XCTAssertTrue(controller.isFinished)
        XCTAssertEqual(appModel.presentationState, .failure("bootstrap_failed"))
        XCTAssertEqual(appModel.presentationHomeSummary, snapshot.home)
    }

    func testRepeatedStartsShareOneBootstrapOperation() async {
        let serviceCalls = Counter()
        let servicesEntered = Latch()
        let releaseServices = Latch()
        defer { Task { await releaseServices.open() } }
        let controller = DirectorStartupController(
            cacheFactory: { nil },
            servicesFactory: {
                await serviceCalls.increment()
                await servicesEntered.open()
                await releaseServices.wait()
                return DirectorStartupServices(
                    store: nil, readStore: nil, coordinator: nil,
                    configuration: nil, snapshotStore: nil,
                    safeError: "bootstrap_failed"
                )
            }
        )
        let appModel = model()
        controller.start(model: appModel)
        controller.start(model: appModel)
        await servicesEntered.wait()
        let serviceCallCount = await serviceCalls.value
        XCTAssertEqual(serviceCallCount, 1)
        await releaseServices.open()
        await waitUntil { controller.isFinished }
        XCTAssertTrue(controller.isFinished)
    }

    func testIdentityReconciliationInvalidatesOldCacheAndUsesReadOnlyStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-startup-reader-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let reader = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"), readOnly: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let stale = PresentationSnapshot(
            identity: PresentationIdentity(databaseEpoch: "old-epoch", dataGeneration: 0),
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-60),
            lastSourceCheckAt: now.addingTimeInterval(-60),
            statisticsThrough: window.end,
            home: PresentationHomeSummary(
                customAgents: 99, customAgentsGlobal: 99, customAgentsProject: 0,
                customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        try await cache.write(stale)

        let appModel = model()
        appModel.installServices(
            store: writer,
            readStore: reader,
            coordinator: nil,
            configuration: nil,
            presentationSnapshotStore: cache
        )
        XCTAssertTrue(appModel.readStore === reader)

        let restored = await appModel.loadInitialData()
        XCTAssertFalse(restored)
        XCTAssertNotEqual(appModel.presentationHomeSummary?.customAgents, 99)
        XCTAssertEqual(appModel.cacheStatus, .verified)
    }

    func testReaderFailureRetainsPrebootstrapCacheAsOldData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-startup-reader-failure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("derived.sqlite")
        let writer = try DatabaseStore(url: databaseURL)
        let reader = try DatabaseStore(url: databaseURL, readOnly: true)
        let identity = try await writer.presentationIdentity()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = CapabilityQueryWindow.recent7(now: now, calendar: Calendar(identifier: .gregorian))
        let home = PresentationHomeSummary(
            customAgents: 8, customAgentsGlobal: 8, customAgentsProject: 0,
            customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
            installedSkills: 0, installedSkillsIndependent: 0,
            installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
        )
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        try await cache.write(PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: window,
            generatedAt: now.addingTimeInterval(-60),
            lastSourceCheckAt: now.addingTimeInterval(-60),
            home: home
        ))

        let appModel = model()
        appModel.installPresentationSnapshotStore(cache)
        let cacheRestored = await appModel.restoreCachedPresentation()
        XCTAssertTrue(cacheRestored)

        let corruptor = try XCTUnwrap(SQLiteConnection(url: databaseURL))
        XCTAssertTrue(corruptor.exec("DROP TABLE resources"))
        appModel.installServices(
            store: writer,
            readStore: reader,
            coordinator: nil,
            configuration: nil,
            presentationSnapshotStore: cache
        )

        let loaded = await appModel.loadInitialData()
        XCTAssertFalse(loaded)
        XCTAssertEqual(appModel.presentationHomeSummary, home)
        XCTAssertFalse(appModel.sourceDataFresh)
        XCTAssertEqual(appModel.cacheStatus, .restoredUnverified)
        XCTAssertEqual(appModel.presentationState, .failure("initial_data_load_failed"))
    }
}
