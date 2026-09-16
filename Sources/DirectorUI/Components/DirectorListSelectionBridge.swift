import AppKit
import SwiftUI

/// Suppresses AppKit's selection paint for one SwiftUI `List` row whose
/// content draws the approved selected surface itself. Selection ownership,
/// keyboard movement and accessibility remain with the native List.
///
/// `NSTableRowView.selectionHighlightStyle` is intentionally changed on the
/// containing row only. Changing the enclosing table's style forces
/// `NSOutlineView` to reload its style data and is unsafe during SwiftUI List
/// reconciliation.
struct DirectorListSelectionBridge: NSViewRepresentable {
    @Binding private var isEmphasized: Bool

    init(isEmphasized: Binding<Bool>) {
        _isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> DirectorListSelectionProbeView {
        let view = DirectorListSelectionProbeView()
        view.emphasisChanged = { value in
            if isEmphasized != value {
                isEmphasized = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: DirectorListSelectionProbeView, context: Context) {
        nsView.emphasisChanged = { value in
            if isEmphasized != value {
                isEmphasized = value
            }
        }
        nsView.installIfPossible()
    }

    static func dismantleNSView(_ nsView: DirectorListSelectionProbeView, coordinator: ()) {
        nsView.restore()
    }
}

final class DirectorListSelectionProbeView: NSView {
    var emphasisChanged: ((Bool) -> Void)?

    private weak var hostedRowView: NSTableRowView?
    private var previousSelectionHighlightStyle: NSTableView.SelectionHighlightStyle?
    private var observesApplicationUpdates = false
    private var installScheduled = false
    private var lastReportedEmphasis: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleInstall()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObservingApplicationUpdates()
            restoreHostedRowView()
        } else {
            startObservingApplicationUpdates()
            scheduleInstall()
        }
    }

    func installIfPossible() {
        guard let rowView = rowViewInHierarchy() else { return }
        if hostedRowView !== rowView {
            restoreHostedRowView()
            hostedRowView = rowView
            previousSelectionHighlightStyle = rowView.selectionHighlightStyle
        }

        if rowView.selectionHighlightStyle != .none {
            rowView.selectionHighlightStyle = .none
        }
        reportEmphasis(rowView.isSelected && rowView.isEmphasized)
    }

    func restore() {
        stopObservingApplicationUpdates()
        restoreHostedRowView()
    }

    private func restoreHostedRowView() {
        guard let rowView = hostedRowView,
              let previousSelectionHighlightStyle else {
            reportEmphasis(false)
            return
        }
        hostedRowView = nil
        self.previousSelectionHighlightStyle = nil
        if rowView.selectionHighlightStyle == .none {
            rowView.selectionHighlightStyle = previousSelectionHighlightStyle
        }
        reportEmphasis(false)
    }

    private func scheduleInstall() {
        guard !installScheduled else { return }
        installScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installScheduled = false
            self.installIfPossible()
        }
    }

    private func startObservingApplicationUpdates() {
        guard !observesApplicationUpdates else { return }
        observesApplicationUpdates = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidUpdate),
            name: NSApplication.didUpdateNotification,
            object: NSApp
        )
    }

    private func stopObservingApplicationUpdates() {
        guard observesApplicationUpdates else { return }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didUpdateNotification, object: NSApp)
        observesApplicationUpdates = false
    }

    @objc private func applicationDidUpdate(_ notification: Notification) {
        installIfPossible()
    }

    private func reportEmphasis(_ value: Bool) {
        guard lastReportedEmphasis != value else { return }
        lastReportedEmphasis = value
        DispatchQueue.main.async { [weak self] in
            self?.emphasisChanged?(value)
        }
    }

    private func rowViewInHierarchy() -> NSTableRowView? {
        var candidate = superview
        var remainingHops = 16
        while let view = candidate, remainingHops > 0 {
            if let rowView = view as? NSTableRowView { return rowView }
            candidate = view.superview
            remainingHops -= 1
        }
        return nil
    }
}
