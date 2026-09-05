import XCTest
@testable import DirectorUI

/// Bootstrap contract for the DirectorUI library target and the
/// executable window's root view.
final class BootstrapUITests: XCTestCase {

    func testProductNameIsStable() {
        XCTAssertEqual(DirectorUI.productName, "Codex Director")
    }

    @MainActor
    func testRootViewCanBeConstructed() {
        _ = DirectorRootView(model: TestMemoryPreferences.makeModel())
    }
}
