/// DirectorCore — read-only domain, discovery, parsing, persistence, and review
/// logic for Codex Director.
///
/// Contract: this target must not import SwiftUI or AppKit. It exposes plain
/// value types and actor-isolated services consumed by DirectorUI.
public enum DirectorCore {
    /// Stable library identity, used by bootstrap tests and diagnostics.
    public static let libraryName = "DirectorCore"

    /// Current derived-index schema contract version.
    /// Maps to SQLite `PRAGMA user_version`; bumped only by an approved migration.
    public static let schemaVersion = 1
}
