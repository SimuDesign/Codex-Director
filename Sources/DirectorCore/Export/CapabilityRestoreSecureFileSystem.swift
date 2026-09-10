import CryptoKit
import Darwin
import Foundation

/// Test-only fault seams used by `@testable` restore tests. Production uses
/// `.none`; the closures never cross the public restore API.
struct CapabilityRestoreTestHooks: Sendable {
    let beforeWrite: @Sendable (_ displayPath: String, _ index: Int) async throws -> Void
    let afterStagingCreate: @Sendable (_ displayPath: String, _ kind: CapabilityRestoreSecureJournalItem.Kind) throws -> Void
    let afterPublish: @Sendable (_ displayPath: String, _ isDirectory: Bool) throws -> Void
    let beforeCleanupRemoval: @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ isolatedName: String) throws -> Void
    let beforeQuarantineMove: @Sendable (_ displayPath: String, _ sourceParentDescriptor: Int32, _ sourceName: String, _ quarantineDescriptor: Int32, _ quarantineName: String) throws -> Void
    let immediatelyBeforeQuarantineRename: @Sendable (_ displayPath: String, _ sourceParentDescriptor: Int32, _ sourceName: String) throws -> Void
    let afterSymbolicLinkPathStat: @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ stagingName: String) throws -> Void
    let beforeSymbolicLinkPublish: @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ stagingName: String) throws -> Void
    let afterSymbolicLinkPublish: @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ finalName: String) throws -> Void
    let shouldFailCleanup: @Sendable (_ displayPath: String) -> Bool
    let shouldFailDirectoryChmod: @Sendable (_ displayPath: String) -> Bool
    let shouldFailQuarantineCreation: @Sendable (_ rootURL: URL) -> Bool

    init(
        beforeWrite: @escaping @Sendable (_ displayPath: String, _ index: Int) async throws -> Void = { _, _ in },
        afterStagingCreate: @escaping @Sendable (_ displayPath: String, _ kind: CapabilityRestoreSecureJournalItem.Kind) throws -> Void = { _, _ in },
        afterPublish: @escaping @Sendable (_ displayPath: String, _ isDirectory: Bool) throws -> Void = { _, _ in },
        beforeCleanupRemoval: @escaping @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ isolatedName: String) throws -> Void = { _, _, _ in },
        beforeQuarantineMove: @escaping @Sendable (_ displayPath: String, _ sourceParentDescriptor: Int32, _ sourceName: String, _ quarantineDescriptor: Int32, _ quarantineName: String) throws -> Void = { _, _, _, _, _ in },
        immediatelyBeforeQuarantineRename: @escaping @Sendable (_ displayPath: String, _ sourceParentDescriptor: Int32, _ sourceName: String) throws -> Void = { _, _, _ in },
        afterSymbolicLinkPathStat: @escaping @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ stagingName: String) throws -> Void = { _, _, _ in },
        beforeSymbolicLinkPublish: @escaping @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ stagingName: String) throws -> Void = { _, _, _ in },
        afterSymbolicLinkPublish: @escaping @Sendable (_ displayPath: String, _ parentDescriptor: Int32, _ finalName: String) throws -> Void = { _, _, _ in },
        shouldFailCleanup: @escaping @Sendable (_ displayPath: String) -> Bool = { _ in false },
        shouldFailDirectoryChmod: @escaping @Sendable (_ displayPath: String) -> Bool = { _ in false },
        shouldFailQuarantineCreation: @escaping @Sendable (_ rootURL: URL) -> Bool = { _ in false }
    ) {
        self.beforeWrite = beforeWrite
        self.afterStagingCreate = afterStagingCreate
        self.afterPublish = afterPublish
        self.beforeCleanupRemoval = beforeCleanupRemoval
        self.beforeQuarantineMove = beforeQuarantineMove
        self.immediatelyBeforeQuarantineRename = immediatelyBeforeQuarantineRename
        self.afterSymbolicLinkPathStat = afterSymbolicLinkPathStat
        self.beforeSymbolicLinkPublish = beforeSymbolicLinkPublish
        self.afterSymbolicLinkPublish = afterSymbolicLinkPublish
        self.shouldFailCleanup = shouldFailCleanup
        self.shouldFailDirectoryChmod = shouldFailDirectoryChmod
        self.shouldFailQuarantineCreation = shouldFailQuarantineCreation
    }

    static let none = CapabilityRestoreTestHooks()
}

struct CapabilityRestoreFileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        mode = UInt32(value.st_mode)
    }

    var fileType: UInt32 { mode & UInt32(S_IFMT) }
    var isDirectory: Bool { fileType == UInt32(S_IFDIR) }
    var isRegularFile: Bool { fileType == UInt32(S_IFREG) }
    var isSymbolicLink: Bool { fileType == UInt32(S_IFLNK) }
    var isExecutable: Bool { mode & 0o111 != 0 }

    func isSameObject(as other: CapabilityRestoreFileIdentity) -> Bool {
        device == other.device && inode == other.inode && fileType == other.fileType
    }
}

struct CapabilityRestoreSecureDestination: Sendable {
    let anchorURL: URL
    let components: [String]
    let capabilityRootComponentCount: Int
    let displayPath: String
}

struct CapabilityRestoreSecureSnapshot: Sendable {
    let exists: Bool
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let byteSize: Int64?
    let sha256: String?
    let executable: Bool?
    let previewData: Data?

    static let missing = CapabilityRestoreSecureSnapshot(
        exists: false,
        isDirectory: false,
        isSymbolicLink: false,
        byteSize: nil,
        sha256: nil,
        executable: nil,
        previewData: nil
    )
}

final class CapabilityRestoreSecureRoot: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    let identity: CapabilityRestoreFileIdentity

    init(url: URL, descriptor: Int32, identity: CapabilityRestoreFileIdentity) {
        self.url = url
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit { Darwin.close(descriptor) }
}

final class CapabilityRestoreSecureJournalItem: @unchecked Sendable {
    enum Kind: Sendable, Equatable {
        case regular
        case symbolicLink
        case directory
    }

    let parentDescriptor: Int32
    let name: String
    let stagingName: String
    let displayPath: String
    var identity: CapabilityRestoreFileIdentity?
    let kind: Kind
    let sha256: String?
    let executable: Bool?
    private(set) var objectDescriptor: Int32 = -1
    let quarantine: CapabilityRestoreSecureQuarantine
    private(set) var isCreated = false
    private(set) var isPublished = false

    var isDirectory: Bool { kind == .directory }
    var activeName: String { isPublished ? name : stagingName }

    init(
        parentDescriptor: Int32,
        name: String,
        stagingName: String,
        displayPath: String,
        kind: Kind,
        quarantine: CapabilityRestoreSecureQuarantine,
        sha256: String? = nil,
        executable: Bool? = nil
    ) throws {
        let parentDuplicate = try Self.duplicateCloseOnExec(parentDescriptor)
        self.parentDescriptor = parentDuplicate
        self.name = name
        self.stagingName = stagingName
        self.displayPath = displayPath
        self.identity = nil
        self.kind = kind
        self.quarantine = quarantine
        self.sha256 = sha256
        self.executable = executable
    }

    func markCreated() { isCreated = true }
    func markPublished() { isPublished = true }

    func bindObject(descriptor: Int32, identity: CapabilityRestoreFileIdentity) throws {
        let duplicate = try Self.duplicateCloseOnExec(descriptor)
        if objectDescriptor >= 0 { Darwin.close(objectDescriptor) }
        objectDescriptor = duplicate
        self.identity = identity
    }

    deinit {
        Darwin.close(parentDescriptor)
        if objectDescriptor >= 0 { Darwin.close(objectDescriptor) }
    }

    private static func duplicateCloseOnExec(_ descriptor: Int32) throws -> Int32 {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw CapabilityRestoreError.writeFailed }
        guard Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(duplicate)
            throw CapabilityRestoreError.writeFailed
        }
        return duplicate
    }
}

final class CapabilityRestoreSecureQuarantine: @unchecked Sendable {
    let root: CapabilityRestoreSecureRoot
    let name: String
    let descriptor: Int32
    let location: CapabilityRestoreQuarantineLocation
    let identity: CapabilityRestoreFileIdentity

    init(
        root: CapabilityRestoreSecureRoot,
        name: String,
        descriptor: Int32,
        location: CapabilityRestoreQuarantineLocation,
        identity: CapabilityRestoreFileIdentity
    ) {
        self.root = root
        self.name = name
        self.descriptor = descriptor
        self.location = location
        self.identity = identity
    }

    deinit { Darwin.close(descriptor) }
}

struct CapabilityRestoreSecureFileSystem: Sendable {
    private final class OwnedDescriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { Darwin.close(value) }
    }

    private struct DirectoryBinding {
        let parent: Int32
        let name: String
        let child: OwnedDescriptor
        let identity: CapabilityRestoreFileIdentity
    }

    private struct DirectoryChain {
        let root: CapabilityRestoreSecureRoot
        let bindings: [DirectoryBinding]

        var parentDescriptor: Int32 { bindings.last?.child.value ?? root.descriptor }

        func validate() throws {
            try CapabilityRestoreSecureFileSystem.validateCurrentBinding(of: root)
            for binding in bindings {
                var current = stat()
                guard Darwin.fstatat(binding.parent, binding.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      CapabilityRestoreFileIdentity(current).isSameObject(as: binding.identity) else {
                    throw CapabilityRestoreError.targetChanged
                }
            }
        }
    }

    static func anchorIdentity(at url: URL) throws -> CapabilityRestoreFileIdentity {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw CapabilityRestoreError.destinationNotWritable
        }
        let identity = CapabilityRestoreFileIdentity(value)
        guard identity.isDirectory, !identity.isSymbolicLink else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        return identity
    }

    static func openRoot(
        at url: URL,
        expectedIdentity: CapabilityRestoreFileIdentity
    ) throws -> CapabilityRestoreSecureRoot {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CapabilityRestoreError.targetChanged }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            Darwin.close(descriptor)
            throw CapabilityRestoreError.destinationNotWritable
        }
        let identity = CapabilityRestoreFileIdentity(value)
        guard identity.isSameObject(as: expectedIdentity), identity.isDirectory else {
            Darwin.close(descriptor)
            throw CapabilityRestoreError.targetChanged
        }
        return CapabilityRestoreSecureRoot(url: url, descriptor: descriptor, identity: identity)
    }

    static func validateCurrentBinding(of root: CapabilityRestoreSecureRoot) throws {
        guard try anchorIdentity(at: root.url).isSameObject(as: root.identity) else {
            throw CapabilityRestoreError.targetChanged
        }
    }

    /// Creates every operation-owned quarantine before the first restore target
    /// write. Directories are mode 0700 and never automatically removed. Their
    /// raw URLs exist only in the returned in-memory reveal handles.
    func prepareQuarantines(
        roots: [String: CapabilityRestoreSecureRoot],
        operationID: UUID,
        hooks: CapabilityRestoreTestHooks,
        locations: inout [CapabilityRestoreQuarantineLocation]
    ) throws -> [String: CapabilityRestoreSecureQuarantine] {
        var result: [String: CapabilityRestoreSecureQuarantine] = [:]
        for (index, key) in roots.keys.sorted().enumerated() {
            guard let root = roots[key] else { throw CapabilityRestoreError.targetChanged }
            try Self.validateCurrentBinding(of: root)
            guard !hooks.shouldFailQuarantineCreation(root.url) else {
                throw CapabilityRestoreError.destinationNotWritable
            }
            let name = ".CodexDirectorRestoreQuarantine-\(operationID.uuidString)-\(index + 1)"
            guard Darwin.mkdirat(root.descriptor, name, mode_t(0o700)) == 0 else {
                throw CapabilityRestoreError.destinationNotWritable
            }
            let location = CapabilityRestoreQuarantineLocation(
                id: "quarantine-\(operationID.uuidString)-\(index + 1)",
                placeholder: "<restore-quarantine-\(index + 1)>",
                directoryURL: root.url.appendingPathComponent(name, isDirectory: true)
            )
            // Record the reveal handle immediately after mkdirat succeeds. If
            // opening or validating the directory fails, the preserved empty
            // directory remains visible in the structured failure result.
            locations.append(location)
            let descriptor = Darwin.openat(root.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CapabilityRestoreError.destinationNotWritable }
            var opened = stat()
            var linked = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  Darwin.fstatat(root.descriptor, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 else {
                Darwin.close(descriptor)
                throw CapabilityRestoreError.destinationNotWritable
            }
            let identity = CapabilityRestoreFileIdentity(opened)
            guard identity.isDirectory,
                  identity.isSameObject(as: CapabilityRestoreFileIdentity(linked)),
                  identity.mode & 0o7777 == 0o700 else {
                Darwin.close(descriptor)
                throw CapabilityRestoreError.targetChanged
            }
            result[key] = CapabilityRestoreSecureQuarantine(
                root: root,
                name: name,
                descriptor: descriptor,
                location: location,
                identity: identity
            )
        }
        return result
    }

    func write(
        source: URL,
        entry: CapabilityPackageEntry,
        destination: CapabilityRestoreSecureDestination,
        root: CapabilityRestoreSecureRoot,
        quarantine: CapabilityRestoreSecureQuarantine,
        hooks: CapabilityRestoreTestHooks,
        created: inout [CapabilityRestoreSecureJournalItem]
    ) throws {
        guard !destination.components.isEmpty,
              destination.capabilityRootComponentCount <= destination.components.count,
              destination.components.allSatisfy(Self.isSafeComponent) else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        try Self.validateCurrentBinding(of: root)
        let parentComponents = Array(destination.components.dropLast())
        let name = destination.components.last!
        let chain = try openDirectoryChain(
            root: root,
            components: parentComponents,
            displayPath: destination.displayPath,
            quarantine: quarantine,
            hooks: hooks,
            created: &created
        )
        try chain.validate()
        try requireMissing(name: name, in: chain.parentDescriptor)

        var sourceInfo = stat()
        guard Darwin.lstat(source.path, &sourceInfo) == 0 else {
            throw CapabilityRestoreError.packageChanged
        }
        let sourceIdentity = CapabilityRestoreFileIdentity(sourceInfo)
        if sourceIdentity.isSymbolicLink {
            try writeSymbolicLink(
                source: source,
                entry: entry,
                destination: destination,
                name: name,
                chain: chain,
                quarantine: quarantine,
                hooks: hooks,
                created: &created
            )
        } else if sourceIdentity.isRegularFile {
            try writeRegularFile(
                source: source,
                entry: entry,
                destination: destination,
                name: name,
                chain: chain,
                quarantine: quarantine,
                hooks: hooks,
                created: &created
            )
        } else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
    }

    /// Reads an existing target without resolving any directory or final-item
    /// symlink. The same descriptor chain is revalidated after the read so a
    /// concurrent ancestry replacement becomes `targetChanged` rather than a
    /// read from outside the approved root.
    func snapshot(
        destination: CapabilityRestoreSecureDestination,
        root: CapabilityRestoreSecureRoot,
        previewDataLimit: Int = 128_000
    ) throws -> CapabilityRestoreSecureSnapshot {
        guard !destination.components.isEmpty,
              destination.components.allSatisfy(Self.isSafeComponent) else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        try Self.validateCurrentBinding(of: root)
        guard let chain = try openExistingDirectoryChain(
            root: root,
            components: Array(destination.components.dropLast())
        ) else { return .missing }
        let name = destination.components.last!
        var value = stat()
        if Darwin.fstatat(chain.parentDescriptor, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return .missing }
            throw CapabilityRestoreError.destinationNotWritable
        }
        let identity = CapabilityRestoreFileIdentity(value)
        let data: Data?
        let byteSize: Int64?
        let digest: String?
        let executable: Bool?
        if identity.isSymbolicLink {
            let target = try readSymbolicLink(name: name, in: chain.parentDescriptor)
            let targetData = Data(target.utf8)
            data = targetData.count <= previewDataLimit ? targetData : nil
            byteSize = Int64(targetData.count)
            digest = Self.sha256(targetData)
            executable = nil
        } else if identity.isDirectory {
            data = nil
            byteSize = 0
            digest = Self.sha256(Data())
            executable = false
        } else if identity.isRegularFile {
            let descriptor = Darwin.openat(chain.parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CapabilityRestoreError.targetChanged }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  CapabilityRestoreFileIdentity(opened).isSameObject(as: identity) else {
                throw CapabilityRestoreError.targetChanged
            }
            let contents = try readAll(from: descriptor)
            data = contents.count <= previewDataLimit ? contents : nil
            byteSize = Int64(contents.count)
            digest = Self.sha256(contents)
            executable = CapabilityRestoreFileIdentity(opened).isExecutable
        } else {
            data = nil
            byteSize = nil
            digest = nil
            executable = nil
        }
        try chain.validate()
        var finalValue = stat()
        guard Darwin.fstatat(chain.parentDescriptor, name, &finalValue, AT_SYMLINK_NOFOLLOW) == 0,
              CapabilityRestoreFileIdentity(finalValue).isSameObject(as: identity) else {
            throw CapabilityRestoreError.targetChanged
        }
        return CapabilityRestoreSecureSnapshot(
            exists: true,
            isDirectory: identity.isDirectory,
            isSymbolicLink: identity.isSymbolicLink,
            byteSize: byteSize,
            sha256: digest,
            executable: executable,
            previewData: data
        )
    }

    func cleanup(
        _ items: [CapabilityRestoreSecureJournalItem],
        hooks: CapabilityRestoreTestHooks,
        quarantineLocations: [CapabilityRestoreQuarantineLocation],
        quarantinePreparationFailed: Bool = false
    ) -> CapabilityRestoreCleanupResult {
        var quarantined = 0
        var quarantinedDirectories = 0
        var skippedModified = 0
        var failedRemoval = 0
        var issues: [CapabilityRestoreIssue] = []

        if quarantinePreparationFailed {
            failedRemoval += 1
            issues.append(CapabilityRestoreIssue(
                severity: .blocking,
                code: "cleanup_quarantine_unavailable",
                message: "A private quarantine could not be prepared, so no restore target writes were started."
            ))
        }

        for item in items.reversed() {
            guard item.isCreated else { continue }
            let activeName = item.activeName
            let quarantineName = "item-\(UUID().uuidString)"

            guard quarantineIsSecurelyBound(item.quarantine) else {
                failedRemoval += 1
                issues.append(cleanupIssue(
                    code: "cleanup_quarantine_move_failed",
                    item: item,
                    message: "The private quarantine changed, so the created item was preserved in place."
                ))
                continue
            }

            // Never move an object whose stable descriptor could not be bound.
            // mkdirat/symlinkat can succeed immediately before an open/fstat
            // fault. The journal proves that creation was attempted, but a
            // mutable pathname alone cannot prove that the current object is
            // still ours. Preserve it in place and report the residual instead
            // of risking movement of a replacement.
            guard item.objectDescriptor >= 0, item.identity != nil else {
                failedRemoval += 1
                issues.append(cleanupIssue(
                    code: "cleanup_unverified_staging_preserved",
                    item: item,
                    message: "A newly created staging item could not be bound to a stable descriptor and was preserved in place."
                ))
                continue
            }

            // A bound object is moved only after its public or staging name is
            // still the exact object created by this operation and its recorded
            // bytes/type/mode remain unchanged.
            if !nameStillIdentifies(item, name: activeName)
                || !itemMatchesRecordedState(item, name: activeName) {
                skippedModified += 1
                let missing = !nameExists(activeName, in: item.parentDescriptor)
                issues.append(cleanupIssue(
                    code: missing ? "cleanup_target_missing" : (item.kind == .directory ? "cleanup_directory_changed" : "cleanup_target_modified"),
                    item: item,
                    message: missing
                        ? "A created item was moved or renamed and was preserved wherever it now resides."
                        : "A created item changed or was replaced and was preserved at its current location."
                ))
                continue
            }

            do {
                try hooks.beforeCleanupRemoval(item.displayPath, item.parentDescriptor, activeName)
                try hooks.beforeQuarantineMove(
                    item.displayPath,
                    item.parentDescriptor,
                    activeName,
                    item.quarantine.descriptor,
                    quarantineName
                )
            } catch {
                failedRemoval += 1
                issues.append(cleanupIssue(
                    code: "cleanup_quarantine_move_failed",
                    item: item,
                    message: "A created item could not be moved to private quarantine and was preserved in place."
                ))
                continue
            }

            // Recheck after the race hook. Any observed replacement or mutation
            // stays in place. There is no unlink in this production path.
            if !nameStillIdentifies(item, name: activeName)
                || !itemMatchesRecordedState(item, name: activeName) {
                skippedModified += 1
                let missing = !nameExists(activeName, in: item.parentDescriptor)
                issues.append(cleanupIssue(
                    code: missing ? "cleanup_target_missing" : "cleanup_target_changed",
                    item: item,
                    message: missing
                        ? "A created item was moved or renamed and was preserved wherever it now resides."
                        : "A created item changed before quarantine and was preserved in place."
                ))
                continue
            }
            if hooks.shouldFailCleanup(item.displayPath) {
                failedRemoval += 1
                issues.append(cleanupIssue(
                    code: "cleanup_quarantine_move_failed",
                    item: item,
                    message: "A created item could not be moved to private quarantine and was preserved in place."
                ))
                continue
            }

            do {
                try hooks.immediatelyBeforeQuarantineRename(
                    item.displayPath,
                    item.parentDescriptor,
                    activeName
                )
            } catch {
                failedRemoval += 1
                issues.append(cleanupIssue(
                    code: "cleanup_quarantine_move_failed",
                    item: item,
                    message: "A created item could not be moved to private quarantine and was preserved in place."
                ))
                continue
            }

            guard Darwin.renameatx_np(
                item.parentDescriptor,
                activeName,
                item.quarantine.descriptor,
                quarantineName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == ENOENT {
                    skippedModified += 1
                    issues.append(cleanupIssue(
                        code: "cleanup_target_missing",
                        item: item,
                        message: "A created item was moved or renamed and was preserved wherever it now resides."
                    ))
                } else {
                    failedRemoval += 1
                    issues.append(cleanupIssue(
                        code: "cleanup_quarantine_move_failed",
                        item: item,
                        message: "A created item could not be moved to private quarantine and was preserved in place."
                    ))
                }
                continue
            }

            // If the source name was replaced in the final check-to-rename
            // interval, restore the moved replacement to its original name.
            // Failure to restore is still non-destructive: both objects remain
            // preserved and the uncertainty is reported.
            if !quarantineIsSecurelyBound(item.quarantine)
                || !quarantineNameIdentifies(item, name: quarantineName)
                || !itemMatchesRecordedStateInQuarantine(item, name: quarantineName) {
                skippedModified += 1
                if Darwin.renameatx_np(
                    item.quarantine.descriptor,
                    quarantineName,
                    item.parentDescriptor,
                    activeName,
                    UInt32(RENAME_EXCL)
                ) == 0 {
                    issues.append(cleanupIssue(
                        code: "cleanup_target_changed",
                        item: item,
                        message: "A replacement won the quarantine race and was restored to its original name."
                    ))
                } else {
                    issues.append(cleanupIssue(
                        code: "cleanup_preserved_isolated",
                        item: item,
                        message: "A replacement could not be restored and remains preserved in private quarantine."
                    ))
                }
                continue
            }

            if item.kind == .directory {
                quarantinedDirectories += 1
            } else {
                quarantined += 1
            }
            issues.append(cleanupIssue(
                code: "cleanup_preserved_isolated",
                item: item,
                message: "A created item was moved out of its logical restore path and remains preserved in private quarantine."
            ))
        }

        return CapabilityRestoreCleanupResult(
            removedCount: 0,
            removedDirectoryCount: 0,
            skippedModifiedCount: skippedModified,
            failedRemovalCount: failedRemoval,
            issues: issues,
            quarantinedCount: quarantined,
            quarantinedDirectoryCount: quarantinedDirectories,
            quarantineLocations: quarantineLocations
        )
    }

    private func openDirectoryChain(
        root: CapabilityRestoreSecureRoot,
        components: [String],
        displayPath: String,
        quarantine: CapabilityRestoreSecureQuarantine,
        hooks: CapabilityRestoreTestHooks,
        created: inout [CapabilityRestoreSecureJournalItem]
    ) throws -> DirectoryChain {
        var bindings: [DirectoryBinding] = []
        var parent = root.descriptor
        for (index, component) in components.enumerated() {
            guard Self.isSafeComponent(component) else { throw CapabilityRestoreError.unsafeArchivePath }
            var descriptor = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 && errno == ENOENT {
                let stagingName = ".CodexDirectorRestore-\(UUID().uuidString).dir"
                let relativeDisplay = components.prefix(index + 1).joined(separator: "/")
                // Pre-journal before mkdirat. Once creation succeeds, every
                // following open/fstat/fchmod/validation failure has a cleanup
                // record even when no stable object descriptor was obtained.
                let directoryItem = try CapabilityRestoreSecureJournalItem(
                    parentDescriptor: parent,
                    name: component,
                    stagingName: stagingName,
                    displayPath: "\(displayPath) [directory: \(relativeDisplay)]",
                    kind: .directory,
                    quarantine: quarantine
                )
                created.append(directoryItem)
                guard Darwin.mkdirat(parent, stagingName, mode_t(0o700)) == 0 else {
                    if errno == EEXIST { throw CapabilityRestoreError.targetChanged }
                    throw CapabilityRestoreError.destinationNotWritable
                }
                directoryItem.markCreated()
                try hooks.afterStagingCreate(directoryItem.displayPath, .directory)
                descriptor = Darwin.openat(parent, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw CapabilityRestoreError.targetChanged }
                var createdInfo = stat()
                guard Darwin.fstat(descriptor, &createdInfo) == 0 else {
                    Darwin.close(descriptor)
                    throw CapabilityRestoreError.writeFailed
                }
                try directoryItem.bindObject(
                    descriptor: descriptor,
                    identity: CapabilityRestoreFileIdentity(createdInfo)
                )
                guard !hooks.shouldFailDirectoryChmod(directoryItem.displayPath),
                      Darwin.fchmod(descriptor, mode_t(0o755)) == 0,
                      Darwin.fstat(descriptor, &createdInfo) == 0 else {
                    throw CapabilityRestoreError.writeFailed
                }
                directoryItem.identity = CapabilityRestoreFileIdentity(createdInfo)
                guard Darwin.renameatx_np(
                    parent,
                    stagingName,
                    parent,
                    component,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    if errno == EEXIST { throw CapabilityRestoreError.targetChanged }
                    throw CapabilityRestoreError.writeFailed
                }
                directoryItem.markPublished()
                try hooks.afterPublish(directoryItem.displayPath, true)
            } else if descriptor < 0 {
                if errno == ELOOP || errno == ENOTDIR { throw CapabilityRestoreError.targetChanged }
                throw CapabilityRestoreError.destinationNotWritable
            }

            let owned = OwnedDescriptor(descriptor)
            var childInfo = stat()
            guard Darwin.fstat(descriptor, &childInfo) == 0 else {
                throw CapabilityRestoreError.writeFailed
            }
            let identity = CapabilityRestoreFileIdentity(childInfo)
            guard identity.isDirectory else { throw CapabilityRestoreError.targetChanged }
            var linkedInfo = stat()
            guard Darwin.fstatat(parent, component, &linkedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  CapabilityRestoreFileIdentity(linkedInfo).isSameObject(as: identity) else {
                throw CapabilityRestoreError.targetChanged
            }
            bindings.append(DirectoryBinding(parent: parent, name: component, child: owned, identity: identity))
            parent = descriptor
        }
        return DirectoryChain(root: root, bindings: bindings)
    }

    private func openExistingDirectoryChain(
        root: CapabilityRestoreSecureRoot,
        components: [String]
    ) throws -> DirectoryChain? {
        var bindings: [DirectoryBinding] = []
        var parent = root.descriptor
        for component in components {
            guard Self.isSafeComponent(component) else { throw CapabilityRestoreError.unsafeArchivePath }
            let descriptor = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 && errno == ENOENT { return nil }
            guard descriptor >= 0 else {
                if errno == ELOOP || errno == ENOTDIR { throw CapabilityRestoreError.unsafeArchivePath }
                throw CapabilityRestoreError.destinationNotWritable
            }
            let owned = OwnedDescriptor(descriptor)
            var childInfo = stat()
            guard Darwin.fstat(descriptor, &childInfo) == 0 else { throw CapabilityRestoreError.destinationNotWritable }
            let identity = CapabilityRestoreFileIdentity(childInfo)
            guard identity.isDirectory else { throw CapabilityRestoreError.unsafeArchivePath }
            var linkedInfo = stat()
            guard Darwin.fstatat(parent, component, &linkedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  CapabilityRestoreFileIdentity(linkedInfo).isSameObject(as: identity) else {
                throw CapabilityRestoreError.targetChanged
            }
            bindings.append(DirectoryBinding(parent: parent, name: component, child: owned, identity: identity))
            parent = descriptor
        }
        let chain = DirectoryChain(root: root, bindings: bindings)
        try chain.validate()
        return chain
    }

    private func requireMissing(name: String, in parent: Int32) throws {
        var value = stat()
        if Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 {
            throw CapabilityRestoreError.targetChanged
        }
        guard errno == ENOENT else { throw CapabilityRestoreError.destinationNotWritable }
    }

    private func writeRegularFile(
        source: URL,
        entry: CapabilityPackageEntry,
        destination: CapabilityRestoreSecureDestination,
        name: String,
        chain: DirectoryChain,
        quarantine: CapabilityRestoreSecureQuarantine,
        hooks: CapabilityRestoreTestHooks,
        created: inout [CapabilityRestoreSecureJournalItem]
    ) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard Int64(data.count) == entry.byteSize, Self.sha256(data) == entry.sha256 else {
            throw CapabilityRestoreError.packageChanged
        }
        let stagingName = ".CodexDirectorRestore-\(UUID().uuidString).tmp"
        let publishedItem = try CapabilityRestoreSecureJournalItem(
            parentDescriptor: chain.parentDescriptor,
            name: name,
            stagingName: stagingName,
            displayPath: destination.displayPath,
            kind: .regular,
            quarantine: quarantine,
            sha256: entry.sha256,
            executable: entry.executable
        )
        created.append(publishedItem)
        let descriptor = Darwin.openat(
            chain.parentDescriptor,
            stagingName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw CapabilityRestoreError.writeFailed }
        let stagingDescriptor = OwnedDescriptor(descriptor)
        publishedItem.markCreated()
        try hooks.afterStagingCreate(destination.displayPath, .regular)
        var temporaryInfo = stat()
        guard Darwin.fstat(descriptor, &temporaryInfo) == 0 else { throw CapabilityRestoreError.writeFailed }
        try publishedItem.bindObject(
            descriptor: descriptor,
            identity: CapabilityRestoreFileIdentity(temporaryInfo)
        )
        try writeAll(data, to: stagingDescriptor.value)
        let permissions = mode_t(entry.executable ? 0o755 : 0o644)
        guard Darwin.fchmod(descriptor, permissions) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &temporaryInfo) == 0 else {
            throw CapabilityRestoreError.writeFailed
        }
        let finalIdentity = CapabilityRestoreFileIdentity(temporaryInfo)
        publishedItem.identity = finalIdentity
        guard Darwin.renameatx_np(
            chain.parentDescriptor,
            stagingName,
            chain.parentDescriptor,
            name,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw CapabilityRestoreError.targetChanged }
            throw CapabilityRestoreError.writeFailed
        }
        publishedItem.markPublished()
        try hooks.afterPublish(destination.displayPath, false)
        var linkedInfo = stat()
        guard Darwin.fstatat(chain.parentDescriptor, name, &linkedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              CapabilityRestoreFileIdentity(linkedInfo).isSameObject(as: finalIdentity) else {
            throw CapabilityRestoreError.targetChanged
        }
        try chain.validate()
    }

    private func writeSymbolicLink(
        source: URL,
        entry: CapabilityPackageEntry,
        destination: CapabilityRestoreSecureDestination,
        name: String,
        chain: DirectoryChain,
        quarantine: CapabilityRestoreSecureQuarantine,
        hooks: CapabilityRestoreTestHooks,
        created: inout [CapabilityRestoreSecureJournalItem]
    ) throws {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        guard Self.safeSymlinkTarget(target, destination: destination),
              Int64(target.utf8.count) == entry.byteSize,
              Self.sha256(Data(target.utf8)) == entry.sha256 else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        try validateResolvedSymbolicLinkTarget(
            target,
            destination: destination,
            root: chain.root
        )
        let stagingName = ".CodexDirectorRestore-\(UUID().uuidString).symlink"
        let publishedItem = try CapabilityRestoreSecureJournalItem(
            parentDescriptor: chain.parentDescriptor,
            name: name,
            stagingName: stagingName,
            displayPath: destination.displayPath,
            kind: .symbolicLink,
            quarantine: quarantine,
            sha256: entry.sha256
        )
        created.append(publishedItem)
        guard Darwin.symlinkat(target, chain.parentDescriptor, stagingName) == 0 else {
            if errno == EEXIST { throw CapabilityRestoreError.targetChanged }
            throw CapabilityRestoreError.writeFailed
        }
        publishedItem.markCreated()
        try hooks.afterStagingCreate(destination.displayPath, .symbolicLink)
        var pathInfo = stat()
        guard Darwin.fstatat(chain.parentDescriptor, stagingName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CapabilityRestoreError.writeFailed
        }
        let pathIdentity = CapabilityRestoreFileIdentity(pathInfo)
        guard pathIdentity.isSymbolicLink else { throw CapabilityRestoreError.targetChanged }
        try hooks.afterSymbolicLinkPathStat(
            destination.displayPath,
            chain.parentDescriptor,
            stagingName
        )
        let objectDescriptor = Darwin.openat(
            chain.parentDescriptor,
            stagingName,
            O_RDONLY | O_SYMLINK | O_CLOEXEC
        )
        guard objectDescriptor >= 0 else { throw CapabilityRestoreError.writeFailed }
        defer { Darwin.close(objectDescriptor) }
        var openedInfo = stat()
        guard Darwin.fstat(objectDescriptor, &openedInfo) == 0 else {
            throw CapabilityRestoreError.writeFailed
        }
        let openedIdentity = CapabilityRestoreFileIdentity(openedInfo)
        guard openedIdentity.isSymbolicLink, openedIdentity == pathIdentity else {
            throw CapabilityRestoreError.targetChanged
        }
        // Bind only the identity obtained from the held O_SYMLINK descriptor,
        // after matching it to the first no-follow pathname observation.
        try publishedItem.bindObject(descriptor: objectDescriptor, identity: openedIdentity)
        try validateResolvedSymbolicLinkTarget(
            target,
            destination: destination,
            root: chain.root
        )
        try hooks.beforeSymbolicLinkPublish(
            destination.displayPath,
            chain.parentDescriptor,
            stagingName
        )
        var prepublishInfo = stat()
        guard Darwin.fstatat(
            chain.parentDescriptor,
            stagingName,
            &prepublishInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            CapabilityRestoreFileIdentity(prepublishInfo) == openedIdentity,
            try readSymbolicLink(name: stagingName, in: chain.parentDescriptor) == target,
            Darwin.fstatat(
                chain.parentDescriptor,
                stagingName,
                &prepublishInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            CapabilityRestoreFileIdentity(prepublishInfo) == openedIdentity else {
            throw CapabilityRestoreError.targetChanged
        }
        guard Darwin.renameatx_np(
            chain.parentDescriptor,
            stagingName,
            chain.parentDescriptor,
            name,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw CapabilityRestoreError.targetChanged }
            throw CapabilityRestoreError.writeFailed
        }
        publishedItem.markPublished()
        try hooks.afterPublish(destination.displayPath, false)
        try hooks.afterSymbolicLinkPublish(
            destination.displayPath,
            chain.parentDescriptor,
            name
        )
        var finalInfo = stat()
        guard Darwin.fstatat(
            chain.parentDescriptor,
            name,
            &finalInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            CapabilityRestoreFileIdentity(finalInfo) == openedIdentity,
            try readSymbolicLink(name: name, in: chain.parentDescriptor) == target,
            Darwin.fstatat(
                chain.parentDescriptor,
                name,
                &finalInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            CapabilityRestoreFileIdentity(finalInfo) == openedIdentity else {
            throw CapabilityRestoreError.targetChanged
        }
        try validateResolvedSymbolicLinkTarget(
            target,
            destination: destination,
            root: chain.root
        )
        try chain.validate()
    }

    private func itemMatchesRecordedState(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String
    ) -> Bool {
        itemMatchesRecordedState(item, name: name, parentDescriptor: item.parentDescriptor)
    }

    private func itemMatchesRecordedStateInQuarantine(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String
    ) -> Bool {
        itemMatchesRecordedState(item, name: name, parentDescriptor: item.quarantine.descriptor)
    }

    private func itemMatchesRecordedState(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String,
        parentDescriptor: Int32
    ) -> Bool {
        guard item.objectDescriptor >= 0, let recordedIdentity = item.identity else { return false }
        switch item.kind {
        case .directory:
            var value = stat()
            guard Darwin.fstat(item.objectDescriptor, &value) == 0,
                  CapabilityRestoreFileIdentity(value).isSameObject(as: recordedIdentity) else {
                return false
            }
            return UInt32(value.st_mode) & 0o7777 == recordedIdentity.mode & 0o7777
                && directoryIsEmpty(item.objectDescriptor)
        case .regular:
            var value = stat()
            guard Darwin.fstat(item.objectDescriptor, &value) == 0,
                  CapabilityRestoreFileIdentity(value).isSameObject(as: recordedIdentity),
                  let data = try? readAll(from: item.objectDescriptor),
                  Self.sha256(data) == item.sha256 else { return false }
            let currentIdentity = CapabilityRestoreFileIdentity(value)
            return (item.executable == nil || currentIdentity.isExecutable == item.executable)
                && currentIdentity.mode & 0o7777 == recordedIdentity.mode & 0o7777
        case .symbolicLink:
            guard let target = try? readSymbolicLink(name: name, in: parentDescriptor) else { return false }
            return Self.sha256(Data(target.utf8)) == item.sha256
        }
    }

    private func directoryIsEmpty(_ descriptor: Int32) -> Bool {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return false }
        guard Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(duplicate)
            return false
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            return false
        }
        defer { Darwin.closedir(stream) }
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return false }
        }
        return errno == 0
    }

    private func nameStillIdentifies(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String
    ) -> Bool {
        nameIdentifies(item, name: name, parentDescriptor: item.parentDescriptor)
    }

    private func quarantineNameIdentifies(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String
    ) -> Bool {
        nameIdentifies(item, name: name, parentDescriptor: item.quarantine.descriptor)
    }

    private func nameIdentifies(
        _ item: CapabilityRestoreSecureJournalItem,
        name: String,
        parentDescriptor: Int32
    ) -> Bool {
        guard item.objectDescriptor >= 0 else { return false }
        var current = stat()
        var held = stat()
        return Darwin.fstatat(parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && Darwin.fstat(item.objectDescriptor, &held) == 0
            && CapabilityRestoreFileIdentity(current).isSameObject(as: CapabilityRestoreFileIdentity(held))
    }

    private func nameExists(_ name: String, in parentDescriptor: Int32) -> Bool {
        var value = stat()
        return Darwin.fstatat(parentDescriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0
    }

    private func quarantineIsSecurelyBound(
        _ quarantine: CapabilityRestoreSecureQuarantine
    ) -> Bool {
        guard (try? Self.validateCurrentBinding(of: quarantine.root)) != nil else { return false }
        var opened = stat()
        var linked = stat()
        guard Darwin.fstat(quarantine.descriptor, &opened) == 0,
              Darwin.fstatat(
                quarantine.root.descriptor,
                quarantine.name,
                &linked,
                AT_SYMLINK_NOFOLLOW
              ) == 0 else { return false }
        let openedIdentity = CapabilityRestoreFileIdentity(opened)
        return openedIdentity.isDirectory
            && openedIdentity.isSameObject(as: quarantine.identity)
            && openedIdentity.isSameObject(as: CapabilityRestoreFileIdentity(linked))
            && openedIdentity.mode & 0o7777 == 0o700
    }

    /// Resolves every component of a relative symlink target from the approved
    /// root descriptor. Existing symlinks are rejected at every position,
    /// including an intermediate directory that would redirect the final
    /// target outside the capability root.
    private func validateResolvedSymbolicLinkTarget(
        _ target: String,
        destination: CapabilityRestoreSecureDestination,
        root: CapabilityRestoreSecureRoot
    ) throws {
        guard let resolved = Self.resolvedSymbolicLinkComponents(
            target,
            destination: destination
        ), !resolved.isEmpty else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        try Self.validateCurrentBinding(of: root)
        guard let chain = try openExistingDirectoryChain(
            root: root,
            components: Array(resolved.dropLast())
        ) else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        var final = stat()
        guard Darwin.fstatat(
            chain.parentDescriptor,
            resolved.last!,
            &final,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        let identity = CapabilityRestoreFileIdentity(final)
        guard identity.isRegularFile || identity.isDirectory else {
            throw CapabilityRestoreError.unsafeArchivePath
        }
        try chain.validate()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CapabilityRestoreError.writeFailed }
                offset += written
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw CapabilityRestoreError.writeFailed }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CapabilityRestoreError.writeFailed }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private func readSymbolicLink(name: String, in parent: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 65_537)
        let count = Darwin.readlinkat(parent, name, &buffer, buffer.count - 1)
        guard count >= 0 else { throw CapabilityRestoreError.writeFailed }
        return String(
            decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func safeSymlinkTarget(
        _ target: String,
        destination: CapabilityRestoreSecureDestination
    ) -> Bool {
        resolvedSymbolicLinkComponents(target, destination: destination) != nil
    }

    private static func resolvedSymbolicLinkComponents(
        _ target: String,
        destination: CapabilityRestoreSecureDestination
    ) -> [String]? {
        guard !target.isEmpty,
              !(target as NSString).isAbsolutePath,
              !target.contains("\\"),
              !target.contains("\0") else { return nil }
        var resolved = Array(destination.components.dropLast())
        for raw in target.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw)
            if component == "." { continue }
            if component == ".." {
                guard resolved.count > destination.capabilityRootComponentCount else { return nil }
                resolved.removeLast()
            } else {
                guard isSafeComponent(component) else { return nil }
                resolved.append(component)
            }
        }
        guard Array(resolved.prefix(destination.capabilityRootComponentCount))
            == Array(destination.components.prefix(destination.capabilityRootComponentCount)) else {
            return nil
        }
        return resolved
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func cleanupIssue(
        code: String,
        item: CapabilityRestoreSecureJournalItem,
        message: String
    ) -> CapabilityRestoreIssue {
        CapabilityRestoreIssue(
            severity: .blocking,
            code: code,
            archivePath: item.displayPath,
            message: message
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
