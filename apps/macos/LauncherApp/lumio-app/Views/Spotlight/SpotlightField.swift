//
//  SpotlightField.swift
//  lumio-app
//
//  ONE component. It resizes itself to fit its own content.
//
//  USAGE
//  ─────────
//  No "results component" is created when there are results. There is only
//  this SpotlightField: when the search field is empty it is a small pill, and as soon as
//  there is content inside, it stretches into a panel — exactly like component A in the
//  example. No component is added; the component grows.
//
//  THREE GUARANTEES
//  ───────────────
//  1. The results area is ALWAYS built in the view tree, even when empty — it just has
//     zero height. No `if` makes it disappear and reappear, so there is
//     never "a new component on top".
//
//  2. The content tree has `.transaction { $0.animation = nil }`: even if the caller
//     wraps it in `withAnimation`, text, rows and borders stay still. Guaranteed in code.
//
//  3. The whole launcher has only ONE animation for the main part: the height of this
//     component itself. No fade, no slide, no cascade, no scale. The content
//     is already built at full size, so growing just reveals it from the
//     bottom up — no frame has to re-lay out, no text slides.
//     (The toast is the only exception: a small independent view, see Reveal.toast.)
//
//  The height comes from measuring the content, but the measurement runs only ONCE per
//  data change (not every frame) because nothing in the content tree
//  animates.
//

import SwiftUI

struct SpotlightField: View {
    // State
    let isVisible: Bool
    let query: Binding<String>
    let rows: [SpotlightItem]
    let selection: Int
    let filter: SpotlightKind?
    let filterKinds: [SpotlightKind]
    let scopeName: String?
    let toast: String?
    let isDark: Bool
    /// Maximum width (the field shrinks with narrow windows).
    var maxWidth: CGFloat = 900

    var onSelectRow: (Int) -> Void = { _ in }
    var onSelectFilter: (SpotlightKind?) -> Void = { _ in }
    /// Natural height of the field, so the owner (window) can leave room.
    /// Placed last so trailing closures bind correctly to onSelectRow/onSelectFilter.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Measured height of the content (0 when empty).
    @State private var contentHeight: CGFloat = 0

    private var palette: SpotlightPalette { .of(isDark ? .dark : .light) }
    private var hasResults: Bool { !rows.isEmpty }
    /// Target height: bar + measured content. When empty, only the bar remains.
    private var fieldHeight: CGFloat {
        isVisible ? SpotlightSpec.Metric.barHeight + contentHeight : 0
    }

    var body: some View {
        ZStack {
            surface
            // The content is always built; only its height is 0 when empty.
            // `fixedSize` keeps the layout independent of the shrinking frame so the measurement
            // isn't affected by it (measuring inside a 0 frame always yields 0).
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard abs(height - contentHeight) > 0.5 else { return }
                    contentHeight = height
                }
        }
        // ── THE ONLY ANIMATION IN THE WHOLE LAUNCHER ──
        // Only this component's frame grows/shrinks. Nothing inside
        // moves, so nothing has to redraw every frame.
        .frame(width: min(SpotlightSpec.Metric.panelWidth, maxWidth))
        .frame(height: fieldHeight, alignment: .top)
        .animation(SpotlightSpec.Reveal.field, value: fieldHeight)
        .clipShape(RoundedRectangle(cornerRadius: SpotlightSpec.Metric.pillRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SpotlightSpec.Metric.pillRadius, style: .continuous)
                .strokeBorder(palette.panelLine, lineWidth: 1)
        }
        .shadow(color: palette.shadow, radius: 22, y: 10)
        .shadow(color: Color.black.opacity(palette.isDark ? 0.4 : 0.12), radius: 4, y: 2)
        .overlay(alignment: .top) {
            if fieldHeight > 0 {
                Rectangle()
                    .fill(palette.panelRing)
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            toastChip
                .animation(SpotlightSpec.Reveal.toast, value: toast)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard height > 0 else { return }
            onHeightChange(height)
        }
    }

    // MARK: - Glass surface

    private var surface: some View {
        ZStack {
            // Frost sampled from the desktop. Transaction locked: inside any
            // transaction the glass layer gets recomposited every frame.
            VisualEffectBlur(
                material: .popover,
                blendingMode: .behindWindow,
                appearance: isDark ? .dark : .light
            )
            .transaction { $0.animation = nil }
            palette.panel
        }
    }

    // MARK: - Content (fully static)

    private var content: some View {
        VStack(spacing: 0) {
            searchRow
            if hasResults {
                // This is NOT a separate results component — it is the lower
                // part of this field itself, and it stays here for the view's whole lifetime.
                Divider()
                    .background(palette.divider)
                    .padding(.top, 8)
                pills
                results
                footer
            }
        }
        .clipped()
        // CONTRACT: nothing in here is animated. Even if the caller
        // wraps state in withAnimation, text and rows stay still.
        .transaction { $0.animation = nil }
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19))
                .foregroundStyle(palette.dim)
                .frame(width: 24, height: 24)

            if let scopeName {
                Text(scopeName)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(palette.pillOn, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            TextField(scopeName == nil ? "Spotlight Search" : "Search in \(scopeName ?? "")", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 23))
                .foregroundStyle(palette.text)
        }
        .padding(.horizontal, SpotlightSpec.Metric.barPadding)
        .frame(height: SpotlightSpec.Metric.barHeight)
    }

    // MARK: - Filter pills

    private var pills: some View {
        HStack(spacing: SpotlightSpec.Metric.pillGap) {
            pillButton("All", active: filter == nil) { onSelectFilter(nil) }
            ForEach(filterKinds) { kind in
                pillButton(kind.label, active: filter == kind) { onSelectFilter(kind) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func pillButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14.5, weight: active ? .medium : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(active ? palette.pillOn : palette.pill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results

    private var results: some View {
        ScrollView(.vertical, showsIndicators: rows.count > SpotlightSpec.Metric.maxVisibleRows) {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { position, item in
                    resultRow(item, index: position, selected: position == selection)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        // Fixed height by row count: don't let the ScrollView grow on its own, since it would take
        // all the room the window offers and report that height back — a measurement loop.
        .frame(height: CGFloat(min(rows.count, SpotlightSpec.Metric.maxVisibleRows)) * SpotlightSpec.Metric.rowHeight + 8)
    }

    private func resultRow(_ item: SpotlightItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 13) {
            SpotlightTile(item: item, size: SpotlightSpec.Metric.tileSize)

            Text(item.name)
                .font(.system(size: 16))
                .lineLimit(1)

            Spacer(minLength: 8)

            if selected {
                Text("Search in \(item.name)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                Text("tab")
                    .font(.system(size: 12))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(palette.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let meta = item.meta {
                Text(meta)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
            } else {
                Text(item.kind.label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SpotlightSpec.Metric.rowHeight)
        // Change the selected row instantly like a native list. Knowing which row will open
        // matters more to the user than seeing it slide from one row to another.
        .background(selected ? palette.rowSel : Color.clear, in: RoundedRectangle(cornerRadius: SpotlightSpec.Metric.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onSelectRow(index) }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↑↓ select")
            Text("⏎ open")
            Text("esc close")
            Spacer()
            Text("\(rows.count) results")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(palette.faint)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
        }
    }

    // MARK: - Toast
    //
    // Lives outside the static tree, so it may fade: a small, independent view, cheap
    // to composite. Toggling it instantly would look like a glitch.

    @ViewBuilder
    private var toastChip: some View {
        if let toast, isVisible {
            Text(toast)
                .font(.system(size: 14.5))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transaction { $0.animation = nil }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.panelLine, lineWidth: 1)
                }
                .shadow(color: palette.shadow, radius: 12, y: 6)
                .padding(14)
                .transition(.opacity)
        }
    }
}
