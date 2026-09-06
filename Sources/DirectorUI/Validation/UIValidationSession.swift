#if DEBUG
import Foundation
import SwiftUI
import DirectorCore

/// A disposable, synthetic projection used only by the Debug validation host.
/// It never scans source roots, starts runtime discovery, or uses production
/// preference domains.
@MainActor
public final class UIValidationSession: ObservableObject {
    public enum Dataset: String, CaseIterable, Identifiable, Sendable {
        case representative
        case empty
        case stress
        case homeVisual

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .representative: return "Representative"
            case .empty: return "Empty"
            case .stress: return "Stress"
            case .homeVisual: return "Home visual edges"
            }
        }
    }

    public struct FixtureCounts: Equatable, Sendable {
        public let resources: Int
        public let sessions: Int
        public let invocations: Int
        public let findings: Int

        public init(resources: Int, sessions: Int, invocations: Int, findings: Int) {
            self.resources = resources
            self.sessions = sessions
            self.invocations = invocations
            self.findings = findings
        }
    }

    @Published public private(set) var dataset: Dataset
    @Published public private(set) var model: DirectorAppModel
    @Published public private(set) var generation = 0
    @Published public private(set) var isReady = false
    @Published public private(set) var hasError = false

    public private(set) var databaseURL: URL

    private var directoryURL: URL
    private var preferences: InMemoryPreferences
    private var preparedDataset: Dataset?
    private var resetGeneration = 0
    private let databaseFactory: () throws -> (URL, URL)
    private let seedOperation: (@Sendable (Dataset, DatabaseStore, InvocationEvaluationStore) async throws -> Void)?

    public convenience init(dataset: Dataset = .representative) throws {
        try self.init(dataset: dataset, databaseFactory: { try Self.makeTemporaryDatabase() })
    }

    /// Internal factory injection is used only to exercise reset failure and
    /// recovery without touching any production path.
    init(
        dataset: Dataset,
        databaseFactory: @escaping () throws -> (URL, URL),
        seedOperation: (@Sendable (Dataset, DatabaseStore, InvocationEvaluationStore) async throws -> Void)? = nil
    ) throws {
        self.databaseFactory = databaseFactory
        self.seedOperation = seedOperation
        let (directoryURL, databaseURL) = try databaseFactory()
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.dataset = dataset
        self.preferences = InMemoryPreferences()

        let classificationStore = ResourceClassificationOverrideStore(
            readData: { [preferences] in preferences.data(forKey: ResourceClassificationOverrideStore.defaultsKey) },
            writeData: { [preferences] data in preferences.set(data, forKey: ResourceClassificationOverrideStore.defaultsKey) },
            removeData: { [preferences] in preferences.removeObject(forKey: ResourceClassificationOverrideStore.defaultsKey) }
        )
        let evaluationStore = InvocationEvaluationStore(
            readData: { [preferences] in preferences.data(forKey: InvocationEvaluationStore.defaultsKey) },
            writeData: { [preferences] data in preferences.set(data, forKey: InvocationEvaluationStore.defaultsKey); return true },
            removeData: { [preferences] in preferences.removeObject(forKey: InvocationEvaluationStore.defaultsKey); return true }
        )
        let store: DatabaseStore
        do {
            store = try DatabaseStore(url: databaseURL)
        } catch {
            DatabaseStore.destroy(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
        self.model = DirectorAppModel(
            store: store,
            coordinator: nil,
            configuration: nil,
            capabilityExportCoordinator: try Self.makeValidationExportCoordinator(in: directoryURL),
            classificationOverrides: classificationStore,
            evaluationStore: evaluationStore,
            nowProvider: { Fixture.referenceNow },
            calendar: Fixture.validationCalendar
        )
    }

    deinit {
        DatabaseStore.destroy(at: databaseURL)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// Seeds the selected dataset once and refreshes the real app model.
    public func prepare() async throws {
        guard preparedDataset != dataset else { return }
        hasError = false
        do {
            try await seed(dataset: dataset, store: model.store!, evaluationStore: model.evaluationStore)
            try await model.refresh()
            preparedDataset = dataset
            isReady = true
        } catch {
            hasError = true
            throw error
        }
    }

    /// Rebuilds only this session's disposable projection and swaps the real
    /// model. The host uses `generation` to recreate its root view state.
    public func reset(to dataset: Dataset) async {
        resetGeneration += 1
        let requestGeneration = resetGeneration
        // Even a same-dataset request invalidates an older pending reset. This
        // makes rapid A → B → A selections deterministic under actor reentry.
        guard dataset != self.dataset || !isReady else { return }
        var allocatedDirectory: URL?
        var allocatedDatabaseURL: URL?
        do {
            let (newDirectory, newURL) = try databaseFactory()
            allocatedDirectory = newDirectory
            allocatedDatabaseURL = newURL
            let newPreferences = InMemoryPreferences()
            let classificationStore = ResourceClassificationOverrideStore(
                readData: { [newPreferences] in newPreferences.data(forKey: ResourceClassificationOverrideStore.defaultsKey) },
                writeData: { [newPreferences] data in newPreferences.set(data, forKey: ResourceClassificationOverrideStore.defaultsKey) },
                removeData: { [newPreferences] in newPreferences.removeObject(forKey: ResourceClassificationOverrideStore.defaultsKey) }
            )
            let evaluationStore = InvocationEvaluationStore(
                readData: { [newPreferences] in newPreferences.data(forKey: InvocationEvaluationStore.defaultsKey) },
                writeData: { [newPreferences] data in newPreferences.set(data, forKey: InvocationEvaluationStore.defaultsKey); return true },
                removeData: { [newPreferences] in newPreferences.removeObject(forKey: InvocationEvaluationStore.defaultsKey); return true }
            )
            let newStore = try DatabaseStore(url: newURL)
            let newModel = DirectorAppModel(
                store: newStore,
                coordinator: nil,
                configuration: nil,
                capabilityExportCoordinator: try Self.makeValidationExportCoordinator(in: newDirectory),
                classificationOverrides: classificationStore,
                evaluationStore: evaluationStore,
                nowProvider: { Fixture.referenceNow },
                calendar: Fixture.validationCalendar
            )
            try await seed(dataset: dataset, store: newStore, evaluationStore: evaluationStore)
            try await newModel.refresh()

            // An async reset may finish after a newer selection. Dispose this
            // stale disposable projection rather than replacing a newer one.
            guard requestGeneration == resetGeneration else {
                DatabaseStore.destroy(at: newURL)
                try? FileManager.default.removeItem(at: newDirectory)
                return
            }

            let oldDirectory = directoryURL
            let oldURL = databaseURL
            self.directoryURL = newDirectory
            self.databaseURL = newURL
            self.preferences = newPreferences
            self.dataset = dataset
            self.model = newModel
            self.generation += 1
            self.preparedDataset = dataset
            self.isReady = true
            self.hasError = false
            DatabaseStore.destroy(at: oldURL)
            try? FileManager.default.removeItem(at: oldDirectory)
        } catch {
            // Keep the current valid dataset visible if a disposable reset
            // cannot be created and expose an explicit unavailable state.
            if let allocatedDatabaseURL {
                DatabaseStore.destroy(at: allocatedDatabaseURL)
            }
            if let allocatedDirectory {
                try? FileManager.default.removeItem(at: allocatedDirectory)
            }
            if requestGeneration == resetGeneration {
                hasError = true
            }
        }
    }

    public var fixtureCounts: FixtureCounts {
        Self.counts(for: dataset)
    }

    private static func makeTemporaryDatabase() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-ui-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("validation.sqlite"))
    }

    private static func makeValidationExportCoordinator(in directory: URL) throws -> CapabilityExportCoordinator {
        let home = directory.appendingPathComponent("synthetic-home", isDirectory: true)
        let project = directory.appendingPathComponent("synthetic-project", isDirectory: true)
        let files: [(String, String)] = [
            (".codex/agents/sample-agent.toml", "developer_instructions = \"{{HOME}}/.codex/agents/sample-agent/agent.md\"\n"),
            (".codex/agents/sample-agent/agent.md", "# Sample Agent\nSynthetic validation content.\n"),
            (".codex/skills/sample-skill/SKILL.md", "---\nname: sample-skill\n---\nSynthetic validation content.\n"),
            (".agents/skills/installed-skill/SKILL.md", "---\nname: installed-skill\n---\nSynthetic installed content.\n"),
            (".codex/AGENTS.md", "# Synthetic global instructions\n"),
        ]
        for (relative, text) in files {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let projectFiles: [(String, String)] = [
            (".codex/agents/project-agent.toml", "developer_instructions = \"Synthetic project Agent\"\n"),
            (".agents/skills/project-skill/SKILL.md", "---\nname: project-skill\n---\nSynthetic project content.\n"),
            ("AGENTS.md", "# Synthetic project instructions\n"),
        ]
        for (relative, text) in projectFiles {
            let url = project.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return CapabilityExportCoordinator(
            environment: CapabilityExportEnvironment(
                homeDirectory: home,
                projects: [CapabilityExportProjectSource(directory: project, displayName: "Synthetic Project")],
                producer: CapabilityPackageProducer(version: "1.0.0", build: "21"),
                platform: CapabilityPackagePlatform(operatingSystem: "macOS", operatingSystemVersion: "26.0", architecture: "arm64")
            ),
            pluginProvider: ValidationPluginProvider(),
            now: { Fixture.referenceNow }
        )
    }

    private static func counts(for dataset: Dataset) -> FixtureCounts {
        switch dataset {
        case .representative: return FixtureCounts(resources: 14, sessions: 4, invocations: 20, findings: 2)
        case .empty: return FixtureCounts(resources: 0, sessions: 0, invocations: 0, findings: 0)
        case .stress: return FixtureCounts(resources: 165, sessions: 4, invocations: 520, findings: 4)
        case .homeVisual: return FixtureCounts(resources: 36, sessions: 4, invocations: 240, findings: 4)
        }
    }

    private static func seed(
        dataset: Dataset,
        store: DatabaseStore,
        evaluationStore: InvocationEvaluationStore
    ) async throws {
        guard dataset != .empty else { return }
        let fixture = Fixture(dataset: dataset)
        try await store.replaceResourceInventory(
            resources: fixture.resources,
            projects: fixture.projects,
            provenance: fixture.provenance,
            relations: fixture.relations
        )
        for batch in fixture.batches {
            try await store.replaceSession(batch, resetExisting: true)
        }
        for evaluation in fixture.evaluations {
            _ = evaluationStore.set(evaluation)
        }
    }

    private func seed(
        dataset: Dataset,
        store: DatabaseStore,
        evaluationStore: InvocationEvaluationStore
    ) async throws {
        if let seedOperation {
            try await seedOperation(dataset, store, evaluationStore)
        } else {
            try await Self.seed(dataset: dataset, store: store, evaluationStore: evaluationStore)
        }
    }
}

private final class InMemoryPreferences: @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

private struct ValidationPluginProvider: CapabilityPluginInventoryProviding {
    func inventory(at date: Date) async -> CapabilityPackagePluginList {
        CapabilityPackagePluginList(
            status: .complete,
            generatedAt: date,
            plugins: [CapabilityPackagePlugin(
                identifier: "synthetic@validation",
                name: "synthetic",
                marketplace: "validation",
                version: "1.0.0",
                enabled: true
            )]
        )
    }
}

private struct Fixture {
    let resources: [CapabilityResource]
    let projects: [CapabilityProject]
    let provenance: [CapabilityProvenance]
    let relations: [ResourceRelation]
    let batches: [PersistedSessionBatch]
    let evaluations: [InvocationEvaluation]

    private init(
        resources: [CapabilityResource], projects: [CapabilityProject],
        provenance: [CapabilityProvenance], relations: [ResourceRelation],
        batches: [PersistedSessionBatch], evaluations: [InvocationEvaluation]
    ) {
        self.resources = resources
        self.projects = projects
        self.provenance = provenance
        self.relations = relations
        self.batches = batches
        self.evaluations = evaluations
    }

    init(dataset: UIValidationSession.Dataset) {
        switch dataset {
        case .representative:
            self = Self.representative()
        case .stress:
            self = Self.stress()
        case .homeVisual:
            self = Self.homeVisual()
        case .empty:
            self.init(resources: [], projects: [], provenance: [], relations: [], batches: [], evaluations: [])
        }
    }

    fileprivate static let referenceNow = Date(timeIntervalSince1970: 1_787_889_600) // 2026-08-28 12:00 Asia/Shanghai
    fileprivate static let validationCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    private static let epoch = referenceNow
    private static let projectA = "project:validation-a"
    private static let projectB = "project:validation-b"

    private static func day(_ offset: Int, hour: Int = 12) -> Date {
        let start = validationCalendar.startOfDay(for: referenceNow)
        return validationCalendar.date(byAdding: .hour, value: hour, to: validationCalendar.date(byAdding: .day, value: offset, to: start)!)!
    }

    private static func resource(
        id: String, name: String, kind: ResourceKind, scope: ResourceScope,
        projectID: String? = nil, ownership: ResourceOwnership, origin: ResourceOrigin,
        confidence: EvidenceConfidence = .exact, status: RuntimeStatus = .idle,
        summary: String = "Synthetic validation fixture", modified: Bool = false
    ) -> CapabilityResource {
        let rootID: String = {
            if kind == .plugin && scope == .plugin { return "plugin-cache" }
            if (kind == .plugin || ownership == .pluginProvided) && scope == .runtime { return "runtime-plugins" }
            return "validation-\(scope.rawValue)"
        }()
        return CapabilityResource(
            id: id, name: name, kind: kind, status: status, scope: scope,
            projectID: projectID, confidence: confidence, summary: summary,
            sourceRootID: rootID, relativeSourcePath: "synthetic/\(name).md",
            sourcePathHash: "hash-\(name)", lastSeenAt: epoch, ownership: ownership, origin: origin,
            classificationConfidence: confidence, contentFingerprint: "fingerprint-\(name)",
            sourceModifiedAt: epoch, modified: modified
        )
    }

    private static func representative() -> Fixture {
        let resources = [
            resource(id: "agent:validation-global", name: "validation-global-agent", kind: .agent, scope: .global, ownership: .userOwned, origin: .local, summary: "Runs synthetic validation orchestration only.", modified: true),
            resource(id: "agent:validation-project-a", name: "validation-project-agent-a", kind: .agent, scope: .project, projectID: projectA, ownership: .userOwned, origin: .local),
            resource(id: "agent:validation-project-b", name: "validation-project-agent-b", kind: .agent, scope: .project, projectID: projectB, ownership: .userOwned, origin: .local),
            resource(id: "skill:validation-custom", name: "validation-custom-skill", kind: .skill, scope: .global, ownership: .userOwned, origin: .local),
            resource(id: "skill:validation-unobserved", name: "validation-unobserved-skill", kind: .skill, scope: .global, ownership: .userOwned, origin: .local),
            resource(id: "skill:validation-installed", name: "validation-installed-skill", kind: .skill, scope: .global, ownership: .installed, origin: .github, confidence: .inferred),
            resource(id: "plugin:validation-enabled", name: "validation-enabled-plugin", kind: .plugin, scope: .runtime, ownership: .pluginProvided, origin: .plugin, confidence: .inferred, status: .success),
            resource(id: "skill:validation-plugin-child", name: "validation-plugin-skill", kind: .skill, scope: .runtime, ownership: .pluginProvided, origin: .plugin, confidence: .inferred),
            resource(id: "plugin:validation-disabled", name: "validation-disabled-plugin", kind: .plugin, scope: .runtime, ownership: .pluginProvided, origin: .plugin, confidence: .exact, status: .blocked),
            resource(id: "plugin:validation-cached", name: "validation-old-cache", kind: .plugin, scope: .plugin, ownership: .pluginProvided, origin: .plugin, confidence: .exact, status: .unknown),
            resource(id: "plugin:validation-unsupported", name: "validation-unsupported-plugin", kind: .plugin, scope: .runtime, ownership: .pluginProvided, origin: .plugin, confidence: .unknown, status: .unknown),
            resource(id: "hook:validation-unsupported", name: "validation-unsupported-hook", kind: .hook, scope: .runtime, ownership: .runtime, origin: .runtime, confidence: .unknown),
            resource(id: "instruction:validation", name: "validation-instructions", kind: .instruction, scope: .project, projectID: projectA, ownership: .userOwned, origin: .local),
            resource(id: "tool:validation-tool", name: "validation-tool", kind: .tool, scope: .runtime, ownership: .runtime, origin: .runtime, status: .success),
        ]
        return build(resources: resources, sessionCount: 4, invocationCount: 20, findingCount: 2)
    }

    private static func stress() -> Fixture {
        var resources = representative().resources
        for index in 0..<151 {
            let name = index == 150
                ? "validation-stress-" + String(repeating: "long-name-", count: 12)
                : "validation-stress-tool-\(index)"
            resources.append(resource(
                id: "tool:validation-stress-\(index)", name: name, kind: .tool,
                scope: .runtime, ownership: .runtime, origin: .runtime,
                confidence: index.isMultiple(of: 7) ? .unknown : .exact,
                status: index.isMultiple(of: 11) ? .warning : .idle
            ))
        }
        return build(resources: resources, sessionCount: 4, invocationCount: 520, findingCount: 4)
    }

    private static func homeVisual() -> Fixture {
        var resources: [CapabilityResource] = []
        for index in 0..<12 {
            let name = index == 11 ? "Home visual Agent with an intentionally long readable name" : "Home visual Agent \(index + 1)"
            resources.append(resource(
                id: "agent:home-visual-\(index)", name: name, kind: .agent, scope: .global,
                ownership: .userOwned, origin: .local,
                confidence: index.isMultiple(of: 4) ? .inferred : .exact
            ))
        }
        for index in 0..<12 {
            let name = index == 11 ? "Home visual Skill with an intentionally long readable name" : "Home visual Skill \(index + 1)"
            resources.append(resource(
                id: "skill:home-visual-\(index)", name: name, kind: .skill, scope: .global,
                ownership: .userOwned, origin: .local,
                confidence: index.isMultiple(of: 5) ? .inferred : .exact
            ))
        }
        for index in 0..<12 {
            let name = index == 11 ? "Installed visual Skill with an intentionally long readable name" : "Installed visual Skill \(index + 1)"
            resources.append(resource(
                id: "installed-skill:home-visual-\(index)", name: name, kind: .skill, scope: .global,
                ownership: .installed, origin: .github,
                confidence: index.isMultiple(of: 3) ? .inferred : .exact
            ))
        }
        return build(resources: resources, sessionCount: 4, invocationCount: 240, findingCount: 4, quotaFixtures: homeVisualQuotaSnapshots())
    }

    private static func build(resources: [CapabilityResource], sessionCount: Int, invocationCount: Int, findingCount: Int, quotaFixtures: [QuotaSnapshot]? = nil) -> Fixture {
        let capabilityResources = resources.filter { $0.kind == .agent || $0.kind == .skill }
        let isStress = invocationCount > 100
        var allCalls: [[InvocationEvent]] = Array(repeating: [], count: sessionCount)
        for index in 0..<invocationCount {
            let sessionIndex = index % sessionCount
            let resourceID: String
            if !isStress {
                let representativeIDs = [
                    "agent:validation-global", "agent:validation-project-a", "agent:validation-global", "agent:validation-project-b",
                    "skill:validation-installed", "agent:validation-global", "skill:validation-plugin-child", "plugin:validation-enabled",
                    "hook:validation-unsupported", "plugin:validation-disabled", "agent:validation-global", "skill:validation-plugin-child",
                    "plugin:validation-enabled", "tool:validation-tool", "agent:validation-project-a", "skill:validation-installed",
                    "plugin:validation-disabled", "plugin:validation-unsupported", "tool:validation-tool", "skill:validation-custom"
                ]
                resourceID = representativeIDs[index]
            } else {
                resourceID = resources[index % resources.count].id
            }
            let resource = resources.first(where: { $0.id == resourceID }) ?? resources[index % resources.count]
            let kind: InvocationKind = resource.kind == .agent ? .agent : (resource.kind == .skill ? .skill : .tool)
            let status: InvocationStatus
            if !isStress {
                status = index == 3 ? .failed : (index == 4 ? .interrupted : (index == 5 ? .unknown : .completed))
            } else {
                status = index.isMultiple(of: 29) ? .unknown : (index.isMultiple(of: 17) ? .interrupted : (index.isMultiple(of: 13) ? .failed : .completed))
            }
            let confidence: EvidenceConfidence = !isStress && index == 3
                ? .inferred
                : (index.isMultiple(of: 5) ? .inferred : (index.isMultiple(of: 19) ? .unknown : .exact))
            let timestamp = !isStress && index == 19 ? day(-10) : day((index % 7) - 6, hour: 9 + (index % 8))
            let parentCallID = !isStress && index == 6 ? "call:validation-0" : nil
            allCalls[sessionIndex].append(InvocationEvent(
                id: "call:validation-\(index)", sessionID: "session:validation-\(sessionIndex)", parentCallID: parentCallID,
                ordinal: allCalls[sessionIndex].count, timestamp: timestamp,
                actorName: "synthetic-codex", resourceID: resource.id, kind: kind, status: status,
                durationMs: index.isMultiple(of: 3) ? 120 : nil, confidence: confidence,
                errorCategory: status == .failed ? "synthetic-failure" : nil
            ))
        }
        var sessions: [TaskSummary] = []
        for index in 0..<sessionCount {
            let projectID: String? = index == 0 ? projectA : (index == 1 ? projectB : nil)
            let startedAt = day((index % 4) - 3, hour: 8 + index)
            let endedAt = index == 1 ? nil : startedAt.addingTimeInterval(120)
            let status: TaskStatus = index == 1 ? .interrupted : (index == 2 ? .failed : .completed)
            let coverage: CoverageState = index == 1 ? .partial : .complete
            sessions.append(TaskSummary(
                id: "session:validation-\(index)", projectID: projectID,
                startedAt: startedAt, endedAt: endedAt, status: status, coverage: coverage,
                parserVersion: "validation-1", sourceFileID: "source:validation-\(index)", title: nil
            ))
        }
        var batches: [PersistedSessionBatch] = []
        for (index, session) in sessions.enumerated() {
            let tokens = [tokenSnapshot(sessionID: session.id, dayOffset: index - 3)]
            let quotas = index == 0 ? (quotaFixtures ?? quotaSnapshots()) : []
            let findings = findingCount > 0 && index < findingCount
                ? [finding(index: index, resourceID: resources[index % resources.count].id, sessionID: session.id)]
                : []
            batches.append(PersistedSessionBatch(
                session: session, calls: allCalls[index], tokenSnapshots: tokens,
                quotaSnapshots: quotas, findings: findings
            ))
        }
        let flattenedCalls = allCalls.flatMap { $0 }
        let labels: [InvocationEvaluationLabel] = [.effective, .ineffective, .uncertain]
        var evaluations: [InvocationEvaluation] = []
        for (index, resource) in capabilityResources.prefix(3).enumerated() {
            guard let call = flattenedCalls.first(where: { event in
                event.resourceID == resource.id && (event.kind == .agent || event.kind == .skill)
            }) else { continue }
            evaluations.append(InvocationEvaluation(
                invocationID: call.id, sessionID: call.sessionID, resourceID: resource.id,
                label: labels[index % labels.count], updatedAt: epoch
            ))
        }
        let projects = [
            CapabilityProject(id: projectA, name: "Synthetic Project A", available: true, lastSeenAt: epoch),
            CapabilityProject(id: projectB, name: "Synthetic Project B", available: true, lastSeenAt: epoch)
        ]
        let provenance = resources.filter { $0.ownership == .installed }.map { resource in
            CapabilityProvenance(id: "provenance:\(resource.id)", resourceID: resource.id, sourceType: resource.origin, sourceIdentifier: "synthetic/source", version: "1.0", installedAt: epoch, updatedAt: epoch, confidence: resource.confidence)
        }
        var relations = zip(resources, resources.dropFirst()).prefix(8).map { source, target in
            ResourceRelation(sourceResourceID: source.id, targetResourceID: target.id, relationKind: "uses", confidence: .inferred, evidenceSummary: "Synthetic relation")
        }
        relations.append(ResourceRelation(sourceResourceID: "plugin:validation-enabled", targetResourceID: "skill:validation-plugin-child", relationKind: "contains", confidence: .exact, evidenceSummary: "Synthetic plugin manifest"))
        return Fixture(resources: resources, projects: projects, provenance: provenance, relations: relations, batches: batches, evaluations: evaluations)
    }

    private static func tokenSnapshot(sessionID: String, dayOffset: Int) -> TokenUsageSnapshot {
        TokenUsageSnapshot(id: "tokens:\(sessionID)", sessionID: sessionID, capturedAt: day(dayOffset), usage: try! TokenUsage(inputTokens: 100, cachedInputTokens: 20, cacheWriteInputTokens: 5, outputTokens: 40, reasoningOutputTokens: 10, totalTokens: 175, coverage: .complete), modelID: "synthetic-model", modelName: "Synthetic model", modelConfidence: .inferred)
    }

    private static func quotaSnapshots() -> [QuotaSnapshot] {
        var values: [QuotaSnapshot] = []
        for offset in [-6, -5, -3, -2, -1, 0] {
            let resetAt = offset == 0 ? day(0, hour: 23) : day(1)
            values.append(try! QuotaSnapshot(id: "quota:source-a:\(offset)", capturedAt: day(offset), windowMinutes: 10_080, usedPercent: Double(18 + (offset + 6) * 7), resetsAt: resetAt, limitID: "source-a", limitName: "Synthetic account A", confidence: .inferred))
        }
        values.append(try! QuotaSnapshot(id: "quota:source-b:expired", capturedAt: day(-2), windowMinutes: 10_080, usedPercent: 64, resetsAt: day(-1), limitID: "source-b", limitName: "Synthetic account B", confidence: .exact))
        values.append(try! QuotaSnapshot(id: "quota:source-a:short", capturedAt: day(0, hour: 10), windowMinutes: 300, usedPercent: 25, resetsAt: day(0, hour: 15), limitID: "source-a", limitName: "Synthetic account A", confidence: .inferred))
        return values
    }

    private static func homeVisualQuotaSnapshots() -> [QuotaSnapshot] {
        let longSourceName = "Synthetic account source with a deliberately long readable name"
        let values: [(Int, Double, Date)] = [
            (-6, 0, day(-1)),
            (-5, 100, day(-1)),
            (-3, 28, day(-1)),
            (-1, 74, day(1)),
            (0, 100, day(1))
        ]
        var snapshots = values.map { offset, used, resetAt in
            try! QuotaSnapshot(
                id: "quota:home-visual-a:\(offset)", capturedAt: day(offset), windowMinutes: 10_080,
                usedPercent: used, resetsAt: resetAt, limitID: "home-visual-source-a",
                limitName: longSourceName, confidence: .exact
            )
        }
        snapshots.append(try! QuotaSnapshot(
            id: "quota:home-visual-b:stale", capturedAt: day(-2), windowMinutes: 10_080,
            usedPercent: 42, resetsAt: day(-1), limitID: "home-visual-source-b",
            limitName: "Synthetic stale source", confidence: .inferred
        ))
        return snapshots
    }

    private static func finding(index: Int, resourceID: String, sessionID: String) -> ReviewFinding {
        ReviewFinding(id: "finding:validation-\(index)", ruleID: index == 0 ? "rule.parser-coverage" : "rule.missing-source", resourceID: resourceID, sessionID: sessionID, severity: index.isMultiple(of: 2) ? .warning : .error, confidence: index.isMultiple(of: 2) ? .exact : .inferred, summary: "Synthetic validation finding", evidenceSummary: "Synthetic evidence only", coverage: index == 0 ? .partial : .complete, createdAt: epoch, remediationStatus: .open)
    }
}
#endif
