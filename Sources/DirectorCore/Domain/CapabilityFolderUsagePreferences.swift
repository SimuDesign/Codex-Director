import Foundation
import Combine

/// Observed usage windows for the folder browser, independent of sort order.
public enum CapabilityFolderUsagePeriod: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    public var id: String { rawValue }

    public static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .sevenDays
    }
}

/// Stores only a bounded period identifier, never folder members or evidence.
/// The app shares one store; tests and validation hosts use memory construction.
public final class CapabilityFolderUsagePreferences: ObservableObject, @unchecked Sendable {
    public static let preferenceKey = "com.peiweitang.CodexDirector.capabilityFolders.usagePeriod"
    @Published public private(set) var period: CapabilityFolderUsagePeriod
    private let writePeriod: (String) -> Void

    public init(defaults: UserDefaults) {
        period = .resolve(defaults.string(forKey: Self.preferenceKey))
        writePeriod = { defaults.set($0, forKey: Self.preferenceKey) }
    }

    public init(memoryPeriod: CapabilityFolderUsagePeriod = .sevenDays) {
        period = memoryPeriod
        writePeriod = { _ in }
    }

    public init(readPeriod: @escaping () -> String?, writePeriod: @escaping (String) -> Void) {
        period = .resolve(readPeriod())
        self.writePeriod = writePeriod
    }

    public func setPeriod(_ period: CapabilityFolderUsagePeriod) {
        guard self.period != period else { return }
        self.period = period
        writePeriod(period.rawValue)
    }
}
