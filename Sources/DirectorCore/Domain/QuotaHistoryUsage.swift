import Foundation

/// One ordered pass over the selected source's fixed context. Unknown evidence
/// stays unknown until a later cycle is proved; it is never filled backwards.
public enum QuotaHistoryUsage {
    private struct DayWork {
        var count = 0
        var first: QuotaSnapshot?
        var last: QuotaSnapshot?
        var baseline: QuotaSnapshot?
        var state: QuotaHistoryDayState = .noObservation
        var total = 0.0
        var segmentBaseline: Double?
        var highWater = 0.0
        var latest = 0.0
        var transitions: [QuotaHistoryTransition] = []

        mutating func accept(_ current: QuotaSnapshot, previous: QuotaSnapshot?, relationship: QuotaCycleClassifier.Relationship) {
            if first == nil {
                first = current
                if let previous, previous.capturedAt < current.capturedAt {
                    baseline = previous
                    segmentBaseline = previous.usedPercent
                    highWater = previous.usedPercent
                    latest = previous.usedPercent
                } else if current.usedPercent == 0 {
                    baseline = current
                    segmentBaseline = 0
                    highWater = 0
                    latest = 0
                } else if state == .noObservation {
                    state = .missingBaseline
                }
            }
            last = current
            switch relationship {
            case .same:
                highWater = max(highWater, current.usedPercent)
                latest = current.usedPercent
            case .reset:
                if let segmentBaseline {
                    if latest + QuotaCycleClassifier.percentageTolerance < highWater { state = .ambiguousCycle }
                    total += highWater - segmentBaseline
                }
                segmentBaseline = 0
                highWater = current.usedPercent
                latest = current.usedPercent
            case .stalePreviousCycle, .ambiguous:
                break
            }
        }
    }

    public static func project(
        query: QuotaHistoryQuery,
        identity: PresentationIdentity,
        observations: [QuotaSnapshot],
        readAt: Date = Date(),
        cancellation: SQLiteCancellationToken? = nil
    ) throws -> QuotaHistorySnapshot {
        let calendar = query.calendar
        let start = query.contextStart
        // The public pure projection must enforce the same source and cutoff
        // boundary as the SQLite reader. Lookahead is evidence too: filtering
        // only the current loop row would let another source or a future row
        // reaffirm an otherwise ambiguous cycle.
        let ordered = observations
            .filter {
                $0.isWeeklyWindow
                    && QuotaCycleClassifier.sourceKey($0) == query.sourceKey
                    && $0.capturedAt <= query.asOf
            }
            .sorted(by: QuotaCycleClassifier.earliestFirst)
        let boundaries = (0...60).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        let predecessorDayStart = calendar.date(byAdding: .day, value: -1, to: start)!
        var work = Array(repeating: DayWork(), count: 60)
        var dayCursor = 0
        var previous: QuotaSnapshot?
        var anchor: Date?
        var exited: [Date] = []
        var unknown = false
        var zeroCandidate: QuotaSnapshot?
        var transitions: [QuotaHistoryTransition] = []
        var lastObservedAt: Date?

        for index in ordered.indices {
            if index & 255 == 0, cancellation?.shouldInterrupt == true { throw SQLiteError.cancelled }
            let current = ordered[index]
            guard current.isWeeklyWindow,
                  QuotaCycleClassifier.sourceKey(current) == query.sourceKey,
                  current.capturedAt <= query.asOf else { continue }
            while dayCursor < 60 && current.capturedAt >= boundaries[dayCursor + 1] {
                dayCursor += 1
            }
            let dayIndex = current.capturedAt < start ? -1 : dayCursor
            let inContext = (0..<60).contains(dayIndex)
            if inContext, QuotaCycleClassifier.isValid(current.usedPercent) {
                lastObservedAt = current.capturedAt
                work[dayIndex].count += 1
            }
            guard QuotaCycleClassifier.isValid(current.usedPercent),
                  QuotaCycleClassifier.isFutureReset(current) else {
                unknown = true
                if inContext { work[dayIndex].state = .ambiguousCycle }
                continue
            }

            let before = previous
            var relation: QuotaCycleClassifier.Relationship = .same
            var recoveredNow = false
            var recoveryBaseline: QuotaSnapshot?
            if let before {
                relation = QuotaCycleClassifier.relationship(
                    from: before, to: current, acceptedAnchor: anchor,
                    exitedAnchors: exited, following: ordered[(index + 1)...],
                    lookaheadCutoff: inContext ? boundaries[dayIndex + 1] : start
                )
                if unknown {
                    if case .reset = relation {
                        recoveredNow = true
                    } else if let candidate = zeroCandidate,
                              candidate.id != current.id,
                              let candidateReset = candidate.resetsAt,
                              let currentReset = current.resetsAt,
                              abs(currentReset.timeIntervalSince(candidateReset)) <= QuotaCycleClassifier.resetTimeTolerance,
                              current.usedPercent >= candidate.usedPercent {
                        recoveredNow = true
                        relation = .same
                        recoveryBaseline = candidate
                        previous = candidate
                        anchor = candidate.resetsAt
                    } else {
                        if current.usedPercent == 0, current.resetsAt != nil { zeroCandidate = current }
                        if inContext { work[dayIndex].state = .ambiguousCycle }
                        continue
                    }
                } else if case .ambiguous = relation {
                    unknown = true
                    if current.usedPercent == 0, current.resetsAt != nil { zeroCandidate = current }
                    if inContext { work[dayIndex].state = .ambiguousCycle }
                    continue
                } else if case .stalePreviousCycle = relation {
                    continue
                }
            } else if unknown {
                if let candidate = zeroCandidate,
                   candidate.id != current.id,
                   let candidateReset = candidate.resetsAt,
                   let currentReset = current.resetsAt,
                   abs(currentReset.timeIntervalSince(candidateReset)) <= QuotaCycleClassifier.resetTimeTolerance,
                   current.usedPercent >= candidate.usedPercent {
                    recoveredNow = true
                    recoveryBaseline = candidate
                    previous = candidate
                    anchor = candidate.resetsAt
                } else {
                    if current.usedPercent == 0, current.resetsAt != nil { zeroCandidate = current }
                    if inContext { work[dayIndex].state = .ambiguousCycle }
                    continue
                }
            }
            if case .reset = relation {
                if let old = anchor { exited.append(old) }
                anchor = current.resetsAt
                if let before, let acceptedAnchor = current.resetsAt, inContext {
                    let transition = QuotaHistoryTransition(id: current.id, beforeObservedAt: before.capturedAt, afterObservedAt: current.capturedAt, acceptedAnchor: acceptedAnchor)
                    transitions.append(transition)
                    work[dayIndex].transitions.append(transition)
                }
            } else if previous == nil {
                anchor = current.resetsAt
            }
            unknown = false
            zeroCandidate = nil
            if inContext {
                if recoveredNow { work[dayIndex].state = .ambiguousCycle }
                let priorStart = dayIndex == 0 ? predecessorDayStart : boundaries[dayIndex - 1]
                let adjacent = before.map { $0.capturedAt >= priorStart && $0.capturedAt < boundaries[dayIndex] } ?? false
                if work[dayIndex].first == nil, adjacent, dayIndex > 0,
                   work[dayIndex - 1].first != nil,
                   work[dayIndex - 1].latest + QuotaCycleClassifier.percentageTolerance < work[dayIndex - 1].highWater {
                    // The previous day's last low report never recovered its
                    // observed high-water mark. It cannot be today's baseline.
                    work[dayIndex].state = .ambiguousCycle
                }
                if work[dayIndex].first == nil, before != nil, !adjacent {
                    work[dayIndex].state = .crossDayGap
                }
                work[dayIndex].accept(current, previous: recoveryBaseline ?? (adjacent ? before : nil), relationship: relation)
            }
            previous = current
        }
        if cancellation?.shouldInterrupt == true { throw SQLiteError.cancelled }
        let days: [QuotaHistoryDay] = (0..<60).map { offset in
            let day = boundaries[offset]
            let item = work[offset]
            var state = item.state
            var delta: Double?
            if item.count > 0, state == .noObservation {
                if let baseline = item.segmentBaseline {
                    if item.latest + QuotaCycleClassifier.percentageTolerance < item.highWater {
                        state = .ambiguousCycle
                    } else {
                        state = .available
                        delta = item.total + item.highWater - baseline
                    }
                } else {
                    state = .missingBaseline
                }
            }
            return QuotaHistoryDay(
                day: day, observationCount: item.count, state: state,
                usedPercentDelta: delta, firstObservedAt: item.first?.capturedAt,
                lastObservedAt: item.last?.capturedAt,
                baseline: item.baseline.map(QuotaHistoryObservationSummary.init),
                firstObservation: item.first.map(QuotaHistoryObservationSummary.init),
                lastObservation: item.last.map(QuotaHistoryObservationSummary.init),
                transitions: item.transitions,
                comparisonKey: QuotaHistoryComparisonKey.home(identity: identity, sourceKey: query.sourceKey, day: day, timeZone: query.timeZone, asOf: query.asOf)
            )
        }
        return QuotaHistorySnapshot(identity: identity, sourceKey: query.sourceKey, timeZoneIdentifier: query.timeZone.identifier, asOf: query.asOf, contextStart: start, readAt: readAt, lastObservedAt: lastObservedAt, days: days, transitions: transitions)
    }
}
