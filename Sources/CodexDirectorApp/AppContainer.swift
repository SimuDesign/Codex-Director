import Foundation
import DirectorCore

/// Dependency container for the executable target.
///
/// Builds the derived database, indexing coordinator, and default scan
/// configuration from the user's home directory at runtime — the home path is
/// never hardcoded in source. A database bootstrap failure is retained as a
/// privacy-safe category so the app can show a failure state without sample
/// data or filesystem details.
struct AppContainer: Sendable {
    let store: DatabaseStore?
    let readStore: DatabaseStore?
    let coordinator: IndexingCoordinator?
    let configuration: IndexingCoordinator.Configuration?
    let snapshotStore: PresentationSnapshotStore?
    let capabilityExportCoordinator: CapabilityExportCoordinator
    let runtimeStatus: CodexRuntimeStatus
    let bootstrapError: String?

    init(
        store: DatabaseStore?,
        readStore: DatabaseStore? = nil,
        coordinator: IndexingCoordinator?,
        configuration: IndexingCoordinator.Configuration?,
        snapshotStore: PresentationSnapshotStore? = nil,
        capabilityExportCoordinator: CapabilityExportCoordinator,
        runtimeStatus: CodexRuntimeStatus = .unavailable,
        bootstrapError: String? = nil
    ) {
        self.store = store
        self.readStore = readStore
        self.coordinator = coordinator
        self.configuration = configuration
        self.snapshotStore = snapshotStore
        self.capabilityExportCoordinator = capabilityExportCoordinator
        self.runtimeStatus = runtimeStatus
        self.bootstrapError = bootstrapError
    }

    static func bootstrap() async -> AppContainer {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default
        let selectedRuntime = CodexRuntimePreferenceStore().selectedURL()
        async let runtimeStatusTask = CodexRuntimeLocator().locate(userSelectedURL: selectedRuntime)

        guard let databaseURL = try? DatabaseStore.defaultDatabaseURL(),
              let writer = try? DatabaseStore(url: databaseURL),
              let reader = try? DatabaseStore(url: databaseURL, readOnly: true) else {
            let runtimeStatus = await runtimeStatusTask
            return AppContainer(
                store: nil,
                readStore: nil,
                coordinator: nil,
                configuration: nil,
                capabilityExportCoordinator: makeCapabilityExportCoordinator(
                    home: home,
                    executable: runtimeStatus.isUsable ? runtimeStatus.executableURL : nil
                ),
                runtimeStatus: runtimeStatus,
                bootstrapError: "derived_database_unavailable"
            )
        }
        let store = writer
        let runtimeStatus = await runtimeStatusTask
        let codexDir = home + "/.codex"
        let approvedSourceRoots = [
            URL(fileURLWithPath: codexDir + "/plugins/cache"),
            URL(fileURLWithPath: codexDir + "/.tmp"),
            URL(fileURLWithPath: home + "/.cache/codex-runtimes"),
        ]
        let runtimeDiscovery = runtimeStatus.isUsable ? runtimeStatus.executableURL.map { executable in
            CodexRuntimeDiscovery(
                commandClient: ProcessRuntimeCommandClient(executableURL: executable),
                codexExecutableURL: executable,
                approvedSourceRoots: approvedSourceRoots
            )
        } : nil
        let overrideStore = ResourceClassificationOverrideStore()
        let coordinator = IndexingCoordinator(store: store, runtimeDiscovery: runtimeDiscovery)
        let configuration = defaultConfiguration(home: home, fileManager: fileManager, overrides: overrideStore.all())
        // The startup controller owns the single cache actor created before
        // bootstrap. Do not create a second actor for the same file here.
        return AppContainer(
            store: store,
            readStore: reader,
            coordinator: coordinator,
            configuration: configuration,
            capabilityExportCoordinator: makeCapabilityExportCoordinator(
                home: home,
                executable: runtimeStatus.isUsable ? runtimeStatus.executableURL : nil
            ),
            runtimeStatus: runtimeStatus
        )
    }

    /// Performs all filesystem, SQLite, and runtime-discovery setup away from
    /// the main actor. App construction uses this asynchronous seam so the
    /// first window can be displayed before the derived index is opened.
    static func bootstrapAsync() async -> AppContainer {
        await Task.detached(priority: .userInitiated) {
            await bootstrap()
        }.value
    }

    static func cacheStoreWithoutDatabase() async -> PresentationSnapshotStore? {
        await Task.detached(priority: .utility) {
            presentationCacheURL(fileManager: .default).map { url in
                PresentationSnapshotStore(url: url)
            }
        }.value
    }

    private static func presentationCacheURL(fileManager: FileManager) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("CodexDirector", isDirectory: true).appendingPathComponent("PresentationCache", isDirectory: true).appendingPathComponent("presentation-snapshot.json")
    }

    private static func makeCapabilityExportCoordinator(home: String, executable: URL?) -> CapabilityExportCoordinator {
        let codexDirectory = URL(fileURLWithPath: home).appendingPathComponent(".codex", isDirectory: true)
        let projectSources = projectPaths(fromConfigAt: codexDirectory.appendingPathComponent("config.toml"))
            .map { path in
                CapabilityExportProjectSource(directory: URL(fileURLWithPath: path))
            }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let platform = CapabilityPackagePlatform(
            operatingSystem: "macOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: runtimeArchitecture
        )
        let pluginProvider: any CapabilityPluginInventoryProviding
        if let executable {
            pluginProvider = RuntimeCapabilityPluginInventoryProvider(
                commandClient: ProcessRuntimeCommandClient(executableURL: executable)
            )
        } else {
            pluginProvider = UnavailableCapabilityPluginInventoryProvider()
        }
        return CapabilityExportCoordinator(
            environment: CapabilityExportEnvironment(
                homeDirectory: URL(fileURLWithPath: home),
                projects: projectSources,
                producer: CapabilityPackageProducer(version: version, build: build),
                platform: platform
            ),
            pluginProvider: pluginProvider
        )
    }

    private static var runtimeArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    // MARK: - Default configuration

    private static func defaultConfiguration(
        home: String, fileManager: FileManager,
        overrides: [String: ResourceClassificationOverride] = [:]
    ) -> IndexingCoordinator.Configuration {
        let codexDir = home + "/.codex"
        var scanRoots: [ScanRoot] = [
            ScanRoot(id: "system-skills", url: URL(fileURLWithPath: codexDir + "/skills/.system"), scope: .system, kind: .skills),
            ScanRoot(id: "global-skills", url: URL(fileURLWithPath: codexDir + "/skills"), scope: .global, kind: .skills),
            ScanRoot(id: "agent-skills", url: URL(fileURLWithPath: home + "/.agents/skills"), scope: .global, kind: .skills),
            ScanRoot(id: "global-agents", url: URL(fileURLWithPath: codexDir + "/agents"), scope: .global, kind: .agents),
            ScanRoot(id: "plugin-cache", url: URL(fileURLWithPath: codexDir + "/plugins/cache"), scope: .plugin, kind: .plugins),
        ]
        for path in projectPaths(fromConfigAt: URL(fileURLWithPath: codexDir + "/config.toml")) {
            scanRoots.append(ScanRoot(
                id: stableProjectID(path),
                url: URL(fileURLWithPath: path),
                scope: .project,
                kind: .projects
            ))
        }
        return IndexingCoordinator.Configuration(
            scanRoots: scanRoots,
            activeSessionRoots: [URL(fileURLWithPath: codexDir + "/sessions")],
            archivedSessionRoot: URL(fileURLWithPath: codexDir + "/archived_sessions"),
            classificationOverrides: overrides,
            skillOwnershipRegistryURL: URL(fileURLWithPath: codexDir + "/AGENTS.md")
        )
    }

    private static func stableProjectID(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in URL(fileURLWithPath: path).standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "project-\(String(format: "%016llx", hash))"
    }

    /// Reads `[projects."<path>"]` section headers from config.toml.
    static func projectPaths(fromConfigAt url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var paths: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[projects.\"") else { continue }
            let inner = trimmed.dropFirst("[projects.\"".count)
            guard let end = inner.firstIndex(of: "\"") else { continue }
            paths.append(String(inner[..<end]))
        }
        return paths
    }
}
