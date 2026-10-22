import XCTest
@testable import DirectorUI
@testable import DirectorCore

@MainActor
final class CapabilityLibraryStateTests: XCTestCase {
    func testFreshLibrariesDefaultToThirtyDayUsageDescending() {
        XCTAssertEqual(CapabilityBrowseContext().sort, .usageDescending)
        for category in CapabilityCategory.allCases {
            let model = CapabilityLibraryViewModel(category: category)
            XCTAssertEqual(model.context.sort, .usageDescending)
            XCTAssertEqual(model.usagePeriod, .thirtyDays)
            XCTAssertFalse(model.displayedUsageReady)
            model.context = model.context.updated(scope: .global, search: "synthetic")
            XCTAssertEqual(model.context.sort, .usageDescending)
            XCTAssertEqual(model.usagePeriod, .thirtyDays)
        }
    }

    func testFolderSortFallbackDefaultsToUsageDescending() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("folderSortByKey[sessionKey(for: folderID)] ?? .usageDescending"))
    }

    func testThirtyDaySortUsesItsOwnCountsAndPreservesSevenDayRows() {
        let entries = ["a", "b"].map { CapabilityCatalogEntry(resource: resource($0, project: nil), category: .customAgents, parentPluginID: nil) }
        let model = CapabilityLibraryViewModel(category: .customAgents)
        let seven = [CapabilityUsageStats(resourceID: "a", callCount: 5, inferredCount: 0, lastUsedAt: date(0), coverage: .complete)]
        let thirty = [CapabilityUsageStats(resourceID: "a", callCount: 5, inferredCount: 0, lastUsedAt: date(0), coverage: .complete), CapabilityUsageStats(resourceID: "b", callCount: 20, inferredCount: 0, lastUsedAt: date(-864000), coverage: .complete)]
        model.setData(catalog: entries, categoryStats: seven, browseHistory: [], category30DayStats: thirty, browse30DayStats: thirty)
        model.setUsagePeriod(.sevenDays)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
        model.context = model.context.updated(sort: .thirtyDayUsageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["b", "a"])
        XCTAssertEqual(model.displayedUsageCount(for: model.rows[0]), 20)
        XCTAssertEqual(model.rows[0].recent7Count, 0)
        model.context = model.context.updated(sort: .recentUsageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(model.displayedUsageCount(for: model.rows[0]), 5)
    }

    func testRowProjectionIsSharedByListAndSelectionAndInvalidatesOnChanges() {
        let a = CapabilityCatalogEntry(resource: resource("a", project: nil), category: .customAgents, parentPluginID: nil)
        let b = CapabilityCatalogEntry(resource: resource("b", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setData(catalog: [a, b], categoryStats: [], browseHistory: [])
        #if DEBUG
        XCTAssertEqual(model.rowProjectionBuildCount, 0)
        #endif
        XCTAssertEqual(model.rows(for: .global).map(\.id), ["a", "b"])
        XCTAssertEqual(model.groupedRows(for: .global).flatMap(\.rows).map(\.id), ["a", "b"])
        XCTAssertEqual(model.row(withID: "b", in: .global)?.id, "b")
        #if DEBUG
        XCTAssertEqual(model.rowProjectionBuildCount, 1)
        #endif

        model.context = model.context.updated(sort: .nameAscending)
        XCTAssertEqual(model.rows(for: .global).map(\.id), ["a", "b"])
        #if DEBUG
        XCTAssertEqual(model.rowProjectionBuildCount, 2)
        #endif

        model.setData(catalog: [a], categoryStats: [], browseHistory: [])
        XCTAssertEqual(model.rows(for: .global).map(\.id), ["a"])
        XCTAssertNil(model.row(withID: "b", in: .global))
        #if DEBUG
        XCTAssertEqual(model.rowProjectionBuildCount, 3)
        #endif
    }

    func testWarmFourLibrarySwitchPreservesEachProjectionSearchSortAndSelection() {
        let categories: [CapabilityCategory] = [.customAgents, .customSkills, .installedSkills, .installedPlugins]
        let models = categories.enumerated().map { offset, category in
            let entry = CapabilityCatalogEntry(
                resource: resource("item-\(offset)", project: nil),
                category: category,
                parentPluginID: nil
            )
            let model = CapabilityLibraryViewModel(category: category)
            model.setData(catalog: [entry], categoryStats: [], browseHistory: [])
            model.context = CapabilityBrowseContext(search: "item-\(offset)", sort: .nameAscending)
            model.selectedID = entry.resource.id
            return model
        }
        for model in models + Array(models.reversed()) {
            XCTAssertEqual(model.rows.map(\.id), [model.selectedID])
            XCTAssertEqual(model.context.sort, .nameAscending)
            XCTAssertEqual(model.context.search, model.selectedID)
            #if DEBUG
            XCTAssertEqual(model.rowProjectionBuildCount, 1)
            #endif
        }
    }

    func testThirtyDayUnavailableDoesNotFallBackToSevenDayCount() {
        let entry = CapabilityCatalogEntry(resource: resource("a", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setData(catalog: [entry], categoryStats: [CapabilityUsageStats(resourceID: "a", callCount: 5, inferredCount: 0, lastUsedAt: date(0), coverage: .complete)], browseHistory: [])
        model.context = model.context.updated(sort: .thirtyDayUsageDescending)
        XCTAssertNil(model.displayedUsageCount(for: model.rows[0]))
        XCTAssertFalse(model.displayedUsageReady)
        model.setData(catalog: [entry], categoryStats: [], browseHistory: [], category30DayStats: [], browse30DayStats: [])
        XCTAssertEqual(model.displayedUsageCount(for: model.rows[0]), 0)
        XCTAssertTrue(model.displayedUsageReady)
    }

    func testThirtyDayFilterDistinguishesPendingObservedZeroAndPositivePartialEvidence() throws {
        let pending = CapabilityCatalogEntry(resource: resource("pending", project: nil), category: .customAgents, parentPluginID: nil)
        let zero = CapabilityCatalogEntry(resource: resource("zero", project: nil), category: .customAgents, parentPluginID: nil)
        let partial = CapabilityCatalogEntry(resource: resource("partial", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        model.setDirectory(catalog: [pending, zero, partial], projects: [])
        model.context = model.context.updated(activityFilter: .notUsed30)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.summaryCards.last?.statisticsReady ?? true)

        let positive = CapabilityUsageStats(resourceID: "partial", callCount: 3, inferredCount: 2, lastUsedAt: date(0), coverage: .partial)
        model.setData(catalog: [pending, zero, partial], categoryStats: [positive], browseStats: [positive], browseHistory: [], category30DayStats: [positive], browse30DayStats: [positive])
        XCTAssertEqual(model.rows.map(\.id), ["pending", "zero"])
        XCTAssertFalse(model.rows.contains { $0.id == "partial" })

        model.context = model.context.updated(activityFilter: .all)
        model.setUsagePeriod(.thirtyDays)
        let partialRow = try XCTUnwrap(model.rows.first { $0.id == "partial" })
        XCTAssertEqual(partialRow.recent30Count, 3)
        XCTAssertEqual(partialRow.coverage, .partial)
        XCTAssertEqual(partialRow.inferredCount, 2)
        let zeroRow = try XCTUnwrap(model.rows.first { $0.id == "zero" })
        let zeroAX = model.rowText(for: zeroRow, language: .english).accessibilityLabel
        XCTAssertTrue(zeroAX.contains("0 calls"))
        XCTAssertFalse(zeroAX.localizedCaseInsensitiveContains("unused"))
        XCTAssertFalse(zeroAX.contains("root"))
        XCTAssertFalse(zeroAX.contains("payload"))
    }

    func testThirtyDayPluginSortKeepsUnknownAfterExplicitZero() {
        let entries = ["a", "b", "c"].map { CapabilityCatalogEntry(resource: resource($0, project: nil), category: .installedPlugins, parentPluginID: nil) }
        let model = CapabilityLibraryViewModel(category: .installedPlugins, catalog: entries)
        let thirty = [PluginUsageResult(pluginID: "a", callCount: nil), PluginUsageResult(pluginID: "b", callCount: 0), PluginUsageResult(pluginID: "c", callCount: 8)]
        model.setPluginData([PluginUsageResult(pluginID: "a", callCount: 100)], category30DayStats: thirty, browse30DayStats: thirty)
        model.context = model.context.updated(sort: .thirtyDayUsageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(model.rows.map { model.displayedUsageCount(for: $0) }, [8, 0, nil])
    }

    func testFolderSortIsIndependentOfPeriodAndHasLocalizedCurrentValue() {
        XCTAssertEqual(CapabilityFolderSort.allCases.map(\.rawValue), ["usageDescending", "usageAscending", "nameAscending"])
        XCTAssertEqual(CapabilityFolderSort.usageDescending.title(.simplifiedChinese), "调用量 ↓")
        XCTAssertEqual(CapabilityFolderSort.usageDescending.title(.english), "Usage ↓")
    }
    func testDefaultSortUsesThirtyDayCountBeforeHistoryDate() {
        let a = CapabilityCatalogEntry(resource: resource("a", project: nil), category: .customAgents, parentPluginID: nil)
        let b = CapabilityCatalogEntry(resource: resource("b", project: nil), category: .customAgents, parentPluginID: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents)
        let thirty = [CapabilityUsageStats(resourceID: "a", callCount: 10, inferredCount: 0, lastUsedAt: date(-100), coverage: .complete), CapabilityUsageStats(resourceID: "b", callCount: 1, inferredCount: 0, lastUsedAt: date(-1), coverage: .complete)]
        let seven = [CapabilityUsageStats(resourceID: "a", callCount: 1, inferredCount: 0, lastUsedAt: date(-100), coverage: .complete), CapabilityUsageStats(resourceID: "b", callCount: 10, inferredCount: 0, lastUsedAt: date(-1), coverage: .complete)]
        model.setData(catalog: [a, b], categoryStats: seven, browseHistory: [], category30DayStats: thirty, browse30DayStats: thirty)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(model.rows.map { model.displayedUsageCount(for: $0) }, [10, 1])
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
