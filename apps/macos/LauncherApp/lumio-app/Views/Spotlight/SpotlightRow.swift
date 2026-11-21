import AppKit
import SwiftUI

// One result row of the launcher list, and the pieces only rows use.
//
// The row is a separate `Equatable` view with value inputs so SwiftUI can skip the body of every
// row whose inputs did not change: moving the selection or the hover re-evaluates the launcher
// view but only the two rows whose `selected` flipped. Closures are NOT part of the comparison, so
// each one may only use what `==` compares (see `SpotlightRow.==`).

struct SpotlightRow: View, Equatable {
    private typealias Metric = SpotlightSpec.Metric

    /// The row as displayed (a translation row already carries its translated text).
    let item: SpotlightItem
    let selected: Bool
    /// :kill — this process is armed, the next Enter kills it.
    let armed: Bool
    /// Clipboard image rows: the thumbnail, loaded by the list (nil = not on disk yet).
    let thumbnail: NSImage?
    /// App rows: the app is running (green dot; ⏎ switches to it).
    var running = false
    /// Typed words shown in bold in the title (Fluent Search-style); empty = plain title.
    var highlight: [String] = []
    let palette: SpotlightPalette
    let reduceMotion: Bool
    let namespace: Namespace.ID
    /// Clipboard rows: pin / delete this clip. Built by the list from the same `item`.
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    /// Everything that changes what the row shows, except the closures: those only use
    /// `item.kind`, `clipID`, `payload` and `isPinned`, all compared here, so a skipped row
    /// never keeps a closure that would act on a different clip.
    static func == (lhs: SpotlightRow, rhs: SpotlightRow) -> Bool {
        lhs.item.sameRowContent(as: rhs.item)
            && lhs.selected == rhs.selected && lhs.armed == rhs.armed
            && lhs.thumbnail === rhs.thumbnail
            && lhs.running == rhs.running && lhs.highlight == rhs.highlight
            && lhs.palette.isDark == rhs.palette.isDark
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.namespace == rhs.namespace
    }

    static let clipRowHeight: CGFloat = 30
    static let clipImageRowHeight: CGFloat = 64
    /// tw": the list is a narrow column of words, like the Dictionary.app sidebar.
    static let wordRowHeight: CGFloat = 32

    var body: some View {
        if item.kind == .lookup {
            wordRow
        } else if item.kind == .clip || item.kind == .clipImage {
            clipRow
        } else {
            standardRow
        }
    }

    private var selection: SpotlightSelection {
        SpotlightSelection(
            isSelected: selected,
            fill: palette.rowSel,
            namespace: namespace,
            reduceMotion: reduceMotion
        )
    }

    /// tw": just the word, like the Dictionary.app sidebar.
    private var wordRow: some View {
        Text(item.name)
            .font(.system(size: 14.5, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Self.wordRowHeight)
            .modifier(selection)
            .contentShape(Rectangle())
    }

    /// Clipboard: just the copied text on one line, or a thumbnail of the image. The full text
    /// and details open in the side preview (see `scheduleClipPreview`).
    private var clipRow: some View {
        let isImage = item.kind == .clipImage
        return Group {
            if isImage, let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(maxHeight: Self.clipImageRowHeight - 12)
            } else {
                Text(item.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.trailing, selected ? (item.isPinned ? 46 : 46) : (item.isPinned ? 24 : 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .overlay(alignment: .trailing) {
            clipRowButtons.padding(.trailing, 6)
        }
        .frame(height: isImage ? Self.clipImageRowHeight : Self.clipRowHeight)
        .modifier(selection)
        .contentShape(Rectangle())
    }

    /// Pin and delete, on the selected clip. A pinned clip always shows its pin.
    @ViewBuilder
    private var clipRowButtons: some View {
        if selected || item.isPinned {
            HStack(spacing: 4) {
                clipIconButton(
                    item.isPinned ? "pin.fill" : "pin",
                    help: item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)",
                    active: item.isPinned,
                    action: onTogglePin
                )
                if selected {
                    clipIconButton("trash", help: "Delete (⌘D)", action: onDelete)
                }
            }
            .padding(.leading, 6)
        }
    }

    private func clipIconButton(
        _ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .background(palette.kbd, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var standardRow: some View {
        HStack(spacing: 11) {
            SpotlightRowIcon(item: item, size: 30, isSelected: selected)
            // Narrow left column (right half is the preview): name on top, path / description below.
            VStack(alignment: .leading, spacing: 2) {
                titleText
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let meta = rowMeta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if running {
                // Running: ⏎ switches to it instead of launching.
                Circle()
                    .fill(Color(nsColor: .systemGreen))
                    .frame(width: 6, height: 6)
                    .help("Running")
            }
            // Change IMMEDIATELY on selection: cross-fading them in step with the slide would make the
            // text of both states overlap.
            Group {
                if item.kind == .calc, let converted = item.payload {
                    Text("= \(converted)")
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .fixedSize()
                } else if item.kind == .calc, let calcResult = item.calcResult {
                    Text("= \(SpotlightCalc.format(calcResult))")
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .fixedSize()
                } else if selected {
                    keyCap("⏎")
                } else if armed {
                    keyCap("⏎")
                }
            }
            .animation(nil, value: selected)
        }
        .padding(.horizontal, 10)
        .frame(height: Metric.rowHeight)
        .modifier(selection)
        .contentShape(Rectangle())
    }

    /// The title, with the typed words in bold where they appear (like Fluent Search).
    private var titleText: Text {
        if item.kind == .web, item.target == nil, !item.id.hasPrefix("suggest|") {
            return Text("Search the web — \(item.name)")
        }
        guard !highlight.isEmpty else { return Text(item.name) }
        var title = AttributedString(item.name)
        for word in highlight {
            var remaining = title.startIndex..<title.endIndex
            while let match = title[remaining].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                title[match].font = .system(size: 14.5, weight: .heavy)
                remaining = match.upperBound..<title.endIndex
            }
        }
        return Text(title)
    }

    /// Secondary line under the name. Apps don't need one (the name is enough); action rows show the item name.
    private var rowMeta: String? {
        switch item.kind {
        case .app: return nil
        case .cmd: return nil
        default: return item.meta ?? item.kind.label
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Background of the selected row. ONE single bar is moved between rows via
/// `matchedGeometryEffect`, so it SLIDES when the selection change happens inside
/// `withAnimation` (arrow keys, hover) and jumps straight when it doesn't (new results).
/// The newly selected row also zooms up one beat and back — same approach as the legacy launcher's
/// SelectionPill, just a different color (follows the glass, not the theme).
struct SpotlightSelection: ViewModifier {
    let isSelected: Bool
    let fill: Color
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @State private var zoomed = false
    /// Incremented on each zoom: the return leg of an old beat doesn't cut off a new one
    /// (moving away then back very quickly).
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            // Pushed down so the row's icon zooms in step.
            .environment(\.isSelectionZoomed, zoomed)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SpotlightSpec.Metric.rowRadius, style: .continuous)
                        .fill(fill)
                        .matchedGeometryEffect(id: "spotlight.selection", in: namespace)
                        .scaleEffect(zoomed ? SpotlightMotion.pillZoomScale : 1)
                }
            }
            // No .animation(value:) here: attached per row, every row the
            // selection bar passes over would flash.
            .onChange(of: isSelected) { _, selected in
                generation &+= 1
                guard selected else {
                    zoomed = false
                    return
                }
                guard !reduceMotion else { return }
                let mine = generation
                withAnimation(SpotlightMotion.zoomIn) { zoomed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + SpotlightMotion.zoomInSeconds) {
                    guard mine == generation else { return }
                    withAnimation(SpotlightMotion.zoomOut) { zoomed = false }
                }
            }
    }
}

/// The row's icon, zooming with the selection beat. A separate view because a view can't read
/// environment values set by its own body.
struct SpotlightRowIcon: View {
    @Environment(\.isSelectionZoomed) private var zoomed
    let item: SpotlightItem
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        SpotlightTile(item: item, size: size)
            .scaleEffect(isSelected && zoomed ? SpotlightMotion.iconZoomScale : 1)
    }
}

private struct SelectionZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True during the one-shot zoom of the newly selected row.
    var isSelectionZoomed: Bool {
        get { self[SelectionZoomedKey.self] }
        set { self[SelectionZoomedKey.self] = newValue }
    }
}
