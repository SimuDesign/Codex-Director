import Foundation

/// Result of one read-only runtime command invocation.
public struct RuntimeCommandResult: Sendable, Equatable {
    public let stdout: String
    public let exitCode: Int32
    /// True only when the watchdog actually terminated the process because
    /// it exceeded the execution deadline.
    public let timedOut: Bool
    /// Only the presence of stderr is exposed. The diagnostic bytes are never
    /// returned, logged, or persisted; plugin list can exit 0 with a partial
    /// JSON inventory while reporting a marketplace failure on stderr.
    public let hadStderrOutput: Bool

    public init(stdout: String, exitCode: Int32, timedOut: Bool, hadStderrOutput: Bool = false) {
        self.stdout = stdout
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.hadStderrOutput = hadStderrOutput
    }
}

/// Injected command client so tests never execute the real CLI.
public protocol RuntimeCommandClient: Sendable {
    func run(arguments: [String]) async throws -> RuntimeCommandResult
}

/// Production implementation: executes the Codex executable directly with an
/// argument array (never a shell), reads stdout incrementally while the
/// process runs (so a full pipe can never block the process), caps captured
/// output size and execution duration, drains and discards stderr without
/// persisting its contents,
/// and independently records whether the watchdog fired.
public struct ProcessRuntimeCommandClient: RuntimeCommandClient, @unchecked Sendable {
    public let executableURL: URL
    public let timeoutSeconds: TimeInterval
    public let maxOutputBytes: Int

    public init(
        executableURL: URL,
        timeoutSeconds: TimeInterval = 10,
        maxOutputBytes: Int = 1_048_576
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }

    public func run(arguments: [String]) async throws -> RuntimeCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let handle = ProcessHandle(process)
            let watchdogFired = LockedFlag()
            let stderrObserved = LockedFlag()
            let state = OutputState(maxBytes: maxOutputBytes)
            let group = DispatchGroup()
            let ioQueue = DispatchQueue(label: "codex-director.runtime-io", qos: .userInitiated)
            let errQueue = DispatchQueue(label: "codex-director.runtime-stderr", qos: .userInitiated)
            let waitQueue = DispatchQueue(label: "codex-director.runtime-wait", qos: .userInitiated)

            // Watchdog on its own queue so it fires even while the read loop
            // is blocked waiting for data.
            let watchdog = DispatchWorkItem {
                watchdogFired.set()
                if handle.process.isRunning {
                    handle.process.terminate()
                }
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

            // Streaming read while the process runs: draining the pipe keeps a
            // large producer from blocking on a full pipe buffer.
            group.enter()
            ioQueue.async {
                let readHandle = outPipe.fileHandleForReading
                while let chunk = try? readHandle.read(upToCount: 16_384), !chunk.isEmpty {
                    state.append(chunk)
                    if state.isCapped {
                        if handle.process.isRunning {
                            handle.process.terminate()
                        }
                        break
                    }
                }
                group.leave()
            }

            group.enter()
            errQueue.async {
                let readHandle = errPipe.fileHandleForReading
                while let chunk = try? readHandle.read(upToCount: 16_384), !chunk.isEmpty {
                    stderrObserved.set()
                }
                group.leave()
            }

            group.enter()
            waitQueue.async {
                process.waitUntilExit()
                group.leave()
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume(returning: RuntimeCommandResult(
                    stdout: state.text,
                    exitCode: handle.process.terminationStatus,
                    timedOut: watchdogFired.get(),
                    hadStderrOutput: stderrObserved.get()
                ))
            }
        }
    }
}

/// Sendable box so a Process can be referenced from @Sendable closures.
private final class ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) {
        self.process = process
    }
}

/// Thread-safe captured-output accumulator with a hard size cap.
private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maxBytes: Int
    private var capped = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maxBytes {
            buffer = buffer.prefix(maxBytes)
            capped = true
        }
    }

    var isCapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capped
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Thread-safe boolean flag.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
