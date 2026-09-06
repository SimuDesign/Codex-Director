import Foundation
import DirectorCore

/// A refreshable presentation domain. Domains are deliberately independent so
/// a quota failure cannot invalidate a usable capability directory.
public enum RefreshDomain: String, CaseIterable, Codable, Sendable {
    case quota
    case directory
    /// Reads the privacy-sanitized account quota snapshot through Codex
    /// app-server. This domain never implies source indexing.
    case accountUsage
    /// Re-ranks the Home summary from the current bounded recent-usage DTO.
    /// This domain is projection-only and must never imply a source scan.
    case homeRankings
    case currentPage
    case detail
}

public enum RefreshReason: String, Codable, Sendable {
    case startup
    case automatic
    /// A passive menu-bar allowance request. It is intentionally distinct
    /// from capability automatic work so the app can cancel it when the
    /// menu-bar schedule is paused without disturbing a manual refresh.
    case accountUsageAutomatic
    case manual
    case indexCommitted
    case dayChanged
    case menuBar
}

public struct RefreshRequest: Equatable, Sendable {
    public let domains: Set<RefreshDomain>
    public let reason: RefreshReason
    public let force: Bool
    /// Whether this request explicitly permits a source phase. Commit and
    /// day-change requests remain projection-only even when forced.
    public let sourceIntent: Bool
    /// Retained for source compatibility with older callers. Source work is
    /// now selected explicitly by `sourceIntent`; presentation reads always
    /// use the bounded timeout.
    public let allowsLongRunning: Bool

    public init(
        domains: Set<RefreshDomain> = Set(RefreshDomain.allCases),
        reason: RefreshReason = .manual,
        force: Bool? = nil,
        allowsLongRunning: Bool = false,
        sourceIntent: Bool? = nil
    ) {
        self.domains = domains
        self.reason = reason
        self.force = force ?? (reason == .manual)
        self.sourceIntent = sourceIntent ?? (reason == .manual || reason == .startup || reason == .automatic)
        self.allowsLongRunning = allowsLongRunning
    }

    public static func all(_ reason: RefreshReason = .manual, force: Bool? = nil, allowsLongRunning: Bool = false, sourceIntent: Bool? = nil) -> RefreshRequest {
        RefreshRequest(domains: Set(RefreshDomain.allCases), reason: reason, force: force, allowsLongRunning: allowsLongRunning, sourceIntent: sourceIntent)
    }
}

public enum RefreshOutcome: Equatable, Sendable {
    case completed
    case noNewData
    case notDue
    case deferred
    case cancelled
    case timedOut
    case failed(String)
}

/// Result of the optional source phase. A skipped source phase is not a
/// successful check and therefore never advances the source freshness TTL.
public enum SourceRefreshOutcome: Equatable, Sendable {
    case skipped
    case succeeded(Date)
    case failed(String)
    case cancelled
}

public enum RefreshPhase: String, Codable, Sendable {
    case idle
    case startupGrace
    case source
    case projection
    case waiting
    case failed
}

/// UI-facing scheduler state. The persisted subset is represented by
/// `PresentationRefreshSchedule` in DirectorCore; phase is intentionally
/// ephemeral and is not written to the presentation cache.
public struct RefreshScheduleState: Equatable, Sendable {
    public let revision: UInt64
    public let phase: RefreshPhase
    public let lastSourceSuccessAt: Date?
    public let sourceRetryAttempt: Int
    public let sourceRetryDate: Date?
    public let projectionRetryAttempt: Int
    public let projectionRetryDate: Date?

    public init(
        revision: UInt64,
        phase: RefreshPhase,
        lastSourceSuccessAt: Date?,
        sourceRetryAttempt: Int,
        sourceRetryDate: Date?,
        projectionRetryAttempt: Int,
        projectionRetryDate: Date?
    ) {
        self.revision = revision
        self.phase = phase
        self.lastSourceSuccessAt = lastSourceSuccessAt
        self.sourceRetryAttempt = sourceRetryAttempt
        self.sourceRetryDate = sourceRetryDate
        self.projectionRetryAttempt = projectionRetryAttempt
        self.projectionRetryDate = projectionRetryDate
    }
}

/// Application-scoped refresh scheduling.
///
/// The coordinator owns scheduling state only. The operation owns database
/// connections and cancellation-aware work, and must return immutable results.
/// All requests received during a run are merged; a changed request can cause
/// at most one additional run before the current batch is released.
@MainActor
public final class RefreshCoordinator {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias Operation = @Sendable (RefreshRequest) async throws -> RefreshOutcome
    public typealias SourceOperation = @Sendable (RefreshRequest) async throws -> SourceRefreshOutcome
    public typealias StateChangeHandler = @MainActor @Sendable (RefreshScheduleState) -> Void

    public let interval: TimeInterval
    public let initialGrace: TimeInterval
    public let timeout: TimeInterval

    public private(set) var isRunning = false
    public private(set) var isStopped = false
    public private(set) var lastSuccessfulAt: Date?
    public private(set) var nextAutomaticDate: Date?
    public private(set) var retryAttempt = 0
    public private(set) var scheduleState = RefreshScheduleState(
        revision: 0,
        phase: .idle,
        lastSourceSuccessAt: nil,
        sourceRetryAttempt: 0,
        sourceRetryDate: nil,
        projectionRetryAttempt: 0,
        projectionRetryDate: nil
    )

    public var nextWakeDate: Date? {
        var dates: [Date] = []
        if let startupDeadline { dates.append(startupDeadline) }
        if let projectionRetryDateValue { dates.append(projectionRetryDateValue) }
        if startupDeadline == nil, automaticSourceEnabled {
            if let sourceRetryDateValue {
                dates.append(sourceRetryDateValue)
            } else if sourceOperation != nil {
                dates.append(lastSuccessfulAt?.addingTimeInterval(interval) ?? clock())
            }
        }
        return dates.min()
    }

    /// Test/diagnostic seam for deterministic coalescing assertions. This is
    /// intentionally not part of the user-facing scheduler API.
    internal var pendingWaiterCount: Int {
        activeWaiters.count + nextBatchWaiters.count
    }

    private let clock: Clock
    private let sleeper: Sleeper
    private let timeoutOperation: @Sendable (TimeInterval) async -> RefreshOutcome
    private let operation: Operation
    private let sourceOperation: SourceOperation?
    private var stateChangeHandler: StateChangeHandler?
    private var stateRevision: UInt64 = 0
    private var sourceRetryAttemptValue = 0
    private var sourceRetryDateValue: Date?
    private var projectionRetryAttemptValue = 0
    private var projectionRetryDateValue: Date?
    private var automaticSourceEnabled = true
    private var workerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var pendingRequest: RefreshRequest?
    private var activeWaiters: [CheckedContinuation<RefreshOutcome, Never>] = []
    private var nextBatchWaiters: [CheckedContinuation<RefreshOutcome, Never>] = []
    private var activeRounds = 0
    private var activeRequest: RefreshRequest?
    private var generation = 0
    private var startupEpoch = 0
    private var startupDeadline: Date?
    private var retryDate: Date?
    private var drainCount = 0
    private var isDraining: Bool { drainCount > 0 }
    private var activeSourceOutcome: SourceRefreshOutcome?

    public init(
        interval: TimeInterval = 30 * 60,
        initialGrace: TimeInterval = 5,
        timeout: TimeInterval = 5,
        clock: @escaping Clock = Date.init,
        sleeper: Sleeper? = nil,
        timeoutSleeper: Sleeper? = nil,
        sourceOperation: SourceOperation? = nil,
        operation: @escaping Operation
    ) {
        self.interval = max(0, interval)
        self.initialGrace = max(0, initialGrace)
        self.timeout = max(0, timeout)
        self.clock = clock
        // Construct the default async closure inside this module. The
        // diagnostic crash only appeared when the same closure was supplied
        // through a default argument at the call site; explicit injected
        // sleepers completed successfully. This preserves the real Duration
        // timeout while avoiding that default-argument construction context.
        let resolvedSleeper: Sleeper
        if let sleeper {
            resolvedSleeper = sleeper
        } else {
            let defaultSleeper: Sleeper = { seconds in
                try await Task.sleep(for: .seconds(seconds))
            }
            resolvedSleeper = defaultSleeper
        }
        self.sleeper = resolvedSleeper
        let resolvedTimeoutSleeper: Sleeper
        if let timeoutSleeper {
            resolvedTimeoutSleeper = timeoutSleeper
        } else {
            resolvedTimeoutSleeper = resolvedSleeper
        }
        self.timeoutOperation = { seconds in
            do {
                try await resolvedTimeoutSleeper(seconds)
                return .timedOut
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .cancelled
            }
        }
        self.sourceOperation = sourceOperation
        self.operation = operation
    }

    deinit {
        workerTask?.cancel()
        startupTask?.cancel()
    }

    public func setStateChangeHandler(_ handler: StateChangeHandler?) {
        stateChangeHandler = handler
    }

    public func setAutomaticSourceEnabled(_ enabled: Bool) {
        automaticSourceEnabled = enabled
    }

    public var persistedSchedule: PresentationRefreshSchedule {
        PresentationRefreshSchedule(
            revision: scheduleState.revision,
            recordedAt: clock(),
            lastSourceSuccessAt: scheduleState.lastSourceSuccessAt,
            sourceRetryAttempt: scheduleState.sourceRetryAttempt,
            sourceRetryDate: scheduleState.sourceRetryDate,
            projectionRetryAttempt: scheduleState.projectionRetryAttempt,
            projectionRetryDate: scheduleState.projectionRetryDate
        )
    }

    /// Restores scheduler metadata without starting work. The revision is
    /// advanced past both local and persisted state so a later callback cannot
    /// overwrite a newer persisted value with an older one.
    public func restoreScheduleState(_ persisted: PresentationRefreshSchedule) {
        let now = clock()
        // UInt64.max is not a usable persisted revision: accepting it would
        // saturate every later callback and prevent consumers from observing
        // a strictly newer state. Rebase corrupt input before applying it.
        let baseRevision = persisted.revision == UInt64.max ? stateRevision : max(stateRevision, persisted.revision)
        let revision = baseRevision < UInt64.max ? baseRevision + 1 : baseRevision
        stateRevision = revision

        let recordedAtIsValid = persisted.recordedAt.timeIntervalSinceReferenceDate.isFinite && persisted.recordedAt <= now
        let sourceSuccess = recordedAtIsValid ? validPastDate(persisted.lastSourceSuccessAt, now: now) : nil
        let sourceRetry = validatedRetry(
            attempt: persisted.sourceRetryAttempt,
            date: persisted.sourceRetryDate,
            recordedAt: persisted.recordedAt,
            now: now
        )
        let projectionRetry = validatedRetry(
            attempt: persisted.projectionRetryAttempt,
            date: persisted.projectionRetryDate,
            recordedAt: persisted.recordedAt,
            now: now
        )

        lastSuccessfulAt = sourceSuccess
        sourceRetryAttemptValue = sourceRetry.attempt
        sourceRetryDateValue = sourceRetry.date
        projectionRetryAttemptValue = projectionRetry.attempt
        projectionRetryDateValue = projectionRetry.date
        syncCompatibilityFields()
        publishScheduleState(phase: (sourceRetry.date != nil || projectionRetry.date != nil) ? .waiting : .idle, revision: revision)
    }

    /// Automatic work observes the earliest eligible domain. A pending
    /// projection retry takes priority only once due; a future projection
    /// retry does not block an earlier source check.
    @discardableResult
    public func requestAutomatic(domains: Set<RefreshDomain> = Set(RefreshDomain.allCases)) async -> RefreshOutcome {
        let now = clock()
        let projectionDue = projectionRetryDateValue.map { $0 <= now } ?? false
        let sourceDue = sourceWorkIsDue(at: now)
        return await request(RefreshRequest(
            domains: domains,
            reason: .automatic,
            force: false,
            sourceIntent: sourceDue && !projectionDue
        ))
    }

    private func validPastDate(_ date: Date?, now: Date) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite, date <= now else { return nil }
        return date
    }

    private func validatedRetry(attempt: Int, date: Date?, recordedAt: Date, now: Date) -> (attempt: Int, date: Date?) {
        guard (1...3).contains(attempt),
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              recordedAt <= now,
              let date,
              date.timeIntervalSinceReferenceDate.isFinite else {
            return (0, nil)
        }
        let allowedDelay: TimeInterval = [0, 5 * 60, 15 * 60, 30 * 60][attempt]
        guard date <= recordedAt.addingTimeInterval(allowedDelay) else {
            return (0, nil)
        }
        return (attempt, date)
    }

    private func syncCompatibilityFields() {
        retryAttempt = max(sourceRetryAttemptValue, projectionRetryAttemptValue)
        if sourceRetryAttemptValue > 0 {
            retryDate = sourceRetryDateValue
        } else {
            retryDate = projectionRetryDateValue
        }
        nextAutomaticDate = retryDate ?? lastSuccessfulAt?.addingTimeInterval(interval)
    }

    private func publishScheduleState(phase: RefreshPhase, revision: UInt64? = nil) {
        if let revision {
            stateRevision = max(stateRevision, revision)
        } else {
            if stateRevision < UInt64.max { stateRevision += 1 }
        }
        scheduleState = RefreshScheduleState(
            revision: stateRevision,
            phase: phase,
            lastSourceSuccessAt: lastSuccessfulAt,
            sourceRetryAttempt: sourceRetryAttemptValue,
            sourceRetryDate: sourceRetryDateValue,
            projectionRetryAttempt: projectionRetryAttemptValue,
            projectionRetryDate: projectionRetryDateValue
        )
        stateChangeHandler?(scheduleState)
    }

    /// Restores a successful check from a presentation cache without running
    /// work. The caller supplies the persisted timestamp; no historical time
    /// is invented at launch.
    public func restoreSuccessfulCheck(at date: Date) {
        restoreScheduleState(PresentationRefreshSchedule(recordedAt: clock(), lastSourceSuccessAt: date))
    }

    /// Requests work and awaits the result for this coalesced batch.
    @discardableResult
    public func request(_ request: RefreshRequest) async -> RefreshOutcome {
        let request = normalizedAutomaticRequest(request)
        guard !isStopped, !isDraining else { return .cancelled }
        if !request.force {
            let now = clock()
            if !isDue(at: now) {
                return (sourceRetryDateValue != nil || projectionRetryDateValue != nil) ? .deferred : .notDue
            }
        }

        return await withCheckedContinuation { continuation in
            // A repeated request for work already being performed joins the
            // current result. A new domain, or an explicit committed version,
            // is the only reason to spend the one permitted follow-up round.
            let joinsCurrent = isRunning && activeRequest.map {
                request.reason != .indexCommitted && request.reason != .dayChanged && request.domains.isSubset(of: $0.domains)
                    && (!request.sourceIntent || $0.sourceIntent)
                    && !(request.reason == .manual && activeSourceOutcome == .skipped)
            } ?? false
            if !joinsCurrent {
                // A projection-only event supersedes a startup grace request
                // that has not begun. Do not carry startup's source intent
                // into a commit/day-change refresh.
                if !isRunning && (request.reason == .indexCommitted || request.reason == .dayChanged), pendingRequest?.reason == .startup {
                    pendingRequest = pendingRequest.map {
                        RefreshRequest(
                            domains: $0.domains.union(request.domains),
                            reason: request.reason,
                            force: true,
                            sourceIntent: false
                        )
                    } ?? request
                } else {
                    let requestedFollowUp = activeRequest.map {
                        RefreshRequest(
                            domains: $0.domains.union(request.domains),
                            reason: strongerReason($0.reason, request.reason),
                            force: $0.force || request.force,
                            allowsLongRunning: request.sourceIntent,
                            sourceIntent: request.sourceIntent
                        )
                    }
                    pendingRequest = merge(pendingRequest, requestedFollowUp ?? request)
                }
            }
            if isRunning && !joinsCurrent {
                nextBatchWaiters.append(continuation)
            } else {
                activeWaiters.append(continuation)
            }
            if request.force, startupTask != nil {
                startupEpoch &+= 1
                startupTask?.cancel()
                startupTask = nil
                startupDeadline = nil
            }
            // Explicit startup work (used for the first bounded projection)
            // is already being awaited by its caller and must not acquire
            // the interactive startup grace delay. The ordinary scheduled
            // startup path remains force=false and keeps the grace period.
            if request.reason == .startup, !request.force, initialGrace > 0, !isRunning {
                scheduleStartupIfNeeded()
            } else {
                startWorkerIfNeeded()
            }
        }
    }

    /// Convenience for callers that keep the request fields separate.
    @discardableResult
    public func request(
        domains: Set<RefreshDomain> = Set(RefreshDomain.allCases),
        reason: RefreshReason,
        force: Bool? = nil
    ) async -> RefreshOutcome {
        await request(RefreshRequest(domains: domains, reason: reason, force: force))
    }

    /// Schedules the startup request without requiring a view/window to await
    /// it. The first window remains interactive during the grace interval.
    public func scheduleStartup(domains: Set<RefreshDomain> = Set(RefreshDomain.allCases)) {
        guard !isStopped, !isDraining, isDue(at: clock()), !isRunning else { return }
        pendingRequest = merge(pendingRequest, RefreshRequest(domains: domains, reason: .startup, force: false, sourceIntent: automaticSourceEnabled))
        scheduleStartupIfNeeded()
    }

    /// Marks a newer committed version. If a run is active, the version is
    /// folded into the one permitted follow-up request.
    public func requestAfterCommit(domains: Set<RefreshDomain> = Set(RefreshDomain.allCases)) {
        guard !isStopped, !isDraining else { return }
        let request = RefreshRequest(domains: domains, reason: .indexCommitted, force: true)
        if isRunning {
            // Preserve a stronger source intent already queued for the active
            // batch, while adding the commit as its single projection follow-
            // up. The active source phase itself remains unchanged.
            pendingRequest = merge(pendingRequest, request)
            return
        }
        if pendingRequest?.reason == .startup {
            pendingRequest = pendingRequest.map { RefreshRequest(domains: $0.domains.union(request.domains), reason: .indexCommitted, force: true, sourceIntent: false) } ?? request
        } else {
            pendingRequest = merge(pendingRequest, request)
        }
        // A committed database version should update the projection promptly;
        // it must not wait behind the startup grace timer. The request remains
        // projection-only because its sourceIntent is false.
        startupEpoch &+= 1
        startupTask?.cancel()
        startupTask = nil
        startupDeadline = nil
        startWorkerIfNeeded()
    }

    /// Cancels the active operation and any scheduled startup. Operations must
    /// cooperate with Task cancellation; a late result cannot be published.
    public func cancel() {
        startupEpoch &+= 1
        startupTask?.cancel()
        startupTask = nil
        generation &+= 1
        workerTask?.cancel()
        pendingRequest = nil
        startupDeadline = nil
        finish(&activeWaiters, with: .cancelled)
        finish(&nextBatchWaiters, with: .cancelled)
        if workerTask == nil {
            isRunning = false
            activeRounds = 0
        }
    }

    /// Cancels an account-only passive request without disturbing an active
    /// manual/source/projection batch. If a manual request was coalesced as a
    /// follow-up to the passive account operation, cancel the active account
    /// round and preserve the local domains for that user request. The
    /// account domain is deferred until the menu-bar scheduler is eligible
    /// again rather than being started under lock, sleep, or Low Power Mode.
    public func cancelScheduledAccountUsage() {
        let scheduled = { (request: RefreshRequest?) in
            request?.reason == .accountUsageAutomatic && request?.domains == [.accountUsage]
        }

        if scheduled(activeRequest) {
            if let pendingRequest {
                let localDomains = pendingRequest.domains.subtracting([.accountUsage])
                if localDomains.isEmpty {
                    self.pendingRequest = nil
                    finish(&nextBatchWaiters, with: .cancelled)
                } else {
                    self.pendingRequest = RefreshRequest(
                        domains: localDomains,
                        reason: pendingRequest.reason,
                        force: pendingRequest.force,
                        allowsLongRunning: pendingRequest.allowsLongRunning,
                        sourceIntent: pendingRequest.sourceIntent
                    )
                }
            }
            cancelActiveScheduledAccountUsage()
            return
        }

        if !isRunning {
            guard scheduled(pendingRequest) else { return }
            pendingRequest = nil
            finish(&activeWaiters, with: .cancelled)
            return
        }

        if scheduled(activeRequest), pendingRequest == nil, nextBatchWaiters.isEmpty {
            cancel()
        } else if scheduled(pendingRequest), nextBatchWaiters.count == 1 {
            pendingRequest = nil
            finish(&nextBatchWaiters, with: .cancelled)
        }
    }

    /// Invalidates only the active passive account round. The worker's
    /// generation guard drains the cancelled operation and promotes any
    /// preserved local follow-up; unlike `cancel()`, this intentionally does
    /// not discard explicit user work already waiting behind it.
    private func cancelActiveScheduledAccountUsage() {
        generation &+= 1
        workerTask?.cancel()
        finish(&activeWaiters, with: .cancelled)
        guard workerTask != nil else {
            isRunning = false
            activeRounds = 0
            activeRequest = nil
            activeSourceOutcome = nil
            promoteNextBatchIfNeeded()
            return
        }
    }

    /// Cancels current work and waits until the cooperative worker has exited.
    /// No replacement batch can begin before this method returns.
    public func cancelAndWait() async {
        drainCount += 1
        let task = workerTask
        cancel()
        await task?.value
        drainCount = max(0, drainCount - 1)
    }

    /// Stops the application-scoped scheduler. A stopped coordinator rejects
    /// future work and leaves no polling task behind.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        cancel()
    }

    private func isDue(at now: Date) -> Bool {
        if let projectionRetryDateValue, projectionRetryDateValue <= now { return true }
        if !automaticSourceEnabled {
            return projectionRetryDateValue == nil
        }
        if let sourceRetryDateValue {
            return sourceRetryDateValue <= now
        }
        if sourceOperation == nil {
            return projectionRetryDateValue == nil
        }
        return sourceWorkIsDue(at: now)
    }

    private func sourceWorkIsDue(at now: Date) -> Bool {
        guard automaticSourceEnabled, sourceOperation != nil else { return false }
        if let sourceRetryDateValue { return sourceRetryDateValue <= now }
        guard let lastSuccessfulAt else { return true }
        return now >= lastSuccessfulAt.addingTimeInterval(interval)
    }

    private func normalizedAutomaticRequest(_ request: RefreshRequest) -> RefreshRequest {
        guard request.reason == .automatic, !request.force,
              projectionRetryDateValue.map({ $0 <= clock() }) == true else {
            return request
        }
        return RefreshRequest(
            domains: request.domains,
            reason: request.reason,
            force: request.force,
            allowsLongRunning: request.allowsLongRunning,
            sourceIntent: false
        )
    }

    private func scheduleStartupIfNeeded() {
        guard startupTask == nil, !isStopped, !isDraining, !isRunning, isDue(at: clock()) else { return }
        let deadline = startupDeadline ?? clock().addingTimeInterval(initialGrace)
        startupDeadline = deadline
        let delay = max(0, deadline.timeIntervalSince(clock()))
        startupEpoch &+= 1
        let epoch = startupEpoch
        publishScheduleState(phase: .startupGrace)
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper(delay)
            } catch {
                guard !Task.isCancelled, self.startupEpoch == epoch else { return }
                self.startupTask = nil
                self.startupDeadline = nil
                self.pendingRequest = nil
                self.publishScheduleState(phase: .failed)
                self.finish(&self.activeWaiters, with: .failed("startup_wait_failed"))
                return
            }
            guard !Task.isCancelled, !self.isStopped, self.startupEpoch == epoch else { return }
            self.startupTask = nil
            self.startupDeadline = nil
            self.publishScheduleState(phase: .waiting)
            self.startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, startupTask == nil, !isStopped, !isDraining, pendingRequest != nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.runBatch()
        }
    }

    private func runBatch() async {
        let batchGeneration = generation
        isRunning = true
        activeRounds = 0
        var rounds = 0
        var outcome: RefreshOutcome = .cancelled

        while let request = pendingRequest,
              rounds < 2,
              batchGeneration == generation,
              !Task.isCancelled,
              !isStopped {
            pendingRequest = nil
            if rounds > 0 {
                // Requests which caused this follow-up belong to the same
                // coalesced result. Requests arriving during the follow-up
                // remain in nextBatchWaiters for the next bounded batch.
                activeWaiters.append(contentsOf: nextBatchWaiters)
                nextBatchWaiters.removeAll(keepingCapacity: false)
            }
            rounds += 1
            activeRounds = rounds
            activeRequest = request
            var sourceOutcome: SourceRefreshOutcome = .skipped
            activeSourceOutcome = nil
            let mayRunSource = request.sourceIntent &&
                request.reason != .indexCommitted &&
                request.reason != .dayChanged
            publishScheduleState(phase: mayRunSource ? .source : .projection)
            do {
                if let sourceOperation, mayRunSource {
                    sourceOutcome = try await sourceOperation(request)
                    activeSourceOutcome = sourceOutcome
                    switch sourceOutcome {
                    case .failed(let message):
                        // Keep the existing presentation usable when the
                        // source phase fails. Do not rebuild or publish a
                        // partial presentation from the failed source.
                        outcome = .failed(message)
                    case .cancelled:
                        outcome = .cancelled
                    case .skipped, .succeeded:
                        publishScheduleState(phase: .projection)
                        outcome = try await execute(request)
                    }
                } else {
                    activeSourceOutcome = .skipped
                    outcome = try await execute(request)
                }
            } catch is CancellationError {
                if mayRunSource { sourceOutcome = .cancelled }
                outcome = .cancelled
            } catch {
                if mayRunSource { sourceOutcome = .failed("source_failed") }
                outcome = .failed(mayRunSource ? "source_failed" : "refresh_failed")
            }
            guard batchGeneration == generation else { break }
            apply(outcome, source: sourceOutcome, request: request, at: clock())
        }

        guard batchGeneration == generation else {
            isRunning = false
            activeRounds = 0
            activeRequest = nil
            activeSourceOutcome = nil
            workerTask = nil
            promoteNextBatchIfNeeded()
            return
        }
        isRunning = false
        activeRounds = 0
        activeRequest = nil
        activeSourceOutcome = nil
        workerTask = nil
        if Task.isCancelled || isStopped {
            finish(&activeWaiters, with: .cancelled)
        } else {
            finish(&activeWaiters, with: outcome)
        }

        // A request that arrived during the follow-up is intentionally
        // deferred to a new batch, rather than creating an unbounded chain.
        if pendingRequest != nil, !isStopped {
            promoteNextBatchIfNeeded()
        }
    }

    private func execute(_ request: RefreshRequest) async throws -> RefreshOutcome {
        guard timeout > 0 else { return try await operation(request) }
        return await withTaskGroup(of: RefreshOutcome.self) { group in
            group.addTask { [operation] in
                await RefreshCoordinator.run(operation: operation, request: request)
            }
            group.addTask { [timeoutOperation, timeout] in
                await timeoutOperation(timeout)
            }
            let result = await group.next() ?? .cancelled
            group.cancelAll()
            return result
        }
    }

    /// The observed Swift 6.3.3 crash report points at a generated async
    /// Double-to-Error thunk while a cancelled timeout child is unwinding.
    /// Keep both task-group children nonthrowing and keep the sleeper adapter
    /// alive as a stored operation, so cancellation does not cross that
    /// generated throwing boundary.
    private nonisolated static func run(operation: Operation, request: RefreshRequest) async -> RefreshOutcome {
        do { return try await operation(request) }
        catch is CancellationError { return .cancelled }
        catch { return .failed("refresh_failed") }
    }

    private func apply(_ outcome: RefreshOutcome, source: SourceRefreshOutcome, request: RefreshRequest, at now: Date) {
        let sourceCanAdvance = request.sourceIntent &&
            request.reason != .indexCommitted &&
            request.reason != .dayChanged &&
            (request.domains.contains(.quota) || request.domains.contains(.directory))
        let sourceWasAttempted = sourceOperation != nil && sourceCanAdvance
        if sourceWasAttempted {
            switch source {
            case .succeeded(let checkedAt) where checkedAt.timeIntervalSinceReferenceDate.isFinite && checkedAt <= now:
                lastSuccessfulAt = checkedAt
                sourceRetryAttemptValue = 0
                sourceRetryDateValue = nil
            case .succeeded:
                // A future/invalid source timestamp is not a successful
                // freshness check; apply a bounded retry instead of waking
                // immediately on every automatic request.
                scheduleSourceRetry(at: now)
            case .failed:
                scheduleSourceRetry(at: now)
            case .skipped:
                scheduleSourceRetry(at: now)
            case .cancelled:
                break
            }
        }

        switch outcome {
        case .failed, .timedOut:
            guard request.domains.contains(.quota) || request.domains.contains(.directory) || request.domains.contains(.homeRankings) else {
                syncCompatibilityFields()
                publishScheduleState(phase: .failed)
                return
            }
            if case .failed = source {
                // Source failures already own the retry lane; no projection
                // was attempted and must not create a second retry loop.
                syncCompatibilityFields()
                publishScheduleState(phase: .failed)
            } else if case .cancelled = source {
                syncCompatibilityFields()
                publishScheduleState(phase: .idle)
            } else {
                scheduleProjectionRetry(at: now)
                syncCompatibilityFields()
                publishScheduleState(phase: .failed)
            }
        case .completed, .noNewData:
            // A successful projection clears only its own retry lane. A
            // source retry remains pending until the source itself succeeds.
            projectionRetryAttemptValue = 0
            projectionRetryDateValue = nil
            syncCompatibilityFields()
            publishScheduleState(phase: nextWakeDate == nil ? .idle : .waiting)
        default:
            syncCompatibilityFields()
            publishScheduleState(phase: .idle)
        }
    }

    private func scheduleSourceRetry(at now: Date) {
        sourceRetryAttemptValue = min(sourceRetryAttemptValue + 1, 3)
        let delays: [TimeInterval] = [0, 5 * 60, 15 * 60, 30 * 60]
        sourceRetryDateValue = now.addingTimeInterval(delays[sourceRetryAttemptValue])
    }

    private func scheduleProjectionRetry(at now: Date) {
        projectionRetryAttemptValue = min(projectionRetryAttemptValue + 1, 3)
        let delays: [TimeInterval] = [0, 5 * 60, 15 * 60, 30 * 60]
        projectionRetryDateValue = now.addingTimeInterval(delays[projectionRetryAttemptValue])
    }

    private func merge(_ first: RefreshRequest?, _ second: RefreshRequest) -> RefreshRequest {
        guard let first else { return second }
        return RefreshRequest(
            domains: first.domains.union(second.domains),
            reason: strongerReason(first.reason, second.reason),
            force: first.force || second.force,
            allowsLongRunning: first.allowsLongRunning || second.allowsLongRunning,
            sourceIntent: first.sourceIntent || second.sourceIntent
        )
    }

    private func strongerReason(_ first: RefreshReason, _ second: RefreshReason) -> RefreshReason {
        func strength(_ reason: RefreshReason) -> Int {
            switch reason {
            case .manual: return 3
            case .startup, .automatic: return 2
            case .accountUsageAutomatic: return 1
            case .menuBar: return 2
            case .indexCommitted, .dayChanged: return 1
            }
        }
        return strength(second) >= strength(first) ? second : first
    }

    private func finish(_ waiters: inout [CheckedContinuation<RefreshOutcome, Never>], with outcome: RefreshOutcome) {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(returning: outcome) }
    }

    private func promoteNextBatchIfNeeded() {
        guard !isStopped, !isDraining, pendingRequest != nil else { return }
        activeWaiters.append(contentsOf: nextBatchWaiters)
        nextBatchWaiters.removeAll(keepingCapacity: false)
        startWorkerIfNeeded()
    }
}
