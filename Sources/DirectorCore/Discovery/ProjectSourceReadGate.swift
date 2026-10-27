import Foundation

/// Fixed, privacy-safe reasons why a project-source result was not published.
public enum ProjectReadFailure: Error, Sendable, Equatable {
    case timedOut
    case busy
    case cancelled
}

/// Bounds synchronous project-source reads without pretending that a blocked
/// filesystem call can be cancelled. Timed-out or cancelled workers retain
/// their slot and root admission until the operation actually returns.
public final class ProjectSourceReadGate: @unchecked Sendable {
    public static let shared = ProjectSourceReadGate()

    private struct RootKey: Hashable {
        let lexicalURL: String
    }

    private let lock = NSLock()
    private let deadline: TimeInterval
    private let capacity: Int
    private let workerQueue: DispatchQueue
    private var activeRoots = Set<RootKey>()
    private var activeWorkers = 0

    public init(
        deadline: TimeInterval = 2,
        capacity: Int = 2
    ) {
        precondition(deadline > 0)
        precondition(capacity > 0)
        self.deadline = deadline
        self.capacity = capacity
        workerQueue = DispatchQueue(
            label: "com.peiweitang.CodexDirector.project-source-read",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    /// Runs one immutable, Sendable computation for an admitted project root.
    /// Admission is lexical and performs no filesystem I/O or symlink
    /// resolution. Busy callers do not queue and create no worker.
    public func perform<Value: Sendable>(
        root: ScanRoot,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        operation: @escaping @Sendable () -> Value
    ) async -> Result<Value, ProjectReadFailure> {
        guard !isCancelled(), !Task.isCancelled else {
            return .failure(.cancelled)
        }

        // The lexical location, not the configurable root identifier, owns
        // single-flight admission. Two aliases for the same location must
        // not consume both worker slots.
        let key = RootKey(
            lexicalURL: root.url.standardizedFileURL.absoluteString
        )
        guard reserve(key) else { return .failure(.busy) }
        let absoluteDeadline = DispatchTime.now() + deadline

        let waiter = ProjectReadWaiter<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)

                let weakWaiter = WeakProjectReadWaiter(waiter)
                let deadlineWork = DispatchWorkItem {
                    weakWaiter.value?.finish(.failure(
                        isCancelled() ? .cancelled : .timedOut
                    ))
                }
                waiter.attachDeadline(deadlineWork)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: absoluteDeadline,
                    execute: deadlineWork
                )

                // Once admitted, a worker always owns the reservation until
                // its operation returns, even when the consumer has left.
                workerQueue.async { [self] in
                    let value = operation()
                    release(key)
                    // A delayed timer callback must not let a value that
                    // returned after the admitted deadline become current.
                    if DispatchTime.now() >= absoluteDeadline {
                        waiter.finish(.failure(
                            isCancelled() ? .cancelled : .timedOut
                        ))
                    } else {
                        waiter.finish(.success(value))
                    }
                }
            }
        } onCancel: {
            waiter.finish(.failure(.cancelled))
        }
    }

    private func reserve(_ key: RootKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeWorkers < capacity, !activeRoots.contains(key) else {
            return false
        }
        activeWorkers += 1
        activeRoots.insert(key)
        return true
    }

    private func release(_ key: RootKey) {
        lock.lock()
        precondition(activeWorkers > 0 && activeRoots.remove(key) != nil)
        activeWorkers -= 1
        lock.unlock()
    }

    var activeWorkerCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeWorkers
    }
}

/// Bridges worker, timeout and cancellation races to one continuation. A late
/// worker value is intentionally dropped after the consumer result is fixed.
private final class ProjectReadWaiter<Value: Sendable>: @unchecked Sendable {
    typealias Output = Result<Value, ProjectReadFailure>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Never>?
    private var pending: Output?
    private var deadlineWork: DispatchWorkItem?
    private var finished = false

    func attachDeadline(_ workItem: DispatchWorkItem) {
        lock.lock()
        if finished {
            lock.unlock()
            workItem.cancel()
            return
        }
        deadlineWork = workItem
        lock.unlock()
    }

    func install(_ continuation: CheckedContinuation<Output, Never>) {
        let immediate: Output?
        lock.lock()
        if let pending {
            immediate = pending
            self.pending = nil
        } else {
            immediate = nil
            self.continuation = continuation
        }
        lock.unlock()
        if let immediate { continuation.resume(returning: immediate) }
    }

    func finish(_ output: Output) {
        let continuation: CheckedContinuation<Output, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        deadlineWork?.cancel()
        deadlineWork = nil
        if let installed = self.continuation {
            continuation = installed
            self.continuation = nil
        } else {
            continuation = nil
            pending = output
        }
        lock.unlock()
        continuation?.resume(returning: output)
    }
}

/// Lets the scheduled deadline avoid extending the lifetime of a completed
/// waiter. The worker still retains its waiter until a real blocked read ends.
private final class WeakProjectReadWaiter<Value: Sendable>: @unchecked Sendable {
    weak var value: ProjectReadWaiter<Value>?

    init(_ value: ProjectReadWaiter<Value>) {
        self.value = value
    }
}
