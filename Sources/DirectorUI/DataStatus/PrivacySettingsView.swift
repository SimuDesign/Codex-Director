import SwiftUI

/// Privacy settings: explains what is stored, what is redacted, and what
/// never leaves this Mac. No account creation, cloud sync, or telemetry.
public struct PrivacySettingsView: View {
    @EnvironmentObject private var languageStore: AppLanguageStore

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space6) {
                languagePicker

                Text(languageStore.localizer.text("privacy.title", fallback: "Privacy"))
                    .font(DirectorTypography.windowTitle)

                section(languageStore.localizer.text("privacy.stored.title", fallback: "Stored")) {
                    Text(languageStore.localizer.text("privacy.stored.body", fallback: "Only normalized metadata is stored in the local derived index: capability identities, session summaries, invocation order and outcome, aggregate token totals, and reported allowance windows."))
                        .font(DirectorTypography.body)
                }

                section(languageStore.localizer.text("privacy.neverStored.title", fallback: "Never stored")) {
                    Text(languageStore.localizer.text("privacy.neverStored.body", fallback: "Prompts, responses, tool arguments, tool output, raw shell commands, credentials, cookies, tokens, and unredacted absolute paths are never stored, logged, or exported."))
                        .font(DirectorTypography.body)
                }

                section(languageStore.localizer.text("privacy.paths.title", fallback: "Paths")) {
                    Text(languageStore.localizer.text("privacy.paths.body", fallback: "Source paths are stored as root identifiers plus relative paths. Absolute paths and usernames are redacted on every surface, including accessibility labels and error descriptions."))
                        .font(DirectorTypography.body)
                }

                section(languageStore.localizer.text("privacy.previews.title", fallback: "Previews and screenshots")) {
                    Text(languageStore.localizer.text("privacy.previews.body", fallback: "All previews, fixtures, and screenshots use synthetic data only."))
                        .font(DirectorTypography.body)
                }

                section(languageStore.localizer.text("privacy.network.title", fallback: "Network")) {
                    Text(languageStore.localizer.text("privacy.network.body", fallback: "Codex Director is local-only. It performs no uploads, telemetry, or cloud synchronization."))
                        .font(DirectorTypography.body)
                }
            }
            .padding(DirectorSpacing.space5)
        }
        .accessibilityLabel(languageStore.localizer.text("privacy.accessibilityLabel", fallback: "Privacy settings"))
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text("语言 / Language")
                .font(DirectorTypography.sectionTitle)
            Picker("语言 / Language", selection: Binding(
                get: { languageStore.language },
                set: { languageStore.setLanguage($0) }
            )) {
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(languageStore.localizer.text("language.settings.description", fallback: "Choose the language used by Codex Director."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(title.uppercased())
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            content()
        }
    }
}
