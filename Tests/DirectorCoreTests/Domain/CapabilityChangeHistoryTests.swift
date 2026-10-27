import XCTest
@testable import DirectorCore

final class CapabilityChangeHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(
        _ id: String,
        signature: Character = "a",
        root: String = "global-skills",
        documents: Set<CapabilityTrackedDocument> = [.skillManifest],
        algorithm: String = CapabilityHistoryObservation.signatureAlgorithm,
        at date: Date? = nil
    ) -> CapabilityHistoryObservation {
        CapabilityHistoryObservation(
            resourceID: id,
            sourceRootID: root,
            name: "Synthetic \(id)",
            kind: documents.contains(.skillManifest) ? .skill : .agent,
            scope: .global,
            projectID: nil,
            documents: documents,
            signature: String(repeating: signature, count: 64),
            documentSignatures: documents.map {
                CapabilityTrackedDocumentSignature(
                    document: $0,
                    sha256: String(repeating: signature, count: 64)
                )
            },
            observedAt: date ?? base,
            signatureAlgorithm: algorithm
        )
    }

    private func batch(
        _ observations: [CapabilityHistoryObservation],
        coverage: CapabilityHistoryCoverage = .complete,
        root: String = "global-skills",
        rootKind: ScanRootKind = .skills,
        at date: Date? = nil,
        source: CapabilityHistoryObservationSource = .filesystem
    ) -> CapabilityHistoryScanBatch {
        CapabilityHistoryScanBatch(
            observedAt: date ?? base,
            scopes: [.init(rootID: root, scope: .global, rootKind: rootKind, coverage: coverage)],
            observations: observations,
            source: source
        )
    }

    func testFirstCompleteScopeBuildsBaselineThenNewIdentityEmitsAddedOnce() {
        let detector = CapabilityChangeDetector()
        let initial = CapabilityHistoryStateV1.empty(epoch: 7)
        let first = detector.apply(initial, batch: batch([observation("skill:a")]))

        XCTAssertTrue(first.newEvents.isEmpty)
        XCTAssertEqual(first.state.baselines.map(\.resourceID), ["skill:a"])

        let second = detector.apply(first.state, batch: batch([
            observation("skill:a", at: base.addingTimeInterval(60)),
            observation("skill:b", at: base.addingTimeInterval(60)),
        ], at: base.addingTimeInterval(60)))
        XCTAssertEqual(second.newEvents.map(\.kind), [.added])
        XCTAssertEqual(second.newEvents.first?.resourceID, "skill:b")

        let repeated = detector.apply(second.state, batch: batch([
            observation("skill:a", at: base.addingTimeInterval(120)),
            observation("skill:b", at: base.addingTimeInterval(120)),
        ], at: base.addingTimeInterval(120)))
        XCTAssertTrue(repeated.newEvents.isEmpty)
    }

    func testDocumentChangesAreIdempotentAndAtoBtoAProducesTwoEvents() {
        let detector = CapabilityChangeDetector()
        var state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state

        let changed = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))
        XCTAssertEqual(changed.newEvents.map(\.kind), [.modified])
        XCTAssertEqual(changed.newEvents.first?.changedDocuments, [.skillManifest])
        state = changed.state

        let duplicate = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)))
        XCTAssertTrue(duplicate.newEvents.isEmpty)

        let reverted = detector.apply(duplicate.state, batch: batch([
            observation("skill:a", signature: "a", at: base.addingTimeInterval(3))
        ], at: base.addingTimeInterval(3)))
        XCTAssertEqual(reverted.newEvents.map(\.kind), [.modified])
        XCTAssertEqual(reverted.state.events.map(\.kind), [.modified, .modified])
    }

    func testAgentDocumentDigestsReportOnlyTheDocumentThatActuallyChanged() {
        let detector = CapabilityChangeDetector()
        func agent(_ aggregate: Character, config: Character, brief: Character, at date: Date) -> CapabilityHistoryObservation {
            CapabilityHistoryObservation(
                resourceID: "agent:global:synthetic",
                sourceRootID: "global-agents",
                name: "Synthetic Agent",
                kind: .agent,
                scope: .global,
                projectID: nil,
                documents: [.agentConfiguration, .agentBrief],
                signature: String(repeating: aggregate, count: 64),
                documentSignatures: [
                    .init(document: .agentConfiguration, sha256: String(repeating: config, count: 64)),
                    .init(document: .agentBrief, sha256: String(repeating: brief, count: 64)),
                ],
                observedAt: date
            )
        }
        let scope = CapabilityHistoryScanScope(
            rootID: "global-agents", scope: .global, rootKind: .agents, coverage: .complete
        )
        let initial = detector.apply(.empty(epoch: 1), batch: .init(
            observedAt: base,
            scopes: [scope],
            observations: [agent("a", config: "a", brief: "a", at: base)]
        ))
        let changed = detector.apply(initial.state, batch: .init(
            observedAt: base.addingTimeInterval(1),
            scopes: [scope],
            observations: [agent("b", config: "b", brief: "a", at: base.addingTimeInterval(1))]
        ))

        XCTAssertEqual(changed.newEvents.first?.changedDocuments, [.agentConfiguration])
        XCTAssertEqual(changed.newEvents.first?.changedDocumentsAreExact, true)
    }

    func testAggregateOnlyChangeDoesNotClaimEveryTrackedDocumentChanged() {
        let detector = CapabilityChangeDetector()
        let scope = CapabilityHistoryScanScope(
            rootID: "global-agents", scope: .global, rootKind: .agents, coverage: .complete
        )
        func aggregateOnly(_ signature: Character, at date: Date) -> CapabilityHistoryObservation {
            CapabilityHistoryObservation(
                resourceID: "agent:global:legacy",
                sourceRootID: "global-agents",
                name: "Legacy Agent",
                kind: .agent,
                scope: .global,
                projectID: nil,
                documents: [.agentConfiguration, .agentBrief],
                signature: String(repeating: signature, count: 64),
                observedAt: date
            )
        }
        let initial = detector.apply(.empty(epoch: 1), batch: .init(
            observedAt: base, scopes: [scope], observations: [aggregateOnly("a", at: base)]
        ))
        let changed = detector.apply(initial.state, batch: .init(
            observedAt: base.addingTimeInterval(1),
            scopes: [scope],
            observations: [aggregateOnly("b", at: base.addingTimeInterval(1))]
        ))

        XCTAssertEqual(changed.newEvents.first?.kind, .modified)
        XCTAssertTrue(changed.newEvents.first?.changedDocuments.isEmpty == true)
        XCTAssertEqual(changed.newEvents.first?.changedDocumentsAreExact, false)
    }

    func testMissingRequiresTwoConsecutiveCompleteScansAndInterruptionRestartsConfirmation() {
        let detector = CapabilityChangeDetector()
        var state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state

        let firstMissing = detector.apply(state, batch: batch([], at: base.addingTimeInterval(1)))
        XCTAssertTrue(firstMissing.newEvents.isEmpty)
        XCTAssertEqual(firstMissing.state.pendingMissing.map(\.resourceID), ["skill:a"])

        let interrupted = detector.apply(firstMissing.state, batch: batch(
            [], coverage: .unavailable, at: base.addingTimeInterval(2)
        ))
        XCTAssertTrue(interrupted.state.pendingMissing.isEmpty)
        XCTAssertTrue(interrupted.issueCodes.contains(.interruptedMissingConfirmation))

        let restarted = detector.apply(interrupted.state, batch: batch([], at: base.addingTimeInterval(3)))
        XCTAssertTrue(restarted.newEvents.isEmpty)
        let confirmed = detector.apply(restarted.state, batch: batch([], at: base.addingTimeInterval(4)))
        XCTAssertEqual(confirmed.newEvents.map(\.kind), [.missing])
        XCTAssertEqual(confirmed.state.baselines.first?.presence, .missing)
    }

    func testOmittedScopeInterruptsMissingConfirmationWithoutInferringAbsence() {
        let detector = CapabilityChangeDetector()
        var state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(1))).state

        let omitted = detector.apply(state, batch: CapabilityHistoryScanBatch(
            observedAt: base.addingTimeInterval(2), scopes: [], observations: []
        ))
        XCTAssertTrue(omitted.state.pendingMissing.isEmpty)
        XCTAssertTrue(omitted.newEvents.isEmpty)
    }

    func testPartialScanCanCommitPositiveChangeButNeverMissing() {
        let detector = CapabilityChangeDetector()
        var state = detector.apply(.empty(epoch: 1), batch: batch([
            observation("skill:a"), observation("skill:b")
        ])).state

        let partial = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(1))
        ], coverage: .partial, at: base.addingTimeInterval(1)))
        XCTAssertEqual(partial.newEvents.map(\.kind), [.modified])
        XCTAssertFalse(partial.state.pendingMissing.contains { $0.resourceID == "skill:b" })
        state = partial.state

        let firstComplete = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(2))
        ], at: base.addingTimeInterval(2)))
        XCTAssertTrue(firstComplete.newEvents.isEmpty)
        XCTAssertEqual(firstComplete.state.pendingMissing.map(\.resourceID), ["skill:b"])
    }

    func testReappearedIsSingleEventAndCarriesChangedDocuments() {
        let detector = CapabilityChangeDetector()
        var state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(1))).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(2))).state

        let result = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(3))
        ], at: base.addingTimeInterval(3)))
        XCTAssertEqual(result.newEvents.count, 1)
        XCTAssertEqual(result.newEvents.first?.kind, .reappeared)
        XCTAssertEqual(result.newEvents.first?.changedDocuments, [.skillManifest])
        XCTAssertEqual(result.state.baselines.first?.presence, .present)
    }

    func testSignatureAlgorithmChangeRebaselinesWithoutContentEvent() {
        let detector = CapabilityChangeDetector()
        let first = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")]))
        let upgraded = detector.apply(first.state, batch: batch([
            observation("skill:a", signature: "b", algorithm: "sha256-v2", at: base.addingTimeInterval(1))
        ], at: base.addingTimeInterval(1)))

        XCTAssertTrue(upgraded.newEvents.isEmpty)
        XCTAssertTrue(upgraded.issueCodes.contains(.signatureAlgorithmChanged))
        XCTAssertEqual(upgraded.state.baselines.first?.signatureAlgorithm, "sha256-v2")
    }

    func testClockRollbackKeepsSequenceMonotonicAndNewEventInsideRetention() {
        let detector = CapabilityChangeDetector()
        let first = detector.apply(.empty(epoch: 4), batch: batch([observation("skill:a")]))
        let forward = detector.apply(first.state, batch: batch([
            observation("skill:a", signature: "b", at: base.addingTimeInterval(100))
        ], at: base.addingTimeInterval(100)))
        let rollback = detector.apply(forward.state, batch: batch([
            observation("skill:a", signature: "c", at: base.addingTimeInterval(50))
        ], at: base.addingTimeInterval(50)))

        XCTAssertEqual(rollback.state.events.map(\.sequence), [1, 2])
        XCTAssertEqual(rollback.state.events.last?.observedAt, base.addingTimeInterval(50))
        XCTAssertTrue(rollback.issueCodes.contains(.clockRollback))
    }

    func testRetentionCapsPerResourceAndGlobalWithoutDroppingCurrentBaseline() {
        let policy = CapabilityHistoryRetentionPolicy(duration: 10_000, maximumEventsPerResource: 2, maximumEvents: 3)
        let detector = CapabilityChangeDetector(retentionPolicy: policy)
        var state = detector.apply(.empty(epoch: 1), batch: batch([
            observation("skill:a"), observation("skill:b")
        ])).state

        for index in 1...4 {
            let character = Character(String(UnicodeScalar(UInt8(97 + index))))
            state = detector.apply(state, batch: batch([
                observation("skill:a", signature: character, at: base.addingTimeInterval(Double(index))),
                observation("skill:b", signature: character, at: base.addingTimeInterval(Double(index))),
            ], at: base.addingTimeInterval(Double(index)))).state
        }

        XCTAssertEqual(state.events.count, 3)
        XCTAssertLessThanOrEqual(state.events.filter { $0.resourceID == "skill:a" }.count, 2)
        XCTAssertLessThanOrEqual(state.events.filter { $0.resourceID == "skill:b" }.count, 2)
        XCTAssertEqual(state.baselines.count, 2)
        XCTAssertNotNil(state.truncatedBefore)
    }

    func testExpiredMissingTombstoneMakesLaterObservationAdded() {
        let detector = CapabilityChangeDetector(retentionPolicy: .init(duration: 10, maximumEventsPerResource: 100, maximumEvents: 20_000))
        var state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(1))).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(2))).state
        state = detector.apply(state, batch: batch([], at: base.addingTimeInterval(20))).state
        XCTAssertFalse(state.baselines.contains { $0.resourceID == "skill:a" })

        let readded = detector.apply(state, batch: batch([
            observation("skill:a", at: base.addingTimeInterval(21))
        ], at: base.addingTimeInterval(21)))
        XCTAssertEqual(readded.newEvents.map(\.kind), [.added])
    }

    func testCacheFallbackNeverMutatesState() {
        let detector = CapabilityChangeDetector()
        let state = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state
        let cached = detector.apply(state, batch: batch([
            observation("skill:a", signature: "b")
        ], source: .cacheFallback))

        XCTAssertEqual(cached.state, state)
        XCTAssertFalse(cached.didChange)
        XCTAssertEqual(cached.issueCodes, [.cacheBatchIgnored])
    }

    func testPartialFirstObservationDoesNotBecomeAddedWhenScopeFirstCompletes() {
        let detector = CapabilityChangeDetector()
        let partial = detector.apply(.empty(epoch: 1), batch: batch([
            observation("skill:a")
        ], coverage: .partial))
        XCTAssertTrue(partial.newEvents.isEmpty)
        XCTAssertTrue(partial.state.scopes.isEmpty)

        let complete = detector.apply(partial.state, batch: batch([
            observation("skill:a", at: base.addingTimeInterval(1)),
            observation("skill:b", at: base.addingTimeInterval(1)),
        ], at: base.addingTimeInterval(1)))
        XCTAssertTrue(complete.newEvents.isEmpty)
        XCTAssertEqual(Set(complete.state.baselines.map(\.resourceID)), ["skill:a", "skill:b"])
    }

    func testPartialSeedThenFirstCompleteAbsenceStartsPendingConfirmation() {
        let detector = CapabilityChangeDetector()
        let partial = detector.apply(.empty(epoch: 1), batch: batch([
            observation("skill:a")
        ], coverage: .partial))

        let firstComplete = detector.apply(partial.state, batch: batch(
            [], at: base.addingTimeInterval(1)
        ))
        XCTAssertEqual(firstComplete.state.pendingMissing.map(\.resourceID), ["skill:a"])
        XCTAssertTrue(firstComplete.newEvents.isEmpty)

        let confirmed = detector.apply(firstComplete.state, batch: batch(
            [], at: base.addingTimeInterval(2)
        ))
        XCTAssertEqual(confirmed.newEvents.map(\.kind), [.missing])
    }

    func testEmptyAndAllInvalidBatchesPersistUnavailableCoverageAndIssue() {
        let detector = CapabilityChangeDetector()
        let empty = detector.apply(.empty(epoch: 1), batch: .init(
            observedAt: base,
            scopes: [],
            observations: []
        ))
        XCTAssertTrue(empty.didChange)
        XCTAssertEqual(empty.state.latestScanCoverage, .unavailable)

        let invalid = detector.apply(empty.state, batch: .init(
            observedAt: base.addingTimeInterval(1),
            scopes: [.init(rootID: "../private", scope: .global, rootKind: .skills, coverage: .complete)],
            observations: []
        ))
        XCTAssertTrue(invalid.didChange)
        XCTAssertEqual(invalid.state.latestScanCoverage, .unavailable)
        XCTAssertTrue(invalid.state.issueCodes.contains(.invalidObservation))
    }

    func testMixedUsableAndUnavailableScopesPersistPartialCoverage() {
        let detector = CapabilityChangeDetector()
        let result = detector.apply(.empty(epoch: 19), batch: .init(
            observedAt: base,
            scopes: [
                .init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: .complete),
                .init(rootID: "project-missing", scope: .project, rootKind: .projects, coverage: .unavailable),
            ],
            observations: []
        ))

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.state.latestScanCoverage, .partial)
        XCTAssertTrue(result.state.scopes.contains { $0.rootID == "global-skills" })
        XCTAssertTrue(result.state.scopes.contains { $0.rootID == "project-missing" } == false)
        XCTAssertTrue(result.state.baselines.isEmpty)
        XCTAssertTrue(result.newEvents.isEmpty)
    }

    func testPartialAndUnavailableScopesRemainPartialAndNeverConfirmMissing() {
        let detector = CapabilityChangeDetector()
        let initial = detector.apply(.empty(epoch: 20), batch: batch([observation("skill:a")])).state
        let mixedBatch = CapabilityHistoryScanBatch(
            observedAt: base.addingTimeInterval(1),
            scopes: [
                .init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: .partial),
                .init(rootID: "project-missing", scope: .project, rootKind: .projects, coverage: .unavailable),
            ],
            observations: []
        )

        let first = detector.apply(initial, batch: mixedBatch)
        let second = detector.apply(first.state, batch: mixedBatch)

        XCTAssertEqual(first.state.latestScanCoverage, .partial)
        XCTAssertEqual(second.state.latestScanCoverage, .partial)
        XCTAssertTrue(first.state.pendingMissing.isEmpty)
        XCTAssertTrue(second.state.pendingMissing.isEmpty)
        XCTAssertTrue(first.newEvents.isEmpty)
        XCTAssertTrue(second.newEvents.isEmpty)
    }

    func testAllUnavailableScopesRemainUnavailableAndNeverConfirmMissing() {
        let detector = CapabilityChangeDetector()
        let initial = detector.apply(.empty(epoch: 21), batch: batch([observation("skill:a")])).state
        let unavailableBatch = CapabilityHistoryScanBatch(
            observedAt: base.addingTimeInterval(1),
            scopes: [
                .init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: .unavailable),
                .init(rootID: "project-missing", scope: .project, rootKind: .projects, coverage: .unavailable),
            ],
            observations: []
        )

        let first = detector.apply(initial, batch: unavailableBatch)
        let second = detector.apply(first.state, batch: unavailableBatch)

        XCTAssertEqual(first.state.latestScanCoverage, .unavailable)
        XCTAssertEqual(second.state.latestScanCoverage, .unavailable)
        XCTAssertTrue(first.state.pendingMissing.isEmpty)
        XCTAssertTrue(second.state.pendingMissing.isEmpty)
        XCTAssertTrue(first.newEvents.isEmpty)
        XCTAssertTrue(second.newEvents.isEmpty)
    }

    func testUnstableCoverageRemainsDominantAcrossSources() {
        let detector = CapabilityChangeDetector()
        let result = detector.apply(.empty(epoch: 22), batch: .init(
            observedAt: base,
            scopes: [
                .init(rootID: "global-skills", scope: .global, rootKind: .skills, coverage: .unstable),
                .init(rootID: "project-missing", scope: .project, rootKind: .projects, coverage: .unavailable),
                .init(rootID: "global-agents", scope: .global, rootKind: .agents, coverage: .complete),
            ],
            observations: []
        ))

        XCTAssertEqual(result.state.latestScanCoverage, .unstable)
        XCTAssertTrue(result.newEvents.isEmpty)
    }

    func testPathAndURLLikeIdentifiersAreRejected() {
        let detector = CapabilityChangeDetector()
        for unsafeID in ["/etc/private", "../private", #"folder\\private"#, "file:private"] {
            let unsafeResource = detector.apply(.empty(epoch: 1), batch: batch([
                observation(unsafeID)
            ]))
            XCTAssertTrue(unsafeResource.state.baselines.isEmpty, unsafeID)
            XCTAssertTrue(unsafeResource.state.issueCodes.contains(.invalidObservation), unsafeID)

            let unsafeRoot = detector.apply(.empty(epoch: 1), batch: batch(
                [observation("skill:safe", root: unsafeID)],
                root: unsafeID
            ))
            XCTAssertTrue(unsafeRoot.state.scopes.isEmpty, unsafeID)
            XCTAssertTrue(unsafeRoot.state.baselines.isEmpty, unsafeID)
            XCTAssertTrue(unsafeRoot.state.issueCodes.contains(.invalidObservation), unsafeID)

            let projectObservation = CapabilityHistoryObservation(
                resourceID: "skill:project:safe",
                sourceRootID: "project-skills",
                name: "Project skill",
                kind: .skill,
                scope: .project,
                projectID: unsafeID,
                documents: [.skillManifest],
                signature: String(repeating: "a", count: 64),
                documentSignatures: [.init(
                    document: .skillManifest,
                    sha256: String(repeating: "a", count: 64)
                )],
                observedAt: base
            )
            let unsafeProject = detector.apply(.empty(epoch: 1), batch: .init(
                observedAt: base,
                scopes: [.init(
                    rootID: "project-skills",
                    scope: .project,
                    rootKind: .skills,
                    coverage: .complete
                )],
                observations: [projectObservation]
            ))
            XCTAssertTrue(unsafeProject.state.baselines.isEmpty, unsafeID)
            XCTAssertTrue(unsafeProject.state.issueCodes.contains(.invalidObservation), unsafeID)
        }
    }

    func testMalformedDuplicateStateAndMaxCountersFailClosedWithoutTrapping() {
        let detector = CapabilityChangeDetector()
        let valid = detector.apply(.empty(epoch: 1), batch: batch([observation("skill:a")])).state
        let duplicate = CapabilityHistoryStateV1(
            epoch: valid.epoch,
            revision: valid.revision,
            nextSequence: valid.nextSequence,
            retentionAnchorAt: valid.retentionAnchorAt,
            truncatedBefore: valid.truncatedBefore,
            latestScanCoverage: valid.latestScanCoverage,
            scopes: valid.scopes + valid.scopes,
            baselines: valid.baselines + valid.baselines,
            pendingMissing: valid.pendingMissing,
            events: valid.events,
            issueCodes: valid.issueCodes
        )
        let duplicateResult = detector.apply(duplicate, batch: batch([]))
        XCTAssertFalse(duplicateResult.didChange)
        XCTAssertEqual(duplicateResult.issueCodes, [.invalidObservation])

        let maxed = CapabilityHistoryStateV1(
            epoch: UInt64.max,
            revision: Int64.max,
            nextSequence: Int64.max
        )
        let maxedResult = detector.apply(maxed, batch: batch([observation("skill:a")]))
        XCTAssertFalse(maxedResult.didChange)
        XCTAssertEqual(maxedResult.issueCodes, [.invalidObservation])

        let oneBeforeMax = CapabilityHistoryStateV1(
            epoch: 1,
            revision: Int64.max - 1,
            nextSequence: Int64.max - 1
        )
        let oneBeforeMaxResult = detector.apply(oneBeforeMax, batch: batch([observation("skill:a")]))
        XCTAssertFalse(oneBeforeMaxResult.didChange)
        XCTAssertEqual(oneBeforeMaxResult.issueCodes, [.invalidObservation])
    }
}
