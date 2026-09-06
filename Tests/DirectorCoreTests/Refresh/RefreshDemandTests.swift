import XCTest
@testable import DirectorCore

final class RefreshDemandTests: XCTestCase {
    func testSurfaceCapabilitiesPreserveSingleRefreshBoundary() {
        XCTAssertFalse(RefreshDemand.none.requestsWork)
        XCTAssertFalse(RefreshDemand.menuBarPassive.requestsWork)
        XCTAssertTrue(RefreshDemand.menuBarPassive.isCacheOnly)

        XCTAssertTrue(RefreshDemand.menuBarPopover.requestsWork)
        XCTAssertFalse(RefreshDemand.menuBarPopover.requestsQuotaRefresh)
        XCTAssertFalse(RefreshDemand.menuBarPopover.requestsCapabilityRefresh)
        XCTAssertTrue(RefreshDemand.menuBarPopover.requestsAccountUsageRefresh)

        XCTAssertTrue(RefreshDemand.mainWindow.requestsWork)
        XCTAssertTrue(RefreshDemand.mainWindow.requestsQuotaRefresh)
        XCTAssertTrue(RefreshDemand.mainWindow.requestsCapabilityRefresh)
        XCTAssertTrue(RefreshDemand.mainWindow.requestsAccountUsageRefresh)
    }

    func testActiveSurfaceResolutionUsesSafePriority() {
        XCTAssertEqual(
            RefreshDemand.resolve(
                mainWindowIsVisible: false,
                menuBarIsEnabled: false,
                menuBarPopoverIsPresented: false
            ),
            .none
        )
        XCTAssertEqual(
            RefreshDemand.resolve(
                mainWindowIsVisible: false,
                menuBarIsEnabled: true,
                menuBarPopoverIsPresented: false
            ),
            .menuBarPassive
        )
        XCTAssertEqual(
            RefreshDemand.resolve(
                mainWindowIsVisible: false,
                menuBarIsEnabled: true,
                menuBarPopoverIsPresented: true
            ),
            .menuBarPopover
        )
        XCTAssertEqual(
            RefreshDemand.resolve(
                mainWindowIsVisible: true,
                menuBarIsEnabled: true,
                menuBarPopoverIsPresented: true
            ),
            .mainWindow
        )
    }

    func testMergedDemandCoalescesMultipleSurfacesWithoutDuplicateWork() {
        XCTAssertEqual(RefreshDemand.none.merged(with: .menuBarPassive), .menuBarPassive)
        XCTAssertEqual(RefreshDemand.menuBarPassive.merged(with: .menuBarPopover), .menuBarPopover)
        XCTAssertEqual(RefreshDemand.menuBarPopover.merged(with: .mainWindow), .mainWindow)
        XCTAssertEqual(
            RefreshDemand.merged([.menuBarPassive, .menuBarPopover, .menuBarPopover]),
            .menuBarPopover
        )
    }

    func testPassiveAndNoneNeverPermitSourceWork() {
        XCTAssertFalse(RefreshDemand.none.permitsSourceRefresh)
        XCTAssertFalse(RefreshDemand.menuBarPassive.permitsSourceRefresh)
        XCTAssertFalse(RefreshDemand.menuBarPopover.permitsSourceRefresh)
        XCTAssertTrue(RefreshDemand.mainWindow.permitsSourceRefresh)
    }

    func testPassiveAndNoneNeverRequestAccountUsage() {
        XCTAssertFalse(RefreshDemand.none.requestsAccountUsageRefresh)
        XCTAssertFalse(RefreshDemand.menuBarPassive.requestsAccountUsageRefresh)
    }
}
