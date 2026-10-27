import Darwin
import Foundation

/// A stable, privacy-safe classification for read failures encountered while
/// discovering local capability sources. The scanner must retain this result
/// instead of treating it as an empty directory or empty document.
public enum FileSystemReadError: String, Error, Codable, Sendable, Equatable {
    case notFound
    case notDirectory
    case permissionDenied
    case enumerationFailed
    case readFailed
    case invalidEncoding
    case changedDuringRead
    case tooLarge
    case outsideApprovedRoot
    case notRegularFile
}

/// Descriptor identity captured with the bytes of a tracked document. The
/// values never leave discovery; they only let the scanner invalidate bytes
/// whose path/object changed before the observation was published.
public struct FileSystemDocumentIdentity: Sendable, Equatable {
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let size: Int64
    fileprivate let modificationSeconds: Int64
    fileprivate let modificationNanoseconds: Int64
    fileprivate let changeSeconds: Int64
    fileprivate let changeNanoseconds: Int64

    fileprivate init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = value.st_size
        modificationSeconds = Int64(value.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

public struct FileSystemDocumentRead: Sendable, Equatable {
    public let data: Data
    public let identity: FileSystemDocumentIdentity?
    fileprivate let resolvedPath: String?
    fileprivate let approvedRootPath: String?
    fileprivate let approvedRootIdentity: FileSystemDocumentIdentity?

    public init(data: Data, identity: FileSystemDocumentIdentity? = nil) {
        self.data = data
        self.identity = identity
        resolvedPath = nil
        approvedRootPath = nil
        approvedRootIdentity = nil
    }

    fileprivate init(
        data: Data,
        identity: FileSystemDocumentIdentity,
        resolvedPath: String?,
        approvedRootPath: String?,
        approvedRootIdentity: FileSystemDocumentIdentity?
    ) {
        self.data = data
        self.identity = identity
        self.resolvedPath = resolvedPath
        self.approvedRootPath = approvedRootPath
        self.approvedRootIdentity = approvedRootIdentity
    }
}

/// Read-only filesystem access for discovery.
///
/// Wrapped in a small Sendable struct so scanner behavior is testable and the
/// write boundary is explicit. Production closures acquire their own
/// FileManager reference when invoked; no mutable non-Sendable manager is
/// captured or shared by the client.
public struct FileSystemClient: Sendable {
    private let existsReader: @Sendable (URL) -> Bool
    private let directoryStatusReader: @Sendable (URL) -> Result<Bool, FileSystemReadError>
    private let directoryReader: @Sendable (URL) -> Result<[URL], FileSystemReadError>
    private let dataReader: @Sendable (URL) -> Result<Data, FileSystemReadError>
    private let verifiedDataReader: @Sendable (URL, URL, Int) -> Result<FileSystemDocumentRead, FileSystemReadError>
    private let identityValidator: @Sendable (URL, URL, FileSystemDocumentRead) -> Bool
    private let directoryIdentityReader: @Sendable (URL) -> FileSystemDocumentIdentity?
    private let attributesReader: @Sendable (URL) -> (size: UInt64, modificationDate: TimeInterval)?
    private let readableReader: @Sendable (URL) -> Bool
    private let symbolicLinkReader: @Sendable (URL) -> Bool

    public init() {
        existsReader = { url in FileManager.default.fileExists(atPath: url.path) }
        directoryStatusReader = { url in Self.productionDirectoryStatus(url) }
        directoryReader = { url in Self.productionDirectoryRead(url) }
        dataReader = { url in
            Self.productionVerifiedRead(url, approvedRoot: nil, maximumByteCount: Int.max)
                .map(\.data)
        }
        verifiedDataReader = { url, root, limit in
            Self.productionVerifiedRead(url, approvedRoot: root, maximumByteCount: limit)
        }
        identityValidator = { url, root, read in
            Self.productionIdentityMatches(url, approvedRoot: root, read: read)
        }
        directoryIdentityReader = { url in Self.productionDirectoryIdentity(url) }
        attributesReader = { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let date = attributes[.modificationDate] as? Date else {
                return nil
            }
            return (size, date.timeIntervalSince1970)
        }
        readableReader = { url in FileManager.default.isReadableFile(atPath: url.path) }
        symbolicLinkReader = { url in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        }
    }

    /// Injectable read-only seams for synthetic discovery failures and race
    /// tests. The production initializer above remains descriptor-backed.
    public init(
        directoryReader: @escaping @Sendable (URL) -> Result<[URL], FileSystemReadError>,
        dataReader: @escaping @Sendable (URL) -> Result<Data, FileSystemReadError>,
        attributesReader: @escaping @Sendable (URL) -> (size: UInt64, modificationDate: TimeInterval)?,
        readableReader: @escaping @Sendable (URL) -> Bool,
        symbolicLinkReader: @escaping @Sendable (URL) -> Bool,
        verifiedDataReader: (@Sendable (URL, URL, Int) -> Result<FileSystemDocumentRead, FileSystemReadError>)? = nil,
        identityValidator: (@Sendable (URL, URL, FileSystemDocumentRead) -> Bool)? = nil,
        directoryIdentityReader: (@Sendable (URL) -> FileSystemDocumentIdentity?)? = nil,
        directoryStatusReader: (@Sendable (URL) -> Result<Bool, FileSystemReadError>)? = nil
    ) {
        existsReader = { url in FileManager.default.fileExists(atPath: url.path) }
        if let directoryStatusReader {
            self.directoryStatusReader = directoryStatusReader
        } else {
            self.directoryStatusReader = { url in Self.productionDirectoryStatus(url) }
        }
        self.directoryReader = directoryReader
        self.dataReader = dataReader
        if let verifiedDataReader {
            self.verifiedDataReader = verifiedDataReader
        } else {
            self.verifiedDataReader = { url, _, maximumByteCount in
                dataReader(url).flatMap { data in
                    data.count <= maximumByteCount
                        ? .success(FileSystemDocumentRead(data: data))
                        : .failure(.tooLarge)
                }
            }
        }
        if let identityValidator {
            self.identityValidator = identityValidator
        } else {
            self.identityValidator = { _, _, _ in true }
        }
        if let directoryIdentityReader {
            self.directoryIdentityReader = directoryIdentityReader
        } else {
            self.directoryIdentityReader = { url in Self.productionDirectoryIdentity(url) }
        }
        self.attributesReader = attributesReader
        self.readableReader = readableReader
        self.symbolicLinkReader = symbolicLinkReader
    }

    public func exists(_ url: URL) -> Bool {
        existsReader(url)
    }

    public func isDirectory(_ url: URL) -> Bool {
        guard case .success(let isDirectory) = directoryStatusReader(url) else { return false }
        return isDirectory
    }

    public func directoryStatus(_ url: URL) -> Result<Bool, FileSystemReadError> {
        directoryStatusReader(url)
    }

    public func isSymbolicLink(_ url: URL) -> Bool {
        symbolicLinkReader(url)
    }

    /// Enumerates a directory while retaining whether the operation actually
    /// completed. An empty success is distinct from a failed enumeration.
    public func enumerateDirectory(_ url: URL) -> Result<[URL], FileSystemReadError> {
        directoryReader(url)
    }

    public func probeDirectory(_ url: URL) -> Result<Void, FileSystemReadError> {
        enumerateDirectory(url).map { _ in () }
    }

    /// Directory entries including hidden entries (dot-files such as
    /// `.codex-plugin` must be discoverable).
    public func contents(_ url: URL) -> [URL] {
        guard case .success(let entries) = enumerateDirectory(url) else { return [] }
        return entries
    }

    public func readData(_ url: URL) -> Result<Data, FileSystemReadError> {
        dataReader(url)
    }

    /// Reads a bounded regular file through a descriptor, verifies that the
    /// opened object remained stable, and proves the descriptor stayed inside
    /// the approved root. The final path identity can be checked again just
    /// before publishing a multi-document observation.
    public func readVerifiedData(
        _ url: URL,
        within approvedRoot: URL,
        maximumByteCount: Int
    ) -> Result<FileSystemDocumentRead, FileSystemReadError> {
        verifiedDataReader(url, approvedRoot, maximumByteCount)
    }

    public func validateDocumentRead(
        _ read: FileSystemDocumentRead,
        at url: URL,
        within approvedRoot: URL
    ) -> Bool {
        guard read.identity != nil else { return true }
        return identityValidator(url, approvedRoot, read)
    }

    /// Captures the descriptor-backed identity of a directory so callers can
    /// prove that a second enumeration refers to the same directory object.
    public func directoryIdentity(_ url: URL) -> FileSystemDocumentIdentity? {
        directoryIdentityReader(url)
    }

    public func readText(_ url: URL) -> Result<String, FileSystemReadError> {
        switch readData(url) {
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.invalidEncoding)
            }
            return .success(text)
        case .failure(let error):
            return .failure(error)
        }
    }

    public func isReadable(_ url: URL) -> Bool {
        readableReader(url)
    }

    /// Size and modification time retained for legacy presentation/fingerprint
    /// behavior. History stability never relies on these two values alone.
    public func fileAttributes(_ url: URL) -> (size: UInt64, modificationDate: TimeInterval)? {
        attributesReader(url)
    }

    private static func productionDirectoryRead(_ url: URL) -> Result<[URL], FileSystemReadError> {
        guard url.isFileURL else { return .failure(.enumerationFailed) }
        var pathBefore = stat()
        guard Darwin.lstat(url.path, &pathBefore) == 0 else {
            return .failure(classifyDirectoryPOSIX(errno))
        }
        guard (pathBefore.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.notDirectory)
        }
        let identityBefore = FileSystemDocumentIdentity(pathBefore)

        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            return .failure(classifyDirectoryPOSIX(errno))
        }
        var descriptorBefore = stat()
        guard Darwin.fstat(descriptor, &descriptorBefore) == 0 else {
            Darwin.close(descriptor)
            return .failure(.enumerationFailed)
        }
        guard FileSystemDocumentIdentity(descriptorBefore) == identityBefore else {
            Darwin.close(descriptor)
            return .failure(.changedDuringRead)
        }
        guard let stream = Darwin.fdopendir(descriptor) else {
            let code = errno
            Darwin.close(descriptor)
            return .failure(classifyDirectoryPOSIX(code))
        }
        defer { Darwin.closedir(stream) }

        var entries: [URL] = []
        let directoryBaseURL = URL(fileURLWithPath: url.path, isDirectory: true)
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                let code = errno
                guard code == 0 else {
                    return .failure(classifyDirectoryPOSIX(code))
                }
                break
            }
            let nameLength = Int(entry.pointee.d_namlen)
            let entryIsDirectory = entry.pointee.d_type == DT_DIR
            var nameStorage = entry.pointee.d_name
            let nameCapacity = MemoryLayout.size(ofValue: nameStorage)
            guard nameLength > 0, nameLength < nameCapacity else {
                return .failure(.enumerationFailed)
            }
            let childURL = withUnsafePointer(to: &nameStorage) { tuplePointer -> URL? in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: nameCapacity
                ) { namePointer in
                    guard namePointer[nameLength] == 0 else { return nil }
                    let isCurrentDirectory = nameLength == 1 && namePointer[0] == 0x2E
                    let isParentDirectory = nameLength == 2
                        && namePointer[0] == 0x2E
                        && namePointer[1] == 0x2E
                    guard !isCurrentDirectory, !isParentDirectory else { return nil }
                    return URL(
                        fileURLWithFileSystemRepresentation: namePointer,
                        isDirectory: entryIsDirectory,
                        relativeTo: directoryBaseURL
                    ).absoluteURL
                }
            }
            guard let childURL else {
                let isDotEntry = nameLength <= 2 && withUnsafePointer(to: &nameStorage) {
                    $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { namePointer in
                        namePointer[nameLength] == 0
                            && namePointer[0] == 0x2E
                            && (nameLength == 1 || namePointer[1] == 0x2E)
                    }
                }
                if isDotEntry { continue }
                return .failure(.enumerationFailed)
            }
            entries.append(childURL)
        }

        var descriptorAfter = stat()
        var pathAfter = stat()
        guard Darwin.fstat(descriptor, &descriptorAfter) == 0,
              Darwin.lstat(url.path, &pathAfter) == 0,
              FileSystemDocumentIdentity(descriptorAfter) == identityBefore,
              FileSystemDocumentIdentity(pathAfter) == identityBefore else {
            return .failure(.changedDuringRead)
        }
        return .success(entries)
    }

    private static func productionDirectoryStatus(_ url: URL) -> Result<Bool, FileSystemReadError> {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return productionIsDirectory(resolvedURL)
    }

    /// Reads only POSIX path metadata. Foundation's attribute dictionary also
    /// asks the filesystem for extended attributes, which can indefinitely
    /// block a serial discovery pass even though directory type needs only
    /// `st_mode`.
    private static func productionIsDirectory(_ url: URL) -> Result<Bool, FileSystemReadError> {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            let code = errno
            return .failure(classifyPOSIX(code))
        }
        return .success((value.st_mode & S_IFMT) == S_IFDIR)
    }

    private static func productionVerifiedRead(
        _ url: URL,
        approvedRoot: URL?,
        maximumByteCount: Int
    ) -> Result<FileSystemDocumentRead, FileSystemReadError> {
        guard maximumByteCount >= 0 else { return .failure(.tooLarge) }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = approvedRoot?.resolvingSymlinksInPath().standardizedFileURL
        let rootIdentity = resolvedRoot.flatMap(productionDirectoryIdentity)
        if resolvedRoot != nil, rootIdentity == nil {
            return .failure(.changedDuringRead)
        }
        if let resolvedRoot, !isWithin(resolvedURL, root: resolvedRoot) {
            return .failure(.outsideApprovedRoot)
        }

        let descriptor = Darwin.open(resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(classifyPOSIX(errno)) }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else { return .failure(.readFailed) }
        guard (before.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard before.st_size >= 0, before.st_size <= Int64(maximumByteCount) else {
            return .failure(.tooLarge)
        }
        if let resolvedRoot, !descriptorIsWithin(descriptor, root: resolvedRoot) {
            return .failure(.outsideApprovedRoot)
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(classifyPOSIX(errno))
            }
            if data.count > maximumByteCount - count { return .failure(.tooLarge) }
            data.append(contentsOf: buffer[..<count])
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else { return .failure(.readFailed) }
        let beforeIdentity = FileSystemDocumentIdentity(before)
        let afterIdentity = FileSystemDocumentIdentity(after)
        guard beforeIdentity == afterIdentity, data.count == Int(after.st_size) else {
            return .failure(.changedDuringRead)
        }
        let read = FileSystemDocumentRead(
            data: data,
            identity: afterIdentity,
            resolvedPath: approvedRoot == nil ? nil : resolvedURL.path,
            approvedRootPath: resolvedRoot?.path,
            approvedRootIdentity: rootIdentity
        )
        if let approvedRoot {
            guard productionIdentityMatches(url, approvedRoot: approvedRoot, read: read) else {
                return .failure(.changedDuringRead)
            }
        }
        return .success(read)
    }

    private static func productionIdentityMatches(
        _ url: URL,
        approvedRoot: URL,
        read: FileSystemDocumentRead
    ) -> Bool {
        guard let expected = read.identity,
              let expectedPath = read.resolvedPath,
              let expectedRootPath = read.approvedRootPath,
              let expectedRootIdentity = read.approvedRootIdentity else {
            return false
        }
        let root = approvedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == expectedRootPath,
              resolvedURL.path == expectedPath,
              productionDirectoryIdentity(root) == expectedRootIdentity,
              isWithin(resolvedURL, root: root) else {
            return false
        }
        let descriptor = Darwin.open(resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var current = stat()
        guard Darwin.fstat(descriptor, &current) == 0,
              descriptorIsWithin(descriptor, root: root) else {
            return false
        }
        return FileSystemDocumentIdentity(current) == expected
    }

    private static func productionDirectoryIdentity(_ url: URL) -> FileSystemDocumentIdentity? {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(
            resolvedURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_DIRECTORY
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { return nil }
        return FileSystemDocumentIdentity(value)
    }

    private static func descriptorIsWithin(_ descriptor: Int32, root: URL) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else { return false }
        let terminatingIndex = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let descriptorPath = String(decoding: pathBuffer[..<terminatingIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
        let descriptorURL = URL(fileURLWithPath: descriptorPath)
            .resolvingSymlinksInPath().standardizedFileURL
        return isWithin(descriptorURL, root: root)
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func classifyPOSIX(_ code: Int32) -> FileSystemReadError {
        switch code {
        case ENOENT: return .notFound
        case EACCES, EPERM: return .permissionDenied
        case ENOTDIR: return .notDirectory
        case ELOOP: return .outsideApprovedRoot
        default: return .readFailed
        }
    }

    private static func classifyDirectoryPOSIX(_ code: Int32) -> FileSystemReadError {
        switch code {
        case ENOENT: return .notFound
        case EACCES, EPERM: return .permissionDenied
        case ENOTDIR, ELOOP: return .notDirectory
        default: return .enumerationFailed
        }
    }
}
