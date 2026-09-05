import XCTest
@testable import DirectorUI

final class UsageLayoutTests: XCTestCase {
    func testUsageTablesAlwaysExposeHeaderAndAtLeastOneRowHeight() {
        XCTAssertEqual(
            UsageTableLayoutMetrics.height(forRowCount: 0),
            UsageTableLayoutMetrics.minimumHeight
        )
        XCTAssertGreaterThan(UsageTableLayoutMetrics.height(forRowCount: 1), 0)
    }

    func testUsageTableHeightIsCappedForLargeDatasets() {
        XCTAssertEqual(
            UsageTableLayoutMetrics.height(forRowCount: 10_000),
            UsageTableLayoutMetrics.maximumHeight
        )
        XCTAssertLessThanOrEqual(
            UsageTableLayoutMetrics.height(forRowCount: 100),
            UsageTableLayoutMetrics.maximumHeight
        )
    }
}
