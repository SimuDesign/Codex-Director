import Foundation
import DirectorCore

/// Pure Home projection over the already-classified catalog and seven-day SQL
/// aggregates. It does not infer categories or load raw invocation records.
public struct HomeOverviewModel: Equatable, Sendable {
    public struct InventoryTotals: Equatable, Sendable {
        public let customAgents: Int
        public let customAgentsGlobal: Int
        public let customAgentsProject: Int
        public let customSkills: Int
        public let customSkillsGlobal: Int
        public let customSkillsProject: Int
        public let installedSkills: Int
        public let installedSkillsIndependent: Int
        public let installedSkillsPluginProvided: Int
        public let installedPlugins: Int
        public let enabledPlugins: Int
    }

    public struct RankingRow: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let count: Int
        public let relativeLength: Double
        public let inferred: Bool
        public let inferredCount: Int
        public let lastUsedAt: Date?
        public let category: CapabilityCategory
    }

    public let inventory: InventoryTotals
    public let rankings: [CapabilityCategory: [RankingRow]]

    public init(catalog: CapabilityCatalog, usage: [CapabilityUsageStats]) {
        let entries = catalog.entries
        let customAgents = entries.filter { $0.category == .customAgents }
        let customSkills = entries.filter { $0.category == .customSkills }
        let installedSkills = entries.filter { $0.category == .installedSkills }
        let plugins = entries.filter { $0.category == .installedPlugins }
        func global(_ values: [CapabilityCatalogEntry]) -> Int { values.filter { $0.resource.projectID == nil }.count }
        func project(_ values: [CapabilityCatalogEntry]) -> Int { values.filter { $0.resource.projectID != nil }.count }
        let pluginSkills = installedSkills.filter { $0.parentPluginID != nil }
        self.inventory = InventoryTotals(
            customAgents: customAgents.count, customAgentsGlobal: global(customAgents), customAgentsProject: project(customAgents),
            customSkills: customSkills.count, customSkillsGlobal: global(customSkills), customSkillsProject: project(customSkills),
            installedSkills: installedSkills.count, installedSkillsIndependent: installedSkills.count - pluginSkills.count, installedSkillsPluginProvided: pluginSkills.count,
            installedPlugins: plugins.count, enabledPlugins: plugins.filter { $0.resource.status != .blocked }.count
        )
        let byID = Dictionary(uniqueKeysWithValues: usage.map { ($0.resourceID, $0) })
        var built: [CapabilityCategory: [RankingRow]] = [:]
        for category in [CapabilityCategory.customAgents, .customSkills, .installedSkills] {
            let rows = entries.filter { $0.category == category }.compactMap { entry -> RankingRow? in
                guard let stat = byID[entry.resource.id], stat.callCount > 0 else { return nil }
                return RankingRow(id: entry.resource.id, name: entry.resource.name, count: stat.callCount, relativeLength: 0, inferred: stat.inferredCount > 0, inferredCount: stat.inferredCount, lastUsedAt: stat.lastUsedAt, category: category)
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                let l = byID[$0.id]?.lastUsedAt ?? .distantPast, r = byID[$1.id]?.lastUsedAt ?? .distantPast
                if l != r { return l > r }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }.prefix(PresentationHomeSummary.currentRankingCapacity)
            let maxCount = Double(rows.map(\.count).max() ?? 1)
            built[category] = rows.map { RankingRow(id: $0.id, name: $0.name, count: $0.count, relativeLength: Double($0.count) / maxCount, inferred: $0.inferred, inferredCount: $0.inferredCount, lastUsedAt: $0.lastUsedAt, category: category) }
        }
        rankings = built
    }

    /// Direct projection for the compact presentation cache. It does not
    /// reconstruct a catalog or query/reaggregate invocation history.
    public init(summary: PresentationHomeSummary) {
        inventory = InventoryTotals(
            customAgents: summary.customAgents,
            customAgentsGlobal: summary.customAgentsGlobal,
            customAgentsProject: summary.customAgentsProject,
            customSkills: summary.customSkills,
            customSkillsGlobal: summary.customSkillsGlobal,
            customSkillsProject: summary.customSkillsProject,
            installedSkills: summary.installedSkills,
            installedSkillsIndependent: summary.installedSkillsIndependent,
            installedSkillsPluginProvided: summary.installedSkillsPluginProvided,
            installedPlugins: summary.installedPlugins,
            enabledPlugins: summary.enabledPlugins
        )
        func rows(_ values: [PresentationHomeTopRow]) -> [RankingRow] {
            let maxCount = Double(values.map(\.count).max() ?? 1)
            return values.map {
                RankingRow(id: $0.resourceID, name: $0.name, count: $0.count,
                           relativeLength: Double($0.count) / maxCount,
                           inferred: $0.inferredCount > 0, inferredCount: $0.inferredCount,
                           lastUsedAt: $0.lastUsedAt, category: $0.category)
            }
        }
        rankings = [
            .customAgents: rows(summary.customAgentsTop),
            .customSkills: rows(summary.customSkillsTop),
            .installedSkills: rows(summary.installedSkillsTop)
        ]
    }

    public var presentationSummary: PresentationHomeSummary {
        func top(_ category: CapabilityCategory) -> [PresentationHomeTopRow] {
            (rankings[category] ?? []).prefix(PresentationHomeSummary.currentRankingCapacity).map {
                PresentationHomeTopRow(resourceID: $0.id, name: $0.name, category: $0.category,
                                       count: $0.count, inferredCount: $0.inferredCount,
                                       lastUsedAt: $0.lastUsedAt)
            }
        }
        return PresentationHomeSummary(
            customAgents: inventory.customAgents, customAgentsGlobal: inventory.customAgentsGlobal,
            customAgentsProject: inventory.customAgentsProject, customSkills: inventory.customSkills,
            customSkillsGlobal: inventory.customSkillsGlobal, customSkillsProject: inventory.customSkillsProject,
            installedSkills: inventory.installedSkills, installedSkillsIndependent: inventory.installedSkillsIndependent,
            installedSkillsPluginProvided: inventory.installedSkillsPluginProvided, installedPlugins: inventory.installedPlugins,
            enabledPlugins: inventory.enabledPlugins, rankingCapacity: PresentationHomeSummary.currentRankingCapacity,
            customAgentsTop: top(.customAgents), customSkillsTop: top(.customSkills), installedSkillsTop: top(.installedSkills)
        )
    }
}
