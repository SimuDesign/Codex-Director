import XCTest
@testable import DirectorUI
import DirectorCore

/// Symbol-contract test: every required SF Symbol must resolve in the
/// current SDK, or the contract fails and a replacement needs approval.
final class DirectorSymbolTests: XCTestCase {

    func testAllRequiredSymbolsResolveInCurrentSDK() {
        let missing = DirectorSymbol.requiredSymbols.filter { !DirectorSymbol.isValid($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "Missing SF Symbols require an approved replacement: \(missing)"
        )
    }

    func testEveryResourceKindHasANonEmptySymbol() {
        for kind in ResourceKind.allCases {
            XCTAssertFalse(DirectorSymbol.resource(kind).isEmpty, "\(kind) has no symbol")
        }
    }

    func testEveryRuntimeStatusHasARedundantSignalSymbol() {
        for status in RuntimeStatus.allCases {
            XCTAssertFalse(DirectorSymbol.status(status).isEmpty, "\(status) has no symbol")
        }
    }

    func testDestinationSymbolsResolve() {
        for destination in DirectorDestination.allCases {
            XCTAssertTrue(DirectorSymbol.isValid(destination.symbol), destination.symbol)
        }
        for utility in DirectorUtility.allCases {
            XCTAssertTrue(DirectorSymbol.isValid(utility.symbol), utility.symbol)
        }
    }
}
