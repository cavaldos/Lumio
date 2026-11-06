import Darwin
import Foundation

/// Drops everything Lumio only keeps to be fast while the launcher is on screen: preview
/// bitmaps, highlighted text, dictionary HTML, row icons, SQLite page cache. Then hands the
/// freed pages back to the OS, so an idle Lumio stays small. Everything here is rebuilt on
/// demand in a few ms.
enum MemoryTrim {
    /// Called when the launcher hides, and when macOS reports memory pressure.
    static func releaseCaches() async {
        HighlightedTextCache.purge()
        SpotlightLookupCache.purgeEntries()
        RowIconCache.purge()
        ContentIndex.shared.releaseMemory()
        await QuickLookPreviewService.shared.purge()
        malloc_zone_pressure_relief(nil, 0)
    }

    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    /// Trims as soon as macOS says memory is short, instead of waiting for the launcher to hide.
    static func watchMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task { @MainActor in await releaseCaches() }
        }
        source.resume()
        pressureSource = source
    }
}
