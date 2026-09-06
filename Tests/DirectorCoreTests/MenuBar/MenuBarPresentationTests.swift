import Foundation
import XCTest
@testable import DirectorCore

final class MenuBarPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testFreshSnapshotProducesPrivacySafeAvailablePresentation() throws {
        let snapshot = try usage(remainingPercent: 72.4, resetOffset: 7_500, credits: 2)
        let presentation = MenuBarPresentation(snapshot: snapshot, freshness: .fresh, now: now)

        XCTAssertEqual(presentation.state, .available)
        XCTAssertEqual(presentation.shortStatus, "72%")
        XCTAssertEqual(presentation.primaryValue, "72%")
        XCTAssertEqual(try XCTUnwrap(presentation.weeklyRemainingPercent), 72.4, accuracy: 0.001)
        XCTAssertEqual(presentation.resetCreditCount, 2)
        XCTAssertEqual(presentation.resetDisplay, .countdown(seconds: 7_500))
        XCTAssertTrue(presentation.canRefresh)
        XCTAssertTrue(presentation.canOpenMainWindow)
        XCTAssertFalse(presentation.usesCachedValue)
    }

    func testMissingAndExpiredSnapshotNeverMasqueradeAsZero() throws {
        let missing = MenuBarPresentation(snapshot: nil, freshness: .unavailable, now: now)
        let expired = MenuBarPresentation(
            snapshot: try usage(remainingPercent: 81, resetOffset: 0),
            freshness: .fresh,
            now: now
        )

        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missing.primaryValue, "—")
        XCTAssertNil(missing.weeklyRemainingPercent)
        XCTAssertEqual(missing.resetDisplay, .unavailable)

        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.primaryValue, "—")
        XCTAssertNil(expired.weeklyRemainingPercent)
        XCTAssertEqual(expired.resetDisplay, .elapsed)
    }

    func testStaleRefreshingAndFailedStatesRemainDistinct() throws {
        let snapshot = try usage(remainingPercent: 64, resetOffset: 3_600)
        let stale = MenuBarPresentation(snapshot: snapshot, freshness: .stale, now: now)
        let refreshing = MenuBarPresentation(snapshot: snapshot, freshness: .fresh, activity: .refreshing, now: now)
        let failed = MenuBarPresentation(snapshot: snapshot, freshness: .fresh, activity: .failed, now: now)

        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(refreshing.state, .refreshing)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(stale.primaryValue, "64%")
        XCTAssertEqual(refreshing.primaryValue, "64%")
        XCTAssertEqual(failed.primaryValue, "64%")
        XCTAssertTrue(stale.usesCachedValue)
        XCTAssertTrue(refreshing.usesCachedValue)
        XCTAssertTrue(failed.usesCachedValue)
        XCTAssertTrue(stale.canRefresh)
        XCTAssertFalse(refreshing.canRefresh)
        XCTAssertTrue(failed.canRefresh)
    }

    func testFailedStateWithoutSnapshotDoesNotClaimCachedData() {
        let failed = MenuBarPresentation(
            snapshot: nil,
            freshness: .unavailable,
            activity: .failed,
            now: now
        )

        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.primaryValue, "—")
        XCTAssertFalse(failed.usesCachedValue)
    }

    func testSnapshotWithNoWeeklyValueStaysUnavailableButRetainsKnownCredits() throws {
        let snapshot = try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: nil,
            weeklyResetsAt: nil,
            resetCreditCount: 0,
            capturedAt: now
        )
        let presentation = MenuBarPresentation(snapshot: snapshot, freshness: .fresh, now: now)

        XCTAssertEqual(presentation.state, .missing)
        XCTAssertEqual(presentation.primaryValue, "—")
        XCTAssertNil(presentation.weeklyRemainingPercent)
        XCTAssertEqual(presentation.resetCreditCount, 0)
        XCTAssertEqual(presentation.resetDisplay, .unavailable)
    }

    func testPreferencesDefaultEnabledAndPersistOnlyDedicatedKey() throws {
        let suiteName = "codex-director-menu-bar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let legacyKey = "com.peiweitang.CodexDirector.menuBar.quotaSource"
        defaults.set("legacy", forKey: legacyKey)

        let first = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(first.snapshot(), .init(isEnabled: true))
        XCTAssertNil(defaults.object(forKey: legacyKey))

        first.setEnabled(false)
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).snapshot(), .init(isEnabled: false))
        first.setEnabled(true)
        XCTAssertEqual(MenuBarPreferences(defaults: defaults).snapshot(), .init(isEnabled: true))
        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(domain.keys), [MenuBarPreferences.enabledKey])
    }

    func testInvalidStoredPreferenceFallsBackToEnabled() throws {
        let suiteName = "codex-director-menu-bar-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("not-a-boolean", forKey: MenuBarPreferences.enabledKey)

        XCTAssertTrue(MenuBarPreferences(defaults: defaults).snapshot().isEnabled)
    }

    func testMemoryPreferencesAreIsolatedAndInjectedWritesOnlyEnabled() {
        let first = MenuBarPreferences(memoryEnabled: true)
        let second = MenuBarPreferences(memoryEnabled: false)
        XCTAssertEqual(first.snapshot(), .init(isEnabled: true))
        XCTAssertEqual(second.snapshot(), .init(isEnabled: false))

        var stored: Bool?
        let injected = MenuBarPreferences(readEnabled: { stored }, writeEnabled: { stored = $0 })
        XCTAssertTrue(injected.snapshot().isEnabled)
        injected.setEnabled(true)
        XCTAssertEqual(stored, true)
        XCTAssertTrue(injected.snapshot().isEnabled)
    }


    func testSnapshotRejectsUnsafeValues() {
        XCTAssertThrowsError(try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: 101,
            weeklyResetsAt: now,
            resetCreditCount: 0,
            capturedAt: now
        ))
        XCTAssertThrowsError(try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: 50,
            weeklyResetsAt: now,
            resetCreditCount: -1,
            capturedAt: now
        ))
    }

    func testCodexSnapshotEncodingDoesNotContainAccountOrModelIdentifiers() throws {
        let snapshot = try usage(remainingPercent: 50, resetOffset: 100)
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.localizedCaseInsensitiveContains("accountId"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("gpt-5.3"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("codex"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    }

    private func usage(remainingPercent: Double, resetOffset: TimeInterval, credits: Int? = nil) throws -> CodexAccountUsageSnapshot {
        try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: remainingPercent,
            weeklyResetsAt: now.addingTimeInterval(resetOffset),
            resetCreditCount: credits,
            capturedAt: now.addingTimeInterval(-30)
        )
    }
}
