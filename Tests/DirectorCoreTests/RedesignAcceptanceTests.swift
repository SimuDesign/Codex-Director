import XCTest
@testable import DirectorCore

/// Independent acceptance contracts for the 0.2 capability-centered redesign.
/// These tests intentionally exercise the public core seams; they do not
/// change production behavior or use the real Codex executable.
final class RedesignAcceptanceTests: XCTestCase {
    private struct FakeRuntime: RuntimeCommandClient {
        let pluginJSON: String

        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            switch arguments.first {
            case "--version":
                return RuntimeCommandResult(stdout: "codex 0.2\n", exitCode: 0, timedOut: false)
            case "mcp":
                return RuntimeCommandResult(stdout: "[]", exitCode: 0, timedOut: false)
            case "plugin":
                return RuntimeCommandResult(stdout: pluginJSON, exitCode: 0, timedOut: false)
            default:
                return RuntimeCommandResult(stdout: "", exitCode: 1, timedOut: false)
            }
        }
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-redesign-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pluginEntry(name: String, installed: Bool, enabled: Bool, path: String) -> String {
        #"{"name":"\#(name)","installed":\#(installed),"enabled":\#(enabled),"source":{"path":"\#(path)","source":"installed"}}"#
    }

    func testRuntimeInventoryUsesInstalledStateAndIndexesRealPluginSkill() async throws {
        let root = try temporaryDirectory("runtime")
        let enabled = root.appendingPathComponent("enabled-plugin", isDirectory: true)
        let disabled = root.appendingPathComponent("disabled-plugin", isDirectory: true)
        for directory in [enabled, disabled] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("skills/real-skill"), withIntermediateDirectories: true)
            try "---\nname: real-skill\ndescription: installed skill\n---\n# Real Skill\n"
                .write(to: directory.appendingPathComponent("skills/real-skill/SKILL.md"), atomically: true, encoding: .utf8)
        }
        let json = #"{"installed":[\#(pluginEntry(name: "enabled", installed: true, enabled: true, path: enabled.path)),\#(pluginEntry(name: "disabled", installed: true, enabled: false, path: disabled.path)),\#(pluginEntry(name: "stale-cache", installed: false, enabled: true, path: disabled.path))],"available":[]}"#
        let result = await CodexRuntimeDiscovery(
            commandClient: FakeRuntime(pluginJSON: json),
            codexExecutableURL: URL(fileURLWithPath: "/tmp/codex"),
            approvedSourceRoots: [root]
        ).discover()

        let plugins = result.resources.filter { $0.kind == .plugin }
        XCTAssertEqual(Set(plugins.map(\.name)), ["enabled", "disabled"])
        XCTAssertEqual(plugins.first(where: { $0.name == "disabled" })?.status, .blocked)
        XCTAssertTrue(result.resources.contains {
            $0.kind == .skill && $0.name == "real-skill" && $0.ownership == .pluginProvided && $0.origin == .plugin
        })
    }

    func testRuntimePluginManifestReadResolvesCanonicalSkillWhenRuntimeRootIsSupplied() async throws {
        let root = try temporaryDirectory("evidence")
        let plugin = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("skills/real-skill"), withIntermediateDirectories: true)
        try "---\nname: real-skill\ndescription: installed skill\n---\n# Real Skill\n"
            .write(to: plugin.appendingPathComponent("skills/real-skill/SKILL.md"), atomically: true, encoding: .utf8)
        let discoveryJSON = #"{"installed":[\#(pluginEntry(name: "p", installed: true, enabled: true, path: plugin.path))],"available":[]}"#
        let discovered = await CodexRuntimeDiscovery(
            commandClient: FakeRuntime(pluginJSON: discoveryJSON),
            codexExecutableURL: URL(fileURLWithPath: "/tmp/codex"),
            approvedSourceRoots: [root]
        ).discover()
        let runtimeSkill = try XCTUnwrap(discovered.resources.first { $0.kind == .skill })
        let resolver = SkillEvidenceResolver(
            resources: [runtimeSkill],
            transientRoots: discovered.transientRoots
        )
        let input = "cat \(plugin.path)/skills/real-skill/SKILL.md"
        let resolved = resolver.resolveManifestReadSignal(input: input, toolName: "exec_command")
        XCTAssertEqual(resolved?.resourceID, runtimeSkill.id)
        XCTAssertEqual(resolved?.confidence, .inferred)
    }

    func testSamePhysicalPluginSkillDoesNotAcquireDifferentIdentityAcrossCacheAndRuntime() async throws {
        let root = try temporaryDirectory("identity")
        let plugin = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("skills/s"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try "---\nname: shared-skill\n---\n# Shared\n".write(to: plugin.appendingPathComponent("skills/s/SKILL.md"), atomically: true, encoding: .utf8)
        let cache = ResourceScanner(roots: [ScanRoot(id: "cache", url: root, scope: .plugin, kind: .plugins)]).scan()
        let cacheSkill = try XCTUnwrap(cache.resources.first { $0.kind == .skill && $0.name == "shared-skill" })
        let json = #"{"installed":[\#(pluginEntry(name: "p", installed: true, enabled: true, path: plugin.path))],"available":[]}"#
        let runtimeDiscovery = CodexRuntimeDiscovery(
            commandClient: FakeRuntime(pluginJSON: json),
            codexExecutableURL: URL(fileURLWithPath: "/tmp/codex"),
            approvedSourceRoots: [root]
        )
        let storeDirectory = try temporaryDirectory("identity-store")
        let activeDirectory = try temporaryDirectory("identity-active")
        let store = try DatabaseStore(url: storeDirectory.appendingPathComponent("index.sqlite"))
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "cache", url: root, scope: .plugin, kind: .plugins)],
            activeSessionRoots: [activeDirectory],
            archivedSessionRoot: nil
        )
        _ = try await IndexingCoordinator(store: store, runtimeDiscovery: runtimeDiscovery)
            .run(configuration: configuration)
        let currentSkills = try await store.fetchAllResources().filter { $0.kind == .skill && $0.name == "shared-skill" }
        XCTAssertEqual(currentSkills.count, 1, "one physical current Skill must retain one canonical resource identity")
        XCTAssertEqual(currentSkills.first?.id, cacheSkill.id, "reconciliation must retain the pre-existing cache identity for evaluation/history compatibility")
    }
}
