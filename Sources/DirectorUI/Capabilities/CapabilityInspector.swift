import SwiftUI
import DirectorCore

/// Inspector for a selected capability.
///
/// Section order: identity, source, confidence, relationships, recent use,
/// review, advanced evidence (DESIGN_SYSTEM_V1 §11.3).
public struct CapabilityInspector: View {
    @EnvironmentObject private var languageStore: AppLanguageStore
    public let resource: CapabilityResource
    public let relations: [ResourceRelation]
    public let usage: CapabilityRow
    public let findings: [ReviewFinding]
    public let provenance: [CapabilityProvenance]
    public let onDismiss: () -> Void
    public let onClassify: ((ResourceOwnership) -> Void)?
    public let onResetClassification: (() -> Void)?

    /// Accessibility identifier for the native dismissal control.
    public static let closeButtonAccessibilityIdentifier = "capabilityInspector.close"

    public init(
        resource: CapabilityResource,
        relations: [ResourceRelation],
        usage: CapabilityRow,
        findings: [ReviewFinding],
        provenance: [CapabilityProvenance] = [],
        onDismiss: @escaping () -> Void = {},
        onClassify: ((ResourceOwnership) -> Void)? = nil,
        onResetClassification: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.relations = relations
        self.usage = usage
        self.findings = findings
        self.provenance = provenance
        self.onDismiss = onDismiss
        self.onClassify = onClassify
        self.onResetClassification = onResetClassification
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                header

                section("inspector.identity", "Identity") {
                    EvidenceInspector(items: [
                        .init(id: "id", label: t("ID", "ID"), value: resource.id),
                        .init(id: "kind", label: t("capability.kind", "Kind"), value: kindLabel),
                        .init(id: "scope", label: t("capability.scope", "Scope"), value: scopeLabel),
                        .init(id: "project", label: t("capability.project", "Project"), value: resource.projectID ?? "—"),
                        .init(id: "ownership", label: t("capability.ownership", "Ownership"), value: ownershipLabel),
                        .init(id: "origin", label: t("capability.origin", "Origin"), value: originLabel),
                        .init(id: "modified", label: t("inspector.modified", "Modified"), value: resource.modified ? t("inspector.modified", "Modified") : t("inspector.unchanged", "Unchanged")),
                    ])
                }

                section("inspector.purpose", "Purpose") {
                    Text(CapabilityPurposeLocalization.localizedSummary(for: resource, language: languageStore.language) ?? t("capability.noPurpose", "No bounded purpose summary declared."))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(resource.summary == nil ? DirectorColor.textSecondary : DirectorColor.textPrimary)
                        .textSelection(.enabled)
                    if resource.kind == .agent || resource.kind == .skill {
                        Text(t("capability.noTriggers", "Trigger conditions and constraints are not declared as structured metadata."))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                    }
                }

                section("inspector.source", "Source") {
                    EvidenceInspector(items: [
                        .init(id: "root", label: t("inspector.sourceRoot", "Source root"), value: resource.sourceRootID),
                        .init(id: "path", label: t("inspector.relativePath", "Relative path"), value: resource.relativeSourcePath ?? "—"),
                        .init(id: "hash", label: t("inspector.pathHash", "Path hash"), value: resource.sourcePathHash ?? "—"),
                        .init(id: "version", label: t("inspector.version", "Version"), value: resource.sourceVersion ?? "—"),
                        .init(id: "fingerprint", label: t("inspector.contentFingerprint", "Content fingerprint"), value: resource.contentFingerprint ?? "—"),
                        .init(id: "modified-at", label: t("inspector.sourceModified", "Source modified"), value: resource.sourceModifiedAt.map { languageStore.localizer.date($0) } ?? "—"),
                        .init(id: "change", label: t("inspector.changeState", "Change state"), value: resource.modified ? t("inspector.modified", "Modified") : t("inspector.unchanged", "Unchanged")),
                    ])
                }

                section("inspector.confidence", "Confidence") {
                    HStack(spacing: DirectorSpacing.space2) {
                        ConfidenceBadge(confidence: resource.confidence)
                        Text(confidenceNote)
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                    Text(format("inspector.classificationConfidence", "Classification confidence: %@", classificationConfidenceLabel))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                }

                section("inspector.provenance", "Provenance") {
                    if provenance.isEmpty {
                        Text(t("capability.noProvenance", "No structured provenance record."))
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                    } else {
                        ForEach(provenance) { record in
                            EvidenceInspector(items: [
                                .init(id: record.id + "-source", label: t("capability.origin", "Source"), value: originLabel(record.sourceType)),
                                .init(id: record.id + "-id", label: t("inspector.identifier", "Identifier"), value: record.sourceIdentifier ?? "—"),
                                .init(id: record.id + "-version", label: t("inspector.version", "Version"), value: record.version ?? "—"),
                                .init(id: record.id + "-confidence", label: t("capability.confidence", "Confidence"), value: confidenceLabel(record.confidence)),
                                .init(id: record.id + "-modified", label: t("inspector.change", "Change"), value: record.modified ? t("inspector.modified", "Modified") : t("inspector.unchanged", "Unchanged"))
                            ])
                        }
                    }
                    if resource.isSkillClassificationCorrectable {
                        Menu(t("capability.correctClassification", "Correct classification")) {
                            Button(t("capability.mySkill", "My Skill")) { onClassify?(.userOwned) }
                            Button(t("capability.installedSkill", "Installed Skill")) { onClassify?(.installed) }
                            Divider()
                            Button(t("capability.resetClassification", "Reset classification")) { onResetClassification?() }
                        }
                        .font(DirectorTypography.supporting)
                    }
                }

                section("inspector.relationships", "Relationships") {
                    CapabilityRelationshipsView(relations: relations)
                }

                section("inspector.operationalSignals", "Operational Signals") {
                    EvidenceInspector(items: [
                        .init(id: "observed", label: t("inspector.observed", "Observed"), value: usage.isObserved ? t("inspector.observedValue", "Observed in indexed history") : t("inspector.notObservedValue", "Not observed in indexed history")),
                        .init(id: "calls", label: t("capability.calls", "Calls"), value: "\(usage.callCount)"),
                        .init(id: "completed", label: t("inspector.completed", "Completed"), value: "\(usage.completedCount)"),
                        .init(id: "failures", label: t("inspector.failedInterrupted", "Failed / interrupted"), value: "\(usage.failureCount)"),
                        .init(id: "unresolved", label: t("inspector.unresolved", "Unresolved"), value: "\(usage.unresolvedCount)"),
                        .init(id: "limited", label: t("inspector.evidenceLimited", "Evidence-limited"), value: "\(usage.evidenceLimitedCount)"),
                        .init(id: "completion", label: t("inspector.observedCompletion", "Observed completion"), value: completionRateText),
                        .init(id: "last", label: t("inspector.lastUsed", "Last used"), value: lastUsedText),
                    ])
                }

                section("inspector.userEvaluation", "User Evaluation") {
                    EvidenceInspector(items: [
                        .init(id: "evaluated", label: t("inspector.evaluated", "Evaluated"), value: "\(usage.evaluatedCount)"),
                        .init(id: "effective", label: t("evaluation.effective", "Effective"), value: "\(usage.effectiveCount)"),
                        .init(id: "ineffective", label: t("evaluation.ineffective", "Ineffective"), value: "\(usage.ineffectiveCount)"),
                        .init(id: "uncertain", label: t("evaluation.uncertain", "Uncertain"), value: "\(usage.uncertainCount)"),
                    ])
                    Text(t("capability.evaluationNote", "These labels are local user judgments, separate from operational completion."))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                }

                section("nav.review", "Review") {
                    if findings.isEmpty {
                        Text(t("capability.noFindings", "No findings for this capability."))
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                    } else {
                        ForEach(findings) { finding in
                            Label(t("review.rule.\(finding.ruleID).summary", finding.summary), systemImage: "exclamationmark.triangle")
                                .font(DirectorTypography.supporting)
                                .foregroundStyle(DirectorColor.status(.warning))
                        }
                    }
                }

                section("inspector.evidence", "Evidence") {
                    EvidenceInspector(items: [
                        .init(id: "source-file", label: t("inspector.sourceFile", "Source file"), value: resource.relativeSourcePath ?? "—"),
                        .init(id: "arguments", label: t("Arguments", "Arguments"), value: t("not persisted", "not persisted"), redacted: true),
                        .init(id: "output", label: t("Output", "Output"), value: t("not persisted", "not persisted"), redacted: true),
                    ])
                }
            }
            .padding(DirectorSpacing.space4)
        }
        .frame(minWidth: 280, idealWidth: 340)
    }

    private var header: some View {
        HStack(spacing: DirectorSpacing.space3) {
            Image(systemName: DirectorSymbol.resource(resource.kind))
                .font(.title2)
                .foregroundStyle(DirectorColor.resource(resource.kind))
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(resource.name)
                    .font(DirectorTypography.sectionTitle)
                Text(kindLabel)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Label(t("capability.closeInspector", "Close Inspector"), systemImage: DirectorSymbol.closeInspector)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(t("capability.closeInspector", "Close Inspector"))
            .accessibilityLabel(t("capability.closeInspector", "Close Inspector"))
            .accessibilityHint(t("capability.closeHint", "Closes the selected capability inspector."))
            .accessibilityIdentifier(Self.closeButtonAccessibilityIdentifier)
            RuntimeStatusBadge(status: resource.status)
        }
    }

    private func section(_ key: String, _ fallback: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(t(key, fallback).uppercased())
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            content()
        }
    }

    private func t(_ key: String, _ fallback: String) -> String { languageStore.localizer.text(key, fallback: fallback) }
    private func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        languageStore.localizer.format(key, fallback: fallback, arguments: arguments)
    }
    private var kindLabel: String { languageStore.localizer.enumLabel(.init(key: "enum.\(resource.kind.rawValue)", fallback: resource.kind.rawValue.capitalized)) }
    private func scopeLabel(_ scope: ResourceScope) -> String { languageStore.localizer.enumLabel(.init(key: "enum.\(scope.rawValue)", fallback: scope.rawValue.capitalized)) }
    private var scopeLabel: String { scopeLabel(resource.scope) }
    private func ownershipLabel(_ ownership: ResourceOwnership) -> String { languageStore.localizer.enumLabel(.init(key: "enum.\(ownership.rawValue)", fallback: ownership.rawValue)) }
    private var ownershipLabel: String { ownershipLabel(resource.ownership) }
    private func originLabel(_ origin: ResourceOrigin) -> String { languageStore.localizer.enumLabel(.init(key: "enum.\(origin.rawValue)", fallback: origin.rawValue.capitalized)) }
    private var originLabel: String { originLabel(resource.origin) }
    private func confidenceLabel(_ confidence: EvidenceConfidence) -> String { DirectorSemanticStyle.confidenceLabel(confidence, localizer: languageStore.localizer) }
    private var classificationConfidenceLabel: String { confidenceLabel(resource.classificationConfidence) }

    private var confidenceNote: String {
        switch resource.confidence {
        case .exact: return t("inspector.confidenceNote.exact", "Recorded from a structured source.")
        case .inferred: return t("inspector.confidenceNote.inferred", "Derived from multiple signals; not an exact event.")
        case .unknown: return t("inspector.confidenceNote.unknown", "Evidence is insufficient to classify.")
        }
    }

    private var lastUsedText: String {
        guard let lastUsedAt = usage.lastUsedAt else { return t("common.notAvailable", "—") }
        return languageStore.localizer.date(lastUsedAt)
    }

    private var completionRateText: String {
        guard let rate = usage.observedCompletionRate else { return t("inspector.notEnoughTerminalOutcomes", "Not enough terminal outcomes") }
        return "\(Int((rate * 100).rounded()))%"
    }
}
