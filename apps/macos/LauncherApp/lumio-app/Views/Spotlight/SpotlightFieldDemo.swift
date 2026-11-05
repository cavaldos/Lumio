//
//  SpotlightFieldDemo.swift
//  lumio-app
//
//  DEMO for SpotlightField — only to feel the component growing on its own. No
//  search/scoring/launch; the rows are a fixed slice of SpotlightData.
//
//  View: open this file then ⌥⌘↩ (Preview), or turn on
//  `LauncherFeatureFlags.isMotionLabEnabled` to see it in the real app.
//  Keys: space replays, ↑↓ changes row, esc closes.
//

import SwiftUI

struct SpotlightFieldDemoView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var isVisible = false
    @State private var query = ""
    @State private var selection = 0
    @State private var filter: SpotlightKind?
    @State private var toast: String?
    @State private var replayTask: Task<Void, Never>?

    /// Fake row count, growing with the query length so the field visibly grows with its content.
    private var rowCount: Int { query.isEmpty ? 0 : min(6, 2 + query.count) }
    private var rows: [SpotlightItem] { Array(SpotlightData.items.prefix(rowCount)) }
    private var shownRows: [SpotlightItem] {
        filter == nil ? rows : rows.filter { $0.kind == filter }
    }
    private var filterKinds: [SpotlightKind] {
        var seen: [SpotlightKind] = []
        for row in rows where !seen.contains(row.kind) { seen.append(row.kind) }
        return seen
    }

    var body: some View {
        ZStack {
            SpotlightAuroraWall(palette: .of(colorScheme == .dark ? .dark : .light))

            // The field grows/shrinks with its own content. The demo needs no
            // simulator of any kind: this is exactly what the app will do.
            SpotlightField(
                isVisible: isVisible,
                query: $query,
                rows: shownRows,
                selection: selection,
                filter: filter,
                filterKinds: filterKinds,
                scopeName: nil,
                toast: toast,
                isDark: colorScheme == .dark
            ) { position in
                selection = position
            } onSelectFilter: { kind in
                filter = kind
                selection = 0
            }
            .padding(.top, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startReplay() }
        .onDisappear { replayTask?.cancel() }
        .onChange(of: query) { _, _ in
            // Deliberately NOT wrapped in withAnimation: the field resizes itself, content toggles
            // instantly.
            selection = 0
        }
        .onKeyPress(.space) { startReplay(); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            query = ""
            toast = nil
            isVisible = false
            return .handled
        }
    }

    // MARK: - Controls

    private func move(_ delta: Int) {
        guard !shownRows.isEmpty else { return }
        selection = (selection + delta + shownRows.count) % shownRows.count
    }

    private func startReplay() {
        replayTask?.cancel()
        replayTask = Task { @MainActor in
            while !Task.isCancelled {
                query = ""
                selection = 0
                filter = nil
                toast = nil
                isVisible = false

                await pause(0.3)
                // Open: the field grows from 0 to the height of the search bar.
                isVisible = true

                await pause(0.35)
                // Type: the field grows with the number of rows it holds.
                query = "fl"
                await pause(0.3)
                query = "flu"

                await pause(0.3)
                selection = 1
                await pause(0.25)
                selection = 2

                await pause(0.4)
                toast = "Opening \(shownRows.first?.name ?? "…")"
                // Close: the field shrinks back to 0.
                isVisible = false

                await pause(0.5)
                toast = nil

                await pause(0.4)
            }
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

#Preview("SpotlightField") {
    SpotlightFieldDemoView()
        .frame(width: 900, height: 620)
}
