import SwiftUI
import DirectorCore

/// Coverage indicator. "No findings" is not "Healthy" unless coverage is
/// complete, so coverage is always visible.
public struct CoverageNotice: View {
    public let coverage: CoverageState
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(coverage: CoverageState) {
        self.coverage = coverage
    }

    public var body: some View {
        Label(localizedLabel, systemImage: symbol)
            .font(DirectorTypography.label)
            .foregroundStyle(foreground)
            .accessibilityLabel(languageStore.localizer.format("coverage.accessibility", fallback: "Coverage: %@", localizedLabel))
    }

    private var label: String {
        switch coverage {
        case .complete: return "Complete"
        case .partial: return "Partial"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }

    private var localizedLabel: String {
        languageStore.localizer.enumLabel(LocalizedEnumValue(key: "coverage.\(coverage.rawValue)", fallback: label))
    }

    private var symbol: String {
        switch coverage {
        case .complete: return "checkmark.circle"
        case .partial: return "exclamationmark.triangle"
        case .unavailable: return "xmark.octagon"
        case .unknown: return "questionmark.circle"
        }
    }

    private var foreground: Color {
        switch coverage {
        case .complete: return Color(nsColor: .systemGreen)
        case .partial: return Color(nsColor: .systemOrange)
        case .unavailable: return Color(nsColor: .systemRed)
        case .unknown: return DirectorColor.textSecondary
        }
    }
}
