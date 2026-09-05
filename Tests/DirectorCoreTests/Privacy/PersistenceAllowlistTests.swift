import XCTest
@testable import DirectorCore

final class PersistenceAllowlistTests: XCTestCase {

    func testNormalizedResourceDictionaryPasses() {
        let dict: [String: Any] = [
            "id": "skill:example", "name": "example", "kind": "skill",
            "availability": "unknown", "scope": "global", "project_id": NSNull(),
            "confidence": "exact", "description": "Synthetic example",
            "source_root_id": "global-skills",
            "relative_source_path": "example/SKILL.md",
            "source_path_hash": "abc", "last_seen_at": 1700000000.0,
        ]
        XCTAssertTrue(PersistenceAllowlist.validate(dict, allowedKeys: PersistenceAllowlist.resourceKeys))
    }

    func testSourceModificationDateIsAllowlistedResourceMetadata() {
        XCTAssertTrue(PersistenceAllowlist.resourceKeys.contains("source_modified_at"))
        XCTAssertFalse(PersistenceAllowlist.resourceKeys.contains("source_body"))
    }

    func testRawEventDictionaryCannotBeEncodedAsRecord() {
        // A raw token_count payload dict contains non-allowlisted keys.
        let raw: [String: Any] = [
            "type": "token_count",
            "info": ["last_token_usage": ["total_tokens": 42]],
            "rate_limits": ["primary": ["used_percent": 50.0]],
        ]
        XCTAssertFalse(PersistenceAllowlist.validate(raw, allowedKeys: PersistenceAllowlist.resourceKeys))
        XCTAssertFalse(PersistenceAllowlist.validate(raw, allowedKeys: PersistenceAllowlist.tokenKeys))
    }

    func testPromptAndArgumentsKeysAreRejected() {
        let unsafe: [String: Any] = [
            "id": "x", "name": "x", "prompt": "please do the thing",
            "arguments": "{\"command\":\"ls\"}", "output": "sensitive",
        ]
        XCTAssertFalse(PersistenceAllowlist.validate(unsafe, allowedKeys: PersistenceAllowlist.resourceKeys))
        XCTAssertFalse(PersistenceAllowlist.validate(unsafe, allowedKeys: PersistenceAllowlist.callKeys))
    }

    func testCredentialValuesNeverAppearInPersistedValues() {
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("sk-" + "proj-abc123def456ghi789"))
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("api_key=live_abcd1234"))
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("Authorization: " + "Bearer " + "eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("ghp_" + "1234567890abcdefghij"))
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("xoxb-1234567890-abcdefghij"))
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("-----BEGIN " + "RSA PRIVATE KEY-----"))
        // Legitimate metadata such as "token totals" must pass.
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("Aggregate token totals"))
    }

    func testSecurityProseIsNotCredentialEvidence() {
        // Regression: real discovered skill names/descriptions legitimately
        // mention security concepts; bare-word substring matching rejected
        // them and failed the entire indexing pass.
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("1password"))
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("1password/SKILL.md"))
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("Detects prompt injection, credential exfiltration, and path traversal"))
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("Checks for sk- prefixed API keys in prompts"))
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("Vets skills for suspicious patterns and permission scope"))
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("Reviewing code for password hashing and authorization flows"))
    }

    func testForbiddenValueRejectsWholeRecord() {
        let dict: [String: Any] = [
            "id": "x", "name": "x", "kind": "tool", "availability": "unknown",
            "scope": "runtime", "confidence": "exact", "description": "uses sk-" + "proj-abc123def456ghi789",
            "source_root_id": "r", "relative_source_path": "p",
            "source_path_hash": "h", "last_seen_at": 0.0,
        ]
        XCTAssertFalse(PersistenceAllowlist.validate(dict, allowedKeys: PersistenceAllowlist.resourceKeys))
    }

    func testSyntheticFixturePasses() {
        // A synthetic, normalized resource record (never derived from real data).
        let dict: [String: Any] = [
            "id": "skill:video-cover-studio", "name": "video-cover-studio",
            "kind": "skill", "availability": "success", "scope": "global",
            "project_id": NSNull(), "confidence": "exact",
            "description": "Designs cover frames for video deliverables.",
            "source_root_id": "global-skills",
            "relative_source_path": "video-cover-studio/SKILL.md",
            "source_path_hash": "e3b0c442", "last_seen_at": 1700000000.0,
        ]
        XCTAssertTrue(PersistenceAllowlist.validate(dict, allowedKeys: PersistenceAllowlist.resourceKeys))
    }

    func testDeliberatelyUnsafeFixtureFails() {
        let unsafe: [String: Any] = [
            "id": "x", "name": "x", "kind": "skill", "availability": "unknown",
            "scope": "global", "confidence": "exact",
            "description": "Copy of prompt: create an image of a cat",
            "source_root_id": "r", "relative_source_path": "p",
            "source_path_hash": "h", "last_seen_at": 0.0,
            "prompt": "create an image of a cat",
        ]
        XCTAssertFalse(PersistenceAllowlist.validate(unsafe, allowedKeys: PersistenceAllowlist.resourceKeys))
    }

    func testUnredactedHomePathRejected() {
        XCTAssertTrue(PersistenceAllowlist.containsForbiddenValue("/Users/exampleuser/private/SKILL.md"))
        XCTAssertTrue(PersistenceAllowlist.containsUnredactedHomePath("/Users/exampleuser/private"))
        // Redacted and unrelated values pass.
        XCTAssertFalse(PersistenceAllowlist.containsForbiddenValue("~/private/SKILL.md"))
        XCTAssertFalse(PersistenceAllowlist.containsUnredactedHomePath("/Applications/Xcode.app"))
        XCTAssertFalse(PersistenceAllowlist.containsUnredactedHomePath("/Users/"))
    }

    func testRelationAndCheckpointAllowlistsExist() {
        XCTAssertTrue(PersistenceAllowlist.relationKeys.contains("evidence_summary"))
        XCTAssertTrue(PersistenceAllowlist.relationKeys.contains("source_resource_id"))
        XCTAssertTrue(PersistenceAllowlist.checkpointKeys.contains("parser_version"))
        XCTAssertTrue(PersistenceAllowlist.checkpointKeys.contains("source_file_id"))
    }
}
