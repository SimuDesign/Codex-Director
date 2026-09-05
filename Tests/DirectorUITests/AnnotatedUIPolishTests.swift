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

    func testQuotaUsesSegmentedSourceSwitchAndResetBelowCenteredRing() throws {
        let quota = try source("Sources/DirectorUI/Home/QuotaOverviewView.swift")

        XCTAssertTrue(quota.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(quota.contains("resetSummary"))
        XCTAssertTrue(quota.contains("ringSection.frame(width: 420, alignment: .center)"))
        XCTAssertFalse(quota.contains("evidenceSection"))
        XCTAssertFalse(quota.contains("home.quota.evidence"))
        XCTAssertFalse(quota.contains("home.quota.recorded"))
        XCTAssertTrue(quota.contains("AxisValueLabel(centered: false)"))
        let normalized = quota.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(normalized.contains(".chartXScale( domain: chartCategories, range: .plotDimension"))
    }

    func testCapabilityGroupsHaveSpacingAndProminentProjectHeaders() throws {
        let library = try source("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
        let shared = try source("Sources/DirectorUI/DesignSystem/DirectorSharedComponents.swift")

        XCTAssertTrue(library.contains("groupRowInsets"))
        XCTAssertTrue(library.contains("DirectorSpacing.space4"))
        XCTAssertTrue(library.contains("symbolName: group.id == \"__global__\""))
        XCTAssertTrue(library.contains("CapabilityGroupHeaderBorder().fill"))
        XCTAssertTrue(shared.contains("public let symbolName: String?"))
        XCTAssertTrue(shared.contains(".title3.weight(.semibold)"))
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
        XCTAssertTrue(spacing.contains("settingsActionLabelWidth: CGFloat = 128"))
        XCTAssertTrue(scheme.contains("case settings"))
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
