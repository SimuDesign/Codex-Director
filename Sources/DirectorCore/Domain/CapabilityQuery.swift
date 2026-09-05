import Foundation

/// The four user-facing capability categories. Runtime resources are kept out
/// of these categories unless they are represented as an installed plugin or
/// a Skill provided by one.
public enum CapabilityCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case customAgents
    case customSkills
    case installedSkills
    case installedPlugins
}

public enum CapabilitySort: String, Codable, Sendable, CaseIterable, Hashable {
    case recentUsageDescending
    case usageAscending
    case usageDescending
    case recentUsageAscending
    case nameAscending
    case modifiedDescending
}

/// Activity filters used by the capability library.  The window is evaluated
/// against the current presentation clock and is intentionally independent of
/// the list search and configuration scope.
public enum CapabilityActivityFilter: String, Codable, Sendable, CaseIterable, Hashable {
    case all
    case recent7
    case notUsed30

    // Readable aliases for clients that describe the filter in product terms.
    public static var usedPast7Days: Self { .recent7 }
    public static var unusedPast30Days: Self { .notUsed30 }
}

/// Installed-plugin status is a presentation filter, not a runtime resource
/// classification.  Disabled plugins remain installed and discoverable.
public enum CapabilityPluginStatusFilter: String, Codable, Sendable, CaseIterable, Hashable {
    case all
    case enabled
    case disabled
}

/// Stable semantic identity for the four summary cards shown by a capability
/// category.  Keeping this typed avoids stringly-typed actions drifting from
/// their labels, symbols, and accessibility values.
public enum CapabilitySummaryMetricKind: String, Codable, Sendable, CaseIterable, Hashable {
    case global
    case project
    case recent7
    case notUsed30
    case installed
    case enabled
    case attributionUnavailable
}

/// The stable browse state shared by home, list, and detail queries.
public enum CapabilityBrowseScope: Codable, Sendable, Equatable, Hashable {
    case global
    case allProjects
    case allCapabilities
    case project(String)
}

public struct CapabilityBrowseContext: Codable, Sendable, Equatable, Hashable {
    public let scope: CapabilityBrowseScope
    public let search: String
    public let sort: CapabilitySort
    public let activityFilter: CapabilityActivityFilter
    public let pluginStatusFilter: CapabilityPluginStatusFilter

    public init(
        scope: CapabilityBrowseScope = .allCapabilities,
        search: String = "",
        sort: CapabilitySort = .recentUsageDescending,
        activityFilter: CapabilityActivityFilter = .all,
        pluginStatusFilter: CapabilityPluginStatusFilter = .all
    ) {
        self.scope = scope
        self.search = search
        self.sort = sort
        self.activityFilter = activityFilter
        self.pluginStatusFilter = pluginStatusFilter
    }

    public func updated(
        scope: CapabilityBrowseScope? = nil,
        search: String? = nil,
        sort: CapabilitySort? = nil,
        activityFilter: CapabilityActivityFilter? = nil,
        pluginStatusFilter: CapabilityPluginStatusFilter? = nil
    ) -> Self {
        Self(scope: scope ?? self.scope, search: search ?? self.search, sort: sort ?? self.sort, activityFilter: activityFilter ?? self.activityFilter, pluginStatusFilter: pluginStatusFilter ?? self.pluginStatusFilter)
    }
}

/// An explicit closed query interval from `start` through `end` (inclusive).
/// Dates are persisted as UTC instants; the timezone is used only to calculate
/// a natural-day boundary.
public struct CapabilityQueryWindow: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    public init(start: Date, end: Date, timeZone: TimeZone = .current) {
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZone.identifier
    }

    public static func recent7(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> CapabilityQueryWindow {
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: day) ?? day
        return CapabilityQueryWindow(start: start, end: now, timeZone: calendar.timeZone)
    }

    /// Current local natural day plus the preceding 29 natural days.  The
    /// upper bound is the injected `now`, so future-dated records never count.
    public static func recent30(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> CapabilityQueryWindow {
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: day) ?? day
        return CapabilityQueryWindow(start: start, end: now, timeZone: calendar.timeZone)
    }

    public static func recentThirtyDays(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> CapabilityQueryWindow {
        recent30(now: now, calendar: calendar)
    }
}

public struct CapabilityUsageStats: Sendable, Equatable {
    public let resourceID: String
    public let callCount: Int
    public let inferredCount: Int
    public let lastUsedAt: Date?
    public let coverage: CoverageState

    public init(resourceID: String, callCount: Int, inferredCount: Int, lastUsedAt: Date?, coverage: CoverageState) {
        self.resourceID = resourceID
        self.callCount = callCount
        self.inferredCount = inferredCount
        self.lastUsedAt = lastUsedAt
        self.coverage = coverage
    }
}

public struct CapabilityInvocationPage: Sendable, Equatable {
    public let items: [InvocationEvent]
    public let nextCursor: String?

    public init(items: [InvocationEvent], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct CapabilityCatalogEntry: Sendable, Equatable {
    public let resource: CapabilityResource
    public let category: CapabilityCategory?
    public let parentPluginID: String?

    public init(resource: CapabilityResource, category: CapabilityCategory?, parentPluginID: String?) {
        self.resource = resource
        self.category = category
        self.parentPluginID = parentPluginID
    }
}

/// Pure projection shared by home and library views. It never merges by name.
public struct CapabilityCatalog: Sendable, Equatable {
    public let entries: [CapabilityCatalogEntry]

    public init(resources: [CapabilityResource], relations: [ResourceRelation] = []) {
        let currentPlugins = Set(resources.filter { $0.kind == .plugin && $0.scope == .runtime && $0.sourceRootID != "last-known-runtime" && ($0.origin == .runtime || $0.origin == .plugin) }.map(\.id))
        let parentCandidates = Dictionary(grouping: relations.filter { $0.relationKind == "contains" && currentPlugins.contains($0.sourceResourceID) }, by: \.targetResourceID)
        let parentByChild = parentCandidates.compactMapValues { values -> String? in
            let ids = Set(values.map(\.sourceResourceID))
            guard ids.count == 1, let id = ids.first, currentPlugins.contains(id) else { return nil }
            return id
        }
        entries = resources.map { resource in
            let category: CapabilityCategory?
            switch resource.kind {
            case .agent where resource.ownership == .userOwned: category = .customAgents
            case .skill where resource.ownership == .userOwned: category = .customSkills
            case .skill where resource.ownership == .installed: category = .installedSkills
            case .skill where resource.ownership == .pluginProvided && parentByChild[resource.id] != nil: category = .installedSkills
            case .plugin where resource.scope == .runtime && resource.sourceRootID != "last-known-runtime" && (resource.origin == .runtime || resource.origin == .plugin): category = .installedPlugins
            default: category = nil
            }
            return CapabilityCatalogEntry(resource: resource, category: category, parentPluginID: parentByChild[resource.id])
        }
    }
}

public struct CapabilityHistory: Sendable, Equatable {
    public let resourceID: String
    public let callCount: Int
    public let lastUsedAt: Date?
    public init(resourceID: String, callCount: Int, lastUsedAt: Date?) {
        self.resourceID = resourceID; self.callCount = callCount; self.lastUsedAt = lastUsedAt
    }
}

public struct PluginUsageResult: Sendable, Equatable {
    public let pluginID: String
    public let callCount: Int?
    public let inferredCount: Int
    public let projectIDs: [String]
    public let lastUsedAt: Date?
    public let coverage: CoverageState
    public init(pluginID: String, callCount: Int?, inferredCount: Int = 0, projectIDs: [String] = [], lastUsedAt: Date? = nil, coverage: CoverageState = .unknown) {
        self.pluginID = pluginID; self.callCount = callCount; self.inferredCount = inferredCount; self.projectIDs = projectIDs; self.lastUsedAt = lastUsedAt; self.coverage = coverage
    }
}

public struct AttributedInvocation: Sendable, Equatable {
    public let original: InvocationEvent
    public let projectID: String?
    public let pluginID: String
    public let confidence: EvidenceConfidence
    public init(original: InvocationEvent, projectID: String?, pluginID: String, confidence: EvidenceConfidence) {
        self.original = original; self.projectID = projectID; self.pluginID = pluginID; self.confidence = confidence
    }
}

public struct PluginInvocationPage: Sendable, Equatable {
    public let items: [AttributedInvocation]
    public let nextCursor: String?
    public init(items: [AttributedInvocation], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }
}

public enum PluginUsage {
    public struct Mapping: Sendable, Equatable {
        public let pluginID: String
        public let skillIDs: [String]
        public let namespaces: [String]
        public init(pluginID: String, skillIDs: [String], namespaces: [String]) {
            self.pluginID = pluginID; self.skillIDs = skillIDs; self.namespaces = namespaces
        }
    }

    /// Builds the conservative, current-runtime attribution contract shared by
    /// the in-memory projection and SQLite queries. A child with more than one
    /// current owner is never attributed; MCP namespaces must have exactly one
    /// plugin owner and no independent current MCP with the same name.
    public static func mappings(resources: [CapabilityResource], relations: [ResourceRelation]) -> [Mapping] {
        let currentPlugins = Set(resources.filter { $0.kind == .plugin && $0.scope == .runtime && $0.sourceRootID != "last-known-runtime" && ($0.origin == .runtime || $0.origin == .plugin) }.map(\.id))
        let byTarget = Dictionary(grouping: relations.filter { $0.relationKind == "contains" }, by: \.targetResourceID)
        let byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        func owners(of resourceID: String) -> Set<String> {
            var result = Set<String>(), pending = [resourceID], visited = Set<String>()
            while let id = pending.popLast(), visited.insert(id).inserted {
                if currentPlugins.contains(id) { result.insert(id) }
                pending.append(contentsOf: byTarget[id, default: []].map(\.sourceResourceID))
            }
            return result
        }
        var skillOwners: [String: Set<String>] = [:], namespaceOwners: [String: Set<String>] = [:]
        var independentNamespaces = Set<String>()
        for resource in resources {
            let owners = owners(of: resource.id)
            let currentChild = resource.sourceRootID != "last-known-runtime" && (resource.origin == .runtime || resource.origin == .plugin)
            if resource.kind == .skill && currentChild { skillOwners[resource.id] = owners }
            if resource.kind == .mcp && currentChild, !resource.name.isEmpty {
                if owners.isEmpty { independentNamespaces.insert(resource.name) }
                else { namespaceOwners[resource.name, default: []].formUnion(owners) }
            }
        }
        return currentPlugins.sorted().map { pluginID in
            let skills = skillOwners.compactMap { id, owners in owners.count == 1 && owners.contains(pluginID) && byID[id]?.kind == .skill ? id : nil }.sorted()
            let namespaces = namespaceOwners.compactMap { name, owners in
                owners.count == 1 && owners.contains(pluginID) && !independentNamespaces.contains(name) ? name : nil
            }.sorted()
            return Mapping(pluginID: pluginID, skillIDs: skills, namespaces: namespaces)
        }
    }

    /// Attributes child Skill events to their uniquely containing current
    /// Plugin. Namespace mappings are supplied only from current manifests.
    /// Ambiguous mappings are intentionally omitted and therefore cannot be
    /// mistaken for zero usage.
    public static func attribute(
        calls: [InvocationEvent],
        catalog: CapabilityCatalog,
        projectIDs: [String: String?] = [:],
        namespaceToPlugin: [String: String] = [:],
        ambiguousNamespaces: Set<String> = []
    ) -> [AttributedInvocation] {
        let parents = Dictionary(grouping: catalog.entries.compactMap { entry -> (String, String)? in
            guard let parent = entry.parentPluginID else { return nil }
            return (entry.resource.id, parent)
        }, by: { $0.0 }).compactMapValues { Set($0.map(\.1)).count == 1 ? $0.first?.1 : nil }
        var candidates: [AttributedInvocation] = []
        for call in calls {
            if let parent = parents[call.resourceID ?? ""] {
                candidates.append(AttributedInvocation(original: call, projectID: projectIDs[call.sessionID] ?? nil, pluginID: parent, confidence: call.confidence))
                continue
            }
            if let actor = call.actorName, !ambiguousNamespaces.contains(actor), let parent = namespaceToPlugin[actor] {
                candidates.append(AttributedInvocation(original: call, projectID: projectIDs[call.sessionID] ?? nil, pluginID: parent, confidence: .inferred))
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
        return candidates.filter { candidate in
            candidates.allSatisfy { possibleDescendant in
                guard possibleDescendant.pluginID == candidate.pluginID,
                      possibleDescendant.original.id != candidate.original.id else { return true }
                var childID = possibleDescendant.original.id
                var visited = Set<String>()
                while let parent = byID[childID]?.parentCallID, visited.insert(parent).inserted {
                    if parent == candidate.original.id { return false }
                    childID = parent
                }
                return true
            }
        }
    }
}
