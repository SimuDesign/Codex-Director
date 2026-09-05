import SwiftUI
import DirectorCore

/// Runtime status with symbol, label, and color — never color alone
/// (DESIGN_SYSTEM_V1 §6.2, §11.4).
public struct RuntimeStatusBadge: View {
    public let status: RuntimeStatus
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(status: RuntimeStatus) {
        self.status = status
    }

    public var body: some View {
        let label = DirectorSemanticStyle.statusLabel(status, localizer: languageStore.localizer)
        Label(
            label,
            systemImage: DirectorSymbol.status(status)
        )
        .font(DirectorTypography.label)
        .foregroundStyle(DirectorColor.status(status))
        .accessibilityLabel(languageStore.localizer.format("status.accessibility", fallback: "Status: %@", label))
    }
}
