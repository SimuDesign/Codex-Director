import XCTest
@testable import DirectorUI
import DirectorCore

/// Publication tests use only UUID-scoped temporary cache files and the
/// model's in-memory classification store. They do not touch preferences,
/// source files, or the application's real database.
@MainActor
final class PresentationPublicationTests: XCTestCase {
    private final class MemoryData: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func read() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ data: Data?) {
            lock.lock()
            value = data
            lock.unlock()
        }
    }

    private func preferenceStores() -> (ResourceClassificationOverrideStore, InvocationEvaluationStore) {
        let classifications = MemoryData()
        let evaluations = MemoryData()
        return (
            ResourceClassificationOverrideStore(
                readData: { classifications.read() },
                writeData: { classifications.write($0) },
                removeData: { classifications.write(nil) }
            ),
            InvocationEvaluationStore(
                readData: { evaluations.read() },
                writeData: { evaluations.write($0); return true },
                removeData: { evaluations.write(nil); return true }
            )
        )
    }

    private func makeSnapshot(identity: PresentationIdentity = .init(databaseEpoch: "publication-test", dataGeneration: 1)) -> PresentationSnapshot {
        PresentationSnapshot(
            identity: identity,
            classificationRevision: PresentationClassificationRevision.make([:]),
            window: CapabilityQueryWindow(
                start: Date(timeIntervalSince1970: 10),
                end: Date(timeIntervalSince1970: 20),
                timeZone: .gmt
            ),
            generatedAt: Date(timeIntervalSince1970: 15),
            statisticsThrough: Date(timeIntervalSince1970: 19),
            home: PresentationHomeSummary(
                customAgents: 1, customAgentsGlobal: 1, customAgentsProject: 0,
                customSkills: 1, customSkillsGlobal: 1, customSkillsProject: 0,
                installedSkills: 0, installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0, installedPlugins: 0, enabledPlugins: 0
            )
        )
    }

    private func cacheURL(in root: URL) -> URL {
        root.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("presentation.json")
    }

    func testDeleteRevokesPermitBeforeRemovingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PresentationSnapshotStore(url: cacheURL(in: root))
        let snapshot = makeSnapshot()
        let permit = await cache.activate(identity: snapshot.identity)
        try await cache.write(snapshot, permit: permit)

        try await cache.delete(expectedIdentity: snapshot.identity)
        let deleted = try await cache.read()
        XCTAssertNil(deleted)

        do {
            try await cache.write(snapshot, permit: permit)
            XCTFail("a permit issued before deletion unexpectedly wrote")
        } catch PresentationSnapshotStore.StoreError.staleIdentity {
            // Expected: delete advances the store revision before removing
            // the file, so late workers cannot resurrect the cache.
        }
    }

    func testDeleteDerivedDataRemovesCacheBeforeLateWriterAndKeepsClassificationStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let cache = PresentationSnapshotStore(url: cacheURL(in: root))
        let snapshot = makeSnapshot()
        let permit = await cache.activate(identity: snapshot.identity)
        try await cache.write(snapshot, permit: permit)

        let (classifications, evaluations) = preferenceStores()
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: classifications,
            evaluationStore: evaluations,
            previewMode: true,
            presentationSnapshotStore: cache
        )

        try await model.deleteDerivedData()
        let deleted = try await cache.read()
        XCTAssertNil(deleted)
        do {
            try await cache.write(snapshot, permit: permit)
            XCTFail("late cache writer unexpectedly resurrected deleted data")
        } catch PresentationSnapshotStore.StoreError.staleIdentity {
            // Expected.
        }
        XCTAssertTrue(classifications.all().isEmpty)
    }

    func testClassificationInvalidatesPresentationButDoesNotEraseMemoryCorrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-classification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let skill = CapabilityResource(
            id: "skill:publication-local",
            name: "Publication Local Skill",
            kind: .skill,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Synthetic local skill",
            sourceRootID: "publication-test",
            relativeSourcePath: "skill/SKILL.md",
            sourcePathHash: nil,
            lastSeenAt: now,
            ownership: .userOwned,
            origin: .local
        )
        try await database.insertResources([skill])
        let cache = PresentationSnapshotStore(url: cacheURL(in: root))
        let (classifications, evaluations) = preferenceStores()
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: classifications,
            evaluationStore: evaluations,
            nowProvider: { now },
            previewMode: false,
            presentationSnapshotStore: cache
        )
        try await model.refresh()

        model.classify(resourceID: skill.id, ownership: .installed)
        XCTAssertEqual(model.classificationOverrides.all()[skill.id]?.ownership, .installed)
        let restored = await model.restoreCachedPresentation()
        XCTAssertFalse(restored)
        XCTAssertEqual(model.cacheStatus, .stale)
        let retained = try await cache.read()
        XCTAssertNotNil(retained)
    }

    func testClassificationDuringProjectionRejectsLateResultAndKeepsOverride() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-classification-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let (classifications, evaluations) = preferenceStores()
        let resource = CapabilityResource(
            id: "skill:publication-race",
            name: "Publication Race Skill",
            kind: .skill,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Synthetic classification race skill",
            sourceRootID: "publication-test",
            relativeSourcePath: "skill/SKILL.md",
            sourcePathHash: nil,
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            ownership: .userOwned,
            origin: .local
        )
        try await database.insertResources([resource])
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: classifications,
            evaluationStore: evaluations,
            previewMode: false
        )
        try await model.refresh()
        XCTAssertEqual(model.presentationHomeSummary?.customSkills, 1)
        XCTAssertEqual(model.presentationHomeSummary?.installedSkills, 0)

        let gate = Gate()
        defer { Task { await gate.release() } }
        model.presentationProjectionTestHook = { await gate.wait() }

        let refresh = Task { try? await model.refresh() }
        guard await gate.waitUntilEntered() else {
            await gate.release()
            _ = await refresh.value
            XCTFail("projection did not reach its publication gate")
            return
        }
        model.classify(resourceID: resource.id, ownership: .installed)
        await gate.release()
        _ = await refresh.value

        XCTAssertEqual(model.classificationOverrides.all()[resource.id]?.ownership, .installed)
        XCTAssertEqual(model.capabilities.allRows.first?.resource.ownership, .installed)
        XCTAssertEqual(model.libraryModels.first(where: { $0.category == .installedSkills })?.categoryCount, 1)
        XCTAssertEqual(model.presentationHomeSummary?.customSkills, 0)
        XCTAssertEqual(model.presentationHomeSummary?.installedSkills, 1)
    }

    func testDeleteRejectsLateSuccessfulProjectionAndLeavesNoCacheOrHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let (classifications, evaluations) = preferenceStores()
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let model = DirectorAppModel(store: database, classificationOverrides: classifications, evaluationStore: evaluations, previewMode: false, presentationSnapshotStore: cache)
        let gate = Gate()
        defer { Task { await gate.release() } }
        model.presentationProjectionTestHook = { await gate.wait() }

        let refresh = Task { try? await model.refresh() }
        guard await gate.waitUntilEntered() else {
            await gate.release()
            _ = await refresh.value
            XCTFail("projection did not reach its publication gate")
            return
        }
        try await model.deleteDerivedData()
        await gate.release()
        _ = await refresh.value

        XCTAssertNil(model.quotaOverviewSnapshot)
        XCTAssertNil(model.presentationHomeSummary)
        let cached = try await cache.read()
        XCTAssertNil(cached)
        XCTAssertEqual(model.presentationState, .initial)
    }

    func testDeleteRejectsLateProjectionErrorWithoutOverwritingDeletionState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let (classifications, evaluations) = preferenceStores()
        let model = DirectorAppModel(store: database, classificationOverrides: classifications, evaluationStore: evaluations, previewMode: false)
        let gate = Gate()
        defer { Task { await gate.release() } }
        model.presentationProjectionTestHook = {
            await gate.wait()
            throw ProbeError.failed
        }

        let refresh = Task { try? await model.refresh() }
        guard await gate.waitUntilEntered() else {
            await gate.release()
            _ = await refresh.value
            XCTFail("projection did not reach its publication gate")
            return
        }
        try await model.deleteDerivedData()
        await gate.release()
        _ = await refresh.value

        XCTAssertEqual(model.presentationState, .initial)
        XCTAssertNil(model.quotaOverviewSnapshot)
        XCTAssertNil(model.presentationHomeSummary)
    }

    func testDatabaseDeleteFailureLeavesRevokedCacheAndFailureState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-delete-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        let writable = try DatabaseStore(url: databaseURL)
        let cache = PresentationSnapshotStore(url: root.appendingPathComponent("presentation.json"))
        let snapshot = makeSnapshot()
        let permit = await cache.activate(identity: snapshot.identity)
        try await cache.write(snapshot, permit: permit)
        let (classifications, evaluations) = preferenceStores()
        // A read-only derived store makes the DB phase deterministically fail
        // after cache revocation/removal, without touching real application data.
        let readOnly = try DatabaseStore(url: databaseURL, readOnly: true)
        _ = writable
        let model = DirectorAppModel(
            store: readOnly,
            classificationOverrides: classifications,
            evaluationStore: evaluations,
            previewMode: false,
            presentationSnapshotStore: cache
        )

        do {
            try await model.deleteDerivedData()
            XCTFail("read-only derived store unexpectedly deleted successfully")
        } catch {
            // Expected: the cache was already revoked and removed.
        }
        let deleted = try await cache.read()
        XCTAssertNil(deleted)
        XCTAssertEqual(model.cacheStatus, .stale)
        XCTAssertEqual(model.presentationState, .failure("derived_data_delete_failed"))
        XCTAssertNotNil(model.indexingError)
    }

    func testCacheRemovalFailureClearsCachedProjectionWithoutDeletingDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-publication-cache-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"))
        let blockedCacheURL = root.appendingPathComponent("cache-node")
        let cache = PresentationSnapshotStore(url: blockedCacheURL)
        let (classifications, evaluations) = preferenceStores()
        let model = DirectorAppModel(
            store: database,
            classificationOverrides: classifications,
            evaluationStore: evaluations,
            previewMode: false,
            presentationSnapshotStore: cache
        )

        let identity = try await database.presentationIdentity()
        let snapshot = makeSnapshot(identity: identity)
        let permit = await cache.activate(identity: identity)
        try await cache.write(snapshot, permit: permit)
        let restored = await model.restoreCachedPresentation()
        XCTAssertTrue(restored)
        XCTAssertNotNil(model.presentationHomeSummary)

        try FileManager.default.removeItem(at: blockedCacheURL)
        try FileManager.default.createDirectory(at: blockedCacheURL, withIntermediateDirectories: true)
        try Data("keep this directory non-empty".utf8).write(to: blockedCacheURL.appendingPathComponent("blocker"))
        let identityBefore = try await database.presentationIdentity()
        do {
            try await model.deleteDerivedData()
            XCTFail("directory cache node unexpectedly removed")
        } catch {
            // Expected: a cache node must be a regular file; the DB phase must
            // not begin after the permit has been revoked.
        }

        XCTAssertNil(model.quotaOverviewSnapshot)
        XCTAssertNil(model.presentationHomeSummary)
        XCTAssertFalse(model.directoryLoaded)
        XCTAssertFalse(model.hasComputedStatistics)
        XCTAssertEqual(model.presentationState, .failure("presentation_cache_delete_failed"))
        XCTAssertEqual(model.cacheStatus, .unavailable)
        let identityAfter = try await database.presentationIdentity()
        XCTAssertEqual(identityAfter, identityBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedCacheURL.appendingPathComponent("blocker").path))
    }

    private enum ProbeError: Error { case failed }

    private actor Gate {
        private var entered = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !entered {
                guard clock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return true
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
