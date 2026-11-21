import AppKit
import Foundation

/// Cache for result-row icons, keyed by the path they were resolved from.
///
/// `NSWorkspace.icon(forFile:)` returns a fresh `NSImage` every call, and rows
/// resolve their icon inside `body`. Uncached, any list redraw hands SwiftUI a
/// new instance per visible row, which it redraws: every icon flickers on each
/// keypress.
nonisolated enum RowIconCache {
    // NSCache is documented thread-safe; nonisolated(unsafe) satisfies Swift 6
    // strict-concurrency without an actor wrapper, as in `HighlightedTextCache`.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // A few screenfuls, so scrolling does not evict icons about to return. File icons
        // are cached as one small bitmap each (see `rasterized`), not as the NSWorkspace
        // image carrying every size and appearance of the icon.
        c.countLimit = 128
        return c
    }()

    /// The largest a cached file icon is ever shown, in points (rows draw 30, the folder
    /// list 18, the clip details 14). Callers that need a bigger icon (the preview header)
    /// ask NSWorkspace directly instead of this cache.
    static let iconPoints: CGFloat = 32

    /// Pixels per point of the cached bitmap: Retina.
    private static let iconScale: CGFloat = 2

    static func icon(forFile path: String) -> NSImage {
        image(key: path) {
            rasterized(NSWorkspace.shared.icon(forFile: path), points: iconPoints)
        }
    }

    /// `image` redrawn into a single `points` x `points` (@2x) bitmap, aspect preserved.
    /// Returns `image` itself when it cannot be drawn (the caller still gets a picture).
    /// Template images (SF Symbols) are returned as they are: a bitmap would lose their tint.
    static func rasterized(_ image: NSImage, points: CGFloat) -> NSImage {
        let source = image.size
        guard !image.isTemplate, source.width > 0, source.height > 0, points > 0 else { return image }
        let pixels = Int((points * iconScale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        // Before the context exists: the context takes its point-to-pixel scale from the
        // rep's size when it is created.
        rep.size = NSSize(width: points, height: points)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        let fit = min(points / source.width, points / source.height)
        let drawn = NSSize(width: source.width * fit, height: source.height * fit)
        let rect = NSRect(
            x: (points - drawn.width) / 2, y: (points - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: points, height: points))
        result.addRepresentation(rep)
        return result
    }

    /// The picture itself, for a row that IS one. Small on disk already, so the
    /// list never decodes the full-size original.
    static func thumbnail(forFile path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// Drops every icon. Called by `MemoryTrim` once the launcher has stayed hidden a while
    /// (and on memory pressure): the cache only exists to stop icons flickering while rows
    /// redraw, and NSWorkspace answers from its own cache in microseconds afterwards.
    static func purge() {
        cache.removeAllObjects()
    }

    /// For rows with no path of their own (synthetic rows, system symbols).
    static func image(key: String, resolve: () -> NSImage) -> NSImage {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let resolved = resolve()
        cache.setObject(resolved, forKey: key as NSString)
        return resolved
    }
}
