import XCTest
@testable import DirectorCore

final class CapabilityHistoryObservationTests: XCTestCase {

    func testSignatureRejectsMissingTrackedDocumentBytes() {
        let signature: String? = CapabilityHistoryObservation.signature(
            for: [.agentConfiguration, .agentBrief],
            data: [.agentConfiguration: Data("config".utf8)]
        )

        XCTAssertNil(signature)
    }

    func testByteInitializerRejectsEmptyMissingAndExtraDocumentsWithoutTrapping() {
        let cases: [(Set<CapabilityTrackedDocument>, [CapabilityTrackedDocument: Data])] = [
            ([], [:]),
            ([.agentConfiguration, .agentBrief], [.agentConfiguration: Data("synthetic".utf8)]),
            ([.agentConfiguration], [.agentConfiguration: Data(), .agentBrief: Data()]),
        ]
        for (documents, data) in cases {
            XCTAssertNil(CapabilityHistoryObservation(
                resourceID: "agent:global:synthetic",
                sourceRootID: "global-agents",
                name: "Synthetic Agent",
                kind: .agent,
                scope: .global,
                projectID: nil,
                documents: documents,
                documentData: data,
                observedAt: Date(timeIntervalSince1970: 1_760_000_000)
            ))
        }
    }

    func testUnsafeSourceNameFallsBackBeforeObservationLeavesDiscovery() throws {
        let unsafeNames = [
            "/Users/example/private-skill",
            "../private/SKILL.md",
            "foo/bar",
            #"foo\bar"#,
            ".",
            "..",
            "Private name\nsource body",
            "api_" + "key=live_abcd1234",
        ]

        for unsafeName in unsafeNames {
            let observation = CapabilityHistoryObservation(
                resourceID: "skill:global:synthetic",
                sourceRootID: "global-skills",
                name: unsafeName,
                kind: .skill,
                scope: .global,
                projectID: nil,
                documents: [.skillManifest],
                signature: String(repeating: "a", count: 64),
                observedAt: Date()
            )

            XCTAssertEqual(observation.name, "Unnamed capability", unsafeName)
            let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
            if unsafeName != ".", unsafeName != ".." {
                XCTAssertFalse(encoded.contains(unsafeName), unsafeName)
            }
        }
    }

    func testSignatureUsesSHA256AndNeverEmbedsSourcePathOrDocumentBody() throws {
        let observedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let observation = try XCTUnwrap(CapabilityHistoryObservation(
            resourceID: "skill:global:synthetic",
            sourceRootID: "global-skills",
            name: "Synthetic Skill",
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            documentData: [.skillManifest: Data("private body".utf8)],
            observedAt: observedAt
        ))

        XCTAssertEqual(observation.signatureAlgorithm, "sha256-v1")
        XCTAssertEqual(observation.signature.count, 64)
        XCTAssertFalse(observation.signature.contains("private"))
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private body"))
        XCTAssertFalse(encoded.contains("/Users"))
    }

    func testDocumentSignaturesUseAlreadySuppliedBytesAndRemainBodyFree() throws {
        let observation = try XCTUnwrap(CapabilityHistoryObservation(
            resourceID: "agent:global:synthetic",
            sourceRootID: "global-agents",
            name: "Synthetic Agent",
            kind: .agent,
            scope: .global,
            projectID: nil,
            documents: [.agentConfiguration, .agentBrief],
            documentData: [
                .agentConfiguration: Data("private configuration".utf8),
                .agentBrief: Data("private brief".utf8),
            ],
            observedAt: Date(timeIntervalSince1970: 1_760_000_000)
        ))

        XCTAssertEqual(Set(observation.documentSignatures.map(\.document)), [.agentConfiguration, .agentBrief])
        XCTAssertTrue(observation.documentSignatures.allSatisfy { $0.sha256.count == 64 })
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private configuration"))
        XCTAssertFalse(encoded.contains("private brief"))
    }

    func testSkillObservationTracksOnlyManifest() {
        let observation = CapabilityHistoryObservation(
            resourceID: "skill:global:synthetic",
            sourceRootID: "global-skills",
            name: "Synthetic Skill",
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            signature: String(repeating: "a", count: 64),
            observedAt: Date()
        )

        XCTAssertEqual(observation.documents, [.skillManifest])
        XCTAssertFalse(observation.documents.contains(.agentBrief))
    }

    func testScanBatchSeparatesRealObservationFromCacheFallback() {
        let batch = CapabilityHistoryScanBatch(
            observedAt: Date(),
            scopes: [CapabilityHistoryScanScope(
                rootID: "root",
                scope: .global,
                rootKind: .skills,
                coverage: .partial
            )],
            observations: [],
            source: .filesystem
        )

        XCTAssertEqual(batch.source, .filesystem)
        XCTAssertEqual(batch.scopes.first?.coverage, .partial)
        XCTAssertFalse(batch.isCacheFallback)
    }

    func testCacheFallbackCannotCarryFreshPositiveObservations() {
        let observation = CapabilityHistoryObservation(
            resourceID: "skill:global:synthetic",
            sourceRootID: "global-skills",
            name: "Synthetic Skill",
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            signature: String(repeating: "a", count: 64),
            observedAt: Date()
        )
        let batch = CapabilityHistoryScanBatch(
            observedAt: Date(),
            scopes: [CapabilityHistoryScanScope(
                rootID: "root",
                scope: .global,
                rootKind: .skills,
                coverage: .complete
            )],
            observations: [observation],
            source: .cacheFallback
        )

        XCTAssertTrue(batch.observations.isEmpty)
        XCTAssertTrue(batch.isCacheFallback)
    }

    func testEmptyScanBatchCoverageIsUnavailable() {
        let batch = CapabilityHistoryScanBatch(
            observedAt: Date(),
            scopes: [],
            observations: []
        )
        XCTAssertEqual(batch.coverage, .unavailable)
    }

    func testScanBatchCoverageAggregatesAcrossSourcesWithoutTreatingMixedAsUnreadable() {
        let scope: (String, CapabilityHistoryCoverage) -> CapabilityHistoryScanScope = { rootID, coverage in
            CapabilityHistoryScanScope(
                rootID: rootID,
                scope: .global,
                rootKind: .skills,
                coverage: coverage
            )
        }
        let cases: [([CapabilityHistoryCoverage], CapabilityHistoryCoverage)] = [
            ([], .unavailable),
            ([.unavailable], .unavailable),
            ([.unavailable, .unavailable], .unavailable),
            ([.complete, .unavailable], .partial),
            ([.partial, .unavailable], .partial),
            ([.complete, .partial], .partial),
            ([.unstable, .unavailable], .unstable),
            ([.unstable, .complete], .unstable),
            ([.complete, .complete], .complete),
        ]

        for (index, pair) in cases.enumerated() {
            let batch = CapabilityHistoryScanBatch(
                observedAt: Date(),
                scopes: pair.0.enumerated().map { offset, coverage in
                    scope("root-\(index)-\(offset)", coverage)
                },
                observations: []
            )
            XCTAssertEqual(batch.coverage, pair.1, "coverage case \(index)")
        }
    }

    func testSameSourceDominatingRemainsConservative() {
        XCTAssertEqual(CapabilityHistoryCoverage.complete.dominating(with: .unavailable), .unavailable)
        XCTAssertEqual(CapabilityHistoryCoverage.unavailable.dominating(with: .complete), .unavailable)
        XCTAssertEqual(CapabilityHistoryCoverage.partial.dominating(with: .unavailable), .unavailable)
        XCTAssertEqual(CapabilityHistoryCoverage.unstable.dominating(with: .unavailable), .unstable)
    }

    func testDuplicateDocumentSignaturesFailClosedWithoutTrapping() {
        let duplicate = CapabilityTrackedDocumentSignature(
            document: .skillManifest,
            sha256: String(repeating: "a", count: 64)
        )
        let observation = CapabilityHistoryObservation(
            resourceID: "skill:global:duplicate",
            sourceRootID: "global-skills",
            name: "Duplicate",
            kind: .skill,
            scope: .global,
            projectID: nil,
            documents: [.skillManifest],
            signature: String(repeating: "a", count: 64),
            documentSignatures: [duplicate, duplicate],
            observedAt: Date()
        )
        XCTAssertTrue(observation.signaturesByDocument.isEmpty)
    }
}
