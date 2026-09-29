import XCTest
import SwiftUI
@testable import DirectorUI
import DirectorCore

final class FolderEntrySearchTests: XCTestCase {
    private let folders: [CapabilityFolderDefinition] = [
        .init(id: "c", source: .custom, customName: "Café Studio"),
        .init(id: "self-training", source: .selfTraining),
        .init(id: "global", source: .global),
        .init(id: "project::one", source: .project, projectID: "one", projectName: "Video Studio")
    ]

    func testEmptyAndWhitespaceKeepOrder() {
        XCTAssertEqual(CapabilityFolderEntrySearch.matching(folders, query: " \n", language: .english), folders)
    }

    func testNamesMatchCaseAndDiacriticsWithoutChangingIdentity() {
        XCTAssertEqual(CapabilityFolderEntrySearch.matching(folders, query: " cafe ", language: .english).map(\.id), ["c"])
        XCTAssertEqual(CapabilityFolderEntrySearch.matching(folders, query: "STUDIO", language: .english).map(\.id), ["c", "project::one"])
    }

    func testLocalizedDefaultsAndRenamedSelfTraining() {
        XCTAssertEqual(CapabilityFolderEntrySearch.matching(folders, query: "自我", language: .simplifiedChinese).map(\.id), ["self-training"])
        XCTAssertEqual(CapabilityFolderEntrySearch.matching(folders, query: "全局", language: .simplifiedChinese).map(\.id), ["global"])
        XCTAssertTrue(CapabilityFolderEntrySearch.matching(folders, query: "全局", language: .english).isEmpty)
        let renamed = CapabilityFolderDefinition(id: "self-training", source: .selfTraining, customName: "My Work")
        XCTAssertEqual(CapabilityFolderEntrySearch.matching([renamed], query: "work", language: .english), [renamed])
        XCTAssertTrue(CapabilityFolderEntrySearch.matching([renamed], query: "Self Training", language: .english).isEmpty)
    }

    func testNoMatchDoesNotSearchIDsOrCapabilityNames() {
        XCTAssertTrue(CapabilityFolderEntrySearch.matching(folders, query: "project::one", language: .english).isEmpty)
        XCTAssertTrue(CapabilityFolderEntrySearch.matching(folders, query: "Video Editor", language: .english).isEmpty)
    }

    func testSharedControlsHaveNativeFocusAndFullMenuLabel() throws {
        let source = try readSource("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift")
        XCTAssertTrue(source.contains(".focused($editorFocused)"))
        XCTAssertTrue(source.contains(".simultaneousGesture(TapGesture().onEnded"))
        XCTAssertTrue(source.contains("if isEnabled { editorFocused = true }"))
        _ = DirectorSearchField("Search folders", text: .constant(""), height: 36, clearLabel: "Clear search")
        _ = DirectorOutlinedMenuField("All capabilities", height: 32) { Text("All") }
    }
    func testEntryUsesSharedTitleAndFolderSearchControls() throws {
        let source = try readSource("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift")
        XCTAssertTrue(source.contains("DirectorTypography.editorialHeroTitleCompact"))
        XCTAssertTrue(source.contains("DirectorTypography.pageHeroSymbol"))
        XCTAssertTrue(source.contains("CapabilityFolderEntrySearch.matching"))
        XCTAssertFalse(source.contains("private var globalSearchResults"))
        XCTAssertTrue(source.contains("DirectorSearchField("))
    }

    func testLibraryUsesSharedActionableFields() throws {
        let source = try readSource("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift")
        XCTAssertTrue(source.contains("DirectorSearchField("))
        XCTAssertTrue(source.contains("DirectorOutlinedMenuField(value, height: DirectorSpacing.controlMinHeight)"))
    }

    private func readSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
