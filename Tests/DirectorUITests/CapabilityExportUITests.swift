import Foundation
import XCTest
import DirectorCore
@testable import DirectorUI

@MainActor
final class CapabilityExportUITests: XCTestCase {
    private struct PluginProvider: CapabilityPluginInventoryProviding {
        func inventory(at date: Date) async -> CapabilityPackagePluginList {
            CapabilityPackagePluginList(status: .complete, generatedAt: date, plugins: [])
        }
    }

    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testAppModelPresentsExportServiceWithoutIndexServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-export-ui-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectory = root
        let skill = root.appendingPathComponent("home/.codex/skills/sample/SKILL.md")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("---\nname: sample\n---\n".utf8).write(to: skill)

        let coordinator = CapabilityExportCoordinator(
            environment: CapabilityExportEnvironment(
                homeDirectory: root.appendingPathComponent("home"),
                projects: [],
                producer: CapabilityPackageProducer(version: "0.3.0", build: "15"),
                platform: CapabilityPackagePlatform(operatingSystem: "macOS", operatingSystemVersion: "26.0", architecture: "arm64")
            ),
            pluginProvider: PluginProvider()
        )
        let model = DirectorAppModel(
            capabilityExportCoordinator: coordinator,
            previewMode: false,
            bootstrapError: "synthetic_database_failure"
        )
        XCTAssertNil(model.store)
        let options = try await model.loadCapabilityExportOptions()
        XCTAssertEqual(options.globalCapabilities.map(\.name), ["sample"])

        let preview = try await model.prepareCapabilityExport(selection: .defaults(for: options))
        XCTAssertFalse(preview.hasBlockingIssues)
        let destination = output.appendingPathComponent("ui.codexpack.zip")
        _ = try await model.savePreparedCapabilityExport(to: destination)
        XCTAssertEqual(model.capabilityExportProgress?.phase, .finished)
        XCTAssertFalse(model.isCapabilityExporting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSettingsAndSheetKeepSchemeAAccessibilityContracts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityExportSheet.swift"), encoding: .utf8)
        XCTAssertEqual(settings.components(separatedBy: "section(ordinal:").count - 1, 6)
        XCTAssertTrue(settings.contains("settings.migration.title"))
        XCTAssertTrue(settings.contains("CapabilityExportSheet"))
        XCTAssertTrue(sheet.contains("NSSavePanel"))
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.escape"))
        XCTAssertTrue(sheet.contains(".interactiveDismissDisabled(model.isCapabilityExporting)"))
        XCTAssertTrue(sheet.contains("DirectorPrimaryActionButtonStyle"))
        XCTAssertTrue(sheet.contains("DirectorSecondaryActionButtonStyle"))
        XCTAssertFalse(sheet.contains(".ultraThinMaterial"))
        XCTAssertFalse(sheet.contains("Glass"))
    }
}
