import XCTest
@testable import DirectorUI

/// Layout contract for the capability table's primary identifying column.
final class CapabilitiesLayoutTests: XCTestCase {

    func testCapabilityNameColumnFitsThreeWordSkillNamesByDefault() {
        XCTAssertGreaterThanOrEqual(DirectorTableMetrics.capabilityNameMinimumWidth, 240)
        XCTAssertGreaterThanOrEqual(DirectorTableMetrics.capabilityNameIdealWidth, 280)
    }

    func testCapabilityNameColumnKeepsResponsiveBounds() {
        XCTAssertLessThanOrEqual(
            DirectorTableMetrics.capabilityNameMinimumWidth,
            DirectorTableMetrics.capabilityNameIdealWidth
        )
        XCTAssertLessThanOrEqual(
            DirectorTableMetrics.capabilityNameIdealWidth,
            DirectorTableMetrics.capabilityNameMaximumWidth
        )
        XCTAssertGreaterThan(DirectorTableMetrics.capabilityNameMinimumWidth, 0)
    }

    func testCapabilitySideSheetKeepsAReadableBoundedWidth() {
        XCTAssertEqual(CapabilitiesLayoutState.forContentWidth(839), .compact)
        XCTAssertEqual(CapabilitiesLayoutState.forContentWidth(840), .spacious)
        XCTAssertEqual(DirectorSpacing.sideSheetMinWidth, 380)
        XCTAssertEqual(DirectorSpacing.sideSheetIdealWidth, 400)
        XCTAssertEqual(DirectorSpacing.sideSheetMaxWidth, 420)
    }

    func testCapabilityPageUsesNamedCompactMetricHeights() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let spacing = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift"), encoding: .utf8)
        XCTAssertTrue(library.contains("DirectorSpacing.capabilityMetricHeightCompact"))
        XCTAssertTrue(library.contains("DirectorSpacing.capabilityMetricHeight"))
        XCTAssertTrue(spacing.contains("capabilityMetricHeight: CGFloat = 96"))
        XCTAssertTrue(spacing.contains("capabilityMetricHeightCompact: CGFloat = 88"))
    }

    func testAgentUsesCardAtlasHeaderRibbonAndProjectGroups() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        XCTAssertTrue(library.contains("capabilityTitleBlock"))
        XCTAssertTrue(library.contains("capabilityTitleText"))
        XCTAssertTrue(library.contains("DirectorMetricSequence"))
        XCTAssertTrue(library.contains("DirectorFilterRibbon"))
        XCTAssertTrue(library.contains("DirectorSideSheet"))
        XCTAssertTrue(library.contains("CapabilityGroupRowBorder"))
        XCTAssertTrue(library.contains("filterSearchField"))
        XCTAssertTrue(library.contains("List(selection: $model.selectedID)"))
        XCTAssertTrue(library.contains("DirectorPageLayout.listRowInset(for: width)"))
        XCTAssertTrue(library.contains(".listRowInsets(rowInsets)"))
        XCTAssertTrue(library.contains(".listRowInsets(headerRowInsets)"))
        XCTAssertTrue(library.contains(".contentMargins(.horizontal, 0, for: .scrollContent)"))
        XCTAssertTrue(library.contains(".contentMargins(.vertical, 0, for: .scrollContent)"))
        XCTAssertFalse(library.contains("capabilityHeader(width:"))
        XCTAssertFalse(library.contains("headerSearch"))
        XCTAssertTrue(library.contains("DirectorTypography.capabilityRowTitle"))
        XCTAssertTrue(library.contains("DirectorTypography.capabilityRowSummary"))
        XCTAssertFalse(library.contains("DirectorContentStage"))
        XCTAssertFalse(library.contains("DirectorTableHeader"))
        XCTAssertFalse(library.contains("DirectorInspectorPanel"))
        XCTAssertFalse(library.contains("activityPicker"))
        XCTAssertFalse(library.contains(".searchable("))
    }

    func testFilterFillsTheRibbonWithoutAResultCountField() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let normalized = library.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(normalized.contains("filterSearchField .frame(minWidth: 220, maxWidth: .infinity) controls"))
        XCTAssertTrue(normalized.contains("filterSearchField .frame(maxWidth: .infinity) controls"))
        XCTAssertFalse(library.contains("private var resultCount"))
    }

    func testCapabilityPolishUsesSharedFieldsSpacingAndSemanticAccent() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let scheme = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift"), encoding: .utf8)
        let typography = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorTypography.swift"), encoding: .utf8)

        XCTAssertTrue(library.contains("DirectorControlField"))
        XCTAssertTrue(scheme.contains("public struct DirectorControlField"))
        XCTAssertTrue(library.contains(".padding(.bottom, compact ? DirectorSpacing.space3 : DirectorSpacing.space4)"))
        XCTAssertTrue(library.contains(".padding(.bottom, DirectorSpacing.space6)"))
        XCTAssertTrue(library.contains("DirectorTypography.pageHeroSymbol"))
        XCTAssertTrue(typography.contains("pageHeroSymbol"))
        XCTAssertTrue(library.contains("if row.entry.resource.kind != .agent"))
        XCTAssertTrue(library.contains("DirectorColor.accent(pageTone).opacity(0.12)"))
        XCTAssertFalse(library.contains("labeledPicker(copy(\"library.view\""))
    }

    func testCapabilityCardsAndRowsExposeVisibleHoverSeparatorsAndRoundedBottoms() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let shared = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift"), encoding: .utf8)

        XCTAssertTrue(shared.contains("DirectorColor.inset.opacity(isHovering || configuration.isPressed ? 0.72 : 0)"))
        XCTAssertFalse(shared.contains(".overlay(alignment: .bottom) {\n                if selected"))
        XCTAssertTrue(library.contains("CapabilityGroupRowBackground"))
        XCTAssertTrue(library.contains("path.addQuadCurve"))
        XCTAssertTrue(library.contains("if boundary == .first || boundary == .middle"))
        XCTAssertTrue(library.contains(".listRowBackground(Color.clear)"))
        XCTAssertTrue(library.contains("DirectorTypography.capabilityRowCount"))
        XCTAssertTrue(library.contains("DirectorTypography.capabilityRowCountLabel"))
    }

    func testCapabilityGroupHeaderHasOneBoundarySource() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shared = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift"), encoding: .utf8)
        let headerStart = try XCTUnwrap(shared.range(of: "public struct DirectorGroupHeader"))
        let headerSource = String(shared[headerStart.lowerBound...])

        XCTAssertFalse(headerSource.contains("Rectangle().fill(DirectorColor.boundary)"))
    }

    func testAgentInspectorUsesIdentityCodeTwoUpStatsAndFullWidthEvidenceAction() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detail = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(detail.contains("Text(\"/ \\(model.row.id)\")"))
        XCTAssertTrue(detail.contains("detailStat(copy(\"detail.metric.recent\""))
        XCTAssertTrue(detail.contains("detailStat(copy(\"detail.metric.inferred\""))
        XCTAssertTrue(detail.contains(".frame(maxWidth: .infinity)"))
    }
}
