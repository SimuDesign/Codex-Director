import Foundation
import Combine
import DirectorCore

public enum QuotaHistoryPhase: Equatable, Sendable {
    case idle
    case loading
    case updating
    case loaded
    case failed
    case unavailable
}

public enum QuotaHistoryControllerError: Error, Sendable {
    case databaseNotReady
}

/// One window's bounded history session. Its only data read is the injected
/// local database query; period and day changes slice the immutable result.
@MainActor
public final class QuotaHistoryController: ObservableObject {
    public typealias Fetch = @MainActor @Sendable (QuotaHistoryQuery, SQLiteCancellationToken) async throws -> QuotaHistorySnapshot

    @Published public private(set) var phase: QuotaHistoryPhase = .idle
    @Published public private(set) var period: QuotaHistoryPeriod
    @Published public private(set) var sourceKey: String?
    @Published public private(set) var sourceName: String?
    @Published public private(set) var snapshot: QuotaHistorySnapshot?
    @Published public private(set) var selectedDay: Date?
    @Published public private(set) var isSourceAvailable = true
    public private(set) var sessionID: UUID?

    public var days: [QuotaHistoryDay] { snapshot?.days(for: period) ?? [] }
    public var recordedDayCount: Int? { snapshot?.recordedDayCount(for: period) }
    public var calculableDayCount: Int? { snapshot?.calculableDayCount(for: period) }
    public var expandedDay: QuotaHistoryDay? {
        guard let selectedDay else { return nil }
        return days.first { $0.day == selectedDay }
    }
    public var isOpen: Bool { sourceKey != nil }

    private let preferences: QuotaHistoryPreferences
    private let now: @MainActor () -> Date
    private let timeZone: @MainActor () -> TimeZone
    private let serviceReady: @MainActor () -> Bool
    private let dataGeneration: @MainActor () -> UInt64
    private let fetch: Fetch
    private let cancellationTimeout: Duration
    private var preferencesCancellable: AnyCancellable?
    private var homeSnapshot: QuotaOverviewSnapshot?
    private var rawSnapshot: QuotaHistorySnapshot?
    /// Window-local browsing memory. Only the selected date is retained;
    /// neither preference storage nor the database receives this state.
    private var selectedDayBySource: [String: Date] = [:]
    private var query: QuotaHistoryQuery?
    private var task: Task<Void, Never>?
    private var cancellation: SQLiteCancellationToken?
    private var requestGeneration: UInt64 = 0

    public init(
        preferences: QuotaHistoryPreferences,
        now: @escaping @MainActor () -> Date,
        timeZone: @escaping @MainActor () -> TimeZone,
        serviceReady: @escaping @MainActor () -> Bool,
        dataGeneration: @escaping @MainActor () -> UInt64,
        cancellationTimeout: Duration = .seconds(5),
        fetch: @escaping Fetch
    ) {
        self.preferences = preferences
        self.period = preferences.period
        self.now = now
        self.timeZone = timeZone
        self.serviceReady = serviceReady
        self.dataGeneration = dataGeneration
        self.cancellationTimeout = cancellationTimeout
        self.fetch = fetch
        preferencesCancellable = preferences.$period.removeDuplicates().sink { [weak self] period in
            self?.period = period
        }
    }

    /// Opening pins the canonical Home source; a later Home source selection
    /// never silently changes this session's calculation boundary. A nil
    /// source is an intentional, navigable empty state: it creates a page
    /// session but starts no bounded read or invented-source query.
    @discardableResult
    public func open(sourceKey: String, sourceName: String, homeSnapshot: QuotaOverviewSnapshot?) -> UUID? {
        open(sourceKey: Optional(sourceKey), sourceName: Optional(sourceName), homeSnapshot: homeSnapshot)
    }

    @discardableResult
    public func open(sourceKey: String?, sourceName: String?, homeSnapshot: QuotaOverviewSnapshot?) -> UUID {
        if let sourceKey { guard !sourceKey.isEmpty else { return open(sourceKey: nil, sourceName: nil, homeSnapshot: homeSnapshot) } }
        cancelRead()
        let sessionID = UUID()
        self.sessionID = sessionID
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.homeSnapshot = homeSnapshot
        self.snapshot = nil
        rawSnapshot = nil
        selectedDay = sourceKey.flatMap { selectedDayBySource[$0] }
        isSourceAvailable = sourceKey != nil
        query = nil
        if sourceKey != nil {
            requestRead()
        } else {
            phase = .unavailable
        }
        return sessionID
    }

    /// Explicit source selection from the page. This preserves the active
    /// window session while replacing its pinned query key and resetting the
    /// bounded result; Home's automatically resolved first source is never
    /// consulted here.
    public func setSource(sourceKey: String?, sourceName: String?, homeSnapshot: QuotaOverviewSnapshot?) {
        guard sourceKey != self.sourceKey else {
            self.sourceName = sourceName ?? self.sourceName
            updateHomeSnapshot(homeSnapshot)
            return
        }
        cancelRead()
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.homeSnapshot = homeSnapshot
        self.snapshot = nil
        self.rawSnapshot = nil
        self.selectedDay = sourceKey.flatMap { selectedDayBySource[$0] }
        self.isSourceAvailable = sourceKey != nil
        self.query = nil
        if sourceKey != nil {
            requestRead()
        } else {
            phase = .unavailable
        }
    }

    public func close(sessionID: UUID? = nil) {
        if let sessionID, self.sessionID != sessionID { return }
        cancelRead()
        self.sessionID = nil
        sourceKey = nil
        sourceName = nil
        snapshot = nil
        rawSnapshot = nil
        selectedDay = nil
        homeSnapshot = nil
        query = nil
        isSourceAvailable = true
        phase = .idle
    }

    public func setPeriod(_ period: QuotaHistoryPeriod) {
        preferences.setPeriod(period)
    }

    public func selectDay(_ day: Date) {
        selectedDay = selectedDay == day ? nil : day
        if let sourceKey { selectedDayBySource[sourceKey] = selectedDay }
    }

    public func retry() { requestRead(force: true) }

    /// Called by the shared app model only after a successful source commit.
    /// It coalesces the invalidation into one replacement read for this page.
    public func indexedDataDidCommit() {
        guard isOpen else { return }
        requestRead(force: true)
    }

    /// Revokes all work before SQLite deletion can finish. No old task may
    /// republish a result even if an actor read ignores cancellation briefly.
    public func derivedDataWillDelete() {
        cancelRead()
        snapshot = nil
        rawSnapshot = nil
        selectedDay = nil
        selectedDayBySource.removeAll()
        query = nil
        isSourceAvailable = false
        phase = .unavailable
    }

    public func serviceDidChange() {
        cancelRead()
        snapshot = nil
        rawSnapshot = nil
        query = nil
        if isOpen { requestRead() }
    }

    /// Clock, time-zone and resume hooks are event-driven; there is no history
    /// timer. Same-day resumes preserve the bounded snapshot without I/O.
    public func checkClockAndRefresh() {
        guard let sourceKey, let query else { return }
        let current = QuotaHistoryQuery(sourceKey: sourceKey, asOf: now(), timeZone: timeZone())
        guard current.timeZone != query.timeZone || current.calendar.startOfDay(for: current.asOf) != query.calendar.startOfDay(for: query.asOf) else { return }
        cancelRead()
        snapshot = nil
        rawSnapshot = nil
        self.query = nil
        requestRead()
    }

    /// Home may publish a newer seven-day projection or current-only account
    /// update. Comparison updates are in memory and never start history I/O.
    public func updateHomeSnapshot(_ overview: QuotaOverviewSnapshot?) {
        homeSnapshot = overview
        if let sourceKey, let overview {
            isSourceAvailable = overview.sources.contains { $0.id == sourceKey }
        } else if sourceKey == nil {
            isSourceAvailable = false
        }
        if let rawSnapshot { snapshot = Self.checkedAgainstHome(rawSnapshot, overview: overview) }
    }

    private func requestRead(force: Bool = false) {
        guard let sourceKey else { return }
        let proposed = QuotaHistoryQuery(sourceKey: sourceKey, asOf: now(), timeZone: timeZone())
        if !force, task != nil, query == proposed { return }
        guard serviceReady() else {
            phase = .loading
            return
        }
        cancelRead()
        query = proposed
        let request = requestGeneration
        let generation = dataGeneration()
        let token = SQLiteCancellationToken(timeout: cancellationTimeout)
        cancellation = token
        phase = snapshot == nil ? .loading : .updating
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetch(proposed, token)
                guard !Task.isCancelled,
                      self.requestGeneration == request,
                      self.dataGeneration() == generation,
                      self.sourceKey == proposed.sourceKey,
                      self.query == proposed,
                      result.sourceKey == proposed.sourceKey,
                      result.timeZoneIdentifier == proposed.timeZone.identifier,
                      result.asOf == proposed.asOf else { return }
                if token.shouldInterrupt {
                    self.phase = .failed
                    self.task = nil
                    self.cancellation = nil
                    return
                }
                self.rawSnapshot = result
                self.snapshot = Self.checkedAgainstHome(result, overview: self.homeSnapshot)
                self.phase = .loaded
                self.task = nil
                self.cancellation = nil
            } catch {
                guard !Task.isCancelled, self.requestGeneration == request,
                      self.dataGeneration() == generation,
                      self.sourceKey == proposed.sourceKey,
                      self.query == proposed else { return }
                self.phase = .failed
                self.task = nil
                self.cancellation = nil
            }
        }
    }

    private func cancelRead() {
        requestGeneration &+= 1
        cancellation?.cancel()
        cancellation = nil
        task?.cancel()
        task = nil
    }

    private static func checkedAgainstHome(_ history: QuotaHistorySnapshot, overview: QuotaOverviewSnapshot?) -> QuotaHistorySnapshot {
        guard let overview, overview.hasCurrentDailyUsageAlgorithm,
              let source = overview.sources.first(where: { $0.id == history.sourceKey }) else { return history }
        // A malformed or old cache may contain the same natural day twice.
        // Preserve that ambiguity instead of choosing an arbitrary row or
        // trapping while making the comparison map.
        let matching = Dictionary(grouping: source.daily, by: \.day)
        let days = history.days.map { day in
            guard day.state == .available, let value = day.usedPercentDelta,
                  let homeDays = matching[day.day] else { return day }
            let homeKey = QuotaHistoryComparisonKey.home(
                identity: overview.identity,
                sourceKey: history.sourceKey,
                day: day.day,
                timeZone: overview.window.timeZone,
                asOf: overview.window.end
            )
            guard day.comparisonKey == homeKey else { return day }
            guard homeDays.count == 1 else { return day.replacingWithEvidenceConflict() }
            guard let homeValue = homeDays[0].usedPercentDelta,
                  abs(value - homeValue) > 0.000_000_001 else { return day }
            return day.replacingWithEvidenceConflict()
        }
        return QuotaHistorySnapshot(
            identity: history.identity,
            sourceKey: history.sourceKey,
            timeZoneIdentifier: history.timeZoneIdentifier,
            asOf: history.asOf,
            contextStart: history.contextStart,
            readAt: history.readAt,
            lastObservedAt: history.lastObservedAt,
            days: days,
            transitions: history.transitions,
            algorithmVersion: history.algorithmVersion
        )
    }
}
