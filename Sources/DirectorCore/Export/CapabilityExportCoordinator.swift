import Foundation

/// Application-scoped export owner. The actor rejects overlapping work and
/// retains at most one isolated, preflighted package until it is saved or
/// discarded.
public actor CapabilityExportCoordinator {
    public typealias ProgressHandler = @Sendable (CapabilityExportProgress) -> Void

    private let environment: CapabilityExportEnvironment
    private let pluginProvider: any CapabilityPluginInventoryProviding
    private let now: @Sendable () -> Date
    private let stagingPrefix: String
    private let migrationGate: CapabilityMigrationGate
    private var prepared: CapabilityPreparedPackage?
    private var prepareTask: Task<CapabilityPreparedPackage, Error>?
    private var writeTask: Task<URL, Error>?
    private var cancellation: CapabilityExportCancellation?
    private var migrationToken: UUID?

    public init(
        environment: CapabilityExportEnvironment,
        pluginProvider: any CapabilityPluginInventoryProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        stagingPrefix: String = "CodexDirectorExport-",
        migrationGate: CapabilityMigrationGate = CapabilityMigrationGate()
    ) {
        self.environment = environment
        self.pluginProvider = pluginProvider
        self.now = now
        self.stagingPrefix = stagingPrefix
        self.migrationGate = migrationGate
    }

    public func options() async throws -> CapabilityExportOptions {
        guard prepareTask == nil, writeTask == nil, prepared == nil else {
            throw CapabilityExportError.operationInProgress
        }
        let token: UUID
        do {
            token = try await migrationGate.acquire()
        } catch {
            throw CapabilityExportError.operationInProgress
        }
        let result = CapabilityPackageDiscovery(environment: environment).options()
        await migrationGate.release(token)
        return result
    }

    public func prepare(
        selection: CapabilityExportSelection,
        progress: ProgressHandler? = nil
    ) async throws -> CapabilityExportPreview {
        guard prepareTask == nil, writeTask == nil else { throw CapabilityExportError.operationInProgress }
        if prepared != nil {
            discardPreparedPackage()
            if let oldToken = migrationToken {
                migrationToken = nil
                await migrationGate.release(oldToken)
            }
        }
        let token: UUID
        do {
            token = try await migrationGate.acquire()
        } catch {
            throw CapabilityExportError.operationInProgress
        }
        let builder = CapabilityPackageBuilder(
            environment: environment,
            pluginProvider: pluginProvider,
            now: now,
            stagingPrefix: stagingPrefix
        )
        let cancellation = CapabilityExportCancellation()
        self.cancellation = cancellation
        self.migrationToken = token
        let task = Task.detached(priority: .userInitiated) {
            try await builder.prepare(selection: selection, progress: progress, cancellation: cancellation)
        }
        prepareTask = task
        do {
            let value = try await task.value
            prepareTask = nil
            self.cancellation = nil
            prepared = value
            return value.preview
        } catch is CancellationError {
            prepareTask = nil
            self.cancellation = nil
            migrationToken = nil
            await migrationGate.release(token)
            throw CapabilityExportError.cancelled
        } catch {
            prepareTask = nil
            self.cancellation = nil
            migrationToken = nil
            await migrationGate.release(token)
            throw error
        }
    }

    public func writePreparedPackage(
        to destinationURL: URL,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        guard prepareTask == nil, writeTask == nil else { throw CapabilityExportError.operationInProgress }
        guard let prepared else { throw CapabilityExportError.noPreparedPackage }
        guard !prepared.preview.hasBlockingIssues else { throw CapabilityExportError.blockingIssues }
        let token: UUID
        if let existing = migrationToken {
            token = existing
        } else {
            do {
                token = try await migrationGate.acquire()
            } catch {
                throw CapabilityExportError.operationInProgress
            }
            migrationToken = token
        }
        let cancellation = CapabilityExportCancellation()
        self.cancellation = cancellation
        let task = Task.detached(priority: .userInitiated) {
            try CapabilityPackageArchiveWriter().write(
                prepared: prepared,
                to: destinationURL,
                progressHandler: progress,
                cancellation: cancellation
            )
        }
        writeTask = task
        do {
            let url = try await task.value
            writeTask = nil
            self.cancellation = nil
            discardPreparedPackage()
            migrationToken = nil
            await migrationGate.release(token)
            return url
        } catch is CancellationError {
            writeTask = nil
            self.cancellation = nil
            migrationToken = nil
            await migrationGate.release(token)
            throw CapabilityExportError.cancelled
        } catch {
            writeTask = nil
            self.cancellation = nil
            migrationToken = nil
            await migrationGate.release(token)
            throw error
        }
    }

    public func cancel() {
        cancellation?.cancel()
        prepareTask?.cancel()
        writeTask?.cancel()
    }

    public func discardPrepared() async throws {
        guard prepareTask == nil, writeTask == nil else { throw CapabilityExportError.operationInProgress }
        discardPreparedPackage()
        if let token = migrationToken {
            migrationToken = nil
            await migrationGate.release(token)
        }
    }

    public nonisolated static func suggestedFileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Codex-Capabilities-\(formatter.string(from: date)).codexpack.zip"
    }

    private func discardPreparedPackage() {
        if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
        prepared = nil
    }

    deinit {
        prepareTask?.cancel()
        writeTask?.cancel()
        cancellation?.cancel()
        if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
    }
}
