import Foundation

public enum QuotaHistoryPeriod: String, CaseIterable, Codable, Sendable {
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case sixtyDays = "60d"

    public var dayCount: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .sixtyDays: 60
        }
    }

    public static func preferenceValue(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .thirtyDays
    }
}

public struct QuotaHistoryQuery: Equatable, Sendable {
    public let sourceKey: String
    public let asOf: Date
    public let timeZone: TimeZone

    public init(sourceKey: String, asOf: Date, timeZone: TimeZone) {
        self.sourceKey = sourceKey
        self.asOf = asOf
        self.timeZone = timeZone
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public var contextStart: Date {
        let today = calendar.startOfDay(for: asOf)
        return calendar.date(byAdding: .day, value: -59, to: today)!
    }
}

public enum QuotaHistoryDayState: String, Codable, Sendable {
    case available
    case noObservation
    case missingBaseline
    case crossDayGap
    case ambiguousCycle
    case evidenceConflict
}

public enum QuotaHistoryCutoff: String, Codable, Sendable {
    case inclusive
    case exclusive
}

public struct QuotaHistoryComparisonKey: Equatable, Sendable {
    public let identity: PresentationIdentity
    public let sourceKey: String
    public let timeZoneIdentifier: String
    public let day: Date
    public let effectiveCutoff: Date
    public let cutoff: QuotaHistoryCutoff

    public init(identity: PresentationIdentity, sourceKey: String, timeZoneIdentifier: String, day: Date, effectiveCutoff: Date, cutoff: QuotaHistoryCutoff) {
        self.identity = identity
        self.sourceKey = sourceKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.day = day
        self.effectiveCutoff = effectiveCutoff
        self.cutoff = cutoff
    }

    public static func home(identity: PresentationIdentity, sourceKey: String, day: Date, timeZone: TimeZone, asOf: Date) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let isCurrent = start <= asOf && asOf < end
        return Self(identity: identity, sourceKey: sourceKey, timeZoneIdentifier: timeZone.identifier, day: start, effectiveCutoff: isCurrent ? asOf : end, cutoff: isCurrent ? .inclusive : .exclusive)
    }
}

public struct QuotaHistoryObservationSummary: Equatable, Sendable {
    public let capturedAt: Date
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(_ snapshot: QuotaSnapshot) {
        capturedAt = snapshot.capturedAt
        usedPercent = snapshot.usedPercent
        resetsAt = snapshot.resetsAt
    }
}

public struct QuotaHistoryTransition: Equatable, Sendable, Identifiable {
    public let id: String
    public let beforeObservedAt: Date
    public let afterObservedAt: Date
    public let acceptedAnchor: Date

    public init(id: String, beforeObservedAt: Date, afterObservedAt: Date, acceptedAnchor: Date) {
        self.id = id
        self.beforeObservedAt = beforeObservedAt
        self.afterObservedAt = afterObservedAt
        self.acceptedAnchor = acceptedAnchor
    }
}

public struct QuotaHistoryDay: Equatable, Sendable, Identifiable {
    public let day: Date
    public var id: Date { day }
    public let observationCount: Int
    public let state: QuotaHistoryDayState
    public let usedPercentDelta: Double?
    public let firstObservedAt: Date?
    public let lastObservedAt: Date?
    public let baseline: QuotaHistoryObservationSummary?
    public let firstObservation: QuotaHistoryObservationSummary?
    public let lastObservation: QuotaHistoryObservationSummary?
    public let transitions: [QuotaHistoryTransition]
    public let comparisonKey: QuotaHistoryComparisonKey

    public init(day: Date, observationCount: Int, state: QuotaHistoryDayState, usedPercentDelta: Double?, firstObservedAt: Date?, lastObservedAt: Date?, baseline: QuotaHistoryObservationSummary?, firstObservation: QuotaHistoryObservationSummary?, lastObservation: QuotaHistoryObservationSummary?, transitions: [QuotaHistoryTransition], comparisonKey: QuotaHistoryComparisonKey) {
        self.day = day
        self.observationCount = observationCount
        self.state = state
        self.usedPercentDelta = usedPercentDelta
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.baseline = baseline
        self.firstObservation = firstObservation
        self.lastObservation = lastObservation
        self.transitions = transitions
        self.comparisonKey = comparisonKey
    }

    public func replacingWithEvidenceConflict() -> Self {
        Self(day: day, observationCount: observationCount, state: .evidenceConflict, usedPercentDelta: nil, firstObservedAt: firstObservedAt, lastObservedAt: lastObservedAt, baseline: baseline, firstObservation: firstObservation, lastObservation: lastObservation, transitions: transitions, comparisonKey: comparisonKey)
    }
}

public struct QuotaHistorySnapshot: Equatable, Sendable {
    public static let currentAlgorithmVersion = 1
    public let identity: PresentationIdentity
    public let sourceKey: String
    public let timeZoneIdentifier: String
    public let asOf: Date
    public let contextStart: Date
    public let readAt: Date
    public let lastObservedAt: Date?
    public let days: [QuotaHistoryDay]
    public let transitions: [QuotaHistoryTransition]
    public let algorithmVersion: Int

    public init(identity: PresentationIdentity, sourceKey: String, timeZoneIdentifier: String, asOf: Date, contextStart: Date, readAt: Date, lastObservedAt: Date?, days: [QuotaHistoryDay], transitions: [QuotaHistoryTransition], algorithmVersion: Int = Self.currentAlgorithmVersion) {
        self.identity = identity
        self.sourceKey = sourceKey
        self.timeZoneIdentifier = timeZoneIdentifier
        self.asOf = asOf
        self.contextStart = contextStart
        self.readAt = readAt
        self.lastObservedAt = lastObservedAt
        self.days = days
        self.transitions = transitions
        self.algorithmVersion = algorithmVersion
    }

    public func days(for period: QuotaHistoryPeriod) -> [QuotaHistoryDay] {
        Array(days.suffix(period.dayCount))
    }

    public func recordedDayCount(for period: QuotaHistoryPeriod) -> Int {
        days(for: period).count { $0.observationCount > 0 }
    }

    public func calculableDayCount(for period: QuotaHistoryPeriod) -> Int {
        days(for: period).count { $0.state == .available }
    }
}
