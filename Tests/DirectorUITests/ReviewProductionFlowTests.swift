import XCTest
@testable import DirectorUI
import DirectorCore

/// End-to-end Review production flow: coordinator -> SQLite -> view model,
/// with no synthetic fallback when a real store exists.
@MainActor
final class ReviewProductionFlowTests: XCTestCase {

    private func makeEnvironment() async throws -> (store: DatabaseStore, configuration: IndexingCoordinator.Configuration) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        // Unmatched call -> partial coverage -> rule.parser-coverage.
        let meta = #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"session:rv","session_id":"session:rv","cli_version":"0.148.0-alpha.9"}}"#
        let call = #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"c1","call_id":"c1","name":"read"}}"#
        try ([meta, call].joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: sessionsDir.appendingPathComponent("session-rv.jsonl"))

        let store = try DatabaseStore(url: base.appendingPathComponent("test.sqlite"))
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [],
            activeSessionRoots: [sessionsDir],
            archivedSessionRoot: nil
        )
        return (store, configuration)
    }

    func testDirectorAppModelRefreshLoadsProductionFinding() async throws {
        let environment = try await makeEnvironment()
        let coordinator = IndexingCoordinator(store: environment.store)
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: environment.store,
            coordinator: coordinator,
            configuration: environment.configuration,
            classificationOverrides: stores.0,
            evaluationStore: stores.1
        )
        XCTAssertFalse(model.isSyntheticMode)

        await model.startIndexing()

        // Review evidence is a destination-local query; indexing must not
        // preload all findings into the launch model.
        XCTAssertTrue(model.review.findings.isEmpty)
        await model.loadReviewIfNeeded()

        // The finding came from production indexing, not SyntheticPreviewData.
        // Parser coverage is preserved for Data Status, but is not actionable
        // Review work.
        XCTAssertTrue(model.review.allFindings.contains { $0.ruleID == "rule.parser-coverage" })
        XCTAssertEqual(model.review.dataQualityFindingCount, 1)
        XCTAssertFalse(model.review.findings.contains { $0.ruleID == "rule.parser-coverage" })
        XCTAssertTrue(model.review.allFindings.contains { $0.sessionID == "session:rv" })
        XCTAssertFalse(model.review.findings.contains { $0.ruleID == "rule.missing-source" && $0.resourceID == "plugin:figma" })
    }
}
