import SwiftUI
import DirectorCore

/// Bounded heights keep native Tables measurable when hosted by the Usage
/// destination's outer ScrollView. Larger datasets scroll inside the table.
public enum UsageTableLayoutMetrics {
    public static let headerHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 28
    public static let minimumHeight: CGFloat = headerHeight + rowHeight
    public static let maximumHeight: CGFloat = 280

    public static func height(forRowCount rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        return min(maximumHeight, headerHeight + CGFloat(rows) * rowHeight)
    }
}

/// Local seven-day token trend and per-task token breakdown.
///
/// Labeled clearly as "locally indexed tasks" — separate from any account
/// allowance. Content surface, not glass.
public struct TaskTokenBreakdownView: View {
    public let sevenDayTotals: [DayTokenTotal]
    public let taskBreakdown: [TaskTokenRow]
    public let modelBreakdown: [ModelTokenRow]
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        sevenDayTotals: [DayTokenTotal],
        taskBreakdown: [TaskTokenRow],
        modelBreakdown: [ModelTokenRow] = []
    ) {
        self.sevenDayTotals = sevenDayTotals
        self.taskBreakdown = taskBreakdown
        self.modelBreakdown = modelBreakdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
            Text(text("Locally indexed tasks"))
                .font(DirectorTypography.sectionTitle)
            Text(text("Token totals are the newest cumulative snapshot per task, summed per day. They are not the official allowance."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)

            sevenDayChart

            Divider()

            Text(text("Task token breakdown"))
                .font(DirectorTypography.sectionTitle)

            Table(taskBreakdown) {
                TableColumn(text("Task")) { row in
                    Text(row.sessionID)
                        .font(DirectorTypography.code)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn(text("Input")) { row in Text(number(row.usage.inputTokens)).font(DirectorTypography.data) }
                TableColumn(text("Cached")) { row in Text(number(row.usage.cachedInputTokens)).font(DirectorTypography.data) }
                TableColumn(text("Cache write")) { row in Text(number(row.usage.cacheWriteInputTokens)).font(DirectorTypography.data) }
                TableColumn(text("Output")) { row in Text(number(row.usage.outputTokens)).font(DirectorTypography.data) }
                TableColumn(text("Reasoning")) { row in Text(number(row.usage.reasoningOutputTokens)).font(DirectorTypography.data) }
                TableColumn(text("Total")) { row in Text(number(row.usage.totalTokens)).font(DirectorTypography.data) }
            }
            .frame(height: UsageTableLayoutMetrics.height(forRowCount: taskBreakdown.count))

            Divider()

            Text(text("By model"))
                .font(DirectorTypography.sectionTitle)
            Text(text("Locally indexed token totals grouped by observed model. Repeated cumulative snapshots are counted once; this does not replace the official allowance."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)

            if modelBreakdown.isEmpty {
                Text(text("No model-attributed token snapshots are available. Re-index the local Session files to rebuild model evidence."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityLabel(text("No model-attributed token snapshots are available. Re-index the local Session files to rebuild model evidence."))
            } else {
                Table(modelBreakdown) {
                    TableColumn(text("Model")) { row in
                        Text(Self.modelDisplayName(row, localizer: languageStore.localizer))
                            .font(DirectorTypography.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn(text("Tokens")) { row in
                        Text(number(row.totalTokens))
                            .font(DirectorTypography.data)
                    }
                    TableColumn(text("Tasks")) { row in
                        Text(number(row.taskCount))
                            .font(DirectorTypography.data)
                    }
                    TableColumn(text("Coverage")) { row in
                        Text(enumLabel(row.coverage, prefix: "coverage."))
                            .font(DirectorTypography.supporting)
                    }
                    TableColumn(text("Attribution")) { row in
                        ConfidenceBadge(confidence: row.attributionConfidence)
                    }
                }
                .frame(height: UsageTableLayoutMetrics.height(forRowCount: modelBreakdown.count))
                .accessibilityLabel(text("Token usage by model"))
            }
        }
        .padding(DirectorSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sevenDayChart: some View {
        let maxTotal = max(sevenDayTotals.map(\.totalTokens).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: DirectorSpacing.space2) {
            ForEach(sevenDayTotals) { item in
                VStack(spacing: DirectorSpacing.space1) {
                    Text(shortCount(item.totalTokens))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                    Rectangle()
                        .fill(DirectorColor.accent)
                        .frame(height: barHeight(tokens: item.totalTokens, maxTotal: maxTotal))
                    Text(languageStore.localizer.date(item.day, style: .dateTime.weekday(.abbreviated)))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(languageStore.localizer.format("%@; %lld tokens", fallback: "%@; %lld tokens", languageStore.localizer.date(item.day, style: Date.FormatStyle(date: .abbreviated, time: .omitted)), item.totalTokens))
            }
        }
        .frame(height: 140)
        // Keep the per-day accessibility elements exposed. A label on this
        // container is inherited by every chart child on macOS, which hides
        // each day's localized date and Token value from the AX tree.
        .accessibilityElement(children: .contain)
    }

    private func barHeight(tokens: Int64, maxTotal: Int64) -> CGFloat {
        guard maxTotal > 0 else { return 4 }
        let ratio = CGFloat(Double(tokens) / Double(maxTotal))
        return Swift.max(4, ratio * 80)
    }

    private func shortCount(_ value: Int64) -> String {
        if value >= 1_000_000 { return languageStore.localizer.format("%.1fM", fallback: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return languageStore.localizer.format("%.1fK", fallback: "%.1fK", Double(value) / 1_000) }
        return number(value)
    }

    private func number(_ value: Int64) -> String {
        languageStore.localizer.format("%lld", fallback: "%lld", value)
    }

    private func number(_ value: Int) -> String {
        languageStore.localizer.format("%lld", fallback: "%lld", value)
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    static func modelDisplayName(_ row: ModelTokenRow, localizer: DirectorLocalizer) -> String {
        if row.modelID == nil { return localizer.text("usage.unknownModel", fallback: "Unknown model") }
        if row.modelID == ModelIdentity.redactedID { return localizer.text("usage.redactedModel", fallback: "Redacted model") }
        return row.modelName
    }

    private func enumLabel<Value: RawRepresentable>(_ value: Value, prefix: String) -> String where Value.RawValue == String {
        languageStore.localizer.enumLabel(.init(key: prefix + value.rawValue, fallback: value.rawValue.capitalized))
    }
}
