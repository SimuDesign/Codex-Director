import XCTest
@testable import DirectorCore

final class IntegrityRulesTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/resources", isDirectory: true)
    }

    private func context(
        resources: [CapabilityResource] = [],
        sessions: [TaskSummary] = [],
        invocations: [String: [InvocationEvent]] = [:],
        quotas: [QuotaSnapshot] = [],
        scanRoots: [ScanRoot] = [],
        now: Date = Date(timeIntervalSince1970: 1_700_100_000)
    ) -> ReviewContext {
        ReviewContext(
            resources: resources,
            sessions: sessions,
            invocationsBySession: invocations,
            quotaSnapshots: quotas,
            scanRoots: scanRoots,
            fileSystem: FileSystemClient(),
            now: now
        )
    }

    private func resource(_ id: String, rootID: String, relative: String?) -> CapabilityResource {
        CapabilityResource(
            id: id, name: id, kind: .skill, status: .unknown, scope: .global,
            projectID: nil, confidence: .exact, summary: nil,
            sourceRootID: rootID, relativeSourcePath: relative,
            sourcePathHash: nil, lastSeenAt: epoch
        )
    }

    private func session(_ id: String, coverage: CoverageState) -> TaskSummary {
        TaskSummary(id: id, projectID: nil, startedAt: epoch, endedAt: nil, status: .completed, coverage: coverage, parserVersion: "1.0.0", sourceFileID: "f-\(id)", title: nil)
    }

    private func call(_ id: String, sessionID: String, status: InvocationStatus) -> InvocationEvent {
        InvocationEvent(id: id, sessionID: sessionID, parentCallID: nil, ordinal: 0, timestamp: epoch, actorName: nil, resourceID: "tool:x", kind: .tool, status: status, durationMs: nil, confidence: .exact, errorCategory: nil)
    }

    private func quota(window: Int, capturedAt: Date, resetsAt: Date?) throws -> QuotaSnapshot {
        try QuotaSnapshot(id: "q-\(window)", capturedAt: capturedAt, windowMinutes: window, usedPercent: 50, resetsAt: resetsAt, limitID: "weekly", limitName: nil, confidence: .exact)
    }

    // MARK: - Rule 1: missing source

    func testMissingSourceRuleFiresWhenFileMissing() {
        let root = ScanRoot(id: "root", url: fixturesRoot.appendingPathComponent("does-not-exist"), scope: .global, kind: .skills)
        let ctx = context(resources: [resource("skill:x", rootID: "root", relative: "x/SKILL.md")], scanRoots: [root])
        let findings = IntegrityRules.evaluate(context: ctx, rules: [MissingSourceRule()])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].ruleID, "rule.missing-source")
        XCTAssertEqual(findings[0].resourceID, "skill:x")
        XCTAssertEqual(findings[0].confidence, .exact)
    }

    func testMissingSourceRuleSilentWhenSourcePresent() {
        let root = ScanRoot(id: "global-skills", url: fixturesRoot.appendingPathComponent("global-skills"), scope: .global, kind: .skills)
        let ctx = context(resources: [resource("skill:sample", rootID: "global-skills", relative: "sample-skill/SKILL.md")], scanRoots: [root])
        let findings = IntegrityRules.evaluate(context: ctx, rules: [MissingSourceRule()])
        XCTAssertTrue(findings.isEmpty)
    }

    func testMissingSourceRuleSkipsUnknownRoots() {
        let ctx = context(resources: [resource("skill:x", rootID: "unknown-root", relative: "x/SKILL.md")], scanRoots: [])
        let findings = IntegrityRules.evaluate(context: ctx, rules: [MissingSourceRule()])
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Rule 2: unmatched result

    func testUnmatchedResultRuleFiresForOpenCallsInCompleteCoverage() {
        let ctx = context(
            sessions: [session("s1", coverage: .complete)],
            invocations: ["s1": [call("c1", sessionID: "s1", status: .started)]]
        )
        let findings = IntegrityRules.evaluate(context: ctx, rules: [UnmatchedResultRule()])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].sessionID, "s1")
        XCTAssertEqual(findings[0].evidenceSummary.contains("started"), true)
    }

    func testUnmatchedResultRuleSilentForCompletedCalls() {
        let ctx = context(
            sessions: [session("s1", coverage: .complete)],
            invocations: ["s1": [call("c1", sessionID: "s1", status: .completed)]]
        )
        XCTAssertTrue(IntegrityRules.evaluate(context: ctx, rules: [UnmatchedResultRule()]).isEmpty)
    }

    func testUnmatchedResultRuleSilentWhenCoverageIsPartial() {
        // With partial coverage we cannot state the fact reliably.
        let ctx = context(
            sessions: [session("s1", coverage: .partial)],
            invocations: ["s1": [call("c1", sessionID: "s1", status: .unknown)]]
        )
        XCTAssertTrue(IntegrityRules.evaluate(context: ctx, rules: [UnmatchedResultRule()]).isEmpty)
    }

    // MARK: - Rule 3: parser coverage

    func testParserCoverageRuleFiresForPartialSessions() {
        let ctx = context(sessions: [session("s1", coverage: .partial), session("s2", coverage: .complete)])
        let findings = IntegrityRules.evaluate(context: ctx, rules: [ParserCoverageRule()])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].sessionID, "s1")
        XCTAssertEqual(findings[0].severity, .info)
    }

    // MARK: - Rule 4: stale quota

    func testStaleQuotaRuleFiresWhenExpired() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let stale = try quota(window: 10_080, capturedAt: epoch, resetsAt: epoch.addingTimeInterval(1000))
        let ctx = context(quotas: [stale], now: now)
        let findings = IntegrityRules.evaluate(context: ctx, rules: [StaleQuotaRule()])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .warning)
    }

    func testStaleQuotaRuleSilentWhenFresh() throws {
        let fresh = try quota(window: 10_080, capturedAt: epoch, resetsAt: epoch.addingTimeInterval(10_000_000))
        let ctx = context(quotas: [fresh], now: Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertTrue(IntegrityRules.evaluate(context: ctx, rules: [StaleQuotaRule()]).isEmpty)
    }

    func testStaleQuotaRuleSilentWithoutWeeklyWindow() throws {
        let onlyShort = try quota(window: 300, capturedAt: epoch, resetsAt: epoch.addingTimeInterval(1))
        let ctx = context(quotas: [onlyShort], now: Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertTrue(IntegrityRules.evaluate(context: ctx, rules: [StaleQuotaRule()]).isEmpty)
    }

    // MARK: - Rule 5: disabled

    func testReviewGateRuleIsDisabled() {
        let ctx = context(sessions: [session("s1", coverage: .complete)])
        XCTAssertTrue(DisabledReviewGateRule().evaluate(context: ctx).isEmpty)
    }

    // MARK: - Determinism

    func testFindingsAreDeterministic() {
        let root = ScanRoot(id: "root", url: fixturesRoot.appendingPathComponent("missing-root"), scope: .global, kind: .skills)
        let ctx = context(
            resources: [resource("skill:x", rootID: "root", relative: "x/SKILL.md")],
            sessions: [session("s1", coverage: .partial)],
            scanRoots: [root]
        )
        let first = IntegrityRules.evaluate(context: ctx)
        let second = IntegrityRules.evaluate(context: ctx)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.ruleID.hasPrefix("rule.") })
    }
}
