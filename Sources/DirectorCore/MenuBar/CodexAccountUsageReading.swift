import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

/// The privacy-safe account information that may be projected into the menu
/// bar.  This type intentionally has no account, model, plan, or reset-credit
/// identity fields.
public struct CodexAccountUsageSnapshot: Codable, Equatable, Sendable {
    public let weeklyRemainingPercent: Double?
    public let weeklyResetsAt: Date?
    public let resetCreditCount: Int?
    public let capturedAt: Date

    public init(
        weeklyRemainingPercent: Double?,
        weeklyResetsAt: Date?,
        resetCreditCount: Int?,
        capturedAt: Date
    ) throws {
        if let weeklyRemainingPercent {
            guard weeklyRemainingPercent.isFinite, (0...100).contains(weeklyRemainingPercent) else {
                throw CodexAccountUsageReadError.invalidValue
            }
        }
        if let weeklyResetsAt {
            guard weeklyResetsAt.timeIntervalSinceReferenceDate.isFinite,
                  weeklyResetsAt >= .distantPast,
                  weeklyResetsAt <= .distantFuture else {
                throw CodexAccountUsageReadError.invalidValue
            }
        }
        if let resetCreditCount {
            guard resetCreditCount >= 0 else { throw CodexAccountUsageReadError.invalidValue }
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CodexAccountUsageReadError.invalidValue
        }
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.resetCreditCount = resetCreditCount
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case weeklyRemainingPercent
        case weeklyResetsAt
        case resetCreditCount
        case capturedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                weeklyRemainingPercent: values.decodeIfPresent(Double.self, forKey: .weeklyRemainingPercent),
                weeklyResetsAt: values.decodeIfPresent(Date.self, forKey: .weeklyResetsAt),
                resetCreditCount: values.decodeIfPresent(Int.self, forKey: .resetCreditCount),
                capturedAt: values.decode(Date.self, forKey: .capturedAt)
            )
        } catch let error as CodexAccountUsageReadError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .capturedAt,
                in: values,
                debugDescription: "Invalid account usage snapshot"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(weeklyRemainingPercent, forKey: .weeklyRemainingPercent)
        try values.encodeIfPresent(weeklyResetsAt, forKey: .weeklyResetsAt)
        try values.encodeIfPresent(resetCreditCount, forKey: .resetCreditCount)
        try values.encode(capturedAt, forKey: .capturedAt)
    }
}

public enum CodexAccountUsageReadError: Error, Equatable, Sendable {
    case unavailable
    case launchFailed
    case timedOut
    case cancelled
    case outputTooLarge
    case malformedResponse
    case protocolError
    case invalidValue
}

/// Reads the current ChatGPT/Codex allowance through the local Codex
/// app-server. The production implementation launches the located executable
/// directly; it never invokes a shell and never reads credential files.
public struct CodexAccountUsageReading: Sendable {
    public typealias Exchange = @Sendable (_ executableURL: URL, _ request: Data, _ timeout: TimeInterval, _ maxOutputBytes: Int) async throws -> Data

    public let executableURL: URL?
    public let timeoutSeconds: TimeInterval
    public let maxOutputBytes: Int
    private let exchange: Exchange
    private let now: @Sendable () -> Date

    public init(
        executableURL: URL?,
        timeoutSeconds: TimeInterval = 8,
        maxOutputBytes: Int = 512 * 1024,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.1, timeoutSeconds)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.exchange = Self.productionExchange
        self.now = now
    }

    /// Injectable transport used by synthetic tests. It receives only the
    /// fixed JSON-RPC request and returns the app-server response bytes.
    public init(
        transport: @escaping Exchange,
        executableURL: URL? = nil,
        timeoutSeconds: TimeInterval = 8,
        maxOutputBytes: Int = 512 * 1024,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.1, timeoutSeconds)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.exchange = transport
        self.now = now
    }

    public func read() async throws -> CodexAccountUsageSnapshot {
        guard let executableURL else { throw CodexAccountUsageReadError.unavailable }
        let request = Self.requestPayload(version: "1.0.0")
        do {
            let response = try await exchange(executableURL, request, timeoutSeconds, maxOutputBytes)
            return try Self.parse(response: response, capturedAt: now())
        } catch let error as CodexAccountUsageReadError {
            throw error
        } catch is CancellationError {
            throw CodexAccountUsageReadError.cancelled
        } catch {
            throw CodexAccountUsageReadError.unavailable
        }
    }

    /// Parses one JSON-RPC response without retaining the response or any
    /// account metadata. The `codex` bucket is preferred; legacy overall
    /// limits are used only when that bucket is absent.
    public static func parse(response: Data, capturedAt: Date) throws -> CodexAccountUsageSnapshot {
        guard response.count <= 512 * 1024 else { throw CodexAccountUsageReadError.outputTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: response),
              let root = object as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rateLimits = selectedRateLimits(from: result) else {
            if let error = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any], error["error"] != nil {
                throw CodexAccountUsageReadError.protocolError
            }
            throw CodexAccountUsageReadError.malformedResponse
        }

        let weekly = [rateLimits["primary"], rateLimits["secondary"]]
            .compactMap { $0 as? [String: Any] }
            .first { numericInt($0["windowDurationMins"] ?? $0["window_minutes"]) == 10_080 }
        let weeklyRemaining: Double?
        let resetsAt: Date?
        if let weekly {
            guard let used = numericDouble(weekly["usedPercent"] ?? weekly["used_percent"]), used.isFinite,
                  (0...100).contains(used) else { throw CodexAccountUsageReadError.invalidValue }
            weeklyRemaining = 100 - used
            if let resetValue = weekly["resetsAt"] ?? weekly["resets_at"] {
                guard let reset = numericDouble(resetValue) else {
                    throw CodexAccountUsageReadError.invalidValue
                }
                guard reset.isFinite, reset >= 0, reset <= Date.distantFuture.timeIntervalSince1970 else {
                    throw CodexAccountUsageReadError.invalidValue
                }
                let date = Date(timeIntervalSince1970: reset)
                guard date >= .distantPast, date <= .distantFuture else {
                    throw CodexAccountUsageReadError.invalidValue
                }
                resetsAt = date
            } else {
                resetsAt = nil
            }
        } else {
            weeklyRemaining = nil
            resetsAt = nil
        }

        var resetCreditCount: Int?
        if let credits = result["rateLimitResetCredits"] as? [String: Any] {
            if let value = credits["availableCount"] ?? credits["available_count"] {
                guard let count = numericInt(value), count >= 0 else { throw CodexAccountUsageReadError.invalidValue }
                resetCreditCount = count
            }
        }

        return try CodexAccountUsageSnapshot(
            weeklyRemainingPercent: weeklyRemaining,
            weeklyResetsAt: resetsAt,
            resetCreditCount: resetCreditCount,
            capturedAt: capturedAt
        )
    }

    private static func selectedRateLimits(from result: [String: Any]) -> [String: Any]? {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any],
           containsWeeklyWindow(codex) {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func containsWeeklyWindow(_ limits: [String: Any]) -> Bool {
        [limits["primary"], limits["secondary"]]
            .compactMap { $0 as? [String: Any] }
            .contains { numericInt($0["windowDurationMins"] ?? $0["window_minutes"]) == 10_080 }
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func numericInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    private static func requestPayload(version: String) -> Data {
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex_director", "title": "Codex Director", "version": version],
                "capabilities": ["experimentalApi": true]
            ]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/rateLimits/read", "params": [:]]
        ]
        let lines = messages.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        return lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
    }

    private static let productionExchange: Exchange = { executableURL, request, timeout, maxOutputBytes in
        try await CodexAppServerProcess.exchange(
            executableURL: executableURL,
            request: request,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }
}

private enum CodexAppServerProcess {
    static func exchange(executableURL: URL, request: Data, timeout: TimeInterval, maxOutputBytes: Int) async throws -> Data {
        let holder = SessionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = Session(
                    executableURL: executableURL,
                    request: request,
                    timeout: timeout,
                    maxOutputBytes: maxOutputBytes,
                    continuation: continuation
                )
                holder.set(session)
                session.start()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private final class SessionHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var session: Session?

        func set(_ session: Session) {
            lock.lock()
            self.session = session
            let cancelled = Task.isCancelled
            lock.unlock()
            if cancelled { session.cancel() }
        }

        func cancel() {
            lock.lock()
            let session = self.session
            lock.unlock()
            session?.cancel()
        }
    }

    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let input: Pipe
        private let output: Pipe
        #if canImport(Darwin)
        private let outputReadLock = NSLock()
        #endif
        private let request: Data
        private let timeout: TimeInterval
        private let maxOutputBytes: Int
        private let initialRequest: Data
        private let usageRequest: Data
        private var finished = false
        private var initializationComplete = false
#if canImport(Darwin)
        private var processGroupID: pid_t?
        /// Identity captured while the Foundation child is still owned by
        /// this request.  A process-group number is only safe to signal when
        /// it still belongs to this launch.  The start timestamp protects
        /// the PID from being reused; the parent and PGID checks protect the
        /// initial capture from accidentally adopting an unrelated process.
        private struct ProcessIdentity: Equatable {
            let pid: pid_t
            let parentPID: pid_t
            let processGroupID: pid_t
            let startSeconds: UInt64
            let startMicroseconds: UInt64
        }
        private var processIdentity: ProcessIdentity?
        private var processGroupCleanupStarted = false
        private var outputReadSource: DispatchSourceRead?
#endif
        private var buffer = Data()
        private var timeoutWork: DispatchWorkItem?
        private let continuation: CheckedContinuation<Data, Error>

        init(executableURL: URL, request: Data, timeout: TimeInterval, maxOutputBytes: Int, continuation: CheckedContinuation<Data, Error>) {
            process = Process()
            input = Pipe()
            output = Pipe()
            self.request = request
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.continuation = continuation
            let lines = request.split(separator: 0x0A, omittingEmptySubsequences: true)
            initialRequest = lines.first.map { Data($0) + Data([0x0A]) } ?? Data()
            usageRequest = lines.dropFirst().reduce(into: Data()) { result, line in
                result.append(contentsOf: line)
                result.append(0x0A)
            }
            process.executableURL = executableURL
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
#if canImport(Darwin)
            // A server can exit between a response and our follow-up write.
            // Suppress SIGPIPE for this pipe so the bounded error path can
            // classify the closed transport instead of terminating the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
        }

        func start() {
            guard !isFinished else { return }
            do {
                try process.run()
            } catch {
                finish(.failure(CodexAccountUsageReadError.launchFailed))
                return
            }
            establishProcessGroup()
            process.terminationHandler = { [weak self] _ in
                self?.processDidTerminate()
            }
            startOutputReader()
            guard !isFinished else { return }
            do {
                try input.fileHandleForWriting.write(contentsOf: initialRequest)
            } catch {
                finish(.failure(CodexAccountUsageReadError.unavailable))
                return
            }
            timeoutWork = DispatchWorkItem { [weak self] in
                guard let self, !self.isFinished else { return }
                self.finish(.failure(CodexAccountUsageReadError.timedOut))
            }
            if let timeoutWork {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            }
        }

        private func startOutputReader() {
#if canImport(Darwin)
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                finish(.failure(CodexAccountUsageReadError.unavailable))
                return
            }

            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.readAvailableOutput()
            }
            let handle = output.fileHandleForReading
            source.setCancelHandler {
                try? handle.close()
            }
            outputReadSource = source
            source.resume()
#else
            // The supported product platform uses the non-blocking Darwin
            // path above. Keep a portable fallback for package-only builds.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let handle = self.output.fileHandleForReading
                    while !self.isFinished,
                          let chunk = try handle.read(upToCount: 16_384),
                          !chunk.isEmpty {
                        self.consume(chunk)
                    }
                    if !self.isFinished {
                        self.finish(.failure(CodexAccountUsageReadError.protocolError))
                    }
                } catch {
                    self.finish(.failure(CodexAccountUsageReadError.unavailable))
                }
            }
#endif
        }

#if canImport(Darwin)
        private func readAvailableOutput() {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            let descriptor = output.fileHandleForReading.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while !isFinished {
                let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.read(descriptor, baseAddress, rawBuffer.count)
                }
                if count > 0 {
                    consume(Data(bytes.prefix(count)))
                    continue
                }
                if count == 0 {
                    if !isFinished {
                        finish(.failure(CodexAccountUsageReadError.protocolError))
                    }
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(.failure(CodexAccountUsageReadError.unavailable))
                return
            }
        }

        private func processDidTerminate() {
            guard !isFinished else { return }
            // Process termination does not imply EOF when a descendant still
            // owns the stdout pipe. Drain bytes already delivered by the
            // kernel before classifying the exchange as a protocol failure;
            // this also makes an early parent exit deterministic.
            readAvailableOutput()
            if !isFinished {
                finish(.failure(CodexAccountUsageReadError.protocolError))
            }
        }
#endif

        private var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        private func consume(_ data: Data) {
            lock.lock()
            buffer.append(data)
            let overLimit = buffer.count > maxOutputBytes
            let lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: true)
            let responses = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            var initializeSucceeded = false
            var responseData: Data?
            var protocolFailure = false
            if !initializationComplete,
               let response = responses.first(where: { ($0["id"] as? NSNumber)?.intValue == 1 }) {
                if response["error"] != nil {
                    protocolFailure = true
                } else if response["result"] != nil {
                    initializationComplete = true
                    initializeSucceeded = true
                }
            }
            if initializationComplete,
               let response = responses.first(where: { ($0["id"] as? NSNumber)?.intValue == 2 }) {
                if response["error"] != nil {
                    protocolFailure = true
                } else {
                    responseData = try? JSONSerialization.data(withJSONObject: response)
                }
            }
            lock.unlock()
            if overLimit {
                finish(.failure(CodexAccountUsageReadError.outputTooLarge))
            } else if protocolFailure {
                finish(.failure(CodexAccountUsageReadError.protocolError))
            } else if let responseData {
                finish(.success(responseData))
            } else if initializeSucceeded, responseData == nil {
                writeUsageRequestIfActive()
            }
        }

        private func writeUsageRequestIfActive() {
            guard !isFinished, process.isRunning else {
                finish(.failure(CodexAccountUsageReadError.unavailable))
                return
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: usageRequest)
            } catch {
                finish(.failure(CodexAccountUsageReadError.unavailable))
            }
        }

        func cancel() {
            finish(.failure(CodexAccountUsageReadError.cancelled))
        }

        private func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            timeoutWork?.cancel()
            stopOutputReader()
            terminateProcessTree()
            continuation.resume(with: result)
        }

        private func establishProcessGroup() {
#if canImport(Darwin)
            let processID = pid_t(process.processIdentifier)
            let parentID = getpid()
            guard processID > 1, processID != parentID else { return }

            // Foundation/posix_spawn can put the child into its own group
            // before it has exec'd.  In that case setpgid(2) correctly
            // returns EACCES even though the desired group already exists.
            // Treat only that expected error as recoverable, then verify the
            // kernel's group and launch identity before retaining the PGID.
            let setResult = setpgid(processID, processID)
            let setError = errno
            guard setResult == 0 || setError == EACCES else { return }
            guard let identity = processIdentity(for: processID),
                  identity.pid == processID,
                  identity.parentPID == parentID,
                  identity.processGroupID == processID,
                  getpgid(processID) == processID else {
                return
            }
            lock.lock()
            processIdentity = identity
            processGroupID = identity.processGroupID
            lock.unlock()
#endif
        }

        private func stopOutputReader() {
#if canImport(Darwin)
            if let source = outputReadSource {
                outputReadSource = nil
                source.cancel()
            } else {
                try? output.fileHandleForReading.close()
            }
#else
            try? output.fileHandleForReading.close()
#endif
        }

        /// Stop the app-server and any descendants before the caller is
        /// released. A continuation must not be resumed while a timed-out
        /// Process is still alive: otherwise a later read/termination callback
        /// can race the next request and leave a zombie or inherited child.
        private func terminateProcessTree() {
            guard process.processIdentifier > 1 else { return }
#if canImport(Darwin)
            lock.lock()
            guard !processGroupCleanupStarted else {
                lock.unlock()
                return
            }
            processGroupCleanupStarted = true
            let processGroupID = self.processGroupID
            let processIdentity = self.processIdentity
            self.processGroupID = nil
            self.processIdentity = nil
            lock.unlock()

            if let processGroupID,
               let processIdentity,
               shouldSignalProcessGroup(processGroupID, identity: processIdentity) {
                // Signal the group even when Process has already reported an
                // exit: descendants may still be alive in the known group.
                _ = kill(-processGroupID, SIGTERM)
            }
            if process.isRunning {
                process.terminate()
                waitForExit(timeout: 0.25)
            }
            if let processGroupID,
               let processIdentity,
               shouldSignalProcessGroup(processGroupID, identity: processIdentity) {
                // A parent can disappear before its child exits. Always send
                // the bounded hard-stop to the captured group once; clearing
                // processGroupID above prevents a later callback from ever
                // signalling a reused PGID.
                _ = kill(-processGroupID, SIGKILL)
            }
            if process.isRunning {
                _ = kill(pid_t(process.processIdentifier), SIGKILL)
            }
            // Reap the Process object itself. The bounded grace period above
            // prevents an uncooperative server from delaying this indefinitely.
            process.waitUntilExit()
            if let processGroupID,
               let processIdentity,
               shouldSignalProcessGroup(processGroupID, identity: processIdentity) {
                waitForProcessGroupToExit(processGroupID, timeout: 0.5)
            }
#else
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
#endif
        }

#if canImport(Darwin)
        private func processIdentity(for processID: pid_t) -> ProcessIdentity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) >= size else {
                return nil
            }
            return ProcessIdentity(
                pid: pid_t(info.pbi_pid),
                parentPID: pid_t(info.pbi_ppid),
                processGroupID: pid_t(info.pbi_pgid),
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
        }

        /// Returns true only while the captured group is still anchored to
        /// the exact child launch.  If the leader has exited, a non-empty
        /// process group cannot have been recycled to another PGID: Darwin
        /// keeps the group number alive while descendants remain members.
        /// If the leader PID has already been reused, the start timestamp
        /// check below rejects the signal before it can reach the new group.
        private func shouldSignalProcessGroup(_ groupID: pid_t, identity: ProcessIdentity) -> Bool {
            guard groupID > 1,
                  groupID == identity.pid,
                  groupID == identity.processGroupID,
                  groupID != getpgrp() else {
                return false
            }

            if let current = processIdentity(for: identity.pid) {
                return current == identity && current.processGroupID == groupID
            }

            // The parent can have exited and been reaped before cleanup.
            // Confirm that the captured PGID still has members before
            // signalling descendants, rather than using process.isRunning as
            // a proxy for group ownership.
            return processGroupHasMembers(groupID)
        }

        private func processGroupHasMembers(_ groupID: pid_t) -> Bool {
            var pids = [pid_t](repeating: 0, count: 128)
            let bytes = proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(groupID),
                &pids,
                Int32(pids.count * MemoryLayout<pid_t>.stride)
            )
            guard bytes > 0 else { return false }
            let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, pids.count)
            return pids[..<count].contains { $0 > 1 }
        }

        private func waitForExit(timeout: TimeInterval) {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
            while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        private func waitForProcessGroupToExit(_ groupID: pid_t, timeout: TimeInterval) {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if kill(-groupID, 0) != 0, errno != EPERM { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
#endif
    }
}
