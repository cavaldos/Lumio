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
                .background { FloatShadow(shape: shape, isDark: isDark) }
        } else {
            content
                .background {
                    VisualEffectBlur(
                        material: .popover,
                        blendingMode: .behindWindow,
                        appearance: isDark ? .darkAqua : .aqua
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

/// Drop shadow under the glass's outline, like Spotlight's, so it floats above the desktop.
/// Liquid Glass has no shadow of its own, and anything drawn under it shows through the
/// glass, so the shadow is cut away inside the outline and only falls outside, mostly below.
private struct FloatShadow<S: Shape>: View {
    let shape: S
    let isDark: Bool

    var body: some View {
        shape
            .fill(Color.black)
            .shadow(color: .black.opacity(isDark ? 0.50 : 0.22), radius: 14, y: 12)
            .shadow(color: .black.opacity(isDark ? 0.25 : 0.10), radius: 2, y: 2)
            .mask { OutsideOf(shape: shape).fill(style: FillStyle(eoFill: true)) }
            .allowsHitTesting(false)
    }
}

/// A big rectangle with `shape` punched out of it (even-odd fill).
private struct OutsideOf<S: Shape>: nonisolated Shape {
    let shape: S

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -80, dy: -80))
        path.addPath(shape.path(in: rect))
        return path
    }
}
