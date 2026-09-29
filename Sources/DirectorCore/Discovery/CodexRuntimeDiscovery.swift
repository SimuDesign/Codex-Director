import Foundation

/// Current System/Runtime capability discovery from current local
/// authoritative sources only. Old Session prompts are never used as runtime
/// truth.
///
/// Authoritative sources:
/// - the current Codex executable's `--version` output;
/// - `codex mcp list --json` for configured current MCP server names and
///   enabled state;
/// - the local Codex app-server's `plugin/installed` for installed Plugin
///   identities and transient installed source locations;
/// - manifests inside an installed Plugin source returned by that current
///   command (`.app.json`, `.mcp.json`, `hooks.json`).
///
/// MCP transport, command, arguments, environment, URLs, auth material,
/// marketplace source, stderr, and raw JSON are never parsed or persisted.
/// The CLI does not expose a stable complete built-in task-tool catalog;
/// that coverage is represented as `unknown`/unsupported rather than invented.
public struct CodexRuntimeDiscovery: Sendable {

    public struct Result: Sendable, Equatable {
        public let resources: [CapabilityResource]
        public let issues: [DiscoveryIssue]
        public let coverage: CoverageState
        /// Categories with no authoritative current source. Always includes
        /// "builtin-tools" in MVP1: the approved CLI commands expose no stable
        /// complete built-in task-tool catalog, so that coverage is recorded
        /// as unsupported rather than invented. Overall coverage is never
        /// `complete` while this set is non-empty.
        public let unsupportedCategories: [String]
        public let relations: [ResourceRelation]
        /// Validated install roots, transient only; never persisted.
        public let transientRoots: [String: URL]
        /// Nil when plugin discovery failed. A verified plugin identity list
        /// can still have unavailable child-package manifests (remote-only
        /// plugins expose no validated local source path).
        public let pluginPackagesAvailable: Bool?

        public init(
            resources: [CapabilityResource],
            issues: [DiscoveryIssue],
            coverage: CoverageState,
            unsupportedCategories: [String],
            relations: [ResourceRelation] = [],
            transientRoots: [String: URL] = [:],
            pluginPackagesAvailable: Bool? = nil
        ) {
            self.resources = resources
            self.issues = issues
            self.coverage = coverage
            self.unsupportedCategories = unsupportedCategories
            self.relations = relations
            self.transientRoots = transientRoots
            self.pluginPackagesAvailable = pluginPackagesAvailable
        }
    }

    public let commandClient: RuntimeCommandClient
    /// Kept for injected legacy CLI fixtures. Production uses
    /// `installedPluginReading`, which includes account-installed plugins.
    public let pluginCommandClient: RuntimeCommandClient
    public let installedPluginReading: (any CodexInstalledPluginInventoryReading)?
    public let codexExecutableURL: URL
    /// Directories inside which an installed plugin source path may be read.
    /// The installed plugin sources reported by the Codex runtime live under
    /// `~/.codex/.tmp` and `~/.cache/codex-runtimes` (and the plugin cache);
    /// arbitrary paths outside these approved roots are never read.
    public let approvedSourceRoots: [URL]
    public let fileSystem: FileSystemClient
    private let nowProvider: @Sendable () -> Date

    public init(
        commandClient: RuntimeCommandClient,
        pluginCommandClient: RuntimeCommandClient? = nil,
        installedPluginReading: (any CodexInstalledPluginInventoryReading)? = nil,
        codexExecutableURL: URL,
        approvedSourceRoots: [URL],
        fileSystem: FileSystemClient = FileSystemClient(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.commandClient = commandClient
        self.pluginCommandClient = pluginCommandClient ?? commandClient
        self.installedPluginReading = installedPluginReading
        self.codexExecutableURL = codexExecutableURL
        self.approvedSourceRoots = approvedSourceRoots
        self.fileSystem = fileSystem
        self.nowProvider = nowProvider
    }

    public func discover() async -> Result {
        let now = nowProvider()
        var resources: [CapabilityResource] = []
        var transientRoots: [String: URL] = [:]
        var issues: [DiscoveryIssue] = []
        var completed: [String] = []
        // MVP1: no approved current CLI command exposes a stable complete
        // built-in task-tool catalog; record that coverage as unsupported.
        var unsupportedCategories: [String] = ["builtin-tools"]

        if let version = await runVersion() {
            completed.append("version")
            resources.append(Self.runtimeResource(
                kind: .app, name: "codex-cli", summary: version, status: .idle,
                sourceRootID: "runtime", relative: "codex-cli", now: now
            ))
        } else {
            unsupportedCategories.append("version")
            issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "version", message: "Codex CLI version unavailable"))
        }

        if let mcp = await runMCPList(now: now) {
            completed.append("mcp")
            resources.append(contentsOf: mcp)
        } else {
            unsupportedCategories.append("mcp")
            issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "mcp", message: "MCP list unavailable or unparsable"))
        }

        var pluginPackagesAvailable: Bool?
        if let pluginResources = await runPluginList(now: now, transientRoots: &transientRoots, issues: &issues) {
            completed.append("plugin")
            resources.append(contentsOf: pluginResources)
            pluginPackagesAvailable = pluginResources.filter { $0.kind == .plugin }.allSatisfy { plugin in
                guard let relative = plugin.relativeSourcePath, relative.hasPrefix("plugins/") else { return false }
                let marker = String(relative.dropFirst("plugins/".count))
                return transientRoots["runtime-plugins:\(marker)"] != nil
            }
        } else {
            unsupportedCategories.append("plugin")
            issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "plugin", message: "Plugin list unavailable or unparsable"))
        }

        let coverage: CoverageState
        if completed.isEmpty {
            coverage = .unavailable
        } else if unsupportedCategories.isEmpty {
            coverage = .complete
        } else {
            coverage = .partial
        }
        return Result(
            resources: resources,
            issues: issues,
            coverage: coverage,
            unsupportedCategories: unsupportedCategories,
            relations: Self.pluginRelations(resources),
            transientRoots: transientRoots,
            pluginPackagesAvailable: pluginPackagesAvailable
        )
    }

    // MARK: - Commands

    private func runVersion() async -> String? {
        guard let result = try? await commandClient.run(arguments: ["--version"]),
              result.exitCode == 0, !result.timedOut else {
            return nil
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private func runMCPList(now: Date) async -> [CapabilityResource]? {
        guard let result = try? await commandClient.run(arguments: ["mcp", "list", "--json"]),
              result.exitCode == 0, !result.timedOut,
              let json = Self.parseJSON(result.stdout) else {
            return nil
        }
        let entries = Self.parseNamedEntries(json)
        return entries.map { entry in
            Self.runtimeResource(
                kind: .mcp,
                name: entry.name,
                summary: nil,
                status: entry.enabled ? .idle : .blocked,
                sourceRootID: "runtime-mcp",
                relative: "mcp/\(entry.name)",
                now: now
            )
        }
    }

    private func runPluginList(now: Date, transientRoots: inout [String: URL], issues: inout [DiscoveryIssue]) async -> [CapabilityResource]? {
        let entries: [(id: String, name: String, enabled: Bool, sourcePath: String?)]
        if let installedPluginReading {
            let inventory: CodexInstalledPluginInventory
            do {
                inventory = try await installedPluginReading.read()
            } catch let error as CodexInstalledPluginReadError {
                let issue: String
                switch error {
                case .timedOut: issue = "plugin_query_timed_out"
                case .cancelled: issue = "plugin_query_cancelled"
                case .outputTooLarge: issue = "plugin_query_output_too_large"
                case .malformedResponse, .protocolError: issue = "plugin_query_protocol_error"
                case .unavailable: issue = "plugin_query_unavailable"
                }
                issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "plugin", message: issue))
                return nil
            } catch {
                issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "plugin", message: "plugin_query_unavailable"))
                return nil
            }
            guard inventory.isComplete else {
                issues.append(DiscoveryIssue(rootID: "runtime", relativePath: "plugin", message: inventory.issue ?? "plugin_inventory_incomplete"))
                return nil
            }
            entries = inventory.plugins.map { ($0.id, $0.name, $0.enabled, $0.sourcePath) }
        } else {
            // Compatibility-only path for older injected clients. Production
            // must not mistake a successful CLI JSON result for complete
            // account-backed inventory.
            guard let result = try? await pluginCommandClient.run(arguments: ["plugin", "list", "--json"]),
                  result.exitCode == 0, !result.timedOut, !result.hadStderrOutput,
                  let json = Self.parseJSON(result.stdout),
                  let parsed = Self.parseInstalledPlugins(json) else {
                return nil
            }
            entries = parsed.filter(\.installed).map { ($0.name + "@legacy", $0.name, $0.enabled, $0.sourcePath) }
        }
        let nameCounts = Dictionary(grouping: entries, by: { $0.name }).mapValues(\.count)
        var resources: [CapabilityResource] = []
        for entry in entries {
            // Preserve existing stable IDs for unique names. Distinct
            // marketplaces sharing one name receive separate IDs rather than
            // being silently merged or assigned one another's evaluations.
            let marker = nameCounts[entry.name] == 1 ? entry.name : entry.id
            resources.append(Self.runtimeResource(
                kind: .plugin,
                name: entry.name,
                summary: nil,
                status: entry.enabled ? .idle : .blocked,
                sourceRootID: "runtime-plugins",
                relative: "plugins/\(marker)",
                now: now
            ))
            if let sourcePath = entry.sourcePath,
               let sourceURL = Self.validatedSourceURL(sourcePath, approvedRoots: approvedSourceRoots, fileSystem: fileSystem) {
                transientRoots["runtime-plugins:\(marker)"] = sourceURL
                scanPluginManifests(pluginDir: sourceURL, name: marker, now: now, into: &resources, issues: &issues)
            }
        }
        return resources
    }

    private func scanPluginManifests(pluginDir: URL, name: String, now: Date, into resources: inout [CapabilityResource], issues: inout [DiscoveryIssue]) {
        // Skills are part of the current installed package, not evidence from
        // a cache directory. Keep the absolute install path transient.
        let skillsDir = pluginDir.appendingPathComponent("skills", isDirectory: true)
        let skillEntries: [URL]
        if Self.isWithinRoot(skillsDir, rootURL: pluginDir) {
            skillEntries = fileSystem.contents(skillsDir)
                .filter { fileSystem.isDirectory($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            issues.append(DiscoveryIssue(
                rootID: "runtime-plugins:\(name)",
                relativePath: "skills",
                message: "Plugin skills directory escapes validated source root; skipped"
            ))
            skillEntries = []
        }
        for entry in skillEntries {
            guard Self.isWithinRoot(entry, rootURL: pluginDir) else {
                issues.append(DiscoveryIssue(rootID: "runtime-plugins:\(name)", relativePath: "skills/\(entry.lastPathComponent)", message: "Plugin child escapes validated source root; skipped"))
                continue
            }
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard Self.isWithinRoot(manifest, rootURL: pluginDir) else {
                issues.append(DiscoveryIssue(rootID: "runtime-plugins:\(name)", relativePath: "skills/\(entry.lastPathComponent)/SKILL.md", message: "Plugin manifest escapes validated source root; skipped"))
                continue
            }
            guard fileSystem.exists(manifest), fileSystem.isReadable(manifest) else { continue }
            let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
            let fields = Self.frontmatterFields(text)
            let skillName = fields["name"] ?? entry.lastPathComponent
            resources.append(Self.runtimeResource(
                kind: .skill, name: skillName, summary: fields["description"], status: .idle,
                sourceRootID: "runtime-plugins:\(name)",
                relative: "plugins/\(name)/skills/\(entry.lastPathComponent)/SKILL.md", now: now,
                ownership: .pluginProvided, origin: .plugin
            ))
        }
        let appManifest = pluginDir.appendingPathComponent(".app.json")
        if Self.isWithinRoot(appManifest, rootURL: pluginDir), let json = Self.parseJSONFile(appManifest, fileSystem: fileSystem) as? [String: Any] {
            for appName in Self.appNames(from: json["apps"]) {
                resources.append(Self.runtimeResource(
                    kind: .app, name: appName, summary: nil, status: .idle,
                    sourceRootID: "runtime-plugins",
                    relative: "plugins/\(name)/.app.json/\(appName)", now: now,
                    ownership: .pluginProvided, origin: .plugin
                ))
            }
        }
        let mcpManifest = pluginDir.appendingPathComponent(".mcp.json")
        if Self.isWithinRoot(mcpManifest, rootURL: pluginDir), let json = Self.parseJSONFile(mcpManifest, fileSystem: fileSystem) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            for serverName in servers.keys.sorted() {
                resources.append(Self.runtimeResource(
                    kind: .mcp, name: serverName, summary: nil, status: .idle,
                    sourceRootID: "runtime-plugins",
                    relative: "plugins/\(name)/.mcp.json/\(serverName)", now: now,
                    ownership: .pluginProvided, origin: .plugin
                ))
            }
        }
        let hooksManifest = pluginDir.appendingPathComponent("hooks.json")
        if Self.isWithinRoot(hooksManifest, rootURL: pluginDir), fileSystem.exists(hooksManifest) {
            resources.append(Self.runtimeResource(
                kind: .hook, name: "hooks", summary: nil, status: .idle,
                sourceRootID: "runtime-plugins",
                relative: "plugins/\(name)/hooks.json", now: now,
                ownership: .pluginProvided, origin: .plugin
            ))
        }
    }

    // MARK: - Helpers

    /// Resolves an installed plugin source path only when its resolved
    /// directory stays within one of the approved source roots.
    private static func validatedSourceURL(_ sourcePath: String, approvedRoots: [URL], fileSystem: FileSystemClient) -> URL? {
        guard !sourcePath.isEmpty, sourcePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: sourcePath)
        guard fileSystem.isDirectory(url) else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let insideApprovedRoot = approvedRoots.contains { root in
            let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == rootResolved || resolved.hasPrefix(rootResolved + "/")
        }
        guard insideApprovedRoot else { return nil }
        return url
    }

    private static func isWithinRoot(_ url: URL, rootURL: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    private static func parseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseJSONFile(_ url: URL, fileSystem: FileSystemClient) -> Any? {
        guard fileSystem.exists(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func frontmatterFields(_ text: String) -> [String: String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Parses the real `codex plugin list --json` response: a dictionary with
    /// an `installed` (or `.installed`) array. Only entries with
    /// `installed == true` are current; `available` entries are never used.
    /// A top-level array is not a valid real response and yields nil.
    private static func parseInstalledPlugins(_ json: Any?) -> [(name: String, enabled: Bool, installed: Bool, sourcePath: String?)]? {
        guard let dict = json as? [String: Any] else { return nil }
        let list = dict["installed"] ?? dict[".installed"]
        guard let array = list as? [[String: Any]] else { return nil }
        return array.compactMap { element in
            guard let name = element["name"] as? String, !name.isEmpty else { return nil }
            let installed = element["installed"] as? Bool ?? false
            let enabled = element["enabled"] as? Bool ?? true
            let sourcePath = (element["source"] as? [String: Any])?["path"] as? String
            return (name, enabled, installed, sourcePath)
        }
    }

    /// `.app.json` `apps` may be an object keyed by app name (the real shape)
    /// or an array of `{name}` objects (synthetic compatibility).
    private static func appNames(from value: Any?) -> [String] {
        if let dict = value as? [String: Any] {
            return dict.keys.sorted()
        }
        if let array = value as? [[String: Any]] {
            return array.compactMap { $0["name"] as? String }.sorted()
        }
        return []
    }

    /// Tolerant parsing of `name` + `enabled` from an array of objects
    /// (the real `codex mcp list --json` shape) or a dict keyed by name.
    private static func parseNamedEntries(_ json: Any?) -> [(name: String, enabled: Bool, sourcePath: String?)] {
        if let dict = json as? [String: Any] {
            return dict.compactMap { key, value in
                guard !key.isEmpty else { return nil }
                let object = value as? [String: Any]
                return (key, object?["enabled"] as? Bool ?? true, object?["source_path"] as? String)
            }
            .sorted { $0.name < $1.name }
        }
        if let array = json as? [[String: Any]] {
            return array.compactMap { element in
                guard let name = element["name"] as? String, !name.isEmpty else { return nil }
                return (name, element["enabled"] as? Bool ?? true, element["source_path"] as? String)
            }
        }
        return []
    }

    private static func runtimeResource(
        kind: ResourceKind,
        name: String,
        summary: String?,
        status: RuntimeStatus,
        sourceRootID: String,
        relative: String,
        now: Date,
        ownership: ResourceOwnership? = nil,
        origin: ResourceOrigin? = nil
    ) -> CapabilityResource {
        CapabilityResource(
            id: "\(kind.rawValue):runtime:\(stableHash(name + relative))",
            name: name,
            kind: kind,
            status: status,
            scope: .runtime,
            projectID: nil,
            confidence: .exact,
            summary: summary,
            sourceRootID: sourceRootID,
            relativeSourcePath: relative,
            sourcePathHash: stableHash(relative),
            lastSeenAt: now,
            ownership: ownership,
            origin: origin
        )
    }

    private static func pluginRelations(_ resources: [CapabilityResource]) -> [ResourceRelation] {
        let plugins = resources.filter { $0.kind == .plugin }
        return plugins.flatMap { plugin in
            let prefix = plugin.relativeSourcePath.map { $0 + "/" } ?? ""
            return resources.filter { candidate in
                candidate.id != plugin.id && candidate.relativeSourcePath?.hasPrefix(prefix) == true
            }.map {
                ResourceRelation(sourceResourceID: plugin.id, targetResourceID: $0.id, relationKind: "contains", confidence: .exact, evidenceSummary: "Current runtime plugin")
            }
        }
    }

    /// FNV-1a 64-bit, hex-encoded — deterministic, dependency-free.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
