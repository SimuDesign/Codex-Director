import XCTest
@testable import DirectorCore
import SQLite3

/// Explicit opt-in Release-scale acceptance tests.
///
/// Ordinary debug test runs skip the 200k/160k fixtures. Run these tests with:
/// `CODEX_DIRECTOR_RUN_HEAVY_PERF=1 swift test -c release --disable-sandbox --scratch-path /tmp/codex-director-query-performance-<UUID> --filter 'QueryPerformanceTests'`
/// They use only UUID-scoped temporary databases and print aggregate timings.
final class QueryPerformanceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private func requireHeavyPerformanceRun() throws {
        guard ProcessInfo.processInfo.environment["CODEX_DIRECTOR_RUN_HEAVY_PERF"] == "1" else {
            throw XCTSkip("opt-in: set CODEX_DIRECTOR_RUN_HEAVY_PERF=1 for Release-scale benchmarks")
        }
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-query-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func percentile(_ values: [TimeInterval], _ p: Double) -> TimeInterval {
        let sorted = values.sorted()
        guard let first = sorted.first else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p) - 1)))
        return sorted[index] == 0 ? first : sorted[index]
    }

    private func elapsed(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func sampleResource(
        id: String,
        kind: ResourceKind,
        name: String,
        scope: ResourceScope = .runtime,
        ownership: ResourceOwnership = .runtime,
        origin: ResourceOrigin = .runtime
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: kind,
            status: .idle,
            scope: scope,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: "perf-root",
            relativeSourcePath: "resource/\(id)",
            sourcePathHash: "hash-\(id)",
            lastSeenAt: now,
            ownership: ownership,
            origin: origin
        )
    }

    private func quotaSnapshots(totalRows: Int) throws -> [QuotaSnapshot] {
        let longSuffix = String(repeating: "q", count: 64)
        var result: [QuotaSnapshot] = []
        let rowsPerSource = totalRows / 2
        let weeklyRowsPerSource = rowsPerSource * 9 / 10
        let shortRowsPerSource = rowsPerSource - weeklyRowsPerSource
        result.reserveCapacity(totalRows)
        for source in 0..<2 {
            let sourceID = "account-\(source)-\(longSuffix)"
            for index in 0..<weeklyRowsPerSource {
                let capturedAt: Date
                if index < 4_000 {
                    capturedAt = now.addingTimeInterval(-Double(index + 1) * 60)
                } else {
                    // Keep the old source histories in separate time bands.
                    // Real providers can have unequal retention/end dates;
                    // this shape catches predecessor queries that rescan the
                    // newer source history once for every older-source row.
                    let sourceBand = Double(source * weeklyRowsPerSource) * 60
                    capturedAt = now.addingTimeInterval(-8 * 86_400 - sourceBand - Double(index) * 60)
                }
                let resetsAt: Date?
                if source == 0, index == 0 {
                    // The newest observation has no reset value. This keeps
                    // the aggregate honest when the provider omits it.
                    resetsAt = nil
                } else if source == 0, index == 1 {
                    // A non-nil transition within the recent window exercises
                    // cycleChanged while the sparse tail leaves missing days.
                    resetsAt = capturedAt.addingTimeInterval(6 * 86_400)
                } else {
                    resetsAt = capturedAt.addingTimeInterval(7 * 86_400)
                }
                result.append(try QuotaSnapshot(
                    id: "quota-weekly-\(source)-\(index)-\(longSuffix)",
                    capturedAt: capturedAt,
                    windowMinutes: 10_080,
                    usedPercent: Double((index + source) % 101),
                    resetsAt: resetsAt,
                    limitID: sourceID,
                    limitName: "Performance source \(source)",
                    confidence: .exact
                ))
            }
            for index in 0..<shortRowsPerSource {
                let capturedAt = now.addingTimeInterval(-30 * 86_400 - Double(index + 1) * 120)
                result.append(try QuotaSnapshot(
                    id: "quota-short-\(source)-\(index)-\(longSuffix)",
                    capturedAt: capturedAt,
                    windowMinutes: 300,
                    usedPercent: Double((index * 3 + source) % 101),
                    resetsAt: capturedAt.addingTimeInterval(300),
                    limitID: sourceID,
                    limitName: "Performance source \(source)",
                    confidence: .exact
                ))
            }
        }
        return result
    }

    private func makeQuotaStore(totalRows: Int = 200_000) async throws -> (DatabaseStore, URL) {
        let root = try temporaryRoot("quota")
        let url = root.appendingPathComponent("quota.sqlite")
        let store = try DatabaseStore(url: url)
        let session = TaskSummary(
            id: "quota-fixture-session-\(String(repeating: "s", count: 48))",
            projectID: "quota-fixture-project",
            startedAt: now,
            endedAt: now,
            status: .completed,
            coverage: .complete,
            parserVersion: "perf",
            sourceFileID: "quota-fixture-source",
            title: nil
        )
        try await store.replaceSession(PersistedSessionBatch(session: session, calls: [], tokenSnapshots: [], quotaSnapshots: try quotaSnapshots(totalRows: totalRows), findings: []))
        return (store, root)
    }

    private func quotaPlan(at root: URL, window: CapabilityQueryWindow) throws -> [String] {
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("quota.sqlite"), readOnly: true))
        let statement = try connection.prepare(
            """
            EXPLAIN QUERY PLAN
            WITH weekly AS (
                SELECT id,captured_at,window_minutes,used_percent,resets_at,limit_id,limit_name,confidence,
                       CASE WHEN limit_id IS NOT NULL AND limit_id <> '' THEN 'id:' || limit_id
                            WHEN limit_name IS NOT NULL AND limit_name <> '' THEN 'name:' || limit_name
                            ELSE 'unknown' END AS source_key
                FROM quota_snapshots
                WHERE window_minutes = 10080 AND captured_at <= ?
            ), predecessor_times AS (
                SELECT source_key,MAX(captured_at) AS captured_at
                FROM weekly WHERE captured_at < ? GROUP BY source_key
            ), ranked_predecessors AS (
                SELECT weekly.id,weekly.captured_at,weekly.window_minutes,weekly.used_percent,
                       weekly.resets_at,weekly.limit_id,weekly.limit_name,weekly.confidence,
                       ROW_NUMBER() OVER (PARTITION BY weekly.source_key ORDER BY weekly.id DESC) AS source_rank
                FROM weekly JOIN predecessor_times
                  ON predecessor_times.source_key = weekly.source_key
                 AND predecessor_times.captured_at = weekly.captured_at
            ), selected AS (
                SELECT id,captured_at,window_minutes,used_percent,resets_at,limit_id,limit_name,confidence
                FROM weekly WHERE captured_at >= ?
                UNION ALL
                SELECT id,captured_at,window_minutes,used_percent,resets_at,limit_id,limit_name,confidence
                FROM ranked_predecessors WHERE source_rank = 1
            )
            SELECT id,captured_at,window_minutes,used_percent,resets_at,limit_id,limit_name,confidence
            FROM selected ORDER BY limit_id,limit_name,captured_at ASC,id ASC
            """
        )
        statement.bind(window.end.timeIntervalSince1970, at: 1)
        statement.bind(window.start.timeIntervalSince1970, at: 2)
        statement.bind(window.start.timeIntervalSince1970, at: 3)
        var details: [String] = []
        while try statement.step() == .row {
            if let detail = statement.columnText(3) { details.append(detail) }
        }
        return details
    }

    private func call(
        id: String,
        sessionID: String,
        ordinal: Int,
        timestamp: Date,
        resourceID: String?,
        parentCallID: String? = nil,
        kind: InvocationKind = .tool,
        status: InvocationStatus = .completed
    ) -> InvocationEvent {
        InvocationEvent(
            id: id,
            sessionID: sessionID,
            parentCallID: parentCallID,
            ordinal: ordinal,
            timestamp: timestamp,
            actorName: nil,
            resourceID: resourceID,
            kind: kind,
            status: status,
            durationMs: 1,
            confidence: .exact,
            errorCategory: status == .failed ? "perf-failure" : nil
        )
    }

    private func makeCallStore() async throws -> (DatabaseStore, URL, Int) {
        let root = try temporaryRoot("calls")
        let url = root.appendingPathComponent("calls.sqlite")
        let store = try DatabaseStore(url: url)
        let plugin = sampleResource(id: "plugin:performance", kind: .plugin, name: "Performance plugin")
        let skill = sampleResource(id: "skill:performance", kind: .skill, name: "Performance skill", scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let mcp = sampleResource(id: "mcp:performance", kind: .mcp, name: "perf", scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let unsupported = sampleResource(id: "plugin:unsupported", kind: .plugin, name: "Unsupported plugin")
        let ambiguousPluginA = sampleResource(id: "plugin:ambiguous-a", kind: .plugin, name: "Ambiguous plugin A")
        let ambiguousPluginB = sampleResource(id: "plugin:ambiguous-b", kind: .plugin, name: "Ambiguous plugin B")
        let ambiguousSkill = sampleResource(id: "skill:ambiguous-child", kind: .skill, name: "Ambiguous child", scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let ambiguousOwnedMCP = sampleResource(id: "mcp:ambiguous-owned", kind: .mcp, name: "ambiguous", scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let ambiguousIndependentMCP = sampleResource(id: "mcp:ambiguous-independent", kind: .mcp, name: "ambiguous")
        let relations = [
            ResourceRelation(sourceResourceID: plugin.id, targetResourceID: skill.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: plugin.id, targetResourceID: mcp.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: ambiguousPluginA.id, targetResourceID: ambiguousSkill.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: ambiguousPluginB.id, targetResourceID: ambiguousSkill.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: plugin.id, targetResourceID: ambiguousOwnedMCP.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        ]
        try await store.replaceResourceInventory(resources: [plugin, skill, mcp, unsupported, ambiguousPluginA, ambiguousPluginB, ambiguousSkill, ambiguousOwnedMCP, ambiguousIndependentMCP], relations: relations)

        let longSuffix = String(repeating: "c", count: 64)
        let totalSessions = 1_500
        let largeSessionCalls = 27_000
        let remainingCalls = 160_000 - largeSessionCalls
        let basePerSession = remainingCalls / (totalSessions - 1)
        let remainder = remainingCalls % (totalSessions - 1)
        for sessionIndex in 0..<totalSessions {
            let sessionID = "session-\(sessionIndex)-\(longSuffix)"
            let count: Int
            if sessionIndex == 0 {
                count = largeSessionCalls
            } else {
                count = basePerSession + (sessionIndex <= remainder ? 1 : 0)
            }
            var calls: [InvocationEvent] = []
            calls.reserveCapacity(count)
            for index in 0..<count {
                let id = "call-\(sessionIndex)-\(index)-\(longSuffix)"
                let timestamp = now.addingTimeInterval(-Double((sessionIndex * 31 + index) % 10_000))
                let status: InvocationStatus
                if sessionIndex == 1, index == 0 {
                    status = .failed
                } else if sessionIndex == 1, index == 1 {
                    status = .interrupted
                } else {
                    status = .completed
                }
                if sessionIndex == 0, index == 0 {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: plugin.id, status: status))
                } else if sessionIndex == 0, index == 1 {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: skill.id, parentCallID: "call-0-0-\(longSuffix)", kind: .skill, status: status))
                } else if sessionIndex == 0, index == 2 {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: skill.id, parentCallID: "call-0-1-\(longSuffix)", kind: .skill, status: status))
                } else if sessionIndex == 0, index == 3 {
                    // This child has two current plugin owners and must not be
                    // attributed to either plugin.
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: ambiguousSkill.id, kind: .skill, status: status))
                } else if sessionIndex == 0, index == 4 {
                    // An independent MCP with the same namespace makes this
                    // namespace ambiguous and therefore unattributable.
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: "tool:mcp__ambiguous__read", status: status))
                } else if index.isMultiple(of: 101) {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: "tool:mcp__perf__read", status: status))
                } else if index.isMultiple(of: 100) {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: skill.id, kind: .skill, status: status))
                } else {
                    calls.append(call(id: id, sessionID: sessionID, ordinal: index, timestamp: timestamp, resourceID: "tool:ordinary", status: status))
                }
            }
            let status = sessionIndex == totalSessions - 1 ? TaskStatus.interrupted : TaskStatus.completed
            try await store.replaceSession(PersistedSessionBatch(
                session: TaskSummary(id: sessionID, projectID: "project-\(sessionIndex % 16)-\(longSuffix)", startedAt: now, endedAt: now, status: status, coverage: .complete, parserVersion: "perf", sourceFileID: "source-\(sessionIndex)-\(longSuffix)", title: nil),
                calls: calls,
                tokenSnapshots: [],
                quotaSnapshots: [],
                findings: []
            ))
        }
        // Fixture writes use a private writer, but measurement must exercise
        // the same read-only connection policy as production presentation
        // queries. The writer is no longer returned to the timed callsite.
        let readStore = try DatabaseStore(url: url, readOnly: true)
        return (readStore, root, largeSessionCalls)
    }

    func testBatchSummariesIncludeZeroCallSessionsAndFailureCountsStayAccurate() async throws {
        let root = try temporaryRoot("summary-contract")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("summary.sqlite"))
        let zero = TaskSummary(id: "session-zero", projectID: nil, startedAt: now, endedAt: now, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "source-zero", title: nil)
        let failed = TaskSummary(id: "session-failed", projectID: "project-a", startedAt: now, endedAt: now, status: .failed, coverage: .complete, parserVersion: "test", sourceFileID: "source-failed", title: nil)
        let failedCall = call(id: "call-failed", sessionID: failed.id, ordinal: 0, timestamp: now, resourceID: "tool:test", status: .failed)
        try await store.replaceSession(PersistedSessionBatch(session: zero, calls: [], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        try await store.replaceSession(PersistedSessionBatch(session: failed, calls: [failedCall], tokenSnapshots: [], quotaSnapshots: [], findings: []))

        let summaries = try await store.fetchTaskCallSummaries()
        XCTAssertEqual(summaries.first(where: { $0.taskID == zero.id })?.callCount, 0)
        XCTAssertEqual(summaries.first(where: { $0.taskID == failed.id })?.callCount, 1)
        XCTAssertEqual(summaries.first(where: { $0.taskID == failed.id })?.failureCount, 1)
        let usage = try await store.fetchResourceUsageStats()
        XCTAssertEqual(usage.first(where: { $0.resourceID == "tool:test" })?.failureCount, 1)
    }

    func testQuotaOverviewReleaseScaleTwentySamples() async throws {
        try requireHeavyPerformanceRun()
        let (writer, root) = try await makeQuotaStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("quota.sqlite"), readOnly: true)
        print("[quota-perf] configuration=\(buildConfiguration) mode=readonly writerCommitted=true sqlite=\(String(cString: sqlite3_libversion())) clock=ContinuousClock")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let window = CapabilityQueryWindow.recent7(now: now, calendar: calendar)
        let warm = try await store.fetchQuotaOverview(window: window)
        XCTAssertEqual(warm.sources.count, 2)
        XCTAssertTrue(warm.sources.allSatisfy { $0.daily.count == 7 })
        let plan = try quotaPlan(at: root, window: window)
        print("[quota-plan] mode=readonly steps=\(plan.count) details=\(plan.joined(separator: " | "))")

        var samples: [TimeInterval] = []
        samples.reserveCapacity(20)
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let value = try await store.fetchQuotaOverview(window: window)
            samples.append(elapsed(start, ContinuousClock.now))
            XCTAssertEqual(value.sources.count, 2)
        }
        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        let max = samples.max() ?? 0
        print("[quota-perf] rows=200000 sources=2 recent=~8000 samples=20 p50=\(p50)s p95=\(p95)s max=\(max)s")
        XCTAssertLessThanOrEqual(p95, 0.5, "200k quota p95 exceeded the approved 0.5s gate")
        _ = writer
    }

    func testQuotaOverviewMillionRowsPressureTwentySamples() async throws {
        try requireHeavyPerformanceRun()
        let (writer, root) = try await makeQuotaStore(totalRows: 1_000_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DatabaseStore(url: root.appendingPathComponent("quota.sqlite"), readOnly: true)
        print("[quota-pressure] configuration=\(buildConfiguration) mode=readonly writerCommitted=true sqlite=\(String(cString: sqlite3_libversion())) clock=ContinuousClock")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let window = CapabilityQueryWindow.recent7(now: now, calendar: calendar)
        let warm = try await store.fetchQuotaOverview(window: window)
        XCTAssertEqual(warm.sources.count, 2)
        XCTAssertTrue(warm.sources.allSatisfy { $0.daily.count == 7 })

        var samples: [TimeInterval] = []
        samples.reserveCapacity(20)
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let value = try await store.fetchQuotaOverview(window: window)
            samples.append(elapsed(start, ContinuousClock.now))
            XCTAssertEqual(value.sources.count, 2)
        }
        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        let max = samples.max() ?? 0
        print("[quota-pressure] rows=1000000 sources=2 recent=~8000 samples=20 p50=\(p50)s p95=\(p95)s max=\(max)s")
        _ = writer
    }

    func testCallSummaryAndPluginAttributionReleaseScaleTwentySamples() async throws {
        try requireHeavyPerformanceRun()
        let (store, root, largeSessionCalls) = try await makeCallStore()
        defer { try? FileManager.default.removeItem(at: root) }
        print("[call-perf] configuration=\(buildConfiguration) mode=readonly sqlite=\(String(cString: sqlite3_libversion())) clock=ContinuousClock")
        let window = CapabilityQueryWindow(start: now.addingTimeInterval(-86_400), end: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let warmSummaries = try await store.fetchTaskCallSummaries()
        XCTAssertEqual(warmSummaries.count, 1_500)
        XCTAssertEqual(warmSummaries.reduce(0) { $0 + $1.callCount }, 160_000)
        XCTAssertEqual(warmSummaries.reduce(0) { $0 + $1.failureCount }, 2)
        let warmPlugins = try await store.fetchPluginUsageStats(window: window)
        let unsupported = try XCTUnwrap(warmPlugins.first(where: { $0.pluginID == "plugin:unsupported" }))
        XCTAssertNil(unsupported.callCount)
        XCTAssertGreaterThan(warmPlugins.first(where: { $0.pluginID == "plugin:performance" })?.callCount ?? 0, 0)
        let ambiguousA = try XCTUnwrap(warmPlugins.first(where: { $0.pluginID == "plugin:ambiguous-a" }))
        let ambiguousB = try XCTUnwrap(warmPlugins.first(where: { $0.pluginID == "plugin:ambiguous-b" }))
        XCTAssertNil(ambiguousA.callCount)
        XCTAssertNil(ambiguousB.callCount)
        let performancePage = try await store.fetchPluginInvocations(pluginID: "plugin:performance", window: window, pageSize: 200)
        XCTAssertFalse(performancePage.items.contains { item in
            item.original.resourceID == "skill:ambiguous-child" || item.original.resourceID == "tool:mcp__ambiguous__read"
        })

        var summarySamples: [TimeInterval] = []
        var pluginSamples: [TimeInterval] = []
        for _ in 0..<20 {
            var start = ContinuousClock.now
            let summaries = try await store.fetchTaskCallSummaries()
            summarySamples.append(elapsed(start, ContinuousClock.now))
            XCTAssertEqual(summaries.reduce(0) { $0 + $1.callCount }, 160_000)
            XCTAssertEqual(summaries.reduce(0) { $0 + $1.failureCount }, 2)
            start = ContinuousClock.now
            let plugins = try await store.fetchPluginUsageStats(window: window)
            pluginSamples.append(elapsed(start, ContinuousClock.now))
            let unsupported = try XCTUnwrap(plugins.first(where: { $0.pluginID == "plugin:unsupported" }))
            XCTAssertNil(unsupported.callCount)
        }
        let summaryP50 = percentile(summarySamples, 0.50)
        let summaryP95 = percentile(summarySamples, 0.95)
        let pluginP50 = percentile(pluginSamples, 0.50)
        let pluginP95 = percentile(pluginSamples, 0.95)
        print("[call-perf] rows=160000 sessions=1500 largeSession=\(largeSessionCalls) samples=20 summaryP50=\(summaryP50)s summaryP95=\(summaryP95)s summaryMax=\(summarySamples.max() ?? 0)s pluginP50=\(pluginP50)s pluginP95=\(pluginP95)s pluginMax=\(pluginSamples.max() ?? 0)s")
    }
}
