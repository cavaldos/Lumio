//
//  ContentView.swift
//  lumio-app
//
//  Created by kunkka07xx on 2026/04/04.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        LauncherView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppUIState())
        .environmentObject(ThemeStore())
}
