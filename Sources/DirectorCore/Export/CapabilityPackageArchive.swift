import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

struct CapabilityPackageLimits: Sendable {
    var maxArchiveBytes: UInt64 = 512 * 1024 * 1024
    var maxEntries: Int = 20_000
    var maxRegularFileBytes: UInt64 = 64 * 1024 * 1024
    var maxTotalExpandedBytes: UInt64 = 512 * 1024 * 1024
    var maxMetadataFileBytes: UInt64 = 8 * 1024 * 1024
    var maxSymlinkBytes: UInt64 = 65_536
    var maxPathUTF8Bytes: Int = 4_096
    var maxPathDepth: Int = 64
}

struct CapabilityPackageFileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        fileType = value.st_mode & S_IFMT
    }
}

private struct CapabilityPackageFileStamp: Equatable {
    let identity: CapabilityPackageFileIdentity
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        identity = CapabilityPackageFileIdentity(value)
        size = value.st_size
        modifiedSeconds = Int(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(value.st_mtimespec.tv_nsec)
        changedSeconds = Int(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int(value.st_ctimespec.tv_nsec)
    }

    func hasSameContentAfterRename(as prior: Self) -> Bool {
        identity == prior.identity && size == prior.size
            && modifiedSeconds == prior.modifiedSeconds
            && modifiedNanoseconds == prior.modifiedNanoseconds
    }
}

enum CapabilityPackageTemporaryItems {
    static func identity(at url: URL) -> CapabilityPackageFileIdentity? {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { return nil }
        return CapabilityPackageFileIdentity(value)
    }

    static func snapshotTree(at url: URL) throws -> [String: CapabilityPackageFileIdentity] {
        let rootFD = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CapabilityExportError.invalidArchive }
        defer { Darwin.close(rootFD) }
        var snapshot: [String: CapabilityPackageFileIdentity] = [:]
        try collect(in: rootFD, prefix: "", into: &snapshot)
        return snapshot
    }

    static func removeOwned(
        at url: URL,
        identity: CapabilityPackageFileIdentity?,
        knownContents: [String: CapabilityPackageFileIdentity]? = nil,
        afterQuarantine: (@Sendable (URL) -> Void)? = nil
    ) {
        guard let identity else { return }
        let parent = url.deletingLastPathComponent()
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { return }
        defer { Darwin.close(parentFD) }
        var current = stat()
        guard Darwin.fstatat(parentFD, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              CapabilityPackageFileIdentity(current) == identity else { return }
        let quarantineName = ".CodexDirectorOwnedCleanup-\(UUID().uuidString)"
        guard Darwin.renameatx_np(
            parentFD, url.lastPathComponent, parentFD, quarantineName, UInt32(RENAME_EXCL)
        ) == 0 else { return }
        afterQuarantine?(parent.appendingPathComponent(quarantineName))
        var moved = stat()
        guard Darwin.fstatat(parentFD, quarantineName, &moved, AT_SYMLINK_NOFOLLOW) == 0,
              CapabilityPackageFileIdentity(moved) == identity else { return }
        if identity.fileType == S_IFDIR {
            let rootFD = Darwin.openat(parentFD, quarantineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { return }
            defer { Darwin.close(rootFD) }
            var opened = stat()
            guard Darwin.fstat(rootFD, &opened) == 0,
                  CapabilityPackageFileIdentity(opened) == identity else { return }
            let snapshot: [String: CapabilityPackageFileIdentity]
            if let knownContents {
                snapshot = knownContents
            } else {
                var captured: [String: CapabilityPackageFileIdentity] = [:]
                guard (try? collect(in: rootFD, prefix: "", into: &captured)) != nil else { return }
                snapshot = captured
            }
            guard (try? removeContents(in: rootFD, prefix: "", snapshot: snapshot)) == true,
                  identityOfEntry(quarantineName, in: parentFD) == identity else { return }
            _ = Darwin.unlinkat(parentFD, quarantineName, AT_REMOVEDIR)
        } else if identity.fileType == S_IFREG,
                  identityOfEntry(quarantineName, in: parentFD) == identity {
            _ = Darwin.unlinkat(parentFD, quarantineName, 0)
        }
    }

    private static func collect(
        in directory: Int32,
        prefix: String,
        into snapshot: inout [String: CapabilityPackageFileIdentity]
    ) throws {
        for name in try names(in: directory) {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard let identity = identityOfEntry(name, in: directory) else {
                throw CapabilityExportError.invalidArchive
            }
            snapshot[path] = identity
            if identity.fileType == S_IFDIR {
                let child = Darwin.openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw CapabilityExportError.invalidArchive }
                defer { Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      CapabilityPackageFileIdentity(opened) == identity else {
                    throw CapabilityExportError.invalidArchive
                }
                try collect(in: child, prefix: path, into: &snapshot)
            }
        }
    }

    private static func removeContents(
        in directory: Int32,
        prefix: String,
        snapshot: [String: CapabilityPackageFileIdentity]
    ) throws -> Bool {
        var allRemoved = true
        for name in try names(in: directory) {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard let expected = snapshot[path], identityOfEntry(name, in: directory) == expected else {
                allRemoved = false
                continue
            }
            if expected.fileType == S_IFDIR {
                let child = Darwin.openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { allRemoved = false; continue }
                defer { Darwin.close(child) }
                var opened = stat()
                let bound = Darwin.fstat(child, &opened) == 0 && CapabilityPackageFileIdentity(opened) == expected
                if bound, try removeContents(in: child, prefix: path, snapshot: snapshot),
                   identityOfEntry(name, in: directory) == expected {
                    if Darwin.unlinkat(directory, name, AT_REMOVEDIR) != 0 { allRemoved = false }
                } else {
                    allRemoved = false
                }
            } else if expected.fileType == S_IFREG || expected.fileType == S_IFLNK {
                if identityOfEntry(name, in: directory) != expected
                    || Darwin.unlinkat(directory, name, 0) != 0 {
                    allRemoved = false
                }
            } else {
                allRemoved = false
            }
        }
        return allRemoved && ((try? names(in: directory).isEmpty) == true)
    }

    private static func identityOfEntry(_ name: String, in parent: Int32) -> CapabilityPackageFileIdentity? {
        var value = stat()
        guard Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return CapabilityPackageFileIdentity(value)
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = Darwin.dup(directory)
        guard duplicate >= 0 else { throw CapabilityExportError.invalidArchive }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw CapabilityExportError.invalidArchive
        }
        defer { Darwin.closedir(stream) }
        var result: [String] = []
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }
}

struct CapabilityPackageArchiveWriter: Sendable {
    typealias ProgressHandler = @Sendable (CapabilityExportProgress) -> Void
    let limits: CapabilityPackageLimits
    let afterPackaging: (@Sendable (URL) -> Void)?
    let afterVerification: (@Sendable (URL) -> Void)?
    private var fileManager: FileManager { .default }

    init(
        limits: CapabilityPackageLimits = CapabilityPackageLimits(),
        afterPackaging: (@Sendable (URL) -> Void)? = nil,
        afterVerification: (@Sendable (URL) -> Void)? = nil
    ) {
        self.limits = limits
        self.afterPackaging = afterPackaging
        self.afterVerification = afterVerification
    }

    func write(
        prepared: CapabilityPreparedPackage,
        to destinationURL: URL,
        progressHandler: ProgressHandler?,
        cancellation: CapabilityExportCancellation
    ) throws -> URL {
        try cancellation.check()
        guard !prepared.preview.hasBlockingIssues else { throw CapabilityExportError.blockingIssues }
        guard destinationURL.lastPathComponent.hasSuffix(".codexpack.zip") else {
            throw CapabilityExportError.invalidArchive
        }
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destinationParentFD = Darwin.open(
            destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationParentFD >= 0 else { throw CapabilityExportError.invalidArchive }
        defer { Darwin.close(destinationParentFD) }
        var initialDestination = stat()
        let destinationExists = Darwin.fstatat(
            destinationParentFD, destinationURL.lastPathComponent,
            &initialDestination, AT_SYMLINK_NOFOLLOW
        ) == 0
        guard destinationExists || errno == ENOENT,
              !destinationExists || initialDestination.st_mode & S_IFMT == S_IFREG else {
            throw CapabilityExportError.invalidArchive
        }
        let expectedDestination = destinationExists ? CapabilityPackageFileIdentity(initialDestination) : nil

        let stagingDirectory = destinationDirectory
            .appendingPathComponent(".CodexDirectorExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        let stagingIdentity = CapabilityPackageTemporaryItems.identity(at: stagingDirectory)
        var stagingTree: [String: CapabilityPackageFileIdentity]?
        defer {
            CapabilityPackageTemporaryItems.removeOwned(
                at: stagingDirectory, identity: stagingIdentity, knownContents: stagingTree
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
        let temporaryArchive = stagingDirectory.appendingPathComponent("package.tmp")
        let zipProgress = Progress()
        cancellation.register(zipProgress)
        defer { zipProgress.cancel() }

        progressHandler?(CapabilityExportProgress(phase: .packaging))
        try fileManager.zipItem(
            at: prepared.directory,
            to: temporaryArchive,
            shouldKeepParent: false,
            compressionMethod: .deflate,
            progress: zipProgress
        )
        try cancellation.check()
        stagingTree = try CapabilityPackageTemporaryItems.snapshotTree(at: stagingDirectory)
        afterPackaging?(stagingDirectory)
        guard CapabilityPackageTemporaryItems.identity(at: stagingDirectory) == stagingIdentity else {
            throw CapabilityExportError.invalidArchive
        }
        let stagingFD = Darwin.open(stagingDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw CapabilityExportError.invalidArchive }
        defer { Darwin.close(stagingFD) }
        let archiveFD = Darwin.openat(stagingFD, "package.tmp", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard archiveFD >= 0 else { throw CapabilityExportError.invalidArchive }
        defer { Darwin.close(archiveFD) }
        let verifiedStamp = try stamp(of: archiveFD)
        guard verifiedStamp.identity.fileType == S_IFREG,
              stagingTree?["package.tmp"] == verifiedStamp.identity,
              try identity(of: "package.tmp", in: stagingFD) == verifiedStamp.identity,
              verifiedStamp.size >= 0 else { throw CapabilityExportError.invalidArchive }
        guard UInt64(verifiedStamp.size) <= limits.maxArchiveBytes else {
            throw CapabilityExportError.resourceLimitExceeded
        }

        progressHandler?(CapabilityExportProgress(phase: .verifying))
        try CapabilityPackageArchiveVerifier(limits: limits).verify(
            archiveURL: URL(fileURLWithPath: "/dev/fd/\(archiveFD)"),
            cancellation: cancellation
        )
        try cancellation.check()
        afterVerification?(temporaryArchive)
        guard CapabilityPackageTemporaryItems.identity(at: stagingDirectory) == stagingIdentity else {
            throw CapabilityExportError.invalidArchive
        }
        guard try stamp(of: archiveFD) == verifiedStamp,
              try identity(of: "package.tmp", in: stagingFD) == verifiedStamp.identity else {
            stagingTree = [:]
            throw CapabilityExportError.invalidArchive
        }

        let name = destinationURL.lastPathComponent
        if let expectedDestination {
            guard try identity(of: name, in: destinationParentFD) == expectedDestination,
                  Darwin.renameatx_np(
                    stagingFD, "package.tmp", destinationParentFD, name, UInt32(RENAME_SWAP)
                  ) == 0 else { throw CapabilityExportError.invalidArchive }
            let published = (try? identity(of: name, in: destinationParentFD)) == verifiedStamp.identity
                && (try? stamp(of: archiveFD).hasSameContentAfterRename(as: verifiedStamp)) == true
            let displaced = (try? identity(of: "package.tmp", in: stagingFD)) == expectedDestination
            if published && displaced {
                stagingTree = ["package.tmp": expectedDestination]
            } else {
                stagingTree = [:]
                if (try? identity(of: name, in: destinationParentFD)) == verifiedStamp.identity,
                   Darwin.renameatx_np(
                    stagingFD, "package.tmp", destinationParentFD, name, UInt32(RENAME_SWAP)
                   ) == 0,
                   (try? identity(of: "package.tmp", in: stagingFD)) == verifiedStamp.identity {
                    stagingTree = ["package.tmp": verifiedStamp.identity]
                }
                throw CapabilityExportError.invalidArchive
            }
        } else {
            guard (try? identity(of: name, in: destinationParentFD)) == nil,
                  Darwin.renameatx_np(
                    stagingFD, "package.tmp", destinationParentFD, name, UInt32(RENAME_EXCL)
                  ) == 0 else { throw CapabilityExportError.invalidArchive }
            guard (try? identity(of: name, in: destinationParentFD)) == verifiedStamp.identity,
                  (try? stamp(of: archiveFD).hasSameContentAfterRename(as: verifiedStamp)) == true else {
                stagingTree = [:]
                if (try? identity(of: name, in: destinationParentFD)) == verifiedStamp.identity,
                   Darwin.renameatx_np(
                    destinationParentFD, name, stagingFD, "package.tmp", UInt32(RENAME_EXCL)
                   ) == 0,
                   (try? identity(of: "package.tmp", in: stagingFD)) == verifiedStamp.identity {
                    stagingTree = ["package.tmp": verifiedStamp.identity]
                }
                throw CapabilityExportError.invalidArchive
            }
        }
        progressHandler?(CapabilityExportProgress(phase: .finished))
        return destinationURL
    }

    private func stamp(of descriptor: Int32) throws -> CapabilityPackageFileStamp {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw CapabilityExportError.invalidArchive }
        return CapabilityPackageFileStamp(metadata)
    }

    private func identity(of name: String, in parent: Int32) throws -> CapabilityPackageFileIdentity {
        var metadata = stat()
        guard Darwin.fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CapabilityExportError.invalidArchive
        }
        return CapabilityPackageFileIdentity(metadata)
    }
}

struct CapabilityVerifiedPackage: Sendable {
    let extractionDirectory: URL
    let extractionIdentity: CapabilityPackageFileIdentity
    let extractionTree: [String: CapabilityPackageFileIdentity]
    let manifest: CapabilityPackageManifestV1
    let plugins: CapabilityPackagePluginList
    let requirements: CapabilityPackageRequirementList

    init(
        extractionDirectory: URL,
        extractionIdentity: CapabilityPackageFileIdentity,
        extractionTree: [String: CapabilityPackageFileIdentity],
        manifest: CapabilityPackageManifestV1,
        plugins: CapabilityPackagePluginList,
        requirements: CapabilityPackageRequirementList
    ) {
        self.extractionDirectory = extractionDirectory
        self.extractionIdentity = extractionIdentity
        self.extractionTree = extractionTree
        self.manifest = manifest
        self.plugins = plugins
        self.requirements = requirements
    }
}

public struct CapabilityPackageArchiveVerifier: Sendable {
    let limits: CapabilityPackageLimits
    let beforePublish: (@Sendable (URL) -> Void)?
    let beforeTemporaryCleanup: (@Sendable (URL) -> Void)?
    let afterTemporaryQuarantine: (@Sendable (URL) -> Void)?
    private var fileManager: FileManager { .default }

    public init() {
        self.limits = CapabilityPackageLimits()
        self.beforePublish = nil
        self.beforeTemporaryCleanup = nil
        self.afterTemporaryQuarantine = nil
    }

    init(
        limits: CapabilityPackageLimits,
        beforePublish: (@Sendable (URL) -> Void)? = nil,
        beforeTemporaryCleanup: (@Sendable (URL) -> Void)? = nil,
        afterTemporaryQuarantine: (@Sendable (URL) -> Void)? = nil
    ) {
        self.limits = limits
        self.beforePublish = beforePublish
        self.beforeTemporaryCleanup = beforeTemporaryCleanup
        self.afterTemporaryQuarantine = afterTemporaryQuarantine
    }

    public func verify(archiveURL: URL, extractionDirectory: URL? = nil) throws {
        if let extractionDirectory {
            _ = try verifyAndExtract(archiveURL: archiveURL, extractionDirectory: extractionDirectory)
            return
        }
        let verified = try verifyAndExtract(
            archiveURL: archiveURL, extractionDirectory: nil, cancellation: nil
        )
        beforeTemporaryCleanup?(verified.extractionDirectory)
        CapabilityPackageTemporaryItems.removeOwned(
            at: verified.extractionDirectory, identity: verified.extractionIdentity,
            knownContents: verified.extractionTree,
            afterQuarantine: afterTemporaryQuarantine
        )
    }

    /// Verifies a package and leaves its isolated extraction directory for a
    /// caller that needs to inspect or restore the payload. The caller owns
    /// cleanup of the returned directory.
    func verifyAndExtract(
        archiveURL: URL,
        extractionDirectory: URL? = nil
    ) throws -> CapabilityVerifiedPackage {
        if let extractionDirectory {
            return try verifyAndExtract(
                archiveURL: archiveURL,
                extractionDirectory: extractionDirectory,
                cancellation: nil
            )
        }
        return try verifyAndExtract(archiveURL: archiveURL, extractionDirectory: nil, cancellation: nil)
    }

    func verify(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        cancellation: CapabilityExportCancellation?
    ) throws {
        if let extractionDirectory {
            _ = try verifyAndExtract(
                archiveURL: archiveURL,
                extractionDirectory: extractionDirectory,
                cancellation: cancellation
            )
            return
        }
        let verified = try verifyAndExtract(
            archiveURL: archiveURL, extractionDirectory: nil, cancellation: cancellation
        )
        beforeTemporaryCleanup?(verified.extractionDirectory)
        CapabilityPackageTemporaryItems.removeOwned(
            at: verified.extractionDirectory, identity: verified.extractionIdentity,
            knownContents: verified.extractionTree,
            afterQuarantine: afterTemporaryQuarantine
        )
    }

    func verifyAndExtract(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        cancellation: CapabilityExportCancellation?
    ) throws -> CapabilityVerifiedPackage {
        try cancellation?.check() ?? Task.checkCancellation()
        let destinationRoot = extractionDirectory
        var expectedDestination: CapabilityPackageFileIdentity?
        if let destinationRoot {
            var metadata = stat()
            if Darwin.lstat(destinationRoot.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR,
                      try fileManager.contentsOfDirectory(atPath: destinationRoot.path).isEmpty else {
                    throw CapabilityExportError.invalidArchive
                }
                expectedDestination = CapabilityPackageFileIdentity(metadata)
            } else if errno != ENOENT {
                throw CapabilityExportError.invalidArchive
            }
        }
        let extractionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CodexDirectorVerify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        var ownedMetadata = stat()
        guard Darwin.lstat(extractionRoot.path, &ownedMetadata) == 0 else {
            throw CapabilityExportError.invalidArchive
        }
        let ownedIdentity = CapabilityPackageFileIdentity(ownedMetadata)
        var published = false
        defer {
            if !published {
                CapabilityPackageTemporaryItems.removeOwned(at: extractionRoot, identity: ownedIdentity)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: extractionRoot.path)

        let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard archiveSize >= 0, UInt64(archiveSize) <= limits.maxArchiveBytes else {
            throw CapabilityExportError.resourceLimitExceeded
        }

        let archive = try Archive(url: archiveURL, accessMode: .read)
        var paths = Set<String>()
        var filePaths = Set<String>()
        var symlinkPaths = Set<String>()
        var required = Set(["manifest.json", "checksums.json", "plugins.json", "requirements.json", "RESTORE.md"])
        var declaredTotal: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            try cancellation?.check() ?? Task.checkCancellation()
            let path = entry.path
            guard isSafeArchivePath(path) else { throw CapabilityExportError.unsafeArchivePath }
            let canonical = path.hasSuffix("/") ? String(path.dropLast()) : path
            entryCount += 1
            guard entryCount <= limits.maxEntries,
                  path.utf8.count <= limits.maxPathUTF8Bytes,
                  canonical.split(separator: "/").count <= limits.maxPathDepth else {
                throw CapabilityExportError.resourceLimitExceeded
            }
            guard paths.insert(canonical).inserted else { throw CapabilityExportError.invalidArchive }
            if entry.type != .directory { filePaths.insert(canonical) }
            if entry.type == .symlink { symlinkPaths.insert(canonical) }
            if entry.type == .directory {
                guard entry.uncompressedSize == 0 else { throw CapabilityExportError.invalidArchive }
            } else {
                let maximum = entry.type == .symlink ? limits.maxSymlinkBytes
                    : (Self.rootMetadata.contains(canonical) ? limits.maxMetadataFileBytes : limits.maxRegularFileBytes)
                guard entry.uncompressedSize <= maximum,
                      entry.compressedSize <= limits.maxArchiveBytes else {
                    throw CapabilityExportError.resourceLimitExceeded
                }
                let (sum, overflow) = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, sum <= limits.maxTotalExpandedBytes else {
                    throw CapabilityExportError.resourceLimitExceeded
                }
                declaredTotal = sum
            }
            required.remove(canonical)
            if Self.rootMetadata.contains(canonical), entry.type != .file {
                throw CapabilityExportError.invalidArchive
            }
            if entry.type != .directory,
               !Self.rootMetadata.contains(canonical),
               !canonical.hasPrefix("payload/") {
                throw CapabilityExportError.invalidArchive
            }
            if entry.type == .directory,
               canonical != "payload", !canonical.hasPrefix("payload/") {
                throw CapabilityExportError.invalidArchive
            }
        }
        guard required.isEmpty else { throw CapabilityExportError.invalidArchive }
        for path in paths {
            guard !filePaths.contains(where: { path != $0 && path.hasPrefix($0 + "/") }) else {
                throw CapabilityExportError.unsafeArchivePath
            }
        }
        try validateLocalSymlinkSizes(at: archiveURL, symlinkPaths: symlinkPaths)
        try extractEntries(archive, to: extractionRoot, cancellation: cancellation)
        try cancellation?.check() ?? Task.checkCancellation()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let checksums = try decoder.decode(
            CapabilityPackageChecksums.self,
            from: Data(contentsOf: extractionRoot.appendingPathComponent("checksums.json"))
        )
        guard checksums.algorithm == "SHA-256" else { throw CapabilityExportError.invalidArchive }
        guard filePaths == Set(checksums.files.keys).union(["checksums.json"]) else {
            throw CapabilityExportError.invalidArchive
        }
        let manifest = try decoder.decode(
            CapabilityPackageManifestV1.self,
            from: Data(contentsOf: extractionRoot.appendingPathComponent("manifest.json"))
        )
        guard manifest.format == "codex-capabilities", manifest.formatVersion == 1 else {
            throw CapabilityExportError.invalidArchive
        }

        let pluginList = try decoder.decode(
            CapabilityPackagePluginList.self,
            from: Data(contentsOf: extractionRoot.appendingPathComponent("plugins.json"))
        )
        let requirementList = try decoder.decode(
            CapabilityPackageRequirementList.self,
            from: Data(contentsOf: extractionRoot.appendingPathComponent("requirements.json"))
        )
        let restoreText = try String(
            contentsOf: extractionRoot.appendingPathComponent("RESTORE.md"),
            encoding: .utf8
        )
        guard restoreText == CapabilityPackageBuilder.restoreInstructions,
              packageMetadataIsSafe(manifest: manifest, plugins: pluginList, requirements: requirementList) else {
            throw CapabilityExportError.invalidArchive
        }

        var verifiedSizes: [String: Int64] = [:]
        for (relativePath, expectedHash) in checksums.files.sorted(by: { $0.key < $1.key }) {
            try cancellation?.check() ?? Task.checkCancellation()
            guard isSafeArchivePath(relativePath), relativePath != "checksums.json" else {
                throw CapabilityExportError.unsafeArchivePath
            }
            let url = extractionRoot.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            let data: Data
            if values.isSymbolicLink == true {
                data = Data(try fileManager.destinationOfSymbolicLink(atPath: url.path).utf8)
            } else {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            verifiedSizes[relativePath] = Int64(data.count)
            guard sha256(data) == expectedHash else { throw CapabilityExportError.checksumMismatch }
        }

        let manifestPaths = Set(manifest.entries.map(\.archivePath))
        let payloadPaths = Set(checksums.files.keys.filter { $0.hasPrefix("payload/") })
        let capabilityPaths = manifest.capabilities.flatMap(\.files)
        guard manifestPaths.count == manifest.entries.count,
              manifestPaths == payloadPaths,
              capabilityPaths.count == manifestPaths.count,
              Set(capabilityPaths) == manifestPaths else {
            throw CapabilityExportError.invalidArchive
        }
        let projectIDs = Set(manifest.projects.map(\.id))
        guard projectIDs.count == manifest.projects.count,
              Set(manifest.capabilities.map(\.id)).count == manifest.capabilities.count else {
            throw CapabilityExportError.invalidArchive
        }
        for capability in manifest.capabilities {
            let hasValidScope: Bool
            if let projectID = capability.projectID {
                hasValidScope = capability.scope == "project" && projectIDs.contains(projectID)
            } else {
                hasValidScope = capability.scope == "global"
            }
            guard capability.files.allSatisfy({ $0.hasPrefix(capability.archiveBasePath + "/") }),
                  hasValidScope,
                  logicalRootIsSafe(capability.logicalRoot, projectIDs: projectIDs) else {
                throw CapabilityExportError.invalidArchive
            }
        }
        for entry in manifest.entries {
            guard isSafeArchivePath(entry.archivePath), entry.archivePath.hasPrefix("payload/"),
                  checksums.files[entry.archivePath] == entry.sha256,
                  verifiedSizes[entry.archivePath] == entry.byteSize,
                  !entry.contentType.isEmpty,
                  logicalRootIsSafe(entry.logicalRoot, projectIDs: projectIDs),
                  manifest.capabilities.contains(where: {
                      $0.logicalRoot == entry.logicalRoot && $0.files.contains(entry.archivePath)
                  }) else {
                throw CapabilityExportError.checksumMismatch
            }
            let url = extractionRoot.appendingPathComponent(entry.archivePath)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard (values.isSymbolicLink == true) == (entry.inspection == .validatedSymlink) else {
                throw CapabilityExportError.checksumMismatch
            }
            if values.isSymbolicLink != true {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                guard (permissions & 0o111 != 0) == entry.executable else {
                    throw CapabilityExportError.checksumMismatch
                }
            }
        }
        for capability in manifest.capabilities {
            let ownEntries = manifest.entries.filter { capability.files.contains($0.archivePath) }
            let ownRegular = Set(ownEntries.filter { $0.inspection != .validatedSymlink }.map(\.archivePath))
            let ownLinks = Set(ownEntries.filter { $0.inspection == .validatedSymlink }.map(\.archivePath))
            for linkPath in ownLinks {
                let linkURL = extractionRoot.appendingPathComponent(linkPath)
                let target = try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
                let targetURL = URL(fileURLWithPath: target, relativeTo: linkURL.deletingLastPathComponent())
                    .standardizedFileURL
                let relative = String(targetURL.path.dropFirst(extractionRoot.standardizedFileURL.path.count + 1))
                let inCapability = targetURL.path.hasPrefix(extractionRoot.standardizedFileURL.path + "/")
                    && relative.hasPrefix(capability.archiveBasePath + "/")
                let targetExists = ownRegular.contains(relative)
                    || ownRegular.contains(where: { $0.hasPrefix(relative + "/") })
                let traversesLink = ownLinks.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
                guard inCapability, targetExists, !traversesLink else {
                    throw CapabilityExportError.unsafeArchivePath
                }
            }
        }
        let ownedTree = try CapabilityPackageTemporaryItems.snapshotTree(at: extractionRoot)
        if let destinationRoot { beforePublish?(destinationRoot) }
        let finalRoot = try destinationRoot.map {
            try publishOwnedExtraction(
                extractionRoot, identity: ownedIdentity,
                to: $0, expectedDestination: expectedDestination
            )
        } ?? extractionRoot
        published = true
        return CapabilityVerifiedPackage(
            extractionDirectory: finalRoot,
            extractionIdentity: expectedDestination ?? ownedIdentity,
            extractionTree: ownedTree,
            manifest: manifest,
            plugins: pluginList,
            requirements: requirementList
        )
    }

    public func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return false }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func publishOwnedExtraction(
        _ source: URL,
        identity: CapabilityPackageFileIdentity,
        to destination: URL,
        expectedDestination: CapabilityPackageFileIdentity?
    ) throws -> URL {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let sourceFD = try openDirectory(source.path)
        defer { Darwin.close(sourceFD) }
        guard try identityOfDescriptor(sourceFD) == identity else {
            throw CapabilityExportError.invalidArchive
        }
        let sourceParentFD = try openDirectory(source.deletingLastPathComponent().path)
        defer { Darwin.close(sourceParentFD) }
        let destinationParentFD = try openDirectory(destination.deletingLastPathComponent().path)
        defer { Darwin.close(destinationParentFD) }
        let destinationName = destination.lastPathComponent

        if let expectedDestination {
            let destinationFD = Darwin.openat(
                destinationParentFD, destinationName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard destinationFD >= 0 else { throw CapabilityExportError.invalidArchive }
            defer { Darwin.close(destinationFD) }
            guard try identityOfDescriptor(destinationFD) == expectedDestination,
                  try identityOfEntry(destinationName, in: destinationParentFD) == expectedDestination,
                  try directoryNames(in: destinationFD).isEmpty else {
                throw CapabilityExportError.invalidArchive
            }
            var moved = [(name: String, identity: CapabilityPackageFileIdentity)]()
            do {
                for name in try directoryNames(in: sourceFD) {
                    let childIdentity = try identityOfEntry(name, in: sourceFD)
                    guard try identityOfEntry(destinationName, in: destinationParentFD) == expectedDestination,
                          Darwin.renameatx_np(
                            sourceFD, name, destinationFD, name, UInt32(RENAME_EXCL)
                          ) == 0 else {
                        throw CapabilityExportError.invalidArchive
                    }
                    moved.append((name, childIdentity))
                    guard try identityOfEntry(name, in: destinationFD) == childIdentity else {
                        throw CapabilityExportError.invalidArchive
                    }
                }
                guard try identityOfEntry(destinationName, in: destinationParentFD) == expectedDestination else {
                    throw CapabilityExportError.invalidArchive
                }
            } catch {
                for item in moved.reversed() {
                    // A changed child is user-owned from this point on. Never
                    // remove or move it during rollback.
                    if (try? identityOfEntry(item.name, in: destinationFD)) == item.identity {
                        _ = Darwin.renameatx_np(
                            destinationFD, item.name, sourceFD, item.name, UInt32(RENAME_EXCL)
                        )
                    }
                }
                throw error
            }
            CapabilityPackageTemporaryItems.removeOwned(at: source, identity: identity)
            return destination
        }

        guard (try? identityOfEntry(destinationName, in: destinationParentFD)) == nil,
              try identityOfEntry(source.lastPathComponent, in: sourceParentFD) == identity,
              Darwin.renameatx_np(
                sourceParentFD, source.lastPathComponent,
                destinationParentFD, destinationName, UInt32(RENAME_EXCL)
              ) == 0 else {
            throw CapabilityExportError.invalidArchive
        }
        guard try identityOfEntry(destinationName, in: destinationParentFD) == identity else {
            throw CapabilityExportError.invalidArchive
        }
        return destination
    }

    private func openDirectory(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CapabilityExportError.invalidArchive }
        return descriptor
    }

    private func identityOfDescriptor(_ descriptor: Int32) throws -> CapabilityPackageFileIdentity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw CapabilityExportError.invalidArchive
        }
        return CapabilityPackageFileIdentity(value)
    }

    private func identityOfEntry(_ name: String, in parent: Int32) throws -> CapabilityPackageFileIdentity {
        var value = stat()
        guard Darwin.fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CapabilityExportError.invalidArchive
        }
        return CapabilityPackageFileIdentity(value)
    }

    private func directoryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw CapabilityExportError.invalidArchive }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw CapabilityExportError.invalidArchive
        }
        defer { Darwin.closedir(stream) }
        var names = [String]()
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func extractEntries(
        _ archive: Archive,
        to root: URL,
        cancellation: CapabilityExportCancellation?
    ) throws {
        var actualTotal: UInt64 = 0
        for entry in archive where entry.type == .directory {
            try cancellation?.check() ?? Task.checkCancellation()
            try fileManager.createDirectory(
                at: root.appendingPathComponent(entry.path),
                withIntermediateDirectories: true
            )
        }
        for entry in archive where entry.type == .file {
            try cancellation?.check() ?? Task.checkCancellation()
            let path = root.appendingPathComponent(entry.path)
            try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: path.path, contents: nil) else {
                throw CapabilityExportError.invalidArchive
            }
            let output = try FileHandle(forWritingTo: path)
            defer { try? output.close() }
            var actual: UInt64 = 0
            let maximum = Self.rootMetadata.contains(entry.path)
                ? limits.maxMetadataFileBytes : limits.maxRegularFileBytes
            let checksum = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false) { chunk in
                try cancellation?.check() ?? Task.checkCancellation()
                let (newSize, sizeOverflow) = actual.addingReportingOverflow(UInt64(chunk.count))
                let (newTotal, totalOverflow) = actualTotal.addingReportingOverflow(UInt64(chunk.count))
                guard !sizeOverflow, !totalOverflow,
                      newSize <= maximum, newTotal <= limits.maxTotalExpandedBytes else {
                    throw CapabilityExportError.resourceLimitExceeded
                }
                actual = newSize
                actualTotal = newTotal
                try output.write(contentsOf: chunk)
            }
            guard checksum == entry.checksum, actual == entry.uncompressedSize else {
                throw CapabilityExportError.checksumMismatch
            }
            let sourceMode = (entry.fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            try fileManager.setAttributes(
                [.posixPermissions: sourceMode & 0o111 != 0 ? 0o755 : 0o644],
                ofItemAtPath: path.path
            )
        }
        for entry in archive where entry.type == .symlink {
            try cancellation?.check() ?? Task.checkCancellation()
            var data = Data()
            let checksum = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false) { chunk in
                try cancellation?.check() ?? Task.checkCancellation()
                let (newSize, sizeOverflow) = UInt64(data.count).addingReportingOverflow(UInt64(chunk.count))
                let (newTotal, totalOverflow) = actualTotal.addingReportingOverflow(UInt64(chunk.count))
                guard !sizeOverflow, !totalOverflow,
                      newSize <= limits.maxSymlinkBytes, newTotal <= limits.maxTotalExpandedBytes else {
                    throw CapabilityExportError.resourceLimitExceeded
                }
                actualTotal = newTotal
                data.append(chunk)
            }
            guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize,
                  let target = String(data: data, encoding: .utf8),
                  isSafeSymlinkTarget(target, entryPath: entry.path, extractionRoot: root) else {
                throw CapabilityExportError.unsafeArchivePath
            }
            let path = root.appendingPathComponent(entry.path)
            try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: path.path, withDestinationPath: target)
        }
    }

    /// ZIPFoundation reads a symlink's local-header compressed size into one
    /// Data allocation before its streaming consumer is called. Verify that
    /// local value against the same small budget before invoking extract.
    private func validateLocalSymlinkSizes(at url: URL, symlinkPaths: Set<String>) throws {
        guard !symlinkPaths.isEmpty else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let tailCount = Int(min(length, 65_557))
        try handle.seek(toOffset: length - UInt64(tailCount))
        let tail = [UInt8](try handle.read(upToCount: tailCount) ?? Data())
        guard tail.count >= 22 else { throw CapabilityExportError.invalidArchive }
        func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
            UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
        }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16
        }
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4b && tail[$0 + 2] == 0x05
                && tail[$0 + 3] == 0x06 && $0 + 22 + Int(u16(tail, $0 + 20)) == tail.count
        }) else { throw CapabilityExportError.invalidArchive }
        let count = Int(u16(tail, eocd + 10))
        let centralSize = UInt64(u32(tail, eocd + 12))
        let centralOffset = UInt64(u32(tail, eocd + 16))
        guard count != 65_535,
              centralSize != UInt64(UInt32.max), centralOffset != UInt64(UInt32.max),
              centralOffset <= length, centralSize <= length - centralOffset else {
            throw CapabilityExportError.invalidArchive
        }
        var cursor = centralOffset
        var checked = Set<String>()
        for _ in 0..<count {
            try handle.seek(toOffset: cursor)
            let header = [UInt8](try handle.read(upToCount: 46) ?? Data())
            guard header.count == 46, u32(header, 0) == 0x02014b50 else {
                throw CapabilityExportError.invalidArchive
            }
            let nameCount = Int(u16(header, 28))
            let extraCount = Int(u16(header, 30))
            let commentCount = Int(u16(header, 32))
            let name = try handle.read(upToCount: nameCount) ?? Data()
            guard name.count == nameCount else { throw CapabilityExportError.invalidArchive }
            if let path = String(data: name, encoding: .utf8), symlinkPaths.contains(path) {
                let localOffset = UInt64(u32(header, 42))
                guard localOffset < length else { throw CapabilityExportError.invalidArchive }
                try handle.seek(toOffset: localOffset)
                let local = [UInt8](try handle.read(upToCount: 30) ?? Data())
                guard local.count == 30, u32(local, 0) == 0x04034b50,
                      u16(local, 8) == 0,
                      UInt64(u32(local, 18)) <= limits.maxSymlinkBytes,
                      UInt64(u32(local, 18)) == UInt64(u32(header, 20)),
                      UInt64(u32(local, 22)) == UInt64(u32(header, 24)),
                      Int(u16(local, 26)) == nameCount else {
                    throw CapabilityExportError.resourceLimitExceeded
                }
                let localName = try handle.read(upToCount: nameCount) ?? Data()
                guard localName == name else { throw CapabilityExportError.invalidArchive }
                checked.insert(path)
            }
            cursor += UInt64(46 + nameCount + extraCount + commentCount)
            guard cursor <= centralOffset + centralSize else { throw CapabilityExportError.invalidArchive }
        }
        guard checked == symlinkPaths else { throw CapabilityExportError.invalidArchive }
    }

    private func isSafeSymlinkTarget(_ target: String, entryPath: String, extractionRoot: URL) -> Bool {
        guard !target.isEmpty,
              !(target as NSString).isAbsolutePath,
              !target.contains("\\"),
              !target.contains("\0") else { return false }
        let linkURL = extractionRoot.appendingPathComponent(entryPath)
        let resolvedTarget = URL(
            fileURLWithPath: target,
            relativeTo: linkURL.deletingLastPathComponent()
        ).standardizedFileURL
        let rootPath = extractionRoot.standardizedFileURL.path
        let targetPath = resolvedTarget.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    private func packageMetadataIsSafe(
        manifest: CapabilityPackageManifestV1,
        plugins: CapabilityPackagePluginList,
        requirements: CapabilityPackageRequirementList
    ) -> Bool {
        var values = [
            manifest.producer.name, manifest.producer.version, manifest.producer.build,
            manifest.platform.operatingSystem, manifest.platform.operatingSystemVersion,
            manifest.platform.architecture
        ]
        values.append(contentsOf: manifest.projects.flatMap { [$0.id, $0.name] })
        values.append(contentsOf: manifest.capabilities.flatMap {
            [$0.id, $0.name, $0.kind, $0.scope, $0.ownership, $0.projectID ?? "", $0.logicalRoot, $0.archiveBasePath]
                + $0.files
        })
        values.append(contentsOf: manifest.entries.flatMap {
            [$0.archivePath, $0.logicalRoot, $0.relativePath, $0.sha256, $0.contentType]
        })
        values.append(contentsOf: plugins.plugins.flatMap {
            [$0.identifier, $0.name, $0.marketplace ?? "", $0.version ?? ""]
        })
        if let issue = plugins.issue { values.append(issue) }
        values.append(contentsOf: requirements.requirements.flatMap {
            [$0.name, $0.kind] + $0.detectedFrom
        })
        guard values.allSatisfy({ !PersistenceAllowlist.containsForbiddenValue($0) }) else { return false }

        let projectIDs = Set(manifest.projects.map(\.id))
        return manifest.entries.allSatisfy { logicalRootIsSafe($0.logicalRoot, projectIDs: projectIDs) }
    }

    private func logicalRootIsSafe(_ value: String, projectIDs: Set<String>) -> Bool {
        let tokens = ["{{HOME}}"] + projectIDs.map { "{{PROJECT:\($0)}}" }
        guard let token = tokens.first(where: { value == $0 || value.hasPrefix($0 + "/") }) else {
            return false
        }
        guard value.count > token.count else { return true }
        let suffix = String(value.dropFirst(token.count + 1))
        return isSafeArchivePath(suffix)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let rootMetadata: Set<String> = [
        "manifest.json", "checksums.json", "plugins.json", "requirements.json", "RESTORE.md"
    ]
}
