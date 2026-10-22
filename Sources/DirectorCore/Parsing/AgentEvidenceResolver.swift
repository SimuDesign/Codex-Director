import Foundation

/// Conservative Agent evidence resolution.
///
/// Lifecycle requests alone are not confirmed Agent launches. The extractor
/// separately handles authoritative child-session metadata; this resolver
/// maps structured identities and real reads of uniquely discovered Agent
/// configurations/Briefs. Prompt text, task names, and system context are
/// never evidence. Paths and transient inputs remain in memory only.
public struct AgentEvidenceResolver: Sendable {

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

    public struct ResolvedAgent: Sendable, Equatable {
        public let resourceID: String?
        public let confidence: EvidenceConfidence

        public init(resourceID: String?, confidence: EvidenceConfidence) {
            self.resourceID = resourceID
            self.confidence = confidence
        }
    }

    public let candidates: [Candidate]
    private let roots: [ScanRoot]

    public init(resources: [CapabilityResource], roots: [ScanRoot] = [], pairings: [CapabilityAgentPairing] = []) {
        self.roots = roots
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.url) })
        self.candidates = resources
            .filter { $0.kind == .agent && $0.origin != .plugin && $0.origin != .codexSystem && $0.scope != .system && $0.scope != .plugin }
            .flatMap { resource -> [Candidate] in
                guard let relative = resource.relativeSourcePath, !relative.isEmpty else { return [] }
                let aliases = pairings.filter { $0.sourceRootID == resource.sourceRootID && $0.agentRelativePath == relative }
                    .flatMap { [$0.briefRelativePath, $0.configurationRelativePath] }
                return Set([relative] + aliases).sorted().map { path in
                    Candidate(resourceID: resource.id, name: resource.name, relativeSourcePath: Self.normalize(path),
                        absoluteSourcePath: rootsByID[resource.sourceRootID]?.appendingPathComponent(path).standardizedFileURL.path,
                        projectID: resource.projectID)
                }
            }
    }

    /// Exact only when the structured identifier resolves to one discovered
    /// Agent. Resource IDs are accepted so event producers can avoid display
    /// name collisions without exposing source content.
    public func resolveStructuredEvent(agentIdentifier: String, projectID: String? = nil) -> ResolvedAgent {
        let identifier = Self.normalizedIdentifier(agentIdentifier)
        let exactIDs = Set(candidates.filter { $0.resourceID == agentIdentifier }.map(\.resourceID))
        if exactIDs.count == 1 { return ResolvedAgent(resourceID: exactIDs.first, confidence: .exact) }
        let matches = candidates.filter {
            Self.normalizedIdentifier($0.name) == identifier ||
            Self.normalizedIdentifier(URL(fileURLWithPath: $0.relativeSourcePath).deletingPathExtension().lastPathComponent) == identifier
        }
        let local = projectID.map { project in matches.filter { $0.projectID == project } } ?? []
        let scoped = local.isEmpty ? matches.filter { $0.projectID == nil } : local
        let ids = Set(scoped.map(\.resourceID))
        guard ids.count == 1 else { return ResolvedAgent(resourceID: nil, confidence: .unknown) }
        return ResolvedAgent(resourceID: ids.first, confidence: .exact)
    }

    func projectID(workingDirectory: String?) -> String? {
        guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        return roots.filter { $0.scope == .project || $0.kind == .projects }
            .filter { path == $0.url.standardizedFileURL.path || path.hasPrefix($0.url.standardizedFileURL.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }?.id
    }

    /// Resolves a real read signal to one discovered Agent manifest.
    /// Returning `nil` means the operation was not a read; a non-nil unknown
    /// result means a read occurred but identity could not be resolved.
    public func resolveManifestReadSignal(input: String, toolName: String?) -> ResolvedAgent? {
        let results = resolveManifestReadSignals(input: input, toolName: toolName)
        return results.count == 1 ? results.first : nil
    }

    public func resolveManifestReadSignals(input: String, toolName: String?, projectID: String? = nil, workingDirectory: String? = nil) -> [ResolvedAgent] {
        let paths = candidates.map {
            ManifestReadCandidate(key: $0.resourceID, relativePath: $0.relativeSourcePath, absolutePath: $0.absoluteSourcePath, projectID: $0.projectID)
        }
        guard let keys = ManifestReadEvidence.matchingCandidateKeys(input: input, toolName: toolName, candidates: paths, projectID: projectID, workingDirectory: workingDirectory) else {
            return []
        }
        // A path that is not one of the discovered Agent manifests is not
        // evidence, and an ambiguous path is deliberately dropped rather
        // than attributed to an arbitrary Agent.
        return keys.sorted().map { ResolvedAgent(resourceID: $0, confidence: .inferred) }
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "./", with: "")
    }

}
