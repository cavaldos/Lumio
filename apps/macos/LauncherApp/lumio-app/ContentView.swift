//
//  ContentView.swift
//  lumio-app
//
//  Created by kunkka07xx on 2026/04/04.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        // Legacy launcher temporarily off: flag OFF -> use the new Spotlight (ported from spotlight.html).
        // To turn it back on: LauncherFeatureFlags.isLegacyLauncherEnabled = true.
        if LauncherFeatureFlags.isMotionLabEnabled {
            // Motion lab: SpotlightField — ONE component that resizes to fit its
            // content, no features wired up yet. The flag is OFF, so this branch never runs.
            SpotlightFieldDemoView()
        } else if LauncherFeatureFlags.isLegacyLauncherEnabled {
            LauncherView()
        } else {
            SpotlightLauncherView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppUIState())
        .environmentObject(ThemeStore())
}
