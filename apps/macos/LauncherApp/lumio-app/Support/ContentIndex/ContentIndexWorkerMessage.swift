import Foundation

/// What the OCR worker (`Lumio --content-index-worker`) tells the app, one JSON object per
/// stdout line. JSON so a path with a newline in it can't split a message in two.
/// Pure logic, so it is unit tested (LauncherLogicTests).
nonisolated enum ContentIndexWorkerMessage: Equatable, Sendable {
    /// Files still to read in this pass.
    case pending(Int)
    /// About to read this file. If the worker dies before the next message, this file
    /// is the one that killed it.
    case reading(String)

    /// The command-line flag that turns the app binary into the worker.
    static let flag = "--content-index-worker"

    private struct Wire: Codable {
        var pending: Int?
        var file: String?
    }

    /// One line, newline included.
    var line: String {
        let wire: Wire
        switch self {
        case .pending(let count): wire = Wire(pending: count)
        case .reading(let path): wire = Wire(file: path)
        }
        let data = (try? JSONEncoder().encode(wire)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// nil for anything that isn't a message (blank lines, stray output from a framework).
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
            let wire = try? JSONDecoder().decode(Wire.self, from: Data(trimmed.utf8))
        else { return nil }
        if let count = wire.pending {
            self = .pending(max(0, count))
        } else if let path = wire.file, !path.isEmpty {
            self = .reading(path)
        } else {
            return nil
        }
    }
}
