import XCTest
@testable import DirectorUI
import DirectorCore

/// Data Status / first run / privacy settings contracts and the
/// first-run-and-delete flow against a real derived database.
@MainActor
final class DataStatusTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Views construct

    func testFirstRunViewConstructs() {
        _ = FirstRunView(message: "Local only.", canIndex: true, isIndexing: false, startAction: {})
        _ = FirstRunView(message: "Local only.", canIndex: false, isIndexing: true, startAction: {})
    }

    func testDataStatusViewConstructs() {
        _ = DataStatusView(
            progress: .initial, isIndexing: false, lastRefresh: nil, error: nil,
            parserVersion: "1.0.0", sourceCategoryCounts: [("skills", 3)],
            sessionsWithPartialCoverage: 0, sourceDataFresh: true,
            sourceDataLastCheckedAt: nil, confirmDelete: .constant(false),
            rebuildAction: {}, deleteAction: {}, parserCoverageFindingCount: 4
        )
    }

    func testPrivacySettingsViewConstructs() {
        _ = PrivacySettingsView()
    }

    // MARK: - Copy contracts

    func testDeleteConfirmationStatesOriginalsUnchanged() {
        let message = DirectorAppModel.deleteConfirmationMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("unchanged"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("original"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("user evaluation"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("labels"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("prompt"))
    }

    func testFirstRunMessageStatesLocalAndReadOnly() {
        let message = DirectorAppModel.firstRunMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("local"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("read-only"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("nothing is uploaded"))
    }

    // MARK: - First run and deletion flow

    private func makeEnvironment() async throws -> (store: DatabaseStore, configuration: IndexingCoordinator.Configuration, sessionURL: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-firstrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionURL = sessionsDir.appendingPathComponent("session-1.jsonl")
        let meta = #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"session:fr","session_id":"session:fr","cli_version":"0.148.0-alpha.9"}}"#
        let call = #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"c1","call_id":"c1","name":"read"}}"#
        let output = #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"custom_tool_call_output","id":"c1o","call_id":"c1","output":[{"type":"text","text":"ok"}]}}"#
        try ([meta, call, output].joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: sessionURL)

        let store = try DatabaseStore(url: base.appendingPathComponent("test.sqlite"))
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [],
            activeSessionRoots: [sessionsDir],
            archivedSessionRoot: nil
        )
        return (store, configuration, sessionURL)
    }

    func testFirstRunIndexesThenDeleteClearsDerivedData() async throws {
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
        XCTAssertFalse(model.hasDerivedDatabase == false) // store present
        XCTAssertTrue(model.tasks.rows.isEmpty) // synthetic-free: nothing indexed yet

        await model.startIndexing()
        XCTAssertTrue(model.tasks.rows.isEmpty) // Tasks are loaded lazily by the destination.
        await model.loadTasksIfNeeded()
        XCTAssertEqual(model.tasks.rows.count, 1)
        XCTAssertEqual(model.tasks.rows.first?.task.id, "session:fr")
        XCTAssertEqual(model.tasks.rows.first?.callCount, 1)
        XCTAssertNotNil(model.lastRefresh)
        XCTAssertEqual(model.presentationState, .loaded)
        XCTAssertTrue(model.hasIndexedData)
        XCTAssertNotNil(model.lastIndexCompletedAt)

        // A second pass skips the unchanged source file, but the completed
        // progress must still report every checked file as finished.
        await model.startIndexing()
        XCTAssertEqual(model.indexingProgress.phase, .completed)
        XCTAssertEqual(model.indexingProgress.processedFiles, 1)
        XCTAssertEqual(model.indexingProgress.totalFiles, 1)

        try await model.deleteDerivedData()
        XCTAssertTrue(model.tasks.rows.isEmpty)
        XCTAssertNil(model.lastRefresh)
        XCTAssertEqual(model.presentationState, .initial)
        XCTAssertFalse(model.hasIndexedData)
        XCTAssertNil(model.lastIndexCompletedAt)
        // Source file is untouched by deletion.
        let data = try Data(contentsOf: environment.sessionURL)
        XCTAssertFalse(data.isEmpty)
    }

    func testSyntheticModeByDefault() {
        let model = TestMemoryPreferences.makeModel()
        XCTAssertTrue(model.isSyntheticMode)
        XCTAssertFalse(model.hasDerivedDatabase)
        XCTAssertFalse(model.capabilities.allRows.isEmpty) // synthetic preview data
    }

    func testEmptyDatabaseRequiresACompletedPassBeforeShowingEmptyState() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = try DatabaseStore(url: base.appendingPathComponent("test.sqlite"))
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: store,
            coordinator: IndexingCoordinator(store: store),
            configuration: configuration,
            classificationOverrides: stores.0,
            evaluationStore: stores.1
        )

        XCTAssertEqual(model.presentationState, .initial)
        try await model.refresh()
        XCTAssertEqual(model.presentationState, .initial)
        XCTAssertFalse(model.hasIndexedData)

        await model.startIndexing()
        XCTAssertEqual(model.presentationState, .empty)
        XCTAssertFalse(model.hasIndexedData)
        XCTAssertNotNil(model.lastIndexCompletedAt)
    }

    func testLaunchLoadsExistingIndexWithoutReindexing() async throws {
        let environment = try await makeEnvironment()
        // Seed the derived database directly, bypassing the app model.
        let coordinator = IndexingCoordinator(store: environment.store)
        try await coordinator.run(configuration: environment.configuration)

        // Fresh launch: a new model with the same store and NO coordinator.
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(
            store: environment.store,
            classificationOverrides: stores.0,
            evaluationStore: stores.1
        )
        XCTAssertNil(model.lastRefresh)
        XCTAssertTrue(model.tasks.rows.isEmpty)

        await model.loadInitialData()
        XCTAssertTrue(model.tasks.rows.isEmpty) // Tasks are loaded lazily by the destination.
        await model.loadTasksIfNeeded()

        XCTAssertNotNil(model.lastRefresh)
        XCTAssertEqual(model.tasks.rows.count, 1)
        XCTAssertEqual(model.tasks.rows.first?.task.id, "session:fr")
    }
}
