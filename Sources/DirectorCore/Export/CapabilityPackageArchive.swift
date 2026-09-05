import CryptoKit
import Foundation
import ZIPFoundation

struct CapabilityPackageArchiveWriter: Sendable {
    typealias ProgressHandler = @Sendable (CapabilityExportProgress) -> Void
    private var fileManager: FileManager { .default }

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

        let temporaryArchive = destinationDirectory
            .appendingPathComponent(".CodexDirectorExport-\(UUID().uuidString).tmp")
        let verificationDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexDirectorVerify-\(UUID().uuidString)", isDirectory: true)
        let zipProgress = Progress()
        cancellation.register(zipProgress)
        defer {
            zipProgress.cancel()
            try? fileManager.removeItem(at: temporaryArchive)
            try? fileManager.removeItem(at: verificationDirectory)
        }

        progressHandler?(CapabilityExportProgress(phase: .packaging))
        try fileManager.zipItem(
            at: prepared.directory,
            to: temporaryArchive,
            shouldKeepParent: false,
            compressionMethod: .deflate,
            progress: zipProgress
        )
        try cancellation.check()

        progressHandler?(CapabilityExportProgress(phase: .verifying))
        try CapabilityPackageArchiveVerifier().verify(
            archiveURL: temporaryArchive,
            extractionDirectory: verificationDirectory,
            cancellation: cancellation
        )
        try cancellation.check()

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryArchive,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryArchive, to: destinationURL)
        }
        progressHandler?(CapabilityExportProgress(phase: .finished))
        return destinationURL
    }
}

public struct CapabilityPackageArchiveVerifier: Sendable {
    private var fileManager: FileManager { .default }

    public init() {}

    public func verify(archiveURL: URL, extractionDirectory: URL? = nil) throws {
        try verify(archiveURL: archiveURL, extractionDirectory: extractionDirectory, cancellation: nil)
    }

    func verify(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        cancellation: CapabilityExportCancellation?
    ) throws {
        try cancellation?.check() ?? Task.checkCancellation()
        let extractionRoot = extractionDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("CodexDirectorVerify-\(UUID().uuidString)", isDirectory: true)
        let ownsExtractionRoot = extractionDirectory == nil
        defer { if ownsExtractionRoot { try? fileManager.removeItem(at: extractionRoot) } }
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        guard try fileManager.contentsOfDirectory(atPath: extractionRoot.path).isEmpty else {
            throw CapabilityExportError.invalidArchive
        }

        let archive = try Archive(url: archiveURL, accessMode: .read)
        var paths = Set<String>()
        var filePaths = Set<String>()
        var symlinkPaths = Set<String>()
        var required = Set(["manifest.json", "checksums.json", "plugins.json", "requirements.json", "RESTORE.md"])
        for entry in archive {
            let path = entry.path
            guard isSafeArchivePath(path) else { throw CapabilityExportError.unsafeArchivePath }
            guard paths.insert(path).inserted else { throw CapabilityExportError.invalidArchive }
            if entry.type != .directory { filePaths.insert(path) }
            if entry.type == .symlink {
                guard entry.uncompressedSize <= 65_536 else { throw CapabilityExportError.unsafeArchivePath }
                var linkData = Data()
                _ = try archive.extract(entry, skipCRC32: false) { linkData.append($0) }
                guard let target = String(data: linkData, encoding: .utf8),
                      isSafeSymlinkTarget(target, entryPath: path, extractionRoot: extractionRoot) else {
                    throw CapabilityExportError.unsafeArchivePath
                }
                symlinkPaths.insert(path)
            }
            required.remove(path)
            if entry.type != .directory,
               !Self.rootMetadata.contains(path),
               !path.hasPrefix("payload/") {
                throw CapabilityExportError.invalidArchive
            }
        }
        guard required.isEmpty else { throw CapabilityExportError.invalidArchive }
        for path in paths {
            guard !symlinkPaths.contains(where: { path != $0 && path.hasPrefix($0 + "/") }) else {
                throw CapabilityExportError.unsafeArchivePath
            }
        }

        try fileManager.unzipItem(
            at: archiveURL,
            to: extractionRoot,
            skipCRC32: false,
            allowUncontainedSymlinks: true
        )
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
            if values.isSymbolicLink != true {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                guard (permissions & 0o111 != 0) == entry.executable else {
                    throw CapabilityExportError.checksumMismatch
                }
            }
        }
    }

    public func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !trimmed.isEmpty else { return false }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
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
