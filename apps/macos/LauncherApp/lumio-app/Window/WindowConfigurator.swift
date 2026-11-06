import AppKit
import SwiftUI

/// Styles the launcher window once: transparent, borderless, floating. The Spotlight panel
/// rounds its own corners and places the window on every show.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(from: nsView)
        }
    }

    private func configureWindow(from view: NSView) {
        guard let window = view.window else { return }
        guard configuredWindowIDs.insert(ObjectIdentifier(window)).inserted else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        // Not user-movable: it opens at a fixed position on the cursor's screen every show.
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.hasShadow = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        // Float above other apps.
        window.level = .floating
    }
}

// One-shot guard so configureWindow runs once per NSWindow (main actor only).
@MainActor private var configuredWindowIDs: Set<ObjectIdentifier> = []
