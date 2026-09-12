import SwiftUI
import DirectorCore

enum CapabilityGroupScopeFilter: Equatable, Sendable {
    case all
    case categorized
    case group(String)

    func matches(_ group: CapabilityGroupDefinition) -> Bool {
        switch self {
        case .all:
            return true
        case .categorized:
            return !group.isUncategorized
        case .group(let groupID):
            return group.id == groupID
        }
    }
}

enum CapabilityGroupingMetricFilter: Equatable, Sendable {
    case agent
    case skill
    case categorized
    case uncategorized
}

struct CapabilityGroupingFilterState: Equatable, Sendable {
    var group: CapabilityGroupScopeFilter = .all
    var kind: ResourceKind?

    var isActive: Bool { group != .all || kind != nil }

    func matches(_ member: CapabilityGroupingMember) -> Bool {
        group.matches(member.group) && (kind == nil || member.resource.kind == kind)
    }

    func selects(_ metric: CapabilityGroupingMetricFilter) -> Bool {
        switch metric {
        case .agent:
            return kind == .agent
        case .skill:
            return kind == .skill
        case .categorized:
            return group == .categorized
        case .uncategorized:
            return group == .group(BuiltInCapabilityGroup.uncategorized.id)
        }
    }

    mutating func toggle(_ metric: CapabilityGroupingMetricFilter) {
        switch metric {
        case .agent:
            kind = kind == .agent ? nil : .agent
        case .skill:
            kind = kind == .skill ? nil : .skill
        case .categorized:
            group = group == .categorized ? .all : .categorized
        case .uncategorized:
            let uncategorized = CapabilityGroupScopeFilter.group(BuiltInCapabilityGroup.uncategorized.id)
            group = group == uncategorized ? .all : uncategorized
        }
    }
}

/// Browsing surface for the local, one-primary-group projection. The page is
/// intentionally one native List so search, keyboard navigation and the
/// existing detail side sheet retain the same behavior as capability pages.
public struct CapabilityGroupsView: View {
    @ObservedObject public var model: DirectorAppModel
    public var detailContext: ((CapabilityResource) -> CapabilityDetailViewModel)?
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var filters = CapabilityGroupingFilterState()
    @State private var selectedResourceID: String?
    @State private var showsCreateSheet = false
    @State private var createName = ""
    @State private var editingGroup: CapabilityGroupDefinition?
    @State private var editName = ""
    @State private var groupToDelete: CapabilityGroupDefinition?
    @State private var showsDeleteConfirmation = false
    @State private var showsCorruptClearConfirmation = false

    public init(model: DirectorAppModel, detailContext: ((CapabilityResource) -> CapabilityDetailViewModel)? = nil) {
        self.model = model
        self.detailContext = detailContext
    }

    public var body: some View {
        DirectorEditorialFrame {
            GeometryReader { proxy in
                List(selection: $selectedResourceID) {
                    header(width: proxy.size.width)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: DirectorSpacing.space6, leading: DirectorPageLayout.listRowInset(for: proxy.size.width), bottom: DirectorSpacing.space4, trailing: DirectorPageLayout.listRowInset(for: proxy.size.width)))

                    if model.capabilityGroupingPreferencesState == .corrupted {
                        corruptedPreferencesState
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(rowInsets(for: proxy.size.width))
                    }

                    metrics(width: proxy.size.width)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets(for: proxy.size.width))

                    filters(width: proxy.size.width)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets(for: proxy.size.width))

                    if visibleMembers.isEmpty {
                        emptyState
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(rowInsets(for: proxy.size.width))
                    } else {
                        if showsAllUncategorizedHint {
                            allUncategorizedState
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(rowInsets(for: proxy.size.width))
                        }
                        ForEach(visibleGroups) { group in
                            groupHeader(group, width: proxy.size.width)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(rowInsets(for: proxy.size.width))
                            if groupMembers(group).isEmpty && !group.isBuiltIn {
                                customGroupEmptyState
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(rowInsets(for: proxy.size.width))
                            } else {
                                ForEach(groupMembers(group)) { member in
                                    memberRow(member, width: proxy.size.width)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(rowInsets(for: proxy.size.width))
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .background(Color.clear)
                .overlay(alignment: .trailing) { detailSheet(width: proxy.size.width) }
            }
        }
        .navigationTitle(t("nav.capabilityGroups", "Capability Groups"))
        .sheet(isPresented: $showsCreateSheet) {
            GroupNameSheet(
                title: t("capabilityGroups.create", "New category"),
                prompt: t("capabilityGroups.name", "Category name"),
                name: $createName,
                confirmTitle: t("capabilityGroups.createAction", "Create"),
                onCancel: { showsCreateSheet = false },
                onConfirm: createGroup
            )
            .environmentObject(languageStore)
        }
        .sheet(item: $editingGroup) { group in
            GroupNameSheet(
                title: t("capabilityGroups.rename", "Rename category"),
                prompt: t("capabilityGroups.name", "Category name"),
                name: $editName,
                confirmTitle: t("capabilityGroups.save", "Save"),
                onCancel: { editingGroup = nil },
                onConfirm: { renameGroup(group) }
            )
            .environmentObject(languageStore)
        }
        .confirmationDialog(
            t("capabilityGroups.delete.confirmTitle", "Delete category?"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(t("capabilityGroups.delete", "Delete"), role: .destructive) {
                if let groupToDelete { deleteGroup(groupToDelete) }
            }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("capabilityGroups.delete.confirmBody", "Its capabilities will move to Uncategorized. No capability files will be changed."))
        }
        .confirmationDialog(
            t("capabilityGroups.clearCorrupted.confirmTitle", "Clear unreadable category preferences?"),
            isPresented: $showsCorruptClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(t("capabilityGroups.clearCorrupted", "Clear unreadable preferences"), role: .destructive) {
                model.clearCorruptedCapabilityGroupingPreferences()
            }
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t("capabilityGroups.clearCorrupted.confirmBody", "The unreadable local category settings will be removed. Capability files will not be changed."))
        }
        .alert(
            t("capabilityGroups.error", "Unable to save category"),
            isPresented: Binding(get: { model.capabilityGroupingError != nil }, set: { if !$0 { model.clearCapabilityGroupingError() } })
        ) {
            Button(t("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(t(model.capabilityGroupingError ?? "capabilityGroups.saveFailed", "Please try again."))
        }
        .onChange(of: model.capabilityGroupingProjection) { _, _ in
            if case .group(let selectedGroupID) = filters.group,
               !model.capabilityGroupingProjection.groups.contains(where: { $0.id == selectedGroupID }) {
                filters.group = .all
            }
            if let selectedResourceID, !visibleMembers.contains(where: { $0.id == selectedResourceID }) {
                self.selectedResourceID = nil
            }
        }
    }

    private func header(width: CGFloat) -> some View {
        DirectorPageHeader(
            eyebrow: t("capabilityGroups.eyebrow", "07 / Capability Groups"),
            title: t("capabilityGroups.title", "Capability Groups"),
            titleAccent: nil,
            subtitle: t("capabilityGroups.subtitle", "Organize Agents and Skills into a focused, local capability map."),
            symbolName: DirectorSymbol.capabilityGroups,
            tone: .blue
        )
    }

    private func metrics(width: CGFloat) -> some View {
        DirectorMetricSequence(contentWidth: DirectorPageLayout.contentWidth(for: width)) {
            metric(.agent, t("capabilityGroups.metric.agents", "Agents"), value: model.capabilityGroupingProjection.agentCount, symbol: "person.crop.circle", tone: .blue)
            metric(.skill, t("capabilityGroups.metric.skills", "Skills"), value: model.capabilityGroupingProjection.skillCount, symbol: "sparkles", tone: .ice)
            metric(.categorized, t("capabilityGroups.metric.categorized", "Categorized"), value: model.capabilityGroupingProjection.categorizedCount, symbol: "checkmark.circle", tone: .mint)
            metric(.uncategorized, t("capabilityGroups.metric.uncategorized", "Uncategorized"), value: model.capabilityGroupingProjection.uncategorizedCount, symbol: "questionmark.circle", tone: .teal)
        }
        .padding(.bottom, DirectorSpacing.space5)
    }

    private func metric(_ filter: CapabilityGroupingMetricFilter, _ label: String, value: Int, symbol: String, tone: DirectorAccentTone) -> some View {
        DirectorMetricCard(
            symbolName: symbol,
            label: label,
            value: "\(value)",
            valueFont: DirectorTypography.metric,
            selected: filters.selects(filter),
            tone: tone,
            minimumHeight: DirectorSpacing.capabilityMetricHeight
        ) {
            filters.toggle(filter)
        }
    }

    private func filters(width: CGFloat) -> some View {
        DirectorFilterRibbon(compact: width < DirectorPageLayout.compactBreakpoint) {
            HStack(alignment: .center, spacing: DirectorSpacing.space3) {
                DirectorControlField {
                    HStack(spacing: DirectorSpacing.space2) {
                        Image(systemName: DirectorSymbol.search).foregroundStyle(DirectorColor.textSecondary).accessibilityHidden(true)
                        TextField(t("capabilityGroups.search", "Search capabilities"), text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityLabel(t("capabilityGroups.search", "Search capabilities"))
                    }
                }
                .frame(minWidth: 180, maxWidth: .infinity)
                groupFilter
                kindFilter
                Button {
                    createName = ""
                    showsCreateSheet = true
                } label: {
                    Label(t("capabilityGroups.add", "New category"), systemImage: "plus")
                }
                .buttonStyle(DirectorSecondaryActionButtonStyle())
                .disabled(model.capabilityGroupingPreferencesState == .corrupted)
            }
        }
    }

    private var groupFilter: some View {
        Menu {
            Button(t("capabilityGroups.filter.all", "All categories")) { filters.group = .all }
            Button(t("capabilityGroups.metric.categorized", "Categorized")) { filters.group = .categorized }
            ForEach(model.capabilityGroupingProjection.groups) { group in
                Button(groupTitle(group)) { filters.group = .group(group.id) }
            }
        } label: {
            Label(groupFilterTitle, systemImage: "folder")
        }
        .menuIndicator(.visible)
        .accessibilityLabel(t("capabilityGroups.filter.category", "Category filter"))
    }

    private var kindFilter: some View {
        Menu {
            Button(t("capabilityGroups.filter.allTypes", "All types")) { filters.kind = nil }
            Button(t("capabilityGroups.filter.agents", "Agents")) { filters.kind = .agent }
            Button(t("capabilityGroups.filter.skills", "Skills")) { filters.kind = .skill }
        } label: {
            Label(filters.kind == .agent ? t("capabilityGroups.filter.agents", "Agents") : filters.kind == .skill ? t("capabilityGroups.filter.skills", "Skills") : t("capabilityGroups.filter.allTypes", "All types"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.visible)
        .accessibilityLabel(t("capabilityGroups.filter.type", "Type filter"))
    }

    private func groupHeader(_ group: CapabilityGroupDefinition, width: CGFloat) -> some View {
        HStack(spacing: DirectorSpacing.space3) {
            Image(systemName: "folder.fill")
                .foregroundStyle(DirectorColor.accent(.teal))
                .accessibilityHidden(true)
            Text(groupTitle(group))
                .font(DirectorTypography.sectionTitle.weight(.semibold))
                .foregroundStyle(DirectorColor.textPrimary)
            Text("\(groupMembers(group).count)")
                .font(DirectorTypography.data.monospacedDigit())
                .foregroundStyle(DirectorColor.textSecondary)
            Spacer()
            if !group.isBuiltIn {
                Menu {
                    Button(t("capabilityGroups.rename", "Rename category")) {
                        editName = group.name
                        editingGroup = group
                    }
                    Button(t("capabilityGroups.delete", "Delete"), role: .destructive) {
                        groupToDelete = group
                        showsDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(DirectorColor.textSecondary)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(t("capabilityGroups.actions", "Category actions"))
            }
        }
        .padding(.vertical, DirectorSpacing.space3)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary).frame(height: 1) }
        .accessibilityAddTraits(.isHeader)
    }

    private func memberRow(_ member: CapabilityGroupingMember, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: DirectorSpacing.space3) {
            Button {
                selectedResourceID = member.id
            } label: {
                HStack(alignment: .top, spacing: DirectorSpacing.space3) {
                    Image(systemName: DirectorSymbol.resource(member.resource.kind))
                        .foregroundStyle(DirectorColor.resource(member.resource.kind))
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                        Text(member.resource.name)
                            .font(DirectorTypography.capabilityRowTitle)
                            .foregroundStyle(DirectorColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(CapabilityPurposeLocalization.localizedSummary(for: member.resource, language: languageStore.language) ?? t("capabilityGroups.purposeUnavailable", "Purpose unavailable"))
                            .font(DirectorTypography.capabilityRowSummary)
                            .foregroundStyle(DirectorColor.textSecondary)
                            .lineLimit(2)
                        Text(metadata(for: member))
                            .font(DirectorTypography.label)
                            .foregroundStyle(DirectorColor.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DirectorSpacing.space2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(member.resource.name), \(groupTitle(member.group))")
            groupAssignmentMenu(member)
        }
        .padding(.vertical, DirectorSpacing.space3)
        .overlay(alignment: .bottom) { Rectangle().fill(DirectorColor.boundary.opacity(0.66)).frame(height: 1) }
    }

    private func groupAssignmentMenu(_ member: CapabilityGroupingMember) -> some View {
        Menu {
            ForEach(model.capabilityGroupingProjection.groups) { group in
                Button {
                    model.setCapabilityGroup(resourceID: member.id, groupID: group.id)
                } label: {
                    HStack {
                        Text(groupTitle(group))
                        if member.group.id == group.id { Image(systemName: "checkmark") }
                    }
                }
            }
            if member.source == .manual {
                Divider()
                Button(t("capabilityGroups.restoreAutomatic", "Restore automatic classification")) {
                    model.restoreAutomaticCapabilityGroup(resourceID: member.id)
                }
            }
        } label: {
            HStack(spacing: DirectorSpacing.space1) {
                Text(groupTitle(member.group))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .padding(.horizontal, DirectorSpacing.space2)
            .padding(.vertical, DirectorSpacing.space1)
            .overlay(Capsule().stroke(DirectorColor.boundary, lineWidth: 1))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(t("capabilityGroups.currentCategory", "Current category"))
        .accessibilityValue(groupTitle(member.group))
        .disabled(model.capabilityGroupingPreferencesState == .corrupted)
    }

    @ViewBuilder private func detailSheet(width: CGFloat) -> some View {
        if let selectedResourceID,
           let resource = model.capabilityGroupingProjection.members.first(where: { $0.id == selectedResourceID })?.resource,
           let detailContext {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { self.selectedResourceID = nil }
                .accessibilityHidden(true)
            DirectorSideSheet(
                width: min(DirectorSpacing.sideSheetMaxWidth, max(DirectorSpacing.sideSheetMinWidth, width * 0.34)),
                onClose: { self.selectedResourceID = nil },
                closeLabel: t("detail.close", "Close detail")
            ) {
                CapabilityDetailView(model: detailContext(resource), showsBackButton: false)
            }
            .padding(.vertical, DirectorSpacing.space2)
        }
    }

    private var visibleMembers: [CapabilityGroupingMember] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.capabilityGroupingProjection.members.filter { member in
            guard filters.matches(member) else { return false }
            guard !query.isEmpty else { return true }
            let summary = CapabilityPurposeLocalization.localizedSummary(for: member.resource, language: languageStore.language) ?? ""
            return member.resource.name.localizedCaseInsensitiveContains(query) || summary.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleGroups: [CapabilityGroupDefinition] {
        let hasActiveFilter = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filters.isActive
        if !hasActiveFilter { return model.capabilityGroupingProjection.groups }
        return model.capabilityGroupingProjection.groups.filter { !groupMembers($0).isEmpty }
    }

    private func groupMembers(_ group: CapabilityGroupDefinition) -> [CapabilityGroupingMember] {
        visibleMembers.filter { $0.group.id == group.id }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            Text(emptyTitle).font(DirectorTypography.sectionTitle.weight(.semibold)).foregroundStyle(DirectorColor.textPrimary)
            Text(t("capabilityGroups.empty.hint", "Try another filter or refresh the indexed capability directory."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
        }
        .padding(.vertical, DirectorSpacing.space8)
    }

    private var showsAllUncategorizedHint: Bool {
        model.capabilityGroupingProjection.members.allSatisfy { $0.group.isUncategorized }
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filters.isActive
    }

    private var allUncategorizedState: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Label(
                t("capabilityGroups.empty.allUncategorized.title", "Everything is currently uncategorized"),
                systemImage: "questionmark.circle"
            )
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textSecondary)
            Text(t("capabilityGroups.empty.allUncategorized.body", "Adjust a category from any row to create a personal organization."))
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textTertiary)
        }
        .padding(.vertical, DirectorSpacing.space2)
    }

    private var customGroupEmptyState: some View {
        Text(t("capabilityGroups.empty.custom", "No capabilities are assigned to this category yet."))
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textTertiary)
            .padding(.leading, DirectorSpacing.space8)
            .padding(.vertical, DirectorSpacing.space2)
    }

    private var corruptedPreferencesState: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Label(t("capabilityGroups.corrupted.title", "Category preferences unavailable"), systemImage: "exclamationmark.triangle")
                .font(DirectorTypography.sectionTitle.weight(.semibold))
                .foregroundStyle(DirectorColor.status(.warning))
            Text(t("capabilityGroups.corrupted", "Category preferences could not be read. They were not changed. Retry, or clear them to start fresh."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DirectorSpacing.space3) {
                Button(t("capabilityGroups.retry", "Retry reading preferences")) {
                    model.retryCapabilityGroupingPreferences()
                }
                .buttonStyle(DirectorSecondaryActionButtonStyle())
                Button(t("capabilityGroups.clearCorrupted", "Clear unreadable preferences"), role: .destructive) {
                    showsCorruptClearConfirmation = true
                }
                .buttonStyle(DirectorSecondaryActionButtonStyle(destructive: true))
            }
        }
        .padding(DirectorSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DirectorRadius.control).stroke(DirectorColor.status(.warning), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var emptyTitle: String {
        if model.capabilityGroupingProjection.members.isEmpty { return t("capabilityGroups.empty.none", "No Agents or Skills found") }
        if visibleMembers.isEmpty && (!searchText.isEmpty || filters.isActive) { return t("capabilityGroups.empty.search", "No capabilities match these filters") }
        return t("capabilityGroups.empty.none", "No Agents or Skills found")
    }

    private var groupFilterTitle: String {
        switch filters.group {
        case .all:
            return t("capabilityGroups.filter.all", "All categories")
        case .categorized:
            return t("capabilityGroups.metric.categorized", "Categorized")
        case .group(let id):
            return model.capabilityGroupingProjection.groups.first(where: { $0.id == id }).map(groupTitle)
                ?? t("capabilityGroups.filter.all", "All categories")
        }
    }

    private func metadata(for member: CapabilityGroupingMember) -> String {
        let kind = member.resource.kind == .agent ? t("capabilityGroups.agent", "Agent") : t("capabilityGroups.skill", "Skill")
        let scope: String
        if member.resource.ownership == .pluginProvided {
            scope = t("capabilityGroups.installed", "Installed")
        } else {
            switch member.resource.scope {
            case .project: scope = t("capabilityGroups.project", "Project")
            case .global: scope = t("capabilityGroups.global", "Global")
            case .runtime: scope = t("capabilityGroups.runtime", "Runtime")
            default: scope = t("capabilityGroups.local", "Local")
            }
        }
        return "\(kind) · \(scope) · \(member.source == .manual ? t("capabilityGroups.manual", "Manual") : t("capabilityGroups.automatic", "Automatic"))"
    }

    private func groupTitle(_ group: CapabilityGroupDefinition) -> String {
        guard let builtIn = group.builtIn else { return group.name }
        let key = "capabilityGroups.group.\(builtIn.rawValue)"
        return t(key, builtIn.englishTitle)
    }

    private func rowInsets(for width: CGFloat) -> EdgeInsets {
        let inset = DirectorPageLayout.listRowInset(for: width)
        return EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
    }

    @discardableResult
    private func createGroup() -> Bool {
        do {
            _ = try model.createCapabilityGroup(named: createName)
            showsCreateSheet = false
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func renameGroup(_ group: CapabilityGroupDefinition) -> Bool {
        do {
            try model.renameCapabilityGroup(id: group.id, to: editName)
            editingGroup = nil
            return true
        } catch {
            return false
        }
    }

    private func deleteGroup(_ group: CapabilityGroupDefinition) {
        do {
            try model.deleteCapabilityGroup(id: group.id)
            groupToDelete = nil
        } catch { }
    }

    private func t(_ key: String, _ fallback: String) -> String { languageStore.localizer.text(key, fallback: fallback) }
}

private struct GroupNameSheet: View {
    let title: String
    let prompt: String
    @Binding var name: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var languageStore: AppLanguageStore

    var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
            Text(title).font(DirectorTypography.sectionTitle.weight(.semibold))
            TextField(prompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { _ = onConfirm() }
            HStack {
                Spacer()
                Button(languageStore.localizer.text("common.cancel", fallback: "Cancel"), action: { onCancel(); dismiss() }).buttonStyle(DirectorSecondaryActionButtonStyle())
                Button(confirmTitle, action: { if onConfirm() { dismiss() } })
                    .buttonStyle(DirectorPrimaryActionButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DirectorSpacing.space6)
        .frame(width: 420)
    }
}
