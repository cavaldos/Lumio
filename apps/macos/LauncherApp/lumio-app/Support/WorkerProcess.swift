import Foundation

/// Runs this app's own binary as a short-lived helper (`Lumio --some-worker …`) and returns
/// what it printed. Heavy one-off work (decoding a copied screenshot, OCR) runs there, so the
/// launcher never holds its memory: the helper's pages go back to the OS when it exits, while
/// memory freed inside a long-lived process mostly stays mapped.
nonisolated enum WorkerProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    /// nil when the helper could not be started. Meant for helpers that print a little
    /// (one JSON line): stdout is read after the exit, so it must fit in the pipe buffer.
    static func run(_ arguments: [String]) async -> Output? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: data))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}
