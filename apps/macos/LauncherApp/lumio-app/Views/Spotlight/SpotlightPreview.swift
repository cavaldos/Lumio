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

struct SpotlightPreviewView: View {
    let item: SpotlightItem
    /// ps" / :kill — process details (loaded on selection) and CPU (measured on Enter).
    var processDetail: ProcessDetail? = nil
    var processCPU: Double? = nil
    var measuringCPU = false
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

    private var standard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            details
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor, in: Capsule())
                    if let detail = info.detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var badgeColor: Color {
        switch item.kind {
        case .app: .accentColor
        case .doc, .content: .green
        case .folder: .orange
        case .url, .web: .blue
        default: .gray
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
        case .web:
            note("Search Google for “\(item.name)”.", key: "⏎", action: "open browser")
        case .url:
            note(item.target ?? item.name, key: "⏎", action: "open link")
        case .setting:
            note("This item is in System Settings.", key: "⏎", action: "open")
        case .prefix:
            note(item.meta ?? "", key: "⏎", action: "use prefix \(item.payload ?? "")")
        case .command:
            if item.id == "command|emptytrash" {
                note(item.meta ?? "", key: "⏎ ⏎", action: "empty the Trash")
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
                        ForEach(Array(listing.items.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 9) {
                                Image(nsImage: RowIconCache.icon(forFile: (path as NSString).appendingPathComponent(entry.name)))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(entry.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if !entry.isDir, let size = entry.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 26)
                        }
                    }
                    .padding(.horizontal, 12)
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
        }
        switch item.kind {
        case .app:
            let bundle = Bundle(path: path)
            info.version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? bundle?.infoDictionary?["CFBundleVersion"] as? String
            info.detail = info.version.map { "Version \($0)" }
        case .doc, .content:
            if let size = attrs?[.size] as? Int64 {
                info.detail = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        default:
            break
        }
        return info
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
