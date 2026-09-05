import AppKit
import Foundation

/// Harness-only passive observation. It returns every event unchanged and
/// records no characters, key codes, button details, or window content.
final class StartupPerformancePassiveMarkers: @unchecked Sendable {
    private let recorder: StartupPerformanceRecorder
    private let lock = NSLock()
    private var lastInput: ContinuousClock.Instant?
    private var lastInputWindowNumber: Int?
    private var pendingWindowUpdate = false
    private var pendingWindowInput: ContinuousClock.Instant?
    private var inputMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []

    init(recorder: StartupPerformanceRecorder) { self.recorder = recorder }

    func start() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.observeInput(event)
            return event
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.observeWindowUpdate(window)
        })
    }

    func selectionChanged() {
        lock.lock(); defer { lock.unlock() }
        guard lastInput != nil else { return }
        recorder.markElapsed("input_to_selection", since: lastInput!)
        pendingWindowUpdate = true
        pendingWindowInput = lastInput
        lastInput = nil
    }

    private func observeInput(_ event: NSEvent) {
        // The local monitor is scoped to this app's event stream. Window
        // identity is retained only transiently for the next update marker.
        guard let window = event.window,
              let instant = recorder.instant(forSystemUptime: event.timestamp) else { return }
        lock.lock(); lastInput = instant; lastInputWindowNumber = window.windowNumber; lock.unlock()
    }

    private func observeWindowUpdate(_ window: NSWindow) {
        lock.lock(); defer { lock.unlock() }
        guard pendingWindowUpdate,
              let inputWindow = lastInputWindowNumber,
              inputWindow == window.windowNumber,
              let inputInstant = pendingWindowInput else { return }
        recorder.markElapsed("input_to_window_update", since: inputInstant)
        pendingWindowUpdate = false
        pendingWindowInput = nil
        lastInputWindowNumber = nil
        recorder.flushAsync()
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
}
