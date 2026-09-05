import Foundation
import XCTest
@testable import DirectorCore

final class MenuBarPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testFreshQuotaProducesPrivacySafeAvailablePresentation() throws {
        let source = try quotaSource(remainingPercent: 72.4, resetOffset: 7_500)

        let presentation = MenuBarPresentation(
            source: source,
            freshness: .fresh,
            activity: .idle,
            now: now
        )

        XCTAssertEqual(presentation.state, .available)
        XCTAssertEqual(presentation.shortStatus, "72%")
        XCTAssertEqual(presentation.primaryValue, "72%")
        XCTAssertEqual(try XCTUnwrap(presentation.remainingPercent), 72.4, accuracy: 0.001)
        XCTAssertEqual(presentation.sourceID, "id:weekly")
        XCTAssertEqual(presentation.sourceName, "Weekly")
        XCTAssertEqual(presentation.resetDisplay, .countdown(seconds: 7_500))
        XCTAssertTrue(presentation.canRefresh)
        XCTAssertTrue(presentation.canOpenMainWindow)
        XCTAssertFalse(presentation.usesCachedValue)
    }

    func testMissingAndExpiredQuotaNeverMasqueradeAsZero() throws {
        let missing = MenuBarPresentation(
            source: QuotaOverviewSourceSnapshot(
                id: "id:weekly",
                name: "Weekly",
                current: nil,
                daily: []
            ),
            freshness: .fresh,
            now: now
        )
        let expired = MenuBarPresentation(
            source: try quotaSource(remainingPercent: 81, resetOffset: 0),
            freshness: .fresh,
            now: now
        )

        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missing.primaryValue, "--")
        XCTAssertNil(missing.remainingPercent)
        XCTAssertEqual(missing.resetDisplay, .unavailable)

        XCTAssertEqual(expired.state, .stale)
        XCTAssertEqual(expired.primaryValue, "--")
        XCTAssertNil(expired.remainingPercent)
        XCTAssertEqual(expired.resetDisplay, .elapsed)
    }

    func testStaleRefreshingAndFailedStatesRemainDistinct() throws {
        let source = try quotaSource(remainingPercent: 64, resetOffset: 3_600)

        let stale = MenuBarPresentation(source: source, freshness: .stale, now: now)
        let refreshing = MenuBarPresentation(
            source: source,
            freshness: .fresh,
            activity: .refreshing,
            now: now
        )
        let failed = MenuBarPresentation(
            source: source,
            freshness: .fresh,
            activity: .failed,
            now: now
        )

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

    func testNoSourceAndFutureObservationAreUnavailable() throws {
        let noSource = MenuBarPresentation(
            source: nil,
            freshness: .unavailable,
            now: now
        )
        let futureSource = try quotaSource(
            remainingPercent: 50,
            resetOffset: 3_600,
            capturedOffset: 10
        )
        let future = MenuBarPresentation(source: futureSource, freshness: .fresh, now: now)

        XCTAssertEqual(noSource.state, .noSource)
        XCTAssertNil(noSource.sourceID)
        XCTAssertEqual(noSource.shortStatus, "--")
        XCTAssertEqual(future.state, .missing)
        XCTAssertNil(future.remainingPercent)
    }

    func testNonWeeklyObservationCannotBecomeMenuBarAllowance() throws {
        let shortWindow = try QuotaSnapshot(
            id: "quota:short",
            capturedAt: now.addingTimeInterval(-30),
            windowMinutes: 300,
            usedPercent: 12,
            resetsAt: now.addingTimeInterval(1_000),
            limitID: "short",
            limitName: "Short",
            confidence: .exact
        )
        let source = QuotaOverviewSourceSnapshot(
            id: "id:short",
            name: "Short",
            current: shortWindow,
            daily: []
        )

        let presentation = MenuBarPresentation(source: source, freshness: .fresh, now: now)

        XCTAssertEqual(presentation.state, .missing)
        XCTAssertNil(presentation.remainingPercent)
        XCTAssertEqual(presentation.primaryValue, "--")
        XCTAssertEqual(presentation.resetDisplay, .unavailable)
    }

    func testCountdownAndSourceSwitchAreDerivedOnlyFromSuppliedFacts() throws {
        let first = try quotaSource(
            id: "id:first",
            name: "First",
            remainingPercent: 35,
            resetOffset: 90_061
        )
        let second = try quotaSource(
            id: "id:second",
            name: "Second",
            remainingPercent: 91,
            resetOffset: 65
        )

        let firstPresentation = MenuBarPresentation(source: first, freshness: .fresh, now: now)
        let secondPresentation = MenuBarPresentation(source: second, freshness: .fresh, now: now)

        XCTAssertEqual(firstPresentation.sourceID, "id:first")
        XCTAssertEqual(firstPresentation.resetDisplay, .countdown(seconds: 90_061))
        XCTAssertEqual(secondPresentation.sourceID, "id:second")
        XCTAssertEqual(secondPresentation.primaryValue, "91%")
        XCTAssertEqual(secondPresentation.resetDisplay, .countdown(seconds: 65))
    }

    func testPreferencesDefaultDisabledAndPersistOnlyDedicatedKeys() throws {
        let suiteName = "codex-director-menu-bar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let before = Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys)

        let first = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(first.snapshot(), .init(isEnabled: false, selectedQuotaSourceID: nil))

        first.setEnabled(true)
        XCTAssertTrue(first.setSelectedQuotaSourceID("id:weekly"))

        let restored = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(restored.snapshot(), .init(isEnabled: true, selectedQuotaSourceID: "id:weekly"))
        let after = Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys)
        XCTAssertEqual(
            after.subtracting(before),
            [MenuBarPreferences.enabledKey, MenuBarPreferences.selectedQuotaSourceKey]
        )
    }

    func testPreferencesRejectInvalidValuesAndMemoryStoresAreIsolated() {
        var enabled: Bool?
        var source: String? = "\nprivate"
        let injected = MenuBarPreferences(
            readEnabled: { enabled },
            readSelectedQuotaSourceID: { source },
            writeEnabled: { enabled = $0 },
            writeSelectedQuotaSourceID: { source = $0 },
            removeSelectedQuotaSourceID: { source = nil }
        )

        XCTAssertEqual(injected.snapshot(), .init(isEnabled: false, selectedQuotaSourceID: nil))
        XCTAssertFalse(injected.setSelectedQuotaSourceID("  "))
        XCTAssertFalse(injected.setSelectedQuotaSourceID("bad\nsource"))

        let first = MenuBarPreferences(memoryEnabled: true, selectedQuotaSourceID: "id:first")
        let second = MenuBarPreferences(memoryEnabled: false, selectedQuotaSourceID: nil)
        XCTAssertEqual(first.snapshot(), .init(isEnabled: true, selectedQuotaSourceID: "id:first"))
        XCTAssertEqual(second.snapshot(), .init(isEnabled: false, selectedQuotaSourceID: nil))

        first.setEnabled(false)
        first.clearSelectedQuotaSourceID()

        XCTAssertEqual(first.snapshot(), .init(isEnabled: false, selectedQuotaSourceID: nil))
        XCTAssertEqual(second.snapshot(), .init(isEnabled: false, selectedQuotaSourceID: nil))
    }

    func testProductionPreferencesTreatWrongStoredTypesAsSafeDefaults() throws {
        let suiteName = "codex-director-menu-bar-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("yes", forKey: MenuBarPreferences.enabledKey)
        defaults.set(42, forKey: MenuBarPreferences.selectedQuotaSourceKey)

        XCTAssertEqual(
            MenuBarPreferences(defaults: defaults).snapshot(),
            .init(isEnabled: false, selectedQuotaSourceID: nil)
        )
    }

    private func quotaSource(
        id: String = "id:weekly",
        name: String = "Weekly",
        remainingPercent: Double,
        resetOffset: TimeInterval,
        capturedOffset: TimeInterval = -30
    ) throws -> QuotaOverviewSourceSnapshot {
        let snapshot = try QuotaSnapshot(
            id: "quota:\(id)",
            capturedAt: now.addingTimeInterval(capturedOffset),
            windowMinutes: 10_080,
            usedPercent: 100 - remainingPercent,
            resetsAt: now.addingTimeInterval(resetOffset),
            limitID: id.replacingOccurrences(of: "id:", with: ""),
            limitName: name,
            confidence: .exact
        )
        return QuotaOverviewSourceSnapshot(id: id, name: name, current: snapshot, daily: [])
    }
}
