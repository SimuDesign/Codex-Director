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

    private func outputLine(callID: String) -> String {
        #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"custom_tool_call_output","id":"\#(callID)-out","call_id":"\#(callID)","output":[{"type":"text","text":"ok"}]}}"#
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

    private func makeCoordinator(store: DatabaseStore) -> IndexingCoordinator {
        IndexingCoordinator(store: store)
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
}
