import Foundation
import XCTest

final class CapabilityRestoreUITests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSettingsExposesRestoreAlongsideExport() throws {
        let settings = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("CapabilityRestoreSheet(model: model)"))
        XCTAssertTrue(settings.contains("settings.migration.restore"))
        XCTAssertTrue(settings.contains("model.isCapabilityRestoring"))
    }

    func testRestoreSheetKeepsTrustMappingPreflightAndUndoStagesVisible() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityRestoreSheet.swift"),
            encoding: .utf8
        )
        for marker in [
            "case choose", "case trust", "case verifying", "case mapping",
            "case preflighting", "case review", "case restoring", "case success",
            "confirmationDialog", "ProgressView()", "undoRestore()",
            "only missing files", "interactiveDismissDisabled"
        ] {
            XCTAssertTrue(source.localizedCaseInsensitiveContains(marker), "Missing restore UI contract: \(marker)")
        }
        XCTAssertTrue(source.contains("CapabilityRestoreSelection"))
        XCTAssertTrue(source.contains("excludedCapabilityIDs"))
    }

    func testRestoreLocalizationHasMatchingBilingualContract() throws {
        let english = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let keys = [
            "settings.migration.restore", "settings.migration.restore.trust",
            "settings.migration.restoreQuarantine",
            "settings.migration.restore.verify", "settings.migration.restore.map",
            "settings.migration.restore.preview", "settings.migration.restore.confirm",
            "settings.migration.restore.restoring", "settings.migration.restore.undo",
            "settings.migration.restore.error.mapping",
            "settings.migration.restore.conflictDetails",
            "settings.migration.restore.textDifference",
            "settings.migration.restore.metadataOnly",
            "settings.migration.restore.pluginChecklist",
            "settings.migration.restore.dependencyChecklist",
            "settings.migration.restore.cleanupSummary",
            "settings.migration.restore.cleanup.moved",
            "settings.migration.restore.cleanup.isolated",
            "settings.migration.restore.cleanup.quarantineUnavailable",
            "settings.migration.restore.cleanup.quarantineMoveFailed",
            "settings.migration.restore.cleanup.unverifiedStaging",
            "settings.migration.restore.quarantineRetention",
            "settings.migration.restore.revealQuarantine",
            "settings.migration.restore.revealQuarantineHint"
        ]
        for key in keys {
            XCTAssertTrue(english.contains("\"\(key)\""), "English key missing: \(key)")
            XCTAssertTrue(chinese.contains("\"\(key)\""), "Chinese key missing: \(key)")
        }
    }

    func testRestoreReviewRendersSafeConflictDiffMetadataAndConcreteChecklists() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityRestoreSheet.swift"),
            encoding: .utf8
        )
        for marker in [
            "ForEach(conflicts)", "entry.difference", "difference.prefix(4_000)",
            "entry.displayPath", "entry.contentType", "entry.byteSize", "entry.sha256",
            "info.plugins.plugins.enumerated()", "info.requirements.requirements.enumerated()",
            "checklistReadOnly", "nothing is installed or executed"
        ] {
            XCTAssertTrue(source.contains(marker), "Missing safe restore review contract: \(marker)")
        }
        XCTAssertFalse(source.contains("Data(contentsOf:"), "The UI must never open package payload content")
    }

    func testRestoreFailureAndUndoRenderStructuredCleanupResiduals() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityRestoreSheet.swift"),
            encoding: .utf8
        )
        for marker in [
            "CapabilityRestoreOperationFailure", "cleanupResult", "cleanupSummary(",
            "failedRemovalCount", "skippedModifiedCount", "cleanupIssueText"
        ] {
            XCTAssertTrue(source.contains(marker), "Missing cleanup reporting contract: \(marker)")
        }
    }

    func testRestoreResultOffersAccessibleNonDestructiveQuarantineReveal() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityRestoreSheet.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"),
            encoding: .utf8
        )
        for marker in [
            "CapabilityRestoreQuarantineLocation", "quarantineLocations",
            "NSWorkspace.shared.activateFileViewerSelecting", "location.directoryURL",
            "location.placeholder",
            "DirectorSecondaryActionButtonStyle", "revealQuarantineHint",
            "never automatically deletes quarantine contents"
        ] {
            XCTAssertTrue(source.contains(marker), "Missing quarantine reveal contract: \(marker)")
        }
        XCTAssertTrue(settings.contains("settings.migration.restoreQuarantine"))
        XCTAssertTrue(settings.contains("private quarantine that the result can reveal in Finder"))
        XCTAssertFalse(source.contains("Text(location.directoryURL.path)"), "Raw quarantine paths must not be rendered")
    }

    func testRestoreSheetCloseDefersCoordinatorDiscardWithoutPublishingFalseIdleState() throws {
        let sheet = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/CapabilityRestoreSheet.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorAppModel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sheet.contains("model.discardCapabilityRestore()"))
        XCTAssertTrue(sheet.contains("defers discard until an active restore/undo"))
        XCTAssertTrue(model.contains("if !isCapabilityRestoring { capabilityRestoreProgress = nil }"))
        XCTAssertFalse(model.contains("Task { await capabilityRestoreCoordinator.discard() }\n        isCapabilityRestoring = false"))
    }
}
