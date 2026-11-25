import Foundation

// MARK: - NJ Transit bus (New Jersey)
//
// Official static GTFS: https://www.njtransit.com/bus_data.zip (free, no login required; about 50 MB).
// 263 routes, 16,564 stops, 33,287 trips, 1,776,808 stop_times rows (77 MB unzipped), shapes.txt 125 MB,
// calendar_dates.txt only (checked on a Mac). Live times need the user's own NJ Transit developer account (see NJTransitLive); without one, timetable only.
//
// Too large to turn into a single FerryFeed like trains and ferries (tens of MB of JSON, one or two hundred MB in memory):
// - After download it's compacted on the Mac into one binary file (NJBusIndex, about 10 MB): stops, routes, stop patterns (trips with the same pattern share one),
//   each trip's times (seconds, UInt32), the calendar for the next 45 days, plus the bus map (the most common, simplified path per route and direction).
//   A stop pattern also records its drop-off-only stops (GTFS pickup_type = 1).
// - At use time only the slice near the user is taken and made into an ordinary FerryFeed: nearby stops and the trips through them (keeping only nearby stops and the terminal),
//   nearby stations, arrival times, directions and trip planning all work like trains and ferries (drop-off-only stops can't be boarded there either).
//   Leaving the slice (changing location) takes a new one.
// Route IDs look like "NJB-107" (route 107), stop IDs "njb:<stop_id>", trip IDs "njb:<trip_id>".

public struct NJBusIndex: Sendable {
    public static let builtInURL = URL(string: "https://www.njtransit.com/bus_data.zip")!
    /// The address: the source list's, or the one in code
    public static var url: URL { SourceList.timetableURL(for: FerryFeed.Source.njTransitBus.rawValue) ?? builtInURL }
    /// Route color: the data has all black, so use NJ Transit blue
    public static let color = "1A4B9B"
    static let magic: [UInt8] = Array("CMNB".utf8)
    /// File format. 2 added each stop pattern's drop-off-only stops (GTFS pickup_type = 1). 3 added the company's time zone (agency_timezone)
    /// and the stops that have their own (stop_timezone). 4 added the stops' codes (stop_code, the number on the stop's sign). Older files
    /// still read (format 1 with boarding allowed everywhere, as they don't list drop-off-only stops; before 3 with no time zone, so the
    /// company's metro area's is used; before 4 with no codes), until the next monthly check rebuilds them (sameContent sees the format
    /// change, so the new file is written); a newer format than this is unreadable, like a damaged file, so that operator counts as
    /// missing and is downloaded again.
    static let formatVersion: UInt32 = 4
    /// Only keep trips for this many days starting yesterday (same as trains)
    static let keepDays = 45

    struct Pattern: Sendable, Equatable {
        var route: Int
        /// 0 or 1 (GTFS direction_id)
        var direction: UInt8
        var headsign: String
        var stops: [UInt16]
        /// Positions in stops where riders can't board, only get off (GTFS pickup_type = 1); never the terminal. Empty in format 1 files.
        var noBoarding: [UInt16] = []
    }

    /// Data version (the earliest service date in the data, e.g. "20260915")
    public let version: String
    public let builtAt: Date
    let stopIDs: [String]
    let stopNames: [String]
    let stopLat: [Double]
    let stopLon: [Double]
    /// Route short name ("107")
    let routeNames: [String]
    let serviceIDs: [String]
    let serviceDates: [[Int]]
    let patterns: [Pattern]
    let tripIDs: [String]
    let tripPattern: [UInt32]
    let tripService: [UInt16]
    let tripTimes: [UInt32]
    /// Each trip's time at each stop (seconds after service day start, little-endian UInt32), ordered by position in tripTimes.
    /// It's the chunk inside the file itself: not copied into an array when the file is memory-mapped; read with time(_:)
    let timeBytes: Data
    /// Bus map (SubwayMap JSON, likewise a chunk of the file)
    let mapJSON: Data
    /// The company's time zone (GTFS agency_timezone), from format 3; nil in older files and when the data has none usable
    public let timeZone: String?
    /// Stops with a time zone of their own (stop_timezone, where it isn't the company's), by stop index; from format 3
    let stopTimeZones: [Int: String]
    /// Each stop's code (GTFS stop_code, the number on the stop's sign; "" for a stop without one), from format 4; empty in older
    /// files. NJ Transit's live data names stops by it (see RegionalBusFeed.liveByStopCodes)
    let stopCodes: [String]

    /// Stop → stop patterns through it; stop pattern → trips. Stored as one block (offset table + contents),
    /// instead of over ten thousand small arrays (memory left fragmented after release that the system couldn't reclaim)
    let stopPatternStart: [Int32]
    let stopPatternList: [Int32]
    let patternTripStart: [Int32]
    let patternTripList: [Int32]

    func time(_ i: Int) -> UInt32 {
        timeBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
    }

    func stopPatterns(_ stop: Int) -> ArraySlice<Int32> {
        stopPatternList[Int(stopPatternStart[stop])..<Int(stopPatternStart[stop + 1])]
    }

    func patternTrips(_ pattern: Int) -> ArraySlice<Int32> {
        patternTripList[Int(patternTripStart[pattern])..<Int(patternTripStart[pattern + 1])]
    }

    /// Which operator's data (NJ Transit, or one of the Long Island, Hudson Valley or Connecticut operators; see RegionalBusFeed)
    public let feed: RegionalBusFeed

    /// Lat/lon bounds of all stops: when moving elsewhere, only reread the operators whose bounds are in reach
    public struct Bounds: Sendable, Equatable {
        public var minLat, maxLat, minLon, maxLon: Double

        /// Whether anything within radiusMeters of center could be in bounds (rough lat/lon estimate, erring on the generous side)
        public func reaches(_ center: Coordinate, radiusMeters: Double) -> Bool {
            let dLat = radiusMeters / 111_000
            let dLon = radiusMeters / (111_000 * max(0.2, cos(center.latitude * .pi / 180)))
            return center.latitude + dLat >= minLat && center.latitude - dLat <= maxLat
                && center.longitude + dLon >= minLon && center.longitude - dLon <= maxLon
        }
    }

    public var bounds: Bounds {
        Bounds(minLat: stopLat.min() ?? 0, maxLat: stopLat.max() ?? 0, minLon: stopLon.min() ?? 0, maxLon: stopLon.max() ?? 0)
    }

    public var stopCount: Int { stopIDs.count }
    public var tripCount: Int { tripIDs.count }
    public var routeCount: Int { routeNames.count }

    // MARK: Reading

    public init(data: Data, feed: RegionalBusFeed = .njTransit) throws {
        self.feed = feed
        var r = ByteReader(data: data)
        guard try r.bytes(4) == Self.magic else { throw TimetableError.badFormat }
        let format = try r.u32()
        guard (1...Self.formatVersion).contains(format) else { throw TimetableError.badFormat }
        builtAt = Date(timeIntervalSince1970: TimeInterval(try r.u32()))
        version = try Self.string(&r)
        let stopCount = Int(try r.u32())
        var ids: [String] = [], names: [String] = [], lats: [Double] = [], lons: [Double] = []
        // A stop is at least 12 bytes (two empty strings and two coordinates), a trip too (empty ID, pattern, service, times)
        let stopRoom = r.room(for: stopCount, minSize: 12)
        ids.reserveCapacity(stopRoom); names.reserveCapacity(stopRoom)
        for _ in 0..<stopCount {
            ids.append(try Self.string(&r))
            names.append(try Self.string(&r))
            lats.append(Double(Int32(bitPattern: try r.u32())) / 1_000_000)
            lons.append(Double(Int32(bitPattern: try r.u32())) / 1_000_000)
        }
        var routes: [String] = []
        for _ in 0..<Int(try r.u32()) { routes.append(try Self.string(&r)) }
        var svcIDs: [String] = [], svcDates: [[Int]] = []
        for _ in 0..<Int(try r.u32()) {
            svcIDs.append(try Self.string(&r))
            var dates: [Int] = []
            for _ in 0..<Int(try r.u16()) { dates.append(Int(try r.u32())) }
            svcDates.append(dates)
        }
        var pats: [Pattern] = []
        for _ in 0..<Int(try r.u32()) {
            let route = Int(try r.u16())
            let dir = try r.u8()
            let headsign = try Self.string(&r)
            var stops: [UInt16] = []
            for _ in 0..<Int(try r.u16()) {
                let s = try r.u16()
                guard Int(s) < stopCount else { throw TimetableError.badFormat }
                stops.append(s)
            }
            var noBoarding: [UInt16] = []
            if format >= 2 {
                let count = Int(try r.u16())
                noBoarding.reserveCapacity(r.room(for: count, minSize: 2))
                for _ in 0..<count {
                    let i = try r.u16()
                    guard Int(i) < stops.count - 1 else { throw TimetableError.badFormat }
                    noBoarding.append(i)
                }
            }
            guard route < routes.count, stops.count >= 2 else { throw TimetableError.badFormat }
            pats.append(Pattern(route: route, direction: dir, headsign: headsign, stops: stops, noBoarding: noBoarding))
        }
        let tripCount = Int(try r.u32())
        var tIDs: [String] = [], tPat: [UInt32] = [], tSvc: [UInt16] = [], tTimes: [UInt32] = []
        let tripRoom = r.room(for: tripCount, minSize: 12)
        tIDs.reserveCapacity(tripRoom); tPat.reserveCapacity(tripRoom)
        tSvc.reserveCapacity(tripRoom); tTimes.reserveCapacity(tripRoom)
        for _ in 0..<tripCount {
            tIDs.append(try Self.string(&r))
            let p = try r.u32()
            let s = try r.u16()
            guard Int(p) < pats.count, Int(s) < svcIDs.count else { throw TimetableError.badFormat }
            tPat.append(p); tSvc.append(s); tTimes.append(try r.u32())
        }
        let timeCount = Int(try r.u32())
        guard r.position + timeCount * 4 <= data.count else { throw TimetableError.badFormat }
        timeBytes = data[try r.range(timeCount * 4)]
        for i in 0..<tripCount where Int(tTimes[i]) + pats[Int(tPat[i])].stops.count > timeCount { throw TimetableError.badFormat }
        let mapLength = Int(try r.u32())
        mapJSON = data[try r.range(mapLength)]
        var zone: String?
        var stopZones: [Int: String] = [:]
        if format >= 3 {
            let named = try Self.string(&r)
            zone = named.isEmpty ? nil : named
            for _ in 0..<Int(try r.u32()) {
                let i = Int(try r.u32())
                guard i < stopCount else { throw TimetableError.badFormat }
                stopZones[i] = try Self.string(&r)
            }
        }
        var codes: [String] = []
        if format >= 4 {
            // One for every stop, in the stops' order
            guard Int(try r.u32()) == stopCount else { throw TimetableError.badFormat }
            codes.reserveCapacity(r.room(for: stopCount, minSize: 2))
            for _ in 0..<stopCount { codes.append(try Self.string(&r)) }
        }
        timeZone = zone
        stopTimeZones = stopZones
        stopCodes = codes

        stopIDs = ids; stopNames = names; stopLat = lats; stopLon = lons
        routeNames = routes; serviceIDs = svcIDs; serviceDates = svcDates; patterns = pats
        tripIDs = tIDs; tripPattern = tPat; tripService = tSvc; tripTimes = tTimes

        // Stop → stop patterns: count how many per stop first, then fill in one pass (a pattern stopping twice at one stop counts once)
        var uniqueStops: [[UInt16]] = pats.map { Array(Set($0.stops)).sorted() }
        var stopStart = [Int32](repeating: 0, count: stopCount + 1)
        for stops in uniqueStops { for s in stops { stopStart[Int(s) + 1] += 1 } }
        for i in 0..<stopCount { stopStart[i + 1] += stopStart[i] }
        var stopFill = stopStart
        var stopList = [Int32](repeating: 0, count: Int(stopStart[stopCount]))
        for (i, stops) in uniqueStops.enumerated() {
            for s in stops { stopList[Int(stopFill[Int(s)])] = Int32(i); stopFill[Int(s)] += 1 }
        }
        uniqueStops = []
        // Stop pattern → trips
        var tripStart = [Int32](repeating: 0, count: pats.count + 1)
        for p in tPat { tripStart[Int(p) + 1] += 1 }
        for i in 0..<pats.count { tripStart[i + 1] += tripStart[i] }
        var tripFill = tripStart
        var tripList = [Int32](repeating: 0, count: tPat.count)
        for (i, p) in tPat.enumerated() { tripList[Int(tripFill[Int(p)])] = Int32(i); tripFill[Int(p)] += 1 }
        stopPatternStart = stopStart; stopPatternList = stopList
        patternTripStart = tripStart; patternTripList = tripList
    }

    static func string(_ r: inout ByteReader) throws -> String {
        try r.string16()
    }

    /// Bus map (one line per route, no stop dots, same as the MTA bus map)
    public func map() -> SubwayMap? {
        try? SubwayMap.decode(mapJSON)
    }

    // MARK: Nearby slice

    /// The destination shown at each kept stop of a pattern (FerryFeed.Trip.headsigns; nil or an empty one: the terminal's name):
    /// the data's headsign where it has one. A loop ends where it starts (the same stop, or one of the same name), so leaving its
    /// first stop the terminal would be that stop itself ("To JWO Transit Center" at JWO Transit Center): there it says the stop
    /// farthest from it in a straight line, where the bus turns back, unless the data's headsign names somewhere else. Its other
    /// stops keep the terminal, as on other trips.
    func headsignsAtStops(_ pattern: Pattern, keep: [Int]) -> [String]? {
        let named = pattern.headsign.isEmpty ? nil : [String](repeating: pattern.headsign, count: keep.count)
        guard keep.first == 0, pattern.stops.count >= 3, let first = pattern.stops.first, let last = pattern.stops.last,
              first == last || sameName(Int(first), Int(last)) else { return named }
        let origin = Int(first)
        guard pattern.headsign.isEmpty || pattern.headsign.caseInsensitiveCompare(stopNames[origin]) == .orderedSame,
              let far = farthestStop(of: pattern, from: origin),
              !sameName(far, origin) else { return named }
        var result = named ?? [String](repeating: "", count: keep.count)
        result[0] = stopNames[far]
        return result
    }

    private func sameName(_ a: Int, _ b: Int) -> Bool {
        stopNames[a].caseInsensitiveCompare(stopNames[b]) == .orderedSame
    }

    /// The stop of a pattern farthest from the given one in a straight line (the first of them on a tie); nil when every stop is
    /// where that one is
    private func farthestStop(of pattern: Pattern, from origin: Int) -> Int? {
        let start = Coordinate(latitude: stopLat[origin], longitude: stopLon[origin])
        var best: (stop: Int, meters: Double)?
        for raw in pattern.stops {
            let stop = Int(raw)
            let meters = WalkEstimator.distanceMeters(start, Coordinate(latitude: stopLat[stop], longitude: stopLon[stop]))
            if meters > (best?.meters ?? 0) { best = (stop, meters) }
        }
        return best?.stop
    }

    /// Stops within radiusMeters of center and the trips through them, made into a FerryFeed (nearby stations, arrival times and directions work like trains).
    /// Each trip keeps only its stops in this slice plus the terminal (the terminal is used for the direction, e.g. "To Newark Penn Station").
    /// Drop-off-only stops stay in the trip, so realtime data still lines up by stop, but are marked noBoarding like trains and ferries.
    /// For a company whose live data names stops by their codes (RegionalBusFeed.liveByStopCodes), each trip's whole list of stop
    /// codes comes along (StopCodeLists), when the stored file has the codes.
    public func slice(near center: Coordinate, radiusMeters: Double) -> FerryFeed {
        let source = FerryFeed.Source.njTransitBus
        let prefix = feed.idPrefix
        let routePrefix = feed.routePrefix
        // Rough filter by lat/lon first, then compute distance
        let dLat = radiusMeters / 111_000
        let dLon = radiusMeters / (111_000 * max(0.2, cos(center.latitude * .pi / 180)))
        var inside = Set<Int>()
        for i in stopIDs.indices
        where abs(stopLat[i] - center.latitude) <= dLat && abs(stopLon[i] - center.longitude) <= dLon {
            let d = WalkEstimator.distanceMeters(center, Coordinate(latitude: stopLat[i], longitude: stopLon[i]))
            if d <= radiusMeters { inside.insert(i) }
        }
        var pierIndexes = Set<Int>()
        var usedRoutes = Set<Int>()
        var usedServices = Set<Int>()
        var trips: [FerryFeed.Trip] = []
        // Only with a code for every stop (a file stored before they were kept has none)
        let withCodes = feed.liveByStopCodes && stopCodes.count == stopIDs.count
        var codeLists = StopCodeLists()
        let patternList = Set(inside.flatMap { stopPatterns($0) }).sorted()
        for p in patternList {
            let pattern = patterns[Int(p)]
            let last = pattern.stops.count - 1
            // Stops in this slice before the terminal (can't board at the terminal), plus the terminal;
            // skip the pattern when it can't be boarded at any of them (drop-off only), so those stops aren't offered as stations
            var keep = (0..<last).filter { inside.contains(Int(pattern.stops[$0])) }
            let noBoarding = keep.indices.filter { pattern.noBoarding.contains(UInt16(keep[$0])) }
            guard noBoarding.count < keep.count else { continue }
            keep.append(last)
            let stops = keep.map { prefix + stopIDs[Int(pattern.stops[$0])] }
            for k in keep { pierIndexes.insert(Int(pattern.stops[k])) }
            usedRoutes.insert(pattern.route)
            let route = routePrefix + routeNames[pattern.route]
            let headsigns = headsignsAtStops(pattern, keep: keep)
            if withCodes {
                codeLists.lists.append(pattern.stops.map { stopCodes[Int($0)] })
                codeLists.kept.append(keep)
            }
            for t in patternTrips(Int(p)) {
                let trip = Int(t)
                let base = Int(tripTimes[trip])
                usedServices.insert(Int(tripService[trip]))
                if withCodes { codeLists.listOfTrip[prefix + tripIDs[trip]] = codeLists.lists.count - 1 }
                trips.append(FerryFeed.Trip(
                    id: prefix + tripIDs[trip], route: route, service: prefix + serviceIDs[Int(tripService[trip])],
                    direction: pattern.direction == 1 ? "S" : "N", stops: stops,
                    times: keep.map { Int(time(base + $0)) }, noBoarding: noBoarding.isEmpty ? nil : noBoarding,
                    headsigns: headsigns))
            }
        }
        let piers = pierIndexes.sorted().map {
            FerryFeed.Pier(id: prefix + stopIDs[$0], name: stopNames[$0], lat: stopLat[$0], lon: stopLon[$0], timeZone: stopTimeZones[$0])
        }
        let routes = usedRoutes.sorted { routeNames[$0].localizedStandardCompare(routeNames[$1]) == .orderedAscending }.map {
            FerryFeed.Route(id: routePrefix + routeNames[$0], name: FerryFeed.routeName(routePrefix + routeNames[$0]),
                            color: feed.color(badge: routeNames[$0]), realtime: false)
        }
        var services: [String: FerryFeed.Service] = [:]
        for s in usedServices {
            let dates = serviceDates[s]
            services[prefix + serviceIDs[s]] = FerryFeed.Service(weekdays: 0, start: dates.first ?? 0, end: dates.last ?? 0,
                                                                 added: Set(dates), removed: [])
        }
        return FerryFeed(versions: [source.rawValue: version], routes: routes, piers: piers, trips: trips,
                         services: services, shapes: [:], zones: timeZone.map { [prefix: $0] },
                         wholeTimetables: feed.liveByStopsAndTime ? [prefix: wholeTimetable()] : nil,
                         stopCodeLists: withCodes && !codeLists.lists.isEmpty ? [prefix: codeLists] : nil)
    }

    /// Every trip with every stop, and their services, and the stops near each other: for a company whose live trips go by stops
    /// and time, kept with its nearby piece (see RegionalBusFeed.liveByStopsAndTime; only small companies, as it's the whole
    /// timetable)
    func wholeTimetable() -> WholeTimetable {
        let prefix = feed.idPrefix
        var trips: [FerryFeed.Trip] = []
        var services: [String: FerryFeed.Service] = [:]
        var served = Set<Int>()
        for pattern in patterns {
            for stop in pattern.stops { served.insert(Int(stop)) }
        }
        // Stops by latitude, each measured only against the next ones up to sameStopDistance farther north
        let distance = RegionalBusFeed.sameStopDistance
        let northward = stopIDs.indices.sorted { stopLat[$0] < stopLat[$1] }
        var nearbyStops: [String: [String]] = [:]
        for (n, i) in northward.enumerated() {
            for j in northward[(n + 1)...] {
                guard stopLat[j] - stopLat[i] <= distance / 111_000 else { break }
                let apart = WalkEstimator.distanceMeters(Coordinate(latitude: stopLat[i], longitude: stopLon[i]),
                                                         Coordinate(latitude: stopLat[j], longitude: stopLon[j]))
                guard apart <= distance else { continue }
                if served.contains(j) { nearbyStops[prefix + stopIDs[i], default: []].append(prefix + stopIDs[j]) }
                if served.contains(i) { nearbyStops[prefix + stopIDs[j], default: []].append(prefix + stopIDs[i]) }
            }
        }
        for t in tripIDs.indices {
            let pattern = patterns[Int(tripPattern[t])]
            let base = Int(tripTimes[t])
            let s = Int(tripService[t])
            let service = prefix + serviceIDs[s]
            trips.append(FerryFeed.Trip(
                id: prefix + tripIDs[t], route: feed.routePrefix + routeNames[pattern.route], service: service,
                direction: pattern.direction == 1 ? "S" : "N", stops: pattern.stops.map { prefix + stopIDs[Int($0)] },
                times: pattern.stops.indices.map { Int(time(base + $0)) }))
            if services[service] == nil {
                let dates = serviceDates[s]
                services[service] = FerryFeed.Service(weekdays: 0, start: dates.first ?? 0, end: dates.last ?? 0, added: Set(dates),
                                                      removed: [])
            }
        }
        return WholeTimetable(trips: trips, services: services, nearbyStops: nearbyStops.mapValues { $0.sorted() })
    }

    /// Whether it has the same trips as another copy (used when checking for updates: identical means "no change")
    /// The two data files have the same content (ignoring the generation time in bytes 8–11). No need to parse the whole old file.
    public static func sameContent(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, a.count >= 12 else { return false }
        return a.prefix(8) == b.prefix(8) && a.dropFirst(12) == b.dropFirst(12)
    }

    /// Whether there are trips in the next few days (including today): if not, the timetable has run out (the app checks once a day for a new one).
    /// All days with service (lets us tell whether the timetable is about to run out without keeping all the data in memory; see runs(onAnyOf:from:))
    public var allServiceDays: Set<Int> { Set(serviceDates.joined()) }

    /// Use allServiceDays to check whether there are trips in the next few days (same as runs(from:))
    public static func runs(onAnyOf serviceDays: Set<Int>, from date: Date, days: Int = 3) -> Bool {
        FerryFeed.days(from: date, count: days).contains(where: serviceDays.contains)
    }

    /// Whether an operator with these service days needs a new timetable: no trips in the next week, or its timetable ends within
    /// the next `FerryFeed.endingSoonDays` (no trips in the two weeks after them). The app then checks for a new one every day (see the
    /// app's FerryStore). A whole week, so an operator that runs only on some days of the week (PHLASH runs Friday to Sunday outside
    /// the summer) isn't taken for one whose timetable ran out early in the week.
    /// Only 45 days of trips are kept from the last download, which still reach past this while the monthly check works
    public static func runsOut(_ serviceDays: Set<Int>, from date: Date) -> Bool {
        let later = FerryFeed.daysAfter(date, skipping: FerryFeed.endingSoonDays)
        return !runs(onAnyOf: serviceDays, from: date, days: 7) || !later.contains(where: serviceDays.contains)
    }

    public func runs(from date: Date, days: Int = 3) -> Bool {
        let wanted = Set(FerryFeed.days(from: date, count: days))
        return serviceDates.contains { $0.contains(where: wanted.contains) }
    }
}
