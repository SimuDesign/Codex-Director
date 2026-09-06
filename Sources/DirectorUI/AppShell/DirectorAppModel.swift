import SwiftUI
import Combine
import DirectorCore

/// Trustworthy state of the derived-data presentation.
///
/// `empty` means an indexing pass completed and found no facts. `initial`
/// means that no completed pass (and no indexed facts) has been observed yet.
/// Preview is deliberately distinct from both states so sample content can
/// never be mistaken for indexed user data.
public enum DirectorPresentationState: Equatable, Sendable {
    case preview
    case initial
    case indexing
    case loaded
    case empty
    case failure(String)
}

public enum DirectorCacheStatus: Equatable, Sendable {
    case unavailable
    case restoredUnverified
    case verified
    case stale
}

public enum DirectorBootstrapStatus: Equatable, Sendable {
    case idle
    case restoringCache
    case bootstrapping
    case ready
    case failed
}

/// Result used by the adaptive account-only scheduler.  The existing
/// `RefreshOutcome` deliberately remains unchanged so a failed optional
/// account read does not make a successful local projection look failed.
public enum AccountUsageRefreshResult: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case unavailable
}

/// Readiness of a destination's bounded presentation query. The result window
/// is exposed so views can distinguish a loaded result from an empty result
/// and keep the previous rows while a new scope is loading.
public enum DirectorLibraryQueryStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded(CapabilityQueryWindow)
    case failed
}

/// Context of the last successful library result. Loading a new project or
/// window never erases this value, allowing the UI to keep old rows visible
/// without presenting them as belonging to the newly requested scope.
public struct DirectorLibraryResultContext: Equatable, Sendable {
    public let scope: CapabilityBrowseScope
    public let window: CapabilityQueryWindow
    public init(scope: CapabilityBrowseScope, window: CapabilityQueryWindow) {
        self.scope = scope
        self.window = window
    }
}

/// Main-actor app state.
///
/// Starts in synthetic preview mode; once a derived database is available,
/// `refresh()` and `startIndexing()` populate the destinations from the local
/// index. The app never mutates source files.
@MainActor
public final class DirectorAppModel: ObservableObject {
    @Published public var selection: DirectorSidebarItem? {
        didSet {
            if selection == .home {
                scheduleHomeRankingUpgradeIfNeeded()
            } else {
                cancelHomeRankingUpgrade()
                // The deferral only protects a Home-visible upgrade. Other
                // destinations may continue their normal automatic refresh.
                normalPresentationRefreshDeferred = false
            }
        }
    }
    @Published public var indexingProgress: IndexingProgress = .initial
    @Published public var isIndexing = false
    @Published public var lastRefresh: Date?
    @Published public var indexingError: String?
    @Published public var sourceDataFresh = true
    @Published public var sourceDataLastCheckedAt: Date?
    @Published public private(set) var presentationState: DirectorPresentationState
    @Published public private(set) var hasIndexedData = false
    @Published public private(set) var cacheStatus: DirectorCacheStatus = .unavailable
    @Published public private(set) var bootstrapStatus: DirectorBootstrapStatus = .idle
    @Published public private(set) var directoryLoaded = false
    @Published public private(set) var statisticsWindow: CapabilityQueryWindow?
    @Published public private(set) var hasComputedStatistics = false
    @Published public private(set) var libraryQueryStatus: [CapabilityCategory: DirectorLibraryQueryStatus] = [:]
    @Published public private(set) var libraryResultContext: [CapabilityCategory: DirectorLibraryResultContext] = [:]
    @Published public private(set) var refreshScheduleState: RefreshScheduleState?
    @Published public private(set) var backgroundRefreshError: String?
    @Published public private(set) var presentationDiagnostics: PresentationDiagnosticsSummary?
    @Published public private(set) var diagnosticsLoading = false
    @Published public private(set) var diagnosticsError: String?
    @Published public private(set) var capabilityExportProgress: CapabilityExportProgress?
    @Published public private(set) var isCapabilityExporting = false
    @Published public private(set) var menuBarEnabled: Bool
    @Published public private(set) var accountUsageSnapshot: CodexAccountUsageSnapshot?
    @Published public private(set) var accountUsageError: String?
    @Published public private(set) var accountUsageReadRevision: UInt64 = 0

    /// One truthful application-wide busy state for refresh controls. Source
    /// indexing and bounded presentation projection are both visible; queued,
    /// waiting, failed, and startup-grace states are not presented as work in
    /// progress.
    public var isRefreshing: Bool {
        Self.refreshIsActive(isIndexing: isIndexing, phase: refreshScheduleState?.phase)
    }

    /// Privacy-safe menu-bar projection. The menu bar never derives account
    /// values from local token or session data.
    public var menuBarPresentation: MenuBarPresentation {
        let freshness: MenuBarPresentation.Freshness = {
            guard let snapshot = accountUsageSnapshot else { return .unavailable }
            let now = nowProvider()
            guard snapshot.capturedAt <= now,
                  now.timeIntervalSince(snapshot.capturedAt) <= 30 * 60 else { return .stale }
            return .fresh
        }()
        let activity: MenuBarPresentation.Activity = isRefreshing
            ? .refreshing
            : (accountUsageError == nil ? .idle : .failed)
        return MenuBarPresentation(snapshot: accountUsageSnapshot, freshness: freshness, activity: activity, now: nowProvider())
    }

    public var canReadAccountUsage: Bool { accountUsageReading != nil }

    public func setMenuBarEnabled(_ enabled: Bool) {
        guard menuBarEnabled != enabled else { return }
        menuBarEnabled = enabled
        menuBarPreferences.setEnabled(enabled)
        accountUsageRefreshScheduler?.setEnabled(enabled)
    }

    /// Refreshes only account usage when the menu-bar popover has no current
    /// trustworthy reading. The main window may be closed during this call.
    @discardableResult
    public func refreshMenuBarIfNeeded() async -> RefreshOutcome {
        guard menuBarEnabled, accountUsageNeedsRefresh else { return .notDue }
        let before = accountUsageReadRevision
        let outcome = await requestAccountUsageRefresh(force: true, reason: .menuBar)
        if accountUsageReadRevision != before {
            accountUsageRefreshScheduler?.recordExternalResult(
                accountUsageSnapshot?.weeklyRemainingPercent == nil ? .unavailable : .succeeded
            )
        } else if outcome == .cancelled {
            accountUsageRefreshScheduler?.recordExternalResult(.cancelled)
        } else {
            accountUsageRefreshScheduler?.recordExternalResult(.failed)
        }
        return outcome
    }

    /// Explicit menu-bar action: runs the same full manual refresh as the
    /// main-window action and adds the account-usage domain.
    @discardableResult
    public func refreshDataFromMenuBar() async -> RefreshOutcome {
        guard !isDeletingDerivedData else { return .cancelled }
        var domains = Set<RefreshDomain>()
        if hasDerivedDatabase {
            domains.formUnion([.quota, .directory])
        }
        if accountUsageReading != nil {
            domains.insert(.accountUsage)
        }
        guard !domains.isEmpty else { return .cancelled }
        let before = accountUsageReadRevision
        let outcome = await ensurePresentationRefreshCoordinator().request(RefreshRequest(
            domains: domains,
            reason: .manual,
            force: true,
            sourceIntent: hasDerivedDatabase
        ))
        if accountUsageReading != nil {
            if accountUsageReadRevision != before {
                accountUsageRefreshScheduler?.recordExternalResult(
                    accountUsageSnapshot?.weeklyRemainingPercent == nil ? .unavailable : .succeeded
                )
            } else if outcome == .cancelled {
                accountUsageRefreshScheduler?.recordExternalResult(.cancelled)
            } else {
                accountUsageRefreshScheduler?.recordExternalResult(.failed)
            }
        }
        return outcome
    }

    private var accountUsageNeedsRefresh: Bool {
        guard let snapshot = accountUsageSnapshot else { return true }
        // A snapshot without a weekly allowance is a valid transport result,
        // but it cannot populate the menu-bar primary value. Treat it like a
        // missing reading so a later popover can retry the account domain.
        guard snapshot.weeklyRemainingPercent != nil else { return true }
        let now = nowProvider()
        guard snapshot.capturedAt <= now else { return true }
        if let reset = snapshot.weeklyResetsAt, reset <= now { return true }
        return now.timeIntervalSince(snapshot.capturedAt) > 2 * 60
    }

    @discardableResult
    private func requestAccountUsageRefresh(force: Bool, reason: RefreshReason = .menuBar) async -> RefreshOutcome {
        guard accountUsageReading != nil else {
            accountUsageError = "account_usage_unavailable"
            return .completed
        }
        return await ensurePresentationRefreshCoordinator().request(RefreshRequest(
            domains: [.accountUsage],
            reason: reason,
            force: force,
            sourceIntent: false
        ))
    }

    internal static func refreshIsActive(isIndexing: Bool, phase: RefreshPhase?) -> Bool {
        if isIndexing { return true }
        switch phase {
        case .source, .projection: return true
        case .idle, .startupGrace, .waiting, .failed, nil: return false
        }
    }

    @Published public private(set) var capabilities: CapabilitiesViewModel
    @Published public private(set) var tasks: TasksViewModel
    @Published public private(set) var usage: UsageViewModel
    @Published public private(set) var review: ReviewViewModel
    @Published public private(set) var libraryModels: [CapabilityLibraryViewModel]
    @Published public private(set) var recentCapabilityStats: [CapabilityUsageStats] = []
    @Published public var quotaSourceID: String?
    public private(set) var statisticsCalendar: Calendar
    private let nowProvider: @Sendable () -> Date
    private var lastStatisticsDay: Date?
    // Presentation refreshes (including midnight statistic updates) must not
    // advance the source-index freshness baseline.
    @Published public private(set) var lastIndexCompletedAt: Date?
    private var hasCompletedIndexPass = false
    private var libraryReloadGeneration: [String: Int] = [:]
    public let classificationOverrides: ResourceClassificationOverrideStore
    public let evaluationStore: InvocationEvaluationStore
    private let menuBarPreferences: MenuBarPreferences
    /// Keeps model instances in separate windows aligned with the shared
    /// application preference. The App scene and Settings may observe the
    /// same store through different model instances.
    private var menuBarPreferencesCancellable: AnyCancellable?

    public private(set) var store: DatabaseStore?
    public private(set) var readStore: DatabaseStore?
    public private(set) var coordinator: IndexingCoordinator?
    public private(set) var configuration: IndexingCoordinator.Configuration?
    public private(set) var capabilityExportCoordinator: CapabilityExportCoordinator?
    public private(set) var presentationSnapshotStore: PresentationSnapshotStore?
    public private(set) var accountUsageReading: CodexAccountUsageReading?
    private var accountUsageRefreshScheduler: AccountUsageRefreshScheduler?
    @Published public private(set) var quotaOverviewSnapshot: QuotaOverviewSnapshot?
    @Published public private(set) var presentationHomeSummary: PresentationHomeSummary?

    private var sourceDataMonitorTask: Task<Void, Never>?
    private var sourceMonitorActionTask: Task<Void, Never>?
    private var homeRankingUpgradeTask: Task<Void, Never>?
    private var homeRankingRetryPending = false
    private var homeRankingUpgradeGeneration: UInt64 = 0
    private var normalPresentationRefreshDeferred = false
    private var presentationRefreshCoordinator: RefreshCoordinator?
    private var hasLoadedInitialData = false
    private var lifecycleEpoch: UInt64 = 0
    private var presentationRequestSequence: UInt64 = 0
    private var classificationEpoch: UInt64 = 0
    private var isDeletingDerivedData = false
    private var detailRequestSequence: UInt64 = 0
    private var diagnosticsRequestSequence: UInt64 = 0
    private var schedulePersistenceRevision: UInt64 = 0
    private var visibleWindowIDs: Set<UUID> = []
    private var isSystemSleeping = false
    private var sourceMonitorGeneration: UInt64 = 0
    private var sourceProgressLastPublishedAt: Date?
    private var cacheInvalidationTask: Task<Void, Never>?
    private var presentationCachePermit: PresentationSnapshotStore.WritePermit?
    private var monitorStatisticsDay: Date?
    private var pendingMonitorDayProjection = false
    private var libraryPresentationKeys: [String: LibraryPresentationKey] = [:]
    /// Deterministic async seam for publication race tests. Production never
    /// assigns this hook; it only delays the already-built immutable DTO.
    internal var presentationProjectionTestHook: (@Sendable () async throws -> Void)?

    private struct PresentationTicket: Sendable {
        let lifecycleEpoch: UInt64
        let requestSequence: UInt64
        let classificationEpoch: UInt64
        let classificationRevision: String
        let identity: PresentationIdentity
        let permit: PresentationSnapshotStore.WritePermit?
    }

    private struct LibraryPresentationKey: Equatable, Sendable {
        let category: CapabilityCategory
        let scope: CapabilityBrowseScope
        let window: CapabilityQueryWindow
        let identity: PresentationIdentity
        let classificationRevision: String
    }

    private struct DisplayTicket: Sendable {
        let lifecycleEpoch: UInt64
        let requestSequence: UInt64
        let classificationEpoch: UInt64
        let classificationRevision: String
    }

    private struct DetailTicket: Sendable {
        let lifecycleEpoch: UInt64
        let sequence: UInt64
        let classificationEpoch: UInt64
        let classificationRevision: String
    }


    public init(
        store: DatabaseStore? = nil,
        readStore: DatabaseStore? = nil,
        coordinator: IndexingCoordinator? = nil,
        configuration: IndexingCoordinator.Configuration? = nil,
        capabilityExportCoordinator: CapabilityExportCoordinator? = nil,
        selection: DirectorSidebarItem? = .home,
        classificationOverrides: ResourceClassificationOverrideStore = ResourceClassificationOverrideStore(),
        evaluationStore: InvocationEvaluationStore = InvocationEvaluationStore(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = Calendar(identifier: .gregorian),
        previewMode: Bool = true,
        bootstrapError: String? = nil,
        bootstrapPending: Bool = false,
        presentationSnapshotStore: PresentationSnapshotStore? = nil,
        presentationRefreshCoordinator: RefreshCoordinator? = nil,
        menuBarPreferences: MenuBarPreferences = MenuBarPreferences(memoryEnabled: true),
        accountUsageReading: CodexAccountUsageReading? = nil
    ) {
        self.store = store
        self.readStore = readStore ?? store
        self.coordinator = coordinator
        self.configuration = configuration
        self.capabilityExportCoordinator = capabilityExportCoordinator
        self.presentationSnapshotStore = presentationSnapshotStore
        self.accountUsageReading = accountUsageReading
        self.accountUsageRefreshScheduler = nil
        self.menuBarPreferences = menuBarPreferences
        self.menuBarEnabled = menuBarPreferences.snapshot().isEnabled
        self.accountUsageSnapshot = nil
        self.accountUsageError = nil
        self.presentationRefreshCoordinator = presentationRefreshCoordinator
        self.selection = selection
        self.classificationOverrides = classificationOverrides
        self.evaluationStore = evaluationStore
        var statisticsCalendar = calendar
        statisticsCalendar.locale = Locale(identifier: "en_US_POSIX")
        self.statisticsCalendar = statisticsCalendar
        self.nowProvider = nowProvider
        let initialNow = nowProvider()
        self.presentationNow = initialNow
        self.lastIndexCompletedAt = nil
        self.quotaSourceID = nil
        self.quotaOverviewSnapshot = nil
        self.presentationHomeSummary = nil
        // Synthetic preview data only when no derived database exists; a real
        // store starts empty until the first refresh.
        let hasStore = store != nil
        let usesPreview = !hasStore && previewMode
        self.cacheStatus = .unavailable
        self.bootstrapStatus = bootstrapPending ? .bootstrapping : (usesPreview ? .ready : (hasStore ? .idle : .failed))
        self.presentationState = hasStore
            ? .initial
            : (usesPreview ? .preview : (bootstrapPending ? .initial : .failure(bootstrapError ?? "derived_database_unavailable")))
        self.capabilities = CapabilitiesViewModel(
            resources: usesPreview ? SyntheticPreviewData.resources : [],
            relations: usesPreview ? SyntheticPreviewData.relations : []
        )
        self.tasks = TasksViewModel(
            sessions: usesPreview ? SyntheticPreviewData.tasks : [],
            invocationsBySession: usesPreview ? Dictionary(grouping: SyntheticPreviewData.invocations, by: \.sessionID) : [:]
        )
        self.usage = UsageViewModel(
            quotaSnapshots: usesPreview ? SyntheticPreviewData.quotaSnapshots : [],
            tokenSnapshots: usesPreview ? SyntheticPreviewData.tokenSnapshots : [],
            now: initialNow
        )
        self.review = ReviewViewModel(
            findings: usesPreview ? SyntheticPreviewData.findings : [],
            sessions: usesPreview ? SyntheticPreviewData.tasks : []
        )
        self.libraryModels = CapabilityCategory.allCases.map { CapabilityLibraryViewModel(category: $0) }
        if usesPreview {
            let catalog = CapabilityCatalog(resources: SyntheticPreviewData.resources, relations: SyntheticPreviewData.relations).entries
            let stats = SyntheticPreviewData.resources.map { CapabilityUsageStats(resourceID: $0.id, callCount: 0, inferredCount: 0, lastUsedAt: nil, coverage: .complete) }
            for model in libraryModels {
                model.setData(
                    catalog: catalog,
                    categoryStats: stats,
                    browseHistory: [],
                    category30DayStats: stats,
                    browse30DayStats: stats
                )
            }
        }
        if let presentationRefreshCoordinator {
            presentationRefreshCoordinator.setAutomaticSourceEnabled(
                coordinator != nil && configuration != nil && (hasCompletedIndexPass || hasIndexedData)
            )
            presentationRefreshCoordinator.setStateChangeHandler { [weak self] state in
                guard let self else { return }
                self.handleScheduleStateChange(state)
            }
            self.refreshScheduleState = presentationRefreshCoordinator.scheduleState
        }

        // MenuBarPreferences is app-scoped. Subscribe after all stored
        // properties have been initialized so a toggle in one window
        // immediately updates the model used by every other window.
        self.menuBarPreferencesCancellable = menuBarPreferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, self.menuBarEnabled != enabled else { return }
                self.menuBarEnabled = enabled
                self.accountUsageRefreshScheduler?.setEnabled(enabled)
            }
    }

    /// Installs services after the first window is already visible. This
    /// keeps navigation, search, language, and other view-owned state in the
    /// original model rather than replacing the root tree after bootstrap.
    public func installServices(
        store: DatabaseStore?,
        readStore: DatabaseStore? = nil,
        coordinator: IndexingCoordinator?,
        configuration: IndexingCoordinator.Configuration?,
        capabilityExportCoordinator: CapabilityExportCoordinator? = nil,
        presentationSnapshotStore: PresentationSnapshotStore? = nil,
        accountUsageReading: CodexAccountUsageReading? = nil,
        bootstrapError: String? = nil
    ) {
        let previousSnapshotStore = self.presentationSnapshotStore
        invalidateLifecycle()
        if let previousSnapshotStore,
           let presentationSnapshotStore,
           ObjectIdentifier(previousSnapshotStore) != ObjectIdentifier(presentationSnapshotStore) {
            queueCacheInvalidation(previousSnapshotStore)
        }
        self.store = store
        self.readStore = readStore ?? store
        self.coordinator = coordinator
        self.configuration = configuration
        self.capabilityExportCoordinator = capabilityExportCoordinator
        self.presentationSnapshotStore = presentationSnapshotStore
        self.accountUsageReading = accountUsageReading
        configureAccountUsageRefreshScheduler()
        guard store != nil else {
            sourceDataFresh = false
            presentationState = .failure(bootstrapError ?? "derived_database_unavailable")
            bootstrapStatus = .failed
            return
        }
        indexingError = nil
        bootstrapStatus = .bootstrapping
        if cacheStatus == .unavailable || presentationState == .preview {
            presentationState = .initial
        }
        if !visibleWindowIDs.isEmpty { startSourceDataMonitor() }
    }

    public func installPresentationSnapshotStore(_ snapshotStore: PresentationSnapshotStore?) {
        let previousSnapshotStore = self.presentationSnapshotStore
        presentationRequestSequence &+= 1
        if let previousSnapshotStore,
           let snapshotStore,
           ObjectIdentifier(previousSnapshotStore) != ObjectIdentifier(snapshotStore) {
            queueCacheInvalidation(previousSnapshotStore)
        }
        presentationSnapshotStore = snapshotStore
    }

    // MARK: - Portable capability export

    public func loadCapabilityExportOptions() async throws -> CapabilityExportOptions {
        guard let capabilityExportCoordinator else { throw CapabilityExportError.noPreparedPackage }
        return try await capabilityExportCoordinator.options()
    }

    public func prepareCapabilityExport(selection: CapabilityExportSelection) async throws -> CapabilityExportPreview {
        guard let capabilityExportCoordinator else { throw CapabilityExportError.noPreparedPackage }
        isCapabilityExporting = true
        capabilityExportProgress = CapabilityExportProgress(phase: .discovering)
        defer { isCapabilityExporting = false }
        return try await capabilityExportCoordinator.prepare(selection: selection) { [weak self] progress in
            Task { @MainActor in self?.capabilityExportProgress = progress }
        }
    }

    public func savePreparedCapabilityExport(to destinationURL: URL) async throws -> URL {
        guard let capabilityExportCoordinator else { throw CapabilityExportError.noPreparedPackage }
        isCapabilityExporting = true
        defer { isCapabilityExporting = false }
        return try await capabilityExportCoordinator.writePreparedPackage(to: destinationURL) { [weak self] progress in
            Task { @MainActor in self?.capabilityExportProgress = progress }
        }
    }

    public func cancelCapabilityExport() {
        guard let capabilityExportCoordinator else { return }
        Task { await capabilityExportCoordinator.cancel() }
    }

    public func discardPreparedCapabilityExport() {
        guard let capabilityExportCoordinator else { return }
        Task { try? await capabilityExportCoordinator.discardPrepared() }
        capabilityExportProgress = nil
    }

    /// Serializes cache revocation with the next cache consumer. This matters
    /// when service installation reuses the same actor-backed store: a late
    /// invalidation must finish before a new cache permit is activated.
    private func queueCacheInvalidation(_ snapshotStore: PresentationSnapshotStore?) {
        guard let snapshotStore else { return }
        presentationCachePermit = nil
        let prior = cacheInvalidationTask
        cacheInvalidationTask = Task {
            if let prior { await prior.value }
            await snapshotStore.invalidate()
        }
    }

    private func invalidateLifecycle() {
        lifecycleEpoch &+= 1
        presentationRequestSequence &+= 1
        detailRequestSequence &+= 1
        diagnosticsRequestSequence &+= 1
        diagnosticsLoading = false
        diagnosticsError = nil
        presentationDiagnostics = nil
        refreshScheduleState = nil
        backgroundRefreshError = nil
        schedulePersistenceRevision = 0
        for category in CapabilityCategory.allCases {
            libraryReloadGeneration[category.rawValue, default: 0] &+= 1
            libraryQueryStatus[category] = .idle
        }
        libraryPresentationKeys.removeAll(keepingCapacity: false)
        libraryResultContext.removeAll(keepingCapacity: false)
        sourceDataMonitorTask?.cancel()
        sourceDataMonitorTask = nil
        sourceMonitorActionTask?.cancel()
        sourceMonitorActionTask = nil
        cancelHomeRankingUpgrade()
        homeRankingRetryPending = false
        normalPresentationRefreshDeferred = false
        sourceMonitorGeneration &+= 1
        hasLoadedInitialData = false
        accountUsageRefreshScheduler?.stop()
        accountUsageRefreshScheduler = nil
        presentationRefreshCoordinator?.cancel()
        presentationRefreshCoordinator = nil
    }

    /// Installs the single app-scoped adaptive account schedule after the
    /// runtime locator has produced an account reader. This deliberately
    /// happens after cache/service bootstrap so no app-server process can be
    /// started before the app services are ready.
    private func configureAccountUsageRefreshScheduler() {
        accountUsageRefreshScheduler?.stop()
        accountUsageRefreshScheduler = nil
        guard accountUsageReading != nil else { return }

        let scheduler = AccountUsageRefreshScheduler(
            clock: nowProvider,
            systemState: MacAccountUsageSystemStateMonitor(),
            wakeScheduler: TaskAccountUsageWakeScheduler(clock: nowProvider),
            snapshot: accountUsageSnapshot,
            refresh: { [weak self] in
                guard let self else { return .unavailable }
                return await self.performScheduledAccountUsageRefresh()
            },
            cancelScheduledRefresh: { [weak self] in
                self?.cancelScheduledAccountUsageRefresh()
            }
        )
        accountUsageRefreshScheduler = scheduler
        scheduler.start(enabled: menuBarEnabled)
    }

    private func cancelScheduledAccountUsageRefresh() {
        presentationRefreshCoordinator?.cancelScheduledAccountUsage()
    }

    private func revokePresentationCache() {
        // Keep revocation in the same actor-ordered chain as replacement and
        // deletion.  An untracked Task could invalidate a newly activated
        // permit after a classification or refresh had already started.
        queueCacheInvalidation(presentationSnapshotStore)
    }

    public var hasDerivedDatabase: Bool {
        store != nil
    }

    public func setQuotaSourceID(_ id: String) {
        quotaSourceID = id
    }

    /// Current wall-clock value used by presentation-only scheduling and
    /// diagnostics. Tests inject `nowProvider`; production owns the clock.
    @Published public private(set) var presentationNow: Date

    /// Window lifecycle hooks are deliberately pure model state. App/window
    /// glue decides visibility and sleeping; this model never reads system
    /// workspace or preference state.
    public func setWindowVisibility(_ id: UUID, visible: Bool) {
        if visible { visibleWindowIDs.insert(id) }
        else { visibleWindowIDs.remove(id) }
        if visible {
            if hasLoadedInitialData {
                if !(normalPresentationRefreshDeferred && selection == .home) {
                    ensurePresentationRefreshCoordinator().scheduleStartup(domains: [.quota, .directory])
                }
                scheduleHomeRankingUpgradeIfNeeded()
            }
            restartSourceDataMonitor()
        }
        else { suspendPendingAutomaticWorkIfHidden() }
    }

    /// Schedules the one-time legacy Home Top5 upgrade. This is deliberately
    /// separate from the normal presentation refresh: it reads only the
    /// directory and bounded recent usage, never invokes source indexing or
    /// quota aggregation, and keeps the cached window/timestamps intact.
    private func scheduleHomeRankingUpgradeIfNeeded() {
        guard homeRankingUpgradeTask == nil,
              let home = presentationHomeSummary,
              home.rankingCapacity < PresentationHomeSummary.currentRankingCapacity,
              let window = statisticsWindow,
              readStore != nil,
              presentationSnapshotStore != nil,
              !visibleWindowIDs.isEmpty,
              selection == .home,
              !isSystemSleeping,
              !isDeletingDerivedData else { return }
        let now = nowProvider()
        if let projectionRetryDate = refreshScheduleState?.projectionRetryDate {
            if projectionRetryDate > now {
                // A legacy Top5 cache whose projection retry survived a
                // restart still owes the Home-only upgrade. Keep it pending
                // for the scheduler deadline rather than bypassing backoff.
                homeRankingRetryPending = true
                return
            }
        }
        let lifecycle = lifecycleEpoch
        let classification = classificationEpoch
        let classificationRevision = currentClassificationRevision
        homeRankingUpgradeGeneration &+= 1
        let upgradeGeneration = homeRankingUpgradeGeneration
        homeRankingUpgradeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.homeRankingUpgradeGeneration == upgradeGeneration {
                    self.homeRankingUpgradeTask = nil
                }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self,
                  lifecycle == self.lifecycleEpoch,
                  classification == self.classificationEpoch,
                  classificationRevision == self.currentClassificationRevision,
                  self.statisticsWindow == window,
                  self.presentationHomeSummary.map { $0.rankingCapacity < PresentationHomeSummary.currentRankingCapacity } == true,
                  !self.visibleWindowIDs.isEmpty,
                  !self.isSystemSleeping,
                  !self.isDeletingDerivedData else { return }
            let outcome = await self.ensurePresentationRefreshCoordinator().request(RefreshRequest(
                domains: [.homeRankings], reason: .automatic, force: true, sourceIntent: false
            ))
            guard lifecycle == self.lifecycleEpoch,
                  classification == self.classificationEpoch,
                  classificationRevision == self.currentClassificationRevision else { return }
            if case .failed = outcome {
                self.homeRankingRetryPending = true
            } else if outcome == .timedOut || outcome == .completed || outcome == .noNewData {
                self.homeRankingRetryPending = outcome == .timedOut
                if (outcome == .completed || outcome == .noNewData), self.normalPresentationRefreshDeferred {
                    self.normalPresentationRefreshDeferred = false
                    self.ensurePresentationRefreshCoordinator().scheduleStartup(domains: [.quota, .directory])
                }
            } else if outcome == .cancelled {
                return
            } else {
                self.homeRankingRetryPending = false
            }
        }
    }

    private func cancelHomeRankingUpgrade() {
        homeRankingUpgradeGeneration &+= 1
        homeRankingUpgradeTask?.cancel()
        homeRankingUpgradeTask = nil
    }

    public func removeWindow(_ id: UUID) {
        visibleWindowIDs.remove(id)
        suspendPendingAutomaticWorkIfHidden()
    }

    public func setSystemSleeping(_ value: Bool) {
        isSystemSleeping = value
        if value { suspendPendingAutomaticWorkIfHidden() }
        else {
            if !visibleWindowIDs.isEmpty, hasLoadedInitialData,
               !(normalPresentationRefreshDeferred && selection == .home) {
                ensurePresentationRefreshCoordinator().scheduleStartup(domains: [.quota, .directory])
            }
            restartSourceDataMonitor()
            scheduleHomeRankingUpgradeIfNeeded()
        }
    }

    /// Updates the calendar used for future seven-day projections. Existing
    /// statistics remain published until a successful projection completes.
    public func presentationClockDidChange(timeZone: TimeZone? = nil) {
        if let timeZone {
            var updated = statisticsCalendar
            updated.timeZone = timeZone
            statisticsCalendar = updated
        }
        presentationNow = nowProvider()
        lastStatisticsDay = nil
        restartSourceDataMonitor()
        guard !visibleWindowIDs.isEmpty, !isSystemSleeping else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshStatisticsIfNeeded(now: self.presentationNow)
        }
    }

    /// Loads bounded Settings diagnostics on demand; startup never calls this
    /// path and therefore never loads all findings or sessions.
    public func loadDiagnosticsIfNeeded(force: Bool = false) async {
        guard let readStore, !isDeletingDerivedData else { return }
        if !force, presentationDiagnostics != nil { return }
        diagnosticsRequestSequence &+= 1
        let sequence = diagnosticsRequestSequence
        let epoch = lifecycleEpoch
        let identity: PresentationIdentity
        do {
            identity = try await readStore.presentationIdentity()
        } catch {
            diagnosticsLoading = false
            diagnosticsError = "diagnostics_load_failed"
            return
        }
        diagnosticsLoading = true
        diagnosticsError = nil
        defer {
            if sequence == diagnosticsRequestSequence { diagnosticsLoading = false }
        }
        do {
            let summary = try await readStore.fetchPresentationDiagnostics()
            let currentIdentity = try await readStore.presentationIdentity()
            guard sequence == diagnosticsRequestSequence,
                  epoch == lifecycleEpoch,
                  summary.metadata.identity == identity,
                  currentIdentity == identity,
                  !isDeletingDerivedData,
                  !Task.isCancelled else { return }
            presentationDiagnostics = summary
        } catch {
            guard sequence == diagnosticsRequestSequence,
                  epoch == lifecycleEpoch,
                  !isDeletingDerivedData else { return }
            diagnosticsError = "diagnostics_load_failed"
        }
    }

    /// Explicit compatibility entry point for the Review destination. This
    /// is intentionally lazy; startup only publishes the compact projection.
    public func loadReviewIfNeeded() async {
        guard let readStore, !isDeletingDerivedData else { return }
        let ticket = beginDetailTicket()
        do {
            let identity = try await readStore.presentationIdentity()
            let findings = try await readStore.fetchAllFindings()
            let sessions = try await readStore.fetchAllSessions()
            let currentIdentity = try await readStore.presentationIdentity()
            guard isCurrent(ticket), currentIdentity == identity else { return }
            review = ReviewViewModel(findings: findings, sessions: sessions)
        } catch {
            if isCurrent(ticket) { backgroundRefreshError = "review_load_failed" }
        }
    }

    public var statisticsNow: Date { nowProvider() }

    /// Refreshes bounded seven-day statistics when the local Gregorian day
    /// changes. This never starts indexing or rereads source files.
    public func refreshStatisticsIfNeeded(now: Date? = nil) async {
        guard !visibleWindowIDs.isEmpty, !isSystemSleeping else { return }
        let instant = now ?? nowProvider()
        let day = statisticsCalendar.startOfDay(for: instant)
        guard lastStatisticsDay != day else { return }
        let outcome = await requestPresentationRefresh(reason: .dayChanged, force: true)
        if case .completed = outcome {
            lastStatisticsDay = day
        } else if case .failed = outcome {
            presentationState = .failure("statistics_refresh_failed")
        }
    }

    public var isSyntheticMode: Bool {
        presentationState == .preview
    }

    /// Home's inventory projection remains available to validation hosts and
    /// callers that need totals without constructing the Home view.
    public var inventory: HomeOverviewModel.InventoryTotals {
        let catalog = CapabilityCatalog(resources: capabilities.allRows.map(\.resource), relations: capabilities.relations)
        return HomeOverviewModel(catalog: catalog, usage: recentCapabilityStats).inventory
    }

    // MARK: - Indexing

    /// Runs the full indexing pass on the configured roots.
    public func startIndexing() async {
        _ = await requestPresentationRefresh(reason: .manual, force: true)
    }

    /// Long-running source work used by the application refresh worker. It
    /// deliberately does not go through the bounded presentation read path.
    @discardableResult
    private func performIndexing() async -> Bool {
        guard let store, let coordinator, let configuration, !isIndexing, !isDeletingDerivedData else { return false }
        let epoch = lifecycleEpoch
        isIndexing = true
        presentationState = .indexing
        sourceDataFresh = false
        indexingError = nil
        sourceProgressLastPublishedAt = nil
        indexingProgress = .init(phase: .scanning, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: nil)
        do {
            let result = try await coordinator.run(configuration: configuration) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycleEpoch == epoch, !self.isDeletingDerivedData else { return }
                    let now = self.nowProvider()
                    let terminal: Bool
                    switch progress.phase {
                    case .completed, .cancelled:
                        terminal = true
                    default:
                        terminal = false
                    }
                    guard terminal || self.sourceProgressLastPublishedAt.map({ now.timeIntervalSince($0) >= 0.1 }) != false else { return }
                    self.sourceProgressLastPublishedAt = now
                    self.indexingProgress = progress
                }
            }
            guard lifecycleEpoch == epoch, !isDeletingDerivedData else { return false }
            indexingProgress = .init(
                phase: result.cancelled ? .cancelled : .completed,
                processedFiles: result.processedFiles,
                // IndexingResult.processedFiles already counts unchanged
                // checkpoint hits; skippedFiles is its diagnostic subset.
                // Adding both made a completed incremental pass look only
                // partly finished in Settings (for example 1468/2915).
                totalFiles: result.processedFiles,
                indexedSessions: result.indexedSessions,
                lastError: nil
            )
            if !result.cancelled {
                try Task.checkCancellation()
                let completedAt = nowProvider()
                // Persist the two markers atomically before publishing a
                // successful source phase to the main-actor model.
                try await store.markSuccessfulSourceIndex(at: completedAt)
                guard lifecycleEpoch == epoch, !isDeletingDerivedData else { return false }
                presentationRefreshCoordinator?.setAutomaticSourceEnabled(true)
                diagnosticsRequestSequence &+= 1
                presentationDiagnostics = nil
                diagnosticsError = nil
                hasCompletedIndexPass = true
                lastIndexCompletedAt = completedAt
                sourceDataLastCheckedAt = completedAt
            }
            sourceDataFresh = !result.cancelled
            isIndexing = false
            presentationState = presentationStateAfterRefresh()
            return !result.cancelled
        } catch is CancellationError {
            guard lifecycleEpoch == epoch, !isDeletingDerivedData else { return false }
            indexingProgress = .init(phase: .cancelled, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: nil)
            sourceDataFresh = false
            isIndexing = false
            presentationState = presentationStateAfterRefresh()
        } catch {
            guard lifecycleEpoch == epoch, !isDeletingDerivedData else { return false }
            indexingError = error.localizedDescription
            indexingProgress = .init(phase: .completed, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: error.localizedDescription)
            sourceDataFresh = false
            isIndexing = false
            presentationState = .failure("indexing_failed")
        }
        isIndexing = false
        return false
    }

    /// Reloads all destinations from the derived index.
    public func refresh() async throws {
        guard let readStore, !isDeletingDerivedData else { throw CancellationError() }
        try await refreshStartupProjection()
        guard !isDeletingDerivedData else { throw CancellationError() }
        for library in libraryModels {
            await reloadLibrary(library.category, scope: library.context.scope)
        }
        let ticket = try await beginPresentationTicket(readStore: readStore, snapshotStore: nil)
        let resources = capabilities.allRows.map(\.resource)
        let relations = capabilities.relations
        let projects = capabilities.projects
        let provenance = capabilities.provenance
        let stats = try await readStore.fetchResourceUsageStats()
        let sessions = try await readStore.fetchAllSessions()
        let allTokens = try await readStore.fetchAllTokenSnapshots()
        let quotas = try await readStore.fetchAllQuotaSnapshots()
        let findings = try await readStore.fetchAllFindings()
        let taskCallSummaries = try await fetchTaskCallSummaries(sessions: sessions, store: readStore)
        try Task.checkCancellation()
        let currentIdentity = try await readStore.presentationIdentity()
        guard isCurrent(ticket), currentIdentity == ticket.identity else { throw CancellationError() }
        let evaluations = evaluationStore.all()
        capabilities.replaceData(
            resources: resources,
            stats: stats,
            relations: relations,
            projects: projects,
            provenance: provenance,
            evaluationCounts: Self.evaluationCounts(
                resources: resources,
                invocationsBySession: [:],
                evaluations: evaluations
            )
        )
        applyClassificationOverrides()
        tasks = TasksViewModel(
            sessions: sessions,
            invocationsBySession: [:],
            tokenSnapshotsBySession: [:],
            callSummaries: taskCallSummaries,
            evaluations: evaluations
        )
        usage = UsageViewModel(quotaSnapshots: quotas, tokenSnapshots: allTokens, now: nowProvider())
        review = ReviewViewModel(findings: findings, sessions: sessions)
        hasIndexedData = !capabilities.allRows.isEmpty || !sessions.isEmpty
        if !isIndexing { presentationState = presentationStateAfterRefresh() }
    }

    private func presentationStateAfterRefresh() -> DirectorPresentationState {
        if hasIndexedData { return .loaded }
        return hasCompletedIndexPass ? .empty : .initial
    }

    public func reloadLibrary(_ category: CapabilityCategory, scope: CapabilityBrowseScope) async {
        guard let readStore,
              !isDeletingDerivedData,
              let library = libraryModels.first(where: { $0.category == category }) else { return }
        let generation = (libraryReloadGeneration[category.rawValue] ?? 0) + 1
        libraryReloadGeneration[category.rawValue] = generation
        let requestedScope = scope
        libraryQueryStatus[category] = .loading
        library.isLoading = true
        library.loadError = nil
        defer {
            if libraryReloadGeneration[category.rawValue] == generation,
               library.context.scope == requestedScope,
               library.isLoading {
                library.isLoading = false
                libraryQueryStatus[category] = .idle
            }
        }
        let projectID: String?
        if case .project(let id) = scope { projectID = id } else { projectID = nil }
        let window = statisticsWindow ?? CapabilityQueryWindow.recent7(now: nowProvider(), calendar: statisticsCalendar)
        do {
            // Capture the identity and classification fingerprint before the
            // bounded DTO query. The key prevents a later database generation
            // or classification from being attached to an older result.
            let identity = try await readStore.presentationIdentity()
            let classificationRevision = currentClassificationRevision
            let key = LibraryPresentationKey(
                category: category,
                scope: requestedScope,
                window: window,
                identity: identity,
                classificationRevision: classificationRevision
            )
            guard isCurrentLibraryRequest(category: category, generation: generation, scope: requestedScope) else { return }
            if libraryPresentationKeys[category.rawValue] == key,
               libraryResultContext[category]?.scope == requestedScope,
               libraryResultContext[category]?.window == window {
                library.isLoading = false
                libraryQueryStatus[category] = .loaded(window)
                return
            }
            let snapshot = try await readStore.fetchLibraryPresentation(
                category: category,
                window: window,
                projectID: projectID
            )
            let currentIdentity = try await readStore.presentationIdentity()
            guard isCurrentLibraryRequest(category: category, generation: generation, scope: requestedScope),
                  snapshot.metadata.identity == key.identity,
                  currentIdentity == key.identity,
                  currentClassificationRevision == key.classificationRevision else { return }
            library.isLoading = false
            library.setData(
                catalog: library.catalog,
                categoryStats: snapshot.categoryUsage,
                browseStats: snapshot.browseUsage,
                browseHistory: snapshot.browseHistory,
                usageProjects: snapshot.usageProjects,
                category30DayStats: snapshot.category30DayUsage,
                browse30DayStats: snapshot.browse30DayUsage,
                categoryHistory: snapshot.categoryHistory
            )
            library.setPluginData(
                snapshot.categoryPluginUsage,
                browseStats: snapshot.browsePluginUsage,
                category30DayStats: snapshot.categoryPlugin30DayUsage,
                browse30DayStats: snapshot.browsePlugin30DayUsage,
                attributionUnavailableCount: snapshot.pluginAttributionUnavailableCount
            )
            libraryPresentationKeys[category.rawValue] = key
            libraryResultContext[category] = DirectorLibraryResultContext(scope: requestedScope, window: window)
            libraryQueryStatus[category] = .loaded(window)
        } catch {
            guard isCurrentLibraryRequest(category: category, generation: generation, scope: requestedScope) else { return }
            library.isLoading = false
            library.loadError = error.localizedDescription
            libraryQueryStatus[category] = .failed
        }
    }

    private func isCurrentLibraryRequest(
        category: CapabilityCategory,
        generation: Int,
        scope: CapabilityBrowseScope
    ) -> Bool {
        !isDeletingDerivedData &&
        libraryReloadGeneration[category.rawValue] == generation &&
        libraryModels.first(where: { $0.category == category })?.context.scope == scope &&
        !Task.isCancelled
    }

    /// Applies an explicit local evaluation without re-indexing the derived
    /// database. Only Agent and Skill events with a current canonical resource
    /// ID participate in capability evaluation aggregates.
    public func setEvaluation(
        for event: InvocationEvent,
        label: InvocationEvaluationLabel,
        updatedAt: Date = Date()
    ) {
        guard let resourceID = event.resourceID,
              let row = capabilities.allRows.first(where: { $0.id == resourceID }),
              (row.resource.kind == .agent || row.resource.kind == .skill),
              event.kind == .agent || event.kind == .skill
        else { return }

        let evaluation = InvocationEvaluation(
            invocationID: event.id,
            sessionID: event.sessionID,
            resourceID: resourceID,
            label: label,
            updatedAt: updatedAt
        )
        guard evaluationStore.set(evaluation) else { return }
        if let prior = tasks.evaluation(for: event.id) {
            capabilities.clearEvaluation(prior)
        }
        tasks.setEvaluation(evaluation)
        capabilities.setEvaluation(evaluation)
    }

    public func clearEvaluation(for invocationID: String) {
        guard let prior = tasks.evaluation(for: invocationID) else { return }
        guard evaluationStore.remove(for: invocationID) else { return }
        tasks.clearEvaluation(for: invocationID)
        capabilities.clearEvaluation(prior)
    }

    /// Persists an independent filesystem Skill classification correction and updates the live
    /// projection immediately. Re-indexing will reapply it from preferences.
    public func classify(resourceID: String, ownership: ResourceOwnership) {
        guard let current = capabilities.allRows.first(where: { $0.id == resourceID }),
              current.resource.isSkillClassificationCorrectable,
              ownership == .userOwned || ownership == .installed else { return }
        let origin = current.resource.manualClassificationOrigin(for: ownership)
        classificationOverrides.set(ResourceClassificationOverride(ownership: ownership, origin: origin), for: resourceID)
        capabilities.applyClassification(ownership, for: resourceID, origin: origin)
        classificationDidChange()
        if let current = configuration {
            configuration = IndexingCoordinator.Configuration(
                scanRoots: current.scanRoots,
                activeSessionRoots: current.activeSessionRoots,
                archivedSessionRoot: current.archivedSessionRoot,
                classificationOverrides: classificationOverrides.all(),
                skillOwnershipRegistryURL: current.skillOwnershipRegistryURL
            )
        }
    }

    public func resetClassification(resourceID: String) {
        guard let current = capabilities.allRows.first(where: { $0.id == resourceID }),
              current.resource.isSkillClassificationCorrectable else { return }
        classificationOverrides.remove(for: resourceID)
        capabilities.resetClassification(for: resourceID)
        classificationDidChange()
        if let current = configuration {
            configuration = IndexingCoordinator.Configuration(
                scanRoots: current.scanRoots,
                activeSessionRoots: current.activeSessionRoots,
                archivedSessionRoot: current.archivedSessionRoot,
                classificationOverrides: classificationOverrides.all(),
                skillOwnershipRegistryURL: current.skillOwnershipRegistryURL
            )
        }
    }

    public func resetAllClassifications() {
        classificationOverrides.removeAll()
        capabilities.resetAllClassifications()
        classificationDidChange()
        if let current = configuration {
            configuration = IndexingCoordinator.Configuration(
                scanRoots: current.scanRoots,
                activeSessionRoots: current.activeSessionRoots,
                archivedSessionRoot: current.archivedSessionRoot,
                classificationOverrides: [:],
                skillOwnershipRegistryURL: current.skillOwnershipRegistryURL
            )
        }
    }

    private func syncLibraryCatalog() {
        let catalog = CapabilityCatalog(resources: capabilities.allRows.map(\.resource), relations: capabilities.relations).entries
        for library in libraryModels {
            library.setDirectory(catalog: catalog, projects: library.projects)
        }
    }

    private func classificationDidChange() {
        classificationEpoch &+= 1
        presentationRequestSequence &+= 1
        cancelHomeRankingUpgrade()
        homeRankingRetryPending = false
        detailRequestSequence &+= 1
        for category in CapabilityCategory.allCases {
            libraryReloadGeneration[category.rawValue, default: 0] &+= 1
            libraryQueryStatus[category] = .idle
        }
        libraryPresentationKeys.removeAll(keepingCapacity: false)
        syncLibraryCatalog()
        presentationHomeSummary = HomeOverviewModel(
            catalog: CapabilityCatalog(resources: capabilities.allRows.map(\.resource), relations: capabilities.relations),
            usage: recentCapabilityStats
        ).presentationSummary
        revokePresentationCache()
    }

    /// Re-runs indexing when source sessions were modified after the last refresh.
    public func ensureSourceDataFresh(stalenessWindow: TimeInterval = 60) async {
        guard hasDerivedDatabase, coordinator != nil, configuration != nil, !isIndexing else { return }
        _ = await requestPresentationRefresh(reason: .automatic, force: false)
    }

    /// Runs one bounded presentation projection through the application-wide
    /// scheduler. Source indexing is intentionally outside this 5-second
    /// presentation operation.
    @discardableResult
    public func requestPresentationRefresh(
        reason: RefreshReason = .automatic,
        force: Bool = false,
        domains: Set<RefreshDomain> = [.quota, .directory]
    ) async -> RefreshOutcome {
        guard hasDerivedDatabase, !isDeletingDerivedData else { return .cancelled }
        if (reason == .automatic || reason == .startup) && (visibleWindowIDs.isEmpty || isSystemSleeping) {
            return .cancelled
        }
        let effectiveForce = force || reason == .manual
        return await ensurePresentationRefreshCoordinator().request(
            RefreshRequest(
                domains: domains,
                reason: reason,
                force: effectiveForce
            )
        )
    }

    private func ensurePresentationRefreshCoordinator() -> RefreshCoordinator {
        if let presentationRefreshCoordinator { return presentationRefreshCoordinator }
        let coordinator = RefreshCoordinator(
            clock: nowProvider,
            sourceOperation: { [weak self] request in
                guard let self else { return .cancelled }
                return await self.refreshSourceIfDue(request: request)
            },
            operation: { [weak self] request in
            guard let self else { return .cancelled }
            if !(await self.automaticWorkAllowed(for: request.reason)) {
                return .cancelled
            }
            do {
                if request.domains == [.homeRankings] {
                    try await self.refreshHomeRankings()
                    return .completed
                }
                let needsPresentation = request.domains.contains(.quota)
                    || request.domains.contains(.directory)
                    || request.domains.contains(.currentPage)
                    || request.domains.contains(.detail)
                if needsPresentation {
                    try await self.refreshStartupProjection()
                }
                if request.domains.contains(.accountUsage) {
                    // This is deliberately immediately before the reader,
                    // after the shared coordinator has coalesced all waiters.
                    // A scheduled account request must not cross a lock,
                    // sleep, Low Power Mode, or menu-bar disable transition.
                    if request.reason == .accountUsageAutomatic {
                        guard await self.accountUsageRefreshScheduler?.isCurrentlyEligible == true else {
                            return .cancelled
                        }
                    }
                    try await self.refreshAccountUsage()
                }
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed("presentation_refresh_failed")
            }
            }
        )
        coordinator.setAutomaticSourceEnabled(
            self.coordinator != nil && self.configuration != nil && (hasCompletedIndexPass || hasIndexedData)
        )
        coordinator.setStateChangeHandler { [weak self] state in
            guard let self else { return }
            self.handleScheduleStateChange(state)
        }
        refreshScheduleState = coordinator.scheduleState
        presentationRefreshCoordinator = coordinator
        return coordinator
    }

    private func automaticWorkAllowed(for reason: RefreshReason) -> Bool {
        if reason == .accountUsageAutomatic {
            // Menu-bar account reads remain available with the main window
            // closed, but the adaptive scheduler is stopped while disabled.
            return menuBarEnabled
                && accountUsageReading != nil
                && !isSystemSleeping
                && accountUsageRefreshScheduler?.isCurrentlyEligible == true
        }
        if reason == .automatic || reason == .startup {
            // The first bounded projection is owned by the scheduler too, so
            // its projection retry lane is durable even before a window has
            // registered. Later automatic/startup work remains window-gated.
            let isInitialProjection = reason == .startup && !hasLoadedInitialData
            return !isSystemSleeping && (isInitialProjection || !visibleWindowIDs.isEmpty)
        }
        return true
    }

    private func handleScheduleStateChange(_ state: RefreshScheduleState) {
        let previousState = refreshScheduleState
        refreshScheduleState = state
        if case .failed = state.phase {
            backgroundRefreshError = "presentation_refresh_failed"
        } else {
            backgroundRefreshError = nil
        }
        // Account-only menu-bar work also traverses the shared coordinator's
        // ephemeral projection phase. Its revision changes must not turn a
        // quota read into a SQLite/cache write. Persist only the source and
        // projection retry metadata that the presentation scheduler owns.
        guard scheduleStateMetadataChanged(from: previousState, to: state) else { return }
        guard state.revision >= schedulePersistenceRevision,
              let snapshotStore = presentationSnapshotStore,
              let readStore else { return }
        schedulePersistenceRevision = state.revision
        let lifecycle = lifecycleEpoch
        let revision = state.revision
        let schedule = PresentationRefreshSchedule(
            revision: state.revision,
            recordedAt: nowProvider(),
            lastSourceSuccessAt: state.lastSourceSuccessAt,
            sourceRetryAttempt: state.sourceRetryAttempt,
            sourceRetryDate: state.sourceRetryDate,
            projectionRetryAttempt: state.projectionRetryAttempt,
            projectionRetryDate: state.projectionRetryDate
        )
        let scheduleClassificationRevision = currentClassificationRevision
        let scheduleWindow = statisticsWindow
            ?? CapabilityQueryWindow.recent7(now: nowProvider(), calendar: statisticsCalendar)
        Task { @MainActor [weak self] in
            guard let self,
                  self.lifecycleEpoch == lifecycle,
                  self.refreshScheduleState?.revision == revision,
                  !self.isDeletingDerivedData else { return }
            guard let identity = try? await readStore.presentationIdentity() else { return }
            guard self.lifecycleEpoch == lifecycle,
                  self.refreshScheduleState?.revision == revision,
                  !self.isDeletingDerivedData else { return }
            guard let permit = self.presentationCachePermit else { return }
            try? await snapshotStore.updateSchedule(
                schedule,
                databaseEpoch: identity.databaseEpoch,
                permit: permit,
                classificationRevision: scheduleClassificationRevision,
                window: scheduleWindow
            )
        }
    }

    private func scheduleStateMetadataChanged(
        from previous: RefreshScheduleState?,
        to current: RefreshScheduleState
    ) -> Bool {
        guard let previous else { return true }
        return previous.lastSourceSuccessAt != current.lastSourceSuccessAt
            || previous.sourceRetryAttempt != current.sourceRetryAttempt
            || previous.sourceRetryDate != current.sourceRetryDate
            || previous.projectionRetryAttempt != current.projectionRetryAttempt
            || previous.projectionRetryDate != current.projectionRetryDate
    }

    /// Performs a source freshness check only when its persisted success is
    /// absent/expired or when the user explicitly forced a refresh. An empty
    /// first-run database is intentionally not auto-indexed.
    private func refreshSourceIfDue(request: RefreshRequest) async -> SourceRefreshOutcome {
        if (request.reason == .automatic || request.reason == .startup) &&
            (visibleWindowIDs.isEmpty || isSystemSleeping) {
            return .cancelled
        }
        // The coordinator marks commit/day-change work as projection-only.
        // Use that explicit intent rather than the reason alone so merged
        // follow-up requests cannot accidentally start a source scan.
        guard request.sourceIntent,
              request.reason != .indexCommitted,
              request.reason != .dayChanged else { return .skipped }
        guard coordinator != nil, configuration != nil else {
            // A bounded presentation-only model (for example a validation
            // host) can still refresh its derived projection, but it cannot
            // claim that a source check succeeded.
            return .skipped
        }

        let now = nowProvider()
        let force = request.force || request.reason == .manual
        let sourceCheckDue: Bool = {
            guard !force, let checked = sourceDataLastCheckedAt, checked <= now else { return true }
            return now.timeIntervalSince(checked) >= 30 * 60
        }()
        guard sourceCheckDue else { return .skipped }

        let hasExistingIndex = hasCompletedIndexPass || hasIndexedData
        // Incremental indexing is the source check: it covers resource roots
        // as well as session logs and skips unchanged checkpoints. Automatic
        // startup never creates the first index for an empty database, while
        // an explicit manual request may do so.
        if force || hasExistingIndex {
            if await performIndexing() {
                // performIndexing publishes the exact persisted marker only
                // after markSuccessfulSourceIndex succeeds.
                return .succeeded(sourceDataLastCheckedAt ?? now)
            }
            return indexingError == nil ? .cancelled : .failed("source_refresh_failed")
        }

        // No source work was attempted. Keep the source-check marker
        // unchanged so an empty first run cannot masquerade as indexed data.
        return .skipped
    }

    /// Starts a background loop that re-checks source freshness and re-indexes
    /// when needed. Useful while the app stays open and source sessions keep
    /// getting appended.
    public func startSourceDataMonitor(pollInterval: TimeInterval = 30 * 60) {
        guard !visibleWindowIDs.isEmpty else { return }
        if sourceDataMonitorTask != nil { return }
        sourceMonitorGeneration &+= 1
        let generation = sourceMonitorGeneration
        sourceDataMonitorTask = Task { @MainActor [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    if let self, self.sourceMonitorGeneration == generation {
                        self.sourceDataMonitorTask = nil
                    }
                }
            }
            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    guard let self else { return }
                    delay = self.advanceSourceMonitor(generation: generation, pollInterval: pollInterval)
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
    }

    private func advanceSourceMonitor(generation: UInt64, pollInterval: TimeInterval) -> TimeInterval {
        presentationNow = nowProvider()
        let now = presentationNow
        let currentDay = statisticsCalendar.startOfDay(for: now)
        if monitorStatisticsDay == nil {
            let publishedDay = lastStatisticsDay
                ?? statisticsWindow.map { statisticsCalendar.startOfDay(for: $0.end) }
                ?? currentDay
            monitorStatisticsDay = publishedDay
            if publishedDay != currentDay { pendingMonitorDayProjection = true }
        } else if monitorStatisticsDay != currentDay {
            monitorStatisticsDay = currentDay
            pendingMonitorDayProjection = true
        }

        var wakeDate = nextPresentationWakeDate(after: now)
        let broadAutomaticAllowed = !(normalPresentationRefreshDeferred && selection == .home)
        if !visibleWindowIDs.isEmpty,
           !isSystemSleeping,
           readStore != nil,
           hasLoadedInitialData {
            let scheduler = ensurePresentationRefreshCoordinator()
            let schedulerDue = broadAutomaticAllowed && scheduler.nextWakeDate.map { $0 <= now } == true
            let dayDue = broadAutomaticAllowed && pendingMonitorDayProjection
            let homeRetryDue = homeRankingRetryPending &&
                (scheduler.scheduleState.projectionRetryDate.map { $0 <= now } == true)
            if (schedulerDue || dayDue || homeRetryDue),
               !scheduler.isRunning,
               sourceMonitorActionTask == nil {
                if !homeRetryDue { pendingMonitorDayProjection = false }
                let reason: RefreshReason = dayDue && !homeRetryDue ? .dayChanged : .automatic
                let actionGeneration = generation
                sourceMonitorActionTask = Task { @MainActor [weak self] in
                    defer {
                        if let self, self.sourceMonitorGeneration == actionGeneration {
                            self.sourceMonitorActionTask = nil
                        }
                    }
                    let outcome: RefreshOutcome
                    if homeRetryDue {
                        outcome = await scheduler.request(RefreshRequest(
                            domains: [.homeRankings], reason: .automatic, force: true, sourceIntent: false
                        ))
                    } else if reason == .dayChanged {
                        outcome = await scheduler.request(RefreshRequest(
                            domains: [.quota, .directory],
                            reason: .dayChanged,
                            force: true,
                            sourceIntent: false
                        ))
                    } else {
                        outcome = await scheduler.requestAutomatic(domains: [.quota, .directory])
                    }
                    guard let self,
                          self.sourceMonitorGeneration == actionGeneration,
                          !self.isDeletingDerivedData else { return }
                    if case .failed = outcome {
                        self.backgroundRefreshError = "presentation_refresh_failed"
                    } else if homeRetryDue, outcome == .completed || outcome == .noNewData {
                        self.homeRankingRetryPending = false
                    } else if homeRetryDue, outcome == .timedOut {
                        self.homeRankingRetryPending = true
                    }
                }
                wakeDate = nil
            }
            if !broadAutomaticAllowed && !homeRankingRetryPending {
                // The delayed Home task owns the next wake while the broad
                // expired-cache refresh is deferred; avoid a due-date busy
                // loop in the monitor until that isolated batch completes.
                wakeDate = nil
            }
        }
        let requestedDelay = wakeDate.map { max(0, $0.timeIntervalSince(now)) } ?? pollInterval
        return min(60, max(0.05, requestedDelay))
    }

    private func nextPresentationWakeDate(after now: Date) -> Date? {
        var dates: [Date] = []
        if let scheduler = presentationRefreshCoordinator,
           let date = scheduler.nextWakeDate,
           date > now {
            dates.append(date)
        }
        if let midnight = statisticsCalendar.date(
            byAdding: .day,
            value: 1,
            to: statisticsCalendar.startOfDay(for: now)
        ), midnight > now {
            dates.append(midnight)
        }
        if let quotaOverviewSnapshot {
            for source in quotaOverviewSnapshot.sources {
                let snapshots = source.daily.compactMap(\.observation) + [source.current].compactMap { $0 }
                if let reset = snapshots.compactMap(\.resetsAt).filter({ $0 > now }).min() {
                    dates.append(reset)
                }
            }
        }
        return dates.min()
    }

    private func restartSourceDataMonitor() {
        sourceMonitorGeneration &+= 1
        sourceDataMonitorTask?.cancel()
        sourceDataMonitorTask = nil
        sourceMonitorActionTask?.cancel()
        sourceMonitorActionTask = nil
        startSourceDataMonitor()
    }

    /// RefreshCoordinator has no knowledge of application windows. Remove a
    /// queued automatic startup/waiting batch while there is no visible awake
    /// window, but leave source/projection work already in flight untouched.
    /// The scheduler's persisted retry/success fields remain available for a
    /// later visible request; suspension is not reported as a failure.
    private func suspendPendingAutomaticWorkIfHidden() {
        cancelHomeRankingUpgrade()
        if visibleWindowIDs.isEmpty {
            stopSourceDataMonitor()
        }
        guard visibleWindowIDs.isEmpty || isSystemSleeping,
              let scheduler = presentationRefreshCoordinator,
              scheduler.scheduleState.phase == .startupGrace || scheduler.scheduleState.phase == .waiting else { return }
        scheduler.cancel()
    }

    public func stopSourceDataMonitor() {
        sourceMonitorGeneration &+= 1
        sourceDataMonitorTask?.cancel()
        sourceDataMonitorTask = nil
        sourceMonitorActionTask?.cancel()
        sourceMonitorActionTask = nil
        cancelHomeRankingUpgrade()
    }

    deinit {
        sourceDataMonitorTask?.cancel()
        sourceDataMonitorTask = nil
        sourceMonitorActionTask?.cancel()
        sourceMonitorActionTask = nil
        homeRankingUpgradeTask?.cancel()
        homeRankingUpgradeTask = nil
    }

    private var currentClassificationRevision: String {
        PresentationClassificationRevision.make(classificationOverrides.all())
    }

    private func beginDisplayTicket() -> DisplayTicket {
        presentationRequestSequence &+= 1
        return DisplayTicket(
            lifecycleEpoch: lifecycleEpoch,
            requestSequence: presentationRequestSequence,
            classificationEpoch: classificationEpoch,
            classificationRevision: currentClassificationRevision
        )
    }

    private func isCurrent(_ ticket: DisplayTicket) -> Bool {
        ticket.lifecycleEpoch == lifecycleEpoch &&
        ticket.requestSequence == presentationRequestSequence &&
        ticket.classificationEpoch == classificationEpoch &&
        ticket.classificationRevision == currentClassificationRevision &&
        !isDeletingDerivedData &&
        !Task.isCancelled
    }

    private func beginDetailTicket() -> DetailTicket {
        detailRequestSequence &+= 1
        return DetailTicket(
            lifecycleEpoch: lifecycleEpoch,
            sequence: detailRequestSequence,
            classificationEpoch: classificationEpoch,
            classificationRevision: currentClassificationRevision
        )
    }

    private func isCurrent(_ ticket: DetailTicket) -> Bool {
        ticket.lifecycleEpoch == lifecycleEpoch &&
        ticket.sequence == detailRequestSequence &&
        ticket.classificationEpoch == classificationEpoch &&
        ticket.classificationRevision == currentClassificationRevision &&
        !isDeletingDerivedData &&
        !Task.isCancelled
    }

    private func isCurrentLifecycle(_ ticket: DisplayTicket) -> Bool {
        ticket.lifecycleEpoch == lifecycleEpoch &&
        ticket.classificationEpoch == classificationEpoch &&
        ticket.classificationRevision == currentClassificationRevision &&
        !isDeletingDerivedData &&
        !Task.isCancelled
    }

    private func beginPresentationTicket(
        readStore: DatabaseStore,
        snapshotStore: PresentationSnapshotStore?
    ) async throws -> PresentationTicket {
        guard !isDeletingDerivedData else { throw CancellationError() }
        let dependencyLifecycle = lifecycleEpoch
        let dependencyClassification = classificationEpoch
        let dependencySnapshotStore = presentationSnapshotStore
        // A classification/reset or service replacement may have queued a
        // revocation on this same cache actor. Do not activate a new permit
        // until that barrier drains, or the late revoke could invalidate the
        // request we are about to publish.
        if let cacheInvalidationTask {
            await cacheInvalidationTask.value
            guard dependencyLifecycle == lifecycleEpoch,
                  dependencyClassification == classificationEpoch,
                  !isDeletingDerivedData,
                  let currentReadStore = self.readStore,
                  ObjectIdentifier(currentReadStore) == ObjectIdentifier(readStore)
            else { throw CancellationError() }
            let snapshotStoreUnchanged: Bool = switch (self.presentationSnapshotStore, dependencySnapshotStore) {
            case (nil, nil): true
            case let (.some(current), .some(original)): ObjectIdentifier(current) == ObjectIdentifier(original)
            default: false
            }
            guard snapshotStoreUnchanged else { throw CancellationError() }
        }
        presentationRequestSequence &+= 1
        let requestSequence = presentationRequestSequence
        let lifecycle = lifecycleEpoch
        let classification = classificationEpoch
        let revision = currentClassificationRevision
        // Identity and the cache permit are captured before any potentially
        // slow DTO query. A later identity is never allowed to relabel this
        // request's quota or Home result.
        let identity = try await readStore.presentationIdentity()
        guard lifecycle == lifecycleEpoch,
              requestSequence == presentationRequestSequence,
              classification == classificationEpoch,
              !isDeletingDerivedData else { throw CancellationError() }
        let permit: PresentationSnapshotStore.WritePermit?
        if let snapshotStore {
            let issuedPermit = await snapshotStore.activate(identity: identity)
            presentationCachePermit = issuedPermit
            permit = issuedPermit
        } else {
            permit = nil
        }
        guard lifecycle == lifecycleEpoch,
              requestSequence == presentationRequestSequence,
              classification == classificationEpoch,
              !isDeletingDerivedData else { throw CancellationError() }
        return PresentationTicket(
            lifecycleEpoch: lifecycle,
            requestSequence: requestSequence,
            classificationEpoch: classification,
            classificationRevision: revision,
            identity: identity,
            permit: permit
        )
    }

    private func isCurrent(_ ticket: PresentationTicket) -> Bool {
        ticket.lifecycleEpoch == lifecycleEpoch &&
        ticket.requestSequence == presentationRequestSequence &&
        ticket.classificationEpoch == classificationEpoch &&
        ticket.classificationRevision == currentClassificationRevision &&
        !isDeletingDerivedData &&
        !Task.isCancelled
    }

    private func classifiedCatalog(
        resources: [CapabilityResource],
        relations: [ResourceRelation]
    ) -> CapabilityCatalog {
        let projected = CapabilitiesViewModel(resources: resources, relations: relations)
        applyClassificationOverrides(to: projected)
        return CapabilityCatalog(resources: projected.allRows.map(\.resource), relations: projected.relations)
    }

    private func applyClassificationOverrides() {
        applyClassificationOverrides(to: capabilities)
    }

    private func applyClassificationOverrides(to model: CapabilitiesViewModel) {
        for (resourceID, override) in classificationOverrides.all() {
            guard let row = model.allRows.first(where: { $0.id == resourceID }),
                  row.resource.isSkillClassificationCorrectable else { continue }
            if let baseline = automaticClassificationBaseline(
                for: row.resource,
                provenance: model.provenance.filter { $0.resourceID == resourceID }
            ) {
                model.setClassificationBaseline(baseline)
            }
            model.applyClassification(override.ownership, for: resourceID, origin: override.origin)
        }
    }

    private func automaticClassificationBaseline(
        for resource: CapabilityResource,
        provenance: [CapabilityProvenance]
    ) -> CapabilityResource? {
        guard let record = provenance.sorted(by: {
            let leftRank = $0.confidence == .exact ? 0 : ($0.confidence == .inferred ? 1 : 2)
            let rightRank = $1.confidence == .exact ? 0 : ($1.confidence == .inferred ? 1 : 2)
            if leftRank != rightRank { return leftRank < rightRank }
            return $0.id < $1.id
        }).first else { return nil }

        let ownership: ResourceOwnership
        let origin: ResourceOrigin
        let confidence: EvidenceConfidence
        switch record.sourceType {
        case .github, .registry:
            ownership = .installed
            origin = record.sourceType
            confidence = record.confidence
        case .unknown:
            ownership = .installed
            origin = .unknown
            confidence = record.confidence
        case .local where record.sourceIdentifier == "global-skill-library"
            || record.sourceIdentifier == "project-skill-directory"
            || resource.scope == .project:
            ownership = .userOwned
            origin = .local
            confidence = record.confidence
        case .local:
            // Legacy global local/inferred records had no positive ownership
            // evidence and therefore follow the new installed fallback.
            ownership = .installed
            origin = .unknown
            confidence = .inferred
        case .codexSystem, .plugin, .runtime:
            return nil
        }

        let preservesSource = ownership == .installed && (origin == .github || origin == .registry)
        return CapabilityResource(
            id: resource.id,
            name: resource.name,
            kind: resource.kind,
            status: resource.status,
            scope: resource.scope,
            projectID: resource.projectID,
            confidence: resource.confidence,
            summary: resource.summary,
            sourceRootID: resource.sourceRootID,
            relativeSourcePath: resource.relativeSourcePath,
            sourcePathHash: resource.sourcePathHash,
            lastSeenAt: resource.lastSeenAt,
            ownership: ownership,
            origin: origin,
            classificationConfidence: confidence,
            originIdentifier: preservesSource ? record.sourceIdentifier : nil,
            sourceVersion: preservesSource ? record.version : nil,
            contentFingerprint: resource.contentFingerprint,
            sourceModifiedAt: resource.sourceModifiedAt,
            modified: resource.modified
        )
    }

    private func applyCachedPresentation(_ snapshot: PresentationSnapshot) {
        quotaOverviewSnapshot = snapshot.quota
        accountUsageSnapshot = snapshot.accountUsage
        accountUsageRefreshScheduler?.updateSnapshot(snapshot.accountUsage)
        accountUsageError = nil
        presentationHomeSummary = snapshot.home
        statisticsWindow = snapshot.window
        hasComputedStatistics = snapshot.quota != nil
        if let quota = snapshot.quota {
            recentCapabilityStats = []
            quotaSourceID = quotaSourceID ?? quota.sources.first?.id
        }
        lastIndexCompletedAt = snapshot.lastIndexCompletedAt
        sourceDataLastCheckedAt = snapshot.lastSourceCheckAt
        let now = nowProvider()
        lastRefresh = min(snapshot.generatedAt, now)
        hasCompletedIndexPass = snapshot.lastIndexCompletedAt != nil
        presentationState = snapshot.home == nil ? .initial : .loaded
        lastStatisticsDay = statisticsCalendar.startOfDay(for: min(snapshot.window.end, now))
        syncMonitorDayToPublishedWindow(snapshot.window, now: now)
        sourceDataFresh = false
    }

    /// Reconciles the monitor's day marker with the actual published window.
    /// A ticker may have started before cache restoration and observed today;
    /// the cache's older, still-valid window must then schedule one projection
    /// rather than being mistaken for today's statistics.
    private func syncMonitorDayToPublishedWindow(_ window: CapabilityQueryWindow, now: Date) {
        let publishedDay = statisticsCalendar.startOfDay(for: min(window.end, now))
        let currentDay = statisticsCalendar.startOfDay(for: now)
        monitorStatisticsDay = publishedDay
        pendingMonitorDayProjection = publishedDay != currentDay
    }

    private func invalidateCachedPresentation() {
        quotaOverviewSnapshot = nil
        accountUsageSnapshot = nil
        accountUsageRefreshScheduler?.updateSnapshot(nil)
        accountUsageError = nil
        presentationHomeSummary = nil
        recentCapabilityStats = []
        statisticsWindow = nil
        hasComputedStatistics = false
        quotaSourceID = nil
        lastRefresh = nil
        lastIndexCompletedAt = nil
        sourceDataLastCheckedAt = nil
        hasCompletedIndexPass = false
        hasIndexedData = false
        directoryLoaded = false
        presentationState = hasDerivedDatabase ? .initial : .failure("derived_database_unavailable")
    }

    /// Restores only the compact cache before a database or configuration is
    /// opened. Identity is unverified until the read-only store reconciles it.
    @discardableResult
    public func restoreCachedPresentation() async -> Bool {
        guard let snapshotStore = presentationSnapshotStore, !isDeletingDerivedData else { return false }
        let ticket = beginDisplayTicket()
        bootstrapStatus = .restoringCache
        do {
            guard let snapshot = try await snapshotStore.read(),
                  isCurrent(ticket),
                  snapshot.classificationRevision == currentClassificationRevision,
                  snapshot.quota != nil || snapshot.home != nil else {
                if isCurrent(ticket) { cacheStatus = .stale }
                return false
            }
            applyCachedPresentation(snapshot)
            cacheStatus = .restoredUnverified
            return true
        } catch {
            if isCurrent(ticket) { cacheStatus = .unavailable }
            return false
        }
    }

    /// Loads already-indexed data once on launch. No-op in synthetic mode.
    /// The return value reports whether a compatible cache was restored; a
    /// cache miss can still complete a fresh projection and leave the model
    /// ready while returning `false`.
    @discardableResult
    public func loadInitialData() async -> Bool {
        guard !hasLoadedInitialData, !isDeletingDerivedData else { return false }
        if let cacheInvalidationTask {
            await cacheInvalidationTask.value
            guard !isDeletingDerivedData else { return false }
        }
        guard hasDerivedDatabase else { return await restoreCachedPresentation() }
        let ticket = beginDisplayTicket()
        if let snapshotStore = presentationSnapshotStore, let readStore {
            let directory: PresentationDirectorySnapshot
            do {
                directory = try await readStore.fetchPresentationDirectory()
                let authoritativeIdentity = try await readStore.presentationIdentity()
                guard isCurrent(ticket), authoritativeIdentity == directory.metadata.identity else { return false }
                // Establish the cache lifecycle permit after the authoritative
                // DB identity is known, before restoring scheduler metadata.
                // The payload may still be an older generation in this epoch.
                presentationCachePermit = await snapshotStore.activate(identity: authoritativeIdentity)
            } catch {
                // A reader/database failure must not erase a legally restored
                // cache. Keep it visible as old/unverified and expose failure
                // state so a later retry can reconcile it.
                if isCurrent(ticket), (presentationHomeSummary != nil || quotaOverviewSnapshot != nil) {
                    cacheStatus = .restoredUnverified
                }
                if isCurrent(ticket) {
                    indexingError = "initial_data_load_failed"
                    presentationState = .failure("initial_data_load_failed")
                    bootstrapStatus = .failed
                }
                return false
            }
            do {
                let snapshot = try await snapshotStore.read()
                guard isCurrent(ticket) else { return false }

                // Scheduler retry metadata belongs to the cache lifecycle and
                // database epoch, not to a particular projection generation or
                // classification revision. Restore it before deciding whether
                // the payload itself is admissible; an old payload is still
                // discarded below and is never relabeled with the new identity.
                if let snapshot,
                   snapshot.identity.databaseEpoch == directory.metadata.identity.databaseEpoch {
                    let scheduler = ensurePresentationRefreshCoordinator()
                    if let schedule = snapshot.refreshSchedule {
                        scheduler.restoreScheduleState(schedule)
                        homeRankingRetryPending = snapshot.home.map {
                            $0.rankingCapacity < PresentationHomeSummary.currentRankingCapacity &&
                            schedule.projectionRetryDate != nil
                        } ?? false
                    } else if let sourceCheck = snapshot.lastSourceCheckAt {
                        scheduler.restoreSuccessfulCheck(at: sourceCheck)
                    }
                }

                if let snapshot,
                   snapshot.identity == directory.metadata.identity,
                   snapshot.classificationRevision == currentClassificationRevision,
                   snapshot.quota != nil || snapshot.home != nil {
                    applyCachedPresentation(snapshot)
                    cacheStatus = .verified
                    let now = nowProvider()
                    // Directory identity and names are independent of quota
                    // statistics. Restore them from one compact read so a
                    // fresh cache still leaves capability pages usable while
                    // doing zero quota aggregation.
                    applyPresentationDirectory(directory)
                    let scheduler = ensurePresentationRefreshCoordinator()
                    // Cache freshness is based only on the last successful
                    // source check. Presentation generation time is not a
                    // source freshness signal; missing or future metadata
                    // must take the expired-cache path.
                    let cacheIsFresh: Bool = {
                        guard let sourceCheck = snapshot.lastSourceCheckAt,
                              sourceCheck <= now else { return false }
                        return now.timeIntervalSince(sourceCheck) <= 30 * 60
                    }()
                    if cacheIsFresh {
                        let sourceFailureAlreadyKnown = indexingError != nil
                            || (refreshScheduleState?.sourceRetryAttempt ?? 0) > 0
                            || refreshScheduleState?.sourceRetryDate != nil
                        if !sourceFailureAlreadyKnown {
                            sourceDataFresh = directory.metadata.lastSourceCheckAt.map {
                                $0.timeIntervalSinceReferenceDate.isFinite &&
                                $0 <= now && now.timeIntervalSince($0) <= 30 * 60
                            } ?? false
                        }
                        hasLoadedInitialData = true
                        bootstrapStatus = .ready
                        restartSourceDataMonitor()
                        scheduleHomeRankingUpgradeIfNeeded()
                        return true
                    }
                    let legacyHomeNeedsUpgrade = snapshot.home.map {
                        $0.rankingCapacity < PresentationHomeSummary.currentRankingCapacity
                    } ?? false
                    if !visibleWindowIDs.isEmpty, !isSystemSleeping, !legacyHomeNeedsUpgrade {
                        scheduler.scheduleStartup(domains: [.quota, .directory])
                    } else if legacyHomeNeedsUpgrade {
                        // The expired cache still has usable legacy Home rows.
                        // Defer the normal broad refresh until the isolated
                        // Top10 upgrade has completed, so queued startup work
                        // cannot merge into the Home-only batch.
                        normalPresentationRefreshDeferred = true
                    }
                    hasLoadedInitialData = true
                    bootstrapStatus = .ready
                    restartSourceDataMonitor()
                    scheduleHomeRankingUpgradeIfNeeded()
                    return true
                }
                guard isCurrent(ticket) else { return false }
                cacheStatus = .stale
                invalidateCachedPresentation()
            } catch {
                guard isCurrent(ticket) else { return false }
                // Corrupt/old cache is disposable presentation data. The
                // authoritative derived index remains available for refresh.
                cacheStatus = .stale
                invalidateCachedPresentation()
            }
            // The directory is independently useful while the bounded
            // statistics projection is running. Reconcile its identity before
            // publishing it so a stale directory can never outlive a DB
            // generation change.
            do {
                let currentIdentity = try await readStore.presentationIdentity()
                guard isCurrent(ticket), currentIdentity == directory.metadata.identity else { return false }
                applyPresentationDirectory(directory)
                if refreshScheduleState?.projectionRetryDate.map({ $0 > nowProvider() }) == true {
                    // The old payload is intentionally not restored, but a
                    // future projection retry must not be bypassed by startup.
                    // Keep the authoritative directory visible and let the
                    // monitor issue the projection request at its deadline.
                    hasLoadedInitialData = true
                    bootstrapStatus = .ready
                    restartSourceDataMonitor()
                    return false
                }
            } catch {
                if isCurrent(ticket) {
                    indexingError = "initial_directory_load_failed"
                    presentationState = .failure("initial_directory_load_failed")
                    bootstrapStatus = .failed
                }
                return false
            }
        }
        if presentationSnapshotStore == nil, let readStore {
            // Hosts without a cache still get the small directory before the
            // first aggregate query; statistics remain unknown until then.
            do {
                let directory = try await readStore.fetchPresentationDirectory()
                let currentIdentity = try await readStore.presentationIdentity()
                guard isCurrent(ticket), currentIdentity == directory.metadata.identity else { return false }
                applyPresentationDirectory(directory)
            } catch {
                if isCurrent(ticket) {
                    indexingError = "initial_directory_load_failed"
                    presentationState = .failure("initial_directory_load_failed")
                    bootstrapStatus = .failed
                }
                return false
            }
        }
        do {
            let outcome = await ensurePresentationRefreshCoordinator().request(RefreshRequest(
                domains: [.quota, .directory],
                reason: .startup,
                force: true,
                sourceIntent: false
            ))
            guard outcome == .completed || outcome == .noNewData else {
                throw CancellationError()
            }
            guard isCurrentLifecycle(ticket), !Task.isCancelled else { return false }
            hasLoadedInitialData = true
            bootstrapStatus = .ready
            restartSourceDataMonitor()
        } catch {
            if isCurrentLifecycle(ticket) {
                let directoryIsAvailable = directoryLoaded
                indexingError = error.localizedDescription
                presentationState = .failure("initial_data_load_failed")
                lastRefresh = nil
                bootstrapStatus = directoryIsAvailable ? .ready : .failed
                // Directory-only startup is still a valid monitor anchor:
                // the scheduler can retry the failed bounded projection at
                // its persisted deadline without claiming statistics ready.
                hasLoadedInitialData = directoryIsAvailable
                if directoryIsAvailable { restartSourceDataMonitor() }
            }
            return false
        }
        return false
    }

    /// Loads only the small directory projection. It intentionally excludes
    /// calls, sessions, tokens, findings, and quota history.
    private func loadPresentationDirectory() async throws {
        guard let readStore else { return }
        let directory = try await readStore.fetchPresentationDirectory()
        applyPresentationDirectory(directory)
    }

    private func applyPresentationDirectory(_ directory: PresentationDirectorySnapshot) {
        let resources = directory.resources
        capabilities.replaceData(
            resources: resources,
            relations: directory.relations,
            projects: directory.projects,
            provenance: directory.provenance,
            evaluationCounts: Self.evaluationCounts(
                resources: resources,
                invocationsBySession: [:],
                evaluations: evaluationStore.all()
            )
        )
        applyClassificationOverrides()
        let catalog = CapabilityCatalog(resources: capabilities.allRows.map(\.resource), relations: capabilities.relations).entries
        for library in libraryModels {
            library.setDirectory(catalog: catalog, projects: directory.projects)
        }
        hasIndexedData = !resources.isEmpty || directory.indexedSessionCount > 0
        directoryLoaded = true
        lastIndexCompletedAt = directory.metadata.lastIndexCompletedAt
        sourceDataLastCheckedAt = directory.metadata.lastSourceCheckAt
        hasCompletedIndexPass = directory.metadata.lastIndexCompletedAt != nil
        presentationState = presentationStateAfterRefresh()
    }

    /// Loads only the first-window projection. Session rows, invocation
    /// payloads, token snapshots, and detail/library history remain lazy until
    /// their destination requests them.
    private func refreshStartupProjection() async throws {
        guard let readStore, !isDeletingDerivedData else { throw CancellationError() }
        let ticket = try await beginPresentationTicket(readStore: readStore, snapshotStore: presentationSnapshotStore)
        let now = nowProvider()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: statisticsCalendar)
        let startup = try await readStore.fetchStartupPresentation(window: window)
        let directory = startup.directory
        let metadata = directory.metadata
        let resources = directory.resources
        let relations = directory.relations
        let projects = directory.projects
        let provenance = directory.provenance
        let quota = startup.quota
        let recentUsage = startup.recentUsage
        let immutableCatalog = classifiedCatalog(resources: resources, relations: relations)
        let homeSummary = await buildHomeSummary(catalog: immutableCatalog, usage: recentUsage)
        try await presentationProjectionTestHook?()
        try Task.checkCancellation()
        let currentIdentity = try await readStore.presentationIdentity()
        guard isCurrent(ticket),
              currentIdentity == ticket.identity,
              metadata.identity == ticket.identity,
              quota.identity == ticket.identity else { throw CancellationError() }

        // Publish the complete immutable projection only after all detached
        // work has finished. A stale query therefore cannot partially replace
        // the live catalog, quota, Home summary, or cache.
        capabilities.replaceData(
            resources: resources,
            stats: [],
            relations: relations,
            projects: projects,
            provenance: provenance,
            evaluationCounts: Self.evaluationCounts(
                resources: resources,
                invocationsBySession: [:],
                evaluations: evaluationStore.all()
            )
        )
        applyClassificationOverrides()
        let catalog = CapabilityCatalog(resources: capabilities.allRows.map(\.resource), relations: capabilities.relations).entries
        recentCapabilityStats = recentUsage
        quotaOverviewSnapshot = quota
        presentationHomeSummary = homeSummary
        for library in libraryModels {
            // Startup replaces only the compact catalog/recent projection;
            // existing browse/detail state remains intact until a page query.
            library.setData(catalog: catalog, categoryStats: recentUsage,
                            browseStats: library.browseStats,
                            browseHistory: library.browseHistory,
                            usageProjects: library.usageProjects)
            library.setProjects(projects)
        }
        hasIndexedData = !resources.isEmpty || directory.indexedSessionCount > 0
        lastIndexCompletedAt = metadata.lastIndexCompletedAt
        sourceDataLastCheckedAt = metadata.lastSourceCheckAt
        hasCompletedIndexPass = metadata.lastIndexCompletedAt != nil
        directoryLoaded = true
        statisticsWindow = window
        hasComputedStatistics = true
        syncMonitorDayToPublishedWindow(window, now: now)
        lastStatisticsDay = statisticsCalendar.startOfDay(for: window.end)
        presentationState = presentationStateAfterRefresh()
        lastRefresh = now
        let cacheWritten = await writePresentationCache(
            quota: quota,
            home: homeSummary,
            metadata: metadata,
            window: window,
            ticket: ticket
        )
        if cacheWritten, isCurrent(ticket) { cacheStatus = .verified }
        scheduleHomeRankingUpgradeIfNeeded()
    }

    /// Reads and publishes only the sanitized account quota DTO. A failed
    /// account read is local to this domain: the last unexpired snapshot and
    /// any successful capability projection remain intact.
    private func refreshAccountUsage() async throws {
        guard let reader = accountUsageReading else {
            accountUsageError = "account_usage_unavailable"
            return
        }
        do {
            let snapshot = try await reader.read()
            try Task.checkCancellation()
            accountUsageSnapshot = snapshot
            accountUsageReadRevision &+= 1
            accountUsageError = snapshot.weeklyRemainingPercent == nil
                ? "account_usage_incomplete"
                : nil
            accountUsageRefreshScheduler?.updateSnapshot(snapshot)
            await writeAccountUsageCache(snapshot)
        } catch let error as CodexAccountUsageReadError where error == .cancelled {
            accountUsageError = "account_usage_cancelled"
            throw CancellationError()
        } catch is CancellationError {
            accountUsageError = "account_usage_cancelled"
            throw CancellationError()
        } catch {
            accountUsageError = "account_usage_unavailable"
        }
    }

    private func performScheduledAccountUsageRefresh() async -> AccountUsageRefreshScheduler.RefreshResult {
        guard menuBarEnabled,
              accountUsageReading != nil,
              !isSystemSleeping,
              accountUsageRefreshScheduler?.isCurrentlyEligible == true else {
            return .cancelled
        }
        let before = accountUsageReadRevision
        let outcome = await requestAccountUsageRefresh(force: true, reason: .accountUsageAutomatic)
        if accountUsageReadRevision != before {
            return accountUsageSnapshot?.weeklyRemainingPercent == nil ? .unavailable : .succeeded
        }
        if outcome == .cancelled { return .cancelled }
        return accountUsageReading == nil ? .unavailable : .failed
    }

    private func writeAccountUsageCache(_ accountUsage: CodexAccountUsageSnapshot) async {
        guard let snapshotStore = presentationSnapshotStore,
              let permit = presentationCachePermit,
              !isDeletingDerivedData else { return }
        do {
            // The permit already binds this cache writer to the current
            // database identity. Do not re-open SQLite for an account-only
            // tick; a stale permit is rejected atomically by the cache actor.
            guard let existing = try await snapshotStore.read() else { return }
            let updated = PresentationSnapshot(
                schemaVersion: existing.schemaVersion,
                identity: existing.identity,
                classificationRevision: existing.classificationRevision,
                window: existing.window,
                generatedAt: existing.generatedAt,
                lastSourceCheckAt: existing.lastSourceCheckAt,
                lastIndexCompletedAt: existing.lastIndexCompletedAt,
                statisticsThrough: existing.statisticsThrough,
                quota: existing.quota,
                home: existing.home,
                accountUsage: accountUsage,
                failureCount: existing.failureCount,
                nextRetryAt: existing.nextRetryAt,
                refreshSchedule: existing.refreshSchedule
            )
            try await snapshotStore.write(updated, permit: permit)
        } catch {
            // Cache persistence is best effort for the optional menu-bar DTO;
            // a successful live reading remains available for this process.
        }
    }

    /// Upgrades only the compact Home ranking payload in a legacy cache. The
    /// cache's quota, source timestamps, statistics window and scheduler
    /// metadata are copied verbatim; this operation cannot manufacture source
    /// freshness or a new full presentation generation.
    private func refreshHomeRankings() async throws {
        guard let readStore,
              let snapshotStore = presentationSnapshotStore,
              let window = statisticsWindow,
              let currentHome = presentationHomeSummary,
              currentHome.rankingCapacity < PresentationHomeSummary.currentRankingCapacity,
              !isDeletingDerivedData,
              !visibleWindowIDs.isEmpty,
              selection == .home,
              !isSystemSleeping else { throw CancellationError() }
        let upgradeGeneration = homeRankingUpgradeGeneration
        let ticket = try await beginPresentationTicket(readStore: readStore, snapshotStore: snapshotStore)
        let projection = try await readStore.fetchHomeRankingPresentation(window: window)
        guard projection.directory.metadata.identity == ticket.identity else { throw CancellationError() }
        let catalog = classifiedCatalog(
            resources: projection.directory.resources,
            relations: projection.directory.relations
        )
        let upgraded = await buildHomeSummary(catalog: catalog, usage: projection.recentUsage)
        try await presentationProjectionTestHook?()
        try Task.checkCancellation()
        let currentIdentity = try await readStore.presentationIdentity()
        guard upgraded.rankingCapacity == PresentationHomeSummary.currentRankingCapacity,
              isCurrent(ticket),
              currentIdentity == ticket.identity,
              statisticsWindow == window,
              presentationHomeSummary.map { $0.rankingCapacity < PresentationHomeSummary.currentRankingCapacity } == true,
              upgradeGeneration == homeRankingUpgradeGeneration,
              selection == .home,
              !visibleWindowIDs.isEmpty,
              !isSystemSleeping else {
            throw CancellationError()
        }
        guard let permit = ticket.permit,
              let existing = try await snapshotStore.read(expectedIdentity: ticket.identity),
              existing.window == window,
              existing.classificationRevision == ticket.classificationRevision else {
            throw CancellationError()
        }
        let merged = PresentationSnapshot(
            schemaVersion: existing.schemaVersion,
            identity: existing.identity,
            classificationRevision: existing.classificationRevision,
            window: existing.window,
            generatedAt: existing.generatedAt,
            lastSourceCheckAt: existing.lastSourceCheckAt,
            lastIndexCompletedAt: existing.lastIndexCompletedAt,
            statisticsThrough: existing.statisticsThrough,
            quota: existing.quota,
            home: upgraded,
            failureCount: existing.failureCount,
            nextRetryAt: existing.nextRetryAt,
            refreshSchedule: existing.refreshSchedule
        )
        guard upgradeGeneration == homeRankingUpgradeGeneration,
              selection == .home,
              !visibleWindowIDs.isEmpty,
              !isSystemSleeping,
              isCurrent(ticket) else { throw CancellationError() }
        try await snapshotStore.write(merged, permit: permit)
        guard isCurrent(ticket), upgradeGeneration == homeRankingUpgradeGeneration,
              selection == .home, !visibleWindowIDs.isEmpty, !isSystemSleeping else { throw CancellationError() }
        presentationHomeSummary = upgraded
        cacheStatus = .verified
    }

    private static func quotaSnapshots(from overview: QuotaOverviewSnapshot) -> [QuotaSnapshot] {
        var result: [QuotaSnapshot] = []
        for source in overview.sources {
            result.append(contentsOf: source.daily.compactMap(\.observation))
            if let current = source.current, !result.contains(where: { $0.id == current.id }) { result.append(current) }
        }
        return result
    }

    private func buildHomeSummary(
        catalog: CapabilityCatalog,
        usage: [CapabilityUsageStats]
    ) async -> PresentationHomeSummary {
        let task = Task.detached(priority: .utility) {
            HomeOverviewModel(catalog: catalog, usage: usage).presentationSummary
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    /// The Tasks destination asks for session summaries only when opened; no
    /// invocation or token payload is loaded during startup projection.
    public func loadTasksIfNeeded() async {
        guard tasks.rows.isEmpty, let readStore, !isDeletingDerivedData else { return }
        let ticket = beginDetailTicket()
        do {
            let sessions = try await readStore.fetchAllSessions()
            let summaries = try await fetchTaskCallSummaries(sessions: sessions, store: readStore)
            guard isCurrent(ticket) else { return }
            tasks = TasksViewModel(sessions: sessions, callSummaries: summaries, evaluations: evaluationStore.all())
        } catch {
            if isCurrent(ticket) { indexingError = "tasks_load_failed" }
        }
    }

    private func writePresentationCache(
        quota: QuotaOverviewSnapshot,
        home: PresentationHomeSummary,
        metadata: PresentationIndexMetadata,
        window: CapabilityQueryWindow,
        ticket: PresentationTicket
    ) async -> Bool {
        guard let snapshotStore = presentationSnapshotStore,
              let permit = ticket.permit,
              isCurrent(ticket) else { return false }
        let snapshot = PresentationSnapshot(
            identity: ticket.identity,
            classificationRevision: ticket.classificationRevision,
            window: window,
            generatedAt: nowProvider(),
            lastSourceCheckAt: metadata.lastSourceCheckAt,
            lastIndexCompletedAt: metadata.lastIndexCompletedAt ?? lastIndexCompletedAt,
            statisticsThrough: window.end,
            quota: quota,
            home: home,
            accountUsage: accountUsageSnapshot,
            refreshSchedule: refreshScheduleState.map {
                PresentationRefreshSchedule(
                    revision: $0.revision,
                    recordedAt: presentationNow,
                    lastSourceSuccessAt: $0.lastSourceSuccessAt,
                    sourceRetryAttempt: $0.sourceRetryAttempt,
                    sourceRetryDate: $0.sourceRetryDate,
                    projectionRetryAttempt: $0.projectionRetryAttempt,
                    projectionRetryDate: $0.projectionRetryDate
                )
            }
        )
        guard isCurrent(ticket) else { return false }
        do {
            try await snapshotStore.write(snapshot, permit: permit)
            return isCurrent(ticket)
        } catch {
            return false
        }
    }

    // MARK: - Derived data control

    /// Deletes all derived data. Source files are never touched.
    public func deleteDerivedData() async throws {
        guard !isDeletingDerivedData else { return }
        isDeletingDerivedData = true
        defer { isDeletingDerivedData = false }
        lifecycleEpoch &+= 1
        presentationRequestSequence &+= 1
        detailRequestSequence &+= 1
        diagnosticsRequestSequence &+= 1
        diagnosticsLoading = false
        diagnosticsError = nil
        presentationDiagnostics = nil
        refreshScheduleState = nil
        backgroundRefreshError = nil
        schedulePersistenceRevision = 0
        for category in CapabilityCategory.allCases {
            libraryReloadGeneration[category.rawValue, default: 0] &+= 1
            libraryQueryStatus[category] = .idle
        }
        libraryPresentationKeys.removeAll(keepingCapacity: false)
        libraryResultContext.removeAll(keepingCapacity: false)
        sourceDataMonitorTask?.cancel()
        sourceDataMonitorTask = nil
        sourceMonitorActionTask?.cancel()
        sourceMonitorActionTask = nil
        homeRankingUpgradeTask?.cancel()
        homeRankingUpgradeTask = nil
        homeRankingRetryPending = false
        let refreshCoordinator = presentationRefreshCoordinator
        presentationRefreshCoordinator = nil

        // Revoke and remove the cache before waiting for workers or touching
        // SQLite. A failed database deletion must not leave a cache that a
        // late writer can resurrect.
        if let cacheInvalidationTask {
            await cacheInvalidationTask.value
            self.cacheInvalidationTask = nil
        }
        if let snapshotStore = presentationSnapshotStore {
            do {
                try await snapshotStore.delete()
            } catch {
                await refreshCoordinator?.cancelAndWait()
                clearPresentationStateAfterCacheDeletionFailure()
                indexingError = "presentation_cache_delete_failed"
                presentationState = .failure("presentation_cache_delete_failed")
                cacheStatus = .unavailable
                throw error
            }
        }
        await refreshCoordinator?.cancelAndWait()

        var deletionError: Error?
        if let store {
            do { try await store.deleteAllData() } catch { deletionError = error }
        }
        capabilities.replaceData(resources: [], relations: [], projects: [], provenance: [])
        tasks = TasksViewModel(sessions: [], evaluations: evaluationStore.all())
        usage = UsageViewModel(quotaSnapshots: [], tokenSnapshots: [], now: nowProvider())
        review = ReviewViewModel(findings: [])
        recentCapabilityStats = []
        quotaOverviewSnapshot = nil
        accountUsageSnapshot = nil
        accountUsageRefreshScheduler?.updateSnapshot(nil)
        accountUsageError = nil
        presentationHomeSummary = nil
        quotaSourceID = nil
        sourceDataLastCheckedAt = nil
        sourceDataFresh = false
        lastStatisticsDay = nil
        isIndexing = false
        for library in libraryModels {
            library.setData(catalog: [], categoryStats: [], browseStats: [], browseHistory: [], usageProjects: [:])
            library.setPluginData([], browseStats: [])
            library.selectedID = nil
        }
        lastRefresh = nil
        lastIndexCompletedAt = nil
        hasCompletedIndexPass = false
        hasIndexedData = false
        directoryLoaded = false
        statisticsWindow = nil
        hasComputedStatistics = false
        hasLoadedInitialData = false
        cacheStatus = .stale
        presentationState = .initial
        indexingError = nil
        indexingProgress = .initial
        if let deletionError {
            indexingError = deletionError.localizedDescription
            presentationState = .failure("derived_data_delete_failed")
            throw deletionError
        }
    }

    /// The cache has already been revoked when removal fails. Drop every
    /// cache-derived display value, but leave the authoritative DB-backed
    /// catalog and user preference stores intact for a later retry.
    private func clearPresentationStateAfterCacheDeletionFailure() {
        quotaOverviewSnapshot = nil
        accountUsageSnapshot = nil
        accountUsageRefreshScheduler?.updateSnapshot(nil)
        accountUsageError = nil
        presentationHomeSummary = nil
        recentCapabilityStats = []
        quotaSourceID = nil
        lastRefresh = nil
        lastIndexCompletedAt = nil
        sourceDataLastCheckedAt = nil
        sourceDataFresh = false
        lastStatisticsDay = nil
        statisticsWindow = nil
        hasComputedStatistics = false
        hasLoadedInitialData = false
        directoryLoaded = false
        isIndexing = false
        indexingProgress = .initial
        for category in CapabilityCategory.allCases {
            libraryQueryStatus[category] = .idle
        }
        for library in libraryModels {
            library.isLoading = false
        }
    }

    /// Applies Home's capability-use deep link while keeping its scope
    /// explicit: only current user-owned Agents and Skills participate.
    public func applyHomeSectionFilter(_ section: HomeView.HomeSectionFilter) {
        selection = .capabilities
        switch section {
        case .myAgents:
            capabilities.applyUserOwnedFilter(kind: .agent, hideBuiltin: true, category: .myAgents)
        case .mySkills:
            capabilities.applyUserOwnedFilter(kind: .skill, hideBuiltin: true, category: .mySkills)
        case .installedSkills:
            capabilities.applyUserOwnedFilter(kind: .skill, hideBuiltin: true, category: .installedSkills)
        case .projectInstructions:
            capabilities.applyUserOwnedFilter(kind: .instruction, scope: .project, hideBuiltin: true, category: .instructions)
        case .pluginCapabilities:
            capabilities.applyUserOwnedFilter(allowedScopes: [.runtime, .plugin], hideBuiltin: true, category: .plugins)
        case .builtIn:
            capabilities.applyUserOwnedFilter(scope: .system, category: .builtIn, showBuiltIn: true)
        case .globalAgents:
            capabilities.applyUserOwnedFilter(kind: .agent, scope: .global, hideBuiltin: true)
        case .projectAgents:
            capabilities.applyUserOwnedFilter(kind: .agent, scope: .project, hideBuiltin: true)
        case .globalSkills:
            capabilities.applyUserOwnedFilter(kind: .skill, scope: .global, hideBuiltin: true)
        case .projectSkills:
            capabilities.applyUserOwnedFilter(kind: .skill, scope: .project, hideBuiltin: true)
        case .installedTools:
            capabilities.applyUserOwnedFilter(
                allowedKinds: [.plugin, .mcp, .tool, .app, .hook],
                allowedScopes: [.runtime, .plugin],
                hideBuiltin: true
            )
        case .observedCapabilities:
            capabilities.applyUserOwnedFilter(allowedKinds: [.agent, .skill], ownership: .userOwned, hideBuiltin: true)
            capabilities.usageFilter = .observed
        case .notObservedCapabilities:
            capabilities.applyUserOwnedFilter(allowedKinds: [.agent, .skill], ownership: .userOwned, hideBuiltin: true)
            capabilities.usageFilter = .notObserved
        case .evidenceLimitedCalls:
            capabilities.applyUserOwnedFilter(allowedKinds: [.agent, .skill], ownership: .userOwned, hideBuiltin: true)
            capabilities.usageFilter = .evidenceLimited
        case .notEvaluatedCapabilities:
            capabilities.applyUserOwnedFilter(allowedKinds: [.agent, .skill], ownership: .userOwned, hideBuiltin: true)
            capabilities.usageFilter = .notEvaluated
        }
    }

    /// Wording shown in the delete confirmation. States explicitly that
    /// original resources and Sessions are unchanged.
    public static let deleteConfirmationMessage =
        "Delete the local derived index (SQLite, caches, and logs)? Original resources and Session files remain unchanged, and local user evaluation labels are retained. The index can be re-indexed at any time."

    public static let firstRunMessage =
        "Codex Director runs entirely on this Mac. It reads resources and Session logs read-only and builds a local derived index; nothing is uploaded, and no prompt, response, argument, or output text is stored."

    private func latestSessionSourceModificationDate() async -> Date? {
        guard let configuration else { return nil }

        var latest: Date?
        for root in configuration.activeSessionRoots {
            let candidate = latestJSONLModificationDate(in: root, depthRemaining: 5)
            if let candidate, candidate > (latest ?? .distantPast) {
                latest = candidate
            }
        }
        if let archived = configuration.archivedSessionRoot {
            let candidate = latestJSONLModificationDate(in: archived, depthRemaining: 2)
            if let candidate, candidate > (latest ?? .distantPast) {
                latest = candidate
            }
        }
        return latest
    }

    private static func evaluationCounts(
        resources: [CapabilityResource],
        invocationsBySession: [String: [InvocationEvent]],
        evaluations: [String: InvocationEvaluation]
    ) -> [String: CapabilityEvaluationCounts] {
        let resourcesByID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        var eventsByID: [String: InvocationEvent] = [:]
        for events in invocationsBySession.values {
            for event in events {
                eventsByID[event.id] = event
            }
        }

        var counts: [String: CapabilityEvaluationCounts] = [:]
        for evaluation in evaluations.values {
            guard let resourceID = evaluation.resourceID,
                  let resource = resourcesByID[resourceID],
                  resource.kind == .agent || resource.kind == .skill
            else { continue }

            // Detail evidence is intentionally lazy. If a call is already in
            // memory, validate its event identity; otherwise a persisted
            // judgment with a current resource ID remains aggregateable.
            if let event = eventsByID[evaluation.invocationID] {
                guard event.sessionID == evaluation.sessionID,
                      event.resourceID == resourceID,
                      event.kind == .agent || event.kind == .skill else { continue }
            }

            let prior = counts[resourceID] ?? .init()
            counts[resourceID] = prior.updated(adding: evaluation.label)
        }
        return counts
    }

    /// Counts task calls directly in SQLite while keeping invocation payloads
    /// lazy for timeline/detail views.
    private func fetchTaskCallSummaries(
        sessions: [TaskSummary],
        store: DatabaseStore
    ) async throws -> [String: TaskCallSummary] {
        var result: [String: TaskCallSummary] = [:]
        for session in sessions {
            let escapedID = session.id.replacingOccurrences(of: "'", with: "''")
            let predicate = "calls WHERE session_id = '\(escapedID)'"
            let callCount = try await store.count(predicate)
            let failedPredicate = "calls WHERE session_id = '\(escapedID)' AND status IN ('failed','interrupted')"
            let failureCount = try await store.count(failedPredicate)
            result[session.id] = TaskCallSummary(callCount: callCount, failureCount: failureCount)
        }
        return result
    }

    /// Capability history contains direct resource calls, while plugin usage
    /// is attributed from current child mappings. Project-specific and
    /// historical plugin calls therefore need a stable parent row in the
    /// existing history projection so its last-used date is not lost.
    private static func mergePluginHistory(
        _ history: [CapabilityHistory],
        pluginHistory: [PluginUsageResult]
    ) -> [CapabilityHistory] {
        var merged = Dictionary(uniqueKeysWithValues: history.map { ($0.resourceID, $0) })
        for usage in pluginHistory {
            guard usage.callCount != nil || usage.lastUsedAt != nil else { continue }
            let existing = merged[usage.pluginID]
            let lastUsedAt = [existing?.lastUsedAt, usage.lastUsedAt].compactMap { $0 }.max()
            merged[usage.pluginID] = CapabilityHistory(
                resourceID: usage.pluginID,
                callCount: (existing?.callCount ?? 0) + (usage.callCount ?? 0),
                lastUsedAt: lastUsedAt
            )
        }
        return merged.values.sorted { $0.resourceID < $1.resourceID }
    }

    private func latestJSONLModificationDate(
        in directory: URL,
        depthRemaining: Int
    ) -> Date? {
        guard depthRemaining >= 0 else { return nil }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var latest: Date?
        for entry in urls {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
                continue
            }
            if values.isDirectory == true {
                if let nested = latestJSONLModificationDate(in: entry, depthRemaining: depthRemaining - 1),
                   nested > (latest ?? .distantPast) {
                    latest = nested
                }
                continue
            }
            guard entry.pathExtension == "jsonl", let modified = values.contentModificationDate else { continue }
            if modified > (latest ?? .distantPast) {
                latest = modified
            }
        }
        return latest
    }
}
