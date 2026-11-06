import AppKit
import SwiftUI

/// Version + update controls for Settings > About. Sparkle (UpdateChecker)
/// shows its own windows for the result and the install.
struct AppUpdateStatusView: View {
    let themeStore: ThemeStore
    @ObservedObject private var updateChecker = UpdateChecker.shared

    private var fontSize: CGFloat { CGFloat(AppConstants.ThemeUI.fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(AppVersion.displayString)
                    .font(themeStore.uiFont(size: fontSize - 1, weight: .semibold))
                    .foregroundStyle(themeStore.fontColor())
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                if updateChecker.isEnabled {
                    pill("Check for Updates") {
                        updateChecker.checkForUpdates()
                    }
                    .disabled(!updateChecker.canCheckForUpdates)
                }
            }

            if updateChecker.isEnabled {
                Toggle(isOn: Binding(
                    get: { updateChecker.automaticallyChecksForUpdates },
                    set: { updateChecker.automaticallyChecksForUpdates = $0 }
                )) {
                    Text("Check for updates automatically")
                        .font(themeStore.uiFont(size: fontSize - 1, weight: .regular))
                }
            } else {
                Text("Updates are off in dev builds")
                    .font(themeStore.uiFont(size: fontSize - 2, weight: .regular))
                    .foregroundStyle(themeStore.mutedTextColor())
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(themeStore.uiFont(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(themeStore.fontColor())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(themeStore.liftColor(opacity: 0.16), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(themeStore.liftColor(opacity: 0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
}
