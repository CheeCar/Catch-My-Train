import Foundation

// MARK: - Building from GTFS

public enum NJBusBuilder {

    /// - Parameters:
    ///   - files: small files (routes.txt, trips.txt, stops.txt, calendar_dates.txt; calendar.txt optional)
    ///   - stopTimes: stop_times.txt (very large, read while unzipping); when nil, read from files
    ///   - shapes: shapes.txt (125 MB, read while unzipping); when nil, read from files; if neither, the map connects the stops
    ///   - now: only keep trips for 45 days starting yesterday
    public static func build(files: [String: Data], stopTimes: FerryBuilder.RowSource? = nil,
                             shapes: FerryBuilder.RowSource? = nil, now: Date = Date(),
                             feed: RegionalBusFeed = .njTransit) throws -> Data {
        for name in ["routes.txt", "trips.txt", "stops.txt"] where files[name] == nil {
            throw TimetableError.missingFile(name)
        }
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces) }
        func rows(_ name: String, _ source: FerryBuilder.RowSource?,
                  _ body: @escaping (_ column: (String) -> String?) throws -> Void) throws {
            if let data = files[name] {
                try TimetableBuilder.forEachRow(data, body)
            } else if let source {
                try source(body)
            } else {
                throw TimetableError.missingFile(name)
            }
        }

        // 1. Calendar: only keep dates with service in the 45 days starting yesterday
        let dayList = FerryFeed.days(from: now.addingTimeInterval(-24 * 3600), count: NJBusIndex.keepDays + 1)
        var calendar: [String: FerryFeed.Service] = [:]
        if let data = files["calendar.txt"] {
            try TimetableBuilder.forEachRow(data) { col in
                let id = clean(col("service_id"))
                guard !id.isEmpty else { return }
                var mask = 0
                for (i, day) in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].enumerated()
                where clean(col(day)) == "1" { mask |= 1 << i }
                calendar[id] = .init(weekdays: mask, start: Int(clean(col("start_date"))) ?? 0,
                                     end: Int(clean(col("end_date"))) ?? 0, added: [], removed: [])
            }
        }
        if let data = files["calendar_dates.txt"] {
            try TimetableBuilder.forEachRow(data) { col in
                let id = clean(col("service_id"))
                guard !id.isEmpty, let day = Int(clean(col("date"))) else { return }
                var s = calendar[id] ?? .init(weekdays: 0, start: 0, end: 0, added: [], removed: [])
                if clean(col("exception_type")) == "1" { s.added.insert(day) } else { s.removed.insert(day) }
                calendar[id] = s
            }
        }
        var serviceIDs: [String] = []
        var serviceDates: [[Int]] = []
        var serviceIndex: [String: Int] = [:]
        var firstDay = Int.max
        for id in calendar.keys.sorted() {
            let s = calendar[id]!
            let all = Array(s.added) + (s.start > 0 ? [s.start] : [])
            firstDay = min(firstDay, all.min() ?? Int.max)
            let dates = dayList.filter { s.runs(on: $0) }
            guard !dates.isEmpty else { continue }
            serviceIndex[id] = serviceIDs.count
            serviceIDs.append(id)
            serviceDates.append(dates)
        }
        guard serviceIDs.count < Int(UInt16.max) else { throw TimetableError.badFormat }

        // The company's time zone (agency_timezone of the first agency with a usable one; GTFS has every agency of a package in the
        // same one): its trips' days and times count in it. Stops with their own (stop_timezone) keep it where it differs.
        // And the package's companies, for one that is one of several in its package (RegionalBusFeed.agency)
        var zone: String?
        var agencies: [(id: String, name: String)] = []
        if let data = files["agency.txt"] {
            try TimetableBuilder.forEachRow(data) { col in
                let named = clean(col("agency_timezone"))
                if zone == nil, TimeZone(identifier: named) != nil { zone = named }
                agencies.append((id: clean(col("agency_id")), name: clean(col("agency_name"))))
            }
        }
        // Its own routes: those of its agency_id, or when no company of the package has that id, of the one with its name. A route
        // without an agency_id is the package's only company's
        let ownAgency = feed.agency.map { wanted in
            agencies.contains { $0.id == wanted.id } ? wanted.id
                : agencies.first { $0.name.caseInsensitiveCompare(wanted.name) == .orderedSame }?.id ?? wanted.id
        }
        let onlyAgency = agencies.count == 1 ? agencies[0].id : ""

        // 2. Routes (by short name, e.g. "107"; without one, from the long name, else the route_id)
        var routeShort: [String: String] = [:]
        var routeLong: [String: String] = [:]
        var routeDirection: [String: UInt8] = [:]
        // Routes whose badge was given by name (badgesByLongName): a word, so a headsign starting with it keeps it ("Patriot Square")
        var namedRoutes = Set<String>()
        try TimetableBuilder.forEachRow(files["routes.txt"]!) { col in
            let id = clean(col("route_id"))
            guard !id.isEmpty else { return }
            let type = clean(col("route_type"))
            // Buses are 3 (700–716 in the extended types), trolleybuses 11 (800: SEPTA's trackless trolleys). The rest of a package
            // isn't a bus (SEPTA's Metro lines are in its bus package, and read with light rail: see FerryFeed.Source.septaMetro; the
            // MBTA's subway, trains and ferries are in its, each read with its own mode)
            guard type.isEmpty || type == "3" || type == "11"
                    || (Int(type).map { (700...716).contains($0) || $0 == 800 } ?? false) else { return }
            // One company of a shared package: only its own routes
            if let ownAgency {
                let agency = clean(col("agency_id"))
                guard (agency.isEmpty ? onlyAgency : agency) == ownAgency else { return }
            }
            // Short names that are the company's name aren't the routes' (see shortNamesNameCompany)
            let raw = feed.shortNamesNameCompany ? "" : clean(col("route_short_name"))
            func withoutPrefix(_ name: String) -> String {
                feed.routeNamePrefix.map { name.hasPrefix($0) && name.count > $0.count ? String(name.dropFirst($0.count)) : name } ?? name
            }
            let short = withoutPrefix(routeShortName(raw))
            let long = clean(col("route_long_name"))
            let badge = withoutPrefix(long)
            let label = feed.routesByFirstPlace ? firstPlace(longName: badge) : routeLabel(longName: badge)
            // By its long name, or with none by its short name (NECTD's "Red-Purple Shuttle"); without a short name, also by how
            // its long name starts (WRTD's "Purple A Fall 2026")
            let named = feed.badgesByLongName[long.isEmpty ? raw : long] ?? (raw.isEmpty ? feed.badge(longNameStart: long) : nil)
            let route = feed.badgesByDescription[clean(col("route_desc"))] ?? named ?? (!short.isEmpty ? short : label ?? id)
            // A route another company's data has too, kept there (PVTA's 904, see leftOutRoutes)
            guard !feed.leftOutRoutes.contains(route) else { return }
            if named != nil { namedRoutes.insert(id) }
            routeShort[id] = route
            routeLong[id] = long
            if let direction = direction(ofRoute: raw) { routeDirection[id] = direction }
        }
        var routeNames: [String] = []
        var routeIndex: [String: Int] = [:]
        // Regardless of case: Ulster's data has "BLUE" next to an older "Blue" (the badge keeps the first one's spelling)
        func routeNumber(_ short: String) -> Int {
            let key = short.uppercased()
            if let i = routeIndex[key] { return i }
            routeIndex[key] = routeNames.count
            routeNames.append(short)
            return routeNames.count - 1
        }

        // 3. Stops
        var stopIDs: [String] = [], stopNames: [String] = [], stopLat: [Double] = [], stopLon: [Double] = []
        var stopCodes: [String] = []
        var stopIndex: [String: Int] = [:]
        var stopZones: [Int: String] = [:]
        try TimetableBuilder.forEachRow(files["stops.txt"]!) { col in
            let id = clean(col("stop_id"))
            guard !id.isEmpty, stopIndex[id] == nil, let lat = Double(clean(col("stop_lat"))),
                  let lon = Double(clean(col("stop_lon"))) else { return }
            // A misprinted position ("nan", "1e12", a missing decimal point) would break the file below: skip that stop
            guard Coordinate.isUsable(latitude: lat, longitude: lon) else { return }
            // Only boarding points under a platform are stops (location_type empty or 0); for Connecticut's CTtransit, only keep those in the service area
            let type = clean(col("location_type"))
            guard type.isEmpty || type == "0" else { return }
            if feed.onlyServiceArea, !ServiceArea.contains(Coordinate(latitude: lat, longitude: lon)) { return }
            let stopZone = clean(col("stop_timezone"))
            if !stopZone.isEmpty, stopZone != zone, TimeZone(identifier: stopZone) != nil { stopZones[stopIDs.count] = stopZone }
            stopIndex[id] = stopIDs.count
            stopIDs.append(id)
            stopNames.append(stopName(clean(col("stop_name"))))
            stopCodes.append(clean(col("stop_code")))
            stopLat.append(lat)
            stopLon.append(lon)
        }
        guard stopIDs.count < Int(UInt16.max) else { throw TimetableError.badFormat }

        // 4. Trips (only those running in the 45 days). The direction is the one in the route's name if it has one, else direction_id
        //    (unless the company's can't be used, see directionsFromStops); without either it's worked out in step 6 from where the
        //    trip goes
        struct TripInfo {
            var route: Int; var rawRoute: String; var direction: UInt8?; var headsign: String; var service: Int; var shape: String
            /// block_id, read only for a company whose live data names trips by block (see RegionalBusFeed.tripsByBlock)
            var block: String
        }
        var tripInfo: [String: Int] = [:]
        var infos: [TripInfo] = []
        var tripIDs: [String] = []
        try TimetableBuilder.forEachRow(files["trips.txt"]!) { col in
            let id = clean(col("trip_id"))
            let rawRoute = clean(col("route_id"))
            guard !id.isEmpty, tripInfo[id] == nil, let short = routeShort[rawRoute],
                  let service = serviceIndex[clean(col("service_id"))] else { return }
            tripInfo[id] = infos.count
            tripIDs.append(id)
            let directionID = feed.directionsFromStops ? "" : clean(col("direction_id"))
            infos.append(TripInfo(route: routeNumber(short), rawRoute: rawRoute,
                                  direction: routeDirection[rawRoute] ?? (directionID == "1" ? 1 : directionID == "0" ? 0 : nil),
                                  headsign: feed.headsignsNameRoutes ? ""
                                      : headsign(clean(col("trip_headsign")), route: namedRoutes.contains(rawRoute) ? "" : short,
                                                 longName: routeLong[rawRoute] ?? ""),
                                  service: service, shape: clean(col("shape_id")),
                                  block: feed.tripsByBlock ? clean(col("block_id")) : ""))
        }

        // 5. Stop times: each row packed as (stop sequence << 48 | stop << 32 | time), plus noPickup where riders can't board
        //    (pickup_type = 1; times stay below 2^20 because parseTime caps the hours, so bit 31 is free).
        //    A stop with both times blank gets blankTime (all 31 time bits) and a time between its neighbors in step 6
        let noPickup: UInt64 = 1 << 31
        let blankTime: UInt64 = (1 << 31) - 1
        var tripRows = [[UInt64]](repeating: [], count: infos.count)
        try rows("stop_times.txt", stopTimes) { col in
            guard let t = col("trip_id").flatMap({ tripInfo[$0.trimmingCharacters(in: .whitespaces)] }),
                  let s = col("stop_id").flatMap({ stopIndex[$0.trimmingCharacters(in: .whitespaces)] }),
                  let seq = col("stop_sequence").flatMap({ UInt64($0.trimmingCharacters(in: .whitespaces)) }) else { return }
            let departure = col("departure_time")?.trimmingCharacters(in: .whitespaces) ?? ""
            let arrival = col("arrival_time")?.trimmingCharacters(in: .whitespaces) ?? ""
            let time: UInt64
            if let parsed = TimetableBuilder.parseTime(departure) ?? TimetableBuilder.parseTime(arrival) {
                time = UInt64(parsed)
            } else if departure.isEmpty, arrival.isEmpty {
                time = blankTime
            } else {
                return
            }
            let pickup = col("pickup_type")?.trimmingCharacters(in: .whitespaces) == "1" ? noPickup : 0
            tripRows[t].append(min(seq, 0xFFFF) << 48 | UInt64(s) << 32 | time | pickup)
        }

        // 6. Trips with the same stop pattern (and direction, headsign and drop-off-only stops) share one copy.
        //    A group is the same key without the drop-off-only stops: the map counts trips per group, so those stops don't change the shape drawn
        struct Variant: Hashable { var group: Int; var noBoarding: [UInt16] }
        var patterns: [NJBusIndex.Pattern] = []
        var patternIndex: [Variant: Int] = [:]
        var groupIndex: [String: Int] = [:]
        // rawRoute: the data's route_id of the group's first trip (routes merged by name keep apart on the map, see step 7)
        var groups: [(pattern: Int, trips: Int, shapes: [String: Int], rawRoute: String)] = []
        var tripPattern: [UInt32] = [], tripService: [UInt16] = [], tripTimes: [UInt32] = [], keptIDs: [String] = []
        var times: [UInt32] = []
        // A trip's ID: for a company whose live data names trips by block and first departure, those two and its service (see
        // BlockTripID); otherwise, or when its block isn't a number or an earlier trip already has that ID, the data's trip_id
        var byBlock = Set<String>()
        func keptID(_ t: Int, firstDeparture: Int) -> String {
            guard feed.tripsByBlock,
                  let id = BlockTripID.stored(block: infos[t].block, firstDeparture: firstDeparture,
                                              service: serviceIDs[infos[t].service]),
                  byBlock.insert(id).inserted else { return tripIDs[t] }
            return id
        }
        for (t, raw) in tripRows.enumerated() where raw.count >= 2 {
            let sorted = TimetableBuilder.fillingBlankTimes(raw.sorted(), time: { $0 & blankTime == blankTime ? nil : Int($0 & blankTime) }) {
                $0 & ~blankTime | UInt64($1)
            }
            guard sorted.count >= 2 else { continue }
            let stops = sorted.map { UInt16(truncatingIfNeeded: $0 >> 32) }
            // Drop-off-only positions (the terminal can't be boarded anyway, no need to record it)
            let noBoarding = sorted.indices.dropLast().compactMap { sorted[$0] & noPickup != 0 ? UInt16(exactly: $0) : nil }
            let info = infos[t]
            // No direction in the data (Sullivan's, Long Beach's): toward Manhattan is 0, away from it 1, as for ferries without one;
            // a loop, ending where it starts, stays 0
            let direction = info.direction ?? { () -> UInt8 in
                let (a, b) = (Int(stops[0]), Int(stops[stops.count - 1]))
                guard a != b else { return 0 }
                return FerryBuilder.headsToManhattan(from: (lat: stopLat[a], lon: stopLon[a]),
                                                     to: (lat: stopLat[b], lon: stopLon[b])) ? 0 : 1
            }()
            let key = "\(info.route)|\(direction)|\(info.headsign)|" + stops.map(String.init).joined(separator: ",")
            let g = groupIndex[key] ?? groups.count
            let variant = Variant(group: g, noBoarding: noBoarding)
            let p: Int
            if let found = patternIndex[variant] {
                p = found
            } else {
                p = patterns.count
                patternIndex[variant] = p
                patterns.append(.init(route: info.route, direction: direction, headsign: info.headsign, stops: stops,
                                      noBoarding: noBoarding))
            }
            if g == groups.count {
                groupIndex[key] = g
                groups.append((pattern: p, trips: 0, shapes: [:], rawRoute: info.rawRoute))
            }
            groups[g].trips += 1
            if !info.shape.isEmpty { groups[g].shapes[info.shape, default: 0] += 1 }
            keptIDs.append(keptID(t, firstDeparture: Int(sorted[0] & blankTime)))
            tripPattern.append(UInt32(p))
            tripService.append(UInt16(info.service))
            tripTimes.append(UInt32(times.count))
            times += sorted.map { UInt32(truncatingIfNeeded: $0 & ~noPickup) }
        }
        tripRows = []
        guard !keptIDs.isEmpty else { throw TimetableError.missingFile("stop_times.txt") }

        // One company of a shared package keeps only the stops and services its trips have: the others' (across the country in
        // Coach USA's) would make its file and its bounds the whole package's, and its days of service theirs too (so a timetable
        // of its own that ran out wouldn't be seen, see NJBusIndex.runsOut). Its version is its own services' first day
        if feed.agency != nil {
            let usedServices = Set(tripService).sorted()
            var newService: [UInt16: UInt16] = [:]
            for (n, old) in usedServices.enumerated() { newService[old] = UInt16(n) }
            tripService = tripService.map { newService[$0]! }
            firstDay = usedServices.compactMap { old -> Int? in
                guard let service = calendar[serviceIDs[Int(old)]] else { return nil }
                return (Array(service.added) + (service.start > 0 ? [service.start] : [])).min()
            }.min() ?? Int.max
            serviceIDs = usedServices.map { serviceIDs[Int($0)] }
            serviceDates = usedServices.map { serviceDates[Int($0)] }
            let used = Set(patterns.flatMap { $0.stops }).sorted()
            var newIndex: [UInt16: UInt16] = [:]
            for (n, old) in used.enumerated() { newIndex[old] = UInt16(n) }
            for p in patterns.indices { patterns[p].stops = patterns[p].stops.map { newIndex[$0]! } }
            let old = used.map(Int.init)
            stopIDs = old.map { stopIDs[$0] }
            stopNames = old.map { stopNames[$0] }
            stopCodes = old.map { stopCodes[$0] }
            stopLat = old.map { stopLat[$0] }
            stopLon = old.map { stopLon[$0] }
            stopZones = Dictionary(uniqueKeysWithValues: stopZones.compactMap { stop, named in
                newIndex[UInt16(stop)].map { (Int($0), named) }
            })
        }

        // 7. Map: for each route and direction (0 first), the stop pattern with the most trips, using its most common shape; without shape data, connect the stops.
        //    A route merged by name from routes that run in different places (Sullivan's "S" is both the Liberty and the Monticello shuttle)
        //    also gets a line for each of those whose best pattern shares no stop with the lines already drawn
        func better(_ g: Int, than b: Int) -> Bool {
            let (new, old) = (patterns[groups[g].pattern], patterns[groups[b].pattern])
            return (new.direction, -groups[g].trips, -new.stops.count) < (old.direction, -groups[b].trips, -old.stops.count)
        }
        var best: [Int: Int] = [:]   // route → group
        var bestOfRaw: [String: Int] = [:]   // the data's route_id → group
        for g in groups.indices {
            let route = patterns[groups[g].pattern].route
            if best[route].map({ better(g, than: $0) }) ?? true { best[route] = g }
            if bestOfRaw[groups[g].rawRoute].map({ better(g, than: $0) }) ?? true { bestOfRaw[groups[g].rawRoute] = g }
        }
        var drawn: [Int: [Int]] = best.mapValues { [$0] }   // route → groups drawn, one line each
        for raw in bestOfRaw.keys.sorted() {
            let g = bestOfRaw[raw]!
            let route = patterns[groups[g].pattern].route
            guard let lines = drawn[route], !lines.contains(g) else { continue }
            let used = Set(lines.flatMap { patterns[groups[$0].pattern].stops })
            if Set(patterns[groups[g].pattern].stops).isDisjoint(with: used) { drawn[route] = lines + [g] }
        }
        var wantedShapes: [Int: String] = [:]   // group → shape
        for g in drawn.values.joined() {
            if let shape = BusMapBuilder.mostCommon(groups[g].shapes) { wantedShapes[g] = shape }
        }
        let shapeSet = Set(wantedShapes.values)
        var shapePoints: [String: [(Int, Double, Double)]] = [:]
        if !shapeSet.isEmpty, files["shapes.txt"] != nil || shapes != nil {
            try rows("shapes.txt", shapes) { col in
                guard let id = col("shape_id")?.trimmingCharacters(in: .whitespaces), shapeSet.contains(id),
                      let seq = col("shape_pt_sequence").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                      let lat = col("shape_pt_lat").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                      let lon = col("shape_pt_lon").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { return }
                shapePoints[id, default: []].append((seq, lat, lon))
            }
        }
        var mapRoutes: [SubwayMap.Route] = []
        for route in drawn.keys.sorted(by: { routeNames[$0].localizedStandardCompare(routeNames[$1]) == .orderedAscending }) {
            var lines: [[[Double]]] = []
            for g in drawn[route]! {
                var points: [(Double, Double)]
                if let shape = wantedShapes[g], let raw = shapePoints[shape], raw.count >= 2 {
                    points = raw.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
                } else {
                    points = patterns[groups[g].pattern].stops.map { (stopLat[Int($0)], stopLon[Int($0)]) }
                }
                let line = SubwayMapBuilder.simplify(points, tolerance: BusMapBuilder.tolerance)
                    .map { [SubwayMapBuilder.round5($0.0), SubwayMapBuilder.round5($0.1)] }
                if line.count >= 2 { lines.append(line) }
            }
            guard !lines.isEmpty else { continue }
            mapRoutes.append(SubwayMap.Route(route: feed.routePrefix + routeNames[route], color: feed.color(badge: routeNames[route]),
                                             lines: lines))
        }
        let version = firstDay == Int.max ? "" : String(firstDay)
        let map = SubwayMap(source: feed.name + " bus GTFS", feedVersion: version, stations: [], routes: mapRoutes)
        let mapJSON = try map.encoded()

        // 8. Write the file
        guard routeNames.count < Int(UInt16.max), patterns.count < Int(UInt32.max) else { throw TimetableError.badFormat }
        var w = ByteWriter()
        func str(_ s: String) {
            let b = Array(s.utf8.prefix(Int(UInt16.max)))
            w.u16(UInt16(b.count))
            w.bytes(b)
        }
        w.bytes(NJBusIndex.magic)
        w.u32(NJBusIndex.formatVersion)
        w.u32(UInt32(max(0, now.timeIntervalSince1970)))
        str(version)
        w.u32(UInt32(stopIDs.count))
        for i in stopIDs.indices {
            str(stopIDs[i])
            str(stopNames[i])
            // Never traps, even on a value that got past the check above
            w.u32(UInt32(bitPattern: Int32(exactly: (stopLat[i] * 1_000_000).rounded()) ?? 0))
            w.u32(UInt32(bitPattern: Int32(exactly: (stopLon[i] * 1_000_000).rounded()) ?? 0))
        }
        w.u32(UInt32(routeNames.count))
        for r in routeNames { str(r) }
        w.u32(UInt32(serviceIDs.count))
        for (i, id) in serviceIDs.enumerated() {
            str(id)
            w.u16(UInt16(min(serviceDates[i].count, Int(UInt16.max))))
            for d in serviceDates[i].prefix(Int(UInt16.max)) { w.u32(UInt32(d)) }
        }
        w.u32(UInt32(patterns.count))
        for p in patterns {
            w.u16(UInt16(p.route))
            w.u8(p.direction)
            str(p.headsign)
            let stopCount = min(p.stops.count, Int(UInt16.max))
            w.u16(UInt16(stopCount))
            for s in p.stops.prefix(stopCount) { w.u16(s) }
            let noBoarding = p.noBoarding.filter { Int($0) < stopCount - 1 }
            w.u16(UInt16(noBoarding.count))
            for i in noBoarding { w.u16(i) }
        }
        w.u32(UInt32(keptIDs.count))
        for i in keptIDs.indices {
            str(keptIDs[i])
            w.u32(tripPattern[i])
            w.u16(tripService[i])
            w.u32(tripTimes[i])
        }
        w.u32(UInt32(times.count))
        var block = [UInt8]()
        block.reserveCapacity(times.count * 4)
        for t in times {
            block.append(UInt8(t & 0xFF)); block.append(UInt8((t >> 8) & 0xFF))
            block.append(UInt8((t >> 16) & 0xFF)); block.append(UInt8(t >> 24))
        }
        w.bytes(block)
        w.u32(UInt32(mapJSON.count))
        w.bytes(Array(mapJSON))
        // Format 3: the company's time zone ("" when the data has none) and the stops with their own
        str(zone ?? "")
        w.u32(UInt32(stopZones.count))
        for (i, named) in stopZones.sorted(by: { $0.key < $1.key }) {
            w.u32(UInt32(i))
            str(named)
        }
        // Format 4: every stop's code ("" for one without)
        w.u32(UInt32(stopCodes.count))
        for code in stopCodes { str(code) }
        return w.data
    }

    /// Route short name: remove extra spaces; Dutchess data splits routes by day ("A  MS", "A SUN"), merged into one "A";
    /// Ulster's splits them by direction ("KS-NB", "KS-SB"), merged into one "KS" (the direction is kept, see direction(ofRoute:)),
    /// and writes the word "Route" into some ("CL Route" next to the older "CL-NB"), which isn't part of the name on the badge
    static func routeShortName(_ raw: String) -> String {
        var words = htmlDecoded(raw).split(separator: " ").map(String.init)
        // Dutchess variants: "A  MS" (Monday to Saturday), "A SUN", "M MF", "G MS1"; route L also has "L SMS", "L AMS", "L SN"
        let dayWords: Set<String> = ["MS", "MS1", "MF", "M-F", "SUN", "SN", "SAT", "SA", "SU", "SMS", "AMS",
                                     "WKD", "WKDY", "WEEKDAY", "WEEKEND"]
        if words.count > 1, let last = words.last, dayWords.contains(last.uppercased()) { words.removeLast() }
        if words.count > 1, words.last?.uppercased() == "ROUTE" {
            words.removeLast()
        } else if words.count > 1, words.first?.uppercased() == "ROUTE" {
            words.removeFirst()
        }
        let name = words.joined(separator: " ")
        return direction(ofRoute: name) != nil ? String(name.dropLast(3)) : name
    }

    /// The direction written into a route's name, for data that splits each line into one route per direction ("KS-NB" and "KS-SB",
    /// Ulster): 0 for north or east, 1 for south or west. Such data's direction_id can't tell the two apart (Ulster's is 1 on both)
    static func direction(ofRoute raw: String) -> UInt8? {
        let name = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard name.count > 3 else { return nil }
        switch name.suffix(3) {
        case "-NB", "-EB": return 0
        case "-SB", "-WB": return 1
        default: return nil
        }
    }

    /// Badge text for a route with no short name, from its long name: the route numbers it starts with
    /// ("581-582 Saybrook Rd/Wesleyan Hills" → "581-582", River Valley), or else the whole name ("Clinton Trolley"); nil when that's empty too
    static func routeLabel(longName raw: String) -> String? {
        let name = routeShortName(raw)
        guard !name.isEmpty else { return nil }
        if let first = name.split(separator: " ").first, first.count < name.count, first.first?.isNumber == true,
           first.allSatisfy({ $0.isNumber || $0 == "-" }) {
            return String(first)
        }
        // A number and one letter ("2S Hanover St/East Side Plaza SAT", Manchester's Saturday route 2)
        if let first = name.split(separator: " ").first, first.count < name.count, (2...4).contains(first.count),
           first.dropLast().allSatisfy(\.isNumber), first.last?.isLetter == true {
            return String(first)
        }
        // A route code of a letter or two and a number ("B1 Beverly to Pemberton", BurLINK's after its prefix)
        if let first = name.split(separator: " ").first, first.count < name.count, first.count <= 4,
           first.first?.isLetter == true, first.last?.isNumber == true, first.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return String(first)
        }
        return name
    }

    /// The first place in a route's long name, for data whose routes are "first place-last place" and a direction (Trans-Bridge's
    /// "Allentown-Clinton Eastbound" → "Allentown", "Wall St Westbound" → "Wall St"); nil when that's empty
    static func firstPlace(longName raw: String) -> String? {
        var words = htmlDecoded(raw).split(separator: " ").map(String.init)
        let directionWords: Set<String> = ["NORTHBOUND", "SOUTHBOUND", "EASTBOUND", "WESTBOUND", "INBOUND", "OUTBOUND"]
        if words.count > 1, let last = words.last, directionWords.contains(last.uppercased()) { words.removeLast() }
        let name = words.joined(separator: " ")
        let first = name.split(separator: "-", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? nil : first
    }

    /// HTML entities (some 511NY operators' data contains "&amp;"), in any case: Trans-Bridge's data, title-cased after the
    /// entities were written, has "&Amp;" and "&Apos;"
    static func htmlDecoded(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
    }

    /// Stop name: "MAIN ST AT ADAMS AVE" → "Main St at Adams Ave". Names that already have mixed case (e.g. NICE data) are left alone.
    /// Notes for the operator's own use are dropped: the state and country at the end of some of River Valley's names
    /// ("415 Killingworth Rd, Haddam, CT, USA"), SEAT's mark on the stops the state looks after ("Salem Plaza (CTDOT)"), and SEPTA's
    /// notes on where a stop is at the corner and its bay numbers ("Girard Av & 40th St - FS", see FerryBuilder.withoutStopPositionNote).
    static func stopName(_ raw: String) -> String {
        var text = htmlDecoded(raw).replacingOccurrences(of: " (CTDOT)", with: "")
        // Title-casing done after the entities were written (Trans-Bridge's): "Peddler'S Village" → "Peddler's Village", and a
        // state's code run into the next word ("Wescosville, PAPark & Ride" → "Wescosville, PA Park & Ride")
        text = text.replacingOccurrences(of: "([a-z])'S\\b", with: "$1's", options: .regularExpression)
        text = text.replacingOccurrences(of: ", ([A-Z]{2})([A-Z][a-z])", with: ", $1 $2", options: .regularExpression)
        if let tail = text.range(of: ", [A-Z]{2}, USA$", options: .regularExpression) { text = String(text[..<tail.lowerBound]) }
        text = FerryBuilder.withoutStopPositionNote(text.trimmingCharacters(in: .whitespaces))
        if text != text.uppercased() { return text }
        return FerryBuilder.njTransitStationName(text)
            .replacingOccurrences(of: " At ", with: " at ")
            .replacingOccurrences(of: " And ", with: " and ")
            .replacingOccurrences(of: " Of ", with: " of ")
    }

    /// Headsign: "1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare" → "Jersey City Journal Sq"
    /// (drops the leading route number, "via ..." and the trailing fare note).
    /// Empty (so the UI uses the terminal's name) when it's no destination: a timetable's internal name, which has a year in it
    /// ("KS_2025", "Blue Regular 2025", Ulster), or the route's own name ("Route 3" on route 3; "Yellow Route" on route "YELLOW")
    static func headsign(_ raw: String, route: String, longName: String = "") -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // A direction after a name ("41 Lafayette Trolley Outbound", COAST) isn't part of it
        let directionWords: Set<String> = ["NORTHBOUND", "SOUTHBOUND", "EASTBOUND", "WESTBOUND", "INBOUND", "OUTBOUND"]
        if let last = text.split(separator: " ").last, directionWords.contains(last.uppercased()), text.count > last.count {
            text = String(text.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
        }
        if hasYear(text) || names(route: route, longName: longName, text) { return "" }
        for suffix in ["-Exact Fare", " Exact Fare", "-EXACT FARE", " EXACT FARE"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var kept = Array(words)
        if let first = kept.first, isRoute(String(first), route), kept.count > 1 { kept.removeFirst() }
        if let via = kept.firstIndex(where: { $0.uppercased() == "VIA" }), via > 0 { kept = Array(kept[..<via]) }
        if let last = kept.last, directionWords.contains(last.uppercased()), kept.count > 1 { kept.removeLast() }
        var joined = htmlDecoded(kept.joined(separator: " ")).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        // Direction-only headsigns (Dutchess's "Northbound", "Outbound") can't be destinations, nor a bare "Terminal" (SRTA's, which
        // has two) or "(Loop)" (Montachusett's): leave empty and use the terminal's name (the UI doesn't show "Northbound")
        if directionWords.contains(joined.uppercased()) || ["TERMINAL", "LOOP", "(LOOP)"].contains(joined.uppercased()) { return "" }
        // "Halesite to Huntington LIRR" (Huntington HART): the destination is the latter; "To White Plains" (Leprechaun): drop the "To"
        if let range = joined.range(of: " to ", options: [.caseInsensitive, .backwards]) {
            joined = String(joined[range.upperBound...])
        }
        if joined.lowercased().hasPrefix("to ") { joined = String(joined.dropFirst(3)) }
        joined = joined.trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "" : stopName(joined)
    }

    /// Whether a headsign's first word is the route: its number, or its number with a direction letter on one of them (COAST's
    /// "12N Rochester" on route 12, "33 Downtown Dover" on route 33s)
    static func isRoute(_ word: String, _ route: String) -> Bool {
        let a = word.uppercased(), b = route.trimmingCharacters(in: .whitespaces).uppercased()
        guard !b.isEmpty else { return false }
        if a == b { return true }
        let letters: Set<Character> = ["N", "S", "E", "W"]
        func plusLetter(_ long: String, _ short: String) -> Bool {
            long.count == short.count + 1 && long.hasPrefix(short) && short.last?.isNumber == true && letters.contains(long.last!)
        }
        return plusLetter(a, b) || plusLetter(b, a)
    }

    /// Whether the text has a year in it (four digits on their own, 1990 to 2099: "KS_2025", "2025 X")
    static func hasYear(_ text: String) -> Bool {
        var digits = ""
        for ch in text + " " {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
                continue
            }
            if digits.count == 4, let year = Int(digits), (1990...2099).contains(year) { return true }
            digits = ""
        }
        return false
    }

    /// Whether a headsign only gives the route's name: its short name, or either name with the word "Route" before or after it
    /// ("Route 3" on route 3, "Yellow Route" on route "YELLOW", "S2 Route" on the route called "S2"). A headsign equal to the long name
    /// alone stays: Huntington's are both ("Halesite to Huntington LIRR")
    static func names(route: String, longName: String, _ text: String) -> Bool {
        let headsign = text.uppercased()
        guard !headsign.isEmpty else { return false }
        let short = route.trimmingCharacters(in: .whitespaces).uppercased()
        if headsign == short { return true }
        for name in [short, longName.trimmingCharacters(in: .whitespaces).uppercased()] where !name.isEmpty {
            if headsign == "ROUTE " + name || headsign == name + " ROUTE" { return true }
        }
        return false
    }
}
