import XCTest
@testable import DirectorCore

final class CapabilityFolderTests: XCTestCase {
    func testMakeMemoryIsolatedFromStandardDefaultsAndOtherStores() throws {
        let key = CapabilityFolderStore.defaultsKey
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let first = CapabilityFolderStore.makeMemory()
        let second = CapabilityFolderStore.makeMemory()
        _ = try first.ensureInitialized()
        XCTAssertEqual(first.preferencesState(), .valid)
        XCTAssertEqual(second.preferencesState(), .missing)
        XCTAssertNil(UserDefaults.standard.data(forKey: key))
    }

    func testMissingStoreInitializesOnlySelfTrainingFolder() throws {
        var newData: Data?
        var legacyRemoved = false
        let store = CapabilityFolderStore(
            readData: { newData },
            writeData: { newData = $0; return true },
            removeData: { newData = nil },
            removeLegacyData: { legacyRemoved = true }
        )

        let preferences = try store.ensureInitialized()

        XCTAssertEqual(preferences.customFolders.map(\.id), [CapabilityFolderDefinition.selfTrainingID])
        XCTAssertTrue(preferences.memberships.isEmpty)
        XCTAssertTrue(legacyRemoved)
        XCTAssertEqual(store.preferencesState(), .valid)
    }

    func testFailedInitializationDoesNotRemoveLegacyData() {
        var legacyRemoved = false
        let store = CapabilityFolderStore(
            readData: { nil },
            writeData: { _ in false },
            removeData: {},
            removeLegacyData: { legacyRemoved = true }
        )

        XCTAssertThrowsError(try store.ensureInitialized()) { error in
            XCTAssertEqual(error as? CapabilityFolderStoreError, .persistenceFailed)
        }
        XCTAssertFalse(legacyRemoved)
    }

    func testSelfTrainingDoesNotImplicitlySeedCapabilitiesOrChangeMemberships() {
        let userAgent = resource(id: "agent:user", name: "User Agent", kind: .agent, ownership: .userOwned)
        let userSkill = resource(id: "skill:user", name: "User Skill", kind: .skill, ownership: .userOwned)
        let installedSkill = resource(id: "skill:installed", name: "Installed Skill", kind: .skill, ownership: .installed)
        let pluginSkill = resource(id: "skill:plugin", name: "Plugin Skill", kind: .skill, ownership: .pluginProvided, scope: .plugin)
        let instruction = resource(id: "instruction:user", name: "Instructions", kind: .instruction, ownership: .userOwned)
        let customFolder = CapabilityFolderDefinition(id: "custom", source: .custom, customName: "Custom")
        let preferences = CapabilityFolderPreferencesV1(
            customFolders: [
                CapabilityFolderDefinition(id: CapabilityFolderDefinition.selfTrainingID, source: .selfTraining),
                customFolder,
            ],
            memberships: [.init(folderID: customFolder.id, resourceID: userAgent.id)]
        )

        let unchanged = preferences.applyingInitialSelfTrainingMemberships(
            from: [userAgent, userSkill, installedSkill, pluginSkill, instruction]
        )

        XCTAssertEqual(unchanged, preferences)
    }

    func testSelfTrainingDoesNotRecreateDeletedFolder() {
        let userAgent = resource(id: "agent:user", name: "User Agent", kind: .agent, ownership: .userOwned)
        let preferences = CapabilityFolderPreferencesV1(customFolders: [])

        let seeded = preferences.applyingInitialSelfTrainingMemberships(from: [userAgent])

        XCTAssertTrue(seeded.customFolders.isEmpty)
        XCTAssertTrue(seeded.memberships.isEmpty)
        XCTAssertNil(seeded.selfTrainingSeedVersion)
    }

    func testLegacyFolderPreferencesDecodeWithoutSelfTrainingSeedMarker() throws {
        let legacyJSON = #"{"version":1,"initialized":true,"customFolders":[{"id":"self-training","source":"selfTraining"}],"memberships":[]}"#

        let decoded = try JSONDecoder().decode(
            CapabilityFolderPreferencesV1.self,
            from: try XCTUnwrap(legacyJSON.data(using: .utf8))
        )

        XCTAssertNil(decoded.selfTrainingSeedVersion)
        XCTAssertEqual(decoded.customFolders.map(\.id), [CapabilityFolderDefinition.selfTrainingID])
    }

    func testProjectionSupportsMultipleCustomMembershipsAndDefaultOwnership() {
        let globalAgent = resource(id: "agent:global", name: "Global Agent", kind: .agent, ownership: .userOwned)
        let projectSkill = resource(id: "skill:project", name: "Project Skill", kind: .skill, ownership: .installed, projectID: "project-a", scope: .project)
        let pluginSkill = resource(id: "skill:plugin", name: "Plugin Skill", kind: .skill, ownership: .pluginProvided, projectID: nil, scope: .plugin)
        let customA = CapabilityFolderDefinition(id: "custom-a", source: .custom, customName: "One")
        let customB = CapabilityFolderDefinition(id: "custom-b", source: .custom, customName: "Two")
        let preferences = CapabilityFolderPreferencesV1(
            customFolders: [customA, customB],
            memberships: [
                .init(folderID: customA.id, resourceID: globalAgent.id),
                .init(folderID: customB.id, resourceID: globalAgent.id),
                .init(folderID: customA.id, resourceID: projectSkill.id)
            ]
        )
        let projection = CapabilityFolderProjection(
            resources: [globalAgent, projectSkill, pluginSkill],
            projects: [CapabilityProject(id: "project-a", name: "Project A")],
            preferences: preferences
        )

        XCTAssertEqual(projection.folders.map(\.id), ["custom-a", "custom-b", "global", "project::project-a"])
        XCTAssertEqual(Set(projection.members(in: "custom-a").map(\.id)), [globalAgent.id, projectSkill.id])
        XCTAssertEqual(projection.members(in: "custom-b").map(\.id), [globalAgent.id])
        XCTAssertEqual(Set(projection.members(in: "global").map(\.id)), [globalAgent.id, pluginSkill.id])
        XCTAssertEqual(projection.members(in: "project::project-a").map(\.id), [projectSkill.id])
        XCTAssertEqual(projection.allUniqueResourceCount, 3)
    }

    func testPluginAgentsAreExcludedButPluginSkillsRemainGlobalAndOutOfRelations() {
        let pluginAgent = resource(id: "agent:plugin", name: "Plugin Agent", kind: .agent, ownership: .pluginProvided, scope: .plugin)
        let pluginSkill = resource(id: "skill:plugin", name: "Plugin Skill", kind: .skill, ownership: .pluginProvided, scope: .plugin)
        let customFolder = CapabilityFolderDefinition(id: "custom", source: .custom, customName: "Custom")
        let preferences = CapabilityFolderPreferencesV1(
            customFolders: [customFolder],
            memberships: [
                .init(folderID: customFolder.id, resourceID: pluginAgent.id),
                .init(folderID: customFolder.id, resourceID: pluginSkill.id)
            ]
        )
        let relation = ResourceRelation(
            sourceResourceID: pluginAgent.id,
            targetResourceID: pluginSkill.id,
            relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue,
            confidence: .exact,
            evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue
        )
        let projection = CapabilityFolderProjection(
            resources: [pluginAgent, pluginSkill],
            preferences: preferences,
            relations: [relation]
        )

        XCTAssertEqual(projection.resources.map(\.id), [pluginSkill.id])
        XCTAssertEqual(projection.members(in: CapabilityFolderDefinition.globalID).map(\.id), [pluginSkill.id])
        XCTAssertEqual(projection.members(in: customFolder.id).map(\.id), [pluginSkill.id])
        XCTAssertTrue(projection.companionRelations.isEmpty)
        XCTAssertEqual(projection.agentCount, 0)
        XCTAssertEqual(projection.skillCount, 1)
    }

    func testPairedAgentRefreshKeepsHistoricalBriefMembership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-folder-paired-agent-\(UUID().uuidString)", isDirectory: true)
        let briefDirectory = root.appendingPathComponent("video-director", isDirectory: true)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let skillDirectory = skillsRoot.appendingPathComponent("video-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Video Director\n\nUse $video-tool for delivery."
            .write(to: briefDirectory.appendingPathComponent("agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let agentRoot = ScanRoot(id: "agents", url: root, scope: .global, kind: .agents)
        let skillRoot = ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills)
        let historicalID = try XCTUnwrap(ResourceScanner(roots: [agentRoot]).scan().resources.first?.id)

        try "name = \"Video Director\"\ndeveloper_instructions = \"Use $video-tool for production.\"\n"
            .write(to: root.appendingPathComponent("video.toml"), atomically: true, encoding: .utf8)
        let refreshed = ResourceScanner(roots: [agentRoot, skillRoot]).scan()
        let refreshedAgent = try XCTUnwrap(refreshed.resources.first { $0.kind == .agent })
        XCTAssertEqual(refreshedAgent.id, historicalID)
        XCTAssertEqual(refreshedAgent.relativeSourcePath, "video-director/agent.md")

        let preferences = CapabilityFolderPreferencesV1(
            customFolders: [.init(id: CapabilityFolderDefinition.selfTrainingID, source: .selfTraining)],
            memberships: [.init(folderID: CapabilityFolderDefinition.selfTrainingID, resourceID: historicalID)]
        )
        let store = CapabilityFolderStore(memoryPreferences: preferences)
        let projection = CapabilityFolderProjection(
            resources: refreshed.resources,
            preferences: store.preferences()
        )
        XCTAssertEqual(projection.members(in: CapabilityFolderDefinition.selfTrainingID).map(\.id), [historicalID])
    }

    func testDuplicateDeclarationsCollapseToOneLogicalCompanionPair() {
        let agent = resource(id: "agent:pair", name: "Pair Agent", kind: .agent, ownership: .userOwned)
        let skill = resource(id: "skill:pair", name: "Pair Skill", kind: .skill, ownership: .userOwned)
        let relations = [
            ResourceRelation(sourceResourceID: agent.id, targetResourceID: skill.id, relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.agentConfiguration.rawValue),
            ResourceRelation(sourceResourceID: agent.id, targetResourceID: skill.id, relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue),
            ResourceRelation(sourceResourceID: agent.id, targetResourceID: skill.id, relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.projectRegistry.rawValue),
        ]
        let projection = CapabilityFolderProjection(resources: [agent, skill], relations: relations)

        XCTAssertEqual(projection.companionRelations.count, 1)
        XCTAssertEqual(projection.companionRelations.first?.pairID, "agent:pair|skill:pair")
    }

    func testPreferencesRejectDuplicateNamesAndUnknownMembershipFolders() throws {
        let duplicateName = CapabilityFolderPreferencesV1(
            customFolders: [
                .init(id: "a", source: .custom, customName: "One"),
                .init(id: "b", source: .custom, customName: "one")
            ]
        )
        let duplicateStore = CapabilityFolderStore(memoryPreferences: duplicateName)
        XCTAssertEqual(duplicateStore.preferencesState(), .corrupted)

        let unknownMembership = CapabilityFolderPreferencesV1(
            customFolders: [.init(id: "a", source: .custom, customName: "One")],
            memberships: [.init(folderID: "missing", resourceID: "agent:one")]
        )
        let unknownStore = CapabilityFolderStore(memoryPreferences: unknownMembership)
        XCTAssertEqual(unknownStore.preferencesState(), .corrupted)
    }

    func testDeletedFolderDoesNotRemoveCapability() {
        let resource = resource(id: "agent:one", name: "One", kind: .agent, ownership: .userOwned)
        let folder = CapabilityFolderDefinition(id: "custom", source: .custom, customName: "One")
        let preferences = CapabilityFolderPreferencesV1(customFolders: [folder], memberships: [.init(folderID: folder.id, resourceID: resource.id)])
        let projection = CapabilityFolderProjection(resources: [resource], preferences: preferences)
        XCTAssertEqual(projection.resources.map(\.id), [resource.id])
        XCTAssertEqual(projection.members(in: folder.id).map(\.id), [resource.id])

        let afterDelete = CapabilityFolderProjection(resources: [resource], preferences: .init())
        XCTAssertEqual(afterDelete.resources.map(\.id), [resource.id])
        XCTAssertTrue(afterDelete.members(in: folder.id).isEmpty)
    }

    func testDuplicateProjectNamesReceiveShortStableIDs() {
        let first = resource(id: "agent:first", name: "First", kind: .agent, ownership: .userOwned, projectID: "project-one", scope: .project)
        let second = resource(id: "agent:second", name: "Second", kind: .agent, ownership: .userOwned, projectID: "project-two", scope: .project)
        let projection = CapabilityFolderProjection(
            resources: [first, second],
            projects: [
                CapabilityProject(id: "project-one", name: "Portfolio"),
                CapabilityProject(id: "project-two", name: "Portfolio")
            ]
        )

        let projectNames = projection.folders.filter { $0.source == .project }.map(\.projectName)
        XCTAssertEqual(Set(projectNames), Set(["Portfolio · projecto", "Portfolio · projectt"]))
    }

    private func resource(
        id: String,
        name: String,
        kind: ResourceKind,
        ownership: ResourceOwnership,
        projectID: String? = nil,
        scope: ResourceScope = .global
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: name,
            kind: kind,
            status: .unknown,
            scope: scope,
            projectID: projectID,
            confidence: .exact,
            summary: "Synthetic purpose",
            sourceRootID: "synthetic",
            relativeSourcePath: "safe",
            sourcePathHash: "hash",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            ownership: ownership,
            origin: .local
        )
    }
}
