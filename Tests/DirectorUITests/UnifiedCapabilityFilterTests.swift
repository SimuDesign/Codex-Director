import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class UnifiedCapabilityFilterTests: XCTestCase {
    func testPeriodRemainsIndependentOfAscendingNameAndModifiedSort() throws {
        let model = makeLibrary(.customAgents)
        model.setUsagePeriod(.thirtyDays)
        model.context = model.context.updated(sort: .usageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["b", "a"])
        model.context = model.context.updated(sort: .usageAscending)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
        for sort in [CapabilitySort.nameAscending, .modifiedDescending] {
            model.context = model.context.updated(sort: sort)
            XCTAssertEqual(model.usagePeriod, .thirtyDays)
            XCTAssertEqual(model.displayedUsageCount(for: try XCTUnwrap(model.row(withID: "b", in: .allCapabilities))), 12)
            XCTAssertTrue(model.rowText(for: model.rows[0], language: .english).countLabel.contains("30 days"))
        }
        model.setUsagePeriod(.sevenDays)
        model.context = model.context.updated(sort: .usageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
    }

    func testSelectedPeriodInvalidatesWarmSortProjectionWithoutChangingData() {
        let model = makeLibrary(.customSkills)
        model.context = model.context.updated(sort: .usageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
        let stats = model.browseStats
        model.setUsagePeriod(.thirtyDays)
        XCTAssertEqual(model.rows.map(\.id), ["b", "a"])
        XCTAssertEqual(model.browseStats, stats)
        XCTAssertFalse(model.isLoading)
    }

    func testSharedRememberedPeriodReachesEveryLibraryAndOtherAppModels() {
        let preferences = CapabilityFolderUsagePreferences(memoryPeriod: .thirtyDays)
        let first = makeApp(preferences)
        let second = makeApp(preferences)
        let members = first.capabilityFolders
        XCTAssertTrue(first.libraryModels.allSatisfy { $0.usagePeriod == .thirtyDays })
        first.setCapabilityFolderUsagePeriod(.sevenDays)
        XCTAssertTrue((first.libraryModels + second.libraryModels).allSatisfy { $0.usagePeriod == .sevenDays })
        XCTAssertEqual(second.capabilityFolderUsagePeriod, .sevenDays)
        XCTAssertEqual(first.homeUsageRankingPeriod, .sevenDays)
        XCTAssertEqual(first.capabilityFolders, members)
        XCTAssertFalse(first.isRefreshing)
        XCTAssertNil(first.accountUsageSnapshot)
        XCTAssertNil(first.folderUsagePeriods)
    }

    func testLegacyPeriodSpecificSortStillSelectsItsPeriod() {
        let model = makeLibrary(.installedSkills)
        model.context = model.context.updated(sort: .thirtyDayUsageDescending)
        XCTAssertEqual(model.usagePeriod, .thirtyDays)
        XCTAssertEqual(model.rows.map(\.id), ["b", "a"])
        model.setUsagePeriod(.sevenDays)
        XCTAssertEqual(model.context.sort, .usageDescending)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
    }

    func testThirtyDayPendingNeverFallsBackToSevenDayOrZero() {
        let model = makeLibrary(.customAgents)
        model.setData(catalog: model.catalog, categoryStats: model.recentStats, browseHistory: [])
        model.setUsagePeriod(.thirtyDays)
        model.context = model.context.updated(sort: .nameAscending)
        XCTAssertNil(model.displayedUsageCount(for: model.rows[0]))
        XCTAssertFalse(model.displayedUsageReady)
        XCTAssertEqual(model.rowText(for: model.rows[0], language: .english).countValue, "—")
    }

    func testPluginUnknownRemainsLastInEitherDirectionAndPeriod() {
        let model = makeLibrary(.installedPlugins)
        let seven = [PluginUsageResult(pluginID: "a", callCount: nil), PluginUsageResult(pluginID: "b", callCount: 0)]
        let thirty = [PluginUsageResult(pluginID: "a", callCount: nil), PluginUsageResult(pluginID: "b", callCount: 4)]
        model.setPluginData(seven, category30DayStats: thirty, browse30DayStats: thirty)
        for period in CapabilityFolderUsagePeriod.allCases {
            model.setUsagePeriod(period)
            for sort in [CapabilitySort.usageAscending, .usageDescending] {
                model.context = model.context.updated(sort: sort)
                XCTAssertEqual(model.rows.map(\.id), ["b", "a"])
                XCTAssertNil(model.displayedUsageCount(for: model.rows[1]))
            }
        }
    }

    func testSharedControlGeometryAndLocalizedVocabulary() throws {
        XCTAssertEqual(DirectorCapabilityFilterMetrics.controlHeight, 36)
        XCTAssertEqual(DirectorCapabilityFilterMetrics.periodWidth, 232)
        XCTAssertEqual(DirectorCapabilityFilterMetrics.sortWidth, 176)
        XCTAssertEqual(DirectorCapabilityFolderLayout.controlHeight, DirectorCapabilityFilterMetrics.controlHeight)
        XCTAssertEqual(CapabilityFolderSort.usageAscending.title(.simplifiedChinese), "调用量 ↑")
        XCTAssertEqual(DirectorUsageSortOption.usageAscending.title(.english), "Usage ↑")
        let control = DirectorNativeOutlinedSegmentedControl(frame: .zero)
        control.applyConfiguration(label: "Usage period", titles: ["Last 7 days", "Last 30 days"], selectedIndex: 0, isEnabled: true, increasedContrast: false, reduceTransparency: false, minimumHeight: DirectorCapabilityFilterMetrics.controlHeight)
        XCTAssertEqual(control.fittingSize(forWidth: 232).height, 36)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["CapabilityLibraryView", "CapabilityFoldersView"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Capabilities/\(name).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains("DirectorUsagePeriodPicker("))
            XCTAssertTrue(source.contains("DirectorUsageSortMenu("))
            XCTAssertFalse(source.contains("selectSort(.thirtyDayUsageDescending)"))
        }
    }

    private func makeLibrary(_ category: CapabilityCategory) -> CapabilityLibraryViewModel {
        let entries = ["a", "b"].map { id in
            CapabilityCatalogEntry(resource: .init(id: id, name: id, kind: category == .customAgents ? .agent : .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Synthetic purpose", sourceRootID: "synthetic", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date(), ownership: .userOwned, origin: .local), category: category, parentPluginID: nil)
        }
        let seven = [stats("a", 8), stats("b", 1)]
        let thirty = [stats("a", 9), stats("b", 12)]
        let model = CapabilityLibraryViewModel(category: category)
        model.setData(catalog: entries, categoryStats: seven, browseHistory: [], category30DayStats: thirty, browse30DayStats: thirty)
        return model
    }
    private func stats(_ id: String, _ count: Int) -> CapabilityUsageStats {
        .init(resourceID: id, callCount: count, inferredCount: 0, lastUsedAt: nil, coverage: .complete)
    }
    private func makeApp(_ preferences: CapabilityFolderUsagePreferences) -> DirectorAppModel {
        let stores = TestMemoryPreferences.makeStores()
        return DirectorAppModel(classificationOverrides: stores.0, evaluationStore: stores.1, previewMode: false, capabilityFolderUsagePreferences: preferences)
    }
}
