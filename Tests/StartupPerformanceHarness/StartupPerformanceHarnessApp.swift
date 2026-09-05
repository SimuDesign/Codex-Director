import SwiftUI
import AppKit
import DirectorCore
import DirectorUI

/// Standalone, test-only app scaffold for Task 7. The production app entry
/// point is not modified and this target must not be part of the release
/// product scheme.
@MainActor
private final class StartupPerformanceLaunchState: ObservableObject {
    let model: DirectorAppModel
    let recorder: StartupPerformanceRecorder
    let passiveMarkers: StartupPerformancePassiveMarkers
    private let manifest: StartupPerformanceManifest?
    private let controller: DirectorStartupController
    private var didStart = false
    private var didRecordCachePayload = false
    private var didRequestAutomaticTermination = false

    init() {
        let loadedManifest = try? StartupPerformanceManifest.loadCurrent()
        manifest = loadedManifest
        // Invalid manifests must not cause writes to a fallback/shared path.
        let launchRecorder = StartupPerformanceRecorder(outputDirectory: loadedManifest?.metricsURL)
        recorder = launchRecorder
        passiveMarkers = StartupPerformancePassiveMarkers(recorder: launchRecorder)
        StartupPerformanceAppDelegate.recorder = launchRecorder
        launchRecorder.mark(loadedManifest == nil ? "manifest_invalid" : "app_init")

        let preferences = LaunchMemoryPreferences()
        model = DirectorAppModel(
            classificationOverrides: ResourceClassificationOverrideStore(
                readData: { preferences.data(for: ResourceClassificationOverrideStore.defaultsKey) },
                writeData: { preferences.set($0, for: ResourceClassificationOverrideStore.defaultsKey) },
                removeData: { preferences.remove(ResourceClassificationOverrideStore.defaultsKey) }
            ),
            evaluationStore: InvocationEvaluationStore(
                readData: { preferences.data(for: InvocationEvaluationStore.defaultsKey) },
                writeData: { preferences.set($0, for: InvocationEvaluationStore.defaultsKey); return true },
                removeData: { preferences.remove(InvocationEvaluationStore.defaultsKey); return true }
            ),
            previewMode: false,
            bootstrapPending: true
        )

        // Capture only immutable, test-owned values in the @Sendable factories.
        // The launch state is MainActor-isolated and must not be captured by
        // the asynchronous service construction closures.
        let launchManifest = loadedManifest
        controller = DirectorStartupController(
            cacheFactory: {
                guard let launchManifest,
                      let current = try? StartupPerformanceManifest.loadCurrent(),
                      current == launchManifest else {
                    launchRecorder.increment("manifest_revalidation_failed")
                    return nil
                }
                launchRecorder.increment("cache_factory")
                let cache = PresentationSnapshotStore(url: current.cacheURL)
                if current.scenario == .cachedIndexed {
                    guard let snapshot = try? await cache.read(),
                          snapshot.identity.databaseEpoch == current.expectedDatabaseEpoch,
                          snapshot.identity.dataGeneration == current.expectedDataGeneration else {
                        launchRecorder.increment("cache_identity_mismatch")
                        return nil
                    }
                    launchRecorder.increment("cache_identity_checked")
                }
                return cache
            },
            servicesFactory: {
                guard let launchManifest else {
                    launchRecorder.increment("manifest_invalid")
                    return DirectorStartupServices(store: nil, readStore: nil, coordinator: nil, configuration: nil, snapshotStore: nil, safeError: "manifest_invalid")
                }
                return await Task.detached(priority: .utility) {
                    guard let current = try? StartupPerformanceManifest.loadCurrent(), current == launchManifest else {
                        launchRecorder.increment("manifest_revalidation_failed")
                        return DirectorStartupServices(store: nil, readStore: nil, coordinator: nil, configuration: nil, snapshotStore: nil, safeError: "manifest_invalid")
                    }
                    do {
                        let queryObserver: @Sendable (PresentationQueryOperation) -> Void = { operation in
                            launchRecorder.increment("query_\(operation.rawValue)")
                        }
                        let sourceObserver: @Sendable (SourceIndexPhase) -> Void = { phase in
                            launchRecorder.increment("source_\(phase.rawValue)")
                        }
                        let writer = try DatabaseStore(url: current.databaseURL, queryObserver: queryObserver)
                        let reader = try DatabaseStore(url: current.databaseURL, readOnly: true, queryObserver: queryObserver)
                        let metadata = try await reader.fetchPresentationIndexMetadata()
                        guard metadata.identity.databaseEpoch == current.expectedDatabaseEpoch,
                              metadata.identity.dataGeneration == current.expectedDataGeneration,
                              metadata.lastSourceCheckAt == current.expectedLastSourceCheckAt,
                              metadata.lastIndexCompletedAt == current.expectedLastIndexCompletedAt else {
                            launchRecorder.increment("database_metadata_mismatch")
                            return DirectorStartupServices(store: nil, readStore: nil, coordinator: nil, configuration: nil, snapshotStore: nil, safeError: "manifest_invalid")
                        }
                        launchRecorder.increment("database_metadata_checked")
                        let coordinator = IndexingCoordinator(store: writer, sourceObserver: sourceObserver)
                        let scanRoot = ScanRoot(id: "startup-perf-sources", url: current.sourceURL, scope: .global, kind: .projects)
                        let configuration = IndexingCoordinator.Configuration(scanRoots: [scanRoot], activeSessionRoots: [], archivedSessionRoot: nil)
                        launchRecorder.increment("services_factory")
                        launchRecorder.increment("query_observer_connected")
                        launchRecorder.increment("source_observer_connected")
                        // Register the cache-hit baseline explicitly only after
                        // both observers are connected. A zero is evidence of
                        // an observed, connected hook—not an absent counter.
                        launchRecorder.increment("query_startup", by: 0)
                        launchRecorder.increment("query_quota", by: 0)
                        launchRecorder.increment("source_started", by: 0)
                        return DirectorStartupServices(store: writer, readStore: reader, coordinator: coordinator, configuration: configuration, snapshotStore: nil)
                    } catch {
                        launchRecorder.increment("services_failure")
                        return DirectorStartupServices(store: nil, readStore: nil, coordinator: nil, configuration: nil, snapshotStore: nil, safeError: "services_unavailable")
                    }
                }.value
            }
        )
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        recorder.mark("bootstrap_requested")
        controller.start(model: model)
    }

    func mark(_ stage: String) {
        recorder.mark(stage)
        if stage == "root_appeared" { passiveMarkers.start() }
        if stage == "selection_changed" { passiveMarkers.selectionChanged() }
        if stage == "startup_ready" || stage == "selection_changed" { recorder.flushAsync() }
        if stage == "startup_ready",
           ProcessInfo.processInfo.environment["CODEX_DIRECTOR_PERF_AUTO_QUIT"] == "1",
           !didRequestAutomaticTermination {
            didRequestAutomaticTermination = true
            Task { @MainActor [recorder] in
                if !(await recorder.flush()) { recorder.increment("metrics_flush_failed") }
                StartupPerformanceAppDelegate.terminationMetricsAlreadyFlushed = true
                NSApp.terminate(nil)
            }
        }
    }

    func finish() {
        Task { [recorder] in
            if !(await recorder.flush()) { recorder.increment("metrics_flush_failed") }
        }
    }

    func recordCacheStatus(_ status: DirectorCacheStatus) {
        guard manifest?.scenario == .cachedIndexed,
              status == .restoredUnverified || status == .verified else { return }
        let hasHome = model.presentationHomeSummary != nil
        let hasQuota = !(model.quotaOverviewSnapshot?.sources.isEmpty ?? true)
        guard hasHome && hasQuota else {
            recorder.increment("cache_payload_missing")
            return
        }
        guard !didRecordCachePayload else { return }
        didRecordCachePayload = true
        // This is a nonempty model-payload marker, not proof of a presented pixel.
        mark("cache_visible")
    }
}

@MainActor
private final class StartupPerformanceAppDelegate: NSObject, NSApplicationDelegate {
    static var recorder: StartupPerformanceRecorder?
    static var terminationMetricsAlreadyFlushed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.terminationMetricsAlreadyFlushed { return .terminateNow }
        guard let recorder = Self.recorder else { return .terminateNow }
        Task { @MainActor in
            let acknowledged = await recorder.flush()
            if !acknowledged { recorder.increment("metrics_flush_failed") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
private struct StartupPerformanceHarnessContent: View {
    @ObservedObject private var model: DirectorAppModel
    private let launch: StartupPerformanceLaunchState
    private let languageStore: AppLanguageStore

    init(launch: StartupPerformanceLaunchState, languageStore: AppLanguageStore) {
        self.launch = launch
        self.languageStore = languageStore
        _model = ObservedObject(wrappedValue: launch.model)
    }

    var body: some View {
        DirectorRootView(model: model)
            .environmentObject(languageStore)
            .onAppear { launch.mark("root_appeared") }
            .onChange(of: model.cacheStatus) { _, status in
                launch.recordCacheStatus(status)
                if status == .verified { launch.mark("cache_verified") }
            }
            .onChange(of: model.bootstrapStatus) { _, status in
                if status == .ready { launch.mark("startup_ready") }
            }
            .onChange(of: model.selection) { _, _ in launch.mark("selection_changed") }
            .onDisappear { launch.finish() }
            .task { launch.start() }
    }
}

private final class LaunchMemoryPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { lock.withLock { values[key] } }
    func set(_ value: Data, for key: String) { lock.withLock { values[key] = value } }
    func remove(_ key: String) { lock.withLock { values.removeValue(forKey: key) } }
}

@main
struct StartupPerformanceHarnessApp: App {
    @NSApplicationDelegateAdaptor(StartupPerformanceAppDelegate.self) private var appDelegate
    @StateObject private var launch: StartupPerformanceLaunchState
    @StateObject private var languageStore: AppLanguageStore

    init() {
        _launch = StateObject(wrappedValue: StartupPerformanceLaunchState())
        _languageStore = StateObject(wrappedValue: AppLanguageStore(memoryLanguage: .simplifiedChinese))
    }

    var body: some Scene {
        WindowGroup("Codex Director Startup Performance") {
            StartupPerformanceHarnessContent(launch: launch, languageStore: languageStore)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock(); defer { unlock() }
        return body()
    }
}
