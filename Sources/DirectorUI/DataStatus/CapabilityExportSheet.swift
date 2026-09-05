import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DirectorCore

struct CapabilityExportSheet: View {
    private enum Stage: Equatable {
        case loading
        case selection
        case preflighting
        case review
        case saving
        case success
        case failure
    }

    @ObservedObject var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var stage: Stage = .loading
    @State private var options: CapabilityExportOptions?
    @State private var selection = CapabilityExportSelection()
    @State private var preview: CapabilityExportPreview?
    @State private var savedURL: URL?
    @State private var failureKey = "settings.migration.error.generic"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 420, idealHeight: 620)
        .background(DirectorColor.canvas)
        .interactiveDismissDisabled(model.isCapabilityExporting)
        .task { await loadOptions() }
        .onDisappear {
            if model.isCapabilityExporting { model.cancelCapabilityExport() }
            model.discardPreparedCapabilityExport()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DirectorSpacing.space3) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DirectorColor.accent(.teal))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(t("settings.migration.sheet.title", "Export capability package"))
                    .font(DirectorTypography.sectionTitle)
                Text(stageLabel)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Spacer()
            Button {
                if model.isCapabilityExporting { model.cancelCapabilityExport() }
                dismiss()
            } label: {
                Image(systemName: DirectorSymbol.closeInspector)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.isCapabilityExporting)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(t("common.close", "Close"))
        }
        .padding(.horizontal, DirectorSpacing.space5)
        .padding(.vertical, DirectorSpacing.space4)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .loading:
            progressContent(title: t("settings.migration.loading", "Loading exportable capabilities…"))
        case .selection:
            selectionContent
        case .preflighting:
            progressContent(title: t("settings.migration.preflighting", "Checking files and privacy…"))
        case .review:
            reviewContent
        case .saving:
            progressContent(title: t("settings.migration.saving", "Creating and verifying the package…"))
        case .success:
            successContent
        case .failure:
            failureContent
        }
    }

    private var selectionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                callout(
                    symbol: "lock.open",
                    title: t("settings.migration.unencryptedTitle", "Local and unencrypted"),
                    body: t("settings.migration.unencryptedBody", "Text files are checked for credentials and local paths. Binary files are included and hashed, but not content-scanned. Nothing is uploaded.")
                )
                if let options {
                    capabilityGroup(
                        title: t("settings.migration.global", "Global capabilities"),
                        subtitle: t("settings.migration.globalDefault", "Selected by default"),
                        capabilities: options.globalCapabilities,
                        projectID: nil
                    )

                    VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                        Text(t("settings.migration.projects", "Projects"))
                            .font(DirectorTypography.sectionTitle)
                        Text(t("settings.migration.projectsDefault", "Projects are not selected by default. Include only the projects you want to migrate."))
                            .font(DirectorTypography.supporting)
                            .foregroundStyle(DirectorColor.textSecondary)
                        if options.projects.isEmpty {
                            Text(t("settings.migration.noProjects", "No configured project capabilities were found."))
                                .font(DirectorTypography.supporting)
                        } else {
                            ForEach(options.projects) { project in
                                projectGroup(project)
                            }
                        }
                    }
                }
            }
            .padding(DirectorSpacing.space5)
        }
    }

    private func capabilityGroup(
        title: String,
        subtitle: String,
        capabilities: [CapabilityExportCapabilityOption],
        projectID: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            HStack {
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    Text(title).font(DirectorTypography.sectionTitle)
                    Text(subtitle).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
                }
                Spacer()
                Text("\(capabilities.filter { capabilityIsSelected($0) }.count)/\(capabilities.count)")
                    .font(DirectorTypography.label.monospacedDigit())
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            if projectID == nil {
                HStack(spacing: DirectorSpacing.space4) {
                    Toggle(t("settings.migration.agents", "Agents"), isOn: $selection.includeGlobalAgents)
                    Toggle(t("settings.migration.skills", "Skills"), isOn: $selection.includeGlobalSkills)
                    Toggle(t("settings.migration.instructions", "Instructions"), isOn: $selection.includeGlobalInstructions)
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            ForEach(capabilities) { capability in
                Toggle(isOn: capabilityBinding(capability)) {
                    HStack {
                        Image(systemName: symbol(for: capability.kind))
                            .foregroundStyle(DirectorColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(capability.name).font(DirectorTypography.supporting)
                        Spacer()
                        Text(kindLabel(capability.kind))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textSecondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!capabilityKindEnabled(capability))
            }
        }
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(panelBoundaryColor, lineWidth: panelBoundaryWidth)
                .accessibilityHidden(true)
        }
    }

    private func projectGroup(_ project: CapabilityExportProjectOption) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                HStack(spacing: DirectorSpacing.space4) {
                    Toggle(t("settings.migration.agents", "Agents"), isOn: projectKindBinding(project.id, kind: "agent"))
                    Toggle(t("settings.migration.skills", "Skills"), isOn: projectKindBinding(project.id, kind: "skill"))
                    Toggle(t("settings.migration.instructions", "Instructions"), isOn: projectKindBinding(project.id, kind: "instruction"))
                }
                .toggleStyle(.checkbox)
                ForEach(project.capabilities) { capability in
                    Toggle(isOn: capabilityBinding(capability)) {
                        HStack {
                            Text(capability.name).font(DirectorTypography.supporting)
                            Spacer()
                            Text(kindLabel(capability.kind)).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!capabilityKindEnabled(capability))
                }
            }
            .padding(.top, DirectorSpacing.space3)
        } label: {
            Toggle(isOn: projectBinding(project)) {
                HStack {
                    Text(project.name).font(DirectorTypography.supporting.weight(.semibold))
                    Spacer()
                    Text("\(project.capabilities.filter { capabilityIsSelected($0) }.count)/\(project.capabilities.count)")
                        .font(DirectorTypography.label.monospacedDigit())
                        .foregroundStyle(DirectorColor.textSecondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(panelBoundaryColor, lineWidth: panelBoundaryWidth)
                .accessibilityHidden(true)
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                if let preview {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DirectorSpacing.space3)], spacing: DirectorSpacing.space3) {
                        summaryMetric(t("settings.migration.capabilities", "Capabilities"), "\(preview.capabilityCount)")
                        summaryMetric(t("settings.migration.files", "Files"), "\(preview.fileCount)")
                        summaryMetric(t("settings.migration.size", "Size"), ByteCountFormatter.string(fromByteCount: preview.byteSize, countStyle: .file))
                        summaryMetric(t("settings.migration.plugins", "Plugins listed"), preview.pluginStatus == .complete ? "\(preview.pluginCount)" : t("settings.migration.incomplete", "Incomplete"))
                    }

                    if preview.issues.isEmpty {
                        callout(
                            symbol: "checkmark.circle",
                            title: t("settings.migration.ready", "Ready to export"),
                            body: t("settings.migration.readyBody", "The package can be created. It will be reopened and every checksum verified before it is moved to your chosen location."),
                            status: .success
                        )
                    } else {
                        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                            Text(t("settings.migration.issues", "Preflight issues"))
                                .font(DirectorTypography.sectionTitle)
                            ForEach(preview.issues) { issue in
                                HStack(alignment: .top, spacing: DirectorSpacing.space3) {
                                    Image(systemName: issue.severity == .blocking ? "hand.raised" : "exclamationmark.triangle")
                                        .foregroundStyle(DirectorColor.status(issue.severity == .blocking ? .blocked : .warning))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                        Text(issueText(issue)).font(DirectorTypography.supporting)
                                        if let path = issue.relativePath {
                                            Text(path).font(DirectorTypography.label.monospaced()).foregroundStyle(DirectorColor.textSecondary)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .padding(DirectorSpacing.space5)
        }
    }

    private func progressContent(title: String) -> some View {
        VStack(spacing: DirectorSpacing.space4) {
            ProgressView()
                .controlSize(.large)
            Text(title).font(DirectorTypography.sectionTitle)
            if let progress = model.capabilityExportProgress, progress.completedItems > 0 {
                Text(t("settings.migration.processed", "%lld items checked", Int64(progress.completedItems)))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Text(t("settings.migration.sourceUntouched", "Source Agent, Skill and instruction files remain untouched."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DirectorSpacing.space6)
        .accessibilityElement(children: .combine)
    }

    private var successContent: some View {
        VStack(spacing: DirectorSpacing.space4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(DirectorColor.status(.success))
                .accessibilityHidden(true)
            Text(t("settings.migration.success", "Capability package created"))
                .font(DirectorTypography.sectionTitle)
            Text(savedURL?.lastPathComponent ?? "")
                .font(DirectorTypography.supporting.monospaced())
                .textSelection(.enabled)
            Text(t("settings.migration.successBody", "The ZIP was reopened and all recorded SHA-256 hashes were verified. Keep this unencrypted file in a trusted location."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DirectorSpacing.space6)
    }

    private var failureContent: some View {
        VStack(spacing: DirectorSpacing.space4) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 38))
                .foregroundStyle(DirectorColor.status(.failure))
                .accessibilityHidden(true)
            Text(t("settings.migration.failed", "Export could not be completed"))
                .font(DirectorTypography.sectionTitle)
            Text(t(failureKey, "No package was left at the selected location. Return to selection and try again."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DirectorSpacing.space6)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DirectorSpacing.space3) {
            switch stage {
            case .loading:
                Spacer()
                Button(t("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(DirectorSecondaryActionButtonStyle())
            case .selection:
                Button(t("common.cancel", "Cancel")) { dismiss() }
                    .buttonStyle(DirectorSecondaryActionButtonStyle())
                Spacer()
                Button(t("settings.migration.runPreflight", "Run preflight")) { runPreflight() }
                    .buttonStyle(DirectorPrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasAnySelection)
            case .preflighting, .saving:
                Spacer()
                Button(t("common.cancel", "Cancel")) { model.cancelCapabilityExport() }
                    .buttonStyle(DirectorSecondaryActionButtonStyle())
            case .review:
                Button(t("common.back", "Back")) {
                    model.discardPreparedCapabilityExport()
                    preview = nil
                    stage = .selection
                }
                .buttonStyle(DirectorSecondaryActionButtonStyle())
                Spacer()
                if preview?.hasBlockingIssues == true {
                    Button(t("settings.migration.excludeBlocked", "Exclude blocked capabilities")) { excludeBlockedAndRetry() }
                        .buttonStyle(DirectorPrimaryActionButtonStyle())
                        .disabled(blockedCapabilityIDs.isEmpty)
                } else {
                    Button(t("settings.migration.chooseLocation", "Choose save location…")) { chooseLocationAndSave() }
                        .buttonStyle(DirectorPrimaryActionButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            case .success:
                if let savedURL {
                    Button(t("settings.migration.showInFinder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                    .buttonStyle(DirectorSecondaryActionButtonStyle())
                }
                Spacer()
                Button(t("common.done", "Done")) { dismiss() }
                    .buttonStyle(DirectorPrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .failure:
                Spacer()
                Button(t("settings.migration.returnToSelection", "Return to selection")) {
                    model.discardPreparedCapabilityExport()
                    stage = .selection
                }
                .buttonStyle(DirectorPrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DirectorSpacing.space5)
        .padding(.vertical, DirectorSpacing.space4)
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(label).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
            Text(value).font(DirectorTypography.sectionTitle).foregroundStyle(DirectorColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
    }

    private func callout(
        symbol: String,
        title: String,
        body: String,
        status: RuntimeStatus = .warning
    ) -> some View {
        HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            Image(systemName: symbol)
                .foregroundStyle(DirectorColor.status(status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(title).font(DirectorTypography.supporting.weight(.semibold))
                Text(body).font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary)
            }
        }
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(panelBoundaryColor, lineWidth: panelBoundaryWidth)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadOptions() async {
        do {
            let loaded = try await model.loadCapabilityExportOptions()
            options = loaded
            selection = .defaults(for: loaded)
            stage = .selection
        } catch {
            failureKey = "settings.migration.error.unavailable"
            stage = .failure
        }
    }

    private func runPreflight() {
        stage = .preflighting
        preview = nil
        Task {
            do {
                preview = try await model.prepareCapabilityExport(selection: selection)
                stage = .review
            } catch let error as CapabilityExportError where error == .cancelled {
                model.discardPreparedCapabilityExport()
                stage = .selection
            } catch {
                failureKey = "settings.migration.error.preflight"
                stage = .failure
            }
        }
    }

    private func excludeBlockedAndRetry() {
        selection.excludedCapabilityIDs.formUnion(blockedCapabilityIDs)
        model.discardPreparedCapabilityExport()
        runPreflight()
    }

    private func chooseLocationAndSave() {
        let panel = NSSavePanel()
        panel.title = t("settings.migration.savePanelTitle", "Save capability package")
        panel.nameFieldStringValue = CapabilityExportCoordinator.suggestedFileName()
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = normalizedPackageURL(url)
        stage = .saving
        Task {
            do {
                savedURL = try await model.savePreparedCapabilityExport(to: destination)
                stage = .success
            } catch let error as CapabilityExportError where error == .cancelled {
                model.discardPreparedCapabilityExport()
                stage = .selection
            } catch {
                failureKey = "settings.migration.error.save"
                stage = .failure
            }
        }
    }

    private func normalizedPackageURL(_ url: URL) -> URL {
        if url.lastPathComponent.hasSuffix(".codexpack.zip") { return url }
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).codexpack.zip")
    }

    private var blockedCapabilityIDs: Set<String> {
        Set(preview?.issues.filter { $0.severity == .blocking }.compactMap(\.capabilityID) ?? [])
    }

    private var hasAnySelection: Bool {
        guard let options else { return false }
        return options.globalCapabilities.contains(where: capabilityIsSelected)
            || options.projects.flatMap(\.capabilities).contains(where: capabilityIsSelected)
    }

    private func capabilityBinding(_ capability: CapabilityExportCapabilityOption) -> Binding<Bool> {
        Binding(
            get: { capabilityIsSelected(capability) },
            set: { isOn in
                if isOn { selection.excludedCapabilityIDs.remove(capability.id) }
                else { selection.excludedCapabilityIDs.insert(capability.id) }
            }
        )
    }

    private func capabilityIsSelected(_ capability: CapabilityExportCapabilityOption) -> Bool {
        capabilityKindEnabled(capability) && !selection.excludedCapabilityIDs.contains(capability.id)
    }

    private func capabilityKindEnabled(_ capability: CapabilityExportCapabilityOption) -> Bool {
        if capability.projectID == nil {
            switch capability.kind {
            case "agent": return selection.includeGlobalAgents
            case "skill": return selection.includeGlobalSkills
            case "instruction": return selection.includeGlobalInstructions
            default: return false
            }
        }
        guard let projectID = capability.projectID,
              let project = selection.projects.first(where: { $0.projectID == projectID }) else { return false }
        switch capability.kind {
        case "agent": return project.includeAgents
        case "skill": return project.includeSkills
        case "instruction": return project.includeInstructions
        default: return false
        }
    }

    private func projectBinding(_ project: CapabilityExportProjectOption) -> Binding<Bool> {
        Binding(
            get: { selection.projects.first(where: { $0.projectID == project.id })?.isIncluded == true },
            set: { isOn in
                updateProject(project.id) { value in
                    value.includeAgents = isOn && project.capabilities.contains { $0.kind == "agent" }
                    value.includeSkills = isOn && project.capabilities.contains { $0.kind == "skill" }
                    value.includeInstructions = isOn && project.capabilities.contains { $0.kind == "instruction" }
                }
            }
        )
    }

    private func projectKindBinding(_ projectID: String, kind: String) -> Binding<Bool> {
        Binding(
            get: {
                guard let value = selection.projects.first(where: { $0.projectID == projectID }) else { return false }
                switch kind {
                case "agent": return value.includeAgents
                case "skill": return value.includeSkills
                case "instruction": return value.includeInstructions
                default: return false
                }
            },
            set: { isOn in
                updateProject(projectID) { value in
                    switch kind {
                    case "agent": value.includeAgents = isOn
                    case "skill": value.includeSkills = isOn
                    case "instruction": value.includeInstructions = isOn
                    default: break
                    }
                }
            }
        )
    }

    private func updateProject(_ id: String, mutation: (inout CapabilityExportProjectSelection) -> Void) {
        guard let index = selection.projects.firstIndex(where: { $0.projectID == id }) else { return }
        mutation(&selection.projects[index])
    }

    private var stageLabel: String {
        switch stage {
        case .loading: return t("settings.migration.stage.loading", "Loading")
        case .selection: return t("settings.migration.stage.selection", "1 of 3 · Select content")
        case .preflighting: return t("settings.migration.stage.preflight", "2 of 3 · Preflight")
        case .review: return t("settings.migration.stage.review", "2 of 3 · Review")
        case .saving: return t("settings.migration.stage.saving", "3 of 3 · Save and verify")
        case .success: return t("settings.migration.stage.complete", "Complete")
        case .failure: return t("settings.migration.stage.failed", "Needs attention")
        }
    }

    private func issueText(_ issue: CapabilityExportIssue) -> String {
        switch issue.code {
        case "no_content_selected": return t("settings.migration.issue.noContent", "Select at least one capability.")
        case "plugin_inventory_incomplete": return t("settings.migration.issue.plugins", "The plugin query failed. Export can continue, but the plugin list will be marked incomplete.")
        case "agent_pair_incomplete": return t("settings.migration.issue.agentPair", "An Agent is missing its configuration or matching Brief directory.")
        case "unsafe_relative_path": return t("settings.migration.issue.path", "An unsafe relative path was found. Exclude this capability.")
        case "source_changed_during_read": return t("settings.migration.issue.changed", "A source file changed during preflight. Run the check again.")
        case "invalid_text_encoding": return t("settings.migration.issue.encoding", "A text file is not valid UTF-8. Exclude this capability.")
        case "sensitive_text_detected": return t("settings.migration.issue.sensitive", "Potential credentials or a local user path remain. Exclude this capability.")
        case "unsafe_symlink": return t("settings.migration.issue.symlink", "A symbolic link leaves its capability directory. Exclude this capability.")
        case "sensitive_path_detected": return t("settings.migration.issue.sensitivePath", "A file name or symbolic-link target resembles credential material. Exclude this capability.")
        case "source_read_failed": return t("settings.migration.issue.read", "A source item could not be read. Exclude this capability or correct its permissions.")
        case "nested_archive_not_inspected": return t("settings.migration.issue.archive", "A nested archive will be included unchanged and was not inspected.")
        case "binary_content_unscanned": return t("settings.migration.issue.binary", "Binary resources will be included and hashed, but were not content-scanned.")
        default: return t("settings.migration.issue.unknown", "This item needs attention before export.")
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "agent": return t("settings.migration.agent", "Agent")
        case "skill": return t("settings.migration.skill", "Skill")
        case "instruction": return t("settings.migration.instruction", "Instruction")
        default: return kind
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "agent": return "person.crop.circle"
        case "skill": return "sparkles"
        case "instruction": return "doc.badge.gearshape"
        default: return "doc"
        }
    }

    private var panelBoundaryColor: Color {
        DirectorColor.boundary.opacity(colorSchemeContrast == .increased ? 1 : 0.9)
    }

    private var panelBoundaryWidth: CGFloat {
        colorSchemeContrast == .increased ? 1.5 : 1
    }

    private func t(_ key: String, _ fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }

    private func t(_ key: String, _ fallback: String, _ argument: Int64) -> String {
        languageStore.localizer.format(key, fallback: fallback, argument)
    }
}
