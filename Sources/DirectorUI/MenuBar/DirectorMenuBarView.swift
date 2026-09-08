import SwiftUI
import DirectorCore

/// The persistent status-item label. It observes the app model directly so a
/// newly captured allowance updates the short label without requiring the
/// main window or the Scene to rebuild its nested model.
public struct DirectorMenuBarLabel: View {
    @ObservedObject private var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(model: DirectorAppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: DirectorSymbol.menuBarUsage)
                .symbolRenderingMode(.monochrome)
            Text(model.menuBarPresentation.shortStatus)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: model.menuBarPresentation))
    }

    private func accessibilityLabel(for presentation: MenuBarPresentation) -> String {
        var values: [String] = []
        if let value = presentation.fiveHourRemainingPercent {
            values.append(languageStore.localizer.format("menuBar.fiveHourRemainingValue", fallback: "Five-hour remaining %@", presentationText(value)))
        }
        if let value = presentation.weeklyRemainingPercent {
            values.append(languageStore.localizer.format("menuBar.weeklyRemainingValue", fallback: "Weekly remaining %@", presentationText(value)))
        }
        return values.isEmpty ? t("menuBar.unavailableStatus", "Account data is unavailable") : values.joined(separator: ", ")
    }

    private func presentationText(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func t(_ key: String, _ fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }
}

/// Compact, privacy-safe menu-bar surface. It owns no indexing or account
/// service; all values and actions are projected from the app model.
public struct DirectorMenuBarView: View {
    @ObservedObject private var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    private let onOpenMainWindow: () -> Void

    public init(model: DirectorAppModel, onOpenMainWindow: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.onOpenMainWindow = onOpenMainWindow
    }

    public var body: some View {
        let presentation = model.menuBarPresentation
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            if let value = presentation.fiveHourRemainingPercent {
                usageRow(
                    title: t("menuBar.fiveHourRemaining", "Five-hour remaining"),
                    value: percent(value),
                    symbol: "chart.pie.fill"
                )
                usageRow(
                    title: t("menuBar.fiveHourReset", "Five-hour reset"),
                    value: resetValue(presentation.fiveHourResetsAt, display: presentation.fiveHourResetDisplay),
                    symbol: "clock.arrow.circlepath"
                )
            }
            if let value = presentation.weeklyRemainingPercent {
                usageRow(
                    title: t("menuBar.weeklyRemaining", "Weekly remaining"),
                    value: percent(value),
                    symbol: "chart.pie.fill"
                )
                usageRow(
                    title: t("menuBar.nextReset", "Next reset"),
                    value: resetValue(presentation.weeklyResetsAt, display: presentation.resetDisplay),
                    symbol: "clock.arrow.circlepath"
                )
            }
            usageRow(
                title: t("menuBar.resetCredits", "Reset cards"),
                value: presentation.resetCreditCount.map(String.init) ?? unavailableText,
                symbol: "arrow.counterclockwise.circle"
            )

            if let statusText = statusText(for: presentation) {
                Text(statusText)
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityAddTraits(.isStaticText)
            }

            Divider()

            DirectorRefreshButton(
                label: t("menuBar.refresh", "Refresh data"),
                runningLabel: t("menuBar.refresh.running", "Refreshing…"),
                hint: t("menuBar.refresh.hint", "Refresh capability and account data."),
                isRefreshing: model.isRefreshing,
                isAvailable: model.canReadAccountUsage || model.hasDerivedDatabase,
                size: .toolbar,
                action: { Task { await model.refreshDataFromMenuBar() } }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpenMainWindow) {
                Label(t("menuBar.openMainWindow", "Open main window"), systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(t("menuBar.openMainWindow.hint", "Show Codex Director's main window."))
        }
        .padding(DirectorSpacing.space4)
        .frame(width: 280, alignment: .leading)
        .environment(\.locale, languageStore.locale)
        .task {
            _ = await model.refreshMenuBarIfNeeded()
        }
        .accessibilityElement(children: .contain)
    }

    private func usageRow(title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
            Image(systemName: symbol)
                .foregroundStyle(DirectorColor.accent(.ice))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(title).font(DirectorTypography.label)
                Text(value)
                    .font(DirectorTypography.data)
                    .foregroundStyle(DirectorColor.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func resetValue(_ date: Date?, display: MenuBarPresentation.ResetDisplay) -> String {
        guard let date, case .countdown = display else {
            return unavailableText
        }
        return languageStore.localizer.date(date)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private var unavailableText: String {
        t("menuBar.unavailable", "Unavailable")
    }

    private func statusText(for presentation: MenuBarPresentation) -> String? {
        switch presentation.state {
        case .stale:
            return t("menuBar.cached", "Showing cached data")
        case .failed:
            return presentation.usesCachedValue
                ? t("menuBar.cached", "Showing cached data")
                : t("menuBar.unavailableStatus", "Account data is unavailable")
        case .missing, .expired:
            return t("menuBar.unavailableStatus", "Account data is unavailable")
        case .available, .refreshing:
            return nil
        }
    }

    private func t(_ key: String, _ fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }
}
