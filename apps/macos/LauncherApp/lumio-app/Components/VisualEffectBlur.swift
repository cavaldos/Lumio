import AppKit
import SwiftUI

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    /// `.behindWindow` frosts the desktop; `.withinWindow` samples the window's own backing.
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    /// nil follows the system light/dark setting.
    var appearance: NSAppearance.Name? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = appearance.flatMap(NSAppearance.init(named:))
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Reassigning the same material makes the blur flash: only set what changed.
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.appearance?.name != appearance {
            nsView.appearance = appearance.flatMap(NSAppearance.init(named:))
        }
    }
}
