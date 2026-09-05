import AppKit
import XCTest

@testable import DirectorUI

final class PageChromeConsistencyTests: XCTestCase {
  private var sourceRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testSharedPageGridMatchesHomeAtStandardCompactAndWideWidths() {
    XCTAssertEqual(DirectorPageLayout.horizontalPadding(for: 759), 16)
    XCTAssertEqual(DirectorPageLayout.horizontalPadding(for: 760), 40)
    XCTAssertEqual(DirectorPageLayout.contentWidth(for: 1_280), 1_200)
    XCTAssertEqual(DirectorPageLayout.contentWidth(for: 2_000), 1_440)
    XCTAssertEqual(DirectorPageLayout.contentMargin(for: 1_280), 40)
    XCTAssertEqual(DirectorPageLayout.contentMargin(for: 2_000), 280)
    XCTAssertEqual(DirectorPageLayout.listRowInset(for: 1_280), 32)
    XCTAssertEqual(DirectorPageLayout.listRowInset(for: 2_000), 272)
  }

  func testPrimaryPageScrollContainersShareTheHomeContentGrid() throws {
    let frame = try source("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift")
    let home = try source("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")
    let capabilities = try source("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
    let settings = try source("Sources/DirectorUI/DataStatus/SettingsView.swift")

    XCTAssertTrue(frame.contains("public struct DirectorPageContentFrame"))
    XCTAssertTrue(home.contains("DirectorPageContentFrame(workspaceWidth: workspaceWidth)"))
    XCTAssertTrue(
      settings.contains("DirectorPageContentFrame(workspaceWidth: viewport.size.width)"))
    XCTAssertTrue(capabilities.contains("DirectorPageLayout.listRowInset(for: width)"))
    XCTAssertTrue(capabilities.contains("pageHeaderRowInsets(for: width)"))
    XCTAssertTrue(capabilities.contains("top: DirectorSpacing.space6"))
    XCTAssertTrue(capabilities.contains(".contentMargins(.vertical, 0, for: .scrollContent)"))
    XCTAssertFalse(capabilities.contains(".frame(maxWidth: DirectorSpacing.maxContentWidth"))
    XCTAssertFalse(settings.contains(".padding(.trailing, DirectorSpacing.space4)"))
  }

  func testPrimaryPageTitlesUseOneResponsiveScaleAndSymbolToken() throws {
    let typography = try source("Sources/DirectorUI/DesignSystem/DirectorTypography.swift")
    let home = try source("Sources/DirectorUI/Home/HomeCardAtlasComponents.swift")
    let capabilities = try source("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
    let settings = try source("Sources/DirectorUI/DataStatus/SettingsView.swift")

    XCTAssertTrue(typography.contains("pageHeroSymbol"))
    XCTAssertTrue(
      home.contains(
        "compact ? DirectorTypography.editorialHeroTitleCompact : DirectorTypography.editorialHeroTitle"
      ))
    XCTAssertTrue(
      capabilities.contains(
        "compact ? DirectorTypography.editorialHeroTitleCompact : DirectorTypography.editorialHeroTitle"
      ))
    XCTAssertTrue(capabilities.contains("DirectorTypography.pageHeroSymbol"))
    XCTAssertTrue(capabilities.contains("private var capabilityTitleText: Text { Text(title) }"))
    XCTAssertTrue(settings.contains("titleAccent: nil"))
  }

  func testAppIconUsesApprovedHexagonLayerArtwork() throws {
    let iconPackage = sourceRoot.appendingPathComponent("Resources/AppIcon.icon")
    let manifest = try String(
      contentsOf: iconPackage.appendingPathComponent("icon.json"), encoding: .utf8)
    let artwork = iconPackage.appendingPathComponent("Assets/codex-director-hexagon-fullbleed.png")

    for layer in ["hexagon-blue.png", "hexagon-cyan.png", "hexagon-mint.png"] {
      XCTAssertTrue(manifest.contains(layer))
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: iconPackage.appendingPathComponent("Assets/\(layer)").path))
    }
    XCTAssertFalse(manifest.contains("capability-nodes.png"))
    XCTAssertFalse(manifest.contains("director-core.png"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: artwork.path))

    let image = try XCTUnwrap(NSImage(contentsOf: artwork))
    XCTAssertEqual(image.size.width, 1_024)
    XCTAssertEqual(image.size.height, 1_024)
  }

  private func source(_ relativePath: String) throws -> String {
    try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
  }
}
