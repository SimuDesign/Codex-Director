import Darwin
import Foundation

public actor CapabilityHistoryStore {
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024

    public enum WritePhase: String, Sendable, Equatable {
        case beforeTemporaryWrite
        case afterTemporaryWrite
        case beforeReplacement
        case afterReplacement
    }

    public struct FaultInjection: Sendable {
        public let fail: @Sendable (WritePhase) throws -> Void

        public init(fail: @escaping @Sendable (WritePhase) throws -> Void) {
            self.fail = fail
        }

        public static let none = Self { _ in }
    }

    public enum StoreError: Error, Equatable, Sendable {
        case oversized
        case corrupt
        case unsupportedVersion(Int)
        case invalidState
        case readOnly
        case stalePermit
        case confirmationRequired
        case atomicWriteFailed
        case fileBudgetExceeded
        case storageUnavailable
        case injectedFailure(WritePhase)
    }

    public struct WritePermit: Sendable, Equatable {
        fileprivate let epoch: UInt64
        fileprivate let revision: Int64
        fileprivate let generation: UInt64
    }

    public nonisolated let url: URL?
    public nonisolated let accessMode: CapabilityHistoryAccessMode
    public nonisolated let maximumBytes: Int

    private enum Backend {
        case memory
        case file
    }

    private struct DirectoryIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
        }
    }

    private final class FileContext: @unchecked Sendable {
        let directoryDescriptor: Int32
        let lockDescriptor: Int32?
        let directoryURL: URL
        let fileName: String
        let identity: DirectoryIdentity

        var hasWriteLease: Bool { lockDescriptor != nil }

        init(
            directoryDescriptor: Int32,
            lockDescriptor: Int32?,
            directoryURL: URL,
            fileName: String,
            identity: DirectoryIdentity
        ) {
            self.directoryDescriptor = directoryDescriptor
            self.lockDescriptor = lockDescriptor
            self.directoryURL = directoryURL
            self.fileName = fileName
            self.identity = identity
        }

        deinit {
            if let lockDescriptor {
                _ = flock(lockDescriptor, LOCK_UN)
                _ = close(lockDescriptor)
            }
            _ = close(directoryDescriptor)
        }
    }

    private struct PostReplacementFailure: Error {
        let phase: WritePhase
    }

    private let backend: Backend
    private let fileContext: FileContext?
    private let detector: CapabilityChangeDetector
    private let faultInjection: FaultInjection
    private let initialEpoch: UInt64
    private var cachedState: CapabilityHistoryStateV1?
    private var memoryData: Data?
    private var permitGeneration: UInt64 = 1

    private init(
        backend: Backend,
        url: URL?,
        accessMode: CapabilityHistoryAccessMode,
        maximumBytes: Int,
        retentionPolicy: CapabilityHistoryRetentionPolicy,
        initialEpoch: UInt64,
        fileContext: FileContext?,
        faultInjection: FaultInjection,
        initialData: Data?
    ) {
        self.backend = backend
        self.url = url
        self.accessMode = accessMode
        self.maximumBytes = maximumBytes
        detector = CapabilityChangeDetector(retentionPolicy: retentionPolicy)
        self.initialEpoch = max(1, initialEpoch)
        self.fileContext = fileContext
        self.faultInjection = faultInjection
        memoryData = initialData
    }

    /// Production constructor. It creates only the private history directory
    /// and lock lease; the history JSON remains lazily unread until a history
    /// API or a verified source batch is submitted.
    public static func production(
        url: URL? = nil,
        maximumBytes: Int = defaultMaximumBytes,
        retentionPolicy: CapabilityHistoryRetentionPolicy = .standard,
        lockTimeout: TimeInterval = 0.25
    ) throws -> CapabilityHistoryStore {
        guard maximumBytes > 0 else { throw StoreError.storageUnavailable }
        let approvedURL = try defaultHistoryURL().standardizedFileURL
        if let url, url.standardizedFileURL != approvedURL {
            throw StoreError.storageUnavailable
        }
        let resolvedURL = approvedURL
        let context = try openFileContext(for: resolvedURL, timeout: lockTimeout)
        return CapabilityHistoryStore(
            backend: .file,
            url: resolvedURL,
            accessMode: context.hasWriteLease ? .readWrite : .readOnly,
            maximumBytes: maximumBytes,
            retentionPolicy: retentionPolicy,
            initialEpoch: UInt64.random(in: 1...UInt64.max),
            fileContext: context,
            faultInjection: .none,
            initialData: nil
        )
    }

    /// Pure-memory constructor for synthetic tests and validation hosts.
    public static func memory(
        initialState: CapabilityHistoryStateV1? = nil,
        maximumBytes: Int = defaultMaximumBytes,
        retentionPolicy: CapabilityHistoryRetentionPolicy = .standard,
        initialEpoch: UInt64 = 1
    ) throws -> CapabilityHistoryStore {
        let data: Data?
        if let initialState {
            try validate(initialState, retentionPolicy: retentionPolicy)
            data = try encode(initialState)
            guard data!.count <= maximumBytes else { throw StoreError.oversized }
        } else {
            data = nil
        }
        return CapabilityHistoryStore(
            backend: .memory,
            url: nil,
            accessMode: .readWrite,
            maximumBytes: maximumBytes,
            retentionPolicy: retentionPolicy,
            initialEpoch: initialState?.epoch ?? initialEpoch,
            fileContext: nil,
            faultInjection: .none,
            initialData: data
        )
    }

    /// File-backed constructor reserved for deterministic failure testing.
    public static func faultInjecting(
        url: URL,
        maximumBytes: Int = defaultMaximumBytes,
        retentionPolicy: CapabilityHistoryRetentionPolicy = .standard,
        lockTimeout: TimeInterval = 0.25,
        initialEpoch: UInt64 = 1,
        faultInjection: FaultInjection
    ) throws -> CapabilityHistoryStore {
        guard maximumBytes > 0 else { throw StoreError.storageUnavailable }
        let context = try openFileContext(for: url, timeout: lockTimeout)
        return CapabilityHistoryStore(
            backend: .file,
            url: url,
            accessMode: context.hasWriteLease ? .readWrite : .readOnly,
            maximumBytes: maximumBytes,
            retentionPolicy: retentionPolicy,
            initialEpoch: initialEpoch,
            fileContext: context,
            faultInjection: faultInjection,
            initialData: nil
        )
    }

    public static func defaultHistoryURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.storageUnavailable
        }
        return support
            .appendingPathComponent("CodexDirector", isDirectory: true)
            .appendingPathComponent("CapabilityHistory", isDirectory: true)
            .appendingPathComponent("capability-history-v1.json")
    }

    public func issueWritePermit() throws -> WritePermit {
        guard accessMode == .readWrite else { throw StoreError.readOnly }
        let state = try loadState()
        return WritePermit(epoch: state.epoch, revision: state.revision, generation: permitGeneration)
    }

    public func revokeWritePermits() {
        permitGeneration &+= 1
    }

    public func commit(
        _ batch: CapabilityHistoryScanBatch,
        permit: WritePermit
    ) throws -> CapabilityHistoryCommitResult {
        guard accessMode == .readWrite else { throw StoreError.readOnly }
        try Task.checkCancellation()
        let old = try loadState()
        try validate(permit: permit, state: old)
        let detection = detector.apply(old, batch: batch)
        guard detection.didChange else {
            return CapabilityHistoryCommitResult(
                revision: old.revision,
                epoch: old.epoch,
                newEvents: [],
                issueCodes: detection.issueCodes
            )
        }

        var candidate = detection.state
        var data = try Self.encode(candidate)
        if data.count > maximumBytes {
            (candidate, data) = try fitToBudget(candidate)
        }
        try Self.validate(candidate, retentionPolicy: detector.retentionPolicy)
        try validate(permit: permit, state: old)
        try Task.checkCancellation()

        do {
            try persist(data)
            cachedState = candidate
        } catch let error as PostReplacementFailure {
            // The atomic rename already completed. Preserve the committed
            // candidate in memory so a caller-visible injected crash cannot
            // make a later write start from the old baseline.
            cachedState = candidate
            throw StoreError.injectedFailure(error.phase)
        }

        let retainedIDs = Set(candidate.events.map(\.id))
        return CapabilityHistoryCommitResult(
            revision: candidate.revision,
            epoch: candidate.epoch,
            newEvents: detection.newEvents.filter { retainedIDs.contains($0.id) },
            issueCodes: candidate.issueCodes
        )
    }

    public func page(_ query: CapabilityHistoryQuery) throws -> CapabilityHistoryPage {
        let state = try loadState(refreshReadOnly: true)
        let boundedLimit = min(max(query.limit, 1), 200)
        let filtered = state.events.reversed().filter { event in
            if let resourceID = query.resourceID, event.resourceID != resourceID { return false }
            if !query.resourceKinds.isEmpty, !query.resourceKinds.contains(event.resourceKind) { return false }
            if !query.changeKinds.isEmpty, !query.changeKinds.contains(event.kind) { return false }
            if let lower = query.observedOnOrAfter, event.observedAt < lower { return false }
            if let upper = query.observedOnOrBefore, event.observedAt > upper { return false }
            if let before = query.beforeSequence, event.sequence >= before { return false }
            return true
        }
        let materialized = Array(filtered.prefix(boundedLimit + 1))
        let hasMore = materialized.count > boundedLimit
        let events = Array(materialized.prefix(boundedLimit))
        return CapabilityHistoryPage(
            events: events,
            nextBeforeSequence: hasMore ? events.last?.sequence : nil,
            revision: state.revision,
            epoch: state.epoch,
            truncatedBefore: state.truncatedBefore,
            issueCodes: state.issueCodes
        )
    }

    public func eventBoundary(
        eventID: String,
        resourceID: String,
        observedAt: Date
    ) throws -> CapabilityHistoryEventBoundary? {
        let state = try loadState(refreshReadOnly: true)
        guard let event = state.events.first(where: {
            $0.id == eventID
                && $0.resourceID == resourceID
                && $0.observedAt == observedAt
        }) else { return nil }
        let next = state.events
            .filter { $0.resourceID == resourceID && $0.sequence > event.sequence }
            .min { $0.sequence < $1.sequence }
        return CapabilityHistoryEventBoundary(
            eventID: event.id,
            resourceID: event.resourceID,
            observedAt: event.observedAt,
            nextObservedAt: next?.observedAt,
            epoch: state.epoch,
            revision: state.revision
        )
    }

    public func status() -> CapabilityHistoryStatus {
        do {
            let state = try loadState(refreshReadOnly: true)
            var issues = state.issueCodes
            if accessMode == .readOnly { issues.append(.readOnlyLockConflict) }
            return CapabilityHistoryStatus(
                accessMode: accessMode,
                epoch: state.epoch,
                revision: state.revision,
                eventCount: state.events.count,
                baselineCount: state.baselines.count,
                isInitialized: !state.scopes.isEmpty,
                initializedScopeCount: state.scopes.count,
                latestScanCoverage: state.latestScanCoverage,
                pendingMissingCount: state.pendingMissing.count,
                issueCodes: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
            )
        } catch let error as StoreError {
            return CapabilityHistoryStatus(
                accessMode: accessMode,
                epoch: nil,
                revision: nil,
                eventCount: nil,
                baselineCount: nil,
                isInitialized: nil,
                initializedScopeCount: nil,
                latestScanCoverage: nil,
                pendingMissingCount: nil,
                issueCodes: [Self.issueCode(for: error)]
            )
        } catch {
            return CapabilityHistoryStatus(
                accessMode: accessMode,
                epoch: nil,
                revision: nil,
                eventCount: nil,
                baselineCount: nil,
                isInitialized: nil,
                initializedScopeCount: nil,
                latestScanCoverage: nil,
                pendingMissingCount: nil,
                issueCodes: [.storageUnavailable]
            )
        }
    }

    /// Explicit destructive operation used only after UI confirmation. It
    /// revokes every prior permit before atomically replacing any existing,
    /// corrupt or unsupported document with a new empty epoch.
    public func clearConfirmed(_ confirmed: Bool) throws -> CapabilityHistoryStatus {
        guard confirmed else { throw StoreError.confirmationRequired }
        guard accessMode == .readWrite else { throw StoreError.readOnly }
        permitGeneration &+= 1

        let prior = try? loadState()
        let nextEpoch: UInt64
        if let prior, prior.epoch < UInt64.max {
            nextEpoch = prior.epoch + 1
        } else if prior?.epoch == UInt64.max {
            nextEpoch = UInt64.random(in: 1..<UInt64.max)
        } else {
            nextEpoch = UInt64.random(in: 1...UInt64.max)
        }
        let empty = CapabilityHistoryStateV1(
            epoch: nextEpoch,
            // Revision is scoped by epoch. Resetting it avoids arithmetic at
            // the persistence boundary and keeps the fresh state writable.
            revision: 1
        )
        let data = try Self.encode(empty)
        do {
            try persist(data)
            cachedState = empty
        } catch let error as PostReplacementFailure {
            cachedState = empty
            throw StoreError.injectedFailure(error.phase)
        }
        return CapabilityHistoryStatus(
            accessMode: .readWrite,
            epoch: empty.epoch,
            revision: empty.revision,
            eventCount: 0,
            baselineCount: 0,
            isInitialized: false,
            initializedScopeCount: 0,
            latestScanCoverage: nil,
            pendingMissingCount: 0
        )
    }

    private func validate(permit: WritePermit, state: CapabilityHistoryStateV1) throws {
        guard permit.epoch == state.epoch,
              permit.revision == state.revision,
              permit.generation == permitGeneration else { throw StoreError.stalePermit }
    }

    private func loadState(refreshReadOnly: Bool = false) throws -> CapabilityHistoryStateV1 {
        if refreshReadOnly, accessMode == .readOnly { cachedState = nil }
        if let cachedState { return cachedState }

        let data: Data?
        switch backend {
        case .memory:
            data = memoryData
        case .file:
            guard let fileContext else { throw StoreError.storageUnavailable }
            try Self.revalidateDirectory(fileContext)
            guard let fileData = try Self.readHistoryData(fileContext, maximumBytes: maximumBytes) else {
                let empty = CapabilityHistoryStateV1.empty(epoch: initialEpoch)
                cachedState = empty
                return empty
            }
            data = fileData
        }
        guard let data else {
            let empty = CapabilityHistoryStateV1.empty(epoch: initialEpoch)
            cachedState = empty
            return empty
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw data.isEmpty ? StoreError.corrupt : StoreError.oversized
        }
        let state: CapabilityHistoryStateV1
        do { state = try Self.decode(data) }
        catch let error as StoreError { throw error }
        catch { throw StoreError.corrupt }
        try Self.validate(state, retentionPolicy: detector.retentionPolicy)
        cachedState = state
        return state
    }

    private func fitToBudget(
        _ original: CapabilityHistoryStateV1
    ) throws -> (CapabilityHistoryStateV1, Data) {
        var events = original.events
        var truncatedBefore = original.truncatedBefore
        while !events.isEmpty {
            let removalCount = max(1, events.count / 20)
            let removed = Array(events.prefix(removalCount))
            events.removeFirst(removalCount)
            if let newest = removed.map(\.observedAt).max() {
                truncatedBefore = max(truncatedBefore ?? newest, newest)
            }
            let issues = Set(original.issueCodes).union([.retentionTruncated, .fileBudgetExceeded])
            let candidate = CapabilityHistoryStateV1(
                epoch: original.epoch,
                revision: original.revision,
                nextSequence: original.nextSequence,
                retentionAnchorAt: original.retentionAnchorAt,
                truncatedBefore: truncatedBefore,
                latestScanCoverage: original.latestScanCoverage,
                scopes: original.scopes,
                baselines: original.baselines,
                pendingMissing: original.pendingMissing,
                events: events,
                issueCodes: Array(issues)
            )
            let data = try Self.encode(candidate)
            if data.count <= maximumBytes { return (candidate, data) }
        }

        let baselineOnly = CapabilityHistoryStateV1(
            epoch: original.epoch,
            revision: original.revision,
            nextSequence: original.nextSequence,
            retentionAnchorAt: original.retentionAnchorAt,
            truncatedBefore: truncatedBefore,
            latestScanCoverage: original.latestScanCoverage,
            scopes: original.scopes,
            baselines: original.baselines,
            pendingMissing: original.pendingMissing,
            events: [],
            issueCodes: Array(Set(original.issueCodes).union([.fileBudgetExceeded]))
        )
        guard try Self.encode(baselineOnly).count <= maximumBytes else {
            // Current tracking cannot be cropped. The caller retains the old
            // complete file and reports a limited history domain.
            throw StoreError.fileBudgetExceeded
        }
        return (baselineOnly, try Self.encode(baselineOnly))
    }

    private func persist(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw StoreError.fileBudgetExceeded }
        switch backend {
        case .memory:
            try inject(.beforeTemporaryWrite)
            try inject(.afterTemporaryWrite)
            try inject(.beforeReplacement)
            memoryData = data
            do { try inject(.afterReplacement) }
            catch { throw PostReplacementFailure(phase: .afterReplacement) }
        case .file:
            guard let fileContext else { throw StoreError.storageUnavailable }
            try Self.revalidateDirectory(fileContext)
            let temporaryName = ".\(fileContext.fileName).\(UUID().uuidString).tmp"
            var shouldRemoveTemporary = true
            do {
                try inject(.beforeTemporaryWrite)
                let descriptor = openat(
                    fileContext.directoryDescriptor,
                    temporaryName,
                    O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    S_IRUSR | S_IWUSR
                )
                guard descriptor >= 0 else { throw StoreError.atomicWriteFailed }
                do {
                    try Self.validateRegularFileDescriptor(descriptor)
                    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                        throw StoreError.atomicWriteFailed
                    }
                    try Self.writeAll(data, to: descriptor)
                    guard Darwin.fsync(descriptor) == 0 else {
                        switch errno {
                        case ENOSPC, EDQUOT, EFBIG: throw StoreError.fileBudgetExceeded
                        case EACCES, EPERM, EROFS: throw StoreError.storageUnavailable
                        default: throw StoreError.atomicWriteFailed
                        }
                    }
                } catch {
                    _ = close(descriptor)
                    throw error
                }
                guard Darwin.close(descriptor) == 0 else { throw StoreError.atomicWriteFailed }
                do { try inject(.afterTemporaryWrite) }
                catch {
                    // Model a process exit after a complete temporary write.
                    // The authoritative old file is untouched; a later load
                    // ignores this non-authoritative sibling.
                    shouldRemoveTemporary = false
                    throw error
                }
                try inject(.beforeReplacement)
                try Self.validateHistoryEntryIfPresent(fileContext)
                try Self.revalidateDirectory(fileContext)
                guard renameat(
                    fileContext.directoryDescriptor,
                    temporaryName,
                    fileContext.directoryDescriptor,
                    fileContext.fileName
                ) == 0 else { throw StoreError.atomicWriteFailed }
                shouldRemoveTemporary = false
                do {
                    try Self.validateHistoryEntryIfPresent(fileContext)
                    guard Darwin.fsync(fileContext.directoryDescriptor) == 0 else {
                        throw StoreError.atomicWriteFailed
                    }
                    try inject(.afterReplacement)
                } catch {
                    // The authoritative name already points at the complete
                    // new regular file. Preserve the candidate in memory even
                    // when a durability check or injected crash is reported.
                    throw PostReplacementFailure(phase: .afterReplacement)
                }
            } catch let error as PostReplacementFailure {
                throw error
            } catch let error as StoreError {
                if shouldRemoveTemporary {
                    _ = unlinkat(fileContext.directoryDescriptor, temporaryName, 0)
                }
                throw error
            } catch {
                if shouldRemoveTemporary {
                    _ = unlinkat(fileContext.directoryDescriptor, temporaryName, 0)
                }
                throw StoreError.atomicWriteFailed
            }
        }
    }

    private func inject(_ phase: WritePhase) throws {
        do { try faultInjection.fail(phase) }
        catch let error as StoreError { throw error }
        catch let error as POSIXError {
            switch error.code.rawValue {
            case ENOSPC, EDQUOT, EFBIG:
                throw StoreError.fileBudgetExceeded
            case EACCES, EPERM, EROFS:
                throw StoreError.storageUnavailable
            default:
                throw StoreError.injectedFailure(phase)
            }
        }
        catch { throw StoreError.injectedFailure(phase) }
    }

    /// Opens/creates the private directory one component at a time. No path
    /// chmod is performed: the descriptor is proven to name the linked
    /// directory before its permissions are narrowed, so a symlink swap can
    /// never redirect chmod to an external sentinel.
    private static func openFileContext(for url: URL, timeout: TimeInterval) throws -> FileContext {
        guard timeout >= 0,
              url.isFileURL,
              url.path.hasPrefix("/"),
              isSafeFileName(url.lastPathComponent) else {
            throw StoreError.storageUnavailable
        }
        let requestedDirectoryURL = url.deletingLastPathComponent().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let broadDirectories: Set<String> = [
            "/", "/Users", "/Applications", "/Library", "/tmp", "/private/tmp",
            "/var", "/private/var", home.path,
            home.appendingPathComponent("Desktop", isDirectory: true).path,
            home.appendingPathComponent("Documents", isDirectory: true).path,
            home.appendingPathComponent("Downloads", isDirectory: true).path,
            home.appendingPathComponent("Library", isDirectory: true).path,
            home.appendingPathComponent("Movies", isDirectory: true).path,
            home.appendingPathComponent("Music", isDirectory: true).path,
            home.appendingPathComponent("Pictures", isDirectory: true).path,
            home.appendingPathComponent("Public", isDirectory: true).path,
        ]
        guard !broadDirectories.contains(requestedDirectoryURL.path) else {
            throw StoreError.storageUnavailable
        }
        let directoryURL = try canonicalDirectoryURL(for: requestedDirectoryURL)
        guard directoryURL.path != "/",
              directoryURL.pathComponents.filter({ $0 != "/" && !$0.isEmpty }).count >= 3 else {
            throw StoreError.storageUnavailable
        }
        let directoryDescriptor = try openDirectory(directoryURL, create: true)
        var ownedContext: FileContext?
        do {
            var directoryInfo = stat()
            guard Darwin.fstat(directoryDescriptor, &directoryInfo) == 0,
                  fileType(directoryInfo) == UInt32(S_IFDIR),
                  Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                throw StoreError.storageUnavailable
            }
            let identity = DirectoryIdentity(directoryInfo)
            let lockDescriptor = try acquireLease(
                directoryDescriptor: directoryDescriptor,
                timeout: timeout
            )
            let context = FileContext(
                directoryDescriptor: directoryDescriptor,
                lockDescriptor: lockDescriptor,
                directoryURL: directoryURL,
                fileName: url.lastPathComponent,
                identity: identity
            )
            ownedContext = context
            try revalidateDirectory(context)
            try validateHistoryEntryIfPresent(context)
            return context
        } catch {
            if ownedContext == nil { _ = Darwin.close(directoryDescriptor) }
            ownedContext = nil
            if let storeError = error as? StoreError { throw storeError }
            throw StoreError.storageUnavailable
        }
    }

    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw StoreError.storageUnavailable }
        for component in components {
            guard isSafeFileName(component) else {
                _ = Darwin.close(parent)
                throw StoreError.storageUnavailable
            }
            var child = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, create {
                if Darwin.mkdirat(parent, component, mode_t(0o700)) != 0, errno != EEXIST {
                    _ = Darwin.close(parent)
                    throw StoreError.storageUnavailable
                }
                child = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                _ = Darwin.close(parent)
                throw StoreError.storageUnavailable
            }
            var opened = stat()
            var linked = stat()
            guard Darwin.fstat(child, &opened) == 0,
                  fileType(opened) == UInt32(S_IFDIR),
                  Darwin.fstatat(parent, component, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  fileType(linked) == UInt32(S_IFDIR),
                  DirectoryIdentity(opened) == DirectoryIdentity(linked) else {
                _ = Darwin.close(child)
                _ = Darwin.close(parent)
                throw StoreError.storageUnavailable
            }
            _ = Darwin.close(parent)
            parent = child
        }
        return parent
    }

    private static func acquireLease(
        directoryDescriptor: Int32,
        timeout: TimeInterval
    ) throws -> Int32? {
        let lockName = ".capability-history.lock"
        let descriptor = Darwin.openat(
            directoryDescriptor,
            lockName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        do {
            try validateRegularFileDescriptor(descriptor)
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw StoreError.storageUnavailable
            }
            var linked = stat()
            var opened = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  Darwin.fstatat(directoryDescriptor, lockName, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  regularSingleLink(linked),
                  sameObject(opened, linked) else {
                throw StoreError.storageUnavailable
            }

            let timeoutNanoseconds = UInt64(
                min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000
            )
            let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
            repeat {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw StoreError.storageUnavailable
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                usleep(10_000)
            } while true
            _ = Darwin.close(descriptor)
            return nil
        } catch {
            _ = Darwin.close(descriptor)
            if let storeError = error as? StoreError { throw storeError }
            throw StoreError.storageUnavailable
        }
    }

    private static func revalidateDirectory(_ context: FileContext) throws {
        var held = stat()
        guard Darwin.fstat(context.directoryDescriptor, &held) == 0,
              fileType(held) == UInt32(S_IFDIR),
              DirectoryIdentity(held) == context.identity else {
            throw StoreError.storageUnavailable
        }
        let current = try openDirectory(context.directoryURL, create: false)
        defer { _ = Darwin.close(current) }
        var currentInfo = stat()
        guard Darwin.fstat(current, &currentInfo) == 0,
              DirectoryIdentity(currentInfo) == context.identity else {
            throw StoreError.storageUnavailable
        }
    }

    private static func validateHistoryEntryIfPresent(_ context: FileContext) throws {
        var linked = stat()
        if Darwin.fstatat(
            context.directoryDescriptor,
            context.fileName,
            &linked,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT { return }
            throw StoreError.storageUnavailable
        }
        guard regularSingleLink(linked) else { throw StoreError.storageUnavailable }
        let descriptor = Darwin.openat(
            context.directoryDescriptor,
            context.fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              regularSingleLink(opened),
              sameObject(opened, linked) else {
            throw StoreError.storageUnavailable
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw StoreError.storageUnavailable
        }
    }

    private static func readHistoryData(
        _ context: FileContext,
        maximumBytes: Int
    ) throws -> Data? {
        var linked = stat()
        if Darwin.fstatat(
            context.directoryDescriptor,
            context.fileName,
            &linked,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT { return nil }
            throw StoreError.storageUnavailable
        }
        guard regularSingleLink(linked), linked.st_size >= 0,
              UInt64(linked.st_size) <= UInt64(maximumBytes) else {
            throw regularSingleLink(linked) ? StoreError.oversized : StoreError.storageUnavailable
        }
        let descriptor = Darwin.openat(
            context.directoryDescriptor,
            context.fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw StoreError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              regularSingleLink(before),
              sameObject(before, linked),
              before.st_size >= 0,
              UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw StoreError.storageUnavailable
        }

        var data = Data()
        data.reserveCapacity(min(Int(before.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreError.storageUnavailable
            }
            guard data.count <= maximumBytes - count else { throw StoreError.oversized }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              regularSingleLink(after),
              sameObject(before, after),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw StoreError.storageUnavailable
        }
        return data
    }

    private static func validateRegularFileDescriptor(_ descriptor: Int32) throws {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              regularSingleLink(value) else {
            throw StoreError.storageUnavailable
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    switch errno {
                    case ENOSPC, EDQUOT, EFBIG: throw StoreError.fileBudgetExceeded
                    case EACCES, EPERM, EROFS: throw StoreError.storageUnavailable
                    default: throw StoreError.atomicWriteFailed
                    }
                }
                guard count > 0 else { throw StoreError.atomicWriteFailed }
                offset += count
            }
        }
    }

    /// Normalize only the two fixed macOS system aliases. Resolving an
    /// arbitrary existing ancestor would follow a user-controlled symlink
    /// before descriptor traversal and could redirect the later chmod. Every
    /// remaining component is opened with `O_NOFOLLOW` and identity checked.
    private static func canonicalDirectoryURL(for requested: URL) throws -> URL {
        let path = requested.standardizedFileURL.path
        let normalized: String
        if path.hasPrefix("/var/") {
            normalized = "/private/var/" + path.dropFirst("/var/".count)
        } else if path.hasPrefix("/tmp/") {
            normalized = "/private/tmp/" + path.dropFirst("/tmp/".count)
        } else {
            normalized = path
        }
        guard normalized.hasPrefix("/") else { throw StoreError.storageUnavailable }
        // Do not standardize again after converting the trusted aliases.
        // Foundation canonicalizes an existing `/private/var/...` back to
        // `/var/...`, which would reintroduce a symlink into the descriptor
        // walk. Dot components were already removed from the requested URL.
        return URL(fileURLWithPath: normalized, isDirectory: true)
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\0")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func fileType(_ value: stat) -> UInt32 {
        UInt32(value.st_mode) & UInt32(S_IFMT)
    }

    private static func regularSingleLink(_ value: stat) -> Bool {
        fileType(value) == UInt32(S_IFREG) && value.st_nlink == 1
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && fileType(lhs) == fileType(rhs)
    }

    private static func encode(_ state: CapabilityHistoryStateV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private static func decode(_ data: Data) throws -> CapabilityHistoryStateV1 {
        struct SchemaHeader: Decodable {
            let schemaVersion: Int
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let header: SchemaHeader
        do { header = try decoder.decode(SchemaHeader.self, from: data) }
        catch { throw StoreError.corrupt }
        guard header.schemaVersion == CapabilityHistoryStateV1.schemaVersion else {
            throw StoreError.unsupportedVersion(header.schemaVersion)
        }
        let state: CapabilityHistoryStateV1
        do { state = try decoder.decode(CapabilityHistoryStateV1.self, from: data) }
        catch { throw StoreError.corrupt }
        guard state.schemaVersion == CapabilityHistoryStateV1.schemaVersion else {
            throw StoreError.unsupportedVersion(state.schemaVersion)
        }
        return state
    }

    private static func validate(
        _ state: CapabilityHistoryStateV1,
        retentionPolicy: CapabilityHistoryRetentionPolicy
    ) throws {
        guard state.schemaVersion == CapabilityHistoryStateV1.schemaVersion else {
            throw StoreError.unsupportedVersion(state.schemaVersion)
        }
        guard state.epoch > 0,
              state.revision >= 0,
              state.revision < Int64.max,
              state.nextSequence > 0,
              state.nextSequence < Int64.max,
              state.events.count <= retentionPolicy.maximumEvents,
              state.baselines.count <= 100_000,
              state.scopes.count <= 100_000,
              state.pendingMissing.count <= state.baselines.count,
              finite(state.retentionAnchorAt), finite(state.truncatedBefore) else {
            throw StoreError.invalidState
        }
        guard unique(state.scopes.map(\.rootID)),
              unique(state.baselines.map(\.resourceID)),
              unique(state.pendingMissing.map(\.resourceID)),
              unique(state.events.map(\.id)),
              unique(state.events.map(\.sequence)) else { throw StoreError.invalidState }

        let baselineIDs = Set(state.baselines.map(\.resourceID))
        guard state.pendingMissing.allSatisfy({ baselineIDs.contains($0.resourceID) }) else {
            throw StoreError.invalidState
        }
        for scope in state.scopes {
            guard safeIdentifier(scope.rootID),
                  scope.scope == .global || scope.scope == .project,
                  ScanRootKind(rawValue: scope.rootKind) != nil,
                  finite(scope.initializedAt), finite(scope.lastCompleteAt) else {
                throw StoreError.invalidState
            }
        }
        for baseline in state.baselines {
            guard safeIdentifier(baseline.resourceID), safeIdentifier(baseline.sourceRootID),
                  safeName(baseline.name),
                  baseline.resourceKind == .agent || baseline.resourceKind == .skill,
                  baseline.scope == .global || baseline.scope == .project,
                  validProjectID(baseline.projectID, scope: baseline.scope),
                  unique(baseline.documents),
                  validDocuments(Set(baseline.documents), kind: baseline.resourceKind),
                  baseline.documents == baseline.documents.sorted(by: { $0.rawValue < $1.rawValue }),
                  validSignature(baseline.signature),
                  validDocumentSignatures(baseline.documentSignatures, documents: Set(baseline.documents)),
                  safeIdentifier(baseline.signatureAlgorithm, maximum: 64),
                  finite(baseline.lastConfirmedAt), finite(baseline.missingSince),
                  (baseline.presence == .missing) == (baseline.missingSince != nil) else {
                throw StoreError.invalidState
            }
        }
        for pending in state.pendingMissing {
            guard safeIdentifier(pending.resourceID), safeIdentifier(pending.sourceRootID),
                  finite(pending.firstMissingAt), finite(pending.previousConfirmedAt) else {
                throw StoreError.invalidState
            }
        }
        var eventCounts: [String: Int] = [:]
        for event in state.events {
            eventCounts[event.resourceID, default: 0] += 1
            guard event.id == "history-\(state.epoch)-\(event.sequence)",
                  safeIdentifier(event.resourceID), safeName(event.name),
                  event.resourceKind == .agent || event.resourceKind == .skill,
                  event.scope == .global || event.scope == .project,
                  validProjectID(event.projectID, scope: event.scope),
                  event.changedDocuments.isSubset(of: Set(CapabilityTrackedDocument.allCases)),
                  validChangedDocuments(event),
                  finite(event.observedAt), finite(event.previousConfirmedAt), finite(event.retentionObservedAt),
                  event.sequence > 0 else { throw StoreError.invalidState }
        }
        guard eventCounts.values.allSatisfy({ $0 <= retentionPolicy.maximumEventsPerResource }),
              (state.events.map(\.sequence).max() ?? 0) < state.nextSequence else {
            throw StoreError.invalidState
        }
    }

    private static func safeIdentifier(_ value: String, maximum: Int = 512) -> Bool {
        !value.isEmpty && value.count <= maximum
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.contains("://")
            && !value.lowercased().hasPrefix("file:")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !PersistenceAllowlist.containsForbiddenValue(value)
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !PersistenceAllowlist.containsForbiddenValue(value)
    }

    private static func validProjectID(_ value: String?, scope: ResourceScope) -> Bool {
        if scope == .project { return value.map { safeIdentifier($0) } ?? false }
        return value == nil
    }

    private static func validDocuments(_ documents: Set<CapabilityTrackedDocument>, kind: ResourceKind) -> Bool {
        switch kind {
        case .agent:
            return !documents.isEmpty && documents.isSubset(of: [.agentConfiguration, .agentBrief])
        case .skill:
            return documents == [.skillManifest]
        default:
            return false
        }
    }

    private static func validSignature(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func validDocumentSignatures(
        _ signatures: [CapabilityTrackedDocumentSignature],
        documents: Set<CapabilityTrackedDocument>
    ) -> Bool {
        guard !signatures.isEmpty else { return true }
        let grouped = Dictionary(grouping: signatures, by: \.document)
        return Set(grouped.keys) == documents
            && grouped.values.allSatisfy { values in
                values.count == 1 && validSignature(values[0].sha256)
            }
    }

    private static func validChangedDocuments(_ event: CapabilityChangeEvent) -> Bool {
        guard event.changedDocumentsAreExact else { return event.changedDocuments.isEmpty }
        switch event.kind {
        case .missing:
            return event.changedDocuments.isEmpty
        case .reappeared:
            return event.changedDocuments.isEmpty
                || validDocuments(event.changedDocuments, kind: event.resourceKind)
        case .added, .modified:
            return validDocuments(event.changedDocuments, kind: event.resourceKind)
        }
    }

    private static func finite(_ date: Date?) -> Bool {
        date.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true
    }

    private static func unique<T: Hashable>(_ values: [T]) -> Bool {
        Set(values).count == values.count
    }

    private static func issueCode(for error: StoreError) -> CapabilityHistoryIssueCode {
        switch error {
        case .oversized, .fileBudgetExceeded: return .fileBudgetExceeded
        case .corrupt, .invalidState: return .corruptStorage
        case .unsupportedVersion: return .unsupportedSchema
        case .readOnly: return .readOnlyLockConflict
        case .storageUnavailable, .atomicWriteFailed, .injectedFailure: return .storageUnavailable
        case .stalePermit, .confirmationRequired: return .historyGap
        }
    }
}
