#if DIRECTOR_INTERACTION_PERFORMANCE
import AppKit
import SwiftUI

/// Disposable, synthetic-only renderer experiment. This is deliberately not
/// connected to any production capability page or persistence boundary.
public struct LibraryRendererComparisonItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        case capability
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let purpose: String
    public let usage: String

    public init(id: String, kind: Kind, title: String, purpose: String = "", usage: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.purpose = purpose
        self.usage = usage
    }
}

public enum LibraryRendererComparisonFixture {
    /// The same immutable rows feed both renderers. All strings are invented
    /// here and never derive from the current user's capability inventory.
    public static func items(capabilityCount: Int) -> [LibraryRendererComparisonItem] {
        let count = min(max(capabilityCount, 0), 1_000)
        var items: [LibraryRendererComparisonItem] = []
        items.reserveCapacity(count + (count + 39) / 40)
        for index in 0..<count {
            if index.isMultiple(of: 40) {
                let group = index / 40 + 1
                items.append(.init(id: "synthetic-group-\(group)", kind: .heading, title: "Synthetic Project \(group)"))
            }
            items.append(.init(
                id: "synthetic-capability-\(index)",
                kind: .capability,
                title: "Synthetic Capability \(index + 1)",
                purpose: "A synthetic purpose used only to compare native row layout and scrolling.",
                usage: "\(index % 13) calls"
            ))
        }
        return items
    }
}

/// A small SwiftUI List reference with the same rows, typography hierarchy,
/// and fixed row heights as the AppKit candidate. It is not the complete
/// production library page, so its timings cannot be substituted for the
/// four-destination navigation results.
public struct LibraryRendererComparisonList: View {
    public let items: [LibraryRendererComparisonItem]
    @Binding public var selectedID: String?

    public init(items: [LibraryRendererComparisonItem], selectedID: Binding<String?>) {
        self.items = items
        _selectedID = selectedID
    }

    public var body: some View {
        List(selection: $selectedID) {
            ForEach(items) { item in
                if item.kind == .heading {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Spacer(minLength: 8)
                            Text(item.usage).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(item.purpose)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .tag(item.id)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// View-based NSTableView candidate. Native table selection, arrow-key
/// behavior, scroll virtualization and row AX structure remain exposed for
/// comparison; production List stays unchanged.
public struct LibraryRendererComparisonTable: NSViewRepresentable {
    public let items: [LibraryRendererComparisonItem]
    @Binding public var selectedID: String?
    public var onAddToFolder: ((String) -> Void)?

    public init(items: [LibraryRendererComparisonItem], selectedID: Binding<String?>, onAddToFolder: ((String) -> Void)? = nil) {
        self.items = items
        _selectedID = selectedID
        self.onAddToFolder = onAddToFolder
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(items: items, selectedID: $selectedID, onAddToFolder: onAddToFolder)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let table = ComparisonTableView()
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("capability")))
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

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ComparisonTableView else { return }
        context.coordinator.selectedID = $selectedID
        context.coordinator.onAddToFolder = onAddToFolder
        if context.coordinator.items != items {
            context.coordinator.items = items
            table.reloadData()
        }
        let selectedRow = table.selectedRow
        let expectedRow = selectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? -1
        if selectedRow != expectedRow {
            table.selectRowIndexes(expectedRow >= 0 ? IndexSet(integer: expectedRow) : IndexSet(), byExtendingSelection: false)
        }
    }

    @MainActor public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var items: [LibraryRendererComparisonItem]
        fileprivate var selectedID: Binding<String?>
        fileprivate var onAddToFolder: ((String) -> Void)?
        fileprivate weak var table: ComparisonTableView?

        fileprivate init(items: [LibraryRendererComparisonItem], selectedID: Binding<String?>, onAddToFolder: ((String) -> Void)?) {
            self.items = items
            self.selectedID = selectedID
            self.onAddToFolder = onAddToFolder
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            items[row].kind == .heading ? 32 : 68
        }

        public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            items[row].kind == .capability
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let identifier = NSUserInterfaceItemIdentifier(item.kind == .heading ? "heading" : "capability")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ComparisonCellView)
                ?? ComparisonCellView(kind: item.kind)
            cell.identifier = identifier
            cell.configure(item)
            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, table.selectedRow >= 0, table.selectedRow < items.count else {
                selectedID.wrappedValue = nil
                return
            }
            let item = items[table.selectedRow]
            selectedID.wrappedValue = item.kind == .capability ? item.id : nil
        }

        fileprivate func menu(for row: Int) -> NSMenu? {
            guard items.indices.contains(row), items[row].kind == .capability else { return nil }
            let menu = NSMenu()
            let action = NSMenuItem(title: "Add to folder", action: #selector(addToFolder(_:)), keyEquivalent: "")
            action.target = self
            action.representedObject = items[row].id
            action.isEnabled = onAddToFolder != nil
            menu.addItem(action)
            return menu
        }

        @objc private func addToFolder(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            onAddToFolder?(id)
        }
    }
}

@MainActor
final class ComparisonTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }
        return menuProvider?(clickedRow)
    }
}

@MainActor
private final class ComparisonCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let kind: LibraryRendererComparisonItem.Kind

    init(kind: LibraryRendererComparisonItem.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        for label in [titleLabel, detailLabel, usageLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: kind == .heading ? 13 : 15, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        usageLabel.font = .systemFont(ofSize: 12)
        usageLabel.textColor = .secondaryLabelColor
        if kind == .heading {
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.isHidden = true
            usageLabel.isHidden = true
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: usageLabel.leadingAnchor, constant: -8),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                usageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                usageLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ item: LibraryRendererComparisonItem) {
        titleLabel.stringValue = item.title
        detailLabel.stringValue = item.purpose
        usageLabel.stringValue = item.usage
        setAccessibilityLabel(item.kind == .heading
            ? item.title
            : "\(item.title), \(item.purpose), \(item.usage)")
    }
}
#endif
