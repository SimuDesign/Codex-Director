import Foundation

/// Everything persisted for one session in a single indexing batch.
public struct PersistedSessionBatch: Sendable {
    public let session: TaskSummary
    public let calls: [InvocationEvent]
    public let tokenSnapshots: [TokenUsageSnapshot]
    public let quotaSnapshots: [QuotaSnapshot]
    public let findings: [ReviewFinding]

    public init(
        session: TaskSummary,
        calls: [InvocationEvent],
        tokenSnapshots: [TokenUsageSnapshot],
        quotaSnapshots: [QuotaSnapshot],
        findings: [ReviewFinding]
    ) {
        self.session = session
        self.calls = calls
        self.tokenSnapshots = tokenSnapshots
        self.quotaSnapshots = quotaSnapshots
        self.findings = findings
    }
}

/// Resume point for incremental JSONL parsing.
public struct IndexCheckpoint: Sendable, Equatable {
    public let sourceFileID: String
    public let sourceSize: UInt64
    public let sourceMtime: TimeInterval
    public let byteOffset: UInt64
    public let parserVersion: String
    public let indexedAt: Date

    public init(
        sourceFileID: String,
        sourceSize: UInt64,
        sourceMtime: TimeInterval,
        byteOffset: UInt64,
        parserVersion: String,
        indexedAt: Date
    ) {
        self.sourceFileID = sourceFileID
        self.sourceSize = sourceSize
        self.sourceMtime = sourceMtime
        self.byteOffset = byteOffset
        self.parserVersion = parserVersion
        self.indexedAt = indexedAt
    }
}
