import Foundation
import XCTest
@testable import DirectorCore

/// Cache-boundary regression tests for the Home ranking upgrade. These tests
/// use only an isolated JSON file and synthetic snapshots; they never open the
/// app's preferences or derived database.
final class HomeRankingCacheTests: XCTestCase {
    func testTopTenUpgradePreservesQuotaWindowAndRefreshMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-ranking-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = PresentationIdentity(databaseEpoch: "home-cache-epoch", dataGeneration: 4)
        let window = CapabilityQueryWindow(
            start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let schedule = PresentationRefreshSchedule(
            revision: 8, recordedAt: now,
            lastSourceSuccessAt: now.addingTimeInterval(-60),
            sourceRetryAttempt: 0, sourceRetryDate: nil,
            projectionRetryAttempt: 1, projectionRetryDate: now.addingTimeInterval(300)
        )
        let quota = QuotaOverviewSnapshot(
            identity: identity, generatedAt: now, window: window,
            coverage: .unknown, sources: []
        )
        let oldHome = makeHome(capacity: 5, count: 5)
        let old = PresentationSnapshot(
            identity: identity, classificationRevision: "classification",
            window: window, generatedAt: now.addingTimeInterval(-120),
            lastSourceCheckAt: now.addingTimeInterval(-60),
            lastIndexCompletedAt: now.addingTimeInterval(-90),
            statisticsThrough: now, quota: quota, home: oldHome,
            failureCount: 2, nextRetryAt: now.addingTimeInterval(300),
            refreshSchedule: schedule
        )
        let store = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        try await store.write(old)

        // The upgrade is a payload replacement under a fresh permit, not a
        // full snapshot rebuild. Every non-Home field is copied unchanged.
        let permit = await store.activate(identity: identity)
        let upgraded = PresentationSnapshot(
            identity: old.identity, classificationRevision: old.classificationRevision,
            window: old.window, generatedAt: old.generatedAt,
            lastSourceCheckAt: old.lastSourceCheckAt,
            lastIndexCompletedAt: old.lastIndexCompletedAt,
            statisticsThrough: old.statisticsThrough,
            quota: old.quota, home: makeHome(capacity: 10, count: 10),
            failureCount: old.failureCount, nextRetryAt: old.nextRetryAt,
            refreshSchedule: old.refreshSchedule
        )
        try await store.write(upgraded, permit: permit)
        let read = try await store.read(expectedIdentity: identity)
        let result = try XCTUnwrap(read)
        XCTAssertEqual(result.home?.rankingCapacity, 10)
        XCTAssertEqual(result.quota, quota)
        XCTAssertEqual(result.identity, old.identity)
        XCTAssertEqual(result.window, old.window)
        XCTAssertEqual(result.generatedAt, old.generatedAt)
        XCTAssertEqual(result.lastSourceCheckAt, old.lastSourceCheckAt)
        XCTAssertEqual(result.lastIndexCompletedAt, old.lastIndexCompletedAt)
        XCTAssertEqual(result.statisticsThrough, old.statisticsThrough)
        XCTAssertEqual(result.failureCount, old.failureCount)
        XCTAssertEqual(result.nextRetryAt, old.nextRetryAt)
        XCTAssertEqual(result.refreshSchedule, schedule)
    }

    func testInvalidTopTenPayloadCannotBePersisted() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-ranking-invalid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let home = makeHome(capacity: 10, count: 11)
        let identity = PresentationIdentity(databaseEpoch: "invalid-home", dataGeneration: 1)
        let window = CapabilityQueryWindow(
            start: Date(timeIntervalSince1970: 1_799_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let store = PresentationSnapshotStore(url: file)
        let snapshot = PresentationSnapshot(identity: identity, classificationRevision: "c", window: window, home: home)
        do {
            try await store.write(snapshot)
            XCTFail("invalid Home ranking length was persisted")
        } catch let error as PresentationSnapshotStore.StoreError {
            XCTAssertEqual(error, .corrupt)
        }
    }

    private func makeHome(capacity: Int, count: Int) -> PresentationHomeSummary {
        let rows = (0..<count).map {
            PresentationHomeTopRow(
                resourceID: "home-\($0)", name: "Home \($0)", category: .customAgents,
                count: count - $0, inferredCount: $0 == 2 ? 2 : 0,
                lastUsedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double($0))
            )
        }
        return PresentationHomeSummary(
            customAgents: count, customAgentsGlobal: count, customAgentsProject: 0,
            customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
            installedSkills: 0, installedSkillsIndependent: 0, installedSkillsPluginProvided: 0,
            installedPlugins: 0, enabledPlugins: 0, rankingCapacity: capacity,
            customAgentsTop: rows
        )
    }
}
