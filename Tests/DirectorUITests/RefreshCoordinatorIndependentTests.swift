import Foundation
import XCTest
@testable import DirectorUI

/// Independent scheduler contracts. These tests use only in-memory gates and
/// clocks; they do not exercise source files, SQLite, or production defaults.
@MainActor
final class RefreshCoordinatorIndependentTests: XCTestCase {
    private actor Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isFired: Bool { fired }

        func wait() async {
            if fired { return }
            await withCheckedContinuation { continuation in
                if fired {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func signal() {
            fired = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation in
                if opened {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func resumeAll() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }

        @discardableResult
        func update<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }

    private func waitFor(
        _ signal: Signal,
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

    func testManualSourceIntentDuringProjectionOnlyRunGetsOneFollowUp() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let requests = Box<[RefreshRequest]>([])
        let firstProjectionEntered = Signal()
        let releaseFirstProjection = Gate()
        defer { Task { await releaseFirstProjection.resumeAll() } }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now },
            sleeper: { _ in },
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                return .succeeded(now)
            },
            operation: { request in
                let callNumber = projectionCalls.update { value in
                    value += 1
                    return value
                }
                requests.update { $0.append(request) }
                if callNumber == 1 {
                    await firstProjectionEntered.signal()
                    await releaseFirstProjection.wait()
                }
                return .completed
            }
        )

        coordinator.requestAfterCommit(domains: [.directory])
        let firstProjectionDidEnter = await waitFor(firstProjectionEntered)
        XCTAssertTrue(firstProjectionDidEnter)
        guard firstProjectionDidEnter else {
            await releaseFirstProjection.resumeAll()
            return
        }

        let manual = Task { await coordinator.request(.init(domains: [.directory], reason: .manual, force: true)) }
        let manualWasAdmitted = await waitUntil {
            coordinator.isRunning && coordinator.pendingWaiterCount == 1
        }
        XCTAssertTrue(manualWasAdmitted)
        guard manualWasAdmitted else {
            await releaseFirstProjection.resumeAll()
            _ = await manual.value
            return
        }
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.pendingWaiterCount, 1)
        await releaseFirstProjection.resumeAll()
        let result = await manual.value

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(projectionCalls.value, 2)
        XCTAssertEqual(requests.value.last?.reason, .manual)
        XCTAssertTrue(requests.value.last?.sourceIntent == true)
    }

    func testCancelAndWaitDrainsOldOperationRejectsNewWorkThenCoordinatorReuses() async {
        let operationCalls = Box(0)
        let operationEntered = Signal()
        let cancellationObserved = Signal()
        let releaseCancelledOperation = Gate()
        defer { Task { await releaseCancelledOperation.resumeAll() } }

        let coordinator = RefreshCoordinator(
            timeout: 0,
            sleeper: { _ in },
            operation: { _ in
                let callNumber = operationCalls.update { value in
                    value += 1
                    return value
                }
                guard callNumber == 1 else { return .completed }
                await operationEntered.signal()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return .completed
                } catch is CancellationError {
                    await cancellationObserved.signal()
                    await releaseCancelledOperation.wait()
                    throw CancellationError()
                }
            }
        )

        let first = Task { await coordinator.request(.init(reason: .manual, force: true)) }
        let operationDidEnter = await waitFor(operationEntered)
        XCTAssertTrue(operationDidEnter)
        guard operationDidEnter else {
            coordinator.cancel()
            await releaseCancelledOperation.resumeAll()
            _ = await first.value
            return
        }

        let draining = Task { await coordinator.cancelAndWait() }
        let cancellationWasObserved = await waitFor(cancellationObserved)
        XCTAssertTrue(cancellationWasObserved)
        guard cancellationWasObserved else {
            await releaseCancelledOperation.resumeAll()
            await draining.value
            _ = await first.value
            return
        }

        let rejected = await coordinator.request(.init(reason: .manual, force: true))
        XCTAssertEqual(rejected, .cancelled)
        coordinator.scheduleStartup()
        XCTAssertEqual(operationCalls.value, 1)
        XCTAssertTrue(coordinator.isRunning)

        await releaseCancelledOperation.resumeAll()
        await draining.value
        _ = await first.value

        let reusable = await coordinator.request(.init(reason: .manual, force: true))
        XCTAssertEqual(reusable, .completed)
        XCTAssertEqual(operationCalls.value, 2)
    }

    func testProjectionFailureWithoutSourceOperationDoesNotInventSourceFreshness() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now },
            sleeper: { _ in },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                return .failed("projection-failed")
            }
        )

        let result = await coordinator.request(.init(domains: [.directory], reason: .indexCommitted, force: true))

        XCTAssertEqual(result, .failed("projection-failed"))
        XCTAssertEqual(projectionCalls.value, 1)
        XCTAssertNil(coordinator.lastSuccessfulAt)
        XCTAssertEqual(coordinator.retryAttempt, 1)
        XCTAssertEqual(coordinator.nextAutomaticDate, now.addingTimeInterval(5 * 60))
    }

    func testFailedProjectionPreservesSuccessfulSourceTimestampAcrossProjectionRetry() async {
        let sourceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            interval: 1_800,
            timeout: 0,
            clock: { sourceDate },
            sleeper: { _ in },
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                return .succeeded(sourceDate)
            },
            operation: { _ in
                let callNumber = projectionCalls.update { value in
                    value += 1
                    return value
                }
                return callNumber == 1 ? .failed("projection-failed") : .completed
            }
        )

        let failed = await coordinator.request(.init(domains: [.directory], reason: .manual, force: true))
        XCTAssertEqual(failed, .failed("projection-failed"))
        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(coordinator.lastSuccessfulAt, sourceDate)
        XCTAssertEqual(coordinator.retryAttempt, 1)
        XCTAssertEqual(coordinator.nextAutomaticDate, sourceDate.addingTimeInterval(5 * 60))

        let recovered = await coordinator.request(.init(domains: [.directory], reason: .indexCommitted, force: true))
        XCTAssertEqual(recovered, .completed)
        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(coordinator.lastSuccessfulAt, sourceDate)
    }

    func testLongSourceOutlastsProjectionTimeoutThenFastProjectionCompletes() async {
        let sourceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let sourceEntered = Signal()
        let releaseSource = Gate()
        let coordinator = RefreshCoordinator(
            timeout: 0.01,
            clock: { sourceDate },
            sleeper: { _ in },
            timeoutSleeper: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            },
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                await sourceEntered.signal()
                await releaseSource.wait()
                return .succeeded(sourceDate)
            },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                return .completed
            }
        )
        defer { Task { await releaseSource.resumeAll() } }

        let request = Task { await coordinator.request(.init(domains: [.directory], reason: .manual, force: true)) }
        let didEnter = await waitFor(sourceEntered)
        XCTAssertTrue(didEnter)
        guard didEnter else {
            await releaseSource.resumeAll()
            _ = await request.value
            return
        }
        try? await Task.sleep(for: .milliseconds(30))
        await releaseSource.resumeAll()

        let result = await request.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(projectionCalls.value, 1)
        XCTAssertEqual(coordinator.lastSuccessfulAt, sourceDate)
    }

    func testInjectedTimeoutSleeperIsCancelledAfterFastCompletionAndCoordinatorReuses() async {
        let calls = Box(0)
        let timeoutStarted = Signal()
        let timeoutCancelled = Signal()
        let coordinator = RefreshCoordinator(
            timeout: 5,
            sleeper: { _ in },
            timeoutSleeper: { _ in
                await timeoutStarted.signal()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError {
                    await timeoutCancelled.signal()
                    throw CancellationError()
                }
            },
            operation: { _ in
                let callNumber = calls.update { value in
                    value += 1
                    return value
                }
                if callNumber == 1 { await timeoutStarted.wait() }
                return .completed
            }
        )

        let first = await coordinator.request(.init(reason: .manual, force: true))
        XCTAssertEqual(first, .completed)
        let wasCancelled = await waitFor(timeoutCancelled)
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(coordinator.isRunning)

        let second = await coordinator.request(.init(reason: .manual, force: true))
        XCTAssertEqual(second, .completed)
        XCTAssertEqual(calls.value, 2)
    }
}
