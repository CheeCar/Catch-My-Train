import Foundation

/// UI language. English by default.
/// Option names are shown in each language's own spelling (e.g. Spanish is listed under its Spanish name), so people who don't read the current language can still find theirs.
/// The cases are in the language menu's order, the alphabetical order of their English names, the same as README.md's language
/// table (a fixed order of its own would read like a ranking); a test keeps the two the same
public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case arabic = "ar"
    case bengali = "bn"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case english = "en"
    case french = "fr"
    case german = "de"
    case gujarati = "gu"
    case haitianCreole = "ht"
    case hebrew = "he"
    case hindi = "hi"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case polish = "pl"
    case portuguese = "pt"
    case russian = "ru"
    case spanish = "es"
    case tagalog = "tl"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"
    case yiddish = "yi"

    public static let `default`: AppLanguage = .english

    /// Show the language menu in Settings (false hides it and keeps the UI in English). A saved code that isn't one of these cases
    /// (a language earlier versions offered, such as Indonesian or Turkish) reads as unrecognized and falls back to English (see SharedStore.language).
    public static let otherLanguagesEnabled = true

    public var id: String { rawValue }

    /// The first of the Mac's preferred languages that the app has, e.g. "zh-Hans-US" → Simplified Chinese, "zh-HK" → Traditional Chinese,
    /// "zh-Hans-HK" → Simplified Chinese (the script counts before the region), "pt-PT" → Portuguese, "es-ES" or "es-419" → Spanish,
    /// "fil-PH" → Tagalog; nil when none of them is available (a new install then starts in English).
    /// Only the language part counts, so every regional variant (Spain or Mexico Spanish, Portugal or Angola Portuguese,
    /// British or Indian English, Canadian French) gets that language's one translation.
    public static func matching(preferred: [String]) -> AppLanguage? {
        for code in preferred {
            let parts = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.lowercased() }
            guard let base = parts.first else { continue }
            if base == "zh" {
                let rest = parts.dropFirst()
                // The script decides when there is one ("zh-Hans-HK" is Simplified Chinese used in Hong Kong); only a code without one goes by region
                if rest.contains("hans") { return .chineseSimplified }
                if rest.contains("hant") { return .chineseTraditional }
                return rest.contains { ["tw", "hk", "mo"].contains($0) } ? .chineseTraditional : .chineseSimplified
            }
            // macOS lists Filipino, the standard form of Tagalog, as "fil"
            if base == "fil" { return .tagalog }
            if let language = AppLanguage(rawValue: base) { return language }
        }
        return nil
    }

    /// The language "System Language" in Settings uses: the first of the Mac's preferred languages that the app has, else English.
    public static func macLanguage(preferred: [String]) -> AppLanguage {
        matching(preferred: preferred) ?? .default
    }

    /// The language to open in, and whether it follows the Mac ("System Language" in Settings), worked out at each launch.
    /// `saved` is the language saved last time (nil when none is), `followsMac` whether "System Language" was chosen,
    /// `preferred` the Mac's preferred languages, most preferred first. Following the Mac picks its language again at every launch,
    /// so a change of the Mac's language shows from the next launch. With no language saved yet, a new install follows the Mac,
    /// and a Mac updating from a version without the language menu keeps English, which it showed before.
    public static func atLaunch(saved: AppLanguage?, followsMac: Bool, isNewInstall: Bool,
                                preferred: [String]) -> (language: AppLanguage, followsMac: Bool) {
        if followsMac || (saved == nil && isNewInstall) { return (macLanguage(preferred: preferred), true) }
        return (saved ?? .default, false)
    }

    /// Name shown in the dropdown menu, in the language's own spelling (read from Resources/language_names.json).
    public var nativeName: String { Translations.languageName(self) }

    /// Locale used for time and number formats.
    public var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .spanish: return Locale(identifier: "es_419")
        case .french: return Locale(identifier: "fr_FR")
        case .german: return Locale(identifier: "de_DE")
        case .portuguese: return Locale(identifier: "pt_BR")
        case .russian: return Locale(identifier: "ru_RU")
        case .chineseSimplified: return Locale(identifier: "zh_Hans_CN")
        case .chineseTraditional: return Locale(identifier: "zh_Hant_TW")
        case .japanese: return Locale(identifier: "ja_JP")
        case .korean: return Locale(identifier: "ko_KR")
        case .ukrainian: return Locale(identifier: "uk_UA")
        case .arabic: return Locale(identifier: "ar@numbers=latn")
        case .hebrew: return Locale(identifier: "he_IL")
        case .hindi: return Locale(identifier: "hi_IN@numbers=latn")
        case .urdu: return Locale(identifier: "ur_PK@numbers=latn")
        case .italian: return Locale(identifier: "it_IT")
        case .polish: return Locale(identifier: "pl_PL")
        case .vietnamese: return Locale(identifier: "vi_VN")
        case .bengali: return Locale(identifier: "bn_BD@numbers=latn")
        // macOS has a Haitian Creole locale but no date data for it: dates come out as "2026 M10 27" with English weekdays
        // (Linux falls back to French). Its clock times and numbers are fine, so the locale stays; AppText writes dates with
        // the Haitian Creole month and weekday names in Resources/date_names.json (kept out of the Swift source like the
        // translations), and the date picker uses datePickerLocale.
        case .haitianCreole: return Locale(identifier: "ht_HT")
        case .yiddish: return Locale(identifier: "yi")
        case .gujarati: return Locale(identifier: "gu_IN@numbers=latn")
        // Filipino has the full date and number data; Tagalog is the same language
        case .tagalog: return Locale(identifier: "fil_PH")
        }
    }

    /// Locale for the system date picker (Plan a Trip), which draws its own month and weekday names.
    /// A language with bundled date names (Haitian Creole) uses a related locale that has real date data,
    /// French (Haiti), so its calendar shows real month names; the app's own text is unchanged.
    public var datePickerLocale: Locale {
        guard let identifier = Translations.dateNames(self)?.pickerLocale else { return locale }
        return Locale(identifier: identifier)
    }

    /// Arabic, Hebrew, Urdu and Yiddish are laid out right-to-left. Numbers and times still use 0–9 (matching route numbers and station signs).
    public var isRightToLeft: Bool {
        self == .arabic || self == .hebrew || self == .urdu || self == .yiddish
    }

    /// Simplified or Traditional Chinese
    public var isChinese: Bool {
        self == .chineseSimplified || self == .chineseTraditional
    }
}
