import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherRowView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let result: LauncherResult
    let isSelected: Bool
    let isPicked: Bool
    /// Last row in the list, so the trailing divider is suppressed.
    let isLast: Bool
    /// Shared namespace for the single selection pill that glides between rows
    /// (see `Motion.Selection`). Only the selected row is the geometry source.
    let selectionNamespace: Namespace.ID
    let onOpen: () -> Void

    private enum Layout {
        /// Spotlight rows are ~58-60pt with a ~36pt icon: a title-only row
        /// would otherwise sit well under the two-line rows around it.
        static let minHeight: CGFloat = 58
        static let borderWidth: CGFloat = 1
        static let dividerHeight: CGFloat = 1
        static let dividerInset: CGFloat = 6
        static let dividerOpacity: Double = 0.8
    }

    /// Spotlight shows no dividers between rows — the selection wash alone
    /// separates them. The row keeps the divider's height either way, so
    /// selection never reflows the list.
    private var showsDivider: Bool {
        false
    }

    private var syntheticRow: SyntheticRow? {
        SyntheticRow.classify(resultID: result.id)
    }

    /// Whether the row IS the file it names, rather than something that merely
    /// lives there. A `[changed]` row is `EngineBridge.swift` at that path; a
    /// branch row is `main`, whose path is the repo every other branch shares,
    /// and giving it that folder's icon says "folder" about a branch.
    ///
    /// The title matching the last path component is what tells them apart. A
    /// block that knows better says so with its own `icon`, which still wins.
    private var rowIsItsPath: Bool {
        guard !result.path.isEmpty else { return false }
        return (result.path as NSString).lastPathComponent
            .caseInsensitiveCompare(result.title) == .orderedSame
    }

    /// Cached: this runs inside `body`, and a fresh `NSImage` per redraw makes
    /// every icon in the list flicker. See `RowIconCache`.
    private var rowIcon: NSImage {
        switch syntheticRow {
        case .commandSuggestion:
            return RowIconCache.image(key: "symbol:terminal") {
                NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                    ?? NSWorkspace.shared.icon(for: .plainText)
            }
        case .webURL:
            return RowIconCache.image(key: "symbol:globe") {
                NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                    ?? NSWorkspace.shared.icon(for: .plainText)
            }
        case .prefixSuggestion:
            return RowIconCache.image(key: "symbol:magnifyingglass") {
                NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                    ?? NSWorkspace.shared.icon(for: .plainText)
            }
        case nil:
            break
        }

        if result.kind == .clipboard {
            // A copied image shows itself. A generic icon would leave the user
            // picking from a column of identical rows named after their source.
            if let thumbnailPath = result.clipboardImageThumbnailPath,
                let thumbnail = RowIconCache.thumbnail(forFile: thumbnailPath)
            {
                return thumbnail
            }
            return RowIconCache.image(key: "symbol:doc.on.clipboard") {
                NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
                    ?? NSWorkspace.shared.icon(for: .plainText)
            }
        }

        // A row with a path IS that file, and a list of them should not be a
        // column of identical bolts. The bolt is left for rows with nothing on
        // disk, where it says the honest thing: Enter performs steps.
        if result.kind == .action {
            if rowIsItsPath {
                return RowIconCache.icon(forFile: result.path)
            }
            return RowIconCache.image(key: "symbol:bolt") {
                NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
                    ?? NSWorkspace.shared.icon(for: .plainText)
            }
        }

        // Not cached: a process icon is keyed to a live pid, and pids are reused.
        if result.kind == .process, let pid = result.processPID {
            return LauncherProcessFeature.icon(forPID: pid)
        }

        if result.id.hasPrefix("setting:") {
            let settingsPath = "/System/Applications/System Settings.app"
            if FileManager.default.fileExists(atPath: settingsPath) {
                return RowIconCache.icon(forFile: settingsPath)
            }
            let legacyPath = "/System/Applications/System Preferences.app"
            return RowIconCache.icon(forFile: legacyPath)
        }
        return RowIconCache.icon(forFile: result.path)
    }

    private var pathInfo: String {
        let parentPath = URL(fileURLWithPath: result.path).deletingLastPathComponent().path
        let components = parentPath
            .split(separator: "/")
            .map(String.init)
        let tail = components.suffix(3).joined(separator: "/")

        if tail.isEmpty {
            return "/"
        }
        if components.count > 3 {
            return ".../\(tail)"
        }
        return "/\(tail)"
    }

    private var metaFont: Font {
        themeStore.uiFont(size: CGFloat(max(10, themeStore.settings.fontSize - 3)), weight: .regular)
    }

    /// The row's second line: what it is ABOUT (parent path / metadata).
    /// Spotlight has no right-hand "kind" column — an app row is just its
    /// title, a file row is title + path/metadata below it.
    private var contextText: String {
        if syntheticRow != nil {
            return result.subtitle ?? ""
        }
        if result.kind == .clipboard || result.kind == .process {
            return result.subtitle ?? ""
        }
        if result.kind == .app {
            return ""
        }
        // A row a user's block produced says WHICH block: the kind is already
        // on the icon, and its origin is what the list cannot otherwise say.
        if result.isSourceRow {
            return result.path.isEmpty ? (result.subtitle ?? "") : pathInfo
        }
        return result.path.isEmpty ? "" : pathInfo
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    if isPicked {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(themeStore.selectionFillColor())
                            .frame(width: 14)
                    }
                    RowIcon(
                        image: rowIcon,
                        isSelected: isSelected,
                        isDeclared: result.isSourceRow,
                        themeStore: themeStore)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                            .font(themeStore.uiFont(size: CGFloat(themeStore.settings.fontSize + 2), weight: .medium))
                            .foregroundStyle(themeStore.fontColor())
                            .lineLimit(1)
                        if !contextText.isEmpty {
                            Text(contextText)
                                .font(metaFont)
                                .foregroundStyle(themeStore.mutedTextColor())
                                .lineLimit(1)
                        }
                    }
                    // Spotlight rows: title over an optional second line, no
                    // right-hand column and no shift on selection.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: Layout.minHeight)
            }
            .buttonStyle(.plain)
            .focusable(false)
            // Glides when the change is wrapped in `Motion.Selection.glide`
            // (keyboard nav), snaps otherwise (click, refresh).
            .selectionPill(
                isSelected: isSelected,
                themeStore: themeStore,
                namespace: selectionNamespace)

            Rectangle()
                .fill(themeStore.dividerColor().opacity(Layout.dividerOpacity))
                .frame(height: Layout.dividerHeight)
                .padding(.horizontal, Layout.dividerInset)
                .opacity(showsDivider ? 1 : 0)
        }
    }
}

/// The row's icon, popping with the selection.
///
/// Its own view because a view cannot read an environment value its own body
/// sets, and `selectionPill` publishes the zoom from inside `LauncherRowView`.
private struct RowIcon: View {
    @Environment(\.isSelectionZoomed) private var zoomed
    let image: NSImage
    let isSelected: Bool
    /// A row a user declared, which wears the tile the preview header already
    /// gives it. Only these rows: one on every row looks striped.
    let isDeclared: Bool
    let themeStore: ThemeStore

    private enum Tile {
        /// Spotlight-sized icon (~36pt). At 22pt a few-percent selection zoom
        /// is one point; at this size the same zoom reads as intended.
        static let size: CGFloat = 36
        static let fill: Double = 0.16
        static let ring: Double = 0.32
        static let ringWidth: CGFloat = 1
        static let inset: CGFloat = 3
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(
                width: isDeclared ? Tile.size - Tile.inset * 2 : Tile.size,
                height: isDeclared ? Tile.size - Tile.inset * 2 : Tile.size)
            .frame(width: Tile.size, height: Tile.size)
            .background {
                if isDeclared {
                    RoundedRectangle(cornerRadius: themeStore.chipRadius, style: .continuous)
                        .fill(themeStore.accentColor().opacity(Tile.fill))
                        .overlay {
                            RoundedRectangle(cornerRadius: themeStore.chipRadius, style: .continuous)
                                .strokeBorder(
                                    themeStore.accentColor().opacity(Tile.ring),
                                    lineWidth: Tile.ringWidth)
                        }
                }
            }
            .scaleEffect(isSelected && zoomed ? Motion.Selection.iconZoomScale : 1)
    }
}
