import Foundation
import DirectorCore

/// Main-actor view state for the Review destination.
@MainActor
public final class ReviewViewModel: ObservableObject {
    @Published public var severityFilter: ReviewSeverity?
    @Published public var selectedFindingID: String?

    /// All persisted findings, including parser coverage notices routed to
    /// Data Status rather than the actionable Review queue.
    public let allFindings: [ReviewFinding]
    public let findings: [ReviewFinding]
    public let sessions: [TaskSummary]

    public init(findings: [ReviewFinding], sessions: [TaskSummary] = []) {
        self.allFindings = findings
        self.findings = findings.filter { $0.ruleID != "rule.parser-coverage" }
        self.sessions = sessions
    }

    public var dataQualityFindingCount: Int {
        allFindings.filter { $0.ruleID == "rule.parser-coverage" }.count
    }

    public var filteredFindings: [ReviewFinding] {
        findings.filter { severityFilter == nil || $0.severity == severityFilter }
    }

    public func count(_ severity: ReviewSeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }

    /// "No findings" is not "Healthy" unless analyzed coverage is complete.
    public var coverageIsComplete: Bool {
        !sessions.isEmpty && sessions.allSatisfy { $0.coverage == .complete }
    }

    public var selectedFinding: ReviewFinding? {
        guard let selectedFindingID else { return nil }
        return findings.first { $0.id == selectedFindingID }
    }

    /// Rule metadata (name, applicability) by rule id.
    public func rule(for finding: ReviewFinding) -> (name: String, applicability: String)? {
        guard let rule = IntegrityRules.all.first(where: { $0.id == finding.ruleID }) else { return nil }
        return (rule.name, rule.applicability)
    }
}
