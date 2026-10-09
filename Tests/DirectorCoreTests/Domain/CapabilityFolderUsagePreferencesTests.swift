import XCTest
@testable import DirectorCore

final class CapabilityFolderUsagePreferencesTests: XCTestCase {
    func testDefaultAndInvalidValuesUseThirtyDays() {
        for raw in [nil, "", "future", "30", " 30d "] as [String?] {
            XCTAssertEqual(CapabilityFolderUsagePeriod.resolve(raw), .thirtyDays)
        }
        XCTAssertEqual(CapabilityFolderUsagePeriod.resolve("30d"), .thirtyDays)
        XCTAssertEqual(CapabilityFolderUsagePeriod.resolve("7d"), .sevenDays)
        XCTAssertEqual(CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays).period, .sevenDays)
        XCTAssertEqual(CapabilityFolderUsagePreferences().period, .thirtyDays)
    }

    func testDedicatedKeyDoesNotReuseHomeOrMembershipPreferences() {
        XCTAssertEqual(CapabilityFolderUsagePreferences.preferenceKey, "com.peiweitang.CodexDirector.capabilityFolders.usagePeriod")
        XCTAssertNotEqual(CapabilityFolderUsagePreferences.preferenceKey, HomeUsageRankingPreferences.preferenceKey)
    }

    func testInjectableStoreRestoresOnlyPeriodAndAvoidsRepeatedWrites() {
        var raw: String?
        var writes: [String] = []
        let preferences = CapabilityFolderUsagePreferences(readPeriod: { raw }, writePeriod: { raw = $0; writes.append($0) })
        XCTAssertEqual(preferences.period, .thirtyDays)
        XCTAssertTrue(writes.isEmpty)
        preferences.setPeriod(.sevenDays)
        preferences.setPeriod(.sevenDays)
        XCTAssertEqual(writes, ["7d"])
        let restored = CapabilityFolderUsagePreferences(readPeriod: { raw }, writePeriod: { raw = $0 })
        XCTAssertEqual(restored.period, .sevenDays)
        restored.setPeriod(.thirtyDays)
        XCTAssertEqual(raw, "30d")
    }

    func testValidRememberedPeriodsRemainAuthoritativeWithoutInitializationWrites() {
        for period in CapabilityFolderUsagePeriod.allCases {
            let preferences = CapabilityFolderUsagePreferences(readPeriod: { period.rawValue }, writePeriod: { _ in XCTFail("Initialization must not overwrite a valid choice") })
            XCTAssertEqual(preferences.period, period)
        }
    }

    func testMemoryStoresDoNotShareOrPersist() {
        let first = CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)
        let second = CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)
        first.setPeriod(.thirtyDays)
        XCTAssertEqual(first.period, .thirtyDays)
        XCTAssertEqual(second.period, .sevenDays)
    }
}
