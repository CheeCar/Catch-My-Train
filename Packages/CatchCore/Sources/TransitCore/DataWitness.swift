import Foundation

// MARK: - The live data as a witness for new data that looked wrong
//
// New data that looks wrong (DataUpdateGate) leaves out stops or lines, and isn't taken until the very same data has come for a
// week. The live data the app downloads anyway, for the departures it shows, can tell more: a train, boat or bus due at a stop
// the new data leaves out, or on a line it leaves out, shows them still served. Then the new data is wrong, and isn't taken
// after the week either, until the live data has shown none of them for `quietDays`. Live data showing nothing proves nothing
// (only what is near is downloaded, and not every operator has live data): the week alone decides then. Nothing more is
// downloaded for this, and it never takes data sooner.

public enum DataWitness {
    /// New data that looked wrong is taken after its week only when the live data hasn't shown served what it leaves out for
    /// this many days
    public static let quietDays = 3
    /// What the live data showed is noted at most this often (seconds) for each operator: departures are downloaded every half
    /// minute, the rule above counts days
    public static let noteEvery: TimeInterval = 3600
    /// The most stops kept of what new data leaves out: new data that leaves out more is broken anyway, and these are enough
    /// to find some near anyone
    public static let missingLimit = 20_000

    /// What an operator's new data that looked wrong leaves out, all of it (an entry's lists are cut, see DataChangeLog.listLimit),
    /// by id: the stops gone (alone or with their line) and the lines gone. And when the live data last showed one of them served
    public struct Missing: Codable, Equatable, Sendable {
        public var stops: [String]
        public var routes: [String]
        public var liveSeenAt: Date?

        public init(stops: [String], routes: [String], liveSeenAt: Date? = nil) {
            self.stops = stops
            self.routes = routes
            self.liveSeenAt = liveSeenAt
        }

        /// What these changes leave out (before they're cut)
        public init(_ changes: DataChanges, liveSeenAt: Date? = nil) {
            let stops = Set(changes.removedStops.map(\.id) + changes.removedRoutes.flatMap { $0.stops.map(\.id) })
            self.init(stops: Array(stops.sorted().prefix(DataWitness.missingLimit)),
                      routes: Set(changes.removedRoutes.map(\.route.id)).sorted(), liveSeenAt: liveSeenAt)
        }
    }

    /// What the live departures shown show of one operator, by its data's ids: the stops where one is due, and their lines
    public struct Seen: Equatable, Sendable {
        public var stops: Set<String> = []
        public var routes: Set<String> = []

        public init(stops: Set<String> = [], routes: Set<String> = []) {
            self.stops = stops
            self.routes = routes
        }
    }

    /// How many of the stops and lines left out the live data shows served
    public struct Match: Equatable, Sendable {
        public var stops: Int
        public var routes: Int
        public var any: Bool { stops > 0 || routes > 0 }
    }

    /// A departure that a vehicle really makes: from the live data, with a vehicle on it (the subway's trips without one yet
    /// still have the timetable's times), not cancelled
    public static func isLive(_ arrival: Arrival) -> Bool {
        arrival.source == .realtime && arrival.isAssigned != false && arrival.status != .cancelled
    }

    /// Whose departure it is, by the key of the log of data checks (DataChangeLog), and its stop and line by the ids of that
    /// operator's data (DataListing). The stations of trains, ferries, PATH and light rail have their operator's prefix, as in
    /// its data; a regional bus operator's stops and lines have the app's own prefixes, which its data doesn't (NJBusIndex);
    /// the MTA's subway stations and city bus stops have none, and the mode shown tells them apart. Nil: one the log doesn't
    /// have (the Roosevelt Island Tram, Demo mode's)
    public static func owner(of arrival: Arrival, mode: TransitSystem) -> (key: String, stop: String, route: String)? {
        let id = arrival.stationID
        guard let key = DataChangeLog.key(station: id, mode: mode) else { return nil }
        if let bus = RegionalBusFeed.of(id: id) {
            let route = arrival.route.hasPrefix(bus.routePrefix) ? String(arrival.route.dropFirst(bus.routePrefix.count)) : arrival.route
            return (key, String(id.dropFirst(bus.idPrefix.count)), route)
        }
        return (key, id, key == DataChangeLog.subwayKey ? MTARoute.normalize(arrival.route) : arrival.route)
    }

    /// What the live ones of these departures (of one mode) show, by operator
    public static func seen(in arrivals: [Arrival], mode: TransitSystem) -> [String: Seen] {
        var seen: [String: Seen] = [:]
        for arrival in arrivals where isLive(arrival) {
            guard let at = owner(of: arrival, mode: mode) else { continue }
            seen[at.key, default: Seen()].stops.insert(at.stop)
            seen[at.key, default: Seen()].routes.insert(at.route)
        }
        return seen
    }

    /// What the live departures shown tell as a sighting: the live ones still fresh (updated within `staleAfter` of the trains'
    /// time, which is `now` moved by `clockOffset`, see ClockSkew), by operator, and when in this Mac's time: the newest update
    /// among them, never later than `now`. Old ones shown again after downloads failed tell nothing new, and shown again while
    /// still fresh they tell the same time. nil: none fresh
    public static func sighting(in arrivals: [Arrival], mode: TransitSystem, staleAfter: TimeInterval, clockOffset: TimeInterval,
                                now: Date) -> (seen: [String: Seen], at: Date)? {
        let trainNow = now.addingTimeInterval(clockOffset)
        let fresh = arrivals.filter { isLive($0) && trainNow.timeIntervalSince($0.updatedAt) <= staleAfter }
        guard let newest = fresh.map(\.updatedAt).max() else { return nil }
        return (seen(in: fresh, mode: mode), min(newest.addingTimeInterval(-clockOffset), now))
    }

    /// How many of what an entry's new data leaves out the live data shows served. The subway's lines go by the name the live
    /// data gives them (6X is the 6)
    public static func match(_ entry: DataChangeLog.Entry, _ seen: Seen) -> Match {
        guard let missing = entry.missing else { return Match(stops: 0, routes: 0) }
        let routes = entry.key == DataChangeLog.subwayKey ? missing.routes.map(MTARoute.normalize) : missing.routes
        return Match(stops: seen.stops.intersection(missing.stops).count, routes: seen.routes.intersection(routes).count)
    }

    /// Whether the live data showed served what new data leaves out within `quietDays` of now
    public static func stillServed(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < Double(quietDays) * 86_400
    }

    /// Whether a sighting now is worth noting: none noted yet, or the last one `noteEvery` ago
    public static func wantsNote(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else { return true }
        return now.timeIntervalSince(lastSeen) >= noteEvery
    }
}
