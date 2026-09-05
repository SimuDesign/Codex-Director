import Foundation
import Darwin
import CryptoKit

/// Test-only launch configuration. It accepts data only from the harness
/// fixture root and never falls back to Application Support or user paths.
struct StartupPerformanceManifest: Codable, Equatable, Sendable {
    enum Scenario: String, Codable, Sendable {
        case cachedIndexed
        case uncachedIndexed
        case uncachedNoIndex
    }

    static let currentSchemaVersion = 2
    static let rootPrefix = "/tmp/codex-director-startup-perf"
    static let sourceSentinelNames = ["fixture-events.jsonl", "fixture-project.md"]
    static var canonicalRootPrefix: String {
        URL(fileURLWithPath: rootPrefix).resolvingSymlinksInPath().path
    }

    let schemaVersion: Int
    let scenario: Scenario
    let fixtureID: String
    let databaseFile: String
    /// Always present as a path; uncached scenarios intentionally omit only
    /// the file at this validated location.
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

    var fixtureRoot: URL {
        URL(fileURLWithPath: Self.rootPrefix, isDirectory: true)
            .appendingPathComponent(fixtureID, isDirectory: true)
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
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
            throw ValidationError.invalidManifest
        }
        let root = fixtureRoot.standardizedFileURL
        let rootPath = root.path + "/"
        guard root.resolvingSymlinksInPath().path.hasPrefix(Self.canonicalRootPrefix + "/"),
              FileManager.default.fileExists(atPath: root.path),
              root.resolvingSymlinksInPath().path == "\(Self.canonicalRootPrefix)/\(fixtureID)" else {
            throw ValidationError.invalidRoot
        }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw ValidationError.invalidRoot }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: root.path),
              let permissions = attrs[.posixPermissions] as? NSNumber,
              let owner = attrs[.ownerAccountID] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              owner.uint32Value == getuid() else { throw ValidationError.invalidRoot }

        try validateChild(databaseFile, named: "database.sqlite", rootPath: rootPath)
        try validateChild(metricsDirectory, named: "metrics", rootPath: rootPath)
        try validateChild(sourceDirectory, named: "sources", rootPath: rootPath)
        try validateChild(cacheFile, named: "presentation.json", rootPath: rootPath,
                          requireExists: scenario == .cachedIndexed)
        try validateSourceSentinels(at: URL(fileURLWithPath: sourceDirectory))
        try validateMetrics(at: URL(fileURLWithPath: metricsDirectory))
        // Every launch receives the same cache URL.  Indexed/uncached scenarios
        // deliberately omit only the file, so the production cache factory
        // follows the same path and a test runner can remove one validated
        // synthetic file between launches.
        return self
    }

    static func loadCurrent() throws -> Self {
        let rootURL = URL(fileURLWithPath: rootPrefix, isDirectory: true)
        guard (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              FileManager.default.fileExists(atPath: rootURL.path) else { throw ValidationError.invalidRoot }
        let url = rootURL
            .appendingPathComponent("current-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1,
              let size = attrs[.size] as? NSNumber, size.intValue <= 32 * 1024 else {
            throw ValidationError.invalidManifest
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url, options: [.mappedIfSafe]))
        return try manifest.validated()
    }

    var databaseURL: URL { URL(fileURLWithPath: databaseFile) }
    var cacheURL: URL { URL(fileURLWithPath: cacheFile) }
    var metricsURL: URL { URL(fileURLWithPath: metricsDirectory, isDirectory: true) }
    var sourceURL: URL { URL(fileURLWithPath: sourceDirectory, isDirectory: true) }

    enum ValidationError: Error { case invalidManifest, invalidRoot }

    private static func digest(schemaVersion: Int, scenario: Scenario, fixtureID: String,
                               databaseFile: String, cacheFile: String, metricsDirectory: String,
                               sourceDirectory: String, expectedDatabaseEpoch: String,
                               expectedDataGeneration: Int64, expectedLastSourceCheckAt: Date?,
                               expectedLastIndexCompletedAt: Date?, expectedResourceCount: Int,
                               expectedProjectCount: Int, expectedSessionCount: Int,
                               expectedCallCount: Int, expectedQuotaCount: Int,
                               expectedRecentQuotaCount: Int, expectedCacheFingerprint: String?) -> String {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let values = [String(schemaVersion), scenario.rawValue, fixtureID, databaseFile, cacheFile,
                      metricsDirectory, sourceDirectory, expectedDatabaseEpoch, String(expectedDataGeneration),
                      expectedLastSourceCheckAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "",
                      expectedLastIndexCompletedAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "",
                      String(expectedResourceCount), String(expectedProjectCount), String(expectedSessionCount),
                      String(expectedCallCount), String(expectedQuotaCount), String(expectedRecentQuotaCount),
                      expectedCacheFingerprint ?? ""]
        let data = Data(values.map(field).joined(separator: "|").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateChild(_ value: String, named expectedName: String, rootPath: String, requireExists: Bool = true) throws {
        let url = URL(fileURLWithPath: value).standardizedFileURL
        let expectedURL = URL(fileURLWithPath: rootPath).appendingPathComponent(expectedName).standardizedFileURL
        // `/tmp` and `/tmp` are equivalent on macOS, but a missing
        // path cannot be symlink-resolved. Normalize that allowlisted root
        // lexically first, then resolve existing paths for the escape check.
        guard Self.canonicalPath(url) == Self.canonicalPath(expectedURL) else {
            throw ValidationError.invalidManifest
        }
        if !requireExists {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  !FileManager.default.fileExists(atPath: url.path) else { throw ValidationError.invalidManifest }
            return
        }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              FileManager.default.fileExists(atPath: url.path),
              url.resolvingSymlinksInPath().path == expectedURL.resolvingSymlinksInPath().path else { throw ValidationError.invalidManifest }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if expectedName == "metrics" || expectedName == "sources" {
            guard values.isDirectory == true,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  let permissions = attrs[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else {
                throw ValidationError.invalidManifest
            }
        } else {
            guard values.isRegularFile == true else { throw ValidationError.invalidManifest }
            try validateOwnedRegularFile(url, maxBytes: expectedName == "presentation.json" ? 2 * 1024 * 1024 : Int.max)
        }
    }

    private func validateSourceSentinels(at directory: URL) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              Set(entries.map(\.lastPathComponent)) == Set(Self.sourceSentinelNames) else {
            throw ValidationError.invalidManifest
        }
        for name in Self.sourceSentinelNames {
            try validateOwnedRegularFile(directory.appendingPathComponent(name), maxBytes: 64 * 1024)
        }
    }

    private func validateMetrics(at directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                  url.pathExtension == "json", url.lastPathComponent.hasPrefix("startup-metrics-"),
                  UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst("startup-metrics-".count))) != nil else {
                throw ValidationError.invalidManifest
            }
            try validateOwnedRegularFile(url, maxBytes: 4 * 1024 * 1024)
        }
    }

    private func validateOwnedRegularFile(_ url: URL, maxBytes: Int) throws {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let links = attrs[.referenceCount] as? NSNumber, links.intValue == 1,
              let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else {
            throw ValidationError.invalidManifest
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        let normalized = url.standardizedFileURL.path
        let rawRoot = rootPrefix
        let normalizedRoot = URL(fileURLWithPath: rootPrefix, isDirectory: true).standardizedFileURL.path
        if normalized == rawRoot || normalized.hasPrefix(rawRoot + "/") {
            return canonicalRootPrefix + String(normalized.dropFirst(rawRoot.count))
        }
        if normalized == normalizedRoot || normalized.hasPrefix(normalizedRoot + "/") {
            return canonicalRootPrefix + String(normalized.dropFirst(normalizedRoot.count))
        }
        return url.resolvingSymlinksInPath().path
    }
}
