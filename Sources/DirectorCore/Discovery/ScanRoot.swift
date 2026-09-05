import Foundation

/// A declared, approved root to scan.
///
/// Roots are always explicit — the user's home path is never embedded in
/// source. The scanner performs read-only walks inside each root only.
public struct ScanRoot: Sendable, Equatable, Hashable {
    /// Stable identifier used in resource identity and source references.
    public let id: String
    /// Absolute location of the root.
    public let url: URL
    /// Scope assigned to resources discovered under this root.
    public let scope: ResourceScope
    /// How the scanner interprets this root.
    public let kind: ScanRootKind

    public init(id: String, url: URL, scope: ResourceScope, kind: ScanRootKind) {
        self.id = id
        self.url = url
        self.scope = scope
        self.kind = kind
    }
}

/// Filesystem interpretation of a scan root.
public enum ScanRootKind: String, Sendable, Equatable, Hashable {
    /// A directory of `*/SKILL.md` manifests.
    case skills
    /// A directory of `*/agent.md` briefs.
    case agents
    /// A plugin cache tree containing `.codex-plugin` marker directories.
    case plugins
    /// A project directory with optional `AGENTS.md`, skills, agents, registry.
    case projects
}
