import Foundation

/// Result of decoding one line: an optional decoded line plus tolerance
/// issues. Malformed or unstructurable lines are skipped, never fatal.
public struct RolloutDecodingResult: Sendable {
    public let line: DecodedLine?
    public let issues: [RolloutDecodingIssue]

    public init(line: DecodedLine?, issues: [RolloutDecodingIssue]) {
        self.line = line
        self.issues = issues
    }
}

/// A tolerance issue while decoding; parsing continues afterwards.
public struct RolloutDecodingIssue: Sendable, Equatable {
    public let lineNumber: Int
    public let byteOffset: UInt64
    public let category: Category

    public enum Category: String, Sendable, Equatable {
        case malformedJSON
        case notAnObject
        case missingType
        case missingPayload
        case invalidTimestamp
    }

    public init(lineNumber: Int, byteOffset: UInt64, category: Category) {
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
        self.category = category
    }
}

/// Tolerant decoder for rollout top-level envelopes.
///
/// Known event types become `RolloutEnvelope`s (payload retained transiently
/// for extractors). Unknown types become `UnknownEventRecord`s without raw
/// payload. Malformed lines produce issues and are skipped.
public struct RolloutEventDecoder: Sendable {
    /// Parser version recorded with every indexed session.
    public static let parserVersion = "1.2.0"

    /// Top-level event types this parser version understands.
    public static let supportedEventTypes: [String] = [
        RolloutEventType.sessionMeta.rawValue,
        RolloutEventType.turnContext.rawValue,
        RolloutEventType.worldState.rawValue,
        RolloutEventType.responseItem.rawValue,
        RolloutEventType.eventMessage.rawValue,
        RolloutEventType.compacted.rawValue,
    ]

    public init() {}

    public func decode(_ line: JSONLLine) -> RolloutDecodingResult {
        guard let data = line.text.data(using: .utf8) else {
            return issue(line: line, category: .malformedJSON)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return issue(line: line, category: .malformedJSON)
        }
        guard let dictionary = json as? [String: Any] else {
            return issue(line: line, category: .notAnObject)
        }

        var issues: [RolloutDecodingIssue] = []

        guard let typeName = dictionary["type"] as? String else {
            issues.append(RolloutDecodingIssue(
                lineNumber: line.lineNumber, byteOffset: line.byteOffset, category: .missingType))
            return RolloutDecodingResult(line: nil, issues: issues)
        }

        let timestamp = Self.parseTimestamp(dictionary["timestamp"])
        if dictionary["timestamp"] != nil, timestamp == nil {
            issues.append(RolloutDecodingIssue(
                lineNumber: line.lineNumber, byteOffset: line.byteOffset, category: .invalidTimestamp))
        }

        guard let known = RolloutEventType(rawValue: typeName) else {
            return RolloutDecodingResult(
                line: .unknownEvent(UnknownEventRecord(
                    typeName: typeName,
                    timestamp: timestamp,
                    lineNumber: line.lineNumber,
                    byteOffset: line.byteOffset
                )),
                issues: issues
            )
        }

        let payload: TransientPayload?
        if let payloadJSON = dictionary["payload"] as? [String: Any] {
            payload = TransientPayload(json: payloadJSON)
        } else {
            payload = nil
            issues.append(RolloutDecodingIssue(
                lineNumber: line.lineNumber, byteOffset: line.byteOffset, category: .missingPayload))
        }

        return RolloutDecodingResult(
            line: .envelope(RolloutEnvelope(
                type: known,
                timestamp: timestamp,
                lineNumber: line.lineNumber,
                byteOffset: line.byteOffset,
                payload: payload
            )),
            issues: issues
        )
    }

    private func issue(line: JSONLLine, category: RolloutDecodingIssue.Category) -> RolloutDecodingResult {
        RolloutDecodingResult(line: nil, issues: [
            RolloutDecodingIssue(lineNumber: line.lineNumber, byteOffset: line.byteOffset, category: category)
        ])
    }

    /// Rollout timestamps are ISO-8601 with milliseconds and `Z`
    /// (e.g. `2026-08-15T04:11:50.973Z`); numeric epoch seconds are also
    /// tolerated.
    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        if let seconds = Double(string) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
