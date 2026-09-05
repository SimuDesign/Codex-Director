import XCTest
@testable import DirectorCore

final class ResourceScannerTests: XCTestCase {

    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/resources", isDirectory: true)
    }

    private func root(_ id: String, _ name: String, kind: ScanRootKind, scope: ResourceScope) -> ScanRoot {
        ScanRoot(
            id: id,
            url: fixturesRoot.appendingPathComponent(name, isDirectory: true),
            scope: scope,
            kind: kind
        )
    }

    func testMissingRootIsTolerated() {
        let scanner = ResourceScanner(roots: [
            ScanRoot(
                id: "missing",
                url: fixturesRoot.appendingPathComponent("does-not-exist"),
                scope: .global,
                kind: .skills
            )
        ])
        let output = scanner.scan()
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertEqual(output.issues.count, 1)
    }

    func testNestedProjectSkill() {
        let scanner = ResourceScanner(roots: [root("project-root", "project-root", kind: .projects, scope: .project)])
        let output = scanner.scan()
        let skill = output.resources.first { $0.relativeSourcePath == ".agents/skills/proj-skill/SKILL.md" }
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.kind, .skill)
        XCTAssertEqual(skill?.scope, .project)
        XCTAssertEqual(skill?.projectID, "project-root")
        XCTAssertEqual(skill?.confidence, .exact)
        XCTAssertEqual(skill?.ownership, .userOwned)
        XCTAssertEqual(skill?.origin, .local)
        XCTAssertEqual(skill?.classificationConfidence, .exact)
    }

    func testUnregisteredGlobalSkillDefaultsToInstalledUnknownInferredRegardlessOfName() throws {
        let scanRoot = root("global-skills", "global-skills", kind: .skills, scope: .global)
        let output = ResourceScanner(roots: [scanRoot]).scan()
        let skill = try XCTUnwrap(output.resources.first { $0.name == "sample-skill" })

        XCTAssertEqual(skill.ownership, .installed)
        XCTAssertEqual(skill.origin, .unknown)
        XCTAssertEqual(skill.classificationConfidence, .inferred)
    }

    func testExplicitGlobalRegistrationMakesSkillUserOwnedExact() throws {
        let scanRoot = root("global-skills", "global-skills", kind: .skills, scope: .global)
        let registration = SkillOwnershipRegistration(
            rootID: scanRoot.id,
            relativeManifestPath: "sample-skill/SKILL.md"
        )
        let output = ResourceScanner(
            roots: [scanRoot],
            userOwnedSkillRegistrations: [registration]
        ).scan()
        let skill = try XCTUnwrap(output.resources.first { $0.name == "sample-skill" })

        XCTAssertEqual(skill.ownership, .userOwned)
        XCTAssertEqual(skill.origin, .local)
        XCTAssertEqual(skill.classificationConfidence, .exact)
        XCTAssertEqual(skill.originIdentifier, "global-skill-library")
    }

    func testManualOverrideWinsForEitherBinaryClassification() throws {
        let scanRoot = root("global-skills", "global-skills", kind: .skills, scope: .global)
        let baseline = ResourceScanner(roots: [scanRoot]).scan()
        let skill = try XCTUnwrap(baseline.resources.first { $0.name == "sample-skill" })

        let custom = ResourceScanner(
            roots: [scanRoot],
            overrides: [skill.id: ResourceClassificationOverride(ownership: .userOwned)]
        ).scan()
        let correctedCustom = try XCTUnwrap(custom.resources.first { $0.id == skill.id })
        XCTAssertEqual(correctedCustom.ownership, .userOwned)
        XCTAssertEqual(correctedCustom.origin, .local)
        XCTAssertEqual(correctedCustom.classificationConfidence, .exact)

        let registration = SkillOwnershipRegistration(rootID: scanRoot.id, relativeManifestPath: "sample-skill/SKILL.md")
        let installed = ResourceScanner(
            roots: [scanRoot],
            overrides: [skill.id: ResourceClassificationOverride(ownership: .installed)],
            userOwnedSkillRegistrations: [registration]
        ).scan()
        let correctedInstalled = try XCTUnwrap(installed.resources.first { $0.id == skill.id })
        XCTAssertEqual(correctedInstalled.ownership, .installed)
        XCTAssertEqual(correctedInstalled.origin, .unknown)
        XCTAssertEqual(correctedInstalled.classificationConfidence, .exact)
    }

    func testDuplicateResourceIdentityIsDeduped() {
        let single = root("global-skills", "global-skills", kind: .skills, scope: .global)
        let output = ResourceScanner(roots: [single, single]).scan()
        XCTAssertEqual(output.resources.count, 2) // sample-skill + versioned-skill
        XCTAssertEqual(Set(output.resources.map(\.id)).count, output.resources.count)
    }

    func testSameLogicalSkillAcrossDistinctRootsRetainsStableIdentities() {
        let first = root("global-skills-a", "global-skills", kind: .skills, scope: .global)
        let second = root("global-skills-b", "global-skills", kind: .skills, scope: .global)
        let output = ResourceScanner(roots: [first, second]).scan()
        XCTAssertEqual(output.resources.count, 4)
        XCTAssertTrue(output.provenance.allSatisfy { record in output.resources.contains { resource in resource.id == record.resourceID } })
    }

    func testSymlinkEscapeIsNotFollowed() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outside = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "---\nname: outside-skill\n---\n".write(
            to: outside.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let rootDir = tempDir.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: rootDir.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let scanner = ResourceScanner(roots: [
            ScanRoot(id: "escape-root", url: rootDir, scope: .global, kind: .skills)
        ])
        let output = scanner.scan()
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.issues.contains { $0.message.contains("Symlink escapes") })
    }

    func testUnknownManifestVersionRecordsIssueAndDropsConfidence() {
        let scanner = ResourceScanner(roots: [root("global-skills", "global-skills", kind: .skills, scope: .global)])
        let output = scanner.scan()
        let versioned = output.resources.first { $0.relativeSourcePath == "versioned-skill/SKILL.md" }
        XCTAssertNotNil(versioned)
        XCTAssertEqual(versioned?.confidence, .unknown)
        XCTAssertTrue(output.issues.contains { $0.message.contains("Unknown manifest version") })
    }

    func testRepeatedScanProducesStableIDs() {
        let roots = [root("global-skills", "global-skills", kind: .skills, scope: .global)]
        let first = ResourceScanner(roots: roots).scan()
        let second = ResourceScanner(roots: roots).scan()
        XCTAssertEqual(first.resources.map(\.id), second.resources.map(\.id))
    }

    func testPluginManifestsYieldPluginAppMcpHookResources() {
        let scanner = ResourceScanner(roots: [root("plugin-root", "plugin-root", kind: .plugins, scope: .plugin)])
        let output = scanner.scan()
        XCTAssertTrue(output.resources.contains { $0.kind == .plugin && $0.name == "demo-plugin" })
        XCTAssertTrue(output.resources.contains { $0.kind == .app && $0.name == "demo-app" })
        XCTAssertTrue(output.resources.contains { $0.kind == .mcp && $0.name == "demo-mcp" })
        XCTAssertTrue(output.resources.contains { $0.kind == .hook })
        XCTAssertTrue(output.resources.contains { $0.kind == .skill && $0.name == "plug-skill" })
        XCTAssertTrue(output.resources.contains { $0.kind == .agent && $0.name == "plug-agent" })
    }

    func testAgentBriefsRecognized() {
        let scanner = ResourceScanner(roots: [root("global-agents", "global-agents", kind: .agents, scope: .global)])
        let output = scanner.scan()
        XCTAssertEqual(output.resources.count, 1)
        XCTAssertEqual(output.resources.first?.kind, .agent)
        XCTAssertEqual(output.resources.first?.name, "Sample Agent")
        XCTAssertEqual(output.resources.first?.summary, "Synthetic agent brief for discovery tests.")
        XCTAssertNotNil(output.resources.first?.contentFingerprint)
        XCTAssertNotNil(output.resources.first?.sourceModifiedAt)
    }

    func testAgentPurposeIsBoundedAndUnsafePurposeFailsClosed() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-purpose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("safe"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("unsafe"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "# Safe Agent\n\n## Mission\n\nThis is a bounded purpose.\n\n## Details\n\nDo not persist this section.".write(to: temp.appendingPathComponent("safe/agent.md"), atomically: true, encoding: .utf8)
        try "# Unsafe Agent\n\n## Mission\n\nAuthorization: Bearer synthetic-example\n".write(to: temp.appendingPathComponent("unsafe/agent.md"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [ScanRoot(id: "agents", url: temp, scope: .global, kind: .agents)]).scan()
        XCTAssertEqual(output.resources.count, 2)
        let safe = try XCTUnwrap(output.resources.first { $0.name == "Safe Agent" })
        XCTAssertEqual(safe.summary, "This is a bounded purpose.")
        XCTAssertLessThanOrEqual(safe.summary?.count ?? 0, 320)
        XCTAssertNil(output.resources.first { $0.name == "Unsafe Agent" }?.summary)
    }

    func testAgentFingerprintDetectsContentChange() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("agent"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let brief = temp.appendingPathComponent("agent/agent.md")
        try "# Agent\n\nInitial purpose.".write(to: brief, atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "agents", url: temp, scope: .global, kind: .agents)
        let first = ResourceScanner(roots: [root]).scan()
        let resource = try XCTUnwrap(first.resources.first)
        try "# Agent\n\nChanged purpose.".write(to: brief, atomically: true, encoding: .utf8)
        let second = ResourceScanner(roots: [root], previousFingerprints: [resource.id: resource.contentFingerprint ?? ""]).scan()
        XCTAssertTrue(second.resources.first?.modified == true)
    }

    func testProjectRegistryEntriesRecognized() {
        let scanner = ResourceScanner(roots: [root("project-root", "project-root", kind: .projects, scope: .project)])
        let output = scanner.scan()
        XCTAssertTrue(output.resources.contains { $0.name == "reg-agent" && $0.kind == .agent })
        XCTAssertTrue(output.resources.contains { $0.name == "reg-workflow" && $0.kind == .workflow })
        XCTAssertTrue(output.resources.contains { $0.name == "project-root" && $0.kind == .instruction })
        let projectAgent = output.resources.first { $0.name == "proj-agent" && $0.kind == .agent }
        XCTAssertEqual(projectAgent?.summary, "Synthetic project agent brief.")
        XCTAssertNotNil(projectAgent?.contentFingerprint)
        XCTAssertNotNil(projectAgent?.sourceModifiedAt)
        XCTAssertEqual(output.projects.count, 1)
    }

    func testProjectAgentTomlAndSkillCarryBoundedMetadataAndAgentChangeState() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-project-agent-(UUID().uuidString)", isDirectory: true)
        let agentDirectory = temp.appendingPathComponent(".codex/agents", isDirectory: true)
        let skillDirectory = temp.appendingPathComponent(".agents/skills/project-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let agent = agentDirectory.appendingPathComponent("project-agent.toml")
        try "name = \"Project Agent\"\ndescription = \"Project-specific bounded purpose.\"\ndeveloper_instructions = \"\"\"\nDo not persist this blob.\n\"\"\"\n".write(to: agent, atomically: true, encoding: .utf8)
        try "---\nname: project-skill\ndescription: Project skill.\n---\n".write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "project-temp", url: temp, scope: .project, kind: .projects)

        let first = ResourceScanner(roots: [root]).scan()
        let firstAgent = try XCTUnwrap(first.resources.first { $0.kind == .agent && $0.projectID == root.id })
        let firstSkill = try XCTUnwrap(first.resources.first { $0.kind == .skill && $0.projectID == root.id })
        XCTAssertEqual(firstAgent.summary, "Project-specific bounded purpose.")
        XCTAssertNotNil(firstAgent.contentFingerprint)
        XCTAssertNotNil(firstAgent.sourceModifiedAt)
        XCTAssertFalse(firstAgent.modified)
        XCTAssertNotNil(firstSkill.sourceModifiedAt)

        try "name = \"Project Agent\"\ndescription = \"Changed project-specific purpose.\"\n".write(to: agent, atomically: true, encoding: .utf8)
        let second = ResourceScanner(
            roots: [root],
            previousFingerprints: [firstAgent.id: firstAgent.contentFingerprint ?? ""]
        ).scan()
        let secondAgent = try XCTUnwrap(second.resources.first { $0.id == firstAgent.id })
        XCTAssertEqual(secondAgent.summary, "Changed project-specific purpose.")
        XCTAssertNotNil(secondAgent.contentFingerprint)
        XCTAssertTrue(secondAgent.modified)
        XCTAssertNotNil(secondAgent.sourceModifiedAt)
    }

    func testProjectAgentTomlMalformedAndOversizedContentFailsSafe() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-project-agent-safe-\(UUID().uuidString)", isDirectory: true)
        let directory = temp.appendingPathComponent(".codex/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let malformed = directory.appendingPathComponent("malformed.toml")
        let oversized = directory.appendingPathComponent("oversized.toml")
        let escaped = directory.appendingPathComponent("escaped.toml")
        try "name = \"Safe\"\ndescription = \"unterminated\n".write(to: malformed, atomically: true, encoding: .utf8)
        try ("name = \"Too Large\"\ndescription = \"" + String(repeating: "x", count: 70_000) + "\"\n").write(to: oversized, atomically: true, encoding: .utf8)
        try "name = \"Escaped\"\ndescription = \"safe\\nvalue\"\n".write(to: escaped, atomically: true, encoding: .utf8)
        let output = ResourceScanner(roots: [ScanRoot(id: "project-safe", url: temp, scope: .project, kind: .projects)]).scan()
        let resources = output.resources.filter { $0.kind == .agent }
        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources.allSatisfy { $0.summary == nil })
        XCTAssertTrue(resources.contains { $0.name == "malformed" })
        XCTAssertTrue(resources.contains { $0.name == "oversized" })
        XCTAssertTrue(resources.contains { $0.name == "escaped" })
    }

    func testAgentPurposeRejectsCredentialAfterBoundedPrefix() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-boundary-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("agent"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let safePrefix = String(repeating: "a", count: 320)
        try "# Agent\n\n## Mission\n\n\(safePrefix) password: super-secret-value\n".write(to: temp.appendingPathComponent("agent/agent.md"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [ScanRoot(id: "agents", url: temp, scope: .global, kind: .agents)]).scan()
        XCTAssertNil(output.resources.first?.summary)
    }

    func testSystemSkillRootUsesSystemScopeAndRejectsClassificationOverride() throws {
        // A System Skill root scans the same manifest shape with scope .system.
        let root = ScanRoot(
            id: "system-skills",
            url: fixturesRoot.appendingPathComponent("global-skills"),
            scope: .system,
            kind: .skills
        )
        let output = ResourceScanner(roots: [root]).scan()
        XCTAssertFalse(output.resources.isEmpty)
        XCTAssertTrue(output.resources.allSatisfy { $0.scope == .system })
        let resource = try XCTUnwrap(output.resources.first)
        let overridden = ResourceScanner(
            roots: [root],
            overrides: [resource.id: ResourceClassificationOverride(ownership: .userOwned)]
        ).scan()
        XCTAssertTrue(overridden.resources.allSatisfy { $0.ownership == .builtIn && $0.origin == .codexSystem })
    }

    func testSkillProvenanceAndModifiedFingerprint() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-provenance-\(UUID().uuidString)", isDirectory: true)
        let skills = temp.appendingPathComponent("skills", isDirectory: true)
        let skill = skills.appendingPathComponent("local-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: local-skill\ndescription: local\n---\nbody\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "{\"version\":3,\"skills\":{\"local-skill\":{\"source\":\"owner/repo\",\"sourceType\":\"github\"}}}".write(to: temp.appendingPathComponent(".skill-lock.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let root = ScanRoot(id: "provenance", url: skills, scope: .global, kind: .skills)
        let first = ResourceScanner(roots: [root]).scan()
        let resource = try XCTUnwrap(first.resources.first)
        XCTAssertEqual(resource.ownership, .installed)
        XCTAssertEqual(resource.origin, .github)
        XCTAssertFalse(resource.modified)
        XCTAssertEqual(first.provenance.first?.sourceIdentifier, "owner/repo")

        try "---\nname: local-skill\n---\nchanged\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let second = ResourceScanner(
            roots: [root],
            previousFingerprints: [resource.id: resource.contentFingerprint ?? ""]
        ).scan()
        XCTAssertTrue(second.resources.first?.modified == true)
    }

    func testGlobalRegistrationWinsInstalledProvenanceAndRecordsConflict() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-registration-conflict-\(UUID().uuidString)", isDirectory: true)
        let skills = temp.appendingPathComponent("skills", isDirectory: true)
        let skill = skills.appendingPathComponent("registered-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "---\nname: registered-skill\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "{\"skills\":{\"registered-skill\":{\"source\":\"owner/repo\",\"sourceType\":\"github\"}}}".write(to: temp.appendingPathComponent(".skill-lock.json"), atomically: true, encoding: .utf8)

        let scanRoot = ScanRoot(id: "global", url: skills, scope: .global, kind: .skills)
        let output = ResourceScanner(
            roots: [scanRoot],
            userOwnedSkillRegistrations: [
                SkillOwnershipRegistration(rootID: scanRoot.id, relativeManifestPath: "registered-skill/SKILL.md")
            ]
        ).scan()
        let resource = try XCTUnwrap(output.resources.first)

        XCTAssertEqual(resource.ownership, .userOwned)
        XCTAssertEqual(resource.origin, .local)
        XCTAssertEqual(resource.classificationConfidence, .exact)
        XCTAssertTrue(output.issues.contains { $0.message.contains("registration wins") })
    }

    func testExactProjectInstallMetadataWinsProjectDirectoryConvention() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-project-installed-\(UUID().uuidString)", isDirectory: true)
        let skill = temp.appendingPathComponent(".agents/skills/installed-project-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "---\nname: installed-project-skill\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "{\"slug\":\"registry/project-skill\",\"version\":\"1.0.0\"}".write(to: skill.appendingPathComponent("_meta.json"), atomically: true, encoding: .utf8)

        let scanRoot = ScanRoot(id: "project", url: temp, scope: .project, kind: .projects)
        let resource = try XCTUnwrap(ResourceScanner(roots: [scanRoot]).scan().resources.first { $0.kind == .skill })

        XCTAssertEqual(resource.ownership, .installed)
        XCTAssertEqual(resource.origin, .registry)
        XCTAssertEqual(resource.classificationConfidence, .exact)
    }
}
