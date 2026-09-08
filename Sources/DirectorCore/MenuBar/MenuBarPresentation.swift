import Foundation

/// A privacy-bounded value prepared for a menu-bar client. It is built from
/// the sanitized account snapshot only and never reads SQLite or source files.
public struct MenuBarPresentation: Equatable, Sendable {
    public enum Freshness: String, Codable, Equatable, Sendable {
        case fresh
        case stale
        case unavailable
    }

    public enum Activity: String, Codable, Equatable, Sendable {
        case idle
        case refreshing
        case failed
    }

    public enum State: String, Codable, Equatable, Sendable {
        case available
        case missing
        case stale
        case expired
        case refreshing
        case failed
    }

    public enum ResetDisplay: Equatable, Sendable {
        case unavailable
        case countdown(seconds: Int)
        case elapsed
    }

    public let state: State
    public let shortStatus: String
    public let primaryValue: String
    public let fiveHourRemainingPercent: Double?
    public let fiveHourResetsAt: Date?
    public let fiveHourResetDisplay: ResetDisplay
    public let weeklyRemainingPercent: Double?
    public let weeklyResetsAt: Date?
    public let resetCreditCount: Int?
    public let resetDisplay: ResetDisplay
    public let canRefresh: Bool
    public let canOpenMainWindow: Bool
    public let usesCachedValue: Bool

    public init(
        snapshot: CodexAccountUsageSnapshot?,
        freshness: Freshness,
        activity: Activity = .idle,
        now: Date
    ) {
        let shortResetElapsed = snapshot?.fiveHourResetsAt.map { $0 <= now } ?? false
        let weeklyResetElapsed = snapshot?.weeklyResetsAt.map { $0 <= now } ?? false
        let usableShort = shortResetElapsed ? nil : snapshot?.fiveHourRemainingPercent
        let usableWeekly = weeklyResetElapsed ? nil : snapshot?.weeklyRemainingPercent
        fiveHourRemainingPercent = usableShort
        fiveHourResetsAt = snapshot?.fiveHourResetsAt
        weeklyRemainingPercent = usableWeekly
        weeklyResetsAt = snapshot?.weeklyResetsAt
        resetCreditCount = snapshot?.resetCreditCount

        shortStatus = Self.statusText(short: usableShort, weekly: usableWeekly)
        primaryValue = usableWeekly.map(Self.percentageText) ?? usableShort.map(Self.percentageText) ?? "—"

        fiveHourResetDisplay = Self.resetDisplay(for: snapshot?.fiveHourResetsAt, now: now)
        resetDisplay = Self.resetDisplay(for: snapshot?.weeklyResetsAt, now: now)

        let baseState: State
        if snapshot == nil {
            baseState = .missing
        } else if usableShort == nil && usableWeekly == nil,
                  shortResetElapsed || weeklyResetElapsed {
            baseState = .expired
        } else if usableShort != nil || usableWeekly != nil {
            baseState = freshness == .fresh ? .available : .stale
        } else {
            baseState = .missing
        }

        switch activity {
        case .idle:
            state = baseState
        case .refreshing:
            state = .refreshing
        case .failed:
            state = .failed
        }

        canRefresh = activity != .refreshing
        canOpenMainWindow = true
        usesCachedValue = (usableShort != nil || usableWeekly != nil)
            && (freshness != .fresh || activity != .idle)
    }

    private static func resetDisplay(for date: Date?, now: Date) -> ResetDisplay {
        guard let date else { return .unavailable }
        if date <= now { return .elapsed }
        return .countdown(seconds: max(1, Int(ceil(date.timeIntervalSince(now)))))
    }

    private static func statusText(short: Double?, weekly: Double?) -> String {
        switch (short, weekly) {
        case let (.some(short), .some(weekly)):
            return "5h \(percentageText(short)) w \(percentageText(weekly))"
        case let (.some(value), .none), let (.none, .some(value)):
            return percentageText(value)
        case (.none, .none):
            return "—"
        }
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

}
