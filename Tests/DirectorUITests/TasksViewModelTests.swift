import XCTest
@testable import DirectorUI
import DirectorCore

/// Tasks view-model contracts: privacy-safe titles, aggregate counts,
/// newest-cumulative tokens, timeline ordering, nesting depth, selection.
@MainActor
final class TasksViewModelTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ id: String, started: Date, status: TaskStatus = .completed) -> TaskSummary {
        TaskSummary(id: id, projectID: nil, startedAt: started, endedAt: started.addingTimeInterval(60), status: status, coverage: .complete, parserVersion: "1.0.0", sourceFileID: "f-\(id)", title: nil)
    }

    private func usage(total: Int64) -> TokenUsage {
        try! TokenUsage(inputTokens: total, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total, coverage: .complete)
    }

    func testRowsComputeCountsAndNewestCumulativeTokens() {
        let snapshots: [String: [TokenUsageSnapshot]] = [
            "s1": [
                TokenUsageSnapshot(id: "t1", sessionID: "s1", capturedAt: epoch, usage: usage(total: 100)),
                TokenUsageSnapshot(id: "t2", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60), usage: usage(total: 250)),
            ]
        ]
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "c1", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:a", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "c2", sessionID: "s1", parentCallID: nil, ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "tool:b", kind: .tool, status: .failed, durationMs: nil, confidence: .exact, errorCategory: "exit_1"),
                InvocationEvent(id: "c3", sessionID: "s1", parentCallID: nil, ordinal: 2, timestamp: epoch, actorName: nil, resourceID: "tool:c", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations, tokenSnapshotsBySession: snapshots)
        XCTAssertEqual(model.rows.count, 1)
        let row = model.rows[0]
        XCTAssertEqual(row.callCount, 3)
        XCTAssertEqual(row.failureCount, 1)
        // Newest cumulative, never summed.
        XCTAssertEqual(row.totalTokens, 250)
        XCTAssertNotEqual(row.totalTokens, 350)
    }

    func testDisplayTitleIsPrivacySafe() {
        let model = TasksViewModel(sessions: [session("s1", started: epoch)])
        let title = model.rows[0].displayTitle
        XCTAssertFalse(title.localizedCaseInsensitiveContains("prompt"))
        XCTAssertTrue(title.contains("Task ·"))
        XCTAssertFalse(title.isEmpty)
    }

    func testTimelineOrderedByOrdinal() {
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "c2", sessionID: "s1", parentCallID: nil, ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "tool:b", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "c1", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:a", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations)
        model.timelineMode = .technical
        XCTAssertEqual(model.timeline(for: "s1").map(\.id), ["c1", "c2"])
    }

    func testSemanticTimelineHidesSuccessfulPlainToolPlumbing() {
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "tool", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "skill", sessionID: "s1", parentCallID: nil, ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "skill:sample", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "failed-tool", sessionID: "s1", parentCallID: nil, ordinal: 2, timestamp: epoch, actorName: nil, resourceID: "tool:write", kind: .tool, status: .failed, durationMs: nil, confidence: .exact, errorCategory: "exit_1"),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations)
        XCTAssertEqual(model.timeline(for: "s1").map(\.id), ["skill", "failed-tool"])
        model.timelineMode = .technical
        XCTAssertEqual(model.timeline(for: "s1").map(\.id), ["tool", "skill", "failed-tool"])
    }

    func testSemanticDepthDoesNotIndentUnderHiddenTechnicalParent() {
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "parent", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "skill", sessionID: "s1", parentCallID: "parent", ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "skill:sample", kind: .skill, status: .completed, durationMs: nil, confidence: .inferred, errorCategory: nil),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations)
        let visible = model.timeline(for: "s1")
        XCTAssertEqual(visible.map(\.id), ["skill"])
        XCTAssertEqual(model.depth(of: visible[0], in: "s1"), 0)
    }

    func testSemanticEmptyStateExplainsTechnicalFallback() {
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "tool", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations)
        XCTAssertTrue(model.timeline(for: "s1").isEmpty)
        XCTAssertTrue(model.emptyTimelineMessage(for: "s1").contains("Technical"))
    }

    func testNestingDepth() {
        let invocations: [String: [InvocationEvent]] = [
            "s1": [
                InvocationEvent(id: "exec", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:exec", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "child", sessionID: "s1", parentCallID: "exec", ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "tool:exec_command", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
                InvocationEvent(id: "grandchild", sessionID: "s1", parentCallID: "child", ordinal: 2, timestamp: epoch, actorName: nil, resourceID: "tool:read", kind: .tool, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            ]
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: invocations)
        model.timelineMode = .technical
        XCTAssertEqual(model.depth(of: invocations["s1"]![0], in: "s1"), 0)
        XCTAssertEqual(model.depth(of: invocations["s1"]![1], in: "s1"), 1)
        XCTAssertEqual(model.depth(of: invocations["s1"]![2], in: "s1"), 2)
    }

    func testSelectionPreserved() {
        let model = TasksViewModel(sessions: [session("s1", started: epoch), session("s2", started: epoch.addingTimeInterval(-3600))])
        model.selectedTaskID = "s2"
        XCTAssertEqual(model.selectedRow?.id, "s2")
        XCTAssertEqual(model.selectedRow?.task.id, "s2")
    }

    func testEvaluationLookupUpdateAndClearPreserveTimelineAndSelection() {
        let calls = [
            InvocationEvent(id: "c1", sessionID: "s1", parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "c2", sessionID: "s1", parentCallID: nil, ordinal: 1, timestamp: epoch, actorName: nil, resourceID: "skill:b", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
        ]
        let model = TasksViewModel(sessions: [session("s1", started: epoch)], invocationsBySession: ["s1": calls])
        model.selectedTaskID = "s1"
        let evaluation = InvocationEvaluation(invocationID: "c1", sessionID: "s1", resourceID: "agent:a", label: .ineffective, updatedAt: epoch)

        model.setEvaluation(evaluation)

        XCTAssertEqual(model.evaluation(for: "c1"), evaluation)
        XCTAssertEqual(model.selectedTaskID, "s1")
        XCTAssertEqual(model.timeline(for: "s1").map(\.id), ["c1", "c2"])

        model.clearEvaluation(for: "c1")

        XCTAssertNil(model.evaluation(for: "c1"))
        XCTAssertEqual(model.selectedTaskID, "s1")
        XCTAssertEqual(model.timeline(for: "s1").map(\.id), ["c1", "c2"])
    }

    func testRowsSortedNewestFirst() {
        let model = TasksViewModel(sessions: [
            session("old", started: epoch.addingTimeInterval(-3600)),
            session("new", started: epoch),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["new", "old"])
    }

    func testDurationFormatting() {
        XCTAssertEqual(InvocationTimelineView.durationText(500), "500 ms")
        XCTAssertEqual(InvocationTimelineView.durationText(2_500), "2.5 s")
        XCTAssertEqual(InvocationTimelineView.durationText(90_000), "1.5 min")
    }
}
