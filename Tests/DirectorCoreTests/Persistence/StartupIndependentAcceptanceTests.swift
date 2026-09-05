import XCTest
@testable import DirectorCore

/// Independent startup/cache contracts. These tests use only UUID-scoped
/// temporary stores and injected values; they never consult the user's
/// application-support database or preferences.
final class StartupIndependentAcceptanceTests: XCTestCase {

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-startup-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleResource(id: String = "agent:readonly") -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: "Independent test resource",
            kind: .agent,
            status: .idle,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: "test-root",
            relativeSourcePath: "agent.md",
            sourcePathHash: "test-hash",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            ownership: .userOwned,
            origin: .local
        )
    }

    private func sampleWindow() -> CapabilityQueryWindow {
        CapabilityQueryWindow(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_600),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func sampleSnapshot(identity: PresentationIdentity, generatedAt: Date) -> PresentationSnapshot {
        PresentationSnapshot(
            identity: identity,
            classificationRevision: "test-revision",
            window: sampleWindow(),
            generatedAt: generatedAt,
            quota: nil,
            home: nil
        )
    }

    func testReadOnlyStoreRejectsWritesAndRemainsUsable() async throws {
        let root = try temporaryRoot("readonly")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("derived.sqlite")

        let writable = try DatabaseStore(url: databaseURL)
        try await writable.insertResources([sampleResource()])
        let identity = try await writable.presentationIdentity()

        let readOnly = try DatabaseStore(url: databaseURL, readOnly: true)
        let readIdentity = try await readOnly.presentationIdentity()
        XCTAssertEqual(readIdentity, identity)

        do {
            try await readOnly.insertResources([sampleResource(id: "agent:should-not-write")])
            XCTFail("read-only store accepted a write")
        } catch {
            // SQLite must reject the mutation; the exact platform error is not
            // part of the contract.
        }

        let resourceCount = try await readOnly.count("resources")
        let resources = try await readOnly.fetchAllResources()
        XCTAssertEqual(resourceCount, 1)
        XCTAssertEqual(resources.count, 1)
    }

    func testCacheRejectsLateSameEpochGenerationAndPostDeleteWrites() async throws {
        let root = try temporaryRoot("cache-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let epoch = UUID().uuidString
        let generation1 = PresentationIdentity(databaseEpoch: epoch, dataGeneration: 1)
        let generation2 = PresentationIdentity(databaseEpoch: epoch, dataGeneration: 2)

        let permit1 = await cache.activate(identity: generation1)
        try await cache.write(
            sampleSnapshot(identity: generation1, generatedAt: Date(timeIntervalSince1970: 1_700_000_001)),
            permit: permit1
        )

        // A newer generation in the same epoch is valid after an explicit
        // activation, while the previous permit must be rejected.
        let permit2 = await cache.activate(identity: generation2)
        try await cache.write(
            sampleSnapshot(identity: generation2, generatedAt: Date(timeIntervalSince1970: 1_700_000_002)),
            permit: permit2
        )

        do {
            try await cache.write(
                sampleSnapshot(identity: generation1, generatedAt: Date(timeIntervalSince1970: 1_700_000_003)),
                permit: permit1
            )
            XCTFail("a late result from an older generation was accepted")
        } catch PresentationSnapshotStore.StoreError.staleIdentity {
            // Expected: activation revokes the previous permit.
        }

        let cached = try await cache.read()
        XCTAssertEqual(cached?.identity, generation2)

        await cache.invalidate()

        do {
            try await cache.write(
                sampleSnapshot(identity: generation2, generatedAt: Date(timeIntervalSince1970: 1_700_000_004)),
                permit: permit2
            )
            XCTFail("a permit from before invalidation was accepted")
        } catch PresentationSnapshotStore.StoreError.staleIdentity {
            // Expected: invalidate revokes all permits for this epoch.
        }

        let newEpoch = PresentationIdentity(databaseEpoch: UUID().uuidString, dataGeneration: 1)
        let newPermit = await cache.activate(identity: newEpoch)
        try await cache.write(sampleSnapshot(identity: newEpoch, generatedAt: Date(timeIntervalSince1970: 1_700_000_005)), permit: newPermit)
        let newCached = try await cache.read()
        XCTAssertEqual(newCached?.identity, newEpoch)
    }

    func testDerivedDeleteRotatesEpochAndResetsGenerationWithData() async throws {
        let root = try temporaryRoot("database-reset")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("reset.sqlite"))
        try await store.insertResources([sampleResource()])
        let before = try await store.presentationIdentity()
        let beforeResourceCount = try await store.count("resources")
        XCTAssertEqual(beforeResourceCount, 1)

        try await store.deleteAllData()

        let after = try await store.presentationIdentity()
        let resourceCount = try await store.count("resources")
        let callCount = try await store.count("calls")
        let quotaCount = try await store.count("quota_snapshots")
        XCTAssertNotEqual(after.databaseEpoch, before.databaseEpoch)
        XCTAssertEqual(after.dataGeneration, 0)
        XCTAssertEqual(resourceCount, 0)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(quotaCount, 0)
    }

    func testSuccessfulSourceIndexRollsBackBothMetadataWritesOnSecondWriteFailure() async throws {
        let root = try temporaryRoot("metadata-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("metadata.sqlite")
        let writer = try DatabaseStore(url: databaseURL)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_100)
        let newDate = Date(timeIntervalSince1970: 1_700_000_200)
        try await writer.markSuccessfulSourceIndex(at: oldDate)
        let beforeIdentity = try await writer.presentationIdentity()
        let beforeMetadata = try await writer.fetchPresentationIndexMetadata()

        let triggerConnection = try XCTUnwrap(SQLiteConnection(url: databaseURL))
        XCTAssertTrue(triggerConnection.exec("CREATE TRIGGER qa_fail_index_metadata BEFORE INSERT ON presentation_metadata WHEN NEW.key = 'last_index_completed_at' BEGIN SELECT RAISE(ABORT, 'qa metadata failure'); END"))

        do {
            try await writer.markSuccessfulSourceIndex(at: newDate)
            XCTFail("metadata transaction unexpectedly committed after its second write failed")
        } catch {
            // The trigger simulates a deterministic second-write failure.
        }

        let afterIdentity = try await writer.presentationIdentity()
        let afterMetadata = try await writer.fetchPresentationIndexMetadata()
        XCTAssertEqual(afterIdentity, beforeIdentity)
        XCTAssertEqual(afterMetadata, beforeMetadata)
        XCTAssertEqual(afterMetadata.lastSourceCheckAt, oldDate)
        XCTAssertEqual(afterMetadata.lastIndexCompletedAt, oldDate)
    }

    func testConcurrentInventoryReadersSeeOnlyCompleteCommittedSnapshots() async throws {
        let root = try temporaryRoot("inventory-atomicity")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("inventory.sqlite")
        let writer = try DatabaseStore(url: databaseURL)
        let reader = try DatabaseStore(url: databaseURL, readOnly: true)
        let oldResources = (0..<64).map { sampleResource(id: "agent:old-\($0)") }
        let newResources = (0..<1_024).map { sampleResource(id: "agent:new-\($0)") }
        try await writer.replaceResourceInventory(resources: oldResources)
        let oldDirectory = try await reader.fetchPresentationDirectory()
        let oldGeneration = oldDirectory.metadata.identity.dataGeneration

        let writerTask = Task {
            try await writer.replaceResourceInventory(resources: newResources)
        }
        let snapshots = try await withThrowingTaskGroup(of: PresentationDirectorySnapshot.self) { group in
            for _ in 0..<24 {
                group.addTask { try await reader.fetchPresentationDirectory() }
            }
            var results: [PresentationDirectorySnapshot] = []
            for try await directory in group { results.append(directory) }
            return results
        }
        try await writerTask.value
        let newDirectory = try await reader.fetchPresentationDirectory()
        let newGeneration = newDirectory.metadata.identity.dataGeneration

        let oldIDs = Set(oldResources.map(\.id))
        let newIDs = Set(newResources.map(\.id))
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        for directory in snapshots {
            let ids = Set(directory.resources.map(\.id))
            let generation = directory.metadata.identity.dataGeneration
            let isOld = ids == oldIDs && generation == oldGeneration
            let isNew = ids == newIDs && generation == newGeneration
            XCTAssertTrue(isOld || isNew, "reader observed a partially committed inventory or mismatched generation")
        }
        XCTAssertEqual(Set(newDirectory.resources.map(\.id)), newIDs)
        XCTAssertEqual(newDirectory.metadata.identity.dataGeneration, newGeneration)

        // A newly opened read-only store must be able to initialize its
        // metadata boundary without mutating or changing the committed view.
        let coldReader = try DatabaseStore(url: databaseURL, readOnly: true)
        let coldDirectory = try await coldReader.fetchPresentationDirectory()
        XCTAssertEqual(coldDirectory.metadata.identity, newDirectory.metadata.identity)
        XCTAssertEqual(Set(coldDirectory.resources.map(\.id)), newIDs)
    }

    func testCacheClassifiesOversizedCorruptFutureSchemaAndIdentityMismatch() async throws {
        let root = try temporaryRoot("cache-validation")
        defer { try? FileManager.default.removeItem(at: root) }

        let oversizedURL = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: 9).write(to: oversizedURL)
        let oversized = PresentationSnapshotStore(url: oversizedURL, maxBytes: 8)
        do {
            _ = try await oversized.read()
            XCTFail("oversized cache was accepted")
        } catch PresentationSnapshotStore.StoreError.oversized {
            // Expected classification before decoding.
        }

        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptURL)
        let corrupt = PresentationSnapshotStore(url: corruptURL)
        do {
            _ = try await corrupt.read()
            XCTFail("corrupt cache was accepted")
        } catch PresentationSnapshotStore.StoreError.corrupt {
            // Expected classification without exposing file contents.
        }

        let futureURL = root.appendingPathComponent("future.json")
        let identity = PresentationIdentity(databaseEpoch: UUID().uuidString, dataGeneration: 1)
        let future = sampleSnapshot(identity: identity, generatedAt: Date(timeIntervalSince1970: 1_700_000_010))
        let futureData = try JSONEncoder().encode(
            PresentationSnapshot(
                schemaVersion: PresentationSnapshot.currentSchemaVersion + 1,
                identity: future.identity,
                classificationRevision: future.classificationRevision,
                window: future.window,
                generatedAt: future.generatedAt
            )
        )
        try futureData.write(to: futureURL)
        let futureStore = PresentationSnapshotStore(url: futureURL)
        do {
            _ = try await futureStore.read()
            XCTFail("future schema cache was accepted")
        } catch PresentationSnapshotStore.StoreError.unsupportedVersion {
            // Expected forward-compatibility guard.
        }

        let identityURL = root.appendingPathComponent("identity.json")
        let identityStore = PresentationSnapshotStore(url: identityURL)
        try await identityStore.write(future, expectedIdentity: future.identity)
        let wrongIdentity = PresentationIdentity(databaseEpoch: UUID().uuidString, dataGeneration: 1)
        do {
            _ = try await identityStore.read(expectedIdentity: wrongIdentity)
            XCTFail("cache identity mismatch was accepted")
        } catch PresentationSnapshotStore.StoreError.staleIdentity {
            // Expected: stale cache cannot be treated as current data.
        }
    }

    func testCancelledSQLiteQueryInterruptsAndConnectionRemainsUsable() throws {
        let root = try temporaryRoot("sqlite-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("probe.sqlite")))
        XCTAssertTrue(connection.exec("CREATE TABLE probe (value INTEGER NOT NULL)"))

        let token = SQLiteCancellationToken(timeout: .milliseconds(25))
        do {
            try connection.perform(cancellation: token) {
                let statement = try connection.prepare(
                    "WITH RECURSIVE numbers(value) AS (SELECT 0 UNION ALL SELECT value + 1 FROM numbers WHERE value < 100000000) SELECT sum(value) FROM numbers"
                )
                while try statement.step() == .row {}
            }
            XCTFail("bounded recursive query was not interrupted")
        } catch SQLiteError.cancelled {
            // Expected interrupt from the connection progress handler.
        }

        let check = try connection.prepare("SELECT 1")
        guard case .row = try check.step() else {
            XCTFail("connection did not execute a query after cancellation")
            return
        }
        XCTAssertEqual(check.columnInt(0), 1)
    }

    func testInFlightSQLiteTaskCancellationInterruptsAndConnectionRecovers() async throws {
        let root = try temporaryRoot("sqlite-in-flight-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("probe.sqlite")))
        XCTAssertTrue(connection.exec("CREATE TABLE probe (value INTEGER NOT NULL)"))
        let token = SQLiteCancellationToken(timeout: .seconds(30))
        let entered = DispatchSemaphore(value: 0)

        let task = Task.detached { () throws -> Void in
            try connection.perform(cancellation: token) {
                entered.signal()
                let statement = try connection.prepare(
                    "WITH RECURSIVE numbers(value) AS (SELECT 0 UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000000000) SELECT sum(value) FROM numbers"
                )
                while try statement.step() == .row {}
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success, "query did not enter before cancellation")
        token.cancel()
        do {
            try await task.value
            XCTFail("in-flight query ignored cancellation")
        } catch SQLiteError.cancelled {
            // Expected callback-driven interruption after the query began.
        }

        let check = try connection.prepare("SELECT 1")
        guard case .row = try check.step() else {
            XCTFail("connection did not recover after in-flight cancellation")
            return
        }
        XCTAssertEqual(check.columnInt(0), 1)
    }

    func testSwiftTaskCancellationInterruptsProductionSQLiteQuery() async throws {
        let root = try temporaryRoot("sqlite-production-task-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("probe.sqlite")))
        let entered = DispatchSemaphore(value: 0)
        let task = Task.detached { () throws -> Bool in
            do {
                try connection.perform(cancellation: nil) {
                    let statement = try connection.prepare(
                        "WITH RECURSIVE numbers(value) AS (SELECT 0 UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000000000) SELECT value FROM numbers"
                    )
                    var rows = 0
                    while try statement.step() == .row {
                        rows += 1
                        if rows == 100 { entered.signal() }
                    }
                }
                return false
            } catch SQLiteError.cancelled {
                return true
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success, "query did not stream before Task.cancel()")
        let cancelStart = ContinuousClock.now
        task.cancel()
        let cancelled = try await task.value
        let completionDuration = cancelStart.duration(to: ContinuousClock.now)
        let completionSeconds = Double(completionDuration.components.seconds) + Double(completionDuration.components.attoseconds) / 1_000_000_000_000_000_000
        XCTAssertTrue(cancelled, "production Task.isCancelled was not observed by SQLite progress handler")
        XCTAssertLessThan(completionSeconds, 1.0)

        let check = try connection.prepare("SELECT 1")
        guard case .row = try check.step() else {
            XCTFail("connection did not recover after production Task.cancel()")
            return
        }
        XCTAssertEqual(check.columnInt(0), 1)
    }

    func testReadOnlyNestedReadPreservesOuterDeadlineAndRollsBack() throws {
        let root = try temporaryRoot("sqlite-read-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("probe.sqlite")
        let writable = try XCTUnwrap(SQLiteConnection(url: databaseURL))
        XCTAssertTrue(writable.exec("CREATE TABLE probe (value INTEGER NOT NULL)"))
        let readOnly = try XCTUnwrap(SQLiteConnection(url: databaseURL, readOnly: true))
        let outer = SQLiteCancellationToken(timeout: .milliseconds(25))

        do {
            try readOnly.performReadSnapshot(cancellation: outer) {
                let inner = SQLiteCancellationToken(timeout: .seconds(10))
                try readOnly.perform(cancellation: inner) {
                    let statement = try readOnly.prepare("SELECT 1")
                    _ = try statement.step()
                }
                let statement = try readOnly.prepare(
                    "WITH RECURSIVE numbers(value) AS (SELECT 0 UNION ALL SELECT value + 1 FROM numbers WHERE value < 100000000) SELECT sum(value) FROM numbers"
                )
                while try statement.step() == .row {}
            }
            XCTFail("outer deadline was not enforced through nested read")
        } catch SQLiteError.cancelled {
            // Expected: nested short work cannot replace the outer token.
        }

        let check = try readOnly.prepare("SELECT 1")
        guard case .row = try check.step() else {
            XCTFail("read-only connection did not recover after rollback")
            return
        }
        XCTAssertEqual(check.columnInt(0), 1)
    }

    func testDefaultSQLiteDeadlineInterruptsAndConnectionRemainsUsable() throws {
        let root = try temporaryRoot("sqlite-default-deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("probe.sqlite")))
        let start = ContinuousClock.now
        do {
            try connection.perform(cancellation: nil) {
                let statement = try connection.prepare(
                    "WITH RECURSIVE numbers(value) AS (SELECT 0 UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000000000) SELECT sum(value) FROM numbers"
                )
                while try statement.step() == .row {}
            }
            XCTFail("default deadline query completed without interruption")
        } catch SQLiteError.cancelled {
            // The nil cancellation argument must still install the default
            // five-second deadline token safely.
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        XCTAssertGreaterThanOrEqual(elapsedSeconds, 4.0)
        XCTAssertLessThan(elapsedSeconds, 7.0)

        let check = try connection.prepare("SELECT 1")
        guard case .row = try check.step() else {
            XCTFail("connection did not recover after default deadline")
            return
        }
        XCTAssertEqual(check.columnInt(0), 1)
    }

    func testQuotaOverviewKeepsSourceIdentityAndClosedSevenDayWindow() async throws {
        let root = try temporaryRoot("quota-contract")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("quota.sqlite"))
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceSession = TaskSummary(
            id: "quota-contract-session",
            projectID: nil,
            startedAt: day,
            endedAt: day,
            status: .completed,
            coverage: .complete,
            parserVersion: "test",
            sourceFileID: "quota-contract-source",
            title: nil
        )
        func quota(_ id: String, _ capturedAt: Date, _ reset: Date?, _ limitID: String?, _ name: String, _ windowMinutes: Int = 10_080) throws -> QuotaSnapshot {
            try QuotaSnapshot(
                id: id,
                capturedAt: capturedAt,
                windowMinutes: windowMinutes,
                usedPercent: 42,
                resetsAt: reset,
                limitID: limitID,
                limitName: name,
                confidence: .exact
            )
        }
        let windowStart = day
        let windowEnd = day.addingTimeInterval(6 * 86_400 + 3_600)
        let snapshots = try [
            // Empty IDs use the stable source name rather than an empty id:.
            quota("empty-name", day.addingTimeInterval(3_600), day.addingTimeInterval(86_400), "", "Alpha"),
            // A short window must not enter the weekly overview.
            quota("short-window", day.addingTimeInterval(7_200), day.addingTimeInterval(300), "short", "Short", 300),
            // Same limit ID with a later renamed display source remains one source.
            quota("rename-old", day.addingTimeInterval(-3_600), day.addingTimeInterval(86_400), "renamed", "Old name"),
            quota("rename-new", day.addingTimeInterval(10_800), day.addingTimeInterval(86_400), "renamed", "New name"),
            // A -> nil -> B is an unknown gap, not proof of a reset transition.
            quota("gap-a", day.addingTimeInterval(14_400), day.addingTimeInterval(20_000), "gap", "Gap", 10_080),
            quota("gap-nil", day.addingTimeInterval(14_500), nil, "gap", "Gap", 10_080),
            quota("gap-b", day.addingTimeInterval(14_600), day.addingTimeInterval(30_000), "gap", "Gap", 10_080),
            // Prior-day A -> first observation today B is a real boundary change.
            quota("boundary-a", day.addingTimeInterval(-7_200), day.addingTimeInterval(40_000), "boundary", "Boundary"),
            quota("boundary-b", day.addingTimeInterval(18_000), day.addingTimeInterval(50_000), "boundary", "Boundary"),
            // Future observations must not become current or daily data.
            quota("future", windowEnd.addingTimeInterval(86_400), windowEnd.addingTimeInterval(172_800), "future", "Future")
        ]
        try await store.replaceSession(PersistedSessionBatch(session: sourceSession, calls: [], tokenSnapshots: [], quotaSnapshots: snapshots, findings: []))

        let window = CapabilityQueryWindow(start: windowStart, end: windowEnd, timeZone: TimeZone(secondsFromGMT: 0)!)
        let overview = try await store.fetchQuotaOverview(window: window)
        XCTAssertEqual(overview.sources.count, 4)
        let alpha = try XCTUnwrap(overview.sources.first(where: { $0.id == "name:Alpha" }))
        XCTAssertEqual(alpha.daily.count, 7)
        XCTAssertEqual(alpha.daily.compactMap(\.observation).count, 1)
        XCTAssertNil(overview.sources.first(where: { $0.id == "id:short" }))
        let renamed = try XCTUnwrap(overview.sources.first(where: { $0.id == "id:renamed" }))
        XCTAssertEqual(renamed.name, "New name")
        XCTAssertEqual(renamed.current?.id, "rename-new")
        let gap = try XCTUnwrap(overview.sources.first(where: { $0.id == "id:gap" }))
        XCTAssertFalse(gap.daily.contains(where: \.cycleChanged))
        let boundary = try XCTUnwrap(overview.sources.first(where: { $0.id == "id:boundary" }))
        XCTAssertTrue(boundary.daily.contains(where: \.cycleChanged))
        // A source observed only after the closed window is not a seven-day
        // source with synthetic empty observations; it is excluded entirely.
        XCTAssertNil(overview.sources.first(where: { $0.id == "id:future" }))
    }
}
