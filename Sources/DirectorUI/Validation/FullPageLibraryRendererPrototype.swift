#if DIRECTOR_INTERACTION_PERFORMANCE
import AppKit
import SwiftUI

/// Diagnostic-only full-page host for the existing library header, controls,
/// groups and capability row views. The regular app never compiles this file.
@MainActor
struct FullPageLibraryPrototypeRow {
    let id: String
    let height: CGFloat
    let selectable: Bool
    let view: AnyView
}

@MainActor
struct FullPageLibraryRendererPrototype: NSViewRepresentable {
    struct FolderOption {
        let id: String
        let name: String
        let included: Bool
    }

    let rows: [FullPageLibraryPrototypeRow]
    @Binding var selectedID: String?
    var folderOptions: ((String) -> [FolderOption])?
    var onToggleFolder: ((String, String, Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, selectedID: $selectedID, folderOptions: folderOptions, onToggleFolder: onToggleFolder)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FullPagePrototypeTable()
        // The parent supplies the full page gutter. Plain adds no implicit
        // table inset, unlike automatic/inset or the production SwiftUI List.
        table.style = .plain
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menuProvider = { row in context.coordinator.menu(for: row) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        table.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? FullPagePrototypeTable else { return }
        let coordinator = context.coordinator
        coordinator.selectedID = $selectedID
        coordinator.folderOptions = folderOptions
        coordinator.onToggleFolder = onToggleFolder
        let oldShape = coordinator.rows.map { ($0.id, $0.height) }
        let newShape = rows.map { ($0.id, $0.height) }
        coordinator.rows = rows
        if oldShape.count != newShape.count || zip(oldShape, newShape).contains(where: { $0.0.0 != $0.1.0 || $0.0.1 != $0.1.1 }) {
            table.reloadData()
        } else {
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                for row in visible.location..<(visible.location + visible.length) where rows.indices.contains(row) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostedLibraryPrototypeCell)?
                        .configure(rows[row].view)
                }
            }
        }
        let selectedRow = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id && $0.selectable }) } ?? -1
        if table.selectedRow != selectedRow {
            coordinator.isUpdatingSelection = true
            table.selectRowIndexes(selectedRow < 0 ? IndexSet() : IndexSet(integer: selectedRow), byExtendingSelection: false)
            coordinator.isUpdatingSelection = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var rows: [FullPageLibraryPrototypeRow]
        fileprivate var selectedID: Binding<String?>
        fileprivate var folderOptions: ((String) -> [FolderOption])?
        fileprivate var onToggleFolder: ((String, String, Bool) -> Void)?
        fileprivate weak var table: FullPagePrototypeTable?
        fileprivate var isUpdatingSelection = false

        fileprivate init(
            rows: [FullPageLibraryPrototypeRow],
            selectedID: Binding<String?>,
            folderOptions: ((String) -> [FolderOption])?,
            onToggleFolder: ((String, String, Bool) -> Void)?
        ) {
            self.rows = rows
            self.selectedID = selectedID
            self.folderOptions = folderOptions
            self.onToggleFolder = onToggleFolder
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        // Heights are precomputed by the SwiftUI parent. Apple explicitly
        // warns against table geometry queries in this delegate callback.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows[row].height
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows[row].selectable
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("hosted-library-row")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? HostedLibraryPrototypeCell)
                ?? HostedLibraryPrototypeCell()
            cell.identifier = identifier
            cell.configure(rows[row].view)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            FullPagePrototypeRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection, let table else { return }
            let index = table.selectedRow
            selectedID.wrappedValue = rows.indices.contains(index) && rows[index].selectable ? rows[index].id : nil
        }

        fileprivate func menu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row), rows[row].selectable else { return nil }
            let id = rows[row].id
            guard let options = folderOptions?(id), !options.isEmpty, onToggleFolder != nil else { return nil }
            let menu = NSMenu()
            for option in options {
                let item = NSMenuItem(title: option.name, action: #selector(toggleFolder(_:)), keyEquivalent: "")
                item.target = self
                item.state = option.included ? .on : .off
                item.representedObject = [id, option.id, option.included ? "1" : "0"]
                menu.addItem(item)
            }
            return menu
        }

        @objc private func toggleFolder(_ sender: NSMenuItem) {
            guard let args = sender.representedObject as? [String], args.count == 3 else { return }
            onToggleFolder?(args[0], args[1], args[2] != "1")
        }
    }
}

@MainActor
private final class HostedLibraryPrototypeCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ view: AnyView) { host.rootView = view }
}

@MainActor
private final class FullPagePrototypeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // The hosted Scheme A row draws its own contained wash and outline.
    }
}

@MainActor
final class FullPagePrototypeTable: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? menuProvider?(row) : nil
    }
}
#endif
