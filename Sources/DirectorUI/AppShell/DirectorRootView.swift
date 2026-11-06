import AppKit
import SwiftUI
import DirectorCore
import QuartzCore

/// Root workspace: native `NavigationSplitView` with primary destinations
/// and a separate Utilities section.
public struct DirectorRootView: View {
    @StateObject private var model: DirectorAppModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @State private var confirmDelete = false
    @State private var showEmptyProjects = false
    @State private var windowPresenceID = UUID()
    @State private var sidebarSelectionEmphasized = false
    @State private var quotaHistoryController: QuotaHistoryController?
    @State private var quotaHistoryPresentation: QuotaHistoryPresentation?
    @State private var quotaHistoryScrollPosition: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.capabilityHistoryPresentationSource) private var injectedHistorySource
#if DIRECTOR_INTERACTION_PERFORMANCE
    @ObservedObject private var interactionPerformanceDriver: InteractionPerformanceDriver
#endif

    private struct QuotaHistoryPresentation: Identifiable {
        let id: UUID
        let controller: QuotaHistoryController
    }

#if DIRECTOR_INTERACTION_PERFORMANCE
    public init(model: DirectorAppModel = DirectorAppModel(), interactionPerformanceDriver: InteractionPerformanceDriver? = nil) {
        _model = StateObject(wrappedValue: model)
        _interactionPerformanceDriver = ObservedObject(wrappedValue: interactionPerformanceDriver ?? .noop)
    }
#else
    public init(model: DirectorAppModel = DirectorAppModel()) {
        _model = StateObject(wrappedValue: model)
    }
#endif

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
#if DIRECTOR_INTERACTION_PERFORMANCE
                .background(alignment: .topLeading) {
                    if let destination = model.selection,
                       destination != .quotaHistory,
                       performanceShouldEmitDestinationDraw(for: destination) {
                        QuotaHistoryFirstPaintMarker.navigation(.destinationDraw, destination: destination)
                    }
                }
#endif
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
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.locale, languageStore.locale)
        .environment(\.capabilityHistoryPresentationSource, injectedHistorySource ?? historySource)
        .environment(\.capabilityHistoryMutationRevision, model.capabilityHistoryMutationRevision)
        .background(WindowPresenceBridge(id: windowPresenceID, onVisibilityChange: { visible in model.setWindowVisibility(windowPresenceID, visible: visible) }, onSleepingChange: { sleeping in model.setSystemSleeping(sleeping) }, onClockChange: { timeZone in model.presentationClockDidChange(timeZone: timeZone) }, onRemove: { id in model.removeWindow(id) }).allowsHitTesting(false).accessibilityHidden(true))
#if DIRECTOR_INTERACTION_PERFORMANCE
        .onChange(of: interactionPerformanceDriver.quotaHistoryCommandToken) { _, _ in
            guard let command = interactionPerformanceDriver.quotaHistoryCommand else { return }
            applyQuotaHistoryPerformanceCommand(command)
        }
        .overlay {
            QuotaHistoryFirstPaintMarker(
                kind: .entryFeedback,
                isCorrect: quotaHistoryPresentation != nil && QuotaHistoryPerformanceProbe.isAwaitingEntryFeedback,
                eventID: QuotaHistoryPerformanceProbe.currentEventID
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
#endif
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(DirectorSidebarItem.approvedNavigation) { item in
                    sidebarDestination(item)
                }
            }
        }
        .listStyle(.sidebar)
        .tint(.clear)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private var sidebarSelection: Binding<DirectorSidebarItem?> {
#if DIRECTOR_INTERACTION_PERFORMANCE
        Binding(get: { model.selection }, set: { destination in
            if let destination, destination != model.selection {
                InteractionPerformanceProbe.beginNativeNavigation(to: destination)
            }
            model.selection = destination
        })
#else
        $model.selection
#endif
    }

    private func sidebarDestination(_ item: DirectorSidebarItem) -> some View {
        let isSelected = model.selection == item
        let foreground = isSelected ? DirectorColor.navigationSelectedForeground : DirectorColor.textPrimary
        return HStack(spacing: DirectorSpacing.space2) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foreground)
                .accessibilityHidden(true)
            Text(languageStore.localizer.text("nav.\(item.rawValue)", fallback: item.title))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, DirectorSpacing.space2)
        .padding(.vertical, DirectorSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .fill(DirectorGradient.navigationSelected)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DirectorRadius.control, style: .continuous)
                    .stroke(
                        sidebarSelectionEmphasized ? DirectorColor.focus : DirectorColor.primaryActionBoundary.opacity(0.76),
                        lineWidth: sidebarSelectionEmphasized || contrast == .increased ? 2 : 1
                    )
                    .accessibilityHidden(true)
                DirectorListSelectionBridge(isEmphasized: $sidebarSelectionEmphasized)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .tag(item)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
#if DIRECTOR_INTERACTION_PERFORMANCE
        .background {
            if isSelected {
                QuotaHistoryFirstPaintMarker.navigation(.sidebarDraw, destination: item)
            }
        }
#endif
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection {
        case .home:
            HomeOverviewView(
                model: homeOverviewModel,
                quotaModel: homeQuotaModel,
                presentationState: model.presentationState,
                directoryLoaded: model.directoryLoaded,
                hasComputedStatistics: model.hasComputedStatistics,
                hasCachedHomeSummary: model.presentationHomeSummary != nil,
                isPreparingFirstPresentation: isPreparingFirstHomePresentation,
                pluginInventoryAvailable: model.pluginInventoryAvailable,
                lastUpdatedAt: model.homeLastUpdatedAt,
                homeUsageRankingPeriod: model.homeUsageRankingPeriod,
                onHomeUsageRankingPeriodChange: { model.setHomeUsageRankingPeriod($0) },
                onOpenQuotaHistory: openQuotaHistory,
                onQuotaSourceChange: { model.setQuotaSourceID($0) },
                onOpenCategory: { category in
                    model.selection = sidebarItem(for: category)
                    if let library = model.libraryModels.first(where: { $0.category == category }) {
                        library.context = CapabilityBrowseContext(scope: .allCapabilities, search: "", sort: .usageDescending)
                        library.selectedID = nil
                    }
                },
                onOpenCapability: { category, id in
                    model.selection = sidebarItem(for: category)
                    if let library = model.libraryModels.first(where: { $0.category == category }) {
                        library.context = CapabilityBrowseContext(scope: .allCapabilities, search: "", sort: .usageDescending)
                        library.selectedID = id
                    }
                }
            )
        case .quotaHistory:
            quotaHistoryPage
        case .capabilityFolders:
#if DIRECTOR_INTERACTION_PERFORMANCE
            CapabilityFoldersView(
                model: model,
                detailContext: { resource in capabilityDetailModel(for: resource) },
                performanceDriver: interactionPerformanceDriver,
                historySource: injectedHistorySource ?? historySource
            )
#else
            CapabilityFoldersView(
                model: model,
                detailContext: { resource in capabilityDetailModel(for: resource) },
                historySource: injectedHistorySource ?? historySource
            )
#endif
        case .customAgents:
            customLibraryDestination(
                destination: .customAgents, category: .myAgents, model: model.libraryModels[0],
                titleKey: "nav.customAgents", fallback: "Custom Agents"
            )
        case .customSkills:
            customLibraryDestination(
                destination: .customSkills, category: .mySkills, model: model.libraryModels[1],
                titleKey: "nav.customSkills", fallback: "Custom Skills"
            )
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

    /// The history controller is retained by the window root while the page
    /// is active. Entering from the sidebar and Home share this same route;
    /// the placeholder activates one session exactly once when navigation
    /// reaches the page.
    @ViewBuilder
    private var quotaHistoryPage: some View {
        let quotaModel = homeQuotaModel
        Group {
            if let presentation = quotaHistoryPresentation {
                QuotaHistoryView(
                    controller: presentation.controller,
                    sessionID: presentation.id,
                    quotaModel: quotaModel,
                    homeSnapshot: model.quotaOverviewSnapshot,
                    onClose: { closeQuotaHistory(presentationID: presentation.id) },
                    onSourceChange: { sourceID in
                        selectQuotaHistorySource(sourceID, presentationID: presentation.id)
                    },
                    scrollPosition: $quotaHistoryScrollPosition
                )
            } else {
                Color.clear
                    .task {
                        guard !Task.isCancelled, model.selection == .quotaHistory else { return }
                        activateQuotaHistoryIfNeeded()
                    }
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: quotaModel.sources.map(\.id)) { _, _ in
            // Startup may publish Home sources after the page has already
            // entered its intentional no-source state. Seed only an
            // uninitialized nil selection; a non-nil missing ID stays pinned.
            seedQuotaHistorySourceIfNeeded()
        }
    }

    private var isPreparingFirstHomePresentation: Bool {
        let isBootstrapping = model.bootstrapStatus == .bootstrapping || model.bootstrapStatus == .restoringCache
        return isBootstrapping && model.presentationHomeSummary == nil
            && model.quotaOverviewSnapshot == nil && !model.directoryLoaded && !model.hasComputedStatistics
    }

    private var homeOverviewModel: HomeOverviewModel {
        if let summary = model.presentationHomeSummary {
            return HomeOverviewModel(summary: summary)
        }
        let catalog = CapabilityCatalog(resources: model.capabilities.allRows.map(\.resource), relations: model.capabilities.relations)
        let stats = model.recentCapabilityStats
        return HomeOverviewModel(catalog: catalog, usage: stats)
    }

    private var homeQuotaModel: QuotaOverviewModel {
        model.quotaOverviewSnapshot.map {
            QuotaOverviewModel(
                snapshot: $0,
                accountUsage: model.accountUsageSnapshot,
                now: model.presentationNow,
                calendar: model.statisticsCalendar,
                selectedSourceID: model.quotaSourceID
            )
        } ?? QuotaOverviewModel(
            snapshots: [],
            now: model.presentationNow,
            calendar: model.statisticsCalendar,
            selectedSourceID: model.quotaSourceID
        )
    }

    private var historySource: CapabilityHistoryPresentationSource {
        CapabilityHistoryPresentationSource.make(model: model)
    }

    private func sidebarItem(for category: CapabilityCategory) -> DirectorSidebarItem {
        switch category { case .customAgents: return .customAgents; case .customSkills: return .customSkills; case .installedSkills: return .installedSkills; case .installedPlugins: return .installedPlugins }
    }

    private func capabilityDetailModel(for resource: CapabilityResource) -> CapabilityDetailViewModel {
        let catalog = CapabilityCatalog(resources: model.capabilities.allRows.map(\.resource), relations: model.capabilities.relations).entries
        let entry = catalog.first(where: { $0.resource.id == resource.id }) ?? CapabilityCatalogEntry(resource: resource, category: nil, parentPluginID: nil)
        let recent = model.recentCapabilityStats.first(where: { $0.resourceID == resource.id })
        let row = CapabilityLibraryRow(
            entry: entry,
            recent7Count: recent?.callCount,
            inferredCount: recent?.inferredCount ?? 0,
            lastUsedAt: recent?.lastUsedAt,
            sourceModifiedAt: resource.sourceModifiedAt,
            coverage: recent?.coverage ?? .unknown,
            statisticsReady: model.hasComputedStatistics,
            recent30Count: nil
        )
        let projects = Self.stableUniqueProjects(from: model.libraryModels.flatMap(\.projects))
        return CapabilityDetailViewModel(
            row: row,
            store: model.readStore,
            projects: projects,
            usageProjectIDs: [],
            evaluationStore: model.evaluationStore,
            findings: [],
            now: model.presentationNow,
            onClassify: { id, ownership in self.model.classify(resourceID: id, ownership: ownership) },
            onResetClassification: { id in self.model.resetClassification(resourceID: id) }
        )
    }

    /// Library projections can expose the same project from multiple
    /// capability categories. Preserve the first deterministic descriptor
    /// and sort by stable ID so details never trap on duplicate keys.
    static func stableUniqueProjects(from projects: [CapabilityProject]) -> [CapabilityProject] {
        var unique: [String: CapabilityProject] = [:]
        for project in projects where unique[project.id] == nil {
            unique[project.id] = project
        }
        return unique.values.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.id < rhs.id
        }
    }

    @ViewBuilder
    private func filteredCapabilities(category: ResourceInventoryCategory, model libraryModel: CapabilityLibraryViewModel, titleKey: String, fallback: String) -> some View {
        CapabilityLibraryView(model: libraryModel,
            title: languageStore.localizer.text(titleKey, fallback: fallback),
            subtitle: languageStore.localizer.text("library.subtitle", fallback: "Browse indexed capabilities and their recent evidence."),
            presentationState: self.model.presentationState,
            pluginInventoryAvailable: self.model.pluginInventoryAvailable,
            queryStatus: self.model.libraryQueryStatus[libraryModel.category],
            resultContext: self.model.libraryResultContext[libraryModel.category],
            queryTrigger: "\(self.model.directoryLoaded)-\(self.model.statisticsWindow?.start.timeIntervalSinceReferenceDate ?? -1)-\(self.model.statisticsWindow?.end.timeIntervalSinceReferenceDate ?? -1)",
            onScopeChanged: { scope in await self.model.reloadLibrary(libraryModel.category, scope: scope) },
            detailContext: { row in
                let effectiveScope = self.model.libraryResultContext[libraryModel.category]?.scope ?? libraryModel.context.scope
                return CapabilityDetailViewModel(row: row, projectID: { if case .project(let id) = effectiveScope { return id }; return nil }(),
                    store: self.model.readStore, projects: libraryModel.projects,
                    sessions: [], usageProjectIDs: libraryModel.usageProjects[row.id] ?? [],
                    evaluationStore: self.model.evaluationStore,
                    findings: [], now: self.model.presentationNow,
                    onClassify: { id, ownership in self.model.classify(resourceID: id, ownership: ownership) },
                    onResetClassification: { id in self.model.resetClassification(resourceID: id) })
            },
            folderDefinitions: self.model.capabilityFolders.folders,
            folderMembership: { resourceID, folderID in
                self.model.capabilityFolderStore.preferences().memberships.contains {
                    $0.resourceID == resourceID && $0.folderID == folderID
                }
            },
            onToggleFolderMembership: { resourceID, folderID, included in
                self.model.setCapabilityFolderMembership(resourceID: resourceID, folderID: folderID, included: included)
            },
            onUsagePeriodChanged: { period in self.model.setCapabilityFolderUsagePeriod(period) })
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

#if DIRECTOR_INTERACTION_PERFORMANCE
    private var performanceUsesLightLibraryDestination: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CODEX_DIRECTOR_INTERACTION_MANUAL_REVIEW"] == "1"
            && environment["CODEX_DIRECTOR_LIBRARY_DESTINATION"] == "light"
    }

    private var performanceLibraryDestinationMode: String? {
        ProcessInfo.processInfo.environment["CODEX_DIRECTOR_LIBRARY_DESTINATION"]
    }

    private func performanceShouldEmitDestinationDraw(for destination: DirectorSidebarItem) -> Bool {
        if destination == .customAgents || destination == .customSkills {
            return performanceLibraryDestinationMode == "original" || performanceUsesLightLibraryDestination
        }
        return true
    }
#endif

    @ViewBuilder
    private func customLibraryDestination(
        destination: DirectorSidebarItem,
        category: ResourceInventoryCategory,
        model: CapabilityLibraryViewModel,
        titleKey: String,
        fallback: String
    ) -> some View {
#if DIRECTOR_INTERACTION_PERFORMANCE
        if performanceUsesLightLibraryDestination {
            libraryDestinationPlaceholder(titleKey: titleKey, fallback: fallback)
        } else if performanceLibraryDestinationMode == "original" {
            filteredCapabilities(category: category, model: model, titleKey: titleKey, fallback: fallback)
        } else {
            stagedLibraryDestination(
                destination: destination, category: category, model: model,
                titleKey: titleKey, fallback: fallback, mountAfterDraw: performanceLibraryDestinationMode != "staged"
            )
        }
#else
        stagedLibraryDestination(
            destination: destination, category: category, model: model,
            titleKey: titleKey, fallback: fallback, mountAfterDraw: true
        )
#endif
    }

    @ViewBuilder
    private func libraryDestinationPlaceholder(titleKey: String, fallback: String) -> some View {
        DirectorEditorialFrame {
            VStack(alignment: .leading, spacing: DirectorSpacing.space4) {
                Text(languageStore.localizer.text(titleKey, fallback: fallback))
                    .font(DirectorTypography.heroTitle)
                    .foregroundStyle(DirectorColor.textPrimary)
                Text(languageStore.localizer.text("library.subtitle", fallback: "Browse indexed capabilities and their recent evidence."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DirectorSpacing.space6)
            .padding(.vertical, DirectorSpacing.space5)
        }
        .navigationTitle(languageStore.localizer.text(titleKey, fallback: fallback))
    }

    @ViewBuilder
    private func stagedLibraryDestination(
        destination: DirectorSidebarItem,
        category: ResourceInventoryCategory,
        model: CapabilityLibraryViewModel,
        titleKey: String,
        fallback: String,
        mountAfterDraw: Bool
    ) -> some View {
        StagedLibraryDestination(
            destination: destination,
            mountAfterDraw: mountAfterDraw,
            isCurrent: { self.model.selection == destination },
            placeholder: {
                libraryDestinationPlaceholder(titleKey: titleKey, fallback: fallback)
            },
            content: {
                filteredCapabilities(category: category, model: model, titleKey: titleKey, fallback: fallback)
            }
        )
        .id(destination)
    }

    private func startIndexing() {
        Task { await model.startIndexing() }
    }

#if DIRECTOR_INTERACTION_PERFORMANCE
    private func applyQuotaHistoryPerformanceCommand(_ command: InteractionPerformanceDriver.QuotaHistoryCommand) {
        QuotaHistoryPerformanceProbe.markCommandAccepted()
        switch command {
        case .open:
            openQuotaHistory()
        case let .setPeriod(period):
            quotaHistoryPresentation?.controller.setPeriod(period)
        case .close:
            // The validation driver has a synthetic close command. Keep the
            // product route free of dismissal chrome while returning the
            // harness to Home so its session can observe deactivation.
            model.selection = .home
        }
    }
#endif

    private func openQuotaHistory() {
        model.selection = .quotaHistory
        activateQuotaHistoryIfNeeded()
    }

    private func activateQuotaHistoryIfNeeded() {
        guard !Task.isCancelled, model.selection == .quotaHistory else { return }
        guard quotaHistoryPresentation == nil else { return }

        // Seed only a never-initialized selection from the existing Home
        // source list. A non-nil missing ID remains the history query key;
        // `homeQuotaModel.selectedSource` is never used as a fallback.
        let sources = homeQuotaModel.sources
        let sourceID = QuotaHistoryViewModel.initialSourceID(
            rawSelection: model.quotaSourceID,
            sources: sources
        )
        if model.quotaSourceID == nil, let sourceID {
            model.setQuotaSourceID(sourceID)
        }
        let sourceName = sourceID.flatMap { id in
            sources.first(where: { $0.id == id })?.name
        } ?? sourceID
        let controller = quotaHistoryController ?? model.makeQuotaHistoryController(windowID: windowPresenceID)
        quotaHistoryController = controller
        let sessionID = controller.open(sourceKey: sourceID, sourceName: sourceName, homeSnapshot: model.quotaOverviewSnapshot)
        quotaHistoryPresentation = QuotaHistoryPresentation(id: sessionID, controller: controller)
    }

    private func seedQuotaHistorySourceIfNeeded() {
        guard model.selection == .quotaHistory,
              model.quotaSourceID == nil,
              let source = homeQuotaModel.sources.first else { return }

        model.setQuotaSourceID(source.id)
        guard let presentation = quotaHistoryPresentation else { return }
        presentation.controller.setSource(
            sourceKey: source.id,
            sourceName: source.name,
            homeSnapshot: model.quotaOverviewSnapshot
        )
        quotaHistoryScrollPosition = "quota-history-top"
    }

    private func selectQuotaHistorySource(_ sourceID: String, presentationID: UUID) {
        guard model.selection == .quotaHistory,
              let presentation = quotaHistoryPresentation,
              presentation.id == presentationID else { return }
        guard let source = homeQuotaModel.sources.first(where: { $0.id == sourceID }) else { return }
        model.setQuotaSourceID(sourceID)
        presentation.controller.setSource(
            sourceKey: source.id,
            sourceName: source.name,
            homeSnapshot: model.quotaOverviewSnapshot
        )
        // This is the only root-owned scroll reset for a source picker
        // action. Presentation-ID and route guards above prevent an old page
        // callback from changing a newer session's retained position.
        quotaHistoryScrollPosition = "quota-history-top"
    }

    private func closeQuotaHistory(presentationID: UUID) {
        guard let presentation = quotaHistoryPresentation, presentation.id == presentationID else { return }
        presentation.controller.close(sessionID: presentationID)
        quotaHistoryPresentation = nil
#if DIRECTOR_INTERACTION_PERFORMANCE
        interactionPerformanceDriver.acknowledgeQuotaHistoryDismissed()
#endif
    }

}

/// Draw the sidebar selection and a lightweight destination before mounting
/// its result list. A display link provides a fallback rendering opportunity.
private struct StagedLibraryDestination<Placeholder: View, Content: View>: View {
    let destination: DirectorSidebarItem
    let mountAfterDraw: Bool
    let isCurrent: () -> Bool
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: () -> Content
    @State private var isMounted = false

    var body: some View {
        if isMounted {
            content()
#if DIRECTOR_INTERACTION_PERFORMANCE
                .background {
                    QuotaHistoryFirstPaintMarker.navigation(.destinationDraw, destination: destination)
                }
#endif
        } else {
            placeholder()
                .background {
                    StagedDestinationScheduler(mountAfterDraw: mountAfterDraw) {
                        guard isCurrent() else { return }
                        isMounted = true
                    }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }
}

private struct StagedDestinationScheduler: NSViewRepresentable {
    let mountAfterDraw: Bool
    let mount: @MainActor () -> Void

    func makeNSView(context: Context) -> StagedDestinationSchedulingView {
        let view = StagedDestinationSchedulingView()
        view.mountAfterDraw = mountAfterDraw
        view.mount = mount
        return view
    }

    func updateNSView(_ view: StagedDestinationSchedulingView, context: Context) {
        view.mount = mount
        view.scheduleIfNeeded()
    }

    static func dismantleNSView(_ view: StagedDestinationSchedulingView, coordinator: ()) {
        view.cancel()
        view.mount = nil
    }
}

private final class StagedDestinationSchedulingView: NSView {
    var mountAfterDraw = false
    var mount: (@MainActor () -> Void)?
    private var displayLink: CADisplayLink?
    private var pendingMount: Task<Void, Never>?
    private var receivedFirstTick = false
    private var finished = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancel()
        scheduleIfNeeded()
    }

    func scheduleIfNeeded() {
        guard !finished, displayLink == nil, pendingMount == nil, let window else { return }
        if !window.isVisible || window.screen == nil {
            scheduleMountOnMainActor()
            return
        }
        if mountAfterDraw { needsDisplay = true }

        let link = window.displayLink(target: self, selector: #selector(displayTick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard mountAfterDraw, window?.occlusionState.contains(.visible) == true else { return }
        // Leave the native drawing pass before touching SwiftUI state.
        // Keep the window display link as a fallback if this view never draws.
        scheduleMountOnMainActor()
    }

    private func scheduleMountOnMainActor() {
        guard !finished, pendingMount == nil else { return }
        pendingMount = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.window != nil else { return }
            self.finish()
        }
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        pendingMount?.cancel()
        pendingMount = nil
        receivedFirstTick = false
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard displayLink === link else { return }
        if receivedFirstTick {
            finish()
        } else {
            receivedFirstTick = true
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        cancel()
        let callback = mount
        mount = nil
        callback?()
    }
}
