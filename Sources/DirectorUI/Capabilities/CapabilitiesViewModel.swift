import SwiftUI
import DirectorCore

/// One row in the Capabilities table: resource plus aggregate usage stats.
public struct CapabilityRow: Identifiable, Equatable {
    public let resource: CapabilityResource
    public let callCount: Int
    public let failureCount: Int
    public let lastUsedAt: Date?
    public let completedCount: Int
    public let unresolvedCount: Int
    public let evidenceLimitedCount: Int
    public let evaluatedCount: Int
    public let effectiveCount: Int
    public let ineffectiveCount: Int
    public let uncertainCount: Int

    public var id: String { resource.id }

    public init(
        resource: CapabilityResource,
        callCount: Int,
        failureCount: Int,
        lastUsedAt: Date?,
        completedCount: Int = 0,
        unresolvedCount: Int = 0,
        evidenceLimitedCount: Int = 0,
        evaluatedCount: Int = 0,
        effectiveCount: Int = 0,
        ineffectiveCount: Int = 0,
        uncertainCount: Int = 0
    ) {
        self.resource = resource
        self.callCount = callCount
        self.failureCount = failureCount
        self.lastUsedAt = lastUsedAt
        self.completedCount = completedCount
        self.unresolvedCount = unresolvedCount
        self.evidenceLimitedCount = evidenceLimitedCount
        self.evaluatedCount = evaluatedCount
        self.effectiveCount = effectiveCount
        self.ineffectiveCount = ineffectiveCount
        self.uncertainCount = uncertainCount
    }

    public var isObserved: Bool { callCount > 0 }
    public var terminalOutcomeCount: Int { completedCount + failureCount }
    public var observedCompletionRate: Double? {
        guard terminalOutcomeCount > 0 else { return nil }
        return Double(completedCount) / Double(terminalOutcomeCount)
    }
    public var evaluationCoverage: Double? {
        guard callCount > 0 else { return nil }
        return Double(evaluatedCount) / Double(callCount)
    }
    public var hasEvidenceLimitedCalls: Bool { evidenceLimitedCount > 0 }
    public var attentionState: CapabilityAttentionState {
        if unresolvedCount > 0 { return .unresolved }
        if failureCount > 0 { return .failures }
        if evidenceLimitedCount > 0 { return .evidenceLimited }
        if isObserved && (resource.kind == .agent || resource.kind == .skill) && evaluatedCount == 0 {
            return .notEvaluated
        }
        return .none
    }
    public var requiresAttention: Bool { attentionState != .none }

    fileprivate func withEvaluationCounts(_ counts: CapabilityEvaluationCounts) -> CapabilityRow {
        CapabilityRow(
            resource: resource,
            callCount: callCount,
            failureCount: failureCount,
            lastUsedAt: lastUsedAt,
            completedCount: completedCount,
            unresolvedCount: unresolvedCount,
            evidenceLimitedCount: evidenceLimitedCount,
            evaluatedCount: counts.evaluated,
            effectiveCount: counts.effective,
            ineffectiveCount: counts.ineffective,
            uncertainCount: counts.uncertain
        )
    }
}

public struct CapabilityEvaluationCounts: Equatable, Sendable {
    public let evaluated: Int
    public let effective: Int
    public let ineffective: Int
    public let uncertain: Int

    public init(evaluated: Int = 0, effective: Int = 0, ineffective: Int = 0, uncertain: Int = 0) {
        self.evaluated = evaluated
        self.effective = effective
        self.ineffective = ineffective
        self.uncertain = uncertain
    }

    func updated(adding label: InvocationEvaluationLabel) -> CapabilityEvaluationCounts {
        var result = self
        switch label {
        case .effective:
            result = CapabilityEvaluationCounts(evaluated: evaluated + 1, effective: effective + 1, ineffective: ineffective, uncertain: uncertain)
        case .ineffective:
            result = CapabilityEvaluationCounts(evaluated: evaluated + 1, effective: effective, ineffective: ineffective + 1, uncertain: uncertain)
        case .uncertain:
            result = CapabilityEvaluationCounts(evaluated: evaluated + 1, effective: effective, ineffective: ineffective, uncertain: uncertain + 1)
        }
        return result
    }

    func updated(removing label: InvocationEvaluationLabel) -> CapabilityEvaluationCounts {
        switch label {
        case .effective:
            return CapabilityEvaluationCounts(evaluated: max(0, evaluated - 1), effective: max(0, effective - 1), ineffective: ineffective, uncertain: uncertain)
        case .ineffective:
            return CapabilityEvaluationCounts(evaluated: max(0, evaluated - 1), effective: effective, ineffective: max(0, ineffective - 1), uncertain: uncertain)
        case .uncertain:
            return CapabilityEvaluationCounts(evaluated: max(0, evaluated - 1), effective: effective, ineffective: ineffective, uncertain: max(0, uncertain - 1))
        }
    }
}

public enum CapabilityAttentionState: String, Codable, Sendable, CaseIterable {
    case none
    case failures
    case unresolved
    case evidenceLimited
    case notEvaluated
}

public enum CapabilityUsageFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case observed
    case notObserved
    case hasFailures
    case evidenceLimited
    case notEvaluated

    public var id: String { rawValue }
}

public enum ResourceInventoryCategory: String, CaseIterable, Identifiable {
    case all = "All Capabilities"
    case myAgents = "My Agents"
    case mySkills = "My Skills"
    case installedSkills = "Installed Skills"
    case instructions = "Project Instructions"
    case plugins = "Plugin Capabilities"
    case builtIn = "Built-in"

    public var id: String { rawValue }
}

/// Main-actor view state for the Capabilities destination: rows, filters,
/// selection, and one-hop relationships.
@MainActor
public final class CapabilitiesViewModel: ObservableObject {
    @Published public var searchText = ""
    @Published public var kindFilter: ResourceKind?
    @Published public var scopeFilter: ResourceScope?
    @Published public var allowedKinds: Set<ResourceKind>?
    @Published public var allowedScopes: Set<ResourceScope>?
    @Published public var ownershipFilter: ResourceOwnership?
    @Published public var hideBuiltinWhenFiltered = false
    @Published public var categoryFilter: ResourceInventoryCategory = .all
    @Published public var projectFilter: String?
    @Published public var showBuiltIn = false
    @Published public var showAdvancedPluginCapabilities = false
    @Published public var selectedResourceID: String?
    @Published public var usageFilter: CapabilityUsageFilter = .all

    @Published public private(set) var allRows: [CapabilityRow]
    @Published public private(set) var relations: [ResourceRelation]
    @Published public private(set) var projects: [CapabilityProject]
    @Published public private(set) var provenance: [CapabilityProvenance]

    // Keep the discovered classification separate from a user's local
    // correction. Reindexing replaces rows, but must not turn a correction
    // into the new baseline or reset it to an invented user-owned/local row.
    private var classificationBaselines: [String: CapabilityResource] = [:]
    private var overriddenClassificationIDs = Set<String>()

    public init(
        resources: [CapabilityResource],
        stats: [DatabaseStore.ResourceUsageStats] = [],
        relations: [ResourceRelation] = [],
        projects: [CapabilityProject] = [],
        provenance: [CapabilityProvenance] = []
    ) {
        self.allRows = Self.makeRows(resources: resources, stats: stats, evaluationCounts: [:])
        self.relations = relations
        self.projects = projects
        self.provenance = provenance
        self.classificationBaselines = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
    }

    /// Replaces the derived projection in place. Filters are intentionally
    /// untouched; a selected resource is retained only while its stable ID is
    /// present in the replacement inventory.
    public func replaceData(
        resources: [CapabilityResource],
        stats: [DatabaseStore.ResourceUsageStats] = [],
        relations: [ResourceRelation] = [],
        projects: [CapabilityProject] = [],
        provenance: [CapabilityProvenance] = [],
        evaluationCounts: [String: CapabilityEvaluationCounts] = [:]
    ) {
        let selectedID = selectedResourceID
        let incomingIDs = Set(resources.map(\.id))
        for resource in resources where !overriddenClassificationIDs.contains(resource.id) {
            classificationBaselines[resource.id] = resource
        }
        classificationBaselines = classificationBaselines.filter { incomingIDs.contains($0.key) }
        allRows = Self.makeRows(resources: resources, stats: stats, evaluationCounts: evaluationCounts)
        self.relations = relations
        self.projects = projects
        self.provenance = provenance
        if let selectedID, allRows.contains(where: { $0.id == selectedID }) {
            selectedResourceID = selectedID
        } else {
            selectedResourceID = nil
        }
    }

    public func setEvaluation(_ evaluation: InvocationEvaluation) {
        guard let resourceID = evaluation.resourceID else { return }
        allRows = allRows.map { row in
            guard row.resource.id == resourceID else { return row }
            let counts = counts(for: row)
            let updated = counts.updated(adding: evaluation.label)
            return row.withEvaluationCounts(updated)
        }
    }

    public func clearEvaluation(_ evaluation: InvocationEvaluation) {
        guard let resourceID = evaluation.resourceID else { return }
        allRows = allRows.map { row in
            guard row.resource.id == resourceID else { return row }
            let counts = counts(for: row)
            let updated = counts.updated(removing: evaluation.label)
            return row.withEvaluationCounts(updated)
        }
    }

    private static func makeRows(
        resources: [CapabilityResource],
        stats: [DatabaseStore.ResourceUsageStats],
        evaluationCounts: [String: CapabilityEvaluationCounts]
    ) -> [CapabilityRow] {
        let statsByID = Dictionary(uniqueKeysWithValues: stats.map { ($0.resourceID, $0) })
        return resources.map { resource in
            let stat = statsByID[resource.id]
            let evaluations = evaluationCounts[resource.id] ?? .init()
            return CapabilityRow(
                resource: resource,
                callCount: stat?.callCount ?? 0,
                failureCount: stat?.failureCount ?? 0,
                lastUsedAt: stat?.lastUsedAt,
                completedCount: stat?.completedCount ?? 0,
                unresolvedCount: stat?.unresolvedCount ?? 0,
                evidenceLimitedCount: stat?.evidenceLimitedCount ?? 0,
                evaluatedCount: evaluations.evaluated,
                effectiveCount: evaluations.effective,
                ineffectiveCount: evaluations.ineffective,
                uncertainCount: evaluations.uncertain
            )
        }
    }

    private func counts(for row: CapabilityRow) -> CapabilityEvaluationCounts {
        CapabilityEvaluationCounts(
            evaluated: row.evaluatedCount,
            effective: row.effectiveCount,
            ineffective: row.ineffectiveCount,
            uncertain: row.uncertainCount
        )
    }

    /// Rows after search, kind, and scope filtering. Selection is preserved
    /// independently of filtering.
    public var filteredRows: [CapabilityRow] {
        allRows.filter { row in
            matchesSearch(row) && matchesCategory(row) && matchesKind(row) && matchesScope(row) && matchesUsage(row)
        }
    }

    public var selectedRow: CapabilityRow? {
        guard let selectedResourceID else { return nil }
        return allRows.first { $0.id == selectedResourceID }
    }

    /// Closes the selection-driven inspector without changing filters or the
    /// current table position.
    public func dismissInspector() {
        selectedResourceID = nil
    }

    /// Clears a stale inspector selection after a filter transition hides its
    /// row. The table remains the source of truth for visible selection.
    public func clearSelectionIfFilteredOut() {
        guard let selectedResourceID,
              !filteredRows.contains(where: { $0.id == selectedResourceID }) else { return }
        self.selectedResourceID = nil
    }

    public func applyUserOwnedFilter(
        kind: ResourceKind? = nil,
        scope: ResourceScope? = nil,
        allowedKinds: Set<ResourceKind>? = nil,
        allowedScopes: Set<ResourceScope>? = nil,
        ownership: ResourceOwnership? = nil,
        hideBuiltin: Bool = false,
        category: ResourceInventoryCategory = .all,
        projectID: String? = nil,
        showBuiltIn: Bool = false
    ) {
        kindFilter = kind
        scopeFilter = scope
        self.allowedKinds = allowedKinds
        self.allowedScopes = allowedScopes
        ownershipFilter = ownership
        hideBuiltinWhenFiltered = hideBuiltin
        categoryFilter = category
        projectFilter = projectID
        self.showBuiltIn = showBuiltIn
        searchText = ""
        usageFilter = .all
        clearSelectionIfFilteredOut()
    }

    public func applyCategory(_ category: ResourceInventoryCategory) {
        categoryFilter = category
        kindFilter = nil
        scopeFilter = nil
        allowedKinds = nil
        allowedScopes = nil
        ownershipFilter = nil
        hideBuiltinWhenFiltered = false
        showBuiltIn = category == .builtIn
        searchText = ""
        usageFilter = .all
        clearSelectionIfFilteredOut()
    }

    public func relations(for resourceID: String) -> [ResourceRelation] {
        relations.filter { $0.sourceResourceID == resourceID || $0.targetResourceID == resourceID }
    }

    public func applyClassification(_ ownership: ResourceOwnership, for resourceID: String, origin: ResourceOrigin? = nil) {
        allRows = allRows.map { row in
            guard row.resource.id == resourceID else { return row }
            if !overriddenClassificationIDs.contains(resourceID) {
                classificationBaselines[resourceID] = row.resource
            }
            overriddenClassificationIDs.insert(resourceID)
            let resource = row.resource
            let correctedOrigin = origin ?? resource.manualClassificationOrigin(for: ownership)
            let preservesInstalledSource = ownership == .installed && correctedOrigin == resource.origin
            let updated = CapabilityResource(
                id: resource.id, name: resource.name, kind: resource.kind, status: resource.status,
                scope: resource.scope, projectID: resource.projectID, confidence: resource.confidence,
                summary: resource.summary, sourceRootID: resource.sourceRootID,
                relativeSourcePath: resource.relativeSourcePath, sourcePathHash: resource.sourcePathHash,
                lastSeenAt: resource.lastSeenAt, ownership: ownership,
                origin: correctedOrigin, classificationConfidence: .exact,
                originIdentifier: preservesInstalledSource ? resource.originIdentifier : nil,
                sourceVersion: preservesInstalledSource ? resource.sourceVersion : nil,
                contentFingerprint: resource.contentFingerprint,
                sourceModifiedAt: resource.sourceModifiedAt,
                modified: resource.modified
            )
            return CapabilityRow(resource: updated, callCount: row.callCount, failureCount: row.failureCount, lastUsedAt: row.lastUsedAt, completedCount: row.completedCount, unresolvedCount: row.unresolvedCount, evidenceLimitedCount: row.evidenceLimitedCount, evaluatedCount: row.evaluatedCount, effectiveCount: row.effectiveCount, ineffectiveCount: row.ineffectiveCount, uncertainCount: row.uncertainCount)
        }
    }

    /// Supplies the automatic discovery baseline when the persisted derived
    /// row already contains a user correction. Provenance remains unmodified
    /// by corrections, so reset can still restore the current source rule
    /// after an application restart.
    public func setClassificationBaseline(_ resource: CapabilityResource) {
        classificationBaselines[resource.id] = resource
    }

    public func resetClassification(for resourceID: String) {
        guard let baseline = classificationBaselines[resourceID] else { return }
        overriddenClassificationIDs.remove(resourceID)
        allRows = allRows.map { row in
            guard row.resource.id == resourceID else { return row }
            return CapabilityRow(resource: baseline, callCount: row.callCount, failureCount: row.failureCount, lastUsedAt: row.lastUsedAt, completedCount: row.completedCount, unresolvedCount: row.unresolvedCount, evidenceLimitedCount: row.evidenceLimitedCount, evaluatedCount: row.evaluatedCount, effectiveCount: row.effectiveCount, ineffectiveCount: row.ineffectiveCount, uncertainCount: row.uncertainCount)
        }
    }

    /// Clears all local corrections while restoring each resource's original
    /// discovered ownership/origin metadata and retaining usage aggregates.
    public func resetAllClassifications() {
        let baselines = classificationBaselines
        allRows = allRows.map { row in
            guard overriddenClassificationIDs.contains(row.id), let baseline = baselines[row.id] else { return row }
            return CapabilityRow(resource: baseline, callCount: row.callCount, failureCount: row.failureCount, lastUsedAt: row.lastUsedAt, completedCount: row.completedCount, unresolvedCount: row.unresolvedCount, evidenceLimitedCount: row.evidenceLimitedCount, evaluatedCount: row.evaluatedCount, effectiveCount: row.effectiveCount, ineffectiveCount: row.ineffectiveCount, uncertainCount: row.uncertainCount)
        }
        overriddenClassificationIDs.removeAll()
    }

    public var availableKinds: [ResourceKind] {
        ResourceKind.allCases.filter { kind in allRows.contains { $0.resource.kind == kind } }
    }

    public var availableScopes: [ResourceScope] {
        ResourceScope.allCases.filter { scope in allRows.contains { $0.resource.scope == scope } }
    }

    public var availableProjects: [CapabilityProject] { projects.filter { project in allRows.contains { $0.resource.projectID == project.id } } }

    private func matchesCategory(_ row: CapabilityRow) -> Bool {
        let resource = row.resource
        switch categoryFilter {
        case .all: return true
        case .myAgents: return resource.kind == .agent && resource.ownership == .userOwned
        case .mySkills: return resource.kind == .skill && resource.ownership == .userOwned
        case .installedSkills: return resource.kind == .skill && resource.ownership == .installed
        case .instructions: return resource.kind == .instruction
        case .plugins:
            return (resource.scope == .runtime || resource.scope == .plugin)
                && resource.ownership == .pluginProvided
                && (showAdvancedPluginCapabilities || resource.sourceRootID != "plugin-cache")
                && (showAdvancedPluginCapabilities || resource.status != .blocked)
        case .builtIn: return resource.ownership == .builtIn
        }
    }

    private func matchesSearch(_ row: CapabilityRow) -> Bool {
        guard !searchText.isEmpty else { return true }
        let values = [
            row.resource.name, row.resource.kind.rawValue, row.resource.scope.rawValue,
            row.resource.summary ?? "", row.resource.sourceRootID, row.resource.origin.rawValue,
            row.resource.ownership.rawValue, row.resource.projectID ?? "",
        ]
        let haystack = LocalizedSearch.haystack(values)
        return haystack.contains(searchText.lowercased())
    }

    private func matchesKind(_ row: CapabilityRow) -> Bool {
        if let allowedKinds {
            return allowedKinds.contains(row.resource.kind)
        }
        return kindFilter == nil || row.resource.kind == kindFilter
    }

    private func matchesScope(_ row: CapabilityRow) -> Bool {
        guard ownershipFilter == nil || row.resource.ownership == ownershipFilter else { return false }
        let revealBuiltIn = showBuiltIn || categoryFilter == .builtIn
        let hiddenPluginCache = !showAdvancedPluginCapabilities && categoryFilter == .all && row.resource.sourceRootID == "plugin-cache"
        let hiddenDisabledPlugin = !showAdvancedPluginCapabilities && categoryFilter == .all && row.resource.scope == .runtime && row.resource.kind == .plugin && row.resource.status == .blocked
        if hiddenPluginCache || hiddenDisabledPlugin { return false }
        if let allowedScopes {
            guard allowedScopes.contains(row.resource.scope) else {
                return false
            }
            return (!hideBuiltinWhenFiltered || revealBuiltIn || !Self.isBuiltinCodexAsset(row.resource)) && (projectFilter == nil || row.resource.projectID == projectFilter)
        }
        guard let scopeFilter else {
            return (revealBuiltIn || row.resource.scope != .system) && (revealBuiltIn || !Self.isBuiltinCodexAsset(row.resource)) && (projectFilter == nil || row.resource.projectID == projectFilter)
        }
        return row.resource.scope == scopeFilter && (!hideBuiltinWhenFiltered || revealBuiltIn || !Self.isBuiltinCodexAsset(row.resource)) && (projectFilter == nil || row.resource.projectID == projectFilter)
    }

    private func matchesUsage(_ row: CapabilityRow) -> Bool {
        switch usageFilter {
        case .all: return true
        case .observed: return row.isObserved
        case .notObserved: return !row.isObserved
        case .hasFailures: return row.failureCount > 0
        case .evidenceLimited: return row.hasEvidenceLimitedCalls
        case .notEvaluated:
            return row.isObserved && (row.resource.kind == .agent || row.resource.kind == .skill) && row.evaluatedCount == 0
        }
    }

    public static func isBuiltinCodexAsset(_ resource: CapabilityResource) -> Bool {
        guard resource.kind == .agent || resource.kind == .skill else { return resource.ownership == .builtIn }
        if resource.ownership == .builtIn { return true }
        guard let relativeSourcePath = resource.relativeSourcePath else {
            return false
        }
        return relativeSourcePath.hasPrefix(".system/")
            || relativeSourcePath == ".system"
    }
}
