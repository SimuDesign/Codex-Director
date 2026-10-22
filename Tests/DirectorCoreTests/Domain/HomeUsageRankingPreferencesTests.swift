import XCTest
@testable import DirectorCore

final class HomeUsageRankingPreferencesTests: XCTestCase {
    func testMissingAndInvalidValuesResolveToThirtyDays() {
        for raw in [nil, "", "future", "30", " 30d "] as [String?] {
            XCTAssertEqual(HomeUsageRankingPeriod.resolve(raw), .thirtyDays)
        }
        XCTAssertEqual(HomeUsageRankingPreferences(memoryPeriod: .thirtyDays).period, .thirtyDays)
        XCTAssertEqual(HomeUsageRankingPreferences(memoryPeriod: .sevenDays).period, .sevenDays)
    }

    func testInjectedMissingValueDefaultsToThirtyDaysWithoutWriting() {
        let store = HomeUsageRankingPreferences(readPeriod: { nil }, writePeriod: { _ in XCTFail("Initialization must not write preferences") })
        XCTAssertEqual(store.period, .thirtyDays)
    }

    func testClosureStorePersistsOnlyTheSelectedPeriod() {
        var rawValue: String?
        let store = HomeUsageRankingPreferences(
            readPeriod: { rawValue },
            writePeriod: { rawValue = $0 }
        )

        XCTAssertEqual(store.period, .thirtyDays)
        XCTAssertNil(rawValue)
        store.setPeriod(.sevenDays)
        XCTAssertEqual(store.period, .sevenDays)
        XCTAssertEqual(rawValue, HomeUsageRankingPeriod.sevenDays.rawValue)

        let restored = HomeUsageRankingPreferences(readPeriod: { rawValue }, writePeriod: { rawValue = $0 })
        XCTAssertEqual(restored.period, .sevenDays)
    }

    func testIsolatedDefaultsRestoreBothValidPeriodsWithoutOverwritingThem() throws {
        let suite = "director-home-period-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HomeUsageRankingPreferences(defaults: defaults).period, .thirtyDays)
        XCTAssertNil(defaults.string(forKey: HomeUsageRankingPreferences.preferenceKey))
        for period in HomeUsageRankingPeriod.allCases {
            defaults.set(period.rawValue, forKey: HomeUsageRankingPreferences.preferenceKey)
            XCTAssertEqual(HomeUsageRankingPreferences(defaults: defaults).period, period)
            XCTAssertEqual(defaults.string(forKey: HomeUsageRankingPreferences.preferenceKey), period.rawValue)
        }
    }

    func testMemoryStoresAreIsolated() {
        let first = HomeUsageRankingPreferences(memoryPeriod: .sevenDays)
        let second = HomeUsageRankingPreferences(memoryPeriod: .sevenDays)

        first.setPeriod(.thirtyDays)

        XCTAssertEqual(first.period, .thirtyDays)
        XCTAssertEqual(second.period, .sevenDays)
    }
}
