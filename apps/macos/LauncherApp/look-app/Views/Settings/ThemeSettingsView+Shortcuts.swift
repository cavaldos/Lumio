import SwiftUI

extension ThemeSettingsView {
    /// The hand-picked cheat sheet on top. Resolved by id at render time so a
    /// catalog rename removes the card instead of showing a stale copy.
    private var essentialShortcuts: [ShortcutEntry] {
        let wanted = [
            "main.open",
            "main.moveArrows",
            "main.actions",
            "main.commandMode",
            "main.reveal",
            "main.webSearch",
            "main.help",
            "main.back",
        ]
        let all = ShortcutCatalog.allEntries
        return wanted.compactMap { id in all.first(where: { $0.id == id }) }
    }

    private var filteredShortcutGroups: [ShortcutGroup] {
        guard let topic = shortcutsTopicFilter else {
            return ShortcutCatalog.groups
        }
        return ShortcutCatalog.groups(for: topic)
    }

    /// Settings curates the same catalog the help screen (`Cmd+H`) dumps in
    /// full: essentials first, topic pills to narrow, every group collapsed in
    /// a disclosure. `ShortcutGroupView` itself is untouched — help renders it
    /// directly, so the two surfaces cannot drift.
    var shortcutsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Essentials")

                essentialsGrid

                presetRow(
                    title: "Topic",
                    options: ["All"] + ShortcutTopic.allCases.map { $0.label },
                    selected: shortcutsTopicFilter
                        .flatMap { ShortcutTopic.allCases.firstIndex(of: $0).map { $0 + 1 } },
                    onPick: {
                        shortcutsTopicFilter = $0 == 0 ? nil : ShortcutTopic.allCases[$0 - 1]
                    }
                )

                ForEach(filteredShortcutGroups) { group in
                    DisclosureGroup(isExpanded: shortcutGroupBinding(group.title)) {
                        ShortcutGroupView(title: group.title, entries: group.entries)
                            .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text(group.title)
                                .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .semibold))
                                .foregroundStyle(themeStore.secondaryTextColor())
                            Text("\(group.entries.count)")
                                .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 2), weight: .regular))
                                .foregroundStyle(themeStore.mutedTextColor())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(themeStore.liftColor(opacity: 0.08), in: Capsule())
                        }
                    }
                }

                Text(HintText.Settings.shortcutsTips)
                    .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .regular))
                    .foregroundStyle(themeStore.secondaryTextColor())
            }
            .padding(.top, 4)
        }
    }

    private var essentialsGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(essentialShortcuts) { entry in
                HStack(spacing: 10) {
                    Text(entry.keys)
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 1), weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(themeStore.liftColor(opacity: 0.14), in: Capsule())
                    Text(entry.action)
                        .font(themeStore.uiFont(size: CGFloat(settings.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    themeStore.liftColor(opacity: 0.06),
                    in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
                )
            }
        }
    }

    /// Collapsed by default; everything opens while a topic filter is active so
    /// picking a pill shows its shortcuts without a second tap per group.
    private func shortcutGroupBinding(_ title: String) -> Binding<Bool> {
        Binding(
            get: { shortcutsTopicFilter != nil || expandedShortcutGroups.contains(title) },
            set: {
                if $0 {
                    expandedShortcutGroups.insert(title)
                } else {
                    expandedShortcutGroups.remove(title)
                }
            }
        )
    }
}
