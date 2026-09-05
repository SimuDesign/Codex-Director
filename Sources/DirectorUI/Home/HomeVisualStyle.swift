import AppKit
import SwiftUI

/// Home-facing aliases for the shared Director visual tokens. The aliases keep
/// the Home call sites readable while ensuring every content surface consumes
/// the same canvas/panel/spacing contract.
enum HomeVisual {
    static let canvas = DirectorColor.canvas
    static let panel = DirectorColor.panel
    static let inset = DirectorColor.inset
    static let boundary = DirectorColor.boundary
    static let emphasis = DirectorColor.emphasis

    static let moduleGap = DirectorSpacing.moduleGap
    static let panelRadius = DirectorRadius.homeModule

}

enum HomeLayout {
    static let maxContentWidth = DirectorSpacing.maxContentWidth
    static let standardPadding = DirectorSpacing.pagePadding
    static let compactPadding = DirectorSpacing.compactPagePadding

    static func horizontalPadding(for width: CGFloat) -> CGFloat {
        DirectorPageLayout.horizontalPadding(for: width)
    }

    static func contentWidth(for width: CGFloat) -> CGFloat {
        DirectorPageLayout.contentWidth(for: width)
    }

    /// The quota stage is a ring/evidence column beside the seven-day chart
    /// only when the measured content can keep both readable. The decision is
    /// based on content width rather than the outer window frame.
    static func quotaColumns(for width: CGFloat) -> Int {
        width >= 760 ? 2 : 1
    }

    /// The inventory strip follows the approved 4/2/1 responsive grammar.
    static func metricColumns(for width: CGFloat) -> Int {
        width >= 760 ? 4 : (width >= 420 ? 2 : 1)
    }

    static func rankingColumns(for width: CGFloat) -> Int {
        width >= 1000 ? 3 : 1
    }
}

/// A compact, predictable percentage scale keeps ordinary daily allowance use
/// legible without implying more precision than the reported source provides.
enum HomeQuotaChartScale {
    static func axisMaximum(for values: [Double]) -> Double {
        let maximum = values.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        switch maximum {
        case ...10: return 10
        case ...20: return 20
        case ...50: return 50
        case ...100: return 100
        default: return ceil(maximum / 50) * 50
        }
    }
}

private struct HomeSecondaryTextModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content.foregroundStyle(DirectorColor.textSecondary.opacity(colorSchemeContrast == .increased ? 1 : 0.9))
    }
}

extension View {
    func homeSecondaryText() -> some View {
        modifier(HomeSecondaryTextModifier())
    }
}
