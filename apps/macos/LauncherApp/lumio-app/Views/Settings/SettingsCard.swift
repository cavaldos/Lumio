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
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
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

/// One row, laid out like Fluent Search's settings cards: an icon, the title with an optional
/// explanation under it, and `control` on the right. `below` holds content that needs the
/// full card width (chips, lists). The row lights up under the pointer.
struct SettingsRow<Control: View, Below: View>: View {
    @EnvironmentObject var themeStore: ThemeStore
    let title: String
    /// SF Symbol shown at the start of the row.
    var icon: String?
    var detail: String?
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(themeStore.fontColor().opacity(0.9))
                        .frame(width: 26, alignment: .center)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize), weight: .medium))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(themeStore.liftColor(opacity: hovering ? 0.045 : 0))
        .onHover { hovering = $0 }
    }
}

extension SettingsRow where Below == EmptyView {
    init(_ title: String, icon: String? = nil, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.control = control()
        self.below = EmptyView()
    }
}

extension SettingsRow {
    init(
        _ title: String,
        icon: String? = nil,
        detail: String? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder below: () -> Below
    ) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.control = control()
        self.below = below()
    }
}

/// On/off row with a switch and its state spelled out ("On" / "Off") beside it.
struct SettingsToggleRow: View {
    @EnvironmentObject var themeStore: ThemeStore
    let title: String
    var icon: String?
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, icon: String? = nil, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, icon: icon, detail: detail) {
            HStack(spacing: 9) {
                Text(isOn ? "On" : "Off")
                    .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                    .foregroundStyle(themeStore.secondaryTextColor())
                    .frame(minWidth: 22, alignment: .trailing)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}
