import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class CapabilityDetailTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    private enum ScriptedInvocationError: Error { case failed }

    private actor ScriptedInvocationLoader {
        let page: CapabilityDetailInvocationPage
        private(set) var requestCount = 0
        private var failNextRequest = false
        private var waitsForRelease = false
        private var released = false
        private(set) var startedWaiting = false

        init(page: CapabilityDetailInvocationPage) { self.page = page }

        func call(_ resourceID: String, _ projectID: String?, _ window: CapabilityQueryWindow, _ pageSize: Int, _ cursor: String?) async throws -> CapabilityDetailInvocationPage {
            _ = (resourceID, projectID, window, pageSize, cursor)
            requestCount += 1
            let shouldFail = failNextRequest
            failNextRequest = false
            if waitsForRelease {
                startedWaiting = true
                while !released {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            if shouldFail { throw ScriptedInvocationError.failed }
            return page
        }

        func failNext() { failNextRequest = true }
        func waitForRelease() { waitsForRelease = true }
        func release() { released = true }
    }

    private actor ScriptedFindingsLoader {
        private let values: [[ReviewFinding]]
        private(set) var requestCount = 0
        private var releaseFirstRequest = false

        init(values: [[ReviewFinding]]) { self.values = values }

        func call(_ resourceID: String) async throws -> [ReviewFinding] {
            _ = resourceID
            requestCount += 1
            let request = requestCount
            while request == 1 && !releaseFirstRequest {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            return values[min(request - 1, values.count - 1)]
        }

        func releaseFirst() { releaseFirstRequest = true }
    }

    private actor CompletionLatch {
        private(set) var completed = false
        func markCompleted() { completed = true }
    }

    private func waitForRequest(_ loader: ScriptedFindingsLoader, count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await loader.requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await loader.requestCount >= count
    }

    private func waitForInvocationRequest(_ loader: ScriptedInvocationLoader, count: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await loader.requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await loader.requestCount >= count
    }

    private func waitForEvidenceToFinish(_ model: CapabilityDetailViewModel) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline && model.state == .loading {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForCompletion(_ latch: CompletionLatch, timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await latch.completed { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await latch.completed
    }

    private func makeFindingsModel(loader: ScriptedFindingsLoader) -> CapabilityDetailViewModel {
        let resource = CapabilityResource(id: "skill:findings", name: "Findings", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: "SKILL.md", sourcePathHash: nil, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000))
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: nil, inferredCount: 0, lastUsedAt: nil, sourceModifiedAt: nil)
        return CapabilityDetailViewModel(row: row, findingsLoader: { resourceID in try await loader.call(resourceID) })
    }

    private func makeInvocationModel(loader: ScriptedInvocationLoader) -> CapabilityDetailViewModel {
        let resource = CapabilityResource(id: "skill:evidence", name: "Evidence", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Declared purpose", sourceRootID: "global", relativeSourcePath: "SKILL.md", sourcePathHash: nil, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000))
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 1, inferredCount: 0, lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceModifiedAt: nil)
        return CapabilityDetailViewModel(row: row, invocationLoader: { resourceID, projectID, window, pageSize, cursor in
            try await loader.call(resourceID, projectID, window, pageSize, cursor)
        })
    }

    private func makeInvocationPage() -> CapabilityDetailInvocationPage {
        let event = InvocationEvent(id: "evidence-call", sessionID: "evidence-session", parentCallID: nil, ordinal: 0, timestamp: Date(timeIntervalSince1970: 1_700_000_000), actorName: nil, resourceID: "skill:evidence", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        return CapabilityDetailInvocationPage(items: [CapabilityDetailInvocation(event: event, projectID: nil, projectName: nil)])
    }

    private func finding(_ id: String, resourceID: String = "skill:findings") -> ReviewFinding {
        ReviewFinding(id: id, ruleID: "rule.test", resourceID: resourceID, sessionID: nil, severity: .info, confidence: .exact, summary: id, evidenceSummary: "Synthetic evidence", coverage: .complete, createdAt: Date(timeIntervalSince1970: 1_700_000_000), remediationStatus: .open)
    }

    private func makeStore() throws -> DatabaseStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("director-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return try DatabaseStore(url: directory.appendingPathComponent("detail.sqlite"))
    }

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDetailKeepsStableOriginalInvocationAndBoundedPageSize() {
        let resource = CapabilityResource(id: "skill:demo", name: "Demo", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: "SKILL.md", sourcePathHash: nil, lastSeenAt: Date())
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 4, inferredCount: 1, lastUsedAt: nil, sourceModifiedAt: nil)
        let model = CapabilityDetailViewModel(row: row, pageSize: 100)
        XCTAssertEqual(model.pageSize, 20)
        XCTAssertEqual(model.recent7Count, 4)
        XCTAssertEqual(model.inferredCount, 1)
        XCTAssertTrue(model.isPurposeMissing)
    }

    func testEvidenceIsLazyUntilExplicitRequest() async {
        let loader = ScriptedInvocationLoader(page: makeInvocationPage())
        let model = makeInvocationModel(loader: loader)
        XCTAssertFalse(model.evidenceRequested)
        try? await Task.sleep(for: .milliseconds(30))
        let initialRequestCount = await loader.requestCount
        XCTAssertEqual(initialRequestCount, 0)

        model.requestEvidence()
        XCTAssertTrue(model.evidenceRequested)
        let didStart = await waitForInvocationRequest(loader, count: 1)
        XCTAssertTrue(didStart)
        await waitForEvidenceToFinish(model)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.invocations.count, 1)
    }

    func testEvidenceCollapseAndReopenReusesLoadedPage() async {
        let loader = ScriptedInvocationLoader(page: makeInvocationPage())
        let model = makeInvocationModel(loader: loader)
        model.requestEvidence()
        let didStart = await waitForInvocationRequest(loader, count: 1)
        XCTAssertTrue(didStart)
        await waitForEvidenceToFinish(model)
        // The view's collapse only hides the section. A second explicit reveal
        // must see loaded state and leave the single query intact.
        model.requestEvidence()
        try? await Task.sleep(for: .milliseconds(30))
        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(model.invocations.count, 1)
    }

    func testEvidenceFailureKeepsRetryAsASecondQuery() async {
        let loader = ScriptedInvocationLoader(page: makeInvocationPage())
        await loader.failNext()
        let model = makeInvocationModel(loader: loader)
        model.requestEvidence()
        let didStart = await waitForInvocationRequest(loader, count: 1)
        XCTAssertTrue(didStart)
        await waitForEvidenceToFinish(model)
        guard case .failed = model.state else {
            XCTFail("expected first evidence request to fail")
            return
        }
        model.reload()
        let didRetry = await waitForInvocationRequest(loader, count: 2)
        XCTAssertTrue(didRetry)
        await waitForEvidenceToFinish(model)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.invocations.count, 1)
    }

    func testCancellingSelectedEvidenceInvalidatesOldQuery() async {
        let loader = ScriptedInvocationLoader(page: makeInvocationPage())
        await loader.waitForRelease()
        let model = makeInvocationModel(loader: loader)
        model.requestEvidence()
        let didStart = await waitForInvocationRequest(loader, count: 1)
        XCTAssertTrue(didStart)
        model.cancelLoading()
        XCTAssertFalse(model.state == .failed("cancelled"))
        XCTAssertGreaterThan(model.generation, 1)
        await loader.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.invocations.isEmpty)
    }

    func testEvaluationUsesInjectedStoreAndCanClear() {
        var data: Data?
        let store = InvocationEvaluationStore(readData: { data }, writeData: { data = $0; return true }, removeData: { data = nil; return true })
        let resource = CapabilityResource(id: "agent:demo", name: "Demo", kind: .agent, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Declared", sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date())
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customAgents, parentPluginID: nil), recent7Count: 1, inferredCount: 0, lastUsedAt: nil, sourceModifiedAt: nil)
        let event = InvocationEvent(id: "call:1", sessionID: "session:1", parentCallID: nil, ordinal: 0, timestamp: Date(), actorName: nil, resourceID: resource.id, kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let invocation = CapabilityDetailInvocation(event: event, projectID: nil, projectName: nil)
        let model = CapabilityDetailViewModel(row: row, evaluationStore: store)
        XCTAssertTrue(model.setEvaluation(.uncertain, for: invocation))
        XCTAssertEqual(model.evaluation(for: invocation)?.label, .uncertain)
        XCTAssertTrue(model.clearEvaluation(for: invocation))
        XCTAssertNil(model.evaluation(for: invocation))
    }

    func testDetailUsesSQLiteKeysetPagesAndProjectFilterWithoutDuplicates() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calls = (0..<5).map { index in
            InvocationEvent(id: "detail-call-\(index)", sessionID: "detail-session-a", parentCallID: nil, ordinal: index,
                timestamp: base.addingTimeInterval(Double(index)), actorName: nil, resourceID: "skill:detail",
                kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        }
        try await store.replaceSession(PersistedSessionBatch(
            session: TaskSummary(id: "detail-session-a", projectID: "project-a", startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "detail-source", title: nil),
            calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        try await store.replaceSession(PersistedSessionBatch(
            session: TaskSummary(id: "detail-session-b", projectID: "project-b", startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "detail-source-b", title: nil),
            calls: [InvocationEvent(id: "detail-other", sessionID: "detail-session-b", parentCallID: nil, ordinal: 0, timestamp: base.addingTimeInterval(10), actorName: nil, resourceID: "skill:detail", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let resource = CapabilityResource(id: "skill:detail", name: "Detail", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Evidence", sourceRootID: "global", relativeSourcePath: "SKILL.md", sourcePathHash: nil, lastSeenAt: base)
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 5, inferredCount: 0, lastUsedAt: base, sourceModifiedAt: nil)
        let model = CapabilityDetailViewModel(row: row, projectID: "project-a", store: store, now: base.addingTimeInterval(20), pageSize: 2)

        await model.loadNow()
        XCTAssertEqual(model.invocations.count, 2)
        XCTAssertEqual(model.invocations.map(\.projectID), ["project-a", "project-a"])
        for _ in 0..<3 { if model.nextCursor == nil { break }; await model.loadMoreNow() }
        XCTAssertEqual(model.invocations.count, 5)
        XCTAssertEqual(Set(model.invocations.map(\.id)).count, 5)
        XCTAssertTrue(model.invocations.allSatisfy { $0.projectID == "project-a" })
    }

    func testFailedEvaluationDoesNotPublishSuccess() {
        var data: Data?
        let store = InvocationEvaluationStore(readData: { data }, writeData: { _ in false }, removeData: { true })
        let resource = CapabilityResource(id: "skill:failure", name: "Failure", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date())
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: nil, inferredCount: 0, lastUsedAt: nil, sourceModifiedAt: nil)
        let event = InvocationEvent(id: "failure-call", sessionID: "failure-session", parentCallID: nil, ordinal: 0, timestamp: Date(), actorName: nil, resourceID: resource.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let model = CapabilityDetailViewModel(row: row, evaluationStore: store)
        let invocation = CapabilityDetailInvocation(event: event, projectID: nil, projectName: nil)
        XCTAssertFalse(model.setEvaluation(.effective, for: invocation))
        XCTAssertNil(model.evaluation(for: invocation))
        XCTAssertEqual(model.persistenceError, "detail.evaluationSaveFailed")
        _ = data
    }

    func testClearFailureRetainsPriorJudgment() {
        var data: Data?
        var allowWrite = true
        let store = InvocationEvaluationStore(readData: { data }, writeData: { value in guard allowWrite else { return false }; data = value; return true }, removeData: { false })
        let resource = CapabilityResource(id: "skill:clear", name: "Clear", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date())
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: nil, inferredCount: 0, lastUsedAt: nil, sourceModifiedAt: nil)
        let event = InvocationEvent(id: "clear-call", sessionID: "clear-session", parentCallID: nil, ordinal: 0, timestamp: Date(), actorName: nil, resourceID: resource.id, kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let model = CapabilityDetailViewModel(row: row, evaluationStore: store)
        let invocation = CapabilityDetailInvocation(event: event, projectID: nil, projectName: nil)
        XCTAssertTrue(model.setEvaluation(.uncertain, for: invocation))
        allowWrite = false
        XCTAssertFalse(model.clearEvaluation(for: invocation))
        XCTAssertEqual(model.evaluation(for: invocation)?.label, .uncertain)
        XCTAssertEqual(model.persistenceError, "detail.evaluationClearFailed")
    }

    func testPresentationRefreshPreservesLoadedPagesAndJudgment() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let calls = (0..<3).map { index in InvocationEvent(id: "refresh-call-\(index)", sessionID: "refresh-session", parentCallID: nil, ordinal: index, timestamp: base.addingTimeInterval(Double(index)), actorName: nil, resourceID: "skill:refresh", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil) }
        try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "refresh-session", projectID: "refresh-project", startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "refresh-source", title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let resource = CapabilityResource(id: "skill:refresh", name: "Refresh", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Old", sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: base)
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 3, inferredCount: 0, lastUsedAt: base, sourceModifiedAt: nil)
        var data: Data?
        let evaluationStore = InvocationEvaluationStore(readData: { data }, writeData: { data = $0; return true }, removeData: { data = nil; return true })
        let model = CapabilityDetailViewModel(row: row, projectID: "refresh-project", store: store, evaluationStore: evaluationStore, now: base.addingTimeInterval(10), pageSize: 2)
        await model.loadNow(); await model.loadMoreNow()
        let first = model.invocations[0]
        XCTAssertTrue(model.setEvaluation(.effective, for: first))
        let updatedResource = CapabilityResource(id: resource.id, name: "Refresh", kind: .skill, status: .success, scope: .global, projectID: nil, confidence: .exact, summary: "New", sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: base)
        let updatedRow = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: updatedResource, category: .customSkills, parentPluginID: nil), recent7Count: 9, inferredCount: 1, lastUsedAt: base, sourceModifiedAt: nil)
        model.updatePresentation(row: updatedRow, projects: [], sessions: [], usageProjectIDs: [], now: base.addingTimeInterval(20))
        XCTAssertEqual(model.invocations.map(\.id), ["refresh-call-2", "refresh-call-1", "refresh-call-0"])
        XCTAssertEqual(model.recent7Count, 9)
        XCTAssertEqual(model.evaluation(for: first)?.label, .effective)
    }

    func testCancellationDoesNotPoisonLatestLoad() async throws {
        let store = try makeStore()
        let resource = CapabilityResource(id: "skill:cancel", name: "Cancel", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: Date())
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 0, inferredCount: 0, lastUsedAt: nil, sourceModifiedAt: nil)
        let model = CapabilityDetailViewModel(row: row, store: store)
        model.startLoading(); model.cancelLoading()
        await model.loadNow()
        XCTAssertNotEqual(model.state, .failed("cancelled"))
        XCTAssertTrue(model.state == .empty || model.state == .loaded)
    }

    func testFindingsCloseReopenCancelsRequestAndReloads() async throws {
        let loader = ScriptedFindingsLoader(values: [[finding("first")], [finding("second")]])
        let model = makeFindingsModel(loader: loader)
        let initialDone = CompletionLatch()
        let initial = Task {
            await model.loadFindingsIfNeeded()
            await initialDone.markCompleted()
        }
        guard await waitForRequest(loader, count: 1) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(initialDone, timeout: .seconds(1))
            XCTFail("findings request did not start")
            return
        }

        model.cancelFindingsLoading()
        guard await waitForCompletion(initialDone) else {
            await loader.releaseFirst()
            _ = await waitForCompletion(initialDone, timeout: .seconds(1))
            XCTFail("cancelled findings request did not finish")
            return
        }
        XCTAssertEqual(model.findingsState, .idle)

        let reopenDone = CompletionLatch()
        let reopen = Task {
            await model.loadFindingsIfNeeded()
            await reopenDone.markCompleted()
        }
        guard await waitForCompletion(reopenDone) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(reopenDone, timeout: .seconds(1))
            XCTFail("reopened findings request did not finish")
            return
        }
        XCTAssertEqual(model.findings.map(\.id), ["second"])
        XCTAssertEqual(model.findingsState, .loaded)
        _ = initial
        _ = reopen
    }

    func testFindingsForceRetryUsesLatestGenerationWithoutStaleOverwrite() async throws {
        let loader = ScriptedFindingsLoader(values: [[finding("stale")], [finding("latest")]])
        let model = makeFindingsModel(loader: loader)
        let initialDone = CompletionLatch()
        let initial = Task {
            await model.loadFindingsIfNeeded()
            await initialDone.markCompleted()
        }
        guard await waitForRequest(loader, count: 1) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(initialDone, timeout: .seconds(1))
            XCTFail("findings request did not start")
            return
        }

        let retryDone = CompletionLatch()
        let retry = Task {
            await model.loadFindingsIfNeeded(force: true)
            await retryDone.markCompleted()
        }
        guard await waitForRequest(loader, count: 2) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(initialDone, timeout: .seconds(1))
            _ = await waitForCompletion(retryDone, timeout: .seconds(1))
            XCTFail("forced findings retry did not start")
            return
        }
        guard await waitForCompletion(initialDone) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(initialDone, timeout: .seconds(1))
            _ = await waitForCompletion(retryDone, timeout: .seconds(1))
            XCTFail("cancelled findings request did not finish")
            return
        }
        guard await waitForCompletion(retryDone) else {
            model.cancelFindingsLoading()
            await loader.releaseFirst()
            _ = await waitForCompletion(retryDone, timeout: .seconds(1))
            XCTFail("forced findings retry did not finish")
            return
        }

        XCTAssertEqual(model.findings.map(\.id), ["latest"])
        XCTAssertEqual(model.findingsState, .loaded)
        _ = initial
        _ = retry
        model.cancelFindingsLoading()
    }

    func testReloadReplacementKeepsStableRowsAndEvaluations() async throws {
        let store = try makeStore(); let base = Date(timeIntervalSince1970: 1_700_200_000)
        func event(_ id: String, _ ordinal: Int) -> InvocationEvent { InvocationEvent(id: id, sessionID: "reload-session", parentCallID: nil, ordinal: ordinal, timestamp: base.addingTimeInterval(Double(ordinal)), actorName: nil, resourceID: "skill:reload", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil) }
        let initial = [event("reload-1", 1), event("reload-0", 0)]
        try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "reload-session", projectID: "reload-project", startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "reload-source", title: nil), calls: initial, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let resource = CapabilityResource(id: "skill:reload", name: "Reload", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: base)
        let row = CapabilityLibraryRow(entry: CapabilityCatalogEntry(resource: resource, category: .customSkills, parentPluginID: nil), recent7Count: 2, inferredCount: 0, lastUsedAt: base, sourceModifiedAt: nil)
        var data: Data?; let evaluations = InvocationEvaluationStore(readData: { data }, writeData: { data = $0; return true }, removeData: { data = nil; return true })
        let model = CapabilityDetailViewModel(row: row, projectID: "reload-project", store: store, evaluationStore: evaluations, now: base.addingTimeInterval(10), pageSize: 2)
        await model.loadNow(); let retained = model.invocations[0]; XCTAssertTrue(model.setEvaluation(.effective, for: retained))
        try await store.replaceSession(PersistedSessionBatch(session: TaskSummary(id: "reload-session", projectID: "reload-project", startedAt: base, endedAt: nil, status: .completed, coverage: .complete, parserVersion: "test", sourceFileID: "reload-source", title: nil), calls: initial + [event("reload-2", 2)], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        model.reload(); for _ in 0..<20 { if model.state != .loading { break }; await Task.yield() }
        XCTAssertEqual(model.invocations.map(\.id), ["reload-2", "reload-1"]); XCTAssertEqual(model.evaluation(for: retained)?.label, .effective)
    }
}
