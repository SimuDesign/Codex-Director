import SwiftUI
import Charts
import DirectorCore

/// Home dashboard: default launch view with personal inventory summary.
public struct HomeView: View {
    @ObservedObject public var capabilities: CapabilitiesViewModel
    @ObservedObject public var usage: UsageViewModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Binding public var showEmptyProjects: Bool
    public let onShowInCapabilities: (HomeSectionFilter) -> Void

    public init(capabilities: CapabilitiesViewModel, usage: UsageViewModel, showEmptyProjects: Binding<Bool> = .constant(false), onShowInCapabilities: @escaping (HomeSectionFilter) -> Void) {
        self.capabilities = capabilities
        self.usage = usage
        _showEmptyProjects = showEmptyProjects
        self.onShowInCapabilities = onShowInCapabilities
    }

    public enum HomeSectionFilter: Equatable {
        case myAgents
        case mySkills
        case installedSkills
        case projectInstructions
        case pluginCapabilities
        case builtIn
        // Kept for compatibility with deep links from older builds.
        case globalAgents
        case projectAgents
        case globalSkills
        case projectSkills
        case installedTools
        case observedCapabilities
        case notObservedCapabilities
        case evidenceLimitedCalls
        case notEvaluatedCapabilities
    }

    private var dashboard: HomeDashboardViewModel {
        HomeDashboardViewModel(rows: capabilities.allRows, projects: capabilities.projects)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                Text(t("nav.home", "Home"))
                    .font(DirectorTypography.sectionTitle)

                Text(t("home.subtitle", "Your custom inventory and current account allowance."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)

                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    sectionTitle("home.inventory", "Inventory")
                    HStack(spacing: DirectorSpacing.space3) {
                        statCard(
                            title: t("home.myAgents", "My Agents"),
                            value: "\(dashboard.myAgentCount)",
                            subtitle: format("home.agentCounts", "Global %lld · Project %lld", Int64(dashboard.myGlobalAgentCount), Int64(dashboard.myProjectAgentCount)),
                            action: { onShowInCapabilities(.myAgents) }
                        )
                        statCard(
                            title: t("home.mySkills", "My Skills"),
                            value: "\(dashboard.mySkillCount)",
                            subtitle: format("home.skillCounts", "Global %lld · Project %lld · %@", Int64(dashboard.myGlobalSkillCount), Int64(dashboard.myProjectSkillCount), confidenceSummary(exact: dashboard.mySkillExactCount, inferred: dashboard.mySkillInferredCount)),
                            action: { onShowInCapabilities(.mySkills) }
                        )
                    }

                    HStack(spacing: DirectorSpacing.space3) {
                        statCard(
                            title: t("home.installedSkills", "Installed Skills"),
                            value: "\(dashboard.installedSkillCount)",
                            subtitle: format("home.installedSkillCounts", "GitHub %lld · Registry %lld · %@", Int64(dashboard.installedGitHubSkillCount), Int64(dashboard.installedRegistrySkillCount), confidenceSummary(exact: dashboard.installedSkillExactCount, inferred: dashboard.installedSkillInferredCount)),
                            action: { onShowInCapabilities(.installedSkills) }
                        )
                        statCard(
                            title: t("home.projectInstructions", "Project Instructions"),
                            value: "\(dashboard.projectInstructionCount)",
                            subtitle: languageStore.localizer.plural("home.projectCount", count: dashboard.projectInstructionProjectCount, fallback: "%lld projects"),
                            action: { onShowInCapabilities(.projectInstructions) }
                        )
                    }

                    statCard(
                        title: t("home.pluginCapabilities", "Plugin Capabilities"),
                        value: "\(dashboard.pluginCount)",
                        subtitle: languageStore.localizer.plural("home.pluginCount", count: dashboard.pluginCapabilityCount, fallback: "%lld enabled child capabilities"),
                        action: { onShowInCapabilities(.pluginCapabilities) }
                    )
                }

                capabilityUse

                projectBreakdown

                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    sectionTitle("home.allowance", "Allowance")
                    allowanceCard
                }

                Spacer(minLength: 0)
            }
            .padding(DirectorSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(t("nav.home", "Home"))
    }

    private var projectBreakdown: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            HStack {
                sectionTitle("home.projectBreakdown", "Project Breakdown")
                Spacer()
                Toggle(t("home.showEmptyProjects", "Show Empty Projects"), isOn: $showEmptyProjects)
                    .toggleStyle(.checkbox)
                    .font(DirectorTypography.label)
            }
            let rows = dashboard.projectBreakdown.filter { showEmptyProjects || $0.myAgents + $0.mySkills + $0.installedSkills + $0.instructions > 0 }
            if rows.isEmpty {
                Text(t("home.noProjectAssets", "No project-local assets discovered."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            } else {
                Table(rows) {
                    TableColumn(t("capability.project", "Project")) { row in
                        Label(row.name, systemImage: "folder")
                            .foregroundStyle(row.available ? DirectorColor.textPrimary : DirectorColor.textSecondary)
                    }
                    TableColumn(t("home.myAgents", "My Agents")) { row in Text("\(row.myAgents)").font(DirectorTypography.data) }
                    TableColumn(t("home.mySkills", "My Skills")) { row in Text("\(row.mySkills)").font(DirectorTypography.data) }
                    TableColumn(t("home.installedSkills", "Installed Skills")) { row in Text("\(row.installedSkills)").font(DirectorTypography.data) }
                    TableColumn(t("home.instructions", "Instructions")) { row in Text("\(row.instructions)").font(DirectorTypography.data) }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private var capabilityUse: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            sectionTitle("home.capabilityUse", "Capability Use")
            Text(t("home.capabilityUseSubtitle", "Current user-owned Agents and Skills in indexed history."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DirectorSpacing.space3) {
                    observedCapabilityCard
                    notObservedCapabilityCard
                }
                VStack(spacing: DirectorSpacing.space3) {
                    observedCapabilityCard
                    notObservedCapabilityCard
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DirectorSpacing.space3) {
                    evidenceLimitedCallsCard
                    evaluatedInvocationsCard
                }
                VStack(spacing: DirectorSpacing.space3) {
                    evidenceLimitedCallsCard
                    evaluatedInvocationsCard
                }
            }
        }
    }

    private var observedCapabilityCard: some View {
        statCard(
            title: t("home.observed", "Observed"),
            value: "\(dashboard.observedCapabilityCount)",
            subtitle: t("home.inIndexedHistory", "In indexed history"),
            action: { onShowInCapabilities(.observedCapabilities) }
        )
    }

    private var notObservedCapabilityCard: some View {
        statCard(
            title: t("home.notObserved", "Not observed"),
            value: "\(dashboard.notObservedCapabilityCount)",
            subtitle: t("home.inIndexedHistory", "In indexed history"),
            action: { onShowInCapabilities(.notObservedCapabilities) }
        )
    }

    private var evidenceLimitedCallsCard: some View {
        statCard(
            title: t("home.evidenceLimitedCalls", "Evidence-limited calls"),
            value: "\(dashboard.evidenceLimitedCallCount)",
            action: { onShowInCapabilities(.evidenceLimitedCalls) }
        )
    }

    private var evaluatedInvocationsCard: some View {
        // There is no inverse "evaluated" usage filter in the Phase 2A
        // contract; this aggregate is intentionally informational.
        statCard(
            title: t("home.evaluatedInvocations", "Evaluated invocations"),
            value: "\(dashboard.evaluatedInvocationCount)",
            subtitle: format("home.ineffectiveCount", "Ineffective %lld", Int64(dashboard.ineffectiveInvocationCount))
        )
    }

    private func sectionTitle(_ key: String, _ fallback: String) -> some View {
        Text(t(key, fallback))
            .font(DirectorTypography.sectionTitle)
    }

    private func t(_ key: String, _ fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }

    private func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        languageStore.localizer.format(key, fallback: fallback, arguments: arguments)
    }

    private func confidenceSummary(exact: Int, inferred: Int) -> String {
        format("home.confidenceSummary", "Exact %lld · Inferred %lld", Int64(exact), Int64(inferred))
    }

    @ViewBuilder
    private func statCard(title: String, value: String, subtitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                statCardContent(title: title, value: value, subtitle: subtitle)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            statCardContent(title: title, value: value, subtitle: subtitle)
        }
    }

    private func statCardContent(title: String, value: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(title)
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            Text(value)
                .font(DirectorTypography.sectionTitle)
            if let subtitle {
                Text(subtitle)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DirectorSpacing.space3)
        .background(DirectorColor.content)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DirectorColor.separator, lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var allowanceCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DirectorSpacing.space6) { quotaDonut; dailyQuotaChart }
            VStack(alignment: .leading, spacing: DirectorSpacing.space4) { quotaDonut; dailyQuotaChart }
        }
        .padding(DirectorSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirectorColor.content)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DirectorColor.separator, lineWidth: 1)
        )
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
    }

    private var quotaDonut: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(t("home.weeklyAllowance", "Weekly allowance (10,080 minutes)"))
                .font(DirectorTypography.body)
            ZStack {
                Circle().stroke(DirectorColor.separator, lineWidth: 12)
                Circle().trim(from: 0, to: CGFloat((quotaUsed ?? 0) / 100))
                    .stroke(DirectorColor.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(quotaRemaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(DirectorTypography.data)
            }
            .frame(width: 112, height: 112)
            Text(allowanceHeadline).font(DirectorTypography.supporting)
            Text(allowanceSource).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
            Text(allowanceSnapshotLine).font(DirectorTypography.label).foregroundStyle(DirectorColor.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(t("home.weeklyAllowance", "Weekly allowance (10,080 minutes)"))
        .accessibilityValue(allowanceHeadline)
    }

    private var dailyQuotaChart: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(t("home.dailyQuota", "Daily weekly-quota use")).font(DirectorTypography.body)
            Chart(usage.weeklyDailySnapshots.filter { $0.usedPercent != nil }) { item in
                if let usedPercent = item.usedPercent {
                    BarMark(x: .value("Day", item.day, unit: .day), y: .value("Used", usedPercent))
                        .foregroundStyle(DirectorColor.accent)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(minWidth: 240, minHeight: 130)
            Text(t("home.dailyQuotaNote", "Missing days show no record; values are not token totals."))
                .font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
        }
    }

    private var quotaUsed: Double? {
        switch usage.weeklyState { case .available(let q), .expired(let q): return q.usedPercent; case .unavailable: return nil }
    }

    private var quotaRemaining: Double? {
        switch usage.weeklyState { case .available(let q), .expired(let q): return q.remainingPercent; case .unavailable: return nil }
    }

    private var allowanceConfidence: EvidenceConfidence {
        switch usage.weeklyState {
        case .available(let quota):
            return quota.confidence
        case .expired(let quota):
            return quota.confidence
        case .unavailable:
            return .unknown
        }
    }

    private var allowanceHeadline: String {
        switch usage.weeklyState {
        case .available(let quota):
            return format("home.allowance.available", "Remaining %lld%% · Used %lld%%", Int64(quota.remainingPercent.rounded()), Int64(quota.usedPercent.rounded()))
        case .expired(let quota):
            return format("home.allowance.expired", "Expired snapshot · Remaining %lld%%", Int64(quota.remainingPercent.rounded()))
        case .unavailable:
            return t("home.allowance.unavailable", "No allowance snapshot available")
        }
    }

    private var allowanceSource: String {
        let selectedQuota: QuotaSnapshot?
        switch usage.weeklyState {
        case .available(let quota), .expired(let quota):
            selectedQuota = quota
        case .unavailable:
            selectedQuota = nil
        }
        let sourceName: String
        let sourceIdentifier: String
        if let selectedQuota {
            // Names and identifiers from the reported snapshot are raw
            // evidence and must remain verbatim. Only the unavailable
            // placeholder is presentation-owned copy.
            sourceName = UsageViewModel.quotaSourceName(for: selectedQuota)
            sourceIdentifier = UsageViewModel.quotaSourceIdentifier(for: selectedQuota)
        } else {
            sourceName = t("home.allowance.unknownSource", "Unknown limit source")
            sourceIdentifier = t("enum.unknown", "unknown")
        }
        return format("home.allowance.source", "Source: %@ (%@)", sourceName, sourceIdentifier)
    }

    private var allowanceSnapshotLine: String {
        guard let quota = usage.quotaForWeek else {
            return t("home.allowance.noSnapshot", "No valid snapshot selected for display.")
        }
        return format("home.allowance.snapshot", "Last reported %@ · resets %@", languageStore.localizer.date(quota.capturedAt), quota.resetsAt.map { languageStore.localizer.date($0) } ?? t("enum.unknown", "unknown"))
    }
}

private extension UsageViewModel {
    var quotaForWeek: QuotaSnapshot? {
        switch weeklyState {
        case .available(let quota), .expired(let quota):
            return quota
        case .unavailable:
            return nil
        }
    }
}
