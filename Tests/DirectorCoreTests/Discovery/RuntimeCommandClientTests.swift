import XCTest
@testable import DirectorCore

/// ProcessRuntimeCommandClient contracts: watchdog actually firing, streaming
/// reads that never block on a full pipe, and honest timedOut reporting.
final class RuntimeCommandClientTests: XCTestCase {

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
}
