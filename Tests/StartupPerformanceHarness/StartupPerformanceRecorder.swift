import Foundation
import Darwin

/// Passive, harness-only timing recorder. Every process gets a UUID-named
/// file and writes are sequence ordered by an actor; only aggregate stages,
/// counters, and monotonic elapsed time are persisted.
final class StartupPerformanceRecorder: @unchecked Sendable {
    private struct Marker: Codable, Sendable { let stage: String; let elapsedMilliseconds: Double }
    private struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let processID: String
        let markers: [Marker]
        let counters: [String: Int]
        let flushSequence: UInt64
        let processBirthToAppInitMilliseconds: Double?
        let processBirthBridgeUncertaintyMilliseconds: Double?
    }
    private actor FlushCoordinator {
        private let outputURL: URL?
        private var lastWrittenSequence: UInt64 = 0
        init(outputURL: URL?) { self.outputURL = outputURL }
        func write(_ snapshot: Snapshot) -> Bool {
            guard snapshot.flushSequence >= lastWrittenSequence,
                  let outputURL,
                  Self.validMetricsOutput(outputURL) else { return false }
            let temporaryURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                let data = try JSONEncoder().encode(snapshot)
                // The fixture creator owns directory creation. A recorder must
                // fail closed if that validated UUID directory is replaced.
                try data.write(to: temporaryURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
                guard Self.validOwnedMetricsFile(temporaryURL, maxBytes: 4 * 1024 * 1024) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    let replacementResult = temporaryURL.path.withCString { source in
                        outputURL.path.withCString { destination in
                            Darwin.rename(source, destination)
                        }
                    }
                    guard replacementResult == 0 else { throw CocoaError(.fileWriteNoPermission) }
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
                lastWrittenSequence = snapshot.flushSequence
                return true
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                return false
            }
        }

        private static func validMetricsOutput(_ outputURL: URL) -> Bool {
            let output = outputURL.standardizedFileURL
            let metrics = output.deletingLastPathComponent()
            let fixtureRoot = metrics.deletingLastPathComponent()
            let root = fixtureRoot.deletingLastPathComponent()
            let prefix = StartupPerformanceManifest.rootPrefix
            let canonicalPrefix = StartupPerformanceManifest.canonicalRootPrefix
            let fixtureID = fixtureRoot.lastPathComponent
            let outputName = output.lastPathComponent
            guard (root.path == prefix || root.path == canonicalPrefix),
                  root.resolvingSymlinksInPath().path == canonicalPrefix,
                  let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey]),
                  rootValues.isDirectory == true,
                  let rootAttributes = try? FileManager.default.attributesOfItem(atPath: root.path),
                  let rootOwner = rootAttributes[.ownerAccountID] as? NSNumber,
                  rootOwner.uint32Value == getuid(),
                  let rootPermissions = rootAttributes[.posixPermissions] as? NSNumber,
                  rootPermissions.intValue & 0o077 == 0,
                  fixtureID.count == 36,
                  UUID(uuidString: fixtureID) != nil,
                  fixtureRoot.resolvingSymlinksInPath().path == "\(canonicalPrefix)/\(fixtureID)",
                  let fixtureValues = try? fixtureRoot.resourceValues(forKeys: [.isDirectoryKey]),
                  fixtureValues.isDirectory == true,
                  let fixtureAttributes = try? FileManager.default.attributesOfItem(atPath: fixtureRoot.path),
                  let fixtureOwner = fixtureAttributes[.ownerAccountID] as? NSNumber,
                  fixtureOwner.uint32Value == getuid(),
                  let fixturePermissions = fixtureAttributes[.posixPermissions] as? NSNumber,
                  fixturePermissions.intValue & 0o777 == 0o700,
                  metrics.lastPathComponent == "metrics",
                  metrics.resolvingSymlinksInPath().path == "\(canonicalPrefix)/\(fixtureID)/metrics",
                  outputName.hasPrefix("startup-metrics-"),
                  output.pathExtension == "json",
                  UUID(uuidString: String(outputName.dropFirst("startup-metrics-".count).dropLast(".json".count))) != nil,
                  let values = try? metrics.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let metricsAttributes = try? FileManager.default.attributesOfItem(atPath: metrics.path),
                  let metricsOwner = metricsAttributes[.ownerAccountID] as? NSNumber,
                  metricsOwner.uint32Value == getuid(),
                  let metricsPermissions = metricsAttributes[.posixPermissions] as? NSNumber,
                  metricsPermissions.intValue & 0o777 == 0o700 else { return false }
            if FileManager.default.fileExists(atPath: output.path) {
                guard validOwnedMetricsFile(output, maxBytes: 4 * 1024 * 1024) else { return false }
            }
            return true
        }

        private static func validOwnedMetricsFile(_ file: URL, maxBytes: Int) -> Bool {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
                  let links = attributes[.referenceCount] as? NSNumber, links.intValue == 1,
                  let size = attributes[.size] as? NSNumber, size.intValue <= maxBytes else { return false }
            return true
        }
    }

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private let processID = UUID().uuidString
    private let flushCoordinator: FlushCoordinator
    private var flushSequence: UInt64 = 0
    private var processBirthToAppInitMilliseconds: Double?
    private var markers: [Marker] = []
    private var counters: [String: Int] = [:]

    init(outputDirectory: URL?) {
        startedAt = clock.now
        flushCoordinator = FlushCoordinator(outputURL: outputDirectory?.appendingPathComponent("startup-metrics-\(processID).json"))
        captureProcessBirth()
    }

    func mark(_ stage: String) {
        guard Self.isSafeAggregateKey(stage) else { return }
        lock.lock()
        markers.append(Marker(stage: stage, elapsedMilliseconds: Self.milliseconds(startedAt.duration(to: clock.now))))
        lock.unlock()
    }

    func increment(_ counter: String, by amount: Int = 1) {
        guard Self.isSafeAggregateKey(counter), amount >= 0 else { return }
        lock.lock(); counters[counter, default: 0] += amount; lock.unlock()
    }

    func markElapsed(_ stage: String, since instant: ContinuousClock.Instant) {
        guard Self.isSafeAggregateKey(stage) else { return }
        lock.lock()
        markers.append(Marker(stage: stage, elapsedMilliseconds: Self.milliseconds(instant.duration(to: clock.now))))
        lock.unlock()
    }

    func flushAsync() {
        let snapshot = snapshot()
        Task { _ = await flushCoordinator.write(snapshot) }
    }

    /// Terminal flush. The caller can report a failed acknowledgement without
    /// exposing the underlying path or source data.
    func flush() async -> Bool { await flushCoordinator.write(snapshot()) }

    private func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        flushSequence &+= 1
        return Snapshot(schemaVersion: 1, processID: processID, markers: markers, counters: counters, flushSequence: flushSequence, processBirthToAppInitMilliseconds: processBirthToAppInitMilliseconds, processBirthBridgeUncertaintyMilliseconds: processBirthBridgeUncertaintyMilliseconds)
    }

    private var processBirthBridgeUncertaintyMilliseconds: Double?

    private func captureProcessBirth() {
        var info = proc_bsdinfo()
        let result = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            increment("process_birth_unsupported")
            return
        }
        let birth = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        // proc_pidinfo reports wall-clock birth. Bridge it to the recorder's
        // monotonic clock using a tight before/after bracket, and retain the
        // bracket width as uncertainty rather than claiming a pure monotonic
        // process-birth timestamp.
        let wallBefore = Date()
        let monoBefore = clock.now
        let wallAfter = Date()
        let monoAfter = clock.now
        let wallBracket = wallAfter.timeIntervalSince(wallBefore)
        let monoBracket = Self.milliseconds(monoBefore.duration(to: monoAfter)) / 1_000
        let wallAge = wallBefore.addingTimeInterval(wallBracket / 2).timeIntervalSince(birth)
        let uncertainty = max(wallBracket, monoBracket) * 1_000
        guard wallAge.isFinite, wallAge >= 0, wallAge < 24 * 60 * 60,
              uncertainty.isFinite, uncertainty >= 0 else {
            increment("process_birth_clock_uncertain")
            return
        }
        let birthInstant = monoBefore.advanced(by: .seconds(-wallAge))
        let elapsed = Self.milliseconds(birthInstant.duration(to: startedAt))
        guard elapsed.isFinite, elapsed >= 0, elapsed < 24 * 60 * 60 * 1_000 else {
            increment("process_birth_clock_uncertain")
            return
        }
        lock.lock()
        processBirthToAppInitMilliseconds = elapsed
        processBirthBridgeUncertaintyMilliseconds = uncertainty
        lock.unlock()
        increment("process_birth_wall_bridge")
        increment("process_birth_observed")
    }

    /// Converts an NSEvent uptime timestamp to the same monotonic clock used
    /// by the recorder. A wall/uptime discontinuity is rejected explicitly.
    func instant(forSystemUptime timestamp: TimeInterval) -> ContinuousClock.Instant? {
        let currentUptime = ProcessInfo.processInfo.systemUptime
        let delay = currentUptime - timestamp
        guard timestamp.isFinite, timestamp > 0, delay.isFinite, delay >= 0, delay < 24 * 60 * 60 else {
            increment("input_timestamp_uncertain")
            return nil
        }
        return clock.now.advanced(by: .seconds(-delay))
    }

    private static func isSafeAggregateKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == "_" || scalar == "-" || (scalar.isASCII && ((48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)))
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
