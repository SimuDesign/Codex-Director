import SwiftUI
import Charts
import DirectorCore

/// Home's quota module. Source selection drives both charts and persists when
/// observations refresh through `QuotaOverviewModel.refreshed`.
public struct QuotaOverviewView: View {
    public let model: QuotaOverviewModel
    private let onSourceChange: ((String) -> Void)?
    private let availableWidth: CGFloat?
    @State private var selectedSourceID: String?
    // Begin in the compact layout so the first pass cannot impose the wide
    // layout's intrinsic width on a narrow parent. The expanding frame below
    // then reports the actual content proposal and promotes to columns only
    // when that measured space is genuinely available.
    @State private var measuredWidth: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(model: QuotaOverviewModel) {
        self.model = model
        self.onSourceChange = nil
        self.availableWidth = nil
        _selectedSourceID = State(initialValue: model.selectedSourceID)
    }

    /// Integration seam for Home: the parent may persist the selected stable
    /// source ID while this view remains a pure renderer of refreshed models.
    public init(
        model: QuotaOverviewModel,
        availableWidth: CGFloat? = nil,
        onSourceChange: @escaping (String) -> Void
    ) {
        self.model = model
        self.onSourceChange = onSourceChange
        self.availableWidth = availableWidth
        _selectedSourceID = State(initialValue: model.selectedSourceID)
    }

    public init(
        snapshots: [QuotaSnapshot],
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        selectedSourceID: String? = nil
    ) {
        let model = QuotaOverviewModel(
            snapshots: snapshots, now: now, calendar: calendar, selectedSourceID: selectedSourceID
        )
        self.model = model
        self.onSourceChange = nil
        self.availableWidth = nil
        _selectedSourceID = State(initialValue: model.selectedSourceID)
    }

    public var body: some View {
        content(width: availableWidth ?? measuredWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onAppear { measuredWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, value in measuredWidth = value }
                }
            }
    }

    private func content(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space6) {
            if displayModel.sources.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
                    Spacer(minLength: DirectorSpacing.space2)
                    sourceControl
                }
            }

            if HomeLayout.quotaColumns(for: width) == 2 {
                HStack(alignment: .top, spacing: DirectorSpacing.space6) {
                    ringSection.frame(width: 420, alignment: .center)
                    dailySection.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
                    ringSection
                    dailySection
                }
            }
        }
        .onChange(of: model.sources) { _, sources in
            if let selectedSourceID, sources.contains(where: { $0.id == selectedSourceID }) { return }
            self.selectedSourceID = sources.first?.id
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var sourceControl: some View {
        if displayModel.sources.count > 1 {
            HStack(alignment: .center, spacing: DirectorSpacing.space2) {
                Text(copy("home.quota.source", fallback: "Source"))
                    .font(DirectorTypography.label)
                    .homeSecondaryText()

                QuotaSourceSwitch(
                    label: copy("home.quota.source", fallback: "Source"),
                    options: model.sources.map { QuotaSourceOption(id: $0.id, title: sourceName($0)) },
                    selection: sourceBinding
                )
                .fixedSize()
            }
        } else {
            EmptyView()
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { selectedSourceID ?? model.sources.first?.id ?? "unknown" },
            set: { newValue in
                selectedSourceID = newValue
                onSourceChange?(newValue)
            }
        )
    }

    private var displayModel: QuotaOverviewModel {
        guard let selectedSourceID else { return model }
        return model.selectingSource(selectedSourceID)
    }

    private func sourceName(_ source: QuotaOverviewModel.Source) -> String {
        source.id == "unknown"
            ? copy("home.allowance.unknownSource", fallback: "Unknown limit source")
            : source.name
    }

    private var ringSection: some View {
        let ring = QuotaRingPresentation.make(remainingPercent: displayModel.remainingPercent)
        return VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Text(copy("home.quota.current", fallback: "Current weekly allowance"))
                .font(DirectorTypography.supporting)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .center, spacing: DirectorSpacing.space5) {
                ZStack {
                    HomeQuotaProgressRing(presentation: ring)
                    VStack(spacing: DirectorSpacing.space1) {
                        Text(ring.centerText)
                            .font(HomeNumericTypography.percentage)
                            .foregroundStyle(DirectorColor.textPrimary)
                        Text(centerCaption(for: ring))
                            .font(DirectorTypography.supporting)
                            .homeSecondaryText()
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(centerAccessibility(for: ring))
                .accessibilityAddTraits(.isStaticText)
                resetSummary
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 236, maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var resetSummary: some View {
        if let current = displayModel.currentObservation {
            detailRow(
                copy("home.quota.resets", fallback: "Resets"),
                value: current.resetsAt.map { languageStore.localizer.date($0) }
                    ?? copy("home.quota.unknown", fallback: "Unknown")
            )
            if displayModel.isAwaitingNewData {
                Text(copy("home.quota.awaiting", fallback: "Waiting for a new quota record"))
                    .font(DirectorTypography.label)
                    .homeSecondaryText()
            }
        } else {
            Text(copy("home.quota.awaiting", fallback: "Waiting for a new quota record"))
                .font(DirectorTypography.label)
                .homeSecondaryText()
        }
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(copy("home.quota.dailyUsage", fallback: "Daily weekly-quota use"))
                    .font(DirectorTypography.supporting)
                Text(copy("home.quota.dailyUsageSubtitle", fallback: "Observed increase from same-source quota records"))
                    .font(DirectorTypography.label)
                    .homeSecondaryText()
            }

            Chart {
                ForEach(displayModel.dailySnapshots) { day in
                    if let used = day.usedPercent {
                        BarMark(
                            x: .value(copy("home.quota.date", fallback: "Date"), chartCategory(for: day)),
                            y: .value(copy("home.quota.dailyUsedPercent", fallback: "Daily weekly-quota use"), used),
                            width: .fixed(44)
                        )
                        .foregroundStyle(DirectorGradient.quotaBar)
                        .accessibilityLabel(dayAccessibilityDate(day))
                        .accessibilityValue(dayAccessibilityValue(day, value: used))
                        .annotation(position: .top, alignment: .center, spacing: 4) {
                            Text(percentLabel(used))
                                .font(DirectorTypography.label.monospacedDigit())
                                .foregroundStyle(DirectorColor.accentIce)
                        }
                    } else {
                        PointMark(
                            x: .value(copy("home.quota.date", fallback: "Date"), chartCategory(for: day)),
                            y: .value(copy("home.quota.dailyUsedPercent", fallback: "Daily weekly-quota use"), 0)
                        )
                        .foregroundStyle(.clear)
                        .accessibilityLabel(dayAccessibilityDate(day))
                        .accessibilityValue(dayAccessibilityValue(day, value: nil))
                        .annotation(position: .top, alignment: .center, spacing: 4) {
                            Text(copy("home.quota.noRecord", fallback: "No record"))
                                .font(DirectorTypography.label)
                                .homeSecondaryText()
                        }
                    }
                }
            }
            // Treat each local day as one categorical slot. Marks and labels
            // therefore share the exact same horizontal center instead of
            // relying on separate continuous-date midpoint calculations.
            .chartXScale(
                domain: chartCategories,
                range: .plotDimension(padding: DirectorSpacing.space6)
            )
            // Keep an annotation lane above the highest labeled axis value.
            .chartYScale(domain: 0...chartPlotMaximum)
            .chartYAxis {
                AxisMarks(position: .leading, values: chartYAxisValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(HomeVisual.boundary.opacity(colorSchemeContrast == .increased ? 0.8 : 0.45))
                    AxisValueLabel(centered: false) {
                        Text("\(Int((value.as(Double.self) ?? 0).rounded()))%")
                            .font(DirectorTypography.label.monospacedDigit())
                            .homeSecondaryText()
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: chartCategories) { value in
                    AxisValueLabel(centered: true) {
                        if let category = value.as(String.self),
                           let index = chartCategories.firstIndex(of: category) {
                            Text(languageStore.localizer.date(displayModel.dailySnapshots[index].date, style: Date.FormatStyle().month(.twoDigits).day(.twoDigits)))
                                .font(DirectorTypography.label)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(minHeight: 180)
            .padding(.top, DirectorSpacing.space2)
        }
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }

    private var chartCategories: [String] {
        displayModel.dailySnapshots.map(chartCategory)
    }

    private var chartAxisMaximum: Double {
        HomeQuotaChartScale.axisMaximum(for: displayModel.dailySnapshots.compactMap(\.usedPercent))
    }

    private var chartPlotMaximum: Double {
        chartAxisMaximum * 1.12
    }

    private var chartYAxisValues: [Double] {
        [0, chartAxisMaximum / 2, chartAxisMaximum]
    }

    private func chartCategory(for day: QuotaOverviewModel.DailySnapshot) -> String {
        String(day.date.timeIntervalSinceReferenceDate)
    }

    private func centerCaption(for ring: QuotaRingPresentation) -> String {
        ring.isAwaitingNewRecord
            ? copy("home.quota.awaitingShort", fallback: "Awaiting new data")
            : copy("home.quota.remaining", fallback: "remaining")
    }

    private func centerAccessibility(for ring: QuotaRingPresentation) -> String {
        guard let remaining = displayModel.remainingPercent, !ring.isAwaitingNewRecord else {
            return copy("home.quota.awaiting", fallback: "Waiting for a new quota record")
        }
        return String(format: "%.0f%% %@", remaining, copy("home.quota.remaining", fallback: "remaining"))
    }

    private func percentLabel(_ value: Double) -> String {
        languageStore.localizer.format("home.quota.percent", fallback: "%.0f%%", value)
    }

    private func dayAccessibilityDate(_ day: QuotaOverviewModel.DailySnapshot) -> String {
        languageStore.localizer.date(day.date, style: Date.FormatStyle().month(.twoDigits).day(.twoDigits))
    }

    private func dayAccessibilityValue(_ day: QuotaOverviewModel.DailySnapshot, value: Double?) -> String {
        value.map {
            languageStore.localizer.format(
                "home.quota.dailyUsedValue",
                fallback: "Used %.0f%% of the weekly allowance",
                $0
            )
        } ?? copy("home.quota.noRecord", fallback: "No record")
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
            Text(label).homeSecondaryText()
            Text(value).font(DirectorTypography.data)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func copy(_ key: String, fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }
}

private struct QuotaSourceOption: Identifiable {
    let id: String
    let title: String
}

/// An outlined segmented source switch that keeps the selected value visible
/// without inheriting the system-blue fill from a native segmented Picker.
private struct QuotaSourceSwitch: View {
    let label: String
    let options: [QuotaSourceOption]
    @Binding var selection: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: DirectorSpacing.space1) {
            ForEach(options) { option in
                let isSelected = selection == option.id
                Button {
                    selection = option.id
                } label: {
                    Text(option.title)
                        .font(DirectorTypography.label.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(DirectorColor.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DirectorSpacing.space3)
                        .frame(minHeight: DirectorSpacing.toolbarControlMinHeight)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DirectorRadius.compact, style: .continuous)
                                    .fill(DirectorColor.inset.opacity(0.72))
                            }
                        }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DirectorRadius.compact, style: .continuous)
                                    .stroke(DirectorGradient.primaryButton, lineWidth: contrast == .increased ? 2 : 1.5)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.compact, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled(false)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(option.title)
            }
        }
        .padding(DirectorSpacing.space1)
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                .stroke(DirectorColor.boundary.opacity(contrast == .increased ? 1 : 0.9), lineWidth: contrast == .increased ? 1.5 : 1)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(options.first(where: { $0.id == selection })?.title ?? "")
    }
}
