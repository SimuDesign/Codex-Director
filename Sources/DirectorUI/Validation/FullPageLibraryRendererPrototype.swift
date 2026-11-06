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
    private let viewFactory: @MainActor () -> AnyView

    init(id: String, height: CGFloat, selectable: Bool, view: AnyView) {
        self.id = id
        self.height = height
        self.selectable = selectable
        self.viewFactory = { view }
    }

    init(id: String, height: CGFloat, selectable: Bool, makeView: @escaping @MainActor () -> AnyView) {
        self.id = id
        self.height = height
        self.selectable = selectable
        self.viewFactory = makeView
    }

    func resolvedView() -> AnyView { viewFactory() }
}

@MainActor
struct FullPageLibraryRendererPrototype: NSViewRepresentable {
    struct FolderOption {
        let id: String
        let name: String
        let included: Bool
    }

    let rows: [FullPageLibraryPrototypeRow]
    let viewportWidth: CGFloat
    let searchText: String
    @Binding var selectedID: String?
    var folderOptions: ((String) -> [FolderOption])?
    var onToggleFolder: ((String, String, Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, searchText: searchText, selectedID: $selectedID, folderOptions: folderOptions, onToggleFolder: onToggleFolder)
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        // Start at the layout's resolved width so SwiftUI does not first
        // measure hosted text and controls in a narrow default column.
        column.width = viewportWidth
        table.setFrameSize(NSSize(width: viewportWidth, height: 0))
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.menuProvider = { row in context.coordinator.menu(for: row) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? FullPagePrototypeTable else { return }
        let coordinator = context.coordinator
        coordinator.selectedID = $selectedID
        coordinator.folderOptions = folderOptions
        coordinator.onToggleFolder = onToggleFolder
        let oldRows = coordinator.rows
        let sameHeader = oldRows.first?.id == rows.first?.id && oldRows.first?.height == rows.first?.height
        // Replacing the hosted header while its TextField changes destroys
        // the field editor. Update the results without touching that cell.
        let preserveHeader = sameHeader && (coordinator.searchText != searchText || table.isEditingHeaderControl)
        let shapeChanged = oldRows.count != rows.count || zip(oldRows, rows).contains {
            $0.0.id != $0.1.id || $0.0.height != $0.1.height
        }
        coordinator.rows = rows
        coordinator.searchText = searchText
        coordinator.isUpdatingSelection = true
        defer { coordinator.isUpdatingSelection = false }

        if table.dataSource == nil {
            // Populate once, from the first update's latest snapshot.
            table.dataSource = coordinator
            table.reloadData()
        } else if shapeChanged {
            if preserveHeader, !oldRows.isEmpty, !rows.isEmpty {
                table.beginUpdates()
                table.removeRows(at: IndexSet(integersIn: 1..<oldRows.count), withAnimation: [])
                table.insertRows(at: IndexSet(integersIn: 1..<rows.count), withAnimation: [])
                table.endUpdates()
            } else {
                table.reloadData()
            }
        } else {
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                for row in visible.location..<(visible.location + visible.length)
                    where rows.indices.contains(row) && (!preserveHeader || row != 0) {
                    (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostedLibraryPrototypeCell)?
                        .configure(rows[row].resolvedView())
                }
            }
        }
        let selectedRow = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id && $0.selectable }) } ?? -1
        if table.selectedRow != selectedRow {
            table.selectRowIndexes(selectedRow < 0 ? IndexSet() : IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var rows: [FullPageLibraryPrototypeRow]
        fileprivate var searchText: String
        fileprivate var selectedID: Binding<String?>
        fileprivate var folderOptions: ((String) -> [FolderOption])?
        fileprivate var onToggleFolder: ((String, String, Bool) -> Void)?
        fileprivate weak var table: FullPagePrototypeTable?
        fileprivate var isUpdatingSelection = false

        fileprivate init(
            rows: [FullPageLibraryPrototypeRow],
            searchText: String,
            selectedID: Binding<String?>,
            folderOptions: ((String) -> [FolderOption])?,
            onToggleFolder: ((String, String, Bool) -> Void)?
        ) {
            self.rows = rows
            self.searchText = searchText
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
            cell.configure(rows[row].resolvedView())
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
        let sizing = ProcessInfo.processInfo.environment["CODEX_DIRECTOR_LIBRARY_FIXED_CELL_SIZING"]
        if sizing == "1" || sizing == "frame" {
            // The table fixes row heights and the enclosing cell fills the host.
            host.sizingOptions = []
        }
        if sizing == "frame" {
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            return
        }
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

    /// NSTableView normally validates first-responder changes by requiring the
    /// proposed control to belong to a selected row. The diagnostic header is
    /// intentionally unselectable, but its search/editor controls still need
    /// the native AppKit responder path.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if isEditableHeaderResponder(responder) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    var isEditingHeaderControl: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        return isEditableHeaderResponder(firstResponder)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? menuProvider?(row) : nil
    }

    private func editableHeaderControl() -> NSView? {
        guard numberOfRows > 0,
              let headerCell = view(atColumn: 0, row: 0, makeIfNecessary: false) else { return nil }
        return firstEditableTextControl(in: headerCell)
    }

    private func firstEditableTextControl(in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for child in view.subviews {
            if let match = firstEditableTextControl(in: child) {
                return match
            }
        }
        return nil
    }

    private func isEditableHeaderResponder(_ responder: NSResponder) -> Bool {
        guard isEditableTextResponder(responder) else { return false }
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
            if let field = editableHeaderControl() as? NSTextField, field.currentEditor() === fieldEditor {
                return true
            }
            if let delegate = fieldEditor.delegate as? NSView {
                return row(for: delegate) == 0
            }
        }
        guard let view = responder as? NSView else { return false }
        return row(for: view) == 0
    }

    private func isEditableTextResponder(_ responder: NSResponder) -> Bool {
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        return false
    }
}
#endif
