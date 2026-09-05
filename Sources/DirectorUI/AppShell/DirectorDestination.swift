import Foundation

/// Primary destinations (approved MVP1 product decision).
public enum DirectorDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case capabilities
    case tasks
    case review
    case usage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .capabilities: return "Capabilities"
        case .tasks: return "Tasks"
        case .review: return "Review"
        case .usage: return "Usage"
        }
    }

    public var symbol: String {
        switch self {
        case .home: return DirectorSymbol.home
        case .capabilities: return DirectorSymbol.capabilities
        case .tasks: return DirectorSymbol.tasks
        case .review: return DirectorSymbol.review
        case .usage: return DirectorSymbol.usage
        }
    }
}

/// Utility destinations shown in a separate sidebar section.
public enum DirectorUtility: String, CaseIterable, Identifiable, Hashable {
    case dataStatus
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataStatus: return "Data Status"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .dataStatus: return DirectorSymbol.dataStatus
        case .settings: return DirectorSymbol.settings
        }
    }
}

/// Unified sidebar selection model: primary destination or utility.
///
/// Deliberately a flat, raw-value enum: `List(selection:)` on macOS 26 fails
/// to render rows when the selection value type uses associated values (the
/// previous `case destination(DirectorDestination) / case utility(...)` shape
/// produced an empty sidebar).
public enum DirectorSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home
    case customAgents
    case customSkills
    case installedSkills
    case installedPlugins
    case settings

    // Legacy destinations remain decodable for old deep links, but are not
    // presented as first-level navigation in the 0.2 shell.
    case capabilities
    case tasks
    case review
    case usage
    case dataStatus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .customAgents: return "Custom Agents"
        case .customSkills: return "Custom Skills"
        case .installedSkills: return "Installed Skills"
        case .installedPlugins: return "Installed Plugins"
        case .capabilities: return "Capabilities"
        case .tasks: return "Tasks"
        case .review: return "Review"
        case .usage: return "Usage"
        case .dataStatus: return "Data Status"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .home: return DirectorSymbol.home
        case .customAgents: return DirectorSymbol.category(.customAgents)
        case .customSkills: return DirectorSymbol.category(.customSkills)
        case .installedSkills: return DirectorSymbol.category(.installedSkills)
        case .installedPlugins: return DirectorSymbol.category(.installedPlugins)
        case .capabilities: return DirectorSymbol.capabilities
        case .tasks: return DirectorSymbol.tasks
        case .review: return DirectorSymbol.review
        case .usage: return DirectorSymbol.usage
        case .dataStatus: return DirectorSymbol.dataStatus
        case .settings: return DirectorSymbol.settings
        }
    }

    public var isUtility: Bool {
        switch self {
        case .dataStatus, .settings: return true
        default: return false
        }
    }

    public static var approvedNavigation: [Self] {
        [.home, .customAgents, .customSkills, .installedSkills, .installedPlugins, .settings]
    }
}
