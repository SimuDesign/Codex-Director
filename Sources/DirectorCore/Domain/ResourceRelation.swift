import Foundation

/// A directed relationship between two capabilities (used by Capability
/// Topology). `relationKind` is a stable string such as "uses", "invokes",
/// "contains", "depends-on".
public struct ResourceRelation: Codable, Sendable, Equatable, Identifiable {
    public let sourceResourceID: String
    public let targetResourceID: String
    public let relationKind: String
    public let confidence: EvidenceConfidence
    public let evidenceSummary: String?

    public var id: String {
        "\(sourceResourceID)|\(relationKind)|\(targetResourceID)"
    }

    public init(
        sourceResourceID: String,
        targetResourceID: String,
        relationKind: String,
        confidence: EvidenceConfidence,
        evidenceSummary: String?
    ) {
        self.sourceResourceID = sourceResourceID
        self.targetResourceID = targetResourceID
        self.relationKind = relationKind
        self.confidence = confidence
        self.evidenceSummary = evidenceSummary
    }
}
