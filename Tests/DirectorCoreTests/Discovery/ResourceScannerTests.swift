import CryptoKit
import Darwin
import XCTest
@testable import DirectorCore

final class ResourceScannerTests: XCTestCase {

    private final class ProjectReadBlocker: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var didBlock = false
        private var starts = 0

        func blockOnce() {
            lock.lock()
            guard !didBlock else {
                lock.unlock()
                return
            }
            didBlock = true
            starts += 1
            lock.unlock()
            releaseSemaphore.wait()
        }

        func release() { releaseSemaphore.signal() }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    func testProjectIsolationCoversEveryReadStageAndKeepsGlobalResults() async throws {
        enum BlockedStage: CaseIterable, Sendable {
            case probe
            case identity
            case document
            case finalValidation
            case registry
            case physicalPath
        }

        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-project-isolation-\(UUID().uuidString)", isDirectory: true)
        let globalRootURL = container.appendingPathComponent("global", isDirectory: true)
        let globalSkill = globalRootURL.appendingPathComponent("global-safe", isDirectory: true)
        let projectURL = container.appendingPathComponent("project", isDirectory: true)
        let projectSkill = projectURL.appendingPathComponent(".agents/skills/project-tool", isDirectory: true)
        let projectManifest = projectSkill.appendingPathComponent("SKILL.md")
        let registryDirectory = projectURL.appendingPathComponent("agents", isDirectory: true)
        let registryURL = registryDirectory.appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try "---\nname: global-safe\n---\n".write(
            to: globalSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "---\nname: project-tool\n---\n".write(
            to: projectManifest, atomically: true, encoding: .utf8
        )
        try #"{"schemaVersion":5,"packages":[]}"#.write(
            to: registryURL, atomically: true, encoding: .utf8
        )

        let globalRoot = ScanRoot(
            id: "global-safe", url: globalRootURL, scope: .global, kind: .skills
        )
        let projectRoot = ScanRoot(
            id: "isolated-project", url: projectURL, scope: .project, kind: .projects
        )
        let base = FileSystemClient()

        for stage in BlockedStage.allCases {
            let blocker = ProjectReadBlocker()
            let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
            let fileSystem = FileSystemClient(
                directoryReader: { url in
                    if stage == .probe,
                       url.standardizedFileURL == projectURL.standardizedFileURL {
                        blocker.blockOnce()
                    }
                    return base.enumerateDirectory(url)
                },
                dataReader: { base.readData($0) },
                attributesReader: { base.fileAttributes($0) },
                readableReader: { base.isReadable($0) },
                symbolicLinkReader: { base.isSymbolicLink($0) },
                verifiedDataReader: { url, root, maximumByteCount in
                    if (stage == .document && url.standardizedFileURL == projectManifest.standardizedFileURL)
                        || (stage == .registry && url.standardizedFileURL == registryURL.standardizedFileURL) {
                        blocker.blockOnce()
                    }
                    return base.readVerifiedData(url, within: root, maximumByteCount: maximumByteCount)
                },
                identityValidator: { url, root, read in
                    if stage == .finalValidation,
                       url.standardizedFileURL == projectManifest.standardizedFileURL {
                        blocker.blockOnce()
                    }
                    return base.validateDocumentRead(read, at: url, within: root)
                },
                directoryIdentityReader: { url in
                    if stage == .identity,
                       url.standardizedFileURL == projectURL.standardizedFileURL {
                        blocker.blockOnce()
                    }
                    return base.directoryIdentity(url)
                },
                directoryStatusReader: { base.directoryStatus($0) }
            )
            let scanner = ResourceScanner(
                roots: [globalRoot, projectRoot],
                fileSystem: fileSystem,
                projectReadGate: gate,
                projectPhysicalPathResolver: { url in
                    if stage == .physicalPath { blocker.blockOnce() }
                    return url.resolvingSymlinksInPath().standardizedFileURL.path
                }
            )

            let isolated = try await scanner.scanIsolatingProjectSources()
            XCTAssertEqual(blocker.startCount, 1, "stage \(stage)")
            XCTAssertTrue(isolated.output.resources.contains { $0.name == "global-safe" }, "stage \(stage)")
            XCTAssertFalse(isolated.output.resources.contains { $0.sourceRootID == projectRoot.id }, "stage \(stage)")
            XCTAssertEqual(isolated.unavailableProjectRootIDs, [projectRoot.id], "stage \(stage)")
            XCTAssertTrue(isolated.output.projects.contains {
                $0.id == projectRoot.id && !$0.available
            }, "stage \(stage)")
            XCTAssertTrue(isolated.output.issues.contains {
                $0.rootID == projectRoot.id
                    && $0.message == "Project source read is temporarily unavailable"
            }, "stage \(stage)")
            let projectScope = isolated.output.historyScanBatch.scopes.first {
                $0.rootID == projectRoot.id
            }
            XCTAssertEqual(projectScope?.coverage, .unavailable, "stage \(stage)")

            blocker.release()
            let released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
            XCTAssertTrue(released, "stage \(stage)")
        }
    }

    func testMissingProjectPhysicalIdentityPublishesUnavailableInsteadOfLexicalFallback() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-project-physical-failure-\(UUID().uuidString)", isDirectory: true)
        let projectSkill = projectURL.appendingPathComponent(".agents/skills/project-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try "---\nname: project-tool\n---\n".write(
            to: projectSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let projectRoot = ScanRoot(
            id: "physical-failure", url: projectURL, scope: .project, kind: .projects
        )
        let scanner = ResourceScanner(
            roots: [projectRoot],
            fileSystem: FileSystemClient(),
            projectReadGate: ProjectSourceReadGate(deadline: 1, capacity: 1),
            projectPhysicalPathResolver: { _ in nil }
        )

        let isolated = try await scanner.scanIsolatingProjectSources()

        XCTAssertTrue(isolated.output.resources.isEmpty)
        XCTAssertTrue(isolated.projectSkillPhysicalPaths.isEmpty)
        XCTAssertEqual(isolated.unavailableProjectRootIDs, [projectRoot.id])
        XCTAssertEqual(isolated.output.historyScanBatch.scopes.first?.coverage, .unavailable)
        XCTAssertEqual(isolated.output.projects.first?.available, false)
    }

    func testTwoBlockedProjectsSaturateGateWhileThirdFailsBusyAndGlobalStillPublishes() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-project-capacity-\(UUID().uuidString)", isDirectory: true)
        let globalURL = container.appendingPathComponent("global", isDirectory: true)
        let globalSkill = globalURL.appendingPathComponent("global-safe", isDirectory: true)
        let projectURLs = (1...3).map {
            container.appendingPathComponent("project-\($0)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        for url in projectURLs {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: container) }
        try "---\nname: global-safe\n---\n".write(
            to: globalSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let firstBlocker = ProjectReadBlocker()
        let secondBlocker = ProjectReadBlocker()
        let base = FileSystemClient()
        let fileSystem = FileSystemClient(
            directoryReader: { url in
                if url.standardizedFileURL == projectURLs[0].standardizedFileURL {
                    firstBlocker.blockOnce()
                } else if url.standardizedFileURL == projectURLs[1].standardizedFileURL {
                    secondBlocker.blockOnce()
                }
                return base.enumerateDirectory(url)
            },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )
        let gate = ProjectSourceReadGate(deadline: 0.03, capacity: 2)
        let roots = [
            ScanRoot(id: "global", url: globalURL, scope: .global, kind: .skills),
        ] + projectURLs.enumerated().map {
            ScanRoot(id: "project-\($0.offset + 1)", url: $0.element, scope: .project, kind: .projects)
        }

        let isolated = try await ResourceScanner(
            roots: roots, fileSystem: fileSystem, projectReadGate: gate
        ).scanIsolatingProjectSources()

        XCTAssertEqual(firstBlocker.startCount, 1)
        XCTAssertEqual(secondBlocker.startCount, 1)
        XCTAssertEqual(gate.activeWorkerCountForTesting, 2)
        XCTAssertTrue(isolated.output.resources.contains { $0.name == "global-safe" })
        XCTAssertEqual(isolated.unavailableProjectRootIDs, Set(["project-1", "project-2", "project-3"]))
        XCTAssertEqual(isolated.output.projects.filter { !$0.available }.count, 3)

        firstBlocker.release()
        secondBlocker.release()
        let released = await waitUntil { gate.activeWorkerCountForTesting == 0 }
        XCTAssertTrue(released)
    }

    func testRootStageLoggingUsesOnlyFixedPrivacySafeFields() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DirectorCore/Discovery/ResourceScanner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let helperStart = try XCTUnwrap(source.range(of: "private static func logRootScan"))
        let scanStart = try XCTUnwrap(source.range(of: "public func scan()"))
        let helper = source[helperStart.lowerBound..<scanStart.lowerBound]

        XCTAssertTrue(source.contains("import OSLog"))
        XCTAssertTrue(source.contains("subsystem: \"com.peiweitang.CodexDirector\""))
        XCTAssertTrue(source.contains("category: \"SourceDiscovery\""))
        XCTAssertTrue(source.contains(".begin,"))
        XCTAssertTrue(source.contains(".probeEnd,"))
        XCTAssertTrue(source.contains(".rootEnd,"))
        XCTAssertTrue(helper.contains("rootKind"))
        XCTAssertTrue(helper.contains("rootOrdinal"))
        XCTAssertTrue(helper.contains("rootTotal"))
        XCTAssertFalse(helper.contains("root.id"))
        XCTAssertFalse(helper.contains("root.url"))
        XCTAssertFalse(helper.contains("root.name"))
        XCTAssertFalse(helper.contains("\\(error"))
    }

    private final class ScanClockProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        private var clockCallCount = 0
        private var directoryReadClockCounts: [Int] = []

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            clockCallCount += 1
            return epoch.addingTimeInterval(TimeInterval(clockCallCount))
        }

        func recordDirectoryRead() {
            lock.lock()
            directoryReadClockCounts.append(clockCallCount)
            lock.unlock()
        }

        var snapshot: (callCount: Int, directoryReadClockCounts: [Int]) {
            lock.lock()
            defer { lock.unlock() }
            return (clockCallCount, directoryReadClockCounts)
        }

        var firstObservationTime: Date { epoch.addingTimeInterval(1) }
        var batchTime: Date { epoch.addingTimeInterval(2) }
    }

    func testEnumerationFailurePreservesUnavailableClassificationAndErrorCode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-enumeration-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = FileSystemClient()
        let denied = FileSystemClient(
            directoryReader: { url in
                url.standardizedFileURL == root.standardizedFileURL
                    ? .failure(.permissionDenied)
                    : base.enumerateDirectory(url)
            },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) }
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "denied-root", url: root, scope: .global, kind: .skills)
        ], fileSystem: denied).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.unavailable])
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertTrue(output.issues.contains { $0.message.contains("permissionDenied") })
    }

    func testDirectoryMetadataFailureMakesCapabilityScopePartialInsteadOfAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-directory-status-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("hidden-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: hidden-skill\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let base = FileSystemClient()
        let denied = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            directoryStatusReader: { url in
                url.standardizedFileURL == skill.standardizedFileURL
                    ? .failure(.permissionDenied)
                    : base.directoryStatus(url)
            }
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "metadata-root", url: root, scope: .global, kind: .skills)
        ], fileSystem: denied).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertTrue(output.issues.contains {
            $0.relativePath == "hidden-skill"
                && $0.message == "Item metadata read failed: permissionDenied"
        })
    }

    func testMissingProjectRootDiffersFromKnownEmptyOptionalChildren() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-scope-absence-\(UUID().uuidString)", isDirectory: true)
        let emptyProject = container.appendingPathComponent("empty-project", isDirectory: true)
        let missingProject = container.appendingPathComponent("missing-project", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let output = ResourceScanner(roots: [
            ScanRoot(id: "empty-project", url: emptyProject, scope: .project, kind: .projects),
            ScanRoot(id: "missing-project", url: missingProject, scope: .project, kind: .projects),
        ]).scan()
        let coverage = Dictionary(uniqueKeysWithValues: output.historyScanBatch.scopes.map { ($0.rootID, $0.coverage) })
        let projects = Dictionary(uniqueKeysWithValues: output.projects.map { ($0.id, $0.available) })

        XCTAssertEqual(coverage["empty-project"], .complete)
        XCTAssertEqual(coverage["missing-project"], .unavailable)
        XCTAssertEqual(projects["empty-project"], true)
        XCTAssertEqual(projects["missing-project"], false)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
    }

    func testUnknownProjectRegistryStructureMakesScopePartial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-invalid-registry-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"schema":1,"entries":{"unexpected":true}}"#.utf8)
            .write(to: agents.appendingPathComponent("registry.json"))

        let output = ResourceScanner(roots: [
            ScanRoot(id: "registry-project", url: root, scope: .project, kind: .projects)
        ]).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertFalse(output.resources.contains { $0.kind == .agent || $0.kind == .workflow })
        XCTAssertTrue(output.issues.contains { $0.message.contains("registry is invalid") })
    }

    func testV5PackagesRegistryIsCompleteWithoutEntriesAndDoesNotDuplicateTomlAgent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-v5-registry-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let skills = root.appendingPathComponent(".agents/skills/video-tool", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "name = \"Display Agent\"\n".write(
            to: agents.appendingPathComponent("build-agent.toml"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Synthetic video utility\n---\n".write(
            to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let registry = #"{"schemaVersion":5,"packages":[{"kind":"native-agent","id":"agent-package","nativeAgent":"build-agent","usesSkills":["video-tool"]},{"kind":"auxiliary-skill","id":"video-tool","nativeAgent":"build-agent","invokedBy":["build-agent"]}]}"#
        try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "v5-project", url: root, scope: .project, kind: .projects)
        ]).scan()
        let agentsFound = output.resources.filter { $0.kind == .agent && $0.projectID == "v5-project" }
        let skillsFound = output.resources.filter { $0.kind == .skill && $0.projectID == "v5-project" }
        XCTAssertEqual(agentsFound.count, 1)
        XCTAssertEqual(agentsFound.first?.relativeSourcePath, ".codex/agents/build-agent.toml")
        XCTAssertEqual(skillsFound.count, 1)
        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.complete])
        XCTAssertFalse(output.issues.contains { $0.message.contains("registry is invalid") })

        let relations = CapabilityCompanionResolver(
            resources: output.resources,
            roots: [ScanRoot(id: "v5-project", url: root, scope: .project, kind: .projects)]
        ).resolve()
        XCTAssertEqual(relations.filter { $0.declarationSource == .projectRegistry }.count, 1)
        XCTAssertEqual(relations.first?.agentID, agentsFound.first?.id)
        XCTAssertEqual(relations.first?.skillID, skillsFound.first?.id)
    }

    func testRegistryVersionMetadataAcceptsExplicitV3AndV5AndLegacyWithoutVersion() throws {
        let registries = [
            #"{"packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]},"skill-package":{"type":"skill","invokedBy":["agent-package"]}}}"#,
            #"{"schemaVersion":3,"packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]},"skill-package":{"type":"skill","invokedBy":["agent-package"]}}}"#,
            #"{"schemaVersion":5,"packages":[{"kind":"native-agent","id":"agent-package","nativeAgent":"agent-package","usesSkills":["skill-package"]},{"kind":"auxiliary-skill","id":"skill-package","nativeAgent":"agent-package","invokedBy":["agent-package"]}]}"#
        ]

        for (index, registry) in registries.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("director-registry-supported-version-\(index)-\(UUID().uuidString)", isDirectory: true)
            let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let skills = root.appendingPathComponent(".agents/skills/skill-package", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"agent-package\"\n".write(to: agents.appendingPathComponent("agent-package.toml"), atomically: true, encoding: .utf8)
            try "---\nname: skill-package\n---\n".write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let output = ResourceScanner(roots: [
                ScanRoot(id: "supported-version-\(index)", url: root, scope: .project, kind: .projects)
            ]).scan()
            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.complete], "registry index \(index)")
            XCTAssertFalse(output.issues.contains { $0.message.contains("registry") && $0.message.contains("version") })
        }
    }

    func testUnsupportedRegistryVersionsArePartialAndDoNotCreateRelations() throws {
        let registries = [
            #"{"schemaVersion":999,"packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]}}}"#,
            #"{"schemaVersion":"5","packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]}}}"#,
            #"{"schema":{"major":5},"schemaVersion":5,"packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]}}}"#,
            #"{"schema":3,"schemaVersion":5,"packages":{"agent-package":{"type":"agent","usesSkills":["skill-package"]}}}"#,
            #"{"schema":999,"entries":[{"name":"Legacy Agent","type":"agent"}]}"#
        ]

        for (index, registry) in registries.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("director-registry-unsupported-version-\(index)-\(UUID().uuidString)", isDirectory: true)
            let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let skills = root.appendingPathComponent(".agents/skills/skill-package", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"agent-package\"\n".write(to: agents.appendingPathComponent("agent-package.toml"), atomically: true, encoding: .utf8)
            try "---\nname: skill-package\n---\n".write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try registry.write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let scanRoot = ScanRoot(id: "unsupported-version-\(index)", url: root, scope: .project, kind: .projects)
            let output = ResourceScanner(roots: [scanRoot]).scan()
            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial], "registry index \(index)")
            XCTAssertTrue(output.issues.contains { $0.message.contains("unsupported") || $0.message.contains("invalid") })
            let relations = CapabilityCompanionResolver(resources: output.resources, roots: [scanRoot]).resolve()
            XCTAssertTrue(relations.filter { $0.declarationSource == .projectRegistry }.isEmpty, "registry index \(index)")
        }
    }

    func testLegacyPackagesObjectAndArrayAreValidRegistryShapes() throws {
        for (index, packagesJSON) in [
            #"{"agent-package":{"type":"agent","usesSkills":["skill-package"]},"skill-package":{"type":"skill","invokedBy":["agent-package"]}}"#,
            #"[{"type":"agent","id":"agent-package","usesSkills":["skill-package"]},{"type":"skill","id":"skill-package","invokedBy":["agent-package"]}]"#
        ].enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("director-legacy-packages-\(index)-\(UUID().uuidString)", isDirectory: true)
            let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
            let skills = root.appendingPathComponent(".agents/skills/skill-package", isDirectory: true)
            let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "name = \"agent-package\"\n".write(to: agents.appendingPathComponent("agent-package.toml"), atomically: true, encoding: .utf8)
            try "---\nname: skill-package\n---\n".write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "{\"packages\":\(packagesJSON)}".write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

            let output = ResourceScanner(roots: [
                ScanRoot(id: "legacy-\(index)", url: root, scope: .project, kind: .projects)
            ]).scan()
            XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.complete])
            XCTAssertFalse(output.issues.contains { $0.message.contains("registry is invalid") })
            XCTAssertEqual(output.resources.filter { $0.kind == .agent }.count, 1)
            XCTAssertEqual(output.resources.filter { $0.kind == .skill }.count, 1)
        }
    }

    func testMalformedPackageFieldMakesProjectRegistryPartial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-malformed-packages-\(UUID().uuidString)", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"schemaVersion":5,"packages":{"broken":{"kind":5}}}"#
            .write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "malformed-packages", url: root, scope: .project, kind: .projects)
        ]).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertTrue(output.issues.contains { $0.message.contains("registry is invalid") })
    }

    func testRegistryPermissionFailureIsNotReportedAsComplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-registry-permission-\(UUID().uuidString)", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let base = FileSystemClient()
        let denied = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { url, approvedRoot, maximumByteCount in
                if url.lastPathComponent == "registry.json" {
                    return .failure(.permissionDenied)
                }
                return base.readVerifiedData(url, within: approvedRoot, maximumByteCount: maximumByteCount)
            },
            identityValidator: { base.validateDocumentRead($2, at: $0, within: $1) },
            directoryIdentityReader: { base.directoryIdentity($0) },
            directoryStatusReader: { base.directoryStatus($0) }
        )

        let output = ResourceScanner(
            roots: [ScanRoot(id: "permission-project", url: root, scope: .project, kind: .projects)],
            fileSystem: denied
        ).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertTrue(output.issues.contains { $0.message.contains("permissionDenied") })
    }

    func testRegistryIdentityRaceDoesNotPublishCompleteScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-registry-race-\(UUID().uuidString)", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"packages":[]}"#.write(
            to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let base = FileSystemClient()
        let raced = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { base.readVerifiedData($0, within: $1, maximumByteCount: $2) },
            identityValidator: { url, approvedRoot, read in
                if url.lastPathComponent == "registry.json" { return false }
                return base.validateDocumentRead(read, at: url, within: approvedRoot)
            },
            directoryIdentityReader: { base.directoryIdentity($0) },
            directoryStatusReader: { base.directoryStatus($0) }
        )

        let output = ResourceScanner(
            roots: [ScanRoot(id: "race-project", url: root, scope: .project, kind: .projects)],
            fileSystem: raced
        ).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.unstable])
        XCTAssertTrue(output.issues.contains { $0.message.contains("registry") })
    }

    func testDuplicateRootProducesOneObservationScopeAndProvenanceWithCorrectRootID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-history-dedup-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: sample\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let scanRoot = ScanRoot(id: "dedup-root", url: root, scope: .global, kind: .skills)

        let output = ResourceScanner(roots: [scanRoot, scanRoot]).scan()

        XCTAssertEqual(output.resources.count, 1)
        XCTAssertEqual(output.provenance.count, 1)
        XCTAssertEqual(output.historyScanBatch.scopes.count, 1)
        XCTAssertEqual(output.historyScanBatch.observations.count, 1)
        XCTAssertEqual(output.historyScanBatch.observations.first?.sourceRootID, "dedup-root")
        XCTAssertEqual(output.historyScanBatch.observations.first?.resourceID, output.resources.first?.id)
    }

    func testObservationAndBatchTimesAreCapturedOnlyAfterFinalValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-history-clock-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: sample\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let base = FileSystemClient()
        let probe = ScanClockProbe()
        let observedFileSystem = FileSystemClient(
            directoryReader: { url in
                probe.recordDirectoryRead()
                return base.enumerateDirectory(url)
            },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { base.readVerifiedData($0, within: $1, maximumByteCount: $2) },
            identityValidator: { base.validateDocumentRead($2, at: $0, within: $1) },
            directoryIdentityReader: { base.directoryIdentity($0) },
            directoryStatusReader: { base.directoryStatus($0) }
        )

        let output = ResourceScanner(
            roots: [ScanRoot(id: "clock-root", url: root, scope: .global, kind: .skills)],
            fileSystem: observedFileSystem,
            now: { probe.now() }
        ).scan()
        let snapshot = probe.snapshot

        XCTAssertEqual(snapshot.callCount, 2)
        XCTAssertFalse(snapshot.directoryReadClockCounts.isEmpty)
        XCTAssertTrue(snapshot.directoryReadClockCounts.allSatisfy { $0 == 0 })
        XCTAssertEqual(output.historyScanBatch.observations.first?.observedAt, probe.firstObservationTime)
        XCTAssertEqual(output.historyScanBatch.observedAt, probe.batchTime)
    }

    func testFakeHomeWithTwoProjectsAndIndependentSkillIsReadOnlyAndFullyAttributed() throws {
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-fake-home-\(UUID().uuidString)", isDirectory: true)
        let globalSkills = fakeHome.appendingPathComponent(".agents/skills", isDirectory: true)
        let independentSkill = globalSkills.appendingPathComponent("independent", isDirectory: true)
        let projectA = fakeHome.appendingPathComponent("Projects/alpha", isDirectory: true)
        let projectAAgents = projectA.appendingPathComponent(".codex/agents", isDirectory: true)
        let projectABrief = projectAAgents.appendingPathComponent("alpha-agent", isDirectory: true)
        let projectB = fakeHome.appendingPathComponent("Projects/beta", isDirectory: true)
        let projectBSkill = projectB.appendingPathComponent(".agents/skills/beta-skill", isDirectory: true)
        for directory in [independentSkill, projectABrief, projectBSkill] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let files: [URL: Data] = [
            independentSkill.appendingPathComponent("SKILL.md"): Data("---\nname: independent\n---\n".utf8),
            projectAAgents.appendingPathComponent("alpha-agent.toml"): Data("name = \"Alpha Agent\"\n".utf8),
            projectABrief.appendingPathComponent("agent.md"): Data("# Alpha Agent\n\nSynthetic brief.\n".utf8),
            projectBSkill.appendingPathComponent("SKILL.md"): Data("---\nname: beta-skill\n---\n".utf8),
        ]
        for (url, data) in files { try data.write(to: url) }
        let beforeHashes = try files.keys.reduce(into: [URL: String]()) { result, url in
            result[url] = try Self.sha256(of: url)
        }

        let output = ResourceScanner(roots: [
            ScanRoot(id: "global-skills", url: globalSkills, scope: .global, kind: .skills),
            ScanRoot(id: "project-alpha", url: projectA, scope: .project, kind: .projects),
            ScanRoot(id: "project-beta", url: projectB, scope: .project, kind: .projects),
        ]).scan()
        let afterHashes = try files.keys.reduce(into: [URL: String]()) { result, url in
            result[url] = try Self.sha256(of: url)
        }

        XCTAssertEqual(beforeHashes, afterHashes)
        XCTAssertEqual(output.projects.map(\.id), ["project-alpha", "project-beta"])
        XCTAssertEqual(output.resources.filter { $0.kind == .agent || $0.kind == .skill }.count, 3)
        XCTAssertEqual(output.historyScanBatch.observations.count, 3)
        XCTAssertEqual(Set(output.historyScanBatch.observations.map(\.sourceRootID)), [
            "global-skills", "project-alpha", "project-beta",
        ])
        XCTAssertEqual(output.historyScanBatch.coverage, .complete)
    }

    func testProjectPairingIsWithheldWhenBriefFailsFinalIdentityValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-pair-race-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let briefDirectory = agents.appendingPathComponent("sample-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = agents.appendingPathComponent("sample-agent.toml")
        let brief = briefDirectory.appendingPathComponent("agent.md")
        try "name = \"Sample Agent\"\n".write(to: configuration, atomically: true, encoding: .utf8)
        try "# Sample Agent\n\nSynthetic brief.\n".write(to: brief, atomically: true, encoding: .utf8)
        let base = FileSystemClient()
        let racing = FileSystemClient(
            directoryReader: { base.enumerateDirectory($0) },
            dataReader: { base.readData($0) },
            attributesReader: { base.fileAttributes($0) },
            readableReader: { base.isReadable($0) },
            symbolicLinkReader: { base.isSymbolicLink($0) },
            verifiedDataReader: { base.readVerifiedData($0, within: $1, maximumByteCount: $2) },
            identityValidator: { url, approvedRoot, read in
                url.standardizedFileURL == brief.standardizedFileURL
                    ? false
                    : base.validateDocumentRead(read, at: url, within: approvedRoot)
            }
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "pair-project", url: root, scope: .project, kind: .projects)
        ], fileSystem: racing).scan()

        XCTAssertEqual(output.resources.filter { $0.kind == .agent }.count, 1)
        XCTAssertTrue(output.agentPairings.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertEqual(output.historyScanBatch.coverage, .unstable)
    }

    func testFIFONamedSkillManifestIsRejectedAsNonRegularWithoutReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-fifo-manifest-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = skill.appendingPathComponent("SKILL.md")
        let result = fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }
        XCTAssertEqual(result, 0)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "fifo-root", url: root, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertEqual(output.historyScanBatch.coverage, .partial)
        XCTAssertTrue(output.issues.contains { $0.message.contains("notRegularFile") })
    }

    func testManifestSymlinkEscapingApprovedRootCannotProduceObservation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-manifest-escape-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("root", isDirectory: true)
        let skill = root.appendingPathComponent("escaped", isDirectory: true)
        let outside = directory.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "---\nname: escaped\n---\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("SKILL.md"),
            withDestinationURL: outside
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "escape", url: root, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertEqual(output.historyScanBatch.coverage, .partial)
    }

    func testManifestSymlinkWithinApprovedRootCanProduceObservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-manifest-inside-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("linked", isDirectory: true)
        let target = root.appendingPathComponent("manifest-source.md")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: linked\n---\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("SKILL.md"),
            withDestinationURL: target
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "inside", url: root, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertEqual(output.resources.map(\.name), ["linked"])
        XCTAssertEqual(output.historyScanBatch.observations.count, 1)
        XCTAssertEqual(output.historyScanBatch.coverage, .complete)
    }

    func testOversizedTrackedDocumentDoesNotProduceResourceOrObservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-document-limit-\(UUID().uuidString)", isDirectory: true)
        let skill = root.appendingPathComponent("large", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1)
        try data.write(to: skill.appendingPathComponent("SKILL.md"))

        let output = ResourceScanner(roots: [
            ScanRoot(id: "large", url: root, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertEqual(output.historyScanBatch.coverage, .partial)
        XCTAssertTrue(output.issues.contains { $0.message.contains("tooLarge") })
    }

    func testBuiltInSystemSkillNestedInGlobalRootIsNotHistoryTracked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-system-exclusion-\(UUID().uuidString)", isDirectory: true)
        let systemSkill = root.appendingPathComponent(".system", isDirectory: true)
        try FileManager.default.createDirectory(at: systemSkill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: system-skill\n---\n".write(
            to: systemSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "global", url: root, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertEqual(output.resources.first?.ownership, .builtIn)
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
    }

    func testEmptyDirectoryIsCompleteHistoryScope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-empty-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = ResourceScanner(roots: [
            ScanRoot(id: "empty-skills", url: directory, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.complete])
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
    }

    func testInvalidUTF8DoesNotBecomeEmptyHistorySignatureOrCompleteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-invalid-history-\(UUID().uuidString)", isDirectory: true)
        let skill = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0xFF, 0xFE, 0xFD]).write(to: skill.appendingPathComponent("SKILL.md"))

        let output = ResourceScanner(roots: [
            ScanRoot(id: "invalid-skills", url: directory, scope: .global, kind: .skills)
        ]).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.partial])
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertTrue(output.resources.isEmpty)
        XCTAssertTrue(output.issues.contains { $0.message.contains("UTF-8") })
    }

    func testProjectBriefOnlyChangeUpdatesHistorySignatureWithoutChangingLegacyFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-brief-history-\(UUID().uuidString)", isDirectory: true)
        let agents = directory.appendingPathComponent(".codex/agents", isDirectory: true)
        let briefDirectory = agents.appendingPathComponent("sample-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "name = \"Sample Agent\"\ndescription = \"Callable\"\n".write(
            to: agents.appendingPathComponent("sample-agent.toml"), atomically: true, encoding: .utf8)
        let brief = briefDirectory.appendingPathComponent("agent.md")
        try "# Sample Agent\n\nFirst brief.\n".write(to: brief, atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "brief-project", url: directory, scope: .project, kind: .projects)

        let first = ResourceScanner(roots: [root]).scan()
        let firstResource = try XCTUnwrap(first.resources.first { $0.kind == .agent })
        let firstObservation = try XCTUnwrap(first.historyScanBatch.observations.first { $0.resourceID == firstResource.id })
        try "# Sample Agent\n\nSecond brief.\n".write(to: brief, atomically: true, encoding: .utf8)

        let second = ResourceScanner(roots: [root]).scan()
        let secondResource = try XCTUnwrap(second.resources.first { $0.id == firstResource.id })
        let secondObservation = try XCTUnwrap(second.historyScanBatch.observations.first { $0.resourceID == firstResource.id })

        XCTAssertEqual(secondResource.id, firstResource.id)
        XCTAssertEqual(secondResource.sourcePathHash, firstResource.sourcePathHash)
        XCTAssertEqual(secondResource.contentFingerprint, firstResource.contentFingerprint)
        XCTAssertNotEqual(secondObservation.signature, firstObservation.signature)
        XCTAssertEqual(secondObservation.documents, [.agentConfiguration, .agentBrief])
    }

    func testScanRaceDoesNotPublishHistoryObservation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-race-history-\(UUID().uuidString)", isDirectory: true)
        let skill = directory.appendingPathComponent("race", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "---\nname: race\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let base = FileSystemClient()
        let racing = FileSystemClient(
            directoryReader: { url in base.enumerateDirectory(url) },
            dataReader: { url in
                if url.lastPathComponent == "SKILL.md" {
                    return .failure(.changedDuringRead)
                }
                return base.readData(url)
            },
            attributesReader: { url in base.fileAttributes(url) },
            readableReader: { url in base.isReadable(url) },
            symbolicLinkReader: { url in base.isSymbolicLink(url) }
        )

        let output = ResourceScanner(roots: [
            ScanRoot(id: "race-skills", url: directory, scope: .global, kind: .skills)
        ], fileSystem: racing).scan()

        XCTAssertEqual(output.historyScanBatch.scopes.map(\.coverage), [.unstable])
        XCTAssertTrue(output.historyScanBatch.observations.isEmpty)
        XCTAssertTrue(output.issues.contains { $0.message.contains("changed") })
    }

    func testProjectBriefPairingKeepsTomlIdentityAndRejectsEscapedSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("director-pairing-\(UUID().uuidString)")
        let project = directory.appendingPathComponent("project")
        let agents = project.appendingPathComponent(".codex/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toml = agents.appendingPathComponent("sample-agent.toml")
        try "name = \"Sample Agent\"\ndescription = \"Synthetic role\"\n".write(to: toml, atomically: true, encoding: .utf8)
        let root = ScanRoot(id: "synthetic-project", url: project, scope: .project, kind: .projects)
        let before = ResourceScanner(roots: [root]).scan()
        let original = try XCTUnwrap(before.resources.first { $0.kind == .agent })
        let briefDirectory = agents.appendingPathComponent("sample-agent")
        try FileManager.default.createDirectory(at: briefDirectory, withIntermediateDirectories: true)
        let brief = briefDirectory.appendingPathComponent("agent.md")
        try "# Synthetic Brief\nRead only.\n".write(to: brief, atomically: true, encoding: .utf8)
        let after = ResourceScanner(roots: [root]).scan()
        XCTAssertEqual(after.resources.filter { $0.kind == .agent }.map(\.id), [original.id])
        XCTAssertEqual(after.agentPairings.count, 1)
        XCTAssertEqual(after.agentPairings.first?.briefRelativePath, ".codex/agents/sample-agent/agent.md")
        XCTAssertEqual(after.resources.first { $0.id == original.id }?.contentFingerprint, original.contentFingerprint)
        try FileManager.default.removeItem(at: brief)
        let outside = directory.appendingPathComponent("outside.md")
        try "Outside synthetic root".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: brief, withDestinationURL: outside)
        XCTAssertTrue(ResourceScanner(roots: [root]).scan().agentPairings.isEmpty)
        XCTAssertEqual(try String(contentsOf: toml, encoding: .utf8), "name = \"Sample Agent\"\ndescription = \"Synthetic role\"\n")
    }

    func testSkillPurposeSupportsBlockScalarsAndOpeningProseWithoutChangingSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("director-purpose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let privatePath = ["", "Users", "fixture-user", "Documents", "work"].joined(separator: "/")
        let examples: [(String, String, String?)] = [
            ("folded", "---\nname: folded\ndescription: >-\n  Inspect local assets.\n  Preserve their sources.\nmetadata: {\"schema\": 1}\n---\n# Instructions\nDo not persist this body.\n", "Inspect local assets. Preserve their sources."),
            ("literal", "---\nname: literal\ndescription: |\n  第一行用途。\n  第二行说明。\n---\nIgnored body.\n", "第一行用途。\n第二行说明。"),
            ("colon", "---\nname: colon\ndescription: >\n  Use when: examining assets.\n  name: is description text, not a resource rename.\nmetadata:\n  name: nested-name\n  description: nested-description\n---\n", "Use when: examining assets. name: is description text, not a resource rename."),
            ("prose", "# prose\n\nInspect and test local changes.\n\n## Commands\nNever index this section.\n", "Inspect and test local changes."),
            ("undeclared", "# undeclared\n\n## Commands\nDo not treat later instructions as a purpose.\n", nil),
            ("code-first", "# code-first\n\n```sh\nrun-something\n```\n", nil),
            ("broken", "---\nname: broken\ndescription: >\n  Unterminated header.\n", nil),
            ("empty-block", "---\nname: empty-block\ndescription: >-\n\nversion: 1\n---\n", nil),
            ("private-prose", "# private-prose\n\nRead \(privatePath).\n", nil),
            ("private-block", "---\nname: private-block\ndescription: |\n  Read \(privatePath).\n---\n", nil),
            ("oversized-block", "---\nname: oversized-block\ndescription: >\n  \(String(repeating: "x", count: 16_385))\n---\n", nil),
        ]
        for (name, text, _) in examples {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let root = ScanRoot(id: "purpose-fixture", url: directory, scope: .global, kind: .skills)
        let output = ResourceScanner(roots: [root]).scan()
        XCTAssertEqual(output.resources.count, examples.count)
        for (name, text, expected) in examples {
            let resource = try XCTUnwrap(output.resources.first { $0.name == name }, name)
            XCTAssertEqual(resource.summary, expected, name)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name).appendingPathComponent("SKILL.md"), encoding: .utf8), text)
        }
    }

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

    func testGlobalAgentTomlAndMatchingBriefAreOneLogicalResource() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("video-director"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "name = \"Video Director\"\ndescription = \"Callable video role.\"\ndeveloper_instructions = \"Use $video-tool.\"\n"
            .write(to: temp.appendingPathComponent("video-director.toml"), atomically: true, encoding: .utf8)
        try "# Video Director\n\nBrief declaration: Use $video-tool for delivery."
            .write(to: temp.appendingPathComponent("video-director/agent.md"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "global-agents", url: temp, scope: .global, kind: .agents)
        ]).scan()
        XCTAssertEqual(output.resources.filter { $0.kind == .agent }.count, 1)
        XCTAssertEqual(output.resources.first?.name, "Video Director")
        XCTAssertEqual(output.resources.first?.relativeSourcePath, "video-director/agent.md")
    }

    func testRealGlobalAgentRootShapePairsAllTopLevelTomlsWithSiblingBriefs() throws {
        // The production global library keeps callable TOMLs at the root and
        // reusable Briefs in sibling <slug>/agent.md directories. Keep this
        // synthetic fixture representative without reading a developer's
        // actual home directory in the public test suite.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-real-agent-root-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let names = [
            "Brand Designer", "Creative Producer", "Figma Editor", "Frontend Developer",
            "Icon Designer", "Material Judge", "Platform Adapter", "Product Architect",
            "Product Designer", "Quality Engineer", "Reference Finder", "Remotion Engineer",
            "Review Analyst", "Skill Architect", "Software Engineer", "UI Designer",
            "Video Director", "Video Editor", "Voice Editor"
        ]
        for name in names {
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            try FileManager.default.createDirectory(
                at: temp.appendingPathComponent(slug),
                withIntermediateDirectories: true
            )
            try "name = \"\(name)\"\ndescription = \"Synthetic callable role.\"\n"
                .write(to: temp.appendingPathComponent("\(slug).toml"), atomically: true, encoding: .utf8)
            try "# \(name)\n\nSynthetic reusable brief."
                .write(to: temp.appendingPathComponent("\(slug)/agent.md"), atomically: true, encoding: .utf8)
        }

        let output = ResourceScanner(roots: [
            ScanRoot(id: "global-agents", url: temp, scope: .global, kind: .agents)
        ]).scan()
        let agents = output.resources.filter { $0.kind == .agent }
        XCTAssertEqual(agents.count, names.count)
        XCTAssertEqual(output.agentPairings.count, names.count)
        XCTAssertTrue(agents.allSatisfy { $0.relativeSourcePath?.hasSuffix("/agent.md") == true })
        XCTAssertTrue(agents.allSatisfy { agent in
            output.agentPairings.contains { pairing in
                pairing.agentRelativePath == agent.relativeSourcePath
            }
        })
    }

    func testPairedGlobalAgentScansDeclarationsFromTomlAndBriefOnce() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-pair-relations-\(UUID().uuidString)", isDirectory: true)
        let skillRoot = temp.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("video-director"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillRoot.appendingPathComponent("video-tool"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillRoot.appendingPathComponent("audio-tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try "name = \"Video Director\"\ndeveloper_instructions = \"Use $video-tool.\"\n"
            .write(to: temp.appendingPathComponent("video-director.toml"), atomically: true, encoding: .utf8)
        try "# Video Director\n\nUse $audio-tool for narration."
            .write(to: temp.appendingPathComponent("video-director/agent.md"), atomically: true, encoding: .utf8)
        for (name, text) in [("video-tool", "Video"), ("audio-tool", "Audio")] {
            try "---\nname: \(name)\ndescription: \(text) utility\n---\n"
                .write(to: skillRoot.appendingPathComponent(name).appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let agentRoot = ScanRoot(id: "agents", url: temp, scope: .global, kind: .agents)
        let skills = ScanRoot(id: "skills", url: skillRoot, scope: .global, kind: .skills)
        let output = ResourceScanner(roots: [agentRoot, skills]).scan()
        let agent = try XCTUnwrap(output.resources.first { $0.kind == .agent })
        let relations = CapabilityCompanionResolver(resources: output.resources, roots: [agentRoot, skills]).resolve()
        XCTAssertEqual(relations.filter { $0.agentID == agent.id }.count, 2)
        XCTAssertEqual(Set(relations.map(\.skillID)).count, 2)
        let videoID = try XCTUnwrap(output.resources.first { $0.name == "video-tool" }?.id)
        let audioID = try XCTUnwrap(output.resources.first { $0.name == "audio-tool" }?.id)
        XCTAssertTrue(relations.contains { $0.skillID == videoID && $0.declarationSource == .agentConfiguration })
        XCTAssertTrue(relations.contains { $0.skillID == audioID && $0.declarationSource == .agentBrief })
    }

    func testPairedAgentWithDifferentSlugUsesEphemeralPairingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-pair-different-slug-\(UUID().uuidString)", isDirectory: true)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("video-director"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsRoot.appendingPathComponent("video-tool"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Video Director\n\nUse $video-tool for delivery."
            .write(to: root.appendingPathComponent("video-director/agent.md"), atomically: true, encoding: .utf8)
        try "---\nname: video-tool\ndescription: Video utility\n---\n"
            .write(to: skillsRoot.appendingPathComponent("video-tool/SKILL.md"), atomically: true, encoding: .utf8)

        let agentRoot = ScanRoot(id: "agents", url: root, scope: .global, kind: .agents)
        let skillRoot = ScanRoot(id: "skills", url: skillsRoot, scope: .global, kind: .skills)
        let historicalBriefID = try XCTUnwrap(ResourceScanner(roots: [agentRoot]).scan().resources.first?.id)

        let tomlOnlyRootURL = FileManager.default.temporaryDirectory.appendingPathComponent("director-agent-toml-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tomlOnlyRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tomlOnlyRootURL) }
        try "name = \"Video Director\"\ndeveloper_instructions = \"Use $video-tool for production.\"\n"
            .write(to: tomlOnlyRootURL.appendingPathComponent("video.toml"), atomically: true, encoding: .utf8)
        let tomlOnlyID = try XCTUnwrap(ResourceScanner(roots: [ScanRoot(id: "agents", url: tomlOnlyRootURL, scope: .global, kind: .agents)]).scan().resources.first?.id)

        try "name = \"Video Director\"\ndeveloper_instructions = \"Use $video-tool for production.\"\n"
            .write(to: root.appendingPathComponent("video.toml"), atomically: true, encoding: .utf8)
        let output = ResourceScanner(roots: [agentRoot, skillRoot]).scan()
        let agent = try XCTUnwrap(output.resources.first { $0.kind == .agent })
        let skill = try XCTUnwrap(output.resources.first { $0.kind == .skill })
        XCTAssertEqual(agent.id, historicalBriefID)
        XCTAssertNotEqual(agent.id, tomlOnlyID)
        let pairing = try XCTUnwrap(output.agentPairings.first)
        XCTAssertEqual(pairing.agentRelativePath, "video-director/agent.md")
        XCTAssertEqual(pairing.briefRelativePath, "video-director/agent.md")
        XCTAssertEqual(pairing.configurationRelativePath, "video.toml")

        let relations = CapabilityCompanionResolver(
            resources: output.resources,
            roots: [agentRoot, skillRoot],
            agentPairings: output.agentPairings
        ).resolve()
        let pairedRelations = relations.filter { $0.agentID == agent.id && $0.skillID == skill.id }
        XCTAssertEqual(pairedRelations.count, 2)
        XCTAssertEqual(Set(pairedRelations.map(\.declarationSource)), [.agentConfiguration, .agentBrief])
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

    func testLegacyRegistryAgentPreservesCanonicalProjectTomlAgentAndRegistryIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-registry-agent-dedup-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent(".codex/agents", isDirectory: true)
        let registryDirectory = root.appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "name = \"Display Agent\"\n".write(
            to: agents.appendingPathComponent("display-agent.toml"), atomically: true, encoding: .utf8)
        try #"{"entries":[{"name":"Display Agent","type":"agent"}]}"#
            .write(to: registryDirectory.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)

        let output = ResourceScanner(roots: [
            ScanRoot(id: "legacy-agent-dedup", url: root, scope: .project, kind: .projects)
        ]).scan()

        let agentsFound = output.resources.filter { $0.kind == .agent && $0.projectID == "legacy-agent-dedup" }
        XCTAssertEqual(agentsFound.count, 2)
        XCTAssertTrue(agentsFound.contains { $0.relativeSourcePath == ".codex/agents/display-agent.toml" })
        XCTAssertTrue(agentsFound.contains { $0.relativeSourcePath == "agents/registry.json/Display Agent" })
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

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
