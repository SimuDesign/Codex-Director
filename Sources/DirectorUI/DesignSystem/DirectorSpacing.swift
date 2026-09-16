import CoreGraphics
import SwiftUI

/// Design-system spacing scale (DESIGN_SYSTEM_V1 §8.1).
/// Governs custom surfaces and visualization overlays, not replacement
/// geometry for native controls.
public enum DirectorSpacing {
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24
    public static let space8: CGFloat = 32
    public static let space10: CGFloat = 40
    /// Desktop Card Atlas pages use the same generous outer gutter as Home.
    /// Native controls may still use their system metrics inside this field.
    public static let pagePadding: CGFloat = 40
    public static let compactPagePadding: CGFloat = 16
    public static let moduleGap: CGFloat = 32
    public static let maxContentWidth: CGFloat = 1440
    public static let heroGap: CGFloat = 28
    public static let ribbonGap: CGFloat = 12
    public static let controlMinHeight: CGFloat = 32
    public static let toolbarControlMinHeight: CGFloat = 28
    /// Shared visual slot for the refresh glyph and indeterminate progress
    /// indicator. Keeping both states in one slot prevents vertical drift.
    public static let refreshIndicatorSize: CGFloat = 14
    /// Shared content width for the three Settings actions. The value covers
    /// the longest localized label while the styles add their common insets.
    public static let settingsActionLabelWidth: CGFloat = 176
    /// Shared outer height for the three Settings actions, including loading
    /// and disabled states.
    public static let settingsActionHeight: CGFloat = 48
    public static let inspectorMinWidth: CGFloat = 360
    public static let inspectorIdealWidth: CGFloat = 380
    public static let inspectorMaxWidth: CGFloat = 400
    public static let sideSheetMinWidth: CGFloat = 380
    public static let sideSheetIdealWidth: CGFloat = 400
    public static let sideSheetMaxWidth: CGFloat = 420
    public static let editorialBandGap: CGFloat = 40
    public static let contentStagePadding: CGFloat = 24
    /// Final outer heights for capability-page metric cards. The metric
    /// button style owns its 16pt vertical insets.
    public static let capabilityMetricHeight: CGFloat = 96
    public static let capabilityMetricHeightCompact: CGFloat = 88
    /// Home's quota ring uses a stronger stroke so it remains the primary
    /// visual signal beside the seven-day snapshot chart.
    public static let homeQuotaRingDiameter: CGFloat = 216
    public static let homeQuotaRingLineWidth: CGFloat = 20
    public static let homeQuotaRingInnerDiameter: CGFloat = 154
    public static let homeQuotaRingInnerLineWidth: CGFloat = 12
    public static let homeQuotaCenterDividerWidth: CGFloat = 40
}

/// Shared workspace grid for every primary destination. Scroll containers stay
/// full width; these values are applied to their content so scroll indicators
/// remain aligned with the workspace's trailing edge.
public enum DirectorPageLayout {
    public static let compactBreakpoint: CGFloat = 760

    public static func horizontalPadding(for width: CGFloat) -> CGFloat {
        width < compactBreakpoint ? DirectorSpacing.compactPagePadding : DirectorSpacing.pagePadding
    }

    public static func contentWidth(for width: CGFloat) -> CGFloat {
        min(
            DirectorSpacing.maxContentWidth,
            max(0, width - horizontalPadding(for: width) * 2)
        )
    }

    /// The content margin includes both the responsive outer gutter and any
    /// extra centering space needed once the 1440 pt content cap is reached.
    public static func contentMargin(for width: CGFloat) -> CGFloat {
        max(horizontalPadding(for: width), (width - DirectorSpacing.maxContentWidth) / 2)
    }

    /// Plain macOS Lists retain an 8 pt internal scroll-content inset even
    /// when their horizontal content margin is zero. Compensate at the row
    /// boundary so the visible row edge matches a ScrollView page exactly.
    public static func listRowInset(for width: CGFloat) -> CGFloat {
        max(0, contentMargin(for: width) - DirectorSpacing.space2)
    }
}

/// Local geometry for the Capability Folders browsing surface.
///
/// This is intentionally a page-scoped variant of the shared workspace grid:
/// the compact folder browser is denser than the editorial library pages, but
/// it must not change the global 1440pt/4-2-1 rules used elsewhere.
public enum DirectorCapabilityFolderLayout {
    public static let entryInlineBreakpoint: CGFloat = 900
    public static let maxContentWidth: CGFloat = 1280
    public static let standardPagePadding: CGFloat = 40
    public static let compactPagePadding: CGFloat = 16
    public static let compactBreakpoint: CGFloat = 760
    public static let narrowBreakpoint: CGFloat = 560
    public static let folderGridGap: CGFloat = 16
    public static let folderGridGapCompact: CGFloat = 12
    public static let folderCardHeight: CGFloat = 128
    public static let folderCardHeightCompact: CGFloat = 120
    public static let folderCardHeightNarrow: CGFloat = 112
    public static let controlHeight: CGFloat = 36
    public static let segmentHeight: CGFloat = 32
    public static let agentGroupGap: CGFloat = 12
    public static let agentGroupGapCompact: CGFloat = 10
    public static let agentHeaderTopPadding: CGFloat = 16
    public static let agentHeaderHorizontalPadding: CGFloat = 18
    public static let agentHeaderBottomPadding: CGFloat = 12
    public static let agentHeaderTopPaddingCompact: CGFloat = 14
    public static let agentHeaderHorizontalPaddingCompact: CGFloat = 14
    public static let agentHeaderBottomPaddingCompact: CGFloat = 10
    public static let skillIndent: CGFloat = 36
    public static let skillIndentCompact: CGFloat = 27
    public static let skillRuleWidth: CGFloat = 2
    public static let skillRuleInset: CGFloat = 14
    public static let skillRuleInsetCompact: CGFloat = 12
    public static let detailWidth: CGFloat = 400

    public static func horizontalPadding(for width: CGFloat) -> CGFloat {
        width < compactBreakpoint ? compactPagePadding : standardPagePadding
    }

    public static func contentWidth(for width: CGFloat) -> CGFloat {
        min(maxContentWidth, max(0, width - horizontalPadding(for: width) * 2))
    }

    public static func contentMargin(for width: CGFloat) -> CGFloat {
        max(horizontalPadding(for: width), (width - maxContentWidth) / 2)
    }

    public static func listRowInset(for width: CGFloat) -> CGFloat {
        max(0, contentMargin(for: width) - DirectorSpacing.space2)
    }

    /// Grid thresholds follow the actual content viewport, not the app
    /// window width. This keeps folder cards readable in side-by-side windows.
    public static func columns(for width: CGFloat) -> Int {
        switch width {
        case 1440...: return 4
        case 901..<1440: return 3
        case 561..<901: return 2
        default: return 1
        }
    }

    public static func cardHeight(for width: CGFloat) -> CGFloat {
        if width <= narrowBreakpoint { return folderCardHeightNarrow }
        if width < compactBreakpoint { return folderCardHeightCompact }
        return folderCardHeight
    }

    public static func gridItems(for width: CGFloat) -> [GridItem] {
        // The column breakpoints describe the actual folder viewport. The
        // caller's row insets still cap the rendered content measure at
        // 1280pt; subtracting the page gutters here would make the 1440pt
        // four-column state unreachable at the viewport boundary.
        let availableViewport = max(0, width)
        let gap = availableViewport < compactBreakpoint ? folderGridGapCompact : folderGridGap
        return Array(repeating: GridItem(.flexible(), spacing: gap), count: columns(for: availableViewport))
    }
}
