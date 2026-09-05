import Foundation
import DirectorCore

/// Synthetic-only preview and test data.
///
/// Every path uses `/Users/example/...`; no real session, resource, prompt, or
/// argument content is ever copied here.
public enum SyntheticPreviewData {
    public static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Resources

    public static let resources: [CapabilityResource] = [
        CapabilityResource(
            id: "skill:video-cover-studio",
            name: "video-cover-studio",
            kind: .skill,
            status: .success,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Designs cover frames for video deliverables.",
            sourceRootID: "global-skills",
            relativeSourcePath: "video-cover-studio/SKILL.md",
            sourcePathHash: "e3b0c442",
            lastSeenAt: epoch
        ),
        CapabilityResource(
            id: "agent:software-engineer",
            name: "software-engineer",
            kind: .agent,
            status: .idle,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: "Implements approved changes with verification evidence.",
            sourceRootID: "global-agents",
            relativeSourcePath: "software-engineer/agent.md",
            sourcePathHash: "d9e6762d",
            lastSeenAt: epoch
        ),
        CapabilityResource(
            id: "plugin:figma",
            name: "figma",
            kind: .plugin,
            status: .unknown,
            scope: .plugin,
            projectID: nil,
            confidence: .inferred,
            summary: "Figma plugin surface.",
            sourceRootID: "plugin-cache",
            relativeSourcePath: "figma/.codex-plugin",
            sourcePathHash: nil,
            lastSeenAt: epoch
        ),
        CapabilityResource(
            id: "tool:exec_command",
            name: "exec_command",
            kind: .tool,
            status: .running,
            scope: .runtime,
            projectID: nil,
            confidence: .exact,
            summary: "Executes commands in a sandboxed shell.",
            sourceRootID: "runtime-dynamic-tools",
            relativeSourcePath: "codex_app/tools/exec_command",
            sourcePathHash: nil,
            lastSeenAt: epoch
        ),
    ]

    // MARK: - Tasks

    public static let tasks: [TaskSummary] = [
        TaskSummary(
            id: "session:syn-001",
            projectID: "example-project",
            startedAt: epoch,
            endedAt: epoch.addingTimeInterval(180),
            status: .completed,
            coverage: .complete,
            parserVersion: "1.0",
            sourceFileID: "rollout-syn-001",
            title: nil
        ),
        TaskSummary(
            id: "session:syn-002",
            projectID: nil,
            startedAt: epoch.addingTimeInterval(-3600),
            endedAt: nil,
            status: .running,
            coverage: .partial,
            parserVersion: "1.0",
            sourceFileID: "rollout-syn-002",
            title: nil
        ),
        TaskSummary(
            id: "session:syn-003",
            projectID: "example-project",
            startedAt: epoch.addingTimeInterval(-86_400),
            endedAt: epoch.addingTimeInterval(-86_400 + 240),
            status: .failed,
            coverage: .complete,
            parserVersion: "1.0",
            sourceFileID: "rollout-syn-003",
            title: nil
        ),
    ]

    // MARK: - Invocations

    public static let invocations: [InvocationEvent] = [
        InvocationEvent(
            id: "call:syn-001-0",
            sessionID: "session:syn-001",
            parentCallID: nil,
            ordinal: 0,
            timestamp: epoch,
            actorName: "codex",
            resourceID: "tool:exec_command",
            kind: .tool,
            status: .completed,
            durationMs: 4_200,
            confidence: .exact,
            errorCategory: nil
        ),
        InvocationEvent(
            id: "call:syn-001-1",
            sessionID: "session:syn-001",
            parentCallID: "call:syn-001-0",
            ordinal: 1,
            timestamp: epoch.addingTimeInterval(1),
            actorName: "codex",
            resourceID: "tool:read",
            kind: .tool,
            status: .completed,
            durationMs: 130,
            confidence: .exact,
            errorCategory: nil
        ),
        InvocationEvent(
            id: "call:syn-003-0",
            sessionID: "session:syn-003",
            parentCallID: nil,
            ordinal: 0,
            timestamp: epoch.addingTimeInterval(-86_400),
            actorName: "codex",
            resourceID: "skill:video-cover-studio",
            kind: .skill,
            status: .failed,
            durationMs: 900,
            confidence: .inferred,
            errorCategory: "tool_failed"
        ),
    ]

    // MARK: - Token usage

    public static let tokenSnapshots: [TokenUsageSnapshot] = [
        TokenUsageSnapshot(
            id: "tokens:syn-001",
            sessionID: "session:syn-001",
            capturedAt: epoch.addingTimeInterval(180),
            usage: try! TokenUsage(
                inputTokens: 12_000, cachedInputTokens: 3_000, cacheWriteInputTokens: 400,
                outputTokens: 2_500, reasoningOutputTokens: 1_100, totalTokens: 19_000,
                coverage: .complete
            )
        ),
    ]

    // MARK: - Quota snapshots

    public static let quotaSnapshots: [QuotaSnapshot] = [
        try! QuotaSnapshot(
            id: "quota:syn-weekly",
            capturedAt: epoch.addingTimeInterval(-3_600),
            windowMinutes: 10_080,
            usedPercent: 47,
            resetsAt: epoch.addingTimeInterval(86_400),
            limitID: "weekly",
            limitName: "Weekly",
            confidence: .exact
        ),
        try! QuotaSnapshot(
            id: "quota:syn-short",
            capturedAt: epoch.addingTimeInterval(-3_600),
            windowMinutes: 300,
            usedPercent: 12.5,
            resetsAt: epoch.addingTimeInterval(7_200),
            limitID: "short",
            limitName: "Five-hour",
            confidence: .exact
        ),
    ]

    // MARK: - Relations

    public static let relations: [ResourceRelation] = [
        ResourceRelation(
            sourceResourceID: "agent:software-engineer",
            targetResourceID: "skill:video-cover-studio",
            relationKind: "uses",
            confidence: .inferred,
            evidenceSummary: "Declared in the agent brief"
        ),
        ResourceRelation(
            sourceResourceID: "tool:exec_command",
            targetResourceID: "plugin:figma",
            relationKind: "invokes",
            confidence: .unknown,
            evidenceSummary: nil
        ),
    ]

    // MARK: - Findings

    public static let findings: [ReviewFinding] = [
        ReviewFinding(
            id: "finding:syn-001",
            ruleID: "rule.missing-source",
            resourceID: "plugin:figma",
            sessionID: nil,
            severity: .warning,
            confidence: .exact,
            summary: "Declared source is missing or unavailable",
            evidenceSummary: "Plugin cache root does not contain figma/.codex-plugin",
            coverage: .complete,
            createdAt: epoch,
            remediationStatus: .open
        ),
    ]
}
