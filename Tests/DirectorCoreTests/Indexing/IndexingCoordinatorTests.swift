import CryptoKit
import XCTest
@testable import DirectorCore

final class IndexingCoordinatorTests: XCTestCase {

    private func tempDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-index-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore() throws -> DatabaseStore {
        let directory = try tempDirectory("db")
        return try DatabaseStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    // MARK: - Synthetic session lines

    private func metaLine(id: String) -> String {
        #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"\#(id)","session_id":"\#(id)","cli_version":"0.148.0-alpha.9"}}"#
    }

    private func callLine(callID: String, name: String) -> String {
        #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"\#(callID)-item","call_id":"\#(callID)","name":"\#(name)"}}"#
    }

    private func callLine(itemID: String, callID: String, name: String) -> String {
        #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"\#(itemID)","call_id":"\#(callID)","name":"\#(name)"}}"#
    }

    private func outputLine(callID: String) -> String {
        #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"custom_tool_call_output","id":"\#(callID)-out","call_id":"\#(callID)","output":[{"type":"text","text":"ok"}]}}"#
    }

    private func mcpItemCompletedLine(callID: String, status: String = "failed") -> String {
        #"{"type":"event_msg","timestamp":"2026-08-15T04:12:06.000Z","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"\#(callID)","status":"\#(status)","duration":{"secs":1,"nanos":0},"error":{"message":"synthetic"}}}}"#
    }

    private func agentReadLine(callID: String) -> String {
        #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"\#(callID)-item","call_id":"\#(callID)","name":"read","input":"cat sample-agent/agent.md"}}"#
    }

    private func startedLine() -> String {
        #"{"type":"event_msg","timestamp":"2026-08-15T04:12:05.000Z","payload":{"type":"task_started","turn_id":"t1"}}"#
    }

    private func completeLine() -> String {
        #"{"type":"event_msg","timestamp":"2026-08-15T04:12:08.000Z","payload":{"type":"task_complete","turn_id":"t1"}}"#
    }

    private func turnContextLine(model: String) -> String {
        #"{"type":"turn_context","timestamp":"2026-08-15T04:12:04.000Z","payload":{"turn_id":"t1","model":"\#(model)"}}"#
    }

    private func tokenCountLine(total: Int, timestamp: String = "2026-08-15T04:12:05.000Z") -> String {
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#
    }

    private func tokenUsageRecordLine(total: Int, timestamp: String = "2026-08-15T04:12:06.000Z") -> String {
        #"{"type":"token_usage_record","timestamp":"\#(timestamp)","payload":{"usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"thread_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":\#(total)}}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        try data.write(to: url)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        try handle.close()
    }

    private func makeCoordinator(store: DatabaseStore, now: Date? = nil) -> IndexingCoordinator {
        if let now { return IndexingCoordinator(store: store, now: { now }) }
        return IndexingCoordinator(store: store)
    }

    private func configuration(
        activeRoots: [URL], archivedRoot: URL? = nil
    ) -> IndexingCoordinator.Configuration {
        IndexingCoordinator.Configuration(
            scanRoots: [],
            activeSessionRoots: activeRoots,
            archivedSessionRoot: archivedRoot
        )
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [IndexingProgress] = []
        func append(_ event: IndexingProgress) { lock.lock(); events.append(event); lock.unlock() }
        var snapshot: [IndexingProgress] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private final class ProjectDirectoryBlocker: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var enabled = false
        private var didBlock = false
        private var starts = 0

        func enable() {
            lock.lock()
            enabled = true
            didBlock = false
            lock.unlock()
        }

        func blockIfEnabled() {
            lock.lock()
            guard enabled, !didBlock else {
                lock.unlock()
                return
            }
            didBlock = true
            starts += 1
            lock.unlock()
            releaseSemaphore.wait()
        }

        func release() { releaseSemaphore.signal() }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }
    }

    private final class CompanionReadBlocker: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var enabled = false
        private var targetReadCount = 0
        private var didBlock = false
        private var starts = 0

        func enableForNextCompanionPass() {
            lock.lock()
            enabled = true
            targetReadCount = 0
            didBlock = false
            lock.unlock()
        }

        func blockOnSecondTargetRead() {
            lock.lock()
            guard enabled else {
                lock.unlock()
                return
            }
            targetReadCount += 1
            let shouldBlock = targetReadCount == 2 && !didBlock
            if shouldBlock {
                didBlock = true
                starts += 1
            }
            lock.unlock()
            if shouldBlock { releaseSemaphore.wait() }
        }

        func release() { releaseSemaphore.signal() }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }
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

    // MARK: - Tests

    func testFirstIndex() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1"), startedLine(), completeLine()],
            to: active.appendingPathComponent("session-a.jsonl")
        )
        let result = try await makeCoordinator(store: store).run(
            configuration: configuration(activeRoots: [active])
        )
        XCTAssertEqual(result.processedFiles, 1)
        XCTAssertEqual(result.indexedSessions, 1)
        XCTAssertFalse(result.cancelled)
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 1)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 1)
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.id, "session:coord-1")
        XCTAssertEqual(session?.status, .completed)
    }

    func testIncompleteCapabilityDirectoryRetainsPreviousInventory() async throws {
        let store = try makeStore()
        let source = try tempDirectory("capability-root")
        let skill = source.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: kept\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "global-skills", url: source, scope: .global, kind: .skills)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [root], activeSessionRoots: [], archivedSessionRoot: nil)
        _ = try await makeCoordinator(store: store).run(configuration: config)
        let prior = try await store.fetchAllResources()
        XCTAssertEqual(prior.filter { $0.kind == .skill }.count, 1)

        let base = FileSystemClient()
        let failing = FileSystemClient(
            directoryReader: { url in
                if url.standardizedFileURL == source.standardizedFileURL {
                    return .failure(.permissionDenied)
                }
                return base.enumerateDirectory(url)
            },
            dataReader: { url in base.readData(url) },
            attributesReader: { url in base.fileAttributes(url) },
            readableReader: { url in base.isReadable(url) },
            symbolicLinkReader: { url in base.isSymbolicLink(url) }
        )

        let result = try await IndexingCoordinator(store: store, fileSystem: failing)
            .run(configuration: config)
        let after = try await store.fetchAllResources()

        XCTAssertEqual(result.resourceCoverage, .unavailable)
        XCTAssertEqual(after.map(\.id), prior.map(\.id))
    }

    func testPartialCapabilityScopeUpdatesReliablePositiveAndRetainsAbsentRowsEvidenceAndRelation() async throws {
        let store = try makeStore()
        let source = try tempDirectory("partial-capability-root")
        let keptDirectory = source.appendingPathComponent("kept", isDirectory: true)
        let updatedDirectory = source.appendingPathComponent("updated", isDirectory: true)
        try FileManager.default.createDirectory(at: keptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updatedDirectory, withIntermediateDirectories: true)
        let keptManifest = keptDirectory.appendingPathComponent("SKILL.md")
        let updatedManifest = updatedDirectory.appendingPathComponent("SKILL.md")
        try "---\nname: kept\n---\nfirst\n".write(to: keptManifest, atomically: true, encoding: .utf8)
        try "---\nname: updated\n---\nfirst\n".write(to: updatedManifest, atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "partial-skills", url: source, scope: .global, kind: .skills)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [root], activeSessionRoots: [], archivedSessionRoot: nil)
        _ = try await makeCoordinator(store: store).run(configuration: config)
        let beforeResources = try await store.fetchAllResources()
        let beforeProvenance = try await store.fetchAllProvenance()
        let kept = try XCTUnwrap(beforeResources.first { $0.name == "kept" })
        let updated = try XCTUnwrap(beforeResources.first { $0.name == "updated" })
        let relation = ResourceRelation(
            sourceResourceID: kept.id,
            targetResourceID: updated.id,
            relationKind: "synthetic-companion",
            confidence: .exact,
            evidenceSummary: "Synthetic fixture"
        )
        try await store.replaceResourceInventory(
            resources: beforeResources,
            provenance: beforeProvenance,
            relations: [relation]
        )
        try "---\nname: updated\n---\nsecond\n".write(to: updatedManifest, atomically: true, encoding: .utf8)

        let base = FileSystemClient()
        let partial = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { url in
                url.standardizedFileURL == keptManifest.standardizedFileURL
                    ? .failure(.permissionDenied)
                    : base.readData(url)
            },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )

        let result = try await IndexingCoordinator(store: store, fileSystem: partial)
            .run(configuration: config)
        let afterResources = try await store.fetchAllResources()
        let afterProvenance = try await store.fetchAllProvenance()
        let afterRelations = try await store.fetchAllRelations()

        XCTAssertEqual(result.resourceCoverage, .partial)
        XCTAssertEqual(afterResources.count, 2)
        XCTAssertEqual(afterResources.first { $0.id == kept.id }?.contentFingerprint, kept.contentFingerprint)
        XCTAssertNotEqual(afterResources.first { $0.id == updated.id }?.contentFingerprint, updated.contentFingerprint)
        XCTAssertEqual(Set(afterProvenance.map(\.id)), Set(beforeProvenance.map(\.id)))
        XCTAssertEqual(afterRelations, [relation])
        XCTAssertTrue(afterResources.allSatisfy { $0.sourceRootID == root.id })
    }

    func testOfflineProjectRetainsInventoryButPublishesCurrentUnavailableProjectRow() async throws {
        let store = try makeStore()
        let project = try tempDirectory("offline-project")
        let skill = project.appendingPathComponent(".agents/skills/project-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: project-skill\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "offline-project", url: project, scope: .project, kind: .projects)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [root], activeSessionRoots: [], archivedSessionRoot: nil)
        _ = try await makeCoordinator(store: store).run(configuration: config)
        let beforeResources = try await store.fetchAllResources()
        let beforeProjects = try await store.fetchAllProjects()
        XCTAssertEqual(beforeProjects.first?.available, true)

        try FileManager.default.removeItem(at: project)
        let result = try await makeCoordinator(store: store).run(configuration: config)
        let afterResources = try await store.fetchAllResources()
        let afterProjects = try await store.fetchAllProjects()

        XCTAssertEqual(result.resourceCoverage, .unavailable)
        XCTAssertEqual(afterResources.map(\.id), beforeResources.map(\.id))
        XCTAssertEqual(afterProjects.map(\.id), [root.id])
        XCTAssertEqual(afterProjects.first?.available, false)
    }

    func testLargeSessionIndexesToCompletion() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        var lines: [String] = [metaLine(id: "session:large")]
        for i in 0..<20_000 {
            lines.append(callLine(callID: "c\(i)", name: "read"))
            lines.append(outputLine(callID: "c\(i)"))
        }
        try write(lines, to: active.appendingPathComponent("session-large.jsonl"))

        let result = try await makeCoordinator(store: store).run(
            configuration: configuration(activeRoots: [active])
        )
        XCTAssertEqual(result.indexedSessions, 1)
        XCTAssertFalse(result.cancelled)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 20_000)
    }

    func testProgressReportsByteOffsetsDuringLargeFile() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        var lines: [String] = [metaLine(id: "session:progress")]
        // ~3.5 MB of events so the 1 MB threshold is crossed multiple times.
        for i in 0..<12_000 {
            lines.append(callLine(callID: "p\(i)", name: "read"))
            lines.append(outputLine(callID: "p\(i)"))
        }
        try write(lines, to: active.appendingPathComponent("session-progress.jsonl"))

        let box = ProgressBox()
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active])) { event in
            if event.phase == .parsing, event.currentFileBytesRead != nil { box.append(event) }
        }

        let byteEvents = box.snapshot
        XCTAssertFalse(byteEvents.isEmpty, "expected at least one byte-progress event")
        XCTAssertNotNil(byteEvents.last?.currentFileTotalBytes)
        XCTAssertGreaterThan(byteEvents.last?.currentFileBytesRead ?? 0, 0)
    }

    func testNoOpSecondIndex() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: active.appendingPathComponent("session-a.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        let first = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(first.indexedSessions, 1)

        let second = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(second.skippedFiles, 1)
        XCTAssertEqual(second.indexedSessions, 0)
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 1)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 1)
    }

    func testParserVersionMismatchReindexesUnchangedFile() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-stale.jsonl")
        try write([
            metaLine(id: "session:stale"),
            callLine(callID: "c1", name: "read"),
            outputLine(callID: "c1"),
        ], to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        try await store.upsertCheckpoint(IndexCheckpoint(
            sourceFileID: url.lastPathComponent,
            sourceSize: size,
            sourceMtime: mtime,
            byteOffset: size,
            parserVersion: "1.1.0",
            indexedAt: Date()
        ))

        let result = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(result.skippedFiles, 0)
        XCTAssertEqual(result.indexedSessions, 1)
        let checkpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(checkpoint?.parserVersion, RolloutEventDecoder.parserVersion)
    }

    func testParser140UpgradeReparsesRecentSessionDespiteOldFileMtimeExactlyOnce() async throws {
        let store = try makeStore()
        let active = try tempDirectory("observation-upgrade")
        let url = active.appendingPathComponent("recent-old-mtime.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T04:00:00Z"))
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        try write([metaLine(id: "session:recent-evidence").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-50 * 86_400)], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(IndexCheckpoint(sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset, parserVersion: "1.4.0", indexedAt: now))
        let repaired = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(repaired.indexedSessions, 1)
        let repairedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(repairedCheckpoint?.parserVersion, "1.4.2")
        let repeated = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(repeated.skippedFiles, 1)
    }

    func testParser140UpgradeDefersUnchangedSessionOlderThanThirtyLocalDays() async throws {
        let store = try makeStore()
        let active = try tempDirectory("observation-old-deferred")
        let url = active.appendingPathComponent("old-unchanged.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T04:00:00Z"))
        let oldDate = now.addingTimeInterval(-45 * 86_400)
        let stamp = ISO8601DateFormatter().string(from: oldDate)
        try write([metaLine(id: "session:old-deferred").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(.init(sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset, parserVersion: "1.4.0", indexedAt: now))

        let deferred = try await coordinator.run(configuration: configuration(activeRoots: [active]))

        XCTAssertEqual(deferred.skippedFiles, 1)
        XCTAssertEqual(deferred.indexedSessions, 0)
        let deferredCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(deferredCheckpoint?.parserVersion, "1.4.0")
    }

    func testChangedOldParser140SessionStillReparsesNormally() async throws {
        let store = try makeStore()
        let active = try tempDirectory("observation-old-changed")
        let url = active.appendingPathComponent("old-changed.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T04:00:00Z"))
        let oldDate = now.addingTimeInterval(-45 * 86_400)
        let stamp = ISO8601DateFormatter().string(from: oldDate)
        try write([metaLine(id: "session:old-changed").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(.init(sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset, parserVersion: "1.4.0", indexedAt: now))
        try append([callLine(callID: "changed", name: "read"), outputLine(callID: "changed")], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)

        let repaired = try await coordinator.run(configuration: configuration(activeRoots: [active]))

        XCTAssertEqual(repaired.indexedSessions, 1)
        let calls = try await store.fetchCalls(sessionID: "session:old-changed")
        let repairedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(repairedCheckpoint?.parserVersion, "1.4.2")
    }

    func testParser141UpgradeReparsesRecentSessionExactlyOnce() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-upgrade")
        let url = active.appendingPathComponent("recent-141.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T04:00:00Z"))
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        try write([metaLine(id: "session:recent-141").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(.init(
            sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset,
            parserVersion: "1.4.1", indexedAt: now
        ))

        let repaired = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let repeated = try await coordinator.run(configuration: configuration(activeRoots: [active]))

        XCTAssertEqual(repaired.indexedSessions, 1)
        XCTAssertEqual(repeated.skippedFiles, 1)
        let repairedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(repairedCheckpoint?.parserVersion, "1.4.2")
    }

    func testParser141UpgradeDefersUnchangedArchiveOutsideRecentWindow() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-deferred")
        let url = active.appendingPathComponent("old-141.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T04:00:00Z"))
        let oldDate = now.addingTimeInterval(-45 * 86_400)
        let stamp = ISO8601DateFormatter().string(from: oldDate)
        try write([metaLine(id: "session:old-141").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(.init(
            sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset,
            parserVersion: "1.4.1", indexedAt: now
        ))

        let deferred = try await coordinator.run(configuration: configuration(activeRoots: [active]))

        XCTAssertEqual(deferred.skippedFiles, 1)
        XCTAssertEqual(deferred.indexedSessions, 0)
        let deferredCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(deferredCheckpoint?.parserVersion, "1.4.1")
    }

    func testChangedOldParser141SessionStillReparsesNormally() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-old-changed")
        let url = active.appendingPathComponent("old-changed-141.jsonl")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-26T04:00:00Z"))
        let oldDate = now.addingTimeInterval(-45 * 86_400)
        let stamp = ISO8601DateFormatter().string(from: oldDate)
        try write([metaLine(id: "session:old-changed-141").replacingOccurrences(of: "2026-08-15T04:11:50.973Z", with: stamp)], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store, now: now)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        try await store.upsertCheckpoint(.init(
            sourceFileID: checkpoint.sourceFileID, sourceSize: checkpoint.sourceSize,
            sourceMtime: checkpoint.sourceMtime, byteOffset: checkpoint.byteOffset,
            parserVersion: "1.4.1", indexedAt: now
        ))
        try append([callLine(callID: "changed-141", name: "read"), outputLine(callID: "changed-141")], to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)

        let repaired = try await coordinator.run(configuration: configuration(activeRoots: [active]))

        XCTAssertEqual(repaired.indexedSessions, 1)
        let calls = try await store.fetchCalls(sessionID: "session:old-changed-141")
        let repairedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(repairedCheckpoint?.parserVersion, "1.4.2")
    }

    func testSyntheticWrapperRepairReplaysAcrossProjectsAndGlobalScopeIdempotently() async throws {
        final class EvaluationDataBox {
            var data: Data?
        }

        let store = try makeStore()
        let active = try tempDirectory("wrapper-replay-active")
        let projectA = try tempDirectory("wrapper-project-a")
        let projectB = try tempDirectory("wrapper-project-b")
        let globalSkills = try tempDirectory("wrapper-global-skills")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T04:00:00Z"))

        func writeSkill(_ root: URL, relativeDirectory: String, name: String) throws -> URL {
            let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("SKILL.md")
            try "---\nname: \(name)\ndescription: Synthetic fixture.\n---\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func writeAgent(_ project: URL) throws -> [URL] {
            let configuration = project.appendingPathComponent(".codex/agents/project-agent.toml")
            let briefDirectory = project.appendingPathComponent(".codex/agents/project-agent", isDirectory: true)
            try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
            let brief = briefDirectory.appendingPathComponent("agent.md")
            try "name = \"Project Agent\"\n".write(to: configuration, atomically: true, encoding: .utf8)
            try "# Project Agent\n\nSynthetic method.\n".write(to: brief, atomically: true, encoding: .utf8)
            return [configuration, brief]
        }
        func line(_ type: String, _ payload: [String: Any], ordinal: Int) throws -> String {
            let object: [String: Any] = [
                "type": type,
                "timestamp": "2026-10-05T03:00:00Z",
                "ordinal": ordinal,
                "payload": payload,
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func wrapper(_ id: String, _ input: String, ordinal: Int) throws -> [String] {
            [
                try line("response_item", ["type": "custom_tool_call", "id": id, "call_id": id, "name": "exec", "input": input], ordinal: ordinal),
                try line("response_item", ["type": "custom_tool_call_output", "call_id": id, "output": "synthetic"], ordinal: ordinal + 1),
            ]
        }
        func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }

        let skillAURL = try writeSkill(projectA, relativeDirectory: ".agents/skills/shared-skill", name: "shared-skill")
        let skillBURL = try writeSkill(projectB, relativeDirectory: ".agents/skills/shared-skill", name: "shared-skill")
        let globalSkillURL = try writeSkill(globalSkills, relativeDirectory: "global-tool", name: "global-tool")
        let agentAURLs = try writeAgent(projectA)
        let agentBURLs = try writeAgent(projectB)
        let capabilityFiles = [skillAURL, skillBURL, globalSkillURL] + agentAURLs + agentBURLs
        let sourceHashesBefore = try capabilityFiles.map(digest)

        let sessionA = active.appendingPathComponent("synthetic-a.jsonl")
        var sessionALines = [try line("session_meta", ["id": "session:synthetic-a", "cwd": projectA.path], ordinal: 0)]
        sessionALines += try wrapper("wrapper-a-batch", """
        const values = await Promise.allSettled([
          tools.exec_command({cmd: 'cat .agents/skills/shared-skill/SKILL.md'}),
          tools.exec_command({cmd: 'cat global-tool/SKILL.md', workdir: '\(globalSkills.path)'})
        ]);
        values.forEach((value, index) => text({index, value}));
        """, ordinal: 1)
        sessionALines += try wrapper("wrapper-a-catalog", """
        text(await tools.exec_command({cmd: 'cat .codex/agents/project-agent/agent.md'}));
        text(ALL_TOOLS.filter(x => /synthetic/.test(x.name)).map(x => ({name:x.name})));
        """, ordinal: 3)
        try write(sessionALines, to: sessionA)

        let sessionB = active.appendingPathComponent("synthetic-b.jsonl")
        var sessionBLines = [try line("session_meta", ["id": "session:synthetic-b", "cwd": projectB.path], ordinal: 0)]
        sessionBLines += try wrapper("wrapper-b-loop", """
        const result = await tools.exec_command({cmd: 'cat .agents/skills/shared-skill/SKILL.md'});
        for (const item of result.output) { text(item); }
        """, ordinal: 1)
        sessionBLines += try wrapper("wrapper-b-workdir", """
        await Promise.all([
          tools.exec_command({cmd: 'cat .agents/skills/shared-skill/SKILL.md', workdir: '\(projectA.path)'}),
          tools.exec_command({cmd: dynamicCommand})
        ]);
        """, ordinal: 3)
        try write(sessionBLines, to: sessionB)

        let child = active.appendingPathComponent("synthetic-child.jsonl")
        var childLines = [try line("session_meta", [
            "id": "session:synthetic-child", "cwd": projectB.path, "agent_role": "Project Agent",
            "parent_thread_id": "session:synthetic-b", "forked_from_id": "session:synthetic-b",
            "subagent_history_start_ordinal": 3,
        ], ordinal: 0)]
        childLines += try wrapper("wrapper-child-inherited", "await tools.exec_command({cmd: 'cat .agents/skills/shared-skill/SKILL.md'});", ordinal: 1)
        childLines += try wrapper("wrapper-child-own", """
        const values = await Promise.allSettled([
          tools.exec_command({cmd: 'cat .codex/agents/project-agent/agent.md'}),
          tools.exec_command({cmd: 'cat .agents/skills/shared-skill/SKILL.md'})
        ]);
        values.forEach(value => text(value));
        """, ordinal: 3)
        try write(childLines, to: child)

        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [
                .init(id: "project-a", url: projectA, scope: .project, kind: .projects),
                .init(id: "project-b", url: projectB, scope: .project, kind: .projects),
                .init(id: "global-skills", url: globalSkills, scope: .global, kind: .skills),
            ],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        )
        let coordinator = makeCoordinator(store: store, now: now)
        let first = try await coordinator.run(configuration: configuration)
        XCTAssertEqual(first.indexedSessions, 3)

        let resources = try await store.fetchAllResources()
        let projectASkill = try XCTUnwrap(resources.first { $0.kind == .skill && $0.projectID == "project-a" && $0.name == "shared-skill" })
        let projectBSkill = try XCTUnwrap(resources.first { $0.kind == .skill && $0.projectID == "project-b" && $0.name == "shared-skill" })
        let globalSkill = try XCTUnwrap(resources.first { $0.kind == .skill && $0.scope == .global && $0.name == "global-tool" })
        let projectAAgent = try XCTUnwrap(resources.first { $0.kind == .agent && $0.projectID == "project-a" && $0.name == "Project Agent" })
        let projectBAgent = try XCTUnwrap(resources.first { $0.kind == .agent && $0.projectID == "project-b" && $0.name == "Project Agent" })
        XCTAssertNotEqual(projectASkill.id, projectBSkill.id)
        XCTAssertNotEqual(projectAAgent.id, projectBAgent.id)

        let callsBefore = try await store.fetchInvocationsBySession()
        let allBefore = callsBefore.values.flatMap { $0 }
        XCTAssertTrue(allBefore.contains { $0.resourceID == projectASkill.id && $0.evidenceKind == .skillManifestRead })
        XCTAssertTrue(allBefore.contains { $0.resourceID == projectBSkill.id && $0.evidenceKind == .skillManifestRead })
        XCTAssertTrue(allBefore.contains { $0.resourceID == globalSkill.id && $0.evidenceKind == .skillManifestRead })
        XCTAssertTrue(allBefore.contains { $0.resourceID == projectAAgent.id && $0.evidenceKind == .agentBriefRead })
        XCTAssertTrue(allBefore.contains { $0.resourceID == projectBAgent.id && $0.evidenceKind == .agentDelegation })
        XCTAssertFalse(callsBefore["session:synthetic-child", default: []].contains { $0.id.contains("inherited") })

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let usage = try await store.fetchCapabilityUsageStats(window: .recent30(now: now, calendar: calendar))
        let usageIDs = Set(usage.filter { $0.callCount > 0 }.map(\.resourceID))
        XCTAssertTrue(usageIDs.isSuperset(of: [projectASkill.id, projectBSkill.id, globalSkill.id, projectAAgent.id, projectBAgent.id]))

        let checkpointA = try await store.fetchCheckpoint(sourceFileID: sessionA.lastPathComponent)
        let checkpointB = try await store.fetchCheckpoint(sourceFileID: sessionB.lastPathComponent)
        let checkpointChild = try await store.fetchCheckpoint(sourceFileID: child.lastPathComponent)
        let evaluationBox = EvaluationDataBox()
        let evaluationStore = InvocationEvaluationStore(
            readData: { evaluationBox.data },
            writeData: { evaluationBox.data = $0; return true },
            removeData: { evaluationBox.data = nil; return true }
        )
        let evaluatedCall = try XCTUnwrap(allBefore.first { $0.resourceID == projectASkill.id && $0.evidenceKind == .skillManifestRead })
        let evaluation = InvocationEvaluation(invocationID: evaluatedCall.id, sessionID: evaluatedCall.sessionID,
            resourceID: evaluatedCall.resourceID, label: .uncertain, updatedAt: now)
        XCTAssertTrue(evaluationStore.set(evaluation))

        let second = try await coordinator.run(configuration: configuration)
        let callsAfter = try await store.fetchInvocationsBySession()
        let resourcesAfter = try await store.fetchAllResources()
        XCTAssertEqual(second.skippedFiles, 3)
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertEqual(Set(resourcesAfter.map(\.id)), Set(resources.map(\.id)))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: resourcesAfter.map { ($0.id, $0.contentFingerprint) }),
                       Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0.contentFingerprint) }))
        let checkpointAAfter = try await store.fetchCheckpoint(sourceFileID: sessionA.lastPathComponent)
        let checkpointBAfter = try await store.fetchCheckpoint(sourceFileID: sessionB.lastPathComponent)
        let checkpointChildAfter = try await store.fetchCheckpoint(sourceFileID: child.lastPathComponent)
        XCTAssertEqual(checkpointAAfter, checkpointA)
        XCTAssertEqual(checkpointBAfter, checkpointB)
        XCTAssertEqual(checkpointChildAfter, checkpointChild)
        XCTAssertEqual(evaluationStore.evaluation(for: evaluatedCall.id), evaluation)
        XCTAssertEqual(try capabilityFiles.map(digest), sourceHashesBefore)
    }

    func testAppendedChildSessionRestoresRoleScopeAliasesAndHistoryBoundary() async throws {
        let store = try makeStore()
        let active = try tempDirectory("child-append")
        let project = try tempDirectory("child-project")
        let agentDir = project.appendingPathComponent(".codex/agents/sample-agent")
        let skillDir = project.appendingPathComponent(".agents/skills/sample-skill")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "name = \"Sample Agent\"\n".write(to: project.appendingPathComponent(".codex/agents/sample-agent.toml"), atomically: true, encoding: .utf8)
        try "# Sample Agent\nSynthetic method.\n".write(to: agentDir.appendingPathComponent("agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: sample-skill\n---\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        func line(_ type: String, _ payload: [String: Any], _ ordinal: Int) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-03T00:00:00Z", "ordinal": ordinal, "payload": payload]), as: UTF8.self)
        }
        let url = active.appendingPathComponent("child.jsonl")
        try write([
            line("session_meta", ["id": "session:child", "cwd": project.path, "agent_role": "Sample Agent", "parent_thread_id": "parent", "forked_from_id": "parent", "subagent_history_start_ordinal": 3], 0),
            line("response_item", ["type": "custom_tool_call", "id": "inherited", "call_id": "inherited", "name": "read", "input": ".agents/skills/sample-skill/SKILL.md"], 1),
            line("response_item", ["type": "custom_tool_call", "id": "brief", "call_id": "brief", "name": "read", "input": ".codex/agents/sample-agent/agent.md"], 3),
            line("response_item", ["type": "custom_tool_call_output", "call_id": "brief", "output": "synthetic"], 4)
        ], to: url)
        let config = IndexingCoordinator.Configuration(scanRoots: [ScanRoot(id: "project", url: project, scope: .project, kind: .projects)], activeSessionRoots: [active], archivedSessionRoot: nil)
        let discovery = ResourceScanner(roots: config.scanRoots).scan()
        XCTAssertEqual(discovery.agentPairings.count, 1)
        let resolution = AgentEvidenceResolver(resources: discovery.resources, roots: config.scanRoots, pairings: discovery.agentPairings)
            .resolveManifestReadSignals(input: ".codex/agents/sample-agent/agent.md", toolName: "read", projectID: "project", workingDirectory: project.path)
        XCTAssertEqual(resolution.count, 1)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: config)
        try append([
            line("response_item", ["type": "function_call", "id": "skill", "call_id": "skill", "name": "exec_command", "arguments": "{\"cmd\":\"cat .agents/skills/sample-skill/SKILL.md\"}"], 5),
            line("response_item", ["type": "function_call_output", "call_id": "skill", "output": "synthetic"], 6)
        ], to: url)
        _ = try await coordinator.run(configuration: config)
        let calls = try await store.fetchCalls(sessionID: "session:child")
        XCTAssertEqual(calls.filter { $0.evidenceKind == .agentDelegation }.count, 1)
        XCTAssertEqual(calls.filter { $0.evidenceKind == .agentBriefRead }.count, 1)
        XCTAssertEqual(calls.filter { $0.evidenceKind == .skillManifestRead }.count, 1)
        XCTAssertFalse(calls.contains { $0.id.contains("inherited") })
        let usage = try await store.fetchCapabilityHistory(through: Date(timeIntervalSince1970: 1_800_000_000))
        let agentUsage = usage.filter { $0.resourceID.hasPrefix("agent:") }
        XCTAssertEqual(agentUsage.first?.callCount, 1)
    }

    func testCurrentTokenUpgradeDefersUnchangedRolloutOlderThanThirtyDays() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-old-token-format.jsonl")
        try write([metaLine(id: "session:old-token-format")], to: url)
        let oldDate = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attributes[.modificationDate] as? Date ?? oldDate
        try await store.upsertCheckpoint(IndexCheckpoint(
            sourceFileID: url.lastPathComponent, sourceSize: size,
            sourceMtime: mtime.timeIntervalSince1970, byteOffset: size,
            parserVersion: "1.2.0", indexedAt: Date()
        ))

        let result = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(result.skippedFiles, 1)
        XCTAssertEqual(result.indexedSessions, 0)
        let checkpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(checkpoint?.parserVersion, "1.2.0")
    }

    func testAppendedJSONL() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-a.jsonl")
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: url
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let count_calls_initial = try await store.count("calls");
        XCTAssertEqual(count_calls_initial, 1)

        // The session continues: a second call is appended to the same file.
        try append([callLine(callID: "c2", name: "write"), outputLine(callID: "c2")], to: url)
        let result = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(result.indexedSessions, 1)
        let count_sessions_after_append = try await store.count("sessions");
        XCTAssertEqual(count_sessions_after_append, 1)
        let count_calls_after_append = try await store.count("calls");
        XCTAssertEqual(count_calls_after_append, 2)
        let calls = try await store.fetchCalls(sessionID: "session:coord-1")
        XCTAssertEqual(calls.map(\.resourceID), ["tool:read", "tool:write"])
    }

    func testAppendedItemCompletionRepairsExistingCallWithoutChangingCountOrIdentity() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-append")
        let url = active.appendingPathComponent("session-item-completion.jsonl")
        try write([
            metaLine(id: "session:item-completion"),
            callLine(callID: "mcp-boundary", name: "js"),
        ], to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let initialCalls = try await store.fetchCalls(sessionID: "session:item-completion")
        let initial = try XCTUnwrap(initialCalls.first)
        XCTAssertEqual(initial.status, .unknown)
        final class EvaluationDataBox { var data: Data? }
        let evaluationData = EvaluationDataBox()
        let evaluationStore = InvocationEvaluationStore(
            readData: { evaluationData.data },
            writeData: { evaluationData.data = $0; return true },
            removeData: { evaluationData.data = nil; return true }
        )
        let evaluation = InvocationEvaluation(
            invocationID: initial.id,
            sessionID: initial.sessionID,
            resourceID: initial.resourceID,
            label: .ineffective,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertTrue(evaluationStore.set(evaluation))

        try append([mcpItemCompletedLine(callID: "mcp-boundary")], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let repaired = try await store.fetchCalls(sessionID: "session:item-completion")

        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(repaired[0].id, initial.id)
        XCTAssertEqual(repaired[0].status, .failed)
        XCTAssertEqual(repaired[0].durationMs, 1_000)
        XCTAssertEqual(repaired[0].errorCategory, "mcp_error")
        XCTAssertEqual(evaluationStore.evaluation(for: repaired[0].id), evaluation)

        try append([
            mcpItemCompletedLine(callID: "mcp-boundary"),
            outputLine(callID: "mcp-boundary"),
        ], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let repeated = try await store.fetchCalls(sessionID: "session:item-completion")
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated[0].id, initial.id)
        XCTAssertEqual(repeated[0].status, .failed)
        XCTAssertEqual(evaluationStore.evaluation(for: repeated[0].id), evaluation)
    }

    func testAppendedItemCompletionOutsideBoundedLookbackStaysUnknownAndPartial() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-lookback")
        let url = active.appendingPathComponent("session-item-lookback.jsonl")
        let oversizedMessage = #"{"type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "x", count: 17 * 1_024 * 1_024))"}}"#
        try write([
            metaLine(id: "session:item-lookback"),
            callLine(callID: "outside-lookback", name: "js"),
            oversizedMessage,
        ], to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let initial = try await store.fetchCalls(sessionID: "session:item-lookback")

        try append([mcpItemCompletedLine(callID: "outside-lookback")], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let after = try await store.fetchCalls(sessionID: "session:item-lookback")
        let session = try await store.fetchAllSessions().first { $0.id == "session:item-lookback" }

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].id, initial[0].id)
        XCTAssertEqual(after[0].status, .unknown)
        XCTAssertNil(after[0].errorCategory)
        XCTAssertEqual(session?.coverage, .partial)
    }

    func testAppendedItemCompletionRefusesAmbiguousReusedCallIdentifier() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-ambiguous")
        let url = active.appendingPathComponent("session-item-ambiguous.jsonl")
        try write([
            metaLine(id: "session:item-ambiguous"),
            callLine(itemID: "attempt-one", callID: "reused-call", name: "js"),
            callLine(itemID: "attempt-two", callID: "reused-call", name: "js"),
        ], to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let before = try await store.fetchCalls(sessionID: "session:item-ambiguous")

        try append([mcpItemCompletedLine(callID: "reused-call")], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let after = try await store.fetchCalls(sessionID: "session:item-ambiguous")
        let session = try await store.fetchAllSessions().first { $0.id == "session:item-ambiguous" }

        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.count, 2)
        XCTAssertFalse(after.contains { $0.status == .failed })
        XCTAssertEqual(session?.coverage, .partial)
    }

    func testAppendedItemCompletionAtExactLookbackBoundaryRepairsKnownCall() async throws {
        let store = try makeStore()
        let active = try tempDirectory("item-completion-exact-boundary")
        let url = active.appendingPathComponent("session-item-boundary.jsonl")
        let metadata = metaLine(id: "session:item-boundary")
        let call = callLine(itemID: "boundary-item", callID: "boundary-call", name: "js")
        let lookbackBytes = 16 * 1_024 * 1_024
        let callRecordBytes = call.utf8.count + 1
        let paddingBytes = lookbackBytes - callRecordBytes - 1
        XCTAssertGreaterThan(paddingBytes, 0)
        let padding = String(repeating: " ", count: paddingBytes)
        try write([metadata, call, padding], to: url)

        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let storedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let checkpoint = try XCTUnwrap(storedCheckpoint)
        XCTAssertEqual(
            checkpoint.byteOffset - UInt64(metadata.utf8.count + 1),
            UInt64(lookbackBytes)
        )

        try append([mcpItemCompletedLine(callID: "boundary-call")], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let repaired = try await store.fetchCalls(sessionID: "session:item-boundary")

        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(repaired[0].id, "boundary-item")
        XCTAssertEqual(repaired[0].status, .failed)
        XCTAssertEqual(repaired[0].errorCategory, "mcp_error")
    }

    func testSameSizeModifiedReplacementFullyReparsesAndKeepsEvaluationMetadata() async throws {
        final class EvaluationDataBox { var data: Data? }

        let store = try makeStore()
        let active = try tempDirectory("same-size-replacement")
        let url = active.appendingPathComponent("session-same-size.jsonl")
        let initialLines = [
            metaLine(id: "session:same-size"),
            callLine(callID: "c1", name: "read"),
            outputLine(callID: "c1"),
        ]
        let replacementLines = [
            metaLine(id: "session:same-size"),
            callLine(callID: "c2", name: "read"),
            outputLine(callID: "c2"),
        ]
        XCTAssertEqual(
            (initialLines.joined(separator: "\n") + "\n").utf8.count,
            (replacementLines.joined(separator: "\n") + "\n").utf8.count
        )
        try write(initialLines, to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let originalCalls = try await store.fetchCalls(sessionID: "session:same-size")
        let original = try XCTUnwrap(originalCalls.first)
        let storedOriginalCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let originalCheckpoint = try XCTUnwrap(storedOriginalCheckpoint)
        let evaluationData = EvaluationDataBox()
        let evaluationStore = InvocationEvaluationStore(
            readData: { evaluationData.data },
            writeData: { evaluationData.data = $0; return true },
            removeData: { evaluationData.data = nil; return true }
        )
        let evaluation = InvocationEvaluation(
            invocationID: original.id,
            sessionID: original.sessionID,
            resourceID: original.resourceID,
            label: .effective,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertTrue(evaluationStore.set(evaluation))

        try write(replacementLines, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: originalCheckpoint.sourceMtime + 2)],
            ofItemAtPath: url.path
        )
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let replaced = try await store.fetchCalls(sessionID: "session:same-size")
        let storedReplacedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        let replacedCheckpoint = try XCTUnwrap(storedReplacedCheckpoint)

        XCTAssertEqual(replaced.count, 1)
        XCTAssertEqual(replaced[0].id, "c2-item")
        XCTAssertFalse(replaced.contains { $0.id == original.id })
        XCTAssertEqual(replacedCheckpoint.sourceSize, originalCheckpoint.sourceSize)
        XCTAssertGreaterThan(replacedCheckpoint.sourceMtime, originalCheckpoint.sourceMtime)
        XCTAssertEqual(evaluationStore.evaluation(for: original.id), evaluation)
        XCTAssertNil(evaluationStore.evaluation(for: replaced[0].id))
    }

    func testMetadataOnlyAppendPreservesDelegationAndTaskCompleteUpdatesOriginal() async throws {
        let store = try makeStore()
        let active = try tempDirectory("delegation-append-delta")
        let url = active.appendingPathComponent("child-delegation.jsonl")
        let metadata = #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"session:delegation-append","parent_thread_id":"parent","agent_role":"Sample Agent"}}"#
        try write([metadata], to: url)
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let initial = try await store.fetchCalls(sessionID: "session:delegation-append")
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial[0].status, .started)

        try append([startedLine()], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let metadataOnly = try await store.fetchCalls(sessionID: "session:delegation-append")
        XCTAssertEqual(metadataOnly, initial)

        try append([completeLine()], to: url)
        _ = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let completed = try await store.fetchCalls(sessionID: "session:delegation-append")

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].id, initial[0].id)
        XCTAssertEqual(completed[0].ordinal, initial[0].ordinal)
        XCTAssertEqual(completed[0].parentCallID, initial[0].parentCallID)
        XCTAssertEqual(completed[0].resourceID, initial[0].resourceID)
        XCTAssertEqual(completed[0].status, .completed)
    }

    func testAppendPreservesSessionMetadataUntilExplicitLifecycleEvidenceChangesStatus() async throws {
        let store = try makeStore()
        let active = try tempDirectory("session-metadata-append")
        let project = try tempDirectory("session-metadata-project")
        let url = active.appendingPathComponent("session-metadata.jsonl")
        let metadata = #"{"type":"session_meta","timestamp":"2026-10-26T01:00:00Z","payload":{"id":"session:metadata","cwd":"\#(project.path)"}}"#
        let started = #"{"type":"event_msg","timestamp":"2026-10-26T01:01:00Z","payload":{"type":"task_started"}}"#
        let completed = #"{"type":"event_msg","timestamp":"2026-10-26T01:02:00Z","payload":{"type":"task_complete"}}"#
        try write([metadata, started, completed], to: url)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "project:metadata", url: project, scope: .project, kind: .projects)],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        )
        let coordinator = makeCoordinator(store: store)
        _ = try await coordinator.run(configuration: config)
        let initialSessions = try await store.fetchAllSessions()
        let initial = try XCTUnwrap(initialSessions.first { $0.id == "session:metadata" })
        XCTAssertEqual(initial.projectID, "project:metadata")
        XCTAssertEqual(initial.status, .completed)

        let laterObservation = #"{"type":"response_item","timestamp":"2026-10-26T01:03:00Z","payload":{"type":"message","content":[]}}"#
        try append([laterObservation], to: url)
        _ = try await coordinator.run(configuration: config)
        let observedSessions = try await store.fetchAllSessions()
        let observed = try XCTUnwrap(observedSessions.first { $0.id == "session:metadata" })
        XCTAssertEqual(observed.projectID, initial.projectID)
        XCTAssertEqual(observed.startedAt, initial.startedAt)
        XCTAssertGreaterThan(try XCTUnwrap(observed.endedAt), try XCTUnwrap(initial.endedAt))
        XCTAssertEqual(observed.status, .completed)

        let outOfOrderObservation = #"{"type":"response_item","timestamp":"2026-10-26T01:00:30Z","payload":{"type":"message","content":[]}}"#
        try append([outOfOrderObservation], to: url)
        _ = try await coordinator.run(configuration: config)
        let nonRegressedSessions = try await store.fetchAllSessions()
        let nonRegressed = try XCTUnwrap(nonRegressedSessions.first { $0.id == "session:metadata" })
        XCTAssertEqual(nonRegressed.startedAt, initial.startedAt)
        XCTAssertEqual(nonRegressed.endedAt, observed.endedAt)
        XCTAssertEqual(nonRegressed.status, .completed)

        let resumed = #"{"type":"event_msg","timestamp":"2026-10-26T01:04:00Z","payload":{"type":"task_started"}}"#
        try append([resumed], to: url)
        _ = try await coordinator.run(configuration: config)
        let runningSessions = try await store.fetchAllSessions()
        let running = try XCTUnwrap(runningSessions.first { $0.id == "session:metadata" })
        XCTAssertEqual(running.startedAt, initial.startedAt)
        XCTAssertEqual(running.status, .running)

        let recompleted = #"{"type":"event_msg","timestamp":"2026-10-26T01:05:00Z","payload":{"type":"task_complete"}}"#
        try append([recompleted], to: url)
        _ = try await coordinator.run(configuration: config)
        let finalSessions = try await store.fetchAllSessions()
        let final = try XCTUnwrap(finalSessions.first { $0.id == "session:metadata" })
        XCTAssertEqual(final.startedAt, initial.startedAt)
        XCTAssertEqual(final.status, .completed)
        XCTAssertGreaterThan(try XCTUnwrap(final.endedAt), try XCTUnwrap(running.endedAt))
    }

    func testSourceRaceDuringAppendDoesNotAdvanceCheckpointAndRetryIsIdempotent() async throws {
        final class AttributeRace: @unchecked Sendable {
            private let lock = NSLock()
            private var targetReads = 0

            func attributes(
                for url: URL,
                target: URL,
                base: FileSystemClient
            ) -> (size: UInt64, modificationDate: TimeInterval)? {
                guard let attributes = base.fileAttributes(url) else { return nil }
                guard url.standardizedFileURL == target.standardizedFileURL else { return attributes }
                lock.lock()
                targetReads += 1
                let changed = targetReads >= 4
                lock.unlock()
                return (
                    size: attributes.size,
                    modificationDate: changed ? attributes.modificationDate + 1 : attributes.modificationDate
                )
            }
        }

        let store = try makeStore()
        let active = try tempDirectory("item-completion-source-race")
        let url = active.appendingPathComponent("session-item-race.jsonl")
        try write([
            metaLine(id: "session:item-race"),
            callLine(callID: "race-call", name: "js"),
        ], to: url)
        let config = configuration(activeRoots: [active])
        _ = try await makeCoordinator(store: store).run(configuration: config)
        let committedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        try append([mcpItemCompletedLine(callID: "race-call")], to: url)

        let base = FileSystemClient()
        let race = AttributeRace()
        let racingFileSystem = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { race.attributes(for: $0, target: url, base: base) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )
        _ = try await IndexingCoordinator(store: store, fileSystem: racingFileSystem).run(configuration: config)
        let racedCheckpoint = try await store.fetchCheckpoint(sourceFileID: url.lastPathComponent)
        XCTAssertEqual(racedCheckpoint, committedCheckpoint)

        _ = try await makeCoordinator(store: store).run(configuration: config)
        let retried = try await store.fetchCalls(sessionID: "session:item-race")
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(retried[0].status, .failed)
        XCTAssertEqual(Set(retried.map(\.id)).count, 1)
    }

    func testCurrentTokenRecordPersistsWithoutSummingLegacySnapshot() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-new-token.jsonl")
        try write([
            metaLine(id: "session:new-token"),
            tokenCountLine(total: 100),
            tokenUsageRecordLine(total: 120),
            tokenCountLine(total: 119, timestamp: "2026-08-15T04:12:07.000Z"),
        ], to: url)
        _ = try await makeCoordinator(store: store).run(configuration: configuration(activeRoots: [active]))
        let snapshots = try await store.fetchTokenSnapshots(sessionID: "session:new-token")
        XCTAssertEqual(snapshots.map(\.usage.totalTokens).sorted(), [100, 120])
        XCTAssertEqual(TokenUsageParser.newestCumulative(from: snapshots)?.usage.totalTokens, 120)
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .complete)
    }

    func testAppendedTokenSnapshotsRestorePriorModelContext() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-model.jsonl")
        try write([
            metaLine(id: "session:model"),
            turnContextLine(model: "Codex 5.3 Spark"),
            tokenCountLine(total: 100),
        ], to: url)

        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))

        // The append begins after the original turn_context. The parser must
        // seed its active model and cumulative high-water mark from SQLite.
        try append([tokenCountLine(total: 200, timestamp: "2026-08-15T04:12:06.000Z")], to: url)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))

        let snapshots = try await store.fetchTokenSnapshots(sessionID: "session:model")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.allSatisfy { $0.modelID == ModelIdentity.codex53SparkID })
        XCTAssertTrue(snapshots.allSatisfy { $0.modelConfidence == .exact })
    }

    func testTruncatedReplacedFile() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-a.jsonl")
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1"), callLine(callID: "c2", name: "write"), outputLine(callID: "c2")],
            to: url
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let count_calls_before = try await store.count("calls");
        XCTAssertEqual(count_calls_before, 2)

        // The file is truncated and replaced with a shorter, different session.
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c3", name: "grep"), outputLine(callID: "c3")],
            to: url
        )
        let result = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        XCTAssertEqual(result.indexedSessions, 1)
        let count_sessions_after_replace = try await store.count("sessions");
        XCTAssertEqual(count_sessions_after_replace, 1)
        let count_calls_after_replace = try await store.count("calls");
        XCTAssertEqual(count_calls_after_replace, 1)
        let calls = try await store.fetchCalls(sessionID: "session:coord-1")
        XCTAssertEqual(calls.map(\.resourceID), ["tool:grep"])
    }

    func testActiveFileMovedToArchive() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let archived = try tempDirectory("archived")
        let fileName = "session-move.jsonl"
        try write(
            [metaLine(id: "session:move"), callLine(callID: "m1", name: "read"), outputLine(callID: "m1")],
            to: active.appendingPathComponent(fileName)
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let count_sessions_before = try await store.count("sessions");
        XCTAssertEqual(count_sessions_before, 1)

        // The session completes after moving to the archive.
        try FileManager.default.removeItem(at: active.appendingPathComponent(fileName))
        try write(
            [metaLine(id: "session:move"), callLine(callID: "m1", name: "read"), outputLine(callID: "m1"), callLine(callID: "m2", name: "write"), outputLine(callID: "m2"), completeLine()],
            to: archived.appendingPathComponent(fileName)
        )
        let result = try await coordinator.run(
            configuration: configuration(activeRoots: [], archivedRoot: archived)
        )
        XCTAssertEqual(result.indexedSessions, 1)
        let count_sessions_after = try await store.count("sessions");
        XCTAssertEqual(count_sessions_after, 1) // no duplicate session
        let count_calls_after = try await store.count("calls");
        XCTAssertEqual(count_calls_after, 2)
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.status, .completed)
    }

    func testCancellationBeforeCommit() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:coord-1"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: active.appendingPathComponent("session-a.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        let config = configuration(activeRoots: [active])
        let task = Task {
            try await coordinator.run(configuration: config)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let count_sessions = try await store.count("sessions");
        XCTAssertEqual(count_sessions, 0)
        let count_calls = try await store.count("calls");
        XCTAssertEqual(count_calls, 0)
    }

    func testCancellationDuringAppendPreservesCommittedCheckpointAndRetryEvidence() async throws {
        let store = try makeStore()
        let active = try tempDirectory("cancel-append")
        let file = active.appendingPathComponent("synthetic-cancel.jsonl")
        try write([metaLine(id: "cancel-child"), callLine(callID: "first", name: "read"), outputLine(callID: "first")], to: file)
        let coordinator = makeCoordinator(store: store)
        let config = configuration(activeRoots: [active])
        _ = try await coordinator.run(configuration: config)
        let before = try await store.fetchCheckpoint(sourceFileID: file.lastPathComponent)
        let padding = #"{"type":"response_item","payload":{"type":"message","text":"\#(String(repeating: "x", count: 1_100_000))"}}"#
        try append([padding, callLine(callID: "second", name: "read"), outputLine(callID: "second")], to: file)
        let progress = ProgressBox()
        let task = Task {
            try await coordinator.run(configuration: config) { event in
                progress.append(event)
                if event.currentFileBytesRead != nil { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("expected mid-file cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(progress.snapshot.contains { $0.currentFileBytesRead != nil })
        let cancelledCheckpoint = try await store.fetchCheckpoint(sourceFileID: file.lastPathComponent)
        let cancelledCalls = try await store.fetchCalls(sessionID: "cancel-child")
        XCTAssertEqual(cancelledCheckpoint, before)
        XCTAssertEqual(cancelledCalls.count, 1)
        _ = try await coordinator.run(configuration: config)
        let retriedCalls = try await store.fetchCalls(sessionID: "cancel-child")
        XCTAssertEqual(retriedCalls.count, 2)
        XCTAssertEqual(Set(retriedCalls.map(\.id)).count, 2)
    }

    private var fixturesResourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/resources", isDirectory: true)
    }

    // MARK: - Runtime discovery integration (Task 5 P1)

    private struct FakeRuntimeClient: RuntimeCommandClient {
        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            switch arguments.first ?? "" {
            case "--version":
                return RuntimeCommandResult(stdout: "0.148.0-alpha.9\n", exitCode: 0, timedOut: false)
            case "mcp":
                return RuntimeCommandResult(stdout: #"[{"name":"pencil","enabled":true}]"#, exitCode: 0, timedOut: false)
            case "plugin":
                return RuntimeCommandResult(stdout: #"{"installed": [], "available": []}"#, exitCode: 0, timedOut: false)
            default:
                return RuntimeCommandResult(stdout: "", exitCode: 1, timedOut: false)
            }
        }
    }

    private struct DuplicateMCPRuntimeClient: RuntimeCommandClient {
        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            switch arguments.first ?? "" {
            case "--version":
                return RuntimeCommandResult(stdout: "0.158.0\n", exitCode: 0, timedOut: false)
            case "mcp":
                return RuntimeCommandResult(
                    stdout: #"[{"name":"duplicate","enabled":true},{"name":"duplicate","enabled":true}]"#,
                    exitCode: 0,
                    timedOut: false
                )
            case "plugin":
                return RuntimeCommandResult(
                    stdout: #"{"installed":[],"available":[]}"#,
                    exitCode: 0,
                    timedOut: false
                )
            default:
                return RuntimeCommandResult(stdout: "", exitCode: 1, timedOut: false)
            }
        }
    }

    private actor MutablePluginRuntimeClient: RuntimeCommandClient {
        private var pluginResult: RuntimeCommandResult

        init(pluginResult: RuntimeCommandResult) { self.pluginResult = pluginResult }

        func setPluginResult(_ result: RuntimeCommandResult) { pluginResult = result }

        func run(arguments: [String]) async throws -> RuntimeCommandResult {
            switch arguments.first ?? "" {
            case "--version": return RuntimeCommandResult(stdout: "0.158.0\n", exitCode: 0, timedOut: false)
            case "mcp": return RuntimeCommandResult(stdout: "[]", exitCode: 0, timedOut: false)
            case "plugin": return pluginResult
            default: return RuntimeCommandResult(stdout: "", exitCode: 1, timedOut: false)
            }
        }
    }

    private actor MutableInstalledPluginReader: CodexInstalledPluginInventoryReading {
        private var inventory: CodexInstalledPluginInventory
        init(_ inventory: CodexInstalledPluginInventory) { self.inventory = inventory }
        func set(_ value: CodexInstalledPluginInventory) { inventory = value }
        func read() async throws -> CodexInstalledPluginInventory { inventory }
    }

    func testVerifiedRemotePluginWithoutLocalPackageRetainsOnlyLastKnownChildren() async throws {
        let store = try makeStore()
        let root = try tempDirectory("plugin-package-transition")
        let package = root.appendingPathComponent("package", isDirectory: true)
        let skill = package.appendingPathComponent("skills/synthetic-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: synthetic-skill\ndescription: Synthetic fixture\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let reader = MutableInstalledPluginReader(.init(plugins: [
            CodexInstalledPlugin(id: "synthetic-plugin@remote-market", name: "synthetic-plugin", marketplace: "remote-market", version: "1", enabled: true, sourcePath: package.path)
        ], isComplete: true))
        let runtime = CodexRuntimeDiscovery(
            commandClient: FakeRuntimeClient(),
            installedPluginReading: reader,
            codexExecutableURL: URL(fileURLWithPath: "/synthetic/codex"),
            approvedSourceRoots: [root]
        )
        let coordinator = IndexingCoordinator(store: store, runtimeDiscovery: runtime)
        let config = configuration(activeRoots: [])
        let first = try await coordinator.run(configuration: config)
        XCTAssertEqual(first.runtimePluginInventoryAvailable, true)
        XCTAssertEqual(first.runtimePluginPackagesAvailable, true)
        let initialResources = try await store.fetchAllResources()
        XCTAssertEqual(initialResources.filter { $0.kind == .skill && $0.ownership == .pluginProvided }.count, 1)

        await reader.set(.init(plugins: [
            CodexInstalledPlugin(id: "synthetic-plugin@remote-market", name: "synthetic-plugin", marketplace: "remote-market", version: "1", enabled: true, sourcePath: nil)
        ], isComplete: true))
        let second = try await coordinator.run(configuration: config)
        XCTAssertEqual(second.runtimePluginInventoryAvailable, true)
        XCTAssertEqual(second.runtimePluginPackagesAvailable, false)
        let retained = try await store.fetchAllResources()
        XCTAssertEqual(retained.filter { $0.kind == .plugin && $0.sourceRootID == "runtime-plugins" }.count, 1)
        let retainedSkill = try XCTUnwrap(retained.first { $0.kind == .skill && $0.ownership == .pluginProvided })
        XCTAssertEqual(retainedSkill.status, .warning)
        XCTAssertEqual(retainedSkill.sourceRootID, "last-known-runtime")
        let retainedRelations = try await store.fetchAllRelations()
        XCTAssertTrue(retainedRelations.contains { $0.targetResourceID == retainedSkill.id && $0.relationKind == "contains" })

        await reader.set(.init(plugins: [], isComplete: true))
        let third = try await coordinator.run(configuration: config)
        XCTAssertEqual(third.runtimePluginPackagesAvailable, true)
        let removed = try await store.fetchAllResources()
        XCTAssertFalse(removed.contains { $0.kind == .plugin || ($0.kind == .skill && $0.ownership == .pluginProvided) })
    }

    func testPluginTimeoutRetainsUnverifiedInventoryAndSuccessfulEmptyPrunesIt() async throws {
        let store = try makeStore()
        let root = try tempDirectory("plugin-source")
        let skill = root.appendingPathComponent("package/skills/synthetic-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: synthetic-skill\ndescription: Synthetic fixture\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let installed = RuntimeCommandResult(
            stdout: #"{"installed":[{"name":"synthetic-plugin","installed":true,"enabled":true,"source":{"path":"\#(root.appendingPathComponent("package").path)"}}],"available":[]}"#,
            exitCode: 0, timedOut: false
        )
        let client = MutablePluginRuntimeClient(pluginResult: installed)
        let runtime = CodexRuntimeDiscovery(
            commandClient: client,
            codexExecutableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            approvedSourceRoots: [root]
        )
        let coordinator = IndexingCoordinator(store: store, runtimeDiscovery: runtime)
        let config = configuration(activeRoots: [])

        let first = try await coordinator.run(configuration: config)
        XCTAssertEqual(first.runtimePluginInventoryAvailable, true)
        let current = try await store.fetchAllResources()
        XCTAssertEqual(current.filter { $0.kind == .plugin && $0.sourceRootID == "runtime-plugins" }.count, 1)
        XCTAssertEqual(current.filter { $0.kind == .skill && $0.ownership == .pluginProvided }.count, 1)

        await client.setPluginResult(RuntimeCommandResult(stdout: "", exitCode: 15, timedOut: true))
        let failed = try await coordinator.run(configuration: config)
        XCTAssertEqual(failed.runtimePluginInventoryAvailable, false)
        let retained = try await store.fetchAllResources()
        let plugin = try XCTUnwrap(retained.first { $0.kind == .plugin })
        XCTAssertEqual(plugin.status, .warning)
        XCTAssertEqual(plugin.sourceRootID, "last-known-runtime")
        XCTAssertEqual(retained.filter { $0.kind == .skill && $0.ownership == .pluginProvided }.count, 1)
        let retainedRelations = try await store.fetchAllRelations()
        let catalog = CapabilityCatalog(resources: retained, relations: retainedRelations)
        XCTAssertEqual(catalog.entries.first { $0.resource.id == plugin.id }?.category, .installedPlugins)
        XCTAssertTrue(PluginUsage.mappings(resources: retained, relations: retainedRelations).isEmpty)

        await client.setPluginResult(RuntimeCommandResult(stdout: #"{"installed":[],"available":[]}"#, exitCode: 0, timedOut: false))
        let empty = try await coordinator.run(configuration: config)
        XCTAssertEqual(empty.runtimePluginInventoryAvailable, true)
        let emptyResources = try await store.fetchAllResources()
        XCTAssertFalse(emptyResources.contains { $0.kind == .plugin })
    }

    func testFirstPluginQueryFailureIsUnavailableNotObservedEmpty() async throws {
        let store = try makeStore()
        let client = MutablePluginRuntimeClient(
            pluginResult: RuntimeCommandResult(stdout: "", exitCode: 15, timedOut: true)
        )
        let runtime = CodexRuntimeDiscovery(
            commandClient: client,
            codexExecutableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            approvedSourceRoots: []
        )
        let result = try await IndexingCoordinator(store: store, runtimeDiscovery: runtime)
            .run(configuration: configuration(activeRoots: []))
        XCTAssertEqual(result.runtimePluginInventoryAvailable, false)
        XCTAssertEqual(result.runtimeCoverage, .partial)
        let resources = try await store.fetchAllResources()
        XCTAssertTrue(resources.filter { $0.kind == .plugin }.isEmpty)
    }

    func testRuntimeDiscoveryResourcesCombinedWithFileDiscovery() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:rt"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: active.appendingPathComponent("session-rt.jsonl")
        )
        let runtime = CodexRuntimeDiscovery(
            commandClient: FakeRuntimeClient(),
            codexExecutableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            approvedSourceRoots: [URL(fileURLWithPath: "/tmp/examplecache")]
        )
        let coordinator = IndexingCoordinator(store: store, runtimeDiscovery: runtime)
        let result = try await coordinator.run(configuration: configuration(activeRoots: [active]))
        // built-in task tools have no authoritative source -> honest partial.
        XCTAssertEqual(result.runtimeCoverage, .partial)
        let resources = try await store.fetchAllResources()
        XCTAssertTrue(resources.contains { $0.kind == .mcp && $0.name == "pencil" && $0.scope == .runtime })
        XCTAssertTrue(resources.contains { $0.kind == .app && $0.name == "codex-cli" })
    }

    func testTimedOutProjectRetainsVerifiedInventoryWhileGlobalAndSessionSourcesAdvance() async throws {
        let store = try makeStore()
        let container = try tempDirectory("isolated-project-retention")
        let globalRootURL = container.appendingPathComponent("global", isDirectory: true)
        let globalSkill = globalRootURL.appendingPathComponent("global-tool", isDirectory: true)
        let globalManifest = globalSkill.appendingPathComponent("SKILL.md")
        let projectURL = container.appendingPathComponent("project", isDirectory: true)
        let projectSkill = projectURL.appendingPathComponent(".agents/skills/project-tool", isDirectory: true)
        let active = container.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try "---\nname: global-tool\n---\nfirst\n".write(
            to: globalManifest, atomically: true, encoding: .utf8
        )
        try "---\nname: project-tool\n---\nverified\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let projectRoot = ScanRoot(
            id: "retained-project", url: projectURL, scope: .project, kind: .projects
        )
        let config = IndexingCoordinator.Configuration(
            scanRoots: [
                ScanRoot(id: "advancing-global", url: globalRootURL, scope: .global, kind: .skills),
                projectRoot,
            ],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        )
        let base = FileSystemClient()
        let blocker = ProjectDirectoryBlocker()
        let fileSystem = FileSystemClient(
            directoryReader: { url in
                if url.standardizedFileURL == projectURL.standardizedFileURL {
                    blocker.blockIfEnabled()
                }
                return base.enumerateDirectory(url)
            },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { base.readVerifiedData($0, within: $1, maximumByteCount: $2) },
            identityValidator: { base.validateDocumentRead($2, at: $0, within: $1) },
            directoryIdentityReader: { base.directoryIdentity($0) },
            directoryStatusReader: { base.directoryStatus($0) }
        )
        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
        let history = CapabilityHistoryCoordinator(store: try .memory(initialEpoch: 17))
        let coordinator = IndexingCoordinator(
            store: store,
            fileSystem: fileSystem,
            capabilityHistoryService: history,
            projectReadGate: gate
        )

        _ = try await coordinator.run(configuration: config)
        let beforeResources = try await store.fetchAllResources()
        let beforeProjectResource = try XCTUnwrap(beforeResources.first {
            $0.sourceRootID == projectRoot.id && $0.kind == .skill
        })
        let beforeProjects = try await store.fetchAllProjects()
        let beforeProject = try XCTUnwrap(beforeProjects.first {
            $0.id == projectRoot.id
        })
        let seededMissingSourceFinding = ReviewFinding(
            id: "rule.missing-source|\(beforeProjectResource.id)",
            ruleID: "rule.missing-source",
            resourceID: beforeProjectResource.id,
            sessionID: nil,
            severity: .warning,
            confidence: .exact,
            summary: "Declared source is missing or unavailable",
            evidenceSummary: "Synthetic previously verified missing source",
            coverage: .complete,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            remediationStatus: .open
        )
        try await store.replaceFindings([seededMissingSourceFinding])

        try "---\nname: global-tool\n---\nsecond\n".write(
            to: globalManifest, atomically: true, encoding: .utf8
        )
        try write(
            [metaLine(id: "session:project-timeout"), startedLine(), completeLine()],
            to: active.appendingPathComponent("session-timeout.jsonl")
        )
        blocker.enable()
        let result = try await coordinator.run(configuration: config)
        let afterResources = try await store.fetchAllResources()
        let retainedProjectResource = try XCTUnwrap(afterResources.first {
            $0.id == beforeProjectResource.id
        })
        let updatedGlobal = try XCTUnwrap(afterResources.first { $0.name == "global-tool" })
        let afterProjects = try await store.fetchAllProjects()
        let afterProject = try XCTUnwrap(afterProjects.first {
            $0.id == projectRoot.id
        })

        XCTAssertEqual(blocker.startCount, 1)
        XCTAssertEqual(result.resourceCoverage, .partial)
        XCTAssertEqual(result.indexedSessions, 1)
        XCTAssertEqual(retainedProjectResource.contentFingerprint, beforeProjectResource.contentFingerprint)
        XCTAssertEqual(retainedProjectResource.lastSeenAt, beforeProjectResource.lastSeenAt)
        XCTAssertNotEqual(updatedGlobal.contentFingerprint, beforeResources.first { $0.name == "global-tool" }?.contentFingerprint)
        XCTAssertFalse(afterProject.available)
        XCTAssertEqual(afterProject.lastSeenAt, beforeProject.lastSeenAt)
        XCTAssertEqual(result.capabilityHistoryStatus?.baselineCount, 2)
        XCTAssertEqual(result.capabilityHistoryStatus?.eventCount, 1)
        let reviewFindings = try await store.fetchAllFindings()
        XCTAssertTrue(reviewFindings.contains(seededMissingSourceFinding))

        blocker.release()
        let released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)

        try FileManager.default.removeItem(at: projectSkill)
        _ = try await coordinator.run(configuration: config)
        let completedResources = try await store.fetchAllResources()
        XCTAssertFalse(completedResources.contains { $0.id == beforeProjectResource.id })
        let completedFindings = try await store.fetchAllFindings()
        XCTAssertFalse(completedFindings.contains {
            $0.ruleID == "rule.missing-source" && $0.resourceID == beforeProjectResource.id
        })
    }

    func testCancellationDuringBlockedProjectDoesNotPublishLateInventory() async throws {
        let store = try makeStore()
        let projectURL = try tempDirectory("isolated-project-cancel")
        let skill = projectURL.appendingPathComponent(".agents/skills/project-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: project-tool\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let root = ScanRoot(id: "cancel-project", url: projectURL, scope: .project, kind: .projects)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [root], activeSessionRoots: [], archivedSessionRoot: nil
        )
        let base = FileSystemClient()
        let blocker = ProjectDirectoryBlocker()
        let fileSystem = FileSystemClient(
            directoryReader: { url in
                if url.standardizedFileURL == projectURL.standardizedFileURL {
                    blocker.blockIfEnabled()
                }
                return base.enumerateDirectory(url)
            },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )
        let gate = ProjectSourceReadGate(deadline: 1, capacity: 1)
        let coordinator = IndexingCoordinator(
            store: store, fileSystem: fileSystem, projectReadGate: gate
        )
        _ = try await coordinator.run(configuration: config)
        let beforeResources = try await store.fetchAllResources()
        let beforeProjects = try await store.fetchAllProjects()

        blocker.enable()
        let task = Task { try await coordinator.run(configuration: config) }
        let started = await waitUntil { blocker.startCount == 1 }
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let afterResources = try await store.fetchAllResources()
        let afterProjects = try await store.fetchAllProjects()
        XCTAssertEqual(afterResources, beforeResources)
        XCTAssertEqual(afterProjects, beforeProjects)
        XCTAssertEqual(gate.activeWorkerCountForTesting, 1)

        blocker.release()
        let released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)
    }

    func testCompanionTimeoutRetainsOnlyRelationsWhoseEndpointsStillExist() async throws {
        let store = try makeStore()
        let container = try tempDirectory("isolated-project-companion")
        let projectURL = container.appendingPathComponent("project", isDirectory: true)
        let agentDirectory = projectURL.appendingPathComponent(".codex/agents", isDirectory: true)
        let agentURL = agentDirectory.appendingPathComponent("build.toml")
        let projectSkillDirectory = projectURL.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = projectURL.appendingPathComponent("agents", isDirectory: true)
        let globalRootURL = container.appendingPathComponent("global", isDirectory: true)
        let globalSkillDirectory = globalRootURL.appendingPathComponent("unrelated-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkillDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalSkillDirectory, withIntermediateDirectories: true)
        try "name = \"Build Agent\"\n".write(to: agentURL, atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "---\nname: unrelated-tool\n---\n".write(
            to: globalSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try #"{"schemaVersion":3,"packages":{"video-tool":{"type":"skill","invokedBy":["Build Agent"]}}}"#.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8
        )
        let projectRoot = ScanRoot(
            id: "companion-project", url: projectURL, scope: .project, kind: .projects
        )
        let config = IndexingCoordinator.Configuration(
            scanRoots: [
                ScanRoot(id: "global", url: globalRootURL, scope: .global, kind: .skills),
                projectRoot,
            ],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )
        let base = FileSystemClient()
        let blocker = CompanionReadBlocker()
        let fileSystem = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { url, root, maximumByteCount in
                if url.standardizedFileURL == agentURL.standardizedFileURL {
                    blocker.blockOnSecondTargetRead()
                }
                return base.readVerifiedData(url, within: root, maximumByteCount: maximumByteCount)
            },
            identityValidator: { base.validateDocumentRead($2, at: $0, within: $1) },
            directoryIdentityReader: { base.directoryIdentity($0) },
            directoryStatusReader: { base.directoryStatus($0) }
        )
        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
        let history = CapabilityHistoryCoordinator(store: try .memory(initialEpoch: 19))
        let coordinator = IndexingCoordinator(
            store: store,
            fileSystem: fileSystem,
            capabilityHistoryService: history,
            projectReadGate: gate
        )

        _ = try await coordinator.run(configuration: config)
        let firstResources = try await store.fetchAllResources()
        let agent = try XCTUnwrap(firstResources.first { $0.kind == .agent && $0.projectID == projectRoot.id })
        let skill = try XCTUnwrap(firstResources.first { $0.kind == .skill && $0.name == "video-tool" })
        let relationKind = CapabilityCompanionRelationKind.companionSkill.rawValue
        let firstRelations = try await store.fetchAllRelations()
        XCTAssertTrue(firstRelations.contains {
            $0.sourceResourceID == agent.id && $0.targetResourceID == skill.id
                && $0.relationKind == relationKind
        })

        blocker.enableForNextCompanionPass()
        let retainedResult = try await coordinator.run(configuration: config)
        let retainedRelations = try await store.fetchAllRelations()
        XCTAssertEqual(blocker.startCount, 1)
        XCTAssertEqual(retainedResult.resourceCoverage, .partial)
        XCTAssertTrue(retainedRelations.contains {
            $0.sourceResourceID == agent.id && $0.targetResourceID == skill.id
                && $0.relationKind == relationKind
        })
        let retainedProjects = try await store.fetchAllProjects()
        XCTAssertEqual(retainedProjects.first { $0.id == projectRoot.id }?.available, false)
        XCTAssertEqual(retainedResult.capabilityHistoryStatus?.eventCount, 0)
        blocker.release()
        var released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)

        try FileManager.default.removeItem(at: projectSkillDirectory)
        blocker.enableForNextCompanionPass()
        let deletedResult = try await coordinator.run(configuration: config)
        let deletedResources = try await store.fetchAllResources()
        let deletedRelations = try await store.fetchAllRelations()
        XCTAssertEqual(blocker.startCount, 2)
        XCTAssertEqual(deletedResult.resourceCoverage, .partial)
        XCTAssertFalse(deletedResources.contains { $0.id == skill.id })
        XCTAssertFalse(deletedRelations.contains {
            $0.sourceResourceID == agent.id && $0.targetResourceID == skill.id
        })
        XCTAssertEqual(deletedResult.capabilityHistoryStatus?.eventCount, 0)
        blocker.release()
        released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)

        // A second complete inventory absence confirms the raw history
        // change even though the derived companion projection times out.
        blocker.enableForNextCompanionPass()
        let confirmedDeletion = try await coordinator.run(configuration: config)
        XCTAssertEqual(blocker.startCount, 3)
        XCTAssertEqual(confirmedDeletion.capabilityHistoryStatus?.eventCount, 1)
        let historyPage = try await coordinator.capabilityHistoryPage(.init(limit: 10))
        XCTAssertEqual(historyPage.events.map(\.kind), [.missing])
        blocker.release()
        released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)
    }

    func testIncompleteProjectDefersWholePassRuntimeAliasDeduplication() async throws {
        let store = try makeStore()
        let container = try tempDirectory("runtime-alias-project-gap")
        let package = container.appendingPathComponent("package", isDirectory: true)
        let globalRootURL = package.appendingPathComponent("skills", isDirectory: true)
        let sharedSkill = globalRootURL.appendingPathComponent("shared-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedSkill, withIntermediateDirectories: true)
        try "---\nname: shared-tool\n---\n".write(
            to: sharedSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let reader = MutableInstalledPluginReader(.init(
            plugins: [CodexInstalledPlugin(
                id: "synthetic-plugin@local",
                name: "synthetic-plugin",
                marketplace: "local",
                version: "1",
                enabled: true,
                sourcePath: package.path
            )],
            isComplete: true
        ))
        let runtime = CodexRuntimeDiscovery(
            commandClient: FakeRuntimeClient(),
            installedPluginReading: reader,
            codexExecutableURL: URL(fileURLWithPath: "/synthetic/codex"),
            approvedSourceRoots: [container]
        )
        let config = IndexingCoordinator.Configuration(
            scanRoots: [
                ScanRoot(id: "global-shared", url: globalRootURL, scope: .global, kind: .skills),
                ScanRoot(
                    id: "unavailable-project",
                    url: container.appendingPathComponent("missing-project", isDirectory: true),
                    scope: .project,
                    kind: .projects
                ),
            ],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )

        let result = try await IndexingCoordinator(
            store: store, runtimeDiscovery: runtime
        ).run(configuration: config)
        let resources = try await store.fetchAllResources()
        let relations = try await store.fetchAllRelations()
        let matchingSkills = resources.filter { $0.kind == .skill && $0.name == "shared-tool" }
        let runtimeSkill = try XCTUnwrap(matchingSkills.first { $0.scope == .runtime })
        let plugin = try XCTUnwrap(resources.first { $0.kind == .plugin })

        XCTAssertEqual(result.resourceCoverage, .partial)
        XCTAssertGreaterThanOrEqual(result.runtimeIssueCount, 1)
        XCTAssertEqual(matchingSkills.count, 2)
        XCTAssertTrue(relations.contains {
            $0.sourceResourceID == plugin.id
                && $0.targetResourceID == runtimeSkill.id
                && $0.relationKind == "contains"
        })
    }

    func testIncompleteProjectKeepsVerifiedPluginPackageAliasAndDistinctGlobalOwnership() async throws {
        let store = try makeStore()
        let container = try tempDirectory("runtime-plugin-package-proof")
        let pluginCache = container.appendingPathComponent("plugin-cache", isDirectory: true)
        let package = pluginCache.appendingPathComponent("synthetic-plugin", isDirectory: true)
        let manifest = package.appendingPathComponent("skills/shared-tool/SKILL.md")
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent(".codex-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "---\nname: shared-tool\n---\n".write(
            to: manifest, atomically: true, encoding: .utf8
        )
        let reader = MutableInstalledPluginReader(.init(
            plugins: [CodexInstalledPlugin(
                id: "synthetic-plugin@local",
                name: "synthetic-plugin",
                marketplace: "local",
                version: "1",
                enabled: true,
                sourcePath: package.path
            )],
            isComplete: true
        ))
        let runtime = CodexRuntimeDiscovery(
            commandClient: FakeRuntimeClient(),
            installedPluginReading: reader,
            codexExecutableURL: URL(fileURLWithPath: "/synthetic/codex"),
            approvedSourceRoots: [container]
        )
        let pluginRoot = ScanRoot(
            id: "plugin-cache", url: pluginCache, scope: .plugin, kind: .plugins
        )
        let missingProject = ScanRoot(
            id: "missing-project",
            url: container.appendingPathComponent("missing-project", isDirectory: true),
            scope: .project,
            kind: .projects
        )
        let baseConfig = IndexingCoordinator.Configuration(
            scanRoots: [pluginRoot, missingProject],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )
        let proofDiscovery = ResourceScanner(roots: baseConfig.scanRoots).scan()
        let proofRuntime = await runtime.discover()
        let proofNativeSkill = try XCTUnwrap(proofDiscovery.resources.first {
            $0.kind == .skill && $0.scope == .plugin
        })
        let proofNativeParent = try XCTUnwrap(proofDiscovery.resources.first {
            $0.kind == .plugin && $0.scope == .plugin
        })
        let proofRuntimeSkill = try XCTUnwrap(proofRuntime.resources.first {
            $0.kind == .skill && $0.scope == .runtime
        })
        let proofRuntimeParent = try XCTUnwrap(proofRuntime.resources.first {
            $0.kind == .plugin && $0.scope == .runtime
        })
        XCTAssertFalse(proofDiscovery.issues.contains { $0.rootID == pluginRoot.id })
        XCTAssertEqual(proofNativeSkill.ownership, .pluginProvided)
        XCTAssertEqual(proofNativeSkill.origin, .plugin)
        XCTAssertEqual(proofRuntimeSkill.ownership, .pluginProvided)
        XCTAssertEqual(proofRuntimeSkill.origin, .plugin)
        XCTAssertTrue(proofDiscovery.relations.contains {
            $0.sourceResourceID == proofNativeParent.id
                && $0.targetResourceID == proofNativeSkill.id
                && $0.relationKind == "contains"
                && $0.confidence == .exact
        })
        XCTAssertTrue(proofRuntime.relations.contains {
            $0.sourceResourceID == proofRuntimeParent.id
                && $0.targetResourceID == proofRuntimeSkill.id
                && $0.relationKind == "contains"
                && $0.confidence == .exact
        })
        XCTAssertNotNil(proofRuntime.transientRoots[proofRuntimeSkill.sourceRootID])
        let proofMap = IndexingCoordinator.pluginPackageRuntimeAliasMap(
            runtime: proofRuntime,
            discovery: proofDiscovery,
            scanRoots: baseConfig.scanRoots,
            pluginInventoryAvailable: true,
            pluginPackagesAvailable: true
        )
        XCTAssertEqual(proofMap.count, 1)
        let coordinator = IndexingCoordinator(store: store, runtimeDiscovery: runtime)

        let first = try await coordinator.run(configuration: baseConfig)
        let firstResources = try await store.fetchAllResources()
        let firstRelations = try await store.fetchAllRelations()
        let nativeSkill = try XCTUnwrap(firstResources.first {
            $0.kind == .skill && $0.name == "shared-tool" && $0.scope == .plugin
        })
        let runtimeParent = try XCTUnwrap(firstResources.first {
            $0.kind == .plugin && $0.scope == .runtime
        })
        XCTAssertEqual(first.resourceCoverage, .partial)
        XCTAssertEqual(firstResources.filter { $0.kind == .skill && $0.name == "shared-tool" }.count, 1)
        XCTAssertTrue(firstRelations.contains {
            $0.sourceResourceID == runtimeParent.id
                && $0.targetResourceID == nativeSkill.id
                && $0.relationKind == "contains"
        })
        let resolved = SkillEvidenceResolver(resources: firstResources, roots: baseConfig.scanRoots)
            .resolveManifestReadSignal(input: "read \(manifest.path)", toolName: "read")
        XCTAssertEqual(resolved?.resourceID, nativeSkill.id)

        _ = try await coordinator.run(configuration: baseConfig)
        let repeatedResources = try await store.fetchAllResources()
        let repeatedRelations = try await store.fetchAllRelations()
        XCTAssertEqual(Set(repeatedResources.map(\.id)), Set(firstResources.map(\.id)))
        XCTAssertEqual(Set(repeatedRelations.map(\.id)), Set(firstRelations.map(\.id)))

        let globalRoot = ScanRoot(
            id: "global-same-file",
            url: package.appendingPathComponent("skills", isDirectory: true),
            scope: .global,
            kind: .skills
        )
        let globalConfig = IndexingCoordinator.Configuration(
            scanRoots: [pluginRoot, globalRoot, missingProject],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )
        _ = try await coordinator.run(configuration: globalConfig)
        let globalResources = try await store.fetchAllResources()
        let globalRelations = try await store.fetchAllRelations()
        let sameFileSkills = globalResources.filter { $0.kind == .skill && $0.name == "shared-tool" }
        XCTAssertEqual(Set(sameFileSkills.map(\.scope)), [.plugin, .global])
        XCTAssertFalse(sameFileSkills.contains { $0.scope == .runtime })
        XCTAssertTrue(globalRelations.contains {
            $0.sourceResourceID == runtimeParent.id
                && $0.targetResourceID == nativeSkill.id
                && $0.relationKind == "contains"
        })
    }

    func testDuplicateRuntimeIDsDoNotTrapWhileLocalCapabilityScopeIsPartial() async throws {
        let store = try makeStore()
        let root = try tempDirectory("duplicate-runtime-partial-local")
        let skill = root.appendingPathComponent("hidden-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: hidden-skill\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let base = FileSystemClient()
        let partial = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            directoryStatusReader: { url in
                url.standardizedFileURL == skill.standardizedFileURL
                    ? .failure(.permissionDenied)
                    : base.directoryStatus(url)
            }
        )
        let runtime = CodexRuntimeDiscovery(
            commandClient: DuplicateMCPRuntimeClient(),
            codexExecutableURL: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            approvedSourceRoots: []
        )
        let config = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "partial-local", url: root, scope: .global, kind: .skills)],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )

        let result = try await IndexingCoordinator(
            store: store,
            fileSystem: partial,
            runtimeDiscovery: runtime
        ).run(configuration: config)
        let resources = try await store.fetchAllResources()

        XCTAssertEqual(result.resourceCoverage, .partial)
        XCTAssertEqual(resources.filter { $0.kind == .mcp && $0.name == "duplicate" }.count, 1)
        XCTAssertFalse(resources.contains { $0.name == "hidden-skill" })
    }

    // MARK: - Skill evidence production flow (Task 4 P1)

    private func writeSkillSession(to active: URL) throws {
        try write([
            metaLine(id: "session:skill"),
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"s1","call_id":"s1","name":"read","input":"read sample-skill/SKILL.md"}}"#,
            outputLine(callID: "s1"),
        ], to: active.appendingPathComponent("session-skill.jsonl"))
    }

    private func skillConfiguration(active: URL) -> IndexingCoordinator.Configuration {
        IndexingCoordinator.Configuration(
            scanRoots: [
                ScanRoot(id: "global-skills", url: fixturesResourcesRoot.appendingPathComponent("global-skills"), scope: .global, kind: .skills),
            ],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        )
    }

    func testCoordinatorReloadsGlobalOwnershipRegistryOnEachSourceRun() async throws {
        let store = try makeStore()
        let temp = try tempDirectory("ownership-registry")
        let skills = temp.appendingPathComponent("skills", isDirectory: true)
        let skill = skills.appendingPathComponent("two-word", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: two-word\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let registry = temp.appendingPathComponent("AGENTS.md")
        try "# Global Skill Library\n\n- `Two Word`: `\(skill.appendingPathComponent("SKILL.md").path)`\n".write(
            to: registry, atomically: true, encoding: .utf8
        )
        let configuration = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "global-skills", url: skills, scope: .global, kind: .skills)],
            activeSessionRoots: [],
            archivedSessionRoot: nil,
            skillOwnershipRegistryURL: registry
        )
        let coordinator = makeCoordinator(store: store)

        let registeredResult = try await coordinator.run(configuration: configuration)
        let registeredResources = try await store.fetchAllResources()
        let registered = try XCTUnwrap(registeredResources.first)
        XCTAssertEqual(registered.ownership, .userOwned)
        XCTAssertEqual(registered.classificationConfidence, .exact)
        XCTAssertEqual(registeredResult.discoveryIssueCount, 0)

        try "# Global Skill Library\n\nNo registered workflows.\n".write(
            to: registry, atomically: true, encoding: .utf8
        )
        _ = try await coordinator.run(configuration: configuration)
        let unregisteredResources = try await store.fetchAllResources()
        let unregistered = try XCTUnwrap(unregisteredResources.first)
        XCTAssertEqual(unregistered.id, registered.id)
        XCTAssertEqual(unregistered.ownership, .installed)
        XCTAssertEqual(unregistered.origin, .unknown)
        XCTAssertEqual(unregistered.classificationConfidence, .inferred)
    }

    func testCoordinatorIndexesSchemaV3PackageCompanionDeclarations() async throws {
        let store = try makeStore()
        let project = try tempDirectory("schema-v3-project")
        let active = try tempDirectory("schema-v3-active")
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: active)
        }
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".agents/skills/video-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "name = \"Build Agent\"\n"
            .write(to: project.appendingPathComponent(".codex/agents/build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: project.appendingPathComponent(".agents/skills/video-tool/SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":3,"packages":{"video-tool":{"type":"skill","invokedBy":["Build Agent"]},"Build Agent":{"type":"agent","usesSkills":["video-tool"]}}}"#
        try registry.write(to: project.appendingPathComponent("agents/registry.json"), atomically: true, encoding: .utf8)

        _ = try await makeCoordinator(store: store).run(configuration: IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "project", url: project, scope: .project, kind: .projects)],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        ))
        let resources = try await store.fetchAllResources()
        let relations = try await store.fetchAllRelations()
        let agent = try XCTUnwrap(resources.first { $0.kind == .agent && $0.name == "Build Agent" })
        let skill = try XCTUnwrap(resources.first { $0.kind == .skill && $0.name == "video-tool" })
        XCTAssertTrue(relations.contains {
            $0.sourceResourceID == agent.id && $0.targetResourceID == skill.id
                && $0.relationKind == CapabilityCompanionRelationKind.companionSkill.rawValue
                && $0.evidenceSummary == CapabilityCompanionDeclarationSource.projectRegistry.rawValue
        })
    }

    func testCoordinatorCompanionResolverUsesInjectedVerifiedFileSystem() async throws {
        let store = try makeStore()
        let project = try tempDirectory("schema-v3-injected-filesystem")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".agents/skills/video-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "name = \"Build Agent\"\n"
            .write(to: project.appendingPathComponent(".codex/agents/build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: project.appendingPathComponent(".agents/skills/video-tool/SKILL.md"), atomically: true, encoding: .utf8)
        let registryURL = project.appendingPathComponent("agents/registry.json")
        try #"{"schemaVersion":3,"packages":{"video-tool":{"type":"skill","invokedBy":["Build Agent"]}}}"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let base = FileSystemClient()
        let restricted = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { url in
                url.standardizedFileURL == registryURL.standardizedFileURL
                    ? .failure(.permissionDenied)
                    : base.readData(url)
            },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )
        let config = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "project", url: project, scope: .project, kind: .projects)],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )

        let result = try await IndexingCoordinator(store: store, fileSystem: restricted).run(configuration: config)
        let relations = try await store.fetchAllRelations()

        XCTAssertTrue(relations.filter { $0.relationKind == CapabilityCompanionRelationKind.companionSkill.rawValue }.isEmpty)
        XCTAssertGreaterThan(result.discoveryIssueCount, 0)
    }

    func testCoordinatorPersistsProductionSkillInvocation() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try writeSkillSession(to: active)
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: skillConfiguration(active: active))
        let calls = try await store.fetchCalls(sessionID: "session:skill")
        let skillCalls = calls.filter { $0.kind == .skill }
        XCTAssertEqual(skillCalls.count, 1)
        XCTAssertEqual(skillCalls[0].confidence, .inferred)
        XCTAssertNotNil(skillCalls[0].resourceID)
        XCTAssertEqual(skillCalls[0].status, .completed)
    }

    func testCoordinatorPersistsOnlyEvidenceBackedAgentInvocation() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write([
            metaLine(id: "session:agent"),
            agentReadLine(callID: "a1"),
            outputLine(callID: "a1"),
        ], to: active.appendingPathComponent("session-agent.jsonl"))
        let config = IndexingCoordinator.Configuration(
            scanRoots: [
                ScanRoot(id: "global-agents", url: fixturesResourcesRoot.appendingPathComponent("global-agents"), scope: .global, kind: .agents),
            ],
            activeSessionRoots: [active],
            archivedSessionRoot: nil
        )
        try await makeCoordinator(store: store).run(configuration: config)
        let calls = try await store.fetchCalls(sessionID: "session:agent")
        let agentCalls = calls.filter { $0.kind == .agent }
        XCTAssertEqual(agentCalls.count, 1)
        XCTAssertEqual(agentCalls[0].confidence, .inferred)
        XCTAssertNotNil(agentCalls[0].resourceID)
        XCTAssertEqual(agentCalls[0].status, .completed)
        XCTAssertFalse(calls.contains { $0.resourceID?.hasPrefix("orchestration:") == true })
    }

    func testSkillEvidenceDoesNotPersistRawInputOrPath() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try writeSkillSession(to: active)
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: skillConfiguration(active: active))
        let calls = try await store.fetchCalls(sessionID: "session:skill")
        XCTAssertTrue(calls.contains { $0.kind == .skill })
        for call in calls {
            let values = [call.id, call.sessionID, call.parentCallID ?? "", call.actorName ?? "", call.resourceID ?? "", call.errorCategory ?? ""]
            for value in values {
                XCTAssertFalse(value.contains("SKILL.md"), "raw manifest path leaked: \(value)")
                XCTAssertFalse(value.contains("sample-skill/"), "raw manifest path leaked: \(value)")
                XCTAssertFalse(value.contains("/Users/"), "unredacted path leaked: \(value)")
            }
        }
    }

    func testCompletedIndexPersistsParserCoverageFinding() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        // Unmatched call -> partial coverage -> rule.parser-coverage fires.
        try write(
            [metaLine(id: "session:partial"), callLine(callID: "c1", name: "read")],
            to: active.appendingPathComponent("session-p.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let findings = try await store.fetchAllFindings()
        XCTAssertTrue(findings.contains { $0.ruleID == "rule.parser-coverage" && $0.sessionID == "session:partial" })
        XCTAssertFalse(findings.isEmpty)
    }

    func testSecondCompletedIndexRemovesResolvedFinding() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-p.jsonl")
        // Longer partial file first.
        try write(
            [metaLine(id: "session:partial"), callLine(callID: "c1", name: "read"), malformedTokenLine(), malformedTokenLine()],
            to: url
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let findings_first = try await store.fetchAllFindings()
        XCTAssertTrue(findings_first.contains { $0.ruleID == "rule.parser-coverage" })

        // Shorter clean replacement re-parses and removes the resolved finding.
        try write(
            [metaLine(id: "session:partial"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: url
        )
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let findings = try await store.fetchAllFindings()
        XCTAssertFalse(findings.contains { $0.ruleID == "rule.parser-coverage" && $0.sessionID == "session:partial" })
    }

    func testCancelledIndexDoesNotClearExistingFindings() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:partial"), callLine(callID: "c1", name: "read")],
            to: active.appendingPathComponent("session-p.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        let config = configuration(activeRoots: [active])
        try await coordinator.run(configuration: config)
        let before = try await store.fetchAllFindings()
        XCTAssertTrue(before.contains { $0.ruleID == "rule.parser-coverage" })

        let task = Task {
            try await coordinator.run(configuration: config)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let after = try await store.fetchAllFindings()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
    }

    private func malformedTokenLine() -> String {
        #"{"type":"event_msg","timestamp":"2026-08-15T04:12:06.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}"#
    }

    func testInvocationIssueMakesPersistedSessionCoveragePartial() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        // A call without a matching result produces an InvocationExtraction issue.
        try write(
            [metaLine(id: "session:cov"), callLine(callID: "c1", name: "read")],
            to: active.appendingPathComponent("session-cov.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .partial)
    }

    func testTokenIssueMakesPersistedSessionCoveragePartial() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:tok"), malformedTokenLine()],
            to: active.appendingPathComponent("session-tok.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .partial)
    }

    func testMatchedValidSessionRemainsComplete() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        try write(
            [metaLine(id: "session:ok"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: active.appendingPathComponent("session-ok.jsonl")
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .complete)
    }

    func testValidAppendDoesNotUpgradePreviouslyPartialCoverage() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-cov.jsonl")
        try write(
            [metaLine(id: "session:cov"), callLine(callID: "c1", name: "read")],
            to: url
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .partial)

        // A clean append must not erase the previously partial state.
        try append([callLine(callID: "c2", name: "write"), outputLine(callID: "c2")], to: url)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session_after_append = try await store.fetchAllSessions().first
        XCTAssertEqual(session_after_append?.coverage, .partial)
    }

    func testFullReplacementCanRecomputePartialCoverageAsComplete() async throws {
        let store = try makeStore()
        let active = try tempDirectory("active")
        let url = active.appendingPathComponent("session-cov.jsonl")
        // A longer partial file (unmatched call + malformed tokens) whose
        // replacement is shorter triggers a full reparse from offset zero.
        try write(
            [metaLine(id: "session:cov"), callLine(callID: "c1", name: "read"), malformedTokenLine(), malformedTokenLine()],
            to: url
        )
        let coordinator = makeCoordinator(store: store)
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session = try await store.fetchAllSessions().first
        XCTAssertEqual(session?.coverage, .partial)

        // Full replacement re-parses from zero and can become complete.
        try write(
            [metaLine(id: "session:cov"), callLine(callID: "c1", name: "read"), outputLine(callID: "c1")],
            to: url
        )
        try await coordinator.run(configuration: configuration(activeRoots: [active]))
        let session_after_replace = try await store.fetchAllSessions().first
        XCTAssertEqual(session_after_replace?.coverage, .complete)
    }

    func testHistoryFailureAfterInventoryCommitRetriesSameObservedDifference() async throws {
        final class FailureSwitch: @unchecked Sendable {
            private let lock = NSLock()
            private var replacementAttempt = 0
            func failOnSecondReplacement(_ phase: CapabilityHistoryStore.WritePhase) throws {
                guard phase == .beforeReplacement else { return }
                lock.lock()
                replacementAttempt += 1
                let shouldFail = replacementAttempt == 2
                lock.unlock()
                if shouldFail { throw NSError(domain: "synthetic-history", code: 1) }
            }
        }

        let store = try makeStore()
        let source = try tempDirectory("history-retry-source")
        let skill = source.appendingPathComponent("history-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let manifest = skill.appendingPathComponent("SKILL.md")
        try "---\nname: history-skill\n---\nA\n".write(to: manifest, atomically: true, encoding: .utf8)
        let historyURL = try tempDirectory("history-retry-store").appendingPathComponent("history.json")
        let failure = FailureSwitch()
        let historyStore = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { try failure.failOnSecondReplacement($0) }
        )
        let history = CapabilityHistoryCoordinator(store: historyStore)
        let coordinator = IndexingCoordinator(store: store, capabilityHistoryService: history)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "global-skills", url: source, scope: .global, kind: .skills)],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )

        let first = try await coordinator.run(configuration: config)
        XCTAssertEqual(first.capabilityHistoryStatus?.baselineCount, 1)
        XCTAssertEqual(first.capabilityHistoryStatus?.eventCount, 0)

        try "---\nname: history-skill\n---\nB\n".write(to: manifest, atomically: true, encoding: .utf8)
        let failedHistory = try await coordinator.run(configuration: config)
        let indexedResources = try await store.fetchAllResources()
        XCTAssertEqual(indexedResources.first?.name, "history-skill")
        XCTAssertTrue(failedHistory.capabilityHistoryStatus?.issueCodes.contains(.storageUnavailable) == true)
        XCTAssertEqual(failedHistory.capabilityHistoryStatus?.eventCount, 0)

        let retried = try await coordinator.run(configuration: config)
        XCTAssertEqual(retried.capabilityHistoryStatus?.eventCount, 1)
        let page = try await coordinator.capabilityHistoryPage(.init(limit: 20))
        XCTAssertEqual(page.events.map(\.kind), [.modified])
    }

    func testDerivedIndexDeletionPreservesHistoryAndDoesNotReportAllCapabilitiesAdded() async throws {
        let store = try makeStore()
        let source = try tempDirectory("history-delete-source")
        let skill = source.appendingPathComponent("history-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let manifest = skill.appendingPathComponent("SKILL.md")
        try "---\nname: history-skill\n---\nA\n".write(to: manifest, atomically: true, encoding: .utf8)
        let history = CapabilityHistoryCoordinator(store: try .memory(initialEpoch: 12))
        let coordinator = IndexingCoordinator(store: store, capabilityHistoryService: history)
        let config = IndexingCoordinator.Configuration(
            scanRoots: [ScanRoot(id: "global-skills", url: source, scope: .global, kind: .skills)],
            activeSessionRoots: [],
            archivedSessionRoot: nil
        )

        _ = try await coordinator.run(configuration: config)
        try "---\nname: history-skill\n---\nB\n".write(to: manifest, atomically: true, encoding: .utf8)
        _ = try await coordinator.run(configuration: config)
        let historyStatus = await coordinator.capabilityHistoryStatus()
        XCTAssertEqual(historyStatus.eventCount, 1)

        try await store.deleteAllData()
        let rebuilt = try await coordinator.run(configuration: config)
        XCTAssertEqual(rebuilt.capabilityHistoryStatus?.eventCount, 1)
        let historyPage = try await coordinator.capabilityHistoryPage(.init(limit: 20))
        XCTAssertEqual(historyPage.events.map(\.kind), [.modified])
    }
}
