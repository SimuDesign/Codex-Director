import AppKit
import XCTest

@testable import DirectorUI

final class HomeCardAtlasTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCardAtlasLayoutContractUsesDesktopGuttersAndBreakpoints() throws {
        XCTAssertEqual(HomeLayout.horizontalPadding(for: 1_280), 40)
        XCTAssertEqual(HomeLayout.horizontalPadding(for: 759), 16)
        XCTAssertEqual(HomeLayout.contentWidth(for: 1_280), 1_200)
        XCTAssertEqual(HomeLayout.contentWidth(for: 2_000), 1_440)

        let style = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeVisualStyle.swift"), encoding: .utf8)
        XCTAssertTrue(style.contains("quotaColumns"))
        XCTAssertTrue(style.contains("metricColumns"))
        XCTAssertTrue(style.contains("rankingColumns"))
        XCTAssertTrue(style.contains("760"))
        XCTAssertTrue(style.contains("1000"))
    }

    func testCardAtlasUsesThreeDistinctOuterModulesAndNoLegacyHomeChrome() throws {
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        XCTAssertEqual(home.components(separatedBy: "HomeOutlineModule(").count - 1, 3)
        XCTAssertFalse(home.contains("DirectorSectionBand("))
        XCTAssertFalse(home.contains("DirectorContentStage"))
        XCTAssertFalse(home.contains("DirectorEditorialHero"))
        XCTAssertFalse(home.contains("ordinal:"))
        XCTAssertTrue(home.contains("home.module.usage"))
        XCTAssertTrue(home.contains("home.module.capabilitySummary"))
        XCTAssertTrue(home.contains("home.module.usageRanking"))
    }

    func testHomeOnlyNumericAndModuleTokensAreNamed() throws {
        let componentsPath = sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")
        let components = (try? String(contentsOf: componentsPath, encoding: .utf8)) ?? ""
        let radius = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorRadius.swift"), encoding: .utf8)
        let typography = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorTypography.swift"), encoding: .utf8)

        XCTAssertTrue(components.contains("HomeNumericTypography"))
        XCTAssertTrue(components.contains("HomeOutlineModule"))
        XCTAssertTrue(components.contains("HomeHeroHeader"))
        XCTAssertTrue(components.contains("HomeMetricStrip"))
        XCTAssertTrue(components.contains("HomeRankingLedger"))
        XCTAssertTrue(radius.contains("homeModule"))
        XCTAssertTrue(typography.contains("homeMetric"))
        XCTAssertTrue(typography.contains("homeRank"))
    }

    func testHomeCompositionUsesTheOuterWorkspaceBreakpoint() throws {
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("HomeCardAtlasFrame(workspaceWidth: viewport.size.width)"))
        XCTAssertTrue(home.contains("HomeLayout.contentWidth(for: viewport.size.width)"))
        XCTAssertFalse(home.contains("DirectorEditorialFrame"))
    }

    func testHomeUsesContinuousMetricsAndAComparisonLedger() throws {
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        let components = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("HomeMetricSegment"))
        XCTAssertFalse(home.contains("DirectorMetricCard("))
        XCTAssertTrue(components.contains("HomeMetricRuleOverlay"))
        XCTAssertTrue(components.contains("HomeRankingRuleOverlay"))
        XCTAssertTrue(components.contains("spacing: 0"))
        XCTAssertTrue(home.contains("HomeNumericTypography.rankIndex"))
        XCTAssertTrue(home.contains("HomeNumericTypography.rankCount"))
    }

    func testQuotaUsesProgressRingAndKeepsSingleSourceSelectorHidden() throws {
        let quota = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/QuotaOverviewView.swift"), encoding: .utf8)
        XCTAssertTrue(quota.contains("HomeQuotaProgressRing"))
        XCTAssertFalse(quota.contains("SectorMark"))
        XCTAssertTrue(quota.contains("displayModel.sources.count > 1"))
        XCTAssertFalse(quota.contains("else if let source = displayModel.selectedSource"))
        XCTAssertTrue(quota.contains("chartYScale(domain: 0...chartPlotMaximum)"))
        XCTAssertTrue(quota.contains("HomeQuotaChartScale.axisMaximum"))
    }

    func testQuotaCentersRingUsesGradientBarsAndAlignedDates() throws {
        let quota = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/QuotaOverviewView.swift"), encoding: .utf8)

        XCTAssertTrue(quota.contains("ringSection.frame(width: 420, alignment: .center)"))
        XCTAssertTrue(quota.contains("resetSummary"))
        XCTAssertFalse(quota.contains("evidenceSection"))
        XCTAssertFalse(quota.contains("home.quota.recorded"))
        XCTAssertTrue(quota.contains(".foregroundStyle(DirectorGradient.quotaBar)"))
        XCTAssertFalse(quota.contains("home.quota.resetMarker"))
        XCTAssertFalse(quota.contains("home.quota.cycleLegend"))
        XCTAssertTrue(quota.contains("width: .fixed(44)"))
        XCTAssertEqual(quota.components(separatedBy: "chartCategory(for: day)").count - 1, 2)
        let normalized = quota.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(normalized.contains(".chartXScale( domain: chartCategories, range: .plotDimension"))
        XCTAssertTrue(quota.contains("AxisMarks(values: chartCategories)"))
        let xAxisStart = try XCTUnwrap(quota.range(of: ".chartXAxis"))
        let xAxisTail = String(quota[xAxisStart.lowerBound...])
        let xAxisEnd = try XCTUnwrap(xAxisTail.range(of: ".frame(minHeight: 180)"))
        let xAxis = String(xAxisTail[..<xAxisEnd.lowerBound])
        XCTAssertTrue(xAxis.contains("AxisValueLabel(centered: false)"))
        XCTAssertFalse(xAxis.contains("AxisValueLabel(anchor:"))
        XCTAssertFalse(xAxis.contains("AxisGridLine"))
    }

    func testWelcomeHeroAndGlobalToolbarUseTheLabeledRefreshControl() throws {
        let homePath = sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift")
        let rootPath = sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorRootView.swift")
        let home = try String(contentsOf: homePath, encoding: .utf8)
        let root = try String(contentsOf: rootPath, encoding: .utf8)

        XCTAssertTrue(home.contains("title: \"Welcome to Codex Director\""))
        XCTAssertTrue(home.contains("titleAccent: DirectorUI.productName"))
        XCTAssertTrue(home.contains("lastUpdatedAt"))
        XCTAssertFalse(home.contains("onRefresh"))
        XCTAssertTrue(root.contains(".navigationTitle(DirectorUI.productName)"))
        XCTAssertTrue(root.contains("lastUpdatedAt: model.lastRefresh"))
        XCTAssertTrue(root.contains("ToolbarItem(placement: .primaryAction)"))
        XCTAssertTrue(root.contains("DirectorRefreshButton("))
        XCTAssertTrue(root.contains("size: .toolbar"))
        XCTAssertTrue(root.contains("action: startIndexing"))
        XCTAssertFalse(root.contains("Image(systemName: \"arrow.clockwise\")"))
    }

    func testApprovedIllustrationIsAnAlphaPNGAtTheExpectedSourceSize() throws {
        let imageURL = sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/Home/home-capability-archive-v3-trimmed.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        let image = try XCTUnwrap(NSImage(contentsOf: imageURL))
        XCTAssertEqual(image.size.width, 852, accuracy: 1)
        XCTAssertEqual(image.size.height, 809, accuracy: 1)

        let bundledURL = try XCTUnwrap(HomeCardAtlasAsset.url)
        XCTAssertEqual(bundledURL.lastPathComponent, imageURL.lastPathComponent)
        let bundledImage = try XCTUnwrap(HomeCardAtlasAsset.image)
        XCTAssertEqual(bundledImage.size.width, 852, accuracy: 1)
        XCTAssertEqual(bundledImage.size.height, 809, accuracy: 1)

        let cgImage = try XCTUnwrap(bundledImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            XCTFail("approved illustration must preserve its transparent alpha channel")
        default:
            break
        }
    }

    func testHeroNoLongerRendersTheIllustrationOrInlineAction() throws {
        let components = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(components.contains("illustrationView"))
        XCTAssertFalse(components.contains("HomeHeroIllustrationTreatment"))
        XCTAssertFalse(components.contains("public let illustration"))
        XCTAssertFalse(components.contains("public let actionTitle"))
    }

    func testQuotaRingUsesTheNamedThickerStrokeAndReduceMotionAwareReveal() throws {
        let components = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift"), encoding: .utf8)
        let spacing = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift"), encoding: .utf8)

        XCTAssertTrue(spacing.contains("homeQuotaRingLineWidth: CGFloat = 20"))
        XCTAssertTrue(components.contains("lineWidth: CGFloat = DirectorSpacing.homeQuotaRingLineWidth"))
        XCTAssertTrue(components.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(components.contains("withAnimation(.easeOut(duration: DirectorMotion.emphasized))"))
    }
}
