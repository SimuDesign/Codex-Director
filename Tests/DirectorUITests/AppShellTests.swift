import XCTest
import SwiftUI
@testable import DirectorUI
import DirectorCore

/// App shell contract: five primary destinations, separate utilities,
/// stable titles/symbols, synthetic data only, and a buildable root view.
@MainActor
final class AppShellTests: XCTestCase {

    func testPrimaryDestinationsAreExactlyFive() {
        XCTAssertEqual(DirectorDestination.allCases.count, 5)
    }

    func testDestinationTitlesAreStableAndDistinct() {
        let titles = DirectorDestination.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(DirectorDestination.home.title, "Home")
        XCTAssertEqual(DirectorDestination.capabilities.title, "Capabilities")
        XCTAssertEqual(DirectorDestination.tasks.title, "Tasks")
        XCTAssertEqual(DirectorDestination.review.title, "Review")
        XCTAssertEqual(DirectorDestination.usage.title, "Usage")
    }

    func testUtilitiesAreSeparateFromPrimaryDestinations() {
        XCTAssertEqual(DirectorUtility.allCases.count, 2)
        let primaryTitles = Set(DirectorDestination.allCases.map(\.title))
        for utility in DirectorUtility.allCases {
            XCTAssertFalse(primaryTitles.contains(utility.title))
        }
        XCTAssertTrue(DirectorSidebarItem.dataStatus.isUtility)
        XCTAssertTrue(DirectorSidebarItem.settings.isUtility)
        XCTAssertFalse(DirectorSidebarItem.capabilities.isUtility)
    }

    func testSidebarItemIDsAreStable() {
        XCTAssertEqual(DirectorSidebarItem.tasks.id, "tasks")
        XCTAssertEqual(DirectorSidebarItem.settings.id, "settings")
        XCTAssertNotEqual(DirectorSidebarItem.usage.id, DirectorSidebarItem.tasks.id)
        XCTAssertNotEqual(DirectorSidebarItem.capabilities.id, DirectorSidebarItem.dataStatus.id)
    }

    func testDefaultSelectionIsHome() {
        let model = TestMemoryPreferences.makeModel()
        XCTAssertEqual(model.selection, .home)
    }

    func testAppModelCarriesSyntheticDataOnly() {
        let model = TestMemoryPreferences.makeModel()
        XCTAssertTrue(model.isSyntheticMode)
        XCTAssertFalse(model.capabilities.allRows.isEmpty)
        XCTAssertFalse(model.tasks.rows.isEmpty)
        for row in model.capabilities.allRows {
            XCTAssertFalse(row.resource.sourceRootID.contains("exampleuser"))
            XCTAssertFalse(row.resource.relativeSourcePath?.contains("exampleuser") ?? false)
            XCTAssertFalse(row.resource.name.contains("exampleuser"))
        }
    }

    func testBootstrapFailureDoesNotCreateSyntheticPreviewData() {
        let model = TestMemoryPreferences.makeModel(
            previewMode: false,
            bootstrapError: "derived_database_unavailable"
        )

        XCTAssertEqual(model.presentationState, .failure("derived_database_unavailable"))
        XCTAssertFalse(model.isSyntheticMode)
        XCTAssertFalse(model.hasDerivedDatabase)
        XCTAssertTrue(model.capabilities.allRows.isEmpty)
        XCTAssertTrue(model.tasks.rows.isEmpty)
    }

    func testRootViewBuilds() {
        _ = DirectorRootView(model: TestMemoryPreferences.makeModel())
    }

    func testCapabilityUseHomeDeepLinksStayWithinCurrentUserOwnedAgentSkillScope() {
        let model = TestMemoryPreferences.makeModel()

        model.applyHomeSectionFilter(.observedCapabilities)

        XCTAssertEqual(model.selection, .capabilities)
        XCTAssertEqual(model.capabilities.allowedKinds, [.agent, .skill])
        XCTAssertEqual(model.capabilities.ownershipFilter, .userOwned)
        XCTAssertEqual(model.capabilities.usageFilter, .observed)
    }

    func testRefreshKeepsCapabilityIdentityAndEvaluationLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("director-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try DatabaseStore(url: directory.appendingPathComponent("test.sqlite"))
        let resource = CapabilityResource(
            id: "agent:refresh", name: "refresh-agent", kind: .agent, status: .unknown,
            scope: .global, projectID: nil, confidence: .exact, summary: "Synthetic purpose",
            sourceRootID: "root", relativeSourcePath: "refresh/agent.md", sourcePathHash: "hash",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000), ownership: .userOwned, origin: .local
        )
        try await store.insertResources([resource])
        let event = InvocationEvent(
            id: "call:refresh", sessionID: "session:refresh", parentCallID: nil, ordinal: 0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), actorName: "synthetic",
            resourceID: resource.id, kind: .agent, status: .completed, durationMs: nil,
            confidence: .exact, errorCategory: nil
        )
        try await store.replaceSession(PersistedSessionBatch(
            session: TaskSummary(id: event.sessionID, projectID: nil, startedAt: event.timestamp, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1.0.0", sourceFileID: "file:refresh", title: nil),
            calls: [event], tokenSnapshots: [], quotaSnapshots: [], findings: []
        ))
        defer { try? FileManager.default.removeItem(at: directory) }

        var rejectWrites = false
        var evaluationData: Data?
        let classificationStore = TestMemoryPreferences.makeStores().0
        let evaluationStore = InvocationEvaluationStore(
            readData: { evaluationData },
            writeData: { data in
                guard !rejectWrites else { return false }
                evaluationData = data
                return true
            },
            removeData: {
                evaluationData = nil
                return true
            }
        )
        let model = DirectorAppModel(store: store, classificationOverrides: classificationStore, evaluationStore: evaluationStore)
        try await model.refresh()
        let capabilitiesIdentity = ObjectIdentifier(model.capabilities)
        model.capabilities.searchText = "refresh"
        model.capabilities.selectedResourceID = resource.id
        model.setEvaluation(for: event, label: .ineffective, updatedAt: Date(timeIntervalSince1970: 1_700_000_001))

        XCTAssertEqual(model.capabilities.selectedResourceID, resource.id)
        XCTAssertEqual(model.capabilities.selectedRow?.ineffectiveCount, 1)
        XCTAssertEqual(model.tasks.evaluation(for: event.id)?.label, .ineffective)

        rejectWrites = true
        model.setEvaluation(for: event, label: .effective)
        XCTAssertEqual(model.evaluationStore.evaluation(for: event.id)?.label, .ineffective)
        XCTAssertEqual(model.tasks.evaluation(for: event.id)?.label, .ineffective)
        XCTAssertEqual(model.capabilities.selectedRow?.evaluatedCount, 1)
        XCTAssertEqual(model.capabilities.selectedRow?.ineffectiveCount, 1)
        XCTAssertEqual(model.capabilities.selectedRow?.effectiveCount, 0)
        rejectWrites = false

        let invalidEvent = InvocationEvent(
            id: "call:/unsafe", sessionID: event.sessionID, parentCallID: nil, ordinal: 1,
            timestamp: event.timestamp, actorName: "synthetic", resourceID: resource.id,
            kind: .agent, status: .completed, durationMs: nil, confidence: .exact,
            errorCategory: nil
        )
        model.setEvaluation(for: invalidEvent, label: .effective)
        XCTAssertNil(model.evaluationStore.evaluation(for: invalidEvent.id))
        XCTAssertEqual(model.capabilities.selectedRow?.evaluatedCount, 1)
        model.clearEvaluation(for: invalidEvent.id)
        XCTAssertEqual(model.capabilities.selectedRow?.evaluatedCount, 1)
        XCTAssertEqual(model.tasks.evaluation(for: event.id)?.label, .ineffective)

        let toolEvent = InvocationEvent(
            id: "call:tool", sessionID: event.sessionID, parentCallID: nil, ordinal: 2,
            timestamp: event.timestamp, actorName: "synthetic", resourceID: resource.id,
            kind: .tool, status: .completed, durationMs: nil, confidence: .exact,
            errorCategory: nil
        )
        model.setEvaluation(for: toolEvent, label: .effective)
        XCTAssertNil(model.evaluationStore.evaluation(for: toolEvent.id))
        XCTAssertEqual(model.capabilities.selectedRow?.evaluatedCount, 1)

        try await model.refresh()

        XCTAssertEqual(ObjectIdentifier(model.capabilities), capabilitiesIdentity)
        XCTAssertEqual(model.capabilities.searchText, "refresh")
        XCTAssertEqual(model.capabilities.selectedResourceID, resource.id)
        XCTAssertEqual(model.capabilities.selectedRow?.ineffectiveCount, 1)

        model.clearEvaluation(for: event.id)
        XCTAssertEqual(model.capabilities.selectedRow?.evaluatedCount, 0)
        XCTAssertNil(model.tasks.evaluation(for: event.id))
    }
}
