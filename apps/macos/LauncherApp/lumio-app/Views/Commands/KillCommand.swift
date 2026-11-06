import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KillCommand {
    /// Row cap for the fuzzy query path (mirrors linows `KILL_RESULT_LIMIT`).
    private static let resultLimit = 60

    struct Candidate: Identifiable {
        let id: String
        let displayName: String
        let pid: Int32
        let icon: NSImage?
        let number: Int
        let detail: String
    }

    private static func getRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private static func appCandidates(from apps: [NSRunningApplication]) -> [Candidate] {
        apps.enumerated().map { index, app in
            Candidate(
                id: "app-\(app.processIdentifier)-\(index)",
                displayName: app.localizedName ?? "Unknown",
                pid: app.processIdentifier,
                icon: app.icon,
                number: index + 1,
                detail: "PID: \(app.processIdentifier)"
            )
        }
    }

    /// Strips the optional `:` / `port ` port-search affordance so `:3000` and
    /// `3000` resolve identically through the one numeric path (exact port >
    /// partial > PID) rather than a separate lsof lookup.
    private static func normalize(_ searchTerm: String) -> String {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":") {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.lowercased().hasPrefix("port ") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// `processes` is the cached `ProcessFinderModel` snapshot: this runs in a
    /// SwiftUI body, so it must never walk the process table itself.
    static func suggestions(searchTerm: String, processes: [ProcessScoring.Candidate]) -> [Candidate] {
        let term = normalize(searchTerm)
        let apps = getRunningApps()
        // Empty query lists apps only (the panel's default view).
        if term.isEmpty {
            return appCandidates(from: apps)
        }

        // Non-empty query: fuzzy over apps + processes, apps first, deduped by
        // PID (ProcessScoring mirrors the Rust `rank_kill_targets`; the fuzzy
        // score is the same `core/matching` scorer over FFI).
        let appPairs = apps.map { (name: $0.localizedName ?? "Unknown", pid: $0.processIdentifier) }
        let lowered = term.lowercased()
        let ranked = ProcessScoring.rankKillTargets(
            apps: appPairs, procs: processes, query: term
        ) { title in
            EngineBridge.shared.fuzzyScore(query: lowered, title: title)
        }

        return ranked.prefix(resultLimit).enumerated().map { index, target in
            Candidate(
                id: "\(target.isApp ? "app" : "proc")-\(target.pid)-\(index)",
                displayName: target.name,
                pid: target.pid,
                icon: LauncherProcessFeature.icon(forPID: target.pid),
                number: index + 1,
                detail: "PID: \(target.pid)"
            )
        }
    }

    /// SIGKILL a process, routed through the native `ProcessService.kill`.
    static func kill(pid: Int32, name: String, completion: @escaping (String) -> Void) {
        switch ProcessService.kill(pid: pid) {
        case .success:
            completion("Killed: \(name) (PID: \(pid))")
        case .failure(let error):
            completion("Failed to kill \(name): \(error.message)")
        }
    }
}
