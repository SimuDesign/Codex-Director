import SwiftUI

/// Design-system typography roles (DESIGN_SYSTEM_V1 §7).
/// San Francisco semantic styles only; no custom interface font.
public enum DirectorTypography {
    public static var windowTitle: Font { .title }
    /// Editorial hero scale used by Scheme A. The surrounding header falls
    /// back to a stacked layout at constrained widths rather than shrinking
    /// the identifying title into a toolbar-sized label.
    public static var heroTitle: Font { .system(size: 48, weight: .semibold, design: .rounded) }
    public static var editorialHeroTitle: Font { .system(size: 52, weight: .semibold, design: .rounded) }
    public static var editorialHeroTitleCompact: Font { .system(size: 36, weight: .semibold, design: .rounded) }
    /// Optical companion shared by decorative symbols beside primary page titles.
    public static var pageHeroSymbol: Font { .system(size: 24, weight: .semibold) }
    public static var capabilityHeroSymbol: Font { pageHeroSymbol }
    public static var eyebrow: Font { .system(.caption, design: .monospaced).weight(.semibold) }
    public static var sectionTitle: Font { .headline }
    public static var body: Font { .body }
    public static var supporting: Font { .callout }
    public static var label: Font { .caption }
    /// Monospaced digits for counts, durations, token and timing values.
    public static var data: Font { .system(.body, design: .monospaced) }
    public static var metric: Font { .system(size: 30, weight: .semibold, design: .rounded).monospacedDigit() }
    public static var metricSupporting: Font { .system(.caption, design: .rounded) }
    public static var primaryAction: Font { .system(.body, design: .rounded).weight(.semibold) }
    public static var toolbarAction: Font { .system(.callout, design: .rounded).weight(.semibold) }
    /// Capability ledger row roles, kept distinct from general body/callout
    /// styles so all four library pages share a stable readable hierarchy.
    public static var capabilityRowTitle: Font { .system(size: 16, weight: .semibold) }
    public static var capabilityRowSummary: Font { .system(size: 14, weight: .regular) }
    public static var capabilityRowCount: Font { .system(size: 16, weight: .semibold, design: .monospaced) }
    public static var capabilityRowCountLabel: Font { .system(size: 13, weight: .medium) }
    /// Home-only numeric roles. Avenir Next is intentionally scoped to
    /// numbers in the Card Atlas composition; interface prose stays native.
    public static var homeMetric: Font { .custom("Avenir Next", size: 34).weight(.semibold).monospacedDigit() }
    public static var homePercentage: Font { .custom("Avenir Next", size: 42).weight(.semibold).monospacedDigit() }
    public static var homeTimestamp: Font { .custom("Avenir Next", size: 13).monospacedDigit() }
    public static var homeRank: Font { .custom("Avenir Next", size: 12).weight(.semibold).monospacedDigit() }
    public static var homeRankCount: Font { .custom("Avenir Next", size: 16).weight(.semibold).monospacedDigit() }
    /// System monospaced for parser types, tool identifiers, redacted paths.
    public static var code: Font { .system(.callout, design: .monospaced) }
}
