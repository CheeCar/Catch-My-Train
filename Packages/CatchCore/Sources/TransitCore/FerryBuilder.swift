import Foundation

// MARK: - Building from GTFS

public enum FerryBuilder {
    /// Douglas-Peucker simplification tolerance, about 15 m
    static let tolerance = 0.00015

    /// Each row of a large file (used like TimetableBuilder.forEachRow). Train stop_times.txt files are large,
    /// so the app reads them while unzipping (ZipReader.forEachRow) instead of loading them whole into memory.
    public typealias RowSource = (_ body: @escaping (_ column: (String) -> String?) throws -> Void) throws -> Void

    /// Combines the downloaded GTFS from several operators into one. An operator with bad files is skipped, the others work as usual; throws if none are usable.
    /// - Parameters:
    ///   - files: each operator's GTFS files (file name → contents). Operators that failed to download are left out.
    ///   - stopTimes: stop_times.txt not in files is read from here (train ones are large and read while unzipping).
    ///   - now: trains keep only trips for 45 days from this day (see Source.keepDays).
    ///   - skipped: told of each operator skipped for its bad files, with what was wrong
    public static func build(_ files: [FerryFeed.Source: [String: Data]], stopTimes: [FerryFeed.Source: RowSource] = [:],
                             now: Date = Date(), skipped: (FerryFeed.Source, Error) -> Void = { _, _ in }) throws -> FerryFeed {
        var feed = FerryFeed(versions: [:], routes: [], piers: [], trips: [], services: [:], shapes: [:])
        var firstError: Error?
        for source in FerryFeed.Source.allCases {
            guard let f = files[source] else { continue }
            // Add to a copy first: if this operator fails partway, no half-built data is left behind
            var trial = feed
            do {
                try add(f, stopTimes: stopTimes[source], source: source, now: now, to: &trial)
                feed = trial
            } catch {
                firstError = firstError ?? error
                skipped(source, error)
            }
        }
        guard !feed.trips.isEmpty else { throw firstError ?? TimetableError.missingFile("stop_times.txt") }
        return feed
    }

    /// - Parameters:
    ///   - nyc: NYC Ferry GTFS files (file name → contents); nil when absent
    ///   - sif: Staten Island Ferry GTFS files; nil when absent
    ///   - nyw: NY Waterway GTFS files; nil when absent
    ///   - sst: Seastreak GTFS files; nil when absent
    ///   - sol: Statue of Liberty ferry (NPS) GTFS files; nil when absent
    public static func build(nyc: [String: Data]?, sif: [String: Data]?,
                             nyw: [String: Data]? = nil, sst: [String: Data]? = nil,
                             sol: [String: Data]? = nil) throws -> FerryFeed {
        var files: [FerryFeed.Source: [String: Data]] = [:]
        files[.nycFerry] = nyc
        files[.statenIsland] = sif
        files[.nyWaterway] = nyw
        files[.seastreak] = sst
        files[.statueOfLiberty] = sol
        return try build(files)
    }

    static func clean(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Pier names: NYC Ferry writes Governors Island as "Gov. Island/Yankee Pier"; spell it out so it's recognizable.
    /// LIRR's Midtown station is also called "Grand Central", but it's Grand Central Madison (270+ m from Metro-North's Grand Central),
    /// so spell it out to tell the two same-name stations apart.
    static func pierName(_ name: String, source: FerryFeed.Source = .nycFerry) -> String {
        if source == .lirr, name == "Grand Central" { return "Grand Central Madison" }
        if source.isNJTransit { return njTransitStationName(name) }
        if source.isAmtrak { return amtrakStationName(name, source: source) }
        // Hartford Line station names are all caps ("NEW HAVEN UNION STATION")
        if source == .hartfordLine { return njTransitStationName(name) }
        // MARC's station names are all caps and end in "MARC" ("PERRYVILLE MARC")
        if source == .marc {
            let base = name.hasSuffix(" MARC") ? String(name.dropLast(5)) : name
            return njTransitStationName(base)
        }
        if source == .septaRail { return septaStationName(name) }
        if source == .septaMetro { return septaMetroStationName(name) }
        if ModeCoverage.ferriesListedTogether.contains(source) { return bostonFerryPierName(name) }
        return name.replacingOccurrences(of: "Gov. Island", with: "Governors Island")
    }

    /// The boats around Greater Boston: the National Park Service adds its own code to each pier ("Long Wharf (LW)"); Patriot
    /// Party Boats names its Falmouth pier by its street address ("227 Clinton St., Falmouth, MA"), shown as the town; Freedom
    /// Cruise Line writes Nantucket's Straight Wharf "Straight Warf"
    static func bostonFerryPierName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\\s*\\([A-Z]{2,5}\\)$", with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "Straight Warf", with: "Straight Wharf")
        if name.range(of: "^[0-9]+ [^,]+, ", options: .regularExpression) != nil, let comma = name.firstIndex(of: ",") {
            name = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// SEPTA's stop names can carry notes for its own use: where the stop is at the corner ("Girard Av & 40th St - FS": far side;
    /// "- NS" near side; "- MBFS" and "- MBNS" mid-block), sometimes with a bay number ("- 2 NS", "- MBNS 2"), and bays numbered
    /// alone ("Whitman Plaza - 1"). Riders don't need them, and without them the stops of one corner or one plaza have the same name,
    /// so they show as one stop. Bus stops drop them too (see NJBusBuilder.stopName); no other operator's names have them
    static func withoutStopPositionNote(_ name: String) -> String {
        // In the middle, before more words: "Beaver St & Garden St - FS - Bristol Station", "Potter St & Jacksonville Rd - FS Charter Arms Apts"
        var text = name.replacingOccurrences(of: " - (FS|NS|MBFS|MBNS|MBN)( -)? ", with: " - ", options: .regularExpression)
        if let note = text.range(of: "\\s*-\\s*(\\d+\\s+)?(FS|NS|MBFS|MBNS|MBN)?(\\s+\\d+)?$", options: .regularExpression) {
            text = String(text[..<note.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A point the data lists among a line's stops that riders can't use, by its name: SEPTA Metro's "96 Signal - not a stop",
    /// "End of WB trip on EB plat - Not a stop" (where trains end, after the last station) and "Employee Platform - Employees Only".
    /// Left out of the trips, so it isn't shown as a station
    static func isNotForRiders(_ name: String) -> Bool {
        let text = name.lowercased()
        return text.contains("not a stop") || text.contains("employees only")
    }

    /// SEPTA Metro stop names: without the position note, nor the lines a platform is for ("Olney Transit Center - B2 & B3"), so a
    /// station's platforms have the same name and show as one station (see pierGroups)
    static func septaMetroStationName(_ raw: String) -> String {
        let name = withoutStopPositionNote(raw.trimmingCharacters(in: .whitespaces))
        guard let lines = name.range(of: " - [A-Z][0-9]( & [A-Z][0-9])*$", options: .regularExpression) else { return name }
        return String(name[..<lines.lowerBound])
    }

    /// NJ Transit station names are all caps ("NEWARK PENN STATION", "EXCHANGE PLACE LIGHT RAIL STATION"):
    /// convert to normal case, drop suffixes like "Light Rail Station" from light rail stops, and fix a few special names individually.
    static func njTransitStationName(_ raw: String) -> String {
        let special: [String: String] = [
            "30TH ST. PHL.": "Philadelphia 30th Street",
            "PENN STATION LIGHT RAIL DEPARTURE": "Newark Penn Station",
            "PENN STATION LIGHT RAIL ARRIVAL": "Newark Penn Station",
            "NEW YORK PENN STATION": "New York Penn Station",
            "NEWARK AIRPORT RAILROAD STATION": "Newark Airport",
            "SECAUCUS LOWER LEVEL": "Secaucus Junction",
            "SECAUCUS UPPER LEVEL": "Secaucus Junction",
            "FRANK R LAUTENBERG SECAUCUS LOWER LEVEL": "Secaucus Junction",
            "FRANK R LAUTENBERG SECAUCUS UPPER LEVEL": "Secaucus Junction",
            // A headsign of Lakeland's and Academy's buses
            "PABT": "Port Authority Bus Terminal",
        ]
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if let name = special[text] { return name }
        for suffix in [" LIGHT RAIL STATION", " LIGHT RAIL STA", " LIGHT RAIL DEPARTURE", " LIGHT RAIL ARRIVAL",
                       " LIGHT RAIL", " LT RAIL STA", " STATION LR"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        // RVCC: Raritan Valley Community College, a headsign of Somerset County's buses
        let upper: Set<String> = ["NJ", "NY", "PHL", "MSU", "US", "II", "III", "PNC", "NJPAC", "JFK", "AC", "RVCC"]
        func word(_ w: Substring) -> String {
            let plain = w.filter { $0.isLetter }
            if upper.contains(String(plain)) { return String(w) }
            // Ordinals: 30TH → 30th
            if let first = w.first, first.isNumber { return w.lowercased() }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }
        // Change words on both sides of spaces, hyphens and slashes; also words after a parenthesis
        var result = ""
        var current = ""
        for ch in text {
            if ch == " " || ch == "-" || ch == "/" || ch == "(" {
                result += word(Substring(current)) + String(ch)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result += word(Substring(current))
        return result.replacingOccurrences(of: " Ave.", with: " Ave").replacingOccurrences(of: "Mt. ", with: "Mount ")
    }

    /// Amtrak station names ("Stamford Amtrak Station", "Ny Moynihan Train Hall At Penn Station"): drop "Amtrak Station",
    /// and for a few stations shared with other operators, use the other operator's name so they land on the same card (among New York trains Penn Station matches LIRR,
    /// among New Jersey trains it matches NJ Transit).
    /// Amtrak stations named by their stop_id: ones with another station's name in its data
    static let amtrakStationNames = ["STS": "New Haven State Street", "BOS": "South Station", "BBY": "Back Bay", "BON": "North Station"]

    static func amtrakStationName(_ raw: String, source: FerryFeed.Source) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        if lower.contains("moynihan") || lower.contains("penn station") && lower.hasPrefix("ny") {
            return "Penn Station"
        }
        let special: [String: String] = [
            "Newark": "Newark Penn Station",
            "Newark Liberty International Airport": "Newark Airport",
            "Philadelphia": "Philadelphia 30th Street",
            // Newark, Delaware: without "Amtrak" it would read like New Jersey's Newark
            "Newark Amtrak": "Newark DE",
            // The MBTA's names for the stations it shares with Amtrak, so they're one station (see pierGroups)
            "Worcester Union Station": "Worcester",
            "Woburn Amtrak Station": "Anderson/Woburn",
        ]
        if let s = special[name] { return s }
        for suffix in [" Amtrak Station", " Amtrak"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// SEPTA Regional Rail station names: the stations it shares with Amtrak and NJ Transit take their names, so they land on the
    /// same card even a bit farther apart (see pierGroups); North Philadelphia's two platforms, about 150 m apart, become one station
    static func septaStationName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let special: [String: String] = [
            "gray 30th st station": "Philadelphia 30th Street",
            "30th street station": "Philadelphia 30th Street",
            "north philadelphia amtrak": "North Philadelphia",
            "north philadelphia septa": "North Philadelphia",
            "chester t.c.": "Chester Transportation Center",
        ]
        return special[name.lowercased()] ?? name
    }

    /// Every pier a ferry trip stops at must be within the app's service area, in a metro area areas.json lists for the operator:
    /// drop routes that go elsewhere, or the map would zoom way out and an area would show an operator its lists don't name (e.g.
    /// Seastreak's New Bedford–Martha's Vineyard boats, in Greater Boston, with New York's data). An operator areas.json doesn't
    /// list keeps every trip inside the service area. Upper Hudson NY Waterway routes (Haverstraw–Ossining, Newburgh–Beacon) are
    /// within the area (the app covers the whole metro area). inside: each pier's answer, worked out once
    static func staysInItsAreas(_ source: FerryFeed.Source, _ stops: [String], _ coordinates: [String: (lat: Double, lon: Double)],
                                inside: inout [String: Bool]) -> Bool {
        let areas = MetroArea.areas(of: source)
        return stops.allSatisfy { stop in
            guard let p = coordinates[stop] else { return true }
            if let known = inside[stop] { return known }
            let c = Coordinate(latitude: p.lat, longitude: p.lon)
            let answer = ServiceArea.contains(c) && (areas.isEmpty || MetroArea.of(c).map(areas.contains) == true)
            inside[stop] = answer
            return answer
        }
    }

    /// Midtown Manhattan: when the data has no direction, "getting closer to here" means heading to Manhattan.
    static let midtown = Coordinate(latitude: 40.754, longitude: -73.984)

    static func headsToManhattan(from a: (lat: Double, lon: Double)?, to b: (lat: Double, lon: Double)?) -> Bool {
        guard let a, let b else { return true }
        return WalkEstimator.distanceMeters(Coordinate(latitude: b.lat, longitude: b.lon), midtown)
            < WalkEstimator.distanceMeters(Coordinate(latitude: a.lat, longitude: a.lon), midtown)
    }

    static func add(_ files: [String: Data], stopTimes stopTimeRows: RowSource? = nil, source: FerryFeed.Source,
                    now: Date = Date(), to feed: inout FerryFeed) throws {
        for name in ["routes.txt", "trips.txt", "stops.txt"] where files[name] == nil {
            throw TimetableError.missingFile(name)
        }
        let readStopTimes: RowSource
        if let data = files["stop_times.txt"] {
            readStopTimes = { body in try TimetableBuilder.forEachRow(data, body) }
        } else if let stopTimeRows {
            readStopTimes = stopTimeRows
        } else {
            throw TimetableError.missingFile("stop_times.txt")
        }
        let prefix = source.rawValue
        let isSIF = source == .statenIsland

        // Calendar (read first: trains keep only trips running in the next few days)
        var services: [String: FerryFeed.Service] = [:]
        if let cal = files["calendar.txt"] {
            try TimetableBuilder.forEachRow(cal) { col in
                let id = clean(col("service_id"))
                guard !id.isEmpty else { return }
                var mask = 0
                for (i, day) in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].enumerated()
                where clean(col(day)) == "1" { mask |= 1 << i }
                services[id] = .init(weekdays: mask, start: Int(clean(col("start_date"))) ?? 0,
                                     end: Int(clean(col("end_date"))) ?? 0, added: [], removed: [])
            }
        }
        if let dates = files["calendar_dates.txt"] {
            try TimetableBuilder.forEachRow(dates) { col in
                let id = clean(col("service_id"))
                guard !id.isEmpty, let day = Int(clean(col("date"))) else { return }
                var s = services[id] ?? .init(weekdays: 0, start: 0, end: 0, added: [], removed: [])
                if clean(col("exception_type")) == "1" { s.added.insert(day) } else { s.removed.insert(day) }
                services[id] = s
            }
        }
        // Trains: keep only calendars running within keepDays from yesterday (trains still running past midnight), and only dates in those days.
        // The calendar's range shrinks to those days too: past them the removed dates are gone, so the weekly pattern would wrongly say it runs
        var keepServices: Set<String>?
        if let keepDays = source.keepDays {
            let dayList = FerryFeed.days(from: now.addingTimeInterval(-24 * 3600), count: keepDays + 1)
            if let first = dayList.first, let last = dayList.last {
                var kept: [String: FerryFeed.Service] = [:]
                for (id, s) in services where dayList.contains(where: { s.runs(on: $0) }) {
                    var t = s
                    t.start = max(s.start, first)
                    t.end = min(s.end, last)
                    t.added = s.added.filter { (first...last).contains($0) }
                    t.removed = s.removed.filter { (first...last).contains($0) }
                    kept[id] = t
                }
                services = kept
                keepServices = Set(kept.keys)
            }
        }

        // Routes (NYC Ferry's RES and RWS are shuttle buses, route_type 3, dropped; trains keep only route_type 2).
        // Ferry operators other than NYC Ferry are each merged into one route (e.g. NY Waterway's dozen-plus routes are all "NYW").
        var routeIDs: [String: String] = [:]   // raw route_id → "NYF-ER" / "SIF" / "NYW" / "LIRR-BAB"
        try TimetableBuilder.forEachRow(files["routes.txt"]!) { col in
            let raw = clean(col("route_id"))
            guard !raw.isEmpty, source.wants(routeType: clean(col("route_type"))),
                  source.wants(agency: clean(col("agency_id"))) else { return }
            var name = clean(col("route_long_name"))
            if name.isEmpty { name = clean(col("route_short_name")) }
            let agency = clean(col("agency_id"))
            let id = source.routeID(raw, name: name, agency: agency)
            routeIDs[raw] = id
            guard !feed.routes.contains(where: { $0.id == id }) else { return }
            if source.singleRouteID != nil || name.isEmpty { name = source.singleRouteID != nil ? source.name : raw }
            if source.isRail || source == .path { name = FerryFeed.routeName(id) }
            var color = clean(col("route_color")).uppercased()
            if let fixed = source.fixedColor { color = fixed }
            if source.isAmtrak, agency == FerryFeed.shoreLineEast.agency { color = FerryFeed.shoreLineEast.color }
            if color.count != 6 { color = source.defaultColor }
            feed.routes.append(.init(id: id, name: name, color: color, realtime: source.hasRealtime))
        }

        var coordinates: [String: (lat: Double, lon: Double)] = [:]   // raw stop_id → location
        var stopPiers: [FerryFeed.Pier] = []
        var notForRiders = Set<String>()   // raw stop_id of the points riders can't use (see isNotForRiders), left out of the trips
        // The operator's time zone (agency_timezone of the first agency kept; GTFS has every agency of a package in the same one):
        // its trips' days and times count in it. Without agency.txt (a copy downloaded before it was read) none is recorded, and its
        // metro area's is used (FerryFeed.timeZone(ofTrip:)). A stop's own (stop_timezone) is kept only where it differs
        var zone: String?
        if let agencies = files["agency.txt"] {
            try TimetableBuilder.forEachRow(agencies) { col in
                guard zone == nil, source.wants(agency: clean(col("agency_id"))) else { return }
                let named = clean(col("agency_timezone"))
                if TimeZone(identifier: named) != nil { zone = named }
            }
        }
        if let zone { feed.zones = (feed.zones ?? [:]).merging([prefix + ":": zone]) { _, new in new } }

        try TimetableBuilder.forEachRow(files["stops.txt"]!) { col in
            let raw = clean(col("stop_id"))
            guard !raw.isEmpty, let lat = Double(clean(col("stop_lat"))), let lon = Double(clean(col("stop_lon"))) else { return }
            // Drop station entrances, platforms and the like (location_type not 0); keep only the stops where riders board
            let type = clean(col("location_type"))
            guard type.isEmpty || type == "0" else { return }
            if isNotForRiders(clean(col("stop_name"))) {
                notForRiders.insert(raw)
                return
            }
            // Amtrak's New Haven has two stations; the State Street one is also called "New Haven". Its three Boston stations are all
            // called "Boston": by the names riders and the MBTA know them by
            let name = source.isAmtrak ? (amtrakStationNames[raw] ?? pierName(clean(col("stop_name")), source: source))
                : pierName(clean(col("stop_name")), source: source)
            let code = clean(col("stop_code"))
            coordinates[raw] = (lat, lon)
            let stopZone = clean(col("stop_timezone"))
            stopPiers.append(.init(id: prefix + ":" + raw, name: name.isEmpty ? raw : name,
                                   lat: SubwayMapBuilder.round5(lat), lon: SubwayMapBuilder.round5(lon),
                                   code: source.isRail && !code.isEmpty ? code : nil,
                                   timeZone: !stopZone.isEmpty && stopZone != zone && TimeZone(identifier: stopZone) != nil ? stopZone : nil))
        }

        struct RawTrip {
            var route: String; var service: String; var directionID: String; var shape: String; var number: String
            var headsign = ""
            /// Runs on the kept days (non-running ones are kept as stop patterns only for the keepsPatterns operator)
            var current = true
        }
        var rawTrips: [String: RawTrip] = [:]
        try TimetableBuilder.forEachRow(files["trips.txt"]!) { col in
            let id = clean(col("trip_id"))
            guard !id.isEmpty, let route = routeIDs[clean(col("route_id"))] else { return }
            let service = clean(col("service_id"))
            let current = keepServices?.contains(service) ?? true
            if !current && !source.keepsPatterns { return }
            // NJ Transit's public timetable has no trip_short_name: a train's number is its block_id. Only one that's all digits
            // ("PJBUS" and the like are the buses that stand in for trains)
            var number = clean(col("trip_short_name"))
            if number.isEmpty, source.liveByTrainNumber {
                let block = clean(col("block_id"))
                if FerryRealtime.trainNumber(block) != nil { number = block }
            }
            rawTrips[id] = RawTrip(route: route, service: service, directionID: clean(col("direction_id")),
                                   shape: clean(col("shape_id")), number: number,
                                   headsign: clean(col("trip_headsign")), current: current)
        }

        // A stop with both times blank is kept (time nil) and given a time between its neighbors below
        var stopTimes: [String: [(seq: Int, stop: String, time: Int?, noPickup: Bool)]] = [:]
        let wantedTrips = rawTrips
        let skippedStops = notForRiders
        try readStopTimes { col in
            let id = clean(col("trip_id"))
            guard wantedTrips[id] != nil, let seq = Int(clean(col("stop_sequence"))) else { return }
            let stop = clean(col("stop_id"))
            guard !skippedStops.contains(stop) else { return }
            let departure = clean(col("departure_time")), arrival = clean(col("arrival_time"))
            let t = TimetableBuilder.parseTime(departure) ?? TimetableBuilder.parseTime(arrival)
            guard t != nil || (departure.isEmpty && arrival.isEmpty) else { return }
            stopTimes[id, default: []].append((seq, stop, t.map { Int($0) }, clean(col("pickup_type")) == "1"))
        }

        var usedServices = Set<String>()
        var shapeCount: [String: [String: Int]] = [:]   // route → shape_id → trip count
        var tripShapes: [String: String] = [:]          // prefixed trip ID → shape_id
        var added: [FerryFeed.Trip] = []
        var patterns = Set<String>()   // kept as stop patterns (route|direction|stops)
        let pierNames = Dictionary(stopPiers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        func inArea(_ stop: String) -> Bool {
            coordinates[stop].map { source.keepsStop(lat: $0.lat, lon: $0.lon) } ?? false
        }
        var piersInItsAreas: [String: Bool] = [:]
        for id in stopTimes.keys.sorted() {
            guard let raw = rawTrips[id] else { continue }
            let ordered = TimetableBuilder.fillingBlankTimes(stopTimes[id]!.sorted { $0.seq < $1.seq }, time: { $0.time }) { row, t in
                var row = row
                row.time = t
                return row
            }
            var rows = ordered.compactMap { r in r.time.map { (seq: r.seq, stop: r.stop, time: $0, noPickup: r.noPickup) } }
            // Amtrak: keep only stations in the area, plus the next stop after (so the last stop in the area is boardable; the destination is still the terminal)
            var amtrakDirection: String?
            let fullTerminal = rows.last?.stop
            if source.clipsToServiceArea {
                let inside = rows.indices.filter { inArea(rows[$0].stop) }
                guard let hi = inside.last else { continue }
                var kept = inside.map { rows[$0] }
                if hi + 1 < rows.count { kept.append(rows[hi + 1]) }
                rows = kept
                // The data's direction_id is unreliable (some trains to New York are 0, some 1):
                // split directions by whether this segment heads northeast (north) or southwest (south)
                if let a = coordinates[rows.first?.stop ?? ""], let b = coordinates[rows.last?.stop ?? ""] {
                    amtrakDirection = (b.lat - a.lat) + (b.lon - a.lon) > 0 ? "N" : "S"
                }
            }
            guard rows.count >= 2, let first = rows.first, let last = rows.last else { continue }
            // Loops that start and end at the same pier: only the Statue of Liberty ferry keeps them (e.g. Battery Park → Liberty Island → Ellis Island → Battery Park),
            // the other operators' ones aren't for riders (e.g. Staten Island Ferry positioning trips at St. George)
            let isLoop = first.stop == last.stop
            if isLoop && !(source.keepsLoops && rows.count >= 3) { continue }
            // Ferries keep only trips within their metro areas; drop any with a pier elsewhere (trains keep whole lines)
            guard source.isRail || source == .path || source.clipsToServiceArea
                    || staysInItsAreas(source, rows.map(\.stop), coordinates, inside: &piersInItsAreas) else { continue }
            let direction: String
            if let amtrakDirection {
                direction = amtrakDirection
            } else if isSIF {
                direction = first.stop.lowercased().contains("whitehall") ? "N" : "S"
            } else if raw.directionID == "0" || raw.directionID == "1" {
                direction = raw.directionID == "1" ? "S" : "N"
            } else {
                // No direction in the data: toward Manhattan is "N", away from Manhattan is "S"
                direction = headsToManhattan(from: coordinates[first.stop], to: coordinates[last.stop]) ? "N" : "S"
            }
            var service = prefix + ":" + raw.service
            if raw.current {
                usedServices.insert(raw.service)
            } else {
                // Trips not running in these days (PATH's schedule expired): keep one per stop pattern, with a nonexistent calendar so it yields no trips
                guard patterns.insert(raw.route + "|" + direction + "|" + rows.map(\.stop).joined(separator: ",")).inserted
                else { continue }
                service = prefix + ":pattern"
            }
            // Drop-off-only piers (the last stop can't be boarded anyway, no need to record it)
            let noBoarding = rows.indices.dropLast().filter { rows[$0].noPickup }
            // When a loop leaves its origin, the destination is the next stop (the terminal is the origin itself; "To Battery Park" would be meaningless)
            var headsigns: [String]?
            if isLoop {
                headsigns = rows.map { _ in "" }
                headsigns?[0] = stopPiers.first { $0.id == prefix + ":" + rows[1].stop }?.name ?? ""
            }
            // SEPTA Metro and PATCO: the trip's headsign, where it differs from the last stop's name (see Source.usesHeadsigns)
            if source.usesHeadsigns, !isLoop, !raw.headsign.isEmpty, raw.headsign != pierNames[prefix + ":" + last.stop] {
                headsigns = rows.map { _ in raw.headsign }
            }
            // Amtrak: the destination is the whole trip's terminal (e.g. "To Washington"), not the last stop in the area
            if source.clipsToServiceArea {
                // When the data has no headsign (Hartford Line), use the whole trip's terminal (e.g. "To Springfield")
                // Hartford Line writes "Northbound to Hartford": keep only the terminal after it
                let terminal = !raw.headsign.isEmpty ? NJBusBuilder.headsign(raw.headsign, route: "")
                    : fullTerminal.flatMap { t in stopPiers.first { $0.id == prefix + ":" + t }?.name } ?? ""
                if !terminal.isEmpty { headsigns = rows.map { _ in terminal } }
            }
            let trip = FerryFeed.Trip(id: prefix + ":" + id, route: raw.route, service: service, direction: direction,
                                      stops: rows.map { prefix + ":" + $0.stop }, times: rows.map(\.time),
                                      noBoarding: noBoarding.isEmpty ? nil : Array(noBoarding), headsigns: headsigns,
                                      number: source.isRail && !raw.number.isEmpty ? raw.number : nil,
                                      sequences: source.liveStopsBySequence ? rows.map(\.seq) : nil)
            added.append(trip)
            if !raw.shape.isEmpty {
                shapeCount[raw.route, default: [:]][raw.shape, default: 0] += 1
                tripShapes[trip.id] = raw.shape
            }
        }
        feed.trips += added
        // Keep only piers with boats stopping (drop stops served only by shuttle buses and piers too far from New York)
        let usedPiers = Set(added.flatMap(\.stops))
        // Drop Amtrak stations outside the area (the next stop kept in trips is only there so the previous one is boardable)
        feed.piers += stopPiers.filter { usedPiers.contains($0.id) && (!source.clipsToServiceArea || inArea(String($0.id.dropFirst(prefix.count + 1)))) }

        for (id, s) in services where usedServices.contains(id) { feed.services[prefix + ":" + id] = s }

        // Map: draw each route's each pattern once (drawing both directions would overlap; the reverse of the same line isn't drawn again)
        var drawn = Set<String>()   // shape_ids drawn (including those skipped because the reverse was already drawn)
        if let shapesFile = files["shapes.txt"] {
            let wanted = Set(shapeCount.values.flatMap(\.keys))
            var points: [String: [(Int, Double, Double)]] = [:]
            try TimetableBuilder.forEachRow(shapesFile) { col in
                let shape = clean(col("shape_id"))
                guard wanted.contains(shape), let seq = Int(clean(col("shape_pt_sequence"))),
                      let lat = Double(clean(col("shape_pt_lat"))), let lon = Double(clean(col("shape_pt_lon"))) else { return }
                // Amtrak lines are very long: draw only the part within the area on the map
                guard source.keepsStop(lat: lat, lon: lon) else { return }
                points[shape, default: []].append((seq, lat, lon))
            }
            for (route, counts) in shapeCount {
                var seen: [[(Double, Double)]] = []
                for shape in counts.keys.sorted(by: { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }) {
                    guard let pts = points[shape], pts.count >= 2 else { continue }
                    drawn.insert(shape)
                    let line = pts.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
                    // The same line in the reverse direction (start and end swapped) isn't drawn again
                    if seen.contains(where: { s in
                        let a = s.first!, b = s.last!, c = line.first!, d = line.last!
                        return abs(a.0 - d.0) + abs(a.1 - d.1) < 0.002 && abs(b.0 - c.0) + abs(b.1 - c.1) < 0.002
                    }) { continue }
                    seen.append(line)
                    feed.shapes[route, default: []].append(
                        SubwayMapBuilder.simplify(line, tolerance: tolerance).map { [SubwayMapBuilder.round5($0.0), SubwayMapBuilder.round5($0.1)] })
                }
            }
        }
        // Trips without route shapes (no shapes.txt, or this trip has no shape): connect piers in order with straight lines.
        // Draw each stop pattern once, skip reverses; also skip if all its piers are on a shaped trip of the same route
        // (e.g. the Statue of Liberty ferry's evening return boat: Liberty Island → Battery Park is already on the loop).
        let shaped = added.filter { tripShapes[$0.id].map(drawn.contains) ?? false }
        var straight: [String: [[String]]] = [:]   // route → pier order
        for trip in added where !(tripShapes[trip.id].map(drawn.contains) ?? false) {
            let stops = Set(trip.stops)
            if shaped.contains(where: { $0.route == trip.route && stops.isSubset(of: $0.stops) }) { continue }
            let list = straight[trip.route, default: []]
            guard !list.contains(trip.stops), !list.contains(Array(trip.stops.reversed())) else { continue }
            straight[trip.route] = list + [trip.stops]
        }
        let pierByID = Dictionary(feed.piers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for route in straight.keys.sorted() {
            for stops in straight[route]!.prefix(30) {
                let line = stops.compactMap { pierByID[$0].map { [$0.lat, $0.lon] } }
                if line.count >= 2 { feed.shapes[route, default: []].append(line) }
            }
        }

        // Record a version for every operator (empty when there's no feed_info.txt) to mark it as processed (see FerryFeed.sources)
        var version = ""
        if let info = files["feed_info.txt"] {
            var first = true
            try TimetableBuilder.forEachRow(info) { col in
                if first { version = clean(col("feed_version")); if version.isEmpty { version = clean(col("feed_start_date")) }; first = false }
            }
        }
        feed.versions[source.rawValue] = version
    }
}
