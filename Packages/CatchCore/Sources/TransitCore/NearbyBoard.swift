import Foundation

// MARK: - Trips organized by station (like the official MTA app: pick a station first, then see both directions)

/// One train (one row in the UI). The arrival time is most prominent; below it in small text: walk time and whether you can catch it.
public struct BoardTrain: Codable, Hashable, Identifiable, Sendable {
    public var id: String { evaluation.arrival.id }
    /// The station this train stops at (one of the complex's stations)
    public var station: Station
    public var route: String
    public var direction: Direction
    public var evaluation: CatchEvaluation
    /// If this train can't be caught, the first later "can try" train at the same station, route and direction.
    public var recommended: CatchEvaluation?

    public var arrivalTime: Date? { evaluation.arrival.arrivalTime }
    public var verdict: CatchVerdict { evaluation.verdict }

    public init(station: Station, route: String, direction: Direction,
                evaluation: CatchEvaluation, recommended: CatchEvaluation? = nil) {
        self.station = station
        self.route = route
        self.direction = direction
        self.evaluation = evaluation
        self.recommended = recommended
    }
}

/// One direction of a complex (GTFS N or S).
public struct BoardDirection: Codable, Hashable, Sendable {
    /// "N" or "S"
    public var code: String
    /// Directions of each route in this direction (sign direction name or terminal), in route order and deduplicated, used for the title.
    public var directions: [Direction]
    /// Routes stopping in this direction (MTA order)
    public var routes: [String]
    /// Upcoming trains sorted by arrival time (those without a time last), at most `maxTrainsPerDirection`.
    public var trains: [BoardTrain]
    /// With no trains in the arrival window: when the next one comes after it, as far as the data on this device says
    /// (nil: not known, or there are trains)
    public var next: Date?

    public init(code: String, directions: [Direction], routes: [String], trains: [BoardTrain], next: Date? = nil) {
        self.code = code
        self.directions = directions
        self.routes = routes
        self.trains = trains
        self.next = next
    }

    /// The earliest "can try" or "tight" train (used as a hint on the toggle button).
    public var firstCatchable: BoardTrain? {
        trains.first { $0.verdict == .canTry || $0.verdict == .tight }
    }
}

/// One item of a station's line in the sidebar (BoardStation.catchSummary)
public struct CatchSummaryItem: Hashable, Sendable {
    /// "N" or "S" when the line is by direction; nil for the earliest of both
    public var direction: String?
    /// The first train you can catch; nil when this direction has trains but none can be caught
    public var train: BoardTrain?

    public init(direction: String?, train: BoardTrain?) {
        self.direction = direction
        self.train = train
    }
}

/// A complex (or a single station): e.g. "42 St-Bryant Pk / 5 Av".
public struct BoardStation: Codable, Hashable, Identifiable, Sendable {
    /// Complex ID; the station ID when there is no complex info.
    public var id: String
    public var name: String
    /// Stations of the complex within walking range, sorted by walk time
    public var stations: [Station]
    /// Walk estimate to the nearest station
    public var walk: WalkEstimate
    public var range: SearchRange
    /// All routes stopping here (MTA order)
    public var routes: [String]
    public var north: BoardDirection
    public var south: BoardDirection

    public init(id: String, name: String, stations: [Station], walk: WalkEstimate, range: SearchRange,
                routes: [String], north: BoardDirection, south: BoardDirection) {
        self.id = id
        self.name = name
        self.stations = stations
        self.walk = walk
        self.range = range
        self.routes = routes
        self.north = north
        self.south = south
    }

    public func direction(_ code: String) -> BoardDirection { code == "S" ? south : north }

    /// The line under a station in the main window's sidebar: the first train you can catch (can try or tight, like the bar on the
    /// station page). By direction (subway: up and down arrows) each direction that has trains gets one item, with no train when none
    /// of them can be caught; otherwise only the earliest one of both directions. Empty when there is nothing to say.
    public func catchSummary(byDirection: Bool) -> [CatchSummaryItem] {
        if byDirection {
            return [north, south].filter { !$0.trains.isEmpty }
                .map { CatchSummaryItem(direction: $0.code, train: $0.firstCatchable) }
        }
        let firsts = [north, south].compactMap(\.firstCatchable)
        let best = firsts.filter { $0.arrivalTime != nil }.min { $0.arrivalTime! < $1.arrivalTime! } ?? firsts.first
        return best.map { [CatchSummaryItem(direction: nil, train: $0)] } ?? []
    }
}

/// Trip board for all nearby stations.
public struct NearbyBoard: Codable, Hashable, Sendable {
    public var generatedAt: Date
    /// Complexes within walking range, sorted by walk time (primary range first)
    public var stations: [BoardStation]
    /// Number of cancelled or skipped trips that were excluded, at all the stations together
    public var cancelledCount: Int
    /// The same per station (BoardStation.id): a station's page says only its own
    public var cancelledByStation: [String: Int]
    /// Oldest update time among the data used
    public var oldestDataUpdate: Date?

    public init(generatedAt: Date, stations: [BoardStation], cancelledCount: Int, cancelledByStation: [String: Int] = [:],
                oldestDataUpdate: Date?) {
        self.generatedAt = generatedAt
        self.stations = stations
        self.cancelledCount = cancelledCount
        self.cancelledByStation = cancelledByStation
        self.oldestDataUpdate = oldestDataUpdate
    }

    /// Cancelled or skipped trips at this station (of the lines the board was made for): what its page's footer says
    public func cancelledCount(at stationID: String) -> Int { cancelledByStation[stationID] ?? 0 }

    public var usedExtendedRange: Bool { stations.contains { $0.range == .extended } }

    public func station(id: String?) -> BoardStation? {
        guard let id else { return nil }
        return stations.first { $0.id == id }
    }
}

/// The selected station (complex ID). Shared by the main window, menu bar and widgets (stored in the shared folder).
public struct BoardSelection: Codable, Hashable, Sendable {
    public var stationID: String?

    public init(stationID: String? = nil) {
        self.stationID = stationID
    }

    /// Which station is actually shown: if the selected station is no longer nearby (e.g. the location changed), use the nearest one.
    public func station(in board: NearbyBoard) -> BoardStation? {
        board.station(id: stationID) ?? board.stations.first
    }

    /// Moves to the next (step = 1) or previous (step = -1) nearby station, cycling only among the nearest `limit`.
    /// When the shown station isn't among them, next goes to the first and previous to the last.
    public func moving(by step: Int, in board: NearbyBoard, limit: Int = 5) -> BoardSelection {
        let ids = board.stations.prefix(max(1, limit)).map(\.id)
        guard !ids.isEmpty else { return self }
        guard let current = station(in: board).flatMap({ ids.firstIndex(of: $0.id) }) else {
            return BoardSelection(stationID: step >= 0 ? ids[0] : ids[ids.count - 1])
        }
        return BoardSelection(stationID: ids[((current + step) % ids.count + ids.count) % ids.count])
    }
}

/// Why the nearby board has no stations to show (the main window, menu bar panel and widget say the same; the app words it).
public enum EmptyBoardReason: Equatable, Sendable {
    /// There is no starting place: none was ever chosen and there is no position to use (StartingPlace.missing)
    case noStartingPlace
    /// The current position is too far off to find the stations nearby (StartingPlace.tooApproximate)
    case locationTooApproximate
    /// The starting point is outside the service area
    case outsideArea
    /// Networking is turned off in Settings, so this mode's missing timetables can't be downloaded
    case networkOff
    /// This mode's timetables (for Subway, the PATH and light rail data) aren't on this Mac yet and are being downloaded
    case downloading
    /// They couldn't be downloaded
    case downloadFailed
    /// They're downloaded the first time the app is turned on (on standby; for Subway, the PATH and light rail data)
    case downloadsOnStart
    /// A problem that affects every station (the app's lastError)
    case error
    /// Still loading the departures
    case loading
    /// Nothing within walking range
    case noStationNearby

    /// Checked in this order.
    /// - Parameters:
    ///   - hasStartingPlace: there is a place to walk from (false: StartingPlace.missing)
    ///   - locationTooApproximate: the current position is too far off to use (StartingPlace.tooApproximate)
    ///   - timetableMissing: this mode's timetable data isn't on this Mac (Train and Ferry: none at all; Bus: its timetable part;
    ///     Subway: PATH or light rail)
    ///   - downloadFailed: downloading it failed (not counting stops by standby)
    ///   - hasError: a problem that affects every station was found (not the note that the network is off: with the data
    ///     on this Mac, turning the network on brings no station nearby)
    public static func of(mode: TransitSystem, hasStartingPlace: Bool, locationTooApproximate: Bool = false, outsideArea: Bool,
                          networkAllowed: Bool, timetableMissing: Bool, downloadFailed: Bool, isActive: Bool, hasStations: Bool,
                          hasError: Bool, isRefreshing: Bool) -> EmptyBoardReason {
        if !hasStartingPlace { return .noStartingPlace }
        if locationTooApproximate { return .locationTooApproximate }
        if outsideArea { return .outsideArea }
        // Train and ferry stations all come from the timetables; Bus and Subway also have MTA stations, so say it only when none is nearby
        let onlyTimetable = mode.mode == .train || mode.mode == .ferry
        if timetableMissing, onlyTimetable || !hasStations {
            // The network being off explains it only while data is missing
            if !networkAllowed { return .networkOff }
            if downloadFailed { return .downloadFailed }
            return isActive ? .downloading : .downloadsOnStart
        }
        if hasError { return .error }
        if isRefreshing && !hasStations { return .loading }
        return .noStationNearby
    }

    /// Only the running app gets past this (it's downloading or loading, or downloads once turned on): when the app isn't running,
    /// the widget asks for it instead of repeating it
    public var needsRunningApp: Bool {
        switch self {
        case .downloading, .downloadsOnStart, .loading: return true
        default: return false
        }
    }
}

/// What the main window's empty page offers to do next: every empty page that has a next step gets a button
public enum EmptyBoardAction: Equatable, Sendable {
    /// "Extend Range for Now" (its menu of +5 to +20 minutes)
    case extendRange
    /// "Choose a Place…" (the place picker)
    case choosePlace
    /// "Settings…", opening Settings at Privacy and permissions (where networking is turned on)
    case openSettings
    /// "Settings…", opening Settings at Search range (the sentence says to widen the range there)
    case rangeSettings
    /// "Refresh"
    case refresh
    /// "Start" (on standby)
    case start
    /// "Service Area" (the map window, showing the whole service area)
    case showServiceArea
}

extension EmptyBoardReason {
    /// Whether the main window's empty page says this reason in its bold line, rather than "No trains worth catching nearby"
    /// with the reason under it: every reason but no station nearby (which that line says) and no starting place (whose bold line
    /// names what's missing)
    public var isTheBoldLine: Bool { self != .noStationNearby && self != .noStartingPlace }

    /// A reason's text split for the empty page: its first line in bold, any others (an operator's own problem after a failed
    /// download, see downloadFailedText) under it as before
    public static func boldLine(of text: String) -> (bold: String, rest: String?) {
        guard let newline = text.firstIndex(of: "\n") else { return (text, nil) }
        let rest = text[text.index(after: newline)...]
        return (String(text[..<newline]), rest.isEmpty ? nil : String(rest))
    }

    /// The buttons for this reason, in order; none while something is on its way (downloading, loading)
    public var actions: [EmptyBoardAction] {
        switch self {
        case .noStartingPlace, .locationTooApproximate: return [.choosePlace]
        // The areas the app covers aren't named in the sentence (they'd make it longer with every area): the map shows them
        case .outsideArea: return [.choosePlace, .showServiceArea]
        case .noStationNearby: return [.extendRange, .choosePlace, .rangeSettings]
        case .networkOff: return [.openSettings]
        case .downloadFailed, .error: return [.refresh]
        case .downloadsOnStart: return [.start]
        case .downloading, .loading: return []
        }
    }
}

public enum NearbyBoardBuilder {

    /// Maximum number of trains shown per direction.
    public static let defaultMaxTrainsPerDirection = 8

    /// How far ahead of now a direction's next departure after the window is said (BoardDirection.next): less than a day, so its
    /// clock time alone says when ("Next: 4:00 PM" at 3:58 PM is today's, never tomorrow's)
    public static let nextWithin: TimeInterval = 24 * 3600 - 60

    /// The route order MTA uses (the order on station signs).
    public static let routeOrder = ["1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M",
                                    "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "FS", "H", "SI", "RIT"]

    public static func sortRoutes<S: Sequence>(_ routes: S) -> [String] where S.Element == String {
        let unique = Set(routes.map(MTARoute.normalize))
        return unique.sorted { a, b in
            let ia = routeOrder.firstIndex(of: a) ?? Int.max
            let ib = routeOrder.firstIndex(of: b) ?? Int.max
            // Bus routes sort by letter prefix, then by number (B2 before B11)
            return ia != ib ? ia < ib : BusCatalog.routeOrder(a, b)
        }
    }

    /// Organizes stations, walk times and trips into a trip board grouped by complex.
    /// - Parameters:
    ///   - routes: routes serving each station (from the station catalog), so routes without trips are shown too.
    ///   - routeFilter: show only these routes (nil means all).
    ///   - walkOrder: breaks ties between equal walk times (station ID → position, see TransitSnapshot.walkOrder); then by ID.
    ///   - clockOffset: server time − local time (seconds); defaults to the measured ClockSkew.current.
    ///   - observedAt: when the arrivals were looked at, for the staleness check (see CatchEvaluator); defaults to `now`.
    ///   - tooSoonKept: how many trains too soon to catch to keep before the first one worth trying (nil keeps them all).
    ///     They are dropped before the list is cut to `maxTrainsPerDirection`, so at a busy complex the cut doesn't leave only "Too soon".
    ///   - later: departures after the arrival window (looked up in the timetables on this device). They are never listed: a
    ///     direction with nothing in the window says when the first of them comes (BoardDirection.next). The ones after the window
    ///     among `arrivals` count too.
    public static func build(
        stations: [Station],
        walks: [String: WalkEstimate],
        arrivals: [Arrival],
        later: [Arrival] = [],
        settings: CatchSettings,
        now: Date,
        routes: [String: [String]] = [:],
        routeFilter: Set<String>? = nil,
        walkOrder: [String: Int]? = nil,
        maxTrainsPerDirection: Int = defaultMaxTrainsPerDirection,
        clockOffset: TimeInterval = ClockSkew.current,
        observedAt: Date? = nil,
        tooSoonKept: Int? = nil
    ) -> NearbyBoard {
        let s = settings.sanitized()

        // 1. Stations within walking range
        var inRange: [(station: Station, walk: WalkEstimate, range: SearchRange)] = []
        for station in stations {
            guard let walk = walks[station.id], let range = Recommender.classify(walk: walk, settings: s) else { continue }
            inRange.append((station, walk, range))
        }
        let stationByID = Dictionary(inRange.map { ($0.station.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 2. Trips per station, route and direction (dropping cancelled, departed, and those beyond the arrival time window)
        // Compared with server time (when the local clock is fast or slow, see ClockSkew): which trains have left, and the arrival time window
        let serverNow = now.addingTimeInterval(clockOffset)
        let windowEnd = serverNow.addingTimeInterval(s.arrivalWindowSeconds)
        // Cancellations are counted per trip: a train passing two nearby stations counts once.
        // Only ones that would still be shown count (not yet departed, within the arrival time window).
        var cancelledTrips = Set<String>()
        // And per station (complex): a train passing two of its platforms counts once there too
        var cancelledAt: [String: Set<String>] = [:]
        var oldest: Date?
        var groups: [String: [Arrival]] = [:]
        // The first one after the window, per complex and direction
        var nextAfterWindow: [String: Date] = [:]
        func noteLater(_ a: Arrival, at time: Date, station: Station) {
            guard a.status != .cancelled, time < serverNow.addingTimeInterval(nextWithin) else { return }
            let key = "\(complexKey(station))|\(a.direction.code)"
            if nextAfterWindow[key].map({ time < $0 }) ?? true { nextAfterWindow[key] = time }
        }
        for a in uniqueByID(arrivals) {
            guard let info = stationByID[a.stationID] else { continue }
            let route = MTARoute.normalize(a.route)
            if let routeFilter, !routeFilter.contains(route) { continue }
            if let t = a.arrivalTime, t < serverNow { continue }
            if let t = a.arrivalTime, t > windowEnd {
                noteLater(a, at: t, station: info.station)
                continue
            }
            if a.status == .cancelled {
                cancelledTrips.insert(tripKey(a))
                cancelledAt[complexKey(info.station), default: []].insert(tripKey(a))
                continue
            }
            oldest = min(oldest ?? a.updatedAt, a.updatedAt)
            groups["\(a.stationID)|\(route)|\(a.direction.code)", default: []].append(a)
        }
        for a in later {
            guard let info = stationByID[a.stationID], let t = a.arrivalTime, t > windowEnd else { continue }
            if let routeFilter, !routeFilter.contains(MTARoute.normalize(a.route)) { continue }
            noteLater(a, at: t, station: info.station)
        }

        // 3. Evaluate each train, and for ones that can't be caught find a later catchable one (can try or tight, like firstCatchable) on the same route
        var trainsByComplexDirection: [String: [BoardTrain]] = [:]
        for (_, list) in groups {
            guard let first = list.first, let info = stationByID[first.stationID] else { continue }
            let sorted = list.sorted(by: arrivalOrder)
            let evals = sorted.map {
                CatchEvaluator.evaluate(arrival: $0, walk: info.walk,
                                        entranceToPlatformSeconds: info.station.entranceToPlatformSeconds,
                                        settings: s, now: now, clockOffset: clockOffset, observedAt: observedAt)
            }
            let complex = complexKey(info.station)
            for (i, e) in evals.enumerated() {
                var recommended: CatchEvaluation?
                if e.verdict == .takeNext || e.verdict == .insufficientInfo {
                    recommended = evals[(i + 1)...].first { $0.verdict == .canTry || $0.verdict == .tight }
                }
                let train = BoardTrain(station: info.station, route: MTARoute.normalize(e.arrival.route),
                                       direction: e.arrival.direction, evaluation: e, recommended: recommended)
                trainsByComplexDirection["\(complex)|\(first.direction.code)", default: []].append(train)
            }
        }

        // 4. Group by complex
        var complexes: [String: [(station: Station, walk: WalkEstimate, range: SearchRange)]] = [:]
        for item in inRange { complexes[complexKey(item.station), default: []].append(item) }

        var result: [BoardStation] = []
        for (key, members) in complexes {
            let byWalk = members.sorted { a, b in
                if a.walk.walkSeconds != b.walk.walkSeconds { return a.walk.walkSeconds < b.walk.walkSeconds }
                let ra = walkOrder?[a.station.id] ?? Int.max, rb = walkOrder?[b.station.id] ?? Int.max
                return ra != rb ? ra < rb : a.station.id < b.station.id
            }
            guard let nearest = byWalk.first else { continue }
            let range: SearchRange = byWalk.contains { $0.range == .primary } ? .primary : .extended

            var allRoutes: [String] = []
            for m in byWalk { allRoutes += routes[m.station.id] ?? [] }
            var north = direction(code: "N", trains: trainsByComplexDirection["\(key)|N"] ?? [],
                                  max: maxTrainsPerDirection, tooSoonKept: tooSoonKept)
            var south = direction(code: "S", trains: trainsByComplexDirection["\(key)|S"] ?? [],
                                  max: maxTrainsPerDirection, tooSoonKept: tooSoonKept)
            if north.trains.isEmpty { north.next = nextAfterWindow["\(key)|N"] }
            if south.trains.isEmpty { south.next = nextAfterWindow["\(key)|S"] }
            // Roosevelt Island Tram: each tram station runs in only one direction, so the title is "To Manhattan" even with no trams for now (e.g. overnight)
            for way in byWalk.compactMap({ RooseveltIslandTram.way(atStation: $0.station.id) }) {
                if way.rawValue == "N", north.directions.isEmpty { north.directions = [way.direction] }
                if way.rawValue == "S", south.directions.isEmpty { south.directions = [way.direction] }
            }
            allRoutes += north.routes + south.routes
            var routeSet = sortRoutes(allRoutes)
            if let routeFilter { routeSet = routeSet.filter(routeFilter.contains) }

            result.append(BoardStation(
                id: key, name: complexName(byWalk.map(\.station)),
                stations: byWalk.map(\.station), walk: nearest.walk, range: range,
                routes: routeSet, north: north, south: south))
        }
        result.sort { a, b in
            if a.range != b.range { return a.range == .primary }
            // Stations without times (NoTimesStations) come after the ones with departures in the same range, however near they are
            let na = a.noTimes != nil, nb = b.noTimes != nil
            if na != nb { return nb }
            if a.walk.walkSeconds != b.walk.walkSeconds { return a.walk.walkSeconds < b.walk.walkSeconds }
            let ra = a.stations.first.flatMap { walkOrder?[$0.id] } ?? Int.max
            let rb = b.stations.first.flatMap { walkOrder?[$0.id] } ?? Int.max
            return ra != rb ? ra < rb : a.id < b.id
        }
        return NearbyBoard(generatedAt: now, stations: result, cancelledCount: cancelledTrips.count,
                           cancelledByStation: cancelledAt.mapValues(\.count), oldestDataUpdate: oldest)
    }

    /// One arrival per ID, in the original order: when the data lists the same trip at the same stop more than once,
    /// only the most recently updated copy is kept (each train row on the board needs its own ID)
    static func uniqueByID(_ arrivals: [Arrival]) -> [Arrival] {
        var position: [String: Int] = [:]
        var result: [Arrival] = []
        result.reserveCapacity(arrivals.count)
        for a in arrivals {
            if let i = position[a.id] {
                if a.updatedAt > result[i].updatedAt { result[i] = a }
            } else {
                position[a.id] = result.count
                result.append(a)
            }
        }
        return result
    }

    /// The trip ID (with the trailing station part removed, e.g. "trip|635N" → "trip")
    static func tripKey(_ a: Arrival) -> String {
        guard let bar = a.id.lastIndex(of: "|") else { return a.id }
        return String(a.id[..<bar]) + "|" + a.route
    }

    /// Grouping key for a complex: the MTA complex ID if there is one, otherwise the station ID.
    static func complexKey(_ station: Station) -> String {
        station.complexID.map { "c" + $0 } ?? station.id
    }

    /// Complex name: the shared name when most stations have the same name (e.g. Times Square); "A / B" for two differently named stations.
    static func complexName(_ members: [Station]) -> String {
        guard let first = members.first else { return "" }
        var counts: [String: Int] = [:]
        for m in members { counts[m.name, default: 0] += 1 }
        let names = members.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if names.count == 1 { return first.name }
        let top = names.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? first.name
        if (counts[top] ?? 0) > 1 { return top }
        return names.prefix(2).joined(separator: " / ")
    }

    private static func direction(code: String, trains: [BoardTrain], max: Int, tooSoonKept: Int?) -> BoardDirection {
        let sorted = trains.sorted { a, b in
            switch (a.arrivalTime, b.arrivalTime) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.route != b.route { return a.route < b.route }
                return a.id < b.id
            }
        }
        let routes = sortRoutes(trains.map(\.route))
        // Title: each route's direction name, deduplicated (e.g. B D F M are all "Uptown").
        // Routes without a sign direction name use the terminal, and trains in one direction may go to different terminals (e.g. some 7 trains only go to
        // Mets-Willets Point): look at all trips in this direction, list every terminal, with the busiest first;
        // don't just look at the first train (the title must cover every terminal).
        var seen = Set<String>()
        var directions: [Direction] = []
        for route in routes {
            var counts: [String: Int] = [:]
            var found: [(key: String, direction: Direction)] = []
            for train in sorted where train.route == route {
                let d = train.direction
                let key = d.label ?? d.terminal ?? d.name
                if counts[key] == nil { found.append((key, d)) }
                counts[key, default: 0] += 1
            }
            // More trips first; on a tie, by the earliest train
            let ordered = found.enumerated().sorted { a, b in
                let ca = counts[a.element.key] ?? 0, cb = counts[b.element.key] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            for item in ordered where seen.insert(item.element.key).inserted {
                directions.append(item.element.direction)
            }
        }
        // Trains too soon to catch at the front: keep only `tooSoonKept` of them, then cut. When every train is too soon, keep the first ones.
        var start = 0
        if let tooSoonKept, let firstUseful = sorted.firstIndex(where: { $0.verdict != .takeNext }) {
            start = Swift.max(0, firstUseful - Swift.max(0, tooSoonKept))
        }
        return BoardDirection(code: code, directions: directions, routes: routes,
                              trains: Array(sorted[start...].prefix(Swift.max(1, max))))
    }

    private static func arrivalOrder(_ lhs: Arrival, _ rhs: Arrival) -> Bool {
        switch (lhs.arrivalTime, rhs.arrivalTime) {
        case let (l?, r?): return l != r ? l < r : lhs.id < rhs.id
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.id < rhs.id
        }
    }
}
