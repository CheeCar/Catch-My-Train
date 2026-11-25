import Foundation

/// "Report an Issue…" in Settings (Data source): GitHub's page for a new issue in the app's repository (the release
/// repository), its title and text filled in. The app sends nothing itself: the page opens in the
/// user's browser, where they read it and decide. It holds only what tells the problem apart: the app's and macOS's versions,
/// the operator, what looked wrong and since when, how many stops the data in use and the new data have (and when the data in
/// use was taken), and whether the live data still showed served what the new data leaves out; never a place, a favorite, where the user is, an account or the computer's name. Kept short (a very long address doesn't open) and without labels (setting one needs rights a reporter doesn't have)
public enum IssueReport {
    /// An operator's new data that wasn't used (DataChangeLog.Entry, outcome kept)
    public static func dataProblem(_ entry: DataChangeLog.Entry, appVersion: String, macOS: String) -> URL {
        let name = DataChangeLog.operatorName(of: entry.key)
        let problem: String
        switch entry.reason {
        case .empty?: problem = "the new data lists no stops"
        case .stopsGone?: problem = "the new data looks incomplete (most stops gone)"
        case .countJump?: problem = "the number of stops in the new data changed too much"
        case nil: problem = "the new data wasn't used"
        }
        func day(_ date: Date) -> String {
            ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        }
        // The live data still showing served what the new data leaves out (DataWitness): a sign the new data is wrong
        let live = entry.missing?.liveSeenAt.map {
            "Live data: still shows trips at stops or lines missing from the new data (last seen \(day($0)))\n"
        } ?? ""
        // How far the new data is from the data in use (entries written before these were kept have none)
        let stops = entry.stopsInUse.map { inUse in
            "Stops: \(inUse) in the data in use" + (entry.inUseSince.map { " (from \(day($0)))" } ?? "")
                + (entry.stopsNew.map { ", \($0) in the new data" } ?? "") + "\n"
        } ?? ""
        let body = """
            App version: \(appVersion)
            macOS: \(macOS)
            Operator: \(name) (\(entry.key))
            Problem: \(problem)
            Since: \(day(entry.notUsedSince))
            Changes the new data would make: \(entry.count)
            \(stops)\(live)
            """
        return newIssue(title: "Data problem: \(name)", body: body)
    }

    /// What the data in use has that this version doesn't know (UnknownData): each operator, the kind, how many and the first
    /// few of the data's own ids (stations, lines, live data codes: no names)
    public static func unknownData(_ findings: [UnknownData.Finding], appVersion: String, macOS: String) -> URL {
        let names = findings.map { DataChangeLog.operatorName(of: $0.key) }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        let found = findings.prefix(6).map { f in
            let kind: String
            switch f.kind {
            case .stations: kind = "stations whose live trains can't be shown"
            case .lines: kind = "lines shown with the operator's own codes"
            case .directions: kind = "stations without signage directions"
            }
            let ids = f.ids.prefix(5).joined(separator: ", ") + (f.ids.count > 5 ? ", …" : "")
            return "Operator: \(DataChangeLog.operatorName(of: f.key)) (\(f.key))\nNew to this version: \(f.ids.count) \(kind) (\(ids))\n"
        }.joined()
        let body = """
            App version: \(appVersion)
            macOS: \(macOS)
            \(found)
            """
        return newIssue(title: "Data new to this version: " + unique.prefix(3).joined(separator: ", "), body: body)
    }

    /// The page for a new issue with this title and text
    static func newIssue(title: String, body: String) -> URL {
        let query = [("title", title), ("body", body)].map { "\($0.0)=\(encoded($0.1))" }.joined(separator: "&")
        return URL(string: "https://github.com/\(UpdateCheck.Channel.release.repository)/issues/new?" + query)!
    }

    /// Everything but letters, digits and "-._~" written as %XX, so an operator's "&" or "+" stays part of the text
    static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension DataChangeLog {
    /// An operator's name by its key in the log, in English (operators' names aren't translated; Settings writes the two MTA
    /// station lists in the app's language itself)
    public static func operatorName(of key: String) -> String {
        if key == subwayKey { return "MTA subway" }
        if key == cityBusKey { return "MTA buses" }
        if key.hasPrefix("bus:") {
            let code = String(key.dropFirst(4))
            return code.isEmpty ? RegionalBusFeed.njTransit.name : RegionalBusFeed.feed(code: code)?.name ?? code
        }
        return FerryFeed.Source(rawValue: key)?.name ?? key
    }
}
