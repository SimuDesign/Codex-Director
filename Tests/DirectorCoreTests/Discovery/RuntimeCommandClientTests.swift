import XCTest
@testable import DirectorCore

/// ProcessRuntimeCommandClient contracts: watchdog actually firing, streaming
/// reads that never block on a full pipe, and honest timedOut reporting.
final class RuntimeCommandClientTests: XCTestCase {

    func testConcurrentRapidExitsPublishEveryTerminationExactlyOnce() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("true not available")
        }
        let client = ProcessRuntimeCommandClient(
            executableURL: executable,
            timeoutSeconds: 2,
            maxOutputBytes: 1_024
        )

        let results = try await withThrowingTaskGroup(
            of: RuntimeCommandResult.self,
            returning: [RuntimeCommandResult].self
        ) { group in
            for _ in 0..<24 {
                group.addTask { try await client.run(arguments: []) }
            }
            var results: [RuntimeCommandResult] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(results.allSatisfy { !$0.timedOut })
        XCTAssertTrue(results.allSatisfy { $0.stdout.isEmpty && !$0.hadStderrOutput })
    }

    func testRapidExitCanBeRepeatedWithoutMissingTermination() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("true not available")
        }
        let client = ProcessRuntimeCommandClient(
            executableURL: executable,
            timeoutSeconds: 2,
            maxOutputBytes: 1_024
        )

        for _ in 0..<32 {
            let result = try await client.run(arguments: [])
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testSlowProcessIsTerminatedByWatchdogWithTimedOutTrue() async throws {
        let client = ProcessRuntimeCommandClient(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeoutSeconds: 0.5,
            maxOutputBytes: 1024
        )
        let start = Date()
        let result = try await client.run(arguments: ["3"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut, "the watchdog actually fired")
        XCTAssertLessThan(elapsed, 2.0, "must not wait out the full sleep")
    }

    func testFastProcessIsNotReportedTimedOut() async throws {
        let client = ProcessRuntimeCommandClient(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeoutSeconds: 5,
            maxOutputBytes: 1024
        )
        let result = try await client.run(arguments: ["0"])
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLargeOutputIsStreamedWithoutPipeBlocking() async throws {
        let awkURL = URL(fileURLWithPath: "/usr/bin/awk")
        guard FileManager.default.fileExists(atPath: awkURL.path) else {
            throw XCTSkip("awk not available")
        }
        // 200,000 bytes exceeds a 64 KB pipe buffer; the streaming read keeps
        // the producer running and the run must not fake a timeout.
        let client = ProcessRuntimeCommandClient(
            executableURL: awkURL,
            timeoutSeconds: 10,
            maxOutputBytes: 1_048_576
        )
        let result = try await client.run(arguments: [
            "BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }",
        ])
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testOutputCapTerminatesProducerAndTruncates() async throws {
        let awkURL = URL(fileURLWithPath: "/usr/bin/awk")
        guard FileManager.default.fileExists(atPath: awkURL.path) else {
            throw XCTSkip("awk not available")
        }
        let client = ProcessRuntimeCommandClient(
            executableURL: awkURL,
            timeoutSeconds: 10,
            maxOutputBytes: 1024
        )
        let result = try await client.run(arguments: [
            "BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }",
        ])
        XCTAssertFalse(result.timedOut) // capped, not a timeout
        XCTAssertLessThanOrEqual(result.stdout.count, 1024)
        XCTAssertNotEqual(result.exitCode, 0) // terminated by the cap
    }

    func testStderrPresenceIsReportedWithoutReturningDiagnosticContent() async throws {
        let client = ProcessRuntimeCommandClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            timeoutSeconds: 5,
            maxOutputBytes: 1024
        )
        let result = try await client.run(arguments: [
            "BEGIN { print \"synthetic diagnostic\" > \"/dev/stderr\"; print \"{}\" }",
        ])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertTrue(result.hadStderrOutput)
        XCTAssertFalse(result.stdout.contains("synthetic diagnostic"))
    }

    func testStdoutAndStderrAreDrainedConcurrentlyUntilConfirmedExit() async throws {
        let awkURL = URL(fileURLWithPath: "/usr/bin/awk")
        guard FileManager.default.fileExists(atPath: awkURL.path) else {
            throw XCTSkip("awk not available")
        }
        let client = ProcessRuntimeCommandClient(
            executableURL: awkURL,
            timeoutSeconds: 10,
            maxOutputBytes: 1_048_576
        )

        let result = try await client.run(arguments: [
            "BEGIN { for (i = 0; i < 100000; i++) { printf \"x\"; printf \"e\" > \"/dev/stderr\" } }",
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 100_000)
        XCTAssertTrue(result.hadStderrOutput)
        XCTAssertFalse(result.stdout.contains("e"))
    }

    func testStartFailureThrowsWithoutPublishingSyntheticTermination() async {
        let client = ProcessRuntimeCommandClient(
            executableURL: URL(fileURLWithPath: "/definitely-missing/codex-director-runtime"),
            timeoutSeconds: 0.1,
            maxOutputBytes: 1_024
        )

        do {
            _ = try await client.run(arguments: [])
            XCTFail("missing executable unexpectedly started")
        } catch {
            // Launch failure is the expected terminal result; no watchdog or
            // synthetic exit status may be published afterward.
        }
    }
}
