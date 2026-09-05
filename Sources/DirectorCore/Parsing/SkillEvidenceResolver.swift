import Foundation

/// Conservative Skill evidence resolution (MVP1 policy).
///
/// Only these production signals are allowed:
/// - `exact`: a structured `skill_invoked` event identifies exactly one
///   currently discovered Skill.
/// - `inferred`: an actual tool-call input transiently references exactly one
///   currently discovered `SKILL.md` manifest. The tool call is execution
///   evidence; the manifest path is used only in memory to resolve the Skill.
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

        public init(resourceID: String, name: String, relativeSourcePath: String, absoluteSourcePath: String? = nil) {
            self.resourceID = resourceID
            self.name = name
            self.relativeSourcePath = relativeSourcePath
            self.absoluteSourcePath = absoluteSourcePath
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
                    absoluteSourcePath: Self.absolutePath(relative: relative, sourceRootID: resource.sourceRootID, rootsByID: rootsByID, transientRoots: transientRoots)
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
    public func resolveStructuredEvent(skillName: String) -> ResolvedSkill {
        let matches = candidates.filter { $0.name == skillName }
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
        let paths = candidates.map {
            ManifestReadCandidate(key: $0.resourceID, relativePath: $0.relativeSourcePath, absolutePath: $0.absoluteSourcePath)
        }
        guard let keys = ManifestReadEvidence.matchingCandidateKeys(input: input, toolName: toolName, candidates: paths), !keys.isEmpty else {
            return nil
        }
        guard keys.count == 1, let resourceID = keys.first else {
            return ResolvedSkill(resourceID: nil, confidence: .unknown)
        }
        return ResolvedSkill(resourceID: resourceID, confidence: .inferred)
    }
}
