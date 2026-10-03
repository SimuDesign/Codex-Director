import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class CapabilityFolderUsageTests: XCTestCase {
    private final class QueryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func record() { lock.lock(); defer { lock.unlock() }; total += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return total }
    }

    func testLoadedPeriodsStayCachedAcrossSwitchesAndKeepSharedSkillSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("director-folder-counts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = QueryCounter()
        let database = try DatabaseStore(url: root.appendingPathComponent("derived.sqlite"), queryObserver: { _ in probe.record() })
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let resources = [resource("a", kind: .agent, now: now), resource("b", kind: .agent, now: now), resource("shared", kind: .skill, now: now)]
        try await database.replaceResourceInventory(resources: resources, relations: [
            .init(sourceResourceID: "a", targetResourceID: "shared", relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue),
            .init(sourceResourceID: "b", targetResourceID: "shared", relationKind: CapabilityCompanionRelationKind.companionSkill.rawValue, confidence: .exact, evidenceSummary: CapabilityCompanionDeclarationSource.agentBrief.rawValue)
        ])
        for (sessionID, timestamp, counts) in [("recent", now, ["a": 2, "b": 4, "shared": 3]), ("older", now.addingTimeInterval(-15 * 86400), ["a": 5])] {
            var calls: [InvocationEvent] = []
            for id in counts.keys.sorted() {
                for index in 0..<(counts[id] ?? 0) {
                    calls.append(.init(id: "\(sessionID)-\(id)-\(index)", sessionID: sessionID, parentCallID: nil, ordinal: calls.count, timestamp: timestamp, actorName: nil, resourceID: id, kind: id == "shared" ? .skill : .agent, status: .completed, durationMs: nil, confidence: .exact, errorCategory: nil))
                }
            }
            try await database.replaceSession(.init(session: .init(id: sessionID, projectID: "usage-project", startedAt: timestamp, endedAt: timestamp, status: .completed, coverage: .complete, parserVersion: "synthetic", sourceFileID: sessionID, title: nil), calls: calls, tokenSnapshots: [], quotaSnapshots: [], findings: []))
        }
        let stores = TestMemoryPreferences.makeStores()
        let model = DirectorAppModel(store: database, classificationOverrides: stores.0, evaluationStore: stores.1, nowProvider: { now }, previewMode: false)
        defer { model.stopSourceDataMonitor() }
        XCTAssertNil(model.capabilityFolderUsageCount(for: "a", thirtyDays: false))
        try await model.refresh()
        await model.loadCapabilityFolderUsageIfNeeded()
        let queryCount = probe.count
        let periods = model.folderUsagePeriods
        let folders = model.capabilityFolders
        XCTAssertEqual(model.capabilityFolderUsageCount(for: "a", thirtyDays: false), 2)
        XCTAssertEqual(model.capabilityFolderUsageCount(for: "a", thirtyDays: true), 7)
        XCTAssertEqual(model.capabilityFolderUsageCount(for: "b", thirtyDays: true), 4)
        XCTAssertEqual(model.capabilityFolderUsageCount(for: "shared", thirtyDays: true), 3)
        for _ in 0..<20 {
            model.setCapabilityFolderUsagePeriod(.thirtyDays)
            XCTAssertTrue(CapabilityFolderUsageDisplay.compareCounts(model.capabilityFolderUsageCount(for: "a", thirtyDays: true), model.capabilityFolderUsageCount(for: "b", thirtyDays: true), ascending: false) == true)
            model.setCapabilityFolderUsagePeriod(.sevenDays)
            XCTAssertTrue(CapabilityFolderUsageDisplay.compareCounts(model.capabilityFolderUsageCount(for: "a", thirtyDays: false), model.capabilityFolderUsageCount(for: "b", thirtyDays: false), ascending: false) == false)
        }
        await model.loadCapabilityFolderUsageIfNeeded()
        XCTAssertEqual(probe.count, queryCount)
        XCTAssertEqual(model.folderUsagePeriods, periods)
        XCTAssertEqual(model.capabilityFolders, folders)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNil(model.accountUsageSnapshot)
    }
    func testSharedPeriodSynchronizesModelsWithoutChangingHomeOrMembers() {
        let preference = CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)
        let first = makeModel(preference)
        let second = makeModel(preference)
        let members = first.capabilityFolders
        first.setCapabilityFolderUsagePeriod(.thirtyDays)
        XCTAssertEqual(first.capabilityFolderUsagePeriod, .thirtyDays)
        XCTAssertEqual(second.capabilityFolderUsagePeriod, .thirtyDays)
        XCTAssertEqual(first.homeUsageRankingPeriod, .sevenDays)
        XCTAssertEqual(first.capabilityFolders, members)
        XCTAssertFalse(first.isRefreshing)
        XCTAssertNil(first.accountUsageSnapshot)
        XCTAssertNil(first.folderUsagePeriods)
    }

    func testPendingAndObservedZeroRemainDistinct() {
        let pending = CapabilityFolderUsageDisplay(count: nil, stats: nil, period: .sevenDays, language: .simplifiedChinese)
        let zero = CapabilityFolderUsageDisplay(count: 0, stats: nil, period: .thirtyDays, language: .simplifiedChinese)
        XCTAssertEqual(pending.value, "—")
        XCTAssertEqual(zero.value, "0")
        XCTAssertTrue(pending.accessibilityText.contains("尚未就绪"))
        XCTAssertTrue(zero.accessibilityText.contains("近 30 天"))
        XCTAssertFalse(zero.accessibilityText.contains("未使用"))
        XCTAssertTrue(zero.help.contains("不代表"))
    }

    func testPartialInferredEvidenceIsNotSuccessfulExecution() {
        let stats = CapabilityUsageStats(resourceID: "skill", callCount: 12, inferredCount: 4, lastUsedAt: nil, coverage: .partial)
        let display = CapabilityFolderUsageDisplay(count: 12, stats: stats, period: .thirtyDays, language: .english)
        XCTAssertEqual(display.value, "12")
        XCTAssertTrue(display.accessibilityText.contains("Last 30 days"))
        XCTAssertTrue(display.help.contains("inferred"))
        XCTAssertTrue(display.help.contains("partial"))
        XCTAssertTrue(display.help.contains("All usage projects"))
        XCTAssertFalse(display.accessibilityText.contains("successful"))
    }

    func testUsageSortingUsesPeriodAndPlacesUnknownAfterObservedZero() {
        XCTAssertEqual(CapabilityFolderUsageDisplay.compareCounts(2, 8, ascending: false), false)
        XCTAssertEqual(CapabilityFolderUsageDisplay.compareCounts(9, 8, ascending: false), true)
        XCTAssertEqual(CapabilityFolderUsageDisplay.compareCounts(0, nil, ascending: true), true)
        XCTAssertEqual(CapabilityFolderUsageDisplay.compareCounts(nil, 0, ascending: false), false)
        XCTAssertNil(CapabilityFolderUsageDisplay.compareCounts(4, 4, ascending: true))
    }

    func testThreeTabsReuseCountsAndCompanionSkillIsNotAddedToAgent() throws {
        let source = try readSource("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift")
        XCTAssertTrue(source.contains("let display = usageDisplay(for: member.id)"))
        XCTAssertTrue(source.contains("let display = usageDisplay(for: item.resource.id)"))
        XCTAssertTrue(source.contains("model.capabilityFolderUsagePeriod"))
        XCTAssertTrue(source.contains("capabilityFolders.usage.allProjects"))
        XCTAssertFalse(source.contains("case .thirtyDayUsageDescending"))
        XCTAssertFalse(source.contains("private func recentUsageText"))
        XCTAssertTrue(source.contains("DirectorTypography.capabilityRowCount"))
    }

    func testLocalizationAndProductionInjectionArePresent() throws {
        for path in ["Sources/DirectorUI/Resources/en.lproj/Localizable.strings", "Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings"] {
            let source = try readSource(path)
            for key in ["capabilityFolders.usage.period", "capabilityFolders.usage.sevenDays", "capabilityFolders.usage.thirtyDays", "capabilityFolders.usage.allProjects", "capabilityFolders.usage.recorded", "capabilityFolders.usage.pending", "capabilityFolders.usage.help"] {
                XCTAssertTrue(source.contains("\"\(key)\""), key)
            }
        }
        let app = try readSource("Sources/CodexDirectorApp/CodexDirectorApp.swift")
        XCTAssertTrue(app.contains("CapabilityFolderUsagePreferences(defaults: .standard)"))
        XCTAssertTrue(app.contains("CapabilityFolderUsagePreferences(memoryPeriod: .sevenDays)"))
    }

    private func makeModel(_ preference: CapabilityFolderUsagePreferences) -> DirectorAppModel {
        let stores = TestMemoryPreferences.makeStores()
        return DirectorAppModel(classificationOverrides: stores.0, evaluationStore: stores.1, previewMode: false, capabilityFolderUsagePreferences: preference)
    }

    private func readSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func resource(_ id: String, kind: ResourceKind, now: Date) -> CapabilityResource {
        .init(id: id, name: id, kind: kind, status: .success, scope: .global, projectID: nil, confidence: .exact, summary: "Synthetic capability", sourceRootID: "synthetic", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: now, ownership: .userOwned, origin: .local)
    }
}
