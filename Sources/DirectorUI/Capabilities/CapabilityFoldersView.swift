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
    // A non-nil anchor also gives the native scroll view a stable initial target.
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
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let selectedFolderID,
                           let folder = model.capabilityFolders.folder(withID: selectedFolderID) {
                            folderPage(folder, width: proxy.size.width)
                        } else {
                            entryPage(width: proxy.size.width)
                        }
                    }
                    .frame(maxWidth: DirectorCapabilityFolderLayout.maxContentWidth, alignment: .leading)
                    .padding(.bottom, DirectorCapabilityFolderLayout.pageBottomPadding)
                    .padding(.horizontal, DirectorCapabilityFolderLayout.horizontalPadding(for: proxy.size.width))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .background(Color.clear)
                #if DEBUG
                .background(UIValidationCaptureMarker().allowsHitTesting(false).accessibilityHidden(true))
                #endif
                .scrollPosition(id: activeScrollPosition, anchor: .top)
                // Keep the overlay's layout box equal to the scroll viewport.
                // A bare ViewBuilder with scrim + sheet siblings sizes the
                // overlay to the sheet and centers it; the explicit ZStack
                // lets the sheet remain pinned to the content trailing edge.
                .overlay(alignment: .trailing) {
                    detailSheet(width: proxy.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
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
        VStack(alignment: .leading, spacing: 0) {
            entryHeaderAndSearch(width: width)
        }
        .scrollTargetLayout()
        folderStatusBanner(width: width, topGap: entrySectionGap(for: width))
        if entrySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            structuralRow(
                sectionHeader("\(t("capabilityFolders.myFolders", "My Folders")) \(model.capabilityFolders.folders.filter(\.isCustom).count)", action: newFolderButton),
                width: width,
                top: entrySectionGap(for: width)
            )
            folderGrid(model.capabilityFolders.folders.filter(\.isCustom), width: width)
                .padding(.top, DirectorCapabilityFolderLayout.sectionContentGap)
            structuralRow(
                sectionHeader("\(t("capabilityFolders.defaults", "Global & Projects")) \(model.capabilityFolders.folders.filter(\.isDefault).count)"),
                width: width,
                top: sectionGap(for: width)
            )
            folderGrid(model.capabilityFolders.folders.filter(\.isDefault), width: width)
                .padding(.top, DirectorCapabilityFolderLayout.sectionContentGap)
        } else if !model.directoryLoaded {
            pendingState(width: width)
        } else {
            structuralRow(
                sectionHeader(t("capabilityFolders.searchResults", "Search results · all capabilities")),
                width: width,
                top: entrySectionGap(for: width)
            )
            if globalSearchResults.isEmpty {
                emptyState(
                    t("capabilityFolders.empty.search", "No capabilities match this search."),
                    width: width,
                    actionTitle: t("capabilityFolders.clearSearch", "Clear search"),
                    action: { entrySearch = "" }
                )
                .padding(.top, DirectorCapabilityFolderLayout.sectionContentGap)
            } else {
                memberListPanel(globalSearchResults, folder: nil, width: width)
                    .padding(.top, DirectorCapabilityFolderLayout.sectionContentGap)
            }
        }
    }

    @ViewBuilder
    private func folderPage(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            folderHeader(folder, width: width)
        }
        .scrollTargetLayout()

        folderTabs(for: folder.id, width: width)

        folderFilterRow(for: folder.id, width: width)

        folderStatusBanner(width: width)
            .padding(.bottom, DirectorCapabilityFolderLayout.filterContentGap)
        if !model.directoryLoaded {
            pendingState(width: width)
        } else {
            let allMembers = model.capabilityFolders.members(in: folder.id)
            let members = folderMembers(folder)
            let hasQuery = !(folderSearch(for: folder.id) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if members.isEmpty {
                if !hasQuery,
                   currentFolderTab(for: folder.id) == .agentCompanions,
                   allMembers.contains(where: { $0.resource.kind == .skill }) {
                    // A folder containing only Skills still gets the relationship
                    // view's route into the complete Skill list instead of a
                    // misleading empty-directory message.
                    companionListPanel([], folder: folder, width: width)
                } else {
                    emptyState(
                        hasQuery
                            ? t("capabilityFolders.empty.matches", "No capabilities match this search.")
                            : folder.isCustom
                            ? t("capabilityFolders.empty.custom", "This folder is empty. Add capabilities from a list or detail view.")
                            : t("capabilityFolders.empty.none", "No Agents or Skills are available here."),
                        width: width,
                        actionTitle: hasQuery
                            ? t("capabilityFolders.clearSearch", "Clear search")
                            : folder.isCustom
                            ? t("capabilityFolders.import", "Add existing capabilities")
                            : nil,
                        action: hasQuery
                            ? { folderSearchByKey[sessionKey(for: folder.id)] = "" }
                            : folder.isCustom
                            ? { importTargetFolder = folder }
                            : nil
                    )
                }
            } else {
                Group {
                    if currentFolderTab(for: folder.id) == .agentCompanions {
                        companionListPanel(members, folder: folder, width: width)
                    } else {
                        memberListPanel(members, folder: folder, width: width)
                    }
                }
            }
        }
    }

    /// Shows a compact, non-blocking status signal while preserving whatever
    /// folder content is already on screen. These states are intentionally
    /// derived from the existing AppModel refresh and cache signals; no new
    /// data or failure channel is introduced for this presentation surface.
    @ViewBuilder
    private func folderStatusBanner(width: CGFloat, topGap: CGFloat = 0) -> some View {
        let hasFailure = model.backgroundRefreshError != nil
            || model.indexingError != nil
            || hasPresentationFailure
        let isStale = model.directoryLoaded && !model.sourceDataFresh
        if model.isRefreshing || hasFailure || isStale {
            HStack(spacing: DirectorSpacing.space2) {
                Image(systemName: model.isRefreshing
                      ? "arrow.triangle.2.circlepath"
                      : hasFailure
                      ? "exclamationmark.triangle"
                      : "clock.arrow.circlepath")
                    .accessibilityHidden(true)
                Text(model.isRefreshing
                     ? t("capabilityFolders.status.updating", "Updating… Showing the last available data.")
                     : hasFailure
                     ? t("capabilityFolders.status.failed", "Background update failed. Showing the last available data.")
                     : t("capabilityFolders.status.stale", "Needs update. Showing the last available data."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: DirectorSpacing.space2)
                if !model.isRefreshing {
                    Button(t("capabilityFolders.status.retry", "Retry")) {
                        Task { await model.startIndexing() }
                    }
                    .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                }
            }
            .padding(.horizontal, DirectorSpacing.space3)
            .padding(.vertical, DirectorSpacing.space2)
            .background(DirectorColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(DirectorColor.controlBoundary, lineWidth: 1)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isRefreshing
                                ? t("capabilityFolders.status.updating", "Updating… Showing the last available data.")
                                : hasFailure
                                ? t("capabilityFolders.status.failed", "Background update failed. Showing the last available data.")
                                : t("capabilityFolders.status.stale", "Needs update. Showing the last available data."))
            .padding(.top, topGap)
        }
    }

    private var hasPresentationFailure: Bool {
        if case .failure = model.presentationState { return true }
        return false
    }

    private func pendingState(width: CGFloat) -> some View {
        VStack(alignment: .center, spacing: DirectorSpacing.space3) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(t("capabilityFolders.pending", "Loading capability directory…"))
            Text(t("capabilityFolders.pending", "Loading capability directory…"))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: DirectorSpacing.space2) {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(DirectorColor.boundary.opacity(0.42))
                    .frame(width: 72, height: 8)
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(DirectorColor.boundary.opacity(0.30))
                    .frame(width: 48, height: 8)
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, DirectorSpacing.space6)
        .background(DirectorColor.panel)
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(
                    DirectorColor.controlBoundary,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
                .accessibilityHidden(true)
        }
    }

    private func entryHeaderAndSearch(width: CGFloat) -> some View {
        // Instantiate only one native text field. ViewThatFits candidates
        // sharing this binding can re-enter AppKit's accessibility graph
        // when a focused search is cleared while content blocks change.
        Group {
            if width >= DirectorCapabilityFolderLayout.entryInlineBreakpoint {
                HStack(alignment: .lastTextBaseline, spacing: DirectorSpacing.space6) {
                    entryTitleBlock(width: width)
                        .layoutPriority(1)
                    Spacer(minLength: DirectorSpacing.space4)
                    entrySearchField
                        .frame(width: min(360, max(260, DirectorCapabilityFolderLayout.contentWidth(for: width) * 0.32)))
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    entryTitleBlock(width: width)
                    entrySearchField
                }
            }
        }
        .padding(.top, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorSpacing.space4 : DirectorSpacing.space6)
        .id("capability-folders-entry-top")
    }

    private func entryTitleBlock(width: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(t("capabilityFolders.title", "Capability Folders"))
                .font(.system(size: width < DirectorCapabilityFolderLayout.compactBreakpoint ? 28 : 32, weight: .semibold, design: .default))
                .foregroundStyle(DirectorColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(t("capabilityFolders.subtitle", "From global to project, understand and organize your capabilities."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        }
    }

    private var entrySearchField: some View {
        CapabilityFolderControlField {
            HStack(spacing: DirectorSpacing.space2) {
                Image(systemName: DirectorSymbol.search)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityHidden(true)
                TextField(t("capabilityFolders.search", "Search all Agents and Skills"), text: $entrySearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(t("capabilityFolders.search", "Search all Agents and Skills"))
                if !entrySearch.isEmpty {
                    Button { entrySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(DirectorColor.textSecondary)
                        .accessibilityLabel(t("capabilityFolders.clearSearch", "Clear search"))
                }
            }
        }
    }

    private func sectionHeader(_ title: String, action: AnyView? = nil) -> some View {
        HStack {
            Text(title)
                .font(DirectorTypography.sectionTitle.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action { action }
        }
    }

    private var newFolderButton: AnyView {
        AnyView(Button {
            createName = ""
            showsCreateSheet = true
        } label: {
            Label(t("capabilityFolders.add", "New folder"), systemImage: "plus")
        }
        .buttonStyle(DirectorSecondaryActionButtonStyle()))
    }

    private func folderHeader(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            HStack(spacing: DirectorSpacing.space2) {
                Button {
                    selectedFolderID = nil
                } label: {
                    Label(t("capabilityFolders.back", "Capability Folders"), systemImage: "chevron.left")
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if folder.isCustom {
                    Button {
                        importTargetFolder = folder
                    } label: {
                        Label(t("capabilityFolders.import", "Add existing capabilities"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                    folderActions(folder)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: DirectorSpacing.space4) {
                    folderTitleBlock(folder, width: width)
                    Spacer(minLength: DirectorSpacing.space4)
                    folderCountBlock(folder)
                }
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    folderTitleBlock(folder, width: width)
                    folderCountBlock(folder)
                }
            }
        }
        .padding(.top, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorSpacing.space4 : DirectorSpacing.space6)
        .padding(.bottom, 0)
        .id("capability-folder-top-\(folder.id)-\(currentFolderTab(for: folder.id).rawValue)")
        .accessibilityElement(children: .contain)
    }

    private func folderTitleBlock(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                Image(systemName: folder.isDefault && folder.source == .global ? "globe" : "folder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DirectorColor.accent(folder.isDefault ? .ice : .teal))
                    .accessibilityHidden(true)
                Text(folderTitle(folder))
                    .font(.system(size: width < DirectorCapabilityFolderLayout.compactBreakpoint ? 28 : 32, weight: .semibold, design: .default))
                    .foregroundStyle(DirectorColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(folder.isDefault
                 ? t("capabilityFolders.defaultSubtitle", "Browse capabilities by configuration ownership.")
                 : t("capabilityFolders.customSubtitle", "A personal, local collection of capabilities."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderCountBlock(_ folder: CapabilityFolderDefinition) -> some View {
        Text(folderCounts(folder))
            .font(DirectorTypography.label.monospacedDigit())
            .foregroundStyle(DirectorColor.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(folderCounts(folder))
    }

    private func folderFilterRow(for folderID: String, width: CGFloat) -> some View {
        // As with the entry search, keep a single native editor per layout.
        Group {
            if width >= DirectorCapabilityFolderLayout.compactBreakpoint {
                HStack(spacing: DirectorSpacing.space3) {
                    folderSearchField(for: folderID)
                        .frame(maxWidth: .infinity)
                    sortMenu(for: folderID)
                }
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    folderSearchField(for: folderID)
                    HStack {
                        Spacer()
                        sortMenu(for: folderID)
                    }
                }
            }
        }
        .padding(.bottom, DirectorCapabilityFolderLayout.filterContentGap)
    }

    private func folderSearchField(for folderID: String) -> some View {
        CapabilityFolderControlField {
            HStack(spacing: DirectorSpacing.space2) {
                Image(systemName: DirectorSymbol.search)
                    .foregroundStyle(DirectorColor.textSecondary)
                    .accessibilityHidden(true)
                TextField(t("capabilityFolders.searchInside", "Search this folder"), text: folderSearchBinding(for: folderID))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(t("capabilityFolders.searchInside", "Search this folder"))
            }
        }
    }

    private func folderGrid(_ folders: [CapabilityFolderDefinition], width: CGFloat) -> some View {
        // The local folder grid supersedes DirectorAdaptiveGrid.items(for:
        // here so its four/three/two/one breakpoints are based on the actual
        // content viewport instead of the global 4/2/1 contract.
        LazyVGrid(
            columns: DirectorCapabilityFolderLayout.gridItems(for: width),
            alignment: .leading,
            spacing: width < DirectorCapabilityFolderLayout.compactBreakpoint
                ? DirectorCapabilityFolderLayout.folderGridGapCompact
                : DirectorCapabilityFolderLayout.folderGridGap
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
        .scrollTargetLayout()
        .accessibilityElement(children: .contain)
    }

    private func folderCard(_ folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { selectedFolderID = folder.id } label: {
                VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                    HStack(spacing: DirectorSpacing.space3) {
                        Image(systemName: folder.isDefault && folder.source == .global ? "globe" : folder.isDefault ? "folder" : "folder.fill")
                            .foregroundStyle(DirectorColor.accent(folder.isDefault ? .ice : .teal))
                            .font(.title3)
                            .accessibilityHidden(true)
                        Text(folderTitle(folder))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DirectorColor.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: DirectorSpacing.space8)
                    }
                    Spacer(minLength: DirectorSpacing.space1)
                    HStack {
                        Text(folderCounts(folder))
                            .font(DirectorTypography.supporting.monospacedDigit())
                            .foregroundStyle(DirectorColor.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DirectorColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, DirectorSpacing.space4)
                .padding(.vertical, DirectorSpacing.space3)
                .frame(maxWidth: .infinity, minHeight: DirectorCapabilityFolderLayout.cardHeight(for: width), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if folder.isCustom {
                folderActions(folder)
                    .padding(.top, DirectorSpacing.space2)
                    .padding(.trailing, DirectorSpacing.space2)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .fill(folder.source == .global ? DirectorColor.folderGlobalSurface : DirectorColor.panel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(DirectorColor.boundary, lineWidth: 1)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("\(folderTitle(folder)), \(folderCounts(folder))")
    }

    private func folderActions(_ folder: CapabilityFolderDefinition) -> some View {
        DirectorOutlinedIconMenu(systemImage: "ellipsis.circle") {
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
        }
        .accessibilityLabel(t("capabilityFolders.actions", "Folder actions"))
    }

    @ViewBuilder
    private func memberListPanel(_ members: [CapabilityFolderMember], folder: CapabilityFolderDefinition?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(DirectorColor.boundary.opacity(0.72))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                if let folder, currentFolderTab(for: folder.id) == .skills {
                    skillRelationshipRow(member, folder: folder, width: width)
                        .id(member.id)
                } else {
                    memberRow(member, folder: folder, width: width)
                        .id(member.id)
                }
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.vertical, DirectorSpacing.space2)
        .background(DirectorColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(DirectorColor.boundary, lineWidth: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func companionListPanel(_ members: [CapabilityFolderMember], folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        let agents = members.filter { $0.resource.kind == .agent }
        let skills = model.capabilityFolders.members(in: folder.id).filter { $0.resource.kind == .skill }
        let representedSkills = Set(agents.flatMap { agent in
            model.capabilityFolders.companionSkills(for: agent.id, in: folder.id)
                .filter { !$0.isPreview }
                .map { $0.resource.id }
        })
        let hasUnrepresentedSkills = skills.contains { !representedSkills.contains($0.id) }

        VStack(alignment: .leading, spacing: width < DirectorCapabilityFolderLayout.compactBreakpoint
               ? DirectorCapabilityFolderLayout.agentGroupGapCompact
               : DirectorCapabilityFolderLayout.agentGroupGap) {
            ForEach(agents) { member in
                agentCompanionRow(member, folder: folder, width: width)
                    .id(member.id)
            }
            if hasUnrepresentedSkills {
                Button {
                    folderTabByID[folder.id] = .skills
                } label: {
                    HStack(spacing: DirectorSpacing.space2) {
                        Image(systemName: DirectorSymbol.resource(.skill))
                            .accessibilityHidden(true)
                        Text(t("capabilityFolders.companions.unrepresentedHint", "Some Skills are not represented by a declared Agent relationship. View all Skills."))
                            .multilineTextAlignment(.leading)
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                    }
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.emphasis)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DirectorSpacing.space2)
                .padding(.top, DirectorSpacing.space1)
                .accessibilityHint(t("capabilityFolders.companions.unrepresentedHintAX", "Switches to the complete Skill list."))
            }
        }
        .scrollTargetLayout()
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
                    }
                    Spacer(minLength: DirectorSpacing.space2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(member.resource.name), \(member.resource.kind == .agent ? t("capabilityFolders.agent", "Agent") : t("capabilityFolders.skill", "Skill"))")
            folderMembershipMenu(member.resource, currentFolder: folder)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DirectorColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DirectorSpacing.space3)
    }

    private func agentCompanionRow(_ member: CapabilityFolderMember, folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        let relations = model.capabilityFolders.companionSkills(for: member.id, in: folder.id)
        let isCollapsed = isCompanionCollapsed(for: member.id, folderID: folder.id)
        return VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            memberRow(member, folder: folder, width: width)
            if relations.isEmpty {
                Text(t("capabilityFolders.companions.none", "No companion Skill recorded"))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textTertiary)
                    .padding(.leading, DirectorCapabilityFolderLayout.skillIndent)
            } else {
                VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                    Button {
                        // Resolve the initial disclosure state only until the
                        // first interaction. Subsequent toggles must mutate
                        // the user's current set instead of rebuilding it.
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
                    .padding(.leading, DirectorCapabilityFolderLayout.skillIndent)
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
                                                .lineLimit(2)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(DirectorColor.textTertiary)
                                                .accessibilityHidden(true)
                                        }
                                        Text(CapabilityPurposeLocalization.localizedSummary(for: item.resource, language: languageStore.language) ?? t("capabilityFolders.purposeUnavailable", "Purpose unavailable"))
                                            .font(DirectorTypography.label)
                                            .foregroundStyle(DirectorColor.textSecondary)
                                            .lineLimit(2)
                                        Text(relationshipDeclarationText(item.relation))
                                            .font(DirectorTypography.label)
                                            .foregroundStyle(DirectorColor.textSecondary)
                                        HStack(spacing: DirectorSpacing.space2) {
                                            if item.isPreview {
                                                Text(companionPreviewLabel(for: item.resource, in: folder))
                                            }
                                            if let sharedAgents = sharedAgentsLabel(for: item.resource.id) {
                                                Text(sharedAgents)
                                            }
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
                        .padding(.leading, DirectorCapabilityFolderLayout.skillIndent + DirectorCapabilityFolderLayout.skillRuleInset)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(DirectorColor.boundary)
                                .frame(width: DirectorCapabilityFolderLayout.skillRuleWidth)
                                .padding(.leading, DirectorCapabilityFolderLayout.skillIndent)
                        }
                        .padding(.bottom, DirectorSpacing.space3)
                    }
                }
            }
        }
        .padding(.top, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorCapabilityFolderLayout.agentHeaderTopPaddingCompact : DirectorCapabilityFolderLayout.agentHeaderTopPadding)
        .padding(.horizontal, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorCapabilityFolderLayout.agentHeaderHorizontalPaddingCompact : DirectorCapabilityFolderLayout.agentHeaderHorizontalPadding)
        .padding(.bottom, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorCapabilityFolderLayout.agentHeaderBottomPaddingCompact : DirectorCapabilityFolderLayout.agentHeaderBottomPadding)
        .background(DirectorColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(DirectorColor.boundary, lineWidth: 1)
                .accessibilityHidden(true)
        }
    }

    private func skillRelationshipRow(_ member: CapabilityFolderMember, folder: CapabilityFolderDefinition, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            // Keep the Skill tab flat. Reverse Agent links remain available
            // from the detail sheet, alongside a concise row status.
            memberRow(member, folder: folder, width: width)
            Text(skillAgentLinkStatus(for: member.id, folderID: folder.id))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textTertiary)
                .padding(.bottom, DirectorSpacing.space3)
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
        let relations = model.capabilityFolders.companionSkills(for: agentID, in: folderID)
        let count = Set(
            relations
                .filter { !$0.isPreview }
                .map { $0.resource.id }
        ).count
        let previewCount = Set(relations.filter(\.isPreview).map { $0.resource.id }).count
        if previewCount > 0 {
            let previews = String(format: t("capabilityFolders.companions.previewCount", "%d related previews"), previewCount)
            return count == 0 ? previews
                : "\(String(format: t("capabilityFolders.companions.count", "%d companion Skills"), count)) · \(previews)"
        }
        return count == 0
            ? t("capabilityFolders.companions.none", "No companion Skill recorded")
            : String(format: t("capabilityFolders.companions.count", "%d companion Skills"), count)
    }

    private func sharedAgentsLabel(for skillID: String) -> String? {
        let count = Set(
            model.capabilityFolders.companionRelations
                .filter { $0.skillID == skillID }
                .map(\.agentID)
        ).count
        guard count > 1 else { return nil }
        return String(format: t("capabilityFolders.companions.sharedAgents", "Shared by %d Agents"), count)
    }

    private func skillAgentLinkStatus(for skillID: String, folderID: String) -> String {
        let hasLinks = !model.capabilityFolders.relatedAgents(for: skillID, in: folderID).isEmpty
        return hasLinks
            ? t("capabilityFolders.companions.agentLinksRecorded", "Agent links recorded")
            : t("capabilityFolders.companions.noAgentLinksRecorded", "No Agent links recorded")
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

    private func folderMembershipMenu(_ resource: CapabilityResource, currentFolder: CapabilityFolderDefinition?) -> some View {
        DirectorOutlinedIconMenu(systemImage: "folder.badge.plus") {
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
        }
        .accessibilityLabel(t("capabilityFolders.addToFolder", "Add to folder"))
        .disabled(model.capabilityFolders.folders.filter(\.isCustom).isEmpty)
    }

    @ViewBuilder private func detailSheet(width: CGFloat) -> some View {
        if let selectedResourceID = currentSelectedResourceID,
           let resource = model.capabilityFolders.resources.first(where: { $0.id == selectedResourceID }),
           let detailContext {
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelectedResource() }
                    .accessibilityHidden(true)
                DirectorSideSheet(
                    width: width < DirectorCapabilityFolderLayout.narrowBreakpoint
                        ? max(0, width - DirectorCapabilityFolderLayout.compactPagePadding * 2)
                        : DirectorCapabilityFolderLayout.detailWidth,
                    onClose: { clearSelectedResource() },
                    closeLabel: t("detail.close", "Close detail")
                ) {
                    CapabilityDetailView(
                        model: detailContext(resource),
                        showsBackButton: false,
                        contextualContent: AnyView(folderDetailContext(for: resource))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func folderDetailContext(for resource: CapabilityResource) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            if let folderID = selectedFolderID {
                if resource.kind == .agent {
                    relatedSkillsSection(for: resource, folderID: folderID)
                } else if resource.kind == .skill {
                    relatedAgentsSection(for: resource, folderID: folderID)
                }
            }
            folderMembershipMenu(resource, currentFolder: selectedFolderID.flatMap(model.capabilityFolders.folder(withID:)))
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

    private func emptyState(
        _ title: String,
        width: CGFloat,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .center, spacing: DirectorSpacing.space3) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(DirectorColor.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(DirectorTypography.sectionTitle.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(t("capabilityFolders.empty.hint", "Try another search or refresh the capability directory."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, DirectorSpacing.space6)
        .background(DirectorColor.panel)
        .overlay {
            RoundedRectangle(cornerRadius: DirectorRadius.contentPanel, style: .continuous)
                .stroke(
                    DirectorColor.controlBoundary,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
                .accessibilityHidden(true)
        }
    }

    private func folderTabs(for folderID: String, width: CGFloat) -> some View {
        DirectorOutlinedSegmentedControl(
            t("capabilityFolders.tabs.label", "Capability view"),
            selection: folderTabBinding(for: folderID),
            options: [
                .init(
                    value: .agentCompanions,
                    title: t("capabilityFolders.tabs.companions", "Agent & Companion Skills")
                ),
                .init(
                    value: .agents,
                    title: "\(t("capabilityFolders.tabs.agents", "Agents")) \(tabCount(for: folderID, kind: .agent))"
                ),
                .init(
                    value: .skills,
                    title: "\(t("capabilityFolders.tabs.skills", "Skills")) \(tabCount(for: folderID, kind: .skill))"
                )
            ]
        )
        .frame(maxWidth: width < DirectorCapabilityFolderLayout.compactBreakpoint ? .infinity : 620, alignment: .leading)
        .padding(.top, width < DirectorCapabilityFolderLayout.compactBreakpoint
                 ? DirectorCapabilityFolderLayout.headerTabsGapCompact
                 : DirectorCapabilityFolderLayout.headerTabsGap)
        .padding(.bottom, DirectorCapabilityFolderLayout.tabsFilterGap)
    }

    private func tabCount(for folderID: String, kind: ResourceKind) -> String {
        guard model.directoryLoaded else { return "—" }
        return String(model.capabilityFolders.members(in: folderID).filter { $0.resource.kind == kind }.count)
    }

    private func sortMenu(for folderID: String) -> some View {
        let selected = folderSort(for: folderID)
        return DirectorOutlinedMenuField(selected.title(languageStore.language)) {
            ForEach(CapabilityFolderSort.allCases) { value in
                Button {
                    folderSortByKey[sessionKey(for: folderID)] = value
                } label: {
                    HStack {
                        Text(value.title(languageStore.language))
                        if value == selected { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .frame(width: DirectorCapabilityFolderLayout.sortFieldWidth)
        .frame(minHeight: DirectorCapabilityFolderLayout.controlHeight, alignment: .leading)
        .accessibilityLabel(t("capabilityFolders.filter.sort", "Sort"))
        .accessibilityValue(selected.title(languageStore.language))
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
        collapsedCompanionAgentIDsByKey[sessionKey(for: folderID)] ?? initialCollapsedCompanionAgents(for: folderID)
    }

    private func initialCollapsedCompanionAgents(for folderID: String) -> Set<String> {
        let orderedAgents = model.capabilityFolders.members(in: folderID)
            .filter { $0.resource.kind == .agent }
        guard let firstRelated = orderedAgents.first(where: {
            !model.capabilityFolders.companionSkills(for: $0.id, in: folderID).isEmpty
        })?.id else {
            return []
        }
        return Set(orderedAgents.map(\.id).filter { $0 != firstRelated })
    }

    private func isCompanionCollapsed(for agentID: String, folderID: String) -> Bool {
        collapsedCompanionAgentIDs(for: folderID).contains(agentID)
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
        // Retain the callback's context even while another folder/tab is
        // being laid out, rather than recording its target in the new tab.
        let key = selectedFolderID.map { sessionKey(for: $0) }
        return Binding(
            get: {
                guard let key else { return entryScrollPosition }
                return (folderScrollPositionByKey[key] ?? nil)
                    ?? "capability-folder-top-\(key.folderID)-\(key.tab.rawValue)"
            },
            set: { value in
                // Missing targets during a context transition must not
                // erase that context's last valid scroll target.
                guard let value else { return }
                guard let key else {
                    entryScrollPosition = value
                    return
                }
                folderScrollPositionByKey[key] = value
            }
        )
    }

    /// Structural headings share the scroll content's common grid and
    /// own only their named inter-block rhythm.
    private func structuralRow<Content: View>(_ content: Content, width: CGFloat, top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        content
            .padding(.top, top)
            .padding(.bottom, bottom)
            .accessibilityElement(children: .contain)
    }

    private func entrySectionGap(for width: CGFloat) -> CGFloat {
        width < DirectorCapabilityFolderLayout.compactBreakpoint
            ? DirectorCapabilityFolderLayout.entrySectionGapCompact
            : DirectorCapabilityFolderLayout.entrySectionGap
    }

    private func sectionGap(for width: CGFloat) -> CGFloat {
        width < DirectorCapabilityFolderLayout.compactBreakpoint
            ? DirectorCapabilityFolderLayout.sectionGapCompact
            : DirectorCapabilityFolderLayout.sectionGap
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

            DirectorOutlinedSegmentedControl(
                t("capabilityFolders.filter.type", "Type filter"),
                selection: $typeFilter,
                options: CapabilityFolderTypeFilter.allCases.map {
                    .init(value: $0, title: $0.title(languageStore.language))
                }
            )

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

/// Folder-local control surface. The rest of the app keeps using the shared
/// ribbon primitive; this variant intentionally removes the outer ribbon
/// border while giving the page's search and sort controls the stronger
/// outline specified by the visual contract.
private struct CapabilityFolderControlField<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, DirectorSpacing.space3)
            .frame(minHeight: DirectorCapabilityFolderLayout.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(reduceTransparency ? DirectorColor.inset : DirectorColor.controlField)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(
                        DirectorColor.controlBoundary,
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
    }
}
