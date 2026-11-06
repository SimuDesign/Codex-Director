import Combine
import Foundation
import DirectorCore

/// Presentation-only adapter for the quota-history page.
///
/// The controller owns the bounded read, cancellation and window session. This
/// model only derives labels, display facts and the small set of actions the
/// page needs. It never reads preferences, SQLite or source files directly.
@MainActor
public final class QuotaHistoryViewModel: ObservableObject {
    public let controller: QuotaHistoryController
    @Published public private(set) var homeQuotaModel: QuotaOverviewModel

    private var controllerObservation: AnyCancellable?

    public init(controller: QuotaHistoryController, homeQuotaModel: QuotaOverviewModel) {
        self.controller = controller
        self.homeQuotaModel = homeQuotaModel
        controllerObservation = controller.objectWillChange.sink { [weak self] _ in
            // Forward controller updates through the page's single
            // observation of this presentation adapter.
            self?.objectWillChange.send()
        }
    }

    /// Resolves only an uninitialized app selection. A non-nil missing ID is
    /// deliberately returned unchanged so a pinned history session cannot
    /// silently query another Home source.
    public static func initialSourceID(
        rawSelection: String?,
        sources: [QuotaOverviewModel.Source]
    ) -> String? {
        rawSelection ?? sources.first?.id
    }

    static func chartReferenceValues(for values: [Double]) -> [Double] {
        let peak = values.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        let top = max(100, ceil(peak / 20) * 20)
        return Array(stride(from: 0, through: top, by: 20))
    }

    public var period: QuotaHistoryPeriod { controller.period }
    public var phase: QuotaHistoryPhase { controller.phase }
    public var sourceKey: String? { controller.sourceKey }
    public var sourceName: String? { controller.sourceName }
    public var sourceOptions: [QuotaOverviewModel.Source] { homeQuotaModel.sources }
    /// The controller's raw pinned key is the page selection source of truth.
    /// `QuotaOverviewModel.selectedSource` may resolve a missing key to the
    /// first available source, which is intentionally not used here.
    public var selectedSourceLabel: String {
        guard let sourceKey else {
            return ""
        }
        return sourceOptions.first(where: { $0.id == sourceKey })?.name ?? sourceName ?? sourceKey
    }
    public var days: [QuotaHistoryDay] { controller.days }
    public var selectedDay: Date? { controller.selectedDay }
    public var expandedDay: QuotaHistoryDay? { controller.expandedDay }
    public var recordedDayCount: Int? { controller.recordedDayCount }
    public var calculableDayCount: Int? { controller.calculableDayCount }
    /// The controller tracks source availability for its history snapshot;
    /// Home also owns the current source projection. Require both to agree so
    /// an account-only refresh or source removal cannot fall back to another
    /// Home source while this page remains open.
    public var isSourceAvailable: Bool {
        controller.isSourceAvailable && isHomeSourceAvailable
    }
    public var isHomeSourceAvailable: Bool {
        guard let sourceKey else { return false }
        return homeQuotaModel.sources.contains { $0.id == sourceKey }
    }
    public var snapshot: QuotaHistorySnapshot? { controller.snapshot }
    public var visibleTransitions: [QuotaHistoryTransition] {
        var seen = Set<String>()
        return days.flatMap(\.transitions).filter { seen.insert($0.id).inserted }
    }
    public var transitionCount: Int { visibleTransitions.count }

    /// The current allowance is intentionally read from Home's existing
    /// projection. History snapshots never masquerade as a live account read.
    public var currentQuotaModel: QuotaOverviewModel {
        guard let sourceKey,
              homeQuotaModel.sources.contains(where: { $0.id == sourceKey }) else {
            // Do not let QuotaOverviewModel.selectingSource fall back to a
            // different source when the pinned Home source disappears.
            return QuotaOverviewModel(
                snapshots: [],
                now: homeQuotaModel.now,
                calendar: homeQuotaModel.calendar
            )
        }
        if sourceKey == homeQuotaModel.selectedSourceID { return homeQuotaModel }
        return homeQuotaModel.selectingSource(sourceKey)
    }

    public var weeklyObservation: QuotaSnapshot? { currentQuotaModel.currentObservation }
    public var shortObservation: QuotaSnapshot? { currentQuotaModel.shortCurrentObservation }
    public var weeklyRemainingPercent: Double? { currentQuotaModel.remainingPercent }
    public var shortRemainingPercent: Double? { currentQuotaModel.shortRemainingPercent }
    public var isWeeklyCurrentStale: Bool { currentQuotaModel.isCurrentObservationStale }
    public var isShortCurrentStale: Bool { currentQuotaModel.isShortObservationStale }

    public var hasHistoryRows: Bool { snapshot != nil }
    public var hasRecordedDays: Bool { (recordedDayCount ?? 0) > 0 }
    public var isLoading: Bool { phase == .loading }
    public var isUpdating: Bool { phase == .updating }
    public var isFailure: Bool { phase == .failed }
    public var isUnavailable: Bool { phase == .unavailable || !isSourceAvailable }

    public func updateHomeQuotaModel(_ model: QuotaOverviewModel) {
        guard homeQuotaModel != model else { return }
        homeQuotaModel = model
    }

    public func setPeriod(_ period: QuotaHistoryPeriod) {
        controller.setPeriod(period)
    }

    public func selectDay(_ day: Date) {
        controller.selectDay(day)
    }

    public func retry() {
        controller.retry()
    }

    /// The first twenty transitions are an in-memory page. The controller
    /// already fetched one bounded snapshot; this method deliberately never
    /// starts another query.
    public func transitions(for day: QuotaHistoryDay, page: Int = 0) -> [QuotaHistoryTransition] {
        let pageSize = 20
        let safePage = max(0, page)
        let start = safePage * pageSize
        guard start < day.transitions.count else { return [] }
        return Array(day.transitions.dropFirst(start).prefix(pageSize))
    }

    public func remainingTransitionCount(for day: QuotaHistoryDay, page: Int = 0) -> Int {
        let pageSize = 20
        let safePage = max(0, page)
        return max(0, day.transitions.count - ((safePage + 1) * pageSize))
    }

    public func statusReason(for state: QuotaHistoryDayState) -> QuotaHistoryDayReason {
        switch state {
        case .available: return .available
        case .noObservation: return .noObservation
        case .missingBaseline: return .missingBaseline
        case .crossDayGap: return .crossDayGap
        case .ambiguousCycle: return .ambiguousCycle
        case .evidenceConflict: return .evidenceConflict
        }
    }
}

public enum QuotaHistoryDayReason: Equatable, Sendable {
    case available
    case noObservation
    case missingBaseline
    case crossDayGap
    case ambiguousCycle
    case evidenceConflict
}
