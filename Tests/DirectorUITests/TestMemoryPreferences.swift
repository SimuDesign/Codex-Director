import Foundation
import DirectorCore
import DirectorUI

/// Thread-safe mutable time source for tests whose async model closure must be
/// @Sendable while still exercising a real clock transition.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ date: Date) {
        stored = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ date: Date) {
        lock.lock()
        stored = date
        lock.unlock()
    }
}

/// Disposable, in-memory preference boundaries for UI tests. These helpers
/// intentionally never construct or consult UserDefaults.
enum TestMemoryPreferences {
    private final class DataBox {
        var value: Data?
    }

    static func makeStores() -> (ResourceClassificationOverrideStore, InvocationEvaluationStore) {
        let classifications = DataBox()
        let evaluations = DataBox()
        return (
            ResourceClassificationOverrideStore(
                readData: { classifications.value },
                writeData: { classifications.value = $0 },
                removeData: { classifications.value = nil }
            ),
            InvocationEvaluationStore(
                readData: { evaluations.value },
                writeData: { evaluations.value = $0; return true },
                removeData: { evaluations.value = nil; return true }
            )
        )
    }

    @MainActor
    static func makeModel(
        previewMode: Bool = true,
        bootstrapError: String? = nil
    ) -> DirectorAppModel {
        let stores = makeStores()
        return DirectorAppModel(
            classificationOverrides: stores.0,
            evaluationStore: stores.1,
            previewMode: previewMode,
            bootstrapError: bootstrapError
        )
    }
}
