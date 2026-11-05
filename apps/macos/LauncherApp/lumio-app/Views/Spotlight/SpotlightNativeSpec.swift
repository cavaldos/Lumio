//
//  SpotlightNativeSpec.swift
//  lumio-app
//
//  Measurements + colors for the native-style launcher. There is NO easing table here: the native version
//  barely animates its content, so the "timing" lives in the window, not in SwiftUI.
//
//  Measurements derive from spotlight.html but drop things that only served web
//  effects (430 morph width, dead --r-open corner radius, cascade…).
//

import SwiftUI

// MARK: - Palette

struct SpotlightPalette {
    let isDark: Bool

    // Wall (blurred gradient background) — only used if the aurora background is enabled.
    let wallA: Color
    let wallB: Color
    let wallC: Color
    let wallD: Color

    // Panel
    let panel: Color
    let panelLine: Color
    let panelRing: Color
    let shadow: Color

    // Text
    let text: Color
    let dim: Color
    let faint: Color

    // Row / pill / kbd
    let divider: Color
    let rowSel: Color
    let pill: Color
    let pillOn: Color
    let kbd: Color

    static let light = SpotlightPalette(
        isDark: false,
        wallA: Color(hex: "cfd9ea"),
        wallB: Color(hex: "eef1f6"),
        wallC: Color(hex: "f6dfe4"),
        wallD: Color(hex: "dbe7dd"),
        panel: Color(hex: "f6f6f8").opacity(0.72),
        panelLine: Color.black.opacity(0.10),
        panelRing: Color.white.opacity(0.65),
        shadow: Color(hex: "14161e").opacity(0.28),
        text: Color.black.opacity(0.90),
        dim: Color.black.opacity(0.48),
        faint: Color.black.opacity(0.30),
        divider: Color.black.opacity(0.10),
        rowSel: Color.black.opacity(0.075),
        pill: Color.black.opacity(0.07),
        pillOn: Color.black.opacity(0.16),
        kbd: Color.black.opacity(0.10)
    )

    static let dark = SpotlightPalette(
        isDark: true,
        wallA: Color(hex: "2b2740"),
        wallB: Color(hex: "121319"),
        wallC: Color(hex: "3a2739"),
        wallD: Color(hex: "16242c"),
        panel: Color(hex: "28282a").opacity(0.70),
        panelLine: Color.white.opacity(0.12),
        panelRing: Color.white.opacity(0.14),
        shadow: Color.black.opacity(0.60),
        text: Color.white.opacity(0.94),
        dim: Color.white.opacity(0.52),
        faint: Color.white.opacity(0.34),
        divider: Color.white.opacity(0.10),
        rowSel: Color.white.opacity(0.13),
        pill: Color.white.opacity(0.10),
        pillOn: Color.white.opacity(0.24),
        kbd: Color.white.opacity(0.16)
    )

    static func of(_ scheme: ColorScheme) -> SpotlightPalette {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Measurements

enum SpotlightSpec {
    enum Metric {
        // Search bar + round buttons measured on the real Spotlight in macOS 26/27, captured
        // next to this launcher: bar 638×58pt, placeholder ~26pt, 56pt buttons spaced
        // 10pt apart, and the cluster (shrunk bar + 4 buttons) is EXACTLY as wide as the full bar.

        /// Search bar height.
        static let barHeight: CGFloat = 58
        /// Full bar width (when there are no round buttons).
        static let panelWidth: CGFloat = 640
        /// Pill-shaped rounding = half the bar height.
        static let pillRadius: CGFloat = 29
        static let rowHeight: CGFloat = 52
        static let rowRadius: CGFloat = 11
        static let tileSize: CGFloat = 34
        static let barPadding: CGFloat = 21
        /// Font size of the search field and magnifying glass.
        static let queryFontSize: CGFloat = 26
        static let glassIconSize: CGFloat = 22
        /// Maximum rows shown without scrolling; the rest scroll inside the panel.
        static let maxVisibleRows = 7
        static let pillGap: CGFloat = 8
        /// Distance from the top edge of the screen (15vh in the web version).
        static let topInsetRatio: CGFloat = 0.15
        static let sideInset: CGFloat = 16

        // "Idle" state (empty field): the bar shrinks from the right and the 4 round buttons fill
        // the space it gave up — total width stays the same, like the real Spotlight.
        static let quickSize: CGFloat = 56
        static let quickGap: CGFloat = 10
        static let quickCount = 4
        static let idleWidth: CGFloat = panelWidth - CGFloat(quickCount) * (quickSize + quickGap)

        // Lower part of the panel. Each section has a fixed height so the panel height
        // can be computed arithmetically instead of measured (measuring lags one frame).
        static let lowerTopInset: CGFloat = 8
        static let pillsHeight: CGFloat = 46
        static let listInsetTop: CGFloat = 2
        static let listInsetBottom: CGFloat = 6
        static let emptyListHeight: CGFloat = 52
        static let footerHeight: CGFloat = 34
        /// The open panel is at least this many rows tall: the right half is the preview,
        /// which needs enough room for code / images.
        static let minRowsWithPreview = 5
    }

    /// Height of the list area for `rows` rows (up to `maxVisibleRows`, the rest scroll).
    static func listHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return Metric.emptyListHeight }
        let visible = CGFloat(min(rows, Metric.maxVisibleRows))
        return visible * Metric.rowHeight + Metric.listInsetTop + Metric.listInsetBottom
    }

    /// Height of the part below the search bar: divider + filter pills + list + footer.
    static func lowerHeight(rows: Int) -> CGFloat {
        1 + Metric.lowerTopInset + Metric.pillsHeight + listHeight(rows: rows) + Metric.footerHeight
    }

    /// Component timing. This is the only place "animation" remains in the launcher.
    enum Reveal {
        /// The field grows / shrinks. Short and linear: the content is already built,
        /// so it only needs revealing; it doesn't need to be long to "feel" right.
        static let fieldSeconds = 0.16
        static let field = Animation.easeOut(duration: fieldSeconds)
        /// Toast — a small independent view that can fade cheaply.
        static let toast = Animation.easeOut(duration: 0.15)
    }
}

// MARK: - Spotlight launcher animation timing
//
// Every motion value lives here so the feel can be tuned in one place. Curves
// come from spotlight2.html: --ease = cubic-bezier(.22,.92,.24,1) for the
// resizing parts, a slightly bouncy spring for things that "pop" out.

enum SpotlightMotion {
    // Open: the glass cluster pops from slightly small to full size, with one gentle bounce.
    static let appearScale: CGFloat = 0.92
    static let appearOffsetY: CGFloat = -10
    static let appear = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let appearFade = Animation.easeOut(duration: 0.18)

    // Close: faster than open, the user already wants to move on. The window only orderOuts after
    // the fade finishes.
    static let dismissSeconds = 0.16
    static let dismiss = Animation.easeOut(duration: dismissSeconds)

    // Enter opens an item: a slight zoom then dissolve, as Spotlight hands off to the app.
    static let launchSeconds = 0.2
    static let launchScale: CGFloat = 1.04
    static let launch = Animation.easeOut(duration: launchSeconds)

    /// Round buttons split off from the bar. A spring so the glass droplets look "liquid".
    static let morph = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// Round buttons merge back into the bar when typing starts: snappier than splitting, since the
    /// user is waiting for results.
    static let merge = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Typing while round buttons are showing: the panel waits until the bar has nearly finished growing
    /// before dropping down, so results fall straight down instead of sweeping diagonally left to right.
    static let expandAfterMerge = 0.12
    /// How long the field must be empty before the 4 round buttons split off.
    static let idleDelay: Duration = .milliseconds(1200)
    /// Icons in the round buttons appear one by one, slightly after the glass droplets.
    static func quickIcon(_ index: Int) -> Animation {
        .spring(response: 0.4, dampingFraction: 0.62).delay(0.1 + Double(index) * 0.05)
    }

    /// The panel expands down / collapses up when results appear / disappear (.38s --ease).
    static let resize = Animation.timingCurve(0.22, 0.92, 0.24, 1, duration: 0.38)
    static let contentIn = Animation.easeOut(duration: 0.22)
    static let contentOut = Animation.easeOut(duration: 0.14)

    /// Result rows "rise" one by one — only right after the panel expands; further typing
    /// swaps rows instantly to avoid jank.
    static let introWindow: TimeInterval = 0.45
    static let rowRiseOffset: CGFloat = -8
    static func rowRise(_ index: Int) -> Animation {
        .timingCurve(0.22, 0.92, 0.24, 1, duration: 0.34)
            .delay(0.06 + Double(min(index, 7)) * 0.026)
    }

    // Row selection: ONE selection bar slides between rows (matchedGeometryEffect),
    // the newly selected row's icon zooms up one beat and back — like the legacy launcher
    // (Motion.Selection).
    static let selectionGlide = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let iconZoomScale: CGFloat = 1.16
    static let pillZoomScale: CGFloat = 1.015
    static let zoomInSeconds = 0.11
    static let zoomIn = Animation.easeOut(duration: zoomInSeconds)
    static let zoomOut = Animation.spring(response: 0.3, dampingFraction: 0.6)


    /// The top-hit icon at the end of the search bar pops out.
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.6)
    /// The scope chip (Tab into an app / browse a group) squeezes into the bar.
    static let chip = Animation.spring(response: 0.32, dampingFraction: 0.8)
    static let toast = Animation.spring(response: 0.34, dampingFraction: 0.8)
    /// "Reduce motion" enabled in Accessibility: only a short fade remains.
    static let reduced = Animation.easeOut(duration: 0.15)
}

// MARK: - Hex (shared by palette + tile)

extension Color {
    init(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        var parsed: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&parsed)
        let red = Double((parsed >> 16) & 0xFF) / 255
        let green = Double((parsed >> 8) & 0xFF) / 255
        let blue = Double(parsed & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
