import Foundation

public enum CapabilityExportIssueSeverity: String, Codable, Sendable, Equatable {
    case warning
    case blocking
}

public enum CapabilityPackageInspection: String, Codable, Sendable, Equatable {
    case scannedText = "scanned_text"
    case unscannedBinary = "unscanned_binary"
    case validatedSymlink = "validated_symlink"
}

public enum CapabilityPackageCheckStatus: String, Codable, Sendable, Equatable {
    case verified
}

public enum CapabilityPluginInventoryStatus: String, Codable, Sendable, Equatable {
    case complete
    case incomplete
}

public struct CapabilityExportIssue: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let severity: CapabilityExportIssueSeverity
    public let code: String
    public let capabilityID: String?
    public let relativePath: String?
    public let message: String

    public init(
        id: String,
        severity: CapabilityExportIssueSeverity,
        code: String,
        capabilityID: String? = nil,
        relativePath: String? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.capabilityID = capabilityID
        self.relativePath = relativePath
        self.message = message
    }
}

public struct CapabilityExportCapabilityOption: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: String
    public let scope: String
    public let projectID: String?

    public init(id: String, name: String, kind: String, scope: String, projectID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scope = scope
        self.projectID = projectID
    }
}

public struct CapabilityExportProjectOption: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let capabilities: [CapabilityExportCapabilityOption]

    public init(id: String, name: String, capabilities: [CapabilityExportCapabilityOption]) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
    }
}

public struct CapabilityExportOptions: Codable, Sendable, Equatable {
    public let globalCapabilities: [CapabilityExportCapabilityOption]
    public let projects: [CapabilityExportProjectOption]

    public init(globalCapabilities: [CapabilityExportCapabilityOption], projects: [CapabilityExportProjectOption]) {
        self.globalCapabilities = globalCapabilities
        self.projects = projects
    }
}

public struct CapabilityExportProjectSelection: Codable, Sendable, Equatable {
    public let projectID: String
    public var includeAgents: Bool
    public var includeSkills: Bool
    public var includeInstructions: Bool

    public init(
        projectID: String,
        includeAgents: Bool = false,
        includeSkills: Bool = false,
        includeInstructions: Bool = false
    ) {
        self.projectID = projectID
        self.includeAgents = includeAgents
        self.includeSkills = includeSkills
        self.includeInstructions = includeInstructions
    }

    public var isIncluded: Bool { includeAgents || includeSkills || includeInstructions }
}

/// User choices for one export. Absolute source paths deliberately remain in
/// the coordinator environment and never cross this public package contract.
public struct CapabilityExportSelection: Codable, Sendable, Equatable {
    public var includeGlobalAgents: Bool
    public var includeGlobalSkills: Bool
    public var includeGlobalInstructions: Bool
    public var projects: [CapabilityExportProjectSelection]
    public var excludedCapabilityIDs: Set<String>

    public init(
        includeGlobalAgents: Bool = true,
        includeGlobalSkills: Bool = true,
        includeGlobalInstructions: Bool = true,
        projects: [CapabilityExportProjectSelection] = [],
        excludedCapabilityIDs: Set<String> = []
    ) {
        self.includeGlobalAgents = includeGlobalAgents
        self.includeGlobalSkills = includeGlobalSkills
        self.includeGlobalInstructions = includeGlobalInstructions
        self.projects = projects
        self.excludedCapabilityIDs = excludedCapabilityIDs
    }

    public static func defaults(for options: CapabilityExportOptions) -> CapabilityExportSelection {
        CapabilityExportSelection(
            projects: options.projects.map { CapabilityExportProjectSelection(projectID: $0.id) }
        )
    }
}

public struct CapabilityPackageEntry: Codable, Sendable, Equatable {
    public let archivePath: String
    public let logicalRoot: String
    public let relativePath: String
    public let byteSize: Int64
    public let sha256: String
    public let executable: Bool
    public let contentType: String
    public let inspection: CapabilityPackageInspection
    public let checkStatus: CapabilityPackageCheckStatus

    public init(
        archivePath: String,
        logicalRoot: String,
        relativePath: String,
        byteSize: Int64,
        sha256: String,
        executable: Bool,
        contentType: String,
        inspection: CapabilityPackageInspection,
        checkStatus: CapabilityPackageCheckStatus = .verified
    ) {
        self.archivePath = archivePath
        self.logicalRoot = logicalRoot
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.executable = executable
        self.contentType = contentType
        self.inspection = inspection
        self.checkStatus = checkStatus
    }
}

public struct CapabilityPackageProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CapabilityPackageCapability: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: String
    public let scope: String
    public let ownership: String
    public let projectID: String?
    public let logicalRoot: String
    public let archiveBasePath: String
    public let files: [String]

    public init(
        id: String,
        name: String,
        kind: String,
        scope: String,
        ownership: String,
        projectID: String? = nil,
        logicalRoot: String,
        archiveBasePath: String,
        files: [String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scope = scope
        self.ownership = ownership
        self.projectID = projectID
        self.logicalRoot = logicalRoot
        self.archiveBasePath = archiveBasePath
        self.files = files
    }
}

public struct CapabilityPackageProducer: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let build: String

    public init(name: String = "Codex Director", version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }
}

public struct CapabilityPackagePlatform: Codable, Sendable, Equatable {
    public let operatingSystem: String
    public let operatingSystemVersion: String
    public let architecture: String

    public init(operatingSystem: String, operatingSystemVersion: String, architecture: String) {
        self.operatingSystem = operatingSystem
        self.operatingSystemVersion = operatingSystemVersion
        self.architecture = architecture
    }
}

public struct CapabilityPackageManifestV1: Codable, Sendable, Equatable {
    public let format: String
    public let formatVersion: Int
    public let createdAt: Date
    public let producer: CapabilityPackageProducer
    public let platform: CapabilityPackagePlatform
    public let projects: [CapabilityPackageProject]
    public let capabilities: [CapabilityPackageCapability]
    public let entries: [CapabilityPackageEntry]

    public init(
        createdAt: Date,
        producer: CapabilityPackageProducer,
        platform: CapabilityPackagePlatform,
        projects: [CapabilityPackageProject],
        capabilities: [CapabilityPackageCapability],
        entries: [CapabilityPackageEntry]
    ) {
        self.format = "codex-capabilities"
        self.formatVersion = 1
        self.createdAt = createdAt
        self.producer = producer
        self.platform = platform
        self.projects = projects
        self.capabilities = capabilities
        self.entries = entries
    }
}

public struct CapabilityPackagePlugin: Codable, Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let marketplace: String?
    public let version: String?
    public let enabled: Bool

    public init(identifier: String, name: String, marketplace: String?, version: String?, enabled: Bool) {
        self.identifier = identifier
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.enabled = enabled
    }
}

public struct CapabilityPackagePluginList: Codable, Sendable, Equatable {
    public let status: CapabilityPluginInventoryStatus
    public let generatedAt: Date
    public let plugins: [CapabilityPackagePlugin]
    public let issue: String?

    public init(
        status: CapabilityPluginInventoryStatus,
        generatedAt: Date,
        plugins: [CapabilityPackagePlugin],
        issue: String? = nil
    ) {
        self.status = status
        self.generatedAt = generatedAt
        self.plugins = plugins
        self.issue = issue
    }
}

public struct CapabilityPackageRequirement: Codable, Sendable, Equatable {
    public let name: String
    public let kind: String
    public let detectedFrom: [String]

    public init(name: String, kind: String, detectedFrom: [String]) {
        self.name = name
        self.kind = kind
        self.detectedFrom = detectedFrom
    }
}

public struct CapabilityPackageRequirementList: Codable, Sendable, Equatable {
    public let requirements: [CapabilityPackageRequirement]

    public init(requirements: [CapabilityPackageRequirement]) {
        self.requirements = requirements
    }
}

public struct CapabilityPackageChecksums: Codable, Sendable, Equatable {
    public let algorithm: String
    public let files: [String: String]

    public init(files: [String: String]) {
        self.algorithm = "SHA-256"
        self.files = files
    }
}

public struct CapabilityExportPreview: Codable, Sendable, Equatable {
    public let capabilityCount: Int
    public let agentCount: Int
    public let skillCount: Int
    public let instructionCount: Int
    public let fileCount: Int
    public let byteSize: Int64
    public let binaryFileCount: Int
    public let pluginStatus: CapabilityPluginInventoryStatus
    public let pluginCount: Int
    public let requirementCount: Int
    public let excludedCapabilityIDs: [String]
    public let issues: [CapabilityExportIssue]

    public init(
        capabilityCount: Int,
        agentCount: Int,
        skillCount: Int,
        instructionCount: Int,
        fileCount: Int,
        byteSize: Int64,
        binaryFileCount: Int,
        pluginStatus: CapabilityPluginInventoryStatus,
        pluginCount: Int,
        requirementCount: Int,
        excludedCapabilityIDs: [String],
        issues: [CapabilityExportIssue]
    ) {
        self.capabilityCount = capabilityCount
        self.agentCount = agentCount
        self.skillCount = skillCount
        self.instructionCount = instructionCount
        self.fileCount = fileCount
        self.byteSize = byteSize
        self.binaryFileCount = binaryFileCount
        self.pluginStatus = pluginStatus
        self.pluginCount = pluginCount
        self.requirementCount = requirementCount
        self.excludedCapabilityIDs = excludedCapabilityIDs
        self.issues = issues
    }

    public var hasBlockingIssues: Bool { issues.contains { $0.severity == .blocking } }
}

public struct CapabilityExportProjectSource: Sendable, Equatable {
    public let directory: URL
    public let displayName: String

    public init(directory: URL, displayName: String? = nil) {
        self.directory = directory.standardizedFileURL
        self.displayName = displayName ?? directory.lastPathComponent
    }
}

/// In-memory source configuration. It is intentionally not Codable so local
/// absolute paths cannot accidentally become part of the package contract.
public struct CapabilityExportEnvironment: Sendable, Equatable {
    public let homeDirectory: URL
    public let projects: [CapabilityExportProjectSource]
    public let producer: CapabilityPackageProducer
    public let platform: CapabilityPackagePlatform

    public init(
        homeDirectory: URL,
        projects: [CapabilityExportProjectSource],
        producer: CapabilityPackageProducer,
        platform: CapabilityPackagePlatform
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.projects = projects
        self.producer = producer
        self.platform = platform
    }
}

public enum CapabilityExportError: Error, Sendable, Equatable {
    case operationInProgress
    case noPreparedPackage
    case blockingIssues
    case invalidSelection
    case sourceChanged
    case invalidArchive
    case unsafeArchivePath
    case checksumMismatch
    case cancelled
}

/// Shared application gate for capability-package operations. Export and
/// restore must never mutate their staging/target state concurrently.
public actor CapabilityMigrationGate {
    public enum Error: Swift.Error, Sendable, Equatable {
        case operationInProgress
    }

    private var owner: UUID?

    public init() {}

    public func acquire() throws -> UUID {
        guard owner == nil else { throw Error.operationInProgress }
        let token = UUID()
        owner = token
        return token
    }

    public func release(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
    }
}

public enum CapabilityRestoreEntryAction: String, Codable, Sendable, Equatable {
    case create
    case skipIdentical = "skip_identical"
    case conflict
}

public enum CapabilityRestoreIssueSeverity: String, Codable, Sendable, Equatable {
    case warning
    case blocking
}

public struct CapabilityRestoreIssue: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let severity: CapabilityRestoreIssueSeverity
    public let code: String
    public let capabilityID: String?
    public let archivePath: String?
    public let message: String

    public init(
        id: String = UUID().uuidString,
        severity: CapabilityRestoreIssueSeverity,
        code: String,
        capabilityID: String? = nil,
        archivePath: String? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.capabilityID = capabilityID
        self.archivePath = archivePath
        self.message = message
    }
}

/// A project mapping is intentionally in-memory only. The destination URL is
/// never encoded into a package, cache, log or persistent restore receipt.
public struct CapabilityRestoreProjectMapping: Sendable, Equatable {
    public let packageProjectID: String
    public let destinationURL: URL

    public init(packageProjectID: String, destinationURL: URL) {
        self.packageProjectID = packageProjectID
        self.destinationURL = destinationURL.standardizedFileURL
    }
}

public struct CapabilityRestoreSelection: Sendable, Equatable {
    public var includedCapabilityIDs: Set<String>
    /// Capabilities explicitly removed from the pending restore. Keeping this
    /// separate from inclusion makes the user's exclusion decision visible to
    /// callers without persisting any source or destination path.
    public var excludedCapabilityIDs: Set<String>
    public var projectMappings: [CapabilityRestoreProjectMapping]

    public init(
        includedCapabilityIDs: Set<String> = [],
        excludedCapabilityIDs: Set<String> = [],
        projectMappings: [CapabilityRestoreProjectMapping] = []
    ) {
        self.includedCapabilityIDs = includedCapabilityIDs
        self.excludedCapabilityIDs = excludedCapabilityIDs
        self.projectMappings = projectMappings
    }

    public static func defaults(for manifest: CapabilityPackageManifestV1) -> CapabilityRestoreSelection {
        CapabilityRestoreSelection(includedCapabilityIDs: Set(manifest.capabilities.map(\.id)))
    }
}

public struct CapabilityRestorePackageInfo: Sendable, Equatable {
    public let manifest: CapabilityPackageManifestV1
    public let plugins: CapabilityPackagePluginList
    public let requirements: CapabilityPackageRequirementList
    public let packageFileName: String

    public init(
        manifest: CapabilityPackageManifestV1,
        plugins: CapabilityPackagePluginList,
        requirements: CapabilityPackageRequirementList,
        packageFileName: String
    ) {
        self.manifest = manifest
        self.plugins = plugins
        self.requirements = requirements
        self.packageFileName = packageFileName
    }
}

public struct CapabilityRestoreEntryPreview: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let capabilityID: String
    public let archivePath: String
    public let displayPath: String
    public let byteSize: Int64
    public let sha256: String
    public let contentType: String
    public let executable: Bool
    public let action: CapabilityRestoreEntryAction
    public let difference: String?

    public init(
        id: String = UUID().uuidString,
        capabilityID: String,
        archivePath: String,
        displayPath: String,
        byteSize: Int64,
        sha256: String,
        contentType: String,
        executable: Bool,
        action: CapabilityRestoreEntryAction,
        difference: String? = nil
    ) {
        self.id = id
        self.capabilityID = capabilityID
        self.archivePath = archivePath
        self.displayPath = displayPath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.contentType = contentType
        self.executable = executable
        self.action = action
        self.difference = difference
    }
}

public struct CapabilityRestorePreview: Codable, Sendable, Equatable {
    public let capabilityCount: Int
    public let createCount: Int
    public let skipCount: Int
    public let conflictCount: Int
    public let byteSize: Int64
    public let binaryWarningCount: Int
    public let pluginStatus: CapabilityPluginInventoryStatus
    public let pluginCount: Int
    public let requirementCount: Int
    public let entries: [CapabilityRestoreEntryPreview]
    public let issues: [CapabilityRestoreIssue]

    public init(
        capabilityCount: Int,
        createCount: Int,
        skipCount: Int,
        conflictCount: Int,
        byteSize: Int64,
        binaryWarningCount: Int,
        pluginStatus: CapabilityPluginInventoryStatus,
        pluginCount: Int,
        requirementCount: Int,
        entries: [CapabilityRestoreEntryPreview],
        issues: [CapabilityRestoreIssue]
    ) {
        self.capabilityCount = capabilityCount
        self.createCount = createCount
        self.skipCount = skipCount
        self.conflictCount = conflictCount
        self.byteSize = byteSize
        self.binaryWarningCount = binaryWarningCount
        self.pluginStatus = pluginStatus
        self.pluginCount = pluginCount
        self.requirementCount = requirementCount
        self.entries = entries
        self.issues = issues
    }

    public var hasBlockingIssues: Bool {
        issues.contains { $0.severity == .blocking } || conflictCount > 0
    }
}

public enum CapabilityRestorePhase: String, Sendable, Equatable {
    case verifying
    case mapping
    case preflighting
    case restoring
    case rescanning
    case finished
}

public struct CapabilityRestoreProgress: Sendable, Equatable {
    public let phase: CapabilityRestorePhase
    public let completedItems: Int
    public let totalItems: Int?

    public init(phase: CapabilityRestorePhase, completedItems: Int = 0, totalItems: Int? = nil) {
        self.phase = phase
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

public struct CapabilityRestoreResult: Sendable, Equatable {
    public let createdCount: Int
    public let skippedCount: Int
    public let conflictCount: Int
    public let warnings: [CapabilityRestoreIssue]
    public let rescanRequired: Bool
    /// Operation-scoped local directories prepared before restore writes.
    /// The URLs remain in memory only and are never encoded or logged.
    public let quarantineLocations: [CapabilityRestoreQuarantineLocation]

    public init(
        createdCount: Int,
        skippedCount: Int,
        conflictCount: Int,
        warnings: [CapabilityRestoreIssue] = [],
        rescanRequired: Bool,
        quarantineLocations: [CapabilityRestoreQuarantineLocation] = []
    ) {
        self.createdCount = createdCount
        self.skippedCount = skippedCount
        self.conflictCount = conflictCount
        self.warnings = warnings
        self.rescanRequired = rescanRequired
        self.quarantineLocations = quarantineLocations
    }
}

/// An ephemeral handle to an operation-owned local quarantine directory.
/// `placeholder` is safe to display; `directoryURL` exists solely so an
/// explicit user action can reveal the directory in Finder. Neither value is
/// persisted in a restore receipt, cache, package, or log.
public struct CapabilityRestoreQuarantineLocation: Identifiable, Sendable, Equatable {
    public let id: String
    public let placeholder: String
    public let directoryURL: URL

    public init(id: String, placeholder: String, directoryURL: URL) {
        self.id = id
        self.placeholder = placeholder
        self.directoryURL = directoryURL
    }
}

public struct CapabilityRestoreRollbackResult: Sendable, Equatable {
    /// Legacy compatibility counters. Strict non-destructive restore cleanup
    /// never increments them; use the quarantine counters below.
    public let removedCount: Int
    public let removedDirectoryCount: Int
    public let skippedModifiedCount: Int
    public let failedRemovalCount: Int
    public let issues: [CapabilityRestoreIssue]
    public let quarantinedCount: Int
    public let quarantinedDirectoryCount: Int
    public let quarantineLocations: [CapabilityRestoreQuarantineLocation]

    public init(
        removedCount: Int,
        removedDirectoryCount: Int = 0,
        skippedModifiedCount: Int,
        failedRemovalCount: Int = 0,
        issues: [CapabilityRestoreIssue] = [],
        quarantinedCount: Int = 0,
        quarantinedDirectoryCount: Int = 0,
        quarantineLocations: [CapabilityRestoreQuarantineLocation] = []
    ) {
        self.removedCount = removedCount
        self.removedDirectoryCount = removedDirectoryCount
        self.skippedModifiedCount = skippedModifiedCount
        self.failedRemovalCount = failedRemovalCount
        self.issues = issues
        self.quarantinedCount = quarantinedCount
        self.quarantinedDirectoryCount = quarantinedDirectoryCount
        self.quarantineLocations = quarantineLocations
    }

    public var hasResidualItems: Bool {
        !quarantineLocations.isEmpty || quarantinedCount > 0 || quarantinedDirectoryCount > 0 || skippedModifiedCount > 0 || failedRemovalCount > 0
    }
}

/// Result of mandatory non-destructive quarantine after a restore fails or is
/// cancelled. Issue paths use package placeholders only. Quarantine URLs are
/// ephemeral Finder reveal handles and are never encoded or persisted.
public struct CapabilityRestoreCleanupResult: Sendable, Equatable {
    /// Legacy compatibility counters, always zero in production.
    public let removedCount: Int
    public let removedDirectoryCount: Int
    public let skippedModifiedCount: Int
    public let failedRemovalCount: Int
    public let issues: [CapabilityRestoreIssue]
    public let quarantinedCount: Int
    public let quarantinedDirectoryCount: Int
    public let quarantineLocations: [CapabilityRestoreQuarantineLocation]

    public init(
        removedCount: Int,
        removedDirectoryCount: Int,
        skippedModifiedCount: Int,
        failedRemovalCount: Int,
        issues: [CapabilityRestoreIssue] = [],
        quarantinedCount: Int = 0,
        quarantinedDirectoryCount: Int = 0,
        quarantineLocations: [CapabilityRestoreQuarantineLocation] = []
    ) {
        self.removedCount = removedCount
        self.removedDirectoryCount = removedDirectoryCount
        self.skippedModifiedCount = skippedModifiedCount
        self.failedRemovalCount = failedRemovalCount
        self.issues = issues
        self.quarantinedCount = quarantinedCount
        self.quarantinedDirectoryCount = quarantinedDirectoryCount
        self.quarantineLocations = quarantineLocations
    }

    public var hasResidualItems: Bool {
        !quarantineLocations.isEmpty || quarantinedCount > 0 || quarantinedDirectoryCount > 0 || skippedModifiedCount > 0 || failedRemovalCount > 0
    }
}

/// Structured restore failure that preserves both the operation reason and
/// the cleanup outcome. Callers must surface residual items rather than
/// replacing this information with a generic error.
public struct CapabilityRestoreOperationFailure: Swift.Error, Sendable, Equatable {
    public let reason: CapabilityRestoreError
    public let cleanup: CapabilityRestoreCleanupResult

    public init(reason: CapabilityRestoreError, cleanup: CapabilityRestoreCleanupResult) {
        self.reason = reason
        self.cleanup = cleanup
    }
}

public enum CapabilityRestoreError: Swift.Error, Sendable, Equatable {
    case operationInProgress
    case noPackage
    case untrustedSource
    case invalidArchive
    case unsafeArchivePath
    case checksumMismatch
    case missingProjectMapping(String)
    case duplicateProjectMapping
    case invalidProjectMapping
    case destinationNotWritable
    case packageChanged
    case targetChanged
    case conflictsRemain
    case preflightRequired
    case cancelled
    case writeFailed
    case rollbackUnavailable
}

public enum CapabilityExportPhase: String, Sendable, Equatable {
    case discovering
    case inspecting
    case packaging
    case verifying
    case finished
}

public struct CapabilityExportProgress: Sendable, Equatable {
    public let phase: CapabilityExportPhase
    public let completedItems: Int
    public let totalItems: Int?

    public init(phase: CapabilityExportPhase, completedItems: Int = 0, totalItems: Int? = nil) {
        self.phase = phase
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}
