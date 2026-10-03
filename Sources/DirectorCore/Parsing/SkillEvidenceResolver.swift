import Foundation

/// Conservative Skill evidence resolution (MVP1 policy).
///
/// Only these production signals are allowed:
/// - `exact`: a structured `skill_invoked` event identifies exactly one
///   currently discovered Skill.
/// - `inferred`: a literal read operation references uniquely resolved
///   discovered `SKILL.md` manifests. Paths are used only in memory; a batch
///   result does not establish success of each individual read.
/// - `unknown`: a structured event or actual manifest-read signal exists, but
///   zero or multiple current Skills can be resolved.
///
/// Forbidden: a Skill name merely appearing in a system prompt, Skill list,
/// user/assistant message, reasoning block, or tool output; natural-language
/// guessing; converting a read signal to `exact`. The matched path, raw
/// input, command, message text, and output are never persisted.
public struct SkillEvidenceResolver: Sendable {

    public struct Candidate: Sendable, Equatable {
        public let resourceID: String
        public let name: String
        public let relativeSourcePath: String
        fileprivate let absoluteSourcePath: String?
        fileprivate let projectID: String?

        public init(resourceID: String, name: String, relativeSourcePath: String, absoluteSourcePath: String? = nil, projectID: String? = nil) {
            self.resourceID = resourceID
            self.name = name
            self.relativeSourcePath = relativeSourcePath
            self.absoluteSourcePath = absoluteSourcePath
            self.projectID = projectID
        }
    }

    /// Normalized resolution: identity plus honest confidence.
    public struct ResolvedSkill: Sendable, Equatable {
        public let resourceID: String?
        public let confidence: EvidenceConfidence

        public init(resourceID: String?, confidence: EvidenceConfidence) {
            self.resourceID = resourceID
            self.confidence = confidence
        }
    }

    /// Transient manifest index from current discovered Skill resources.
    public let candidates: [Candidate]

    public init(resources: [CapabilityResource], roots: [ScanRoot] = [], transientRoots: [String: URL] = [:]) {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.url) })
        self.candidates = resources
            .filter { $0.kind == .skill }
            .compactMap { resource in
                guard let relative = resource.relativeSourcePath, !relative.isEmpty else { return nil }
                return Candidate(
                    resourceID: resource.id,
                    name: resource.name,
                    relativeSourcePath: relative.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "./", with: ""),
                    absoluteSourcePath: Self.absolutePath(relative: relative, sourceRootID: resource.sourceRootID, rootsByID: rootsByID, transientRoots: transientRoots), projectID: resource.projectID
                )
            }
    }

    private static func absolutePath(relative: String, sourceRootID: String, rootsByID: [String: URL], transientRoots: [String: URL]) -> String? {
        if let root = rootsByID[sourceRootID] { return root.appendingPathComponent(relative).standardizedFileURL.path }
        guard let root = transientRoots[sourceRootID] else { return nil }
        let marker = sourceRootID.replacingOccurrences(of: "runtime-plugins:", with: "")
        let prefix = "plugins/\(marker)/"
        let child = relative.hasPrefix(prefix) ? String(relative.dropFirst(prefix.count)) : relative
        return root.appendingPathComponent(child).standardizedFileURL.path
    }

    /// Structured `skill_invoked` event: exact when exactly one current Skill
    /// matches by name, otherwise unknown.
    public func resolveStructuredEvent(skillName: String, projectID: String? = nil) -> ResolvedSkill {
        let explicit = candidates.filter { $0.resourceID == skillName }
        if explicit.count == 1 { return ResolvedSkill(resourceID: explicit[0].resourceID, confidence: .exact) }
        let all = candidates.filter { $0.name == skillName }
        let local = projectID.map { project in all.filter { $0.projectID == project } } ?? []
        let matches = local.isEmpty ? all.filter { $0.projectID == nil } : local
        switch matches.count {
        case 1:
            return ResolvedSkill(resourceID: matches[0].resourceID, confidence: .exact)
        default:
            return ResolvedSkill(resourceID: nil, confidence: .unknown)
        }
    }

    /// Manifest-read signal from a tool-call input. The operation must be a
    /// real read: a read-capable tool, or a shell whose command contains a
    /// read-only token and no write/delete/mutation operator. A write,
    /// delete, search, or plain-text reference of a manifest path is never
    /// evidence. Returns nil when there is no read signal; otherwise inferred
    /// for exactly one matching candidate, unknown for zero or multiple.
    public func resolveManifestReadSignal(input: String, toolName: String?) -> ResolvedSkill? {
        let results = resolveManifestReadSignals(input: input, toolName: toolName)
        if results.count > 1 { return ResolvedSkill(resourceID: nil, confidence: .unknown) }
        return results.first
    }

    public func resolveManifestReadSignals(input: String, toolName: String?, projectID: String? = nil, workingDirectory: String? = nil) -> [ResolvedSkill] {
        let paths = candidates.map {
            ManifestReadCandidate(key: $0.resourceID, relativePath: $0.relativeSourcePath, absolutePath: $0.absoluteSourcePath, projectID: $0.projectID)
        }
        guard let keys = ManifestReadEvidence.matchingCandidateKeys(input: input, toolName: toolName, candidates: paths, projectID: projectID, workingDirectory: workingDirectory), !keys.isEmpty else {
            return []
        }
        return keys.sorted().map { ResolvedSkill(resourceID: $0, confidence: .inferred) }
    }
}
