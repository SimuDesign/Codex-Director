import XCTest
@testable import DirectorCore

final class TokenUsageParserTests: XCTestCase {

    private let sessionID = "session:token"

    // MARK: - Helpers

    private func envelope(payload: [String: Any], timestamp: String, line: Int = 1, type: String = "event_msg") -> RolloutEnvelope {
        let json: [String: Any] = ["type": type, "timestamp": timestamp, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!
        let result = RolloutEventDecoder().decode(JSONLLine(byteOffset: 0, lineNumber: line, text: text))
        guard case .envelope(let envelope)? = result.line else {
            fatalError("fixture did not decode")
        }
        return envelope
    }

    private func tokenCount(
        info: [String: Any],
        rateLimits: [String: Any]? = nil,
        timestamp: String = "2026-08-15T04:12:05.950Z",
        line: Int = 1
    ) -> RolloutEnvelope {
        var payload: [String: Any] = ["type": "token_count", "info": info]
        if let rateLimits {
            payload["rate_limits"] = rateLimits
        }
        return envelope(payload: payload, timestamp: timestamp, line: line)
    }

    private func turnContext(model: Any, timestamp: String = "2026-08-15T04:12:04.000Z", line: Int = 1) -> RolloutEnvelope {
        envelope(payload: ["turn_id": "turn-\(line)", "model": model], timestamp: timestamp, line: line, type: "turn_context")
    }

    private func usage(
        input: Int = 10, cached: Int = 2, cacheWrite: Int = 1,
        output: Int = 5, reasoning: Int = 3, total: Int = 21
    ) -> [String: Any] {
        [
            "input_tokens": input, "cached_input_tokens": cached,
            "cache_write_input_tokens": cacheWrite, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": total,
        ]
    }

    private func window(minutes: Int, usedPercent: Double, resetsAt: Int? = nil) -> [String: Any] {
        var dict: [String: Any] = ["window_minutes": minutes, "used_percent": usedPercent]
        if let resetsAt {
            dict["resets_at"] = resetsAt
        }
        return dict
    }

    private func extract(_ envelopes: [RolloutEnvelope]) -> TokenUsageExtraction {
        TokenUsageParser().extract(sessionID: sessionID, envelopes: envelopes)
    }

    // MARK: - Token parsing

    func testParsesAllSixTokenFields() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage(input: 10, cached: 2, cacheWrite: 1, output: 5, reasoning: 3, total: 21)]),
        ])
        XCTAssertEqual(result.snapshots.count, 1)
        let snapshot = result.snapshots[0]
        XCTAssertEqual(snapshot.usage.inputTokens, 10)
        XCTAssertEqual(snapshot.usage.cachedInputTokens, 2)
        XCTAssertEqual(snapshot.usage.cacheWriteInputTokens, 1)
        XCTAssertEqual(snapshot.usage.outputTokens, 5)
        XCTAssertEqual(snapshot.usage.reasoningOutputTokens, 3)
        XCTAssertEqual(snapshot.usage.totalTokens, 21)
        XCTAssertEqual(snapshot.usage.coverage, .complete)
    }

    func testCodex53SparkAliasesShareCanonicalSnapshotIdentity() {
        let first = tokenCount(
            info: ["total_token_usage": usage(total: 100)],
            timestamp: "2026-08-15T04:12:05.000Z",
            line: 2
        )
        let second = tokenCount(
            info: ["total_token_usage": usage(total: 200)],
            timestamp: "2026-08-15T04:12:06.000Z",
            line: 4
        )
        let result = extract([
            turnContext(model: "gpt-5.3-codex-spark", line: 1), first,
            turnContext(model: "Codex 5.3 Spark", timestamp: "2026-08-15T04:12:05.500Z", line: 3), second,
        ])
        XCTAssertEqual(result.snapshots.map(\.modelID), [ModelIdentity.codex53SparkID, ModelIdentity.codex53SparkID])
        XCTAssertTrue(result.snapshots.allSatisfy { $0.modelName == "Codex 5.3 Spark" && $0.modelConfidence == .exact })
    }

    func testMissingModelContextRemainsUnknown() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage(total: 21)])
        ])
        XCTAssertNil(result.snapshots.first?.modelID)
        XCTAssertEqual(result.snapshots.first?.modelConfidence, .unknown)
    }

    func testMalformedModelContextDoesNotBecomeExact() {
        let result = extract([
            turnContext(model: NSNull(), line: 1),
            tokenCount(info: ["total_token_usage": usage(total: 21)], line: 2),
        ])
        XCTAssertEqual(result.snapshots.first?.modelConfidence, .unknown)
        XCTAssertTrue(result.issues.contains { $0.message.contains("malformed turn_context model") })
    }

    func testNewestCumulativeSnapshotIsSelectedNeverSummed() throws {
        let early = tokenCount(
            info: ["total_token_usage": usage(total: 100)], timestamp: "2026-08-15T04:12:05.950Z", line: 1)
        let middle = tokenCount(
            info: ["total_token_usage": usage(total: 250)], timestamp: "2026-08-15T04:12:10.000Z", line: 2)
        let latest = tokenCount(
            info: ["total_token_usage": usage(total: 400)], timestamp: "2026-08-15T04:12:15.000Z", line: 3)
        let result = extract([early, middle, latest])
        let newest = TokenUsageParser.newestCumulative(from: result.snapshots)
        XCTAssertEqual(newest?.usage.totalTokens, 400)
        XCTAssertNotEqual(newest?.usage.totalTokens, 750) // never summed
    }

    func testDecreasingCumulativeTotalMarksPartialCoverage() {
        let first = tokenCount(info: ["total_token_usage": usage(total: 400)], line: 1)
        let second = tokenCount(info: ["total_token_usage": usage(total: 300)], line: 2)
        let result = extract([first, second])
        XCTAssertEqual(result.snapshots.count, 2)
        XCTAssertEqual(result.snapshots[0].usage.coverage, .complete)
        XCTAssertEqual(result.snapshots[1].usage.coverage, .partial)
        XCTAssertTrue(result.issues.contains { $0.message.contains("decreasing cumulative total") })
    }

    func testMalformedUsageSkippedWithIssue() {
        let result = extract([
            tokenCount(info: ["total_token_usage": ["input_tokens": 1]]),
        ])
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.message.contains("malformed total_token_usage") })
    }

    func testNegativeUsageRejected() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage(total: -5)]),
        ])
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.message.contains("invalid token counts") })
    }

    func testLastTokenUsageIsNotRecordedAsTaskSnapshot() {
        let result = extract([
            tokenCount(info: [
                "last_token_usage": usage(total: 42),
                "total_token_usage": usage(total: 21),
            ]),
        ])
        XCTAssertEqual(result.snapshots.count, 1)
        XCTAssertEqual(result.snapshots[0].usage.totalTokens, 21)
    }

    // MARK: - Rate-limit windows

    func testWeeklyWindowInPrimaryOnly() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "limit_id": "weekly", "primary": window(minutes: 10_080, usedPercent: 50.0, resetsAt: 1787197042),
            ]),
        ])
        XCTAssertEqual(result.quotas.count, 1)
        let quota = result.quotas[0]
        XCTAssertTrue(quota.isWeeklyWindow)
        XCTAssertFalse(quota.isShortWindow)
        XCTAssertEqual(quota.usedPercent, 50.0)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 1787197042))
        XCTAssertEqual(quota.limitID, "weekly")
    }

    func testFiveHourPrimaryPlusWeeklySecondary() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "limit_id": "short",
                "primary": window(minutes: 300, usedPercent: 12.5),
                "secondary": window(minutes: 10_080, usedPercent: 47.0),
            ]),
        ])
        XCTAssertEqual(result.quotas.count, 2)
        let short = result.quotas.first { $0.isShortWindow }
        let weekly = result.quotas.first { $0.isWeeklyWindow }
        XCTAssertNotNil(short)
        XCTAssertNotNil(weekly)
        XCTAssertEqual(short?.usedPercent, 12.5)
        XCTAssertEqual(weekly?.usedPercent, 47.0)
    }

    func testQuotaSnapshotsPreserveLimitNameAndId() {
        let result = extract([
            tokenCount(
                info: ["total_token_usage": usage()],
                rateLimits: [
                    "limit_id": "codex_bengalfox",
                    "limit_name": "Codex Bengalfox",
                    "primary": window(minutes: 300, usedPercent: 12.5),
                ]),
        ])
        XCTAssertEqual(result.quotas.count, 1)
        XCTAssertEqual(result.quotas[0].limitID, "codex_bengalfox")
        XCTAssertEqual(result.quotas[0].limitName, "Codex Bengalfox")
    }

    func testQuotaSnapshotsKeepMultipleLimitIDsFromBatch() {
        let result = extract([
            tokenCount(
                info: ["total_token_usage": usage()],
                rateLimits: [
                    "limit_id": "codex",
                    "primary": window(minutes: 10_080, usedPercent: 50.0),
                ]),
            tokenCount(
                info: ["total_token_usage": usage()],
                rateLimits: [
                    "limit_id": "codex_bengalfox",
                    "primary": window(minutes: 10_080, usedPercent: 60.0),
                ]),
        ])
        let ids = Set(result.quotas.map(\.limitID))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("codex"))
        XCTAssertTrue(ids.contains("codex_bengalfox"))
    }

    func testWeeklyInSecondaryWithAbsentShortWindow() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "secondary": window(minutes: 10_080, usedPercent: 60.0),
            ]),
        ])
        XCTAssertEqual(result.quotas.count, 1)
        XCTAssertTrue(result.quotas[0].isWeeklyWindow)
    }

    func testNoWeeklyWindow() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "primary": window(minutes: 300, usedPercent: 5.0),
            ]),
        ])
        XCTAssertEqual(result.quotas.count, 1)
        XCTAssertFalse(result.quotas[0].isWeeklyWindow)
    }

    func testNullSecondaryWindowIsIgnored() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "primary": window(minutes: 10_080, usedPercent: 50.0),
                "secondary": NSNull(),
            ]),
        ])
        XCTAssertEqual(result.quotas.count, 1)
    }

    func testResetTimePassedIsExpired() {
        let now = Date(timeIntervalSince1970: 1787198000)
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "primary": window(minutes: 10_080, usedPercent: 50.0, resetsAt: 1787197042),
            ]),
        ])
        XCTAssertTrue(result.quotas[0].isExpired(at: now))
        XCTAssertFalse(result.quotas[0].isExpired(at: Date(timeIntervalSince1970: 1787197000)))
    }

    func testMalformedWindowRecordsIssue() {
        let result = extract([
            tokenCount(info: ["total_token_usage": usage()], rateLimits: [
                "primary": ["window_minutes": "weekly"],
            ]),
        ])
        XCTAssertTrue(result.quotas.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.message.contains("malformed primary rate-limit window") })
    }

    // MARK: - Integration fixture

    func testIntegrationFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing/token-counts.jsonl")
        guard let reader = JSONLIncrementalReader(url: url) else {
            return XCTFail("cannot open fixture")
        }
        let decoder = RolloutEventDecoder()
        var envelopes: [RolloutEnvelope] = []
        while let line = try reader.nextLine() {
            if case .envelope(let envelope)? = decoder.decode(line).line {
                envelopes.append(envelope)
            }
        }
        let result = TokenUsageParser().extract(sessionID: "syn-token-1", envelopes: envelopes)
        XCTAssertEqual(result.snapshots.count, 2)
        XCTAssertEqual(result.quotas.count, 2) // one token_count event has no rate_limits; both parsed windows: 2 primary windows
        XCTAssertEqual(TokenUsageParser.newestCumulative(from: result.snapshots)?.usage.totalTokens, 85283)
        XCTAssertTrue(result.quotas.allSatisfy { $0.isWeeklyWindow })
        XCTAssertEqual(result.quotas.first?.resetsAt, Date(timeIntervalSince1970: 1787197042))
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAccumulatorMatchesBatchExtraction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing/token-counts.jsonl")
        guard let reader = JSONLIncrementalReader(url: url) else {
            return XCTFail("cannot open fixture")
        }
        let decoder = RolloutEventDecoder()
        var envelopes: [RolloutEnvelope] = []
        while let line = try reader.nextLine() {
            if case .envelope(let envelope)? = decoder.decode(line).line {
                envelopes.append(envelope)
            }
        }
        let batch = TokenUsageParser().extract(sessionID: "syn-token-1", envelopes: envelopes)
        var accumulator = TokenUsageParser().makeAccumulator(sessionID: "syn-token-1")
        for envelope in envelopes { accumulator.process(envelope) }
        let streamed = accumulator.finish()
        XCTAssertEqual(streamed.snapshots.map(\.id), batch.snapshots.map(\.id))
        XCTAssertEqual(streamed.quotas.map(\.id), batch.quotas.map(\.id))
        XCTAssertEqual(streamed.issues.count, batch.issues.count)
    }

    func testQuotaSnapshotIdUsesLineAndSubsecondPrecision() throws {
        let result = extract([
            tokenCount(
                info: ["total_token_usage": usage()],
                rateLimits: [
                    "limit_id": "codex",
                    "primary": window(minutes: 300, usedPercent: 20.0),
                ],
                timestamp: "2026-08-15T04:12:05Z",
                line: 1
            ),
            tokenCount(
                info: ["total_token_usage": usage()],
                rateLimits: [
                    "limit_id": "codex",
                    "primary": window(minutes: 300, usedPercent: 20.0),
                ],
                timestamp: "2026-08-15T04:12:05Z",
                line: 2
            ),
        ])
        XCTAssertEqual(result.quotas.count, 2)
        XCTAssertNotEqual(result.quotas[0].id, result.quotas[1].id)
    }
}
