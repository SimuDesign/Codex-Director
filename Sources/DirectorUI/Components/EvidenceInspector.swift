import SwiftUI

/// Collapsed evidence list. Redacted values are always marked; nothing here
/// exposes prompts, arguments, outputs, or unredacted paths.
public struct EvidenceInspector: View {
    public struct EvidenceItem: Identifiable {
        public let id: String
        public let label: String
        public let value: String
        public let redacted: Bool

        public init(id: String, label: String, value: String, redacted: Bool = false) {
            self.id = id
            self.label = label
            self.value = value
            self.redacted = redacted
        }
    }

    public let items: [EvidenceItem]
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init(items: [EvidenceItem]) {
        self.items = items
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space2) {
                    Text(item.label)
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    if item.redacted {
                        Image(systemName: "lock.fill")
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                            .accessibilityLabel(languageStore.localizer.text("Redacted", fallback: "Redacted"))
                    }
                    Text(item.value)
                        .font(DirectorTypography.code)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
