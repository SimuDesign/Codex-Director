#if DEBUG
import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class UIValidationTests: XCTestCase {
    func testDebugHostConstructsWithNativeValidationSurface() {
        _ = UIValidationHost(
            languageStore: AppLanguageStore(memoryLanguage: .simplifiedChinese),
            themeStore: AppThemeStore(memoryTheme: .dark)
        )
        XCTAssertEqual(UIValidationSession.Dataset.allCases.count, 4)
    }

    func testValidationHostExposesBilingualAppearanceAndWindowMatrix() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let host = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Validation/UIValidationHost.swift"), encoding: .utf8)
        let destinations = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorDestination.swift"), encoding: .utf8)
        XCTAssertTrue(host.contains("Picker(\"Language / 语言\""))
        XCTAssertTrue(host.contains("Text(\"简体中文\")"))
        XCTAssertTrue(host.contains("Text(\"English\")"))
        XCTAssertTrue(host.contains("AppThemeStore(memoryTheme: .dark)"))
        XCTAssertTrue(host.contains(".environmentObject(themeStore)"))
        XCTAssertTrue(host.contains(".onChange(of: themeStore.theme)"))
        XCTAssertTrue(host.contains("Toggle(\"Refresh loading\""))
        XCTAssertTrue(host.contains("session.model.isIndexing = value"))
        XCTAssertTrue(host.contains(".onChange(of: session.generation)"))
        XCTAssertTrue(host.contains("720 × 480"))
        XCTAssertTrue(host.contains("1280 × 800"))
        XCTAssertTrue(host.contains("1600 × 1000"))
        XCTAssertEqual(destinations.components(separatedBy: "public static var approvedNavigation").count - 1, 1)
        XCTAssertTrue(destinations.contains("[.home, .customAgents, .customSkills, .installedSkills, .installedPlugins, .settings]"))
    }

    func testCaptureLayoutKeepsControlsOutsideTheRequestedProductViewport() {
        let requested = CGSize(width: 1_280, height: 800)

        XCTAssertEqual(
            UIValidationCaptureLayout.windowContentSize(
                productSize: requested,
                controlsHeight: 52,
                showsControls: true
            ),
            CGSize(width: 1_280, height: 853)
        )
        XCTAssertEqual(
            UIValidationCaptureLayout.windowContentSize(
                productSize: requested,
                controlsHeight: 52,
                showsControls: false
            ),
            requested
        )
        XCTAssertEqual(
            UIValidationCaptureLayout.reportedProductViewportSize(
                requested: requested,
                measured: CGSize(width: 1_280, height: 748),
                captureMode: true
            ),
            requested
        )
        XCTAssertEqual(
            UIValidationCaptureLayout.reportedProductViewportSize(
                requested: requested,
                measured: CGSize(width: 1_280, height: 748),
                captureMode: false
            ),
            CGSize(width: 1_280, height: 748)
        )
    }

    func testCaptureModeHidesControlsAndUsesEscapeToRestoreThem() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let host = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Validation/UIValidationHost.swift"), encoding: .utf8)

        XCTAssertTrue(host.contains("@State private var isCaptureMode = false"))
        XCTAssertTrue(host.contains("Button(\"Capture view\")"))
        XCTAssertTrue(host.contains("if !isCaptureMode"))
        XCTAssertTrue(host.contains(".onExitCommand"))
        XCTAssertTrue(host.contains("private func enterCaptureMode()"))
        XCTAssertTrue(host.contains("private func exitCaptureMode()"))
        XCTAssertTrue(host.contains("reportedProductViewportSize"))
        XCTAssertFalse(host.contains("Task { @MainActor in\n                await Task.yield()"), "capture sizing must not depend on an incidental scheduling turn")
    }

    func testHomeVisualFixtureCoversRankingAndQuotaEdges() async throws {
        let session = try UIValidationSession(dataset: .homeVisual)
        try await session.prepare()

        let rows = session.model.capabilities.allRows
        XCTAssertEqual(rows.count, 36)
        XCTAssertEqual(rows.filter { $0.id.hasPrefix("agent:home-visual-") && $0.callCount > 0 }.count, 12)
        XCTAssertEqual(rows.filter { $0.id.hasPrefix("skill:home-visual-") && $0.callCount > 0 }.count, 12)
        XCTAssertEqual(rows.filter { $0.id.hasPrefix("installed-skill:home-visual-") && $0.callCount > 0 }.count, 12)
        XCTAssertTrue(rows.contains { $0.resource.name.contains("intentionally long readable name") })

        let now = Date(timeIntervalSince1970: 1_787_889_600)
        let quotas = session.model.usage.quotaSnapshots
        XCTAssertTrue(quotas.contains { $0.limitName == "Synthetic account source with a deliberately long readable name" })
        XCTAssertTrue(quotas.contains { $0.limitID == "home-visual-source-a" && $0.usedPercent == 0 })
        XCTAssertTrue(quotas.contains { $0.limitID == "home-visual-source-a" && $0.usedPercent == 100 })
        XCTAssertTrue(quotas.contains {
            $0.limitID == "home-visual-source-b" && ($0.resetsAt ?? .distantFuture) < now
        })

        let quotaModel = QuotaOverviewModel(
            snapshots: quotas,
            now: now,
            calendar: session.model.statisticsCalendar,
            selectedSourceID: "id:home-visual-source-a"
        )
        XCTAssertEqual(quotaModel.dailySnapshots.count, 7)
        XCTAssertTrue(quotaModel.dailySnapshots.contains { $0.usedPercent == 0 })
        XCTAssertTrue(quotaModel.dailySnapshots.contains { $0.usedPercent == 100 })
        XCTAssertTrue(quotaModel.dailySnapshots.contains { $0.usedPercent == nil })
        XCTAssertTrue(quotaModel.dailySnapshots.contains { $0.cycleChanged })

        let catalog = try await session.model.store!.fetchCapabilityCatalog()
        let home = HomeOverviewModel(catalog: catalog, usage: session.model.recentCapabilityStats)
        for category in [CapabilityCategory.customAgents, .customSkills, .installedSkills] {
            let ranking = home.rankings[category] ?? []
            XCTAssertLessThanOrEqual(ranking.count, 10)
            XCTAssertTrue(ranking.allSatisfy { $0.count > 0 })
        }
    }

    func testRepresentativeFixtureIsIsolatedAndOperational() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()

        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.model.coordinator)
        XCTAssertNil(session.model.configuration)
        XCTAssertEqual(session.model.capabilities.allRows.count, 14)
        XCTAssertEqual(session.model.tasks.rows.count, 4)
        XCTAssertTrue(session.model.tasks.invocationsBySession.isEmpty, "Invocation evidence is intentionally lazy")
        XCTAssertGreaterThan(session.model.capabilities.allRows.filter { $0.callCount > 0 }.count, 0)
        XCTAssertGreaterThan(session.model.review.allFindings.count, 0)
        XCTAssertGreaterThan(session.model.usage.taskBreakdown.count, 0)
        XCTAssertTrue(session.databaseURL.path.contains("codex-director-ui-validation-"))
        XCTAssertGreaterThan(session.model.evaluationStore.all().count, 0)
        let firstPage = try await session.model.store!.fetchCapabilityInvocations(resourceID: "agent:validation-global", pageSize: 2)
        XCTAssertEqual(firstPage.items.count, 2)
        XCTAssertNotNil(firstPage.nextCursor)
        var allCalls: [InvocationEvent] = []
        for index in 0..<4 { allCalls += try await session.model.store!.fetchCalls(sessionID: "session:validation-\(index)") }
        let statuses = Set(allCalls.map(\.status))
        XCTAssertTrue(statuses.contains(.failed))
        XCTAssertTrue(statuses.contains(.interrupted))
        XCTAssertTrue(statuses.contains(.unknown))
        let confidences = Set(allCalls.map(\.confidence))
        XCTAssertTrue(confidences.contains(.exact))
        XCTAssertTrue(confidences.contains(.inferred))
        XCTAssertTrue(session.model.capabilities.allRows.contains { $0.resource.name == "validation-unobserved-skill" && !$0.isObserved })

        let localSkill = try XCTUnwrap(session.model.capabilities.allRows.first { $0.id == "skill:validation-custom" })
        XCTAssertEqual(localSkill.resource.kind, .skill)
        XCTAssertEqual(localSkill.resource.scope, .global)
        XCTAssertEqual(localSkill.resource.origin, .local)
        session.model.classify(resourceID: localSkill.id, ownership: .installed)
        XCTAssertEqual(session.model.classificationOverrides.all()[localSkill.id]?.ownership, .installed)
        XCTAssertEqual(session.model.capabilities.allRows.first { $0.id == localSkill.id }?.resource.ownership, .installed)

        let isolatedEmpty = try UIValidationSession(dataset: .empty)
        try await isolatedEmpty.prepare()
        XCTAssertTrue(isolatedEmpty.model.classificationOverrides.all().isEmpty)
        XCTAssertTrue(isolatedEmpty.model.evaluationStore.all().isEmpty)
        XCTAssertNotEqual(session.databaseURL, isolatedEmpty.databaseURL)
    }

    func testDatasetSelectionCoversEmptyAndStressCardinalities() async throws {
        let session = try UIValidationSession(dataset: .empty)
        try await session.prepare()
        XCTAssertEqual(session.model.capabilities.allRows.count, 0)
        XCTAssertEqual(session.model.tasks.rows.count, 0)
        XCTAssertEqual(session.model.review.allFindings.count, 0)

        let oldDatabaseURL = session.databaseURL
        await session.reset(to: .stress)
        XCTAssertEqual(session.dataset, .stress)
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.hasError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDatabaseURL.path))
        XCTAssertGreaterThanOrEqual(session.model.capabilities.allRows.count, 150)
        XCTAssertGreaterThanOrEqual(session.model.tasks.rows.count, 4)
        let invocationCount = try await session.model.store!.count("calls")
        XCTAssertGreaterThanOrEqual(invocationCount, 500)
    }

    func testCanonicalEvaluationUpdateChangesAggregatesWithoutReindexing() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        var allCalls: [InvocationEvent] = []
        for index in 0..<4 { allCalls += try await session.model.store!.fetchCalls(sessionID: "session:validation-\(index)") }
        let event = try XCTUnwrap(allCalls.first {
            ($0.kind == .agent || $0.kind == .skill) && session.model.evaluationStore.evaluation(for: $0.id) == nil
        })
        let rowBefore = try XCTUnwrap(session.model.capabilities.allRows.first { $0.id == event.resourceID })

        session.model.setEvaluation(for: event, label: .effective)

        let rowAfter = try XCTUnwrap(session.model.capabilities.allRows.first { $0.id == event.resourceID })
        XCTAssertEqual(rowAfter.evaluatedCount, rowBefore.evaluatedCount + 1)
        XCTAssertEqual(rowAfter.effectiveCount, rowBefore.effectiveCount + 1)
        XCTAssertEqual(session.model.evaluationStore.evaluation(for: event.id)?.label, .effective)
    }

    func testValidationStoresArePureMemoryAndCountersStayInjected() {
        var data: Data?
        var writes = 0
        var removals = 0
        let store = InvocationEvaluationStore(
            readData: { data },
            writeData: { value in writes += 1; data = value; return true },
            removeData: { removals += 1; data = nil; return true }
        )
        let evaluation = InvocationEvaluation(
            invocationID: "call:memory-only",
            sessionID: "session:memory-only",
            resourceID: "agent:memory-only",
            label: .effective,
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )

        XCTAssertTrue(store.set(evaluation))
        XCTAssertEqual(store.all()[evaluation.invocationID], evaluation)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(store.removeAll())
        XCTAssertEqual(removals, 1)
        XCTAssertTrue(store.all().isEmpty)

        var classifications: Data?
        let classificationStore = ResourceClassificationOverrideStore(
            readData: { classifications },
            writeData: { classifications = $0 },
            removeData: { classifications = nil }
        )
        classificationStore.set(
            ResourceClassificationOverride(ownership: .installed, origin: .github),
            for: "skill:memory-only"
        )
        XCTAssertEqual(classificationStore.all()["skill:memory-only"]?.ownership, .installed)
    }

    func testSharedLanguageSwitchPreservesSyntheticModelAndEvaluationState() async throws {
        let languageStore = AppLanguageStore(memoryLanguage: .simplifiedChinese)
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let modelIdentity = ObjectIdentifier(session.model)
        let databaseURL = session.databaseURL
        let generation = session.generation
        let evaluations = session.model.evaluationStore.all()

        languageStore.setLanguage(.english)
        languageStore.setLanguage(.simplifiedChinese)

        XCTAssertEqual(languageStore.language, .simplifiedChinese)
        XCTAssertEqual(ObjectIdentifier(session.model), modelIdentity)
        XCTAssertEqual(session.databaseURL, databaseURL)
        XCTAssertEqual(session.generation, generation)
        XCTAssertEqual(session.model.evaluationStore.all(), evaluations)
    }

    func testSharedThemeSwitchPreservesSyntheticModelAndRefreshState() async throws {
        let themeStore = AppThemeStore(memoryTheme: .dark)
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let modelIdentity = ObjectIdentifier(session.model)
        let databaseURL = session.databaseURL
        let generation = session.generation
        let wasRefreshing = session.model.isRefreshing

        themeStore.setTheme(.light)
        themeStore.setTheme(.dark)

        XCTAssertEqual(themeStore.theme, .dark)
        XCTAssertEqual(ObjectIdentifier(session.model), modelIdentity)
        XCTAssertEqual(session.databaseURL, databaseURL)
        XCTAssertEqual(session.generation, generation)
        XCTAssertEqual(session.model.isRefreshing, wasRefreshing)
        XCTAssertFalse(session.model.isIndexing)
    }

    func testResetFailureRetainsReadyDatasetAndRetryRecovers() async throws {
        enum FactoryError: Error { case unavailable }
        var failNextAllocation = false
        let factory: () throws -> (URL, URL) = {
            if failNextAllocation {
                failNextAllocation = false
                throw FactoryError.unavailable
            }
            return try makeValidationDatabaseAllocation()
        }
        let session = try UIValidationSession(dataset: .empty, databaseFactory: factory)
        try await session.prepare()
        let oldDatabaseURL = session.databaseURL
        failNextAllocation = true

        await session.reset(to: .stress)
        XCTAssertTrue(session.hasError)
        XCTAssertEqual(session.dataset, .empty)
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.databaseURL, oldDatabaseURL)

        await session.reset(to: .stress)
        XCTAssertFalse(session.hasError)
        XCTAssertEqual(session.dataset, .stress)
        XCTAssertTrue(session.isReady)
        XCTAssertNotEqual(session.databaseURL, oldDatabaseURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.databaseURL.path))
        XCTAssertEqual(session.model.capabilities.allRows.count, 165)
        let callCount = try await session.model.store!.count("calls")
        XCTAssertEqual(callCount, 520)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDatabaseURL.path))
    }

    func testSameDatasetRequestInvalidatesPendingReset() async throws {
        let gate = ValidationAsyncGate()
        let session = try UIValidationSession(
            dataset: .representative,
            databaseFactory: makeValidationDatabaseAllocation,
            seedOperation: { dataset, _, _ in
                if dataset == .empty { await gate.wait() }
            }
        )
        try await session.prepare()

        let pendingReset = Task { await session.reset(to: .empty) }
        await gate.waitUntilEntered()
        await session.reset(to: .representative)
        await gate.release()
        await pendingReset.value

        XCTAssertEqual(session.dataset, .representative)
        XCTAssertEqual(session.generation, 0)
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.hasError)
    }

    func testStaleResetFailureCannotOverwriteNewerSuccess() async throws {
        let gate = ValidationAsyncGate()
        let session = try UIValidationSession(
            dataset: .representative,
            databaseFactory: makeValidationDatabaseAllocation,
            seedOperation: { dataset, _, _ in
                if dataset == .empty {
                    await gate.wait()
                    throw ValidationSeedError.failed
                }
            }
        )
        try await session.prepare()

        let failedReset = Task { await session.reset(to: .empty) }
        await gate.waitUntilEntered()
        await session.reset(to: .stress)
        XCTAssertEqual(session.dataset, .stress)
        XCTAssertFalse(session.hasError)
        await gate.release()
        await failedReset.value

        XCTAssertEqual(session.dataset, .stress)
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.hasError)
    }

}

private enum ValidationSeedError: Error {
    case failed
}

private func makeValidationDatabaseAllocation() throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-director-ui-validation-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("validation.sqlite"))
}

private actor ValidationAsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
#endif
