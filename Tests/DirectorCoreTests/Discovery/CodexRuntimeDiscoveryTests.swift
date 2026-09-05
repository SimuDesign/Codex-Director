import XCTest
@testable import DirectorCore

/// Current System/Runtime discovery contracts, exercised entirely through an
/// injected fake command client. Fakes mirror the REAL `codex plugin list
/// --json` shape (`{"installed": [...], "available": [...]}`) and the real
/// `.app.json` object shape; array-shaped plugin responses are rejected.
final class CodexRuntimeDiscoveryTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private struct FakeClient: RuntimeCommandClient {
        let handler: @Sendable (String) -> RuntimeCommandResult
        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            handler(arguments.first ?? "")
        }
    }

    private struct ThrowingClient: RuntimeCommandClient {
        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private func makeDiscovery(client: RuntimeCommandClient, approvedSourceRoots: [URL]) -> CodexRuntimeDiscovery {
        CodexRuntimeDiscovery(
            commandClient: client,
            codexExecutableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            approvedSourceRoots: approvedSourceRoots,
            now: epoch
        )
    }

    private func fakeClient(
        version: String = "0.148.0-alpha.9",
        mcpJSON: String = "[]",
        pluginJSON: String = #"{"installed": [], "available": []}"#
    ) -> RuntimeCommandClient {
        FakeClient { firstArgument in
            switch firstArgument {
            case "--version":
                return RuntimeCommandResult(stdout: version + "\n", exitCode: 0, timedOut: false)
            case "mcp":
                return RuntimeCommandResult(stdout: mcpJSON, exitCode: 0, timedOut: false)
            case "plugin":
                return RuntimeCommandResult(stdout: pluginJSON, exitCode: 0, timedOut: false)
            default:
                return RuntimeCommandResult(stdout: "", exitCode: 1, timedOut: false)
            }
        }
    }

    private func assertHonestPartialCoverage(_ result: CodexRuntimeDiscovery.Result) {
        // built-in task-tool catalog has no authoritative source in MVP1.
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.unsupportedCategories.contains("builtin-tools"))
    }

    // MARK: - MCP

    func testCurrentMCPListProducesRuntimeMCPResources() async throws {
        let client = fakeClient(mcpJSON: #"[{"name":"pencil","enabled":true,"transport":"stdio"},{"name":"legacy","enabled":false,"transport":"sse"}]"#)
        let result = await makeDiscovery(client: client, approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")]).discover()
        let mcps = result.resources.filter { $0.kind == .mcp }
        XCTAssertEqual(mcps.count, 2)
        XCTAssertTrue(mcps.allSatisfy { $0.scope == .runtime })
        XCTAssertEqual(mcps.first { $0.name == "pencil" }?.status, .idle)
        XCTAssertEqual(mcps.first { $0.name == "legacy" }?.status, .blocked)
        // Transport details are never persisted.
        XCTAssertFalse(mcps.contains { $0.summary?.contains("stdio") ?? false || $0.summary?.contains("sse") ?? false })
        assertHonestPartialCoverage(result)
    }

    func testDisabledRuntimeEntryIsNotReportedAsAvailable() async throws {
        let client = fakeClient(mcpJSON: #"[{"name":"off","enabled":false}]"#)
        let result = await makeDiscovery(client: client, approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")]).discover()
        let off = result.resources.first { $0.name == "off" }
        XCTAssertNotNil(off)
        XCTAssertNotEqual(off?.status, .idle)
        XCTAssertEqual(off?.status, .blocked)
    }

    // MARK: - Plugins (real response structure)

    private func pluginEntryJSON(name: String, installed: Bool, enabled: Bool = true, sourcePath: String) -> String {
        #"{"name":"\#(name)","installed":\#(installed),"enabled":\#(enabled),"version":"1.0.0","marketplaceName":"curated","marketplaceSource":"remote","source":{"path":"\#(sourcePath)","source":"installed"}}"#
    }

    func testInstalledPluginManifestProducesRuntimePluginAppAndHookResources() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let pluginDir = base.appendingPathComponent("market/figma/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try #"{"apps":{"demo-app":{"description":"demo"}}}"#.write(to: pluginDir.appendingPathComponent(".app.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"demo-mcp":{}}}"#.write(to: pluginDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"hooks":{}}"#.write(to: pluginDir.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)

        let pluginJSON = #"{"installed":[\#(pluginEntryJSON(name: "figma", installed: true, sourcePath: pluginDir.path))],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [base]).discover()

        XCTAssertTrue(result.resources.contains { $0.kind == .plugin && $0.name == "figma" && $0.scope == .runtime })
        XCTAssertTrue(result.resources.contains { $0.kind == .app && $0.name == "demo-app" })
        XCTAssertTrue(result.resources.contains { $0.kind == .mcp && $0.name == "demo-mcp" })
        XCTAssertTrue(result.resources.contains { $0.kind == .hook && $0.name == "hooks" })
        assertHonestPartialCoverage(result)
    }

    func testSymlinkedSkillOutsideValidatedPluginRootIsSkipped() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        let pluginDir = base.appendingPathComponent("plugin", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "---\nname: escaped\ndescription: should-not-read\n---".write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: pluginDir.appendingPathComponent("skills/escaped"), withDestinationURL: outside)
        let pluginJSON = #"{"installed":[\#(pluginEntryJSON(name: "p", installed: true, sourcePath: pluginDir.path))],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [base]).discover()
        XCTAssertFalse(result.resources.contains { $0.kind == .skill && $0.name == "escaped" })
        XCTAssertTrue(result.issues.contains { $0.message.contains("escapes") })
    }

    func testSymlinkedSkillsDirectoryOutsideValidatedPluginRootIsSkippedBeforeEnumeration() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        let pluginDir = base.appendingPathComponent("plugin", isDirectory: true)
        let outside = base.appendingPathComponent("neutral-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "---\nname: escaped-root\ndescription: should-not-read\n---".write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: pluginDir.appendingPathComponent("skills"), withDestinationURL: outside)

        let pluginJSON = #"{"installed":[\#(pluginEntryJSON(name: "p", installed: true, sourcePath: pluginDir.path))],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [base]).discover()

        XCTAssertFalse(result.resources.contains { $0.kind == .skill && $0.name == "escaped-root" })
        XCTAssertTrue(result.issues.contains { $0.relativePath == "skills" && $0.message.contains("skills directory") })
        XCTAssertFalse(result.issues.contains { issue in
            issue.relativePath.contains(outside.lastPathComponent) || issue.message.contains(outside.path)
        })
    }

    func testAppJsonObjectShapeProducesAppResources() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let pluginDir = base.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // Real shape: `apps` is an object keyed by app name.
        try #"{"apps":{"alpha":{"description":"a"},"beta":{"description":"b"}}}"#.write(to: pluginDir.appendingPathComponent(".app.json"), atomically: true, encoding: .utf8)

        let pluginJSON = #"{"installed":[\#(pluginEntryJSON(name: "p1", installed: true, sourcePath: pluginDir.path))],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [base]).discover()
        let apps = result.resources
            .filter { $0.kind == .app && $0.name != "codex-cli" }
            .map(\.name)
        XCTAssertEqual(apps, ["alpha", "beta"])
    }

    func testOnlyInstalledTrueEntriesAreAccepted() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let trueDir = base.appendingPathComponent("true-plugin", isDirectory: true)
        let falseDir = base.appendingPathComponent("false-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: trueDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: falseDir, withIntermediateDirectories: true)

        let pluginJSON = #"{"installed":[\#(pluginEntryJSON(name: "active", installed: true, sourcePath: trueDir.path)),\#(pluginEntryJSON(name: "inactive", installed: false, sourcePath: falseDir.path))],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [base]).discover()
        XCTAssertTrue(result.resources.contains { $0.kind == .plugin && $0.name == "active" })
        XCTAssertFalse(result.resources.contains { $0.kind == .plugin && $0.name == "inactive" })
    }

    func testTopLevelArrayPluginResponseIsRejected() async throws {
        // A top-level array is not the real `codex plugin list --json`
        // response and must not be treated as authoritative.
        let arrayJSON = #"[{"name":"not-real","installed":true}]"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: arrayJSON), approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")]).discover()
        XCTAssertFalse(result.resources.contains { $0.kind == .plugin })
        XCTAssertTrue(result.unsupportedCategories.contains("plugin"))
        XCTAssertEqual(result.coverage, .partial)
    }

    func testTransportArgumentsEnvironmentAndSourcePathAreNeverPersisted() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let pluginJSON = #"{"installed":[{"name":"evil","installed":true,"enabled":true,"command":"/bin/sh","transport":"stdio","env":{"TOKEN":"sk-super-secret"},"auth_token":"sk-bearer-value","marketplaceSource":"remote","source":{"path":"\#(outside.path)","source":"installed"}}],"available":[]}"#
        let result = await makeDiscovery(client: fakeClient(pluginJSON: pluginJSON), approvedSourceRoots: [cacheRoot]).discover()

        // The outside source path must not be read; no dangerous values may
        // appear in any persisted resource field.
        XCTAssertFalse(result.resources.contains { $0.relativeSourcePath?.contains(outside.path) ?? false })
        for resource in result.resources {
            let values = [resource.name, resource.summary ?? "", resource.sourceRootID, resource.relativeSourcePath ?? "", resource.sourcePathHash ?? ""]
            for value in values {
                XCTAssertFalse(value.contains("sk-super-secret"))
                XCTAssertFalse(value.contains("sk-bearer-value"))
                XCTAssertFalse(value.contains("/bin/sh"))
                XCTAssertFalse(value.contains(outside.path))
                XCTAssertFalse(value.contains("remote"))
            }
        }
        for resource in result.resources {
            let dict: [String: Any] = [
                "id": resource.id, "name": resource.name, "kind": resource.kind.rawValue,
                "scope": resource.scope.rawValue, "project_id": resource.projectID ?? "",
                "availability": resource.status.rawValue, "confidence": resource.confidence.rawValue,
                "description": resource.summary ?? "", "source_root_id": resource.sourceRootID,
                "relative_source_path": resource.relativeSourcePath ?? "",
                "source_path_hash": resource.sourcePathHash ?? "",
                "last_seen_at": resource.lastSeenAt.timeIntervalSince1970,
            ]
            XCTAssertTrue(PersistenceAllowlist.validate(dict, allowedKeys: PersistenceAllowlist.resourceKeys))
        }
    }

    // MARK: - Coverage and stability

    func testUnavailableCLIProducesUnknownCoverageWithoutInventedTools() async throws {
        let result = await makeDiscovery(client: ThrowingClient(), approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")]).discover()
        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertTrue(result.resources.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.unsupportedCategories.contains("builtin-tools"))
        XCTAssertTrue(result.unsupportedCategories.contains("version"))
    }

    func testRepeatedRuntimeDiscoveryUsesStableIDs() async throws {
        let client = fakeClient(mcpJSON: #"[{"name":"pencil","enabled":true}]"#)
        let discovery = makeDiscovery(client: client, approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")])
        let first = await discovery.discover()
        let second = await discovery.discover()
        XCTAssertEqual(first.resources.map(\.id), second.resources.map(\.id))
        XCTAssertFalse(first.resources.isEmpty)
    }
}
