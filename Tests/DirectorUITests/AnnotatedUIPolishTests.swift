import XCTest
@testable import DirectorUI

final class AnnotatedUIPolishTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testHomeProductNameUsesGradientWhileToolbarKeepsNativeTitle() throws {
        let root = try source("Sources/DirectorUI/AppShell/DirectorRootView.swift")
        let home = try source("Sources/DirectorUI/Home/HomeOverviewView.swift")
        let components = try source("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")
        let typography = try source("Sources/DirectorUI/DesignSystem/DirectorTypography.swift")

        XCTAssertTrue(root.contains(".navigationTitle(DirectorUI.productName)"))
        XCTAssertFalse(root.contains("brandToolbarTitle"))
        XCTAssertFalse(root.contains("ToolbarItem(placement: .navigation)"))
        XCTAssertTrue(root.contains("sidebarDestination"))
        XCTAssertTrue(root.contains("DirectorColor.primaryActionForeground"))
        XCTAssertTrue(home.contains("titleAccent: DirectorUI.productName"))
        XCTAssertTrue(components.contains("public let titleAccent: String?"))
        XCTAssertTrue(components.contains("Text(titleAccent).foregroundStyle(DirectorGradient.primaryButton)"))
        XCTAssertTrue(components.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(typography.contains("size: 52"))
        XCTAssertTrue(typography.contains("size: 36"))
    }

    func testHomeModuleHeadersAreSymmetricAndHaveNoSummarySubtitles() throws {
        let home = try source("Sources/DirectorUI/Home/HomeOverviewView.swift")
        let components = try source("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")

        XCTAssertGreaterThanOrEqual(home.components(separatedBy: "supportingText: nil").count - 1, 3)
        XCTAssertFalse(home.contains("home.overview.inventorySubtitle"))
        XCTAssertFalse(home.contains("home.overview.frequencyNote"))
        XCTAssertTrue(components.contains(".padding(.vertical, DirectorSpacing.space4)"))
        XCTAssertTrue(components.contains(".padding(.horizontal, DirectorSpacing.space6)"))
        XCTAssertTrue(components.contains(".padding(.bottom, DirectorSpacing.space6)"))
    }

    func testQuotaUsesOutlinedBrandSourceSwitchAndResetBelowSmallerCenteredRing() throws {
        let quota = try source("Sources/DirectorUI/Home/QuotaOverviewView.swift")
        let components = try source("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")
        let spacing = try source("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift")

        XCTAssertTrue(quota.contains("QuotaSourceSwitch("))
        XCTAssertFalse(quota.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(quota.contains(".stroke(DirectorGradient.primaryButton"))
        XCTAssertTrue(quota.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        XCTAssertTrue(quota.contains("resetSummary"))
        XCTAssertTrue(quota.contains("ringSection.frame(width: 420, alignment: .center)"))
        XCTAssertTrue(quota.contains("VStack(alignment: .leading, spacing: DirectorSpacing.space3)"))
        XCTAssertTrue(quota.contains("VStack(alignment: .center, spacing: DirectorSpacing.space5)"))
        XCTAssertTrue(components.contains("diameter: CGFloat = DirectorSpacing.homeQuotaRingDiameter"))
        XCTAssertTrue(spacing.contains("homeQuotaRingDiameter: CGFloat = 216"))
        XCTAssertFalse(quota.contains("evidenceSection"))
        XCTAssertFalse(quota.contains("home.quota.evidence"))
        XCTAssertFalse(quota.contains("home.quota.recorded"))
        XCTAssertTrue(quota.contains("AxisValueLabel(centered: true)"))
        let normalized = quota.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(normalized.contains(".chartXScale( domain: chartCategories, range: .plotDimension"))
    }

    func testSidebarAndToolbarUseSingleBrandSelectionLayer() throws {
        let root = try source("Sources/DirectorUI/AppShell/DirectorRootView.swift")
        let colors = try source("Sources/DirectorUI/DesignSystem/DirectorColor.swift")
        let scheme = try source("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift")

        XCTAssertTrue(root.contains(".tint(.clear)"))
        XCTAssertTrue(root.contains("NativeListSelectionVisualSuppressor"))
        XCTAssertTrue(root.contains("tableView.selectionHighlightStyle = .none"))
        XCTAssertTrue(root.contains("DirectorColor.sidebarSelectedSymbol"))
        XCTAssertTrue(colors.contains("sidebarSelectedSymbol"))
        XCTAssertTrue(root.contains(".sharedBackgroundVisibility(.hidden)"))
        XCTAssertTrue(scheme.contains("size == .toolbar ? 0"))
    }

    func testCapabilityGroupsHaveSpacingAndProminentProjectHeaders() throws {
        let library = try source("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
        let shared = try source("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift")

        XCTAssertTrue(library.contains("groupRowInsets"))
        XCTAssertTrue(library.contains("bottom: closesGroup ? DirectorSpacing.space5 : base.bottom"))
        XCTAssertTrue(library.contains("symbolName: group.id == \"__global__\""))
        XCTAssertTrue(library.contains("CapabilityGroupHeaderBorder().fill"))
        XCTAssertTrue(shared.contains("public let symbolName: String?"))
        XCTAssertTrue(shared.contains(".title3.weight(.semibold)"))
    }

    func testCapabilityProjectGroupsUseTwentyPointInterGroupSpacing() throws {
        let library = try source("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
        let spacing = try source("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift")
        let design = try source(".design/codex-director/DESIGN_SYSTEM_V1.md")

        XCTAssertTrue(library.contains("bottom: closesGroup ? DirectorSpacing.space5 : base.bottom"))
        XCTAssertTrue(library.contains("Only the final row owns the inter-group gap"))
        XCTAssertTrue(spacing.contains("public static let space5: CGFloat = 20"))
        XCTAssertTrue(design.contains("exactly 20pt") || design.contains("exactly 20 pt"))
    }

    func testDarkTealDataAccentUsesReadableEmphasisValue() throws {
        let colors = try source("Sources/DirectorUI/DesignSystem/DirectorColor.swift")
        let tealLine = try XCTUnwrap(colors.split(separator: "\n").first { $0.contains("accentTeal = dynamic") })
        XCTAssertTrue(tealLine.contains("dark: NSColor(red: 0x5F / 255, green: 0xD7 / 255, blue: 0xEE / 255"))

        let foreground = relativeLuminance(red: 0x5F / 255, green: 0xD7 / 255, blue: 0xEE / 255)
        let background = relativeLuminance(red: 0x09 / 255, green: 0x0F / 255, blue: 0x13 / 255)
        XCTAssertGreaterThanOrEqual((foreground + 0.05) / (background + 0.05), 4.5)
    }

    func testSettingsUsesBalancedSectionsAndEqualCompactActions() throws {
        let settings = try source("Sources/DirectorUI/DataStatus/SettingsView.swift")
        let shared = try source("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift")

        XCTAssertTrue(settings.contains("subtitle: nil"))
        XCTAssertTrue(settings.contains("VStack(alignment: .leading, spacing: 0)"))
        XCTAssertTrue(settings.contains("size: .settings"))
        XCTAssertTrue(settings.contains("DirectorSecondaryActionButtonStyle(size: .settings"))
        XCTAssertFalse(settings.contains("content()\n                .padding(.bottom, DirectorSpacing.space3)"))
        XCTAssertTrue(shared.contains(".padding(.vertical, DirectorSpacing.space6)"))
        XCTAssertFalse(shared.contains(".padding(.top, DirectorSpacing.space2)"))
    }

    func testCompactActionTokensAreNamed() throws {
        let spacing = try source("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift")
        let scheme = try source("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift")

        XCTAssertTrue(spacing.contains("toolbarControlMinHeight: CGFloat = 28"))
        XCTAssertTrue(spacing.contains("settingsActionLabelWidth: CGFloat = 176"))
        XCTAssertTrue(spacing.contains("settingsActionHeight: CGFloat = 48"))
        XCTAssertTrue(scheme.contains("case settings"))
    }

    func testSettingsActionsShareFixedDimensionsAndExportHasNoEllipsis() throws {
        let settings = try source("Sources/DirectorUI/DataStatus/SettingsView.swift")
        let spacing = try source("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift")
        let scheme = try source("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift")
        XCTAssertTrue(settings.contains("DirectorRefreshButton("))
        XCTAssertTrue(settings.contains("size: .settings"))
        XCTAssertTrue(settings.contains("DirectorSecondaryActionButtonStyle(size: .settings, destructive: true)"))
        XCTAssertTrue(settings.contains("DirectorPrimaryActionButtonStyle(size: .settings)"))
        XCTAssertEqual(settings.components(separatedBy: "size: .settings").count - 1, 3)
        XCTAssertTrue(spacing.contains("settingsActionLabelWidth: CGFloat = 176"))
        XCTAssertTrue(spacing.contains("settingsActionHeight: CGFloat = 48"))
        XCTAssertTrue(scheme.contains("self == .settings ? DirectorSpacing.settingsActionLabelWidth : nil"))
        XCTAssertTrue(scheme.contains("case .settings: return DirectorSpacing.settingsActionHeight"))
        XCTAssertTrue(scheme.contains("case .standard: return DirectorSpacing.controlMinHeight"))
        XCTAssertEqual(scheme.components(separatedBy: ".frame(minHeight: size.minimumHeight)").count - 1, 2)
        XCTAssertFalse(settings.contains("Export capability package…"))
        XCTAssertFalse(settings.contains("Export capability package..."))

        for relativePath in [
            "Sources/DirectorUI/Resources/en.lproj/Localizable.strings",
            "Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings",
        ] {
            let localization = try source(relativePath)
            let line = try XCTUnwrap(localization.split(separator: "\n").first { $0.contains("\"settings.migration.export\"") })
            XCTAssertFalse(line.contains("…"), "export label must not contain an ellipsis in \(relativePath)")
            XCTAssertFalse(line.contains("..."), "export label must not contain three dots in \(relativePath)")
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
