import Foundation

/// Progress and coverage published by the indexing coordinator.
public struct IndexingProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case scanning
        case parsing
        case committing
        case completed
        case cancelled
    }

    public let phase: Phase
    public let processedFiles: Int
    public let totalFiles: Int
    public let indexedSessions: Int
    public let lastError: String?
    public let currentFileBytesRead: UInt64?
    public let currentFileTotalBytes: UInt64?

    public init(
        phase: Phase,
        processedFiles: Int,
        totalFiles: Int,
        indexedSessions: Int,
        lastError: String?,
        currentFileBytesRead: UInt64? = nil,
        currentFileTotalBytes: UInt64? = nil
    ) {
        self.phase = phase
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.indexedSessions = indexedSessions
        self.lastError = lastError
        self.currentFileBytesRead = currentFileBytesRead
        self.currentFileTotalBytes = currentFileTotalBytes
    }

    public static let initial = IndexingProgress(
        phase: .idle, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: nil,
        currentFileBytesRead: nil, currentFileTotalBytes: nil
    )
}
