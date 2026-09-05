import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class HomeViewModelTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func resource(
        id: String,
        name: String,
        kind: ResourceKind,
        scope: ResourceScope,
        relativeSourcePath: String
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
            sourceRootID: "root",
            relativeSourcePath: relativeSourcePath,
            sourcePathHash: nil,
            lastSeenAt: epoch
        )
    }

    private func row(
        _ id: String,
        name: String,
        kind: ResourceKind,
        scope: ResourceScope,
        relativeSourcePath: String
    ) -> CapabilityRow {
        CapabilityRow(
            resource: resource(
                id: id,
                name: name,
                kind: kind,
                scope: scope,
                relativeSourcePath: relativeSourcePath
            ),
            callCount: 0,
            failureCount: 0,
            lastUsedAt: nil
        )
    }

    func testHomeCountsExcludeBuiltinAgentsAndSkills() {
        let model = HomeDashboardViewModel(rows: [
            row(
                "agent:global-custom",
                name: "custom-agent",
                kind: .agent,
                scope: .global,
                relativeSourcePath: "agent/agent.md"
            ),
            row(
                "agent:global-system",
                name: "system-agent",
                kind: .agent,
                scope: .global,
                relativeSourcePath: ".system/agent-system/AGENTS.md"
            ),
            row(
                "agent:global-system2",
                name: "system-agent-2",
                kind: .agent,
                scope: .system,
                relativeSourcePath: "agents/system.md"
            ),
            row(
                "agent:project-a",
                name: "project-agent",
                kind: .agent,
                scope: .project,
                relativeSourcePath: "AGENTS.md"
            ),
            row(
                "skill:global-custom",
                name: "custom-skill",
                kind: .skill,
                scope: .global,
                relativeSourcePath: "skill/SKILL.md"
            ),
            row(
                "skill:global-system",
                name: "system-skill",
                kind: .skill,
                scope: .global,
                relativeSourcePath: ".system/skill-system/SKILL.md"
            ),
            row(
                "skill:project-a",
                name: "project-skill",
                kind: .skill,
                scope: .project,
                relativeSourcePath: "skills/SKILL.md"
            )
        ])

        XCTAssertEqual(model.globalAgentCount, 1)
        XCTAssertEqual(model.projectAgentCount, 1)
        XCTAssertEqual(model.globalSkillCount, 1)
        XCTAssertEqual(model.projectSkillCount, 1)
    }

    func testInstalledToolCountsIncludeRuntimeAndPluginToolsAndExcludeCodexCli() {
        let model = HomeDashboardViewModel(rows: [
            row(
                "plugin:runtime-figma",
                name: "figma",
                kind: .plugin,
                scope: .plugin,
                relativeSourcePath: "plugins/figma/.codex-plugin"
            ),
            row(
                "mcp:runtime-linear",
                name: "linear",
                kind: .mcp,
                scope: .runtime,
                relativeSourcePath: "runtime/mcp/linear"
            ),
            row(
                "app:runtime-calendar",
                name: "calendar",
                kind: .app,
                scope: .runtime,
                relativeSourcePath: "runtime/plugin.calendar"
            ),
            row(
                "app:runtime-codex-cli",
                name: "codex-cli",
                kind: .app,
                scope: .runtime,
                relativeSourcePath: "runtime/codex-cli"
            ),
            row(
                "tool:runtime-grep",
                name: "grep",
                kind: .tool,
                scope: .runtime,
                relativeSourcePath: "runtime/tools/grep"
            ),
            row(
                "hook:runtime-scan",
                name: "hooks",
                kind: .hook,
                scope: .runtime,
                relativeSourcePath: "runtime/hooks.json"
            ),
            row(
                "agent:runtime",
                name: "runtime-agent",
                kind: .agent,
                scope: .runtime,
                relativeSourcePath: "runtime/agent.md"
            ),
            row(
                "plugin:runtime-figma",
                name: "figma",
                kind: .plugin,
                scope: .plugin,
                relativeSourcePath: "plugins/figma/.codex-plugin"
            ),
            row(
                "plugin:runtime-figma",
                name: "figma",
                kind: .plugin,
                scope: .plugin,
                relativeSourcePath: "plugins/figma/.codex-plugin"
            )
        ])

        XCTAssertEqual(model.installedToolCount, 5)
    }

    func testCapabilityUseMetricsScopeToCurrentUserOwnedAgentsAndSkills() {
        let observed = CapabilityRow(
            resource: resource(id: "agent:observed", name: "observed", kind: .agent, scope: .global, relativeSourcePath: "agent.md"),
            callCount: 2, failureCount: 1, lastUsedAt: epoch,
            completedCount: 1, unresolvedCount: 0, evidenceLimitedCount: 2,
            evaluatedCount: 1, effectiveCount: 0, ineffectiveCount: 1, uncertainCount: 0
        )
        let notObserved = row("skill:not-observed", name: "not-observed", kind: .skill, scope: .global, relativeSourcePath: "skill.md")
        let builtin = row("skill:builtin", name: "builtin", kind: .skill, scope: .global, relativeSourcePath: ".system/builtin/SKILL.md")
        let tool = row("tool:other", name: "other", kind: .tool, scope: .runtime, relativeSourcePath: "tool")

        let model = HomeDashboardViewModel(rows: [observed, notObserved, builtin, tool])

        XCTAssertEqual(model.observedCapabilityCount, 1)
        XCTAssertEqual(model.notObservedCapabilityCount, 1)
        XCTAssertEqual(model.evidenceLimitedCallCount, 2)
        XCTAssertEqual(model.evaluatedInvocationCount, 1)
        XCTAssertEqual(model.ineffectiveInvocationCount, 1)
    }

    func testCapabilityUseFilterScopesKindsAndOwnership() {
        let observedAgent = CapabilityRow(
            resource: resource(id: "agent:observed", name: "observed", kind: .agent, scope: .global, relativeSourcePath: "agent.md"),
            callCount: 1, failureCount: 0, lastUsedAt: epoch
        )
        let observedSkill = CapabilityRow(
            resource: resource(id: "skill:observed", name: "observed", kind: .skill, scope: .global, relativeSourcePath: "skill.md"),
            callCount: 1, failureCount: 0, lastUsedAt: epoch
        )
        let observedTool = CapabilityRow(
            resource: resource(id: "tool:observed", name: "observed", kind: .tool, scope: .runtime, relativeSourcePath: "tool"),
            callCount: 1, failureCount: 0, lastUsedAt: epoch
        )
        let installedSkill = CapabilityRow(
            resource: CapabilityResource(
                id: "skill:installed", name: "installed", kind: .skill, status: .idle,
                scope: .global, projectID: nil, confidence: .exact, summary: nil,
                sourceRootID: "root", relativeSourcePath: "installed/SKILL.md", sourcePathHash: nil,
                lastSeenAt: epoch, ownership: .installed
            ),
            callCount: 1, failureCount: 0, lastUsedAt: epoch
        )

        let model = CapabilitiesViewModel(resources: [
            observedAgent.resource, observedSkill.resource, observedTool.resource, installedSkill.resource
        ], stats: [
            .init(resourceID: observedAgent.id, callCount: 1, failureCount: 0, lastUsedAt: epoch),
            .init(resourceID: observedSkill.id, callCount: 1, failureCount: 0, lastUsedAt: epoch),
            .init(resourceID: observedTool.id, callCount: 1, failureCount: 0, lastUsedAt: epoch),
            .init(resourceID: installedSkill.id, callCount: 1, failureCount: 0, lastUsedAt: epoch)
        ])
        model.applyUserOwnedFilter(allowedKinds: [.agent, .skill], ownership: .userOwned, hideBuiltin: true)
        model.usageFilter = .observed

        XCTAssertEqual(model.filteredRows.map(\.id), ["agent:observed", "skill:observed"])
    }
}
