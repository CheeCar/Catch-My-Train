import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Source list
//
// Where each operator's data is downloaded from, and the stations without times, in one small JSON file. The app comes with a copy
// (Resources/source-list.json, kept the same as the addresses in code by a test) and once a month asks the project's repository on
// GitHub for the current one (see the app's SourceListStore), so an address that moved, or a pier that was added, can be fixed without
// an app update. A list is used only when every check in `validate` passes; otherwise the last good one stays in use. IDs the app
// doesn't know are skipped, and a download the list leaves out keeps the address in code. Addresses that need the user's own key or
// account (MTA Bus Time, NJ Transit's live data, Swiftly) are never in it: how to sign in to them is in code.
//
// When an address changes: change it in the file in the repository first (apps pick it up at their next check), then in code before
// the next version, together with the file's "updated" day (`builtInUpdated`), or the test that keeps the two the same fails.

public struct SourceList: Codable, Sendable, Equatable {
    /// The list format this version reads. A list in a newer format isn't used (a newer app wrote it)
    public static let format = 1
    /// A larger file isn't read (the list is a few dozen KB)
    public static let maxBytes = 256 * 1024
    /// At most this many operators, counting the operators of the stations without times, can be turned off by one list, so a bad
    /// list can't take every operator away
    public static let maxTurnedOff = 5
    /// The file's place in the repository: the copy that comes with the app is the same file
    public static let repositoryPath = "Packages/CatchCore/Sources/TransitCore/Resources/source-list.json"
    /// Saved under this name next to the downloaded data
    public static let fileName = "source-list.json"
    /// The day the list in code was last changed (see the note at the top)
    static let builtInUpdated = "2026-11-22"

    public var format: Int
    /// The day the list was last changed (year-month-day), shown in Settings
    public var updated: String
    public var operators: [Operator]
    /// nil: the stations without times in code
    public var stationsWithoutTimes: StationsWithoutTimes?

    public init(format: Int, updated: String, operators: [Operator], stationsWithoutTimes: StationsWithoutTimes?) {
        self.format = format
        self.updated = updated
        self.operators = operators
        self.stationsWithoutTimes = stationsWithoutTimes
    }

    /// One download (or two: an operator's timetable and its free live data)
    public struct Operator: Codable, Sendable, Equatable {
        /// Which download it is (see `known`): stays the same when a name or an address changes
        public var id: String
        /// For people reading the file; the app uses its own names
        public var name: String
        public var timetable: String?
        public var realtime: String?
        /// false turns the operator off: nothing of it is downloaded, and it's left out as if the app didn't have it. Left out: on
        public var enabled: Bool?

        public init(id: String, name: String, timetable: String? = nil, realtime: String? = nil, enabled: Bool? = nil) {
            self.id = id
            self.name = name
            self.timetable = timetable
            self.realtime = realtime
            self.enabled = enabled
        }
    }

    /// The stations without times (see NoTimesStations): the operators, then their stations
    public struct StationsWithoutTimes: Codable, Sendable, Equatable {
        public var operators: [Agency]
        public var stations: [Place]

        public init(operators: [Agency], stations: [Place]) {
            self.operators = operators
            self.stations = stations
        }
    }

    /// An operator of stations without times (see NoTimesAgency)
    public struct Agency: Codable, Sendable, Equatable {
        /// Its part of its stations' IDs: don't change it (favorites and recent places keep the IDs)
        public var key: String
        public var name: String
        public var shortName: String
        /// "subway" or "ferry": the mode whose lists show its stations
        public var mode: String
        /// How often it runs where its own website says so, in minutes: [fewest, most]
        public var headwayMinutes: [Int]?
        public var crossesWater: Bool?
        /// false turns it off, like an operator's
        public var enabled: Bool?

        public init(key: String, name: String, shortName: String, mode: String, headwayMinutes: [Int]? = nil,
                    crossesWater: Bool? = nil, enabled: Bool? = nil) {
            self.key = key
            self.name = name
            self.shortName = shortName
            self.mode = mode
            self.headwayMinutes = headwayMinutes
            self.crossesWater = crossesWater
            self.enabled = enabled
        }
    }

    /// A station without times
    public struct Place: Codable, Sendable, Equatable {
        /// Its operator's key
        public var agency: String
        /// The rest of the station's ID ("notimes:<operator>:<id>"): don't change it either
        public var id: String
        public var name: String
        public var latitude: Double
        public var longitude: Double
        /// The operator's own page for it
        public var website: String

        enum CodingKeys: String, CodingKey {
            case agency = "operator", id, name, latitude, longitude, website
        }

        public init(agency: String, id: String, name: String, latitude: Double, longitude: Double, website: String) {
            self.agency = agency
            self.id = id
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.website = website
        }
    }
}

// MARK: - The downloads in code

extension SourceList {
    /// One download the app has an address for in code
    struct Known: Sendable {
        let id: String
        let name: String
        let timetable: URL?
        let realtime: URL?
        /// The list may turn it off: the operators whose timetables are downloaded. MTA's subway and bus data and the tram come with
        /// the app, and the subway is the app's base
        let canTurnOff: Bool
        /// The name its live data's notices go by (see RateLimit.provider(forHost:)), for an address on a server the app doesn't know
        let realtimeProvider: String?
    }

    /// Every download, in the list's order: MTA's subway data and its live data groups, MTA's bus data, the tram, the operators whose
    /// timetables are downloaded (FerryFeed.Source), then the other timetable bus operators (RegionalBusFeed)
    static let known: [Known] = {
        var all = [Known(id: "mta-subway", name: "MTA Subway", timetable: SubwayMap.builtInSourceURL, realtime: nil,
                         canTurnOff: false, realtimeProvider: nil)]
        for feed in MTAFeed.allCases {
            all.append(Known(id: feed.listID, name: "MTA Subway (\(feed.displayName))", timetable: nil, realtime: feed.builtInURL,
                             canTurnOff: false, realtimeProvider: "MTA"))
        }
        for (part, url) in zip(BusMap.parts, BusMap.builtInSourceURLs) {
            all.append(Known(id: BusMap.listID(part.code), name: part.name, timetable: url, realtime: nil, canTurnOff: false,
                             realtimeProvider: nil))
        }
        all.append(Known(id: RooseveltIslandTram.listID, name: ModeCoverage.tram, timetable: RooseveltIslandTram.builtInSourceURL,
                         realtime: nil, canTurnOff: false, realtimeProvider: nil))
        for source in FerryFeed.Source.allCases {
            let realtime = source == .path ? PathLive.builtInURL : source.builtInRealtimeURL
            let provider: String?
            switch source {
            case .lirr, .metroNorth: provider = "MTA"
            case .path: provider = "PATH"
            default: provider = realtime == nil ? nil : source.name
            }
            all.append(Known(id: source.rawValue, name: source.name, timetable: source.builtInURL, realtime: realtime,
                             canTurnOff: true, realtimeProvider: provider))
        }
        for feed in RegionalBusFeed.builtIn where !feed.code.isEmpty {
            all.append(Known(id: feed.listID, name: feed.name, timetable: feed.builtInURL, realtime: feed.builtInRealtimeURL,
                             canTurnOff: true, realtimeProvider: feed.builtInRealtimeURL == nil ? nil : feed.name))
        }
        return all
    }()

    private static let knownByID: [String: Known] = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func known(_ id: String) -> Known? { knownByID[id] }

    /// The list in code: the copy that comes with the app is the same (a test keeps them so)
    public static let builtIn = SourceList(
        format: format, updated: builtInUpdated,
        operators: known.map { Operator(id: $0.id, name: $0.name, timetable: $0.timetable?.absoluteString, realtime: $0.realtime?.absoluteString) },
        stationsWithoutTimes: StationsWithoutTimes(
            operators: NoTimesStations.builtInAgencies.map {
                Agency(key: $0.key, name: $0.name, shortName: $0.shortName, mode: $0.mode.rawValue,
                       headwayMinutes: $0.headwayMinutes.map { [$0.lowerBound, $0.upperBound] }, crossesWater: $0.crossesWater ? true : nil)
            },
            stations: NoTimesStations.builtInStations.map {
                Place(agency: $0.agency.key, id: String($0.id.dropFirst(NoTimesStations.idPrefix.count + $0.agency.key.count + 1)),
                      name: $0.name, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, website: $0.website.absoluteString)
            }))
}

// MARK: - Checking a list

extension SourceList {
    /// Why a list isn't used (only logged, never shown)
    public enum Rejection: Error, Equatable, Sendable {
        case tooLarge
        case unreadable
        /// Written for a newer app version
        case newerFormat
        /// This field is wrong (e.g. "operators[3].timetable")
        case badField(String)
        /// This address is on a server, or in a folder, the app doesn't download this from (e.g. "nyf.timetable", or
        /// "stationsWithoutTimes.stations[3].website"): see validate
        case otherServer(String)
        /// Turns off more than `maxTurnedOff`
        case turnsOffTooMany
    }

    /// A downloaded or saved file as a list, if every check passes
    public static func checked(_ data: Data) throws -> SourceList {
        guard data.count <= maxBytes else { throw Rejection.tooLarge }
        let list: SourceList
        do {
            list = try JSONDecoder().decode(SourceList.self, from: data)
        } catch {
            throw Rejection.unreadable
        }
        try list.validate()
        return list
    }

    /// Every rule a list has to follow. One wrong field and the whole list isn't used. Whoever can change the file can't send the
    /// app elsewhere: an address may only move within the server and first folder of the one in code (see isMove), and a station's
    /// website may only be on a server the stations in code link to
    public func validate() throws {
        guard format <= Self.format else { throw Rejection.newerFormat }
        guard format == Self.format else { throw Rejection.badField("format") }
        guard Self.day(updated) != nil else { throw Rejection.badField("updated") }
        guard (1...200).contains(operators.count) else { throw Rejection.badField("operators") }
        var ids = Set<String>()
        var turnedOff = 0
        for (i, o) in operators.enumerated() {
            let at = "operators[\(i)]"
            guard Self.isKey(o.id, max: 40), ids.insert(o.id).inserted else { throw Rejection.badField(at + ".id") }
            guard Self.isName(o.name, max: 80) else { throw Rejection.badField(at + ".name") }
            if let t = o.timetable, !Self.isAddress(t) { throw Rejection.badField(at + ".timetable") }
            if let r = o.realtime, !Self.isAddress(r) { throw Rejection.badField(at + ".realtime") }
            // Only the kinds of data the code has an address for are used (see Applied), so only those are compared
            if let known = Self.known(o.id) {
                if let t = o.timetable, let built = known.timetable, !Self.isMove(t, from: built) {
                    throw Rejection.otherServer(o.id + ".timetable")
                }
                if let r = o.realtime, let built = known.realtime, !Self.isMove(r, from: built) {
                    throw Rejection.otherServer(o.id + ".realtime")
                }
            }
            // An ID the app doesn't know is skipped, also when it's turned off
            if o.enabled == false, let known = Self.known(o.id) {
                guard known.canTurnOff else { throw Rejection.badField(at + ".enabled") }
                turnedOff += 1
            }
        }
        if let s = stationsWithoutTimes {
            guard (1...50).contains(s.operators.count) else { throw Rejection.badField("stationsWithoutTimes.operators") }
            guard (1...500).contains(s.stations.count) else { throw Rejection.badField("stationsWithoutTimes.stations") }
            var keys = Set<String>()
            for (i, a) in s.operators.enumerated() {
                let at = "stationsWithoutTimes.operators[\(i)]"
                guard Self.isKey(a.key, max: 40), keys.insert(a.key).inserted else { throw Rejection.badField(at + ".key") }
                guard Self.isName(a.name, max: 60) else { throw Rejection.badField(at + ".name") }
                guard Self.isName(a.shortName, max: 40) else { throw Rejection.badField(at + ".shortName") }
                guard Self.noTimesModes.contains(a.mode) else { throw Rejection.badField(at + ".mode") }
                if let h = a.headwayMinutes {
                    guard h.count == 2, (1...240).contains(h[0]), (h[0]...240).contains(h[1]) else {
                        throw Rejection.badField(at + ".headwayMinutes")
                    }
                }
                if a.enabled == false { turnedOff += 1 }
            }
            var places = Set<String>()
            var used = Set<String>()
            for (i, p) in s.stations.enumerated() {
                let at = "stationsWithoutTimes.stations[\(i)]"
                guard keys.contains(p.agency) else { throw Rejection.badField(at + ".operator") }
                guard Self.isKey(p.id, max: 60), places.insert(p.agency + ":" + p.id).inserted else { throw Rejection.badField(at + ".id") }
                guard Self.isName(p.name, max: 80) else { throw Rejection.badField(at + ".name") }
                guard p.latitude.isFinite, p.longitude.isFinite,
                      ServiceArea.contains(Coordinate(latitude: p.latitude, longitude: p.longitude)) else {
                    throw Rejection.badField(at + ".position")
                }
                guard Self.isAddress(p.website) else { throw Rejection.badField(at + ".website") }
                guard Self.isWebsite(p.website) else { throw Rejection.otherServer(at + ".website") }
                used.insert(p.agency)
            }
            // An operator with no station left is a list cut short, not one meant to be empty
            guard used == keys else { throw Rejection.badField("stationsWithoutTimes.operators") }
        }
        guard turnedOff <= Self.maxTurnedOff else { throw Rejection.turnsOffTooMany }
    }

    /// The modes stations without times can be listed in (the nearby lists of the other modes don't take them)
    static let noTimesModes: Set<String> = [TransitSystem.subway.rawValue, TransitSystem.ferry.rawValue]

    private static let letters: ClosedRange<Unicode.Scalar> = "a"..."z"
    private static let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
    private static let hyphen: Unicode.Scalar = "-"

    /// Lowercase letters, digits and hyphens, starting with a letter or digit
    static func isKey(_ s: String, max: Int) -> Bool {
        guard (1...max).contains(s.count), let first = s.unicodeScalars.first, first != hyphen else { return false }
        return s.unicodeScalars.allSatisfy { letters.contains($0) || digits.contains($0) || $0 == hyphen }
    }

    /// Not empty, not too long, and on one line
    static func isName(_ s: String, max: Int) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && s.count <= max && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// An https address with a server name and nothing to sign in with
    static func isAddress(_ s: String) -> Bool {
        guard s.count <= 500, let url = URL(string: s), url.scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    /// Whether a list's address only moves the one in code within its server and first folder: the same server (any case) and port,
    /// and below the same first folder ("s3.amazonaws.com/datatools-511ny/…" only within that bucket). An address in code at the
    /// server's top ("rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip") has no folder to keep: the same server is enough. A path that
    /// steps back up a folder ("..", also written with percent signs) never counts
    static func isMove(_ s: String, from built: URL) -> Bool {
        guard !s.contains("\\"), let url = URL(string: s), let host = url.host, let builtHost = built.host,
              host.lowercased() == builtHost.lowercased(), url.port == built.port else { return false }
        // Read decoded, as a server may: "/a/b" splits into "", "a", "b"
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let builtParts = built.path.split(separator: "/", omittingEmptySubsequences: false)
        guard builtParts.count > 2 else { return true }
        return parts.count > 2 && parts[0].isEmpty && parts[1] == builtParts[1]
    }

    /// The servers the stations without times in code link to (their operators' own websites)
    static let websiteHosts: Set<String> = Set(NoTimesStations.builtInStations.compactMap { $0.website.host?.lowercased() })

    /// A station's website on one of those servers
    static func isWebsite(_ s: String) -> Bool {
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return false }
        return url.port == nil && websiteHosts.contains(host)
    }

    /// A day written year-month-day, as the list's "updated" is, as that day at noon in this Mac's time zone (`zone`), where it's
    /// shown: the list is the whole app's, no one metro area's
    public static func day(_ text: String, in zone: TimeZone = .autoupdatingCurrent) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m), (1...31).contains(d) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: y, month: m, day: d, hour: 12)
        guard let date = calendar.date(from: components), calendar.component(.month, from: date) == m,
              calendar.component(.day, from: date) == d else { return nil }
        return date
    }

    /// The day this list was last changed
    public var updatedDay: Date? { Self.day(updated) }

    /// Of several lists (the saved one first), the one changed last: the copy in a newer app version can be newer than a list
    /// downloaded before the update. On the same day the earlier one in the order wins
    public static func newest(_ lists: [SourceList?]) -> SourceList? {
        var best: SourceList?
        for case let list? in lists where best.map({ list.updated > $0.updated }) ?? true { best = list }
        return best
    }
}

// MARK: - The list in use

extension SourceList {
    /// A checked list, worked out once when it's put in use: every address the app downloads, what's turned off, the stations without times
    public struct Applied: Sendable {
        public let list: SourceList
        /// By ID: the list's address, or the one in code where the list has none. Only the kinds of data the code has an address for:
        /// a list can move an address (within its server and first folder, see validate) but not add live data the app has never read
        let timetables: [String: URL]
        let realtime: [String: URL]
        /// Operators the list turned off (IDs)
        public let turnedOff: Set<String>
        /// The server names of the live data addresses and the names their notices go by
        let realtimeProviders: [String: String]
        let buses: [RegionalBusFeed]
        let noTimesAgencies: [NoTimesAgency]
        let noTimesStations: [NoTimesStation]
        let noTimesByID: [String: NoTimesStation]

        /// Only use a checked list (see validate)
        init(_ list: SourceList) {
            self.list = list
            let given = Dictionary(list.operators.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var timetables: [String: URL] = [:]
            var realtime: [String: URL] = [:]
            var providers: [String: String] = [:]
            var off = Set<String>()
            for known in SourceList.known {
                let entry = given[known.id]
                if let built = known.timetable { timetables[known.id] = entry?.timetable.flatMap(URL.init(string:)) ?? built }
                if let built = known.realtime {
                    let url = entry?.realtime.flatMap(URL.init(string:)) ?? built
                    realtime[known.id] = url
                    if let host = url.host?.lowercased(), let name = known.realtimeProvider { providers[host] = name }
                }
                if entry?.enabled == false, known.canTurnOff { off.insert(known.id) }
            }
            self.timetables = timetables
            self.realtime = realtime
            turnedOff = off
            realtimeProviders = providers
            buses = RegionalBusFeed.builtIn.filter { !off.contains($0.listID) }

            guard let s = list.stationsWithoutTimes else {
                noTimesAgencies = NoTimesStations.builtInAgencies
                noTimesStations = NoTimesStations.builtInStations
                noTimesByID = NoTimesStations.builtInByID
                return
            }
            var agencies: [String: NoTimesAgency] = [:]
            var order: [NoTimesAgency] = []
            for a in s.operators where a.enabled != false {
                guard let mode = TransitSystem(rawValue: a.mode) else { continue }
                let headway = a.headwayMinutes.flatMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
                let agency = NoTimesAgency(key: a.key, name: a.name, shortName: a.shortName, mode: mode, headwayMinutes: headway,
                                           crossesWater: a.crossesWater ?? false)
                agencies[a.key] = agency
                order.append(agency)
            }
            noTimesAgencies = order
            noTimesStations = s.stations.compactMap { p in
                guard let agency = agencies[p.agency], let website = URL(string: p.website) else { return nil }
                return NoTimesStation(id: NoTimesStations.idPrefix + agency.key + ":" + p.id, name: p.name,
                                      coordinate: Coordinate(latitude: p.latitude, longitude: p.longitude), agency: agency, website: website)
            }
            noTimesByID = Dictionary(noTimesStations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var inUse: Applied?
    private static let builtInApplied = Applied(builtIn)

    /// The list in use: put in use by the app at launch and after a check (see use); until then, and in the widget, the one in code
    public static var current: Applied {
        lock.lock()
        let applied = inUse
        lock.unlock()
        return applied ?? builtInApplied
    }

    /// Uses this list from now on (a checked one: see checked). Returns whether what's turned off or the stations without times changed,
    /// which the data already loaded has to be read again for
    @discardableResult
    public static func use(_ list: SourceList) -> Bool {
        let applied = Applied(list)
        lock.lock()
        let before = inUse ?? builtInApplied
        inUse = applied
        lock.unlock()
        return before.turnedOff != applied.turnedOff || before.list.stationsWithoutTimes != applied.list.stationsWithoutTimes
    }

    /// For tests: back to the list in code
    public static func reset() {
        lock.lock()
        inUse = nil
        lock.unlock()
    }

    /// The timetable address for this ID (nil when the code has none)
    public static func timetableURL(for id: String) -> URL? { current.timetables[id] }

    /// The free live data address for this ID (nil when the code has none)
    public static func realtimeURL(for id: String) -> URL? { current.realtime[id] }

    /// Turned off by the list in use
    public static func isTurnedOff(_ id: String) -> Bool { current.turnedOff.contains(id) }

    /// The name a live data server's notices go by, for a server only the list names
    public static func provider(forHost host: String) -> String? { current.realtimeProviders[host.lowercased()] }

    /// The copy that comes with the app (nil only if it's missing or broken, which a test rules out)
    public static func bundled() -> SourceList? {
        guard let url = Bundle.module.url(forResource: "source-list", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? checked(data)
    }
}

// MARK: - Asking GitHub for the current list

extension SourceList {
    /// The repository's copy on its main branch, through GitHub's public API (the same server as the update check). The raw media
    /// type gives the file itself
    public static func remoteURL(repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/contents/\(repositoryPath)?ref=main")!
    }

    /// The list isn't transit data: GitHub's answers (404 while the repository is private, rate limits) aren't recorded for the notices
    /// at the stations, and nothing is shown for them
    static let fetcher = URLSessionFetcher(timeout: 20, accept: "application/vnd.github.raw+json", recordsReach: false)

    /// Downloads and checks the repository's list. Returns it with the file as downloaded (to save). Throws the fetcher's error, or a Rejection
    public static func fetch(repository: String, fetcher: DataFetching? = nil) async throws -> (list: SourceList, data: Data) {
        let data = try await (fetcher ?? Self.fetcher).fetch(remoteURL(repository: repository))
        return (try checked(data), data)
    }

    /// One check a month, like the timetables; while an operator's data can't be downloaded for a reason on its side (the address may
    /// have moved), also once a day, in case the list has its new address. `lastTried`: the last time it was asked, whatever came back
    public static func isDue(lastTried: Date?, operatorProblem: Bool, now: Date = Date()) -> Bool {
        guard let lastTried else { return true }
        if SubwayMapSchedule.isDue(lastChecked: lastTried, now: now) { return true }
        return operatorProblem && now.timeIntervalSince(lastTried) >= 24 * 3600
    }
}
