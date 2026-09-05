import XCTest
@testable import DirectorCore

/// Bootstrap contract for the DirectorCore library target.
final class BootstrapTests: XCTestCase {

    func testCoreLibraryIdentityIsStable() {
        XCTAssertEqual(DirectorCore.libraryName, "DirectorCore")
    }

    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(DirectorCore.schemaVersion, 0)
    }
}
