import Foundation
import SwiftUI
import DirectorCore

/// A presentation-safe projection of one invocation. `event` is retained so
/// evaluation always uses the original, stable invocation identity.
public struct CapabilityDetailInvocation: Identifiable, Equatable, Sendable {
    public let event: InvocationEvent
    public let projectID: String?
    public let projectName: String?
    public let confidence: EvidenceConfidence
    public var id: String { event.id }

    public init(event: InvocationEvent, projectID: String?, projectName: String?, confidence: EvidenceConfidence? = nil) {
        self.event = event
        self.projectID = projectID
        self.projectName = projectName
        self.confidence = confidence ?? event.confidence
    }
}

/// A bounded page returned by the detail evidence query. Keeping this seam in
/// the UI model makes the lazy lifecycle testable without touching SQLite.
public struct CapabilityDetailInvocationPage: Sendable {
    public let items: [CapabilityDetailInvocation]
    public let nextCursor: String?

    public init(items: [CapabilityDetailInvocation], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum CapabilityDetailLoadState: Equatable, Sendable {
    case idle, loading, loaded, empty
    case failed(String)
}

@MainActor
public final class CapabilityDetailViewModel: ObservableObject {
    public typealias FindingsLoader = @Sendable (String) async throws -> [ReviewFinding]
    public typealias InvocationLoader = @Sendable (String, String?, CapabilityQueryWindow, Int, String?) async throws -> CapabilityDetailInvocationPage

    public private(set) var row: CapabilityLibraryRow
    public private(set) var projectID: String?
    public private(set) var now: Date
    public let pageSize: Int
    public let store: DatabaseStore?
    public private(set) var projects: [CapabilityProject]
    public private(set) var sessions: [TaskSummary]
    public private(set) var usageProjectIDs: Set<String>
    public let evaluationStore: InvocationEvaluationStore?
    private let findingsLoader: FindingsLoader?
    private let invocationLoader: InvocationLoader?
    @Published public private(set) var findings: [ReviewFinding]

    public var onEvaluationChange: ((InvocationEvaluation?) -> Void)?
    public var onClassify: ((String, ResourceOwnership) -> Void)?
    public var onResetClassification: ((String) -> Void)?

    @Published public private(set) var state: CapabilityDetailLoadState = .idle
    @Published public private(set) var invocations: [CapabilityDetailInvocation] = []
    @Published public private(set) var evaluations: [String: InvocationEvaluation] = [:]
    @Published public private(set) var nextCursor: String?
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var generation: Int = 0
    @Published public private(set) var findingsState: CapabilityDetailLoadState = .idle
    /// True after the user has explicitly requested usage evidence. Selection
    /// and metadata refreshes never set this flag.
    @Published public private(set) var evidenceRequested = false

    private var loadTask: Task<Void, Never>?
    private var findingsTask: Task<Void, Never>?
    private var findingsGeneration: Int = 0
    private var observedProjectIDs = Set<String>()

    public init(
        row: CapabilityLibraryRow,
        projectID: String? = nil,
        store: DatabaseStore? = nil,
        projects: [CapabilityProject] = [],
        sessions: [TaskSummary] = [],
        usageProjectIDs: Set<String> = [],
        evaluationStore: InvocationEvaluationStore? = nil,
        findings: [ReviewFinding] = [],
        now: Date = Date(),
        pageSize: Int = 20,
        findingsLoader: FindingsLoader? = nil,
        invocationLoader: InvocationLoader? = nil,
        onEvaluationChange: ((InvocationEvaluation?) -> Void)? = nil,
        onClassify: ((String, ResourceOwnership) -> Void)? = nil,
        onResetClassification: ((String) -> Void)? = nil
    ) {
        self.row = row; self.projectID = projectID; self.store = store
        self.projects = projects; self.sessions = sessions; self.usageProjectIDs = usageProjectIDs; self.evaluationStore = evaluationStore
        self.findingsLoader = findingsLoader
        self.invocationLoader = invocationLoader
        self.findings = findings.filter { $0.resourceID == row.id }; self.now = now; self.pageSize = max(1, min(pageSize, 20))
        self.findingsState = self.findings.isEmpty ? .idle : .loaded
        self.onEvaluationChange = onEvaluationChange; self.onClassify = onClassify
        self.onResetClassification = onResetClassification
        if let evaluationStore { self.evaluations = evaluationStore.all() }
    }

    public var recent7Count: Int? { row.recent7Count }
    public var inferredCount: Int { row.inferredCount }
    public var usageProjectNames: [String] {
        let ids = !usageProjectIDs.isEmpty ? usageProjectIDs : observedProjectIDs
        return projects.filter { ids.contains($0.id) }.map(\.name)
    }
    public var projectNames: [String] { usageProjectNames }
    public var sourcePurpose: String? { row.entry.resource.summary }
    public var isPurposeMissing: Bool { sourcePurpose?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
    public var isPlugin: Bool { row.entry.resource.kind == .plugin }
    public var statisticsReady: Bool { row.statisticsReady }
    public var attributionUnavailable: Bool { row.attributionUnavailable }

    /// Explicit user action for the lazy evidence section. Repeated requests
    /// reuse loaded/empty evidence and do not issue another first query.
    public func requestEvidence() {
        evidenceRequested = true
        if state == .idle { beginLoading(clearExisting: true) }
    }

    public func startLoading() {
        evidenceRequested = true
        beginLoading(clearExisting: true)
    }

    private func beginLoading(clearExisting: Bool) {
        generation += 1
        let token = generation
        loadTask?.cancel()
        if clearExisting {
            invocations = []
            observedProjectIDs.removeAll()
            nextCursor = nil
        }
        persistenceError = nil
        state = .loading
        loadTask = Task { [weak self] in await self?.loadPage(cursor: nil, token: token, append: false) }
    }

    /// Compatibility spelling for callers that treat detail loading as an
    /// explicit lifecycle operation. It also advances the generation token.
    public func load() { startLoading() }

    /// Awaitable test and integration seam. Unlike `startLoading`, this does
    /// not detach the operation from the caller's task.
    public func loadNow() async {
        evidenceRequested = true
        generation += 1
        let token = generation
        loadTask?.cancel()
        invocations = []
        observedProjectIDs.removeAll()
        nextCursor = nil
        persistenceError = nil
        state = .loading
        await loadPage(cursor: nil, token: token, append: false)
    }

    /// Reload keeps the last good page visible while the new query runs.
    public func reload() {
        evidenceRequested = true
        beginLoading(clearExisting: false)
    }

    public func loadMore() {
        guard nextCursor != nil, state != .loading else { return }
        let token = generation
        let cursor = nextCursor
        state = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadPage(cursor: cursor, token: token, append: true) }
    }

    /// Awaitable counterpart used by deterministic integration tests and
    /// callers that need to know when a page has been committed.
    public func loadMoreNow() async {
        guard let cursor = nextCursor, state != .loading else { return }
        let token = generation
        state = .loading
        await loadPage(cursor: cursor, token: token, append: true)
    }

    public func cancelLoading() {
        generation += 1
        loadTask?.cancel(); loadTask = nil
        if state == .loading { state = invocations.isEmpty ? .idle : .loaded }
    }

    private func loadPage(cursor: String?, token: Int, append: Bool) async {
        guard store != nil || invocationLoader != nil else {
            guard token == generation else { return }
            state = invocations.isEmpty ? .empty : .loaded
            return
        }
        do {
            let window = CapabilityQueryWindow(start: Calendar.current.date(byAdding: .day, value: -36500, to: now) ?? .distantPast, end: now)
            let result: CapabilityDetailInvocationPage
            if let invocationLoader {
                result = try await invocationLoader(row.id, projectID, window, pageSize, cursor)
            } else if let store {
                if row.entry.resource.kind == .plugin {
                    let page = try await store.fetchPluginInvocations(pluginID: row.id, projectID: projectID, window: window, pageSize: pageSize, cursor: cursor)
                    result = CapabilityDetailInvocationPage(items: page.items.map { makeInvocation($0.original, projectID: $0.projectID, confidence: $0.confidence) }, nextCursor: page.nextCursor)
                } else {
                    let page = try await store.fetchCapabilityInvocations(resourceID: row.id, projectID: projectID, window: window, pageSize: pageSize, cursor: cursor)
                    let projectIDs = projectID == nil
                        ? try await store.fetchSessionProjects(ids: page.items.map(\.sessionID))
                        : [:]
                    result = CapabilityDetailInvocationPage(items: page.items.map { event in
                        makeInvocation(event, projectID: projectID ?? projectIDs[event.sessionID] ?? sessionProjectID(event.sessionID), confidence: event.confidence)
                    }, nextCursor: page.nextCursor)
                }
            } else {
                result = CapabilityDetailInvocationPage(items: [], nextCursor: nil)
            }
            guard !Task.isCancelled, token == generation else { return }
            let uniqueIncoming = result.items.reduce(into: [CapabilityDetailInvocation]()) { values, item in
                if !values.contains(where: { $0.id == item.id }) { values.append(item) }
            }
            let existingIDs = Set(invocations.map(\.id))
            let uniqueResult = append ? uniqueIncoming.filter { !existingIDs.contains($0.id) } : uniqueIncoming
            invocations = append ? invocations + uniqueResult : uniqueResult
            observedProjectIDs.formUnion(uniqueResult.compactMap(\.projectID))
            nextCursor = result.nextCursor
            state = invocations.isEmpty ? .empty : .loaded
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func sessionProjectID(_ sessionID: String) -> String? { sessions.first { $0.id == sessionID }?.projectID }
    private func makeInvocation(_ event: InvocationEvent, projectID: String?, confidence: EvidenceConfidence) -> CapabilityDetailInvocation {
        CapabilityDetailInvocation(event: event, projectID: projectID, projectName: projectID.flatMap { id in projects.first { $0.id == id }?.name }, confidence: confidence)
    }

    public func evaluation(for invocation: CapabilityDetailInvocation) -> InvocationEvaluation? { evaluations[invocation.id] }

    /// Findings are evidence attached to the selected capability, not a
    /// startup requirement. The disclosure in the detail view invokes this
    /// bounded query only when requested and keeps the prior result on retry.
    public func loadFindingsIfNeeded(force: Bool = false) async {
        guard store != nil || findingsLoader != nil else {
            if findings.isEmpty { findingsState = .empty }
            return
        }
        guard force || findingsState == .idle else { return }
        findingsTask?.cancel()
        findingsGeneration += 1
        let token = findingsGeneration
        let priorState = findings.isEmpty ? CapabilityDetailLoadState.idle : CapabilityDetailLoadState.loaded
        findingsState = .loading
        let resourceID = row.id
        let loader = findingsLoader
        let request = Task { [weak self, store, loader, resourceID, token, priorState] in
            do {
                let values: [ReviewFinding]
                if let loader {
                    values = try await loader(resourceID)
                } else if let store {
                    values = try await store.fetchReviewFindings(resourceID: resourceID, limit: 100)
                } else {
                    values = []
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.finishFindings(values: values, token: token, priorState: priorState)
            } catch {
                guard let self else { return }
                self.finishFindingsFailure(token: token, priorState: priorState)
            }
        }
        findingsTask = request
        await withTaskCancellationHandler(operation: {
            await request.value
        }, onCancel: {
            request.cancel()
        })
        if token == findingsGeneration { findingsTask = nil }
    }

    private func finishFindings(values: [ReviewFinding], token: Int, priorState: CapabilityDetailLoadState) {
        guard !Task.isCancelled, token == findingsGeneration else {
            if token == findingsGeneration { findingsState = priorState }
            return
        }
        findings = values
        findingsState = values.isEmpty ? .empty : .loaded
    }

    private func finishFindingsFailure(token: Int, priorState: CapabilityDetailLoadState) {
        guard token == findingsGeneration else { return }
        findingsState = Task.isCancelled ? priorState : .failed("detail.findingsLoadFailed")
    }

    public func cancelFindingsLoading() {
        findingsGeneration += 1
        findingsTask?.cancel()
        findingsTask = nil
        if findingsState == .loading { findingsState = findings.isEmpty ? .idle : .loaded }
    }

    /// Updates catalog/session context for a cached detail model without
    /// discarding its loaded evidence or changing stable evaluation IDs.
    /// Callers must keep the same resource and project identity.
    public func updatePresentation(
        row: CapabilityLibraryRow,
        projects: [CapabilityProject],
        sessions: [TaskSummary],
        usageProjectIDs: Set<String>,
        now: Date
    ) {
        guard row.id == self.row.id else { return }
        objectWillChange.send()
        self.row = row
        self.projects = projects
        self.sessions = sessions
        self.usageProjectIDs = usageProjectIDs
        self.now = now
        invocations = invocations.map { invocation in
            CapabilityDetailInvocation(event: invocation.event, projectID: invocation.projectID, projectName: invocation.projectID.flatMap { id in projects.first { $0.id == id }?.name }, confidence: invocation.confidence)
        }
        if let evaluationStore { evaluations = evaluationStore.all() }
    }

    @discardableResult
    public func setEvaluation(_ label: InvocationEvaluationLabel, for invocation: CapabilityDetailInvocation, at date: Date = Date()) -> Bool {
        guard let evaluationStore else { persistenceError = "detail.evaluationUnavailable"; return false }
        let value = InvocationEvaluation(invocationID: invocation.event.id, sessionID: invocation.event.sessionID, resourceID: invocation.event.resourceID, label: label, updatedAt: date)
        guard evaluationStore.set(value) else { persistenceError = "detail.evaluationSaveFailed"; return false }
        evaluations[value.invocationID] = value; persistenceError = nil; onEvaluationChange?(value); return true
    }

    @discardableResult
    public func clearEvaluation(for invocation: CapabilityDetailInvocation) -> Bool {
        guard evaluations[invocation.id] != nil else { return true }
        guard let evaluationStore else { persistenceError = "detail.evaluationUnavailable"; return false }
        guard evaluationStore.remove(for: invocation.id) else { persistenceError = "detail.evaluationClearFailed"; return false }
        evaluations.removeValue(forKey: invocation.id); persistenceError = nil; onEvaluationChange?(nil); return true
    }
}
