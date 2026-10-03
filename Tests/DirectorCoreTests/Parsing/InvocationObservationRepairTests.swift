import XCTest
@testable import DirectorCore

final class InvocationObservationRepairTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_982_000)

    private func resource(_ id: String, _ name: String, kind: ResourceKind, project: String? = nil, path: String) -> CapabilityResource {
        CapabilityResource(id: id, name: name, kind: kind, status: .unknown,
            scope: project == nil ? .global : .project, projectID: project, confidence: .exact,
            summary: nil, sourceRootID: project ?? "global", relativeSourcePath: path,
            sourcePathHash: nil, lastSeenAt: date)
    }

    private func event(_ type: String, _ payload: [String: Any], ordinal: Int = 0) -> RolloutEnvelope {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-03T00:00:00Z", "ordinal": ordinal, "payload": payload])
        let result = RolloutEventDecoder().decode(JSONLLine(byteOffset: UInt64(ordinal), lineNumber: ordinal + 1, text: String(decoding: data, as: UTF8.self)))
        guard case .envelope(let envelope) = result.line else { fatalError("invalid synthetic fixture") }
        return envelope
    }

    func testChildRoleResolvesProjectOverrideRatherThanGlobalNameCollision() {
        let global = resource("agent:global", "Sample Agent", kind: .agent, path: "sample-agent/agent.md")
        let project = resource("agent:project", "Sample Agent", kind: .agent, project: "project", path: ".codex/agents/sample-agent.toml")
        let root = ScanRoot(id: "project", url: URL(fileURLWithPath: "/fixture/project"), scope: .project, kind: .projects)
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [global, project], roots: [root]))
        let result = extractor.extract(sessionID: "child", envelopes: [event("session_meta", ["id": "child", "cwd": "/fixture/project", "agent_role": "Sample Agent", "parent_thread_id": "parent", "source": ["subagent": ["thread_spawn": [:]]]])])
        XCTAssertEqual(result.calls.filter { $0.kind == .agent }.map(\.resourceID), [project.id])
    }

    func testGlobalConfigurationAndBriefShareCanonicalAgent() {
        let agent = resource("agent:global", "Sample Agent", kind: .agent, path: "sample-agent/agent.md")
        let pairing = CapabilityAgentPairing(sourceRootID: "global", agentRelativePath: "sample-agent/agent.md", briefRelativePath: "sample-agent/agent.md", configurationRelativePath: "sample-agent.toml")
        let extractor = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent], pairings: [pairing]))
        let result = extractor.extract(sessionID: "root", envelopes: [event("response_item", ["type": "function_call", "id": "read", "call_id": "read", "name": "exec_command", "arguments": "{\"cmd\":\"cat sample-agent.toml\"}"] )])
        XCTAssertEqual(result.calls.filter { $0.kind == .agent }.map(\.resourceID), [agent.id])
    }

    func testLiteralMultiToolWrapperResolvesEachSkill() {
        let a = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let b = resource("skill:b", "sample-b", kind: .skill, path: "sample-b/SKILL.md")
        let extractor = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [a, b]))
        let input = "const a = await tools.exec_command({cmd: 'cat sample-a/SKILL.md'}); const b = await tools.exec_command({cmd: 'cat sample-b/SKILL.md'}); text(a); text(b);"
        let result = extractor.extract(sessionID: "root", envelopes: [event("response_item", ["type": "custom_tool_call", "id": "batch", "call_id": "batch", "name": "exec", "input": input])])
        XCTAssertEqual(Set(result.calls.filter { $0.kind == .skill }.compactMap(\.resourceID)), [a.id, b.id])
    }

    func testSpawnTypeIsRequestEvidenceNotAnotherConfirmedDelegation() {
        let agent = resource("agent:global", "Sample Agent", kind: .agent, path: "sample-agent.toml")
        let args = "{\"agent_type\":\"Sample Agent\",\"message\":\"synthetic task\"}"
        let result = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent])).extract(sessionID: "parent", envelopes: [
            event("response_item", ["type": "function_call", "id": "spawn", "call_id": "spawn", "name": "collaboration.spawn_agent", "arguments": args])])
        XCTAssertEqual(result.calls.first?.kind, .orchestration)
        XCTAssertEqual(result.calls.filter { $0.kind == .agent }.first?.evidenceKind, .agentDelegationRequest)
        XCTAssertFalse(result.calls.contains { $0.evidenceKind == .agentDelegation })
    }

    func testRoleWithoutChildSourceOrParentDoesNotCreateDelegation() {
        let agent = resource("agent:global", "Sample Agent", kind: .agent, path: "sample-agent.toml")
        let result = InvocationExtractor(agentResolver: AgentEvidenceResolver(resources: [agent])).extract(sessionID: "root", envelopes: [
            event("session_meta", ["id": "root", "agent_role": "Sample Agent", "agent_path": "Sample Agent", "base_instructions": "Sample Agent"])])
        XCTAssertTrue(result.calls.isEmpty)
    }

    func testExplicitHistoryBoundaryExcludesInheritedCallsAndEmitsOneLaunch() {
        let agent = resource("agent:global", "Sample Agent", kind: .agent, path: "sample-agent.toml")
        let skill = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let meta = event("session_meta", ["id": "child", "parent_thread_id": "parent", "agent_role": "Sample Agent", "forked_from_id": "parent", "subagent_history_start_ordinal": 7])
        let inherited = event("response_item", ["type": "function_call", "id": "old", "call_id": "old", "name": "exec_command", "arguments": "{\"cmd\":\"cat sample-a/SKILL.md\"}"], ordinal: 1)
        let own = event("response_item", ["type": "function_call", "id": "own", "call_id": "own", "name": "exec_command", "arguments": "{\"cmd\":\"cat sample-a/SKILL.md\"}"], ordinal: 7)
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [skill]), agentResolver: AgentEvidenceResolver(resources: [agent])).extract(sessionID: "child", envelopes: [meta, meta, inherited, own])
        XCTAssertEqual(result.calls.filter { $0.evidenceKind == .agentDelegation }.count, 1)
        XCTAssertEqual(result.calls.filter { $0.kind == .skill }.count, 1)
        XCTAssertFalse(result.calls.contains { $0.id.contains("old") })
    }

    func testForkWithoutBoundaryDoesNotGuessOwnReads() {
        let skill = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [skill])).extract(sessionID: "child", envelopes: [
            event("session_meta", ["id": "child", "forked_from_id": "parent"]),
            event("response_item", ["type": "custom_tool_call", "id": "old", "call_id": "old", "name": "read", "input": "sample-a/SKILL.md"], ordinal: 1)])
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.message.contains("boundary unavailable") })
    }

    func testMalformedHistoryBoundaryDoesNotTreatBooleanOrFractionAsPosition() {
        let skill = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        for invalid: Any in [true, -1, 1.5, "7"] {
            let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [skill])).extract(sessionID: "child", envelopes: [
                event("session_meta", ["id": "child", "forked_from_id": "parent", "subagent_history_start_ordinal": invalid]),
                event("response_item", ["type": "custom_tool_call", "id": "old", "call_id": "old", "name": "read", "input": "sample-a/SKILL.md"], ordinal: 8)])
            XCTAssertTrue(result.calls.isEmpty)
            XCTAssertTrue(result.issues.contains { $0.message.contains("boundary unavailable") })
        }
    }

    func testExplicitSkillIDIsAuthoritativeAndNamesRemainProjectScoped() {
        let a = resource("skill:a", "sample", kind: .skill, project: "a", path: "sample/SKILL.md")
        let b = resource("skill:b", "sample", kind: .skill, project: "b", path: "sample/SKILL.md")
        let resolver = SkillEvidenceResolver(resources: [a, b])
        XCTAssertEqual(resolver.resolveStructuredEvent(skillName: b.id, projectID: "a").resourceID, b.id)
        XCTAssertEqual(resolver.resolveStructuredEvent(skillName: "sample", projectID: "a").resourceID, a.id)
        XCTAssertNil(resolver.resolveStructuredEvent(skillName: "sample").resourceID)
    }

    func testCommentsAndQuotedToolNamesAreNotCalls() {
        let skill = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let input = "// tools.exec_command({cmd: 'cat missing/SKILL.md'})\nconst ignored = 'tools.fake_tool'; const r = await tools.exec_command({cmd: 'cat sample-a/SKILL.md'}); text(r);"
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [skill])).extract(sessionID: "root", envelopes: [event("response_item", ["type": "custom_tool_call", "id": "read", "call_id": "read", "name": "exec", "input": input])])
        XCTAssertEqual(result.calls.filter { $0.kind == .skill }.compactMap(\.resourceID), [skill.id])
        XCTAssertEqual(result.calls.filter { $0.parentCallID != nil && $0.kind == .tool }.count, 1)
    }

    func testConditionalDynamicAndMixedMutationInputsDoNotBecomeReads() {
        let skill = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let inputs = [
            "if (false) { await tools.exec_command({cmd: 'cat sample-a/SKILL.md'}); }",
            "const fn = () => tools.exec_command({cmd: 'cat sample-a/SKILL.md'});",
            "const obj = { read() { tools.exec_command({cmd: 'cat sample-a/SKILL.md'}); } };",
            "const regex = /tools.exec_command({cmd: 'cat sample-a/SKILL.md'})/;",
            "await tools.exec_command({cmd: 'cat sample-a/SKILL.md' + suffix});",
            "await tools.exec_command({cmd: `cat ${path}/SKILL.md`});",
            "await tools.exec_command({cmd: 'cat sample-a/SKILL.md && cat other/SKILL.md'});",
            "await tools.exec_command({cmd: 'cat sample-a/SKILL.md; rm other.txt'});",
            "await tools.exec_command({cmd: 'cat sample-a/SKILL.md > result.txt'});",
            "await tools.exec_command({cmd: \"sed -n '1e dangerous' sample-a/SKILL.md\"});",
            "await tools.exec_command({cmd: 'cat \"$(echo sample-a)/SKILL.md\"'});"
        ]
        for input in inputs {
            let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [skill])).extract(sessionID: "root", envelopes: [event("response_item", ["type": "custom_tool_call", "id": "read", "call_id": "read", "name": "exec", "input": input])])
            XCTAssertFalse(result.calls.contains { $0.kind == .skill })
        }
    }

    func testExplicitCommandWorkdirResolvesSamePathInCorrectProject() {
        let a = resource("skill:a", "sample", kind: .skill, project: "a", path: ".agents/skills/sample/SKILL.md")
        let b = resource("skill:b", "sample", kind: .skill, project: "b", path: ".agents/skills/sample/SKILL.md")
        let roots = [ScanRoot(id: "a", url: URL(fileURLWithPath: "/fixture/a"), scope: .project, kind: .projects), ScanRoot(id: "b", url: URL(fileURLWithPath: "/fixture/b"), scope: .project, kind: .projects)]
        let input = "{\"cmd\":\"cat .agents/skills/sample/SKILL.md\",\"workdir\":\"/fixture/b\"}"
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [a,b], roots: roots)).extract(sessionID: "root", envelopes: [event("response_item", ["type": "function_call", "id": "read", "call_id": "read", "name": "exec_command", "arguments": input])])
        XCTAssertEqual(result.calls.filter { $0.kind == .skill }.compactMap(\.resourceID), [b.id])
    }

    func testBatchResultDoesNotInventPerOperationSuccess() {
        let a = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let input = "await Promise.all([tools.exec_command({cmd: 'cat sample-a/SKILL.md'}), tools.exec_command({cmd: 'cat unrelated.txt'})]);"
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [a])).extract(sessionID: "root", envelopes: [
            event("response_item", ["type": "custom_tool_call", "id": "batch", "call_id": "batch", "name": "exec", "input": input]),
            event("response_item", ["type": "custom_tool_call_output", "call_id": "batch", "output": "ok"], ordinal: 1)])
        XCTAssertEqual(result.calls.first { $0.kind == .skill }?.status, .unknown)
    }

    func testUnconditionalMultiManifestShellSequenceIsDeduplicatedPerWrapper() {
        let a = resource("skill:a", "sample-a", kind: .skill, path: "sample-a/SKILL.md")
        let b = resource("skill:b", "sample-b", kind: .skill, path: "sample-b/SKILL.md")
        let input = "{\"cmd\":\"cat sample-a/SKILL.md; cat sample-b/SKILL.md; cat sample-a/SKILL.md\"}"
        let result = InvocationExtractor(skillResolver: SkillEvidenceResolver(resources: [a,b])).extract(sessionID: "root", envelopes: [event("response_item", ["type": "function_call", "id": "read", "call_id": "read", "name": "exec_command", "arguments": input])])
        XCTAssertEqual(result.calls.filter { $0.kind == .skill }.count, 2)
    }
}
