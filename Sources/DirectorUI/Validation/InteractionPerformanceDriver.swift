#if DIRECTOR_INTERACTION_PERFORMANCE
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

    public static let noop = InteractionPerformanceDriver()

    @Published public private(set) var command: Command?
    @Published public private(set) var commandToken = 0

    public init() {}

    public func send(_ command: Command) {
        self.command = command
        commandToken &+= 1
    }
}

/// Diagnostic-only aggregate timings. Keys are a closed enum so capability
/// names, IDs and paths cannot enter the report through this probe.
@MainActor
public enum InteractionPerformanceProbe {
    public enum Phase: String, CaseIterable {
        case identityRead
        case rowProjectionBuild
    }

    public enum Counter: String, CaseIterable {
        case rowViewBuild
        case libraryReloadFailure
    }

    private static var durationByPhase: [Phase: Double] = [:]
    private static var countByPhase: [Phase: Int] = [:]
    private static var countByCounter: [Counter: Int] = [:]

    public static func reset() {
        durationByPhase = [:]
        countByPhase = [:]
        countByCounter = [:]
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
#endif
