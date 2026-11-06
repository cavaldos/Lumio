//
//  SpotlightClipPreview.swift
//  lumio-app
//
//  Clipboard tab's side preview, opened by resting on a row for a few seconds: the full
//  text (or the image), then a few small lines about the clip, like Maccy.
//

import AppKit
import SwiftUI

/// The small lines under the clip's content.
struct ClipboardClipDetails: Equatable {
    let appBundleID: String?
    let firstCopiedAt: Date
    let lastCopiedAt: Date
    let copyCount: Int
    /// Images only: "1920×1080 · 2.1 MB".
    var imageSize: String? = nil
}

struct SpotlightClipPreview: View {
    let item: SpotlightItem
    let details: ClipboardClipDetails?

    /// SwiftUI lays out the whole string: keep a 30 000-character clip from stalling the pane.
    private static let maxShownCharacters = 8_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let details {
                detailLines(details)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .clipImage, let path = item.target {
            QuickLookPreviewImage(path: path, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(shownText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .scrollIndicators(.never)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var shownText: String {
        let text = item.payload ?? item.name
        guard text.count > Self.maxShownCharacters else { return text }
        return String(text.prefix(Self.maxShownCharacters)) + "…"
    }

    private func detailLines(_ details: ClipboardClipDetails) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Application:")
                if let app = Self.app(details.appBundleID) {
                    Image(nsImage: RowIconCache.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(app.name)
                } else {
                    Text("Unknown")
                }
            }
            Text("First copy time: \(Self.format(details.firstCopiedAt))")
            Text("Last copy time: \(Self.format(details.lastCopiedAt))")
            Text("Number of copies: \(details.copyCount)")
            if let size = details.imageSize {
                Text("Size: \(size)")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().hour().minute())
    }

    /// Name and bundle path of the app a clip came from. Cached: LaunchServices is asked once per app.
    private static var appCache: [String: (name: String, path: String)?] = [:]

    private static func app(_ bundleID: String?) -> (name: String, path: String)? {
        guard let bundleID else { return nil }
        if let cached = appCache[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            (name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
             path: url.path)
        }
        appCache[bundleID] = resolved
        return resolved
    }
}
