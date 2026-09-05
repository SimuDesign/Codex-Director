import Foundation
import SwiftUI
import DirectorCore

/// Services produced by the application bootstrap boundary. The writer is
/// reserved for indexing/deletion; presentation reads use the read-only store.
public struct DirectorStartupServices: Sendable {
    public let store: DatabaseStore?
    public let readStore: DatabaseStore?
    public let coordinator: IndexingCoordinator?
    public let configuration: IndexingCoordinator.Configuration?
    public let snapshotStore: PresentationSnapshotStore?
    public let capabilityExportCoordinator: CapabilityExportCoordinator?
    public let safeError: String?

    public init(
        store: DatabaseStore?,
        readStore: DatabaseStore?,
        coordinator: IndexingCoordinator?,
        configuration: IndexingCoordinator.Configuration?,
        snapshotStore: PresentationSnapshotStore?,
        capabilityExportCoordinator: CapabilityExportCoordinator? = nil,
        safeError: String? = nil
    ) {
        self.store = store
        self.readStore = readStore
        self.coordinator = coordinator
        self.configuration = configuration
        self.snapshotStore = snapshotStore
        self.capabilityExportCoordinator = capabilityExportCoordinator
        self.safeError = safeError
    }
}

/// Owns one application-scoped startup operation. Cache restoration and slow
/// service construction begin together, while the cache is installed into the
/// existing lightweight model as soon as it is available.
@MainActor
public final class DirectorStartupController: ObservableObject {
    public typealias CacheFactory = @Sendable () async -> PresentationSnapshotStore?
    public typealias ServicesFactory = @Sendable () async -> DirectorStartupServices

    @Published public private(set) var isStarted = false
    @Published public private(set) var isFinished = false

    private let cacheFactory: CacheFactory
    private let servicesFactory: ServicesFactory
    private var startupTask: Task<Void, Never>?

    public init(cacheFactory: @escaping CacheFactory, servicesFactory: @escaping ServicesFactory) {
        self.cacheFactory = cacheFactory
        self.servicesFactory = servicesFactory
    }

    /// Starts at most once. The returned task is intentionally owned here,
    /// rather than by a window `.task`, so closing one window cannot cancel the
    /// application bootstrap needed by another.
    public func start(model: DirectorAppModel) {
        guard startupTask == nil else { return }
        isStarted = true
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cacheTask = Task { await self.cacheFactory() }
            let servicesTask = Task { await self.servicesFactory() }

            let cache = await cacheTask.value
            model.installPresentationSnapshotStore(cache)
            _ = await model.restoreCachedPresentation()

            let services = await servicesTask.value
            model.installServices(
                store: services.store,
                readStore: services.readStore,
                coordinator: services.coordinator,
                configuration: services.configuration,
                capabilityExportCoordinator: services.capabilityExportCoordinator,
                // Keep the actor created by the prebootstrap cache path as
                // the sole owner of this file for the model's full lifetime.
                presentationSnapshotStore: cache ?? services.snapshotStore,
                bootstrapError: services.safeError
            )
            if services.store != nil, services.readStore != nil {
                _ = await model.loadInitialData()
                model.startSourceDataMonitor()
            }
            self.isFinished = true
        }
    }

    deinit {
        startupTask?.cancel()
    }
}
