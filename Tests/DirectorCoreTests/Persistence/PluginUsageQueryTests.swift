import XCTest
@testable import DirectorCore

final class PluginUsageQueryTests: XCTestCase {
    private func resource(_ id: String, _ kind: ResourceKind, _ scope: ResourceScope = .runtime, _ name: String = "x", _ origin: ResourceOrigin = .runtime) -> CapabilityResource {
        CapabilityResource(id: id, name: name, kind: kind, status: .idle, scope: scope, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: Date(), ownership: kind == .plugin ? .runtime : (kind == .skill ? .pluginProvided : .runtime), origin: origin)
    }

    private func store(_ resources: [CapabilityResource], _ relations: [ResourceRelation] = []) async throws -> DatabaseStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-query-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try DatabaseStore(url: dir.appendingPathComponent("index.sqlite"))
        try await store.replaceResourceInventory(resources: resources, relations: relations)
        return store
    }
    func testUnsupportedAndSupportedZeroPluginResults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-query-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try DatabaseStore(url: dir.appendingPathComponent("index.sqlite"))
        let now = Date()
        let plugin = CapabilityResource(id: "plugin", name: "p", kind: .plugin, status: .idle, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime-plugins", relativeSourcePath: "plugins/p", sourcePathHash: nil, lastSeenAt: now, ownership: .runtime, origin: .runtime)
        let skill = CapabilityResource(id: "skill", name: "s", kind: .skill, status: .idle, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime-plugins:p", relativeSourcePath: "plugins/p/skills/s/SKILL.md", sourcePathHash: nil, lastSeenAt: now, ownership: .pluginProvided, origin: .plugin)
        try await store.replaceResourceInventory(resources: [plugin, skill], relations: [ResourceRelation(sourceResourceID: "plugin", targetResourceID: "skill", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let results = try await store.fetchPluginUsageStats(window: CapabilityQueryWindow(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)))
        XCTAssertEqual(results.first?.pluginID, "plugin")
        XCTAssertEqual(results.first?.callCount, 0)
    }

    func testNamespaceRequiresNonEmptySuffixAndReadConfidenceIsPreserved() async throws {
        let p = resource("p", .plugin), m = resource("m", .mcp, .plugin, "server")
        let s = try await store([p, m], [ResourceRelation(sourceResourceID: "p", targetResourceID: "m", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let now = Date()
        let calls = ["tool:mcp__server__", "tool:mcp__server__read"].enumerated().map { i, id in
            InvocationEvent(id: "c\(i)", sessionID: "s", parentCallID: nil, ordinal: i, timestamp: now, actorName: nil, resourceID: id, kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        }
        try await s.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "s", projectID: "A", startedAt: now, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "f", title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let result = try await s.fetchPluginUsageStats(window: CapabilityQueryWindow(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1))).first
        XCTAssertEqual(result?.callCount, 1)
        XCTAssertEqual(result?.inferredCount, 1)
    }

    func testNamespaceCollisionAndIndependentMCPAreUnsupported() async throws {
        let p1 = resource("p1", .plugin), p2 = resource("p2", .plugin)
        let m1 = resource("m1", .mcp, .plugin, "same"), m2 = resource("m2", .mcp, .plugin, "same")
        let store = try await store([p1, p2, m1, m2], [
            ResourceRelation(sourceResourceID: "p1", targetResourceID: "m1", relationKind: "contains", confidence: .exact, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: "p2", targetResourceID: "m2", relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        ])
        let stats = try await store.fetchPluginUsageStats(window: CapabilityQueryWindow(start: Date(timeIntervalSince1970: 0), end: Date()))
        XCTAssertTrue(stats.allSatisfy { $0.callCount == nil })
    }

    func testIndependentCurrentMCPAlsoInvalidatesOtherwiseUniqueNamespace() async throws {
        let p = resource("p", .plugin)
        let linked = resource("linked", .mcp, .plugin, "solo")
        let independent = resource("independent", .mcp, .runtime, "solo")
        let store = try await store([p, linked, independent], [
            ResourceRelation(sourceResourceID: "p", targetResourceID: "linked", relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        ])
        let stats = try await store.fetchPluginUsageStats(window: CapabilityQueryWindow(start: Date(timeIntervalSince1970: 0), end: Date()))
        XCTAssertEqual(stats.first?.pluginID, "p")
        XCTAssertNil(stats.first?.callCount)
    }

    func testNamespaceUsesLiteralUnderscoreBoundary() async throws {
        let p = resource("p", .plugin), m = resource("m", .mcp, .plugin, "my_server")
        let store = try await store([p, m], [ResourceRelation(sourceResourceID: "p", targetResourceID: "m", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let t = Date()
        let calls = [
            InvocationEvent(id: "exact", sessionID: "s", parentCallID: nil, ordinal: 0, timestamp: t, actorName: nil, resourceID: "tool:mcp__my_server__read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "near", sessionID: "s", parentCallID: nil, ordinal: 1, timestamp: t, actorName: nil, resourceID: "tool:mcp__my_serverX__read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        ]
        try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "s", projectID: "A", startedAt: t, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "f", title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let stats = try await store.fetchPluginUsageStats(window: CapabilityQueryWindow(start: t.addingTimeInterval(-1), end: t.addingTimeInterval(1)))
        XCTAssertEqual(stats.first?.callCount, 1)
    }

    func testUnsupportedNilAndSupportedZeroAreDistinct() async throws {
        let supported = resource("supported", .plugin)
        let skill = resource("skill", .skill, .plugin, "s", .plugin)
        let unsupported = resource("unsupported", .plugin)
        let store = try await store([supported, skill, unsupported], [ResourceRelation(sourceResourceID: "supported", targetResourceID: "skill", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let stats = try await store.fetchPluginUsageStats(window: CapabilityQueryWindow(start: Date(timeIntervalSince1970: 0), end: Date()))
        XCTAssertEqual(stats.first(where: { $0.pluginID == "supported" })?.callCount, 0)
        XCTAssertNil(stats.first(where: { $0.pluginID == "unsupported" })?.callCount)
    }

    func testPagingProjectFilterAndSummaryDetailEquality() async throws {
        let p = resource("p", .plugin), skill = resource("skill", .skill, .plugin, "s", .plugin)
        let store = try await store([p, skill], [ResourceRelation(sourceResourceID: "p", targetResourceID: "skill", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var calls: [InvocationEvent] = []
        for i in 0..<7 {
            calls.append(InvocationEvent(id: "c\(i)", sessionID: i % 2 == 0 ? "a" : "b", parentCallID: nil, ordinal: i, timestamp: base.addingTimeInterval(Double(i)), actorName: nil, resourceID: "skill", kind: .skill, status: .completed, durationMs: nil, confidence: i == 1 ? .inferred : .exact, errorCategory: nil))
        }
        // This late event is outside the shared window and must not affect either path.
        calls.append(InvocationEvent(id: "late", sessionID: "a", parentCallID: nil, ordinal: 8, timestamp: base.addingTimeInterval(100), actorName: nil, resourceID: "skill", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil))
        for (id, project) in [("a", "A"), ("b", "B")] {
            try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: id, projectID: project, startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "f-\(id)", title: nil), calls: calls.filter { $0.sessionID == id }, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        }
        let window = CapabilityQueryWindow(start: base.addingTimeInterval(-1), end: base.addingTimeInterval(6))
        let summaries = try await store.fetchPluginUsageStats(window: window)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.callCount, 7)
        XCTAssertEqual(summary.projectIDs, ["A", "B"])
        var cursor: String?
        var ids: [String] = []
        for _ in 0..<4 {
            let page = try await store.fetchPluginInvocations(pluginID: "p", window: window, pageSize: 2, cursor: cursor)
            ids.append(contentsOf: page.items.map { $0.original.id })
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        XCTAssertEqual(ids.count, 7)
        XCTAssertEqual(Set(ids).count, 7)
        let projectA = try await store.fetchPluginInvocations(pluginID: "p", projectID: "A", window: window, pageSize: 20)
        XCTAssertEqual(projectA.items.count, 4)
        XCTAssertEqual(projectA.items.map { $0.projectID }.allSatisfy { $0 == "A" }, true)
    }

    func testWrapperChainKeepsLeafAndProjectIDsMatchSummary() async throws {
        let p = resource("p", .plugin), skill = resource("skill", .skill, .plugin, "skill", .plugin)
        let store = try await store([p, skill], [ResourceRelation(sourceResourceID: "p", targetResourceID: "skill", relationKind: "contains", confidence: .exact, evidenceSummary: nil)])
        let t = Date()
        let calls = [
            InvocationEvent(id: "wrapper", sessionID: "s", parentCallID: nil, ordinal: 0, timestamp: t, actorName: nil, resourceID: "skill", kind: .tool, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil),
            InvocationEvent(id: "middle", sessionID: "s", parentCallID: "wrapper", ordinal: 1, timestamp: t.addingTimeInterval(1), actorName: nil, resourceID: "skill", kind: .skill, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil),
            InvocationEvent(id: "leaf", sessionID: "s", parentCallID: "middle", ordinal: 2, timestamp: t.addingTimeInterval(2), actorName: nil, resourceID: "skill", kind: .skill, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil)
        ]
        try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "s", projectID: "project-A", startedAt: t, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "f", title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let window = CapabilityQueryWindow(start: t.addingTimeInterval(-1), end: t.addingTimeInterval(3))
        let summaries = try await store.fetchPluginUsageStats(window: window)
        let summary = try XCTUnwrap(summaries.first)
        let page = try await store.fetchPluginInvocations(pluginID: "p", window: window, pageSize: 1)
        XCTAssertEqual(summary.callCount, 1)
        XCTAssertEqual(page.items.map { $0.original.id }, ["leaf"])
        XCTAssertEqual(summary.projectIDs, ["project-A"])
    }
}
