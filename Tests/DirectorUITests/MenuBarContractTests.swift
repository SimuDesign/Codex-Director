import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class MenuBarContractTests: XCTestCase {
    func testMenuBarViewUsesFixedPrivacySafeOrderAndSharedRefreshControl() throws {
        let root = projectRoot()
        let viewSource = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/MenuBar/DirectorMenuBarView.swift"), encoding: .utf8)
        let refreshSource = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Components/DirectorRefreshButton.swift"), encoding: .utf8)
        let appSource = try String(contentsOf: root.appendingPathComponent("Sources/CodexDirectorApp/CodexDirectorApp.swift"), encoding: .utf8)

        let order = [
            "menuBar.weeklyRemaining",
            "menuBar.nextReset",
            "menuBar.resetCredits",
            "menuBar.refresh",
            "menuBar.openMainWindow",
        ].compactMap { viewSource.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 5)
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(viewSource.contains("DirectorRefreshButton("))
        XCTAssertTrue(viewSource.contains("menuBar.refresh.running"))
        XCTAssertTrue(viewSource.contains("presentation.usesCachedValue"))
        XCTAssertTrue(viewSource.contains("public struct DirectorMenuBarLabel"))
        XCTAssertTrue(refreshSource.contains("ProgressView"))
        XCTAssertTrue(appSource.contains("MenuBarExtra(isInserted: menuBarBinding)"))
        XCTAssertTrue(appSource.contains(".menuBarExtraStyle(.window)"))
        XCTAssertTrue(viewSource.contains("DirectorSymbol.menuBarUsage"))
    }

    func testMenuBarSourceContainsNoProviderModelOrAccountIdentitySurface() throws {
        let root = projectRoot()
        let files = [
            root.appendingPathComponent("Sources/DirectorUI/MenuBar/DirectorMenuBarView.swift"),
            root.appendingPathComponent("Sources/CodexDirectorApp/CodexDirectorApp.swift"),
            root.appendingPathComponent("Sources/DirectorCore/MenuBar/CodexAccountUsageReading.swift"),
            root.appendingPathComponent("Sources/DirectorCore/MenuBar/MenuBarPresentation.swift"),
        ]
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n").lowercased()

        for forbidden in ["sourcename", "sourceid", "gpt-5.3", "accountid", "account_id", "token", "cookie"] {
            XCTAssertFalse(source.contains(forbidden), "menu bar contract leaked \(forbidden)")
        }
        XCTAssertFalse(source.contains("selectedquotasource"))
    }

    func testSettingsExposesDefaultOnMenuBarSwitchAndLiveSceneBinding() throws {
        let root = projectRoot()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"), encoding: .utf8)
        let preferences = try String(contentsOf: root.appendingPathComponent("Sources/DirectorCore/MenuBar/MenuBarPreferences.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Sources/CodexDirectorApp/CodexDirectorApp.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("settings.menuBar"))
        XCTAssertTrue(settings.contains("model.setMenuBarEnabled($0)"))
        XCTAssertTrue(settings.contains(".toggleStyle(.switch)"))
        XCTAssertFalse(settings.contains("launch at login"))
        XCTAssertTrue(preferences.contains("as? Bool ?? true"))
        XCTAssertTrue(preferences.contains("public init(memoryEnabled: Bool = true)"))
        XCTAssertTrue(preferences.contains("ObservableObject"))
        XCTAssertTrue(app.contains("@StateObject private var menuBarPreferences: MenuBarPreferences"))
        XCTAssertTrue(app.contains("MenuBarInsertionBinding.make(preferences: menuBarPreferences, model: launchState.model)"))
        let insertion = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/MenuBar/MenuBarInsertionBinding.swift"), encoding: .utf8)
        XCTAssertTrue(insertion.contains("_ = preferences.isEnabled"))
        XCTAssertTrue(insertion.contains("get: { preferences.isEnabled }"))
    }

    func testMenuBarLocalizationsMatchAndUsePrivacySafeLabels() throws {
        let root = projectRoot()
        let english = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        let chinese = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        let required = [
            "menuBar.weeklyRemaining", "menuBar.nextReset", "menuBar.resetCredits",
            "menuBar.refresh", "menuBar.refresh.running", "menuBar.openMainWindow", "menuBar.unavailable",
            "menuBar.cached", "menuBar.unavailableStatus",
        ]
        for key in required {
            XCTAssertTrue(english.contains("\"\(key)\""))
            XCTAssertTrue(chinese.contains("\"\(key)\""))
        }
        XCTAssertFalse(english.localizedCaseInsensitiveContains("gpt-5.3"))
        XCTAssertFalse(chinese.localizedCaseInsensitiveContains("gpt-5.3"))
    }

    func testUnavailableFailureCopyIsDistinctFromCachedCopyInBothLanguages() {
        let english = DirectorLocalizer(language: .english)
        XCTAssertEqual(english.text("menuBar.cached", fallback: "cached"), "Showing cached data")
        XCTAssertEqual(english.text("menuBar.unavailableStatus", fallback: "unavailable"), "Account data is unavailable")

        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        XCTAssertEqual(chinese.text("menuBar.cached", fallback: "cached"), "正在显示缓存数据")
        XCTAssertEqual(chinese.text("menuBar.unavailableStatus", fallback: "unavailable"), "账户数据不可用")
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
