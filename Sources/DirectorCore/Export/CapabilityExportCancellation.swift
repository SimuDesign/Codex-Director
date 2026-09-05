import Foundation

/// Cross-executor cancellation bridge. ZIPFoundation observes `Progress`
/// cancellation, while file collection observes this locked flag between
/// items. This keeps the app-level actor responsive during detached work.
final class CapabilityExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var progresses: [Progress] = []

    func register(_ progress: Progress) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            progress.cancel()
            return
        }
        progresses.append(progress)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let current = progresses
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    func check() throws {
        try Task.checkCancellation()
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}
