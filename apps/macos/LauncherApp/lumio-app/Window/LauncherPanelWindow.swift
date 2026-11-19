import AppKit
import Quartz

/// Borderless, because macOS clips a *titled* window to its own corner radius
/// whatever `layer.cornerRadius` says, so the panel could never go square.
/// Borderless refuses key status by default, hence the overrides.
final class LauncherPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Quick Look panel controller: the preview's expand button opens it (SpotlightQuickLook).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = SpotlightQuickLook.shared
            panel.delegate = SpotlightQuickLook.shared
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
