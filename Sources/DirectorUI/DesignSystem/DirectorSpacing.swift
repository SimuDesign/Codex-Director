import CoreGraphics

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
