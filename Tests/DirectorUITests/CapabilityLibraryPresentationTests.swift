import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class CapabilityLibraryPresentationTests: XCTestCase {
    func testSummaryMetricsAreLabeledAndCategorySpecific() {
        let resources = [resource("a", "Agent", .agent, .global, nil, .userOwned), resource("p", "Agent project", .agent, .project, "project", .userOwned)]
        let entries = CapabilityCatalog(resources: resources).entries
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: entries)
        XCTAssertEqual(model.summaryMetrics.map(\.label), ["Global", "Project", "Used in past 7 days"])
        XCTAssertEqual(model.summaryMetrics.map(\.value), [1, 1, 0])
    }

    func testSummaryCardsExposeFourTypedMetricsAndKeepCategoryTotalsStable() {
        let resources = [
            resource("global", "Global Agent", .agent, .global, nil, .userOwned),
            resource("project", "Project Agent", .agent, .project, "project", .userOwned)
        ]
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: CapabilityCatalog(resources: resources).entries)
        model.setData(
            catalog: model.catalog,
            categoryStats: [CapabilityUsageStats(resourceID: "global", callCount: 1, inferredCount: 1, lastUsedAt: Date(), coverage: .complete)],
            browseHistory: [],
            category30DayStats: [],
            browse30DayStats: []
        )
        XCTAssertEqual(model.summaryCards.map(\.kind), [.global, .project, .recent7, .notUsed30])
        XCTAssertEqual(model.summaryCards.map(\.value), [1, 1, 1, 2])
        model.context = CapabilityBrowseContext(search: "Global")
        XCTAssertEqual(model.summaryCards.map(\.value), [1, 1, 1, 2])
        XCTAssertEqual(model.summaryCards.last?.statisticsReady, true)
    }

    func testActivityAndOwnershipFiltersComposeAndSelectedFilterClears() {
        let resources = [
            resource("global", "Global Agent", .agent, .global, nil, .userOwned),
            resource("project", "Project Agent", .agent, .project, "project", .userOwned),
            resource("unused", "Unused Agent", .agent, .global, nil, .userOwned)
        ]
        let entries = CapabilityCatalog(resources: resources).entries
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: entries)
        model.setProjects([CapabilityProject(id: "project", name: "Project")])
        model.setData(
            catalog: entries,
            categoryStats: [CapabilityUsageStats(resourceID: "global", callCount: 1, inferredCount: 1, lastUsedAt: Date(), coverage: .complete), CapabilityUsageStats(resourceID: "project", callCount: 0, inferredCount: 0, lastUsedAt: nil, coverage: .complete)],
            browseHistory: [],
            usageProjects: ["project": ["project"]],
            category30DayStats: [CapabilityUsageStats(resourceID: "global", callCount: 2, inferredCount: 0, lastUsedAt: Date(), coverage: .complete), CapabilityUsageStats(resourceID: "project", callCount: 1, inferredCount: 1, lastUsedAt: Date(), coverage: .complete)],
            browse30DayStats: [CapabilityUsageStats(resourceID: "global", callCount: 2, inferredCount: 0, lastUsedAt: Date(), coverage: .complete), CapabilityUsageStats(resourceID: "project", callCount: 1, inferredCount: 1, lastUsedAt: Date(), coverage: .complete)]
        )
        model.context = CapabilityBrowseContext(scope: .allProjects, activityFilter: .recent7)
        XCTAssertTrue(model.rows.isEmpty)
        model.context = model.context.updated(activityFilter: .all)
        XCTAssertEqual(model.rows.map(\.id), ["project"])
        model.context = model.context.updated(scope: .allCapabilities, activityFilter: .notUsed30)
        XCTAssertEqual(model.rows.map(\.id), ["unused"])
        model.context = model.context.updated(activityFilter: .notUsed30)
        XCTAssertEqual(model.context.activityFilter, .notUsed30)
        model.context = model.context.updated(activityFilter: .all)
        XCTAssertEqual(Set(model.rows.map(\.id)), Set(["global", "project", "unused"]))
    }

    func testGroupingKeepsGlobalFirstAndProjectSortStableWhileSearchHidesEmptyGroups() {
        let resources = [
            resource("global-b", "Same", .agent, .global, nil, .userOwned),
            resource("global-a", "Same", .agent, .global, nil, .userOwned),
            resource("p2", "Zulu", .agent, .project, "p2", .userOwned),
            resource("p1", "Same", .agent, .project, "p1", .userOwned)
        ]
        let entries = CapabilityCatalog(resources: resources).entries
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: entries)
        model.setProjects([CapabilityProject(id: "p2", name: "Zulu"), CapabilityProject(id: "p1", name: "Alpha")])
        model.setData(catalog: entries, categoryStats: [], browseHistory: [], category30DayStats: [], browse30DayStats: [])
        XCTAssertEqual(model.groupedRows(for: .allCapabilities).map(\.id), ["__global__", "p1", "p2"])
        XCTAssertEqual(model.groupedRows(for: .allCapabilities).first?.rows.map(\.id), ["global-a", "global-b"])
        model.context = model.context.updated(search: "Zulu")
        XCTAssertEqual(model.groupedRows(for: .allCapabilities).map(\.id), ["p2"])
    }

    func testPluginUnavailableNeverAppearsInThirtyDayInactiveFilter() {
        func plugin(_ id: String, _ status: RuntimeStatus) -> CapabilityCatalogEntry {
            let resource = CapabilityResource(id: id, name: id, kind: .plugin, status: status, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: Date(), ownership: .runtime, origin: .runtime)
            return CapabilityCatalogEntry(resource: resource, category: .installedPlugins, parentPluginID: nil)
        }
        let entries = [plugin("plugin:enabled", .idle), plugin("plugin:unavailable", .blocked)]
        let model = CapabilityLibraryViewModel(category: .installedPlugins, catalog: entries)
        let results = [PluginUsageResult(pluginID: "plugin:enabled", callCount: 0), PluginUsageResult(pluginID: "plugin:unavailable", callCount: nil)]
        model.setPluginData(results, category30DayStats: results, browse30DayStats: results, attributionUnavailableCount: 1)
        model.context = CapabilityBrowseContext(activityFilter: .notUsed30)
        XCTAssertEqual(model.rows.map(\.id), ["plugin:enabled"])
        XCTAssertEqual(model.summaryCards.map(\.kind), [.installed, .enabled, .recent7, .notUsed30])
        XCTAssertEqual(model.pluginAttributionUnavailableCount, 1)
    }

    func testHomeUsesSharedVisualContracts() throws {
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 800), 4)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 600), 2)
        _ = DirectorMetricCard(symbolName: "person.crop.circle", label: "Agents", value: "1", supportingText: "Global 1 · Project 0", ordinal: "01") { }
        _ = DirectorGroupHeader(title: "Inventory", supportingText: "All capabilities", ordinal: "01")

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeSource = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        let layoutSource = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeVisualStyle.swift"), encoding: .utf8)
        let settingsSource = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(homeSource.contains("HomeCardAtlasFrame(workspaceWidth: viewport.size.width)"))
        XCTAssertEqual(homeSource.components(separatedBy: "HomeOutlineModule(").count - 1, 3)
        XCTAssertTrue(homeSource.contains("HomeMetricSegment"))
        XCTAssertTrue(homeSource.contains("HomeRankingLedger"))
        XCTAssertFalse(homeSource.contains("DirectorEditorialFrame"))
        XCTAssertFalse(homeSource.contains("DirectorMetricCard("))
        XCTAssertFalse(homeSource.contains("DirectorSectionBand("))
        XCTAssertFalse(homeSource.contains("DirectorMetricSequence"))
        XCTAssertTrue(homeSource.contains("inventoryTone"))
        XCTAssertTrue(homeSource.contains("rankingTone"))
        XCTAssertFalse(layoutSource.contains("inventoryColumns"))
        XCTAssertFalse(homeSource.contains("HomeMetricButtonStyle"))
        XCTAssertFalse(layoutSource.contains("struct HomeMetricButtonStyle"))
        XCTAssertFalse(layoutSource.contains("struct HomeModuleHeader"))
        XCTAssertTrue(settingsSource.contains("DirectorEditorialFrame"))
        XCTAssertTrue(settingsSource.contains("DirectorSectionBand("))
        XCTAssertTrue(settingsSource.contains("DirectorPrimaryActionButtonStyle"))
        XCTAssertTrue(settingsSource.contains("settings.about.title"))
    }

    func testModifiedSortIsLegalOnlyForCustomCategories() {
        XCTAssertTrue(CapabilityLibraryViewModel(category: .customSkills).modifiedSortAllowed)
        XCTAssertFalse(CapabilityLibraryViewModel(category: .installedSkills).modifiedSortAllowed)
        XCTAssertFalse(CapabilityLibraryViewModel(category: .installedPlugins).modifiedSortAllowed)
    }

    func testProjectScopeLabelIncludesProjectNameAndUsage() {
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setProjects([CapabilityProject(id: "p", name: "Demo Project")])
        model.context = CapabilityBrowseContext(scope: .project("p"))
        XCTAssertEqual(model.projects.first?.name, "Demo Project")
        XCTAssertEqual(model.context.scope, .project("p"))
    }

    private func resource(_ id: String, _ name: String, _ kind: ResourceKind, _ scope: ResourceScope, _ project: String?, _ ownership: ResourceOwnership) -> CapabilityResource {
        CapabilityResource(id: id, name: name, kind: kind, status: .success, scope: scope, projectID: project, confidence: .exact, summary: "Purpose", sourceRootID: "synthetic", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date(), ownership: ownership, origin: .local)
    }

}
