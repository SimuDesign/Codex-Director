import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class LocalizationTests: XCTestCase {
    func testLanguageDefaultsToChineseAndInvalidValueFallsBack() {
        let defaultStore = AppLanguageStore(memoryLanguage: .simplifiedChinese)
        XCTAssertEqual(defaultStore.language, .simplifiedChinese)

        var stored: String? = "not-a-language"
        let store = AppLanguageStore(readPreference: { stored }, writePreference: { stored = $0 })
        XCTAssertEqual(store.language, .simplifiedChinese)
        store.setLanguage(.english)
        XCTAssertEqual(stored, AppLanguage.english.rawValue)
    }

    func testInjectedLanguageStoreDoesNotUseDefaults() {
        var stored: String?
        let store = AppLanguageStore(readPreference: { stored }, writePreference: { stored = $0 })
        store.setLanguage(.english)
        XCTAssertEqual(store.localizer.text("language.settings.title", fallback: "Language"), "Language")
        XCTAssertEqual(stored, "en")
    }

    func testMissingLanguageUsesDeterministicEnglishOrExplicitFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-director-locale-\(UUID().uuidString)", isDirectory: true)
        let englishDirectory = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: englishDirectory, withIntermediateDirectories: true)
        try #""greeting" = "English source";"#.write(
            to: englishDirectory.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try XCTUnwrap(Bundle(path: root.path))
        let missingChinese = DirectorLocalizer(language: .simplifiedChinese, bundle: bundle)
        XCTAssertEqual(missingChinese.text("greeting", fallback: "Explicit fallback"), "English source")

        let noEnglishRoot = root.appendingPathComponent("no-english", isDirectory: true)
        try FileManager.default.createDirectory(at: noEnglishRoot, withIntermediateDirectories: true)
        let noEnglishBundle = try XCTUnwrap(Bundle(path: noEnglishRoot.path))
        XCTAssertEqual(DirectorLocalizer(language: .simplifiedChinese, bundle: noEnglishBundle).text("greeting", fallback: "Explicit fallback"), "Explicit fallback")
    }

    func testProductionConstructorUsesOnlyDedicatedPreferenceKey() throws {
        let suiteName = "codex-director-localization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        defaults.set("sentinel-locale", forKey: "AppleLocale")
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, .simplifiedChinese)

        let beforeDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let store = AppLanguageStore(defaults: defaults)
        store.setLanguage(.english)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, .english)
        defaults.set("invalid", forKey: AppLanguageStore.preferenceKey)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).language, .simplifiedChinese)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["zh-Hans"])
        XCTAssertEqual(defaults.string(forKey: "AppleLocale"), "sentinel-locale")
        let afterDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertTrue(Set(afterDomain.keys).subtracting(beforeDomain.keys).isSubset(of: [AppLanguageStore.preferenceKey]))
        XCTAssertEqual(afterDomain["AppleLanguages"] as? [String], beforeDomain["AppleLanguages"] as? [String])
        XCTAssertEqual(afterDomain["AppleLocale"] as? String, beforeDomain["AppleLocale"] as? String)
    }

    func testPluralResolvesBothLanguagesAndLargeCount() {
        let english = DirectorLocalizer(language: .english)
        let chinese = DirectorLocalizer(language: .simplifiedChinese)
        XCTAssertEqual(english.plural("resource.count", count: 0, fallback: "%lld resource(s)"), "0 resources")
        XCTAssertEqual(english.plural("resource.count", count: 1, fallback: "%lld resource(s)"), "1 resource")
        XCTAssertEqual(english.plural("resource.count", count: 2, fallback: "%lld resource(s)"), "2 resources")
        XCTAssertEqual(chinese.plural("resource.count", count: 2, fallback: "%lld resource(s)"), "2 项能力")
        let large = english.plural("resource.count", count: Int.max, fallback: "%lld resource(s)")
        XCTAssertTrue(large.contains("resources"))
        XCTAssertFalse(large.contains("%#@count@"))
        XCTAssertTrue(large.contains("9,223,372,036,854,775,807"))
    }

    func testSearchAliasesCoverRawEnumValues() {
        let values = ["plugin", "workflow", "project", "global", "builtIn"]
        let haystack = LocalizedSearch.haystack(values)
        XCTAssertTrue(haystack.contains("插件"))
        XCTAssertTrue(haystack.contains("工作流"))
        XCTAssertTrue(haystack.contains("项目"))
        XCTAssertTrue(haystack.contains("全局"))
        XCTAssertTrue(haystack.contains("内置"))
    }

    func testCapabilitiesSearchMatchesChineseEnumAliases() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let resources = [
            CapabilityResource(id: "app:a", name: "Calendar", kind: .app, status: .unknown, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: epoch),
            CapabilityResource(id: "hook:h", name: "Formatter", kind: .hook, status: .unknown, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: epoch),
            CapabilityResource(id: "output:o", name: "Output", kind: .output, status: .unknown, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "runtime", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: epoch),
            CapabilityResource(id: "skill:r", name: "Registry skill", kind: .skill, status: .unknown, scope: .runtime, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "registry", relativeSourcePath: nil, sourcePathHash: nil, lastSeenAt: epoch, ownership: .installed, origin: .registry)
        ]
        let model = CapabilitiesViewModel(resources: resources)
        for (query, expectedID) in [("应用", "app:a"), ("钩子", "hook:h"), ("输出", "output:o"), ("注册源", "skill:r")] {
            model.searchText = query
            XCTAssertEqual(model.filteredRows.map(\.id), [expectedID], "Chinese search alias failed for \(query)")
        }
    }
}
