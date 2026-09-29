import XCTest
import DirectorCore
#if DIRECTOR_INTERACTION_PERFORMANCE
@testable import DirectorUI
#endif

/// An optimized, synthetic microbenchmark for the folder projection hot path.
/// It is deliberately not an input-to-paint or accessibility timing claim.
final class InteractionPerformanceTests: XCTestCase {
#if DIRECTOR_INTERACTION_PERFORMANCE
    @MainActor
    func testLibraryNavigationStagesAreDistinctAndInSidebarOrder() {
        let stages = InteractionPerformanceDriver.libraryNavigationStages
        XCTAssertEqual(stages.map(\.destination), [
            .customAgents, .customSkills, .installedSkills, .installedPlugins
        ])
        XCTAssertEqual(stages.map(\.name), [
            "sidebar-custom-agents", "sidebar-custom-skills",
            "sidebar-installed-skills", "sidebar-installed-plugins"
        ])
        XCTAssertEqual(stages.map(\.category), [
            .customAgents, .customSkills, .installedSkills, .installedPlugins
        ])
        XCTAssertEqual(Set(stages.map(\.name)).count, 4)
    }

    @MainActor
    func testDiagnosticProbeUsesClosedPhaseNamesAndClearsBetweenStages() {
        InteractionPerformanceProbe.reset()
        let start = DispatchTime.now().uptimeNanoseconds - 1_000_000
        InteractionPerformanceProbe.record(.identityRead, since: start)
        let first = InteractionPerformanceProbe.take()
        XCTAssertEqual(first.counts["identityRead"], 1)
        XCTAssertGreaterThan(first.durations["identityRead"] ?? 0, 0)
        XCTAssertTrue(InteractionPerformanceProbe.take().durations.isEmpty)
    }
#endif

    func testFolderRelationshipProjectionMeasurements() {
        for fixture in [Fixture(agents: 47, skills: 44, skillsPerAgent: 3),
                        Fixture(agents: 19, skills: 173, skillsPerAgent: 5),
                        Fixture(agents: 500, skills: 500, skillsPerAgent: 8)] {
            let projection = fixture.makeProjection()
            let agentIDs = (0..<fixture.agents).map { "agent:\($0)" }
            let skillIDs = (0..<fixture.skills).map { "skill:\($0)" }
            let folderID = "synthetic-folder"
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                var count = 0
                for id in agentIDs {
                    count += projection.companionSkills(for: id, in: folderID).count
                }
                for id in skillIDs {
                    count += projection.relatedAgents(for: id, in: folderID).count
                }
                XCTAssertGreaterThan(count, 0)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = samples.sorted()
            print("interaction_projection resources=\(fixture.agents + fixture.skills) relations=\(projection.companionRelations.count) samples=20 median_ms=\(sorted[9]) p95_ms=\(sorted[18]) max_ms=\(sorted[19])")
        }
    }

    func testEvaluationDecodeMeasurements() throws {
        for count in [1_000, 5_000] {
            let values = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
                let id = "invocation:\(index)"
                return (id, InvocationEvaluation(
                    invocationID: id,
                    sessionID: "session:\(index / 20)",
                    resourceID: "agent:\(index % 50)",
                    label: .uncertain,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ))
            })
            let encoded = try JSONEncoder().encode(values)
            let store = InvocationEvaluationStore(
                readData: { encoded },
                writeData: { _ in false },
                removeData: { false }
            )
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                XCTAssertEqual(store.all().count, count)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = samples.sorted()
            print("interaction_evaluations count=\(count) samples=20 median_ms=\(sorted[9]) p95_ms=\(sorted[18]) max_ms=\(sorted[19])")
        }
    }

    private struct Fixture {
        let agents: Int
        let skills: Int
        let skillsPerAgent: Int

        func makeProjection() -> CapabilityFolderProjection {
            let allAgents = (0..<agents).map { index in
                resource(id: "agent:\(index)", kind: .agent)
            }
            let allSkills = (0..<skills).map { index in
                resource(id: "skill:\(index)", kind: .skill)
            }
            let folder = CapabilityFolderDefinition(id: "synthetic-folder", source: .custom, customName: "Synthetic")
            let memberships = (allAgents + allSkills).map {
                CapabilityFolderMembership(folderID: folder.id, resourceID: $0.id)
            }
            let relations = (0..<agents).flatMap { agent in
                (0..<skillsPerAgent).map { offset in
                    ResourceRelation(
                        sourceResourceID: "agent:\(agent)",
                        targetResourceID: "skill:\((agent * skillsPerAgent + offset) % skills)",
                        relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue,
                        confidence: .exact,
                        evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue
                    )
                }
            }
            return CapabilityFolderProjection(
                resources: allAgents + allSkills,
                preferences: CapabilityFolderPreferencesV1(customFolders: [folder], memberships: memberships),
                relations: relations
            )
        }

        private func resource(id: String, kind: ResourceKind) -> CapabilityResource {
            CapabilityResource(
                id: id,
                name: id,
                kind: kind,
                status: .unknown,
                scope: .global,
                projectID: nil,
                confidence: .exact,
                summary: "Synthetic purpose",
                sourceRootID: "synthetic",
                relativeSourcePath: "synthetic",
                sourcePathHash: "synthetic",
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                ownership: .userOwned,
                origin: .local
            )
        }
    }
}
