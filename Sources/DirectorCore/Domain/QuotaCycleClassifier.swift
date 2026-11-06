import Foundation

/// Shared cycle evidence rules for the legacy Home projection and history.
internal enum QuotaCycleClassifier {
    static let resetTimeTolerance: TimeInterval = 5 * 60
    static let percentageTolerance = 0.000_001
    static let weeklyWindowDuration: TimeInterval = 7 * 24 * 60 * 60
    enum Relationship {
        case same
        case reset
        case stalePreviousCycle
        case ambiguous
    }

    struct Sequence {
        let observations: [QuotaSnapshot]
        let relationships: [Relationship]
        let accepted: [Bool]
    }

    static func classify(_ observations: [QuotaSnapshot]) -> Sequence? {
        let ordered = observations.sorted(by: earliestFirst)
        guard !ordered.isEmpty,
              Set(ordered.map(sourceKey)).count <= 1,
              ordered.allSatisfy({ isValid($0.usedPercent) }) else {
            return nil
        }

        var acceptedAnchor = ordered[0].resetsAt
        var exitedAnchors: [Date] = []
        var previous = ordered[0]
        var relationships: [Relationship] = [.same]
        var accepted = [true]
        guard isFutureReset(previous) else { return nil }

        for index in ordered.indices.dropFirst() {
            let current = ordered[index]
            let relationship = relationship(
                from: previous,
                to: current,
                acceptedAnchor: acceptedAnchor,
                exitedAnchors: exitedAnchors,
                following: ordered[(index + 1)...]
            )
            relationships.append(relationship)
            switch relationship {
            case .same:
                accepted.append(true)
                previous = current
            case .reset:
                accepted.append(true)
                if let acceptedAnchor { exitedAnchors.append(acceptedAnchor) }
                acceptedAnchor = current.resetsAt
                previous = current
            case .stalePreviousCycle:
                accepted.append(false)
                continue
            case .ambiguous:
                return nil
            }
        }
        return Sequence(observations: ordered, relationships: relationships, accepted: accepted)
    }

    static func relationship(
        from previous: QuotaSnapshot,
        to current: QuotaSnapshot,
        acceptedAnchor: Date?,
        exitedAnchors: [Date],
        following: ArraySlice<QuotaSnapshot>,
        lookaheadCutoff: Date? = nil
    ) -> Relationship {
        switch (previous.resetsAt, current.resetsAt, acceptedAnchor) {
        case (nil, nil, nil):
            return .same
        case (nil, nil, .some):
            return .ambiguous
        case (.some, nil, _), (nil, .some, _), (_, _, nil):
            return .ambiguous
        case let (.some(_), .some(currentReset), .some(anchor)):
            if matches(currentReset, anyOf: exitedAnchors) && currentReset < anchor {
                return .stalePreviousCycle
            }
            if currentReset <= current.capturedAt {
                return .ambiguous
            }
            if abs(currentReset.timeIntervalSince(anchor)) <= resetTimeTolerance {
                return .same
            }
            if currentReset < anchor.addingTimeInterval(-resetTimeTolerance) {
                // A backwards jump is stale only when it matches a cycle
                // that this sequence has already exited. A pair without
                // that history cannot prove the older identity.
                return .ambiguous
            }

            let inferredStart = currentReset.addingTimeInterval(-weeklyWindowDuration)
            let withinCaptureInterval = inferredStart >= previous.capturedAt.addingTimeInterval(-resetTimeTolerance)
                && inferredStart <= current.capturedAt.addingTimeInterval(resetTimeTolerance)
            let crossesOldAnchor = previous.capturedAt <= anchor.addingTimeInterval(resetTimeTolerance)
                && current.capturedAt >= anchor.addingTimeInterval(-resetTimeTolerance)
            let naturalReset = currentReset > anchor
                && crossesOldAnchor
                && withinCaptureInterval
            let earlyReset = currentReset > anchor
                && inferredStart < anchor.addingTimeInterval(-resetTimeTolerance)
                && withinCaptureInterval
                && current.usedPercent + percentageTolerance < previous.usedPercent
            if earlyReset {
                let acceptedStart = anchor.addingTimeInterval(-weeklyWindowDuration)
                let nearbyStart = inferredStart <= acceptedStart.addingTimeInterval(3 * resetTimeTolerance)
                    && current.capturedAt <= acceptedStart.addingTimeInterval(3 * resetTimeTolerance)
                let onePointDrop = previous.usedPercent - current.usedPercent <= 1 + percentageTolerance
                if nearbyStart && onePointDrop {
                    // A nearby countdown shift plus one rounded percentage
                    // point is not enough to retire a cycle. Reaffirmation by
                    // the accepted anchor with higher usage in the same short
                    // observation span resolves the transient as drift. A
                    // mere old-value replay does not. Otherwise preserve
                    // uncertainty rather than guessing a second reset.
                    let reappears = following
                        .prefix { candidate in
                            candidate.capturedAt <= current.capturedAt.addingTimeInterval(3 * resetTimeTolerance)
                                && (lookaheadCutoff.map { cutoff in candidate.capturedAt < cutoff } ?? true)
                        }
                        .contains {
                            $0.resetsAt.map { abs($0.timeIntervalSince(anchor)) <= resetTimeTolerance } == true
                                && $0.usedPercent > previous.usedPercent + percentageTolerance
                        }
                    return reappears ? .same : .ambiguous
                }
            }
            if naturalReset || earlyReset {
                return .reset
            }

            // Before the accepted anchor has passed, a changed future
            // countdown is still the same cycle. The anchor remains fixed.
            if current.capturedAt < anchor.addingTimeInterval(-resetTimeTolerance) {
                return .same
            }
            // After crossing the anchor, an unproven jump is contradictory;
            // never turn it into a guessed reset or an arbitrary stale replay.
            return .ambiguous
        }
    }

    static func isFutureReset(_ snapshot: QuotaSnapshot) -> Bool {
        guard let reset = snapshot.resetsAt else { return true }
        return reset > snapshot.capturedAt
    }

    static func matches(_ value: Date, anyOf dates: [Date]) -> Bool {
        dates.contains { abs(value.timeIntervalSince($0)) <= resetTimeTolerance }
    }

    static func earliestFirst(_ lhs: QuotaSnapshot, _ rhs: QuotaSnapshot) -> Bool {
        lhs.capturedAt < rhs.capturedAt || (lhs.capturedAt == rhs.capturedAt && lhs.id < rhs.id)
    }

    static func sourceKey(_ snapshot: QuotaSnapshot) -> String {
        if let id = snapshot.limitID, !id.isEmpty { return "id:\(id)" }
        if let name = snapshot.limitName, !name.isEmpty { return "name:\(name)" }
        return "unknown"
    }

    static func isValid(_ percentage: Double) -> Bool {
        percentage.isFinite && (0...100).contains(percentage)
    }
}
