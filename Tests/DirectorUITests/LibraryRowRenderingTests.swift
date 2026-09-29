import XCTest
@testable import DirectorUI
import DirectorCore

@MainActor
final class LibraryRowRenderingTests: XCTestCase {
    func testRenderRowsKeepStableIDsAndGroupBoundaries() {
        let rows = [makeRow("a"), makeRow("b"), makeRow("c")]
        let group = CapabilityLibraryGroup(id: "global", title: "Global", rows: rows)
        XCTAssertEqual(group.renderRows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(group.renderRows.map(\.boundary), [.first, .middle, .last])
        XCTAssertEqual(CapabilityLibraryGroup(id: "one", title: "One", rows: [rows[0]]).renderRows.map(\.boundary), [.only])
        XCTAssertTrue(CapabilityLibraryGroup(id: "empty", title: "Empty", rows: []).renderRows.isEmpty)
    }

    func testWarmTextCacheSurvivesSelectionSearchAndSevenDaySortChanges() {
        let row = makeRow("a")
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: [row.entry])
        let first = model.rowText(for: row, language: .english)
        for _ in 0..<30 {
            model.selectedID = "a"
            model.context = CapabilityBrowseContext(search: "a", sort: .nameAscending)
            XCTAssertEqual(model.rowText(for: row, language: .english), first)
        }
        #if DEBUG
        XCTAssertEqual(model.rowTextBuildCount, 1)
        #endif
        XCTAssertEqual(first.countValue, "2")
        XCTAssertEqual(first.accessibilityLabel, "a, 2 calls")
        XCTAssertEqual(first.summary, "Synthetic purpose")
    }

    func testTextInvalidatesForLanguagePeriodDataAndTimeZone() {
        let row = makeRow("a")
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: [row.entry])
        let english = model.rowText(for: row, language: .english, timeZone: TimeZone(secondsFromGMT: 0)!)
        let chinese = model.rowText(for: row, language: .simplifiedChinese, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNotEqual(english.metadata, chinese.metadata)
        model.context = CapabilityBrowseContext(sort: .thirtyDayUsageDescending)
        let thirty = model.rowText(for: row, language: .english, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(thirty.countValue, "12")
        XCTAssertNotEqual(english.countLabel, thirty.countLabel)
        let changedTimeZone = model.rowText(for: row, language: .english, timeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertNotEqual(thirty.metadata, changedTimeZone.metadata)
        model.setDirectory(catalog: [row.entry], projects: [])
        XCTAssertEqual(model.rowText(for: row, language: .english, timeZone: TimeZone(secondsFromGMT: 3600)!), changedTimeZone)
        #if DEBUG
        XCTAssertEqual(model.rowTextBuildCount, 5)
        #endif
    }

    func testUnknownExplicitZeroAndChangedCountsRemainDistinct() {
        let unknown = makeRow("a", seven: nil, thirty: nil)
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: [unknown.entry])
        XCTAssertEqual(model.rowText(for: unknown, language: .english).countValue, "—")
        let zero = makeRow("a", seven: 0, thirty: 0)
        XCTAssertEqual(model.rowText(for: zero, language: .english).countValue, "0")
        let updated = makeRow("a", seven: 3, thirty: 15)
        XCTAssertEqual(model.rowText(for: updated, language: .english).countValue, "3")
        model.context = CapabilityBrowseContext(sort: .thirtyDayUsageDescending)
        XCTAssertEqual(model.rowText(for: updated, language: .english).countValue, "15")
    }

    func testPluginUnavailableAndReadyTransitionInvalidateText() {
        let row = makeRow("plugin", seven: nil, thirty: nil)
        let model = CapabilityLibraryViewModel(category: .installedPlugins, catalog: [row.entry])
        XCTAssertEqual(model.rowText(for: row, language: .english).countValue, "—")
        model.setPluginData([])
        XCTAssertEqual(model.rowText(for: row, language: .english).countValue, "Unavailable")
        model.context = CapabilityBrowseContext(sort: .thirtyDayUsageDescending)
        XCTAssertEqual(model.rowText(for: row, language: .english).countValue, "—")
        model.setPluginData([], category30DayStats: [])
        XCTAssertEqual(model.rowText(for: row, language: .english).countValue, "—")
        model.setPluginData([], category30DayStats: [], browse30DayStats: [])
        XCTAssertEqual(model.rowText(for: row, language: .english).countValue, "Unavailable")
    }

    func testRefreshDoesNotReuseOldNameOrPurpose() {
        let row = makeRow("a")
        let model = CapabilityLibraryViewModel(category: .customAgents, catalog: [row.entry])
        let first = model.rowText(for: row, language: .english)
        let resource = CapabilityResource(id: "a", name: "Synthetic renamed capability", kind: .agent, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Synthetic changed purpose", sourceRootID: "synthetic", relativeSourcePath: "a", sourcePathHash: nil, lastSeenAt: row.entry.resource.lastSeenAt, ownership: .userOwned, origin: .local, sourceModifiedAt: row.sourceModifiedAt)
        let entry = CapabilityCatalogEntry(resource: resource, category: .customAgents, parentPluginID: nil)
        let changed = CapabilityLibraryRow(entry: entry, recent7Count: 2, inferredCount: 0, lastUsedAt: row.lastUsedAt, sourceModifiedAt: row.sourceModifiedAt, recent30Count: 12)
        model.setDirectory(catalog: [entry], projects: [])
        let updated = model.rowText(for: changed, language: .english)
        XCTAssertNotEqual(updated, first)
        XCTAssertEqual(updated.summary, resource.summary)
        XCTAssertEqual(updated.accessibilityLabel, "Synthetic renamed capability, 2 calls")
    }

    private func makeRow(_ id: String, seven: Int? = 2, thirty: Int? = 12) -> CapabilityLibraryRow {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let resource = CapabilityResource(id: id, name: id, kind: .agent, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: "Synthetic purpose", sourceRootID: "synthetic", relativeSourcePath: id, sourcePathHash: nil, lastSeenAt: date, ownership: .userOwned, origin: .local, sourceModifiedAt: date)
        return CapabilityLibraryRow(entry: .init(resource: resource, category: .customAgents, parentPluginID: nil), recent7Count: seven, inferredCount: 0, lastUsedAt: date, sourceModifiedAt: date, recent30Count: thirty)
    }

    func testListConsumesStableRenderRowsWithoutPerBodyEnumeration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("ForEach(Array(group.rows.enumerated())"))
        XCTAssertTrue(source.contains("ForEach(group.renderRows)"))
    }
}
