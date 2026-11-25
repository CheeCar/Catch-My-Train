import Foundation

/// What one operator's downloaded data lists, as far as a change in it is told: its stops and its lines, by their ids, with the
/// names the app shows, and which stops each line serves. Made from the old data and from the new before the new takes the old's
/// place (DataChanges.between, DataJudgement.of). It is made and compared, never stored.
public struct DataListing: Equatable, Sendable {
    /// Stop id to name
    public var stops: [String: String]
    /// Line id to name
    public var routes: [String: String]
    /// Line id to the ids of the stops it serves. A line left out here is told without its stops
    public var routeStops: [String: Set<String>]
    /// Stop id to where it is, where that is known: it tells a stop that only got a new id from another one of the same name
    /// somewhere else
    public var places: [String: Coordinate]

    public init(stops: [String: String] = [:], routes: [String: String] = [:], routeStops: [String: Set<String>] = [:],
                places: [String: Coordinate] = [:]) {
        self.stops = stops
        self.routes = routes
        self.routeStops = routeStops
        self.places = places
    }

    /// A timetable's listing (trains, ferries, PATH, light rail, regional buses): its piers or stations, its lines, and for each
    /// line the stops of its trips
    public init(_ feed: FerryFeed) {
        stops = Dictionary(feed.piers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        routes = Dictionary(feed.routes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var served: [String: Set<String>] = [:]
        for trip in feed.trips { served[trip.route, default: []].formUnion(trip.stops) }
        routeStops = served
        places = Dictionary(feed.piers.map { ($0.id, Coordinate(latitude: $0.lat, longitude: $0.lon)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The subway's station list. Its lines have no other name than their letter or number
    public init(_ catalog: StationCatalog) {
        self.init()
        for station in catalog.entries where stops[station.id] == nil {
            stops[station.id] = station.name
            places[station.id] = station.coordinate
            for line in station.routes {
                routes[line.route] = line.route
                routeStops[line.route, default: []].insert(station.id)
            }
        }
    }

    /// The city buses' stop list
    public init(_ catalog: BusCatalog) {
        self.init(routes: catalog.routes.mapValues(\.name))
        for stop in catalog.stops where stops[stop.id] == nil {
            stops[stop.id] = stop.name
            places[stop.id] = stop.coordinate
            for line in stop.routeDirections { routeStops[line.route, default: []].insert(stop.id) }
        }
    }
}

/// What changed from one listing to the next of the same data: the stops and lines that came, went or were renamed.
/// It tells what a rider would see. A stop or line that only got a new id, its name the same, is not a change (an operator
/// renumbering its data would otherwise read as everything gone and everything new); those are only counted. A stop is the
/// same one when its name is the same and, where both positions are known, it is no farther than `sameStopWithin` from where
/// it was: a "Main St" gone in one town and a "Main St" new in another are two changes.
public struct DataChanges: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Rename: Codable, Equatable, Sendable {
        public var id: String
        public var from: String
        public var to: String
    }

    /// A line that is gone, with the stops that went with it (served by no line that is left): told in one sentence, not a
    /// line of its own for every stop
    public struct LostRoute: Codable, Equatable, Sendable {
        public var route: Item
        public var stops: [Item]
    }

    public var addedStops: [Item] = []
    /// The stops gone that went with no line (see LostRoute)
    public var removedStops: [Item] = []
    public var renamedStops: [Rename] = []
    public var addedRoutes: [Item] = []
    public var removedRoutes: [LostRoute] = []
    public var renamedRoutes: [Rename] = []
    /// Stops and lines that only got a new id
    public var renumbered = 0
    /// Where the stops told above are, by id, where that is known (where a stop gone was; where a new or renamed one is): to
    /// tell the changes near the user's own places. Nil in what was written before it was kept
    public var places: [String: Coordinate]?

    public init() {}

    /// How far (meters) a stop with a new id may be from the old one of the same name and still be the same stop: a stop moved
    /// along its block is, the next station of that name is not
    public static let sameStopWithin = 300.0

    /// Nothing a rider would see changed
    public var isEmpty: Bool {
        addedStops.isEmpty && removedStops.isEmpty && renamedStops.isEmpty && addedRoutes.isEmpty && removedRoutes.isEmpty
            && renamedRoutes.isEmpty
    }

    /// How many things changed: each stop and line that came, went or was renamed, a line's own stops included
    public var count: Int {
        addedStops.count + removedStops.count + renamedStops.count + addedRoutes.count + renamedRoutes.count
            + removedRoutes.reduce(0) { $0 + 1 + $1.stops.count }
    }

    /// How many lines a list of the changes has: a line gone with its stops is one
    public var lines: Int {
        addedStops.count + removedStops.count + renamedStops.count + addedRoutes.count + renamedRoutes.count + removedRoutes.count
    }

    /// Old to new. Each list comes out in the order of the names (then the ids), so the same change always reads the same
    public static func between(old: DataListing, new: DataListing) -> DataChanges {
        var changes = DataChanges()
        let stops = compare(old: old.stops, new: new.stops, oldPlaces: old.places, newPlaces: new.places)
        let routes = compare(old: old.routes, new: new.routes)
        changes.addedStops = stops.added
        changes.renamedStops = stops.renamed
        changes.addedRoutes = routes.added
        changes.renamedRoutes = routes.renamed
        changes.renumbered = stops.renumbered + routes.renumbered
        // A stop that is gone goes with a line that is gone when every line it had is gone too
        let goneRoutes = Set(routes.removed.map(\.id))
        var linesOfStop: [String: Set<String>] = [:]
        for (route, served) in old.routeStops { for stop in served { linesOfStop[stop, default: []].insert(route) } }
        var taken: Set<String> = []
        for route in routes.removed {
            let served = old.routeStops[route.id] ?? []
            let with = stops.removed.filter { stop in
                served.contains(stop.id) && !taken.contains(stop.id) && (linesOfStop[stop.id] ?? []).isSubset(of: goneRoutes)
            }
            taken.formUnion(with.map(\.id))
            changes.removedRoutes.append(LostRoute(route: route, stops: with))
        }
        changes.removedStops = stops.removed.filter { !taken.contains($0.id) }
        var places: [String: Coordinate] = [:]
        for item in changes.removedStops + changes.removedRoutes.flatMap(\.stops) { places[item.id] = old.places[item.id] }
        for item in changes.addedStops { places[item.id] = new.places[item.id] }
        for rename in changes.renamedStops { places[rename.id] = new.places[rename.id] ?? old.places[rename.id] }
        changes.places = places
        return changes
    }

    /// The changes at stops no farther than `meters` from one of these points (a line gone is told with its stops near them).
    /// Stops whose place isn't known are left out, and so are new and renamed lines, which have no place of their own
    public func near(_ points: [Coordinate], within meters: Double) -> DataChanges {
        func close(_ id: String) -> Bool {
            guard let at = places?[id] else { return false }
            return points.contains { WalkEstimator.distanceMeters($0, at) <= meters }
        }
        var c = DataChanges()
        c.addedStops = addedStops.filter { close($0.id) }
        c.removedStops = removedStops.filter { close($0.id) }
        c.renamedStops = renamedStops.filter { close($0.id) }
        c.removedRoutes = removedRoutes.compactMap { lost in
            let stops = lost.stops.filter { close($0.id) }
            return stops.isEmpty ? nil : LostRoute(route: lost.route, stops: stops)
        }
        let told = Set((c.addedStops + c.removedStops + c.removedRoutes.flatMap(\.stops)).map(\.id) + c.renamedStops.map(\.id))
        c.places = places?.filter { told.contains($0.key) }
        return c
    }

    /// The changes with each list cut to its first `limit` entries, to keep what is stored small. The numbers are lost with
    /// them: count what is to be told before cutting
    public func capped(to limit: Int) -> DataChanges {
        var c = self
        let n = max(limit, 0)
        c.addedStops = Array(addedStops.prefix(n))
        c.removedStops = Array(removedStops.prefix(n))
        c.renamedStops = Array(renamedStops.prefix(n))
        c.addedRoutes = Array(addedRoutes.prefix(n))
        c.renamedRoutes = Array(renamedRoutes.prefix(n))
        c.removedRoutes = removedRoutes.prefix(n).map { LostRoute(route: $0.route, stops: Array($0.stops.prefix(n))) }
        let told = Set((c.addedStops + c.removedStops + c.removedRoutes.flatMap(\.stops)).map(\.id) + c.renamedStops.map(\.id))
        c.places = places?.filter { told.contains($0.key) }
        return c
    }

    private struct Compared {
        var added: [Item] = []
        var removed: [Item] = []
        var renamed: [Rename] = []
        var renumbered = 0
    }

    /// By id first. Of what is left on both sides, the ones with the same name are the same thing with a new id
    private static func compare(old: [String: String], new: [String: String], oldPlaces: [String: Coordinate] = [:],
                                newPlaces: [String: Coordinate] = [:]) -> Compared {
        var result = Compared()
        var gone: [Item] = []
        var come: [Item] = []
        for (id, name) in old {
            if let now = new[id] {
                if key(now) != key(name) { result.renamed.append(Rename(id: id, from: name, to: now)) }
            } else {
                gone.append(Item(id: id, name: name))
            }
        }
        for (id, name) in new where old[id] == nil { come.append(Item(id: id, name: name)) }
        gone.sort(by: inOrder)
        come.sort(by: inOrder)
        // Several stops can share a name (the two sides of a street): each one gone pairs with one come, no more, and with
        // the nearest one when it is known where they are
        var waiting: [String: [Int]] = [:]
        for (index, item) in come.enumerated() { waiting[key(item.name), default: []].append(index) }
        var paired: Set<Int> = []
        for item in gone {
            let k = key(item.name)
            var best: (at: Int, index: Int, meters: Double)?
            for (at, index) in (waiting[k] ?? []).enumerated() {
                // Where one of the two isn't known, the name alone decides; such a pair comes after any that is known to be near
                var meters = sameStopWithin
                if let was = oldPlaces[item.id], let now = newPlaces[come[index].id] {
                    meters = WalkEstimator.distanceMeters(was, now)
                    if meters > sameStopWithin { continue }
                }
                if let nearest = best, nearest.meters <= meters { continue }
                best = (at, index, meters)
            }
            if let best {
                waiting[k]?.remove(at: best.at)
                paired.insert(best.index)
                result.renumbered += 1
            } else {
                result.removed.append(item)
            }
        }
        for (index, item) in come.enumerated() where !paired.contains(index) { result.added.append(item) }
        result.renamed.sort { ($0.from, $0.id) < ($1.from, $1.id) }
        return result
    }

    private static func inOrder(_ a: Item, _ b: Item) -> Bool { (a.name, a.id) < (b.name, b.id) }

    /// A name as it is compared: capitals and extra spaces don't make a new name
    static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

/// Whether new data takes the old's place. Data that reads as far from the old isn't taken: a file cut short or half broken
/// looks like most stops gone, and the app goes on with the last good data instead (nothing else is disturbed).
public enum DataJudgement: Equatable, Sendable {
    /// Nothing a rider would see changed
    case same
    /// Take the new data; there are changes to tell
    case changed
    /// Looks wrong: keep the old data, and say so
    case tooDifferent(Reason)

    public enum Reason: String, Codable, Sendable {
        /// The new data lists no stops at all
        case empty
        /// Too many of the old stops are gone
        case stopsGone
        /// The number of stops jumped, up or down
        case countJump
    }

    /// How far new data may be from the old and still be taken
    public struct Limits: Equatable, Sendable {
        /// The share of the old stops that must still be there (by id, or by name with a new id)
        public var kept: Double
        /// How far the number of stops may move, as a share of the old number
        public var countChange: Double
        /// A few stops may always go or come, however small the operator: with five piers, one gone is a fifth of them
        public var slack: Int

        public init(kept: Double, countChange: Double, slack: Int) {
            self.kept = kept
            self.countChange = countChange
            self.slack = slack
        }
    }

    public static func of(old: DataListing, new: DataListing, limits: Limits) -> DataJudgement {
        guard !new.stops.isEmpty else { return .tooDifferent(.empty) }
        // The first data there is: nothing to hold it against
        guard !old.stops.isEmpty else { return .changed }
        let changes = DataChanges.between(old: old, new: new)
        let was = old.stops.count
        let gone = changes.removedStops.count + changes.removedRoutes.reduce(0) { $0 + $1.stops.count }
        // All of them gone is never a few (two piers, both gone, are within the slack of two)
        let mayGo = min(max(Int((Double(was) * (1 - limits.kept)).rounded(.down)), limits.slack), was - 1)
        if gone > mayGo { return .tooDifferent(.stopsGone) }
        let mayMove = max(Int((Double(was) * limits.countChange).rounded(.down)), limits.slack)
        if abs(new.stops.count - was) > mayMove { return .tooDifferent(.countJump) }
        return changes.isEmpty ? .same : .changed
    }
}
