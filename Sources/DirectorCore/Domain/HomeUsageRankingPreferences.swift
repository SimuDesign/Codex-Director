import Foundation
import Combine

/// The bounded usage windows available to the Home ranking module.
public enum HomeUsageRankingPeriod: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case sevenDays = "7d"
    case thirtyDays = "30d"

    public var id: String { rawValue }

    /// Invalid or missing persisted values intentionally resolve to the
    /// familiar seven-day view for a deterministic first launch.
    public static func resolve(_ rawValue: String?) -> Self {
        guard let rawValue, let period = Self(rawValue: rawValue) else { return .sevenDays }
        return period
    }
}

/// App-owned selection for the Home usage ranking period.
///
/// The store persists only the period identifier. It never stores ranking
/// rows, resource names, paths, or invocation data. Memory and closure-backed
/// initializers keep validation hosts and tests isolated from production
/// preferences.
public final class HomeUsageRankingPreferences: ObservableObject, @unchecked Sendable {
    public static let preferenceKey = "com.peiweitang.CodexDirector.homeUsageRanking.period"

    private let writePeriod: (String) -> Void
    @Published public private(set) var period: HomeUsageRankingPeriod

    public convenience init() {
        self.init(defaults: .standard)
    }

    public init(defaults: UserDefaults) {
        period = HomeUsageRankingPeriod.resolve(defaults.string(forKey: Self.preferenceKey))
        writePeriod = { rawValue in
            defaults.set(rawValue, forKey: Self.preferenceKey)
        }
    }

    /// Pure-memory construction for tests and the debug validation host.
    public init(memoryPeriod: HomeUsageRankingPeriod = .sevenDays) {
        period = memoryPeriod
        writePeriod = { _ in }
    }

    /// Injectable persistence boundary for deterministic preference tests.
    public init(
        readPeriod: @escaping () -> String?,
        writePeriod: @escaping (String) -> Void
    ) {
        period = HomeUsageRankingPeriod.resolve(readPeriod())
        self.writePeriod = writePeriod
    }

    public func snapshot() -> HomeUsageRankingPeriod { period }

    public func setPeriod(_ period: HomeUsageRankingPeriod) {
        guard self.period != period else { return }
        self.period = period
        writePeriod(period.rawValue)
    }

    public func setPeriod(rawValue: String?) {
        setPeriod(HomeUsageRankingPeriod.resolve(rawValue))
    }
}
