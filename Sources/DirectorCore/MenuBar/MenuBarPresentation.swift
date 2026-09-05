import Foundation

/// A privacy-bounded value prepared for a menu-bar client.
///
/// It derives only from an already available quota projection. It never reads
/// SQLite, starts a command, refreshes a source, or exposes task and capability
/// content. Localized UI copy should be produced from the semantic states.
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
        case noSource
        case missing
        case stale
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
    public let remainingPercent: Double?
    public let sourceID: String?
    public let sourceName: String?
    public let resetDisplay: ResetDisplay
    public let canRefresh: Bool
    public let canOpenMainWindow: Bool
    public let usesCachedValue: Bool

    public init(
        source: QuotaOverviewSourceSnapshot?,
        freshness: Freshness,
        activity: Activity = .idle,
        now: Date
    ) {
        sourceID = source?.id
        sourceName = source.flatMap { Self.safeSourceName($0.name) }

        let observation = source?.current.flatMap { snapshot in
            snapshot.isWeeklyWindow && snapshot.capturedAt <= now ? snapshot : nil
        }
        let resetElapsed = observation?.resetsAt.map { $0 <= now } ?? false
        let usableObservation = resetElapsed ? nil : observation
        remainingPercent = usableObservation?.remainingPercent

        let percentage = remainingPercent.map(Self.percentageText) ?? "--"
        shortStatus = percentage
        primaryValue = percentage

        if let resetAt = observation?.resetsAt {
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
        if source == nil {
            baseState = .noSource
        } else if observation == nil {
            baseState = .missing
        } else if resetElapsed || freshness != .fresh {
            baseState = .stale
        } else {
            baseState = .available
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
        usesCachedValue = usableObservation != nil
            && (freshness != .fresh || activity != .idle)
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func safeSourceName(_ name: String) -> String? {
        guard !name.isEmpty,
              name.utf8.count <= 512,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return name
    }
}
