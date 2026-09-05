import Foundation
import DirectorCore

/// One row in the Tasks list: session plus aggregate counts and the newest
/// cumulative token total (never summed).
public struct TaskRow: Identifiable, Equatable {
    public let task: TaskSummary
    public let callCount: Int
    public let failureCount: Int
    public let totalTokens: Int64?

    public var id: String { task.id }

    public init(task: TaskSummary, callCount: Int, failureCount: Int, totalTokens: Int64?) {
        self.task = task
        self.callCount = callCount
        self.failureCount = failureCount
        self.totalTokens = totalTokens
    }

    /// Privacy-safe display title: never prompt or response text.
    public var displayTitle: String {
        task.title ?? "Task · \(task.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown time")"
    }
}

/// SQL-backed task aggregate used while invocation evidence remains lazy.
/// The list can show useful counts without materializing every call.
public struct TaskCallSummary: Sendable, Equatable {
    public let callCount: Int
    public let failureCount: Int

    public init(callCount: Int = 0, failureCount: Int = 0) {
        self.callCount = callCount
        self.failureCount = failureCount
    }
}

/// Timeline presentation: semantic behavior by default, with a complete raw
/// event view available for technical inspection.
public enum TimelineMode: String, CaseIterable, Sendable {
    case semantic
    case technical
}

/// Main-actor view state for the Tasks destination.
@MainActor
public final class TasksViewModel: ObservableObject {
    @Published public var selectedTaskID: String? {
        didSet {
            guard oldValue != selectedTaskID else { return }
            selectedEventID = nil
        }
    }
    /// Model-backed invocation selection survives view reconstruction, such
    /// as when the app language changes.
    @Published public var selectedEventID: String?
    @Published public var timelineMode: TimelineMode = .semantic {
        didSet {
            guard oldValue != timelineMode else { return }
            selectedEventID = nil
        }
    }
    @Published public private(set) var evaluations: [String: InvocationEvaluation]

    public let rows: [TaskRow]
    public let invocationsBySession: [String: [InvocationEvent]]

    private let byIDBySession: [String: [String: InvocationEvent]]

    public init(
        sessions: [TaskSummary],
        invocationsBySession: [String: [InvocationEvent]] = [:],
        tokenSnapshotsBySession: [String: [TokenUsageSnapshot]] = [:],
        callSummaries: [String: TaskCallSummary] = [:],
        evaluations: [String: InvocationEvaluation] = [:],
        selectedTaskID: String? = nil,
        selectedEventID: String? = nil
    ) {
        var rows: [TaskRow] = []
        for session in sessions {
            let calls = invocationsBySession[session.id] ?? []
            let tokens = tokenSnapshotsBySession[session.id] ?? []
            let summary = callSummaries[session.id]
            let newest = TokenUsageParser.newestCumulative(from: tokens)
            rows.append(TaskRow(
                task: session,
                callCount: calls.isEmpty ? (summary?.callCount ?? 0) : calls.count,
                failureCount: calls.isEmpty ? (summary?.failureCount ?? 0) : calls.filter { $0.status == .failed || $0.status == .interrupted }.count,
                totalTokens: newest?.usage.totalTokens
            ))
        }
        self.rows = rows.sorted {
            ($0.task.startedAt ?? .distantPast) > ($1.task.startedAt ?? .distantPast)
        }
        self.invocationsBySession = invocationsBySession
        self.evaluations = evaluations
        self.selectedTaskID = selectedTaskID
        self.selectedEventID = selectedEventID
        self.byIDBySession = invocationsBySession.mapValues { calls in
            Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0) })
        }
    }

    public var selectedRow: TaskRow? {
        guard let selectedTaskID else { return nil }
        return rows.first { $0.id == selectedTaskID }
    }

    /// Updates task selection and clears its invocation only when the task
    /// actually changes. This keeps a same-value refresh or language-driven
    /// view reconstruction from dropping the selected call.
    public func selectTask(_ taskID: String?) {
        guard selectedTaskID != taskID else { return }
        selectedTaskID = taskID
        selectedEventID = nil
    }

    /// Timeline mode changes can hide the selected event, so clear it only
    /// for a real mode transition.
    public func setTimelineMode(_ mode: TimelineMode) {
        guard timelineMode != mode else { return }
        timelineMode = mode
        selectedEventID = nil
    }

    public func timeline(for sessionID: String) -> [InvocationEvent] {
        let events = technicalTimeline(for: sessionID)
        return timelineMode == .technical ? events : events.filter(Self.isSemantic)
    }

    public func technicalTimeline(for sessionID: String) -> [InvocationEvent] {
        (invocationsBySession[sessionID] ?? []).sorted { $0.ordinal < $1.ordinal }
    }

    public func semanticTimeline(for sessionID: String) -> [InvocationEvent] {
        technicalTimeline(for: sessionID).filter(Self.isSemantic)
    }

    public func emptyTimelineMessage(for sessionID: String) -> String {
        if timelineMode == .semantic && !technicalTimeline(for: sessionID).isEmpty {
            return "No semantic events recorded. Switch to Technical to inspect raw calls."
        }
        return "No invocations recorded for this task."
    }

    public func evaluation(for invocationID: String) -> InvocationEvaluation? {
        evaluations[invocationID]
    }

    public func setEvaluation(_ evaluation: InvocationEvaluation) {
        evaluations[evaluation.invocationID] = evaluation
    }

    public func setEvaluation(
        for event: InvocationEvent,
        label: InvocationEvaluationLabel,
        updatedAt: Date = Date()
    ) {
        setEvaluation(InvocationEvaluation(
            invocationID: event.id,
            sessionID: event.sessionID,
            resourceID: event.resourceID,
            label: label,
            updatedAt: updatedAt
        ))
    }

    public func clearEvaluation(for invocationID: String) {
        evaluations.removeValue(forKey: invocationID)
    }

    /// Successful plain tool plumbing is intentionally hidden in semantic
    /// mode. Incomplete, failed, or interrupted calls remain visible because
    /// they affect a user's judgment even when no capability was involved.
    public static func isSemantic(_ event: InvocationEvent) -> Bool {
        switch event.kind {
        case .agent, .skill, .orchestration, .workflow, .review, .handoff, .compaction, .interruption:
            return true
        case .tool:
            return event.status != .completed
        case .unknown:
            return true
        }
    }

    /// Nesting depth from the parent-call chain.
    public func depth(of event: InvocationEvent, in sessionID: String) -> Int {
        let visibleIDs = Set(timeline(for: sessionID).map(\.id))
        var depth = 0
        var current: InvocationEvent? = event
        var hops = 0
        while let parentID = current?.parentCallID, hops < 64 {
            guard visibleIDs.contains(parentID) else { break }
            guard let parent = byIDBySession[sessionID]?[parentID] else { break }
            depth += 1
            current = parent
            hops += 1
        }
        return depth
    }
}
