import Foundation

/// Everything a deterministic Review Lite rule needs to evaluate.
public struct ReviewContext: Sendable {
    public let resources: [CapabilityResource]
    public let sessions: [TaskSummary]
    public let invocationsBySession: [String: [InvocationEvent]]
    public let quotaSnapshots: [QuotaSnapshot]
    public let scanRoots: [ScanRoot]
    public let fileSystem: FileSystemClient
    public let now: Date

    public init(
        resources: [CapabilityResource],
        sessions: [TaskSummary],
        invocationsBySession: [String: [InvocationEvent]],
        quotaSnapshots: [QuotaSnapshot],
        scanRoots: [ScanRoot],
        fileSystem: FileSystemClient,
        now: Date
    ) {
        self.resources = resources
        self.sessions = sessions
        self.invocationsBySession = invocationsBySession
        self.quotaSnapshots = quotaSnapshots
        self.scanRoots = scanRoots
        self.fileSystem = fileSystem
        self.now = now
    }
}

/// A deterministic, evidence-backed Review Lite rule.
///
/// Rules never interpret Prompt text and never ask an LLM to judge behavior.
/// Every finding exposes rule source, applicability, evidence, coverage,
/// confidence, and related task/resource.
public protocol ReviewRule: Sendable {
    /// Stable identifier, e.g. `rule.missing-source`.
    var id: String { get }
    /// Human-readable name.
    var name: String { get }
    /// When this rule applies.
    var applicability: String { get }
    /// Deterministic findings; empty when nothing matches.
    func evaluate(context: ReviewContext) -> [ReviewFinding]
}

/// Shared finding construction for rules.
public extension ReviewRule {
    func makeFinding(
        ruleID: String,
        resourceID: String?,
        sessionID: String?,
        severity: ReviewSeverity,
        summary: String,
        evidenceSummary: String,
        coverage: CoverageState,
        confidence: EvidenceConfidence,
        createdAt: Date
    ) -> ReviewFinding {
        let stableSuffix = [resourceID, sessionID].compactMap { $0 }.joined(separator: "|")
        let id = stableSuffix.isEmpty ? "\(ruleID)" : "\(ruleID)|\(stableSuffix)"
        return ReviewFinding(
            id: id,
            ruleID: ruleID,
            resourceID: resourceID,
            sessionID: sessionID,
            severity: severity,
            confidence: confidence,
            summary: summary,
            evidenceSummary: evidenceSummary,
            coverage: coverage,
            createdAt: createdAt,
            remediationStatus: .open
        )
    }
}
