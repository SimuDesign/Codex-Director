import SwiftUI
import DirectorCore

private struct CapabilityFolderSessionKey: Hashable {
    let folderID: String
    let tab: CapabilityFolderTab
}

/// Folder browser for the local capability directory. This surface deliberately
/// keeps folder organization separate from source files, usage evidence and
/// the existing capability detail model.
public struct CapabilityFoldersView: View {
    @ObservedObject public var model: DirectorAppModel
    public var detailContext: ((CapabilityResource) -> CapabilityDetailViewModel)?

    @EnvironmentObject private var languageStore: AppLanguageStore
    @State private var selectedFolderID: String?
    @State private var entrySearch = ""
    // Keep the entry page's scroll target independent from each folder page.
    // A non-nil anchor also gives the native List a stable initial target.
    @State private var entryScrollPosition: String? = "capability-folders-entry-top"
    // Folder browsing state is session-only and keyed by folder + tab. A
    // search, sort, expansion, scroll target, or selected detail in Agent is
    // intentionally independent from the same folder's Skill view.
    @State private var folderSearchByKey: [CapabilityFolderSessionKey: String] = [:]
    @State private var folderTabByID: [String: CapabilityFolderTab] = [:]
    @State private var folderSortByKey: [CapabilityFolderSessionKey: CapabilityFolderSort] = [:]
    @State private var folderScrollPositionByKey: [CapabilityFolderSessionKey: String?] = [:]
    @State private var draggingFolderID: String?
    @State private var entrySelectedResourceID: String?
    @State private var selectedResourceIDByKey: [CapabilityFolderSessionKey: String?] = [:]
    @State private var collapsedCompanionAgentIDsByKey: [CapabilityFolderSessionKey: Set<String>] = [:]
    @State private var showsCreateSheet = false
    @State private var createName = ""
    @State private var editingFolder: CapabilityFolderDefinition?
    @State private var editName = ""
    @State private var importTargetFolder: CapabilityFolderDefinition?
    @State private var folderToDelete: CapabilityFolderDefinition?
    @State private var showsDeleteConfirmation = false

    public init(model: DirectorAppModel, detailContext: ((CapabilityResource) -> CapabilityDetailViewModel)? = nil) {
        self.model = model
        self.detailContext = detailContext
    }

    public var body: some View {
        DirectorEditorialFrame {
            GeometryReader { proxy in
                List {
                    if let selectedFolderID,
                       let folder = model.capabilityFolders.folder(withID: selectedFolderID) {
                        folderPage(folder, width: proxy.size.width)
                    } else {
                        entryPage(width: proxy.size.width)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .background(Color.clear)
                .scrollPosition(id: activeScrollPosition)
                .overlay(alignment: .trailing) { detailSheet(width: proxy.size.width) }
            }
        }
        .navigationTitle(t("nav.capabilityFolders", "Capability Folders"))
        .sheet(isPresented: $showsCreateSheet) {
            FolderNameSheet(
                title: t("capabilityFolders.create", "New folder"),
                prompt: t("capabilityFolders.name", "Folder name"),
                name: $createName,
                confirmTitle: t("capabilityFolders.createAction", "Create"),
                onCancel: { showsCreateSheet = false },
                onConfirm: createFolder
            )
            .environmentObject(languageStore)
        }
        .sheet(item: $editingFolder) { folder in
            FolderNameSheet(
                title: t("capabilityFolders.rename", "Rename folder"),
                prompt: t("capabilityFolders.name", "Folder name"),
                name: $editName,
                confirmTitle: t("capabilityFolders.save", "Save"),
                onCancel: { editingFolder = nil },
                onConfirm: { renameFolder(folder) }
            )
            .environmentObject(languageStore)
        }
        .sheet(item: $importTargetFolder) { folder in
            CapabilityFolderImportSheet(model: model, folder: folder)
                .environmentObject(languageStore)
        }
        .confirmationDialog(
            t("capabilityFolders.delete.confirmTitle", "Delete folder?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(t("capabilityFolders.delete", "Delete"), role: .destructive) {
                if let folderToDelete { deleteFolder(folderToDelete) }
            }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("capabilityFolders.delete.confirmBody", "Only the folder and its memberships will be removed. Capability files and evidence are unchanged."))
        }
        .alert(
            t("capabilityFolders.error", "Unable to save folder"),
            isPresented: Binding(get: { model.capabilityFolderError != nil }, set: { if !$0 { model.clearCapabilityFolderError() } })
        ) {
            Button(t("capabilityFolders.retry", "Try again")) { model.retryCapabilityFolderPreferences() }
            if model.capabilityFolderPreferencesState == .corrupted {
                Button(t("capabilityFolders.clearCorrupted", "Reset folder settings"), role: .destructive) {
                    model.clearCorruptedCapabilityFolderPreferences()
                }
            }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t(model.capabilityFolderError ?? "capabilityFolders.saveFailed", "Please try again."))
        }
        .onChange(of: model.capabilityFolderProjection) { _, projection in
            if let selectedFolderID, !projection.folders.contains(where: { $0.id == selectedFolderID }) {
                self.selectedFolderID = nil
            }
            for key in selectedResourceIDByKey.keys where selectedResourceIDByKey[key].flatMap({ $0 }) != nil {
                if let selected = selectedResourceIDByKey[key] ?? nil,
                   !projection.resources.contains(where: { $0.id == selected }) {
                    selectedResourceIDByKey[key] = nil
                }
            }
        }
        .task(id: model.capabilityCompanionUsageGeneration) {
            await model.loadCapabilityCompanionUsageIfNeeded()
        }
    }

    @ViewBuilder
    private func entryPage(width: CGFloat) -> some View {
        pageHeader(width: width)
        entrySearchRow(width: width)
        if entrySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section {
                folderGrid(model.capabilityFolders.folders.filter(\.isCustom), width: width)
            } header: {
                sectionHeader(t("capabilityFolders.myFolders", "My Folders"), action: newFolderButton)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets(for: width))
            }

            Section {
                folderGrid(model.capabilityFolders.folders.filter(\.isDefault), width: width)
            } header: {
                sectionHeader(t("capabilityFolders.defaults", "Global & Projects"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets(for: width))
            }
        } else {
            Section {
                if globalSearchResults.isEmpty {
                    emptyState(t("capabilityFolders.empty.search", "No capabilities match this search."), width: width)
                } else {
                    ForEach(globalSearchResults) { member in
                        memberRow(member, folder: nil, width: width)
                            .id(member.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(rowInsets(for: width))
                    }
                }
            } header: {
                sectionHeader(t("capabilityFolders.searchResults", "Search results · all capabilities"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets(for: width))
            }
        }
    }

    @ViewBuilder
    private func folderPage(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        HStack(spacing: DirectorSpacing.space3) {
            Button {
                selectedFolderID = nil
            } label: {
                Label(t("capabilityFolders.back", "Back to folders"), systemImage: "chevron.left")
            }
            .buttonStyle(DirectorSecondaryActionButtonStyle())
            Spacer()
            if folder.isCustom {
                Button {
                    importTargetFolder = folder
                } label: {
                    Label(t("capabilityFolders.import", "Add existing capabilities"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(DirectorSecondaryActionButtonStyle())
                folderActions(folder)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))

        DirectorPageHeader(
            eyebrow: t("capabilityFolders.eyebrow", "07 / Capability Folders"),
            title: folderTitle(folder),
            titleAccent: nil,
            subtitle: folder.isDefault
                ? t("capabilityFolders.defaultSubtitle", "Browse capabilities by configuration ownership.")
                : t("capabilityFolders.customSubtitle", "A personal, local collection of capabilities."),
            symbolName: "folder.fill",
            tone: .blue
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))

        folderTabs(for: folder.id, width: width)

        DirectorFilterRibbon(compact: width < DirectorPageLayout.compactBreakpoint) {
            HStack(spacing: DirectorSpacing.space3) {
                DirectorControlField {
                    HStack(spacing: DirectorSpacing.space2) {
                        Image(systemName: DirectorSymbol.search).foregroundStyle(DirectorColor.textSecondary).accessibilityHidden(true)
                        TextField(t("capabilityFolders.searchInside", "Search this folder"), text: folderSearchBinding(for: folder.id))
                            .textFieldStyle(.plain)
                            .accessibilityLabel(t("capabilityFolders.searchInside", "Search this folder"))
                    }
                }
                .frame(minWidth: 180, maxWidth: .infinity)
                sortMenu(for: folder.id)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))

        let members = folderMembers(folder)
        let hasQuery = !(folderSearch(for: folder.id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if members.isEmpty {
            emptyState(
                hasQuery
                    ? t("capabilityFolders.empty.matches", "No capabilities match this search.")
                    : folder.isCustom
                    ? t("capabilityFolders.empty.custom", "This folder is empty. Add capabilities from a list or detail view.")
                    : t("capabilityFolders.empty.none", "No Agents or Skills are available here."),
                width: width
            )
        } else {
            ForEach(members) { member in
                Group {
                    if currentFolderTab(for: folder.id) == .agentCompanions,
                       member.resource.kind == .agent {
                        agentCompanionRow(member, folder: folder, width: width)
                    } else if currentFolderTab(for: folder.id) == .skills,
                              member.resource.kind == .skill {
                        skillRelationshipRow(member, folder: folder, width: width)
                    } else {
                        memberRow(member, folder: folder, width: width)
                    }
                }
                    .id(member.id)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets(for: width))
            }
        }
    }

    private func pageHeader(width: CGFloat) -> some View {
        DirectorPageHeader(
            eyebrow: t("capabilityFolders.eyebrow", "07 / Capability Folders"),
            title: t("capabilityFolders.title", "Capability Folders"),
            titleAccent: nil,
            subtitle: t("capabilityFolders.subtitle", "Browse Agents and Skills through local, user-controlled folders."),
            symbolName: "folder.fill",
            tone: .blue
        )
        .id("capability-folders-entry-top")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: DirectorSpacing.space6, leading: DirectorPageLayout.listRowInset(for: width), bottom: DirectorSpacing.space4, trailing: DirectorPageLayout.listRowInset(for: width)))
    }

    private func entrySearchRow(width: CGFloat) -> some View {
        DirectorFilterRibbon(compact: width < DirectorPageLayout.compactBreakpoint) {
            HStack(spacing: DirectorSpacing.space2) {
                Image(systemName: DirectorSymbol.search).foregroundStyle(DirectorColor.textSecondary).accessibilityHidden(true)
                TextField(t("capabilityFolders.search", "Search all capabilities"), text: $entrySearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(t("capabilityFolders.search", "Search all capabilities"))
                if !entrySearch.isEmpty {
                    Button { entrySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .accessibilityLabel(t("capabilityFolders.clearSearch", "Clear search"))
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))
    }

    private func sectionHeader(_ title: String, action: AnyView? = nil) -> some View {
        HStack {
            Text(title).font(DirectorTypography.sectionTitle.weight(.semibold)).foregroundStyle(DirectorColor.textPrimary)
            Spacer()
            if let action { action }
        }
        .padding(.vertical, DirectorSpacing.space3)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary).frame(height: 1) }
    }

    private var newFolderButton: AnyView {
        AnyView(Button { createName = ""; showsCreateSheet = true } label: {
            Label(t("capabilityFolders.add", "New folder"), systemImage: "plus")
        }.buttonStyle(DirectorSecondaryActionButtonStyle()))
    }

    private func folderGrid(_ folders: [CapabilityFolderDefinition], width: CGFloat) -> some View {
        LazyVGrid(
            columns: DirectorAdaptiveGrid.items(for: max(0, width - DirectorPageLayout.listRowInset(for: width) * 2)),
            alignment: .leading,
            spacing: DirectorSpacing.space4
        ) {
            ForEach(folders) { folder in
                if folder.isCustom {
                    folderCard(folder, width: width)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onDrag {
                            draggingFolderID = folder.id
                            return NSItemProvider(object: folder.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: CapabilityFolderDropDelegate(
                                targetID: folder.id,
                                orderedIDs: folders.filter(\.isCustom).map(\.id),
                                draggingID: $draggingFolderID,
                                move: moveDraggedFolder
                            )
                        )
                        .id(folder.id)
                } else {
                    // Global and Project are immutable derived views. They
                    // remain selectable, but are never drag sources or drop
                    // targets for the custom-folder reorder operation.
                    folderCard(folder, width: width)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(folder.id)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))
        .accessibilityElement(children: .contain)
    }

    private func folderCard(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        HStack(spacing: DirectorSpacing.space3) {
            Button { selectedFolderID = folder.id } label: {
                HStack(spacing: DirectorSpacing.space3) {
                Image(systemName: folder.isDefault ? "folder" : "folder.fill")
                    .foregroundStyle(DirectorColor.accent(folder.isDefault ? .ice : .teal))
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    Text(folderTitle(folder)).font(DirectorTypography.capabilityRowTitle).foregroundStyle(DirectorColor.textPrimary)
                    Text(folderCounts(folder)).font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary)
                }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(DirectorColor.textTertiary).accessibilityHidden(true)
                }
                .padding(.vertical, DirectorSpacing.space4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if folder.isCustom { folderActions(folder) }
        }
        .padding(.horizontal, DirectorSpacing.space3)
        .padding(.vertical, DirectorSpacing.space1)
        .background(RoundedRectangle(cornerRadius: DirectorRadius.metric, style: .continuous).fill(DirectorColor.inset.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: DirectorRadius.metric, style: .continuous).stroke(DirectorColor.boundary, lineWidth: 1))
        .accessibilityLabel("\(folderTitle(folder)), \(folderCounts(folder))")
    }

    private func folderActions(_ folder: CapabilityFolderDefinition) -> some View {
        Menu {
            Button(t("capabilityFolders.import", "Add existing capabilities")) {
                importTargetFolder = folder
            }
            Divider()
            Button(t("capabilityFolders.rename", "Rename folder")) {
                editName = folder.customName ?? folderTitle(folder)
                editingFolder = folder
            }
            Button(t("capabilityFolders.moveUp", "Move up")) { model.moveCapabilityFolder(id: folder.id, direction: .up) }
            Button(t("capabilityFolders.moveDown", "Move down")) { model.moveCapabilityFolder(id: folder.id, direction: .down) }
            Divider()
            Button(t("capabilityFolders.delete", "Delete"), role: .destructive) {
                folderToDelete = folder
                showsDeleteConfirmation = true
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(DirectorColor.textSecondary)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(t("capabilityFolders.actions", "Folder actions"))
    }

    private func memberRow(_ member: CapabilityFolderMember, folder: CapabilityFolderDefinition?, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            Button { selectResource(member.id) } label: {
                HStack(alignment: .top, spacing: DirectorSpacing.space3) {
                    Image(systemName: DirectorSymbol.resource(member.resource.kind))
                        .foregroundStyle(DirectorColor.resource(member.resource.kind))
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        HStack(spacing: DirectorSpacing.space2) {
                            Text(member.resource.name).font(DirectorTypography.capabilityRowTitle).foregroundStyle(DirectorColor.textPrimary).lineLimit(1).truncationMode(.middle)
                            Text(member.resource.kind == .agent ? t("capabilityFolders.agent", "Agent") : t("capabilityFolders.skill", "Skill"))
                                .font(DirectorTypography.label).foregroundStyle(DirectorColor.textTertiary)
                            if let folder,
                               member.resource.kind == .agent,
                               currentFolderTab(for: folder.id) == .agentCompanions {
                                Text(companionCountText(for: member.id, folderID: folder.id))
                                    .font(DirectorTypography.label)
                                    .foregroundStyle(DirectorColor.textSecondary)
                            }
                        }
                        Text(CapabilityPurposeLocalization.localizedSummary(for: member.resource, language: languageStore.language) ?? t("capabilityFolders.purposeUnavailable", "Purpose unavailable"))
                            .font(DirectorTypography.capabilityRowSummary).foregroundStyle(DirectorColor.textSecondary).lineLimit(2)
                        Text("\(scopeText(for: member.resource)) · \(sourceText(for: member.resource))")
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                            .lineLimit(1)
                        Text(recentUsageText(for: member.resource.id))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                    }
                    Spacer(minLength: DirectorSpacing.space2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(member.resource.name), \(member.resource.kind == .agent ? t("capabilityFolders.agent", "Agent") : t("capabilityFolders.skill", "Skill"))")
            folderMembershipMenu(member.resource, currentFolder: folder)
        }
        .padding(.vertical, DirectorSpacing.space3)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary.opacity(0.66)).frame(height: 1) }
    }

    private func agentCompanionRow(_ member: CapabilityFolderMember, folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            memberRow(member, folder: folder, width: width)
                .overlay(alignment: .bottom) { EmptyView() }
            let relations = model.capabilityFolders.companionSkills(for: member.id, in: folder.id)
            if relations.isEmpty {
                Text(t("capabilityFolders.companions.none", "No companion Skill recorded"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                    .padding(.leading, 38)
            } else {
                let isCollapsed = collapsedCompanionAgentIDs(for: folder.id).contains(member.id)
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    Button {
                        var collapsed = collapsedCompanionAgentIDs(for: folder.id)
                        if isCollapsed { collapsed.remove(member.id) }
                        else { collapsed.insert(member.id) }
                        collapsedCompanionAgentIDsByKey[sessionKey(for: folder.id)] = collapsed
                    } label: {
                        Label(
                            isCollapsed
                                ? t("capabilityFolders.companions.expand", "Show companion Skills")
                                : t("capabilityFolders.companions.collapse", "Hide companion Skills"),
                            systemImage: isCollapsed ? "chevron.right" : "chevron.down"
                        )
                        .font(DirectorTypography.label.weight(.semibold))
                        .foregroundStyle(DirectorColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 38)
                    .accessibilityHint(t("capabilityFolders.companions.expandHint", "Expand to review declared relationships and usage evidence."))
                    if !isCollapsed {
                        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                            ForEach(Array(relations.enumerated()), id: \.offset) { _, item in
                                Button {
                                    selectResource(item.resource.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                        HStack(spacing: DirectorSpacing.space2) {
                                            Image(systemName: DirectorSymbol.resource(.skill))
                                                .foregroundStyle(DirectorColor.resource(.skill))
                                                .accessibilityHidden(true)
                                            Text(item.resource.name)
                                                .font(DirectorTypography.supporting)
                                                .foregroundStyle(DirectorColor.textPrimary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(DirectorColor.textTertiary)
                                                .accessibilityHidden(true)
                                        }
                                        Text(relationshipDeclarationText(item.relation))
                                            .font(DirectorTypography.label)
                                        HStack(spacing: DirectorSpacing.space2) {
                                            if item.isPreview {
                                                Text(companionPreviewLabel(for: item.resource, in: folder))
                                            }
                                            companionUsageLabel(for: item.relation)
                                        }
                                        .font(DirectorTypography.label)
                                        .foregroundStyle(DirectorColor.textTertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.resource.name), \(t("capabilityFolders.skill", "Skill"))")
                            }
                        }
                        .padding(.leading, 38)
                        .padding(.bottom, DirectorSpacing.space3)
                    }
                }
            }
        }
    }

    private func skillRelationshipRow(_ member: CapabilityFolderMember, folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            memberRow(member, folder: folder, width: width)
            let relations = model.capabilityFolders.relatedAgents(for: member.id, in: folder.id)
            if relations.isEmpty {
                Text(t("capabilityFolders.companions.unassociated", "No Agent association recorded"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                    .padding(.leading, 38)
                    .padding(.bottom, DirectorSpacing.space3)
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    ForEach(Array(relations.enumerated()), id: \.offset) { _, item in
                        Button { selectResource(item.resource.id) } label: {
                            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                HStack(spacing: DirectorSpacing.space2) {
                                    Image(systemName: DirectorSymbol.resource(.agent))
                                        .foregroundStyle(DirectorColor.resource(.agent))
                                        .accessibilityHidden(true)
                                    Text(item.resource.name).font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DirectorColor.textTertiary).accessibilityHidden(true)
                                }
                                Text(relationshipDeclarationText(item.relation))
                                    .font(DirectorTypography.label)
                                HStack(spacing: DirectorSpacing.space2) {
                                    if item.isPreview { Text(companionPreviewLabel(for: item.resource, in: folder)) }
                                    companionUsageLabel(for: item.relation)
                                }
                                .font(DirectorTypography.label)
                                .foregroundStyle(DirectorColor.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.resource.name), \(t("capabilityFolders.agent", "Agent"))")
                    }
                }
                .padding(.leading, 38)
                .padding(.bottom, DirectorSpacing.space3)
            }
        }
    }

    private func companionPreviewLabel(for resource: CapabilityResource, in folder: CapabilityFolderDefinition) -> String {
        if folder.isCustom {
            return t("capabilityFolders.companions.previewOutside", "Outside folder · related preview")
        }
        if folder.source == .project, resource.projectID == nil {
            return t("capabilityFolders.companions.previewGlobal", "Global · related preview")
        }
        return t("capabilityFolders.companions.previewOutside", "Outside folder · related preview")
    }

    private func companionCountText(for agentID: String, folderID: String) -> String {
        let count = Set(
            model.capabilityFolders.companionSkills(for: agentID, in: folderID)
                .filter { !$0.isPreview }
                .map { $0.resource.id }
        ).count
        return count == 0
            ? t("capabilityFolders.companions.none", "No companion Skill recorded")
            : String(format: t("capabilityFolders.companions.count", "%d companion Skills"), count)
    }

    private func relationshipDeclarationText(_ relation: CapabilityCompanionRelation) -> String {
        let kind = relation.kind == .requiresAgent
            ? t("capabilityFolders.companions.requiresAgent", "Requires Agent")
            : t("capabilityFolders.companions.companion", "Companion Skill")
        let source: String
        switch relation.declarationSource {
        case .projectRegistry: source = t("capabilityFolders.companions.source.registry", "Project registry")
        case .agentConfiguration: source = t("capabilityFolders.companions.source.configuration", "Agent configuration")
        case .agentBrief: source = t("capabilityFolders.companions.source.brief", "Agent Brief")
        case .skillDescription: source = t("capabilityFolders.companions.source.description", "Skill description")
        }
        return "\(kind) · \(source)"
    }

    @ViewBuilder
    private func companionUsageLabel(for relation: CapabilityCompanionRelation) -> some View {
        // Consume the AppModel's one-shot batch projection. Rows never query
        // SQLite or rescan sessions independently.
        let stats = model.capabilityCompanionUsageByRelationID[relation.id] ?? .unavailable
        let count = stats.sessionCount.map(String.init) ?? "—"
        let last = stats.lastObservedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        Text("\(t("capabilityFolders.companions.coObservedShort", "Co-observed")): \(count) · \(t("capabilityFolders.companions.lastObserved", "Last observed")): \(last) · \(coverageText(stats.coverage))")
            .font(DirectorTypography.label)
            .foregroundStyle(DirectorColor.textTertiary)
    }

    private func folderMembershipMenu(_ resource: CapabilityResource, currentFolder: CapabilityFolderDefinition?) -> some View {
        Menu {
            ForEach(model.capabilityFolders.folders.filter(\.isCustom)) { folder in
                let checked = model.capabilityFolderStore.preferences().memberships.contains { $0.folderID == folder.id && $0.resourceID == resource.id }
                Button {
                    model.setCapabilityFolderMembership(resourceID: resource.id, folderID: folder.id, included: !checked)
                } label: {
                    HStack {
                        Text(folderTitle(folder))
                        if checked { Image(systemName: "checkmark") }
                    }
                }
            }
            if let currentFolder, currentFolder.isCustom {
                Divider()
                Button(t("capabilityFolders.remove", "Remove from folder"), role: .destructive) {
                    model.setCapabilityFolderMembership(resourceID: resource.id, folderID: currentFolder.id, included: false)
                }
            }
        } label: {
            Image(systemName: "folder.badge.plus").foregroundStyle(DirectorColor.textSecondary)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(t("capabilityFolders.addToFolder", "Add to folder"))
        .disabled(model.capabilityFolders.folders.filter(\.isCustom).isEmpty)
    }

    @ViewBuilder private func detailSheet(width: CGFloat) -> some View {
        if let selectedResourceID = currentSelectedResourceID,
           let resource = model.capabilityFolders.resources.first(where: { $0.id == selectedResourceID }),
           let detailContext {
            Color.black.opacity(0.24).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { clearSelectedResource() }.accessibilityHidden(true)
            DirectorSideSheet(
                width: min(DirectorSpacing.sideSheetMaxWidth, max(DirectorSpacing.sideSheetMinWidth, width * 0.34)),
                onClose: { clearSelectedResource() },
                closeLabel: t("detail.close", "Close detail")
            ) {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    folderMembershipMenu(resource, currentFolder: selectedFolderID.flatMap(model.capabilityFolders.folder(withID:)))
                    if let folderID = selectedFolderID {
                        if resource.kind == .agent {
                            relatedSkillsSection(for: resource, folderID: folderID)
                        } else if resource.kind == .skill {
                            relatedAgentsSection(for: resource, folderID: folderID)
                        }
                    }
                    CapabilityDetailView(model: detailContext(resource), showsBackButton: false)
                }
            }
            .padding(.vertical, DirectorSpacing.space2)
        }
    }

    @ViewBuilder
    private func relatedSkillsSection(for resource: CapabilityResource, folderID: String) -> some View {
        let relations = model.capabilityFolders.companionSkills(for: resource.id, in: folderID)
        relationshipDetailGroups(
            title: t("capabilityFolders.companions.relatedSkills", "Companion Skills"),
            empty: t("capabilityFolders.companions.none", "No companion Skill recorded"),
            relations: relations,
            iconKind: .skill,
            folder: model.capabilityFolders.folder(withID: folderID)
        )
    }

    @ViewBuilder
    private func relatedAgentsSection(for resource: CapabilityResource, folderID: String) -> some View {
        let relations = model.capabilityFolders.relatedAgents(for: resource.id, in: folderID)
        relationshipDetailGroups(
            title: t("capabilityFolders.companions.relatedAgents", "Related Agents"),
            empty: t("capabilityFolders.companions.unassociated", "No Agent association recorded"),
            relations: relations,
            iconKind: .agent,
            folder: model.capabilityFolders.folder(withID: folderID)
        )
    }

    @ViewBuilder
    private func relationshipDetailGroups(
        title: String,
        empty: String,
        relations: [(resource: CapabilityResource, relation: CapabilityCompanionRelation, isPreview: Bool)],
        iconKind: ResourceKind,
        folder: CapabilityFolderDefinition?
    ) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text(title)
                .font(DirectorTypography.label.weight(.semibold))
                .foregroundStyle(DirectorColor.textSecondary)
            if relations.isEmpty {
                Text(empty)
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textTertiary)
            } else {
                Text(t("capabilityFolders.companions.declarationGroup", "Explicit declarations"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                ForEach(Array(relations.enumerated()), id: \.offset) { _, item in
                    Button { selectResource(item.resource.id) } label: {
                        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                            HStack {
                                Image(systemName: DirectorSymbol.resource(iconKind))
                                    .accessibilityHidden(true)
                                Text(item.resource.name).foregroundStyle(DirectorColor.textPrimary)
                                Spacer()
                                if item.isPreview, let folder { Text(companionPreviewLabel(for: item.resource, in: folder)).font(DirectorTypography.label) }
                            }
                            Text(relationshipDeclarationText(item.relation))
                                .font(DirectorTypography.label)
                                .foregroundStyle(DirectorColor.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Divider().overlay(DirectorColor.boundary)
                Text(t("capabilityFolders.companions.historyGroup", "Historical co-observation evidence"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                ForEach(Array(relations.enumerated()), id: \.offset) { _, item in
                    historicalEvidenceText(for: item.relation)
                }
                Text(t("capabilityFolders.companions.noCausalClaim", "Co-observation does not prove invocation."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
            }
        }
        .padding(.vertical, DirectorSpacing.space2)
    }

    @ViewBuilder
    private func historicalEvidenceText(for relation: CapabilityCompanionRelation) -> some View {
        let stats = model.capabilityCompanionUsageByRelationID[relation.id] ?? .unavailable
        let count = stats.sessionCount.map(String.init) ?? "—"
        let last = stats.lastObservedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        let coverage = coverageText(stats.coverage)
        Text("\(count) · \(last) · \(coverage)")
            .font(DirectorTypography.label)
            .foregroundStyle(DirectorColor.textSecondary)
    }

    private func coverageText(_ coverage: CoverageState) -> String {
        switch coverage {
        case .complete: return t("capabilityFolders.companions.coverage.complete", "Coverage complete")
        case .partial: return t("capabilityFolders.companions.coverage.partial", "Coverage partial")
        case .unavailable: return t("capabilityFolders.companions.coverage.unavailable", "Coverage unavailable")
        case .unknown: return t("capabilityFolders.companions.coverage.unknown", "Coverage unknown")
        }
    }

    private var globalSearchResults: [CapabilityFolderMember] {
        let query = entrySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return model.capabilityFolders.resources.filter { resource in
            let summary = CapabilityPurposeLocalization.localizedSummary(for: resource, language: languageStore.language) ?? ""
            return resource.name.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending || ($0.name == $1.name && $0.id < $1.id) }.map(CapabilityFolderMember.init)
    }

    private func folderMembers(_ folder: CapabilityFolderDefinition) -> [CapabilityFolderMember] {
        let query = (folderSearch(for: folder.id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = currentFolderTab(for: folder.id)
        let sort = folderSort(for: folder.id)
        return model.capabilityFolders.members(in: folder.id).filter { member in
            let matchesType: Bool
            switch tab {
            case .agentCompanions, .agents: matchesType = member.resource.kind == .agent
            case .skills: matchesType = member.resource.kind == .skill
            }
            let summary = CapabilityPurposeLocalization.localizedSummary(for: member.resource, language: languageStore.language) ?? ""
            let matchesSearch = query.isEmpty || member.resource.name.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query)
            return matchesType && matchesSearch
        }.sorted { lhs, rhs in
            switch sort {
            case .usageAscending:
                if let result = compareUsage(lhs.resource.id, rhs.resource.id, ascending: true) { return result }
            case .recentUsageDescending:
                if let result = compareUsage(lhs.resource.id, rhs.resource.id, ascending: false) { return result }
            case .nameAscending: break
            }
            let compare = lhs.resource.name.localizedStandardCompare(rhs.resource.name)
            return compare == .orderedSame ? lhs.id < rhs.id : compare == .orderedAscending
        }
    }

    private func recentCount(for id: String) -> Int? {
        guard model.hasComputedStatistics else { return nil }
        return model.recentCapabilityStats.first(where: { $0.resourceID == id })?.callCount ?? 0
    }

    private func recentUsageText(for id: String) -> String {
        "\(t("capabilityFolders.recentUsage", "Last 7 days")): \(recentCount(for: id).map(String.init) ?? "—")"
    }

    /// Unknown statistics are kept after known values rather than being
    /// silently treated as zero. The final name/ID tie-breaker remains
    /// deterministic for both known and unknown rows.
    private func compareUsage(_ lhsID: String, _ rhsID: String, ascending: Bool) -> Bool? {
        let lhs = recentCount(for: lhsID)
        let rhs = recentCount(for: rhsID)
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right { return nil }
            return ascending ? left < right : left > right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }

    private func folderTitle(_ folder: CapabilityFolderDefinition) -> String {
        folder.displayName(language: languageStore.language == .simplifiedChinese ? .simplifiedChinese : .english)
    }

    private func folderCounts(_ folder: CapabilityFolderDefinition) -> String {
        guard model.directoryLoaded else { return "—" }
        let members = model.capabilityFolders.members(in: folder.id)
        let agents = members.filter { $0.resource.kind == .agent }.count
        let skills = members.filter { $0.resource.kind == .skill }.count
        return "\(agents) \(t("capabilityFolders.agents", "Agents")) · \(skills) \(t("capabilityFolders.skills", "Skills"))"
    }

    private func scopeText(for resource: CapabilityResource) -> String {
        if resource.ownership == .pluginProvided { return t("capabilityFolders.global", "Global") }
        if let projectID = resource.projectID {
            let projectLabel = model.capabilityFolders.folders.first {
                $0.source == .project && $0.projectID == projectID
            }?.projectName ?? shortProjectID(projectID)
            return "\(t("capabilityFolders.project", "Project")) · \(projectLabel)"
        }
        return t("capabilityFolders.global", "Global")
    }

    private func sourceText(for resource: CapabilityResource) -> String {
        if resource.ownership == .pluginProvided {
            return t("capabilityFolders.source.plugin", "Plugin")
        }
        switch resource.ownership {
        case .installed:
            switch resource.origin {
            case .github: return t("capabilityFolders.source.github", "Installed · GitHub")
            case .registry: return t("capabilityFolders.source.registry", "Installed · Registry")
            default: return t("capabilityFolders.source.installed", "Installed")
            }
        case .userOwned: return t("capabilityFolders.source.custom", "Custom")
        default: return t("capabilityFolders.source.local", "Local")
        }
    }

    private func shortProjectID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        return String((compact.isEmpty ? value : compact).prefix(8))
    }

    private func emptyState(_ title: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(title).font(DirectorTypography.sectionTitle.weight(.semibold)).foregroundStyle(DirectorColor.textPrimary)
            Text(t("capabilityFolders.empty.hint", "Try another search or refresh the capability directory."))
                .font(DirectorTypography.supporting).foregroundStyle(DirectorColor.textSecondary)
        }
        .padding(.vertical, DirectorSpacing.space8)
        .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(rowInsets(for: width))
    }

    private func folderTabs(for folderID: String, width: CGFloat) -> some View {
        Picker(
            t("capabilityFolders.tabs.label", "Capability view"),
            selection: folderTabBinding(for: folderID)
        ) {
            Text(t("capabilityFolders.tabs.companions", "Agent & Companion Skills"))
                .tag(CapabilityFolderTab.agentCompanions)
            Text(t("capabilityFolders.tabs.agents", "Agents"))
                .tag(CapabilityFolderTab.agents)
            Text(t("capabilityFolders.tabs.skills", "Skills"))
                .tag(CapabilityFolderTab.skills)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: width < DirectorPageLayout.compactBreakpoint ? .infinity : 620)
        .accessibilityLabel(t("capabilityFolders.tabs.label", "Capability view"))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets(for: width))
    }

    private func sortMenu(for folderID: String) -> some View {
        let selected = folderSort(for: folderID)
        return Menu {
            ForEach(CapabilityFolderSort.allCases) { value in
                Button(value.title(languageStore.language)) { folderSortByKey[sessionKey(for: folderID)] = value }
            }
        } label: {
            Label(selected.title(languageStore.language), systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.visible)
        .accessibilityLabel(t("capabilityFolders.filter.sort", "Sort"))
    }

    private func createFolder() {
        do { _ = try model.createCapabilityFolder(named: createName); showsCreateSheet = false }
        catch { }
    }

    private func renameFolder(_ folder: CapabilityFolderDefinition) {
        do { try model.renameCapabilityFolder(id: folder.id, to: editName); editingFolder = nil }
        catch { }
    }

    private func deleteFolder(_ folder: CapabilityFolderDefinition) {
        do { try model.deleteCapabilityFolder(id: folder.id); if selectedFolderID == folder.id { selectedFolderID = nil } }
        catch { }
    }

    private func moveDraggedFolder(from source: Int, to destination: Int) {
        model.reorderCapabilityFolders(fromOffsets: IndexSet(integer: source), toOffset: destination)
    }

    private func folderSearchBinding(for folderID: String) -> Binding<String> {
        Binding(
            get: { folderSearch(for: folderID) ?? "" },
            set: { folderSearchByKey[sessionKey(for: folderID)] = $0 }
        )
    }

    private func folderTabBinding(for folderID: String) -> Binding<CapabilityFolderTab> {
        Binding(
            get: { folderTabByID[folderID] ?? .agentCompanions },
            set: { folderTabByID[folderID] = $0 }
        )
    }

    private func currentFolderTab(for folderID: String) -> CapabilityFolderTab {
        folderTabByID[folderID] ?? .agentCompanions
    }

    private func sessionKey(for folderID: String) -> CapabilityFolderSessionKey {
        CapabilityFolderSessionKey(folderID: folderID, tab: currentFolderTab(for: folderID))
    }

    private func folderSearch(for folderID: String) -> String? {
        folderSearchByKey[sessionKey(for: folderID)]
    }

    private func folderSort(for folderID: String) -> CapabilityFolderSort {
        folderSortByKey[sessionKey(for: folderID)] ?? .nameAscending
    }

    private func collapsedCompanionAgentIDs(for folderID: String) -> Set<String> {
        collapsedCompanionAgentIDsByKey[sessionKey(for: folderID)] ?? []
    }

    private var currentSelectedResourceID: String? {
        guard let selectedFolderID else { return entrySelectedResourceID }
        return selectedResourceIDByKey[sessionKey(for: selectedFolderID)] ?? nil
    }

    private func selectResource(_ resourceID: String) {
        guard let selectedFolderID else {
            entrySelectedResourceID = resourceID
            return
        }
        selectedResourceIDByKey[sessionKey(for: selectedFolderID)] = resourceID
    }

    private func clearSelectedResource() {
        guard let selectedFolderID else {
            entrySelectedResourceID = nil
            return
        }
        selectedResourceIDByKey[sessionKey(for: selectedFolderID)] = nil
    }

    private var activeScrollPosition: Binding<String?> {
        Binding(
            get: {
                guard let selectedFolderID else { return entryScrollPosition }
                return folderScrollPositionByKey[sessionKey(for: selectedFolderID)] ?? nil
            },
            set: { value in
                guard let selectedFolderID else {
                    entryScrollPosition = value ?? "capability-folders-entry-top"
                    return
                }
                folderScrollPositionByKey[sessionKey(for: selectedFolderID)] = value
            }
        )
    }

    private func rowInsets(for width: CGFloat) -> EdgeInsets {
        EdgeInsets(top: 0, leading: DirectorPageLayout.listRowInset(for: width), bottom: 0, trailing: DirectorPageLayout.listRowInset(for: width))
    }

    private func t(_ key: String, _ fallback: String) -> String { languageStore.localizer.text(key, fallback: fallback) }
}

private enum CapabilityFolderTypeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, agent, skill
    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self { case .all: return language == .simplifiedChinese ? "全部类型" : "All types"; case .agent: return "Agent"; case .skill: return "Skill" }
    }
}

/// Native drag-and-drop reordering for the custom folder grid. The menu's
/// up/down actions remain available for keyboard and VoiceOver users.
private struct CapabilityFolderDropDelegate: DropDelegate {
    let targetID: String
    let orderedIDs: [String]
    @Binding var draggingID: String?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != targetID,
              let sourceIndex = orderedIDs.firstIndex(of: draggingID),
              let targetIndex = orderedIDs.firstIndex(of: targetID) else { return }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        move(sourceIndex, destination)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private enum CapabilityFolderSort: String, CaseIterable, Identifiable, Sendable {
    case recentUsageDescending
    case usageAscending
    case nameAscending
    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .recentUsageDescending: return language == .simplifiedChinese ? "近 7 天调用" : "Recent usage"
        case .usageAscending: return language == .simplifiedChinese ? "调用量升序" : "Usage ascending"
        case .nameAscending: return language == .simplifiedChinese ? "名称 A–Z" : "Name A–Z"
        }
    }
}

/// Pull-style organizer for adding already indexed capabilities to a custom
/// folder. The selection is staged locally and committed in one preference
/// write, so cancellation or persistence failure cannot leave a partial import.
private struct CapabilityFolderImportSheet: View {
    @ObservedObject var model: DirectorAppModel
    let folder: CapabilityFolderDefinition

    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var typeFilter: CapabilityFolderTypeFilter = .all
    @State private var selectedIDs: Set<String> = []

    private var existingIDs: Set<String> {
        Set(model.capabilityFolders.members(in: folder.id).map(\.id))
    }

    private var filteredResources: [CapabilityResource] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.capabilityFolders.resources.filter { resource in
            let matchesType = typeFilter == .all
                || (typeFilter == .agent && resource.kind == .agent)
                || (typeFilter == .skill && resource.kind == .skill)
            let summary = CapabilityPurposeLocalization.localizedSummary(
                for: resource,
                language: languageStore.language
            ) ?? ""
            let matchesSearch = query.isEmpty
                || resource.name.localizedCaseInsensitiveContains(query)
                || summary.localizedCaseInsensitiveContains(query)
            return matchesType && matchesSearch
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(t("capabilityFolders.import.title", "Add existing capabilities"))
                    .font(DirectorTypography.sectionTitle.weight(.semibold))
                Text(folder.displayName(language: languageStore.language == .simplifiedChinese ? .simplifiedChinese : .english))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }

            DirectorControlField {
                HStack(spacing: DirectorSpacing.space2) {
                    Image(systemName: DirectorSymbol.search)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .accessibilityHidden(true)
                    TextField(t("capabilityFolders.import.search", "Search Agents and Skills"), text: $search)
                        .textFieldStyle(.plain)
                }
            }

            Picker(t("capabilityFolders.filter.type", "Type filter"), selection: $typeFilter) {
                ForEach(CapabilityFolderTypeFilter.allCases) { filter in
                    Text(filter.title(languageStore.language)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(t("capabilityFolders.filter.type", "Type filter"))

            Group {
                if filteredResources.isEmpty {
                    ContentUnavailableView(
                        t("capabilityFolders.import.empty", "No capabilities are available to add."),
                        systemImage: "folder.badge.questionmark"
                    )
                } else {
                    List(filteredResources) { resource in
                        let alreadyIncluded = existingIDs.contains(resource.id)
                        Toggle(
                            isOn: Binding(
                                get: { alreadyIncluded || selectedIDs.contains(resource.id) },
                                set: { selected in
                                    guard !alreadyIncluded else { return }
                                    if selected { selectedIDs.insert(resource.id) }
                                    else { selectedIDs.remove(resource.id) }
                                }
                            )
                        ) {
                            HStack(spacing: DirectorSpacing.space3) {
                                Image(systemName: DirectorSymbol.resource(resource.kind))
                                    .foregroundStyle(DirectorColor.resource(resource.kind))
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                                    Text(resource.name)
                                        .font(DirectorTypography.capabilityRowTitle)
                                        .lineLimit(1)
                                    Text(resource.kind == .agent ? "Agent" : "Skill")
                                        .font(DirectorTypography.label)
                                        .foregroundStyle(DirectorColor.textSecondary)
                                }
                                Spacer()
                                if alreadyIncluded {
                                    Text(t("capabilityFolders.import.added", "Added"))
                                        .font(DirectorTypography.label)
                                        .foregroundStyle(DirectorColor.textTertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(alreadyIncluded)
                        .accessibilityHint(
                            alreadyIncluded
                                ? t("capabilityFolders.import.addedHint", "Already in this folder")
                                : t("capabilityFolders.import.selectHint", "Select to add to this folder")
                        )
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 300, maxHeight: .infinity)

            HStack {
                Text(t("capabilityFolders.import.selected", "Selected: %d", selectedIDs.count))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
                Spacer()
                Button(t("common.cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("capabilityFolders.import.confirm", "Add selected")) {
                    do {
                        try model.addCapabilitiesToFolder(resourceIDs: selectedIDs, folderID: folder.id)
                        dismiss()
                    } catch {
                        // The app model owns the privacy-safe localized error.
                        // Keep this sheet and the staged selection in place so
                        // the user can retry without reconstructing the batch.
                    }
                }
                .buttonStyle(DirectorPrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(DirectorSpacing.space6)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .alert(
            t("capabilityFolders.error", "Unable to save folder"),
            isPresented: Binding(
                get: { model.capabilityFolderError != nil },
                set: { if !$0 { model.clearCapabilityFolderError() } }
            )
        ) {
            Button(t("capabilityFolders.import.ok", "OK")) { model.clearCapabilityFolderError() }
        } message: {
            Text(t(model.capabilityFolderError ?? "capabilityFolders.saveFailed", "Please try again."))
        }
    }

    private func t(_ key: String, _ fallback: String) -> String {
        languageStore.localizer.text(key, fallback: fallback)
    }

    private func t(_ key: String, _ fallback: String, _ value: Int) -> String {
        String(format: languageStore.localizer.text(key, fallback: fallback), value)
    }
}

private struct FolderNameSheet: View {
    let title: String
    let prompt: String
    @Binding var name: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @EnvironmentObject private var languageStore: AppLanguageStore
    var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
            Text(title).font(DirectorTypography.sectionTitle.weight(.semibold))
            TextField(prompt, text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(languageStore.localizer.text("common.cancel", fallback: "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm).keyboardShortcut(.defaultAction).buttonStyle(DirectorPrimaryActionButtonStyle())
            }
        }
        .padding(DirectorSpacing.space6)
        .frame(width: 420)
    }
}
