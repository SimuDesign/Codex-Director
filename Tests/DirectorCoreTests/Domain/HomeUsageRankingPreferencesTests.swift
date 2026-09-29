import XCTest
@testable import DirectorCore

final class HomeUsageRankingPreferencesTests: XCTestCase {
    func testMissingAndInvalidValuesResolveToSevenDays() {
        XCTAssertEqual(HomeUsageRankingPeriod.resolve(nil), .sevenDays)
        XCTAssertEqual(HomeUsageRankingPeriod.resolve("future"), .sevenDays)
        XCTAssertEqual(HomeUsageRankingPreferences(memoryPeriod: .sevenDays).period, .sevenDays)
    }

    func testClosureStorePersistsOnlyTheSelectedPeriod() {
        var rawValue: String?
        let store = HomeUsageRankingPreferences(
            readPeriod: { rawValue },
            writePeriod: { rawValue = $0 }
        )

        XCTAssertEqual(store.period, .sevenDays)
        store.setPeriod(.thirtyDays)
        XCTAssertEqual(store.period, .thirtyDays)
        XCTAssertEqual(rawValue, HomeUsageRankingPeriod.thirtyDays.rawValue)

        let restored = HomeUsageRankingPreferences(readPeriod: { rawValue }, writePeriod: { rawValue = $0 })
        XCTAssertEqual(restored.period, .thirtyDays)
    }

    func testMemoryStoresAreIsolated() {
        let first = HomeUsageRankingPreferences(memoryPeriod: .sevenDays)
        let second = HomeUsageRankingPreferences(memoryPeriod: .sevenDays)

        first.setPeriod(.thirtyDays)

        XCTAssertEqual(first.period, .thirtyDays)
        XCTAssertEqual(second.period, .sevenDays)
    }
}
