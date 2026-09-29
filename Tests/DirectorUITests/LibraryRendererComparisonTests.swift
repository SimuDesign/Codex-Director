#if DIRECTOR_INTERACTION_PERFORMANCE
import AppKit
import SwiftUI
import XCTest
@testable import DirectorUI

@MainActor
final class LibraryRendererComparisonTests: XCTestCase {
    func testSyntheticFixtureHasStableDistinctRowsAndNonselectableHeadings() {
        let items = LibraryRendererComparisonFixture.items(capabilityCount: 1_000)
        XCTAssertEqual(items.filter { $0.kind == .capability }.count, 1_000)
        XCTAssertEqual(items.filter { $0.kind == .heading }.count, 25)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertTrue(items.allSatisfy { $0.id.hasPrefix("synthetic-") })
        XCTAssertEqual(LibraryRendererComparisonFixture.items(capabilityCount: 1_000), items)
    }

    func testAppKitPrototypePreservesTableSelectionAndExcludesHeadings() {
        let items = LibraryRendererComparisonFixture.items(capabilityCount: 80)
        let fixture = WindowFixture(size: CGSize(width: 720, height: 480))
        var selectedID: String?
        var folderActionID: String?
        let binding = Binding<String?>(get: { selectedID }, set: { selectedID = $0 })
        fixture.show(LibraryRendererComparisonTable(items: items, selectedID: binding, onAddToFolder: { folderActionID = $0 }))
        defer { fixture.close() }

        guard let table = fixture.findTable() else {
            XCTFail("AppKit table was not installed")
            return
        }
        XCTAssertEqual(table.numberOfRows, 82)
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertFalse(table.delegate?.tableView?(table, shouldSelectRow: 0) ?? true)
        XCTAssertTrue(table.delegate?.tableView?(table, shouldSelectRow: 1) ?? false)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(selectedID, "synthetic-capability-0")
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertNotNil(table.view(atColumn: 0, row: 1, makeIfNecessary: true)?.accessibilityLabel())
        guard let table = table as? ComparisonTableView else {
            XCTFail("Prototype table subclass missing")
            return
        }
        XCTAssertNil(table.menuProvider?(0))
        let menu = table.menuProvider?(1)
        XCTAssertEqual(menu?.items.first?.title, "Add to folder")
        XCTAssertEqual(menu?.items.first?.isEnabled, true)
        if let item = menu?.items.first, let target = item.target, let action = item.action {
            _ = NSApp.sendAction(action, to: target, from: item)
        }
        XCTAssertEqual(folderActionID, "synthetic-capability-0")
    }

    func testAppKitPrototypeScrollsWithoutRealizingAllRows() {
        let items = LibraryRendererComparisonFixture.items(capabilityCount: 1_000)
        let fixture = WindowFixture(size: CGSize(width: 720, height: 480))
        fixture.show(LibraryRendererComparisonTable(items: items, selectedID: .constant(nil)))
        defer { fixture.close() }
        guard let table = fixture.findTable() else {
            XCTFail("AppKit table was not installed")
            return
        }
        XCTAssertEqual(table.numberOfRows, 1_025)
        let initial = table.rows(in: table.visibleRect)
        XCTAssertLessThan(initial.length, 30)
        table.scrollRowToVisible(table.numberOfRows - 1)
        fixture.settle()
        let final = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(final.location, 900)
        XCTAssertLessThan(final.length, 30)
    }

    func testFullPagePrototypeKeepsHeadingsUnselectableAndRoutesFolderAction() {
        let fixture = WindowFixture(size: CGSize(width: 720, height: 480))
        var selectedID: String?
        var toggled: (String, String, Bool)?
        let rows = [
            FullPageLibraryPrototypeRow(id: "synthetic-heading", height: 60, selectable: false, view: AnyView(Text("Synthetic group"))),
            FullPageLibraryPrototypeRow(id: "synthetic-capability", height: 96, selectable: true, view: AnyView(Text("Synthetic capability")))
        ]
        fixture.show(FullPageLibraryRendererPrototype(
            rows: rows,
            selectedID: Binding(get: { selectedID }, set: { selectedID = $0 }),
            folderOptions: { _ in [.init(id: "synthetic-folder", name: "Synthetic folder", included: false)] },
            onToggleFolder: { resourceID, folderID, included in toggled = (resourceID, folderID, included) }
        ))
        defer { fixture.close() }

        guard let table = fixture.findTable() as? FullPagePrototypeTable else {
            XCTFail("Full-page table was not installed")
            return
        }
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual(table.effectiveStyle, .plain)
        XCTAssertFalse(table.delegate?.tableView?(table, shouldSelectRow: 0) ?? true)
        XCTAssertTrue(table.delegate?.tableView?(table, shouldSelectRow: 1) ?? false)
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 0), 60)
        XCTAssertEqual(table.delegate?.tableView?(table, heightOfRow: 1), 96)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(selectedID, "synthetic-capability")
        XCTAssertNil(table.menuProvider?(0))
        let menu = table.menuProvider?(1)
        XCTAssertEqual(menu?.items.first?.title, "Synthetic folder")
        if let item = menu?.items.first, let target = item.target, let action = item.action {
            _ = NSApp.sendAction(action, to: target, from: item)
        }
        XCTAssertEqual(toggled?.0, "synthetic-capability")
        XCTAssertEqual(toggled?.1, "synthetic-folder")
        XCTAssertEqual(toggled?.2, true)
    }

    func testFullPagePrototypeArrowNavigationSkipsHeadingsAndExposesVisibleRows() {
        let fixture = WindowFixture(size: CGSize(width: 720, height: 480))
        var selectedID: String?
        let rows = [
            FullPageLibraryPrototypeRow(id: "synthetic-heading-one", height: 40, selectable: false, view: AnyView(Text("Group one"))),
            FullPageLibraryPrototypeRow(id: "synthetic-agent-one", height: 68, selectable: true, view: AnyView(Text("Synthetic Agent One"))),
            FullPageLibraryPrototypeRow(id: "synthetic-heading-two", height: 40, selectable: false, view: AnyView(Text("Group two"))),
            FullPageLibraryPrototypeRow(id: "synthetic-agent-two", height: 68, selectable: true, view: AnyView(Text("Synthetic Agent Two")))
        ]
        fixture.show(FullPageLibraryRendererPrototype(
            rows: rows,
            selectedID: Binding(get: { selectedID }, set: { selectedID = $0 })
        ))
        defer { fixture.close() }
        guard let table = fixture.findTable() as? FullPagePrototypeTable else {
            XCTFail("Full-page table was not installed")
            return
        }

        XCTAssertGreaterThan(table.accessibilityVisibleRows()?.count ?? 0, 0)
        XCTAssertTrue(fixture.focus(table))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(selectedID, "synthetic-agent-one")
        fixture.pressArrow(down: true)
        XCTAssertEqual(table.selectedRow, 3)
        XCTAssertEqual(selectedID, "synthetic-agent-two")
        fixture.pressArrow(down: false)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(selectedID, "synthetic-agent-one")
    }

    /// Opt-in diagnostic: measures root replacement through AppKit layout and
    /// display submission. It does NOT measure compositor first paint, actual
    /// pointer/keyboard input, or the full production library page.
    func testOptInRendererLayoutComparison() {
        guard ProcessInfo.processInfo.environment["DIRECTOR_RENDERER_COMPARISON"] == "1" else { return }
        _ = NSApplication.shared
        for count in [283, 1_000] {
            let items = LibraryRendererComparisonFixture.items(capabilityCount: count)
            for size in [CGSize(width: 720, height: 480), CGSize(width: 1280, height: 800)] {
                let list = measureRenderer(size: size, label: "swiftui-list") {
                    LibraryRendererComparisonList(items: items, selectedID: .constant(nil))
                }
                let table = measureRenderer(size: size, label: "appkit-table") {
                    LibraryRendererComparisonTable(items: items, selectedID: .constant(nil))
                }
                print("renderer_comparison capabilities=\(count) viewport=\(Int(size.width))x\(Int(size.height)) " +
                      "list_first_ms=\(format(list.first)) list_p50_ms=\(format(list.p50)) list_p95_ms=\(format(list.p95)) " +
                      "table_first_ms=\(format(table.first)) table_p50_ms=\(format(table.p50)) table_p95_ms=\(format(table.p95)) " +
                      "measurement=layout_and_display_submission_only")
            }
        }
    }

    func testOptInSyntheticAppearanceSnapshots() throws {
        guard ProcessInfo.processInfo.environment["DIRECTOR_RENDERER_SNAPSHOTS"] == "1" else { return }
        let items = LibraryRendererComparisonFixture.items(capabilityCount: 80)
        let directory = URL(fileURLWithPath: "/tmp/codex-director-renderer-prototype", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let list = WindowFixture(size: CGSize(width: 720, height: 480))
            list.appearance = NSAppearance(named: appearance)
            list.show(LibraryRendererComparisonList(items: items, selectedID: .constant(nil)))
            try list.capture(to: directory.appendingPathComponent("list-\(name).png"))
            list.close()

            let table = WindowFixture(size: CGSize(width: 720, height: 480))
            table.appearance = NSAppearance(named: appearance)
            table.show(LibraryRendererComparisonTable(items: items, selectedID: .constant(nil)))
            try table.capture(to: directory.appendingPathComponent("table-\(name).png"))
            table.close()
        }
    }

    private struct Distribution {
        let first: Double
        let p50: Double
        let p95: Double
    }

    private func measureRenderer<Content: View>(
        size: CGSize,
        label: String,
        @ViewBuilder view: () -> Content
    ) -> Distribution {
        let fixture = WindowFixture(size: size)
        defer { fixture.close() }
        var samples: [Double] = []
        for _ in 0..<31 {
            let start = DispatchTime.now().uptimeNanoseconds
            fixture.show(view())
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            fixture.clear()
        }
        let warm = Array(samples.dropFirst()).sorted()
        XCTAssertEqual(warm.count, 30, label)
        return Distribution(first: samples[0], p50: warm[14], p95: warm[28])
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

@MainActor
private final class WindowFixture {
    private let window: NSWindow
    var appearance: NSAppearance? {
        get { window.appearance }
        set { window.appearance = newValue }
    }

    init(size: CGSize) {
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Synthetic renderer comparison"
    }

    func show<Content: View>(_ view: Content) {
        let host = NSHostingView(rootView: view)
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.orderFront(nil)
        settle()
    }

    func clear() {
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        settle()
    }

    func findTable() -> NSTableView? {
        func walk(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let match = walk(child) { return match }
            }
            return nil
        }
        return window.contentView.flatMap(walk)
    }

    func close() { window.close() }

    func focus(_ view: NSView) -> Bool { window.makeFirstResponder(view) }

    func pressArrow(down: Bool) {
        let arrow = String(UnicodeScalar(down ? 0xF701 : 0xF700)!)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: arrow,
            charactersIgnoringModifiers: arrow,
            isARepeat: false,
            keyCode: down ? 125 : 126
        ) else { return }
        window.sendEvent(event)
        settle()
    }

    func capture(to url: URL) throws {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw NSError(domain: "SyntheticRendererSnapshot", code: 1)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SyntheticRendererSnapshot", code: 2)
        }
        try data.write(to: url, options: .atomic)
    }

    func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}
#endif
