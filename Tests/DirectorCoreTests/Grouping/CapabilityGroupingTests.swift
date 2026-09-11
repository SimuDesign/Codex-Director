import XCTest
@testable import DirectorCore

final class CapabilityGroupingTests: XCTestCase {
    func testBuiltInGroupsAreStableAndOrdered() {
        XCTAssertEqual(BuiltInCapabilityGroup.allCases.count, 8)
        XCTAssertEqual(BuiltInCapabilityGroup.allCases.map(\.id), [
            "video-production", "ui-design", "software-development", "content-creation",
            "research-data", "automation-productivity", "general-tools", "uncategorized"
        ])
        XCTAssertEqual(CapabilityGroupDefinition.builtInDefinitions.count, 8)
    }

    func testClassifierIsDeterministicAndAmbiguityFallsBack() {
        let classifier = CapabilityGroupingClassifier()
        XCTAssertEqual(classifier.classify(name: "video-editor", summary: "Edit footage"), .videoProduction)
        XCTAssertEqual(classifier.classify(name: "figma-editor", summary: "Create UI prototypes"), .uiDesign)
        XCTAssertEqual(classifier.classify(name: "software-engineer", summary: "Implement Swift code"), .softwareDevelopment)
        XCTAssertEqual(classifier.classify(name: "视频剪辑", summary: nil), .videoProduction)
        XCTAssertEqual(classifier.classify(name: "界面设计", summary: "用户体验原型"), .uiDesign)
        XCTAssertEqual(classifier.classify(name: "数据分析", summary: "研究报告"), .researchData)
        XCTAssertEqual(classifier.classify(name: "mystery", summary: "A useful thing"), .uncategorized)
        XCTAssertEqual(classifier.classify(name: "frontend-developer", summary: nil), .uncategorized)
    }

    func testSingleGenericEvidenceAndAmbiguousEvidenceRemainUncategorized() {
        let classifier = CapabilityGroupingClassifier()
        for name in ["video", "data", "writing", "analysis", "app", "design"] {
            XCTAssertEqual(classifier.classify(name: name, summary: nil), .uncategorized, name)
            XCTAssertEqual(classifier.classify(name: name, summary: name), .uncategorized, "repeated generic evidence: \(name)")
        }
        XCTAssertEqual(classifier.classify(name: "helper", summary: "A useful app"), .uncategorized)
        XCTAssertEqual(classifier.classify(name: "tool", summary: "A generic thing"), .uncategorized)
        XCTAssertEqual(classifier.classify(name: "video", summary: "Edit video footage"), .videoProduction)
        XCTAssertEqual(classifier.classify(name: "data", summary: "Data analysis"), .uncategorized)
        XCTAssertEqual(classifier.classify(name: "design", summary: "UI"), .uncategorized)
    }

    func testManualAssignmentsOverrideEphemeralAutomaticProjection() {
        let classifier = CapabilityGroupingClassifier()
        let custom = CapabilityGroupDefinition(id: "custom-one", name: "My Work")
        let resource = resource(id: "skill:one", name: "video-editor", kind: .skill, ownership: .installed)
        let automatic = CapabilityGroupingProjection(resources: [resource], preferences: .init(customGroups: [custom]), classifier: classifier)
        XCTAssertEqual(automatic.members.first?.source, .automatic)
        XCTAssertEqual(automatic.members.first?.group.builtIn, .videoProduction)

        let manual = CapabilityGroupingProjection(
            resources: [resource],
            preferences: .init(customGroups: [custom], manualAssignments: [
                .init(resourceID: resource.id, groupID: custom.id, source: .manual)
            ]),
            classifier: classifier
        )
        XCTAssertEqual(manual.members.first?.source, .manual)
        XCTAssertEqual(manual.members.first?.group.id, custom.id)
    }

    func testCustomGroupsPrecedeTheFinalUncategorizedSection() {
        let custom = CapabilityGroupDefinition(id: "custom-one", name: "My Work")
        let projection = CapabilityGroupingProjection(
            resources: [],
            preferences: .init(customGroups: [custom])
        )

        XCTAssertEqual(projection.groups.dropLast().last?.id, custom.id)
        XCTAssertEqual(projection.groups.last?.builtIn, .uncategorized)
    }

    func testStoreRoundTripsOnlyV1PreferencesAndCorruptDataResets() throws {
        var data: Data?
        let store = CapabilityGroupingStore(
            readData: { data },
            writeData: { data = $0; return true },
            removeData: { data = nil }
        )
        let group = CapabilityGroupDefinition(id: "custom-one", name: "My Work")
        let prefs = CapabilityGroupingPreferencesV1(
            customGroups: [group],
            manualAssignments: [CapabilityGroupAssignment(resourceID: "skill:a", groupID: group.id, source: .manual)]
        )
        try store.save(prefs)
        XCTAssertEqual(store.preferences(), prefs)
        data = Data("not-json".utf8)
        XCTAssertEqual(store.preferencesState(), .corrupted)
        XCTAssertEqual(store.preferences(), .init())
        XCTAssertThrowsError(try store.save(prefs)) { error in
            XCTAssertEqual(error as? CapabilityGroupingStoreError, .corruptedPreferences)
        }
        XCTAssertEqual(data, Data("not-json".utf8), "corrupt bytes must not be overwritten")
        store.clearCorruptedPreferences()
        XCTAssertEqual(store.preferencesState(), .missing)
    }

    func testStoreRejectsStructurallyCorruptV1Preferences() throws {
        var data: Data?
        let store = CapabilityGroupingStore(
            readData: { data },
            writeData: { data = $0; return true },
            removeData: { data = nil }
        )
        let duplicateID = CapabilityGroupDefinition(id: "custom-duplicate", name: "One")
        let duplicateName = CapabilityGroupDefinition(id: "custom-other", name: "one")
        let malformed = CapabilityGroupingPreferencesV1(
            customGroups: [duplicateID, duplicateName],
            manualAssignments: []
        )
        data = try JSONEncoder().encode(malformed)
        XCTAssertEqual(store.preferences(), .init())
    }

    func testStoreReportsWriteFailure() {
        let store = CapabilityGroupingStore(readData: { nil }, writeData: { _ in false }, removeData: {})
        XCTAssertThrowsError(try store.save(.init())) { error in
            XCTAssertEqual(error as? CapabilityGroupingStoreError, .persistenceFailed)
        }
    }

    func testProjectionIncludesOnlyEligibleAgentAndSkillAndManualWins() {
        let agent = resource(id: "agent:video", name: "video-director", kind: .agent, ownership: .userOwned)
        let skill = resource(id: "skill:custom", name: "unrecognized", kind: .skill, ownership: .installed)
        let system = resource(id: "skill:system", name: "video-editor", kind: .skill, ownership: .builtIn, scope: .system)
        let tool = resource(id: "tool:exec", name: "video-editor", kind: .tool, ownership: .runtime, scope: .runtime)
        let custom = CapabilityGroupDefinition(id: "custom", name: "My Group")
        let prefs = CapabilityGroupingPreferencesV1(
            customGroups: [custom],
            manualAssignments: [CapabilityGroupAssignment(resourceID: skill.id, groupID: custom.id, source: .manual)]
        )
        let catalog = CapabilityCatalog(resources: [agent, skill, system, tool]).entries
        let projection = CapabilityGroupingProjection(resources: [agent, skill, system, tool], catalog: catalog, preferences: prefs)
        XCTAssertEqual(Set(projection.members.map(\.id)), Set([agent.id, skill.id]))
        XCTAssertEqual(projection.members.first(where: { $0.id == agent.id })?.group.builtIn, .videoProduction)
        XCTAssertEqual(projection.members.first(where: { $0.id == skill.id })?.group.id, custom.id)
        XCTAssertEqual(projection.agentCount, 1)
        XCTAssertEqual(projection.skillCount, 1)
    }

    private func resource(
        id: String,
        name: String,
        kind: ResourceKind,
        ownership: ResourceOwnership,
        scope: ResourceScope = .global
    ) -> CapabilityResource {
        CapabilityResource(
            id: id, name: name, kind: kind, status: .unknown, scope: scope,
            projectID: scope == .project ? "project:test" : nil, confidence: .exact,
            summary: nil, sourceRootID: "synthetic", relativeSourcePath: "safe",
            sourcePathHash: "hash", lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            ownership: ownership, origin: .local
        )
    }
}
