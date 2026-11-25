import XCTest
@testable import CatchText

/// The language list in Settings: the two names of each row, the order, the search, the suggested rows.
final class LanguageListTests: XCTestCase {
    /// Stands in for the Mac's names: "<identifier> in <language>", so every name is known and the same on every machine
    private static let plain: LanguageList.SystemNames = { interface, identifier in "\(identifier) in \(interface.rawValue)" }

    /// Names as a Mac shown in German has them, for the rows the tests look at
    private static let german: LanguageList.SystemNames = { interface, identifier in
        guard interface == .german else { return nil }
        return ["ar": "Arabisch", "de": "Deutsch", "en": "Englisch", "fr": "Franz\u{F6}sisch", "it": "Italienisch", "ja": "Japanisch",
                "pl": "Polnisch", "zh_Hans": "Chinesisch (Vereinfacht)", "zh_Hant": "Chinesisch (Traditionell)",
                "es_419": "Spanisch (Lateinamerika)", "pt_BR": "Portugiesisch (Brasilien)", "uk": "Ukrainisch"][identifier]
    }

    // MARK: Names

    func testEnglishNamesAreTheReadmes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let readme = root.appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readme.path) else {
            throw XCTSkip("README.md not found (CatchCore package copied alone), skipping")
        }
        let text = try String(contentsOf: readme, encoding: .utf8)
        let table = try XCTUnwrap(text.components(separatedBy: "<!-- native-language-names:start -->").dropFirst().first?
            .components(separatedBy: "<!-- native-language-names:end -->").first)
        let english = table.split(separator: "\n").compactMap { line -> String? in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 2, cells[0] != "Language", !cells[0].hasPrefix("-"), !cells[0].hasPrefix(":") else { return nil }
            return cells[0].replacingOccurrences(of: "<br>(right to left)", with: "").replacingOccurrences(of: "<br>", with: " ")
        }
        XCTAssertEqual(english, AppLanguage.allCases.map(LanguageList.englishName))
    }

    func testInEnglishTheNamesAreTheAppsOwn() {
        // Whatever the Mac would say ("Bangla", "Filipino"), it isn't asked
        let never: LanguageList.SystemNames = { _, _ in "something else" }
        for language in AppLanguage.allCases {
            XCTAssertEqual(LanguageList.name(of: language, in: .english, system: never), LanguageList.englishName(language))
        }
        XCTAssertEqual(LanguageList.englishName(.bengali), "Bengali")
        XCTAssertEqual(LanguageList.englishName(.tagalog), "Tagalog")
        XCTAssertEqual(Set(AppLanguage.allCases.map(LanguageList.englishName)).count, AppLanguage.allCases.count)
    }

    func testTheMacIsAskedForTheVariantTheAppHas() {
        XCTAssertEqual(LanguageList.name(of: .chineseSimplified, in: .french, system: Self.plain), "Zh_Hans in fr")
        XCTAssertEqual(LanguageList.name(of: .chineseTraditional, in: .french, system: Self.plain), "Zh_Hant in fr")
        XCTAssertEqual(LanguageList.name(of: .portuguese, in: .french, system: Self.plain), "Pt_BR in fr")
        XCTAssertEqual(LanguageList.name(of: .spanish, in: .french, system: Self.plain), "Es_419 in fr")
        // Tagalog by its own code: the app calls it Tagalog, not Filipino
        XCTAssertEqual(LanguageList.name(of: .tagalog, in: .french, system: Self.plain), "Tl in fr")
        XCTAssertEqual(LanguageList.name(of: .german, in: .french, system: Self.plain), "De in fr")
    }

    func testANameStartsWithACapital() {
        let small: LanguageList.SystemNames = { _, identifier in identifier == "de" ? "allemand" : " espagnol (Am\u{E9}rique latine)\n" }
        XCTAssertEqual(LanguageList.name(of: .german, in: .french, system: small), "Allemand")
        XCTAssertEqual(LanguageList.name(of: .spanish, in: .french, system: small), "Espagnol (Am\u{E9}rique latine)")
        // Writing without capitals stays as it is
        let japanese: LanguageList.SystemNames = { _, _ in "\u{30C9}\u{30A4}\u{30C4}\u{8A9E}" }
        XCTAssertEqual(LanguageList.name(of: .german, in: .japanese, system: japanese), "\u{30C9}\u{30A4}\u{30C4}\u{8A9E}")
    }

    func testWhatIsNotANameFallsBackToEnglish() {
        let nothing: LanguageList.SystemNames = { _, _ in nil }
        let empty: LanguageList.SystemNames = { _, _ in "  " }
        let echo: LanguageList.SystemNames = { _, identifier in identifier }
        let dashed: LanguageList.SystemNames = { _, identifier in identifier.replacingOccurrences(of: "_", with: "-") }
        for system in [nothing, empty, echo, dashed] {
            XCTAssertEqual(LanguageList.name(of: .german, in: .french, system: system), "German")
            XCTAssertEqual(LanguageList.name(of: .chineseSimplified, in: .russian, system: system), "Chinese (Simplified)")
            // Also where Latin letters alone wouldn't give it away, with "_" or "-" in the identifier
            XCTAssertEqual(LanguageList.name(of: .portuguese, in: .italian, system: system), "Portuguese (Brazil)")
            XCTAssertEqual(LanguageList.name(of: .chineseTraditional, in: .french, system: system), "Chinese (Traditional)")
        }
        // Latin letters in a language not written with them: another language's name, or a code left in the name
        let french: LanguageList.SystemNames = { _, _ in "allemand" }
        XCTAssertEqual(LanguageList.name(of: .german, in: .russian, system: french), "German")
        XCTAssertEqual(LanguageList.name(of: .german, in: .korean, system: french), "German")
        let coded: LanguageList.SystemNames = { _, _ in "\u{4E2D}\u{6587} (Hans)" }
        XCTAssertEqual(LanguageList.name(of: .chineseSimplified, in: .japanese, system: coded), "Chinese (Simplified)")
        // In a language written with Latin letters there is no telling: the name is taken
        XCTAssertEqual(LanguageList.name(of: .german, in: .italian, system: french), "Allemand")
        // Every language is one or the other
        XCTAssertTrue(LanguageList.latinScript.isSubset(of: Set(AppLanguage.allCases)))
        XCTAssertEqual(LanguageList.latinScript.count, 10)
        XCTAssertTrue(LanguageList.latinScript.allSatisfy { !$0.isRightToLeft })
    }

    /// Haitian Creole: the Mac answers in French, so it isn't asked and the app has all the names. Yiddish: the app has the
    /// few the Mac lacks, and they count before the Mac's
    func testNamesTheMacLacksAreTheAppsOwn() {
        let asked = Asked()
        let recording: LanguageList.SystemNames = { interface, identifier in
            asked.add(interface)
            return "\(identifier) from the Mac"
        }
        for language in AppLanguage.allCases {
            let name = LanguageList.name(of: language, in: .haitianCreole, system: recording)
            XCTAssertFalse(name.contains("from the Mac"), language.rawValue)
            XCTAssertEqual(name, Translations.languageNamesExtra(.haitianCreole)[language.rawValue], language.rawValue)
        }
        XCTAssertFalse(asked.all.contains(.haitianCreole))
        XCTAssertEqual(LanguageList.name(of: .haitianCreole, in: .haitianCreole, system: recording), AppLanguage.haitianCreole.nativeName)
        XCTAssertEqual(LanguageList.name(of: .english, in: .haitianCreole, system: recording), "Angl\u{E8}")

        let yiddish = Translations.languageNamesExtra(.yiddish)
        XCTAssertEqual(Set(yiddish.keys), ["gu", "ht", "zh-Hans", "zh-Hant"])
        for language in [AppLanguage.gujarati, .haitianCreole, .chineseSimplified, .chineseTraditional] {
            XCTAssertEqual(LanguageList.name(of: language, in: .yiddish, system: recording), yiddish[language.rawValue])
        }
    }

    /// Where each name comes from: the one the list shows, from the same rules
    func testWhereANameComesFrom() {
        let nothing: LanguageList.SystemNames = { _, _ in nil }
        XCTAssertTrue(LanguageList.named(.german, in: .english, system: Self.plain) == ("German", .english))
        XCTAssertTrue(LanguageList.named(.german, in: .french, system: Self.plain) == ("De in fr", .mac))
        XCTAssertTrue(LanguageList.named(.german, in: .french, system: nothing) == ("German", .fallback))
        XCTAssertTrue(LanguageList.named(.english, in: .haitianCreole, system: Self.plain) == ("Angl\u{E8}", .app))
        XCTAssertTrue(LanguageList.named(.gujarati, in: .yiddish, system: Self.plain)
            == (Translations.languageNamesExtra(.yiddish)["gu"] ?? "", .app))
        for interface in AppLanguage.allCases {
            for language in AppLanguage.allCases {
                XCTAssertEqual(LanguageList.named(language, in: interface, system: Self.plain).name,
                               LanguageList.name(of: language, in: interface, system: Self.plain))
            }
        }
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AppLanguage] = []
        func add(_ language: AppLanguage) { lock.lock(); list.append(language); lock.unlock() }
        var all: [AppLanguage] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testTheExtraNamesFile() {
        let known = Set(AppLanguage.allCases.map(\.rawValue))
        var withNames: [AppLanguage] = []
        for interface in AppLanguage.allCases {
            let names = Translations.languageNamesExtra(interface)
            guard !names.isEmpty else { continue }
            withNames.append(interface)
            XCTAssertTrue(Set(names.keys).isSubset(of: known), interface.rawValue)
            for (code, name) in names {
                let spot = "\(interface.rawValue) \(code)"
                XCTAssertFalse(name.isEmpty, spot)
                XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines), spot)
                XCTAssertEqual(name, name.precomposedStringWithCanonicalMapping, spot)
                // Yiddish is written with its letters one by one, as in the translations (no joined double letters)
                XCTAssertFalse(name.unicodeScalars.contains { (0x5F0...0x5F2).contains($0.value) }, spot)
                // No marks that set the direction
                XCTAssertFalse(name.unicodeScalars.contains { [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x2066, 0x2067, 0x2069].contains($0.value) }, spot)
                if LanguageList.latinScript.contains(interface) {
                    XCTAssertEqual(String(name.prefix(1)), String(name.prefix(1)).uppercased(), spot)
                } else {
                    XCTAssertFalse(name.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }, spot)
                }
            }
            XCTAssertEqual(Set(names.values).count, names.count, "\(interface.rawValue): two languages with one name")
        }
        XCTAssertEqual(withNames, [.haitianCreole, .yiddish])
        // A language that isn't asked of the Mac has every name here
        for interface in LanguageList.noSystemNames {
            XCTAssertEqual(Set(Translations.languageNamesExtra(interface).keys), known, interface.rawValue)
        }
        // Its own name is the one the list shows first
        XCTAssertEqual(Translations.languageNamesExtra(.haitianCreole)["ht"], AppLanguage.haitianCreole.nativeName)
    }

    /// With the Mac's real names, whatever they are on this machine: every row has a name, in every language
    func testEveryLanguageHasANameInEveryLanguage() {
        for interface in AppLanguage.allCases {
            let rows = LanguageList.rows(in: interface)
            XCTAssertEqual(rows.count, AppLanguage.allCases.count)
            XCTAssertEqual(Set(rows.map(\.language)), Set(AppLanguage.allCases))
            for row in rows {
                XCTAssertFalse(row.sortName.isEmpty, "\(interface.rawValue) \(row.id)")
                XCTAssertNotEqual(row.sortName, row.id, "\(interface.rawValue) \(row.id)")
                XCTAssertEqual(row.nativeName, row.language.nativeName)
                XCTAssertNotEqual(row.secondName, "", "\(interface.rawValue) \(row.id)")
            }
            XCTAssertNil(rows.first { $0.language == interface }?.secondName, interface.rawValue)
        }
    }

    // MARK: Rows

    func testARowHasItsOwnNameAndItsNameInTheAppsLanguage() throws {
        let rows = LanguageList.rows(in: .german, system: Self.german)
        let french = try XCTUnwrap(rows.first { $0.language == .french })
        XCTAssertEqual(french.nativeName, "Fran\u{E7}ais")
        XCTAssertEqual(french.secondName, "Franz\u{F6}sisch")
        // The app's own language has one name
        let own = try XCTUnwrap(rows.first { $0.language == .german })
        XCTAssertEqual(own.nativeName, "Deutsch")
        XCTAssertNil(own.secondName)
        XCTAssertEqual(own.sortName, "Deutsch")
        // A language the stand-in has no name for: its English name
        XCTAssertEqual(rows.first { $0.language == .hindi }?.secondName, "Hindi")
        // The same name twice is shown once: Tagalog in English, Italian in an app shown in Italian but for a capital
        XCTAssertNil(LanguageList.rows(in: .english).first { $0.language == .tagalog }?.secondName)
        XCTAssertNil(LanguageList.rows(in: .english).first { $0.language == .english }?.secondName)
        let italian: LanguageList.SystemNames = { _, identifier in identifier == "it" ? "ITALIANO" : nil }
        XCTAssertNil(LanguageList.rows(in: .french, system: italian).first { $0.language == .italian }?.secondName)
        XCTAssertEqual(LanguageList.rows(in: .english).first { $0.language == .german }?.secondName, "German")
    }

    func testTheOrderIsByTheNameInTheAppsLanguage() {
        // In English: the alphabetical order of the English names, which is the order README.md's table and AppLanguage have
        XCTAssertEqual(LanguageList.rows(in: .english).map(\.language), AppLanguage.allCases)
        // In German by the German names: "Deutsch" comes before "Englisch", "Polnisch" before "Portugiesisch", and the ones
        // the stand-in has no German name for fall in by their English names
        let order = LanguageList.rows(in: .german, system: Self.german).map(\.sortName)
        XCTAssertEqual(order, order.sorted { $0.compare($1, options: [.caseInsensitive], range: nil, locale: Locale(identifier: "de_DE")) == .orderedAscending })
        func place(_ name: String) -> Int { order.firstIndex(of: name) ?? -1 }
        XCTAssertLessThan(place("Arabisch"), place("Bengali"))
        XCTAssertLessThan(place("Chinesisch (Traditionell)"), place("Chinesisch (Vereinfacht)"))
        XCTAssertLessThan(place("Deutsch"), place("Englisch"))
        XCTAssertLessThan(place("Polnisch"), place("Portugiesisch (Brasilien)"))
        XCTAssertLessThan(place("Spanisch (Lateinamerika)"), place("Tagalog"))
        XCTAssertGreaterThanOrEqual(place("Arabisch"), 0)
        // Capitals don't decide, and two with one name keep a fixed order (by code)
        let same: LanguageList.SystemNames = { _, identifier in ["de": "b", "fr": "A", "it": "a", "pl": "C"][identifier] ?? "z" }
        let first = LanguageList.rows(in: .spanish, system: same).prefix(4).map(\.language)
        XCTAssertEqual(first, [.french, .italian, .german, .polish])
    }

    // MARK: Search

    func testSearch() {
        let rows = LanguageList.rows(in: .german, system: Self.german)
        func found(_ text: String) -> [AppLanguage] { LanguageList.search(text, in: rows).map(\.language) }
        // Nothing typed, or only spaces: every row, in the list's order
        XCTAssertEqual(found(""), rows.map(\.language))
        XCTAssertEqual(found("  "), rows.map(\.language))
        // By its own name, by its name in the app's language, by its English name, whatever the capitals and accents
        XCTAssertEqual(found("Fran\u{E7}ais"), [.french])
        XCTAssertEqual(found("francais"), [.french])
        XCTAssertEqual(found("FRANZ\u{D6}SISCH"), [.french])
        XCTAssertEqual(found("franzosisch"), [.french])
        XCTAssertEqual(found("French"), [.french])
        XCTAssertEqual(found("espanol"), [.spanish])
        XCTAssertEqual(found("kreyol"), [.haitianCreole])
        XCTAssertEqual(found("\u{65E5}\u{672C}"), [.japanese])
        XCTAssertEqual(found("\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"), [.arabic])
        // By code
        XCTAssertEqual(found("zh"), [.chineseSimplified, .chineseTraditional].sorted { a, b in
            rows.firstIndex { $0.language == a }! < rows.firstIndex { $0.language == b }!
        })
        XCTAssertEqual(found("zh-hant"), [.chineseTraditional])
        XCTAssertEqual(found("ZH-TW"), [.chineseTraditional])
        XCTAssertEqual(found("zh-cn"), [.chineseSimplified])
        // By another name it goes by
        XCTAssertEqual(found("bangla"), [.bengali])
        XCTAssertEqual(found("Filipino"), [.tagalog])
        // Every word typed must be there, in any order and in any of the names
        XCTAssertEqual(found("simplified chinese"), [.chineseSimplified])
        XCTAssertEqual(found("chinesisch trad"), [.chineseTraditional])
        XCTAssertEqual(found("portuguese brasil"), [.portuguese])
        XCTAssertEqual(found("chinese french"), [])
        // Full-width letters typed with a Chinese or Japanese keyboard
        XCTAssertEqual(found("\u{FF50}\u{FF4F}\u{FF4C}\u{FF53}\u{FF4B}\u{FF49}"), [.polish])
        // Nothing found
        XCTAssertEqual(found("klingon"), [])
        XCTAssertEqual(found("qq"), [])
    }

    /// "it" is inside "Haitian Creole", which comes before Italian in the list: the one that begins with it comes first
    func testWhatBeginsWithTheTypedTextComesFirst() {
        let rows = LanguageList.rows(in: .english)
        let found = LanguageList.search("it", in: rows).map(\.language)
        XCTAssertEqual(found.first, .italian)
        XCTAssertTrue(found.contains(.haitianCreole))
        XCTAssertLessThan(rows.firstIndex { $0.language == .haitianCreole }!, rows.firstIndex { $0.language == .italian }!)
        // Among the ones that begin with it, and among the rest, the list's order stays
        let po = LanguageList.search("po", in: rows).map(\.language)
        XCTAssertEqual(Array(po.prefix(2)), [.polish, .portuguese])
        let en = LanguageList.search("en", in: rows).map(\.language)
        XCTAssertEqual(en.first, .english)
        let rest = Array(en.dropFirst())
        XCTAssertEqual(rest, rows.map(\.language).filter { rest.contains($0) })
        XCTAssertTrue(rest.contains(.french))
        XCTAssertEqual(Set(en).count, en.count)
    }

    func testFolding() {
        XCTAssertEqual(LanguageList.fold("  Portugu\u{EA}s   (Brasil) "), "portugues (brasil)")
        XCTAssertEqual(LanguageList.fold("Ti\u{1EBF}ng Vi\u{1EC7}t"), "tieng viet")
        XCTAssertEqual(LanguageList.fold("\u{FF21}\u{FF22}"), "ab")
        XCTAssertEqual(LanguageList.fold(""), "")
    }

    // MARK: Suggested

    func testSuggestedAreTheMacsLanguagesTheAppHas() {
        XCTAssertEqual(LanguageList.suggested(preferred: ["zh-Hans-US", "en-US", "xx-YY", "zh-CN", "es-MX", "fr-FR"]),
                       [.chineseSimplified, .english, .spanish])
        XCTAssertEqual(LanguageList.suggested(preferred: ["fil-PH", "pt-PT", "en-GB", "en-US"]), [.tagalog, .portuguese, .english])
        XCTAssertEqual(LanguageList.suggested(preferred: ["tr-TR", "id-ID"]), [])
        XCTAssertEqual(LanguageList.suggested(preferred: []), [])
        XCTAssertEqual(LanguageList.suggested(preferred: ["de-DE", "de-AT", "de-CH"]), [.german])
        XCTAssertEqual(LanguageList.suggested(preferred: ["ja", "ko", "he", "ar"], limit: 2), [.japanese, .korean])
    }

    /// A suggested language is under "All languages" too, and in one lazy list a second row with the same id is drawn blank
    /// (German, suggested, was a blank row under "All languages"): no two rows of the list have the same id
    func testEveryRowOfTheListHasAnIdOfItsOwn() {
        let rows = LanguageList.rows(in: .french, system: Self.plain)
        let suggested = LanguageList.suggested(preferred: ["de-DE", "sw-KE", "ja-JP", "es-419"]).compactMap { language in
            rows.first { $0.language == language }
        }
        XCTAssertEqual(suggested.map(\.language), [.german, .japanese, .spanish])
        let list = LanguageList.items(suggested, in: .suggested) + LanguageList.items(rows, in: .all)
        XCTAssertEqual(list.count, 3 + AppLanguage.allCases.count)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        // Each part keeps its rows, in their order
        XCTAssertEqual(list.filter { $0.part == .suggested }.map(\.row), suggested)
        XCTAssertEqual(list.filter { $0.part == .all }.map(\.row), rows)
        // A search's rows are one part's too
        let found = LanguageList.items(LanguageList.search("de", in: rows), in: .all)
        XCTAssertEqual(Set(found.map(\.id)).count, found.count)
    }
}
