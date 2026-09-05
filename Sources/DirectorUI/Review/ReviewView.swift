import SwiftUI
import DirectorCore

/// The findings list and inspector are staged below their combined readable
/// width so the selected rule source is never cropped by a nested split view.
public enum ReviewLayoutState: String, Equatable, Sendable {
    case spacious
    case compact

    public static func forContentWidth(_ width: CGFloat) -> Self {
        width >= ReviewLayoutMetrics.spaciousWorkspaceMinimumWidth ? .spacious : .compact
    }
}

public enum ReviewLayoutMetrics {
    public static let findingsMinimumWidth: CGFloat = 320
    public static let inspectorMinimumWidth: CGFloat = 320
    public static let spaciousWorkspaceMinimumWidth: CGFloat =
        findingsMinimumWidth + inspectorMinimumWidth + DirectorSpacing.space8
}

/// Pure content routing for compact Review presentation. A filtered-out
/// dataset remains a list state so changing the filter does not alter
/// selection semantics; a genuinely empty actionable dataset uses emptyState.
public enum ReviewContentStage: String, Equatable, Sendable {
    case findings
    case empty
    case filteredEmpty

    public static func forCounts(findingsCount: Int, filteredCount: Int) -> Self {
        if findingsCount == 0 { return .empty }
        if filteredCount == 0 { return .filteredEmpty }
        return .findings
    }
}

/// Review destination: deterministic findings with severity grouping.
/// "No findings" is never presented as "Healthy" unless coverage is complete.
public struct ReviewView: View {
    @ObservedObject public var model: ReviewViewModel
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(model: ReviewViewModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // Keep the summary in normal layout flow. Native HSplitView
                // does not always reserve a safeAreaInset's height, which
                // can otherwise cover the inspector header at wide widths.
                    summaryBar(compact: ReviewLayoutState.forContentWidth(proxy.size.width) == .compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                reviewContent(width: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func reviewContent(width: CGFloat) -> some View {
        switch ReviewLayoutState.forContentWidth(width) {
        case .spacious:
            HSplitView {
                findingsList
                    .frame(minWidth: ReviewLayoutMetrics.findingsMinimumWidth, idealWidth: 420)

                if let finding = model.selectedFinding {
                    ReviewInspector(finding: finding, rule: model.rule(for: finding))
                        .frame(minWidth: ReviewLayoutMetrics.inspectorMinimumWidth, idealWidth: 360)
                } else {
                    emptyState
                        .frame(minWidth: ReviewLayoutMetrics.inspectorMinimumWidth)
                }
            }
        case .compact:
            if let finding = model.selectedFinding {
                compactFindingDetail(finding)
            } else if ReviewContentStage.forCounts(
                findingsCount: model.findings.count,
                filteredCount: model.filteredFindings.count
            ) == .empty {
                emptyState
            } else {
                findingsList
            }
        }
    }

    private var findingsList: some View {
        List(selection: $model.selectedFindingID) {
            Section(text("Errors")) {
                ForEach(model.filteredFindings.filter { $0.severity == .error }) { finding in
                    row(finding).tag(finding.id)
                }
            }
            Section(text("Warnings")) {
                ForEach(model.filteredFindings.filter { $0.severity == .warning }) { finding in
                    row(finding).tag(finding.id)
                }
            }
            Section(text("Info")) {
                ForEach(model.filteredFindings.filter { $0.severity == .info }) { finding in
                    row(finding).tag(finding.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactFindingDetail(_ finding: ReviewFinding) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DirectorSpacing.space2) {
                Button {
                    model.selectedFindingID = nil
                } label: {
                    Label(text("Back to findings"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(text("Back to findings"))
                .accessibilityHint(text("Returns to Review findings."))

                Text(localizedSummary(for: finding))
                    .font(DirectorTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DirectorSpacing.space3)
            .padding(.vertical, DirectorSpacing.space2)
            Divider()
            ReviewInspector(finding: finding, rule: model.rule(for: finding))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            model.selectedFindingID = nil
        }
    }

    private func row(_ finding: ReviewFinding) -> some View {
        HStack(spacing: DirectorSpacing.space2) {
            Image(systemName: symbol(for: finding.severity))
                .foregroundStyle(color(for: finding.severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(localizedSummary(for: finding))
                    .font(DirectorTypography.body)
                Text(finding.ruleID)
                    .font(DirectorTypography.code)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Spacer()
            ConfidenceBadge(confidence: finding.confidence)
        }
        .padding(.vertical, DirectorSpacing.space1)
    }

    private func summaryBar(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    HStack(spacing: DirectorSpacing.space2) {
                        Text(text("Review Lite"))
                            .font(DirectorTypography.sectionTitle)
                        Spacer(minLength: 0)
                        filterMenu
                    }
                    countsSummary
                    coverageSummary
                }
            } else {
                HStack(spacing: DirectorSpacing.space4) {
                    Text(text("Review Lite"))
                        .font(DirectorTypography.sectionTitle)
                    countsSummary
                    coverageSummary
                    Spacer()
                    filterMenu
                }
            }
        }
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.vertical, DirectorSpacing.space2)
        .background(DirectorColor.raised)
        .accessibilityElement(children: .contain)
    }

    private var countsSummary: some View {
        Text(languageStore.localizer.format(
            "%@ · %@ · %@",
            fallback: "%@ · %@ · %@",
            languageStore.localizer.plural("review.errorCount", count: model.count(.error), fallback: "%lld errors"),
            languageStore.localizer.plural("review.warningCount", count: model.count(.warning), fallback: "%lld warnings"),
            languageStore.localizer.plural("review.infoCount", count: model.count(.info), fallback: "%lld info")
        ))
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var coverageSummary: some View {
        if !model.coverageIsComplete || model.dataQualityFindingCount > 0 {
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                if !model.coverageIsComplete {
                    Label(text("Findings may be incomplete — some sessions have partial coverage"), systemImage: "exclamationmark.triangle")
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.status(.warning))
                        .lineLimit(1)
                }
                if model.dataQualityFindingCount > 0 {
                    Label(languageStore.localizer.format(
                        "%@ in Data Status",
                        fallback: "%@ in Data Status",
                        languageStore.localizer.plural("review.parserCoverageNotices", count: model.dataQualityFindingCount, fallback: "%lld parser coverage notices")
                    ), systemImage: "waveform.path.ecg")
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button(text("All")) { model.severityFilter = nil }
            Button(text("Errors only")) { model.severityFilter = .error }
            Button(text("Warnings only")) { model.severityFilter = .warning }
            Button(text("Info only")) { model.severityFilter = .info }
        } label: {
            Label(text("Filter"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(text("Filter"))
        .accessibilityValue(severityFilterLabel)
        .accessibilityHint(text("Choose which finding severities to show."))
    }

    private var severityFilterLabel: String {
        switch model.severityFilter {
        case .none: return text("All findings")
        case .some(.error): return text("Errors only")
        case .some(.warning): return text("Warnings only")
        case .some(.info): return text("Info only")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.findings.isEmpty {
            VStack(spacing: DirectorSpacing.space3) {
                Image(systemName: "checkmark.seal")
                    .font(.title)
                    .foregroundStyle(DirectorColor.textTertiary)
                    .accessibilityHidden(true)
                Text(text("No actionable findings."))
                    .font(DirectorTypography.body)
                Text(text(model.coverageIsComplete
                          ? "All analyzed sessions have complete coverage."
                          : "Some evidence is incomplete; review Data Status for parser coverage notices."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(text("Select a finding to inspect its rule source and evidence."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func symbol(for severity: ReviewSeverity) -> String {
        switch severity {
        case .error: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: ReviewSeverity) -> Color {
        switch severity {
        case .error: return DirectorColor.status(.failure)
        case .warning: return DirectorColor.status(.warning)
        case .info: return DirectorColor.textSecondary
        }
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    private func localizedSummary(for finding: ReviewFinding) -> String {
        languageStore.localizer.text("review.rule.\(finding.ruleID).summary", fallback: finding.summary)
    }
}
