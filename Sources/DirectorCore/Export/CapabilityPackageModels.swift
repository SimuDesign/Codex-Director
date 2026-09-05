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
