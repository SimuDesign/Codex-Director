import XCTest
import DirectorCore
@testable import DirectorUI

/// Regression contracts for the Tasks workspace breakpoint and staged
/// selection transitions. These are pure tests so they can run without
/// launching the Debug app or depending on window screenshot timing.
@MainActor
final class TasksLayoutTests: XCTestCase {

    func testSupportedMinimumWorkspaceUsesStagedCompactLayout() {
        // The root minimum is 720 pt; after the approximately 228 pt sidebar,
        // Tasks receives about 492 pt and cannot host three readable panes.
        XCTAssertEqual(TasksLayoutState.forWorkspaceWidth(492), .compact)
    }

    func testDefaultWorkspaceUsesReadableSpaciousLayout() {
        // A 1280 pt window with the normal sidebar leaves enough width for
        // task list, timeline, and inspector in one native split view.
        XCTAssertEqual(TasksLayoutState.forWorkspaceWidth(1_052), .spacious)
    }

    func testSpaciousWorkspaceMinimumIsDerivedFromPaneContracts() {
        let paneMinimums = TasksLayoutMetrics.taskListMinimumWidth
            + TasksLayoutMetrics.timelineMinimumWidth
            + TasksLayoutMetrics.inspectorMinimumWidth

        XCTAssertGreaterThanOrEqual(TasksLayoutMetrics.taskListMinimumWidth, 240)
        XCTAssertGreaterThanOrEqual(TasksLayoutMetrics.timelineMinimumWidth, 300)
        XCTAssertGreaterThanOrEqual(TasksLayoutMetrics.inspectorMinimumWidth, 320)
        XCTAssertEqual(
            TasksLayoutMetrics.spaciousWorkspaceMinimumWidth,
            paneMinimums + DirectorSpacing.space8
        )
    }

    func testBreakpointDoesNotReintroduceDetailOnlyWidthCollapse() {
        let threshold = TasksLayoutMetrics.spaciousWorkspaceMinimumWidth
        XCTAssertEqual(TasksLayoutState.forWorkspaceWidth(threshold - 1), .compact)
        XCTAssertEqual(TasksLayoutState.forWorkspaceWidth(threshold), .spacious)
    }

    func testClosingInvocationPreservesTaskSelection() {
        let state = TasksSelectionState(taskID: "session:validation-0", eventID: "agent:validation-global")

        XCTAssertEqual(
            state.closingInvocation(),
            TasksSelectionState(taskID: "session:validation-0")
        )
    }

    func testReturningToTaskListClearsTaskAndInvocationSelection() {
        let state = TasksSelectionState(taskID: "session:validation-0", eventID: "agent:validation-global")

        XCTAssertEqual(state.returningToTaskList(), TasksSelectionState())
    }

    func testModelBackedInvocationSelectionSurvivesViewReconstruction() {
        let model = TasksViewModel(sessions: [])
        model.selectedTaskID = "session:validation-0"
        model.selectedEventID = "agent:validation-global"

        _ = TasksView(model: model)
        _ = TasksView(model: model)

        XCTAssertEqual(model.selectedTaskID, "session:validation-0")
        XCTAssertEqual(model.selectedEventID, "agent:validation-global")
    }

    func testTaskAndTimelineTransitionsClearOnlyOnRealChanges() {
        let model = TasksViewModel(sessions: [])
        model.selectedTaskID = "session:validation-0"
        model.selectedEventID = "agent:validation-global"

        model.selectTask("session:validation-0")
        XCTAssertEqual(model.selectedEventID, "agent:validation-global")

        model.selectTask("session:validation-1")
        XCTAssertNil(model.selectedEventID)
        model.selectedEventID = "agent:validation-other"
        model.setTimelineMode(.semantic)
        XCTAssertEqual(model.selectedEventID, "agent:validation-other")

        model.setTimelineMode(.technical)
        XCTAssertNil(model.selectedEventID)
    }

    func testLanguageRoundTripDoesNotAlterTaskEventOrEvaluationState() {
        let event = InvocationEvent(
            id: "agent:validation-global",
            sessionID: "session:validation-0",
            parentCallID: nil,
            ordinal: 0,
            timestamp: nil,
            actorName: nil,
            resourceID: "agent:validation-global",
            kind: .agent,
            status: .completed,
            durationMs: nil,
            confidence: .exact,
            errorCategory: nil
        )
        let evaluation = InvocationEvaluation(
            invocationID: event.id,
            sessionID: event.sessionID,
            resourceID: event.resourceID,
            label: .effective,
            updatedAt: Date(timeIntervalSince1970: 1_754_000_000)
        )
        let model = TasksViewModel(
            sessions: [],
            evaluations: [event.id: evaluation],
            selectedTaskID: event.sessionID,
            selectedEventID: event.id
        )

        let languageStore = AppLanguageStore(memoryLanguage: .simplifiedChinese)
        for language in [AppLanguage.simplifiedChinese, .english, .simplifiedChinese] {
            languageStore.setLanguage(language)
            XCTAssertEqual(model.selectedTaskID, event.sessionID)
            XCTAssertEqual(model.selectedEventID, event.id)
            XCTAssertEqual(model.evaluation(for: event.id), evaluation)
        }
    }
}
