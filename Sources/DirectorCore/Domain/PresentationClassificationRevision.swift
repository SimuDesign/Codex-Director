import Foundation

public enum PresentationClassificationRevision {
    public static func make(_ overrides: [String: ResourceClassificationOverride]) -> String {
        let material = overrides.keys.sorted().map { id in
            let value = overrides[id]!
            let origin = value.origin?.rawValue ?? ""
            return [id, value.ownership.rawValue, origin].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        }.joined(separator: ";")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in material.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return "classification-v1:\(String(format: "%016llx", hash))"
    }
}
