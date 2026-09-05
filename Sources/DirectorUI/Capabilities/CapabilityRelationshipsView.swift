import SwiftUI
import DirectorCore

/// One-hop relationships for the selected capability, rendered as a
/// synchronized accessible list (a canvas is not required for accessibility).
public struct CapabilityRelationshipsView: View {
    public let relations: [ResourceRelation]
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(relations: [ResourceRelation]) {
        self.relations = relations
    }

    public var body: some View {
        if relations.isEmpty {
            Text(text("No relationships recorded."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                ForEach(relations) { relation in
                    HStack(spacing: DirectorSpacing.space2) {
                        Text(relation.sourceResourceID)
                        Image(systemName: "arrow.right")
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                        Text(relation.targetResourceID)
                        Spacer(minLength: DirectorSpacing.space3)
                        Text(relationLabel(relation.relationKind))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSecondary)
                        ConfidenceBadge(confidence: relation.confidence)
                    }
                    .font(DirectorTypography.code)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        languageStore.localizer.format(
                            "%@ %@ %@, confidence %@",
                            fallback: "%@ %@ %@, confidence %@",
                            relation.sourceResourceID,
                            relationLabel(relation.relationKind),
                            relation.targetResourceID,
                            confidenceLabel(relation.confidence)
                        )
                    )
                }
            }
        }
    }

    private func text(_ key: String) -> String {
        languageStore.localizer.text(key, fallback: key)
    }

    private func relationLabel(_ relationKind: String) -> String {
        let key: String
        switch relationKind {
        case "uses", "invokes", "contains": key = "relation.kind.\(relationKind)"
        default: return relationKind
        }
        return languageStore.localizer.text(key, fallback: relationKind.capitalized)
    }

    private func confidenceLabel(_ confidence: EvidenceConfidence) -> String {
        languageStore.localizer.enumLabel(.init(key: "confidence.\(confidence.rawValue)", fallback: confidence.rawValue.capitalized))
    }
}
