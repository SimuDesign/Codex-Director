import XCTest
@testable import DirectorUI

final class HomeVisualLayoutTests: XCTestCase {
    func testHomeContentUsesApprovedWidthAndPaddingBreakpoints() {
        XCTAssertEqual(HomeLayout.horizontalPadding(for: 759), 16)
        XCTAssertEqual(HomeLayout.horizontalPadding(for: 760), 40)
        XCTAssertEqual(HomeLayout.contentWidth(for: 1280), 1200)
        XCTAssertEqual(HomeLayout.contentWidth(for: 2000), 1440)
        XCTAssertEqual(HomeVisual.moduleGap, 32)
    }

    func testInventoryAndRankingColumnsFollowActualContentWidth() {
        XCTAssertEqual(HomeLayout.quotaColumns(for: 759), 1)
        XCTAssertEqual(HomeLayout.quotaColumns(for: 760), 2)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 800), 4)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 600), 2)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 419), 1)
        XCTAssertEqual(HomeLayout.rankingColumns(for: 1000), 3)
        XCTAssertEqual(HomeLayout.rankingColumns(for: 999), 1)
    }

    func testDailyQuotaUsageScaleKeepsSmallValuesLegible() {
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: []), 10)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [0, 8]), 10)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [8, 18]), 20)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [48]), 50)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [71]), 100)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [100]), 100)
        XCTAssertEqual(HomeQuotaChartScale.axisMaximum(for: [117]), 150)
    }

    func testHomeUsesCardAtlasModulesWithoutLegacyBands() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        XCTAssertEqual(home.components(separatedBy: "HomeOutlineModule(").count - 1, 3)
        XCTAssertFalse(home.contains("DirectorSectionBand("))
        XCTAssertFalse(home.contains("DirectorContentStage"))
        XCTAssertFalse(home.contains("DirectorMetricSequence"))
        XCTAssertFalse(home.contains("ordinal:"))
    }
}
