import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es, fr, ja, zh

    var id: String { rawValue }
    var resolvedCode: String {
        let code = self == .system ? Locale.preferredLanguages.first ?? "en" : rawValue
        let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "en"
        return ["en", "es", "fr", "ja", "zh"].contains(primary) ? primary : "en"
    }

    var name: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .ja: return "日本語"
        case .zh: return "中文"
        }
    }
}

enum L10n {
    static let resources = Bundle.module

    static func text(_ key: String, language: AppLanguage) -> String {
        let path = resources.path(forResource: language.resolvedCode, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? resources
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ value: String, language: AppLanguage) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language.resolvedCode), value)
    }
}
