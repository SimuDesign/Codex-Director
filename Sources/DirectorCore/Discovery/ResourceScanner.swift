import Foundation

/// Normalized output of one scan pass.
public struct DiscoveryOutput: Sendable, Equatable {
    public let resources: [CapabilityResource]
    public let issues: [DiscoveryIssue]
    public let provenance: [CapabilityProvenance]
    public let projects: [CapabilityProject]
    public let relations: [ResourceRelation]

    public init(
        resources: [CapabilityResource],
        issues: [DiscoveryIssue],
        provenance: [CapabilityProvenance] = [],
        projects: [CapabilityProject] = [],
        relations: [ResourceRelation] = []
    ) {
        self.resources = resources
        self.issues = issues
        self.provenance = provenance
        self.projects = projects
        self.relations = relations
    }
}

/// A tolerance issue recorded while scanning (missing root, unknown manifest
/// version, symlink escape, unreadable file). Discovery never mutates sources.
public struct DiscoveryIssue: Sendable, Equatable {
    public let rootID: String
    public let relativePath: String
    public let message: String

    public init(rootID: String, relativePath: String, message: String) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.message = message
    }
}

/// Read-only capability discovery over explicit scan roots.
///
/// Recognizes at minimum: Skill manifests (`SKILL.md`), Agent briefs
/// (`agent.md`/`Agent.md`/`AGENTS.md`), project-local skills and agents,
/// project registry entries, and plugin manifests (`.codex-plugin`,
/// `.app.json`, `.mcp.json`, `hooks.json`). Missing roots, absent optional
/// files, and older layouts are tolerated; symlinks that escape an approved
/// root are never followed. The scanner never writes to a discovered root.
public struct ResourceScanner: Sendable {
    private let roots: [ScanRoot]
    private let fileSystem: FileSystemClient
    private let overrides: [String: ResourceClassificationOverride]
    private let userOwnedSkillRegistrations: Set<SkillOwnershipRegistration>
    private let previousFingerprints: [String: String]
    private let previousModified: [String: Bool]

    public init(
        roots: [ScanRoot],
        fileSystem: FileSystemClient = FileSystemClient(),
        overrides: [String: ResourceClassificationOverride] = [:],
        userOwnedSkillRegistrations: Set<SkillOwnershipRegistration> = [],
        previousFingerprints: [String: String] = [:],
        previousModified: [String: Bool] = [:]
    ) {
        self.roots = roots
        self.fileSystem = fileSystem
        self.overrides = overrides
        self.userOwnedSkillRegistrations = userOwnedSkillRegistrations
        self.previousFingerprints = previousFingerprints
        self.previousModified = previousModified
    }

    public func scan() -> DiscoveryOutput {
        var resources: [CapabilityResource] = []
        var issues: [DiscoveryIssue] = []
        var provenance: [CapabilityProvenance] = []
        var projects: [CapabilityProject] = []
        var relations: [ResourceRelation] = []
        var seenIDs = Set<String>()

        for root in roots {
            if root.kind == .projects && !fileSystem.exists(root.url) {
                projects.append(CapabilityProject(id: root.id, name: root.url.lastPathComponent, available: false))
            }
            guard fileSystem.exists(root.url) else {
                issues.append(DiscoveryIssue(rootID: root.id, relativePath: "", message: "Scan root is missing"))
                continue
            }
            guard fileSystem.isDirectory(root.url) else {
                issues.append(DiscoveryIssue(rootID: root.id, relativePath: "", message: "Scan root is not a directory"))
                continue
            }
            switch root.kind {
            case .skills: scanSkills(root: root, resources: &resources, provenance: &provenance, issues: &issues, seen: &seenIDs)
            case .agents: scanAgents(root: root, resources: &resources, issues: &issues, seen: &seenIDs)
            case .plugins: scanPlugins(root: root, resources: &resources, issues: &issues, seen: &seenIDs, relations: &relations)
            case .projects: scanProject(root: root, resources: &resources, provenance: &provenance, projects: &projects, issues: &issues, seen: &seenIDs)
            }
        }

        resources.sort { $0.id < $1.id }
        provenance.sort { $0.id < $1.id }
        projects.sort { $0.id < $1.id }
        return DiscoveryOutput(resources: resources, issues: issues, provenance: provenance, projects: projects, relations: relations)
    }

    // MARK: - Skills

    private func scanSkills(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        provenance: inout [CapabilityProvenance],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>
    ) {
        let lockEntries = (Self.parseJSON(root.url.deletingLastPathComponent().appendingPathComponent(".skill-lock.json")) as? [String: Any])?["skills"] as? [String: Any] ?? [:]
        var discoveredNames = Set<String>()
        for entry in safeEntries(in: root.url, root: root, issues: &issues) {
            guard fileSystem.isDirectory(entry) else { continue }
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard fileSystem.exists(manifest), fileSystem.isReadable(manifest) else { continue }
            let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
            let frontmatter = Frontmatter.parse(text)
            let schemaSupported = Self.schemaIsSupported(frontmatter.metadata["schema"])
            let manifestName = frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 }
            let name = manifestName ?? entry.lastPathComponent
            discoveredNames.insert(name)
            discoveredNames.insert(entry.lastPathComponent)
            let relative = "\(entry.lastPathComponent)/SKILL.md"
            let evidence = skillEvidence(
                name: name,
                entry: entry,
                root: root,
                resourceID: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                issues: &issues
            )

            if !schemaSupported {
                issues.append(DiscoveryIssue(
                    rootID: root.id, relativePath: relative, message: "Unknown manifest version")
                )
            }

            let resource = CapabilityResource(
                id: evidence.resourceID,
                name: name,
                kind: .skill,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: schemaSupported ? evidence.confidence : .unknown,
                summary: frontmatter.fields["description"],
                sourceRootID: root.id,
                relativeSourcePath: relative,
                sourcePathHash: Self.stableHash(relative),
                lastSeenAt: Date(),
                ownership: evidence.ownership,
                origin: evidence.origin,
                classificationConfidence: evidence.confidence,
                originIdentifier: evidence.sourceIdentifier,
                sourceVersion: evidence.version,
                contentFingerprint: evidence.fingerprint,
                sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                modified: evidence.modified
            )
            let canonicalID = resources.first(where: {
                $0.kind == resource.kind && $0.scope == resource.scope && $0.projectID == resource.projectID
                    && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == resource.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })?.id ?? resource.id
            add(resource, to: &resources, seen: &seen)
            if let record = evidence.provenance {
                provenance.append(Self.retarget(record, resourceID: canonicalID, disambiguator: root.id))
            }
        }
        for key in lockEntries.keys.sorted() where !discoveredNames.contains(key) {
            issues.append(DiscoveryIssue(rootID: root.id, relativePath: ".skill-lock.json/\(key)", message: "Installed provenance could not be matched to a local Skill"))
        }
    }

    // MARK: - Agents

    private func scanAgents(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>
    ) {
        for entry in safeEntries(in: root.url, root: root, issues: &issues) {
            guard fileSystem.isDirectory(entry) else { continue }
            let brief = ["agent.md", "Agent.md", "AGENTS.md"]
                .map { entry.appendingPathComponent($0) }
                .first { fileSystem.exists($0) }
            guard let brief else { continue }
            let text = (try? String(contentsOf: brief, encoding: .utf8)) ?? ""
            let name = Self.firstHeading(in: text) ?? entry.lastPathComponent
            let relative = "\(entry.lastPathComponent)/\(brief.lastPathComponent)"
            let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
            let fingerprint = Self.stableHash(text)
            let modified = previousModified[resourceID] == true
                || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
            let purpose = Self.agentPurpose(in: text)

            let resource = CapabilityResource(
                id: resourceID,
                name: name,
                kind: .agent,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: .exact,
                summary: purpose,
                sourceRootID: root.id,
                relativeSourcePath: relative,
                sourcePathHash: Self.stableHash(relative),
                lastSeenAt: Date(),
                contentFingerprint: fingerprint,
                sourceModifiedAt: fileSystem.fileAttributes(brief).map { Date(timeIntervalSince1970: $0.modificationDate) },
                modified: modified
            )
            add(resource, to: &resources, seen: &seen)
        }
    }

    // MARK: - Plugins

    private func scanPlugins(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation]
    ) {
        findPluginDirs(in: root.url, depth: 0, maxDepth: 6, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations)
    }

    private func findPluginDirs(
        in directory: URL,
        depth: Int,
        maxDepth: Int,
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation]
    ) {
        guard depth <= maxDepth else { return }
        for entry in safeEntries(in: directory, root: root, issues: &issues) {
            let marker = entry.appendingPathComponent(".codex-plugin")
            if fileSystem.exists(marker) {
                scanPluginDir(entry, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations)
            } else if fileSystem.isDirectory(entry) {
                findPluginDirs(in: entry, depth: depth + 1, maxDepth: maxDepth, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations)
            }
        }
    }

    private func scanPluginDir(
        _ directory: URL,
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation]
    ) {
        let pluginRelative = Self.relativePath(of: directory, under: root.url)
        let name = directory.lastPathComponent

        let pluginID = Self.stableID(kind: .plugin, scope: root.scope, rootID: root.id, relative: pluginRelative)
        add(CapabilityResource(
            id: pluginID,
            name: name,
            kind: .plugin,
            status: .unknown,
            scope: root.scope,
            projectID: nil,
            confidence: .exact,
            summary: "Plugin (\(pluginRelative))",
            sourceRootID: root.id,
            relativeSourcePath: pluginRelative,
            sourcePathHash: Self.stableHash(pluginRelative),
            lastSeenAt: Date()
        ), to: &resources, seen: &seen)

        // Apps (.app.json -> apps[]).
        let appManifest = directory.appendingPathComponent(".app.json")
        if fileSystem.exists(appManifest), let json = Self.parseJSON(appManifest) as? [String: Any],
           let apps = json["apps"] as? [[String: Any]] {
            for app in apps {
                let appName = (app["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "app"
                add(CapabilityResource(
                    id: Self.stableID(kind: .app, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.app.json/" + appName),
                    name: appName,
                    kind: .app,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: app["description"] as? String,
                    sourceRootID: root.id,
                    relativeSourcePath: pluginRelative + "/.app.json",
                    sourcePathHash: Self.stableHash(pluginRelative + "/.app.json/" + appName),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .app, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.app.json/" + appName), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
            }
        }

        // MCP servers (.mcp.json -> mcpServers keys).
        let mcpManifest = directory.appendingPathComponent(".mcp.json")
        if fileSystem.exists(mcpManifest), let json = Self.parseJSON(mcpManifest) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            for serverName in servers.keys.sorted() {
                add(CapabilityResource(
                    id: Self.stableID(kind: .mcp, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.mcp.json/" + serverName),
                    name: serverName,
                    kind: .mcp,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: "MCP server",
                    sourceRootID: root.id,
                    relativeSourcePath: pluginRelative + "/.mcp.json",
                    sourcePathHash: Self.stableHash(pluginRelative + "/.mcp.json/" + serverName),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .mcp, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.mcp.json/" + serverName), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
            }
        }

        // Hooks (hooks.json).
        let hooksManifest = directory.appendingPathComponent("hooks.json")
        if fileSystem.exists(hooksManifest) {
            add(CapabilityResource(
                id: Self.stableID(kind: .hook, scope: root.scope, rootID: root.id, relative: pluginRelative + "/hooks.json"),
                name: "hooks",
                kind: .hook,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: .exact,
                summary: "Plugin hooks",
                sourceRootID: root.id,
                relativeSourcePath: pluginRelative + "/hooks.json",
                sourcePathHash: Self.stableHash(pluginRelative + "/hooks.json"),
                lastSeenAt: Date()
            ), to: &resources, seen: &seen)
            relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .hook, scope: root.scope, rootID: root.id, relative: pluginRelative + "/hooks.json"), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
        }

        // Plugin-scoped skills and agents.
        let skillsDir = directory.appendingPathComponent("skills")
        if fileSystem.isDirectory(skillsDir) {
            for entry in safeEntries(in: skillsDir, root: root, issues: &issues) where fileSystem.isDirectory(entry) {
                let manifest = entry.appendingPathComponent("SKILL.md")
                guard fileSystem.exists(manifest) else { continue }
                let relative = pluginRelative + "/skills/\(entry.lastPathComponent)/SKILL.md"
                let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
                let frontmatter = Frontmatter.parse(text)
                let resourceID = Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                add(CapabilityResource(
                    id: resourceID,
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    kind: .skill,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: frontmatter.fields["description"],
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: resourceID, relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin skill"))
            }
        }

        let agentsDir = directory.appendingPathComponent("agents")
        if fileSystem.isDirectory(agentsDir) {
            for entry in safeEntries(in: agentsDir, root: root, issues: &issues) where fileSystem.isDirectory(entry) {
                let brief = entry.appendingPathComponent("agent.md")
                guard fileSystem.exists(brief) else { continue }
                let relative = pluginRelative + "/agents/\(entry.lastPathComponent)/agent.md"
                let text = (try? String(contentsOf: brief, encoding: .utf8)) ?? ""
                let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                add(CapabilityResource(
                    id: resourceID,
                    name: entry.lastPathComponent,
                    kind: .agent,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: Self.agentPurpose(in: text),
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(brief).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: resourceID, relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin agent"))
            }
        }
    }

    // MARK: - Projects

    private func scanProject(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        provenance: inout [CapabilityProvenance],
        projects: inout [CapabilityProject],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>
    ) {
        let projectName = root.url.lastPathComponent
        projects.append(CapabilityProject(id: root.id, name: projectName, available: fileSystem.exists(root.url)))

        // Project AGENTS.md brief.
        let agentsMD = root.url.appendingPathComponent("AGENTS.md")
        if fileSystem.exists(agentsMD) {
            add(CapabilityResource(
                id: Self.stableID(kind: .instruction, scope: root.scope, rootID: root.id, relative: "AGENTS.md"),
                name: projectName,
                kind: .instruction,
                status: .unknown,
                scope: root.scope,
                projectID: root.id,
                confidence: .exact,
                summary: "Project instructions (AGENTS.md)",
                sourceRootID: root.id,
                relativeSourcePath: "AGENTS.md",
                sourcePathHash: Self.stableHash("AGENTS.md"),
                lastSeenAt: Date(),
                ownership: .userOwned,
                origin: .local,
                classificationConfidence: .exact
            ), to: &resources, seen: &seen)
        }

        // Project skills: .agents/skills/*/SKILL.md
        let projectSkills = root.url.appendingPathComponent(".agents/skills")
        if fileSystem.isDirectory(projectSkills) {
            for entry in safeEntries(in: projectSkills, root: root, issues: &issues) where fileSystem.isDirectory(entry) {
                let manifest = entry.appendingPathComponent("SKILL.md")
                guard fileSystem.exists(manifest) else { continue }
                let relative = ".agents/skills/\(entry.lastPathComponent)/SKILL.md"
                let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
                let frontmatter = Frontmatter.parse(text)
                let evidence = skillEvidence(
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    entry: entry,
                    root: root,
                    resourceID: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                    issues: &issues
                )
                add(CapabilityResource(
                    id: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    kind: .skill,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: .exact,
                    summary: frontmatter.fields["description"],
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    ownership: evidence.ownership,
                    origin: evidence.origin,
                    classificationConfidence: evidence.confidence,
                    originIdentifier: evidence.sourceIdentifier,
                    sourceVersion: evidence.version,
                    contentFingerprint: evidence.fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: evidence.modified
                ), to: &resources, seen: &seen)
                let canonicalID = resources.first(where: {
                    $0.kind == .skill && $0.scope == root.scope && $0.projectID == root.id
                        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == (frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })?.id ?? evidence.resourceID
                if let record = evidence.provenance { provenance.append(Self.retarget(record, resourceID: canonicalID, disambiguator: root.id)) }
            }
        }

        // Project agents: .codex/agents/*.toml
        let projectAgents = root.url.appendingPathComponent(".codex/agents")
        if fileSystem.isDirectory(projectAgents) {
            for entry in safeEntries(in: projectAgents, root: root, issues: &issues) where entry.pathExtension == "toml" {
                let relative = ".codex/agents/\(entry.lastPathComponent)"
                let text = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                let manifest = Self.parseTopLevelAgentTOML(text)
                add(CapabilityResource(
                    id: resourceID,
                    name: manifest.name ?? entry.deletingPathExtension().lastPathComponent,
                    kind: .agent,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: .exact,
                    summary: manifest.description,
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(entry).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
            }
        }

        // Project registry: agents/registry.json
        let registry = root.url.appendingPathComponent("agents/registry.json")
        if fileSystem.exists(registry), let json = Self.parseJSON(registry) as? [String: Any] {
            let schemaSupported = Self.schemaIsSupported(json["schema"])
            let entries = json["entries"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let name = (entry["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { continue }
                let kind: ResourceKind = (entry["type"] as? String) == "workflow" ? .workflow : .agent
                let relative = "agents/registry.json/\(name)"
                if !schemaSupported {
                    issues.append(DiscoveryIssue(
                        rootID: root.id, relativePath: relative, message: "Unknown manifest version")
                    )
                }
                add(CapabilityResource(
                    id: Self.stableID(kind: kind, scope: root.scope, rootID: root.id, relative: relative),
                    name: name,
                    kind: kind,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: schemaSupported ? .exact : .unknown,
                    summary: entry["description"] as? String,
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
            }
        }
    }

    // MARK: - Helpers

    private struct SkillEvidence {
        let resourceID: String
        let ownership: ResourceOwnership
        let origin: ResourceOrigin
        let confidence: EvidenceConfidence
        let sourceIdentifier: String?
        let version: String?
        let fingerprint: String
        let modified: Bool
        let provenance: CapabilityProvenance?
    }

    /// Resolves classification and local provenance only. No network, `gh`,
    /// credential store, or full source URL is consulted.
    private func skillEvidence(
        name: String,
        entry: URL,
        root: ScanRoot,
        resourceID: String,
        issues: inout [DiscoveryIssue]
    ) -> SkillEvidence {
        let fingerprint = Self.stableHash((try? String(contentsOf: entry.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "")
        let modified = previousModified[resourceID] == true
            || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
        let system = root.scope == .system
            || entry.resolvingSymlinksInPath().standardizedFileURL.path.contains("/.system/")
        if system {
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .builtIn,
                origin: .codexSystem,
                confidence: .exact,
                sourceIdentifier: "codex-system",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":system",
                    resourceID: resourceID,
                    sourceType: .codexSystem,
                    sourceIdentifier: "codex-system",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact
                )
            )
        }

        let installed = installedSkillEvidence(
            name: name,
            entry: entry,
            root: root,
            resourceID: resourceID,
            fingerprint: fingerprint,
            modified: modified
        )
        let manifestRelativePath = Self.relativePath(of: entry.appendingPathComponent("SKILL.md"), under: root.url)
        let registration = SkillOwnershipRegistration(rootID: root.id, relativeManifestPath: manifestRelativePath)
        if userOwnedSkillRegistrations.contains(registration) {
            if installed != nil {
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: manifestRelativePath,
                    message: "Explicit user-owned registration conflicts with installed provenance; registration wins"
                ))
            }
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .userOwned,
                origin: .local,
                confidence: .exact,
                sourceIdentifier: "global-skill-library",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":local-registration",
                    resourceID: resourceID,
                    sourceType: .local,
                    sourceIdentifier: "global-skill-library",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact,
                    modified: modified
                )
            )
        }

        if let installed { return installed }

        if root.scope == .project {
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .userOwned,
                origin: .local,
                confidence: .exact,
                sourceIdentifier: "project-skill-directory",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":project-local",
                    resourceID: resourceID,
                    sourceType: .local,
                    sourceIdentifier: "project-skill-directory",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact,
                    modified: modified
                )
            )
        }

        return SkillEvidence(
            resourceID: resourceID,
            ownership: .installed,
            origin: .unknown,
            confidence: .inferred,
            sourceIdentifier: nil,
            version: nil,
            fingerprint: fingerprint,
            modified: modified,
            provenance: CapabilityProvenance(
                id: resourceID + ":unknown",
                resourceID: resourceID,
                sourceType: .unknown,
                sourceIdentifier: nil,
                version: nil,
                installedAt: nil,
                updatedAt: nil,
                confidence: .inferred,
                modified: modified
            )
        )
    }

    private func installedSkillEvidence(
        name: String,
        entry: URL,
        root: ScanRoot,
        resourceID: String,
        fingerprint: String,
        modified: Bool
    ) -> SkillEvidence? {
        for lockURL in skillLockURLs(for: root) {
            guard let lock = Self.parseJSON(lockURL) as? [String: Any],
                  let entries = lock["skills"] as? [String: Any] else { continue }
            let candidates = [name, entry.lastPathComponent]
            for key in candidates {
                guard let item = entries[key] as? [String: Any] else { continue }
                let sourceType = (item["sourceType"] as? String)?.lowercased() == "github" ? ResourceOrigin.github : .registry
                let source = Self.safeSourceIdentifier(item["source"] as? String)
                let installedAt = Self.parseDate(item["installedAt"])
                let updatedAt = Self.parseDate(item["updatedAt"])
                let record = CapabilityProvenance(
                    id: resourceID + ":" + sourceType.rawValue,
                    resourceID: resourceID,
                    sourceType: sourceType,
                    sourceIdentifier: source,
                    version: item["version"] as? String,
                    installedAt: installedAt,
                    updatedAt: updatedAt,
                    confidence: .exact,
                    modified: modified
                )
                return SkillEvidence(resourceID: resourceID, ownership: .installed, origin: sourceType, confidence: .exact, sourceIdentifier: source, version: item["version"] as? String, fingerprint: fingerprint, modified: modified, provenance: record)
            }
        }

        let meta = entry.appendingPathComponent("_meta.json")
        if let json = Self.parseJSON(meta) as? [String: Any],
           let slug = (json["slug"] as? String).flatMap({ Self.safeSourceIdentifier($0) }) {
            let version = json["version"] as? String
            let record = CapabilityProvenance(
                id: resourceID + ":registry",
                resourceID: resourceID,
                sourceType: .registry,
                sourceIdentifier: slug,
                version: version,
                installedAt: nil,
                updatedAt: nil,
                confidence: .exact,
                modified: modified
            )
            return SkillEvidence(resourceID: resourceID, ownership: .installed, origin: .registry, confidence: .exact, sourceIdentifier: slug, version: version, fingerprint: fingerprint, modified: modified, provenance: record)
        }
        return nil
    }

    private func skillLockURLs(for root: ScanRoot) -> [URL] {
        if root.kind == .projects {
            return [
                root.url.appendingPathComponent(".agents/.skill-lock.json"),
                root.url.appendingPathComponent(".skill-lock.json"),
            ]
        }
        return [root.url.deletingLastPathComponent().appendingPathComponent(".skill-lock.json")]
    }

    private func safeEntries(in directory: URL, root: ScanRoot, issues: inout [DiscoveryIssue]) -> [URL] {
        fileSystem.contents(directory).filter { entry in
            if fileSystem.isSymbolicLink(entry), !Self.isWithinRoot(entry, rootURL: root.url) {
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: entry.lastPathComponent,
                    message: "Symlink escapes approved root; skipped"
                ))
                return false
            }
            return true
        }
    }

    private func add(_ resource: CapabilityResource, to resources: inout [CapabilityResource], seen: inout Set<String>) {
        let adjusted: CapabilityResource
        if let override = overrides[resource.id],
           resource.isSkillClassificationCorrectable,
           override.ownership == .userOwned || override.ownership == .installed {
            let correctedOrigin = override.origin ?? resource.manualClassificationOrigin(for: override.ownership)
            let preservesInstalledSource = override.ownership == .installed && correctedOrigin == resource.origin
            adjusted = CapabilityResource(
                id: resource.id, name: resource.name, kind: resource.kind, status: resource.status,
                scope: resource.scope, projectID: resource.projectID, confidence: resource.confidence,
                summary: resource.summary, sourceRootID: resource.sourceRootID,
                relativeSourcePath: resource.relativeSourcePath, sourcePathHash: resource.sourcePathHash,
                lastSeenAt: resource.lastSeenAt, ownership: override.ownership,
                origin: correctedOrigin, classificationConfidence: .exact,
                originIdentifier: preservesInstalledSource ? resource.originIdentifier : nil,
                sourceVersion: preservesInstalledSource ? resource.sourceVersion : nil,
                contentFingerprint: resource.contentFingerprint,
                sourceModifiedAt: resource.sourceModifiedAt,
                modified: resource.modified
            )
        } else {
            adjusted = resource
        }
        guard seen.insert(adjusted.id).inserted else { return }
        resources.append(adjusted)
    }

    private static func isWithinRoot(_ url: URL, rootURL: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootResolved = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == rootResolved || resolved.hasPrefix(rootResolved + "/")
    }

    private static func relativePath(of url: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func parseJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func safeSourceIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep only a registry slug or GitHub owner/repo; never persist URLs.
        if trimmed.contains("://") { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/."))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    private static func retarget(_ record: CapabilityProvenance, resourceID: String, disambiguator: String) -> CapabilityProvenance {
        CapabilityProvenance(
            id: "\(resourceID):\(record.sourceType.rawValue):\(stableHash(disambiguator))",
            resourceID: resourceID,
            sourceType: record.sourceType,
            sourceIdentifier: record.sourceIdentifier,
            version: record.version,
            installedAt: record.installedAt,
            updatedAt: record.updatedAt,
            confidence: record.confidence,
            modified: record.modified
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000.0) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    /// Supported manifest schema: absent or "1". Anything else is an unknown
    /// version and lowers the produced resources' confidence to `unknown`.
    private static func schemaIsSupported(_ schema: Any?) -> Bool {
        guard let schema else { return true }
        if let string = schema as? String { return string == "1" }
        if let number = schema as? NSNumber { return number.intValue == 1 }
        return false
    }

    private static func firstHeading(in text: String) -> String? {
        text.split(separator: "\n")
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    private struct AgentTOMLManifest {
        let name: String?
        let description: String?
    }

    /// Reads only top-level `name` and `description` fields from a project
    /// Agent TOML. In particular, developer instructions are never treated as
    /// a purpose. The parser is intentionally conservative: malformed,
    /// escaped, oversized, or sensitive values fail closed while the file's
    /// stable path remains discoverable.
    private static func parseTopLevelAgentTOML(_ text: String) -> AgentTOMLManifest {
        let maximumBytes = 64 * 1024
        guard text.utf8.count <= maximumBytes else { return AgentTOMLManifest(name: nil, description: nil) }
        var name: String?
        var description: String?
        var inTable = false
        var ignoringMultilineValue = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if ignoringMultilineValue {
                if line.contains("\"\"\"") || line.contains("'''") { ignoringMultilineValue = false }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inTable = true
                continue
            }
            guard !inTable else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key != "name" && key != "description" {
                if (rawValue.hasPrefix("\"\"\"") && !rawValue.dropFirst(3).contains("\"\"\"")) || (rawValue.hasPrefix("'''") && !rawValue.dropFirst(3).contains("'''")) {
                    ignoringMultilineValue = true
                }
                continue
            }
            guard let value = parseTOMLString(rawValue) else { return AgentTOMLManifest(name: nil, description: nil) }
            if key == "name" {
                guard name == nil else { return AgentTOMLManifest(name: nil, description: nil) }
                name = safeAgentManifestValue(value, maximumLength: 160)
            } else {
                guard description == nil else { return AgentTOMLManifest(name: nil, description: nil) }
                let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                description = safeAgentManifestValue(normalized, maximumLength: 320)
            }
        }
        return AgentTOMLManifest(name: name, description: description)
    }

    private static func parseTOMLString(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        let quote = raw.first!
        guard quote == "\"" || quote == "'" else { return nil }
        let content = raw.dropFirst()
        guard let closing = content.firstIndex(of: quote) else { return nil }
        let body = String(content[..<closing])
        let trailing = content[content.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        // The scanner deliberately accepts only plain single-line strings.
        // Escape sequences are valid TOML, but accepting them here would make
        // a hostile or malformed manifest look like a trusted description.
        // Returning nil keeps the stable resource discoverable while dropping
        // the untrusted metadata.
        guard !body.contains("\\") else { return nil }
        if quote == "'" { return body.contains("'") ? nil : body }
        return body.contains("\"") ? nil : body
    }

    private static func safeAgentManifestValue(_ value: String, maximumLength: Int) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximumLength,
              !PersistenceAllowlist.containsForbiddenValue(normalized) else { return nil }
        return normalized
    }

    /// Extracts only the first bounded declarative paragraph from an Agent
    /// brief. Source body sections are intentionally never persisted.
    private static func agentPurpose(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let missionIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "## mission"
        }

        let startIndex: Int
        if let missionIndex {
            startIndex = missionIndex + 1
        } else if let titleIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") }) {
            startIndex = titleIndex + 1
        } else {
            startIndex = 0
        }

        var paragraph: [String] = []
        for line in lines.dropFirst(startIndex) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                if missionIndex != nil || !paragraph.isEmpty { break }
                continue
            }
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(trimmed)
        }
        let normalized = paragraph.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        // Inspect the complete normalized paragraph before truncation so a
        // credential just beyond the UI bound cannot be silently retained.
        guard !PersistenceAllowlist.containsForbiddenValue(normalized) else { return nil }
        return String(normalized.prefix(320))
    }

    /// FNV-1a 64-bit, hex-encoded — a deterministic, dependency-free stable hash.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stableID(kind: ResourceKind, scope: ResourceScope, rootID: String, relative: String) -> String {
        "\(kind.rawValue):\(scope.rawValue):\(rootID):\(Self.stableHash(relative))"
    }
}

/// Minimal YAML-ish frontmatter parser for `SKILL.md`-style manifests.
/// Handles `key: value` pairs between `---` fences and a JSON `metadata` value.
private struct Frontmatter {
    var fields: [String: String] = [:]
    var metadata: [String: Any] = [:]

    static func parse(_ text: String) -> Frontmatter {
        var result = Frontmatter()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }

        var body: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            body.append(String(line))
        }

        for line in body {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            result.fields[key] = value
        }

        if let metadataText = result.fields["metadata"],
           let data = metadataText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.metadata = json
        }
        return result
    }
}
