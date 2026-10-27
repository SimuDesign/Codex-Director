import Foundation

/// Privacy-safe in-memory normalization for the project registry layouts that
/// Director understands. The registry is metadata about existing capabilities;
/// package records never become source resources by themselves.
struct CodexProjectRegistry {
    static let maximumByteCount = 2 * 1_024 * 1_024

    enum PackageKind: Equatable, Hashable, Sendable {
        case nativeAgent
        case auxiliarySkill
        case agent
        case skill
        case unknown
    }

    enum Version: Equatable, Sendable {
        case legacy
        case v3
        case v5
    }

    enum LegacyKind: Equatable, Sendable {
        case unspecified
        case agent
        case skill
        case workflow
        case unsupported
    }

    enum ParseResult: Equatable, Sendable {
        case success(Document)
        case unsupportedVersion
        case invalid
    }

    struct LegacyEntry: Equatable, Sendable {
        let name: String
        let kind: LegacyKind
        let description: String?
        let skillName: String?
        let usesSkills: [String]
        let invokedBy: [String]
    }

    struct Package: Equatable, Sendable {
        let id: String?
        let name: String?
        let kind: PackageKind
        let nativeAgent: String?
        let usesSkills: [String]
        let invokedBy: [String]
    }

    struct Document: Equatable, Sendable {
        let version: Version
        let legacyEntries: [LegacyEntry]
        let packages: [Package]
    }

    static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maximumByteCount,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .invalid }

        guard let version = supportedVersion(in: dictionary) else {
            if hasVersionMetadata(in: dictionary) { return .unsupportedVersion }
            return .invalid
        }

        var legacyEntries: [LegacyEntry] = []
        var packages: [Package] = []
        var hasSupportedLayout = false

        if let rawEntries = dictionary["entries"] {
            guard let entries = rawEntries as? [Any] else { return .invalid }
            hasSupportedLayout = true
            for rawEntry in entries {
                guard let entry = rawEntry as? [String: Any] else { return .invalid }
                guard let name = nonEmptyString(entry["name"]) else { continue }
                let kindValue = entry["type"] ?? entry["kind"]
                if kindValue != nil, nonEmptyString(kindValue) == nil { return .invalid }
                let kind = normalizeLegacyKind(nonEmptyString(kindValue))
                let description = optionalString(entry["description"])
                guard let usesSkills = referenceValues(entry["usesSkills"]),
                      let invokedBy = referenceValues(entry["invokedBy"]) else { return .invalid }
                let skillName = optionalString(entry["skillName"] ?? entry["skill"])
                legacyEntries.append(LegacyEntry(
                    name: name,
                    kind: kind,
                    description: description,
                    skillName: skillName,
                    usesSkills: usesSkills,
                    invokedBy: invokedBy
                ))
            }
        }

        if let rawPackages = dictionary["packages"] {
            hasSupportedLayout = true
            switch rawPackages {
            case let packageArray as [Any]:
                for rawPackage in packageArray {
                    guard let package = rawPackage as? [String: Any],
                          let normalized = normalizePackage(package, fallbackID: nil) else { return .invalid }
                    packages.append(normalized)
                }
            case let packageObject as [String: Any]:
                for (fallbackID, rawPackage) in packageObject {
                    guard let package = rawPackage as? [String: Any],
                          let normalized = normalizePackage(package, fallbackID: fallbackID) else { return .invalid }
                    packages.append(normalized)
                }
            default:
                return .invalid
            }
        }

        guard hasSupportedLayout,
              !hasConflictingPackageIDs(packages) else { return .invalid }
        return .success(Document(version: version, legacyEntries: legacyEntries, packages: packages))
    }

    private static func supportedVersion(in dictionary: [String: Any]) -> Version? {
        let schema = versionField(dictionary["schema"], allowsString: true)
        let schemaVersion = versionField(dictionary["schemaVersion"], allowsString: false)
        guard schema != .invalid, schemaVersion != .invalid else { return nil }
        if schema != .absent, schemaVersion != .absent, schema != schemaVersion { return nil }
        let effective: VersionField = schemaVersion == .absent ? schema : schemaVersion
        switch effective {
        case .absent, .value(1): return .legacy
        case .value(3): return .v3
        case .value(5): return .v5
        default: return nil
        }
    }

    private static func hasVersionMetadata(in dictionary: [String: Any]) -> Bool {
        dictionary["schema"] != nil || dictionary["schemaVersion"] != nil
    }

    private enum VersionField: Equatable {
        case absent
        case value(Int)
        case invalid
    }

    private static func versionField(_ value: Any?, allowsString: Bool) -> VersionField {
        guard let value else { return .absent }
        if allowsString, let string = value as? String,
           let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .value(parsed)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max) else { return .invalid }
        return .value(number.intValue)
    }

    private struct PackageIdentity: Hashable {
        let kind: PackageKind
        let name: String?
        let nativeAgent: String?
    }

    private static func hasConflictingPackageIDs(_ packages: [Package]) -> Bool {
        var identitiesByID: [String: Set<PackageIdentity>] = [:]
        for package in packages {
            guard let id = package.id else { continue }
            identitiesByID[normalizeID(id), default: []].insert(PackageIdentity(
                kind: package.kind,
                name: package.name.map(normalizeID),
                nativeAgent: package.nativeAgent.map(normalizeID)
            ))
        }
        return identitiesByID.values.contains { $0.count > 1 }
    }

    private static func normalizeID(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func normalizePackage(_ package: [String: Any], fallbackID: String?) -> Package? {
        for key in ["id", "packageID", "name", "kind", "type", "nativeAgent"] {
            if package[key] != nil, nonEmptyString(package[key]) == nil { return nil }
        }
        let explicitID = optionalString(package["id"])
        let packageID = optionalString(package["packageID"])
        if let explicitID, let packageID,
           normalizeID(explicitID) != normalizeID(packageID) {
            return nil
        }
        let id = explicitID ?? packageID ?? fallbackID
        let name = optionalString(package["name"])
        let explicitKind = optionalString(package["kind"])
        let explicitType = optionalString(package["type"])
        if let explicitKind, let explicitType {
            let normalizedKind = normalizeKind(explicitKind)
            let normalizedType = normalizeKind(explicitType)
            let equivalent = normalizedKind == .unknown && normalizedType == .unknown
                ? normalizeID(explicitKind) == normalizeID(explicitType)
                : normalizedKind == normalizedType
            if !equivalent { return nil }
        }
        let kindValue = explicitKind ?? explicitType
        let kind = normalizeKind(kindValue)
        let nativeAgent = optionalString(package["nativeAgent"])
        guard let usesSkills = referenceValues(package["usesSkills"]),
              let invokedBy = referenceValues(package["invokedBy"]) else { return nil }

        // A package must carry an identity or a supported declaration field.
        // Unknown ancillary package records are accepted for coverage but do
        // not create any relation or capability.
        guard id != nil || name != nil || nativeAgent != nil || !usesSkills.isEmpty || !invokedBy.isEmpty || kind != .unknown else {
            return nil
        }
        return Package(
            id: id,
            name: name,
            kind: kind,
            nativeAgent: nativeAgent,
            usesSkills: usesSkills,
            invokedBy: invokedBy
        )
    }

    private static func normalizeKind(_ value: String?) -> PackageKind {
        guard let value else { return .unknown }
        let key = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        switch key {
        case "native-agent", "nativeagent": return .nativeAgent
        case "auxiliary-skill", "auxiliaryskill": return .auxiliarySkill
        case "agent": return .agent
        case "skill": return .skill
        default: return .unknown
        }
    }

    private static func normalizeLegacyKind(_ value: String?) -> LegacyKind {
        guard let value else { return .unspecified }
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-") {
        case "agent", "native-agent", "nativeagent": return .agent
        case "skill", "auxiliary-skill", "auxiliaryskill": return .skill
        case "workflow": return .workflow
        default: return .unsupported
        }
    }

    private static func referenceValues(_ value: Any?) -> [String]? {
        guard let value else { return [] }
        if let string = nonEmptyString(value) { return [string] }
        guard let array = value as? [Any] else { return nil }
        var result: [String] = []
        for item in array {
            if let string = nonEmptyString(item) {
                result.append(string)
                continue
            }
            guard let object = item as? [String: Any] else { return nil }
            var references: [String] = []
            for key in ["nativeAgent", "id", "name"] where object[key] != nil {
                guard let reference = nonEmptyString(object[key]) else { return nil }
                references.append(reference)
            }
            guard !references.isEmpty else { return nil }
            let normalized = Set(references.map(normalizeID))
            guard normalized.count == 1, let reference = normalized.first else { return nil }
            result.append(reference)
        }
        return result
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard value != nil else { return nil }
        return nonEmptyString(value)
    }
}
