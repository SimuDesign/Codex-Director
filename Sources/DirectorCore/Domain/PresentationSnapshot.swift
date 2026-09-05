import Foundation

public struct PresentationIdentity: Codable, Equatable, Sendable {
    public let databaseEpoch: String
    public let dataGeneration: Int64
    public init(databaseEpoch: String, dataGeneration: Int64) {
        self.databaseEpoch = databaseEpoch; self.dataGeneration = dataGeneration
    }
}

public struct QuotaOverviewDay: Codable, Equatable, Sendable {
    public let day: Date
    public let observation: QuotaSnapshot?
    public let cycleChanged: Bool
    /// Observed percentage-point increase in the reported weekly allowance
    /// during this local calendar day. Nil means the source evidence cannot
    /// support a daily value; it never means zero.
    public let usedPercentDelta: Double?

    public init(
        day: Date,
        observation: QuotaSnapshot?,
        cycleChanged: Bool = false,
        usedPercentDelta: Double? = nil
    ) {
        self.day = day
        self.observation = observation
        self.cycleChanged = cycleChanged
        self.usedPercentDelta = usedPercentDelta
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case observation
        case cycleChanged
        case usedPercentDelta
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(Date.self, forKey: .day)
        observation = try values.decodeIfPresent(QuotaSnapshot.self, forKey: .observation)
        cycleChanged = try values.decodeIfPresent(Bool.self, forKey: .cycleChanged) ?? false
        // Version-1 presentation caches predate daily usage. Keeping this
        // field optional lets the new app start from those caches safely.
        usedPercentDelta = try values.decodeIfPresent(Double.self, forKey: .usedPercentDelta)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(day, forKey: .day)
        try values.encodeIfPresent(observation, forKey: .observation)
        try values.encode(cycleChanged, forKey: .cycleChanged)
        try values.encodeIfPresent(usedPercentDelta, forKey: .usedPercentDelta)
    }
}

public struct QuotaOverviewSourceSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let rawDisplayName: String?
    public let current: QuotaSnapshot?
    public let daily: [QuotaOverviewDay]
    public init(id: String, name: String, rawDisplayName: String? = nil, current: QuotaSnapshot?, daily: [QuotaOverviewDay]) {
        self.id = id; self.name = name; self.rawDisplayName = rawDisplayName; self.current = current; self.daily = Array(daily.prefix(7))
    }
}

public struct QuotaOverviewSnapshot: Codable, Equatable, Sendable {
    public let identity: PresentationIdentity
    public let generatedAt: Date
    public let window: CapabilityQueryWindow
    public let coverage: CoverageState
    public let sources: [QuotaOverviewSourceSnapshot]
    public init(identity: PresentationIdentity, generatedAt: Date = Date(), window: CapabilityQueryWindow, coverage: CoverageState, sources: [QuotaOverviewSourceSnapshot]) {
        self.identity = identity; self.generatedAt = generatedAt; self.window = window; self.coverage = coverage; self.sources = sources
    }
}

public struct PresentationHomeTopRow: Codable, Equatable, Sendable, Identifiable {
    public let resourceID: String; public let name: String; public let category: CapabilityCategory
    public let count: Int; public let inferredCount: Int; public let lastUsedAt: Date?
    public var id: String { resourceID }
    public init(resourceID: String, name: String, category: CapabilityCategory, count: Int, inferredCount: Int, lastUsedAt: Date?) {
        self.resourceID = resourceID; self.name = name; self.category = category; self.count = count; self.inferredCount = inferredCount; self.lastUsedAt = lastUsedAt
    }
}

public struct PresentationHomeSummary: Codable, Equatable, Sendable {
    public static let currentRankingCapacity = 10

    public let customAgents, customAgentsGlobal, customAgentsProject: Int
    public let customSkills, customSkillsGlobal, customSkillsProject: Int
    public let installedSkills, installedSkillsIndependent, installedSkillsPluginProvided: Int
    public let installedPlugins, enabledPlugins: Int
    public let rankingCapacity: Int
    public let customAgentsTop, customSkillsTop, installedSkillsTop: [PresentationHomeTopRow]

    /// Compatibility views for callers that still need to inspect a legacy
    /// Top5 payload. They are intentionally not Codable keys.
    public var customAgentsTop5: [PresentationHomeTopRow] { Array(customAgentsTop.prefix(5)) }
    public var customSkillsTop5: [PresentationHomeTopRow] { Array(customSkillsTop.prefix(5)) }
    public var installedSkillsTop5: [PresentationHomeTopRow] { Array(installedSkillsTop.prefix(5)) }

    public init(customAgents: Int, customAgentsGlobal: Int, customAgentsProject: Int, customSkills: Int, customSkillsGlobal: Int, customSkillsProject: Int, installedSkills: Int, installedSkillsIndependent: Int, installedSkillsPluginProvided: Int, installedPlugins: Int, enabledPlugins: Int, rankingCapacity: Int = currentRankingCapacity, customAgentsTop: [PresentationHomeTopRow] = [], customSkillsTop: [PresentationHomeTopRow] = [], installedSkillsTop: [PresentationHomeTopRow] = []) {
        self.customAgents = customAgents; self.customAgentsGlobal = customAgentsGlobal; self.customAgentsProject = customAgentsProject
        self.customSkills = customSkills; self.customSkillsGlobal = customSkillsGlobal; self.customSkillsProject = customSkillsProject
        self.installedSkills = installedSkills; self.installedSkillsIndependent = installedSkillsIndependent; self.installedSkillsPluginProvided = installedSkillsPluginProvided
        self.installedPlugins = installedPlugins; self.enabledPlugins = enabledPlugins
        self.rankingCapacity = rankingCapacity
        self.customAgentsTop = customAgentsTop; self.customSkillsTop = customSkillsTop; self.installedSkillsTop = installedSkillsTop
    }

    /// Source compatibility for callers that constructed the pre-0.2.2
    /// Top5 payload directly. New writes always use the neutral fields above.
    public init(customAgents: Int, customAgentsGlobal: Int, customAgentsProject: Int, customSkills: Int, customSkillsGlobal: Int, customSkillsProject: Int, installedSkills: Int, installedSkillsIndependent: Int, installedSkillsPluginProvided: Int, installedPlugins: Int, enabledPlugins: Int, customAgentsTop5: [PresentationHomeTopRow], customSkillsTop5: [PresentationHomeTopRow] = [], installedSkillsTop5: [PresentationHomeTopRow] = []) {
        self.init(
            customAgents: customAgents, customAgentsGlobal: customAgentsGlobal, customAgentsProject: customAgentsProject,
            customSkills: customSkills, customSkillsGlobal: customSkillsGlobal, customSkillsProject: customSkillsProject,
            installedSkills: installedSkills, installedSkillsIndependent: installedSkillsIndependent,
            installedSkillsPluginProvided: installedSkillsPluginProvided, installedPlugins: installedPlugins,
            enabledPlugins: enabledPlugins, rankingCapacity: 5,
            customAgentsTop: customAgentsTop5, customSkillsTop: customSkillsTop5, installedSkillsTop: installedSkillsTop5
        )
    }

    private enum CodingKeys: String, CodingKey {
        case customAgents, customAgentsGlobal, customAgentsProject
        case customSkills, customSkillsGlobal, customSkillsProject
        case installedSkills, installedSkillsIndependent, installedSkillsPluginProvided
        case installedPlugins, enabledPlugins
        case rankingCapacity, customAgentsTop, customSkillsTop, installedSkillsTop
        case customAgentsTop5, customSkillsTop5, installedSkillsTop5
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        customAgents = try values.decode(Int.self, forKey: .customAgents)
        customAgentsGlobal = try values.decode(Int.self, forKey: .customAgentsGlobal)
        customAgentsProject = try values.decode(Int.self, forKey: .customAgentsProject)
        customSkills = try values.decode(Int.self, forKey: .customSkills)
        customSkillsGlobal = try values.decode(Int.self, forKey: .customSkillsGlobal)
        customSkillsProject = try values.decode(Int.self, forKey: .customSkillsProject)
        installedSkills = try values.decode(Int.self, forKey: .installedSkills)
        installedSkillsIndependent = try values.decode(Int.self, forKey: .installedSkillsIndependent)
        installedSkillsPluginProvided = try values.decode(Int.self, forKey: .installedSkillsPluginProvided)
        installedPlugins = try values.decode(Int.self, forKey: .installedPlugins)
        enabledPlugins = try values.decode(Int.self, forKey: .enabledPlugins)

        if let capacity = try values.decodeIfPresent(Int.self, forKey: .rankingCapacity) {
            guard (1...Self.currentRankingCapacity).contains(capacity) else { throw DecodingError.dataCorruptedError(forKey: .rankingCapacity, in: values, debugDescription: "Invalid Home ranking capacity") }
            rankingCapacity = capacity
            customAgentsTop = try values.decode([PresentationHomeTopRow].self, forKey: .customAgentsTop)
            customSkillsTop = try values.decode([PresentationHomeTopRow].self, forKey: .customSkillsTop)
            installedSkillsTop = try values.decode([PresentationHomeTopRow].self, forKey: .installedSkillsTop)
        } else {
            guard !values.contains(.customAgentsTop),
                  !values.contains(.customSkillsTop),
                  !values.contains(.installedSkillsTop) else {
                throw DecodingError.dataCorruptedError(forKey: .rankingCapacity, in: values, debugDescription: "Neutral Home ranking fields require rankingCapacity")
            }
            rankingCapacity = 5
            customAgentsTop = try values.decodeIfPresent([PresentationHomeTopRow].self, forKey: .customAgentsTop5) ?? []
            customSkillsTop = try values.decodeIfPresent([PresentationHomeTopRow].self, forKey: .customSkillsTop5) ?? []
            installedSkillsTop = try values.decodeIfPresent([PresentationHomeTopRow].self, forKey: .installedSkillsTop5) ?? []
        }
        guard customAgentsTop.count <= rankingCapacity,
              customSkillsTop.count <= rankingCapacity,
              installedSkillsTop.count <= rankingCapacity else {
            throw DecodingError.dataCorruptedError(forKey: .rankingCapacity, in: values, debugDescription: "Home ranking exceeds declared capacity")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(customAgents, forKey: .customAgents)
        try values.encode(customAgentsGlobal, forKey: .customAgentsGlobal)
        try values.encode(customAgentsProject, forKey: .customAgentsProject)
        try values.encode(customSkills, forKey: .customSkills)
        try values.encode(customSkillsGlobal, forKey: .customSkillsGlobal)
        try values.encode(customSkillsProject, forKey: .customSkillsProject)
        try values.encode(installedSkills, forKey: .installedSkills)
        try values.encode(installedSkillsIndependent, forKey: .installedSkillsIndependent)
        try values.encode(installedSkillsPluginProvided, forKey: .installedSkillsPluginProvided)
        try values.encode(installedPlugins, forKey: .installedPlugins)
        try values.encode(enabledPlugins, forKey: .enabledPlugins)
        try values.encode(rankingCapacity, forKey: .rankingCapacity)
        try values.encode(customAgentsTop, forKey: .customAgentsTop)
        try values.encode(customSkillsTop, forKey: .customSkillsTop)
        try values.encode(installedSkillsTop, forKey: .installedSkillsTop)
    }
}

public struct PresentationTaskCallSummary: Codable, Equatable, Sendable, Identifiable {
    public let taskID: String
    public let projectID: String?
    public let callCount: Int
    public let failureCount: Int
    public let lastUsedAt: Date?
    public var id: String { taskID }
    public init(taskID: String, projectID: String?, callCount: Int, failureCount: Int = 0, lastUsedAt: Date?) {
        self.taskID = taskID; self.projectID = projectID; self.callCount = callCount; self.failureCount = failureCount; self.lastUsedAt = lastUsedAt
    }
}

public struct PresentationIndexMetadata: Codable, Equatable, Sendable {
    public let identity: PresentationIdentity
    public let lastSourceCheckAt: Date?
    public let lastIndexCompletedAt: Date?
    public init(identity: PresentationIdentity, lastSourceCheckAt: Date?, lastIndexCompletedAt: Date?) {
        self.identity = identity; self.lastSourceCheckAt = lastSourceCheckAt; self.lastIndexCompletedAt = lastIndexCompletedAt
    }
}

public struct PresentationDirectorySnapshot: Codable, Equatable, Sendable {
    public let metadata: PresentationIndexMetadata
    public let resources: [CapabilityResource]
    public let relations: [ResourceRelation]
    public let projects: [CapabilityProject]
    public let provenance: [CapabilityProvenance]
    public let indexedSessionCount: Int
    public init(metadata: PresentationIndexMetadata, resources: [CapabilityResource], relations: [ResourceRelation], projects: [CapabilityProject], provenance: [CapabilityProvenance], indexedSessionCount: Int) {
        self.metadata = metadata; self.resources = resources; self.relations = relations; self.projects = projects; self.provenance = provenance; self.indexedSessionCount = indexedSessionCount
    }
}

/// Persisted scheduler metadata for presentation refreshes. This is optional
/// in the presentation cache so snapshots written before scheduler state was
/// introduced remain readable without a schema-version bump.
public struct PresentationRefreshSchedule: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let recordedAt: Date
    public let lastSourceSuccessAt: Date?
    public let sourceRetryAttempt: Int
    public let sourceRetryDate: Date?
    public let projectionRetryAttempt: Int
    public let projectionRetryDate: Date?

    public init(
        revision: UInt64 = 0,
        recordedAt: Date,
        lastSourceSuccessAt: Date? = nil,
        sourceRetryAttempt: Int = 0,
        sourceRetryDate: Date? = nil,
        projectionRetryAttempt: Int = 0,
        projectionRetryDate: Date? = nil
    ) {
        self.revision = revision
        self.recordedAt = recordedAt
        self.lastSourceSuccessAt = lastSourceSuccessAt
        self.sourceRetryAttempt = sourceRetryAttempt
        self.sourceRetryDate = sourceRetryDate
        self.projectionRetryAttempt = projectionRetryAttempt
        self.projectionRetryDate = projectionRetryDate
    }
}

public struct StartupPresentationSnapshot: Sendable, Equatable {
    public let directory: PresentationDirectorySnapshot
    public let recentUsage: [CapabilityUsageStats]
    public let quota: QuotaOverviewSnapshot
    public init(directory: PresentationDirectorySnapshot, recentUsage: [CapabilityUsageStats], quota: QuotaOverviewSnapshot) {
        self.directory = directory; self.recentUsage = recentUsage; self.quota = quota
    }
}

/// Compact Home-only input. It intentionally excludes quota and raw history so
/// a Top10 cache upgrade cannot turn into a full startup refresh.
public struct HomeRankingPresentationSnapshot: Sendable, Equatable {
    public let directory: PresentationDirectorySnapshot
    public let recentUsage: [CapabilityUsageStats]

    public init(directory: PresentationDirectorySnapshot, recentUsage: [CapabilityUsageStats]) {
        self.directory = directory
        self.recentUsage = recentUsage
    }
}

public struct LibraryPresentationSnapshot: Sendable, Equatable {
    public let metadata: PresentationIndexMetadata
    public let categoryUsage: [CapabilityUsageStats]
    public let browseUsage: [CapabilityUsageStats]
    public let browseHistory: [CapabilityHistory]
    public let usageProjects: [String: Set<String>]
    public let categoryPluginUsage: [PluginUsageResult]
    public let browsePluginUsage: [PluginUsageResult]
    /// All-time category history is used for recency/detail presentation. It
    /// is kept separate from the bounded recent-seven-day aggregate.
    public let categoryHistory: [CapabilityHistory]
    /// Bounded current-local-day + preceding 29 natural days aggregates used
    /// by the inactive filter. A missing row means zero only after the query
    /// has completed successfully.
    public let category30DayUsage: [CapabilityUsageStats]
    public let browse30DayUsage: [CapabilityUsageStats]
    public let categoryPlugin30DayUsage: [PluginUsageResult]
    public let browsePlugin30DayUsage: [PluginUsageResult]
    /// Number of current plugins whose call evidence cannot be conservatively
    /// attributed. These are never counted as inactive.
    public let pluginAttributionUnavailableCount: Int

    public init(
        metadata: PresentationIndexMetadata,
        categoryUsage: [CapabilityUsageStats],
        browseUsage: [CapabilityUsageStats],
        browseHistory: [CapabilityHistory],
        usageProjects: [String: Set<String>],
        categoryPluginUsage: [PluginUsageResult],
        browsePluginUsage: [PluginUsageResult],
        categoryHistory: [CapabilityHistory] = [],
        category30DayUsage: [CapabilityUsageStats] = [],
        browse30DayUsage: [CapabilityUsageStats] = [],
        categoryPlugin30DayUsage: [PluginUsageResult] = [],
        browsePlugin30DayUsage: [PluginUsageResult] = [],
        pluginAttributionUnavailableCount: Int? = nil
    ) {
        self.metadata = metadata; self.categoryUsage = categoryUsage; self.browseUsage = browseUsage; self.browseHistory = browseHistory; self.usageProjects = usageProjects; self.categoryPluginUsage = categoryPluginUsage; self.browsePluginUsage = browsePluginUsage
        self.categoryHistory = categoryHistory
        self.category30DayUsage = category30DayUsage
        self.browse30DayUsage = browse30DayUsage
        self.categoryPlugin30DayUsage = categoryPlugin30DayUsage
        self.browsePlugin30DayUsage = browsePlugin30DayUsage
        self.pluginAttributionUnavailableCount = pluginAttributionUnavailableCount ?? categoryPluginUsage.filter { $0.callCount == nil }.count
    }

    // Stable aliases make the intent clear at call sites without breaking the
    // original presentation DTO vocabulary.
    public var categoryGlobalHistory: [CapabilityHistory] { categoryHistory }
    public var pluginUnavailableCount: Int { pluginAttributionUnavailableCount }
}

public struct PresentationSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let identity: PresentationIdentity
    public let classificationRevision: String
    public let window: CapabilityQueryWindow
    public let generatedAt: Date
    public let lastSourceCheckAt, lastIndexCompletedAt, statisticsThrough: Date?
    public let quota: QuotaOverviewSnapshot?
    public let home: PresentationHomeSummary?
    public let failureCount: Int
    public let nextRetryAt: Date?
    public let refreshSchedule: PresentationRefreshSchedule?
    public init(schemaVersion: Int = currentSchemaVersion, identity: PresentationIdentity, classificationRevision: String, window: CapabilityQueryWindow, generatedAt: Date = Date(), lastSourceCheckAt: Date? = nil, lastIndexCompletedAt: Date? = nil, statisticsThrough: Date? = nil, quota: QuotaOverviewSnapshot? = nil, home: PresentationHomeSummary? = nil, failureCount: Int = 0, nextRetryAt: Date? = nil, refreshSchedule: PresentationRefreshSchedule? = nil) {
        self.schemaVersion = schemaVersion; self.identity = identity; self.classificationRevision = classificationRevision; self.window = window; self.generatedAt = generatedAt; self.lastSourceCheckAt = lastSourceCheckAt; self.lastIndexCompletedAt = lastIndexCompletedAt; self.statisticsThrough = statisticsThrough; self.quota = quota; self.home = home; self.failureCount = failureCount; self.nextRetryAt = nextRetryAt; self.refreshSchedule = refreshSchedule
    }
}
