import Foundation

/// A local user judgment about one indexed capability invocation.
///
/// This is deliberately separate from the operational status of an
/// `InvocationEvent`: a completed call is not evidence that the capability was
/// effective for the user's goal. The value contains only stable identifiers,
/// the explicit label, and when the label was last changed.
public enum InvocationEvaluationLabel: String, Codable, Sendable, CaseIterable {
    case effective
    case ineffective
    case uncertain
}

public struct InvocationEvaluation: Codable, Sendable, Equatable, Identifiable {
    public let invocationID: String
    public let sessionID: String
    public let resourceID: String?
    public let label: InvocationEvaluationLabel
    public let updatedAt: Date

    public var id: String { invocationID }

    public init(
        invocationID: String,
        sessionID: String,
        resourceID: String?,
        label: InvocationEvaluationLabel,
        updatedAt: Date
    ) {
        self.invocationID = invocationID
        self.sessionID = sessionID
        self.resourceID = resourceID
        self.label = label
        self.updatedAt = updatedAt
    }

    /// Naming-compatible convenience for callers that want to make the
    /// canonical nature of the resource identifier explicit.
    public init(
        invocationID: String,
        sessionID: String,
        canonicalResourceID: String?,
        label: InvocationEvaluationLabel,
        updatedAt: Date
    ) {
        self.init(
            invocationID: invocationID,
            sessionID: sessionID,
            resourceID: canonicalResourceID,
            label: label,
            updatedAt: updatedAt
        )
    }

    public var canonicalResourceID: String? { resourceID }
}

/// Privacy-safe storage read result. `unavailable` carries no underlying
/// error text, path, defaults domain, or payload.
public enum InvocationEvaluationReadResult: Sendable, Equatable {
    case missing
    case data(Data)
    case unavailable
}

public enum InvocationEvaluationSnapshotAvailability: String, Sendable, Equatable {
    case available
    case invalid
    case unavailable
}

/// Bounded metadata snapshot for aggregate evaluation joins. Existing detail
/// consumers keep using `all()`; summary callers use this explicit coverage so
/// corrupt or unreadable storage cannot be mistaken for an empty rating set.
public struct InvocationEvaluationSnapshot: Sendable, Equatable {
    public let availability: InvocationEvaluationSnapshotAvailability
    public let evaluations: [String: InvocationEvaluation]
    public let mutationRevision: UInt64

    public init(
        availability: InvocationEvaluationSnapshotAvailability,
        evaluations: [String: InvocationEvaluation],
        mutationRevision: UInt64 = 0
    ) {
        self.availability = availability
        self.evaluations = evaluations
        self.mutationRevision = mutationRevision
    }
}

/// Durable local storage for explicit invocation evaluations.
///
/// UserDefaults is intentionally used instead of the rebuildable SQLite
/// projection so reindexing or deleting derived data cannot erase judgments.
/// The single versioned key stores a JSON dictionary keyed by invocation ID.
public final class InvocationEvaluationStore: @unchecked Sendable {
    public static let defaultsKey = "codexDirector.invocationEvaluations.v1"
    public static let didMutateNotification = Notification.Name("CodexDirector.InvocationEvaluationStore.didMutate")
    private static let maximumStableIDLength = 256
    private static let maximumSnapshotBytes = 16 * 1_024 * 1_024
    private static let maximumSnapshotEvaluations = 100_000

    private let readData: () -> Data?
    private let readResult: () -> InvocationEvaluationReadResult
    private let writeData: (Data) -> Bool
    private let removeData: () -> Bool
    private let cacheLock = NSLock()
    private var cachedData: Data?
    private var cachedEvaluations: [String: InvocationEvaluation]?
    private var mutationRevision: UInt64 = 0

    public init(defaults: UserDefaults = .standard) {
        self.readData = { defaults.data(forKey: Self.defaultsKey) }
        self.readResult = {
            if let data = defaults.data(forKey: Self.defaultsKey) { return .data(data) }
            return .missing
        }
        self.writeData = { data in
            defaults.set(data, forKey: Self.defaultsKey)
            return defaults.data(forKey: Self.defaultsKey) == data
        }
        self.removeData = {
            defaults.removeObject(forKey: Self.defaultsKey)
            return defaults.data(forKey: Self.defaultsKey) == nil
        }
    }

    /// Injectable persistence hooks keep failure behavior testable without
    /// changing the production UserDefaults boundary.
    public init(
        defaults: UserDefaults,
        readData: (() -> Data?)? = nil,
        writeData: @escaping (Data) -> Bool,
        removeData: @escaping () -> Bool
    ) {
        let reader = readData ?? { defaults.data(forKey: Self.defaultsKey) }
        self.readData = reader
        self.readResult = {
            if let data = reader() { return .data(data) }
            return .missing
        }
        self.writeData = writeData
        self.removeData = removeData
    }

    /// A fully in-memory persistence boundary for disposable validation and
    /// tests. No `UserDefaults` instance is created or consulted.
    public init(
        readData: @escaping () -> Data?,
        writeData: @escaping (Data) -> Bool,
        removeData: @escaping () -> Bool
    ) {
        self.readData = readData
        self.readResult = {
            if let data = readData() { return .data(data) }
            return .missing
        }
        self.writeData = writeData
        self.removeData = removeData
    }

    /// Injectable read-availability seam for corruption and unavailable-store
    /// tests. `all()` retains its legacy empty-on-failure behavior, while
    /// `readSnapshot()` preserves the explicit availability state.
    public init(
        readResult: @escaping () -> InvocationEvaluationReadResult,
        writeData: @escaping (Data) -> Bool,
        removeData: @escaping () -> Bool
    ) {
        self.readResult = readResult
        self.readData = {
            if case .data(let data) = readResult() { return data }
            return nil
        }
        self.writeData = writeData
        self.removeData = removeData
    }

    public func all() -> [String: InvocationEvaluation] {
        guard let data = readData() else {
            cacheLock.lock()
            cachedData = nil
            cachedEvaluations = nil
            cacheLock.unlock()
            return [:]
        }
        cacheLock.lock()
        if cachedData == data, let cachedEvaluations {
            cacheLock.unlock()
            return cachedEvaluations
        }
        cacheLock.unlock()

        let decoded = (try? JSONDecoder().decode([String: InvocationEvaluation].self, from: data)) ?? [:]
        let validated = decoded.filter { key, value in
            key == value.invocationID && Self.isStableIdentifier(value.invocationID)
                && Self.isStableIdentifier(value.sessionID)
                && (value.resourceID == nil || Self.isStableIdentifier(value.resourceID!))
        }
        cacheLock.lock()
        cachedData = data
        cachedEvaluations = validated
        cacheLock.unlock()
        return validated
    }

    public func readSnapshot() -> InvocationEvaluationSnapshot {
        let revision = currentMutationRevision()
        let data: Data
        switch readResult() {
        case .missing:
            return InvocationEvaluationSnapshot(availability: .available, evaluations: [:], mutationRevision: revision)
        case .unavailable:
            return InvocationEvaluationSnapshot(availability: .unavailable, evaluations: [:], mutationRevision: revision)
        case .data(let value):
            data = value
        }
        guard data.count <= Self.maximumSnapshotBytes,
              let decoded = try? JSONDecoder().decode([String: InvocationEvaluation].self, from: data),
              decoded.count <= Self.maximumSnapshotEvaluations else {
            return InvocationEvaluationSnapshot(availability: .invalid, evaluations: [:], mutationRevision: revision)
        }
        let validated = decoded.filter { key, value in
            key == value.invocationID && Self.isValid(value)
        }
        guard validated.count == decoded.count else {
            return InvocationEvaluationSnapshot(availability: .invalid, evaluations: [:], mutationRevision: revision)
        }
        cacheLock.lock()
        cachedData = data
        cachedEvaluations = validated
        cacheLock.unlock()
        return InvocationEvaluationSnapshot(
            availability: .available,
            evaluations: validated,
            mutationRevision: revision
        )
    }

    public func evaluation(for invocationID: String) -> InvocationEvaluation? {
        all()[invocationID]
    }

    public func mutationRevisionSnapshot() -> UInt64 {
        currentMutationRevision()
    }

    @discardableResult
    public func set(_ evaluation: InvocationEvaluation) -> Bool {
        guard Self.isValid(evaluation) else { return false }
        var values = all()
        if values[evaluation.invocationID] == evaluation { return true }
        values[evaluation.invocationID] = evaluation
        guard let data = try? JSONEncoder().encode(values) else { return false }
        guard writeData(data) else { return false }
        guard all()[evaluation.invocationID] == evaluation else { return false }
        recordMutation()
        return true
    }

    /// Compatibility overload matching the other preference stores while
    /// still requiring the value's stable identifier to be authoritative.
    @discardableResult
    public func set(_ evaluation: InvocationEvaluation, for invocationID: String) -> Bool {
        guard evaluation.invocationID == invocationID else { return false }
        return set(evaluation)
    }

    @discardableResult
    public func remove(for invocationID: String) -> Bool {
        guard Self.isStableIdentifier(invocationID) else { return false }
        var values = all()
        guard values.removeValue(forKey: invocationID) != nil else { return true }
        if values.isEmpty {
            guard removeData() else { return false }
            recordMutation()
            return true
        }
        guard let data = try? JSONEncoder().encode(values), writeData(data) else { return false }
        guard evaluation(for: invocationID) == nil else { return false }
        recordMutation()
        return true
    }

    @discardableResult
    public func removeAll() -> Bool {
        let hadStoredPayload: Bool
        switch readResult() {
        case .missing:
            hadStoredPayload = false
        case .data, .unavailable:
            // An explicit clear must still attempt to remove corrupt or
            // temporarily unreadable bytes. A successful removal may change
            // shared state even when no valid evaluations could be decoded.
            hadStoredPayload = true
        }
        guard hadStoredPayload else { return true }
        guard removeData() else { return false }
        cacheLock.lock()
        cachedData = nil
        cachedEvaluations = nil
        cacheLock.unlock()
        recordMutation()
        return true
    }

    private func currentMutationRevision() -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return mutationRevision
    }

    private func recordMutation() {
        cacheLock.lock()
        mutationRevision &+= 1
        cacheLock.unlock()
        NotificationCenter.default.post(name: Self.didMutateNotification, object: self)
    }

    private static func isValid(_ evaluation: InvocationEvaluation) -> Bool {
        isStableIdentifier(evaluation.invocationID)
            && isStableIdentifier(evaluation.sessionID)
            && (evaluation.resourceID == nil || isStableIdentifier(evaluation.resourceID!))
    }

    /// Stable IDs are generated identifiers, not arbitrary source text. The
    /// grammar accommodates existing call_/UUID/colon/dot/hyphen/underscore
    /// IDs while rejecting paths, whitespace, and free-form content.
    private static func isStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumStableIDLength,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !PersistenceAllowlist.containsForbiddenValue(value)
        else { return false }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9:._-]*$"#, options: .regularExpression) != nil
    }
}
