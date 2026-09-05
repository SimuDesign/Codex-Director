import XCTest
@testable import DirectorCore

final class PresentationClassificationRevisionTests: XCTestCase {
    func testRevisionIsDeterministicAndMaterialOnly() {
        let a = ResourceClassificationOverride(ownership: .installed, origin: .github, note: "one")
        let b = ResourceClassificationOverride(ownership: .userOwned, origin: .local)
        let first = PresentationClassificationRevision.make(["skill:b": b, "skill:a": a])
        let reordered = PresentationClassificationRevision.make(["skill:a": a, "skill:b": b])
        XCTAssertEqual(first, reordered)
        XCTAssertNotEqual(first, PresentationClassificationRevision.make(["skill:b": b, "skill:a": ResourceClassificationOverride(ownership: .userOwned, origin: .github)]))
        XCTAssertNotEqual(first, PresentationClassificationRevision.make(["skill:a": a]))
        XCTAssertNotEqual(first, PresentationClassificationRevision.make(["skill:b": b, "skill:a": ResourceClassificationOverride(ownership: .installed, origin: .registry)]))
        let delimiterA = PresentationClassificationRevision.make(["a|b": a])
        let delimiterB = PresentationClassificationRevision.make(["a": a, "b": a])
        XCTAssertNotEqual(delimiterA, delimiterB)
    }
}
