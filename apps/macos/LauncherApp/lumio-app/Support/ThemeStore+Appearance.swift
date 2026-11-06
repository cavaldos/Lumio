import AppKit
import SwiftUI

/// Settings-window styling. System font and colors, so the window follows the
/// macOS light/dark appearance like the launcher does.
extension ThemeStore {
    func uiFont(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        .system(size: size ?? AppConstants.ThemeUI.fontSize, weight: weight)
    }

    func fontColor(opacityMultiplier: Double = 1.0) -> Color {
        Color.primary.opacity(opacityMultiplier)
    }

    func secondaryTextColor() -> Color { .secondary }
    func mutedTextColor() -> Color { Color(nsColor: .tertiaryLabelColor) }
    func dividerColor() -> Color { Color(nsColor: .separatorColor) }
    func liftColor(opacity: Double) -> Color { Color.primary.opacity(opacity) }
    func accentColor() -> Color { .accentColor }
    func successColor() -> Color { .green }
    func onSuccessColor() -> Color { .white }
    func dangerColor() -> Color { .red }
    func onDangerColor() -> Color { .white }

    var controlRadius: CGFloat { 8 }
}
