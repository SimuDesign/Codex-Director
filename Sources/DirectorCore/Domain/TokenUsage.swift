import Foundation

/// Validated token counts for one point in time.
///
/// All counts must be non-negative; the throwing initializer and the custom
/// decoder enforce that boundary.
public struct TokenUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64
    public let coverage: CoverageState

    public init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64,
        coverage: CoverageState
    ) throws {
        let counts = [
            inputTokens, cachedInputTokens, cacheWriteInputTokens,
            outputTokens, reasoningOutputTokens, totalTokens,
        ]
        guard counts.allSatisfy({ $0 >= 0 }) else {
            throw DomainValidationError.negativeTokenCount
        }
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case cacheWriteInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
        case coverage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            inputTokens: c.decode(Int64.self, forKey: .inputTokens),
            cachedInputTokens: c.decode(Int64.self, forKey: .cachedInputTokens),
            cacheWriteInputTokens: c.decode(Int64.self, forKey: .cacheWriteInputTokens),
            outputTokens: c.decode(Int64.self, forKey: .outputTokens),
            reasoningOutputTokens: c.decode(Int64.self, forKey: .reasoningOutputTokens),
            totalTokens: c.decode(Int64.self, forKey: .totalTokens),
            coverage: c.decode(CoverageState.self, forKey: .coverage)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try c.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(coverage, forKey: .coverage)
    }
}

/// One captured token-usage record for a session.
public struct TokenUsageSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let capturedAt: Date
    public let usage: TokenUsage
    public let modelID: String?
    public let modelName: String?
    public let modelConfidence: EvidenceConfidence

    public init(
        id: String,
        sessionID: String,
        capturedAt: Date,
        usage: TokenUsage,
        modelID: String? = nil,
        modelName: String? = nil,
        modelConfidence: EvidenceConfidence = .unknown
    ) {
        self.id = id
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.usage = usage
        self.modelID = modelID
        self.modelName = modelName
        self.modelConfidence = modelConfidence
    }

    public var modelIdentity: ModelIdentity? {
        guard let modelID, !modelID.isEmpty else { return nil }
        return ModelIdentity(id: modelID, displayName: modelName ?? modelID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, capturedAt, usage, modelID, modelName, modelConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            usage: try container.decode(TokenUsage.self, forKey: .usage),
            modelID: modelID,
            modelName: try container.decodeIfPresent(String.self, forKey: .modelName),
            modelConfidence: try container.decodeIfPresent(EvidenceConfidence.self, forKey: .modelConfidence)
                ?? (modelID == nil ? .unknown : .exact)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(usage, forKey: .usage)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encode(modelConfidence, forKey: .modelConfidence)
    }
}
