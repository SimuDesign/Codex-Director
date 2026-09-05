import SwiftUI
import DirectorCore

/// Reported allowance windows. Content surface, not glass. Credits and local
/// task totals are never merged into the reported percentage.
public struct AllowanceSummaryView: View {
    public let weeklyState: AllowanceState
    public let shortWindowQuota: QuotaSnapshot?
    public let weeklyLimitSource: String
    public let weeklyLimitIdentifier: String
    public let hasMultipleWeeklyNamespaces: Bool
    public let shortWindowLimitSource: String
    public let shortWindowLimitIdentifier: String
    public let hasMultipleShortNamespaces: Bool
    public let weeklyNamespaceSnapshots: [QuotaSnapshot]
    public let shortNamespaceSnapshots: [QuotaSnapshot]
    public let weeklyLimitSourceIsPlaceholder: Bool
    public let shortWindowLimitSourceIsPlaceholder: Bool
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        weeklyState: AllowanceState,
        weeklyLimitSource: String,
        weeklyLimitIdentifier: String,
        hasMultipleWeeklyNamespaces: Bool,
        shortWindowQuota: QuotaSnapshot?,
        shortWindowLimitSource: String,
        shortWindowLimitIdentifier: String,
        hasMultipleShortNamespaces: Bool,
        weeklyNamespaceSnapshots: [QuotaSnapshot],
        shortNamespaceSnapshots: [QuotaSnapshot],
        weeklyLimitSourceIsPlaceholder: Bool = false,
        shortWindowLimitSourceIsPlaceholder: Bool = false
    ) {
        self.weeklyState = weeklyState
        self.weeklyLimitSource = weeklyLimitSource
        self.weeklyLimitIdentifier = weeklyLimitIdentifier
        self.hasMultipleWeeklyNamespaces = hasMultipleWeeklyNamespaces
        self.shortWindowQuota = shortWindowQuota
        self.shortWindowLimitSource = shortWindowLimitSource
        self.shortWindowLimitIdentifier = shortWindowLimitIdentifier
        self.hasMultipleShortNamespaces = hasMultipleShortNamespaces
        self.weeklyNamespaceSnapshots = weeklyNamespaceSnapshots
        self.shortNamespaceSnapshots = shortNamespaceSnapshots
        self.weeklyLimitSourceIsPlaceholder = weeklyLimitSourceIsPlaceholder
        self.shortWindowLimitSourceIsPlaceholder = shortWindowLimitSourceIsPlaceholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
            Text(text("Allowance"))
                .font(DirectorTypography.sectionTitle)

            weeklyView

            if let short = shortWindowQuota {
                Divider()
                windowView(
                    title: text("Five-hour window"),
                    usedPercent: short.usedPercent,
                    remaining: short.remainingPercent,
                    resetsAt: short.resetsAt,
                    capturedAt: short.capturedAt,
                    confidence: short.confidence,
                    sourceName: shortWindowLimitSource,
                    sourceNameIsPlaceholder: shortWindowLimitSourceIsPlaceholder,
                    limitIdentifier: shortWindowLimitIdentifier,
                    showMultipleSource: hasMultipleShortNamespaces,
                    namespaceSnapshots: shortNamespaceSnapshots
                )
            }

            Text(text("Credits and locally indexed task totals are not part of this reported percentage."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
        }
        .padding(DirectorSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var weeklyView: some View {
        switch weeklyState {
        case .available(let quota):
            windowView(
                title: text("Weekly allowance"),
                usedPercent: quota.usedPercent,
                remaining: quota.remainingPercent,
                resetsAt: quota.resetsAt,
                capturedAt: quota.capturedAt,
                confidence: quota.confidence,
                sourceName: weeklyLimitSource,
                sourceNameIsPlaceholder: weeklyLimitSourceIsPlaceholder,
                limitIdentifier: weeklyLimitIdentifier,
                showMultipleSource: hasMultipleWeeklyNamespaces,
                namespaceSnapshots: weeklyNamespaceSnapshots
            )
        case .expired(let quota):
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                Label(text("Weekly allowance — Unknown"), systemImage: "questionmark.circle")
                    .font(DirectorTypography.body)
                Text(text("The reported reset time has passed and no newer snapshot exists. Remaining is Unknown, not 100%."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                sourceSection(
                    sourceName: weeklyLimitSource,
                    sourceNameIsPlaceholder: weeklyLimitSourceIsPlaceholder,
                    limitIdentifier: weeklyLimitIdentifier,
                    showMultipleSource: hasMultipleWeeklyNamespaces,
                    namespaceSnapshots: weeklyNamespaceSnapshots
                )
                Text(languageStore.localizer.format("Last reported at %@ · reset %@", fallback: "Last reported at %@ · reset %@", languageStore.localizer.date(quota.capturedAt), quota.resetsAt.map { languageStore.localizer.date($0) } ?? text("unknown")))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
            }
        case .unavailable:
            Text(text("No allowance snapshot has been reported."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        }
    }

    private func windowView(
        title: String,
        usedPercent: Double,
        remaining: Double,
        resetsAt: Date?,
        capturedAt: Date,
        confidence: EvidenceConfidence,
        sourceName: String,
        sourceNameIsPlaceholder: Bool,
        limitIdentifier: String,
        showMultipleSource: Bool,
        namespaceSnapshots: [QuotaSnapshot]
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            HStack(spacing: DirectorSpacing.space2) {
                Text(title)
                    .font(DirectorTypography.body)
                Spacer()
                ConfidenceBadge(confidence: confidence)
            }
            sourceSection(
                sourceName: sourceName,
                sourceNameIsPlaceholder: sourceNameIsPlaceholder,
                limitIdentifier: limitIdentifier,
                showMultipleSource: showMultipleSource,
                namespaceSnapshots: namespaceSnapshots
            )
            HStack(spacing: DirectorSpacing.space3) {
                Text(languageStore.localizer.format("Used %@", fallback: "Used %@", percent(usedPercent)))
                    .font(DirectorTypography.data)
                Text(languageStore.localizer.format("Remaining %@", fallback: "Remaining %@", percent(remaining)))
                    .font(DirectorTypography.data)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            progressBar(usedPercent)
            Text(languageStore.localizer.format("Reported %@ · resets %@", fallback: "Reported %@ · resets %@", languageStore.localizer.date(capturedAt), resetsAt.map { languageStore.localizer.date($0) } ?? text("unknown")))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textTertiary)
        }
    }

    private func sourceSection(
        sourceName: String,
        sourceNameIsPlaceholder: Bool,
        limitIdentifier: String,
        showMultipleSource: Bool,
        namespaceSnapshots: [QuotaSnapshot]
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(languageStore.localizer.format("Source: %@", fallback: "Source: %@", Self.displaySourceName(sourceName, isPlaceholder: sourceNameIsPlaceholder, localizer: languageStore.localizer)))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            if showMultipleSource {
                Text(languageStore.localizer.format("Multiple allowance sources; showing %@", fallback: "Multiple allowance sources; showing %@", limitIdentifier))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.status(.warning))
                if !namespaceSnapshots.isEmpty {
                    ForEach(namespaceSnapshots) { snapshot in
                        HStack(spacing: DirectorSpacing.space2) {
                            Text(snapshot.limitID ?? text("unknown"))
                                .font(DirectorTypography.label)
                                .frame(maxWidth: 180, alignment: .leading)
                            Text(languageStore.localizer.format("Used %@", fallback: "Used %@", percent(snapshot.usedPercent)))
                                .font(DirectorTypography.supporting)
                                .foregroundStyle(DirectorColor.textSecondary)
                            Text(languageStore.localizer.format("Remaining %@", fallback: "Remaining %@", percent(snapshot.remainingPercent)))
                                .font(DirectorTypography.supporting)
                                .foregroundStyle(DirectorColor.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func progressBar(_ usedPercent: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DirectorColor.separator)
                Capsule()
                    .fill(DirectorColor.status(.success))
                    .frame(width: proxy.size.width * CGFloat(min(max(usedPercent, 0), 100) / 100))
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(languageStore.localizer.format("Used %@", fallback: "Used %@", percent(usedPercent)))
    }

    private func percent(_ value: Double) -> String {
        languageStore.localizer.format("%lld%%", fallback: "%lld%%", Int(value.rounded()))
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    static func displaySourceName(_ sourceName: String, isPlaceholder: Bool, localizer: DirectorLocalizer) -> String {
        isPlaceholder ? localizer.text("home.allowance.unknownSource", fallback: "Unknown limit source") : sourceName
    }
}
