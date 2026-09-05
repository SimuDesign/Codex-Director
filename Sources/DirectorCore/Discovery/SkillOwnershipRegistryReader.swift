import Foundation

/// A privacy-safe reference from the user-owned Skill registry to one
/// discoverable manifest. Absolute paths never leave the reader.
public struct SkillOwnershipRegistration: Sendable, Equatable, Hashable {
    public let rootID: String
    public let relativeManifestPath: String

    public init(rootID: String, relativeManifestPath: String) {
        self.rootID = rootID
        self.relativeManifestPath = relativeManifestPath
    }
}

public struct SkillOwnershipRegistryOutput: Sendable, Equatable {
    public let registrations: Set<SkillOwnershipRegistration>
    public let issues: [DiscoveryIssue]

    public init(
        registrations: Set<SkillOwnershipRegistration> = [],
        issues: [DiscoveryIssue] = []
    ) {
        self.registrations = registrations
        self.issues = issues
    }
}

/// Reads explicit path bullets from the `Global Skill Library` section of the
/// user's global AGENTS.md. The reader is intentionally narrow: prose mentions,
/// display names, and paths outside approved global Skill roots are not
/// ownership evidence.
public struct SkillOwnershipRegistryReader: Sendable {
    private static let issueRootID = "skill-ownership-registry"
    private static let sectionHeading = "# Global Skill Library"
    private static let maximumDocumentBytes: UInt64 = 1_048_576

    private let fileSystem: FileSystemClient

    public init(fileSystem: FileSystemClient = FileSystemClient()) {
        self.fileSystem = fileSystem
    }

    public func read(
        from registryURL: URL?,
        globalSkillRoots: [ScanRoot]
    ) -> SkillOwnershipRegistryOutput {
        guard let registryURL else { return SkillOwnershipRegistryOutput() }
        guard fileSystem.exists(registryURL) else {
            return issue("Global Skill Library registry is missing")
        }
        guard fileSystem.isReadable(registryURL), !fileSystem.isDirectory(registryURL) else {
            return issue("Global Skill Library registry is unreadable")
        }
        if let attributes = fileSystem.fileAttributes(registryURL),
           attributes.size > Self.maximumDocumentBytes {
            return issue("Global Skill Library registry exceeds the safe read limit")
        }
        guard let text = try? String(contentsOf: registryURL, encoding: .utf8) else {
            return issue("Global Skill Library registry could not be decoded")
        }

        let approvedRoots = globalSkillRoots
            .filter { $0.kind == .skills && $0.scope == .global }
            .sorted { $0.url.standardizedFileURL.path.count > $1.url.standardizedFileURL.path.count }
        guard !approvedRoots.isEmpty else { return SkillOwnershipRegistryOutput() }

        var registrations = Set<SkillOwnershipRegistration>()
        var issues: [DiscoveryIssue] = []
        var insideSection = false

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line == Self.sectionHeading {
                insideSection = true
                continue
            }
            if insideSection, line.hasPrefix("# ") {
                break
            }
            guard insideSection, line.hasPrefix("- "),
                  let declaredPath = Self.explicitManifestPath(in: line) else {
                continue
            }

            let lineReference = "line-\(offset + 1)"
            guard declaredPath.hasPrefix("/") else {
                issues.append(Self.issue(relativePath: lineReference, message: "Registered Skill path is not absolute"))
                continue
            }
            let manifest = URL(fileURLWithPath: declaredPath).standardizedFileURL
            guard manifest.lastPathComponent == "SKILL.md" else {
                issues.append(Self.issue(relativePath: lineReference, message: "Registered Skill path is not a SKILL.md manifest"))
                continue
            }
            guard let root = approvedRoots.first(where: { Self.isLexicallyWithin(manifest, root: $0.url) }),
                  Self.isResolvedWithin(manifest, root: root.url) else {
                issues.append(Self.issue(relativePath: lineReference, message: "Registered Skill path is outside approved roots"))
                continue
            }
            guard fileSystem.exists(manifest), fileSystem.isReadable(manifest), !fileSystem.isDirectory(manifest) else {
                issues.append(Self.issue(
                    relativePath: Self.relativePath(of: manifest, under: root.url),
                    message: "Registered Skill manifest is missing or unreadable"
                ))
                continue
            }

            let registration = SkillOwnershipRegistration(
                rootID: root.id,
                relativeManifestPath: Self.relativePath(of: manifest, under: root.url)
            )
            if !registrations.insert(registration).inserted {
                issues.append(Self.issue(
                    relativePath: lineReference,
                    message: "Duplicate registered Skill path was ignored"
                ))
            }
        }

        return SkillOwnershipRegistryOutput(registrations: registrations, issues: issues)
    }

    private func issue(_ message: String) -> SkillOwnershipRegistryOutput {
        SkillOwnershipRegistryOutput(issues: [Self.issue(relativePath: "", message: message)])
    }

    private static func issue(relativePath: String, message: String) -> DiscoveryIssue {
        DiscoveryIssue(rootID: issueRootID, relativePath: relativePath, message: message)
    }

    private static func explicitManifestPath(in bullet: String) -> String? {
        let parts = bullet.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count == 5,
              String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines) == "-",
              !String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) == ":",
              String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let path = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix("/SKILL.md") ? path : nil
    }

    private static func isLexicallyWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func isResolvedWithin(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
