import CryptoKit
import Foundation
import XCTest
@testable import DirectorCore

final class CapabilityPackageTests: XCTestCase {
    private struct CommandClient: RuntimeCommandClient {
        let result: RuntimeCommandResult

        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            XCTAssertEqual(arguments, ["plugin", "list", "--json"])
            return result
        }
    }

    private struct PluginProvider: CapabilityPluginInventoryProviding {
        let status: CapabilityPluginInventoryStatus

        func inventory(at date: Date) async -> CapabilityPackagePluginList {
            CapabilityPackagePluginList(
                status: status,
                generatedAt: date,
                plugins: status == .complete
                    ? [CapabilityPackagePlugin(
                        identifier: "demo@catalog",
                        name: "demo",
                        marketplace: "catalog",
                        version: "1.2.3",
                        enabled: true
                    )]
                    : [],
                issue: status == .incomplete ? "synthetic_failure" : nil
            )
        }
    }

    private actor GatedPluginProvider: CapabilityPluginInventoryProviding {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        func inventory(at date: Date) async -> CapabilityPackagePluginList {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return CapabilityPackagePluginList(status: .complete, generatedAt: date, plugins: [])
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testOptionsPairGlobalAgentAndLeaveProjectsUnselectedByDefault() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let options = try await coordinator.options()

        XCTAssertTrue(options.globalCapabilities.contains { $0.id == "global:agent:video-director" })
        XCTAssertTrue(options.globalCapabilities.contains { $0.id == "global:skill:codex:local-skill" })
        XCTAssertEqual(options.projects.count, 1)

        let selection = CapabilityExportSelection.defaults(for: options)
        XCTAssertTrue(selection.includeGlobalAgents)
        XCTAssertTrue(selection.includeGlobalSkills)
        XCTAssertTrue(selection.includeGlobalInstructions)
        XCTAssertEqual(selection.projects.count, 1)
        XCTAssertFalse(selection.projects[0].isIncluded)
    }

    func testSyntheticExportRewritesPathsExcludesCachesAndRoundTrips() async throws {
        let fixture = try makeFixture()
        let sourceSkill = fixture.home.appendingPathComponent(".codex/skills/local-skill/SKILL.md")
        let sourceBefore = try fileSnapshot(sourceSkill)
        let coordinator = makeCoordinator(fixture: fixture)
        let options = try await coordinator.options()
        var selection = CapabilityExportSelection.defaults(for: options)
        selection.projects = options.projects.map {
            CapabilityExportProjectSelection(
                projectID: $0.id,
                includeAgents: true,
                includeSkills: true,
                includeInstructions: true
            )
        }

        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        XCTAssertEqual(preview.agentCount, 2)
        XCTAssertEqual(preview.skillCount, 3)
        XCTAssertEqual(preview.instructionCount, 2)
        XCTAssertEqual(preview.pluginStatus, .complete)
        XCTAssertEqual(preview.pluginCount, 1)
        XCTAssertEqual(preview.binaryFileCount, 1)
        XCTAssertTrue(preview.issues.contains { $0.code == "binary_content_unscanned" })

        let destination = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        let result = try await coordinator.writePreparedPackage(to: destination)
        XCTAssertEqual(result, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try fileSnapshot(sourceSkill), sourceBefore, "Source files must not be changed by export")

        let extraction = try temporaryDirectory("extracted")
        try CapabilityPackageArchiveVerifier().verify(archiveURL: destination, extractionDirectory: extraction)
        let manifest = try decode(CapabilityPackageManifestV1.self, at: extraction.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.projects.map(\.id), ["project-001"])
        XCTAssertEqual(manifest.entries.map(\.archivePath), manifest.entries.map(\.archivePath).sorted())
        XCTAssertEqual(manifest.capabilities.map(\.id), manifest.capabilities.map(\.id).sorted())
        XCTAssertFalse(try String(contentsOf: extraction.appendingPathComponent("manifest.json"), encoding: .utf8).contains(fixture.home.path))
        XCTAssertFalse(try String(contentsOf: extraction.appendingPathComponent("manifest.json"), encoding: .utf8).contains(fixture.project.path))

        let exportedSkill = extraction.appendingPathComponent("payload/global/skills/codex/local-skill/SKILL.md")
        let exportedText = try String(contentsOf: exportedSkill, encoding: .utf8)
        XCTAssertTrue(exportedText.contains("{{HOME}}/.codex/skills/local-skill"))
        XCTAssertFalse(exportedText.contains(fixture.home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.appendingPathComponent("payload/global/skills/codex/local-skill/cache/ignored.txt").path))

        let scriptEntry = try XCTUnwrap(manifest.entries.first { $0.relativePath.hasSuffix("scripts/run.sh") })
        XCTAssertTrue(scriptEntry.executable)
        XCTAssertEqual(scriptEntry.inspection, .scannedText)
        let binaryEntry = try XCTUnwrap(manifest.entries.first { $0.relativePath.hasSuffix("image.png") })
        XCTAssertEqual(binaryEntry.inspection, .unscannedBinary)
        XCTAssertEqual(binaryEntry.contentType, "image/png")

        let pluginsText = try String(contentsOf: extraction.appendingPathComponent("plugins.json"), encoding: .utf8)
        XCTAssertTrue(pluginsText.contains("demo@catalog"))
        XCTAssertFalse(pluginsText.contains("/Users/"))
        let requirements = try decode(
            CapabilityPackageRequirementList.self,
            at: extraction.appendingPathComponent("requirements.json")
        )
        XCTAssertEqual(requirements.requirements.map(\.name), ["Bash", "Codex"])
        let restoreText = try String(contentsOf: extraction.appendingPathComponent("RESTORE.md"), encoding: .utf8)
        XCTAssertTrue(restoreText.contains("Do not execute them"))
        XCTAssertTrue(restoreText.contains("不得执行"))

        try restore(manifest: manifest, extractedRoot: extraction, newHome: fixture.secondHome, projectMap: ["project-001": fixture.secondProject])
        for entry in manifest.entries {
            let restored = restoredURL(for: entry, newHome: fixture.secondHome, projectMap: ["project-001": fixture.secondProject])
            XCTAssertEqual(try hashItem(restored), entry.sha256)
            if entry.inspection != .validatedSymlink {
                let attributes = try FileManager.default.attributesOfItem(atPath: restored.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                XCTAssertEqual(permissions & 0o111 != 0, entry.executable)
            }
        }
    }

    func testCredentialDetectionBlocksExportUntilCapabilityIsExcluded() async throws {
        let fixture = try makeFixture()
        let unsafe = fixture.home.appendingPathComponent(".codex/skills/unsafe-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        try Data("---\nname: unsafe-skill\n---\napi_key=abcdefghijk12345\n".utf8)
            .write(to: unsafe.appendingPathComponent("SKILL.md"))
        let coordinator = makeCoordinator(fixture: fixture)
        let options = try await coordinator.options()
        var selection = CapabilityExportSelection.defaults(for: options)

        let blocked = try await coordinator.prepare(selection: selection)
        let issue = try XCTUnwrap(blocked.issues.first { $0.code == "sensitive_text_detected" })
        XCTAssertEqual(issue.severity, .blocking)
        XCTAssertEqual(issue.capabilityID, "global:skill:codex:unsafe-skill")

        do {
            _ = try await coordinator.writePreparedPackage(to: fixture.output.appendingPathComponent("blocked.codexpack.zip"))
            XCTFail("A package with blocking issues must not be written")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .blockingIssues)
        }

        selection.excludedCapabilityIDs.insert("global:skill:codex:unsafe-skill")
        let allowed = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(allowed.hasBlockingIssues)
        XCTAssertTrue(allowed.excludedCapabilityIDs.contains("global:skill:codex:unsafe-skill"))
    }

    func testEscapingSymbolicLinkIsBlocking() async throws {
        let fixture = try makeFixture()
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = fixture.home.appendingPathComponent(".codex/skills/local-skill/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertTrue(preview.issues.contains { $0.code == "unsafe_symlink" && $0.severity == .blocking })
    }

    func testTopLevelSkillSymlinkCannotEscapeSkillCollection() async throws {
        let fixture = try makeFixture()
        let outsideSkill = fixture.root.appendingPathComponent("outside-skill", isDirectory: true)
        try write("---\nname: outside-skill\n---\n", to: outsideSkill.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent(".codex/skills/linked-outside"),
            withDestinationURL: outsideSkill
        )
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())

        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertTrue(preview.issues.contains {
            $0.code == "unsafe_symlink" && $0.capabilityID == "global:skill:codex:linked-outside"
        })
    }

    func testCredentialLikeFileNameIsBlockedWithoutEchoingItInIssueLocation() async throws {
        let fixture = try makeFixture()
        let skill = fixture.home.appendingPathComponent(".codex/skills/path-skill", isDirectory: true)
        try write("---\nname: path-skill\n---\n", to: skill.appendingPathComponent("SKILL.md"))
        try write("unsafe", to: skill.appendingPathComponent("assets/token=abcdefghijkl"))
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())

        let preview = try await coordinator.prepare(selection: selection)
        let issue = try XCTUnwrap(preview.issues.first { $0.code == "sensitive_path_detected" })
        XCTAssertEqual(issue.severity, .blocking)
        XCTAssertEqual(issue.capabilityID, "global:skill:codex:path-skill")
        XCTAssertNil(issue.relativePath)
    }

    func testPluginFailureIsIncompleteWarningNotZeroPluginSuccess() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture, pluginStatus: .incomplete)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertEqual(preview.pluginStatus, .incomplete)
        XCTAssertEqual(preview.pluginCount, 0)
        XCTAssertTrue(preview.issues.contains { $0.code == "plugin_inventory_incomplete" && $0.severity == .warning })
    }

    func testUnavailableRuntimeProviderReportsIncompleteInventory() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let inventory = await UnavailableCapabilityPluginInventoryProvider().inventory(at: date)

        XCTAssertEqual(inventory.status, .incomplete)
        XCTAssertEqual(inventory.generatedAt, date)
        XCTAssertTrue(inventory.plugins.isEmpty)
        XCTAssertEqual(inventory.issue, "plugin_query_unavailable")
    }

    func testRuntimePluginListUsesRealCLIShapeWithoutPersistingSourcePath() async throws {
        let json = #"{"installed":[{"name":"figma","installed":true,"enabled":false,"version":"2.0.21","marketplaceName":"openai-curated-remote","source":{"path":"/Users/example/.codex/plugins/figma"}}],"available":[]}"#
        let provider = RuntimeCapabilityPluginInventoryProvider(commandClient: CommandClient(
            result: RuntimeCommandResult(stdout: json, exitCode: 0, timedOut: false)
        ))
        let inventory = await provider.inventory(at: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(inventory.status, .complete)
        XCTAssertEqual(inventory.plugins.count, 1)
        XCTAssertEqual(inventory.plugins[0].identifier, "figma@openai-curated-remote")
        XCTAssertFalse(inventory.plugins[0].enabled)
        let encoded = try JSONEncoder().encode(inventory)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/Users/"))
    }

    func testConcurrentPrepareIsRejected() async throws {
        let fixture = try makeFixture()
        let provider = GatedPluginProvider()
        let coordinator = CapabilityExportCoordinator(
            environment: environment(fixture: fixture),
            pluginProvider: provider,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let first = Task { try await coordinator.prepare(selection: selection) }
        while !(await provider.started) { await Task.yield() }

        do {
            _ = try await coordinator.prepare(selection: selection)
            XCTFail("Concurrent export work must be rejected")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .operationInProgress)
        }
        await provider.release()
        _ = try await first.value
    }

    func testCancellationCleansStagingDirectory() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let before = temporaryItems(withPrefix: "CodexDirectorExport-")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await coordinator.prepare(selection: selection) { progress in
                guard progress.phase == .inspecting, progress.completedItems == 1 else { return }
                started.signal()
                release.wait()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)

        await coordinator.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop preflight")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .cancelled)
        }
        XCTAssertEqual(temporaryItems(withPrefix: "CodexDirectorExport-"), before)
    }

    func testVerificationFailureLeavesNoDestinationOrPartialArchive() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let options = CapabilityPackageDiscovery(environment: environment(fixture: fixture)).options()
        let prepared = try await builder.prepare(selection: .defaults(for: options), progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try Data("tampered".utf8).write(
            to: prepared.directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let destination = fixture.output.appendingPathComponent("invalid.codexpack.zip")
        XCTAssertThrowsError(try CapabilityPackageArchiveWriter().write(
            prepared: prepared,
            to: destination,
            progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let outputNames = try FileManager.default.contentsOfDirectory(atPath: fixture.output.path)
        XCTAssertFalse(outputNames.contains { $0.hasPrefix(".CodexDirectorExport-") })
    }

    func testVerifiedPackageAtomicallyReplacesExistingDestination() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let destination = fixture.output.appendingPathComponent("existing.codexpack.zip")
        try Data("previous file".utf8).write(to: destination)

        _ = try await coordinator.writePreparedPackage(to: destination)
        try CapabilityPackageArchiveVerifier().verify(archiveURL: destination)
        let outputNames = try FileManager.default.contentsOfDirectory(atPath: fixture.output.path)
        XCTAssertFalse(outputNames.contains { $0.hasPrefix(".CodexDirectorExport-") })
    }

    func testSourceRaceIsDetectedAndArchivePathsRejectTraversal() async throws {
        let fixture = try makeFixture()
        let skillURL = fixture.home.appendingPathComponent(".codex/skills/local-skill/SKILL.md")
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            afterFileRead: { url in
                guard url.standardizedFileURL == skillURL.standardizedFileURL else { return }
                try? Data("changed-during-read".utf8).write(to: url)
            }
        )
        let options = CapabilityPackageDiscovery(environment: environment(fixture: fixture)).options()
        let prepared = try await builder.prepare(selection: .defaults(for: options), progress: nil)
        XCTAssertTrue(prepared.preview.issues.contains { $0.code == "source_changed_during_read" })

        let verifier = CapabilityPackageArchiveVerifier()
        XCTAssertFalse(verifier.isSafeArchivePath("../escape"))
        XCTAssertFalse(verifier.isSafeArchivePath("payload/../../escape"))
        XCTAssertFalse(verifier.isSafeArchivePath("/absolute"))
        XCTAssertFalse(verifier.isSafeArchivePath("payload\\escape"))
        XCTAssertTrue(verifier.isSafeArchivePath("payload/global/skills/demo/SKILL.md"))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let home: URL
        let project: URL
        let output: URL
        let secondHome: URL
        let secondProject: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try temporaryDirectory("fixture")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let secondHome = root.appendingPathComponent("restored-home", isDirectory: true)
        let secondProject = root.appendingPathComponent("restored-project", isDirectory: true)
        for directory in [home, project, output, secondHome, secondProject] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try write("developer_instructions = \"\(home.path)/.codex/agents/video-director/agent.md\"\n", to: home.appendingPathComponent(".codex/agents/video-director.toml"))
        try write("# Video Director\n", to: home.appendingPathComponent(".codex/agents/video-director/agent.md"))
        try write("# Global instructions\n", to: home.appendingPathComponent(".codex/AGENTS.md"))

        let localSkill = home.appendingPathComponent(".codex/skills/local-skill", isDirectory: true)
        try write("---\nname: local-skill\n---\nPath: \(localSkill.path)\n", to: localSkill.appendingPathComponent("SKILL.md"))
        let script = localSkill.appendingPathComponent("scripts/run.sh")
        try write("#!/bin/bash\necho safe\n", to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let image = localSkill.appendingPathComponent("assets/image.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        try FileManager.default.createSymbolicLink(
            atPath: localSkill.appendingPathComponent("assets/run-link").path,
            withDestinationPath: "../scripts/run.sh"
        )
        try write("ignored", to: localSkill.appendingPathComponent("cache/ignored.txt"))
        try write("---\nname: installed-skill\n---\n", to: home.appendingPathComponent(".agents/skills/installed-skill/SKILL.md"))
        try write("{}", to: home.appendingPathComponent(".agents/skills/installed-skill/_meta.json"))
        try write("---\nname: system-only\n---\n", to: home.appendingPathComponent(".codex/skills/.system/system-only/SKILL.md"))

        try write("developer_instructions = \"project agent\"\n", to: project.appendingPathComponent(".codex/agents/project-agent.toml"))
        try write("---\nname: project-skill\n---\n", to: project.appendingPathComponent(".agents/skills/project-skill/SKILL.md"))
        try write("# Project instructions\nProject: \(project.path)\n", to: project.appendingPathComponent("AGENTS.md"))
        return Fixture(root: root, home: home, project: project, output: output, secondHome: secondHome, secondProject: secondProject)
    }

    private func environment(fixture: Fixture) -> CapabilityExportEnvironment {
        CapabilityExportEnvironment(
            homeDirectory: fixture.home,
            projects: [CapabilityExportProjectSource(directory: fixture.project, displayName: "Fixture Project")],
            producer: CapabilityPackageProducer(version: "0.3.0", build: "15"),
            platform: CapabilityPackagePlatform(operatingSystem: "macOS", operatingSystemVersion: "26.0", architecture: "arm64")
        )
    }

    private func makeCoordinator(
        fixture: Fixture,
        pluginStatus: CapabilityPluginInventoryStatus = .complete
    ) -> CapabilityExportCoordinator {
        CapabilityExportCoordinator(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: pluginStatus),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-package-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func temporaryItems(withPrefix prefix: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func fileSnapshot(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(try hashItem(url)):\(date)"
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func restore(
        manifest: CapabilityPackageManifestV1,
        extractedRoot: URL,
        newHome: URL,
        projectMap: [String: URL]
    ) throws {
        for entry in manifest.entries {
            let source = extractedRoot.appendingPathComponent(entry.archivePath)
            let destination = restoredURL(for: entry, newHome: newHome, projectMap: projectMap)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.inspection == .validatedSymlink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes(
                    [.posixPermissions: entry.executable ? 0o755 : 0o644],
                    ofItemAtPath: destination.path
                )
            }
        }
    }

    private func restoredURL(for entry: CapabilityPackageEntry, newHome: URL, projectMap: [String: URL]) -> URL {
        if entry.logicalRoot.hasPrefix("{{HOME}}") {
            let suffix = String(entry.logicalRoot.dropFirst("{{HOME}}".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return newHome.appendingPathComponent(suffix).appendingPathComponent(entry.relativePath)
        }
        let prefix = "{{PROJECT:"
        let end = entry.logicalRoot.firstIndex(of: "}")!
        let projectID = String(entry.logicalRoot[entry.logicalRoot.index(entry.logicalRoot.startIndex, offsetBy: prefix.count)..<end])
        let root = projectMap[projectID]!
        let token = "{{PROJECT:\(projectID)}}"
        let suffix = String(entry.logicalRoot.dropFirst(token.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.appendingPathComponent(suffix).appendingPathComponent(entry.relativePath)
    }

    private func hashItem(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let data: Data
        if values.isSymbolicLink == true {
            data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        } else {
            data = try Data(contentsOf: url)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
