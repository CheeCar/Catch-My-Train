import Foundation

/// A second way to ask the place search when the text as typed finds nothing. A name with its town after a comma
/// ("Springfield Union Station, Springfield MA") can find nothing where the name alone finds the place: the text is then asked
/// again without its last part, and the results that mention the part left out are listed first.
///
/// One per search field. `reset` when the field's text changes; results are used only while `isCurrent` says they are for the
/// text the field shows (as typed, or the simpler text asked for it).
public struct SearchRetry: Equatable, Sendable {
    /// The text in the field the simpler one was asked for, and the simpler text
    private var typed: String?
    private var asked: String?

    public init() {}

    /// How many suggestions a search field lists at most
    public static let listedAtMost = 8

    /// The text without its last part (what follows the last comma), or nil when there is no such part or too little is left
    /// to search for
    public static func simpler(_ text: String) -> String? {
        guard let comma = text.lastIndex(of: ",") else { return nil }
        let head = text[..<comma].trimmingCharacters(in: .whitespaces)
        let tail = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, head.count >= USAddress.nothingFoundFrom else { return nil }
        return head
    }

    /// The field's text changed, a suggestion was picked or the search stopped: nothing simpler is being asked any more
    public mutating func reset() {
        typed = nil
        asked = nil
    }

    /// Results that arrived for `fragment` fit a field showing `query`: they are for that text, or for the simpler text asked
    /// in its place
    public func isCurrent(fragment: String, query: String) -> Bool {
        USAddress.suggestionsAreCurrent(fragment: fragment, query: query)
            || (USAddress.isSearchable(query) && typed == query && asked == fragment)
    }

    /// Nothing was found for `fragment` (current for `query`, see isCurrent): the simpler text to ask next, or nil when there
    /// is none left. The answer is remembered, so its results count as current
    public mutating func next(after fragment: String, query: String) -> String? {
        guard isCurrent(fragment: fragment, query: query), let simpler = Self.simpler(fragment) else { return nil }
        typed = query
        asked = simpler
        return simpler
    }

    /// The part of the field's text left out of the simpler one asked ("" when the text was asked as typed)
    public var leftOut: String {
        guard let typed, let asked, typed.hasPrefix(asked) else { return "" }
        return String(typed.dropFirst(asked.count))
    }

    /// The suggestions to list: when a simpler text was asked, the ones that mention more of the words left out come first
    /// (otherwise in the order they came in); at most `listedAtMost`. `text` is what a suggestion says (its name and address):
    /// two that say the same are one choice to the user (Apple Maps can give a place twice), so only the first is listed
    public func listed<T>(_ items: [T], text: (T) -> String) -> [T] {
        var said = Set<String>()
        let items = items.filter { said.insert(text($0)).inserted }
        let wanted = Self.words(leftOut)
        guard !wanted.isEmpty else { return Array(items.prefix(Self.listedAtMost)) }
        let scored = items.enumerated().map { item -> (index: Int, hits: Int, value: T) in
            let said = Set(Self.words(text(item.element)))
            return (item.offset, wanted.filter(said.contains).count, item.element)
        }
        return scored.sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.index < $1.index }
            .prefix(Self.listedAtMost).map(\.value)
    }

    /// The words of a text, in lower case, each once
    static func words(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { seen.insert($0).inserted }
    }
}
