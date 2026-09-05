import Foundation
import DirectorCore

/// Aggregated KPIs for the Home dashboard.
@MainActor
public final class HomeDashboardViewModel: ObservableObject {
    public let allRows: [CapabilityRow]
    public let projects: [CapabilityProject]

    public init(rows: [CapabilityRow], projects: [CapabilityProject] = []) {
        self.allRows = rows
        self.projects = projects
    }

    public var myAgentCount: Int { count(kind: .agent, ownership: .userOwned) }
    public var myGlobalAgentCount: Int { count(kind: .agent, ownership: .userOwned, scope: .global) }
    public var myProjectAgentCount: Int { count(kind: .agent, ownership: .userOwned, scope: .project) }
    public var mySkillCount: Int { count(kind: .skill, ownership: .userOwned) }
    public var myGlobalSkillCount: Int { count(kind: .skill, ownership: .userOwned, scope: .global) }
    public var myProjectSkillCount: Int { count(kind: .skill, ownership: .userOwned, scope: .project) }
    public var installedSkillCount: Int { count(kind: .skill, ownership: .installed) }
    public var installedGitHubSkillCount: Int { allRows.filter { $0.resource.kind == .skill && $0.resource.ownership == .installed && $0.resource.origin == .github }.count }
    public var installedRegistrySkillCount: Int { allRows.filter { $0.resource.kind == .skill && $0.resource.ownership == .installed && $0.resource.origin == .registry }.count }
    public var mySkillConfidenceSummary: String { confidenceSummary(for: .skill, ownership: .userOwned) }
    public var installedSkillConfidenceSummary: String { confidenceSummary(for: .skill, ownership: .installed) }
    public var mySkillExactCount: Int { confidenceCount(for: .skill, ownership: .userOwned, confidence: .exact) }
    public var mySkillInferredCount: Int { confidenceCount(for: .skill, ownership: .userOwned, confidence: .inferred) }
    public var installedSkillExactCount: Int { confidenceCount(for: .skill, ownership: .installed, confidence: .exact) }
    public var installedSkillInferredCount: Int { confidenceCount(for: .skill, ownership: .installed, confidence: .inferred) }
    public var projectInstructionCount: Int { allRows.filter { $0.resource.kind == .instruction && $0.resource.scope == .project }.count }
    public var projectInstructionProjectCount: Int { Set(allRows.filter { $0.resource.kind == .instruction && $0.resource.scope == .project }.compactMap { $0.resource.projectID }).count }
    public var pluginCount: Int { allRows.filter { $0.resource.kind == .plugin && $0.resource.scope == .runtime && $0.resource.sourceRootID == "runtime-plugins" && $0.resource.status != .blocked }.count }
    public var pluginCapabilityCount: Int { allRows.filter { ($0.resource.scope == .runtime || $0.resource.scope == .plugin) && $0.resource.ownership == .pluginProvided && $0.resource.sourceRootID == "runtime-plugins" && $0.resource.status != .blocked }.count }

    private var currentCapabilities: [CapabilityRow] {
        allRows.filter {
            ($0.resource.kind == .agent || $0.resource.kind == .skill)
                && $0.resource.ownership == .userOwned
                && !CapabilitiesViewModel.isBuiltinCodexAsset($0.resource)
        }
    }

    public var observedCapabilityCount: Int { currentCapabilities.filter(\.isObserved).count }
    public var notObservedCapabilityCount: Int { currentCapabilities.filter { !$0.isObserved }.count }
    public var evidenceLimitedCallCount: Int { currentCapabilities.reduce(0) { $0 + $1.evidenceLimitedCount } }
    public var evaluatedInvocationCount: Int { currentCapabilities.reduce(0) { $0 + $1.evaluatedCount } }
    public var ineffectiveInvocationCount: Int { currentCapabilities.reduce(0) { $0 + $1.ineffectiveCount } }

    public var projectBreakdown: [ProjectInventorySummary] {
        let projectIDs = Set(projects.map(\.id)).union(allRows.compactMap { $0.resource.projectID })
        return projectIDs.compactMap { id in
            let name = projects.first(where: { $0.id == id })?.name ?? id
            let rows = allRows.filter { $0.resource.projectID == id }
            return ProjectInventorySummary(
                id: id,
                name: name,
                myAgents: rows.filter { $0.resource.kind == .agent && $0.resource.ownership == .userOwned }.count,
                mySkills: rows.filter { $0.resource.kind == .skill && $0.resource.ownership == .userOwned }.count,
                installedSkills: rows.filter { $0.resource.kind == .skill && $0.resource.ownership == .installed }.count,
                instructions: rows.filter { $0.resource.kind == .instruction }.count,
                available: projects.first(where: { $0.id == id })?.available ?? true
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var globalAgentCount: Int {
        myGlobalAgentCount
    }

    public var projectAgentCount: Int {
        myProjectAgentCount
    }

    public var globalSkillCount: Int {
        myGlobalSkillCount
    }

    public var projectSkillCount: Int {
        myProjectSkillCount
    }

    public var installedToolCount: Int {
        let allowedKinds: Set<ResourceKind> = [.plugin, .mcp, .tool, .app, .hook]
        let allowedScopes: Set<ResourceScope> = [.runtime, .plugin]
        let filtered = allRows.filter { row in
            let resource = row.resource
            guard allowedKinds.contains(resource.kind) else { return false }
            guard allowedScopes.contains(resource.scope) else { return false }

            if resource.scope == .runtime,
               resource.kind == .app,
               resource.name.lowercased() == "codex-cli" {
                return false
            }
            return true
        }
        return Set(filtered.map { $0.resource.id }).count
    }

    private func resourceRows(kind: ResourceKind, scope: ResourceScope) -> [CapabilityRow] {
        allRows.filter { $0.resource.kind == kind && $0.resource.scope == scope }
    }

    private func count(kind: ResourceKind, ownership: ResourceOwnership, scope: ResourceScope? = nil) -> Int {
        allRows.filter { row in
            row.resource.kind == kind && row.resource.ownership == ownership
                && !CapabilitiesViewModel.isBuiltinCodexAsset(row.resource)
                && (scope == nil || row.resource.scope == scope)
        }.count
    }

    private func confidenceSummary(for kind: ResourceKind, ownership: ResourceOwnership) -> String {
        let rows = allRows.filter { $0.resource.kind == kind && $0.resource.ownership == ownership && !CapabilitiesViewModel.isBuiltinCodexAsset($0.resource) }
        let exact = rows.filter { $0.resource.classificationConfidence == .exact }.count
        let inferred = rows.filter { $0.resource.classificationConfidence == .inferred }.count
        return "exact \(exact) · inferred \(inferred)"
    }

    private func confidenceCount(for kind: ResourceKind, ownership: ResourceOwnership, confidence: EvidenceConfidence) -> Int {
        allRows.filter {
            $0.resource.kind == kind
                && $0.resource.ownership == ownership
                && !CapabilitiesViewModel.isBuiltinCodexAsset($0.resource)
                && $0.resource.classificationConfidence == confidence
        }.count
    }
}

public struct ProjectInventorySummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let myAgents: Int
    public let mySkills: Int
    public let installedSkills: Int
    public let instructions: Int
    public let available: Bool
}
