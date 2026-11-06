import Foundation
import Combine

final class AppUIState: ObservableObject {
    // Shared instance so AppDelegate (which now owns the launcher NSWindow and
    // hosts ContentView) and the App scene's `.commands` operate on the same
    // state. See AppDelegate.makeLauncherWindow().
    static let shared = AppUIState()

    @Published var showsThemeSettings = false
}

extension Notification.Name {
    static let lookReloadConfigRequested = Notification.Name("lumio.reloadConfigRequested")
    static let lookRefocusInputRequested = Notification.Name("lumio.refocusInputRequested")
    static let lookToggleWindowRequested = Notification.Name("lumio.toggleWindowRequested")
    static let lookToggleSettingsRequested = Notification.Name("lumio.toggleSettingsRequested")
    static let lookActivateLauncherRequested = Notification.Name("lumio.activateLauncherRequested")
    static let lookHideLauncherRequested = Notification.Name("lumio.hideLauncherRequested")
    /// A tab's global shortcut was pressed; `object` is the SpotlightKind raw value.
    static let lookOpenTabRequested = Notification.Name("lumio.openTabRequested")
    /// The global shortcuts in Settings changed: register them again.
    static let lookHotKeysChanged = Notification.Name("lumio.hotKeysChanged")
    /// Settings is recording a shortcut (`object` = Bool): pause the global ones meanwhile.
    static let lookHotKeyRecordingChanged = Notification.Name("lumio.hotKeyRecordingChanged")
}
