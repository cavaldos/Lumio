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
    /// Language codes the translator offers (tr" rows, tw" bar).
    var translationLanguages: [String] = TranslationLanguage.defaultCodes
    /// Order of the tool tabs in the launcher (`tab_order`), SpotlightKind raw values.
    var tabOrder: [String] = TabOrder.defaultCodes

    static let `default` = ThemeSettings()

    init() {}

    // Missing keys keep their defaults, so a blob saved by an older build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSettings()
        fileScanDepth = try c.decodeIfPresent(Int.self, forKey: .fileScanDepth) ?? d.fileScanDepth
        fileScanLimit = try c.decodeIfPresent(Int.self, forKey: .fileScanLimit) ?? d.fileScanLimit
        lazyIndexingEnabled = try c.decodeIfPresent(Bool.self, forKey: .lazyIndexingEnabled) ?? d.lazyIndexingEnabled
        backendLogLevel = try c.decodeIfPresent(BackendLogLevel.self, forKey: .backendLogLevel) ?? d.backendLogLevel
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        translationLanguages = try c.decodeIfPresent([String].self, forKey: .translationLanguages) ?? d.translationLanguages
        tabOrder = TabOrder.normalized(try c.decodeIfPresent([String].self, forKey: .tabOrder) ?? d.tabOrder)
    }
}
