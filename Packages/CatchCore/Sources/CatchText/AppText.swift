import Foundation
import TransitCore

/// All UI text and formatting: translated into the chosen language, distances shown in the chosen units.
///
/// Usage: `text.t("Refresh")` gets a translation; `text.f("in %@ min", "6")` fills in arguments.
/// The keys are the English source text, so English needs no translation table; other languages live in the Translations folder,
/// and missing translations fall back to English (tests check that every language is fully translated).
/// The main app and widgets share this one copy, so both sides display the same.
public struct AppText: Sendable {
    public var language: AppLanguage
    public var units: DistanceUnit
    public var clock: ClockStyle
    /// The time zone times and dates are shown in: the metro area's of the place they're for (the app sets it from the place, see
    /// MetroArea.timeZone(at:)); outside the service area, this Mac's. A station's departures can be in its own (Arrival.timeZone)
    public var timeZone: TimeZone
    /// Whether `timeZone` is a metro area's: the current time then always names it, as the station clocks did when every area
    /// was New York's. Outside the service area it's this Mac's own and isn't named, unless it differs from the Mac's
    public var timeZoneIsArea: Bool
    /// This Mac's own time zone: a clock time names its zone ("8:14 PM EST") when it reads differently there. Nil: not compared,
    /// so no clock time names its zone except the current time in a metro area (text that isn't shown on this Mac's screen, tests)
    public var macTimeZone: TimeZone?
    /// This Mac's own time zone (the system's when not set), for times and dates about the whole app rather than a place: the last
    /// update check, the widget's last run
    public var macZone: TimeZone { macTimeZone ?? .autoupdatingCurrent }

    public init(language: AppLanguage = .default, units: DistanceUnit = .default, clock: ClockStyle = .default,
                timeZone: TimeZone = .autoupdatingCurrent, timeZoneIsArea: Bool = false, macTimeZone: TimeZone? = nil) {
        self.language = language
        self.units = units
        self.clock = clock
        self.timeZone = timeZone
        self.timeZoneIsArea = timeZoneIsArea
        self.macTimeZone = macTimeZone
    }

    /// The same text with times in another place's time zone (`area`: whether it's a metro area's)
    public func inTimeZone(_ zone: TimeZone, area: Bool) -> AppText {
        var copy = self
        copy.timeZone = zone
        copy.timeZoneIsArea = area
        return copy
    }

    /// Whether a clock time in this zone (`timeZone` when nil) reads differently from this Mac's clock at that moment: it then
    /// names its zone. Compared by the clock's offset, so a zone that keeps the same time as the Mac's (Detroit and New York) isn't
    /// named
    public func showsZone(_ zone: TimeZone? = nil, at date: Date) -> Bool {
        guard let macTimeZone else { return false }
        return (zone ?? timeZone).secondsFromGMT(for: date) != macTimeZone.secondsFromGMT(for: date)
    }

    public var locale: Locale { language.locale }

    // MARK: - Translation

    /// Translates a fixed piece of text.
    public func t(_ key: String) -> String {
        let text = Translations.table(for: language)[key] ?? key
        return language.isRightToLeft ? Self.rightToLeftParagraph(text) : text
    }

    /// Text takes its direction from its first letter, so a right-to-left sentence that starts with an English name
    /// ("Catch My Train …", "MTA Bus Time …") would be laid out left-to-right: the name jumps to the far left and the period to the far right.
    /// An invisible right-to-left mark (U+200F) in front fixes the direction. Text with no right-to-left letters at all ("SBS", "%@ m") stays as it is.
    static func rightToLeftParagraph(_ text: String) -> String {
        var depth = 0
        var startsLeftToRight: Bool?
        var hasRightToLeft = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2066...0x2068: depth += 1; continue
            case 0x2069: depth = max(0, depth - 1); continue
            default: break
            }
            // Text inside an isolate doesn't decide the direction of the sentence around it
            guard depth == 0 else { continue }
            if isRightToLeftLetter(scalar) {
                hasRightToLeft = true
                if startsLeftToRight == nil { startsLeftToRight = false }
            } else if scalar.value == 0x200E || scalar.properties.isAlphabetic {
                if startsLeftToRight == nil { startsLeftToRight = true }
            }
            if startsLeftToRight == false || (startsLeftToRight == true && hasRightToLeft) { break }
        }
        return startsLeftToRight == true && hasRightToLeft ? "\u{200F}" + text : text
    }

    /// Hebrew and Yiddish, Arabic and Urdu letters (and their presentation forms), plus the right-to-left and Arabic letter marks
    static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x200F, 0x061C: return true
        default: return false
        }
    }

    /// Translates text with arguments. Templates fill %@ in order, or use %1$@, %2$@ to pick a specific argument.
    public func f(_ key: String, _ args: String...) -> String {
        Self.fill(t(key), args.map(isolated), closingUp: language.isChinese && Self.spareTemplates.contains(key))
    }

    /// The sentences that say how much time is to spare. Chinese puts a space between a word and a number but none between two
    /// words, and the time put in starts with a number ("3 min") or, in Chinese, with a word ("under 1 min"): for these the
    /// template's space in front of it is dropped when a word follows (see fill).
    static let spareTemplates: Set<String> = ["%@ to spare", "%1$@, %2$@ to spare", "Spare time: %1$@ (needs %2$@)"]

    /// In right-to-left languages (Arabic, Hebrew, Urdu), English station names, line names, numbers etc. inserted into sentences
    /// are wrapped in Unicode isolates (FSI…PDI): each lays out in its own direction without affecting the surrounding text.
    /// Otherwise the numbers in "34 St-Hudson Yards" jump to the other end, and commas and periods land in the wrong place.
    /// The characters themselves are invisible; other languages don't add them.
    public func isolated(_ text: String) -> String {
        guard language.isRightToLeft, !text.isEmpty else { return text }
        return "\u{2068}" + text + "\u{2069}"
    }

    /// Comma for lists: Arabic and Urdu use the Arabic comma (U+060C), other languages use ",".
    public var comma: String {
        language == .arabic || language == .urdu ? "\u{60C} " : ", "
    }

    /// Sentences one after another in a line of text: a space between two, and none in Chinese and Japanese, where the full
    /// stop already takes a character's width
    public func sentences(_ parts: [String]) -> String {
        let said = parts.filter { !$0.isEmpty }
        switch language {
        case .chineseSimplified, .chineseTraditional, .japanese: return said.joined()
        default: return said.joined(separator: " ")
        }
    }

    /// A label and what follows it ("Without times: Island Queen"), with the colon the language's own sentences use: French puts
    /// a no-break space before it, Chinese and Japanese write the full-width colon with no space, the others ": "
    public func labeled(_ label: String, _ text: String) -> String {
        switch language {
        case .french: return label + "\u{A0}: " + text
        case .chineseSimplified, .chineseTraditional, .japanese: return label + "\u{FF1A}" + text
        default: return label + ": " + text
        }
    }

    /// Joins items with commas (no "and"); in right-to-left languages each item is isolated so order and punctuation stay intact.
    public func commaList(_ items: [String]) -> String {
        items.map(isolated).joined(separator: comma)
    }

    /// A list of short items without "and", such as a station's lines ("B, D, F, M"): Chinese and Japanese put the ideographic
    /// comma (U+3001) between them, the other languages their comma (as in commaList, with each item isolated in right-to-left ones)
    public func shortList(_ items: [String]) -> String {
        switch language {
        case .chineseSimplified, .chineseTraditional, .japanese: return items.joined(separator: "\u{3001}")
        default: return commaList(items)
        }
    }

    /// The line under a demo place's name in the place searches. A subway station's is said in the UI language ("Subway station
    /// (B, D, F, M), New York, NY", its lines listed the language's way, the city's name in English as Apple Maps gives it); a famous
    /// place's is where it is ("Midtown, New York, NY"), place names that stay as they are, like the app's station names.
    /// The search itself still reads the English line (DemoData.search)
    public func demoPlaceDetail(_ detail: String, lines: [String]) -> String {
        lines.isEmpty ? detail : f("Subway station (%@), New York, NY", shortList(lines))
    }

    public func demoPlaceDetail(_ place: DemoData.Place) -> String {
        demoPlaceDetail(place.detail, lines: place.lines)
    }

    /// Joins pieces with " · ", e.g. "5 min walk · 1,590 ft · Apple Maps". In right-to-left languages each piece is isolated, as in
    /// commaList, so a number and its unit or an English name keep their own order, and an invisible right-to-left mark (U+200F) in
    /// front keeps the pieces going from right to left, the first one on the right (with every piece isolated, nothing else would
    /// say which way the line goes). Other languages get the pieces as they are.
    public func dotted(_ items: [String]) -> String {
        let joined = items.map(isolated).joined(separator: " · ")
        return language.isRightToLeft && !joined.isEmpty ? "\u{200F}" + joined : joined
    }

    /// Fills a template's %@, %1$@ … with the arguments. An argument that ends with a period (Russian and Ukrainian dates end with
    /// their word for "year", shortened; an abbreviation) takes the place of the period right after it in the template, so the
    /// sentence doesn't end in "..". `closingUp` (Chinese only, see spareTemplates): an argument that starts with a Chinese
    /// character takes the place of a space the template has between it and the Chinese character before.
    static func fill(_ template: String, _ args: [String], closingUp: Bool = false) -> String {
        var out = ""
        var next = 0
        let chars = Array(template)
        var i = 0
        var endsWithPeriod = false
        func insert(_ arg: String) {
            if closingUp, out.last == " ", arg.first.map(isHan) == true, out.dropLast().last.map(isHan) == true {
                out.removeLast()
            }
            out += arg
            // An isolated argument (right-to-left languages) ends with the invisible U+2069 after its own last character
            endsWithPeriod = arg.last(where: { $0 != "\u{2069}" }) == "."
        }
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                if chars[i + 1] == "@" {
                    insert(next < args.count ? args[next] : "")
                    next += 1
                    i += 2
                    continue
                }
                if chars[i + 1] == "%" {
                    out.append("%")
                    endsWithPeriod = false
                    i += 2
                    continue
                }
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    digits.append(chars[j])
                    j += 1
                }
                if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@", let n = Int(digits) {
                    insert((n >= 1 && n <= args.count) ? args[n - 1] : "")
                    i = j + 2
                    continue
                }
            }
            if !(endsWithPeriod && chars[i] == ".") { out.append(chars[i]) }
            endsWithPeriod = false
            i += 1
        }
        return out
    }

    /// A Chinese character (CJK Unified Ideographs and Extension A), not punctuation or a full-width letter
    static func isHan(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
    }

    /// Which arguments a template references (sorted), used by tests to check translations match the English arguments.
    static func placeholderIndexes(in template: String) -> [Int] {
        var result: [Int] = []
        var next = 1
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                if chars[i + 1] == "@" { result.append(next); next += 1; i += 2; continue }
                if chars[i + 1] == "%" { i += 2; continue }
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@", let n = Int(digits) {
                    result.append(n); i = j + 2; continue
                }
            }
            i += 1
        }
        return result.sorted()
    }

    // MARK: - Numbers and time

    public func number(_ value: Double, fractionDigits: Int = 0) -> String {
        let formatter = FormatterCache.number(locale: locale, fractionDigits: fractionDigits)
        // Round ourselves first (NumberFormatter on some platforms ignores the maximum fraction digits).
        let scale = pow(10, Double(max(0, fractionDigits)))
        let rounded = (value * scale).rounded() / scale
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    // Times and dates are in `timeZone` (the place's metro area's), wherever the Mac's clock is set: the timetables count in it,
    // and a Mac set to another zone sees the same times and days as one there. A clock time names its zone when the Mac's
    // clock reads differently (showsZone); "in 5 min" never does.

    /// Clock time, e.g. "8:14 PM" / "20:14" / the Chinese afternoon form (per locale convention); "8:14 PM EST" when the Mac's clock
    /// reads differently. `timeZone`: a station's own, when its departures are in another zone than the area's
    public func time(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let zone = timeZone ?? self.timeZone
        return format(date, style: .short, timeZone: zone, zone: showsZone(zone, at: date))
    }

    /// The current time, with the time zone named the way this language writes it (e.g. "8:14 PM EDT", "EST" in winter; "GMT-4" in some
    /// languages), so it's clear whose time it is: always in a metro area; outside the service area only when it isn't the Mac's.
    public func currentTime(_ date: Date) -> String {
        format(date, style: .short, timeZone: timeZone, zone: timeZoneIsArea || showsZone(at: date))
    }

    /// The time zone's short name the way this language writes it ("EST", "GMT-5"), at that moment (EDT in summer)
    public func zoneName(_ zone: TimeZone? = nil, at date: Date) -> String {
        FormatterCache.date(locale: locale, timeZone: zone ?? timeZone, dateStyle: .none, template: "z").string(from: date)
    }

    /// The line above a station's departures, Plan a Trip and the menu bar panel when their times aren't what this Mac's clock reads:
    /// in a metro area, that they're its local time; outside the service area (only when where you are is known to keep another time
    /// than the Mac), that the Mac's clock is set to another zone. Nil when the times read as on the Mac's clock. `areaName`: the
    /// metro area's name, already in this language
    public func timeZoneNote(at date: Date, areaName: String?) -> String? {
        guard showsZone(at: date) else { return nil }
        if timeZoneIsArea, let areaName {
            return f("Times here are local time in %@ (%@), not this Mac's time zone.", areaName, zoneName(at: date))
        }
        return t("This Mac's clock is set to a different time zone than where you are.")
    }

    /// Clock time with seconds (for "data updated time"), naming its zone like time().
    public func timeWithSeconds(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let zone = timeZone ?? self.timeZone
        return format(date, style: .medium, timeZone: zone, zone: showsZone(zone, at: date))
    }

    /// Date, e.g. "Oct 31, 2026" / the Chinese year-month-day form. `timeZone`: another than the place's, e.g. this Mac's for
    /// what isn't about a metro area (the last update check). Kept on one line where it's inside a sentence that wraps
    /// (unbroken): a narrow line moves the whole date to the next one rather than leaving "Dec" at the end of one and "1, 2026"
    /// on the next
    public func day(_ date: Date, timeZone: TimeZone? = nil) -> String {
        unbroken(format(date, dateStyle: .medium, style: .none, timeZone: timeZone ?? self.timeZone))
    }

    /// Date and clock time, e.g. "Oct 14, 2026 at 6:00 PM", naming the zone like time().
    public func dayAndTime(_ date: Date, timeZone: TimeZone? = nil) -> String {
        let zone = timeZone ?? self.timeZone
        return format(date, dateStyle: .medium, style: .short, timeZone: zone, zone: showsZone(zone, at: date))
    }

    /// Like dayAndTime, with today and tomorrow in the language's own words from the system: "Today at 6:00 PM",
    /// "Tomorrow at 6:00 PM", and the full date and time (dayAndTime) for other days. A language the system has no such words for
    /// (Haitian Creole has no date data) keeps the date, as does any whose date can't be found in the text.
    public func dayAndTimeFromToday(_ date: Date, now: Date = Date(), timeZone: TimeZone? = nil) -> String {
        let timeZone = timeZone ?? self.timeZone
        let full = dayAndTime(date, timeZone: timeZone)
        guard Translations.dateNames(language) == nil else { return full }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day,
              days == 0 || days == 1 else { return full }
        // The date as dayAndTime writes it (the same template), to find it in the text
        let datePart = FormatterCache.date(locale: locale, timeZone: timeZone, dateStyle: .medium, template: "yMMMd").string(from: date)
        guard !datePart.isEmpty, let range = full.range(of: datePart) else { return full }
        // The system names the day relative to its own today, so ask it about the real today or tomorrow
        let today = Date()
        guard let sample = days == 0 ? today : calendar.date(byAdding: .day, value: 1, to: today) else { return full }
        let word = FormatterCache.relativeDay(locale: locale, timeZone: timeZone, startOfSentence: range.lowerBound == full.startIndex)
            .string(from: sample)
        let plain = FormatterCache.date(locale: locale, timeZone: timeZone, dateStyle: .medium, template: nil).string(from: sample)
        guard !word.isEmpty, word != plain else { return full }
        return full.replacingCharacters(in: range, with: word)
    }

    private func format(_ date: Date, dateStyle: DateFormatter.Style = .none, style: DateFormatter.Style,
                        timeZone: TimeZone, zone: Bool = false) -> String {
        // Clock time follows the 12 / 24-hour setting, not the locale default; "z" adds the short zone name where the locale puts it
        let time = style == .none ? nil : clock.template(seconds: style == .medium) + (zone ? "z" : "")
        // A language whose locale has no date data (Haitian Creole) writes dates with its bundled month names
        if dateStyle != .none, let names = Translations.dateNames(language) {
            return FormatterCache.date(locale: locale, timeZone: timeZone, names: names, dateTemplate: "yMMMd", timeTemplate: time)
                .string(from: date)
        }
        let template = time.map { (dateStyle == .none ? "" : "yMMMd") + $0 }
        return FormatterCache.date(locale: locale, timeZone: timeZone, dateStyle: dateStyle, template: template)
            .string(from: date)
    }

    /// Duration, rounded up to minutes, e.g. "7 min".
    public func minutes(_ seconds: TimeInterval) -> String {
        f("%@ min", number(max(0, (seconds / 60).rounded(.up))))
    }

    /// Duration: minutes under 1 hour ("30 min"), hours from 1 hour up ("2 hr", "1.5 hr").
    public func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, (seconds / 60).rounded())
        if m < 60 { return minutes(m * 60) }
        let h = m / 60
        return f("%@ hr", number(h, fractionDigits: h == h.rounded() ? 0 : 1))
    }

    /// Countdown, e.g. "in 6 min" / "Arriving now" / "At the stop now".
    /// Rounded down (together with walking time rounded up, it errs on the side of feeling tight, never off by a minute).
    public func countdown(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return t("No data") }
        // The train's time has passed, in something made a moment before (a widget entry, an open details view)
        if seconds < -30 { return t("At the stop now") }
        if seconds < 60 { return t("Arriving now") }
        return f("in %@ min", number((seconds / 60).rounded(.down)))
    }

    /// The countdown's short form, for where the full one doesn't fit: "6 min", and "Now" for both "Arriving now" and "At the
    /// stop now". Nil without a time. Rounded down like the full one, so the two never show different minutes
    public func shortCountdown(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        if seconds < 60 { return t("Now") }
        return f("%@ min", number((seconds / 60).rounded(.down)))
    }

    /// Margin with a sign: "+3 min" (you arrive first) / "−1 min" (you'll miss it); a margin under 1 minute is "under 1 min", not "+0 min".
    public func slack(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds >= 0, seconds < 60 { return t("under 1 min") }
        let m = Int((seconds / 60).rounded(.towardZero))
        let signed = seconds >= 0 ? "+\(m)" : "−\(max(1, abs(m)))"
        return f("%@ min", signed)
    }

    // MARK: - Distance and speed

    /// Distance, rounded to 10 meters or 10 feet, e.g. "950 m" / "3,100 ft". In right-to-left languages the whole of it is isolated,
    /// so the number stays before its unit next to other text ("1,590 ft", not "ft 1,590")
    public func distance(_ meters: Double) -> String {
        let value = (units.displayDistance(fromMeters: meters) / 10).rounded() * 10
        switch units {
        case .metric: return isolated(f("%@ m", number(value)))
        case .usCustomary: return isolated(f("%@ ft", number(value)))
        }
    }

    /// A rough distance, for "within about …": two figures ("350 m", "1,500 m", "4,900 ft", "16,000 ft"), isolated as a whole in
    /// right-to-left languages like distance
    public func roughDistance(_ meters: Double) -> String {
        let value = units.displayDistance(fromMeters: meters)
        // The step that keeps two figures: 10 below 1,000, 100 below 10,000, and so on
        let step = pow(10, max(1, log10(max(value, 1)).rounded(.down) - 1))
        let rounded = (value / step).rounded() * step
        switch units {
        case .metric: return isolated(f("%@ m", number(rounded)))
        case .usCustomary: return isolated(f("%@ ft", number(rounded)))
        }
    }

    /// Search radius (rounded the same as in Settings): feet to 100 ("4,000 ft"), meters to 10 ("1,220 m", the default converted from
    /// 4,000 ft). Isolated as a whole in right-to-left languages, like distance
    public func radius(_ meters: Double) -> String {
        let step: Double = units == .metric ? 10 : 100
        let value = (units.displayDistance(fromMeters: meters) / step).rounded() * step
        switch units {
        case .metric: return isolated(f("%@ m", number(value)))
        case .usCustomary: return isolated(f("%@ ft", number(value)))
        }
    }

    /// Walking speed, e.g. "4.5 km/h" / "2.8 mph".
    public func speed(kmh: Double) -> String {
        let value = units.displaySpeed(fromKmh: kmh)
        switch units {
        case .metric: return f("%@ km/h", number(value, fractionDigits: 1))
        case .usCustomary: return f("%@ mph", number(value, fractionDigits: 1))
        }
    }

    // MARK: - Subway

    /// Direction: prefer the direction name on station signage (e.g. "Uptown", "Manhattan"),
    /// otherwise the terminal, e.g. "To Woodlawn" (or its translation). Place names keep MTA's English spelling.
    /// Directions are always "To <terminal>", never phrasing like "Northbound" or "Outbound"; the subway keeps Uptown / Downtown.
    /// When nothing is known, write "Destination not listed" rather than guessing a compass direction.
    public func direction(_ d: Direction) -> String {
        if let label = d.label, let sign = signLabel(label) { return sign }
        if let terminal = d.terminal, !terminal.isEmpty { return f("To %@", terminal) }
        switch d.name {
        case "Uptown": return t("Uptown")
        case "Downtown": return t("Downtown")
        case "Brooklyn-bound": return t("Brooklyn-bound")
        case _ where Self.genericDirectionNames.contains(d.name) || d.name.isEmpty:
            return t("Destination not listed")
        default: return d.name
        }
    }

    /// Phrasings that only give a compass direction without saying where the train goes: not shown in the UI (the terminal is used instead).
    static let genericDirectionNames: Set<String> = [
        "Northbound", "Southbound", "Eastbound", "Westbound", "Outbound", "Inbound", "Last Stop",
    ]

    /// Signage direction names: Uptown / Downtown are translated; place names get "To" in front (e.g. "To Manhattan"),
    /// matching "To Flushing-Main St"; the place name itself stays in English (like the signs in stations).
    /// Names that don't say where it goes, like "Northbound", "Outbound", "Last Stop", return nil, and the caller uses the terminal instead.
    public func signLabel(_ label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespaces)
        if label.isEmpty || Self.genericDirectionNames.contains(label) { return nil }
        switch label {
        case "Uptown", "Downtown": return t(label)
        default: return f("To %@", label)
        }
    }

    /// Where this train is headed, e.g. "To Jamaica-179 St". nil when there's no terminal info.
    public func terminal(_ d: Direction) -> String? {
        guard let terminal = d.terminal, !terminal.isEmpty else { return nil }
        return f("To %@", terminal)
    }

    /// Title for one direction, e.g. "To Queens · Uptown". Lines without a signage direction name use the terminal;
    /// when trains in this direction go to several terminals, the title covers them all, not just the first train's: "To
    /// Flushing-Main St or Mets-Willets Point", and past two "To A, B, and 5 more" (the full list: directionTerminals).
    public func directionTitle(_ dir: BoardDirection) -> String {
        var names: [String] = []
        var terminals: [String] = []
        var terminalsAt: Int?
        for d in dir.directions {
            if d.label.flatMap(signLabel) == nil, let terminal = d.terminal, !terminal.isEmpty {
                if !terminals.contains(terminal) { terminals.append(terminal) }
                if terminalsAt == nil { terminalsAt = names.count; names.append("") }
                continue
            }
            let name = direction(d)
            if !names.contains(name) { names.append(name) }
        }
        if let i = terminalsAt { names[i] = toPlaces(terminals) }
        // Don't write "Northbound" for a direction we know nothing about
        let known = names.filter { $0 != t("Destination not listed") }
        if known.isEmpty { return t("Destination not listed") }
        return dotted(known)
    }

    /// The terminals a direction title names (directionTitle), in its order: the trains without a signage direction name.
    /// Past shownPlaces the title names only the first ones, and the station page lists them all from here
    public func directionTerminals(_ dir: BoardDirection) -> [String] {
        var terminals: [String] = []
        for d in dir.directions where d.label.flatMap(signLabel) == nil {
            if let terminal = d.terminal, !terminal.isEmpty, !terminals.contains(terminal) { terminals.append(terminal) }
        }
        return terminals
    }

    /// A direction title names at most this many terminals, then "and N more"
    public static let shownPlaces = 2

    /// "To A", "To A or B", "To A, B, and 5 more": the terminals trains in one direction go to (place names stay in English).
    /// A long list made titles of three lines cut off at the end
    public func toPlaces(_ places: [String]) -> String {
        guard let last = places.last else { return "" }
        if places.count == 1 { return f("To %@", last) }
        if places.count <= Self.shownPlaces { return f("To %1$@ or %2$@", places[0], last) }
        return f("To %1$@, %2$@, and %3$@ more", places[0], places[1], number(Double(places.count - Self.shownPlaces)))
    }

    /// Whether you can catch it. The main window, menu bar and widgets use the same wording (instead of three separate sets).
    /// All short enough to fit in widgets; no guarantees like "run for it" or "you'll make it".
    public func verdict(_ v: CatchVerdict) -> String {
        switch v {
        case .canTry: return t("Can try")
        case .tight: return t("Tight")
        case .takeNext: return t("Too soon")
        case .insufficientInfo: return t("Not sure")
        }
    }

    /// Short text for widgets and the menu bar (same as verdict).
    public func verdictShort(_ v: CatchVerdict) -> String { verdict(v) }

    /// What a verdict means, in one sentence, for the legend at the top of How It Works (after the verdict's icon and name)
    public func verdictMeaning(_ v: CatchVerdict) -> String {
        switch v {
        case .canTry: return t("You should reach the platform in time, with your safety buffer to spare.")
        case .tight: return t("You may just make it: less than your safety buffer to spare.")
        case .takeNext: return t("It leaves before you can get there. Its time is gray, and the line names the next one you can catch.")
        case .insufficientInfo: return t("The data is old or missing, so there's no telling.")
        }
    }

    /// Spare time, rounded down: "3 min"; under 1 minute, "under 1 min".
    public func spare(_ seconds: TimeInterval) -> String {
        let m = (max(0, seconds) / 60).rounded(.down)
        return m < 1 ? t("under 1 min") : f("%@ min", number(m))
    }

    /// Short caption: "16 min walk · Can try".
    public func shortCatchLine(_ e: CatchEvaluation) -> String {
        f("%@ walk", minutes(e.walk.walkSeconds)) + " · " + verdictShort(e.verdict)
    }

    /// Even shorter caption (when space is tight): "16 min · Can try".
    public func tinyCatchLine(_ e: CatchEvaluation) -> String {
        minutes(e.walk.walkSeconds) + " · " + verdictShort(e.verdict)
    }

    /// The full caption for one train (see catchLine).
    public func trainLine(_ train: BoardTrain) -> String {
        catchLine(train.evaluation, recommended: train.recommended)
    }

    /// What a screen reader says for one departure: one sentence of pieces already shown, joined with the language's comma (each
    /// piece isolated in right-to-left languages): the line, the station (`station`, at a group of stations), where it goes, the
    /// time, how soon, express or local, "Timetable", the walk, and whether you can catch it. e.g. "E, To Jamaica Center, 1:03 AM,
    /// in 3 min, 5 min walk, Too soon. Next one you can catch: 1:20 AM". The main window, the menu bar panel and the widgets read
    /// the same
    public func spokenDeparture(_ train: BoardTrain, station: String? = nil) -> String {
        let e = train.evaluation
        var pieces = [FerryFeed.spokenRouteName(train.route)]
        if let station { pieces.append(station) }
        pieces.append(terminal(train.direction) ?? direction(train.direction))
        pieces.append(arrivalTime(e))
        pieces.append(countdown(e.secondsUntilTrain))
        if let express = e.arrival.isExpress { pieces.append(serviceName(express: express, bus: e.arrival.busService)) }
        if e.arrival.isTimetableTime { pieces.append(t("Timetable")) }
        pieces.append(f("%@ walk", minutes(e.walk.walkSeconds)))
        pieces.append(catchJudgement(e, recommended: train.recommended))
        return commaList(pieces)
    }

    /// The word on a departure's service tag: Local, Limited, SBS or Express for a bus, Express or Local for a train
    public func serviceName(express: Bool, bus: BusService?) -> String {
        switch bus {
        case .local: return t("Local")
        case .limited: return t("Limited")
        case .selectBus: return t("SBS")
        case .express: return t("Express")
        case nil: return express ? t("Express") : t("Local")
        }
    }

    /// Start / Standby status, e.g. "On until 5:23 PM"; "On until 5:40 PM for a reminder" while a reminder still to come keeps it
    /// on past its auto-standby time (ActivityState.standbyAt)
    public func activityStatus(_ state: ActivityState, now: Date) -> String {
        guard state.isActive(at: now) else { return t("Standby") }
        guard let until = state.standbyAt else { return t("On") }
        if let usual = state.activeUntil, until > usual { return f("On until %@ for a reminder", time(until)) }
        return f("On until %@", time(until))
    }

    public func note(_ n: CatchNote) -> String {
        switch n {
        case .missingPrediction: return t("No prediction")
        case .staleRealtime: return t("Real-time data is out of date")
        case .scheduledOnly: return t("Scheduled, not real-time")
        case .walkEstimated: return t("Walk time estimated")
        case .acrossWater: return t("Across the water: the real walk may be much longer.")
        case .mockData: return t("Mock data")
        case .delayed: return t("Delayed")
        }
    }

    public func walkSource(_ s: WalkSource) -> String {
        switch s {
        case .route: return t("walking route")
        case .estimated: return t("estimated")
        }
    }

    /// Clock time the train reaches this station; shows "No time" without a prediction.
    public func arrivalTime(_ e: CatchEvaluation) -> String {
        e.arrival.arrivalTime.map { time($0, timeZone: e.arrival.stationTimeZone) } ?? t("Time unknown")
    }

    /// Keeps a clock time or a date on one line where it's inside a sentence that wraps: Japanese and Chinese may break a line between
    /// any two characters, which could split the two-character afternoon word of a Japanese time, and other languages break at the
    /// spaces in a date. A word joiner (U+2060, invisible) between the characters stops that.
    func unbroken(_ text: String) -> String {
        text.map(String.init).joined(separator: "\u{2060}")
    }

    /// Caption under a train: how long the walk is and whether you can catch it.
    /// e.g. "7 min walk · Can try, 3 min to spare".
    public func catchLine(_ e: CatchEvaluation, recommended: CatchEvaluation?) -> String {
        f("%@ walk", minutes(e.walk.walkSeconds)) + " · " + catchJudgement(e, recommended: recommended)
    }

    /// Whether you can catch it, in a sentence (catchLine without the walk): "Can try, 3 min to spare", "Too soon to catch".
    public func catchJudgement(_ e: CatchEvaluation, recommended: CatchEvaluation?) -> String {
        switch e.verdict {
        case .canTry, .tight:
            return f("%1$@, %2$@ to spare", verdict(e.verdict), spare(e.slackSeconds ?? 0))
        case .takeNext:
            if let rec = recommended, let arrivalTime = rec.arrival.arrivalTime {
                // Don't write train / bus / ferry (the same text serves every mode, NJ Transit buses and the tram included)
                return f("Too soon. Next one you can catch: %@", unbroken(time(arrivalTime, timeZone: rec.arrival.stationTimeZone)))
            }
            return t("Too soon to catch")
        case .insufficientInfo:
            // Can't tell for this one, but a later one can be caught: say which, as for "too soon"
            if let rec = recommended, let arrivalTime = rec.arrival.arrivalTime {
                return f("Not sure. Next one you can catch: %@", unbroken(time(arrivalTime, timeZone: rec.arrival.stationTimeZone)))
            }
            return verdict(.insufficientInfo)
        }
    }

    /// The time to spare when tight, e.g. "2 min to spare", "under 1 min to spare" (Plan a Trip's blocks; the main window says it
    /// after the verdict, see catchJudgement)
    public func toSpare(_ seconds: TimeInterval?) -> String {
        f("%@ to spare", spare(seconds ?? 0))
    }

    /// "Leave by 8:14 PM": the latest time to set off and still have "can try" (CatchEvaluation.latestLeave), with the clock time
    /// kept on one line. nil unless "can try".
    public func leaveBy(_ e: CatchEvaluation) -> String? {
        e.latestLeave.map { leaveBy(at: $0, timeZone: e.arrival.stationTimeZone) }
    }

    /// "Leave by 8:14 PM" for this time (leaveBy above, or a sample to measure), in the station's zone if it has its own
    public func leaveBy(at date: Date, timeZone: TimeZone? = nil) -> String {
        f("Leave by %@", unbroken(time(date, timeZone: timeZone)))
    }
}

/// Number and date formatters are kept per language and format for reuse (the main window formats hundreds of times every 5 seconds, and creating them each time is CPU-heavy).
/// NumberFormatter / DateFormatter are thread-safe when formatting; the dictionary itself is lock-protected.
enum FormatterCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var numbers: [String: NumberFormatter] = [:]
    nonisolated(unsafe) private static var dates: [String: DateFormatter] = [:]

    static func number(locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let key = locale.identifier + "|" + String(fractionDigits)
        lock.lock(); defer { lock.unlock() }
        if let f = numbers[key] { return f }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        numbers[key] = f
        return f
    }

    static func date(locale: Locale, timeZone: TimeZone, dateStyle: DateFormatter.Style, template: String?) -> DateFormatter {
        let key = [locale.identifier, timeZone.identifier, String(dateStyle.rawValue), template ?? "-"].joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let f = dates[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        if let template {
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
        } else {
            f.dateStyle = dateStyle
            f.timeStyle = .none
        }
        dates[key] = f
        return f
    }

    /// Today and tomorrow in the system's own words for the locale ("Today", "Tomorrow"); other days as the medium date.
    /// - Parameter startOfSentence: capitalized as at the start of a sentence, otherwise as in the middle of one
    static func relativeDay(locale: Locale, timeZone: TimeZone, startOfSentence: Bool) -> DateFormatter {
        let key = [locale.identifier, timeZone.identifier, "relative", startOfSentence ? "start" : "middle"].joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let f = dates[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        f.formattingContext = startOfSentence ? .beginningOfSentence : .middleOfSentence
        dates[key] = f
        return f
    }

    /// A date formatter that writes the bundled month and weekday names (for a language whose locale has no date data).
    /// The clock part still comes from the locale (it has times, just no dates), so 12 / 24 hours read as in time().
    static func date(locale: Locale, timeZone: TimeZone, names: DateNames, dateTemplate: String, timeTemplate: String?) -> DateFormatter {
        let key = [locale.identifier, timeZone.identifier, "names", dateTemplate, timeTemplate ?? "-"].joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let f = dates[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        names.apply(to: f)
        f.dateFormat = names.dateFormat(dateTemplate: dateTemplate, timeTemplate: timeTemplate, locale: locale)
        dates[key] = f
        return f
    }
}

/// Month and weekday names and date patterns for a language whose locale has no date data on macOS
/// (Resources/date_names.json; see AppLanguage.locale). Another language missing date data can get an entry there too.
struct DateNames: Decodable, Sendable {
    /// January to December
    let months: [String]
    let shortMonths: [String]
    /// Sunday to Saturday
    let weekdays: [String]
    let shortWeekdays: [String]
    /// Date pattern for each date template the app uses, e.g. "yMMMd" → "d MMM y"
    let patterns: [String: String]
    /// Between the date and the clock time, e.g. ", "
    let dateTimeSeparator: String
    /// A locale that has real date data, for the system date picker, which draws its own names (AppLanguage.datePickerLocale)
    let pickerLocale: String

    /// Every month and weekday has a name (a formatter given a short list could write blanks).
    var isComplete: Bool {
        months.count == 12 && shortMonths.count == 12 && weekdays.count == 7 && shortWeekdays.count == 7
    }

    /// The date pattern for a template (the locale's own order when the file has none), then the clock time from the locale.
    func dateFormat(dateTemplate: String, timeTemplate: String?, locale: Locale) -> String {
        let day = patterns[dateTemplate]
            ?? DateFormatter.dateFormat(fromTemplate: dateTemplate, options: 0, locale: locale) ?? dateTemplate
        guard let timeTemplate else { return day }
        let time = DateFormatter.dateFormat(fromTemplate: timeTemplate, options: 0, locale: locale) ?? timeTemplate
        return day + Self.quoted(dateTimeSeparator) + time
    }

    /// Puts the names into a formatter, for both the in-sentence and the standalone forms.
    func apply(to formatter: DateFormatter) {
        formatter.monthSymbols = months
        formatter.standaloneMonthSymbols = months
        formatter.shortMonthSymbols = shortMonths
        formatter.shortStandaloneMonthSymbols = shortMonths
        formatter.weekdaySymbols = weekdays
        formatter.standaloneWeekdaySymbols = weekdays
        formatter.shortWeekdaySymbols = shortWeekdays
        formatter.shortStandaloneWeekdaySymbols = shortWeekdays
    }

    /// Literal text in a date pattern, so its letters aren't read as fields ("'" is written "''").
    static func quoted(_ text: String) -> String {
        text.isEmpty ? "" : "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
