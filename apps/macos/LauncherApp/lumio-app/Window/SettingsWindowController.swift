import AppKit
import Combine
import SwiftUI

/// Marks the settings window so launcher code that walks `NSApp.windows`
/// can tell it apart from the launcher panel.
final class SettingsPanelWindow: NSWindow {}

/// The Spotlight launcher has no settings page of its own, so settings open in
/// a separate window (Cmd+Shift+Space, or the Theme Settings menu command).
/// The legacy launcher still shows settings inside its own panel and does not
/// use this.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: SettingsPanelWindow?
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { window?.isVisible ?? false }

    private override init() {
        super.init()
        // ThemeSettingsView closes itself (Esc, "Back to Launcher") by clearing
        // this flag, so follow it to close the window.
        AppUIState.shared.$showsThemeSettings
            .removeDuplicates()
            .sink { [weak self] shows in
                guard !shows else { return }
                DispatchQueue.main.async { self?.window?.close() }
            }
            .store(in: &cancellables)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.close()
        } else {
            show()
        }
    }

    func show() {
        // The launcher floats above normal windows; close it so it doesn't
        // cover settings. Its hide hands focus back to the previous app, so
        // take focus back a moment later.
        let launcherOpen = NSApp.windows.contains { $0 is LauncherPanelWindow && $0.isVisible }
        if launcherOpen {
            NotificationCenter.default.post(name: .lookHideLauncherRequested, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.present()
            }
        } else {
            present()
        }
    }

    private func present() {
        let window = window ?? makeWindow()
        AppUIState.shared.showsThemeSettings = true
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> SettingsPanelWindow {
        let window = SettingsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumio Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentView = NSHostingView(
            rootView: SettingsWindowRoot()
                .environmentObject(AppUIState.shared)
                .environmentObject(ThemeStore.shared)
        )
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if AppUIState.shared.showsThemeSettings {
            AppUIState.shared.showsThemeSettings = false
        }
        // Nothing else of Lumio's is on screen: hand focus back to the app the
        // user was in, like the launcher does when it closes.
        let launcherOpen = NSApp.windows.contains { $0 is LauncherPanelWindow && $0.isVisible }
        if !launcherOpen {
            DispatchQueue.main.async { NSApp.hide(nil) }
        }
    }
}

private struct SettingsWindowRoot: View {
    @EnvironmentObject var themeStore: ThemeStore

    var body: some View {
        ThemeSettingsView(settings: $themeStore.settings)
            .padding(20)
            .foregroundStyle(themeStore.fontColor())
            .frame(minWidth: 680, minHeight: 520)
            .background(ThemedBackdrop(themeStore: themeStore).ignoresSafeArea())
            .background(WindowAppearancePin(appearance: themeStore.themeAppearance()))
    }
}
