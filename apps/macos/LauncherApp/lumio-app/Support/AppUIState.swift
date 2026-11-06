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
}
