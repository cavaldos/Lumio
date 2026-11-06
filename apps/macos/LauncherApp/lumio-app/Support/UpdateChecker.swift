import AppKit
import Combine
import Sparkle

/// Self-updates through Sparkle, set up like Ice. Sparkle reads the feed named
/// by SUFeedURL in Info.plist (published by scripts/notify-update.sh after each
/// release), verifies the download against SUPublicEDKey, then installs it and
/// relaunches Lumio.
///
/// Off in Debug builds and in the side-by-side "Lumio Dev" app: an update would
/// replace them with the release build.
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    /// False for Debug builds and Lumio Dev.
    let isEnabled: Bool

    /// False while a check or an update is already in progress.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?

    override init() {
        #if DEBUG
        isEnabled = false
        #else
        isEnabled = !AppVersion.isDevBuild
        #endif
        super.init()
    }

    /// Starts Sparkle's scheduled checks (once a day). Call once at launch.
    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// "Check for Updates": Sparkle shows the result (up to date, or the update).
    func checkForUpdates() {
        guard let controller else { return }
        // Lumio is a background (LSUIElement) app: Sparkle's windows only take
        // input while it is active.
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    /// Never show Sparkle's "check for updates automatically?" prompt: in a
    /// background app it freezes and comes back on every launch
    /// (jordanbaird/Ice#681). Settings > About has the same toggle.
    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

extension UpdateChecker: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check found an update: activate first so the alert Sparkle
    /// shows can take input while Lumio sits in the background.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
