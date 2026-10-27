import Darwin
import XCTest
@testable import DirectorCore

final class CapabilityHistoryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-history-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func url(in root: URL) -> URL {
        root.appendingPathComponent("private", isDirectory: true).appendingPathComponent("history.json")
    }

    private func observation(
        _ id: String = "skill:global:synthetic",
        signature: Character = "a",
        at date: Date? = nil,
        name: String = "Synthetic Skill"
    ) -> CapabilityHistoryObservation {
        CapabilityHistoryObservation(
            resourceID: id,
            sourceRootID: "global-skills",
            name: name,
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            signature: String(repeating: signature, count: 64),
            documentSignatures: [
                .init(document: .skillManifest, sha256: String(repeating: signature, count: 64))
            ],
            observedAt: date ?? base
        )
    }

    private func batch(
        _ observations: [CapabilityHistoryObservation],
        at date: Date? = nil,
        coverage: CapabilityHistoryCoverage = .complete
    ) -> CapabilityHistoryScanBatch {
        CapabilityHistoryScanBatch(
            observedAt: date ?? base,
            scopes: [.init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: coverage)],
            observations: observations
        )
    }

    @discardableResult
    private func commit(
        _ batch: CapabilityHistoryScanBatch,
        to store: CapabilityHistoryStore
    ) async throws -> CapabilityHistoryCommitResult {
        let permit = try await store.issueWritePermit()
        return try await store.commit(batch, permit: permit)
    }

    func testMemoryStoreBuildsBaselineAndPagesNewestEvents() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 17)
        let first = try await commit(batch([observation()]), to: store)
        XCTAssertTrue(first.newEvents.isEmpty)

        _ = try await commit(batch([
            observation(signature: "b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)), to: store)
        _ = try await commit(batch([
            observation(signature: "c", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)), to: store)

        let firstPage = try await store.page(.init(resourceID: "skill:global:synthetic", limit: 1))
        XCTAssertEqual(firstPage.events.map(\.sequence), [2])
        XCTAssertEqual(firstPage.nextBeforeSequence, 2)
        let secondPage = try await store.page(.init(
            resourceID: "skill:global:synthetic",
            beforeSequence: firstPage.nextBeforeSequence,
            limit: 1
        ))
        XCTAssertEqual(secondPage.events.map(\.sequence), [1])
        XCTAssertNil(secondPage.nextBeforeSequence)
    }

    func testHistoryPageUpperBoundIsInclusiveAndExcludesFutureEvents() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 18)
        _ = try await commit(batch([observation()]), to: store)
        for (offset, signature) in [(1.0, Character("b")), (2.0, Character("c")), (3.0, Character("d"))] {
            let observedAt = base.addingTimeInterval(offset)
            _ = try await commit(batch([
                observation(signature: signature, at: observedAt)
            ], at: observedAt), to: store)
        }

        let throughSecond = try await store.page(.init(
            resourceID: "skill:global:synthetic",
            observedOnOrAfter: base.addingTimeInterval(1),
            observedOnOrBefore: base.addingTimeInterval(2),
            limit: 20
        ))
        XCTAssertEqual(throughSecond.events.map(\.observedAt), [
            base.addingTimeInterval(2),
            base.addingTimeInterval(1),
        ])

        let inverted = try await store.page(.init(
            observedOnOrAfter: base.addingTimeInterval(3),
            observedOnOrBefore: base.addingTimeInterval(2),
            limit: 20
        ))
        XCTAssertTrue(inverted.events.isEmpty)
        XCTAssertNil(inverted.nextBeforeSequence)
    }

    func testFileSchemaPersistsOnlySafeMetadataWithPrivatePermissions() async throws {
        let root = try temporaryRoot("safe-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        let store = try fileStore(at: historyURL)
        _ = try await commit(batch([observation()]), to: store)
        _ = try await commit(batch([
            observation(signature: "b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)), to: store)

        let text = String(decoding: try Data(contentsOf: historyURL), as: UTF8.self)
        XCTAssertTrue(text.contains("skill:global:synthetic"))
        XCTAssertFalse(text.contains("SKILL.md"))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("sourceBody"))
        XCTAssertFalse(text.contains("prompt"))
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: historyURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testExistingHistoryFilePermissionsAreNarrowedBeforeRead() async throws {
        let root = try temporaryRoot("existing-permissions")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        do {
            let seed = try fileStore(at: historyURL)
            _ = try await commit(batch([observation()]), to: seed)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: historyURL.path)
        let reopened = try fileStore(at: historyURL)
        _ = await reopened.status()
        XCTAssertEqual(try permissions(of: historyURL), 0o600)
    }

    func testProductionRejectsCustomAndRootLevelURLsWithoutMutatingParentPermissions() throws {
        let root = try temporaryRoot("production-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try permissions(of: root)
        XCTAssertThrowsError(try CapabilityHistoryStore.production(
            url: root.appendingPathComponent("history.json"),
            lockTimeout: 0
        ))
        XCTAssertEqual(try permissions(of: root), before)
        XCTAssertThrowsError(try CapabilityHistoryStore.faultInjecting(
            url: URL(fileURLWithPath: "/capability-history.json"),
            lockTimeout: 0,
            faultInjection: .none
        ))
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homeMode = try permissions(of: home)
        XCTAssertThrowsError(try CapabilityHistoryStore.faultInjecting(
            url: home.appendingPathComponent("history.json"),
            lockTimeout: 0,
            faultInjection: .none
        ))
        XCTAssertEqual(try permissions(of: home), homeMode)
    }

    func testFailureBeforeReplacementKeepsOldFileAndBaselineForRetry() async throws {
        let root = try temporaryRoot("old-file")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        do {
            let seed = try fileStore(at: historyURL)
            _ = try await commit(batch([observation()]), to: seed)
        }
        let oldData = try Data(contentsOf: historyURL)
        do {
            let failing = try CapabilityHistoryStore.faultInjecting(
                url: historyURL,
                lockTimeout: 0,
                faultInjection: .init { phase in
                    if phase == .beforeReplacement { throw SyntheticFailure.expected }
                }
            )
            do {
                _ = try await commit(batch([
                    observation(signature: "b", at: base.addingTimeInterval(1))
                ], at: base.addingTimeInterval(1)), to: failing)
                XCTFail("write unexpectedly succeeded")
            } catch CapabilityHistoryStore.StoreError.injectedFailure(.beforeReplacement) {
                // Expected.
            }
            XCTAssertEqual(try Data(contentsOf: historyURL), oldData)
        }

        let retry = try fileStore(at: historyURL)
        let result = try await commit(batch([
            observation(signature: "b", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)), to: retry)
        XCTAssertEqual(result.newEvents.map(\.kind), [.modified])
    }

    func testSimulatedCrashAfterTemporaryWriteLeavesAuthoritativeOldFileReadable() async throws {
        let root = try temporaryRoot("temp-crash")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        do {
            let seed = try fileStore(at: historyURL)
            _ = try await commit(batch([observation()]), to: seed)
        }
        let oldData = try Data(contentsOf: historyURL)
        let failing = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .afterTemporaryWrite { throw SyntheticFailure.expected }
            }
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await self.commit(self.batch([
                self.observation(signature: "b", at: self.base.addingTimeInterval(1))
            ], at: self.base.addingTimeInterval(1)), to: failing)
        }
        XCTAssertEqual(try Data(contentsOf: historyURL), oldData)
        let page = try await failing.page(.init(limit: 20))
        XCTAssertTrue(page.events.isEmpty)
    }

    func testSimulatedCrashAfterReplacementLeavesCompleteNewFile() async throws {
        let root = try temporaryRoot("post-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        do {
            let seed = try fileStore(at: historyURL)
            _ = try await commit(batch([observation()]), to: seed)
        }
        let failing = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .afterReplacement { throw SyntheticFailure.expected }
            }
        )
        do {
            _ = try await commit(batch([
                observation(signature: "b", at: base.addingTimeInterval(1))
            ], at: base.addingTimeInterval(1)), to: failing)
            XCTFail("simulated post-replacement crash did not surface")
        } catch CapabilityHistoryStore.StoreError.injectedFailure(.afterReplacement) {
            // Expected; the complete new file is authoritative.
        }
        let page = try await failing.page(.init(limit: 20))
        XCTAssertEqual(page.events.map(\.kind), [.modified])
    }

    func testSecondStoreIsReadOnlyWhileProcessLifetimeLeaseIsHeld() async throws {
        let root = try temporaryRoot("lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        let writer = try fileStore(at: historyURL)
        _ = try await commit(batch([observation()]), to: writer)

        let reader = try fileStore(at: historyURL)
        XCTAssertEqual(reader.accessMode, .readOnly)
        let status = await reader.status()
        XCTAssertTrue(status.issueCodes.contains(.readOnlyLockConflict))
        _ = try await reader.page(.init(limit: 20))
        do {
            _ = try await reader.issueWritePermit()
            XCTFail("read-only store issued a write permit")
        } catch CapabilityHistoryStore.StoreError.readOnly {
            // Expected.
        }
    }

    func testLeaseConflictIsObservedAcrossProcesses() throws {
        let root = try temporaryRoot("cross-process-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(".capability-history.lock").path
        let readyPath = root.appendingPathComponent("ready").path
        let releasePath = root.appendingPathComponent("release").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            lock_path, ready_path, release_path = sys.argv[1:4]
            with open(lock_path, "a+") as lock_file:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                with open(ready_path, "wb") as ready_file:
                    ready_file.write(b"1")
                deadline = time.monotonic() + 10.0
                while not os.path.exists(release_path) and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not os.path.exists(release_path):
                    sys.exit(3)
            """,
            lockPath,
            readyPath,
            releasePath,
        ]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline && !FileManager.default.fileExists(atPath: readyPath) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyPath))

        let contender = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0.05,
            faultInjection: .none
        )
        XCTAssertEqual(contender.accessMode, .readOnly)
        XCTAssertTrue(FileManager.default.createFile(atPath: releasePath, contents: Data("1".utf8)))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testCorruptAndUnknownFilesFailClosedUntilExplicitClear() async throws {
        for (label, bytes, expectedIssue) in [
            ("corrupt", Data("not-json".utf8), CapabilityHistoryIssueCode.corruptStorage),
            ("unknown", Data("{\"schemaVersion\":9}".utf8), CapabilityHistoryIssueCode.unsupportedSchema),
        ] {
            let root = try temporaryRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let historyURL = url(in: root)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: historyURL)
            let store = try fileStore(at: historyURL)
            let before = try Data(contentsOf: historyURL)
            let status = await store.status()
            XCTAssertTrue(status.issueCodes.contains(expectedIssue))
            do {
                _ = try await store.issueWritePermit()
                XCTFail("invalid history issued a permit")
            } catch {
                XCTAssertEqual(try Data(contentsOf: historyURL), before)
            }
            let cleared = try await store.clearConfirmed(true)
            XCTAssertEqual(cleared.eventCount, 0)
            XCTAssertNotEqual(try Data(contentsOf: historyURL), before)
        }
    }

    func testDuplicateBaselineDocumentArrayFailsClosedAndPreservesFile() async throws {
        let root = try temporaryRoot("duplicate-documents")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        do {
            let seed = try fileStore(at: historyURL)
            _ = try await commit(batch([observation()]), to: seed)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])
        var baselines = try XCTUnwrap(object["baselines"] as? [[String: Any]])
        baselines[0]["documents"] = ["skillManifest", "skillManifest"]
        object["baselines"] = baselines
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try malformed.write(to: historyURL, options: .atomic)

        let reopened = try fileStore(at: historyURL)
        let status = await reopened.status()
        XCTAssertTrue(status.issueCodes.contains(.corruptStorage))
        await XCTAssertThrowsErrorAsync { _ = try await reopened.issueWritePermit() }
        XCTAssertEqual(try Data(contentsOf: historyURL), malformed)
    }

    func testClearRevokesOldPermitAndStartsFreshBaselineWithoutAddedEvents() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 10)
        _ = try await commit(batch([observation()]), to: store)
        let stale = try await store.issueWritePermit()
        let cleared = try await store.clearConfirmed(true)
        XCTAssertEqual(cleared.epoch, 11)

        do {
            _ = try await store.commit(batch([
                observation(signature: "b", at: base.addingTimeInterval(1))
            ], at: base.addingTimeInterval(1)), permit: stale)
            XCTFail("stale permit resurrected cleared history")
        } catch CapabilityHistoryStore.StoreError.stalePermit {
            // Expected.
        }
        let rebuilt = try await commit(batch([
            observation(signature: "b", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)), to: store)
        XCTAssertTrue(rebuilt.newEvents.isEmpty)
        let rebuiltStatus = await store.status()
        XCTAssertEqual(rebuiltStatus.baselineCount, 1)
    }

    func testClearAtMaximumEpochStartsAValidDistinctEpochAndRevision() async throws {
        let store = try CapabilityHistoryStore.memory(
            initialState: CapabilityHistoryStateV1(
                epoch: UInt64.max,
                revision: Int64.max - 1,
                nextSequence: 1
            )
        )
        let cleared = try await store.clearConfirmed(true)
        XCTAssertNotEqual(cleared.epoch, UInt64.max)
        XCTAssertEqual(cleared.revision, 1)
        _ = try await store.issueWritePermit()
    }

    func testHardBudgetNeverDropsCurrentBaselineToForceACommit() async throws {
        let root = try temporaryRoot("budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = url(in: root)
        let store = try fileStore(at: historyURL, maximumBytes: 1_200)
        _ = try await commit(batch([observation("skill:seed", name: "Seed")]), to: store)
        let old = try Data(contentsOf: historyURL)
        let many = (0..<20).map { index in
            observation("skill:new:\(index)", name: String(repeating: "N", count: 200) + "\(index)")
        }
        do {
            _ = try await commit(batch([observation("skill:seed", name: "Seed")] + many), to: store)
            XCTFail("oversized baseline unexpectedly replaced the old file")
        } catch CapabilityHistoryStore.StoreError.fileBudgetExceeded {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: historyURL), old)
        let budgetStatus = await store.status()
        XCTAssertEqual(budgetStatus.baselineCount, 1)
    }

    func testCancellationBeforeCommitPointLeavesStateUnchanged() async throws {
        let store = try CapabilityHistoryStore.memory()
        _ = try await commit(batch([observation()]), to: store)
        let prior = try await store.page(.init(limit: 20))
        let cancelledBatch = batch([
            observation(signature: "b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1))
        let task = Task {
            try Task.checkCancellation()
            let permit = try await store.issueWritePermit()
            return try await store.commit(cancelledBatch, permit: permit)
        }
        task.cancel()
        do { _ = try await task.value } catch is CancellationError { }
        let after = try await store.page(.init(limit: 20))
        XCTAssertEqual(after, prior)
    }

    func testScannedEmptyPartialAndPendingAbsenceRemainDistinctInStatus() async throws {
        let empty = try CapabilityHistoryStore.memory(initialEpoch: 101)
        _ = try await commit(batch([], coverage: .complete), to: empty)
        let emptyStatus = await empty.status()
        XCTAssertEqual(emptyStatus.isInitialized, true)
        XCTAssertEqual(emptyStatus.initializedScopeCount, 1)
        XCTAssertEqual(emptyStatus.baselineCount, 0)
        XCTAssertEqual(emptyStatus.latestScanCoverage, .complete)
        XCTAssertEqual(emptyStatus.pendingMissingCount, 0)

        let partial = try CapabilityHistoryStore.memory(initialEpoch: 102)
        _ = try await commit(batch([observation()], coverage: .partial), to: partial)
        let partialStatus = await partial.status()
        XCTAssertEqual(partialStatus.isInitialized, false)
        XCTAssertEqual(partialStatus.baselineCount, 1)
        XCTAssertEqual(partialStatus.latestScanCoverage, .partial)
        XCTAssertEqual(partialStatus.pendingMissingCount, 0)

        let pending = try CapabilityHistoryStore.memory(initialEpoch: 103)
        _ = try await commit(batch([observation()]), to: pending)
        _ = try await commit(batch([], at: base.addingTimeInterval(1)), to: pending)
        let pendingStatus = await pending.status()
        XCTAssertEqual(pendingStatus.isInitialized, true)
        XCTAssertEqual(pendingStatus.latestScanCoverage, .complete)
        XCTAssertEqual(pendingStatus.pendingMissingCount, 1)
        XCTAssertEqual(pendingStatus.eventCount, 0)
    }

    func testSymlinkDirectoryIsRejectedWithoutChangingExternalSentinel() throws {
        let root = try temporaryRoot("directory-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)
        let sentinel = external.appendingPathComponent("sentinel")
        let bytes = Data("external-sentinel".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("private", isDirectory: true),
            withDestinationURL: external
        )
        let beforeMode = try permissions(of: external)

        XCTAssertThrowsError(try fileStore(at: url(in: root)))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try permissions(of: external), beforeMode)
    }

    func testUnsafeLockEntriesAreRejectedWithoutTouchingSentinel() throws {
        for kind in UnsafeEntryKind.allCases {
            let root = try temporaryRoot("lock-\(kind.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = url(in: root).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sentinel = root.appendingPathComponent("sentinel")
            let bytes = Data("lock-sentinel".utf8)
            try bytes.write(to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sentinel.path)
            let beforeMode = try permissions(of: sentinel)
            try makeUnsafeEntry(kind, at: directory.appendingPathComponent(".capability-history.lock"), sentinel: sentinel)

            let clock = ContinuousClock()
            let started = clock.now
            XCTAssertThrowsError(try fileStore(at: url(in: root)))
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(try permissions(of: sentinel), beforeMode)
        }
    }

    func testUnsafeHistoryEntriesAreRejectedWithoutTouchingSentinel() throws {
        for kind in UnsafeEntryKind.allCases {
            let root = try temporaryRoot("history-\(kind.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let historyURL = url(in: root)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sentinel = root.appendingPathComponent("sentinel")
            let bytes = Data("history-sentinel".utf8)
            try bytes.write(to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sentinel.path)
            let beforeMode = try permissions(of: sentinel)
            try makeUnsafeEntry(kind, at: historyURL, sentinel: sentinel)

            let clock = ContinuousClock()
            let started = clock.now
            XCTAssertThrowsError(try fileStore(at: historyURL))
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(try permissions(of: sentinel), beforeMode)
        }
    }

    func testInjectedDiskFullAndPermissionFailuresKeepAuthoritativeFile() async throws {
        for (label, code, expected) in [
            ("disk-full", POSIXErrorCode.ENOSPC, CapabilityHistoryStore.StoreError.fileBudgetExceeded),
            ("permission", POSIXErrorCode.EACCES, CapabilityHistoryStore.StoreError.storageUnavailable),
        ] {
            let root = try temporaryRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let historyURL = url(in: root)
            do {
                let seed = try fileStore(at: historyURL)
                _ = try await commit(batch([observation()]), to: seed)
            }
            let old = try Data(contentsOf: historyURL)
            let store = try CapabilityHistoryStore.faultInjecting(
                url: historyURL,
                lockTimeout: 0,
                faultInjection: .init { phase in
                    if phase == .beforeTemporaryWrite { throw POSIXError(code) }
                }
            )
            do {
                _ = try await commit(batch([
                    observation(signature: "b", at: base.addingTimeInterval(1))
                ], at: base.addingTimeInterval(1)), to: store)
                XCTFail("injected failure unexpectedly committed")
            } catch let error as CapabilityHistoryStore.StoreError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(try Data(contentsOf: historyURL), old)
        }
    }

    func testEventBoundaryUsesCompleteSameResourceHistory() async throws {
        let store = try CapabilityHistoryStore.memory(initialEpoch: 104)
        _ = try await commit(batch([observation("skill:a"), observation("skill:b")]), to: store)
        _ = try await commit(batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(1)),
            observation("skill:b", at: base.addingTimeInterval(1)),
        ], at: base.addingTimeInterval(1)), to: store)
        _ = try await commit(batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(2)),
            observation("skill:b", signature: "b", at: base.addingTimeInterval(2)),
        ], at: base.addingTimeInterval(2)), to: store)
        _ = try await commit(batch([
            observation("skill:a", signature: "c", at: base.addingTimeInterval(3)),
            observation("skill:b", signature: "b", at: base.addingTimeInterval(3)),
        ], at: base.addingTimeInterval(3)), to: store)
        let page = try await store.page(.init(resourceID: "skill:a", limit: 20))
        let first = try XCTUnwrap(page.events.last)
        let boundary = try await store.eventBoundary(
            eventID: first.id,
            resourceID: first.resourceID,
            observedAt: first.observedAt
        )
        XCTAssertEqual(boundary?.nextObservedAt, base.addingTimeInterval(3))
        let forgedBoundary = try await store.eventBoundary(
            eventID: "history-999-1",
            resourceID: first.resourceID,
            observedAt: first.observedAt
        )
        XCTAssertNil(forgedBoundary)
    }

    private enum UnsafeEntryKind: String, CaseIterable {
        case symlink
        case hardlink
        case fifo
    }

    private func fileStore(
        at url: URL,
        maximumBytes: Int = CapabilityHistoryStore.defaultMaximumBytes
    ) throws -> CapabilityHistoryStore {
        try CapabilityHistoryStore.faultInjecting(
            url: url,
            maximumBytes: maximumBytes,
            lockTimeout: 0,
            faultInjection: .none
        )
    }

    private func makeUnsafeEntry(_ kind: UnsafeEntryKind, at url: URL, sentinel: URL) throws {
        switch kind {
        case .symlink:
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sentinel)
        case .hardlink:
            try FileManager.default.linkItem(at: sentinel, to: url)
        case .fifo:
            guard Darwin.mkfifo(url.path, mode_t(0o600)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }

    private enum SyntheticFailure: Error { case expected }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("expected async expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
