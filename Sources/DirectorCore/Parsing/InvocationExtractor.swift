import Foundation

/// A tolerance issue recorded during invocation extraction.
public struct InvocationIssue: Sendable, Equatable {
    public let lineNumber: Int
    public let message: String

    public init(lineNumber: Int, message: String) {
        self.lineNumber = lineNumber
        self.message = message
    }
}

/// Normalized calls plus extraction issues for one session.
public struct InvocationExtraction: Sendable {
    public let calls: [InvocationEvent]
    public let issues: [InvocationIssue]

    public init(calls: [InvocationEvent], issues: [InvocationIssue]) {
        self.calls = calls
        self.issues = issues
    }
}

/// Reconstructs normalized `InvocationEvent`s from decoded rollout envelopes.
///
/// - Recognizes `custom_tool_call`, `custom_tool_call_output`, `function_call`,
///   and `function_call_output`, pairing calls and results by `call_id`.
/// - Recovers the nested tool name from an `exec` wrapper only when a single
///   unambiguous `tools.<name>` identifier is present in the (transient) input;
///   the input itself is never retained.
/// - Preserves order, parent/child nesting, retry, error, interruption, and
///   missing-result signals. Duplicate events do not duplicate calls.
/// - Never infers Skill use from a name in a prompt or system Skill list.
public struct InvocationExtractor: Sendable {
    private let skillResolver: SkillEvidenceResolver
    private let agentResolver: AgentEvidenceResolver

    public init(
        skillResolver: SkillEvidenceResolver = SkillEvidenceResolver(resources: []),
        agentResolver: AgentEvidenceResolver = AgentEvidenceResolver(resources: [])
    ) {
        self.skillResolver = skillResolver
        self.agentResolver = agentResolver
    }

    /// Bounded-memory streaming extractor for one session. Feed envelopes in
    /// order; each transient payload is consumed and then released.
    func makeAccumulator(sessionID: String) -> InvocationAccumulator {
        InvocationAccumulator(state: ExtractionState(sessionID: sessionID, skillResolver: skillResolver, agentResolver: agentResolver))
    }

    public func extract(sessionID: String, envelopes: [RolloutEnvelope]) -> InvocationExtraction {
        var accumulator = makeAccumulator(sessionID: sessionID)
        for envelope in envelopes { accumulator.process(envelope) }
        return accumulator.finish()
    }
}

/// Mutable, bounded-memory accumulator that processes envelopes one at a time.
struct InvocationAccumulator: Sendable {
    private var state: ExtractionState
    fileprivate init(state: ExtractionState) { self.state = state }
    mutating func process(_ envelope: RolloutEnvelope) { state.process(envelope) }
    mutating func finish() -> InvocationExtraction { state.finish() }
}

// MARK: - Extraction state

private struct ExtractionState {
    let sessionID: String
    let skillResolver: SkillEvidenceResolver
    let agentResolver: AgentEvidenceResolver

    var calls: [CallRecord] = []
    var openByCallID: [String: OpenCall] = [:]
    var callIDHistory: [String: [Int]] = [:]
    var seenItemIDs = Set<String>()
    var seenStructuredEvents = Set<String>()
    var issues: [InvocationIssue] = []
    var ordinal = 0

    mutating func process(_ envelope: RolloutEnvelope) {
        switch envelope.type {
        case .responseItem:
            guard let payload = envelope.payload else { return }
            switch payload.json["type"] as? String {
            case "custom_tool_call", "function_call":
                handleCallStart(envelope: envelope, payload: payload)
            case "custom_tool_call_output", "function_call_output":
                handleCallOutput(envelope: envelope, payload: payload)
            default:
                break // message, reasoning, web_search_call: not calls
            }
        case .eventMessage:
            guard let payload = envelope.payload else { return }
            switch payload.json["type"] as? String {
            case "exec_command_end", "patch_apply_end", "web_search_end":
                handleEndEvent(envelope: envelope, payload: payload)
            case "skill_invoked":
                handleSkillEvent(envelope: envelope, payload: payload)
            case "agent_invoked":
                handleAgentEvent(envelope: envelope, payload: payload)
            default:
                break
            }
        case .compacted:
            let record = CallRecord(
                id: "compaction-\(envelope.lineNumber)",
                sessionID: sessionID,
                parentCallID: nil,
                ordinal: ordinal,
                timestamp: envelope.timestamp,
                actorName: "system",
                resourceID: nil,
                kind: .compaction,
                status: .completed,
                durationMs: nil,
                confidence: .exact,
                errorCategory: nil,
                hasResult: true
            )
            calls.append(record)
            ordinal += 1
        default:
            break
        }
    }

    private mutating func handleCallStart(envelope: RolloutEnvelope, payload: TransientPayload) {
        let itemID = payload.json["id"] as? String
        if let itemID, !seenItemIDs.insert(itemID).inserted {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "duplicate event skipped (\(itemID))"))
            return
        }

        let callID = payload.json["call_id"] as? String
        let name = payload.json["name"] as? String ?? "unknown"
        let kind = Self.kind(for: name)
        let id = itemID ?? callID ?? "line-\(envelope.lineNumber)-\(ordinal)"

        // A new call with an already-seen call_id closes the previous attempt.
        if let callID, let previous = openByCallID[callID] {
            if !calls[previous.recordIndex].hasResult {
                issues.append(InvocationIssue(
                    lineNumber: envelope.lineNumber,
                    message: "superseded call without result (\(callID))"))
            }
            let previousStatus = calls[previous.recordIndex].status
            if previousStatus == .completed || previousStatus == .started || previousStatus == .unknown {
                calls[previous.recordIndex].status = .retried
            }
        }

        let record = CallRecord(
            id: id,
            sessionID: sessionID,
            parentCallID: nil,
            ordinal: ordinal,
            timestamp: envelope.timestamp,
            actorName: nil,
            resourceID: "\(kind.rawValue):\(name)",
            kind: kind,
            status: Self.itemStatus(payload.json["status"]),
            durationMs: nil,
            confidence: .exact,
            errorCategory: nil,
            hasResult: false
        )
        calls.append(record)
        ordinal += 1
        let index = calls.count - 1

        if let callID {
            openByCallID[callID] = OpenCall(callID: callID, recordIndex: index)
            callIDHistory[callID, default: []].append(index)
        } else {
            issues.append(InvocationIssue(
                lineNumber: envelope.lineNumber,
                message: "tool call without call_id; result pairing unavailable"))
        }

        // exec wrapper: recover the nested tool name from the transient input.
        let input = payload.json["input"] as? String
        let evidenceToolName: String?
        if name == "exec", let input {
            let nested = Self.nestedToolNames(in: input)
            if nested.count == 1 {
                evidenceToolName = nested[0]
                let childKind = Self.kind(for: nested[0])
                let child = CallRecord(
                    id: "\(id)-nested-\(nested[0])",
                    sessionID: sessionID,
                    parentCallID: id,
                    ordinal: ordinal,
                    timestamp: envelope.timestamp,
                    actorName: nil,
                    resourceID: "\(childKind.rawValue):\(nested[0])",
                    kind: childKind,
                    status: .completed,
                    durationMs: nil,
                    confidence: .exact,
                    errorCategory: nil,
                    hasResult: true
                )
                calls.append(child)
                ordinal += 1
            } else {
                evidenceToolName = nil
                issues.append(InvocationIssue(
                    lineNumber: envelope.lineNumber,
                    message: "nested tool name not recoverable (found \(nested.count))"))
            }
        } else {
            evidenceToolName = name
        }

        // Capability evidence: only a real read of a discovered manifest in a
        // tool input resolves to a child invocation. The transient input is
        // never retained.
        if let input, let evidenceToolName,
           let resolved = skillResolver.resolveManifestReadSignal(input: input, toolName: evidenceToolName) {
            let child = CallRecord(
                id: "\(id)-skill-\(resolved.resourceID ?? "unresolved")",
                sessionID: sessionID,
                parentCallID: id,
                ordinal: ordinal,
                timestamp: envelope.timestamp,
                actorName: nil,
                resourceID: resolved.resourceID,
                kind: .skill,
                status: .started,
                durationMs: nil,
                confidence: resolved.confidence,
                errorCategory: nil,
                hasResult: false
            )
            calls.append(child)
            ordinal += 1
        }
        if let input, let evidenceToolName,
           let resolved = agentResolver.resolveManifestReadSignal(input: input, toolName: evidenceToolName) {
            let child = CallRecord(
                id: "\(id)-agent-\(resolved.resourceID ?? "unresolved")",
                sessionID: sessionID,
                parentCallID: id,
                ordinal: ordinal,
                timestamp: envelope.timestamp,
                actorName: nil,
                resourceID: resolved.resourceID,
                kind: .agent,
                status: .started,
                durationMs: nil,
                confidence: resolved.confidence,
                errorCategory: nil,
                hasResult: false
            )
            calls.append(child)
            ordinal += 1
        }
    }

    private mutating func handleCallOutput(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let callID = payload.json["call_id"] as? String else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "call result without call_id"))
            return
        }
        guard let open = openByCallID[callID] else {
            issues.append(InvocationIssue(
                lineNumber: envelope.lineNumber,
                message: "call result without matching call (\(callID))"))
            return
        }
        let index = open.recordIndex
        calls[index].hasResult = true
        if calls[index].status == .unknown || calls[index].status == .started {
            calls[index].status = .completed
        }
        Self.propagateToSkillChildren(calls: &calls, parentID: calls[index].id, status: calls[index].status)
    }

    private mutating func handleEndEvent(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let callID = payload.json["call_id"] as? String else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "end event without call_id"))
            return
        }
        guard let open = openByCallID[callID] else {
            issues.append(InvocationIssue(
                lineNumber: envelope.lineNumber,
                message: "end event without matching call (\(callID))"))
            return
        }
        let index = open.recordIndex
        calls[index].hasResult = true

        var endStatus = Self.endStatus(payload.json["status"])
        if let success = payload.json["success"] as? Bool, payload.json["status"] == nil {
            endStatus = success ? .completed : .failed
        }
        if endStatus != .unknown {
            calls[index].status = endStatus
        }
        if let duration = Self.durationMs(from: payload.json["duration"]) {
            calls[index].durationMs = duration
        }
        if let exitCode = payload.json["exit_code"] as? Int, exitCode != 0 {
            calls[index].errorCategory = "exit_\(exitCode)"
        }
        Self.propagateToSkillChildren(calls: &calls, parentID: calls[index].id, status: calls[index].status)
    }

    /// Structured `skill_invoked` event: exact when it resolves to exactly
    /// one current Skill, otherwise unknown. Duplicate structured events are
    /// deduplicated without suppressing separate real invocations.
    private mutating func handleSkillEvent(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let skillName = payload.json["skill"] as? String, !skillName.isEmpty else {
            issues.append(InvocationIssue(
                lineNumber: envelope.lineNumber,
                message: "skill_invoked without a skill name"))
            return
        }
        let dedupKey = (payload.json["id"] as? String) ?? "\(skillName)-\(envelope.lineNumber)"
        guard seenStructuredEvents.insert(dedupKey).inserted else { return }

        let resolved = skillResolver.resolveStructuredEvent(skillName: skillName)
        let eventStatus = Self.itemStatus(payload.json["status"])
        let record = CallRecord(
            id: "skill-\(dedupKey)",
            sessionID: sessionID,
            parentCallID: nil,
            ordinal: ordinal,
            timestamp: envelope.timestamp,
            actorName: nil,
            resourceID: resolved.resourceID,
            kind: .skill,
            status: eventStatus == .unknown ? .completed : eventStatus,
            durationMs: nil,
            confidence: resolved.confidence,
            errorCategory: nil,
            hasResult: true
        )
        calls.append(record)
        ordinal += 1
    }

    /// Structured Agent evidence is exact only when the event identifier
    /// resolves to one discovered Agent; unresolved evidence remains visible
    /// as an unknown Agent event rather than being attributed by name alone.
    private mutating func handleAgentEvent(envelope: RolloutEnvelope, payload: TransientPayload) {
        let identifier = (payload.json["agent_id"] as? String)
            ?? (payload.json["agent"] as? String)
            ?? (payload.json["agent_name"] as? String)
        guard let identifier, !identifier.isEmpty else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "agent_invoked without an Agent identifier"))
            return
        }
        let dedupKey = (payload.json["id"] as? String) ?? "\(identifier)-\(envelope.lineNumber)"
        guard seenStructuredEvents.insert("agent-\(dedupKey)").inserted else { return }
        let resolved = agentResolver.resolveStructuredEvent(agentIdentifier: identifier)
        let eventStatus = Self.itemStatus(payload.json["status"])
        calls.append(CallRecord(
            id: "agent-\(dedupKey)",
            sessionID: sessionID,
            parentCallID: nil,
            ordinal: ordinal,
            timestamp: envelope.timestamp,
            actorName: nil,
            resourceID: resolved.resourceID,
            kind: .agent,
            status: eventStatus == .unknown ? .completed : eventStatus,
            durationMs: nil,
            confidence: resolved.confidence,
            errorCategory: nil,
            hasResult: true
        ))
        ordinal += 1
    }

    mutating func finish() -> InvocationExtraction {
        var issues = self.issues
        for (callID, open) in openByCallID where !calls[open.recordIndex].hasResult {
            issues.append(InvocationIssue(
                lineNumber: 0,
                message: "invocation has no matching result (\(callID))"))
            if calls[open.recordIndex].status == .started {
                calls[open.recordIndex].status = .unknown
            }
        }
        // Derived capability children whose parent result is missing stay
        // honestly unknown.
        for index in calls.indices where (calls[index].kind == .skill || calls[index].kind == .agent) && calls[index].status == .started {
            calls[index].status = .unknown
        }
        let events = calls.map { $0.toEvent() }
        return InvocationExtraction(calls: events, issues: issues)
    }

    /// Propagates the parent call's resolved status to derived capability children.
    private static func propagateToSkillChildren(calls: inout [CallRecord], parentID: String, status: InvocationStatus) {
        for index in calls.indices where (calls[index].kind == .skill || calls[index].kind == .agent) && calls[index].parentCallID == parentID {
            calls[index].status = status
        }
    }
}

private struct CallRecord {
    let id: String
    let sessionID: String
    let parentCallID: String?
    let ordinal: Int
    let timestamp: Date?
    let actorName: String?
    let resourceID: String?
    let kind: InvocationKind
    var status: InvocationStatus
    var durationMs: Int?
    let confidence: EvidenceConfidence
    var errorCategory: String?
    var hasResult: Bool

    func toEvent() -> InvocationEvent {
        InvocationEvent(
            id: id,
            sessionID: sessionID,
            parentCallID: parentCallID,
            ordinal: ordinal,
            timestamp: timestamp,
            actorName: actorName,
            resourceID: resourceID,
            kind: kind,
            status: status,
            durationMs: durationMs,
            confidence: confidence,
            errorCategory: errorCategory
        )
    }
}

private struct OpenCall {
    let callID: String
    let recordIndex: Int
}

// MARK: - Classification helpers

private extension ExtractionState {
    static func kind(for name: String) -> InvocationKind {
        switch name {
        case "spawn_agent", "send_input", "wait_agent", "resume_agent", "close_agent":
            return .orchestration
        default:
            return .tool
        }
    }

    static func itemStatus(_ raw: Any?) -> InvocationStatus {
        switch (raw as? String)?.lowercased() {
        case "completed", "success":
            return .completed
        case "failed", "error":
            return .failed
        case "interrupted", "canceled", "cancelled":
            return .interrupted
        case "running", "in_progress", "pending":
            return .started
        default:
            return .unknown
        }
    }

    static func endStatus(_ raw: Any?) -> InvocationStatus {
        switch (raw as? String)?.lowercased() {
        case "completed", "success":
            return .completed
        case "failed", "error":
            return .failed
        case "interrupted", "canceled", "cancelled":
            return .interrupted
        default:
            return .unknown
        }
    }

    static func durationMs(from raw: Any?) -> Int? {
        if let number = raw as? NSNumber {
            return number.intValue
        }
        guard let object = raw as? [String: Any] else { return nil }
        let secs = (object["secs"] as? NSNumber)?.int64Value ?? 0
        let nanos = (object["nanos"] as? NSNumber)?.int64Value ?? 0
        return Int(secs * 1000 + nanos / 1_000_000)
    }

    /// Bare `tools.<name>` identifiers inside an exec wrapper's JS-style input.
    /// Returns all matches so ambiguity can be detected.
    static func nestedToolNames(in input: String) -> [String] {
        var names: [String] = []
        var searchRange = input.startIndex..<input.endIndex
        while let range = input.range(of: "tools.", options: [], range: searchRange) {
            var end = range.upperBound
            while end < input.endIndex {
                let character = input[end]
                if character.isLetter || character.isNumber || character == "_" || character == "-" {
                    end = input.index(after: end)
                } else {
                    break
                }
            }
            if end > range.upperBound {
                names.append(String(input[range.upperBound..<end]))
            }
            searchRange = end..<input.endIndex
        }
        return names
    }
}
