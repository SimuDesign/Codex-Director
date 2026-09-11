import Foundation

/// The stable, language-independent built-in capability groups.
public enum BuiltInCapabilityGroup: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case videoProduction = "video-production"
    case uiDesign = "ui-design"
    case softwareDevelopment = "software-development"
    case contentCreation = "content-creation"
    case researchData = "research-data"
    case automationProductivity = "automation-productivity"
    case generalTools = "general-tools"
    case uncategorized = "uncategorized"

    public var id: String { rawValue }
    public var englishTitle: String {
        switch self {
        case .videoProduction: return "Video Production"
        case .uiDesign: return "UI Design"
        case .softwareDevelopment: return "Software Development"
        case .contentCreation: return "Content Creation"
        case .researchData: return "Research & Data"
        case .automationProductivity: return "Automation & Productivity"
        case .generalTools: return "General Tools"
        case .uncategorized: return "Uncategorized"
        }
    }
    public var simplifiedChineseTitle: String {
        switch self {
        case .videoProduction: return "视频制作"
        case .uiDesign: return "UI 设计"
        case .softwareDevelopment: return "软件开发"
        case .contentCreation: return "内容创作"
        case .researchData: return "研究与数据"
        case .automationProductivity: return "自动化与效率"
        case .generalTools: return "通用工具"
        case .uncategorized: return "未分类"
        }
    }
    public var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A built-in or user-created group. User-authored names are intentionally
/// the only custom data persisted by the grouping feature.
public struct CapabilityGroupDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let builtIn: BuiltInCapabilityGroup?
    public let name: String

    public init(id: String, builtIn: BuiltInCapabilityGroup? = nil, name: String) {
        self.id = id
        self.builtIn = builtIn
        self.name = name
    }

    public var isBuiltIn: Bool { builtIn != nil }
    public var isUncategorized: Bool { builtIn == .uncategorized }

    public static var builtInDefinitions: [CapabilityGroupDefinition] {
        BuiltInCapabilityGroup.allCases.map {
            CapabilityGroupDefinition(id: $0.id, builtIn: $0, name: $0.englishTitle)
        }
    }
}

public enum CapabilityGroupAssignmentSource: String, Codable, Equatable, Hashable, Sendable {
    case automatic
    case manual
}

public struct CapabilityGroupAssignment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let resourceID: String
    public let groupID: String
    public let source: CapabilityGroupAssignmentSource

    public var id: String { resourceID }

    public init(resourceID: String, groupID: String, source: CapabilityGroupAssignmentSource) {
        self.resourceID = resourceID
        self.groupID = groupID
        self.source = source
    }
}

/// Only user-created groups and explicit manual overrides are persisted.
/// Automatic classifications are projected from the current inventory.
public struct CapabilityGroupingPreferencesV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let customGroups: [CapabilityGroupDefinition]
    public let manualAssignments: [CapabilityGroupAssignment]

    public init(
        version: Int = Self.currentVersion,
        customGroups: [CapabilityGroupDefinition] = [],
        manualAssignments: [CapabilityGroupAssignment] = []
    ) {
        self.version = version
        self.customGroups = customGroups.filter { !$0.isBuiltIn }
        self.manualAssignments = manualAssignments.map {
            CapabilityGroupAssignment(resourceID: $0.resourceID, groupID: $0.groupID, source: .manual)
        }
    }
}

public enum CapabilityGroupingStoreError: Error, Equatable, Sendable {
    case persistenceFailed
    case corruptedPreferences
    case invalidGroupName
    case duplicateGroupName
    case immutableGroup
    case missingGroup
}

/// The store distinguishes an untouched first run from unreadable persisted
/// bytes. Corrupt bytes are never silently replaced by a subsequent write.
public enum CapabilityGroupingPreferencesState: String, Codable, Equatable, Sendable {
    case missing
    case valid
    case corrupted
}

/// UserDefaults-backed local grouping preferences. The injected closures make
/// this store usable by memory-only validation hosts and failure tests.
public final class CapabilityGroupingStore: @unchecked Sendable {
    public static let defaultsKey = "com.peiweitang.CodexDirector.capabilityGrouping.v1"

    private let readData: () -> Data?
    private let writeData: (Data) -> Bool
    private let removeData: () -> Void

    public init(defaults: UserDefaults = .standard) {
        readData = { defaults.data(forKey: Self.defaultsKey) }
        writeData = { data in
            defaults.set(data, forKey: Self.defaultsKey)
            return true
        }
        removeData = { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    public init(memoryPreferences: CapabilityGroupingPreferencesV1) {
        var value: Data? = try? JSONEncoder().encode(memoryPreferences)
        readData = { value }
        writeData = { data in value = data; return true }
        removeData = { value = nil }
    }

    public init(
        readData: @escaping () -> Data?,
        writeData: @escaping (Data) -> Bool,
        removeData: @escaping () -> Void
    ) {
        self.readData = readData
        self.writeData = writeData
        self.removeData = removeData
    }

    public func preferences() -> CapabilityGroupingPreferencesV1 {
        guard case .valid = preferencesState(),
              let data = readData(),
              let value = try? JSONDecoder().decode(CapabilityGroupingPreferencesV1.self, from: data) else {
            return .init()
        }
        return CapabilityGroupingPreferencesV1(customGroups: value.customGroups, manualAssignments: value.manualAssignments)
    }

    public func preferencesState() -> CapabilityGroupingPreferencesState {
        guard let data = readData() else { return .missing }
        guard let value = try? JSONDecoder().decode(CapabilityGroupingPreferencesV1.self, from: data),
              Self.isValid(value) else {
            return .corrupted
        }
        return .valid
    }

    public func save(_ preferences: CapabilityGroupingPreferencesV1) throws {
        guard preferencesState() != .corrupted else {
            throw CapabilityGroupingStoreError.corruptedPreferences
        }
        let data = try JSONEncoder().encode(preferences)
        guard writeData(data) else { throw CapabilityGroupingStoreError.persistenceFailed }
    }

    public func clear() { removeData() }

    /// Explicitly discards unreadable grouping bytes after user confirmation.
    /// A valid or missing preference is left untouched.
    public func clearCorruptedPreferences() {
        guard preferencesState() == .corrupted else { return }
        removeData()
    }

    private static func isValid(_ value: CapabilityGroupingPreferencesV1) -> Bool {
        guard value.version == CapabilityGroupingPreferencesV1.currentVersion else { return false }
        let customGroups = value.customGroups
        guard customGroups.allSatisfy({
            !$0.id.isEmpty
                && !$0.isBuiltIn
                && !$0.name.isEmpty
                && $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.name.count <= 40
        }) else { return false }
        guard Set(customGroups.map(\.id)).count == customGroups.count else { return false }

        let normalizedNames = customGroups.map {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        guard Set(normalizedNames).count == normalizedNames.count else { return false }
        let builtInNames = Set(BuiltInCapabilityGroup.allCases.flatMap { group in
            [group.englishTitle, group.simplifiedChineseTitle]
        }.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        guard normalizedNames.allSatisfy({ !builtInNames.contains($0) }) else { return false }

        guard value.manualAssignments.allSatisfy({
            !$0.resourceID.isEmpty && !$0.groupID.isEmpty
        }) else { return false }
        return Set(value.manualAssignments.map(\.resourceID)).count == value.manualAssignments.count
    }
}

/// A deterministic local classifier. It intentionally accepts only the
/// indexed name and declared summary; no AI, filesystem or network access is
/// involved.
public struct CapabilityGroupingClassifier: Sendable {
    public static let currentRuleVersion = 1

    private struct Rule: Sendable {
        let exact: Set<String>
        let prefixes: [String]
        let words: Set<String>
        let fragments: [String]
        let weight: Int

        init(exact: Set<String>, prefixes: [String], words: Set<String>, fragments: [String] = [], weight: Int) {
            self.exact = exact
            self.prefixes = prefixes
            self.words = words
            self.fragments = fragments
            self.weight = weight
        }
    }

    private let rules: [BuiltInCapabilityGroup: Rule]

    /// These labels occur in many unrelated names and are not category
    /// evidence by themselves. A repeated generic label across name and
    /// summary is still one weak signal, not two independent clues.
    private static let genericEvidenceWords: Set<String> = [
        "video", "data", "writing", "analysis", "app", "design", "ui", "tool", "utility"
    ]

    public init() {
        rules = [
            .videoProduction: Rule(exact: ["video director", "video editor", "remotion engineer", "ffmpeg video editor", "after effects production", "video cover studio", "video frames", "视频制作", "视频编辑", "视频导演"], prefixes: ["video ", "remotion ", "ffmpeg ", "after effects ", "video-", "视频"], words: ["video", "videography", "editing", "edit", "subtitle", "caption", "remotion", "ffmpeg", "after", "effects"], fragments: ["视频", "剪辑", "字幕"], weight: 3),
            .uiDesign: Rule(exact: ["ui designer", "frontend developer", "figma editor", "icon designer", "brand designer", "interface concept drafting", "figma swiftui", "system glyph icons", "illustrated gradient icons", "ui 设计", "界面设计", "用户界面"], prefixes: ["ui ", "figma ", "icon ", "brand ", "interface ", "frontend ", "ui-", "界面"], words: ["ui", "ux", "design", "figma", "interface", "wireframe", "prototype", "icon", "brand", "frontend"], fragments: ["界面", "设计", "用户体验", "图标", "原型", "品牌"], weight: 3),
            .softwareDevelopment: Rule(exact: ["software engineer", "frontend developer", "architecture designer", "code", "openai developers", "软件开发", "软件工程", "程序开发"], prefixes: ["software ", "frontend ", "architecture ", "swift ", "code", "软件", "开发"], words: ["software", "developer", "development", "coding", "code", "swift", "app", "api", "debug", "architecture", "testing", "quality"], fragments: ["软件", "开发", "编程", "代码", "架构", "测试"], weight: 3),
            .contentCreation: Rule(exact: ["blog writer", "copywriting", "social content", "seo content writer", "content strategy", "humanize writing", "内容创作", "文案写作", "内容策略"], prefixes: ["content ", "social ", "blog ", "seo ", "copy", "内容", "文案"], words: ["content", "writing", "writer", "copy", "blog", "social", "seo", "marketing", "script"], fragments: ["内容", "写作", "文案", "博客", "营销", "脚本"], weight: 3),
            .researchData: Rule(exact: ["market research", "research paper writer", "aminer data search", "deep research", "stock analysis", "backtest expert", "研究与数据", "数据研究", "市场研究"], prefixes: ["research ", "data ", "market ", "academic ", "a-stock-", "研究", "数据"], words: ["research", "data", "analysis", "academic", "paper", "search", "dataset", "backtest", "stock", "market"], fragments: ["研究", "数据", "分析", "学术", "论文", "搜索", "市场"], weight: 3),
            .automationProductivity: Rule(exact: ["automation workflows", "social media scheduler", "feishu cron reminder", "memory", "tmux", "skill installer", "plugin management", "自动化与效率", "自动化工作流", "效率工具"], prefixes: ["automation ", "social media ", "feishu ", "skill ", "plugin ", "todo ", "task ", "自动化", "效率"], words: ["automation", "workflow", "productivity", "scheduler", "reminder", "memory", "install", "plugin", "todo", "calendar", "tmux"], fragments: ["自动化", "工作流", "效率", "日程", "提醒", "安装", "插件"], weight: 3),
            .generalTools: Rule(exact: ["self improving agent", "clawdefender", "1password", "flue", "visualize", "通用工具", "实用工具"], prefixes: ["general ", "tool ", "openai ", "pdf ", "documents ", "spreadsheets ", "presentations ", "通用", "工具"], words: ["tool", "utility", "security", "browser", "document", "spreadsheet", "presentation", "pdf", "visual", "general"], fragments: ["工具", "文档", "表格", "演示", "安全", "浏览器", "可视化"], weight: 2)
        ]
    }

    public func classify(name: String, summary: String?) -> BuiltInCapabilityGroup {
        let normalizedName = Self.normalized(name)
        let normalizedSummary = Self.normalized(summary ?? "")
        var scores: [(BuiltInCapabilityGroup, Int)] = []
        for group in BuiltInCapabilityGroup.allCases where group != .uncategorized {
            guard let rule = rules[group] else { continue }
            var score = 0
            let exactMatch = rule.exact.contains(normalizedName)
            let prefixMatch = rule.prefixes.contains(where: { normalizedName.hasPrefix($0) })
            if exactMatch { score += 100 }
            if prefixMatch { score += 20 }
            let nameWords = Set(Self.words(normalizedName))
            let matchedNameWords = nameWords.intersection(rule.words)
            score += matchedNameWords.count * rule.weight
            let summaryWords = Set(Self.words(normalizedSummary))
            let matchedSummaryWords = summaryWords.intersection(rule.words)
            score += matchedSummaryWords.count
            let meaningfulNameWords = matchedNameWords.subtracting(Self.genericEvidenceWords)
            let meaningfulSummaryWords = matchedSummaryWords.subtracting(Self.genericEvidenceWords)
            let meaningfulEvidence = meaningfulNameWords.union(meaningfulSummaryWords)
            let matchedPrefix = rule.prefixes.first(where: { normalizedName.hasPrefix($0) })
            let prefixToken = matchedPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixIsGenericOnly = prefixToken.map(Self.genericEvidenceWords.contains) == true
            let strongPrefixMatch = prefixMatch && (!prefixIsGenericOnly || !meaningfulEvidence.isEmpty)
            var matchedNameFragments = 0
            var matchedSummaryFragments = 0
            score += rule.fragments.reduce(into: 0) { result, fragment in
                if normalizedName.contains(fragment) {
                    matchedNameFragments += 1
                    result += 20
                }
                if normalizedSummary.contains(fragment) {
                    matchedSummaryFragments += 1
                    result += 4
                }
            }
            // A single broad token (for example "video", "data", "app" or
            // "writing") is not enough evidence to classify a capability.
            // Exact names, clear prefixes and Chinese phrase fragments are
            // strong evidence; otherwise require multiple independent words
            // across the name and declared purpose.
            let hasStrongEvidence = exactMatch
                || strongPrefixMatch
                || matchedNameFragments > 0
                || meaningfulNameWords.count >= 2
                || matchedSummaryFragments > 0
                || ((matchedNameWords.count + matchedSummaryWords.count >= 2) && !meaningfulEvidence.isEmpty)
            if score > 0, hasStrongEvidence { scores.append((group, score)) }
        }
        let ranked = scores.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.sortOrder < rhs.0.sortOrder : lhs.1 > rhs.1
        }
        guard let first = ranked.first, first.1 > 0 else { return .uncategorized }
        if ranked.dropFirst().first?.1 == first.1 { return .uncategorized }
        // Avoid assigning broad labels when the only evidence is one generic
        // word such as "tool" or "design" in a declared summary.
        if first.1 < 3 { return .uncategorized }
        return first.0
    }

    public func classify(resource: CapabilityResource) -> BuiltInCapabilityGroup {
        classify(name: resource.name, summary: resource.summary)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" })
            .joined(separator: " ")
    }

    private static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

public struct CapabilityGroupingMember: Identifiable, Equatable, Sendable {
    public let resource: CapabilityResource
    public let group: CapabilityGroupDefinition
    public let source: CapabilityGroupAssignmentSource
    public var id: String { resource.id }

    public init(resource: CapabilityResource, group: CapabilityGroupDefinition, source: CapabilityGroupAssignmentSource) {
        self.resource = resource
        self.group = group
        self.source = source
    }
}

/// Current grouping projection. Members are restricted to Agent/Skill records
/// that the capability catalog exposes as user/installed capabilities.
public struct CapabilityGroupingProjection: Equatable, Sendable {
    public let groups: [CapabilityGroupDefinition]
    public let members: [CapabilityGroupingMember]
    public let ruleVersion: Int

    public init(
        resources: [CapabilityResource],
        catalog: [CapabilityCatalogEntry] = [],
        preferences: CapabilityGroupingPreferencesV1 = .init(),
        classifier: CapabilityGroupingClassifier = .init()
    ) {
        let eligibleIDs = Set(catalog.filter { entry in
            (entry.resource.kind == .agent || entry.resource.kind == .skill) && entry.category != nil
        }.map(\.resource.id))
        let eligibleResources = resources.filter { resource in
            eligibleIDs.isEmpty
                ? (resource.kind == .agent || resource.kind == .skill) && Self.isEligibleWithoutCatalog(resource)
                : eligibleIDs.contains(resource.id)
        }
        var definitions: [CapabilityGroupDefinition] = []
        var definitionIDs = Set<String>()
        // Uncategorized is a sentinel section and must remain last, after
        // built-ins and user-created groups. Custom definitions retain their
        // persisted creation order.
        let builtIns = CapabilityGroupDefinition.builtInDefinitions
        let orderedDefinitions = builtIns.filter { !$0.isUncategorized }
            + preferences.customGroups.filter { !$0.isBuiltIn }
            + builtIns.filter(\.isUncategorized)
        for definition in orderedDefinitions {
            guard definitionIDs.insert(definition.id).inserted else { continue }
            definitions.append(definition)
        }
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let manual = preferences.manualAssignments.reduce(into: [String: CapabilityGroupAssignment]()) { result, assignment in
            if result[assignment.resourceID] == nil { result[assignment.resourceID] = assignment }
        }
        let defaultGroup = definitions.first(where: { $0.builtIn == .uncategorized }) ?? CapabilityGroupDefinition.builtInDefinitions.last!
        members = eligibleResources.map { resource in
            if let override = manual[resource.id], let group = definitionsByID[override.groupID] {
                return CapabilityGroupingMember(resource: resource, group: group, source: .manual)
            }
            let groupID = classifier.classify(resource: resource).id
            let group = definitionsByID[groupID] ?? defaultGroup
            return CapabilityGroupingMember(resource: resource, group: group, source: .automatic)
        }.sorted { lhs, rhs in
            // Use the projected definition order rather than the enum order:
            // this keeps custom groups before the final Uncategorized group.
            let leftOrder = definitions.firstIndex(of: lhs.group) ?? Int.max
            let rightOrder = definitions.firstIndex(of: rhs.group) ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            let compare = lhs.resource.name.localizedStandardCompare(rhs.resource.name)
            return compare == .orderedSame ? lhs.resource.id < rhs.resource.id : compare == .orderedAscending
        }
        groups = definitions
        ruleVersion = CapabilityGroupingClassifier.currentRuleVersion
    }

    public var agentCount: Int { members.filter { $0.resource.kind == .agent }.count }
    public var skillCount: Int { members.filter { $0.resource.kind == .skill }.count }
    public var categorizedCount: Int { members.filter { !$0.group.isUncategorized }.count }
    public var uncategorizedCount: Int { members.filter { $0.group.isUncategorized }.count }
    public func members(in groupID: String) -> [CapabilityGroupingMember] { members.filter { $0.group.id == groupID } }

    private static func isEligibleWithoutCatalog(_ resource: CapabilityResource) -> Bool {
        guard resource.scope == .global || resource.scope == .project else { return false }
        if resource.scope == .system || resource.scope == .plugin { return false }
        return resource.ownership == .userOwned || resource.ownership == .installed || resource.ownership == .pluginProvided
    }
}

public extension CapabilityGroupingStore {
    static func makeMemory() -> CapabilityGroupingStore { CapabilityGroupingStore(memoryPreferences: .init()) }
}
