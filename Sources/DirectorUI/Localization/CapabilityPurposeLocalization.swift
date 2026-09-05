import Foundation
import CryptoKit
import DirectorCore

/// One offline, presentation-only translation of a declared capability
/// purpose. Stable identity, kind, name, and source text must all match before
/// the translation can be shown.
public struct CapabilityPurposeLocalizationEntry: Sendable, Equatable, Hashable {
    public let resourceID: String
    public let kind: ResourceKind
    public let sourceName: String
    public let sourcePurposeSignature: String
    public let chinesePurpose: String

    public init(
        resourceID: String,
        kind: ResourceKind,
        sourceName: String,
        sourcePurpose: String,
        chinesePurpose: String
    ) {
        self.resourceID = resourceID
        self.kind = kind
        self.sourceName = sourceName
        self.sourcePurposeSignature = CapabilityPurposeLocalization.signature(sourcePurpose)
        self.chinesePurpose = chinesePurpose
    }

    init(
        resourceID: String,
        kind: ResourceKind,
        sourceName: String,
        sourcePurposeSignature: String,
        chinesePurpose: String
    ) {
        self.resourceID = resourceID
        self.kind = kind
        self.sourceName = sourceName
        self.sourcePurposeSignature = sourcePurposeSignature
        self.chinesePurpose = chinesePurpose
    }
}

/// Shared localization boundary for Agent and Skill purpose text. It never
/// changes the indexed source text and has no filesystem or network access.
public enum CapabilityPurposeLocalization {
    private static let invalidPurposeSentinels: Set<String> = [">", ">-", "|", "|-"]

    public static let entries: [CapabilityPurposeLocalizationEntry] =
        CapabilityPurposeAgentCatalog.entries + CapabilityPurposeSkillCatalog.entries

    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    public static func signature(_ value: String?) -> String {
        let digest = SHA256.hash(data: Data(normalized(value ?? "").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func meaningfulSource(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !invalidPurposeSentinels.contains(trimmed) else { return nil }
        return value
    }

    public static func localizedSummary(
        for resource: CapabilityResource,
        language: AppLanguage,
        catalog: [CapabilityPurposeLocalizationEntry] = entries
    ) -> String? {
        guard let source = meaningfulSource(resource.summary) else { return nil }
        guard language == .simplifiedChinese else { return source }
        let name = normalized(resource.name)
        let sourceSignature = signature(source)
        guard let entry = catalog.first(where: {
            $0.resourceID == resource.id
                && $0.kind == resource.kind
                && normalized($0.sourceName) == name
                && $0.sourcePurposeSignature == sourceSignature
        }) else { return source }
        return entry.chinesePurpose
    }

    public static func searchTerms(
        for resource: CapabilityResource,
        language: AppLanguage,
        catalog: [CapabilityPurposeLocalizationEntry] = entries
    ) -> [String] {
        [
            resource.name,
            resource.summary ?? "",
            localizedSummary(for: resource, language: language, catalog: catalog) ?? "",
        ]
    }
}
