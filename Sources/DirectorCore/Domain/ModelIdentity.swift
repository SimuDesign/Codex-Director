import Foundation

/// Privacy-safe canonical identity for the model recorded by a rollout.
///
/// Only a trimmed, normalized identifier is retained. Known Codex 5.3 Spark
/// aliases intentionally converge on one stable ID so the Usage breakdown
/// cannot split one model across several display rows.
public struct ModelIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let codex53SparkID = "codex-5.3-spark"
    public static let codex53SparkDisplayName = "Codex 5.3 Spark"
    public static let redactedID = "redacted-model"
    public static let redactedDisplayName = "Redacted model"

    /// Normalizes a model string from an allowlisted rollout field.
    ///
    /// Empty values are treated as missing evidence. URLs and absolute paths
    /// are represented by a redacted placeholder so they are not persisted as
    /// raw source data while still remaining visible as non-exact evidence.
    public static func normalized(raw: String?) -> ModelIdentity? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") || trimmed.hasPrefix("/") || trimmed.contains("\\") {
            return ModelIdentity(id: redactedID, displayName: redactedDisplayName)
        }

        let sanitized = trimmed
            .lowercased()
            .replacingOccurrences(of: "[_\\s]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9._-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        guard !sanitized.isEmpty else {
            return ModelIdentity(id: redactedID, displayName: redactedDisplayName)
        }

        let bounded = String(sanitized.prefix(96))
        let aliasKey = bounded.replacingOccurrences(of: ".", with: "-")
        let sparkAliases: Set<String> = [
            "codex-5-3-spark",
            "codex-53-spark",
            "gpt-5-3-codex-spark",
            "gpt-53-codex-spark",
            "codex-5-3-codex-spark",
        ]
        if sparkAliases.contains(aliasKey) {
            return ModelIdentity(id: codex53SparkID, displayName: codex53SparkDisplayName)
        }

        return ModelIdentity(id: bounded, displayName: bounded)
    }
}
