import Foundation
import XCTest
@testable import DirectorCore
@testable import DirectorUI

/// Independent acceptance coverage for the Home 0.2.2 neutral Top10 cache
/// contract. These tests intentionally use only synthetic values and unique
/// temporary files; they do not read preferences, source files, or databases.
final class HomeRefreshIndependentTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeutralSummaryUsesCapacityTenAndRetainsRowEvidence() throws {
        XCTAssertEqual(PresentationHomeSummary.currentRankingCapacity, 10)

        let lastUsedAt = epoch.addingTimeInterval(123)
        let agents = rows(category: .customAgents, count: 10, lastUsedAt: lastUsedAt)
        let skills = rows(category: .customSkills, count: 10, lastUsedAt: lastUsedAt)
        let installed = rows(category: .installedSkills, count: 10, lastUsedAt: lastUsedAt)
        let summary = makeSummary(
            rankingCapacity: PresentationHomeSummary.currentRankingCapacity,
            customAgentsTop: agents,
            customSkillsTop: skills,
            installedSkillsTop: installed
        )

        let encoded = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["rankingCapacity"] as? Int, 10)
        XCTAssertNotNil(object["customAgentsTop"])
        XCTAssertNotNil(object["customSkillsTop"])
        XCTAssertNotNil(object["installedSkillsTop"])
        XCTAssertNil(object["customAgentsTop5"])
        XCTAssertNil(object["customSkillsTop5"])
        XCTAssertNil(object["installedSkillsTop5"])

        let decoded = try JSONDecoder().decode(PresentationHomeSummary.self, from: encoded)
        XCTAssertEqual(decoded.rankingCapacity, 10)
        XCTAssertEqual(decoded.customAgentsTop, agents)
        XCTAssertEqual(decoded.customSkillsTop, skills)
        XCTAssertEqual(decoded.installedSkillsTop, installed)
        XCTAssertEqual(decoded.customAgentsTop[3].lastUsedAt, lastUsedAt)
        XCTAssertEqual(decoded.customAgentsTop[3].inferredCount, 3)
    }

    func testLegacyTopFiveJSONDecodesAndNilScheduleEnvelopeRemainsReadable() throws {
        let legacyRow = row(category: .customAgents, id: "legacy-agent", count: 4, inferredCount: 2, lastUsedAt: epoch)
        let legacyRowObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyRow)) as? [String: Any]
        )
        let legacyHome: [String: Any] = [
            "customAgents": 1, "customAgentsGlobal": 1, "customAgentsProject": 0,
            "customSkills": 0, "customSkillsGlobal": 0, "customSkillsProject": 0,
            "installedSkills": 0, "installedSkillsIndependent": 0,
            "installedSkillsPluginProvided": 0, "installedPlugins": 0, "enabledPlugins": 0,
            "customAgentsTop5": [legacyRowObject], "customSkillsTop5": [], "installedSkillsTop5": []
        ]

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot(home: nil))) as? [String: Any]
        )
        object["home"] = legacyHome
        // Old snapshots predate the scheduler envelope entirely.
        object.removeValue(forKey: "refreshSchedule")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PresentationSnapshot.self, from: data)
        XCTAssertNil(decoded.refreshSchedule)
        XCTAssertEqual(decoded.home?.rankingCapacity, 5)
        XCTAssertEqual(decoded.home?.customAgentsTop, [legacyRow])
        XCTAssertEqual(decoded.home?.customAgentsTop.first?.lastUsedAt, epoch)
        XCTAssertEqual(decoded.home?.customAgentsTop.first?.inferredCount, 2)
    }

    func testNeutralJSONWithoutCapacityIsRejectedInsteadOfSilentlyDroppingRows() throws {
        let summary = makeSummary(
            rankingCapacity: PresentationHomeSummary.currentRankingCapacity,
            customAgentsTop: rows(category: .customAgents, count: 2)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        )
        object.removeValue(forKey: "rankingCapacity")

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(PresentationHomeSummary.self, from: data))
    }

    func testDecoderRejectsCapacityAboveTen() throws {
        let summary = makeSummary(
            rankingCapacity: 10,
            customAgentsTop: rows(category: .customAgents, count: 10)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        )
        object["rankingCapacity"] = 11
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(PresentationHomeSummary.self, from: data))
    }

    func testSnapshotStoreRejectsRowsBeyondDeclaredCapacity() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-refresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // The constructor accepts values so the persistence boundary is tested
        // independently; the store must reject a summary containing 11 rows
        // while declaring the approved capacity of 10.
        let home = makeSummary(
            rankingCapacity: 10,
            customAgentsTop: rows(category: .customAgents, count: 11)
        )
        let store = PresentationSnapshotStore(url: file)
        do {
            try await store.write(makeSnapshot(home: home))
            XCTFail("rows beyond the declared Home ranking capacity were persisted")
        } catch let error as PresentationSnapshotStore.StoreError {
            XCTAssertEqual(error, .corrupt)
        } catch {
            XCTFail("unexpected store error: \(error)")
        }
    }

    func testPositiveCallRankingKeepsStableTopTenTieOrderAndExcludesZero() {
        let categories: [CapabilityCategory] = [.customAgents, .customSkills, .installedSkills]
        var resources: [CapabilityResource] = []
        var usage: [CapabilityUsageStats] = []
        for category in categories {
            let categoryResources = (0..<11).map { index in
                resource(id: String(format: "%@-%02d", category.rawValue, index), name: "Same", category: category)
            }
            let zero = resource(id: category.rawValue + "-zero", name: "Zero", category: category)
            resources.append(contentsOf: categoryResources + [zero])
            usage.append(contentsOf: categoryResources.map {
                CapabilityUsageStats(
                    resourceID: $0.id,
                    callCount: 4,
                    inferredCount: $0.id.hasSuffix("-03") ? 2 : 0,
                    lastUsedAt: epoch,
                    coverage: .complete
                )
            })
            usage.append(CapabilityUsageStats(resourceID: zero.id, callCount: 0, inferredCount: 0, lastUsedAt: epoch, coverage: .complete))
        }

        let model = HomeOverviewModel(
            catalog: CapabilityCatalog(resources: resources),
            usage: usage
        )
        for category in categories {
            let ranking = model.rankings[category] ?? []
            let expectedIDs = (0..<10).map { String(format: "%@-%02d", category.rawValue, $0) }
            XCTAssertEqual(ranking.count, 10, "unexpected ranking size for \(category)")
            XCTAssertEqual(ranking.map(\.id), expectedIDs, "unstable tie order for \(category)")
            XCTAssertTrue(ranking.allSatisfy { $0.count > 0 })
            XCTAssertEqual(ranking.first(where: { $0.id.hasSuffix("-03") })?.inferred, true)
            XCTAssertFalse(ranking.contains { $0.id == category.rawValue + "-zero" })
        }
    }

    private func makeSummary(
        rankingCapacity: Int = PresentationHomeSummary.currentRankingCapacity,
        customAgentsTop: [PresentationHomeTopRow] = [],
        customSkillsTop: [PresentationHomeTopRow] = [],
        installedSkillsTop: [PresentationHomeTopRow] = []
    ) -> PresentationHomeSummary {
        PresentationHomeSummary(
            customAgents: 10, customAgentsGlobal: 10, customAgentsProject: 0,
            customSkills: 10, customSkillsGlobal: 10, customSkillsProject: 0,
            installedSkills: 10, installedSkillsIndependent: 10, installedSkillsPluginProvided: 0,
            installedPlugins: 1, enabledPlugins: 1,
            rankingCapacity: rankingCapacity,
            customAgentsTop: customAgentsTop,
            customSkillsTop: customSkillsTop,
            installedSkillsTop: installedSkillsTop
        )
    }

    private func makeSnapshot(home: PresentationHomeSummary?) -> PresentationSnapshot {
        let identity = PresentationIdentity(databaseEpoch: "home-test-epoch", dataGeneration: 1)
        let window = CapabilityQueryWindow(
            start: epoch.addingTimeInterval(-600),
            end: epoch,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        return PresentationSnapshot(
            identity: identity,
            classificationRevision: "home-test-classification",
            window: window,
            generatedAt: epoch,
            home: home
        )
    }

    private func rows(category: CapabilityCategory, count: Int, lastUsedAt: Date? = nil) -> [PresentationHomeTopRow] {
        (0..<count).map { index in
            row(
                category: category,
                id: "\(category.rawValue)-\(index)",
                count: count - index,
                inferredCount: index == 3 ? 3 : 0,
                lastUsedAt: lastUsedAt
            )
        }
    }

    private func row(category: CapabilityCategory, id: String, count: Int, inferredCount: Int = 0, lastUsedAt: Date? = nil) -> PresentationHomeTopRow {
        PresentationHomeTopRow(
            resourceID: id,
            name: "Synthetic \(id)",
            category: category,
            count: count,
            inferredCount: inferredCount,
            lastUsedAt: lastUsedAt
        )
    }

    private func resource(id: String, name: String, category: CapabilityCategory) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: category == .customAgents ? .agent : .skill,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: "synthetic-home",
            relativeSourcePath: "\(id).md",
            sourcePathHash: nil,
            lastSeenAt: epoch,
            ownership: category == .installedSkills ? .installed : .userOwned,
            origin: category == .installedSkills ? .github : .local
        )
    }
}
