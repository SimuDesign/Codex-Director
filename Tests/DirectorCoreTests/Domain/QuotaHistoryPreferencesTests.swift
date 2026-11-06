import XCTest
@testable import DirectorCore

final class QuotaHistoryPreferencesTests: XCTestCase {
    func testMissingAndInvalidValuesDefaultWithoutWriting() {
        for raw in [nil, "invalid", "90d"] as [String?] {
            var writes: [String] = []
            let preferences = QuotaHistoryPreferences(
                readPeriod: { raw },
                writePeriod: { writes.append($0) }
            )
            XCTAssertEqual(preferences.period, .thirtyDays)
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testWritesOnlyChangedIndependentHistoryPeriod() {
        var writes: [String] = []
        let preferences = QuotaHistoryPreferences(
            readPeriod: { "7d" },
            writePeriod: { writes.append($0) }
        )
        XCTAssertEqual(preferences.period, .sevenDays)
        preferences.setPeriod(.sevenDays)
        preferences.setPeriod(.sixtyDays)
        XCTAssertEqual(preferences.period, .sixtyDays)
        XCTAssertEqual(writes, ["60d"])
        XCTAssertNotEqual(QuotaHistoryPreferences.preferenceKey, HomeUsageRankingPreferences.preferenceKey)
        XCTAssertNotEqual(QuotaHistoryPreferences.preferenceKey, CapabilityFolderUsagePreferences.preferenceKey)
    }
}
