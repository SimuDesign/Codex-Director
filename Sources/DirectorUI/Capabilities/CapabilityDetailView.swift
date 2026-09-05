import SwiftUI
import DirectorCore

public struct CapabilityDetailView: View {
    @ObservedObject public var model: CapabilityDetailViewModel
    public let onBack: () -> Void
    /// The compact, same-region detail stage owns the Back/Escape transition.
    /// The wide library layout already supplies a native inspector dismissal,
    /// so it must not duplicate that navigation affordance inside the panel.
    public let showsBackButton: Bool
    @EnvironmentObject private var languageStore: AppLanguageStore
    @State private var showTechnical = false
    @State private var showClassification = false
    @State private var showFindings = false
    @State private var showEvidence = false

    public init(model: CapabilityDetailViewModel, onBack: @escaping () -> Void = {}, showsBackButton: Bool = true) { self.model = model; self.onBack = onBack; self.showsBackButton = showsBackButton }
    public var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
            if showsBackButton {
                Button(copy("detail.back", "Back to list"), action: onBack).keyboardShortcut(.escape, modifiers: [])
            }
            Text("/ \(model.row.id)")
                .font(DirectorTypography.eyebrow)
                .foregroundStyle(DirectorColor.accent(.teal))
                .textSelection(.enabled)
            Text(model.row.entry.resource.name)
                .font(DirectorTypography.sectionTitle.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
            identity; usage; evidenceControl
            if showEvidence { calls }
            if let error = model.persistenceError { VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(copy("detail.persistenceError", "Unable to save local judgment.")).font(DirectorTypography.sectionTitle)
                Text(errorMessage(error)).font(DirectorTypography.supporting)
            }.foregroundStyle(DirectorColor.status(.failure)) }
            disclosure(copy("detail.technical", "Technical information"), isExpanded: $showTechnical) { technical }
            disclosure(copy("detail.classification", "Classification correction"), isExpanded: $showClassification) { classification }
            disclosure(copy("detail.findings", "Related review findings"), isExpanded: $showFindings) { findings }
        }.padding(DirectorSpacing.space5).frame(maxWidth: .infinity, alignment: .leading) }
        .task(id: showFindings) { if showFindings { await model.loadFindingsIfNeeded() } else { model.cancelFindingsLoading() } }
        .onDisappear {
            model.cancelLoading()
            model.cancelFindingsLoading()
        }
    }
    private var localizer: DirectorLocalizer { languageStore.localizer }
    private func copy(_ key: String, _ fallback: String, _ args: CVarArg...) -> String { localizer.format(key, fallback: fallback, arguments: args) }
    private var identity: some View { VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
        Text(model.isPurposeMissing ? copy("detail.purposeMissing", "Purpose not declared") : (CapabilityPurposeLocalization.localizedSummary(for: model.row.entry.resource, language: languageStore.language) ?? copy("detail.purposeMissing", "Purpose not declared")))
        Text("\(ownershipLabel) · \(originLabel)").foregroundStyle(DirectorColor.textSecondary)
        if model.row.entry.category == .customAgents || model.row.entry.category == .customSkills { Text("\(copy("detail.sourceModified", "Source modified")): \(model.row.entry.resource.sourceModifiedAt.map { localizer.date($0) } ?? copy("detail.notAvailable", "Not available"))").foregroundStyle(DirectorColor.textSecondary) }
    }.font(DirectorTypography.body) }
    private var usage: some View { VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
        HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            detailStat(copy("detail.metric.recent", "Past 7 days"), recentUsageValue)
            detailStat(copy("detail.metric.inferred", "Inferred"), String(model.inferredCount))
        }
        if !model.usageProjectNames.isEmpty {
            Text(model.usageProjectNames.joined(separator: ", "))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        }
    } }
    private func detailStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(label).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
            Text(value).font(DirectorTypography.data.weight(.semibold)).foregroundStyle(DirectorColor.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DirectorSpacing.space3)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary).frame(height: 1) }
    }
    private var recentUsageValue: String {
        if let count = model.recent7Count {
            return localizer.plural("detail.callCount", count: count, fallback: "%lld calls")
        }
        if !model.statisticsReady { return copy("detail.recent7Preparing", "Preparing statistics") }
        if model.attributionUnavailable { return copy("detail.recent7AttributionUnavailable", "Attribution unavailable") }
        return copy("detail.recent7Unavailable", "Unavailable")
    }
    @ViewBuilder private var evidenceControl: some View {
        if showEvidence {
            Button {
                showEvidence = false
            } label: { Text(copy("detail.hideUsageEvidence", "Hide usage evidence")).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .accessibilityHint(copy("detail.hideUsageEvidenceHint", "Hides the loaded usage evidence without clearing it."))
        } else {
            Button {
                showEvidence = true
                model.requestEvidence()
            } label: { Text(copy("detail.usageEvidence", "View usage evidence")).frame(maxWidth: .infinity) }
            .buttonStyle(DirectorPrimaryActionButtonStyle())
            .accessibilityHint(copy("detail.usageEvidenceHint", "Loads usage evidence the first time it is requested."))
        }
    }
    private var calls: some View { VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
        Text(copy("detail.recentCalls", "Recent calls")).font(DirectorTypography.sectionTitle)
        if case .failed = model.state { VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(copy("detail.dataError", "Data error")).font(DirectorTypography.sectionTitle)
            HStack { Text(copy("detail.loadFailed", "Unable to load recent calls.")).foregroundStyle(DirectorColor.status(.failure)); Spacer(); Button(copy("detail.retry", "Retry")) { model.reload() } }
        } }
        else if model.invocations.isEmpty && model.state == .empty { Text(copy("detail.noCalls", "No observed calls.")).foregroundStyle(DirectorColor.textSecondary) }
        ForEach(model.invocations) { invocationCard($0) }
        if model.nextCursor != nil { Button(copy("detail.loadMore", "Load more"), action: model.loadMore).disabled(model.state == .loading) }
        if model.state == .loading { ProgressView().controlSize(.small) }
    } }
    private func invocationCard(_ call: CapabilityDetailInvocation) -> some View { VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
        HStack { Text(call.event.timestamp.map { localizer.date($0) } ?? "—"); Spacer(); Text(invocationStatusLabel(call.event.status)) }
        Text(call.projectName ?? copy("detail.unassociated", "Unassociated project")).foregroundStyle(DirectorColor.textSecondary)
        Text("\(copy("detail.evidence", "Evidence")): \(confidenceLabel(call.confidence))").foregroundStyle(DirectorColor.textSecondary)
        HStack { Picker(copy("detail.evaluation", "Evaluation"), selection: evaluationBinding(for: call)) {
            Text(copy("evaluation.none", "Not evaluated")).tag(Optional<InvocationEvaluationLabel>.none)
            ForEach(InvocationEvaluationLabel.allCases, id: \.self) { label in Text(evaluationLabel(label)).tag(Optional(label)) }
        }.pickerStyle(.menu).accessibilityValue(evaluationLabel(model.evaluation(for: call)?.label)); if model.evaluation(for: call) != nil { Button(copy("detail.clear", "Clear")) { _ = model.clearEvaluation(for: call) } } }
    }.padding(.vertical, DirectorSpacing.space2).overlay(alignment: .bottom) { Divider() } }
    private func evaluationBinding(for call: CapabilityDetailInvocation) -> Binding<InvocationEvaluationLabel?> { Binding(get: { model.evaluation(for: call)?.label }, set: { value in if let value { _ = model.setEvaluation(value, for: call) } else { _ = model.clearEvaluation(for: call) } }) }
    private var technical: some View { VStack(alignment: .leading, spacing: DirectorSpacing.space1) { Text("\(copy("detail.technical.id", "ID")): \(model.row.id)"); Text("\(copy("detail.technical.source", "Source")): \(model.row.entry.resource.relativeSourcePath ?? "—")"); Text("\(copy("detail.technical.root", "Root")): \(model.row.entry.resource.sourceRootID)" ) }.font(DirectorTypography.code).textSelection(.enabled) }
    private var classification: some View { HStack { Text(ownershipLabel); if model.row.entry.resource.isSkillClassificationCorrectable {
        Button(copy("detail.mySkill", "My Skill")) { model.onClassify?(model.row.id, .userOwned) }
        Button(copy("detail.installedSkill", "Installed Skill")) { model.onClassify?(model.row.id, .installed) }
        Button(copy("detail.reset", "Reset")) { model.onResetClassification?(model.row.id) }
    } } }
    private var findings: some View { Group { switch model.findingsState { case .idle: ProgressView(copy("detail.findingsLoading", "Loading findings…")).controlSize(.small); case .loading: if model.findings.isEmpty { ProgressView(copy("detail.findingsLoading", "Loading findings…")).controlSize(.small) } else { findingsList }; case .failed: VStack(alignment: .leading, spacing: DirectorSpacing.space2) { Text(copy("detail.findingsLoadFailed", "Unable to load related findings.")).foregroundStyle(DirectorColor.status(.failure)); Button(copy("detail.retry", "Retry")) { Task { await model.loadFindingsIfNeeded(force: true) } }; if !model.findings.isEmpty { findingsList } }; case .empty, .loaded: findingsList } } }
    private var recentUsageLabel: String { if let count = model.recent7Count { return "\(copy("detail.recent7Label", "Last 7 days")): \(localizer.plural("detail.callCount", count: count, fallback: "%lld calls"))" }; if !model.statisticsReady { return copy("detail.recent7Preparing", "Last 7 days: preparing statistics") }; if model.attributionUnavailable { return copy("detail.recent7AttributionUnavailable", "Last 7 days: attribution unavailable") }; return copy("detail.recent7Unavailable", "Last 7 days: unavailable") }
    @ViewBuilder private var findingsList: some View { if model.findings.isEmpty { Text(copy("detail.noFindings", "No related findings.")) } else { ForEach(model.findings) { finding in VStack(alignment: .leading) { Text(localizer.text("review.rule.\(finding.ruleID).summary", fallback: finding.summary)); Text(finding.evidenceSummary).foregroundStyle(DirectorColor.textSecondary) } } } }
    private func disclosure<Content: View>(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View { DisclosureGroup(title, isExpanded: isExpanded, content: content) }
    private var ownershipLabel: String { localizer.enumLabel(.init(key: "enum.\(model.row.entry.resource.ownership.rawValue)", fallback: model.row.entry.resource.ownership.rawValue)) }
    private var originLabel: String { localizer.enumLabel(.init(key: "enum.\(model.row.entry.resource.origin.rawValue)", fallback: model.row.entry.resource.origin.rawValue)) }
    private func confidenceLabel(_ value: EvidenceConfidence) -> String { localizer.enumLabel(.init(key: "confidence.\(value.rawValue)", fallback: value.rawValue)) }
    private func statusLabel(_ value: RuntimeStatus) -> String { localizer.enumLabel(.init(key: "status.\(value.rawValue)", fallback: value.rawValue)) }
    private func invocationStatusLabel(_ value: InvocationStatus) -> String { localizer.enumLabel(.init(key: "status.\(value.rawValue)", fallback: value.rawValue)) }
    private func errorMessage(_ key: String) -> String {
        if languageStore.language == .simplifiedChinese {
            switch key { case "detail.evaluationUnavailable": return "评价存储不可用。"; case "detail.evaluationSaveFailed": return "无法保存评价。"; case "detail.evaluationClearFailed": return "无法清除评价。"; default: return "请稍后重试。" }
        }
        switch key { case "detail.evaluationUnavailable": return "Evaluation storage is unavailable."; case "detail.evaluationSaveFailed": return "Unable to save evaluation."; case "detail.evaluationClearFailed": return "Unable to clear evaluation."; default: return "Please try again." }
    }
    private func evaluationLabel(_ value: InvocationEvaluationLabel?) -> String { value.map { localizer.text("evaluation.\($0.rawValue)", fallback: $0.rawValue.capitalized) } ?? copy("evaluation.none", "Not evaluated") }
}
