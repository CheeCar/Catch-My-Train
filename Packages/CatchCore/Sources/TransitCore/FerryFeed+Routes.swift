import Foundation

extension FerryFeed {
    // MARK: Routes

    /// Whether it's a ferry route.
    public static func isFerryRoute(_ route: String) -> Bool {
        Source.of(route: route)?.system == .ferry
    }

    /// Whether it's a train route (LIRR, Metro-North).
    public static func isRailRoute(_ route: String) -> Bool {
        Source.of(route: route)?.isRail == true
    }

    /// Whether it's a PATH route.
    public static func isPathRoute(_ route: String) -> Bool {
        Source.of(route: route) == .path
    }

    /// Whether it's an NJ Transit bus route ("NJB-107").
    public static func isNJBusRoute(_ route: String) -> Bool {
        Source.of(route: route) == .njTransitBus
    }

    /// Whether it's one of these routes (ferry or train).
    public static func isFeedRoute(_ route: String) -> Bool {
        Source.of(route: route) != nil
    }

    /// Text on the route badge: "NYF-ER" → "ER", "SIF" → "SI", "NYW" → "NYW", "SST" → "SEA", "LIRR-BAB" → "BAB".
    public static func badge(_ route: String) -> String {
        switch route {
        case "SIF": return "SI"
        case "SST": return "SEA"
        default:
            if let source = Source.of(route: route), source.singleRouteID == nil {
                if source == .njTransitBus { return RegionalBusFeed.badge(route) }
                return String(route.dropFirst(source.routePrefix.count))
            }
            return route
        }
    }

    /// Full route name (for hover and screen readers), e.g. "NYF-ER" → "NYC Ferry East River", "NYW" → "NY Waterway",
    /// "LIRR-BAB" → "LIRR Babylon Branch".
    public static func routeName(_ route: String) -> String {
        guard let source = Source.of(route: route) else { return route }
        if source == .njTransitBus {
            // NJ Transit and the other schedule-only bus operators ("NJB-107", "NJB-NICE/n6")
            let feed = RegionalBusFeed.of(route: route) ?? .njTransit
            return (feed.code.isEmpty ? "NJ Transit Bus" : feed.name) + " " + badge(route)
        }
        if source.isRail || source == .path {
            let code = badge(route)
            // In Amtrak's package, but CTrail's line
            if isShoreLineEast(route) { return "CTrail " + shoreLineEast.name }
            // In MBTA's package, but the Cape Cod Regional Transit Authority's train
            if route == mbtaCapeFlyerRoute { return "CapeFLYER" }
            return source.shortName + " " + (railLines[source]?.first { $0.code == code }?.name ?? code)
        }
        if source == .mbtaFerry {
            let code = badge(route)
            return source.shortName + " " + (railLines[source]?.first { $0.code == code }?.name ?? code)
        }
        guard source == .nycFerry else { return source.name }
        let names = ["AS": "Astoria", "ER": "East River", "RS": "Rockaway-Soundview", "SB": "South Brooklyn",
                     "SG": "St. George", "RW": "Rockaway", "SV": "Soundview"]
        let code = badge(route)
        return source.name + " " + (names[code] ?? code)
    }

    /// Name of any route for hover and screen readers: full names for trains, ferries and the timetable bus companies,
    /// "Roosevelt Island Tram", and the badge text for MTA subway and buses ("S", "M15-SBS"), never an ID like "LIRR-BAB".
    /// The order matters: BusCatalog.isBusRoute is true for anything that isn't a subway route.
    public static func spokenRouteName(_ route: String) -> String {
        if RooseveltIslandTram.isTram(route: route) { return "Roosevelt Island Tram" }
        if isFeedRoute(route) { return routeName(route) }
        if BusCatalog.isBusRoute(route) { return route.hasSuffix("+") ? String(route.dropLast()) + "-SBS" : route }
        return MTARoute.badge(route)
    }

    public func route(_ id: String) -> Route? { routes.first { $0.id == id } }

    /// Whether this route has realtime data (Staten Island Ferry doesn't).
    public func hasRealtime(route id: String) -> Bool { route(id)?.realtime ?? false }

    /// Whether this route has realtime data: marked so in the data, or it's an operator the user entered an account for (see Source.needsAccount)
    public func hasRealtime(route id: String, accounts: Set<Source>) -> Bool {
        hasRealtime(route: id) || Source.of(route: id).map(accounts.contains) == true
    }

    public func pier(id: String) -> Pier? { piers.first { $0.id == id } }

    /// Where this trip goes when leaving the i-th pier: usually the terminal; at the start of a loop, the next stop (see Trip.headsigns).
    public func destination(of trip: Trip, at i: Int) -> String? {
        if let h = trip.headsigns, h.indices.contains(i), !h[i].isEmpty { return h[i] }
        return trip.stops.last.flatMap { pier(id: $0)?.name }
    }

    /// Routes serving each pier (only counting boats departing from there).
    public func routesByPier() -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        for trip in trips {
            for stop in trip.boardingStops { result[stop, default: []].insert(trip.route) }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Destination per direction at this pier (the most frequent one in the schedule), used to show "To …" when there are no boats.
    /// For operators merged into one route (e.g. NY Waterway has several terminals): give up to 3 common destinations.
    public func terminals(atPier id: String) -> [(route: String, direction: String, terminal: String)] {
        var counts: [String: [String: Int]] = [:]
        for trip in trips {
            guard let i = trip.stops.indices.first(where: { trip.stops[$0] == id && trip.canBoard(at: $0) }),
                  let name = destination(of: trip, at: i) else { continue }
            counts[trip.route + "|" + trip.direction, default: [:]][name, default: 0] += 1
        }
        return counts.keys.sorted().flatMap { key -> [(route: String, direction: String, terminal: String)] in
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, let names = counts[key] else { return [] }
            let ranked = names.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            guard let top = ranked.first else { return [] }
            // For operators merged into one route, and trains (one line's trains go to several terminals, e.g. inbound LIRR to Penn Station or Grand Central):
            // list the few common destinations
            let source = Source.of(route: parts[0])
            let rail = source?.isRail == true || source == .path
            let merged = source?.singleRouteID != nil || rail
            let chosen = rail ? Array(ranked.filter { $0.value * 5 >= top.value }.prefix(4))
                : merged ? Array(ranked.filter { $0.value * 3 >= top.value }.prefix(3)) : [top]
            return chosen.map { (parts[0], parts[1], $0.key) }
        }
    }

    // MARK: Nearby piers

    /// Operators (or one operator's several boarding points) this close together (meters) count as one pier: listed once among nearby piers, under one name.
    /// In the real data, operators at the same pier are 0–36 m apart (Pier 11, Brookfield Place, W 39th St, E 34th St);
    /// Seastreak's Battery Maritime Building Slip 5 is about 100 m from Staten Island Ferry's Whitehall,
    /// a separate building next door, so it must not be merged (or Seastreak boats would show under "Whitehall Ferry Terminal").
    public static let samePierMeters = 60.0

    /// Groups of stops at the same pier (e.g. Pier 11 has NYC Ferry, NY Waterway and Seastreak stops).
    /// Returns pier ID → (group ID, name); the name is taken from the first operator in the order NYC Ferry, Staten Island Ferry, NY Waterway, Seastreak
    /// (operators spell names differently, e.g. "Wall St/Pier 11" and "Pier 11/Wall Street"). Piers with only one stop aren't in the result.
    /// Whether two names are the same station: identical names, or the various names of New York Penn Station
    /// (LIRR and Amtrak say "Penn Station", NJ Transit says "New York Penn Station")
    static func sameStationName(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let penn: Set<String> = ["Penn Station", "New York Penn Station"]
        return penn.contains(a) && penn.contains(b)
    }

    public func pierGroups() -> [String: (group: String, name: String)] {
        let served = Set(trips.flatMap(\.stops))
        // South to north: each pier is compared only with the ones north of it close enough to be merged (SEPTA Metro's hundreds of
        // trolley stops make comparing every pair slow)
        let list = piers.filter { served.contains($0.id) }.sorted { $0.lat < $1.lat }
        var parent = Array(list.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in list.indices {
            for j in (i + 1)..<list.count {
                // The rest are farther north than 400 m (a degree of latitude is about 111 km)
                if list[j].lat - list[i].lat > 0.004 { break }
                // Same-name stations count as one even a bit farther apart (e.g. Amtrak's Penn Station is in Moynihan Hall, 100–200 m from the LIRR and NJ Transit points)
                let d = WalkEstimator.distanceMeters(list[i].coordinate, list[j].coordinate)
                if d <= Self.samePierMeters || (d <= 400 && Self.sameStationName(list[i].name, list[j].name)) {
                    parent[root(i)] = root(j)
                }
            }
        }
        var members: [Int: [Pier]] = [:]
        for i in list.indices { members[root(i), default: []].append(list[i]) }
        let order = Source.allCases
        func rank(_ p: Pier) -> Int { order.firstIndex { $0.owns(id: p.id) } ?? order.count }
        var result: [String: (group: String, name: String)] = [:]
        for group in members.values where group.count > 1 {
            let sorted = group.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.id < $1.id }
            for p in sorted { result[p.id] = ("ferry:" + sorted[0].id, sorted[0].name) }
        }
        return result
    }

    public func stations(near coordinate: Coordinate, radiusMeters: Double) -> [Station] {
        let served = Set(trips.flatMap(\.boardingStops))
        let groups = pierGroups()
        return piers
            .filter { served.contains($0.id) }
            .map { ($0, WalkEstimator.distanceMeters(coordinate, $0.coordinate)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .map { pier, _ in
                let group = groups[pier.id]
                let boarding = Source.allCases.first { $0.owns(id: pier.id) }?.boardingSeconds ?? 60
                return Station(id: pier.id, name: group?.name ?? pier.name, coordinate: pier.coordinate, entrances: [],
                               entranceToPlatformSeconds: boarding, complexID: group?.group)
            }
    }

    /// Of `stations` (nearest first, as stations(near:radiusMeters:) gives them), only the ones where a route can be boarded in a
    /// direction that no nearer one in the list offers, as BusCatalog.stations picks MTA stops: with a long walk, bus stops follow
    /// one another along the same streets, and the nearest stop of each route and direction is the one worth walking to.
    public func nearestPerRouteDirection(_ stations: [Station]) -> [Station] {
        var offered: [String: Set<String>] = [:]
        for trip in trips {
            for stop in trip.boardingStops { offered[stop, default: []].insert(trip.route + "|" + trip.direction) }
        }
        var covered = Set<String>()
        return stations.filter { station in
            let fresh = (offered[station.id] ?? []).subtracting(covered)
            guard !fresh.isEmpty else { return false }
            covered.formUnion(fresh)
            return true
        }
    }
}
