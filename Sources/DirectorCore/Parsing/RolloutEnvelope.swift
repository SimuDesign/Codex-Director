import Foundation
import CoreFoundation

/// Known rollout top-level event types observed across April–August 2026
/// samples. Anything else is recorded as an `UnknownEventRecord`.
public enum RolloutEventType: String, Sendable, CaseIterable, Equatable {
    case sessionMeta = "session_meta"
    case turnContext = "turn_context"
    case worldState = "world_state"
    case responseItem = "response_item"
    case eventMessage = "event_msg"
    case tokenUsageRecord = "token_usage_record"
    case interAgentCommunicationMetadata = "inter_agent_communication_metadata"
    case compacted
}

/// Transient decoded payload of a known envelope.
///
/// Exists only inside the parsing pipeline for extractors to read allowlisted
/// fields from. It is never persisted, logged, or encoded into database
/// records.
public struct TransientPayload: @unchecked Sendable {
    public let json: [String: Any]

    public init(json: [String: Any]) {
        self.json = json
    }
}

/// A normalized rollout envelope for a known event type.
public struct RolloutEnvelope: Sendable {
    public let type: RolloutEventType
    public let timestamp: Date?
    public let lineNumber: Int
    public let byteOffset: UInt64
    public let payload: TransientPayload?
    /// Original history ordinal, transiently used to exclude inherited history.
    public let sourceOrdinal: Int?

    /// JSON booleans must not bridge to 0/1 history positions.
    static func validatedOrdinal(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let ordinal = value as? Int, ordinal >= 0,
              number.doubleValue == Double(ordinal) else { return nil }
        return ordinal
    }

    public init(
        type: RolloutEventType,
        timestamp: Date?,
        lineNumber: Int,
        byteOffset: UInt64,
        payload: TransientPayload?,
        sourceOrdinal: Int? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
        self.payload = payload
        self.sourceOrdinal = sourceOrdinal
    }
}

/// A record for an unknown top-level event type: type name and metadata only.
/// The raw payload is never retained.
public struct UnknownEventRecord: Sendable {
    public let typeName: String
    public let timestamp: Date?
    public let lineNumber: Int
    public let byteOffset: UInt64

    public init(typeName: String, timestamp: Date?, lineNumber: Int, byteOffset: UInt64) {
        self.typeName = typeName
        self.timestamp = timestamp
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
    }
}

/// What one decoded line produced.
public enum DecodedLine: Sendable {
    case envelope(RolloutEnvelope)
    case unknownEvent(UnknownEventRecord)
}
