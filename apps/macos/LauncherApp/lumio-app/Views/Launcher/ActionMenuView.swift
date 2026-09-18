import SwiftUI

/// Everything you can do to the selected row, in one popup (Cmd+K).
struct ActionMenuView: View {
    let descriptors: [LauncherView.RowActionDescriptor]
    let focusedIndex: Int
    let themeStore: ThemeStore
    let onActivate: (LauncherView.RowActionDescriptor) -> Void

    private typealias Layout = AppConstants.Launcher.ActionMenu

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(descriptors.enumerated()), id: \.element.id) { pair in
                        row(pair.element, isFocused: pair.offset == focusedIndex)
                            .id(pair.offset)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, new in contentHeight = new }
                    }
                )
            }
            .frame(height: min(contentHeight, Layout.maxHeight))
            .onChange(of: focusedIndex) { _, index in
                withAnimation(Motion.Selection.glide) { proxy.scrollTo(index) }
            }
        }
        .padding(4)
        .background(menuBackground)
        .overlay(menuBorder)
    }

    private var menuCornerRadius: CGFloat {
        themeStore.barRadius
    }

    private var menuBackground: some View {
        RoundedRectangle(cornerRadius: menuCornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .background(
                RoundedRectangle(cornerRadius: menuCornerRadius, style: .continuous)
                    .fill(themeStore.panelFillColor())
            )
            .shadow(color: .black.opacity(0.45), radius: Layout.shadowRadius, x: 0, y: 8)
    }

    private var menuBorder: some View {
        RoundedRectangle(cornerRadius: menuCornerRadius, style: .continuous)
            .strokeBorder(themeStore.dividerColor(), lineWidth: 1)
    }

    private func row(_ descriptor: LauncherView.RowActionDescriptor, isFocused: Bool) -> some View {
        HStack {
            Text(descriptor.title)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 1), weight: .medium))
                .foregroundStyle(themeStore.fontColor())
                .lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut = descriptor.shortcut {
                Text(shortcut)
                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .regular))
                    .foregroundStyle(themeStore.mutedTextColor())
            }
            if isFocused {
                Text(Layout.runHint)
                    .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 2), weight: .semibold))
                    .foregroundStyle(themeStore.secondaryTextColor())
            }
        }
        .padding(.horizontal, Layout.rowHorizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isFocused: isFocused))
        .contentShape(Rectangle())
        .onTapGesture { onActivate(descriptor) }
    }

    private func rowBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: themeStore.chipRadius, style: .continuous)
            .fill(isFocused ? themeStore.selectionFillColor() : Color.clear)
    }
}
