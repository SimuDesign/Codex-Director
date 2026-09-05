import Foundation

/// App-owned menu-bar preferences.
///
/// The store is deliberately independent from account and runtime settings.
/// It persists only whether the optional surface is enabled and the stable ID
/// of the quota source selected by the user.
public final class MenuBarPreferences: @unchecked Sendable {
    public static let enabledKey = "com.peiweitang.CodexDirector.menuBar.enabled"
    public static let selectedQuotaSourceKey = "com.peiweitang.CodexDirector.menuBar.quotaSource"

    public struct Snapshot: Equatable, Sendable {
        public let isEnabled: Bool
        public let selectedQuotaSourceID: String?

        public init(isEnabled: Bool, selectedQuotaSourceID: String?) {
            self.isEnabled = isEnabled
            self.selectedQuotaSourceID = selectedQuotaSourceID
        }
    }

    private let readEnabled: () -> Bool?
    private let readSelectedQuotaSourceID: () -> String?
    private let writeEnabled: (Bool) -> Void
    private let writeSelectedQuotaSourceID: (String) -> Void
    private let removeSelectedQuotaSourceID: () -> Void

    public init(defaults: UserDefaults = .standard) {
        readEnabled = {
            defaults.object(forKey: Self.enabledKey) as? Bool
        }
        readSelectedQuotaSourceID = {
            defaults.object(forKey: Self.selectedQuotaSourceKey) as? String
        }
        writeEnabled = {
            defaults.set($0, forKey: Self.enabledKey)
        }
        writeSelectedQuotaSourceID = {
            defaults.set($0, forKey: Self.selectedQuotaSourceKey)
        }
        removeSelectedQuotaSourceID = {
            defaults.removeObject(forKey: Self.selectedQuotaSourceKey)
        }
    }

    /// Pure-memory construction for tests and validation hosts. Each instance
    /// owns isolated storage and never consults production UserDefaults.
    public init(memoryEnabled: Bool = false, selectedQuotaSourceID: String? = nil) {
        let storage = MenuBarMemoryPreferences(
            isEnabled: memoryEnabled,
            selectedQuotaSourceID: Self.validatedSourceID(selectedQuotaSourceID)
        )
        readEnabled = { storage.read().isEnabled }
        readSelectedQuotaSourceID = { storage.read().selectedQuotaSourceID }
        writeEnabled = { storage.setEnabled($0) }
        writeSelectedQuotaSourceID = { storage.setSelectedQuotaSourceID($0) }
        removeSelectedQuotaSourceID = { storage.setSelectedQuotaSourceID(nil) }
    }

    /// Injectable construction for deterministic preference-boundary tests.
    public init(
        readEnabled: @escaping () -> Bool?,
        readSelectedQuotaSourceID: @escaping () -> String?,
        writeEnabled: @escaping (Bool) -> Void,
        writeSelectedQuotaSourceID: @escaping (String) -> Void,
        removeSelectedQuotaSourceID: @escaping () -> Void
    ) {
        self.readEnabled = readEnabled
        self.readSelectedQuotaSourceID = readSelectedQuotaSourceID
        self.writeEnabled = writeEnabled
        self.writeSelectedQuotaSourceID = writeSelectedQuotaSourceID
        self.removeSelectedQuotaSourceID = removeSelectedQuotaSourceID
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            isEnabled: readEnabled() ?? false,
            selectedQuotaSourceID: Self.validatedSourceID(readSelectedQuotaSourceID())
        )
    }

    public func setEnabled(_ isEnabled: Bool) {
        writeEnabled(isEnabled)
    }

    @discardableResult
    public func setSelectedQuotaSourceID(_ sourceID: String) -> Bool {
        guard let sourceID = Self.validatedSourceID(sourceID) else { return false }
        writeSelectedQuotaSourceID(sourceID)
        return snapshot().selectedQuotaSourceID == sourceID
    }

    public func clearSelectedQuotaSourceID() {
        removeSelectedQuotaSourceID()
    }

    private static func validatedSourceID(_ sourceID: String?) -> String? {
        guard let sourceID,
              !sourceID.isEmpty,
              sourceID.utf8.count <= 512,
              sourceID.trimmingCharacters(in: .whitespacesAndNewlines) == sourceID,
              sourceID.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return sourceID
    }
}

private final class MenuBarMemoryPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MenuBarPreferences.Snapshot

    init(isEnabled: Bool, selectedQuotaSourceID: String?) {
        value = .init(
            isEnabled: isEnabled,
            selectedQuotaSourceID: selectedQuotaSourceID
        )
    }

    func read() -> MenuBarPreferences.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        value = .init(
            isEnabled: isEnabled,
            selectedQuotaSourceID: value.selectedQuotaSourceID
        )
        lock.unlock()
    }

    func setSelectedQuotaSourceID(_ sourceID: String?) {
        lock.lock()
        value = .init(isEnabled: value.isEnabled, selectedQuotaSourceID: sourceID)
        lock.unlock()
    }
}
