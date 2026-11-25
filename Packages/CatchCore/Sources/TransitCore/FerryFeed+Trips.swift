import Foundation

extension FerryFeed {
    // MARK: Trips

    /// Boats departing these piers within a time window (schedule + one operator's realtime data).
    public func arrivals(pierIDs: [String], from: Date, to: Date, realtime: FerryRealtime? = nil,
                         now: Date = Date()) -> [Arrival] {
        arrivals(pierIDs: pierIDs, from: from, to: to, realtime: realtime.map { [$0] } ?? [], now: now)
    }

    /// Boats departing these piers within a time window (schedule + NYC Ferry and NY Waterway realtime data).
    /// - Trips with realtime data: the delay "predicted − scheduled" carries over to later stops, marked as realtime,
    ///   but not past a NO_DATA stop (from there the scheduled time is used, marked as scheduled, until the next stop
    ///   with a prediction); piers already departed aren't shown.
    /// - Without realtime data (Staten Island Ferry, Seastreak, or trips not yet departed): use the scheduled time, marked as scheduled.
    /// - Trips that end at this pier, or only drop off here, aren't shown (you can't board).
    public func arrivals(pierIDs: [String], from: Date, to: Date, realtime: [FerryRealtime],
                         now: Date = Date()) -> [Arrival] {
        let wanted = Set(pierIDs)
        guard !wanted.isEmpty else { return [] }
        // Train realtime data may use station codes (see Pier.code)
        var stopCodes: [String: String] = [:]
        for pier in piers { if let code = pier.code { stopCodes[code] = pier.id } }
        // A stop with its own time zone shows its times in it (Pier.timeZone); the others in their trip's operator's
        var stopZones: [String: String] = [:]
        for pier in piers where wanted.contains(pier.id) { if let zone = pier.timeZone { stopZones[pier.id] = zone } }
        // First pick out trips that stop at these piers (stations): trains have thousands of trips a day, no need to scan them all every time.
        // Each operator's trips count their days in its own time zone (GTFS: a trip's times are its operator's local time), so they're
        // grouped by zone and each group gets its own days
        var groups: [String: (zone: TimeZone, trips: [Trip])] = [:]
        var zoneByOperator: [Substring: TimeZone] = [:]
        for trip in trips where trip.boardingStops.contains(where: wanted.contains) {
            let key = Self.operatorKey(trip.id)
            let zone: TimeZone
            if let known = zoneByOperator[key] {
                zone = known
            } else {
                zone = timeZone(ofTrip: trip.id)
                zoneByOperator[key] = zone
            }
            groups[zone.identifier, default: (zone, [])].trips.append(trip)
        }
        // Longest prefix first (in buses, "njb:CTT/" trips use CTtransit's, not NJ Transit's "njb:"); prefixes computed only once
        let byPrefix = realtime.map { (prefix: $0.prefix, rt: $0) }.sorted { $0.prefix.count > $1.prefix.count }
        var result: [Arrival] = []
        for (zone, candidates) in groups.values {
            let firstDay = Timetable.dayNumber(from.addingTimeInterval(-24 * 3600), in: zone)
            let lastDay = Timetable.dayNumber(to, in: zone)
            var days: [Int] = []
            var d = firstDay
            while d <= lastDay, days.count < 4 {
                days.append(d)
                d = Timetable.nextDay(d)
            }
            for day in days {
                guard let dayStart = Timetable.serviceDayStart(day, in: zone) else { continue }
                for trip in candidates {
                    guard services[trip.service]?.runs(on: day) == true else { continue }
                    let live = byPrefix.first { trip.id.hasPrefix($0.prefix) }.flatMap { p in
                        p.rt.delays(for: trip, dayStart: dayStart, day: day, stopCodes: stopCodes)
                    }
                    if live?.canceled == true { continue }
                    for i in 0..<(trip.stops.count - 1) where wanted.contains(trip.stops[i]) && trip.canBoard(at: i) {
                        // Realtime data says this trip skips this stop
                        if live?.skipped.contains(i) == true { continue }
                        let terminal = destination(of: trip, at: i)
                        var time = dayStart.addingTimeInterval(TimeInterval(trip.times[i]))
                        var source = ArrivalSource.scheduled
                        var updatedAt = now
                        if let live {
                            // Realtime data says this stop has already been departed: don't show
                            if let passed = live.passedIndex, i <= passed { continue }
                            if let delay = live.delay(atIndex: i) {
                                time = time.addingTimeInterval(delay)
                                source = .realtime
                                updatedAt = live.updatedAt ?? now
                            }
                        }
                        guard time >= from, time <= to else { continue }
                        // A loop or a route serving a stop twice can board at the same stop twice on one trip: those also get the position
                        let once = trip.stops.firstIndex(of: trip.stops[i]) == trip.stops.lastIndex(of: trip.stops[i])
                        result.append(Arrival(
                            id: "\(trip.id)|\(day)|\(trip.stops[i])" + (once ? "" : "@\(i)"),
                            stationID: trip.stops[i],
                            route: trip.route,
                            direction: Direction(code: trip.direction, name: terminal.map { "To " + $0 } ?? trip.route,
                                                 terminal: terminal),
                            arrivalTime: time,
                            source: source,
                            status: .normal,
                            updatedAt: updatedAt,
                            timeZone: stopZones[trip.stops[i]] ?? zone.identifier))
                    }
                }
            }
        }
        return result.sorted { ($0.arrivalTime ?? .distantFuture) < ($1.arrivalTime ?? .distantFuture) }
    }

    /// For the app's log, an operator whose live trains are matched by train number (NJ Transit's): how many trains its live data
    /// has, and how many of them give one of the timetable's trips a live status on the service days around now (the trip runs
    /// that day, the live start date is that day's, and its times are within 3 hours of the timetable's: see FerryRealtime.delays)
    public func liveTrains(_ realtime: FerryRealtime, now: Date = Date()) -> (live: Int, matched: Int) {
        var stopCodes: [String: String] = [:]
        for pier in piers { if let code = pier.code { stopCodes[code] = pier.id } }
        let zone = timeZone(ofTrip: realtime.prefix)
        // Yesterday's too: a train that left before midnight is still on yesterday's service day
        let days = [Timetable.dayNumber(now.addingTimeInterval(-24 * 3600), in: zone), Timetable.dayNumber(now, in: zone)]
        var matched = Set<String>()
        for day in days {
            guard let dayStart = Timetable.serviceDayStart(day, in: zone) else { continue }
            for trip in trips where trip.id.hasPrefix(realtime.prefix) {
                guard let number = trip.number.flatMap(FerryRealtime.trainNumber), realtime.numbers[number] != nil,
                      !matched.contains(number), services[trip.service]?.runs(on: day) == true,
                      realtime.delays(for: trip, dayStart: dayStart, day: day, stopCodes: stopCodes) != nil else { continue }
                matched.insert(number)
            }
        }
        return (realtime.numbers.count, matched.count)
    }

    /// That count as a line for the app's log (the operator's name and two counts only): "NJ Transit Rail live data: 54 trains,
    /// 54 of them matched to the timetable's trips on these days"
    public func liveTrainsLogLine(_ realtime: FerryRealtime, now: Date = Date()) -> String {
        let count = liveTrains(realtime, now: now)
        return "\(realtime.source.name) live data: \(count.live) trains, \(count.matched) of them matched to the timetable's trips on these days"
    }

    /// The next departure after `after` at each of these piers, on each route and in each direction, from the timetable alone
    /// (no live data), looking up to `within` ahead (the board says only those less than a day from now: NearbyBoardBuilder.nextWithin)
    public func nextDepartures(pierIDs: [String], after: Date, within: TimeInterval = 23 * 3600, now: Date = Date()) -> [Arrival] {
        Arrival.firstPerDirection(arrivals(pierIDs: pierIDs, from: after, to: after.addingTimeInterval(within), realtime: [], now: now))
    }

    // MARK: Map

    /// Routes and piers drawn on the map (same format as the subway map).
    public func map() -> SubwayMap {
        let served = Set(trips.flatMap(\.stops))
        // Draw only one dot for several operators at the same pier (using the group's first stop and name)
        let groups = pierGroups()
        let stations = piers.filter { p in served.contains(p.id) && (groups[p.id].map { $0.group == "ferry:" + p.id } ?? true) }
            .map { SubwayMap.Station(id: $0.id, name: groups[$0.id]?.name ?? $0.name, lat: $0.lat, lon: $0.lon) }
        let mapRoutes = routes.compactMap { r -> SubwayMap.Route? in
            guard let lines = shapes[r.id], !lines.isEmpty else { return nil }
            return SubwayMap.Route(route: r.id, color: r.color, lines: lines)
        }
        let present = sources
        return SubwayMap(source: Source.allCases.filter(present.contains).map { $0.name + " GTFS" }.joined(separator: " + "),
                         feedVersion: Source.allCases.compactMap { versions[$0.rawValue] }.filter { !$0.isEmpty }
                            .joined(separator: " / "),
                         stations: stations, routes: mapRoutes)
    }
}
