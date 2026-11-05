import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeyManager = GlobalHotKeyManager()

    // The launcher window is owned by AppKit (created here), NOT by a SwiftUI
    // WindowGroup. SwiftUI refuses to create a WindowGroup window on a
    // background login launch, which left LauncherView (and its Option+Space
    // toggle observer) unmounted → the hotkey fired into the void. An AppKit
    // NSWindow is not subject to that suppression: we create it at launch
    // (hidden) so LauncherView is always mounted and the existing
    // .lookToggleWindowRequested → toggleWindowVisibility() path just works.
    private var launcherWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?

    // Grace period allows macOS "Quit & Reopen" handoff to release the previous process lock.
    private static let relaunchGracePeriodSeconds: TimeInterval = 0.8
    private static let contentionRetrySeconds: TimeInterval = 0.25
    private static let lockPollIntervalMicros: useconds_t = 50_000
    nonisolated(unsafe) private static var singletonLockFD: CInt = -1

    deinit {
        SingleInstanceLock.release(Self.singletonLockFD)
        Self.singletonLockFD = -1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        hotKeyManager.registerToggleHotKey()
        NSApp.setActivationPolicy(.accessory)

        // Create the launcher window ourselves (hidden) so LauncherView mounts
        // at launch - even on a cold background-login launch, where SwiftUI
        // would never create a WindowGroup window. With the view mounted, its
        // .lookToggleWindowRequested observer is live and Option+Space toggles it.
        makeLauncherWindow()

        // The legacy launcher shows settings inside its own panel. The
        // Spotlight launcher has none, so open them in a separate window.
        if !LauncherFeatureFlags.isLegacyLauncherEnabled {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .lookToggleSettingsRequested, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { SettingsWindowController.shared.toggle() }
            }
        }

        // Notify-only update check against GitHub Releases (throttled to once
        // per 12h). Lumio ships via GitHub Releases, so this never self-installs - it
        // just surfaces a notice linking to the release page.
        UpdateChecker.shared.checkForUpdates()
    }

    /// Build the launcher window in AppKit, host ContentView in it, and leave
    /// it hidden. WindowConfigurator (embedded in ContentView) restyles this
    /// window on first appearance - corner radius, floating level, multi-display
    /// autoscale.
    private func makeLauncherWindow() {
        // New Spotlight launcher (flag OFF): transparent window, fixed size large
        // enough for the biggest state — all animation lives in SwiftUI.
        // Legacy launcher: keeps baseSize 860×600 + test flags as before.
        let legacy = LauncherFeatureFlags.isLegacyLauncherEnabled
        let baseSize = legacy ? WindowAutoScale.baseSize() : SpotlightWindowSizing.windowSize
        let (minW, minH) = (baseSize.width, baseSize.height)
        // TEMP single-component: lower the min size so the window can shrink to 600×100.
        let testMin = LauncherView.testCollapsedWindowSize
        let content = ContentView()
            .frame(
                minWidth: legacy && LauncherView.testExpandOnly ? testMin.width : minW,
                minHeight: legacy && LauncherView.testExpandOnly ? testMin.height : minH
            )
            .background(WindowConfigurator(themeStore: .shared))
            .environmentObject(AppUIState.shared)
            .environmentObject(ThemeStore.shared)

        let window = LauncherPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: minW, height: minH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: content)
        if !legacy {
            // Spotlight: SwiftUI must not resize the window to fit content —
            // the window stays put and the panel animates inside it.
            hostingView.sizingOptions = []
        }
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        // Start hidden - this matches the launcher's normal resting state
        // (it is summoned with Option+Space, not shown at launch).
        window.orderOut(nil)
        launcherWindow = window
    }

    private func shouldTerminateDuplicateInstance() -> Bool {
        let currentBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let lockPath = SingleInstanceLock.lockPath(for: currentBundlePath)

        // Try to acquire singleton lock with grace period for "Quit & Reopen" handoff
        let lockResult = acquireSingletonLock(lockPath: lockPath, timeoutSeconds: Self.relaunchGracePeriodSeconds)

        if case .heldByOtherInstance = lockResult {
            if checkAndActivateDuplicateInstance(currentBundlePath: currentBundlePath) {
                return true
            }

            let retryResult = acquireSingletonLock(lockPath: lockPath, timeoutSeconds: Self.contentionRetrySeconds)
            if case .heldByOtherInstance = retryResult {
                return checkAndActivateDuplicateInstance(currentBundlePath: currentBundlePath)
            }
        }

        // Always check for other running instances to handle:
        // 1. Mixed-version scenarios (older builds not using lock protocol)
        // 2. Lock subsystem unavailable (fallback to process-based detection)
        return checkAndActivateDuplicateInstance(currentBundlePath: currentBundlePath)
    }

    private func checkAndActivateDuplicateInstance(currentBundlePath: String) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let otherInstances = runningApps.filter { $0.processIdentifier != currentPID }

        // No other instances found
        guard !otherInstances.isEmpty else {
            return false
        }

        // Prefer instance at same path (clean handoff for "Quit & Reopen")
        // Fall back to any instance if same path not found (prevents concurrent instances from different paths)
        let samePathInstance = otherInstances.first { app in
            let otherPath = app.bundleURL?.resolvingSymlinksInPath().path
            return otherPath == currentBundlePath
        }

        let primaryApp = samePathInstance ?? otherInstances.min(by: { $0.processIdentifier < $1.processIdentifier })!

        primaryApp.activate(options: [.activateAllWindows])
        return true
    }

    private func acquireSingletonLock(lockPath: String, timeoutSeconds: TimeInterval) -> SingleInstanceLockResult {
        if Self.singletonLockFD >= 0 {
            return .acquired(Self.singletonLockFD)
        }

        let lockResult = SingleInstanceLock.acquire(
            lockPath: lockPath,
            timeoutSeconds: timeoutSeconds,
            pollIntervalMicros: Self.lockPollIntervalMicros
        )

        if case .acquired(let fd) = lockResult {
            Self.singletonLockFD = fd
        }

        return lockResult
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SettingsWindowController.shared.isVisible {
            SettingsWindowController.shared.show()
            return false
        }
        if let window = collapseToSingleLauncherWindow(preferred: sender.windows.first(where: { $0.isVisible })) {
            sender.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .lookActivateLauncherRequested, object: nil)
        // We handled reopen ourselves; prevent AppKit from creating another window.
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async {
            // Activated for the settings window: leave the launcher closed.
            if SettingsWindowController.shared.isVisible { return }
            if let app = notification.object as? NSApplication,
                let window = app.windows.first(where: { $0.isVisible }) ?? app.windows.first
            {
                app.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            NotificationCenter.default.post(name: .lookActivateLauncherRequested, object: nil)
        }
    }

    @discardableResult
    private func collapseToSingleLauncherWindow(preferred: NSWindow? = nil) -> NSWindow? {
        let windows = NSApplication.shared.windows.filter { !($0 is SettingsPanelWindow) }
        guard !windows.isEmpty else { return nil }

        let primary = preferred ?? windows.first(where: { $0.isVisible }) ?? windows.first
        guard let primary else { return nil }

        for window in windows where window !== primary {
            window.orderOut(nil)
            window.close()
        }

        return primary
    }
}
