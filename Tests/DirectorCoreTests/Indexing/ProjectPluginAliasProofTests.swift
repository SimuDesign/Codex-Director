import Foundation
import XCTest
@testable import DirectorCore

final class ProjectPluginAliasProofTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func resource(
        _ id: String,
        _ kind: ResourceKind,
        _ scope: ResourceScope,
        _ rootID: String,
        _ relativePath: String,
        ownership: ResourceOwnership,
        origin: ResourceOrigin
    ) -> CapabilityResource {
        CapabilityResource(
            id: id,
            name: "tool",
            kind: kind,
            status: .idle,
            scope: scope,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: rootID,
            relativeSourcePath: relativePath,
            sourcePathHash: nil,
            lastSeenAt: observedAt,
            ownership: ownership,
            origin: origin
        )
    }

    private func contains(
        _ parent: CapabilityResource,
        _ child: CapabilityResource,
        confidence: EvidenceConfidence = .exact
    ) -> ResourceRelation {
        ResourceRelation(
            sourceResourceID: parent.id,
            targetResourceID: child.id,
            relationKind: "contains",
            confidence: confidence,
            evidenceSummary: "Synthetic package membership"
        )
    }

    func testPluginPackageAliasProofRejectsAmbiguityAndMalformedMembership() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-plugin-proof-\(UUID().uuidString)", isDirectory: true)
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        let package = cache.appendingPathComponent("package", isDirectory: true)
        let manifest = package.appendingPathComponent("skills/tool/SKILL.md")
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("---\nname: tool\n---\n".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: container) }

        let root = ScanRoot(id: "plugin-cache", url: cache, scope: .plugin, kind: .plugins)
        let nativeParent = resource(
            "native-parent", .plugin, .plugin, root.id, "package",
            ownership: .pluginProvided, origin: .plugin
        )
        let nativeChild = resource(
            "native-child", .skill, .plugin, root.id, "package/skills/tool/SKILL.md",
            ownership: .pluginProvided, origin: .plugin
        )
        let runtimeParent = resource(
            "runtime-parent", .plugin, .runtime, "runtime-plugins", "plugins/marker",
            ownership: .runtime, origin: .runtime
        )
        let runtimeChild = resource(
            "runtime-child", .skill, .runtime, "runtime-plugins:marker",
            "plugins/marker/skills/tool/SKILL.md",
            ownership: .pluginProvided, origin: .plugin
        )
        let nativeRelation = contains(nativeParent, nativeChild)
        let runtimeRelation = contains(runtimeParent, runtimeChild)

        func discovery(
            _ resources: [CapabilityResource] = [nativeParent, nativeChild],
            _ relations: [ResourceRelation] = [nativeRelation],
            issues: [DiscoveryIssue] = []
        ) -> DiscoveryOutput {
            DiscoveryOutput(resources: resources, issues: issues, relations: relations)
        }
        func runtime(
            _ resources: [CapabilityResource] = [runtimeParent, runtimeChild],
            _ relations: [ResourceRelation] = [runtimeRelation],
            transientRoots: [String: URL] = ["runtime-plugins:marker": package]
        ) -> CodexRuntimeDiscovery.Result {
            CodexRuntimeDiscovery.Result(
                resources: resources,
                issues: [],
                coverage: .partial,
                unsupportedCategories: ["builtin-tools"],
                relations: relations,
                transientRoots: transientRoots,
                pluginPackagesAvailable: true
            )
        }
        func projection(
            _ runtimeResult: CodexRuntimeDiscovery.Result = runtime(),
            _ discoveryResult: DiscoveryOutput = discovery(),
            roots: [ScanRoot] = [root]
        ) -> [String: String] {
            IndexingCoordinator.pluginPackageRuntimeAliasMap(
                runtime: runtimeResult,
                discovery: discoveryResult,
                scanRoots: roots,
                pluginInventoryAvailable: true,
                pluginPackagesAvailable: true
            )
        }

        let expected = [runtimeChild.id: nativeChild.id]
        XCTAssertEqual(projection(), expected)
        XCTAssertEqual(projection(
            runtime([runtimeChild, runtimeParent], [runtimeRelation, runtimeRelation]),
            discovery([nativeChild, nativeParent], [nativeRelation, nativeRelation])
        ), expected)

        let runtimeParent2 = resource(
            "runtime-parent-2", .plugin, .runtime, "runtime-plugins", "plugins/marker",
            ownership: .runtime, origin: .runtime
        )
        XCTAssertTrue(projection(runtime(
            [runtimeParent, runtimeParent2, runtimeChild],
            [runtimeRelation, contains(runtimeParent2, runtimeChild)]
        )).isEmpty)

        let nativeChild2 = resource(
            "native-child-2", .skill, .plugin, root.id, nativeChild.relativeSourcePath!,
            ownership: .pluginProvided, origin: .plugin
        )
        XCTAssertTrue(projection(
            runtime(),
            discovery(
                [nativeParent, nativeChild, nativeChild2],
                [nativeRelation, contains(nativeParent, nativeChild2)]
            )
        ).isEmpty)

        let otherPackage = container.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherPackage.appendingPathComponent("skills/tool"),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(projection(runtime(
            transientRoots: ["runtime-plugins:marker": otherPackage]
        )).isEmpty)
        XCTAssertTrue(projection(runtime(
            [runtimeParent, runtimeChild],
            [contains(runtimeParent, runtimeChild, confidence: .inferred)]
        )).isEmpty)
        XCTAssertTrue(projection(runtime(transientRoots: [:])).isEmpty)

        let wrongRuntimeRoot = resource(
            runtimeChild.id, .skill, .runtime, "runtime-plugins:other",
            runtimeChild.relativeSourcePath!, ownership: .pluginProvided, origin: .plugin
        )
        XCTAssertTrue(projection(runtime(
            [runtimeParent, wrongRuntimeRoot], [contains(runtimeParent, wrongRuntimeRoot)]
        )).isEmpty)
        XCTAssertTrue(projection(
            runtime(),
            discovery(issues: [DiscoveryIssue(
                rootID: root.id,
                relativePath: "",
                message: "Synthetic plugin root issue"
            )])
        ).isEmpty)
        let secondRoot = ScanRoot(
            id: "second-cache",
            url: container.appendingPathComponent("second-cache", isDirectory: true),
            scope: .plugin,
            kind: .plugins
        )
        XCTAssertTrue(projection(roots: [root, secondRoot]).isEmpty)

        let wrongNativeParent = resource(
            nativeParent.id, .plugin, .plugin, "other-root",
            nativeParent.relativeSourcePath!, ownership: .pluginProvided, origin: .plugin
        )
        XCTAssertTrue(projection(
            runtime(),
            discovery(
                [wrongNativeParent, nativeChild],
                [contains(wrongNativeParent, nativeChild)]
            )
        ).isEmpty)

        let outside = container.appendingPathComponent("outside-SKILL.md")
        try Data("---\nname: outside\n---\n".utf8).write(to: outside)
        let escapingPath = package.appendingPathComponent("skills/escape/SKILL.md")
        try FileManager.default.createDirectory(
            at: escapingPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: escapingPath, withDestinationURL: outside)
        let escapingNative = resource(
            "escaping-native", .skill, .plugin, root.id,
            "package/skills/escape/SKILL.md", ownership: .pluginProvided, origin: .plugin
        )
        let escapingRuntime = resource(
            "escaping-runtime", .skill, .runtime, "runtime-plugins:marker",
            "plugins/marker/skills/escape/SKILL.md", ownership: .pluginProvided, origin: .plugin
        )
        XCTAssertTrue(projection(
            runtime(
                [runtimeParent, escapingRuntime],
                [contains(runtimeParent, escapingRuntime)]
            ),
            discovery(
                [nativeParent, escapingNative],
                [contains(nativeParent, escapingNative)]
            )
        ).isEmpty)
    }
}
