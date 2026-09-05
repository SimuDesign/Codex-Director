import XCTest
@testable import DirectorCore

final class SkillOwnershipRegistryReaderTests: XCTestCase {
    func testReadsOnlyExplicitSafeManifestBulletsFromGlobalLibrarySection() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-skill-registry-\(UUID().uuidString)", isDirectory: true)
        let skills = temp.appendingPathComponent("skills", isDirectory: true)
        let valid = skills.appendingPathComponent("valid-skill", isDirectory: true)
        let outside = temp.appendingPathComponent("outside-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try "---\nname: valid-skill\n---\n".write(
            to: valid.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "---\nname: outside-skill\n---\n".write(
            to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let validPath = valid.appendingPathComponent("SKILL.md").path
        let missingPath = skills.appendingPathComponent("missing/SKILL.md").path
        let outsidePath = outside.appendingPathComponent("SKILL.md").path
        let escapedPath = skills.appendingPathComponent("escape/SKILL.md").path
        let document = """
        # Global Skill Library

        Available shared workflows:

        - `Valid Skill`: `\(validPath)`
        - `Duplicate`: `\(validPath)`
        This prose mentions `\(validPath)` but is not a registration bullet.
        - See `\(validPath)` for documentation; this is not a registration entry.
        - `\(validPath)`
        - `Missing`: `\(missingPath)`
        - `Outside`: `\(outsidePath)`
        - `Escape`: `\(escapedPath)`

        # Another Section

        - `Ignored`: `\(validPath)`
        """
        let registry = temp.appendingPathComponent("AGENTS.md")
        try document.write(to: registry, atomically: true, encoding: .utf8)

        let root = ScanRoot(id: "global-skills", url: skills, scope: .global, kind: .skills)
        let output = SkillOwnershipRegistryReader().read(from: registry, globalSkillRoots: [root])

        XCTAssertEqual(output.registrations, [
            SkillOwnershipRegistration(rootID: root.id, relativeManifestPath: "valid-skill/SKILL.md")
        ])
        XCTAssertEqual(output.issues.count, 4)
        XCTAssertTrue(output.issues.contains { $0.message.contains("Duplicate") })
        XCTAssertTrue(output.issues.allSatisfy { $0.rootID == "skill-ownership-registry" })
        XCTAssertFalse(output.issues.contains { $0.relativePath.contains(temp.path) })
    }

    func testMissingRegistryIsNonFatalAndDoesNotInventRegistrations() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-missing-registry-\(UUID().uuidString)", isDirectory: true)
        let root = ScanRoot(id: "global-skills", url: temp, scope: .global, kind: .skills)

        let output = SkillOwnershipRegistryReader().read(
            from: temp.appendingPathComponent("AGENTS.md"),
            globalSkillRoots: [root]
        )

        XCTAssertTrue(output.registrations.isEmpty)
        XCTAssertEqual(output.issues.count, 1)
    }
}
