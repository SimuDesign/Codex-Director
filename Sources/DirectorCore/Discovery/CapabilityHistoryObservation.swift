import CryptoKit
import Foundation

/// Documents that are part of the first capability-history observation
/// contract. A Skill is deliberately represented by its manifest only; helper
/// scripts and binary assets are outside this version's tracking boundary.
public enum CapabilityTrackedDocument: String, Codable, Sendable, Hashable, CaseIterable {
    case agentConfiguration
    case agentBrief
    case skillManifest
}

/// Privacy-safe digest for one already-validated tracked document. The source
/// bytes and path never cross the scanner boundary.
public struct CapabilityTrackedDocumentSignature: Codable, Sendable, Equatable, Hashable {
    public let document: CapabilityTrackedDocument
    public let sha256: String

    public init(document: CapabilityTrackedDocument, sha256: String) {
        self.document = document
        self.sha256 = sha256
    }
}

/// Completeness of a single approved source scope for history purposes.
public enum CapabilityHistoryCoverage: String, Codable, Sendable, Hashable {
    case complete
    case partial
    case unavailable
    case unstable

    public func dominating(with other: Self) -> Self {
        switch (self, other) {
        case (.unstable, _), (_, .unstable): return .unstable
        case (.unavailable, _), (_, .unavailable): return .unavailable
        case (.partial, _), (_, .partial): return .partial
        default: return .complete
        }
    }

    /// Aggregates independently observed source scopes. A source that is
    /// unavailable limits the claim only when it is the entire observation;
    /// when another scope is usable, the aggregate is partial rather than
    /// unreadable. Same-source duplicate scopes continue to use
    /// `dominating(with:)` before reaching this cross-source rule.
    public static func aggregate(_ coverages: [Self]) -> Self {
        guard !coverages.isEmpty else { return .unavailable }
        if coverages.contains(.unstable) { return .unstable }

        let usable = coverages.filter { $0 != .unavailable }
        guard !usable.isEmpty else { return .unavailable }
        if coverages.contains(.unavailable) || usable.contains(.partial) {
            return .partial
        }
        return .complete
    }
}

/// The only positive source observation passed to the future history detector.
/// It intentionally contains no path, source body, diff, prompt or exception.
public struct CapabilityHistoryObservation: Codable, Sendable, Equatable, Identifiable {
    public static let signatureAlgorithm = "sha256-v1"

    public let id: String
    public let resourceID: String
    public let sourceRootID: String
    public let name: String
    public let kind: ResourceKind
    public let scope: ResourceScope
    public let projectID: String?
    public let documents: Set<CapabilityTrackedDocument>
    public let signature: String
    public let documentSignatures: [CapabilityTrackedDocumentSignature]
    public let observedAt: Date
    public let signatureAlgorithm: String

    public init(
        resourceID: String,
        sourceRootID: String,
        name: String,
        kind: ResourceKind,
        scope: ResourceScope,
        projectID: String?,
        documents: Set<CapabilityTrackedDocument>,
        signature: String,
        documentSignatures: [CapabilityTrackedDocumentSignature] = [],
        observedAt: Date,
        signatureAlgorithm: String = CapabilityHistoryObservation.signatureAlgorithm
    ) {
        self.id = resourceID
        self.resourceID = resourceID
        self.sourceRootID = sourceRootID
        self.name = Self.safeName(name)
        self.kind = kind
        self.scope = scope
        self.projectID = projectID
        self.documents = documents
        self.signature = signature
        self.documentSignatures = documentSignatures.sorted { $0.document.rawValue < $1.document.rawValue }
        self.observedAt = observedAt
        self.signatureAlgorithm = signatureAlgorithm
    }

    /// Builds the independent history signature from already validated bytes.
    /// Length prefixes and document tags prevent ambiguous concatenation.
    /// Incomplete caller input fails closed instead of terminating the app.
    public init?(
        resourceID: String,
        sourceRootID: String,
        name: String,
        kind: ResourceKind,
        scope: ResourceScope,
        projectID: String?,
        documents: Set<CapabilityTrackedDocument>,
        documentData: [CapabilityTrackedDocument: Data],
        observedAt: Date,
        signatureAlgorithm: String = CapabilityHistoryObservation.signatureAlgorithm
    ) {
        guard let signature = Self.signature(for: documents, data: documentData) else { return nil }
        let documentSignatures = Self.documentSignatures(for: documentData)
        self.init(
            resourceID: resourceID,
            sourceRootID: sourceRootID,
            name: name,
            kind: kind,
            scope: scope,
            projectID: projectID,
            documents: documents,
            signature: signature,
            documentSignatures: documentSignatures,
            observedAt: observedAt,
            signatureAlgorithm: signatureAlgorithm
        )
    }

    public var trackingSignature: String { signature }

    public var signaturesByDocument: [CapabilityTrackedDocument: String] {
        var result: [CapabilityTrackedDocument: String] = [:]
        for signature in documentSignatures {
            guard result[signature.document] == nil else { return [:] }
            result[signature.document] = signature.sha256
        }
        return result
    }

    public static func documentSignatures(
        for data: [CapabilityTrackedDocument: Data]
    ) -> [CapabilityTrackedDocumentSignature] {
        data.map { document, bytes in
            CapabilityTrackedDocumentSignature(
                document: document,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
        }.sorted { $0.document.rawValue < $1.document.rawValue }
    }

    public static func signature(
        for documents: Set<CapabilityTrackedDocument>,
        data: [CapabilityTrackedDocument: Data]
    ) -> String? {
        guard !documents.isEmpty, documents == Set(data.keys) else { return nil }
        var canonical = Data()
        for document in documents.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let bytes = data[document] else { return nil }
            let tag = Data(document.rawValue.utf8)
            appendLengthPrefixed(tag, to: &canonical)
            appendLengthPrefixed(bytes, to: &canonical)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixed(_ bytes: Data, to result: inout Data) {
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(bytes)
    }

    private static func safeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 256,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("://"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !PersistenceAllowlist.containsForbiddenValue(trimmed) else {
            return "Unnamed capability"
        }
        return trimmed
    }
}

/// Completeness and identity for one approved directory scope. Root paths are
/// deliberately absent so this value can be handed to history persistence.
public struct CapabilityHistoryScanScope: Sendable, Equatable, Identifiable {
    public let id: String
    public let rootID: String
    public let scope: ResourceScope
    public let rootKind: ScanRootKind
    public let coverage: CapabilityHistoryCoverage

    public init(
        rootID: String,
        scope: ResourceScope,
        rootKind: ScanRootKind,
        coverage: CapabilityHistoryCoverage
    ) {
        self.id = rootID
        self.rootID = rootID
        self.scope = scope
        self.rootKind = rootKind
        self.coverage = coverage
    }
}

public enum CapabilityHistoryObservationSource: String, Codable, Sendable, Equatable {
    case filesystem
    case cacheFallback
}

/// Task 1's hand-off from discovery to the future history detector. This is
/// an in-memory value only; it does not write events or baselines.
public struct CapabilityHistoryScanBatch: Sendable, Equatable {
    public let observedAt: Date
    public let scopes: [CapabilityHistoryScanScope]
    public let observations: [CapabilityHistoryObservation]
    public let source: CapabilityHistoryObservationSource

    public init(
        observedAt: Date,
        scopes: [CapabilityHistoryScanScope],
        observations: [CapabilityHistoryObservation],
        source: CapabilityHistoryObservationSource = .filesystem
    ) {
        self.observedAt = observedAt
        self.scopes = scopes
        self.observations = source == .filesystem ? observations : []
        self.source = source
    }

    public var isCacheFallback: Bool { source == .cacheFallback }

    public var coverage: CapabilityHistoryCoverage {
        CapabilityHistoryCoverage.aggregate(scopes.map(\.coverage))
    }
}
