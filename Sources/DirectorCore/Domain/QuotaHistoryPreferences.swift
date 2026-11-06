import Foundation
import Combine

/// App-scoped period selection. Only the period identifier is persisted;
/// historical observations and source identities stay in the derived index.
public final class QuotaHistoryPreferences: ObservableObject, @unchecked Sendable {
    public static let preferenceKey = "com.peiweitang.CodexDirector.quotaHistory.period"

    @Published public private(set) var period: QuotaHistoryPeriod
    private let writePeriod: (String) -> Void

    public init(defaults: UserDefaults) {
        period = QuotaHistoryPeriod.preferenceValue(defaults.string(forKey: Self.preferenceKey))
        writePeriod = { defaults.set($0, forKey: Self.preferenceKey) }
    }

    public init(memoryPeriod: QuotaHistoryPeriod = .thirtyDays) {
        period = memoryPeriod
        writePeriod = { _ in }
    }

    public init(readPeriod: @escaping () -> String?, writePeriod: @escaping (String) -> Void) {
        period = QuotaHistoryPeriod.preferenceValue(readPeriod())
        self.writePeriod = writePeriod
    }

    public func setPeriod(_ period: QuotaHistoryPeriod) {
        guard self.period != period else { return }
        self.period = period
        writePeriod(period.rawValue)
    }
}
