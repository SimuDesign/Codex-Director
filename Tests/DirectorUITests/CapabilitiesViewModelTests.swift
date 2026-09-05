import XCTest
@testable import DirectorUI
import DirectorCore

/// Capabilities view-model contracts: filtering, selection preservation,
/// stats mapping, and one-hop relationship lookups.
@MainActor
final class CapabilitiesViewModelTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func resource(
        _ id: String, name: String, kind: ResourceKind, scope: ResourceScope
    ) -> CapabilityResource {
        return resource(id: id, name: name, kind: kind, scope: scope, relativeSourcePath: "\(name)/SKILL.md")
    }

    private func resource(
        id: String,
        name: String,
        kind: ResourceKind,
        scope: ResourceScope,
        relativeSourcePath: String
    ) -> CapabilityResource {
        CapabilityResource(
            id: id, name: name, kind: kind, status: .unknown, scope: scope,
            projectID: nil, confidence: .exact, summary: nil,
            sourceRootID: "root", relativeSourcePath: relativeSourcePath,
            sourcePathHash: nil, lastSeenAt: epoch
        )
    }

    func testStatsMapToRowsByResourceID() {
        let stats = [
            DatabaseStore.ResourceUsageStats(resourceID: "tool:a", callCount: 5, failureCount: 1, lastUsedAt: epoch),
            DatabaseStore.ResourceUsageStats(resourceID: "tool:b", callCount: 2, failureCount: 0, lastUsedAt: nil),
        ]
        let model = CapabilitiesViewModel(
            resources: [
                resource("tool:a", name: "a", kind: .tool, scope: .runtime),
                resource("tool:b", name: "b", kind: .tool, scope: .runtime),
                resource("skill:c", name: "c", kind: .skill, scope: .global),
            ],
            stats: stats
        )
        XCTAssertEqual(model.allRows.count, 3)
        XCTAssertEqual(model.allRows[0].callCount, 5)
        XCTAssertEqual(model.allRows[0].failureCount, 1)
        XCTAssertEqual(model.allRows[0].lastUsedAt, epoch)
        XCTAssertEqual(model.allRows[2].callCount, 0)
    }

    func testOperationalRatesAndUsageFilters() {
        let stats = [
            DatabaseStore.ResourceUsageStats(resourceID: "agent:observed", callCount: 4, failureCount: 1, lastUsedAt: epoch, completedCount: 2, unresolvedCount: 1, evidenceLimitedCount: 2),
        ]
        let model = CapabilitiesViewModel(resources: [
            resource("agent:observed", name: "observed", kind: .agent, scope: .global),
            resource("skill:unobserved", name: "unobserved", kind: .skill, scope: .global),
            resource("tool:other", name: "other", kind: .tool, scope: .runtime),
        ], stats: stats)
        let row = try! XCTUnwrap(model.allRows.first { $0.id == "agent:observed" })
        XCTAssertTrue(row.isObserved)
        XCTAssertEqual(row.terminalOutcomeCount, 3)
        XCTAssertEqual(row.observedCompletionRate!, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(row.evidenceLimitedCount, 2)
        XCTAssertEqual(row.attentionState, .unresolved)

        model.usageFilter = .observed
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:observed"])
        model.usageFilter = .notObserved
        XCTAssertEqual(model.filteredRows.map(\.id).sorted(), ["skill:unobserved", "tool:other"].sorted())
        model.usageFilter = .hasFailures
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:observed"])
        model.usageFilter = .evidenceLimited
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:observed"])
        model.usageFilter = .notEvaluated
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:observed"])
    }

    func testCompletionRateIsNilWithoutTerminalOutcomes() {
        let model = CapabilitiesViewModel(resources: [resource("agent:a", name: "a", kind: .agent, scope: .global)], stats: [
            DatabaseStore.ResourceUsageStats(resourceID: "agent:a", callCount: 1, failureCount: 0, lastUsedAt: nil, completedCount: 0, unresolvedCount: 1, evidenceLimitedCount: 1)
        ])
        XCTAssertNil(model.allRows[0].observedCompletionRate)
    }

    func testReplaceDataUpdatesInPlaceAndPreservesValidFilterAndSelection() {
        let model = CapabilitiesViewModel(resources: [
            resource("agent:a", name: "a", kind: .agent, scope: .global),
            resource("skill:b", name: "b", kind: .skill, scope: .global),
        ])
        model.searchText = "a2"
        model.selectedResourceID = "agent:a"

        model.replaceData(resources: [
            resource("agent:a", name: "a2", kind: .agent, scope: .global),
            resource("skill:c", name: "c", kind: .skill, scope: .project),
        ])

        XCTAssertEqual(model.searchText, "a2")
        XCTAssertEqual(model.selectedResourceID, "agent:a")
        XCTAssertEqual(model.selectedRow?.resource.name, "a2")
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:a"])

        model.replaceData(resources: [resource("skill:c", name: "c", kind: .skill, scope: .project)])
        XCTAssertNil(model.selectedResourceID)
        XCTAssertNil(model.selectedRow)
        XCTAssertEqual(model.searchText, "a2")
    }

    func testEvaluationCountsUpdateRowsWithoutChangingSelection() {
        let model = CapabilitiesViewModel(resources: [resource("agent:a", name: "a", kind: .agent, scope: .global)])
        model.selectedResourceID = "agent:a"
        let evaluation = InvocationEvaluation(invocationID: "call:a", sessionID: "session:a", resourceID: "agent:a", label: .effective, updatedAt: epoch)

        model.setEvaluation(evaluation)

        XCTAssertEqual(model.selectedResourceID, "agent:a")
        XCTAssertEqual(model.selectedRow?.evaluatedCount, 1)
        XCTAssertEqual(model.selectedRow?.effectiveCount, 1)
        model.clearEvaluation(evaluation)
        XCTAssertEqual(model.selectedRow?.evaluatedCount, 0)
    }

    func testSearchFiltersRows() {
        let model = CapabilitiesViewModel(resources: [
            resource("skill:video", name: "video-cover-studio", kind: .skill, scope: .global),
            resource("agent:software", name: "software-engineer", kind: .agent, scope: .global),
        ])
        XCTAssertEqual(model.filteredRows.count, 2)
        model.searchText = "video"
        XCTAssertEqual(model.filteredRows.count, 1)
        XCTAssertEqual(model.filteredRows.first?.resource.id, "skill:video")
        model.searchText = "agent"
        XCTAssertEqual(model.filteredRows.count, 1)
        XCTAssertEqual(model.filteredRows.first?.resource.kind, .agent)
    }

    func testKindAndScopeFilters() {
        let model = CapabilitiesViewModel(resources: [
            resource("s0", name: "system-agent", kind: .agent, scope: .system),
            resource("s1", name: "one", kind: .skill, scope: .global),
            resource("s2", name: "two", kind: .skill, scope: .project),
            resource(
                id: "s3",
                name: "builtin-global-agent",
                kind: .agent,
                scope: .global,
                relativeSourcePath: ".system/agent-system/AGENTS.md"
            ),
            resource(
                id: "s4",
                name: "builtin-global-skill",
                kind: .skill,
                scope: .global,
                relativeSourcePath: ".system/skill-system/SKILL.md"
            ),
            resource("t1", name: "three", kind: .tool, scope: .runtime),
        ])
        XCTAssertEqual(model.filteredRows.map { $0.id }, ["s1", "s2", "t1"])
        model.kindFilter = .skill
        XCTAssertEqual(model.filteredRows.map { $0.id }, ["s1", "s2"])
        model.scopeFilter = .project
        XCTAssertEqual(model.filteredRows.map { $0.id }, ["s2"])
        model.scopeFilter = .system
        XCTAssertEqual(model.filteredRows.map { $0.id }, [])
        model.scopeFilter = .global
        XCTAssertEqual(model.filteredRows.map { $0.id }.sorted(), ["s1", "s4"].sorted())
    }

    func testUserOwnedFilterHidesBuiltinForGlobalRows() {
        let model = CapabilitiesViewModel(resources: [
            resource(
                id: "a",
                name: "global-agent",
                kind: ResourceKind.agent,
                scope: ResourceScope.global,
                relativeSourcePath: "agent/global/agent.md"
            ),
            resource(
                id: "b",
                name: "builtin-agent",
                kind: ResourceKind.agent,
                scope: ResourceScope.global,
                relativeSourcePath: ".system/agent-system/AGENTS.md"
            ),
            resource(
                id: "c",
                name: "project-agent",
                kind: ResourceKind.agent,
                scope: ResourceScope.project,
                relativeSourcePath: "project-agent/agent.md"
            )
        ])
        model.applyUserOwnedFilter(kind: ResourceKind.agent, scope: ResourceScope.global, hideBuiltin: true)
        XCTAssertEqual(model.filteredRows.map { $0.id }, ["a"])

        model.applyUserOwnedFilter(kind: ResourceKind.agent, scope: ResourceScope.project, hideBuiltin: true)
        XCTAssertEqual(model.filteredRows.map { $0.id }, ["c"])
    }

    func testUserOwnedFilterWithAllowedKindsAndScopes() {
        let model = CapabilitiesViewModel(resources: [
            resource(
                id: "plugin:one",
                name: "figma",
                kind: .plugin,
                scope: .plugin,
                relativeSourcePath: "plugins/figma/.codex-plugin"
            ),
            resource(
                id: "tool:two",
                name: "grep",
                kind: .tool,
                scope: .runtime,
                relativeSourcePath: "runtime/tools/grep"
            ),
            resource(
                id: "app:three",
                name: "calendar",
                kind: .app,
                scope: .runtime,
                relativeSourcePath: "runtime/calendar"
            ),
            resource(
                id: "agent:four",
                name: "agent",
                kind: .agent,
                scope: .runtime,
                relativeSourcePath: "runtime/agent"
            ),
        ])

        let allowedKinds: Set<ResourceKind> = [.plugin, .tool, .app, .mcp, .hook]
        let allowedScopes: Set<ResourceScope> = [.runtime, .plugin]
        model.applyUserOwnedFilter(
            allowedKinds: allowedKinds,
            allowedScopes: allowedScopes,
            hideBuiltin: true
        )

        XCTAssertEqual(model.filteredRows.map { $0.id }.sorted(), ["plugin:one", "tool:two", "app:three"].sorted())
    }

    func testSelectionPreservedWhileFiltering() {
        let model = CapabilitiesViewModel(resources: [
            resource("skill:video", name: "video", kind: .skill, scope: .global),
            resource("agent:software", name: "software", kind: .agent, scope: .global),
        ])
        model.selectedResourceID = "skill:video"
        XCTAssertEqual(model.selectedRow?.resource.id, "skill:video")
        model.searchText = "software"
        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:software"])
        // Selection is preserved even though the row is filtered out.
        XCTAssertEqual(model.selectedRow?.resource.id, "skill:video")
    }

    func testSelectionClearsWhenFilterHidesInspectorRow() {
        let model = CapabilitiesViewModel(resources: [
            resource("skill:unobserved", name: "unobserved", kind: .skill, scope: .global),
            resource("agent:observed", name: "observed", kind: .agent, scope: .global),
        ], stats: [
            .init(resourceID: "agent:observed", callCount: 1, failureCount: 0, lastUsedAt: nil, completedCount: 1, unresolvedCount: 0, evidenceLimitedCount: 0)
        ])
        model.selectedResourceID = "skill:unobserved"
        model.categoryFilter = .mySkills
        XCTAssertEqual(model.selectedRow?.id, "skill:unobserved")

        model.usageFilter = .observed
        model.clearSelectionIfFilteredOut()

        XCTAssertNil(model.selectedResourceID)
        XCTAssertNil(model.selectedRow)
        XCTAssertEqual(model.filteredRows.map(\.id), [])
    }

    func testSelectionClearsWhenAdvancedVisibilityHidesInspectorRow() {
        let cachedPlugin = CapabilityResource(
            id: "plugin:cached", name: "cached-plugin", kind: .plugin, status: .blocked,
            scope: .runtime, projectID: nil, confidence: .exact, summary: nil,
            sourceRootID: "plugin-cache", relativeSourcePath: "plugins/cached/.codex-plugin",
            sourcePathHash: nil, lastSeenAt: epoch, ownership: .pluginProvided, origin: .plugin
        )
        let model = CapabilitiesViewModel(resources: [cachedPlugin])
        model.applyCategory(.plugins)
        model.selectedResourceID = "plugin:cached"
        model.showAdvancedPluginCapabilities = false

        model.clearSelectionIfFilteredOut()

        XCTAssertTrue(model.filteredRows.isEmpty)
        XCTAssertNil(model.selectedResourceID)
    }

    func testSelectionClearsAfterRefreshChangesVisibleResourceProjection() {
        let model = CapabilitiesViewModel(resources: [
            resource("agent:refresh", name: "refreshable", kind: .agent, scope: .global)
        ])
        model.selectedResourceID = "agent:refresh"
        model.categoryFilter = .myAgents

        model.replaceData(resources: [
            resource("agent:refresh", name: "refreshable", kind: .agent, scope: .system)
        ])
        model.clearSelectionIfFilteredOut()

        XCTAssertTrue(model.filteredRows.isEmpty)
        XCTAssertNil(model.selectedResourceID)
    }

    func testDismissInspectorClearsSelectionWithoutChangingFilters() {
        let model = CapabilitiesViewModel(resources: [
            resource("skill:video", name: "video", kind: .skill, scope: .global),
            resource("agent:software", name: "software", kind: .agent, scope: .global),
        ])
        model.searchText = "video"
        model.selectedResourceID = "skill:video"

        model.dismissInspector()

        XCTAssertNil(model.selectedResourceID)
        XCTAssertNil(model.selectedRow)
        XCTAssertEqual(model.searchText, "video")
        XCTAssertEqual(model.filteredRows.map(\.id), ["skill:video"])
    }

    func testOneHopRelationships() {
        let relations = [
            ResourceRelation(sourceResourceID: "agent:a", targetResourceID: "skill:b", relationKind: "uses", confidence: .inferred, evidenceSummary: nil),
            ResourceRelation(sourceResourceID: "skill:b", targetResourceID: "tool:c", relationKind: "invokes", confidence: .exact, evidenceSummary: nil),
        ]
        let model = CapabilitiesViewModel(resources: [], relations: relations)
        let forB = model.relations(for: "skill:b")
        XCTAssertEqual(forB.count, 2) // incoming from a, outgoing to c
        XCTAssertTrue(forB.contains { $0.relationKind == "uses" })
        XCTAssertTrue(forB.contains { $0.relationKind == "invokes" })
    }
}
