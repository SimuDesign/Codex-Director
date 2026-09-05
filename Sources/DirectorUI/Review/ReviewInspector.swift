import SwiftUI
import DirectorCore

/// Inspector for one Review Lite finding: rule source, applicability,
/// evidence, coverage, confidence, related task/resource, remediation.
public struct ReviewInspector: View {
    public let finding: ReviewFinding
    public let rule: (name: String, applicability: String)?
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(finding: ReviewFinding, rule: (name: String, applicability: String)?) {
        self.finding = finding
        self.rule = rule
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                HStack(spacing: DirectorSpacing.space3) {
                    Image(systemName: severitySymbol)
                        .foregroundStyle(severityColor)
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Text(localizedSummary)
                            .font(DirectorTypography.sectionTitle)
                        Text(finding.id)
                            .font(DirectorTypography.code)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                    Spacer()
                }

                section("Finding") {
                    EvidenceInspector(items: [
                        .init(id: "severity", label: text("Severity"), value: enumLabel(finding.severity, prefix: "review.severity.")),
                        .init(id: "confidence", label: text("Confidence"), value: enumLabel(finding.confidence, prefix: "confidence.")),
                        .init(id: "coverage", label: text("Coverage"), value: enumLabel(finding.coverage, prefix: "coverage.")),
                    ])
                }

                section("Rule") {
                    EvidenceInspector(items: [
                        .init(id: "id", label: text("Rule ID"), value: finding.ruleID),
                        .init(id: "name", label: text("Name"), value: rule.map { languageStore.localizer.text("review.rule.\(finding.ruleID).name", fallback: $0.name) } ?? "—"),
                        .init(id: "applies", label: text("Applies"), value: rule.map { languageStore.localizer.text("review.rule.\(finding.ruleID).applicability", fallback: $0.applicability) } ?? "—"),
                    ])
                }

                section("Evidence") {
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Text(text("Original evidence"))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSecondary)
                        Text(Self.originalEvidenceText(for: finding))
                            .font(DirectorTypography.body)
                            .textSelection(.enabled)
                    }
                }

                section("Related") {
                    EvidenceInspector(items: [
                        .init(id: "resource", label: text("Resource"), value: finding.resourceID ?? "—"),
                        .init(id: "session", label: text("Session"), value: finding.sessionID ?? "—"),
                        .init(id: "created", label: text("Created"), value: languageStore.localizer.date(finding.createdAt, style: Date.FormatStyle(date: .abbreviated, time: .shortened))),
                    ])
                }

                section("Remediation") {
                    Text(enumLabel(finding.remediationStatus, prefix: "remediation."))
                        .font(DirectorTypography.body)
                }
            }
            .padding(DirectorSpacing.space4)
        }
        .frame(minWidth: 300, idealWidth: 360)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(text(title).uppercased())
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            content()
        }
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    private func enumLabel<Value: RawRepresentable>(_ value: Value, prefix: String) -> String where Value.RawValue == String {
        languageStore.localizer.enumLabel(.init(key: prefix + value.rawValue, fallback: value.rawValue.capitalized))
    }

    private var localizedSummary: String {
        languageStore.localizer.text("review.rule.\(finding.ruleID).summary", fallback: finding.summary)
    }

    static func originalEvidenceText(for finding: ReviewFinding) -> String {
        finding.evidenceSummary
    }

    private var severitySymbol: String {
        switch finding.severity {
        case .error: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }

    private var severityColor: Color {
        switch finding.severity {
        case .error: return DirectorColor.status(.failure)
        case .warning: return DirectorColor.status(.warning)
        case .info: return DirectorColor.textSecondary
        }
    }
}
