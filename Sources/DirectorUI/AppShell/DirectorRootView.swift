import SwiftUI
import DirectorCore

/// Root workspace: native `NavigationSplitView` with primary destinations
/// and a separate Utilities section.
public struct DirectorRootView: View {
    @StateObject private var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @State private var confirmDelete = false
    @State private var showEmptyProjects = false
    @State private var windowPresenceID = UUID()

    public init(model: DirectorAppModel = DirectorAppModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle(DirectorUI.productName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DirectorRefreshButton(
                    label: languageStore.localizer.text("home.refresh", fallback: "Refresh data"),
                    runningLabel: languageStore.localizer.text("home.refresh.running", fallback: "Refreshing…"),
                    hint: languageStore.localizer.text("home.refresh.hint", fallback: "Refresh capabilities, quota and recent usage data."),
                    isRefreshing: model.isRefreshing,
                    isAvailable: model.coordinator != nil && model.configuration != nil,
                    size: .toolbar,
                    action: startIndexing
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.locale, languageStore.locale)
        .background(WindowPresenceBridge(id: windowPresenceID, onVisibilityChange: { visible in model.setWindowVisibility(windowPresenceID, visible: visible) }, onSleepingChange: { sleeping in model.setSystemSleeping(sleeping) }, onClockChange: { timeZone in model.presentationClockDidChange(timeZone: timeZone) }, onRemove: { id in model.removeWindow(id) }).allowsHitTesting(false).accessibilityHidden(true))
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section {
                ForEach(DirectorSidebarItem.approvedNavigation) { item in
                    sidebarDestination(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func sidebarDestination(_ item: DirectorSidebarItem) -> some View {
        let isSelected = model.selection == item
        return Label(
            languageStore.localizer.text("nav.\(item.rawValue)", fallback: item.title),
            systemImage: item.symbol
        )
        .foregroundStyle(isSelected ? DirectorColor.primaryActionForeground : DirectorColor.textPrimary)
        .padding(.horizontal, DirectorSpacing.space2)
        .padding(.vertical, DirectorSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(DirectorGradient.primaryButton)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        .tag(item)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection {
        case .home:
            HomeOverviewView(model: homeOverviewModel, quotaModel: model.quotaOverviewSnapshot.map { QuotaOverviewModel(snapshot: $0, now: model.presentationNow, calendar: model.statisticsCalendar, selectedSourceID: model.quotaSourceID) } ?? QuotaOverviewModel(snapshots: [], now: model.presentationNow, calendar: model.statisticsCalendar, selectedSourceID: model.quotaSourceID), presentationState: model.presentationState, directoryLoaded: model.directoryLoaded, hasComputedStatistics: model.hasComputedStatistics, hasCachedHomeSummary: model.presentationHomeSummary != nil, lastUpdatedAt: model.lastRefresh, onQuotaSourceChange: { model.setQuotaSourceID($0) }, onOpenCategory: { category in
                model.selection = sidebarItem(for: category)
                if let library = model.libraryModels.first(where: { $0.category == category }) {
                    library.context = CapabilityBrowseContext(scope: .allCapabilities, search: "", sort: .usageDescending)
                    library.selectedID = nil
                }
            }, onOpenCapability: { category, id in
                model.selection = sidebarItem(for: category)
                if let library = model.libraryModels.first(where: { $0.category == category }) { library.context = CapabilityBrowseContext(scope: .allCapabilities, search: "", sort: .usageDescending); library.selectedID = id }
            })
        case .customAgents:
            filteredCapabilities(category: .myAgents, model: model.libraryModels[0], titleKey: "nav.customAgents", fallback: "Custom Agents")
        case .customSkills:
            filteredCapabilities(category: .mySkills, model: model.libraryModels[1], titleKey: "nav.customSkills", fallback: "Custom Skills")
        case .installedSkills:
            filteredCapabilities(category: .installedSkills, model: model.libraryModels[2], titleKey: "nav.installedSkills", fallback: "Installed Skills")
        case .installedPlugins:
            filteredCapabilities(category: .plugins, model: model.libraryModels[3], titleKey: "nav.installedPlugins", fallback: "Installed Plugins")
        case .capabilities:
            CapabilitiesView(model: model.capabilities, findings: model.review.findings) { resourceID, ownership in
                model.classify(resourceID: resourceID, ownership: ownership)
            } onResetClassification: { resourceID in
                model.resetClassification(resourceID: resourceID)
            } onResetAllClassification: {
                model.resetAllClassifications()
            }
        case .tasks:
            TasksView(
                model: model.tasks,
                onEvaluate: { event, label in model.setEvaluation(for: event, label: label) },
                onClearEvaluation: { event in model.clearEvaluation(for: event.id) }
            )
            .task { await model.loadTasksIfNeeded() }
        case .review:
            ReviewView(model: model.review)
                .task { await model.loadReviewIfNeeded() }
        case .usage:
            UsageView(model: model.usage)
        case .dataStatus:
            dataStatusView
        case .settings:
            SettingsView(model: model)
        case nil:
            Text(languageStore.localizer.text("app.selectDestination", fallback: "Select a destination from the sidebar."))
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var homeOverviewModel: HomeOverviewModel {
        if let summary = model.presentationHomeSummary {
            return HomeOverviewModel(summary: summary)
        }
        let catalog = CapabilityCatalog(resources: model.capabilities.allRows.map(\.resource), relations: model.capabilities.relations)
        let stats = model.recentCapabilityStats
        return HomeOverviewModel(catalog: catalog, usage: stats)
    }

    private func sidebarItem(for category: CapabilityCategory) -> DirectorSidebarItem {
        switch category { case .customAgents: return .customAgents; case .customSkills: return .customSkills; case .installedSkills: return .installedSkills; case .installedPlugins: return .installedPlugins }
    }

    @ViewBuilder
    private func filteredCapabilities(category: ResourceInventoryCategory, model libraryModel: CapabilityLibraryViewModel, titleKey: String, fallback: String) -> some View {
        CapabilityLibraryView(model: libraryModel,
            title: languageStore.localizer.text(titleKey, fallback: fallback),
            subtitle: languageStore.localizer.text("library.subtitle", fallback: "Browse indexed capabilities and their recent evidence."),
            presentationState: self.model.presentationState,
            queryStatus: self.model.libraryQueryStatus[libraryModel.category],
            resultContext: self.model.libraryResultContext[libraryModel.category],
            queryTrigger: "\(self.model.directoryLoaded)-\(self.model.statisticsWindow?.start.timeIntervalSinceReferenceDate ?? -1)-\(self.model.statisticsWindow?.end.timeIntervalSinceReferenceDate ?? -1)",
            onScopeChanged: { scope in Task { await self.model.reloadLibrary(libraryModel.category, scope: scope) } },
            detailContext: { row in
                let effectiveScope = self.model.libraryResultContext[libraryModel.category]?.scope ?? libraryModel.context.scope
                return CapabilityDetailViewModel(row: row, projectID: { if case .project(let id) = effectiveScope { return id }; return nil }(),
                    store: self.model.readStore, projects: libraryModel.projects,
                    sessions: [], usageProjectIDs: libraryModel.usageProjects[row.id] ?? [],
                    evaluationStore: self.model.evaluationStore,
                    findings: [], now: self.model.presentationNow,
                    onClassify: { id, ownership in self.model.classify(resourceID: id, ownership: ownership) },
                    onResetClassification: { id in self.model.resetClassification(resourceID: id) })
            })
        .navigationTitle(languageStore.localizer.text(titleKey, fallback: fallback))
    }

    @ViewBuilder
    private var dataStatusView: some View {
        if model.lastRefresh == nil {
            FirstRunView(
                message: DirectorAppModel.firstRunMessage,
                canIndex: model.hasDerivedDatabase,
                isIndexing: model.isIndexing,
                progress: model.indexingProgress,
                startAction: startIndexing
            )
        } else {
            DataStatusView(
                progress: model.indexingProgress,
                isIndexing: model.isIndexing,
                lastRefresh: model.lastRefresh,
                error: model.indexingError,
                parserVersion: RolloutEventDecoder.parserVersion,
                sourceCategoryCounts: sourceCategoryCounts,
                sessionsWithPartialCoverage: partialCoverageSessionCount,
                sourceDataFresh: model.sourceDataFresh,
                sourceDataLastCheckedAt: model.sourceDataLastCheckedAt,
                confirmDelete: $confirmDelete,
                rebuildAction: startIndexing,
                deleteAction: { Task { try? await model.deleteDerivedData() } },
                parserCoverageFindingCount: model.review.dataQualityFindingCount
            )
        }
    }

    private var sourceCategoryCounts: [(name: String, count: Int)] {
        let roots = model.configuration?.scanRoots ?? []
        return Dictionary(grouping: roots, by: { $0.kind.rawValue })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    private var partialCoverageSessionCount: Int {
        model.tasks.rows.filter { $0.task.coverage == .partial }.count
    }

    private func startIndexing() {
        Task { await model.startIndexing() }
    }

}
