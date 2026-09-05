import Foundation

/// Read-only filesystem access for discovery.
///
/// Wrapped in a small struct so scanner behavior is testable and the
/// write-boundary is explicit: this client has no write operations.
/// `FileManager` is thread-safe for the read APIs used here.
public struct FileSystemClient: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    public func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Directory entries including hidden entries (dot-files such as
    /// `.codex-plugin` must be discoverable).
    public func contents(_ url: URL) -> [URL] {
        guard isDirectory(url) else { return [] }
        return (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
    }

    public func isReadable(_ url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.path)
    }

    /// Size and modification time for change detection.
    public func fileAttributes(_ url: URL) -> (size: UInt64, modificationDate: TimeInterval)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return (size, date.timeIntervalSince1970)
    }
}
