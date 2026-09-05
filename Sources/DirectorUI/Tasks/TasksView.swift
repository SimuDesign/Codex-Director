import SwiftUI
import DirectorCore

/// Layout states for the Tasks workspace. The breakpoint is based on the
/// complete available workspace width so compact mode can stage the task
/// list, timeline, and inspector instead of asking nested split views to fit.
public enum TasksLayoutState: String, Equatable, Sendable {
    case spacious
    case compact

    public static func forWorkspaceWidth(_ width: CGFloat) -> Self {
        width >= TasksLayoutMetrics.spaciousWorkspaceMinimumWidth ? .spacious : .compact
    }
}

/// Width and height contracts for the native Tasks panes.
///
/// The spacious threshold is derived from the three readable pane minima plus
/// the design-system allowance for native split separators and breathing room.
public enum TasksLayoutMetrics {
    public static let taskListMinimumWidth: CGFloat = 240
    public static let taskListIdealWidth: CGFloat = 280
    public static let taskListMaximumWidth: CGFloat = 360
    public static let timelineMinimumWidth: CGFloat = 300
    public static let inspectorMinimumWidth: CGFloat = 320
    public static let spaciousWorkspaceMinimumWidth: CGFloat =
        taskListMinimumWidth + timelineMinimumWidth + inspectorMinimumWidth + DirectorSpacing.space8
    public static let compactInspectorMinimumHeight: CGFloat = 170
}

/// Pure selection transitions used by staged compact navigation.
public struct TasksSelectionState: Equatable, Sendable {
    public let taskID: String?
    public let eventID: String?

    public init(taskID: String? = nil, eventID: String? = nil) {
        self.taskID = taskID
        self.eventID = eventID
    }

    public func closingInvocation() -> Self {
        Self(taskID: taskID, eventID: nil)
    }

    public func returningToTaskList() -> Self {
        Self()
    }
}

/// Tasks destination: privacy-safe task list driving the invocation timeline
/// and inspector. Prompt text is never shown.
public struct TasksView: View {
    @ObservedObject public var model: TasksViewModel
    public let onEvaluate: ((InvocationEvent, InvocationEvaluationLabel) -> Void)?
    public let onClearEvaluation: ((InvocationEvent) -> Void)?
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        model: TasksViewModel,
        onEvaluate: ((InvocationEvent, InvocationEvaluationLabel) -> Void)? = nil,
        onClearEvaluation: ((InvocationEvent) -> Void)? = nil
    ) {
        self.model = model
        self.onEvaluate = onEvaluate
        self.onClearEvaluation = onClearEvaluation
    }

    public var body: some View {
        GeometryReader { workspaceProxy in
            workspaceContent(width: workspaceProxy.size.width)
        }
    }

    @ViewBuilder
    private func workspaceContent(width: CGFloat) -> some View {
        switch TasksLayoutState.forWorkspaceWidth(width) {
        case .spacious:
            spaciousWorkspace
        case .compact:
            compactWorkspace
        }
    }

    private func taskList(expanded: Bool = false) -> some View {
        List(selection: Binding(
            get: { model.selectedTaskID },
            set: { model.selectTask($0) }
        )) {
            ForEach(model.rows) { row in
                rowView(row)
                    .tag(row.id)
            }
        }
        .frame(
            minWidth: TasksLayoutMetrics.taskListMinimumWidth,
            idealWidth: TasksLayoutMetrics.taskListIdealWidth,
            maxWidth: expanded ? .infinity : TasksLayoutMetrics.taskListMaximumWidth
        )
        .layoutPriority(2)
    }

    @ViewBuilder
    private var spaciousWorkspace: some View {
        HSplitView {
            taskList()

            if let selected = model.selectedRow {
                timelinePane(for: selected)
                    .frame(minWidth: TasksLayoutMetrics.timelineMinimumWidth, idealWidth: 440)
                    .layoutPriority(1)
                inspectorContent
                    .frame(minWidth: TasksLayoutMetrics.inspectorMinimumWidth, idealWidth: 360)
                    .layoutPriority(1)
            } else {
                Text(languageStore.localizer.text("Select a task to see its invocation timeline.", fallback: "Select a task to see its invocation timeline."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var compactWorkspace: some View {
        if let selected = model.selectedRow {
            compactTaskDetail(for: selected)
        } else {
            taskList(expanded: true)
        }
    }

    private func compactTaskDetail(for selected: TaskRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DirectorSpacing.space2) {
                Button {
                    returnToTaskList()
                } label: {
                    Label(languageStore.localizer.text("Back to task list", fallback: "Back to task list"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(languageStore.localizer.text("Back to task list", fallback: "Back to task list"))
                .accessibilityHint(languageStore.localizer.text("Returns to the Tasks list.", fallback: "Returns to the Tasks list."))

                Text(displayTitle(for: selected))
                    .font(DirectorTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DirectorSpacing.space3)
            .padding(.vertical, DirectorSpacing.space2)

            timelinePane(for: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            compactInspectorContent
                .frame(
                    minHeight: TasksLayoutMetrics.compactInspectorMinimumHeight,
                    idealHeight: 210,
                    maxHeight: 280
                )
        }
    }

    @ViewBuilder
    private var compactInspectorContent: some View {
        if selectedEvent != nil {
            VStack(spacing: 0) {
                HStack {
                    Text(languageStore.localizer.text("Invocation inspector", fallback: "Invocation inspector"))
                        .font(DirectorTypography.sectionTitle)
                    Spacer()
                    Button {
                        closeSelectedInvocation()
                    } label: {
                        Label(languageStore.localizer.text("Close", fallback: "Close"), systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(languageStore.localizer.text("Close invocation inspector", fallback: "Close invocation inspector"))
                    .accessibilityHint(languageStore.localizer.text("Closes the selected invocation and returns to the timeline.", fallback: "Closes the selected invocation and returns to the timeline."))
                }
                .padding(.horizontal, DirectorSpacing.space4)
                .padding(.vertical, DirectorSpacing.space2)
                Divider()
                inspectorContent
            }
        } else {
            inspectorContent
        }
    }

    private func timelinePane(for row: TaskRow) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                HStack {
                    Picker(languageStore.localizer.text("Timeline", fallback: "Timeline"), selection: Binding(
                        get: { model.timelineMode },
                        set: { model.setTimelineMode($0) }
                    )) {
                        Text(languageStore.localizer.enumLabel(.init(key: "timeline.mode.semantic", fallback: "Semantic"))).tag(TimelineMode.semantic)
                        Text(languageStore.localizer.enumLabel(.init(key: "timeline.mode.technical", fallback: "Technical"))).tag(TimelineMode.technical)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    // The segmented control keeps its accessible Picker label,
                    // while the visible label is hidden so it cannot wrap into
                    // vertical letters in a narrow timeline pane.
                    .labelsHidden()
                    .accessibilityLabel(languageStore.localizer.text("Timeline mode", fallback: "Timeline mode"))
                    Spacer(minLength: 0)
                }

                HStack(spacing: DirectorSpacing.space3) {
                    CoverageNotice(coverage: row.task.coverage)
                    Text(languageStore.localizer.plural("task.rawCallCount", count: row.callCount, fallback: "%lld raw calls"))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DirectorSpacing.space3)
            .padding(.vertical, DirectorSpacing.space2)
            Divider()

            InvocationTimelineView(
                events: model.timeline(for: row.id),
                depths: depthMap(for: row.id),
                selection: $model.selectedEventID,
                emptyMessage: model.emptyTimelineMessage(for: row.id)
            )
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let selectedEvent {
            InvocationInspector(
                event: selectedEvent,
                evaluation: model.evaluation(for: selectedEvent.id),
                onEvaluate: { label in onEvaluate?(selectedEvent, label) },
                onClearEvaluation: { onClearEvaluation?(selectedEvent) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: DirectorSpacing.space2) {
                Image(systemName: "sidebar.right")
                    .font(.title2)
                    .foregroundStyle(DirectorColor.textSecondary)
                Text(languageStore.localizer.text("Select an invocation to inspect it.", fallback: "Select an invocation to inspect it."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func closeSelectedInvocation() {
        let transition = TasksSelectionState(
            taskID: model.selectedTaskID,
            eventID: model.selectedEventID
        ).closingInvocation()
        model.selectedEventID = transition.eventID
    }

    private func returnToTaskList() {
        let transition = TasksSelectionState(
            taskID: model.selectedTaskID,
            eventID: model.selectedEventID
        ).returningToTaskList()
        model.selectedEventID = transition.eventID
        model.selectedTaskID = transition.taskID
    }

    private func rowView(_ row: TaskRow) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                Text(displayTitle(for: row))
                    .font(DirectorTypography.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DirectorSpacing.space2)
                CoverageNotice(coverage: row.task.coverage)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                RuntimeStatusBadge(status: status(for: row.task.status))
                    .fixedSize(horizontal: true, vertical: false)
                Text(row.task.id)
                    .font(DirectorTypography.code)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
                Text(languageStore.localizer.format(
                    "%@ · %@",
                    fallback: "%@ · %@",
                    languageStore.localizer.plural("task.callCount", count: row.callCount, fallback: "%lld calls"),
                    languageStore.localizer.plural("task.failureCount", count: row.failureCount, fallback: "%lld failed")
                ))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                if let totalTokens = row.totalTokens {
                    Text(languageStore.localizer.format("%lld tokens", fallback: "%lld tokens", totalTokens))
                        .font(DirectorTypography.data)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, DirectorSpacing.space1)
    }

    private func status(for taskStatus: TaskStatus) -> RuntimeStatus {
        switch taskStatus {
        case .running: return .running
        case .completed: return .success
        case .interrupted: return .blocked
        case .failed: return .failure
        case .unknown: return .unknown
        }
    }

    private func displayTitle(for row: TaskRow) -> String {
        guard row.task.title == nil else { return row.displayTitle }
        let timestamp = row.task.startedAt.map {
            languageStore.localizer.date($0, style: Date.FormatStyle(date: .abbreviated, time: .shortened))
        } ?? languageStore.localizer.text("unknown time", fallback: "unknown time")
        return languageStore.localizer.format("Task · %@", fallback: "Task · %@", timestamp)
    }

    private func depthMap(for sessionID: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for event in model.timeline(for: sessionID) {
            map[event.id] = model.depth(of: event, in: sessionID)
        }
        return map
    }

    private var selectedEvent: InvocationEvent? {
        guard let selected = model.selectedRow, let selectedEventID = model.selectedEventID else { return nil }
        return model.timeline(for: selected.id).first { $0.id == selectedEventID }
    }
}
