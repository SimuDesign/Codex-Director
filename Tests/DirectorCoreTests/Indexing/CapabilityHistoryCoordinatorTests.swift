import XCTest
@testable import DirectorCore

final class CapabilityHistoryCoordinatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(failing: Bool = true) {
            value = failing
        }

        func shouldFail() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func allowWrites() {
            lock.lock(); value = false; lock.unlock()
        }

        func failWrites() {
            lock.lock(); value = true; lock.unlock()
        }
    }

    private final class BlockingWriteFailure: @unchecked Sendable {
        private let condition = NSCondition()
        private var armed = false
        private var entered = false
        private var released = false

        func arm() {
            condition.lock()
            armed = true
            entered = false
            released = false
            condition.unlock()
        }

        func failOnceIfArmed() throws {
            condition.lock()
            guard armed else {
                condition.unlock()
                return
            }
            armed = false
            entered = true
            condition.broadcast()
            while !released {
                condition.wait()
            }
            condition.unlock()
            throw CapabilityHistoryStore.StoreError.atomicWriteFailed
        }

        func waitUntilEntered() async {
            while !hasEntered() {
                await Task.yield()
            }
        }

        private func hasEntered() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return entered
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private actor Gate {
        private var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            while !entered { await Task.yield() }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func observation(_ signature: Character = "a", at date: Date? = nil) -> CapabilityHistoryObservation {
        CapabilityHistoryObservation(
            resourceID: "skill:global:synthetic",
            sourceRootID: "global-skills",
            name: "Synthetic Skill",
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            signature: String(repeating: signature, count: 64),
            observedAt: date ?? base
        )
    }

    private func batch(
        _ observations: [CapabilityHistoryObservation],
        at date: Date? = nil,
        source: CapabilityHistoryObservationSource = .filesystem
    ) -> CapabilityHistoryScanBatch {
        CapabilityHistoryScanBatch(
            observedAt: date ?? base,
            scopes: [.init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: .complete)],
            observations: observations,
            source: source
        )
    }

    func testFilesystemBatchesBuildBaselineThenPublishRevisionAndEvent() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 9)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        let first = try await coordinator.submit(batch([observation()]))
        XCTAssertEqual(first?.revision, 1)
        XCTAssertTrue(first?.newEvents.isEmpty == true)

        let second = try await coordinator.submit(batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))
        XCTAssertEqual(second?.revision, 2)
        XCTAssertEqual(second?.newEvents.map(\.kind), [.modified])
        let status = await coordinator.status()
        XCTAssertEqual(status.revision, 2)
        XCTAssertEqual(status.eventCount, 1)
    }

    func testCacheFallbackDoesNotOpenHistoryOrAdvanceStatus() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 9)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        let result = try await coordinator.submit(batch([observation()], source: .cacheFallback))

        XCTAssertNil(result)
        let cached = await coordinator.status(refresh: false)
        XCTAssertNil(cached.revision)
        XCTAssertNil(cached.eventCount)
    }

    func testClearRevokesSubmissionDelayedAfterPermitAndOldResultCannotReappear() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 20)
        let baselineCoordinator = CapabilityHistoryCoordinator(store: store)
        _ = try await baselineCoordinator.submit(batch([observation()]))

        let gate = Gate()
        let coordinator = CapabilityHistoryCoordinator(store: store, beforeCommitHook: { await gate.wait() })
        let delayedBatch = batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1))
        let delayed = Task {
            try await coordinator.submit(delayedBatch)
        }
        await gate.waitUntilEntered()
        let clear = try await coordinator.clearConfirmed()
        XCTAssertEqual(clear.eventCount, 0)
        await gate.open()
        do {
            _ = try await delayed.value
            XCTFail("delayed pre-clear submission committed")
        } catch is CancellationError {
            // Expected.
        } catch CapabilityHistoryStore.StoreError.stalePermit {
            // Also safe if store revocation wins the race.
        }

        let page = try await coordinator.page(.init(limit: 20))
        XCTAssertTrue(page.events.isEmpty)
        let pendingStatus = await coordinator.status()
        XCTAssertEqual(pendingStatus.baselineCount, 0)
    }

    func testCancelPendingWritesPreservesHistoryAndAllowsLaterRefresh() async throws {
        let store = try CapabilityHistoryStore.memory()
        let coordinator = CapabilityHistoryCoordinator(store: store)
        _ = try await coordinator.submit(batch([observation()]))
        await coordinator.cancelPendingWrites()

        let result = try await coordinator.submit(batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))
        XCTAssertEqual(result?.newEvents.map(\.kind), [.modified])
        let initializedStatus = await coordinator.status()
        XCTAssertEqual(initializedStatus.baselineCount, 1)
    }

    func testExplicitClearMakesNextReliableScanBaselineOnly() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 3)
        let coordinator = CapabilityHistoryCoordinator(store: store)
        _ = try await coordinator.submit(batch([observation()]))
        _ = try await coordinator.submit(batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))
        let beforeClear = await coordinator.status()
        XCTAssertEqual(beforeClear.eventCount, 1)

        let cleared = try await coordinator.clearConfirmed()
        XCTAssertEqual(cleared.epoch, 4)
        let rebuilt = try await coordinator.submit(batch([
            observation("c", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)))
        XCTAssertTrue(rebuilt?.newEvents.isEmpty == true)
        let afterClear = await coordinator.status()
        XCTAssertEqual(afterClear.eventCount, 0)
    }

    func testRecordingFailureSurvivesStatusAndPageRefreshUntilSuccessfulCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let historyURL = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("history.json")
        let failure = FailureSwitch()
        let store = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeTemporaryWrite, failure.shouldFail() {
                    throw CapabilityHistoryStore.StoreError.fileBudgetExceeded
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(store: store)
        do {
            _ = try await coordinator.submit(batch([observation()]))
            XCTFail("injected recording failure did not surface")
        } catch CapabilityHistoryStore.StoreError.fileBudgetExceeded {
            // Expected.
        }
        let failedStatus = await coordinator.status()
        XCTAssertTrue(failedStatus.issueCodes.contains(.fileBudgetExceeded))
        _ = try await coordinator.page(.init(limit: 20))
        let refreshedStatus = await coordinator.status()
        XCTAssertTrue(refreshedStatus.issueCodes.contains(.fileBudgetExceeded))

        failure.allowWrites()
        _ = try await coordinator.submit(batch([observation()]))
        let recoveredStatus = await coordinator.status()
        XCTAssertFalse(recoveredStatus.issueCodes.contains(.fileBudgetExceeded))
    }

    func testAtomicObservationSaveFailureSignalSurvivesReadsThenClearsOnRecoveryAndClear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-coordinator-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let historyURL = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("history.json")
        let failure = FailureSwitch(failing: false)
        let store = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeReplacement, failure.shouldFail() {
                    throw CapabilityHistoryStore.StoreError.atomicWriteFailed
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(store: store)

        _ = try await coordinator.submit(batch([observation()]))
        failure.failWrites()
        do {
            _ = try await coordinator.submit(batch([
                observation("b", at: base.addingTimeInterval(1))
            ], at: base.addingTimeInterval(1)))
            XCTFail("injected atomic save failure did not surface")
        } catch CapabilityHistoryStore.StoreError.atomicWriteFailed {
            // Expected.
        }

        let failedStatus = await coordinator.status()
        XCTAssertTrue(failedStatus.latestObservationSaveFailed)
        XCTAssertTrue(failedStatus.issueCodes.contains(.storageUnavailable))

        let page = try await coordinator.page(.init(limit: 20))
        XCTAssertEqual(page.revision, 1)
        XCTAssertTrue(page.events.isEmpty)
        let refreshedStatus = await coordinator.status()
        XCTAssertTrue(refreshedStatus.latestObservationSaveFailed)

        failure.allowWrites()
        let recovered = try await coordinator.submit(batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))
        XCTAssertEqual(recovered?.newEvents.map(\.kind), [.modified])
        let recoveredStatus = await coordinator.status()
        XCTAssertFalse(recoveredStatus.latestObservationSaveFailed)

        let cleared = try await coordinator.clearConfirmed()
        XCTAssertFalse(cleared.latestObservationSaveFailed)
    }

    func testLateCommitFailureCannotOverrideConcurrentClearReset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-coordinator-clear-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let failure = BlockingWriteFailure()
        let store = try CapabilityHistoryStore.faultInjecting(
            url: root.appendingPathComponent("history.json"),
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeReplacement {
                    try failure.failOnceIfArmed()
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(
            store: store,
            storeAccessProbe: { operation in
                if case .clear = operation { failure.release() }
            }
        )
        _ = try await coordinator.submit(batch([observation()]))
        failure.arm()

        let delayedBatch = batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1))
        let delayed = Task {
            try await coordinator.submit(delayedBatch)
        }
        await failure.waitUntilEntered()
        let clear = Task { try await coordinator.clearConfirmed() }

        let cleared = try await clear.value
        XCTAssertEqual(cleared.eventCount, 0)
        do {
            _ = try await delayed.value
            XCTFail("pre-clear failed submission was not cancelled")
        } catch is CancellationError {
            // Expected: the old generation cannot publish failure diagnostics.
        }

        let status = await coordinator.status()
        XCTAssertFalse(status.latestObservationSaveFailed)
        XCTAssertFalse(status.issueCodes.contains(.storageUnavailable))
        XCTAssertFalse(status.issueCodes.contains(.corruptStorage))
    }

    func testLateCommitFailureCannotPublishDiagnosticsAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-coordinator-cancel-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let failure = BlockingWriteFailure()
        let store = try CapabilityHistoryStore.faultInjecting(
            url: root.appendingPathComponent("history.json"),
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeReplacement {
                    try failure.failOnceIfArmed()
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(
            store: store,
            storeAccessProbe: { operation in
                if case .cancel = operation { failure.release() }
            }
        )
        _ = try await coordinator.submit(batch([observation()]))
        failure.arm()

        let delayedBatch = batch([
            observation("b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1))
        let delayed = Task {
            try await coordinator.submit(delayedBatch)
        }
        await failure.waitUntilEntered()
        await coordinator.cancelPendingWrites()

        do {
            _ = try await delayed.value
            XCTFail("cancelled failed submission published its error")
        } catch is CancellationError {
            // Expected: cancellation owns the newer coordinator generation.
        }

        let status = await coordinator.status()
        XCTAssertFalse(status.latestObservationSaveFailed)
        XCTAssertFalse(status.issueCodes.contains(.storageUnavailable))
        XCTAssertFalse(status.issueCodes.contains(.corruptStorage))
    }

    func testInvalidCommitStateWithReadableRetainedHistoryIsRecordingFailureNotCorruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-coordinator-invalid-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let failure = FailureSwitch(failing: false)
        let store = try CapabilityHistoryStore.faultInjecting(
            url: root.appendingPathComponent("history.json"),
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeReplacement, failure.shouldFail() {
                    throw CapabilityHistoryStore.StoreError.invalidState
                }
            }
        )
        let coordinator = CapabilityHistoryCoordinator(store: store)
        _ = try await coordinator.submit(batch([observation()]))
        failure.failWrites()

        do {
            _ = try await coordinator.submit(batch([
                observation("b", at: base.addingTimeInterval(1))
            ], at: base.addingTimeInterval(1)))
            XCTFail("injected invalid commit state did not surface")
        } catch CapabilityHistoryStore.StoreError.invalidState {
            // Expected.
        }

        let page = try await coordinator.page(.init(limit: 20))
        XCTAssertEqual(page.revision, 1)
        XCTAssertTrue(page.events.isEmpty)
        let status = await coordinator.status()
        XCTAssertTrue(status.latestObservationSaveFailed)
        XCTAssertTrue(status.issueCodes.contains(.storageUnavailable))
        XCTAssertFalse(status.issueCodes.contains(.corruptStorage))
    }
}
