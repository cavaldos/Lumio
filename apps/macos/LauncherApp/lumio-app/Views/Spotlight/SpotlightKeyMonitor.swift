//
//  SpotlightKeyMonitor.swift
//  lumio-app
//
//  Catches navigation keys (↑↓, Tab, Esc, ⌘1–4…) BEFORE the text field can swallow
//  them — the same approach as the legacy launcher (KeyboardSelectionMonitor). Enter is still left to
//  the TextField's `onSubmit`, because it respects an input method (Telex/VNI) that is committing text.
//

import AppKit

@MainActor
final class SpotlightKeyMonitor {
    private var monitor: Any?

    /// `handler` returns `true` if it handled the key (the key is swallowed).
    func start(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
