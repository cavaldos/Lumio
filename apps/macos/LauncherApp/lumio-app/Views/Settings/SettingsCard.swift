import SwiftUI

// Building blocks for the Settings page: a bold section title, a rounded card that
// groups related rows, and rows with the label (plus an optional explanation) on
// the left and the control on the right — the System Settings layout.

/// Bold heading above a card.
struct SettingsSectionTitle: View {
    @EnvironmentObject var themeStore: ThemeStore
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize), weight: .bold))
            .foregroundStyle(themeStore.fontColor())
            .padding(.leading, 4)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

/// Rounded, softly filled box holding one section's rows. Put a `SettingsDivider`
/// between rows.
struct SettingsCard<Content: View>: View {
    @EnvironmentObject var themeStore: ThemeStore
    @ViewBuilder var content: Content

    private static var radius: CGFloat { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            themeStore.liftColor(opacity: 0.045),
            in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(themeStore.liftColor(opacity: 0.08), lineWidth: 1)
        )
    }
}

/// Hairline between two rows of a card, inset like System Settings.
struct SettingsDivider: View {
    @EnvironmentObject var themeStore: ThemeStore

    var body: some View {
        Rectangle()
            .fill(themeStore.liftColor(opacity: 0.08))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

/// One row: title and optional explanation on the left, `control` on the right.
/// `below` holds content that needs the full card width (chips, lists).
struct SettingsRow<Control: View, Below: View>: View {
    @EnvironmentObject var themeStore: ThemeStore
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize), weight: .regular))
                        .foregroundStyle(themeStore.fontColor())
                    if let detail {
                        Text(detail)
                            .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                            .foregroundStyle(themeStore.secondaryTextColor())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            below
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Below == EmptyView {
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
        self.below = EmptyView()
    }
}

extension SettingsRow {
    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder below: () -> Below
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
        self.below = below()
    }
}

/// On/off row with a switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
