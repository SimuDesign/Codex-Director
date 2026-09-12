import Foundation

/// The owner of a capability folder. Only custom and self-training folders
/// are persisted; global and project folders are derived from the catalog.
public enum CapabilityFolderSource: String, Codable, CaseIterable, Hashable, Sendable {
    case selfTraining
    case custom
    case global
    case project
}

/// A stable folder definition. User-entered names are kept verbatim after
/// trimming and are never used as identity.
public struct CapabilityFolderDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let selfTrainingID = "self-training"
    public static let globalID = "global"

    public let id: String
    public let source: CapabilityFolderSource
    public let customName: String?
    public let projectID: String?
    public let projectName: String?

    public init(
        id: String,
        source: CapabilityFolderSource,
        customName: String? = nil,
        projectID: String? = nil,
        projectName: String? = nil
    ) {
        self.id = id
        self.source = source
        self.customName = customName
        self.projectID = projectID
        self.projectName = projectName
    }

    public var isCustom: Bool { source == .custom || source == .selfTraining }
    public var isDefault: Bool { !isCustom }
    public var isSelfTraining: Bool { source == .selfTraining }

    public func displayName(language: CapabilityFolderLanguage = .english) -> String {
        if let customName, !customName.isEmpty { return customName }
        switch source {
        case .selfTraining:
            return language == .simplifiedChinese ? "自我训练" : "Self Training"
        case .global:
            return language == .simplifiedChinese ? "全局" : "Global"
        case .project:
            return projectName ?? projectID ?? (language == .simplifiedChinese ? "项目" : "Project")
        case .custom:
            return language == .simplifiedChinese ? "文件夹" : "Folder"
        }
    }
}

public enum CapabilityFolderLanguage: Sendable {
    case simplifiedChinese
    case english
}

/// The fixed browsing modes shared by Global, Project and custom folders.
public enum CapabilityFolderTab: String, CaseIterable, Codable, Hashable, Sendable {
    case agentCompanions
    case agents
    case skills
}

/// A many-to-many membership relation. Duplicate pairs are discarded by the
/// preferences initializer and by the store validator.
public struct CapabilityFolderMembership: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let folderID: String
    public let resourceID: String
    public var id: String { "\(folderID)::\(resourceID)" }

    public init(folderID: String, resourceID: String) {
        self.folderID = folderID
        self.resourceID = resourceID
    }
}

/// Independent, application-owned folder preferences. The array order is the
/// user-visible order in “My Folders”. Stale resource IDs intentionally remain
/// so a capability can reappear after a rebuild without losing organization.
public struct CapabilityFolderPreferencesV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let currentSelfTrainingSeedVersion = 1
    public let version: Int
    public let initialized: Bool
    /// Optional so folder preferences written by the first 1.3.0 build remain
    /// decodable. `nil` means the one-time Self Training membership seed has
    /// not run against a successfully loaded capability directory yet.
    public let selfTrainingSeedVersion: Int?
    public let customFolders: [CapabilityFolderDefinition]
    public let memberships: [CapabilityFolderMembership]

    public init(
        version: Int = Self.currentVersion,
        initialized: Bool = true,
        selfTrainingSeedVersion: Int? = nil,
        customFolders: [CapabilityFolderDefinition] = [],
        memberships: [CapabilityFolderMembership] = []
    ) {
        self.version = version
        self.initialized = initialized
        self.selfTrainingSeedVersion = selfTrainingSeedVersion
        var seenFolderIDs = Set<String>()
        self.customFolders = customFolders.filter { folder in
            guard folder.isCustom, !folder.id.isEmpty, seenFolderIDs.insert(folder.id).inserted else { return false }
            return true
        }
        var seenMemberships = Set<String>()
        self.memberships = memberships.filter { membership in
            guard !membership.folderID.isEmpty, !membership.resourceID.isEmpty else { return false }
            return seenMemberships.insert(membership.id).inserted
        }
    }

    public static func initial() -> Self {
        Self(customFolders: [CapabilityFolderDefinition(id: CapabilityFolderDefinition.selfTrainingID, source: .selfTraining)])
    }

    /// Legacy compatibility hook from the unpublished folder browser build.
    /// Self Training is intentionally empty for new installs, and the new
    /// behavior must never add memberships implicitly. Existing memberships
    /// are returned unchanged so upgrades preserve the user's organization.
    public func applyingInitialSelfTrainingMemberships(
        from resources: [CapabilityResource]
    ) -> Self {
        _ = resources
        return self
    }
}

public enum CapabilityFolderStoreError: Error, Equatable, Sendable {
    case persistenceFailed
    case corruptedPreferences
    case invalidFolderName
    case duplicateFolderName
    case immutableFolder
    case missingFolder
    case invalidMembership
}

public enum CapabilityFolderPreferencesState: String, Codable, Equatable, Sendable {
    case missing
    case valid
    case corrupted
}

public enum CapabilityFolderMoveDirection: Sendable {
    case up
    case down
}

/// UserDefaults-backed, injectable folder storage. Initialization is explicit
/// so the legacy grouping key can be removed only after the new document has
/// been written successfully.
public final class CapabilityFolderStore: @unchecked Sendable {
    public static let defaultsKey = "com.peiweitang.CodexDirector.capabilityFolders.v1"
    /// Retained only for the one-way cleanup from the unpublished grouping
    /// experiment. Keeping the literal here makes this store independently
    /// removable once old grouping compatibility is retired.
    public static let legacyDefaultsKey = "com.peiweitang.CodexDirector.capabilityGrouping.v1"

    private let readData: () -> Data?
    private let writeData: (Data) -> Bool
    private let removeData: () -> Void
    private let removeLegacyData: () -> Void

    public init(defaults: UserDefaults = .standard) {
        readData = { defaults.data(forKey: Self.defaultsKey) }
        writeData = { data in
            defaults.set(data, forKey: Self.defaultsKey)
            return true
        }
        removeData = { defaults.removeObject(forKey: Self.defaultsKey) }
        removeLegacyData = { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
    }

    public init(memoryPreferences: CapabilityFolderPreferencesV1? = nil, legacyData: Data? = nil) {
        var value = memoryPreferences.flatMap { try? JSONEncoder().encode($0) }
        _ = legacyData
        readData = { value }
        writeData = { data in value = data; return true }
        removeData = { value = nil }
        removeLegacyData = {}
    }

    public init(
        readData: @escaping () -> Data?,
        writeData: @escaping (Data) -> Bool,
        removeData: @escaping () -> Void,
        removeLegacyData: @escaping () -> Void = {}
    ) {
        self.readData = readData
        self.writeData = writeData
        self.removeData = removeData
        self.removeLegacyData = removeLegacyData
    }

    public func preferences() -> CapabilityFolderPreferencesV1 {
        guard case .valid = preferencesState(), let data = readData(), let value = try? JSONDecoder().decode(CapabilityFolderPreferencesV1.self, from: data) else {
            return .init()
        }
        return value
    }

    public func preferencesState() -> CapabilityFolderPreferencesState {
        guard let data = readData() else { return .missing }
        guard let value = try? JSONDecoder().decode(CapabilityFolderPreferencesV1.self, from: data), Self.isValid(value) else { return .corrupted }
        return .valid
    }

    /// Creates the Self Training folder definition exactly once. Memberships
    /// are populated only after the capability directory loads successfully.
    /// A failed write leaves both new and legacy data untouched.
    @discardableResult
    public func ensureInitialized() throws -> CapabilityFolderPreferencesV1 {
        switch preferencesState() {
        case .valid:
            let current = preferences()
            removeLegacyData()
            return current
        case .corrupted:
            throw CapabilityFolderStoreError.corruptedPreferences
        case .missing:
            let initial = CapabilityFolderPreferencesV1.initial()
            try save(initial)
            removeLegacyData()
            return initial
        }
    }

    public func save(_ preferences: CapabilityFolderPreferencesV1) throws {
        guard preferencesState() != .corrupted else { throw CapabilityFolderStoreError.corruptedPreferences }
        guard Self.isValid(preferences) else { throw CapabilityFolderStoreError.invalidMembership }
        let data = try JSONEncoder().encode(preferences)
        guard writeData(data) else { throw CapabilityFolderStoreError.persistenceFailed }
    }

    public func clear() { removeData() }

    public func clearCorruptedPreferences() {
        guard preferencesState() == .corrupted else { return }
        removeData()
    }

    private static func isValid(_ value: CapabilityFolderPreferencesV1) -> Bool {
        guard value.version == CapabilityFolderPreferencesV1.currentVersion else { return false }
        guard value.initialized else { return false }
        guard value.selfTrainingSeedVersion == nil
                || value.selfTrainingSeedVersion == CapabilityFolderPreferencesV1.currentSelfTrainingSeedVersion else { return false }
        let folders = value.customFolders
        guard folders.allSatisfy({ folder in
            folder.isCustom && !folder.id.isEmpty && (folder.source != .custom || folder.customName?.isEmpty == false)
        }) else { return false }
        guard Set(folders.map(\.id)).count == folders.count else { return false }
        guard folders.filter(\.isSelfTraining).count <= 1 else { return false }
        let normalizedNames = folders.compactMap(\.customName).map(Self.normalizedName)
        guard Set(normalizedNames).count == normalizedNames.count else { return false }
        guard folders.allSatisfy({ folder in
            guard let name = folder.customName else { return true }
            return name == name.trimmingCharacters(in: .whitespacesAndNewlines) && name.count >= 1 && name.count <= 40
        }) else { return false }
        var pairIDs = Set<String>()
        for membership in value.memberships {
            guard !membership.folderID.isEmpty, !membership.resourceID.isEmpty else { return false }
            guard folders.contains(where: { $0.id == membership.folderID }) else { return false }
            guard pairIDs.insert(membership.id).inserted else { return false }
        }
        return true
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct CapabilityFolderMember: Identifiable, Equatable, Sendable {
    public let resource: CapabilityResource
    public var id: String { resource.id }
    public init(resource: CapabilityResource) { self.resource = resource }
}

/// Live folder projection. Default folders are regenerated from the current
/// capability catalog, while custom memberships are read from the store.
public struct CapabilityFolderProjection: Equatable, Sendable {
    public let folders: [CapabilityFolderDefinition]
    public let resources: [CapabilityResource]
    public let projects: [CapabilityProject]
    /// Explicit Agent/Skill declarations projected from the same indexed
    /// snapshot. These are separate from generic topology edges and never
    /// alter folder membership.
    public let companionRelations: [CapabilityCompanionRelation]
    private let membersByFolder: [String: [CapabilityFolderMember]]

    public init(
        resources: [CapabilityResource],
        projects: [CapabilityProject] = [],
        preferences: CapabilityFolderPreferencesV1 = .initial(),
        relations: [ResourceRelation] = []
    ) {
        let eligible = Self.eligibleResources(resources)
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var defaults = [CapabilityFolderDefinition(id: CapabilityFolderDefinition.globalID, source: .global)]
        let projectIDs = Set(eligible.compactMap { resource -> String? in
            guard resource.ownership != .pluginProvided else { return nil }
            return resource.projectID
        })
        let projectNameCounts = Dictionary(grouping: projectByID.values) { project in
            Self.normalizedProjectName(project.name)
        }.mapValues(\.count)
        defaults += projectIDs.map { id in
            let project = projectByID[id]
            let name = project?.name
            let normalized = name.map(Self.normalizedProjectName) ?? ""
            let displayName: String?
            if let name, (projectNameCounts[normalized] ?? 0) > 1 {
                displayName = "\(name) · \(Self.shortProjectID(id))"
            } else {
                displayName = name
            }
            return CapabilityFolderDefinition(id: "project::\(id)", source: .project, projectID: id, projectName: displayName)
        }.sorted { lhs, rhs in
            let left = lhs.projectName ?? lhs.projectID ?? ""
            let right = rhs.projectName ?? rhs.projectID ?? ""
            let compare = left.localizedStandardCompare(right)
            return compare == .orderedSame ? lhs.id < rhs.id : compare == .orderedAscending
        }
        let allFolders = preferences.customFolders + defaults
        self.folders = allFolders
        self.resources = eligible
        self.projects = projects
        let eligibleIDs = Set(eligible.map(\.id))
        let discoveredRelations = CapabilityCompanionResolver.relations(from: relations).filter {
            eligibleIDs.contains($0.agentID) && eligibleIDs.contains($0.skillID)
        }
        // Registry, Agent TOML, Brief and Skill-description declarations may
        // describe the same logical pair. Keep one deterministic projection
        // entry so list counts and evidence maps cannot double-count it.
        var canonicalByPair: [String: CapabilityCompanionRelation] = [:]
        for relation in discoveredRelations.sorted(by: { $0.id < $1.id }) {
            canonicalByPair[relation.pairID] = canonicalByPair[relation.pairID] ?? relation
        }
        self.companionRelations = canonicalByPair.values.sorted {
            $0.agentID == $1.agentID
                ? ($0.skillID == $1.skillID ? $0.id < $1.id : $0.skillID < $1.skillID)
                : $0.agentID < $1.agentID
        }
        var map: [String: [CapabilityFolderMember]] = [:]
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        map[CapabilityFolderDefinition.globalID] = eligible.filter { resource in
            resource.ownership == .pluginProvided || resource.projectID == nil
        }.sorted(by: Self.resourceSort).map(CapabilityFolderMember.init)
        for folder in defaults where folder.source == .project {
            map[folder.id] = eligible.filter { resource in
                resource.ownership != .pluginProvided && resource.projectID == folder.projectID
            }.sorted(by: Self.resourceSort).map(CapabilityFolderMember.init)
        }
        for folder in preferences.customFolders {
            let ids = preferences.memberships.filter { $0.folderID == folder.id }.map(\.resourceID)
            var seen = Set<String>()
            map[folder.id] = ids.compactMap { id in
                guard seen.insert(id).inserted, let resource = byID[id] else { return nil }
                return CapabilityFolderMember(resource: resource)
            }.sorted { Self.resourceSort($0.resource, $1.resource) }
        }
        self.membersByFolder = map
    }

    public func members(in folderID: String) -> [CapabilityFolderMember] { membersByFolder[folderID, default: []] }
    public func folder(withID id: String) -> CapabilityFolderDefinition? { folders.first { $0.id == id } }
    public func members(of kind: ResourceKind, in folderID: String) -> [CapabilityFolderMember] {
        members(in: folderID).filter { $0.resource.kind == kind }
    }

    /// Declared Skills for an Agent. In a custom folder, relations whose Skill
    /// is outside the folder are returned as previews, while membership and
    /// counts remain unchanged.
    public func companionSkills(for agentID: String, in folderID: String) -> [(resource: CapabilityResource, relation: CapabilityCompanionRelation, isPreview: Bool)] {
        let folderIDs = Set(members(in: folderID).map(\.id))
        return companionRelations.compactMap { relation in
            guard relation.agentID == agentID,
                  let skill = resources.first(where: { $0.id == relation.skillID }) else { return nil }
            return (skill, relation, !folderIDs.contains(skill.id))
        }.sorted { $0.resource.name.localizedStandardCompare($1.resource.name) == .orderedAscending }
    }

    public func relatedAgents(for skillID: String, in folderID: String) -> [(resource: CapabilityResource, relation: CapabilityCompanionRelation, isPreview: Bool)] {
        let folderIDs = Set(members(in: folderID).map(\.id))
        return companionRelations.compactMap { relation in
            guard relation.skillID == skillID,
                  let agent = resources.first(where: { $0.id == relation.agentID }) else { return nil }
            return (agent, relation, !folderIDs.contains(agent.id))
        }.sorted { $0.resource.name.localizedStandardCompare($1.resource.name) == .orderedAscending }
    }
    public var allUniqueResourceCount: Int { Set(resources.map(\.id)).count }
    public var agentCount: Int { Set(resources.filter { $0.kind == .agent }.map(\.id)).count }
    public var skillCount: Int { Set(resources.filter { $0.kind == .skill }.map(\.id)).count }

    private static func eligibleResources(_ resources: [CapabilityResource]) -> [CapabilityResource] {
        var seen = Set<String>()
        return resources.filter { resource in
            guard (resource.kind == .agent || resource.kind == .skill),
                  resource.ownership == .userOwned || resource.ownership == .installed || resource.ownership == .pluginProvided else { return false }
            // Plugin packages may contribute Skills to the Global folder, but
            // plugin Agents are not user capabilities and must never become
            // folder members or relationship endpoints.
            guard !(resource.kind == .agent && resource.ownership == .pluginProvided) else { return false }
            return seen.insert(resource.id).inserted
        }
    }

    private static func resourceSort(_ lhs: CapabilityResource, _ rhs: CapabilityResource) -> Bool {
        let compare = lhs.name.localizedStandardCompare(rhs.name)
        return compare == .orderedSame ? lhs.id < rhs.id : compare == .orderedAscending
    }

    private static func normalizedProjectName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func shortProjectID(_ value: String) -> String {
        let suffix = value.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        return String((suffix.isEmpty ? value : suffix).prefix(8))
    }
}

public extension CapabilityFolderStore {
    /// Creates an isolated, process-local store. This must never fall back to
    /// `UserDefaults.standard`: validation hosts and tests may run beside a
    /// production model, and a folder mutation in one must not leak into the
    /// other.
    static func makeMemory() -> CapabilityFolderStore {
        CapabilityFolderStore(memoryPreferences: nil)
    }
}
