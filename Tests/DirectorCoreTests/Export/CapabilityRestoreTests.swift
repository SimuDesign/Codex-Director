import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import DirectorCore

final class CapabilityRestoreTests: XCTestCase {
    private actor AsyncWriteGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func pause() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private final class CleanupReplacementRace: @unchecked Sendable {
        let movedName = ".user-moved-\(UUID().uuidString)"
        private let replacement: Data
        private let lock = NSLock()
        private var ran = false

        init(replacement: Data) { self.replacement = replacement }

        func replaceIsolatedName(parent: Int32, isolatedName: String) throws {
            lock.lock()
            guard !ran else { lock.unlock(); return }
            ran = true
            lock.unlock()
            guard Darwin.renameatx_np(
                parent,
                isolatedName,
                parent,
                movedName,
                UInt32(RENAME_EXCL)
            ) == 0 else { throw CapabilityRestoreError.writeFailed }
            let descriptor = Darwin.openat(
                parent,
                isolatedName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o644)
            )
            guard descriptor >= 0 else { throw CapabilityRestoreError.writeFailed }
            defer { Darwin.close(descriptor) }
            try replacement.withUnsafeBytes { bytes in
                guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
                    throw CapabilityRestoreError.writeFailed
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw CapabilityRestoreError.writeFailed }
        }
    }

    private final class SymlinkIdentityRace: @unchecked Sendable {
        let movedName = ".symlink-original-\(UUID().uuidString)"
        private let replacementTarget: String
        private let lock = NSLock()
        private var ran = false
        private var replacedNameStorage: String?

        init(replacementTarget: String) {
            self.replacementTarget = replacementTarget
        }

        func replace(parent: Int32, name: String) throws {
            lock.lock()
            guard !ran else { lock.unlock(); return }
            ran = true
            replacedNameStorage = name
            lock.unlock()
            guard Darwin.renameatx_np(
                parent,
                name,
                parent,
                movedName,
                UInt32(RENAME_EXCL)
            ) == 0 else { throw CapabilityRestoreError.writeFailed }
            guard Darwin.symlinkat(replacementTarget, parent, name) == 0 else {
                throw CapabilityRestoreError.writeFailed
            }
        }

        var replacedName: String? {
            lock.lock()
            defer { lock.unlock() }
            return replacedNameStorage
        }
    }

    private enum SymlinkIdentityRacePhase: Equatable {
        case pathStatToOpen
        case beforePublish
        case afterPublish
    }

    private struct PluginProvider: CapabilityPluginInventoryProviding {
        func inventory(at date: Date) async -> CapabilityPackagePluginList {
            CapabilityPackagePluginList(
                status: .complete,
                generatedAt: date,
                plugins: [CapabilityPackagePlugin(
                    identifier: "fixture-plugin",
                    name: "Fixture Plugin",
                    marketplace: "fixture-market",
                    version: "1.0.0",
                    enabled: true
                )]
            )
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let project: URL
        let archive: URL
        let restoredHome: URL
        let restoredProject: URL
    }

    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testTrustedPackageRestoresGlobalAndProjectCapabilitiesAndSupportsUndo() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        XCTAssertEqual(info.manifest.formatVersion, 1)
        XCTAssertEqual(info.packageFileName, fixture.archive.lastPathComponent)
        XCTAssertEqual(info.plugins.plugins.map(\.name), ["Fixture Plugin"])
        XCTAssertTrue(info.requirements.requirements.contains { $0.name == "Codex" })

        let projectID = try XCTUnwrap(info.manifest.projects.first?.id)
        let selection = CapabilityRestoreSelection(
            includedCapabilityIDs: Set(info.manifest.capabilities.map(\.id)),
            projectMappings: [CapabilityRestoreProjectMapping(
                packageProjectID: projectID,
                destinationURL: fixture.restoredProject
            )]
        )
        let preview = try await restore.preview(selection: selection)
        XCTAssertGreaterThan(preview.createCount, 0)
        XCTAssertEqual(preview.conflictCount, 0)
        XCTAssertFalse(preview.hasBlockingIssues)

        let result = try await restore.restore(selection: selection)
        XCTAssertGreaterThan(result.createdCount, 0)
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertTrue(result.rescanRequired)
        XCTAssertFalse(result.quarantineLocations.isEmpty)

        let manifest = info.manifest
        for entry in manifest.entries {
            let destination = restoredURL(
                for: entry,
                home: fixture.restoredHome,
                project: fixture.restoredProject
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), entry.archivePath)
            XCTAssertEqual(try hashItem(destination), entry.sha256, entry.archivePath)
            if entry.inspection != .validatedSymlink {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                XCTAssertEqual(permissions & 0o111 != 0, entry.executable, entry.archivePath)
            }
        }

        let secondPreview = try await restore.preview(selection: selection)
        XCTAssertEqual(secondPreview.createCount, 0)
        XCTAssertEqual(secondPreview.skipCount, manifest.entries.count)
        XCTAssertFalse(secondPreview.hasBlockingIssues)

        let rollback = try await restore.rollbackLastOperation()
        XCTAssertEqual(rollback.skippedModifiedCount, 0)
        XCTAssertEqual(rollback.removedCount, 0)
        XCTAssertEqual(rollback.quarantinedCount, result.createdCount)
        XCTAssertFalse(rollback.quarantineLocations.isEmpty)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_preserved_isolated" })
        XCTAssertTrue(rollback.quarantineLocations.allSatisfy {
            $0.placeholder.hasPrefix("<restore-quarantine-")
                && !$0.placeholder.contains(fixture.restoredHome.path)
                && !$0.placeholder.contains(fixture.restoredProject.path)
        })
        XCTAssertFalse(rollback.issues.contains {
            $0.message.contains(fixture.restoredHome.path)
                || $0.message.contains(fixture.restoredProject.path)
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md").path
        ))
    }

    func testExistingDifferentFileBlocksAtomicCapabilityWithoutOverwriting() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let projectID = try XCTUnwrap(info.manifest.projects.first?.id)
        let skillID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil }?.id)
        let selection = CapabilityRestoreSelection(
            includedCapabilityIDs: [skillID],
            projectMappings: [CapabilityRestoreProjectMapping(
                packageProjectID: projectID,
                destinationURL: fixture.restoredProject
            )]
        )
        let destination = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-owned content".utf8).write(to: destination)

        let preview = try await restore.preview(selection: selection)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertTrue(preview.issues.contains { $0.code == "target_conflict" })
        XCTAssertTrue(preview.issues.contains { $0.code == "capability_conflict" })

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("Conflicting capability must not be written")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .conflictsRemain)
            XCTAssertFalse(failure.cleanup.hasResidualItems)
            XCTAssertTrue(failure.cleanup.quarantineLocations.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("user-owned content".utf8))
    }

    func testUntrustedSourceAndDuplicateProjectDestinationAreRejected() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        do {
            _ = try await restore.openPackage(at: fixture.archive, trustedSource: false)
            XCTFail("Untrusted package must not be opened")
        } catch {
            XCTAssertEqual(error as? CapabilityRestoreError, .untrustedSource)
        }
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let projectID = try XCTUnwrap(info.manifest.projects.first?.id)
        let projectSelection = CapabilityRestoreSelection(
            includedCapabilityIDs: Set(info.manifest.capabilities.map(\.id)),
            projectMappings: [
                CapabilityRestoreProjectMapping(packageProjectID: projectID, destinationURL: fixture.restoredProject),
                CapabilityRestoreProjectMapping(packageProjectID: projectID, destinationURL: fixture.restoredProject)
            ]
        )
        do {
            _ = try await restore.preview(selection: projectSelection)
            XCTFail("Duplicate project mappings must be rejected")
        } catch {
            XCTAssertEqual(error as? CapabilityRestoreError, .duplicateProjectMapping)
        }
    }

    func testExistingAgentsFileIsAlwaysAConflict() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture, includeProjectInstructions: true)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let projectID = try XCTUnwrap(info.manifest.projects.first?.id)
        let selection = CapabilityRestoreSelection(
            includedCapabilityIDs: Set(info.manifest.capabilities.map(\.id)),
            projectMappings: [CapabilityRestoreProjectMapping(
                packageProjectID: projectID,
                destinationURL: fixture.restoredProject
            )]
        )
        let agentsFile = fixture.restoredProject.appendingPathComponent("AGENTS.md")
        try write("same bytes are still a manual decision\n", to: agentsFile)
        let preview = try await restore.preview(selection: selection)
        XCTAssertTrue(preview.issues.contains { $0.code == "agents_file_exists" })
        XCTAssertTrue(preview.hasBlockingIssues)
    }

    func testExportAndRestoreShareTheApplicationMigrationLock() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let gate = CapabilityMigrationGate()
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, migrationGate: gate)
        _ = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let exporter = CapabilityExportCoordinator(
            environment: environment(for: fixture),
            pluginProvider: PluginProvider(),
            migrationGate: gate
        )
        do {
            _ = try await exporter.options()
            XCTFail("Restore must exclude a concurrent export operation")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .operationInProgress)
        }
        await restore.discard()
        _ = try await exporter.options()
    }

    func testSymlinkedDestinationRootIsRejectedBeforeWrite() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.restoredHome.appendingPathComponent(".codex").path,
            withDestinationPath: outside.path
        )

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skillID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil }?.id)
        do {
            _ = try await restore.preview(selection: CapabilityRestoreSelection(includedCapabilityIDs: [skillID]))
            XCTFail("A symlinked approved root must not redirect restore writes")
        } catch {
            XCTAssertEqual(error as? CapabilityRestoreError, .unsafeArchivePath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("skills").path))
    }

    func testCancellationBeforeWriteLeavesDestinationUntouched() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let projectID = try XCTUnwrap(info.manifest.projects.first?.id)
        let selection = CapabilityRestoreSelection(
            includedCapabilityIDs: Set(info.manifest.capabilities.map(\.id)),
            projectMappings: [CapabilityRestoreProjectMapping(
                packageProjectID: projectID,
                destinationURL: fixture.restoredProject
            )]
        )
        _ = try await restore.preview(selection: selection)
        let started = expectation(description: "restore started")
        let restoreTask = Task {
            try await restore.restore(selection: selection) { progress in
                if progress.phase == .restoring, progress.completedItems == 0 {
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        await restore.cancel()
        do {
            _ = try await restoreTask.value
            XCTFail("Cancellation must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertFalse(failure.cleanup.quarantineLocations.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.restoredHome.appendingPathComponent(".codex").path
        ))
    }

    func testConflictPreviewProvidesCappedRedactedTextDiffAndBinaryMetadataOnly() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skillID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil }?.id)
        let skillRoot = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try Data("private source at /Users/test/work\n".utf8).write(to: skillRoot.appendingPathComponent("SKILL.md"))
        try Data([0xff, 0x00, 0x7f]).write(to: skillRoot.appendingPathComponent("asset.bin"))

        let preview = try await restore.preview(selection: CapabilityRestoreSelection(includedCapabilityIDs: [skillID]))
        let text = try XCTUnwrap(preview.entries.first { $0.displayPath.hasSuffix("SKILL.md") })
        let difference = try XCTUnwrap(text.difference)
        XCTAssertLessThanOrEqual(difference.count, 4_000)
        XCTAssertFalse(difference.contains("/Users/test"))
        XCTAssertTrue(difference.contains("{{USER_PATH}}") || difference.contains("[REDACTED]"))

        let binary = try XCTUnwrap(preview.entries.first { $0.displayPath.hasSuffix("asset.bin") })
        XCTAssertEqual(binary.action, .conflict)
        XCTAssertNil(binary.difference)
        XCTAssertEqual(binary.sha256.count, 64)
        XCTAssertFalse(binary.contentType.isEmpty)
    }

    func testParentDirectoryReplacementRaceCannotWriteOutsideApprovedRoot() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let skillsRoot = fixture.restoredHome.appendingPathComponent(".codex/skills", isDirectory: true)
        let displaced = fixture.restoredHome.appendingPathComponent(".codex/skills-original", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let hooks = CapabilityRestoreTestHooks(beforeWrite: { _, index in
            guard index == 0 else { return }
            try FileManager.default.moveItem(at: skillsRoot, to: displaced)
            try FileManager.default.createSymbolicLink(atPath: skillsRoot.path, withDestinationPath: outside.path)
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skillID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skillID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("A replaced parent directory must stop the restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .targetChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("portable-skill").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testAutomaticFailureReportsQuarantineMoveFailureInsteadOfSwallowingIt() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(
            beforeWrite: { _, index in
                if index == 1 { throw CapabilityRestoreError.writeFailed }
            },
            shouldFailCleanup: { !$0.contains("[directory:") }
        )
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("Injected failure must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .writeFailed)
            XCTAssertGreaterThan(failure.cleanup.failedRemovalCount, 0)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertTrue(failure.cleanup.issues.contains { $0.code == "cleanup_quarantine_move_failed" })
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.restoredHome.appendingPathComponent(".codex/agents").path).isEmpty)
    }

    func testAutomaticRollbackPreservesAndReportsConcurrentModification() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        let discoveryRestore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let discoveryInfo = try await discoveryRestore.openPackage(at: fixture.archive, trustedSource: true)
        let agent = try XCTUnwrap(discoveryInfo.manifest.capabilities.first { $0.kind == "agent" })
        let firstEntry = try XCTUnwrap(discoveryInfo.manifest.entries.filter { agent.files.contains($0.archivePath) }.sorted { $0.archivePath < $1.archivePath }.first)
        let firstDestination = restoredURL(for: firstEntry, home: fixture.restoredHome, project: fixture.restoredProject)
        await discoveryRestore.discard()

        let hooks = CapabilityRestoreTestHooks(beforeWrite: { _, index in
            guard index == 1 else { return }
            try Data("concurrent user modification\n".utf8).write(to: firstDestination)
            throw CapabilityRestoreError.writeFailed
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let restoredAgentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [restoredAgentID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("Injected failure must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .writeFailed)
            XCTAssertGreaterThan(failure.cleanup.skippedModifiedCount, 0)
            XCTAssertTrue(failure.cleanup.issues.contains { $0.code == "cleanup_target_modified" })
        }
        XCTAssertEqual(try String(contentsOf: firstDestination, encoding: .utf8), "concurrent user modification\n")
    }

    func testUndoPreservesChangedRestoredFileAndReportsResidual() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)
        let changedEntry = try XCTUnwrap(info.manifest.entries.first { skill.files.contains($0.archivePath) && $0.relativePath.hasSuffix("SKILL.md") })
        let changedURL = restoredURL(for: changedEntry, home: fixture.restoredHome, project: fixture.restoredProject)
        try Data("user changed after restore\n".utf8).write(to: changedURL)

        let rollback = try await restore.rollbackLastOperation()
        XCTAssertGreaterThan(rollback.skippedModifiedCount, 0)
        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_target_modified" })
        XCTAssertEqual(try String(contentsOf: changedURL, encoding: .utf8), "user changed after restore\n")
    }

    func testUndoReportsQuarantineMoveFailureWithoutDeletingUnverifiedItems() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(shouldFailCleanup: { !$0.contains("[directory:") })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)

        let rollback = try await restore.rollbackLastOperation()
        XCTAssertGreaterThan(rollback.failedRemovalCount, 0)
        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_quarantine_move_failed" })
    }

    func testFinalVerificationToQuarantineRenameReplacementIsRestoredWithoutDeletion() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let replacement = Data("replacement written during cleanup\n".utf8)
        let race = CleanupReplacementRace(replacement: replacement)
        let hooks = CapabilityRestoreTestHooks(immediatelyBeforeQuarantineRename: { displayPath, parent, isolatedName in
            guard displayPath.hasSuffix("/SKILL.md") else { return }
            try race.replaceIsolatedName(parent: parent, isolatedName: isolatedName)
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)

        let skillURL = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        let movedOriginal = skillURL.deletingLastPathComponent().appendingPathComponent(race.movedName)
        let rollback = try await restore.rollbackLastOperation()

        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertGreaterThan(rollback.skippedModifiedCount, 0)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_target_changed" })
        XCTAssertEqual(try Data(contentsOf: skillURL), replacement, "The replacement must be returned, never unlinked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedOriginal.path), "The originally created object must also remain recoverable")
    }

    func testUndoReportsMovedCreatedObjectAsResidualInsteadOfTreatingENOENTAsSuccess() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)
        let original = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        let moved = original.deletingLastPathComponent().appendingPathComponent("renamed-by-user.md")
        try FileManager.default.moveItem(at: original, to: moved)

        let rollback = try await restore.rollbackLastOperation()

        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertGreaterThan(rollback.skippedModifiedCount, 0)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_target_missing" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testRelativeSymlinkTargetCannotTraverseExistingSymlinkDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-restore-symlink-target-\(UUID().uuidString)", isDirectory: true)
        roots.append(rootURL)
        let parent = rootURL.appendingPathComponent(".codex/skills/demo", isDirectory: true)
        let outside = rootURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside\n".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(
            atPath: parent.appendingPathComponent("inside").path,
            withDestinationPath: outside.path
        )
        let source = rootURL.appendingPathComponent("source-link")
        let target = "inside/file"
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: target)
        let entry = CapabilityPackageEntry(
            archivePath: "payload/demo/latest",
            logicalRoot: "{{HOME}}/.codex/skills",
            relativePath: "demo/latest",
            byteSize: Int64(target.utf8.count),
            sha256: SHA256.hash(data: Data(target.utf8)).map { String(format: "%02x", $0) }.joined(),
            executable: false,
            contentType: "public.symlink",
            inspection: .validatedSymlink
        )
        let destination = CapabilityRestoreSecureDestination(
            anchorURL: rootURL,
            components: [".codex", "skills", "demo", "latest"],
            capabilityRootComponentCount: 3,
            displayPath: "{{HOME}}/.codex/skills/demo/latest"
        )
        let identity = try CapabilityRestoreSecureFileSystem.anchorIdentity(at: rootURL)
        let root = try CapabilityRestoreSecureFileSystem.openRoot(at: rootURL, expectedIdentity: identity)
        let quarantine = try makeQuarantine(for: root)
        var created: [CapabilityRestoreSecureJournalItem] = []

        XCTAssertThrowsError(try CapabilityRestoreSecureFileSystem().write(
            source: source,
            entry: entry,
            destination: destination,
            root: root,
            quarantine: quarantine,
            hooks: .none,
            created: &created
        )) { error in
            XCTAssertEqual(error as? CapabilityRestoreError, .unsafeArchivePath)
        }
        XCTAssertTrue(created.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("latest").path))
    }

    func testDiscardDuringSuspendedRestoreKeepsMigrationGateUntilCleanupFinishes() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let migrationGate = CapabilityMigrationGate()
        let writeGate = AsyncWriteGate()
        let hooks = CapabilityRestoreTestHooks(beforeWrite: { _, index in
            if index == 0 { await writeGate.pause() }
        })
        let restore = CapabilityRestoreCoordinator(
            homeDirectory: fixture.restoredHome,
            migrationGate: migrationGate,
            hooks: hooks
        )
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)
        let restoreTask = Task { try await restore.restore(selection: selection) }
        await writeGate.waitUntilEntered()

        await restore.discard()
        let exporter = CapabilityExportCoordinator(
            environment: environment(for: fixture),
            pluginProvider: PluginProvider(),
            migrationGate: migrationGate
        )
        do {
            _ = try await exporter.options()
            XCTFail("Deferred discard must not release the migration gate while restore is suspended")
        } catch {
            XCTAssertEqual(error as? CapabilityExportError, .operationInProgress)
        }

        await writeGate.release()
        do {
            _ = try await restoreTask.value
            XCTFail("Discard must cancel the suspended restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertFalse(failure.cleanup.quarantineLocations.isEmpty)
        }
        _ = try await exporter.options()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.restoredHome.appendingPathComponent(".codex").path))
    }

    func testPublishedObjectIsJournaledBeforePostPublishVerificationFailure() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(afterPublish: { _, isDirectory in
            if !isDirectory { throw CapabilityRestoreError.writeFailed }
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("The post-publish fault must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .writeFailed)
            XCTAssertGreaterThan(failure.cleanup.quarantinedCount, 0)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertTrue(failure.cleanup.issues.contains { $0.code == "cleanup_preserved_isolated" })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.restoredHome.appendingPathComponent(".codex").path))
    }

    func testRegularFileIsPreJournaledBeforePostCreateFault() async throws {
        try await assertPostCreateFault(
            kind: .regular,
            capabilityKind: "agent",
            logicalRelativePath: ".codex/agents/portable-agent.toml"
        )
    }

    func testDirectoryIsPreJournaledBeforePostCreateFault() async throws {
        try await assertPostCreateFault(
            kind: .directory,
            capabilityKind: "agent",
            logicalRelativePath: ".codex"
        )
    }

    func testSymbolicLinkIsPreJournaledBeforePostCreateFault() async throws {
        try await assertPostCreateFault(
            kind: .symbolicLink,
            capabilityKind: "skill",
            logicalRelativePath: ".codex/skills/portable-skill/latest.sh"
        )
    }

    func testSymlinkReplacementBetweenPathStatAndOpenIsNeverBoundOrPublished() async throws {
        try await assertSymlinkIdentityRace(.pathStatToOpen)
    }

    func testSymlinkReplacementBeforePublishIsNeverPublished() async throws {
        try await assertSymlinkIdentityRace(.beforePublish)
    }

    func testSymlinkReplacementAfterPublishIsDetectedAndPreserved() async throws {
        try await assertSymlinkIdentityRace(.afterPublish)
    }

    func testQuarantineNameCollisionPreservesLogicalObjectInPlace() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let collision = Data("preexisting quarantine collision\n".utf8)
        let hooks = CapabilityRestoreTestHooks(beforeQuarantineMove: { displayPath, _, _, quarantine, name in
            guard displayPath.hasSuffix("/SKILL.md") else { return }
            let descriptor = Darwin.openat(
                quarantine,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw CapabilityRestoreError.writeFailed }
            defer { Darwin.close(descriptor) }
            try collision.withUnsafeBytes { bytes in
                guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
                    throw CapabilityRestoreError.writeFailed
                }
            }
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)
        let logical = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        let expected = try Data(contentsOf: logical)

        let rollback = try await restore.rollbackLastOperation()

        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertGreaterThan(rollback.failedRemovalCount, 0)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_quarantine_move_failed" })
        XCTAssertEqual(try Data(contentsOf: logical), expected)
        XCTAssertFalse(rollback.quarantineLocations.isEmpty)
    }

    func testQuarantineDirectoryNameReplacementPreservesLogicalObjectInPlace() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        let result = try await restore.restore(selection: selection)
        let quarantine = try XCTUnwrap(result.quarantineLocations.first?.directoryURL)
        let movedQuarantine = quarantine.deletingLastPathComponent()
            .appendingPathComponent("moved-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: quarantine, to: movedQuarantine)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantine.path)
        let logical = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        let expected = try Data(contentsOf: logical)

        let rollback = try await restore.rollbackLastOperation()

        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertGreaterThan(rollback.failedRemovalCount, 0)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_quarantine_move_failed" })
        XCTAssertEqual(try Data(contentsOf: logical), expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedQuarantine.path))
    }

    func testQuarantinePreparationFailurePreventsEveryTargetWrite() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(shouldFailQuarantineCreation: { _ in true })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("Restore must not start when private quarantine cannot be prepared")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .destinationNotWritable)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertTrue(failure.cleanup.issues.contains { $0.code == "cleanup_quarantine_unavailable" })
            XCTAssertEqual(failure.cleanup.quarantinedCount, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.restoredHome.appendingPathComponent(".codex").path
        ))
    }

    func testQuarantinePermissionChangePreservesLogicalObjectInPlace() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(beforeQuarantineMove: { displayPath, _, _, quarantine, _ in
            guard displayPath.hasSuffix("/SKILL.md") else { return }
            guard Darwin.fchmod(quarantine, mode_t(0o500)) == 0 else {
                throw CapabilityRestoreError.writeFailed
            }
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "skill" && $0.projectID == nil })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)
        _ = try await restore.restore(selection: selection)
        let logical = fixture.restoredHome.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        let expected = try Data(contentsOf: logical)

        let rollback = try await restore.rollbackLastOperation()

        XCTAssertTrue(rollback.hasResidualItems)
        XCTAssertGreaterThan(rollback.failedRemovalCount, 0)
        XCTAssertTrue(rollback.issues.contains { $0.code == "cleanup_quarantine_move_failed" })
        XCTAssertEqual(try Data(contentsOf: logical), expected)
    }

    func testProductionRestoreCleanupContainsNoDestructiveUnlink() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../../../Sources/DirectorCore/Export/CapabilityRestoreSecureFileSystem.swift")
                .standardizedFileURL,
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("unlinkat("))
        XCTAssertFalse(source.contains("removeItem("))
    }

    func testDirectoryPermissionFailureUsesPreJournaledStagingAndQuarantine() async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(shouldFailDirectoryChmod: { _ in true })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let agentID = try XCTUnwrap(info.manifest.capabilities.first { $0.kind == "agent" }?.id)
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [agentID])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("The directory chmod fault must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .writeFailed)
            XCTAssertEqual(failure.cleanup.quarantinedDirectoryCount, 1)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertTrue(failure.cleanup.issues.contains { $0.code == "cleanup_preserved_isolated" })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.restoredHome.appendingPathComponent(".codex").path))
    }

    func testJournalDescriptorDuplicatesAreCloseOnExec() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-restore-cloexec-\(UUID().uuidString)", isDirectory: true)
        roots.append(rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let parent = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { Darwin.close(parent) }
        let name = "staging"
        let object = Darwin.openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(object, 0)
        defer { Darwin.close(object) }
        var value = stat()
        XCTAssertEqual(Darwin.fstat(object, &value), 0)
        let identity = try CapabilityRestoreSecureFileSystem.anchorIdentity(at: rootURL)
        let root = try CapabilityRestoreSecureFileSystem.openRoot(at: rootURL, expectedIdentity: identity)
        let quarantine = try makeQuarantine(for: root)
        let item = try CapabilityRestoreSecureJournalItem(
            parentDescriptor: parent,
            name: "final",
            stagingName: name,
            displayPath: "{{HOME}}/final",
            kind: .regular,
            quarantine: quarantine
        )
        item.markCreated()
        try item.bindObject(descriptor: object, identity: CapabilityRestoreFileIdentity(value))

        XCTAssertNotEqual(Darwin.fcntl(item.parentDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(Darwin.fcntl(item.objectDescriptor, F_GETFD) & FD_CLOEXEC, 0)
    }

    // MARK: Fixtures

    private func assertPostCreateFault(
        kind: CapabilityRestoreSecureJournalItem.Kind,
        capabilityKind: String,
        logicalRelativePath: String
    ) async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let hooks = CapabilityRestoreTestHooks(afterStagingCreate: { _, createdKind in
            if createdKind == kind { throw CapabilityRestoreError.writeFailed }
        })
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let capability = try XCTUnwrap(info.manifest.capabilities.first {
            $0.kind == capabilityKind && (capabilityKind != "skill" || $0.projectID == nil)
        })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [capability.id])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("The post-create fault must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .writeFailed)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
            XCTAssertGreaterThan(failure.cleanup.failedRemovalCount, 0)
            XCTAssertTrue(failure.cleanup.issues.contains {
                $0.code == "cleanup_unverified_staging_preserved"
            })
            let quarantine = try XCTUnwrap(failure.cleanup.quarantineLocations.first)
            let permissions = try FileManager.default.attributesOfItem(atPath: quarantine.directoryURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.uint16Value, 0o700)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.restoredHome.appendingPathComponent(logicalRelativePath).path
        ))
        let remainingStagingItems = FileManager.default.enumerator(
            at: fixture.restoredHome,
            includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL)?.lastPathComponent }
            .filter { $0.hasPrefix(".CodexDirectorRestore-") } ?? []
        XCTAssertFalse(
            remainingStagingItems.isEmpty,
            "An unbound post-create object must remain in place rather than moving a possibly replaced pathname"
        )
    }

    private func makeQuarantine(
        for root: CapabilityRestoreSecureRoot
    ) throws -> CapabilityRestoreSecureQuarantine {
        var locations: [CapabilityRestoreQuarantineLocation] = []
        let contexts = try CapabilityRestoreSecureFileSystem().prepareQuarantines(
            roots: [root.url.path: root],
            operationID: UUID(),
            hooks: .none,
            locations: &locations
        )
        return try XCTUnwrap(contexts[root.url.path])
    }

    private func assertSymlinkIdentityRace(_ phase: SymlinkIdentityRacePhase) async throws {
        let fixture = try makeFixture()
        let prepared = try await makePackage(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let race = SymlinkIdentityRace(replacementTarget: "asset.bin")
        let hooks: CapabilityRestoreTestHooks
        switch phase {
        case .pathStatToOpen:
            hooks = CapabilityRestoreTestHooks(afterSymbolicLinkPathStat: { _, parent, name in
                try race.replace(parent: parent, name: name)
            })
        case .beforePublish:
            hooks = CapabilityRestoreTestHooks(beforeSymbolicLinkPublish: { _, parent, name in
                try race.replace(parent: parent, name: name)
            })
        case .afterPublish:
            hooks = CapabilityRestoreTestHooks(afterSymbolicLinkPublish: { _, parent, name in
                try race.replace(parent: parent, name: name)
            })
        }
        let restore = CapabilityRestoreCoordinator(homeDirectory: fixture.restoredHome, hooks: hooks)
        let info = try await restore.openPackage(at: fixture.archive, trustedSource: true)
        let skill = try XCTUnwrap(info.manifest.capabilities.first {
            $0.kind == "skill" && $0.projectID == nil
        })
        let selection = CapabilityRestoreSelection(includedCapabilityIDs: [skill.id])
        _ = try await restore.preview(selection: selection)

        do {
            _ = try await restore.restore(selection: selection)
            XCTFail("The symlink identity race must abort restore")
        } catch {
            let failure = try XCTUnwrap(error as? CapabilityRestoreOperationFailure)
            XCTAssertEqual(failure.reason, .targetChanged)
            XCTAssertTrue(failure.cleanup.hasResidualItems)
        }

        let skillDirectory = fixture.restoredHome.appendingPathComponent(
            ".codex/skills/portable-skill",
            isDirectory: true
        )
        let replacedName = try XCTUnwrap(race.replacedName)
        let replacement = skillDirectory.appendingPathComponent(replacedName)
        let original = skillDirectory.appendingPathComponent(race.movedName)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: original.path),
            "run.sh",
            "The originally created symlink must remain recoverable"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: replacement.path),
            "asset.bin",
            "The replacement symlink must be preserved rather than deleted"
        )
        let logical = skillDirectory.appendingPathComponent("latest.sh")
        if phase == .afterPublish {
            XCTAssertEqual(replacement.standardizedFileURL, logical.standardizedFileURL)
        } else {
            XCTAssertNil(
                try? FileManager.default.attributesOfItem(atPath: logical.path),
                "A replacement observed before publication must never reach the logical target"
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-restore-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let restoredHome = root.appendingPathComponent("restored-home", isDirectory: true)
        let restoredProject = root.appendingPathComponent("restored-project", isDirectory: true)
        for directory in [home, project, output, restoredHome, restoredProject] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("name = \"Portable Agent\"\n", to: home.appendingPathComponent(".codex/agents/portable-agent.toml"))
        try write("# Portable Agent\n", to: home.appendingPathComponent(".codex/agents/portable-agent/agent.md"))
        try write(
            "---\nname: portable-skill\n---\n",
            to: home.appendingPathComponent(".codex/skills/portable-skill/SKILL.md")
        )
        let binary = home.appendingPathComponent(".codex/skills/portable-skill/asset.bin")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00, 0xff, 0x10, 0x80]).write(to: binary)
        let executable = home.appendingPathComponent(".codex/skills/portable-skill/run.sh")
        try write("#!/bin/zsh\necho synthetic\n", to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent(".codex/skills/portable-skill/latest.sh").path,
            withDestinationPath: "run.sh"
        )
        try write(
            "---\nname: project-skill\n---\n",
            to: project.appendingPathComponent(".agents/skills/project-skill/SKILL.md")
        )
        try write("# Project instructions\n", to: project.appendingPathComponent("AGENTS.md"))
        return Fixture(
            root: root,
            home: home,
            project: project,
            archive: output.appendingPathComponent("restore.codexpack.zip"),
            restoredHome: restoredHome,
            restoredProject: restoredProject
        )
    }

    private func makePackage(
        fixture: Fixture,
        includeProjectInstructions: Bool = false
    ) async throws -> CapabilityPreparedPackage {
        let environment = environment(for: fixture)
        let discovery = CapabilityPackageDiscovery(environment: environment)
        var selection = CapabilityExportSelection.defaults(for: discovery.options())
        selection.projects = [CapabilityExportProjectSelection(
            projectID: "project-001",
            includeSkills: true,
            includeInstructions: includeProjectInstructions
        )]
        let prepared = try await CapabilityPackageBuilder(
            environment: environment,
            pluginProvider: PluginProvider(),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).prepare(selection: selection, progress: nil)
        XCTAssertFalse(prepared.preview.hasBlockingIssues)
        _ = try CapabilityPackageArchiveWriter().write(
            prepared: prepared,
            to: fixture.archive,
            progressHandler: nil,
            cancellation: CapabilityExportCancellation()
        )
        return prepared
    }

    private func environment(for fixture: Fixture) -> CapabilityExportEnvironment {
        CapabilityExportEnvironment(
            homeDirectory: fixture.home,
            projects: [CapabilityExportProjectSource(directory: fixture.project, displayName: "Fixture Project")],
            producer: CapabilityPackageProducer(version: "1.2.0", build: "24"),
            platform: CapabilityPackagePlatform(operatingSystem: "macOS", operatingSystemVersion: "26.0", architecture: "arm64")
        )
    }

    private func restoredURL(for entry: CapabilityPackageEntry, home: URL, project: URL) -> URL {
        if entry.logicalRoot.hasPrefix("{{HOME}}") {
            let suffix = String(entry.logicalRoot.dropFirst("{{HOME}}".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return home.appendingPathComponent(suffix).appendingPathComponent(entry.relativePath)
        }
        let tokenEnd = entry.logicalRoot.firstIndex(of: "}")!
        let suffixStart = entry.logicalRoot.index(tokenEnd, offsetBy: 2)
        let suffix = String(entry.logicalRoot[suffixStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = suffix.isEmpty ? project : project.appendingPathComponent(suffix)
        return root.appendingPathComponent(entry.relativePath)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
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
