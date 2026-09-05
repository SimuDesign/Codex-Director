import SwiftUI
import DirectorCore

/// Inspector for a selected invocation. Raw payloads stay collapsed and
/// redacted.
public struct InvocationInspector: View {
    public let event: InvocationEvent
    public let evaluation: InvocationEvaluation?
    public let onEvaluate: ((InvocationEvaluationLabel) -> Void)?
    public let onClearEvaluation: (() -> Void)?
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(
        event: InvocationEvent,
        evaluation: InvocationEvaluation? = nil,
        onEvaluate: ((InvocationEvaluationLabel) -> Void)? = nil,
        onClearEvaluation: (() -> Void)? = nil
    ) {
        self.event = event
        self.evaluation = evaluation
        self.onEvaluate = onEvaluate
        self.onClearEvaluation = onClearEvaluation
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                HStack(spacing: DirectorSpacing.space3) {
                    Image(systemName: DirectorSymbol.resource(resourceKind))
                        .foregroundStyle(DirectorColor.resource(resourceKind))
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Text(event.resourceID ?? enumLabel(event.kind, fallback: event.kind.rawValue.capitalized))
                            .font(DirectorTypography.sectionTitle)
                            .textSelection(.enabled)
                        Text(event.id)
                            .font(DirectorTypography.code)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                    Spacer()
                }

                section("Identity") {
                    EvidenceInspector(items: [
                        .init(id: "id", label: text("ID"), value: event.id),
                        .init(id: "kind", label: text("Kind"), value: enumLabel(event.kind, fallback: event.kind.rawValue.capitalized)),
                        .init(id: "status", label: text("Status"), value: enumLabel(event.status, fallback: event.status.rawValue.capitalized)),
                        .init(id: "parent", label: text("Parent call"), value: event.parentCallID ?? "—"),
                    ])
                }

                section("Timing") {
                    EvidenceInspector(items: [
                        .init(id: "at", label: text("Timestamp"), value: event.timestamp.map { languageStore.localizer.date($0, style: Date.FormatStyle(date: .abbreviated, time: .shortened)) } ?? "—"),
                        .init(id: "duration", label: text("Duration"), value: event.durationMs.map(durationText) ?? "—"),
                        .init(id: "ordinal", label: text("Ordinal"), value: "\(event.ordinal)"),
                    ])
                }

                section("Outcome") {
                    EvidenceInspector(items: [
                        .init(id: "error", label: text("Error category"), value: event.errorCategory ?? "—"),
                        .init(id: "confidence", label: text("Evidence confidence"), value: enumLabel(event.confidence, fallback: event.confidence.rawValue.capitalized)),
                    ])
                }

                if supportsEvaluation {
                    section("Evaluation") {
                        Text(text("Local user judgment; separate from operational completion."))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSecondary)
                        // Evaluation controls must remain usable in the narrow
                        // compact inspector. An adaptive grid wraps labels
                        // instead of allowing a horizontal control row to clip.
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 128), alignment: .leading)
                            ],
                            alignment: .leading,
                            spacing: DirectorSpacing.space2
                        ) {
                            ForEach(InvocationEvaluationLabel.allCases, id: \.self) { label in
                                Button {
                                    if let onEvaluate {
                                        onEvaluate(label)
                                    }
                                } label: {
                                    HStack(spacing: DirectorSpacing.space1) {
                                        if evaluation?.label == label {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(DirectorColor.status(.success))
                                        }
                                        Text(enumLabel(label, fallback: label.rawValue.capitalized))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(enumLabel(label, fallback: label.rawValue.capitalized))
                                .accessibilityValue(evaluation?.label == label ? text("Selected") : text("Not selected"))
                                .accessibilityHint(text("Records this as a local user judgment for the invocation."))
                            }
                        }
                        if evaluation != nil {
                            Button(text("Clear")) {
                                onClearEvaluation?()
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(text("Clear evaluation"))
                            .accessibilityHint(text("Removes the local evaluation label."))
                        }
                    }
                }

                section("Evidence") {
                    EvidenceInspector(items: [
                        .init(id: "arguments", label: text("Arguments"), value: text("not persisted"), redacted: true),
                        .init(id: "output", label: text("Output"), value: text("not persisted"), redacted: true),
                    ])
                }
            }
            .padding(DirectorSpacing.space4)
        }
        .frame(idealWidth: 340, maxWidth: .infinity)
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

    private func enumLabel<Value: RawRepresentable>(_ value: Value, fallback: String) -> String where Value.RawValue == String {
        let prefix: String
        switch value {
        case is InvocationKind: prefix = "invocation.kind."
        case is InvocationStatus: prefix = "status."
        case is EvidenceConfidence: prefix = "confidence."
        case is InvocationEvaluationLabel: prefix = "evaluation."
        default: prefix = "enum."
        }
        return languageStore.localizer.enumLabel(.init(key: prefix + value.rawValue, fallback: fallback))
    }

    private func durationText(_ durationMs: Int) -> String {
        if durationMs >= 60_000 {
            return languageStore.localizer.format("%.1f min", fallback: "%.1f min", Double(durationMs) / 60_000)
        }
        if durationMs >= 1_000 {
            return languageStore.localizer.format("%.1f s", fallback: "%.1f s", Double(durationMs) / 1_000)
        }
        return languageStore.localizer.format("%lld ms", fallback: "%lld ms", durationMs)
    }

    private var resourceKind: ResourceKind {
        switch event.kind {
        case .agent: return .agent
        case .skill: return .skill
        case .orchestration: return .workflow
        case .workflow: return .workflow
        case .review: return .output
        case .handoff: return .output
        case .tool: return .tool
        case .compaction, .interruption, .unknown: return .unknown
        }
    }

    private var supportsEvaluation: Bool {
        (event.kind == .agent || event.kind == .skill) && event.resourceID != nil
    }

}
