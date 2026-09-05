import Foundation
import XCTest
@testable import DirectorUI

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
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

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var storedWaitCount = 0

        var waitCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedWaitCount
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                storedWaitCount += 1
                continuations.append(continuation)
                lock.unlock()
            }
        }

        func resumeAll() {
            lock.lock()
            let waiting = continuations
            continuations.removeAll()
            lock.unlock()
            waiting.forEach { $0.resume() }
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("condition did not become true before timeout")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func testAutomaticRefreshWaitsForThirtyMinutesButManualBypasses() async {
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let calls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now.value },
            sleeper: { _ in },
            sourceOperation: { _ in .succeeded(now.value) },
            operation: { _ in calls.update { $0 += 1 }; return .completed }
        )

        let initial = await coordinator.request(.init(reason: .manual))
        XCTAssertEqual(initial, .completed)
        XCTAssertEqual(calls.value, 1)

        now.update { $0.addTimeInterval(30 * 60 - 1) }
        let early = await coordinator.request(.init(reason: .automatic))
        XCTAssertEqual(early, .notDue)
        XCTAssertEqual(calls.value, 1)

        now.update { $0.addTimeInterval(1) }
        let due = await coordinator.request(.init(reason: .automatic))
        XCTAssertEqual(due, .completed)
        XCTAssertEqual(calls.value, 2)
    }

    func testStartupGraceKeepsWindowFreeBeforeBackgroundWork() async {
        let calls = Box(0)
        let sleeperGate = Gate()
        defer { sleeperGate.resumeAll() }
        let coordinator = RefreshCoordinator(
            initialGrace: 5,
            timeout: 0,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleeper: { _ in await sleeperGate.wait() },
            operation: { _ in calls.update { $0 += 1 }; return .completed }
        )

        coordinator.scheduleStartup()
        await waitUntil { sleeperGate.waitCount == 1 }
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(sleeperGate.waitCount, 1)

        sleeperGate.resumeAll()
        await waitUntil { calls.value == 1 }
        XCTAssertEqual(calls.value, 1)
    }

    func testConcurrentRequestsMergeAndPermitAtMostOneFollowUp() async {
        let calls = Box(0)
        let requests = Box<[RefreshRequest]>([])
        let operationGate = Gate()
        defer { operationGate.resumeAll() }
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sleeper: { _ in },
            operation: { request in
                let callNumber = calls.update { value in
                    value += 1
                    return value
                }
                requests.update { $0.append(request) }
                if callNumber == 1 { await operationGate.wait() }
                return .completed
            }
        )

        let first = Task { await coordinator.request(.init(domains: [.directory], reason: .manual)) }
        await waitUntil { calls.value == 1 && coordinator.pendingWaiterCount == 1 }
        XCTAssertEqual(calls.value, 1)

        let followers = (0..<10).map { _ in
            Task { await coordinator.request(.init(domains: [.quota], reason: .manual)) }
        }
        await waitUntil { coordinator.pendingWaiterCount == 11 }
        operationGate.resumeAll()

        _ = await first.value
        for follower in followers { _ = await follower.value }
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(requests.value[1].domains, Set([.directory, .quota]))
    }

    func testManualRefreshAfterSkippedSourceGetsOneFollowUp() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let gate = Gate()
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { request in
                sourceCalls.update { $0 += 1 }
                return request.reason == .automatic ? .skipped : .succeeded(Date())
            },
            operation: { _ in
                let callNumber = projectionCalls.update { value in
                    value += 1
                    return value
                }
                if callNumber == 1 { await gate.wait() }
                return .completed
            }
        )
        let automatic = Task { await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true)) }
        await waitUntil { projectionCalls.value == 1 }
        let manual = Task { await coordinator.request(.init(domains: [.quota], reason: .manual, force: true)) }
        await Task.yield()
        gate.resumeAll()
        let automaticResult = await automatic.value
        let manualResult = await manual.value
        XCTAssertEqual(automaticResult, .completed)
        XCTAssertEqual(manualResult, .completed)
        XCTAssertEqual(sourceCalls.value, 2)
        XCTAssertEqual(projectionCalls.value, 2)
    }

    func testFailuresUseFiveMinuteBackoffAndManualStillRuns() async {
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let calls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now.value },
            sleeper: { _ in },
            sourceOperation: { _ in
                let callNumber = calls.update { value in
                    value += 1
                    return value
                }
                return callNumber == 1 ? .failed("temporary") : .succeeded(now.value)
            },
            operation: { _ in
                return .completed
            }
        )

        let failed = await coordinator.request(.init(reason: .manual))
        XCTAssertEqual(failed, .failed("temporary"))
        now.update { $0.addTimeInterval(299) }
        let deferred = await coordinator.request(.init(reason: .automatic))
        XCTAssertEqual(deferred, .deferred)
        let recovered = await coordinator.request(.init(reason: .manual))
        XCTAssertEqual(recovered, .completed)
        XCTAssertEqual(calls.value, 2)
    }

    func testTimeoutCancelsOperationAndRecordsRetry() async {
        let coordinator = RefreshCoordinator(
            timeout: 5,
            sleeper: { _ in },
            sourceOperation: { _ in .skipped },
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return .completed
            }
        )

        let result = await coordinator.request(.init(reason: .manual))
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(coordinator.retryAttempt, 1)
    }

    func testDefaultFiveSecondTimeoutCancelsFastCompletionRepeatedly() async {
        let calls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 5,
            operation: { _ in
                calls.update { $0 += 1 }
                return .completed
            }
        )

        for _ in 0..<100 {
            let result = await coordinator.request(.init(reason: .manual, force: true))
            XCTAssertEqual(result, .completed)
        }

        XCTAssertEqual(calls.value, 100)
        XCTAssertEqual(coordinator.retryAttempt, 0)
    }

    func testDefaultTimeoutReturnsTimedOutForSlowProjection() async {
        let coordinator = RefreshCoordinator(
            timeout: 0.01,
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return .completed
            }
        )

        let result = await coordinator.request(.init(reason: .manual, force: true))

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(coordinator.retryAttempt, 1)
    }

    func testDayChangedProjectionDoesNotAdvanceSourceCheckTTL() async {
        let now = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now.value },
            sourceOperation: { _ in .succeeded(now.value) },
            operation: { _ in .completed }
        )

        let first = await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true))
        XCTAssertEqual(first, .completed)
        let sourceCheck = coordinator.lastSuccessfulAt
        XCTAssertNotNil(sourceCheck)

        now.update { $0.addTimeInterval(86_400) }
        let midnight = await coordinator.request(.init(domains: [.quota], reason: .dayChanged, force: true))
        XCTAssertEqual(midnight, .completed)
        XCTAssertEqual(coordinator.lastSuccessfulAt, sourceCheck)
    }

    func testSkippedSourceDoesNotAdvanceTTL() async {
        let calls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in .skipped },
            operation: { _ in calls.update { $0 += 1 }; return .completed }
        )

        let result = await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true))
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(coordinator.lastSuccessfulAt)
    }

    func testTenManualRequestsShareOneSourceRun() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let sourceGate = Gate()
        defer { sourceGate.resumeAll() }
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                await sourceGate.wait()
                return .succeeded(Date(timeIntervalSince1970: 1_800_000_000))
            },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )

        let first = Task { await coordinator.request(.init(domains: [.quota], reason: .manual, force: true)) }
        await waitUntil { sourceCalls.value == 1 }
        let followers = (0..<10).map { _ in
            Task { await coordinator.request(.init(domains: [.quota], reason: .manual, force: true)) }
        }
        await waitUntil { coordinator.pendingWaiterCount == 11 }
        sourceGate.resumeAll()
        _ = await first.value
        for follower in followers { _ = await follower.value }

        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(projectionCalls.value, 1)
    }

    func testCommitAndDayChangedRemainProjectionOnly() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in sourceCalls.update { $0 += 1 }; return .succeeded(Date()) },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )

        let committed = await coordinator.request(.init(domains: [.directory], reason: .indexCommitted, force: true))
        let midnight = await coordinator.request(.init(domains: [.quota], reason: .dayChanged, force: true))
        XCTAssertEqual(committed, .completed)
        XCTAssertEqual(midnight, .completed)
        XCTAssertEqual(sourceCalls.value, 0)
        XCTAssertEqual(projectionCalls.value, 2)
        XCTAssertNil(coordinator.lastSuccessfulAt)
    }

    func testCommitSupersedesPendingStartupWithoutStartingSource() async {
        let startupSleeperEntered = Box(false)
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            initialGrace: 60,
            timeout: 0,
            sleeper: { _ in
                startupSleeperEntered.value = true
                try await Task.sleep(for: .seconds(60))
            },
            sourceOperation: { _ in sourceCalls.update { $0 += 1 }; return .succeeded(Date()) },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )

        coordinator.scheduleStartup()
        await waitUntil { startupSleeperEntered.value }
        let result = await coordinator.request(.init(domains: [.directory], reason: .indexCommitted, force: true))

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(sourceCalls.value, 0)
        XCTAssertEqual(projectionCalls.value, 1)
    }

    func testFutureSourceSuccessDoesNotAdvanceTTL() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now },
            sourceOperation: { _ in .succeeded(now.addingTimeInterval(1)) },
            operation: { _ in .completed }
        )

        let result = await coordinator.request(.init(domains: [.quota], reason: .manual, force: true))
        XCTAssertEqual(result, .completed)
        XCTAssertNil(coordinator.lastSuccessfulAt)
    }

    func testLongSourceRunsBeforeProjectionTimeout() async {
        let sourceStarted = Box(false)
        let projectionCalls = Box(0)
        let sourceGate = Gate()
        defer { sourceGate.resumeAll() }
        let coordinator = RefreshCoordinator(
            timeout: 5,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            timeoutSleeper: { _ in },
            sourceOperation: { _ in
                sourceStarted.value = true
                await sourceGate.wait()
                return .succeeded(Date(timeIntervalSince1970: 1_800_000_000))
            },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                try await Task.sleep(for: .seconds(60))
                return .completed
            }
        )

        let request = Task { await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true)) }
        await waitUntil { sourceStarted.value }
        XCTAssertTrue(sourceStarted.value)
        sourceGate.resumeAll()
        let result = await request.value
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(projectionCalls.value, 1)
        XCTAssertEqual(coordinator.retryAttempt, 1)
        XCTAssertNotNil(coordinator.lastSuccessfulAt)
    }

    func testSourceFailureSchedulesBackoffWithoutSuccessTimestamp() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in sourceCalls.update { $0 += 1 }; return .failed("source-unavailable") },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )

        let result = await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true))
        XCTAssertEqual(result, .failed("source-unavailable"))
        XCTAssertEqual(sourceCalls.value, 1)
        XCTAssertEqual(projectionCalls.value, 0)
        XCTAssertNil(coordinator.lastSuccessfulAt)
        XCTAssertEqual(coordinator.retryAttempt, 1)
    }
}
