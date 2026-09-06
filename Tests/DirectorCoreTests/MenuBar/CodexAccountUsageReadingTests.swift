import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import DirectorCore

final class CodexAccountUsageReadingTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 2_000_000)

    func testPrefersCodexWeeklyBucketAndIgnoresModelSpecificBuckets() throws {
        let response = try json([
            "id": 2,
            "result": [
                "rateLimitsByLimitId": [
                    "codex": [
                        "primary": ["usedPercent": 25, "windowDurationMins": 10_080, "resetsAt": 2_001_000],
                        "secondary": ["usedPercent": 75, "windowDurationMins": 60, "resetsAt": 2_000_100]
                    ],
                    "gpt-5.3-codex-spark": [
                        "primary": ["usedPercent": 99, "windowDurationMins": 10_080]
                    ]
                ],
                "rateLimits": ["primary": ["usedPercent": 100, "windowDurationMins": 10_080]],
                "accountId": "must-not-be-retained",
                "rateLimitResetCredits": ["availableCount": 3, "credits": [["id": "private"]]]
            ]
        ])

        let snapshot = try CodexAccountUsageReading.parse(response: response, capturedAt: capturedAt)

        XCTAssertEqual(snapshot.weeklyRemainingPercent, 75)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 2_001_000))
        XCTAssertEqual(snapshot.resetCreditCount, 3)
        XCTAssertEqual(snapshot.capturedAt, capturedAt)
    }

    func testFallsBackToLegacyOverallRateLimitsWhenCodexBucketIsMissing() throws {
        let response = try json([
            "id": 2,
            "result": [
                "rateLimits": [
                    "primary": ["usedPercent": 40, "windowDurationMins": 10_080, "resetsAt": 2_002_000],
                    "secondary": ["usedPercent": 10, "windowDurationMins": 60]
                ]
            ]
        ])

        let snapshot = try CodexAccountUsageReading.parse(response: response, capturedAt: capturedAt)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 60)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 2_002_000))
        XCTAssertNil(snapshot.resetCreditCount)
    }

    func testFallsBackToLegacyOverallRateLimitsWhenCodexBucketHasNoWeeklyWindow() throws {
        let response = try json([
            "id": 2,
            "result": [
                "rateLimitsByLimitId": [
                    "codex": ["primary": ["usedPercent": 2, "windowDurationMins": 60]]
                ],
                "rateLimits": [
                    "secondary": ["usedPercent": 30, "windowDurationMins": 10_080, "resetsAt": 2_002_000]
                ]
            ]
        ])

        let snapshot = try CodexAccountUsageReading.parse(response: response, capturedAt: capturedAt)
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 70)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 2_002_000))
    }

    func testMissingWeeklyWindowAndExplicitZeroAreDistinguishedFromUnknown() throws {
        let response = try json([
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 5, "windowDurationMins": 60]],
                "rateLimitResetCredits": ["availableCount": 0]
            ]
        ])
        let snapshot = try CodexAccountUsageReading.parse(response: response, capturedAt: capturedAt)
        XCTAssertNil(snapshot.weeklyRemainingPercent)
        XCTAssertNil(snapshot.weeklyResetsAt)
        XCTAssertEqual(snapshot.resetCreditCount, 0)
    }

    func testBooleanNumericFieldsAreNotAcceptedAsCountsOrPercentages() throws {
        let invalidPercent = try json([
            "id": 2,
            "result": ["rateLimits": ["primary": ["usedPercent": true, "windowDurationMins": 10_080]]]
        ])
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: invalidPercent, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .invalidValue)
        }

        let invalidCount = try json([
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 10, "windowDurationMins": 10_080]],
                "rateLimitResetCredits": ["availableCount": false]
            ]
        ])
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: invalidCount, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .invalidValue)
        }
    }

    func testInvalidValuesMalformedResponsesAndProtocolErrorsAreRejected() throws {
        let invalidPercent = try json([
            "id": 2,
            "result": ["rateLimits": ["primary": ["usedPercent": 101, "windowDurationMins": 10_080]]]
        ])
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: invalidPercent, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .invalidValue)
        }

        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: Data("not json".utf8), capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .malformedResponse)
        }

        let protocolError = try json(["id": 2, "error": ["code": -32601, "message": "unsupported"]])
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: protocolError, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .protocolError)
        }

        let invalidReset = try json([
            "id": 2,
            "result": [
                "rateLimits": ["primary": ["usedPercent": 10, "windowDurationMins": 10_080, "resetsAt": "not-a-date"]]
            ]
        ])
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: invalidReset, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .invalidValue)
        }
    }

    func testCodableDecodeRetainsValidationBoundaries() throws {
        let decoder = JSONDecoder()
        let invalid = Data("{\"weeklyRemainingPercent\":101,\"capturedAt\":\"2001-01-01T00:00:00Z\"}".utf8)
        XCTAssertThrowsError(try decoder.decode(CodexAccountUsageSnapshot.self, from: invalid))
    }

    func testOutputLimitIsBoundedBeforeParsing() {
        let oversized = Data(repeating: 0x20, count: 512 * 1024 + 1)
        XCTAssertThrowsError(try CodexAccountUsageReading.parse(response: oversized, capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? CodexAccountUsageReadError, .outputTooLarge)
        }
    }

    func testReadUsesInjectedTransportAndFixedHandshakeWithoutSensitiveFields() async throws {
        let expectedCapturedAt = capturedAt
        let response = try json([
            "id": 2,
            "result": ["rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 10_080]]]
        ])
        let requestBox = RequestBox()
        let reading = CodexAccountUsageReading(
            transport: { _, request, _, _ in
                await requestBox.set(request)
                return response
            },
            executableURL: URL(fileURLWithPath: "/usr/bin/codex"),
            now: { expectedCapturedAt }
        )

        let snapshot = try await reading.read()
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 88)
        let request = await requestBox.get()
        let lines = request.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0]["method"] as? String, "initialize")
        XCTAssertEqual(lines[1]["method"] as? String, "initialized")
        XCTAssertEqual(lines[2]["method"] as? String, "account/rateLimits/read")
        let text = String(decoding: request, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("accountid"))
        XCTAssertFalse(text.contains("gpt-5.3"))
        XCTAssertFalse(text.contains("token"))
    }

    func testUnavailableExecutableFailsWithoutAttemptingTransport() async {
        let reading = CodexAccountUsageReading(
            transport: { _, _, _, _ in XCTFail("transport must not run"); throw CodexAccountUsageReadError.unavailable },
            executableURL: nil
        )
        do {
            _ = try await reading.read()
            XCTFail("expected unavailable")
        } catch let error as CodexAccountUsageReadError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReadMapsTimeoutAndCancellationWithoutLeakingTransportErrors() async {
        let timeoutReader = CodexAccountUsageReading(
            transport: { _, _, _, _ in throw CodexAccountUsageReadError.timedOut },
            executableURL: URL(fileURLWithPath: "/synthetic/codex")
        )
        do {
            _ = try await timeoutReader.read()
            XCTFail("expected timeout")
        } catch let error as CodexAccountUsageReadError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let cancellationReader = CodexAccountUsageReading(
            transport: { _, _, _, _ in throw CancellationError() },
            executableURL: URL(fileURLWithPath: "/synthetic/codex")
        )
        do {
            _ = try await cancellationReader.read()
            XCTFail("expected cancellation")
        } catch let error as CodexAccountUsageReadError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testProductionExchangeCompletesSyntheticHandshakeAndReapsProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-menu-bar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"synthetic\"}}'
        sleep 0.1
        printf '%s\\n' '{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":10080,\"resetsAt\":2001000}}}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 2, now: { expectedCapturedAt })
        let snapshot = try await reading.read()
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 80)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 2_001_000))
    }

    func testFoundationChildOwnsItsPGIDWhenSetPGIDReturnsEACCES() throws {
#if canImport(Darwin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = pid_t(process.processIdentifier)
        defer {
            if process.isRunning { _ = kill(pid, SIGKILL) }
            process.waitUntilExit()
        }

        XCTAssertEqual(getpgid(pid), pid, "Foundation should have created a private group for the child")
        errno = 0
        let result = setpgid(pid, pid)
        XCTAssertEqual(result, -1)
        XCTAssertEqual(errno, EACCES, "the current macOS path must exercise the post-exec EACCES case")
        XCTAssertEqual(getpgid(pid), pid)
#else
        throw XCTSkip("Darwin process-group behavior is not available")
#endif
    }

    func testProductionExchangeParsesResponseBeforePersistentServerEOFAndReapsProcessTree() async throws {
        let (directory, executable, parentFile, childFile, grandchildFile) = try persistentResponseServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 2, now: { expectedCapturedAt })
        let snapshot = try await reading.read()
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 80)

        let parentPID = try await waitForPID(in: parentFile)
        let childPID = try await waitForPID(in: childFile)
        let grandchildPID = try await waitForPID(in: grandchildFile)
        let parentExited = await waitForProcessToExit(parentPID)
        let childExited = await waitForProcessToExit(childPID)
        let grandchildExited = await waitForProcessToExit(grandchildPID)
        XCTAssertTrue(parentExited, "normal completion must reap the server")
        XCTAssertTrue(childExited, "normal completion must terminate descendants")
        XCTAssertTrue(grandchildExited, "normal completion must terminate the ignored grandchild")
    }

    func testProductionExchangeEarlyParentExitStillTerminatesDescendantGroup() async throws {
        let (directory, executable, parentFile, childFile, grandchildFile) = try earlyExitResponseServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 2, now: { expectedCapturedAt })
        let snapshot = try await reading.read()
        XCTAssertEqual(snapshot.weeklyRemainingPercent, 80)

        let parentPID = try await waitForPID(in: parentFile)
        let childPID = try await waitForPID(in: childFile)
        let grandchildPID = try await waitForPID(in: grandchildFile)
        let parentExited = await waitForProcessToExit(parentPID)
        let childExited = await waitForProcessToExit(childPID)
        let grandchildExited = await waitForProcessToExit(grandchildPID)
        XCTAssertTrue(parentExited, "early-exited parent must be reaped")
        XCTAssertTrue(childExited, "early-exited parent must not orphan its child")
        XCTAssertTrue(grandchildExited, "early-exited parent must not orphan its grandchild")
    }

    func testProductionExchangeTimesOutAndTerminatesSilentServer() async throws {
        let (directory, executable) = try silentServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 0.15, now: { expectedCapturedAt })
        do {
            _ = try await reading.read()
            XCTFail("expected a bounded timeout")
        } catch let error as CodexAccountUsageReadError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testProductionExchangeCancellationTerminatesSilentServer() async throws {
        let (directory, executable) = try silentServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 5, now: { expectedCapturedAt })
        let task = Task<CodexAccountUsageReadError?, Never> {
            do {
                _ = try await reading.read()
                return nil
            } catch let error as CodexAccountUsageReadError {
                return error
            } catch {
                return nil
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testProductionExchangeCancellationTerminatesProcessTree() async throws {
        let (directory, executable, parentFile, childFile, grandchildFile) = try processTreeServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 5, now: { expectedCapturedAt })
        let task = Task<CodexAccountUsageReadError?, Never> {
            do {
                _ = try await reading.read()
                return nil
            } catch let error as CodexAccountUsageReadError {
                return error
            } catch {
                return nil
            }
        }

        let parentPID = try await waitForPID(in: parentFile)
        let childPID = try await waitForPID(in: childFile)
        let grandchildPID = try await waitForPID(in: grandchildFile)
        task.cancel()

        let outcome = await task.value
        let parentExited = await waitForProcessToExit(parentPID)
        let childExited = await waitForProcessToExit(childPID)
        let grandchildExited = await waitForProcessToExit(grandchildPID)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(parentExited, "cancelled server must be reaped")
        XCTAssertTrue(childExited, "cancelled server must terminate descendants")
        XCTAssertTrue(grandchildExited, "cancelled server must terminate the ignored grandchild")
    }

    func testProductionExchangeTimeoutTerminatesServerAndChildProcess() async throws {
        let (directory, executable, parentFile, childFile, grandchildFile) = try processTreeServer()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedCapturedAt = capturedAt
        let reading = CodexAccountUsageReading(executableURL: executable, timeoutSeconds: 1, now: { expectedCapturedAt })
        do {
            _ = try await reading.read()
            XCTFail("expected a bounded timeout")
        } catch let error as CodexAccountUsageReadError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let parentPID = try await waitForPID(in: parentFile)
        let childPID = try await waitForPID(in: childFile)
        let grandchildPID = try await waitForPID(in: grandchildFile)
        let parentExited = await waitForProcessToExit(parentPID)
        let childExited = await waitForProcessToExit(childPID)
        let grandchildExited = await waitForProcessToExit(grandchildPID)
        XCTAssertTrue(parentExited, "server parent must be reaped")
        XCTAssertTrue(childExited, "server child must be terminated")
        XCTAssertTrue(grandchildExited, "server grandchild must be terminated")
    }

    private func silentServer() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-menu-bar-silent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-codex")
        let script = "#!/bin/sh\nsleep 10\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func processTreeServer() throws -> (URL, URL, URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-menu-bar-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-codex")
        let parentFile = directory.appendingPathComponent("parent.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let grandchildFile = directory.appendingPathComponent("grandchild.pid")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "\(parentFile.path)"
        (
            trap '' TERM HUP
            (
                trap '' TERM HUP
                while :; do sleep 1; done
            ) &
            printf '%s\\n' "$!" > "\(grandchildFile.path)"
            while :; do sleep 1; done
        ) &
        printf '%s\\n' "$!" > "\(childFile.path)"
        wait
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        return (directory, executable, parentFile, childFile, grandchildFile)
    }

    private func persistentResponseServer() throws -> (URL, URL, URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-menu-bar-persistent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-codex")
        let parentFile = directory.appendingPathComponent("parent.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let grandchildFile = directory.appendingPathComponent("grandchild.pid")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "\(parentFile.path)"
        (
            trap '' TERM HUP
            (
                trap '' TERM HUP
                while :; do sleep 1; done
            ) &
            printf '%s\\n' "$!" > "\(grandchildFile.path)"
            while :; do sleep 1; done
        ) &
        printf '%s\\n' "$!" > "\(childFile.path)"
        printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"synthetic\"}}'
        sleep 0.1
        printf '%s\\n' '{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":10080}}}}'
        sleep 30
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        return (directory, executable, parentFile, childFile, grandchildFile)
    }

    private func earlyExitResponseServer() throws -> (URL, URL, URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-director-menu-bar-early-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("synthetic-codex")
        let parentFile = directory.appendingPathComponent("parent.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let grandchildFile = directory.appendingPathComponent("grandchild.pid")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "\(parentFile.path)"
        (
            trap '' TERM HUP
            (
                trap '' TERM HUP
                while :; do sleep 1; done
            ) &
            printf '%s\\n' "$!" > "\(grandchildFile.path)"
            while :; do sleep 1; done
        ) &
        printf '%s\\n' "$!" > "\(childFile.path)"
        # Do not publish the protocol response until both descendant PID
        # writes have completed. This keeps the early-parent-exit test focused
        # on process-group cleanup instead of depending on runner scheduling.
        attempts=0
        while [ "$attempts" -lt 200 ]; do
            if [ -s "\(grandchildFile.path)" ]; then
                break
            else
                attempts=$((attempts + 1))
                sleep 0.01
            fi
        done
        if [ ! -s "\(grandchildFile.path)" ]; then
            exit 75
        fi
        printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"synthetic\"}}'
        printf '%s\\n' '{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":10080}}}}'
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: executable.path)
        return (directory, executable, parentFile, childFile, grandchildFile)
    }

    private func waitForPID(in file: URL) async throws -> Int32 {
        for _ in 0..<100 {
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CodexAccountUsageReadingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic PID was not recorded"])
    }

    private func waitForProcessToExit(_ pid: Int32) async -> Bool {
        guard pid > 1 else { return false }
        for _ in 0..<100 {
            if !processExists(pid) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !processExists(pid)
    }

    private func processExists(_ pid: Int32) -> Bool {
#if canImport(Darwin)
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
#else
        return false
#endif
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

}

private actor RequestBox {
    private var request = Data()

    func set(_ request: Data) { self.request = request }
    func get() -> Data { request }
}
