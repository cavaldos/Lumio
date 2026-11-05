//
//  SpotlightAuroraWall.swift
//  lumio-app
//
//  1:1 port of the `.wall` background from spotlight.html: overlapping
//  radial-gradient streaks, heavily blurred, drifting back and forth very slowly.
//
//  NOT used in the native launcher (SpotlightNativeStage turns this background off by default):
//  two full-screen blur layers are the heaviest thing in the view and the furthest
//  from the native feel of the real Spotlight. Kept around to enable when an animated
//  background is wanted, or delete it if unused.
//

import SwiftUI

struct SpotlightAuroraWall: View {
    let palette: SpotlightPalette

    /// prefers-reduced-motion: the HTML version disables animation; here it just stays still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 46s period of the ::before layer.
    @State private var drifting = false
    /// 62s reverse-direction period of the ::after layer.
    @State private var counterDrifting = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let blurRadius = min(70, size.width * 0.09)

            ZStack {
                palette.wallB
                // ::before — 3 streaks, 46s drift
                layer(forward: drifting, blurRadius: blurRadius, size: size) {
                    blob(color: palette.wallA, centerX: 0.22, centerY: 0.26, width: 0.38, height: 0.46, size: size)
                    blob(color: palette.wallC, centerX: 0.78, centerY: 0.22, width: 0.42, height: 0.48, size: size)
                    blob(color: palette.wallD, centerX: 0.60, centerY: 0.84, width: 0.52, height: 0.55, size: size)
                }
                // ::after — 1 streak, opacity .6, 62s drift in REVERSE
                layer(forward: counterDrifting, blurRadius: blurRadius, size: size, reverses: true) {
                    blob(color: palette.wallC, centerX: 0.12, centerY: 0.78, width: 0.34, height: 0.40, size: size)
                        .opacity(0.6)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 46).repeatForever(autoreverses: true)) {
                drifting = true
            }
            withAnimation(.easeInOut(duration: 62).repeatForever(autoreverses: true)) {
                counterDrifting = true
            }
        }
    }

    /// One independent background layer: in the HTML each pseudo-element has its own
    /// filter + animation, so the two streaks must drift independently (46s and 62s reversed)
    /// rather than share one transform.
    ///
    /// The scale → blur → drawingGroup order is deliberate: the blur runs on the enlarged
    /// content (at the right resolution), then rasterizes once; the drift after that is just
    /// a transform, so the GPU composites it without re-blurring every frame.
    private func layer<Content: View>(
        forward: Bool,
        blurRadius: CGFloat,
        size: CGSize,
        reverses: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()
        }
        // inset: -30% → the background block overflows the frame so the drift never shows a hard edge.
        .scaleEffect(1.6)
        .blur(radius: blurRadius)
        .drawingGroup()
        .modifier(SpotlightDrift(forward: forward, size: size, reverses: reverses))
    }

    /// radial-gradient(W% H% at X% Y%, color 0%, transparent 62%)
    ///
    /// endRadius follows the shorter side, so the streak is fully faded in the middle then smears out —
    /// slightly off from the CSS at the outer edge, but invisible after a 70px blur.
    private func blob(
        color: Color,
        centerX: CGFloat,
        centerY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        size: CGSize
    ) -> some View {
        let box = CGSize(width: size.width * width, height: size.height * height)
        return Ellipse()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 0.62 * min(box.width, box.height) / 2
                )
            )
            .frame(width: box.width, height: box.height)
            .position(x: size.width * centerX, y: size.height * centerY)
    }
}

/// @keyframes drift: translate3d(-2%,-1%,0) scale(1) → translate3d(3%,2%,0) scale(1.08)
///
/// - CSS percentages are relative to the inset block itself (-30%), so multiply by 1.6.
/// - `reverses` is the alternate-reverse of ::after: flips the drift direction.
private struct SpotlightDrift: ViewModifier {
    let forward: Bool
    let size: CGSize
    /// ::after runs alternate-reverse: flips the drift direction.
    var reverses = false

    private var isFar: Bool { reverses ? !forward : forward }

    func body(content: Content) -> some View {
        content
            .offset(
                x: isFar ? size.width * 1.6 * 0.03 : -size.width * 1.6 * 0.02,
                y: isFar ? size.height * 1.6 * 0.02 : -size.height * 1.6 * 0.01
            )
            .scaleEffect(isFar ? 1.08 : 1)
    }
}
