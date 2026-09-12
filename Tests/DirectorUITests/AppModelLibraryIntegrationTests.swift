import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class AppModelLibraryIntegrationTests: XCTestCase {
    private final class MemoryData {
        var value: Data?
    }

    private final class MigrationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RefreshRequest] = []

        func append(_ request: RefreshRequest) {
            lock.lock()
            values.append(request)
            lock.unlock()
        }

        func snapshot() -> [RefreshRequest] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func makePreferenceStores() -> (ResourceClassificationOverrideStore, InvocationEvaluationStore) {
        let classificationData = MemoryData()
        let evaluationData = MemoryData()
        let classifications = ResourceClassificationOverrideStore(
            readData: { classificationData.value },
            writeData: { classificationData.value = $0 },
            removeData: { classificationData.value = nil }
        )
        let evaluations = InvocationEvaluationStore(
            readData: { evaluationData.value },
            writeData: { evaluationData.value = $0; return true },
            removeData: { evaluationData.value = nil; return true }
        )
        return (classifications, evaluations)
    }

    func testMissingRelationshipMarkerTriggersOneForcedSourceMigrationAndPersistsIt() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-companion-migration-\(UUID().uuidString).sqlite")
        )
        let resource = resource("agent:migration", "Migration Agent", project: nil)
        try await database.replaceResourceInventory(resources: [resource])
        let initialMarker = try await database.relationshipIndexVersion()
        XCTAssertNil(initialMarker)

        let probe = MigrationProbe()
        let source = IndexingCoordinator(store: database)
        let coordinator = RefreshCoordinator(
            initialGrace: 0,
            timeout: 0,
            sourceOperation: { request in
                probe.append(request)
                // This injected source operation stands in for the real
                // AppModel indexing boundary and writes the marker only after
                // a successful source pass.
                try await database.markSuccessfulSourceIndex(
                    at: now,
                    relationshipIndexVersion: CapabilityCompanionIndex.currentVersion
                )
                return .succeeded(now)
            },
            operation: { _ in .completed }
        )
        let stores = makePreferenceStores()
        let model = DirectorAppModel(
            store: database,
            coordinator: source,
            configuration: .init(scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil),
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { now },
            previewMode: false,
            presentationRefreshCoordinator: coordinator
        )
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.removeWindow(windowID) }

        try await model.refresh()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.snapshot().isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let requests = probe.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.domains, [.directory])
        XCTAssertTrue(requests.first?.force == true)
        XCTAssertTrue(requests.first?.sourceIntent == true)
        let migratedMarker = try await database.relationshipIndexVersion()
        XCTAssertEqual(migratedMarker, CapabilityCompanionIndex.currentVersion)

        // A second directory refresh observes the current derived marker and
        // must not schedule another source migration.
        try await model.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.snapshot().count, 1)
    }

    func testLegacyV1RelationshipMarkerTriggersCompatibilityRefreshBeforeWritingV2() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-companion-v1-migration-\(UUID().uuidString).sqlite")
        )
        try await database.replaceResourceInventory(resources: [resource("agent:legacy", "Legacy Agent", project: nil)])
        try await database.markSuccessfulSourceIndex(
            at: now.addingTimeInterval(-60),
            relationshipIndexVersion: "capability-companions.v1"
        )
        let initialLegacyMarker = try await database.relationshipIndexVersion()
        XCTAssertEqual(initialLegacyMarker, "capability-companions.v1")

        let probe = MigrationProbe()
        let source = IndexingCoordinator(store: database)
        let coordinator = RefreshCoordinator(
            initialGrace: 0,
            timeout: 0,
            sourceOperation: { request in
                probe.append(request)
                try await database.markSuccessfulSourceIndex(
                    at: now,
                    relationshipIndexVersion: CapabilityCompanionIndex.currentVersion
                )
                return .succeeded(now)
            },
            operation: { _ in .completed }
        )
        let stores = makePreferenceStores()
        let model = DirectorAppModel(
            store: database,
            coordinator: source,
            configuration: .init(scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil),
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { now },
            previewMode: false,
            presentationRefreshCoordinator: coordinator
        )
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.removeWindow(windowID) }

        try await model.refresh()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.snapshot().isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.snapshot().count, 1)
        let migratedMarker = try await database.relationshipIndexVersion()
        XCTAssertEqual(migratedMarker, CapabilityCompanionIndex.currentVersion)
    }

    func testRelationshipMigrationFailureLeavesLegacyMarkerForRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-companion-failed-migration-\(UUID().uuidString).sqlite")
        )
        try await database.replaceResourceInventory(resources: [resource("agent:failed", "Failed Agent", project: nil)])
        try await database.markSuccessfulSourceIndex(
            at: now.addingTimeInterval(-60),
            relationshipIndexVersion: "capability-companions.v1"
        )
        let probe = MigrationProbe()
        let source = IndexingCoordinator(store: database)
        let coordinator = RefreshCoordinator(
            initialGrace: 0,
            timeout: 0,
            sourceOperation: { request in
                probe.append(request)
                throw NSError(domain: "test-migration", code: 1)
            },
            operation: { _ in .completed }
        )
        let stores = makePreferenceStores()
        let model = DirectorAppModel(
            store: database,
            coordinator: source,
            configuration: .init(scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil),
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            nowProvider: { now },
            previewMode: false,
            presentationRefreshCoordinator: coordinator
        )
        let windowID = UUID()
        model.setWindowVisibility(windowID, visible: true)
        defer { model.removeWindow(windowID) }

        try await model.refresh()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while probe.snapshot().isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.snapshot().count, 1)
        let failedMarker = try await database.relationshipIndexVersion()
        XCTAssertEqual(failedMarker, "capability-companions.v1")
    }

    func testRefreshBuildsRealSQLiteHomeAndLibraryProjection() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("director-ui-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore(url: dbURL)
        let shared = resource("agent:shared", "Shared Agent", project: nil)
        let old = resource("agent:old", "Old only", project: nil)
        let unusedProject = resource("agent:unused-b", "Unused B Agent", project: "b")
        let projectOnly = resource("agent:only-a", "Only A Agent", project: "a")
        let legacyPlugin = CapabilityResource(id: "plugin:legacy", name: "Legacy Plugin", kind: .plugin, status: .success, scope: .runtime, projectID: nil, confidence: .exact, summary: "Historical plugin", sourceRootID: "runtime-plugins", relativeSourcePath: "plugins/legacy", sourcePathHash: nil, lastSeenAt: now, ownership: .runtime, origin: .runtime)
        let legacySkill = CapabilityResource(id: "skill:legacy-child", name: "Legacy Child", kind: .skill, status: .success, scope: .runtime, projectID: nil, confidence: .exact, summary: "Plugin child", sourceRootID: "runtime-plugins:legacy", relativeSourcePath: "plugins/legacy/skills/child/SKILL.md", sourcePathHash: nil, lastSeenAt: now, ownership: .pluginProvided, origin: .plugin)
        let unsupportedPlugin = CapabilityResource(id: "plugin:unsupported", name: "Unsupported Plugin", kind: .plugin, status: .success, scope: .runtime, projectID: nil, confidence: .exact, summary: "No current attribution", sourceRootID: "runtime-plugins", relativeSourcePath: "plugins/unsupported", sourcePathHash: nil, lastSeenAt: now, ownership: .runtime, origin: .runtime)
        let resources = [shared, old, unusedProject, projectOnly]
        try await store.replaceResourceInventory(resources: resources + [legacyPlugin, legacySkill, unsupportedPlugin], projects: [CapabilityProject(id: "a", name: "Project A"), CapabilityProject(id: "b", name: "Project B")], relations: [ResourceRelation(sourceResourceID: legacyPlugin.id, targetResourceID: legacySkill.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)])

        // One stable global Agent appears in three A calls, one B call, and
        // one unassociated call. The old-only record is outside recent7.
        let records: [(String, String?, Date, String)] = [
            ("a-1", "a", now.addingTimeInterval(-60), shared.id),
            ("a-2", "a", now.addingTimeInterval(-120), shared.id),
            ("a-3", "a", now.addingTimeInterval(-180), shared.id),
            ("b-1", "b", now.addingTimeInterval(-240), shared.id),
            ("unknown-1", nil, now.addingTimeInterval(-300), shared.id),
            ("old-1", "a", now.addingTimeInterval(-8 * 86_400), old.id),
        ]
        for (id, project, timestamp, resourceID) in records {
            let session = TaskSummary(id: "session:\(id)-\(UUID().uuidString)", projectID: project, startedAt: timestamp, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "file:\(id)-\(UUID().uuidString)", title: nil)
            let call = InvocationEvent(id: "call:\(id)-\(UUID().uuidString)", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: timestamp, actorName: "agent", resourceID: resourceID, kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
            try await store.replaceSession(PersistedSessionBatch(session: session, calls: [call], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        }
        for (id, project, timestamp) in [("legacy-a", "a", now.addingTimeInterval(-8 * 86_400)), ("legacy-b", "b", now.addingTimeInterval(-9 * 86_400))] {
            let session = TaskSummary(id: "session:\(id)-\(UUID().uuidString)", projectID: project, startedAt: timestamp, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "file:\(id)-\(UUID().uuidString)", title: nil)
            let call = InvocationEvent(id: "call:\(id)-\(UUID().uuidString)", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: timestamp, actorName: "legacy-child", resourceID: legacySkill.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
            try await store.replaceSession(PersistedSessionBatch(session: session, calls: [call], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        }
        // A raw plugin-parent wrapper is newer than the attributed child
        // calls, but must not pollute plugin history or project membership.
        for (id, project, resourceID, timestamp) in [
            ("legacy-parent", "a", legacyPlugin.id, now.addingTimeInterval(-86_400)),
            ("unsupported-parent", "b", unsupportedPlugin.id, now.addingTimeInterval(-86_400))
        ] {
            let session = TaskSummary(id: "session:\(id)-\(UUID().uuidString)", projectID: project, startedAt: timestamp, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "file:\(id)-\(UUID().uuidString)", title: nil)
            let call = InvocationEvent(id: "call:\(id)-\(UUID().uuidString)", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: timestamp, actorName: "plugin-wrapper", resourceID: resourceID, kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
            try await store.replaceSession(PersistedSessionBatch(session: session, calls: [call], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        }
        let prefs = makePreferenceStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.0, evaluationStore: prefs.1, nowProvider: { now })
        try await model.refresh()
        let home = HomeOverviewModel(catalog: CapabilityCatalog(resources: resources), usage: model.recentCapabilityStats)
        XCTAssertEqual(home.inventory.customAgents, 4)
        let library = try XCTUnwrap(model.libraryModels.first)
        XCTAssertEqual(library.rows.first(where: { $0.id == shared.id })?.recent7Count, 5)
        XCTAssertEqual(library.rows.first(where: { $0.id == old.id })?.recent7Count, 0)
        XCTAssertEqual(library.rows.first(where: { $0.id == shared.id })?.lastUsedAt, now.addingTimeInterval(-60))

        let recentWindow = CapabilityQueryWindow.recent7(now: now, calendar: model.statisticsCalendar)
        let usageA = try await store.fetchCapabilityUsageStats(window: recentWindow, projectID: "a")
        let usageB = try await store.fetchCapabilityUsageStats(window: recentWindow, projectID: "b")
        let usageAll = try await store.fetchCapabilityUsageStats(window: recentWindow)
        let historyA = try await store.fetchCapabilityHistory(projectID: "a", through: now)
        XCTAssertEqual(usageA.first { $0.resourceID == shared.id }?.callCount, 3)
        XCTAssertEqual(usageB.first { $0.resourceID == shared.id }?.callCount, 1)
        XCTAssertEqual(usageAll.first { $0.resourceID == shared.id }?.callCount, 5)
        XCTAssertEqual(historyA.first { $0.resourceID == old.id }?.callCount, 1)
        XCTAssertEqual(model.libraryModels.first?.usageProjects[shared.id], Set(["a", "b"]))

        library.context = .init(scope: .allProjects, search: "", sort: .recentUsageDescending)
        await model.reloadLibrary(.customAgents, scope: .allProjects)
        XCTAssertTrue(library.rows.contains { $0.id == unusedProject.id })
        library.context = .init(scope: .project("a"), search: "Shared", sort: .nameAscending)
        library.selectedID = shared.id
        let language = AppLanguageStore(memoryLanguage: .simplifiedChinese)
        language.setLanguage(.english)
        language.setLanguage(.simplifiedChinese)
        try await model.refresh()
        XCTAssertEqual(library.context, .init(scope: .project("a"), search: "Shared", sort: .nameAscending))
        XCTAssertEqual(library.selectedID, shared.id)
        XCTAssertEqual(library.rows.map(\.id), [shared.id])

        let pluginLibrary = try XCTUnwrap(model.libraryModels.first { $0.category == .installedPlugins })
        let pluginRow = try XCTUnwrap(pluginLibrary.rows.first { $0.id == legacyPlugin.id })
        XCTAssertEqual(pluginRow.recent7Count, 0)
        XCTAssertEqual(pluginRow.lastUsedAt, now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(pluginLibrary.usageProjects[legacyPlugin.id], Set(["a", "b"]))
        let unsupportedRow = try XCTUnwrap(pluginLibrary.rows.first { $0.id == unsupportedPlugin.id })
        XCTAssertNil(unsupportedRow.recent7Count)
        XCTAssertNil(unsupportedRow.lastUsedAt)
        XCTAssertTrue(pluginLibrary.usageProjects[unsupportedPlugin.id, default: []].isEmpty)
        pluginLibrary.context = .init(scope: .project("a"), search: "", sort: .recentUsageDescending)
        await model.reloadLibrary(.installedPlugins, scope: .project("a"))
        XCTAssertEqual(pluginLibrary.rows.first { $0.id == legacyPlugin.id }?.recent7Count, 0)
        XCTAssertEqual(pluginLibrary.rows.first { $0.id == legacyPlugin.id }?.lastUsedAt, now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(pluginLibrary.usageProjects[legacyPlugin.id], Set(["a", "b"]))
        XCTAssertTrue(pluginLibrary.usageProjects[unsupportedPlugin.id, default: []].isEmpty)
        let scopedPluginStats = pluginLibrary.browsePluginStats
        try await model.refresh()
        XCTAssertEqual(pluginLibrary.browsePluginStats, scopedPluginStats)
        XCTAssertEqual(pluginLibrary.usageProjects[legacyPlugin.id], Set(["a", "b"]))
        XCTAssertTrue(pluginLibrary.usageProjects[unsupportedPlugin.id, default: []].isEmpty)
    }

    func testBrowseContextAndSelectionAreStableAcrossRefresh() async throws {
        let prefs = makePreferenceStores()
        let model = DirectorAppModel(classificationOverrides: prefs.0, evaluationStore: prefs.1)
        let library = try XCTUnwrap(model.libraryModels.first)
        library.context = .init(scope: .project("p"), search: "needle", sort: .nameAscending)
        library.selectedID = "stable"
        XCTAssertEqual(library.context.scope, .project("p")); XCTAssertEqual(library.selectedID, "stable")
    }

    func testCapabilityFolderNamesIncludeVisibleDefaultsAndProjects() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-folder-names-\(UUID().uuidString).sqlite")
        )
        let global = resource("agent:visible-global", "Visible Global", project: nil)
        let project = resource("skill:visible-project", "Visible Project", project: "project-a")
        try await database.replaceResourceInventory(
            resources: [global, project],
            projects: [CapabilityProject(id: "project-a", name: "Portfolio")],
            relations: []
        )
        let prefs = makePreferenceStores()
        let folderStore = CapabilityFolderStore(memoryPreferences: .initial())
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: prefs.0,
            evaluationStore: prefs.1,
            nowProvider: { now },
            capabilityFolderStore: folderStore
        )
        try await model.refresh()

        XCTAssertTrue(model.capabilityFolders.folders.contains { $0.source == .project && $0.projectName == "Portfolio" })
        XCTAssertTrue(
            model.capabilityFolders.members(in: CapabilityFolderDefinition.selfTrainingID).isEmpty,
            "new Self Training folders remain empty until the user imports capabilities"
        )
        XCTAssertNil(folderStore.preferences().selfTrainingSeedVersion)
        XCTAssertThrowsError(try model.createCapabilityFolder(named: "portfolio")) { error in
            XCTAssertEqual(error as? CapabilityFolderStoreError, .duplicateFolderName)
        }
        XCTAssertThrowsError(try model.createCapabilityFolder(named: "GLOBAL")) { error in
            XCTAssertEqual(error as? CapabilityFolderStoreError, .duplicateFolderName)
        }
        XCTAssertThrowsError(try model.createCapabilityFolder(named: "自我训练")) { error in
            XCTAssertEqual(error as? CapabilityFolderStoreError, .duplicateFolderName)
        }
        let research = try model.createCapabilityFolder(named: "Research")
        XCTAssertEqual(
            try model.addCapabilitiesToFolder(resourceIDs: Set([global.id, project.id]), folderID: research.id),
            2
        )
        XCTAssertEqual(Set(model.capabilityFolders.members(in: research.id).map(\.id)), Set([global.id, project.id]))
        XCTAssertThrowsError(
            try model.addCapabilitiesToFolder(resourceIDs: Set([global.id, "agent:missing"]), folderID: research.id)
        ) { error in
            XCTAssertEqual(error as? CapabilityFolderStoreError, .invalidMembership)
        }
        XCTAssertEqual(
            Set(model.capabilityFolders.members(in: research.id).map(\.id)),
            Set([global.id, project.id]),
            "an invalid batch must not partially change folder membership"
        )

        model.setCapabilityFolderMembership(
            resourceID: project.id,
            folderID: CapabilityFolderDefinition.selfTrainingID,
            included: false
        )
        try await model.refresh()
        XCTAssertFalse(
            model.capabilityFolders.members(in: CapabilityFolderDefinition.selfTrainingID).contains { $0.id == project.id },
            "refresh must not add capabilities to Self Training implicitly"
        )
    }

    func testCapabilityFolderRefreshPreservesPreExistingSelfTrainingMemberships() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-folder-preserve-\(UUID().uuidString).sqlite")
        )
        let global = resource("agent:preserved-global", "Preserved Global", project: nil)
        let project = resource("skill:preserved-project", "Preserved Project", project: "project-a")
        try await database.replaceResourceInventory(
            resources: [global, project],
            projects: [CapabilityProject(id: "project-a", name: "Portfolio")],
            relations: []
        )

        let prefs = makePreferenceStores()
        let existingPreferences = CapabilityFolderPreferencesV1(
            customFolders: [.init(id: CapabilityFolderDefinition.selfTrainingID, source: .selfTraining)],
            memberships: [.init(folderID: CapabilityFolderDefinition.selfTrainingID, resourceID: global.id)]
        )
        let folderStore = CapabilityFolderStore(memoryPreferences: existingPreferences)
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: prefs.0,
            evaluationStore: prefs.1,
            nowProvider: { now },
            capabilityFolderStore: folderStore
        )

        try await model.refresh()
        XCTAssertEqual(
            model.capabilityFolders.members(in: CapabilityFolderDefinition.selfTrainingID).map(\.id),
            [global.id]
        )
        try await model.refresh()
        XCTAssertEqual(
            model.capabilityFolders.members(in: CapabilityFolderDefinition.selfTrainingID).map(\.id),
            [global.id],
            "refresh and upgrade paths must preserve saved memberships without reseeding"
        )
        XCTAssertFalse(model.capabilityFolders.members(in: CapabilityFolderDefinition.selfTrainingID).contains { $0.id == project.id })
    }

    func testAppModelPublishesBatchCompanionUsageFromIndexedInvocationsAndInvalidatesOnRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-companion-batch-\(UUID().uuidString).sqlite")
        )
        let agent = CapabilityResource(id: "agent:batch", name: "Batch Agent", kind: .agent, status: .success, scope: .global, projectID: nil, confidence: .exact, summary: "Agent", sourceRootID: "test", relativeSourcePath: "batch.toml", sourcePathHash: nil, lastSeenAt: now, ownership: .userOwned, origin: .local)
        let skill = CapabilityResource(id: "skill:batch", name: "batch-skill", kind: .skill, status: .success, scope: .global, projectID: nil, confidence: .exact, summary: "Skill", sourceRootID: "test", relativeSourcePath: "batch/SKILL.md", sourcePathHash: nil, lastSeenAt: now, ownership: .userOwned, origin: .local)
        let relation = ResourceRelation(sourceResourceID: agent.id, targetResourceID: skill.id, relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue)
        try await database.replaceResourceInventory(resources: [agent, skill], relations: [relation])

        func session(_ id: String, offset: TimeInterval) -> PersistedSessionBatch {
            let task = TaskSummary(id: id, projectID: nil, startedAt: now.addingTimeInterval(offset), endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: id, title: nil)
            let agentCall = InvocationEvent(id: "\(id)-agent", sessionID: id, parentCallID: nil, ordinal: 0, timestamp: task.startedAt, actorName: nil, resourceID: agent.id, kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
            let skillCall = InvocationEvent(id: "\(id)-skill", sessionID: id, parentCallID: nil, ordinal: 1, timestamp: task.startedAt, actorName: nil, resourceID: skill.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
            return PersistedSessionBatch(session: task, calls: [agentCall, skillCall], tokenSnapshots: [], quotaSnapshots: [], findings: [])
        }
        try await database.replaceSession(session("session:one", offset: -60))
        let stores = makePreferenceStores()
        let model = DirectorAppModel(store: database, classificationOverrides: stores.0, evaluationStore: stores.1, nowProvider: { now })
        try await model.refresh()
        XCTAssertEqual(model.capabilityCompanionUsageByRelationID[CapabilityCompanionRelation(agentID: agent.id, skillID: skill.id, declarationSource: .agentBrief).id]?.sessionCount, 1)

        try await database.replaceSession(session("session:two", offset: -120))
        try await model.refresh()
        XCTAssertEqual(model.capabilityCompanionUsageByRelationID[CapabilityCompanionRelation(agentID: agent.id, skillID: skill.id, declarationSource: .agentBrief).id]?.sessionCount, 2)
    }

    func testCapabilityFolderReorderIgnoresStaleDropIndexesAndDerivedIDs() throws {
        let prefs = makePreferenceStores()
        let store = CapabilityFolderStore(memoryPreferences: .initial())
        let model = DirectorAppModel(
            classificationOverrides: prefs.0,
            evaluationStore: prefs.1,
            capabilityFolderStore: store
        )
        _ = try model.createCapabilityFolder(named: "One")
        _ = try model.createCapabilityFolder(named: "Two")
        let before = model.capabilityFolders.folders.filter(\.isCustom).map(\.id)

        model.reorderCapabilityFolders(fromOffsets: IndexSet(integer: 999), toOffset: 0)
        model.reorderCapabilityFolders(fromOffsets: IndexSet(integer: 0), toOffset: 999)
        model.moveCapabilityFolder(id: CapabilityFolderDefinition.globalID, direction: .up)

        XCTAssertEqual(model.capabilityFolders.folders.filter(\.isCustom).map(\.id), before)
    }

    func testClassificationUsesMemoryStoreWithoutTouchingProductionFiles() {
        let prefs = makePreferenceStores()
        let model = DirectorAppModel(classificationOverrides: prefs.0, evaluationStore: prefs.1)
        let baseline = model.capabilities.allRows.first { $0.id == "skill:video-cover-studio" }!.resource
        model.classify(resourceID: "skill:video-cover-studio", ownership: .installed)
        XCTAssertNotNil(model.classificationOverrides.all()["skill:video-cover-studio"])
        model.resetClassification(resourceID: "skill:video-cover-studio")
        XCTAssertEqual(model.capabilities.allRows.first { $0.id == baseline.id }?.resource, baseline)
    }

    func testInstalledUnknownSkillCanBeCorrectedToCustomAndReset() async throws {
        let database = try DatabaseStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("director-binary-classification-\(UUID().uuidString).sqlite")
        )
        let resource = CapabilityResource(
            id: "skill:installed-unknown",
            name: "Installed Unknown",
            kind: .skill,
            status: .unknown,
            scope: .global,
            projectID: nil,
            confidence: .inferred,
            summary: nil,
            sourceRootID: "global-skills",
            relativeSourcePath: "installed-unknown/SKILL.md",
            sourcePathHash: nil,
            lastSeenAt: Date(),
            ownership: .installed,
            origin: .unknown,
            classificationConfidence: .inferred
        )
        try await database.insertResources([resource])
        let prefs = makePreferenceStores()
        let model = DirectorAppModel(store: database, classificationOverrides: prefs.0, evaluationStore: prefs.1)
        try await model.refresh()

        model.classify(resourceID: resource.id, ownership: .userOwned)
        let corrected = try XCTUnwrap(model.capabilities.allRows.first { $0.id == resource.id }?.resource)
        XCTAssertEqual(corrected.ownership, .userOwned)
        XCTAssertEqual(corrected.origin, .local)
        XCTAssertEqual(corrected.classificationConfidence, .exact)
        XCTAssertEqual(model.classificationOverrides.all()[resource.id]?.origin, .local)

        model.resetClassification(resourceID: resource.id)
        let reset = try XCTUnwrap(model.capabilities.allRows.first { $0.id == resource.id }?.resource)
        XCTAssertEqual(reset.ownership, .installed)
        XCTAssertEqual(reset.origin, .unknown)
        XCTAssertEqual(reset.classificationConfidence, .inferred)
    }

    func testResetAfterRestartUsesAutomaticProvenanceBaseline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-classification-restart-\(UUID().uuidString)", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        let skill = skills.appendingPathComponent("restart-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: restart-skill\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let scanRoot = ScanRoot(id: "global-skills", url: skills, scope: .global, kind: .skills)
        let baseline = try XCTUnwrap(ResourceScanner(roots: [scanRoot]).scan().resources.first)
        let correction = ResourceClassificationOverride(ownership: .userOwned, origin: .local)
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        _ = try await IndexingCoordinator(store: database).run(configuration: .init(
            scanRoots: [scanRoot],
            activeSessionRoots: [],
            archivedSessionRoot: nil,
            classificationOverrides: [baseline.id: correction]
        ))
        let prefs = makePreferenceStores()
        prefs.0.set(correction, for: baseline.id)

        let relaunched = DirectorAppModel(store: database, classificationOverrides: prefs.0, evaluationStore: prefs.1)
        try await relaunched.refresh()
        XCTAssertEqual(relaunched.capabilities.allRows.first?.resource.ownership, .userOwned)

        relaunched.resetClassification(resourceID: baseline.id)
        let reset = try XCTUnwrap(relaunched.capabilities.allRows.first?.resource)
        XCTAssertEqual(reset.ownership, .installed)
        XCTAssertEqual(reset.origin, .unknown)
        XCTAssertEqual(reset.classificationConfidence, .inferred)
        XCTAssertNil(relaunched.classificationOverrides.all()[baseline.id])
    }

    func testMidnightStatisticsRefreshDoesNotIndexAndDeleteKeepsMemoryJudgment() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let clock = TestClock(now)
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("director-ui-\(UUID().uuidString).sqlite")
        let store = try DatabaseStore(url: dbURL)
        let skill = CapabilityResource(id: "skill:judged", name: "Judged Skill", kind: .skill, status: .success, scope: .global, projectID: nil, confidence: .exact, summary: "Purpose", sourceRootID: "test", relativeSourcePath: "judged/SKILL.md", sourcePathHash: nil, lastSeenAt: now, ownership: .userOwned, origin: .local)
        try await store.insertResources([skill])
        let session = TaskSummary(id: "session:judged", projectID: nil, startedAt: now, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "file:judged", title: nil)
        let event = InvocationEvent(id: "call:judged", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: now, actorName: "skill", resourceID: skill.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [event], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let prefs = makePreferenceStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.0, evaluationStore: prefs.1, nowProvider: { clock.now })
        try await model.refresh()
        model.setEvaluation(for: event, label: .effective, updatedAt: now)
        XCTAssertEqual(model.capabilities.allRows.first { $0.id == skill.id }?.evaluatedCount, 1)

        clock.set(now.addingTimeInterval(86_400))
        await model.refreshStatisticsIfNeeded()
        XCTAssertFalse(model.isIndexing)
        let persistedCallCount = try await store.count("calls")
        XCTAssertEqual(persistedCallCount, 1)
        XCTAssertEqual(model.evaluationStore.evaluation(for: event.id)?.label, .effective)

        try await model.deleteDerivedData()
        XCTAssertEqual(model.evaluationStore.evaluation(for: event.id)?.label, .effective)
    }

    private func resource(_ id: String, _ name: String, project: String?) -> CapabilityResource {
        CapabilityResource(id: id, name: name, kind: .agent, status: .success, scope: project == nil ? .global : .project, projectID: project, confidence: .exact, summary: "Purpose", sourceRootID: "test", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: Date(), ownership: .userOwned, origin: .local)
    }
}
