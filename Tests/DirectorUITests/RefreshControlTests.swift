import XCTest
import SwiftUI
@testable import DirectorUI

@MainActor
final class RefreshControlTests: XCTestCase {
    func testRefreshBusyStateCoversOnlyActiveWork() {
        XCTAssertTrue(DirectorAppModel.refreshIsActive(isIndexing: true, phase: .idle))
        XCTAssertTrue(DirectorAppModel.refreshIsActive(isIndexing: false, phase: .source))
        XCTAssertTrue(DirectorAppModel.refreshIsActive(isIndexing: false, phase: .projection))

        for phase in [RefreshPhase.idle, .startupGrace, .waiting, .failed] {
            XCTAssertFalse(DirectorAppModel.refreshIsActive(isIndexing: false, phase: phase))
        }
        XCTAssertFalse(DirectorAppModel.refreshIsActive(isIndexing: false, phase: nil))
    }

    func testRefreshButtonSupportsStandardAndToolbarSizes() {
        _ = DirectorRefreshButton(
            label: "Refresh data",
            runningLabel: "Refreshing…",
            hint: "Refresh capabilities, quota and recent usage data.",
            isRefreshing: false,
            isAvailable: true,
            size: .toolbar,
            action: {}
        )
        _ = DirectorRefreshButton(
            label: "Update now",
            runningLabel: "Refreshing…",
            hint: "Refresh capabilities, quota and recent usage data.",
            isRefreshing: true,
            isAvailable: true,
            action: {}
        )
    }

    func testRootAndSettingsUseTheSharedLabeledRefreshControl() throws {
        let root = try source("Sources/DirectorUI/AppShell/DirectorRootView.swift")
        let settings = try source("Sources/DirectorUI/DataStatus/SettingsView.swift")
        let control = try source("Sources/DirectorUI/Components/DirectorRefreshButton.swift")

        XCTAssertTrue(root.contains("DirectorRefreshButton("))
        XCTAssertTrue(root.contains("size: .toolbar"))
        XCTAssertFalse(root.contains("Image(systemName: \"arrow.clockwise\")"))
        XCTAssertTrue(settings.contains("DirectorRefreshButton("))
        XCTAssertTrue(settings.contains("label: t(\"settings.updateNow\""))
        XCTAssertTrue(control.contains("Label(label, systemImage: \"arrow.clockwise\")"))
        XCTAssertTrue(control.contains(".labelStyle(.titleAndIcon)"))
        XCTAssertTrue(control.contains("ProgressView()"))
        XCTAssertTrue(control.contains("ZStack"))
        XCTAssertTrue(control.contains(".disabled(isRefreshing || !isAvailable)"))
        XCTAssertTrue(control.contains("isProcessing: isRefreshing"))
        XCTAssertFalse(control.contains(".accessibilityElement(children: .ignore)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
