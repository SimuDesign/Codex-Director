#if DEBUG
import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class ValidationRedesignTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_889_600)

    func testSharedCatalogCoversFourCategoriesAndCurrentPluginRelations() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let catalog = try await session.model.store!.fetchCapabilityCatalog()
        let grouped = Dictionary(grouping: catalog.entries.compactMap(\.category), by: { $0 })
        XCTAssertEqual(grouped[.customAgents]?.count, 3)
        XCTAssertEqual(grouped[.customSkills]?.count, 2)
        XCTAssertEqual(grouped[.installedSkills]?.count, 2)
        XCTAssertEqual(grouped[.installedPlugins]?.count, 3)
        XCTAssertTrue(catalog.entries.contains { $0.resource.id == "plugin:validation-enabled" })
        XCTAssertTrue(catalog.entries.contains { $0.resource.id == "plugin:validation-cached" && $0.category == nil })
        XCTAssertEqual(catalog.entries.first { $0.resource.id == "skill:validation-plugin-child" }?.parentPluginID, "plugin:validation-enabled")
        let overview = HomeOverviewModel(catalog: catalog, usage: [])
        XCTAssertEqual(overview.inventory.installedPlugins, 3)
        XCTAssertEqual(overview.inventory.enabledPlugins, 2)
    }

    func testRecentUsageIsNonzeroAndSeparatesProjectsAndHistory() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let store = try XCTUnwrap(session.model.store)
        let window = CapabilityQueryWindow.recent7(now: now, calendar: session.model.statisticsCalendar)
        let global = try await store.fetchCapabilityUsageStats(window: window)
        XCTAssertTrue(global.contains { $0.resourceID == "agent:validation-global" && $0.callCount > 0 })
        let a = try await store.fetchCapabilityUsageStats(window: window, projectID: "project:validation-a")
        let b = try await store.fetchCapabilityUsageStats(window: window, projectID: "project:validation-b")
        XCTAssertTrue(a.contains { $0.resourceID == "agent:validation-global" })
        XCTAssertTrue(b.contains { $0.resourceID == "agent:validation-global" })
        let history = try await store.fetchCapabilityHistory()
        XCTAssertTrue(history.contains { $0.resourceID == "skill:validation-custom" && $0.callCount > 0 })
        let customRecent = global.first { $0.resourceID == "skill:validation-custom" }
        XCTAssertTrue(customRecent == nil || customRecent?.callCount == 0)
    }

    func testWeeklyQuotaSourcesExposeGapResetAndExpiredObservation() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let usage = session.model.usage
        XCTAssertTrue(usage.quotaSnapshots.allSatisfy { $0.windowMinutes == 10_080 || $0.windowMinutes == 300 })
        XCTAssertTrue(usage.hasMultipleWeeklyNamespaces)
        XCTAssertEqual(usage.weeklyDailySnapshots.count, 7)
        XCTAssertTrue(usage.weeklyDailySnapshots.contains { $0.usedPercent == nil })
        XCTAssertTrue(usage.weeklyDailySnapshots.contains { $0.isResetDay })
        XCTAssertTrue(usage.weeklyNamespaceSummaries.contains { $0.limitID == "source-b" && $0.isExpired(at: now) })
    }

    func testSyntheticDatabaseContainsNoOutsideDataAndKeepsStableEvidence() async throws {
        let session = try UIValidationSession(dataset: .representative)
        try await session.prepare()
        let store = try XCTUnwrap(session.model.store)
        let resources = try await store.fetchAllResources()
        XCTAssertTrue(resources.allSatisfy { $0.sourceRootID.hasPrefix("validation-") || $0.sourceRootID == "runtime-plugins" || $0.sourceRootID == "plugin-cache" })
        XCTAssertTrue(resources.allSatisfy { !($0.relativeSourcePath ?? "").contains("/") || !$0.relativeSourcePath!.contains("Users/") })
        let page = try await store.fetchCapabilityInvocations(resourceID: "agent:validation-global", pageSize: 2)
        XCTAssertTrue(page.items.allSatisfy { $0.id.hasPrefix("call:validation-") })
        XCTAssertTrue(session.model.evaluationStore.all().keys.allSatisfy { $0.hasPrefix("call:validation-") })
    }

    func testStressFixtureSupportsPagedEvidence() async throws {
        let session = try UIValidationSession(dataset: .stress)
        try await session.prepare()
        let store = try XCTUnwrap(session.model.store)
        let first = try await store.fetchCapabilityInvocations(resourceID: "tool:validation-stress-0", pageSize: 3)
        XCTAssertEqual(first.items.count, 3)
        XCTAssertNotNil(first.nextCursor)
        let callCount = try await store.count("calls")
        XCTAssertEqual(callCount, 520)
    }
}
#endif
