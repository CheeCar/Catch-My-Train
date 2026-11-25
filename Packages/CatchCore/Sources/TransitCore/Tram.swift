import Foundation

// MARK: - Roosevelt Island Tram (part of Subway, timetable only)
//
// The tram has no realtime data and doesn't run to a fixed schedule but at intervals. It uses the official intervals:
// trips are derived from the intervals on the RIOC website (weekdays 7:00–10:00 and 14:30–19:00 every 7.5 minutes, other times every 15 minutes),
// and the UI states it's a timetable with estimated times.
// The downloadable GTFS (compiled by Trillium, https://data.trilliumtransit.com/gtfs/rooseveltisland-ny-us/rooseveltisland-ny-us.zip)
// lists a ride as 10–21 minutes and midday every 21 minutes, which doesn't match reality, so only its first and last trip times per day (operating hours) are used.
// The app checks this feed once after the 1st of each month (together with the subway map), see App/Services/SubwayMapStore.swift.

public enum RooseveltIslandTram {
    /// Route ID (shown in the UI as a red "TRAM" badge)
    public static let route = "RIT"
    public static let color = "D52B1E"
    public static let builtInSourceURL = URL(string: "https://data.trilliumtransit.com/gtfs/rooseveltisland-ny-us/rooseveltisland-ny-us.zip")!
    /// The address: the source list's, or the one in code
    public static var sourceURL: URL { SourceList.timetableURL(for: listID) ?? builtInSourceURL }
    /// Its ID in the source list
    static let listID = "tram"
    /// Downloaded operating hours live in the shared folder; the widget reads the same copy
    public static let hoursFile = "tram_hours.json"

    /// Two directions: Roosevelt Island to Manhattan ("N"), Manhattan to Roosevelt Island ("S")
    public enum Way: String, Codable, CaseIterable, Sendable {
        case toManhattan = "N"
        case toIsland = "S"

        public var terminal: String { self == .toManhattan ? "Manhattan" : "Roosevelt Island" }
        public var direction: Direction { Direction(code: rawValue, name: "To " + terminal, terminal: terminal) }
        /// Which station this direction departs from
        public var stationID: String { self == .toManhattan ? islandStationID : manhattanStationID }
    }

    public static let islandStationID = "RIT-RI"
    public static let manhattanStationID = "RIT-MN"

    /// The two tram stations (coordinates from GTFS). Tickets and queuing before boarding: entry time counts as 1 minute.
    public static let stations: [Station] = [
        Station(id: islandStationID, name: "Tramway Plaza",
                coordinate: Coordinate(latitude: 40.757320, longitude: -73.954104),
                entrances: [StationEntrance(name: "Tramway Plaza", coordinate: Coordinate(latitude: 40.757320, longitude: -73.954104))],
                entranceToPlatformSeconds: 60),
        Station(id: manhattanStationID, name: "2 Av & E 60 St",
                coordinate: Coordinate(latitude: 40.761220, longitude: -73.964212),
                entrances: [StationEntrance(name: "2 Av & E 60 St", coordinate: Coordinate(latitude: 40.761220, longitude: -73.964212))],
                entranceToPlatformSeconds: 60),
    ]

    public static func isTramStation(_ id: String) -> Bool { id == islandStationID || id == manhattanStationID }
    public static func isTram(route: String) -> Bool { route == Self.route }

    /// Direction departing from this tram station
    public static func way(atStation id: String) -> Way? {
        id == islandStationID ? .toManhattan : id == manhattanStationID ? .toIsland : nil
    }

    public static func station(id: String) -> Station? { stations.first { $0.id == id } }

    /// Nearby tram stations, nearest first
    public static func stations(near coordinate: Coordinate, radiusMeters: Double) -> [Station] {
        stations.map { ($0, WalkEstimator.distanceMeters(coordinate, $0.coordinate)) }
            .filter { $0.1 <= radiusMeters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: Operating hours

    /// First and last trip each day (seconds from the start of the service day; may exceed 24 hours, e.g. 25:36 is 1:36 the next morning).
    public struct Span: Codable, Equatable, Sendable {
        public var first: Int
        public var last: Int
        public init(first: Int, last: Int) {
            self.first = first
            self.last = last
        }
    }

    /// Operating hours for all seven days and both directions.
    public struct Hours: Codable, Equatable, Sendable {
        /// 0 = Monday … 6 = Sunday; keys are Way's rawValue
        public var days: [[String: Span]]
        /// Where the data comes from ("RIOC" or the GTFS version)
        public var source: String

        public init(days: [[String: Span]], source: String) {
            self.days = days
            self.source = source
        }

        public func span(weekday: Int, way: Way) -> Span? {
            guard days.indices.contains(weekday) else { return nil }
            return days[weekday][way.rawValue]
        }

        /// Looks sane: both directions every day, first trip between 4:00–9:00, last trip between 22:00–29:00
        public var isPlausible: Bool {
            guard days.count == 7 else { return false }
            return days.allSatisfy { day in
                Way.allCases.allSatisfy { w in
                    guard let s = day[w.rawValue] else { return false }
                    return (4 * 3600...9 * 3600).contains(s.first) && (22 * 3600...29 * 3600).contains(s.last) && s.first < s.last
                }
            }
        }
    }

    /// Bundled operating hours (RIOC website: Sunday to Thursday 6:00 to 2:00 a.m., Friday and Saturday until 3:30 a.m.;
    /// exact first and last trip times match the tram's GTFS).
    public static let builtInHours: Hours = {
        func s(_ h: Int, _ m: Int) -> Int { h * 3600 + m * 60 }
        let regular: [String: Span] = [Way.toManhattan.rawValue: Span(first: s(6, 0), last: s(25, 36)),
                                       Way.toIsland.rawValue: Span(first: s(6, 7), last: s(25, 43))]
        let late: [String: Span] = [Way.toManhattan.rawValue: Span(first: s(6, 0), last: s(27, 0)),
                                    Way.toIsland.rawValue: Span(first: s(6, 0), last: s(27, 0))]
        // Monday to Thursday and Sunday are regular; Friday and Saturday are late
        return Hours(days: [regular, regular, regular, regular, late, late, regular], source: "RIOC")
    }()

    /// Operating hours in use: the downloaded one if downloaded (monthly check), otherwise the bundled one.
    public static func loadCurrentHours() -> Hours {
        if let data = StaticData.downloaded(hoursFile),
           let hours = try? JSONDecoder().decode(Hours.self, from: data), hours.isPlausible {
            return hours
        }
        return builtInHours
    }

    /// Save operating hours from the monthly check. Not saved if they look wrong (keep using the old ones).
    /// Returns whether the hours in use changed: compared by the hours themselves, not the file's bytes, so an unchanged month doesn't reload everything.
    @discardableResult
    public static func saveHours(_ hours: Hours) throws -> Bool {
        guard hours.isPlausible else { return false }
        let saved = StaticData.downloaded(hoursFile).flatMap { try? JSONDecoder().decode(Hours.self, from: $0) }
        if hours.days == builtInHours.days {
            // Same as the bundled hours: use those (nothing changes if they're already in use)
            guard saved != nil else { return false }
            StaticData.remove(hoursFile)
            return true
        }
        if let saved, saved.isPlausible, saved.days == hours.days { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try StaticData.save(try encoder.encode(hours), as: hoursFile)
        return true
    }

    // MARK: Intervals

    /// RIOC website: weekdays (Monday to Friday) 7:00–10:00 and 14:30–19:00 every 7.5 minutes, other times every 15 minutes.
    public static func headway(weekday: Int, secondsOfDay t: Int) -> Int {
        let rush = weekday < 5 && ((7 * 3600..<10 * 3600).contains(t) || (14 * 3600 + 1800..<19 * 3600).contains(t))
        return rush ? 450 : 900
    }

    /// Departure times in one direction within [from, to] (derived from operating hours and official intervals).
    public static func departures(_ way: Way, from: Date, to: Date, hours: Hours) -> [Date] {
        guard to >= from else { return [] }
        // The previous day's last trip may fall early this morning, so start from the previous day
        var day = Timetable.dayNumber(from.addingTimeInterval(-86400), in: Timetable.timeZone)
        let lastDay = Timetable.dayNumber(to, in: Timetable.timeZone)
        var result: [Date] = []
        var guardCount = 0
        while day <= lastDay, guardCount < 400 {
            guardCount += 1
            guard let start = Timetable.serviceDayStart(day, in: Timetable.timeZone) else { break }
            let weekday = Timetable.weekday(day)
            if let span = hours.span(weekday: weekday, way: way) {
                var t = span.first
                while t <= span.last {
                    let d = start.addingTimeInterval(TimeInterval(t))
                    if d > to { break }
                    if d >= from { result.append(d) }
                    t += headway(weekday: weekday, secondsOfDay: t)
                }
            }
            // Next day: service day start plus 36 hours always lands on the next day (DST changes too)
            day = Timetable.dayNumber(start.addingTimeInterval(36 * 3600), in: Timetable.timeZone)
        }
        return result
    }

    /// Trips at these stations (tram stations only) within [from, to], marked as "timetable".
    public static func arrivals(stationIDs: [String], from: Date, to: Date, hours: Hours, now: Date) -> [Arrival] {
        var result: [Arrival] = []
        for id in Set(stationIDs) {
            guard let way = way(atStation: id) else { continue }
            for d in departures(way, from: from, to: to, hours: hours) {
                result.append(Arrival(id: "\(route)-\(way.rawValue)-\(Int(d.timeIntervalSince1970))", stationID: id,
                                      route: route, direction: way.direction, arrivalTime: d,
                                      source: .scheduled, updatedAt: now))
            }
        }
        return result.sorted { ($0.arrivalTime ?? .distantFuture) < ($1.arrivalTime ?? .distantFuture) }
    }

    // MARK: Operating hours from GTFS

    /// Gets daily operating hours from Trillium's GTFS text files: for the tram route (route_type 0 or "Tram" in the name),
    /// per weekday take the service with the most trips (e.g. Monday to Thursday is "Year round (MTuWTh)", not the one-day "Rush Hour Service"),
    /// and the first and last departure times in each direction. direction_id 0 is from the island to Manhattan.
    public static func hours(routes: Data, trips: Data, stopTimes: Data, calendar: Data, version: String) throws -> Hours {
        var tramRoutes = Set<String>()
        try TimetableBuilder.forEachRow(routes) { col in
            let name = (col("route_long_name") ?? "") + " " + (col("route_short_name") ?? "")
            if col("route_type")?.trimmingCharacters(in: .whitespaces) == "0" || name.localizedCaseInsensitiveContains("tram") {
                if let id = col("route_id") { tramRoutes.insert(id) }
            }
        }
        // trip → (service, way)
        var tripInfo: [String: (service: String, way: Way)] = [:]
        try TimetableBuilder.forEachRow(trips) { col in
            guard let r = col("route_id"), tramRoutes.contains(r), let trip = col("trip_id"), let service = col("service_id") else { return }
            let way: Way = col("direction_id")?.trimmingCharacters(in: .whitespaces) == "1" ? .toIsland : .toManhattan
            tripInfo[trip] = (service, way)
        }
        // First-stop departure time of each trip
        var firstStop: [String: (seq: Int, time: Int)] = [:]
        try TimetableBuilder.forEachRow(stopTimes) { col in
            guard let trip = col("trip_id"), tripInfo[trip] != nil else { return }
            let seq = Int((col("stop_sequence") ?? "").trimmingCharacters(in: .whitespaces)) ?? Int.max
            let raw = col("departure_time").flatMap { $0.isEmpty ? nil : $0 } ?? col("arrival_time") ?? ""
            guard let t = TimetableBuilder.parseTime(raw.trimmingCharacters(in: .whitespaces)) else { return }
            if let old = firstStop[trip], old.seq <= seq { return }
            firstStop[trip] = (seq, Int(t))
        }
        // Trip count and first/last trips per service and direction
        struct Stat { var count = 0; var first = Int.max; var last = Int.min }
        var stats: [String: [Way: Stat]] = [:]
        for (trip, info) in tripInfo {
            guard let t = firstStop[trip]?.time else { continue }
            var s = stats[info.service, default: [:]][info.way, default: Stat()]
            s.count += 1
            s.first = min(s.first, t)
            s.last = max(s.last, t)
            stats[info.service, default: [:]][info.way] = s
        }
        // Which weekdays each service runs
        let dayColumns = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        var servicesByDay: [[String]] = Array(repeating: [], count: 7)
        try TimetableBuilder.forEachRow(calendar) { col in
            guard let service = col("service_id"), stats[service] != nil else { return }
            for (i, name) in dayColumns.enumerated() where col(name)?.trimmingCharacters(in: .whitespaces) == "1" {
                servicesByDay[i].append(service)
            }
        }
        var days: [[String: Span]] = []
        for i in 0..<7 {
            var day: [String: Span] = [:]
            for way in Way.allCases {
                let best = servicesByDay[i].compactMap { sid in stats[sid]?[way].map { (sid, $0) } }
                    .max { a, b in a.1.count != b.1.count ? a.1.count < b.1.count : a.0 > b.0 }
                if let s = best?.1 { day[way.rawValue] = Span(first: s.first, last: s.last) }
            }
            days.append(day)
        }
        return Hours(days: days, source: version.isEmpty ? "GTFS" : "GTFS " + version)
    }

    // MARK: Map

    /// The subway map with the tram line and both tram stations added (the tram is drawn as a straight red line).
    public static func adding(to map: SubwayMap) -> SubwayMap {
        guard !map.routes.contains(where: { $0.route == route }) else { return map }
        var m = map
        let points = stations.map { [$0.coordinate.latitude, $0.coordinate.longitude] }
        m.routes.append(SubwayMap.Route(route: route, color: color, lines: [points]))
        m.stations += stations.map { SubwayMap.Station(id: $0.id, name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        return m
    }
}
