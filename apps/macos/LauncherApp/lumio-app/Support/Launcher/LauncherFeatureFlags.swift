import Foundation

/// Temporarily turns off the legacy launcher (LauncherView) to try the new Spotlight launcher.
/// - `isLegacyLauncherEnabled = false`: ContentView + AppDelegate use SpotlightLauncherView.
/// - To bring back the legacy launcher: set it to `true`; no code needs deleting.
///
/// `isMotionLabEnabled` opens an ANIMATION-ONLY demo ported from spotlight.html
/// (no search/launch wired up): set it to `true` and rebuild to feel the timing in
/// the real app. Defaults to false, so the current launcher is unchanged.
enum LauncherFeatureFlags {
    static let isLegacyLauncherEnabled = false
    static let isMotionLabEnabled = false
}
