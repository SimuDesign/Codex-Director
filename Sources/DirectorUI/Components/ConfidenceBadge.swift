import SwiftUI
import DirectorCore

/// Confidence indicator with symbol, label, and color — never color alone
/// (DESIGN_SYSTEM_V1 §3.4, §6.4).
public struct ConfidenceBadge: View {
    public let confidence: EvidenceConfidence
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(confidence: EvidenceConfidence) {
        self.confidence = confidence
    }

    public var body: some View {
        let label = DirectorSemanticStyle.confidenceLabel(confidence, localizer: languageStore.localizer)
        Label(
            label,
            systemImage: DirectorSemanticStyle.confidenceSymbol(confidence)
        )
        .font(DirectorTypography.label)
        .foregroundStyle(foreground)
        .accessibilityLabel(languageStore.localizer.format("confidence.accessibility", fallback: "Confidence: %@", label))
    }

    private var foreground: Color {
        switch confidence {
        case .exact: return Color(nsColor: .systemGreen)
        case .inferred: return Color(nsColor: .systemOrange)
        case .unknown: return DirectorColor.textSecondary
        }
    }
}
