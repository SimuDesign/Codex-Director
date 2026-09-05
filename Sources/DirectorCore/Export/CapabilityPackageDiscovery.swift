import Foundation

struct CapabilityPackageProjectContext: Sendable {
    let id: String
    let name: String
    let directory: URL
}

struct CapabilityPackageSourceComponent: Sendable {
    let sourceURL: URL
    let relativeDestination: String
    let relativeTargetPath: String
    let containmentRoot: URL
}

struct CapabilityPackageSource: Sendable {
    let id: String
    let name: String
    let kind: String
    let scope: String
    let ownership: String
    let projectID: String?
    let logicalRoot: String
    let archiveBasePath: String
    let components: [CapabilityPackageSourceComponent]

    var option: CapabilityExportCapabilityOption {
        CapabilityExportCapabilityOption(id: id, name: name, kind: kind, scope: scope, projectID: projectID)
    }
}

struct CapabilityPackageDiscovery: Sendable {
    let environment: CapabilityExportEnvironment
    private var fileManager: FileManager { .default }

    var projectContexts: [CapabilityPackageProjectContext] {
        environment.projects
            .sorted {
                let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                if comparison == .orderedSame { return $0.directory.path < $1.directory.path }
                return comparison == .orderedAscending
            }
            .enumerated()
            .map { index, source in
                CapabilityPackageProjectContext(
                    id: String(format: "project-%03d", index + 1),
                    name: source.displayName,
                    directory: source.directory
                )
            }
    }

    func options() -> CapabilityExportOptions {
        let sources = discoverAll()
        let globals = sources
            .filter { $0.scope == "global" }
            .map(\.option)
            .sorted(by: optionSort)
        let projects = projectContexts.map { project in
            CapabilityExportProjectOption(
                id: project.id,
                name: project.name,
                capabilities: sources
                    .filter { $0.projectID == project.id }
                    .map(\.option)
                    .sorted(by: optionSort)
            )
        }
        return CapabilityExportOptions(globalCapabilities: globals, projects: projects)
    }

    func selectedSources(for selection: CapabilityExportSelection) -> [CapabilityPackageSource] {
        let projectSelections = Dictionary(uniqueKeysWithValues: selection.projects.map { ($0.projectID, $0) })
        return discoverAll().filter { source in
            guard !selection.excludedCapabilityIDs.contains(source.id) else { return false }
            if source.scope == "global" {
                switch source.kind {
                case "agent": return selection.includeGlobalAgents
                case "skill": return selection.includeGlobalSkills
                case "instruction": return selection.includeGlobalInstructions
                default: return false
                }
            }
            guard let projectID = source.projectID, let project = projectSelections[projectID] else { return false }
            switch source.kind {
            case "agent": return project.includeAgents
            case "skill": return project.includeSkills
            case "instruction": return project.includeInstructions
            default: return false
            }
        }.sorted { $0.id < $1.id }
    }

    func selectedProjects(for selection: CapabilityExportSelection) -> [CapabilityPackageProject] {
        let selected = Set(selection.projects.filter(\.isIncluded).map(\.projectID))
        return projectContexts
            .filter { selected.contains($0.id) }
            .map { CapabilityPackageProject(id: $0.id, name: $0.name) }
    }

    private func discoverAll() -> [CapabilityPackageSource] {
        let home = environment.homeDirectory
        var results: [CapabilityPackageSource] = []
        results.append(contentsOf: discoverAgents(
            at: home.appendingPathComponent(".codex/agents", isDirectory: true),
            idPrefix: "global:agent",
            scope: "global",
            projectID: nil,
            logicalRoot: "{{HOME}}/.codex/agents",
            archiveBasePath: "payload/global/agents"
        ))
        results.append(contentsOf: discoverSkills(
            at: home.appendingPathComponent(".codex/skills", isDirectory: true),
            idPrefix: "global:skill:codex",
            scope: "global",
            projectID: nil,
            logicalRoot: "{{HOME}}/.codex/skills",
            archiveBasePath: "payload/global/skills/codex"
        ))
        results.append(contentsOf: discoverSkills(
            at: home.appendingPathComponent(".agents/skills", isDirectory: true),
            idPrefix: "global:skill:agents",
            scope: "global",
            projectID: nil,
            logicalRoot: "{{HOME}}/.agents/skills",
            archiveBasePath: "payload/global/skills/agents"
        ))
        let globalInstructions = home.appendingPathComponent(".codex/AGENTS.md")
        if itemExists(globalInstructions) {
            results.append(instruction(
                at: globalInstructions,
                id: "global:instruction:agents-md",
                scope: "global",
                projectID: nil,
                logicalRoot: "{{HOME}}/.codex",
                archiveBasePath: "payload/global/instructions"
            ))
        }

        for project in projectContexts {
            let projectToken = "{{PROJECT:\(project.id)}}"
            results.append(contentsOf: discoverAgents(
                at: project.directory.appendingPathComponent(".codex/agents", isDirectory: true),
                idPrefix: "project:\(project.id):agent",
                scope: "project",
                projectID: project.id,
                logicalRoot: "\(projectToken)/.codex/agents",
                archiveBasePath: "payload/projects/\(project.id)/agents"
            ))
            results.append(contentsOf: discoverSkills(
                at: project.directory.appendingPathComponent(".agents/skills", isDirectory: true),
                idPrefix: "project:\(project.id):skill:agents",
                scope: "project",
                projectID: project.id,
                logicalRoot: "\(projectToken)/.agents/skills",
                archiveBasePath: "payload/projects/\(project.id)/skills/agents"
            ))
            results.append(contentsOf: discoverSkills(
                at: project.directory.appendingPathComponent(".codex/skills", isDirectory: true),
                idPrefix: "project:\(project.id):skill:codex",
                scope: "project",
                projectID: project.id,
                logicalRoot: "\(projectToken)/.codex/skills",
                archiveBasePath: "payload/projects/\(project.id)/skills/codex"
            ))
            let instructions = project.directory.appendingPathComponent("AGENTS.md")
            if itemExists(instructions) {
                results.append(instruction(
                    at: instructions,
                    id: "project:\(project.id):instruction:agents-md",
                    scope: "project",
                    projectID: project.id,
                    logicalRoot: projectToken,
                    archiveBasePath: "payload/projects/\(project.id)/instructions"
                ))
            }
        }
        return results
    }

    private func discoverAgents(
        at root: URL,
        idPrefix: String,
        scope: String,
        projectID: String?,
        logicalRoot: String,
        archiveBasePath: String
    ) -> [CapabilityPackageSource] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }

        let tomlFiles = children.filter { $0.pathExtension.lowercased() == "toml" }
        let directories = children.filter(isDirectoryItem)
        var usedDirectories = Set<String>()
        var results: [CapabilityPackageSource] = []

        for configuration in tomlFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = configuration.deletingPathExtension().lastPathComponent
            var components = [CapabilityPackageSourceComponent(
                sourceURL: configuration,
                relativeDestination: configuration.lastPathComponent,
                relativeTargetPath: configuration.lastPathComponent,
                containmentRoot: root
            )]
            if let briefDirectory = directories.first(where: { $0.lastPathComponent == stem }) {
                usedDirectories.insert(stem)
                components.append(CapabilityPackageSourceComponent(
                    sourceURL: briefDirectory,
                    relativeDestination: stem,
                    relativeTargetPath: stem,
                    containmentRoot: containmentRoot(for: briefDirectory, collectionRoot: root)
                ))
            }
            results.append(CapabilityPackageSource(
                id: "\(idPrefix):\(portableIdentifier(stem))",
                name: stem,
                kind: "agent",
                scope: scope,
                ownership: "user_owned",
                projectID: projectID,
                logicalRoot: logicalRoot,
                archiveBasePath: archiveBasePath,
                components: components
            ))
        }

        for directory in directories where !usedDirectories.contains(directory.lastPathComponent) {
            let hasBrief = ["agent.md", "Agent.md", "AGENTS.md"].contains {
                itemExists(directory.appendingPathComponent($0))
            }
            guard hasBrief else { continue }
            let name = directory.lastPathComponent
            results.append(CapabilityPackageSource(
                id: "\(idPrefix):\(portableIdentifier(name))",
                name: name,
                kind: "agent",
                scope: scope,
                ownership: "user_owned",
                projectID: projectID,
                logicalRoot: logicalRoot,
                archiveBasePath: archiveBasePath,
                components: [CapabilityPackageSourceComponent(
                    sourceURL: directory,
                    relativeDestination: name,
                    relativeTargetPath: name,
                    containmentRoot: containmentRoot(for: directory, collectionRoot: root)
                )]
            ))
        }
        return results
    }

    private func discoverSkills(
        at root: URL,
        idPrefix: String,
        scope: String,
        projectID: String?,
        logicalRoot: String,
        archiveBasePath: String
    ) -> [CapabilityPackageSource] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return directories.compactMap { directory in
            guard directory.lastPathComponent != ".system",
                  isDirectoryItem(directory),
                  itemExists(directory.appendingPathComponent("SKILL.md")) else { return nil }
            let name = directory.lastPathComponent
            let installed = itemExists(directory.appendingPathComponent("_meta.json"))
                || itemExists(directory.appendingPathComponent(".skill-lock.json"))
            return CapabilityPackageSource(
                id: "\(idPrefix):\(portableIdentifier(name))",
                name: name,
                kind: "skill",
                scope: scope,
                ownership: installed ? "installed" : "user_owned",
                projectID: projectID,
                logicalRoot: logicalRoot,
                archiveBasePath: archiveBasePath,
                components: [CapabilityPackageSourceComponent(
                    sourceURL: directory,
                    relativeDestination: name,
                    relativeTargetPath: name,
                    containmentRoot: containmentRoot(for: directory, collectionRoot: root)
                )]
            )
        }.sorted { $0.id < $1.id }
    }

    private func instruction(
        at url: URL,
        id: String,
        scope: String,
        projectID: String?,
        logicalRoot: String,
        archiveBasePath: String
    ) -> CapabilityPackageSource {
        CapabilityPackageSource(
            id: id,
            name: "AGENTS.md",
            kind: "instruction",
            scope: scope,
            ownership: "user_owned",
            projectID: projectID,
            logicalRoot: logicalRoot,
            archiveBasePath: archiveBasePath,
            components: [CapabilityPackageSourceComponent(
                sourceURL: url,
                relativeDestination: "AGENTS.md",
                relativeTargetPath: "AGENTS.md",
                containmentRoot: url.deletingLastPathComponent()
            )]
        )
    }

    private func itemExists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
    }

    private func isDirectoryItem(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func containmentRoot(for item: URL, collectionRoot: URL) -> URL {
        let isSymbolicLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        return isSymbolicLink ? collectionRoot : item
    }

    private func portableIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars).lowercased()
        return result.isEmpty ? "unnamed" : result
    }

    private func optionSort(_ lhs: CapabilityExportCapabilityOption, _ rhs: CapabilityExportCapabilityOption) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame { return lhs.id < rhs.id }
        return comparison == .orderedAscending
    }
}
