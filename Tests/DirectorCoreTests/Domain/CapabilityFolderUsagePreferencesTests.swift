import XCTest
@testable import DirectorCore

final class CapabilityFolderUsagePreferencesTests: XCTestCase {
    func testDefaultAndInvalidValuesUseSevenDays() {
        for raw in [nil, "", "future", "30", " 30d "] as [String?] {
            XCTAssertEqual(CapabilityFolderUsagePeriod.resolve(raw), .sevenDays)
        }
        XCTAssertEqual(CapabilityFolderUsagePeriod.resolve("30d"), .thirtyDays)
        XCTAssertEqual(CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays).period, .sevenDays)
    }

    func testDedicatedKeyDoesNotReuseHomeOrMembershipPreferences() {
        XCTAssertEqual(CapabilityFolderUsagePreferences.preferenceKey, "com.peiweitang.CodexDirector.capabilityFolders.usagePeriod")
        XCTAssertNotEqual(CapabilityFolderUsagePreferences.preferenceKey, HomeUsageRankingPreferences.preferenceKey)
    }

    func testInjectableStoreRestoresOnlyPeriodAndAvoidsRepeatedWrites() {
        var raw: String?
        var writes: [String] = []
        let preferences = CapabilityFolderUsagePreferences(readPeriod: { raw }, writePeriod: { raw = $0; writes.append($0) })
        preferences.setPeriod(.thirtyDays)
        preferences.setPeriod(.thirtyDays)
        XCTAssertEqual(writes, ["30d"])
        let restored = CapabilityFolderUsagePreferences(readPeriod: { raw }, writePeriod: { raw = $0 })
        XCTAssertEqual(restored.period, .thirtyDays)
        restored.setPeriod(.sevenDays)
        XCTAssertEqual(raw, "7d")
    }

    func testMemoryStoresDoNotShareOrPersist() {
        let first = CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)
        let second = CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)
        first.setPeriod(.thirtyDays)
        XCTAssertEqual(first.period, .thirtyDays)
        XCTAssertEqual(second.period, .sevenDays)
    }
}
