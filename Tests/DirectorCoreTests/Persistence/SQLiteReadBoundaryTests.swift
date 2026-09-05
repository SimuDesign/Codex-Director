import XCTest
@testable import DirectorCore

final class SQLiteReadBoundaryTests: XCTestCase {
    private func connection() -> SQLiteConnection {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-boundary-\(UUID().uuidString).db")
        return SQLiteConnection(url: url)!
    }

    func testNestedReadReusesOuterBoundaryAndConnection() throws {
        let db = connection()
        XCTAssertNoThrow(try db.performReadSnapshot {
            try db.performReadSnapshot { try db.exec("SELECT 1") }
            return try db.exec("SELECT 1")
        })
        XCTAssertTrue(db.exec("SELECT 1"))
    }

    func testPreCancelledQueryDoesNotPoisonConnection() throws {
        let db = connection(); let token = SQLiteCancellationToken(); token.cancel()
        XCTAssertThrowsError(try db.perform(cancellation: token) { _ = try db.prepare("SELECT 1") })
        XCTAssertTrue(try db.perform(cancellation: SQLiteCancellationToken(timeout: .seconds(1))) { try db.exec("SELECT 1") })
    }

    func testTaskCancellationIsObservedByProgressHandler() async throws {
        let db = connection()
        let task = Task.detached { () -> Bool in
            do {
                _ = try db.perform(cancellation: nil) { try db.prepare("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 100000000) SELECT sum(x) FROM c") .step() }
                return false
            } catch { return true }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(try db.exec("SELECT 1"))
    }
}
