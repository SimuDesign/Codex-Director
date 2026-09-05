import Foundation

/// A user correction for an ambiguous local Skill. Overrides are persisted in
/// application preferences, not in the rebuildable SQLite projection and do
/// not mutate the discovered source files.
public struct ResourceClassificationOverride: Codable, Sendable, Equatable {
    public let ownership: ResourceOwnership
    public let origin: ResourceOrigin?
    public let note: String?

    public init(ownership: ResourceOwnership, origin: ResourceOrigin? = nil, note: String? = nil) {
        self.ownership = ownership
        self.origin = origin
        self.note = note
    }
}

public final class ResourceClassificationOverrideStore: @unchecked Sendable {
    public static let defaultsKey = "codexDirector.resourceClassificationOverrides"
    private let readData: () -> Data?
    private let writeData: (Data) -> Void
    private let removeData: () -> Void

    public init(defaults: UserDefaults = .standard) {
        self.readData = { defaults.data(forKey: Self.defaultsKey) }
        self.writeData = { data in defaults.set(data, forKey: Self.defaultsKey) }
        self.removeData = { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    /// Injectable storage for isolated validation and tests. The closure
    /// boundary keeps production preferences out of synthetic sessions while
    /// retaining the same Codable representation and validation behavior.
    public init(
        readData: @escaping () -> Data?,
        writeData: @escaping (Data) -> Void,
        removeData: @escaping () -> Void
    ) {
        self.readData = readData
        self.writeData = writeData
        self.removeData = removeData
    }

    public func all() -> [String: ResourceClassificationOverride] {
        guard let data = readData(),
              let decoded = try? JSONDecoder().decode([String: ResourceClassificationOverride].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public func set(_ value: ResourceClassificationOverride, for resourceID: String) {
        var values = all()
        values[resourceID] = value
        if let data = try? JSONEncoder().encode(values) {
            writeData(data)
        }
    }

    public func remove(for resourceID: String) {
        var values = all()
        values.removeValue(forKey: resourceID)
        if values.isEmpty {
            removeData()
        } else if let data = try? JSONEncoder().encode(values) {
            writeData(data)
        }
    }

    public func removeAll() {
        removeData()
    }
}
