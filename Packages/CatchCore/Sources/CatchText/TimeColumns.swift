import Foundation
import TransitCore

/// The trip planner's time picker: an hour column, a minute column and, on a 12-hour clock, an AM/PM column, each picked with one click.
/// The columns follow the way this language writes a clock time in the rest of the app (AppText.time), so they read like the time
/// on the Leave at button: the 12 / 24-hour setting, the AM/PM column first where the language writes it first (Chinese, Japanese,
/// Korean), Japanese hours counted 0–11, two-digit hours where the language writes them. Digits are always 0–9, as everywhere in
/// the app. A right-to-left layout mirrors the columns. Times are in the text's time zone (the departure place's metro area's), like the timetables.
public struct TimeColumns: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case hour, minute, period
    }

    public struct Cell: Hashable, Sendable {
        /// Hour: 0–23 on a 24-hour clock, the hour within the half day (0–11) on a 12-hour one; minute: 0–59; period: 0 = AM, 1 = PM
        public let value: Int
        public let text: String
    }

    /// The columns in reading order
    public let kinds: [Kind]
    private let hours: [Cell]
    private let minutes: [Cell]
    private let periods: [Cell]
    private let twelveHour: Bool
    private let calendar: Calendar

    public init(text: AppText, calendar: Calendar? = nil) {
        let pattern = DateFormatter.dateFormat(fromTemplate: text.clock.template(seconds: false), options: 0, locale: text.locale)
            ?? text.clock.template(seconds: false)
        let fields = Self.fields(in: pattern)
        // The hour letter: h = 1–12, K = 0–11, H = 0–23, k = 1–24 (the 12 / 24-hour setting asks for h or H; the language may answer K)
        let letter = fields.hour?.letter ?? (text.clock == .twelveHour ? "h" : "H")
        let padded = (fields.hour?.length ?? 1) >= 2
        let twelve = letter == "h" || letter == "K"
        let hourValues = twelve ? Array(0...11) : letter == "k" ? Array(1...23) + [0] : Array(0...23)
        hours = hourValues.map { value in
            let shown = letter == "h" && value == 0 ? 12 : letter == "k" && value == 0 ? 24 : value
            return Cell(value: value, text: padded ? Self.twoDigits(shown) : String(shown))
        }
        minutes = (0...59).map { Cell(value: $0, text: Self.twoDigits($0)) }
        // AM and PM in this language's words, the same ones its clock times use
        let formatter = DateFormatter()
        formatter.locale = text.locale
        let am: String = formatter.amSymbol
        let pm: String = formatter.pmSymbol
        periods = [Cell(value: 0, text: am), Cell(value: 1, text: pm)]
        twelveHour = twelve
        if twelve {
            let periodFirst = fields.period.map { $0 < (fields.hour?.position ?? .max) } ?? false
            kinds = periodFirst ? [.period, .hour, .minute] : [.hour, .minute, .period]
        } else {
            kinds = [.hour, .minute]
        }
        self.calendar = calendar ?? Timetable.calendar(in: text.timeZone)
    }

    /// Every cell of a column, top to bottom
    public func cells(_ kind: Kind) -> [Cell] {
        switch kind {
        case .hour: return hours
        case .minute: return minutes
        case .period: return twelveHour ? periods : []
        }
    }

    /// The selected cell's value in a column for this time
    public func selected(_ kind: Kind, in date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        switch kind {
        case .hour: return twelveHour ? hour % 12 : hour
        case .minute: return parts.minute ?? 0
        case .period: return hour >= 12 ? 1 : 0
        }
    }

    /// The time with a cell picked: the same day, the other columns kept, seconds dropped.
    /// On the night the clocks go forward, an hour that doesn't exist that night moves on an hour.
    public func setting(_ kind: Kind, to value: Int, in date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var hour = parts.hour ?? 0
        var minute = parts.minute ?? 0
        switch kind {
        case .hour: hour = twelveHour ? value % 12 + (hour >= 12 ? 12 : 0) : value
        case .minute: minute = value
        case .period: hour = hour % 12 + (value == 1 ? 12 : 0)
        }
        var picked = DateComponents()
        picked.year = parts.year
        picked.month = parts.month
        picked.day = parts.day
        picked.hour = hour
        picked.minute = minute
        picked.second = 0
        return calendar.date(from: picked) ?? date
    }

    /// The time with the next cell up (−1) or down (+1) picked in a column, for the arrow keys; nil past the first or last cell
    public func stepping(_ kind: Kind, by offset: Int, in date: Date) -> Date? {
        let list = cells(kind)
        let now = selected(kind, in: date)
        guard let index = list.firstIndex(where: { $0.value == now }), list.indices.contains(index + offset) else { return nil }
        return setting(kind, to: list[index + offset].value, in: date)
    }

    /// The column's name for VoiceOver: "Hour", "Minute", or the language's AM and PM ("AM/PM")
    public func name(_ kind: Kind, text: AppText) -> String {
        switch kind {
        case .hour: return text.t("Hour")
        case .minute: return text.t("Minute")
        case .period: return periods.map(\.text).joined(separator: "/")
        }
    }

    // MARK: - Reading the clock pattern

    struct Fields {
        /// The hour field: its letter, where it starts and how many letters long it is
        var hour: (letter: Character, position: Int, length: Int)?
        /// Where the AM/PM field starts
        var period: Int?
    }

    /// Finds the hour and AM/PM fields in a date format pattern such as "h:mm a" or "ah:mm" (text in quotes is skipped)
    static func fields(in pattern: String) -> Fields {
        var result = Fields()
        var quoted = false
        let letters = Array(pattern)
        var i = 0
        while i < letters.count {
            let c = letters[i]
            if c == "'" {
                quoted.toggle()
                i += 1
                continue
            }
            var length = 1
            while i + length < letters.count, letters[i + length] == c { length += 1 }
            if !quoted {
                if "hHkK".contains(c), result.hour == nil { result.hour = (c, i, length) }
                if "abB".contains(c), result.period == nil { result.period = i }
            }
            i += length
        }
        return result
    }

    static func twoDigits(_ n: Int) -> String {
        n < 10 ? "0" + String(n) : String(n)
    }
}
