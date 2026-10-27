import Foundation
import OSLog

/// Normalized output of one scan pass.
public struct DiscoveryOutput: Sendable, Equatable {
    public let resources: [CapabilityResource]
    public let issues: [DiscoveryIssue]
    public let provenance: [CapabilityProvenance]
    public let projects: [CapabilityProject]
    public let relations: [ResourceRelation]
    /// Ephemeral Agent TOML/Brief pairings used by companion resolution. The
    /// relative paths are never persisted in the derived inventory.
    public let agentPairings: [CapabilityAgentPairing]
    /// Verified, privacy-safe source observations for the future history
    /// detector. This is not persisted and contains no source paths/body.
    public let historyScanBatch: CapabilityHistoryScanBatch

    public init(
        resources: [CapabilityResource],
        issues: [DiscoveryIssue],
        provenance: [CapabilityProvenance] = [],
        projects: [CapabilityProject] = [],
        relations: [ResourceRelation] = [],
        agentPairings: [CapabilityAgentPairing] = [],
        historyScanBatch: CapabilityHistoryScanBatch = CapabilityHistoryScanBatch(
            observedAt: Date(), scopes: [], observations: [])
    ) {
        self.resources = resources
        self.issues = issues
        self.provenance = provenance
        self.projects = projects
        self.relations = relations
        self.agentPairings = agentPairings
        self.historyScanBatch = historyScanBatch
    }
}

/// A tolerance issue recorded while scanning (missing root, unknown manifest
/// version, symlink escape, unreadable file). Discovery never mutates sources.
public struct DiscoveryIssue: Sendable, Equatable {
    public let rootID: String
    public let relativePath: String
    public let message: String

    public init(rootID: String, relativePath: String, message: String) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.message = message
    }
}

/// Physical identity evidence produced inside the same bounded project job as
/// discovery. Callers must not replace a missing tuple with a lexical path.
struct ProjectSkillPhysicalPath: Sendable, Equatable {
    let physicalPath: String
    let resourceID: String
}

/// Production-only partitioned discovery result. The public scanner output
/// remains source-compatible for focused scanner tests and other pure callers.
struct IsolatedResourceDiscovery: Sendable {
    let output: DiscoveryOutput
    let projectSkillPhysicalPaths: [ProjectSkillPhysicalPath]
    let unavailableProjectRootIDs: Set<String>
}

/// Read-only capability discovery over explicit scan roots.
///
/// Recognizes at minimum: Skill manifests (`SKILL.md`), Agent briefs
/// (`agent.md`/`Agent.md`/`AGENTS.md`), project-local skills and agents,
/// project registry entries, and plugin manifests (`.codex-plugin`,
/// `.app.json`, `.mcp.json`, `hooks.json`). Missing roots, absent optional
/// files, and older layouts are tolerated; symlinks that escape an approved
/// root are never followed. The scanner never writes to a discovered root.
public struct ResourceScanner: Sendable {
    private static let maximumTrackedDocumentBytes = 2 * 1_024 * 1_024
    private static let discoveryLogger = Logger(
        subsystem: "com.peiweitang.CodexDirector",
        category: "SourceDiscovery"
    )
    private let roots: [ScanRoot]
    private let fileSystem: FileSystemClient
    private let overrides: [String: ResourceClassificationOverride]
    private let userOwnedSkillRegistrations: Set<SkillOwnershipRegistration>
    private let previousFingerprints: [String: String]
    private let previousModified: [String: Bool]
    private let nowProvider: @Sendable () -> Date
    private let projectReadGate: ProjectSourceReadGate
    private let projectPhysicalPathResolver: @Sendable (URL) -> String?
    private let rootLogPosition: @Sendable (ScanRoot) -> (ordinal: Int, total: Int)

    /// Holds only privacy-safe metadata and a signature while the scanner
    /// completes its final document/directory validation. `observedAt` is
    /// captured only when this candidate is promoted into the returned batch.
    private struct PendingHistoryObservation {
        let resourceID: String
        let sourceRootID: String
        let name: String
        let kind: ResourceKind
        let scope: ResourceScope
        let projectID: String?
        let documents: Set<CapabilityTrackedDocument>
        let signature: String
        let documentSignatures: [CapabilityTrackedDocumentSignature]

        init(
            resourceID: String,
            sourceRootID: String,
            name: String,
            kind: ResourceKind,
            scope: ResourceScope,
            projectID: String?,
            documents: Set<CapabilityTrackedDocument>,
            documentData: [CapabilityTrackedDocument: Data]
        ) {
            precondition(!documents.isEmpty && documents == Set(documentData.keys))
            self.resourceID = resourceID
            self.sourceRootID = sourceRootID
            self.name = name
            self.kind = kind
            self.scope = scope
            self.projectID = projectID
            self.documents = documents
            signature = CapabilityHistoryObservation.signature(for: documents, data: documentData)!
            documentSignatures = CapabilityHistoryObservation.documentSignatures(for: documentData)
        }

        func finalized(observedAt: Date) -> CapabilityHistoryObservation {
            CapabilityHistoryObservation(
                resourceID: resourceID,
                sourceRootID: sourceRootID,
                name: name,
                kind: kind,
                scope: scope,
                projectID: projectID,
                documents: documents,
                signature: signature,
                documentSignatures: documentSignatures,
                observedAt: observedAt
            )
        }
    }

    public init(
        roots: [ScanRoot],
        fileSystem: FileSystemClient = FileSystemClient(),
        overrides: [String: ResourceClassificationOverride] = [:],
        userOwnedSkillRegistrations: Set<SkillOwnershipRegistration> = [],
        previousFingerprints: [String: String] = [:],
        previousModified: [String: Bool] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        projectReadGate: ProjectSourceReadGate = .shared
    ) {
        self.init(
            roots: roots,
            fileSystem: fileSystem,
            overrides: overrides,
            userOwnedSkillRegistrations: userOwnedSkillRegistrations,
            previousFingerprints: previousFingerprints,
            previousModified: previousModified,
            now: now,
            projectReadGate: projectReadGate,
            projectPhysicalPathResolver: {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            },
            rootLogPosition: { root in
                (
                    ordinal: (roots.firstIndex(of: root) ?? 0) + 1,
                    total: roots.count
                )
            }
        )
    }

    init(
        roots: [ScanRoot],
        fileSystem: FileSystemClient,
        overrides: [String: ResourceClassificationOverride] = [:],
        userOwnedSkillRegistrations: Set<SkillOwnershipRegistration> = [],
        previousFingerprints: [String: String] = [:],
        previousModified: [String: Bool] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
        projectReadGate: ProjectSourceReadGate,
        projectPhysicalPathResolver: @escaping @Sendable (URL) -> String?
    ) {
        self.init(
            roots: roots,
            fileSystem: fileSystem,
            overrides: overrides,
            userOwnedSkillRegistrations: userOwnedSkillRegistrations,
            previousFingerprints: previousFingerprints,
            previousModified: previousModified,
            now: now,
            projectReadGate: projectReadGate,
            projectPhysicalPathResolver: projectPhysicalPathResolver,
            rootLogPosition: { root in
                (
                    ordinal: (roots.firstIndex(of: root) ?? 0) + 1,
                    total: roots.count
                )
            }
        )
    }

    private init(
        roots: [ScanRoot],
        fileSystem: FileSystemClient,
        overrides: [String: ResourceClassificationOverride],
        userOwnedSkillRegistrations: Set<SkillOwnershipRegistration>,
        previousFingerprints: [String: String],
        previousModified: [String: Bool],
        now: @escaping @Sendable () -> Date,
        projectReadGate: ProjectSourceReadGate,
        projectPhysicalPathResolver: @escaping @Sendable (URL) -> String?,
        rootLogPosition: @escaping @Sendable (ScanRoot) -> (ordinal: Int, total: Int)
    ) {
        self.roots = roots
        self.fileSystem = fileSystem
        self.overrides = overrides
        self.userOwnedSkillRegistrations = userOwnedSkillRegistrations
        self.previousFingerprints = previousFingerprints
        self.previousModified = previousModified
        nowProvider = now
        self.projectReadGate = projectReadGate
        self.projectPhysicalPathResolver = projectPhysicalPathResolver
        self.rootLogPosition = rootLogPosition
    }

    private enum RootScanLogPhase: String {
        case begin
        case probeEnd = "probe_end"
        case rootEnd = "root_end"
    }

    /// Emits only a fixed phase, root kind, and positional counters. Source
    /// identities, paths, names, contents, and dynamic errors stay out of the
    /// unified log.
    private static func logRootScan(
        _ phase: RootScanLogPhase,
        rootKind: ScanRootKind,
        rootOrdinal: Int,
        rootTotal: Int
    ) {
        discoveryLogger.notice(
            "phase=\(phase.rawValue, privacy: .public) root_kind=\(rootKind.rawValue, privacy: .public) root_ordinal=\(rootOrdinal, privacy: .public) root_total=\(rootTotal, privacy: .public)"
        )
    }

    public func scan() -> DiscoveryOutput {
        var resources: [CapabilityResource] = []
        var issues: [DiscoveryIssue] = []
        var provenance: [CapabilityProvenance] = []
        var projects: [CapabilityProject] = []
        var relations: [ResourceRelation] = []
        var agentPairings: [CapabilityAgentPairing] = []
        var historyObservations: [PendingHistoryObservation] = []
        var historyScopes: [CapabilityHistoryScanScope] = []
        var seenIDs = Set<String>()
        for root in roots {
            let logPosition = rootLogPosition(root)
            Self.logRootScan(
                .begin,
                rootKind: root.kind,
                rootOrdinal: logPosition.ordinal,
                rootTotal: logPosition.total
            )
            defer {
                Self.logRootScan(
                    .rootEnd,
                    rootKind: root.kind,
                    rootOrdinal: logPosition.ordinal,
                    rootTotal: logPosition.total
                )
            }
            var coverage = CapabilityHistoryCoverage.complete
            let probeResult = fileSystem.probeDirectory(root.url)
            Self.logRootScan(
                .probeEnd,
                rootKind: root.kind,
                rootOrdinal: logPosition.ordinal,
                rootTotal: logPosition.total
            )
            if case .failure(let error) = probeResult {
                if root.kind == .projects {
                    projects.append(CapabilityProject(
                        id: root.id,
                        name: root.url.lastPathComponent,
                        available: false
                    ))
                }
                let message = error == .notFound
                    ? "Scan root is missing"
                    : "Scan root is unavailable: \(error.rawValue)"
                issues.append(DiscoveryIssue(rootID: root.id, relativePath: "", message: message))
                coverage = .unavailable
                appendHistoryScope(for: root, coverage: coverage, to: &historyScopes)
                continue
            }
            switch root.kind {
            case .skills: scanSkills(root: root, resources: &resources, provenance: &provenance, issues: &issues, seen: &seenIDs, historyObservations: &historyObservations, coverage: &coverage)
            case .agents: scanAgents(root: root, resources: &resources, issues: &issues, seen: &seenIDs, pairings: &agentPairings, historyObservations: &historyObservations, coverage: &coverage)
            case .plugins: scanPlugins(root: root, resources: &resources, issues: &issues, seen: &seenIDs, relations: &relations, coverage: &coverage)
            case .projects: scanProject(root: root, resources: &resources, provenance: &provenance, projects: &projects, issues: &issues, seen: &seenIDs, pairings: &agentPairings, historyObservations: &historyObservations, coverage: &coverage)
            }
            appendHistoryScope(for: root, coverage: coverage, to: &historyScopes)
        }

        resources.sort { $0.id < $1.id }
        var seenProvenanceIDs = Set<String>()
        provenance = provenance.filter { seenProvenanceIDs.insert($0.id).inserted }
        provenance.sort { $0.id < $1.id }
        var seenProjectIDs = Set<String>()
        projects = projects.filter { seenProjectIDs.insert($0.id).inserted }
        projects.sort { $0.id < $1.id }
        var seenRelationIDs = Set<String>()
        relations = relations.filter { seenRelationIDs.insert($0.id).inserted }
        var seenPairings = Set<CapabilityAgentPairing>()
        agentPairings = agentPairings.filter { seenPairings.insert($0).inserted }
        var seenObservationIDs = Set<String>()
        let uniqueHistoryObservations = historyObservations.filter {
            seenObservationIDs.insert($0.resourceID).inserted
        }
        var scopeByRootID: [String: CapabilityHistoryScanScope] = [:]
        for scope in historyScopes {
            if let existing = scopeByRootID[scope.rootID] {
                let compatible = existing.scope == scope.scope && existing.rootKind == scope.rootKind
                scopeByRootID[scope.rootID] = CapabilityHistoryScanScope(
                    rootID: scope.rootID,
                    scope: existing.scope,
                    rootKind: existing.rootKind,
                    coverage: compatible
                        ? existing.coverage.dominating(with: scope.coverage)
                        : .partial
                )
            } else {
                scopeByRootID[scope.rootID] = scope
            }
        }
        let finalizedHistoryObservations = uniqueHistoryObservations
            .sorted { $0.resourceID < $1.resourceID }
            .map { $0.finalized(observedAt: nowProvider()) }
        // This timestamp proves the scanner finished validating the complete
        // set of scopes/candidates. Do not clamp a rolled-back wall clock;
        // Task 2's commit sequence is the monotonic ordering authority.
        let batchObservedAt = nowProvider()
        return DiscoveryOutput(
            resources: resources,
            issues: issues,
            provenance: provenance,
            projects: projects,
            relations: relations,
            agentPairings: agentPairings,
            historyScanBatch: CapabilityHistoryScanBatch(
                observedAt: batchObservedAt,
                scopes: scopeByRootID.values.sorted { $0.rootID < $1.rootID },
                observations: finalizedHistoryObservations
            )
        )
    }

    /// Production discovery path: non-project sources keep the established
    /// synchronous scanner, while every complete project read and physical
    /// alias calculation is isolated as one immutable gate job.
    func scanIsolatingProjectSources() async throws -> IsolatedResourceDiscovery {
        let nonProjectRoots = roots.filter { $0.kind != .projects }
        var outputs: [DiscoveryOutput] = []
        if !nonProjectRoots.isEmpty {
            outputs.append(scanner(for: nonProjectRoots).scan())
        }

        var physicalPaths: [ProjectSkillPhysicalPath] = []
        var unavailableRootIDs = Set<String>()
        for root in roots where root.kind == .projects {
            let job = await projectReadGate.perform(root: root) {
                scanner(for: [root]).projectScanJob(root: root)
            }
            switch job {
            case .success(let result):
                if result.physicalPathsComplete {
                    outputs.append(result.output)
                    physicalPaths.append(contentsOf: result.physicalPaths)
                } else {
                    // Physical identity is part of the guarded project job.
                    // Without it the fresh project result cannot safely join
                    // runtime alias de-duplication, so publish no fresh rows.
                    unavailableRootIDs.insert(root.id)
                    outputs.append(unavailableProjectOutput(for: root))
                }
            case .failure(.cancelled):
                throw CancellationError()
            case .failure:
                unavailableRootIDs.insert(root.id)
                outputs.append(unavailableProjectOutput(for: root))
            }
        }
        return IsolatedResourceDiscovery(
            output: merge(outputs),
            projectSkillPhysicalPaths: physicalPaths,
            unavailableProjectRootIDs: unavailableRootIDs
        )
    }

    private struct ProjectScanJobResult: Sendable {
        let output: DiscoveryOutput
        let physicalPaths: [ProjectSkillPhysicalPath]
        let physicalPathsComplete: Bool
    }

    private func projectScanJob(root: ScanRoot) -> ProjectScanJobResult {
        let output = scan()
        var physicalPaths: [ProjectSkillPhysicalPath] = []
        var physicalPathsComplete = true
        for resource in output.resources where resource.kind == .skill && resource.sourceRootID == root.id {
            guard let relative = resource.relativeSourcePath,
                  let physicalPath = projectPhysicalPathResolver(
                    root.url.appendingPathComponent(relative)
                  ),
                  !physicalPath.isEmpty else {
                physicalPathsComplete = false
                break
            }
            physicalPaths.append(ProjectSkillPhysicalPath(
                physicalPath: physicalPath,
                resourceID: resource.id
            ))
        }
        return ProjectScanJobResult(
            output: output,
            physicalPaths: physicalPaths,
            physicalPathsComplete: physicalPathsComplete
        )
    }

    private func scanner(for selectedRoots: [ScanRoot]) -> ResourceScanner {
        ResourceScanner(
            roots: selectedRoots,
            fileSystem: fileSystem,
            overrides: overrides,
            userOwnedSkillRegistrations: userOwnedSkillRegistrations,
            previousFingerprints: previousFingerprints,
            previousModified: previousModified,
            now: nowProvider,
            projectReadGate: projectReadGate,
            projectPhysicalPathResolver: projectPhysicalPathResolver,
            rootLogPosition: rootLogPosition
        )
    }

    private func unavailableProjectOutput(for root: ScanRoot) -> DiscoveryOutput {
        DiscoveryOutput(
            resources: [],
            issues: [DiscoveryIssue(
                rootID: root.id,
                relativePath: "",
                message: "Project source read is temporarily unavailable"
            )],
            projects: [CapabilityProject(
                id: root.id,
                name: root.url.lastPathComponent,
                available: false
            )],
            historyScanBatch: CapabilityHistoryScanBatch(
                observedAt: nowProvider(),
                scopes: [CapabilityHistoryScanScope(
                    rootID: root.id,
                    scope: root.scope,
                    rootKind: root.kind,
                    coverage: .unavailable
                )],
                observations: []
            )
        )
    }

    private func merge(_ outputs: [DiscoveryOutput]) -> DiscoveryOutput {
        var resources: [CapabilityResource] = []
        var issues: [DiscoveryIssue] = []
        var provenance: [CapabilityProvenance] = []
        var projects: [CapabilityProject] = []
        var relations: [ResourceRelation] = []
        var pairings: [CapabilityAgentPairing] = []
        var scopes: [CapabilityHistoryScanScope] = []
        var observations: [CapabilityHistoryObservation] = []
        for output in outputs {
            resources.append(contentsOf: output.resources)
            issues.append(contentsOf: output.issues)
            provenance.append(contentsOf: output.provenance)
            projects.append(contentsOf: output.projects)
            relations.append(contentsOf: output.relations)
            pairings.append(contentsOf: output.agentPairings)
            scopes.append(contentsOf: output.historyScanBatch.scopes)
            observations.append(contentsOf: output.historyScanBatch.observations)
        }

        resources = firstUnique(resources, by: \CapabilityResource.id).sorted { $0.id < $1.id }
        provenance = firstUnique(provenance, by: \CapabilityProvenance.id).sorted { $0.id < $1.id }
        projects = firstUnique(projects, by: \CapabilityProject.id).sorted { $0.id < $1.id }
        relations = firstUnique(relations, by: \ResourceRelation.id)
        pairings = firstUnique(pairings, by: { $0 })
        observations = firstUnique(observations, by: \CapabilityHistoryObservation.resourceID)

        var scopeByRootID: [String: CapabilityHistoryScanScope] = [:]
        for scope in scopes {
            if let existing = scopeByRootID[scope.rootID] {
                let compatible = existing.scope == scope.scope && existing.rootKind == scope.rootKind
                scopeByRootID[scope.rootID] = CapabilityHistoryScanScope(
                    rootID: existing.rootID,
                    scope: existing.scope,
                    rootKind: existing.rootKind,
                    coverage: compatible
                        ? existing.coverage.dominating(with: scope.coverage)
                        : .partial
                )
            } else {
                scopeByRootID[scope.rootID] = scope
            }
        }
        return DiscoveryOutput(
            resources: resources,
            issues: issues,
            provenance: provenance,
            projects: projects,
            relations: relations,
            agentPairings: pairings,
            historyScanBatch: CapabilityHistoryScanBatch(
                observedAt: nowProvider(),
                scopes: scopeByRootID.values.sorted { $0.rootID < $1.rootID },
                observations: observations.sorted { $0.resourceID < $1.resourceID }
            )
        )
    }

    private func firstUnique<Value, Key: Hashable>(
        _ values: [Value],
        by key: (Value) -> Key
    ) -> [Value] {
        var seen = Set<Key>()
        return values.filter { seen.insert(key($0)).inserted }
    }

    // MARK: - Skills

    private func scanSkills(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        provenance: inout [CapabilityProvenance],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        historyObservations: inout [PendingHistoryObservation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        let lockEntries = (Self.parseJSON(root.url.deletingLastPathComponent().appendingPathComponent(".skill-lock.json")) as? [String: Any])?["skills"] as? [String: Any] ?? [:]
        var discoveredNames = Set<String>()
        let rootDirectoryIdentity = fileSystem.directoryIdentity(root.url)
        let entries = safeEntries(in: root.url, root: root, issues: &issues, coverage: &coverage)
        let observationStart = historyObservations.count
        for entry in entries {
            guard isCapabilityDirectory(
                entry,
                root: root,
                issues: &issues,
                coverage: &coverage
            ) else { continue }
            let manifest = entry.appendingPathComponent("SKILL.md")
            guard let document = readOptionalTrackedDocument(
                manifest,
                root: root,
                issues: &issues,
                coverage: &coverage
            ) else { continue }
            let text = document.text
            let frontmatter = Frontmatter.parse(text)
            let schemaSupported = Self.schemaIsSupported(frontmatter.metadata["schema"])
            let manifestName = frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 }
            let name = manifestName ?? entry.lastPathComponent
            discoveredNames.insert(name)
            discoveredNames.insert(entry.lastPathComponent)
            let relative = "\(entry.lastPathComponent)/SKILL.md"
            let evidence = skillEvidence(
                name: name,
                entry: entry,
                root: root,
                resourceID: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                issues: &issues,
                manifestText: text,
                manifestData: document.data
            )
            guard validateTrackedDocuments(
                [document], root: root, issues: &issues, coverage: &coverage
            ) else { continue }

            if !schemaSupported {
                issues.append(DiscoveryIssue(
                    rootID: root.id, relativePath: relative, message: "Unknown manifest version")
                )
            }

            let resource = CapabilityResource(
                id: evidence.resourceID,
                name: name,
                kind: .skill,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: schemaSupported ? evidence.confidence : .unknown,
                summary: frontmatter.fields["description"],
                sourceRootID: root.id,
                relativeSourcePath: relative,
                sourcePathHash: Self.stableHash(relative),
                lastSeenAt: Date(),
                ownership: evidence.ownership,
                origin: evidence.origin,
                classificationConfidence: evidence.confidence,
                originIdentifier: evidence.sourceIdentifier,
                sourceVersion: evidence.version,
                contentFingerprint: evidence.fingerprint,
                sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                modified: evidence.modified
            )
            let canonicalID = resources.first(where: {
                $0.kind == resource.kind && $0.scope == resource.scope && $0.projectID == resource.projectID
                    && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == resource.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })?.id ?? resource.id
            add(resource, to: &resources, seen: &seen)
            if let record = evidence.provenance {
                provenance.append(Self.retarget(record, resourceID: canonicalID, disambiguator: root.id))
            }
            if Self.isHistoryTracked(root: root),
               evidence.ownership != .builtIn,
               let canonicalResource = resources.first(where: { $0.id == evidence.resourceID }) {
                historyObservations.append(PendingHistoryObservation(
                    resourceID: canonicalResource.id,
                    sourceRootID: root.id,
                    name: canonicalResource.name,
                    kind: canonicalResource.kind,
                    scope: canonicalResource.scope,
                    projectID: canonicalResource.projectID,
                    documents: [.skillManifest],
                    documentData: [.skillManifest: document.data]
                ))
            }
        }
        for key in lockEntries.keys.sorted() where !discoveredNames.contains(key) {
            issues.append(DiscoveryIssue(rootID: root.id, relativePath: ".skill-lock.json/\(key)", message: "Installed provenance could not be matched to a local Skill"))
        }
        if !directoryEntriesRemainStable(
            entries,
            in: root.url,
            root: root,
            issues: &issues,
            coverage: &coverage,
            initialIdentity: rootDirectoryIdentity
        ) {
            historyObservations.removeSubrange(observationStart...)
        }
    }

    // MARK: - Agents

    private func scanAgents(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        pairings: inout [CapabilityAgentPairing],
        historyObservations: inout [PendingHistoryObservation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        let rootDirectoryIdentity = fileSystem.directoryIdentity(root.url)
        let entries = safeEntries(in: root.url, root: root, issues: &issues, coverage: &coverage)
        let observationStart = historyObservations.count
        let pairingStart = pairings.count
        var briefRecords: [(entry: URL, relative: String, document: TrackedDocument, name: String)] = []
        var briefDirectorySnapshots: [(directory: URL, entries: [URL], identity: FileSystemDocumentIdentity?)] = []
        for entry in entries {
            guard isCapabilityDirectory(
                entry,
                root: root,
                issues: &issues,
                coverage: &coverage
            ) else { continue }
            let directoryIdentity = fileSystem.directoryIdentity(entry)
            let childEntries = safeEntries(in: entry, root: root, issues: &issues, coverage: &coverage)
            briefDirectorySnapshots.append((entry, childEntries, directoryIdentity))
            let brief = ["agent.md", "Agent.md", "AGENTS.md"].compactMap { name in
                childEntries.first { $0.lastPathComponent == name }
            }.first
            guard let brief,
                  let document = readTrackedDocument(brief, root: root, issues: &issues, coverage: &coverage) else { continue }
            let text = document.text
            let name = Self.firstHeading(in: text) ?? entry.lastPathComponent
            briefRecords.append((entry, "\(entry.lastPathComponent)/\(brief.lastPathComponent)", document, name))
        }
        let tomlEntries = entries.filter { $0.pathExtension.lowercased() == "toml" }
        var tomlRecords: [(entry: URL, document: TrackedDocument)] = []
        for entry in tomlEntries {
            if let document = readTrackedDocument(entry, root: root, issues: &issues, coverage: &coverage) {
                tomlRecords.append((entry, document))
            }
        }
        var pairedBriefPaths = Set<String>()
        var pairedBriefByTOMLPath: [String: (relative: String, document: TrackedDocument)] = [:]

        // A global Agent's callable `<role>.toml` and `<role>/agent.md` are
        // one logical capability. Pair only a unique exact normalized name;
        // ambiguity remains two legacy resources rather than guessing.
        for record in tomlRecords {
            let entry = record.entry
            let text = record.document.text
            let manifest = Self.parseTopLevelAgentTOML(text)
            let tomlNames = Set([manifest.name, entry.deletingPathExtension().lastPathComponent]
                .compactMap { $0 }
                .map(Self.normalizedAgentName))
            let matches = briefRecords.filter { record in
                let briefNames = Set([record.name, record.entry.lastPathComponent].map(Self.normalizedAgentName))
                return !tomlNames.isDisjoint(with: briefNames)
            }
            if matches.count == 1, let match = matches.first {
                pairedBriefPaths.insert(match.entry.path)
                pairedBriefByTOMLPath[entry.path] = (match.relative, match.document)
            }
        }

        // Global Agent libraries commonly keep the callable TOML beside its
        // Brief directory. Preserve the historical Brief path and stable ID
        // as the logical Agent identity while retaining both documents for
        // fingerprints and ephemeral companion declaration resolution.
        for record in tomlRecords {
            let entry = record.entry
            let paired = pairedBriefByTOMLPath[entry.path]
            let relative = paired?.relative ?? entry.lastPathComponent
            let text = record.document.text
            let manifest = Self.parseTopLevelAgentTOML(text)
            let fingerprintText = [text, paired?.document.text].compactMap { $0 }.joined(separator: "\n")
            let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
            let fingerprint = Self.stableHash(fingerprintText)
            let modified = previousModified[resourceID] == true
                || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
            let summary = manifest.description ?? paired.flatMap { Self.agentPurpose(in: $0.document.text) }
            let modifiedAt = [fileSystem.fileAttributes(entry), paired.flatMap { fileSystem.fileAttributes(root.url.appendingPathComponent($0.relative)) }]
                .compactMap { $0?.modificationDate }
                .map(Date.init(timeIntervalSince1970:))
                .max()
            let documentsStable = validateTrackedDocuments(
                [record.document] + [paired?.document].compactMap { $0 },
                root: root,
                issues: &issues,
                coverage: &coverage
            )
            guard documentsStable else { continue }
            add(CapabilityResource(
                id: resourceID,
                name: manifest.name ?? entry.deletingPathExtension().lastPathComponent,
                kind: .agent,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: .exact,
                summary: summary,
                sourceRootID: root.id,
                relativeSourcePath: relative,
                sourcePathHash: Self.stableHash(relative),
                lastSeenAt: Date(),
                contentFingerprint: fingerprint,
                sourceModifiedAt: modifiedAt,
                modified: modified
            ), to: &resources, seen: &seen)
            if let paired {
                pairings.append(CapabilityAgentPairing(
                    sourceRootID: root.id,
                    agentRelativePath: paired.relative,
                    briefRelativePath: paired.relative,
                    configurationRelativePath: entry.lastPathComponent
                ))
            }
            if Self.isHistoryTracked(root: root),
               documentsStable,
               let logical = resources.first(where: { $0.id == resourceID }) {
                var documentData: [CapabilityTrackedDocument: Data] = [.agentConfiguration: record.document.data]
                if let paired { documentData[.agentBrief] = paired.document.data }
                historyObservations.append(PendingHistoryObservation(
                    resourceID: logical.id,
                    sourceRootID: root.id,
                    name: logical.name,
                    kind: logical.kind,
                    scope: logical.scope,
                    projectID: logical.projectID,
                    documents: Set(documentData.keys),
                    documentData: documentData
                ))
            }
        }
        for record in briefRecords where !pairedBriefPaths.contains(record.entry.path) {
            let name = record.name
            let relative = record.relative
            let text = record.document.text
            let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
            let fingerprint = Self.stableHash(text)
            let modified = previousModified[resourceID] == true
                || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
            let purpose = Self.agentPurpose(in: text)
            guard validateTrackedDocuments(
                [record.document], root: root, issues: &issues, coverage: &coverage
            ) else { continue }

            let resource = CapabilityResource(
                id: resourceID,
                name: name,
                kind: .agent,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: .exact,
                summary: purpose,
                sourceRootID: root.id,
                relativeSourcePath: relative,
                sourcePathHash: Self.stableHash(relative),
                lastSeenAt: Date(),
                contentFingerprint: fingerprint,
                sourceModifiedAt: fileSystem.fileAttributes(record.entry.appendingPathComponent(relative.split(separator: "/").last.map(String.init) ?? "agent.md"))
                    .map { Date(timeIntervalSince1970: $0.modificationDate) },
                modified: modified
            )
            add(resource, to: &resources, seen: &seen)
            if Self.isHistoryTracked(root: root),
               let logical = resources.first(where: { $0.id == resourceID }) {
                historyObservations.append(PendingHistoryObservation(
                    resourceID: logical.id,
                    sourceRootID: root.id,
                    name: logical.name,
                    kind: logical.kind,
                    scope: logical.scope,
                    projectID: logical.projectID,
                    documents: [.agentBrief],
                    documentData: [.agentBrief: record.document.data]
                ))
            }
        }
        let rootStable = directoryEntriesRemainStable(
            entries,
            in: root.url,
            root: root,
            issues: &issues,
            coverage: &coverage,
            initialIdentity: rootDirectoryIdentity
        )
        var briefDirectoriesStable = true
        for snapshot in briefDirectorySnapshots {
            if !directoryEntriesRemainStable(
                snapshot.entries,
                in: snapshot.directory,
                root: root,
                issues: &issues,
                coverage: &coverage,
                initialIdentity: snapshot.identity
            ) {
                briefDirectoriesStable = false
            }
        }
        if !rootStable || !briefDirectoriesStable {
            historyObservations.removeSubrange(observationStart...)
            pairings.removeSubrange(pairingStart...)
        }
    }

    // MARK: - Plugins

    private func scanPlugins(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        findPluginDirs(in: root.url, depth: 0, maxDepth: 6, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations, coverage: &coverage)
    }

    private func findPluginDirs(
        in directory: URL,
        depth: Int,
        maxDepth: Int,
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        guard depth <= maxDepth else { return }
        for entry in safeEntries(in: directory, root: root, issues: &issues, coverage: &coverage) {
            let marker = entry.appendingPathComponent(".codex-plugin")
            if fileSystem.exists(marker) {
                scanPluginDir(entry, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations, coverage: &coverage)
            } else if fileSystem.isDirectory(entry) {
                findPluginDirs(in: entry, depth: depth + 1, maxDepth: maxDepth, root: root, resources: &resources, issues: &issues, seen: &seen, relations: &relations, coverage: &coverage)
            }
        }
    }

    private func scanPluginDir(
        _ directory: URL,
        root: ScanRoot,
        resources: inout [CapabilityResource],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        relations: inout [ResourceRelation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        let pluginRelative = Self.relativePath(of: directory, under: root.url)
        let name = directory.lastPathComponent

        let pluginID = Self.stableID(kind: .plugin, scope: root.scope, rootID: root.id, relative: pluginRelative)
        add(CapabilityResource(
            id: pluginID,
            name: name,
            kind: .plugin,
            status: .unknown,
            scope: root.scope,
            projectID: nil,
            confidence: .exact,
            summary: "Plugin (\(pluginRelative))",
            sourceRootID: root.id,
            relativeSourcePath: pluginRelative,
            sourcePathHash: Self.stableHash(pluginRelative),
            lastSeenAt: Date()
        ), to: &resources, seen: &seen)

        // Apps (.app.json -> apps[]).
        let appManifest = directory.appendingPathComponent(".app.json")
        if fileSystem.exists(appManifest), let json = Self.parseJSON(appManifest) as? [String: Any],
           let apps = json["apps"] as? [[String: Any]] {
            for app in apps {
                let appName = (app["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "app"
                add(CapabilityResource(
                    id: Self.stableID(kind: .app, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.app.json/" + appName),
                    name: appName,
                    kind: .app,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: app["description"] as? String,
                    sourceRootID: root.id,
                    relativeSourcePath: pluginRelative + "/.app.json",
                    sourcePathHash: Self.stableHash(pluginRelative + "/.app.json/" + appName),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .app, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.app.json/" + appName), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
            }
        }

        // MCP servers (.mcp.json -> mcpServers keys).
        let mcpManifest = directory.appendingPathComponent(".mcp.json")
        if fileSystem.exists(mcpManifest), let json = Self.parseJSON(mcpManifest) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            for serverName in servers.keys.sorted() {
                add(CapabilityResource(
                    id: Self.stableID(kind: .mcp, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.mcp.json/" + serverName),
                    name: serverName,
                    kind: .mcp,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: "MCP server",
                    sourceRootID: root.id,
                    relativeSourcePath: pluginRelative + "/.mcp.json",
                    sourcePathHash: Self.stableHash(pluginRelative + "/.mcp.json/" + serverName),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .mcp, scope: root.scope, rootID: root.id, relative: pluginRelative + "/.mcp.json/" + serverName), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
            }
        }

        // Hooks (hooks.json).
        let hooksManifest = directory.appendingPathComponent("hooks.json")
        if fileSystem.exists(hooksManifest) {
            add(CapabilityResource(
                id: Self.stableID(kind: .hook, scope: root.scope, rootID: root.id, relative: pluginRelative + "/hooks.json"),
                name: "hooks",
                kind: .hook,
                status: .unknown,
                scope: root.scope,
                projectID: nil,
                confidence: .exact,
                summary: "Plugin hooks",
                sourceRootID: root.id,
                relativeSourcePath: pluginRelative + "/hooks.json",
                sourcePathHash: Self.stableHash(pluginRelative + "/hooks.json"),
                lastSeenAt: Date()
            ), to: &resources, seen: &seen)
            relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: Self.stableID(kind: .hook, scope: root.scope, rootID: root.id, relative: pluginRelative + "/hooks.json"), relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin manifest"))
        }

        // Plugin-scoped skills and agents.
        let skillsDir = directory.appendingPathComponent("skills")
        if fileSystem.isDirectory(skillsDir) {
            for entry in safeEntries(in: skillsDir, root: root, issues: &issues, coverage: &coverage) where fileSystem.isDirectory(entry) {
                let manifest = entry.appendingPathComponent("SKILL.md")
                guard fileSystem.exists(manifest) else { continue }
                let relative = pluginRelative + "/skills/\(entry.lastPathComponent)/SKILL.md"
                let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
                let frontmatter = Frontmatter.parse(text)
                let resourceID = Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                add(CapabilityResource(
                    id: resourceID,
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    kind: .skill,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: frontmatter.fields["description"],
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: resourceID, relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin skill"))
            }
        }

        let agentsDir = directory.appendingPathComponent("agents")
        if fileSystem.isDirectory(agentsDir) {
            for entry in safeEntries(in: agentsDir, root: root, issues: &issues, coverage: &coverage) where fileSystem.isDirectory(entry) {
                let brief = entry.appendingPathComponent("agent.md")
                guard fileSystem.exists(brief) else { continue }
                let relative = pluginRelative + "/agents/\(entry.lastPathComponent)/agent.md"
                let text = (try? String(contentsOf: brief, encoding: .utf8)) ?? ""
                let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                add(CapabilityResource(
                    id: resourceID,
                    name: entry.lastPathComponent,
                    kind: .agent,
                    status: .unknown,
                    scope: root.scope,
                    projectID: nil,
                    confidence: .exact,
                    summary: Self.agentPurpose(in: text),
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(brief).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
                relations.append(ResourceRelation(sourceResourceID: pluginID, targetResourceID: resourceID, relationKind: "contains", confidence: .exact, evidenceSummary: "Plugin agent"))
            }
        }
    }

    // MARK: - Projects

    private func scanProject(
        root: ScanRoot,
        resources: inout [CapabilityResource],
        provenance: inout [CapabilityProvenance],
        projects: inout [CapabilityProject],
        issues: inout [DiscoveryIssue],
        seen: inout Set<String>,
        pairings: inout [CapabilityAgentPairing],
        historyObservations: inout [PendingHistoryObservation],
        coverage: inout CapabilityHistoryCoverage
    ) {
        let projectObservationStart = historyObservations.count
        let projectPairingStart = pairings.count
        let rootDirectoryIdentity = fileSystem.directoryIdentity(root.url)
        let rootEntries = safeEntries(in: root.url, root: root, issues: &issues, coverage: &coverage)
        let projectName = root.url.lastPathComponent
        projects.append(CapabilityProject(id: root.id, name: projectName, available: true))

        // Project AGENTS.md brief.
        if rootEntries.contains(where: { $0.lastPathComponent == "AGENTS.md" }) {
            add(CapabilityResource(
                id: Self.stableID(kind: .instruction, scope: root.scope, rootID: root.id, relative: "AGENTS.md"),
                name: projectName,
                kind: .instruction,
                status: .unknown,
                scope: root.scope,
                projectID: root.id,
                confidence: .exact,
                summary: "Project instructions (AGENTS.md)",
                sourceRootID: root.id,
                relativeSourcePath: "AGENTS.md",
                sourcePathHash: Self.stableHash("AGENTS.md"),
                lastSeenAt: Date(),
                ownership: .userOwned,
                origin: .local,
                classificationConfidence: .exact
            ), to: &resources, seen: &seen)
        }

        // Project skills: .agents/skills/*/SKILL.md
        let projectSkills = root.url.appendingPathComponent(".agents/skills")
        let projectSkillsIdentity = fileSystem.directoryIdentity(projectSkills)
        if let skillEntries = optionalEntries(
            in: projectSkills,
            root: root,
            issues: &issues,
            coverage: &coverage
        ) {
            let observationStart = historyObservations.count
            for entry in skillEntries {
                guard isCapabilityDirectory(
                    entry,
                    root: root,
                    issues: &issues,
                    coverage: &coverage
                ) else { continue }
                let manifest = entry.appendingPathComponent("SKILL.md")
                let relative = ".agents/skills/\(entry.lastPathComponent)/SKILL.md"
                guard let document = readOptionalTrackedDocument(
                    manifest,
                    root: root,
                    issues: &issues,
                    coverage: &coverage
                ) else { continue }
                let text = document.text
                let frontmatter = Frontmatter.parse(text)
                let evidence = skillEvidence(
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    entry: entry,
                    root: root,
                    resourceID: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                    issues: &issues,
                    manifestText: text,
                    manifestData: document.data
                )
                guard validateTrackedDocuments(
                    [document], root: root, issues: &issues, coverage: &coverage
                ) else { continue }
                add(CapabilityResource(
                    id: Self.stableID(kind: .skill, scope: root.scope, rootID: root.id, relative: relative),
                    name: frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent,
                    kind: .skill,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: .exact,
                    summary: frontmatter.fields["description"],
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    ownership: evidence.ownership,
                    origin: evidence.origin,
                    classificationConfidence: evidence.confidence,
                    originIdentifier: evidence.sourceIdentifier,
                    sourceVersion: evidence.version,
                    contentFingerprint: evidence.fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(manifest).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: evidence.modified
                ), to: &resources, seen: &seen)
                let canonicalID = resources.first(where: {
                    $0.kind == .skill && $0.scope == root.scope && $0.projectID == root.id
                        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == (frontmatter.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })?.id ?? evidence.resourceID
                if let record = evidence.provenance { provenance.append(Self.retarget(record, resourceID: canonicalID, disambiguator: root.id)) }
                if evidence.ownership != .builtIn,
                   let logical = resources.first(where: { $0.id == evidence.resourceID }) {
                    historyObservations.append(PendingHistoryObservation(
                        resourceID: logical.id,
                        sourceRootID: root.id,
                        name: logical.name,
                        kind: logical.kind,
                        scope: logical.scope,
                        projectID: logical.projectID,
                        documents: [.skillManifest],
                        documentData: [.skillManifest: document.data]
                    ))
                }
            }
            if !directoryEntriesRemainStable(
                   skillEntries,
                   in: projectSkills,
                   root: root,
                   issues: &issues,
                   coverage: &coverage,
                   missingIsEmpty: true,
                   initialIdentity: projectSkillsIdentity
               ) {
                historyObservations.removeSubrange(observationStart...)
            }
        }

        // Project agents: .codex/agents/*.toml
        let projectAgents = root.url.appendingPathComponent(".codex/agents")
        let projectAgentsIdentity = fileSystem.directoryIdentity(projectAgents)
        if let agentEntries = optionalEntries(
            in: projectAgents,
            root: root,
            issues: &issues,
            coverage: &coverage
        ) {
            let observationStart = historyObservations.count
            for entry in agentEntries where entry.pathExtension == "toml" {
                let relative = ".codex/agents/\(entry.lastPathComponent)"
                guard let document = readTrackedDocument(entry, root: root, issues: &issues, coverage: &coverage) else { continue }
                let text = document.text
                let resourceID = Self.stableID(kind: .agent, scope: root.scope, rootID: root.id, relative: relative)
                let fingerprint = Self.stableHash(text)
                let modified = previousModified[resourceID] == true
                    || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
                let manifest = Self.parseTopLevelAgentTOML(text)
                guard validateTrackedDocuments(
                    [document], root: root, issues: &issues, coverage: &coverage
                ) else { continue }
                // Keep the historical TOML identity; the Brief is an alias,
                // not a new capability. Only an existing bounded companion
                // directory with a unique matching name is paired.
                let briefDirectory = entry.deletingPathExtension()
                var briefCandidates: [URL] = []
                var briefDirectoryEntries: [URL]?
                var briefDirectoryReliable = true
                let briefDirectoryIdentity = fileSystem.directoryIdentity(briefDirectory)
                if fileSystem.isSymbolicLink(briefDirectory),
                   !Self.isWithinRoot(briefDirectory, rootURL: root.url) {
                    coverage = coverage.dominating(with: .partial)
                    issues.append(DiscoveryIssue(
                        rootID: root.id,
                        relativePath: Self.relativePath(of: briefDirectory, under: root.url),
                        message: "Symlink escapes approved root; skipped"
                    ))
                    briefDirectoryReliable = false
                } else if let entries = optionalEntries(
                    in: briefDirectory,
                    root: root,
                    issues: &issues,
                    coverage: &coverage
                ) {
                    // Enumerate actual entries: on case-insensitive APFS,
                    // exists(agent.md) and exists(Agent.md) can be the same file.
                    briefDirectoryEntries = entries
                    briefCandidates = entries.filter {
                        ["agent.md", "Agent.md"].contains($0.lastPathComponent)
                    }
                    if briefCandidates.count > 1 {
                        coverage = coverage.dominating(with: .partial)
                        issues.append(DiscoveryIssue(
                            rootID: root.id,
                            relativePath: Self.relativePath(of: briefDirectory, under: root.url),
                            message: "Agent Brief pairing is ambiguous"
                        ))
                        briefDirectoryReliable = false
                    }
                } else {
                    briefDirectoryReliable = false
                }
                add(CapabilityResource(
                    id: resourceID,
                    name: manifest.name ?? entry.deletingPathExtension().lastPathComponent,
                    kind: .agent,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: .exact,
                    summary: manifest.description,
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date(),
                    contentFingerprint: fingerprint,
                    sourceModifiedAt: fileSystem.fileAttributes(entry).map { Date(timeIntervalSince1970: $0.modificationDate) },
                    modified: modified
                ), to: &resources, seen: &seen)
                if let logical = resources.first(where: { $0.id == resourceID }) {
                    var documentData: [CapabilityTrackedDocument: Data] = [.agentConfiguration: document.data]
                    var trackedDocuments = [document]
                    var trackedDocumentSetReliable = briefDirectoryReliable
                    let pairedBrief = briefCandidates.count == 1 ? briefCandidates.first : nil
                    if let brief = pairedBrief {
                        if let briefDocument = readTrackedDocument(brief, root: root, issues: &issues, coverage: &coverage) {
                            documentData[.agentBrief] = briefDocument.data
                            trackedDocuments.append(briefDocument)
                        } else {
                            trackedDocumentSetReliable = false
                        }
                    }
                    let briefDirectoryStable: Bool
                    if let briefDirectoryEntries {
                        briefDirectoryStable = directoryEntriesRemainStable(
                            briefDirectoryEntries,
                            in: briefDirectory,
                            root: root,
                            issues: &issues,
                            coverage: &coverage,
                            missingIsEmpty: true,
                            initialIdentity: briefDirectoryIdentity
                        )
                    } else {
                        briefDirectoryStable = briefDirectoryReliable
                    }
                    let documentsStable = trackedDocumentSetReliable
                        && validateTrackedDocuments(trackedDocuments, root: root, issues: &issues, coverage: &coverage)
                    if documentsStable, briefDirectoryStable, let pairedBrief {
                        pairings.append(CapabilityAgentPairing(
                            sourceRootID: root.id,
                            agentRelativePath: relative,
                            briefRelativePath: ".codex/agents/\(briefDirectory.lastPathComponent)/\(pairedBrief.lastPathComponent)",
                            configurationRelativePath: relative
                        ))
                    }
                    if documentsStable,
                       briefDirectoryStable {
                        historyObservations.append(PendingHistoryObservation(
                            resourceID: logical.id,
                            sourceRootID: root.id,
                            name: logical.name,
                            kind: logical.kind,
                            scope: logical.scope,
                            projectID: logical.projectID,
                            documents: Set(documentData.keys),
                            documentData: documentData
                        ))
                    }
                }
            }
            if !directoryEntriesRemainStable(
                   agentEntries,
                   in: projectAgents,
                   root: root,
                   issues: &issues,
                   coverage: &coverage,
                   missingIsEmpty: true,
                   initialIdentity: projectAgentsIdentity
               ) {
                historyObservations.removeSubrange(observationStart...)
                pairings.removeSubrange(projectPairingStart...)
            }
        }

        // Project registry: prefer agents/registry.json. The root-level file
        // is a legacy compatibility location and may be read only when the
        // primary path is genuinely absent, never when it is invalid,
        // unsupported, unreadable, oversized or unstable.
        let primaryRegistry = root.url.appendingPathComponent("agents/registry.json")
        let primaryRegistryRead = fileSystem.readVerifiedData(
            primaryRegistry,
            within: root.url,
            maximumByteCount: CodexProjectRegistry.maximumByteCount
        )
        let registrySelection: (
            url: URL,
            relativePath: String,
            read: Result<FileSystemDocumentRead, FileSystemReadError>
        )
        if case .failure(.notFound) = primaryRegistryRead {
            let compatibilityRegistry = root.url.appendingPathComponent("registry.json")
            registrySelection = (
                compatibilityRegistry,
                "registry.json",
                fileSystem.readVerifiedData(
                    compatibilityRegistry,
                    within: root.url,
                    maximumByteCount: CodexProjectRegistry.maximumByteCount
                )
            )
        } else {
            registrySelection = (primaryRegistry, "agents/registry.json", primaryRegistryRead)
        }
        switch registrySelection.read {
        case .failure(.notFound):
            break
        case .failure(let error):
            coverage = coverage.dominating(with: error == .changedDuringRead ? .unstable : .partial)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: registrySelection.relativePath,
                message: "Project registry read failed: \(error.rawValue)"
            ))
        case .success(let read):
            guard fileSystem.validateDocumentRead(read, at: registrySelection.url, within: root.url) else {
                coverage = coverage.dominating(with: .unstable)
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: registrySelection.relativePath,
                    message: "Project registry changed during scan"
                ))
                break
            }
            let parsedRegistry = CodexProjectRegistry.parse(read.data)
            guard case .success(let document) = parsedRegistry else {
                coverage = coverage.dominating(with: .partial)
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: registrySelection.relativePath,
                    message: {
                        switch parsedRegistry {
                        case .unsupportedVersion:
                            return "Project registry schema version is unsupported"
                        case .invalid, .success:
                            return "Project registry is invalid or changed during scan"
                        }
                    }()
                ))
                break
            }
            for entry in document.legacyEntries {
                let name = entry.name
                let kind: ResourceKind
                switch entry.kind {
                case .unspecified, .agent:
                    kind = .agent
                case .workflow:
                    kind = .workflow
                case .skill, .unsupported:
                    continue
                }
                let relative = "\(registrySelection.relativePath)/\(name)"
                add(CapabilityResource(
                    id: Self.stableID(kind: kind, scope: root.scope, rootID: root.id, relative: relative),
                    name: name,
                    kind: kind,
                    status: .unknown,
                    scope: root.scope,
                    projectID: root.id,
                    confidence: .exact,
                    summary: entry.description,
                    sourceRootID: root.id,
                    relativeSourcePath: relative,
                    sourcePathHash: Self.stableHash(relative),
                    lastSeenAt: Date()
                ), to: &resources, seen: &seen)
            }
        }

        if !directoryEntriesRemainStable(
            rootEntries,
            in: root.url,
            root: root,
            issues: &issues,
            coverage: &coverage,
            initialIdentity: rootDirectoryIdentity
        ) {
            historyObservations.removeSubrange(projectObservationStart...)
            pairings.removeSubrange(projectPairingStart...)
        }
    }

    // MARK: - Helpers

    private struct SkillEvidence {
        let resourceID: String
        let ownership: ResourceOwnership
        let origin: ResourceOrigin
        let confidence: EvidenceConfidence
        let sourceIdentifier: String?
        let version: String?
        let fingerprint: String
        let modified: Bool
        let provenance: CapabilityProvenance?
    }

    /// Resolves classification and local provenance only. No network, `gh`,
    /// credential store, or full source URL is consulted.
    private func skillEvidence(
        name: String,
        entry: URL,
        root: ScanRoot,
        resourceID: String,
        issues: inout [DiscoveryIssue],
        manifestText: String,
        manifestData: Data
    ) -> SkillEvidence {
        let fingerprint = Self.stableHash(manifestText)
        let modified = previousModified[resourceID] == true
            || (previousFingerprints[resourceID].map { $0 != fingerprint } ?? false)
        let system = root.scope == .system
            || entry.resolvingSymlinksInPath().standardizedFileURL.pathComponents.contains(".system")
        if system {
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .builtIn,
                origin: .codexSystem,
                confidence: .exact,
                sourceIdentifier: "codex-system",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":system",
                    resourceID: resourceID,
                    sourceType: .codexSystem,
                    sourceIdentifier: "codex-system",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact
                )
            )
        }

        let installed = installedSkillEvidence(
            name: name,
            entry: entry,
            root: root,
            resourceID: resourceID,
            fingerprint: fingerprint,
            modified: modified
        )
        let manifestRelativePath = Self.relativePath(of: entry.appendingPathComponent("SKILL.md"), under: root.url)
        let registration = SkillOwnershipRegistration(rootID: root.id, relativeManifestPath: manifestRelativePath)
        if userOwnedSkillRegistrations.contains(registration) {
            if installed != nil {
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: manifestRelativePath,
                    message: "Explicit user-owned registration conflicts with installed provenance; registration wins"
                ))
            }
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .userOwned,
                origin: .local,
                confidence: .exact,
                sourceIdentifier: "global-skill-library",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":local-registration",
                    resourceID: resourceID,
                    sourceType: .local,
                    sourceIdentifier: "global-skill-library",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact,
                    modified: modified
                )
            )
        }

        if let installed { return installed }

        if root.scope == .project {
            return SkillEvidence(
                resourceID: resourceID,
                ownership: .userOwned,
                origin: .local,
                confidence: .exact,
                sourceIdentifier: "project-skill-directory",
                version: nil,
                fingerprint: fingerprint,
                modified: modified,
                provenance: CapabilityProvenance(
                    id: resourceID + ":project-local",
                    resourceID: resourceID,
                    sourceType: .local,
                    sourceIdentifier: "project-skill-directory",
                    version: nil,
                    installedAt: nil,
                    updatedAt: nil,
                    confidence: .exact,
                    modified: modified
                )
            )
        }

        return SkillEvidence(
            resourceID: resourceID,
            ownership: .installed,
            origin: .unknown,
            confidence: .inferred,
            sourceIdentifier: nil,
            version: nil,
            fingerprint: fingerprint,
            modified: modified,
            provenance: CapabilityProvenance(
                id: resourceID + ":unknown",
                resourceID: resourceID,
                sourceType: .unknown,
                sourceIdentifier: nil,
                version: nil,
                installedAt: nil,
                updatedAt: nil,
                confidence: .inferred,
                modified: modified
            )
        )
    }

    private func installedSkillEvidence(
        name: String,
        entry: URL,
        root: ScanRoot,
        resourceID: String,
        fingerprint: String,
        modified: Bool
    ) -> SkillEvidence? {
        for lockURL in skillLockURLs(for: root) {
            guard let lock = Self.parseJSON(lockURL) as? [String: Any],
                  let entries = lock["skills"] as? [String: Any] else { continue }
            let candidates = [name, entry.lastPathComponent]
            for key in candidates {
                guard let item = entries[key] as? [String: Any] else { continue }
                let sourceType = (item["sourceType"] as? String)?.lowercased() == "github" ? ResourceOrigin.github : .registry
                let source = Self.safeSourceIdentifier(item["source"] as? String)
                let installedAt = Self.parseDate(item["installedAt"])
                let updatedAt = Self.parseDate(item["updatedAt"])
                let record = CapabilityProvenance(
                    id: resourceID + ":" + sourceType.rawValue,
                    resourceID: resourceID,
                    sourceType: sourceType,
                    sourceIdentifier: source,
                    version: item["version"] as? String,
                    installedAt: installedAt,
                    updatedAt: updatedAt,
                    confidence: .exact,
                    modified: modified
                )
                return SkillEvidence(resourceID: resourceID, ownership: .installed, origin: sourceType, confidence: .exact, sourceIdentifier: source, version: item["version"] as? String, fingerprint: fingerprint, modified: modified, provenance: record)
            }
        }

        let meta = entry.appendingPathComponent("_meta.json")
        if let json = Self.parseJSON(meta) as? [String: Any],
           let slug = (json["slug"] as? String).flatMap({ Self.safeSourceIdentifier($0) }) {
            let version = json["version"] as? String
            let record = CapabilityProvenance(
                id: resourceID + ":registry",
                resourceID: resourceID,
                sourceType: .registry,
                sourceIdentifier: slug,
                version: version,
                installedAt: nil,
                updatedAt: nil,
                confidence: .exact,
                modified: modified
            )
            return SkillEvidence(resourceID: resourceID, ownership: .installed, origin: .registry, confidence: .exact, sourceIdentifier: slug, version: version, fingerprint: fingerprint, modified: modified, provenance: record)
        }
        return nil
    }

    private func skillLockURLs(for root: ScanRoot) -> [URL] {
        if root.kind == .projects {
            return [
                root.url.appendingPathComponent(".agents/.skill-lock.json"),
                root.url.appendingPathComponent(".skill-lock.json"),
            ]
        }
        return [root.url.deletingLastPathComponent().appendingPathComponent(".skill-lock.json")]
    }

    private struct TrackedDocument {
        let url: URL
        let text: String
        let read: FileSystemDocumentRead

        var data: Data { read.data }
    }

    private func readTrackedDocument(
        _ url: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> TrackedDocument? {
        let relative = Self.relativePath(of: url, under: root.url)
        switch fileSystem.readVerifiedData(
            url,
            within: root.url,
            maximumByteCount: Self.maximumTrackedDocumentBytes
        ) {
        case .success(let read):
            guard let text = String(data: read.data, encoding: .utf8) else {
                coverage = coverage.dominating(with: .partial)
                issues.append(DiscoveryIssue(rootID: root.id, relativePath: relative, message: "Document is not valid UTF-8"))
                return nil
            }
            return TrackedDocument(url: url, text: text, read: read)
        case .failure(let error):
            coverage = coverage.dominating(with: error == .changedDuringRead ? .unstable : .partial)
            issues.append(DiscoveryIssue(rootID: root.id, relativePath: relative, message: "Document read failed: \(error.rawValue)"))
            return nil
        }
    }

    /// Reads an optional tracked document without collapsing an access error
    /// into ordinary absence. A verified ENOENT means the enclosing directory
    /// is not a capability; every other failure limits scope completeness.
    private func readOptionalTrackedDocument(
        _ url: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> TrackedDocument? {
        let relative = Self.relativePath(of: url, under: root.url)
        switch fileSystem.readVerifiedData(
            url,
            within: root.url,
            maximumByteCount: Self.maximumTrackedDocumentBytes
        ) {
        case .failure(.notFound):
            return nil
        case .failure(let error):
            coverage = coverage.dominating(with: error == .changedDuringRead ? .unstable : .partial)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: relative,
                message: "Document read failed: \(error.rawValue)"
            ))
            return nil
        case .success(let read):
            guard let text = String(data: read.data, encoding: .utf8) else {
                coverage = coverage.dominating(with: .partial)
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: relative,
                    message: "Document is not valid UTF-8"
                ))
                return nil
            }
            return TrackedDocument(url: url, text: text, read: read)
        }
    }

    private func validateTrackedDocuments(
        _ documents: [TrackedDocument],
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> Bool {
        for document in documents where !fileSystem.validateDocumentRead(
            document.read,
            at: document.url,
            within: root.url
        ) {
            coverage = coverage.dominating(with: .unstable)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: document.url, under: root.url),
                message: "Document changed before observation was published"
            ))
            return false
        }
        return true
    }

    private func safeEntries(
        in directory: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> [URL] {
        let entries: [URL]
        switch fileSystem.enumerateDirectory(directory) {
        case .success(let value):
            entries = value
        case .failure(let error):
            coverage = coverage.dominating(with: .partial)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: directory, under: root.url),
                message: "Directory enumeration failed: \(error.rawValue)"
            ))
            return []
        }
        return filterApprovedEntries(entries, root: root, issues: &issues, coverage: &coverage)
    }

    /// A missing optional child under a verified project root is a known empty
    /// child scope. Every other enumeration failure makes the parent scope
    /// incomplete and must not become absence evidence.
    private func optionalEntries(
        in directory: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> [URL]? {
        switch fileSystem.enumerateDirectory(directory) {
        case .success(let entries):
            return filterApprovedEntries(entries, root: root, issues: &issues, coverage: &coverage)
        case .failure(.notFound):
            return []
        case .failure(let error):
            coverage = coverage.dominating(with: .partial)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: directory, under: root.url),
                message: "Directory enumeration failed: \(error.rawValue)"
            ))
            return nil
        }
    }

    private func filterApprovedEntries(
        _ entries: [URL],
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> [URL] {
        entries.filter { entry in
            if fileSystem.isSymbolicLink(entry), !Self.isWithinRoot(entry, rootURL: root.url) {
                coverage = coverage.dominating(with: .partial)
                issues.append(DiscoveryIssue(
                    rootID: root.id,
                    relativePath: entry.lastPathComponent,
                    message: "Symlink escapes approved root; skipped"
                ))
                return false
            }
            return true
        }
    }

    /// Capability roots must distinguish a non-directory entry from metadata
    /// that could not be read. The latter makes the scope incomplete; treating
    /// it as `false` would incorrectly turn EACCES into absence evidence.
    private func isCapabilityDirectory(
        _ url: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage
    ) -> Bool {
        switch fileSystem.directoryStatus(url) {
        case .success(let isDirectory):
            return isDirectory
        case .failure(let error):
            coverage = coverage.dominating(with: .partial)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: url, under: root.url),
                message: "Item metadata read failed: \(error.rawValue)"
            ))
            return false
        }
    }

    private func directoryEntriesRemainStable(
        _ initialEntries: [URL],
        in directory: URL,
        root: ScanRoot,
        issues: inout [DiscoveryIssue],
        coverage: inout CapabilityHistoryCoverage,
        missingIsEmpty: Bool = false,
        initialIdentity: FileSystemDocumentIdentity?
    ) -> Bool {
        let current: [URL]
        switch fileSystem.enumerateDirectory(directory) {
        case .success(let entries):
            current = filterApprovedEntries(entries, root: root, issues: &issues, coverage: &coverage)
        case .failure(.notFound) where missingIsEmpty && initialEntries.isEmpty:
            return true
        case .failure(let error):
            coverage = coverage.dominating(with: .unstable)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: directory, under: root.url),
                message: "Directory changed before observation was published: \(error.rawValue)"
            ))
            return false
        }
        guard let initialIdentity,
              fileSystem.directoryIdentity(directory) == initialIdentity else {
            coverage = coverage.dominating(with: .unstable)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: directory, under: root.url),
                message: "Directory object changed before observation was published"
            ))
            return false
        }
        guard Set(initialEntries.map(\.lastPathComponent)) == Set(current.map(\.lastPathComponent)) else {
            coverage = coverage.dominating(with: .unstable)
            issues.append(DiscoveryIssue(
                rootID: root.id,
                relativePath: Self.relativePath(of: directory, under: root.url),
                message: "Directory contents changed before observation was published"
            ))
            return false
        }
        return true
    }

    private func appendHistoryScope(
        for root: ScanRoot,
        coverage: CapabilityHistoryCoverage,
        to scopes: inout [CapabilityHistoryScanScope]
    ) {
        guard Self.isHistoryTracked(root: root) else { return }
        scopes.append(CapabilityHistoryScanScope(
            rootID: root.id,
            scope: root.scope,
            rootKind: root.kind,
            coverage: coverage
        ))
    }

    private func add(_ resource: CapabilityResource, to resources: inout [CapabilityResource], seen: inout Set<String>) {
        let adjusted: CapabilityResource
        if let override = overrides[resource.id],
           resource.isSkillClassificationCorrectable,
           override.ownership == .userOwned || override.ownership == .installed {
            let correctedOrigin = override.origin ?? resource.manualClassificationOrigin(for: override.ownership)
            let preservesInstalledSource = override.ownership == .installed && correctedOrigin == resource.origin
            adjusted = CapabilityResource(
                id: resource.id, name: resource.name, kind: resource.kind, status: resource.status,
                scope: resource.scope, projectID: resource.projectID, confidence: resource.confidence,
                summary: resource.summary, sourceRootID: resource.sourceRootID,
                relativeSourcePath: resource.relativeSourcePath, sourcePathHash: resource.sourcePathHash,
                lastSeenAt: resource.lastSeenAt, ownership: override.ownership,
                origin: correctedOrigin, classificationConfidence: .exact,
                originIdentifier: preservesInstalledSource ? resource.originIdentifier : nil,
                sourceVersion: preservesInstalledSource ? resource.sourceVersion : nil,
                contentFingerprint: resource.contentFingerprint,
                sourceModifiedAt: resource.sourceModifiedAt,
                modified: resource.modified
            )
        } else {
            adjusted = resource
        }
        guard seen.insert(adjusted.id).inserted else { return }
        resources.append(adjusted)
    }

    private static func isWithinRoot(_ url: URL, rootURL: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootResolved = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == rootResolved || resolved.hasPrefix(rootResolved + "/")
    }

    private static func isHistoryTracked(root: ScanRoot) -> Bool {
        (root.scope == .global || root.scope == .project)
            && (root.kind == .skills || root.kind == .agents || root.kind == .projects)
    }

    private static func relativePath(of url: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func parseJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func safeSourceIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep only a registry slug or GitHub owner/repo; never persist URLs.
        if trimmed.contains("://") { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/."))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    private static func retarget(_ record: CapabilityProvenance, resourceID: String, disambiguator: String) -> CapabilityProvenance {
        CapabilityProvenance(
            id: "\(resourceID):\(record.sourceType.rawValue):\(stableHash(disambiguator))",
            resourceID: resourceID,
            sourceType: record.sourceType,
            sourceIdentifier: record.sourceIdentifier,
            version: record.version,
            installedAt: record.installedAt,
            updatedAt: record.updatedAt,
            confidence: record.confidence,
            modified: record.modified
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue / 1000.0) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    /// Supported manifest schema: absent or "1". Anything else is an unknown
    /// version and lowers the produced resources' confidence to `unknown`.
    private static func schemaIsSupported(_ schema: Any?) -> Bool {
        guard let schema else { return true }
        if let string = schema as? String { return string == "1" }
        if let number = schema as? NSNumber { return number.intValue == 1 }
        return false
    }

    private static func firstHeading(in text: String) -> String? {
        text.split(separator: "\n")
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    private static func normalizedAgentName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private struct AgentTOMLManifest {
        let name: String?
        let description: String?
    }

    /// Reads only top-level `name` and `description` fields from a project
    /// Agent TOML. In particular, developer instructions are never treated as
    /// a purpose. The parser is intentionally conservative: malformed,
    /// escaped, oversized, or sensitive values fail closed while the file's
    /// stable path remains discoverable.
    private static func parseTopLevelAgentTOML(_ text: String) -> AgentTOMLManifest {
        let maximumBytes = 64 * 1024
        guard text.utf8.count <= maximumBytes else { return AgentTOMLManifest(name: nil, description: nil) }
        var name: String?
        var description: String?
        var inTable = false
        var ignoringMultilineValue = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if ignoringMultilineValue {
                if line.contains("\"\"\"") || line.contains("'''") { ignoringMultilineValue = false }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inTable = true
                continue
            }
            guard !inTable else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key != "name" && key != "description" {
                if (rawValue.hasPrefix("\"\"\"") && !rawValue.dropFirst(3).contains("\"\"\"")) || (rawValue.hasPrefix("'''") && !rawValue.dropFirst(3).contains("'''")) {
                    ignoringMultilineValue = true
                }
                continue
            }
            guard let value = parseTOMLString(rawValue) else { return AgentTOMLManifest(name: nil, description: nil) }
            if key == "name" {
                guard name == nil else { return AgentTOMLManifest(name: nil, description: nil) }
                name = safeAgentManifestValue(value, maximumLength: 160)
            } else {
                guard description == nil else { return AgentTOMLManifest(name: nil, description: nil) }
                let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                description = safeAgentManifestValue(normalized, maximumLength: 320)
            }
        }
        return AgentTOMLManifest(name: name, description: description)
    }

    private static func parseTOMLString(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        let quote = raw.first!
        guard quote == "\"" || quote == "'" else { return nil }
        let content = raw.dropFirst()
        guard let closing = content.firstIndex(of: quote) else { return nil }
        let body = String(content[..<closing])
        let trailing = content[content.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        // The scanner deliberately accepts only plain single-line strings.
        // Escape sequences are valid TOML, but accepting them here would make
        // a hostile or malformed manifest look like a trusted description.
        // Returning nil keeps the stable resource discoverable while dropping
        // the untrusted metadata.
        guard !body.contains("\\") else { return nil }
        if quote == "'" { return body.contains("'") ? nil : body }
        return body.contains("\"") ? nil : body
    }

    private static func safeAgentManifestValue(_ value: String, maximumLength: Int) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maximumLength,
              !PersistenceAllowlist.containsForbiddenValue(normalized) else { return nil }
        return normalized
    }

    /// Extracts only the first bounded declarative paragraph from an Agent
    /// brief. Source body sections are intentionally never persisted.
    private static func agentPurpose(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let missionIndex = lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "## mission"
        }

        let startIndex: Int
        if let missionIndex {
            startIndex = missionIndex + 1
        } else if let titleIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") }) {
            startIndex = titleIndex + 1
        } else {
            startIndex = 0
        }

        var paragraph: [String] = []
        for line in lines.dropFirst(startIndex) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                if missionIndex != nil || !paragraph.isEmpty { break }
                continue
            }
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(trimmed)
        }
        let normalized = paragraph.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        // Inspect the complete normalized paragraph before truncation so a
        // credential just beyond the UI bound cannot be silently retained.
        guard !PersistenceAllowlist.containsForbiddenValue(normalized) else { return nil }
        return String(normalized.prefix(320))
    }

    /// FNV-1a 64-bit, hex-encoded — a deterministic, dependency-free stable hash.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stableID(kind: ResourceKind, scope: ResourceScope, rootID: String, relative: String) -> String {
        "\(kind.rawValue):\(scope.rawValue):\(rootID):\(Self.stableHash(relative))"
    }
}

/// Minimal YAML-ish frontmatter parser for `SKILL.md`-style manifests.
/// Handles top-level scalar fields, description block scalars and JSON metadata.
/// This is not a general YAML interpreter and never evaluates manifest content.
private struct Frontmatter {
    var fields: [String: String] = [:]
    var metadata: [String: Any] = [:]

    static func parse(_ text: String) -> Frontmatter {
        var result = Frontmatter()
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            result.fields["description"] = leadingPurpose(in: lines)
            return result
        }
        guard let end = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else { return result }
        let body = Array(lines[1..<end])
        var index = 0
        while index < body.count {
            let line = body[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            if [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
                var block: [String] = []
                while index < body.count {
                    let next = body[index]
                    guard next.trimmingCharacters(in: .whitespaces).isEmpty || next.first?.isWhitespace == true else { break }
                    block.append(next)
                    index += 1
                }
                // Only descriptions support block syntax. Do not let a nested
                // `name:` or `description:` become a top-level identity field.
                if key == "description" {
                    let indentation = block.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { $0.prefix(while: { $0.isWhitespace }).count }.min() ?? 0
                    let content = block.map { String($0.dropFirst(min(indentation, $0.count))) }
                    let summary = content.joined(separator: value.hasPrefix(">") ? " " : "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty, summary.utf8.count <= 16_384,
                       !PersistenceAllowlist.containsForbiddenValue(summary) {
                        result.fields[key] = summary
                    }
                }
                continue
            }
            result.fields[key] = value
        }

        if let metadataText = result.fields["metadata"],
           let data = metadataText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.metadata = json
        }
        return result
    }

    /// Some independently installed Skills declare their purpose directly
    /// after the Markdown title instead of in frontmatter. Read only that
    /// opening prose paragraph, never later sections, lists or code fences.
    private static func leadingPurpose(in lines: [String]) -> String? {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].hasPrefix("# ") else { return nil }
        var paragraph: [String] = []
        for line in lines.dropFirst(first + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if paragraph.isEmpty { continue }
                break
            }
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("```"), !trimmed.hasPrefix("~~~"),
                  !trimmed.hasPrefix("- "), !trimmed.hasPrefix("* "), !trimmed.hasPrefix(">"),
                  !trimmed.hasPrefix("|"), trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil else { break }
            paragraph.append(trimmed)
        }
        let summary = paragraph.joined(separator: " ")
        guard !summary.isEmpty, summary.count <= 320,
              !PersistenceAllowlist.containsForbiddenValue(summary) else { return nil }
        return summary
    }
}
