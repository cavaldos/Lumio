import Darwin
import Foundation

/// The OCR worker: the app binary started as `Lumio --content-index-worker`.
///
/// OCR (Vision) and PDF reading run here, in their own short-lived process, never inside the
/// launcher: a pass can take hundreds of MB, and memory that size is not handed back to the
/// OS once it is freed. The worker reads new / changed files, writes their text to
/// `content-index.db` (the launcher reads the same file) and exits. It is started only when
/// the OCR tab is opened (`ContentIndexer.refresh`).
nonisolated enum ContentIndexWorker {
    /// Called first thing at launch. Returns at once for a normal launch; in worker mode it
    /// runs the pass and exits the process, so SwiftUI never starts.
    @MainActor
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains(ContentIndexWorkerMessage.flag) else { return }
        exitWithParent()
        let config = ContentIndexConfig.load()
        guard let store = ContentIndexStore(path: ContentIndexStore.defaultPath) else { exit(1) }
        Task.detached(priority: .utility) {
            let completed = await ContentIndexer.pass(store: store, config: config) { message in
                FileHandle.standardOutput.write(Data(message.line.utf8))
            }
            exit(completed ? 0 : 1)
        }
        // Keeps the main queue serving while the pass runs; the task above ends the process.
        dispatchMain()
    }

    /// The app holds the other end of our stdin. When it closes (the app quit, crashed or
    /// called `stopWorker`), stop: a worker must never outlive the launcher.
    private static func exitWithParent() {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO else { return }
        Thread.detachNewThread {
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) > 0 {}
            exit(0)
        }
    }
}
