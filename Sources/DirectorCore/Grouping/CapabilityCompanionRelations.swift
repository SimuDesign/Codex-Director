import Foundation

/// Version of the derived explicit Agent/Skill relationship index. This is
/// deliberately independent from the rollout parser version; historical
/// sessions do not need to be reparsed when relationship rules change.
public enum CapabilityCompanionIndex {
    // v1 could be written by the first 1.3 migration implementation while
    // global paired Agents still used their callable TOML path as identity.
    // v2 reran the source projection once so users converged on the historical
    // Brief-derived identity. v3 adds the normalized project registry layouts;
    // session history is still not reparsed.
    public static let currentVersion = "capability-companions.v3"
}

/// Decides whether an indexed database needs the one-time source pass that
/// materializes the current relationship rules. Keeping this policy separate
/// from the rollout parser version makes the upgrade behavior deterministic
/// and easy to exercise without starting a scan.
public enum CapabilityCompanionIndexMigration {
    public static func needsSourceRefresh(marker: String?, hasIndexedData: Bool) -> Bool {
        hasIndexedData && marker != CapabilityCompanionIndex.currentVersion
    }
}

/// The two relationship meanings that are safe to show as a companion
/// relationship. Historical co-observation is deliberately not represented by
/// this enum and can never create a membership or declaration.
public enum CapabilityCompanionRelationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case companionSkill = "companion-skill"
    case requiresAgent = "requires-agent"
}

/// A privacy-safe origin for an explicit relationship declaration. The source
/// is a fixed label; raw document contents and paths never leave discovery.
public enum CapabilityCompanionDeclarationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case projectRegistry = "project-registry"
    case agentConfiguration = "agent-configuration"
    case agentBrief = "agent-brief"
    case skillDescription = "skill-description"
}

/// Ephemeral scanner metadata for an Agent whose callable TOML and reusable
/// Brief live at different relative paths. It is never persisted.
public struct CapabilityAgentPairing: Codable, Equatable, Hashable, Sendable {
    public let sourceRootID: String
    /// The relative path used by the historical Agent resource identity. For
    /// paired global Agents this is the Brief path, preserving memberships
    /// created before the callable TOML was discovered.
    public let agentRelativePath: String
    public let briefRelativePath: String
    /// The callable configuration path. This is ephemeral scanner metadata;
    /// it is never written into the resource row or relation index.
    public let configurationRelativePath: String

    public init(
        sourceRootID: String,
        agentRelativePath: String,
        briefRelativePath: String,
        configurationRelativePath: String? = nil
    ) {
        self.sourceRootID = sourceRootID
        self.agentRelativePath = agentRelativePath
        self.briefRelativePath = briefRelativePath
        self.configurationRelativePath = configurationRelativePath ?? agentRelativePath
    }

    private enum CodingKeys: String, CodingKey {
        case sourceRootID
        case agentRelativePath
        case briefRelativePath
        case configurationRelativePath
    }

    /// Pairings are ephemeral, but keeping decoding tolerant means a test or
    /// diagnostic snapshot made by the earlier three-field shape can still
    /// be inspected without manufacturing a new path.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceRootID = try container.decode(String.self, forKey: .sourceRootID)
        let agentRelativePath = try container.decode(String.self, forKey: .agentRelativePath)
        let briefRelativePath = try container.decode(String.self, forKey: .briefRelativePath)
        let configurationRelativePath = try container.decodeIfPresent(String.self, forKey: .configurationRelativePath)
        self.init(
            sourceRootID: sourceRootID,
            agentRelativePath: agentRelativePath,
            briefRelativePath: briefRelativePath,
            configurationRelativePath: configurationRelativePath
        )
    }
}

/// A typed Agent–Skill relationship projected from an explicit local
/// declaration. It is intentionally independent from generic topology edges
/// so the UI can distinguish a declaration from observed usage.
public struct CapabilityCompanionRelation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let agentID: String
    public let skillID: String
    public let kind: CapabilityCompanionRelationKind
    public let declarationSource: CapabilityCompanionDeclarationSource
    public let confidence: EvidenceConfidence

    public var source: CapabilityCompanionDeclarationSource { declarationSource }
    public var relationKind: CapabilityCompanionRelationKind { kind }

    /// Logical Agent/Skill pair identity used for presentation de-duplication.
    public var pairID: String { "\(agentID)|\(skillID)" }

    public var id: String {
        "\(agentID)|\(kind.rawValue)|\(skillID)|\(declarationSource.rawValue)"
    }

    public init(
        agentID: String,
        skillID: String,
        kind: CapabilityCompanionRelationKind = .companionSkill,
        declarationSource: CapabilityCompanionDeclarationSource,
        confidence: EvidenceConfidence = .exact
    ) {
        self.agentID = agentID
        self.skillID = skillID
        self.kind = kind
        self.declarationSource = declarationSource
        self.confidence = confidence
    }

    public init?(resourceRelation: ResourceRelation) {
        guard let kind = CapabilityCompanionRelationKind(rawValue: resourceRelation.relationKind) else { return nil }
        let source = resourceRelation.evidenceSummary.flatMap(CapabilityCompanionDeclarationSource.init(rawValue:))
            ?? .agentBrief
        self.init(
            agentID: resourceRelation.sourceResourceID,
            skillID: resourceRelation.targetResourceID,
            kind: kind,
            declarationSource: source,
            confidence: resourceRelation.confidence
        )
    }

    public var resourceRelation: ResourceRelation {
        ResourceRelation(
            sourceResourceID: agentID,
            targetResourceID: skillID,
            relationKind: kind.rawValue,
            confidence: confidence,
            evidenceSummary: declarationSource.rawValue
        )
    }
}

/// Observed co-occurrence is shown separately from declared relationships.
/// `coverage` describes the session evidence, not the relationship confidence.
public struct CapabilityCompanionUsageStats: Codable, Equatable, Sendable {
    public let sessionCount: Int?
    public let lastObservedAt: Date?
    public let coverage: CoverageState

    public init(sessionCount: Int?, lastObservedAt: Date?, coverage: CoverageState) {
        self.sessionCount = sessionCount
        self.lastObservedAt = lastObservedAt
        self.coverage = coverage
    }

    public static let unavailable = Self(sessionCount: nil, lastObservedAt: nil, coverage: .unknown)

    /// Computes every declared pair from one materialized evidence snapshot.
    /// Session event sets and coverage are prepared once, then reused for all
    /// relations. Callers should use this batch API for list/detail screens;
    /// it prevents a row-by-row SQLite or event scan from turning a folder
    /// into an N×M query.
    public static func calculateBatch(
        relations: [CapabilityCompanionRelation],
        invocationsBySession: [String: [InvocationEvent]],
        sessions: [TaskSummary],
        window: CapabilityQueryWindow,
        calendar: Calendar = .current
    ) -> [String: CapabilityCompanionUsageStats] {
        guard !relations.isEmpty else { return [:] }

        let coverageBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.coverage) })
        var relevantSessionIDs = Set<String>()
        var resourcesBySession: [String: Set<String>] = [:]
        var latestTimestampByResourceBySession: [String: [String: Date]] = [:]
        for session in sessions {
            let timestamps = [session.startedAt, session.endedAt].compactMap { $0 }
            if timestamps.isEmpty {
                if invocationsBySession[session.id]?.contains(where: { event in
                    guard let date = event.timestamp else { return false }
                    return date >= window.start && date <= window.end
                }) == true {
                    relevantSessionIDs.insert(session.id)
                }
            } else if timestamps.min()! <= window.end && timestamps.max()! >= window.start {
                relevantSessionIDs.insert(session.id)
            }
        }

        for (sessionID, events) in invocationsBySession {
            let inWindow = events.filter { event in
                guard let date = event.timestamp else { return false }
                return date >= window.start && date <= window.end
            }
            guard !inWindow.isEmpty else { continue }
            relevantSessionIDs.insert(sessionID)
            resourcesBySession[sessionID] = Set(inWindow.compactMap(\.resourceID))
            var latestByResource: [String: Date] = [:]
            for event in inWindow {
                guard let resourceID = event.resourceID, let timestamp = event.timestamp else { continue }
                if timestamp > (latestByResource[resourceID] ?? .distantPast) {
                    latestByResource[resourceID] = timestamp
                }
            }
            latestTimestampByResourceBySession[sessionID] = latestByResource
        }

        var overallCoverage: CoverageState?
        for sessionID in relevantSessionIDs {
            let state = coverageBySession[sessionID] ?? .unknown
            overallCoverage = overallCoverage.map { mergedCoverage($0, state) } ?? state
        }
        let fallbackCoverage = overallCoverage ?? .unknown

        var result: [String: CapabilityCompanionUsageStats] = [:]
        for relation in relations {
            var matchingCount = 0
            var lastObserved: Date?
            for sessionID in relevantSessionIDs {
                guard let resources = resourcesBySession[sessionID],
                      resources.contains(relation.agentID),
                      resources.contains(relation.skillID) else { continue }
                matchingCount += 1
                // Do not use an unrelated later event in the same session as
                // evidence for this Agent/Skill pair.
                let dates = [
                    latestTimestampByResourceBySession[sessionID]?[relation.agentID],
                    latestTimestampByResourceBySession[sessionID]?[relation.skillID]
                ].compactMap { $0 }
                if let date = dates.max(), date > (lastObserved ?? .distantPast) {
                    lastObserved = date
                }
            }
            result[relation.id] = Self(
                sessionCount: matchingCount,
                lastObservedAt: lastObserved,
                coverage: fallbackCoverage
            )
        }
        _ = calendar
        return result
    }

    private static func mergedCoverage(_ prior: CoverageState, _ new: CoverageState) -> CoverageState {
        CoverageState.mergedCoverage(prior, new)
    }

    /// Computes distinct-session co-observation for a declared pair. This is
    /// deliberately a separate projection: it reports evidence that both
    /// resources appeared in the same session, never a causal invocation.
    public static func calculate(
        agentID: String,
        skillID: String,
        invocationsBySession: [String: [InvocationEvent]],
        sessions: [TaskSummary],
        window: CapabilityQueryWindow,
        calendar: Calendar = .current
    ) -> Self {
        let relation = CapabilityCompanionRelation(
            agentID: agentID,
            skillID: skillID,
            declarationSource: .agentBrief
        )
        return calculateBatch(
            relations: [relation],
            invocationsBySession: invocationsBySession,
            sessions: sessions,
            window: window,
            calendar: calendar
        )[relation.id] ?? .unavailable
    }
}

/// One bounded, immutable history snapshot for the companion projection. The
/// database layer returns this as a batch so UI rows never issue per-resource
/// or per-relation reads.
public struct CapabilityCompanionEvidenceSnapshot: Sendable, Equatable {
    public let sessions: [TaskSummary]
    public let invocationsBySession: [String: [InvocationEvent]]

    public init(sessions: [TaskSummary], invocationsBySession: [String: [InvocationEvent]]) {
        self.sessions = sessions
        self.invocationsBySession = invocationsBySession
    }
}

/// A privacy-safe resolver warning. Names, source bodies and paths are never
/// retained; the stable source-root identifier is enough for diagnostics.
public struct CapabilityCompanionResolutionIssue: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case ambiguousSkill
        case ambiguousAgent
    }

    public let kind: Kind
    public let sourceRootID: String

    public init(kind: Kind, sourceRootID: String) {
        self.kind = kind
        self.sourceRootID = sourceRootID
    }
}

public struct CapabilityCompanionResolutionReport: Equatable, Sendable {
    public let relations: [CapabilityCompanionRelation]
    public let issues: [CapabilityCompanionResolutionIssue]

    public init(relations: [CapabilityCompanionRelation], issues: [CapabilityCompanionResolutionIssue]) {
        self.relations = relations
        self.issues = issues
    }
}

/// Deterministic, read-only resolver for explicit Agent/Skill declarations.
/// It intentionally does not infer relations from arbitrary prose, usage
/// history, network data, or AI classification.
public struct CapabilityCompanionResolver: Sendable {
    private let resources: [CapabilityResource]
    private let roots: [ScanRoot]
    private let transientRoots: [String: URL]
    private let agentPairings: [CapabilityAgentPairing]
    private let fileSystem: FileSystemClient

    public init(
        resources: [CapabilityResource],
        roots: [ScanRoot],
        transientRoots: [String: URL] = [:],
        agentPairings: [CapabilityAgentPairing] = [],
        fileSystem: FileSystemClient = FileSystemClient()
    ) {
        self.resources = resources
        self.roots = roots
        self.transientRoots = transientRoots
        self.agentPairings = agentPairings
        self.fileSystem = fileSystem
    }

    public func resolve() -> [CapabilityCompanionRelation] {
        resolveWithIssues().relations
    }

    /// Resolves exact declarations and reports only safe ambiguity metadata.
    /// Ambiguous names are never guessed into a relationship.
    public func resolveWithIssues() -> CapabilityCompanionResolutionReport {
        // Plugin packages may contribute Skills, but a plugin-provided Agent
        // is not a user capability. Exclude it at the resolver boundary as
        // well as in folder projection so no persisted relation can expose a
        // plugin Agent through another consumer.
        let agents = resources.filter {
            $0.kind == .agent && isEligible($0) && $0.ownership != .pluginProvided
        }
        let skills = resources.filter { $0.kind == .skill && isEligible($0) && !isSystemSkill($0) }
        guard !agents.isEmpty, !skills.isEmpty else { return .init(relations: [], issues: []) }

        let skillsByName = Dictionary(grouping: skills, by: normalizedName)
        let agentsByName = Dictionary(grouping: agents, by: normalizedName)
        var result = Set<CapabilityCompanionRelation>()
        var issueKeys = Set<String>()

        for agent in agents {
            for declaration in sourceTexts(for: agent) {
                for token in positiveSkillDirectives(in: declaration.text) {
                    guard let skill = resolveSkill(token, for: agent, candidates: skillsByName, issueKeys: &issueKeys) else { continue }
                    result.insert(CapabilityCompanionRelation(
                        agentID: agent.id,
                        skillID: skill.id,
                        kind: .companionSkill,
                        declarationSource: declaration.source
                    ))
                }
            }
        }

        for root in roots where root.kind == .projects {
            for declaration in registryDeclarations(root: root) {
                guard let agent = resolveRegistryAgent(
                    declaration.agent,
                    rootID: root.id,
                    candidates: agents,
                    issueKeys: &issueKeys
                ) else { continue }
                for skillName in declaration.skillNames {
                    guard let skill = resolveSkill(
                        RegistryReference(token: skillName, requiresAgentStem: false),
                        for: agent,
                        candidates: skills,
                        issueKeys: &issueKeys
                    ) else { continue }
                    result.insert(CapabilityCompanionRelation(
                        agentID: agent.id,
                        skillID: skill.id,
                        kind: .companionSkill,
                        declarationSource: .projectRegistry
                    ))
                }
            }
        }

        for skill in skills {
            for declaration in sourceTexts(for: skill) {
                for agentName in requiredAgentNames(in: declaration.text) {
                    guard let agent = resolveAgent(agentName, for: skill, candidates: agentsByName, issueKeys: &issueKeys) else { continue }
                    result.insert(CapabilityCompanionRelation(
                        agentID: agent.id,
                        skillID: skill.id,
                        kind: .requiresAgent,
                        declarationSource: declaration.source
                    ))
                }
            }
        }

        let sortedRelations = result.sorted {
            $0.agentID == $1.agentID
                ? ($0.skillID == $1.skillID ? $0.id < $1.id : $0.skillID < $1.skillID)
                : $0.agentID < $1.agentID
        }
        let issues = issueKeys.sorted().compactMap { key -> CapabilityCompanionResolutionIssue? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return CapabilityCompanionResolutionIssue(
                kind: parts[0] == "skill" ? .ambiguousSkill : .ambiguousAgent,
                sourceRootID: parts[1]
            )
        }
        return .init(relations: sortedRelations, issues: issues)
    }

    private struct DeclarationSourceText {
        let text: String
        let source: CapabilityCompanionDeclarationSource
    }

    private func sourceTexts(for resource: CapabilityResource) -> [DeclarationSourceText] {
        guard let relative = resource.relativeSourcePath,
              let rootURL = roots.first(where: { $0.id == resource.sourceRootID })?.url
                ?? transientRoots[resource.sourceRootID] else { return [] }
        // Runtime plugin resources expose a privacy-safe path rooted at the
        // plugin collection (`plugins/<name>/...`), while the transient root
        // is already the validated plugin installation directory.  Resolve
        // the child path exactly as the runtime Skill evidence reader does;
        // otherwise relation discovery would look under
        // `<plugin>/plugins/<name>/...` and silently miss frontmatter.
        let rootRelative: String = {
            guard transientRoots[resource.sourceRootID] != nil else { return relative }
            let marker = resource.sourceRootID.replacingOccurrences(of: "runtime-plugins:", with: "")
            let prefix = "plugins/\(marker)/"
            return relative.hasPrefix(prefix) ? String(relative.dropFirst(prefix.count)) : relative
        }()
        var urls: [(url: URL, source: CapabilityCompanionDeclarationSource)] = [
            (
                rootURL.appendingPathComponent(rootRelative),
                resource.kind == .skill ? .skillDescription : (relative.lowercased().hasSuffix(".toml") ? .agentConfiguration : .agentBrief)
            )
        ]
        if resource.kind == .agent {
            if let pairing = agentPairings.first(where: {
                $0.sourceRootID == resource.sourceRootID
                    && ($0.agentRelativePath == relative
                        || $0.briefRelativePath == relative
                        || $0.configurationRelativePath == relative)
            }) {
                urls.append((rootURL.appendingPathComponent(pairing.briefRelativePath), .agentBrief))
                urls.append((rootURL.appendingPathComponent(pairing.configurationRelativePath), .agentConfiguration))
            }
            let base: String
            if relative.lowercased().hasSuffix(".toml") {
                base = URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent
                for briefName in ["agent.md", "Agent.md", "AGENTS.md"] {
                    urls.append((rootURL.appendingPathComponent(base).appendingPathComponent(briefName), .agentBrief))
                }
            } else {
                base = URL(fileURLWithPath: relative).deletingLastPathComponent().lastPathComponent
                urls.append((rootURL.appendingPathComponent(base + ".toml"), .agentConfiguration))
            }
        }
        var texts = [DeclarationSourceText]()
        var seenPaths = Set<String>()
        for (url, source) in urls {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted,
                  case .success(let read) = fileSystem.readVerifiedData(
                      url,
                      within: rootURL,
                      maximumByteCount: 512 * 1024
                  ),
                  fileSystem.validateDocumentRead(read, at: url, within: rootURL),
                  let text = String(data: read.data, encoding: .utf8) else { continue }
            texts.append(DeclarationSourceText(text: text, source: source))
        }
        return texts
    }

    private func isEligible(_ resource: CapabilityResource) -> Bool {
        resource.ownership == .userOwned || resource.ownership == .installed || resource.ownership == .pluginProvided
    }

    private func isSystemSkill(_ resource: CapabilityResource) -> Bool {
        resource.scope == .system || resource.ownership == .builtIn || resource.origin == .codexSystem
    }

    private func normalizedName(_ resource: CapabilityResource) -> String {
        normalize(resource.name)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func resolveSkill(_ token: String, for agent: CapabilityResource, candidates: [String: [CapabilityResource]], issueKeys: inout Set<String>) -> CapabilityResource? {
        let key = normalize(token).trimmingCharacters(in: CharacterSet(charactersIn: "$`"))
        guard let all = candidates[key], !all.isEmpty else { return nil }
        if let projectID = agent.projectID {
            let local = all.filter { $0.projectID == projectID }
            if local.count == 1 { return local[0] }
            if !local.isEmpty { issueKeys.insert("skill|\(agent.sourceRootID)"); return nil }
        }
        let global = all.filter { $0.projectID == nil }
        if global.count == 1 { return global[0] }
        if all.count > 1 { issueKeys.insert("skill|\(agent.sourceRootID)") }
        return nil
    }

    private func resolveSkill(
        _ reference: RegistryReference,
        for agent: CapabilityResource,
        candidates: [CapabilityResource],
        issueKeys: inout Set<String>
    ) -> CapabilityResource? {
        let key = normalize(reference.token).trimmingCharacters(in: CharacterSet(charactersIn: "$`"))
        let all = candidates.filter { skill in
            skillAliases(skill).contains(key)
        }
        guard !all.isEmpty else { return nil }
        if let projectID = agent.projectID {
            let local = all.filter { $0.projectID == projectID }
            if local.count == 1 { return local[0] }
            if !local.isEmpty { issueKeys.insert("skill|\(agent.sourceRootID)"); return nil }
        }
        let global = all.filter { $0.projectID == nil }
        if global.count == 1 { return global[0] }
        if all.count > 1 { issueKeys.insert("skill|\(agent.sourceRootID)") }
        return nil
    }

    private func resolveAgent(_ token: String, for skill: CapabilityResource, candidates: [String: [CapabilityResource]], issueKeys: inout Set<String>) -> CapabilityResource? {
        let key = normalize(token).trimmingCharacters(in: CharacterSet(charactersIn: "`$"))
        guard let all = candidates[key], !all.isEmpty else { return nil }
        if let projectID = skill.projectID {
            let local = all.filter { $0.projectID == projectID }
            if local.count == 1 { return local[0] }
            if !local.isEmpty { issueKeys.insert("agent|\(skill.sourceRootID)"); return nil }
        }
        let global = all.filter { $0.projectID == nil }
        if global.count == 1 { return global[0] }
        if all.count > 1 { issueKeys.insert("agent|\(skill.sourceRootID)") }
        return nil
    }

    private func resolveRegistryAgent(
        _ reference: RegistryReference,
        rootID: String,
        candidates: [CapabilityResource],
        issueKeys: inout Set<String>
    ) -> CapabilityResource? {
        let key = normalize(reference.token)
        let matching = candidates.filter { agent in
            guard agent.projectID == rootID else { return false }
            if reference.requiresAgentStem {
                return agentConfigurationStems(agent).contains(key)
            }
            return agentAliases(agent).contains(key)
        }
        // Legacy registries may coexist with the historical registry-backed
        // Agent identity and a canonical project TOML that has the same name.
        // Keep both resources, but bind the declaration to the one unique
        // callable TOML. Multiple TOML matches remain ambiguous.
        let canonicalTOML = matching.filter { !agentConfigurationStems($0).isEmpty }
        if canonicalTOML.count == 1 { return canonicalTOML[0] }
        if canonicalTOML.count > 1 {
            issueKeys.insert("agent|\(rootID)")
            return nil
        }
        guard matching.count == 1 else {
            if matching.count > 1 { issueKeys.insert("agent|\(rootID)") }
            return nil
        }
        return matching[0]
    }

    private func skillAliases(_ resource: CapabilityResource) -> Set<String> {
        var aliases = Set([normalize(resource.name)])
        if let relative = resource.relativeSourcePath {
            let url = URL(fileURLWithPath: relative)
            aliases.insert(normalize(url.deletingPathExtension().lastPathComponent))
            aliases.insert(normalize(url.deletingLastPathComponent().lastPathComponent))
        }
        aliases.insert(normalize(resource.id))
        return aliases
    }

    private func agentAliases(_ resource: CapabilityResource) -> Set<String> {
        Set([normalize(resource.name)] + agentConfigurationStems(resource))
    }

    private func agentConfigurationStems(_ resource: CapabilityResource) -> Set<String> {
        guard let relative = resource.relativeSourcePath,
              URL(fileURLWithPath: relative).pathExtension.lowercased() == "toml" else { return [] }
        return [normalize(URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent)]
    }

    private func positiveSkillDirectives(in text: String) -> [String] {
        var values = [String]()
        for line in text.components(separatedBy: .newlines) {
            let lowered = line.lowercased()
            // A directive is only positive when the line does not explicitly
            // negate use. Failing closed matters more than recovering a
            // relationship from ambiguous prose: a negated `$skill` must
            // never become a companion edge.
            let negative = [
                #"\bnever\s+(?:use|invoke)\b"#,
                #"\bdo\s+not\b"#,
                #"\bdon't\b"#,
                #"\bnot\b"#,
            ].contains { pattern in
                matches(pattern: pattern, in: lowered)
            } || ["禁止", "不得", "不要", "不可", "不应", "无需"].contains { lowered.contains($0) }
            if negative { continue }
            // A generic mention of “skill” is not a declaration. Require an
            // explicit positive use/invoke/call directive (or the Chinese
            // equivalents) before accepting a `$skill` token.
            let positiveEnglish = matches(
                pattern: #"\b(?:use|uses|using|invoke|invokes|invoking|call|calls|calling)\b"#,
                in: lowered
            )
            let positiveChinese = line.contains("使用") || line.contains("调用")
            guard positiveEnglish || positiveChinese else { continue }
            values.append(contentsOf: capture(pattern: #"\$([A-Za-z0-9][A-Za-z0-9_-]*)"#, in: line))
        }
        return Array(Set(values)).sorted()
    }

    private func requiredAgentNames(in text: String) -> [String] {
        let frontmatter = frontmatterFields(in: text)
        // Only the frontmatter description is an approved reverse-declaration
        // source. Arbitrary body text and unrelated metadata fields can
        // mention an Agent without declaring a required relationship.
        let values = frontmatter.first { key, _ in
            key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "description"
        }.map { $0.value } ?? ""
        var result = [String]()
        for line in values.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.contains("use through") || lower.contains("required agent") || line.contains("需通过") else { continue }
            let suffix: String
            if let range = line.range(of: "use through", options: .caseInsensitive) { suffix = String(line[range.upperBound...]) }
            else if let range = line.range(of: "required agent", options: .caseInsensitive) { suffix = String(line[range.upperBound...]) }
            else if let range = line.range(of: "需通过") { suffix = String(line[range.upperBound...]) }
            else { continue }
            var clean = suffix.trimmingCharacters(in: CharacterSet(charactersIn: " :`*\t"))
            // The standard brief wording is "Use through Brand Designer to
            // ...". Keep the Agent name only; do not treat the rest of the
            // sentence as a resource identifier. Chinese descriptions use
            // the equivalent "需通过 Brand Designer ..." form.
            if let range = clean.range(of: #"\s+(?:to|for|when|before)\b"#, options: [.regularExpression, .caseInsensitive]) {
                clean = String(clean[..<range.lowerBound])
            }
            if let range = clean.range(of: "进行") { clean = String(clean[..<range.lowerBound]) }
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: " :`*,.，。;；"))
            if !clean.isEmpty { result.append(clean) }
        }
        return Array(Set(result)).sorted()
    }

    private struct RegistryReference: Hashable {
        let token: String
        let requiresAgentStem: Bool
    }

    private struct RegistryDeclaration: Hashable {
        let agent: RegistryReference
        let skillNames: [String]
    }

    private func registryDeclarations(root: ScanRoot) -> [RegistryDeclaration] {
        let primaryURL = root.url.appendingPathComponent("agents/registry.json")
        let primaryRead = fileSystem.readVerifiedData(
            primaryURL,
            within: root.url,
            maximumByteCount: CodexProjectRegistry.maximumByteCount
        )
        let selection: (url: URL, read: Result<FileSystemDocumentRead, FileSystemReadError>)
        if case .failure(.notFound) = primaryRead {
            let compatibilityURL = root.url.appendingPathComponent("registry.json")
            selection = (
                compatibilityURL,
                fileSystem.readVerifiedData(
                    compatibilityURL,
                    within: root.url,
                    maximumByteCount: CodexProjectRegistry.maximumByteCount
                )
            )
        } else {
            selection = (primaryURL, primaryRead)
        }
        guard case .success(let read) = selection.read,
              fileSystem.validateDocumentRead(read, at: selection.url, within: root.url),
              case .success(let document) = CodexProjectRegistry.parse(read.data) else { return [] }

        var declarations = Set<RegistryDeclaration>()
        for entry in document.legacyEntries {
            switch entry.kind {
            case .unspecified, .agent:
                if !entry.usesSkills.isEmpty {
                    declarations.insert(RegistryDeclaration(
                        agent: RegistryReference(token: entry.name, requiresAgentStem: false),
                        skillNames: entry.usesSkills
                    ))
                }
            case .skill:
                let skillToken = entry.skillName ?? entry.name
                for agentName in entry.invokedBy {
                    declarations.insert(RegistryDeclaration(
                        agent: RegistryReference(token: agentName, requiresAgentStem: false),
                        skillNames: [skillToken]
                    ))
                }
            case .workflow, .unsupported:
                break
            }
            if entry.kind == .unspecified, !entry.invokedBy.isEmpty {
                let skillToken = entry.skillName ?? entry.name
                for agentName in entry.invokedBy {
                    declarations.insert(RegistryDeclaration(
                        agent: RegistryReference(token: agentName, requiresAgentStem: false),
                        skillNames: [skillToken]
                    ))
                }
            }
        }

        var agentAliasesByPackageID: [String: Set<RegistryReference>] = [:]
        var skillAliasesByPackageID: [String: Set<String>] = [:]
        for package in document.packages {
            guard let id = package.id else { continue }
            let key = normalize(id)
            switch package.kind {
            case .nativeAgent, .agent:
                if let nativeAgent = package.nativeAgent {
                    agentAliasesByPackageID[key, default: []].insert(RegistryReference(
                        token: normalize(nativeAgent),
                        requiresAgentStem: true
                    ))
                } else if let name = package.name {
                    agentAliasesByPackageID[key, default: []].insert(RegistryReference(
                        token: normalize(name),
                        requiresAgentStem: false
                    ))
                }
            case .auxiliarySkill, .skill:
                if let name = package.name {
                    skillAliasesByPackageID[key, default: []].insert(normalize(name))
                }
            case .unknown:
                break
            }
        }
        guard !agentAliasesByPackageID.values.contains(where: { $0.count > 1 }),
              !skillAliasesByPackageID.values.contains(where: { $0.count > 1 }) else { return [] }

        func agentReference(for token: String) -> RegistryReference {
            if let aliases = agentAliasesByPackageID[normalize(token)], aliases.count == 1,
               let alias = aliases.first {
                return alias
            }
            return RegistryReference(token: token, requiresAgentStem: false)
        }

        func skillReference(for token: String) -> String {
            if let aliases = skillAliasesByPackageID[normalize(token)], aliases.count == 1,
               let alias = aliases.first {
                return alias
            }
            return token
        }

        for package in document.packages {
            let packageID = package.id ?? package.name
            switch package.kind {
            case .nativeAgent, .agent:
                let reference: RegistryReference?
                if let nativeAgent = package.nativeAgent {
                    reference = RegistryReference(token: nativeAgent, requiresAgentStem: true)
                } else if let name = package.name {
                    reference = RegistryReference(token: name, requiresAgentStem: false)
                } else if let packageID {
                    reference = agentReference(for: packageID)
                } else {
                    reference = nil
                }
                guard let reference, !package.usesSkills.isEmpty else { continue }
                declarations.insert(RegistryDeclaration(
                    agent: reference,
                    skillNames: package.usesSkills.map { skillReference(for: $0) }
                ))
            case .auxiliarySkill, .skill:
                guard let rawSkillToken = package.name ?? packageID else { continue }
                let skillToken = skillReference(for: rawSkillToken)
                let agentReferences: [RegistryReference]
                // In v5 `nativeAgent` is the canonical TOML filename stem.
                // Otherwise only an explicit declared package-ID alias may
                // map to a different canonical Agent name.
                if let nativeAgent = package.nativeAgent {
                    agentReferences = [RegistryReference(token: nativeAgent, requiresAgentStem: true)]
                } else {
                    agentReferences = package.invokedBy.map { agentReference(for: $0) }
                }
                for agent in agentReferences {
                    declarations.insert(RegistryDeclaration(agent: agent, skillNames: [skillToken]))
                }
            case .unknown:
                // Unknown future package types are coverage-only metadata.
                // Do not guess whether they represent an Agent or a Skill.
                continue
            }
        }
        return declarations.sorted {
            $0.agent.token == $1.agent.token
                ? $0.skillNames.joined(separator: "\u{1f}") < $1.skillNames.joined(separator: "\u{1f}")
                : $0.agent.token < $1.agent.token
        }
    }

    private func frontmatterFields(in text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func capture(pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private func matches(pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

public extension CapabilityCompanionResolver {
    static func relations(from resourceRelations: [ResourceRelation]) -> [CapabilityCompanionRelation] {
        resourceRelations.compactMap(CapabilityCompanionRelation.init(resourceRelation:)).sorted { $0.id < $1.id }
    }
}
