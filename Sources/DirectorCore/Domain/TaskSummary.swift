import Foundation

/// High-level outcome of a Codex task/session.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case running
    case completed
    case interrupted
    case failed
    case unknown
}

/// Privacy-safe summary of one Codex session. Never carries prompt or
/// response text; `title` is an optional derived, redacted display label.
public struct TaskSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let status: TaskStatus
    public let coverage: CoverageState
    public let parserVersion: String
    public let sourceFileID: String
    public let title: String?

    public init(
        id: String,
        projectID: String?,
        startedAt: Date?,
        endedAt: Date?,
        status: TaskStatus,
        coverage: CoverageState,
        parserVersion: String,
        sourceFileID: String,
        title: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.coverage = coverage
        self.parserVersion = parserVersion
        self.sourceFileID = sourceFileID
        self.title = title
    }
}
