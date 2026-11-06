import AppKit
import Foundation

/// What the clipboard image helper reports: the stored image, or nothing (no image, too big,
/// or the clipboard changed before it looked). One JSON line on stdout.
nonisolated struct ClipboardImageWorkerResult: Codable, Equatable, Sendable {
    let hash: String
    let width: Double
    let height: Double
    let byteSize: Int
    /// Set when the image was copied as a file (Finder): the better label.
    let fileName: String?

    var stored: StoredClipboardImage {
        StoredClipboardImage(hash: hash, pixelSize: CGSize(width: width, height: height), byteSize: byteSize)
    }
}

/// `Lumio --clipboard-image-worker <changeCount> <images directory>`: reads the image on the
/// clipboard, writes it as PNG plus a thumbnail, prints a `ClipboardImageWorkerResult` and exits.
///
/// A copied screenshot arrives as raw TIFF (~33 MB at 4K) and is decoded and re-encoded to be
/// stored: done inside the launcher, that took it from ~60 MB to ~140 MB for every image
/// copied, even while hidden. Here it costs the launcher nothing.
nonisolated enum ClipboardImageWorker {
    static let flag = "--clipboard-image-worker"

    /// Called first thing at launch: returns at once unless this process is the helper.
    @MainActor
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == flag else { return }
        guard arguments.count == 3, let changeCount = Int(arguments[1]) else { exit(2) }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)

        let pasteboard = NSPasteboard.general
        // Something else was copied since the launcher looked: that copy gets its own helper.
        guard pasteboard.changeCount == changeCount else { exit(3) }
        guard
            let candidate = ClipboardImagePasteboard.candidate(from: pasteboard, types: pasteboard.types ?? []),
            candidate.data.count <= AppConstants.Launcher.ClipboardImage.maxImageBytes,
            let stored = ClipboardImageFiles.store(candidate.data, in: directory)
        else { exit(1) }

        let result = ClipboardImageWorkerResult(
            hash: stored.hash, width: stored.pixelSize.width, height: stored.pixelSize.height,
            byteSize: stored.byteSize, fileName: candidate.fileName)
        guard let line = try? JSONEncoder().encode(result) else { exit(1) }
        FileHandle.standardOutput.write(line)
        exit(0)
    }

    /// Runs the helper for the copy numbered `changeCount`. Call off the main thread's hot path;
    /// it awaits a process.
    static func capture(changeCount: Int) async -> ClipboardImageWorkerResult? {
        guard let directory = ClipboardImageFiles.directoryURL,
            let output = await WorkerProcess.run([flag, String(changeCount), directory.path]),
            output.status == 0
        else { return nil }
        return try? JSONDecoder().decode(ClipboardImageWorkerResult.self, from: output.stdout)
    }
}
