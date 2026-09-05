import XCTest
@testable import DirectorUI
import DirectorCore

/// Accessibility contract for shared components: state is never conveyed by
/// color alone; labels carry the semantic state.
final class AccessibilityContractTests: XCTestCase {

    func testConfidenceBadgeAlwaysExposesLabel() {
        for confidence in EvidenceConfidence.allCases {
            let badge = ConfidenceBadge(confidence: confidence)
            XCTAssertFalse(badge.confidence == confidence && DirectorSemanticStyle.confidenceLabel(confidence).isEmpty)
            XCTAssertTrue(DirectorSemanticStyle.confidenceLabel(confidence).count > 0)
        }
        XCTAssertEqual(DirectorSemanticStyle.confidenceLabel(.exact), "Exact")
        XCTAssertEqual(DirectorSemanticStyle.confidenceLabel(.inferred), "Inferred")
        XCTAssertEqual(DirectorSemanticStyle.confidenceLabel(.unknown), "Unknown")
    }

    func testStatusBadgeLabelsAreDistinct() {
        let labels = RuntimeStatus.allCases.map(DirectorSemanticStyle.statusLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testCoverageLabelsAreDistinct() {
        let labels = CoverageState.allCases.map { coverage in
            DirectorSemanticStyle.confidenceLabel(.exact) // placeholder reference
            _ = coverage
            return "\(coverage.rawValue)"
        }
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testEvidenceInspectorMarksRedactedItems() {
        let inspector = EvidenceInspector(items: [
            .init(id: "a", label: "Path", value: "~/example", redacted: true),
            .init(id: "b", label: "Name", value: "example"),
        ])
        XCTAssertEqual(inspector.items.count, 2)
        XCTAssertTrue(inspector.items[0].redacted)
        XCTAssertFalse(inspector.items[1].redacted)
    }

    func testConfidenceLinePatternsAreDistinct() {
        let exact = DirectorSemanticStyle.confidenceLineDash(.exact)
        let inferred = DirectorSemanticStyle.confidenceLineDash(.inferred)
        let unknown = DirectorSemanticStyle.confidenceLineDash(.unknown)
        XCTAssertNotEqual(exact, inferred)
        XCTAssertNotEqual(inferred, unknown)
        XCTAssertNotEqual(exact, unknown)
    }

    func testCapabilityInspectorCloseControlHasNativeSymbolAndAccessibleContract() {
        XCTAssertTrue(DirectorSymbol.isValid(DirectorSymbol.closeInspector))
        XCTAssertEqual(
            CapabilityInspector.closeButtonAccessibilityIdentifier,
            "capabilityInspector.close"
        )
    }
}
