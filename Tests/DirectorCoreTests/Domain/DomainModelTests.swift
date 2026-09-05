import XCTest
@testable import DirectorCore

/// Contracts for the Domain value models.
final class DomainModelTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Codable round trips

    func testEvidenceConfidenceRoundTrip() throws {
        for value in EvidenceConfidence.allCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(EvidenceConfidence.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testInvocationEvaluationLabelRoundTrip() throws {
        for value in InvocationEvaluationLabel.allCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(InvocationEvaluationLabel.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func testInvocationEvaluationStorePersistsAndRemovesWithoutFreeText() throws {
        let suiteName = "codex-director-evaluation-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let evaluation = InvocationEvaluation(
            invocationID: "call:1",
            sessionID: "session:1",
            resourceID: "agent:writer",
            label: .effective,
            updatedAt: epoch
        )
        InvocationEvaluationStore(defaults: defaults).set(evaluation)

        let reconstructed = InvocationEvaluationStore(defaults: defaults)
        XCTAssertEqual(reconstructed.evaluation(for: evaluation.invocationID), evaluation)
        let stored = try XCTUnwrap(defaults.data(forKey: InvocationEvaluationStore.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let fields = try XCTUnwrap(json["call:1"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["invocationID", "sessionID", "resourceID", "label", "updatedAt"])
        XCTAssertNil(fields["note"])
        XCTAssertNil(fields["body"])
        XCTAssertNil(fields["path"])

        reconstructed.remove(for: evaluation.invocationID)
        XCTAssertNil(InvocationEvaluationStore(defaults: defaults).evaluation(for: evaluation.invocationID))
        XCTAssertNil(defaults.data(forKey: InvocationEvaluationStore.defaultsKey))
    }

    func testInvocationEvaluationStoreRejectsUnsafeStableIDsWithoutWriting() throws {
        let suiteName = "codex-director-evaluation-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = InvocationEvaluationStore(defaults: defaults)
        let invalidIDs = [
            "call:/tmp/secret", "session:Bearer sk-test-secret", "resource:password=secret",
            "free text", "", "call\\unsafe"
        ]
        for id in invalidIDs {
            let evaluation = InvocationEvaluation(
                invocationID: id, sessionID: "session:valid", resourceID: "agent:valid",
                label: .effective, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTAssertFalse(store.set(evaluation))
            XCTAssertNil(defaults.data(forKey: InvocationEvaluationStore.defaultsKey))
        }
    }

    func testInvocationEvaluationStoreFiltersLegacyMismatchedAndUnsafeValues() throws {
        let suiteName = "codex-director-evaluation-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let valid = InvocationEvaluation(invocationID: "call:valid", sessionID: "session:valid", resourceID: "agent:valid", label: .uncertain, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let mismatch = InvocationEvaluation(invocationID: "call:value", sessionID: "session:valid", resourceID: "agent:valid", label: .effective, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let unsafe = InvocationEvaluation(invocationID: "call:unsafe/path", sessionID: "session:valid", resourceID: "agent:valid", label: .effective, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode([
            "call:valid": valid,
            "call:key-mismatch": mismatch,
            "call:unsafe/path": unsafe
        ])
        defaults.set(data, forKey: InvocationEvaluationStore.defaultsKey)

        let values = InvocationEvaluationStore(defaults: defaults).all()
        XCTAssertEqual(Array(values.keys), ["call:valid"])
    }

    func testTokenUsageRoundTripPreservesAllFields() throws {
        let usage = try TokenUsage(
            inputTokens: 10, cachedInputTokens: 2, cacheWriteInputTokens: 1,
            outputTokens: 5, reasoningOutputTokens: 3, totalTokens: 21,
            coverage: .complete
        )
        let decoded = try roundTrip(usage)
        XCTAssertEqual(decoded, usage)
    }

    func testModelIdentityNormalizesCodex53SparkAliases() {
        let aliases = [
            "gpt-5.3-codex-spark",
            "Codex 5.3 Spark",
            "codex_5_3_spark",
        ]
        for alias in aliases {
            let identity = ModelIdentity.normalized(raw: alias)
            XCTAssertEqual(identity?.id, ModelIdentity.codex53SparkID)
            XCTAssertEqual(identity?.displayName, "Codex 5.3 Spark")
        }
    }

    func testModelIdentityRedactsPathLikeValues() {
        let identity = ModelIdentity.normalized(raw: "/Users/exampleuser/model.json")
        XCTAssertEqual(identity?.id, ModelIdentity.redactedID)
        XCTAssertEqual(identity?.displayName, ModelIdentity.redactedDisplayName)
    }

    func testTokenUsageSnapshotRoundTripPreservesModelAttribution() throws {
        let snapshot = TokenUsageSnapshot(
            id: "token:1",
            sessionID: "session:1",
            capturedAt: epoch,
            usage: try TokenUsage(
                inputTokens: 1, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                outputTokens: 2, reasoningOutputTokens: 0, totalTokens: 3,
                coverage: .complete
            ),
            modelID: ModelIdentity.codex53SparkID,
            modelName: ModelIdentity.codex53SparkDisplayName,
            modelConfidence: .exact
        )
        let decoded = try roundTrip(snapshot)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.modelIdentity?.displayName, "Codex 5.3 Spark")
    }

    func testCapabilityResourceRoundTripPreservesID() throws {
        let resource = sampleResource(kind: .skill, status: .success, confidence: .exact)
        let decoded = try roundTrip(resource)
        XCTAssertEqual(decoded, resource)
        XCTAssertEqual(decoded.id, resource.id)
    }

    func testQuotaSnapshotRoundTrip() throws {
        let quota = try sampleQuota(windowMinutes: 10_080, usedPercent: 42.5, resetsAt: epoch.addingTimeInterval(3600))
        let decoded = try roundTrip(quota)
        XCTAssertEqual(decoded, quota)
        XCTAssertEqual(decoded.id, quota.id)
    }

    func testInvocationEventRoundTrip() throws {
        let event = sampleInvocation()
        let decoded = try roundTrip(event)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.sessionID, event.sessionID)
    }

    func testTaskSummaryRoundTrip() throws {
        let task = sampleTask()
        let decoded = try roundTrip(task)
        XCTAssertEqual(decoded, task)
    }

    func testReviewFindingRoundTrip() throws {
        let finding = sampleFinding()
        let decoded = try roundTrip(finding)
        XCTAssertEqual(decoded, finding)
    }

    // MARK: - Stable IDs

    func testStableIdentityEqualsAcrossConstruction() {
        let a = sampleResource(kind: .tool, status: .running, confidence: .exact)
        let b = sampleResource(kind: .tool, status: .running, confidence: .exact)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }

    // MARK: - Quota semantics

    func testQuotaRemainingClampedToZeroThroughHundred() throws {
        XCTAssertEqual(try sampleQuota(windowMinutes: 300, usedPercent: 120).remainingPercent, 0)
        XCTAssertEqual(try sampleQuota(windowMinutes: 300, usedPercent: -10).remainingPercent, 100)
        XCTAssertEqual(try sampleQuota(windowMinutes: 300, usedPercent: 0).remainingPercent, 100)
        XCTAssertEqual(try sampleQuota(windowMinutes: 300, usedPercent: 100).remainingPercent, 0)
        XCTAssertEqual(try sampleQuota(windowMinutes: 300, usedPercent: 40).remainingPercent, 60)
    }

    func testQuotaWindowClassificationByMinutes() throws {
        let weekly = try sampleQuota(windowMinutes: 10_080)
        let short = try sampleQuota(windowMinutes: 300)
        XCTAssertTrue(weekly.isWeeklyWindow)
        XCTAssertFalse(weekly.isShortWindow)
        XCTAssertTrue(short.isShortWindow)
        XCTAssertFalse(short.isWeeklyWindow)
    }

    func testQuotaExpiryDoesNotAssumeReset() {
        let expired = try? sampleQuota(windowMinutes: 10_080, resetsAt: epoch.addingTimeInterval(-60))
        let open = try? sampleQuota(windowMinutes: 10_080, resetsAt: epoch.addingTimeInterval(60))
        let none = try? sampleQuota(windowMinutes: 10_080, resetsAt: nil)
        XCTAssertEqual(expired?.isExpired(at: epoch), true)
        XCTAssertEqual(open?.isExpired(at: epoch), false)
        XCTAssertEqual(none?.isExpired(at: epoch), false)
    }

    // MARK: - Resource kind vs runtime status

    func testResourceKindDoesNotChangeWhenStatusChanges() {
        let success = sampleResource(kind: .skill, status: .success, confidence: .exact)
        let failed = sampleResource(kind: .skill, status: .failure, confidence: .exact)
        XCTAssertEqual(success.kind, failed.kind)
        XCTAssertNotEqual(success.status, failed.status)
        XCTAssertNotEqual(success.status.rawValue, failed.status.rawValue)
    }

    // MARK: - Confidence stays distinct

    func testConfidenceCasesRemainDistinct() {
        let rawValues = EvidenceConfidence.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, EvidenceConfidence.allCases.count)

        let inferred = sampleResource(kind: .skill, status: .idle, confidence: .inferred)
        XCTAssertEqual(inferred.confidence, .inferred)
        XCTAssertNotEqual(inferred.confidence, .exact)
        XCTAssertNotEqual(inferred.confidence, .unknown)
    }

    func testInferredNeverUpgradesOnRoundTrip() throws {
        let inferred = sampleResource(kind: .workflow, status: .idle, confidence: .inferred)
        let decoded = try roundTrip(inferred)
        XCTAssertEqual(decoded.confidence, .inferred)
    }

    // MARK: - Validation at construction and decoding boundaries

    func testTokenUsageRejectsNegativeCounts() {
        XCTAssertThrowsError(try TokenUsage(
            inputTokens: -1, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, coverage: .complete
        ))
        XCTAssertThrowsError(try TokenUsage(
            inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: -5, reasoningOutputTokens: 0, totalTokens: 0, coverage: .complete
        ))
        XCTAssertThrowsError(try TokenUsage(
            inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: -1, coverage: .complete
        ))
    }

    func testTokenUsageDecodeRejectsNegativeTotal() {
        let json = #"{"inputTokens":0,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":-3,"coverage":"complete"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8)))
    }

    func testQuotaRejectsNonFinitePercentage() {
        XCTAssertThrowsError(try sampleQuota(windowMinutes: 300, usedPercent: .infinity))
        XCTAssertThrowsError(try sampleQuota(windowMinutes: 300, usedPercent: .nan))
    }

    func testQuotaRejectsNonPositiveWindow() {
        XCTAssertThrowsError(try sampleQuota(windowMinutes: 0))
        XCTAssertThrowsError(try sampleQuota(windowMinutes: -10_080))
    }

    // MARK: - Helpers

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sampleResource(
        kind: ResourceKind, status: RuntimeStatus, confidence: EvidenceConfidence
    ) -> CapabilityResource {
        CapabilityResource(
            id: "\(kind.rawValue):example-\(status.rawValue)",
            name: "example-\(kind.rawValue)",
            kind: kind,
            status: status,
            scope: .global,
            projectID: nil,
            confidence: confidence,
            summary: "Synthetic example",
            sourceRootID: "global-skills",
            relativeSourcePath: "example/SKILL.md",
            sourcePathHash: "abc123",
            lastSeenAt: epoch
        )
    }

    private func sampleQuota(
        windowMinutes: Int, usedPercent: Double = 40, resetsAt: Date? = nil
    ) throws -> QuotaSnapshot {
        try QuotaSnapshot(
            id: "quota:\(windowMinutes):\(usedPercent)",
            capturedAt: epoch,
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            limitID: "weekly",
            limitName: nil,
            confidence: .exact
        )
    }

    private func sampleInvocation() -> InvocationEvent {
        InvocationEvent(
            id: "call:1",
            sessionID: "session:1",
            parentCallID: nil,
            ordinal: 0,
            timestamp: epoch,
            actorName: "codex",
            resourceID: "tool:bash",
            kind: .tool,
            status: .completed,
            durationMs: 12,
            confidence: .exact,
            errorCategory: nil
        )
    }

    private func sampleTask() -> TaskSummary {
        TaskSummary(
            id: "session:1",
            projectID: nil,
            startedAt: epoch,
            endedAt: epoch.addingTimeInterval(120),
            status: .completed,
            coverage: .complete,
            parserVersion: "1.0",
            sourceFileID: "file:1",
            title: nil
        )
    }

    private func sampleFinding() -> ReviewFinding {
        ReviewFinding(
            id: "finding:1",
            ruleID: "rule.missing-source",
            resourceID: "skill:example",
            sessionID: nil,
            severity: .warning,
            confidence: .exact,
            summary: "Declared source is missing",
            evidenceSummary: "Source root does not contain the declared path",
            coverage: .complete,
            createdAt: epoch,
            remediationStatus: .open
        )
    }
}
