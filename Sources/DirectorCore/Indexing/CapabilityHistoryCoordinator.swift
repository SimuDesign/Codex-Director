import Foundation

/// Application-scoped history lifecycle owner. It receives already-scanned
/// batches from the one indexing pipeline and never starts scans, timers,
/// watchers, runtime processes or SQLite work of its own.
public actor CapabilityHistoryCoordinator {
    public typealias BeforeCommitHook = @Sendable () async throws -> Void

    enum StoreAccessOperation: Sendable {
        case submit
        case page
        case status
        case cancel
        case clear
    }

    typealias StoreAccessProbe = @Sendable (StoreAccessOperation) -> Void

    private let store: CapabilityHistoryStore
    public nonisolated let accessMode: CapabilityHistoryAccessMode
    private let beforeCommitHook: BeforeCommitHook?
    private let storeAccessProbe: StoreAccessProbe?
    private var generation: UInt64 = 1
    private var cachedStatus: CapabilityHistoryStatus
    private var pendingSubmissionIssues = Set<CapabilityHistoryIssueCode>()
    private var latestObservationSaveFailed = false

    public init(
        store: CapabilityHistoryStore,
        beforeCommitHook: BeforeCommitHook? = nil
    ) {
        self.store = store
        accessMode = store.accessMode
        self.beforeCommitHook = beforeCommitHook
        storeAccessProbe = nil
        cachedStatus = CapabilityHistoryStatus(
            accessMode: store.accessMode,
            epoch: nil,
            revision: nil,
            eventCount: nil,
            baselineCount: nil,
            issueCodes: store.accessMode == .readOnly ? [.readOnlyLockConflict] : []
        )
    }

    /// Internal instrumentation seam for synthetic tests proving that
    /// MainActor presentation mutations do not enter the history actor's
    /// storage paths.
    init(
        store: CapabilityHistoryStore,
        beforeCommitHook: BeforeCommitHook? = nil,
        storeAccessProbe: @escaping StoreAccessProbe
    ) {
        self.store = store
        accessMode = store.accessMode
        self.beforeCommitHook = beforeCommitHook
        self.storeAccessProbe = storeAccessProbe
        cachedStatus = CapabilityHistoryStatus(
            accessMode: store.accessMode,
            epoch: nil,
            revision: nil,
            eventCount: nil,
            baselineCount: nil,
            issueCodes: store.accessMode == .readOnly ? [.readOnlyLockConflict] : []
        )
    }

    /// Commits one raw filesystem observation batch after the derived resource
    /// inventory transaction has succeeded. Cache restoration is deliberately
    /// ignored without opening the history file.
    public func submit(
        _ batch: CapabilityHistoryScanBatch
    ) async throws -> CapabilityHistoryCommitResult? {
        guard batch.source == .filesystem else { return nil }
        storeAccessProbe?(.submit)
        let capturedGeneration = generation
        let permit = try await store.issueWritePermit()
        if let beforeCommitHook { try await beforeCommitHook() }
        try Task.checkCancellation()
        guard capturedGeneration == generation else { throw CancellationError() }
        do {
            let result = try await store.commit(batch, permit: permit)
            guard capturedGeneration == generation else { throw CancellationError() }
            pendingSubmissionIssues.removeAll()
            latestObservationSaveFailed = false
            cachedStatus = await store.status()
            return result
        } catch {
            guard capturedGeneration == generation else { throw CancellationError() }
            let current = await store.status()
            guard capturedGeneration == generation else { throw CancellationError() }
            let retainedHistoryIsReadable = current.epoch != nil && current.revision != nil
            let issue: CapabilityHistoryIssueCode
            if error is CancellationError {
                issue = .historyGap
            } else if let storeError = error as? CapabilityHistoryStore.StoreError {
                switch storeError {
                case .readOnly:
                    issue = .readOnlyLockConflict
                case .corrupt:
                    issue = .corruptStorage
                case .invalidState:
                    issue = retainedHistoryIsReadable ? .storageUnavailable : .corruptStorage
                case .unsupportedVersion:
                    issue = .unsupportedSchema
                case .oversized, .fileBudgetExceeded:
                    issue = .fileBudgetExceeded
                default:
                    issue = .storageUnavailable
                }
            } else {
                issue = .storageUnavailable
            }
            latestObservationSaveFailed = Self.isObservationSaveFailure(
                error,
                readableStatus: current
            )
            pendingSubmissionIssues.insert(issue)
            cachedStatus = status(
                basedOn: current,
                issueCodes: Set(current.issueCodes).union([issue])
            )
            throw error
        }
    }

    public func page(_ query: CapabilityHistoryQuery) async throws -> CapabilityHistoryPage {
        storeAccessProbe?(.page)
        let page = try await store.page(query)
        cachedStatus = preservingSubmissionIssues(await store.status())
        return page
    }

    public func eventBoundary(
        eventID: String,
        resourceID: String,
        observedAt: Date
    ) async throws -> CapabilityHistoryEventBoundary? {
        storeAccessProbe?(.page)
        return try await store.eventBoundary(
            eventID: eventID,
            resourceID: resourceID,
            observedAt: observedAt
        )
    }

    public func status(refresh: Bool = true) async -> CapabilityHistoryStatus {
        if refresh {
            storeAccessProbe?(.status)
            cachedStatus = preservingSubmissionIssues(await store.status())
        }
        return cachedStatus
    }

    /// Invalidates delayed submissions without deleting any history. The next
    /// normal source refresh can immediately obtain a permit in the new
    /// generation.
    public func cancelPendingWrites() async {
        storeAccessProbe?(.cancel)
        generation &+= 1
        await store.revokeWritePermits()
    }

    public func clearConfirmed() async throws -> CapabilityHistoryStatus {
        storeAccessProbe?(.clear)
        generation &+= 1
        await store.revokeWritePermits()
        let status = try await store.clearConfirmed(true)
        pendingSubmissionIssues.removeAll()
        latestObservationSaveFailed = false
        cachedStatus = status
        return status
    }

    private func preservingSubmissionIssues(_ status: CapabilityHistoryStatus) -> CapabilityHistoryStatus {
        guard !pendingSubmissionIssues.isEmpty || latestObservationSaveFailed else { return status }
        return self.status(
            basedOn: status,
            issueCodes: Set(status.issueCodes).union(pendingSubmissionIssues)
        )
    }

    private func status(
        basedOn status: CapabilityHistoryStatus,
        issueCodes: Set<CapabilityHistoryIssueCode>
    ) -> CapabilityHistoryStatus {
        // A failed read is authoritative. Do not let a prior in-memory save
        // signal mask an unreadable, corrupt, or unsupported store status.
        let readable = status.epoch != nil && status.revision != nil
        return CapabilityHistoryStatus(
            accessMode: status.accessMode,
            epoch: status.epoch,
            revision: status.revision,
            eventCount: status.eventCount,
            baselineCount: status.baselineCount,
            isInitialized: status.isInitialized,
            initializedScopeCount: status.initializedScopeCount,
            latestScanCoverage: status.latestScanCoverage,
            pendingMissingCount: status.pendingMissingCount,
            issueCodes: Array(issueCodes)
                .sorted { $0.rawValue < $1.rawValue },
            latestObservationSaveFailed: readable && latestObservationSaveFailed
        )
    }

    private static func isObservationSaveFailure(
        _ error: Error,
        readableStatus: CapabilityHistoryStatus
    ) -> Bool {
        guard readableStatus.epoch != nil, readableStatus.revision != nil else { return false }
        if error is CancellationError { return false }
        guard let storeError = error as? CapabilityHistoryStore.StoreError else {
            // The store was readable before/after the commit boundary, so a
            // non-store error from commit is an actual save failure rather
            // than a read, permit, or cancellation failure.
            return true
        }
        switch storeError {
        case .atomicWriteFailed, .fileBudgetExceeded, .storageUnavailable,
             .injectedFailure, .invalidState:
            return true
        case .oversized, .corrupt, .unsupportedVersion, .readOnly,
             .stalePermit, .confirmationRequired:
            return false
        }
    }
}
