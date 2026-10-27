import Foundation
import CoreFoundation

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
/// - Resolves literal, unconditional tool operations from bounded `exec`
///   wrappers without executing or retaining their transient input.
/// - Records child delegation once and excludes explicitly inherited history.
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
    func makeAccumulator(
        sessionID: String,
        projectID: String? = nil,
        workingDirectory: String? = nil,
        existingCalls: [InvocationEvent] = []
    ) -> InvocationAccumulator {
        InvocationAccumulator(state: ExtractionState(
            sessionID: sessionID,
            skillResolver: skillResolver,
            agentResolver: agentResolver,
            projectID: projectID,
            workingDirectory: workingDirectory,
            existingCalls: existingCalls
        ))
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
    var unresolvedResultIdentifiers: Set<String> { state.unresolvedResultIdentifiers }
    mutating func resolvePendingResults(aliases: [String: String]) { state.resolvePendingResults(aliases: aliases) }
    mutating func finish() -> InvocationExtraction { state.finish() }
}

// MARK: - Extraction state

private struct ExtractionState {
    let sessionID: String
    let skillResolver: SkillEvidenceResolver
    let agentResolver: AgentEvidenceResolver
    var projectID: String?
    var workingDirectory: String?
    var historyBoundary: Int?
    var hasUnknownForkBoundary = false
    var processedMetadata = false
    var warnedHistory = false

    var calls: [CallRecord] = []
    let priorCallsByID: [String: InvocationEvent]
    let priorChildIDsByParentID: [String: [String]]
    var recordIndexByID: [String: Int] = [:]
    var recordIDByIdentifier: [String: String] = [:]
    var openByCallID: [String: OpenCall] = [:]
    var callIDHistory: [String: [Int]] = [:]
    var seenItemIDs = Set<String>()
    var seenStructuredEvents = Set<String>()
    var pendingResults: [String: PendingResult] = [:]
    var issues: [InvocationIssue] = []
    var ordinal = 0

    private static let maximumPendingResults = 1_024

    init(
        sessionID: String,
        skillResolver: SkillEvidenceResolver,
        agentResolver: AgentEvidenceResolver,
        projectID: String?,
        workingDirectory: String?,
        existingCalls: [InvocationEvent]
    ) {
        self.sessionID = sessionID
        self.skillResolver = skillResolver
        self.agentResolver = agentResolver
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.priorCallsByID = Dictionary(uniqueKeysWithValues: existingCalls.map { ($0.id, $0) })
        self.priorChildIDsByParentID = Dictionary(
            grouping: existingCalls.compactMap { call in
                call.parentCallID.map { ($0, call.id) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }
        self.ordinal = (existingCalls.map(\.ordinal).max() ?? -1) + 1
    }

    mutating func process(_ envelope: RolloutEnvelope) {
        if envelope.type == .sessionMeta {
            handleSessionMetadata(envelope)
            return
        }
        if hasUnknownForkBoundary || (historyBoundary != nil && envelope.sourceOrdinal == nil) {
            if !warnedHistory {
                issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "inherited history boundary unavailable; calls not attributed"))
                warnedHistory = true
            }
            return
        }
        if let boundary = historyBoundary, let sourceOrdinal = envelope.sourceOrdinal, sourceOrdinal < boundary { return }
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
            case "item_completed":
                handleItemCompletion(envelope: envelope, payload: payload)
            case "skill_invoked":
                handleSkillEvent(envelope: envelope, payload: payload)
            case "agent_invoked":
                handleAgentEvent(envelope: envelope, payload: payload)
            case "task_complete":
                handleTaskComplete(envelope: envelope)
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

    private mutating func handleSessionMetadata(_ envelope: RolloutEnvelope) {
        guard !processedMetadata, let payload = envelope.payload?.json else { return }
        processedMetadata = true
        workingDirectory = (payload["cwd"] as? String) ?? (payload["working_directory"] as? String) ?? (payload["workdir"] as? String) ?? workingDirectory
        projectID = projectID ?? agentResolver.projectID(workingDirectory: workingDirectory)
        historyBoundary = RolloutEnvelope.validatedOrdinal(payload["subagent_history_start_ordinal"])
        hasUnknownForkBoundary = payload["forked_from_id"] != nil && historyBoundary == nil
        let source = payload["source"] as? [String: Any]
        guard payload["parent_thread_id"] is String || source?["subagent"] != nil,
              let role = payload["agent_role"] as? String, !role.isEmpty,
              !["default", "worker", "explorer"].contains(role.lowercased()) else { return }
        let delegationID = "delegation-\(sessionID)"
        if priorCallsByID[delegationID] != nil {
            // Appended segments recover the header for scope only. The already
            // persisted delegation remains authoritative until a real terminal
            // event changes it.
            return
        }
        let resolved = agentResolver.resolveStructuredEvent(agentIdentifier: role, projectID: projectID)
        if resolved.resourceID == nil {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "child Agent identity unresolved"))
        }
        calls.append(CallRecord(id: delegationID, sessionID: sessionID, parentCallID: nil,
            ordinal: ordinal, timestamp: envelope.timestamp, actorName: nil, resourceID: resolved.resourceID,
            kind: .agent, status: .started, durationMs: nil,
            confidence: resolved.resourceID == nil ? .unknown : .inferred,
            errorCategory: nil, hasResult: true, evidenceKind: .agentDelegation))
        recordIndexByID[delegationID] = calls.count - 1
        ordinal += 1
    }

    private mutating func handleTaskComplete(envelope: RolloutEnvelope) {
        let result = PendingResult(
            status: .completed,
            durationMs: nil,
            errorCategory: nil,
            lineNumber: envelope.lineNumber,
            source: .legacyTerminal
        )
        let currentIDs = calls.filter { $0.evidenceKind == .agentDelegation }.map(\.id)
        let priorIDs = priorCallsByID.values.filter { $0.evidenceKind == .agentDelegation }.map(\.id)
        for id in Set(currentIDs + priorIDs) {
            apply(result, to: id)
        }
    }

    private mutating func handleCallStart(envelope: RolloutEnvelope, payload: TransientPayload) {
        let itemID = payload.json["id"] as? String
        if let itemID, !seenItemIDs.insert(itemID).inserted {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "duplicate event skipped (\(itemID))"))
            return
        }

        let callID = payload.json["call_id"] as? String
        let name = TransientToolInput.normalizedName(payload.json["name"] as? String ?? "unknown")
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
        recordIndexByID[id] = index

        if let validatedItemID = InvocationIdentifier.validated(itemID) {
            recordIDByIdentifier[validatedItemID] = id
        }

        if let callID {
            openByCallID[callID] = OpenCall(callID: callID, recordIndex: index)
            callIDHistory[callID, default: []].append(index)
            if let validatedCallID = InvocationIdentifier.validated(callID) {
                recordIDByIdentifier[validatedCallID] = id
            }
        } else {
            issues.append(InvocationIssue(
                lineNumber: envelope.lineNumber,
                message: "tool call without call_id; result pairing unavailable"))
        }

        defer {
            if let validatedCallID = InvocationIdentifier.validated(callID) {
                resolvePendingResult(identifier: validatedCallID, recordID: id)
            }
            if let validatedItemID = InvocationIdentifier.validated(itemID) {
                resolvePendingResult(identifier: validatedItemID, recordID: id)
            }
        }

        let input = (payload.json["input"] as? String) ?? (payload.json["arguments"] as? String)
        guard let input else { return }
        let operations: [TransientToolInput.Call]
        var wrapperExtractionLimited = false
        if name == "exec" {
            let extraction = TransientToolInput.extractLiteralCalls(input)
            let nested = extraction.calls
            guard !nested.isEmpty else {
                issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "nested tool name not recoverable; dynamic or unsupported wrapper"))
                return
            }
            if extraction.wasLimited {
                issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "nested tool extraction limited; known literal operations retained"))
            }
            wrapperExtractionLimited = extraction.wasLimited
            operations = nested
            for (offset, operation) in nested.enumerated() {
                let childKind = Self.kind(for: operation.name)
                let suffix = nested.count == 1 ? "" : "-\(offset)"
                calls.append(CallRecord(id: "\(id)-nested-\(operation.name)\(suffix)", sessionID: sessionID,
                    parentCallID: id, ordinal: ordinal, timestamp: envelope.timestamp, actorName: nil,
                    resourceID: "\(childKind.rawValue):\(operation.name)", kind: childKind,
                    status: .unknown, durationMs: nil, confidence: .exact, errorCategory: nil, hasResult: true))
                ordinal += 1
            }
        } else { operations = [.init(name: name, input: input)] }
        let uncertainBatch = operations.count > 1
        var emittedSkills = Set<String>()
        var emittedAgents = Set<String>()
        for (operationIndex, operation) in operations.enumerated() {
            let uncertainResult = wrapperExtractionLimited || uncertainBatch || operation.resultBinding != .direct
            if operation.name == "spawn_agent", let role = TransientToolInput.arguments(operation.input)?["agent_type"] as? String {
                let resolved = agentResolver.resolveStructuredEvent(agentIdentifier: role, projectID: projectID)
                appendEvidence(id: "\(id)-delegation-request-\(operationIndex)", parentID: id, envelope: envelope, resourceID: resolved.resourceID,
                    kind: .agent, confidence: resolved.resourceID == nil ? .unknown : .inferred,
                    evidence: .agentDelegationRequest, uncertain: uncertainResult)
            }
            for resolved in skillResolver.resolveManifestReadSignals(input: operation.input, toolName: operation.name,
                projectID: projectID, workingDirectory: workingDirectory) {
                guard let resourceID = resolved.resourceID, emittedSkills.insert(resourceID).inserted else { continue }
                appendEvidence(id: "\(id)-skill-\(resourceID)", parentID: id, envelope: envelope, resourceID: resourceID,
                    kind: .skill, confidence: resolved.confidence, evidence: .skillManifestRead, uncertain: uncertainResult)
            }
            for resolved in agentResolver.resolveManifestReadSignals(input: operation.input, toolName: operation.name,
                projectID: projectID, workingDirectory: workingDirectory) {
                guard let resourceID = resolved.resourceID, emittedAgents.insert(resourceID).inserted else { continue }
                appendEvidence(id: "\(id)-agent-\(resourceID)", parentID: id, envelope: envelope, resourceID: resourceID,
                    kind: .agent, confidence: resolved.confidence, evidence: .agentBriefRead, uncertain: uncertainResult)
            }
        }
    }

    private mutating func appendEvidence(id: String, parentID: String, envelope: RolloutEnvelope, resourceID: String?,
        kind: InvocationKind, confidence: EvidenceConfidence, evidence: InvocationEvidenceKind, uncertain: Bool) {
        calls.append(CallRecord(id: id, sessionID: sessionID, parentCallID: parentID, ordinal: ordinal,
            timestamp: envelope.timestamp, actorName: nil, resourceID: resourceID, kind: kind,
            status: uncertain ? .unknown : .started, durationMs: nil, confidence: confidence,
            errorCategory: nil, hasResult: false, evidenceKind: evidence, hasUncertainResult: uncertain))
        recordIndexByID[id] = calls.count - 1
        ordinal += 1
    }

    private mutating func handleCallOutput(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let callID = InvocationIdentifier.validated(payload.json["call_id"] as? String) else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "call result without call_id"))
            return
        }
        guard let recordID = recordID(for: callID) else {
            enqueuePendingResult(
                identifier: callID,
                result: PendingResult(
                    status: .completed,
                    durationMs: nil,
                    errorCategory: nil,
                    lineNumber: envelope.lineNumber,
                    source: .genericOutput
                )
            )
            return
        }
        apply(
            PendingResult(
                status: .completed,
                durationMs: nil,
                errorCategory: nil,
                lineNumber: envelope.lineNumber,
                source: .genericOutput
            ),
            to: recordID
        )
    }

    private mutating func handleEndEvent(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let callID = InvocationIdentifier.validated(payload.json["call_id"] as? String) else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "end event without call_id"))
            return
        }
        guard let recordID = recordID(for: callID) else {
            var status = Self.endStatus(payload.json["status"])
            if let success = payload.json["success"] as? Bool, payload.json["status"] == nil {
                status = success ? .completed : .failed
            }
            enqueuePendingResult(
                identifier: callID,
                result: PendingResult(
                    status: status,
                    durationMs: Self.durationMs(from: payload.json["duration"]),
                    errorCategory: Self.commandErrorCategory(exitCode: Self.validatedExitCode(payload.json["exit_code"]), status: status),
                    lineNumber: envelope.lineNumber,
                    source: .legacyTerminal
                )
            )
            return
        }

        var endStatus = Self.endStatus(payload.json["status"])
        if let success = payload.json["success"] as? Bool, payload.json["status"] == nil {
            endStatus = success ? .completed : .failed
        }
        apply(
            PendingResult(
                status: endStatus,
                durationMs: Self.durationMs(from: payload.json["duration"]),
                errorCategory: Self.commandErrorCategory(exitCode: Self.validatedExitCode(payload.json["exit_code"]), status: endStatus),
                lineNumber: envelope.lineNumber,
                source: .legacyTerminal
            ),
            to: recordID
        )
    }

    private mutating func handleItemCompletion(envelope: RolloutEnvelope, payload: TransientPayload) {
        guard let item = payload.json["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              itemType == "CommandExecution" || itemType == "McpToolCall"
        else { return }

        let identifierFields = ["id", "call_id"].compactMap { key -> String? in
            guard item[key] != nil else { return nil }
            return InvocationIdentifier.validated(item[key] as? String)
        }
        let suppliedIdentifierCount = ["id", "call_id"].filter { item[$0] != nil }.count
        guard suppliedIdentifierCount == identifierFields.count,
              Set(identifierFields).count == 1,
              let identifier = identifierFields.first
        else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "item completion has a missing, invalid, or ambiguous identifier"))
            return
        }
        var status = Self.itemStatus(item["status"])
        let exitCode = itemType == "CommandExecution" ? Self.validatedExitCode(item["exit_code"]) : nil
        let durationMs = Self.durationMs(from: item["duration"])
        if item["duration"] != nil, durationMs == nil {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "item completion duration is invalid or outside limits"))
        }
        if itemType == "CommandExecution", item["exit_code"] != nil, exitCode == nil {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "item completion exit code is invalid or outside limits"))
        }
        if let exitCode {
            if exitCode != 0 { status = .failed }
            else if status == .unknown { status = .completed }
        }
        guard status == .completed || status == .failed || status == .interrupted else {
            issues.append(InvocationIssue(lineNumber: envelope.lineNumber, message: "item completion has no supported terminal status"))
            return
        }

        let result = PendingResult(
            status: status,
            durationMs: durationMs,
            errorCategory: itemType == "CommandExecution"
                ? Self.commandErrorCategory(exitCode: exitCode, status: status)
                : (status == .failed ? "mcp_error" : nil),
            lineNumber: envelope.lineNumber,
            source: .structuredItem
        )
        if let recordID = recordID(for: identifier) {
            apply(result, to: recordID)
        } else {
            enqueuePendingResult(identifier: identifier, result: result)
        }
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

        let resolved = skillResolver.resolveStructuredEvent(skillName: skillName, projectID: projectID)
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
            hasResult: true,
            evidenceKind: .structuredInvocation
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
        let resolved = agentResolver.resolveStructuredEvent(agentIdentifier: identifier, projectID: projectID)
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
            hasResult: true,
            evidenceKind: .structuredInvocation
        ))
        ordinal += 1
    }

    mutating func finish() -> InvocationExtraction {
        var issues = self.issues
        for result in pendingResults.values {
            let message = result.source == .structuredItem
                ? "item completion without matching call"
                : "call result without matching call"
            issues.append(InvocationIssue(lineNumber: result.lineNumber, message: message))
        }
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
        for index in calls.indices where (calls[index].kind == .skill || calls[index].kind == .agent) && calls[index].status == .started && calls[index].evidenceKind != .agentDelegation {
            calls[index].status = .unknown
        }
        let events = calls.map { $0.toEvent() }
        return InvocationExtraction(calls: events, issues: issues)
    }

    var unresolvedResultIdentifiers: Set<String> { Set(pendingResults.keys) }

    mutating func resolvePendingResults(aliases: [String: String]) {
        for identifier in pendingResults.keys.sorted() {
            guard let recordID = aliases[identifier] ?? recordID(for: identifier) else { continue }
            resolvePendingResult(identifier: identifier, recordID: recordID)
        }
    }

    private func recordID(for identifier: String) -> String? {
        if let current = recordIDByIdentifier[identifier] { return current }
        if priorCallsByID[identifier] != nil { return identifier }
        return nil
    }

    private mutating func resolvePendingResult(identifier: String, recordID: String) {
        guard let pending = pendingResults.removeValue(forKey: identifier) else { return }
        apply(pending, to: recordID)
    }

    private mutating func enqueuePendingResult(identifier: String, result: PendingResult) {
        if let existing = pendingResults[identifier] {
            pendingResults[identifier] = existing.merged(with: result)
        } else if pendingResults.count < Self.maximumPendingResults {
            pendingResults[identifier] = result
        } else {
            issues.append(InvocationIssue(lineNumber: result.lineNumber, message: "item completion correlation limit reached"))
        }
    }

    private mutating func mutableRecordIndex(for recordID: String) -> Int? {
        if let index = recordIndexByID[recordID] { return index }
        guard let prior = priorCallsByID[recordID] else { return nil }
        calls.append(CallRecord(event: prior))
        let index = calls.count - 1
        recordIndexByID[recordID] = index
        return index
    }

    private mutating func apply(_ result: PendingResult, to recordID: String) {
        if recordIndexByID[recordID] == nil, let prior = priorCallsByID[recordID] {
            let mergedStatus = Self.mergedTerminalStatus(prior.status, result.status)
            let unchangedDuration = result.durationMs == nil || result.durationMs == prior.durationMs
            let unchangedError = result.errorCategory == nil || result.errorCategory == prior.errorCategory
            if mergedStatus == prior.status, unchangedDuration, unchangedError {
                propagateToCapabilityChildren(parentID: recordID, status: mergedStatus)
                return
            }
        }
        guard let index = mutableRecordIndex(for: recordID) else { return }
        calls[index].hasResult = true
        calls[index].status = Self.mergedTerminalStatus(calls[index].status, result.status)
        if let durationMs = result.durationMs { calls[index].durationMs = durationMs }
        if let errorCategory = result.errorCategory { calls[index].errorCategory = errorCategory }
        propagateToCapabilityChildren(parentID: recordID, status: calls[index].status)
    }

    private mutating func propagateToCapabilityChildren(parentID: String, status: InvocationStatus) {
        let currentChildIDs = calls.filter {
            ($0.kind == .skill || $0.kind == .agent) && $0.parentCallID == parentID
        }.map(\.id)
        let childIDs = Set(currentChildIDs + priorChildIDsByParentID[parentID, default: []])
        for childID in childIDs {
            if recordIndexByID[childID] == nil, let prior = priorCallsByID[childID] {
                // The transient uncertainty bit is intentionally not
                // persisted. An unknown baseline child therefore never
                // inherits a wrapper terminal state after a checkpoint.
                if prior.status == .unknown { continue }
                if Self.mergedTerminalStatus(prior.status, status) == prior.status { continue }
            }
            guard let index = mutableRecordIndex(for: childID) else { continue }
            calls[index].status = calls[index].hasUncertainResult
                ? .unknown
                : Self.mergedTerminalStatus(calls[index].status, status)
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
    var evidenceKind: InvocationEvidenceKind? = nil
    var hasUncertainResult = false

    init(
        id: String,
        sessionID: String,
        parentCallID: String?,
        ordinal: Int,
        timestamp: Date?,
        actorName: String?,
        resourceID: String?,
        kind: InvocationKind,
        status: InvocationStatus,
        durationMs: Int?,
        confidence: EvidenceConfidence,
        errorCategory: String?,
        hasResult: Bool,
        evidenceKind: InvocationEvidenceKind? = nil,
        hasUncertainResult: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentCallID = parentCallID
        self.ordinal = ordinal
        self.timestamp = timestamp
        self.actorName = actorName
        self.resourceID = resourceID
        self.kind = kind
        self.status = status
        self.durationMs = durationMs
        self.confidence = confidence
        self.errorCategory = errorCategory
        self.hasResult = hasResult
        self.evidenceKind = evidenceKind
        self.hasUncertainResult = hasUncertainResult
    }

    init(event: InvocationEvent) {
        self.init(
            id: event.id,
            sessionID: event.sessionID,
            parentCallID: event.parentCallID,
            ordinal: event.ordinal,
            timestamp: event.timestamp,
            actorName: event.actorName,
            resourceID: event.resourceID,
            kind: event.kind,
            status: event.status,
            durationMs: event.durationMs,
            confidence: event.confidence,
            errorCategory: event.errorCategory,
            hasResult: event.status != .unknown && event.status != .started,
            evidenceKind: event.evidenceKind
        )
    }

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
            errorCategory: errorCategory,
            evidenceKind: evidenceKind
        )
    }
}

private struct OpenCall {
    let callID: String
    let recordIndex: Int
}

private enum PendingResultSource {
    case genericOutput
    case legacyTerminal
    case structuredItem
}

private struct PendingResult {
    let status: InvocationStatus
    let durationMs: Int?
    let errorCategory: String?
    let lineNumber: Int
    let source: PendingResultSource

    func merged(with newer: PendingResult) -> PendingResult {
        PendingResult(
            status: ExtractionState.mergedTerminalStatus(status, newer.status),
            durationMs: newer.durationMs ?? durationMs,
            errorCategory: newer.errorCategory ?? errorCategory,
            lineNumber: newer.lineNumber,
            source: source == .structuredItem || newer.source == .structuredItem ? .structuredItem : newer.source
        )
    }
}

enum InvocationIdentifier {
    private static let maximumLength = 256

    static func validated(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLength else { return nil }
        guard let first = value.unicodeScalars.first,
              (first.value >= 48 && first.value <= 57)
                || (first.value >= 65 && first.value <= 90)
                || (first.value >= 97 && first.value <= 122)
        else { return nil }
        for scalar in value.unicodeScalars {
            let valid = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == ":" || scalar == "." || scalar == "_" || scalar == "-"
            if !valid { return nil }
        }
        return value
    }
}

// MARK: - Classification helpers

private extension ExtractionState {
    static func kind(for name: String) -> InvocationKind {
        switch name {
        case "spawn_agent", "send_input", "wait_agent", "resume_agent", "close_agent", "send_message", "followup_task", "interrupt_agent", "list_agents":
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
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= Double(Int32.max), value.rounded() == value else { return nil }
            return Int(value)
        }
        guard let object = raw as? [String: Any],
              let secs = validatedInteger(object["secs"]),
              let nanos = validatedInteger(object["nanos"]),
              secs >= 0,
              nanos >= 0,
              nanos < 1_000_000_000
        else { return nil }
        let (secondsMs, secondsOverflow) = secs.multipliedReportingOverflow(by: 1_000)
        let (total, totalOverflow) = secondsMs.addingReportingOverflow(nanos / 1_000_000)
        guard !secondsOverflow, !totalOverflow, total <= Int(Int32.max) else { return nil }
        return total
    }

    static func validatedInteger(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded() == value,
              value >= Double(Int.min),
              value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }

    static func validatedExitCode(_ raw: Any?) -> Int? {
        guard let value = validatedInteger(raw), (-1...255).contains(value) else { return nil }
        return value
    }

    static func commandErrorCategory(exitCode: Int?, status: InvocationStatus) -> String? {
        if let exitCode, exitCode != 0 { return "exit_\(exitCode)" }
        return status == .failed ? "command_failed" : nil
    }

    static func mergedTerminalStatus(_ current: InvocationStatus, _ incoming: InvocationStatus) -> InvocationStatus {
        func rank(_ status: InvocationStatus) -> Int {
            switch status {
            case .failed, .interrupted: return 3
            case .completed: return 2
            case .retried: return 1
            case .started, .unknown: return 0
            }
        }
        return rank(incoming) > rank(current) ? incoming : current
    }

}
