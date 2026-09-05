import XCTest
import SwiftUI
@testable import DirectorUI
import DirectorCore

@MainActor
final class DirectorSchemeATests: XCTestCase {
    func testSchemeAAdaptiveGridUsesFourTwoOneBreakpoints() {
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 1_280), 4)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 760), 4)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 759), 2)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 420), 2)
        XCTAssertEqual(DirectorAdaptiveGrid.columns(for: 419), 1)
        XCTAssertEqual(DirectorAdaptiveGrid.items(for: 600).count, 2)
    }

    func testSchemeAHasTypedAccentAndSharedVisualContracts() {
        XCTAssertEqual(DirectorAccentTone.allCases, [.blue, .ice, .mint, .teal])
        _ = DirectorGradient.primaryButton
        _ = DirectorGradient.accent(.mint)
        _ = DirectorGradient.selectionWash(.ice)
        _ = DirectorGradient.environment
        _ = DirectorCanvas { Text("Canvas") }
        _ = DirectorPageHeader(eyebrow: "01", title: "Agents", subtitle: "Purpose", symbolName: DirectorSymbol.category(.customAgents))
        _ = DirectorFilterRibbon { Text("Filters") }
        _ = DirectorControlField { Text("Current value") }
        _ = DirectorInspectorPanel { Text("Inspector") }
        _ = DirectorSideSheet(onClose: {}) { Text("Detail") }
        _ = DirectorMetricCard(symbolName: DirectorSymbol.summaryMetric(.global), label: "Global", value: "1", tone: .blue) { }
        _ = DirectorGroupHeader(title: "Global", tone: .teal)
        _ = Button("Primary", action: {}).buttonStyle(DirectorPrimaryActionButtonStyle())
        _ = Button("Toolbar", action: {}).buttonStyle(DirectorPrimaryActionButtonStyle(size: .toolbar))
        XCTAssertTrue(DirectorSymbol.requiredSymbols.contains(DirectorSymbol.usageEvidence))
    }

    func testAccentGradientKeepsThreeDistinctCoreHuesForEveryPageTone() {
        for tone in DirectorAccentTone.allCases {
            let stops = DirectorGradient.accentStopTones(for: tone)
            XCTAssertEqual(stops.count, 3, "accent rail should have three chromatic stops for \(tone)")
            XCTAssertTrue(stops.contains(.blue), "accent rail missing blue for \(tone)")
            XCTAssertTrue(stops.contains(.ice), "accent rail missing ice for \(tone)")
            XCTAssertTrue(stops.contains(.mint), "accent rail missing mint for \(tone)")
        }
    }

    func testAllCapabilityPagesConsumeTheSameSchemeAView() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let root = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorRootView.swift"), encoding: .utf8)
        XCTAssertTrue(library.contains("capabilityTitleBlock"))
        XCTAssertTrue(library.contains("capabilityTitleText"))
        XCTAssertGreaterThanOrEqual(library.components(separatedBy: "DirectorMetricCard(").count - 1, 1)
        XCTAssertTrue(library.contains("DirectorFilterRibbon"))
        XCTAssertTrue(library.contains("DirectorSideSheet"))
        XCTAssertFalse(library.contains("DirectorInspectorPanel"))
        XCTAssertTrue(library.contains("DirectorGroupHeader"))
        XCTAssertTrue(library.contains("case .customAgents: return .blue"))
        XCTAssertTrue(library.contains("case .customSkills: return .ice"))
        XCTAssertTrue(library.contains("case .installedSkills: return .mint"))
        XCTAssertTrue(library.contains("case .installedPlugins: return .teal"))
        XCTAssertTrue(library.contains("pluginStatusPicker"))
        for category in ["customAgents", "customSkills", "installedSkills", "installedPlugins"] {
            XCTAssertTrue(root.contains("CapabilityLibraryView"), "missing shared capability page route for \(category)")
        }
    }

    func testCapabilitySelectionUsesDismissibleSideSheet() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let detail = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityDetailView.swift"), encoding: .utf8)

        XCTAssertTrue(library.contains("DirectorSideSheet("))
        XCTAssertTrue(library.contains("detail(row, showsBackButton: false)"))
        XCTAssertFalse(library.contains("inspectorActive"))
        XCTAssertTrue(detail.contains("public let showsBackButton: Bool"))
        XCTAssertTrue(detail.contains("if showsBackButton"))
        XCTAssertTrue(detail.contains(".keyboardShortcut(.escape, modifiers: [])"))
    }

    func testCapabilitySummaryUsesActualContentWidthOnce() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)

        XCTAssertTrue(library.contains("DirectorMetricSequence(contentWidth: width)"))
        XCTAssertFalse(library.contains("DirectorAdaptiveGrid.items(for: max(0, width - DirectorSpacing.pagePadding * 2))"))
    }

    func testNativeRecompositionPrimitivesAreDeclared() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scheme = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift"), encoding: .utf8)
        let shared = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift"), encoding: .utf8)
        let spacing = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift"), encoding: .utf8)
        let typography = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorTypography.swift"), encoding: .utf8)

        for primitive in ["DirectorEditorialFrame", "DirectorEditorialHero", "DirectorInspectorPanel", "DirectorSideSheet"] {
            XCTAssertTrue(scheme.contains("public struct \(primitive)"), "missing shared frame primitive \(primitive)")
        }
        for primitive in ["DirectorContentStage", "DirectorSectionBand", "DirectorMetricSequence", "DirectorTableHeader"] {
            XCTAssertTrue(shared.contains("public struct \(primitive)"), "missing shared content primitive \(primitive)")
        }
        XCTAssertTrue(spacing.contains("inspectorMinWidth: CGFloat = 360"))
        XCTAssertTrue(spacing.contains("inspectorMaxWidth: CGFloat = 400"))
        XCTAssertTrue(spacing.contains("sideSheetMinWidth: CGFloat = 380"))
        XCTAssertTrue(spacing.contains("sideSheetMaxWidth: CGFloat = 420"))
        XCTAssertTrue(typography.contains("editorialHeroTitle"))
    }

    func testHomeAndSettingsUseSharedSchemeATonesAndPrimaryAction() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Home/HomeOverviewView.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("HomeCardAtlasFrame(workspaceWidth: viewport.size.width)"))
        XCTAssertFalse(home.contains("DirectorEditorialFrame"))
        XCTAssertTrue(home.contains("tone: inventoryTone(category)"))
        XCTAssertTrue(home.contains("DirectorColor.accent(tone)"))
        XCTAssertTrue(settings.contains("DirectorEditorialHero"))
        XCTAssertEqual(settings.components(separatedBy: "section(ordinal:").count - 1, 6)
        XCTAssertTrue(settings.contains("DirectorPrimaryActionButtonStyle"))
        XCTAssertTrue(settings.contains("settings.languageAppearance"))
        XCTAssertTrue(settings.contains("themePicker"))
        XCTAssertTrue(settings.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(settings.contains("settings.about.title"))
        XCTAssertTrue(settings.contains("settings.author"))
        XCTAssertTrue(settings.contains("七木 Simu"))
        XCTAssertTrue(settings.contains("0.3.1 (16)"))
        XCTAssertTrue(settings.contains("eyebrow: nil"))
        XCTAssertTrue(settings.contains("DirectorPageContentFrame(workspaceWidth: viewport.size.width)"))
        XCTAssertTrue(settings.contains("DirectorSecondaryActionButtonStyle(size: .settings, destructive: true)"))
        XCTAssertFalse(settings.contains(".frame(maxWidth: 960"), "Settings must use the shared 1440 pt editorial content measure")
        XCTAssertFalse(settings.contains(".padding(.trailing, DirectorSpacing.space4)"), "Settings must not add an asymmetric trailing page gutter")
    }

    func testSchemeAColorsStayCentralizedInDirectorColor() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorColor.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("0x15 / 255"))
        XCTAssertTrue(source.contains("0x49 / 255"))
        XCTAssertTrue(source.contains("0x79 / 255"))
        XCTAssertTrue(source.contains("0x0B / 255"))
        XCTAssertTrue(source.contains("primaryActionForeground = Color.black"))
        XCTAssertFalse(source.contains("TODO"))
    }

    func testBlackPrimaryActionTextMeetsContrastForEveryGradientStop() {
        let stops: [(Double, Double, Double)] = [
            (0x08, 0x79, 0xD9), (0x11, 0x8E, 0xAE), (0x14, 0x8F, 0x7E),
            (0x15, 0x9D, 0xFF), (0x49, 0xCA, 0xFF), (0x79, 0xEA, 0xD8),
        ]

        for stop in stops {
            let luminance = relativeLuminance(red: stop.0 / 255, green: stop.1 / 255, blue: stop.2 / 255)
            XCTAssertGreaterThanOrEqual((luminance + 0.05) / 0.05, 4.5)
        }
    }

    func testEveryGradientActionConsumerUsesTheBlackForegroundToken() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scheme = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift"), encoding: .utf8)
        XCTAssertTrue(scheme.contains(".foregroundStyle(DirectorColor.primaryActionForeground)"))

        for relativePath in [
            "Sources/DirectorUI/Capabilities/CapabilityDetailView.swift",
            "Sources/DirectorUI/Components/DirectorRefreshButton.swift",
            "Sources/DirectorUI/DataStatus/CapabilityExportSheet.swift",
            "Sources/DirectorUI/DataStatus/SettingsView.swift",
        ] {
            let consumer = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(consumer.contains("DirectorPrimaryActionButtonStyle"), "missing shared primary style in \(relativePath)")
        }
    }

    func testApplicationVersionContractAdvancesWithoutMovingHarnessVersion() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(contentsOf: sourceRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let pbxproj = try String(contentsOf: sourceRoot.appendingPathComponent("CodexDirector.xcodeproj/project.pbxproj"), encoding: .utf8)
        let buildScript = try String(contentsOf: sourceRoot.appendingPathComponent("scripts/build-local-app.sh"), encoding: .utf8)
        let appVerifier = try String(contentsOf: sourceRoot.appendingPathComponent("scripts/verify-app-bundle.sh"), encoding: .utf8)
        let harness = try String(contentsOf: sourceRoot.appendingPathComponent("Tests/StartupPerformanceHarness/project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("MARKETING_VERSION: 0.3.1"))
        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 16"))
        XCTAssertEqual(pbxproj.components(separatedBy: "MARKETING_VERSION = 0.3.1").count - 1, 2)
        XCTAssertEqual(pbxproj.components(separatedBy: "CURRENT_PROJECT_VERSION = 16").count - 1, 2)
        XCTAssertTrue(buildScript.contains("verify-app-bundle.sh"))
        XCTAssertTrue(appVerifier.contains("read-project-version.sh"))
        XCTAssertTrue(appVerifier.contains("short_version\" == \"$expected_marketing_version\""))
        XCTAssertTrue(appVerifier.contains("build_version\" == \"$expected_build_version\""))
        XCTAssertTrue(harness.contains("MARKETING_VERSION: 0.2.1"))
        XCTAssertTrue(harness.contains("CURRENT_PROJECT_VERSION: 4"))
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
