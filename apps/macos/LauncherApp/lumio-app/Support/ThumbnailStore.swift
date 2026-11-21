//
//  ThumbnailStore.swift
//  lumio-app
//
//  Picture thumbnails for result rows: an image, video or PSD shows what it looks like
//  instead of a generic file icon, like Finder and Fluent Search.
//
//  Made by Quick Look (the system's own thumbnailer, the one Finder uses), off the main
//  thread, and cached. A row draws its normal icon first and swaps to the thumbnail when it
//  lands, so the list never waits.
//

import AppKit
import Combine
import QuickLookThumbnailing

final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    /// Files worth a picture. Anything else keeps its type icon (a thumbnail of a zip is its icon).
    private static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "ico",
        "psd", "psb", "psdt", "ai", "eps", "raw", "cr2", "cr3", "nef", "arw", "dng",
        "mp4", "mov", "m4v", "mkv", "avi", "webm",
        "sketch", "fig",
    ]
    // Not PDFs or office documents: a page shrunk to 30 points is a grey smudge, and the
    // type icon (PDF, Pages…) says more.

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240
        return cache
    }()
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private var publishScheduled = false

    static func wants(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The thumbnail for `path`, nil while it is being made (or when the file has none).
    func image(for path: String) -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        guard !loading.contains(path), !failed.contains(path) else { return nil }
        loading.insert(path)
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: 96, height: 96),
            scale: 2, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            // An all-transparent picture (an empty canvas, a file Quick Look can't render) would
            // leave a hole in the row: keep the file's normal icon for those.
            let image = representation.flatMap { Self.hasContent($0.cgImage) ? $0.nsImage : nil }
            Task { @MainActor in
                self.loading.remove(path)
                if let image {
                    self.cache.setObject(image, forKey: path as NSString)
                    self.publishSoon()
                } else {
                    self.failed.insert(path)
                }
            }
        }
        return nil
    }

    /// Whether a meaningful part of the picture is not transparent (sampled at 12×12).
    nonisolated static func hasContent(_ image: CGImage) -> Bool {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 24 }.count
        return visible >= 8
    }

    /// Several thumbnails usually land together: one redraw for the batch.
    private func publishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.publishScheduled = false
            self.objectWillChange.send()
        }
    }
}
