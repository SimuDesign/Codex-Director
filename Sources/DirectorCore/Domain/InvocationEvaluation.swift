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

/// Durable local storage for explicit invocation evaluations.
///
/// UserDefaults is intentionally used instead of the rebuildable SQLite
/// projection so reindexing or deleting derived data cannot erase judgments.
/// The single versioned key stores a JSON dictionary keyed by invocation ID.
public final class InvocationEvaluationStore: @unchecked Sendable {
    public static let defaultsKey = "codexDirector.invocationEvaluations.v1"
    private static let maximumStableIDLength = 256

    private let readData: () -> Data?
    private let writeData: (Data) -> Bool
    private let removeData: () -> Bool

    public init(defaults: UserDefaults = .standard) {
        self.readData = { defaults.data(forKey: Self.defaultsKey) }
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
        self.readData = readData ?? { defaults.data(forKey: Self.defaultsKey) }
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
        self.writeData = writeData
        self.removeData = removeData
    }

    public func all() -> [String: InvocationEvaluation] {
        guard let data = readData(),
              let decoded = try? JSONDecoder().decode([String: InvocationEvaluation].self, from: data)
        else {
            return [:]
        }
        return decoded.filter { key, value in
            key == value.invocationID && Self.isStableIdentifier(value.invocationID)
                && Self.isStableIdentifier(value.sessionID)
                && (value.resourceID == nil || Self.isStableIdentifier(value.resourceID!))
        }
    }

    public func evaluation(for invocationID: String) -> InvocationEvaluation? {
        all()[invocationID]
    }

    @discardableResult
    public func set(_ evaluation: InvocationEvaluation) -> Bool {
        guard Self.isValid(evaluation) else { return false }
        var values = all()
        values[evaluation.invocationID] = evaluation
        guard let data = try? JSONEncoder().encode(values) else { return false }
        guard writeData(data) else { return false }
        return all()[evaluation.invocationID] == evaluation
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
        values.removeValue(forKey: invocationID)
        if values.isEmpty {
            return removeData()
        }
        guard let data = try? JSONEncoder().encode(values), writeData(data) else { return false }
        return evaluation(for: invocationID) == nil
    }

    @discardableResult
    public func removeAll() -> Bool {
        return removeData()
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
