import Foundation
import XCTest
@testable import DirectorCore

final class ProjectSourceReadGateTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var snapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func root(_ id: String, _ path: String) -> ScanRoot {
        ScanRoot(
            id: id,
            url: URL(fileURLWithPath: path, isDirectory: true),
            scope: .project,
            kind: .projects
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    func testTimeoutRetainsRootAndSlotUntilWorkerActuallyReturns() async {
        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
        let blocked = DispatchSemaphore(value: 0)
        let starts = Counter()
        let project = root("project", "/synthetic/project")

        let firstTask = Task {
            await gate.perform(root: project) {
                starts.increment()
                blocked.wait()
                return 1
            }
        }
        let didStart = await waitUntil { starts.snapshot == 1 }
        XCTAssertTrue(didStart)
        let first = await firstTask.value
        guard case .failure(.timedOut) = first else {
            return XCTFail("expected timeout, got \(first)")
        }

        let duplicate = await gate.perform(root: project) {
            starts.increment()
            return 2
        }
        guard case .failure(.busy) = duplicate else {
            blocked.signal()
            return XCTFail("same active root must be busy")
        }
        XCTAssertEqual(starts.snapshot, 1)
        XCTAssertEqual(gate.activeWorkerCountForTesting, 1)

        blocked.signal()
        let didRelease = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(didRelease)
        let retry = await gate.perform(root: project) {
            starts.increment()
            return 3
        }
        XCTAssertEqual(try? retry.get(), 3)
        XCTAssertEqual(starts.snapshot, 2)
    }

    func testTwoBlockedRootsSaturateCapacityAndThirdDoesNotQueue() async {
        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
        let firstRelease = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        let starts = Counter()
        let firstRoot = root("one", "/synthetic/one")
        let secondRoot = root("two", "/synthetic/two")
        let thirdRoot = root("three", "/synthetic/three")

        let first = Task {
            await gate.perform(root: firstRoot) {
                starts.increment()
                firstRelease.wait()
                return 1
            }
        }
        let second = Task {
            await gate.perform(root: secondRoot) {
                starts.increment()
                secondRelease.wait()
                return 2
            }
        }
        let didStartBoth = await waitUntil { starts.snapshot == 2 }
        XCTAssertTrue(didStartBoth)
        let firstResult = await first.value
        let secondResult = await second.value
        guard case .failure(.timedOut) = firstResult,
              case .failure(.timedOut) = secondResult else {
            firstRelease.signal()
            secondRelease.signal()
            return XCTFail("both admitted workers should time out for callers")
        }

        let third = await gate.perform(root: thirdRoot) {
            starts.increment()
            return 3
        }
        guard case .failure(.busy) = third else {
            firstRelease.signal()
            secondRelease.signal()
            return XCTFail("saturated gate must fail without queueing")
        }
        XCTAssertEqual(starts.snapshot, 2)
        XCTAssertEqual(gate.activeWorkerCountForTesting, 2)

        firstRelease.signal()
        secondRelease.signal()
        let didReleaseBoth = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(didReleaseBoth)
    }

    func testCancellationReturnsButDoesNotReleaseActiveWorker() async {
        let gate = ProjectSourceReadGate(deadline: 1, capacity: 1)
        let blocked = DispatchSemaphore(value: 0)
        let starts = Counter()
        let project = root("cancelled", "/synthetic/cancelled")

        let task = Task {
            await gate.perform(root: project) {
                starts.increment()
                blocked.wait()
                return 1
            }
        }
        let didStart = await waitUntil { starts.snapshot == 1 }
        XCTAssertTrue(didStart)
        task.cancel()
        let cancelledResult = await task.value
        guard case .failure(.cancelled) = cancelledResult else {
            blocked.signal()
            return XCTFail("cancelled caller must stop waiting")
        }
        let duplicate = await gate.perform(root: project, operation: { 2 })
        guard case .failure(.busy) = duplicate else {
            blocked.signal()
            return XCTFail("cancelled blocked worker must retain its reservation")
        }

        blocked.signal()
        let didRelease = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(didRelease)
        let retry = await gate.perform(root: project, operation: { 3 })
        XCTAssertEqual(try? retry.get(), 3)
    }

    func testRootIdentityIncludesLexicalURLWithoutResolvingIt() async {
        let gate = ProjectSourceReadGate(deadline: 1, capacity: 2)
        let releaseA = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let starts = Counter()
        let firstRoot = root("reused-id", "/synthetic/location-a")
        let secondRoot = root("reused-id", "/synthetic/location-b")

        let first = Task {
            await gate.perform(root: firstRoot) {
                starts.increment()
                releaseA.wait()
                return 1
            }
        }
        let second = Task {
            await gate.perform(root: secondRoot) {
                starts.increment()
                releaseB.wait()
                return 2
            }
        }
        let didStartBoth = await waitUntil { starts.snapshot == 2 }
        XCTAssertTrue(didStartBoth)
        XCTAssertEqual(gate.activeWorkerCountForTesting, 2)
        releaseA.signal()
        releaseB.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(try? firstResult.get(), 1)
        XCTAssertEqual(try? secondResult.get(), 2)
    }

    func testDifferentRootIDsForSameLexicalURLRemainSingleFlight() async {
        let gate = ProjectSourceReadGate(deadline: 1, capacity: 2)
        let release = DispatchSemaphore(value: 0)
        let starts = Counter()
        let firstRoot = root("first-id", "/synthetic/shared-location")
        let aliasRoot = root("second-id", "/synthetic/shared-location")

        let first = Task {
            await gate.perform(root: firstRoot) {
                starts.increment()
                release.wait()
                return 1
            }
        }
        let didStart = await waitUntil { starts.snapshot == 1 }
        XCTAssertTrue(didStart)

        let alias = await gate.perform(root: aliasRoot) {
            starts.increment()
            return 2
        }
        guard case .failure(.busy) = alias else {
            release.signal()
            return XCTFail("one lexical project location must remain single-flight")
        }
        XCTAssertEqual(starts.snapshot, 1)
        release.signal()
        let firstValue = try? await first.value.get()
        XCTAssertEqual(firstValue, 1)
    }

    func testLateFailureValueIsDiscardedAndRetryIsFresh() async {
        enum SyntheticFailure: Error, Sendable { case late }

        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 1)
        let blocked = DispatchSemaphore(value: 0)
        let starts = Counter()
        let project = root("late", "/synthetic/late")
        let first = Task {
            await gate.perform(root: project) { () -> Result<Int, SyntheticFailure> in
                starts.increment()
                blocked.wait()
                return .failure(.late)
            }
        }

        let didStart = await waitUntil { starts.snapshot == 1 }
        XCTAssertTrue(didStart)
        let firstResult = await first.value
        guard case .failure(.timedOut) = firstResult else {
            blocked.signal()
            return XCTFail("consumer must receive only the gate timeout")
        }
        blocked.signal()
        let didRelease = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(didRelease)

        let retry = await gate.perform(root: project) { () -> Result<Int, SyntheticFailure> in
            starts.increment()
            return .success(7)
        }
        let nested = try? retry.get()
        XCTAssertEqual(try? nested?.get(), 7)
        XCTAssertEqual(starts.snapshot, 2)
    }

    func testWorkerReturningAfterAbsoluteDeadlineCannotPublishSuccess() async {
        let gate = ProjectSourceReadGate(deadline: 0.01, capacity: 1)
        let project = root("late-success", "/synthetic/late-success")

        let result = await gate.perform(root: project) {
            Thread.sleep(forTimeInterval: 0.04)
            return 42
        }

        guard case .failure(.timedOut) = result else {
            return XCTFail("a value returned after the admitted deadline must be discarded")
        }
        let released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)
    }

    func testFastCompletionsReleaseReservationsWithoutDeadlineBacklog() async {
        let gate = ProjectSourceReadGate(deadline: 1, capacity: 2)
        for index in 0..<100 {
            let result = await gate.perform(root: root("fast-\(index)", "/synthetic/fast-\(index)")) {
                index
            }
            XCTAssertEqual(try? result.get(), index)
        }
        XCTAssertEqual(gate.activeWorkerCountForTesting, 0)
    }
}
