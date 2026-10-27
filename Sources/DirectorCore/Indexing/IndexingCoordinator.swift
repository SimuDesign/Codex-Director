import Foundation

/// Result of one indexing run.
public struct IndexingResult: Sendable, Equatable {
    public let processedFiles: Int
    public let skippedFiles: Int
    public let indexedSessions: Int
    public let resources: Int
    public let cancelled: Bool
    public let runtimeCoverage: CoverageState
    public let runtimeIssueCount: Int
    public let discoveryIssueCount: Int
    /// Completeness of the user-owned capability source scopes. This is
    /// intentionally separate from session/runtime coverage.
    public let resourceCoverage: CapabilityHistoryCoverage
    /// Nil means no runtime query was attempted. False is not an observed
    /// empty plugin list and must never be presented as one.
    public let runtimePluginInventoryAvailable: Bool?
    public let runtimePluginPackagesAvailable: Bool?
    /// Independent history-domain result. Nil means no history service was
    /// configured; a failed history write is represented by its status and
    /// never turns a successful inventory commit into an indexing failure.
    public let capabilityHistoryStatus: CapabilityHistoryStatus?

    public init(
        processedFiles: Int,
        skippedFiles: Int,
        indexedSessions: Int,
        resources: Int,
        cancelled: Bool,
        runtimeCoverage: CoverageState = .unknown,
        runtimeIssueCount: Int = 0,
        discoveryIssueCount: Int = 0,
        resourceCoverage: CapabilityHistoryCoverage = .complete,
        runtimePluginInventoryAvailable: Bool? = nil,
        runtimePluginPackagesAvailable: Bool? = nil,
        capabilityHistoryStatus: CapabilityHistoryStatus? = nil
    ) {
        self.processedFiles = processedFiles
        self.skippedFiles = skippedFiles
        self.indexedSessions = indexedSessions
        self.resources = resources
        self.cancelled = cancelled
        self.runtimeCoverage = runtimeCoverage
        self.runtimeIssueCount = runtimeIssueCount
        self.discoveryIssueCount = discoveryIssueCount
        self.resourceCoverage = resourceCoverage
        self.runtimePluginInventoryAvailable = runtimePluginInventoryAvailable
        self.runtimePluginPackagesAvailable = runtimePluginPackagesAvailable
        self.capabilityHistoryStatus = capabilityHistoryStatus
    }
}

/// Coordinates resource scan, incremental session parsing, normalization,
/// database commits, and checkpoints for one indexing run.
///
/// - Reindexes only changed files (size+mtime based).
/// - Resumes appended files from their committed byte offset.
/// - Restarts truncated/replaced files from offset zero.
/// - Active-to-archived moves are handled by the idempotent session replace;
///   no session is duplicated.
/// - Progress is published via a callback; cancellation is cooperative and
///   never corrupts a committed checkpoint.
public actor IndexingCoordinator {

    public struct Configuration: Sendable {
        public let scanRoots: [ScanRoot]
        public let activeSessionRoots: [URL]
        public let archivedSessionRoot: URL?
        public let classificationOverrides: [String: ResourceClassificationOverride]
        public let skillOwnershipRegistryURL: URL?

        public init(
            scanRoots: [ScanRoot],
            activeSessionRoots: [URL],
            archivedSessionRoot: URL?,
            classificationOverrides: [String: ResourceClassificationOverride] = [:],
            skillOwnershipRegistryURL: URL? = nil
        ) {
            self.scanRoots = scanRoots
            self.activeSessionRoots = activeSessionRoots
            self.archivedSessionRoot = archivedSessionRoot
            self.classificationOverrides = classificationOverrides
            self.skillOwnershipRegistryURL = skillOwnershipRegistryURL
        }
    }

    private let store: DatabaseStore
    private let fileSystem: FileSystemClient
    private let decoder = RolloutEventDecoder()
    private var extractor = InvocationExtractor()
    private let tokenParser = TokenUsageParser()
    private let runtimeDiscovery: CodexRuntimeDiscovery?
    /// Injectable clock so Review Lite stale-quota tests are deterministic.
    private let nowProvider: @Sendable () -> Date
    private let sourceObserver: (@Sendable (SourceIndexPhase) -> Void)?
    private let projectReadGate: ProjectSourceReadGate
    public nonisolated let capabilityHistoryService: CapabilityHistoryCoordinator?

    public init(
        store: DatabaseStore,
        fileSystem: FileSystemClient = FileSystemClient(),
        runtimeDiscovery: CodexRuntimeDiscovery? = nil,
        capabilityHistoryService: CapabilityHistoryCoordinator? = nil,
        projectReadGate: ProjectSourceReadGate = ProjectSourceReadGate(),
        now: @escaping @Sendable () -> Date = { Date() },
        sourceObserver: (@Sendable (SourceIndexPhase) -> Void)? = nil
    ) {
        self.store = store
        self.fileSystem = fileSystem
        self.runtimeDiscovery = runtimeDiscovery
        self.capabilityHistoryService = capabilityHistoryService
        self.projectReadGate = projectReadGate
        self.nowProvider = now
        self.sourceObserver = sourceObserver
    }

    public func run(
        configuration: Configuration,
        progress: @escaping @Sendable (IndexingProgress) -> Void = { _ in }
    ) async throws -> IndexingResult {
        try await run(
            configuration: configuration,
            onCapabilityHistoryStatus: nil,
            progress: progress
        )
    }

    /// Both callbacks are explicit so an existing single trailing progress
    /// closure cannot be rebound to the history callback by Swift matching.
    public func run(
        configuration: Configuration,
        onCapabilityHistoryStatus: (@Sendable (CapabilityHistoryStatus) async -> Void)?,
        progress: @escaping @Sendable (IndexingProgress) -> Void
    ) async throws -> IndexingResult {
        sourceObserver?(.started)
        do {
            let result = try await runImplementation(
                configuration: configuration,
                onCapabilityHistoryStatus: onCapabilityHistoryStatus,
                progress: progress
            )
            sourceObserver?(result.cancelled ? .cancelled : .completed)
            return result
        } catch is CancellationError {
            sourceObserver?(.cancelled)
            throw CancellationError()
        } catch {
            sourceObserver?(.failed)
            throw error
        }
    }

    private func runImplementation(
        configuration: Configuration,
        onCapabilityHistoryStatus: (@Sendable (CapabilityHistoryStatus) async -> Void)?,
        progress: @escaping @Sendable (IndexingProgress) -> Void
    ) async throws -> IndexingResult {
        progress(.init(phase: .scanning, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: nil))
        try Task.checkCancellation()

        // 1. Resource discovery: filesystem + current System/Runtime sources.
        let previousResources = try await store.fetchAllResources()
        let previousProjects = try await store.fetchAllProjects()
        let previousProvenance = try await store.fetchAllProvenance()
        let previousRelations = try await store.fetchAllRelations()
        let previousFingerprints = Dictionary(
            uniqueKeysWithValues: previousResources.compactMap { resource in
                resource.contentFingerprint.map { (resource.id, $0) }
            }
        )
        let previousModified = Dictionary(uniqueKeysWithValues: previousResources.map { ($0.id, $0.modified) })
        let registry = SkillOwnershipRegistryReader(fileSystem: fileSystem).read(
            from: configuration.skillOwnershipRegistryURL,
            globalSkillRoots: configuration.scanRoots
        )
        let isolatedDiscovery = try await ResourceScanner(
            roots: configuration.scanRoots,
            fileSystem: fileSystem,
            overrides: configuration.classificationOverrides,
            userOwnedSkillRegistrations: registry.registrations,
            previousFingerprints: previousFingerprints,
            previousModified: previousModified,
            projectReadGate: projectReadGate
        ).scanIsolatingProjectSources()
        try Task.checkCancellation()
        let discovery = isolatedDiscovery.output
        var combinedResources = discovery.resources
        var combinedProvenance = discovery.provenance
        var combinedProjects = discovery.projects
        var combinedRelations = discovery.relations
        var companionIssueCount = 0
        var transientRoots: [String: URL] = [:]
        var runtimeIssues: [DiscoveryIssue] = []
        var runtimeCoverage: CoverageState = .unknown
        var runtimePluginInventoryAvailable: Bool?
        var runtimePluginPackagesAvailable: Bool?
        var runtimeAliasCanonicalizationDeferred = false
        if let runtimeDiscovery {
            let runtime = await runtimeDiscovery.discover()
            try Task.checkCancellation()
            runtimePluginInventoryAvailable = !runtime.unsupportedCategories.contains("plugin")
            runtimePluginPackagesAvailable = runtime.pluginPackagesAvailable
            let runtimeSkillIDs = Dictionary(grouping: runtime.resources.filter { $0.kind == .skill }.compactMap { resource -> (String, String)? in
                guard let root = runtime.transientRoots[resource.sourceRootID], let relative = resource.relativeSourcePath else { return nil }
                let marker = resource.sourceRootID.replacingOccurrences(of: "runtime-plugins:", with: "")
                let prefix = "plugins/\(marker)/"
                let child = relative.hasPrefix(prefix) ? String(relative.dropFirst(prefix.count)) : relative
                return (root.appendingPathComponent(child).resolvingSymlinksInPath().standardizedFileURL.path, resource.id)
            }, by: { $0.0 })
            let projectScopesByRootID = Dictionary(
                uniqueKeysWithValues: discovery.historyScanBatch.scopes
                    .filter { $0.rootKind == .projects }
                    .map { ($0.rootID, $0.coverage) }
            )
            let canCanonicalizeRuntimeAliases = configuration.scanRoots
                .filter { $0.kind == .projects }
                .allSatisfy {
                    projectScopesByRootID[$0.id] == .complete
                        && !isolatedDiscovery.unavailableProjectRootIDs.contains($0.id)
                }
            var runtimeCanonicalMap: [String: String] = [:]
            if canCanonicalizeRuntimeAliases {
                let nonProjectPhysicalPaths = combinedResources.filter { $0.kind == .skill }.compactMap { resource -> ProjectSkillPhysicalPath? in
                    guard let root = configuration.scanRoots.first(where: {
                        $0.id == resource.sourceRootID && $0.kind != .projects
                    }), let relative = resource.relativeSourcePath else { return nil }
                    return ProjectSkillPhysicalPath(
                        physicalPath: root.url.appendingPathComponent(relative)
                            .resolvingSymlinksInPath().standardizedFileURL.path,
                        resourceID: resource.id
                    )
                }
                let canonicalByPhysical = Dictionary(
                    grouping: nonProjectPhysicalPaths + isolatedDiscovery.projectSkillPhysicalPaths,
                    by: \ProjectSkillPhysicalPath.physicalPath
                ).compactMapValues { values -> String? in
                    let ids = Set(values.map(\.resourceID))
                    return ids.count == 1 ? ids.first : nil
                }
                for (physical, values) in runtimeSkillIDs {
                    let ids = Set(values.map(\.1))
                    if ids.count == 1, let runtimeID = ids.first, let canonicalID = canonicalByPhysical[physical] {
                        runtimeCanonicalMap[runtimeID] = canonicalID
                    }
                }
            } else {
                // Project/global physical uniqueness is open while any
                // configured project is incomplete. A current plugin package
                // can still prove its own native/runtime alias through exact
                // contains relations and one validated package directory.
                runtimeCanonicalMap = Self.pluginPackageRuntimeAliasMap(
                    runtime: runtime,
                    discovery: discovery,
                    scanRoots: configuration.scanRoots,
                    pluginInventoryAvailable: runtimePluginInventoryAvailable == true,
                    pluginPackagesAvailable: runtimePluginPackagesAvailable == true
                )
                runtimeAliasCanonicalizationDeferred = true
            }
            let duplicateRuntimeIDs = Set(runtimeCanonicalMap.keys)
            combinedResources.append(contentsOf: runtime.resources.filter { !duplicateRuntimeIDs.contains($0.id) })
            let remappedRelations = runtime.relations.compactMap { relation -> ResourceRelation? in
                guard let target = runtimeCanonicalMap[relation.targetResourceID] else { return relation }
                return ResourceRelation(sourceResourceID: relation.sourceResourceID, targetResourceID: target, relationKind: relation.relationKind, confidence: relation.confidence, evidenceSummary: relation.evidenceSummary)
            }
            combinedRelations.append(contentsOf: remappedRelations)
            transientRoots = runtime.transientRoots
            runtimeIssues = runtime.issues
            if runtimeAliasCanonicalizationDeferred {
                runtimeIssues.append(DiscoveryIssue(
                    rootID: "runtime",
                    relativePath: "skill-alias",
                    message: "Runtime Skill alias de-duplication deferred because project source identity is unavailable"
                ))
            }
            runtimeCoverage = runtime.coverage
            if runtime.coverage == .unavailable || runtimePluginInventoryAvailable == false {
                // A successful version/MCP read must not prune the last-known
                // plugin inventory when plugin enumeration alone fails. Keep
                // its children and relations, but mark every retained item as
                // unverified so it cannot be used as current attribution.
                let previousRelations = try await store.fetchAllRelations()
                let previous: [CapabilityResource]
                if runtime.coverage == .unavailable {
                    previous = previousResources.filter { $0.scope == .runtime }
                } else {
                    let pluginIDs = Set(previousResources.filter {
                        $0.scope == .runtime && $0.kind == .plugin && ($0.origin == .runtime || $0.origin == .plugin)
                    }.map(\.id))
                    var retainedIDs = pluginIDs
                    var pending = Array(pluginIDs)
                    while let parent = pending.popLast() {
                        for relation in previousRelations where relation.sourceResourceID == parent && relation.relationKind == "contains" {
                            if retainedIDs.insert(relation.targetResourceID).inserted {
                                pending.append(relation.targetResourceID)
                            }
                        }
                    }
                    previous = previousResources.filter { retainedIDs.contains($0.id) && $0.scope == .runtime }
                }
                let currentIDs = Set(combinedResources.map(\.id))
                let retained = previous.filter { !currentIDs.contains($0.id) }
                let retainedIDs = Set(retained.map(\.id))
                combinedResources.append(contentsOf: retained.map { resource in
                    CapabilityResource(
                        id: resource.id, name: resource.name, kind: resource.kind, status: .warning,
                        scope: resource.scope, projectID: resource.projectID, confidence: resource.confidence,
                        summary: resource.summary, sourceRootID: "last-known-runtime",
                        relativeSourcePath: resource.relativeSourcePath, sourcePathHash: resource.sourcePathHash,
                        lastSeenAt: resource.lastSeenAt, ownership: resource.ownership,
                        origin: resource.origin, classificationConfidence: resource.classificationConfidence,
                        originIdentifier: resource.originIdentifier, sourceVersion: resource.sourceVersion,
                        contentFingerprint: resource.contentFingerprint,
                        modified: resource.modified
                    )
                })
                let allIDs = Set(combinedResources.map(\.id))
                combinedProvenance.append(contentsOf: try await store.fetchAllProvenance().filter { retainedIDs.contains($0.resourceID) })
                combinedRelations.append(contentsOf: previousRelations.filter {
                    (retainedIDs.contains($0.sourceResourceID) || retainedIDs.contains($0.targetResourceID)) &&
                    allIDs.contains($0.sourceResourceID) && allIDs.contains($0.targetResourceID)
                })
            } else if runtimePluginPackagesAvailable == false {
                // Identity is current, but a remote plugin can have no
                // validated local package path. Preserve only its previously
                // observed children as warnings; never retain plugins that
                // have actually disappeared from the installed inventory.
                let unscannedPluginIDs = Set(runtime.resources.filter { resource in
                    guard resource.kind == .plugin,
                          let relative = resource.relativeSourcePath,
                          relative.hasPrefix("plugins/") else { return false }
                    let marker = String(relative.dropFirst("plugins/".count))
                    return runtime.transientRoots["runtime-plugins:\(marker)"] == nil
                }.map(\.id))
                let previousRelations = try await store.fetchAllRelations()
                let priorChildIDs = Set(previousRelations.filter {
                    $0.relationKind == "contains" && unscannedPluginIDs.contains($0.sourceResourceID)
                }.map(\.targetResourceID))
                let currentIDs = Set(combinedResources.map(\.id))
                let retained = previousResources.filter {
                    priorChildIDs.contains($0.id) && $0.scope == .runtime && !currentIDs.contains($0.id)
                }
                let retainedIDs = Set(retained.map(\.id))
                combinedResources.append(contentsOf: retained.map { resource in
                    CapabilityResource(
                        id: resource.id, name: resource.name, kind: resource.kind, status: .warning,
                        scope: resource.scope, projectID: resource.projectID, confidence: resource.confidence,
                        summary: resource.summary, sourceRootID: "last-known-runtime",
                        relativeSourcePath: resource.relativeSourcePath, sourcePathHash: resource.sourcePathHash,
                        lastSeenAt: resource.lastSeenAt, ownership: resource.ownership,
                        origin: resource.origin, classificationConfidence: resource.classificationConfidence,
                        originIdentifier: resource.originIdentifier, sourceVersion: resource.sourceVersion,
                        contentFingerprint: resource.contentFingerprint,
                        modified: resource.modified
                    )
                })
                let allIDs = Set(combinedResources.map(\.id))
                combinedProvenance.append(contentsOf: try await store.fetchAllProvenance().filter { retainedIDs.contains($0.resourceID) })
                combinedRelations.append(contentsOf: previousRelations.filter {
                    retainedIDs.contains($0.targetResourceID) &&
                    unscannedPluginIDs.contains($0.sourceResourceID) &&
                    allIDs.contains($0.sourceResourceID)
                })
            }
        }
        // Companion declarations are a derived, privacy-safe projection of
        // local Agent/Skill documents. Global/runtime sources are read once
        // without project roots; each complete project is then reopened only
        // through the same persistent project gate used by discovery.
        let globalCompanionReport = CapabilityCompanionResolver(
            resources: combinedResources,
            roots: configuration.scanRoots.filter { $0.kind != .projects },
            transientRoots: transientRoots,
            agentPairings: discovery.agentPairings,
            fileSystem: fileSystem
        ).resolveWithIssues()
        combinedRelations.append(contentsOf: globalCompanionReport.relations.map(\.resourceRelation))
        companionIssueCount = globalCompanionReport.issues.count

        let scopeByRootID = Dictionary(
            uniqueKeysWithValues: discovery.historyScanBatch.scopes.map { ($0.rootID, $0) }
        )
        let companionCandidates = combinedResources
        let companionPairings = discovery.agentPairings
        let companionFileSystem = fileSystem
        var failedCompanionRootIDs = Set<String>()
        for root in configuration.scanRoots where root.kind == .projects {
            guard scopeByRootID[root.id]?.coverage == .complete,
                  !isolatedDiscovery.unavailableProjectRootIDs.contains(root.id) else {
                continue
            }
            let projectCompanion = await projectReadGate.perform(root: root) {
                CapabilityCompanionResolver(
                    resources: companionCandidates,
                    roots: [root],
                    transientRoots: [:],
                    agentPairings: companionPairings,
                    fileSystem: companionFileSystem
                ).resolveWithIssues()
            }
            switch projectCompanion {
            case .success(let report):
                combinedRelations.append(contentsOf: report.relations.map(\.resourceRelation))
                companionIssueCount += report.issues.count
            case .failure(.cancelled):
                throw CancellationError()
            case .failure:
                failedCompanionRootIDs.insert(root.id)
                companionIssueCount += 1
            }
        }
        try Task.checkCancellation()
        var resultResourceCoverage = discovery.historyScanBatch.coverage
        if runtimeAliasCanonicalizationDeferred,
           resultResourceCoverage != .unstable {
            // Runtime remains useful, but its physical Skill alias projection
            // is intentionally unqualified for this pass.
            resultResourceCoverage = .partial
        }
        if !failedCompanionRootIDs.isEmpty {
            resultResourceCoverage = resultResourceCoverage.dominating(with: .partial)
            combinedProjects = combinedProjects.map { project in
                guard failedCompanionRootIDs.contains(project.id) else { return project }
                return CapabilityProject(
                    id: project.id,
                    name: project.name,
                    available: false,
                    lastSeenAt: project.lastSeenAt
                )
            }
        }
        // A discovery output may contain a useful positive subset while one
        // approved scope could not be enumerated or read. Keep the last
        // verified rows for that scope instead of treating the partial subset
        // as a complete deletion snapshot. A genuinely empty, complete scope
        // has no IDs here and therefore replaces normally.
        let incompleteRootIDs = Set(discovery.historyScanBatch.scopes.compactMap { scope in
            scope.coverage == .complete ? nil : scope.rootID
        })
        if !incompleteRootIDs.isEmpty {
            let currentIDs = Set(combinedResources.map(\.id))
            let retained = previousResources.filter {
                incompleteRootIDs.contains($0.sourceRootID) && !currentIDs.contains($0.id)
            }
            combinedResources.append(contentsOf: retained)
            let retainedIDs = Set(retained.map(\.id))
            let currentProvenanceIDs = Set(combinedProvenance.map(\.id))
            combinedProvenance.append(contentsOf: previousProvenance.filter {
                retainedIDs.contains($0.resourceID) && !currentProvenanceIDs.contains($0.id)
            })
            let allIDs = Set(combinedResources.map(\.id))
            // Runtime discovery can yield repeated IDs (for example duplicate
            // MCP names). Keep every observed root association here instead
            // of trapping on a duplicate dictionary key or inventing a source
            // priority. SQLite's existing INSERT OR REPLACE boundary retains
            // its established projection behavior.
            let resourceRootsByID = Dictionary(grouping: combinedResources, by: \.id)
                .mapValues { Set($0.map(\.sourceRootID)) }
            let currentRelationIDs = Set(combinedRelations.map(\.id))
            combinedRelations.append(contentsOf: previousRelations.filter { relation in
                guard allIDs.contains(relation.sourceResourceID), allIDs.contains(relation.targetResourceID) else { return false }
                guard !currentRelationIDs.contains(relation.id) else { return false }
                let sourceRoots = resourceRootsByID[relation.sourceResourceID] ?? []
                let targetRoots = resourceRootsByID[relation.targetResourceID] ?? []
                return !sourceRoots.isDisjoint(with: incompleteRootIDs)
                    || !targetRoots.isDisjoint(with: incompleteRootIDs)
            })
            let incompleteProjectRootIDs = Set(discovery.historyScanBatch.scopes.compactMap { scope in
                scope.coverage == .complete || scope.rootKind != .projects ? nil : scope.rootID
            })
            let previousProjectsByID = Dictionary(
                uniqueKeysWithValues: previousProjects.map { ($0.id, $0) }
            )
            combinedProjects = combinedProjects.map { project in
                guard incompleteProjectRootIDs.contains(project.id),
                      !project.available,
                      let previous = previousProjectsByID[project.id] else {
                    return project
                }
                return CapabilityProject(
                    id: project.id,
                    name: previous.name,
                    available: false,
                    lastSeenAt: previous.lastSeenAt
                )
            }
            let currentProjectIDs = Set(combinedProjects.map(\.id))
            combinedProjects.append(contentsOf: previousProjects.filter {
                incompleteProjectRootIDs.contains($0.id) && !currentProjectIDs.contains($0.id)
            }.map {
                CapabilityProject(
                    id: $0.id,
                    name: $0.name,
                    available: false,
                    lastSeenAt: $0.lastSeenAt
                )
            })
        }
        if !failedCompanionRootIDs.isEmpty {
            let allIDs = Set(combinedResources.map(\.id))
            let resourceRootsByID = Dictionary(grouping: combinedResources, by: \.id)
                .mapValues { Set($0.map(\.sourceRootID)) }
            let currentRelationIDs = Set(combinedRelations.map(\.id))
            combinedRelations.append(contentsOf: previousRelations.filter { relation in
                guard CapabilityCompanionRelationKind(rawValue: relation.relationKind) != nil,
                      allIDs.contains(relation.sourceResourceID),
                      allIDs.contains(relation.targetResourceID),
                      !currentRelationIDs.contains(relation.id) else { return false }
                let sourceRoots = resourceRootsByID[relation.sourceResourceID] ?? []
                let targetRoots = resourceRootsByID[relation.targetResourceID] ?? []
                return !sourceRoots.isDisjoint(with: failedCompanionRootIDs)
                    || !targetRoots.isDisjoint(with: failedCompanionRootIDs)
            })
        }
        let unavailableProjectRootIDsForReview = Set(
            discovery.historyScanBatch.scopes.compactMap { scope in
                scope.rootKind == .projects && scope.coverage != .complete
                    ? scope.rootID
                    : nil
            }
        ).union(failedCompanionRootIDs)
        try Task.checkCancellation()
        // Resource inventory is a replaceable snapshot. A completed scan
        // prunes deleted/moved records; runtime failures are represented by
        // the last successful snapshot already present in the store because
        // the replacement is only committed after discovery succeeds.
        try await store.replaceResourceInventory(
            resources: combinedResources,
            projects: combinedProjects,
            provenance: combinedProvenance,
            relations: combinedRelations
        )
        try Task.checkCancellation()

        // The raw verified batch is submitted immediately after the reliable
        // inventory transaction. Later session parsing, quota work or review
        // failures cannot erase an already observed capability-document
        // change. History failures remain isolated to this optional domain.
        var capabilityHistoryStatus: CapabilityHistoryStatus?
        if let capabilityHistoryService {
            do {
                _ = try await capabilityHistoryService.submit(discovery.historyScanBatch)
            } catch {
                // Retain the successful resource inventory. The independent
                // status exposes a safe fixed error category for retry/UI.
            }
            capabilityHistoryStatus = await capabilityHistoryService.status(refresh: false)
            if let capabilityHistoryStatus {
                // Notify the shared presentation before unrelated session
                // inventory/parsing can delay completion. This carries only
                // safe history metadata and does not initiate another scan.
                await onCapabilityHistoryStatus?(capabilityHistoryStatus)
            }
        }

        // Skill evidence resolution uses only currently discovered resources.
        extractor = InvocationExtractor(
            skillResolver: SkillEvidenceResolver(resources: combinedResources, roots: configuration.scanRoots, transientRoots: transientRoots),
            agentResolver: AgentEvidenceResolver(resources: combinedResources, roots: configuration.scanRoots, pairings: discovery.agentPairings)
        )

        // 2. Session file inventory.
        let files = collectSessionFiles(configuration: configuration)
        let recentStart = CapabilityQueryWindow.recent30(now: nowProvider(), calendar: .current).start.timeIntervalSince1970
        let persistedSessions = try await store.fetchAllSessions()
        let sessionsBySourceFileID = Dictionary(grouping: persistedSessions, by: \.sourceFileID)
            .compactMapValues(\.first)
        let sessionEnds = Dictionary(grouping: persistedSessions, by: \.sourceFileID)
            .mapValues { rows in rows.compactMap { $0.endedAt ?? $0.startedAt }.max()?.timeIntervalSince1970 ?? 0 }
        progress(.init(phase: .parsing, processedFiles: 0, totalFiles: files.count, indexedSessions: 0, lastError: nil))

        var processedFiles = 0
        var skippedFiles = 0
        var indexedSessions = 0
        var cancelled = false

        for url in files {
            try Task.checkCancellation()
            if Task.isCancelled {
                cancelled = true
                break
            }
            let sourceFileID = url.lastPathComponent
            guard let attributes = fileSystem.fileAttributes(url) else { continue }
            let checkpoint = try await store.fetchCheckpoint(sourceFileID: sourceFileID)

            // Observation repair affects recent ranking windows. Reparse
            // the last 30 days, but do not force a
            // one-time read of years of unchanged archived rollouts (which
            // can total tens of GB). Any older file changed later is still
            // fully reparsed below.
            let unchanged = checkpoint?.sourceSize == attributes.size &&
                checkpoint?.sourceMtime == attributes.modificationDate && checkpoint?.byteOffset == attributes.size
            let priorParserOutsideRankingWindow = ["1.2.0", "1.3.0", "1.4.0", "1.4.1"].contains(checkpoint?.parserVersion ?? "") &&
                attributes.modificationDate < recentStart && (sessionEnds[sourceFileID] ?? 0) < recentStart
            if let checkpoint, unchanged,
               (checkpoint.parserVersion == RolloutEventDecoder.parserVersion || priorParserOutsideRankingWindow) {
                skippedFiles += 1
                processedFiles += 1
                progress(.init(phase: .parsing, processedFiles: processedFiles, totalFiles: files.count, indexedSessions: indexedSessions, lastError: nil))
                continue
            }

            let startOffset: UInt64
            if let checkpoint,
               checkpoint.parserVersion == RolloutEventDecoder.parserVersion,
               attributes.size > checkpoint.sourceSize,
               checkpoint.byteOffset <= attributes.size {
                startOffset = checkpoint.byteOffset // appended
            } else {
                // Equal-size content with a changed mtime is a replacement,
                // not an append from an already-complete checkpoint. Strict
                // growth retains the cheap append path for large rollouts.
                startOffset = 0 // fresh, same-size replacement or truncated
            }

            let outcome = try await parseSessionFile(
                url: url,
                sourceFileID: sourceFileID,
                startOffset: startOffset,
                resumeCheckpoint: checkpoint,
                priorSession: startOffset > 0 ? sessionsBySourceFileID[sourceFileID] : nil,
                scanRoots: configuration.scanRoots,
                fileProgress: { [processedFiles, indexedSessions] bytesRead, fileTotal in
                    progress(.init(
                        phase: .parsing,
                        processedFiles: processedFiles,
                        totalFiles: files.count,
                        indexedSessions: indexedSessions,
                        lastError: nil,
                        currentFileBytesRead: bytesRead,
                        currentFileTotalBytes: fileTotal
                    ))
                }
            )

            if outcome.cancelled {
                cancelled = true
                break
            }
            if outcome.indexed {
                indexedSessions += 1
            }
            processedFiles += 1
            progress(.init(phase: .parsing, processedFiles: processedFiles, totalFiles: files.count, indexedSessions: indexedSessions, lastError: nil))
        }

        if !cancelled {
            try await runReviewPass(
                configuration: configuration,
                unavailableProjectRootIDs: unavailableProjectRootIDsForReview
            )
        }

        progress(.init(
            phase: cancelled ? .cancelled : .completed,
            processedFiles: processedFiles,
            totalFiles: files.count,
            indexedSessions: indexedSessions,
            lastError: nil
        ))
        return IndexingResult(
            processedFiles: processedFiles,
            skippedFiles: skippedFiles,
            indexedSessions: indexedSessions,
            resources: combinedResources.count,
            cancelled: cancelled,
            runtimeCoverage: runtimeCoverage,
            runtimeIssueCount: runtimeIssues.count,
            discoveryIssueCount: registry.issues.count + discovery.issues.count + companionIssueCount,
            resourceCoverage: resultResourceCoverage,
            runtimePluginInventoryAvailable: runtimePluginInventoryAvailable,
            runtimePluginPackagesAvailable: runtimePluginPackagesAvailable,
            capabilityHistoryStatus: capabilityHistoryStatus
        )
    }

    public func capabilityHistoryPage(
        _ query: CapabilityHistoryQuery
    ) async throws -> CapabilityHistoryPage {
        guard let capabilityHistoryService else {
            throw CapabilityHistoryStore.StoreError.storageUnavailable
        }
        return try await capabilityHistoryService.page(query)
    }

    public func capabilityHistoryStatus(
        refresh: Bool = true
    ) async -> CapabilityHistoryStatus {
        guard let capabilityHistoryService else { return .unavailable }
        return await capabilityHistoryService.status(refresh: refresh)
    }

    public func clearCapabilityHistoryConfirmed() async throws -> CapabilityHistoryStatus {
        guard let capabilityHistoryService else {
            throw CapabilityHistoryStore.StoreError.storageUnavailable
        }
        return try await capabilityHistoryService.clearConfirmed()
    }

    public func cancelPendingCapabilityHistoryWrites() async {
        await capabilityHistoryService?.cancelPendingWrites()
    }

    private struct PluginManifestKey: Hashable {
        let packagePath: String
        let manifestPath: String
    }

    /// Preserves the established native plugin Skill ID only when a complete
    /// current plugin-cache scan and the current runtime inventory prove the
    /// same package directory, manifest and exact parent/child containment.
    /// Names and runtime markers are never treated as identity evidence.
    static func pluginPackageRuntimeAliasMap(
        runtime: CodexRuntimeDiscovery.Result,
        discovery: DiscoveryOutput,
        scanRoots: [ScanRoot],
        pluginInventoryAvailable: Bool,
        pluginPackagesAvailable: Bool
    ) -> [String: String] {
        guard pluginInventoryAvailable, pluginPackagesAvailable else { return [:] }
        let nativeRoots = scanRoots.filter { $0.kind == .plugins && $0.scope == .plugin }
        guard nativeRoots.count == 1, let nativeRoot = nativeRoots.first,
              !discovery.issues.contains(where: { $0.rootID == nativeRoot.id }) else {
            return [:]
        }

        let nativeResourcesByID = Dictionary(grouping: discovery.resources, by: \.id)
        let runtimeResourcesByID = Dictionary(grouping: runtime.resources, by: \.id)
        let nativeContainsByChild = exactContainsParents(discovery.relations)
        let runtimeContainsByChild = exactContainsParents(runtime.relations)
        let nativeRootPath = nativeRoot.url.resolvingSymlinksInPath().standardizedFileURL.path

        var nativeIDsByKey: [PluginManifestKey: Set<String>] = [:]
        for rows in nativeResourcesByID.values {
            guard let child = oneConsistentResource(rows),
                  child.kind == .skill,
                  child.scope == .plugin,
                  child.projectID == nil,
                  child.sourceRootID == nativeRoot.id,
                  child.ownership == .pluginProvided,
                  child.origin == .plugin,
                  let childRelative = child.relativeSourcePath,
                  let parentIDs = nativeContainsByChild[child.id],
                  parentIDs.count == 1,
                  let parentID = parentIDs.first,
                  let parentRows = nativeResourcesByID[parentID],
                  let parent = oneConsistentResource(parentRows),
                  parent.kind == .plugin,
                  parent.scope == .plugin,
                  parent.projectID == nil,
                  parent.sourceRootID == nativeRoot.id,
                  let parentRelative = parent.relativeSourcePath,
                  childRelative.hasPrefix(parentRelative + "/") else { continue }
            let packagePath = nativeRoot.url.appendingPathComponent(parentRelative)
                .resolvingSymlinksInPath().standardizedFileURL.path
            let manifestPath = nativeRoot.url.appendingPathComponent(childRelative)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard isStrictlyInside(packagePath, root: nativeRootPath),
                  isStrictlyInside(manifestPath, root: packagePath) else { continue }
            nativeIDsByKey[
                PluginManifestKey(packagePath: packagePath, manifestPath: manifestPath),
                default: []
            ].insert(child.id)
        }

        struct RuntimeProof {
            let childID: String
            let parentID: String
        }
        var runtimeProofsByKey: [PluginManifestKey: [RuntimeProof]] = [:]
        for rows in runtimeResourcesByID.values {
            guard let child = oneConsistentResource(rows),
                  child.kind == .skill,
                  child.scope == .runtime,
                  child.projectID == nil,
                  child.ownership == .pluginProvided,
                  child.origin == .plugin,
                  let childRelative = child.relativeSourcePath,
                  let parentIDs = runtimeContainsByChild[child.id],
                  parentIDs.count == 1,
                  let parentID = parentIDs.first,
                  let parentRows = runtimeResourcesByID[parentID],
                  let parent = oneConsistentResource(parentRows),
                  parent.kind == .plugin,
                  parent.scope == .runtime,
                  parent.projectID == nil,
                  let parentRelative = parent.relativeSourcePath,
                  let marker = runtimePluginMarker(from: parentRelative),
                  child.sourceRootID == "runtime-plugins:\(marker)",
                  childRelative.hasPrefix(parentRelative + "/"),
                  let packageURL = runtime.transientRoots["runtime-plugins:\(marker)"] else {
                continue
            }
            let packagePath = packageURL.resolvingSymlinksInPath().standardizedFileURL.path
            let childWithinPackage = String(childRelative.dropFirst(parentRelative.count + 1))
            let manifestPath = packageURL.appendingPathComponent(childWithinPackage)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard isStrictlyInside(manifestPath, root: packagePath) else { continue }
            runtimeProofsByKey[
                PluginManifestKey(packagePath: packagePath, manifestPath: manifestPath),
                default: []
            ].append(RuntimeProof(childID: child.id, parentID: parent.id))
        }

        var proposedTargets: [String: Set<String>] = [:]
        for (key, proofs) in runtimeProofsByKey {
            let runtimeChildIDs = Set(proofs.map(\.childID))
            let runtimeParentIDs = Set(proofs.map(\.parentID))
            guard runtimeChildIDs.count == 1,
                  runtimeParentIDs.count == 1,
                  let runtimeChildID = runtimeChildIDs.first,
                  let nativeIDs = nativeIDsByKey[key],
                  nativeIDs.count == 1,
                  let nativeID = nativeIDs.first else { continue }
            proposedTargets[runtimeChildID, default: []].insert(nativeID)
        }
        return proposedTargets.compactMapValues { targets in
            targets.count == 1 ? targets.first : nil
        }
    }

    private static func exactContainsParents(
        _ relations: [ResourceRelation]
    ) -> [String: Set<String>] {
        var seenRelationIDs = Set<String>()
        var result: [String: Set<String>] = [:]
        for relation in relations where relation.relationKind == "contains" && relation.confidence == .exact {
            guard seenRelationIDs.insert(relation.id).inserted else { continue }
            result[relation.targetResourceID, default: []].insert(relation.sourceResourceID)
        }
        return result
    }

    private static func oneConsistentResource(
        _ rows: [CapabilityResource]
    ) -> CapabilityResource? {
        guard let first = rows.first, rows.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func runtimePluginMarker(from parentRelative: String) -> String? {
        let components = parentRelative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "plugins",
              !components[1].isEmpty else { return nil }
        return String(components[1])
    }

    private static func isStrictlyInside(_ path: String, root: String) -> Bool {
        path.hasPrefix(root + "/")
    }

    // MARK: - Review pass (production caller for IntegrityRules)

    private func runReviewPass(
        configuration: Configuration,
        unavailableProjectRootIDs: Set<String>
    ) async throws {
        let resources = try await store.fetchAllResources()
        let sessions = try await store.fetchAllSessions()
        let previousFindings = try await store.fetchAllFindings()
        var invocationsBySession: [String: [InvocationEvent]] = [:]
        for session in sessions {
            invocationsBySession[session.id] = try await store.fetchCalls(sessionID: session.id)
        }
        let quotas = try await store.fetchAllQuotaSnapshots()
        // MissingSourceRule treats a root absent from the context as unknown.
        // Do not reopen a project that this pass could not verify. All other
        // rule inputs remain complete and use the established replace model.
        let reviewRoots = configuration.scanRoots.filter {
            !($0.kind == .projects && unavailableProjectRootIDs.contains($0.id))
        }
        let context = ReviewContext(
            resources: resources,
            sessions: sessions,
            invocationsBySession: invocationsBySession,
            quotaSnapshots: quotas,
            scanRoots: reviewRoots,
            fileSystem: fileSystem,
            now: nowProvider()
        )
        // Deterministic rules only; disabled Rule 5 is never evaluated.
        var findings = IntegrityRules.evaluate(context: context)
        let resourcesByID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        let findingIDs = Set(findings.map(\.id))
        findings.append(contentsOf: previousFindings.filter { finding in
            guard finding.ruleID == "rule.missing-source",
                  !findingIDs.contains(finding.id),
                  let resourceID = finding.resourceID,
                  let resource = resourcesByID[resourceID] else {
                return false
            }
            return unavailableProjectRootIDs.contains(resource.sourceRootID)
        })
        try await store.replaceFindings(findings)
    }

    // MARK: - Session file parsing

    private struct ParseOutcome {
        let indexed: Bool
        let cancelled: Bool
    }

    /// Accumulated results for one session file, produced without retaining the
    /// file's full event stream in memory.
    private struct SessionAccumulation {
        let sessionID: String
        let sourceFileID: String
        let startedAt: Date?
        let endedAt: Date?
        let status: TaskStatus
        let sawAnyEnvelope: Bool
        let decoderIssueCount: Int
        let unknownEvents: Int
        let invocation: InvocationExtraction
        let tokens: TokenUsageExtraction
        let projectID: String?
    }

    private func parseSessionFile(
        url: URL,
        sourceFileID: String,
        startOffset: UInt64,
        resumeCheckpoint: IndexCheckpoint?,
        priorSession: TaskSummary?,
        scanRoots: [ScanRoot],
        fileProgress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) async throws -> ParseOutcome {
        let sourceBeforeRead = fileSystem.fileAttributes(url)
        guard let reader = JSONLIncrementalReader(url: url, startOffset: startOffset) else {
            return ParseOutcome(indexed: false, cancelled: false)
        }

        // On an append, the session id is already persisted. On a fresh parse,
        // read leading envelopes until a session_meta envelope yields the id.
        // Rollout files begin with session_meta, so the leading buffer is tiny.
        var resolvedSessionID: String? = startOffset > 0 ? priorSession?.id : nil
        var resolvedProjectID: String? = startOffset > 0 ? priorSession?.projectID : nil

        var leading: [RolloutEnvelope] = []
        var leadingDecoderIssues = 0
        var leadingUnknownEvents = 0
        var lastCommittedOffset = startOffset
        var cancelled = false

        while resolvedSessionID == nil {
            guard let line = try reader.nextLine() else { break }
            try Task.checkCancellation()
            if Task.isCancelled { cancelled = true; break }
            let result = decoder.decode(line)
            leadingDecoderIssues += result.issues.count
            switch result.line {
            case .envelope(let envelope):
                leading.append(envelope)
                if envelope.type == .sessionMeta {
                    resolvedSessionID = Self.sessionID(from: envelope)
                    if resolvedProjectID == nil {
                        resolvedProjectID = Self.projectID(from: envelope, scanRoots: scanRoots)
                    }
                }
            case .unknownEvent:
                leadingUnknownEvents += 1
            case nil:
                break
            }
            lastCommittedOffset = reader.currentByteOffset
        }

        if cancelled {
            return ParseOutcome(indexed: false, cancelled: true)
        }

        let sessionID = resolvedSessionID ?? sourceFileID
        let existingCalls = startOffset > 0
            ? (try await store.fetchCalls(sessionID: sessionID))
            : []
        let resumeTokenSnapshot: TokenUsageSnapshot?
        if startOffset > 0 {
            resumeTokenSnapshot = TokenUsageParser.newestCumulative(
                from: try await store.fetchTokenSnapshots(sessionID: sessionID)
            )
        } else {
            resumeTokenSnapshot = nil
        }
        var metadata: RolloutEnvelope? = leading.first { $0.type == .sessionMeta }
        // Appended segments do not repeat metadata. Recover only a bounded
        // header, without replaying old calls or cumulative token snapshots.
        if startOffset > 0, let header = JSONLIncrementalReader(url: url) {
            for _ in 0..<32 {
                guard let line = try header.nextLine() else { break }
                if case .envelope(let envelope) = decoder.decode(line).line, envelope.type == .sessionMeta {
                    metadata = envelope; break
                }
            }
        }
        let directory = metadata?.payload?.json["cwd"] as? String
        var invocation = extractor.makeAccumulator(
            sessionID: sessionID,
            projectID: resolvedProjectID,
            workingDirectory: directory,
            existingCalls: existingCalls
        )
        if startOffset > 0, let metadata { invocation.process(metadata) }
        var tokens = tokenParser.makeAccumulator(sessionID: sessionID, resumeFrom: resumeTokenSnapshot)

        var segmentStartedAt: Date?
        var segmentEndedAt: Date?
        var segmentLifecycleStatus: TaskStatus?
        var sawAnyEnvelope = false
        var decoderIssueCount = leadingDecoderIssues
        var unknownEvents = leadingUnknownEvents

        func process(_ envelope: RolloutEnvelope) {
            sawAnyEnvelope = true
            if let timestamp = envelope.timestamp {
                segmentStartedAt = min(segmentStartedAt ?? timestamp, timestamp)
                segmentEndedAt = max(segmentEndedAt ?? timestamp, timestamp)
            }
            if envelope.type == .eventMessage, let payload = envelope.payload {
                switch payload.json["type"] as? String {
                case "task_started": segmentLifecycleStatus = .running
                case "task_complete": segmentLifecycleStatus = .completed
                default: break
                }
            }
            invocation.process(envelope)
            tokens.process(envelope)
        }

        for envelope in leading { process(envelope) }
        leading.removeAll()

        let fileSize = fileSystem.fileAttributes(url)?.size ?? 0
        var lastProgressByte: UInt64 = 0

        while let line = try reader.nextLine() {
            try Task.checkCancellation()
            if Task.isCancelled { cancelled = true; break }
            let result = decoder.decode(line)
            decoderIssueCount += result.issues.count
            switch result.line {
            case .envelope(let envelope):
                process(envelope)
            case .unknownEvent:
                unknownEvents += 1
            case nil:
                break
            }
            lastCommittedOffset = reader.currentByteOffset
            if lastCommittedOffset >= lastProgressByte + 1_048_576 {
                fileProgress(lastCommittedOffset, fileSize)
                lastProgressByte = lastCommittedOffset
            }
        }

        // Calls have not committed. Advancing a checkpoint on cancel would
        // permanently drop the uncommitted segment on retry.
        if cancelled {
            return ParseOutcome(indexed: false, cancelled: true)
        }

        if startOffset > 0, !invocation.unresolvedResultIdentifiers.isEmpty {
            let aliases = try recoverCallIdentifierAliases(
                url: url,
                before: startOffset,
                matching: invocation.unresolvedResultIdentifiers
            )
            invocation.resolvePendingResults(aliases: aliases)
        }

        let matchingPriorSession = startOffset > 0 && priorSession?.id == sessionID ? priorSession : nil
        let startedAt = Self.earlier(matchingPriorSession?.startedAt, segmentStartedAt)
        let endedAt = Self.later(matchingPriorSession?.endedAt, segmentEndedAt)
        let status = segmentLifecycleStatus ?? matchingPriorSession?.status ?? .unknown
        let projectID = resolvedProjectID ?? matchingPriorSession?.projectID

        let accumulation = SessionAccumulation(
            sessionID: sessionID,
            sourceFileID: sourceFileID,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            sawAnyEnvelope: sawAnyEnvelope,
            decoderIssueCount: decoderIssueCount,
            unknownEvents: unknownEvents,
            invocation: invocation.finish(),
            tokens: tokens.finish(),
            projectID: projectID
        )
        let batch = try makeBatch(accumulation: accumulation, priorCoverage: matchingPriorSession?.coverage)
        try await store.replaceSession(batch, resetExisting: startOffset == 0)
        if let attributes = fileSystem.fileAttributes(url),
           sourceBeforeRead?.size == attributes.size, sourceBeforeRead?.modificationDate == attributes.modificationDate {
            try await store.upsertCheckpoint(IndexCheckpoint(
                sourceFileID: sourceFileID,
                sourceSize: attributes.size,
                sourceMtime: attributes.modificationDate,
                byteOffset: attributes.size,
                parserVersion: RolloutEventDecoder.parserVersion,
                indexedAt: Date()
            ))
        }
        return ParseOutcome(indexed: true, cancelled: false)
    }

    /// Completion events can arrive just after a committed append checkpoint,
    /// while the persisted call intentionally retains its response-item ID.
    /// Recover only the small, recent identifier seam needed to join those two
    /// stable IDs; never replay the file or manufacture a standalone call.
    private func recoverCallIdentifierAliases(
        url: URL,
        before checkpointOffset: UInt64,
        matching identifiers: Set<String>
    ) throws -> [String: String] {
        let maximumLookback: UInt64 = 16 * 1_024 * 1_024
        let startOffset = checkpointOffset > maximumLookback ? checkpointOffset - maximumLookback : 0
        let startsAtLineBoundary = try isJSONLLineBoundary(url: url, offset: startOffset)
        guard let reader = JSONLIncrementalReader(
            url: url,
            startOffset: startOffset,
            endOffsetExclusive: checkpointOffset
        ) else { return [:] }
        var candidateItemIDs: [String: Set<String>] = [:]
        var isFirstWindowLine = true

        while true {
            // Check before I/O as well as after each complete line. In
            // particular, cancellation must still be observed when a bounded
            // window contains only one unterminated oversized record.
            try Task.checkCancellation()
            guard let line = try reader.nextLine() else { break }
            try Task.checkCancellation()
            // Reject a partial leading record instead of trying to decode or
            // correlate it. Offset zero and a preceding newline prove that
            // the first bounded byte starts a complete JSONL record.
            if isFirstWindowLine {
                isFirstWindowLine = false
                if !startsAtLineBoundary { continue }
            }
            guard case .envelope(let envelope)? = decoder.decode(line).line,
                  envelope.type == .responseItem,
                  let payload = envelope.payload?.json,
                  let type = payload["type"] as? String,
                  type == "custom_tool_call" || type == "function_call",
                  let callID = InvocationIdentifier.validated(payload["call_id"] as? String),
                  identifiers.contains(callID),
                  let itemID = InvocationIdentifier.validated(payload["id"] as? String)
            else { continue }
            candidateItemIDs[callID, default: []].insert(itemID)
        }
        return candidateItemIDs.compactMapValues { itemIDs in
            // A terminal identifier cannot safely select between retries that
            // used the same call ID but persisted distinct response-item IDs.
            itemIDs.count == 1 ? itemIDs.first : nil
        }
    }

    /// The alias window reads at most 16 MiB of records plus this one-byte
    /// boundary witness. It distinguishes an exact line start from a partial
    /// leading record without following an unbounded predecessor line.
    private func isJSONLLineBoundary(url: URL, offset: UInt64) throws -> Bool {
        guard offset > 0 else { return true }
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - 1)
            let byte = try handle.read(upToCount: 1)
            try Task.checkCancellation()
            return byte?.first == 0x0A
        } catch let error as CancellationError {
            throw error
        } catch {
            return false
        }
    }

    private static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return min(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.none, .none): return nil
        }
    }

    private static func sessionID(from envelope: RolloutEnvelope) -> String? {
        guard envelope.type == .sessionMeta, let payload = envelope.payload else { return nil }
        if let id = payload.json["id"] as? String, !id.isEmpty { return id }
        if let id = payload.json["session_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    private static func projectID(from envelope: RolloutEnvelope, scanRoots: [ScanRoot]) -> String? {
        guard envelope.type == .sessionMeta, let payload = envelope.payload else { return nil }
        let raw = (payload.json["cwd"] as? String) ?? (payload.json["working_directory"] as? String) ?? (payload.json["workdir"] as? String)
        guard let raw, raw.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: raw).standardizedFileURL.path
        return scanRoots.filter { $0.kind == .projects || $0.scope == .project }.compactMap { root -> (String, Int)? in
            let rootPath = root.url.standardizedFileURL.path
            guard candidate == rootPath || candidate.hasPrefix(rootPath + "/") else { return nil }
            return (root.id, rootPath.count)
        }.max { $0.1 < $1.1 }?.0
    }

    private func makeBatch(
        accumulation: SessionAccumulation,
        priorCoverage: CoverageState?
    ) throws -> PersistedSessionBatch {
        let coverage = Self.segmentCoverage(
            sawAnyEnvelope: accumulation.sawAnyEnvelope,
            decoderIssueCount: accumulation.decoderIssueCount,
            unknownEvents: accumulation.unknownEvents,
            extractionIssues: accumulation.invocation.issues,
            tokenIssues: accumulation.tokens.issues,
            tokenSnapshots: accumulation.tokens.snapshots
        )
        let merged = priorCoverage.map { CoverageState.mergedCoverage($0, coverage) } ?? coverage

        return PersistedSessionBatch(
            session: TaskSummary(
                id: accumulation.sessionID,
                projectID: accumulation.projectID,
                startedAt: accumulation.startedAt,
                endedAt: accumulation.endedAt,
                status: accumulation.status,
                coverage: merged,
                parserVersion: RolloutEventDecoder.parserVersion,
                sourceFileID: accumulation.sourceFileID,
                title: nil
            ),
            calls: accumulation.invocation.calls,
            tokenSnapshots: accumulation.tokens.snapshots,
            quotaSnapshots: accumulation.tokens.quotas,
            findings: []
        )
    }

    /// `complete` only when every available evidence stage is clean.
    private static func segmentCoverage(
        sawAnyEnvelope: Bool,
        decoderIssueCount: Int,
        unknownEvents: Int,
        extractionIssues: [InvocationIssue],
        tokenIssues: [TokenUsageIssue],
        tokenSnapshots: [TokenUsageSnapshot]
    ) -> CoverageState {
        if !sawAnyEnvelope { return .unknown }
        let decoderClean = decoderIssueCount == 0 && unknownEvents == 0
        let extractionClean = extractionIssues.isEmpty
        let tokenClean = tokenIssues.isEmpty
        let snapshotsClean = tokenSnapshots.allSatisfy { $0.usage.coverage == .complete }
        let allComplete = decoderClean && extractionClean && tokenClean && snapshotsClean
        return allComplete ? .complete : .partial
    }

    // MARK: - File inventory

    private func collectSessionFiles(configuration: Configuration) -> [URL] {
        var files: [URL] = []
        for root in configuration.activeSessionRoots {
            collectJSONLFiles(in: root, depth: 0, maxDepth: 5, into: &files)
        }
        if let archivedRoot = configuration.archivedSessionRoot {
            collectJSONLFiles(in: archivedRoot, depth: 0, maxDepth: 2, into: &files)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func collectJSONLFiles(in directory: URL, depth: Int, maxDepth: Int, into files: inout [URL]) {
        guard depth <= maxDepth, fileSystem.isDirectory(directory) else { return }
        for entry in fileSystem.contents(directory) {
            if entry.pathExtension == "jsonl", fileSystem.isReadable(entry) {
                files.append(entry)
            } else if fileSystem.isDirectory(entry) {
                collectJSONLFiles(in: entry, depth: depth + 1, maxDepth: maxDepth, into: &files)
            }
        }
    }
}
