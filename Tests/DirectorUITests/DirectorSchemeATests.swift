import XCTest
import SwiftUI
import ImageIO
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

    func testCapabilityFolderDetailsDeduplicateProjectsAndForwardClassificationActions() throws {
        let first = CapabilityProject(id: "project:shared", name: "Shared project", lastSeenAt: Date(timeIntervalSince1970: 10))
        let duplicate = CapabilityProject(id: "project:shared", name: "Stale duplicate", lastSeenAt: Date(timeIntervalSince1970: 20))
        let other = CapabilityProject(id: "project:other", name: "Other project", lastSeenAt: Date(timeIntervalSince1970: 20))
        let projects = DirectorRootView.stableUniqueProjects(from: [first, duplicate, other])
        XCTAssertEqual(projects.map(\.id), ["project:other", "project:shared"])
        XCTAssertEqual(projects.last?.name, "Shared project")

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorRootView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("Self.stableUniqueProjects(from: model.libraryModels.flatMap(\\.projects))"))
        XCTAssertTrue(root.contains("onClassify: { id, ownership in self.model.classify(resourceID: id, ownership: ownership) }"))
        XCTAssertTrue(root.contains("onResetClassification: { id in self.model.resetClassification(resourceID: id) }"))
    }

    func testCapabilityFoldersUseResponsiveCardsAndPerFolderSessionState() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        XCTAssertTrue(folders.contains("LazyVGrid"))
        let entryHeaderStart = try XCTUnwrap(folders.range(of: "private func entryHeaderAndSearch"))
        let entryHeaderEnd = try XCTUnwrap(folders[entryHeaderStart.upperBound...].range(of: "private func entryTitleBlock")?.lowerBound)
        let entryHeader = String(folders[entryHeaderStart.lowerBound..<entryHeaderEnd])
        XCTAssertTrue(entryHeader.contains("if width >= DirectorCapabilityFolderLayout.entryInlineBreakpoint"))
        XCTAssertFalse(entryHeader.contains("ViewThatFits(in:"), "only one live search field may participate in the native accessibility graph")
        let folderFilterStart = try XCTUnwrap(folders.range(of: "private func folderFilterRow"))
        let folderFilterEnd = try XCTUnwrap(folders[folderFilterStart.upperBound...].range(of: "private func folderSearchField")?.lowerBound)
        let folderFilter = String(folders[folderFilterStart.lowerBound..<folderFilterEnd])
        XCTAssertFalse(folderFilter.contains("ViewThatFits(in:"), "switching tabs must not update competing native editors")
        let folderGridStart = try XCTUnwrap(folders.range(of: "private func folderGrid"))
        let folderGridEnd = folders[folderGridStart.upperBound...].range(of: "private func folderTitle")?.lowerBound ?? folders.endIndex
        let folderGrid = String(folders[folderGridStart.lowerBound..<folderGridEnd])
        XCTAssertTrue(
            folderGrid.contains("columns: DirectorCapabilityFolderLayout.gridItems(for: width)"),
            "folder grid uses the folder-local responsive layout in executable code"
        )
        XCTAssertTrue(folders.contains("folderSearchByKey"))
        XCTAssertTrue(folders.contains("folderTabByID"))
        XCTAssertTrue(folders.contains("folderSortByKey"))
        XCTAssertTrue(folders.contains("folderScrollPositionByKey"))
        XCTAssertTrue(folders.contains("selectedResourceIDByKey"))
        XCTAssertTrue(folders.contains("CapabilityFolderSessionKey"))
        XCTAssertTrue(folders.contains("capabilityCompanionUsageByRelationID"))
        XCTAssertTrue(folders.contains(".task(id: model.capabilityCompanionUsageGeneration)"), "companion evidence reload must follow projection generations")
        XCTAssertTrue(folders.contains("relatedSkillsSection"))
        XCTAssertTrue(folders.contains("relatedAgentsSection"))
        XCTAssertTrue(folders.contains("relationshipDeclarationText"))
        XCTAssertTrue(folders.contains("relation.kind == .requiresAgent"))
        XCTAssertTrue(folders.contains("relation.declarationSource"))
        XCTAssertTrue(folders.contains("stats.lastObservedAt"))
        XCTAssertTrue(folders.contains("stats.coverage"))
        XCTAssertTrue(folders.contains("Historical co-observation evidence"))
        XCTAssertTrue(folders.contains("Co-observation does not prove invocation."))
        XCTAssertTrue(folders.contains("entryScrollPosition"))
        XCTAssertTrue(folders.contains(".scrollPosition(id: activeScrollPosition, anchor: .top)"))
        XCTAssertTrue(folders.contains("guard model.directoryLoaded else { return \"—\" }"))
        XCTAssertTrue(folders.contains("capabilityFolders.empty.matches"))
        XCTAssertTrue(folders.contains("capabilityFolders.recentUsage"))
        XCTAssertTrue(folders.contains("CapabilityFolderImportSheet"))
        XCTAssertTrue(folders.contains("addCapabilitiesToFolder(resourceIDs:"))
        XCTAssertTrue(folders.contains("var collapsed = collapsedCompanionAgentIDs(for: folder.id)"), "disclosure toggles must mutate the current session set")
        XCTAssertTrue(folders.contains("sharedAgentsLabel(for: item.resource.id)"), "companion Skills expose shared-Agent context")
        XCTAssertTrue(folders.contains("relations.filter(\\.isPreview)"))
        XCTAssertTrue(folders.contains("capabilityFolders.companions.previewCount"), "preview-only relationships must not claim no relationship exists")
        XCTAssertTrue(folders.contains("localizedSummary(for: item.resource"), "companion Skills expose their purpose")
        XCTAssertFalse(folders.contains("companionUsageLabel(for:"), "co-observation evidence belongs only in detail")
        XCTAssertTrue(folders.contains("skillAgentLinkStatus(for: member.id, folderID: folder.id)"), "Skill rows expose concise reverse-link status")
        XCTAssertTrue(folders.contains("folderStatusBanner(width:"))
        XCTAssertTrue(folders.contains("pendingState(width:"))
        XCTAssertTrue(folders.contains("StrokeStyle(lineWidth: 1, dash: [6, 5])"))
        let skillRowStart = try XCTUnwrap(folders.range(of: "private func skillRelationshipRow"))
        let skillRowEnd = folders[skillRowStart.upperBound...].range(of: "private func companionPreviewLabel")?.lowerBound ?? folders.endIndex
        let skillRow = String(folders[skillRowStart.lowerBound..<skillRowEnd])
        XCTAssertFalse(skillRow.contains("ForEach"), "Skill tab remains a flat list")
        XCTAssertFalse(skillRow.contains("relatedAgents"), "reverse Agent links stay in detail")
        let memberRowStart = try XCTUnwrap(folders.range(of: "private func memberRow"))
        let memberRowEnd = folders[memberRowStart.upperBound...].range(of: "private func agentCompanionRow")?.lowerBound ?? folders.endIndex
        let memberRow = String(folders[memberRowStart.lowerBound..<memberRowEnd])
        let membershipOffset = try XCTUnwrap(memberRow.range(of: "folderMembershipMenu")?.lowerBound)
        let detailChevronOffset = try XCTUnwrap(memberRow.range(of: "Image(systemName: \"chevron.right\")")?.lowerBound)
        XCTAssertLessThan(membershipOffset, detailChevronOffset, "membership action precedes the final detail chevron")
        XCTAssertTrue(folders.contains("folder.isDefault"))
        XCTAssertTrue(folders.contains("folderTabs(for:"))
        XCTAssertFalse(folders.contains("projectTypeTabs(for:"))
        XCTAssertFalse(folders.contains("folderTypeFilterByID"))
        XCTAssertTrue(folders.contains("DirectorOutlinedSegmentedControl"))
        XCTAssertTrue(folders.contains("CapabilityFolderDropDelegate"))
        XCTAssertTrue(folders.contains("if folder.isCustom"))
        XCTAssertTrue(folders.contains("Global and Project are immutable derived views"))
        XCTAssertTrue(folders.contains("\\(scopeText(for: member.resource))"))
        XCTAssertTrue(folders.contains("\\(sourceText(for: member.resource))"))
        XCTAssertFalse(folders.contains("Text(\"(scopeText(for: member.resource))"))

        let english = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        let chinese = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        for key in [
            "capabilityFolders.empty.matches",
            "capabilityFolders.recentUsage",
            "capabilityFolders.import",
            "capabilityFolders.import.confirm",
            "capabilityFolders.tabs.label",
            "capabilityFolders.tabs.companions",
            "capabilityFolders.tabs.agents",
            "capabilityFolders.tabs.skills",
            "capabilityFolders.companions.companion",
            "capabilityFolders.companions.requiresAgent",
            "capabilityFolders.companions.source.registry",
            "capabilityFolders.companions.source.configuration",
            "capabilityFolders.companions.source.brief",
            "capabilityFolders.companions.source.description",
            "capabilityFolders.companions.historyGroup",
            "capabilityFolders.companions.coObservedShort",
            "capabilityFolders.companions.lastObserved",
            "capabilityFolders.companions.coverage.complete",
            "capabilityFolders.companions.coverage.partial",
            "capabilityFolders.companions.coverage.unknown",
            "capabilityFolders.companions.previewGlobal",
            "capabilityFolders.companions.previewOutside",
            "capabilityFolders.companions.noCausalClaim",
            "capabilityFolders.companions.sharedAgents",
            "capabilityFolders.companions.agentLinksRecorded",
            "capabilityFolders.companions.noAgentLinksRecorded",
            "capabilityFolders.status.updating",
            "capabilityFolders.status.failed",
            "capabilityFolders.status.stale",
            "capabilityFolders.status.retry",
            "capabilityFolders.pending",
        ] {
            XCTAssertTrue(english.contains("\"\(key)\""), "missing English folder state key \(key)")
            XCTAssertTrue(chinese.contains("\"\(key)\""), "missing Chinese folder state key \(key)")
        }
    }

    func testCapabilityFolderLocalLayoutMatchesApprovedResponsiveContract() {
        XCTAssertEqual(DirectorCapabilityFolderLayout.maxContentWidth, 1_280)
        XCTAssertEqual(DirectorCapabilityFolderLayout.horizontalPadding(for: 1_280), 40)
        XCTAssertEqual(DirectorCapabilityFolderLayout.horizontalPadding(for: 759), 16)

        // Column decisions use the available folder viewport, rather than the
        // capped content measure. This keeps the four-column desktop state
        // reachable on wide windows while preserving the 1280pt visual cap.
        XCTAssertEqual(DirectorCapabilityFolderLayout.columns(for: 1_440), 4)
        XCTAssertEqual(DirectorCapabilityFolderLayout.columns(for: 901), 3)
        XCTAssertEqual(DirectorCapabilityFolderLayout.columns(for: 900), 2)
        XCTAssertEqual(DirectorCapabilityFolderLayout.columns(for: 561), 2)
        XCTAssertEqual(DirectorCapabilityFolderLayout.columns(for: 560), 1)

        XCTAssertEqual(DirectorCapabilityFolderLayout.cardHeight(for: 1_000), 128)
        XCTAssertEqual(DirectorCapabilityFolderLayout.cardHeight(for: 759), 120)
        XCTAssertEqual(DirectorCapabilityFolderLayout.cardHeight(for: 560), 112)
        XCTAssertEqual(DirectorCapabilityFolderLayout.gridItems(for: 1_520).count, 4)
    }

    func testCapabilityFolderVisualRepairUsesAlignedStructuralRowsAndNamedRhythm() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        let scheme = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift"), encoding: .utf8)
        let spacing = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSpacing.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DataStatus/SettingsView.swift"), encoding: .utf8)

        XCTAssertTrue(folders.contains("structuralRow("), "folder headings must share common scroll-content gutters with their content")
        XCTAssertFalse(folders.contains("Section {"), "folder headings must not use native Section header geometry")
        for token in [
            "entrySectionGap",
            "sectionContentGap",
            "sectionGap",
            "headerTabsGap",
            "tabsFilterGap",
            "filterContentGap",
            "pageBottomPadding",
        ] {
            XCTAssertTrue(spacing.contains("public static let \(token)"), "missing named folder rhythm token \(token)")
        }
        XCTAssertTrue(folders.contains("DirectorOutlinedSegmentedControl"))
        XCTAssertTrue(folders.contains("DirectorOutlinedMenuField"))
        XCTAssertTrue(folders.contains("DirectorOutlinedIconMenu"))
        XCTAssertFalse(folders.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(settings.contains("DirectorOutlinedSegmentedControl"))
        XCTAssertFalse(settings.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(scheme.contains("public struct DirectorOutlinedSegmentedControl"))
        XCTAssertTrue(scheme.contains("public struct DirectorOutlinedIconMenu"))
        XCTAssertTrue(scheme.contains("public struct DirectorOutlinedMenuField"))
        XCTAssertFalse(scheme.contains(".accessibilityRepresentation"), "single choice must be a live native control, not a hidden replica")
        XCTAssertTrue(scheme.contains("DirectorNativeSegmentedControlBridge: NSViewRepresentable"))
        XCTAssertTrue(scheme.contains("DirectorNativeOutlinedSegmentedControl: NSSegmentedControl"))
        XCTAssertTrue(scheme.contains("trackingMode = .selectOne"))
        XCTAssertTrue(scheme.contains("segmentDistribution = .fillEqually"))
        XCTAssertTrue(scheme.contains("focusRingType = .exterior"))
        XCTAssertTrue(scheme.contains(".menuStyle(.button)"))
        XCTAssertTrue(scheme.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(scheme.contains(".menuIndicator(.hidden)"))
        XCTAssertTrue(scheme.contains("NSGradient(colors: [NSColor(DirectorColor.accentBlue), NSColor(DirectorColor.accentIce), NSColor(DirectorColor.accentMint)])"))
    }

    func testOutlinedControlsKeepReadableNativeSizeAndConstruct() {
        XCTAssertEqual(DirectorTypography.segmentedControl, .system(size: 13, weight: .regular))
        XCTAssertEqual(DirectorCapabilityFolderLayout.controlHeight, 36)
        XCTAssertEqual(DirectorCapabilityFolderLayout.iconMenuTarget, 28)
        _ = DirectorOutlinedSegmentedControl(
            "Capability view",
            selection: .constant(0),
            options: [
                .init(value: 0, title: "Agent & Companion Skills"),
                .init(value: 1, title: "Agents —"),
                .init(value: 2, title: "Skills —"),
            ]
        )
        _ = DirectorOutlinedMenuField("Name A–Z") { Button("Name A–Z") { } }
        _ = DirectorOutlinedIconMenu(systemImage: "folder.badge.plus") { Button("Synthetic folder") { } }
    }

    func testNativeOutlinedSegmentsKeepNativeSelectionAndWrappedEqualHeight() {
        let control = DirectorNativeOutlinedSegmentedControl(frame: .zero)
        control.segmentCount = 3
        control.setLabel("Agent & Companion Skills", forSegment: 0)
        control.setLabel("Agents —", forSegment: 1)
        control.setLabel("Skills —", forSegment: 2)
        control.selectedSegment = 0
        XCTAssertEqual(control.trackingMode, .selectOne)
        XCTAssertEqual(control.segmentDistribution, .fillEqually)
        XCTAssertEqual(control.font?.pointSize, 13)
        XCTAssertTrue(control.isSelected(forSegment: 0))
        XCTAssertFalse(control.isSelected(forSegment: 1))
        XCTAssertGreaterThan(control.fittingSize(forWidth: 260).height, control.fittingSize(forWidth: 620).height)
        let wrappedHeight = control.fittingSize(forWidth: 260).height
        var activatedIndex: Int?
        control.selectionChanged = { activatedIndex = $0 }
        control.selectedSegment = 2
        XCTAssertEqual(control.fittingSize(forWidth: 260).height, wrappedHeight)
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        XCTAssertEqual(activatedIndex, 2)
        XCTAssertTrue(control.isSelected(forSegment: 2))
        XCTAssertFalse(control.isSelected(forSegment: 0))
    }

    func testNativeOutlinedThemeSegmentsReserveUnconstrainedTextTolerance() {
        for titles in [["Light", "Dark"], ["浅色", "深色"]] {
            let control = DirectorNativeOutlinedSegmentedControl(frame: .zero)
            control.segmentCount = titles.count
            for (index, title) in titles.enumerated() { control.setLabel(title, forSegment: index) }
            control.selectedSegment = 0
            let size = control.fittingSize(forWidth: nil)
            let padding = DirectorSpacing.space1
            let textWidth = (size.width - padding * 2 - padding * CGFloat(titles.count - 1)) / CGFloat(titles.count) - DirectorSpacing.space2 * 2
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            for title in titles {
                let text = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .paragraphStyle: paragraph
                ])
                let measured = text.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                XCTAssertGreaterThanOrEqual(textWidth, measured.width.rounded(.up) + padding)
                let allocated = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
                XCTAssertEqual(allocated.height.rounded(.up), measured.height.rounded(.up), "unconstrained \(title) must remain one line")
            }
            XCTAssertEqual(size.height, DirectorCapabilityFolderLayout.segmentHeight + padding * 2)
            XCTAssertGreaterThan(control.fittingSize(forWidth: 80).height, size.height, "explicitly narrow controls still wrap at 13pt")
        }
    }

    func testFolderStructuralAndHeaderRowsContainTheirTrueActionChildren() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        for (startMarker, endMarker) in [
            ("private func structuralRow<", "private func entrySectionGap"),
            ("private func folderHeader(", "private func folderTitleBlock("),
        ] {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(source[start.upperBound...].range(of: endMarker)?.lowerBound)
            let row = String(source[start.lowerBound..<end])
            XCTAssertTrue(row.contains(".accessibilityElement(children: .contain)"), "\(startMarker) must preserve real child controls")
            XCTAssertFalse(row.contains(".accessibilityAction"), "the aggregate row must not impersonate a child Button")
        }
        XCTAssertTrue(source.contains("Label(t(\"capabilityFolders.add\", \"New folder\"), systemImage: \"plus\")"))
        XCTAssertTrue(source.contains("createName = \"\""))
        XCTAssertTrue(source.contains("showsCreateSheet = true"))
        XCTAssertTrue(source.contains("selectedFolderID = nil"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(.isHeader)"))
    }

    func testFolderScrollContainerPreservesFullGuttersAndNestedStableTargets() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        let bodyStart = try XCTUnwrap(folders.range(of: "public var body: some View"))
        let bodyEnd = try XCTUnwrap(folders[bodyStart.upperBound...].range(of: "private func entryPage")?.lowerBound)
        let body = String(folders[bodyStart.lowerBound..<bodyEnd])
        XCTAssertEqual(body.components(separatedBy: "ScrollView(.vertical)").count - 1, 1)
        XCTAssertFalse(body.contains("List {"))
        XCTAssertTrue(body.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        XCTAssertTrue(body.contains(".frame(maxWidth: DirectorCapabilityFolderLayout.maxContentWidth, alignment: .leading)"))
        XCTAssertTrue(body.contains(".padding(.horizontal, DirectorCapabilityFolderLayout.horizontalPadding(for: proxy.size.width))"))
        XCTAssertTrue(body.contains(".scrollPosition(id: activeScrollPosition, anchor: .top)"))
        XCTAssertFalse(body.contains(".scrollTargetLayout()"), "an outer primary target layout would disable nested resource targets")
        XCTAssertFalse(folders.contains(".id(\"folder-content-"), "the whole grouped stage must not replace its individual resource targets")
        for (startMarker, endMarker, headerCall) in [
            ("private func entryPage", "private func folderPage", "entryHeaderAndSearch(width: width)"),
            ("private func folderPage", "private func folderStatusBanner", "folderHeader(folder, width: width)"),
        ] {
            let start = try XCTUnwrap(folders.range(of: startMarker))
            let end = try XCTUnwrap(folders[start.upperBound...].range(of: endMarker)?.lowerBound)
            let page = String(folders[start.lowerBound..<end])
            XCTAssertTrue(page.contains("VStack(alignment: .leading, spacing: 0) {\n            \(headerCall)\n        }\n        .scrollTargetLayout()"), "the context's stable top child needs its own sibling target layout")
        }
        XCTAssertTrue(body.contains(".overlay(alignment: .trailing)"))
        XCTAssertFalse(folders.contains("rowInsets(for:"), "native List's minus-8 compensation must not survive in ScrollView")
        XCTAssertEqual(folders.components(separatedBy: ".padding(.bottom, DirectorCapabilityFolderLayout.pageBottomPadding)").count - 1, 1)
        for (startMarker, endMarker) in [
            ("private func memberListPanel", "private func companionListPanel"),
            ("private func companionListPanel", "private func memberRow"),
        ] {
            let start = try XCTUnwrap(folders.range(of: startMarker))
            let end = try XCTUnwrap(folders[start.upperBound...].range(of: endMarker)?.lowerBound)
            let stage = String(folders[start.lowerBound..<end])
            XCTAssertTrue(stage.contains(".scrollTargetLayout()"), "independent grouped stages must discover their resource targets")
            XCTAssertTrue(stage.contains(".id(member.id)"), "scroll restoration must address individual resources, not just the outer stage")
        }
        XCTAssertTrue(folders.contains("folderScrollPositionByKey[key]"))
        XCTAssertTrue(folders.contains("?? \"capability-folder-top-\\(key.folderID)-\\(key.tab.rawValue)\""), "first visits must use their own stable top instead of inheriting another context's offset")
        XCTAssertTrue(folders.contains(".id(\"capability-folder-top-\\(folder.id)-\\(currentFolderTab(for: folder.id).rawValue)\")"))
        XCTAssertTrue(folders.contains(".padding(.top, width < DirectorCapabilityFolderLayout.compactBreakpoint ? DirectorSpacing.space4 : DirectorSpacing.space6)"))
        XCTAssertTrue(folders.contains("List(filteredResources)"), "the separate native import sheet is not part of the container exception")
    }

    func testFolderScrollBindingCapturesItsContextAndRetainsValidTargets() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(folders.range(of: "private var activeScrollPosition: Binding<String?>"))
        let end = try XCTUnwrap(folders[start.upperBound...].range(of: "private func structuralRow<")?.lowerBound)
        let binding = String(folders[start.lowerBound..<end])
        XCTAssertTrue(binding.contains("let key = selectedFolderID.map { sessionKey(for: $0) }\n        return Binding("), "the callback must retain its original folder/tab key")
        XCTAssertTrue(binding.contains("guard let value else { return }"), "transition nil must not overwrite a saved entry/folder target")
        XCTAssertTrue(binding.contains("entryScrollPosition = value"))
        XCTAssertTrue(binding.contains("folderScrollPositionByKey[key] = value"))
        XCTAssertFalse(binding.contains("sessionKey(for: selectedFolderID)"), "a delayed callback must not resolve whichever tab happens to be active now")
    }

    func testCapabilityFolderVisualContractUsesLocalPresentationPrimitives() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertEqual(DirectorSidebarItem.approvedNavigation.map(\.rawValue), [
            "home", "capabilityFolders", "customAgents", "customSkills",
            "installedSkills", "installedPlugins", "settings"
        ])
        let folders = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        XCTAssertTrue(folders.contains("entryHeaderAndSearch(width:"))
        XCTAssertTrue(folders.contains("folderFilterRow(for:"))
        XCTAssertTrue(folders.contains("companionListPanel"))
        XCTAssertTrue(folders.contains("folderDetailContext(for:"))
        XCTAssertTrue(folders.contains("contextualContent: AnyView"))
        XCTAssertTrue(folders.contains("folderGlobalSurface"))
        XCTAssertTrue(folders.contains("controlBoundary"))
        XCTAssertTrue(folders.contains("unrepresentedHint"))
        XCTAssertTrue(folders.contains("folderActions(folder)"))
        XCTAssertFalse(folders.contains("07 / Capability Folders"))

        // The detail overlay must occupy the full list viewport so its scrim
        // covers the content while the sheet itself stays pinned to trailing.
        // A ViewBuilder returning scrim + sheet siblings would size the
        // overlay to the sheet and center it in a wide window.
        let detailSheetStart = try XCTUnwrap(folders.range(of: "@ViewBuilder private func detailSheet"))
        let detailSheetEnd = folders[detailSheetStart.upperBound...].range(of: "private func folderDetailContext")?.lowerBound ?? folders.endIndex
        let detailSheet = String(folders[detailSheetStart.lowerBound..<detailSheetEnd])
        XCTAssertTrue(detailSheet.contains("ZStack(alignment: .trailing)"))
        XCTAssertTrue(detailSheet.contains(".ignoresSafeArea()"))
        XCTAssertTrue(detailSheet.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)"))
        XCTAssertTrue(folders.contains("detailSheet(width: proxy.size.width)"))

        let detail = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(detail.contains("identity\n            if let contextualContent { contextualContent }\n            usage; evidenceControl"))

        for key in [
            "capabilityFolders.companions.unrepresentedHint",
            "capabilityFolders.companions.unrepresentedHintAX"
        ] {
            let english = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
            let chinese = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
            XCTAssertTrue(english.contains("\"\(key)\""), "missing English local folder state key \(key)")
            XCTAssertTrue(chinese.contains("\"\(key)\""), "missing Chinese local folder state key \(key)")
        }
    }

    func testCapabilityFolderReorderGuardsDerivedFoldersAndInvalidIndexes() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift"), encoding: .utf8)
        let model = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorAppModel.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("if folder.isCustom"))
        XCTAssertTrue(view.contains("folders.filter(\\.isCustom).map(\\.id)"))
        XCTAssertTrue(model.contains("offsets.allSatisfy({ $0 >= 0 && $0 < folders.count })"))
        XCTAssertTrue(model.contains("destination <= folders.count"))
        XCTAssertTrue(model.contains("$0.id == id && $0.isCustom"))
    }

    func testCapabilityMembershipMenuIsConnectedToAllAgentAndSkillLibraries() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift"), encoding: .utf8)
        let root = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorRootView.swift"), encoding: .utf8)
        XCTAssertTrue(library.contains("resource.kind == .agent || resource.kind == .skill"))
        XCTAssertTrue(library.contains("folderMembershipMenu(for: row.entry.resource)"))
        XCTAssertTrue(library.contains("folderDefinitions.filter(\\.isCustom)"))
        XCTAssertTrue(root.contains("folderDefinitions: self.model.capabilityFolders.folders"))
        XCTAssertTrue(root.contains("onToggleFolderMembership:"))
    }

    func testFolderNavigationUsesNewPublicKeyAndLegacyDeepLinkOnlyMaps() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let destination = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/AppShell/DirectorDestination.swift"), encoding: .utf8)
        XCTAssertTrue(destination.contains("case capabilityFolders"))
        XCTAssertTrue(destination.contains("if rawValue == \"capabilityGroups\""))
        XCTAssertFalse(destination.contains("case capabilityGroups"))
    }

    func testUnpublishedGroupingImplementationIsNotBuilt() {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Sources/DirectorCore/Grouping/CapabilityGrouping.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Sources/DirectorUI/Capabilities/CapabilityGroupsView.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Tests/DirectorCoreTests/Grouping/CapabilityGroupingTests.swift").path))
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
        XCTAssertTrue(settings.contains("DirectorOutlinedSegmentedControl"))
        XCTAssertTrue(settings.contains("settings.about.title"))
        XCTAssertTrue(settings.contains("settings.author"))
        XCTAssertTrue(settings.contains("七木 Simu"))
        XCTAssertTrue(settings.contains("return version ?? \"1.3.1\""))
        XCTAssertFalse(settings.contains("1.3.1 (26)"))
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
        XCTAssertTrue(source.contains("actionBlue = dynamic"))
        XCTAssertTrue(source.contains("actionIce = dynamic"))
        XCTAssertTrue(source.contains("actionMint = dynamic"))
        XCTAssertTrue(source.contains("primaryActionForeground = dynamic(light: .white, dark: .black)"))
        XCTAssertFalse(source.contains("TODO"))
    }

    func testResolvedPrimaryActionTextMeetsContrastAcrossEveryGradientState() throws {
        let rails: [[Color]] = [
            [DirectorColor.actionBlue, DirectorColor.actionIce, DirectorColor.actionMint],
            [DirectorColor.actionHoverBlue, DirectorColor.actionHoverIce, DirectorColor.actionHoverMint],
            [DirectorColor.actionPressedBlue, DirectorColor.actionPressedIce, DirectorColor.actionPressedMint],
            [DirectorColor.actionDisabledBlue, DirectorColor.actionDisabledIce, DirectorColor.actionDisabledMint],
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let foreground = try resolvedRGB(DirectorColor.primaryActionForeground, appearance: appearance)
            for rail in rails {
                let stops = try rail.map { try resolvedRGB($0, appearance: appearance) }
                for pair in zip(stops, stops.dropFirst()) {
                    for sample in 0...100 {
                        let amount = Double(sample) / 100
                        let background = (
                            pair.0.0 + (pair.1.0 - pair.0.0) * amount,
                            pair.0.1 + (pair.1.1 - pair.0.1) * amount,
                            pair.0.2 + (pair.1.2 - pair.0.2) * amount
                        )
                        XCTAssertGreaterThanOrEqual(contrastRatio(foreground, background), 4.5)
                    }
                }
            }
        }
    }

    func testResolvedSupportingAndSmallDataTextMeetContrastOnRealSurfaces() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for foreground in [DirectorColor.textSupporting, DirectorColor.dataText] {
                let resolvedForeground = try resolvedRGB(foreground, appearance: appearance)
                for background in [DirectorColor.canvas, DirectorColor.panel] {
                    let resolvedBackground = try resolvedRGB(background, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(contrastRatio(resolvedForeground, resolvedBackground), 4.5)
                }
            }
        }
    }

    func testEveryGradientActionConsumerUsesTheSharedForegroundToken() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scheme = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift"), encoding: .utf8)
        XCTAssertTrue(scheme.contains(".foregroundStyle(DirectorColor.primaryActionForeground)"))
        XCTAssertTrue(scheme.contains("DirectorGradient.primaryAction(state: actionState)"))
        XCTAssertFalse(scheme.contains(".opacity(visuallyActive ?"))

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
        XCTAssertTrue(project.contains("MARKETING_VERSION: 1.3.1"))
        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 26"))
        XCTAssertEqual(pbxproj.components(separatedBy: "MARKETING_VERSION = 1.3.1").count - 1, 2)
        XCTAssertEqual(pbxproj.components(separatedBy: "CURRENT_PROJECT_VERSION = 26").count - 1, 2)
        XCTAssertTrue(buildScript.contains("verify-app-bundle.sh"))
        XCTAssertTrue(appVerifier.contains("read-project-version.sh"))
        XCTAssertTrue(appVerifier.contains("short_version\" == \"$expected_marketing_version\""))
        XCTAssertTrue(appVerifier.contains("build_version\" == \"$expected_build_version\""))
        XCTAssertTrue(harness.contains("MARKETING_VERSION: 0.2.1"))
        XCTAssertTrue(harness.contains("CURRENT_PROJECT_VERSION: 4"))
    }

    func testVersionAndExportCopyAreSynchronizedAcrossPublicSources() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(contentsOf: sourceRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let pbxproj = try String(contentsOf: sourceRoot.appendingPathComponent("CodexDirector.xcodeproj/project.pbxproj"), encoding: .utf8)
        let readClient = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorCore/MenuBar/CodexAccountUsageReading.swift"), encoding: .utf8)
        let validation = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/DirectorUI/Validation/UIValidationSession.swift"), encoding: .utf8)
        let changelog = try String(contentsOf: sourceRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let readme = try String(contentsOf: sourceRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeChinese = try String(contentsOf: sourceRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        XCTAssertTrue(project.contains("MARKETING_VERSION: 1.3.1"))
        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: 26"))
        XCTAssertEqual(pbxproj.components(separatedBy: "MARKETING_VERSION = 1.3.1").count - 1, 2)
        XCTAssertEqual(pbxproj.components(separatedBy: "CURRENT_PROJECT_VERSION = 26").count - 1, 2)
        XCTAssertTrue(readClient.contains("requestPayload(version: \"1.2.0\")"))
        XCTAssertTrue(validation.contains("CapabilityPackageProducer(version: \"1.2.0\", build: \"24\")"))
        XCTAssertTrue(changelog.contains("## 1.1.1"))
        XCTAssertTrue(changelog.contains("## 1.1.0"))
        XCTAssertTrue(changelog.contains("## 1.0.0"))
        XCTAssertTrue(readme.contains("1.3.1"))
        XCTAssertTrue(readmeChinese.contains("1.3.1"))
        XCTAssertFalse(readme.contains("1.3.1 (26)"))
        XCTAssertFalse(readmeChinese.contains("1.3.1 (26)"))

        for relativePath in [
            "Sources/DirectorUI/Resources/en.lproj/Localizable.strings",
            "Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings",
        ] {
            let localization = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            let line = try XCTUnwrap(localization.split(separator: "\n").first { $0.contains("\"settings.migration.export\"") })
            XCTAssertFalse(line.contains("…"))
            XCTAssertFalse(line.contains("..."))
        }
    }

    func testPublicSyntheticScreenshotsHaveReviewedDimensionsAndRegistration() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let screenshotNames = [
            "home-en-light.png", "agents-en-light.png", "settings-en-dark.png",
            "home-zh-dark.png", "agents-zh-light.png", "settings-zh-light.png",
        ]
        let inventory = try String(contentsOf: sourceRoot.appendingPathComponent("docs/public-asset-inventory.md"), encoding: .utf8)
        let license = try String(contentsOf: sourceRoot.appendingPathComponent("ASSETS_LICENSE.md"), encoding: .utf8)
        let englishREADME = try String(contentsOf: sourceRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let chineseREADME = try String(contentsOf: sourceRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        for name in screenshotNames {
            let url = sourceRoot.appendingPathComponent("docs/screenshots").appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing public screenshot \(name)")
            XCTAssertLessThan(try Data(contentsOf: url).count, 5 * 1024 * 1024, "screenshot exceeds the public asset limit")
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                XCTFail("unable to decode public screenshot \(name)")
                continue
            }
            XCTAssertEqual(image.width, 1280, "screenshot width must match the product viewport")
            XCTAssertEqual(image.height, 800, "screenshot height must match the product viewport")
            XCTAssertTrue(inventory.contains("docs/screenshots/\(name)"), "asset inventory missing \(name)")
            XCTAssertTrue(license.contains("docs/screenshots/"), "asset license must cover synthetic screenshots")
            let readme = name.contains("-zh-") ? chineseREADME : englishREADME
            XCTAssertTrue(readme.contains("docs/screenshots/\(name)"), "README missing screenshot reference \(name)")
        }
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func resolvedRGB(_ color: Color, appearance: NSAppearance.Name) throws -> (Double, Double, Double) {
        let appearance = try XCTUnwrap(NSAppearance(named: appearance))
        var result: (Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
            result = (Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent))
        }
        return try XCTUnwrap(result)
    }

    private func contrastRatio(_ first: (Double, Double, Double), _ second: (Double, Double, Double)) -> Double {
        let firstLuminance = relativeLuminance(red: first.0, green: first.1, blue: first.2)
        let secondLuminance = relativeLuminance(red: second.0, green: second.1, blue: second.2)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }
}
