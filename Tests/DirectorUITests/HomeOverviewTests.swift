import XCTest
@testable import DirectorUI
import DirectorCore

final class HomeOverviewTests: XCTestCase {
    func testInitialStateIsPreparingUntilAnyUsablePresentationExists() {
        XCTAssertEqual(
            HomeOverviewView.stateMessageKey(
                for: .initial,
                directoryLoaded: false,
                hasComputedStatistics: false,
                hasCachedHomeSummary: false
            ),
            "home.state.preparing"
        )
    }

    func testInitialStateWithDirectoryStatisticsOrCacheIsNotIndexedYet() {
        let cases = [
            (true, false, false),
            (false, true, false),
            (false, false, true)
        ]

        for (directoryLoaded, hasComputedStatistics, hasCachedHomeSummary) in cases {
            XCTAssertEqual(
                HomeOverviewView.stateMessageKey(
                    for: .initial,
                    directoryLoaded: directoryLoaded,
                    hasComputedStatistics: hasComputedStatistics,
                    hasCachedHomeSummary: hasCachedHomeSummary
                ),
                "home.state.notIndexed"
            )
        }
    }

    func testCompletedAndTransientPresentationStatesKeepTheirExistingMessages() {
        let flags = (directoryLoaded: true, hasComputedStatistics: true, hasCachedHomeSummary: true)
        XCTAssertNil(HomeOverviewView.stateMessageKey(for: .preview, directoryLoaded: flags.directoryLoaded, hasComputedStatistics: flags.hasComputedStatistics, hasCachedHomeSummary: flags.hasCachedHomeSummary))
        XCTAssertNil(HomeOverviewView.stateMessageKey(for: .loaded, directoryLoaded: flags.directoryLoaded, hasComputedStatistics: flags.hasComputedStatistics, hasCachedHomeSummary: flags.hasCachedHomeSummary))
        XCTAssertNil(HomeOverviewView.stateMessageKey(for: .empty, directoryLoaded: flags.directoryLoaded, hasComputedStatistics: flags.hasComputedStatistics, hasCachedHomeSummary: flags.hasCachedHomeSummary))
        XCTAssertEqual(HomeOverviewView.stateMessageKey(for: .indexing, directoryLoaded: false, hasComputedStatistics: false, hasCachedHomeSummary: false), "home.state.indexing")
        XCTAssertEqual(HomeOverviewView.stateMessageKey(for: .failure("synthetic"), directoryLoaded: true, hasComputedStatistics: true, hasCachedHomeSummary: true), "home.state.failure")
    }

    func testInventoryTotalsSplitCustomScopeAndInstalledPluginSkills() {
        let entries = [
            entry("a", "Agent", .agent, .customAgents, scope: .global), entry("ap", "Agent P", .agent, .customAgents, scope: .project, project: "p"),
            entry("s", "Skill", .skill, .customSkills), entry("sp", "Skill P", .skill, .customSkills, scope: .project, project: "p"),
            entry("i", "Installed", .skill, .installedSkills), entry("ps", "Plugin Skill", .skill, .installedSkills, scope: .plugin, ownership: .pluginProvided, parent: "plug"),
            entry("plug", "Plugin", .plugin, .installedPlugins, scope: .runtime, ownership: .runtime, origin: .runtime),
            entry("disabled", "Disabled", .plugin, .installedPlugins, scope: .runtime, ownership: .runtime, origin: .runtime, status: .blocked)
        ]
        let relation = ResourceRelation(sourceResourceID: "plug", targetResourceID: "ps", relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let model = HomeOverviewModel(catalog: CapabilityCatalog(resources: entries, relations: [relation]), usage: [])
        XCTAssertEqual(model.inventory.customAgentsGlobal, 1); XCTAssertEqual(model.inventory.customAgentsProject, 1)
        XCTAssertEqual(model.inventory.customSkills, 2); XCTAssertEqual(model.inventory.installedSkills, 1); XCTAssertEqual(model.inventory.installedSkillsIndependent, 1); XCTAssertEqual(model.inventory.installedSkillsPluginProvided, 1)
        XCTAssertEqual(model.inventory.installedPlugins, 2); XCTAssertEqual(model.inventory.enabledPlugins, 1)
        XCTAssertNil(model.currentPluginCounts(when: nil))
        XCTAssertNil(model.currentPluginCounts(when: false))
        XCTAssertEqual(model.currentPluginCounts(when: true)?.installed, 2)
        XCTAssertEqual(model.currentPluginCounts(when: true)?.enabled, 1)
    }

    func testRankingsExcludeZeroCallsAndKeepStableTieOrderAndInference() {
        let resources = (0..<6).map { entry("s\($0)", "Same", .skill, .customSkills) }
        let catalog = CapabilityCatalog(resources: resources)
        let usage = resources.enumerated().map { CapabilityUsageStats(resourceID: $0.element.id, callCount: $0.offset == 5 ? 0 : 4, inferredCount: $0.offset == 2 ? 1 : 0, lastUsedAt: Date(timeIntervalSince1970: Double($0.offset)), coverage: .complete) }
        let rows = HomeOverviewModel(catalog: catalog, usage: usage).rankings[.customSkills]!
        XCTAssertEqual(rows.count, 5); XCTAssertFalse(rows.contains { $0.count == 0 }); XCTAssertTrue(rows.contains { $0.inferred })
        XCTAssertEqual(rows.map(\.id), ["s4", "s3", "s2", "s1", "s0"])
    }

    func testPluginSkillUsageCannotEnterIndependentInstalledRanking() {
        let independent = entry("independent", "Independent", .skill, .installedSkills)
        let child = entry("plugin-skill", "Plugin Skill", .skill, .installedSkills, scope: .plugin, ownership: .pluginProvided, parent: "plugin")
        let plugin = entry("plugin", "Plugin", .plugin, .installedPlugins, scope: .runtime, ownership: .runtime, origin: .runtime)
        let relation = ResourceRelation(sourceResourceID: plugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let usage = [
            CapabilityUsageStats(resourceID: independent.id, callCount: 1, inferredCount: 0, lastUsedAt: nil, coverage: .complete),
            CapabilityUsageStats(resourceID: child.id, callCount: 99, inferredCount: 0, lastUsedAt: nil, coverage: .complete)
        ]
        let model = HomeOverviewModel(catalog: CapabilityCatalog(resources: [independent, child, plugin], relations: [relation]), usage: usage, thirtyDayUsage: usage)
        XCTAssertEqual(model.inventory.installedSkills, 1)
        XCTAssertEqual(model.rankings(for: .sevenDays)?[.installedSkills]?.map(\.id), [independent.id])
        XCTAssertEqual(model.rankings(for: .thirtyDays)?[.installedSkills]?.map(\.id), [independent.id])
    }

    func testRankingsUseSharedCapacityTenAndRetainEvidenceFields() {
        let resources = (0..<12).map { entry("agent\($0)", "Agent \($0)", .agent, .customAgents) }
        let usage = resources.enumerated().map { index, resource in
            CapabilityUsageStats(
                resourceID: resource.id,
                callCount: 12 - index,
                inferredCount: index == 0 ? 3 : 0,
                lastUsedAt: Date(timeIntervalSince1970: Double(index + 1)),
                coverage: .complete
            )
        }
        let model = HomeOverviewModel(catalog: CapabilityCatalog(resources: resources), usage: usage)
        let rows = model.rankings[.customAgents] ?? []
        XCTAssertEqual(rows.count, PresentationHomeSummary.currentRankingCapacity)
        XCTAssertEqual(rows.first?.inferredCount, 3)
        XCTAssertEqual(rows.first?.lastUsedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(model.presentationSummary.rankingCapacity, PresentationHomeSummary.currentRankingCapacity)
        XCTAssertEqual(model.presentationSummary.customAgentsTop.count, PresentationHomeSummary.currentRankingCapacity)
        XCTAssertEqual(model.presentationSummary.customAgentsTop5.count, 5)
    }

    func testRankingUsesIDWhenLocalizedNamesCollateAsEqual() {
        let lower = entry("z", "Alpha", .agent, .customAgents)
        let upper = entry("a", "alpha", .agent, .customAgents)
        let usage = [lower, upper].map {
            CapabilityUsageStats(resourceID: $0.id, callCount: 1, inferredCount: 0, lastUsedAt: nil, coverage: .complete)
        }
        let ranking = HomeOverviewModel(catalog: CapabilityCatalog(resources: [lower, upper]), usage: usage).rankings[.customAgents]
        XCTAssertEqual(ranking?.map(\.id), ["a", "z"])
    }

    func testDualPeriodProjectionKeepsIndependentTopTenSets() {
        let first = entry("a", "Agent A", .agent, .customAgents)
        let second = entry("b", "Agent B", .agent, .customAgents)
        let catalog = CapabilityCatalog(resources: [first, second])
        let sevenDay = [CapabilityUsageStats(resourceID: first.id, callCount: 2, inferredCount: 0, lastUsedAt: nil, coverage: .complete)]
        let thirtyDay = [CapabilityUsageStats(resourceID: second.id, callCount: 8, inferredCount: 1, lastUsedAt: nil, coverage: .partial)]

        let model = HomeOverviewModel(catalog: catalog, usage: sevenDay, thirtyDayUsage: thirtyDay)

        XCTAssertEqual(model.rankings(for: .sevenDays)?[.customAgents]?.map(\.id), ["a"])
        XCTAssertEqual(model.rankings(for: .thirtyDays)?[.customAgents]?.map(\.id), ["b"])
        XCTAssertEqual(model.presentationSummary.thirtyDayRankings?.customAgentsTop.first?.resourceID, "b")
    }

    func testComputedEmptyThirtyDayRankingIsDistinctFromUnavailable() {
        let resource = entry("a", "Agent A", .agent, .customAgents)
        let catalog = CapabilityCatalog(resources: [resource])
        let model = HomeOverviewModel(catalog: catalog, usage: [], thirtyDayUsage: [])
        XCTAssertNotNil(model.presentationSummary.thirtyDayRankings)
        XCTAssertNil(HomeOverviewModel(catalog: catalog, usage: []).presentationSummary.thirtyDayRankings)
    }

    func testLegacyTopFiveDecodesAsCapacityFiveAndNewEncodingIsNeutral() throws {
        let row = PresentationHomeTopRow(resourceID: "agent", name: "Agent", category: .customAgents, count: 2, inferredCount: 1, lastUsedAt: Date(timeIntervalSince1970: 10))
        let summary = PresentationHomeSummary(
            customAgents: 1, customAgentsGlobal: 1, customAgentsProject: 0,
            customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
            installedSkills: 0, installedSkillsIndependent: 0, installedSkillsPluginProvided: 0,
            installedPlugins: 0, enabledPlugins: 0,
            rankingCapacity: 5, customAgentsTop: [row], customSkillsTop: [], installedSkillsTop: []
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(summary)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rankingCapacity")
        object.removeValue(forKey: "customAgentsTop")
        object.removeValue(forKey: "customSkillsTop")
        object.removeValue(forKey: "installedSkillsTop")
        object.removeValue(forKey: "installedSkillRankingScopeVersion")
        object["customAgentsTop5"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([row]))
        object["customSkillsTop5"] = []
        object["installedSkillsTop5"] = []
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(PresentationHomeSummary.self, from: legacyData)
        XCTAssertEqual(legacy.rankingCapacity, 5)
        XCTAssertEqual(legacy.installedSkillRankingScopeVersion, 1)
        XCTAssertTrue(legacy.needsRankingUpgrade)
        XCTAssertEqual(legacy.customAgentsTop5, [row])

        let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(newObject["rankingCapacity"])
        XCTAssertEqual(newObject["installedSkillRankingScopeVersion"] as? Int, 2)
        XCTAssertNotNil(newObject["customAgentsTop"])
        XCTAssertNil(newObject["customAgentsTop5"])
    }

    func testOldHomeCacheKeepsIndependentCountButWaitsForRankingUpgrade() throws {
        let row = PresentationHomeTopRow(resourceID: "plugin-child", name: "Plugin Skill", category: .installedSkills, count: 8, inferredCount: 0, lastUsedAt: nil)
        let old = PresentationHomeSummary(
            customAgents: 0, customAgentsGlobal: 0, customAgentsProject: 0,
            customSkills: 0, customSkillsGlobal: 0, customSkillsProject: 0,
            installedSkills: 2, installedSkillsIndependent: 1, installedSkillsPluginProvided: 1,
            installedPlugins: 1, enabledPlugins: 1,
            installedSkillsTop: [row], thirtyDayRankings: PresentationHomeRankingSet(installedSkillsTop: [row]),
            installedSkillRankingScopeVersion: 1
        )
        let decoded = try JSONDecoder().decode(PresentationHomeSummary.self, from: JSONEncoder().encode(old))
        let model = HomeOverviewModel(summary: decoded)
        XCTAssertEqual(model.inventory.installedSkills, 1)
        XCTAssertFalse(model.installedSkillRankingsVerified)
        XCTAssertTrue(decoded.needsRankingUpgrade)
    }

    func testDeepLinkRowsRetainSharedCategoryAndStableID() {
        let resource = entry("agent-1", "Build", .agent, .customAgents)
        let model = HomeOverviewModel(catalog: CapabilityCatalog(resources: [resource]), usage: [CapabilityUsageStats(resourceID: resource.id, callCount: 2, inferredCount: 0, lastUsedAt: nil, coverage: .complete)])
        let row = model.rankings[.customAgents]?.first
        XCTAssertEqual(row?.category, .customAgents); XCTAssertEqual(row?.id, "agent-1")
    }

    private func entry(_ id: String, _ name: String, _ kind: ResourceKind, _ category: CapabilityCategory, scope: ResourceScope = .global, project: String? = nil, ownership: ResourceOwnership? = nil, origin: ResourceOrigin? = nil, parent: String? = nil, status: RuntimeStatus = .success) -> CapabilityResource {
        let inferredOwnership = ownership ?? (category == .customAgents || category == .customSkills ? .userOwned : category == .installedSkills ? .installed : .runtime)
        let inferredOrigin = origin ?? (category == .installedPlugins ? .runtime : .local)
        return CapabilityResource(id: id, name: name, kind: kind, status: status, scope: scope, projectID: project, confidence: .exact, summary: nil, sourceRootID: "synthetic", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date(), ownership: inferredOwnership, origin: inferredOrigin)
    }
}
