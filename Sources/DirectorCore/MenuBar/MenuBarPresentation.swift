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
        let resetElapsed = snapshot?.weeklyResetsAt.map { $0 <= now } ?? false
        let usableValue = resetElapsed ? nil : snapshot?.weeklyRemainingPercent
        weeklyRemainingPercent = usableValue
        weeklyResetsAt = snapshot?.weeklyResetsAt
        resetCreditCount = snapshot?.resetCreditCount

        let percentage = usableValue.map(Self.percentageText) ?? "—"
        shortStatus = percentage
        primaryValue = percentage

        if let resetAt = snapshot?.weeklyResetsAt {
            if resetAt <= now {
                resetDisplay = .elapsed
            } else {
                resetDisplay = .countdown(
                    seconds: max(1, Int(ceil(resetAt.timeIntervalSince(now))))
                )
            }
        } else {
            resetDisplay = .unavailable
        }

        let baseState: State
        if snapshot == nil {
            baseState = .missing
        } else if resetElapsed {
            baseState = .expired
        } else if usableValue != nil {
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
        usesCachedValue = usableValue != nil
            && (freshness != .fresh || activity != .idle)
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

}
