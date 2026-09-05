import Foundation

/// Conservative Agent evidence resolution.
///
/// Agent lifecycle tools are orchestration and do not identify a custom
/// Agent. An Agent invocation is emitted only for a structured
/// `agent_invoked` event or a real read of one uniquely matched discovered
/// Agent manifest. Prompt text, task names, and system context are never
/// evidence. Paths and transient inputs remain in memory only.
public struct AgentEvidenceResolver: Sendable {

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

    public struct ResolvedAgent: Sendable, Equatable {
        public let resourceID: String?
        public let confidence: EvidenceConfidence

        public init(resourceID: String?, confidence: EvidenceConfidence) {
            self.resourceID = resourceID
            self.confidence = confidence
        }
    }

    public let candidates: [Candidate]

    public init(resources: [CapabilityResource], roots: [ScanRoot] = []) {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.url) })
        self.candidates = resources
            .filter { $0.kind == .agent }
            .compactMap { resource in
                guard let relative = resource.relativeSourcePath, !relative.isEmpty else { return nil }
                let absolute = rootsByID[resource.sourceRootID]?
                    .appendingPathComponent(relative)
                    .standardizedFileURL.path
                return Candidate(
                    resourceID: resource.id,
                    name: resource.name,
                    relativeSourcePath: Self.normalize(relative),
                    absoluteSourcePath: absolute.map(Self.normalize)
                )
            }
    }

    /// Exact only when the structured identifier resolves to one discovered
    /// Agent. Resource IDs are accepted so event producers can avoid display
    /// name collisions without exposing source content.
    public func resolveStructuredEvent(agentIdentifier: String) -> ResolvedAgent {
        let identifier = Self.normalizedIdentifier(agentIdentifier)
        let matches = candidates.filter {
            Self.normalizedIdentifier($0.name) == identifier || $0.resourceID == agentIdentifier
        }
        guard matches.count == 1 else { return ResolvedAgent(resourceID: nil, confidence: .unknown) }
        return ResolvedAgent(resourceID: matches[0].resourceID, confidence: .exact)
    }

    /// Resolves a real read signal to one discovered Agent manifest.
    /// Returning `nil` means the operation was not a read; a non-nil unknown
    /// result means a read occurred but identity could not be resolved.
    public func resolveManifestReadSignal(input: String, toolName: String?) -> ResolvedAgent? {
        let paths = candidates.map {
            ManifestReadCandidate(key: $0.resourceID, relativePath: $0.relativeSourcePath, absolutePath: $0.absoluteSourcePath)
        }
        guard let keys = ManifestReadEvidence.matchingCandidateKeys(input: input, toolName: toolName, candidates: paths) else {
            return nil
        }
        // A path that is not one of the discovered Agent manifests is not
        // evidence, and an ambiguous path is deliberately dropped rather
        // than attributed to an arbitrary Agent.
        guard keys.count == 1, let resourceID = keys.first else { return nil }
        return ResolvedAgent(resourceID: resourceID, confidence: .inferred)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "//", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .replacingOccurrences(of: "./", with: "")
    }

}
