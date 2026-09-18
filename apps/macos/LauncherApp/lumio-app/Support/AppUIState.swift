import Foundation
import Combine

final class AppUIState: ObservableObject {
    // Shared instance so AppDelegate (which now owns the launcher NSWindow and
    // hosts ContentView) and the App scene's `.commands` operate on the same
    // state. See AppDelegate.makeLauncherWindow().
    static let shared = AppUIState()

    @Published var showsThemeSettings = false

    // Remembered command id of the last command-mode panel the user
    // visited *during this launch*. Re-entering command mode (Cmd+/)
    // resumes there instead of jumping back to /kill. Intentionally
    // not persisted - each fresh launch should start at /kill.
    @Published var lastCommandID: String?
}

extension Notification.Name {
    static let lookReloadConfigRequested = Notification.Name("lumio.reloadConfigRequested")
    static let lookRefocusInputRequested = Notification.Name("lumio.refocusInputRequested")
    /// A row's `then` targets finished loading off the main actor, so the panel
    /// that showed none can build its action list now.
    static let lookSourceTargetsLoaded = Notification.Name("lumio.sourceTargetsLoaded")
    static let lookFocusSettingsInputRequested = Notification.Name("lumio.focusSettingsInputRequested")
    static let lookToggleWindowRequested = Notification.Name("lumio.toggleWindowRequested")
    static let lookToggleSettingsRequested = Notification.Name("lumio.toggleSettingsRequested")
    static let lookActivateLauncherRequested = Notification.Name("lumio.activateLauncherRequested")
    static let lookHideLauncherRequested = Notification.Name("lumio.hideLauncherRequested")
}
