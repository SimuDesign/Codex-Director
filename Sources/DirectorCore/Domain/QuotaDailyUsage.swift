import Foundation

/// Derives observed daily use from account-reported weekly allowance facts.
///
/// The result is a percentage-point increase in the reported `usedPercent`,
/// not a token-derived estimate. Reset classification is deliberately
/// stateful: one accepted future reset instant is the cycle anchor and a
/// later report cannot roll that anchor merely because its countdown drifted.
/// Callers provide observations for one canonical quota source; mixed sources
/// or ambiguous transitions return an unavailable projection.
public enum QuotaDailyUsage {
    public static let currentAlgorithmVersion = 2

    private static let percentageTolerance = 0.000_001

    public struct DailyProjection: Equatable, Sendable {
        public let usedPercent: Double?
        public let cycleChanged: Bool

        public init(usedPercent: Double?, cycleChanged: Bool) {
            self.usedPercent = usedPercent
            self.cycleChanged = cycleChanged
        }
    }

    /// Projects both the daily value and reset marker from one bounded,
    /// statefully classified sequence. Callers must use this result for both
    /// fields so a marker can never disagree with the value's reset segments.
    public static func project(
        on day: Date,
        observations: [QuotaSnapshot],
        calendar: Calendar
    ) -> DailyProjection {
        guard let interval = calendar.dateInterval(of: .day, for: day) else {
            return DailyProjection(usedPercent: nil, cycleChanged: false)
        }

        let eligible = observations
            .filter { $0.isWeeklyWindow && $0.capturedAt < interval.end }
            .sorted(by: earliestFirst)
        guard Set(eligible.map(sourceKey)).count <= 1,
              let classified = classify(eligible) else {
            return DailyProjection(usedPercent: nil, cycleChanged: false)
        }

        // A raw first observation can be a replay of a cycle already exited
        // earlier in the bounded sequence. It is evidence that must remain in
        // the classifier, but it cannot become either today's baseline or
        // today's first observation. Choose only accepted, valid points for
        // both edges of the daily projection.
        guard let firstIndex = classified.observations.indices.first(where: {
            classified.accepted[$0] &&
                classified.observations[$0].capturedAt >= interval.start &&
                isValid(classified.observations[$0].usedPercent)
        }) else {
            return DailyProjection(usedPercent: nil, cycleChanged: false)
        }
        let first = classified.observations[firstIndex]
        let previousIndex = classified.observations.indices[..<firstIndex].last(where: {
            let observation = classified.observations[$0]
            return observation.capturedAt < interval.start &&
                classified.accepted[$0] &&
                isValid(observation.usedPercent)
        })

        let previous: QuotaSnapshot
        var startIndex = firstIndex
        if let previousIndex {
            previous = classified.observations[previousIndex]
            guard let priorDay = calendar.date(byAdding: .day, value: -1, to: interval.start),
                  calendar.isDate(previous.capturedAt, inSameDayAs: priorDay),
                  isValid(previous.usedPercent) else {
                return DailyProjection(
                    usedPercent: nil,
                    cycleChanged: hasAcceptedReset(
                        in: classified,
                        interval: interval
                    )
                )
            }
        } else {
            guard first.usedPercent == 0 else {
                return DailyProjection(
                    usedPercent: nil,
                    cycleChanged: hasAcceptedReset(
                        in: classified,
                        interval: interval
                    )
                )
            }
            previous = first
            startIndex += 1
        }

        var total = 0.0
        var segmentBaseline = previous.usedPercent
        var segmentHighWater = previous.usedPercent
        var segmentLatest = previous.usedPercent
        var cycleChanged = false

        guard startIndex < classified.observations.count else {
            return DailyProjection(usedPercent: 0, cycleChanged: false)
        }

        for index in startIndex..<classified.observations.count {
            let current = classified.observations[index]
            guard current.capturedAt >= interval.start,
                  current.capturedAt < interval.end,
                  isValid(current.usedPercent) else { continue }

            switch classified.relationships[index] {
            case .same:
                // Replayed lower values are ignored for the segment total
                // until a later observation recovers the high-water mark.
                segmentHighWater = max(segmentHighWater, current.usedPercent)
                segmentLatest = current.usedPercent
            case .reset:
                guard hasRecovered(latest: segmentLatest, highWater: segmentHighWater) else {
                    return DailyProjection(usedPercent: nil, cycleChanged: false)
                }
                total += segmentHighWater - segmentBaseline
                segmentBaseline = 0
                segmentHighWater = current.usedPercent
                segmentLatest = current.usedPercent
                cycleChanged = true
            case .stalePreviousCycle:
                // A replay of an already exited cycle must not move the
                // accepted sequence state or add a second daily segment.
                continue
            case .ambiguous:
                return DailyProjection(usedPercent: nil, cycleChanged: false)
            }
        }

        guard hasRecovered(latest: segmentLatest, highWater: segmentHighWater) else {
            return DailyProjection(usedPercent: nil, cycleChanged: false)
        }
        total += segmentHighWater - segmentBaseline
        return DailyProjection(usedPercent: total, cycleChanged: cycleChanged)
    }

    private static func hasAcceptedReset(
        in classified: ClassifiedSequence,
        interval: DateInterval
    ) -> Bool {
        classified.observations.indices.contains { index in
            let observation = classified.observations[index]
            guard observation.capturedAt >= interval.start,
                  observation.capturedAt < interval.end,
                  classified.accepted[index] else { return false }
            if case .reset = classified.relationships[index] { return true }
            return false
        }
    }

    public static func observedUsedPercent(
        on day: Date,
        observations: [QuotaSnapshot],
        calendar: Calendar
    ) -> Double? {
        project(on: day, observations: observations, calendar: calendar).usedPercent
    }

    /// Reports a reset only when the stateful classifier accepts a new cycle
    /// from this ordered pair. Pair callers are retained for compatibility;
    /// bounded day projections use `project(on:observations:calendar:)` so all
    /// markers share the same sequence state.
    public static func reportedCycleChanged(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot
    ) -> Bool {
        guard let relationship = classify([previous, current])?.relationships.last else {
            return false
        }
        if case .reset = relationship { return true }
        return false
    }

    /// Returns nil when one side lacks reset evidence or the transition is
    /// stale/contradictory.
    public static func isSameReportedCycle(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot
    ) -> Bool? {
        guard let relationship = classify([previous, current])?.relationships.last else {
            return nil
        }
        switch relationship {
        case .same: return true
        case .reset: return false
        case .stalePreviousCycle, .ambiguous: return nil
        }
    }

    private typealias ClassifiedSequence = QuotaCycleClassifier.Sequence

    private static func classify(_ observations: [QuotaSnapshot]) -> ClassifiedSequence? {
        QuotaCycleClassifier.classify(observations)
    }

    private static func hasRecovered(latest: Double, highWater: Double) -> Bool {
        latest + percentageTolerance >= highWater
    }

    private static func earliestFirst(_ lhs: QuotaSnapshot, _ rhs: QuotaSnapshot) -> Bool {
        QuotaCycleClassifier.earliestFirst(lhs, rhs)
    }

    private static func sourceKey(_ snapshot: QuotaSnapshot) -> String {
        QuotaCycleClassifier.sourceKey(snapshot)
    }

    private static func isValid(_ percentage: Double) -> Bool {
        QuotaCycleClassifier.isValid(percentage)
    }
}
