import Foundation
import SQLite3

public enum SQLiteError: Error, Sendable, Equatable, LocalizedError {
    case cannotOpenDatabase(URL)
    case statementFailed(String)
    case stepFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let url):
            return "Cannot open SQLite database at \(url.path)"
        case .statementFailed(let message):
            return "SQLite statement failed: \(message)"
        case .stepFailed(let message):
            return "SQLite step failed: \(message)"
        case .cancelled: return "SQLite query cancelled"
        }
    }
}

/// Thin, actor-confined wrapper around a SQLite3 connection.
///
/// Prepared statements and bound parameters only; source files are never
/// opened by this type.
public final class SQLiteConnection: @unchecked Sendable {
    public let url: URL
    private let readOnly: Bool
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    private var readDepth = 0

    public init?(url: URL, readOnly: Bool = false) {
        self.url = url
        self.readOnly = readOnly
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        self.handle = db
        sqlite3_busy_timeout(db, 5_000)
        if !readOnly {
            _ = exec("PRAGMA foreign_keys = ON")
            _ = exec("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public func exec(_ sql: String) -> Bool {
        guard let handle else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if errorMessage != nil { sqlite3_free(errorMessage) }
        return result == SQLITE_OK
    }

    public func lastErrorMessage() -> String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "unknown" }
        return String(cString: message)
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError.statementFailed("no connection") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.statementFailed(lastErrorMessage())
        }
        return SQLiteStatement(statement: statement)
    }

    public func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    public func userVersion() -> Int {
        var version = 0
        if let statement = try? prepare("PRAGMA user_version"),
           (try? statement.step()) == .row {
            version = statement.columnInt(0)
        }
        return version
    }

    public func setUserVersion(_ version: Int) {
        _ = exec("PRAGMA user_version = \(version)")
    }

    public func setUserVersionOrThrow(_ version: Int) throws {
        guard exec("PRAGMA user_version = \(version)") else { throw SQLiteError.statementFailed(lastErrorMessage()) }
    }

    // MARK: Transactions (nesting-safe)

    public func beginTransaction() {
        if transactionDepth == 0 {
            _ = exec("BEGIN IMMEDIATE TRANSACTION")
        }
        transactionDepth += 1
    }

    public func beginTransactionOrThrow() throws {
        if transactionDepth == 0 {
            guard exec("BEGIN IMMEDIATE TRANSACTION") else { throw SQLiteError.statementFailed(lastErrorMessage()) }
        }
        transactionDepth += 1
    }

    public func commitOrThrow() throws {
        guard transactionDepth > 0 else { throw SQLiteError.statementFailed("commit without transaction") }
        transactionDepth -= 1
        if transactionDepth == 0, !exec("COMMIT") { throw SQLiteError.statementFailed(lastErrorMessage()) }
    }

    public func commit() {
        transactionDepth = max(0, transactionDepth - 1)
        if transactionDepth == 0 {
            _ = exec("COMMIT")
        }
    }

    public func rollback() {
        transactionDepth = 0
        _ = exec("ROLLBACK")
    }

    public func perform<T>(cancellation: SQLiteCancellationToken?, _ body: () throws -> T) throws -> T {
        let token = cancellation ?? SQLiteCancellationToken()
        if token.shouldInterrupt { throw SQLiteError.cancelled }
        let outermost = readDepth == 0
        if outermost { sqlite3_busy_timeout(handle, 100) }
        let installsHandler = readDepth == 0
        readDepth += 1
        if installsHandler {
            sqlite3_progress_handler(handle, 1_000, { context in
                guard let context else { return 0 }
                return Unmanaged<SQLiteCancellationToken>.fromOpaque(context).takeUnretainedValue().shouldInterrupt ? 1 : 0
            }, Unmanaged.passUnretained(token).toOpaque())
        }
        defer {
            if outermost { sqlite3_busy_timeout(handle, 5_000) }
            readDepth = max(0, readDepth - 1)
            if installsHandler { sqlite3_progress_handler(handle, 0, nil, nil) }
        }
        return try withExtendedLifetime(token) { try body() }
    }

    /// Executes a short coherent snapshot on a read-only connection. The
    /// deferred transaction prevents separate aggregate queries from mixing
    /// generations while never taking the writer lock.
    public func performReadSnapshot<T>(cancellation: SQLiteCancellationToken? = nil, _ body: () throws -> T) throws -> T {
        guard readOnly else { return try perform(cancellation: cancellation, body) }
        if readDepth > 0 { return try body() }
        guard exec("BEGIN DEFERRED TRANSACTION") else { throw SQLiteError.statementFailed(lastErrorMessage()) }
        do {
            let value = try perform(cancellation: cancellation, body)
            guard exec("COMMIT") else { throw SQLiteError.statementFailed(lastErrorMessage()) }
            return value
        } catch {
            _ = exec("ROLLBACK")
            throw error
        }
    }
}

public final class SQLiteCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: ContinuousClock.Instant?
    public init(timeout: Duration = .seconds(5)) { deadline = ContinuousClock.now + timeout }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var shouldInterrupt: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || Task.isCancelled || (deadline.map { ContinuousClock.now >= $0 } ?? false) }
}

/// A prepared statement with bound-parameter helpers.
public final class SQLiteStatement: @unchecked Sendable {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    public enum StepResult {
        case row
        case done
    }

    // MARK: Binding

    public func bind(_ value: String?, at index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    public func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    public func bind(_ value: Int?, at index: Int32) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    public func bind(_ value: Int64, at index: Int32) {
        sqlite3_bind_int64(statement, index, value)
    }

    public func bind(_ value: Double, at index: Int32) {
        sqlite3_bind_double(statement, index, value)
    }

    public func bind(_ value: Double?, at index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: Stepping

    public func step() throws -> StepResult {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        case SQLITE_INTERRUPT:
            throw SQLiteError.cancelled
        default:
            throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))
        }
    }

    /// Resets the statement and clears bindings for reuse.
    public func reset() throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: Columns

    public func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    public func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public func columnText(_ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    public func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
