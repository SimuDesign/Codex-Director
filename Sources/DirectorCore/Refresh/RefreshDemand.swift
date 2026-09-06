/// The highest active application surface that may request refresh work.
///
/// Multiple surfaces collapse to one value before reaching the shared refresh
/// coordinator. This type describes demand only; it does not create a timer,
/// database connection, indexer, or polling loop.
public enum RefreshDemand: Int, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case none = 0
    case menuBarPassive = 1
    case menuBarPopover = 2
    case mainWindow = 3

    public var requestsWork: Bool {
        switch self {
        case .none, .menuBarPassive: false
        case .menuBarPopover, .mainWindow: true
        }
    }

    public var isCacheOnly: Bool {
        self == .menuBarPassive
    }

    public var requestsQuotaRefresh: Bool {
        switch self {
        case .none, .menuBarPassive, .menuBarPopover: false
        case .mainWindow: true
        }
    }

    public var requestsCapabilityRefresh: Bool {
        self == .mainWindow
    }

    public var requestsAccountUsageRefresh: Bool {
        switch self {
        case .menuBarPopover, .mainWindow: true
        case .none, .menuBarPassive: false
        }
    }

    public var permitsSourceRefresh: Bool {
        switch self {
        case .none, .menuBarPassive, .menuBarPopover: false
        case .mainWindow: true
        }
    }

    public func merged(with other: RefreshDemand) -> RefreshDemand {
        rawValue >= other.rawValue ? self : other
    }

    public static func merged<S: Sequence>(_ demands: S) -> RefreshDemand
    where S.Element == RefreshDemand {
        demands.reduce(.none) { $0.merged(with: $1) }
    }

    public static func resolve(
        mainWindowIsVisible: Bool,
        menuBarIsEnabled: Bool,
        menuBarPopoverIsPresented: Bool
    ) -> RefreshDemand {
        if mainWindowIsVisible { return .mainWindow }
        guard menuBarIsEnabled else { return .none }
        return menuBarPopoverIsPresented ? .menuBarPopover : .menuBarPassive
    }
}
