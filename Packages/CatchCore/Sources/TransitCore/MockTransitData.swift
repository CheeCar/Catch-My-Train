import Foundation

/// Made-up data: the subway stations around Times Square for the widget gallery preview, the app's place before one is chosen, and
/// Demo mode (see below).
/// The stations, their complexes and direction names are those of the station list (RecommenderTests checks it); trip times are
/// fake data generated from the "current time", with the source marked `.mock`; the UI clearly shows "mock data" and never passes it
/// off as realtime predictions.
public enum MockTransitData {

    /// A preset place for the made-up data.
    public struct Place: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var coordinate: Coordinate
    }

    public static let places: [Place] = [
        Place(id: "union-sq-park", name: "Union Square Park",
              coordinate: Coordinate(latitude: 40.7359, longitude: -73.9906)),
        Place(id: "nyu", name: "Washington Square (NYU)",
              coordinate: Coordinate(latitude: 40.7308, longitude: -73.9973)),
        Place(id: "gramercy", name: "Gramercy Park",
              coordinate: Coordinate(latitude: 40.7377, longitude: -73.9860)),
    ]

    /// The app's place before one is chosen (UserPlace.default)
    public static let defaultPlace = places[0]

    /// The widget gallery preview's place: Times Square, where Demo mode's current location is (DemoData.home), so Times Sq-42 St
    /// comes first
    public static let previewPlace = Place(id: "times-square", name: "Times Square",
                                           coordinate: DemoData.home.coordinate)

    /// A direction as the station list names it there (StationCatalog.direction): its signage name and the line's terminal
    static func dir(_ code: String, _ label: String, to terminal: String) -> Direction {
        Direction(code: code, name: label, terminal: terminal, label: label)
    }

    /// The preview's stations: those of the station list nearest Times Square, with their complexes (the board shows a complex once,
    /// as the app does)
    public static let stations: [Station] = [
        Station(id: "127", name: "Times Sq-42 St", coordinate: Coordinate(latitude: 40.75529, longitude: -73.987495), complexID: "611"),
        Station(id: "725", name: "Times Sq-42 St", coordinate: Coordinate(latitude: 40.755477, longitude: -73.987691), complexID: "611"),
        Station(id: "R16", name: "Times Sq-42 St", coordinate: Coordinate(latitude: 40.754672, longitude: -73.986754), complexID: "611"),
        Station(id: "A27", name: "42 St-Port Authority Bus Terminal", coordinate: Coordinate(latitude: 40.757308, longitude: -73.989735),
                complexID: "611"),
        Station(id: "R15", name: "49 St", coordinate: Coordinate(latitude: 40.759901, longitude: -73.984139), complexID: "10"),
        Station(id: "D15", name: "47-50 Sts-Rockefeller Ctr", coordinate: Coordinate(latitude: 40.758663, longitude: -73.981329),
                complexID: "225"),
        Station(id: "D16", name: "42 St-Bryant Pk", coordinate: Coordinate(latitude: 40.754222, longitude: -73.984569), complexID: "609"),
        Station(id: "724", name: "5 Av", coordinate: Coordinate(latitude: 40.753821, longitude: -73.981963), complexID: "609"),
        Station(id: "126", name: "50 St", coordinate: Coordinate(latitude: 40.761728, longitude: -73.983849), complexID: "316"),
    ]

    /// (station, route, direction, first-train offset in minutes, headway in minutes) of the preview's trips
    static let plan: [(String, String, Direction, Double, Double)] = [
        ("127", "1", dir("N", "Uptown", to: "Van Cortlandt Park-242 St"), 2.5, 5),
        ("127", "1", dir("S", "Downtown", to: "South Ferry"), 3.5, 5),
        ("127", "2", dir("S", "Downtown", to: "Flatbush Av-Brooklyn College"), 4.0, 6),
        ("127", "3", dir("N", "Uptown", to: "Harlem-148 St"), 6.5, 7),
        ("725", "7", dir("N", "Queens", to: "Flushing-Main St"), 3.0, 4),
        ("725", "7", dir("S", "Hudson Yards", to: "34 St-Hudson Yards"), 5.0, 4),
        ("R16", "N", dir("N", "Uptown", to: "Astoria-Ditmars Blvd"), 5.5, 8),
        ("R16", "Q", dir("S", "Downtown", to: "Coney Island-Stillwell Av"), 7.0, 8),
        ("R16", "R", dir("N", "Uptown", to: "Forest Hills-71 Av"), 9.0, 8),
        ("R16", "W", dir("S", "Downtown", to: "Whitehall St-South Ferry"), 11.0, 10),
        ("A27", "A", dir("N", "Uptown", to: "Inwood-207 St"), 4.5, 8),
        ("A27", "E", dir("S", "Downtown", to: "World Trade Center"), 6.0, 6),
        ("A27", "C", dir("S", "Downtown", to: "Euclid Av"), 8.0, 10),
        ("R15", "N", dir("S", "Downtown", to: "Coney Island-Stillwell Av"), 6.0, 8),
        ("R15", "R", dir("N", "Uptown", to: "Forest Hills-71 Av"), 10.0, 8),
        ("D15", "F", dir("S", "Downtown", to: "Coney Island-Stillwell Av"), 3.5, 6),
        ("D15", "D", dir("S", "Downtown", to: "Coney Island-Stillwell Av"), 5.0, 8),
        ("D15", "B", dir("N", "Uptown", to: "Bedford Park Blvd"), 7.5, 10),
        ("D15", "M", dir("N", "Uptown", to: "Forest Hills-71 Av"), 9.0, 10),
        ("D16", "F", dir("N", "Uptown", to: "Jamaica-179 St"), 8.5, 6),
        ("724", "7", dir("N", "Queens", to: "Flushing-Main St"), 6.0, 4),
        ("126", "1", dir("S", "Downtown", to: "South Ferry"), 9.5, 5),
        ("126", "2", dir("N", "Uptown", to: "Wakefield-241 St"), 11.5, 6),
    ]

    /// Generates a set of mock trips relative to `now`.
    /// - Parameter seed: different seeds give slightly different times, used for the "refresh" demo.
    public static func arrivals(now: Date, seed: Int = 0) -> [Arrival] {
        let jitter = Double(seed % 3) * 0.5
        var result: [Arrival] = []
        for (i, p) in plan.enumerated() {
            for k in 0..<3 {
                let minutes = p.3 + jitter + Double(k) * p.4
                result.append(Arrival(
                    id: "mock-\(p.0)-\(p.1)-\(p.2.code)-\(k)",
                    stationID: p.0, route: p.1, direction: p.2,
                    arrivalTime: now.addingTimeInterval(minutes * 60),
                    source: .mock,
                    status: (i == 3 && k == 0) ? .delayed : .normal,
                    updatedAt: now.addingTimeInterval(-30)
                ))
            }
        }
        return result
    }

    // MARK: - Demo mode (Manhattan, as the interactive demo page shows it)

    /// Demo mode's stations of a mode within `radiusMeters` (straight line) of a place, nearest first, all in its area
    /// (DemoArea.includesStation): subway stations from the station list, the tram's Manhattan station and the demo's PATH stations;
    /// MTA bus stops from the bus list, picked as for real; the demo's own train stations and piers (DemoData).
    public static func demoStations(_ system: TransitSystem, near c: Coordinate, radiusMeters: Double,
                                    catalog: StationCatalog?, buses: BusCatalog?) -> [Station] {
        func near(_ stations: [Station]) -> [Station] {
            stations.map { ($0, WalkEstimator.distanceMeters(c, $0.coordinate)) }
                .filter { $0.1 <= radiusMeters && DemoArea.includesStation($0.0.coordinate) }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
        switch system.mode {
        case .bus:
            return buses?.stations(near: c, radiusMeters: radiusMeters, where: DemoArea.includesStation) ?? []
        case .train:
            return near(DemoData.trainStops.map(\.station))
        case .ferry:
            return near(DemoData.ferryStops.map(\.station))
        default:
            return near(catalog?.stations(near: c, radiusMeters: radiusMeters) ?? [])
                + near(RooseveltIslandTram.stations) + near(DemoData.pathStops.map(\.station))
        }
    }

    /// Minutes apart each subway line leaves in Demo mode (the page's), 8 for any other
    static let demoSubwayEvery: [String: Double] = [
        "1": 6, "2": 8, "3": 8, "4": 8, "5": 8, "6": 5, "7": 4, "A": 8, "C": 10, "E": 6, "B": 10, "D": 8, "F": 6, "M": 8, "G": 8,
        "J": 8, "Z": 10, "L": 5, "N": 8, "Q": 8, "R": 8, "W": 10, "GS": 4, "FS": 8, "H": 10, "SI": 20,
    ]

    /// Minutes apart each bus route leaves in Demo mode (the page's): some Manhattan routes have their own; any other Select Bus
    /// Service route 8, express routes 30, Manhattan routes 12, the rest 15
    static func demoBusEvery(_ route: String) -> Double {
        let own: [String: Double] = ["M7": 10, "M20": 12, "M104": 10, "M42": 8, "M5": 10, "M55": 10, "M34+": 7, "M34A+": 10,
                                     "M50": 12, "M11": 10, "M1": 9, "M2": 9, "M3": 10, "M4": 8, "Q32": 12]
        if let every = own[route] { return every }
        if route.hasSuffix("+") { return 8 }
        if BusCatalog.service(ofRoute: route) == .express { return 30 }
        return route.hasPrefix("M") ? 12 : 15
    }

    /// The page's hash (each UTF-16 unit added to 31 times the total, as an unsigned 32-bit number): staggers first departures
    /// by station and line, the same at every refresh
    static func demoHash(_ text: String) -> UInt32 {
        text.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
    }

    /// Minutes to the first departure, by station and line: from 0.6 to just over `every`
    static func demoFirst(_ key: String, every: Double) -> Double {
        0.6 + Double(demoHash(key) % demoSpread(every)) / 10
    }

    /// Tenths of a minute the first departures are spread over: at least one, so a gap of 0 (or less) can't divide by zero
    static func demoSpread(_ every: Double) -> UInt32 {
        guard every.isFinite, every > 0 else { return 1 }
        return max(1, UInt32(min(every * 10, 100_000)))
    }

    /// A bus line's minutes to the first departure, by stop, route and direction: from 0.8, to a tenth of a minute
    static func demoBusFirst(_ key: String, every: Double) -> Double {
        ((0.8 + Double(demoHash(key) % demoSpread(every)) / 10) * 10).rounded() / 10
    }

    /// Demo departures at these stations, made up relative to `now` as the page does: each line both ways where it goes, every
    /// so many minutes for about the next 2 hours, the first staggered by station and line, the second way half a gap later; the
    /// second departure of a station's first line is late (unless it's a timetable's); `seed` moves them all a little at each
    /// refresh. Subway lines are the ones that stop there in the daytime (DemoData.subwayLines), with the station list's directions;
    /// bus stops have each route once for each destination, on their side of the street; the demo's own stations their lines.
    /// Lines whose operator has only a timetable show the timetable mark. The tram's times aren't made up (TransitModel adds them).
    /// For Plan a Trip (demoPlan) the same service goes on from `now` to the time asked: `from` and `to` give the departures in that
    /// time instead of the next 2 hours, `scheduled` makes all of them the timetables' (the timetable mark, never late), and
    /// `madeAt` is when they were made, which their age is counted from (the board says a time half a minute older than that is new)
    public static func demoArrivals(at stations: [Station], system: TransitSystem, catalog: StationCatalog?, buses: BusCatalog?,
                                    now: Date, seed: Int = 0, from: Date? = nil, to: Date? = nil, scheduled: Bool = false,
                                    madeAt: Date? = nil) -> [Arrival] {
        let jitter = Double(seed % 3) * 0.5
        // Minutes after `now`
        let start = from.map { $0.timeIntervalSince(now) / 60 } ?? 0
        let end = to.map { $0.timeIntervalSince(now) / 60 } ?? 125
        var result: [Arrival] = []
        func add(_ station: Station, line li: Int, route: String, direction: Direction, first: Double, every: Double,
                 timetable ownTimetable: Bool = false, express: Bool? = nil, bus: BusService? = nil) {
            // A line without a gap has no service to make up (and would never end below)
            guard every.isFinite, every > 0 else { return }
            let timetable = ownTimetable || scheduled
            let begin = first + jitter
            // The first one at `from` or later, counted from the one after `now`, so each keeps its place in the service (the late one too)
            var k = max(0, Int(((start - begin) / every).rounded(.up)))
            while true {
                let minutes = begin + Double(k) * every
                if minutes > end { break }
                let t = now.addingTimeInterval(minutes * 60)
                result.append(Arrival(
                    id: "demo-\(station.id)-\(route)-\(direction.code)-\(li)-\(k)",
                    stationID: station.id, route: route, direction: direction,
                    arrivalTime: t, source: .mock,
                    status: !timetable && li == 0 && k == 1 && direction.code == "N" ? .delayed : .normal,
                    updatedAt: madeAt.map { timetable ? $0 : $0.addingTimeInterval(-30) } ?? now.addingTimeInterval(-30),
                    isExpress: express, busService: bus,
                    // A timetable's time: shown with the timetable mark, as for real
                    isAssigned: timetable ? false : nil))
                k += 1
            }
        }
        // Bus stops of one group (the same name, either side of a street)
        var groups: [String: [String]] = [:]
        for s in stations { groups[s.complexID ?? s.id, default: []].append(s.id) }

        for station in stations {
            if let own = DemoData.stop(id: station.id) {
                for (li, line) in own.lines.enumerated() {
                    let first = demoFirst(station.id + line.route, every: line.every)
                    for (code, to) in [("N", line.north), ("S", line.south)] {
                        guard let to else { continue }
                        let offset = code == "S" && line.north != nil ? line.every / 2 : 0
                        add(station, line: li, route: line.route, direction: Direction(code: code, name: "To " + to, terminal: to),
                            first: first + offset, every: line.every, timetable: line.timetable)
                    }
                }
            } else if system.mode == .bus {
                guard let buses, let stop = buses.stop(id: station.id) else { continue }
                let side = buses.side(ofStop: stop.id, among: groups[station.complexID ?? station.id] ?? [station.id])
                var seen = Set<String>()
                var li = 0
                for rd in stop.routeDirections {
                    let to = buses.headsign(route: rd.route, direction: rd.direction)
                    guard seen.insert(rd.route + "|" + (to ?? "")).inserted else { continue }
                    defer { li += 1 }
                    guard let to else { continue }
                    let every = demoBusEvery(rd.route)
                    let service = BusCatalog.service(route: rd.route, destination: to)
                    add(station, line: li, route: rd.route, direction: Direction(code: side, name: "To " + to, terminal: to),
                        first: demoBusFirst(stop.id + rd.route + rd.direction, every: every), every: every,
                        express: service != .local, bus: service)
                }
            } else if let lines = DemoData.subwayLines[station.id] {
                var routes: [String] = []
                for line in lines where !routes.contains(line.route) { routes.append(line.route) }
                for line in lines {
                    let every = demoSubwayEvery[line.route] ?? 8
                    let both = line.code == "S" && lines.contains { $0.route == line.route && $0.code == "N" }
                    let direction = catalog?.direction(stationID: station.id, route: line.route, code: line.code)
                        ?? Direction(code: line.code, name: line.code == "N" ? "Northbound" : "Southbound")
                    add(station, line: routes.firstIndex(of: line.route) ?? 0, route: line.route, direction: direction,
                        first: demoFirst(station.id + line.route, every: every) + (both ? every / 2 : 0), every: every,
                        express: line.express)
                }
            }
        }
        return result
    }

    // MARK: - Plan a Trip in Demo mode

    /// What Plan a Trip says above Demo mode's results, as the real app says it at that time (PlannerModel puts it into words)
    public enum DemoPlanNote: Equatable, Sendable {
        /// On standby, live times come only once the app is on: subway stations and MTA bus stops show none, train stations and
        /// piers their timetables
        case turnOnForLiveTimes
        /// PATH has only live times, so none for a later time
        case pathLiveOnly
        /// On standby PATH shows its timetable: live times come only once the app is on
        case turnOnForPathLiveTimes
        /// MTA buses have only live times, so none for a later time
        case mtaBusLiveOnly
    }

    /// Plan a Trip's results in Demo mode
    public struct DemoPlan: Sendable {
        public var stations: [Station]
        public var arrivals: [Arrival]
        /// The times count as live data (leaving within 30 minutes, where the operator has live data, the app on); otherwise
        /// they are the timetables'
        public var live: Bool
        public var note: DemoPlanNote?
    }

    /// Plan a Trip in Demo mode, as the interactive demo page works it out: the demo's stations near the place (demoStations), with
    /// departures from the same made-up service as the main window's (pass its `base` time and `seed`, so a station shows the same
    /// times in both), from `leave` to the end of the time range. `live` is leaving within 30 minutes (PlannerModel.usesRealtime),
    /// `active` the app on (not on standby). Then as for real:
    /// - subway: live times only with the app on, else none; later, the timetable's. PATH has live times only: with the app on, its
    ///   timetable on standby, none later. The tram's times aren't made up (PlannerModel adds them, estimated as always)
    /// - MTA buses: live times only, and only with the app on; without them their stops aren't listed (the note says why)
    /// - trains and ferries: live times where the operator has them and the app is on, the timetables otherwise
    /// `now` is when the plan is made.
    public static func demoPlan(_ system: TransitSystem, near place: Coordinate, radiusMeters: Double, leave: Date,
                                window: TimeInterval, live: Bool, active: Bool, catalog: StationCatalog?, buses: BusCatalog?,
                                base: Date, seed: Int, now: Date) -> DemoPlan {
        let stations = demoStations(system, near: place, radiusMeters: radiusMeters, catalog: catalog, buses: buses)
        func times(_ list: [Station], scheduled: Bool) -> [Arrival] {
            guard !list.isEmpty else { return [] }
            return demoArrivals(at: list, system: system, catalog: catalog, buses: buses, now: base, seed: seed,
                                from: leave, to: leave.addingTimeInterval(window), scheduled: scheduled, madeAt: now)
        }
        switch system.mode {
        case .bus:
            let note: DemoPlanNote? = stations.isEmpty ? nil : !live ? .mtaBusLiveOnly : !active ? .turnOnForLiveTimes : nil
            // A stop with no times to show isn't listed, as in the real Plan a Trip, which lists only the MTA stops Bus Time answered for
            let shown = live && active ? stations : []
            return DemoPlan(stations: shown, arrivals: times(shown, scheduled: false), live: live && active, note: note)
        case .train, .ferry:
            let liveNear = stations.contains { s in DemoData.stop(id: s.id)?.lines.contains { !$0.timetable } ?? false }
            return DemoPlan(stations: stations, arrivals: times(stations, scheduled: !(live && active)),
                            live: live && active && liveNear, note: live && !active && liveNear ? .turnOnForLiveTimes : nil)
        default:
            let pathIDs = Set(DemoData.pathStops.map(\.station.id))
            let path = stations.filter { pathIDs.contains($0.id) }
            let subway = stations.filter { !pathIDs.contains($0.id) && !RooseveltIslandTram.isTramStation($0.id) }
            var note: DemoPlanNote?
            if live, !active, !subway.isEmpty { note = .turnOnForLiveTimes }
            if !path.isEmpty, note == nil { note = !live ? .pathLiveOnly : !active ? .turnOnForPathLiveTimes : nil }
            let arrivals = (live && !active ? [] : times(subway, scheduled: !live)) + (live ? times(path, scheduled: !active) : [])
            return DemoPlan(stations: stations, arrivals: arrivals, live: live, note: note)
        }
    }
}
