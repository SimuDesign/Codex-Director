import Foundation

/// Derives observed daily use from account-reported weekly allowance facts.
///
/// The result is a percentage-point increase in the reported `usedPercent`,
/// not a token-derived estimate. Callers provide observations for one
/// canonical quota source; mixed sources or ambiguous transitions return nil.
public enum QuotaDailyUsage {
    private static let resetTimeTolerance: TimeInterval = 5 * 60
    private static let percentageTolerance = 0.000_001

    public static func observedUsedPercent(
        on day: Date,
        observations: [QuotaSnapshot],
        calendar: Calendar
    ) -> Double? {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return nil }

        let eligible = observations
            .filter { $0.isWeeklyWindow && $0.capturedAt < interval.end }
            .sorted {
                $0.capturedAt < $1.capturedAt ||
                    ($0.capturedAt == $1.capturedAt && $0.id < $1.id)
            }
        guard Set(eligible.map(sourceKey)).count <= 1 else { return nil }

        let daily = eligible.filter { $0.capturedAt >= interval.start }
        guard let first = daily.first else { return nil }
        guard isValid(first.usedPercent) else { return nil }

        var previous = eligible.last { $0.capturedAt < interval.start }
        var startIndex = daily.startIndex

        // A reported zero is itself a usable baseline when history starts on
        // this day. A non-zero first observation cannot reveal earlier use.
        if let previous,
           let priorDay = calendar.date(byAdding: .day, value: -1, to: interval.start),
           !calendar.isDate(previous.capturedAt, inSameDayAs: priorDay) {
            return nil
        } else if previous == nil {
            guard first.usedPercent == 0 else { return nil }
            previous = first
            startIndex = daily.index(after: startIndex)
        }

        guard var previous else { return nil }
        guard isValid(previous.usedPercent) else { return nil }

        var total = 0.0
        var segmentBaseline = previous.usedPercent
        var segmentHighWater = previous.usedPercent
        var segmentLatest = previous.usedPercent

        for current in daily[startIndex...] {
            guard isValid(current.usedPercent) else { return nil }

            switch cycleRelationship(from: previous, to: current) {
            case .same:
                // Concurrent session logs can replay a slightly older quota
                // value before returning to the current value. Keep the
                // cycle's observed high-water mark so a recovered regression
                // neither invalidates the day nor counts the recovery twice.
                segmentHighWater = max(segmentHighWater, current.usedPercent)
                segmentLatest = current.usedPercent
            case .reset:
                guard hasRecovered(latest: segmentLatest, highWater: segmentHighWater) else {
                    return nil
                }
                total += max(0, segmentHighWater - segmentBaseline)
                segmentBaseline = 0
                segmentHighWater = current.usedPercent
                segmentLatest = current.usedPercent
            case .ambiguous:
                return nil
            }
            previous = current
        }

        // A lower final observation that never returns to the high-water mark
        // is still ambiguous and must remain unavailable rather than being
        // silently treated as stale.
        guard hasRecovered(latest: segmentLatest, highWater: segmentHighWater) else {
            return nil
        }
        total += max(0, segmentHighWater - segmentBaseline)
        return total
    }

    /// Reports a reset only when both observations carry materially different
    /// reset instants. Missing reset evidence remains non-affirmative.
    public static func reportedCycleChanged(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot
    ) -> Bool {
        if case .reset = cycleRelationship(from: previous, to: current) {
            return true
        }
        return false
    }

    /// Returns nil when one side lacks reset evidence.
    public static func isSameReportedCycle(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot
    ) -> Bool? {
        switch cycleRelationship(from: previous, to: current) {
        case .same: true
        case .reset: false
        case .ambiguous: nil
        }
    }

    private enum CycleRelationship {
        case same
        case reset
        case ambiguous
    }

    private static func cycleRelationship(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot
    ) -> CycleRelationship {
        switch (previous.resetsAt, current.resetsAt) {
        case let (.some(previousReset), .some(currentReset)):
            // Reset timestamps can be reconstructed from a countdown and
            // therefore drift by seconds across otherwise identical reports.
            return abs(currentReset.timeIntervalSince(previousReset)) <= resetTimeTolerance
                ? .same
                : .reset
        case (nil, nil):
            return .same
        case (.some, nil), (nil, .some):
            return .ambiguous
        }
    }

    private static func hasRecovered(latest: Double, highWater: Double) -> Bool {
        latest + percentageTolerance >= highWater
    }

    private static func sourceKey(_ snapshot: QuotaSnapshot) -> String {
        if let id = snapshot.limitID, !id.isEmpty { return "id:\(id)" }
        if let name = snapshot.limitName, !name.isEmpty { return "name:\(name)" }
        return "unknown"
    }

    private static func isValid(_ percentage: Double) -> Bool {
        percentage.isFinite && (0...100).contains(percentage)
    }
}
