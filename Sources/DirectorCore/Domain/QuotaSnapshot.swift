import Foundation

/// A reported account rate-limit/allowance window snapshot.
///
/// Semantics:
/// - Weekly means `windowMinutes == 10_080`; the short window is 300 when present.
/// - Do not assume whether the weekly window is primary or secondary.
/// - `remainingPercent` is a deterministic display derived from a reported
///   `usedPercent`; local task token totals must never be subtracted from it.
/// - If `resetsAt` has passed and no newer snapshot exists, presentation must
///   show Unknown rather than assuming 100%.
public struct QuotaSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let capturedAt: Date
    public let windowMinutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?
    public let limitID: String?
    public let limitName: String?
    public let confidence: EvidenceConfidence

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    public var isWeeklyWindow: Bool {
        windowMinutes == 10_080
    }

    public var isShortWindow: Bool {
        windowMinutes == 300
    }

    /// True when the reported reset time has passed.
    public func isExpired(at date: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt < date
    }

    public init(
        id: String,
        capturedAt: Date,
        windowMinutes: Int,
        usedPercent: Double,
        resetsAt: Date?,
        limitID: String?,
        limitName: String?,
        confidence: EvidenceConfidence
    ) throws {
        guard usedPercent.isFinite else {
            throw DomainValidationError.nonFinitePercentage
        }
        guard windowMinutes > 0 else {
            throw DomainValidationError.invalidWindowMinutes
        }
        self.id = id
        self.capturedAt = capturedAt
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.limitID = limitID
        self.limitName = limitName
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case capturedAt
        case windowMinutes
        case usedPercent
        case resetsAt
        case limitID
        case limitName
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            capturedAt: c.decode(Date.self, forKey: .capturedAt),
            windowMinutes: c.decode(Int.self, forKey: .windowMinutes),
            usedPercent: c.decode(Double.self, forKey: .usedPercent),
            resetsAt: c.decodeIfPresent(Date.self, forKey: .resetsAt),
            limitID: c.decodeIfPresent(String.self, forKey: .limitID),
            limitName: c.decodeIfPresent(String.self, forKey: .limitName),
            confidence: c.decode(EvidenceConfidence.self, forKey: .confidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(windowMinutes, forKey: .windowMinutes)
        try c.encode(usedPercent, forKey: .usedPercent)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encodeIfPresent(limitID, forKey: .limitID)
        try c.encodeIfPresent(limitName, forKey: .limitName)
        try c.encode(confidence, forKey: .confidence)
    }
}
