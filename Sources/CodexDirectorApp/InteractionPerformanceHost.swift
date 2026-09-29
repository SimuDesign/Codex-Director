#if DIRECTOR_INTERACTION_PERFORMANCE
import AppKit
import Foundation
import OSLog
import SwiftUI
import DirectorCore
import DirectorUI

/// Release-equivalent synthetic interaction host. The build is enabled only
/// by DIRECTOR_INTERACTION_PERFORMANCE and receives an isolated in-memory
/// preference store plus a strictly selected synthetic fixture from DirectorUI.
@MainActor
struct InteractionPerformanceHost: View {
    @ObservedObject private var languageStore: AppLanguageStore
    @ObservedObject private var themeStore: AppThemeStore
    @State private var session: UIValidationSession?
    @State private var counters: InteractionPerformanceCounters
    @StateObject private var driver = InteractionPerformanceDriver()
    @State private var didRun = false
    private let width: CGFloat
    private let height: CGFloat
    private let fixtureName: String

    init(languageStore: AppLanguageStore, themeStore: AppThemeStore) {
        _languageStore = ObservedObject(wrappedValue: languageStore)
        _themeStore = ObservedObject(wrappedValue: themeStore)
        let counters = InteractionPerformanceCounters()
        _counters = State(initialValue: counters)
        let requestedFixture = ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_FIXTURE"] ?? UIValidationSession.Dataset.interactionStress.rawValue
        fixtureName = requestedFixture
        let selectedFixture = UIValidationSession.Dataset(rawValue: requestedFixture).flatMap { fixture in
            fixture == .interactionStress || fixture == .representative || fixture == .interactionRepresentative ? fixture : nil
        }
        if let selectedFixture {
            _session = State(initialValue: try? UIValidationSession(dataset: selectedFixture, queryObserver: { operation in
                counters.increment(operation)
            }))
        } else {
            // Invalid fixture selection fails closed. The runner will report
            // the missing JSON without ever falling back to production data.
            _session = State(initialValue: nil)
        }
        width = CGFloat(Double(ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_WIDTH"] ?? "1280") ?? 1280)
        height = CGFloat(Double(ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_HEIGHT"] ?? "800") ?? 800)
    }

    var body: some View {
        Group {
            if let session {
                DirectorRootView(model: session.model, interactionPerformanceDriver: driver)
                    .environmentObject(languageStore)
                    .environmentObject(themeStore)
                    .background(InteractionPerformanceWindowReader(width: width, height: height))
                    .id(session.generation)
            } else {
                Text("Synthetic interaction fixture unavailable")
                    .frame(minWidth: width, minHeight: height)
            }
        }
        .task {
            guard let session, !didRun else {
                if self.session == nil { NSApp.terminate(nil) }
                return
            }
            didRun = true
            await run(session: session)
        }
        .preferredColorScheme(themeStore.theme.colorScheme)
    }

    private func run(session: UIValidationSession) async {
        do {
            try await session.prepare()
        } catch {
            // Keep the failure privacy-safe and fail the shell runner through
            // its missing report check; never continue on an unprepared model.
            NSApp.terminate(nil)
            return
        }
        // Native-window review stays inside the isolated Release host. It
        // never runs the synthetic click driver or opens a production store.
        if ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_MANUAL_REVIEW"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
            print("native_review_ready pid=\(ProcessInfo.processInfo.processIdentifier)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(600))
            NSApp.terminate(nil)
            return
        }
        let recorder = InteractionPerformanceRecorder(
            outputURL: Self.outputURL(),
            width: width,
            height: height,
            fixture: fixtureName,
            inventory: Self.inventory(for: session.model.capabilityFolders),
            queryCounters: counters
        )
        let runLoopProbe = InteractionPerformanceRunLoopProbe(recorder: recorder)
        let runner = InteractionPerformanceRunner(model: session.model, driver: driver, recorder: recorder)
        await runner.runSamples(count: Int(ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_SAMPLES"] ?? "20") ?? 20)
        _ = runLoopProbe
        recorder.finish()
        // Keep termination outside the recorder's final write task so the
        // aggregate file is durably acknowledged before the process exits.
        NSApp.terminate(nil)
    }

    private static func inventory(for projection: CapabilityFolderProjection) -> InteractionPerformanceRecorder.FixtureInventoryCounts {
        func counts(_ members: [CapabilityFolderMember]) -> InteractionPerformanceRecorder.ResourceKindCounts {
            InteractionPerformanceRecorder.ResourceKindCounts(
                agents: members.filter { $0.resource.kind == .agent }.count,
                skills: members.filter { $0.resource.kind == .skill }.count
            )
        }
        let global = counts(projection.members(in: CapabilityFolderDefinition.globalID))
        let projectMembers = projection.folders
            .filter { $0.source == .project }
            .flatMap { projection.members(in: $0.id) }
        let customMembers = projection.folders
            .filter(\.isCustom)
            .flatMap { projection.members(in: $0.id) }
        return InteractionPerformanceRecorder.FixtureInventoryCounts(
            agents: projection.resources.filter { $0.kind == .agent }.count,
            skills: projection.resources.filter { $0.kind == .skill }.count,
            folders: projection.folders.count,
            global: global,
            project: counts(projectMembers),
            custom: counts(customMembers)
        )
    }

    private static func outputURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_PERF_OUTPUT"],
              path.hasPrefix("/tmp/codex-director-interaction-perf/") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "json" else { return nil }
        return url
    }
}

/// Measures the longest main-run-loop turn while the synthetic interaction
/// sequence is active. This is intentionally separate from app-stage markers:
/// it reports a scheduling/blocking signal, not a painted-frame timestamp.
private final class InteractionPerformanceRunLoopProbe {
    private var observer: CFRunLoopObserver?

    init(recorder: InteractionPerformanceRecorder) {
        var turnStart: UInt64?
        let activities: CFRunLoopActivity = [.beforeSources, .beforeWaiting, .exit]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, activity in
            switch activity {
            case .beforeSources:
                turnStart = DispatchTime.now().uptimeNanoseconds
            case .beforeWaiting, .exit:
                guard let start = turnStart else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                recorder.setMainRunLoopLongestTurn(elapsed)
                turnStart = nil
            default:
                break
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
}

private final class InteractionPerformanceCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func increment(_ operation: PresentationQueryOperation) {
        lock.lock(); defer { lock.unlock() }
        values[operation.rawValue, default: 0] += 1
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private final class InteractionPerformanceRecorder: @unchecked Sendable {
    struct StageToken {
        let name: String
        let instant: ContinuousClock.Instant
        let signpostID: OSSignpostID
        let sequence: Int
    }

    struct StageEvent: Codable, Sendable {
        let sequence: Int
        let name: String
        let durationMilliseconds: Double
        let queryCounts: [String: Int]
        let phaseDurationsMilliseconds: [String: Double]
        let phaseCounts: [String: Int]
    }

    struct Sample: Codable, Sendable {
        let index: Int
        let path: String
        let width: Int
        let height: Int
        let durationsMilliseconds: [String: Double]
        let stageEvents: [StageEvent]
        let queryCounts: [String: Int]
        let queryCountsByStage: [String: [String: Int]]
        let mainRunLoopLongestTurnMilliseconds: Double
    }

    struct RuntimeEnvironment: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let syntheticData: Bool
    }

    struct ResourceKindCounts: Codable, Sendable {
        let agents: Int
        let skills: Int
    }

    struct FixtureInventoryCounts: Codable, Sendable {
        let agents: Int
        let skills: Int
        let folders: Int
        let global: ResourceKindCounts
        let project: ResourceKindCounts
        let custom: ResourceKindCounts
    }

    struct BuildIdentity: Codable, Sendable {
        let bundleIdentifier: String
        let appVersion: String
        let configuration: String
        let optimization: String
        let compilationCondition: String
        let signature: String
    }

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let fixture: String
        let measurementMode: String
        let width: Int
        let height: Int
        let samples: [Sample]
        let signpostCategory: String
        let inputToPaintMeasurement: String
        let runtimeEnvironment: RuntimeEnvironment
        let buildIdentity: BuildIdentity
        let inventory: FixtureInventoryCounts
    }

    private let outputURL: URL?
    private let width: CGFloat
    private let height: CGFloat
    private let fixture: String
    private let inventory: FixtureInventoryCounts
    private let queryCounters: InteractionPerformanceCounters
    private let clock = ContinuousClock()
    private let log = OSLog(subsystem: "com.peiweitang.CodexDirector", category: "interaction-performance")
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var currentDurations: [String: Double] = [:]
    private var currentStageEvents: [StageEvent] = []
    private var currentQueryCounts: [String: Int] = [:]
    private var currentQueryCountsByStage: [String: [String: Int]] = [:]
    private var mainRunLoopLongestTurnMilliseconds = 0.0
    private var currentIndex = 0
    private var nextEventSequence = 0

    init(outputURL: URL?, width: CGFloat, height: CGFloat, fixture: String, inventory: FixtureInventoryCounts, queryCounters: InteractionPerformanceCounters) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.fixture = fixture
        self.inventory = inventory
        self.queryCounters = queryCounters
    }

    func begin(_ name: String) -> StageToken {
        let signpostID = OSSignpostID(log: log)
        lock.lock()
        nextEventSequence += 1
        let sequence = nextEventSequence
        lock.unlock()
        os_signpost(.begin, log: log, name: "interaction-stage", signpostID: signpostID)
        return StageToken(name: name, instant: clock.now, signpostID: signpostID, sequence: sequence)
    }

    func end(_ token: StageToken, queryCounts: [String: Int], phaseDurations: [String: Double], phaseCounts: [String: Int]) {
        let milliseconds = Self.milliseconds(token.instant.duration(to: clock.now))
        lock.lock()
        currentDurations[token.name, default: 0] += milliseconds
        currentStageEvents.append(StageEvent(
            sequence: token.sequence,
            name: token.name,
            durationMilliseconds: milliseconds,
            queryCounts: queryCounts,
            phaseDurationsMilliseconds: phaseDurations,
            phaseCounts: phaseCounts
        ))
        for (operation, value) in queryCounts {
            currentQueryCountsByStage[token.name, default: [:]][operation, default: 0] += value
        }
        lock.unlock()
        os_signpost(.end, log: log, name: "interaction-stage", signpostID: token.signpostID)
    }

    func setMainRunLoopLongestTurn(_ milliseconds: Double) {
        lock.lock(); mainRunLoopLongestTurnMilliseconds = max(mainRunLoopLongestTurnMilliseconds, milliseconds); lock.unlock()
    }

    func beginSample(index: Int) {
        lock.lock()
        currentIndex = index
        currentDurations = [:]
        currentStageEvents = []
        currentQueryCounts = queryCounters.snapshot()
        currentQueryCountsByStage = [:]
        mainRunLoopLongestTurnMilliseconds = 0
        nextEventSequence = 0
        lock.unlock()
    }

    func querySnapshot() -> [String: Int] {
        queryCounters.snapshot()
    }

    func finishSample(path: String) {
        let afterQueries = queryCounters.snapshot()
        lock.lock(); defer { lock.unlock() }
        var delta: [String: Int] = [:]
        for key in Set(currentQueryCounts.keys).union(afterQueries.keys) {
            let value = (afterQueries[key] ?? 0) - (currentQueryCounts[key] ?? 0)
            if value != 0 { delta[key] = value }
        }
        samples.append(Sample(
            index: currentIndex,
            path: path,
            width: Int(width),
            height: Int(height),
            durationsMilliseconds: currentDurations,
            stageEvents: currentStageEvents,
            queryCounts: delta,
            queryCountsByStage: currentQueryCountsByStage,
            mainRunLoopLongestTurnMilliseconds: mainRunLoopLongestTurnMilliseconds
        ))
    }

    func finish() {
        let report: Report
        lock.lock()
        report = Report(
            schemaVersion: 3,
            fixture: fixture,
            measurementMode: "release-optimized-synthetic-root-model-and-layout-markers",
            width: Int(width),
            height: Int(height),
            samples: samples,
            signpostCategory: "interaction-performance",
            inputToPaintMeasurement: "not_claimed; AX and pixel presentation are outside this app marker chain",
            runtimeEnvironment: RuntimeEnvironment(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: Self.architecture,
                syntheticData: true
            ),
            buildIdentity: BuildIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.peiweitang.CodexDirector.InteractionPerformance",
                appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
                configuration: "Release",
                optimization: "release",
                compilationCondition: "DIRECTOR_INTERACTION_PERFORMANCE",
                signature: "ad-hoc"
            ),
            inventory: inventory
        )
        lock.unlock()
        guard let outputURL else { return }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(report)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            // The runner remains useful as an Instruments signpost target even
            // when a caller intentionally omits a report location.
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

@MainActor
private final class InteractionPerformanceRunner {
    private let model: DirectorAppModel
    private let driver: InteractionPerformanceDriver
    private let recorder: InteractionPerformanceRecorder
    private var capturedRequestedStage = false

    init(model: DirectorAppModel, driver: InteractionPerformanceDriver, recorder: InteractionPerformanceRecorder) {
        self.model = model
        self.driver = driver
        self.recorder = recorder
    }

    func runSamples(count: Int) async {
        let boundedCount = min(max(count, 1), 50)
        for index in 0..<boundedCount {
            recorder.beginSample(index: index + 1)
            let path = index == 0 ? "first-entry" : "warm-repeat"
            await measure("sidebar-home") { [self] in self.model.selection = .home }
            for stage in InteractionPerformanceDriver.libraryNavigationStages {
                await measure(stage.name, libraryCategory: stage.category) { [self] in self.model.selection = stage.destination }
            }
            await measure("sidebar-folder") { [self] in self.model.selection = .capabilityFolders }
            await settleView()

            let folderIDs = [CapabilityFolderDefinition.globalID] + model.capabilityFolders.folders.filter(\.isCustom).map(\.id)
            for folderID in folderIDs {
                await measure("folder-entry") { [self] in self.driver.send(.selectFolder(folderID)) }
                for tab in CapabilityFolderTab.allCases {
                    await measure("folder-tab") { [self] in self.driver.send(.selectTab(folderID: folderID, tab: tab)) }
                }
                await measure("folder-sort") { [self] in
                    self.driver.send(.selectSort(folderID: folderID, sort: "thirtyDayUsageDescending"))
                }
                if let resource = model.capabilityFolders.members(in: folderID).first?.id {
                    await measure("detail") { [self] in
                        self.driver.send(.selectDetail(folderID: folderID, resourceID: resource)
                        )
                    }
                    driver.send(.clear)
                }
            }
            if let customFolderID = model.capabilityFolders.folders.first(where: \.isCustom)?.id,
               let resourceID = model.capabilityFolders.members(in: CapabilityFolderDefinition.globalID).first?.id {
                await measure("folder-member-add") { [self] in
                    self.driver.send(.setMembership(folderID: customFolderID, resourceID: resourceID, included: true))
                }
                await measure("folder-member-remove") { [self] in
                    self.driver.send(.setMembership(folderID: customFolderID, resourceID: resourceID, included: false))
                }
            }
            await measure("sidebar-settings") { [self] in self.model.selection = .settings }
            recorder.finishSample(path: path)
        }
    }

    private func measure(_ name: String, libraryCategory: CapabilityCategory? = nil, operation: @escaping @MainActor () -> Void) async {
        InteractionPerformanceProbe.reset()
        let beforeQueries = recorder.querySnapshot()
        let priorCompletions = libraryCategory.map { model.performanceLibraryReloadCompletions[$0, default: 0] }
        let token = recorder.begin(name)
        let mutationStart = DispatchTime.now().uptimeNanoseconds
        operation()
        let mutationDuration = Double(DispatchTime.now().uptimeNanoseconds - mutationStart) / 1_000_000
        let settlementStart = DispatchTime.now().uptimeNanoseconds
        await settleView()
        let settlementDuration = Double(DispatchTime.now().uptimeNanoseconds - settlementStart) / 1_000_000
        var reloadWaitDuration: Double?
        var finalSettlementDuration: Double?
        var reloadCompleted = false
        if let libraryCategory, let priorCompletions {
            let waitStart = DispatchTime.now().uptimeNanoseconds
            reloadCompleted = await waitForLibraryReload(category: libraryCategory, after: priorCompletions)
            reloadWaitDuration = Double(DispatchTime.now().uptimeNanoseconds - waitStart) / 1_000_000
            let finalStart = DispatchTime.now().uptimeNanoseconds
            await settleView()
            finalSettlementDuration = Double(DispatchTime.now().uptimeNanoseconds - finalStart) / 1_000_000
        }
        let afterQueries = recorder.querySnapshot()
        let probe = InteractionPerformanceProbe.take()
        var phases = probe.durations
        phases["selectionMutation"] = mutationDuration
        phases["initialLayoutSettlement"] = settlementDuration
        if let reloadWaitDuration { phases["libraryReloadAwait"] = reloadWaitDuration }
        if let finalSettlementDuration { phases["finalLayoutSettlement"] = finalSettlementDuration }
        var counts = probe.counts
        if let libraryCategory {
            counts["libraryReloadCompleted"] = reloadCompleted ? 1 : 0
            if let status = model.libraryQueryStatus[libraryCategory], case .loaded = status {
                counts["libraryReloadLoaded"] = 1
            } else {
                counts["libraryReloadLoaded"] = 0
            }
        }
        recorder.end(token,
            queryCounts: queryDelta(before: beforeQueries, after: afterQueries),
            phaseDurations: phases,
            phaseCounts: counts)
        await captureSyntheticStageIfRequested(name)
    }

    private func captureSyntheticStageIfRequested(_ name: String) async {
        guard !capturedRequestedStage,
              ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_SCREENSHOT_STAGE"] == name,
              let path = ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_SCREENSHOT_OUTPUT"],
              path.hasPrefix("/tmp/codex-director-interaction-perf/"), path.hasSuffix(".png") else { return }
        guard let content = (NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first)?.contentView else {
            print("interaction_screenshot=no_window")
            return
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("interaction_screenshot=no_bitmap")
            return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            print("interaction_screenshot=no_png")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            capturedRequestedStage = true
            print("interaction_screenshot=saved")
            if let window = content.window,
               let seconds = Int(ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_HOLD_SECONDS"] ?? ""),
               (1...20).contains(seconds) {
                print("interaction_window_id=\(window.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(for: .seconds(seconds))
            }
        } catch {
            // Optional visual evidence must never interrupt the benchmark.
            print("interaction_screenshot=write_failed")
        }
    }

    private func waitForLibraryReload(category: CapabilityCategory, after priorCompletions: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.performanceLibraryReloadCompletions[category, default: 0] <= priorCompletions {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func queryDelta(before: [String: Int], after: [String: Int]) -> [String: Int] {
        Set(before.keys).union(after.keys).reduce(into: [:]) { result, key in
            let value = (after[key] ?? 0) - (before[key] ?? 0)
            if value != 0 { result[key] = value }
        }
    }

    private func settleView() async {
        await Task.yield()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSApp.keyWindow?.displayIfNeeded()
                continuation.resume()
            }
        }
        await Task.yield()
    }
}

private struct InteractionPerformanceWindowReader: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> InteractionPerformanceSizingView {
        InteractionPerformanceSizingView(target: CGSize(width: max(720, width), height: max(480, height)))
    }

    func updateNSView(_ nsView: InteractionPerformanceSizingView, context: Context) {
        nsView.target = CGSize(width: max(720, width), height: max(480, height))
    }
}

private final class InteractionPerformanceSizingView: NSView {
    var target: CGSize {
        didSet { applyTarget() }
    }

    init(target: CGSize) {
        self.target = target
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTarget()
    }

    private func applyTarget() {
        guard let window else { return }
        // NSViewRepresentable can receive its first update before it has a
        // window. Apply the requested viewport after attachment instead.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            let current = window.contentView?.bounds.size ?? .zero
            if abs(current.width - self.target.width) > 1 || abs(current.height - self.target.height) > 1 {
                window.setContentSize(self.target)
            }
            let actual = window.contentView?.bounds.size ?? .zero
            print("interaction_window_content_size=\(Int(actual.width))x\(Int(actual.height))")
        }
    }
}
#endif
