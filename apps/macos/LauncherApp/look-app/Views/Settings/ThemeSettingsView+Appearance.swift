import AppKit
import SwiftUI

extension ThemeSettingsView {
    // MARK: - Preset values (one tap instead of a slider)

    private var fontSizePresets: [(title: String, value: Double)] {
        [(title: "Compact", value: 12), (title: "Regular", value: 14), (title: "Large", value: 17)]
    }

    private var cornerPresets: [(title: String, value: Double)] {
        [(title: "Sharp", value: 0), (title: "Soft", value: 1.5), (title: "Round", value: 2.5)]
    }

    private var gapPresets: [(title: String, value: Double)] {
        [(title: "Flat", value: 0), (title: "Airy", value: 8), (title: "Wide", value: 16)]
    }

    var appearanceTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    inlinePickerLabel("Running Apps")
                    Toggle("Show running apps", isOn: Binding(
                        get: { settings.runningAppsPlacement != .none },
                        set: { settings.runningAppsPlacement = $0 ? .right : .none }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Show running apps in the right half of the search bar (⌘1-9 to switch)")

                    Spacer(minLength: 0)
                }

                Divider()
                    .overlay(themeStore.dividerColor())
                    .padding(.vertical, 4)

                sectionHeader("Theme")

                themeGrid

                if settings.uiTheme == .custom {
                    Text("Custom colors in use — pick a theme to go back to a preset.")
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.mutedTextColor())
                }

                sectionHeader("Text")

                HStack(spacing: 10) {
                    Text("Font")
                        .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())

                    Picker("Font", selection: $settings.fontName) {
                        ForEach(themeStore.fontFamilyOptions(including: settings.fontName), id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)

                    Text("AaBbCc 123")
                        .font(fontPreview)
                        .foregroundStyle(themeStore.mutedTextColor())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                presetRow(
                    title: "Size",
                    options: fontSizePresets.map { $0.title },
                    selected: fontSizePresets.firstIndex(where: { abs($0.value - settings.fontSize) < 0.01 }),
                    onPick: { settings.fontSize = fontSizePresets[$0].value }
                )

                sectionHeader("Shape")

                presetRow(
                    title: "Corners",
                    options: cornerPresets.map { $0.title },
                    selected: cornerPresets.firstIndex(where: { abs($0.value - settings.surfaceRadius) < 0.01 }),
                    onPick: { settings.surfaceRadius = cornerPresets[$0].value }
                )

                presetRow(
                    title: "Spacing",
                    options: gapPresets.map { $0.title },
                    selected: gapPresets.firstIndex(where: { abs($0.value - settings.innerGap) < 0.01 }),
                    onPick: { settings.innerGap = gapPresets[$0].value }
                )
                .help("Gap between the top row, results list and preview. Flat merges them; Airy/Wide turns each into its own card.")

                sectionHeader("Backdrop Effect")

                blurGrid

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledSlider(
                            title: "Inner Gap",
                            value: $settings.innerGap,
                            range: AppConstants.ThemeUI.innerGapRange)

                        LabeledSlider(
                            title: "Corner Radius",
                            value: $settings.surfaceRadius,
                            range: AppConstants.ThemeUI.surfaceRadiusRange)

                        LabeledColorPicker(title: "Tint", value: tintColorBinding)
                        LabeledSlider(title: "Tint Opacity", value: $settings.tintOpacity, range: 0...1)

                        LabeledSlider(title: "Blur Opacity", value: $settings.blurOpacity, range: 0...1)
                            .disabled(settings.blurMaterial.rendersGlass)
                            .opacity(settings.blurMaterial.rendersGlass ? AppConstants.ThemeUI.disabledControlOpacity : 1)
                        LabeledSlider(title: "Settings Blur", value: $settings.settingsBlurMultiplier, range: 0.4...1)

                        LabeledSlider(title: "Font Size", value: $settings.fontSize, range: 10...28)
                        LabeledColorPicker(title: "Text", value: fontColorBinding)
                        LabeledSlider(title: "Text Opacity", value: $settings.fontOpacity, range: 0...1)

                        LabeledColorPicker(title: "Border", value: borderColorBinding)
                        LabeledSlider(title: "Border Thick", value: $settings.borderThickness, range: 0...6)
                        LabeledSlider(title: "Border Opacity", value: $settings.borderOpacity, range: 0...1)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Fine tuning")
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .semibold))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
            }
        }
    }

    // MARK: - Theme preset grid

    private var themeGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(BuiltinThemePreset.options(including: settings.uiTheme)) { preset in
                let isActive = settings.uiTheme == preset
                Button {
                    settings.uiTheme = preset
                    themeStore.applyBuiltinTheme(preset)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            ForEach(presetSwatches(preset).indices, id: \.self) { index in
                                Circle()
                                    .fill(presetSwatches(preset)[index])
                                    .frame(width: 14, height: 14)
                            }
                        }
                        Text(preset.pickerTitle)
                            .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 2), weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? themeStore.fontColor() : themeStore.secondaryTextColor())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        themeStore.liftColor(opacity: isActive ? ThemeSettingsView.activeTabFillOpacity : ThemeSettingsView.inactiveTabFillOpacity),
                        in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                            .stroke(themeStore.fontColor(opacityMultiplier: 0.6), lineWidth: isActive ? 1.5 : 0)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Preview dots only — border is boosted to stay visible on the card.
    private func presetSwatches(_ preset: BuiltinThemePreset) -> [Color] {
        guard let style = preset.style else {
            return [.gray, .gray, .gray]
        }
        return [
            Color(red: style.tintRed, green: style.tintGreen, blue: style.tintBlue),
            Color(red: style.fontRed, green: style.fontGreen, blue: style.fontBlue),
            Color(
                red: style.borderRed,
                green: style.borderGreen,
                blue: style.borderBlue,
                opacity: max(style.borderOpacity, 0.5)
            ),
        ]
    }

    // MARK: - Small preset rows (Size / Corners / Spacing)

    func presetRow(title: String, options: [String], selected: Int?, onPick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .regular))
                .foregroundStyle(themeStore.secondaryTextColor())

            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let isActive = selected == index
                    Button {
                        onPick(index)
                    } label: {
                        Text(options[index])
                            .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? themeStore.fontColor() : themeStore.secondaryTextColor())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                themeStore.liftColor(opacity: isActive ? ThemeSettingsView.activeTabFillOpacity : ThemeSettingsView.inactiveTabFillOpacity),
                                in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Backdrop effect presets

    private var blurGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(LauncherBlurMaterial.options(including: settings.blurMaterial)) { item in
                presetCard(title: item.pickerTitle, detail: item.detail, isActive: settings.blurMaterial == item) {
                    settings.blurMaterial = item
                }
            }
        }
    }

    /// One selectable card (title + optional detail), shared by the preset grids
    /// in Appearance and Advanced so every preset looks like the same control.
    func presetCard(title: String, detail: String? = nil, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? themeStore.fontColor() : themeStore.secondaryTextColor())
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.mutedTextColor())
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                themeStore.liftColor(opacity: isActive ? ThemeSettingsView.activeTabFillOpacity : ThemeSettingsView.inactiveTabFillOpacity),
                in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                    .stroke(themeStore.fontColor(opacityMultiplier: 0.6), lineWidth: isActive ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - ColorPicker bindings (RGB doubles <-> Color)

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: settings.tintRed, green: settings.tintGreen, blue: settings.tintBlue) },
            set: {
                let c = Self.srgbComponents(of: $0)
                settings.tintRed = c.red
                settings.tintGreen = c.green
                settings.tintBlue = c.blue
            }
        )
    }

    private var fontColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: settings.fontRed, green: settings.fontGreen, blue: settings.fontBlue) },
            set: {
                let c = Self.srgbComponents(of: $0)
                settings.fontRed = c.red
                settings.fontGreen = c.green
                settings.fontBlue = c.blue
            }
        )
    }

    private var borderColorBinding: Binding<Color> {
        Binding(
            get: { Color(red: settings.borderRed, green: settings.borderGreen, blue: settings.borderBlue) },
            set: {
                let c = Self.srgbComponents(of: $0)
                settings.borderRed = c.red
                settings.borderGreen = c.green
                settings.borderBlue = c.blue
            }
        )
    }

    private var fontPreview: Font {
        let name = settings.fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, NSFont(name: name, size: 13) != nil {
            return .custom(name, size: 13)
        }
        return .system(size: 13)
    }

    private static func srgbComponents(of color: Color) -> (red: Double, green: Double, blue: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    @ViewBuilder
    func inlinePickerLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text("▶")
                .font(.system(size: CGFloat(settings.fontSize - 2)))
                .foregroundStyle(themeStore.secondaryTextColor())
            Text(title)
                .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .semibold))
                .foregroundStyle(themeStore.secondaryTextColor())
        }
    }
}

/// One color well + swatch row, kept for the Fine-tuning section.
private struct LabeledColorPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    @Binding var value: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: AppConstants.ThemeUI.labelWidth, alignment: .leading)
                .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize - 1), weight: .regular))
                .foregroundStyle(themeStore.secondaryTextColor())
            ColorPicker("", selection: $value, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 60, alignment: .leading)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(value)
                .frame(width: 120, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(themeStore.liftColor(opacity: 0.12), lineWidth: 1)
                )
        }
    }
}
