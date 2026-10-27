import Foundation

/// Everything persisted for one session in a single indexing batch.
public struct PersistedSessionBatch: Sendable {
    public let session: TaskSummary
    public let calls: [InvocationEvent]
    public let tokenSnapshots: [TokenUsageSnapshot]
    public let quotaSnapshots: [QuotaSnapshot]
    public let findings: [ReviewFinding]

    public init(
        session: TaskSummary,
        calls: [InvocationEvent],
        tokenSnapshots: [TokenUsageSnapshot],
        quotaSnapshots: [QuotaSnapshot],
        findings: [ReviewFinding]
    ) {
        self.session = session
        self.calls = calls
        self.tokenSnapshots = tokenSnapshots
        self.quotaSnapshots = quotaSnapshots
        self.findings = findings
    }
}

/// Resume point for incremental JSONL parsing.
public struct IndexCheckpoint: Sendable, Equatable {
    public let sourceFileID: String
    public let sourceSize: UInt64
    public let sourceMtime: TimeInterval
    public let byteOffset: UInt64
    public let parserVersion: String
    public let indexedAt: Date

    public init(
        sourceFileID: String,
        sourceSize: UInt64,
        sourceMtime: TimeInterval,
        byteOffset: UInt64,
        parserVersion: String,
        indexedAt: Date
    ) {
        self.sourceFileID = sourceFileID
        self.sourceSize = sourceSize
        self.sourceMtime = sourceMtime
        self.byteOffset = byteOffset
        self.parserVersion = parserVersion
        self.indexedAt = indexedAt
    }
}

/// Joins a bounded derived-index aggregate to the current manual-evaluation
/// store. Evaluations remain authoritative in their existing store; this
/// repository neither copies them into SQLite nor interprets edit time as an
/// invocation timestamp.
public struct CapabilityChangeUsageRepository: Sendable {
    public let database: DatabaseStore?
    public let evaluations: InvocationEvaluationStore

    public init(database: DatabaseStore?, evaluations: InvocationEvaluationStore) {
        self.database = database
        self.evaluations = evaluations
    }

    public func summary(for query: CapabilityChangeUsageQuery) async throws -> CapabilityChangeUsageSummary {
        try await summary(for: query, mayRetryEvaluationMutation: true)
    }

    private func summary(
        for query: CapabilityChangeUsageQuery,
        mayRetryEvaluationMutation: Bool
    ) async throws -> CapabilityChangeUsageSummary {
        let resolution = query.resolve()
        guard resolution.availability == .available else {
            return .unavailable(for: query, availability: resolution.availability)
        }
        guard let database else {
            return .unavailable(for: query, availability: .indexUnavailable)
        }

        // Read only the existing evaluation metadata before querying SQLite.
        // The database then validates these IDs in chunks; it never returns the
        // full interval call list merely so Swift can count it.
        let evaluationSnapshot = await Task.detached(priority: .utility) {
            evaluations.readSnapshot()
        }.value
        let relevantEvaluations: [InvocationEvaluation]
        if evaluationSnapshot.availability == .available {
            relevantEvaluations = evaluationSnapshot.evaluations.values.filter {
                $0.resourceID == query.resourceID
            }
        } else {
            relevantEvaluations = []
        }
        let candidates = relevantEvaluations.map {
            CapabilityChangeUsageEvaluationCandidate(
                invocationID: $0.invocationID,
                sessionID: $0.sessionID
            )
        }
        let cancellation = SQLiteCancellationToken(timeout: .seconds(5))
        let result = try await withTaskCancellationHandler(operation: {
            try await database.fetchCapabilityChangeUsage(
                query,
                evaluationCandidates: candidates,
                cancellation: cancellation
            )
        }, onCancel: {
            cancellation.cancel()
        })
        guard result.availability == .available, let callCount = result.callCount else {
            return .unavailable(for: query, availability: result.availability)
        }

        let currentEvaluationSnapshot = await Task.detached(priority: .utility) {
            evaluations.readSnapshot()
        }.value
        if currentEvaluationSnapshot != evaluationSnapshot {
            if mayRetryEvaluationMutation {
                return try await summary(for: query, mayRetryEvaluationMutation: false)
            }
            // A second mutation raced the retry. Keep the bounded call facts,
            // but never expose ratings from a snapshot that is no longer
            // current; the app-level mutation signal will request a fresh key.
            return CapabilityChangeUsageSummary(
                cacheKey: result.cacheKey,
                availability: .available,
                interval: result.interval,
                callCount: callCount,
                inferredCount: result.inferredCount,
                coverage: result.coverage,
                evaluatedCount: nil,
                effectiveCount: nil,
                ineffectiveCount: nil,
                uncertainCount: nil,
                unratedCount: nil
            )
        }

        guard evaluationSnapshot.availability == .available,
              result.evaluationLookupComplete else {
            return CapabilityChangeUsageSummary(
                cacheKey: result.cacheKey,
                availability: .available,
                interval: result.interval,
                callCount: callCount,
                inferredCount: result.inferredCount,
                coverage: result.coverage,
                evaluatedCount: nil,
                effectiveCount: nil,
                ineffectiveCount: nil,
                uncertainCount: nil,
                unratedCount: nil
            )
        }

        let evaluationByID = Dictionary(
            uniqueKeysWithValues: relevantEvaluations.map { ($0.invocationID, $0) }
        )
        var effectiveCount = 0
        var ineffectiveCount = 0
        var uncertainCount = 0
        for call in result.matchedEvaluationCalls {
            guard let evaluation = evaluationByID[call.invocationID],
                  evaluation.sessionID == call.sessionID,
                  evaluation.resourceID == query.resourceID else { continue }
            switch evaluation.label {
            case .effective: effectiveCount += 1
            case .ineffective: ineffectiveCount += 1
            case .uncertain: uncertainCount += 1
            }
        }
        let evaluatedCount = effectiveCount + ineffectiveCount + uncertainCount
        return CapabilityChangeUsageSummary(
            cacheKey: result.cacheKey,
            availability: .available,
            interval: result.interval,
            callCount: callCount,
            inferredCount: result.inferredCount,
            coverage: result.coverage,
            evaluatedCount: evaluatedCount,
            effectiveCount: effectiveCount,
            ineffectiveCount: ineffectiveCount,
            uncertainCount: uncertainCount,
            unratedCount: max(0, callCount - evaluatedCount)
        )
    }
}
