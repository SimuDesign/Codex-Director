import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class RefreshSchedulePersistenceTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&storage)
            lock.unlock()
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiting = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            waiting += 1
            await withCheckedContinuation { waiters.append($0) }
        }

        func count() -> Int { waiting }

        func resumeAll() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @discardableResult
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("condition did not become true", file: file, line: line)
                return false
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private func waitForGate(_ gate: Gate, count expected: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.count() < expected {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func testRestoreKeepsRetryLanesAndChoosesEarliestWake() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = RefreshCoordinator(
            clock: { now },
            sourceOperation: { _ in .skipped },
            operation: { _ in .completed }
        )
        let persisted = PresentationRefreshSchedule(
            revision: 7,
            recordedAt: now.addingTimeInterval(-10),
            lastSourceSuccessAt: now.addingTimeInterval(-1_800),
            sourceRetryAttempt: 2,
            sourceRetryDate: now.addingTimeInterval(100),
            projectionRetryAttempt: 1,
            projectionRetryDate: now.addingTimeInterval(200)
        )

        coordinator.restoreScheduleState(persisted)

        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 2)
        XCTAssertEqual(coordinator.scheduleState.projectionRetryAttempt, 1)
        XCTAssertEqual(coordinator.nextWakeDate, now.addingTimeInterval(100))
        XCTAssertEqual(coordinator.persistedSchedule.revision, 8)
        let priorRevision = coordinator.scheduleState.revision
        coordinator.restoreScheduleState(PresentationRefreshSchedule(revision: .max, recordedAt: now))
        let rebasedRevision = coordinator.scheduleState.revision
        XCTAssertGreaterThan(rebasedRevision, priorRevision)

        let sourceDue = Date(timeIntervalSince1970: 1_800_000_000)
        let dueCoordinator = RefreshCoordinator(
            timeout: 0,
            clock: { sourceDue },
            sourceOperation: { _ in .failed("still-unavailable") },
            operation: { _ in .completed }
        )
        dueCoordinator.restoreScheduleState(PresentationRefreshSchedule(
            revision: 2,
            recordedAt: sourceDue,
            sourceRetryAttempt: 2,
            sourceRetryDate: sourceDue.addingTimeInterval(-1)
        ))
        let retryResult = await dueCoordinator.requestAutomatic(domains: [.directory])
        XCTAssertEqual(retryResult, .failed("still-unavailable"))
        XCTAssertEqual(dueCoordinator.scheduleState.sourceRetryAttempt, 3)
        XCTAssertEqual(dueCoordinator.nextWakeDate, sourceDue.addingTimeInterval(30 * 60))
    }

    func testProjectionRetryDoesNotRunSourceAndDoesNotClearSourceRetry() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now },
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                return .succeeded(now)
            },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                return projectionCalls.read() == 1 ? .failed("projection") : .completed
            }
        )
        coordinator.restoreScheduleState(PresentationRefreshSchedule(
            recordedAt: now,
            sourceRetryAttempt: 1,
            sourceRetryDate: now.addingTimeInterval(300)
        ))

        let failed = await coordinator.request(.init(domains: [.quota], reason: .indexCommitted, force: true))
        XCTAssertEqual(failed, .failed("projection"))
        XCTAssertEqual(sourceCalls.read(), 0)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 1)
        XCTAssertEqual(coordinator.scheduleState.projectionRetryAttempt, 1)

        let recovered = await coordinator.request(.init(domains: [.quota], reason: .indexCommitted, force: true))
        XCTAssertEqual(recovered, .completed)
        XCTAssertEqual(sourceCalls.read(), 0)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 1)
        XCTAssertEqual(coordinator.scheduleState.projectionRetryAttempt, 0)
    }

    func testSourceFailureSchedulesSourceRetryWithoutProjection() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                return .failed("source")
            },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                return .completed
            }
        )

        let result = await coordinator.request(.init(domains: [.directory], reason: .automatic, force: true))

        XCTAssertEqual(result, .failed("source"))
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 0)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 1)
        XCTAssertEqual(coordinator.scheduleState.projectionRetryAttempt, 0)
    }

    func testThrowingSourceIsClassifiedAsSourceFailure() async {
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            sourceOperation: { _ in
                sourceCalls.update { $0 += 1 }
                struct SourceUnavailable: Error {}
                throw SourceUnavailable()
            },
            operation: { _ in
                projectionCalls.update { $0 += 1 }
                return .completed
            }
        )

        let result = await coordinator.request(.init(domains: [.directory], reason: .automatic, force: true))

        XCTAssertEqual(result, .failed("source_failed"))
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 0)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 1)
        XCTAssertEqual(coordinator.scheduleState.projectionRetryAttempt, 0)
    }

    func testNonFiniteSourceSuccessDoesNotAdvanceTTL() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            clock: { now },
            sourceOperation: { _ in .succeeded(Date(timeIntervalSinceReferenceDate: .nan)) },
            operation: { _ in .completed }
        )

        let result = await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true))

        XCTAssertEqual(result, .completed)
        XCTAssertNil(coordinator.lastSuccessfulAt)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 1)
    }

    func testFutureOrAbsurdRestoredDatesBecomeStale() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = RefreshCoordinator(clock: { now }, sourceOperation: { _ in .skipped }, operation: { _ in .completed })
        coordinator.restoreScheduleState(PresentationRefreshSchedule(
            recordedAt: now.addingTimeInterval(-1),
            lastSourceSuccessAt: now.addingTimeInterval(1),
            sourceRetryAttempt: 1,
            sourceRetryDate: now.addingTimeInterval(3_600)
        ))

        XCTAssertNil(coordinator.scheduleState.lastSourceSuccessAt)
        XCTAssertEqual(coordinator.scheduleState.sourceRetryAttempt, 0)
        XCTAssertNil(coordinator.scheduleState.sourceRetryDate)
        XCTAssertEqual(coordinator.nextWakeDate, now)

        coordinator.setAutomaticSourceEnabled(false)
        XCTAssertNil(coordinator.nextWakeDate)

        let skippedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let skippedCoordinator = RefreshCoordinator(
            timeout: 0,
            clock: { skippedNow },
            sourceOperation: { _ in .skipped },
            operation: { _ in .completed }
        )
        _ = await skippedCoordinator.requestAutomatic(domains: [.directory])
        XCTAssertEqual(skippedCoordinator.nextWakeDate, skippedNow.addingTimeInterval(5 * 60))
    }

    func testDayChangedDuringActiveRunGetsOneProjectionFollowUp() async {
        let gate = Gate()
        let calls = Box(0)
        let coordinator = RefreshCoordinator(
            timeout: 0,
            operation: { _ in
                calls.update { $0 += 1 }
                if calls.read() == 1 { await gate.wait() }
                return .completed
            }
        )

        let first = Task { await coordinator.request(.init(domains: [.quota], reason: .automatic, force: true, sourceIntent: false)) }
        let firstEntered = await waitForGate(gate, count: 1)
        guard firstEntered else {
            await gate.resumeAll()
            first.cancel()
            _ = await first.value
            XCTFail("first operation did not enter gate")
            return
        }
        let midnight = Task { await coordinator.request(.init(domains: [.quota], reason: .dayChanged, force: true, sourceIntent: false)) }
        let followUpQueued = await waitUntil { coordinator.pendingWaiterCount == 2 }
        guard followUpQueued else {
            await gate.resumeAll()
            first.cancel()
            midnight.cancel()
            _ = await first.value
            _ = await midnight.value
            XCTFail("dayChanged follow-up did not queue")
            return
        }
        await gate.resumeAll()

        let firstResult = await first.value
        let midnightResult = await midnight.value
        XCTAssertEqual(firstResult, .completed)
        XCTAssertEqual(midnightResult, .completed)
        XCTAssertEqual(calls.read(), 2)
    }

    func testAutomaticDoesNotCancelStartupGrace() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = Gate()
        let sourceCalls = Box(0)
        let projectionCalls = Box(0)
        let coordinator = RefreshCoordinator(
            initialGrace: 5,
            timeout: 0,
            clock: { now },
            sleeper: { _ in await gate.wait() },
            sourceOperation: { _ in sourceCalls.update { $0 += 1 }; return .skipped },
            operation: { _ in projectionCalls.update { $0 += 1 }; return .completed }
        )

        coordinator.scheduleStartup(domains: [.quota])
        let graceEntered = await waitForGate(gate, count: 1)
        guard graceEntered else {
            await gate.resumeAll()
            XCTFail("startup grace sleeper did not enter gate")
            return
        }
        let graceDeadline = now.addingTimeInterval(5)
        XCTAssertEqual(coordinator.nextWakeDate, graceDeadline)
        let automatic = Task { await coordinator.requestAutomatic(domains: [.quota]) }
        let automaticQueued = await waitUntil { coordinator.pendingWaiterCount == 1 }
        guard automaticQueued else {
            await gate.resumeAll()
            automatic.cancel()
            _ = await automatic.value
            XCTFail("automatic request did not remain behind startup grace")
            return
        }
        XCTAssertEqual(sourceCalls.read(), 0)
        XCTAssertEqual(projectionCalls.read(), 0)
        XCTAssertEqual(coordinator.scheduleState.phase, .startupGrace)

        await gate.resumeAll()
        let automaticResult = await automatic.value
        XCTAssertEqual(automaticResult, .completed)
        XCTAssertEqual(sourceCalls.read(), 1)
        XCTAssertEqual(projectionCalls.read(), 1)
    }

    func testStateCallbackRevisionsAreMonotonic() async {
        let revisions = Box<[UInt64]>([])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = RefreshCoordinator(timeout: 0, clock: { now }, operation: { _ in .completed })
        coordinator.setStateChangeHandler { state in revisions.update { $0.append(state.revision) } }
        coordinator.restoreScheduleState(PresentationRefreshSchedule(revision: 4, recordedAt: now))

        _ = await coordinator.request(.init(domains: [.quota], reason: .indexCommitted, force: true))

        let revisionValues = revisions.read()
        XCTAssertFalse(revisionValues.isEmpty)
        XCTAssertEqual(revisionValues, revisionValues.sorted())
        XCTAssertEqual(Set(revisionValues).count, revisionValues.count)
    }

    func testScheduleJSONRoundTripsAndLegacySnapshotDecodesWithoutOptionalField() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = PresentationRefreshSchedule(
            revision: 3,
            recordedAt: now,
            lastSourceSuccessAt: now.addingTimeInterval(-60),
            sourceRetryAttempt: 1,
            sourceRetryDate: now.addingTimeInterval(300)
        )
        let scheduleData = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(PresentationRefreshSchedule.self, from: scheduleData), schedule)

        let identity = PresentationIdentity(databaseEpoch: "epoch", dataGeneration: 1)
        let window = CapabilityQueryWindow(
            start: now.addingTimeInterval(-86_400),
            end: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let snapshot = PresentationSnapshot(
            identity: identity,
            classificationRevision: "classification",
            window: window,
            generatedAt: now,
            refreshSchedule: schedule
        )
        let encodedSnapshot = try JSONEncoder().encode(snapshot)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedSnapshot) as? [String: Any])
        legacyObject.removeValue(forKey: "refreshSchedule")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(PresentationSnapshot.self, from: legacyData)
        XCTAssertNil(decodedLegacy.refreshSchedule)
    }
}
