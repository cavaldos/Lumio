//
//  SpotlightQuickLook.swift
//  lumio-app
//
//  The side preview's expand button opens the system Quick Look panel, the same one
//  Finder shows on Space: documents, images, PDFs, text clips (written to a temp .txt).
//  The launcher window is the panel's controller (see LauncherPanelWindow).
//

import AppKit
import Quartz
import SwiftUI

final class SpotlightQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SpotlightQuickLook()

    /// Only touched on the main thread (Quick Look calls its data source there).
    nonisolated(unsafe) private var url: URL?
    /// What the panel zooms out of and back into (the side preview), and the picture it
    /// zooms with. Main thread only, like `url`.
    nonisolated(unsafe) fileprivate weak var sourceView: NSView?
    nonisolated(unsafe) private var transitionImage: NSImage?

    /// Loads a text clip's full text by its row id in the launcher's history. Set by the
    /// launcher: clip rows hold a title, and the text lives in the database.
    static var clipText: ((UUID) async -> String?)?

    /// Bumped by every request, so a slow clip load cannot land after a newer selection.
    private static var request = 0

    /// Opens Quick Look on `item`, or swaps what it shows if it is already open.
    static func show(item: SpotlightItem) {
        request += 1
        let current = request
        Task { @MainActor in
            guard let url = await previewURL(for: item), current == request else {
                if current == request { NSSound.beep() }
                return
            }
            shared.url = url
            shared.transitionImage = transitionImage(for: item, url: url)
            guard let panel = QLPreviewPanel.shared() else { return }
            if panel.isVisible {
                panel.reloadData()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            // The launcher sits at .floating: keep Quick Look above it.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        }
    }

    /// Settings ▸ Shortcuts ▸ Quick Look (⌘Y by default); nil = turned off.
    static var shortcut: KeyCombo? { ThemeStore.shared.settings.hotKey(for: .quickLook) }

    static func matchesShortcut(_ event: NSEvent) -> Bool {
        shortcut?.matches(keyCode: event.keyCode, flags: event.modifierFlags) == true
    }

    static var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    static func close() {
        // A clip still loading must not reopen the panel that was just closed.
        request += 1
        guard isVisible else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// ⌘Y: open on `item`, or close if already open.
    static func toggle(item: SpotlightItem) {
        if isVisible { close() } else { show(item: item) }
    }

    /// While open, follows the launcher's selection (↑ / ↓ inside the panel).
    static func follow(item: SpotlightItem) {
        guard isVisible else { return }
        request += 1
        let current = request
        Task { @MainActor in
            guard let url = await previewURL(for: item), current == request, isVisible else { return }
            shared.url = url
            shared.transitionImage = transitionImage(for: item, url: url)
            QLPreviewPanel.shared()?.reloadData()
        }
    }

    /// A file Quick Look can open: the document itself, the stored image, or the text in a temp file.
    private static func previewURL(for item: SpotlightItem) async -> URL? {
        switch item.kind {
        case .doc, .content, .clipImage:
            guard let path = item.target, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        case .clip:
            guard let id = item.clipID, let text = await clipText?(id) else { return nil }
            return writeTextClip(text)
        default:
            return nil
        }
    }

    /// The thumbnail for images, the file icon for documents, nothing for text (plain zoom).
    private static func transitionImage(for item: SpotlightItem, url: URL) -> NSImage? {
        switch item.kind {
        case .clipImage:
            return item.iconPath.flatMap { RowIconCache.thumbnail(forFile: $0) }
        case .doc, .content:
            return NSWorkspace.shared.icon(forFile: url.path)
        default:
            return nil
        }
    }

    /// A fresh folder each time: Quick Look caches by URL, so reusing one path shows stale text.
    private static func writeTextClip(_ text: String) -> URL? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LumioQuickLook", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("Clipboard.txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }

    // MARK: - QLPreviewPanelDelegate (zoom animation)

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let view = sourceView, let window = view.window, window.isVisible else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        transitionImage
    }
}

/// Marks the side preview as the place Quick Look zooms from and back into.
struct QuickLookSourceAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        SpotlightQuickLook.shared.sourceView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        SpotlightQuickLook.shared.sourceView = view
    }
}

/// The small expand button on the side preview's top-right corner.
struct PreviewExpandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SpotlightQuickLook.shortcut.map { "Quick Look (\($0.display))" } ?? "Quick Look")
    }
}
