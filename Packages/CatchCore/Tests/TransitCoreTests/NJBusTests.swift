import XCTest
@testable import TransitCore

/// NJ Transit bus: builds a compact binary file and only takes the nearby slice at use time. The sample format matches real data (calendar_dates only).
final class NJBusTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

    private var files: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color
            1,NJB,1,,3,000000
            107,NJB,107,,3,000000
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id
            100,100,NEWARK PENN STATION LANE 5,,40.734500,-74.164200,1
            101,101,BROAD ST AT MARKET ST,,40.735600,-74.171900,1
            102,102,JOURNAL SQUARE TRANSPORTATION CENTER,,40.732900,-74.063600,2
            103,103,PORT AUTHORITY BUS TERMINAL,,40.756900,-73.990800,3
            104,104,MAIN ST AT ADAMS AVE,,40.600000,-74.300000,4
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
            1,5,9001,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,S1
            1,5,9002,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,S1
            1,5,9003,1 NEWARK BROAD ST-Exact Fare,1,1,S2
            107,5,9004,107 NEW YORK,0,2,S3
            107,8,9005,107 NEW YORK,0,2,S3
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            9001,12:10:00,12:10:00,101,1,0,0
            9001,12:14:00,12:14:00,100,2,0,0
            9001,12:40:00,12:40:00,102,3,0,0
            9003,12:00:00,12:00:00,102,1,0,0
            9003,12:26:00,12:26:00,100,2,0,0
            9003,12:30:00,12:30:00,101,3,0,0
            9002,13:10:00,13:10:00,101,1,0,0
            9002,13:14:00,13:14:00,100,2,0,0
            9002,13:40:00,13:40:00,102,3,0,0
            9004,12:20:00,12:20:00,100,1,0,0
            9004,13:10:00,13:10:00,103,2,0,0
            9005,12:20:00,12:20:00,100,1,0,0
            9005,13:10:00,13:10:00,103,2,0,0
            """),
            "calendar_dates.txt": d("""
            service_id,date,exception_type
            5,20261013,1
            5,20261014,1
            5,20261015,1
            8,20270301,1
            """),
            "shapes.txt": d("""
            shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence
            S1,40.735600,-74.171900,1
            S1,40.734500,-74.164200,2
            S1,40.740000,-74.100000,3
            S1,40.732900,-74.063600,4
            """),
        ]
    }

    func testSystem() {
        XCTAssertEqual(TransitSystem.njBus.mode, .bus)
        XCTAssertEqual(TransitSystem.njBus.family, .bus)
        XCTAssertTrue(TransitSystem.njBus.usesTimetableFeed)
        XCTAssertFalse(TransitSystem.bus.usesTimetableFeed)
        XCTAssertEqual(FerryFeed.Source.cases(for: .njBus), [.njTransitBus])
        XCTAssertFalse(FerryFeed.Source.njTransitBus.hasRealtime)
        XCTAssertTrue(FerryFeed.isNJBusRoute("NJB-107"))
        XCTAssertFalse(FerryFeed.isRailRoute("NJB-107"))
        XCTAssertFalse(FerryFeed.isFerryRoute("NJB-107"))
        XCTAssertEqual(FerryFeed.badge("NJB-107"), "107")
        XCTAssertEqual(FerryFeed.routeName("NJB-107"), "NJ Transit Bus 107")
    }

    func testNames() {
        XCTAssertEqual(NJBusBuilder.stopName("MAIN ST AT ADAMS AVE"), "Main St at Adams Ave")
        XCTAssertEqual(NJBusBuilder.headsign("1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare", route: "1"),
                       "Jersey City Journal Sq")
        XCTAssertEqual(NJBusBuilder.headsign("107 NEW YORK", route: "107"), "New York")
        XCTAssertEqual(NJBusBuilder.headsign("", route: "107"), "")
    }

    func testBuildAndSlice() throws {
        let data = try NJBusBuilder.build(files: files, now: now)
        let index = try NJBusIndex(data: data)
        XCTAssertEqual(index.stopCount, 5)
        XCTAssertEqual(index.routeCount, 2)
        // 9005's calendar is beyond 45 days, so it's not kept
        XCTAssertEqual(index.tripCount, 4)
        XCTAssertEqual(index.version, "20261013")
        XCTAssertTrue(index.runs(from: now))
        // Can also tell from just the days with service (the full data can be released)
        XCTAssertTrue(NJBusIndex.runs(onAnyOf: index.allServiceDays, from: now))
        XCTAssertFalse(NJBusIndex.runs(onAnyOf: index.allServiceDays, from: now.addingTimeInterval(400 * 86400)))
        XCTAssertEqual(NJBusIndex.runs(onAnyOf: index.allServiceDays, from: now.addingTimeInterval(400 * 86400)),
                       index.runs(from: now.addingTimeInterval(400 * 86400)))
        // Checked daily from a week before the timetable runs out (see NJBusIndex.runsOut)
        let days = FerryFeed.days(from: now, count: 60)
        XCTAssertFalse(NJBusIndex.runsOut(Set(days), from: now))
        XCTAssertTrue(NJBusIndex.runsOut(Set(days.prefix(7)), from: now), "Its last day with buses is within the next 7 days")
        XCTAssertFalse(NJBusIndex.runsOut(Set(days.prefix(8)), from: now))
        XCTAssertTrue(NJBusIndex.runsOut(Set(days.dropFirst(7)), from: now), "No buses in the next 7 days")
        // Buses only 3 days a week, the next ones in 4 days: still running
        let weekends = days.enumerated().filter { $0.offset % 7 >= 4 }.map(\.element)
        XCTAssertFalse(NJBusIndex.runsOut(Set(weekends), from: now))
        XCTAssertTrue(NJBusIndex.runsOut([], from: now))
        // 9001 and 9002, with the same stop pattern, share one copy
        XCTAssertEqual(index.patterns.count, 3)

        // 1.5 km around Newark Penn Station: Newark Penn and Broad St
        let feed = index.slice(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500)
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["NJB-1", "NJB-107"])
        XCTAssertEqual(feed.route("NJB-1")?.color, NJBusIndex.color)
        XCTAssertEqual(feed.sources, [.njTransitBus])
        // The terminal is there too (for the direction), but only two stops are nearby
        XCTAssertTrue(feed.piers.contains { $0.name == "Port Authority Bus Terminal" })
        let near = feed.stations(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500)
        XCTAssertEqual(Set(near.map(\.name)), ["Newark Penn Station Lane 5", "Broad St at Market St"])
        let penn = try XCTUnwrap(feed.piers.first { $0.name == "Newark Penn Station Lane 5" }?.id)
        let arrivals = feed.arrivals(pierIDs: [penn], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        // 12:14 and 13:14 to Journal Sq, 12:20 to New York, 12:26 to Broad St
        XCTAssertEqual(arrivals.count, 4)
        XCTAssertEqual(Set(arrivals.map { $0.direction.terminal ?? "" }), ["Jersey City Journal Sq", "New York", "Newark Broad St"])
        XCTAssertTrue(arrivals.allSatisfy { $0.source == .scheduled })
        let toJSQ = try XCTUnwrap(feed.trips.first { $0.id == "njb:9001" })
        XCTAssertEqual(toJSQ.direction, "N")
        XCTAssertEqual(toJSQ.stops.count, 3)   // Broad St, Newark Penn (nearby), plus the terminal Journal Sq
        XCTAssertEqual(feed.trips.first { $0.id == "njb:9003" }?.direction, "S")
        XCTAssertEqual(feed.terminals(atPier: penn).map(\.terminal).sorted(), ["Jersey City Journal Sq", "New York", "Newark Broad St"])

        // Somewhere far away: nothing
        let empty = index.slice(near: Coordinate(latitude: 39.0, longitude: -74.9), radiusMeters: 1500)
        XCTAssertTrue(empty.piers.isEmpty && empty.trips.isEmpty)
        XCTAssertEqual(empty.sources, [.njTransitBus])

        // Map: two lines; route 1 uses shape data, route 107 connects the stops
        let map = try XCTUnwrap(index.map())
        XCTAssertEqual(map.routes.map(\.route), ["NJB-1", "NJB-107"])
        XCTAssertEqual(map.routes[0].lines.first?.count, 4)
        XCTAssertEqual(map.routes[1].lines.first?.count, 2)
    }

    /// Route 1 to Journal Sq: 9001 lets riders on at every stop but the terminal, 9002 and 9006 only let them off at Newark Penn
    /// (pickup_type = 1), 9007–9009 run express from Broad St. Route 107 (9004) only lets riders off at Market St, its only stop near Newark Penn.
    /// With restricted false, every pickup_type is 0.
    private func pickupFiles(restricted: Bool = true) -> [String: Data] {
        let rows: [(trip: String, time: String, stop: String, seq: Int, pickup: Int)] = [
            ("9001", "12:10:00", "101", 1, 0), ("9001", "12:14:00", "100", 2, 0), ("9001", "12:40:00", "102", 3, 1),
            ("9002", "13:10:00", "101", 1, 0), ("9002", "13:14:00", "100", 2, 1), ("9002", "13:40:00", "102", 3, 1),
            ("9006", "12:50:00", "101", 1, 0), ("9006", "12:54:00", "100", 2, 1), ("9006", "13:20:00", "102", 3, 0),
            ("9007", "12:30:00", "101", 1, 0), ("9007", "12:55:00", "102", 2, 1),
            ("9008", "13:00:00", "101", 1, 0), ("9008", "13:25:00", "102", 2, 1),
            ("9009", "13:30:00", "101", 1, 0), ("9009", "13:55:00", "102", 2, 1),
            ("9004", "11:30:00", "103", 1, 0), ("9004", "12:20:00", "105", 2, 1), ("9004", "12:25:00", "100", 3, 1),
        ]
        var f = files
        f["stops.txt"] = d("""
        stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id
        100,100,NEWARK PENN STATION LANE 5,,40.734500,-74.164200,1
        101,101,BROAD ST AT MARKET ST,,40.735600,-74.171900,1
        102,102,JOURNAL SQUARE TRANSPORTATION CENTER,,40.732900,-74.063600,2
        103,103,PORT AUTHORITY BUS TERMINAL,,40.756900,-73.990800,3
        105,105,MARKET ST AT MULBERRY ST,,40.736000,-74.167000,1
        """)
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
        1,5,9001,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,S1
        1,5,9002,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,S1
        1,5,9006,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,S1
        1,5,9007,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,
        1,5,9008,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,
        1,5,9009,1 JERSEY CITY JOURNAL SQ VIA RIVER TERMINAL-Exact Fare,0,1,
        107,5,9004,107 NEWARK,1,2,
        """)
        f["stop_times.txt"] = d("trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type\n"
            + rows.map { "\($0.trip),\($0.time),\($0.time),\($0.stop),\($0.seq),\(restricted ? $0.pickup : 0),0" }
                .joined(separator: "\n"))
        return f
    }

    /// Trip IDs of these arrivals
    private func tripIDs(_ arrivals: [Arrival]) -> [String] {
        arrivals.map { $0.id.components(separatedBy: "|")[0] }
    }

    /// pickup_type = 1 survives building and reading the file; trips that differ only there don't share a stop pattern,
    /// but the bus map still counts them together, so it draws the same lines as without the restrictions
    func testDropOffOnlyStopsRoundTrip() throws {
        let data = try NJBusBuilder.build(files: pickupFiles(), now: now)
        XCTAssertEqual(Array(data[4..<8]), [4, 0, 0, 0])
        let index = try NJBusIndex(data: data)
        XCTAssertEqual(index.tripCount, 7)
        func pattern(_ trip: String) throws -> Int {
            Int(index.tripPattern[try XCTUnwrap(index.tripIDs.firstIndex(of: trip))])
        }
        let all = try pattern("9001"), dropOff = try pattern("9002"), express = try pattern("9007"), route107 = try pattern("9004")
        // 9002 and 9006 share one, though only 9002's terminal says pickup_type = 1 (the terminal can't be boarded anyway);
        // 9001, which lets riders on at Newark Penn, gets its own
        XCTAssertEqual(index.patterns.count, 4)
        XCTAssertEqual(try pattern("9006"), dropOff)
        XCTAssertNotEqual(all, dropOff)
        XCTAssertEqual(index.patterns[all].stops, index.patterns[dropOff].stops)
        XCTAssertEqual(index.patterns[all].noBoarding, [])
        XCTAssertEqual(index.patterns[dropOff].noBoarding, [1])
        XCTAssertEqual(index.patterns[express].noBoarding, [])
        XCTAssertEqual(index.patterns[route107].noBoarding, [1])

        let plain = try NJBusIndex(data: NJBusBuilder.build(files: pickupFiles(restricted: false), now: now))
        XCTAssertEqual(plain.patterns.count, 3)
        XCTAssertTrue(plain.patterns.allSatisfy(\.noBoarding.isEmpty))
        // Route 1's Broad St–Newark Penn–Journal Sq trips (3) tie with the express (3) and win on more stops, so the map uses their shape
        // (counted apart, the 2 trips that only let riders off at Newark Penn would lose to the express)
        let map = try XCTUnwrap(index.map())
        XCTAssertEqual(map, plain.map())
        XCTAssertEqual(map.routes.first { $0.route == "NJB-1" }?.lines.first?.count, 4)
    }

    /// A company's time zone (agency_timezone) and a stop's own (stop_timezone) survive building and reading the file: the trips'
    /// days and times count in the company's, and each departure carries its stop's zone for showing it. The fixture's company is
    /// given Chicago time and one stop Denver time to test it
    func testTimeZonesRoundTrip() throws {
        var f = pickupFiles()
        f["agency.txt"] = d("""
        agency_id,agency_name,agency_url,agency_timezone
        NJB,Test Bus,https://example.com,America/Chicago
        """)
        f["stops.txt"] = d("""
        stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_timezone
        100,100,NEWARK PENN STATION LANE 5,,40.734500,-74.164200,1,
        101,101,BROAD ST AT MARKET ST,,40.735600,-74.171900,1,America/Denver
        102,102,JOURNAL SQUARE TRANSPORTATION CENTER,,40.732900,-74.063600,2,America/Chicago
        103,103,PORT AUTHORITY BUS TERMINAL,,40.756900,-73.990800,3,Not/AZone
        105,105,MARKET ST AT MULBERRY ST,,40.736000,-74.167000,1,
        """)
        let index = try NJBusIndex(data: NJBusBuilder.build(files: f, now: now))
        XCTAssertEqual(index.timeZone, "America/Chicago")
        // Only where it differs from the company's and is a real zone
        XCTAssertEqual(Array(index.stopTimeZones.values), ["America/Denver"])

        let feed = index.slice(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500)
        XCTAssertEqual(feed.zones, ["njb:": "America/Chicago"])
        XCTAssertEqual(feed.piers.first { $0.id == "njb:101" }?.timeZone, "America/Denver")
        XCTAssertNil(feed.piers.first { $0.id == "njb:100" }?.timeZone)
        XCTAssertEqual(feed.timeZone(ofTrip: "njb:9001").identifier, "America/Chicago")

        // Noon in New York is 11 AM in Chicago: 9001 leaves Broad St at 12:10 Chicago time, 70 minutes later
        let broad = feed.arrivals(pierIDs: ["njb:101"], from: now, to: now.addingTimeInterval(2 * 3600 + 300), realtime: [], now: now)
        XCTAssertEqual(Set(tripIDs(broad)), ["njb:9001", "njb:9007", "njb:9006", "njb:9008"])
        XCTAssertTrue(broad.allSatisfy { $0.timeZone == "America/Denver" }, "\(broad.map(\.timeZone))")
        let first = try XCTUnwrap(broad.first { $0.id.hasPrefix("njb:9001|") })
        XCTAssertEqual(first.arrivalTime, now.addingTimeInterval(70 * 60))
        XCTAssertEqual(first.stationTimeZone?.identifier, "America/Denver")
        let penn = feed.arrivals(pierIDs: ["njb:100"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(tripIDs(penn), ["njb:9001"])
        XCTAssertEqual(penn.first?.arrivalTime, now.addingTimeInterval(74 * 60))
        XCTAssertEqual(penn.first?.timeZone, "America/Chicago")

        // Without agency.txt (a file built before zones were kept reads the same way): the area's zone, New York's
        let plain = try NJBusIndex(data: NJBusBuilder.build(files: pickupFiles(), now: now))
        XCTAssertNil(plain.timeZone)
        let plainFeed = plain.slice(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500)
        XCTAssertNil(plainFeed.zones)
        let plainPenn = plainFeed.arrivals(pierIDs: ["njb:100"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(plainPenn.first?.arrivalTime, now.addingTimeInterval(14 * 60))
        XCTAssertEqual(plainPenn.first?.timeZone, MetroArea.newYork.timeZone.identifier)
    }

    /// A trip that only lets riders off at a stop isn't listed as departing there, and a stop where no trip lets riders on isn't a station
    func testDropOffOnlyStopsCantBeBoarded() throws {
        let index = try NJBusIndex(data: NJBusBuilder.build(files: pickupFiles(), now: now))
        let newark = Coordinate(latitude: 40.7345, longitude: -74.1642)
        let feed = index.slice(near: newark, radiusMeters: 1500)
        // Newark Penn stays in the trip, with its time (live data lines up by stop), but can't be boarded
        let trip = try XCTUnwrap(feed.trips.first { $0.id == "njb:9006" })
        XCTAssertEqual(trip.stops, ["njb:101", "njb:100", "njb:102"])
        XCTAssertEqual(trip.times, [12 * 3600 + 50 * 60, 12 * 3600 + 54 * 60, 13 * 3600 + 20 * 60])
        XCTAssertEqual(trip.noBoarding, [1])
        XCTAssertEqual(trip.boardingStops, ["njb:101"])
        XCTAssertNil(feed.trips.first { $0.id == "njb:9001" }?.noBoarding)

        let later = now.addingTimeInterval(2 * 3600)
        let penn = feed.arrivals(pierIDs: ["njb:100"], from: now, to: later, realtime: [], now: now)
        XCTAssertEqual(tripIDs(penn), ["njb:9001"])
        let broad = feed.arrivals(pierIDs: ["njb:101"], from: now, to: later, realtime: [], now: now)
        XCTAssertEqual(Set(tripIDs(broad)), ["njb:9001", "njb:9002", "njb:9006", "njb:9007", "njb:9008", "njb:9009"])
        XCTAssertEqual(feed.terminals(atPier: "njb:100").map(\.terminal), ["Jersey City Journal Sq"])
        XCTAssertEqual(feed.routesByPier()["njb:100"], ["NJB-1"])

        // Route 107 only lets riders off at Market St, its only stop nearby: neither the stop nor the route is offered here
        XCTAssertEqual(Set(feed.stations(near: newark, radiusMeters: 1500).map(\.name)),
                       ["Newark Penn Station Lane 5", "Broad St at Market St"])
        XCTAssertFalse(feed.piers.contains { $0.id == "njb:105" })
        XCTAssertEqual(feed.routes.map(\.id), ["NJB-1"])
        XCTAssertTrue(feed.arrivals(pierIDs: ["njb:105"], from: now.addingTimeInterval(-3600), to: later, realtime: [], now: now).isEmpty)
        // Where it does let riders on, it's there as before
        let terminal = Coordinate(latitude: 40.7569, longitude: -73.9908)
        let fromTerminal = index.slice(near: terminal, radiusMeters: 1500)
        XCTAssertEqual(fromTerminal.trips.map(\.id), ["njb:9004"])
        XCTAssertEqual(fromTerminal.stations(near: terminal, radiusMeters: 1500).map(\.name), ["Port Authority Bus Terminal"])
    }

    /// A small file written by hand in the given format: route 1 from Broad St via Newark Penn to Journal Sq, one trip (9001 at 12:10, 12:14, 12:40).
    /// Format 1 has no drop-off-only stops; from format 2 each stop pattern lists their positions after its stops
    private func handWritten(format: UInt32, noBoarding: [UInt16] = []) -> Data {
        var w = ByteWriter()
        func str(_ s: String) { w.u16(UInt16(s.utf8.count)); w.bytes(Array(s.utf8)) }
        func degrees(_ v: Double) { w.u32(UInt32(bitPattern: Int32((v * 1_000_000).rounded()))) }
        w.bytes(Array("CMNB".utf8)); w.u32(format); w.u32(UInt32(now.timeIntervalSince1970)); str("20261013")
        w.u32(3)
        str("100"); str("Newark Penn Station Lane 5"); degrees(40.7345); degrees(-74.1642)
        str("101"); str("Broad St at Market St"); degrees(40.7356); degrees(-74.1719)
        str("102"); str("Journal Square Transportation Center"); degrees(40.7329); degrees(-74.0636)
        w.u32(1); str("1")                                       // routes
        w.u32(1); str("5"); w.u16(1); w.u32(20261014)            // services, each with its dates
        // One stop pattern: route 0, direction 0, headsign, stops Broad St, Newark Penn, Journal Sq
        w.u32(1); w.u16(0); w.u8(0); str("Jersey City Journal Sq"); w.u16(3); w.u16(1); w.u16(0); w.u16(2)
        if format >= 2 {
            w.u16(UInt16(noBoarding.count))
            for i in noBoarding { w.u16(i) }
        }
        w.u32(1); str("9001"); w.u32(0); w.u16(0); w.u32(0)      // one trip: stop pattern 0, service 0, its times from 0
        w.u32(3)
        for t in [12 * 3600 + 10 * 60, 12 * 3600 + 14 * 60, 12 * 3600 + 40 * 60] { w.u32(UInt32(t)) }
        w.u32(0)                                                 // no bus map
        return w.data
    }

    /// Files written before drop-off-only stops were recorded (format 1) still read, with boarding allowed everywhere as before.
    /// A bad position or a format newer than this app knows makes the file unreadable, so the app downloads it again as for a damaged file
    func testFormatVersions() throws {
        let newark = Coordinate(latitude: 40.7345, longitude: -74.1642)
        let later = now.addingTimeInterval(3600)
        let old = try NJBusIndex(data: handWritten(format: 1))
        XCTAssertEqual(old.patterns.map(\.noBoarding), [[]])
        let oldFeed = old.slice(near: newark, radiusMeters: 1500)
        XCTAssertNil(oldFeed.trips.first?.noBoarding)
        XCTAssertEqual(Set(oldFeed.stations(near: newark, radiusMeters: 1500).map(\.name)),
                       ["Newark Penn Station Lane 5", "Broad St at Market St"])
        XCTAssertEqual(oldFeed.arrivals(pierIDs: ["njb:100"], from: now, to: later, realtime: [], now: now).map(\.arrivalTime),
                       [now.addingTimeInterval(14 * 60)])
        // Format 2 without restrictions reads the same; the monthly check sees it as new data, so the rebuilt file replaces format 1
        XCTAssertEqual(try NJBusIndex(data: handWritten(format: 2)).slice(near: newark, radiusMeters: 1500), oldFeed)
        XCTAssertFalse(NJBusIndex.sameContent(handWritten(format: 1), handWritten(format: 2)))

        let current = try NJBusIndex(data: handWritten(format: 2, noBoarding: [1]))
        XCTAssertEqual(current.patterns.map(\.noBoarding), [[1]])
        let feed = current.slice(near: newark, radiusMeters: 1500)
        XCTAssertEqual(feed.trips.first?.noBoarding, [1])
        XCTAssertEqual(feed.stations(near: newark, radiusMeters: 1500).map(\.name), ["Broad St at Market St"])
        XCTAssertTrue(feed.arrivals(pierIDs: ["njb:100"], from: now, to: later, realtime: [], now: now).isEmpty)

        // Only stops before the terminal can be marked; there is no format 0, and 3 isn't known yet
        XCTAssertThrowsError(try NJBusIndex(data: handWritten(format: 2, noBoarding: [2])))
        XCTAssertThrowsError(try NJBusIndex(data: handWritten(format: 2, noBoarding: [9])))
        XCTAssertThrowsError(try NJBusIndex(data: handWritten(format: 2, noBoarding: [0xFFFF])))
        XCTAssertThrowsError(try NJBusIndex(data: handWritten(format: 0)))
        XCTAssertThrowsError(try NJBusIndex(data: handWritten(format: 3)))
    }

    /// Monthly updates compare old and new files byte by byte, ignoring the generation time in bytes 8–11
    func testSameContentIgnoresBuildTime() {
        let a = Data([1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 1, 9, 9])
        var b = a; b[9] = 7
        var c = a; c[13] = 0
        XCTAssertTrue(NJBusIndex.sameContent(a, b))
        XCTAssertFalse(NJBusIndex.sameContent(a, c))
        XCTAssertFalse(NJBusIndex.sameContent(a, a.prefix(13)))
    }

    /// A damaged count in the header throws instead of reserving memory for billions of records first
    func testHugeCountInHeaderThrows() {
        let u32Max: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        // magic, version 1, build time, empty version string, then the stop count
        let bus = Array("CMNB".utf8) + [1, 0, 0, 0] + [0, 0, 0, 0] + [0, 0] + u32Max
        XCTAssertThrowsError(try NJBusIndex(data: Data(bus)))
        // magic, version 1, start, end, build time, then the string count
        let timetable = Array("CMTT".utf8) + [1, 0, 0, 0] + [UInt8](repeating: 0, count: 12) + u32Max
        XCTAssertThrowsError(try Timetable(data: Data(timetable)))
    }

    func testBadData() {
        XCTAssertThrowsError(try NJBusIndex(data: Data("nope".utf8)))
        var f = files
        f["trips.txt"] = nil
        XCTAssertThrowsError(try NJBusBuilder.build(files: f, now: now))
    }

    /// CMT_NJBUS_ZIP points to bus_data.zip (Mac only).
    func testRealNJBusDataIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["CMT_NJBUS_ZIP"] else { throw XCTSkip("CMT_NJBUS_ZIP not set") }
        #if canImport(Compression)
        let zip = try Data(contentsOf: URL(fileURLWithPath: path))
        var clock = Date()
        let small = try ZipReader.read(zip, names: ["routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt"])
        let data = try NJBusBuilder.build(files: small,
                                          stopTimes: { body in try ZipReader.forEachRow(zip, name: "stop_times.txt", body) },
                                          shapes: { body in try ZipReader.forEachRow(zip, name: "shapes.txt", body) },
                                          now: Date())
        print("njbus: built in \(String(format: "%.1f", Date().timeIntervalSince(clock))) s, file \(data.count) bytes")
        clock = Date()
        let index = try NJBusIndex(data: data)
        print("njbus: loaded in \(String(format: "%.2f", Date().timeIntervalSince(clock))) s: \(index.stopCount) stops, \(index.routeCount) routes, \(index.patterns.count) patterns, \(index.tripCount) trips, \(index.timeBytes.count / 4) stop times, version \(index.version), map routes \(index.map()?.routes.count ?? 0)")
        XCTAssertTrue(index.runs(from: Date()))
        let places: [(String, Coordinate)] = [
            ("Newark Penn", Coordinate(latitude: 40.7345, longitude: -74.1642)),
            ("Journal Square", Coordinate(latitude: 40.7329, longitude: -74.0636)),
            ("Hoboken", Coordinate(latitude: 40.7359, longitude: -74.0291)),
            ("Port Authority", Coordinate(latitude: 40.7569, longitude: -73.9908)),
            ("Trenton", Coordinate(latitude: 40.2185, longitude: -74.7539)),
        ]
        for (name, c) in places {
            clock = Date()
            let feed = index.slice(near: c, radiusMeters: 1500)
            let sliceTime = Date().timeIntervalSince(clock)
            clock = Date()
            let near = feed.stations(near: c, radiusMeters: 1300)
            let arrivals = feed.arrivals(pierIDs: Array(near.prefix(8).map(\.id)), from: Date(), to: Date().addingTimeInterval(2 * 3600),
                                         realtime: [], now: Date())
            print("njbus: \(name): slice \(String(format: "%.2f", sliceTime)) s (\(feed.piers.count) stops, \(feed.trips.count) trips, \(feed.routes.count) routes), nearby \(near.count) in \(String(format: "%.2f", Date().timeIntervalSince(clock))) s, e.g. \(near.prefix(4).map(\.name)); next 2 h \(arrivals.count): \(arrivals.prefix(5).map { "\(FerryFeed.badge($0.route)) \($0.direction.name)" })")
        }
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    /// A misprinted stop position ("nan", a missing decimal point, a huge number, 0,0) skips that stop instead of stopping the app
    func testBadStopPositionsAreSkipped() throws {
        var f = files
        f["stops.txt"] = Data((String(decoding: f["stops.txt"]!, as: UTF8.self)
                               + "\n105,105,BAD NAN,,nan,-74.1,1\n106,106,BAD DECIMAL,,4074.5,-74.1,1"
                               + "\n107,107,BAD HUGE,,1e12,1e12,1\n108,108,BAD ZERO,,0,0,1").utf8)
        f["stop_times.txt"] = Data((String(decoding: f["stop_times.txt"]!, as: UTF8.self) + "\n9004,13:30:00,13:30:00,107,3,0,0").utf8)
        let index = try NJBusIndex(data: NJBusBuilder.build(files: f, now: now))
        XCTAssertEqual(index.stopCount, 5)
        XCTAssertEqual(index.tripCount, 4)
        XCTAssertTrue(Coordinate.isUsable(latitude: 40.7, longitude: -74.1))
        XCTAssertFalse(Coordinate.isUsable(latitude: .nan, longitude: -74.1))
        XCTAssertFalse(Coordinate.isUsable(latitude: 4074.5, longitude: -74.1))
        XCTAssertFalse(Coordinate.isUsable(latitude: 1e12, longitude: 1e12))
        XCTAssertFalse(Coordinate.isUsable(latitude: 0, longitude: 0))
    }
}
