import SwiftUI
import DirectorCore

/// The single settings destination for 0.2. Index status and privacy remain
/// together so recovery and data-boundary explanations are discoverable.
public struct SettingsView: View {
    @ObservedObject private var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @EnvironmentObject private var themeStore: AppThemeStore
    @State private var confirmDelete = false
    @State private var operationError: String?
    @State private var showsCapabilityExport = false

    public init(model: DirectorAppModel) { _model = ObservedObject(wrappedValue: model) }

    public var body: some View {
        DirectorEditorialFrame {
            GeometryReader { viewport in
                ScrollView {
                    DirectorPageContentFrame(workspaceWidth: viewport.size.width) {
                        VStack(alignment: .leading, spacing: 0) {
                            DirectorEditorialHero(
                                eyebrow: nil,
                                title: t("nav.settings", "Settings"),
                                titleAccent: nil,
                                subtitle: nil,
                                symbolName: DirectorSymbol.settings,
                                tone: .blue,
                                compact: viewport.size.width < DirectorPageLayout.compactBreakpoint
                            )

                            section(ordinal: "01", titleKey: "settings.languageAppearance", fallback: "Language & appearance", tone: .blue) {
                                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                                    LabeledContent(t("settings.language", "Language")) {
                                        languagePicker
                                    }
                                    LabeledContent(t("settings.appearance", "Theme")) {
                                        themePicker
                                    }
                                    Toggle(
                                        t("settings.menuBar", "Show in menu bar"),
                                        isOn: Binding(
                                            get: { model.menuBarEnabled },
                                            set: { model.setMenuBarEnabled($0) }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .accessibilityHint(t("settings.menuBar.hint", "Show a privacy-safe weekly quota summary in the macOS menu bar."))
                                }
                            }
                            section(ordinal: "02", titleKey: "settings.index.title", fallback: "Index", tone: .ice) {
                                labeledRow(t("settings.index.status", "Status"), indexStatus)
                                if model.backgroundRefreshError != nil {
                                    Text(t("settings.index.backgroundError", "Background update failed; showing the last available data."))
                                        .font(DirectorTypography.supporting)
                                        .foregroundStyle(DirectorColor.status(.failure))
                                }
                                if model.indexingProgress.totalFiles > 0 {
                                    ProgressView(value: Double(model.indexingProgress.processedFiles), total: Double(model.indexingProgress.totalFiles))
                                    labeledRow(t("settings.index.files", "Files"), "\(model.indexingProgress.processedFiles)/\(model.indexingProgress.totalFiles)")
                                }
                                if model.indexingError != nil {
                                    VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                                        Text(t("settings.index.errorHeading", "Indexing failed"))
                                            .font(DirectorTypography.supporting)
                                            .foregroundStyle(DirectorColor.status(.failure))
                                        Text(t("settings.index.retryHint", "Retry the update from this screen when the data source is available again."))
                                            .font(DirectorTypography.supporting)
                                    }
                                }
                                if let date = model.lastIndexCompletedAt {
                                    labeledRow(t("settings.index.lastIndexed", "Last indexed"), languageStore.localizer.date(date))
                                } else {
                                    labeledRow(t("settings.index.lastIndexed", "Last indexed"), t("settings.index.notAvailable", "Not available"))
                                }
                                labeledRow(t("settings.index.lastSourceCheck", "Last source check"), model.sourceDataLastCheckedAt.map { languageStore.localizer.date($0) } ?? t("settings.index.notAvailable", "Not available"))
                                labeledRow(t("settings.index.statisticsThrough", "Statistics through"), model.statisticsWindow.map { languageStore.localizer.date($0.end) } ?? t("settings.index.notAvailable", "Not available"))
                                if let schedule = model.refreshScheduleState {
                                    if let retry = schedule.sourceRetryDate {
                                        labeledRow(t("settings.index.sourceRetry", "Source retry"), languageStore.localizer.date(retry))
                                    }
                                    if let retry = schedule.projectionRetryDate {
                                        labeledRow(t("settings.index.projectionRetry", "Statistics retry"), languageStore.localizer.date(retry))
                                    }
                                }
                                HStack(spacing: DirectorSpacing.space3) {
                                    DirectorRefreshButton(
                                        label: t("settings.updateNow", "Update now"),
                                        runningLabel: t("home.refresh.running", "Refreshing…"),
                                        hint: t("home.refresh.hint", "Refresh capabilities, quota and recent usage data."),
                                        isRefreshing: model.isRefreshing,
                                        isAvailable: model.coordinator != nil && model.configuration != nil,
                                        size: .settings,
                                        action: { Task { await model.startIndexing() } }
                                    )
                                    Button(t("settings.delete", "Delete derived index"), role: .destructive) { confirmDelete = true }
                                        .buttonStyle(DirectorSecondaryActionButtonStyle(size: .settings, destructive: true))
                                        .disabled(model.isIndexing || model.store == nil)
                                }
                            }
                            section(ordinal: "03", titleKey: "settings.migration.title", fallback: "Capability migration", tone: .teal) {
                                Text(t("settings.migration.body", "Create an open ZIP package containing selected Agents, Skills and instructions. Plugins and external requirements are recorded as lists only."))
                                    .font(DirectorTypography.body)
                                Text(t("settings.migration.localWarning", "The package is an unencrypted local file. Source capability files are never modified, and the package is written only to the location you choose."))
                                    .font(DirectorTypography.supporting)
                                    .foregroundStyle(DirectorColor.textSecondary)
                                Button(t("settings.migration.export", "Export capability package")) {
                                    showsCapabilityExport = true
                                }
                                .buttonStyle(DirectorPrimaryActionButtonStyle(size: .settings))
                                .disabled(model.capabilityExportCoordinator == nil || model.isCapabilityExporting)
                                .accessibilityHint(t("settings.migration.exportHint", "Choose content, run a safety preflight, then save a local ZIP package."))
                            }
                            section(ordinal: "04", titleKey: "settings.privacy.title", fallback: "Privacy", tone: .mint) {
                                Text(t("settings.privacy.body", "Codex Director runs locally. It reads resources and session logs read-only; prompts, responses, arguments, and output text are not stored."))
                                    .font(DirectorTypography.body)
                                Text(t("settings.privacy.sourceBoundary", "Source resources and session files are never modified. Capability exports are unencrypted local files written only to a location you choose. Deleting derived data preserves evaluations and classification corrections."))
                                    .font(DirectorTypography.supporting)
                                    .foregroundStyle(DirectorColor.textSecondary)
                            }
                            section(ordinal: "05", titleKey: "settings.diagnostics.title", fallback: "Diagnostics", tone: .teal) {
                                labeledRow(t("settings.diagnostics.parser", "Parser version"), RolloutEventDecoder.parserVersion)
                                if model.diagnosticsLoading {
                                    ProgressView(t("settings.diagnostics.loading", "Loading diagnostics…")).controlSize(.small)
                                } else if let diagnostics = model.presentationDiagnostics {
                                    labeledRow(t("settings.diagnostics.coverage", "Coverage notices"), "\(diagnostics.parserCoverageFindingCount)")
                                    labeledRow(t("settings.diagnostics.sessions", "Indexed sessions"), "\(diagnostics.sessionCount)")
                                    labeledRow(t("settings.diagnostics.partial", "Partial sessions"), "\(diagnostics.partialCoverageSessionCount)")
                                } else {
                                    labeledRow(t("settings.diagnostics.coverage", "Coverage notices"), "—")
                                }
                                if model.diagnosticsError != nil {
                                    Text(t("settings.diagnostics.failed", "Diagnostics are unavailable."))
                                        .font(DirectorTypography.supporting)
                                        .foregroundStyle(DirectorColor.status(.failure))
                                }
                                Text(t("settings.diagnostics.limitations", "Missing timestamps and unresolved capabilities are excluded from precise recent capability rankings; unassociated projects remain in overall totals but not project-specific views."))
                                    .font(DirectorTypography.supporting)
                                    .foregroundStyle(DirectorColor.textSecondary)
                            }
                            section(ordinal: "06", titleKey: "settings.about.title", fallback: "About", tone: .blue) {
                                labeledRow(t("settings.author", "Author"), "七木 Simu")
                                labeledRow(t("settings.version", "Version"), appVersion)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .confirmationDialog(t("settings.delete.confirmTitle", "Delete derived index?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(t("settings.delete", "Delete derived index"), role: .destructive) { Task { do { try await model.deleteDerivedData() } catch { operationError = "settings.delete.failed" } } }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("settings.delete.confirmBody", "Only the derived index is removed. Original resources and session files remain unchanged."))
        }
        .alert(t("settings.operationError", "Operation failed"), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) { Button(t("common.cancel", "Cancel"), role: .cancel) {} } message: { Text(t(operationError ?? "settings.operationError", "Unable to complete this operation.")) }
        .sheet(isPresented: $showsCapabilityExport) {
            CapabilityExportSheet(model: model)
                .environmentObject(languageStore)
        }
        .task { await model.loadDiagnosticsIfNeeded() }
    }

    private var languagePicker: some View {
        Picker(t("settings.language.accessibilityLabel", "Language"), selection: Binding(get: { languageStore.language }, set: { languageStore.setLanguage($0) })) {
            Text("简体中文").tag(AppLanguage.simplifiedChinese)
            Text("English").tag(AppLanguage.english)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityValue(languageStore.language.pickerTitle)
    }

    private var themePicker: some View {
        Picker(t("settings.appearance", "Theme"), selection: Binding(get: { themeStore.theme }, set: { themeStore.setTheme($0) })) {
            Text(t("settings.appearance.light", "Light")).tag(AppTheme.light)
            Text(t("settings.appearance.dark", "Dark")).tag(AppTheme.dark)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityValue(themeStore.theme == .light ? t("settings.appearance.light", "Light") : t("settings.appearance.dark", "Dark"))
    }

    private var indexStatus: String {
        switch model.presentationState {
        case .initial: return t("settings.index.notIndexed", "Not indexed")
        case .indexing: return t("settings.index.running", "Indexing…")
        case .failure: return t("settings.index.errorHeading", "Indexing failed")
        case .empty: return t("settings.index.empty", "No indexed data")
        case .loaded: return model.sourceDataFresh ? t("settings.index.ready", "Ready") : t("settings.index.stale", "Needs update")
        case .preview: return t("settings.index.preview", "Preview data")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "1.0.0"
    }

    private func section<Content: View>(ordinal: String, titleKey: String, fallback: String, tone: DirectorAccentTone, @ViewBuilder content: () -> Content) -> some View {
        DirectorSectionBand(ordinal: ordinal, title: t(titleKey, fallback), tone: tone) {
            content()
        }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(DirectorColor.textSecondary) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private func t(_ key: String, _ fallback: String) -> String { languageStore.localizer.text(key, fallback: fallback) }
}
