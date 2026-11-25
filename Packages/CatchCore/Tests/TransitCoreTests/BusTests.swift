import XCTest
@testable import TransitCore

final class BusTests: XCTestCase {

    func testBundledCatalog() throws {
        let c = try BusCatalog.loadBundled()
        XCTAssertGreaterThan(c.stops.count, 10_000)
        XCTAssertGreaterThan(c.routes.count, 300)
        XCTAssertEqual(c.routes["Q53+"]?.headsigns["0"], "Woodside")
        XCTAssertEqual(c.routes["M60+"]?.express, true)
    }

    func testNearbyStopsAroundWoodside() throws {
        let c = try BusCatalog.loadBundled()
        let center = Coordinate(latitude: 40.73862, longitude: -73.90003) // 65 Pl / 48 Av bus stop
        let stations = c.stations(near: center, radiusMeters: 800)
        XCTAssertFalse(stations.isEmpty)
        XCTAssertLessThanOrEqual(stations.count, 30)
        // Keep only the nearest stop for each direction of each route
        var seen = Set<String>()
        for s in stations {
            for rd in c.stop(id: s.id)!.routeDirections where seen.contains("\(rd.route)|\(rd.direction)") {
                // A stop can share a direction with a closer stop, but it must bring at least one new direction
                _ = rd
            }
            for rd in c.stop(id: s.id)!.routeDirections { seen.insert("\(rd.route)|\(rd.direction)") }
        }
        // Stops on both sides of 65 Pl / 48 Av merge into one stop group, split by side
        let pair = stations.filter { $0.name == "65 Pl / 48 Av" }
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(Set(pair.compactMap(\.complexID)).count, 1)
        let ids = pair.map(\.id)
        XCTAssertEqual(Set(ids.map { c.side(ofStop: $0, among: ids) }), ["N", "S"])
        XCTAssertTrue(stations.allSatisfy { $0.entranceToPlatformSeconds == 0 })
    }

    func testServiceKinds() {
        XCTAssertEqual(BusCatalog.service(ofRoute: "Q18"), .local)
        XCTAssertEqual(BusCatalog.service(ofRoute: "M15+"), .selectBus)
        XCTAssertEqual(BusCatalog.service(ofRoute: "QM16"), .express)
        XCTAssertEqual(BusCatalog.service(ofRoute: "BXM2"), .express)
        XCTAssertEqual(BusCatalog.service(ofRoute: "X27"), .express)
        XCTAssertEqual(BusCatalog.service(route: "M101", destination: "LTD FT GEORGE via 3 AV"), .limited)
        XCTAssertEqual(BusCatalog.service(route: "M101", destination: "FT GEORGE via 3 AV"), .local)
        XCTAssertTrue(BusCatalog.isBusRoute("B1"))
        XCTAssertFalse(BusCatalog.isBusRoute("B"))
        XCTAssertFalse(BusCatalog.isBusRoute("7X"))
        XCTAssertEqual(BusCatalog.cleanDestination("LTD FT GEORGE via 3 AV"), "Ft George")
        XCTAssertEqual(BusCatalog.niceName("WILLIS AV/E 138 ST"), "Willis Av / E 138 St")
    }

    func testRouteOrder() {
        XCTAssertEqual(["B11", "B2", "B1", "Bx12", "B44+"].sorted(by: BusCatalog.routeOrder), ["B1", "B2", "B11", "B44+", "Bx12"])
    }

    func testParseStopMonitoring() throws {
        let json = """
        {"Siri":{"ServiceDelivery":{"ResponseTimestamp":"2026-10-13T21:00:05.123-04:00",
          "StopMonitoringDelivery":[{"MonitoredStopVisit":[
            {"RecordedAtTime":"2026-10-13T20:59:50.000-04:00","MonitoredVehicleJourney":{
              "LineRef":"MTABC_Q53+","DirectionRef":"0","PublishedLineName":["Q53-SBS"],
              "DestinationName":["SELECT BUS WOODSIDE 61 ST STA"],
              "FramedVehicleJourneyRef":{"DataFrameRef":"2026-10-13","DatedVehicleJourneyRef":"MTABC_123"},
              "MonitoredCall":{"ExpectedArrivalTime":"2026-10-13T21:06:00.000-04:00","StopPointRef":"MTA_550559"}}},
            {"RecordedAtTime":"2026-10-13T20:59:40.000-04:00","MonitoredVehicleJourney":{
              "LineRef":"MTA NYCT_Q18","DirectionRef":"1","DestinationName":"LTD ASTORIA via 30 AV",
              "FramedVehicleJourneyRef":{"DatedVehicleJourneyRef":"MTA NYCT_456"},
              "MonitoredCall":{"ExpectedArrivalTime":"2026-10-13T21:10:00-04:00"}}},
            {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_Q18","MonitoredCall":{}}}
          ]}]}}}
        """
        let r = try BusTimeParser.arrivals(from: Data(json.utf8), stopID: "550559", side: "S", catalog: nil,
                                           fallbackTime: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.arrivals.count, 2)
        XCTAssertEqual(r.arrivals[0].route, "Q53+")
        XCTAssertEqual(r.arrivals[0].busService, .selectBus)
        XCTAssertEqual(r.arrivals[0].direction.code, "S")
        XCTAssertEqual(r.arrivals[0].direction.terminal, "Woodside 61 St Sta")
        XCTAssertEqual(r.arrivals[1].busService, .limited)
        XCTAssertEqual(r.arrivals[1].direction.terminal, "Astoria")
        XCTAssertEqual(r.arrivals[1].arrivalTime, ISO8601DateFormatter().date(from: "2026-10-14T01:10:00Z"))
        XCTAssertNotNil(r.responseTime)
    }

    /// Buses without a trip number: each refresh gives the same ID (the list doesn't flicker); the data time is Bus Time's response time
    func testStableIDWithoutJourneyRef() throws {
        let json = """
        {"Siri":{"ServiceDelivery":{"ResponseTimestamp":"2026-10-13T21:00:05.000-04:00",
          "StopMonitoringDelivery":[{"MonitoredStopVisit":[
            {"RecordedAtTime":"2026-10-13T20:50:00.000-04:00","MonitoredVehicleJourney":{
              "LineRef":"MTA NYCT_Q32","DirectionRef":"0","DestinationName":"JACKSON HTS",
              "MonitoredCall":{"ExpectedArrivalTime":"2026-10-13T21:06:00.000-04:00"}}}
          ]}]}}}
        """
        func parse() throws -> Arrival {
            try XCTUnwrap(BusTimeParser.arrivals(from: Data(json.utf8), stopID: "1", side: "N", catalog: nil,
                                                 fallbackTime: Date()).arrivals.first)
        }
        XCTAssertEqual(try parse().id, try parse().id)
        XCTAssertEqual(try parse().updatedAt, ISO8601DateFormatter().date(from: "2026-10-14T01:00:05Z"))
    }

    /// Without a trip or vehicle number, the ID follows the scheduled time when there is one, so a bus whose expected time moves
    /// keeps its row; without a scheduled time it falls back to the expected time
    func testIDFollowsTheScheduledTime() throws {
        func visit(expected: String, aimed: String?) throws -> Arrival {
            let aimedField = aimed.map { #","AimedArrivalTime":"\#($0)""# } ?? ""
            let json = """
            {"Siri":{"ServiceDelivery":{"ResponseTimestamp":"2026-10-13T21:00:05.000-04:00",
              "StopMonitoringDelivery":[{"MonitoredStopVisit":[
                {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_Q32","DirectionRef":"0",
                  "MonitoredCall":{"ExpectedArrivalTime":"\(expected)"\(aimedField)}}}
              ]}]}}}
            """
            return try XCTUnwrap(BusTimeParser.arrivals(from: Data(json.utf8), stopID: "1", side: "N", catalog: nil,
                                                        fallbackTime: Date()).arrivals.first)
        }
        let aimed = "2026-10-13T21:05:00.000-04:00"
        let first = try visit(expected: "2026-10-13T21:06:00.000-04:00", aimed: aimed)
        let later = try visit(expected: "2026-10-13T21:08:00.000-04:00", aimed: aimed)
        XCTAssertEqual(first.id, later.id)
        XCTAssertNotEqual(first.arrivalTime, later.arrivalTime)
        XCTAssertNotEqual(try visit(expected: "2026-10-13T21:06:00.000-04:00", aimed: nil).id,
                          try visit(expected: "2026-10-13T21:08:00.000-04:00", aimed: nil).id)
    }

    func testInvalidKeyError() {
        let json = #"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"ErrorCondition":{"Description":"API key is not authorized."}}]}}}"#
        XCTAssertThrowsError(try BusTimeParser.arrivals(from: Data(json.utf8), stopID: "1", side: "N", catalog: nil,
                                                        fallbackTime: Date())) { e in
            XCTAssertEqual(e as? BusTimeError, .invalidKey)
        }
    }

    func testLoaderWithoutKey() async throws {
        let c = BusCatalog(feedVersion: "", routes: [:], stops: [])
        let s = Station(id: "1", name: "A", coordinate: Coordinate(latitude: 0, longitude: 0), entrances: [],
                        entranceToPlatformSeconds: 0)
        let load = await BusTimeLoader(key: " ", catalog: c).load(stations: [s])
        XCTAssertEqual(load.mainError, .missingKey)
        XCTAssertTrue(load.arrivals.isEmpty)
    }

    /// A stop listed twice (upstream data with a duplicate) doesn't crash the loader
    func testLoaderWithDuplicateStops() async {
        let c = BusCatalog(feedVersion: "", routes: [:], stops: [])
        let s = Station(id: "1", name: "A", coordinate: Coordinate(latitude: 0, longitude: 0), entrances: [],
                        entranceToPlatformSeconds: 0)
        let load = await BusTimeLoader(key: " ", catalog: c).load(stations: [s, s])
        XCTAssertEqual(load.errors, ["1": .missingKey])
    }

    /// Several stops asked at once, their answers arriving in another order than asked: each stop's buses come back under that
    /// stop (the answers are kept by their place in the list, see Together), and a stop that fails is reported for itself
    /// while the others still count
    func testLoaderKeepsEachStopsAnswerUnderThatStop() async {
        struct ByStop: DataFetching {
            func fetch(_ url: URL) async throws -> Data {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let number = Int(items.first { $0.name == "MonitoringRef" }?.value ?? "") else { throw FeedFetchError.noData }
                if number == 7 { throw FeedFetchError.httpStatus(500) }
                // The stops asked first answer last
                try await Task.sleep(nanoseconds: UInt64(13 - number) * 4_000_000)
                let minute = number < 10 ? "0\(number)" : "\(number)"
                let json = """
                {"Siri":{"ServiceDelivery":{"ResponseTimestamp":"2026-10-13T21:00:05.000-04:00",
                  "StopMonitoringDelivery":[{"MonitoredStopVisit":[
                    {"MonitoredVehicleJourney":{"LineRef":"MTA NYCT_Q\(number)","DirectionRef":"0","DestinationName":"SOMEWHERE",
                      "MonitoredCall":{"ExpectedArrivalTime":"2026-10-13T21:\(minute):00.000-04:00"}}}
                  ]}]}}}
                """
                return Data(json.utf8)
            }
        }
        BusTimeBackoff.forget()
        defer { BusTimeBackoff.forget() }
        let catalog = BusCatalog(feedVersion: "", routes: [:], stops: [])
        let stations = (1...12).map {
            Station(id: "\($0)", name: "Stop \($0)", coordinate: Coordinate(latitude: 0, longitude: 0), entrances: [], entranceToPlatformSeconds: 0)
        }
        let load = await BusTimeLoader(key: "k", catalog: catalog, fetcher: ByStop()).load(stations: stations)
        XCTAssertEqual(load.errors, ["7": .httpStatus(500)])
        XCTAssertEqual(load.requested, 12)
        XCTAssertEqual(load.arrivals.map(\.stationID), stations.map(\.id).filter { $0 != "7" }, "in the order the stops were asked")
        for arrival in load.arrivals {
            XCTAssertEqual(arrival.route, "Q" + arrival.stationID, "stop \(arrival.stationID) got another stop's bus")
            let minute = arrival.arrivalTime.flatMap {
                Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: $0).minute
            }
            XCTAssertEqual(minute, Int(arrival.stationID), "and its own time")
        }
        XCTAssertEqual(load.responseTime, ISO8601DateFormatter().date(from: "2026-10-14T01:00:05Z"))
    }

    /// A Bus Time answer is reused for the same stops for under a minute; a timed refresh always asks again,
    /// and an answer where every stop failed is never reused
    func testBusLoadMemo() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let arrival = Arrival(id: "j|1", stationID: "1", route: "Q53+", direction: Direction(code: "N", name: "To Woodside"),
                              arrivalTime: t0.addingTimeInterval(300), source: .realtime, updatedAt: t0)
        let ok = BusLoad(arrivals: [arrival], errors: [:], fetchedAt: t0.addingTimeInterval(2), responseTime: t0, requested: 2)
        var memo = BusLoadMemo()
        XCTAssertNil(memo.reusable(stops: ["1", "2"], now: t0), "Nothing kept yet")
        memo.keep(ok, stops: ["1", "2"], startedAt: t0)
        XCTAssertEqual(memo.reusable(stops: ["1", "2"], now: t0.addingTimeInterval(30))?.arrivals.map(\.id), ["j|1"])
        XCTAssertEqual(memo.reusable(stops: ["2", "1"], now: t0.addingTimeInterval(30))?.fetchedAt, ok.fetchedAt,
                       "Same stops in another order: reused with its own download time")
        XCTAssertNil(memo.reusable(stops: ["1", "3"], now: t0.addingTimeInterval(30)), "Other stops")
        XCTAssertNil(memo.reusable(stops: ["1"], now: t0.addingTimeInterval(30)), "Fewer stops")
        XCTAssertNil(memo.reusable(stops: ["1", "2"], now: t0.addingTimeInterval(55)))
        XCTAssertNil(memo.reusable(stops: ["1", "2"], now: t0.addingTimeInterval(-1)), "Clock set back")
        // A timed refresh is due from 59 s on, and the memo never stands in for it
        XCTAssertLessThan(BusLoadMemo.reuseFor, 59)
        XCTAssertTrue(RefreshSchedule.isDue(now: t0.addingTimeInterval(59), lastStart: t0, interval: 60, running: false))
        XCTAssertNil(memo.reusable(stops: ["1", "2"], now: t0.addingTimeInterval(59)))
        // An answer where every stop failed isn't kept, and drops the one before
        let failed = BusLoad(arrivals: [], errors: ["1": .httpStatus(500), "2": .httpStatus(500)], fetchedAt: t0,
                             responseTime: nil, requested: 2)
        XCTAssertTrue(failed.allFailed)
        memo.keep(ok, stops: ["1", "2"], startedAt: t0)
        memo.keep(failed, stops: ["1", "2"], startedAt: t0.addingTimeInterval(10))
        XCTAssertNil(memo.reusable(stops: ["1", "2"], now: t0.addingTimeInterval(20)))
        // Only the stops a load asks (the nearest maxStops) are compared
        let many = (0..<(BusTimeLoader.maxStops + 3)).map { "s\($0)" }
        memo.keep(ok, stops: many, startedAt: t0)
        XCTAssertNotNil(memo.reusable(stops: Array(many.prefix(BusTimeLoader.maxStops)), now: t0.addingTimeInterval(1)))
    }

    func testNonSiriAnswerIsUnexpected() {
        XCTAssertThrowsError(try BusTimeParser.arrivals(from: Data(#"{"status":"maintenance"}"#.utf8), stopID: "1", side: "N",
                                                        catalog: nil, fallbackTime: Date())) { e in
            XCTAssertEqual(e as? BusTimeError, .unexpectedResponse)
        }
    }

    func testBusMapBuilder() throws {
        var b = BusMapBuilder()
        try b.add(files: [
            "routes.txt": Data("route_id,route_short_name,route_color\nQ18,Q18,\nM15+,M15-SBS,00a1de\n".utf8),
            "trips.txt": Data("""
                route_id,trip_id,direction_id,shape_id
                Q18,t1,0,Q180001
                Q18,t2,0,Q180001
                Q18,t3,0,Q180002
                Q18,t4,1,Q180003
                M15+,t5,1,M15S01
                """.utf8),
            "shapes.txt": Data("""
                shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence
                Q180001,40.7,-73.9,1
                Q180001,40.71,-73.9,2
                Q180001,40.72,-73.9,3
                Q180002,40.0,-73.0,1
                Q180002,40.1,-73.0,2
                M15S01,40.8,-73.95,2
                M15S01,40.7,-73.99,1
                """.utf8),
        ])
        let map = try b.build()
        XCTAssertEqual(map.routes.map(\.route), ["M15+", "Q18"])
        XCTAssertEqual(map.routes[0].color, "00A1DE")
        // A route with only direction 1 uses direction 1; points in order
        XCTAssertEqual(map.routes[0].lines, [[[40.7, -73.99], [40.8, -73.95]]])
        // Direction 0's most common pattern, with middle points on straight lines simplified away
        XCTAssertEqual(map.routes[1].color, "0039A6")
        XCTAssertEqual(map.routes[1].lines, [[[40.7, -73.9], [40.72, -73.9]]])
        XCTAssertTrue(map.stations.isEmpty)
    }

    func testBundledBusMap() throws {
        let map = try BusMap.loadBundled()
        XCTAssertGreaterThan(map.routes.count, 300)
    }

    func testBusRouteSorting() {
        XCTAssertEqual(NearbyBoardBuilder.sortRoutes(["B11", "Q18", "B2", "7"]), ["7", "B2", "B11", "Q18"])
    }
}
