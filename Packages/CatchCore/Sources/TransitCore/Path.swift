import Foundation

// MARK: - PATH realtime data
//
// Data used by the official PATH app: https://www.panynj.gov/bin/portauthority/ridepath.json (free, no key needed, updated about every 15 seconds).
// For each station and each direction (ToNY to New York, ToNJ to New Jersey) it gives the next two or three trains:
//   {"results":[{"consideredStation":"NWK","destinations":[{"label":"ToNY","messages":[
//     {"target":"WTC","secondsToArrival":"554","arrivalTimeMessage":"9 min","lineColor":"D93A30",
//      "headSign":"World Trade Center","lastUpdated":"YYYY-MM-DDT15:20:45.940598-04:00"}]}]}]}
// There are no trip IDs, so we don't match timetable trips; they become arrivals directly: stations match timetable stations by name, routes by color (and terminal).
// Realtime only: the PATH timetable is outdated, so trips come only from here (once a new timetable exists, trips after the realtime ones use the timetable).

public struct PathLive: Sendable, Equatable {
    public static let builtInURL = URL(string: "https://www.panynj.gov/bin/portauthority/ridepath.json")!
    /// The address: the source list's (the live data of its "path" entry), or the one in code
    public static var url: URL { SourceList.realtimeURL(for: FerryFeed.Source.path.rawValue) ?? builtInURL }

    public struct Train: Sendable, Equatable {
        /// Station code (NWK, HOB, 33S…)
        public var station: String
        /// Toward New York (ToNY) or New Jersey (ToNJ)
        public var toNY: Bool
        /// Terminal code
        public var target: String
        public var headSign: String
        /// Line color (may be two colors like "FF9900,4D92FB": Journal Square–33rd Street via Hoboken)
        public var colors: [String]
        public var time: Date
        public var updatedAt: Date
    }

    public var trains: [Train]
    public var fetchedAt: Date

    public init(trains: [Train], fetchedAt: Date) {
        self.trains = trains
        self.fetchedAt = fetchedAt
    }

    /// Station code in the data → station name in the timetable
    public static let stationNames: [String: String] = [
        "NWK": "Newark", "HAR": "Harrison", "JSQ": "Journal Square", "GRV": "Grove Street", "NEW": "Newport",
        "EXP": "Exchange Place", "HOB": "Hoboken", "WTC": "World Trade Center", "CHR": "Christopher Street",
        "09S": "9th Street", "14S": "14th Street", "23S": "23rd Street", "33S": "33rd Street",
    ]

    private struct Raw: Decodable {
        struct Station: Decodable {
            var consideredStation: String?
            var destinations: [Destination]?
        }
        struct Destination: Decodable {
            var label: String?
            var messages: [Message]?
        }
        struct Message: Decodable {
            var target: String?
            var secondsToArrival: String?
            var lineColor: String?
            var headSign: String?
            var lastUpdated: String?
        }
        var results: [Station]?
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> PathLive {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var trains: [Train] = []
        for station in raw.results ?? [] {
            guard let code = station.consideredStation?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { continue }
            for dest in station.destinations ?? [] {
                let toNY = dest.label?.uppercased() == "TONY"
                for m in dest.messages ?? [] {
                    guard let secs = m.secondsToArrival.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { continue }
                    let updated = m.lastUpdated.flatMap(parseDate) ?? fetchedAt
                    // If the data is newer than the download time (clocks out of sync), use the download time
                    let base = min(updated, fetchedAt)
                    let colors = (m.lineColor ?? "").split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
                    trains.append(Train(station: code, toNY: toNY, target: m.target ?? "",
                                        headSign: (m.headSign ?? "").trimmingCharacters(in: .whitespaces),
                                        colors: colors, time: base.addingTimeInterval(secs), updatedAt: base))
                }
            }
        }
        return PathLive(trains: trains, fetchedAt: fetchedAt)
    }

    /// "YYYY-MM-DDT15:20:45.940598-04:00" (the number of fractional digits varies)
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // Drop the fraction after the seconds and parse with the standard format
        var text = trimmed
        if let dot = trimmed.firstIndex(of: ".") {
            let rest = trimmed[trimmed.index(after: dot)...]
            let tz = rest.drop { $0.isNumber }
            text = String(trimmed[..<dot]) + tz
        }
        lock.lock(); defer { lock.unlock() }
        return formatter.value.date(from: text)
    }

    /// Created once (ISO8601DateFormatter isn't cheap to create) and locked, since it isn't guaranteed thread-safe
    private static let lock = NSLock()
    private static let formatter = LockedBox<ISO8601DateFormatter>({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    /// Time of the newest data ("Updated" in the UI)
    public var updatedAt: Date? { trains.map(\.updatedAt).max() }

    // MARK: Convert to arrivals

    /// Realtime trips for these stations (timetable station IDs).
    /// - Station: matched by name (a station with several platforms uses the smallest ID among those requested).
    /// - Route: matched by color; when several routes share a color, use the one leaving this station whose terminal matches the headSign.
    /// - Direction: in the timetable, direction_id 1 (toward New York) is "S" and 0 is "N" (see FerryBuilder).
    /// - ID: see `PathIDs`; `previous` is the last refresh's arrivals (any kind; only PATH's are used).
    public func arrivals(feed: FerryFeed, pierIDs: [String], from: Date, to: Date, previous: [Arrival] = []) -> [Arrival] {
        let wanted = Set(pierIDs)
        let pathPiers = feed.piers.filter { wanted.contains($0.id) && FerryFeed.Source.path.owns(id: $0.id) }
        guard !pathPiers.isEmpty else { return [] }
        var pierByName: [String: String] = [:]
        for p in pathPiers.sorted(by: { $0.id < $1.id }) where pierByName[p.name] == nil { pierByName[p.name] = p.id }
        var result: [Arrival] = []
        var ids = PathIDs(previous: previous)
        let ordered = trains.sorted { ($0.time, $0.station, $0.target, $0.headSign) < ($1.time, $1.station, $1.target, $1.headSign) }
        for t in ordered {
            guard t.time >= from, t.time <= to, let name = Self.stationNames[t.station], let pier = pierByName[name] else { continue }
            let code = t.toNY ? "S" : "N"
            let route = Self.route(for: t, at: pier, direction: code, feed: feed)
            let terminal = t.headSign.isEmpty ? (Self.stationNames[t.target] ?? t.target) : t.headSign
            let group = "\(t.station)|\(code)|\(t.target)"
            result.append(Arrival(
                id: ids.id(group: group, time: t.time),
                stationID: pier, route: route,
                direction: Direction(code: code, name: "To " + terminal, terminal: terminal),
                arrivalTime: t.time, source: .realtime, status: .normal, updatedAt: t.updatedAt))
        }
        return result.sorted { ($0.arrivalTime ?? .distantFuture) < ($1.arrivalTime ?? .distantFuture) }
    }

    /// Route: among routes with the same color, pick the one leaving this station in this direction whose terminal matches this train (e.g. green has Hoboken–WTC and WTC–33rd St);
    /// two-color ones (yellow + blue) are Journal Square–33rd Street via Hoboken. If nothing matches, use the first route with the same color.
    static func route(for t: Train, at pier: String, direction: String, feed: FerryFeed) -> String {
        let pathRoutes = feed.routes.filter { FerryFeed.Source.path.owns(route: $0.id) }
        var candidates = pathRoutes.filter { t.colors.contains($0.color.uppercased()) }
        if t.colors.count > 1, let via = candidates.first(where: { $0.id.hasSuffix("JSQ-HOB-33") }) { return via.id }
        if t.colors.count == 1 {
            let direct = candidates.filter { !$0.id.hasSuffix("JSQ-HOB-33") }
            if !direct.isEmpty { candidates = direct }
        }
        let targetName = (stationNames[t.target] ?? t.headSign).lowercased()
        // Count every platform of the same station (different IDs, same name in the timetable)
        let name = feed.pier(id: pier)?.name
        let platforms = Set(feed.piers.filter { $0.id == pier || ($0.name == name && FerryFeed.Source.path.owns(id: $0.id)) }.map(\.id))
        for r in candidates {
            let ends = feed.trips.filter { $0.route == r.id && $0.direction == direction && !platforms.isDisjoint(with: $0.boardingStops) }
                .compactMap { $0.stops.last.flatMap { feed.pier(id: $0)?.name.lowercased() } }
            if ends.contains(targetName) { return r.id }
        }
        return candidates.first?.id ?? pathRoutes.first?.id ?? "PATH"
    }

    /// Row IDs for PATH trains, which have no trip number. A train keeps the ID it had at the last refresh when that refresh had a
    /// train at the same station, direction and destination expected within 3 minutes of it (the closest one, each used once);
    /// any other train gets a number not used in its group before, so a train that comes into view never takes over the row of
    /// one that left (the predicted time changes with every update, and the place in line changes when the first train leaves).
    struct PathIDs {
        static let sameTrain: TimeInterval = 3 * 60
        private var earlier: [String: [(number: Int, time: Date)]] = [:]
        private var next: [String: Int] = [:]

        init(previous: [Arrival]) {
            for a in previous {
                guard let (group, number) = Self.parse(a.id) else { continue }
                next[group] = max(next[group] ?? 1, number + 1)
                if let time = a.arrivalTime { earlier[group, default: []].append((number, time)) }
            }
        }

        /// "path|<station>|<direction>|<destination>|<number>" → (group, number)
        static func parse(_ id: String) -> (String, Int)? {
            guard id.hasPrefix("path|"), let bar = id.lastIndex(of: "|"), let number = Int(id[id.index(after: bar)...]) else { return nil }
            let group = id[id.index(id.startIndex, offsetBy: 5)..<bar]
            return group.isEmpty ? nil : (String(group), number)
        }

        mutating func id(group: String, time: Date) -> String {
            var closest: (index: Int, gap: TimeInterval)?
            for (i, e) in (earlier[group] ?? []).enumerated() {
                let gap = abs(e.time.timeIntervalSince(time))
                if gap <= Self.sameTrain, gap < closest?.gap ?? .infinity { closest = (i, gap) }
            }
            if let closest, let number = earlier[group]?.remove(at: closest.index).number { return "path|\(group)|\(number)" }
            let number = next[group] ?? 1
            next[group] = number + 1
            return "path|\(group)|\(number)"
        }
    }

    /// Merges realtime and timetable trips: when a station and direction has realtime data, drop timetable trips before the last realtime train
    /// (realtime only gives the next two or three; later ones come from the timetable; when the timetable is outdated there is only realtime).
    /// Platforms of the same station (separate in the timetable) count as one station.
    public static func merge(live: [Arrival], timetable: [Arrival], feed: FerryFeed) -> [Arrival] {
        func key(_ a: Arrival) -> String { (feed.pier(id: a.stationID)?.name ?? a.stationID) + "|" + a.direction.code }
        var lastLive: [String: Date] = [:]
        for a in live {
            guard let t = a.arrivalTime else { continue }
            lastLive[key(a)] = max(lastLive[key(a)] ?? t, t)
        }
        let kept = timetable.filter { a in
            guard let last = lastLive[key(a)], let t = a.arrivalTime else { return true }
            return t > last.addingTimeInterval(60)
        }
        return (live + kept).sorted { ($0.arrivalTime ?? .distantFuture) < ($1.arrivalTime ?? .distantFuture) }
    }
}
