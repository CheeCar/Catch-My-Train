import XCTest
@testable import TransitCore

/// The timetable-only bus companies of Coach USA's package and of NJ Transit's website around New York: who they are, where
/// they're downloaded, and how their data is read (one company of a package several share, short names that are the company's,
/// directions the data can't tell apart, routes named by how their long names start)
final class NewYorkBusCompaniesTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

    static let coachUSA = ["SLH", "SUBT", "ROCK", "COMC", "NAE", "OWL"]
    static let njTransitSite = ["LAKE", "HUNT", "ACAD", "SOM", "SUSX"]

    func testTheCompanies() throws {
        let codes = Self.coachUSA + Self.njTransitSite
        let built = RegionalBusFeed.builtIn.map(\.code)
        let seat = try XCTUnwrap(built.firstIndex(of: "SEAT"))
        XCTAssertEqual(Array(built[(seat + 1)...].prefix(codes.count)), codes)
        for code in codes {
            let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code), code)
            XCTAssertNotNil(feed.downloadArea, code)
            XCTAssertFalse(feed.hasRealtime || feed.needsAccount || feed.needsKey || feed.onlyServiceArea, code)
            XCTAssertEqual(feed.builtInURL.scheme, "https", code)
            // New: nothing stored to read again
            XCTAssertEqual(feed.readingVersion, 0, code)
            XCTAssertGreaterThanOrEqual(ColorVision.contrast(try XCTUnwrap(UInt32(feed.color, radix: 16)), 0xFFFFFF), 4.5, code)
            // In the New York area (Academy's buses reach the Philadelphia area's south of Trenton too): express buses into
            // Manhattan or White Plains, the three counties' local ones
            XCTAssertEqual(MetroArea.areas(ofBus: feed), code == "ACAD" ? [.newYork, .philadelphia] : [.newYork], code)
            let kind: VehicleKind = ["HUNT", "SOM", "SUSX"].contains(code) ? .localBus : .expressBus
            for area in MetroArea.areas(ofBus: feed) {
                XCTAssertEqual(MetroArea.kinds(ofOperator: MetroArea.busOperatorID(code), in: area), [kind], code)
            }
        }
        XCTAssertEqual(Set(codes.compactMap { RegionalBusFeed.feed(code: $0)?.downloadArea }).count, codes.count)
        // Coach USA's six: one package, each company its own part of it, by its agency_id and name there
        let coach = Self.coachUSA.compactMap { RegionalBusFeed.feed(code: $0) }
        XCTAssertEqual(Set(coach.map(\.builtInURL.absoluteString)), ["https://api.prod.coachusa.com/gtfs"])
        XCTAssertEqual(coach.map { $0.agency?.id }, ["1574", "1573", "1559", "1566", "664", "1801"])
        XCTAssertEqual(coach.map { $0.agency?.name }, coach.map(\.name))
        XCTAssertEqual(RegionalBusFeed.builtIn.filter { $0.agency != nil }.map(\.code), Self.coachUSA)
        XCTAssertEqual(RegionalBusFeed.builtIn.filter(\.shortNamesNameCompany).map(\.code), Self.coachUSA)
        XCTAssertEqual(RegionalBusFeed.builtIn.filter(\.directionsFromStops).map(\.code), ["HUNT"])
        for code in Self.njTransitSite {
            let url = try XCTUnwrap(RegionalBusFeed.feed(code: code)?.builtInURL.absoluteString)
            XCTAssertTrue(url.hasPrefix("https://content.njtransit.com/sites/default/files/developers-resources/"), code)
        }
    }

    /// Each company's box takes in its stops (a few of the busiest, and the ends of its routes)
    func testEachBoxHasTheCompanysStops() {
        let places: [(DownloadArea, [(Double, Double)])] = [
            (.shortLine, [(40.757, -73.991), (41.6556, -74.6893), (42.0987, -75.9180), (41.5768, -75.2588)]),
            (.suburbanTransit, [(40.3487, -74.6590), (40.4966, -74.4455), (40.757, -73.991)]),
            (.rocklandCoaches, [(41.1476, -73.9893), (41.0468, -74.0229), (40.757, -73.991)]),
            (.communityCoach, [(40.774, -74.354), (40.757, -73.991)]),
            (.newarkAirportExpress, [(40.751, -73.977), (40.6895, -74.1745)]),
            (.orangeWestchester, [(41.034, -73.775), (41.4459, -74.4229)]),
            (.lakeland, [(40.883, -74.537), (40.7187, -74.569), (40.757, -73.991)]),
            (.hunterdon, [(40.513, -74.863), (40.3659, -74.9430)]),
            (.academy, [(40.338, -74.097), (40.386, -74.183), (40.0276, -74.8693), (40.757, -73.992)]),
            (.somerset, [(40.587, -74.62), (40.565, -74.613), (40.498, -74.445)]),
            (.sussex, [(41.031, -74.636), (41.112, -74.578), (40.898, -74.709)]),
        ]
        for (area, points) in places {
            for (lat, lon) in points {
                XCTAssertTrue(area.contains(Coordinate(latitude: lat, longitude: lon)), "\(area.rawValue) \(lat), \(lon)")
            }
        }
    }

    // MARK: One company of a package several share

    /// Coach USA's package: its six around New York with others across the country (one here, in Wisconsin), each with its own
    /// routes, services and stops; every route's short name the company's, its number at the start of the long name
    private func coachUSAFiles(shortLineID: String = "1574", shortLineName: String = "ShortLine Hudson") -> [String: Data] {
        let agencies = [(shortLineID, shortLineName), ("1573", "Suburban Transit"), ("1559", "Rockland Coaches"),
                        ("1566", "Community Coach"), ("664", "Newark Airport Express"), ("1801", "Orange Westchester Link"),
                        ("563", "Wisconsin Coach Lines")]
        // Route, its agency, short and long name, service, headsign, from and to
        let routes: [(String, String, String, String, String, String, String, String)] = [
            ("R1", shortLineID, "ShortLine Hudson", "00-10 - Long Island - Monticello", "SH", "Middletown", "PA", "MT"),
            ("R2", shortLineID, "ShortLine Hudson", "Eastside Woodbury Common", "SH", "Woodbury Common", "PA", "WC"),
            ("R3", shortLineID, "ShortLine Hudson", "Eastside Manhattan Commuter Service", "SH", "New York", "MT", "PA"),
            ("R4", shortLineID, "ShortLine Hudson", "Main Line", "SH", "Middletown", "PA", "MT"),
            ("R5", "1573", "Suburban Transit", "100 - Princeton - NYC", "SU", "Princeton", "PA", "PR"),
            ("R6", "1559", "Rockland Coaches", "9/9A", "RC", "New City", "PA", "NC"),
            ("R7", "1566", "Community Coach", "77 Local", "CC", "Livingston", "PA", "LV"),
            ("R8", "664", "Newark Airport Express", "Newark Airport Express", "NA", "Newark Airport", "GC", "EW"),
            ("R9", "1801", "OWL", "Orange Westchester Link", "OW", "White Plains", "MT", "WP"),
            ("R10", "563", "Wisconsin Coach Lines", "901 Waukesha - Milwaukee", "WI", "Milwaukee", "WK", "MK"),
        ]
        let services = [("SH", 20260901), ("SU", 20250527), ("RC", 20250106), ("CC", 20230401), ("NA", 20250310),
                        ("OW", 20210628), ("WI", 20240101)]
        return [
            "agency.txt": d((["agency_id,agency_name,agency_url,agency_timezone"]
                             + agencies.map { "\($0.0),\($0.1),https://example.com,America/New_York" }).joined(separator: "\n")),
            "routes.txt": d((["route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color"]
                             + routes.map { "\($0.0),\($0.1),\($0.2),\($0.3),3,," }).joined(separator: "\n")),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            PA,Port Authority Bus Terminal,40.7570,-73.9910
            GC,Grand Central,40.7510,-73.9770
            MT,Middletown,41.4459,-74.4229
            WC,Woodbury Common,41.3150,-74.1300
            PR,Princeton,40.3487,-74.6590
            NC,New City,41.1476,-73.9893
            LV,Livingston Mall,40.7740,-74.3540
            EW,Newark Airport Terminal A,40.6895,-74.1745
            WP,White Plains Bus Center,41.0340,-73.7750
            WK,Waukesha Metro Transit Center,43.0117,-88.2315
            MK,Milwaukee Intermodal Station,43.0345,-87.9171
            """),
            "trips.txt": d((["route_id,service_id,trip_id,trip_headsign,direction_id"]
                            + routes.map { "\($0.0),\($0.4),T\($0.0),\($0.5),0" }).joined(separator: "\n")),
            "stop_times.txt": d((["trip_id,arrival_time,departure_time,stop_id,stop_sequence"]
                                 + routes.flatMap { ["T\($0.0),12:10:00,12:10:00,\($0.6),1", "T\($0.0),13:10:00,13:10:00,\($0.7),2"] })
                .joined(separator: "\n")),
            "calendar.txt": d((["service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date"]
                               + services.map { "\($0.0),1,1,1,1,1,0,0,\($0.1),20270501" }).joined(separator: "\n")),
        ]
    }

    private func index(_ code: String, _ files: [String: Data]) throws -> NJBusIndex {
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code), code)
        return try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: feed), feed: feed)
    }

    /// Each badge and terminal leaving a stop between noon and one
    private func departures(_ index: NJBusIndex, near lat: Double, _ lon: Double) -> Set<String> {
        let slice = index.slice(near: Coordinate(latitude: lat, longitude: lon), radiusMeters: 300)
        let arrivals = slice.arrivals(pierIDs: slice.piers.map(\.id), from: now, to: now.addingTimeInterval(3600), realtime: [], now: now)
        return Set(arrivals.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" })
    }

    func testEachCompanyReadsItsOwnPartOfCoachUSAsPackage() throws {
        let files = coachUSAFiles()
        // Its own routes only, the badge from the long name: its number, or the name riders know it by
        let badges = try Self.coachUSA.map { try index($0, files).routeNames }
        XCTAssertEqual(badges, [["00-10", "Eastside", "Main Line"], ["100"], ["9/9A"], ["77"], ["EWR"], ["OWL"]])
        // Its own stops and services: its file, its bounds and its days aren't the whole package's; its version is its own
        // services' first day
        let shortLine = try index("SLH", files)
        XCTAssertEqual(shortLine.stopCount, 3)
        XCTAssertEqual(Set(shortLine.stopNames), ["Port Authority Bus Terminal", "Middletown", "Woodbury Common"])
        XCTAssertEqual(shortLine.serviceIDs, ["SH"])
        XCTAssertEqual(shortLine.version, "20260901")
        XCTAssertEqual(shortLine.bounds, NJBusIndex.Bounds(minLat: 40.757, maxLat: 41.4459, minLon: -74.4229, maxLon: -73.991))
        XCTAssertEqual(shortLine.tripCount, 4)
        let airport = try index("NAE", files)
        XCTAssertEqual(Set(airport.stopNames), ["Grand Central", "Newark Airport Terminal A"])
        XCTAssertEqual(airport.version, "20250310")
        // Each trip's stops point at the stops kept
        XCTAssertEqual(departures(shortLine, near: 40.7570, -73.9910),
                       ["00-10 Middletown", "Eastside Woodbury Common", "Main Line Middletown"])
        XCTAssertEqual(departures(shortLine, near: 41.4459, -74.4229), ["Eastside New York"])
        XCTAssertEqual(departures(airport, near: 40.7510, -73.9770), ["EWR Newark Airport"])
        // The lines' own colors, by badge
        let slice = shortLine.slice(near: Coordinate(latitude: 40.7570, longitude: -73.9910), radiusMeters: 300)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: slice.routes.map { ($0.id, $0.color) }),
                       ["NJB-SLH/00-10": "AC61A7", "NJB-SLH/Eastside": "B04876", "NJB-SLH/Main Line": "FF6442"])
        let map = try XCTUnwrap(shortLine.map())
        XCTAssertEqual(Set(map.routes.map(\.route)), ["NJB-SLH/00-10", "NJB-SLH/Eastside", "NJB-SLH/Main Line"])
        XCTAssertTrue(map.routes.allSatisfy { $0.lines.joined().allSatisfy { $0[1] > -75 } }, "a line reaches Wisconsin")
    }

    func testACompanyIsFoundByNameWhenItsIDChanges() throws {
        // A new agency_id: found by its name, in any case
        for name in ["ShortLine Hudson", "SHORTLINE HUDSON"] {
            let shortLine = try index("SLH", coachUSAFiles(shortLineID: "2001", shortLineName: name))
            XCTAssertEqual(shortLine.routeNames, ["00-10", "Eastside", "Main Line"], name)
        }
        // Neither its ID nor its name: nothing of the others' is taken for it
        XCTAssertThrowsError(try index("SLH", coachUSAFiles(shortLineID: "2001", shortLineName: "Hudson Valley Coaches")))
        // A package of its own with routes that name no agency: its only company's
        var files = coachUSAFiles()
        files["agency.txt"] = d("agency_id,agency_name,agency_url,agency_timezone\n1574,ShortLine Hudson,https://example.com,America/New_York")
        files["routes.txt"] = d("route_id,route_short_name,route_long_name,route_type\nR1,ShortLine Hudson,00-10 - Long Island - Monticello,3")
        XCTAssertEqual(try index("SLH", files).routeNames, ["00-10"])
    }

    /// Companies of a package several share come one after another, so a check downloads it once for all of them
    func testOneDownloadForCompaniesSharingAPackage() {
        func feed(_ code: String, _ file: String) -> RegionalBusFeed {
            RegionalBusFeed(code: code, name: code, url: "https://example.com/" + file, color: "0080C0")
        }
        let feeds = [feed("TA", "a.zip"), feed("TB", "b.zip"), feed("TC", "a.zip"), feed("TD", "c.zip"), feed("TE", "b.zip")]
        XCTAssertEqual(RegionalBusFeed.downloadOrder(feeds).map(\.code), ["TA", "TC", "TB", "TE", "TD"])
        XCTAssertEqual(RegionalBusFeed.downloadOrder([]).map(\.code), [])
        let order = RegionalBusFeed.downloadOrder(RegionalBusFeed.builtIn).map(\.code)
        XCTAssertEqual(order, RegionalBusFeed.builtIn.map(\.code), "the app's companies are listed so already")
        let first = order.firstIndex(of: "SLH") ?? 0
        XCTAssertEqual(Array(order[first...].prefix(6)), Self.coachUSA)
    }

    // MARK: NJ Transit's website

    func testLakelandsRoutesOnePerHighway() throws {
        let files: [String: Data] = [
            "agency.txt": d("agency_id,agency_name,agency_url,agency_timezone\n20163,Lakeland Bus Lines Inc.,https://example.com,America/New_York"),
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            L1,20163,,Rt. 46/80 - Eastbound,3
            L2,20163,,Rt. 46/80 - Westbound,3
            L3,20163,,Rt. 78 - Eastbound,3
            L4,20163,,Rt. 78 - Westbound,3
            L5,20163,,Downtown Wall Street Eastbound,3
            L6,20163,,Downtown Wall Street Westbound,3
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            DV,E Blackwell St. at Lakeland Bus Terminal,40.8830,-74.5370
            PA,NYC Port Authority Bus Terminal,40.7570,-73.9910
            BV,Bernardsville,40.7187,-74.5690
            WS,Wall Street,40.7060,-74.0090
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            L1,WK,E1,PABT,1
            L2,WK,W1,Rockaway Mall via Dover,0
            L3,WK,E2,PABT,1
            L4,WK,W2,Bernardsville via Warren P&amp;R,0
            L5,WK,E3,Wall Street,1
            L6,WK,W3,Mt. Arlington Park &amp; Ride via Dover,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            E1,12:10:00,12:10:00,DV,1
            E1,,,BV,2
            E1,13:10:00,13:10:00,PA,3
            W1,12:10:00,12:10:00,PA,1
            W1,13:10:00,13:10:00,DV,2
            E2,12:15:00,12:15:00,BV,1
            E2,13:15:00,13:15:00,PA,2
            W2,12:20:00,12:20:00,PA,1
            W2,13:20:00,13:20:00,BV,2
            E3,12:30:00,12:30:00,DV,1
            E3,13:40:00,13:40:00,WS,2
            W3,12:30:00,12:30:00,WS,1
            W3,13:40:00,13:40:00,DV,2
            """),
            "calendar.txt": d("service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20260101,20271231"),
        ]
        let lakeland = try index("LAKE", files)
        // One route for each way's pair; "PABT" said in full
        XCTAssertEqual(lakeland.routeNames, ["46/80", "78", "Wall St"])
        XCTAssertEqual(departures(lakeland, near: 40.8830, -74.5370), ["46/80 Port Authority Bus Terminal", "Wall St Wall Street"])
        XCTAssertEqual(departures(lakeland, near: 40.7570, -73.9910), ["46/80 Rockaway Mall", "78 Bernardsville"])
        XCTAssertEqual(departures(lakeland, near: 40.7060, -74.0090), ["Wall St Mt. Arlington Park & Ride"])
        // A stop with no time gets one between its neighbors' (Lakeland's data leaves half of them blank)
        XCTAssertEqual(departures(lakeland, near: 40.7187, -74.5690), ["46/80 Port Authority Bus Terminal", "78 Port Authority Bus Terminal"])
        // The slash in a badge stays in it: the company is what comes before the first one
        XCTAssertEqual(RegionalBusFeed.badge("NJB-LAKE/46/80"), "46/80")
        XCTAssertEqual(RegionalBusFeed.of(route: "NJB-LAKE/46/80")?.code, "LAKE")
        XCTAssertEqual(FerryFeed.badge("NJB-ROCK/9/9A"), "9/9A")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-LAKE/46/80"), "7A4419")
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: "LAKE"))
        XCTAssertEqual(feed.badge(longNameStart: "Rt. 46/80 - Eastbound"), "46/80")
        XCTAssertNil(feed.badge(longNameStart: "Rt. 46/80X"))
    }

    /// Hunterdon's data gives every trip direction 1: the two ways are told apart by where the trips go
    func testHunterdonsDirectionsFromWhereTripsGo() throws {
        let files: [String: Data] = [
            "routes.txt": d("route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color\n14,20212,14,,3,00AFEF,FFFFFF"),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            FL,LINK Bus Transfer Center (Jury Lot),40.5130,-74.8630
            LA,Lambertville,40.3659,-74.9430
            """),
            "trips.txt": d("route_id,service_id,trip_id,trip_headsign,direction_id\n14,WK,H1,Lambertville,1\n14,WK,H2,Flemington,1"),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            H1,12:10:00,12:10:00,FL,1
            H1,12:50:00,12:50:00,LA,2
            H2,12:10:00,12:10:00,LA,1
            H2,12:50:00,12:50:00,FL,2
            """),
            "calendar.txt": d("service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20260101,20261231"),
        ]
        let hunterdon = try index("HUNT", files)
        // Toward Manhattan 0, away from it 1
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: hunterdon.patterns.map { ($0.headsign, $0.direction) }),
                       ["Lambertville": 1, "Flemington": 0])
        XCTAssertEqual(departures(hunterdon, near: 40.5130, -74.8630), ["14 Lambertville"])
        // Read with the data's directions, both would be one way
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: "HUNT"))
        let asGiven = RegionalBusFeed(code: "HUNT", name: feed.name, url: feed.builtInURL.absoluteString, color: feed.color)
        let read = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: asGiven), feed: asGiven)
        XCTAssertEqual(Set(read.patterns.map(\.direction)), [1])
    }

    /// Academy's headsigns describe the route with the place: its trips show their last stop instead. Somerset's name a college
    /// by its initials, Lakeland's the bus terminal
    func testHeadsignsOfAcademySomersetAndLakeland() throws {
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            602,20122,602,Route 36 - Port Authority,3,000000,ffffff
            352,20122,352,PNC Bank Arts Center - Port Authority,3,e8e8e8,000000
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            HL,Highlands Bay Ave,40.4040,-73.9910
            PNC,PNC Bank Arts Center,40.3860,-74.1830
            PA,Port Authority Bus Terminal (Gate 9),40.7570,-73.9920
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            602,WK,A1,Route 36 to Port Authority - Highlands Highway,1
            602,WK,A2,Port Authority to Route 36 - Highway Highlands,0
            352,WK,A3,PNC to PABT,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            A1,12:10:00,12:10:00,HL,1
            A1,13:30:00,13:30:00,PA,2
            A2,12:10:00,12:10:00,PA,1
            A2,13:30:00,13:30:00,HL,2
            A3,12:20:00,12:20:00,PNC,1
            A3,13:10:00,13:10:00,PA,2
            """),
            "calendar.txt": d("service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20260101,20261231"),
        ]
        let academy = try index("ACAD", files)
        XCTAssertEqual(departures(academy, near: 40.4040, -73.9910), ["602 Port Authority Bus Terminal (Gate 9)"])
        XCTAssertEqual(departures(academy, near: 40.7570, -73.9920), ["602 Highlands Bay Ave"])
        XCTAssertEqual(departures(academy, near: 40.3860, -74.1830), ["352 Port Authority Bus Terminal (Gate 9)"])
        // Its data's black isn't its routes' color
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-ACAD/602"), "A31F34")
        XCTAssertEqual(NJBusBuilder.headsign("RVCC", route: "CAT 1R"), "RVCC")
        XCTAssertEqual(NJBusBuilder.headsign("New Brunswick", route: "CAT 1R"), "New Brunswick")
        XCTAssertEqual(NJBusBuilder.headsign("PABT", route: ""), "Port Authority Bus Terminal")
        XCTAssertEqual(NJBusBuilder.stopName("RVCC"), "RVCC")
    }

    func testSussexRoutesByName() throws {
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            1,SC,,Skylands Connect,3,d670da,
            2,SC,,New Freedom,3,ed9564,
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            SP,Sparta Theater,41.0310,-74.6360
            FR,Franklin Weis Market (Rt. 23),41.1120,-74.5780
            NE,Netcong,40.8980,-74.7090
            """),
            "trips.txt": d("route_id,service_id,trip_id,trip_headsign,direction_id\n1,WK,S1,Hampton Plaza,0\n2,WK,S2,Netcong,1"),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            S1,12:10:00,12:10:00,SP,1
            S1,12:40:00,12:40:00,FR,2
            S2,12:20:00,12:20:00,SP,1
            S2,12:50:00,12:50:00,NE,2
            """),
            "calendar.txt": d("service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20210401,20270501"),
        ]
        let sussex = try index("SUSX", files)
        XCTAssertEqual(sussex.routeNames, ["Skylands", "New Freedom"])
        XCTAssertEqual(departures(sussex, near: 41.0310, -74.6360), ["Skylands Hampton Plaza", "New Freedom Netcong"])
        let slice = sussex.slice(near: Coordinate(latitude: 41.0310, longitude: -74.6360), radiusMeters: 300)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: slice.routes.map { ($0.id, $0.color) }),
                       ["NJB-SUSX/Skylands": "D670DA", "NJB-SUSX/New Freedom": "ED9564"])
    }

    // MARK: Lines in their own colors

    /// Black or white text, whichever reads better on the line's color; the companies' own colors take white
    func testTextOnTheNewLinesColors() {
        for route in ["NJB-SLH/00-10", "NJB-SLH/250", "NJB-SLH/Main Line", "NJB-OWL/OWL", "NJB-HUNT/19", "NJB-HUNT/15",
                      "NJB-SUSX/New Freedom", "NJB-SUSX/Skylands", "NJB-WRTD/Yellow A", "NJB-WRTD/671B"] {
            XCTAssertTrue(RegionalBusFeed.darkText(route: route), route)
        }
        for route in ["NJB-SLH/900", "NJB-SLH/Eastside", "NJB-HUNT/16", "NJB-HUNT/23", "NJB-WRTD/991", "NJB-WRTD/Blue A",
                      "NJB-SUBT/100", "NJB-LAKE/46/80", "NJB-NAE/EWR"] {
            XCTAssertFalse(RegionalBusFeed.darkText(route: route), route)
        }
        // WRTD's two whose trips are in more than one color: its own color
        let wrtd = RegionalBusFeed.feed(code: "WRTD")?.color
        XCTAssertNotNil(wrtd)
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-WRTD/674D"), wrtd)
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-WRTD/674A"), "1F77B4")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-OWL/OWL"), "CCDBE9")
    }
}
