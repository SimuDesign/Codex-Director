import XCTest
@testable import DirectorUI

/// Temporary runtime diagnostic. This deliberately compares the injected
/// nanoseconds sleeper with the production Duration sleeper without changing
/// production code or disabling the real timeout.
@MainActor
final class RefreshCoordinatorTimeoutDiagnosticTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var value = 0
    }

    func testNanosecondsSleeperWithDefaultFiveSecondTimeoutCancelsRepeatedly() async {
        let calls = Box()
        let coordinator = RefreshCoordinator(
            timeout: 5,
            sleeper: { seconds in
                let nanoseconds = UInt64(max(0, min(seconds, 9_223_372_036)) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            operation: { _ in
                calls.value += 1
                return .completed
            }
        )

        for _ in 0..<100 {
            let result = await coordinator.request(.init(reason: .manual, force: true))
            XCTAssertEqual(result, .completed)
        }

        XCTAssertEqual(calls.value, 100)
        XCTAssertEqual(coordinator.retryAttempt, 0)
    }

    func testExplicitDurationSleeperWithDefaultFiveSecondTimeoutCancelsRepeatedly() async {
        let calls = Box()
        let coordinator = RefreshCoordinator(
            timeout: 5,
            sleeper: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            },
            operation: { _ in
                calls.value += 1
                return .completed
            }
        )

        for _ in 0..<100 {
            let result = await coordinator.request(.init(reason: .manual, force: true))
            XCTAssertEqual(result, .completed)
        }

        XCTAssertEqual(calls.value, 100)
        XCTAssertEqual(coordinator.retryAttempt, 0)
    }
}
