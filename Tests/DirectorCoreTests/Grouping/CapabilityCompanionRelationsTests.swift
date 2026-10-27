import XCTest
@testable import DirectorCore

final class CapabilityCompanionRelationsTests: XCTestCase {
    func testRelationshipIndexMigrationPolicySchedulesOnlyForIndexedLegacyData() {
        XCTAssertFalse(CapabilityCompanionIndexMigration.needsSourceRefresh(marker: nil, hasIndexedData: false))
        XCTAssertTrue(CapabilityCompanionIndexMigration.needsSourceRefresh(marker: nil, hasIndexedData: true))
        XCTAssertTrue(CapabilityCompanionIndexMigration.needsSourceRefresh(marker: "capability-companions.v0", hasIndexedData: true))
        XCTAssertFalse(CapabilityCompanionIndexMigration.needsSourceRefresh(marker: CapabilityCompanionIndex.currentVersion, hasIndexedData: true))
        // A cancelled/failed source pass does not write the marker, so the
        // next lifecycle request makes the same decision and retries safely.
        XCTAssertTrue(CapabilityCompanionIndexMigration.needsSourceRefresh(marker: nil, hasIndexedData: true))
    }

    func testRelationshipIndexMigrationUpgradesLegacyV2MarkerToV3Once() {
        XCTAssertTrue(
            CapabilityCompanionIndexMigration.needsSourceRefresh(
                marker: "capability-companions.v2",
                hasIndexedData: true
            )
        )
        XCTAssertFalse(
            CapabilityCompanionIndexMigration.needsSourceRefresh(
                marker: CapabilityCompanionIndex.currentVersion,
                hasIndexedData: true
            )
        )
    }

    func testV5RegistryUsesNativeAgentTomlStemAndSkillIDWithoutDuplicateAgent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-v5-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/render", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: projectAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Display Name\"\n".write(to: projectAgents.appendingPathComponent("render-agent.toml"), atomically: true, encoding: .utf8)
        try "---\nname: skill-package\n---\n".write(to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":5,"packages":{"agent-package":{"kind":"native-agent","id":"agent-package","nativeAgent":"render-agent","usesSkills":["skill-package"]},"skill-package":{"kind":"auxiliary-skill","id":"skill-package","nativeAgent":"render-agent","invokedBy":["render-agent"]}}}"#
        try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "project", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let agent = try XCTUnwrap(output.resources.first { $0.kind == .agent })
        let skill = try XCTUnwrap(output.resources.first { $0.kind == .skill })
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()

        XCTAssertEqual(agent.relativeSourcePath, ".codex/agents/render-agent.toml")
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(report.relations.first?.agentID, agent.id)
        XCTAssertEqual(report.relations.first?.skillID, skill.id)
    }

    func testV5RegistryDoesNotTreatNativeAgentDisplayNameAsTomlStem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-v5-stem-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/render", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: projectAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Display Name\"\n".write(to: projectAgents.appendingPathComponent("render-agent.toml"), atomically: true, encoding: .utf8)
        try "---\nname: skill-package\n---\n".write(to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":5,"packages":[{"kind":"auxiliary-skill","id":"skill-package","nativeAgent":"Display Name","invokedBy":["Display Name"]}]}"#
        try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "project", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()

        XCTAssertTrue(report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty)
    }

    func testV5ConflictingDuplicatePackageIDsRejectRegistryIndependentOfArrayOrder() throws {
        let packageA = #"{"kind":"native-agent","id":"agent-package","nativeAgent":"build-agent","usesSkills":["skill-package"]}"#
        let packageB = #"{"kind":"native-agent","id":"AGENT-PACKAGE","nativeAgent":"other-agent","usesSkills":["skill-package"]}"#
        for (index, packages) in [[packageA, packageB], [packageB, packageA]].enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-v5-conflicting-id-\(index)-\(UUID().uuidString)", isDirectory: true)
            let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let projectSkill = root.appendingPathComponent(".agents/skills/skill-package", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: projectAgents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"Build Agent\"\n".write(to: projectAgents.appendingPathComponent("build-agent.toml"), atomically: true, encoding: .utf8)
            try "name = \"Other Agent\"\n".write(to: projectAgents.appendingPathComponent("other-agent.toml"), atomically: true, encoding: .utf8)
            try "---\nname: skill-package\n---\n".write(to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let registry = #"{"schemaVersion":5,"packages":["# + packages.joined(separator: ",") + #"]}"#
            try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let rootDescriptor = ScanRoot(id: "project-\(index)", url: root, scope: .project, kind: .projects)
            let output = ResourceScanner(roots: [rootDescriptor]).scan()
            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial], "array order \(index)")
            XCTAssertTrue(output.issues.contains { $0.message.contains("registry is invalid") }, "array order \(index)")
            let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
                .resolveWithIssues()
            XCTAssertTrue(report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty, "array order \(index)")
        }
    }

    func testLegacyRegistryReferencePrefersUniqueCanonicalTomlAgentWithoutDroppingLegacyIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-legacy-canonical-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "legacy-canonical", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let agents = output.resources.filter { $0.kind == .agent && $0.projectID == rootDescriptor.id }
        XCTAssertEqual(agents.count, 2)
        let canonical = try XCTUnwrap(agents.first { $0.relativeSourcePath == ".codex/agents/build.toml" })
        XCTAssertNotNil(agents.first { $0.relativeSourcePath == "agents/registry.json/Build Agent" })

        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(report.relations.first?.agentID, canonical.id)
    }

    func testLegacyRegistryReferenceRejectsMultipleCanonicalTomlAgents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-legacy-ambiguous-toml-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for stem in ["build-one", "build-two"] {
            try "name = \"Build Agent\"\n".write(
                to: projectAgents.appendingPathComponent("\(stem).toml"), atomically: true, encoding: .utf8)
        }
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "legacy-ambiguous", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()

        XCTAssertTrue(report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty)
        XCTAssertEqual(report.issues, [.init(kind: .ambiguousAgent, sourceRootID: rootDescriptor.id)])
    }

    func testLegacyRegistryMissingKindRemainsSupportedButExplicitUnknownAndWorkflowDoNotDeclareAgentRelations() throws {
        let registries: [(String, Bool)] = [
            (#"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#, true),
            (#"{"entries":[{"name":"Build Agent","type":"future-agent","usesSkills":["video-tool"]}]}"#, false),
            (#"{"entries":[{"name":"Build Agent","type":"workflow","usesSkills":["video-tool"]}]}"#, false),
        ]
        for (index, fixture) in registries.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-legacy-kind-\(index)-\(UUID().uuidString)", isDirectory: true)
            let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            for directory in [projectAgents, projectSkill, registryDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"Build Agent\"\n".write(
                to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
            try "---\nname: video-tool\n---\n".write(
                to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try fixture.0.write(
                to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let rootDescriptor = ScanRoot(id: "legacy-kind-\(index)", url: root, scope: .project, kind: .projects)
            let output = ResourceScanner(roots: [rootDescriptor]).scan()
            let relations = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
                .resolve()
                .filter { $0.declarationSource == .projectRegistry }
            XCTAssertEqual(relations.count, fixture.1 ? 1 : 0, "fixture \(index)")
            if index == 1 {
                XCTAssertFalse(output.resources.contains {
                    $0.relativeSourcePath == "agents/registry.json/Build Agent"
                })
            }
        }
    }

    func testPackageIDReferencesResolveOnlyThroughUniqueDeclaredCanonicalAliases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-package-alias-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":5,"packages":[{"kind":"agent","id":"agent-package","name":"Build Agent","usesSkills":["skill-package"]},{"kind":"skill","id":"skill-package","name":"video-tool","invokedBy":["agent-package"]},{"kind":"skill","id":"SKÍLL-PACKAGE","name":"VÍDEO-TOOL","invokedBy":["agent-package"]}]}"#
        try registry.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "package-alias", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()
        let agent = try XCTUnwrap(output.resources.first { $0.relativeSourcePath == ".codex/agents/build.toml" })
        let skill = try XCTUnwrap(output.resources.first { $0.relativeSourcePath == ".agents/skills/video-tool/SKILL.md" })

        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(report.relations.first?.agentID, agent.id)
        XCTAssertEqual(report.relations.first?.skillID, skill.id)
    }

    func testConflictingPackageIDAliasMappingsRejectRegistryIndependentOfArrayOrder() throws {
        let packageA = #"{"kind":"skill","id":"skill-package","name":"video-tool","invokedBy":["Build Agent"]}"#
        let packageB = #"{"kind":"skill","id":"SKÍLL-PACKAGE","name":"other-tool","invokedBy":["Build Agent"]}"#
        for (index, packages) in [[packageA, packageB], [packageB, packageA]].enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-package-alias-conflict-\(index)-\(UUID().uuidString)", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let registry = #"{"schemaVersion":5,"packages":["# + packages.joined(separator: ",") + #"]}"#
            try registry.write(
                to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let rootDescriptor = ScanRoot(id: "package-alias-conflict-\(index)", url: root, scope: .project, kind: .projects)
            let output = ResourceScanner(roots: [rootDescriptor]).scan()
            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial], "array order \(index)")
            XCTAssertTrue(output.issues.contains { $0.message.contains("registry is invalid") }, "array order \(index)")
        }
    }

    func testEquivalentSynonymFieldsAreAcceptedIndependentOfFieldOrder() throws {
        let registries = [
            #"{"schemaVersion":5,"packages":[{"kind":"agent","type":"AGENT","id":"agent-package","packageID":"AGÉNT-PACKAGE","name":"Build Agent","usesSkills":[{"id":"skill-package","name":"SKÍLL-PACKAGE"}]},{"kind":"skill","type":"SKILL","id":"skill-package","packageID":"SKÍLL-PACKAGE","name":"video-tool","invokedBy":[{"nativeAgent":"agent-package","id":"AGÉNT-PACKAGE","name":"agent-package"}]}]}"#,
            #"{"schemaVersion":5,"packages":[{"usesSkills":[{"name":"SKÍLL-PACKAGE","id":"skill-package"}],"name":"Build Agent","packageID":"AGÉNT-PACKAGE","id":"agent-package","type":"AGENT","kind":"agent"},{"invokedBy":[{"name":"agent-package","id":"AGÉNT-PACKAGE","nativeAgent":"agent-package"}],"name":"video-tool","packageID":"SKÍLL-PACKAGE","id":"skill-package","type":"SKILL","kind":"skill"}]}"#,
        ]

        for (index, registry) in registries.enumerated() {
            let result = try scanRegistryFixture(
                registry,
                rootID: "synonym-equivalent-\(index)"
            )
            XCTAssertEqual(result.output.historyScanBatch.scopes.map(\.coverage), [.complete])
            XCTAssertFalse(result.output.issues.contains { $0.message.contains("registry is invalid") })
            XCTAssertEqual(
                result.report.relations.filter { $0.declarationSource == .projectRegistry }.count,
                1
            )
        }
    }

    func testConflictingSynonymFieldsRejectRegistryIndependentOfFieldOrder() throws {
        let registries = [
            #"{"schemaVersion":5,"packages":[{"kind":"agent","id":"agent-one","packageID":"agent-two","name":"Build Agent","usesSkills":["skill-package"]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"agent","packageID":"agent-two","id":"agent-one","name":"Build Agent","usesSkills":["skill-package"]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"agent","type":"skill","id":"agent-package","name":"Build Agent","usesSkills":["skill-package"]}]}"#,
            #"{"schemaVersion":5,"packages":[{"type":"skill","kind":"agent","id":"agent-package","name":"Build Agent","usesSkills":["skill-package"]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"agent","id":"agent-package","name":"Build Agent","usesSkills":[{"id":"skill-package","name":"other-package"}]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"agent","id":"agent-package","name":"Build Agent","usesSkills":[{"name":"other-package","id":"skill-package"}]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"skill","id":"skill-package","name":"video-tool","invokedBy":[{"nativeAgent":"agent-package","id":"other-agent","name":"agent-package"}]}]}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"skill","id":"skill-package","name":"video-tool","invokedBy":[{"name":"agent-package","id":"other-agent","nativeAgent":"agent-package"}]}]}"#,
        ]

        for (index, registry) in registries.enumerated() {
            let result = try scanRegistryFixture(
                registry,
                rootID: "synonym-conflict-\(index)"
            )
            XCTAssertEqual(
                result.output.historyScanBatch.scopes.map(\.coverage),
                [.partial],
                "fixture \(index)"
            )
            XCTAssertTrue(
                result.output.issues.contains { $0.message.contains("registry is invalid") },
                "fixture \(index)"
            )
            XCTAssertTrue(
                result.report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty,
                "fixture \(index)"
            )
        }
    }

    func testMissingPrimaryRegistryUsesCompatibleRootRegistryAndRetainsLegacyIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-registry-fallback-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        for directory in [projectAgents, projectSkill] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#.write(
            to: root.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "registry-fallback", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let agents = output.resources.filter { $0.kind == .agent && $0.projectID == rootDescriptor.id }
        let canonical = try XCTUnwrap(agents.first { $0.relativeSourcePath == ".codex/agents/build.toml" })
        XCTAssertNotNil(agents.first { $0.relativeSourcePath == "registry.json/Build Agent" })

        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(report.relations.first?.agentID, canonical.id)
    }

    func testInvalidPrimaryRegistryDoesNotFallThroughToCompatibleRootRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-registry-shadow-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"entries":"invalid"}"#.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)
        try #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#.write(
            to: root.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "registry-shadow", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertTrue(report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty)
    }

    func testUnsupportedOversizedUnreadableAndOutOfRootPrimaryRegistriesDoNotUseCompatibleRootRegistry() throws {
        let fixtures: [(label: String, data: Data, readError: FileSystemReadError?)] = [
            ("unsupported", Data(#"{"schemaVersion":999,"packages":[]}"#.utf8), nil),
            ("oversized", Data(repeating: 0x20, count: CodexProjectRegistry.maximumByteCount + 1), nil),
            ("unreadable", Data(#"{"packages":[]}"#.utf8), .permissionDenied),
            ("outside-root", Data(#"{"packages":[]}"#.utf8), .outsideApprovedRoot),
        ]
        for fixture in fixtures {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("companion-registry-\(fixture.label)-\(UUID().uuidString)", isDirectory: true)
            let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            for directory in [projectAgents, projectSkill, registryDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"Build Agent\"\n".write(
                to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
            try "---\nname: video-tool\n---\n".write(
                to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let primaryURL = registryDirectory.appendingPathComponent("registry.json")
            try fixture.data.write(to: primaryURL)
            try #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]}]}"#.write(
                to: root.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let base = FileSystemClient()
            let client = fixture.readError != nil ? FileSystemClient(
                directoryReader: { base.enumerateDirectory($0) },
                dataReader: { base.readData($0) },
                attributesReader: { base.fileAttributes($0) },
                readableReader: { base.isReadable($0) },
                symbolicLinkReader: { base.isSymbolicLink($0) },
                verifiedDataReader: { url, approvedRoot, maximumByteCount in
                    if url.standardizedFileURL == primaryURL.standardizedFileURL,
                       let readError = fixture.readError {
                        return .failure(readError)
                    }
                    return base.readVerifiedData(
                        url, within: approvedRoot, maximumByteCount: maximumByteCount)
                },
                identityValidator: { base.validateDocumentRead($2, at: $0, within: $1) },
                directoryIdentityReader: { base.directoryIdentity($0) },
                directoryStatusReader: { base.directoryStatus($0) }
            ) : base
            let rootDescriptor = ScanRoot(
                id: "registry-\(fixture.label)", url: root, scope: .project, kind: .projects)
            let output = ResourceScanner(roots: [rootDescriptor], fileSystem: client).scan()
            let report = CapabilityCompanionResolver(
                resources: output.resources,
                roots: [rootDescriptor],
                fileSystem: client
            ).resolveWithIssues()

            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial], fixture.label)
            XCTAssertTrue(
                report.relations.filter { $0.declarationSource == .projectRegistry }.isEmpty,
                fixture.label
            )
        }
    }

    func testUnknownPackageKindDoesNotDeclareAgentRelation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-package-unknown-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":5,"packages":[{"kind":"future-agent","id":"Build Agent","usesSkills":["video-tool"]}]}"#
        try registry.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "package-unknown", url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let relations = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolve()

        XCTAssertTrue(relations.filter { $0.declarationSource == .projectRegistry }.isEmpty)
    }

    func testRelationIDUsesStableEndpointsAndDeclarationMetadata() {
        let first = CapabilityCompanionRelation(
            agentID: "agent:a", skillID: "skill:s", declarationSource: .agentBrief)
        let second = CapabilityCompanionRelation(
            agentID: "agent:b", skillID: "skill:s", declarationSource: .agentBrief)
        XCTAssertNotEqual(first.id, "(agentID)|(kind.rawValue)|(skillID)|(declarationSource.rawValue)")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.contains("agent:a"))
        XCTAssertTrue(first.id.contains("skill:s"))
    }

    func testAgentDirectiveCreatesExactCompanionRelationAndProjectSkillWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-(UUID().uuidString)")
        let globalAgentRoot = root.appendingPathComponent("agents")
        let globalSkillsRoot = root.appendingPathComponent("skills")
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: globalAgentRoot.appendingPathComponent("build-agent"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalSkillsRoot.appendingPathComponent("video-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".codex/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".agents/skills/video-tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Build Agent\nUse $video-tool for rendering.".write(to: globalAgentRoot.appendingPathComponent("build-agent/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Global skill\n---\n".write(to: globalSkillsRoot.appendingPathComponent("video-tool/SKILL.md"), atomically: true, encoding: .utf8)
        try "name = \"Build Agent\"\ndescription = \"Project agent\"\n# Use $video-tool locally\n".write(to: projectRoot.appendingPathComponent(".codex/agents/build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Project skill\n---\n".write(to: projectRoot.appendingPathComponent(".agents/skills/video-tool/SKILL.md"), atomically: true, encoding: .utf8)

        let globalAgent = makeResource(id: "agent:global", name: "Build Agent", kind: .agent, rootID: "global-agents", relative: "build-agent/agent.md")
        let globalSkill = makeResource(id: "skill:global", name: "video-tool", kind: .skill, rootID: "global-skills", relative: "video-tool/SKILL.md")
        let projectAgent = makeResource(id: "agent:project", name: "Build Agent", kind: .agent, rootID: "project", relative: ".codex/agents/build.toml", projectID: "project")
        let projectSkill = makeResource(id: "skill:project", name: "video-tool", kind: .skill, rootID: "project", relative: ".agents/skills/video-tool/SKILL.md", projectID: "project")

        let relations = CapabilityCompanionResolver(
            resources: [globalAgent, globalSkill, projectAgent, projectSkill],
            roots: [
                ScanRoot(id: "global-agents", url: globalAgentRoot, scope: .global, kind: .agents),
                ScanRoot(id: "global-skills", url: globalSkillsRoot, scope: .global, kind: .skills),
                ScanRoot(id: "project", url: projectRoot, scope: .project, kind: .projects)
            ]
        ).resolve()

        XCTAssertTrue(relations.contains {
            $0.agentID == projectAgent.id && $0.skillID == projectSkill.id && $0.declarationSource == .agentConfiguration
        })
        XCTAssertFalse(relations.contains { $0.agentID == projectAgent.id && $0.skillID == globalSkill.id })
        XCTAssertTrue(relations.contains {
            $0.agentID == globalAgent.id && $0.skillID == globalSkill.id && $0.declarationSource == .agentBrief
        })
    }

    func testGlobalAgentNeverFallsBackToProjectOnlySkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-global-scope-\(UUID().uuidString)")
        let agentsRoot = root.appendingPathComponent("agents")
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".agents/skills/project-only"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Build Agent\nUse $project-only for local work."
            .write(to: agentsRoot.appendingPathComponent("build/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: project-only\ndescription: Project-only utility\n---\n"
            .write(to: projectRoot.appendingPathComponent(".agents/skills/project-only/SKILL.md"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:global-only", name: "Build Agent", kind: .agent, rootID: "agents", relative: "build/agent.md")
        let projectSkill = makeResource(id: "skill:project-only", name: "project-only", kind: .skill, rootID: "project", relative: ".agents/skills/project-only/SKILL.md", projectID: "project")
        let report = CapabilityCompanionResolver(
            resources: [agent, projectSkill],
            roots: [
                ScanRoot(id: "agents", url: agentsRoot, scope: .global, kind: .agents),
                ScanRoot(id: "project", url: projectRoot, scope: .project, kind: .projects),
            ]
        ).resolveWithIssues()

        XCTAssertTrue(report.relations.isEmpty)
        XCTAssertTrue(report.issues.isEmpty, "a missing global candidate is not an ambiguity")
    }

    func testResolverExcludesPluginProvidedAgentsButKeepsPluginSkillDeclarationsOutOfEndpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-plugin-agent-\(UUID().uuidString)")
        let pluginRoot = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("agents/plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("skills/tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Plugin Agent\nUse $tool."
            .write(to: pluginRoot.appendingPathComponent("agents/plugin/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: tool\ndescription: Plugin utility\n---\n"
            .write(to: pluginRoot.appendingPathComponent("skills/tool/SKILL.md"), atomically: true, encoding: .utf8)

        let pluginAgent = CapabilityResource(
            id: "agent:plugin", name: "Plugin Agent", kind: .agent, status: .success,
            scope: .plugin, projectID: nil, confidence: .exact, summary: nil,
            sourceRootID: "runtime-plugins:demo", relativeSourcePath: "plugins/demo/agents/plugin/agent.md",
            sourcePathHash: nil, lastSeenAt: Date(), ownership: .pluginProvided, origin: .plugin
        )
        let pluginSkill = CapabilityResource(
            id: "skill:plugin", name: "tool", kind: .skill, status: .success,
            scope: .plugin, projectID: nil, confidence: .exact, summary: nil,
            sourceRootID: "runtime-plugins:demo", relativeSourcePath: "plugins/demo/skills/tool/SKILL.md",
            sourcePathHash: nil, lastSeenAt: Date(), ownership: .pluginProvided, origin: .plugin
        )
        let report = CapabilityCompanionResolver(
            resources: [pluginAgent, pluginSkill],
            roots: [],
            transientRoots: ["runtime-plugins:demo": pluginRoot]
        ).resolveWithIssues()

        XCTAssertTrue(report.relations.isEmpty)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testSkillDescriptionCreatesRequiresAgentAndArbitraryMentionDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-(UUID().uuidString)")
        let agentRoot = root.appendingPathComponent("agents")
        let skillsRoot = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: agentRoot.appendingPathComponent("product"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsRoot.appendingPathComponent("studio"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Product Architect\nThis document mentions studio but does not declare a skill.".write(to: agentRoot.appendingPathComponent("product/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: studio\ndescription: Use through Product Architect.\n---\n".write(to: skillsRoot.appendingPathComponent("studio/SKILL.md"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:product", name: "Product Architect", kind: .agent, rootID: "agents", relative: "product/agent.md")
        let skill = makeResource(id: "skill:studio", name: "studio", kind: .skill, rootID: "skills", relative: "studio/SKILL.md")
        let relations = CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [
                ScanRoot(id: "agents", url: agentRoot, scope: .global, kind: .agents),
                ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills)
            ]
        ).resolve()

        XCTAssertEqual(relations.count, 1)
        XCTAssertEqual(relations.first?.kind, .requiresAgent)
        XCTAssertEqual(relations.first?.declarationSource, .skillDescription)
        XCTAssertEqual(relations.first?.agentID, agent.id)
    }

    func testNegativeSkillDirectivesNeverCreateCompanionRelations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-negative-\(UUID().uuidString)")
        let agentRoot = root.appendingPathComponent("agents")
        let skillsRoot = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: agentRoot.appendingPathComponent("build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsRoot.appendingPathComponent("video-tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let negativeLines = [
            "Never use $video-tool.",
            "Never invoke $video-tool.",
            "Do not use $video-tool.",
            "Don't use $video-tool.",
            "Not $video-tool.",
            "禁止使用 $video-tool。",
            "不得调用 $video-tool。",
            "不要使用 $video-tool。",
            "不可使用 $video-tool。",
            "不应调用 $video-tool。",
            "无需使用 $video-tool。",
        ]
        try ("# Build Agent\n" + negativeLines.joined(separator: "\n"))
            .write(to: agentRoot.appendingPathComponent("build/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: skillsRoot.appendingPathComponent("video-tool/SKILL.md"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:build", name: "Build Agent", kind: .agent, rootID: "agents", relative: "build/agent.md")
        let skill = makeResource(id: "skill:video", name: "video-tool", kind: .skill, rootID: "skills", relative: "video-tool/SKILL.md")
        let relations = CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [
                ScanRoot(id: "agents", url: agentRoot, scope: .global, kind: .agents),
                ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills),
            ]
        ).resolve()
        XCTAssertTrue(relations.isEmpty)
    }

    func testSkillRelationshipOnlyReadsFrontmatterDescription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-frontmatter-\(UUID().uuidString)")
        let agentRoot = root.appendingPathComponent("agents")
        let skillsRoot = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: agentRoot.appendingPathComponent("brand"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsRoot.appendingPathComponent("logo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Brand Designer\nPurpose."
            .write(to: agentRoot.appendingPathComponent("brand/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: logo\ntags: Use through Brand Designer.\ndescription: A logo utility.\n---\n\nBody says Use through Brand Designer, but is not a declaration."
            .write(to: skillsRoot.appendingPathComponent("logo/SKILL.md"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:brand", name: "Brand Designer", kind: .agent, rootID: "agents", relative: "brand/agent.md")
        let skill = makeResource(id: "skill:logo", name: "logo", kind: .skill, rootID: "skills", relative: "logo/SKILL.md")
        let noRelation = CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [
                ScanRoot(id: "agents", url: agentRoot, scope: .global, kind: .agents),
                ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills),
            ]
        ).resolve()
        XCTAssertTrue(noRelation.isEmpty)

        try "---\nname: logo\ndescription: Use through Brand Designer to create the mark.\n---\n"
            .write(to: skillsRoot.appendingPathComponent("logo/SKILL.md"), atomically: true, encoding: .utf8)
        let relation = CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [
                ScanRoot(id: "agents", url: agentRoot, scope: .global, kind: .agents),
                ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills),
            ]
        ).resolve()
        XCTAssertEqual(relation.count, 1)
        XCTAssertEqual(relation.first?.agentID, agent.id)
    }

    func testRuntimePluginSkillUsesValidatedTransientRootForFrontmatter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-runtime-plugin-\(UUID().uuidString)")
        let agentsRoot = root.appendingPathComponent("agents")
        let pluginRoot = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("brand"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("skills/logo"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Brand Designer\nPurpose."
            .write(to: agentsRoot.appendingPathComponent("brand/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: logo\ndescription: Use through Brand Designer to create the mark.\n---\n"
            .write(to: pluginRoot.appendingPathComponent("skills/logo/SKILL.md"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:brand-runtime", name: "Brand Designer", kind: .agent, rootID: "agents", relative: "brand/agent.md")
        let pluginSkill = CapabilityResource(
            id: "skill:runtime-logo", name: "logo", kind: .skill, status: .success,
            scope: .plugin, projectID: nil, confidence: .exact, summary: "Use through Brand Designer to create the mark.",
            sourceRootID: "runtime-plugins:demo", relativeSourcePath: "plugins/demo/skills/logo/SKILL.md",
            sourcePathHash: nil, lastSeenAt: Date(), ownership: .pluginProvided, origin: .plugin
        )
        let relations = CapabilityCompanionResolver(
            resources: [agent, pluginSkill],
            roots: [ScanRoot(id: "agents", url: agentsRoot, scope: .global, kind: .agents)],
            transientRoots: ["runtime-plugins:demo": pluginRoot]
        ).resolve()

        XCTAssertEqual(relations.count, 1)
        XCTAssertEqual(relations.first?.skillID, pluginSkill.id)
        XCTAssertEqual(relations.first?.declarationSource, .skillDescription)
    }

    func testGenericSkillMentionWithoutPositiveDirectiveFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-generic-skill-\(UUID().uuidString)")
        let agentsRoot = root.appendingPathComponent("agents")
        let skillsRoot = root.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsRoot.appendingPathComponent("video-tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Build Agent\nThe $video-tool skill is available, but no invocation is declared."
            .write(to: agentsRoot.appendingPathComponent("build/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: skillsRoot.appendingPathComponent("video-tool/SKILL.md"), atomically: true, encoding: .utf8)
        let agent = makeResource(id: "agent:build-generic", name: "Build Agent", kind: .agent, rootID: "agents", relative: "build/agent.md")
        let skill = makeResource(id: "skill:video-generic", name: "video-tool", kind: .skill, rootID: "skills", relative: "video-tool/SKILL.md")
        XCTAssertTrue(CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [
                ScanRoot(id: "agents", url: agentsRoot, scope: .global, kind: .agents),
                ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills),
            ]
        ).resolve().isEmpty)
    }

    func testAmbiguousSkillReferenceFailsClosedAndReportsSafeIssue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-ambiguous-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let skillsA = root.appendingPathComponent("skills-a")
        let skillsB = root.appendingPathComponent("skills-b")
        for directory in [agents.appendingPathComponent("build"), skillsA.appendingPathComponent("same"), skillsB.appendingPathComponent("same")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Build Agent\nUse $same."
            .write(to: agents.appendingPathComponent("build/agent.md"), atomically: true, encoding: .utf8)
        for skills in [skillsA, skillsB] {
            try "---\nname: same\ndescription: Same\n---\n"
                .write(to: skills.appendingPathComponent("same/SKILL.md"), atomically: true, encoding: .utf8)
        }
        let agent = makeResource(id: "agent:build", name: "Build Agent", kind: .agent, rootID: "agents", relative: "build/agent.md")
        let skillA = makeResource(id: "skill:a", name: "same", kind: .skill, rootID: "skills-a", relative: "same/SKILL.md")
        let skillB = makeResource(id: "skill:b", name: "same", kind: .skill, rootID: "skills-b", relative: "same/SKILL.md")
        let report = CapabilityCompanionResolver(
            resources: [agent, skillA, skillB],
            roots: [
                ScanRoot(id: "agents", url: agents, scope: .global, kind: .agents),
                ScanRoot(id: "skills-a", url: skillsA, scope: .global, kind: .skills),
                ScanRoot(id: "skills-b", url: skillsB, scope: .global, kind: .skills),
            ]
        ).resolveWithIssues()
        XCTAssertTrue(report.relations.isEmpty)
        XCTAssertEqual(report.issues, [.init(kind: .ambiguousSkill, sourceRootID: "agents")])
    }

    func testRegistryInvokedByOnSkillCreatesInverseProjectRelation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-(UUID().uuidString)")
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".codex/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".agents/skills/video-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("agents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "name = \"Build Agent\"\n".write(to: projectRoot.appendingPathComponent(".codex/agents/build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Render videos\n---\n".write(to: projectRoot.appendingPathComponent(".agents/skills/video-tool/SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":3,"packages":{"video-tool":{"type":"skill","invokedBy":["Build Agent"]}}}"#
        try registry.write(to: projectRoot.appendingPathComponent("agents/registry.json"), atomically: true, encoding: .utf8)

        let agent = makeResource(id: "agent:project", name: "Build Agent", kind: .agent, rootID: "project", relative: ".codex/agents/build.toml", projectID: "project")
        let skill = makeResource(id: "skill:project", name: "video-tool", kind: .skill, rootID: "project", relative: ".agents/skills/video-tool/SKILL.md", projectID: "project")
        let relations = CapabilityCompanionResolver(
            resources: [agent, skill],
            roots: [ScanRoot(id: "project", url: projectRoot, scope: .project, kind: .projects)]
        ).resolve()

        XCTAssertTrue(relations.contains {
            $0.agentID == agent.id && $0.skillID == skill.id && $0.declarationSource == .projectRegistry
        })
        XCTAssertFalse(relations.contains { $0.agentID == skill.id || $0.skillID == agent.id })
    }

    func testLegacyRegistryEntriesPreserveUsesSkillsAndInvokedByDirections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-legacy-entries-\(UUID().uuidString)")
        let projectAgents = root.appendingPathComponent(".codex/agents")
        let projectSkills = root.appendingPathComponent(".agents/skills/video-tool")
        let registryDirectory = root.appendingPathComponent("agents")
        for directory in [projectAgents, projectSkills, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"entries":[{"name":"Build Agent","usesSkills":["video-tool"]},{"name":"video-tool","type":"skill","invokedBy":["Build Agent"]}]}"#
        try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: "legacy-project", url: root, scope: .project, kind: .projects)
        let agent = makeResource(
            id: "agent:legacy-project", name: "Build Agent", kind: .agent,
            rootID: "legacy-project", relative: ".codex/agents/build.toml", projectID: "legacy-project")
        let skill = makeResource(
            id: "skill:legacy-project", name: "video-tool", kind: .skill,
            rootID: "legacy-project", relative: ".agents/skills/video-tool/SKILL.md", projectID: "legacy-project")

        let report = CapabilityCompanionResolver(
            resources: [agent, skill], roots: [rootDescriptor]
        ).resolveWithIssues()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(report.relations.first?.agentID, agent.id)
        XCTAssertEqual(report.relations.first?.skillID, skill.id)
    }

    func testCoObservationIsSeparateDistinctSessionEvidence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let event = InvocationEvent(
            id: "call:agent",
            sessionID: "session:one",
            parentCallID: nil,
            ordinal: 1,
            timestamp: now,
            actorName: nil,
            resourceID: "agent:a",
            kind: .agent,
            status: .completed,
            durationMs: nil,
            confidence: .exact,
            errorCategory: nil
        )
        let skillEvent = InvocationEvent(
            id: "call:skill",
            sessionID: "session:one",
            parentCallID: nil,
            ordinal: 2,
            timestamp: now,
            actorName: nil,
            resourceID: "skill:s",
            kind: .skill,
            status: .completed,
            durationMs: nil,
            confidence: .exact,
            errorCategory: nil
        )
        let session = TaskSummary(
            id: "session:one",
            projectID: nil,
            startedAt: now,
            endedAt: now,
            status: .completed,
            coverage: .complete,
            parserVersion: "1",
            sourceFileID: "synthetic",
            title: nil
        )
        let stats = CapabilityCompanionUsageStats.calculate(
            agentID: "agent:a",
            skillID: "skill:s",
            invocationsBySession: ["session:one": [event, skillEvent]],
            sessions: [session],
            window: CapabilityQueryWindow(start: now.addingTimeInterval(-10), end: now)
        )
        XCTAssertEqual(stats.sessionCount, 1)
        XCTAssertEqual(stats.coverage, .complete)
        XCTAssertEqual(stats.lastObservedAt, now)
    }

    func testZeroCoObservationRetainsPartialCoverageFromRelevantSessions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = CapabilityQueryWindow(start: now.addingTimeInterval(-10), end: now)
        let agentEvent = InvocationEvent(id: "call:agent", sessionID: "session:one", parentCallID: nil, ordinal: 1, timestamp: now, actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let skillEvent = InvocationEvent(id: "call:skill", sessionID: "session:two", parentCallID: nil, ordinal: 1, timestamp: now, actorName: nil, resourceID: "skill:s", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil)
        let sessionOne = TaskSummary(id: "session:one", projectID: nil, startedAt: now, endedAt: now, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "one", title: nil)
        let sessionTwo = TaskSummary(id: "session:two", projectID: nil, startedAt: now, endedAt: now, status: .completed, coverage: .partial, parserVersion: "1", sourceFileID: "two", title: nil)

        let stats = CapabilityCompanionUsageStats.calculate(
            agentID: "agent:a", skillID: "skill:s",
            invocationsBySession: ["session:one": [agentEvent], "session:two": [skillEvent]],
            sessions: [sessionOne, sessionTwo], window: window)

        XCTAssertEqual(stats.sessionCount, 0)
        XCTAssertNil(stats.lastObservedAt)
        XCTAssertEqual(stats.coverage, .partial)
    }

    func testNoCallsWithCompleteSessionReportsZeroInsteadOfUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let relation = CapabilityCompanionRelation(
            agentID: "agent:a",
            skillID: "skill:s",
            declarationSource: .agentBrief
        )
        let session = TaskSummary(
            id: "session:empty",
            projectID: nil,
            startedAt: now,
            endedAt: now,
            status: .completed,
            coverage: .complete,
            parserVersion: "1",
            sourceFileID: "empty",
            title: nil
        )
        let stats = CapabilityCompanionUsageStats.calculateBatch(
            relations: [relation],
            invocationsBySession: [:],
            sessions: [session],
            window: CapabilityQueryWindow(start: now.addingTimeInterval(-10), end: now)
        )[relation.id]

        XCTAssertEqual(stats?.sessionCount, 0)
        XCTAssertNil(stats?.lastObservedAt)
        XCTAssertEqual(stats?.coverage, .complete)
    }

    func testBatchUsageProjectionComputesEveryRelationFromOneEvidenceSnapshot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = CapabilityQueryWindow(start: now.addingTimeInterval(-10), end: now)
        let session = TaskSummary(id: "session:batch", projectID: nil, startedAt: now, endedAt: now, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "batch", title: nil)
        let events = [
            InvocationEvent(id: "a", sessionID: session.id, parentCallID: nil, ordinal: 1, timestamp: now, actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "s", sessionID: session.id, parentCallID: nil, ordinal: 2, timestamp: now, actorName: nil, resourceID: "skill:s", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "b", sessionID: session.id, parentCallID: nil, ordinal: 3, timestamp: now, actorName: nil, resourceID: "agent:b", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
        ]
        let relations = [
            CapabilityCompanionRelation(agentID: "agent:a", skillID: "skill:s", declarationSource: .agentBrief),
            CapabilityCompanionRelation(agentID: "agent:b", skillID: "skill:s", declarationSource: .projectRegistry),
        ]
        let result = CapabilityCompanionUsageStats.calculateBatch(
            relations: relations,
            invocationsBySession: [session.id: events],
            sessions: [session],
            window: window
        )
        XCTAssertEqual(result[relations[0].id]?.sessionCount, 1)
        XCTAssertEqual(result[relations[1].id]?.sessionCount, 1)
        XCTAssertEqual(result[relations[0].id]?.coverage, .complete)
        XCTAssertEqual(result[relations[0].id]?.lastObservedAt, now)
    }

    func testLastObservedUsesLatestEndpointEventNotUnrelatedLaterEvent() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let session = TaskSummary(id: "session:last-observed", projectID: nil, startedAt: base, endedAt: base.addingTimeInterval(20), status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "last", title: nil)
        let events = [
            InvocationEvent(id: "agent", sessionID: session.id, parentCallID: nil, ordinal: 1, timestamp: base.addingTimeInterval(1), actorName: nil, resourceID: "agent:a", kind: .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "skill", sessionID: session.id, parentCallID: nil, ordinal: 2, timestamp: base.addingTimeInterval(2), actorName: nil, resourceID: "skill:s", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
            InvocationEvent(id: "other", sessionID: session.id, parentCallID: nil, ordinal: 3, timestamp: base.addingTimeInterval(19), actorName: nil, resourceID: "skill:other", kind: .skill, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil),
        ]
        let relation = CapabilityCompanionRelation(agentID: "agent:a", skillID: "skill:s", declarationSource: .agentBrief)
        let stats = CapabilityCompanionUsageStats.calculateBatch(
            relations: [relation], invocationsBySession: [session.id: events], sessions: [session],
            window: CapabilityQueryWindow(start: base, end: base.addingTimeInterval(20))
        )[relation.id]

        XCTAssertEqual(stats?.sessionCount, 1)
        XCTAssertEqual(stats?.lastObservedAt, base.addingTimeInterval(2))
    }

    private func makeResource(
        id: String,
        name: String,
        kind: ResourceKind,
        rootID: String,
        relative: String,
        projectID: String? = nil
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: kind,
            status: .unknown,
            scope: projectID == nil ? .global : .project,
            projectID: projectID,
            confidence: .exact,
            summary: nil,
            sourceRootID: rootID,
            relativeSourcePath: relative,
            sourcePathHash: nil,
            lastSeenAt: Date(),
            ownership: .userOwned,
            origin: .local
        )
    }

    private func scanRegistryFixture(
        _ registry: String,
        rootID: String
    ) throws -> (output: DiscoveryOutput, report: CapabilityCompanionResolutionReport) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-registry-synonyms-\(UUID().uuidString)", isDirectory: true)
        let projectAgents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectSkill = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        for directory in [projectAgents, projectSkill, registryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Build Agent\"\n".write(
            to: projectAgents.appendingPathComponent("build.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try registry.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let rootDescriptor = ScanRoot(id: rootID, url: root, scope: .project, kind: .projects)
        let output = ResourceScanner(roots: [rootDescriptor]).scan()
        let report = CapabilityCompanionResolver(resources: output.resources, roots: [rootDescriptor])
            .resolveWithIssues()
        return (output, report)
    }
}
