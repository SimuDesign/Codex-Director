import Foundation

/// User-visible kinds of verified capability-document change.
public enum CapabilityChangeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case added
    case modified
    case missing
    case reappeared
}

/// Fixed, privacy-safe detector diagnostics. These codes may be persisted or
/// displayed, but raw filesystem errors and source locations never are.
public enum CapabilityHistoryIssueCode: String, Codable, Sendable, Hashable, CaseIterable {
    case cacheBatchIgnored
    case invalidObservation
    case interruptedMissingConfirmation
    case clockRollback
    case signatureAlgorithmChanged
    case retentionTruncated
    case historyGap
    case fileBudgetExceeded
    case readOnlyLockConflict
    case storageUnavailable
    case corruptStorage
    case unsupportedSchema
}

public enum CapabilityHistoryPresence: String, Codable, Sendable, Hashable {
    case present
    case missing
}

/// One immutable history event. It contains only allowlisted display metadata
/// and document labels; source paths, source bytes and diffs are never stored.
public struct CapabilityChangeEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let resourceID: String
    public let name: String
    public let resourceKind: ResourceKind
    public let scope: ResourceScope
    public let projectID: String?
    public let kind: CapabilityChangeKind
    public let changedDocuments: Set<CapabilityTrackedDocument>
    /// False means the aggregate capability digest changed but the input did
    /// not carry per-document digests. In that case changedDocuments is empty
    /// and presentation must use generic “tracked documents changed” wording.
    public let changedDocumentsAreExact: Bool
    public let observedAt: Date
    public let previousConfirmedAt: Date?
    public let sequence: Int64

    /// Monotonic retention anchor kept separate from the wall-clock
    /// observation. This prevents a clock rollback from immediately pruning a
    /// newly committed event while preserving the truthful observedAt value.
    let retentionObservedAt: Date

    public init(
        id: String,
        resourceID: String,
        name: String,
        resourceKind: ResourceKind,
        scope: ResourceScope,
        projectID: String?,
        kind: CapabilityChangeKind,
        changedDocuments: Set<CapabilityTrackedDocument>,
        changedDocumentsAreExact: Bool = true,
        observedAt: Date,
        previousConfirmedAt: Date?,
        sequence: Int64,
        retentionObservedAt: Date? = nil
    ) {
        self.id = id
        self.resourceID = resourceID
        self.name = name
        self.resourceKind = resourceKind
        self.scope = scope
        self.projectID = projectID
        self.kind = kind
        self.changedDocuments = changedDocuments
        self.changedDocumentsAreExact = changedDocumentsAreExact
        self.observedAt = observedAt
        self.previousConfirmedAt = previousConfirmedAt
        self.sequence = sequence
        self.retentionObservedAt = retentionObservedAt ?? observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, resourceID, name, resourceKind, scope, projectID, kind
        case changedDocuments, changedDocumentsAreExact, observedAt, previousConfirmedAt, sequence, retentionObservedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        resourceID = try values.decode(String.self, forKey: .resourceID)
        name = try values.decode(String.self, forKey: .name)
        resourceKind = try values.decode(ResourceKind.self, forKey: .resourceKind)
        scope = try values.decode(ResourceScope.self, forKey: .scope)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        kind = try values.decode(CapabilityChangeKind.self, forKey: .kind)
        changedDocuments = Set(try values.decode([CapabilityTrackedDocument].self, forKey: .changedDocuments))
        changedDocumentsAreExact = try values.decode(Bool.self, forKey: .changedDocumentsAreExact)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        previousConfirmedAt = try values.decodeIfPresent(Date.self, forKey: .previousConfirmedAt)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        retentionObservedAt = try values.decode(Date.self, forKey: .retentionObservedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(resourceID, forKey: .resourceID)
        try values.encode(name, forKey: .name)
        try values.encode(resourceKind, forKey: .resourceKind)
        try values.encode(scope, forKey: .scope)
        try values.encodeIfPresent(projectID, forKey: .projectID)
        try values.encode(kind, forKey: .kind)
        try values.encode(changedDocuments.sorted { $0.rawValue < $1.rawValue }, forKey: .changedDocuments)
        try values.encode(changedDocumentsAreExact, forKey: .changedDocumentsAreExact)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encodeIfPresent(previousConfirmedAt, forKey: .previousConfirmedAt)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(retentionObservedAt, forKey: .retentionObservedAt)
    }
}

/// Current privacy-safe baseline for one stable capability identity.
public struct CapabilityHistoryBaseline: Codable, Sendable, Equatable, Identifiable {
    public let resourceID: String
    public let sourceRootID: String
    public let name: String
    public let resourceKind: ResourceKind
    public let scope: ResourceScope
    public let projectID: String?
    public let documents: [CapabilityTrackedDocument]
    public let signature: String
    public let documentSignatures: [CapabilityTrackedDocumentSignature]
    public let signatureAlgorithm: String
    public let presence: CapabilityHistoryPresence
    public let lastConfirmedAt: Date
    public let missingSince: Date?

    public var id: String { resourceID }

    public init(
        resourceID: String,
        sourceRootID: String,
        name: String,
        resourceKind: ResourceKind,
        scope: ResourceScope,
        projectID: String?,
        documents: [CapabilityTrackedDocument],
        signature: String,
        documentSignatures: [CapabilityTrackedDocumentSignature] = [],
        signatureAlgorithm: String,
        presence: CapabilityHistoryPresence,
        lastConfirmedAt: Date,
        missingSince: Date?
    ) {
        self.resourceID = resourceID
        self.sourceRootID = sourceRootID
        self.name = name
        self.resourceKind = resourceKind
        self.scope = scope
        self.projectID = projectID
        self.documents = documents.sorted { $0.rawValue < $1.rawValue }
        self.signature = signature
        self.documentSignatures = documentSignatures.sorted { $0.document.rawValue < $1.document.rawValue }
        self.signatureAlgorithm = signatureAlgorithm
        self.presence = presence
        self.lastConfirmedAt = lastConfirmedAt
        self.missingSince = missingSince
    }
}

public struct CapabilityHistoryScopeBaseline: Codable, Sendable, Equatable, Identifiable {
    public let rootID: String
    public let scope: ResourceScope
    public let rootKind: String
    public let initializedAt: Date
    public let lastCompleteAt: Date

    public var id: String { rootID }

    public init(rootID: String, scope: ResourceScope, rootKind: String, initializedAt: Date, lastCompleteAt: Date) {
        self.rootID = rootID
        self.scope = scope
        self.rootKind = rootKind
        self.initializedAt = initializedAt
        self.lastCompleteAt = lastCompleteAt
    }
}

public struct CapabilityHistoryPendingMissing: Codable, Sendable, Equatable, Identifiable {
    public let resourceID: String
    public let sourceRootID: String
    public let firstMissingAt: Date
    public let previousConfirmedAt: Date

    public var id: String { resourceID }

    public init(resourceID: String, sourceRootID: String, firstMissingAt: Date, previousConfirmedAt: Date) {
        self.resourceID = resourceID
        self.sourceRootID = sourceRootID
        self.firstMissingAt = firstMissingAt
        self.previousConfirmedAt = previousConfirmedAt
    }
}

/// Versioned document stored in the single history JSON file.
public struct CapabilityHistoryStateV1: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let epoch: UInt64
    public let revision: Int64
    public let nextSequence: Int64
    public let retentionAnchorAt: Date?
    public let truncatedBefore: Date?
    /// Coverage of the latest filesystem observation batch. This is current
    /// status, not proof that prior gaps were reconstructed.
    public let latestScanCoverage: CapabilityHistoryCoverage?
    public let scopes: [CapabilityHistoryScopeBaseline]
    public let baselines: [CapabilityHistoryBaseline]
    public let pendingMissing: [CapabilityHistoryPendingMissing]
    public let events: [CapabilityChangeEvent]
    public let issueCodes: [CapabilityHistoryIssueCode]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        epoch: UInt64,
        revision: Int64 = 0,
        nextSequence: Int64 = 1,
        retentionAnchorAt: Date? = nil,
        truncatedBefore: Date? = nil,
        latestScanCoverage: CapabilityHistoryCoverage? = nil,
        scopes: [CapabilityHistoryScopeBaseline] = [],
        baselines: [CapabilityHistoryBaseline] = [],
        pendingMissing: [CapabilityHistoryPendingMissing] = [],
        events: [CapabilityChangeEvent] = [],
        issueCodes: [CapabilityHistoryIssueCode] = []
    ) {
        self.schemaVersion = schemaVersion
        self.epoch = epoch
        self.revision = revision
        self.nextSequence = nextSequence
        self.retentionAnchorAt = retentionAnchorAt
        self.truncatedBefore = truncatedBefore
        self.latestScanCoverage = latestScanCoverage
        self.scopes = scopes.sorted { $0.rootID < $1.rootID }
        self.baselines = baselines.sorted { $0.resourceID < $1.resourceID }
        self.pendingMissing = pendingMissing.sorted { $0.resourceID < $1.resourceID }
        self.events = events.sorted { $0.sequence < $1.sequence }
        self.issueCodes = Array(Set(issueCodes)).sorted { $0.rawValue < $1.rawValue }
    }

    public static func empty(epoch: UInt64) -> Self {
        Self(epoch: epoch)
    }
}

public struct CapabilityHistoryRetentionPolicy: Sendable, Equatable {
    public let duration: TimeInterval
    public let maximumEventsPerResource: Int
    public let maximumEvents: Int

    public init(
        duration: TimeInterval = 180 * 86_400,
        maximumEventsPerResource: Int = 100,
        maximumEvents: Int = 20_000
    ) {
        self.duration = duration
        self.maximumEventsPerResource = maximumEventsPerResource
        self.maximumEvents = maximumEvents
    }

    public static let standard = Self()
}

public struct CapabilityHistoryQuery: Sendable, Equatable {
    public let resourceID: String?
    public let resourceKinds: Set<ResourceKind>
    public let changeKinds: Set<CapabilityChangeKind>
    public let observedOnOrAfter: Date?
    public let observedOnOrBefore: Date?
    public let beforeSequence: Int64?
    public let limit: Int

    public init(
        resourceID: String? = nil,
        resourceKinds: Set<ResourceKind> = [],
        changeKinds: Set<CapabilityChangeKind> = [],
        observedOnOrAfter: Date? = nil,
        observedOnOrBefore: Date? = nil,
        beforeSequence: Int64? = nil,
        limit: Int = 20
    ) {
        self.resourceID = resourceID
        self.resourceKinds = resourceKinds
        self.changeKinds = changeKinds
        self.observedOnOrAfter = observedOnOrAfter
        self.observedOnOrBefore = observedOnOrBefore
        self.beforeSequence = beforeSequence
        self.limit = limit
    }
}

public struct CapabilityHistoryPage: Sendable, Equatable {
    public let events: [CapabilityChangeEvent]
    public let nextBeforeSequence: Int64?
    public let revision: Int64
    public let epoch: UInt64
    public let truncatedBefore: Date?
    public let issueCodes: [CapabilityHistoryIssueCode]

    public init(
        events: [CapabilityChangeEvent],
        nextBeforeSequence: Int64?,
        revision: Int64,
        epoch: UInt64,
        truncatedBefore: Date?,
        issueCodes: [CapabilityHistoryIssueCode]
    ) {
        self.events = events
        self.nextBeforeSequence = nextBeforeSequence
        self.revision = revision
        self.epoch = epoch
        self.truncatedBefore = truncatedBefore
        self.issueCodes = issueCodes
    }
}

/// Store-authenticated interval boundary for one retained event. The next
/// value is computed from the complete retained history of the same stable
/// resource, independent of the UI's filters and current page.
public struct CapabilityHistoryEventBoundary: Sendable, Equatable {
    public let eventID: String
    public let resourceID: String
    public let observedAt: Date
    public let nextObservedAt: Date?
    public let epoch: UInt64
    public let revision: Int64

    public init(
        eventID: String,
        resourceID: String,
        observedAt: Date,
        nextObservedAt: Date?,
        epoch: UInt64,
        revision: Int64
    ) {
        self.eventID = eventID
        self.resourceID = resourceID
        self.observedAt = observedAt
        self.nextObservedAt = nextObservedAt
        self.epoch = epoch
        self.revision = revision
    }
}

public enum CapabilityHistoryAccessMode: String, Sendable, Equatable {
    case readWrite
    case readOnly
    case unavailable
}

public struct CapabilityHistoryStatus: Sendable, Equatable {
    public let accessMode: CapabilityHistoryAccessMode
    public let epoch: UInt64?
    public let revision: Int64?
    public let eventCount: Int?
    public let baselineCount: Int?
    /// Explicit scope initialization state. A successfully observed empty
    /// scope has `isInitialized == true` and `baselineCount == 0`; nil means
    /// history has not been read or is unavailable.
    public let isInitialized: Bool?
    public let initializedScopeCount: Int?
    /// Nil means the state was unavailable. A non-nil value preserves the
    /// distinction between a complete empty scan and partial/unavailable
    /// source coverage.
    public let latestScanCoverage: CapabilityHistoryCoverage?
    /// Ephemeral coordinator metadata. This is true only while the most
    /// recent filesystem observation could not be committed; it is never
    /// encoded into the history state or used as a substitute for a read
    /// error reported by the store.
    public let latestObservationSaveFailed: Bool
    public let pendingMissingCount: Int?
    public let issueCodes: [CapabilityHistoryIssueCode]

    public init(
        accessMode: CapabilityHistoryAccessMode,
        epoch: UInt64?,
        revision: Int64?,
        eventCount: Int?,
        baselineCount: Int?,
        isInitialized: Bool? = nil,
        initializedScopeCount: Int? = nil,
        latestScanCoverage: CapabilityHistoryCoverage? = nil,
        pendingMissingCount: Int? = nil,
        issueCodes: [CapabilityHistoryIssueCode] = [],
        latestObservationSaveFailed: Bool = false
    ) {
        self.accessMode = accessMode
        self.epoch = epoch
        self.revision = revision
        self.eventCount = eventCount
        self.baselineCount = baselineCount
        self.isInitialized = isInitialized
        self.initializedScopeCount = initializedScopeCount
        self.latestScanCoverage = latestScanCoverage
        self.latestObservationSaveFailed = latestObservationSaveFailed
        self.pendingMissingCount = pendingMissingCount
        self.issueCodes = issueCodes
    }

    public static let unavailable = Self(
        accessMode: .unavailable,
        epoch: nil,
        revision: nil,
        eventCount: nil,
        baselineCount: nil,
        isInitialized: nil,
        initializedScopeCount: nil,
        latestScanCoverage: nil,
        pendingMissingCount: nil,
        issueCodes: [.storageUnavailable]
    )
}

public struct CapabilityHistoryCommitResult: Sendable, Equatable {
    public let revision: Int64
    public let epoch: UInt64
    public let newEvents: [CapabilityChangeEvent]
    public let issueCodes: [CapabilityHistoryIssueCode]

    public init(revision: Int64, epoch: UInt64, newEvents: [CapabilityChangeEvent], issueCodes: [CapabilityHistoryIssueCode]) {
        self.revision = revision
        self.epoch = epoch
        self.newEvents = newEvents
        self.issueCodes = issueCodes
    }
}
