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
public struct AccountUsageSystemState: Equatable, Sendable {
    public let isAwake: Bool
    public let isUnlocked: Bool
    public let isLowPowerMode: Bool
    public let idleDuration: TimeInterval

    public init(
        isAwake: Bool = true,
        isUnlocked: Bool = true,
        isLowPowerMode: Bool = false,
        idleDuration: TimeInterval = 0
    ) {
        self.isAwake = isAwake
        self.isUnlocked = isUnlocked
        self.isLowPowerMode = isLowPowerMode
        self.idleDuration = max(0, idleDuration.isFinite ? idleDuration : 0)
    }

    public var mayRefresh: Bool {
        isAwake && isUnlocked && !isLowPowerMode
    }

    public var cadence: TimeInterval {
        idleDuration >= 30 * 60 ? 30 * 60 : 5 * 60
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
    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let distributedCenter: DistributedNotificationCenter
    private let processInfo: ProcessInfo
    private let idleDurationReader: @MainActor @Sendable () -> TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var handler: (@MainActor @Sendable (AccountUsageSystemState) -> Void)?
    private var awake = true
    private var unlocked = true

    public init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter = .default,
        distributedCenter: DistributedNotificationCenter = .default(),
        processInfo: ProcessInfo = .processInfo,
        idleDurationReader: (@MainActor @Sendable () -> TimeInterval)? = nil
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.distributedCenter = distributedCenter
        self.processInfo = processInfo
        self.idleDurationReader = idleDurationReader ?? { MacAccountUsageSystemStateMonitor.readAggregateIdleDuration() }
    }

    public var currentState: AccountUsageSystemState {
        AccountUsageSystemState(
            isAwake: awake,
            isUnlocked: unlocked,
            isLowPowerMode: processInfo.isLowPowerModeEnabled,
            idleDuration: idleDurationReader()
        )
    }

    public func start(onChange: @escaping @MainActor @Sendable (AccountUsageSystemState) -> Void) {
        stop()
        handler = onChange
        awake = true
        unlocked = true

        let workspaceCenter = workspace.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(awake: false) }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(awake: true) }
        })
        observers.append(notificationCenter.addObserver(forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: processInfo, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        })
        observers.append(distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(unlocked: false) }
        })
        observers.append(distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update(unlocked: true) }
        })
        publish()
    }

    public func stop() {
        observers.forEach { observer in
            notificationCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
            workspace.notificationCenter.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
        handler = nil
    }

    private func update(awake: Bool? = nil, unlocked: Bool? = nil) {
        if let awake { self.awake = awake }
        if let unlocked { self.unlocked = unlocked }
        publish()
    }

    private func publish() { handler?(currentState) }

    private static func readAggregateIdleDuration() -> TimeInterval {
#if canImport(IOKit)
        let matching = IOServiceMatching("IOHIDSystem")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
        guard let value = property?.takeUnretainedValue() as? NSNumber else { return 0 }
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
    public private(set) var failureAttempt = 0
    public private(set) var scheduledRefreshCount = 0

    /// A final synchronous gate for the account reader. The coordinator uses
    /// this after any coalescing delay, immediately before it starts the
    /// app-server request, so a stale scheduled task cannot cross a lock,
    /// sleep, or Low Power Mode transition.
    public var isCurrentlyEligible: Bool {
        isStarted && isEnabled && systemState.currentState.mayRefresh
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
        let needsInitialRead = snapshot == nil || snapshotNeedsRefresh(at: clock(), cadence: currentState.cadence)
        reevaluate(after: needsInitialRead ? initialGrace : nil)
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
        failureAttempt = 0
        wakeScheduler.cancel()
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
        scheduleFromCurrentState(after: 0)
    }

    private func reevaluate(after delay: TimeInterval? = nil) {
        guard isStarted, isEnabled else { return }
        let state = systemState.currentState
        lastState = state
        guard state.mayRefresh else {
            isPaused = true
            nextDueDate = nil
            wakeScheduler.cancel()
            if isRefreshing { cancelScheduledRefresh() }
            return
        }
        isPaused = false
        scheduleFromCurrentState(after: delay)
    }

    private func scheduleFromCurrentState(after overrideDelay: TimeInterval? = nil) {
        guard isStarted, isEnabled, !isRefreshing else { return }
        let state = systemState.currentState
        lastState = state
        guard state.mayRefresh else {
            reevaluate()
            return
        }
        let now = clock()
        let due = dueDate(now: now, state: state)
        let scheduledDate = overrideDelay.map { now.addingTimeInterval(max(0, $0)) } ?? due
        // Repeated wake/lock/power notifications and cache publication can
        // produce the same due point. Keep one bounded wake-up instead of
        // replacing an equivalent timer on every signal.
        if overrideDelay == nil,
           let nextDueDate,
           abs(nextDueDate.timeIntervalSince(scheduledDate)) < 0.001 {
            return
        }
        nextDueDate = scheduledDate
        wakeScheduler.schedule(at: scheduledDate) { [weak self] in
            self?.fire()
        }
    }

    private func dueDate(now: Date, state: AccountUsageSystemState) -> Date {
        // Backoff is independent of whether the last transport response
        // contained a usable weekly window. A failed first read with no
        // cache must still back off at 5/15/30 minutes rather than spinning
        // at the startup grace interval.
        if failureAttempt > 0 {
            return now.addingTimeInterval(failureDelay(for: failureAttempt))
        }
        guard let snapshot else { return now.addingTimeInterval(initialGrace) }
        guard snapshot.capturedAt <= now,
              snapshot.weeklyRemainingPercent != nil,
              snapshot.weeklyResetsAt.map({ $0 > now }) ?? true else {
            return now.addingTimeInterval(initialGrace)
        }
        let candidate = snapshot.capturedAt.addingTimeInterval(state.cadence)
        return max(now, candidate)
    }

    private func snapshotNeedsRefresh(at now: Date, cadence: TimeInterval) -> Bool {
        guard let snapshot else { return true }
        guard snapshot.capturedAt <= now,
              snapshot.weeklyRemainingPercent != nil,
              snapshot.weeklyResetsAt.map({ $0 > now }) ?? true else { return true }
        return now.timeIntervalSince(snapshot.capturedAt) >= cadence
    }

    private func fire() {
        guard isStarted, isEnabled else { return }
        let state = systemState.currentState
        lastState = state
        guard state.mayRefresh else {
            reevaluate()
            return
        }
        let fireGeneration = generation
        isRefreshing = true
        nextDueDate = nil
        scheduledRefreshCount += 1
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.generation == fireGeneration,
                  self.isStarted,
                  self.isEnabled,
                  self.systemState.currentState.mayRefresh else {
                self.isRefreshing = false
                self.refreshTask = nil
                self.isPaused = true
                self.nextDueDate = nil
                self.wakeScheduler.cancel()
                self.cancelScheduledRefresh()
                return
            }
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
            failureAttempt = 0
            nextDueDate = nil
            scheduleFromCurrentState()
        case .failed, .unavailable:
            failureAttempt = min(failureAttempt + 1, 3)
            nextDueDate = nil
            scheduleFromCurrentState()
        case .cancelled:
            scheduleFromCurrentState()
        }
    }

    private func failureDelay(for attempt: Int) -> TimeInterval {
        switch min(max(attempt, 1), 3) {
        case 1: return 5 * 60
        case 2: return 15 * 60
        default: return 30 * 60
        }
    }
}
