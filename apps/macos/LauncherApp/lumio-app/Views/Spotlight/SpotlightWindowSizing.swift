//
//  SpotlightWindowSizing.swift
//  lumio-app
//
//  The Spotlight launcher's window does NOT change size while animating. It is
//  transparent and large enough for the biggest state (fully expanded panel + toast),
//  then stays put. All motion lives in SwiftUI, so the window
//  and its content never fall out of step.
//
//  Layout inside the window: the panel's left and top edges sit exactly `margin`
//  from the window edge (leaving room for the shadow). The panel is always centered on screen; the preview sits
//  inside the panel (right half), never sticking out.
//

import AppKit

enum SpotlightWindowSizing {
    private typealias Metric = SpotlightSpec.Metric

    /// Margin around the panel for the shadow and the bounce when opening.
    static let margin: CGFloat = 40
    /// Room for the toast below the panel.
    static let toastRoom: CGFloat = 80

    /// Width of the largest glass cluster: the normal bar, or the shrunk bar + 4 round buttons.
    static var clusterMaxWidth: CGFloat {
        let quicks = CGFloat(Metric.quickCount) * Metric.quickSize
            + CGFloat(Metric.quickCount) * Metric.quickGap
        return max(Metric.panelWidth, Metric.idleWidth + quicks)
    }

    static var windowSize: CGSize {
        let panelMax = Metric.barHeight + SpotlightSpec.lowerHeight(rows: Metric.maxVisibleRows)
        return CGSize(
            width: clusterMaxWidth + margin * 2,
            height: panelMax + toastRoom + margin * 2
        )
    }

    /// Centers the panel horizontally on screen, with its top edge `topInsetRatio` below the top
    /// of the visible area (15vh like the web version).
    static func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = windowSize
        let panelLeft = visible.midX - Metric.panelWidth / 2
        let panelTop = visible.maxY - visible.height * Metric.topInsetRatio
        let originX = panelLeft - margin
        let originY = max(panelTop + margin - size.height, visible.minY)
        return NSRect(x: originX.rounded(), y: originY.rounded(), width: size.width, height: size.height)
    }

    /// The screen that currently has the mouse pointer — Spotlight opens there.
    static func screenForCursor() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
}
