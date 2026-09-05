import XCTest
@testable import DirectorCore

final class InvocationExtractorTests: XCTestCase {

    private let sessionID = "session:test"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func envelope(_ json: String, line: Int) -> RolloutEnvelope {
        let result = RolloutEventDecoder().decode(
            JSONLLine(byteOffset: UInt64(line), lineNumber: line, text: json)
        )
        guard case .envelope(let envelope)? = result.line else {
            fatalError("fixture did not decode: \(json)")
        }
        return envelope
    }

    private func extract(_ envelopes: [RolloutEnvelope]) -> InvocationExtraction {
        InvocationExtractor().extract(sessionID: sessionID, envelopes: envelopes)
    }

    private func call(
        _ json: String,
        callID: String = "call-1",
        name: String,
        input: String? = nil,
        line: Int = 1
    ) -> RolloutEnvelope {
        let inputJSON = input.map { ", \"input\": \"\($0)\"" } ?? ""
        return envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"\#(callID)-item","call_id":"\#(callID)","name":"\#(name)"\#(inputJSON)}}"#,
            line: line
        )
    }

    private func output(_ json: String, callID: String = "call-1", line: Int = 2) -> RolloutEnvelope {
        envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"custom_tool_call_output","id":"\#(callID)-out","call_id":"\#(callID)","output":[{"type":"text","text":"ok"}]}}"#,
            line: line
        )
    }

    // MARK: - Tests

    func testExactToolCallAndResult() {
        let result = extract([
            call("", name: "read"),
            output(""),
        ])
        XCTAssertEqual(result.calls.count, 1)
        let call = result.calls[0]
        XCTAssertEqual(call.kind, .tool)
        XCTAssertEqual(call.resourceID, "tool:read")
        XCTAssertEqual(call.status, .completed)
        XCTAssertEqual(call.confidence, .exact)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testNestedExecCommandRecovered() {
        let result = extract([
            call("", name: "exec", input: "const r = await tools.exec_command({command: 'ls'})"),
            output(""),
        ])
        XCTAssertEqual(result.calls.count, 2)
        let parent = result.calls[0]
        let child = result.calls[1]
        XCTAssertEqual(parent.resourceID, "tool:exec")
        XCTAssertEqual(child.resourceID, "tool:exec_command")
        XCTAssertEqual(child.parentCallID, parent.id)
        XCTAssertGreaterThan(child.ordinal, parent.ordinal)
        XCTAssertEqual(child.confidence, .exact)
    }

    func testMultiAgentLifecycleNestedToolIsOrchestration() {
        let result = extract([
            call("", name: "exec", input: "await tools.spawn_agent({prompt: 'x'})"),
        ])
        XCTAssertEqual(result.calls.count, 2)
        XCTAssertEqual(result.calls[1].kind, .orchestration)
        XCTAssertEqual(result.calls[1].resourceID, "orchestration:spawn_agent")
    }

    func testAllAgentLifecycleToolsAreOrchestration() {
        let lifecycleTools = ["spawn_agent", "send_input", "wait_agent", "resume_agent", "close_agent"]
        let result = extract(lifecycleTools.enumerated().map { index, name in
            call("", callID: "lifecycle-\(index)", name: name, line: index + 1)
        })
        XCTAssertEqual(result.calls.map(\.kind), Array(repeating: .orchestration, count: lifecycleTools.count))
        XCTAssertEqual(result.calls.map(\.resourceID), lifecycleTools.map { "orchestration:\($0)" })
    }

    func testStructuredAgentEventResolvesExactDiscoveredAgent() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent",
            name: "Sample Agent",
            kind: .agent,
            status: .unknown,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: "global-agents",
            relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil,
            lastSeenAt: epoch
        )
        let event = envelope(
            #"{"type":"event_msg","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"agent_invoked","agent":"Sample Agent","status":"completed"}}"#,
            line: 1
        )
        let result = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
            .extract(sessionID: sessionID, envelopes: [event])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls[0].kind, .agent)
        XCTAssertEqual(result.calls[0].resourceID, agent.id)
        XCTAssertEqual(result.calls[0].confidence, .exact)
    }

    func testAgentManifestReadProducesInferredAgentInvocation() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent",
            name: "Sample Agent",
            kind: .agent,
            status: .unknown,
            scope: .global,
            projectID: nil,
            confidence: .exact,
            summary: nil,
            sourceRootID: "global-agents",
            relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil,
            lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "agent-read", name: "read", input: "cat sample-agent/agent.md"),
            output("", callID: "agent-read"),
        ])
        let child = result.calls.first { $0.kind == .agent }
        XCTAssertEqual(child?.resourceID, agent.id)
        XCTAssertEqual(child?.confidence, .inferred)
        XCTAssertEqual(child?.parentCallID, "agent-read-item")
        XCTAssertEqual(child?.status, .completed)
    }

    func testUnknownAgentPathPrefixDoesNotResolveBySuffix() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "unknown-prefix", name: "read", input: "cat unknown/sample-agent/agent.md"),
            output("", callID: "unknown-prefix"),
        ])
        XCTAssertFalse(result.calls.contains { $0.kind == .agent })
    }

    func testMixedAgentReadAndDeleteCommandDoesNotResolve() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "mixed-agent", name: "exec", input: "const r = await tools.exec_command({command: 'cat unrelated.txt; rm sample-agent/agent.md'})"),
            output("", callID: "mixed-agent"),
        ])
        XCTAssertFalse(result.calls.contains { $0.kind == .agent })
    }

    func testAgentReadWithRedirectionDoesNotResolve() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "redirect-agent", name: "exec", input: "const r = await tools.exec_command({command: 'cat sample-agent/agent.md > /tmp/out'})"),
            output("", callID: "redirect-agent"),
        ])
        XCTAssertFalse(result.calls.contains { $0.kind == .agent })
    }

    func testAgentManifestPathInCommentDoesNotResolve() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "comment-agent", name: "exec", input: "const r = await tools.exec_command({command: 'cat unrelated.txt # sample-agent/agent.md'})"),
            output("", callID: "comment-agent"),
        ])
        XCTAssertFalse(result.calls.contains { $0.kind == .agent })
    }

    func testSedMutationOptionsDoNotResolveAgentManifest() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
        let mutationCommands = [
            "sed --in-place sample-agent/agent.md",
            "sed --in-place=.bak sample-agent/agent.md",
            "sed -i.bak sample-agent/agent.md",
            "sed -ni sample-agent/agent.md",
        ]
        for (index, command) in mutationCommands.enumerated() {
            let result = extractor.extract(sessionID: sessionID, envelopes: [
                call("", callID: "sed-agent-\(index)", name: "exec", input: "const r = await tools.exec_command({command: '\(command)'})"),
                output("", callID: "sed-agent-\(index)"),
            ])
            XCTAssertFalse(result.calls.contains { $0.kind == .agent }, command)
        }

        let readOnly = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "sed-read-agent", name: "exec", input: "const r = await tools.exec_command({command: 'sed -n sample-agent/agent.md'})"),
            output("", callID: "sed-read-agent"),
        ])
        XCTAssertTrue(readOnly.calls.contains { $0.kind == .agent && $0.resourceID == agent.id })
    }

    func testAgentAbsoluteManifestRequiresExactKnownScanRootPath() {
        let agent = CapabilityResource(
            id: "agent:global:sample-agent", name: "Sample Agent", kind: .agent,
            status: .unknown, scope: .global, projectID: nil, confidence: .exact,
            summary: nil, sourceRootID: "global-agents", relativeSourcePath: "sample-agent/agent.md",
            sourcePathHash: nil, lastSeenAt: epoch
        )
        let root = ScanRoot(id: "global-agents", url: URL(fileURLWithPath: "/known/agents"), scope: .global, kind: .agents)
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent], roots: [root]))
        let known = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "known-absolute", name: "read", input: "cat /known/agents/sample-agent/agent.md"),
            output("", callID: "known-absolute"),
        ])
        XCTAssertTrue(known.calls.contains { $0.kind == .agent && $0.resourceID == agent.id })

        let unknown = extractor.extract(sessionID: sessionID, envelopes: [
            call("", callID: "unknown-absolute", name: "read", input: "cat /other/agents/sample-agent/agent.md"),
            output("", callID: "unknown-absolute"),
        ])
        XCTAssertFalse(unknown.calls.contains { $0.kind == .agent })
    }

    func testAmbiguousAgentManifestReadDoesNotChooseAnAgent() {
        let resources = [
            CapabilityResource(id: "agent:a", name: "Same", kind: .agent, status: .unknown, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "root-a", relativeSourcePath: "same/agent.md", sourcePathHash: nil, lastSeenAt: epoch),
            CapabilityResource(id: "agent:b", name: "Same", kind: .agent, status: .unknown, scope: .project, projectID: "p", confidence: .exact, summary: nil, sourceRootID: "root-b", relativeSourcePath: "same/agent.md", sourcePathHash: nil, lastSeenAt: epoch),
        ]
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: resources))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            call("", name: "read", input: "cat same/agent.md"),
            output(""),
        ])
        let agents = result.calls.filter { $0.kind == .agent }
        XCTAssertTrue(agents.isEmpty)
    }

    func testAgentNameInSystemContextDoesNotCreateInvocation() {
        let agent = CapabilityResource(id: "agent:a", name: "Sample Agent", kind: .agent, status: .unknown, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "root", relativeSourcePath: "sample-agent/agent.md", sourcePathHash: nil, lastSeenAt: epoch)
        let meta = envelope(
            #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"s1","base_instructions":"Agents available: Sample Agent"}}"#,
            line: 1
        )
        let result = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent]))
            .extract(sessionID: sessionID, envelopes: [meta])
        XCTAssertTrue(result.calls.isEmpty)
    }

    func testInvalidNestedInputProducesIssueAndNoChild() {
        let result = extract([
            call("", name: "exec", input: "run something without a nested tool"),
            output(""),
        ])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls[0].resourceID, "tool:exec")
        XCTAssertTrue(result.issues.contains { $0.message.contains("nested tool name not recoverable") })
    }

    func testMissingResultProducesIssue() {
        let result = extract([
            call("", name: "read"),
        ])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("no matching result") })
    }

    func testRetryAfterFailurePreserved() {
        let failedEnd = envelope(
            #"{"type":"event_msg","timestamp":"2026-08-15T04:12:06.000Z","payload":{"type":"exec_command_end","call_id":"retry-1","status":"failed","duration":{"secs":1,"nanos":0},"exit_code":2}}"#,
            line: 4
        )
        let successEnd = envelope(
            #"{"type":"event_msg","timestamp":"2026-08-15T04:12:08.000Z","payload":{"type":"exec_command_end","call_id":"retry-1","status":"completed","duration":{"secs":1,"nanos":0},"exit_code":0}}"#,
            line: 7
        )
        let oldCall = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.000Z","payload":{"type":"function_call","id":"f-1","call_id":"retry-1","name":"exec_command","arguments":"{}"}}"#,
            line: 1
        )
        let oldOutput = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.100Z","payload":{"type":"function_call_output","id":"f-1o","call_id":"retry-1","output":"x"}}"#,
            line: 2
        )
        let retryCall = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:07.000Z","payload":{"type":"function_call","id":"f-2","call_id":"retry-1","name":"exec_command","arguments":"{}"}}"#,
            line: 5
        )
        let retryOutput = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:07.100Z","payload":{"type":"function_call_output","id":"f-2o","call_id":"retry-1","output":"y"}}"#,
            line: 6
        )

        let result = extract([oldCall, oldOutput, failedEnd, retryCall, retryOutput, successEnd])
        XCTAssertEqual(result.calls.count, 2)
        XCTAssertEqual(result.calls[0].status, .failed)
        XCTAssertEqual(result.calls[0].resourceID, "tool:exec_command")
        XCTAssertEqual(result.calls[0].errorCategory, "exit_2")
        XCTAssertEqual(result.calls[1].status, .completed)
        XCTAssertEqual(result.calls[1].resourceID, "tool:exec_command")
        XCTAssertEqual(result.calls[0].ordinal, 0)
        XCTAssertEqual(result.calls[1].ordinal, 1)
    }

    func testDuplicateEventDoesNotDuplicateCall() {
        let first = call("", name: "read", line: 1)
        let duplicate = call("", name: "read", line: 2)
        let result = extract([first, duplicate])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertTrue(result.issues.contains { $0.message.contains("duplicate event") })
    }

    func testUnmatchedResultProducesIssue() {
        let result = extract([output("", callID: "orphan")])
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.message.contains("without matching call") })
    }

    func testCompactionEmittedAsInvocation() {
        let compacted = envelope(
            #"{"type":"compacted","timestamp":"2026-08-15T04:12:08.000Z","payload":{"window_id":"w1","window_number":1}}"#,
            line: 9
        )
        let result = extract([compacted])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls[0].kind, .compaction)
        XCTAssertEqual(result.calls[0].status, .completed)
    }

    func testSkillNameInMessageDoesNotCreateInvocation() {
        let message = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:06.000Z","payload":{"type":"message","id":"m-1","role":"assistant","content":[{"type":"output_text","text":"I will use SKILL.md for this task"}]}}"#,
            line: 3
        )
        let result = extract([message])
        XCTAssertTrue(result.calls.isEmpty)
    }

    func testIntegrationFixtureSession() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing/invocations.jsonl")
        guard let reader = JSONLIncrementalReader(url: url) else {
            return XCTFail("cannot open fixture")
        }
        let decoder = RolloutEventDecoder()
        var envelopes: [RolloutEnvelope] = []
        while let line = try reader.nextLine() {
            if case .envelope(let envelope)? = decoder.decode(line).line {
                envelopes.append(envelope)
            }
        }
        let result = InvocationExtractor().extract(sessionID: "syn-inv-1", envelopes: envelopes)
        XCTAssertEqual(result.calls.count, 3) // exec + nested exec_command + compaction
        XCTAssertEqual(result.calls.map(\.kind), [.tool, .tool, .compaction])
        XCTAssertEqual(result.calls[1].resourceID, "tool:exec_command")
        XCTAssertEqual(result.calls[0].durationMs, 2500)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAccumulatorMatchesBatchExtraction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing/invocations.jsonl")
        guard let reader = JSONLIncrementalReader(url: url) else {
            return XCTFail("cannot open fixture")
        }
        let decoder = RolloutEventDecoder()
        var envelopes: [RolloutEnvelope] = []
        while let line = try reader.nextLine() {
            if case .envelope(let envelope)? = decoder.decode(line).line {
                envelopes.append(envelope)
            }
        }
        let batch = InvocationExtractor().extract(sessionID: "syn-inv-1", envelopes: envelopes)
        var accumulator = InvocationExtractor().makeAccumulator(sessionID: "syn-inv-1")
        for envelope in envelopes { accumulator.process(envelope) }
        let streamed = accumulator.finish()
        XCTAssertEqual(streamed.calls.map(\.id), batch.calls.map(\.id))
        XCTAssertEqual(streamed.calls.map(\.ordinal), batch.calls.map(\.ordinal))
        XCTAssertEqual(streamed.calls.map(\.resourceID), batch.calls.map(\.resourceID))
        XCTAssertEqual(streamed.issues.count, batch.issues.count)
    }

    // MARK: - Skill evidence matrix (Task 4 P1)

    private func skillResources() -> [CapabilityResource] {
        [
            CapabilityResource(id: "skill:sample-skill", name: "sample-skill", kind: .skill, status: .unknown, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global-skills", relativeSourcePath: "sample-skill/SKILL.md", sourcePathHash: nil, lastSeenAt: epoch),
            CapabilityResource(id: "skill:other-skill", name: "other-skill", kind: .skill, status: .unknown, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "global-skills", relativeSourcePath: "other-skill/SKILL.md", sourcePathHash: nil, lastSeenAt: epoch),
        ]
    }

    private func readCall(_ input: String, callID: String = "r1") -> RolloutEnvelope {
        envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"\#(callID)","call_id":"\#(callID)","name":"read","input":"\#(input)"}}"#,
            line: 1
        )
    }

    func testStructuredSkillEventProducesExactSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let event = envelope(
            #"{"type":"event_msg","timestamp":"2026-08-15T04:12:05.950Z","payload":{"type":"skill_invoked","skill":"sample-skill","status":"completed"}}"#,
            line: 1
        )
        let result = extractor.extract(sessionID: sessionID, envelopes: [event])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls[0].kind, .skill)
        XCTAssertEqual(result.calls[0].resourceID, "skill:sample-skill")
        XCTAssertEqual(result.calls[0].confidence, .exact)
        XCTAssertEqual(result.calls[0].status, .completed)
    }

    func testManifestReadToolCallProducesInferredSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            readCall("read sample-skill/SKILL.md"),
            output("", callID: "r1"),
        ])
        XCTAssertEqual(result.calls.count, 2)
        let skill = result.calls[1]
        XCTAssertEqual(skill.kind, .skill)
        XCTAssertEqual(skill.resourceID, "skill:sample-skill")
        XCTAssertEqual(skill.confidence, .inferred)
        XCTAssertEqual(skill.parentCallID, "r1")
        // Parent result status propagates to the derived Skill child.
        XCTAssertEqual(skill.status, .completed)
    }

    func testUnknownSkillPathPrefixDoesNotResolveBySuffix() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            readCall("read unknown/sample-skill/SKILL.md", callID: "unknown-skill"),
            output("", callID: "unknown-skill"),
        ])
        assertNoSkillInvocation(result)
    }

    func testMixedSkillReadAndDeleteCommandDoesNotResolve() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"mixed-skill","call_id":"mixed-skill","name":"exec","input":"const r = await tools.exec_command({command: 'cat unrelated.txt; rm sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "mixed-skill"),
        ])
        assertNoSkillInvocation(result)
    }

    func testSkillReadWithRedirectionDoesNotResolve() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"redirect-skill","call_id":"redirect-skill","name":"exec","input":"const r = await tools.exec_command({command: 'cat sample-skill/SKILL.md > /tmp/out'})"}}"#, line: 1),
            output("", callID: "redirect-skill"),
        ])
        assertNoSkillInvocation(result)
    }

    func testSkillManifestPathInSecondShellLineDoesNotResolve() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"newline-skill","call_id":"newline-skill","name":"exec","input":"const r = await tools.exec_command({command: 'cat unrelated.txt\u000acat sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "newline-skill"),
        ])
        assertNoSkillInvocation(result)
    }

    func testSedMutationOptionsDoNotResolveSkillManifest() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let mutationCommands = [
            "sed --in-place sample-skill/SKILL.md",
            "sed --in-place=.bak sample-skill/SKILL.md",
            "sed -i.bak sample-skill/SKILL.md",
            "sed -ni sample-skill/SKILL.md",
        ]
        for (index, command) in mutationCommands.enumerated() {
            let result = extractor.extract(sessionID: sessionID, envelopes: [
                envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"sed-skill-\#(index)","call_id":"sed-skill-\#(index)","name":"exec","input":"const r = await tools.exec_command({command: '\#(command)'})"}}"#, line: index + 1),
                output("", callID: "sed-skill-\(index)"),
            ])
            assertNoSkillInvocation(result)
        }

        let readOnly = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"sed-read-skill","call_id":"sed-read-skill","name":"exec","input":"const r = await tools.exec_command({command: 'sed -n sample-skill/SKILL.md'})"}}"#, line: 10),
            output("", callID: "sed-read-skill"),
        ])
        XCTAssertTrue(readOnly.calls.contains { $0.kind == .skill && $0.resourceID == "skill:sample-skill" })
    }

    func testAmbiguousManifestSignalProducesUnknownSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            readCall("read sample-skill/SKILL.md other-skill/SKILL.md"),
            output("", callID: "r1"),
        ])
        XCTAssertEqual(result.calls.count, 2)
        let skill = result.calls[1]
        XCTAssertEqual(skill.kind, .skill)
        XCTAssertEqual(skill.confidence, .unknown)
        XCTAssertNil(skill.resourceID)
    }

    func testSystemPromptSkillNameProducesNoSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let meta = envelope(
            #"{"type":"session_meta","timestamp":"2026-08-15T04:11:50.973Z","payload":{"id":"s1","session_id":"s1","base_instructions":"Skills available: sample-skill, other-skill"}}"#,
            line: 1
        )
        let message = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"text","text":"please use sample-skill"}]}}"#,
            line: 2
        )
        let outputMessage = envelope(
            #"{"type":"response_item","timestamp":"2026-08-15T04:12:06.000Z","payload":{"type":"message","id":"m2","role":"assistant","content":[{"type":"text","text":"I invoked sample-skill"}]}}"#,
            line: 3
        )
        let result = extractor.extract(sessionID: sessionID, envelopes: [meta, message, outputMessage])
        XCTAssertTrue(result.calls.isEmpty)
    }

    func testMissingParentResultLeavesSkillEvidenceUnknown() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // Manifest-read call without a matching result: skill stays unknown,
        // and the missing-result issue reduces coverage.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            readCall("read sample-skill/SKILL.md"),
        ])
        XCTAssertEqual(result.calls.count, 2)
        XCTAssertEqual(result.calls[1].kind, .skill)
        XCTAssertEqual(result.calls[1].status, .unknown)
        XCTAssertTrue(result.issues.contains { $0.message.contains("no matching result") })
    }

    // MARK: - Skill evidence negative matrix (real reads only)

    private func assertNoSkillInvocation(_ result: InvocationExtraction, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.calls.contains { $0.kind == .skill }, "unexpected Skill invocation", file: file, line: line)
    }

    func testWriteOperationDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"w1","call_id":"w1","name":"write","input":"write sample-skill/SKILL.md"}}"#, line: 1),
            output("", callID: "w1"),
        ])
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls[0].kind, .tool)
        assertNoSkillInvocation(result)
    }

    func testDeleteOperationDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"d1","call_id":"d1","name":"exec","input":"const r = await tools.exec_command({command: 'rm sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "d1"),
        ])
        XCTAssertEqual(result.calls.count, 2) // exec + nested exec_command
        assertNoSkillInvocation(result)
    }

    func testSearchOperationDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"g1","call_id":"g1","name":"grep","input":"grep -r sample-skill/SKILL.md ."}}"#, line: 1),
            output("", callID: "g1"),
        ])
        XCTAssertEqual(result.calls.count, 1)
        assertNoSkillInvocation(result)
    }

    func testPlainTextReferenceDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // echo is not a read operation, even though the path appears as text.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"e1","call_id":"e1","name":"exec","input":"const r = await tools.exec_command({command: 'echo sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "e1"),
        ])
        XCTAssertEqual(result.calls.count, 2) // exec + nested exec_command
        assertNoSkillInvocation(result)
    }

    // MARK: - Executable-position read detection (convergence fix)

    func testShellCatCommandProducesInferredSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // `cat` in executable position of the parsed command is a real read.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"s1","call_id":"s1","name":"exec","input":"const r = await tools.exec_command({command: 'cat sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "s1"),
        ])
        let skill = result.calls.first { $0.kind == .skill }
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.confidence, .inferred)
        XCTAssertEqual(skill?.resourceID, "skill:sample-skill")
    }

    func testShellCmdKeyProducesInferredSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // Real harness shape: `cmd:` alias instead of `command:`.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"c1","call_id":"c1","name":"exec","input":"const r = await tools.exec_command({cmd: 'cat sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "c1"),
        ])
        let skill = result.calls.first { $0.kind == .skill }
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.confidence, .inferred)
        XCTAssertEqual(skill?.resourceID, "skill:sample-skill")
    }

    func testShellQuotedCmdKeyProducesInferredSkillInvocation() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // Quoted key shape `{"cmd": 'cat …'}` is also recognized.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"c2","call_id":"c2","name":"exec","input":"const r = await tools.exec_command({\"cmd\": 'cat sample-skill/SKILL.md'})"}}"#, line: 1),
            output("", callID: "c2"),
        ])
        let skill = result.calls.first { $0.kind == .skill }
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.confidence, .inferred)
        XCTAssertEqual(skill?.resourceID, "skill:sample-skill")
    }

    func testReadCommandInsideQuotedEchoArgumentDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        // `cat` is inside echo quotes: not an executable read.
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"q1","call_id":"q1","name":"exec","input":"const r = await tools.exec_command({command: 'echo \"cat sample-skill/SKILL.md\"'})"}}"#, line: 1),
            output("", callID: "q1"),
        ])
        assertNoSkillInvocation(result)
    }

    func testReadCommandInsidePrintfArgumentDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"p1","call_id":"p1","name":"exec","input":"const r = await tools.exec_command({command: 'printf \"%s\" \"cat sample-skill/SKILL.md\"'})"}}"#, line: 1),
            output("", callID: "p1"),
        ])
        assertNoSkillInvocation(result)
    }

    func testReadCommandInsideSearchExpressionDoesNotProduceSkillEvidence() throws {
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: skillResources()))
        let result = extractor.extract(sessionID: sessionID, envelopes: [
            envelope(#"{"type":"response_item","timestamp":"2026-08-15T04:12:05.949Z","payload":{"type":"custom_tool_call","id":"r1","call_id":"r1","name":"exec","input":"const r = await tools.exec_command({command: 'rg \"cat sample-skill/SKILL.md\" .'})"}}"#, line: 1),
            output("", callID: "r1"),
        ])
        assertNoSkillInvocation(result)
    }
}
