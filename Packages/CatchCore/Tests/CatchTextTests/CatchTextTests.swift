import XCTest
@testable import CatchText
import TransitCore

final class CatchTextTests: XCTestCase {

    // MARK: Languages

    func testEnglishIsDefault() {
        XCTAssertEqual(AppLanguage.default, .english)
        XCTAssertEqual(AppText().language, .english)
        XCTAssertEqual(AppText().t("Refresh"), "Refresh")
        XCTAssertEqual(DistanceUnit.default, .usCustomary)
        XCTAssertEqual(ClockStyle.default, .twelveHour)
    }

    /// A new install starts in the first of the Mac's languages that the app has
    func testMatchesMacLanguage() {
        XCTAssertEqual(AppLanguage.matching(preferred: ["zh-Hans-US", "en-US"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.matching(preferred: ["zh-Hant-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.matching(preferred: ["zh-HK"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.matching(preferred: ["zh_CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.matching(preferred: ["pt-PT"]), .portuguese)
        XCTAssertEqual(AppLanguage.matching(preferred: ["es-419"]), .spanish)
        XCTAssertEqual(AppLanguage.matching(preferred: ["en-GB", "de-DE"]), .english)
        // A language the app doesn't have is skipped for the next one; none at all gives nil (English is used)
        XCTAssertEqual(AppLanguage.matching(preferred: ["tr-TR", "ar-SA"]), .arabic)
        XCTAssertNil(AppLanguage.matching(preferred: ["tr-TR", "nl-NL"]))
        XCTAssertNil(AppLanguage.matching(preferred: []))
    }

    /// "System Language": a new install follows the Mac, a Mac updating from an older version keeps what it showed,
    /// a chosen language stays, and following the Mac picks its language again at each launch
    func testSystemLanguageAtLaunch() {
        func launch(_ saved: AppLanguage?, follows: Bool, new: Bool, _ preferred: [String]) -> AppLanguage? {
            let result = AppLanguage.atLaunch(saved: saved, followsMac: follows, isNewInstall: new, preferred: preferred)
            // nil: not following the Mac
            return result.followsMac ? result.language : nil
        }
        func chosen(_ saved: AppLanguage?, follows: Bool, new: Bool, _ preferred: [String]) -> AppLanguage? {
            let result = AppLanguage.atLaunch(saved: saved, followsMac: follows, isNewInstall: new, preferred: preferred)
            return result.followsMac ? nil : result.language
        }
        // A new install follows the Mac: its first language the app has, else English
        XCTAssertEqual(launch(nil, follows: false, new: true, ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(launch(nil, follows: false, new: true, ["nl-NL"]), .english)
        // A Mac updating from a version without the language menu keeps English, as chosen, not following
        XCTAssertEqual(chosen(nil, follows: false, new: false, ["ja-JP"]), .english)
        // A language chosen in Settings stays, whatever the Mac's language
        XCTAssertEqual(chosen(.english, follows: false, new: false, ["ja-JP"]), .english)
        XCTAssertEqual(chosen(.german, follows: false, new: true, ["ja-JP"]), .german)
        // System Language: the Mac's language now, also when it changed since the last launch
        XCTAssertEqual(launch(.japanese, follows: true, new: false, ["fr-CA", "ja-JP"]), .french)
        XCTAssertEqual(launch(.french, follows: true, new: false, ["tr-TR"]), .english)
        XCTAssertEqual(launch(nil, follows: true, new: false, ["he-IL"]), .hebrew)
        XCTAssertEqual(AppLanguage.macLanguage(preferred: ["ar-SA", "en-US"]), .arabic)
        XCTAssertEqual(AppLanguage.macLanguage(preferred: []), .english)
        // The menu item names the language it follows, in each language's own text
        let japanese = AppLanguage.japanese.nativeName
        XCTAssertEqual(AppText().f("System Language (%@)", japanese), "System Language (\(japanese))")
        for language in AppLanguage.allCases {
            XCTAssertTrue(AppText(language: language).f("System Language (%@)", "X").contains("X"), language.rawValue)
        }
    }

    /// Spanish is the Latin American translation and Portuguese the Brazilian one, but every regional variant of a language
    /// (and the bare language code) gets that language's translation, never English
    func testRegionalVariantsGetTheirLanguage() {
        let expected: [String: AppLanguage] = [
            "es": .spanish, "es-ES": .spanish, "es-MX": .spanish, "es-AR": .spanish, "es-US": .spanish, "es_CO": .spanish,
            "pt": .portuguese, "pt-BR": .portuguese, "pt-PT": .portuguese, "pt-AO": .portuguese, "pt_MZ": .portuguese,
            "en": .english, "en-US": .english, "en-GB": .english, "en-AU": .english, "en-CA": .english, "en-IN": .english,
            "fr-FR": .french, "fr-CA": .french, "fr-HT": .french, "de-AT": .german, "de-CH": .german, "it-CH": .italian,
            "ru-UA": .russian, "ko-KR": .korean, "ja-JP": .japanese, "uk-UA": .ukrainian, "ar-EG": .arabic, "ar-SA": .arabic,
            "he-IL": .hebrew, "hi-IN": .hindi, "ur-IN": .urdu, "ur-PK": .urdu, "vi-VN": .vietnamese, "bn-IN": .bengali,
            "bn-BD": .bengali, "pl": .polish, "pl-PL": .polish, "ht": .haitianCreole, "ht-HT": .haitianCreole,
            "yi": .yiddish, "yi-US": .yiddish, "gu": .gujarati, "gu-IN": .gujarati, "tl": .tagalog, "tl-PH": .tagalog,
            "fil": .tagalog, "fil-PH": .tagalog, "fil_US": .tagalog,
            "zh-Hans": .chineseSimplified, "zh-Hans-SG": .chineseSimplified, "zh-SG": .chineseSimplified,
            "zh-Hant": .chineseTraditional, "zh-Hant-HK": .chineseTraditional, "zh-TW": .chineseTraditional,
            "zh-MO": .chineseTraditional, "zh-HK": .chineseTraditional, "zh_CN": .chineseSimplified,
            // The script counts before the region: Simplified Chinese as used in Hong Kong, Taiwan or Macau stays Simplified
            "zh-Hans-HK": .chineseSimplified, "zh-Hans-TW": .chineseSimplified, "zh-Hans-MO": .chineseSimplified,
            "zh_Hans_HK": .chineseSimplified, "zh-Hant-CN": .chineseTraditional,
        ]
        for (code, language) in expected {
            XCTAssertEqual(AppLanguage.matching(preferred: [code]), language, code)
        }
        // Every language the app has is reached by its own code
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.matching(preferred: [language.rawValue]), language, language.rawValue)
        }
    }

    func testRightToLeftArgumentsAreIsolated() {
        for lang in AppLanguage.allCases {
            let text = AppText(language: lang)
            let filled = text.f("To %@", "34 St-Hudson Yards")
            XCTAssertEqual(filled.contains("\u{2068}34 St-Hudson Yards\u{2069}"), lang.isRightToLeft, lang.rawValue)
            XCTAssertEqual(text.commaList(["A", "B"]).contains("\u{2068}"), lang.isRightToLeft, lang.rawValue)
        }
        XCTAssertEqual(AppText(language: .arabic).comma, "\u{60C} ")
        XCTAssertEqual(AppText(language: .hebrew).comma, ", ")
    }

    // A distance, and the pieces of a line joined with " · ", keep their own order in right-to-left languages ("1,590 ft", not
    // "ft 1,590"), and the line still goes from right to left; other languages get them unchanged
    func testRightToLeftDistancesAndDottedLinesKeepTheirOrder() {
        for lang in AppLanguage.allCases {
            let text = AppText(language: lang, units: .usCustomary)
            let distance = text.distance(484.6)
            let dotted = text.dotted(["A", distance, "B"])
            if lang.isRightToLeft {
                XCTAssertTrue(distance.hasPrefix("\u{2068}") && distance.hasSuffix("\u{2069}"), lang.rawValue)
                XCTAssertTrue(text.radius(1219.2).hasPrefix("\u{2068}"), lang.rawValue)
                XCTAssertEqual(dotted, "\u{200F}\u{2068}A\u{2069} · \u{2068}" + distance + "\u{2069} · \u{2068}B\u{2069}", lang.rawValue)
            } else {
                XCTAssertFalse(distance.contains("\u{2068}"), lang.rawValue)
                XCTAssertFalse(text.radius(1219.2).contains("\u{2068}"), lang.rawValue)
                XCTAssertEqual(dotted, "A · " + distance + " · B", lang.rawValue)
            }
        }
        XCTAssertEqual(AppText(units: .usCustomary).distance(484.6), "1,590 ft")
        XCTAssertEqual(AppText().dotted([]), "")
        XCTAssertEqual(AppText(language: .arabic).dotted([]), "")
    }

    func testRightToLeftSentencesStartingWithEnglishKeepTheirDirection() {
        let key = "Catch My Train works best with these. Each one is optional."
        // The Hebrew and Yiddish translations start with the app's name; other languages are unchanged
        for lang in AppLanguage.allCases {
            let text = AppText(language: lang).t(key)
            XCTAssertEqual(text.hasPrefix("\u{200F}"), lang == .hebrew || lang == .yiddish, lang.rawValue)
        }
        // Text with no right-to-left letters, or whose first letter is already right-to-left (also after an isolated name), is unchanged
        let walk = "\u{05D4}\u{05DC}\u{05D9}\u{05DB}\u{05D4}"
        XCTAssertEqual(AppText.rightToLeftParagraph("SBS"), "SBS")
        XCTAssertEqual(AppText.rightToLeftParagraph("%@ m"), "%@ m")
        XCTAssertEqual(AppText.rightToLeftParagraph("%@ " + walk), "%@ " + walk)
        XCTAssertEqual(AppText.rightToLeftParagraph("\u{2068}MTA\u{2069} " + walk), "\u{2068}MTA\u{2069} " + walk)
        XCTAssertEqual(AppText.rightToLeftParagraph("MTA " + walk), "\u{200F}MTA " + walk)
        // After the change, every right-to-left translation with right-to-left letters starts in that direction
        for lang in AppLanguage.allCases where lang.isRightToLeft {
            let text = AppText(language: lang)
            for key in Translations.table(for: lang).keys {
                let shown = text.t(key)
                guard let first = shown.unicodeScalars.first(where: { AppText.isRightToLeftLetter($0) || $0.properties.isAlphabetic }),
                      shown.unicodeScalars.contains(where: AppText.isRightToLeftLetter) else { continue }
                XCTAssertTrue(AppText.isRightToLeftLetter(first), "\(lang.rawValue): \(key)")
            }
        }
    }

    func testLanguageNamesAreUnique() {
        let names = AppLanguage.allCases.map(\.nativeName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(AppLanguage.allCases.count, 23)   // 22 plus English
    }

    /// The installer's guide (folder name in Finder and the guide page) has every app language, with every field English has
    func testInstallGuideHasEveryLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let release = root.appendingPathComponent("tools/release")
        let guide = release.appendingPathComponent("translations/dmg-guide.json")
        guard FileManager.default.fileExists(atPath: guide.path) else {
            throw XCTSkip("Release tools not found (CatchCore package copied alone), skipping")
        }
        let texts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: guide)) as? [String: [String: String]])
        let english = try XCTUnwrap(texts["en"])
        XCTAssertEqual(Set(texts.keys), Set(AppLanguage.allCases.map(\.rawValue)), "Guide languages differ from the app's")
        for (code, fields) in texts {
            XCTAssertEqual(Set(fields.keys), Set(english.keys), "\(code) guide fields differ from English")
            XCTAssertFalse(fields.values.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(code) has an empty guide field")
            // The install page names the widget folder as Finder shows it: make-guide.py puts the name where the sentence has
            // its placeholder, and no other field has one
            XCTAssertEqual(fields["widget"]?.components(separatedBy: "{widgetFolder}").count, 2, "\(code) widget sentence doesn't name the folder once")
            XCTAssertFalse(fields.contains { $0.key != "widget" && $0.value.contains("{") }, "\(code) has a placeholder outside the widget sentence")
        }
        // Finder picks the folder name by the Mac's language: each language needs its .localized entry
        let script = try String(contentsOf: release.appendingPathComponent("make-guide.py"), encoding: .utf8)
        for language in AppLanguage.allCases {
            XCTAssertTrue(script.contains("\"\(language.rawValue)\": ["), "make-guide.py has no Finder names for \(language.rawValue)")
        }
        // The guide page picks Chinese the way the app does: by script first, by region only without one
        XCTAssertTrue(script.contains("rest.includes(\"hans\")") && script.contains("rest.includes(\"hant\")"),
                      "make-guide.py picks Chinese differently from AppLanguage.matching")
        // Steps point in reading direction: left-to-right languages never use the left arrow, and English names run left to right
        // even in a right-to-left sentence, so they take the right arrow
        let backArrow = try NSRegularExpression(pattern: Self.leftArrowBetweenEnglish)
        for (code, fields) in texts {
            let rightToLeft = AppLanguage(rawValue: code)?.isRightToLeft ?? false
            for (field, value) in fields {
                XCTAssertFalse(!rightToLeft && value.contains("\u{2190}"), "\(code) \(field) uses the left arrow")
                XCTAssertNil(backArrow.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                             "\(code) \(field) has a left arrow between English names")
            }
        }
    }

    /// The left arrow with English text on both sides (in a right-to-left sentence that run reads left to right, so the arrow would point back)
    static let leftArrowBetweenEnglish = "[A-Za-z&]\\s*\u{2190}\\s*[A-Za-z]"

    /// README.md's language table lists exactly the app's languages, by the names the language menu shows, in the alphabetical
    /// order of their English names (the README is in English): a fixed order would read like a ranking. The language menu lists
    /// them in the same order, in every language
    func testReadmeListsEveryLanguage() throws {
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
        let rows = table.split(separator: "\n").compactMap { line -> (english: String, native: String)? in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // The separator row starts with "-", or with ":" when a column is aligned (":---:" centers it)
            guard cells.count == 2, cells[0] != "Language", !cells[0].hasPrefix("-"), !cells[0].hasPrefix(":") else { return nil }
            // A long name can break onto a second line with <br>; the app shows it on one line. "(right to left)" is a note, not
            // part of the name
            let english = cells[0].replacingOccurrences(of: "<br>(right to left)", with: "").replacingOccurrences(of: "<br>", with: " ")
            return (english, cells[1].replacingOccurrences(of: "<br>", with: " "))
        }
        XCTAssertEqual(Set(rows.map(\.native)), Set(AppLanguage.allCases.map(\.nativeName)))
        XCTAssertEqual(rows.count, AppLanguage.allCases.count)
        let english = rows.map(\.english)
        XCTAssertEqual(english, english.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "not in alphabetical order")
        XCTAssertEqual(rows.map(\.native), AppLanguage.allCases.map(\.nativeName),
                       "the language menu (AppLanguage's cases, in order) and the table aren't in the same order")
    }

    // Two sentences in one line of text: a space between them, none in Chinese and Japanese; an empty one adds nothing
    func testSentencesOneAfterAnother() {
        XCTAssertEqual(AppText(language: .english).sentences(["One.", "Two."]), "One. Two.")
        XCTAssertEqual(AppText(language: .english).sentences(["One.", ""]), "One.")
        XCTAssertEqual(AppText(language: .japanese).sentences(["\u{3042}\u{3002}", "\u{3044}\u{3002}"]), "\u{3042}\u{3002}\u{3044}\u{3002}")
        XCTAssertEqual(AppText(language: .chineseSimplified).sentences(["\u{4E00}\u{3002}", "\u{4E8C}\u{3002}"]), "\u{4E00}\u{3002}\u{4E8C}\u{3002}")
        XCTAssertEqual(AppText(language: .korean).sentences(["\u{D558}\u{B098}.", "\u{B458}."]), "\u{D558}\u{B098}. \u{B458}.")
    }

    // A label and what follows it, with the colon each language's own translations use ("Sans horaires : …" in French, the
    // full-width colon in Chinese and Japanese)
    func testALabelAndItsText() {
        XCTAssertEqual(AppText(language: .english).labeled("Without times", "Island Queen"), "Without times: Island Queen")
        XCTAssertEqual(AppText(language: .french).labeled("Sans horaires", "Island Queen"), "Sans horaires\u{A0}: Island Queen")
        XCTAssertEqual(AppText(language: .japanese).labeled("\u{6642}\u{523B}\u{306A}\u{3057}", "A"), "\u{6642}\u{523B}\u{306A}\u{3057}\u{FF1A}A")
        XCTAssertEqual(AppText(language: .chineseTraditional).labeled("X", "Y"), "X\u{FF1A}Y")
        XCTAssertEqual(AppText(language: .german).labeled("X", "Y"), "X: Y")
        // As the translations of "Not included: …" write it
        for language in [AppLanguage.french, .japanese, .chineseSimplified, .chineseTraditional, .german] {
            let l = AppText(language: language)
            let sentence = l.t("Not included: private commuter buses whose times aren't published in a form Catch My Train can use.")
            let colon = l.labeled("", "").trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(sentence.contains(l.labeled("", "")) || sentence.contains(colon), language.rawValue)
        }
    }

    // The Settings window's six pages have six different names in every language (two with one name couldn't be told apart
    // in its column)
    func testSettingsPagesHaveNamesOfTheirOwn() {
        let pages = ["General", "Running", "Privacy", "Search range", "Data source", "Reminders", "About"]
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            XCTAssertEqual(Set(pages.map { l.t($0) }).count, pages.count, language.rawValue)
        }
    }

    func testEveryLanguageTranslatesEveryKey() {
        let keys = Set(AppText.allKeys)
        XCTAssertEqual(keys.count, AppText.allKeys.count, "allKeys has duplicates")
        for language in AppLanguage.allCases where language != .english {
            let table = Translations.table(for: language)
            // Text is added in English first. Text not yet translated is listed in untranslatedKeys
            // and shown in English meanwhile; when translating, translate them and then empty untranslatedKeys.
            let missing = keys.subtracting(table.keys).subtracting(AppText.untranslatedKeys)
            let extra = Set(table.keys).subtracting(keys)
            XCTAssertTrue(missing.isEmpty, "\(language.rawValue) is missing translations: \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "\(language.rawValue) has extra keys: \(extra.sorted())")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue) has an empty \(key)")
            }
        }
    }

    /// German says "this Mac's" one way everywhere, with the genitive's ending ("dieses Macs"): some sentences had it and some
    /// didn't
    func testGermanNamesThisMacOneWay() {
        let uses = Translations.table(for: .german).filter { $0.value.contains("dieses Mac") }
        XCTAssertGreaterThanOrEqual(uses.count, 6)
        for (key, value) in uses {
            XCTAssertNil(value.range(of: "dieses Mac(?!s)", options: .regularExpression), "\(key): \(value)")
        }
    }

    /// While it's English only: untranslated text must be registered, and other languages show the English original (never blanks or anything other than the key).
    func testUntranslatedKeysShowEnglish() {
        let untranslated = AppText.untranslatedKeys
        XCTAssertTrue(untranslated.isSubset(of: Set(AppText.allKeys)), "untranslatedKeys has keys that don't exist")
        let ja = AppText(language: .japanese)
        for key in untranslated where AppText.placeholderIndexes(in: key).isEmpty {
            XCTAssertEqual(ja.t(key), key)
        }
        // Once translated: Japanese shows Japanese, with arguments still filled in
        let jaText = ja.f("No trains in the next %@", "2 hr")
        XCTAssertNotEqual(jaText, "No trains in the next 2 hr")
        XCTAssertTrue(jaText.contains("2 hr"))
    }

    func testPlaceholdersMatchEnglish() {
        for language in AppLanguage.allCases where language != .english {
            for (key, value) in Translations.table(for: language) {
                XCTAssertEqual(AppText.placeholderIndexes(in: value), AppText.placeholderIndexes(in: key),
                               "\(language.rawValue): placeholders in \"\(value)\" don't match \"\(key)\"")
            }
        }
    }

    /// Text that quotes another piece of the UI (“My current location”, “Timetable”) quotes it exactly as that language shows it
    func testQuotedTextMatchesItsTranslation() throws {
        let keys = Set(AppText.allKeys)
        let quote = try NSRegularExpression(pattern: "\u{201C}([^\u{201D}]+)\u{201D}")
        var checked = 0
        for key in AppText.allKeys {
            let ns = key as NSString
            for match in quote.matches(in: key, range: NSRange(location: 0, length: ns.length)) {
                let quoted = ns.substring(with: match.range(at: 1))
                guard keys.contains(quoted) else { continue }
                checked += 1
                for language in AppLanguage.allCases where language != .english {
                    let table = Translations.table(for: language)
                    guard let value = table[key], let name = table[quoted] else { continue }
                    XCTAssertTrue(value.contains(name), "\(language.rawValue): \"\(key)\" doesn't quote its \"\(quoted)\" (\(name))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 3, "found too few quoted names; did the quote marks change?")
    }

    /// Numbers are written with 0-9 in every language, as the locales write them (see AppLanguage.locale), also inside sentences
    func testTranslationsUseLatinDigits() {
        for language in AppLanguage.allCases where language != .english {
            for (key, value) in Translations.table(for: language) {
                let digits = value.unicodeScalars.filter { !$0.isASCII && $0.properties.generalCategory == .decimalNumber }
                XCTAssertTrue(digits.isEmpty, "\(language.rawValue) writes digits other than 0-9 in \"\(key)\"")
            }
        }
    }

    /// Plan a Trip's star popover says how many places it lists, with the numbers in the sentence itself (no plural forms to
    /// work out in any language): they are the popover's limits, and every language writes both
    func testStarPopoverLineNamesItsLimits() {
        let key = "Up to \(PlaceLists.quickFavorites) favorites and the \(PlaceLists.quickRecents) most recent places are shown here. To change the order of favorites, drag them in All Places."
        XCTAssertTrue(AppText.allKeys.contains(key), "the sentence's numbers no longer match PlaceLists.quickFavorites and quickRecents")
        for language in AppLanguage.allCases where language != .english {
            let text = Translations.table(for: language)[key] ?? ""
            XCTAssertFalse(text.isEmpty, "\(language.rawValue): no translation")
            for number in ["\(PlaceLists.quickFavorites)", "\(PlaceLists.quickRecents)"] {
                XCTAssertTrue(text.contains(number), "\(language.rawValue): \(number) missing")
            }
        }
    }

    /// The legend at the top of How It Works has a sentence for every verdict, each a known key, no two alike, in every language
    func testEveryVerdictHasAMeaningForTheLegend() {
        let english = CatchVerdict.allCases.map { AppText().verdictMeaning($0) }
        XCTAssertEqual(Set(english).count, CatchVerdict.allCases.count, "two verdicts share a sentence")
        for text in english {
            XCTAssertTrue(AppText.allKeys.contains(text), "\"\(text)\" isn't a key")
        }
        for language in AppLanguage.allCases where language != .english {
            let l = AppText(language: language)
            let meanings = CatchVerdict.allCases.map { l.verdictMeaning($0) }
            XCTAssertEqual(Set(meanings).count, CatchVerdict.allCases.count, "\(language.rawValue): two verdicts share a sentence")
            for (meaning, key) in zip(meanings, english) {
                XCTAssertNotEqual(meaning, key, "\(language.rawValue): not translated: \(key)")
            }
        }
    }

    /// Settings paths go step by step with arrows ("Settings → Privacy and permissions"), never ">". Right-to-left languages
    /// use the left arrow between right-to-left names, but English names run left to right there too, so they take the right arrow.
    func testSettingsPathsUseArrows() throws {
        for key in AppText.allKeys {
            XCTAssertFalse(key.contains(" > "), "\"\(key)\" uses \">\" for a path")
        }
        let backArrow = try NSRegularExpression(pattern: Self.leftArrowBetweenEnglish)
        // ">" between quoted names: curly quotes, corner brackets, guillemets
        let separators = [" > ", "\u{201D}>\u{201C}", "\u{300D}>\u{300C}", "\u{BB} > \u{AB}"]
        for language in AppLanguage.allCases where language != .english {
            for (key, value) in Translations.table(for: language) {
                for separator in separators {
                    XCTAssertFalse(value.contains(separator), "\(language.rawValue) uses \">\" for a path in \"\(key)\"")
                }
                XCTAssertFalse(!language.isRightToLeft && value.contains("\u{2190}"), "\(language.rawValue) uses the left arrow in \"\(key)\"")
                XCTAssertNil(backArrow.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                             "\(language.rawValue) has a left arrow between English names in \"\(key)\"")
            }
        }
    }

    /// Languages macOS doesn't come in keep the Mac's own English names for System Settings and its panes, as the Mac shows them
    func testMacNamesStayEnglishWhereTheMacIsInEnglish() {
        for language in [AppLanguage.bengali, .urdu, .gujarati, .haitianCreole, .tagalog, .yiddish] {
            let table = Translations.table(for: language)
            for (key, value) in table where key.contains("System Settings") {
                XCTAssertTrue(value.contains("System Settings"), "\(language.rawValue): \"\(key)\" doesn't name System Settings")
            }
            XCTAssertTrue(table["Open Login Items Settings"]?.contains("Login Items") == true, language.rawValue)
            XCTAssertTrue(table["Open Location Settings"]?.contains("Location Services") == true, language.rawValue)
        }
    }

    /// One word for one thing: Hebrew says "the app" (\u{05D4}\u{05D9}\u{05D9}\u{05E9}\u{05D5}\u{05DD}) and "Keychain"
    /// (\u{05E6}\u{05E8}\u{05D5}\u{05E8} \u{05D4}\u{05DE}\u{05E4}\u{05EA}\u{05D7}\u{05D5}\u{05EA}) the same way everywhere,
    /// and Bengali spells Keychain one way (\u{0995}\u{09C0}\u{099A}\u{09C7}\u{0987}\u{09A8})
    func testTerminologyIsConsistent() {
        let he = Translations.table(for: .hebrew)
        XCTAssertTrue(he.values.contains { $0.contains("\u{05D4}\u{05D9}\u{05D9}\u{05E9}\u{05D5}\u{05DD}") })
        XCTAssertTrue(he.values.contains { $0.contains("\u{05E6}\u{05E8}\u{05D5}\u{05E8} \u{05D4}\u{05DE}\u{05E4}\u{05EA}\u{05D7}\u{05D5}\u{05EA}") })
        for (key, value) in he {
            XCTAssertFalse(value.contains("\u{05D0}\u{05E4}\u{05DC}\u{05D9}\u{05E7}\u{05E6}\u{05D9}"), "he uses another word for the app in \"\(key)\"")
            XCTAssertFalse(value.contains("\u{05DE}\u{05D7}\u{05D6}\u{05D9}\u{05E7}"), "he uses another word for Keychain in \"\(key)\"")
        }
        let bn = Translations.table(for: .bengali)
        XCTAssertTrue(bn.values.contains { $0.contains("\u{0995}\u{09C0}\u{099A}\u{09C7}\u{0987}\u{09A8}") })
        for (key, value) in bn {
            XCTAssertFalse(value.contains("\u{0995}\u{09BF}\u{099A}\u{09C7}\u{0987}\u{09A8}"), "bn spells Keychain another way in \"\(key)\"")
        }
    }

    /// A count goes where the language puts it: with its measure word in Chinese, before the noun in Vietnamese
    func testUnreachableSourceCountReadsNaturally() {
        let key = "Can't reach %@ data sources. Your network may be blocking them."
        XCTAssertTrue(AppText(language: .chineseSimplified).f(key, "3").contains("3 \u{4E2A}"))
        XCTAssertTrue(AppText(language: .vietnamese).f(key, "3").contains("\u{0111}\u{01B0}\u{1EE3}c 3 ngu"))
    }

    /// Every key used in the main app, widget and shared code must be in allKeys (otherwise other languages show English).
    func testKeysUsedInSourcesAreKnown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CatchTextTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CatchCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // project root
        let folders = ["App", "Widget", "Shared"].map { root.appendingPathComponent($0) }
            + [root.appendingPathComponent("Packages/CatchCore/Sources/CatchText")]
        let fm = FileManager.default
        guard fm.fileExists(atPath: folders[0].path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?:t|f)\(\s*"((?:[^"\\]|\\.)*)""#)
        let known = Set(AppText.allKeys)
        var used = Set<String>()
        for folder in folders {
            guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Translations/") {
                let source = try String(contentsOf: url, encoding: .utf8)
                let ns = source as NSString
                for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                    let key = ns.substring(with: match.range(at: 1))
                    used.insert(key)
                    XCTAssertTrue(known.contains(key), "\(url.lastPathComponent) uses unregistered text: \(key)")
                }
            }
        }
        // The names of the states, the metro areas and their regions are data (areas.json) and reach t(…) as values: no t("…")
        // call writes them out; nor the names of Demo mode's presets (AppText.demoPresets)
        let unused = known.subtracting(used).subtracting(AreaCatalog.shared.states.values)
            .subtracting(MetroArea.allCases.map(\.nameKey)).subtracting(MetroSubRegion.allCases.map(\.nameKey))
            .subtracting(DemoData.presets.map(\.name))
        XCTAssertTrue(unused.isEmpty, "allKeys has unused text: \(unused.sorted())")
    }

    /// Keys passed as values, not written out in a t("…") call (the scan above can't see them): every mode, region and metro area name,
    /// every kind of vehicle, every state an area is in (areas.json's "states": a new area in another state fails here until
    /// that state's name is registered, and then until every language has it), and the names of Demo mode's presets
    func testNameKeysPassedAsValuesAreKnown() {
        let known = Set(AppText.allKeys)
        let keys = TransitSystem.allCases.map(\.nameKey) + MetroSubRegion.allCases.map(\.nameKey) + MetroArea.allCases.map(\.nameKey)
            + VehicleKind.allCases.map(\.nameKey) + Array(AreaCatalog.shared.states.values) + DemoData.presets.map(\.name)
        for key in keys { XCTAssertTrue(known.contains(key), "Name key not registered: \(key)") }
        XCTAssertFalse(AreaCatalog.shared.states.isEmpty)
    }

    /// Demo mode's presets in every language: the demo's own, in its order, each named in that language as a preset may be
    /// named (CommutePresets.cleanName leaves it as it is) and none like another. After a change of language, those still
    /// named as Demo mode named them take the new names; one the user renamed keeps its name
    func testDemoPresetNames() {
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            let presets = l.demoPresets
            XCTAssertEqual(presets.map(\.id), DemoData.presets.map(\.id), language.rawValue)
            XCTAssertEqual(presets.map(\.mode), DemoData.presets.map(\.mode), language.rawValue)
            XCTAssertEqual(Set(presets.map(\.name)).count, presets.count, language.rawValue)
            for preset in presets {
                XCTAssertEqual(CommutePresets.cleanName(preset.name), preset.name, "\(language.rawValue): \(preset.name)")
                if language != .english {
                    XCTAssertNotNil(Translations.table(for: language)[DemoData.presets.first { $0.id == preset.id }!.name],
                                    "\(language.rawValue): \(preset.name)")
                }
            }
        }
        let english = AppText(language: .english)
        let german = AppText(language: .german)
        var mine = english.demoPresets
        mine[1].name = "Gym"
        let renamed = german.demoPresetsRenamed(mine, from: english)
        XCTAssertEqual(renamed.map(\.name), [german.demoPresets[0].name, "Gym", german.demoPresets[2].name])
        XCTAssertNotEqual(renamed[0].name, mine[0].name)
        XCTAssertEqual(english.demoPresetsRenamed(renamed, from: german).map(\.name), ["Work", "Gym", "Weekend"])
    }

    /// A sentence to translate doesn't name a metro area or an operator: their names come from the data (areas.json, the source
    /// list, each operator's own), so one that is added, stopped or taken away needs no new sentence and leaves none behind.
    /// The sentences that still name one are listed: the list only gets shorter (one no longer naming any fails until it's
    /// taken off). Keys that are a name themselves (a mode, a region, a state) aren't sentences
    func testSentencesDontNameAreasOrOperators() {
        var names = Set(MetroArea.allCases.map(\.nameKey))
        for credit in AreaCatalog.shared.operators.compactMap(\.credit) {
            // "MBTA (MassDOT)": the whole, and each name in it
            names.insert(credit)
            names.formUnion(credit.split(whereSeparator: { $0 == "(" || $0 == ")" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        // The short names too ("PATH", "SCT"), which name whose live times are shown
        names.formUnion(AreaCatalog.shared.operators.compactMap(\.short))
        names.formUnion(FerryFeed.Source.allCases.map(\.name))
        names.formUnion(RegionalBusFeed.all.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["MTA", "PATH", "NJ Transit", "Greater Boston"]))
        let nameKeys = names.union(MetroSubRegion.allCases.map(\.nameKey)).union(AreaCatalog.shared.states.values)
            .union(TransitSystem.allCases.map(\.nameKey)).union(VehicleKind.allCases.map(\.nameKey))
        func wordPart(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        func mentions(_ text: String, _ name: String) -> Bool {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: name, range: from..<text.endIndex) {
                let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
                let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
                if !wordPart(before), !wordPart(after) { return true }
                from = text.index(after: r.lowerBound)
            }
            return false
        }
        var naming: [String: [String]] = [:]
        for key in AppText.allKeys where !nameKeys.contains(key) {
            let found = names.filter { mentions(key, $0) }
            if !found.isEmpty { naming[key] = found.sorted() }
        }
        let listed = Self.sentencesNamingAreasOrOperators
        let new = Set(naming.keys).subtracting(listed).sorted()
        XCTAssertTrue(new.isEmpty, "Name these from the data instead: \(new.map { "\($0) (\(naming[$0, default: []].joined(separator: ", ")))" })")
        XCTAssertTrue(listed.subtracting(naming.keys).isEmpty, "No longer names one, take off the list: \(listed.subtracting(naming.keys).sorted())")
        XCTAssertLessThanOrEqual(listed.count, Self.sentencesNamingAreasOrOperatorsMost, "The list only gets shorter")
    }

    /// The sentences that still name an area or an operator (testSentencesDontNameAreasOrOperators)
    static let sentencesNamingAreasOrOperators: Set<String> = [
        "Account saved, but NJ Transit didn't accept it for buses. Using the timetable.",
        "Account saved, but NJ Transit didn't accept it.",
        "Account saved, but NJ Transit didn't accept it. Using the timetable.",
        "Add your free MTA Bus Time key in Settings to see live bus times.",
        "Bus times come from MTA Bus Time, which needs a free personal key. Getting one takes about two minutes.",
        "Cape May\u{2013}Lewes Ferry: timetable only. Only its Cape May terminal is in the area.",
        "Companies that run in more than one area, such as Amtrak. Kept while one of their areas is kept.",
        "Couldn't download the MTA timetable. Check your network.",
        "Couldn't get MTA Bus Time data. Check your network. Showing the last data received.",
        "Couldn't get MTA real-time data. Check your network. Showing the last data received.",
        "For MTA buses, only live times are available, so they appear only when you leave within the next 30 minutes.",
        "For PATH, only live times are available, so Plan a Trip works only when you leave within the next 30 minutes.",
        "Get a Free Key from MTA",
        "Key saved, but MTA Bus Time didn't accept it.",
        "Live NJ Transit times (trains and buses) need a free NJ Transit developer account. Sign up on NJ Transit's developer site and wait for the email saying your account is approved, then enter your username and password below. They're kept only in this Mac's Keychain. Without an account, NJ Transit times come from the timetable.",
        "Live bus times need a free key from MTA. It takes about two minutes: open the sign-up page, fill in your name and email, and MTA emails you the key. Paste it here. It's kept only in this Mac's Keychain.",
        "Live times need a free Suffolk County Transit key (above). Using the timetable for now.",
        "Live times need your free MTA Bus Time key (above).",
        "Live times need your free NJ Transit account (above). Using the timetable for now.",
        "Live times need your own free NJ Transit developer account. Using the timetable for now.",
        "Live times with your MTA Bus Time key (above).",
        "Live times with your NJ Transit account (above).",
        "Live times with your Suffolk County Transit key (above).",
        "MARC (Maryland): timetables and live times, free, no key. Only its Perryville station is in the area.",
        "MTA Bus Time didn't accept this key. Check that you copied all of it.",
        "MTA Bus Time didn't accept your key.",
        "MTA Bus Time didn't accept your key. Check it in Settings.",
        "MTA Bus Time key",
        "MTA buses (MTA Bus Time)",
        "MTA buses: live times from MTA Bus Time (free, needs your own key, entered in Settings and kept in this Mac's Keychain). The app asks only about the bus stops nearest you (up to 24), a few at a time and at most once a minute. Stops and the map come from MTA's GTFS data, built into the app and checked for updates on the 1st of each month. Bus types follow MTA: Local, Limited-Stop, Select Bus Service (SBS) and Express.",
        "MTA subway",
        "MTA subway and Staten Island Railway: live times from MTA's official real-time feeds (free, no key). The app downloads only the lines that stop near you, at the refresh interval you set. Stations, directions, the map and timetables come from MTA's GTFS data, built into the app and checked for updates on the 1st of each month.",
        "NJ Transit account",
        "NJ Transit buses",
        "NJ Transit didn't accept this username and password. Check that the username matches the one at the top right of NJ Transit's developer site, including capital letters. If you just signed up, wait for the approval email.",
        "NJ Transit didn't accept your account (above). Using the timetable for now.",
        "NJ Transit didn't accept your developer account, so NJ Transit times are from the timetable. Check it in Settings \u{2192} Data source.",
        "NJ Transit said: %@",
        "No PATH station is within a %@ walk. Choose another place, or a longer walk.",
        "No PATH station is within walking range. Choose another place, or widen the range in Settings.",
        "No live data for this time. Times are from the MTA timetable (valid until %@).",
        "No live data for this time. Times are from the MTA timetable.",
        "On the NYC Subway, whether a train is express or local comes from the live data: its next stops are compared with the MTA timetable, and a train that skips stations other trains stop at is express.",
        "PATH (Port Authority of New York and New Jersey): live times from the data used by the official PATH app (free, no key). It gives the next few trains at each station, so only those are shown, and Plan a Trip works only for the next 30 minutes. PATH publishes no current timetable, so stations, lines and the map come from its last public timetable, downloaded on this Mac and checked for updates on the 1st of each month.",
        "PATH, light rail: open the app to update",
        "Plan a Trip uses live data where available when you leave within the next 30 minutes, for the whole time range, and timetables only when you leave later. Its NJ Transit light rail and PATCO times always come from the timetable.",
        "Roosevelt Island Tram (RIOC)",
        "Roosevelt Island Tram (RIOC): RIOC publishes no live data or exact timetable, only its hours and how often it runs (every 7.5 min at weekday rush hours, every 15 min otherwise). The app works out departures from these, so tram times are estimates marked \u{201C}Timetable\u{201D}. The hours are checked on the 1st of each month.",
        "Sign Up on NJ Transit's Developer Site",
        "Statue of Liberty ferry (National Park Service): timetable only, published one season at a time. Between seasons its piers are hidden.",
        "Suffolk County Transit key",
        "Suffolk County Transit: timetables, free. Live times with your own free key from Swiftly, which runs Suffolk's live data; you ask for it with Swiftly's request form, and Swiftly reviews each request.",
        "Suffolk's live bus times come from Swiftly. Ask Swiftly for a free key with the request form: choose Suffolk County Transit and GTFS-Realtime Trip Updates. Swiftly reviews each request and emails the key. Paste it here. It's kept only in this Mac's Keychain.",
        "Swiftly didn't accept your Suffolk County Transit key, so Suffolk times are from the timetable. Check it in Settings \u{2192} Data source.",
        "The MTA Bus Time key above wasn't accepted, so there are no MTA bus times for now.",
        "The MTA timetable doesn't cover that date yet.",
        "The subway stations, subway map and MTA bus stops that come with the app are made from MTA open data; the stations without times come from public federal and Port Authority data. Everything else is downloaded from each operator's public data, some of it through %1$@. Operators in this area (%2$@): %3$@. Every area's operators are listed in Settings \u{2192} Data source. This data belongs to those operators and is used under their terms.",
        "Times are from the timetable. For live NJ Transit times, add your NJ Transit developer account in Settings \u{2192} Data source.",
        "Times are from the timetable. For live Suffolk County Transit times, add your own Swiftly key in Settings \u{2192} Data source.",
        "Turn the app on to download the MTA timetable.",
        "Turn the app on to get PATH live times.",
        "Type your username exactly as NJ Transit shows it at the top right of its developer site, including capital letters.",
        "Updated with the latest MTA data.",
        "Uses your NJ Transit account (above). Live where NJ Transit provides it, otherwise the timetable.",
        "Walk time is the Apple Maps walking route from your starting point to the station, divided by your walking speed, plus time from the entrance to the platform: 1.5 min for the subway, PATH and light rail, 2 min for trains, 1 min for ferries, the tram and buses outside MTA, none at MTA bus stops, and 30 min for the Statue of Liberty ferry's security check. Without a route, the straight-line distance \u{D7} 1.25 is used and marked \u{201C}estimated\u{201D}.",
        "Worked out from RIOC's hours and intervals",
        "Your account works only on NJ Transit's test system. Ask NJ Transit to turn on live data access for your account.",
        "Your location is used to work out walk times. It's sent only to Apple Maps, for walking routes and place names, and to no one else, unless you choose Google Maps for Directions. The transit data downloads don't include your location, though MTA Bus Time does see which nearby bus stops the app asks about. Nearby stations and walking times are kept on this Mac so the widget can show them, and the places you choose are saved only on this Mac.",
    ]
    /// How many there were; lowered as they're fixed, never raised
    static let sentencesNamingAreasOrOperatorsMost = 68

    /// The full list of areas finds an area by its names in the app's language and in English, whatever the case and the accents,
    /// and New York the state doesn't read as the city where the two would
    func testAreaSearchFindsTranslatedAndEnglishNames() {
        let de = AppText(language: .german), zh = AppText(language: .chineseSimplified), es = AppText(language: .spanish)
        func found(_ search: String, _ l: AppText) -> [MetroArea] {
            MetroArea.allCases.filter { AreaList.matches(search, names: $0.searchNames(l.t)) }
        }
        XCTAssertEqual(found("gro\u{DF}raum bos", de), [.greaterBoston])
        XCTAssertEqual(found("GREATER BOS", de), [.greaterBoston], "English too")
        XCTAssertEqual(found("\u{7EBD}\u{7EA6}\u{5DDE}", zh), [.newYork])
        XCTAssertEqual(found("\u{65B0}\u{6CFD}\u{897F}", zh), [.newYork, .philadelphia, .lehighValley])
        XCTAssertEqual(found("new jersey", zh), [.newYork, .philadelphia, .lehighValley])
        // The Spanish name starts with an accented letter: found without the accent
        XCTAssertTrue(es.t(MetroArea.philadelphia.nameKey).hasPrefix("\u{C1}rea"))
        XCTAssertEqual(found("area metropolitana de fil", es), [.philadelphia])
        XCTAssertEqual(found("pensilvania", es), [.newYork, .philadelphia, .lehighValley])
        for language in AppLanguage.allCases where language != .english {
            let l = AppText(language: language)
            XCTAssertNotEqual(l.t("New York"), l.t("New York City"), language.rawValue)
            for area in MetroArea.allCases {
                XCTAssertTrue(AreaList.matches(l.t(area.nameKey), names: area.searchNames(l.t)), "\(language.rawValue) \(area.rawValue)")
            }
        }
    }

    /// "On" is translated as "running" (the app is started, until standby; AppText.activityStatus). Anything else that is
    /// switched on or allowed says so in its own words ("Allowed"), so the app, widget and shared code never use t("On").
    func testOnIsOnlyTheActivityStatus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["App", "Widget", "Shared"].map { root.appendingPathComponent($0) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folders[0].path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])t\(\s*"On"\s*\)"#)
        var checked = 0
        for folder in folders {
            guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                checked += 1
                XCTAssertNil(regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)),
                             "\(url.lastPathComponent) uses t(\"On\"), which means the app is running")
            }
        }
        XCTAssertGreaterThan(checked, 10, "found too few files; is the project root right?")
    }

    /// Every repository file is English only. Only the translation data
    /// (Resources/translations, language_names.json, language_names_extra.json and date_names.json) and the tests' names.json may
    /// hold other languages; tests write
    /// non-English sample text as \u{...} escapes. Symbols and punctuation are allowed; letters, marks,
    /// digits and emoji outside ASCII are not. README.md's language
    /// table, between the "native-language-names:start" and "native-language-names:end" markers, lists each
    /// language's own name and is skipped too.
    func testRepositoryFilesAreEnglishOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("App").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let skippedFolders: Set<String> = [".build", "build", ".git", ".swiftpm", "xcuserdata", "translations"]
        let skippedFiles: Set<String> = ["language_names.json", "language_names_extra.json", "date_names.json", "names.json"]
        let textExtensions: Set<String> = ["swift", "py", "md", "yml", "yaml", "json", "plist", "entitlements", "xcprivacy",
                                           "xcscheme", "pbxproj", "xcworkspacedata", "xcconfig", "psv", "csv", "svg", "mjs", "js", "sh", "txt", "html", ""]
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var checked = 0
        for case let url as URL in files {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(name) { files.skipDescendants() }
                continue
            }
            // Local.xcconfig.example is read as the xcconfig it stands for
            let ext = name.hasSuffix(".xcconfig.example") ? "xcconfig" : url.pathExtension
            guard textExtensions.contains(ext), !skippedFiles.contains(name),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let isReadme = name == "README.md"
            var inNameTable = false
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if isReadme, line.contains("<!-- native-language-names:start -->") { inNameTable = true }
                if isReadme, line.contains("<!-- native-language-names:end -->") { inNameTable = false; continue }
                if inNameTable { continue }
                let bad = line.unicodeScalars.filter { !$0.isASCII && Self.isWriting($0) }
                XCTAssertTrue(bad.isEmpty, "\(url.path.replacingOccurrences(of: root.path + "/", with: "")):\(number + 1) has non-English text: \(String(String.UnicodeScalarView(bad)))")
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few files; is the project root right?")
    }

    /// A character that belongs to some language's writing (a letter, combining mark or digit), or an emoji.
    static func isWriting(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber:
            return true
        default:
            return u.properties.isEmojiPresentation
        }
    }

    // MARK: Names

    /// One entry of Tests/names.json: how a name in the app's text is written in each language
    struct NameEntry: Decodable {
        /// The name as the English text writes it
        let en: String
        /// "keep": as in English in every language; "official": the maker's own name in each language; "place": the name most
        /// used in each language (its Wikipedia article's title), or English where there is none
        let kind: String
        /// The place's Wikidata item, where its name in each language was looked up
        let wikidata: String?
        /// "official" and "place": each language's forms of the name (more than one where the grammar changes it)
        let names: [String: [String]]?
        /// Parts of English sentences where the name is text to type and stays in English
        let typed: [String]?
    }

    private struct NameList: Decodable {
        let names: [NameEntry]
    }

    /// Tests/names.json, beside the test folders (not a resource: it is only read here)
    private func nameList() throws -> [NameEntry] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("names.json")
        return try JSONDecoder().decode(NameList.self, from: Data(contentsOf: url)).names
    }

    private var translatedLanguages: [AppLanguage] { AppLanguage.allCases.filter { $0 != .english } }

    /// Whether the text has the name as a whole, not as part of a longer word (an English letter right before or after it)
    static func hasName(_ text: String, _ name: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: name, range: start..<text.endIndex) {
            let isLetter: (Character?) -> Bool = { $0.map { $0.isASCII && $0.isLetter } ?? false }
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isLetter(before) && !isLetter(after) { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    /// Whether the text holds the part, compared Unicode scalar by scalar, not character by character: a name with an ending
    /// joined to it is found too (Bengali joins a vowel sign to the last letter of Manhattan for "Manhattan's", which makes that
    /// letter and the sign one character, so a search by characters misses the name there)
    static func holds(_ text: String, _ part: String, ignoringCase: Bool = false) -> Bool {
        let whole = Array((ignoringCase ? text.lowercased() : text).unicodeScalars)
        let sought = Array((ignoringCase ? part.lowercased() : part).unicodeScalars)
        guard !sought.isEmpty else { return true }
        guard sought.count <= whole.count else { return false }
        return (0...(whole.count - sought.count)).contains { whole[$0..<$0 + sought.count].elementsEqual(sought) }
    }

    /// Every official and place name has a form in every language the app has, and none for a language it no longer has: a
    /// language added or taken away shows up here until names.json follows
    func testEveryListedNameHasEveryLanguage() throws {
        let entries = try nameList()
        let languages = Set(translatedLanguages.map(\.rawValue))
        XCTAssertEqual(Set(entries.map(\.en)).count, entries.count, "a name is listed twice in names.json")
        for entry in entries {
            XCTAssertTrue(["keep", "official", "place"].contains(entry.kind), "\(entry.en): unknown kind \(entry.kind)")
            guard entry.kind != "keep" else {
                XCTAssertNil(entry.names, "\(entry.en) is kept in English, so it lists no names")
                continue
            }
            let have = Set((entry.names ?? [:]).keys)
            XCTAssertTrue(languages.subtracting(have).isEmpty,
                          "\(entry.en) has no name for \(languages.subtracting(have).sorted()): add it (English where the language has none)")
            XCTAssertTrue(have.subtracting(languages).isEmpty,
                          "\(entry.en) still lists \(have.subtracting(languages).sorted()), which the app no longer has")
            for (language, forms) in entry.names ?? [:] {
                XCTAssertFalse(forms.isEmpty, "\(entry.en): \(language) has no form")
                XCTAssertFalse(forms.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(entry.en): \(language) has an empty form")
            }
        }
    }

    /// Every translation writes each listed name the way names.json says: kept names as in English, the others in one of the
    /// language's listed forms. A name translated in one sentence and kept in English in another fails here
    func testTranslationsWriteNamesAsTheListSays() throws {
        let entries = try nameList()
        let tables = Dictionary(uniqueKeysWithValues: translatedLanguages.map { ($0, Translations.table(for: $0)) })
        for entry in entries {
            // A longer listed name that holds this one is checked as itself ("Northern New Jersey", "New York, NY")
            let longer = entries.map(\.en).filter { $0 != entry.en && $0.contains(entry.en) }
            var used = 0
            for key in AppText.allKeys {
                let own = longer.reduce(key) { $0.replacingOccurrences(of: $1, with: " ") }
                guard Self.hasName(own, entry.en) else { continue }
                used += 1
                let typed = (entry.typed ?? []).contains { key.contains($0) }
                for language in translatedLanguages {
                    guard let text = tables[language]?[key] else { continue }
                    let written: Bool
                    if entry.kind == "keep" || typed {
                        // German joins a name into a compound with hyphens ("NJ-Transit-Konto")
                        written = Self.holds(text, entry.en) || Self.holds(text, entry.en.replacingOccurrences(of: " ", with: "-"))
                    } else {
                        let forms = entry.names?[language.rawValue] ?? []
                        written = forms.contains { Self.holds(text, $0, ignoringCase: true) }
                    }
                    XCTAssertTrue(written, "\(language.rawValue): \"\(key)\" doesn't write \(entry.en) as names.json says")
                }
            }
            XCTAssertGreaterThan(used, 0, "\(entry.en): no text uses it any more, so it comes off names.json")
        }
    }

    func testNameCheckFindsWholeNamesOnly() {
        XCTAssertTrue(Self.hasName("Only its Perryville station is in range.", "Perryville"))
        XCTAssertTrue(Self.hasName("PATH (Port Authority)", "PATH"))
        XCTAssertFalse(Self.hasName("No path here", "PATH"))
        XCTAssertFalse(Self.hasName("MTAs", "MTA"))
        XCTAssertTrue(Self.hasName("NJ Transit's site", "NJ Transit"))
        // A name with an ending joined to its last letter: Bengali "Manhattan's" holds "Manhattan"
        let manhattan = "\u{09AE}\u{09CD}\u{09AF}\u{09BE}\u{09A8}\u{09B9}\u{09BE}\u{099F}\u{09A8}"
        XCTAssertTrue(Self.holds(manhattan + "\u{09C7}\u{09B0}", manhattan, ignoringCase: true))
        XCTAssertTrue(Self.holds("La statue de la Libert\u{E9}", "Statue de la Libert\u{E9}", ignoringCase: true))
        XCTAssertFalse(Self.holds("Statue of Liberty", "statue of Liberty"))
        XCTAssertFalse(Self.holds("Liberty", "Libert\u{E9}", ignoringCase: true))
    }

    // MARK: Argument filling

    func testFillSequentialAndPositional() {
        XCTAssertEqual(AppText.fill("in %@ min", ["6"]), "in 6 min")
        XCTAssertEqual(AppText.fill("%2$@ / %1$@", ["a", "b"]), "b / a")
        XCTAssertEqual(AppText.fill("100%% %@", ["x"]), "100% x")
        XCTAssertEqual(AppText.fill("%3$@", ["a"]), "", "doesn't crash with missing arguments")
        XCTAssertEqual(AppText.fill("%1$@", []), "", "doesn't crash with no arguments")
        // An argument that ends with a period (Russian and Ukrainian dates, an abbreviation) at the end of a sentence: one period
        XCTAssertEqual(AppText.fill("Not working since %@.", ["Oct. 30, 2026 y."]), "Not working since Oct. 30, 2026 y.")
        XCTAssertEqual(AppText.fill("%1$@. Next: %2$@.", ["Main St.", "Oct 31"]), "Main St. Next: Oct 31.")
        XCTAssertEqual(AppText.fill("%@.", ["\u{2068}y.\u{2069}"]), "\u{2068}y.\u{2069}", "an isolated argument too")
        XCTAssertEqual(AppText.fill("%@...", ["a."]), "a...", "only the one period right after it")
        XCTAssertEqual(AppText.fill("%@ .", ["a."]), "a. .")
        // The two sentences it was seen in, with the system's own dates
        let day = Date(timeIntervalSince1970: 1_793_400_000)
        for language in [AppLanguage.russian, .ukrainian] {
            let l = AppText(language: language)
            for text in [l.f("Not working since %@.", l.day(day)),
                         l.f("Not used since %@. Removed on %@ unless you use it again.", l.day(day), l.day(day.addingTimeInterval(30 * 86_400)))] {
                XCTAssertFalse(text.contains(".."), "\(language.rawValue): \(text)")
            }
        }
        XCTAssertEqual(AppText.placeholderIndexes(in: "%2$@ %1$@"), [1, 2])
        XCTAssertEqual(AppText.placeholderIndexes(in: "%@ and %@"), [1, 2])
    }

    /// Chinese writes a space between a word and a number, none between two words: a span of time put into a sentence doesn't bring one
    func testChineseHasNoSpaceBetweenTwoWords() {
        let zh = AppText(language: .chineseSimplified)
        XCTAssertEqual(zh.toSpare(180), "\u{5BCC}\u{4F59} 3 \u{5206}\u{949F}")
        XCTAssertEqual(zh.toSpare(30), "\u{5BCC}\u{4F59}\u{4E0D}\u{5230} 1 \u{5206}\u{949F}")
        XCTAssertEqual(zh.f("Spare time: %1$@ (needs %2$@)", zh.slack(30), zh.minutes(120)), "\u{5BCC}\u{4F59}\u{4E0D}\u{5230} 1 \u{5206}\u{949F}\u{FF08}\u{81F3}\u{5C11}\u{9700}\u{8981} 2 \u{5206}\u{949F}\u{FF09}")
        XCTAssertEqual(zh.f("Spare time: %1$@ (needs %2$@)", zh.slack(200), zh.minutes(120)), "\u{5BCC}\u{4F59} +3 \u{5206}\u{949F}\u{FF08}\u{81F3}\u{5C11}\u{9700}\u{8981} 2 \u{5206}\u{949F}\u{FF09}")
        XCTAssertEqual(zh.f("Within %@", zh.duration(7200)), "2 \u{5C0F}\u{65F6}\u{5185}")
        XCTAssertEqual(zh.f("Goes back to standby after %@.", zh.minutes(1800)), "30 \u{5206}\u{949F}\u{540E}\u{81EA}\u{52A8}\u{56DE}\u{5230}\u{5F85}\u{673A}\u{3002}")
        let both = [AppLanguage.chineseSimplified, .chineseTraditional].map { AppText(language: $0) }
        for l in both {
            var lines = [l.toSpare(30), l.toSpare(180), l.f("%1$@, %2$@ to spare", l.verdict(.tight), l.spare(30)),
                         l.f("%1$@, %2$@ to spare", l.verdict(.canTry), l.spare(240)),
                         l.f("Spare time: %1$@ (needs %2$@)", l.slack(30), l.minutes(120)),
                         l.f("Goes back to standby after %@.", l.minutes(1800))]
            for seconds in [600.0, 1800, 3600, 5400, 7200] {
                let d = l.duration(seconds)
                lines += ["Within %@", "Trains in the next %@", "Buses in the next %@", "Ferries in the next %@", "No trains in the next %@",
                          "No buses in the next %@", "No ferries in the next %@", "No trains in the %@ after you leave",
                          "No buses in the %@ after you leave", "No ferries in the %@ after you leave"].map { l.f($0, d) }
            }
            for line in lines {
                let c = Array(line)
                let stray = c.indices.dropFirst().dropLast().contains { c[$0] == " " && AppText.isHan(c[$0 - 1]) && AppText.isHan(c[$0 + 1]) }
                XCTAssertFalse(stray, "\(l.language.rawValue): \(line)")
            }
        }
        // Only where a span of time goes in: the space in front of a clock time that starts with a word stays
        let afternoon = "\u{4E0B}\u{5348}8:14"
        XCTAssertTrue(zh.f("Leave by %@", afternoon).contains(" " + afternoon + " "))
        // The rule by itself, and switched off
        XCTAssertEqual(AppText.fill("\u{5BCC}\u{4F59} %@", ["\u{4E0D}\u{5230} 1"], closingUp: true), "\u{5BCC}\u{4F59}\u{4E0D}\u{5230} 1")
        XCTAssertEqual(AppText.fill("\u{5BCC}\u{4F59} %@", ["3"], closingUp: true), "\u{5BCC}\u{4F59} 3")
        XCTAssertEqual(AppText.fill("\u{5BCC}\u{4F59} %@", ["\u{4E0D}\u{5230} 1"]), "\u{5BCC}\u{4F59} \u{4E0D}\u{5230} 1")
        XCTAssertEqual(AppText.fill("a %@", ["\u{4E0D}\u{5230}"], closingUp: true), "a \u{4E0D}\u{5230}")
        // Other languages read as before
        XCTAssertEqual(AppText(language: .english).toSpare(30), "under 1 min to spare")
        XCTAssertEqual(AppText(language: .english).f("Within %@", "2 hr"), "Within 2 hr")
    }

    func testTranslatedTemplates() {
        let ja = AppText(language: .japanese)
        XCTAssertEqual(ja.f("To %@", "Woodlawn"), "Woodlawn\u{884C}\u{304D}")
        let zh = AppText(language: .chineseSimplified)
        XCTAssertEqual(zh.countdown(360), "6 \u{5206}\u{949F}\u{540E}")
        XCTAssertEqual(zh.verdict(.canTry), "\u{53EF}\u{4EE5}\u{8BD5}\u{8BD5}")
        let es = AppText(language: .spanish)
        XCTAssertEqual(es.verdict(.tight), "Ajustado")
    }

    // MARK: Time and distance (English)

    func testDurationUsesHoursFromOneHour() {
        let l = AppText()
        XCTAssertEqual(l.duration(30 * 60), "30 min")
        XCTAssertEqual(l.duration(60 * 60), "1 hr")
        XCTAssertEqual(l.duration(90 * 60), "1.5 hr")
        XCTAssertEqual(l.duration(120 * 60), "2 hr")
    }

    func testEnglishMinutesAndCountdown() {
        let l = AppText()
        XCTAssertEqual(l.minutes(61), "2 min")
        XCTAssertEqual(l.minutes(840), "14 min")
        XCTAssertEqual(l.countdown(nil), "No data")
        XCTAssertEqual(l.countdown(29), "Arriving now")
        XCTAssertEqual(l.countdown(360), "in 6 min")
        // The short form, for where the full one doesn't fit: the same minutes, never rounded another way
        XCTAssertNil(l.shortCountdown(nil))
        XCTAssertEqual(l.shortCountdown(-45), "Now")
        XCTAssertEqual(l.shortCountdown(29), "Now")
        XCTAssertEqual(l.shortCountdown(60), "1 min")
        XCTAssertEqual(l.shortCountdown(419), "6 min")
        for seconds in stride(from: 60.0, through: 900, by: 37) {
            XCTAssertEqual(l.countdown(seconds), "in " + (l.shortCountdown(seconds) ?? ""), "\(seconds)")
        }
        XCTAssertEqual(l.slack(200), "+3 min")
        XCTAssertEqual(l.slack(-20), "−1 min")
    }

    func testClockTime() {
        let l = AppText()
        let date = Date(timeIntervalSince1970: 20 * 3600 + 14 * 60)  // 1970-01-01 20:14 UTC
        let utc = TimeZone(identifier: "UTC")!
        let text = l.time(date, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(text, "8:14 PM")
        let de = AppText(language: .german, clock: .twentyFourHour).time(date, timeZone: utc)
        XCTAssertEqual(de, "20:14")
        // 12/24-hour clock follows the setting, not the language
        let h24 = AppText(clock: .twentyFourHour)
        XCTAssertEqual(h24.time(date, timeZone: utc), "20:14")
        XCTAssertEqual(h24.timeWithSeconds(date.addingTimeInterval(5), timeZone: utc), "20:14:05")
        XCTAssertEqual(l.timeWithSeconds(date.addingTimeInterval(5), timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " "), "8:14:05 PM")
        // Whether ", " or " at " goes between date and time depends on the OS version; only check that both parts are there
        let both = h24.dayAndTime(date, timeZone: utc)
        XCTAssertTrue(both.hasPrefix("Jan 1, 1970") && both.hasSuffix("20:14"), both)
        XCTAssertEqual(h24.day(date, timeZone: utc).replacingOccurrences(of: "\u{2060}", with: ""), "Jan 1, 1970")
    }

    /// Times and dates are in the place's metro area's time zone wherever the Mac's clock is set (the timetables and the day math
    /// count in it). A clock time names its zone only when the Mac's clock reads differently; the current time always does in an area,
    /// in the language's own form
    func testTimesAndDatesAreTheAreasTime() throws {
        let newYork = MetroArea.newYork.timeZone
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let detroit = try XCTUnwrap(TimeZone(identifier: "America/Detroit"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let sydney = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        // 11:30 PM on October 31 in New York: 8:30 PM in Los Angeles, already November 1 in UTC, Tokyo and Sydney
        let late = Date(timeIntervalSince1970: 1_793_503_800)
        let winter = late.addingTimeInterval(7 * 86400)

        // In a New York area on a Mac set to New York: as before, only the current time names the zone
        let home = AppText(clock: .twentyFourHour, timeZone: newYork, timeZoneIsArea: true, macTimeZone: newYork)
        XCTAssertEqual(home.time(late), "23:30")
        XCTAssertEqual(home.timeWithSeconds(late), "23:30:00")
        XCTAssertEqual(home.day(late).replacingOccurrences(of: "\u{2060}", with: ""), "Oct 31, 2026")
        XCTAssertTrue(home.dayAndTime(late).hasPrefix("Oct 31, 2026") && home.dayAndTime(late).hasSuffix("23:30"), home.dayAndTime(late))
        XCTAssertEqual(home.currentTime(late), "23:30 EDT")
        XCTAssertEqual(home.currentTime(winter), "22:30 EST", "after the clocks go back: standard time")
        XCTAssertNil(home.timeZoneNote(at: late, areaName: "New York"))
        XCTAssertEqual(home.countdown(360), AppText(clock: .twentyFourHour).countdown(360))
        for language in AppLanguage.allCases {
            let text = AppText(language: language, clock: .twentyFourHour, timeZone: newYork, timeZoneIsArea: true, macTimeZone: newYork)
            XCTAssertNotEqual(text.currentTime(late), text.time(late), "\(language.rawValue): the zone is named")
        }

        // The same area on a Mac set to Los Angeles: the same times and days, each clock time naming its zone, and the line above
        var awayMac = home
        awayMac.macTimeZone = losAngeles
        XCTAssertEqual(awayMac.time(late), "23:30 EDT")
        XCTAssertEqual(awayMac.time(winter), "22:30 EST")
        XCTAssertEqual(awayMac.timeWithSeconds(late), "23:30:00 EDT")
        XCTAssertEqual(awayMac.day(late), home.day(late), "a day names no zone")
        XCTAssertTrue(awayMac.dayAndTime(late).hasPrefix("Oct 31, 2026") && awayMac.dayAndTime(late).hasSuffix("23:30 EDT"),
                      awayMac.dayAndTime(late))
        XCTAssertEqual(awayMac.currentTime(late), "23:30 EDT")
        XCTAssertEqual(awayMac.leaveBy(at: late).replacingOccurrences(of: "\u{2060}", with: ""), "Leave by 23:30 EDT", "kept on one line")
        XCTAssertEqual(awayMac.timeZoneNote(at: late, areaName: "New York"),
                       "Times here are local time in New York (EDT), not this Mac's time zone.")
        XCTAssertEqual(awayMac.countdown(360), home.countdown(360), "a countdown is the same anywhere")
        // A station whose departures are in its own zone (Arrival.timeZone): named when that reads differently, even on a New York Mac
        XCTAssertEqual(home.time(late, timeZone: losAngeles), "20:30 PDT")
        XCTAssertEqual(home.time(late, timeZone: detroit), "23:30")

        // A Mac set to another zone that keeps the same time (Detroit) sees nothing named
        var detroitMac = home
        detroitMac.macTimeZone = detroit
        XCTAssertEqual(detroitMac.time(late), "23:30")
        XCTAssertNil(detroitMac.timeZoneNote(at: late, areaName: "New York"))

        // Outside the service area: the Mac's own time, not named, no line
        let outside = AppText(clock: .twentyFourHour, timeZone: losAngeles, timeZoneIsArea: false, macTimeZone: losAngeles)
        XCTAssertEqual(outside.currentTime(late), "20:30")
        XCTAssertEqual(outside.day(late), home.day(late))
        XCTAssertNil(outside.timeZoneNote(at: late, areaName: nil))
        // ... unless where you are is known to keep another time than the Mac's: that time, named, and the other line
        let elsewhere = outside.inTimeZone(newYork, area: false)
        XCTAssertEqual(elsewhere.currentTime(late), "23:30 EDT")
        XCTAssertEqual(elsewhere.timeZoneNote(at: late, areaName: nil),
                       "This Mac's clock is set to a different time zone than where you are.")
        XCTAssertEqual(elsewhere.timeZoneNote(at: late, areaName: "New York"),
                       "This Mac's clock is set to a different time zone than where you are.", "not an area's time")

        // An area in another zone, on a New York Mac: Tokyo keeps one time all year, Sydney is in summer time in November
        for (zone, clock, day) in [(tokyo, "12:30", "Nov 1, 2026"), (sydney, "14:30", "Nov 1, 2026")] {
            let area = home.inTimeZone(zone, area: true)
            let which = zone.identifier
            XCTAssertTrue(area.time(late).hasPrefix(clock + " "), "\(which): \(area.time(late))")
            XCTAssertEqual(area.time(late), clock + " " + area.zoneName(at: late), which)
            XCTAssertEqual(area.day(late).replacingOccurrences(of: "\u{2060}", with: ""), day, which)
            XCTAssertEqual(area.currentTime(late), area.time(late), which)
            XCTAssertNotNil(area.timeZoneNote(at: late, areaName: "Test"), which)
            // The same area on a Mac set to its own zone names nothing but the current time
            var there = area
            there.macTimeZone = zone
            XCTAssertEqual(there.time(late), clock, which)
            XCTAssertNil(there.timeZoneNote(at: late, areaName: "Test"), which)
        }
        // Sydney's clocks go back on April 4, 2027, while New York's stay: 1:30 AM New York time is 4:30 PM there on April 2 and
        // 3:30 PM a week later
        let april = Date(timeIntervalSince1970: 1_806_643_800)
        XCTAssertEqual(home.inTimeZone(sydney, area: true).time(april, timeZone: sydney).prefix(5), "16:30")
        XCTAssertEqual(home.inTimeZone(sydney, area: true).time(april.addingTimeInterval(7 * 86400), timeZone: sydney).prefix(5), "15:30")

        // Text not shown on this Mac's screen (no Mac zone to compare): only the current time in an area names its zone
        let unshown = AppText(clock: .twentyFourHour, timeZone: tokyo, timeZoneIsArea: true)
        XCTAssertEqual(unshown.time(late), "12:30")
        XCTAssertNil(unshown.timeZoneNote(at: late, areaName: "Test"))
        XCTAssertNotEqual(unshown.currentTime(late), "12:30")
    }

    /// Plan a Trip's time picker: the columns read like the language's clock time (AppText.time) and follow the 12 / 24-hour setting
    func testTimeColumnsFollowTheClockAndLanguage() {
        let en = TimeColumns(text: AppText())
        XCTAssertEqual(en.kinds, [.hour, .minute, .period])
        XCTAssertEqual(en.cells(.hour).map(\.text), ["12"] + (1...11).map(String.init))
        XCTAssertEqual(en.cells(.minute).map(\.text).prefix(3), ["00", "01", "02"])
        XCTAssertEqual(en.cells(.minute).count, 60, "one cell a minute")
        XCTAssertEqual(en.cells(.period).map(\.text), ["AM", "PM"])
        XCTAssertEqual(en.name(.hour, text: AppText()), "Hour")
        XCTAssertEqual(en.name(.period, text: AppText()), "AM/PM")

        let h24 = TimeColumns(text: AppText(clock: .twentyFourHour))
        XCTAssertEqual(h24.kinds, [.hour, .minute], "no AM/PM on a 24-hour clock")
        XCTAssertEqual(h24.cells(.hour).map(\.text), (0...23).map { $0 < 10 ? "0\($0)" : "\($0)" })
        XCTAssertTrue(h24.cells(.period).isEmpty)

        // AM/PM comes first where the language writes it first; Japanese counts the half day's hours 0–11
        XCTAssertEqual(TimeColumns(text: AppText(language: .chineseSimplified)).kinds, [.period, .hour, .minute])
        XCTAssertEqual(TimeColumns(text: AppText(language: .chineseSimplified)).cells(.period).map(\.text), ["\u{4E0A}\u{5348}", "\u{4E0B}\u{5348}"])
        XCTAssertEqual(TimeColumns(text: AppText(language: .korean)).kinds, [.period, .hour, .minute])
        let ja = TimeColumns(text: AppText(language: .japanese))
        XCTAssertEqual(ja.kinds, [.period, .hour, .minute])
        XCTAssertEqual(ja.cells(.hour).map(\.text), (0...11).map(String.init))
        // Right-to-left languages keep the reading order; the layout mirrors it
        XCTAssertEqual(TimeColumns(text: AppText(language: .arabic)).kinds, [.hour, .minute, .period])

        for language in AppLanguage.allCases {
            for clock in ClockStyle.allCases {
                let text = AppText(language: language, clock: clock)
                let columns = TimeColumns(text: text)
                let which = "\(language.rawValue) \(clock.rawValue)"
                XCTAssertEqual(columns.kinds.count, clock == .twelveHour ? 3 : 2, which)
                XCTAssertEqual(columns.cells(.hour).count, clock == .twelveHour ? 12 : 24, which)
                for kind in [TimeColumns.Kind.hour, .minute] {
                    XCTAssertTrue(columns.cells(kind).allSatisfy { !$0.text.isEmpty && $0.text.allSatisfy { "0123456789".contains($0) } },
                                  "\(which): digits 0–9")
                    XCTAssertEqual(Set(columns.cells(kind).map(\.text)).count, columns.cells(kind).count, which)
                }
                if clock == .twelveHour {
                    let periods = columns.cells(.period).map(\.text)
                    XCTAssertEqual(periods.count, 2, which)
                    XCTAssertTrue(periods.allSatisfy { !$0.isEmpty } && periods[0] != periods[1], "\(which): \(periods)")
                }
                for kind in columns.kinds { XCTAssertFalse(columns.name(kind, text: text).isEmpty, which) }
            }
        }
    }

    /// Picking a cell changes only that part of the time, on the same day in the place's time zone; the arrow keys stop at the first
    /// and last cell
    func testTimeColumnsPickInThePlacesTime() throws {
        let calendar = Timetable.calendar(in: Timetable.timeZone)
        func ny(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11, year: Int = 2026) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        let evening = try ny(7, 20, 14).addingTimeInterval(25)
        let en = TimeColumns(text: AppText(timeZone: Timetable.timeZone, timeZoneIsArea: true))
        XCTAssertEqual(en.selected(.hour, in: evening), 8)
        XCTAssertEqual(en.selected(.minute, in: evening), 14)
        XCTAssertEqual(en.selected(.period, in: evening), 1)
        XCTAssertEqual(en.setting(.period, to: 0, in: evening), try ny(7, 8, 14), "AM: the same day, seconds dropped")
        XCTAssertEqual(en.setting(.hour, to: 0, in: evening), try ny(7, 12, 14), "12 PM is noon")
        XCTAssertEqual(en.setting(.hour, to: 0, in: try ny(7, 9, 0)), try ny(7, 0, 0), "12 AM is midnight")
        XCTAssertEqual(en.setting(.minute, to: 5, in: evening), try ny(7, 20, 5))
        XCTAssertEqual(TimeColumns(text: AppText(clock: .twentyFourHour, timeZone: Timetable.timeZone)).setting(.hour, to: 7, in: evening),
                       try ny(7, 7, 14))

        XCTAssertNil(en.stepping(.minute, by: 1, in: try ny(7, 20, 59)), "no wrapping past the last cell")
        XCTAssertEqual(en.stepping(.minute, by: -1, in: try ny(7, 20, 59)), try ny(7, 20, 58))
        XCTAssertNil(en.stepping(.hour, by: -1, in: try ny(7, 12, 30)), "12 is the first hour")
        XCTAssertEqual(en.stepping(.hour, by: 1, in: try ny(7, 12, 30)), try ny(7, 13, 30))
        XCTAssertEqual(en.stepping(.period, by: 1, in: try ny(7, 9, 0)), try ny(7, 21, 0))
        XCTAssertNil(en.stepping(.period, by: 1, in: try ny(7, 21, 0)))

        // The night the clocks go forward (March 14, 2027): 2 AM doesn't exist, but the time stays on that day
        let spring = try ny(14, 1, 30, month: 3, year: 2027)
        let picked = en.setting(.hour, to: 2, in: spring)
        XCTAssertEqual(calendar.component(.day, from: picked), 14)
        XCTAssertGreaterThan(picked, spring)

        // In an area in Tokyo, the hours are Tokyo's: 8:14 PM in New York on November 7 is 10:14 AM on November 8 there
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let there = TimeColumns(text: AppText(clock: .twentyFourHour, timeZone: tokyo, timeZoneIsArea: true))
        XCTAssertEqual(there.selected(.hour, in: evening), 10)
        let tokyoCalendar = Timetable.calendar(in: tokyo)
        let eight = there.setting(.hour, to: 8, in: evening)
        XCTAssertEqual(tokyoCalendar.dateComponents([.day, .hour, .minute], from: eight), DateComponents(day: 8, hour: 8, minute: 14))
        XCTAssertEqual(eight, try ny(7, 18, 14), "two hours earlier on the same Tokyo day")
    }

    /// Haitian Creole has no date data on macOS (Linux falls back to French), so its dates use the month names in
    /// Resources/date_names.json, day first; the clock still follows the 12 / 24-hour setting
    func testHaitianCreoleDatesUseBundledNames() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let tuesday = date(2026, 10, 27, 14, 5)
        let ht = AppText(language: .haitianCreole)
        XCTAssertEqual(ht.day(tuesday, timeZone: utc).replacingOccurrences(of: "\u{2060}", with: ""), "27 okt 2026")
        XCTAssertEqual((1...12).map { ht.day(date(2026, $0, 4), timeZone: utc).replacingOccurrences(of: "\u{2060}", with: "") },
                       ["4 jan 2026", "4 fev 2026", "4 mas 2026", "4 avr 2026", "4 me 2026", "4 jen 2026",
                        "4 jiy 2026", "4 out 2026", "4 sep 2026", "4 okt 2026", "4 nov 2026", "4 des 2026"])
        XCTAssertEqual(ht.dayAndTime(tuesday, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " "), "27 okt 2026, 2:05 PM")
        let ht24 = AppText(language: .haitianCreole, clock: .twentyFourHour)
        XCTAssertEqual(ht24.dayAndTime(tuesday, timeZone: utc), "27 okt 2026, 14:05")
        XCTAssertEqual(ht24.dayAndTime(date(2026, 12, 31, 9, 30), timeZone: utc), "31 des 2026, 09:30")
        // Clock times alone are as before
        XCTAssertEqual(ht.time(tuesday, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " "), "2:05 PM")
        XCTAssertEqual(ht24.time(tuesday, timeZone: utc), "14:05")
        XCTAssertEqual(ht24.timeWithSeconds(tuesday.addingTimeInterval(7), timeZone: utc), "14:05:07")

        // Full month and weekday names, in-sentence and standalone (2026-07-01 is a Wednesday)
        let names = try XCTUnwrap(Translations.dateNames(.haitianCreole))
        XCTAssertEqual(names.months, ["janvye", "fevriye", "mas", "avril", "me", "jen", "jiy\u{E8}", "out", "septanm",
                                      "okt\u{F2}b", "novanm", "desanm"])
        XCTAssertEqual(names.weekdays, ["dimanch", "lendi", "madi", "m\u{E8}kredi", "jedi", "vandredi", "samdi"])
        XCTAssertEqual(names.shortWeekdays, ["dim", "len", "mad", "m\u{E8}k", "jed", "van", "sam"])
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.haitianCreole.locale
        formatter.timeZone = utc
        names.apply(to: formatter)
        formatter.dateFormat = "EEEE d MMMM, EEE LLL LLLL ccc cccc"
        XCTAssertEqual(formatter.string(from: tuesday), "madi 27 okt\u{F2}b, mad okt okt\u{F2}b mad madi")
        XCTAssertEqual(formatter.string(from: date(2026, 7, 1)),
                       "m\u{E8}kredi 1 jiy\u{E8}, m\u{E8}k jiy jiy\u{E8} m\u{E8}k m\u{E8}kredi")
        // Letters in a separator are quoted so they aren't read as date fields
        XCTAssertEqual(DateNames.quoted(", "), "', '")
        XCTAssertEqual(DateNames.quoted("it's"), "'it''s'")
    }

    /// The date picker gets a locale with real date data: French (Haiti) for Haitian Creole, each language's own for the rest
    func testDatePickerLocale() {
        XCTAssertEqual(AppLanguage.haitianCreole.datePickerLocale.identifier, "fr_HT")
        XCTAssertTrue(Locale.availableIdentifiers.contains("fr_HT"))
        for language in AppLanguage.allCases where language != .haitianCreole {
            XCTAssertEqual(language.datePickerLocale.identifier, language.locale.identifier, language.rawValue)
        }
    }

    /// Only Haitian Creole uses bundled date names; every other language formats dates exactly as a formatter built
    /// from its locale (the way they were formatted before the bundled names existed)
    func testOtherLanguagesDatesAreUnchanged() {
        XCTAssertEqual(AppLanguage.allCases.filter { Translations.dateNames($0) != nil }, [.haitianCreole])
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_153_100)  // 2026-10-28 02:05 UTC
        for language in AppLanguage.allCases where language != .haitianCreole {
            for clock in ClockStyle.allCases {
                let text = AppText(language: language, clock: clock)
                let medium = DateFormatter()
                medium.locale = language.locale
                medium.timeZone = utc
                medium.dateStyle = .medium
                medium.timeStyle = .none
                XCTAssertEqual(text.day(date, timeZone: utc), text.unbroken(medium.string(from: date)), language.rawValue)
                let template = "yMMMd" + clock.template(seconds: false)
                let both = DateFormatter()
                both.locale = language.locale
                both.timeZone = utc
                both.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: language.locale) ?? template
                XCTAssertEqual(text.dayAndTime(date, timeZone: utc), both.string(from: date), "\(language.rawValue) \(clock.rawValue)")
            }
        }
        XCTAssertEqual(AppText(language: .english).day(date, timeZone: utc).replacingOccurrences(of: "\u{2060}", with: ""), "Oct 28, 2026")
        XCTAssertEqual(AppText(language: .polish).day(date, timeZone: utc).replacingOccurrences(of: "\u{2060}", with: ""), "28 pa\u{17A} 2026")
        // Kept on one line inside a sentence: a word joiner between every two characters, so a narrow line never ends in "Oct"
        XCTAssertEqual(AppText(language: .english).day(date, timeZone: utc), "Oct 28, 2026".map(String.init).joined(separator: "\u{2060}"))
    }

    func testMetricAndUSUnits() {
        let metric = AppText(units: .metric)
        let us = AppText(units: .usCustomary)
        XCTAssertEqual(metric.distance(987), "990 m")
        XCTAssertEqual(metric.distance(1200), "1,200 m")
        XCTAssertEqual(us.distance(987), "3,240 ft")
        XCTAssertEqual(metric.speed(kmh: 4.5), "4.5 km/h")
        XCTAssertEqual(us.speed(kmh: 4.5), "2.8 mph")
    }

    func testUnitConversionsRoundTrip() {
        let us = DistanceUnit.usCustomary
        XCTAssertEqual(us.meters(fromDisplay: us.displayDistance(fromMeters: 1200)), 1200, accuracy: 0.0001)
        XCTAssertEqual(us.displayDistance(fromMeters: 1), 3.2808, accuracy: 0.0001)
        XCTAssertEqual(us.kmh(fromDisplay: us.displaySpeed(fromKmh: 4.5)), 4.5, accuracy: 0.0001)
        XCTAssertEqual(DistanceUnit.metric.displayDistance(fromMeters: 800), 800)
    }

    // MARK: Subway text

    func testDirectionUsesSignThenTerminal() {
        let d = Direction(code: "N", name: "To Flushing-Main St", terminal: "Flushing-Main St")
        XCTAssertEqual(AppText().direction(d), "To Flushing-Main St")
        XCTAssertEqual(AppText(language: .chineseSimplified).direction(d), "\u{5F00}\u{5F80} Flushing-Main St")
        // Use the sign's direction name when there is one; Uptown / Downtown get translated, place names don't
        let manhattan = Direction(code: "S", name: "Manhattan", terminal: "34 St-Hudson Yards", label: "Manhattan")
        XCTAssertEqual(AppText(language: .chineseSimplified).direction(manhattan), "\u{5F00}\u{5F80} Manhattan")
        XCTAssertEqual(AppText().direction(manhattan), "To Manhattan")
        XCTAssertEqual(AppText().terminal(manhattan), "To 34 St-Hudson Yards")
        let uptown = Direction(code: "N", name: "Uptown", terminal: "Jamaica-179 St", label: "Uptown")
        XCTAssertEqual(AppText(language: .german).direction(uptown), AppText(language: .german).t("Uptown"))
        let dir = BoardDirection(code: "N", directions: [Direction(code: "N", name: "Queens", label: "Queens"), uptown, uptown],
                                 routes: ["7", "F"], trains: [])
        XCTAssertEqual(AppText().directionTitle(dir), "To Queens · Uptown")
        // Without a sign direction name, use terminals; list every terminal in the same direction
        let flushing = Direction(code: "N", name: "To Flushing-Main St", terminal: "Flushing-Main St")
        let mets = Direction(code: "N", name: "To Mets-Willets Point", terminal: "Mets-Willets Point")
        let st111 = Direction(code: "N", name: "To 111 St", terminal: "111 St")
        func title(_ ds: [Direction]) -> String {
            AppText().directionTitle(BoardDirection(code: "N", directions: ds, routes: ["7"], trains: []))
        }
        XCTAssertEqual(title([flushing]), "To Flushing-Main St")
        XCTAssertEqual(title([flushing, mets]), "To Flushing-Main St or Mets-Willets Point")
        // Past two terminals: the first two and how many more (the station page lists them all, from directionTerminals)
        XCTAssertEqual(title([flushing, mets, st111, mets]), "To Flushing-Main St, Mets-Willets Point, and 1 more")
        let brooklyn = ["Flatbush Av-Brooklyn College", "New Lots Av", "Crown Hts-Utica Av", "Brighton Beach",
                        "Coney Island-Stillwell Av", "Bay Ridge-95 St", "Bay Pkwy"]
        let seven = brooklyn.map { Direction(code: "S", name: "To " + $0, terminal: $0) }
        XCTAssertEqual(title(seven), "To Flatbush Av-Brooklyn College, New Lots Av, and 5 more")
        XCTAssertEqual(AppText().directionTerminals(BoardDirection(code: "S", directions: seven + seven, routes: [], trains: [])), brooklyn)
        XCTAssertEqual(AppText().directionTerminals(BoardDirection(code: "N", directions: [Direction(code: "N", name: "Queens", label: "Queens"),
                                                                                           flushing, uptown, mets], routes: [], trains: [])),
                       ["Flushing-Main St", "Mets-Willets Point"], "the trains with a sign direction name aren't listed")
        XCTAssertEqual(AppText(language: .chineseSimplified).toPlaces(brooklyn),
                       "\u{5F00}\u{5F80} Flatbush Av-Brooklyn College\u{3001}New Lots Av \u{53CA}\u{53E6}\u{5916} 5 \u{5904}")
        for language in AppLanguage.allCases {
            let text = AppText(language: language).toPlaces(brooklyn)
            XCTAssertTrue(text.contains("Flatbush Av-Brooklyn College") && text.contains("New Lots Av") && !text.contains("Brighton Beach"),
                          "\(language): \(text)")
        }
        XCTAssertEqual(title([Direction(code: "N", name: "Queens", label: "Queens"), flushing, uptown, mets]),
                       "To Queens · To Flushing-Main St or Mets-Willets Point · Uptown", "no longer keeps only two names")
        XCTAssertEqual(AppText().toPlaces([]), "")
        // When the terminal is unknown, don't write a vague direction like "Southbound" (rule: always write To <terminal>)
        XCTAssertEqual(AppText().directionTitle(BoardDirection(code: "S", directions: [], routes: [], trains: [])), "Destination not listed")
        XCTAssertEqual(AppText().direction(Direction(code: "N", name: "Northbound")), "Destination not listed")
        XCTAssertEqual(AppText().direction(Direction(code: "N", name: "Last Stop", label: "Last Stop")), "Destination not listed")
        XCTAssertEqual(AppText().direction(Direction(code: "N", name: "Uptown", label: "Uptown")), "Uptown")
        XCTAssertEqual(AppText().direction(Direction(code: "X", name: "Somewhere")), "Somewhere")
    }

    func testCatchLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route, routeMeters: 750)
        func eval(_ minutes: Double) -> CatchEvaluation {
            let arrival = Arrival(id: "a\(minutes)", stationID: "712", route: "7",
                                  direction: Direction(code: "N", name: "To Flushing-Main St", terminal: "Flushing-Main St"),
                                  arrivalTime: now.addingTimeInterval(minutes * 60), source: .realtime, updatedAt: now)
            return CatchEvaluator.evaluate(arrival: arrival, walk: walk, entranceToPlatformSeconds: 90,
                                           settings: .default, now: now)
        }
        let l = AppText()
        let good = eval(20)   // 11.5 min to the platform, train in 20 min → 8.5 min to spare (rounded down to 8)
        XCTAssertEqual(good.verdict, .canTry)
        XCTAssertEqual(l.catchLine(good, recommended: good), "10 min walk · Can try, 8 min to spare")
        XCTAssertEqual(l.shortCatchLine(good), "10 min walk · Can try")
        XCTAssertEqual(l.tinyCatchLine(good), "10 min · Can try")
        let tight = eval(12)  // 0.5 min to spare
        XCTAssertEqual(tight.verdict, .tight)
        XCTAssertEqual(l.catchLine(tight, recommended: good), "10 min walk · Tight, under 1 min to spare")
        let late = eval(5)
        XCTAssertEqual(late.verdict, .takeNext)
        let line = l.catchLine(late, recommended: good).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertTrue(line.hasPrefix("10 min walk · Too soon. Next one you can catch: "), line)
        // The time in it is kept on one line (word joiners), and reads the same without them
        let time = line.components(separatedBy: ": ").last ?? ""
        XCTAssertTrue(time.contains("\u{2060}"), line)
        XCTAssertEqual(time.replacingOccurrences(of: "\u{2060}", with: ""),
                       l.time(good.arrival.arrivalTime!).replacingOccurrences(of: "\u{202F}", with: " "))
        XCTAssertEqual(l.catchLine(late, recommended: nil), "10 min walk · Too soon to catch")
        XCTAssertEqual(l.walkSource(.route), "walking route")
        // Not sure, with a later one to catch: says which, as for too soon; without one, just "Not sure"
        var unsure = good
        unsure.verdict = .insufficientInfo
        let unsureLine = l.catchJudgement(unsure, recommended: good).replacingOccurrences(of: "\u{2060}", with: "")
        XCTAssertEqual(unsureLine, "Not sure. Next one you can catch: " + l.time(good.arrival.arrivalTime!))
        XCTAssertEqual(l.catchJudgement(unsure, recommended: nil), "Not sure")
        // Plan a Trip's tight blocks say the time to spare as the main window does
        XCTAssertEqual(l.toSpare(tight.slackSeconds), "under 1 min to spare")
        XCTAssertEqual(l.toSpare(150), "2 min to spare")
    }

    /// A screen reader gets each departure as one sentence of the pieces shown, in order: the line's name, where it goes, the
    /// time, how soon, the service and "Timetable" when shown, the walk, and whether you can catch it. No words of the icons
    func testSpokenDepartureIsOneSentence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route, routeMeters: 750)
        let to = Direction(code: "N", name: "To Flushing-Main St", terminal: "Flushing-Main St")
        func train(_ minutes: Double, express: Bool? = nil, source: ArrivalSource = .realtime) -> BoardTrain {
            let arrival = Arrival(id: "a\(minutes)", stationID: "712", route: "7", direction: to,
                                  arrivalTime: now.addingTimeInterval(minutes * 60), source: source, updatedAt: now, isExpress: express)
            let e = CatchEvaluator.evaluate(arrival: arrival, walk: walk, entranceToPlatformSeconds: 90, settings: .default, now: now)
            let station = Station(id: "712", name: "61 St-Woodside", coordinate: Coordinate(latitude: 40.74563, longitude: -73.90297))
            return BoardTrain(station: station, route: "7", direction: to, evaluation: e)
        }
        let l = AppText()
        XCTAssertEqual(l.spokenDeparture(train(20)), "7, To Flushing-Main St, " + l.arrivalTime(train(20).evaluation)
                       + ", in 20 min, 10 min walk, Can try, 8 min to spare")
        let express = l.spokenDeparture(train(20, express: true, source: .scheduled), station: "61 St-Woodside")
        XCTAssertTrue(express.hasPrefix("7, 61 St-Woodside, To Flushing-Main St, "), express)
        XCTAssertTrue(express.hasSuffix(", in 20 min, Express, Timetable, 10 min walk, Can try, 8 min to spare"), express)
        XCTAssertTrue(l.spokenDeparture(train(5)).hasSuffix(", 10 min walk, Too soon to catch"))
        for word in ["Selected", "Close", "checkmark", "xmark"] {
            XCTAssertFalse(express.contains(word), word)
        }
        // In Arabic each piece is isolated and joined with the Arabic comma, in the same order
        let arabic = AppText(language: .arabic).spokenDeparture(train(20))
        XCTAssertTrue(arabic.hasPrefix("\u{2068}7\u{2069}\u{60C} "), arabic)
        XCTAssertEqual(l.serviceName(express: false, bus: .selectBus), "SBS")
        XCTAssertEqual(l.serviceName(express: true, bus: nil), "Express")
        XCTAssertEqual(l.serviceName(express: false, bus: nil), "Local")
    }

    /// The line under a demo subway station's name is said in the UI language, its lines listed the language's way; English is the
    /// same as the line the search reads, and a famous place's neighborhood stays as it is
    func testDemoStationLineIsTranslated() throws {
        let catalog = try StationCatalog.loadBundled()
        let found = DemoData.search("42", catalog: catalog)
        XCTAssertEqual(found.count, 4)
        for place in found {
            XCTAssertFalse(place.lines.isEmpty, place.name)
            XCTAssertEqual(AppText().demoPlaceDetail(place), place.detail)
        }
        let famous = try XCTUnwrap(DemoData.search("Cloisters", catalog: catalog).first)
        XCTAssertTrue(famous.lines.isEmpty)
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppText(language: language).demoPlaceDetail(famous), "Fort Tryon Park, New York, NY", language.rawValue)
        }
        let lines = ["B", "D", "F", "M"]
        XCTAssertEqual(AppText().demoPlaceDetail("", lines: lines), "Subway station (B, D, F, M), New York, NY")
        let chinese = AppText(language: .chineseSimplified).demoPlaceDetail("", lines: lines)
        XCTAssertTrue(chinese.contains("B\u{3001}D\u{3001}F\u{3001}M"), chinese)
        XCTAssertFalse(chinese.contains("Subway station"), chinese)
        XCTAssertTrue(chinese.hasSuffix("New York, NY"), chinese)
        XCTAssertTrue(AppText(language: .japanese).demoPlaceDetail("", lines: lines).contains("B\u{3001}D"))
        XCTAssertTrue(AppText(language: .french).demoPlaceDetail("", lines: lines).contains("(B, D, F, M)"))
        // Right to left: the lines together, and each line, isolated
        for language in AppLanguage.allCases where language.isRightToLeft {
            let text = AppText(language: language)
            let shown = text.demoPlaceDetail("", lines: lines)
            XCTAssertTrue(shown.contains("\u{2068}" + lines.map(text.isolated).joined(separator: text.comma) + "\u{2069}"),
                          language.rawValue)
            XCTAssertFalse(shown.contains("Subway station"), language.rawValue)
        }
    }

    /// "Leave by" only for "can try": the latest minute to set off, with the clock time kept on one line, in every language
    func testLeaveBy() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let walk = WalkEstimate(walkSeconds: 900, straightLineMeters: 1000, source: .route)
        func eval(_ minutes: Double) -> CatchEvaluation {
            let arrival = Arrival(id: "a", stationID: "S", route: "1", direction: Direction(code: "N", name: "Uptown"),
                                  arrivalTime: now.addingTimeInterval(minutes * 60), source: .scheduled, updatedAt: now)
            return CatchEvaluator.evaluate(arrival: arrival, walk: walk, entranceToPlatformSeconds: 60, settings: .default,
                                           now: now, clockOffset: 0)
        }
        let l = AppText()
        let good = eval(26)   // 16 min to the platform: 10 min to spare, 3 needed for a timetable time
        let text = try XCTUnwrap(l.leaveBy(good))
        XCTAssertTrue(text.contains("\u{2060}"), text)
        XCTAssertEqual(text.replacingOccurrences(of: "\u{2060}", with: ""), "Leave by " + l.time(now.addingTimeInterval(420)))
        XCTAssertNil(l.leaveBy(eval(18)), "Tight: 2 min to spare")
        XCTAssertEqual(l.catchJudgement(good, recommended: nil), "Can try, 10 min to spare")
        XCTAssertEqual(l.catchLine(good, recommended: nil), "15 min walk · Can try, 10 min to spare")
        for language in AppLanguage.allCases {
            let shown = AppText(language: language)
            let line = try XCTUnwrap(shown.leaveBy(good)).replacingOccurrences(of: "\u{2060}", with: "")
            XCTAssertTrue(line.contains(shown.time(now.addingTimeInterval(420))), language.rawValue)
        }
    }

    /// Today and tomorrow in the system's own words, at the start where the date was; other days, and Haitian Creole
    /// (no date data), keep the date
    func testDayAndTimeFromToday() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ny
        let now = Date()
        let today = try XCTUnwrap(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: today))
        let en = AppText(clock: .twentyFourHour)
        let todayText = en.dayAndTimeFromToday(today, now: now, timeZone: ny)
        let tomorrowText = en.dayAndTimeFromToday(tomorrow, now: now, timeZone: ny)
        #if canImport(Darwin)
        XCTAssertTrue(todayText.hasPrefix("Today") && todayText.hasSuffix("18:00"), todayText)
        XCTAssertFalse(todayText.contains(String(calendar.component(.year, from: today))), todayText)
        XCTAssertTrue(tomorrowText.hasPrefix("Tomorrow") && tomorrowText.hasSuffix("18:00"), tomorrowText)
        XCTAssertTrue(AppText(language: .chineseSimplified).dayAndTimeFromToday(today, now: now, timeZone: ny).contains("\u{4ECA}\u{5929}"))
        XCTAssertTrue(AppText(language: .german).dayAndTimeFromToday(tomorrow, now: now, timeZone: ny).hasPrefix("Morgen"))
        #else
        // The open-source Foundation has no words like "Today": the date stays, as in a language without them
        XCTAssertEqual(todayText, en.dayAndTime(today, timeZone: ny))
        XCTAssertEqual(tomorrowText, en.dayAndTime(tomorrow, timeZone: ny))
        #endif
        XCTAssertEqual(en.dayAndTimeFromToday(later, now: now, timeZone: ny), en.dayAndTime(later, timeZone: ny))
        // Yesterday (a time left in the past) keeps the date too
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertEqual(en.dayAndTimeFromToday(yesterday, now: now, timeZone: ny), en.dayAndTime(yesterday, timeZone: ny))
        let ht = AppText(language: .haitianCreole)
        XCTAssertEqual(ht.dayAndTimeFromToday(today, now: now, timeZone: ny), ht.dayAndTime(today, timeZone: ny))
        // Every language still shows the time
        for language in AppLanguage.allCases {
            let shown = AppText(language: language, clock: .twentyFourHour)
            XCTAssertTrue(shown.dayAndTimeFromToday(today, now: now, timeZone: ny).contains(shown.time(today, timeZone: ny)), language.rawValue)
        }
    }

    func testSpareRoundsDown() {
        let l = AppText()
        XCTAssertEqual(l.spare(59), "under 1 min")
        XCTAssertEqual(l.spare(-30), "under 1 min")
        XCTAssertEqual(l.spare(179), "2 min", "round down; don't overstate spare time")
        XCTAssertEqual(AppText(language: .chineseSimplified).spare(30), "\u{4E0D}\u{5230} 1 \u{5206}\u{949F}")
    }

    func testActivityStatus() {
        let now = Date(timeIntervalSince1970: 20 * 3600)
        let l = AppText()
        let on = ActivityState(isOn: false, changedAt: now).started(at: now)
        XCTAssertEqual(l.activityStatus(on, now: now), "On until " + l.time(now.addingTimeInterval(30 * 60)))
        XCTAssertEqual(l.activityStatus(on, now: now.addingTimeInterval(31 * 60)), "Standby", "auto standby after 30 minutes")
        let forever = ActivityState(isOn: false, autoStandbyMinutes: nil, changedAt: now).started(at: now)
        XCTAssertEqual(l.activityStatus(forever, now: now), "On")
        // Kept on past its auto-standby time by a reminder still to come: the later time, and why
        let until = now.addingTimeInterval(45 * 60)
        let held = on.holding(until: until)
        XCTAssertEqual(l.activityStatus(held, now: now), "On until " + l.time(until) + " for a reminder")
        XCTAssertEqual(l.activityStatus(held, now: now.addingTimeInterval(40 * 60)), "On until " + l.time(until) + " for a reminder")
        XCTAssertEqual(l.activityStatus(held, now: until), "Standby")
        // A hold that ends before the usual time says nothing more; neither does one on "no auto-standby"
        XCTAssertEqual(l.activityStatus(on.holding(until: now.addingTimeInterval(60)), now: now), l.activityStatus(on, now: now))
        XCTAssertEqual(l.activityStatus(forever.holding(until: until), now: now), "On")
        XCTAssertEqual(AppText(language: .german).activityStatus(held, now: now), "Aktiv bis " + AppText(language: .german).time(until)
                       + " f\u{00FC}r eine Erinnerung")
        XCTAssertEqual(AppText(language: .chineseSimplified).activityStatus(on.stopped(at: now), now: now), "\u{5F85}\u{673A}")
    }

    /// Short widget text can't be too long (must fit in a narrow column), and must never say things like "run" or "you'll definitely make it".
    func testShortVerdictsStayShort() {
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            for v in [CatchVerdict.canTry, .tight, .takeNext, .insufficientInfo] {
                XCTAssertLessThanOrEqual(l.verdictShort(v).count, 14, "\(language.rawValue): \(l.verdictShort(v))")
            }
        }
        let keys = Set(AppText.allKeys)
        XCTAssertFalse(keys.contains("Go"))
        XCTAssertFalse(keys.contains("Hurry"))
    }

    /// A failed first download says the operators' own problems instead of asking to check the network, unless the network failed too
    func testDownloadFailedSaysTheOperatorsProblem() {
        let l = AppText()
        let network = l.t("Couldn't download the train timetables. Check your network.")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let moved = NetworkReach.Notice(provider: "Amtrak", problem: .notFound, since: t0, lasting: true)
        let errors = NetworkReach.Notice(provider: "CTrail Hartford Line", problem: .serverError, since: t0, lasting: true)
        let blocked = NetworkReach.Notice(provider: "Long Island Rail Road", problem: .noDNS, since: t0, lasting: true)
        XCTAssertEqual(l.downloadFailedText(network, problems: []), network)
        XCTAssertEqual(l.downloadFailedText(network, problems: [blocked]), network)
        XCTAssertEqual(l.downloadFailedText(network, problems: [moved]),
                       "Can't get data from Amtrak: it's no longer at its usual address. The operator may have moved or changed it.")
        XCTAssertEqual(l.downloadFailedText(network, problems: [moved, errors], short: true),
                       "Amtrak: data moved or missing\nCTrail Hartford Line: server errors")
        XCTAssertEqual(l.downloadFailedText(network, problems: [blocked, moved], short: true), network + "\nAmtrak: data moved or missing")
    }

    /// A reason about this Mac or its network as a whole (its clock, a sign-in page) is said in place of "check your network",
    /// once and without a provider's name; with an unreachable server too, the network sentence stays. Offline says itself
    func testDownloadFailedSaysThisMacsReason() {
        let l = AppText()
        let network = l.t("Couldn't download the train timetables. Check your network.")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = NetworkReach.Notice(provider: "", problem: .clock, since: t0)
        let signIn = NetworkReach.Notice(provider: "", problem: .signIn, since: t0)
        let offline = NetworkReach.Notice(provider: "", problem: .offline, since: t0)
        let blocked = NetworkReach.Notice(provider: "Long Island Rail Road", problem: .noDNS, since: t0, lasting: true)
        XCTAssertEqual(l.downloadFailedText(network, problems: [clock]), l.reachText(clock))
        XCTAssertEqual(l.downloadFailedText(network, problems: [signIn], short: true), "This network may need you to sign in")
        XCTAssertEqual(l.downloadFailedText(network, problems: [offline]), network)
        XCTAssertEqual(l.downloadFailedText(network, problems: [clock, blocked], short: true), network + "\nCheck this Mac's date and time")
        XCTAssertFalse(l.reachText(clock).contains(":"), "No provider's name")
        XCTAssertEqual(l.reachSymbol(clock), "clock.badge.exclamationmark")
        // Said once, not counted with the unreachable servers: two of those are combined, the reasons stay on their own lines
        let slow = NetworkReach.Notice(provider: "Amtrak", problem: .noResponse, since: t0)
        XCTAssertNil(l.reachCombinedText([clock, signIn, blocked]))
        XCTAssertNotNil(l.reachCombinedText([clock, signIn, blocked, slow]))
        XCTAssertEqual(l.reachSeparate([clock, signIn, blocked, slow]), [clock, signIn])
    }

    /// The main window and Settings say how far off the Mac's clock is, either way, in minutes or hours
    func testClockOffsetText() {
        let l = AppText()
        XCTAssertTrue(l.clockOffsetText(300).hasPrefix("This Mac's clock is about 5 min off"))
        XCTAssertTrue(l.clockOffsetText(-300).hasPrefix("This Mac's clock is about 5 min off"))
        XCTAssertTrue(l.clockOffsetText(-2 * 3600).hasPrefix("This Mac's clock is about 2 hr off"))
        XCTAssertTrue(AppText(language: .german).clockOffsetText(300).contains("5 Min."))
    }

    /// How approximate the position is, kept to two figures: it's macOS's estimate, not a measurement
    func testRoughDistance() {
        let metric = AppText(units: .metric)
        let us = AppText(units: .usCustomary)
        XCTAssertEqual(metric.roughDistance(87), "90 m")
        XCTAssertEqual(metric.roughDistance(1234), "1,200 m")
        XCTAssertEqual(metric.roughDistance(1500), "1,500 m")
        XCTAssertEqual(metric.roughDistance(5050), "5,100 m")
        XCTAssertEqual(metric.roughDistance(12345), "12,000 m")
        XCTAssertEqual(metric.roughDistance(0), "0 m")
        XCTAssertEqual(us.roughDistance(1500), "4,900 ft")
        let arabic = AppText(language: .arabic, units: .metric).roughDistance(1500)
        XCTAssertTrue(arabic.hasPrefix("\u{2068}") && arabic.hasSuffix("\u{2069}"), "Kept in its order in right-to-left text")
    }
}
