import XCTest
@testable import DirectorUI
import DirectorCore

/// Review presentation contracts: severity grouping/counts, filters,
/// selection, and the "no findings is not healthy" coverage rule.
@MainActor
final class ReviewViewModelTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func finding(
        _ id: String, ruleID: String = "rule.unmatched-result",
        severity: ReviewSeverity = .warning, sessionID: String? = "s1"
    ) -> ReviewFinding {
        ReviewFinding(
            id: id, ruleID: ruleID, resourceID: nil, sessionID: sessionID,
            severity: severity, confidence: .exact, summary: "Summary \(id)",
            evidenceSummary: "Evidence \(id)", coverage: .complete,
            createdAt: epoch, remediationStatus: .open
        )
    }

    func testCountsBySeverity() {
        let model = ReviewViewModel(findings: [
            finding("a", severity: .error),
            finding("b", severity: .warning),
            finding("c", severity: .warning),
            finding("d", severity: .info),
        ])
        XCTAssertEqual(model.count(.error), 1)
        XCTAssertEqual(model.count(.warning), 2)
        XCTAssertEqual(model.count(.info), 1)
    }

    func testSeverityFilter() {
        let model = ReviewViewModel(findings: [
            finding("a", severity: .error),
            finding("b", severity: .warning),
            finding("c", severity: .info),
        ])
        XCTAssertEqual(model.filteredFindings.count, 3)
        model.severityFilter = .warning
        XCTAssertEqual(model.filteredFindings.map(\.id), ["b"])
        model.severityFilter = nil
        XCTAssertEqual(model.filteredFindings.count, 3)
    }

    func testSelectionPreserved() {
        let model = ReviewViewModel(findings: [finding("a"), finding("b")])
        model.selectedFindingID = "b"
        XCTAssertEqual(model.selectedFinding?.id, "b")
        model.severityFilter = .error
        XCTAssertEqual(model.selectedFinding?.id, "b") // preserved
    }

    func testNoFindingsIsNotHealthyWhenCoverageIncomplete() {
        let incomplete = ReviewViewModel(findings: [], sessions: [
            TaskSummary(id: "s1", projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: .partial, parserVersion: "1.0.0", sourceFileID: "f", title: nil),
        ])
        XCTAssertFalse(incomplete.coverageIsComplete)

        let complete = ReviewViewModel(findings: [], sessions: [
            TaskSummary(id: "s1", projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1.0.0", sourceFileID: "f", title: nil),
        ])
        XCTAssertTrue(complete.coverageIsComplete)
    }

    func testNoSessionsMeansCoverageNotComplete() {
        let model = ReviewViewModel(findings: [])
        XCTAssertFalse(model.coverageIsComplete)
    }

    func testRuleMetadataResolvedByID() {
        let model = ReviewViewModel(findings: [finding("a", ruleID: "rule.missing-source")])
        let rule = model.rule(for: model.findings[0])
        XCTAssertEqual(rule?.name, "Declared source is missing or unavailable")
        XCTAssertFalse(rule?.applicability.isEmpty ?? true)
    }

    func testParserCoverageFindingsRemainAvailableButLeaveActionableQueue() {
        let parser = finding("parser", ruleID: "rule.parser-coverage", severity: .info)
        let actionable = finding("actionable", ruleID: "rule.missing-source", severity: .warning)
        let model = ReviewViewModel(findings: [parser, actionable])

        XCTAssertEqual(model.allFindings.map(\.id), ["parser", "actionable"])
        XCTAssertEqual(model.findings.map(\.id), ["actionable"])
        XCTAssertEqual(model.filteredFindings.map(\.id), ["actionable"])
        XCTAssertEqual(model.dataQualityFindingCount, 1)
        XCTAssertEqual(model.count(.info), 0)
    }

    func testReviewEmptyCopyUsesActionableTerminology() {
        let model = ReviewViewModel(findings: [finding("parser", ruleID: "rule.parser-coverage")])
        XCTAssertTrue(model.findings.isEmpty)
        XCTAssertEqual(model.dataQualityFindingCount, 1)
    }
}
