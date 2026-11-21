//
//  AccessibilityAccess.swift
//  lumio-app
//
//  Whether the Accessibility permission really works, not just whether macOS says "allowed".
//
//  Three answers:
//    working  macOS allows it and a real request goes through.
//    off      Lumio is not in the list, or its switch is off.
//    stale    the switch for Lumio is ON in System Settings, yet macOS ignores it. This is
//             what happens after Lumio is replaced by a newer build: the entry belongs to
//             the old copy. Flipping the switch does not help; the entry has to be removed
//             and added again.
//
//  How stale is told apart from off: macOS keeps the switches in a database that an app
//  with Full Disk Access may read. If Lumio's row says "allowed" while macOS refuses, it is
//  stale for certain. Without Full Disk Access the row cannot be read, so Lumio falls back
//  on remembering that the permission worked before.
//

import AppKit
import ApplicationServices
import SQLite3
import Security

nonisolated enum AccessibilityAccess {
    enum State: Equatable, Sendable {
        case working
        /// `listed`: Lumio is in the list with its switch off (false = not in the list, or unknown).
        case off(listed: Bool)
        case stale(Stale)
    }

    enum Stale: Equatable, Sendable {
        /// The switch is on in System Settings, macOS says no.
        case switchOnButIgnored
        /// It worked before and stopped; the list could not be read to say why.
        case workedBefore
        /// macOS says yes but refuses the requests themselves. Reopening Lumio fixes it.
        case allowedButRefused
    }

    /// What macOS has written down for Lumio.
    enum Record: Equatable, Sendable {
        case allowed, denied, missing
        /// No Full Disk Access (or a macOS that keeps it elsewhere).
        case unreadable
    }

    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let workedKey = "AccessibilityAccess.workedBefore"

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.cavaldos.Lumio" }

    /// The quick question, safe to ask often. Never prompts.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The full check. Takes a few milliseconds; call it off the main thread when you can.
    static func check() -> State {
        let trusted = AXIsProcessTrusted()
        if trusted {
            guard requestsGoThrough() else { return .stale(.allowedButRefused) }
            UserDefaults.standard.set(true, forKey: workedKey)
            return .working
        }
        switch record() {
        case .allowed:
            return .stale(.switchOnButIgnored)
        case .denied:
            // Switched off on purpose: nothing stale about that, and no reason to warn later.
            UserDefaults.standard.set(false, forKey: workedKey)
            return .off(listed: true)
        case .missing:
            UserDefaults.standard.set(false, forKey: workedKey)
            return .off(listed: false)
        case .unreadable:
            return UserDefaults.standard.bool(forKey: workedKey) ? .stale(.workedBefore) : .off(listed: false)
        }
    }

    /// Whether the permission worked the last time it was checked.
    static var workedBefore: Bool { UserDefaults.standard.bool(forKey: workedKey) }

    /// One line for the self-check report and Settings.
    static func summary(_ state: State) -> String {
        switch state {
        case .working: "working"
        case .off(listed: true): "off (Lumio is in the list, its switch is off)"
        case .off(listed: false): "off (Lumio is not in the list)"
        case .stale(.switchOnButIgnored): "STALE (the switch is on, macOS ignores it)"
        case .stale(.workedBefore): "probably STALE (worked before, stopped)"
        case .stale(.allowedButRefused): "STALE (allowed, but requests are refused until Lumio is reopened)"
        }
    }

    // MARK: - A real request

    /// Asks an app that is always running for one harmless fact. Only a plain "accessibility
    /// is disabled" answer counts as a refusal; a busy app proves nothing either way.
    private static func requestsGoThrough() -> Bool {
        for bundle in ["com.apple.dock", "com.apple.finder", "com.apple.systemuiserver"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) {
            case .success: return true
            case .apiDisabled: return false
            default: continue
            }
        }
        return true
    }

    // MARK: - What macOS wrote down

    static func record() -> Record {
        // Accessibility is a system-wide permission; older systems kept a per-user copy.
        let paths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        var readAny = false
        for path in paths {
            guard let found = record(in: path) else { continue }
            readAny = true
            if found != .missing { return found }
        }
        return readAny ? .missing : .unreadable
    }

    /// nil = this database could not be read.
    static func record(in path: String) -> Record? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return nil }
        sqlite3_busy_timeout(handle, 300)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT auth_value FROM access WHERE service = 'kTCCServiceAccessibility' AND client = ?1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, bundleID, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            // 0 = denied, 2 = allowed (3 = limited, which Accessibility does not use).
            return sqlite3_column_int(statement, 0) >= 2 ? .allowed : .denied
        case SQLITE_DONE:
            return .missing
        default:
            return nil
        }
    }

    /// For the self-check report: when macOS wrote the entry down, which signature it was
    /// written for, and whether this copy of Lumio still fits it.
    static func recordDetail() -> String {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return "list not readable"
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT auth_value, last_modified, csreq FROM access "
            + "WHERE service = 'kTCCServiceAccessibility' AND client = ?1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return "list has another shape" }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, bundleID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return "no entry" }
        let value = sqlite3_column_int(statement, 0)
        let when = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
        var fits = "no signature recorded"
        if let bytes = sqlite3_column_blob(statement, 2) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            var requirement: SecRequirement?
            var code: SecCode?
            if SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess, let requirement,
               SecCodeCopySelf([], &code) == errSecSuccess, let code
            {
                var text: CFString?
                SecRequirementCopyString(requirement, [], &text)
                let matches = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
                fits = "written for [\(text as String? ?? "?")], this copy \(matches ? "FITS" : "does NOT fit")"
            }
        }
        return "value \(value), last changed \(when.formatted(date: .abbreviated, time: .shortened)), \(fits)"
    }

    // MARK: - Fixing it

    /// Removes Lumio's entry from the Accessibility list (only Lumio's, only Accessibility),
    /// which is what clears a stale one. False when macOS would not do it.
    static func removeEntry() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        UserDefaults.standard.set(false, forKey: workedKey)
        return process.terminationStatus == 0
    }

    /// Makes macOS list Lumio again (switch off) and show its own "open System Settings" prompt.
    static func askMacOSToListLumio() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
