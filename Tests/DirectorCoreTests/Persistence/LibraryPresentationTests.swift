import XCTest
@testable import DirectorCore

/// Regression coverage for the bounded library projection.  Every fixture is
/// UUID-scoped temporary data; no production preferences, sessions, or
/// databases are consulted.
final class LibraryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryStore() throws -> DatabaseStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try DatabaseStore(url: root.appendingPathComponent("index.sqlite"))
    }

    private func resource(
        _ id: String,
        kind: ResourceKind = .agent,
        scope: ResourceScope = .global,
        projectID: String? = nil,
        ownership: ResourceOwnership = .userOwned,
        origin: ResourceOrigin = .local,
        sourceRootID: String = "test-root",
        name: String = "Synthetic resource"
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: kind,
            status: .success,
            scope: scope,
            projectID: projectID,
            confidence: .exact,
            summary: "Synthetic test resource",
            sourceRootID: sourceRootID,
            relativeSourcePath: id,
            sourcePathHash: "hash-\(id)",
            lastSeenAt: now,
            ownership: ownership,
            origin: origin
        )
    }

    private func record(
        _ store: DatabaseStore,
        id: String,
        resourceID: String,
        timestamp: Date,
        projectID: String?,
        kind: InvocationKind = .agent,
        actorName: String? = nil
    ) async throws {
        let sessionID = "session:\(id)"
        let session = TaskSummary(
            id: sessionID,
            projectID: projectID,
            startedAt: timestamp,
            endedAt: nil,
            status: .completed,
            coverage: .complete,
            parserVersion: "library-test",
            sourceFileID: "source:\(id)",
            title: nil
        )
        let call = InvocationEvent(
            id: "call:\(id)",
            sessionID: sessionID,
            parentCallID: nil,
            ordinal: 0,
            timestamp: timestamp,
            actorName: actorName,
            resourceID: resourceID,
            kind: kind,
            status: .completed,
            durationMs: nil,
            confidence: .exact,
            errorCategory: nil
        )
        try await store.replaceSession(PersistedSessionBatch(
            session: session,
            calls: [call],
            tokenSnapshots: [],
            quotaSnapshots: [],
            findings: []
        ))
    }

    private func window(startOffset: TimeInterval = -7 * 86_400) -> CapabilityQueryWindow {
        CapabilityQueryWindow(
            start: now.addingTimeInterval(startOffset),
            end: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    func testRawUsageIDsAndHistorySurviveCategoryProjectionAndFutureCutoff() async throws {
        let store = try temporaryStore()
        let agentA = resource("agent:stable-a", name: "Stable A")
        let agentB = resource("agent:stable-b", name: "Stable B")
        let unassociated = resource("agent:unassociated", name: "Unassociated")
        let old = resource("agent:old-only", name: "Old only")
        let unused = resource("agent:unused", name: "Unused")
        let reclassifiedSkill = resource(
            "skill:reclassified",
            kind: .skill,
            ownership: .userOwned,
            origin: .local,
            name: "Reclassified skill"
        )
        try await store.replaceResourceInventory(resources: [agentA, agentB, unassociated, old, unused, reclassifiedSkill])

        for index in 0..<3 {
            try await record(store, id: "a-\(index)", resourceID: agentA.id, timestamp: now.addingTimeInterval(Double(-60 - index)), projectID: "project:a")
        }
        try await record(store, id: "b-1", resourceID: agentB.id, timestamp: now.addingTimeInterval(-240), projectID: "project:b")
        try await record(store, id: "unassociated-1", resourceID: unassociated.id, timestamp: now.addingTimeInterval(-300), projectID: nil)
        try await record(store, id: "old-1", resourceID: old.id, timestamp: now.addingTimeInterval(-8 * 86_400), projectID: "project:a")
        try await record(store, id: "skill-1", resourceID: reclassifiedSkill.id, timestamp: now.addingTimeInterval(-120), projectID: nil, kind: .skill)
        try await record(store, id: "future-a", resourceID: agentA.id, timestamp: now.addingTimeInterval(60), projectID: "project:a")

        let customSkills = try await store.fetchLibraryPresentation(category: .customSkills, window: window())
        let installedSkills = try await store.fetchLibraryPresentation(category: .installedSkills, window: window())

        let expectedRecentIDs: Set<String> = [agentA.id, agentB.id, unassociated.id, reclassifiedSkill.id]
        let customSkillRecentIDs = Set(customSkills.categoryUsage.map(\.resourceID))
        let installedSkillRecentIDs = Set(installedSkills.categoryUsage.map(\.resourceID))
        XCTAssertEqual(customSkillRecentIDs, expectedRecentIDs)
        XCTAssertEqual(installedSkillRecentIDs, expectedRecentIDs)
        let agentAStats = customSkills.categoryUsage.first { $0.resourceID == agentA.id }
        let agentBStats = customSkills.categoryUsage.first { $0.resourceID == agentB.id }
        let unassociatedStats = customSkills.categoryUsage.first { $0.resourceID == unassociated.id }
        XCTAssertEqual(agentAStats?.callCount, 3)
        XCTAssertEqual(agentBStats?.callCount, 1)
        XCTAssertEqual(unassociatedStats?.callCount, 1)
        XCTAssertFalse(customSkillRecentIDs.contains(unused.id))
        XCTAssertFalse(customSkillRecentIDs.contains(old.id))

        XCTAssertEqual(customSkills.categoryUsage, installedSkills.categoryUsage)
        XCTAssertEqual(customSkills.browseUsage, customSkills.categoryUsage)
        XCTAssertEqual(customSkills.browseHistory, installedSkills.browseHistory)
        XCTAssertTrue(customSkills.categoryPluginUsage.isEmpty)
        XCTAssertTrue(customSkills.browsePluginUsage.isEmpty)

        let oldHistory = customSkills.browseHistory.first { $0.resourceID == old.id }
        XCTAssertEqual(oldHistory?.callCount, 1)
        XCTAssertEqual(oldHistory?.lastUsedAt, now.addingTimeInterval(-8 * 86_400))
        XCTAssertFalse(customSkills.browseHistory.contains { $0.resourceID == unused.id })
        XCTAssertFalse(customSkills.browseHistory.contains { $0.resourceID == agentA.id && $0.callCount == 4 })
        XCTAssertEqual(customSkills.usageProjects[agentA.id], Set(["project:a"]))
        XCTAssertEqual(customSkills.usageProjects[agentB.id], Set(["project:b"]))
        XCTAssertNil(customSkills.usageProjects[unassociated.id])
    }

    func testInstalledPluginUsesAttributedAllTimeHistoryAndGlobalMembership() async throws {
        let store = try temporaryStore()
        let plugin = resource("plugin:current", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins", name: "Current plugin")
        let child = resource("skill:current-child", kind: .skill, scope: .plugin, ownership: .pluginProvided, origin: .plugin, sourceRootID: "runtime-plugins:current", name: "Current child")
        let mcp = resource("mcp:current", kind: .mcp, scope: .plugin, ownership: .pluginProvided, origin: .plugin, sourceRootID: "runtime-plugins:current", name: "current_server")
        let unsupported = resource("plugin:unsupported", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins", name: "Unsupported plugin")
        try await store.replaceResourceInventory(
            resources: [plugin, child, mcp, unsupported],
            relations: [
                ResourceRelation(sourceResourceID: plugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil),
                ResourceRelation(sourceResourceID: plugin.id, targetResourceID: mcp.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)
            ]
        )

        try await record(store, id: "child-a-old", resourceID: child.id, timestamp: now.addingTimeInterval(-8 * 86_400), projectID: "project:a", kind: .skill)
        try await record(store, id: "namespace-b-old", resourceID: "tool:mcp__current_server__read", timestamp: now.addingTimeInterval(-9 * 86_400), projectID: "project:b", kind: .tool)
        try await record(store, id: "raw-parent-now", resourceID: plugin.id, timestamp: now, projectID: "project:a", kind: .tool, actorName: "plugin-wrapper")
        try await record(store, id: "unsupported-parent-now", resourceID: unsupported.id, timestamp: now, projectID: "project:b", kind: .tool, actorName: "plugin-wrapper")
        try await record(store, id: "child-future", resourceID: child.id, timestamp: now.addingTimeInterval(60), projectID: "project:c", kind: .skill)

        let global = try await store.fetchLibraryPresentation(category: .installedPlugins, window: window())
        let projectA = try await store.fetchLibraryPresentation(category: .installedPlugins, window: window(), projectID: "project:a")

        let currentRecent = global.categoryPluginUsage.first { $0.pluginID == plugin.id }
        let unsupportedRecent = global.categoryPluginUsage.first { $0.pluginID == unsupported.id }
        XCTAssertEqual(currentRecent?.callCount, 0)
        XCTAssertEqual(currentRecent?.projectIDs, [])
        XCTAssertNil(unsupportedRecent?.callCount)
        XCTAssertNil(unsupportedRecent?.lastUsedAt)
        XCTAssertTrue(unsupportedRecent?.projectIDs.isEmpty == true)

        let currentHistory = global.browseHistory.first { $0.resourceID == plugin.id }
        XCTAssertEqual(currentHistory?.callCount, 2)
        XCTAssertEqual(currentHistory?.lastUsedAt, now.addingTimeInterval(-8 * 86_400))
        XCTAssertFalse(global.browseHistory.contains { $0.resourceID == unsupported.id })
        XCTAssertEqual(global.usageProjects[plugin.id], Set(["project:a", "project:b"]))
        XCTAssertNil(global.usageProjects[unsupported.id])
        XCTAssertEqual(global.browseUsage, global.categoryUsage)
        XCTAssertEqual(global.browsePluginUsage, global.categoryPluginUsage)

        let projectCurrentRecent = projectA.browsePluginUsage.first { $0.pluginID == plugin.id }
        XCTAssertEqual(projectCurrentRecent?.callCount, 0)
        let projectHistory = projectA.browseHistory.first { $0.resourceID == plugin.id }
        XCTAssertEqual(projectHistory?.callCount, 1)
        XCTAssertEqual(projectHistory?.lastUsedAt, now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(projectA.usageProjects[plugin.id], Set(["project:a", "project:b"]))
        XCTAssertNil(projectA.browseHistory.first { $0.resourceID == unsupported.id })
    }

    func testNonPluginCategoryDoesNotReturnPluginAttribution() async throws {
        let store = try temporaryStore()
        let plugin = resource("plugin:nonplugin-check", kind: .plugin, scope: .runtime, ownership: .runtime, origin: .runtime, sourceRootID: "runtime-plugins")
        let child = resource("skill:nonplugin-child", kind: .skill, scope: .plugin, ownership: .pluginProvided, origin: .plugin, sourceRootID: "runtime-plugins:nonplugin-check")
        let agent = resource("agent:nonplugin-check")
        try await store.replaceResourceInventory(
            resources: [plugin, child, agent],
            relations: [ResourceRelation(sourceResourceID: plugin.id, targetResourceID: child.id, relationKind: "contains", confidence: .exact, evidenceSummary: nil)]
        )
        try await record(store, id: "child", resourceID: child.id, timestamp: now.addingTimeInterval(-60), projectID: "project:a", kind: .skill)
        try await record(store, id: "parent", resourceID: plugin.id, timestamp: now.addingTimeInterval(-30), projectID: "project:a", kind: .tool)

        let snapshot = try await store.fetchLibraryPresentation(category: .customAgents, window: window())
        XCTAssertTrue(snapshot.categoryPluginUsage.isEmpty)
        XCTAssertTrue(snapshot.browsePluginUsage.isEmpty)
        XCTAssertFalse(snapshot.browseHistory.contains { $0.resourceID == plugin.id })
        XCTAssertTrue(snapshot.browseHistory.contains { $0.resourceID == child.id })
        XCTAssertNil(snapshot.usageProjects[plugin.id])
    }

    func testThirtyDayUsageUsesNaturalBoundaryAndExcludesFuture() async throws {
        let store = try temporaryStore()
        let agent = resource("agent:thirty-day", name: "Thirty Day Agent")
        try await store.replaceResourceInventory(resources: [agent])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let thirty = CapabilityQueryWindow.recent30(now: now, calendar: calendar)
        try await record(store, id: "at-start", resourceID: agent.id, timestamp: thirty.start, projectID: nil)
        try await record(store, id: "before-start", resourceID: agent.id, timestamp: thirty.start.addingTimeInterval(-1), projectID: nil)
        try await record(store, id: "future", resourceID: agent.id, timestamp: now.addingTimeInterval(1), projectID: nil)

        let browseWindow = CapabilityQueryWindow(start: now.addingTimeInterval(-7 * 86_400), end: now, timeZone: calendar.timeZone)
        let snapshot = try await store.fetchLibraryPresentation(category: .customAgents, window: browseWindow)
        let usage = try XCTUnwrap(snapshot.category30DayUsage.first { $0.resourceID == agent.id })
        XCTAssertEqual(usage.callCount, 1)
        XCTAssertEqual(usage.inferredCount, 0)
    }
}
