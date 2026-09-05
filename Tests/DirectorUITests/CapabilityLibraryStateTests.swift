import XCTest
@testable import DirectorUI
@testable import DirectorCore

@MainActor
final class CapabilityLibraryStateTests: XCTestCase {
    func testDefaultSortUsesSevenDayCountBeforeHistoryDate() {
        let a = CapabilityCatalogEntry(resource: resource("a", project: nil), category: .customAgents, parentPluginID: nil)
        let b = CapabilityCatalogEntry(resource: resource("b", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setData(catalog: [a, b], categoryStats: [CapabilityUsageStats(resourceID: "a", callCount: 10, inferredCount: 0, lastUsedAt: date(-100), coverage: .complete), CapabilityUsageStats(resourceID: "b", callCount: 1, inferredCount: 0, lastUsedAt: date(-1), coverage: .complete)], browseHistory: [])
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
    }
    func testScopeAndSearchDoNotChangeCategoryCountOrUsedCount() {
        let entries = ["a", "b"].map { CapabilityCatalogEntry(resource: resource($0, project: $0 == "a" ? nil : "p"), category: .customAgents, parentPluginID: nil) }
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setData(catalog: entries, categoryStats: entries.map { CapabilityUsageStats(resourceID: $0.resource.id, callCount: 2, inferredCount: 0, lastUsedAt: nil, coverage: .complete) }, browseHistory: [], usageProjects: ["a": ["p"]])
        XCTAssertEqual(model.categoryCount, 2); XCTAssertEqual(model.usedCount, 2)
        model.context = CapabilityBrowseContext(search: "a")
        XCTAssertEqual(model.categoryCount, 2); XCTAssertEqual(model.usedCount, 2)
        model.context = CapabilityBrowseContext(scope: .allProjects)
        XCTAssertEqual(model.rows.map(\.id), ["b"])
        model.context = CapabilityBrowseContext(scope: .project("p"))
        XCTAssertEqual(model.rows.map(\.id), ["a"])
    }
    func testIndependentModelsPreserveContextAndSelection() {
        let entry = CapabilityCatalogEntry(resource: resource("a", project: nil), category: .customAgents, parentPluginID: nil)
        let first = CapabilityLibraryViewModel(category: .customAgents); let second = CapabilityLibraryViewModel(category: .customAgents)
        first.setData(catalog: [entry], categoryStats: [], browseHistory: []); second.setData(catalog: [entry], categoryStats: [], browseHistory: [])
        first.context = CapabilityBrowseContext(search: "a", sort: .nameAscending); first.selectedID = "a"
        XCTAssertEqual(second.context, CapabilityBrowseContext()); XCTAssertNil(second.selectedID)
    }
    func testDirectoryProjectionDoesNotConfirmUsageAndConfirmedEmptyShowsZero() {
        let entry = CapabilityCatalogEntry(resource: resource("directory-agent", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setDirectory(catalog: [entry], projects: [])
        XCTAssertFalse(model.rows[0].statisticsReady)
        XCTAssertNil(model.rows[0].recent7Count)
        model.setData(catalog: [entry], categoryStats: [], browseStats: [], browseHistory: [])
        XCTAssertTrue(model.rows[0].statisticsReady)
        XCTAssertEqual(model.rows[0].recent7Count, 0)
    }
    func testPluginRowsUseAttributedStatsAndHistoryOnly() {
        let now = date(100)
        func plugin(_ id: String) -> CapabilityCatalogEntry {
            let resource = CapabilityResource(id: id, name: id, kind: .plugin, status: .idle, scope: .runtime, projectID: nil, confidence: .exact, summary: id, sourceRootID: "runtime", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: now, ownership: .runtime, origin: .runtime)
            return CapabilityCatalogEntry(resource: resource, category: .installedPlugins, parentPluginID: nil)
        }
        let model = CapabilityLibraryViewModel(category: .installedPlugins, catalog: [plugin("plugin:attributed"), plugin("plugin:unsupported")])
        model.setData(catalog: [plugin("plugin:attributed"), plugin("plugin:unsupported")], categoryStats: [CapabilityUsageStats(resourceID: "plugin:attributed", callCount: 5, inferredCount: 0, lastUsedAt: now, coverage: .complete)], browseHistory: [CapabilityHistory(resourceID: "plugin:attributed", callCount: 1, lastUsedAt: date(1))])
        model.setPluginData([PluginUsageResult(pluginID: "plugin:attributed", callCount: 1, inferredCount: 1, lastUsedAt: date(2), coverage: .partial), PluginUsageResult(pluginID: "plugin:unsupported", callCount: nil)])
        let rows = model.rows
        let attributed = rows.first { $0.id == "plugin:attributed" }
        XCTAssertEqual(attributed?.recent7Count, 1); XCTAssertEqual(attributed?.inferredCount, 1); XCTAssertEqual(attributed?.lastUsedAt, date(1)); XCTAssertEqual(attributed?.coverage, .partial)
        let unsupported = rows.first { $0.id == "plugin:unsupported" }
        XCTAssertNil(unsupported?.recent7Count); XCTAssertNil(unsupported?.lastUsedAt)
    }
    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }
    private func resource(_ name: String, project: String?) -> CapabilityResource { CapabilityResource(id: name, name: name, kind: .agent, status: .unknown, scope: project == nil ? .global : .project, projectID: project, confidence: .exact, summary: name, sourceRootID: "root", relativeSourcePath: name, sourcePathHash: nil, lastSeenAt: date(0), ownership: .userOwned, origin: .local, sourceModifiedAt: date(0)) }
}
