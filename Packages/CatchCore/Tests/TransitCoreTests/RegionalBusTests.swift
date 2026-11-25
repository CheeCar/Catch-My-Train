import XCTest
@testable import TransitCore

/// The timetable-only bus agencies in the metro area (NICE, Suffolk, Bee-Line, CTtransit...): same compact file format as NJ Transit, with a code prefixed to IDs.
final class RegionalBusTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

    /// Data like NICE's and Dutchess's: mixed-case stop names, calendar.txt, route names split by day, HTML entities
    private var files: [String: Data] {
        [
            "routes.txt": d("""
            route_id,route_short_name,route_long_name,route_type,route_color
            15,"A  MS","A (POUGHKEEPSIE - FISHKILL) MON - SAT","3",18D657
            22,"A SUN","A (POUGHKEEPSIE - FISHKILL) SUN","3",18D657
            7,n6,Hempstead - Jamaica,3,00539B
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
            S1,Hempstead Transit Center,40.7069,-73.6171,0,
            S2,Fulton St &amp; Franklin Av,40.7060,-73.6300,,
            S3,Jamaica Center,40.7020,-73.8010,0,
            P1,Station area,40.7069,-73.6171,1,
            F1,MAIN ST AT MARKET ST,41.7004,-73.9210,0,
            F2,FISHKILL PLAZA,41.5300,-73.8900,0,
            X1,Hartford Union Station,41.7690,-72.6820,0,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            7,WK,T1,Jamaica,0,
            15,WK,T2,FISHKILL,0,
            22,SU,T3,FISHKILL,0,
            7,WK,T4,Hartford,0,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            T1,12:10:00,12:10:00,S1,1
            T1,12:14:00,12:14:00,S2,2
            T1,12:50:00,12:50:00,S3,3
            T2,12:30:00,12:30:00,F1,1
            T2,13:00:00,13:00:00,F2,2
            T3,12:30:00,12:30:00,F1,1
            T3,13:00:00,13:00:00,F2,2
            T4,12:00:00,12:00:00,S1,1
            T4,15:00:00,15:00:00,X1,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            SU,0,0,0,0,0,0,1,20260901,20261231
            """),
        ]
    }

    func testFeeds() {
        XCTAssertEqual(RegionalBusFeed.all.first, .njTransit)
        for code in ["UCAT", "SUL", "NTD", "RVT", "SEAT"] { XCTAssertNotNil(RegionalBusFeed.feed(code: code), code) }
        // Badges show white text on the operator's color: from Ulster's on (see RegionalBusFeed.all) it must be readable (4.5:1)
        for feed in RegionalBusFeed.all.drop(while: { $0.code != "UCAT" }) {
            XCTAssertGreaterThanOrEqual(contrastWithWhite(feed.color), 4.5, feed.code)
        }
        XCTAssertEqual(Set(RegionalBusFeed.all.map(\.code)).count, RegionalBusFeed.all.count)
        XCTAssertEqual(Set(RegionalBusFeed.all.map(\.fileName)).count, RegionalBusFeed.all.count)
        XCTAssertEqual(RegionalBusFeed.njTransit.fileName, "njbus.bin")
        XCTAssertEqual(RegionalBusFeed.feed(code: "NICE")?.fileName, "bus-nice.bin")
        XCTAssertTrue(RegionalBusFeed.all.allSatisfy { UInt32($0.color, radix: 16) != nil && $0.color.count == 6 })

        XCTAssertEqual(RegionalBusFeed.of(route: "NJB-107"), .njTransit)
        XCTAssertEqual(RegionalBusFeed.of(route: "NJB-NICE/n6")?.code, "NICE")
        XCTAssertNil(RegionalBusFeed.of(route: "LIRR-BAB"))
        XCTAssertEqual(FerryFeed.badge("NJB-NICE/n6"), "n6")
        XCTAssertEqual(FerryFeed.badge("NJB-107"), "107")
        XCTAssertEqual(FerryFeed.routeName("NJB-SCT/1"), "Suffolk County Transit 1")
        XCTAssertEqual(FerryFeed.routeName("NJB-107"), "NJ Transit Bus 107")
        XCTAssertTrue(FerryFeed.isNJBusRoute("NJB-NICE/n6"))
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-BXL/1"), "0080C0")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-107"), NJBusIndex.color)
    }

    func testNames() {
        XCTAssertEqual(NJBusBuilder.routeShortName("A  MS"), "A")
        XCTAssertEqual(NJBusBuilder.routeShortName("A SUN"), "A")
        XCTAssertEqual(NJBusBuilder.routeShortName("A EXP"), "A EXP")
        XCTAssertEqual(NJBusBuilder.routeShortName("n6"), "n6")
        XCTAssertEqual(NJBusBuilder.routeShortName("L SMS"), "L")
        XCTAssertEqual(NJBusBuilder.headsign("Northbound", route: "A"), "")
        XCTAssertEqual(NJBusBuilder.headsign("To White Plains", route: "WPP"), "White Plains")
        XCTAssertEqual(NJBusBuilder.headsign("Halesite to Huntington LIRR", route: "H20"), "Huntington LIRR")
        XCTAssertEqual(NJBusBuilder.headsign("The Bronx, Bedford Park", route: "60"), "The Bronx, Bedford Park")
        // Around Boston: COAST's direction letters and directions after the name, SRTA's "Terminal", Montachusett's "(Loop)"
        XCTAssertEqual(NJBusBuilder.headsign("12N Rochester via 108", route: "12"), "Rochester")
        XCTAssertEqual(NJBusBuilder.headsign("33 Downtown Dover", route: "33s"), "Downtown Dover")
        XCTAssertEqual(NJBusBuilder.headsign("41 Lafayette Trolley Outbound", route: "41"), "Lafayette Trolley")
        XCTAssertEqual(NJBusBuilder.headsign("Inbound", route: "41"), "")
        XCTAssertEqual(NJBusBuilder.headsign("Terminal", route: "1"), "")
        XCTAssertEqual(NJBusBuilder.headsign("(Loop)", route: "G1"), "")
        XCTAssertEqual(NJBusBuilder.headsign("Westgate Terminal", route: "15"), "Westgate Terminal")
        XCTAssertTrue(NJBusBuilder.isRoute("12N", "12"))
        XCTAssertTrue(NJBusBuilder.isRoute("33", "33s"))
        XCTAssertFalse(NJBusBuilder.isRoute("12X", "12"))
        XCTAssertFalse(NJBusBuilder.isRoute("N", ""))
        XCTAssertFalse(NJBusBuilder.isRoute("1N", "N"))
        XCTAssertFalse(NJBusBuilder.isRoute("120", "12"))
        // Manchester's long names start with the route: its number, with a letter on one ("2S", Saturdays)
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "1 Dartmouth/VA Hospital"), "1")
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "2S Hanover St/East Side Plaza SAT"), "2S")
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "Patriot LTD"), "Patriot LTD")
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "2S"), "2S")
        XCTAssertEqual(NJBusBuilder.stopName("Fulton St &amp; Franklin Av"), "Fulton St & Franklin Av")
        XCTAssertEqual(NJBusBuilder.stopName("Hempstead Transit Center"), "Hempstead Transit Center")
        XCTAssertEqual(NJBusBuilder.stopName("MAIN ST AT MARKET ST"), "Main St at Market St")
    }

    /// Ulster's one route per direction, "Route" in short names, River Valley's routes without a short name, headsigns that aren't destinations,
    /// River Valley's and SEAT's notes in stop names
    func testNamesInNewerData() {
        XCTAssertEqual(NJBusBuilder.routeShortName("KS-NB"), "KS")
        XCTAssertEqual(NJBusBuilder.routeShortName("UPL-WB"), "UPL")
        XCTAssertEqual(NJBusBuilder.routeShortName("CL Route"), "CL")
        XCTAssertEqual(NJBusBuilder.routeShortName("River Route"), "River")
        XCTAssertEqual(NJBusBuilder.routeShortName("Route 7"), "7")
        XCTAssertEqual(NJBusBuilder.routeShortName("Route"), "Route")
        XCTAssertEqual(NJBusBuilder.routeShortName("641 B"), "641 B")
        XCTAssertEqual(NJBusBuilder.direction(ofRoute: "KS-NB"), 0)
        XCTAssertEqual(NJBusBuilder.direction(ofRoute: "UPL-EB"), 0)
        XCTAssertEqual(NJBusBuilder.direction(ofRoute: "KS-SB"), 1)
        XCTAssertEqual(NJBusBuilder.direction(ofRoute: "z-wb "), 1)
        XCTAssertNil(NJBusBuilder.direction(ofRoute: "KS"))
        XCTAssertNil(NJBusBuilder.direction(ofRoute: "-NB"))
        XCTAssertNil(NJBusBuilder.direction(ofRoute: "BLUE"))
        XCTAssertNil(NJBusBuilder.direction(ofRoute: "Norwich-Foxwoods"))
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "581-582 Saybrook Rd/Wesleyan Hills"), "581-582")
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "Clinton Trolley"), "Clinton Trolley")
        XCTAssertNil(NJBusBuilder.routeLabel(longName: " "))
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "B1 Beverly to Pemberton"), "B1")
        XCTAssertEqual(NJBusBuilder.routeLabel(longName: "West Park Loop"), "West Park Loop")
        // A timetable's internal name, with a year in it, or the route's own name: no destination, so empty (the terminal is shown)
        XCTAssertEqual(NJBusBuilder.headsign("KS_2025", route: "KS"), "")
        XCTAssertEqual(NJBusBuilder.headsign("SATURDAY_E_2023", route: "EU"), "")
        XCTAssertEqual(NJBusBuilder.headsign("Blue Regular 2025", route: "BLUE"), "")
        XCTAssertEqual(NJBusBuilder.headsign("Yellow Route", route: "YELLOW"), "")
        XCTAssertEqual(NJBusBuilder.headsign("Route 1", route: "1"), "")
        XCTAssertEqual(NJBusBuilder.headsign("S2 Route", route: "2S", longName: "S2"), "")
        XCTAssertEqual(NJBusBuilder.headsign("KS", route: "KS"), "")
        // Places stay, numbers and long names too
        XCTAssertEqual(NJBusBuilder.headsign("Norwich via SR 12", route: "2"), "Norwich")
        XCTAssertEqual(NJBusBuilder.headsign("Mohegan Sun", route: "108"), "Mohegan Sun")
        XCTAssertEqual(NJBusBuilder.headsign("Route 1 Plaza", route: "1"), "Route 1 Plaza")
        XCTAssertEqual(NJBusBuilder.headsign("1500 Broadway", route: "X"), "1500 Broadway")
        XCTAssertEqual(NJBusBuilder.headsign("Halesite to Huntington LIRR", route: "H20", longName: "Halesite to Huntington LIRR"),
                       "Huntington LIRR")
        XCTAssertEqual(NJBusBuilder.headsign("Coastal Link", route: "8", longName: "Coastal Link"), "Coastal Link")
        XCTAssertTrue(NJBusBuilder.hasYear("KS_2025"))
        XCTAssertTrue(NJBusBuilder.hasYear("2025 X"))
        XCTAssertFalse(NJBusBuilder.hasYear("Route 1985"))
        XCTAssertFalse(NJBusBuilder.hasYear("Stop 20251"))
        XCTAssertFalse(NJBusBuilder.hasYear("Washington"))
        XCTAssertEqual(NJBusBuilder.stopName("415 Killingworth Rd, Haddam, CT, USA"), "415 Killingworth Rd, Haddam")
        XCTAssertEqual(NJBusBuilder.stopName("Salem Tpk & Briar Ln (CTDOT)"), "Salem Tpk & Briar Ln")
        XCTAssertEqual(NJBusBuilder.stopName("GRASSO GARDENS (CTDOT)"), "Grasso Gardens")
        XCTAssertEqual(NJBusBuilder.stopName("Main St, Middletown"), "Main St, Middletown")
    }

    /// Data like Ulster's: one route per direction ("KS-NB", "KS-SB") with direction_id 1 on both, an older copy of a route spelled
    /// differently ("Blue" beside "BLUE"), "Route" in a short name, headsigns that are timetables' names or the route's own name
    private var ulsterFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            3847,72,KS-NB,"KS: Kingston - Mall - Saugerties",3
            4066,72,KS-SB,"KS: Saugerties - Mall - Kingston",3
            12249,72,BLUE,BLUE,3
            11936,72,Blue,"Blue: Kingston Plaza to Riverfront",3
            12251,72,YELLOW,YELLOW,3
            12949,72,Route 7,Route 7,3
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            K1,Kingston Plaza,41.9290,-73.9970
            K2,Ulster Mall,41.9590,-73.9890
            K3,Saugerties Price Chopper,42.0770,-73.9530
            K4,Riverfront,41.9190,-73.9850
            K5,Port Ewen,41.9050,-73.9790
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            3847,WK,N1,KS_2025,1
            4066,WK,S1,KS_2025,1
            12249,WK,B1,Blue Regular 2025,0
            11936,WK,B2,Riverfront,0
            12251,WK,Y1,Yellow Route,0
            12949,WK,R7,Route 7,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            N1,12:10:00,12:10:00,K1,1
            N1,12:20:00,12:20:00,K2,2
            N1,12:40:00,12:40:00,K3,3
            S1,12:05:00,12:05:00,K3,1
            S1,12:25:00,12:25:00,K2,2
            S1,12:35:00,12:35:00,K1,3
            B1,12:30:00,12:30:00,K1,1
            B1,12:40:00,12:40:00,K4,2
            B2,13:30:00,13:30:00,K1,1
            B2,13:40:00,13:40:00,K4,2
            Y1,12:20:00,12:20:00,K1,1
            Y1,12:35:00,12:35:00,K5,2
            R7,12:25:00,12:25:00,K1,1
            R7,12:50:00,12:50:00,K2,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
    }

    func testRoutesSplitByDirection() throws {
        let ucat = try XCTUnwrap(RegionalBusFeed.feed(code: "UCAT"))
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: ulsterFiles, now: now, feed: ucat), feed: ucat)
        // KS-NB and KS-SB are one route; BLUE and Blue too (the first one's spelling); "Route 7" is route 7
        XCTAssertEqual(Set(index.routeNames), ["KS", "BLUE", "YELLOW", "7"])
        XCTAssertEqual(index.routeNames.count, 4)
        // The direction comes from the route's name, not direction_id
        let mall = index.slice(near: Coordinate(latitude: 41.9590, longitude: -73.9890), radiusMeters: 300)
        XCTAssertEqual(mall.trips.first { $0.id == "njb:UCAT/N1" }?.direction, "N")
        XCTAssertEqual(mall.trips.first { $0.id == "njb:UCAT/S1" }?.direction, "S")
        // Route 7 ends at the mall, so it can't be boarded there
        XCTAssertEqual(Set(mall.routes.map(\.id)), ["NJB-UCAT/KS"])
        let mallID = try XCTUnwrap(mall.piers.first { $0.name == "Ulster Mall" }?.id)
        let atMall = mall.arrivals(pierIDs: [mallID], from: now, to: now.addingTimeInterval(3600), realtime: [], now: now)
        XCTAssertEqual(Set(atMall.map { "\($0.direction.code) \($0.direction.terminal ?? "")" }),
                       ["N Saugerties Price Chopper", "S Kingston Plaza"])
        // No "To KS_2025", "To Yellow Route" or "To Route 7": the terminal instead; a real destination stays
        let plaza = index.slice(near: Coordinate(latitude: 41.9290, longitude: -73.9970), radiusMeters: 300)
        let plazaID = try XCTUnwrap(plaza.piers.first { $0.name == "Kingston Plaza" }?.id)
        let atPlaza = plaza.arrivals(pierIDs: [plazaID], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(Set(atPlaza.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" }),
                       ["KS Saugerties Price Chopper", "BLUE Riverfront", "YELLOW Port Ewen", "7 Ulster Mall"])
        XCTAssertFalse(atPlaza.contains { ($0.direction.terminal ?? "").contains("2025") || ($0.direction.terminal ?? "").contains("Route") })
        // One map line per route
        XCTAssertEqual(index.map()?.routes.map(\.route).sorted(), ["NJB-UCAT/7", "NJB-UCAT/BLUE", "NJB-UCAT/KS", "NJB-UCAT/YELLOW"])
        XCTAssertTrue(index.map()?.routes.allSatisfy { $0.lines.count == 1 } ?? false)
    }

    /// Data like Sullivan's: no headsigns and no direction_id, and the same short name ("S") for two shuttles in different towns
    private var sullivanFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            vb9b,SCT,S,Liberty Shuttle,3
            dnf9,SCT,S,Monticello Shuttle,3
            A,SCT_MS,A,Route A,3
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            L1,Liberty Walmart,41.8010,-74.7460
            L2,Liberty Main St,41.7980,-74.7470
            M1,Monticello Walmart,41.6560,-74.6900
            M2,Monticello Government Center,41.6530,-74.6880
            W1,Wurtsboro,41.5770,-74.4870
            """),
            "trips.txt": d("""
            trip_id,route_id,service_id,trip_headsign,trip_short_name,direction_id
            LS1,vb9b,WK,,,
            MS1,dnf9,WK,,,
            MS2,dnf9,WK,,,
            A1,A,WK,,,
            A2,A,WK,,,
            A3,A,WK,,,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            LS1,12:10:00,12:10:00,L1,1
            LS1,12:20:00,12:20:00,L2,2
            MS1,12:10:00,12:10:00,M1,1
            MS1,12:20:00,12:20:00,M2,2
            MS2,13:10:00,13:10:00,M1,1
            MS2,13:20:00,13:20:00,M2,2
            A1,12:00:00,12:00:00,L1,1
            A1,12:30:00,12:30:00,M1,2
            A1,13:00:00,13:00:00,W1,3
            A2,12:10:00,12:10:00,W1,1
            A2,12:40:00,12:40:00,M1,2
            A2,13:10:00,13:10:00,L1,3
            A3,12:45:00,12:45:00,M1,1
            A3,13:15:00,13:15:00,W1,2
            A3,13:45:00,13:45:00,M1,3
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
    }

    func testNoDirectionsOrHeadsigns() throws {
        let sul = try XCTUnwrap(RegionalBusFeed.feed(code: "SUL"))
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: sullivanFiles, now: now, feed: sul), feed: sul)
        XCTAssertEqual(Set(index.routeNames), ["S", "A"])
        // Toward Manhattan is "N" (Liberty → Wurtsboro), away from it "S"; a loop stays "N"
        let monticello = index.slice(near: Coordinate(latitude: 41.6560, longitude: -74.6900), radiusMeters: 300)
        XCTAssertEqual(monticello.trips.first { $0.id == "njb:SUL/A1" }?.direction, "N")
        XCTAssertEqual(monticello.trips.first { $0.id == "njb:SUL/A2" }?.direction, "S")
        XCTAssertEqual(monticello.trips.first { $0.id == "njb:SUL/A3" }?.direction, "N")
        // Without headsigns every trip still has a destination: its terminal; A3, a loop from Monticello Walmart out to Wurtsboro
        // and back, says the stop where it turns back when it leaves Monticello Walmart (not Monticello Walmart itself)
        let walmart = try XCTUnwrap(monticello.piers.first { $0.name == "Monticello Walmart" }?.id)
        let arrivals = monticello.arrivals(pierIDs: [walmart], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(Set(arrivals.map { $0.direction.terminal ?? "" }), ["Monticello Government Center", "Wurtsboro", "Liberty Walmart"])
        XCTAssertEqual(arrivals.first { $0.id.hasPrefix("njb:SUL/A3|") }?.direction.terminal, "Wurtsboro")
        // The two shuttles called "S" are one route, drawn where each one runs: two lines that don't touch
        let map = try XCTUnwrap(index.map())
        let s = try XCTUnwrap(map.routes.first { $0.route == "NJB-SUL/S" })
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(map.routes.first { $0.route == "NJB-SUL/A" }?.lines.count, 1)
        let lats = s.lines.map { $0.map { $0[0] } }
        XCTAssertTrue(lats.contains { $0.allSatisfy { $0 > 41.75 } } && lats.contains { $0.allSatisfy { $0 < 41.70 } })
    }

    /// Loops like FRTA's from JWO Transit Center: L1 has no headsign, L2's names its first stop, L3's names somewhere else, L4 ends
    /// at another stop of the same name (another bay); T1 isn't a loop. The loops leave JWO and run out past Main St to Turners
    /// Falls (the farthest stop) and back
    private var loopFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,route_short_name,route_long_name,route_type
            20,20,Route 20,3
            21,21,Route 21,3
            31,31,Route 31,3
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            J,JWO Transit Center,42.5880,-72.6000
            J2,JWO TRANSIT CENTER,42.5881,-72.6002
            M,Main St,42.5900,-72.5800
            T,Turners Falls,42.6050,-72.5550
            C,Greenfield Community College,42.5950,-72.6250
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            20,WK,L1,,0
            21,WK,L2,JWO Transit Center,1
            21,WK,L3,Greenfield Community College,1
            20,WK,L4,,0
            31,WK,T1,,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            L1,12:15:00,12:15:00,J,1
            L1,12:20:00,12:20:00,M,2
            L1,12:30:00,12:30:00,T,3
            L1,12:45:00,12:45:00,J,4
            L2,12:25:00,12:25:00,J,1
            L2,12:35:00,12:35:00,T,2
            L2,12:45:00,12:45:00,M,3
            L2,12:55:00,12:55:00,J,4
            L3,12:35:00,12:35:00,J,1
            L3,12:40:00,12:40:00,M,2
            L3,12:50:00,12:50:00,T,3
            L3,13:05:00,13:05:00,J,4
            L4,13:15:00,13:15:00,J,1
            L4,13:25:00,13:25:00,T,2
            L4,13:40:00,13:40:00,J2,3
            T1,12:40:00,12:40:00,J,1
            T1,12:50:00,12:50:00,C,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
    }

    /// Leaving the first stop of a loop, the destination is where the bus turns back (its stop farthest from there), not the first
    /// stop itself; the loop's other stops and other trips keep their terminal, and a headsign naming somewhere else stays
    func testLoopsNameWhereTheyTurnBack() throws {
        let frta = try XCTUnwrap(RegionalBusFeed.feed(code: "FRTA"))
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: loopFiles, now: now, feed: frta), feed: frta)
        let jwo = Coordinate(latitude: 42.5880, longitude: -72.6000)
        let feed = index.slice(near: jwo, radiusMeters: 300)
        let pier = frta.idPrefix + "J"
        XCTAssertTrue(feed.piers.contains { $0.id == pier })
        let arrivals = feed.arrivals(pierIDs: [pier], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        func terminal(_ trip: String) -> String? { arrivals.first { $0.id.hasPrefix(frta.idPrefix + trip + "|") }?.direction.terminal }
        XCTAssertEqual(terminal("L1"), "Turners Falls")
        XCTAssertEqual(terminal("L2"), "Turners Falls", "A headsign naming the first stop itself says no more than no headsign")
        XCTAssertEqual(terminal("L3"), "Greenfield Community College")
        XCTAssertEqual(terminal("L4"), "Turners Falls")
        XCTAssertEqual(terminal("T1"), "Greenfield Community College")
        // At Main St, partway round, the loop still goes back to JWO Transit Center
        let main = index.slice(near: Coordinate(latitude: 42.5900, longitude: -72.5800), radiusMeters: 300)
        let mainPier = try XCTUnwrap(main.piers.first { $0.name == "Main St" }?.id)
        let atMain = main.arrivals(pierIDs: [mainPier], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(atMain.first { $0.id.hasPrefix(frta.idPrefix + "L1|") }?.direction.terminal, "JWO Transit Center")
        XCTAssertEqual(atMain.first { $0.id.hasPrefix(frta.idPrefix + "L2|") }?.direction.terminal, "JWO Transit Center")
    }

    /// Norwalk's and River Valley's headsigns name the route; River Valley has routes without a short name and notes in stop names;
    /// SEAT marks the state's stops
    private var connecticutFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            8,10057,8,Coastal Link,3
            76876,4964,,581-582 Saybrook Rd/Wesleyan Hills,3
            16490,4964,,Clinton Trolley,3
            99,4964,,,3
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            C1,Norwalk Pulse Point,41.1170,-73.4140
            C2,"Westport Station, CT, USA",41.1190,-73.3720
            C3,Milford Transit Center (CTDOT),41.2230,-73.0570
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            8,WK,T1,Coastal Link,0
            76876,WK,T2,,0
            16490,WK,T3,,1
            99,WK,T4,Westport,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            T1,12:10:00,12:10:00,C1,1
            T1,12:20:00,12:20:00,C2,2
            T1,12:50:00,12:50:00,C3,3
            T2,12:15:00,12:15:00,C1,1
            T2,12:30:00,12:30:00,C2,2
            T3,12:30:00,12:30:00,C1,1
            T3,12:40:00,12:40:00,C2,2
            T4,12:40:00,12:40:00,C1,1
            T4,12:55:00,12:55:00,C2,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
    }

    func testHeadsignsThatNameRoutesAndRoutesWithoutShortNames() throws {
        let ntd = try XCTUnwrap(RegionalBusFeed.feed(code: "NTD"))
        XCTAssertTrue(ntd.headsignsNameRoutes)
        XCTAssertEqual(RegionalBusFeed.all.filter(\.headsignsNameRoutes).map(\.code), ["NTD", "RVT", "ACAD", "ATLC", "SJTA"])
        let c = Coordinate(latitude: 41.1170, longitude: -73.4140)
        func terminals(_ feed: RegionalBusFeed) throws -> Set<String> {
            let index = try NJBusIndex(data: try NJBusBuilder.build(files: connecticutFiles, now: now, feed: feed), feed: feed)
            let slice = index.slice(near: c, radiusMeters: 300)
            let pier = try XCTUnwrap(slice.piers.first { $0.name == "Norwalk Pulse Point" }?.id)
            let arrivals = slice.arrivals(pierIDs: [pier], from: now, to: now.addingTimeInterval(3600), realtime: [], now: now)
            return Set(arrivals.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" })
        }
        // Norwalk and River Valley: the terminal instead of "Coastal Link" (and for every other headsign too)
        let rvt = try XCTUnwrap(RegionalBusFeed.feed(code: "RVT"))
        for feed in [ntd, rvt] {
            XCTAssertEqual(try terminals(feed), ["8 Milford Transit Center", "581-582 Westport Station", "Clinton Trolley Westport Station",
                                                 "99 Westport Station"], feed.code)
        }
        // Elsewhere headsigns stay; a route with no names at all keeps its route_id
        let seat = try XCTUnwrap(RegionalBusFeed.feed(code: "SEAT"))
        XCTAssertFalse(seat.headsignsNameRoutes)
        XCTAssertEqual(try terminals(seat), ["8 Coastal Link", "581-582 Westport Station", "Clinton Trolley Westport Station", "99 Westport"])
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: connecticutFiles, now: now, feed: seat), feed: seat)
        XCTAssertEqual(Set(index.stopNames), ["Norwalk Pulse Point", "Westport Station", "Milford Transit Center"])
    }

    /// PHLASH's data has no short route names and its long names start with "PHLASH": the badge leaves that out. Only PHLASH,
    /// BurLINK (whose badges are then the codes, "B1") and MWRTA (short names "RT206") do that; others keep the long name as it is
    func testRouteNamePrefix() throws {
        let phlash = try XCTUnwrap(RegionalBusFeed.feed(code: "PHLASH"))
        XCTAssertEqual(RegionalBusFeed.all.filter { $0.routeNamePrefix != nil }.map(\.code), ["PHLASH", "BURL", "MWRTA"])
        XCTAssertNil(phlash.downloadArea)
        XCTAssertFalse(phlash.hasRealtime)
        var files = connecticutFiles
        files["routes.txt"] = d("""
        route_id,agency_id,route_short_name,route_long_name,route_type
        8,10057,8,Coastal Link,3
        76876,4964,,581-582 Saybrook Rd/Wesleyan Hills,3
        16490,4964,,PHLASH Clinton Trolley,3
        99,4964,,PHLASH,3
        """)
        let seat = try XCTUnwrap(RegionalBusFeed.feed(code: "SEAT"))
        func badges(_ feed: RegionalBusFeed) throws -> Set<String> {
            let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: feed), feed: feed)
            return Set(index.routeNames)
        }
        // A long name that is only the prefix stays as it is
        XCTAssertEqual(try badges(phlash), ["8", "581-582", "Clinton Trolley", "PHLASH"])
        XCTAssertEqual(try badges(seat), ["8", "581-582", "PHLASH Clinton Trolley", "PHLASH"])
    }

    /// NECTD's and NWCTD's lines are known by their colors: each badge and each line on the map has its line's color, and the
    /// badge's text is whichever of black and white reads better on it. Everything else is as before
    func testLinesWithColorsOfTheirOwn() throws {
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-NECTD/Orange"), "F5A623")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-NECTD/Red-Purple"), "DD3355")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-NWCTD/Sat"), "034107")
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-NWCTD/Job Access"), "2FD0E4")
        // A line that isn't listed (a new one): the operator's color, with white text
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-NECTD/Silver"), "417505")
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-NECTD/Silver"))
        // Operators without colors for their lines, and what isn't a regional bus
        XCTAssertEqual(RegionalBusFeed.color(route: "NJB-BXL/1"), "0080C0")
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-BXL/1"))
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-107"))
        XCTAssertFalse(RegionalBusFeed.darkText(route: "LIRR-BAB"))
        // Yellow, orange and the light green take dark text; the dark greens take white
        XCTAssertTrue(RegionalBusFeed.darkText(route: "NJB-NECTD/Weekender"))
        XCTAssertTrue(RegionalBusFeed.darkText(route: "NJB-NECTD/Orange"))
        XCTAssertTrue(RegionalBusFeed.darkText(route: "NJB-NWCTD/3"))
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-NECTD/Green"))
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-NWCTD/5"))
        XCTAssertFalse(RegionalBusFeed.darkText(route: "NJB-NWCTD/Sat"))
        var withColors: [String] = []
        for feed in RegionalBusFeed.all where !feed.lineColors.isEmpty {
            withColors.append(feed.code)
            for (badge, hex) in feed.lineColors {
                let route = "NJB-\(feed.code)/\(badge)"
                let color = try XCTUnwrap(UInt32(hex, radix: 16), route)
                XCTAssertEqual(hex.count, 6, route)
                XCTAssertEqual(hex, hex.uppercased(), route)
                XCTAssertEqual(RegionalBusFeed.color(route: route), hex)
                XCTAssertGreaterThanOrEqual(ColorVision.contrast(color, RegionalBusFeed.darkText(route: route) ? 0x000000 : 0xFFFFFF), 4.5, route)
            }
            // A company already in the app before its lines had colors: the map inside its stored file is drawn again, with them
            if ["NECTD", "NWCTD", "WRTD"].contains(feed.code) { XCTAssertGreaterThanOrEqual(feed.readingVersion, 1, feed.code) }
        }
        XCTAssertEqual(withColors.sorted(), ["HUNT", "NECTD", "NWCTD", "OWL", "SLH", "SUSX", "WRTD"])
        // How many lines each has colors for: WRTD all but the two whose routes have different colors in the data (674D, 674E),
        // ShortLine Hudson's two Eastside lines one badge
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: withColors.map { ($0, RegionalBusFeed.feed(code: $0)?.lineColors.count ?? 0) }),
                       ["NECTD": 5, "NWCTD": 6, "WRTD": 18, "SLH": 14, "OWL": 1, "HUNT": 8, "SUSX": 2])

        // From a package to what is shown: the departures' routes and the map's lines
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: "NECTD"))
        let ids = ["GREEN", "ORANGE", "PURPLE-RED", "SILVER"]
        let files: [String: Data] = [
            "routes.txt": d("route_id,route_short_name,route_long_name,route_type\nGREEN,Green,,3\nORANGE,Orange,,3\nPURPLE-RED,Red-Purple Shuttle,,3\nSILVER,Silver,,3"),
            "stops.txt": d("stop_id,stop_name,stop_lat,stop_lon\nH1,Hyannis Transportation Center,41.6590,-70.2790\nH2,Cape Cod Mall,41.6740,-70.3020"),
            "trips.txt": d((["route_id,service_id,trip_id,trip_headsign,direction_id"] + ids.enumerated().map { "\($1),WK,T\($0),,0" }).joined(separator: "\n")),
            "stop_times.txt": d((["trip_id,arrival_time,departure_time,stop_id,stop_sequence"]
                                 + ids.indices.flatMap { ["T\($0),12:10:00,12:10:00,H1,1", "T\($0),12:40:00,12:40:00,H2,2"] }).joined(separator: "\n")),
            "calendar.txt": d("service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWK,1,1,1,1,1,0,0,20260901,20261231"),
        ]
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: feed), feed: feed)
        let expected = ["NJB-NECTD/Green": "417505", "NJB-NECTD/Orange": "F5A623", "NJB-NECTD/Red-Purple": "DD3355", "NJB-NECTD/Silver": "417505"]
        let slice = index.slice(near: Coordinate(latitude: 41.6590, longitude: -70.2790), radiusMeters: 300)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: slice.routes.map { ($0.id, $0.color) }), expected)
        let map = try XCTUnwrap(index.map())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: map.routes.map { ($0.route, $0.color) }), expected)
    }

    /// Two stops in Hyannis, every route from one to the other at 12:10: the routes' badges, and each one's badge and terminal there
    private func build(_ code: String, routes: String, headsigns: [String: String]) throws -> (badges: Set<String>, terminals: Set<String>) {
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code))
        let ids = routes.split(separator: "\n").dropFirst().map { String($0.split(separator: ",", omittingEmptySubsequences: false)[0]) }
        let trips = ids.enumerated().map { "\($1),WK,T\($0),\(headsigns[$1] ?? ""),0" }
        let times = ids.indices.flatMap { ["T\($0),12:10:00,12:10:00,H1,1", "T\($0),12:40:00,12:40:00,H2,2"] }
        let files: [String: Data] = [
            "routes.txt": d(routes),
            "stops.txt": d("stop_id,stop_name,stop_lat,stop_lon\nH1,Hyannis Transportation Center,41.6590,-70.2790\nH2,Cape Cod Mall,41.6740,-70.3020"),
            "trips.txt": d((["route_id,service_id,trip_id,trip_headsign,direction_id"] + trips).joined(separator: "\n")),
            "stop_times.txt": d((["trip_id,arrival_time,departure_time,stop_id,stop_sequence"] + times).joined(separator: "\n")),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: feed), feed: feed)
        let slice = index.slice(near: Coordinate(latitude: 41.6590, longitude: -70.2790), radiusMeters: 300)
        let arrivals = slice.arrivals(pierIDs: slice.piers.map(\.id), from: now, to: now.addingTimeInterval(3600), realtime: [], now: now)
        return (Set(index.routeNames), Set(arrivals.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" }))
    }

    /// The bus operators around Boston: after the MBTA, each in its own box; free live data from WRTA, LRTA, GATRA, BAT and COAST.
    /// Badges from routes with no short name (Cape Cod's, Montachusett's shuttles, Manchester's) or a name for one (MeVa's 30,
    /// MWRTA's "RT206"); a headsign that starts with the badge's word keeps it ("Patriot Square" on the Patriot)
    func testGreaterBostonCompanies() throws {
        let codes = ["RIPTA", "WRTA", "LRTA", "GATRA", "SRTA", "BAT", "CCRTA", "MART", "MEVA", "CATA", "MWRTA", "LOGAN", "MANCH", "NTS",
                     "COAST", "VTA", "NRTA"]
        // After them, Greater Hartford's and Western Massachusetts' six (see testHartfordAndWesternMassachusettsCompanies)
        XCTAssertEqual(Array(RegionalBusFeed.all.map(\.code).drop { $0 != RegionalBusFeed.mbtaCode }.dropFirst()), codes + Self.hartfordAndWesternMassachusetts)
        for code in codes {
            let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code), code)
            XCTAssertNotNil(feed.downloadArea, code)
            XCTAssertFalse(feed.needsAccount || feed.needsKey, code)
            XCTAssertEqual(feed.hasRealtime, ["WRTA", "LRTA", "GATRA", "BAT", "COAST"].contains(code), code)
            XCTAssertEqual(feed.builtInURL.scheme, "https", code)
            if let live = feed.builtInRealtimeURL { XCTAssertEqual(live.scheme, "https", code) }
        }
        XCTAssertEqual(RegionalBusFeed.feed(code: "LOGAN")?.name, "Massport")
        XCTAssertEqual(RegionalBusFeed.feed(code: "VTA")?.name, "VTA")
        XCTAssertEqual(RegionalBusFeed.feed(code: "NRTA")?.name, "The WAVE")
        // RIPTA's file at an address that answers it directly: its old one sends the app on to an http address, which macOS
        // doesn't let the app follow
        XCTAssertEqual(RegionalBusFeed.feed(code: "RIPTA")?.builtInURL.absoluteString, "https://ripta.com/system/files/gtfs_file/RIPTA-GTFS.zip")
        let cape = try build("CCRTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            2976,,Sealine Hyannis-Falmouth/Woods Hole,3
            14475,,Patriot LTD,3
            2982,,Provincetown/North Truro Shuttle,3
            """, headsigns: ["2976": "Woods Hole", "14475": "Patriot Square"])
        XCTAssertEqual(cape.badges, ["Sealine", "Patriot", "Shuttle"])
        XCTAssertEqual(cape.terminals, ["Sealine Woods Hole", "Patriot Patriot Square", "Shuttle Cape Cod Mall"])
        let mart = try build("MART", routes: """
            route_id,route_short_name,route_long_name,route_type
            2721,1,Fitchburg/Leominster/Lunenburg,3
            3235,,Athol/Orange Shuttle ,3
            2732,,Gardner Route 1,3
            """, headsigns: ["2732": "(Loop)"])
        XCTAssertEqual(mart.badges, ["1", "Athol", "G1"])
        XCTAssertEqual(mart.terminals, ["1 Cape Cod Mall", "Athol Cape Cod Mall", "G1 Cape Cod Mall"])
        let meva = try build("MEVA", routes: """
            route_id,route_short_name,route_long_name,route_type
            6162,16,16 - Washington Street/Westgate Plaza,3
            7070,Amesbury Town Park,30 Amesbury Town Park,3
            """, headsigns: ["7070": "Amesbury Town Park"])
        XCTAssertEqual(meva.badges, ["16", "30"])
        XCTAssertEqual(meva.terminals, ["16 Cape Cod Mall", "30 Amesbury Town Park"])
        let mwrta = try build("MWRTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            r206,RT206,Route 206,3
            r495,495C,495 Connector,3
            """, headsigns: [:])
        XCTAssertEqual(mwrta.badges, ["206", "495C"])
        let manchester = try build("MANCH", routes: """
            route_id,route_short_name,route_long_name,route_type
            1,,1 Dartmouth/VA Hospital,3
            2S,,2S Hanover St/East Side Plaza SAT,3
            SSS,,Salem Shopper Shuttle,3
            """, headsigns: [:])
        XCTAssertEqual(manchester.badges, ["1", "2S", "Shopper"])
        let coast = try build("COAST", routes: """
            route_id,route_short_name,route_long_name,route_type
            3790,12,12 Rochester / Somersworth / Dover,3
            3796,41,41 Lafayette Trolley,3
            """, headsigns: ["3790": "12N Rochester via 108", "3796": "41 Lafayette Trolley Outbound"])
        XCTAssertEqual(coast.terminals, ["12 Rochester", "41 Lafayette Trolley"])
        // Martha's Vineyard's buses have their numbers; Nantucket's have names only, shortened to the part that tells them apart
        // (three go to Sconset, by different roads)
        let vineyard = try build("VTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            2799,1,Edgartown - Vineyard Haven Road,3
            2809,10A,West Chop Loop,3
            """, headsigns: [:])
        XCTAssertEqual(vineyard.badges, ["1", "10A"])
        let nantucket = try build("NRTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            2884,,Madaket Route,3
            2887,,Sconset via Milestone Road Route,3
            2888,,Sconset via Old South Road Route,3
            2889,,Sconset via Polpis Road Route,3
            6277,,Airport,3
            2883,,Jetties Beach Route,3
            2885,,Miacomet Loop,3
            2886,,Mid Island Loop,3
            """, headsigns: [:])
        XCTAssertEqual(nantucket.badges, ["Madaket", "Milestone", "Old South", "Polpis", "Airport", "Jetties", "Miacomet", "Mid Island"])
    }

    static let hartfordAndWesternMassachusetts = ["PVTA", "FRTA", "BRTA", "NECTD", "WRTD", "NWCTD"]

    /// Greater Hartford's and Western Massachusetts' bus operators: the last six, each in its own box; free live data from PVTA
    /// (its own server), FRTA and WRTD (Passio's; FRTA's timetable from Trillium). Badges for the routes without a short name
    /// (NWCTD's Saturday route and its Job Access bus; WRTD's campus routes, whose long names end with the term) or with a whole
    /// name for one (NECTD's shuttle). The Link413's 904 is in PVTA's data and BRTA's: only BRTA's is kept
    func testHartfordAndWesternMassachusettsCompanies() throws {
        let codes = Self.hartfordAndWesternMassachusetts
        XCTAssertEqual(RegionalBusFeed.builtIn.suffix(6).map(\.code), codes)
        for code in codes {
            let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code), code)
            XCTAssertEqual(feed.name, code)
            XCTAssertNotNil(feed.downloadArea, code)
            XCTAssertFalse(feed.needsAccount || feed.needsKey || feed.onlyServiceArea, code)
            XCTAssertEqual(feed.hasRealtime, ["PVTA", "FRTA", "WRTD"].contains(code), code)
            XCTAssertEqual(feed.builtInURL.scheme, "https", code)
            if let live = feed.builtInRealtimeURL { XCTAssertEqual(live.scheme, "https", code) }
            // Read again: PVTA's trips by block and without its 904, FRTA's from Passio's timetable and then Trillium's again,
            // WRTD's new badges and then its lines in their own colors, NECTD's and NWCTD's lines in their own colors on the map
            XCTAssertEqual(feed.readingVersion, ["PVTA": 1, "FRTA": 2, "WRTD": 2, "NECTD": 1, "NWCTD": 1][code] ?? 0, code)
            // White text can be read on its color
            XCTAssertGreaterThanOrEqual(contrastWithWhite(feed.color), 4.5, code)
        }
        XCTAssertEqual(Set(codes.compactMap { RegionalBusFeed.feed(code: $0)?.downloadArea }).count, 6)
        // Passio's server has FRTA's and WRTD's live data with Cecil Transit's, BAT's and COAST's; PVTA's is on its own
        XCTAssertEqual(RegionalBusFeed.passioFeeds.map(\.code), ["CECIL", "BAT", "COAST", "FRTA", "WRTD"])
        XCTAssertEqual(RegionalBusFeed.passioProvider, "Cecil Transit / BAT / COAST / FRTA / WRTD")
        XCTAssertEqual(RegionalBusFeed.feed(code: "PVTA")?.builtInRealtimeURL?.host, "bustracker.pvta.com")
        // FRTA's timetable is Trillium's copy, whose stops its live data on Passio's server names; its live trips go by stops and
        // time, as its live data's trip IDs are in no copy (only FRTA's do)
        let frta = try XCTUnwrap(RegionalBusFeed.feed(code: "FRTA"))
        XCTAssertEqual(frta.builtInURL.absoluteString, "https://data.trilliumtransit.com/gtfs/frta-ma-us/frta-ma-us.zip")
        XCTAssertEqual(frta.builtInRealtimeURL?.host, "passio3.com")
        XCTAssertEqual(RegionalBusFeed.builtIn.filter(\.liveByStopsAndTime).map(\.code), ["FRTA"])
        // The two published through one host have their own packages
        XCTAssertEqual(RegionalBusFeed.feed(code: "NECTD")?.builtInURL.absoluteString, "https://hosted-gtfs-feeds.s3.amazonaws.com/NECTD/gtfs.zip")
        XCTAssertEqual(RegionalBusFeed.feed(code: "NWCTD")?.builtInURL.absoluteString, "https://hosted-gtfs-feeds.s3.amazonaws.com/NWCTD/gtfs.zip")
        // Every company has a package of its own but Coach USA's six, which share one
        let shared = Dictionary(grouping: RegionalBusFeed.builtIn, by: \.builtInURL).values.filter { $0.count > 1 }
        XCTAssertEqual(shared.map { $0.map(\.code) }, [["SLH", "SUBT", "ROCK", "COMC", "NAE", "OWL"]])
        // NECTD's routes go by colors, in their short names; the shuttle's whole name is there too
        let nectd = try build("NECTD", routes: """
            route_id,route_short_name,route_long_name,route_type
            BLUE,Blue,,3
            GREEN,Green,,3
            WEEKENDER,Weekender,,3
            PURPLE-RED,Red-Purple Shuttle,,3
            """, headsigns: ["BLUE": "Putnam"])
        XCTAssertEqual(nectd.badges, ["Blue", "Green", "Weekender", "Red-Purple"])
        XCTAssertEqual(nectd.terminals, ["Blue Putnam", "Green Cape Cod Mall", "Weekender Cape Cod Mall", "Red-Purple Cape Cod Mall"])
        // NWCTD's numbered routes keep their numbers; the two without one get a short word each
        let nwctd = try build("NWCTD", routes: """
            route_id,route_short_name,route_long_name,route_type
            1B,1B,Winsted (College Only),3
            5,5,Torrington: Westside to Southend,3
            SaturdayTorrington,,Saturday Torrington,3
            Job Access,,Job Access AM/PM,3
            """, headsigns: [:])
        XCTAssertEqual(nwctd.badges, ["1B", "5", "Sat", "Job Access"])
        // The others' routes all have short names of their own (PVTA's "B79", "P21E", FRTA's "32", BRTA's "5A" and the Link413's "904")
        let pvta = try build("PVTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            B79,B79,Amherst-Worcester Intercity Service,3
            921,P21E,Holyoke-Springfield Express via I-391,3
            B9,WSU,WSU Shuttle,3
            904,904,Pittsfield / Northampton,3
            """, headsigns: [:])
        XCTAssertEqual(pvta.badges, ["B79", "P21E", "WSU"])
        XCTAssertEqual(RegionalBusFeed.feed(code: "PVTA")?.leftOutRoutes, ["904"])
        XCTAssertTrue(RegionalBusFeed.builtIn.filter { $0.code != "PVTA" }.allSatisfy { $0.leftOutRoutes.isEmpty })
        let brta = try build("BRTA", routes: """
            route_id,route_short_name,route_long_name,route_type
            5A,5A,"Pittsfield, Lanesborough",3
            904,904,Pittsfield  / Northampton,3
            """, headsigns: [:])
        XCTAssertEqual(brta.badges, ["5A", "904"])
        // WRTD's campus routes without short names, this term's and the next's; the rest keep their short names, and a name
        // that only starts the same way without a space after it isn't one of them
        let wrtd = try build("WRTD", routes: """
            route_id,route_short_name,route_long_name,route_type
            56565,,Purple A Fall 2026,3
            56566,,Purple B Spring 2027,3
            74428,,Yellow Line A Counter Clockwise Fall 2026,3
            74420,,Yellow Line B Clockwise Spring 2027,3
            71994,Blue A,Blue Line - A Fall 2026,3
            61000,674A,NEW 674 A Willimantic - Storrs,3
            99999,,Purple Alpha,3
            """, headsigns: [:])
        XCTAssertEqual(wrtd.badges, ["Purple A", "Purple B", "Yellow A", "Yellow B", "Blue A", "674A", "Purple Alpha"])
        let wrtdFeed = try XCTUnwrap(RegionalBusFeed.feed(code: "WRTD"))
        XCTAssertEqual(wrtdFeed.badge(longNameStart: "Yellow Line A"), "Yellow A")
        XCTAssertNil(wrtdFeed.badge(longNameStart: "Yellow Line"))
        XCTAssertEqual(RegionalBusFeed.builtIn.filter { !$0.badgesByLongNameStart.isEmpty }.map(\.code), ["LAKE", "WRTD"])
    }

    func testBuildAndSliceWithPrefix() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let data = try NJBusBuilder.build(files: files, now: now, feed: nice)
        let index = try NJBusIndex(data: data, feed: nice)
        // Platforms (location_type 1) don't count as stations; Dutchess's "A MS" and "A SUN" merge into one A route
        XCTAssertEqual(index.stopCount, 6)
        XCTAssertEqual(Set(index.routeNames), ["n6", "A"])
        let hempstead = Coordinate(latitude: 40.7069, longitude: -73.6171)
        let feed = index.slice(near: hempstead, radiusMeters: 1500)
        XCTAssertEqual(Set(feed.routes.map(\.id)), ["NJB-NICE/n6"])
        XCTAssertEqual(feed.routes.first?.name, "NICE n6")
        XCTAssertEqual(feed.routes.first?.color, nice.color)
        XCTAssertTrue(feed.piers.allSatisfy { $0.id.hasPrefix("njb:NICE/") })
        XCTAssertTrue(feed.trips.allSatisfy { $0.id.hasPrefix("njb:NICE/") && $0.service.hasPrefix("njb:NICE/") })
        XCTAssertEqual(feed.sources, [.njTransitBus])
        let pier = try XCTUnwrap(feed.piers.first { $0.name == "Hempstead Transit Center" }?.id)
        let arrivals = feed.arrivals(pierIDs: [pier], from: now.addingTimeInterval(-30 * 60), to: now.addingTimeInterval(3600),
                                     realtime: [], now: now)
        XCTAssertEqual(Set(arrivals.map { $0.direction.terminal ?? "" }), ["Jamaica", "Hartford"])
        XCTAssertTrue(feed.piers.contains { $0.name == "Fulton St & Franklin Av" })
        XCTAssertEqual(index.map()?.routes.map(\.route).sorted(), ["NJB-NICE/A", "NJB-NICE/n6"])
    }

    /// SEPTA's bus package also has its Metro lines (read with light rail, see FerryFeed.Source.septaMetro): only its buses (3) and
    /// trackless trolleys (11) are kept here, in SEPTA's blue, and stop names lose SEPTA's notes on where the stop is at the corner
    func testSEPTABuses() throws {
        let septa = try XCTUnwrap(RegionalBusFeed.feed(code: RegionalBusFeed.septaCode))
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_url,route_color,route_text_color,route_sort_order,network_id
            L1,SEPTA,L1,Market-Frankford Line,1,,0097D6,FFFFFF,,
            G1,SEPTA,G1,Girard Avenue Trolley,0,,FFD700,000000,,
            17,SEPTA,17,20th-Johnston to Front-Market,3,,FFFFFF,000000,,
            66,SEPTA,66,Frankford-Dyre to Frankford-Knights,11,,,,,
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,wheelchair_boarding,level_id
            416,,69th St Transit Center,39.962338,-75.258555,1,,0,,1,
            2457,,8th-Market,39.951102,-75.153589,1,,0,,1,
            4002,,Girard Av & 40th St - FS,39.973600,-75.202300,1,,0,,1,
            4003,,Richmond St & Westmoreland St,39.984300,-75.100500,1,,0,,1,
            5001,,20th St & Johnston St - FS,39.920100,-75.179800,1,,0,,1,
            5002,,Front St & Market St - MBNS 2,39.949900,-75.142300,1,,0,,1,
            6001,,Frankford Transit Center - 2 NS,40.022929,-75.077861,1,,0,,1,
            6002,,Frankford Av & Knights Rd,40.058000,-74.986000,1,,0,,1,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed
            L1,16,699524,Frankford Transit Center,,0,70002,,1,1
            G1,16,694316,63rd-Girard,,0,9001,,1,2
            17,16,720936,Front-Market,,0,7301,,1,1
            66,16,730001,Frankford-Knights,,0,,,1,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            699524,12:00:00,12:00:00,416,1
            699524,12:17:00,12:17:00,2457,2
            694316,12:00:00,12:00:00,4003,1
            694316,12:20:00,12:20:00,4002,2
            720936,12:20:00,12:20:00,5001,1
            720936,12:50:00,12:50:00,5002,2
            730001,12:10:00,12:10:00,6001,1
            730001,12:40:00,12:40:00,6002,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            16,1,1,1,1,1,0,0,20261005,20270220
            """),
        ]
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: septa), feed: septa)
        XCTAssertEqual(Set(index.routeNames), ["17", "66"])
        XCTAssertEqual(Set(index.tripIDs), ["720936", "730001"])
        // Where only the Metro stops there's no bus stop
        let eighth = index.slice(near: Coordinate(latitude: 39.951102, longitude: -75.153589), radiusMeters: 300)
        XCTAssertTrue(eighth.piers.isEmpty)
        XCTAssertTrue(eighth.trips.isEmpty)
        let south = index.slice(near: Coordinate(latitude: 39.920100, longitude: -75.179800), radiusMeters: 500)
        XCTAssertEqual(Set(south.routes.map(\.id)), ["NJB-SEPTA/17"])
        XCTAssertTrue(south.routes.allSatisfy { $0.color == septa.color })
        XCTAssertEqual(FerryFeed.routeName("NJB-SEPTA/17"), "SEPTA 17")
        XCTAssertEqual(Set(south.piers.map(\.name)), ["20th St & Johnston St", "Front St & Market St"])
        XCTAssertTrue(south.trips.allSatisfy { $0.id.hasPrefix("njb:SEPTA/") })
        let frankford = index.slice(near: Coordinate(latitude: 40.022929, longitude: -75.077861), radiusMeters: 300)
        XCTAssertEqual(Set(frankford.routes.map(\.id)), ["NJB-SEPTA/66"])
        XCTAssertEqual(frankford.piers.first { $0.id == "njb:SEPTA/6001" }?.name, "Frankford Transit Center")
        // Its package is large: downloaded only for places in its area (see DownloadArea), with free live data
        XCTAssertEqual(septa.downloadArea, .philadelphia)
        XCTAssertFalse(septa.needsAccount)
        XCTAssertNotNil(septa.realtimeURL)
        XCTAssertNil(RegionalBusFeed.feed(code: "CTT")?.downloadArea)
        // Its package is SEPTA Metro's too: downloaded once for both. NJ Transit's buses are in both operator lists, but only the
        // buses read their package, and NJ Transit's rail package (trains and light rail) has no buses
        XCTAssertTrue(RegionalBusFeed.isSharedPackage(septa.url))
        XCTAssertEqual(septa.url, FerryFeed.Source.septaMetro.url)
        XCTAssertFalse(RegionalBusFeed.isSharedPackage(RegionalBusFeed.njTransit.url))
        XCTAssertFalse(RegionalBusFeed.isSharedPackage(FerryFeed.Source.njTransitRail.url))
    }

    /// The MBTA's package also has its subway, trains and ferries (each read with its own mode): only its buses are kept here. The
    /// Silver Line keeps its own badges (SL1…); the shuttle buses that replace trains during work on the lines (route_desc "Rail
    /// Replacement Bus", one route each) all say "Shuttle", with the place they go to
    func testMBTABuses() throws {
        let mbta = try XCTUnwrap(RegionalBusFeed.feed(code: RegionalBusFeed.mbtaCode))
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color,route_sort_order,route_fare_class,line_id,listed_route,network_id
            Red,1,,Red Line,Rapid Transit,1,,DA291C,FFFFFF,10010,Rapid Transit,line-Red,,rapid_transit
            CR-Fitchburg,1,,Fitchburg Line,Regional Rail,2,,80276C,FFFFFF,20003,Commuter Rail,line-Fitchburg,,commuter_rail
            741,1,SL1,Logan Airport Terminals - South Station,Frequent Bus,3,,7C878E,FFFFFF,10051,Rapid Transit,line-SLWaterfront,,sl_rapid_transit
            1,1,1,Harvard Square - Nubian Station,Frequent Bus,3,,FFC72C,000000,50010,Local Bus,line-1,,local_bus
            Shuttle-ForgeParkNorwoodCentral,1,Franklin Line Shuttle,Forge Park/495 - Norwood Central,Rail Replacement Bus,3,,FFC72C,000000,61740,Free,line-Franklin,1,rail_replacement_bus
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,platform_code,platform_name,stop_lat,stop_lon,zone_id,stop_address,stop_url,level_id,location_type,parent_station,wheelchair_boarding,municipality,on_street,at_street,vehicle_type
            70061,70061,Alewife,Alewife - Red Line,,Red Line,42.396148,-71.140698,RapidTransit,,,,0,place-alfcl,1,Cambridge,,,1
            BNT-0000,,North Station,North Station - Commuter Rail,,Commuter Rail,42.366417,-71.062326,CR-zone-1A,,,,0,place-north,1,Boston,,,2
            84611,84611,South Station,South Station - Silver Line - Airport,,Airport,42.352271,-71.055242,,,,,0,place-sstat,1,Boston,,,3
            17091,17091,Terminal A,Terminal A - Silver Line - South Station,,South Station,42.364612,-71.020862,,,,,0,,1,Boston,,,3
            110,110,Massachusetts Ave @ Holyoke St,,,,42.372422,-71.115738,,,,,0,,1,Cambridge,,,3
            64000,64000,Nubian,Nubian - Busway,,,42.329544,-71.083982,,,,,0,place-dudly,1,Boston,,,3
            FB-0148-B1,,Norwood Central - Broadway @ Norwood Central Station,,,Commuter Rail Shuttle,42.18874,-71.20004,,,,,0,place-FB-0148,1,Norwood,,,3
            FB-0303-B,,Forge Park/495 - South Parking Lot,,,Commuter Rail Shuttle,42.089825,-71.439075,,,,,0,place-FB-0303,1,Franklin,,,3
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,trip_route_type,route_pattern_id,bikes_allowed
            Red,16,80722172,Ashmont,,0,,,1,,Red-1-0,0
            CR-Fitchburg,16,WRMLCulverts-885467-4515,Wachusett,4515,0,,,1,,CR-Fitchburg-C1-0,1
            741,16,78612827,Logan Airport,,0,,,1,,741-_-0,0
            1,16,79000001,Nubian Station,,0,,,1,,1-_-0,1
            Shuttle-ForgeParkNorwoodCentral,16,CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,Forge Park (Shuttle),B7005,0,,,1,,Shuttle-ForgeParkNorwoodCentral-0-0,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,timepoint,checkpoint_id,continuous_pickup,continuous_drop_off
            80722172,12:18:00,12:18:00,70061,1,,0,1,1,,1,1
            WRMLCulverts-885467-4515,12:40:00,12:40:00,BNT-0000,0,,0,1,1,,1,1
            78612827,12:48:00,12:48:00,84611,1,,0,1,1,,1,1
            78612827,13:06:00,13:06:00,17091,5,,1,0,1,,1,1
            79000001,12:00:00,12:00:00,110,1,,0,1,1,,1,1
            79000001,12:30:00,12:30:00,64000,2,,1,0,1,,1,1
            CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,12:19:00,12:19:00,FB-0148-B1,1,,0,1,1,,1,1
            CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00,13:10:00,13:10:00,FB-0303-B,6,,1,0,1,,1,1
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            16,1,1,1,1,1,0,0,20261005,20270220
            """),
        ]
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: mbta), feed: mbta)
        XCTAssertEqual(Set(index.routeNames), ["SL1", "1", "Shuttle"])
        XCTAssertEqual(Set(index.tripIDs), ["78612827", "79000001", "CR-Fall2026FranklinPhase2-Shuttle-ForgeParkNorwoodCentral-0-08:19:00"])
        // Where only the subway or a train stops there's no bus stop
        XCTAssertTrue(index.slice(near: Coordinate(latitude: 42.396148, longitude: -71.140698), radiusMeters: 300).piers.isEmpty)
        let norwood = index.slice(near: Coordinate(latitude: 42.18874, longitude: -71.20004), radiusMeters: 300)
        XCTAssertEqual(norwood.routes.map { FerryFeed.badge($0.id) }, ["Shuttle"])
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let shuttle = norwood.arrivals(pierIDs: norwood.piers.map(\.id), from: dayStart.addingTimeInterval(11 * 3600),
                                       to: dayStart.addingTimeInterval(14 * 3600), realtime: [], now: now)
        XCTAssertEqual(shuttle.map { $0.direction.terminal ?? "" }, ["Forge Park (Shuttle)"])
        let airport = index.slice(near: Coordinate(latitude: 42.352271, longitude: -71.055242), radiusMeters: 300)
        XCTAssertEqual(airport.routes.map { FerryFeed.badge($0.id) }, ["SL1"])
        // Its package is the subway's, trains' and ferries' too: downloaded once for all four, only for places in Greater Boston
        XCTAssertTrue(RegionalBusFeed.isSharedPackage(mbta.url))
        XCTAssertEqual(Set([FerryFeed.Source.mbtaSubway, .mbtaRail, .mbtaFerry].map(\.url)), [mbta.url])
        XCTAssertEqual(mbta.downloadArea, .greaterBoston)
        XCTAssertFalse(mbta.needsAccount)
        XCTAssertEqual(mbta.realtimeURL, FerryFeed.Source.mbtaSubway.realtimeURL)
    }

    /// CTtransit keeps only stops in the service area: Hartford's are in it (Greater Hartford); a stop beyond the area (here the
    /// same one moved to Albany) is left out
    func testOnlyServiceArea() throws {
        let ctt = try XCTUnwrap(RegionalBusFeed.feed(code: "CTT"))
        XCTAssertTrue(ctt.onlyServiceArea)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: ctt), feed: ctt)
        XCTAssertEqual(index.stopCount, 6)
        XCTAssertTrue(index.stopNames.contains("Hartford Union Station"))
        var beyond = files
        let stops = String(decoding: try XCTUnwrap(files["stops.txt"]), as: UTF8.self)
        XCTAssertTrue(stops.contains("41.7690,-72.6820"))
        beyond["stops.txt"] = Data(stops.replacingOccurrences(of: "41.7690,-72.6820", with: "42.6526,-73.7562").utf8)
        let cut = try NJBusIndex(data: try NJBusBuilder.build(files: beyond, now: now, feed: ctt), feed: ctt)
        XCTAssertEqual(cut.stopCount, 5)
        XCTAssertFalse(cut.stopNames.contains("Hartford Union Station"))
        // A company not cut to the area keeps it
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        XCTAssertEqual(try NJBusIndex(data: try NJBusBuilder.build(files: beyond, now: now, feed: nice), feed: nice).stopCount, 6)
        // Read differently from before, so stored copies are read again once (see RegionalBusFeed.readingVersion)
        XCTAssertEqual(ctt.readingVersion, 1)
    }

    func testCombining() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let a = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: nice), feed: nice)
        let b = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now), feed: .njTransit)
        let c = Coordinate(latitude: 40.7069, longitude: -73.6171)
        let merged = try XCTUnwrap(FerryFeed.combining([a.slice(near: c, radiusMeters: 1500), b.slice(near: c, radiusMeters: 1500)]))
        XCTAssertEqual(Set(merged.routes.map(\.id)), ["NJB-NICE/n6", "NJB-n6"])
        XCTAssertEqual(merged.piers.count, a.slice(near: c, radiusMeters: 1500).piers.count * 2)
        XCTAssertNil(FerryFeed.combining([]))
    }

    // MARK: The Lehigh Valley

    /// Trans-Bridge's data as NJ Transit publishes it: a route per trip with no short name ("Allentown-Clinton Eastbound"), the
    /// westbound headsigns "Outbound", and entities written before the names were title-cased ("&Amp;", "Peddler&Apos;S")
    private var transBridgeFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            AllentownClinton_EB_101,20169,,Allentown-Clinton Eastbound,3
            AllentownClinton_EB_105,20169,,Allentown-Clinton Eastbound,3
            AllentownClinton_WB_202,20169,,Allentown-Clinton Westbound,3
            DoylestownFlemington_EB_301,20169,,Doylestown-Flemington Eastbound,3
            WallSt_EB_401,20169,,Wall St Eastbound,3
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon
            AllentownClinton_1,,Allentown Transportation Center - Platform C,,40.604265,-75.471484
            AllentownClinton_4,,"Wescosville, PAPark &Amp; Ride",,40.569722,-75.543333
            AllentownClinton_11,,"New York, NY (PABT) Out",,40.756809,-73.990564
            AllentownClinton_12,,"New York, NY (PABT) In",,40.757153,-73.993457
            DoylestownFlemington_3,,"Lahaska, PA - Peddler&Apos;S Village At Street Rd",,40.34801886,-75.03107873
            WallSt_7,,Water &Amp; Wall,,40.70500403,-74.00741902
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            AllentownClinton_EB_101,WD,T1,New York,1
            AllentownClinton_EB_105,WD,T5,New York,1
            AllentownClinton_WB_202,WD,T2,Outbound,0
            DoylestownFlemington_EB_301,WD,T3,New York,1
            WallSt_EB_401,WD,T4,New York,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type
            T1,08:00:00,08:00:00,AllentownClinton_1,1,
            T1,09:30:00,09:30:00,AllentownClinton_12,2,
            T5,10:00:00,10:00:00,AllentownClinton_4,1,
            T5,10:20:00,10:20:00,AllentownClinton_1,2,
            T5,11:50:00,11:50:00,AllentownClinton_12,3,
            T2,17:00:00,17:00:00,AllentownClinton_11,1,
            T2,18:30:00,18:30:00,AllentownClinton_4,2,1
            T2,18:45:00,18:45:00,AllentownClinton_1,3,1
            T3,07:00:00,07:00:00,DoylestownFlemington_3,1,
            T3,08:30:00,08:30:00,AllentownClinton_12,2,
            T4,06:00:00,06:00:00,AllentownClinton_4,1,
            T4,08:00:00,08:00:00,WallSt_7,2,
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WD,1,1,1,1,1,0,0,20251208,20261231
            """),
        ]
    }

    /// Trans-Bridge's trips are three routes, named for where they start; its stop names are mended; a westbound trip shows where it ends
    func testTransBridgeRoutesAndNames() throws {
        let tbl = try XCTUnwrap(RegionalBusFeed.feed(code: "TBL"))
        XCTAssertTrue(tbl.routesByFirstPlace)
        XCTAssertNil(tbl.downloadArea, "it stops in three metro areas, so everyone downloads it")
        XCTAssertFalse(tbl.hasRealtime)
        XCTAssertEqual(RegionalBusFeed.all.filter(\.routesByFirstPlace).map(\.code), ["TBL"])
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: transBridgeFiles, now: now, feed: tbl), feed: tbl)
        XCTAssertEqual(Set(index.routeNames), ["Allentown", "Doylestown", "Wall St"])
        XCTAssertEqual(index.routeNames.count, 3)
        XCTAssertEqual(Set(index.stopNames), ["Allentown Transportation Center - Platform C", "Wescosville, PA Park & Ride",
                                              "New York, NY (PABT) Out", "New York, NY (PABT) In",
                                              "Lahaska, PA - Peddler's Village At Street Rd", "Water & Wall"])
        let morning = now.addingTimeInterval(-6 * 3600), night = now.addingTimeInterval(12 * 3600)
        let allentown = index.slice(near: Coordinate(latitude: 40.604265, longitude: -75.471484), radiusMeters: 300)
        let atc = try XCTUnwrap(allentown.piers.first { $0.name.hasPrefix("Allentown Transportation Center") }?.id)
        let fromAllentown = allentown.arrivals(pierIDs: [atc], from: morning, to: night, realtime: [], now: morning)
        XCTAssertEqual(Set(fromAllentown.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" }), ["Allentown New York"])
        // Westbound: "Outbound" isn't a destination, so the trip shows its last stop
        let pabt = index.slice(near: Coordinate(latitude: 40.756809, longitude: -73.990564), radiusMeters: 300)
        let gate = try XCTUnwrap(pabt.piers.first { $0.name.hasSuffix("Out") }?.id)
        let fromNewYork = pabt.arrivals(pierIDs: [gate], from: morning, to: night, realtime: [], now: morning)
        XCTAssertEqual(fromNewYork.map { "\(FerryFeed.badge($0.route)) \($0.direction.terminal ?? "")" },
                       ["Allentown Allentown Transportation Center - Platform C"])
        XCTAssertEqual(NJBusBuilder.firstPlace(longName: "Allentown-Clinton Westbound"), "Allentown")
        XCTAssertEqual(NJBusBuilder.firstPlace(longName: "Wall St Eastbound"), "Wall St")
        XCTAssertEqual(NJBusBuilder.firstPlace(longName: "Doylestown-Flemington"), "Doylestown")
        XCTAssertNil(NJBusBuilder.firstPlace(longName: " "))
        // The mending leaves other data's names as they were
        XCTAssertEqual(NJBusBuilder.stopName("ST LUKE'S WARREN HOSPITAL"), NJBusBuilder.stopName("ST LUKE'S WARREN HOSPITAL"))
        XCTAssertEqual(NJBusBuilder.stopName("O'Shea Park, NY"), "O'Shea Park, NY")
        XCTAssertEqual(NJBusBuilder.stopName("Main St, NJ Transit Lot"), "Main St, NJ Transit Lot")
    }

    /// LANta, the Pocono Pony and Warren County's shuttles are downloaded only for places in the Lehigh Valley, whose box holds all
    /// their stops (the corners of LANta's and the Pocono Pony's stops in their 2026 data; Warren County's towns)
    func testLehighValleyCompanies() throws {
        let at = { (lat: Double, lon: Double) in Coordinate(latitude: lat, longitude: lon) }
        for code in ["LANTA", "PONY", "WARR"] {
            let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code), code)
            XCTAssertEqual(feed.downloadArea, .lehighValley, code)
        }
        XCTAssertTrue(try XCTUnwrap(RegionalBusFeed.feed(code: "LANTA")).hasRealtime)
        XCTAssertTrue(try XCTUnwrap(RegionalBusFeed.feed(code: "PONY")).hasRealtime)
        XCTAssertFalse(try XCTUnwrap(RegionalBusFeed.feed(code: "WARR")).hasRealtime)
        let corners = [at(40.527096, -75.894966), at(40.884444, -75.204932), at(40.527096, -75.204932), at(40.884444, -75.894966),
                       at(40.982555, -75.415588), at(41.219090, -75.038175), at(40.982555, -75.038175), at(41.219090, -75.415588)]
        let towns = [at(40.6023, -75.4714), at(40.8676, -75.7402), at(41.1220, -75.3646),                 // Allentown, Jim Thorpe, Mount Pocono
                     at(40.6937, -75.1902), at(40.7584, -74.9793), at(40.8529, -74.8291)]                // Phillipsburg, Washington, Hackettstown
        for c in corners + towns { XCTAssertTrue(DownloadArea.lehighValley.contains(c), "\(c)") }
        for c in towns { XCTAssertEqual(MetroArea.of(c), .lehighValley, "\(c)") }
        for c in [at(40.7557, -73.9871), at(39.9556, -75.1820), at(40.3356, -75.9269)] {   // Times Sq, Philadelphia, Reading
            XCTAssertFalse(DownloadArea.lehighValley.contains(c), "\(c)")
        }
        PlacesInUse.reset()
        defer { PlacesInUse.reset() }
        let lanta = try XCTUnwrap(RegionalBusFeed.feed(code: "LANTA"))
        PlacesInUse.set(.start, [at(40.7557, -73.9871)])
        XCTAssertFalse(lanta.isWanted)
        XCTAssertTrue(try XCTUnwrap(RegionalBusFeed.feed(code: "TBL")).isWanted)
        PlacesInUse.set(.planner, [at(40.6023, -75.4714)])   // Allentown
        XCTAssertTrue(lanta.isWanted)
    }

    /// Under CMT_REGIONAL_BUS_DIR, one unzipped folder per agency, named by its code (e.g. BXL, DCT).
    func testRealRegionalBusDataIfAvailable() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMT_REGIONAL_BUS_DIR"] else { throw XCTSkip("CMT_REGIONAL_BUS_DIR is not set") }
        var checked = 0
        for feed in RegionalBusFeed.all where !feed.code.isEmpty {
            let folder = URL(fileURLWithPath: dir).appendingPathComponent(feed.code)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            var files: [String: Data] = [:]
            for name in ["routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt", "stop_times.txt", "shapes.txt"] {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { files[name] = data }
            }
            let clock = Date()
            let data = try NJBusBuilder.build(files: files, now: Date(), feed: feed)
            let index = try NJBusIndex(data: data, feed: feed)
            let map = index.map()
            // Find a stop that has trips and take a chunk there
            let busiest = (0..<index.stopCount).max { index.stopPatterns($0).count < index.stopPatterns($1).count } ?? 0
            let c = Coordinate(latitude: index.stopLat[busiest], longitude: index.stopLon[busiest])
            let slice = index.slice(near: c, radiusMeters: 800)
            let near = slice.stations(near: c, radiusMeters: 800)
            let arrivals = slice.arrivals(pierIDs: near.map(\.id), from: Date(), to: Date().addingTimeInterval(24 * 3600),
                                          realtime: [], now: Date())
            print("\(feed.code): \(data.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(clock))) s, \(index.stopCount) stops, \(index.routeCount) routes \(index.routeNames.prefix(8)), \(index.tripCount) trips, map \(map?.routes.count ?? 0); near \(index.stopNames[busiest]): \(near.count) stops, next 24 h \(arrivals.count), e.g. \(arrivals.prefix(3).map { "\(FerryFeed.badge($0.route)) \($0.direction.name)" })")
            XCTAssertGreaterThan(index.tripCount, 0, feed.code)
            XCTAssertTrue(ServiceArea.contains(c), feed.code)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: CTrail Hartford Line (train)

    func testHartfordLine() throws {
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color
            HART,CONN DOT,,Hartford Line,2,ea0d2a
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            NHV,NEW HAVEN UNION STATION,41.2977,-72.9266
            MDN,Meriden,41.5378,-72.8009
            HFD,Hartford,41.7685,-72.6818
            SPG,Springfield,42.1065,-72.5933
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            HART,WK,4401,Northbound to Hartford,0
            HART,WK,4402,,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            4401,12:10:00,12:10:00,NHV,1
            4401,12:35:00,12:35:00,MDN,2
            4401,13:00:00,13:00:00,HFD,3
            4401,13:40:00,13:40:00,SPG,4
            4402,11:00:00,11:00:00,SPG,1
            4402,11:40:00,11:40:00,HFD,2
            4402,12:05:00,12:05:00,MDN,3
            4402,12:30:00,12:30:00,NHV,4
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
        XCTAssertEqual(FerryFeed.Source.hartfordLine.system, .train)
        XCTAssertFalse(FerryFeed.Source.hartfordLine.hasRealtime)
        let feed = try FerryBuilder.build([.hartfordLine: files], now: now)
        XCTAssertEqual(feed.routes.map(\.id), ["CTR-HL"])
        XCTAssertEqual(FerryFeed.badge("CTR-HL"), "HL")
        XCTAssertEqual(FerryFeed.routeName("CTR-HL"), "CTrail Hartford Line")
        XCTAssertTrue(FerryFeed.isRailRoute("CTR-HL"))
        // Only stations in the service area: all of them (Hartford in Greater Hartford, Springfield in Western Massachusetts)
        XCTAssertEqual(Set(feed.piers.map(\.name)), ["New Haven Union Station", "Meriden", "Hartford", "Springfield"])
        XCTAssertTrue(FerryFeed.Source.hartfordLine.keepsStop(lat: 42.1065, lon: -72.5933))
        XCTAssertFalse(FerryFeed.Source.hartfordLine.keepsStop(lat: 42.6526, lon: -73.7562))   // Albany
        let meriden = try XCTUnwrap(feed.piers.first { $0.name == "Meriden" }?.id)
        let arrivals = feed.arrivals(pierIDs: [meriden], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        // The headsign is the whole trip's last stop
        XCTAssertEqual(Set(arrivals.map { $0.direction.terminal ?? "" }), ["Hartford", "New Haven Union Station"])
        XCTAssertEqual(feed.route("CTR-HL")?.color.uppercased(), "EA0D2A")
    }

    /// WCAG contrast ratio of white text on this background color ("974806")
    private func contrastWithWhite(_ hex: String) -> Double {
        let value = UInt32(hex, radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }
}
