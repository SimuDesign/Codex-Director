import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class AccountUsageRefreshSchedulerTests: XCTestCase {
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var valueStorage: Date
        init(_ value: Date) { valueStorage = value }
        var value: Date {
            get { lock.lock(); defer { lock.unlock() }; return valueStorage }
            set { lock.lock(); valueStorage = newValue; lock.unlock() }
        }
    }

    @MainActor
    private final class FakeSystemState: AccountUsageSystemStateProviding {
        private var stateStorage: AccountUsageSystemState
        var currentState: AccountUsageSystemState {
            currentStateReadCount += 1
            return stateStorage
        }
        var startCount = 0
        var stopCount = 0
        private(set) var currentStateReadCount = 0
        private var handler: (@MainActor @Sendable (AccountUsageSystemState) -> Void)?

        init(_ state: AccountUsageSystemState = .init()) { stateStorage = state }

        func start(onChange: @escaping @MainActor @Sendable (AccountUsageSystemState) -> Void) {
            startCount += 1
            handler = onChange
        }

        func stop() {
            stopCount += 1
            handler = nil
        }

        func emit(_ state: AccountUsageSystemState) {
            stateStorage = state
            handler?(state)
        }
    }

    @MainActor
    private final class ManualWake: AccountUsageWakeScheduling {
        private(set) var scheduledDates: [Date] = []
        private var handler: (@MainActor @Sendable () -> Void)?
        private(set) var cancelCount = 0

        func schedule(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {
            scheduledDates.append(date)
            self.handler = handler
        }

        func cancel() {
            cancelCount += 1
            handler = nil
        }

        func fire() { let callback = handler; handler = nil; callback?() }
        var lastScheduledDate: Date? { scheduledDates.last }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var valueStorage = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return valueStorage }
        func increment() { lock.lock(); valueStorage += 1; lock.unlock() }
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testActiveSessionUsesFiveMinuteCadence() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 10))
        let wake = ManualWake()
        let reads = Counter()
        let snapshot = try usage(capturedAt: now)
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: snapshot,
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)

        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(reads.value, 0)
    }

    func testIdleSessionUsesThirtyMinuteCadenceAndReevaluatesOnStateSignal() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 30 * 60))
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(30 * 60))

        system.emit(.init(idleDuration: 5))
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(5 * 60))
    }

    func testRepeatedSystemSignalsKeepOneEquivalentWakeup() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 10))
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.scheduledDates.count, 1)

        // Sleep/wake and power notifications may be delivered repeatedly.
        // An unchanged state must not create an unbounded sequence of timer
        // replacements or wakeups.
        system.emit(.init(idleDuration: 10))
        system.emit(.init(idleDuration: 10))
        XCTAssertEqual(wake.scheduledDates.count, 1)
    }

    func testSimulatedTimeUsesOnlyOneWakeAndReadPerFiveMinuteDuePoint() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 10))
        let wake = ManualWake()
        let reads = Counter()
        var scheduler: AccountUsageRefreshScheduler!
        scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: {
                reads.increment()
                scheduler.updateSnapshot(try? CodexAccountUsageSnapshot(
                    weeklyRemainingPercent: 72,
                    weeklyResetsAt: clock.value.addingTimeInterval(86_400),
                    resetCreditCount: 0,
                    capturedAt: clock.value
                ))
                return .succeeded
            }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.scheduledDates.count, 1)
        for minute in [5, 10, 15] {
            clock.value = now.addingTimeInterval(TimeInterval(minute * 60))
            wake.fire()
            await Task.yield()
            XCTAssertEqual(reads.value, minute / 5)
            XCTAssertEqual(scheduler.scheduledRefreshCount, minute / 5)
            XCTAssertEqual(wake.scheduledDates.count, minute / 5 + 1)
        }

        // Repeated state signals at the same simulated time do not add a
        // second timer or process start.
        system.emit(.init(idleDuration: 10))
        system.emit(.init(idleDuration: 10))
        XCTAssertEqual(reads.value, 3)
        XCTAssertEqual(wake.scheduledDates.count, 4)
    }

    func testFailureBackoffIsFiveFifteenThirtyThenSuccessResets() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let results = LockedResults([AccountUsageRefreshScheduler.RefreshResult.failed, .failed, .failed, .succeeded])
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { results.next() }
        )

        scheduler.start(enabled: true)
        for expected in [5 * 60.0, 15 * 60.0, 30 * 60.0] {
            clock.value = wake.lastScheduledDate ?? now
            wake.fire()
            await Task.yield()
            XCTAssertEqual(scheduler.failureAttempt, expected == 5 * 60 ? 1 : expected == 15 * 60 ? 2 : 3)
            XCTAssertEqual(wake.lastScheduledDate, clock.value.addingTimeInterval(expected))
        }
        clock.value = wake.lastScheduledDate ?? now
        wake.fire()
        await Task.yield()
        XCTAssertEqual(scheduler.failureAttempt, 0)
    }

    func testMissingSnapshotFailureUsesFiveMinuteBackoff() async {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            refresh: { .failed }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(5))
        clock.value = now.addingTimeInterval(5)
        wake.fire()
        await Task.yield()

        XCTAssertEqual(scheduler.failureAttempt, 1)
        XCTAssertEqual(wake.lastScheduledDate, clock.value.addingTimeInterval(5 * 60))
    }

    func testLockedSleepingAndLowPowerPauseWithoutReadingThenResume() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now.addingTimeInterval(-5 * 60)),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        system.emit(.init(isUnlocked: false))
        XCTAssertTrue(scheduler.isPaused)
        XCTAssertNil(scheduler.nextDueDate)
        wake.fire()
        XCTAssertEqual(reads.value, 0)

        system.emit(.init(isAwake: false))
        XCTAssertTrue(scheduler.isPaused)
        system.emit(.init(isLowPowerMode: true))
        XCTAssertTrue(scheduler.isPaused)

        system.emit(.init(isAwake: true, isUnlocked: true, isLowPowerMode: false))
        XCTAssertFalse(scheduler.isPaused)
        XCTAssertNotNil(scheduler.nextDueDate)
    }

    func testEveryPauseSignalCancelsActiveAutomaticAndPreservesManualLocalWork() async throws {
        for pause in PauseSignalKind.allCases {
            try await exercisePauseSignal(pause)
        }
    }

    private func exercisePauseSignal(_ pause: PauseSignalKind) async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let accountEntered = PauseSignal()
        let accountCancelled = PauseSignal()
        let releaseAccount = PauseGate()
        let accountStarts = Counter()
        let localStarts = Counter()
        let requests = LockedRequests()
        let coordinator = RefreshCoordinator(
            timeout: 0,
            operation: { request in
                requests.append(request)
                if request.domains.contains(.accountUsage) {
                    accountStarts.increment()
                    if accountStarts.value == 1 {
                        await accountEntered.signal()
                        do {
                            await releaseAccount.wait()
                            try Task.checkCancellation()
                            return .completed
                        } catch is CancellationError {
                            await accountCancelled.signal()
                            throw CancellationError()
                        }
                    }
                } else {
                    localStarts.increment()
                }
                return .completed
            }
        )
        defer { Task { await releaseAccount.resumeAll() } }

        var scheduler: AccountUsageRefreshScheduler!
        scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value },
            systemState: system,
            wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: {
                let outcome = await coordinator.request(RefreshRequest(
                    domains: [.accountUsage],
                    reason: .accountUsageAutomatic,
                    force: true,
                    sourceIntent: false
                ))
                switch outcome {
                case .completed, .noNewData: return .succeeded
                case .cancelled: return .cancelled
                default: return .failed
                }
            },
            cancelScheduledRefresh: {
                coordinator.cancelScheduledAccountUsage()
            }
        )

        scheduler.start(enabled: true)
        clock.value = wake.lastScheduledDate ?? now
        wake.fire()
        let accountDidEnter = await waitFor(accountEntered)
        XCTAssertTrue(accountDidEnter)

        let manual = Task {
            await coordinator.request(RefreshRequest(
                domains: [.accountUsage, .quota, .directory],
                reason: .manual,
                force: true,
                sourceIntent: true
            ))
        }
        let manualWasAdmitted = await waitUntil {
            coordinator.isRunning && coordinator.pendingWaiterCount >= 2
        }
        XCTAssertTrue(manualWasAdmitted)

        switch pause {
        case .disabled:
            scheduler.setEnabled(false)
        case .locked:
            system.emit(.init(isUnlocked: false))
        case .lowPower:
            system.emit(.init(isLowPowerMode: true))
        case .sleeping:
            system.emit(.init(isAwake: false))
        }
        await releaseAccount.resumeAll()

        let cancellationWasObserved = await waitFor(accountCancelled)
        XCTAssertTrue(cancellationWasObserved)
        let manualResult = await manual.value
        XCTAssertEqual(manualResult, .completed)
        XCTAssertEqual(accountStarts.value, 1, "\(pause) started an account read while paused")
        XCTAssertEqual(localStarts.value, 1)
        XCTAssertEqual(requests.values.map(\.domains), [[.accountUsage], [.quota, .directory]])

        // Lock/sleep/power pause resumes on the next authoritative state
        // signal. Disable resumes only after the preference is turned back on.
        if pause == .disabled {
            scheduler.setEnabled(true)
        } else {
            system.emit(.init(isAwake: true, isUnlocked: true, isLowPowerMode: false))
        }
        clock.value = wake.lastScheduledDate ?? clock.value.addingTimeInterval(5 * 60)
        wake.fire()
        let resumed = await waitUntil { accountStarts.value == 2 }
        XCTAssertTrue(resumed)
        scheduler.stop()
    }

    func testDisabledSchedulerHasNoTimerOrSystemObserverAndReenableUsesGrace() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: false)
        XCTAssertEqual(system.startCount, 0)
        XCTAssertEqual(system.currentStateReadCount, 0)
        XCTAssertEqual(wake.scheduledDates.count, 0)
        XCTAssertEqual(reads.value, 0)

        scheduler.setEnabled(true)
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(5))
    }

    func testStartupGraceSchedulesMissingReadingWithoutImmediateAccountCall() async {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(5))
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
    }

    func testClockRollbackTreatsSnapshotAsDueAfterGraceNotAsFresh() throws {
        let clock = ClockBox(now.addingTimeInterval(-100))
        let system = FakeSystemState()
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.lastScheduledDate, clock.value.addingTimeInterval(5))
    }

    private func usage(capturedAt: Date) throws -> CodexAccountUsageSnapshot {
        try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: 72,
            weeklyResetsAt: now.addingTimeInterval(86_400),
            resetCreditCount: 0,
            capturedAt: capturedAt
        )
    }
}

private enum PauseSignalKind: CaseIterable, CustomStringConvertible {
    case disabled
    case locked
    case lowPower
    case sleeping

    var description: String {
        switch self {
        case .disabled: return "disabled"
        case .locked: return "locked"
        case .lowPower: return "low-power"
        case .sleeping: return "sleeping"
        }
    }
}

private actor PauseSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFired: Bool { fired }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation in
            if fired { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func signal() {
        fired = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PauseGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func resumeAll() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RefreshRequest] = []

    var values: [RefreshRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: RefreshRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private func waitFor(
    _ signal: PauseSignal,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await signal.isFired) {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@MainActor
private final class LockedResults {
    private var values: [AccountUsageRefreshScheduler.RefreshResult]
    init(_ values: [AccountUsageRefreshScheduler.RefreshResult]) { self.values = values }
    func next() -> AccountUsageRefreshScheduler.RefreshResult { values.isEmpty ? .succeeded : values.removeFirst() }
}
