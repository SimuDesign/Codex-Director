import Foundation

/// Severity of a deterministic Review Lite finding.
public enum ReviewSeverity: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
}

/// Remediation state of a finding.
public enum RemediationStatus: String, Codable, Sendable, CaseIterable {
    case open
    case fixed
    case accepted
}

/// One deterministic, evidence-backed Review Lite finding.
///
/// Findings are produced by explicit rules only; no AI health score or
/// personality judgment is ever produced.
public struct ReviewFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ruleID: String
    public let resourceID: String?
    public let sessionID: String?
    public let severity: ReviewSeverity
    public let confidence: EvidenceConfidence
    public let summary: String
    public let evidenceSummary: String
    public let coverage: CoverageState
    public let createdAt: Date
    public let remediationStatus: RemediationStatus

    public init(
        id: String,
        ruleID: String,
        resourceID: String?,
        sessionID: String?,
        severity: ReviewSeverity,
        confidence: EvidenceConfidence,
        summary: String,
        evidenceSummary: String,
        coverage: CoverageState,
        createdAt: Date,
        remediationStatus: RemediationStatus
    ) {
        self.id = id
        self.ruleID = ruleID
        self.resourceID = resourceID
        self.sessionID = sessionID
        self.severity = severity
        self.confidence = confidence
        self.summary = summary
        self.evidenceSummary = evidenceSummary
        self.coverage = coverage
        self.createdAt = createdAt
        self.remediationStatus = remediationStatus
    }
}
