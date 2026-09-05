import XCTest
@testable import DirectorUI
import DirectorCore

/// Presentation state must distinguish sample data, an unindexed database,
/// a completed empty pass, and a bootstrap failure without reading preferences.
@MainActor
final class PresentationStateTests: XCTestCase {
    private final class MemoryData {
        var value: Data?
    }

    private func preferenceStores() -> (ResourceClassificationOverrideStore, InvocationEvaluationStore) {
        let classificationData = MemoryData()
        let evaluationData = MemoryData()
        return (
            ResourceClassificationOverrideStore(
                readData: { classificationData.value },
                writeData: { classificationData.value = $0 },
                removeData: { classificationData.value = nil }
            ),
            InvocationEvaluationStore(
                readData: { evaluationData.value },
                writeData: { evaluationData.value = $0; return true },
                removeData: { evaluationData.value = nil; return true }
            )
        )
    }

    func testExplicitPreviewRemainsPreview() {
        let stores = preferenceStores()
        let model = DirectorAppModel(classificationOverrides: stores.0, evaluationStore: stores.1)

        XCTAssertEqual(model.presentationState, .preview)
        XCTAssertTrue(model.isSyntheticMode)
        XCTAssertFalse(model.capabilities.allRows.isEmpty)
    }

    func testNonPreviewBootstrapFailureIsEmptyAndSafe() {
        let stores = preferenceStores()
        let model = DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            previewMode: false,
            bootstrapError: "derived_database_unavailable"
        )

        XCTAssertEqual(model.presentationState, .failure("derived_database_unavailable"))
        XCTAssertFalse(model.isSyntheticMode)
        XCTAssertTrue(model.capabilities.allRows.isEmpty)
        XCTAssertTrue(model.tasks.rows.isEmpty)
        XCTAssertTrue(model.usage.quotaSnapshots.isEmpty)
        XCTAssertTrue(model.review.findings.isEmpty)
    }

    func testEmptyDatabaseStaysInitialUntilCompletedIndexPass() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-presentation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try DatabaseStore(url: directory.appendingPathComponent("test.sqlite"))
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let stores = preferenceStores()
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

        let plugin = PluginUsageResult(pluginID: "plugin:stale", callCount: 2)
        let pluginLibrary = try XCTUnwrap(model.libraryModels.first(where: { $0.category == .installedPlugins }))
        pluginLibrary.setPluginData([plugin], browseStats: [plugin])
        try await model.deleteDerivedData()
        XCTAssertTrue(pluginLibrary.pluginStats.isEmpty)
        XCTAssertTrue(pluginLibrary.browsePluginStats.isEmpty)
        XCTAssertEqual(model.presentationState, .initial)
        XCTAssertNil(model.lastIndexCompletedAt)
    }
}
