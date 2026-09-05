import XCTest
import SwiftUI
@testable import DirectorUI

@MainActor
final class AppThemeTests: XCTestCase {
    func testThemeDefaultsToDarkAndInvalidValueFallsBackToDark() {
        XCTAssertEqual(AppTheme.resolve(nil), .dark)
        XCTAssertEqual(AppTheme.resolve("invalid"), .dark)
        XCTAssertEqual(AppThemeStore(memoryTheme: .dark).theme, .dark)
    }

    func testThemeMapsToTheRequestedSwiftUIColorScheme() {
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    func testInjectedThemeStorePersistsWithoutConsultingUserDefaults() {
        var stored: String?
        let store = AppThemeStore(readPreference: { stored }, writePreference: { stored = $0 })

        XCTAssertEqual(store.theme, .dark)
        store.setTheme(.light)

        XCTAssertEqual(store.theme, .light)
        XCTAssertEqual(stored, AppTheme.light.rawValue)
        XCTAssertEqual(AppThemeStore(readPreference: { stored }, writePreference: { _ in }).theme, .light)
    }

    func testProductionConstructorUsesOnlyDedicatedThemePreferenceKey() throws {
        let suiteName = "codex-director-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["en"], forKey: "AppleLanguages")
        defaults.set("sentinel", forKey: "AppleInterfaceStyle")

        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        let store = AppThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme, .dark)
        store.setTheme(.light)

        XCTAssertEqual(AppThemeStore(defaults: defaults).theme, .light)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["en"])
        XCTAssertEqual(defaults.string(forKey: "AppleInterfaceStyle"), "sentinel")
        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertTrue(Set(after.keys).subtracting(before.keys).isSubset(of: [AppThemeStore.preferenceKey]))
        XCTAssertEqual(after["AppleLanguages"] as? [String], before["AppleLanguages"] as? [String])
        XCTAssertEqual(after["AppleInterfaceStyle"] as? String, before["AppleInterfaceStyle"] as? String)
    }
}
