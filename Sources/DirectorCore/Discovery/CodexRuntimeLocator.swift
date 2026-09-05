import Foundation

public enum CodexRuntimeSource: String, Codable, Hashable, Sendable {
    case userSelected
    case codexApplication
    case chatGPTApplication
    case path
}

public enum CodexRuntimePermission: String, Codable, Hashable, Sendable {
    case executable
    case notExecutable
    case missing
}

public enum CodexRuntimeCompatibility: String, Codable, Hashable, Sendable {
    case compatible
    case unknown
    case incompatible
}

public enum CodexRuntimeIssue: String, Codable, Hashable, Sendable {
    case runtimeNotFound
    case notExecutable
    case versionUnavailable
    case incompatibleVersion
}

public struct CodexRuntimeStatus: Hashable, Sendable {
    public let executableURL: URL?
    public let source: CodexRuntimeSource?
    public let version: String?
    public let compatibility: CodexRuntimeCompatibility
    public let permission: CodexRuntimePermission
    public let issue: CodexRuntimeIssue?

    public init(
        executableURL: URL?,
        source: CodexRuntimeSource?,
        version: String?,
        compatibility: CodexRuntimeCompatibility,
        permission: CodexRuntimePermission,
        issue: CodexRuntimeIssue?
    ) {
        self.executableURL = executableURL
        self.source = source
        self.version = version
        self.compatibility = compatibility
        self.permission = permission
        self.issue = issue
    }

    public var isUsable: Bool {
        permission == .executable && compatibility != .incompatible
    }

    public static let unavailable = CodexRuntimeStatus(
        executableURL: nil,
        source: nil,
        version: nil,
        compatibility: .unknown,
        permission: .missing,
        issue: .runtimeNotFound
    )
}

public struct CodexRuntimeCandidate: Hashable, Sendable {
    public let url: URL
    public let source: CodexRuntimeSource

    public init(url: URL, source: CodexRuntimeSource) {
        self.url = url.standardizedFileURL
        self.source = source
    }
}

/// Locates an existing Codex CLI without installing software, invoking a
/// shell, changing PATH, or reading account information.
public struct CodexRuntimeLocator: Sendable {
    public typealias FileCheck = @Sendable (URL) -> Bool
    public typealias VersionProbe = @Sendable (URL) async -> String?

    public static let defaultApplicationCandidates: [CodexRuntimeCandidate] = [
        CodexRuntimeCandidate(
            url: URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            source: .codexApplication
        ),
        CodexRuntimeCandidate(
            url: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            source: .chatGPTApplication
        ),
    ]

    private let knownApplicationCandidates: [CodexRuntimeCandidate]
    private let environment: [String: String]
    private let fileExists: FileCheck
    private let isRegularFile: FileCheck
    private let isExecutable: FileCheck
    private let versionProbe: VersionProbe

    public init() {
        knownApplicationCandidates = Self.defaultApplicationCandidates
        environment = ProcessInfo.processInfo.environment
        fileExists = { FileManager.default.fileExists(atPath: $0.path) }
        isRegularFile = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        isExecutable = { FileManager.default.isExecutableFile(atPath: $0.path) }
        versionProbe = { await Self.probeVersion(at: $0) }
    }

    public init(
        knownApplicationCandidates: [CodexRuntimeCandidate],
        environment: [String: String],
        fileExists: @escaping FileCheck,
        isRegularFile: @escaping FileCheck,
        isExecutable: @escaping FileCheck,
        versionProbe: @escaping VersionProbe
    ) {
        self.knownApplicationCandidates = knownApplicationCandidates
        self.environment = environment
        self.fileExists = fileExists
        self.isRegularFile = isRegularFile
        self.isExecutable = isExecutable
        self.versionProbe = versionProbe
    }

    public func locate(userSelectedURL: URL? = nil) async -> CodexRuntimeStatus {
        if let userSelectedURL {
            return await inspect(
                CodexRuntimeCandidate(url: userSelectedURL, source: .userSelected),
                strict: true
            ) ?? .unavailable
        }

        let candidates = deduplicated(knownApplicationCandidates + pathCandidates())
        var firstFailure: CodexRuntimeStatus?
        for candidate in candidates {
            guard let status = await inspect(candidate, strict: false) else { continue }
            if status.isUsable { return status }
            if firstFailure == nil { firstFailure = status }
        }
        return firstFailure ?? .unavailable
    }

    private func inspect(_ candidate: CodexRuntimeCandidate, strict: Bool) async -> CodexRuntimeStatus? {
        let url = candidate.url
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return strict ? missingStatus(for: candidate) : nil
        }
        guard fileExists(url) else {
            return strict ? missingStatus(for: candidate) : nil
        }
        guard isRegularFile(url), isExecutable(url) else {
            return CodexRuntimeStatus(
                executableURL: url,
                source: candidate.source,
                version: nil,
                compatibility: .unknown,
                permission: .notExecutable,
                issue: .notExecutable
            )
        }

        guard let rawVersion = await versionProbe(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVersion.isEmpty else {
            return CodexRuntimeStatus(
                executableURL: url,
                source: candidate.source,
                version: nil,
                compatibility: .unknown,
                permission: .executable,
                issue: .versionUnavailable
            )
        }

        let displayVersion = String(rawVersion.split(whereSeparator: \Character.isNewline).first ?? "").prefix(128)
        let compatibility = Self.compatibility(for: String(displayVersion))
        return CodexRuntimeStatus(
            executableURL: url,
            source: candidate.source,
            version: compatibility == .incompatible ? nil : String(displayVersion),
            compatibility: compatibility,
            permission: .executable,
            issue: compatibility == .incompatible ? .incompatibleVersion : nil
        )
    }

    private func missingStatus(for candidate: CodexRuntimeCandidate) -> CodexRuntimeStatus {
        CodexRuntimeStatus(
            executableURL: candidate.url,
            source: candidate.source,
            version: nil,
            compatibility: .unknown,
            permission: .missing,
            issue: .runtimeNotFound
        )
    }

    private func pathCandidates() -> [CodexRuntimeCandidate] {
        (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { segment -> CodexRuntimeCandidate? in
                let directory = String(segment)
                guard directory.hasPrefix("/"), !directory.isEmpty else { return nil }
                return CodexRuntimeCandidate(
                    url: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("codex"),
                    source: .path
                )
            }
    }

    private func deduplicated(_ candidates: [CodexRuntimeCandidate]) -> [CodexRuntimeCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.path).inserted }
    }

    private static func compatibility(for version: String) -> CodexRuntimeCompatibility {
        let fields = version.lowercased().split(whereSeparator: \Character.isWhitespace)
        guard let product = fields.first, product == "codex-cli" || product == "codex" else {
            return .incompatible
        }
        guard fields.dropFirst().contains(where: { field in
            field.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9a-z.-]+)?$"#, options: .regularExpression) != nil
        }) else {
            return .unknown
        }
        return .compatible
    }

    private static func probeVersion(at url: URL) async -> String? {
        let client = ProcessRuntimeCommandClient(executableURL: url, timeoutSeconds: 3, maxOutputBytes: 4_096)
        guard let result = try? await client.run(arguments: ["--version"]),
              result.exitCode == 0,
              !result.timedOut else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// App-owned preference for an explicit runtime path. It stores only a local
/// absolute path in Codex Director's own UserDefaults domain.
public final class CodexRuntimePreferenceStore: @unchecked Sendable {
    public static let preferenceKey = "com.peiweitang.CodexDirector.codexRuntimePath"

    private let readPreference: () -> String?
    private let writePreference: (String) -> Void
    private let removePreference: () -> Void

    public init(defaults: UserDefaults = .standard) {
        readPreference = { defaults.string(forKey: Self.preferenceKey) }
        writePreference = { defaults.set($0, forKey: Self.preferenceKey) }
        removePreference = { defaults.removeObject(forKey: Self.preferenceKey) }
    }

    public init(memoryURL: URL?) {
        let storage = CodexRuntimeMemoryPreference(value: Self.validatedPath(memoryURL))
        readPreference = { storage.get() }
        writePreference = { storage.set($0) }
        removePreference = { storage.set(nil) }
    }

    public init(
        readPreference: @escaping () -> String?,
        writePreference: @escaping (String) -> Void,
        removePreference: @escaping () -> Void
    ) {
        self.readPreference = readPreference
        self.writePreference = writePreference
        self.removePreference = removePreference
    }

    public func selectedURL() -> URL? {
        guard let rawValue = readPreference(), Self.isValidPath(rawValue) else {
            return nil
        }
        return URL(fileURLWithPath: rawValue).standardizedFileURL
    }

    @discardableResult
    public func setSelectedURL(_ url: URL) -> Bool {
        guard let path = Self.validatedPath(url) else { return false }
        writePreference(path)
        return selectedURL()?.path == path
    }

    public func clear() {
        removePreference()
    }

    private static func validatedPath(_ url: URL?) -> String? {
        guard let url, url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard Self.isValidPath(path) else { return nil }
        return path
    }

    private static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= 4_096
            && path.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

private final class CodexRuntimeMemoryPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(value: String?) {
        self.value = value
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
