import Foundation

// MARK: - Basic data models
// These types only describe "what the data is" and contain no UI code.
// All are Codable, so they can be shared as JSON between the main app and the widget through their shared folder.

/// Latitude/longitude coordinate (no CoreLocation dependency, so it can be tested on any platform).
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// A position read from a data file can be used: finite numbers, latitude within ±90 and longitude within ±180,
    /// and not 0,0 (a common placeholder for a missing position)
    public static func isUsable(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }
}

/// Station entrance. A station may have several entrances, possibly on both sides of the street.
public struct StationEntrance: Codable, Hashable, Sendable {
    public var name: String
    public var coordinate: Coordinate

    public init(name: String, coordinate: Coordinate) {
        self.name = name
        self.coordinate = coordinate
    }
}

/// Direction of travel, e.g. "Uptown" or "To Woodlawn" (toward Woodlawn).
public struct Direction: Codable, Hashable, Sendable {
    /// Direction code in GTFS, e.g. "N" / "S".
    public var code: String
    /// English display name (the UI rearranges it per language, see CatchText).
    public var name: String
    /// Terminal name, e.g. "Woodlawn". The UI uses it to build "To Woodlawn" in each language.
    public var terminal: String?
    /// Direction name on station signage (official MTA), e.g. "Uptown" "Manhattan" "Queens".
    /// nil when the official signage only says something generic like "Outbound" or "Northbound"; the UI uses the terminal instead.
    public var label: String?

    public init(code: String, name: String, terminal: String? = nil, label: String? = nil) {
        self.code = code
        self.name = name
        self.terminal = terminal
        self.label = label
    }
}

/// Station (a GTFS parent station).
public struct Station: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    public var entrances: [StationEntrance]
    /// Extra time (seconds) from the entrance to the platform, e.g. stairs, fare gates, changing platforms.
    public var entranceToPlatformSeconds: TimeInterval
    /// MTA complex ID. Stations in the same complex are connected inside, e.g. 42 St-Bryant Pk and 5 Av. nil if none.
    public var complexID: String?

    public init(
        id: String,
        name: String,
        coordinate: Coordinate,
        entrances: [StationEntrance] = [],
        entranceToPlatformSeconds: TimeInterval = 90,
        complexID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.entrances = entrances
        self.entranceToPlatformSeconds = entranceToPlatformSeconds
        self.complexID = complexID
    }
}

/// Source of the arrival time. Must be clearly distinguished; scheduled times must never pose as realtime predictions.
public enum ArrivalSource: String, Codable, Sendable {
    /// GTFS-Realtime prediction
    case realtime
    /// GTFS static scheduled timetable
    case scheduled
    /// Made-up data (Demo mode, widget gallery preview)
    case mock
}

/// Trip status.
public enum TripStatus: String, Codable, Sendable {
    case normal
    case delayed
    case cancelled
}

/// A trip's predicted arrival at a station.
public struct Arrival: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var stationID: String
    /// Route name, e.g. "L", "6", "Q".
    public var route: String
    public var direction: Direction
    /// The trip's one time at the station: the one shown, and the one whether it can be caught, "Leave by", reminders, Plan a
    /// Trip and the widget all go by. A trip has no other time (each source takes one, its arrival or its departure, the same in
    /// its timetable and its live data). nil means "no prediction" (missing data).
    public var arrivalTime: Date?
    public var source: ArrivalSource
    public var status: TripStatus
    /// When the data source generated/updated this prediction, used to tell if it's stale.
    public var updatedAt: Date
    /// Express (true) or local (false) at this station; nil when unknown (e.g. scheduled timetable, mock data).
    public var isExpress: Bool?
    /// Bus service type (Local / Limited / SBS / Express). nil for subway.
    public var busService: BusService?
    /// MTA subway only: false when the realtime data lists this trip but no train is assigned to it yet, so its times are still the timetable's.
    /// nil when the data doesn't say (every other provider).
    public var isAssigned: Bool?
    /// The station's own time zone (IANA name), when its timetable gives it: its times are shown in it. Nil: the metro area's
    /// (every station now; a station in another zone than the rest of its area would have one, see FerryFeed.Pier.timeZone)
    public var timeZone: String?

    /// The time comes from a timetable: a scheduled trip, or a trip in the realtime data with no train assigned yet.
    /// The UI marks these with the timetable icon.
    public var isTimetableTime: Bool { source == .scheduled || isAssigned == false }

    public init(
        id: String,
        stationID: String,
        route: String,
        direction: Direction,
        arrivalTime: Date?,
        source: ArrivalSource,
        status: TripStatus = .normal,
        updatedAt: Date,
        isExpress: Bool? = nil,
        busService: BusService? = nil,
        isAssigned: Bool? = nil,
        timeZone: String? = nil
    ) {
        self.id = id
        self.stationID = stationID
        self.route = route
        self.direction = direction
        self.arrivalTime = arrivalTime
        self.source = source
        self.status = status
        self.updatedAt = updatedAt
        self.isExpress = isExpress
        self.busService = busService
        self.isAssigned = isAssigned
        self.timeZone = timeZone
    }

    /// The station's own time zone, if it has one (see timeZone)
    public var stationTimeZone: TimeZone? { timeZone.flatMap(TimeZone.init(identifier:)) }
}

extension Arrival {
    /// The earliest of these at each station, on each route and in each direction (those without a time are left out), by time:
    /// all a board needs to say when the next one comes after its arrival window (NearbyBoardBuilder.build's `later`)
    public static func firstPerDirection(_ arrivals: [Arrival]) -> [Arrival] {
        var first: [String: Arrival] = [:]
        for a in arrivals {
            guard let t = a.arrivalTime, a.status != .cancelled else { continue }
            let key = "\(a.stationID)|\(a.route)|\(a.direction.code)"
            if let kept = first[key], let keptTime = kept.arrivalTime, keptTime <= t { continue }
            first[key] = a
        }
        return first.values.sorted { a, b in
            let ta = a.arrivalTime ?? .distantFuture, tb = b.arrivalTime ?? .distantFuture
            return ta != tb ? ta < tb : a.id < b.id
        }
    }
}

/// Whose live data the shown departures are (the source in the menu bar panel's and the widget's data status): one operator by
/// the name areas.json gives it (ModeCoverage.liveName), so a new area's operators need no new words
public enum LiveSource: Hashable, Sendable {
    /// One operator's: "MTA" (its subway, buses, LIRR and Metro-North), "PATH", "SEPTA", "MBTA"…
    case one(String)
    /// Several ferry operators' together (NYC Ferry and NY Waterway)
    case ferries
    /// Several operators', or one without a name
    case several
    /// Nothing shown is live (e.g. only light rail without an NJ Transit account, or just the Staten Island Ferry): it never goes stale
    case timetable

    public var isLive: Bool { self != .timetable }

    /// From the departures themselves; a trip with no train assigned yet still has the timetable's time.
    /// Before any departures arrive, a mode without a timetable feed (subway, MTA buses) names the operator that comes with the app
    public static func of(_ arrivals: [Arrival], system: TransitSystem) -> LiveSource {
        let mode = system.mode
        if arrivals.isEmpty, !system.usesTimetableFeed {
            let bundled = mode == .bus ? ModeCoverage.mtaBusID : ModeCoverage.subwayID
            return ModeCoverage.liveName(ofOperator: bundled).map(LiveSource.one) ?? .several
        }
        let live = arrivals.filter { $0.source == .realtime && !$0.isTimetableTime }
        guard !live.isEmpty else { return .timetable }
        let names = Set(live.map { ModeCoverage.liveName(ofOperator: operatorID(route: $0.route, mode: mode)) })
        if names.count == 1, let only = names.first, let name = only { return .one(name) }
        return mode == .ferry ? .ferries : .several
    }

    /// The same for one station's departures (the menu bar panel and the widget show one at a time): the other stations nearby
    /// don't count, so MTA's trains beside a PATH station still say "MTA live". All of them when no station is shown, or when it
    /// has none yet, unless none of its lines can ever be live (a stop of bus companies that publish only timetables, with
    /// nothing in the arrival window, says "Timetable", not the live data of the stops around it)
    public static func of(_ arrivals: [Arrival], at station: BoardStation?, system: TransitSystem) -> LiveSource {
        guard let station else { return of(arrivals, system: system) }
        let ids = Set(station.stations.map(\.id))
        let its = arrivals.filter { ids.contains($0.stationID) }
        if its.isEmpty, !station.routes.isEmpty, !station.routes.contains(where: canBeLive) { return .timetable }
        return of(its.isEmpty ? arrivals : its, system: system)
    }

    /// Whether this line's times can be live at all: its operator publishes live data, or does with the user's key or account.
    /// A line of no timetable operator is MTA's (its subway and buses)
    static func canBeLive(route: String) -> Bool {
        if let feed = RegionalBusFeed.of(route: route) { return feed.canBeLive }
        guard let source = FerryFeed.Source.of(route: route) else { return true }
        return source.hasRealtime || source.liveWithAccount
    }

    /// The areas.json id of the operator whose route this is: by its prefix (FerryFeed.Source, the bus companies by
    /// RegionalBusFeed); a route without one is MTA's (its subway and buses)
    static func operatorID(route: String, mode: TransitSystem) -> String {
        guard let source = FerryFeed.Source.of(route: route) else {
            return mode == .bus ? ModeCoverage.mtaBusID : ModeCoverage.subwayID
        }
        if source == .njTransitBus, let feed = RegionalBusFeed.of(route: route), !feed.code.isEmpty {
            return MetroArea.busOperatorID(feed.code)
        }
        return source.rawValue
    }
}

/// Source of walking time: a real route (e.g. a MapKit walking route) or a straight-line estimate.
public enum WalkSource: String, Codable, Sendable {
    case route
    case estimated
}

/// Walking estimate from the user's location to a station.
public struct WalkEstimate: Codable, Hashable, Sendable {
    /// Walking time (seconds) from the user's location to the station entrance, excluding entry time.
    public var walkSeconds: TimeInterval
    /// Straight-line distance (meters), used only for initial filtering and display.
    public var straightLineMeters: Double
    public var source: WalkSource
    public var entranceName: String?
    /// Length of the real walking route (meters), present only for `.route` when it comes from route distance.
    public var routeMeters: Double?
    /// true when the straight line of an estimate crosses a river or a bay (WaterMap), so the real walk may be much longer;
    /// nil otherwise. Optional so walks saved before it existed still read
    public var acrossWater: Bool?

    public init(walkSeconds: TimeInterval, straightLineMeters: Double, source: WalkSource,
                entranceName: String? = nil, routeMeters: Double? = nil, acrossWater: Bool = false) {
        self.walkSeconds = walkSeconds
        self.straightLineMeters = straightLineMeters
        self.source = source
        self.entranceName = entranceName
        self.routeMeters = routeMeters
        self.acrossWater = acrossWater ? true : nil
    }

    /// A straight-line estimate across the water: the verdict is "Not sure" at best, and the walk says why (CatchEvaluator)
    public var isAcrossWater: Bool { source == .estimated && acrossWater == true }
}
