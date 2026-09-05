import Foundation

/// Coarse operation names used only by isolated performance/latency harnesses.
/// No query arguments, identifiers, paths, or rows are exposed.
public enum PresentationQueryOperation: String, Codable, Sendable {
    case directory
    case startup
    case quota
    case library
    case taskSummaries
    case allSessions
    case allQuotas
    case allTokens
    case allInvocations
    case findings
    case diagnostics
    case identity
}

/// Small, bounded diagnostics projection for Settings and validation hosts.
public struct PresentationDiagnosticsSummary: Codable, Equatable, Sendable {
    public let metadata: PresentationIndexMetadata
    public let parserCoverageFindingCount: Int
    public let partialCoverageSessionCount: Int
    public let sessionCount: Int

    public init(
        metadata: PresentationIndexMetadata,
        parserCoverageFindingCount: Int,
        partialCoverageSessionCount: Int,
        sessionCount: Int
    ) {
        self.metadata = metadata
        self.parserCoverageFindingCount = parserCoverageFindingCount
        self.partialCoverageSessionCount = partialCoverageSessionCount
        self.sessionCount = sessionCount
    }
}

/// Coarse source-index lifecycle events used by isolated harnesses.
public enum SourceIndexPhase: String, Codable, Sendable {
    case started
    case completed
    case cancelled
    case failed
}
