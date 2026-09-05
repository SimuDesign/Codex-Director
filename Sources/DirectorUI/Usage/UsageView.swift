import SwiftUI
import DirectorCore

/// Usage destination: reported allowance (weekly + optional five-hour) and
/// separate locally indexed task token trend and breakdown.
public struct UsageView: View {
    @ObservedObject public var model: UsageViewModel
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(model: UsageViewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space6) {
                AllowanceSummaryView(
                    weeklyState: model.weeklyState,
                    weeklyLimitSource: UsageViewModel.quotaSourceName(for: model.weeklyQuota),
                    weeklyLimitIdentifier: UsageViewModel.quotaSourceIdentifier(for: model.weeklyQuota),
                    hasMultipleWeeklyNamespaces: model.hasMultipleWeeklyNamespaces,
                    shortWindowQuota: model.shortWindowQuota,
                    shortWindowLimitSource: UsageViewModel.quotaSourceName(for: model.shortWindowQuota),
                    shortWindowLimitIdentifier: UsageViewModel.quotaSourceIdentifier(for: model.shortWindowQuota),
                    hasMultipleShortNamespaces: model.hasMultipleShortNamespaces,
                    weeklyNamespaceSnapshots: model.weeklyNamespaceSummaries,
                    shortNamespaceSnapshots: model.shortWindowNamespaceSummaries,
                    weeklyLimitSourceIsPlaceholder: model.weeklyQuota == nil,
                    shortWindowLimitSourceIsPlaceholder: model.shortWindowQuota == nil
                )
                Divider()
                TaskTokenBreakdownView(
                    sevenDayTotals: model.sevenDayTotals,
                    taskBreakdown: model.taskBreakdown,
                    modelBreakdown: model.modelBreakdown
                )
            }
            .padding(DirectorSpacing.space4)
        }
        .accessibilityElement(children: .contain)
    }
}
