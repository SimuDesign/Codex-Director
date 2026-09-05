import Foundation

/// Parsed token and quota evidence for one session.
public struct TokenUsageExtraction: Sendable {
    public let snapshots: [TokenUsageSnapshot]
    public let quotas: [QuotaSnapshot]
    public let issues: [TokenUsageIssue]

    public init(snapshots: [TokenUsageSnapshot], quotas: [QuotaSnapshot], issues: [TokenUsageIssue]) {
        self.snapshots = snapshots
        self.quotas = quotas
        self.issues = issues
    }
}

/// A tolerance issue while parsing token or quota evidence.
public struct TokenUsageIssue: Sendable, Equatable {
    public let lineNumber: Int
    public let message: String

    public init(lineNumber: Int, message: String) {
        self.lineNumber = lineNumber
        self.message = message
    }
}

/// Parses `token_count` event evidence into cumulative token snapshots and
/// reported rate-limit windows.
///
/// - A task total is the newest cumulative `total_token_usage` snapshot; the
///   parser never sums cumulative snapshots.
/// - `last_token_usage` is a per-event view and is not recorded as a task
///   snapshot.
/// - Primary and secondary rate-limit windows are parsed symmetrically and
///   classified by minutes (10_080 = weekly, 300 = short), never by position.
/// - A decreasing or malformed cumulative total marks partial coverage.
/// - Official allowance is never derived from local token totals.
public struct TokenUsageParser: Sendable {
    public static let weeklyWindowMinutes = 10_080
    public static let shortWindowMinutes = 300

    public init() {}

    /// Bounded-memory streaming parser for one session.
    func makeAccumulator(sessionID: String, resumeFrom snapshot: TokenUsageSnapshot? = nil) -> TokenUsageAccumulator {
        TokenUsageAccumulator(state: TokenState(
            sessionID: sessionID,
            lastCumulativeTotal: snapshot?.usage.totalTokens,
            activeModel: snapshot?.modelIdentity
        ))
    }

    public func extract(sessionID: String, envelopes: [RolloutEnvelope]) -> TokenUsageExtraction {
        var accumulator = makeAccumulator(sessionID: sessionID)
        for envelope in envelopes { accumulator.process(envelope) }
        return accumulator.finish()
    }

    /// The newest cumulative snapshot for a task total — never a sum.
    public static func newestCumulative(from snapshots: [TokenUsageSnapshot]) -> TokenUsageSnapshot? {
        snapshots.max { $0.capturedAt < $1.capturedAt }
    }
}

/// Mutable, bounded-memory accumulator for `token_count` evidence.
struct TokenUsageAccumulator: Sendable {
    private var state: TokenState
    fileprivate init(state: TokenState) { self.state = state }
    mutating func process(_ envelope: RolloutEnvelope) {
        state.processModelContext(envelope)
        guard envelope.type == .eventMessage, let payload = envelope.payload else { return }
        guard (payload.json["type"] as? String) == "token_count" else { return }
        state.process(envelope: envelope, payload: payload)
    }
    mutating func finish() -> TokenUsageExtraction { state.finish() }
}

// MARK: - State

private struct TokenState {
    let sessionID: String
    var snapshots: [TokenUsageSnapshot] = []
    var quotas: [QuotaSnapshot] = []
    var issues: [TokenUsageIssue] = []
    var lastCumulativeTotal: Int64?
    var activeModel: ModelIdentity?

    mutating func processModelContext(_ envelope: RolloutEnvelope) {
        guard envelope.type == .turnContext, let payload = envelope.payload else { return }
        guard let rawModel = payload.json["model"] else { return }
        guard let rawModel = rawModel as? String else {
            issues.append(TokenUsageIssue(lineNumber: envelope.lineNumber, message: "malformed turn_context model"))
            activeModel = nil
            return
        }
        activeModel = ModelIdentity.normalized(raw: rawModel)
        if activeModel == nil {
            issues.append(TokenUsageIssue(lineNumber: envelope.lineNumber, message: "empty turn_context model"))
        }
    }

    mutating func process(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let capturedAt = envelope.timestamp else {
            issues.append(TokenUsageIssue(lineNumber: envelope.lineNumber, message: "token_count event without timestamp"))
            return
        }
        if let info = payload.json["info"] as? [String: Any] {
            parseTokenUsage(envelope: envelope, capturedAt: capturedAt, info: info)
        }
        if let rateLimits = payload.json["rate_limits"] as? [String: Any] {
            parseRateLimits(envelope: envelope, capturedAt: capturedAt, rateLimits: rateLimits)
        }
    }

    mutating func parseTokenUsage(envelope: RolloutEnvelope, capturedAt: Date, info: [String: Any]) {
        guard let total = info["total_token_usage"] as? [String: Any],
              let parsed = TokenUsageParser.parseUsage(total) else {
            issues.append(TokenUsageIssue(lineNumber: envelope.lineNumber, message: "malformed total_token_usage"))
            return
        }
        var coverage: CoverageState = .complete
        if let last = lastCumulativeTotal, parsed.totalTokens < last {
            coverage = .partial
            issues.append(TokenUsageIssue(
                lineNumber: envelope.lineNumber,
                message: "decreasing cumulative total marks partial coverage"))
        }
        lastCumulativeTotal = parsed.totalTokens

        let usage: TokenUsage
        do {
            usage = try TokenUsage(
                inputTokens: parsed.inputTokens,
                cachedInputTokens: parsed.cachedInputTokens,
                cacheWriteInputTokens: parsed.cacheWriteInputTokens,
                outputTokens: parsed.outputTokens,
                reasoningOutputTokens: parsed.reasoningOutputTokens,
                totalTokens: parsed.totalTokens,
                coverage: coverage
            )
        } catch {
            issues.append(TokenUsageIssue(lineNumber: envelope.lineNumber, message: "invalid token counts"))
            return
        }
        let id = "\(sessionID)-t\(Int64(capturedAt.timeIntervalSince1970))"
        snapshots.append(TokenUsageSnapshot(
            id: id,
            sessionID: sessionID,
            capturedAt: capturedAt,
            usage: usage,
            modelID: activeModel?.id,
            modelName: activeModel?.displayName,
            modelConfidence: activeModel == nil || activeModel?.id == ModelIdentity.redactedID
                ? .unknown
                : .exact
        ))
    }

    mutating func parseRateLimits(envelope: RolloutEnvelope, capturedAt: Date, rateLimits: [String: Any]) {
        let limitID = rateLimits["limit_id"] as? String
        let limitName = rateLimits["limit_name"] as? String
        parseWindow(
            envelope: envelope, capturedAt: capturedAt, window: rateLimits["primary"],
            position: "primary", limitID: limitID, limitName: limitName)
        parseWindow(
            envelope: envelope, capturedAt: capturedAt, window: rateLimits["secondary"],
            position: "secondary", limitID: limitID, limitName: limitName)
    }

    mutating func parseWindow(
        envelope: RolloutEnvelope,
        capturedAt: Date,
        window: Any?,
        position: String,
        limitID: String?,
        limitName: String?
    ) {
        guard let dictionary = window as? [String: Any] else { return } // absent or null window
        guard let windowMinutes = (dictionary["window_minutes"] as? NSNumber)?.intValue,
              let usedPercent = (dictionary["used_percent"] as? NSNumber)?.doubleValue else {
            issues.append(TokenUsageIssue(
                lineNumber: envelope.lineNumber,
                message: "malformed \(position) rate-limit window"))
            return
        }
        let resetsAt: Date? = (dictionary["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let microseconds = Int64(capturedAt.timeIntervalSince1970 * 1_000_000)
        let id = "quota-\(microseconds)-\(windowMinutes)-\(limitID ?? "nil")-\(position)-line-\(envelope.lineNumber)"
        do {
            quotas.append(try QuotaSnapshot(
                id: id,
                capturedAt: capturedAt,
                windowMinutes: windowMinutes,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                limitID: limitID,
                limitName: limitName,
                confidence: .exact
            ))
        } catch {
            issues.append(TokenUsageIssue(
                lineNumber: envelope.lineNumber,
                message: "invalid \(position) rate-limit window"))
        }
    }

    func finish() -> TokenUsageExtraction {
        TokenUsageExtraction(snapshots: snapshots, quotas: quotas, issues: issues)
    }
}

// MARK: - Helpers

public extension TokenUsageParser {
    static func parseUsage(_ dictionary: [String: Any]) -> (inputTokens: Int64, cachedInputTokens: Int64, cacheWriteInputTokens: Int64, outputTokens: Int64, reasoningOutputTokens: Int64, totalTokens: Int64)? {
        guard let input = int64(dictionary["input_tokens"]),
              let cached = int64(dictionary["cached_input_tokens"]),
              let cacheWrite = int64(dictionary["cache_write_input_tokens"]),
              let output = int64(dictionary["output_tokens"]),
              let reasoning = int64(dictionary["reasoning_output_tokens"]),
              let total = int64(dictionary["total_tokens"]) else {
            return nil
        }
        return (input, cached, cacheWrite, output, reasoning, total)
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
