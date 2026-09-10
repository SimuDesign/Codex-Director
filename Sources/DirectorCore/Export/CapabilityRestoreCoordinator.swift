import CryptoKit
import Foundation

/// Performs a user-confirmed, local restore from an already exported package.
/// The coordinator owns the verified extraction directory and the in-memory
/// rollback journal. No package or destination path is persisted.
public actor CapabilityRestoreCoordinator {
    public typealias ProgressHandler = @Sendable (CapabilityRestoreProgress) -> Void

    private struct FileSnapshot: Sendable, Equatable {
        let exists: Bool
        let isDirectory: Bool
        let isSymlink: Bool
        let byteSize: Int64?
        let sha256: String?
        let executable: Bool?
        let symlinkTarget: String?
    }

    private struct ApprovedPreflight: Sendable {
        let selectionSignature: String
        let anchorIdentities: [String: CapabilityRestoreFileIdentity]
    }

    private enum OperationKind: Sendable, Equatable {
        case opening
        case restoring
        case undoing
    }

    private struct ActiveOperation: Sendable, Equatable {
        let id: UUID
        let generation: UInt64
        let kind: OperationKind
    }

    private let homeDirectory: URL
    private let migrationGate: CapabilityMigrationGate
    private let hooks: CapabilityRestoreTestHooks
    private let secureFileSystem = CapabilityRestoreSecureFileSystem()
    private let fileManager = FileManager.default
    private var package: CapabilityVerifiedPackage?
    private var packageURL: URL?
    private var packageDigest: String?
    private var migrationToken: UUID?
    private var rollbackJournal: [CapabilityRestoreSecureJournalItem] = []
    private var approvedPreflight: ApprovedPreflight?
    private var cancellation: CapabilityExportCancellation?
    private var operationGeneration: UInt64 = 0
    private var activeOperation: ActiveOperation?
    private var discardRequested = false

    public init(homeDirectory: URL, migrationGate: CapabilityMigrationGate = CapabilityMigrationGate()) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.migrationGate = migrationGate
        self.hooks = .none
    }

    init(
        homeDirectory: URL,
        migrationGate: CapabilityMigrationGate = CapabilityMigrationGate(),
        hooks: CapabilityRestoreTestHooks
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.migrationGate = migrationGate
        self.hooks = hooks
    }

    public func openPackage(
        at archiveURL: URL,
        trustedSource: Bool,
        progress: ProgressHandler? = nil
    ) async throws -> CapabilityRestorePackageInfo {
        guard trustedSource else { throw CapabilityRestoreError.untrustedSource }
        guard package == nil else { throw CapabilityRestoreError.operationInProgress }
        let operation = try beginOperation(.opening)
        let cancel = CapabilityExportCancellation()
        cancellation = cancel
        let token: UUID
        do {
            token = try await migrationGate.acquire()
        } catch {
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: false)
            throw CapabilityRestoreError.operationInProgress
        }
        migrationToken = token
        let initialDigest: String
        do {
            try validateOperation(operation)
            try cancel.check()
            initialDigest = try digest(of: archiveURL)
        } catch {
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreError.invalidArchive
        }
        let extraction = fileManager.temporaryDirectory
            .appendingPathComponent("CodexDirectorRestore-\(UUID().uuidString)", isDirectory: true)
        do {
            progress?(CapabilityRestoreProgress(phase: .verifying))
            let verified = try CapabilityPackageArchiveVerifier().verifyAndExtract(
                archiveURL: archiveURL,
                extractionDirectory: extraction,
                cancellation: cancel
            )
            try cancel.check()
            let finalDigest = try digest(of: archiveURL)
            guard finalDigest == initialDigest else { throw CapabilityRestoreError.packageChanged }
            try cancel.check()
            package = verified
            packageURL = archiveURL.standardizedFileURL
            packageDigest = finalDigest
            approvedPreflight = nil
            cancellation = nil
            let result = CapabilityRestorePackageInfo(
                manifest: verified.manifest,
                plugins: verified.plugins,
                requirements: verified.requirements,
                packageFileName: archiveURL.lastPathComponent
            )
            await completeOperation(operation, releaseMigrationGate: false)
            return result
        } catch is CancellationError {
            cleanupPackageExtraction(at: extraction)
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreError.cancelled
        } catch let error as CapabilityRestoreError {
            cleanupPackageExtraction(at: extraction)
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: true)
            throw error
        } catch let error as CapabilityExportError {
            cleanupPackageExtraction(at: extraction)
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: true)
            throw map(error)
        } catch {
            cleanupPackageExtraction(at: extraction)
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreError.invalidArchive
        }
    }

    public func preview(
        selection: CapabilityRestoreSelection,
        progress: ProgressHandler? = nil
    ) throws -> CapabilityRestorePreview {
        guard let package else { throw CapabilityRestoreError.noPackage }
        progress?(CapabilityRestoreProgress(phase: .preflighting))
        let approval = try makeApprovedPreflight(manifest: package.manifest, selection: selection)
        let roots = try openSecureRoots(manifest: package.manifest, selection: selection, approvedPreflight: approval)
        let result = try makePreview(package: package, selection: selection, secureRoots: roots, progress: progress)
        approvedPreflight = approval
        return result
    }

    public func restore(
        selection: CapabilityRestoreSelection,
        progress: ProgressHandler? = nil
    ) async throws -> CapabilityRestoreResult {
        guard let package, let packageURL, let packageDigest else {
            throw CapabilityRestoreError.noPackage
        }
        guard let currentDigest = try? digest(of: packageURL), currentDigest == packageDigest else {
            throw CapabilityRestoreError.packageChanged
        }
        let selected = try selectedCapabilities(manifest: package.manifest, selection: selection)
        let signature = selectionSignature(selection)
        guard let approvedPreflight, approvedPreflight.selectionSignature == signature else {
            throw CapabilityRestoreError.preflightRequired
        }
        let operation = try beginOperation(.restoring)
        let cancel = CapabilityExportCancellation()
        cancellation = cancel
        rollbackJournal.removeAll()
        var created: [CapabilityRestoreSecureJournalItem] = []
        var quarantineLocations: [CapabilityRestoreQuarantineLocation] = []
        var quarantinePreparationAttempted = false
        var quarantinePreparationComplete = false
        do {
            let secureRoots = try openSecureRoots(
                manifest: package.manifest,
                selection: selection,
                approvedPreflight: approvedPreflight
            )
            let preview = try makePreview(package: package, selection: selection, secureRoots: secureRoots, progress: progress)
            guard !preview.hasBlockingIssues else { throw CapabilityRestoreError.conflictsRemain }
            quarantinePreparationAttempted = true
            let quarantines = try secureFileSystem.prepareQuarantines(
                roots: secureRoots,
                operationID: operation.id,
                hooks: hooks,
                locations: &quarantineLocations
            )
            quarantinePreparationComplete = true
            let totalItems = selected.reduce(0) { $0 + $1.files.count }
            progress?(CapabilityRestoreProgress(
                phase: .restoring,
                completedItems: 0,
                totalItems: totalItems
            ))
            var completed = 0
            var writeIndex = 0
            for capability in selected {
                try validateOperation(operation)
                try cancel.check()
                let entries = package.manifest.entries
                    .filter { capability.files.contains($0.archivePath) }
                    .sorted {
                        let lhsIsLink = $0.inspection == .validatedSymlink
                        let rhsIsLink = $1.inspection == .validatedSymlink
                        return lhsIsLink == rhsIsLink
                            ? $0.archivePath < $1.archivePath
                            : !lhsIsLink
                    }
                for entry in entries {
                    await Task.yield()
                    try validateOperation(operation)
                    try cancel.check()
                    let action = preview.entries.first(where: { $0.archivePath == entry.archivePath })?.action
                    guard action == .create else {
                        completed += 1
                        continue
                    }
                    let destination = try secureDestination(
                        for: entry,
                        capability: capability,
                        selection: selection
                    )
                    try await hooks.beforeWrite(destination.displayPath, writeIndex)
                    writeIndex += 1
                    try validateOperation(operation)
                    try cancel.check()
                    guard let secureRoot = secureRoots[destination.anchorURL.path] else {
                        throw CapabilityRestoreError.targetChanged
                    }
                    guard let quarantine = quarantines[destination.anchorURL.path] else {
                        throw CapabilityRestoreError.targetChanged
                    }
                    try CapabilityRestoreSecureFileSystem.validateCurrentBinding(of: secureRoot)
                    let source = package.extractionDirectory.appendingPathComponent(entry.archivePath)
                    try secureFileSystem.write(
                        source: source,
                        entry: entry,
                        destination: destination,
                        root: secureRoot,
                        quarantine: quarantine,
                        hooks: hooks,
                        created: &created
                    )
                    completed += 1
                    progress?(CapabilityRestoreProgress(
                        phase: .restoring,
                        completedItems: completed,
                        totalItems: totalItems
                    ))
                }
            }
            try cancel.check()
            rollbackJournal = created
            cancellation = nil
            progress?(CapabilityRestoreProgress(phase: .rescanning, completedItems: completed, totalItems: completed))
            progress?(CapabilityRestoreProgress(phase: .finished, completedItems: completed, totalItems: completed))
            let result = CapabilityRestoreResult(
                createdCount: created.filter { !$0.isDirectory }.count,
                skippedCount: preview.skipCount,
                conflictCount: preview.conflictCount,
                warnings: preview.issues.filter { $0.severity == .warning },
                rescanRequired: !created.isEmpty,
                quarantineLocations: quarantineLocations
            )
            await completeOperation(operation, releaseMigrationGate: true)
            return result
        } catch is CancellationError {
            cancellation = nil
            let cleanup = secureFileSystem.cleanup(
                created,
                hooks: hooks,
                quarantineLocations: quarantineLocations,
                quarantinePreparationFailed: quarantinePreparationAttempted && !quarantinePreparationComplete
            )
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreOperationFailure(reason: .cancelled, cleanup: cleanup)
        } catch let error as CapabilityRestoreError {
            cancellation = nil
            let cleanup = secureFileSystem.cleanup(
                created,
                hooks: hooks,
                quarantineLocations: quarantineLocations,
                quarantinePreparationFailed: quarantinePreparationAttempted && !quarantinePreparationComplete
            )
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreOperationFailure(reason: error, cleanup: cleanup)
        } catch {
            cancellation = nil
            let cleanup = secureFileSystem.cleanup(
                created,
                hooks: hooks,
                quarantineLocations: quarantineLocations,
                quarantinePreparationFailed: quarantinePreparationAttempted && !quarantinePreparationComplete
            )
            await completeOperation(operation, releaseMigrationGate: true)
            throw CapabilityRestoreOperationFailure(reason: .writeFailed, cleanup: cleanup)
        }
    }

    /// Logically undoes the last restore by moving unchanged created objects to
    /// its private quarantine. Production never destroys quarantine contents.
    public func rollbackLastOperation() async throws -> CapabilityRestoreRollbackResult {
        guard !rollbackJournal.isEmpty else { throw CapabilityRestoreError.rollbackUnavailable }
        let operation = try beginOperation(.undoing)
        let cancel = CapabilityExportCancellation()
        cancellation = cancel
        let token: UUID
        do {
            token = try await migrationGate.acquire()
        } catch {
            cancellation = nil
            await completeOperation(operation, releaseMigrationGate: false)
            throw CapabilityRestoreError.operationInProgress
        }
        do {
            try validateOperation(operation)
            try cancel.check()
            let quarantineLocations = uniqueQuarantineLocations(for: rollbackJournal)
            let cleanup = secureFileSystem.cleanup(
                rollbackJournal,
                hooks: hooks,
                quarantineLocations: quarantineLocations
            )
            rollbackJournal.removeAll()
            cancellation = nil
            await migrationGate.release(token)
            await completeOperation(operation, releaseMigrationGate: false)
            return CapabilityRestoreRollbackResult(
                removedCount: cleanup.removedCount,
                removedDirectoryCount: cleanup.removedDirectoryCount,
                skippedModifiedCount: cleanup.skippedModifiedCount,
                failedRemovalCount: cleanup.failedRemovalCount,
                issues: cleanup.issues,
                quarantinedCount: cleanup.quarantinedCount,
                quarantinedDirectoryCount: cleanup.quarantinedDirectoryCount,
                quarantineLocations: cleanup.quarantineLocations
            )
        } catch {
            cancellation = nil
            await migrationGate.release(token)
            await completeOperation(operation, releaseMigrationGate: false)
            throw CapabilityRestoreError.cancelled
        }
    }

    public func cancel() {
        cancellation?.cancel()
    }

    public func discard() async {
        cancellation?.cancel()
        guard activeOperation == nil else {
            discardRequested = true
            return
        }
        clearPackageState()
        await releaseGate()
    }

    deinit {
        cancellation?.cancel()
        if let package {
            try? FileManager.default.removeItem(at: package.extractionDirectory)
        }
    }

    private func makePreview(
        package: CapabilityVerifiedPackage,
        selection: CapabilityRestoreSelection,
        secureRoots: [String: CapabilityRestoreSecureRoot],
        progress: ProgressHandler?
    ) throws -> CapabilityRestorePreview {
        let selected = try selectedCapabilities(manifest: package.manifest, selection: selection)
        let sourceProjects = Set(package.manifest.projects.map(\.id))
        var mappedProjects: [String: URL] = [:]
        for mapping in selection.projectMappings {
            guard mappedProjects.updateValue(mapping.destinationURL.standardizedFileURL, forKey: mapping.packageProjectID) == nil else {
                throw CapabilityRestoreError.duplicateProjectMapping
            }
        }
        guard mappedProjects.count == selection.projectMappings.count,
              mappedProjects.keys.allSatisfy({ sourceProjects.contains($0) }) else {
            throw CapabilityRestoreError.duplicateProjectMapping
        }
        let destinationPaths = selection.projectMappings.map { $0.destinationURL.path }
        guard Set(destinationPaths).count == destinationPaths.count else {
            throw CapabilityRestoreError.duplicateProjectMapping
        }
        for mapping in selection.projectMappings {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: mapping.destinationURL.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw CapabilityRestoreError.invalidProjectMapping }
            } else {
                throw CapabilityRestoreError.invalidProjectMapping
            }
        }

        var entries: [CapabilityRestoreEntryPreview] = []
        var issues: [CapabilityRestoreIssue] = []
        var actionsByCapability: [String: [CapabilityRestoreEntryAction]] = [:]
        for capability in selected {
            let capabilityEntries = package.manifest.entries
                .filter { capability.files.contains($0.archivePath) }
                .sorted { $0.archivePath < $1.archivePath }
            for entry in capabilityEntries {
                progress?(CapabilityRestoreProgress(phase: .preflighting, completedItems: entries.count, totalItems: package.manifest.entries.count))
                let secureTarget = try secureDestination(for: entry, capability: capability, selection: selection)
                guard let secureRoot = secureRoots[secureTarget.anchorURL.path] else {
                    throw CapabilityRestoreError.targetChanged
                }
                let secureSnapshot = try secureFileSystem.snapshot(destination: secureTarget, root: secureRoot)
                let targetSnapshot = FileSnapshot(
                    exists: secureSnapshot.exists,
                    isDirectory: secureSnapshot.isDirectory,
                    isSymlink: secureSnapshot.isSymbolicLink,
                    byteSize: secureSnapshot.byteSize,
                    sha256: secureSnapshot.sha256,
                    executable: secureSnapshot.executable,
                    symlinkTarget: nil
                )
                let source = package.extractionDirectory.appendingPathComponent(entry.archivePath)
                let expected = try snapshot(of: source)
                let action: CapabilityRestoreEntryAction
                if !targetSnapshot.exists {
                    action = .create
                } else if entry.relativePath == "AGENTS.md" || (entry.relativePath as NSString).lastPathComponent == "AGENTS.md" {
                    action = .conflict
                    issues.append(issue(code: "agents_file_exists", capabilityID: capability.id, entry: entry, message: "An existing AGENTS.md requires a manual decision."))
                } else if sameContent(targetSnapshot, expected: expected, entry: entry) {
                    action = .skipIdentical
                } else {
                    action = .conflict
                    issues.append(issue(code: "target_conflict", capabilityID: capability.id, entry: entry, message: "An existing target differs and will not be overwritten."))
                }
                actionsByCapability[capability.id, default: []].append(action)
                let difference: String? = action == .conflict
                    && entry.inspection == .scannedText
                    && !isNestedArchive(entry.relativePath)
                    && !targetSnapshot.isDirectory
                    && !targetSnapshot.isSymlink
                    ? safeDifference(source: source, destinationData: secureSnapshot.previewData)
                    : nil
                entries.append(CapabilityRestoreEntryPreview(
                    capabilityID: capability.id,
                    archivePath: entry.archivePath,
                    displayPath: displayPath(for: entry, manifest: package.manifest),
                    byteSize: entry.byteSize,
                    sha256: entry.sha256,
                    contentType: entry.contentType,
                    executable: entry.executable,
                    action: action,
                    difference: difference
                ))
                if entry.inspection == .unscannedBinary {
                    issues.append(issue(code: "binary_content_unscanned", capabilityID: capability.id, entry: entry, message: "This binary resource was verified and hashed, but its contents were not scanned."))
                }
                if isNestedArchive(entry.relativePath) {
                    issues.append(issue(code: "nested_archive_not_inspected", capabilityID: capability.id, entry: entry, message: "This nested archive will be copied unchanged and will not be opened or executed."))
                }
            }
        }
        for capability in selected {
            let actions = actionsByCapability[capability.id] ?? []
            if actions.contains(.conflict) || (actions.contains(.create) && actions.contains(.skipIdentical)) {
                issues.append(CapabilityRestoreIssue(
                    severity: .blocking,
                    code: "capability_conflict",
                    capabilityID: capability.id,
                    message: "This capability is partially present or conflicts; exclude it before restoring."
                ))
            }
        }
        if selected.isEmpty {
            issues.append(CapabilityRestoreIssue(severity: .blocking, code: "no_capability_selected", message: "Select at least one capability to restore."))
        }
        let createCount = entries.filter { $0.action == .create }.count
        return CapabilityRestorePreview(
            capabilityCount: selected.count,
            createCount: createCount,
            skipCount: entries.filter { $0.action == .skipIdentical }.count,
            conflictCount: entries.filter { $0.action == .conflict }.count,
            byteSize: entries.filter { $0.action == .create }.reduce(0) { $0 + $1.byteSize },
            binaryWarningCount: issues.filter { $0.code == "binary_content_unscanned" }.count,
            pluginStatus: package.plugins.status,
            pluginCount: package.plugins.plugins.count,
            requirementCount: package.requirements.requirements.count,
            entries: entries,
            issues: deduplicate(issues)
        )
    }

    private func selectedCapabilities(
        manifest: CapabilityPackageManifestV1,
        selection: CapabilityRestoreSelection
    ) throws -> [CapabilityPackageCapability] {
        let ids = Set(manifest.capabilities.map(\.id))
        guard selection.includedCapabilityIDs.isSubset(of: ids),
              selection.excludedCapabilityIDs.isSubset(of: ids) else { throw CapabilityRestoreError.invalidProjectMapping }
        let selectedIDs = selection.includedCapabilityIDs.subtracting(selection.excludedCapabilityIDs)
        let selected = manifest.capabilities.filter { selectedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let projectIDs = Set(selected.compactMap(\.projectID))
        var mappings: [String: URL] = [:]
        for mapping in selection.projectMappings {
            guard mappings.updateValue(mapping.destinationURL.standardizedFileURL, forKey: mapping.packageProjectID) == nil else {
                throw CapabilityRestoreError.duplicateProjectMapping
            }
        }
        guard projectIDs.allSatisfy({ mappings[$0] != nil }) else {
            throw CapabilityRestoreError.missingProjectMapping(projectIDs.first(where: { mappings[$0] == nil }) ?? "project")
        }
        guard projectIDs.count == Set(mappings.keys).intersection(projectIDs).count else {
            throw CapabilityRestoreError.invalidProjectMapping
        }
        return selected
    }

    private func makeApprovedPreflight(
        manifest: CapabilityPackageManifestV1,
        selection: CapabilityRestoreSelection
    ) throws -> ApprovedPreflight {
        let selected = try selectedCapabilities(manifest: manifest, selection: selection)
        var identities: [String: CapabilityRestoreFileIdentity] = [:]
        for capability in selected {
            let anchor = try secureAnchorURL(for: capability, selection: selection)
            if identities[anchor.path] == nil {
                identities[anchor.path] = try CapabilityRestoreSecureFileSystem.anchorIdentity(at: anchor)
            }
        }
        return ApprovedPreflight(
            selectionSignature: selectionSignature(selection),
            anchorIdentities: identities
        )
    }

    private func openSecureRoots(
        manifest: CapabilityPackageManifestV1,
        selection: CapabilityRestoreSelection,
        approvedPreflight: ApprovedPreflight
    ) throws -> [String: CapabilityRestoreSecureRoot] {
        let selected = try selectedCapabilities(manifest: manifest, selection: selection)
        var roots: [String: CapabilityRestoreSecureRoot] = [:]
        for capability in selected {
            let anchor = try secureAnchorURL(for: capability, selection: selection)
            guard let expected = approvedPreflight.anchorIdentities[anchor.path] else {
                throw CapabilityRestoreError.preflightRequired
            }
            if roots[anchor.path] == nil {
                roots[anchor.path] = try CapabilityRestoreSecureFileSystem.openRoot(
                    at: anchor,
                    expectedIdentity: expected
                )
            }
        }
        return roots
    }

    private func secureDestination(
        for entry: CapabilityPackageEntry,
        capability: CapabilityPackageCapability,
        selection: CapabilityRestoreSelection
    ) throws -> CapabilityRestoreSecureDestination {
        guard capability.files.contains(entry.archivePath), isSafeRelativePath(entry.relativePath) else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        let anchor = try secureAnchorURL(for: capability, selection: selection)
        let rootComponents = try secureRootComponents(for: capability)
        let entryComponents = entry.relativePath.split(separator: "/").map(String.init)
        return CapabilityRestoreSecureDestination(
            anchorURL: anchor,
            components: rootComponents + entryComponents,
            capabilityRootComponentCount: rootComponents.count,
            displayPath: entry.relativePath.isEmpty
                ? (capability.projectID.map { "{{PROJECT:\($0)}}" } ?? entry.logicalRoot)
                : "\(capability.projectID.map { "{{PROJECT:\($0)}}" } ?? entry.logicalRoot)/\(entry.relativePath)"
        )
    }

    private func secureAnchorURL(
        for capability: CapabilityPackageCapability,
        selection: CapabilityRestoreSelection
    ) throws -> URL {
        if let projectID = capability.projectID {
            guard let mapping = selection.projectMappings.first(where: { $0.packageProjectID == projectID }) else {
                throw CapabilityRestoreError.missingProjectMapping(projectID)
            }
            return mapping.destinationURL.standardizedFileURL
        }
        return homeDirectory
    }

    private func secureRootComponents(for capability: CapabilityPackageCapability) throws -> [String] {
        if let projectID = capability.projectID {
            let token = "{{PROJECT:\(projectID)}}"
            guard capability.logicalRoot == token || capability.logicalRoot.hasPrefix(token + "/") else {
                throw CapabilityRestoreError.invalidArchive
            }
            let suffix = capability.logicalRoot == token
                ? ""
                : String(capability.logicalRoot.dropFirst(token.count + 1))
            if suffix.isEmpty { return [] }
            guard isSafeRelativePath(suffix) else { throw CapabilityRestoreError.unsafeArchivePath }
            return suffix.split(separator: "/").map(String.init)
        }
        switch capability.logicalRoot {
        case "{{HOME}}/.codex/agents": return [".codex", "agents"]
        case "{{HOME}}/.codex/skills": return [".codex", "skills"]
        case "{{HOME}}/.agents/skills": return [".agents", "skills"]
        case "{{HOME}}/.codex": return [".codex"]
        default: throw CapabilityRestoreError.invalidArchive
        }
    }

    private func selectionSignature(_ selection: CapabilityRestoreSelection) -> String {
        let included = selection.includedCapabilityIDs.sorted().joined(separator: "\u{1f}")
        let excluded = selection.excludedCapabilityIDs.sorted().joined(separator: "\u{1f}")
        let mappings = selection.projectMappings
            .map { "\($0.packageProjectID)=\($0.destinationURL.standardizedFileURL.path)" }
            .sorted()
            .joined(separator: "\u{1f}")
        return sha256(Data("\(included)\u{1e}\(excluded)\u{1e}\(mappings)".utf8))
    }

    private func displayPath(for entry: CapabilityPackageEntry, manifest: CapabilityPackageManifestV1) -> String {
        let prefix: String
        if let capability = manifest.capabilities.first(where: { $0.files.contains(entry.archivePath) }), let projectID = capability.projectID {
            prefix = "{{PROJECT:\(projectID)}}"
        } else {
            prefix = entry.logicalRoot
        }
        return entry.relativePath.isEmpty ? prefix : "\(prefix)/\(entry.relativePath)"
    }

    private func snapshot(of url: URL) throws -> FileSnapshot {
        var isDirectory: ObjCBool = false
        guard itemExists(at: url) else {
            return FileSnapshot(exists: false, isDirectory: false, isSymlink: false, byteSize: nil, sha256: nil, executable: nil, symlinkTarget: nil)
        }
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        let symlink = values.isSymbolicLink == true
        let data: Data
        let target: String?
        if symlink {
            target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            data = Data((target ?? "").utf8)
        } else if isDirectory.boolValue {
            target = nil
            data = Data()
        } else {
            target = nil
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return FileSnapshot(
            exists: true,
            isDirectory: isDirectory.boolValue,
            isSymlink: symlink,
            byteSize: Int64(data.count),
            sha256: sha256(data),
            executable: symlink ? nil : (permissions & 0o111 != 0),
            symlinkTarget: target
        )
    }

    private func sameContent(_ current: FileSnapshot, expected: FileSnapshot, entry: CapabilityPackageEntry) -> Bool {
        current.exists && current.isDirectory == expected.isDirectory && current.isSymlink == expected.isSymlink
            && current.sha256 == expected.sha256 && current.byteSize == expected.byteSize
            && (current.isSymlink || current.executable == entry.executable)
    }

    private func safeDifference(source: URL, destinationData: Data?) -> String? {
        guard let sourceSnapshot = try? snapshot(of: source),
              !sourceSnapshot.isDirectory,
              !sourceSnapshot.isSymlink,
              let sourceSize = sourceSnapshot.byteSize, sourceSize <= 128_000,
              let sourceData = try? Data(contentsOf: source, options: .mappedIfSafe),
              let destinationData,
              sourceData.count <= 128_000, destinationData.count <= 128_000,
              let sourceText = String(data: sourceData, encoding: .utf8),
              let destinationText = String(data: destinationData, encoding: .utf8) else { return nil }
        let sourceSafe = redact(sourceText)
        let destinationSafe = redact(destinationText)
        guard !PersistenceAllowlist.containsForbiddenValue(sourceSafe), !PersistenceAllowlist.containsForbiddenValue(destinationSafe) else {
            return "[redacted difference]"
        }
        let old = destinationSafe.split(separator: "\n", omittingEmptySubsequences: false)
        let new = sourceSafe.split(separator: "\n", omittingEmptySubsequences: false)
        var result = ""
        for line in old.prefix(80) where !new.contains(line) { result += "-\(line)\n" }
        for line in new.prefix(80) where !old.contains(line) { result += "+\(line)\n" }
        return String(result.prefix(4_000))
    }

    private func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: homeDirectory.path, with: "{{HOME}}")
        result = result.replacingOccurrences(
            of: #"/Users/[^/[:space:]]+"#,
            with: "{{USER_PATH}}",
            options: .regularExpression
        )
        for pattern in PersistenceAllowlist.forbiddenValuePatterns {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return result
    }

    private func isNestedArchive(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".zip", ".tar", ".gz", ".tgz", ".7z", ".rar"].contains { lower.hasSuffix($0) }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func issue(code: String, capabilityID: String, entry: CapabilityPackageEntry, message: String) -> CapabilityRestoreIssue {
        CapabilityRestoreIssue(severity: code.hasPrefix("binary") || code.hasPrefix("nested") ? .warning : .blocking, code: code, capabilityID: capabilityID, archivePath: entry.archivePath, message: message)
    }

    private func deduplicate(_ issues: [CapabilityRestoreIssue]) -> [CapabilityRestoreIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert("\($0.code)|\($0.capabilityID ?? "")|\($0.archivePath ?? "")").inserted }
    }

    private func uniqueQuarantineLocations(
        for items: [CapabilityRestoreSecureJournalItem]
    ) -> [CapabilityRestoreQuarantineLocation] {
        var seen: Set<String> = []
        return items.compactMap { item in
            let location = item.quarantine.location
            return seen.insert(location.id).inserted ? location : nil
        }
    }

    private func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return sha256(data)
    }

    /// FileManager.fileExists follows links and returns false for a dangling
    /// link. Attributes are intentionally used as the existence check so a
    /// dangling user-owned target is classified as a conflict rather than an
    /// attempted create.
    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupPackageExtraction(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func map(_ error: CapabilityExportError) -> CapabilityRestoreError {
        switch error {
        case .unsafeArchivePath: return .unsafeArchivePath
        case .checksumMismatch: return .checksumMismatch
        case .cancelled: return .cancelled
        default: return .invalidArchive
        }
    }

    private func beginOperation(_ kind: OperationKind) throws -> ActiveOperation {
        guard activeOperation == nil else { throw CapabilityRestoreError.operationInProgress }
        operationGeneration &+= 1
        let operation = ActiveOperation(
            id: UUID(),
            generation: operationGeneration,
            kind: kind
        )
        activeOperation = operation
        return operation
    }

    private func validateOperation(_ operation: ActiveOperation) throws {
        guard activeOperation == operation,
              operation.generation == operationGeneration else {
            throw CapabilityRestoreError.cancelled
        }
    }

    /// Completes an actor operation without allowing `discard()` to release the
    /// shared migration lock or destroy extraction/journal state while that
    /// operation is suspended. A close request is applied only after mutation
    /// and mandatory cleanup have reached a terminal point.
    private func completeOperation(
        _ operation: ActiveOperation,
        releaseMigrationGate: Bool
    ) async {
        guard activeOperation == operation else { return }
        let shouldDiscardBeforeRelease = discardRequested
        if shouldDiscardBeforeRelease { clearPackageState() }
        if releaseMigrationGate || shouldDiscardBeforeRelease { await releaseGate() }
        if discardRequested && !shouldDiscardBeforeRelease {
            clearPackageState()
        }
        discardRequested = false
        activeOperation = nil
    }

    private func clearPackageState() {
        cancellation = nil
        if let package { cleanupPackageExtraction(at: package.extractionDirectory) }
        package = nil
        packageURL = nil
        packageDigest = nil
        approvedPreflight = nil
        rollbackJournal.removeAll()
    }

    private func releaseGate() async {
        guard let token = migrationToken else { return }
        migrationToken = nil
        await migrationGate.release(token)
    }
}
