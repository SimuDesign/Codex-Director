import Foundation
import AppKit
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

        func setWithoutSignal(_ state: AccountUsageSystemState) {
            stateStorage = state
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

    private final class BundleIdentifierBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?
        init(_ value: String?) { storage = value }
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    @MainActor
    private final class StateRecorder {
        private(set) var values: [AccountUsageSystemState] = []
        func append(_ value: AccountUsageSystemState) { values.append(value) }
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testPolicyRowsAndPriorityAreDeterministic() {
        XCTAssertNil(AccountUsageSystemState(isAwake: false).refreshPolicy(at: now))
        XCTAssertNil(AccountUsageSystemState(isUnlocked: false).refreshPolicy(at: now))
        XCTAssertNil(AccountUsageSystemState(isLowPowerMode: true).refreshPolicy(at: now))

        let idle = AccountUsageSystemState(
            idleDuration: 30 * 60,
            foregroundState: .codex
        ).refreshPolicy(at: now)
        XCTAssertEqual(idle, AccountUsageRefreshPolicy(interval: 30 * 60))

        let codex = AccountUsageSystemState(foregroundState: .codex).refreshPolicy(at: now)
        XCTAssertEqual(codex, AccountUsageRefreshPolicy(interval: 60))

        let departure = now.addingTimeInterval(-9 * 60)
        let grace = AccountUsageSystemState(
            foregroundState: .other,
            lastCodexDepartureAt: departure
        ).refreshPolicy(at: now)
        XCTAssertEqual(
            grace,
            AccountUsageRefreshPolicy(
                interval: 2 * 60,
                nextBoundary: departure.addingTimeInterval(10 * 60)
            )
        )

        let other = AccountUsageSystemState(foregroundState: .other).refreshPolicy(at: now)
        XCTAssertEqual(other, AccountUsageRefreshPolicy(interval: 5 * 60))

        let unknown = AccountUsageSystemState(foregroundState: .unknown).refreshPolicy(at: now)
        XCTAssertEqual(unknown, AccountUsageRefreshPolicy(interval: 2 * 60))
    }

    func testDepartureGraceEndsAtExactTenMinuteBoundary() {
        let departure = now.addingTimeInterval(-10 * 60)
        let policy = AccountUsageSystemState(
            foregroundState: .other,
            lastCodexDepartureAt: departure
        ).refreshPolicy(at: now)

        XCTAssertEqual(policy, AccountUsageRefreshPolicy(interval: 5 * 60))
    }

    func testFutureDepartureUsesUnknownFallbackAfterClockRollback() {
        let policy = AccountUsageSystemState(
            foregroundState: .other,
            lastCodexDepartureAt: now.addingTimeInterval(60)
        ).refreshPolicy(at: now)

        XCTAssertEqual(policy, AccountUsageRefreshPolicy(interval: 2 * 60))
    }

    func testInitialKnownOtherApplicationDoesNotInventDepartureGrace() {
        let state = AccountUsageSystemState(foregroundState: .other)
        XCTAssertNil(state.lastCodexDepartureAt)
        XCTAssertEqual(state.refreshPolicy(at: now), AccountUsageRefreshPolicy(interval: 5 * 60))
    }

    func testUnknownSessionUsesTwoMinuteCadence() throws {
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

        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(2 * 60))
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(reads.value, 0)
    }

    func testKnownCodexFrontmostUsesOneMinuteCadenceWithPopoverClosed() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .codex))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(60))
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(60))
        clock.value = now.addingTimeInterval(60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
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
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(60))

        system.emit(.init(idleDuration: 5))
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(2 * 60))
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(60))
    }

    func testIdleChecksDoNotReadAccountUntilThirtyMinutes() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 30 * 60))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { reads.increment(); return .succeeded }
        )
        scheduler.start(enabled: true)

        for minute in 1..<30 {
            clock.value = now.addingTimeInterval(TimeInterval(minute * 60))
            wake.fire()
            await Task.yield()
            XCTAssertEqual(reads.value, 0)
            XCTAssertEqual(scheduler.scheduledRefreshCount, 0)
            XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(30 * 60))
            XCTAssertEqual(wake.lastScheduledDate, clock.value.addingTimeInterval(60))
        }
        clock.value = now.addingTimeInterval(30 * 60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
        scheduler.stop()
    }

    func testResumingInputFromIdleDoesNotWaitForThirtyMinuteDeadline() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 30 * 60))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { reads.increment(); return .succeeded }
        )
        scheduler.start(enabled: true)
        system.setWithoutSignal(.init(idleDuration: 1, foregroundState: .codex))
        clock.value = now.addingTimeInterval(60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
        scheduler.stop()
    }

    func testIdleActivityCheckPreservesEarlierResetDeadline() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 30 * 60))
        let wake = ManualWake()
        let reads = Counter()
        let reset = now.addingTimeInterval(150)
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try CodexAccountUsageSnapshot(
                weeklyRemainingPercent: 72, weeklyResetsAt: reset,
                resetCreditCount: 0, capturedAt: now
            ),
            refresh: { reads.increment(); return .succeeded }
        )
        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, reset)
        clock.value = now.addingTimeInterval(120)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(wake.lastScheduledDate, reset)
        clock.value = reset
        XCTAssertTrue(scheduler.isCurrentlyEligible)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
        scheduler.stop()
    }

    func testExactEarliestWindowResetReadsEvenWhenLaterWindowRemainsUsableAndBackoffStaysStable() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .other))
        let wake = ManualWake()
        let reads = Counter()
        let earliestReset = now.addingTimeInterval(60)
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try CodexAccountUsageSnapshot(
                fiveHourRemainingPercent: 82,
                fiveHourResetsAt: earliestReset,
                weeklyRemainingPercent: 74,
                weeklyResetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetCreditCount: 2,
                capturedAt: now
            ),
            refresh: { reads.increment(); return .failed }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, earliestReset)
        clock.value = earliestReset
        XCTAssertTrue(scheduler.isCurrentlyEligible)
        wake.fire()
        await Task.yield()

        XCTAssertEqual(reads.value, 1)
        let retryDeadline = earliestReset.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.nextDueDate, retryDeadline)
        system.emit(.init(foregroundState: .codex))
        XCTAssertEqual(scheduler.nextDueDate, retryDeadline)
        XCTAssertEqual(scheduler.nextWakeDate, retryDeadline)
        scheduler.stop()
    }

    func testStartupGraceReadsExpiredEarlierWindowWhileKeepingLaterWindowUsable() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .other))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            initialGrace: 3,
            snapshot: try CodexAccountUsageSnapshot(
                fiveHourRemainingPercent: 82,
                fiveHourResetsAt: now.addingTimeInterval(-1),
                weeklyRemainingPercent: 74,
                weeklyResetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetCreditCount: 2,
                capturedAt: now.addingTimeInterval(-60)
            ),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(3))
        clock.value = now.addingTimeInterval(3)
        wake.fire()
        await Task.yield()

        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(scheduler.nextDueDate, clock.value.addingTimeInterval(5 * 60))
        scheduler.stop()
    }

    func testRepeatedAlreadyExpiredSnapshotsUseNormalCadenceWithoutImmediateLoop() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let reads = Counter()
        var scheduler: AccountUsageRefreshScheduler!
        scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            initialGrace: 3,
            snapshot: try CodexAccountUsageSnapshot(
                fiveHourRemainingPercent: 40,
                fiveHourResetsAt: now,
                weeklyRemainingPercent: nil,
                weeklyResetsAt: nil,
                resetCreditCount: 0,
                capturedAt: now.addingTimeInterval(-60)
            ),
            refresh: {
                reads.increment()
                scheduler.updateSnapshot(try? CodexAccountUsageSnapshot(
                    fiveHourRemainingPercent: 40,
                    fiveHourResetsAt: clock.value,
                    weeklyRemainingPercent: nil,
                    weeklyResetsAt: nil,
                    resetCreditCount: 0,
                    capturedAt: clock.value
                ))
                return .succeeded
            }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(3))
        clock.value = now.addingTimeInterval(3)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(scheduler.nextDueDate, clock.value.addingTimeInterval(2 * 60))

        clock.value = try XCTUnwrap(scheduler.nextWakeDate)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(scheduler.nextDueDate, clock.value.addingTimeInterval(2 * 60))
        scheduler.stop()
    }

    func testRepeatedUnknownSnapshotUsesFailureBackoffInsteadOfStartupGraceLoop() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState()
        let wake = ManualWake()
        let reads = Counter()
        var scheduler: AccountUsageRefreshScheduler!
        scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            initialGrace: 3,
            refresh: {
                reads.increment()
                scheduler.updateSnapshot(try? CodexAccountUsageSnapshot(
                    weeklyRemainingPercent: nil,
                    weeklyResetsAt: nil,
                    resetCreditCount: nil,
                    capturedAt: clock.value
                ))
                return .unavailable
            }
        )

        scheduler.start(enabled: true)
        clock.value = now.addingTimeInterval(3)
        wake.fire()
        await Task.yield()

        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(scheduler.failureAttempt, 1)
        XCTAssertEqual(scheduler.nextDueDate, clock.value.addingTimeInterval(5 * 60))
        XCTAssertEqual(scheduler.nextWakeDate, clock.value.addingTimeInterval(5 * 60))
        scheduler.stop()
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

    func testSimulatedTimeUsesOnlyOneWakeAndReadPerTwoMinuteDuePoint() async throws {
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
        for minute in [2, 4, 6] {
            clock.value = now.addingTimeInterval(TimeInterval(minute * 60))
            wake.fire()
            await Task.yield()
            XCTAssertEqual(reads.value, minute / 2)
            XCTAssertEqual(scheduler.scheduledRefreshCount, minute / 2)
            XCTAssertEqual(wake.scheduledDates.count, minute / 2 + 1)
        }

        // Repeated state signals at the same simulated time do not add a
        // second timer or process start.
        system.emit(.init(idleDuration: 10))
        system.emit(.init(idleDuration: 10))
        XCTAssertEqual(reads.value, 3)
        XCTAssertEqual(wake.scheduledDates.count, 4)
    }

    func testForegroundClassificationRequiresExactCodexBundleIdentifier() {
        XCTAssertEqual(
            MacAccountUsageSystemStateMonitor.classifyForeground(bundleIdentifier: "com.openai.codex"),
            .codex
        )
        XCTAssertEqual(
            MacAccountUsageSystemStateMonitor.classifyForeground(bundleIdentifier: "com.openai.chatgpt"),
            .other
        )
        XCTAssertEqual(
            MacAccountUsageSystemStateMonitor.classifyForeground(bundleIdentifier: "Codex"),
            .other
        )
        XCTAssertEqual(MacAccountUsageSystemStateMonitor.classifyForeground(bundleIdentifier: nil), .unknown)
        XCTAssertEqual(MacAccountUsageSystemStateMonitor.classifyForeground(bundleIdentifier: "  "), .unknown)
    }

    func testMonitorSeedsInitialForegroundAndTracksOnlyConfirmedCodexDeparture() async {
        let clock = ClockBox(now)
        let bundle = BundleIdentifierBox("com.openai.codex")
        let workspaceCenter = NotificationCenter()
        let recorder = StateRecorder()
        let monitor = makeMonitor(
            clock: clock,
            bundle: bundle,
            workspaceCenter: workspaceCenter
        )

        monitor.start { recorder.append($0) }
        XCTAssertEqual(monitor.currentState.foregroundState, .codex)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)

        clock.value = now.addingTimeInterval(20)
        postActivation("com.example.editor", to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.foregroundState, .other)
        XCTAssertEqual(monitor.currentState.lastCodexDepartureAt, clock.value)

        let firstDeparture = monitor.currentState.lastCodexDepartureAt
        clock.value = now.addingTimeInterval(40)
        postActivation("com.example.browser", to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.lastCodexDepartureAt, firstDeparture)

        postActivation("com.openai.codex", to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.foregroundState, .codex)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)
        XCTAssertGreaterThanOrEqual(recorder.values.count, 4)
        monitor.stop()
    }

    func testMonitorUnknownAndStartupOtherDoNotInventDeparture() async {
        let clock = ClockBox(now)
        let bundle = BundleIdentifierBox("com.example.editor")
        let workspaceCenter = NotificationCenter()
        let monitor = makeMonitor(clock: clock, bundle: bundle, workspaceCenter: workspaceCenter)

        monitor.start { _ in }
        XCTAssertEqual(monitor.currentState.foregroundState, .other)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)

        postActivation(nil, to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.foregroundState, .unknown)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)

        postActivation("com.example.browser", to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.foregroundState, .other)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)
        monitor.stop()
    }

    func testMonitorStopClearsStateAndRejectsDelayedEarlierGeneration() async {
        let clock = ClockBox(now)
        let bundle = BundleIdentifierBox("com.openai.codex")
        let workspaceCenter = NotificationCenter()
        let firstRecorder = StateRecorder()
        let monitor = makeMonitor(clock: clock, bundle: bundle, workspaceCenter: workspaceCenter)

        monitor.start { firstRecorder.append($0) }
        postActivation("com.example.delayed", to: workspaceCenter)
        monitor.stop()
        XCTAssertEqual(monitor.currentState.foregroundState, .unknown)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)

        bundle.value = "com.openai.codex"
        let secondRecorder = StateRecorder()
        monitor.start { secondRecorder.append($0) }
        await drainMainActor()
        XCTAssertEqual(monitor.currentState.foregroundState, .codex)
        XCTAssertNil(monitor.currentState.lastCodexDepartureAt)

        monitor.stop()
        let recordedCount = secondRecorder.values.count
        postActivation("com.example.after-stop", to: workspaceCenter)
        await drainMainActor()
        XCTAssertEqual(secondRecorder.values.count, recordedCount)
        XCTAssertEqual(monitor.currentState.foregroundState, .unknown)
    }

    func testFasterForegroundTransitionBringsOnlyStaleDeadlineForward() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .other))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(5 * 60))
        clock.value = now.addingTimeInterval(30)
        system.emit(.init(foregroundState: .codex))
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(60))
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(60))
        XCTAssertEqual(reads.value, 0)

        clock.value = now.addingTimeInterval(60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 1)
    }

    func testSlowerForegroundTransitionLetsOldWakeRecheckWithoutEarlyRead() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .codex))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(wake.lastScheduledDate, now.addingTimeInterval(60))
        clock.value = now.addingTimeInterval(30)
        system.emit(.init(foregroundState: .other))
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(scheduler.nextWakeDate, now.addingTimeInterval(60))

        clock.value = now.addingTimeInterval(60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(scheduler.nextWakeDate, now.addingTimeInterval(5 * 60))
    }

    func testSlowerTransitionDuringCoordinatorDelayFailsFinalEligibility() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .codex))
        let wake = ManualWake()
        let enteredCoordinator = PauseSignal()
        let releaseCoordinator = PauseGate()
        let reads = Counter()
        var scheduler: AccountUsageRefreshScheduler!
        scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: {
                await enteredCoordinator.signal()
                await releaseCoordinator.wait()
                guard scheduler.isCurrentlyEligible else { return .cancelled }
                reads.increment()
                return .succeeded
            }
        )

        scheduler.start(enabled: true)
        clock.value = now.addingTimeInterval(60)
        wake.fire()
        let coordinatorEntered = await waitFor(enteredCoordinator)
        XCTAssertTrue(coordinatorEntered)

        system.emit(.init(foregroundState: .other))
        XCTAssertFalse(scheduler.isCurrentlyEligible)
        await releaseCoordinator.resumeAll()
        let rescheduled = await waitUntil { scheduler.nextDueDate != nil }
        XCTAssertTrue(rescheduled)

        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(scheduler.nextWakeDate, now.addingTimeInterval(5 * 60))
    }

    func testGraceExpiryWakeChangesPolicyWithoutForcingRead() async throws {
        let clock = ClockBox(now.addingTimeInterval(9 * 60))
        let system = FakeSystemState(.init(
            foregroundState: .other,
            lastCodexDepartureAt: now
        ))
        let wake = ManualWake()
        let reads = Counter()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now.addingTimeInterval(8 * 60)),
            refresh: { reads.increment(); return .succeeded }
        )

        scheduler.start(enabled: true)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(10 * 60))
        XCTAssertEqual(scheduler.nextWakeDate, now.addingTimeInterval(10 * 60))
        clock.value = now.addingTimeInterval(10 * 60)
        wake.fire()
        await Task.yield()
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(scheduler.nextDueDate, now.addingTimeInterval(13 * 60))
    }

    func testFailureDeadlineSurvivesActivationAndSnapshotSignals() async throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(foregroundState: .codex))
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now.addingTimeInterval(-60)),
            refresh: { .failed }
        )

        scheduler.start(enabled: true)
        clock.value = now.addingTimeInterval(5)
        wake.fire()
        await Task.yield()
        let retryDeadline = clock.value.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.nextDueDate, retryDeadline)
        XCTAssertEqual(scheduler.nextWakeDate, retryDeadline)
        XCTAssertEqual(wake.scheduledDates.count, 2)

        clock.value = now.addingTimeInterval(35)
        system.emit(.init(foregroundState: .other))
        system.emit(.init(foregroundState: .codex))
        system.emit(.init(idleDuration: 31 * 60, foregroundState: .codex))
        scheduler.updateSnapshot(try usage(capturedAt: now.addingTimeInterval(-60)))

        XCTAssertEqual(scheduler.failureAttempt, 1)
        XCTAssertEqual(scheduler.nextDueDate, retryDeadline)
        XCTAssertEqual(scheduler.nextWakeDate, retryDeadline)
        XCTAssertEqual(wake.scheduledDates.count, 2)
    }

    func testFrequentSignalsDoNotPostponeExistingIdleActivityWake() throws {
        let clock = ClockBox(now)
        let system = FakeSystemState(.init(idleDuration: 31 * 60, foregroundState: .other))
        let wake = ManualWake()
        let scheduler = AccountUsageRefreshScheduler(
            clock: { clock.value }, systemState: system, wakeScheduler: wake,
            snapshot: try usage(capturedAt: now),
            refresh: { .succeeded }
        )

        scheduler.start(enabled: true)
        let firstWake = now.addingTimeInterval(60)
        XCTAssertEqual(scheduler.nextWakeDate, firstWake)
        clock.value = now.addingTimeInterval(30)
        system.emit(.init(idleDuration: 31 * 60, foregroundState: .codex))
        scheduler.updateSnapshot(try usage(capturedAt: clock.value))
        XCTAssertEqual(scheduler.nextWakeDate, firstWake)
        XCTAssertEqual(wake.scheduledDates.count, 1)
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
        clock.value = now.addingTimeInterval(5)
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

    private func makeMonitor(
        clock: ClockBox,
        bundle: BundleIdentifierBox,
        workspaceCenter: NotificationCenter
    ) -> MacAccountUsageSystemStateMonitor {
        MacAccountUsageSystemStateMonitor(
            workspaceNotificationCenter: workspaceCenter,
            notificationCenter: NotificationCenter(),
            clock: { clock.value },
            idleDurationReader: { 0 },
            frontmostBundleIdentifierReader: { bundle.value },
            activatedBundleIdentifierReader: { notification in
                notification.userInfo?["bundle"] as? String
            }
        )
    }

    private func postActivation(_ bundleIdentifier: String?, to center: NotificationCenter) {
        let userInfo: [AnyHashable: Any]? = bundleIdentifier.map { ["bundle": $0] }
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    private func drainMainActor() async {
        await Task.yield()
        await Task.yield()
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
