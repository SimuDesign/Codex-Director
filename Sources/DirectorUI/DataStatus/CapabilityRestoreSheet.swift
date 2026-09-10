import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DirectorCore

/// Guided local restore. The sheet intentionally keeps the trust, project
/// mapping, conflict and final confirmation decisions visible in sequence.
struct CapabilityRestoreSheet: View {
    private enum Stage: Equatable {
        case choose
        case trust
        case verifying
        case mapping
        case preflighting
        case review
        case restoring
        case success
        case failure
    }

    @ObservedObject var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var stage: Stage = .choose
    @State private var archiveURL: URL?
    @State private var packageInfo: CapabilityRestorePackageInfo?
    @State private var trustSource = false
    @State private var includedCapabilityIDs: Set<String> = []
    @State private var excludedCapabilityIDs: Set<String> = []
    @State private var mappings: [String: URL] = [:]
    @State private var preview: CapabilityRestorePreview?
    @State private var result: CapabilityRestoreResult?
    @State private var rollbackResult: CapabilityRestoreRollbackResult?
    @State private var cleanupResult: CapabilityRestoreCleanupResult?
    @State private var failureKey = "settings.migration.restore.error.generic"
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 420, idealHeight: 620)
        .background(DirectorColor.canvas)
        .interactiveDismissDisabled(model.isCapabilityRestoring)
        .confirmationDialog(
            t("settings.migration.restore.confirm", "Restore missing files"),
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button(t("settings.migration.restore.confirm", "Restore missing files"), role: .none) { runRestore() }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("settings.migration.restore.confirmBody", "Only missing files will be created. Existing files are never overwritten or merged."))
        }
        .task { stage = .choose }
        .onDisappear {
            // The coordinator defers discard until an active restore/undo has
            // cancelled and completed mandatory cleanup without releasing the
            // shared migration gate early.
            model.discardCapabilityRestore()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DirectorSpacing.space3) {
            Image(systemName: "shippingbox.and.arrow.down")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DirectorColor.accent(.teal))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(t("settings.migration.restoreSheet.title", "Restore capability package"))
                    .font(DirectorTypography.sectionTitle)
                Text(stageLabel)
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Spacer()
            Button { if model.isCapabilityRestoring { model.cancelCapabilityRestore() }; dismiss() } label: {
                Image(systemName: DirectorSymbol.closeInspector).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.isCapabilityRestoring)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(t("common.close", "Close"))
        }
        .padding(.horizontal, DirectorSpacing.space5)
        .padding(.vertical, DirectorSpacing.space4)
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .choose: chooseContent
        case .trust: trustContent
        case .verifying: progressContent(t("settings.migration.restore.verify", "Verify package"))
        case .mapping: mappingContent
        case .preflighting: progressContent(t("settings.migration.restore.preview", "Review restore"))
        case .review: reviewContent
        case .restoring: progressContent(t("settings.migration.restore.restoring", "Restoring files…"))
        case .success: successContent
        case .failure: failureContent
        }
    }

    private var chooseContent: some View {
        VStack(spacing: DirectorSpacing.space4) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 42))
                .foregroundStyle(DirectorColor.accent(.ice))
                .accessibilityHidden(true)
            Text(t("settings.migration.restore.choose", "Choose a .codexpack.zip file…"))
                .font(DirectorTypography.sectionTitle)
            Text(t("settings.migration.restore.mapHint", "Choose a destination folder for every project. Paths are not saved."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(t("settings.migration.restore.choose", "Choose a .codexpack.zip file…")) { choosePackage() }
                .buttonStyle(DirectorPrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DirectorSpacing.space6)
    }

    private var trustContent: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
            callout(symbol: "lock.open", title: t("settings.migration.restore.trust", "I trust the source of this package and understand it is unencrypted."), body: t("settings.migration.unencryptedBody", "Text files are checked for credentials and local paths. Binary files are included and hashed, but not content-scanned. Nothing is uploaded."))
            if let archiveURL {
                Text(archiveURL.lastPathComponent).font(DirectorTypography.supporting.monospaced()).textSelection(.enabled)
            }
            Toggle(t("settings.migration.restore.trust", "I trust the source of this package and understand it is unencrypted."), isOn: $trustSource)
                .toggleStyle(.checkbox)
                .accessibilityHint(t("settings.migration.restore.error.trust", "Confirm that this package comes from a source you trust."))
        }
        .padding(DirectorSpacing.space5)
    }

    private var mappingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                callout(symbol: "arrow.triangle.branch", title: t("settings.migration.restore.map", "Map projects"), body: t("settings.migration.restore.mapHint", "Choose a destination folder for every project. Paths are not saved."), status: .running)
                if let packageInfo, packageInfo.manifest.projects.isEmpty {
                    Text(t("settings.migration.restore.noProjects", "This package has no project capabilities.")).font(DirectorTypography.supporting)
                } else if let packageInfo {
                    ForEach(packageInfo.manifest.projects, id: \.id) { project in
                        HStack(spacing: DirectorSpacing.space3) {
                            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                Text(project.name).font(DirectorTypography.supporting.weight(.semibold))
                                Text(project.id).font(DirectorTypography.label.monospaced()).foregroundStyle(DirectorColor.textSecondary)
                            }
                            Spacer()
                            Button(mappings[project.id]?.lastPathComponent ?? t("settings.migration.restore.map", "Choose folder")) { chooseProjectFolder(project.id) }
                                .buttonStyle(DirectorSecondaryActionButtonStyle(size: .settings))
                        }
                        .padding(DirectorSpacing.space4)
                        .background(DirectorColor.inset.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
                    }
                }
            }
            .padding(DirectorSpacing.space5)
        }
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirectorSpacing.space5) {
                if let preview {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DirectorSpacing.space3)], spacing: DirectorSpacing.space3) {
                        summaryMetric(t("settings.migration.restore.create", "New files"), "\(preview.createCount)")
                        summaryMetric(t("settings.migration.restore.skip", "Identical files skipped"), "\(preview.skipCount)")
                        summaryMetric(t("settings.migration.restore.conflict", "Conflicts"), "\(preview.conflictCount)")
                        summaryMetric(t("settings.migration.plugins", "Plugins listed"), preview.pluginStatus == .complete ? "\(preview.pluginCount)" : t("settings.migration.incomplete", "Incomplete"))
                    }
                    capabilitySelection
                    conflictDetails(preview)
                    packageChecklist
                    if preview.issues.isEmpty || (preview.issues.allSatisfy { $0.severity == .warning }) {
                        callout(symbol: "checkmark.circle", title: t("settings.migration.restore.noConflicts", "No existing targets conflict with this restore."), body: t("settings.migration.restore.confirmBody", "Only missing files will be created. Existing files are never overwritten or merged."), status: .success)
                    } else {
                        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                            Text(t("settings.migration.issues", "Preflight issues")).font(DirectorTypography.sectionTitle)
                            ForEach(preview.issues) { issue in
                                HStack(alignment: .top, spacing: DirectorSpacing.space3) {
                                    Image(systemName: issue.severity == .blocking ? "hand.raised" : "exclamationmark.triangle")
                                        .foregroundStyle(DirectorColor.status(issue.severity == .blocking ? .blocked : .warning))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                        Text(issueText(issue)).font(DirectorTypography.supporting)
                                        if let path = issue.archivePath,
                                           let displayPath = preview.entries.first(where: { $0.archivePath == path })?.displayPath {
                                            Text(displayPath)
                                                .font(DirectorTypography.label.monospaced())
                                                .foregroundStyle(DirectorColor.textSecondary)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    Text(t("settings.migration.restore.successBody", "New files were verified. Plugins and dependencies were listed only; nothing was installed or executed."))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                }
            }
            .padding(DirectorSpacing.space5)
        }
    }

    private var capabilitySelection: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            if let info = packageInfo {
                ForEach(info.manifest.capabilities, id: \.id) { capability in
                    Toggle(isOn: Binding(
                        get: { includedCapabilityIDs.contains(capability.id) },
                        set: {
                            if $0 {
                                includedCapabilityIDs.insert(capability.id)
                                excludedCapabilityIDs.remove(capability.id)
                            } else {
                                includedCapabilityIDs.remove(capability.id)
                                excludedCapabilityIDs.insert(capability.id)
                            }
                            runPreview()
                        }
                    )) {
                        HStack {
                            Image(systemName: capability.kind == "agent" ? "person.crop.circle" : capability.kind == "skill" ? "sparkles" : "doc.badge.gearshape")
                                .accessibilityHidden(true)
                            Text(capability.name).font(DirectorTypography.supporting)
                            Spacer()
                            Text(capability.kind.capitalized).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func progressContent(_ title: String) -> some View {
        VStack(spacing: DirectorSpacing.space4) {
            ProgressView().controlSize(.large)
            Text(title).font(DirectorTypography.sectionTitle)
            if let progress = model.capabilityRestoreProgress, progress.completedItems > 0 {
                Text("\(progress.completedItems)" + (progress.totalItems.map { "/\($0)" } ?? ""))
                    .font(DirectorTypography.supporting.monospacedDigit())
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            Text(t("settings.migration.restore.confirmBody", "Only missing files will be created. Existing files are never overwritten or merged."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DirectorSpacing.space6)
        .accessibilityElement(children: .combine)
    }

    private var successContent: some View {
        ScrollView {
            VStack(spacing: DirectorSpacing.space4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).foregroundStyle(DirectorColor.status(.success)).accessibilityHidden(true)
                Text(t("settings.migration.restore.success", "Restore completed")).font(DirectorTypography.sectionTitle)
                if let result {
                    Text("\(result.createdCount) · \(result.skippedCount)").font(DirectorTypography.supporting.monospacedDigit())
                }
                Text(rollbackResult == nil ? t("settings.migration.restore.successBody", "New files were verified. Plugins and dependencies were listed only; nothing was installed or executed.") : t("settings.migration.restore.undone", "Restore undone"))
                    .font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                if let rollbackResult {
                    cleanupSummary(
                        quarantined: rollbackResult.quarantinedCount,
                        quarantinedDirectories: rollbackResult.quarantinedDirectoryCount,
                        skipped: rollbackResult.skippedModifiedCount,
                        failed: rollbackResult.failedRemovalCount,
                        issues: rollbackResult.issues,
                        quarantineLocations: rollbackResult.quarantineLocations
                    )
                } else if let result, !result.quarantineLocations.isEmpty {
                    quarantinePreparedSummary(result.quarantineLocations)
                }
                packageChecklist
            }
            .frame(maxWidth: .infinity)
            .padding(DirectorSpacing.space6)
        }
    }

    private var failureContent: some View {
        ScrollView {
            VStack(spacing: DirectorSpacing.space4) {
                Image(systemName: "xmark.circle").font(.system(size: 38)).foregroundStyle(DirectorColor.status(.failure)).accessibilityHidden(true)
                Text(t("settings.migration.restore.failed", "Restore could not be completed")).font(DirectorTypography.sectionTitle)
                Text(t(failureKey, "The package was not restored. Review the non-destructive quarantine result below."))
                    .font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                if let cleanupResult {
                    cleanupSummary(
                        quarantined: cleanupResult.quarantinedCount,
                        quarantinedDirectories: cleanupResult.quarantinedDirectoryCount,
                        skipped: cleanupResult.skippedModifiedCount,
                        failed: cleanupResult.failedRemovalCount,
                        issues: cleanupResult.issues,
                        quarantineLocations: cleanupResult.quarantineLocations
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(DirectorSpacing.space6)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: DirectorSpacing.space3) {
            switch stage {
            case .choose, .trust, .mapping, .review, .failure:
                Button(t("common.cancel", "Cancel")) { model.discardCapabilityRestore(); dismiss() }.buttonStyle(DirectorSecondaryActionButtonStyle())
                Spacer()
                footerPrimary
            case .verifying, .preflighting, .restoring:
                Spacer()
                Button(t("settings.migration.restore.cancel", "Cancel restore")) { model.cancelCapabilityRestore() }.buttonStyle(DirectorSecondaryActionButtonStyle())
            case .success:
                if rollbackResult == nil {
                    Button(t("settings.migration.restore.undo", "Undo this restore")) { undoRestore() }.buttonStyle(DirectorSecondaryActionButtonStyle())
                }
                Spacer()
                Button(t("common.done", "Done")) { dismiss() }.buttonStyle(DirectorPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DirectorSpacing.space5).padding(.vertical, DirectorSpacing.space4)
    }

    @ViewBuilder private var footerPrimary: some View {
        switch stage {
        case .choose: Button(t("settings.migration.restore.choose", "Choose a .codexpack.zip file…")) { choosePackage() }.buttonStyle(DirectorPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
        case .trust: Button(t("settings.migration.restore.verify", "Verify package")) { verifyPackage() }.buttonStyle(DirectorPrimaryActionButtonStyle()).disabled(!trustSource).keyboardShortcut(.defaultAction)
        case .mapping: Button(t("settings.migration.restore.preview", "Review restore")) { runPreview() }.buttonStyle(DirectorPrimaryActionButtonStyle()).disabled(!allProjectsMapped).keyboardShortcut(.defaultAction)
        case .review: Button(t("settings.migration.restore.confirm", "Restore missing files")) { confirmRestore = true }.buttonStyle(DirectorPrimaryActionButtonStyle()).disabled(preview?.hasBlockingIssues != false).keyboardShortcut(.defaultAction)
        case .failure: Button(t("settings.migration.restore.choose", "Choose a .codexpack.zip file…")) { reset() }.buttonStyle(DirectorPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
        default: EmptyView()
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = t("settings.migration.restore.choose", "Choose a .codexpack.zip file…")
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, url.lastPathComponent.hasSuffix(".codexpack.zip") else { return }
        archiveURL = url
        stage = .trust
    }

    private func verifyPackage() {
        guard let archiveURL else { return }
        stage = .verifying
        Task {
            do {
                packageInfo = try await model.openCapabilityRestorePackage(at: archiveURL, trustedSource: trustSource)
                includedCapabilityIDs = Set(packageInfo?.manifest.capabilities.map(\.id) ?? [])
                stage = .mapping
            } catch {
                captureCleanup(from: error)
                failureKey = errorKey(error)
                stage = .failure
            }
        }
    }

    private func chooseProjectFolder(_ projectID: String) {
        let panel = NSOpenPanel()
        panel.title = t("settings.migration.restore.map", "Choose destination folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { mappings[projectID] = url }
    }

    private func runPreview() {
        guard packageInfo != nil else { return }
        stage = .preflighting
        Task {
            do {
                preview = try await model.previewCapabilityRestore(selection: makeSelection())
                stage = .review
            } catch {
                failureKey = errorKey(error)
                stage = .failure
            }
        }
    }

    private func runRestore() {
        cleanupResult = nil
        stage = .restoring
        Task {
            do {
                result = try await model.restoreCapabilityPackage(selection: makeSelection())
                stage = .success
            } catch {
                captureCleanup(from: error)
                failureKey = errorKey(error)
                stage = .failure
            }
        }
    }

    private func undoRestore() {
        Task {
            do { rollbackResult = try await model.rollbackCapabilityRestore() }
            catch { failureKey = "settings.migration.restore.error.generic" }
        }
    }

    private func reset() {
        model.discardCapabilityRestore()
        archiveURL = nil; packageInfo = nil; preview = nil; result = nil; rollbackResult = nil; cleanupResult = nil; mappings = [:]; includedCapabilityIDs = []; excludedCapabilityIDs = []; trustSource = false; stage = .choose
    }

    private var allProjectsMapped: Bool {
        guard let info = packageInfo else { return false }
        let required = Set(info.manifest.capabilities.filter { includedCapabilityIDs.contains($0.id) }.compactMap(\.projectID))
        return required.isSubset(of: Set(mappings.keys))
    }

    private func makeSelection() -> CapabilityRestoreSelection {
        CapabilityRestoreSelection(
            includedCapabilityIDs: includedCapabilityIDs,
            excludedCapabilityIDs: excludedCapabilityIDs,
            projectMappings: mappings.map {
                CapabilityRestoreProjectMapping(packageProjectID: $0.key, destinationURL: $0.value)
            }
        )
    }

    private var stageLabel: String {
        switch stage {
        case .choose: return t("settings.migration.restore.choose", "Choose package")
        case .trust: return t("settings.migration.restore.trust", "Confirm trusted source")
        case .verifying: return t("settings.migration.restore.verify", "Verifying")
        case .mapping: return t("settings.migration.restore.map", "Map projects")
        case .preflighting, .review: return t("settings.migration.restore.preview", "Review restore")
        case .restoring: return t("settings.migration.restore.restoring", "Restoring")
        case .success: return t("settings.migration.restore.success", "Complete")
        case .failure: return t("settings.migration.restore.failed", "Needs attention")
        }
    }

    private func issueText(_ issue: CapabilityRestoreIssue) -> String {
        switch issue.code {
        case "target_conflict": return t("settings.migration.restore.issue.conflict", "An existing file differs and will not be overwritten.")
        case "agents_file_exists": return t("settings.migration.restore.issue.agents", "An existing AGENTS.md requires a manual decision.")
        case "capability_conflict": return t("settings.migration.restore.issue.capability", "This capability is partially present or conflicts. Exclude it to continue.")
        case "binary_content_unscanned": return t("settings.migration.restore.issue.binary", "This binary was verified and hashed, but its contents were not scanned.")
        case "nested_archive_not_inspected": return t("settings.migration.restore.issue.archive", "This nested archive will remain unchanged and will not be opened.")
        default: return issue.message
        }
    }

    private func errorKey(_ error: Error) -> String {
        if let failure = error as? CapabilityRestoreOperationFailure {
            return errorKey(failure.reason)
        }
        if let error = error as? CapabilityRestoreError {
            switch error {
            case .untrustedSource: return "settings.migration.restore.error.trust"
            case .missingProjectMapping, .duplicateProjectMapping, .invalidProjectMapping: return "settings.migration.restore.error.mapping"
            default: return "settings.migration.restore.error.generic"
            }
        }
        return "settings.migration.restore.error.generic"
    }

    private func captureCleanup(from error: Error) {
        cleanupResult = (error as? CapabilityRestoreOperationFailure)?.cleanup
    }

    @ViewBuilder private func conflictDetails(_ preview: CapabilityRestorePreview) -> some View {
        let conflicts = preview.entries.filter { $0.action == .conflict }
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                Text(t("settings.migration.restore.conflictDetails", "Conflict details"))
                    .font(DirectorTypography.sectionTitle)
                ForEach(conflicts) { entry in
                    VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                        Text(entry.displayPath)
                            .font(DirectorTypography.supporting.monospaced())
                            .textSelection(.enabled)
                        Text(entryMetadata(entry))
                            .font(DirectorTypography.label.monospaced())
                            .foregroundStyle(DirectorColor.textSecondary)
                            .textSelection(.enabled)
                        if let difference = entry.difference, !difference.isEmpty {
                            Text(t("settings.migration.restore.textDifference", "Redacted text difference"))
                                .font(DirectorTypography.label.weight(.semibold))
                            ScrollView(.horizontal) {
                                Text(String(difference.prefix(4_000)))
                                    .font(DirectorTypography.label.monospaced())
                                    .textSelection(.enabled)
                            }
                            .accessibilityLabel(t("settings.migration.restore.textDifference", "Redacted text difference"))
                        } else {
                            Text(t("settings.migration.restore.metadataOnly", "Content is not shown. Only verified type, size, executable state, and SHA-256 metadata are available."))
                                .font(DirectorTypography.label)
                                .foregroundStyle(DirectorColor.textSecondary)
                        }
                    }
                    .padding(DirectorSpacing.space4)
                    .background(DirectorColor.inset.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                            .stroke(DirectorColor.boundary, lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var packageChecklist: some View {
        if let info = packageInfo {
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                Text(t("settings.migration.restore.pluginChecklist", "Plugins to install manually"))
                    .font(DirectorTypography.sectionTitle)
                if info.plugins.plugins.isEmpty {
                    Text(t("settings.migration.restore.noneListed", "None listed"))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                } else {
                    ForEach(Array(info.plugins.plugins.enumerated()), id: \.offset) { _, plugin in
                        checklistRow(
                            title: safeLabel(plugin.name.isEmpty ? plugin.identifier : plugin.name),
                            detail: [plugin.version.map { safeLabel($0) }, plugin.enabled ? t("library.enabled", "Enabled") : t("library.disabled", "Disabled")]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                    }
                }
                if info.plugins.status == .incomplete {
                    Text(t("settings.migration.restore.pluginIncomplete", "The package plugin inventory is incomplete."))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.status(.warning))
                }

                Text(t("settings.migration.restore.dependencyChecklist", "Missing dependency checklist"))
                    .font(DirectorTypography.sectionTitle)
                    .padding(.top, DirectorSpacing.space2)
                if info.requirements.requirements.isEmpty {
                    Text(t("settings.migration.restore.noneListed", "None listed"))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSecondary)
                } else {
                    ForEach(Array(info.requirements.requirements.enumerated()), id: \.offset) { _, requirement in
                        checklistRow(title: safeLabel(requirement.name), detail: safeLabel(requirement.kind))
                    }
                }
                Text(t("settings.migration.restore.checklistReadOnly", "This is a read-only checklist from the verified package. Availability is not inferred, and nothing is installed or executed."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cleanupSummary(
        quarantined: Int,
        quarantinedDirectories: Int,
        skipped: Int,
        failed: Int,
        issues: [CapabilityRestoreIssue],
        quarantineLocations: [CapabilityRestoreQuarantineLocation]
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Text(t("settings.migration.restore.cleanupTitle", "Cleanup result"))
                .font(DirectorTypography.sectionTitle)
            Text(String(
                format: t("settings.migration.restore.cleanupSummary", "Moved %d files and %d directories to private quarantine; preserved %d changed items in place; %d quarantine moves failed."),
                quarantined,
                quarantinedDirectories,
                skipped,
                failed
            ))
            .font(DirectorTypography.supporting.monospacedDigit())
            Text(t("settings.migration.restore.quarantineRetention", "Codex Director never automatically deletes quarantine contents. Review them in Finder and delete them yourself only when ready."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSecondary)
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: DirectorSpacing.space2) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DirectorColor.status(.warning))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Text(cleanupIssueText(issue)).font(DirectorTypography.supporting)
                        if let path = issue.archivePath {
                            Text(path).font(DirectorTypography.label.monospaced()).foregroundStyle(DirectorColor.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            quarantineRevealButtons(quarantineLocations)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
    }

    private func quarantinePreparedSummary(
        _ locations: [CapabilityRestoreQuarantineLocation]
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Text(t("settings.migration.restore.quarantineTitle", "Private quarantine"))
                .font(DirectorTypography.sectionTitle)
            Text(t("settings.migration.restore.quarantinePrepared", "A private quarantine was prepared before restore writes. It is kept locally and is not automatically deleted."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
            quarantineRevealButtons(locations)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
    }

    @ViewBuilder private func quarantineRevealButtons(
        _ locations: [CapabilityRestoreQuarantineLocation]
    ) -> some View {
        ForEach(locations) { location in
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([location.directoryURL])
            } label: {
                Label(
                    "\(t("settings.migration.restore.revealQuarantine", "Reveal quarantine in Finder")) · \(location.placeholder)",
                    systemImage: "folder"
                )
            }
            .buttonStyle(DirectorSecondaryActionButtonStyle())
            .accessibilityLabel("\(t("settings.migration.restore.revealQuarantine", "Reveal quarantine in Finder")) \(location.placeholder)")
            .accessibilityHint(t("settings.migration.restore.revealQuarantineHint", "Opens the local private quarantine in Finder without deleting anything."))
        }
    }

    private func checklistRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
            Image(systemName: "circle")
                .font(.system(size: 6, weight: .semibold))
                .accessibilityHidden(true)
            Text(title).font(DirectorTypography.supporting.weight(.semibold))
            Spacer()
            Text(detail).font(DirectorTypography.label).foregroundStyle(DirectorColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func entryMetadata(_ entry: CapabilityRestoreEntryPreview) -> String {
        let size = ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file)
        let executable = entry.executable
            ? t("settings.migration.restore.executable", "executable")
            : t("settings.migration.restore.notExecutable", "not executable")
        return "\(safeLabel(entry.contentType)) · \(size) · \(executable) · SHA-256 \(entry.sha256)"
    }

    private func cleanupIssueText(_ issue: CapabilityRestoreIssue) -> String {
        switch issue.code {
        case "cleanup_target_changed": return t("settings.migration.restore.cleanup.changed", "A created item was replaced and was preserved.")
        case "cleanup_target_modified": return t("settings.migration.restore.cleanup.modified", "A created item was modified and was preserved.")
        case "cleanup_target_missing": return t("settings.migration.restore.cleanup.moved", "A created item was moved or renamed and was preserved.")
        case "cleanup_directory_changed": return t("settings.migration.restore.cleanup.directory", "A created directory is no longer empty and was preserved.")
        case "cleanup_preserved_isolated": return t("settings.migration.restore.cleanup.isolated", "An unchanged created item was moved out of its logical path and remains preserved in private quarantine.")
        case "cleanup_quarantine_unavailable": return t("settings.migration.restore.cleanup.quarantineUnavailable", "A private quarantine could not be prepared, so no restore target writes were started.")
        case "cleanup_quarantine_move_failed": return t("settings.migration.restore.cleanup.quarantineMoveFailed", "An item could not be moved to private quarantine and was preserved in place.")
        case "cleanup_unverified_staging_preserved": return t("settings.migration.restore.cleanup.unverifiedStaging", "A staging item could not be proven to still belong to this restore and was preserved in place.")
        default: return t("settings.migration.restore.cleanup.failed", "An item was preserved because its cleanup state could not be proven safe.")
        }
    }

    private func safeLabel(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(flattened.prefix(120))
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

    private func callout(symbol: String, title: String, body: String, status: RuntimeStatus = .warning) -> some View {
        HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            Image(systemName: symbol).foregroundStyle(DirectorColor.status(status)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) { Text(title).font(DirectorTypography.supporting.weight(.semibold)); Text(body).font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary) }
        }
        .padding(DirectorSpacing.space4)
        .background(DirectorColor.inset.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous).stroke(DirectorColor.boundary.opacity(colorSchemeContrast == .increased ? 1 : 0.9), lineWidth: colorSchemeContrast == .increased ? 1.5 : 1).accessibilityHidden(true) }
        .accessibilityElement(children: .combine)
    }

    private func t(_ key: String, _ fallback: String) -> String { languageStore.localizer.text(key, fallback: fallback) }
}
