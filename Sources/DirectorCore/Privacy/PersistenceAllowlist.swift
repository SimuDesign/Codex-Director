import Foundation

/// Explicit persistence allowlist.
///
/// Only allowlisted fields may cross the persistence boundary. Raw event
/// dictionaries, conversation text, tool arguments/outputs, commands, and
/// credential-bearing values are rejected here and must never reach the
/// database, logs, or exports.
public enum PersistenceAllowlist {

    /// Keys allowed in persisted resource records (SQLite column names).
    public static let resourceKeys: Set<String> = [
        "id", "name", "kind", "availability", "scope", "project_id",
        "confidence", "description", "source_root_id", "relative_source_path",
        "source_path_hash", "last_seen_at", "ownership", "origin",
        "classification_confidence", "origin_identifier", "source_version", "content_fingerprint", "source_modified_at", "modified",
    ]

    public static let projectKeys: Set<String> = ["id", "name", "available", "last_seen_at"]

    public static let provenanceKeys: Set<String> = [
        "id", "resource_id", "source_type", "source_identifier", "version",
        "installed_at", "updated_at", "confidence", "modified",
    ]

    public static let discoverySourceKeys: Set<String> = [
        "id", "source_kind", "availability", "last_seen_at", "issue_summary",
    ]

    /// Keys allowed in persisted session records.
    public static let sessionKeys: Set<String> = [
        "id", "project_id", "started_at", "ended_at", "status", "coverage",
        "parser_version", "source_file_id",
    ]

    /// Keys allowed in persisted call records.
    public static let callKeys: Set<String> = [
        "id", "session_id", "parent_call_id", "ordinal", "timestamp",
        "actor_name", "resource_id", "call_kind", "status", "duration_ms",
        "confidence", "error_category",
    ]

    /// Keys allowed in persisted token snapshots.
    public static let tokenKeys: Set<String> = [
        "id", "session_id", "captured_at", "input_tokens", "cached_input_tokens",
        "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens",
        "total_tokens", "coverage", "model_id", "model_name", "model_confidence",
    ]

    /// Keys allowed in persisted quota snapshots.
    public static let quotaKeys: Set<String> = [
        "id", "captured_at", "window_minutes", "used_percent", "resets_at",
        "limit_id", "limit_name", "confidence",
    ]

    /// Keys allowed in persisted relation records.
    public static let relationKeys: Set<String> = [
        "id", "source_resource_id", "target_resource_id", "relation_kind",
        "confidence", "evidence_summary",
    ]

    /// Keys allowed in persisted checkpoint records.
    public static let checkpointKeys: Set<String> = [
        "source_file_id", "source_size", "source_mtime", "byte_offset",
        "parser_version", "indexed_at",
    ]

    /// Keys allowed in persisted review findings.
    public static let findingKeys: Set<String> = [
        "id", "rule_id", "resource_id", "session_id", "severity", "confidence",
        "summary", "evidence_summary", "coverage", "created_at",
        "remediation_status",
    ]

    /// Credential-value patterns that must never appear in persisted string
    /// values. Unlike bare-word substring checks, these only match actual
    /// credential material — API keys, tokens, PEM blocks, and key=value
    /// assignments — so legitimate prose that merely mentions security
    /// concepts ("credential exfiltration", "1password", "checks for sk- keys")
    /// is not rejected. The SQLite boundary still fails closed on any match.
    /// Deliberately does not include the bare word "token", which appears in
    /// legitimate metadata such as "token totals".
    public static let forbiddenValuePatterns: [String] = [
        // OpenAI-style keys: sk- followed by 8+ base62-ish characters.
        #"(?i)\bsk-[A-Za-z0-9_-]{8,}"#,
        // GitHub personal access tokens.
        #"ghp_[A-Za-z0-9]{8,}"#,
        // Slack tokens.
        #"xox[baprs]-[0-9A-Za-z-]{8,}"#,
        // PEM-encoded private key / certificate blocks.
        #"-----BEGIN [A-Z0-9 ]+-----"#,
        // Authorization header values.
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        // key=value / key: value credential assignments.
        #"(?i)\b(api[_-]?key|apikey|password|passwd|secret|token|cookie|credential|authorization)\s*[=:]\s*[A-Za-z0-9._~+/=-]{8,}"#,
    ]

    /// True when the value still contains an unredacted macOS home path such
    /// as `/Users/<name>/...`. The SQLite boundary fails closed on these.
    public static func containsUnredactedHomePath(_ value: String) -> Bool {
        value.range(of: #"/Users/[^/[:space:]]+"#, options: .regularExpression) != nil
    }

    /// True when the value must never be persisted.
    public static func containsForbiddenValue(_ value: String) -> Bool {
        containsUnredactedHomePath(value) || forbiddenValuePatterns.contains {
            value.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// True when every key is allowlisted and no string value carries a
    /// forbidden credential-like or unredacted-home-path substring.
    public static func validate(
        _ dictionary: [String: Any],
        allowedKeys: Set<String>
    ) -> Bool {
        guard Set(dictionary.keys).isSubset(of: allowedKeys) else { return false }
        for value in dictionary.values {
            if let string = value as? String, containsForbiddenValue(string) {
                return false
            }
        }
        return true
    }
}
