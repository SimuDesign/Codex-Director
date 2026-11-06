#if DIRECTOR_INTERACTION_PERFORMANCE
import AppKit
import Foundation
import SwiftUI
import DirectorCore

/// Test-only control surface for the optimized synthetic interaction harness.
/// It carries only stable synthetic IDs and enum values; no source paths,
/// capability text, sessions, or account data enter the performance trace.
@MainActor
public final class InteractionPerformanceDriver: ObservableObject {
    public struct LibraryNavigationStage: Equatable {
        public let destination: DirectorSidebarItem
        public let category: CapabilityCategory
        public let name: String
    }

    public static let libraryNavigationStages: [LibraryNavigationStage] = [
        .init(destination: .customAgents, category: .customAgents, name: "sidebar-custom-agents"),
        .init(destination: .customSkills, category: .customSkills, name: "sidebar-custom-skills"),
        .init(destination: .installedSkills, category: .installedSkills, name: "sidebar-installed-skills"),
        .init(destination: .installedPlugins, category: .installedPlugins, name: "sidebar-installed-plugins")
    ]

    public enum Command: Equatable, Sendable {
        case selectFolder(String)
        case selectTab(folderID: String, tab: CapabilityFolderTab)
        case selectSort(folderID: String, sort: String)
        case selectDetail(folderID: String, resourceID: String)
        case setMembership(folderID: String, resourceID: String, included: Bool)
        case clear
    }

    public enum QuotaHistoryCommand: Equatable, Sendable {
        case open
        case setPeriod(QuotaHistoryPeriod)
        case close
    }

    public static let noop = InteractionPerformanceDriver()

    @Published public private(set) var command: Command?
    @Published public private(set) var commandToken = 0
    @Published public private(set) var quotaHistoryCommand: QuotaHistoryCommand?
    @Published public private(set) var quotaHistoryCommandToken = 0
    @Published public private(set) var quotaHistoryDismissalToken = 0

    public init() {}

    public func send(_ command: Command) {
        self.command = command
        commandToken &+= 1
    }

    public func sendQuotaHistory(_ command: QuotaHistoryCommand) {
        quotaHistoryCommand = command
        quotaHistoryCommandToken &+= 1
    }

    /// Diagnostic-only acknowledgement emitted when the quota-history page
    /// session deactivates. The runner uses the generation token instead of
    /// guessing with a fixed sleep.
    public func acknowledgeQuotaHistoryDismissed() {
        quotaHistoryDismissalToken &+= 1
    }
}

/// Diagnostic-only aggregate timings. Keys are a closed enum so capability
/// names, IDs and paths cannot enter the report through this probe.
@MainActor
public enum InteractionPerformanceProbe {
    public enum Phase: String, CaseIterable {
        case identityRead
        case rowProjectionBuild
        case sidebarDraw
        case destinationDraw
    }

    public enum Counter: String, CaseIterable {
        case rowViewBuild
        case libraryReloadFailure
    }

    private static var durationByPhase: [Phase: Double] = [:]
    private static var countByPhase: [Phase: Int] = [:]
    private static var countByCounter: [Counter: Int] = [:]

    private static var navigationEventID: UInt64 = 0
    private static var navigation: (destination: DirectorSidebarItem, start: UInt64)?
    private static var nativeInputKind: String?
    private static let measuresNativeInput =
        ProcessInfo.processInfo.environment["CODEX_DIRECTOR_INTERACTION_MANUAL_REVIEW"] == "1"

    public static var hasNavigationDraws: Bool {
        durationByPhase[.sidebarDraw] != nil && durationByPhase[.destinationDraw] != nil
    }

    public static func beginNavigation(to destination: DirectorSidebarItem, at start: UInt64) {
        navigationEventID &+= 1
        navigation = (destination, start)
    }

    public static func beginNativeNavigation(to destination: DirectorSidebarItem) {
        guard measuresNativeInput else { return }
        reset()
        guard let event = NSApp.currentEvent, event.window?.isKeyWindow == true else { return }
        let kind: String
        switch event.type {
        case .leftMouseDown, .leftMouseUp: kind = "pointer"
        case .keyDown: kind = "keyboard"
        default: return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - event.timestamp
        let uptime = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = elapsed * 1_000_000_000
        // Keep slow inputs in the distribution. Only reject an invalid
        // timestamp or one that cannot be represented on this clock.
        guard elapsedNanoseconds.isFinite, elapsedNanoseconds >= 0,
              elapsedNanoseconds < Double(uptime) else { return }
        beginNavigation(to: destination, at: uptime - UInt64(elapsedNanoseconds))
        nativeInputKind = kind
    }

    public static func navigationID(for destination: DirectorSidebarItem) -> UInt64? {
        navigation?.destination == destination ? navigationEventID : nil
    }

    fileprivate static func markNavigationDraw(_ phase: Phase, eventID: UInt64) {
        guard eventID == navigationEventID, let navigation,
              durationByPhase[phase] == nil else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - navigation.start
        durationByPhase[phase] = Double(elapsed) / 1_000_000
        if let nativeInputKind, let sidebar = durationByPhase[.sidebarDraw],
           let content = durationByPhase[.destinationDraw] {
            print("native_navigation input=\(nativeInputKind) destination=\(navigation.destination.rawValue) sidebar_ms=\(sidebar) content_ms=\(content)")
            fflush(stdout)
        }
    }

    public static func reset() {
        durationByPhase = [:]
        countByPhase = [:]
        countByCounter = [:]
        navigation = nil
        nativeInputKind = nil
    }

    public static func record(_ phase: Phase, since startNanoseconds: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanoseconds
        durationByPhase[phase, default: 0] += Double(elapsed) / 1_000_000
        countByPhase[phase, default: 0] += 1
    }

    public static func increment(_ counter: Counter) {
        countByCounter[counter, default: 0] += 1
    }

    public static func take() -> (durations: [String: Double], counts: [String: Int]) {
        let durations = Dictionary(uniqueKeysWithValues: durationByPhase.map { ($0.key.rawValue, $0.value) })
        var counts = Dictionary(uniqueKeysWithValues: countByPhase.map { ($0.key.rawValue, $0.value) })
        for (counter, value) in countByCounter { counts[counter.rawValue] = value }
        reset()
        return (durations, counts)
    }
}

/// A bounded, diagnostic-only event-to-first-correct-paint probe for the
/// quota-history page. The marker is completed by an AppKit draw callback in
/// the visible page, rather than by view-model work or a CUA round trip.
@MainActor
public final class QuotaHistoryPerformanceProbe {
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case entry = "quota-history-entry"
        case sevenDays = "quota-history-period-7d"
        case thirtyDays = "quota-history-period-30d"
        case sixtyDays = "quota-history-period-60d"
    }

    private struct Pending {
        let eventID: UInt64
        let stage: Stage
        let startedAt: UInt64
        let expectedPeriod: QuotaHistoryPeriod
        var acceptedAt: UInt64?
    }

    public struct Measurements: Sendable {
        public let commandAccepted: Bool
        public let eventToFeedbackMilliseconds: Double?
        public let acceptedToFeedbackMilliseconds: Double?
        public let eventToFirstCorrectPaintMilliseconds: Double?
        public let acceptedToFirstCorrectPaintMilliseconds: Double?

        fileprivate init(
            commandAccepted: Bool,
            eventToFeedbackMilliseconds: Double?,
            acceptedToFeedbackMilliseconds: Double?,
            eventToFirstCorrectPaintMilliseconds: Double?,
            acceptedToFirstCorrectPaintMilliseconds: Double?
        ) {
            self.commandAccepted = commandAccepted
            self.eventToFeedbackMilliseconds = eventToFeedbackMilliseconds
            self.acceptedToFeedbackMilliseconds = acceptedToFeedbackMilliseconds
            self.eventToFirstCorrectPaintMilliseconds = eventToFirstCorrectPaintMilliseconds
            self.acceptedToFirstCorrectPaintMilliseconds = acceptedToFirstCorrectPaintMilliseconds
        }
    }

    private static var nextEventID: UInt64 = 0
    private static var pending: Pending?
    private static var feedbackMilliseconds: Double?
    private static var acceptedToFeedbackMilliseconds: Double?
    private static var contentMilliseconds: Double?
    private static var acceptedToContentMilliseconds: Double?

    public static var currentEventID: UInt64? { pending?.eventID }
    public static var expectedPeriod: QuotaHistoryPeriod? { pending?.expectedPeriod }
    public static var isAwaitingEntryFeedback: Bool {
        pending?.stage == .entry && feedbackMilliseconds == nil
    }

    @discardableResult
    public static func begin(_ stage: Stage) -> UInt64 {
        let expectedPeriod: QuotaHistoryPeriod
        switch stage {
        case .entry, .thirtyDays: expectedPeriod = .thirtyDays
        case .sevenDays: expectedPeriod = .sevenDays
        case .sixtyDays: expectedPeriod = .sixtyDays
        }
        nextEventID &+= 1
        let eventID = nextEventID
        pending = Pending(
            eventID: eventID,
            stage: stage,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            expectedPeriod: expectedPeriod,
            acceptedAt: nil
        )
        feedbackMilliseconds = nil
        acceptedToFeedbackMilliseconds = nil
        contentMilliseconds = nil
        acceptedToContentMilliseconds = nil
        return eventID
    }

    /// Returns true only when the current page state is the event's target
    /// period and contains the bounded history snapshot used by the page.
    public static func isCorrect(period: QuotaHistoryPeriod, isOpen: Bool, hasSnapshot: Bool) -> Bool {
        guard let pending else { return false }
        return isOpen && hasSnapshot && period == pending.expectedPeriod
    }

    /// Called from the visible marker's AppKit draw callback. It is idempotent
    /// per event so later redraws cannot shorten the measured interval.
    public static func markCommandAccepted() {
        guard var pending, pending.acceptedAt == nil else { return }
        pending.acceptedAt = DispatchTime.now().uptimeNanoseconds
        self.pending = pending
    }

    /// Called from the visible marker's AppKit draw callback. The event ID
    /// prevents a delayed draw from an older sheet presentation claiming a
    /// later command.
    public static func markEntryFeedbackPaint(eventID: UInt64) {
        guard let pending,
              pending.eventID == eventID,
              pending.stage == .entry,
              feedbackMilliseconds == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - pending.startedAt
        feedbackMilliseconds = Double(elapsed) / 1_000_000
        if let acceptedAt = pending.acceptedAt {
            acceptedToFeedbackMilliseconds = Double(now - acceptedAt) / 1_000_000
        }
    }

    public static func markCorrectPaint(eventID: UInt64) {
        guard let pending,
              pending.eventID == eventID,
              contentMilliseconds == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - pending.startedAt
        contentMilliseconds = Double(elapsed) / 1_000_000
        if let acceptedAt = pending.acceptedAt {
            acceptedToContentMilliseconds = Double(now - acceptedAt) / 1_000_000
        }
    }

    public static func takeMeasurements() -> Measurements {
        let result = Measurements(
            commandAccepted: pending?.acceptedAt != nil,
            eventToFeedbackMilliseconds: feedbackMilliseconds,
            acceptedToFeedbackMilliseconds: acceptedToFeedbackMilliseconds,
            eventToFirstCorrectPaintMilliseconds: contentMilliseconds,
            acceptedToFirstCorrectPaintMilliseconds: acceptedToContentMilliseconds
        )
        pending = nil
        feedbackMilliseconds = nil
        acceptedToFeedbackMilliseconds = nil
        contentMilliseconds = nil
        acceptedToContentMilliseconds = nil
        return result
    }

    public static func waitForEntryFeedback(timeoutMilliseconds: UInt64 = 2_000) async -> Double? {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMilliseconds * 1_000_000
        while feedbackMilliseconds == nil, DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return feedbackMilliseconds
    }

    public static func waitForCorrectPaint(timeoutMilliseconds: UInt64 = 2_000) async -> Double? {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMilliseconds * 1_000_000
        while contentMilliseconds == nil, DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return contentMilliseconds
    }
}

/// Zero-sized work-free marker whose draw callback represents a real AppKit
/// paint of the quota-history page subtree. It carries no user content or
/// persistent state.
public struct QuotaHistoryFirstPaintMarker: NSViewRepresentable {
    public enum Kind: Sendable {
        case entryFeedback
        case pageContent
    }

    public let kind: Kind
    public let isCorrect: Bool
    public let eventID: UInt64?
    private let navigationPhase: InteractionPerformanceProbe.Phase?

    public init(kind: Kind, isCorrect: Bool, eventID: UInt64? = nil) {
        self.kind = kind
        self.isCorrect = isCorrect
        self.eventID = eventID
        navigationPhase = nil
    }

    private init(navigationPhase: InteractionPerformanceProbe.Phase, eventID: UInt64?) {
        kind = .pageContent
        isCorrect = eventID != nil
        self.eventID = eventID
        self.navigationPhase = navigationPhase
    }

    public static func navigation(_ phase: InteractionPerformanceProbe.Phase, destination: DirectorSidebarItem) -> some View {
        Self(navigationPhase: phase, eventID: InteractionPerformanceProbe.navigationID(for: destination))
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    public func makeNSView(context: Context) -> MarkerView {
        MarkerView()
    }

    public func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.kind = kind
        nsView.isCorrect = isCorrect
        nsView.eventID = eventID
        nsView.navigationPhase = navigationPhase
        nsView.needsDisplay = true
    }

    public final class MarkerView: NSView {
        var kind: Kind = .pageContent
        var isCorrect = false
        var eventID: UInt64?
        var navigationPhase: InteractionPerformanceProbe.Phase?

        public override var isOpaque: Bool { false }

        public override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // A SwiftUI/AppKit view can receive a draw while its window is
            // hidden, occluded, or attached to a non-visible presentation
            // surface. Only count a paint when the marker is in the visible
            // synthetic Host window; this keeps the probe about actual user
            // feedback rather than an off-screen layout pass.
            guard isCorrect,
                  let eventID,
                  let window,
                  window.isVisible,
                  window.occlusionState.contains(.visible),
                  !isHiddenOrHasHiddenAncestor,
                  !visibleRect.isEmpty else { return }
            if let navigationPhase {
                InteractionPerformanceProbe.markNavigationDraw(navigationPhase, eventID: eventID)
                return
            }
            guard eventID == QuotaHistoryPerformanceProbe.currentEventID else { return }
            switch kind {
            case .entryFeedback:
                QuotaHistoryPerformanceProbe.markEntryFeedbackPaint(eventID: eventID)
            case .pageContent:
                QuotaHistoryPerformanceProbe.markCorrectPaint(eventID: eventID)
            }
        }
    }
}
#endif
