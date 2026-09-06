import Foundation
import XCTest
@testable import DirectorCore

final class PresentationSnapshotStoreTests: XCTestCase {
    private func makeSnapshot(identity: PresentationIdentity = .init(databaseEpoch: "epoch", dataGeneration: 1), home: PresentationHomeSummary? = nil) -> PresentationSnapshot {
        PresentationSnapshot(identity: identity, classificationRevision: "c1", window: .init(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20), timeZone: TimeZone(secondsFromGMT: 0)! ), generatedAt: Date(timeIntervalSince1970: 15), statisticsThrough: Date(timeIntervalSince1970: 19), home: home)
    }
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json") }

    func testRoundTripPreservesDatesAndModules() async throws {
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }; let store = PresentationSnapshotStore(url: file)
        let snapshot = makeSnapshot(home: PresentationHomeSummary(customAgents: 1, customAgentsGlobal: 1, customAgentsProject: 0, customSkills: 2, customSkillsGlobal: 2, customSkillsProject: 0, installedSkills: 3, installedSkillsIndependent: 3, installedSkillsPluginProvided: 0, installedPlugins: 1, enabledPlugins: 1))
        try await store.write(snapshot)
        let loaded = try await store.read()
        XCTAssertEqual(loaded, snapshot)
    }

    func testMergePreservesCompatibleModulesAndRejectsOldIdentity() async throws {
        let identity = PresentationIdentity(databaseEpoch: "e", dataGeneration: 2)
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }; let store = PresentationSnapshotStore(url: file)
        let first = PresentationSnapshot(identity: identity, classificationRevision: "c1", window: makeSnapshot(identity: identity).window, quota: nil, home: PresentationHomeSummary(customAgents: 1, customAgentsGlobal: 1, customAgentsProject: 0, customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0, installedSkills: 0, installedSkillsIndependent: 0, installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0))
        try await store.write(first)
        let updated = PresentationSnapshot(identity: identity, classificationRevision: "c1", window: first.window, quota: nil, home: nil)
        try await store.merge(updated, expectedIdentity: identity, generation: 2)
        let loaded = try await store.read()
        XCTAssertEqual(loaded?.home?.customAgents, 1)
        do { try await store.write(makeSnapshot(identity: .init(databaseEpoch: "e", dataGeneration: 1))); XCTFail("old generation unexpectedly wrote") } catch { }
        try await store.delete(expectedIdentity: identity)
        let deleted = try await store.read()
        XCTAssertNil(deleted)
        do { try await store.write(first); XCTFail("revoked identity unexpectedly wrote") } catch { }
    }

    func testRejectsQuotaWithMismatchedContainerIdentityOrWindow() async throws {
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }
        let identity = PresentationIdentity(databaseEpoch: "e", dataGeneration: 1)
        let container = makeSnapshot(identity: identity)
        let otherWindow = CapabilityQueryWindow(start: Date(timeIntervalSince1970: 30), end: Date(timeIntervalSince1970: 40), timeZone: .gmt)
        let quota = QuotaOverviewSnapshot(identity: .init(databaseEpoch: "other", dataGeneration: 1), window: otherWindow, coverage: .complete, sources: [])
        let invalid = PresentationSnapshot(identity: identity, classificationRevision: "c1", window: container.window, quota: quota)
        let store = PresentationSnapshotStore(url: file)
        do { try await store.write(invalid); XCTFail("mismatched quota unexpectedly wrote") } catch { }
    }

    func testSameEpochScheduleUpdatesOldPayloadAfterGenerationAdvance() async throws {
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }
        let store = PresentationSnapshotStore(url: file)
        let oldIdentity = PresentationIdentity(databaseEpoch: "epoch", dataGeneration: 1)
        let newIdentity = PresentationIdentity(databaseEpoch: "epoch", dataGeneration: 2)
        let old = makeSnapshot(identity: oldIdentity)
        let oldPermit = await store.activate(identity: oldIdentity)
        try await store.write(old, permit: oldPermit)

        // A source commit can advance the database generation before a
        // projection succeeds. Keep the old payload identity intact while
        // allowing its same-epoch retry metadata to advance.
        let newPermit = await store.activate(identity: newIdentity)
        let schedule = PresentationRefreshSchedule(
            revision: 4,
            recordedAt: Date(timeIntervalSince1970: 30),
            projectionRetryAttempt: 1,
            projectionRetryDate: Date(timeIntervalSince1970: 330)
        )
        try await store.updateSchedule(schedule, databaseEpoch: "epoch", permit: newPermit)

        let loaded = try await store.read()
        XCTAssertEqual(loaded?.identity, oldIdentity)
        XCTAssertEqual(loaded?.refreshSchedule, schedule)
    }

    func testQuotaOverviewDayRoundTripPreservesDailyUsage() throws {
        let day = QuotaOverviewDay(
            day: Date(timeIntervalSinceReferenceDate: 10),
            observation: nil,
            cycleChanged: true,
            usedPercentDelta: 12
        )

        let encoded = try JSONEncoder().encode(day)
        XCTAssertEqual(try JSONDecoder().decode(QuotaOverviewDay.self, from: encoded), day)
    }

    func testQuotaOverviewDayDecodesLegacyPayloadWithoutDailyUsage() throws {
        let legacy = Data(#"{"day":10,"observation":null,"cycleChanged":false}"#.utf8)

        let decoded = try JSONDecoder().decode(QuotaOverviewDay.self, from: legacy)

        XCTAssertNil(decoded.usedPercentDelta)
    }

    func testAccountUsageIsOptionalV1CacheDataAndRoundTrips() async throws {
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }
        let accountUsage = try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: 74,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_001_000),
            resetCreditCount: 2,
            capturedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let snapshot = PresentationSnapshot(
            identity: .init(databaseEpoch: "account-cache", dataGeneration: 1),
            classificationRevision: "c1",
            window: .init(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20), timeZone: .gmt),
            accountUsage: accountUsage
        )
        let store = PresentationSnapshotStore(url: file)

        try await store.write(snapshot)

        let loaded = try await store.read()
        XCTAssertEqual(loaded?.accountUsage, accountUsage)
        let encoded = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("accountId"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
    }

    func testLegacyV1CacheWithoutAccountUsageStillReads() async throws {
        let file = url(); defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = makeSnapshot(identity: .init(databaseEpoch: "legacy-cache", dataGeneration: 1))
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "accountUsage")
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let loaded = try await PresentationSnapshotStore(url: file).read()

        XCTAssertNil(loaded?.accountUsage)
        XCTAssertEqual(loaded?.identity, snapshot.identity)
    }
}
