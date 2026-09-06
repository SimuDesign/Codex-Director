import AppKit
import DirectorCore

/// Required SF Symbols (DESIGN_SYSTEM_V1 §6.3, §11, §12).
/// Every symbol is validated against the current SDK by `isValid` and the
/// symbol-contract test; missing symbols fail the contract and require an
/// approved replacement rather than a silent substitution.
public enum DirectorSymbol {

    public static func category(_ category: CapabilityCategory) -> String {
        switch category { case .customAgents: return "person.crop.circle"; case .customSkills: return "sparkles"; case .installedSkills: return "shippingbox"; case .installedPlugins: return "puzzlepiece.extension" }
    }

    public static func summaryMetric(_ kind: CapabilitySummaryMetricKind) -> String {
        switch kind { case .global: return "globe"; case .project: return "folder"; case .recent7: return "clock.arrow.circlepath"; case .notUsed30: return "calendar.badge.exclamationmark"; case .installed: return "checkmark.circle"; case .enabled: return "checkmark.circle"; case .attributionUnavailable: return "tray.full" }
    }

    // MARK: Resource-type symbols (§6.3)

    public static func resource(_ kind: ResourceKind) -> String {
        switch kind {
        case .agent: return "person.crop.circle"
        case .skill: return "sparkles"
        case .instruction: return "doc.badge.gearshape"
        case .workflow: return "arrow.triangle.branch"
        case .tool: return "wrench.and.screwdriver"
        case .plugin: return "puzzlepiece.extension"
        case .mcp: return "link"
        case .app: return "macwindow"
        case .hook: return "bolt"
        case .output: return "doc.text"
        case .unknown: return "questionmark.circle"
        }
    }

    // MARK: Runtime-status redundant signal symbols (§6.2)

    public static func status(_ status: RuntimeStatus) -> String {
        switch status {
        case .idle: return "pause.circle"
        case .running: return "circle.hexagongrid"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.circle"
        case .blocked: return "hand.raised"
        case .unknown: return "questionmark.circle"
        }
    }

    // MARK: Destinations

    public static let capabilities = "square.grid.2x2"
    public static let home = "house"
    public static let tasks = "clock.arrow.circlepath"
    public static let review = "checkmark.seal"
    public static let usage = "chart.bar"
    public static let dataStatus = "cylinder.split.1x2"
    public static let settings = "gearshape"
    /// Standard native inspector dismissal control.
    public static let closeInspector = "xmark"
    public static let usageEvidence = "doc.text.magnifyingglass"
    public static let search = "magnifyingglass"
    public static let filter = "line.3.horizontal.decrease.circle"
    public static let back = "chevron.backward"
    public static let menuBarUsage = "gauge.with.dots.needle.50percent"

    /// Every symbol the design system requires, for the contract test.
    public static let requiredSymbols: [String] = {
        var names: [String] = [
            home, capabilities, tasks, review, usage, dataStatus, settings,
            closeInspector,
            usageEvidence, search, filter, back,
            menuBarUsage,
        ]
        for kind in ResourceKind.allCases {
            names.append(resource(kind))
        }
        for category in CapabilityCategory.allCases {
            names.append(DirectorSymbol.category(category))
        }
        for metric in CapabilitySummaryMetricKind.allCases {
            names.append(summaryMetric(metric))
        }
        for runtimeStatus in RuntimeStatus.allCases {
            names.append(status(runtimeStatus))
        }
        return names
    }()

    /// True when the symbol exists in the current SDK.
    public static func isValid(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
