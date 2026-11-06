import Foundation

enum BackendLogLevel: String, CaseIterable, Codable, Identifiable {
    case error
    case info
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error: return "Error"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }
}

/// Settings edited in the Settings window and saved to the config file.
struct ThemeSettings: Codable, Equatable {
    var fileScanDepth: Int = 4
    var fileScanLimit: Int = 4000
    var lazyIndexingEnabled: Bool = true
    var backendLogLevel: BackendLogLevel = .error
    var launchAtLogin: Bool = true

    static let `default` = ThemeSettings()
}
