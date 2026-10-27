import XCTest
@testable import DirectorCore

final class CapabilityChangeUsageTests: XCTestCase {
    private final class QueryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [PresentationQueryOperation] = []

        func append(_ operation: PresentationQueryOperation) {
            lock.lock()
            operations.append(operation)
            lock.unlock()
        }

        func count(_ operation: PresentationQueryOperation) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return operations.filter { $0 == operation }.count
        }
    }

    private final class FirstQueryGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var didBlock = false
        private var enteredFirstQuery = false

        var hasEntered: Bool {
            lock.lock(); defer { lock.unlock() }
            return enteredFirstQuery
        }

        func observe(_ operation: PresentationQueryOperation) {
            guard operation == .allInvocations else { return }
            lock.lock()
            let shouldBlock = !didBlock
            if shouldBlock {
                didBlock = true
                enteredFirstQuery = true
            }
            lock.unlock()
            guard shouldBlock else { return }
            entered.signal()
            release.wait()
        }
    }

    private var temporaryDirectories: [URL] = []
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func makeStore(
        counter: QueryCounter? = nil,
        observer: (@Sendable (PresentationQueryOperation) -> Void)? = nil
    ) throws -> DatabaseStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-change-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return try DatabaseStore(
            url: directory.appendingPathComponent("usage.sqlite"),
            queryObserver: {
                counter?.append($0)
                observer?($0)
            }
        )
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func query(
        resourceID: String = "skill:target",
        observedAt: Date? = nil,
        nextObservedAt: Date? = nil,
        statisticsThrough: Date? = nil,
        identity: PresentationIdentity? = PresentationIdentity(databaseEpoch: "epoch-a", dataGeneration: 7),
        period: CapabilityChangeUsagePeriod = .recent30,
        evaluationRevision: UInt64 = 0
    ) -> CapabilityChangeUsageQuery {
        CapabilityChangeUsageQuery(
            eventID: "event:1",
            resourceID: resourceID,
            observedAt: observedAt ?? reference.addingTimeInterval(-1_000),
            nextObservedAt: nextObservedAt,
            period: period,
            referenceDate: reference,
            calendar: calendar(),
            statisticsThrough: statisticsThrough ?? reference,
            databaseIdentity: identity,
            evaluationRevision: evaluationRevision
        )
    }

    private func batch(
        sessionID: String,
        projectID: String,
        coverage: CoverageState = .complete,
        calls: [InvocationEvent]
    ) -> PersistedSessionBatch {
        PersistedSessionBatch(
            session: TaskSummary(
                id: sessionID,
                projectID: projectID,
                startedAt: calls.compactMap(\.timestamp).min(),
                endedAt: calls.compactMap(\.timestamp).max(),
                status: .completed,
                coverage: coverage,
                parserVersion: "synthetic",
                sourceFileID: "source:\(sessionID)",
                title: nil
            ),
            calls: calls,
            tokenSnapshots: [],
            quotaSnapshots: [],
            findings: []
        )
    }

    private func call(
        _ id: String,
        sessionID: String,
        resourceID: String = "skill:target",
        timestamp: Date?,
        confidence: EvidenceConfidence = .exact,
        kind: InvocationKind = .skill,
        evidenceKind: InvocationEvidenceKind? = nil
    ) -> InvocationEvent {
        InvocationEvent(
            id: id,
            sessionID: sessionID,
            parentCallID: nil,
            ordinal: 0,
            timestamp: timestamp,
            actorName: nil,
            resourceID: resourceID,
            kind: kind,
            status: .completed,
            durationMs: nil,
            confidence: confidence,
            errorCategory: nil,
            evidenceKind: evidenceKind
        )
    }

    private func memoryEvaluations(_ values: [InvocationEvaluation]) -> InvocationEvaluationStore {
        var data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }))
        return InvocationEvaluationStore(
            readData: { data },
            writeData: { data = $0; return true },
            removeData: { data = nil; return true }
        )
    }

    func testAdjacentEventBoundaryIsExclusiveAndLastKnownThroughBoundaryIsInclusive() async throws {
        let store = try makeStore()
        let observed = reference.addingTimeInterval(-100)
        let boundary = reference.addingTimeInterval(-50)
        try await store.replaceSession(batch(
            sessionID: "session:boundary",
            projectID: "project:a",
            calls: [
                call("call:before", sessionID: "session:boundary", timestamp: boundary.addingTimeInterval(-1)),
                call("call:at", sessionID: "session:boundary", timestamp: boundary),
            ]
        ))

        let first = try await store.fetchCapabilityChangeUsage(query(
            observedAt: observed,
            nextObservedAt: boundary,
            statisticsThrough: reference
        ))
        XCTAssertEqual(first.callCount, 1)
        XCTAssertFalse(try XCTUnwrap(first.interval).endInclusive)

        let last = try await store.fetchCapabilityChangeUsage(query(
            observedAt: boundary,
            nextObservedAt: nil,
            statisticsThrough: boundary
        ))
        XCTAssertEqual(last.callCount, 1)
        XCTAssertTrue(try XCTUnwrap(last.interval).endInclusive)
    }

    func testDefaultSummaryPeriodIsThirtyLocalNaturalDaysAndHasNoUnlimitedCase() {
        let value = query()
        let expectedStart = calendar().date(
            byAdding: .day,
            value: -29,
            to: calendar().startOfDay(for: reference)
        )
        XCTAssertEqual(value.period, .recent30)
        XCTAssertEqual(value.selectedWindow.start, expectedStart)
        XCTAssertEqual(value.selectedWindow.end, reference)
        XCTAssertEqual(Set(CapabilityChangeUsagePeriod.allCases), [.recent7, .recent30])
    }

    func testSummaryJoinsCurrentEvaluationsByCallSessionAndResourceNotEvaluationEditTime() async throws {
        let store = try makeStore()
        let time = reference.addingTimeInterval(-100)
        let validCalls = [
            call("call:effective", sessionID: "session:ratings", timestamp: time),
            call("call:uncertain", sessionID: "session:ratings", timestamp: time.addingTimeInterval(1)),
            call("call:wrong-resource", sessionID: "session:ratings", timestamp: time.addingTimeInterval(2)),
            call("call:wrong-session", sessionID: "session:ratings", timestamp: time.addingTimeInterval(3)),
            call("call:unrated", sessionID: "session:ratings", timestamp: time.addingTimeInterval(4)),
            call("call:no-time", sessionID: "session:ratings", timestamp: nil),
        ]
        try await store.replaceSession(batch(
            sessionID: "session:ratings",
            projectID: "project:a",
            calls: validCalls
        ))
        let editedMuchLater = reference.addingTimeInterval(1_000_000)
        let evaluations = memoryEvaluations([
            InvocationEvaluation(invocationID: "call:effective", sessionID: "session:ratings", resourceID: "skill:target", label: .effective, updatedAt: editedMuchLater),
            InvocationEvaluation(invocationID: "call:uncertain", sessionID: "session:ratings", resourceID: "skill:target", label: .uncertain, updatedAt: editedMuchLater),
            InvocationEvaluation(invocationID: "call:wrong-resource", sessionID: "session:ratings", resourceID: "skill:other", label: .ineffective, updatedAt: time),
            InvocationEvaluation(invocationID: "call:wrong-session", sessionID: "session:other", resourceID: "skill:target", label: .ineffective, updatedAt: time),
            InvocationEvaluation(invocationID: "call:orphan", sessionID: "session:ratings", resourceID: "skill:target", label: .ineffective, updatedAt: time),
            InvocationEvaluation(invocationID: "call:no-time", sessionID: "session:ratings", resourceID: "skill:target", label: .effective, updatedAt: time),
        ])
        let repository = CapabilityChangeUsageRepository(database: store, evaluations: evaluations)

        let summary = try await repository.summary(for: query(observedAt: time.addingTimeInterval(-1)))

        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.callCount, 5)
        XCTAssertEqual(summary.evaluatedCount, 2)
        XCTAssertEqual(summary.effectiveCount, 1)
        XCTAssertEqual(summary.ineffectiveCount, 0)
        XCTAssertEqual(summary.uncertainCount, 1)
        XCTAssertEqual(summary.unratedCount, 3)
    }

    func testEvaluationMutationDuringSQLNeverReturnsOldRatingsAsCurrent() async throws {
        let gate = FirstQueryGate()
        let counter = QueryCounter()
        let store = try makeStore(counter: counter, observer: gate.observe)
        let time = reference.addingTimeInterval(-100)
        try await store.replaceSession(batch(
            sessionID: "session:race",
            projectID: "project:a",
            calls: [call("call:race", sessionID: "session:race", timestamp: time)]
        ))
        let evaluations = memoryEvaluations([
            InvocationEvaluation(
                invocationID: "call:race",
                sessionID: "session:race",
                resourceID: "skill:target",
                label: .effective,
                updatedAt: time
            )
        ])
        let repository = CapabilityChangeUsageRepository(database: store, evaluations: evaluations)
        let usageQuery = query(observedAt: time.addingTimeInterval(-1))
        let request = Task {
            try await repository.summary(for: usageQuery)
        }
        while !gate.hasEntered { await Task.yield() }
        XCTAssertTrue(evaluations.set(InvocationEvaluation(
            invocationID: "call:race",
            sessionID: "session:race",
            resourceID: "skill:target",
            label: .ineffective,
            updatedAt: time.addingTimeInterval(1)
        )))
        gate.release.signal()

        let summary = try await request.value
        XCTAssertEqual(summary.effectiveCount, 0)
        XCTAssertEqual(summary.ineffectiveCount, 1)
        XCTAssertEqual(counter.count(.allInvocations), 2, "one mutation permits one bounded retry")
    }

    func testCorruptEvaluationMetadataKeepsCallCountsButLeavesRatingCoverageUnknown() async throws {
        let store = try makeStore()
        let time = reference.addingTimeInterval(-100)
        try await store.replaceSession(batch(
            sessionID: "session:corrupt-ratings",
            projectID: "project:a",
            calls: [call("call:corrupt-ratings", sessionID: "session:corrupt-ratings", timestamp: time)]
        ))
        let evaluations = InvocationEvaluationStore(
            readData: { Data("{not-json".utf8) },
            writeData: { _ in false },
            removeData: { false }
        )

        let summary = try await CapabilityChangeUsageRepository(
            database: store,
            evaluations: evaluations
        ).summary(for: query(observedAt: time.addingTimeInterval(-1)))

        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.callCount, 1)
        XCTAssertNil(summary.evaluatedCount)
        XCTAssertNil(summary.effectiveCount)
        XCTAssertNil(summary.ineffectiveCount)
        XCTAssertNil(summary.uncertainCount)
        XCTAssertNil(summary.unratedCount)
        XCTAssertTrue(evaluations.all().isEmpty, "legacy consumers retain empty-on-corrupt semantics")
    }

    func testUnavailableEvaluationReadDoesNotBecomeAllUnrated() async throws {
        let store = try makeStore()
        let time = reference.addingTimeInterval(-100)
        try await store.replaceSession(batch(
            sessionID: "session:unavailable-ratings",
            projectID: "project:a",
            calls: [call("call:unavailable-ratings", sessionID: "session:unavailable-ratings", timestamp: time)]
        ))
        let evaluations = InvocationEvaluationStore(
            readResult: { .unavailable },
            writeData: { _ in false },
            removeData: { false }
        )

        let summary = try await CapabilityChangeUsageRepository(
            database: store,
            evaluations: evaluations
        ).summary(for: query(observedAt: time.addingTimeInterval(-1)))

        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.callCount, 1)
        XCTAssertNil(summary.evaluatedCount)
        XCTAssertNil(summary.unratedCount)
        XCTAssertTrue(evaluations.all().isEmpty, "legacy consumers retain empty-on-unavailable semantics")
    }

    func testQueryUsesStableResourceIDAcrossProjectsAndPreservesNormalizedUsageSemantics() async throws {
        let counter = QueryCounter()
        let store = try makeStore(counter: counter)
        let time = reference.addingTimeInterval(-200)
        try await store.replaceSession(batch(
            sessionID: "session:a",
            projectID: "project:a",
            calls: [
                call("call:a", sessionID: "session:a", timestamp: time, confidence: .inferred),
                call("call:same-name-other-id", sessionID: "session:a", resourceID: "skill:other-id", timestamp: time),
                call("call:delegation-request", sessionID: "session:a", timestamp: time, kind: .agent, evidenceKind: .agentDelegationRequest),
                call("call:agent-brief", sessionID: "session:a", timestamp: time, kind: .agent, evidenceKind: .agentBriefRead),
                call("call:agent-actual", sessionID: "session:a", timestamp: time, kind: .agent, evidenceKind: .agentDelegation),
            ]
        ))
        try await store.replaceSession(batch(
            sessionID: "session:b",
            projectID: "project:b",
            coverage: .partial,
            calls: [call("call:b", sessionID: "session:b", timestamp: time.addingTimeInterval(1))]
        ))

        let result = try await store.fetchCapabilityChangeUsage(query(observedAt: time.addingTimeInterval(-1)))

        XCTAssertEqual(result.callCount, 3)
        XCTAssertEqual(result.inferredCount, 1)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertEqual(counter.count(.allInvocations), 1, "one selected event must use one bounded SQL read")
    }

    func testSummaryReadDoesNotAdvanceIndexGenerationOrStartAReparse() async throws {
        let counter = QueryCounter()
        let store = try makeStore(counter: counter)
        let before = try await store.presentationIdentity()

        _ = try await store.fetchCapabilityChangeUsage(query(
            statisticsThrough: reference,
            identity: before
        ))

        let after = try await store.presentationIdentity()
        XCTAssertEqual(after, before)
        XCTAssertEqual(counter.count(.allInvocations), 1)
    }

    func testUnavailableOutdatedAndDisjointStatesDoNotManufactureZero() async throws {
        let counter = QueryCounter()
        let store = try makeStore(counter: counter)
        let evaluations = memoryEvaluations([])

        let noIndex = try await CapabilityChangeUsageRepository(database: nil, evaluations: evaluations)
            .summary(for: query(identity: nil))
        XCTAssertEqual(noIndex.availability, .indexUnavailable)
        XCTAssertNil(noIndex.callCount)

        let observed = reference.addingTimeInterval(-10)
        let outdated = try await CapabilityChangeUsageRepository(database: store, evaluations: evaluations)
            .summary(for: query(observedAt: observed, statisticsThrough: observed.addingTimeInterval(-1)))
        XCTAssertEqual(outdated.availability, .indexOutdated)
        XCTAssertNil(outdated.callCount)

        let oldEvent = reference.addingTimeInterval(-40 * 86_400)
        let disjoint = try await CapabilityChangeUsageRepository(database: store, evaluations: evaluations)
            .summary(for: query(observedAt: oldEvent, nextObservedAt: oldEvent.addingTimeInterval(60)))
        XCTAssertEqual(disjoint.availability, .outsideSelectedPeriod)
        XCTAssertNil(disjoint.callCount)
        XCTAssertEqual(counter.count(.allInvocations), 0)
    }

    func testZeroLengthAdjacentWindowIsOutsideRangeButClockInversionIsInvalid() async throws {
        let counter = QueryCounter()
        let store = try makeStore(counter: counter)
        let evaluations = memoryEvaluations([])
        let observed = reference.addingTimeInterval(-10)
        let repository = CapabilityChangeUsageRepository(database: store, evaluations: evaluations)

        let empty = try await repository.summary(for: query(
            observedAt: observed,
            nextObservedAt: observed
        ))
        let inverted = try await repository.summary(for: query(
            observedAt: observed,
            nextObservedAt: observed.addingTimeInterval(-1)
        ))

        XCTAssertEqual(empty.availability, .outsideSelectedPeriod)
        XCTAssertNil(empty.callCount)
        XCTAssertEqual(inverted.availability, .invalidInterval)
        XCTAssertNil(inverted.callCount)
        XCTAssertEqual(counter.count(.allInvocations), 0)
    }

    func testCompletedEmptyQueryIsTrueZeroAndCacheKeyTracksDeletionEpochAndEvaluationRevision() async throws {
        let store = try makeStore()
        let evaluations = memoryEvaluations([])
        let firstQuery = query(evaluationRevision: 4)
        let summary = try await CapabilityChangeUsageRepository(database: store, evaluations: evaluations)
            .summary(for: firstQuery)

        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.callCount, 0)
        XCTAssertEqual(summary.coverage, .complete)
        XCTAssertEqual(summary.unratedCount, 0)

        let deletedIndexQuery = query(
            identity: PresentationIdentity(databaseEpoch: "epoch-after-delete", dataGeneration: 0),
            evaluationRevision: 4
        )
        let editedEvaluationQuery = query(evaluationRevision: 5)
        XCTAssertNotEqual(firstQuery.cacheKey, deletedIndexQuery.cacheKey)
        XCTAssertNotEqual(firstQuery.cacheKey, editedEvaluationQuery.cacheKey)
    }

    func testEvaluationCandidateValidationUsesFixedSizeChunksInsteadOfLoadingIntervalCalls() async throws {
        let store = try makeStore()
        let time = reference.addingTimeInterval(-100)
        try await store.replaceSession(batch(
            sessionID: "session:chunked",
            projectID: "project:a",
            calls: [call("call:match", sessionID: "session:chunked", timestamp: time)]
        ))
        let candidates = (0..<1_201).map { index in
            CapabilityChangeUsageEvaluationCandidate(
                invocationID: index == 600 ? "call:match" : "evaluation:\(index)",
                sessionID: "session:chunked"
            )
        }

        let result = try await store.fetchCapabilityChangeUsage(
            query(observedAt: time.addingTimeInterval(-1)),
            evaluationCandidates: candidates
        )

        XCTAssertEqual(result.callCount, 1)
        XCTAssertEqual(result.matchedEvaluationCalls.map(\.invocationID), ["call:match"])
        XCTAssertEqual(result.evaluationLookupChunkCount, 4)
        XCTAssertEqual(result.sqlStatementCount, 5)

        let overflowCandidates = (0..<3_201).map { index in
            CapabilityChangeUsageEvaluationCandidate(
                invocationID: "overflow:\(index)",
                sessionID: "session:chunked"
            )
        }
        let bounded = try await store.fetchCapabilityChangeUsage(
            query(observedAt: time.addingTimeInterval(-1)),
            evaluationCandidates: overflowCandidates
        )
        XCTAssertFalse(bounded.evaluationLookupComplete)
        XCTAssertTrue(bounded.matchedEvaluationCalls.isEmpty)
        XCTAssertEqual(bounded.evaluationLookupChunkCount, 0)
        XCTAssertEqual(bounded.sqlStatementCount, 1)

        let oversizedEvaluationStore = memoryEvaluations((0..<3_201).map { index in
            InvocationEvaluation(
                invocationID: "overflow:\(index)",
                sessionID: "session:chunked",
                resourceID: "skill:target",
                label: .effective,
                updatedAt: time
            )
        })
        let summary = try await CapabilityChangeUsageRepository(
            database: store,
            evaluations: oversizedEvaluationStore
        ).summary(for: query(observedAt: time.addingTimeInterval(-1)))
        XCTAssertEqual(summary.callCount, 1)
        XCTAssertNil(summary.evaluatedCount)
        XCTAssertNil(summary.unratedCount)
    }
}
