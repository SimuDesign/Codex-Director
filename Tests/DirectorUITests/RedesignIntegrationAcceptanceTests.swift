import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

/// Independent integration acceptance for the approved 0.2 capability-centered
/// contract. These tests use disposable SQLite and in-memory preference seams;
/// they do not use the Debug validation host or production UserDefaults.
@MainActor
final class RedesignIntegrationAcceptanceTests: XCTestCase {
    private final class MemoryBlob: @unchecked Sendable {
        var data: Data?
    }

    private struct Fixture {
        let resources: [CapabilityResource]
        let projects: [CapabilityProject]
        let batches: [PersistedSessionBatch]
        let sharedID = "agent:shared"
        let oldID = "agent:old-only"
        let projectOnlyID = "agent:unused-project"
        let skillID = "skill:local"
    }

    func testRealSQLiteProjectUsageAndInclusiveWindow() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = validationCalendar
        let fixture = makeFixture(now: now, calendar: calendar)
        try await seed(fixture, into: store)

        let window = CapabilityQueryWindow.recent7(now: now, calendar: calendar)
        let global = try await store.fetchCapabilityUsageStats(window: window)
        XCTAssertEqual(global.first { $0.resourceID == fixture.sharedID }?.callCount, 5)
        XCTAssertFalse(global.contains { $0.resourceID == fixture.oldID }, "historical-only usage must not enter recent seven-day stats")

        let a = try await store.fetchCapabilityUsageStats(window: window, projectID: "project:a")
        let b = try await store.fetchCapabilityUsageStats(window: window, projectID: "project:b")
        XCTAssertEqual(a.first { $0.resourceID == fixture.sharedID }?.callCount, 3)
        XCTAssertEqual(b.first { $0.resourceID == fixture.sharedID }?.callCount, 1)
        XCTAssertFalse(a.contains { $0.resourceID == "agent:unassociated" }, "unassociated calls must not enter a concrete project")

        let historyA = try await store.fetchCapabilityHistory(projectID: "project:a", through: now)
        XCTAssertEqual(historyA.first { $0.resourceID == fixture.sharedID }?.callCount, 3)
        XCTAssertEqual(historyA.first { $0.resourceID == fixture.oldID }?.callCount, 1)

        let boundaryCalls = try await store.fetchCapabilityInvocations(
            resourceID: fixture.sharedID,
            projectID: "project:a",
            window: window,
            pageSize: 20
        )
        XCTAssertEqual(boundaryCalls.items.count, 3, "start and end are inclusive: A has calls at the window start")
        XCTAssertTrue(boundaryCalls.items.contains { $0.timestamp == window.start })
    }

    func testRealAppModelRefreshPreservesBrowseSelectionAndLanguageState() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = makeFixture(now: now, calendar: validationCalendar)
        try await seed(fixture, into: store)
        let prefs = makeMemoryStores()
        let model = DirectorAppModel(
            store: store,
            classificationOverrides: prefs.classifications,
            evaluationStore: prefs.evaluations,
            nowProvider: { now },
            calendar: validationCalendar
        )
        try await model.refresh()

        let library = try XCTUnwrap(model.libraryModels.first { $0.category == .customAgents })
        XCTAssertEqual(library.categoryCount, 5, "category totals are resource counts, including unused project capabilities")
        library.context = .init(scope: .allProjects, search: "Unused", sort: .nameAscending)
        XCTAssertTrue(library.rows.contains { $0.id == "agent:unused-project" }, "project configuration overview includes unused project capabilities")
        library.context = .init(scope: .project("project:a"), search: "Shared", sort: .nameAscending)
        library.selectedID = fixture.sharedID
        try await model.refresh()
        XCTAssertEqual(library.context, .init(scope: .project("project:a"), search: "Shared", sort: .nameAscending))
        XCTAssertEqual(library.selectedID, fixture.sharedID)
        XCTAssertEqual(library.rows.first?.recent7Count, 3)

        let language = AppLanguageStore(memoryLanguage: .simplifiedChinese)
        XCTAssertEqual(language.language, .simplifiedChinese)
        language.setLanguage(.english)
        XCTAssertEqual(language.language, .english)
        language.setLanguage(.simplifiedChinese)
        XCTAssertEqual(language.language, .simplifiedChinese)
        XCTAssertEqual(library.context.search, "Shared", "language changes must not recreate or clear browse state")
        XCTAssertEqual(library.selectedID, fixture.sharedID)
    }

    func testEvaluationSurvivesDerivedDeleteAndRefreshWithMemoryStore() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = makeFixture(now: now, calendar: validationCalendar)
        try await seed(fixture, into: store)
        let prefs = makeMemoryStores()
        let model = DirectorAppModel(
            store: store,
            classificationOverrides: prefs.classifications,
            evaluationStore: prefs.evaluations,
            nowProvider: { now },
            calendar: validationCalendar
        )
        try await model.refresh()
        let event = try XCTUnwrap(fixture.batches.first?.calls.first { $0.resourceID == fixture.sharedID })
        model.setEvaluation(for: event, label: .effective, updatedAt: now)
        XCTAssertEqual(prefs.evaluations.evaluation(for: event.id)?.label, .effective)

        try await model.deleteDerivedData()
        let resourcesAfterDelete = try await store.count("resources")
        let callsAfterDelete = try await store.count("calls")
        XCTAssertEqual(resourcesAfterDelete, 0)
        XCTAssertEqual(callsAfterDelete, 0)
        XCTAssertEqual(prefs.evaluations.evaluation(for: event.id)?.label, .effective)

        try await seed(fixture, into: store)
        try await model.refresh()
        let row = try XCTUnwrap(model.capabilities.allRows.first { $0.id == fixture.sharedID })
        XCTAssertEqual(row.evaluatedCount, 1)
        XCTAssertEqual(row.effectiveCount, 1)
        XCTAssertEqual(model.evaluationStore.evaluation(for: event.id)?.label, .effective)
    }

    func testLocalSkillClassificationImmediatelyUpdatesCategoryAndReset() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = makeFixture(now: now, calendar: validationCalendar)
        try await seed(fixture, into: store)
        let prefs = makeMemoryStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.classifications, evaluationStore: prefs.evaluations, nowProvider: { now }, calendar: validationCalendar)
        try await model.refresh()
        let custom = try XCTUnwrap(model.libraryModels.first { $0.category == .customSkills })
        let installed = try XCTUnwrap(model.libraryModels.first { $0.category == .installedSkills })
        XCTAssertEqual(custom.categoryCount, 1)
        XCTAssertEqual(installed.categoryCount, 0)

        model.classify(resourceID: fixture.skillID, ownership: .installed)
        XCTAssertEqual(custom.categoryCount, 0)
        XCTAssertEqual(installed.categoryCount, 1)
        XCTAssertEqual(prefs.classifications.all()[fixture.skillID]?.ownership, .installed)

        model.resetClassification(resourceID: fixture.skillID)
        XCTAssertEqual(custom.categoryCount, 1)
        XCTAssertEqual(installed.categoryCount, 0)
        XCTAssertTrue(prefs.classifications.all().isEmpty)
    }

    func testClockAdvancingToNextLocalDayDropsOldBoundaryWithoutIndexing() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let calendar = validationCalendar
        let fixture = makeFixture(now: clock.now, calendar: calendar)
        try await seed(fixture, into: store)
        let prefs = makeMemoryStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.classifications, evaluationStore: prefs.evaluations, nowProvider: { clock.now }, calendar: calendar)
        let visibleWindowID = UUID()
        model.setWindowVisibility(visibleWindowID, visible: true)
        defer { model.removeWindow(visibleWindowID) }
        await model.refreshStatisticsIfNeeded(now: clock.now)
        XCTAssertEqual(model.recentCapabilityStats.first { $0.resourceID == fixture.sharedID }?.callCount, 5)

        clock.set(calendar.date(byAdding: .day, value: 1, to: clock.now)!)
        await model.refreshStatisticsIfNeeded(now: clock.now)
        XCTAssertEqual(model.recentCapabilityStats.first { $0.resourceID == fixture.sharedID }?.callCount, 2, "the three calls on the old local-day boundary leave the seven-day window after midnight")
        XCTAssertEqual(model.indexingProgress.phase, .idle)
    }

    func testRecentSevenUsesLocalGregorianDaysAcrossNewYorkDSTAndShanghai() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = ISO8601DateFormatter().date(from: "2026-03-10T16:00:00Z")!
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let nyWindow = CapabilityQueryWindow.recent7(now: now, calendar: newYork)
        let shWindow = CapabilityQueryWindow.recent7(now: now, calendar: shanghai)

        XCTAssertEqual(nyWindow.start, newYork.date(byAdding: .day, value: -6, to: newYork.startOfDay(for: now)))
        XCTAssertEqual(shWindow.start, shanghai.date(byAdding: .day, value: -6, to: shanghai.startOfDay(for: now)))
        XCTAssertEqual(nyWindow.end, now)
        XCTAssertEqual(shWindow.end, now)
        let nyDuration = nyWindow.end.timeIntervalSince(nyWindow.start)
        let shDuration = shWindow.end.timeIntervalSince(shWindow.start)
        XCTAssertEqual(shDuration, 6 * 86_400, accuracy: 0.001)
        XCTAssertEqual(nyDuration, 6 * 86_400 + 12 * 3_600 - 3_600, accuracy: 0.001, "New York's spring-forward day shortens its local-midnight-to-noon elapsed span by one hour")

        let nyResource = resource(id: "agent:timezone-ny", name: "New York", kind: .agent, scope: .global)
        let shResource = resource(id: "agent:timezone-sh", name: "Shanghai", kind: .agent, scope: .global)
        try await store.replaceResourceInventory(resources: [nyResource, shResource])
        let records: [(String, CapabilityQueryWindow, CapabilityResource)] = [("ny", nyWindow, nyResource), ("sh", shWindow, shResource)]
        for (prefix, window, capability) in records {
            let timestamps = [window.start.addingTimeInterval(-1), window.start, now]
            for (index, timestamp) in timestamps.enumerated() {
                let sessionID = "session:tz-\(prefix)-\(index)"
                let session = TaskSummary(id: sessionID, projectID: nil, startedAt: timestamp, endedAt: timestamp, status: .completed, coverage: .complete, parserVersion: "acceptance", sourceFileID: "file:\(sessionID)", title: nil)
                let event = call(id: "call:tz-\(prefix)-\(index)", sessionID: sessionID, resourceID: capability.id, timestamp: timestamp)
                try await store.replaceSession(PersistedSessionBatch(session: session, calls: [event], tokenSnapshots: [], quotaSnapshots: [], findings: []))
            }
        }
        let nyStats = try await store.fetchCapabilityUsageStats(window: nyWindow)
        let shStats = try await store.fetchCapabilityUsageStats(window: shWindow)
        XCTAssertEqual(nyStats.first { $0.resourceID == nyResource.id }?.callCount, 2)
        XCTAssertEqual(shStats.first { $0.resourceID == shResource.id }?.callCount, 2)
        let nyEvidence = try await store.fetchCapabilityInvocations(resourceID: nyResource.id, window: nyWindow, pageSize: 10)
        XCTAssertEqual(Set(nyEvidence.items.compactMap(\.timestamp)), Set([nyWindow.start, now]))
    }

    func testPluginCountsKeepUnknownAttributionAsNilAndExcludeOldCache() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plugin = resource(id: "plugin:current", name: "Current", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let disabled = resource(id: "plugin:disabled", name: "Disabled", kind: .plugin, scope: .runtime, status: .blocked, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let unsupported = resource(id: "plugin:unsupported", name: "Unsupported", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let cache = resource(id: "plugin:cache", name: "Old Cache", kind: .plugin, scope: .plugin, ownership: .pluginProvided, origin: .plugin, sourceRootID: "last-known-runtime")
        let child = resource(id: "skill:plugin-child", name: "plugin-child", kind: .skill, scope: .runtime, ownership: .pluginProvided, origin: .plugin, sourceRootID: "runtime-plugins")
        let relation = ResourceRelation(sourceResourceID: plugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let session = TaskSummary(id: "session:plugin", projectID: "project:a", startedAt: now, endedAt: now, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "file:plugin", title: nil)
        let rawParent = InvocationEvent(id: "call:plugin-parent", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: now.addingTimeInterval(-1), actorName: nil, resourceID: plugin.id, kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let call = InvocationEvent(id: "call:plugin-child", sessionID: session.id, parentCallID: rawParent.id, ordinal: 1, timestamp: now, actorName: nil, resourceID: child.id, kind: .skill, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil)
        try await store.replaceResourceInventory(resources: [plugin, disabled, unsupported, cache, child], relations: [relation])
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [rawParent, call], tokenSnapshots: [], quotaSnapshots: [], findings: []))

        let window = CapabilityQueryWindow(start: now.addingTimeInterval(-60), end: now, timeZone: validationCalendar.timeZone)
        let stats = try await store.fetchPluginUsageStats(window: window)
        XCTAssertEqual(stats.first { $0.pluginID == plugin.id }?.callCount, 1)
        XCTAssertEqual(stats.first { $0.pluginID == plugin.id }?.inferredCount, 1, "inferred child evidence must not be masked by a raw parent wrapper")
        XCTAssertEqual(stats.first { $0.pluginID == plugin.id }?.projectIDs, ["project:a"])
        XCTAssertEqual(stats.first { $0.pluginID == plugin.id }?.lastUsedAt, now)
        XCTAssertNil(stats.first { $0.pluginID == disabled.id }?.callCount)
        let unsupportedStats = try XCTUnwrap(stats.first { $0.pluginID == unsupported.id })
        XCTAssertNil(unsupportedStats.callCount, "unsupported plugins must not be represented as zero use")
        XCTAssertNil(unsupportedStats.lastUsedAt)
        XCTAssertTrue(unsupportedStats.projectIDs.isEmpty)
        XCTAssertEqual(unsupportedStats.inferredCount, 0)
        XCTAssertEqual(unsupportedStats.coverage, .unknown)
        XCTAssertFalse(stats.contains { $0.pluginID == cache.id }, "last-known cache packages are not current installed plugins")
        let detail = try await store.fetchPluginInvocations(pluginID: plugin.id, window: window, pageSize: 10)
        XCTAssertEqual(detail.items.map { $0.original.id }, [call.id], "raw plugin parent calls are wrappers, not plugin evidence")
        XCTAssertEqual(detail.items.first?.confidence, .inferred)
        XCTAssertEqual(detail.items.first?.projectID, "project:a")
        let catalog = try await store.fetchCapabilityCatalog()
        XCTAssertEqual(catalog.entries.first { $0.resource.id == plugin.id }?.category, .installedPlugins)
        XCTAssertEqual(catalog.entries.first { $0.resource.id == disabled.id }?.category, .installedPlugins)
        XCTAssertEqual(catalog.entries.first { $0.resource.id == unsupported.id }?.category, .installedPlugins)
        XCTAssertEqual(catalog.entries.first { $0.resource.id == child.id }?.category, .installedSkills)
        XCTAssertNil(catalog.entries.first { $0.resource.id == cache.id }?.category)

        let prefs = makeMemoryStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.classifications, evaluationStore: prefs.evaluations, nowProvider: { now }, calendar: validationCalendar)
        try await model.refresh()
        let pluginLibrary = try XCTUnwrap(model.libraryModels.first { $0.category == .installedPlugins })
        let pluginRow = try XCTUnwrap(pluginLibrary.rows.first { $0.id == plugin.id })
        XCTAssertEqual(pluginRow.recent7Count, 1)
        XCTAssertEqual(pluginRow.inferredCount, 1)
        let unsupportedRow = try XCTUnwrap(pluginLibrary.rows.first { $0.id == unsupported.id })
        XCTAssertNil(unsupportedRow.recent7Count)
        XCTAssertTrue(unsupportedRow.attributionUnavailable)
        XCTAssertNil(unsupportedRow.lastUsedAt)
        XCTAssertEqual(unsupportedRow.inferredCount, 0)
        XCTAssertEqual(unsupportedRow.coverage, .unknown)
    }

    func testHistoricalPluginUseKeepsProjectMembershipAndLastUsedDate() async throws {
        let (store, url) = try makeStore()
        defer { DatabaseStore.destroy(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let plugin = resource(id: "plugin:historical", name: "Historical", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let child = resource(id: "skill:historical-child", name: "historical-child", kind: .skill, scope: .runtime, ownership: .pluginProvided, origin: .plugin, sourceRootID: "runtime-plugins")
        let relation = ResourceRelation(sourceResourceID: plugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let session = TaskSummary(id: "session:historical", projectID: "project:a", startedAt: oldDate, endedAt: oldDate, status: .completed, coverage: .complete, parserVersion: "acceptance", sourceFileID: "file:historical", title: nil)
        let call = InvocationEvent(id: "call:historical", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: oldDate, actorName: nil, resourceID: child.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        try await store.replaceResourceInventory(resources: [plugin, child], projects: [CapabilityProject(id: "project:a", name: "Project A")], relations: [relation])
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [call], tokenSnapshots: [], quotaSnapshots: [], findings: []))

        let prefs = makeMemoryStores()
        let model = DirectorAppModel(store: store, classificationOverrides: prefs.classifications, evaluationStore: prefs.evaluations, nowProvider: { now }, calendar: validationCalendar)
        try await model.refresh()
        let library = try XCTUnwrap(model.libraryModels.first { $0.category == .installedPlugins })
        library.context = .init(scope: .project("project:a"), search: "", sort: .nameAscending)
        await model.reloadLibrary(.installedPlugins, scope: library.context.scope)
        let row = try XCTUnwrap(library.rows.first { $0.id == plugin.id }, "all-time plugin history should retain project membership")
        XCTAssertEqual(row.recent7Count, 0)
        XCTAssertEqual(row.lastUsedAt, oldDate, "historical plugin use should remain visible as last use even when recent count is zero")
    }

    func testCoreSymlinkBoundaryNameIdentityAndCurrentCacheRules() throws {
        let root = try temporaryDirectory("scanner-root")
        let outside = try temporaryDirectory("scanner-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let local = root.appendingPathComponent("local-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "---\nname: Local\ndescription: local\n---\n".write(to: local.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let escaped = outside.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        try "---\nname: Escaped\n---\n".write(to: escaped.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: escaped)
        let output = ResourceScanner(roots: [ScanRoot(id: "root", url: root, scope: .global, kind: .skills)]).scan()
        XCTAssertTrue(output.resources.contains { $0.name == "Local" })
        XCTAssertFalse(output.resources.contains { $0.name == "Escaped" })
        XCTAssertTrue(output.issues.contains { $0.message.contains("Symlink escapes approved root") })

        let currentPlugin = resource(id: "plugin:current", name: "same", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let cachePlugin = resource(id: "plugin:cache", name: "same", kind: .plugin, scope: .plugin, ownership: .pluginProvided, origin: .plugin, sourceRootID: "last-known-runtime")
        let catalog = CapabilityCatalog(resources: [currentPlugin, cachePlugin])
        XCTAssertEqual(catalog.entries.first { $0.resource.id == currentPlugin.id }?.category, .installedPlugins)
        XCTAssertNil(catalog.entries.first { $0.resource.id == cachePlugin.id }?.category)
        XCTAssertNotEqual(currentPlugin.id, cachePlugin.id, "stable identity must not collapse different source identities by name")
        let indexerSource = try sourceText("Sources/DirectorCore/Indexing/IndexingCoordinator.swift")
        XCTAssertTrue(indexerSource.contains("canonicalByPhysical"), "runtime/cache reconciliation must compare physical identity")
        XCTAssertTrue(indexerSource.contains("duplicateRuntimeIDs"), "runtime/cache reconciliation must remove duplicate runtime identities")
    }

    func testStaticUIContractsRetainDetailCacheSelectorValueCountsAndDiagnostics() throws {
        let librarySource = try sourceText("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
        XCTAssertTrue(librarySource.contains("@State private var cachedDetail"))
        XCTAssertTrue(librarySource.contains("@State private var cachedDetailKey"))
        XCTAssertTrue(librarySource.contains("refreshDetailIfNeeded"))
        XCTAssertTrue(librarySource.contains("scope = \"project:\\(id)\""))
        XCTAssertTrue(librarySource.contains("accessibilityValue(value)"), "shared menu fields must expose their current selection")
        XCTAssertTrue(librarySource.contains("value: scopeLabel"))
        XCTAssertTrue(librarySource.contains("value: sortLabel"))
        XCTAssertTrue(librarySource.contains("row.attributionUnavailable"), "plugin attribution state must remain explicit")
        XCTAssertTrue(librarySource.contains("copy(\"library.unavailable\", \"Unavailable\")"), "attributed-unavailable counts must remain distinct from pending")

        let settingsSource = try sourceText("Sources/DirectorUI/DataStatus/SettingsView.swift")
        XCTAssertTrue(settingsSource.contains("settings.diagnostics.limitations"))
        XCTAssertTrue(settingsSource.contains("Missing timestamps and unresolved capabilities"))
        XCTAssertTrue(settingsSource.contains("unassociated projects remain in overall totals but not project-specific views"))

        let rootSource = try sourceText("Sources/DirectorUI/AppShell/DirectorRootView.swift")
        XCTAssertTrue(rootSource.contains("AppLanguageStore"))
        XCTAssertTrue(rootSource.contains("SettingsView(model: model)"))
    }

    func testAllStaticCopyHelperKeysExistInBothLocales() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceDirectory = root.appendingPathComponent("Sources/DirectorUI")
        let source = (FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Localization/") && !$0.path.contains("/Validation/") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let expression = try NSRegularExpression(pattern: #"\bcopy\(\"([^\"]+)\""#)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let keys = Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            let key = String(source[range])
            return key.contains("\\(") ? nil : key
        })
        for language in ["en", "zh-Hans"] {
            let strings = try sourceText("Sources/DirectorUI/Resources/\(language).lproj/Localizable.strings")
            for key in keys {
                XCTAssertTrue(strings.contains("\"\(key)\" ="), "Missing \(language) copy helper key: \(key)")
            }
        }
    }

    private var validationCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar
    }

    private func makeStore() throws -> (DatabaseStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("director-acceptance-\(UUID().uuidString).sqlite")
        return (try DatabaseStore(url: url), url)
    }

    private func makeMemoryStores() -> (classifications: ResourceClassificationOverrideStore, evaluations: InvocationEvaluationStore) {
        let classification = MemoryBlob()
        let evaluation = MemoryBlob()
        return (
            ResourceClassificationOverrideStore(readData: { classification.data }, writeData: { classification.data = $0 }, removeData: { classification.data = nil }),
            InvocationEvaluationStore(readData: { evaluation.data }, writeData: { evaluation.data = $0; return true }, removeData: { evaluation.data = nil; return true })
        )
    }

    private func seed(_ fixture: Fixture, into store: DatabaseStore) async throws {
        try await store.replaceResourceInventory(resources: fixture.resources, projects: fixture.projects)
        for batch in fixture.batches { try await store.replaceSession(batch, resetExisting: true) }
    }

    private func makeFixture(now: Date, calendar: Calendar) -> Fixture {
        let window = CapabilityQueryWindow.recent7(now: now, calendar: calendar)
        let resources = [
            resource(id: "agent:shared", name: "Shared", kind: .agent, scope: .global),
            resource(id: "agent:old-only", name: "Old only", kind: .agent, scope: .global),
            resource(id: "agent:unused-project", name: "Unused project", kind: .agent, scope: .project, projectID: "project:a"),
            resource(id: "agent:project-a", name: "Project A", kind: .agent, scope: .project, projectID: "project:a"),
            resource(id: "agent:project-b", name: "Project B", kind: .agent, scope: .project, projectID: "project:b"),
            resource(id: "skill:local", name: "Local skill", kind: .skill, scope: .global)
        ]
        var batches: [PersistedSessionBatch] = []
        func batch(_ id: String, project: String?, timestamp: Date, calls: [InvocationEvent]) -> PersistedSessionBatch {
            PersistedSessionBatch(session: TaskSummary(id: id, projectID: project, startedAt: timestamp, endedAt: timestamp, status: .completed, coverage: .complete, parserVersion: "acceptance", sourceFileID: "file:\(id)", title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: [])
        }
        for index in 0..<3 {
            let timestamp = window.start.addingTimeInterval(Double(index) * 60)
            batches.append(batch("session:a-\(index)", project: "project:a", timestamp: timestamp, calls: [call(id: "call:a-\(index)", sessionID: "session:a-\(index)", resourceID: "agent:shared", timestamp: timestamp)]))
        }
        batches.append(batch("session:b", project: "project:b", timestamp: now, calls: [call(id: "call:b", sessionID: "session:b", resourceID: "agent:shared", timestamp: now)]))
        batches.append(batch("session:unknown", project: nil, timestamp: now.addingTimeInterval(-120), calls: [call(id: "call:unknown", sessionID: "session:unknown", resourceID: "agent:shared", timestamp: now.addingTimeInterval(-120))]))
        let oldTimestamp = window.start.addingTimeInterval(-8 * 24 * 60 * 60)
        batches.append(batch("session:old", project: "project:a", timestamp: oldTimestamp, calls: [call(id: "call:old", sessionID: "session:old", resourceID: "agent:old-only", timestamp: oldTimestamp)]))
        return Fixture(resources: resources, projects: [CapabilityProject(id: "project:a", name: "Project A"), CapabilityProject(id: "project:b", name: "Project B")], batches: batches)
    }

    private func call(id: String, sessionID: String, resourceID: String, timestamp: Date) -> InvocationEvent {
        InvocationEvent(id: id, sessionID: sessionID, parentCallID: nil, ordinal: 0, timestamp: timestamp, actorName: nil, resourceID: resourceID, kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
    }

    private func resource(id: String, name: String, kind: ResourceKind, scope: ResourceScope, projectID: String? = nil, status: RuntimeStatus = .success, ownership: ResourceOwnership? = nil, origin: ResourceOrigin? = nil, sourceRootID: String = "acceptance") -> CapabilityResource {
        CapabilityResource(id: id, name: name, kind: kind, status: status, scope: scope, projectID: projectID, confidence: .exact, summary: "Acceptance purpose", sourceRootID: sourceRootID, relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000), ownership: ownership, origin: origin)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("director-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
