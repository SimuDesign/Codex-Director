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

    private struct InstalledReader: CodexInstalledPluginInventoryReading {
        let result: CodexInstalledPluginInventory
        func read() async throws -> CodexInstalledPluginInventory { result }
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

    func testDanglingInternalLinkIsBlockedBeforePackageCanBeRestored() async throws {
        try await assertUnrestorableLinkIsBlocked(target: "../assets/missing.txt", name: "dangling-link")
    }

    func testLinkToExcludedContentIsBlockedBeforePackageCanBeRestored() async throws {
        try await assertUnrestorableLinkIsBlocked(target: "../cache/ignored.txt", name: "excluded-link")
    }

    private func assertUnrestorableLinkIsBlocked(target: String, name: String) async throws {
        let fixture = try makeFixture()
        let link = fixture.home.appendingPathComponent(".codex/skills/local-skill/assets/\(name)")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        // Exercise the complete builder -> ZIP -> restore path while this is
        // still accepted, so the regression covers a real unreadable package.
        if !prepared.preview.hasBlockingIssues {
            let archive = fixture.output.appendingPathComponent("unrestorable.codexpack.zip")
            _ = try CapabilityPackageArchiveWriter().write(
                prepared: prepared, to: archive, progressHandler: nil,
                cancellation: CapabilityExportCancellation()
            )
            let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.secondHome)
            let info = try await restore.openPackage(at: archive, trustedSource: true)
            let skillID = try XCTUnwrap(info.manifest.capabilities.first {
                $0.id == "global:skill:codex:local-skill"
            }?.id)
            let restoreSelection = CapabilityRestoreSelection(includedCapabilityIDs: [skillID])
            _ = try await restore.preview(selection: restoreSelection)
            do {
                _ = try await restore.restore(selection: restoreSelection)
                XCTFail("Unrestorable link unexpectedly survived restore")
            } catch {
                // The export preflight must now stop this before a ZIP is made.
            }
        }
        XCTAssertTrue(prepared.preview.issues.contains {
            $0.code == "unrestorable_symlink" && $0.severity == .blocking
        })
    }

    func testUnknownExportProjectIsRejectedBeforeSourceCollection() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        var selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        selection.projects.append(CapabilityExportProjectSelection(projectID: "project-unknown", includeSkills: true))
        do {
            _ = try await coordinator.prepare(selection: selection)
            XCTFail("Unknown project must fail closed")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .invalidSelection)
        }
    }

    func testRepeatedExportProjectIsRejectedWithoutCreatingStaging() async throws {
        let fixture = try makeFixture()
        let prefix = "CodexDirectorInvalidSelection-"
        let coordinator = makeCoordinator(fixture: fixture, stagingPrefix: prefix)
        var selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let first = try XCTUnwrap(selection.projects.first)
        selection.projects.append(CapabilityExportProjectSelection(
            projectID: first.projectID, includeSkills: true
        ))
        let before = temporaryItems(withPrefix: prefix)
        do {
            _ = try await coordinator.prepare(selection: selection)
            XCTFail("Repeated project ID must fail closed")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .invalidSelection)
        }
        XCTAssertEqual(temporaryItems(withPrefix: prefix), before)
    }

    func testArchiveLimitsRejectSmallSyntheticPackageAndLeaveDestinationClean() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let archive = fixture.output.appendingPathComponent("small.codexpack.zip")
        _ = try CapabilityPackageArchiveWriter().write(
            prepared: prepared, to: archive, progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        )
        let archiveHash = try hashItem(archive)

        var policies = [CapabilityPackageLimits]()
        var entryLimit = CapabilityPackageLimits()
        entryLimit.maxEntries = 1
        policies.append(entryLimit)
        var fileLimit = CapabilityPackageLimits()
        fileLimit.maxRegularFileBytes = 1
        policies.append(fileLimit)
        var metadataLimit = CapabilityPackageLimits()
        metadataLimit.maxMetadataFileBytes = 1
        policies.append(metadataLimit)
        var totalLimit = CapabilityPackageLimits()
        totalLimit.maxTotalExpandedBytes = 1
        policies.append(totalLimit)
        var archiveLimit = CapabilityPackageLimits()
        archiveLimit.maxArchiveBytes = 1
        policies.append(archiveLimit)

        for (index, limits) in policies.enumerated() {
            let extraction = fixture.output.appendingPathComponent("rejected-\(index)")
            XCTAssertThrowsError(try CapabilityPackageArchiveVerifier(limits: limits).verify(
                archiveURL: archive, extractionDirectory: extraction
            )) { error in
                XCTAssertEqual(error as? CapabilityExportError, .resourceLimitExceeded)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
            XCTAssertEqual(try hashItem(archive), archiveHash)
        }
    }

    func testBuilderUsesSameSmallMetadataLimitAsVerifier() async throws {
        let fixture = try makeFixture()
        var limits = CapabilityPackageLimits()
        limits.maxMetadataFileBytes = 1
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            limits: limits
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        XCTAssertTrue(prepared.preview.issues.contains {
            $0.code == "package_resource_limit" && $0.severity == .blocking
        })
    }

    func testVerifierRejectsOversizedLocalSymlinkHeaderWithoutLeavingExtraction() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let original = fixture.output.appendingPathComponent("original.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: original)
        var bytes = [UInt8](try Data(contentsOf: original))
        let signature: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
        var changed = false
        for offset in 0..<(bytes.count - 30) where Array(bytes[offset..<(offset + 4)]) == signature {
            let nameLength = Int(bytes[offset + 26]) | Int(bytes[offset + 27]) << 8
            guard offset + 30 + nameLength <= bytes.count else { continue }
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            guard name.hasSuffix("assets/run-link") else { continue }
            for index in (offset + 18)..<(offset + 22) { bytes[index] = 0xff }
            changed = true
            break
        }
        XCTAssertTrue(changed)
        let malformed = fixture.output.appendingPathComponent("malformed.codexpack.zip")
        try Data(bytes).write(to: malformed)
        let extraction = fixture.output.appendingPathComponent("malformed-extraction")
        XCTAssertThrowsError(try CapabilityPackageArchiveVerifier().verify(
            archiveURL: malformed, extractionDirectory: extraction
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testVerifierCountsActualDecompressedBytesWhenHeaderUnderstatesSize() async throws {
        let fixture = try makeFixture()
        let oversized = fixture.home.appendingPathComponent(".codex/skills/local-skill/assets/oversized.bin")
        try Data(repeating: 0xa5, count: 2_048).write(to: oversized)
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let original = fixture.output.appendingPathComponent("actual.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: original)
        var bytes = [UInt8](try Data(contentsOf: original))
        var changed = false
        for offset in 0..<(bytes.count - 46)
        where Array(bytes[offset..<(offset + 4)]) == [0x50, 0x4b, 0x01, 0x02] {
            let nameLength = Int(bytes[offset + 28]) | Int(bytes[offset + 29]) << 8
            guard offset + 46 + nameLength <= bytes.count else { continue }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            guard name.hasSuffix("assets/oversized.bin") else { continue }
            bytes[offset + 24] = 1
            for index in (offset + 25)..<(offset + 28) { bytes[index] = 0 }
            changed = true
            break
        }
        XCTAssertTrue(changed)
        let forged = fixture.output.appendingPathComponent("understated.codexpack.zip")
        try Data(bytes).write(to: forged)
        var limits = CapabilityPackageLimits()
        limits.maxRegularFileBytes = 1_024
        let extraction = fixture.output.appendingPathComponent("understated-extraction")
        XCTAssertThrowsError(try CapabilityPackageArchiveVerifier(limits: limits).verify(
            archiveURL: forged, extractionDirectory: extraction
        )) { error in
            XCTAssertEqual(error as? CapabilityExportError, .resourceLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testVerifierLeavesPreexistingExtractionContentsUntouched() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)
        let extraction = fixture.output.appendingPathComponent("occupied", isDirectory: true)
        let sentinel = extraction.appendingPathComponent("keep.txt")
        try write("keep", to: sentinel)
        XCTAssertThrowsError(try CapabilityPackageArchiveVerifier().verify(
            archiveURL: archive, extractionDirectory: extraction
        ))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testVerifierDoesNotPublishThroughSwappedExtractionRoot() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)

        let extraction = fixture.output.appendingPathComponent("existing", isDirectory: true)
        let displaced = fixture.output.appendingPathComponent("displaced", isDirectory: true)
        let outside = fixture.output.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        try write("foreign", to: outside.appendingPathComponent("keep.txt"))
        let verifier = CapabilityPackageArchiveVerifier(limits: CapabilityPackageLimits()) { _ in
            try? FileManager.default.moveItem(at: extraction, to: displaced)
            try? FileManager.default.createSymbolicLink(atPath: extraction.path, withDestinationPath: outside.path)
        }
        XCTAssertThrowsError(try verifier.verify(archiveURL: archive, extractionDirectory: extraction))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8), "foreign")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: displaced.path).isEmpty)
    }

    func testVerifierDoesNotOverwriteNewOrAddedExtractionContent() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)

        for existedInitially in [false, true] {
            let extraction = fixture.output.appendingPathComponent("occupied-\(existedInitially)", isDirectory: true)
            if existedInitially {
                try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            }
            let sentinel = extraction.appendingPathComponent("keep.txt")
            let verifier = CapabilityPackageArchiveVerifier(limits: CapabilityPackageLimits()) { _ in
                try? FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
                try? Data("foreign".utf8).write(to: sentinel)
            }
            XCTAssertThrowsError(try verifier.verify(archiveURL: archive, extractionDirectory: extraction))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "foreign")
            XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.appendingPathComponent("payload").path))
        }
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

    func testRuntimePluginListWithStderrIsMarkedIncompleteDespiteSuccessExit() async {
        let json = #"{"installed":[{"name":"partial","installed":true,"enabled":true}],"available":[]}"#
        let provider = RuntimeCapabilityPluginInventoryProvider(commandClient: CommandClient(
            result: RuntimeCommandResult(stdout: json, exitCode: 0, timedOut: false, hadStderrOutput: true)
        ))
        let inventory = await provider.inventory(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(inventory.status, .incomplete)
        XCTAssertTrue(inventory.plugins.isEmpty)
        XCTAssertEqual(inventory.issue, "plugin_query_failed")
    }

    func testAppServerPluginInventoryUsesSameCompletenessGateAndDropsSourcePath() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let installed = CodexInstalledPlugin(
            id: "figma@remote-catalog", name: "figma", marketplace: "remote-catalog",
            version: "3.0.0", enabled: true, sourcePath: "/synthetic/private-package"
        )
        let completeProvider = RuntimeCapabilityPluginInventoryProvider(installedPluginReading:
            InstalledReader(result: .init(plugins: [installed], isComplete: true))
        )
        let complete = await completeProvider.inventory(at: date)
        XCTAssertEqual(complete.status, .complete)
        XCTAssertEqual(complete.plugins.map(\.identifier), ["figma@remote-catalog"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(complete), as: UTF8.self).contains("/synthetic/private-package"))

        let partialProvider = RuntimeCapabilityPluginInventoryProvider(installedPluginReading:
            InstalledReader(result: .init(plugins: [installed], isComplete: false, issue: "plugin_remote_unverified"))
        )
        let partial = await partialProvider.inventory(at: date)
        XCTAssertEqual(partial.status, .incomplete)
        XCTAssertEqual(partial.issue, "plugin_remote_unverified")
        XCTAssertEqual(partial.plugins.map(\.identifier), ["figma@remote-catalog"])
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
        let stagingPrefix = "CodexDirectorCancellation-"
        let coordinator = makeCoordinator(fixture: fixture, stagingPrefix: stagingPrefix)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let before = temporaryItems(withPrefix: stagingPrefix)
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
        XCTAssertEqual(temporaryItems(withPrefix: stagingPrefix), before)
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

    func testWriterCleanupPreservesReplacementStagingDirectory() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let displaced = fixture.output.appendingPathComponent("displaced-staging", isDirectory: true)
        let marker = fixture.output.appendingPathComponent("staging-path.txt")
        let writer = CapabilityPackageArchiveWriter(afterPackaging: { staging in
            try? Data(staging.path.utf8).write(to: marker)
            try? FileManager.default.moveItem(at: staging, to: displaced)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try? Data("foreign".utf8).write(to: staging.appendingPathComponent("keep.txt"))
        })
        let destination = fixture.output.appendingPathComponent("rejected.codexpack.zip")
        XCTAssertThrowsError(try writer.write(
            prepared: prepared, to: destination, progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        ))
        let staging = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("keep.txt"), encoding: .utf8), "foreign")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: staging)
    }

    func testWriterNeverPublishesPackageTmpSwappedAfterVerification() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let displaced = fixture.output.appendingPathComponent("verified-original.zip")
        let destination = fixture.output.appendingPathComponent("existing.codexpack.zip")
        try Data("previous".utf8).write(to: destination)
        let writer = CapabilityPackageArchiveWriter(afterVerification: { temporary in
            try? FileManager.default.moveItem(at: temporary, to: displaced)
            try? Data("foreign".utf8).write(to: temporary)
        })
        XCTAssertThrowsError(try writer.write(
            prepared: prepared, to: destination, progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
        let quarantine = try FileManager.default.contentsOfDirectory(
            at: fixture.output, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".CodexDirectorOwnedCleanup-") }
        let retained = try XCTUnwrap(quarantine)
        XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("package.tmp"), encoding: .utf8), "foreign")
        try FileManager.default.removeItem(at: retained)
    }

    func testWriterPreservesDestinationCreatedDuringVerification() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let destination = fixture.output.appendingPathComponent("appeared.codexpack.zip")
        let writer = CapabilityPackageArchiveWriter(afterVerification: { _ in
            try? Data("foreign".utf8).write(to: destination)
        })
        XCTAssertThrowsError(try writer.write(
            prepared: prepared, to: destination, progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "foreign")
    }

    func testWriterPreservesExistingDestinationReplacedDuringVerification() async throws {
        let fixture = try makeFixture()
        let builder = CapabilityPackageBuilder(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: .complete),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let selection = CapabilityExportSelection.defaults(for: CapabilityPackageDiscovery(
            environment: environment(fixture: fixture)
        ).options())
        let prepared = try await builder.prepare(selection: selection, progress: nil)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let destination = fixture.output.appendingPathComponent("existing.codexpack.zip")
        let moved = fixture.output.appendingPathComponent("original-destination.zip")
        try Data("previous".utf8).write(to: destination)
        let writer = CapabilityPackageArchiveWriter(afterVerification: { _ in
            try? FileManager.default.moveItem(at: destination, to: moved)
            try? Data("foreign".utf8).write(to: destination)
        })
        XCTAssertThrowsError(try writer.write(
            prepared: prepared, to: destination, progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "foreign")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "previous")
    }

    func testConvenienceVerifierCleanupPreservesReplacementDirectory() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)
        let displaced = fixture.output.appendingPathComponent("displaced-verification", isDirectory: true)
        let marker = fixture.output.appendingPathComponent("verification-path.txt")
        let verifier = CapabilityPackageArchiveVerifier(
            limits: CapabilityPackageLimits(),
            beforeTemporaryCleanup: { extraction in
                try? Data(extraction.path.utf8).write(to: marker)
                try? FileManager.default.moveItem(at: extraction, to: displaced)
                try? FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
                try? Data("foreign".utf8).write(to: extraction.appendingPathComponent("keep.txt"))
            }
        )
        try verifier.verify(archiveURL: archive)
        let extraction = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        XCTAssertEqual(try String(contentsOf: extraction.appendingPathComponent("keep.txt"), encoding: .utf8), "foreign")
        try FileManager.default.removeItem(at: extraction)
    }

    func testConvenienceVerifierRemovesItsOwnedDirectoryAfterSuccess() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)
        let marker = fixture.output.appendingPathComponent("verification-path.txt")
        let verifier = CapabilityPackageArchiveVerifier(
            limits: CapabilityPackageLimits(),
            beforeTemporaryCleanup: { extraction in
                try? Data(extraction.path.utf8).write(to: marker)
            }
        )
        try verifier.verify(archiveURL: archive)
        let extraction = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testVerifierCleanupNeverRecursesIntoSwappedQuarantineName() async throws {
        let fixture = try makeFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let selection = CapabilityExportSelection.defaults(for: try await coordinator.options())
        let preview = try await coordinator.prepare(selection: selection)
        XCTAssertFalse(preview.hasBlockingIssues)
        let archive = fixture.output.appendingPathComponent("fixture.codexpack.zip")
        _ = try await coordinator.writePreparedPackage(to: archive)
        let displaced = fixture.output.appendingPathComponent("owned-displaced", isDirectory: true)
        let marker = fixture.output.appendingPathComponent("quarantine-path.txt")
        let verifier = CapabilityPackageArchiveVerifier(
            limits: CapabilityPackageLimits(),
            afterTemporaryQuarantine: { quarantine in
                try? Data(quarantine.path.utf8).write(to: marker)
                try? FileManager.default.moveItem(at: quarantine, to: displaced)
                try? FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
                try? Data("foreign".utf8).write(to: quarantine.appendingPathComponent("keep.txt"))
            }
        )
        try verifier.verify(archiveURL: archive)
        let quarantine = URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        XCTAssertEqual(try String(contentsOf: quarantine.appendingPathComponent("keep.txt"), encoding: .utf8), "foreign")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("manifest.json").path))
        try FileManager.default.removeItem(at: quarantine)
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
        pluginStatus: CapabilityPluginInventoryStatus = .complete,
        stagingPrefix: String = "CodexDirectorExport-"
    ) -> CapabilityExportCoordinator {
        CapabilityExportCoordinator(
            environment: environment(fixture: fixture),
            pluginProvider: PluginProvider(status: pluginStatus),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            stagingPrefix: stagingPrefix
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
