//
//  SpotlightGlass.swift
//  lumio-app
//
//  Glass layer of the Spotlight launcher.
//
//  macOS 26+: SwiftUI Liquid Glass (`glassEffect`). Inside Lumio's transparent window
//  it still samples the desktop behind it (tested on macOS 27), and when
//  glass pieces share a `SpotlightGlassGroup` with a `glassEffectID`, they
//  split/merge like water droplets — just like Spotlight's 4 round buttons.
//
//  Older macOS: behind-window blur + thin border; glass pieces appear with
//  scale + fade instead of morphing.
//

import SwiftUI

extension View {
    /// Applies glass to the view using `shape`. `id` (within `namespace`) lets the glass
    /// piece morph with other pieces in the same `SpotlightGlassGroup`.
    func spotlightGlass<S: Shape>(
        _ shape: S,
        id: String? = nil,
        in namespace: Namespace.ID,
        interactive: Bool = false,
        isDark: Bool
    ) -> some View {
        modifier(SpotlightGlassModifier(
            shape: shape,
            id: id,
            namespace: namespace,
            interactive: interactive,
            isDark: isDark
        ))
    }
}

/// Groups glass pieces so they render together and can morph into each other.
struct SpotlightGlassGroup<Content: View>: View {
    /// Two pieces closer than this distance stick together while morphing.
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private struct SpotlightGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let id: String?
    let namespace: Namespace.ID
    let interactive: Bool
    let isDark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            content
                .background {
                    VisualEffectBlur(
                        material: .popover,
                        blendingMode: .behindWindow,
                        appearance: isDark ? .dark : .light
                    )
                }
                .clipShape(shape)
                .overlay {
                    shape.stroke(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(isDark ? 0.35 : 0.15), radius: 18, y: 8)
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
        }
    }
}
