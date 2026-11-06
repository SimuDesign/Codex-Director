import Charts
import SwiftUI
import DirectorCore

/// Native quota-history page for the Home allowance module.
///
/// The page deliberately has one full-workspace vertical scroll region and no
/// nested modal or dismissal chrome.
/// Current allowance values come from the Home projection; historical values
/// come from the one bounded controller snapshot.
public struct QuotaHistoryView: View {
    @StateObject private var model: QuotaHistoryViewModel
    private var controller: QuotaHistoryController { model.controller }
    private let quotaModelProjection: QuotaOverviewModel
    private let homeSnapshotProjection: QuotaOverviewSnapshot?
    private let sessionID: UUID?
    private let onClose: () -> Void
    private let onSourceChange: (String) -> Void
    @Binding private var scrollPosition: String?
    @State private var localScrollPosition: String?
    @State private var pendingScrollRestore: String?
    @State private var pendingScrollRestorePeriod: QuotaHistoryPeriod?
    private var isCurrentSession: Bool { sessionID == nil || controller.sessionID == sessionID }
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chartSelection: Date?
    @State private var transitionPage = 0
    @State private var isDataDetailsExpanded = false

    public init(
        controller: QuotaHistoryController,
        sessionID: UUID? = nil,
        quotaModel: QuotaOverviewModel,
        homeSnapshot: QuotaOverviewSnapshot? = nil,
        onClose: @escaping () -> Void = {},
        onSourceChange: @escaping (String) -> Void = { _ in },
        scrollPosition: Binding<String?> = .constant(nil)
    ) {
        _model = StateObject(wrappedValue: QuotaHistoryViewModel(controller: controller, homeQuotaModel: quotaModel))
        self.sessionID = sessionID
        self.quotaModelProjection = quotaModel
        self.homeSnapshotProjection = homeSnapshot
        self.onClose = onClose
        self.onSourceChange = onSourceChange
        self._scrollPosition = scrollPosition
        let incomingTarget = scrollPosition.wrappedValue
        _localScrollPosition = State(initialValue: incomingTarget == "quota-history-top" ? incomingTarget : nil)
        _pendingScrollRestore = State(initialValue: Self.pendingTarget(from: incomingTarget))
        _pendingScrollRestorePeriod = State(initialValue: controller.period)
    }

    public init(model: QuotaHistoryViewModel, onClose: @escaping () -> Void = {}, onSourceChange: @escaping (String) -> Void = { _ in }, scrollPosition: Binding<String?> = .constant(nil)) {
        _model = StateObject(wrappedValue: model)
        self.sessionID = nil
        self.quotaModelProjection = model.homeQuotaModel
        self.homeSnapshotProjection = nil
        self.onClose = onClose
        self.onSourceChange = onSourceChange
        self._scrollPosition = scrollPosition
        let incomingTarget = scrollPosition.wrappedValue
        _localScrollPosition = State(initialValue: incomingTarget == "quota-history-top" ? incomingTarget : nil)
        _pendingScrollRestore = State(initialValue: Self.pendingTarget(from: incomingTarget))
        _pendingScrollRestorePeriod = State(initialValue: model.period)
    }

    public var body: some View {
        GeometryReader { viewport in
            DirectorEditorialFrame {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        DirectorPageContentFrame(workspaceWidth: viewport.size.width) {
                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 0) {
                                    DirectorEditorialHero(
                                        title: copy("home.quotaHistory.title", fallback: "Quota history"),
                                        subtitle: nil,
                                        symbolName: DirectorSymbol.usage,
                                        tone: .blue,
                                        compact: DirectorPageLayout.contentWidth(for: viewport.size.width) < DirectorPageLayout.compactBreakpoint
                                    )
                                    .id("quota-history-top")
                                }
                                .scrollTargetLayout()
                                sourceAndCurrentContext(width: viewport.size.width)
                                trendSection(width: viewport.size.width)
                                dataDetails(width: viewport.size.width)
                                dayList
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(DirectorColor.canvas)
                    .scrollPosition(id: $localScrollPosition, anchor: .top)
                    .onAppear {
                        captureIncomingScrollTargetIfNeeded()
                        restorePendingScrollIfAvailable(using: scrollProxy)
                    }
                    .onChange(of: model.snapshot?.readAt) { _, _ in
                        restorePendingScrollIfAvailable(using: scrollProxy)
                    }
                    .onChange(of: localScrollPosition) { _, value in
                        guard isCurrentSession, pendingScrollRestore == nil else { return }
                        scrollPosition = value
                    }
                    .onChange(of: scrollPosition) { _, value in
                        guard isCurrentSession, value == "quota-history-top" else { return }
                        pendingScrollRestore = nil
                        pendingScrollRestorePeriod = nil
                        localScrollPosition = value
                    }
                    .onChange(of: controller.sourceKey) { previousSourceKey, sourceKey in
                        // Opening a new page session may transition the
                        // retained controller from its closed nil state to
                        // its pinned source before this view appears. Only a
                        // live source replacement made from the picker should
                        // move the retained window-local scroll position.
                        guard isCurrentSession,
                              previousSourceKey != nil,
                              sourceKey != nil,
                              previousSourceKey != sourceKey else { return }
                        pendingScrollRestore = nil
                        pendingScrollRestorePeriod = nil
                        transitionPage = 0
                        chartSelection = nil
                        localScrollPosition = "quota-history-top"
                        scrollPosition = "quota-history-top"
                        if reduceMotion {
                            scrollProxy.scrollTo("quota-history-top", anchor: .top)
                        } else {
                            withAnimation(.easeOut(duration: DirectorMotion.standard)) {
                                scrollProxy.scrollTo("quota-history-top", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
#if DEBUG || DIRECTOR_INTERACTION_PERFORMANCE
        // Validation-only capture target. When the page is visible, the
        // Host's Save PNG action resolves this marker's window so evidence
        // never falls back to the underlying Home viewport.
        .background(UIValidationCaptureMarker().frame(width: 1, height: 1).accessibilityHidden(true))
#endif
#if DIRECTOR_INTERACTION_PERFORMANCE
        .background(alignment: .topLeading) {
            if model.snapshot != nil, isCurrentSession {
                QuotaHistoryFirstPaintMarker.navigation(.destinationDraw, destination: .quotaHistory)
            }
        }
        .background {
            QuotaHistoryFirstPaintMarker(
                kind: .pageContent,
                isCorrect: QuotaHistoryPerformanceProbe.isCorrect(
                    period: model.period,
                    isOpen: model.controller.isOpen && isCurrentSession,
                    hasSnapshot: model.snapshot != nil
                ),
                eventID: QuotaHistoryPerformanceProbe.currentEventID
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
#endif
        .task {
            guard isCurrentSession else { return }
            controller.checkClockAndRefresh()
            if let homeSnapshotProjection {
                controller.updateHomeSnapshot(homeSnapshotProjection)
            }
        }
        // Root's Home projection is a value rebuilt from the shared app
        // model. Observing it here keeps current allowance values live while
        // the history read remains the controller's one bounded snapshot.
        .onChange(of: quotaModelProjection) { _, value in
            guard isCurrentSession else { return }
            model.updateHomeQuotaModel(value)
        }
        .onChange(of: homeSnapshotProjection) { _, value in
            guard isCurrentSession else { return }
            guard let value else { return }
            controller.updateHomeSnapshot(value)
        }
        .onChange(of: controller.selectedDay) { _, value in
            chartSelection = value
            transitionPage = 0
        }
        .onChange(of: model.period) { previousPeriod, period in
            guard isCurrentSession else { return }
            transitionPage = 0
            guard previousPeriod != period else { return }
            if let pending = pendingScrollRestore {
                pendingScrollRestorePeriod = period
                guard model.snapshot != nil else { return }
                guard scrollTargetExists(pending) else {
                    pendingScrollRestore = nil
                    pendingScrollRestorePeriod = nil
                    localScrollPosition = "quota-history-top"
                    scrollPosition = "quota-history-top"
                    return
                }
                pendingScrollRestore = nil
                pendingScrollRestorePeriod = nil
                localScrollPosition = pending
                scrollPosition = pending
                return
            }

            let anchor = scrollPosition ?? localScrollPosition
            guard let anchor, anchor != "quota-history-top" else { return }
            guard model.snapshot != nil else {
                pendingScrollRestore = anchor
                pendingScrollRestorePeriod = period
                localScrollPosition = nil
                return
            }
            guard !scrollTargetExists(anchor) else { return }
            localScrollPosition = "quota-history-top"
            scrollPosition = "quota-history-top"
        }
        .onDisappear {
            onClose()
        }
    }

    private static func pendingTarget(from target: String?) -> String? {
        guard let target, target != "quota-history-top" else { return nil }
        return target
    }

    private func captureIncomingScrollTargetIfNeeded() {
        guard isCurrentSession else { return }
        guard let incomingTarget = scrollPosition else {
            pendingScrollRestore = nil
            pendingScrollRestorePeriod = nil
            localScrollPosition = nil
            return
        }
        guard incomingTarget != "quota-history-top" else {
            pendingScrollRestore = nil
            pendingScrollRestorePeriod = nil
            localScrollPosition = incomingTarget
            return
        }
        guard pendingScrollRestore != incomingTarget else { return }
        pendingScrollRestore = incomingTarget
        pendingScrollRestorePeriod = model.period
        localScrollPosition = nil
    }

    private func restorePendingScrollIfAvailable(using scrollProxy: ScrollViewProxy) {
        guard isCurrentSession,
              let target = pendingScrollRestore else { return }
        guard pendingScrollRestorePeriod == model.period else {
            pendingScrollRestore = nil
            pendingScrollRestorePeriod = nil
            return
        }
        guard scrollTargetExists(target) else {
            if model.snapshot != nil {
                pendingScrollRestore = nil
                pendingScrollRestorePeriod = nil
            }
            return
        }
        pendingScrollRestore = nil
        pendingScrollRestorePeriod = nil
        localScrollPosition = target
        scrollPosition = target
        scrollProxy.scrollTo(target, anchor: .top)
    }

    private func scrollTargetExists(_ target: String) -> Bool {
        guard target != "quota-history-top" else { return true }
        guard model.hasHistoryRows,
              model.days.contains(where: { $0.observationCount > 0 }) else { return false }
        return model.days.contains { day in
            "quota-history-day-\(day.day.timeIntervalSinceReferenceDate)" == target
        }
    }

    private func sourceAndCurrentContext(width: CGFloat) -> some View {
        let innerWidth = DirectorPageLayout.contentWidth(for: width)

        return Group {
            if innerWidth >= 880 {
                HStack(alignment: .top, spacing: DirectorSpacing.space6) {
                    currentAllowance(width: innerWidth - 304)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sourceSection
                        .frame(width: 280, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    currentAllowance(width: innerWidth)
                    sourceSection
                        .frame(width: min(280, innerWidth))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.top, DirectorSpacing.space2)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(copy("home.quotaHistory.source", fallback: "Source"))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            DirectorOutlinedMenuField(
                model.sourceKey == nil
                    ? copy("home.quotaHistory.noSourceSelected", fallback: "No source selected")
                    : (model.selectedSourceLabel.isEmpty ? copy("home.quotaHistory.unknownSource", fallback: "Unknown source") : model.selectedSourceLabel),
                height: 36,
                titleLineLimit: 2
            ) {
                ForEach(model.sourceOptions) { source in
                    Button {
                        onSourceChange(source.id)
                    } label: {
                        Text(source.name)
                    }
                }
            }
            .disabled(model.sourceOptions.isEmpty)
            .frame(maxWidth: 280)
            .accessibilityIdentifier("quota-history-source")
            .accessibilityLabel(copy("home.quotaHistory.source", fallback: "Source"))
            .accessibilityValue(
                model.sourceKey == nil
                    ? copy("home.quotaHistory.noSourceSelected", fallback: "No source selected")
                    : (model.selectedSourceLabel.isEmpty ? copy("home.quotaHistory.unknownSource", fallback: "Unknown source") : model.selectedSourceLabel)
            )
            Text(copy("home.quotaHistory.sourceHelp", fallback: "Accounts sharing a source cannot be distinguished."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currentAllowance(width: CGFloat) -> some View {
        let currentQuota = model.currentQuotaModel
        return VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            let layout = width >= 420
                ? AnyLayout(HStackLayout(alignment: .top, spacing: DirectorSpacing.space4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: DirectorSpacing.space2))
            layout {
                allowanceRow(
                    title: copy("home.quotaHistory.weeklyRemaining", fallback: "Weekly remaining"),
                    accessibilityTitle: copy("home.quota.weekly", fallback: "Weekly"),
                    remaining: currentQuota.remainingPercent,
                    observation: currentQuota.currentObservation,
                    stale: currentQuota.isCurrentObservationStale
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shortRemaining = currentQuota.shortRemainingPercent {
                    Rectangle()
                        .fill(DirectorColor.boundary)
                        .frame(width: width >= 420 ? 1 : nil, height: width >= 420 ? 44 : 1)
                        .accessibilityHidden(true)
                    allowanceRow(
                        title: copy("home.quotaHistory.fiveHourRemaining", fallback: "5-hour remaining"),
                        accessibilityTitle: copy("home.quota.fiveHour", fallback: "5-hour"),
                        remaining: shortRemaining,
                        observation: currentQuota.shortCurrentObservation,
                        stale: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.sourceKey != nil && !model.isHomeSourceAvailable {
                statusLine(
                    symbol: "questionmark.circle",
                    text: copy("home.quotaHistory.currentSourceUnavailable", fallback: "The selected source is no longer available in Home; current allowance is unknown."),
                    color: DirectorColor.status(.unknown)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy("home.quotaHistory.current", fallback: "Current allowance"))
    }

    private func allowanceRow(title: String, accessibilityTitle: String? = nil, remaining: Double?, observation: QuotaSnapshot?, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                Text(title)
                    .font(DirectorTypography.supporting.weight(.semibold))
                    .foregroundStyle(DirectorColor.textPrimary)
                Text(remaining.map { percent($0) } ?? "—")
                    .font(DirectorTypography.metric)
                    .foregroundStyle(remaining == nil ? DirectorColor.textSecondary : DirectorColor.dataText)
                    .fixedSize()
            }

            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space1) {
                Text(copy("home.quotaHistory.reportedReset", fallback: "Reported reset"))
                Text(observation?.resetsAt.map(dateTime) ?? copy("home.quota.unknown", fallback: "Unknown"))
                    .foregroundStyle(DirectorColor.textPrimary)
            }
            .font(DirectorTypography.label)
            .foregroundStyle(DirectorColor.textSupporting)
            .fixedSize(horizontal: false, vertical: true)

            if stale {
                Text(copy("home.quotaHistory.currentExpired", fallback: "Waiting for a new quota record; this reported allowance has expired."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.sourceKey != nil,
                      model.isHomeSourceAvailable,
                      remaining == nil,
                      observation == nil {
                Text(copy("home.quotaHistory.currentUnavailable", fallback: "No valid current report is available."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(allowanceAccessibilityLabel(title: accessibilityTitle ?? title, remaining: remaining, observation: observation, stale: stale))
    }

    private func trendSection(width: CGFloat) -> some View {
        let innerWidth = DirectorPageLayout.contentWidth(for: width)
        return VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            chartHeading
            periodAndCoverage(width: width)
            historyStatus
            chartSection(width: innerWidth)
        }
        .padding(.top, innerWidth >= 880 ? DirectorSpacing.space5 : DirectorSpacing.space4)
    }

    private var chartHeading: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(copy("home.quotaHistory.chartTitle", fallback: "Observed weekly quota use"))
                .font(DirectorTypography.sectionTitle)
                .foregroundStyle(DirectorColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(copy("home.quotaHistory.chartSubtitle", fallback: "Daily observed increase from same-source weekly quota reports"))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var historyStatus: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: DirectorSpacing.space2) {
                ProgressView().controlSize(.small)
                Text(copy("home.quotaHistory.loading", fallback: "Loading quota history…"))
            }
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textSecondary)
            .accessibilityElement(children: .combine)
        case .updating:
            statusLine(
                symbol: "arrow.triangle.2.circlepath",
                text: copy("home.quotaHistory.updating", fallback: "Updating quota history…"),
                color: DirectorColor.status(.running)
            )
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                statusLine(
                    symbol: "exclamationmark.triangle",
                    text: model.hasHistoryRows
                        ? copy("home.quotaHistory.failedKeepingOld", fallback: "Could not update history; showing the last available result.")
                        : copy("home.quotaHistory.failed", fallback: "Quota history could not be read."),
                    color: DirectorColor.status(.failure)
                )
                Button(copy("common.retry", fallback: "Retry"), action: model.retry)
                    .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                    .accessibilityIdentifier("quota-history-retry")
            }
        case .unavailable:
            if model.sourceKey == nil {
                statusLine(
                    symbol: "questionmark.circle",
                    text: copy("home.quotaHistory.noSourceSelectedHelp", fallback: "Choose a quota source above to read its current allowance and history."),
                    color: DirectorColor.status(.unknown)
                )
            } else if model.isHomeSourceAvailable {
                statusLine(
                    symbol: "questionmark.circle",
                    text: copy("home.quotaHistory.unavailable", fallback: "Quota history is unavailable. Current allowance data is unchanged."),
                    color: DirectorColor.status(.unknown)
                )
            }
        case .idle, .loaded:
            EmptyView()
        }
    }

    private func statusLine(symbol: String, text: String, color: Color) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(DirectorTypography.label)
        .foregroundStyle(DirectorColor.textSupporting)
        .accessibilityElement(children: .combine)
    }

    private func periodAndCoverage(width: CGFloat) -> some View {
        let innerWidth = DirectorPageLayout.contentWidth(for: width)

        return Group {
            if innerWidth >= 560 {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                    coverageText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    periodControl
                        .frame(width: 320)
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    coverageText
                    periodControl
                        .frame(width: min(320, innerWidth))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var periodControl: some View {
        DirectorOutlinedSegmentedControl(
            copy("home.quotaHistory.period", fallback: "History period"),
            selection: Binding(
                get: { model.period },
                set: { model.setPeriod($0) }
            ),
            options: [
                .init(value: .sevenDays, title: copy("home.quotaHistory.period7", fallback: "Last 7 days")),
                .init(value: .thirtyDays, title: copy("home.quotaHistory.period30", fallback: "Last 30 days")),
                .init(value: .sixtyDays, title: copy("home.quotaHistory.period60", fallback: "Last 60 days"))
            ],
            minimumHeight: 36
        )
        .accessibilityIdentifier("quota-history-period")
        .accessibilityValue(periodTitle)
        .frame(maxWidth: .infinity)
    }

    private var coverageText: some View {
        Group {
            if let recorded = model.recordedDayCount, let calculable = model.calculableDayCount {
                Text(copy("home.quotaHistory.coverage", fallback: "Recorded %lld/%lld days · Calculable %lld/%lld days", Int64(recorded), Int64(model.days.count), Int64(calculable), Int64(model.days.count)))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textPrimary)
            } else {
                Text(copy("home.quotaHistory.coveragePending", fallback: "Recorded — · Calculable —"))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
            Text(label)
            Text(value)
                .foregroundStyle(DirectorColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DirectorTypography.label)
        .foregroundStyle(DirectorColor.textSupporting)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chartSection(width: CGFloat) -> some View {
        let height: CGFloat = width >= 640 ? 310 : 250
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            if model.phase == .loading && model.snapshot == nil {
                chartPlaceholder(height: height)
            } else if model.phase == .failed && model.snapshot == nil {
                chartPlaceholder(height: height)
            } else if model.phase == .unavailable && model.sourceKey == nil {
                chartPlaceholder(height: height)
            } else if !model.hasHistoryRows {
                chartPlaceholder(height: height)
            } else if model.days.allSatisfy({ $0.observationCount == 0 }) {
                Text(copy("home.quotaHistory.noRecords", fallback: "This source has no quota records in the selected period."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
            } else if availableDays.isEmpty {
                Text(copy("home.quotaHistory.noCalculableDays", fallback: "No day in this period has enough evidence for a numeric value."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
            } else {
                fittedHistoryChart(width: width)
                    .frame(height: height)
            }
            transitionBand
        }
    }

    private func chartPlaceholder(height: CGFloat) -> some View {
        Text("—")
            .font(DirectorTypography.metric)
            .foregroundStyle(DirectorColor.textSecondary)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
            .accessibilityLabel(chartPlaceholderLabel)
    }

    private var chartPlaceholderLabel: String {
        switch model.phase {
        case .loading, .updating:
            return copy("home.quotaHistory.chartPending", fallback: "Waiting for history evidence…")
        case .failed:
            return copy("home.quotaHistory.chartFailed", fallback: "History could not be read. Retry to request this source again.")
        case .unavailable:
            return model.sourceKey == nil
                ? copy("home.quotaHistory.noSourceSelectedHelp", fallback: "Choose a quota source above to read its current allowance and history.")
                : (!model.isHomeSourceAvailable
                    ? copy("home.quotaHistory.currentSourceUnavailable", fallback: "The selected source is no longer available in Home; current allowance is unknown.")
                    : copy("home.quotaHistory.unavailable", fallback: "Quota history is unavailable. Current allowance data is unchanged."))
        case .idle, .loaded:
            return copy("home.quotaHistory.noSnapshot", fallback: "No quota history is available for this source.")
        }
    }

    /// A separate interval band communicates accepted cycle transitions as
    /// ranges between observations. It intentionally avoids a point or line
    /// that could imply the platform exposed an exact reset instant.
    @ViewBuilder
    private var transitionBand: some View {
        let transitions = model.visibleTransitions
        if !transitions.isEmpty {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                    Text(copy("home.quotaHistory.transitionBand", fallback: "Observed cycle transition"))
                        .font(DirectorTypography.label.weight(.semibold))
                        .foregroundStyle(DirectorColor.textPrimary)
                    Spacer(minLength: DirectorSpacing.space2)
                    Text(copy("home.quotaHistory.transitionCount", fallback: "%lld cycle transitions", Int64(transitions.count)))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSupporting)
                }
                Text(copy(
                    "home.quotaHistory.transitionBandHelp",
                    fallback: "Orange segments show where a quota cycle changed between two reports in the selected period. The exact reset time is unknown."
                ))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DirectorColor.boundary)
                            .frame(height: 6)
                        ForEach(transitions) { transition in
                            let bounds = transitionBandBounds(for: transition, width: proxy.size.width)
                            Capsule()
                                .fill(DirectorColor.status(.warning).opacity(0.82))
                                .frame(width: bounds.width, height: 10)
                                .offset(x: bounds.origin)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy("home.quotaHistory.transitionBandAccessibility", fallback: "Observed cycle transition interval band"))
                .accessibilityValue(transitions.map { transition in
                    copy("home.quotaHistory.transitionBetween", fallback: "Between %@ and %@", dateTime(transition.beforeObservedAt), dateTime(transition.afterObservedAt))
                }.joined(separator: ", "))
            }
            .padding(.top, DirectorSpacing.space1)
        }
    }

    private func dataDetails(width: CGFloat) -> some View {
        let innerWidth = DirectorPageLayout.contentWidth(for: width)
        return VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $isDataDetailsExpanded) {
                if isDataDetailsExpanded {
                    detailsGroups(width: width)
                        .padding(.top, DirectorSpacing.space2)
                        .padding(.bottom, DirectorSpacing.space3)
                }
            } label: {
                Text(copy("home.quotaHistory.dataDetails", fallback: "Data details"))
                    .font(DirectorTypography.supporting.weight(.semibold))
                    .foregroundStyle(DirectorColor.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("quota-history-data-details")

            Rectangle()
                .fill(DirectorColor.boundary)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .padding(.top, innerWidth >= 640 ? DirectorSpacing.space4 : DirectorSpacing.space3)
    }

    private func detailsGroups(width: CGFloat) -> some View {
        let innerWidth = DirectorPageLayout.contentWidth(for: width)
        return Group {
            if innerWidth >= 640 {
                HStack(alignment: .top, spacing: DirectorSpacing.space3) {
                    currentCaptureDetails
                    historySnapshotDetails
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    currentCaptureDetails
                    historySnapshotDetails
                }
            }
        }
    }

    private var currentCaptureDetails: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(copy("home.quotaHistory.currentCaptures", fallback: "Current allowance captures"))
                .font(DirectorTypography.label.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
            metadataRow(
                copy("home.quotaHistory.weeklyCapture", fallback: "Weekly captured"),
                value: model.weeklyObservation.map { dateTime($0.capturedAt) } ?? "—"
            )
            if model.shortRemainingPercent != nil, let shortObservation = model.shortObservation {
                metadataRow(
                    copy("home.quotaHistory.fiveHourCapture", fallback: "5-hour captured"),
                    value: dateTime(shortObservation.capturedAt)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySnapshotDetails: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(copy("home.quotaHistory.historySnapshot", fallback: "History snapshot"))
                .font(DirectorTypography.label.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
            metadataRow(
                copy("home.quotaHistory.lastObserved", fallback: "History last observed"),
                value: model.snapshot?.lastObservedAt.map(dateTime) ?? "—"
            )
            metadataRow(
                copy("home.quotaHistory.asOf", fallback: "As of"),
                value: model.snapshot.map { dateTime($0.asOf) } ?? "—"
            )
            metadataRow(
                copy("home.quotaHistory.readAt", fallback: "Read at"),
                value: model.snapshot.map { dateTime($0.readAt) } ?? "—"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fittedHistoryChart(width: CGFloat) -> some View {
        let dayCount = model.days.count
        let visibleDays = max(1, Int((width - 48) / 24))
        if visibleDays < dayCount {
            let domain = chartDomain
            let visibleDuration = domain.upperBound.timeIntervalSince(domain.lowerBound)
                * Double(visibleDays) / Double(dayCount)
            historyChart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleDuration)
                .chartScrollPosition(initialX: domain.upperBound.addingTimeInterval(-visibleDuration))
                .id(model.period)
        } else {
            historyChart
        }
    }

    private var historyChart: some View {
        let days = availableDays
        let axisValues = QuotaHistoryViewModel.chartReferenceValues(for: days.compactMap(\.usedPercentDelta))
        let maximum = axisValues.last ?? 100
        return Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value(copy("home.quota.date", fallback: "Date"), day.day, unit: .day),
                    y: .value(copy("home.quota.dailyUsedPercent", fallback: "Daily weekly-quota use"), day.usedPercentDelta ?? 0)
                )
                .foregroundStyle(DirectorGradient.quotaBar)
                .accessibilityLabel(dayAccessibilityDate(day))
                .accessibilityValue(dayAccessibilityValue(day))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    if let used = day.usedPercentDelta {
                        Text(chartValueLabel(used))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(DirectorColor.dataText)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
            }
            if let selectedDay = model.selectedDay {
                RuleMark(x: .value(copy("home.quota.date", fallback: "Date"), selectedDay, unit: .day))
                    .foregroundStyle(DirectorColor.emphasis)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: chartDomain)
        .chartYScale(domain: 0...(maximum * 1.12))
        .chartYAxis {
            AxisMarks(position: .leading, values: axisValues) { value in
                AxisGridLine()
                    .foregroundStyle(DirectorColor.boundary.opacity(0.55))
                AxisValueLabel {
                    Text("\(Int((value.as(Double.self) ?? 0).rounded()))%")
                        .font(DirectorTypography.label.monospacedDigit())
                        .foregroundStyle(DirectorColor.textSupporting)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDays) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(languageStore.localizer.date(date, style: .dateTime.month(.twoDigits).day(.twoDigits)))
                            .font(DirectorTypography.label)
                            .fixedSize()
                    }
                }
            }
        }
        .chartXSelection(value: $chartSelection)
        .onChange(of: chartSelection) { _, value in
            guard let value, let day = day(matching: value) else { return }
            if model.selectedDay != day.day { model.selectDay(day.day) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy("home.quotaHistory.chartAccessibility", fallback: "Observed weekly quota use chart"))
    }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                Text(copy("home.quotaHistory.dailyRecords", fallback: "Daily records"))
                    .font(DirectorTypography.sectionTitle)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DirectorSpacing.space2)
                if model.transitionCount > 0 {
                    Label(
                        copy("home.quotaHistory.transitionCount", fallback: "%lld cycle changes", Int64(model.transitionCount)),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
                }
            }

            if model.phase == .loading && model.snapshot == nil {
                Text("—")
                    .font(DirectorTypography.metric)
                    .foregroundStyle(DirectorColor.textSecondary)
            } else if model.phase == .failed && model.snapshot == nil {
                Text("—")
                    .font(DirectorTypography.metric)
                    .foregroundStyle(DirectorColor.textSecondary)
            } else if model.phase == .unavailable {
                Text("—")
                    .font(DirectorTypography.metric)
                    .foregroundStyle(DirectorColor.textSupporting)
            } else if !model.hasHistoryRows {
                Text("—")
                    .font(DirectorTypography.metric)
                    .foregroundStyle(DirectorColor.textSecondary)
            } else if model.days.allSatisfy({ $0.observationCount == 0 }) {
                EmptyView()
            } else {
                // The history page is a single vertical scroll surface. A
                // lazy stack keeps the 60-day period from eagerly constructing
                // every row before the first correct paint; the chart remains
                // truthful and still receives the complete observed series.
                LazyVStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    ForEach(model.days.reversed()) { day in
                        dayRow(day)
                        if model.selectedDay == day.day, let expanded = model.expandedDay, expanded.day == day.day {
                            expandedDay(expanded)
                        }
                    }
                }
                .scrollTargetLayout()
            }
        }
        .padding(.top, DirectorSpacing.space4)
    }

    private func dayRow(_ day: QuotaHistoryDay) -> some View {
        Button {
            model.selectDay(day.day)
            chartSelection = model.selectedDay
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    Text(fullDate(day.day))
                        .font(DirectorTypography.supporting.weight(.semibold))
                        .foregroundStyle(DirectorColor.textPrimary)
                    if day.transitions.count == 1 {
                        Label(copy("home.quotaHistory.cycleChanged", fallback: "Observed cycle transition"), systemImage: "arrow.triangle.2.circlepath")
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.status(.warning))
                    } else if day.transitions.count > 1 {
                        Label(copy("home.quotaHistory.transitionCount", fallback: "%lld cycle transitions", Int64(day.transitions.count)), systemImage: "arrow.triangle.2.circlepath")
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.status(.warning))
                    }
                }
                Spacer(minLength: DirectorSpacing.space2)
                dayValue(day)
                Image(systemName: model.selectedDay == day.day ? "chevron.up" : "chevron.down")
                    .font(DirectorTypography.label.weight(.semibold))
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DirectorSpacing.space3)
            .padding(.vertical, DirectorSpacing.space3)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(model.selectedDay == day.day ? DirectorColor.inset : DirectorColor.panel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DirectorColor.boundary).frame(height: 1).accessibilityHidden(true)
        }
        .accessibilityLabel(dayAccessibilityLabel(day))
        .accessibilityAddTraits(model.selectedDay == day.day ? .isSelected : [])
        .accessibilityIdentifier("quota-history-day-\(day.day.timeIntervalSinceReferenceDate)")
        .id("quota-history-day-\(day.day.timeIntervalSinceReferenceDate)")
    }

    @ViewBuilder
    private func dayValue(_ day: QuotaHistoryDay) -> some View {
        switch day.state {
        case .available:
            Text(percent(day.usedPercentDelta ?? 0) + " " + copy("home.quotaHistory.used", fallback: "used"))
                .font(DirectorTypography.data)
                .foregroundStyle(DirectorColor.dataText)
                .fixedSize()
        case .noObservation:
            Text(copy("home.quotaHistory.noObservation", fallback: "No observation"))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSupporting)
                .fixedSize()
        default:
            Text(unknownDayValue(day.state))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.status(.unknown))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func expandedDay(_ day: QuotaHistoryDay) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            detailRow(copy("home.quotaHistory.observations", fallback: "Observations"), value: "\(day.observationCount)")
            detailRow(copy("home.quotaHistory.observedFrom", fallback: "Observed from"), value: day.firstObservedAt.map(dateTime) ?? "—")
            detailRow(copy("home.quotaHistory.observedTo", fallback: "Observed to"), value: day.lastObservedAt.map(dateTime) ?? "—")
            detailRow(copy("home.quotaHistory.baseline", fallback: "Baseline"), value: observationValue(day.baseline))
            detailRow(copy("home.quotaHistory.firstLast", fallback: "First → last"), value: "\(observationValue(day.firstObservation)) → \(observationValue(day.lastObservation))")

            if let reason = reasonText(for: day.state) {
                Text(reason)
                    .font(DirectorTypography.label)
                    .foregroundStyle(day.state == .noObservation ? DirectorColor.textSupporting : DirectorColor.status(.unknown))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !day.transitions.isEmpty {
                VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    Text(copy("home.quotaHistory.transitionInterval", fallback: "Observed cycle transition intervals"))
                        .font(DirectorTypography.label.weight(.semibold))
                        .foregroundStyle(DirectorColor.textPrimary)
                    ForEach(model.transitions(for: day, page: transitionPage)) { transition in
                        Text(copy("home.quotaHistory.transitionBetween", fallback: "Between %@ and %@", dateTime(transition.beforeObservedAt), dateTime(transition.afterObservedAt)))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSupporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if transitionPageCount(for: day) > 1 {
                        HStack(alignment: .center, spacing: DirectorSpacing.space2) {
                            Button {
                                transitionPage = max(0, transitionPage - 1)
                            } label: {
                                Label(copy("home.quotaHistory.previousTransitions", fallback: "Previous"), systemImage: "chevron.left")
                            }
                            .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                            .disabled(transitionPage == 0)
                            .accessibilityIdentifier("quota-history-transition-previous")

                            Text(copy("home.quotaHistory.transitionPage", fallback: "Page %lld of %lld", Int64(transitionPage + 1), Int64(transitionPageCount(for: day))))
                                .font(DirectorTypography.label.monospacedDigit())
                                .foregroundStyle(DirectorColor.textSupporting)
                                .frame(minWidth: 76)
                                .multilineTextAlignment(.center)
                                .accessibilityLabel(copy("home.quotaHistory.transitionPage", fallback: "Page %lld of %lld", Int64(transitionPage + 1), Int64(transitionPageCount(for: day))))

                            Button {
                                transitionPage = min(transitionPageCount(for: day) - 1, transitionPage + 1)
                            } label: {
                                Label(copy("home.quotaHistory.nextTransitions", fallback: "Next"), systemImage: "chevron.right")
                            }
                            .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                            .disabled(transitionPage >= transitionPageCount(for: day) - 1)
                            .accessibilityIdentifier("quota-history-transition-next")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
        .padding(.horizontal, DirectorSpacing.space3)
        .padding(.vertical, DirectorSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirectorColor.inset)
        .accessibilityElement(children: .contain)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
            Text(label)
            Spacer(minLength: DirectorSpacing.space2)
            Text(value)
                .foregroundStyle(DirectorColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(DirectorTypography.label)
        .foregroundStyle(DirectorColor.textSupporting)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func transitionPageCount(for day: QuotaHistoryDay) -> Int {
        max(1, Int(ceil(Double(day.transitions.count) / 20.0)))
    }

    private var availableDays: [QuotaHistoryDay] {
        model.days.filter { $0.state == .available && $0.usedPercentDelta != nil }
    }

    private func transitionBandBounds(for transition: QuotaHistoryTransition, width: CGFloat) -> (origin: CGFloat, width: CGFloat) {
        guard let firstDay = model.days.first?.day,
              let lastDay = model.days.last?.day else {
            return (0, max(6, width))
        }
        let timeZone = TimeZone(identifier: model.snapshot?.timeZoneIdentifier ?? "") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        let total = max(end.timeIntervalSince(firstDay), 1)
        let startRatio = min(1, max(0, transition.beforeObservedAt.timeIntervalSince(firstDay) / total))
        let endRatio = min(1, max(startRatio, transition.afterObservedAt.timeIntervalSince(firstDay) / total))
        let origin = CGFloat(startRatio) * width
        return (origin, max(6, CGFloat(endRatio - startRatio) * width))
    }

    private var axisDays: [Date] {
        let days = model.days
        guard days.count > 7 else { return days.map(\.day) }
        let stride = days.count > 30 ? 10 : 5
        return days.enumerated().compactMap { index, day in index.isMultiple(of: stride) ? day.day : nil }
    }

    private var chartDomain: ClosedRange<Date> {
        guard let first = model.days.first?.day,
              let last = model.days.last?.day else {
            let now = Date()
            return now...now.addingTimeInterval(86_400)
        }
        let timeZone = TimeZone(identifier: model.snapshot?.timeZoneIdentifier ?? "") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return first...((calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)))
    }

    private var periodTitle: String {
        switch model.period {
        case .sevenDays: return copy("home.quotaHistory.period7", fallback: "Last 7 days")
        case .thirtyDays: return copy("home.quotaHistory.period30", fallback: "Last 30 days")
        case .sixtyDays: return copy("home.quotaHistory.period60", fallback: "Last 60 days")
        }
    }

    private func day(matching date: Date) -> QuotaHistoryDay? {
        let timeZone = TimeZone(identifier: model.snapshot?.timeZoneIdentifier ?? "") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let exact = model.days.first(where: { calendar.isDate($0.day, inSameDayAs: date) }) else {
            return model.days.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
        }
        return exact
    }

    private func allowanceAccessibilityLabel(title: String, remaining: Double?, observation: QuotaSnapshot?, stale: Bool) -> String {
        let value = remaining.map { percent($0) } ?? copy("home.quota.unknown", fallback: "Unknown")
        let reset = observation?.resetsAt.map(dateTime) ?? copy("home.quota.unknown", fallback: "Unknown")
        let staleText = stale ? ", " + copy("home.quotaHistory.currentExpiredShort", fallback: "expired") : ""
        return "\(title), \(copy("home.quota.remaining", fallback: "Remaining")) \(value), \(copy("home.quotaHistory.reportedReset", fallback: "Reported reset")) \(reset)\(staleText)"
    }

    private func dayAccessibilityLabel(_ day: QuotaHistoryDay) -> String {
        let value: String
        switch day.state {
        case .available: value = percent(day.usedPercentDelta ?? 0) + " " + copy("home.quotaHistory.used", fallback: "used")
        case .noObservation: value = copy("home.quotaHistory.noObservation", fallback: "No observation")
        default: value = unknownDayValue(day.state)
        }
        let transition: String
        if day.transitions.isEmpty {
            transition = ""
        } else if day.transitions.count == 1 {
            transition = ", " + copy("home.quotaHistory.cycleChanged", fallback: "Observed cycle transition")
        } else {
            transition = ", " + copy("home.quotaHistory.transitionCount", fallback: "%lld cycle transitions", Int64(day.transitions.count))
        }
        return "\(fullDate(day.day)), \(value)\(transition)"
    }

    private func dayAccessibilityDate(_ day: QuotaHistoryDay) -> String { fullDate(day.day) }

    private func dayAccessibilityValue(_ day: QuotaHistoryDay) -> String {
        switch day.state {
        case .available: return percent(day.usedPercentDelta ?? 0) + " " + copy("home.quotaHistory.used", fallback: "used")
        case .noObservation: return copy("home.quotaHistory.noObservation", fallback: "No observation")
        default: return unknownDayValue(day.state)
        }
    }

    private func unknownDayValue(_ state: QuotaHistoryDayState) -> String {
        "— " + (reasonText(for: state) ?? copy("home.quotaHistory.unknown", fallback: "Unknown"))
    }

    private func reasonText(for state: QuotaHistoryDayState) -> String? {
        switch state {
        case .available: return nil
        case .noObservation: return copy("home.quotaHistory.reason.noObservation", fallback: "No valid observation was recorded.")
        case .missingBaseline: return copy("home.quotaHistory.reason.missingBaseline", fallback: "No trustworthy preceding baseline.")
        case .crossDayGap: return copy("home.quotaHistory.reason.crossDayGap", fallback: "Observations cross a missing calendar day.")
        case .ambiguousCycle: return copy("home.quotaHistory.reason.ambiguousCycle", fallback: "Cycle evidence is ambiguous.")
        case .evidenceConflict: return copy("home.quotaHistory.reason.evidenceConflict", fallback: "History and Home evidence conflict.")
        }
    }

    private func observationValue(_ observation: QuotaHistoryObservationSummary?) -> String {
        guard let observation else { return "—" }
        return percent(observation.usedPercent)
    }

    private func percent(_ value: Double) -> String {
        languageStore.localizer.format("home.quota.percent", fallback: "%.0f%%", value)
    }

    private func chartValueLabel(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...1))
            .locale(languageStore.locale)
        return value > 0 && value < 0.1 ? "<" + 0.1.formatted(style) : value.formatted(style)
    }

    private func fullDate(_ date: Date) -> String {
        languageStore.localizer.date(date, style: .dateTime.year().month().day())
    }

    private func dateTime(_ date: Date) -> String {
        languageStore.localizer.date(date, style: .dateTime.year().month().day().hour().minute())
    }

    private func copy(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        languageStore.localizer.format(key, fallback: fallback, arguments: arguments)
    }
}
