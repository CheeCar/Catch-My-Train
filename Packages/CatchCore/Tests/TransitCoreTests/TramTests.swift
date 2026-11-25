import XCTest
@testable import TransitCore

/// Roosevelt Island Tram: trips derived from operating hours and intervals on the RIOC website (official intervals).
final class TramTests: XCTestCase {

    private func day(_ n: Int) -> Date { Timetable.serviceDayStart(n, in: Timetable.timeZone)! }
    private func at(_ n: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        day(n).addingTimeInterval(TimeInterval(h * 3600 + m * 60 + s))
    }
    private let hours = RooseveltIslandTram.builtInHours

    func testBuiltInHoursArePlausible() {
        XCTAssertTrue(hours.isPlausible)
        XCTAssertEqual(hours.days.count, 7)
        // Friday and Saturday run until 3 a.m., other days until a bit after 1 a.m.
        XCTAssertEqual(hours.span(weekday: 4, way: .toManhattan)?.last, 27 * 3600)
        XCTAssertEqual(hours.span(weekday: 0, way: .toManhattan)?.last, 25 * 3600 + 36 * 60)
    }

    func testHeadwayFollowsRIOC() {
        // Weekday morning and evening rush every 7.5 minutes, other times every 15 minutes; weekends always 15 minutes
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 0, secondsOfDay: 8 * 3600), 450)
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 2, secondsOfDay: 15 * 3600), 450)
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 2, secondsOfDay: 12 * 3600), 900)
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 4, secondsOfDay: 19 * 3600), 900)
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 5, secondsOfDay: 8 * 3600), 900)
        XCTAssertEqual(RooseveltIslandTram.headway(weekday: 6, secondsOfDay: 17 * 3600), 900)
    }

    func testMondayDepartures() {
        // 2026-10-19 is a Monday
        let list = RooseveltIslandTram.departures(.toManhattan, from: at(20261019, 5, 0), to: at(20261019, 11, 0), hours: hours)
        XCTAssertEqual(list.first, at(20261019, 6, 0))
        XCTAssertEqual(list[1], at(20261019, 6, 15))
        XCTAssertTrue(list.contains(at(20261019, 7, 7, 30)), "Morning rush every 7.5 minutes")
        XCTAssertTrue(list.contains(at(20261019, 10, 0)))
        XCTAssertFalse(list.contains(at(20261019, 10, 7, 30)), "After 10:00, back to every 15 minutes")
        // 6:00–7:00 four trips, 7:00–10:00 twenty-four trips, 10:00–11:00 five trips (including 10:00 and 11:00)
        XCTAssertEqual(list.count, 4 + 24 + 5)
        let island = RooseveltIslandTram.departures(.toIsland, from: at(20261019, 5, 0), to: at(20261019, 6, 30), hours: hours)
        XCTAssertEqual(island.first, at(20261019, 6, 7))
    }

    func testLateNightBelongsToPreviousDay() {
        // Sunday night trips run into early Monday (every 15 minutes from 6:00, last trip 1:30, not past 1:36); the Saturday 3:00 a.m. trip belongs to Friday
        let mon = RooseveltIslandTram.departures(.toManhattan, from: at(20261019, 0, 0), to: at(20261019, 5, 59), hours: hours)
        XCTAssertEqual(mon.first, at(20261019, 0, 0))
        XCTAssertEqual(mon.last, at(20261018, 25, 30))
        let sat = RooseveltIslandTram.departures(.toManhattan, from: at(20261017, 2, 30), to: at(20261017, 5, 59), hours: hours)
        XCTAssertEqual(sat, [at(20261017, 2, 30), at(20261017, 2, 45), at(20261016, 27, 0)])
    }

    func testDaylightSavingDayStillHasService() {
        // 2026-11-01 DST ends (a Sunday)
        let list = RooseveltIslandTram.departures(.toManhattan, from: at(20261101, 0, 0), to: at(20261102, 0, 0), hours: hours)
        XCTAssertGreaterThan(list.count, 70)
        XCTAssertEqual(list.filter { $0 >= at(20261101, 6, 0) }.first, at(20261101, 6, 0))
    }

    func testArrivalsAreScheduledWithDirections() {
        let now = at(20261019, 12, 0)
        let list = RooseveltIslandTram.arrivals(stationIDs: [RooseveltIslandTram.islandStationID, RooseveltIslandTram.manhattanStationID, "R11"],
                                                from: now, to: now.addingTimeInterval(3600), hours: hours, now: now)
        XCTAssertEqual(list.count, 9)   // 12:00–13:00: 5 trips to Manhattan (12:00 … 13:00), 4 to the island (12:07 … 12:52)
        XCTAssertTrue(list.allSatisfy { $0.source == .scheduled && $0.route == "RIT" })
        let ri = list.filter { $0.stationID == RooseveltIslandTram.islandStationID }
        XCTAssertTrue(ri.allSatisfy { $0.direction.code == "N" && $0.direction.terminal == "Manhattan" })
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
    }

    func testBoardShowsOnlyOneDirectionAtTramStation() {
        let now = at(20261019, 12, 0)
        let station = RooseveltIslandTram.station(id: RooseveltIslandTram.islandStationID)!
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 300, source: .estimated)
        let arrivals = RooseveltIslandTram.arrivals(stationIDs: [station.id], from: now, to: now.addingTimeInterval(7200),
                                                    hours: hours, now: now)
        let board = NearbyBoardBuilder.build(stations: [station], walks: [station.id: walk], arrivals: arrivals,
                                             settings: .default, now: now, routes: [station.id: ["RIT"]])
        let b = try! XCTUnwrap(board.stations.first)
        XCTAssertEqual(b.routes, ["RIT"])
        XCTAssertFalse(b.north.trains.isEmpty)
        XCTAssertEqual(b.north.directions.first?.terminal, "Manhattan")
        XCTAssertTrue(b.south.trains.isEmpty)
        XCTAssertTrue(b.south.directions.isEmpty)
        // Overnight shutdown: direction names exist even with no trips
        let night = at(20261019, 3, 0)
        let empty = NearbyBoardBuilder.build(stations: [station], walks: [station.id: walk], arrivals: [],
                                             settings: .default, now: night, routes: [station.id: ["RIT"]])
        XCTAssertEqual(empty.stations.first?.north.directions.first?.terminal, "Manhattan")
    }

    func testNearbyStations() {
        // Near the Roosevelt Island subway station: the island tram station is about 150 m away
        let near = RooseveltIslandTram.stations(near: Coordinate(latitude: 40.759145, longitude: -73.953350), radiusMeters: 500)
        XCTAssertEqual(near.map(\.id), [RooseveltIslandTram.islandStationID])
        XCTAssertTrue(RooseveltIslandTram.stations(near: Coordinate(latitude: 40.7466, longitude: -73.9026), radiusMeters: 1300).isEmpty)
    }

    /// Same as Trillium's data: one file has the tram and several bus routes, and besides the Monday–Thursday service there's a one-day "Rush Hour Service" (few trips).
    func testHoursFromTrilliumStyleGTFS() throws {
        func d(_ s: String) -> Data { Data(s.utf8) }
        let routes = d("""
        route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
        10093,805,,RIOC Red Bus,,3,,247BFA,FFFFFF
        10092,805,,Roosevelt Island Aerial Tramway,,0,,4CD975,000000
        """)
        var trips = "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id\n"
        var stopTimes = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        func add(_ service: String, _ dir: Int, _ times: [String], route: String = "10092") {
            for (i, t) in times.enumerated() {
                let id = "\(service)_\(dir)_\(i)_\(route)"
                trips += "\(route),\(service),\(id),,,\(dir),,\n"
                stopTimes += "\(id),\(t),\(t),\(dir == 0 ? "2437315" : "2436149"),1\n"
                stopTimes += "\(id),\(t),\(t),\(dir == 0 ? "2436149" : "2437315"),2\n"
            }
        }
        let weekday = ["06:00:00", "06:21:00", "12:00:00", "25:36:00"]
        add("MTuWTh", 0, weekday)
        add("MTuWTh", 1, ["06:07:00", "12:07:00", "25:43:00"])
        add("Fri", 0, ["06:00:00", "27:00:00"]); add("Fri", 1, ["06:00:00", "27:00:00"])
        add("Sat", 0, ["06:00:00", "27:00:00"]); add("Sat", 1, ["06:00:00", "27:00:00"])
        add("Sun", 0, ["06:00:00", "25:36:00"]); add("Sun", 1, ["06:07:00", "25:43:00"])
        add("Rush", 0, ["07:00:00", "19:45:00"]); add("Rush", 1, ["07:00:00", "19:45:00"])
        add("MTuWTh", 0, ["05:30:00", "23:59:00"], route: "10093")   // buses don't count
        let calendar = d("""
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        MTuWTh,1,1,1,1,0,0,0,20260722,20270201
        Fri,0,0,0,0,1,0,0,20260722,20270201
        Sat,0,0,0,0,0,1,0,20260722,20270201
        Sun,0,0,0,0,0,0,1,20260722,20270201
        Rush,1,1,1,1,1,0,0,20261126,20270101
        """)
        let h = try RooseveltIslandTram.hours(routes: routes, trips: d(trips), stopTimes: d(stopTimes), calendar: calendar,
                                              version: "20260722")
        XCTAssertTrue(h.isPlausible, "\(h)")
        XCTAssertEqual(h.span(weekday: 0, way: .toManhattan), .init(first: 6 * 3600, last: 25 * 3600 + 36 * 60))
        XCTAssertEqual(h.span(weekday: 0, way: .toIsland), .init(first: 6 * 3600 + 7 * 60, last: 25 * 3600 + 43 * 60))
        // Friday has only Fri (2 trips) and Rush (2 trips): on a tie take the name that sorts first (Fri), so it doesn't end at 19:45
        XCTAssertEqual(h.span(weekday: 4, way: .toManhattan)?.last, 27 * 3600)
        XCTAssertEqual(h.days, hours.days)
        XCTAssertEqual(h.source, "GTFS 20260722")
    }

    func testImplausibleHoursAreRejected() {
        var h = hours
        h.days[2][RooseveltIslandTram.Way.toManhattan.rawValue] = .init(first: 7 * 3600, last: 19 * 3600 + 45 * 60)
        XCTAssertFalse(h.isPlausible)
        h.days.removeLast()
        XCTAssertFalse(h.isPlausible)
    }

    func testMapGetsTramLine() {
        let map = SubwayMap(source: "x", feedVersion: "1", stations: [], routes: [])
        let m = RooseveltIslandTram.adding(to: map)
        XCTAssertEqual(m.routes.map(\.route), ["RIT"])
        XCTAssertEqual(m.routes.first?.lines.first?.count, 2)
        XCTAssertEqual(m.stations.count, 2)
        XCTAssertEqual(RooseveltIslandTram.adding(to: m), m, "Adding twice still gives only one")
    }

    /// Real data (runs only on a Mac): CMT_TRAM_ZIP points to the downloaded rooseveltisland-ny-us.zip; prints the resulting operating hours.
    func testRealTramFeedIfAvailable() throws {
        #if canImport(Compression)
        guard let path = ProcessInfo.processInfo.environment["CMT_TRAM_ZIP"] else { throw XCTSkip("CMT_TRAM_ZIP is not set") }
        let h = try StaticRefresh.tramHours(zip: try Data(contentsOf: URL(fileURLWithPath: path)))
        func f(_ t: Int) -> String { String(format: "%02d:%02d", t / 3600, t / 60 % 60) }
        for (i, day) in h.days.enumerated() {
            let text = RooseveltIslandTram.Way.allCases.map { w in day[w.rawValue].map { "\(w.terminal) \(f($0.first))-\(f($0.last))" } ?? "\(w.terminal) none" }
            print("tram day \(i): " + text.joined(separator: ", "))
        }
        print("tram source: \(h.source), plausible \(h.isPlausible), same as built-in \(h.days == RooseveltIslandTram.builtInHours.days)")
        XCTAssertTrue(h.isPlausible)
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }
}
