import SwiftUI

/// Shared motion constants outside the launcher panel (whose timing lives in `SpotlightMotion`).
enum Motion {
    /// A row landing in or leaving a list: a skipped folder, an extra scan
    /// directory. Springs so an entry reads as placed rather than popped in.
    enum Insert {
        static let response: Double = 0.34
        static let dampingFraction: Double = 0.82
        /// Grown from, and collapsed back to, on the row's leading edge.
        static let startScale: CGFloat = 0.9

        static var animation: Animation {
            .spring(response: response, dampingFraction: dampingFraction)
        }

        static var transition: AnyTransition {
            .scale(scale: startScale, anchor: .leading).combined(with: .opacity)
        }
    }

    /// The gliding search-field caret (see `SmoothCaretTextField`).
    enum Caret {
        static let width: CGFloat = 2
        static let cornerRadius: CGFloat = 1
        /// Multiplier on the font's line height so the bar reads as a caret.
        static let heightScale: CGFloat = 1.05
        static let glideSeconds: CFTimeInterval = 0.105
        static let blinkPeriodSeconds: CFTimeInterval = 1.05
        /// Idle time after a keystroke before the blink resumes (solid while typing).
        static let blinkResumeSeconds: TimeInterval = 0.4
    }

    /// House easing as cubic-bezier control points, for the CoreAnimation caret.
    static let houseCurveControlPoints: (Float, Float, Float, Float) = (0.22, 1, 0.36, 1)
}
