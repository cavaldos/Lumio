//
//  SpotlightPreview.swift
//  lumio-app
//
//  Preview pane on the right of the panel. Layout follows the legacy launcher's preview
//  (ResultPreviewView): large icon, name, kind label + size, content (syntax-highlighted
//  code / QuickLook image / folder listing), then path + modified date.
//
//  Painted with system colors rather than the theme: this pane is Liquid Glass and switches
//  light/dark with the system, while theme colors could be light text on light glass.
//  Core pieces reused from the legacy launcher: SyntaxHighlighter + HighlightedTextView,
//  QuickLookPreviewImage, FolderListingService.
//

import AppKit
import SwiftUI

/// One quick action in the preview pane (Open, Show in Finder, Quit…), like Fluent Search's
/// result actions. The launcher builds them; the pane only draws and triggers them.
struct PreviewAction: Identifiable {
    let id: String
    let label: String
    /// Shorter text for the compact strip ("Show" for "Show in Path Finder").
    var short: String? = nil
    let symbol: String
    var shortcut: String? = nil
    let run: () -> Void
}

/// A tag chip on the detail card (file, .psd, the parent folder, the site…): click to narrow
/// the search to it, like Fluent Search's result tags.
struct PreviewChip: Identifiable {
    let id: String
    let label: String
    var symbol: String? = nil
    /// An app's path, to show its icon on the chip.
    var appPath: String? = nil
    let run: () -> Void
}

struct SpotlightPreviewView: View {
    let item: SpotlightItem
    /// Tag chips for this result.
    var chips: [PreviewChip] = []
    /// false = the details card (info, chips, actions); true = the file's preview. ⌥P toggles.
    var showsPreview = false
    var onTogglePreview: () -> Void = {}
    /// Quick actions for this row. Apps and links get a full list (their pane is otherwise
    /// empty); files and folders get a compact strip above the preview.
    var actions: [PreviewAction] = []
    /// ps" / :kill — process details (loaded on selection) and CPU (measured on Enter).
    var processDetail: ProcessDetail? = nil
    var processCPU: Double? = nil
    var measuringCPU = false
    /// A file or folder in the folder listing was clicked: (path, isFolder).
    var onOpenPath: (String, Bool) -> Void = { _, _ in }
    /// tw" — a linked word in a dictionary entry was clicked.
    var onLookup: (String) -> Void = { _ in }
    /// tr" — translations of the typed text.
    var translation = SpotlightTranslationBatch()

    @State private var info = Info()
    @State private var folder: FolderListing?

    /// Extra info read from disk when a row is selected.
    struct Info {
        var detail: String?
        var modified: String?
        var version: String?
        /// "Documents › Photoshop Projects › name.psd"
        var location: String?
        /// "2 years ago"
        var modifiedAgo: String?
        var size: String?
    }

    /// Results that get the Fluent-style card: something to open, with actions.
    private var usesCard: Bool {
        !actions.isEmpty && [.doc, .content, .folder, .app, .url, .tab, .web, .setting, .window].contains(item.kind)
    }

    /// Files and folders have a real preview to switch to; apps and links only have the card.
    private var hasPreview: Bool {
        (item.kind.isDocument || item.kind == .folder) && item.target?.hasPrefix("/") == true
    }

    var body: some View {
        if item.kind == .lookup {
            // Dictionary.app layout: the entry has its own headword, so no header / details.
            SpotlightDictionaryView(word: item.payload ?? item.name, onLookup: onLookup)
        } else if item.kind == .translation, let target = TranslationLanguage.named(item.payload) {
            SpotlightTranslationView(batch: translation, target: target)
        } else {
            standard
        }
    }

    @ViewBuilder
    private var standard: some View {
        if usesCard, !(hasPreview && showsPreview) {
            card
        } else {
            classic
        }
    }

    /// Fluent Search's detail card: big icon, name, facts, tag chips, then every action.
    private var card: some View {
        ScrollView(.vertical) {
            VStack(spacing: 11) {
                SpotlightTile(item: item, size: 68)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .padding(.top, 6)
                Text(item.name)
                    .font(.system(size: 15.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                cardFacts
                if !chips.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(chips) { chip in PreviewChipButton(chip: chip) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                actionList
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .overlay(alignment: .topTrailing) { paneButtons }
        .task(id: item.id) { info = Self.loadInfo(for: item) }
    }

    /// Location / Modified / Size (files), Url (links), Version (apps).
    @ViewBuilder
    private var cardFacts: some View {
        let link = item.tab?.url ?? item.target.flatMap { $0.hasPrefix("http") ? $0 : nil }
        if info.location != nil || info.modifiedAgo != nil || info.size != nil || info.version != nil || link != nil
            || item.kind == .window
        {
            VStack(alignment: .leading, spacing: 5) {
                if let link { factRow("Url", link) }
                if item.kind == .window, let app = item.meta { factRow("Window", app) }
                if let location = info.location { factRow("Location", location) }
                if let version = info.version { factRow("Version", version) }
                if let modified = info.modifiedAgo { factRow("Modified", modified) }
                if let size = info.size { factRow("Size", size) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }

    /// Top-right corner: switch between the card and the preview (⌥P), and Quick Look.
    private var paneButtons: some View {
        HStack(spacing: 4) {
            if hasPreview, usesCard {
                PreviewToggleButton(showingPreview: showsPreview, action: onTogglePreview)
            }
            if item.kind.isDocument, item.target?.hasPrefix("/") == true {
                PreviewExpandButton { SpotlightQuickLook.show(item: item) }
            }
        }
        .padding(12)
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if usesActionList {
                // Scrolls rather than overflowing the pane when the panel is short.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        content
                        actionList
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                if !actions.isEmpty { actionStrip }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            details
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .topTrailing) { paneButtons }
        .task(id: item.id) {
            info = Self.loadInfo(for: item)
            folder = nil
            guard item.kind == .folder, let path = item.target else { return }
            // Dwell like QuickLookPreviewImage: skimming past quickly doesn't list anything.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let listing = await FolderListingService.list(path: path)
            guard !Task.isCancelled else { return }
            folder = listing
            if let listing { info.detail = Self.countText(listing) }
        }
    }

    // MARK: - Quick actions

    private var usesActionList: Bool {
        !actions.isEmpty && [.app, .url, .tab, .web, .setting].contains(item.kind)
    }

    /// Full list, first action highlighted (it is what ⏎ does).
    private var actionList: some View {
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                PreviewActionRow(action: action, primary: index == 0)
            }
        }
    }

    /// Compact buttons for files and folders, so the preview keeps its room.
    private var actionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                // The first few: the rest are one ⌥P (details card) or ⌘K away.
                ForEach(Array(actions.prefix(5))) { action in
                    PreviewActionChip(action: action)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            SpotlightTile(item: item, size: 48)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    Text(item.kind.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color(nsColor: .systemBlue), in: Capsule())
                    if let detail = info.detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 58)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .doc, .content:
            if let path = item.target {
                if QuickLookPreviewService.isTextFile(path: path) {
                    SpotlightCodePreview(path: path)
                } else {
                    QuickLookPreviewImage(path: path, maxHeight: .infinity)
                }
            } else if item.kind == .content {
                // OCR tab status row.
                Text(item.meta ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .folder:
            if let folder, let path = item.target {
                folderList(folder, path: path)
            }
        case .calc where item.payload != nil:
            VStack(alignment: .leading, spacing: 8) {
                Text("= \(item.payload ?? "")")
                    .font(.system(size: 34, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                hint("⏎", "copy result")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .calc:
            if let value = item.calcResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text("= \(SpotlightCalc.format(value))")
                        .font(.system(size: 34, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    hint("⏎", "copy result")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .web where item.target != nil:
            // A search tag's search row: the exact address it opens.
            note(item.target ?? "", key: "⏎", action: "search")
        case .web:
            SpotlightWebInfoView(term: item.name)
        case .tab:
            note(item.tab?.url ?? item.target ?? "", key: "⏎", action: "switch to this tab")
        case .tagHint:
            note(item.meta ?? "", key: "⇥", action: "search \(item.name)")
        case .window:
            note(item.meta ?? "", key: "⏎", action: "switch to this window")
        case .url:
            note(item.target ?? item.name, key: "⏎", action: "open link")
        case .setting:
            note("This item is in System Settings.", key: "⏎", action: "open")
        case .prefix:
            note(item.meta ?? "", key: "⏎", action: "use prefix \(item.payload ?? "")")
        case .command:
            if item.id == "command|emptytrash" {
                note(item.meta ?? "", key: "⏎ ⏎", action: "empty the Trash")
            } else if item.id.hasPrefix(SystemCommands.idPrefix) || item.id.hasPrefix(SystemCommands.runPrefix) {
                note(item.meta ?? "", key: "⏎", action: "run")
            } else {
                note(item.meta ?? "", key: "⏎", action: "enter command")
            }
        case .help:
            Text(item.meta ?? "")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .clip:
            textBox(item.payload ?? item.name)
        case .clipImage:
            // A pane-sized thumbnail, not the original: decoding a copied 4K
            // screenshot at full size is ~33 MB, on every render.
            if let path = item.target {
                QuickLookPreviewImage(path: path, maxHeight: .infinity)
            }
        case .process:
            processContent
        case .app, .cmd, .lookup, .translation:
            EmptyView()
        }
    }

    /// Plain text in a frame (clipboard, a process's command line).
    private func textBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .scrollIndicators(.never)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var processContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let pid = item.pid { infoRow("PID", "\(pid)") }
            if measuringCPU {
                infoRow("CPU", "measuring…")
            } else if let processCPU {
                infoRow("CPU", String(format: "%.1f%%", processCPU))
            } else {
                infoRow("CPU", "not measured")
            }
            if let detail = processDetail {
                infoRow("Memory", ByteCountFormatter.string(fromByteCount: Int64(detail.memoryKB) * 1024, countStyle: .memory))
                infoRow("User", detail.user)
                infoRow("PPID", "\(detail.ppid)")
                if !detail.cmdline.isEmpty {
                    textBox(detail.cmdline)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func note(_ text: String, key: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
            hint(key, action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(action)
                .font(.system(size: 12.5))
        }
        .foregroundStyle(.secondary)
    }

    private func folderList(_ listing: FolderListing, path: String) -> some View {
        Group {
            if listing.items.isEmpty {
                Text("Empty folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Newest first; click opens, drag carries the file to another app.
                        ForEach(Array(listing.items.enumerated()), id: \.offset) { _, entry in
                            FolderEntryRow(
                                entry: entry,
                                path: (path as NSString).appendingPathComponent(entry.name),
                                onOpen: onOpenPath
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
            }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Bottom details

    @ViewBuilder
    private var details: some View {
        let path = item.target.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if path != nil || info.modified != nil || info.version != nil {
            VStack(spacing: 7) {
                if let version = info.version { infoRow("Version", version) }
                if let path { infoRow("Path", PathDisplay.abbreviated(path)) }
                if let modified = info.modified { infoRow("Modified", modified) }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12.5))
    }

    // MARK: - Disk reads

    private static func loadInfo(for item: SpotlightItem) -> Info {
        var info = Info()
        switch item.kind {
        case .setting:
            info.detail = "System Settings"
            return info
        case .clip, .clipImage, .process:
            info.detail = item.meta
            return info
        case .app, .doc, .content, .folder:
            break
        default:
            return info
        }
        guard let path = item.target, path.hasPrefix("/") else { return info }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let date = attrs?[.modificationDate] as? Date {
            info.modified = date.formatted(date: .abbreviated, time: .shortened)
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            info.modifiedAgo = relative.localizedString(for: date, relativeTo: Date())
        }
        info.location = Self.breadcrumb(path)
        switch item.kind {
        case .app:
            let bundle = Bundle(path: path)
            info.version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? bundle?.infoDictionary?["CFBundleVersion"] as? String
            info.detail = info.version.map { "Version \($0)" }
        case .doc, .content:
            if let size = attrs?[.size] as? Int64 {
                info.detail = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                info.size = info.detail
            }
        default:
            break
        }
        return info
    }

    /// "/Users/me/Documents/Photoshop Projects/a.psd" → "Documents › Photoshop Projects › a.psd"
    /// (the last four parts, from the home folder down).
    private static func breadcrumb(_ path: String) -> String {
        let home = NSHomeDirectory()
        let shown = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        var parts = shown.split(separator: "/").map(String.init)
        if parts.count > 4 { parts = ["…"] + parts.suffix(4) }
        return parts.joined(separator: " › ")
    }

    private static func countText(_ listing: FolderListing) -> String? {
        var parts: [String] = []
        if listing.folderCount > 0 { parts.append("\(listing.folderCount) folders") }
        if listing.fileCount > 0 { parts.append("\(listing.fileCount) files") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Syntax-highlighted code

/// Like the legacy launcher's TextFilePreview (reads the first 64 KB off the main thread,
/// highlights, caches by mtime), but paints background/text with system colors.
struct SpotlightCodePreview: View {
    let path: String

    nonisolated private static let displayByteCap = 64 * 1024

    nonisolated private final class Highlighted: @unchecked Sendable {
        let text: NSAttributedString
        let cacheKey: String?
        init(_ text: NSAttributedString, _ cacheKey: String?) {
            self.text = text
            self.cacheKey = cacheKey
        }
    }

    @State private var content = NSAttributedString(string: "")

    var body: some View {
        HighlightedTextView(
            attributed: content,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            defaultColor: .secondaryLabelColor
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: path) {
            let p = path
            if let key = Self.cacheKey(for: p), let cached = HighlightedTextCache.get(key) {
                content = cached
                return
            }
            content = NSAttributedString(string: "")
            // Skimming past quickly doesn't read the file.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Highlighted in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: p), options: [.mappedIfSafe]) else {
                    return Highlighted(NSAttributedString(string: ""), nil)
                }
                let text = String(decoding: data.prefix(Self.displayByteCap), as: UTF8.self)
                return Highlighted(SyntaxHighlighter.highlight(text, path: p), Self.cacheKey(for: p))
            }.value
            guard !Task.isCancelled else { return }
            content = result.text
            if let key = result.cacheKey { HighlightedTextCache.set(key, result.text) }
        }
    }

    nonisolated private static func cacheKey(for path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64
        else { return nil }
        return HighlightedTextCache.key(path: path, mtime: mtime, size: size)
    }
}


/// Web tab: a short Wikipedia summary of the typed term (like Look Up's Siri Knowledge),
/// falling back to the plain "search Google" note when nothing is found.
struct SpotlightWebInfoView: View {
    let term: String

    private struct Summary {
        var title: String
        var subtitle: String?
        var extract: String
        var url: URL?
    }

    private enum Phase { case loading, found(Summary), none }
    @State private var phase: Phase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .loading:
                Text("Looking up “\(term)”…").font(.system(size: 14)).foregroundStyle(.secondary)
            case .found(let s):
                Text(s.title).font(.system(size: 15, weight: .semibold))
                if let sub = s.subtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(s.extract)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                Text("Wikipedia").font(.system(size: 11)).foregroundStyle(.tertiary)
            case .none:
                Text("No summary found. Search Google for “\(term)”.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("⏎").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("open browser").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: term) { await load() }
    }

    private func load() async {
        phase = .loading
        try? await Task.sleep(nanoseconds: 300_000_000)  // debounce typing
        if Task.isCancelled { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let enc = trimmed.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)?redirect=true")
        else { phase = .none; return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Lumio", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if Task.isCancelled { return }
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extract = json["extract"] as? String, !extract.isEmpty,
                  (json["type"] as? String) != "disambiguation"
            else { phase = .none; return }
            phase = .found(Summary(
                title: json["title"] as? String ?? trimmed,
                subtitle: json["description"] as? String,
                extract: extract, url: nil))
        } catch {
            if !Task.isCancelled { phase = .none }
        }
    }
}

/// A row of the quick actions list: icon, label, shortcut. The first is filled like Fluent's.
private struct PreviewActionRow: View {
    let action: PreviewAction
    let primary: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: action.run) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(action.label)
                    .font(.system(size: 13.5, weight: primary ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                primary ? Color(nsColor: .systemBlue).opacity(hovering ? 1 : 0.9)
                    : Color.primary.opacity(hovering ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.shortcut.map { "\(action.label)  \($0)" } ?? action.label)
    }
}

private struct PreviewActionChip: View {
    let action: PreviewAction
    @State private var hovering = false

    var body: some View {
        Button(action: action.run) {
            HStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 11, weight: .medium))
                // An empty short label = icon only (the tooltip names it).
                if action.short != "" {
                    Text(action.short ?? action.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.shortcut.map { "\(action.label)  \($0)" } ?? action.label)
    }
}

/// One line of a folder's listing in the preview: icon, name, how recent, size. Clickable.
private struct FolderEntryRow: View {
    let entry: FolderEntry
    let path: String
    let onOpen: (String, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            onOpen(path, entry.isDir)
        } label: {
            HStack(spacing: 9) {
                Image(nsImage: RowIconCache.icon(forFile: path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
        .help("Open \(entry.name)")
    }

    /// "2d · 285.1 MB" (files) or "2d" (folders).
    private var detail: String {
        var parts: [String] = []
        if let modified = entry.modified { parts.append(Self.ago(modified)) }
        if !entry.isDir, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// Compact age: now, 5m, 3h, 2d, 3w, 5mo, 2y.
    private static func ago(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 60): return "\(Int(seconds / (86_400 * 7)))w"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
        default: return "\(Int(seconds / (86_400 * 365)))y"
        }
    }
}

/// A tag chip on the detail card.
private struct PreviewChipButton: View {
    let chip: PreviewChip
    @State private var hovering = false

    var body: some View {
        Button(action: chip.run) {
            HStack(spacing: 5) {
                if let appPath = chip.appPath {
                    Image(nsImage: RowIconCache.icon(forFile: appPath))
                        .resizable()
                        .frame(width: 14, height: 14)
                } else if let symbol = chip.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .medium))
                }
                Text(chip.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering ? 0.18 : 0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Search in \(chip.label)")
    }
}

/// The eye button: card ↔ preview.
private struct PreviewToggleButton: View {
    let showingPreview: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: showingPreview ? "eye.slash" : "eye")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hovering ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(showingPreview ? "Show details  ⌥P" : "Show preview  ⌥P")
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension SpotlightPreviewView {
    /// Draws the detail card for the file at `path` into a PNG, without a window, so the layout
    /// can be checked from the command line: `Lumio --render-card <file.png> <path>`.
    static func renderSample(path: String, to output: String, preview: Bool = false) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        let isApp = path.hasSuffix(".app")
        let kind: SpotlightKind = isApp ? .app : (isDir.boolValue ? .folder : .doc)
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        let item = SpotlightItem(id: "sample|" + path, name: name, kind: kind, target: path, iconPath: path)
        let ext = (path as NSString).pathExtension.lowercased()
        let parent = FileManager.default.displayName(atPath: (path as NSString).deletingLastPathComponent)
        var chips = [PreviewChip(id: "kind", label: isApp ? "apps" : (isDir.boolValue ? "folder" : "file"), symbol: "doc") {}]
        if !ext.isEmpty, !isApp { chips.append(PreviewChip(id: "ext", label: "." + ext, symbol: "square.on.square") {}) }
        chips.append(PreviewChip(id: "parent", label: parent, symbol: "folder") {})
        if !isApp, !isDir.boolValue, let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) {
            chips.append(PreviewChip(
                id: "app", label: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                appPath: app.path
            ) {})
        }
        let actions = [
            PreviewAction(id: "open", label: "Open", symbol: "arrow.up.forward.app", shortcut: "⏎") {},
            PreviewAction(id: "reveal", label: "Show in \(FileManagerApp.name)", short: "Show", symbol: "folder", shortcut: "⌘F") {},
            PreviewAction(id: "search", label: "Search in Parent Folder", short: "Search", symbol: "magnifyingglass", shortcut: "⌘R") {},
            PreviewAction(id: "terminal", label: "Open in Terminal", short: "Terminal", symbol: "terminal", shortcut: "⌘T") {},
            PreviewAction(id: "openwith", label: "Open With…", symbol: "arrow.up.forward.square") {},
            PreviewAction(id: "copy", label: "Copy Path", short: "", symbol: "doc.on.doc", shortcut: "⌘⇧C") {},
            PreviewAction(id: "pin", label: "Pin to Home", symbol: "pin", shortcut: "⌘⇧P") {},
        ]
        let size = NSSize(width: 360, height: 392)
        let view = NSHostingView(
            rootView: SpotlightPreviewView(item: item, chips: chips, showsPreview: preview, actions: actions)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.2))
                .environment(\.colorScheme, .dark)
        )
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // Let the first layout, the info load and the thumbnail land.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: output))) != nil
    }
}
