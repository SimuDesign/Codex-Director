import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class AppModelLibraryIntegrationTests: XCTestCase {
    private final class MemoryData {
        var value: Data?
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
