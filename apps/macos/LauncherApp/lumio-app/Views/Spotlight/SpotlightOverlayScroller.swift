//
//  SpotlightOverlayScroller.swift
//  lumio-app
//
//  A thin pill scroll indicator drawn by SwiftUI. It replaces the system bar,
//  which turns into a wide legacy bar with a track when macOS is set to
//  "Always show scroll bars" or a mouse is plugged in.
//

import SwiftUI

extension View {
    /// Hides the system scroll bar of this ScrollView and draws a thin one that
    /// appears while scrolling and fades out when idle.
    func spotlightThinScroller(isDark: Bool) -> some View {
        modifier(ThinScroller(isDark: isDark))
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
}

private struct ThinScroller: ViewModifier {
    let isDark: Bool

    @State private var metrics = ScrollMetrics()
    @State private var shown = false
    @State private var hideTask: Task<Void, Never>?

    private enum Metric {
        static let width: CGFloat = 5
        static let inset: CGFloat = 4
        static let trailing: CGFloat = 3
        static let minKnob: CGFloat = 28
        static let idleDelay: Duration = .milliseconds(1100)
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                ScrollMetrics(
                    offset: geo.visibleRect.minY,
                    content: geo.contentSize.height,
                    visible: geo.containerSize.height
                )
            } action: { old, new in
                metrics = new
                if old.offset != new.offset { flash() }
            }
            .overlay(alignment: .topTrailing) { knob }
            .onHover { if $0 { flash() } }
    }

    @ViewBuilder
    private var knob: some View {
        let scrollable = metrics.content - metrics.visible
        if scrollable > 1, metrics.visible > 0 {
            let track = metrics.visible - Metric.inset * 2
            let height = max(Metric.minKnob, track * metrics.visible / metrics.content)
            let progress = min(max(metrics.offset / scrollable, 0), 1)
            Capsule()
                .fill(isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.3))
                .frame(width: Metric.width, height: height)
                .offset(x: -Metric.trailing, y: Metric.inset + (track - height) * progress)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: shown)
                .allowsHitTesting(false)
        }
    }

    private func flash() {
        shown = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: Metric.idleDelay)
            guard !Task.isCancelled else { return }
            shown = false
        }
    }
}
