import XCTest
@testable import DirectorUI
import DirectorCore

/// Pure contracts for Review's staged narrow-window navigation.
@MainActor
final class ReviewLayoutTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testReviewStagesBelowReadableSplitWidth() {
        let threshold = ReviewLayoutMetrics.spaciousWorkspaceMinimumWidth
        XCTAssertEqual(ReviewLayoutState.forContentWidth(threshold - 1), .compact)
        XCTAssertEqual(ReviewLayoutState.forContentWidth(threshold), .spacious)
        XCTAssertGreaterThanOrEqual(ReviewLayoutMetrics.findingsMinimumWidth, 300)
        XCTAssertGreaterThanOrEqual(ReviewLayoutMetrics.inspectorMinimumWidth, 300)
    }

    func testBackTransitionClearsOnlyFindingSelectionAndKeepsFilter() {
        let finding = ReviewFinding(
            id: "finding:validation-1",
            ruleID: "rule.missing-source",
            resourceID: "agent:validation-project",
            sessionID: "session:validation-1",
            severity: .error,
            confidence: .exact,
            summary: "Declared source is missing or unavailable",
            evidenceSummary: "Synthetic evidence only",
            coverage: .complete,
            createdAt: date,
            remediationStatus: .open
        )
        let model = ReviewViewModel(findings: [finding])

        model.severityFilter = .error
        model.selectedFindingID = finding.id
        XCTAssertEqual(model.selectedFinding?.id, finding.id)
        XCTAssertEqual(model.severityFilter, .error)

        // Compact Back/Escape transition is model-backed and does not reset
        // the user's active severity filter.
        model.selectedFindingID = nil
        XCTAssertNil(model.selectedFinding)
        XCTAssertEqual(model.severityFilter, .error)
    }

    func testCompactEmptyDatasetRoutesToExistingEmptyState() {
        XCTAssertEqual(ReviewContentStage.forCounts(findingsCount: 0, filteredCount: 0), .empty)
        XCTAssertEqual(ReviewContentStage.forCounts(findingsCount: 2, filteredCount: 0), .filteredEmpty)
        XCTAssertEqual(ReviewContentStage.forCounts(findingsCount: 2, filteredCount: 1), .findings)
    }
}
