import Foundation
import Darwin
import CryptoKit
import DirectorCore
import DirectorUI

/// Synthetic-only fixture producer.  DatabaseStore owns schema migration and
/// persistence validation; this tool never copies production SQL or opens a
/// user database.  It prints aggregate counts only.
enum FixtureError: Error, CustomStringConvertible {
    case usage, invalidScenario, invalidID, unsafeRoot, existingFixture, invalidCache, invalidManifest
    var description: String {
        switch self {
        case .usage: "usage"
        case .invalidScenario: "invalid_scenario"
        case .invalidID: "invalid_fixture_id"
        case .unsafeRoot: "unsafe_root"
        case .existingFixture: "fixture_exists"
        case .invalidCache: "invalid_cache"
        case .invalidManifest: "invalid_manifest"
        }
    }
}

struct FixtureManifest: Codable {
    let schemaVersion: Int
    let scenario: String
    let fixtureID: String
    let databaseFile: String
    let cacheFile: String
    let metricsDirectory: String
    let sourceDirectory: String
    let expectedDatabaseEpoch: String
    let expectedDataGeneration: Int64
    let expectedLastSourceCheckAt: Date?
    let expectedLastIndexCompletedAt: Date?
    let expectedResourceCount: Int
    let expectedProjectCount: Int
    let expectedSessionCount: Int
    let expectedCallCount: Int
    let expectedQuotaCount: Int
    let expectedRecentQuotaCount: Int
    let expectedCacheFingerprint: String?
    let manifestDigest: String

    static func digest(schemaVersion: Int, scenario: String, fixtureID: String,
                       databaseFile: String, cacheFile: String, metricsDirectory: String,
                       sourceDirectory: String, expectedDatabaseEpoch: String,
                       expectedDataGeneration: Int64, expectedLastSourceCheckAt: Date?,
                       expectedLastIndexCompletedAt: Date?, expectedResourceCount: Int,
                       expectedProjectCount: Int, expectedSessionCount: Int,
                       expectedCallCount: Int, expectedQuotaCount: Int,
                       expectedRecentQuotaCount: Int, expectedCacheFingerprint: String?) -> String {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let values = [String(schemaVersion), scenario, fixtureID, databaseFile, cacheFile,
                      metricsDirectory, sourceDirectory, expectedDatabaseEpoch, String(expectedDataGeneration),
                      expectedLastSourceCheckAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "",
                      expectedLastIndexCompletedAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "",
                      String(expectedResourceCount), String(expectedProjectCount), String(expectedSessionCount),
                      String(expectedCallCount), String(expectedQuotaCount), String(expectedRecentQuotaCount),
                      expectedCacheFingerprint ?? ""]
        return SHA256.hash(data: Data(values.map(field).joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func validated() throws {
        guard schemaVersion == 2,
              UUID(uuidString: fixtureID) != nil,
              manifestDigest == Self.digest(schemaVersion: schemaVersion, scenario: scenario,
                                            fixtureID: fixtureID, databaseFile: databaseFile,
                                            cacheFile: cacheFile, metricsDirectory: metricsDirectory,
                                            sourceDirectory: sourceDirectory,
                                            expectedDatabaseEpoch: expectedDatabaseEpoch,
                                            expectedDataGeneration: expectedDataGeneration,
                                            expectedLastSourceCheckAt: expectedLastSourceCheckAt,
                                            expectedLastIndexCompletedAt: expectedLastIndexCompletedAt,
                                            expectedResourceCount: expectedResourceCount,
                                            expectedProjectCount: expectedProjectCount,
                                            expectedSessionCount: expectedSessionCount,
                                            expectedCallCount: expectedCallCount,
                                            expectedQuotaCount: expectedQuotaCount,
                                            expectedRecentQuotaCount: expectedRecentQuotaCount,
                                            expectedCacheFingerprint: expectedCacheFingerprint) else {
            throw FixtureError.invalidManifest
        }
    }
}

@main
struct StartupPerformanceFixtureTool {
    static let root = URL(fileURLWithPath: "/tmp/codex-director-startup-perf", isDirectory: true)
    static let canonicalRootPath = root.resolvingSymlinksInPath().path

    static func main() async {
        do { try await run(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch let error as FixtureError { FileHandle.standardError.write(Data("error=\(error.description)\n".utf8)); exit(2) }
        catch { FileHandle.standardError.write(Data("error=fixture_failed\n".utf8)); exit(2) }
    }

    static func run(arguments: [String]) async throws {
        let isPreflight = arguments.first == "--preflight"
        let scenarioIndex = isPreflight ? 1 : 0
        guard arguments.count > scenarioIndex,
              let scenario = arguments.dropFirst(scenarioIndex).first,
              ["cachedIndexed", "uncachedIndexed", "uncachedNoIndex"].contains(scenario) else { throw FixtureError.invalidScenario }
        let fixtureID = arguments.dropFirst(scenarioIndex + 1).first ?? UUID().uuidString
        guard UUID(uuidString: fixtureID) != nil else { throw FixtureError.invalidID }
        guard root.path == "/tmp/codex-director-startup-perf",
              root.resolvingSymlinksInPath().path == canonicalRootPath else { throw FixtureError.unsafeRoot }
        if isPreflight {
            try await preflight(scenario: scenario, fixtureID: fixtureID)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let fixtureRoot = root.appendingPathComponent(fixtureID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: fixtureRoot.path) else { throw FixtureError.existingFixture }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
        let databaseURL = fixtureRoot.appendingPathComponent("database.sqlite")
        let cacheURL = fixtureRoot.appendingPathComponent("presentation.json")
        let metricsURL = fixtureRoot.appendingPathComponent("metrics", isDirectory: true)
        let sourceURL = fixtureRoot.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: metricsURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metricsURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceURL.path)
        try writeSentinelSources(to: sourceURL)

        let indexed = scenario != "uncachedNoIndex"
        let now = Date()
        let writer = try DatabaseStore(url: databaseURL)
        if indexed {
            try await populate(writer, now: now)
            try await writer.markSuccessfulSourceIndex(at: now)
        }
        let identity = try await writer.presentationIdentity()
        let window = CapabilityQueryWindow.recent7(now: now, calendar: makeCalendar())
        var cachePresent = false
        if scenario == "cachedIndexed" {
            let startup = try await writer.fetchStartupPresentation(window: window)
            let home = HomeOverviewModel(catalog: try await writer.fetchCapabilityCatalog(), usage: startup.recentUsage).presentationSummary
            let metadata = try await writer.fetchPresentationIndexMetadata()
            let snapshot = PresentationSnapshot(
                identity: identity,
                classificationRevision: PresentationClassificationRevision.make([:]),
                window: window,
                generatedAt: now,
                lastSourceCheckAt: metadata.lastSourceCheckAt,
                lastIndexCompletedAt: metadata.lastIndexCompletedAt,
                statisticsThrough: now,
                quota: startup.quota,
                home: home
            )
            let store = PresentationSnapshotStore(url: cacheURL)
            let permit = await store.activate(identity: identity)
            try await store.write(snapshot, permit: permit)
            let cacheAttributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
            guard FileManager.default.fileExists(atPath: cacheURL.path),
                  let cacheAttributes,
                  let size = cacheAttributes[.size] as? NSNumber,
                  size.intValue <= 2 * 1024 * 1024 else { throw FixtureError.invalidCache }
            cachePresent = true
        }
        let counts = try aggregateCounts(at: databaseURL)
        let metadata = try await writer.fetchPresentationIndexMetadata()
        let cacheFingerprint = cachePresent ? try digest(of: cacheURL) : nil
        let manifestDigest = FixtureManifest.digest(
            schemaVersion: 2, scenario: scenario, fixtureID: fixtureID,
            databaseFile: databaseURL.path, cacheFile: cacheURL.path,
            metricsDirectory: metricsURL.path, sourceDirectory: sourceURL.path,
            expectedDatabaseEpoch: identity.databaseEpoch, expectedDataGeneration: identity.dataGeneration,
            expectedLastSourceCheckAt: metadata.lastSourceCheckAt,
            expectedLastIndexCompletedAt: metadata.lastIndexCompletedAt,
            expectedResourceCount: counts.resources, expectedProjectCount: counts.projects,
            expectedSessionCount: counts.sessions, expectedCallCount: counts.calls,
            expectedQuotaCount: counts.quotas, expectedRecentQuotaCount: counts.recentQuotas,
            expectedCacheFingerprint: cacheFingerprint)
        let manifest = FixtureManifest(schemaVersion: 2, scenario: scenario, fixtureID: fixtureID,
                                       databaseFile: databaseURL.path, cacheFile: cacheURL.path,
                                       metricsDirectory: metricsURL.path, sourceDirectory: sourceURL.path,
                                       expectedDatabaseEpoch: identity.databaseEpoch, expectedDataGeneration: identity.dataGeneration,
                                       expectedLastSourceCheckAt: metadata.lastSourceCheckAt,
                                       expectedLastIndexCompletedAt: metadata.lastIndexCompletedAt,
                                       expectedResourceCount: counts.resources, expectedProjectCount: counts.projects,
                                       expectedSessionCount: counts.sessions, expectedCallCount: counts.calls,
                                       expectedQuotaCount: counts.quotas, expectedRecentQuotaCount: counts.recentQuotas,
                                       expectedCacheFingerprint: cacheFingerprint, manifestDigest: manifestDigest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let currentURL = root.appendingPathComponent("current-manifest.json")
        if FileManager.default.fileExists(atPath: currentURL.path) {
            guard (try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  (try? currentURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: currentURL.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
                  let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 32 * 1024 else { throw FixtureError.unsafeRoot }
        }
        try manifestData.write(to: currentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL.path)
        print("stage=fixture_prepared scenario=\(scenario) resources=\(counts.resources) projects=\(counts.projects) sessions=\(counts.sessions) calls=\(counts.calls) quota_rows=\(counts.quotas) recent_quota_rows=\(counts.recentQuotas) cache=\(cachePresent ? 1 : 0) indexed=\(indexed ? 1 : 0) source_sentinels=2")
    }

    static func preflight(scenario: String, fixtureID: String) async throws {
        let manifestURL = root.appendingPathComponent("current-manifest.json")
        guard (try? manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              (try? manifestURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let manifestAttributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
              let manifestOwner = manifestAttributes[.ownerAccountID] as? NSNumber, manifestOwner.uint32Value == getuid(),
              let manifestPermissions = manifestAttributes[.posixPermissions] as? NSNumber, manifestPermissions.intValue & 0o077 == 0,
              let manifestLinks = manifestAttributes[.referenceCount] as? NSNumber, manifestLinks.intValue == 1,
              let manifestSize = manifestAttributes[.size] as? NSNumber, manifestSize.intValue <= 32 * 1024,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(FixtureManifest.self, from: data),
              manifest.fixtureID == fixtureID, manifest.scenario == scenario else { throw FixtureError.invalidManifest }
        try manifest.validated()
        try validateManifestPaths(manifest)
        let databaseURL = URL(fileURLWithPath: manifest.databaseFile)
        let reader = try DatabaseStore(url: databaseURL, readOnly: true)
        let identity = try await reader.presentationIdentity()
        let metadata = try await reader.fetchPresentationIndexMetadata()
        let counts = try aggregateCounts(at: databaseURL)
        guard identity.databaseEpoch == manifest.expectedDatabaseEpoch,
              identity.dataGeneration == manifest.expectedDataGeneration,
              metadata.lastSourceCheckAt == manifest.expectedLastSourceCheckAt,
              metadata.lastIndexCompletedAt == manifest.expectedLastIndexCompletedAt,
              counts.resources == manifest.expectedResourceCount,
              counts.projects == manifest.expectedProjectCount,
              counts.sessions == manifest.expectedSessionCount,
              counts.calls == manifest.expectedCallCount,
              counts.quotas == manifest.expectedQuotaCount,
              counts.recentQuotas == manifest.expectedRecentQuotaCount else { throw FixtureError.invalidManifest }
        if let expected = manifest.expectedCacheFingerprint {
            guard FileManager.default.fileExists(atPath: manifest.cacheFile), try digest(of: URL(fileURLWithPath: manifest.cacheFile)) == expected else { throw FixtureError.invalidCache }
        } else if FileManager.default.fileExists(atPath: manifest.cacheFile) {
            throw FixtureError.invalidCache
        }
        print("stage=fixture_preflight scenario=\(scenario) resources=\(counts.resources) projects=\(counts.projects) sessions=\(counts.sessions) calls=\(counts.calls) quota_rows=\(counts.quotas) recent_quota_rows=\(counts.recentQuotas) identity_checked=1 metadata_checked=1 cache_fingerprint_checked=\(manifest.expectedCacheFingerprint == nil ? 0 : 1)")
    }

    static func validateManifestPaths(_ manifest: FixtureManifest) throws {
        let fixtureRoot = root.appendingPathComponent(manifest.fixtureID, isDirectory: true)
        guard fixtureRoot.resolvingSymlinksInPath().path == "\(canonicalRootPath)/\(manifest.fixtureID)",
              (try? fixtureRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let rootAttrs = try? FileManager.default.attributesOfItem(atPath: fixtureRoot.path),
              let rootOwner = rootAttrs[.ownerAccountID] as? NSNumber, rootOwner.uint32Value == getuid(),
              let rootPermissions = rootAttrs[.posixPermissions] as? NSNumber, rootPermissions.intValue & 0o077 == 0 else {
            throw FixtureError.unsafeRoot
        }
        func directChild(_ path: String, _ name: String, directory: Bool, required: Bool = true) throws {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let expected = fixtureRoot.appendingPathComponent(name, isDirectory: directory).standardizedFileURL
            guard url.path == expected.path,
                  url.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else { throw FixtureError.invalidManifest }
            if !required {
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      !FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.invalidCache }
                return
            }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  FileManager.default.fileExists(atPath: url.path),
                  url.resolvingSymlinksInPath().path == url.path else { throw FixtureError.invalidManifest }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard (directory ? values.isDirectory : values.isRegularFile) == true else { throw FixtureError.invalidManifest }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { throw FixtureError.invalidManifest }
            if !directory {
                guard let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1 else { throw FixtureError.invalidManifest }
            }
        }
        try directChild(manifest.databaseFile, "database.sqlite", directory: false)
        try directChild(manifest.metricsDirectory, "metrics", directory: true)
        try directChild(manifest.sourceDirectory, "sources", directory: true)
        try directChild(manifest.cacheFile, "presentation.json", directory: false, required: manifest.scenario != "cachedIndexed" ? false : true)
        let sourceURL = URL(fileURLWithPath: manifest.sourceDirectory)
        let sourceNames = Set((try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
        guard sourceNames == Set(["fixture-events.jsonl", "fixture-project.md"]) else { throw FixtureError.invalidManifest }
        for name in sourceNames {
            let url = sourceURL.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1,
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  let size = attrs[.size] as? NSNumber, size.intValue <= 64 * 1024,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw FixtureError.invalidManifest }
        }
        let metricsURL = URL(fileURLWithPath: manifest.metricsDirectory)
        for url in try FileManager.default.contentsOfDirectory(at: metricsURL, includingPropertiesForKeys: nil) {
            let suffix = String(url.deletingPathExtension().lastPathComponent.dropFirst("startup-metrics-".count))
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("startup-metrics-"), UUID(uuidString: suffix) != nil,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1,
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  let size = attrs[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else { throw FixtureError.invalidManifest }
        }
    }

    static func populate(_ store: DatabaseStore, now: Date) async throws {
        let resources = makeResources(now: now)
        try await store.replaceResourceInventory(resources: resources, projects: [
            CapabilityProject(id: "project-a-long-stable-id", name: "Synthetic Project A", lastSeenAt: now),
            CapabilityProject(id: "project-b-long-stable-id", name: "Synthetic Project B", lastSeenAt: now)
        ], relations: [
            ResourceRelation(sourceResourceID: "plugin-owner-long-stable-id", targetResourceID: "plugin-child-long-stable-id", relationKind: "contains", confidence: .exact, evidenceSummary: "synthetic"),
            ResourceRelation(sourceResourceID: "plugin-owner-long-stable-id", targetResourceID: "ambiguous-child-long-stable-id", relationKind: "contains", confidence: .exact, evidenceSummary: "synthetic"),
            ResourceRelation(sourceResourceID: "plugin-other-long-stable-id", targetResourceID: "ambiguous-child-long-stable-id", relationKind: "contains", confidence: .exact, evidenceSummary: "synthetic")
        ])
        var callOrdinal = 0
        for sessionNumber in 1...1500 {
            let count = sessionNumber == 1 ? 27_000 : 88 + (sessionNumber <= 1_089 ? 1 : 0)
            let sessionID = String(format: "session-%04d-long-stable-identifier", sessionNumber)
            let projectID = sessionNumber.isMultiple(of: 2) ? "project-a-long-stable-id" : "project-b-long-stable-id"
            var calls: [InvocationEvent] = []; calls.reserveCapacity(count)
            for ordinal in 0..<count {
                callOrdinal += 1
                let id = String(format: "call-%06d-long-stable-identifier", callOrdinal)
                let wrapper = callOrdinal % 46 == 24
                let child = callOrdinal.isMultiple(of: 23) || wrapper
                let ambiguous = callOrdinal.isMultiple(of: 29)
                let resourceID = child ? (ambiguous ? "ambiguous-child-long-stable-id" : "plugin-child-long-stable-id") : (callOrdinal.isMultiple(of: 7) ? "custom-skill-long-stable-id" : "custom-agent-long-stable-id")
                let parentID = wrapper ? String(format: "call-%06d-long-stable-identifier", max(1, callOrdinal - 1)) : nil
                calls.append(InvocationEvent(id: id, sessionID: sessionID, parentCallID: parentID, ordinal: ordinal,
                    timestamp: now.addingTimeInterval(-Double(callOrdinal % 100_000) * 60), actorName: callOrdinal.isMultiple(of: 31) ? "synthetic.namespace" : nil,
                    resourceID: resourceID, kind: wrapper ? .tool : (child ? .skill : .agent),
                    status: callOrdinal.isMultiple(of: 101) ? .failed : (callOrdinal.isMultiple(of: 199) ? .interrupted : .completed),
                    durationMs: 1 + callOrdinal % 40, confidence: .exact, errorCategory: callOrdinal.isMultiple(of: 101) ? "synthetic_failure" : nil))
            }
            let session = TaskSummary(id: sessionID, projectID: projectID,
                startedAt: now.addingTimeInterval(-Double(sessionNumber) * 3600), endedAt: now.addingTimeInterval(-Double(sessionNumber) * 3600 + 1),
                status: .completed, coverage: .complete, parserVersion: "1.2.0", sourceFileID: "source-\(sessionNumber)", title: nil)
            var quotas: [QuotaSnapshot] = []
            if sessionNumber == 1 {
                quotas.reserveCapacity(200_000)
                for index in 0..<200_000 {
                    let captured = index < 192_000 ? now.addingTimeInterval(-Double(200_000 - index) * 3600) : now.addingTimeInterval(-Double(200_000 - index) * 60)
                    quotas.append(try QuotaSnapshot(id: String(format: "quota-%06d-long-stable-identifier", index), capturedAt: captured,
                        windowMinutes: index < 192_000 && index.isMultiple(of: 11) ? 300 : 10_080, usedPercent: Double(10 + index % 80),
                        resetsAt: index.isMultiple(of: 37) ? now.addingTimeInterval(3600) : nil,
                        limitID: index.isMultiple(of: 2) ? "source-a-long-stable-id" : "source-b-long-stable-id",
                        limitName: index.isMultiple(of: 2) ? "Synthetic Source A" : "Synthetic Source B", confidence: .exact))
                }
            }
            try await store.replaceSession(PersistedSessionBatch(session: session, calls: calls, tokenSnapshots: [], quotaSnapshots: quotas, findings: []), resetExisting: false)
        }
    }

    static func makeResources(now: Date) -> [CapabilityResource] {
        func resource(_ id: String, _ name: String, _ kind: ResourceKind, _ scope: ResourceScope, _ project: String?, _ ownership: ResourceOwnership, _ origin: ResourceOrigin = .local) -> CapabilityResource {
            CapabilityResource(id: id, name: name, kind: kind, status: .success, scope: scope, projectID: project, confidence: .exact, summary: "synthetic fixture", sourceRootID: "startup-perf-fixture", relativeSourcePath: id + ".md", sourcePathHash: "hash-" + id, lastSeenAt: now, ownership: ownership, origin: origin, classificationConfidence: .exact)
        }
        return [
            resource("custom-agent-long-stable-id", "Custom Agent", .agent, .global, nil, .userOwned),
            resource("custom-agent-project-long-stable-id", "Project Agent", .agent, .project, "project-a-long-stable-id", .userOwned),
            resource("custom-skill-long-stable-id", "Custom Skill", .skill, .global, nil, .userOwned),
            resource("custom-skill-project-long-stable-id", "Project Skill", .skill, .project, "project-b-long-stable-id", .userOwned),
            resource("plugin-owner-long-stable-id", "Installed Plugin", .plugin, .runtime, nil, .installed, .plugin),
            resource("plugin-other-long-stable-id", "Second Plugin", .plugin, .runtime, nil, .installed, .plugin),
            resource("plugin-child-long-stable-id", "Plugin Skill", .skill, .plugin, nil, .pluginProvided, .plugin),
            resource("ambiguous-child-long-stable-id", "Ambiguous Skill", .skill, .plugin, nil, .pluginProvided, .plugin),
            resource("independent-namespace-long-id", "Independent Namespace", .mcp, .runtime, nil, .runtime, .runtime)
        ]
    }

    static func writeSentinelSources(to directory: URL) throws {
        let files = [
            ("fixture-project.md", Data("# startup fixture sentinel\n".utf8)),
            ("fixture-events.jsonl", Data("{\"type\":\"synthetic_sentinel\"}\n".utf8))
        ]
        for (name, data) in files {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func makeCalendar() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }

    static func aggregateCounts(at url: URL) throws -> (resources: Int, projects: Int, sessions: Int, calls: Int, quotas: Int, recentQuotas: Int) {
        guard let connection = SQLiteConnection(url: url, readOnly: true) else { throw FixtureError.unsafeRoot }
        func count(_ table: String, where clause: String? = nil) throws -> Int {
            let statement = try connection.prepare("SELECT COUNT(*) FROM \(table)\(clause.map { " WHERE \($0)" } ?? "")")
            guard try statement.step() == .row else { return 0 }; return statement.columnInt(0)
        }
        let cutoff = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        return (try count("resources"), try count("projects"), try count("sessions"), try count("calls"), try count("quota_snapshots"), try count("quota_snapshots", where: "captured_at >= \(cutoff)"))
    }
}
