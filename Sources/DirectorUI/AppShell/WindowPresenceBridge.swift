import AppKit
import SwiftUI

/// Bridges the real AppKit window lifecycle into model-only flags. The bridge
/// performs no data work in notification callbacks; it only reports visibility
/// and sleep changes to the already-created app model.
public struct WindowPresenceBridge: NSViewRepresentable {
    public let id: UUID
    public let onVisibilityChange: (Bool) -> Void
    public let onSleepingChange: (Bool) -> Void
    public let onClockChange: ((TimeZone?) -> Void)?
    public let onRemove: ((UUID) -> Void)?

    public init(
        id: UUID,
        onVisibilityChange: @escaping (Bool) -> Void,
        onSleepingChange: @escaping (Bool) -> Void,
        onClockChange: ((TimeZone?) -> Void)? = nil,
        onRemove: ((UUID) -> Void)? = nil
    ) {
        self.id = id
        self.onVisibilityChange = onVisibilityChange
        self.onSleepingChange = onSleepingChange
        self.onClockChange = onClockChange
        self.onRemove = onRemove
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(id: id, onVisibilityChange: onVisibilityChange, onSleepingChange: onSleepingChange, onClockChange: onClockChange, onRemove: onRemove)
    }

    public func makeNSView(context: Context) -> PresenceView {
        let view = PresenceView()
        view.coordinator = context.coordinator
        return view
    }

    public func updateNSView(_ nsView: PresenceView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.updateCallbacks(onVisibilityChange: onVisibilityChange, onSleepingChange: onSleepingChange, onClockChange: onClockChange, onRemove: onRemove)
        context.coordinator.attach(to: nsView.window)
    }

    public static func dismantleNSView(_ nsView: PresenceView, coordinator: Coordinator) {
        coordinator.dismantle()
        nsView.coordinator = nil
    }

    @MainActor
    public final class Coordinator {
        private let id: UUID
        private var onVisibilityChange: (Bool) -> Void
        private var onSleepingChange: (Bool) -> Void
        private var onClockChange: ((TimeZone?) -> Void)?
        private var onRemove: ((UUID) -> Void)?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var hasReportedRemoval = false
        private var lastVisibility: Bool?

        init(id: UUID, onVisibilityChange: @escaping (Bool) -> Void, onSleepingChange: @escaping (Bool) -> Void, onClockChange: ((TimeZone?) -> Void)?, onRemove: ((UUID) -> Void)?) {
            self.id = id
            self.onVisibilityChange = onVisibilityChange
            self.onSleepingChange = onSleepingChange
            self.onClockChange = onClockChange
            self.onRemove = onRemove
        }

        func updateCallbacks(onVisibilityChange: @escaping (Bool) -> Void, onSleepingChange: @escaping (Bool) -> Void, onClockChange: ((TimeZone?) -> Void)?, onRemove: ((UUID) -> Void)?) {
            self.onVisibilityChange = onVisibilityChange
            self.onSleepingChange = onSleepingChange
            self.onClockChange = onClockChange
            self.onRemove = onRemove
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                reportVisibility()
                return
            }
            if self.window != nil, !hasReportedRemoval {
                onVisibilityChange(false)
                onRemove?(id)
            }
            removeObservers()
            self.window = window
            hasReportedRemoval = false
            lastVisibility = nil
            guard let window else { return }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification
            ]
            observers = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if isClosing { self.removeWindow() } else { self.reportVisibility() }
                    }
                }
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onSleepingChange(true) }
            })
            observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onSleepingChange(false)
                    self?.reportVisibility()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onClockChange?(TimeZone.current) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name.NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onClockChange?(nil) }
            })
            reportVisibility()
        }

        private func reportVisibility() {
            guard let window else { return }
            let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            guard lastVisibility != visible else { return }
            lastVisibility = visible
            onVisibilityChange(visible)
        }

        private func removeWindow() {
            guard !hasReportedRemoval else { return }
            hasReportedRemoval = true
            onVisibilityChange(false)
            onRemove?(id)
            removeObservers()
            window = nil
            lastVisibility = nil
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            observers.forEach {
                center.removeObserver($0)
                workspaceCenter.removeObserver($0)
            }
            observers.removeAll()
        }

        func dismantle() {
            if !hasReportedRemoval, window != nil {
                removeWindow()
            } else {
                removeObservers()
                window = nil
                lastVisibility = nil
            }
        }

        deinit {}
    }

    public final class PresenceView: NSView {
        weak var coordinator: Coordinator?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }
}
