import Foundation
import DirectorCore

/// Presentation model for the Home quota module. It deliberately consumes
/// reported weekly quota observations only; token totals are not involved.
public struct QuotaOverviewModel: Equatable, Sendable {
    public struct Source: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let snapshotCount: Int

        public init(id: String, name: String, snapshotCount: Int) {
            self.id = id
            self.name = name
            self.snapshotCount = snapshotCount
        }
    }

    public struct DailySnapshot: Identifiable, Equatable, Sendable {
        public let date: Date
        public let observation: QuotaSnapshot?
        public let cycleChanged: Bool
        /// Percentage of the weekly allowance observed as used during this
        /// local calendar day. Nil is unavailable evidence, not zero.
        public let usedPercent: Double?

        public var id: Date { date }

        public init(
            date: Date,
            observation: QuotaSnapshot?,
            cycleChanged: Bool,
            usedPercent: Double?
        ) {
            self.date = date
            self.observation = observation
            self.cycleChanged = cycleChanged
            self.usedPercent = usedPercent
        }
    }

    public let now: Date
    public let calendar: Calendar
    public let sources: [Source]
    public let selectedSourceID: String?
    public let currentObservation: QuotaSnapshot?
    public let dailySnapshots: [DailySnapshot]
    private let compactSnapshot: QuotaOverviewSnapshot?

    public var selectedSource: Source? { sources.first { $0.id == selectedSourceID } }
    public var isCurrentObservationStale: Bool {
        guard let currentObservation else { return false }
        // Home's contract treats the exact reset instant as stale as well.
        return currentObservation.resetsAt.map { $0 <= now } ?? false
    }
    public var remainingPercent: Double? {
        guard let currentObservation, !isCurrentObservationStale else { return nil }
        return currentObservation.remainingPercent
    }
    public var isAwaitingNewData: Bool { currentObservation == nil || isCurrentObservationStale }

    public init(
        snapshots: [QuotaSnapshot],
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        selectedSourceID: String? = nil
    ) {
        var calendar = calendar
        calendar.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        self.allSnapshots = snapshots
        self.compactSnapshot = nil
        self.now = now
        self.calendar = calendar

        let weekly = snapshots.filter { $0.isWeeklyWindow && $0.capturedAt <= now }
        let grouped = Dictionary(grouping: weekly, by: Self.sourceID(for:))
        let builtSources = grouped.map { id, values in
            Source(id: id, name: Self.sourceName(for: id, snapshots: values), snapshotCount: values.count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.sources = builtSources

        let resolvedID: String?
        if let selectedSourceID, builtSources.contains(where: { $0.id == selectedSourceID }) {
            resolvedID = selectedSourceID
        } else {
            resolvedID = builtSources.first?.id
        }
        self.selectedSourceID = resolvedID

        guard let resolvedID else {
            currentObservation = nil
            dailySnapshots = Self.emptyDays(now: now, calendar: calendar)
            return
        }
        let sourceSnapshots = (grouped[resolvedID] ?? []).sorted { $0.capturedAt < $1.capturedAt }
        currentObservation = sourceSnapshots.last
        dailySnapshots = Self.makeDailySnapshots(sourceSnapshots, now: now, calendar: calendar)
    }

    /// Adapts the compact startup projection without asking SQLite for the
    /// raw quota history again. The snapshot's per-source daily values remain
    /// authoritative, including cycle markers and stable source names.
    public init(
        snapshot: QuotaOverviewSnapshot,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        selectedSourceID: String? = nil
    ) {
        var calendar = calendar
        calendar.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        self.allSnapshots = []
        self.compactSnapshot = snapshot
        self.now = now
        self.calendar = calendar
        let sourceValues = snapshot.sources.map {
            Source(id: $0.id, name: $0.name, snapshotCount: $0.daily.compactMap(\.observation).count)
        }
        self.sources = sourceValues
        let resolvedID = selectedSourceID.flatMap { id in sourceValues.contains { $0.id == id } ? id : nil } ?? sourceValues.first?.id
        self.selectedSourceID = resolvedID
        guard let resolvedID, let source = snapshot.sources.first(where: { $0.id == resolvedID }) else {
            self.currentObservation = nil
            self.dailySnapshots = Self.emptyDays(now: now, calendar: calendar)
            return
        }
        self.currentObservation = source.current
        self.dailySnapshots = Self.makeCompactDailySnapshots(source.daily, calendar: calendar)
    }

    /// Rebuild with a new observation set while retaining the selected source
    /// whenever that source still exists.
    public func refreshed(with snapshots: [QuotaSnapshot], now: Date? = nil, calendar: Calendar? = nil) -> QuotaOverviewModel {
        QuotaOverviewModel(
            snapshots: snapshots,
            now: now ?? self.now,
            calendar: calendar ?? self.calendar,
            selectedSourceID: selectedSourceID
        )
    }

    public func selectingSource(_ sourceID: String) -> QuotaOverviewModel {
        if let compactSnapshot {
            return QuotaOverviewModel(snapshot: compactSnapshot, now: now, calendar: calendar, selectedSourceID: sourceID)
        }
        return QuotaOverviewModel(snapshots: allSnapshots, now: now, calendar: calendar, selectedSourceID: sourceID)
    }

    // Keeps refresh/source selection deterministic without exposing a mutable
    // store. The view model is intentionally a value over the supplied facts.
    private let allSnapshots: [QuotaSnapshot]

    private static func sourceID(for snapshot: QuotaSnapshot) -> String {
        if let limitID = snapshot.limitID, !limitID.isEmpty { return "id:\(limitID)" }
        if let limitName = snapshot.limitName, !limitName.isEmpty { return "name:\(limitName)" }
        return "unknown"
    }

    private static func sourceName(for id: String, snapshots: [QuotaSnapshot]) -> String {
        if let name = snapshots.compactMap({ $0.limitName }).first(where: { !$0.isEmpty }) { return name }
        if let snapshot = snapshots.first, let limitID = snapshot.limitID, !limitID.isEmpty { return limitID }
        return id == "unknown" ? "Unknown source" : id.replacingOccurrences(of: "^(id:|name:)", with: "", options: .regularExpression)
    }

    private static func emptyDays(now: Date, calendar: Calendar) -> [DailySnapshot] {
        (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            return DailySnapshot(date: day, observation: nil, cycleChanged: false, usedPercent: nil)
        }
    }

    private static func makeDailySnapshots(_ observations: [QuotaSnapshot], now: Date, calendar: Calendar) -> [DailySnapshot] {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).reversed().compactMap { offset in calendar.date(byAdding: .day, value: -offset, to: today) }
        return days.map { day in
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let candidates = observations.filter { $0.capturedAt >= day && $0.capturedAt < next }
            let selected = candidates.max { $0.capturedAt < $1.capturedAt }
            let changed: Bool
            if selected != nil {
                // Compare the first observation of this day with the last
                // observation before the day. Looking only at the observation
                // immediately before the selected (latest) one misses a
                // reset when today contains multiple observations.
                let first = candidates.min { $0.capturedAt < $1.capturedAt }
                let priorBeforeDay = observations.last { $0.capturedAt < day }
                let sameDayTransition = candidates.dropFirst().contains { item in
                    guard let previousIndex = observations.firstIndex(where: { $0.id == item.id }), previousIndex > 0 else { return false }
                    let previous = observations[previousIndex - 1]
                    return previous.capturedAt >= day && QuotaDailyUsage.reportedCycleChanged(from: previous, to: item)
                }
                let boundaryTransition: Bool
                if let first, let priorBeforeDay {
                    boundaryTransition = QuotaDailyUsage.reportedCycleChanged(from: priorBeforeDay, to: first)
                } else {
                    boundaryTransition = false
                }
                changed = sameDayTransition || boundaryTransition
            } else {
                changed = false
            }
            return DailySnapshot(
                date: day,
                observation: selected,
                cycleChanged: changed,
                usedPercent: QuotaDailyUsage.observedUsedPercent(
                    on: day,
                    observations: observations,
                    calendar: calendar
                )
            )
        }
    }

    /// New compact projections carry the fully reset-aware value. For a
    /// schema-v1 cache written by an older app, preserve startup availability
    /// by deriving only an unambiguous adjacent-day increase. Reset days and
    /// gaps remain unavailable until the next bounded quota projection.
    private static func makeCompactDailySnapshots(
        _ days: [QuotaOverviewDay],
        calendar: Calendar
    ) -> [DailySnapshot] {
        var previousObservation: QuotaSnapshot?
        var previousObservationDay: Date?
        return days.map { day in
            let legacyValue: Double?
            if day.usedPercentDelta != nil {
                legacyValue = nil
            } else {
                legacyValue = legacyDailyUsedPercent(
                    day: day.day,
                    observation: day.observation,
                    previousObservation: previousObservation,
                    previousObservationDay: previousObservationDay,
                    calendar: calendar
                )
            }
            if let observation = day.observation {
                previousObservation = observation
                previousObservationDay = day.day
            }
            return DailySnapshot(
                date: day.day,
                observation: day.observation,
                cycleChanged: day.cycleChanged,
                usedPercent: day.usedPercentDelta ?? legacyValue
            )
        }
    }

    private static func legacyDailyUsedPercent(
        day: Date,
        observation: QuotaSnapshot?,
        previousObservation: QuotaSnapshot?,
        previousObservationDay: Date?,
        calendar: Calendar
    ) -> Double? {
        guard let observation, (0...100).contains(observation.usedPercent) else { return nil }
        guard let previousObservation, let previousObservationDay else {
            return observation.usedPercent == 0 ? 0 : nil
        }
        guard let expectedPriorDay = calendar.date(byAdding: .day, value: -1, to: day),
              calendar.isDate(previousObservationDay, inSameDayAs: expectedPriorDay),
              (0...100).contains(previousObservation.usedPercent) else { return nil }

        guard QuotaDailyUsage.isSameReportedCycle(
            from: previousObservation,
            to: observation
        ) == true else { return nil }
        let difference = observation.usedPercent - previousObservation.usedPercent
        return difference >= 0 ? difference : nil
    }

}
