import Foundation
import SwiftUI
import DirectorCore

/// Presentation-only adapter for the approved history seams. It keeps the
/// views independent from the indexing actor and makes synthetic validation
/// possible without opening source roots or production data.
public struct CapabilityHistoryPresentationSource: @unchecked Sendable {
    public typealias PageLoader = @Sendable (CapabilityHistoryQuery) async throws -> CapabilityHistoryPage
    public typealias StatusLoader = @Sendable () async -> CapabilityHistoryStatus
    public typealias ClearLoader = @Sendable () async throws -> CapabilityHistoryStatus
    public typealias UsageLoader = @Sendable (CapabilityChangeUsageQuery) async throws -> CapabilityChangeUsageSummary
    public typealias UsageQueryLoader = @Sendable (CapabilityChangeEvent, Date?, CapabilityChangeUsagePeriod) async -> CapabilityChangeUsageQuery?
    public typealias IdentityLoader = @Sendable () async -> PresentationIdentity?

    public let pageLoader: PageLoader
    public let statusLoader: StatusLoader
    public let clearLoader: ClearLoader
    public let usageLoader: UsageLoader
    public let now: @Sendable () -> Date
    public let statisticsThrough: @Sendable () -> Date?
    public let identityLoader: IdentityLoader
    public let usageQueryLoader: UsageQueryLoader?

    public init(
        pageLoader: @escaping PageLoader,
        statusLoader: @escaping StatusLoader,
        clearLoader: @escaping ClearLoader,
        usageLoader: @escaping UsageLoader,
        now: @escaping @Sendable () -> Date = Date.init,
        statisticsThrough: @escaping @Sendable () -> Date? = { nil },
        identityLoader: @escaping IdentityLoader = { nil },
        usageQueryLoader: UsageQueryLoader? = nil
    ) {
        self.pageLoader = pageLoader
        self.statusLoader = statusLoader
        self.clearLoader = clearLoader
        self.usageLoader = usageLoader
        self.now = now
        self.statisticsThrough = statisticsThrough
        self.identityLoader = identityLoader
        self.usageQueryLoader = usageQueryLoader
    }

    public static var unavailable: Self {
        return Self(
            pageLoader: { _ in throw CapabilityHistoryStore.StoreError.storageUnavailable },
            statusLoader: { .unavailable },
            clearLoader: { throw CapabilityHistoryStore.StoreError.storageUnavailable },
            usageLoader: { query in
                .unavailable(for: query, availability: .indexUnavailable)
            }
        )
    }

    @MainActor
    public static func make(
        model: DirectorAppModel,
        now: (@Sendable () -> Date)? = nil
    ) -> Self {
        let historyClock = now ?? model.capabilityHistoryClock
        let statisticsThrough = model.statisticsWindow?.end
        return Self(
            pageLoader: { [weak model] query in
                guard let model else { throw CapabilityHistoryStore.StoreError.storageUnavailable }
                return try await model.capabilityHistoryPage(query)
            },
            statusLoader: { [weak model] in
                guard let model else { return .unavailable }
                return await model.capabilityHistoryStatus()
            },
            clearLoader: { [weak model] in
                guard let model else { throw CapabilityHistoryStore.StoreError.storageUnavailable }
                try await model.clearCapabilityHistoryConfirmed()
                return await model.capabilityHistoryStatus()
            },
            usageLoader: { [weak model] query in
                guard let model else {
                    return .unavailable(for: query, availability: .indexUnavailable)
                }
                return try await model.capabilityChangeUsageSummary(query)
            },
            now: historyClock,
            statisticsThrough: { statisticsThrough },
            identityLoader: {
                try? await model.readStore?.presentationIdentity()
            },
            usageQueryLoader: { [weak model] event, next, period in
                guard let model else { return nil }
                return await model.capabilityChangeUsageQuery(for: event, nextObservedAt: next, period: period)
            }
        )
    }

    public func makeUsageQuery(
        event: CapabilityChangeEvent,
        nextObservedAt: Date?,
        period: CapabilityChangeUsagePeriod,
        evaluationRevision: UInt64 = 0
    ) async -> CapabilityChangeUsageQuery? {
        if let usageQueryLoader {
            // A production boundary failure must not become an open-ended
            // interval. Return an explicitly unavailable query so the summary
            // renders “— · Call data is not indexed” instead of overcounting
            // through the present.
            return await usageQueryLoader(event, nextObservedAt, period)
                ?? makeUnavailableUsageQuery(event: event, period: period)
        }
        let through = statisticsThrough()
        let identity = await identityLoader()
        return CapabilityChangeUsageQuery(
            eventID: event.id,
            resourceID: event.resourceID,
            observedAt: event.observedAt,
            nextObservedAt: nextObservedAt,
            period: period,
            referenceDate: now(),
            calendar: Calendar.current,
            statisticsThrough: through,
            databaseIdentity: identity,
            evaluationRevision: evaluationRevision
        )
    }

    public func makeUnavailableUsageQuery(
        event: CapabilityChangeEvent,
        period: CapabilityChangeUsagePeriod
    ) -> CapabilityChangeUsageQuery {
        CapabilityChangeUsageQuery(
            eventID: event.id,
            resourceID: event.resourceID,
            observedAt: event.observedAt,
            nextObservedAt: nil,
            period: period,
            referenceDate: now(),
            calendar: Calendar.current,
            statisticsThrough: nil,
            databaseIdentity: nil,
            evaluationRevision: 0
        )
    }
}

private struct CapabilityHistoryPresentationSourceKey: EnvironmentKey {
    static let defaultValue: CapabilityHistoryPresentationSource? = nil
}

private struct CapabilityHistoryMutationRevisionKey: EnvironmentKey {
    static let defaultValue: UInt64? = nil
}

public extension EnvironmentValues {
    var capabilityHistoryPresentationSource: CapabilityHistoryPresentationSource? {
        get { self[CapabilityHistoryPresentationSourceKey.self] }
        set { self[CapabilityHistoryPresentationSourceKey.self] = newValue }
    }

    var capabilityHistoryMutationRevision: UInt64? {
        get { self[CapabilityHistoryMutationRevisionKey.self] }
        set { self[CapabilityHistoryMutationRevisionKey.self] = newValue }
    }
}

public enum CapabilityHistoryRecordWindow: String, CaseIterable, Hashable, Sendable {
    case last7
    case last30
    case allRetained

    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .last7:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .last30:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .allRetained:
            return nil
        }
    }
}

public enum CapabilityHistoryResourceFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case agent
    case skill
}

public enum CapabilityHistoryPresentationLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed
}

public enum CapabilityHistorySummaryState: Equatable, Sendable {
    case idle
    case loading
    case loaded(CapabilityChangeUsageSummary)
    case failed
}

/// The history page has independent storage, source-coverage and recording
/// dimensions. Keep their user-facing states in one adapter so the global
/// sheet and resource detail disclosure cannot drift into different recovery
/// advice.
public enum CapabilityHistoryPresentationStatus: Equatable, Sendable {
    case clockAnomaly
    case partialCoverage
    case sourceScanIncomplete
    case awaitingConfirmation
    case readOnly
    case recordingFailure
    case unavailable
    case corrupt
    case unsupported
    case failed

    fileprivate var messageKey: String {
        switch self {
        case .clockAnomaly: return "history.state.clock"
        case .partialCoverage: return "history.state.partial"
        case .sourceScanIncomplete: return "history.state.sourceScanIncomplete"
        case .awaitingConfirmation: return "history.state.awaitingConfirmation"
        case .readOnly: return "history.state.readOnly"
        case .recordingFailure: return "history.state.recordingFailure"
        case .unavailable: return "history.state.unavailable"
        case .corrupt: return "history.state.corrupt"
        case .unsupported: return "history.state.unsupported"
        case .failed: return "history.state.failed"
        }
    }

    fileprivate var allowsReadRetry: Bool {
        switch self {
        case .unavailable, .corrupt, .unsupported, .failed: return true
        case .clockAnomaly, .partialCoverage, .sourceScanIncomplete, .awaitingConfirmation, .readOnly, .recordingFailure:
            return false
        }
    }
}

/// Main-actor state for both the global sheet and detail disclosure. It owns
/// only paging, selection, filters and bounded summary cancellation.
@MainActor
public final class CapabilityHistoryPresentationModel: ObservableObject {
    public let source: CapabilityHistoryPresentationSource
    public let resourceID: String?
    public let initialPageSize: Int
    public let subsequentPageSize: Int
    public let nowProvider: @Sendable () -> Date

    @Published public private(set) var events: [CapabilityChangeEvent] = []
    @Published public private(set) var status: CapabilityHistoryStatus?
    @Published public private(set) var loadState: CapabilityHistoryPresentationLoadState = .idle
    @Published public private(set) var summaryState: CapabilityHistorySummaryState = .idle
    @Published public private(set) var selectedEventID: String?
    @Published public private(set) var nextBeforeSequence: Int64?
    @Published public private(set) var truncatedBefore: Date?
    @Published public private(set) var issueCodes: [CapabilityHistoryIssueCode] = []
    @Published public private(set) var lastErrorKey: String?
    /// Summary failures belong to the selected row, not to the history page.
    /// Keeping this separate prevents an unavailable usage index from making
    /// the global history sheet look as if its retained rows failed to load.
    @Published public private(set) var summaryErrorKey: String?
    @Published public private(set) var hasLoadedFirstPage = false
    @Published public var recordWindow: CapabilityHistoryRecordWindow
    @Published public var resourceFilter: CapabilityHistoryResourceFilter = .all
    @Published public var changeFilter: CapabilityChangeKind?
    @Published public var summaryPeriod: CapabilityChangeUsagePeriod = .recent30

    private var requestGeneration = 0
    private var pageTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var loadedMutationRevision: UInt64?

    private enum NeighborResolution {
        case resolved(Date?)
        case unavailable
    }

    public init(
        source: CapabilityHistoryPresentationSource,
        resourceID: String? = nil,
        recordWindow: CapabilityHistoryRecordWindow = .last30,
        initialPageSize: Int = 20,
        subsequentPageSize: Int = 20,
        nowProvider: (@Sendable () -> Date)? = nil
    ) {
        self.source = source
        self.resourceID = resourceID
        self.recordWindow = recordWindow
        self.initialPageSize = max(1, initialPageSize)
        self.subsequentPageSize = max(1, subsequentPageSize)
        self.nowProvider = nowProvider ?? source.now
    }

    public var selectedEvent: CapabilityChangeEvent? {
        guard let selectedEventID else { return nil }
        return events.first { $0.id == selectedEventID }
    }

    public var isBaselinePending: Bool {
        guard let status else {
            return events.isEmpty && !hasLoadedFirstPage
        }
        // An unavailable store is an error state, not an uninitialized scope.
        // In particular, never infer baseline state from a zero baseline count.
        return !isHistoryReadFailure && status.accessMode != .unavailable && status.isInitialized == false
    }

    public var isInitialized: Bool? { status?.isInitialized }
    /// A page/status read failure is distinct from an incomplete source scan.
    /// The latter leaves the history file readable and must not suppress a
    /// truthful empty state or offer a read-only retry as a scan repair.
    public var isHistoryReadFailure: Bool {
        if lastErrorKey != nil { return true }
        guard let status else { return false }
        if status.accessMode == .unavailable { return true }
        // A storageUnavailable diagnostic can describe the last failed
        // observation write while the committed history page remains
        // readable. The coordinator marks that ephemeral condition so it
        // cannot be mistaken for a page/status read failure.
        if status.latestObservationSaveFailed {
            return issueCodes.contains(.corruptStorage)
                || issueCodes.contains(.unsupportedSchema)
        }
        return issueCodes.contains(.storageUnavailable)
            || issueCodes.contains(.corruptStorage)
            || issueCodes.contains(.unsupportedSchema)
    }
    public var isUnavailable: Bool {
        isHistoryReadFailure
    }
    public var isReadOnlyRecording: Bool {
        status?.accessMode == .readOnly || issueCodes.contains(.readOnlyLockConflict)
    }
    public var hasStoredEvents: Bool {
        !events.isEmpty || (status?.eventCount ?? 0) > 0
    }
    public var hasNoMatchingEvents: Bool {
        hasLoadedFirstPage && events.isEmpty && hasStoredEvents && !isHistoryReadFailure
    }
    /// The only empty state that may be rendered is a successfully committed
    /// page with no matching events. Read failures and baseline-pending states
    /// intentionally suppress it, including when older rows remain visible.
    public var shouldShowEmptyState: Bool {
        hasLoadedFirstPage && events.isEmpty && !isHistoryReadFailure && !isBaselinePending
    }
    public var presentationStatus: CapabilityHistoryPresentationStatus? {
        if isHistoryReadFailure {
            switch lastErrorKey {
            case "history.state.corrupt": return .corrupt
            case "history.state.unsupported": return .unsupported
            case "history.state.failed": return .failed
            default: break
            }
            if issueCodes.contains(.unsupportedSchema) { return .unsupported }
            if issueCodes.contains(.corruptStorage) { return .corrupt }
            return .unavailable
        }
        if status?.latestObservationSaveFailed == true { return .recordingFailure }
        if isReadOnlyRecording { return .readOnly }
        if issueCodes.contains(.fileBudgetExceeded) { return .recordingFailure }
        if issueCodes.contains(.clockRollback) { return .clockAnomaly }
        // An unavailable latest scan is a stronger, explicit source-coverage
        // fact than a retained historical gap code. Do not backslide into a
        // partial-coverage claim when the aggregate cannot establish that
        // this scan reached any source.
        if status?.latestScanCoverage == .unavailable {
            return .sourceScanIncomplete
        }
        if issueCodes.contains(.historyGap)
            || issueCodes.contains(.interruptedMissingConfirmation)
            || issueCodes.contains(.cacheBatchIgnored)
            || issueCodes.contains(.invalidObservation) {
            return .partialCoverage
        }
        if status?.latestScanCoverage == .partial || status?.latestScanCoverage == .unstable {
            return .partialCoverage
        }
        if status?.pendingMissingCount ?? 0 > 0 {
            return .awaitingConfirmation
        }
        return nil
    }
    public var statusIssueKey: String? { presentationStatus?.messageKey }
    public var shouldOfferReadRetry: Bool { presentationStatus?.allowsReadRetry == true }
    public var selectedSummary: CapabilityChangeUsageSummary? {
        if case let .loaded(summary) = summaryState { return summary }
        return nil
    }

    public func load() {
        guard pageTask == nil else { return }
        pageTask = Task { [weak self] in await self?.loadNow(reset: true) }
    }

    public func loadNow(reset: Bool = true) async {
        requestGeneration &+= 1
        pageTask = nil
        if reset {
            // Keep the last committed rows visible while a new bounded page
            // is requested. A failed refresh must not erase trustworthy
            // history or turn an error into an empty state.
            nextBeforeSequence = nil
            truncatedBefore = nil
            hasLoadedFirstPage = false
            selectedEventID = nil
            summaryTask?.cancel()
            summaryTask = nil
            summaryState = .idle
        }
        let token = requestGeneration
        loadState = .loading
        let loadedStatus = await source.statusLoader()
        guard !Task.isCancelled, token == requestGeneration else { return }
        status = loadedStatus
        issueCodes = status?.issueCodes ?? []
        do {
            let page = try await source.pageLoader(query(beforeSequence: nil, limit: initialPageSize))
            guard !Task.isCancelled, token == requestGeneration else { return }
            commit(page, replacing: true)
        } catch is CancellationError {
            guard token == requestGeneration else { return }
            loadState = events.isEmpty ? .idle : .loaded
        } catch {
            guard token == requestGeneration else { return }
            lastErrorKey = errorKey(error)
            loadState = events.isEmpty ? .failed : .loaded
        }
    }

    /// Load the first page only when it has not been committed for the
    /// current shared-store revision. The parent keeps this model alive while
    /// the native sheet is dismissed, so returning from a resource detail
    /// preserves the selected row, filters and scroll position.
    public func loadIfNeeded(for mutationRevision: UInt64?) async {
        guard !hasLoadedFirstPage || loadedMutationRevision != mutationRevision else { return }
        await loadNow()
        if hasLoadedFirstPage {
            loadedMutationRevision = mutationRevision
        }
    }

    /// Re-entering a sheet may cancel a summary task while its selected row is
    /// intentionally preserved. Restart only the cancelled/idle summary so a
    /// normal reopen does not discard selection, filters, or scroll state.
    public func resumeSelectedSummaryIfNeeded() {
        guard summaryTask == nil,
              summaryState == .idle,
              let event = selectedEvent,
              event.kind != .missing else { return }
        select(event)
    }

    public func loadMore() {
        guard nextBeforeSequence != nil, pageTask == nil else { return }
        pageTask = Task { [weak self] in await self?.loadMoreNow() }
    }

    public func loadMoreNow() async {
        guard let before = nextBeforeSequence else { return }
        requestGeneration &+= 1
        let token = requestGeneration
        loadState = .loading
        defer { pageTask = nil }
        do {
            let page = try await source.pageLoader(query(beforeSequence: before, limit: subsequentPageSize))
            guard !Task.isCancelled, token == requestGeneration else { return }
            commit(page, replacing: false)
        } catch is CancellationError {
            if token == requestGeneration { loadState = .loaded }
        } catch {
            if token == requestGeneration {
                lastErrorKey = errorKey(error)
                loadState = .loaded
            }
        }
    }

    public func retry() {
        load()
    }

    public func setRecordWindow(_ value: CapabilityHistoryRecordWindow) {
        guard recordWindow != value else { return }
        recordWindow = value
        reloadForFilterChange()
    }

    public func setResourceFilter(_ value: CapabilityHistoryResourceFilter) {
        guard resourceFilter != value else { return }
        resourceFilter = value
        reloadForFilterChange()
    }

    public func setChangeFilter(_ value: CapabilityChangeKind?) {
        guard changeFilter != value else { return }
        changeFilter = value
        reloadForFilterChange()
    }

    public func setSummaryPeriod(_ value: CapabilityChangeUsagePeriod) {
        guard summaryPeriod != value else { return }
        summaryPeriod = value
        if let event = selectedEvent { select(event) }
    }

    public func select(_ event: CapabilityChangeEvent?) {
        requestGeneration &+= 1
        summaryTask?.cancel()
        summaryTask = nil
        selectedEventID = event?.id
        summaryState = .idle
        summaryErrorKey = nil
        // Selecting a retained row is a new page interaction. Do not leave a
        // previous page-load warning pinned above the selected summary.
        lastErrorKey = nil
        guard let event, event.kind != .missing else { return }
        let token = requestGeneration
        summaryState = .loading
        summaryTask = Task { [weak self] in
            guard let self else { return }
            // The visible page can be filtered or paged. Resolve the exact
            // same-resource successor from retained history instead of
            // inferring the interval from whichever rows are on screen.
            // Production AppModel usage-query loading authenticates the event
            // and resolves its same-resource successor in the history actor.
            // Synthetic sources without that seam use the bounded fallback.
            let newer: Date?
            if self.source.usageQueryLoader == nil {
                switch await self.nextObservedAt(after: event) {
                case let .resolved(date):
                    newer = date
                case .unavailable:
                    let query = self.source.makeUnavailableUsageQuery(event: event, period: self.summaryPeriod)
                    do {
                        let result = try await self.source.usageLoader(query)
                        guard !Task.isCancelled, token == self.requestGeneration else { return }
                        self.summaryState = .loaded(result)
                    } catch {
                        guard !Task.isCancelled, token == self.requestGeneration else { return }
                        self.summaryState = .failed
                        self.summaryErrorKey = self.errorKey(error)
                    }
                    self.summaryTask = nil
                    return
                }
            } else {
                newer = nil
            }
            guard !Task.isCancelled, token == self.requestGeneration else { return }
            guard let query = await self.source.makeUsageQuery(
                event: event,
                nextObservedAt: newer,
                period: self.summaryPeriod
            ) else {
                self.summaryState = .idle
                self.summaryTask = nil
                return
            }
            do {
                let result = try await self.source.usageLoader(query)
                guard !Task.isCancelled, token == self.requestGeneration else { return }
                self.summaryState = .loaded(result)
                self.summaryErrorKey = nil
                self.summaryTask = nil
            } catch {
                guard !Task.isCancelled, token == self.requestGeneration else { return }
                self.summaryState = .failed
                self.summaryErrorKey = self.errorKey(error)
                self.summaryTask = nil
            }
        }
    }

    private func nextObservedAt(after event: CapabilityChangeEvent) async -> NeighborResolution {
        do {
            // Retention caps a capability at 100 events. This remains a
            // bounded read while covering every retained event for the
            // selected resource, independent of current filters/page.
            let page = try await source.pageLoader(CapabilityHistoryQuery(
                resourceID: event.resourceID,
                limit: 100
            ))
            let blockingIssues: Set<CapabilityHistoryIssueCode> = [
                .storageUnavailable,
                .corruptStorage,
                .unsupportedSchema,
                .readOnlyLockConflict,
                .historyGap,
                .interruptedMissingConfirmation
            ]
            if page.issueCodes.contains(where: blockingIssues.contains) {
                return .unavailable
            }
            return .resolved(page.events
                .filter { $0.sequence > event.sequence }
                .min { lhs, rhs in
                    lhs.sequence == rhs.sequence
                        ? lhs.observedAt < rhs.observedAt
                        : lhs.sequence < rhs.sequence
                }?
                .observedAt)
        } catch {
            // A failed neighbor read is not evidence that the selected event
            // is the latest event. Preserve a fail-closed unavailable state.
            return .unavailable
        }
    }

    public func cancelSummary() {
        requestGeneration &+= 1
        summaryTask?.cancel()
        summaryTask = nil
        selectedEventID = nil
        summaryState = .idle
    }

    public func cancelAll() {
        requestGeneration &+= 1
        pageTask?.cancel()
        summaryTask?.cancel()
        pageTask = nil
        summaryTask = nil
        // Keep the selected row so the global sheet can restore its session,
        // but never leave a cancelled task presenting an endless spinner.
        if summaryState == .loading {
            summaryState = .idle
            summaryErrorKey = nil
        }
    }

    private func reloadForFilterChange() {
        pageTask?.cancel()
        pageTask = Task { [weak self] in await self?.loadNow(reset: true) }
    }

    private func query(beforeSequence: Int64?, limit: Int) -> CapabilityHistoryQuery {
        let now = nowProvider()
        let kinds: Set<ResourceKind> = switch resourceFilter {
        case .all: []
        case .agent: [.agent]
        case .skill: [.skill]
        }
        let changes: Set<CapabilityChangeKind> = changeFilter.map { [$0] } ?? []
        return CapabilityHistoryQuery(
            resourceID: resourceID,
            resourceKinds: kinds,
            changeKinds: changes,
            observedOnOrAfter: recordWindow.start(now: now),
            observedOnOrBefore: recordWindow == .allRetained ? nil : now,
            beforeSequence: beforeSequence,
            limit: limit
        )
    }

    private func commit(_ page: CapabilityHistoryPage, replacing: Bool) {
        if replacing {
            events = page.events
        } else {
            let existing = Set(events.map(\.id))
            events.append(contentsOf: page.events.filter { !existing.contains($0.id) })
        }
        events.sort { $0.sequence > $1.sequence }
        nextBeforeSequence = page.nextBeforeSequence
        truncatedBefore = page.truncatedBefore
        issueCodes = Array(Set(issueCodes + page.issueCodes)).sorted { $0.rawValue < $1.rawValue }
        hasLoadedFirstPage = true
        lastErrorKey = nil
        loadState = events.isEmpty ? .empty : .loaded
    }

    private func errorKey(_ error: Error) -> String {
        if let storeError = error as? CapabilityHistoryStore.StoreError {
            switch storeError {
            case .corrupt: return "history.state.corrupt"
            case .unsupportedVersion: return "history.state.unsupported"
            case .storageUnavailable: return "history.state.unavailable"
            default: return "history.state.failed"
            }
        }
        return "history.state.failed"
    }
}

private func capabilityHistoryWarningLabel(_ text: String) -> some View {
    Label {
        Text(text)
            .foregroundStyle(DirectorColor.textSupporting)
    } icon: {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(DirectorColor.status(.warning))
    }
}

public struct CapabilityHistoryEventRow: View {
    public let event: CapabilityChangeEvent
    public let isSelected: Bool
    public let localizer: DirectorLocalizer
    public let isResourceAvailable: Bool
    /// Detail disclosures have a narrower reading column than the global
    /// sheet. Their date is deliberately stacked below the capability name so
    /// a 380–420pt window never compresses or truncates the timestamp.
    public let compact: Bool
    public let onSelect: () -> Void

    public init(event: CapabilityChangeEvent, isSelected: Bool, localizer: DirectorLocalizer, isResourceAvailable: Bool = true, compact: Bool = false, onSelect: @escaping () -> Void) {
        self.event = event; self.isSelected = isSelected; self.localizer = localizer; self.isResourceAvailable = isResourceAvailable; self.compact = compact; self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                heading
                Text(changeLabel)
                    .font(DirectorTypography.body.weight(.medium))
                    .foregroundStyle(DirectorColor.textPrimary)
                if !isResourceAvailable || event.kind == .missing {
                    capabilityHistoryWarningLabel(localizer.text("history.resource.notFound", fallback: "Not found in the current directory"))
                        .font(DirectorTypography.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !event.changedDocuments.isEmpty {
                    Text(event.changedDocuments.sorted { $0.rawValue < $1.rawValue }.map(documentLabel).joined(separator: " · "))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                } else if event.kind == .modified && !event.changedDocumentsAreExact {
                    Text(localizer.text("history.document.unknown", fallback: "Tracked documents changed; specific documents are unavailable."))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isSelected {
                    Label(localizer.text("history.selected", fallback: "Selected event"), systemImage: "checkmark.circle")
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.dataText)
                }
            }
            .padding(.horizontal, DirectorSpacing.space4)
            .padding(.vertical, DirectorSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? DirectorColor.inset : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DirectorColor.boundary)
                    .frame(height: 1)
                    .padding(.horizontal, DirectorSpacing.space4)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let documents = event.changedDocuments.isEmpty && !event.changedDocumentsAreExact
            ? localizer.text("history.document.unknown", fallback: "Tracked documents changed; specific documents are unavailable.")
            : event.changedDocuments.sorted { $0.rawValue < $1.rawValue }.map(documentLabel).joined(separator: ", ")
        let availability = (!isResourceAvailable || event.kind == .missing)
            ? localizer.text("history.resource.notFound", fallback: "Not found in the current directory")
            : ""
        return [event.name, resourceKindLabel, scopeLabel, changeLabel, availability, fullDate(event.observedAt), documents].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    @ViewBuilder private var heading: some View {
        if compact {
            VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                Text(event.name)
                    .font(DirectorTypography.capabilityRowTitle)
                    .foregroundStyle(DirectorColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fullDate(event.observedAt))
                    .font(DirectorTypography.label.monospacedDigit())
                    .foregroundStyle(DirectorColor.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(resourceKindLabel) · \(scopeLabel)")
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
                VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
                    Text(event.name)
                        .font(DirectorTypography.capabilityRowTitle)
                        .foregroundStyle(DirectorColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(resourceKindLabel) · \(scopeLabel)")
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSupporting)
                }
                Spacer(minLength: DirectorSpacing.space2)
                Text(fullDate(event.observedAt))
                    .font(DirectorTypography.label.monospacedDigit())
                    .foregroundStyle(DirectorColor.textSupporting)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var changeLabel: String { localizer.text("history.event.\(event.kind.rawValue)", fallback: event.kind.rawValue) }
    private var resourceKindLabel: String { localizer.text("history.kind.\(event.resourceKind.rawValue)", fallback: event.resourceKind.rawValue.capitalized) }
    private var scopeLabel: String { localizer.text("history.scope.\(event.scope.rawValue)", fallback: event.scope.rawValue.capitalized) }
    private func documentLabel(_ document: CapabilityTrackedDocument) -> String {
        switch document {
        case .agentConfiguration: return localizer.text("history.document.agentConfiguration", fallback: "Agent configuration")
        case .agentBrief: return localizer.text("history.document.agentBrief", fallback: "Agent method document")
        case .skillManifest: return localizer.text("history.document.skillManifest", fallback: "Skill description file")
        }
    }
    private func fullDate(_ date: Date) -> String {
        localizer.date(date, style: .dateTime.year().month().day().hour().minute())
    }
}

public struct CapabilityHistorySelectedSummary: View {
    public let event: CapabilityChangeEvent
    public let state: CapabilityHistorySummaryState
    public let period: CapabilityChangeUsagePeriod
    public let localizer: DirectorLocalizer
    public let onPeriodChange: @MainActor (CapabilityChangeUsagePeriod) -> Void
    public let onOpenResource: (() -> Void)?

    public init(event: CapabilityChangeEvent, state: CapabilityHistorySummaryState, period: CapabilityChangeUsagePeriod, localizer: DirectorLocalizer, onPeriodChange: @escaping @MainActor (CapabilityChangeUsagePeriod) -> Void, onOpenResource: (() -> Void)? = nil) {
        self.event = event; self.state = state; self.period = period; self.localizer = localizer; self.onPeriodChange = onPeriodChange; self.onOpenResource = onOpenResource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
            Text(event.name)
                .font(DirectorTypography.capabilityRowTitle)
                .foregroundStyle(DirectorColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if event.kind == .missing {
                // A missing capability has no post-change call interval. Keep
                // only its observation context and explanation; never show
                // the ordinary "recorded calls after the observed change"
                // heading for an interval that cannot be calculated.
                eventContext
                capabilityHistoryWarningLabel(localizer.text("history.resource.notFound", fallback: "Not found in the current directory"))
                    .font(DirectorTypography.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                Text(localizer.text("history.summary.missing", fallback: "This capability was not found in two consecutive complete scans; post-change usage is not calculated."))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSupporting)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
                    Text(localizer.text("history.summary.title", fallback: "Recorded calls after the observed change"))
                        .font(DirectorTypography.sectionTitle)
                        .foregroundStyle(DirectorColor.textPrimary)
                    Spacer(minLength: DirectorSpacing.space2)
                    if let onOpenResource {
                        Button(localizer.text("history.openDetail", fallback: "Open capability detail"), action: onOpenResource)
                            .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("history-open-detail")
                    }
                }
                .accessibilityElement(children: .contain)
                eventContext
                summaryControls
                switch state {
                case .idle:
                    EmptyView()
                case .loading:
                    ProgressView(localizer.text("history.summary.loading", fallback: "Loading bounded summary…"))
                        .controlSize(.small)
                case .failed:
                    capabilityHistoryWarningLabel(localizer.text("history.state.failed", fallback: "Change history is temporarily unavailable"))
                        .font(DirectorTypography.supporting)
                case let .loaded(summary):
                    loadedSummary(summary)
                }
            }
        }
        .padding(.top, DirectorSpacing.space3)
        .padding(.horizontal, DirectorSpacing.space4)
        .padding(.bottom, DirectorSpacing.space4)
        .accessibilityElement(children: .contain)
    }

    private var summaryControls: some View {
        DirectorOutlinedSegmentedControl(
            localizer.text("history.summary.period", fallback: "Summary: Last 30 days"),
            selection: Binding(get: { period }, set: { value in onPeriodChange(value) }),
            options: [
                .init(value: CapabilityChangeUsagePeriod.recent7, title: localizer.text("history.period.seven", fallback: "Last 7 days")),
                .init(value: CapabilityChangeUsagePeriod.recent30, title: localizer.text("history.period.thirty", fallback: "Last 30 days"))
            ]
        )
        .accessibilityLabel(localizer.text("history.summary.period", fallback: "Summary period"))
        .accessibilityElement(children: .combine)
    }

    private var eventContext: some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space1) {
            Text("\(localizer.text("history.observed", fallback: "Observed")): \(date(event.observedAt))")
            if let previous = event.previousConfirmedAt {
                Text("\(localizer.text("history.previousConfirmed", fallback: "Possible change interval from")): \(date(previous))")
            }
        }
        .font(DirectorTypography.supporting)
        .foregroundStyle(DirectorColor.textSupporting)
    }

    @ViewBuilder private func loadedSummary(_ summary: CapabilityChangeUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
            if let interval = summary.interval {
                let endSuffix = interval.endInclusive ? "" : " \(localizer.text("history.summary.openEnd", fallback: "(end exclusive)"))"
                Text("\(localizer.text("history.summary.interval", fallback: "Actual summary interval")): \(date(interval.start)) – \(date(interval.end))\(endSuffix)")
            } else {
                Text("\(localizer.text("history.summary.interval", fallback: "Actual summary interval")): \(localizer.text("history.summary.notAvailable", fallback: "—"))")
            }
            Text("\(localizer.text("history.summary.cutoff", fallback: "Statistics through")): \(summaryCutoff(summary))")
            summaryCount(label: localizer.text("history.summary.calls", fallback: "Recorded calls"), value: countValue(summary.callCount, inferred: summary.inferredCount, summary: summary))
            let evaluationReason = localizer.text("history.summary.evaluationsUnavailable", fallback: "Evaluation coverage unavailable")
            summaryCount(label: localizer.text("history.summary.evaluated", fallback: "Evaluated calls"), value: value(summary.evaluatedCount, reason: evaluationReason))
            summaryCount(label: localizer.text("history.summary.effective", fallback: "Effective"), value: value(summary.effectiveCount, reason: summary.evaluatedCount == nil ? evaluationReason : nil))
            summaryCount(label: localizer.text("history.summary.ineffective", fallback: "Ineffective"), value: value(summary.ineffectiveCount, reason: summary.evaluatedCount == nil ? evaluationReason : nil))
            summaryCount(label: localizer.text("history.summary.uncertain", fallback: "Uncertain"), value: value(summary.uncertainCount, reason: summary.evaluatedCount == nil ? evaluationReason : nil))
            summaryCount(label: localizer.text("history.summary.unrated", fallback: "Not evaluated"), value: value(summary.unratedCount, reason: summary.evaluatedCount == nil ? evaluationReason : nil))
            if summary.coverage == .partial || summary.inferredCount != nil && summary.inferredCount! > 0 {
                Text(localizer.text("history.summary.partial", fallback: "Partial or inferred evidence is retained as qualified coverage."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
            }
            if summary.availability != .available {
                Text(availabilityReason(summary.availability))
                    .font(DirectorTypography.supporting)
                    .foregroundStyle(DirectorColor.textSupporting)
            }
        }
        .font(DirectorTypography.supporting)
        .foregroundStyle(DirectorColor.textSupporting)
    }

    private func summaryCount(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirectorSpacing.space3) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).font(DirectorTypography.data).multilineTextAlignment(.trailing)
        }
    }
    private func countValue(_ count: Int?, inferred: Int?, summary: CapabilityChangeUsageSummary) -> String {
        guard let count else { return "— · \(availabilityReason(summary.availability))" }
        if count == 0 { return "0 · \(localizer.text("history.summary.zero", fallback: "No recorded calls observed"))" }
        if let inferred, inferred > 0 { return "\(count) · \(localizer.text("history.summary.inferred", fallback: "partial / inferred"))" }
        return String(count)
    }
    private func value(_ value: Int?, reason: String?) -> String {
        guard let value else { return reason.map { "— · \($0)" } ?? "—" }
        return String(value)
    }
    private func summaryCutoff(_ summary: CapabilityChangeUsageSummary) -> String {
        if let through = summary.cacheKey.statisticsThrough { return date(through) }
        return localizer.text("history.summary.notAvailable", fallback: "—")
    }
    private func availabilityReason(_ availability: CapabilityChangeUsageAvailability) -> String {
        switch availability {
        case .available: return ""
        case .outsideSelectedPeriod: return localizer.text("history.state.outside", fallback: "Outside this summary window")
        case .indexUnavailable: return localizer.text("history.state.indexUnavailable", fallback: "Call data is not indexed")
        case .indexOutdated: return localizer.text("history.state.indexOutdated", fallback: "Call data is not yet updated through this observation")
        case .invalidInterval: return localizer.text("history.state.clock", fallback: "Time anomaly detected; showing record order")
        }
    }
    private func date(_ date: Date) -> String { localizer.date(date, style: .dateTime.year().month().day().hour().minute()) }
}

public struct CapabilityHistorySheet: View {
    @StateObject private var model: CapabilityHistoryPresentationModel
    @Binding private var scrollPosition: String?
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.capabilityHistoryMutationRevision) private var historyMutationRevision
    public let onOpenResource: (String) -> Void
    public let isResourceAvailable: (String) -> Bool

    public init(
        source: CapabilityHistoryPresentationSource,
        scrollPosition: Binding<String?> = .constant(nil),
        onOpenResource: @escaping (String) -> Void = { _ in },
        isResourceAvailable: @escaping (String) -> Bool = { _ in true }
    ) {
        _model = StateObject(wrappedValue: CapabilityHistoryPresentationModel(source: source))
        _scrollPosition = scrollPosition
        self.onOpenResource = onOpenResource
        self.isResourceAvailable = isResourceAvailable
    }

    public init(
        model: CapabilityHistoryPresentationModel,
        scrollPosition: Binding<String?> = .constant(nil),
        onOpenResource: @escaping (String) -> Void = { _ in },
        isResourceAvailable: @escaping (String) -> Bool = { _ in true }
    ) {
        _model = StateObject(wrappedValue: model)
        _scrollPosition = scrollPosition
        self.onOpenResource = onOpenResource
        self.isResourceAvailable = isResourceAvailable
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    filters
                    Text(languageStore.localizer.text("history.limit", fallback: "Multiple changes between scans may not be recorded individually. Agent configuration/method documents are tracked; Skills track only SKILL.md. Scripts, images, binaries and other supporting files are outside this version."))
                        .font(DirectorTypography.label)
                        .foregroundStyle(DirectorColor.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowSeparator(.hidden)
                statusSection
                if model.shouldShowEmptyState {
                    emptySection
                } else {
                    ForEach(model.events) { event in
                        CapabilityHistoryEventRow(event: event, isSelected: model.selectedEventID == event.id, localizer: languageStore.localizer, isResourceAvailable: isResourceAvailable(event.resourceID)) { model.select(event) }
                            .id(event.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        if model.selectedEventID == event.id {
                            CapabilityHistorySelectedSummary(
                                event: event,
                                state: model.summaryState,
                                period: model.summaryPeriod,
                                localizer: languageStore.localizer,
                                onPeriodChange: model.setSummaryPeriod,
                                onOpenResource: event.kind == .missing || !isResourceAvailable(event.resourceID) ? nil : { onOpenResource(event.resourceID) }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    }
                    if model.nextBeforeSequence != nil {
                        Button(languageStore.localizer.text("history.loadMore", fallback: "Load earlier records"), action: model.loadMore)
                            .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .disabled(model.loadState == .loading)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DirectorColor.canvas)
            .scrollPosition(id: $scrollPosition, anchor: .top)
            .navigationTitle(languageStore.localizer.text("history.title", fallback: "Change history"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(languageStore.localizer.text("common.close", fallback: "Close"), action: { dismiss() })
                }
            }
            .frame(minWidth: 520, idealWidth: 640, maxWidth: 800, minHeight: 0, idealHeight: 600)
        }
        .task(id: historyMutationRevision) {
            await model.loadIfNeeded(for: historyMutationRevision)
            model.resumeSelectedSummaryIfNeeded()
        }
        .onDisappear { model.cancelAll() }
    }

    private var filters: some View {
        // Keep the approved 3/2/1 visual grid, but use explicit structural
        // rows so AppKit does not flatten an adaptive LazyVGrid into one
        // selectable List row. Each child remains a live native Menu.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DirectorSpacing.space3) {
                windowFilter
                resourceFilter
                eventFilter
            }
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                HStack(spacing: DirectorSpacing.space3) {
                    windowFilter
                    resourceFilter
                }
                eventFilter
            }
            VStack(alignment: .leading, spacing: DirectorSpacing.space3) {
                windowFilter
                resourceFilter
                eventFilter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var windowFilter: some View {
        DirectorOutlinedMenuField(windowTitle, titleLineLimit: 2) {
            Button(languageStore.localizer.text("history.window.seven", fallback: "Last 7 days")) { model.setRecordWindow(.last7) }
            Button(languageStore.localizer.text("history.window.thirty", fallback: "Last 30 days")) { model.setRecordWindow(.last30) }
            Button(languageStore.localizer.text("history.window.all", fallback: "All retained records")) { model.setRecordWindow(.allRetained) }
        }
        .accessibilityLabel(languageStore.localizer.text("history.window.label", fallback: "Timeline period"))
        .accessibilityValue(windowTitle)
        .accessibilityIdentifier("history-filter-window")
        .accessibilityElement(children: .combine)
        .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
    }

    private var resourceFilter: some View {
        DirectorOutlinedMenuField(resourceTitle, titleLineLimit: 2) {
            Button(languageStore.localizer.text("history.filter.all", fallback: "All")) { model.setResourceFilter(.all) }
            Button(languageStore.localizer.text("history.kind.agent", fallback: "Agent")) { model.setResourceFilter(.agent) }
            Button(languageStore.localizer.text("history.kind.skill", fallback: "Skill")) { model.setResourceFilter(.skill) }
        }
        .accessibilityLabel(languageStore.localizer.text("history.filter.resource", fallback: "Resource type"))
        .accessibilityValue(resourceTitle)
        .accessibilityIdentifier("history-filter-resource")
        .accessibilityElement(children: .combine)
        .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
    }

    private var eventFilter: some View {
        DirectorOutlinedMenuField(eventTitle, titleLineLimit: 2) {
            Button(languageStore.localizer.text("history.filter.all", fallback: "All")) { model.setChangeFilter(nil) }
            ForEach(CapabilityChangeKind.allCases, id: \.self) { kind in
                Button(languageStore.localizer.text("history.event.\(kind.rawValue)", fallback: kind.rawValue)) { model.setChangeFilter(kind) }
            }
        }
        .accessibilityLabel(languageStore.localizer.text("history.filter.event", fallback: "Event type"))
        .accessibilityValue(eventTitle)
        .accessibilityIdentifier("history-filter-event")
        .accessibilityElement(children: .combine)
        .frame(minWidth: 176, maxWidth: .infinity, alignment: .leading)
    }

    private var windowTitle: String {
        let label = switch model.recordWindow {
        case .last7: languageStore.localizer.text("history.window.seven", fallback: "Last 7 days")
        case .last30: languageStore.localizer.text("history.window.thirty", fallback: "Last 30 days")
        case .allRetained: languageStore.localizer.text("history.window.all", fallback: "All retained records")
        }
        return "\(languageStore.localizer.text("history.window.prefix", fallback: "Records")): \(label)"
    }
    private var resourceTitle: String { "\(languageStore.localizer.text("history.resource.prefix", fallback: "Type")): \(languageStore.localizer.text("history.filter.\(model.resourceFilter.rawValue)", fallback: model.resourceFilter.rawValue.capitalized))" }
    private var eventTitle: String { "\(languageStore.localizer.text("history.event.prefix", fallback: "Event")): \(model.changeFilter.map { languageStore.localizer.text("history.event.\($0.rawValue)", fallback: $0.rawValue) } ?? languageStore.localizer.text("history.filter.all", fallback: "All"))" }

    @ViewBuilder private var statusSection: some View {
        if model.loadState == .loading && model.events.isEmpty {
            ProgressView(languageStore.localizer.text("history.state.loading", fallback: "Loading change history…"))
                .controlSize(.small)
                .listRowSeparator(.hidden)
        } else if let issue = model.statusIssueKey {
            HStack(spacing: DirectorSpacing.space2) {
                capabilityHistoryWarningLabel(languageStore.localizer.text(issue, fallback: "History coverage is partial"))
                if model.shouldOfferReadRetry {
                    Spacer(minLength: DirectorSpacing.space2)
                    Button(languageStore.localizer.text("history.retry", fallback: "Retry"), action: model.retry)
                        .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                }
            }
            .font(DirectorTypography.supporting)
            .listRowSeparator(.hidden)
        } else if model.isBaselinePending {
            Label(languageStore.localizer.text("history.state.baseline", fallback: "Waiting for a baseline"), systemImage: "clock.arrow.circlepath")
                .font(DirectorTypography.supporting)
                .foregroundStyle(DirectorColor.textSupporting)
                .listRowSeparator(.hidden)
        }
        if let truncatedBefore = model.truncatedBefore {
            Text("\(languageStore.localizer.text("history.retention", fallback: "History is retained from")) \(languageStore.localizer.date(truncatedBefore)) · \(languageStore.localizer.text("history.retention.limits", fallback: "180 days / 100 per capability / 20,000 total"))")
                .font(DirectorTypography.label)
                .foregroundStyle(DirectorColor.textSupporting)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var emptySection: some View {
        Text(model.hasNoMatchingEvents
             ? languageStore.localizer.text("history.state.noMatch", fallback: "No records match these filters")
             : languageStore.localizer.text("history.state.noEvents", fallback: "No changes recorded yet"))
            .font(DirectorTypography.supporting)
            .foregroundStyle(DirectorColor.textSupporting)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
    }
}

public struct CapabilityHistoryDisclosure: View {
    @Binding public var isExpanded: Bool
    @StateObject private var model: CapabilityHistoryPresentationModel
    @EnvironmentObject private var languageStore: AppLanguageStore
    @Environment(\.capabilityHistoryMutationRevision) private var historyMutationRevision
    @State private var loadedHistoryMutationRevision: UInt64?

    public init(resourceID: String, source: CapabilityHistoryPresentationSource, isExpanded: Binding<Bool>) {
        _isExpanded = isExpanded
        _model = StateObject(wrappedValue: CapabilityHistoryPresentationModel(source: source, resourceID: resourceID, initialPageSize: 10, subsequentPageSize: 20))
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DirectorSpacing.space2) {
                if model.loadState == .loading && model.events.isEmpty {
                    ProgressView(languageStore.localizer.text("history.state.loading", fallback: "Loading change history…"))
                        .controlSize(.small)
                } else if let issue = model.statusIssueKey {
                    HStack(spacing: DirectorSpacing.space2) {
                        capabilityHistoryWarningLabel(languageStore.localizer.text(issue, fallback: "Change history is temporarily unavailable"))
                        if model.shouldOfferReadRetry {
                            Spacer(minLength: DirectorSpacing.space2)
                            Button(languageStore.localizer.text("history.retry", fallback: "Retry"), action: model.retry)
                                .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                        }
                    }
                    .font(DirectorTypography.supporting)
                } else if model.isBaselinePending && model.events.isEmpty {
                    Label(languageStore.localizer.text("history.state.baseline", fallback: "Waiting for a baseline"), systemImage: "clock.arrow.circlepath")
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSupporting)
                }
                if model.shouldShowEmptyState {
                    Text(languageStore.localizer.text("history.state.noEvents", fallback: "No changes recorded yet"))
                        .font(DirectorTypography.supporting)
                        .foregroundStyle(DirectorColor.textSupporting)
                } else if !model.events.isEmpty {
                    ForEach(model.events) { event in
                        CapabilityHistoryEventRow(event: event, isSelected: model.selectedEventID == event.id, localizer: languageStore.localizer, compact: true) { model.select(event) }
                        if model.selectedEventID == event.id {
                            CapabilityHistorySelectedSummary(event: event, state: model.summaryState, period: model.summaryPeriod, localizer: languageStore.localizer, onPeriodChange: model.setSummaryPeriod)
                        }
                    }
                    if model.nextBeforeSequence != nil {
                        Button(languageStore.localizer.text("history.loadMore", fallback: "Load earlier records"), action: model.loadMore)
                            .buttonStyle(DirectorSecondaryActionButtonStyle(size: .toolbar))
                            .disabled(model.loadState == .loading)
                    }
                }
                Text(languageStore.localizer.text("history.limit", fallback: "Multiple changes between scans may not be recorded individually. Agent configuration/method documents are tracked; Skills track only SKILL.md. Scripts, images, binaries and other supporting files are outside this version."))
                    .font(DirectorTypography.label)
                    .foregroundStyle(DirectorColor.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(languageStore.localizer.text("history.title", fallback: "Change history"))
        }
        .accessibilityHint(languageStore.localizer.text("history.disclosure.hint", fallback: "Expand to review verified capability-document changes."))
        .task(id: "\(isExpanded)-\(historyMutationRevision ?? 0)") {
            if isExpanded {
                if loadedHistoryMutationRevision != historyMutationRevision {
                    model.cancelAll()
                    await model.loadNow()
                    loadedHistoryMutationRevision = historyMutationRevision
                } else if !model.hasLoadedFirstPage {
                    await model.loadNow()
                }
                model.resumeSelectedSummaryIfNeeded()
            }
            if !isExpanded { model.cancelSummary() }
        }
        .onDisappear { model.cancelAll() }
    }
}
