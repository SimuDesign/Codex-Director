import Foundation
import XCTest
@testable import DirectorCore

final class CodexRuntimeLocatorTests: XCTestCase {
    private actor ProbeRecorder {
        let versions: [String: String?]
        private(set) var paths: [String] = []

        init(versions: [String: String?]) {
            self.versions = versions
        }

        func probe(_ url: URL) -> String? {
            paths.append(url.path)
            return versions[url.path] ?? nil
        }

        func recordedPaths() -> [String] { paths }
    }

    func testUserSelectedRuntimeTakesPriorityOverApplicationsAndPATH() async {
        let selected = URL(fileURLWithPath: "/opt/custom/codex")
        let app = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let path = URL(fileURLWithPath: "/usr/local/bin/codex")
        let available = Set([selected.path, app.path, path.path])
        let recorder = ProbeRecorder(versions: [selected.path: "codex-cli 0.153.0-alpha.5"])
        let locator = makeLocator(
            available: available,
            executable: available,
            environment: ["PATH": "/usr/local/bin"],
            knownCandidates: [.init(url: app, source: .codexApplication)],
            recorder: recorder
        )

        let status = await locator.locate(userSelectedURL: selected)

        XCTAssertEqual(status.executableURL, selected)
        XCTAssertEqual(status.source, .userSelected)
        XCTAssertEqual(status.permission, .executable)
        XCTAssertEqual(status.compatibility, .compatible)
        XCTAssertEqual(status.version, "codex-cli 0.153.0-alpha.5")
        XCTAssertTrue(status.isUsable)
        let paths = await recorder.recordedPaths()
        XCTAssertEqual(paths, [selected.path])
    }

    func testKnownApplicationPrecedesPATHWhenNoUserSelectionExists() async {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let path = URL(fileURLWithPath: "/usr/local/bin/codex")
        let available = Set([app.path, path.path])
        let recorder = ProbeRecorder(versions: [app.path: "codex-cli 1.2.3"])
        let locator = makeLocator(
            available: available,
            executable: available,
            environment: ["PATH": "/usr/local/bin"],
            knownCandidates: [.init(url: app, source: .chatGPTApplication)],
            recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertEqual(status.executableURL, app)
        XCTAssertEqual(status.source, .chatGPTApplication)
    }

    func testPATHIgnoresRelativeAndEmptySegments() async {
        let safe = URL(fileURLWithPath: "/opt/codex/bin/codex")
        let recorder = ProbeRecorder(versions: [safe.path: "codex-cli 1.0.0"])
        let locator = makeLocator(
            available: [safe.path],
            executable: [safe.path],
            environment: ["PATH": ":relative:/opt/codex/bin"],
            knownCandidates: [],
            recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertEqual(status.executableURL, safe)
        XCTAssertEqual(status.source, .path)
    }

    func testExplicitMissingAndNonExecutableSelectionsAreReportedWithoutFallback() async {
        let fallback = URL(fileURLWithPath: "/usr/local/bin/codex")
        let missing = URL(fileURLWithPath: "/opt/missing/codex")
        let blocked = URL(fileURLWithPath: "/opt/blocked/codex")
        let recorder = ProbeRecorder(versions: [fallback.path: "codex-cli 1.0.0"])
        let locator = makeLocator(
            available: [fallback.path, blocked.path],
            executable: [fallback.path],
            environment: ["PATH": "/usr/local/bin"],
            knownCandidates: [],
            recorder: recorder
        )

        let missingStatus = await locator.locate(userSelectedURL: missing)
        XCTAssertEqual(missingStatus.executableURL, missing)
        XCTAssertEqual(missingStatus.permission, .missing)
        XCTAssertEqual(missingStatus.issue, .runtimeNotFound)
        XCTAssertFalse(missingStatus.isUsable)

        let blockedStatus = await locator.locate(userSelectedURL: blocked)
        XCTAssertEqual(blockedStatus.executableURL, blocked)
        XCTAssertEqual(blockedStatus.permission, .notExecutable)
        XCTAssertEqual(blockedStatus.issue, .notExecutable)
        XCTAssertFalse(blockedStatus.isUsable)

        let paths = await recorder.recordedPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func testDirectoryNamedCodexIsNotAcceptedAsAnExecutableRuntime() async {
        let directory = URL(fileURLWithPath: "/opt/bin/codex", isDirectory: true)
        let recorder = ProbeRecorder(versions: [directory.path: "codex-cli 1.0.0"])
        let locator = makeLocator(
            available: [directory.path],
            regular: [],
            executable: [directory.path],
            environment: [:],
            knownCandidates: [.init(url: directory, source: .codexApplication)],
            recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertEqual(status.permission, .notExecutable)
        XCTAssertEqual(status.issue, .notExecutable)
        XCTAssertFalse(status.isUsable)
        let paths = await recorder.recordedPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func testMissingAutomaticCandidatesProducesPrivacySafeUnavailableStatus() async {
        let recorder = ProbeRecorder(versions: [:])
        let locator = makeLocator(
            available: [], executable: [], environment: ["PATH": "/missing"],
            knownCandidates: [], recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertNil(status.executableURL)
        XCTAssertNil(status.source)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.permission, .missing)
        XCTAssertEqual(status.compatibility, .unknown)
        XCTAssertEqual(status.issue, .runtimeNotFound)
        XCTAssertFalse(status.isUsable)
    }

    func testUnavailableVersionIsUnknownButRuntimeRemainsUsable() async {
        let app = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let recorder = ProbeRecorder(versions: [app.path: nil])
        let locator = makeLocator(
            available: [app.path], executable: [app.path], environment: [:],
            knownCandidates: [.init(url: app, source: .codexApplication)], recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertEqual(status.permission, .executable)
        XCTAssertEqual(status.compatibility, .unknown)
        XCTAssertEqual(status.issue, .versionUnavailable)
        XCTAssertTrue(status.isUsable)
    }

    func testNonCodexExecutableIsIncompatibleAndAutomaticSearchContinues() async {
        let app = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let path = URL(fileURLWithPath: "/usr/local/bin/codex")
        let available = Set([app.path, path.path])
        let recorder = ProbeRecorder(versions: [
            app.path: "other-cli 1.0.0",
            path.path: "codex-cli 0.153.0-alpha.5",
        ])
        let locator = makeLocator(
            available: available,
            executable: available,
            environment: ["PATH": "/usr/local/bin"],
            knownCandidates: [.init(url: app, source: .codexApplication)],
            recorder: recorder
        )

        let status = await locator.locate()

        XCTAssertEqual(status.executableURL, path)
        XCTAssertEqual(status.compatibility, .compatible)
        let paths = await recorder.recordedPaths()
        XCTAssertEqual(paths, [app.path, path.path])
    }

    func testRuntimePreferenceStoreUsesDedicatedKeyAndRestoresAcrossInstances() throws {
        let suite = "codex-director-runtime-path-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = URL(fileURLWithPath: "/opt/custom/codex")
        let keysBefore = Set(defaults.dictionaryRepresentation().keys)

        let first = CodexRuntimePreferenceStore(defaults: defaults)
        XCTAssertTrue(first.setSelectedURL(selected))
        XCTAssertEqual(defaults.string(forKey: CodexRuntimePreferenceStore.preferenceKey), selected.path)
        XCTAssertEqual(CodexRuntimePreferenceStore(defaults: defaults).selectedURL(), selected)
        let addedKeys = Set(defaults.dictionaryRepresentation().keys).subtracting(keysBefore)
        XCTAssertEqual(addedKeys, [CodexRuntimePreferenceStore.preferenceKey])

        first.clear()
        XCTAssertNil(defaults.string(forKey: CodexRuntimePreferenceStore.preferenceKey))
    }

    func testRuntimePreferenceStoreRejectsInvalidAndSupportsMemoryIsolation() {
        var stored: String?
        let store = CodexRuntimePreferenceStore(
            readPreference: { stored },
            writePreference: { stored = $0 },
            removePreference: { stored = nil }
        )

        XCTAssertFalse(store.setSelectedURL(URL(string: "https://example.invalid/codex")!))
        XCTAssertNil(stored)
        stored = "relative/codex"
        XCTAssertNil(store.selectedURL())
        stored = "/opt/codex\nmalformed"
        XCTAssertNil(store.selectedURL())

        let memory = CodexRuntimePreferenceStore(memoryURL: URL(fileURLWithPath: "/memory/codex"))
        XCTAssertEqual(memory.selectedURL()?.path, "/memory/codex")
        XCTAssertTrue(memory.setSelectedURL(URL(fileURLWithPath: "/changed/codex")))
        XCTAssertEqual(memory.selectedURL()?.path, "/changed/codex")
    }

    private func makeLocator(
        available: Set<String>,
        regular: Set<String>? = nil,
        executable: Set<String>,
        environment: [String: String],
        knownCandidates: [CodexRuntimeCandidate],
        recorder: ProbeRecorder
    ) -> CodexRuntimeLocator {
        let regularFiles = regular ?? available
        return CodexRuntimeLocator(
            knownApplicationCandidates: knownCandidates,
            environment: environment,
            fileExists: { available.contains($0.path) },
            isRegularFile: { regularFiles.contains($0.path) },
            isExecutable: { executable.contains($0.path) },
            versionProbe: { url in await recorder.probe(url) }
        )
    }
}
