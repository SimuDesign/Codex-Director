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

    public init(
        processedFiles: Int,
        skippedFiles: Int,
        indexedSessions: Int,
        resources: Int,
        cancelled: Bool,
        runtimeCoverage: CoverageState = .unknown,
        runtimeIssueCount: Int = 0,
        discoveryIssueCount: Int = 0
    ) {
        self.processedFiles = processedFiles
        self.skippedFiles = skippedFiles
        self.indexedSessions = indexedSessions
        self.resources = resources
        self.cancelled = cancelled
        self.runtimeCoverage = runtimeCoverage
        self.runtimeIssueCount = runtimeIssueCount
        self.discoveryIssueCount = discoveryIssueCount
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

    public init(
        store: DatabaseStore,
        fileSystem: FileSystemClient = FileSystemClient(),
        runtimeDiscovery: CodexRuntimeDiscovery? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sourceObserver: (@Sendable (SourceIndexPhase) -> Void)? = nil
    ) {
        self.store = store
        self.fileSystem = fileSystem
        self.runtimeDiscovery = runtimeDiscovery
        self.nowProvider = now
        self.sourceObserver = sourceObserver
    }

    public func run(
        configuration: Configuration,
        progress: @escaping @Sendable (IndexingProgress) -> Void = { _ in }
    ) async throws -> IndexingResult {
        sourceObserver?(.started)
        do {
            let result = try await runImplementation(configuration: configuration, progress: progress)
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
        progress: @escaping @Sendable (IndexingProgress) -> Void
    ) async throws -> IndexingResult {
        progress(.init(phase: .scanning, processedFiles: 0, totalFiles: 0, indexedSessions: 0, lastError: nil))
        try Task.checkCancellation()

        // 1. Resource discovery: filesystem + current System/Runtime sources.
        let previousResources = try await store.fetchAllResources()
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
        let discovery = ResourceScanner(
            roots: configuration.scanRoots,
            fileSystem: fileSystem,
            overrides: configuration.classificationOverrides,
            userOwnedSkillRegistrations: registry.registrations,
            previousFingerprints: previousFingerprints,
            previousModified: previousModified
        ).scan()
        var combinedResources = discovery.resources
        var combinedProvenance = discovery.provenance
        let combinedProjects = discovery.projects
        var combinedRelations = discovery.relations
        var transientRoots: [String: URL] = [:]
        var runtimeIssues: [DiscoveryIssue] = []
        var runtimeCoverage: CoverageState = .unknown
        if let runtimeDiscovery {
            let runtime = await runtimeDiscovery.discover()
            let runtimeSkillIDs = Dictionary(grouping: runtime.resources.filter { $0.kind == .skill }.compactMap { resource -> (String, String)? in
                guard let root = runtime.transientRoots[resource.sourceRootID], let relative = resource.relativeSourcePath else { return nil }
                let marker = resource.sourceRootID.replacingOccurrences(of: "runtime-plugins:", with: "")
                let prefix = "plugins/\(marker)/"
                let child = relative.hasPrefix(prefix) ? String(relative.dropFirst(prefix.count)) : relative
                return (root.appendingPathComponent(child).resolvingSymlinksInPath().standardizedFileURL.path, resource.id)
            }, by: { $0.0 })
            let canonicalByPhysical = Dictionary(grouping: combinedResources.filter { $0.kind == .skill }.compactMap { resource -> (String, String)? in
                guard let root = configuration.scanRoots.first(where: { $0.id == resource.sourceRootID }), let relative = resource.relativeSourcePath else { return nil }
                return (root.url.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL.path, resource.id)
            }, by: { $0.0 }).compactMapValues { values -> String? in
                let ids = Set(values.map(\.1))
                return ids.count == 1 ? ids.first : nil
            }
            var runtimeCanonicalMap: [String: String] = [:]
            for (physical, values) in runtimeSkillIDs {
                let ids = Set(values.map(\.1))
                if ids.count == 1, let runtimeID = ids.first, let canonicalID = canonicalByPhysical[physical] {
                    runtimeCanonicalMap[runtimeID] = canonicalID
                }
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
            runtimeCoverage = runtime.coverage
            if runtime.coverage == .unavailable {
                // Preserve the last-known runtime inventory without counting
                // it as current. It is intentionally marked warning and moved
                // to a non-current source bucket for the UI.
                let previous = try await store.fetchAllResources().filter { $0.scope == .runtime }
                let previousIDs = Set(previous.map(\.id))
                combinedResources.append(contentsOf: previous.map { resource in
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
                combinedProvenance.append(contentsOf: try await store.fetchAllProvenance().filter { previousIDs.contains($0.resourceID) })
                combinedRelations.append(contentsOf: try await store.fetchAllRelations().filter { previousIDs.contains($0.sourceResourceID) || previousIDs.contains($0.targetResourceID) })
            }
        }
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

        // Skill evidence resolution uses only currently discovered resources.
        extractor = InvocationExtractor(
            skillResolver: SkillEvidenceResolver(resources: combinedResources, roots: configuration.scanRoots, transientRoots: transientRoots),
            agentResolver: AgentEvidenceResolver(resources: combinedResources, roots: configuration.scanRoots)
        )

        // 2. Session file inventory.
        let files = collectSessionFiles(configuration: configuration)
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

            if let checkpoint,
               checkpoint.sourceSize == attributes.size,
               checkpoint.sourceMtime == attributes.modificationDate,
               checkpoint.parserVersion == RolloutEventDecoder.parserVersion {
                skippedFiles += 1
                processedFiles += 1
                progress(.init(phase: .parsing, processedFiles: processedFiles, totalFiles: files.count, indexedSessions: indexedSessions, lastError: nil))
                continue
            }

            let startOffset: UInt64
            if let checkpoint,
               checkpoint.parserVersion == RolloutEventDecoder.parserVersion,
               attributes.size >= checkpoint.sourceSize,
               checkpoint.byteOffset <= attributes.size {
                startOffset = checkpoint.byteOffset // appended
            } else {
                startOffset = 0 // fresh or truncated/replaced
            }

            let outcome = try await parseSessionFile(
                url: url,
                sourceFileID: sourceFileID,
                startOffset: startOffset,
                resumeCheckpoint: checkpoint,
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
            try await runReviewPass(configuration: configuration)
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
            discoveryIssueCount: registry.issues.count + discovery.issues.count
        )
    }

    // MARK: - Review pass (production caller for IntegrityRules)

    private func runReviewPass(configuration: Configuration) async throws {
        let resources = try await store.fetchAllResources()
        let sessions = try await store.fetchAllSessions()
        var invocationsBySession: [String: [InvocationEvent]] = [:]
        for session in sessions {
            invocationsBySession[session.id] = try await store.fetchCalls(sessionID: session.id)
        }
        let quotas = try await store.fetchAllQuotaSnapshots()
        let context = ReviewContext(
            resources: resources,
            sessions: sessions,
            invocationsBySession: invocationsBySession,
            quotaSnapshots: quotas,
            scanRoots: configuration.scanRoots,
            fileSystem: fileSystem,
            now: nowProvider()
        )
        // Deterministic rules only; disabled Rule 5 is never evaluated.
        let findings = IntegrityRules.evaluate(context: context)
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
        scanRoots: [ScanRoot],
        fileProgress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) async throws -> ParseOutcome {
        guard let reader = JSONLIncrementalReader(url: url, startOffset: startOffset) else {
            return ParseOutcome(indexed: false, cancelled: false)
        }

        // On an append, the session id is already persisted. On a fresh parse,
        // read leading envelopes until a session_meta envelope yields the id.
        // Rollout files begin with session_meta, so the leading buffer is tiny.
        var resolvedSessionID: String? = startOffset > 0
            ? (try await store.fetchSessionID(sourceFileID: sourceFileID))
            : nil
        var resolvedProjectID: String? = startOffset > 0
            ? (try await store.fetchSessionProjectID(sourceFileID: sourceFileID))
            : nil

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
            try await persistCheckpoint(url: url, sourceFileID: sourceFileID, byteOffset: lastCommittedOffset)
            return ParseOutcome(indexed: false, cancelled: true)
        }

        let sessionID = resolvedSessionID ?? sourceFileID
        let resumeTokenSnapshot: TokenUsageSnapshot?
        if startOffset > 0 {
            resumeTokenSnapshot = try await store.fetchTokenSnapshots(sessionID: sessionID)
                .max { lhs, rhs in
                    if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
                    return lhs.id < rhs.id
                }
        } else {
            resumeTokenSnapshot = nil
        }
        var invocation = extractor.makeAccumulator(sessionID: sessionID)
        var tokens = tokenParser.makeAccumulator(sessionID: sessionID, resumeFrom: resumeTokenSnapshot)

        var startedAt: Date?
        var endedAt: Date?
        var started = false
        var completed = false
        var sawAnyEnvelope = false
        var decoderIssueCount = leadingDecoderIssues
        var unknownEvents = leadingUnknownEvents

        func process(_ envelope: RolloutEnvelope) {
            sawAnyEnvelope = true
            if startedAt == nil { startedAt = envelope.timestamp }
            endedAt = envelope.timestamp
            if envelope.type == .eventMessage, let payload = envelope.payload {
                switch payload.json["type"] as? String {
                case "task_started": started = true
                case "task_complete": completed = true
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

        // Persist the resume point even when cancelled mid-file.
        if cancelled {
            try await persistCheckpoint(url: url, sourceFileID: sourceFileID, byteOffset: lastCommittedOffset)
            return ParseOutcome(indexed: false, cancelled: true)
        }

        let priorCoverage: CoverageState?
        if startOffset > 0 {
            priorCoverage = try await store.fetchSessionCoverage(sourceFileID: sourceFileID)
        } else {
            priorCoverage = nil
        }

        let accumulation = SessionAccumulation(
            sessionID: sessionID,
            sourceFileID: sourceFileID,
            startedAt: startedAt,
            endedAt: endedAt,
            status: completed ? .completed : (started ? .running : .unknown),
            sawAnyEnvelope: sawAnyEnvelope,
            decoderIssueCount: decoderIssueCount,
            unknownEvents: unknownEvents,
            invocation: invocation.finish(),
            tokens: tokens.finish(),
            projectID: resolvedProjectID
        )
        let batch = try makeBatch(accumulation: accumulation, priorCoverage: priorCoverage)
        try await store.replaceSession(batch, resetExisting: startOffset == 0)
        if let attributes = fileSystem.fileAttributes(url) {
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

    private func persistCheckpoint(url: URL, sourceFileID: String, byteOffset: UInt64) async throws {
        guard let attributes = fileSystem.fileAttributes(url) else { return }
        try await store.upsertCheckpoint(IndexCheckpoint(
            sourceFileID: sourceFileID,
            sourceSize: attributes.size,
            sourceMtime: attributes.modificationDate,
            byteOffset: byteOffset,
            parserVersion: RolloutEventDecoder.parserVersion,
            indexedAt: Date()
        ))
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
