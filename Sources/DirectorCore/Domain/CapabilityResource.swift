import Foundation

/// Resource types inventoried by Codex Director.
public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case agent
    case skill
    /// Project-level instructions (`AGENTS.md`). Instructions are not Agents.
    case instruction
    case workflow
    case tool
    case plugin
    case mcp
    case app
    case hook
    case output
    case unknown
}

/// Ownership/classification shown by the personal capability inventory.
public enum ResourceOwnership: String, Codable, Sendable, CaseIterable {
    case userOwned
    case installed
    case builtIn
    case pluginProvided
    case runtime
    case unknown
}

/// Provenance family used for safe, local-only source attribution.
public enum ResourceOrigin: String, Codable, Sendable, CaseIterable {
    case local
    case github
    case registry
    case codexSystem
    case plugin
    case runtime
    case unknown
}

/// Where a resource lives.
public enum ResourceScope: String, Codable, Sendable, CaseIterable {
    case system
    case global
    case project
    case plugin
    case runtime
    case unknown
}

/// Current runtime status of a resource. Distinct from `ResourceKind`:
/// a failed Skill remains a Skill-kind resource with a failure status.
public enum RuntimeStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case success
    case warning
    case failure
    case blocked
    case unknown
}

/// A source record proving where a logical capability came from. Values are
/// deliberately redacted to owner/repo or registry slugs; full URLs and
/// absolute paths never cross the persistence boundary.
public struct CapabilityProvenance: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let resourceID: String
    public let sourceType: ResourceOrigin
    public let sourceIdentifier: String?
    public let version: String?
    public let installedAt: Date?
    public let updatedAt: Date?
    public let confidence: EvidenceConfidence
    public let modified: Bool

    public init(
        id: String,
        resourceID: String,
        sourceType: ResourceOrigin,
        sourceIdentifier: String?,
        version: String?,
        installedAt: Date?,
        updatedAt: Date?,
        confidence: EvidenceConfidence,
        modified: Bool = false
    ) {
        self.id = id
        self.resourceID = resourceID
        self.sourceType = sourceType
        self.sourceIdentifier = sourceIdentifier
        self.version = version
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.confidence = confidence
        self.modified = modified
    }
}

/// Privacy-safe project descriptor. The stable ID is derived from the path,
/// but the path itself is never persisted.
public struct CapabilityProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let available: Bool
    public let lastSeenAt: Date

    public init(id: String, name: String, available: Bool = true, lastSeenAt: Date = Date()) {
        self.id = id
        self.name = name
        self.available = available
        self.lastSeenAt = lastSeenAt
    }
}

/// A discovered capability: Agent, Skill, Workflow, Tool, Plugin, MCP, App,
/// Hook, or Output. Source files remain the source of truth; this value is a
/// normalized, indexable projection.
public struct CapabilityResource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: ResourceKind
    public let status: RuntimeStatus
    public let scope: ResourceScope
    public let projectID: String?
    public let confidence: EvidenceConfidence
    public let summary: String?
    public let sourceRootID: String
    public let relativeSourcePath: String?
    public let sourcePathHash: String?
    public let lastSeenAt: Date
    public let ownership: ResourceOwnership
    public let origin: ResourceOrigin
    public let classificationConfidence: EvidenceConfidence
    public let originIdentifier: String?
    public let sourceVersion: String?
    public let contentFingerprint: String?
    public let sourceModifiedAt: Date?
    public let modified: Bool

    public init(
        id: String,
        name: String,
        kind: ResourceKind,
        status: RuntimeStatus,
        scope: ResourceScope,
        projectID: String?,
        confidence: EvidenceConfidence,
        summary: String?,
        sourceRootID: String,
        relativeSourcePath: String?,
        sourcePathHash: String?,
        lastSeenAt: Date,
        ownership: ResourceOwnership? = nil,
        origin: ResourceOrigin? = nil,
        classificationConfidence: EvidenceConfidence? = nil,
        originIdentifier: String? = nil,
        sourceVersion: String? = nil,
        contentFingerprint: String? = nil,
        sourceModifiedAt: Date? = nil,
        modified: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.scope = scope
        self.projectID = projectID
        self.confidence = confidence
        self.summary = summary
        self.sourceRootID = sourceRootID
        self.relativeSourcePath = relativeSourcePath
        self.sourcePathHash = sourcePathHash
        self.lastSeenAt = lastSeenAt
        self.ownership = ownership ?? Self.defaultOwnership(kind: kind, scope: scope)
        self.origin = origin ?? Self.defaultOrigin(scope: scope, ownership: self.ownership)
        self.classificationConfidence = classificationConfidence ?? confidence
        self.originIdentifier = originIdentifier
        self.sourceVersion = sourceVersion
        self.contentFingerprint = contentFingerprint
        self.sourceModifiedAt = sourceModifiedAt
        self.modified = modified
    }

    /// Only independent filesystem Skills can be corrected by the user.
    /// System, plugin-provided, and runtime capabilities keep immutable source
    /// ownership even when they share the Skill kind.
    public var isSkillClassificationCorrectable: Bool {
        kind == .skill
            && (scope == .global || scope == .project)
            && (ownership == .userOwned || ownership == .installed)
    }

    /// Normalizes the provenance family used by a manual binary correction.
    /// Exact install provenance is retained when it already exists; otherwise
    /// an installed correction is explicitly source-unknown.
    public func manualClassificationOrigin(for ownership: ResourceOwnership) -> ResourceOrigin {
        switch ownership {
        case .userOwned:
            return .local
        case .installed:
            if self.ownership == .installed, origin == .github || origin == .registry {
                return origin
            }
            return .unknown
        default:
            return origin
        }
    }

    private static func defaultOwnership(kind: ResourceKind, scope: ResourceScope) -> ResourceOwnership {
        switch scope {
        case .system: return .builtIn
        case .plugin: return .pluginProvided
        case .runtime: return .runtime
        case .global, .project:
            return (kind == .agent || kind == .skill || kind == .instruction) ? .userOwned : .unknown
        case .unknown: return .unknown
        }
    }

    private static func defaultOrigin(scope: ResourceScope, ownership: ResourceOwnership) -> ResourceOrigin {
        switch ownership {
        case .builtIn: return .codexSystem
        case .pluginProvided: return .plugin
        case .runtime: return .runtime
        case .userOwned: return .local
        default:
            switch scope {
            case .system: return .codexSystem
            case .plugin: return .plugin
            case .runtime: return .runtime
            default: return .unknown
            }
        }
    }
}
