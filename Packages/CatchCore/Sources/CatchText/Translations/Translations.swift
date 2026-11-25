import Foundation

/// UI translation tables. Each language is a JSON file in Resources/translations, named by its
/// AppLanguage raw value, whose keys are the English text (so other languages stay
/// out of the Swift source). English needs no table. A table is read the first time it is needed and then kept.
enum Translations {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var tables: [AppLanguage: [String: String]] = [:]
        var names: [String: String]?
        var dateNames: [String: DateNames]?
        var extraNames: [String: [String: String]]?
    }

    private static let cache = Cache()

    static func table(for language: AppLanguage) -> [String: String] {
        guard language != .english else { return [:] }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let table = cache.tables[language] { return table }
        let table = load(language.rawValue, folder: "translations")
        cache.tables[language] = table
        return table
    }

    /// Each language's name in its own spelling (Resources/language_names.json), for the language menu.
    static func languageName(_ language: AppLanguage) -> String {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.names == nil { cache.names = load("language_names") }
        return cache.names?[language.rawValue] ?? language.rawValue
    }

    /// Month and weekday names for a language whose locale has no date data (Resources/date_names.json, by AppLanguage
    /// raw value); nil for every other language, which uses the system's own names. Only Haitian Creole has them now.
    static func dateNames(_ language: AppLanguage) -> DateNames? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.dateNames == nil { cache.dateNames = decode("date_names") ?? [:] }
        guard let names = cache.dateNames?[language.rawValue], names.isComplete else { return nil }
        return names
    }

    /// The names of languages in a language the Mac has none or not all in (Resources/language_names_extra.json: by the raw
    /// value of the language the app is shown in, then by the named language's); empty for every other language.
    static func languageNamesExtra(_ interface: AppLanguage) -> [String: String] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if cache.extraNames == nil { cache.extraNames = decode("language_names_extra") ?? [:] }
        return cache.extraNames?[interface.rawValue] ?? [:]
    }

    /// Reads one JSON file copied from Resources; an empty table if it is missing or can't be read.
    static func load(_ name: String, folder: String? = nil) -> [String: String] {
        decode(name, folder: folder) ?? [:]
    }

    private static func decode<Value: Decodable>(_ name: String, folder: String? = nil) -> Value? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: folder),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
