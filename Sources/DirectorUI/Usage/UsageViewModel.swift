import Foundation
import DirectorCore

/// Presentation state of the reported weekly allowance.
public enum AllowanceState: Equatable, Sendable {
    /// A fresh reported snapshot.
    case available(QuotaSnapshot)
    /// The reset time has passed and no newer snapshot exists: present as
    /// Unknown, never as 100%.
    case expired(QuotaSnapshot)
    /// No allowance snapshot was reported.
    case unavailable
}

/// One day of locally indexed task tokens.
public struct DayTokenTotal: Identifiable, Equatable {
    public let day: Date
    public let totalTokens: Int64

    public var id: TimeInterval { day.timeIntervalSince1970 }
}

/// One of the seven local calendar-day allowance usage values. A nil value is
/// unavailable evidence and is never rendered as zero usage.
public struct QuotaDaySnapshot: Identifiable, Equatable, Sendable {
    public let day: Date
    public let usedPercent: Double?
    public let isResetDay: Bool
    public var id: Date { day }
    public init(day: Date, usedPercent: Double?, isResetDay: Bool = false) {
        self.day = day; self.usedPercent = usedPercent; self.isResetDay = isResetDay
    }
}

/// One task's newest cumulative token usage (never summed).
public struct TaskTokenRow: Identifiable, Equatable {
    public let sessionID: String
    public let usage: TokenUsage

    public var id: String { sessionID }
}

/// Local cumulative token usage attributed to one observed model identity.
///
/// A row can be `Unknown model` when the rollout did not expose a model
/// context. Attribution confidence is intentionally independent from token
/// coverage so missing model evidence cannot be presented as exact usage.
public struct ModelTokenRow: Identifiable, Equatable {
    public let modelID: String?
    public let modelName: String
    public let totalTokens: Int64
    public let taskCount: Int
    public let coverage: CoverageState
    public let attributionConfidence: EvidenceConfidence

    public init(
        modelID: String?,
        modelName: String,
        totalTokens: Int64,
        taskCount: Int,
        coverage: CoverageState,
        attributionConfidence: EvidenceConfidence
    ) {
        self.modelID = modelID
        self.modelName = modelName
        self.totalTokens = totalTokens
        self.taskCount = taskCount
        self.coverage = coverage
        self.attributionConfidence = attributionConfidence
    }

    public var id: String { modelID ?? "unknown-model" }
}

/// Main-actor view state for the Usage destination.
///
/// Account allowance snapshots and locally indexed task token totals are
/// always presented as separate quantities; they are never reconciled.
@MainActor
public final class UsageViewModel: ObservableObject {
    public let quotaSnapshots: [QuotaSnapshot]
    public let tokenSnapshots: [TokenUsageSnapshot]
    public let now: Date

    public enum WindowKind {
        case weekly
        case short
    }

    public init(quotaSnapshots: [QuotaSnapshot], tokenSnapshots: [TokenUsageSnapshot], now: Date = Date()) {
        self.quotaSnapshots = quotaSnapshots
        self.tokenSnapshots = tokenSnapshots
        self.now = now
    }

    /// Newest reported weekly window (10_080 minutes), after namespace arbitration.
    public var weeklyQuota: QuotaSnapshot? {
        selectedQuota(for: .weekly)
    }

    /// Newest reported five-hour window (300 minutes), after namespace arbitration.
    public var shortWindowQuota: QuotaSnapshot? {
        selectedQuota(for: .short)
    }

    /// Latest non-expired and expired snapshots for each active namespace, used for
    /// transparent multi-source rendering and manual verification.
    public var weeklyNamespaceSummaries: [QuotaSnapshot] {
        latestQuotaPerNamespace(for: .weekly)
    }

    /// Latest non-expired and expired snapshots for each active namespace, used for
    /// transparent multi-source rendering and manual verification.
    public var shortWindowNamespaceSummaries: [QuotaSnapshot] {
        latestQuotaPerNamespace(for: .short)
    }

    /// True when a weekly window has multiple active namespaces.
    public var hasMultipleWeeklyNamespaces: Bool {
        hasMultipleNamespaces(for: .weekly)
    }

    /// Observed weekly-allowance use per local calendar day for the selected
    /// source. The array always contains seven days; missing evidence stays nil.
    public var weeklyDailySnapshots: [QuotaDaySnapshot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let selected = weeklyQuota.map(Self.namespaceKey)
        let source = quotaSnapshots.filter {
            $0.isWeeklyWindow && $0.capturedAt <= now &&
                (selected == nil || Self.namespaceKey($0) == selected)
        }
        var latest: [Date: QuotaSnapshot] = [:]
        for snapshot in source {
            let day = calendar.startOfDay(for: snapshot.capturedAt)
            guard day >= calendar.date(byAdding: .day, value: -6, to: today)! && day <= today else { continue }
            if latest[day].map({ $0.capturedAt < snapshot.capturedAt }) ?? true { latest[day] = snapshot }
        }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            let snapshot = latest[day]
            let reset = snapshot?.resetsAt.map { calendar.startOfDay(for: $0) == day } ?? false
            return QuotaDaySnapshot(
                day: day,
                usedPercent: QuotaDailyUsage.observedUsedPercent(
                    on: day,
                    observations: source,
                    calendar: calendar
                ),
                isResetDay: reset
            )
        }
    }

    /// True when a five-hour window has multiple active namespaces.
    public var hasMultipleShortNamespaces: Bool {
        hasMultipleNamespaces(for: .short)
    }

    public var weeklyState: AllowanceState {
        guard let weekly = weeklyQuota else { return .unavailable }
        return weekly.isExpired(at: now) ? .expired(weekly) : .available(weekly)
    }

    /// Last seven calendar days of locally indexed task tokens, oldest first.
    public var sevenDayTotals: [DayTokenTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let newestPerSession = Dictionary(grouping: tokenSnapshots, by: \.sessionID)
            .compactMapValues { TokenUsageParser.newestCumulative(from: $0) }
        var totals: [Date: Int64] = [:]
        for snapshot in newestPerSession.values {
            let day = calendar.startOfDay(for: snapshot.capturedAt)
            guard let daysAgo = calendar.dateComponents([.day], from: day, to: today).day,
                  daysAgo >= 0, daysAgo < 7 else { continue }
            totals[day, default: 0] += snapshot.usage.totalTokens
        }
        var days: [DayTokenTotal] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            days.append(DayTokenTotal(day: day, totalTokens: totals[day] ?? 0))
        }
        return days
    }

    /// Newest cumulative usage per locally indexed task, largest total first.
    public var taskBreakdown: [TaskTokenRow] {
        Dictionary(grouping: tokenSnapshots, by: \.sessionID)
            .compactMapValues { TokenUsageParser.newestCumulative(from: $0) }
            .map { TaskTokenRow(sessionID: $0.key, usage: $0.value.usage) }
            .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }

    /// Cumulative local usage grouped by observed model, without summing
    /// repeated snapshots. Each session's first cumulative total is counted
    /// once; subsequent monotonic deltas are attributed to the model on that
    /// snapshot. Decreases never become negative usage and mark that model
    /// row partial.
    public var modelBreakdown: [ModelTokenRow] {
        var aggregates: [String: ModelTokenAggregate] = [:]
        let sessions = Dictionary(grouping: tokenSnapshots, by: \.sessionID)

        for (sessionID, snapshots) in sessions {
            let ordered = snapshots.sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                return $0.id < $1.id
            }
            guard !ordered.isEmpty else { continue }

            var previousTotal: Int64?
            for snapshot in ordered {
                // Normalize at the presentation boundary as well as in the
                // parser. Persisted databases and tests may contain aliases
                // written by an older parser version; they must still merge
                // into one canonical Spark row.
                let identity = snapshot.modelID.flatMap(ModelIdentity.normalized(raw:))
                let key = identity?.id ?? "unknown-model"
                let displayName = identity?.displayName ?? "Unknown model"
                let confidence = identity == nil || identity?.id == ModelIdentity.redactedID
                    ? EvidenceConfidence.unknown
                    : snapshot.modelConfidence
                var aggregate = aggregates[key] ?? ModelTokenAggregate(
                    modelID: identity?.id,
                    modelName: displayName
                )
                aggregate.sessionIDs.insert(sessionID)
                aggregate.confidence = Self.mergeConfidence(aggregate.confidence, confidence)
                aggregate.coverage = Self.mergeCoverage(aggregate.coverage, snapshot.usage.coverage)

                if let previousTotal {
                    if snapshot.usage.totalTokens < previousTotal {
                        aggregate.coverage = .partial
                        aggregates[key] = aggregate
                        // Keep the high-water mark so a reset cannot cause a
                        // later snapshot to be counted a second time.
                        continue
                    }
                    aggregate.totalTokens += snapshot.usage.totalTokens - previousTotal
                } else {
                    aggregate.totalTokens += snapshot.usage.totalTokens
                }
                previousTotal = max(previousTotal ?? 0, snapshot.usage.totalTokens)
                aggregates[key] = aggregate
            }
        }

        return aggregates.values
            .map { aggregate in
                ModelTokenRow(
                    modelID: aggregate.modelID,
                    modelName: aggregate.modelName,
                    totalTokens: aggregate.totalTokens,
                    taskCount: aggregate.sessionIDs.count,
                    coverage: aggregate.coverage,
                    attributionConfidence: aggregate.confidence
                )
            }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                return $0.modelName < $1.modelName
            }
    }

    /// Deterministic remaining-percent display from the reported value.
    public static func remainingPercent(_ quota: QuotaSnapshot) -> Double {
        quota.remainingPercent
    }

    public static func quotaSourceName(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return "Unknown limit source" }
        if let name = quota.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return quotaSourceIdentifier(for: quota)
    }

    public static func quotaSourceIdentifier(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return "unknown" }
        if let identifier = quota.limitID?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
            return identifier
        }
        return "unknown"
    }

    public static func namespaceKey(_ quota: QuotaSnapshot) -> String {
        let identifier = quota.limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier, !identifier.isEmpty else {
            return "unknown"
        }
        return identifier
    }

    private func hasMultipleNamespaces(for window: WindowKind) -> Bool {
        Set(activeQuotaSnapshots(for: window).map(Self.namespaceKey)).count > 1
    }

    private func selectedQuota(for window: WindowKind) -> QuotaSnapshot? {
        let perNamespaceLatest = latestQuotaPerNamespace(for: window)
        guard !perNamespaceLatest.isEmpty else { return nil }

        let selected = perNamespaceLatest.max(by: Self.preferredQuota(now: now))
        guard let selected else { return nil }

        if selected.usedPercent == 0 {
            let nonZeroCandidate = perNamespaceLatest
                .filter { !$0.isExpired(at: now) && $0.usedPercent > 0 }
                .max(by: Self.preferredQuota(now: now))
            if let fallback = nonZeroCandidate {
                return fallback
            }
        }

        return selected
    }

    private func activeQuotaSnapshots(for window: WindowKind) -> [QuotaSnapshot] {
        switch window {
        case .weekly:
            return quotaSnapshots.filter(\.isWeeklyWindow)
        case .short:
            return quotaSnapshots.filter(\.isShortWindow)
        }
    }

    private func latestQuotaPerNamespace(for window: WindowKind) -> [QuotaSnapshot] {
        let grouped = Dictionary(grouping: activeQuotaSnapshots(for: window), by: Self.namespaceKey)
        return grouped.compactMapValues { snapshots in
            snapshots.max(by: Self.byCaptureThenFreshness(now: now))
        }.values.sorted {
            if $0.isExpired(at: now) != $1.isExpired(at: now) {
                return $1.isExpired(at: now) && !$0.isExpired(at: now)
            }
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt > $1.capturedAt
            }
            return $0.id > $1.id
        }
    }

    private static func byCaptureThenFreshness(now: Date) -> (QuotaSnapshot, QuotaSnapshot) -> Bool {
        { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            if lhs.isExpired(at: now) != rhs.isExpired(at: now) {
                return lhs.isExpired(at: now) && !rhs.isExpired(at: now)
            }
            return lhs.id < rhs.id
        }
    }

    private static func preferredQuota(now: Date) -> (QuotaSnapshot, QuotaSnapshot) -> Bool {
        { lhs, rhs in
            let lhsExpired = lhs.isExpired(at: now)
            let rhsExpired = rhs.isExpired(at: now)

            if lhsExpired != rhsExpired {
                return lhsExpired && !rhsExpired
            }
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.id < rhs.id
        }
    }

    private static func mergeConfidence(_ lhs: EvidenceConfidence, _ rhs: EvidenceConfidence) -> EvidenceConfidence {
        if lhs == .unknown || rhs == .unknown { return .unknown }
        if lhs == .inferred || rhs == .inferred { return .inferred }
        return .exact
    }

    private static func mergeCoverage(_ lhs: CoverageState, _ rhs: CoverageState) -> CoverageState {
        if lhs == .partial || rhs == .partial { return .partial }
        if lhs == .unavailable || rhs == .unavailable { return .unavailable }
        if lhs == .unknown || rhs == .unknown { return .unknown }
        return .complete
    }

    private struct ModelTokenAggregate {
        let modelID: String?
        let modelName: String
        var totalTokens: Int64 = 0
        var sessionIDs: Set<String> = []
        var coverage: CoverageState = .complete
        var confidence: EvidenceConfidence = .exact
    }
}
