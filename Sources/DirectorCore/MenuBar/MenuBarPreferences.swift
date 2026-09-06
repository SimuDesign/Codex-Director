import Foundation
import Combine

/// App-owned preference for the user-controlled menu-bar surface.
///
/// Only the enabled flag is persisted. Earlier development builds briefly
/// stored a quota-source selection; that value is removed on first production
/// read and is not represented in this public type.
public final class MenuBarPreferences: ObservableObject, @unchecked Sendable {
    public static let enabledKey = "com.peiweitang.CodexDirector.menuBar.enabled"
    private static let legacySelectedQuotaSourceKey = "com.peiweitang.CodexDirector.menuBar.quotaSource"

    public struct Snapshot: Equatable, Sendable {
        public let isEnabled: Bool
        public init(isEnabled: Bool) { self.isEnabled = isEnabled }
    }

    private let writeEnabled: (Bool) -> Void
    @Published public private(set) var isEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.legacySelectedQuotaSourceKey)
        _isEnabled = Published(initialValue: defaults.object(forKey: Self.enabledKey) as? Bool ?? true)
        writeEnabled = {
            defaults.set($0, forKey: Self.enabledKey)
        }
    }

    /// Pure-memory construction for tests and validation hosts. Each instance
    /// owns isolated storage and never consults production UserDefaults.
    public init(memoryEnabled: Bool = true) {
        let storage = MenuBarMemoryPreferences(isEnabled: memoryEnabled)
        isEnabled = memoryEnabled
        writeEnabled = { storage.setEnabled($0) }
    }

    /// Injectable construction for deterministic preference-boundary tests.
    public init(
        readEnabled: @escaping () -> Bool?,
        writeEnabled: @escaping (Bool) -> Void
    ) {
        isEnabled = readEnabled() ?? true
        self.writeEnabled = writeEnabled
    }

    public func snapshot() -> Snapshot { Snapshot(isEnabled: isEnabled) }

    public func setEnabled(_ isEnabled: Bool) {
        writeEnabled(isEnabled)
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
    }

}

private final class MenuBarMemoryPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MenuBarPreferences.Snapshot

    init(isEnabled: Bool) { value = .init(isEnabled: isEnabled) }

    func read() -> MenuBarPreferences.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        value = .init(isEnabled: isEnabled)
        lock.unlock()
    }
}
