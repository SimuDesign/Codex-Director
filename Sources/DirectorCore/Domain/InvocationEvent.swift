import Foundation

/// What kind of capability an invocation exercised.
public enum InvocationKind: String, Codable, Sendable, CaseIterable {
    case agent
    /// Agent orchestration lifecycle, not a custom Agent invocation.
    case orchestration
    case tool
    case skill
    case workflow
    case review
    case handoff
    case compaction
    case interruption
    case unknown
}

/// Observed outcome of a single invocation.
public enum InvocationStatus: String, Codable, Sendable, CaseIterable {
    case started
    case completed
    case failed
    case retried
    case interrupted
    case unknown
}

/// One normalized call record reconstructed from rollout JSONL evidence.
/// The event carries identity, order, nesting, outcome, and confidence, but
/// never raw arguments, outputs, or conversation text.
public struct InvocationEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let parentCallID: String?
    public let ordinal: Int
    public let timestamp: Date?
    public let actorName: String?
    public let resourceID: String?
    public let kind: InvocationKind
    public let status: InvocationStatus
    public let durationMs: Int?
    public let confidence: EvidenceConfidence
    public let errorCategory: String?

    public init(
        id: String,
        sessionID: String,
        parentCallID: String?,
        ordinal: Int,
        timestamp: Date?,
        actorName: String?,
        resourceID: String?,
        kind: InvocationKind,
        status: InvocationStatus,
        durationMs: Int?,
        confidence: EvidenceConfidence,
        errorCategory: String?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentCallID = parentCallID
        self.ordinal = ordinal
        self.timestamp = timestamp
        self.actorName = actorName
        self.resourceID = resourceID
        self.kind = kind
        self.status = status
        self.durationMs = durationMs
        self.confidence = confidence
        self.errorCategory = errorCategory
    }
}
