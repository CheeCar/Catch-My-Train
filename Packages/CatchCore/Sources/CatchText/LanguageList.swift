import Foundation

/// One row of the language list in Settings
public struct LanguageRow: Equatable, Identifiable, Sendable {
    public var language: AppLanguage
    /// The language's own name, which the row shows first
    public var nativeName: String
    /// Its name in the language the app is shown in, shown after it. Nil for that language itself and when the two names are
    /// the same
    public var secondName: String?
    /// Its name in the app's language: what the list is ordered by
    public var sortName: String
    /// Everything a search looks in (LanguageList.search), folded: both names, the English name, the code, other names it goes by
    public var searchWords: [String]

    public var id: String { language.rawValue }
}

/// A row as the list of languages shows it. A language the Mac suggests is in the list twice, under "Suggested" and under
/// "All languages", and in one lazy list a second row with the same id is drawn blank: so a row's id is its part and its
/// language, and no two rows of the list have the same
public struct LanguageListItem: Equatable, Identifiable, Sendable {
    /// The part of the list a row is in
    public enum Part: String, Sendable {
        case suggested
        case all
    }

    public var part: Part
    public var row: LanguageRow

    public var id: String { part.rawValue + "/" + row.id }
}

/// The language list in Settings: each language by its own name and by its name in the app's language, in the order of the
/// second, with a search over both, the English name and the code.
public enum LanguageList {
    /// The English names, as README.md's language table has them (a test keeps the two the same)
    public static func englishName(_ language: AppLanguage) -> String {
        switch language {
        case .arabic: return "Arabic"
        case .bengali: return "Bengali"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .english: return "English"
        case .french: return "French"
        case .german: return "German"
        case .gujarati: return "Gujarati"
        case .haitianCreole: return "Haitian Creole"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese (Brazil)"
        case .russian: return "Russian"
        case .spanish: return "Spanish (Latin America)"
        case .tagalog: return "Tagalog"
        case .ukrainian: return "Ukrainian"
        case .urdu: return "Urdu"
        case .vietnamese: return "Vietnamese"
        case .yiddish: return "Yiddish"
        }
    }

    /// A language's name in another language, as the Mac has it: asked with the app's language and the named one's identifier
    public typealias SystemNames = @Sendable (_ interface: AppLanguage, _ identifier: String) -> String?

    public static let macNames: SystemNames = { interface, identifier in
        interface.locale.localizedString(forIdentifier: identifier)
    }

    /// What the Mac is asked for: the variant the app's translation is in
    static func identifier(_ language: AppLanguage) -> String {
        switch language {
        case .chineseSimplified: return "zh_Hans"
        case .chineseTraditional: return "zh_Hant"
        case .portuguese: return "pt_BR"
        case .spanish: return "es_419"
        default: return language.rawValue
        }
    }

    /// The app's languages the Mac has no names in: asked, it answers in another language (in French for Haitian Creole), so
    /// it isn't asked
    static let noSystemNames: Set<AppLanguage> = [.haitianCreole]

    /// The app's languages written with Latin letters
    static let latinScript: Set<AppLanguage> = [.english, .french, .german, .haitianCreole, .italian, .polish, .portuguese,
                                                .spanish, .tagalog, .vietnamese]

    /// The name of `language` in the app's language `interface`. In English, the app's own English names. Else the name in
    /// Resources/language_names_extra.json when it has one (the names the Mac lacks), else the Mac's, else the English name
    public static func name(of language: AppLanguage, in interface: AppLanguage, system: SystemNames = macNames) -> String {
        named(language, in: interface, system: system).name
    }

    /// Where a name in the list comes from
    public enum NameSource: String, Sendable {
        /// The app's own English names, with the app shown in English
        case english
        /// The app's own, for a language the Mac has no name in (Resources/language_names_extra.json)
        case app
        /// The Mac's
        case mac
        /// The English name: the Mac had none that could be used
        case fallback
    }

    /// The name of `language` in `interface` (see name(of:in:)) and where it comes from
    public static func named(_ language: AppLanguage, in interface: AppLanguage,
                             system: SystemNames = macNames) -> (name: String, source: NameSource) {
        if interface == .english { return (englishName(language), .english) }
        if let extra = Translations.languageNamesExtra(interface)[language.rawValue], !extra.isEmpty { return (extra, .app) }
        if !noSystemNames.contains(interface) {
            let asked = identifier(language)
            let name = (system(interface, asked) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if usable(name, asked: asked, in: interface) { return (capitalized(name, in: interface), .mac) }
        }
        return (englishName(language), .fallback)
    }

    /// Not a name: nothing, the identifier handed back, or Latin letters in a language not written with them (the Mac fell
    /// back to another language, or left a code in the name)
    static func usable(_ name: String, asked: String, in interface: AppLanguage) -> Bool {
        guard !name.isEmpty, name != asked, name != asked.replacingOccurrences(of: "_", with: "-") else { return false }
        if !latinScript.contains(interface), name.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
            return false
        }
        return true
    }

    /// Many languages write a language's name small inside a sentence ("allemand"); at the start of a row it gets a capital
    static func capitalized(_ name: String, in interface: AppLanguage) -> String {
        guard let first = name.first else { return name }
        return String(first).uppercased(with: interface.locale) + name.dropFirst()
    }

    /// Every language, in the order of its name in the app's language (that language's own alphabetical order)
    public static func rows(in interface: AppLanguage, system: SystemNames = macNames) -> [LanguageRow] {
        let rows = AppLanguage.allCases.map { language -> LanguageRow in
            let native = language.nativeName
            let local = name(of: language, in: interface, system: system)
            let second = language == interface || fold(local) == fold(native) ? nil : local
            let words = [native, local, englishName(language), language.rawValue] + otherNames(language)
            return LanguageRow(language: language, nativeName: native, secondName: second, sortName: local,
                               searchWords: words.map(fold))
        }
        let locale = interface.locale
        return rows.sorted { a, b in
            let order = a.sortName.compare(b.sortName, options: [.caseInsensitive], range: nil, locale: locale)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    /// Other names and codes people look a language up by
    static func otherNames(_ language: AppLanguage) -> [String] {
        switch language {
        case .bengali: return ["Bangla"]
        case .tagalog: return ["Filipino", "fil"]
        case .chineseSimplified: return ["zh-CN"]
        case .chineseTraditional: return ["zh-TW", "zh-HK"]
        default: return []
        }
    }

    /// The rows that have every word typed somewhere in their names or code, whatever the capitals and accents. The ones with
    /// a name or code that begins with what was typed come first; otherwise the list's order stays. Nothing typed: all of them
    public static func search(_ query: String, in rows: [LanguageRow]) -> [LanguageRow] {
        let typed = fold(query)
        let words = typed.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rows }
        let found = rows.filter { row in words.allSatisfy { word in row.searchWords.contains { $0.contains(word) } } }
        let begins = found.filter { row in row.searchWords.contains { $0.hasPrefix(typed) } }
        let first = Set(begins.map(\.id))
        return begins + found.filter { !first.contains($0.id) }
    }

    /// The rows of one part of the list, in their order, each with an id no row of another part has (LanguageListItem)
    public static func items(_ rows: [LanguageRow], in part: LanguageListItem.Part) -> [LanguageListItem] {
        rows.map { LanguageListItem(part: part, row: $0) }
    }

    /// The Mac's preferred languages that the app has, most preferred first, each once: the list's "Suggested" rows
    public static func suggested(preferred: [String], limit: Int = 3) -> [AppLanguage] {
        var list: [AppLanguage] = []
        for code in preferred where list.count < limit {
            guard let language = AppLanguage.matching(preferred: [code]), !list.contains(language) else { continue }
            list.append(language)
        }
        return list
    }

    /// Text as it is compared in a search: no capitals, no accents, full-width letters as plain ones, single spaces
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
