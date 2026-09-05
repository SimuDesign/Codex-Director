import XCTest
@testable import DirectorUI
import DirectorCore

/// Usage presentation contracts: allowance state, window selection, expired
/// handling, seven-day trend bucketing, and strict separation of account
/// allowance from locally indexed tokens.
@MainActor
final class UsageViewModelTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var now: Date { epoch.addingTimeInterval(10_000) }

    private func quota(
        window: Int,
        used: Double,
        capturedAt: Date,
        resetsAt: Date?,
        limitID: String = "limit",
        limitName: String? = nil
    ) throws -> QuotaSnapshot {
        try QuotaSnapshot(
            id: "q-\(window)-\(capturedAt.timeIntervalSince1970)",
            capturedAt: capturedAt,
            windowMinutes: window,
            usedPercent: used,
            resetsAt: resetsAt,
            limitID: limitID,
            limitName: limitName,
            confidence: .exact
        )
    }

    private func usage(total: Int64, input: Int64 = 0) throws -> TokenUsage {
        try TokenUsage(
            inputTokens: input, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total,
            coverage: .complete
        )
    }

    func testWeeklyWindowSelectedByCapturedAtRegardlessOfPosition() throws {
        let older = try quota(window: 300, used: 10, capturedAt: epoch, resetsAt: nil)
        let newerWeekly = try quota(window: 10_080, used: 40, capturedAt: epoch.addingTimeInterval(60), resetsAt: epoch.addingTimeInterval(86_400))
        let model = UsageViewModel(quotaSnapshots: [older, newerWeekly], tokenSnapshots: [], now: now)
        XCTAssertEqual(model.weeklyQuota?.windowMinutes, 10_080)
        XCTAssertEqual(model.weeklyQuota?.usedPercent, 40)
        XCTAssertEqual(model.shortWindowQuota?.windowMinutes, 300)
        XCTAssertEqual(model.weeklyState, .available(newerWeekly))
    }

    func testWeeklyInSecondaryWithAbsentShortWindow() throws {
        let weeklySecondary = try quota(window: 10_080, used: 55, capturedAt: epoch, resetsAt: epoch.addingTimeInterval(86_400))
        let model = UsageViewModel(quotaSnapshots: [weeklySecondary], tokenSnapshots: [], now: now)
        XCTAssertEqual(model.weeklyQuota, weeklySecondary)
        XCTAssertNil(model.shortWindowQuota)
        XCTAssertEqual(model.weeklyState, .available(weeklySecondary))
    }

    func testNoWeeklyWindowIsUnavailable() throws {
        let onlyShort = try quota(window: 300, used: 5, capturedAt: epoch, resetsAt: nil)
        let model = UsageViewModel(quotaSnapshots: [onlyShort], tokenSnapshots: [], now: now)
        XCTAssertEqual(model.weeklyState, .unavailable)
    }

    func testExpiredResetIsNotAssumedFull() throws {
        let expired = try quota(window: 10_080, used: 70, capturedAt: epoch, resetsAt: epoch.addingTimeInterval(5_000))
        let model = UsageViewModel(quotaSnapshots: [expired], tokenSnapshots: [], now: now)
        XCTAssertEqual(model.weeklyState, .expired(expired))
        // Presentation must show Unknown, never 100%.
        XCTAssertNotEqual(UsageViewModel.remainingPercent(expired), 100)
    }

    func testRemainingPercentClamped() throws {
        let over = try quota(window: 10_080, used: 120, capturedAt: epoch, resetsAt: nil)
        let model = UsageViewModel(quotaSnapshots: [over], tokenSnapshots: [], now: now)
        XCTAssertEqual(model.weeklyState, .available(over))
        XCTAssertEqual(UsageViewModel.remainingPercent(over), 0)
    }

    func testLocalTokensNeverSubtractedFromAllowance() throws {
        let weekly = try quota(window: 10_080, used: 40, capturedAt: epoch, resetsAt: nil)
        let tokenSnapshots = [
            TokenUsageSnapshot(id: "t1", sessionID: "s1", capturedAt: epoch, usage: try usage(total: 500_000)),
        ]
        let model = UsageViewModel(quotaSnapshots: [weekly], tokenSnapshots: tokenSnapshots, now: now)
        XCTAssertEqual(model.weeklyQuota?.usedPercent, 40)
        XCTAssertEqual(UsageViewModel.remainingPercent(weekly), 60)
        // The huge local total does not change the reported allowance.
        XCTAssertEqual(model.taskBreakdown.first?.usage.totalTokens, 500_000)
    }

    func testSevenDayTotalsBucketByDay() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        let snapshots = [
            TokenUsageSnapshot(id: "a", sessionID: "s1", capturedAt: today.addingTimeInterval(3600), usage: try usage(total: 100)),
            TokenUsageSnapshot(id: "b", sessionID: "s1", capturedAt: yesterday.addingTimeInterval(3600), usage: try usage(total: 200)),
            TokenUsageSnapshot(id: "c", sessionID: "s2", capturedAt: yesterday.addingTimeInterval(7200), usage: try usage(total: 50)),
            TokenUsageSnapshot(id: "d", sessionID: "s3", capturedAt: threeDaysAgo.addingTimeInterval(3600), usage: try usage(total: 10)),
            TokenUsageSnapshot(id: "e", sessionID: "s4", capturedAt: calendar.date(byAdding: .day, value: -8, to: today)!, usage: try usage(total: 999)),
        ]
        let model = UsageViewModel(quotaSnapshots: [], tokenSnapshots: snapshots, now: now)
        let totals = model.sevenDayTotals
        XCTAssertEqual(totals.count, 7)
        // Each session contributes only its newest cumulative snapshot,
        // bucketed by that snapshot's day.
        XCTAssertEqual(totals[6].day, today)
        XCTAssertEqual(totals[6].totalTokens, 100) // s1 newest snapshot is today's
        XCTAssertEqual(totals[5].day, yesterday)
        XCTAssertEqual(totals[5].totalTokens, 50) // s2 on yesterday
        XCTAssertEqual(totals[3].day, threeDaysAgo)
        XCTAssertEqual(totals[3].totalTokens, 10) // s3 three days ago
        // Out-of-range snapshot is excluded.
        XCTAssertFalse(totals.contains { $0.totalTokens == 999 })
    }

    func testTaskBreakdownUsesNewestCumulativePerSession() throws {
        let snapshots = [
            TokenUsageSnapshot(id: "t1", sessionID: "s1", capturedAt: epoch, usage: try usage(total: 100)),
            TokenUsageSnapshot(id: "t2", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60), usage: try usage(total: 250)),
        ]
        let model = UsageViewModel(quotaSnapshots: [], tokenSnapshots: snapshots, now: now)
        XCTAssertEqual(model.taskBreakdown.count, 1)
        XCTAssertEqual(model.taskBreakdown.first?.usage.totalTokens, 250)
        XCTAssertNotEqual(model.taskBreakdown.first?.usage.totalTokens, 350)
    }

    func testModelBreakdownCanonicalizesSparkAndDoesNotDoubleCountSnapshots() throws {
        let snapshots = [
            TokenUsageSnapshot(
                id: "s1-a", sessionID: "s1", capturedAt: epoch,
                usage: try usage(total: 100), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "s1-b", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60),
                usage: try usage(total: 250), modelID: "gpt-5-3-codex-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "s2-a", sessionID: "s2", capturedAt: epoch.addingTimeInterval(120),
                usage: try usage(total: 40), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
        ]

        let rows = UsageViewModel(quotaSnapshots: [], tokenSnapshots: snapshots, now: now).modelBreakdown

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.modelID, ModelIdentity.codex53SparkID)
        XCTAssertEqual(rows.first?.modelName, ModelIdentity.codex53SparkDisplayName)
        XCTAssertEqual(rows.first?.totalTokens, 290) // 250 + 40, not 100 + 250 + 40.
        XCTAssertEqual(rows.first?.taskCount, 2)
        XCTAssertEqual(rows.first?.attributionConfidence, .exact)
    }

    func testModelBreakdownSeparatesModelTransitionsByDelta() throws {
        let snapshots = [
            TokenUsageSnapshot(
                id: "a", sessionID: "s1", capturedAt: epoch,
                usage: try usage(total: 100), modelID: "codex-5.2", modelName: "codex-5.2",
                modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "b", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60),
                usage: try usage(total: 250), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "c", sessionID: "s1", capturedAt: epoch.addingTimeInterval(120),
                usage: try usage(total: 400), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
        ]

        let rows = UsageViewModel(quotaSnapshots: [], tokenSnapshots: snapshots, now: now).modelBreakdown

        XCTAssertEqual(rows.first(where: { $0.modelID == "codex-5.2" })?.totalTokens, 100)
        XCTAssertEqual(rows.first(where: { $0.modelID == ModelIdentity.codex53SparkID })?.totalTokens, 300)
    }

    func testModelBreakdownKeepsUnknownEvidenceUnknown() throws {
        let snapshot = TokenUsageSnapshot(
            id: "unknown", sessionID: "s1", capturedAt: epoch,
            usage: try usage(total: 42))

        let row = UsageViewModel(quotaSnapshots: [], tokenSnapshots: [snapshot], now: now).modelBreakdown.first

        XCTAssertEqual(row?.modelName, "Unknown model")
        XCTAssertNil(row?.modelID)
        XCTAssertEqual(row?.totalTokens, 42)
        XCTAssertEqual(row?.attributionConfidence, .unknown)
    }

    func testModelBreakdownDoesNotInflateAfterCumulativeReset() throws {
        let snapshots = [
            TokenUsageSnapshot(
                id: "a", sessionID: "s1", capturedAt: epoch,
                usage: try usage(total: 100), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "b", sessionID: "s1", capturedAt: epoch.addingTimeInterval(60),
                usage: try usage(total: 50), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
            TokenUsageSnapshot(
                id: "c", sessionID: "s1", capturedAt: epoch.addingTimeInterval(120),
                usage: try usage(total: 200), modelID: "codex-5.3-spark",
                modelName: "Codex 5.3 Spark", modelConfidence: .exact),
        ]

        let row = UsageViewModel(quotaSnapshots: [], tokenSnapshots: snapshots, now: now).modelBreakdown.first

        XCTAssertEqual(row?.totalTokens, 200)
        XCTAssertEqual(row?.coverage, .partial)
    }

    func testWeeklyNamespaceSelectionPrefersNonExpiredGroup() throws {
        let namespaceARecent = try quota(
            window: 10_080,
            used: 20,
            capturedAt: now.addingTimeInterval(-120),
            resetsAt: now.addingTimeInterval(-80),
            limitID: "codex"
        )
        let namespaceAFresh = try quota(
            window: 10_080,
            used: 40,
            capturedAt: now.addingTimeInterval(-20),
            resetsAt: now.addingTimeInterval(-10),
            limitID: "codex"
        )
        let namespaceBLatest = try quota(
            window: 10_080,
            used: 30,
            capturedAt: now.addingTimeInterval(-90),
            resetsAt: now.addingTimeInterval(2_000),
            limitID: "codex_bengalfox"
        )

        let model = UsageViewModel(
            quotaSnapshots: [namespaceARecent, namespaceBLatest, namespaceAFresh],
            tokenSnapshots: [],
            now: now
        )

        XCTAssertEqual(model.hasMultipleWeeklyNamespaces, true)
        XCTAssertEqual(UsageViewModel.quotaSourceIdentifier(for: model.weeklyQuota), "codex_bengalfox")
        XCTAssertEqual(model.weeklyQuota?.usedPercent, 30)
    }

    func testWeeklySelectionFallsBackToLatestNonExpiredNonZeroAcrossNamespaces() throws {
        let newestZeroBengalfox = try quota(
            window: 10_080,
            used: 0,
            capturedAt: now,
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex_bengalfox"
        )
        let olderCodex = try quota(
            window: 10_080,
            used: 53,
            capturedAt: now.addingTimeInterval(-1800),
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex"
        )
        let model = UsageViewModel(
            quotaSnapshots: [newestZeroBengalfox, olderCodex],
            tokenSnapshots: [],
            now: now
        )

        XCTAssertEqual(UsageViewModel.quotaSourceIdentifier(for: model.weeklyQuota), "codex")
        XCTAssertEqual(model.weeklyQuota?.usedPercent, 53)
    }

    func testWeeklyNamespaceSnapshotsExposeLatestPerNamespace() throws {
        let quota1 = try quota(
            window: 10_080,
            used: 10,
            capturedAt: now.addingTimeInterval(-100),
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex"
        )
        let quota2 = try quota(
            window: 10_080,
            used: 20,
            capturedAt: now,
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex_bengalfox"
        )
        let quota3 = try quota(
            window: 10_080,
            used: 30,
            capturedAt: now.addingTimeInterval(-50),
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex_bengalfox"
        )
        let model = UsageViewModel(
            quotaSnapshots: [quota1, quota2, quota3],
            tokenSnapshots: [],
            now: now
        )
        let summaries = model.weeklyNamespaceSummaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.compactMap { $0.limitID }.sorted(), ["codex", "codex_bengalfox"])
        XCTAssertEqual(summaries.first(where: { $0.limitID == "codex_bengalfox" })?.usedPercent, 20)
    }

    func testShortNamespaceSourceNameAndPreference() throws {
        let freshForCodex = try quota(
            window: 300,
            used: 20,
            capturedAt: now,
            resetsAt: now.addingTimeInterval(3_600),
            limitID: "codex",
            limitName: "Codex Production"
        )
        let olderForCodex = try quota(
            window: 300,
            used: 90,
            capturedAt: now.addingTimeInterval(-30),
            resetsAt: now.addingTimeInterval(-10),
            limitID: "codex"
        )
        let model = UsageViewModel(
            quotaSnapshots: [olderForCodex, freshForCodex],
            tokenSnapshots: [],
            now: now
        )

        XCTAssertEqual(model.shortWindowQuota?.usedPercent, 20)
        XCTAssertEqual(UsageViewModel.quotaSourceName(for: model.shortWindowQuota), "Codex Production")
        XCTAssertFalse(model.hasMultipleShortNamespaces)
    }
}
