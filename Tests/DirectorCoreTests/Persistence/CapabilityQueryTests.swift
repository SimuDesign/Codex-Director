import XCTest
@testable import DirectorCore

/// Query contracts behind the Capabilities destination.
final class CapabilityQueryTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() async throws -> DatabaseStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-caps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try DatabaseStore(url: directory.appendingPathComponent("test.sqlite"))
    }

    func testResourceUsageStatsAggregation() async throws {
        let store = try await makeStore()
        let batch = PersistedSessionBatch(
            session: TaskSummary(id: "s1", projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1.0.0", sourceFileID: "f1", title: nil),
            calls: [
                InvocationEvent(id: "c1", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: 1, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "c2", sessionID: "s1", parentCallID: nil, ordinal: 1, timestamp: epoch.addingTimeInterval(1), actorName: nil, resourceID: "tool:read", kind: .tool, status: .failed, durationMs: 1, confidence: .exact, errorCategory: "exit_1"),
                InvocationEvent(id: "c3", sessionID: "s1", parentCallID: nil, ordinal: 2, timestamp: epoch.addingTimeInterval(2), actorName: nil, resourceID: "tool:write", kind: .tool, status: .completed, durationMs: 1, confidence: .exact, errorCategory: nil),
            ],
            tokenSnapshots: [],
            quotaSnapshots: [],
            findings: []
        )
        try await store.replaceSession(batch)
        let stats = try await store.fetchResourceUsageStats()
        XCTAssertEqual(stats.count, 2)
        let read = stats.first { $0.resourceID == "tool:read" }
        XCTAssertEqual(read?.callCount, 2)
        XCTAssertEqual(read?.failureCount, 1)
        XCTAssertEqual(read?.lastUsedAt, epoch.addingTimeInterval(1))
        let write = stats.first { $0.resourceID == "tool:write" }
        XCTAssertEqual(write?.callCount, 1)
        XCTAssertEqual(write?.failureCount, 0)
    }

    func testRecentSevenUsesInjectedGregorianTimezoneAndIncludesNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-08-28T00:30:00Z")!
        let window = CapabilityQueryWindow.recent7(now: now, calendar: calendar)
        XCTAssertEqual(window.timeZoneIdentifier, calendar.timeZone.identifier)
        XCTAssertEqual(window.end, now)
        XCTAssertEqual(window.start, ISO8601DateFormatter().date(from: "2026-08-21T16:00:00Z")!)
    }

    func testRecentThirtyUsesLocalNaturalDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-08-30T00:30:00Z")!
        let window = CapabilityQueryWindow.recent30(now: now, calendar: calendar)
        XCTAssertEqual(window.timeZoneIdentifier, calendar.timeZone.identifier)
        XCTAssertEqual(window.start, ISO8601DateFormatter().date(from: "2026-07-31T16:00:00Z")!)
        XCTAssertEqual(window.end, now)
    }

    func testCapabilityStatsWindowAndKeysetPaging() async throws {
        let store = try await makeStore()
        let calls = (0..<3).map { index in
            InvocationEvent(id: "call-\(index)", sessionID: "s1", parentCallID: nil, ordinal: index,
                timestamp: epoch.addingTimeInterval(Double(index)), actorName: nil, resourceID: "skill:x",
                kind: .skill, status: .completed, durationMs: nil,
                confidence: index == 1 ? .inferred : .exact, errorCategory: nil)
        }
        try await store.replaceSession(PersistedSessionBatch(
            session: TaskSummary(id: "s1", projectID: "p1", startedAt: epoch, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "f1", title: nil),
            calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let window = CapabilityQueryWindow(start: epoch, end: epoch.addingTimeInterval(2), timeZone: TimeZone(secondsFromGMT: 0)!)
        let stats = try await store.fetchCapabilityUsageStats(window: window, projectID: "p1")
        XCTAssertEqual(stats.first?.callCount, 3)
        XCTAssertEqual(stats.first?.inferredCount, 1)
        let first = try await store.fetchCapabilityInvocations(resourceID: "skill:x", projectID: "p1", window: nil, pageSize: 2)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertNotNil(first.nextCursor)
        let second = try await store.fetchCapabilityInvocations(resourceID: "skill:x", projectID: "p1", window: nil, pageSize: 2, cursor: first.nextCursor)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertEqual(Set(first.items.map(\.id)).intersection(second.items.map(\.id)).count, 0)
    }

    func testCatalogUsesCurrentRuntimeIdentityAndLeavesAmbiguousParentsUnlinked() {
        let now = Date()
        func resource(_ id: String, kind: ResourceKind, scope: ResourceScope, ownership: ResourceOwnership, origin: ResourceOrigin) -> CapabilityResource {
            CapabilityResource(id: id, name: "same", kind: kind, status: .idle, scope: scope, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "root", relativeSourcePath: "same", sourcePathHash: nil, lastSeenAt: now, ownership: ownership, origin: origin)
        }
        let currentPlugin = resource("plugin-current", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime)
        let oldPlugin = resource("plugin-cache", kind: .plugin, scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let child = resource("skill-child", kind: .skill, scope: .runtime, ownership: .pluginProvided, origin: .plugin)
        let staleChild = resource("skill-cache", kind: .skill, scope: .plugin, ownership: .pluginProvided, origin: .plugin)
        let relations = [
            ResourceRelation(sourceResourceID: currentPlugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: oldPlugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        ]
        let catalog = CapabilityCatalog(resources: [currentPlugin, oldPlugin, child, staleChild], relations: relations)
        XCTAssertEqual(catalog.entries.first(where: { $0.resource.id == currentPlugin.id })?.category, .installedPlugins)
        XCTAssertNil(catalog.entries.first(where: { $0.resource.id == oldPlugin.id })?.category)
        XCTAssertEqual(catalog.entries.first(where: { $0.resource.id == child.id })?.category, .installedSkills)
        XCTAssertEqual(catalog.entries.first(where: { $0.resource.id == child.id })?.parentPluginID, currentPlugin.id)
        XCTAssertNil(catalog.entries.first(where: { $0.resource.id == staleChild.id })?.category)
    }

    func testCatalogExcludesUnlinkedPluginCacheAndKeepsDisabledCurrentPlugin() {
        let now = Date()
        func r(_ id: String, _ kind: ResourceKind, _ scope: ResourceScope, _ ownership: ResourceOwnership, _ origin: ResourceOrigin, _ project: String? = nil, status: RuntimeStatus = .idle) -> CapabilityResource {
            CapabilityResource(id: id, name: "same", kind: kind, status: status, scope: scope, projectID: project, confidence: .exact, summary: nil, sourceRootID: "root", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: now, ownership: ownership, origin: origin)
        }
        let p = r("P", .plugin, .runtime, .runtime, .runtime)
        let d = r("D", .plugin, .runtime, .runtime, .runtime, status: .blocked)
        let c = r("C", .plugin, .plugin, .pluginProvided, .plugin)
        let ps = r("PS", .skill, .runtime, .pluginProvided, .plugin)
        let cs = r("CS", .skill, .plugin, .pluginProvided, .plugin)
        let u = r("U", .skill, .plugin, .pluginProvided, .plugin)
        let i = r("I", .skill, .global, .installed, .registry)
        let b = r("B", .skill, .system, .builtIn, .codexSystem)
        let a = r("A", .agent, .global, .userOwned, .local)
        let a2 = r("A2", .agent, .project, .userOwned, .local, "project")
        let rel = ResourceRelation(sourceResourceID: p.id, targetResourceID: ps.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let ambiguous = ResourceRelation(sourceResourceID: d.id, targetResourceID: ps.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        let catalog = CapabilityCatalog(resources: [p, d, c, ps, cs, u, i, b, a, a2], relations: [rel, ambiguous])
        XCTAssertEqual(Set(catalog.entries.compactMap { $0.category == .installedPlugins ? $0.resource.id : nil }), ["P", "D"])
        XCTAssertEqual(catalog.entries.first(where: { $0.resource.id == "D" })?.resource.status, .blocked)
        XCTAssertEqual(Set(catalog.entries.compactMap { $0.category == .installedSkills ? $0.resource.id : nil }), ["I"])
        XCTAssertEqual(Set(catalog.entries.compactMap { $0.category == .customAgents ? $0.resource.id : nil }), ["A", "A2"])
        XCTAssertTrue(catalog.entries.allSatisfy { $0.resource.id != "PS" || $0.parentPluginID == nil })
    }

    func testResourceUsageStatsSeparateTerminalUnresolvedAndEvidenceLimitedCalls() async throws {
        let store = try await makeStore()
        let completeCalls: [InvocationEvent] = [
            InvocationEvent(id: "completed", sessionID: "complete", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "failed", sessionID: "complete", parentCallID: nil, ordinal: 1, timestamp: epoch.addingTimeInterval(1), actorName: nil, resourceID: "agent:a", kind: .agent, status: .failed, durationMs: nil, confidence: .exact, errorCategory: "synthetic"),
            InvocationEvent(id: "interrupted", sessionID: "complete", parentCallID: nil, ordinal: 2, timestamp: epoch.addingTimeInterval(2), actorName: nil, resourceID: "agent:a", kind: .agent, status: .interrupted, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "retried", sessionID: "complete", parentCallID: nil, ordinal: 3, timestamp: epoch.addingTimeInterval(3), actorName: nil, resourceID: "agent:a", kind: .agent, status: .retried, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "inferred", sessionID: "complete", parentCallID: nil, ordinal: 4, timestamp: epoch.addingTimeInterval(4), actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil),
        ]
        let partialCalls: [InvocationEvent] = [
            InvocationEvent(id: "started", sessionID: "partial", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "agent:a", kind: .agent, status: .started, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "unknown", sessionID: "partial", parentCallID: nil, ordinal: 1, timestamp: epoch.addingTimeInterval(1), actorName: nil, resourceID: "agent:a", kind: .agent, status: .unknown, durationMs: nil, confidence: .exact, errorCategory: nil),
        ]
        for (id, coverage, calls) in [("complete", CoverageState.complete, completeCalls), ("partial", CoverageState.partial, partialCalls)] {
            try await store.replaceSession(PersistedSessionBatch(
                session: TaskSummary(id: id, projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: coverage, parserVersion: "1.0.0", sourceFileID: "file-\(id)", title: nil),
                calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []
            ))
        }
        let stats = try await store.fetchResourceUsageStats()
        let stat = try XCTUnwrap(stats.first { $0.resourceID == "agent:a" })
        XCTAssertEqual(stat.callCount, 7)
        XCTAssertEqual(stat.completedCount, 2)
        XCTAssertEqual(stat.failureCount, 2)
        XCTAssertEqual(stat.unresolvedCount, 2)
        XCTAssertEqual(stat.evidenceLimitedCount, 3) // inferred + the two calls from the partial session
        XCTAssertEqual(stat.completedCount + stat.failureCount, 4)
    }

    func testRelationsRoundTripAndOneHopQuery() async throws {
        let store = try await makeStore()
        let relations = [
            ResourceRelation(sourceResourceID: "agent:a", targetResourceID: "skill:b", relationKind: "uses", confidence: .inferred, evidenceSummary: "brief"),
            ResourceRelation(sourceResourceID: "skill:b", targetResourceID: "tool:c", relationKind: "invokes", confidence: .exact, evidenceSummary: nil),
        ]
        try await store.insertRelations(relations)
        let all = try await store.fetchAllRelations()
        XCTAssertEqual(all.count, 2)
        let oneHop = try await store.fetchRelations(for: "skill:b")
        XCTAssertEqual(oneHop.count, 2)
        XCTAssertEqual(Set(oneHop.map(\.relationKind)), ["uses", "invokes"])
    }

    func testAllTokenSnapshotsQuery() async throws {
        let store = try await makeStore()
        let usage = try TokenUsage(inputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1, coverage: .complete)
        let batch = PersistedSessionBatch(
            session: TaskSummary(id: "s1", projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1.0.0", sourceFileID: "f1", title: nil),
            calls: [],
            tokenSnapshots: [
                TokenUsageSnapshot(id: "t1", sessionID: "s1", capturedAt: epoch, usage: usage),
                TokenUsageSnapshot(id: "t2", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60), usage: usage),
            ],
            quotaSnapshots: [],
            findings: []
        )
        try await store.replaceSession(batch)
        let snapshots = try await store.fetchAllTokenSnapshots()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.map(\.capturedAt), [epoch, epoch.addingTimeInterval(60)])
    }
}
