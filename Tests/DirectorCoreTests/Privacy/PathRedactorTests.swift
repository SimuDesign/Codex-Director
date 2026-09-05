import XCTest
@testable import DirectorCore

final class PathRedactorTests: XCTestCase {

    private let redactor = PathRedactor()
    private let home = "/Users/exampleuser"

    func testUsernameRemoval() {
        let path = "/Users/exampleuser/.codex/skills/video-cover-studio/SKILL.md"
        XCTAssertEqual(
            redactor.redact(path, homeDirectory: home),
            "~/.codex/skills/video-cover-studio/SKILL.md"
        )
        XCTAssertFalse(redactor.containsUserName(redactor.redact(path, homeDirectory: home), userName: "exampleuser"))
    }

    func testHomePathItselfBecomesTilde() {
        XCTAssertEqual(redactor.redact(home, homeDirectory: home), "~")
    }

    func testUserNamePrefixRemovedWithoutHomeDirectory() {
        let path = "/Users/exampleuser/Documents/Codex/2026-08-15/project"
        XCTAssertEqual(
            redactor.redactUser(path, userName: "exampleuser"),
            "~/Documents/Codex/2026-08-15/project"
        )
    }

    func testPathsWithoutUserAreUnchanged() {
        let path = "/Applications/Xcode.app"
        XCTAssertEqual(redactor.redact(path, homeDirectory: home), path)
        XCTAssertEqual(redactor.redactUser(path, userName: "exampleuser"), path)
    }

    func testRedactionAppliesToErrorDescriptionsAndLabels() {
        let errorDescription = "Failed to read /Users/exampleuser/.codex/agents/x/agent.md"
        let redacted = redactor.redact(errorDescription, homeDirectory: home)
        XCTAssertFalse(redacted.contains("exampleuser"))
        XCTAssertTrue(redacted.contains("~/.codex/agents/x/agent.md"))
    }

    func testAccessibilityLabelRedaction() {
        let label = "Source: /Users/exampleuser/CodeX/Codex Director"
        XCTAssertFalse(redactor.containsUserName(redactor.redact(label, homeDirectory: home), userName: "exampleuser"))
    }
}
