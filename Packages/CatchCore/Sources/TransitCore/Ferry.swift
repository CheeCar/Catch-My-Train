import Foundation

// MARK: - New York ferries (NYC Ferry, Staten Island Ferry, NY Waterway, Seastreak, Statue of Liberty ferry)
//
// Each has one official static GTFS, all free with no key. The app downloads them on the Mac the first time ferries are used (all small, tens of KB),
// then checks for updates on first use after the 1st of each month (same as the subway map):
// - NYC Ferry: https://nycferry.connexionz.net/rtt/public/resource/gtfs.zip
//   Also has GTFS-Realtime data (trip_id only; gives the actual departure at the previous stop and the predicted arrival at the next).
// - Staten Island Ferry (NYC DOT): https://www.nyc.gov/html/dot/downloads/misc/siferry-gtfs.zip
//   Schedule only, no realtime data: the UI must say clearly "No realtime data; times are from the schedule".
// - NY Waterway (mostly New Jersey ↔ Manhattan): https://nywaterway.connexionz.net/rtt/public/resource/gtfs.zip
//   Same system as NYC Ferry, with the same realtime format.
// - Seastreak (New Jersey Highlands area ↔ Manhattan): https://seastreak.com/api/transit/google_transit.zip, schedule only.
// - Statue of Liberty ferry (Statue City Cruises, Battery Park ↔ Liberty Island ↔ Ellis Island ↔ Liberty State Park):
//   Published by the National Park Service (NPS) at https://www.nps.gov/external-resources/gtfs/stli/statue-of-liberty-ferries.zip,
//   schedule only. One file per season; there can be days to weeks without data between seasons:
//   during that time its piers aren't shown (see active(from:)), and the app checks daily for a new one (see the app's FerryStore).
//   The main route is a loop (Battery Park → Liberty Island → Ellis Island → Battery Park); see Source.keepsLoops.
//
// Only keep trips where every pier is within the service area, in a metro area the operator runs in (areas.json); drop routes that
// go elsewhere (e.g. Seastreak's summer boats from New Bedford to Martha's Vineyard, in Greater Boston, with New York's data), see
// FerryBuilder.staysInItsAreas. Upper Hudson NY Waterway routes (Haverstraw–Ossining, etc.) are within the area.
//
// Route IDs all get a prefix so they never mix with subway or bus routes: NYC Ferry keeps each route separate (like "NYF-ER"),
// the others are each merged into one route ("SIF", "NYW", "SST"): riders don't use their route numbers; the destination is enough.
// Pier IDs get a prefix too: "nyf:<stop_id>", "sif:<stop_id>", "nyw:…", "sst:…".
// Each operator is downloaded and processed separately: if one fails to download or has bad data, the others still show (see FerryBuilder.build and the app's FerryStore).
//
// MARK: Trains (commuter rail) use the same setup
//
// Like ferries, trains are "several operators' schedules + realtime data for some of them", so they use the same format and the same logic,
// just stored and shown separately (trains are one transit system, ferries another; see TransitSystem and Source.system):
// - Long Island Rail Road (LIRR): https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip (official MTA, free, no key)
// - Metro-North Railroad: https://rrgtfsfeeds.s3.amazonaws.com/gtfsmnr.zip
// - Both have GTFS-Realtime data (MTA's api-endpoint.mta.info, no key), giving predicted times at each later stop of every train.
// - SEPTA Regional Rail (Philadelphia): https://www3.septa.org/developer/google_rail.zip, with GTFS-Realtime trip updates (free, no key)
//   that use the schedule's trip_ids. NJ Transit, Amtrak and the CTrail lines are schedule only.
// Train schedules are large (Metro-North's stop_times.txt is 27 MB, with half a year of trips), so only the next 45 days of trips are kept;
// LIRR data only runs a few weeks ahead, so when it's nearly used up the app checks daily for a new one (see endingSources). Every operator's
// timetable is also checked daily from a week before it runs out (see endingSoonSources).
// Route IDs look like "LIRR-BAB" (Babylon Branch), "MNR-HUD" (Hudson Line); station IDs: "lirr:<stop_id>", "mnr:<stop_id>".
// Train trips aren't limited to within NYC: keep all LIRR and Metro-North lines (complete map, and suburban destinations still show).

//
// MARK: PATH (New Jersey) uses the same setup too
//
// PATH (Port Authority Trans-Hudson): schedule at https://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip
// (compiled by Trillium for the Port Authority). When this data has expired (it can stay expired for months), PATH trips come from realtime data only:
// stations, lines and the map come from this data, and trips only from realtime data (ridepath.json, used by the official PATH app; see Path.swift).
// Expired trips aren't kept, except one trip per stop pattern (see Source.keepsPatterns); stations, directions and the map work as usual;
// checked on the 1st of each month, and a new schedule is used automatically once available. Route IDs look like "PATH-NWK-WTC", station IDs: "path:<stop_id>".
//
// MARK: SEPTA Metro and PATCO (Philadelphia) are kept with light rail
//
// - SEPTA Metro (the L, B and M lines and the T, G and D trolleys): its lines are in SEPTA's bus package
//   https://www3.septa.org/developer/google_bus.zip (route_type 0 and 1; the buses in it are read as a bus operator, see RegionalBusFeed),
//   with free GTFS-Realtime trip updates for its buses and Metro together (no key; the realtime trip_ids are the timetable's).
//   The package is 26 MB, so it's downloaded only once a place in use is in its area (see DownloadArea and PlacesInUse).
// - PATCO (Philadelphia to Lindenwold, run by the Delaware River Port Authority): its timetable at the address PATCO's developer page
//   links to; no realtime data.
// Both are stored with NJ Transit's light rail (TransitSystem.lightRail) and shown under Subway. Route IDs look like "SMT-L1" and
// "PAT-PATCO", station IDs "smt:<stop_id>" and "pat:<stop_id>".

public struct FerryFeed: Codable, Sendable, Equatable {

    public struct Route: Codable, Sendable, Equatable {
        /// "NYF-ER", "SIF"
        public var id: String
        /// Full route name, e.g. "East River", "Staten Island Ferry"
        public var name: String
        /// Hex color
        public var color: String
        /// Whether it has realtime data (Staten Island Ferry doesn't)
        public var realtime: Bool
    }

    public struct Pier: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var lat: Double
        public var lon: Double
        /// Station code (GTFS stop_code, e.g. "NYK" for LIRR Penn Station): used to match when realtime data uses codes instead of stop_id.
        /// Only recorded for trains; nil when absent.
        public var code: String? = nil
        /// The stop's own time zone (GTFS stop_timezone), only when its timetable gives one other than its operator's: its times are
        /// shown in it. Nil: its operator's (see FerryFeed.timeZone(ofTrip:))
        public var timeZone: String? = nil
        public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    public struct Trip: Codable, Sendable, Equatable {
        /// Prefixed trip ID ("nyf:…", "sif:…")
        public var id: String
        public var route: String
        public var service: String
        /// "N" (GTFS direction_id 0) or "S" (1); Staten Island Ferry is "N" leaving Whitehall and "S" leaving St. George
        public var direction: String
        /// Piers served in order
        public var stops: [String]
        /// Departure time at each pier (seconds since the start of the service day; can exceed 24 hours)
        public var times: [Int]
        /// Positions of drop-off-only piers where you can't board (GTFS pickup_type = 1, e.g. NY Waterway boats from Edgewater to Midtown
        /// only drop off at Port Imperial); nil when boarding is allowed everywhere.
        public var noBoarding: [Int]? = nil
        /// Destination shown when leaving each pier (same length as stops; empty string means use the terminal). Only loops need it:
        /// on a loop the terminal is the origin itself, so show the next stop (e.g. "Liberty Island" when leaving Battery Park).
        public var headsigns: [String]? = nil
        /// Train number (trip_short_name, e.g. Metro-North "1229"; NJ Transit's is in block_id, e.g. "3276"): used to match when the
        /// realtime trip_id doesn't match, and the only way NJ Transit's trains are matched (see Source.liveByTrainNumber).
        public var number: String? = nil
        /// The data's stop_sequence of each pier (same length as stops), for an operator whose live data names stops only by it
        /// (see Source.liveStopsBySequence); nil for the others
        public var sequences: [Int]? = nil

        /// Whether you can board this trip at the i-th pier (not at the terminal or drop-off-only piers).
        public func canBoard(at i: Int) -> Bool {
            i >= 0 && i < stops.count - 1 && !(noBoarding?.contains(i) ?? false)
        }

        /// Piers where you can board this trip.
        public var boardingStops: [String] {
            stops.indices.filter(canBoard(at:)).map { stops[$0] }
        }
    }

    public struct Service: Codable, Sendable, Equatable {
        /// bit0 = Monday … bit6 = Sunday
        public var weekdays: Int
        public var start: Int
        public var end: Int
        /// Added and removed dates (a Set, so checking a day needs no linear scan; NJ Transit buses have hundreds of added dates)
        public var added: Set<Int>
        public var removed: Set<Int>

        func runs(on day: Int) -> Bool {
            if removed.contains(day) { return false }
            if added.contains(day) { return true }
            return day >= start && day <= end && weekdays & (1 << Timetable.weekday(day)) != 0
        }
    }

    /// Operators among these routes that have realtime data (only download realtime data that's needed).
    /// PATH isn't here (its realtime data isn't GTFS-Realtime; see PathLive).
    /// accounts: operators the user has entered an account for (see Source.needsAccount); their realtime data is downloaded too.
    public static func realtimeSources(routes: [String], accounts: Set<Source> = []) -> [Source] {
        Source.allCases.filter { s in (s.realtimeURL != nil || accounts.contains(s)) && routes.contains { s.owns(route: $0) } }
    }

    /// Data version per operator (source rawValue → version from feed_info, or the start date when missing)
    public var versions: [String: String]
    public var routes: [Route]
    public var piers: [Pier]
    public var trips: [Trip]
    public var services: [String: Service]
    /// Route → polyline (each point is [latitude, longitude])
    public var shapes: [String: [[[Double]]]]
    /// Which way of reading the packages built this stored copy (see contentVersion). Copies stored before it was recorded have none and count as 0
    public var builtWith: Int? = nil
    /// Each operator's time zone as its timetable gives it (GTFS agency_timezone), by the prefix of its trip IDs ("hyl:", "njb:WRTA/"):
    /// its trips' days and times count in it. Copies stored before it was recorded have none (see timeZone(ofTrip:))
    public var zones: [String: String]? = nil
    /// The whole timetables of the bus companies whose live trips go by stops and time (RegionalBusFeed.liveByStopsAndTime), by the
    /// prefix of their trip IDs: a nearby piece carries them only to match those live trips (see RegionalBusFeed.realtime). Nil
    /// for everything else
    public var wholeTimetables: [String: WholeTimetable]? = nil
    /// Each trip's whole list of stop codes, for the bus companies whose live data names stops by their codes
    /// (RegionalBusFeed.liveByStopCodes), by the prefix of their trip IDs: a nearby piece carries them only to match those live
    /// trips (see RegionalBusFeed.realtime). Nil for everything else
    public var stopCodeLists: [String: StopCodeLists]? = nil

    /// The time zone a trip's times count in: its operator's (zones, the longest prefix of the trip's ID that has one). An operator
    /// without one (a copy stored before they were recorded) counts in its metro area's (areas.json; every area was New York's then),
    /// and one in no area in the subway's
    public func timeZone(ofTrip id: String) -> TimeZone {
        if let zones {
            var best: (length: Int, zone: String)?
            for (prefix, zone) in zones where id.hasPrefix(prefix) && prefix.count > (best?.length ?? -1) { best = (prefix.count, zone) }
            if let zone = best.flatMap({ TimeZone(identifier: $0.zone) }) { return zone }
        }
        return Self.areaTimeZone(ofTrip: id)
    }

    /// The part of a trip's ID that says whose it is: "njb:CODE/" for a bus company's, "src:" for a timetable source's (and NJ
    /// Transit's buses, "njb:"). Every trip with the same one counts in the same time zone
    static func operatorKey(_ id: String) -> Substring {
        let bus = Source.njTransitBus.rawValue + ":"
        if id.hasPrefix(bus), let slash = id.dropFirst(bus.count).firstIndex(of: "/") { return id[...slash] }
        guard let colon = id.firstIndex(of: ":") else { return id[...] }
        return id[...colon]
    }

    /// The time zone of the metro area a trip's operator is in (its first, by areas.json), from the trip's ID: "njb:CODE/…" is a bus
    /// company's, "njb:…" NJ Transit's buses, "src:…" a timetable source's
    static func areaTimeZone(ofTrip id: String) -> TimeZone {
        let areas: [MetroArea]
        if id.hasPrefix(Source.njTransitBus.rawValue + ":") {
            let rest = id.dropFirst(Source.njTransitBus.rawValue.count + 1)
            if let slash = rest.firstIndex(of: "/") {
                areas = MetroArea.areas(ofOperator: MetroArea.busOperatorID(String(rest[..<slash])))
            } else {
                areas = MetroArea.areas(of: .njTransitBus)
            }
        } else {
            areas = id.split(separator: ":", maxSplits: 1).first.flatMap { Source(rawValue: String($0)) }.map { MetroArea.areas(of: $0) } ?? []
        }
        return areas.first?.timeZone ?? Timetable.timeZone
    }

    /// How this version turns each system's downloaded packages into stored data. Raise a system's number when an update changes what is kept
    /// from a package the app already downloads, for example the service area (Amtrak and Hartford Line stations are cut to it, ferry routes
    /// reaching outside it are dropped) or which agencies of a package are kept. A new operator alone doesn't need it: a missing operator is
    /// downloaded anyway. A stored copy built with a lower number is downloaded and read again once, the first time it's used online (see
    /// FerryStore.ensure); until then the old copy is used.
    /// Trains, 1: Shore Line East and the stations of the larger service area come from the Amtrak package.
    /// Trains, 2: SEPTA's trips keep the data's stop_sequence, which its live data names stops by (see Source.liveStopsBySequence).
    /// Trains, 3: the service area's Berks County and western Chester County boxes (Amtrak's Keystone stop at Parkesburg).
    /// Trains, 4: Greater Boston's boxes (Amtrak from Westerly to Boston, the Downeaster to Dover, the Lake Shore Limited's Boston section).
    /// Trains, 5: Greater Hartford's and Western Massachusetts' boxes (the Hartford Line and Amtrak from Berlin to Springfield, Amtrak
    /// on to Holyoke, Northampton and Greenfield, and at Pittsfield).
    /// Trains, 6: NJ Transit's trips keep their train numbers (from block_id), which its live trips are matched by.
    /// Trains, 7, and ferries, PATH and light rail, 1: every operator's stations and trips are under its own name. A copy an
    /// optimized build made from packages that came back under another operator's name (see Together) is built again.
    /// Bus companies have their own mark, one each (see RegionalBusFeed.readingVersion).
    public static func contentVersion(for system: TransitSystem) -> Int {
        switch system {
        case .train: return 7
        case .ferry, .path, .lightRail: return 1
        default: return 0
        }
    }

    /// Whether this stored copy was built with an older way of reading the packages than this version's (see contentVersion)
    public func isOutdated(for system: TransitSystem) -> Bool {
        (builtWith ?? 0) < Self.contentVersion(for: system)
    }

    /// Marks this copy as built with this version's way of reading once every operator in it was read by this version (`read`). Otherwise the
    /// operators kept from `older` may still be read the old way, so the lower mark stays and they're read again. 0 isn't written, so the files
    /// of systems whose reading never changed stay as they were
    public mutating func markBuilt(for system: TransitSystem, read: Set<Source>, older: FerryFeed?) {
        let version = Self.contentVersion(for: system)
        let mark = sources.isSubset(of: read) ? version : min(older?.builtWith ?? 0, version)
        builtWith = mark > 0 ? mark : nil
    }

    public static let nycFerryURL = URL(string: "https://nycferry.connexionz.net/rtt/public/resource/gtfs.zip")!
    public static let statenIslandURL = URL(string: "https://www.nyc.gov/html/dot/downloads/misc/siferry-gtfs.zip")!
    public static let realtimeURL = URL(string: "https://nycferry.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate")!
    public static let nyWaterwayURL = URL(string: "https://nywaterway.connexionz.net/rtt/public/resource/gtfs.zip")!
    public static let nyWaterwayRealtimeURL = URL(string: "https://nywaterway.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate")!
    public static let seastreakURL = URL(string: "https://seastreak.com/api/transit/google_transit.zip")!
    public static let statueOfLibertyURL = URL(string: "https://www.nps.gov/external-resources/gtfs/stli/statue-of-liberty-ferries.zip")!
    public static let lirrURL = URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/gtfslirr.zip")!
    public static let metroNorthURL = URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/gtfsmnr.zip")!
    public static let lirrRealtimeURL = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/lirr%2Fgtfs-lirr")!
    public static let metroNorthRealtimeURL = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/mnr%2Fgtfs-mnr")!
    public static let pathURL = URL(string: "https://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip")!
    /// NJ Transit train and light rail schedules (free, no login; redirects to content.njtransit.com)
    public static let njTransitRailURL = URL(string: "https://www.njtransit.com/rail_data.zip")!
    /// Amtrak schedule (free, no login, updated daily)
    public static let amtrakURL = URL(string: "https://content.amtrak.com/content/gtfs/GTFS.zip")!
    /// CTrail Hartford Line schedule (CTDOT, free, no login; tried on a Mac)
    public static let hartfordLineURL = URL(string: "https://ctrides.com/hlgtfs.zip")!
    /// SEPTA Regional Rail schedule and realtime trip updates (free, no login; the realtime trip_ids are the schedule's, checked on a Mac)
    public static let septaRailURL = URL(string: "https://www3.septa.org/developer/google_rail.zip")!
    public static let septaRailRealtimeURL = URL(string: "https://www3.septa.org/gtfsrt/septarail-pa-us/Trip/rtTripUpdates.pb")!
    /// SEPTA's bus package, which has SEPTA Metro's lines too (free, no login; 26 MB), and the realtime trip updates for both (free,
    /// no key; the realtime trip_ids are the timetable's, checked on a Mac)
    public static let septaBusURL = URL(string: "https://www3.septa.org/developer/google_bus.zip")!
    public static let septaBusRealtimeURL = URL(string: "https://www3.septa.org/gtfsrt/septa-pa-us/Trip/rtTripUpdates.pb")!
    /// PATCO's timetable (free, no login), at the address PATCO's developer page links to (its own site's older address is gone)
    public static let patcoURL = URL(string: "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/13562/PATCO_GTFS.zip")!
    /// MARC's timetable and realtime trip updates (Maryland Transit Administration; free, no key; checked on a Mac). The Amtrak
    /// package has MARC's trains too, but its trip_ids don't match MARC's live data, so MARC's own timetable is used
    public static let marcURL = URL(string: "https://mdotmta-gtfs.s3.amazonaws.com/mdotmta_gtfs_marc.zip")!
    public static let marcRealtimeURL = URL(string: "https://mdotmta-gtfs-rt.s3.amazonaws.com/MARC+RT/marc-tu.pb")!
    /// MBTA's one package for its subway, Commuter Rail, buses and ferries (free, no key; the MassDOT Developers License Agreement
    /// asks that MassDOT be credited as the provider, see areas.json), and its one realtime file of trip updates for all of them
    public static let mbtaURL = URL(string: "https://cdn.mbta.com/MBTA_GTFS.zip")!
    public static let mbtaRealtimeURL = URL(string: "https://cdn.mbta.com/realtime/TripUpdates.pb")!
    /// The Cape May–Lewes Ferry's timetable (free, for developers' apps, says its developer page). The file name has the year in it and
    /// changes each year: the source list gives the new one
    public static let capeMayLewesURL = URL(string: "https://www.cmlf.com/wp-content/uploads/2026/06/CMLF_GTFS-2026.zip")!
    /// A timetable Trillium publishes for an operator (free, no key; the ferries around Boston, all checked on a Mac)
    static func trilliumURL(_ name: String) -> URL { URL(string: "https://data.trilliumtransit.com/gtfs/\(name)/\(name).zip")! }
    /// The National Park Service's timetables of the Boston Harbor Islands ferries (free, no key; like the Statue of Liberty ferry's)
    public static let harborIslandsURL = URL(string: "https://www.nps.gov/external-resources/gtfs/boha/boston-harbor-islands-ferry.zip")!
    public static let cathleenStoneURL = URL(string: "https://www.nps.gov/external-resources/gtfs/boha/cathleen-stone-island-ferry.zip")!
    /// CTrail Shore Line East (CTDOT; New Haven to New London, a few trips on to Bridgeport and Stamford): Amtrak publishes its timetable
    /// in the Amtrak package as agency 1230. It stays a line of its own there, with its own badge, name and color, and uses Amtrak's stations.
    /// The color is the red of its former own timetable data (EF3E42), a little darker so white text on the badge can be read (4.5:1);
    /// the Amtrak package gives it Amtrak's light blue
    public static let shoreLineEast = (agency: "1230", code: "SLE", name: "Shore Line East", color: "D9383C")

    /// The CapeFLYER's route ID ("MBR-CF"): MBTA's package, the Cape Cod Regional Transit Authority's train
    public static var mbtaCapeFlyerRoute: String { Source.mbtaRail.routePrefix + "CF" }

    /// Shore Line East's route ID ("AMK-SLE"): Amtrak's package, CTrail's line
    public static var shoreLineEastRoute: String { Source.amtrakNY.routePrefix + shoreLineEast.code }
    public static func isShoreLineEast(_ route: String) -> Bool { route == shoreLineEastRoute }

    public static let neededFiles: Set<String> = ["routes.txt", "trips.txt", "stops.txt", "stop_times.txt",
                                                  "calendar.txt", "calendar_dates.txt", "shapes.txt", "feed_info.txt", "agency.txt"]

    public static func decode(_ data: Data) throws -> FerryFeed {
        try JSONDecoder().decode(FerryFeed.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Which operators are in this data (any that were processed count, even if they currently have no trips serving New York).
    public var sources: Set<Source> {
        Set(Source.allCases.filter { s in versions[s.rawValue] != nil || routes.contains { s.owns(route: $0.id) } })
    }

    /// Fill in operators missing from this data from `other` (e.g. Staten Island Ferry failed to download this time, so use the last saved copy).
    public func filling(missingSourcesFrom other: FerryFeed) -> FerryFeed {
        var result = self
        for s in Source.allCases where !sources.contains(s) && other.sources.contains(s) {
            result.routes += other.routes.filter { s.owns(route: $0.id) }
            result.piers += other.piers.filter { s.owns(id: $0.id) }
            result.trips += other.trips.filter { s.owns(id: $0.id) }
            for (k, v) in other.services where s.owns(id: k) { result.services[k] = v }
            for (k, v) in other.shapes where s.owns(route: k) { result.shapes[k] = v }
            if let v = other.versions[s.rawValue] { result.versions[s.rawValue] = v }
            if let zone = other.zones?[s.rawValue + ":"] { result.zones = (result.zones ?? [:]).merging([s.rawValue + ":": zone]) { a, _ in a } }
        }
        return result
    }
}
