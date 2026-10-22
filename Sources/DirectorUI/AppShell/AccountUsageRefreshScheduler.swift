import Foundation
import SwiftUI
import AppKit
import DirectorCore
#if canImport(IOKit)
import IOKit
#endif

/// The small set of OS state needed to decide whether a passive account
/// allowance read is appropriate.  It intentionally contains no input
/// events, window contents, or user activity details.
public enum AccountUsageForegroundState: Equatable, Sendable {
    case codex
    case other
    case unknown
}

public struct AccountUsageRefreshPolicy: Equatable, Sendable {
    public let interval: TimeInterval
    public let nextBoundary: Date?

    public init(interval: TimeInterval, nextBoundary: Date? = nil) {
        self.interval = interval
        self.nextBoundary = nextBoundary
    }
}

public struct AccountUsageSystemState: Equatable, Sendable {
    static let codexRefreshInterval: TimeInterval = 60
    static let departureRefreshInterval: TimeInterval = 2 * 60
    static let otherApplicationRefreshInterval: TimeInterval = 5 * 60
    static let unknownRefreshInterval: TimeInterval = 2 * 60
    static let idleRefreshInterval: TimeInterval = 30 * 60
    static let idleThreshold: TimeInterval = 30 * 60
    static let departureGrace: TimeInterval = 10 * 60
    static let activityCheckInterval: TimeInterval = 60
    static let popoverFreshnessInterval: TimeInterval = 2 * 60

    public let isAwake: Bool
    public let isUnlocked: Bool
    public let isLowPowerMode: Bool
    public let idleDuration: TimeInterval
    public let foregroundState: AccountUsageForegroundState
    public let lastCodexDepartureAt: Date?

    public init(
        isAwake: Bool = true,
        isUnlocked: Bool = true,
        isLowPowerMode: Bool = false,
        idleDuration: TimeInterval = 0,
        foregroundState: AccountUsageForegroundState = .unknown,
        lastCodexDepartureAt: Date? = nil
    ) {
        self.isAwake = isAwake
        self.isUnlocked = isUnlocked
        self.isLowPowerMode = isLowPowerMode
        self.idleDuration = max(0, idleDuration.isFinite ? idleDuration : 0)
        self.foregroundState = foregroundState
        self.lastCodexDepartureAt = lastCodexDepartureAt
    }

    public var mayRefresh: Bool {
        isAwake && isUnlocked && !isLowPowerMode
    }

    public func refreshPolicy(at now: Date) -> AccountUsageRefreshPolicy? {
        guard mayRefresh else { return nil }
        if idleDuration >= Self.idleThreshold {
            return AccountUsageRefreshPolicy(interval: Self.idleRefreshInterval)
        }
        switch foregroundState {
        case .codex:
            return AccountUsageRefreshPolicy(interval: Self.codexRefreshInterval)
        case .unknown:
            return AccountUsageRefreshPolicy(interval: Self.unknownRefreshInterval)
        case .other:
            guard let departure = lastCodexDepartureAt else {
                return AccountUsageRefreshPolicy(interval: Self.otherApplicationRefreshInterval)
            }
            // A future departure is evidence of wall-clock rollback, not a
            // reason to extend grace indefinitely. Use the conservative
            // unknown cadence until the monitor discards that invalid state.
            guard departure <= now else {
                return AccountUsageRefreshPolicy(interval: Self.unknownRefreshInterval)
            }
            let boundary = departure.addingTimeInterval(Self.departureGrace)
            guard now < boundary else {
                return AccountUsageRefreshPolicy(interval: Self.otherApplicationRefreshInterval)
            }
            return AccountUsageRefreshPolicy(
                interval: Self.departureRefreshInterval,
                nextBoundary: boundary
            )
        }
    }
}

@MainActor
public protocol AccountUsageSystemStateProviding: AnyObject {
    var currentState: AccountUsageSystemState { get }
    func start(onChange: @escaping @MainActor @Sendable (AccountUsageSystemState) -> Void)
    func stop()
}

@MainActor
public protocol AccountUsageWakeScheduling: AnyObject {
    func schedule(at date: Date, handler: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

/// Production wake-up implementation. It schedules one bounded one-shot
/// task, never a per-second countdown or a repeating polling timer.
@MainActor
public final class TaskAccountUsageWakeScheduler: AccountUsageWakeScheduling {
    private let clock: @Sendable () -> Date
    private var task: Task<Void, Never>?

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public func schedule(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let delay = max(0, date.timeIntervalSince(clock()))
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            handler()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Reads only aggregate HID idle duration. No event type, contents, or
/// timestamps are persisted or logged. A failure conservatively reports an
/// active session so the schedule remains bounded and useful.
@MainActor
public final class MacAccountUsageSystemStateMonitor: AccountUsageSystemStateProviding {
    public static let codexBundleIdentifier = "com.openai.codex"

    private let workspaceCenter: NotificationCenter
    private let notificationCenter: NotificationCenter
    private let distributedCenter: DistributedNotificationCenter
    private let processInfo: ProcessInfo
    private let clock: @MainActor @Sendable () -> Date
    private let idleDurationReader: @MainActor @Sendable () -> TimeInterval
    private let frontmostBundleIdentifierReader: @MainActor @Sendable () -> String?
    private let activatedBundleIdentifierReader: @Sendable (Notification) -> String?
    private var observers: [NSObjectProtocol] = []
    private var handler: (@MainActor @Sendable (AccountUsageSystemState) -> Void)?
    private var awake = true
    private var unlocked = true
    private var foregroundState: AccountUsageForegroundState = .unknown
    private var lastCodexDepartureAt: Date?
    private var monitorGeneration: UInt64 = 0
    private var isMonitoring = false

    public init(
        workspace: NSWorkspace = .shared,
        workspaceNotificationCenter: NotificationCenter? = nil,
        notificationCenter: NotificationCenter = .default,
        distributedCenter: DistributedNotificationCenter = .default(),
        processInfo: ProcessInfo = .processInfo,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init,
        idleDurationReader: (@MainActor @Sendable () -> TimeInterval)? = nil,
        frontmostBundleIdentifierReader: (@MainActor @Sendable () -> String?)? = nil,
        activatedBundleIdentifierReader: (@Sendable (Notification) -> String?)? = nil
    ) {
        self.workspaceCenter = workspaceNotificationCenter ?? workspace.notificationCenter
        self.notificationCenter = notificationCenter
        self.distributedCenter = distributedCenter
        self.processInfo = processInfo
        self.clock = clock
        self.idleDurationReader = idleDurationReader ?? { MacAccountUsageSystemStateMonitor.readAggregateIdleDuration() }
        self.frontmostBundleIdentifierReader = frontmostBundleIdentifierReader ?? {
            workspace.frontmostApplication?.bundleIdentifier
        }
        self.activatedBundleIdentifierReader = activatedBundleIdentifierReader ?? { notification in
            (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        }
    }

    public var currentState: AccountUsageSystemState {
        discardRolledBackDeparture(at: clock())
        return AccountUsageSystemState(
            isAwake: awake,
            isUnlocked: unlocked,
            isLowPowerMode: processInfo.isLowPowerModeEnabled,
            idleDuration: idleDurationReader(),
            foregroundState: foregroundState,
            lastCodexDepartureAt: lastCodexDepartureAt
        )
    }

    public func start(onChange: @escaping @MainActor @Sendable (AccountUsageSystemState) -> Void) {
        stop()
        handler = onChange
        awake = true
        unlocked = true
        foregroundState = .unknown
        lastCodexDepartureAt = nil
        isMonitoring = true
        let generation = monitorGeneration
        let readActivatedBundleIdentifier = activatedBundleIdentifierReader

        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(awake: false, generation: generation) }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(awake: true, generation: generation) }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundleIdentifier = readActivatedBundleIdentifier(notification)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateForeground(
                    bundleIdentifier: bundleIdentifier,
                    at: self.clock(),
                    generation: generation
                )
            }
        })
        observers.append(notificationCenter.addObserver(forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: processInfo, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish(generation: generation) }
        })
        observers.append(distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(unlocked: false, generation: generation) }
        })
        observers.append(distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(unlocked: true, generation: generation) }
        })
        updateForeground(
            bundleIdentifier: frontmostBundleIdentifierReader(),
            at: clock(),
            generation: generation,
            publishChange: false
        )
        publish(generation: generation)
    }

    public func stop() {
        monitorGeneration &+= 1
        isMonitoring = false
        observers.forEach { observer in
            notificationCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
        handler = nil
        foregroundState = .unknown
        lastCodexDepartureAt = nil
    }

    private func update(awake: Bool? = nil, unlocked: Bool? = nil, generation: UInt64) {
        guard isCurrent(generation) else { return }
        if let awake { self.awake = awake }
        if let unlocked { self.unlocked = unlocked }
        publish(generation: generation)
    }

    private func updateForeground(
        bundleIdentifier: String?,
        at now: Date,
        generation: UInt64,
        publishChange: Bool = true
    ) {
        guard isCurrent(generation) else { return }
        discardRolledBackDeparture(at: now)
        let next = Self.classifyForeground(bundleIdentifier: bundleIdentifier)
        if foregroundState == .codex, next == .other {
            lastCodexDepartureAt = now
        } else if next == .codex {
            lastCodexDepartureAt = nil
        }
        foregroundState = next
        if publishChange { publish(generation: generation) }
    }

    private func publish(generation: UInt64) {
        guard isCurrent(generation) else { return }
        handler?(currentState)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        isMonitoring && generation == monitorGeneration
    }

    private func discardRolledBackDeparture(at now: Date) {
        guard let lastCodexDepartureAt, lastCodexDepartureAt > now else { return }
        self.lastCodexDepartureAt = nil
        foregroundState = .unknown
    }

    static func classifyForeground(bundleIdentifier: String?) -> AccountUsageForegroundState {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        return bundleIdentifier == codexBundleIdentifier ? .codex : .other
    }

    private static func readAggregateIdleDuration() -> TimeInterval {
#if canImport(IOKit)
        let matching = IOServiceMatching("IOHIDSystem")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
        guard let property else { return 0 }
        let value = property.takeRetainedValue()
        guard let value = value as? NSNumber else { return 0 }
        return max(0, value.doubleValue / 1_000_000_000)
#else
        return 0
#endif
    }

}

/// Application-scoped adaptive scheduler for account usage. Capability and
/// source refreshes remain owned by `RefreshCoordinator`; this object only
/// decides when to submit the account-only domain to that coordinator.
@MainActor
public final class AccountUsageRefreshScheduler: ObservableObject {
    public enum RefreshResult: Equatable, Sendable {
        case succeeded
        case failed
        case cancelled
        case unavailable
    }

    public typealias Clock = @Sendable () -> Date
    public typealias Refresh = @MainActor @Sendable () async -> RefreshResult
    public typealias CancelScheduledRefresh = @MainActor @Sendable () -> Void

    public let initialGrace: TimeInterval
    public private(set) var isEnabled = false
    public private(set) var isPaused = false
    public private(set) var nextDueDate: Date?
    public private(set) var nextWakeDate: Date?
    public private(set) var failureAttempt = 0
    public private(set) var scheduledRefreshCount = 0

    /// A final synchronous gate for the account reader. The coordinator uses
    /// this after any coalescing delay, immediately before it starts the
    /// app-server request, so a stale scheduled task cannot cross a lock,
    /// sleep, Low Power Mode, or slower foreground-policy transition.
    public var isCurrentlyEligible: Bool {
        guard isStarted, isEnabled else { return false }
        let now = clock()
        guard let policy = systemState.currentState.refreshPolicy(at: now) else { return false }
        return automaticReadIsDue(now: now, policy: policy)
    }

    private let clock: Clock
    private let systemState: AccountUsageSystemStateProviding
    private let wakeScheduler: AccountUsageWakeScheduling
    private let refresh: Refresh
    private let cancelScheduledRefresh: CancelScheduledRefresh
    private var snapshot: CodexAccountUsageSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isStarted = false
    private var isRefreshing = false
    private var lastState = AccountUsageSystemState()
    private var pendingAccountDeadline: Date?
    private var failureRetryDeadline: Date?
    private var lastCompletedReadAt: Date?
    private var wakeGeneration: UInt64 = 0

    public init(
        clock: @escaping Clock = Date.init,
        systemState: AccountUsageSystemStateProviding,
        wakeScheduler: AccountUsageWakeScheduling,
        initialGrace: TimeInterval = 5,
        snapshot: CodexAccountUsageSnapshot? = nil,
        refresh: @escaping Refresh,
        cancelScheduledRefresh: @escaping CancelScheduledRefresh = {}
    ) {
        self.clock = clock
        self.systemState = systemState
        self.wakeScheduler = wakeScheduler
        self.initialGrace = max(0, initialGrace)
        self.snapshot = snapshot
        self.refresh = refresh
        self.cancelScheduledRefresh = cancelScheduledRefresh
        // Do not read aggregate activity or power state until the menu-bar
        // preference explicitly enables and starts the scheduler.
        self.lastState = AccountUsageSystemState()
    }

    public func updateSnapshot(_ snapshot: CodexAccountUsageSnapshot?) {
        self.snapshot = snapshot
        guard isStarted, isEnabled, !isRefreshing else { return }
        let now = clock()
        if let policy = systemState.currentState.refreshPolicy(at: now),
           snapshotNeedsRefresh(at: now, cadence: policy.interval),
           failureRetryDeadline == nil,
           pendingAccountDeadline == nil {
            pendingAccountDeadline = now.addingTimeInterval(initialGrace)
        }
        scheduleFromCurrentState()
    }

    public func start(enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            stop()
            return
        }
        guard !isStarted else {
            reevaluate()
            return
        }
        isStarted = true
        systemState.start { [weak self] _ in
            self?.reevaluate()
        }
        let currentState = systemState.currentState
        lastState = currentState
        let now = clock()
        if let policy = currentState.refreshPolicy(at: now),
           snapshotNeedsRefresh(at: now, cadence: policy.interval) {
            pendingAccountDeadline = now.addingTimeInterval(initialGrace)
        }
        reevaluate()
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled { start(enabled: true) }
        else { stop() }
    }

    public func stop() {
        generation &+= 1
        isEnabled = false
        isStarted = false
        isPaused = false
        nextDueDate = nil
        nextWakeDate = nil
        failureAttempt = 0
        pendingAccountDeadline = nil
        failureRetryDeadline = nil
        lastCompletedReadAt = nil
        cancelWake()
        systemState.stop()
        refreshTask?.cancel()
        refreshTask = nil
        if isRefreshing { cancelScheduledRefresh() }
        isRefreshing = false
    }

    /// Called after a user-initiated menu/popover/full refresh. It keeps the
    /// passive schedule anchored to the newest result without starting a
    /// second account request.
    public func recordExternalResult(_ result: RefreshResult) {
        guard isStarted, isEnabled else { return }
        guard !isRefreshing else { return }
        handle(result, generation: generation)
    }

    /// Forces a one-shot account read when the popover reports a missing or
    /// stale value. The shared refresh coordinator still coalesces this with
    /// any automatic or full request already in flight.
    public func requestImmediately() {
        guard isStarted, isEnabled, !isRefreshing, lastState.mayRefresh else { return }
        pendingAccountDeadline = clock()
        scheduleFromCurrentState()
    }

    private func reevaluate() {
        guard isStarted, isEnabled else { return }
        let state = systemState.currentState
        lastState = state
        guard state.mayRefresh else {
            isPaused = true
            nextDueDate = nil
            nextWakeDate = nil
            cancelWake()
            if isRefreshing { cancelScheduledRefresh() }
            return
        }
        isPaused = false
        scheduleFromCurrentState()
    }

    private func scheduleFromCurrentState() {
        guard isStarted, isEnabled, !isRefreshing else { return }
        let state = systemState.currentState
        lastState = state
        let now = clock()
        guard let policy = state.refreshPolicy(at: now) else {
            reevaluate()
            return
        }
        let accountDeadline = accountDeadline(now: now, policy: policy)
        var proposedWake = accountDeadline
        if failureRetryDeadline == nil {
            if state.idleDuration >= AccountUsageSystemState.idleThreshold {
                proposedWake = min(
                    proposedWake,
                    now.addingTimeInterval(AccountUsageSystemState.activityCheckInterval)
                )
            }
            if let boundary = policy.nextBoundary, boundary > now {
                proposedWake = min(proposedWake, boundary)
            }
        }
        // A frequent activation, power or cache signal must not postpone an
        // already scheduled local policy/activity check. Earlier wakes remain
        // safe because `fire` recalculates policy before any account request.
        let wakeDate: Date
        if let existingWake = nextWakeDate, existingWake > now {
            wakeDate = min(existingWake, proposedWake)
        } else {
            wakeDate = proposedWake
        }
        nextDueDate = accountDeadline
        if let nextWakeDate,
           abs(nextWakeDate.timeIntervalSince(wakeDate)) < 0.001 {
            return
        }
        nextWakeDate = wakeDate
        wakeGeneration &+= 1
        let scheduledGeneration = wakeGeneration
        wakeScheduler.schedule(at: wakeDate) { [weak self] in
            self?.fire(generation: scheduledGeneration)
        }
    }

    private func accountDeadline(now: Date, policy: AccountUsageRefreshPolicy) -> Date {
        // Backoff is independent of whether the last transport response
        // contained a usable weekly window. A failed first read with no
        // cache must still back off at 5/15/30 minutes rather than spinning
        // at the startup grace interval.
        if let failureRetryDeadline {
            return failureRetryDeadline
        }
        if let pendingAccountDeadline {
            return pendingAccountDeadline
        }
        guard let snapshot else {
            let deadline = now.addingTimeInterval(initialGrace)
            pendingAccountDeadline = deadline
            return deadline
        }
        guard snapshot.capturedAt <= now,
              snapshot.hasUsableAllowance else {
            if let nextDueDate {
                pendingAccountDeadline = nextDueDate
                return nextDueDate
            }
            let deadline = now.addingTimeInterval(initialGrace)
            pendingAccountDeadline = deadline
            return deadline
        }
        let anchor = refreshAnchor(for: snapshot, at: now)
        let cadenceDate = anchor.addingTimeInterval(policy.interval)
        let resetDate = nextObservedResetDate(in: snapshot, after: anchor)
        return max(now, min(cadenceDate, resetDate ?? cadenceDate))
    }

    private func snapshotNeedsRefresh(at now: Date, cadence: TimeInterval) -> Bool {
        guard let snapshot else { return true }
        guard snapshot.capturedAt <= now,
              snapshot.hasUsableAllowance else { return true }
        let anchor = refreshAnchor(for: snapshot, at: now)
        let cadenceDate = anchor.addingTimeInterval(cadence)
        let resetDate = nextObservedResetDate(in: snapshot, after: anchor)
        return min(cadenceDate, resetDate ?? cadenceDate) <= now
    }

    private func fire(generation scheduledGeneration: UInt64) {
        guard isStarted, isEnabled, scheduledGeneration == wakeGeneration else { return }
        nextWakeDate = nil
        let state = systemState.currentState
        lastState = state
        let now = clock()
        guard let policy = state.refreshPolicy(at: now) else {
            reevaluate()
            return
        }
        let deadline = accountDeadline(now: now, policy: policy)
        nextDueDate = deadline
        guard deadline <= now else {
            scheduleFromCurrentState()
            return
        }
        let fireGeneration = generation
        isRefreshing = true
        nextDueDate = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.generation == fireGeneration, self.isStarted, self.isEnabled else { return }
            let finalState = self.systemState.currentState
            let finalNow = self.clock()
            guard let finalPolicy = finalState.refreshPolicy(at: finalNow) else {
                self.isRefreshing = false
                self.refreshTask = nil
                self.isPaused = true
                self.nextDueDate = nil
                self.nextWakeDate = nil
                self.wakeScheduler.cancel()
                self.cancelScheduledRefresh()
                return
            }
            let finalDeadline = self.accountDeadline(now: finalNow, policy: finalPolicy)
            guard finalDeadline <= finalNow else {
                self.isRefreshing = false
                self.refreshTask = nil
                self.nextDueDate = finalDeadline
                self.scheduleFromCurrentState()
                return
            }
            self.pendingAccountDeadline = nil
            self.scheduledRefreshCount += 1
            let result = await self.refresh()
            guard self.generation == fireGeneration, self.isStarted, self.isEnabled else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.handle(result, generation: fireGeneration)
        }
    }

    private func handle(_ result: RefreshResult, generation: UInt64) {
        guard self.generation == generation, isStarted, isEnabled else { return }
        switch result {
        case .succeeded:
            lastCompletedReadAt = clock()
            failureAttempt = 0
            failureRetryDeadline = nil
            pendingAccountDeadline = nil
            nextDueDate = nil
            scheduleFromCurrentState()
        case .failed, .unavailable:
            lastCompletedReadAt = clock()
            failureAttempt = min(failureAttempt + 1, 3)
            pendingAccountDeadline = nil
            failureRetryDeadline = clock().addingTimeInterval(failureDelay(for: failureAttempt))
            nextDueDate = nil
            scheduleFromCurrentState()
        case .cancelled:
            if failureRetryDeadline == nil {
                pendingAccountDeadline = nil
                let now = clock()
                if let policy = systemState.currentState.refreshPolicy(at: now),
                   normalAccountReadIsDue(now: now, policy: policy) {
                    pendingAccountDeadline = now.addingTimeInterval(initialGrace)
                }
            }
            scheduleFromCurrentState()
        }
    }

    private func automaticReadIsDue(now: Date, policy: AccountUsageRefreshPolicy) -> Bool {
        if let failureRetryDeadline { return failureRetryDeadline <= now }
        if let pendingAccountDeadline { return pendingAccountDeadline <= now }
        return normalAccountReadIsDue(now: now, policy: policy)
    }

    private func normalAccountReadIsDue(now: Date, policy: AccountUsageRefreshPolicy) -> Bool {
        guard let snapshot,
              snapshot.capturedAt <= now,
              snapshot.hasUsableAllowance else { return true }
        let anchor = refreshAnchor(for: snapshot, at: now)
        let cadenceDate = anchor.addingTimeInterval(policy.interval)
        let resetDate = nextObservedResetDate(in: snapshot, after: anchor)
        return min(cadenceDate, resetDate ?? cadenceDate) <= now
    }

    private func refreshAnchor(for snapshot: CodexAccountUsageSnapshot, at now: Date) -> Date {
        guard let lastCompletedReadAt, lastCompletedReadAt <= now else {
            return snapshot.capturedAt
        }
        return max(snapshot.capturedAt, lastCompletedReadAt)
    }

    /// A reset is a reason to read when it represents a state transition
    /// observed after the newest snapshot/read anchor. A backend may itself
    /// return an already-expired window; treating that historical reset as a
    /// new transition would create an immediate retry loop.
    private func nextObservedResetDate(
        in snapshot: CodexAccountUsageSnapshot,
        after anchor: Date
    ) -> Date? {
        [
            (snapshot.fiveHourRemainingPercent, snapshot.fiveHourResetsAt),
            (snapshot.weeklyRemainingPercent, snapshot.weeklyResetsAt)
        ].compactMap { remaining, reset -> Date? in
            guard remaining != nil, let reset, reset > anchor else { return nil }
            return reset
        }.min()
    }

    private func cancelWake() {
        wakeGeneration &+= 1
        wakeScheduler.cancel()
    }

    private func failureDelay(for attempt: Int) -> TimeInterval {
        switch min(max(attempt, 1), 3) {
        case 1: return 5 * 60
        case 2: return 15 * 60
        default: return 30 * 60
        }
    }
}
