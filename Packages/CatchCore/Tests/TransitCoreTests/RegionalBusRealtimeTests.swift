import XCTest
@testable import TransitCore

/// Minimal Protocol Buffers encoder for tests (builds GTFS-Realtime trip updates)
private struct Proto {
    var bytes: [UInt8] = []
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    mutating func int(_ field: Int, _ v: UInt64) { bytes += Proto.varint(UInt64(field << 3)) + Proto.varint(v) }
    mutating func string(_ field: Int, _ s: String) {
        let b = Array(s.utf8)
        bytes += Proto.varint(UInt64(field << 3 | 2)) + Proto.varint(UInt64(b.count)) + b
    }
    mutating func message(_ field: Int, _ build: (inout Proto) -> Void) {
        var sub = Proto()
        build(&sub)
        bytes += Proto.varint(UInt64(field << 3 | 2)) + Proto.varint(UInt64(sub.bytes.count)) + sub.bytes
    }
}

/// Bus live data: CTtransit, Bee-Line (free) and NJ Transit (account); each operator has a different trip ID prefix.
final class RegionalBusRealtimeTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

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

    /// Predicted arrival times of these trips at S1 (or another stop); startDate: the trips' start_date (none when nil); at: the
    /// header's time (now when nil)
    private func tripUpdates(_ trips: [(String, Date)], stop: String = "S1", startDate: String? = nil, at header: Date? = nil) -> Data {
        var feed = Proto()
        feed.message(1) { h in h.string(1, "2.0"); h.int(3, UInt64((header ?? now).timeIntervalSince1970)) }
        for (id, time) in trips {
            feed.message(2) { e in
                e.string(1, id)
                e.message(3) { tu in
                    tu.message(1) { t in
                        t.string(1, id)
                        if let startDate { t.string(3, startDate) }
                    }
                    tu.message(2) { s in
                        s.message(2) { a in a.int(2, UInt64(time.timeIntervalSince1970)) }
                        s.string(4, stop)
                    }
                }
            }
        }
        return Data(feed.bytes)
    }

    /// One trip's predicted times at several stops
    private func tripUpdate(_ id: String, stops: [(String, Date)], at time: Date? = nil) -> Data {
        let header = time ?? now
        var feed = Proto()
        feed.message(1) { h in h.string(1, "2.0"); h.int(3, UInt64(header.timeIntervalSince1970)) }
        feed.message(2) { e in
            e.string(1, id)
            e.message(3) { tu in
                tu.message(1) { t in t.string(1, id) }
                for (stop, time) in stops {
                    tu.message(2) { s in
                        s.message(2) { a in a.int(2, UInt64(time.timeIntervalSince1970)) }
                        s.string(4, stop)
                    }
                }
            }
        }
        return Data(feed.bytes)
    }

    /// Bus live data lists every upcoming stop: stops not yet reached still show (the ferry rule "the second-to-last known stop counts as departed" can't be used)
    func testBusWithManyStopUpdatesKeepsUpcomingStops() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: nice), feed: nice)
        let feed = index.slice(near: Coordinate(latitude: 40.7069, longitude: -73.6171), radiusMeters: 1500)
        // T1: S1 12:10, S2 12:14, S3 12:50, 2 minutes late
        let late: TimeInterval = 120
        let rt = try nice.realtime(from: tripUpdate("T1", stops: [
            ("S1", now.addingTimeInterval(10 * 60 + late)),
            ("S2", now.addingTimeInterval(14 * 60 + late)),
            ("S3", now.addingTimeInterval(50 * 60 + late)),
        ]), fetchedAt: now)
        let arrivals = feed.arrivals(pierIDs: ["njb:NICE/S1", "njb:NICE/S2"], from: now, to: now.addingTimeInterval(3600),
                                     realtime: [rt], now: now).filter { $0.id.contains("T1|") }
        XCTAssertEqual(Set(arrivals.map(\.stationID)), ["njb:NICE/S1", "njb:NICE/S2"])
        XCTAssertTrue(arrivals.allSatisfy { $0.source == .realtime })
        XCTAssertEqual(arrivals.first { $0.stationID == "njb:NICE/S1" }?.arrivalTime, now.addingTimeInterval(10 * 60 + late))
        // Already past S1 (predicted 12:12, now 12:20): S1 isn't shown, S2 still is
        let later = now.addingTimeInterval(20 * 60)
        let rt2 = try nice.realtime(from: tripUpdate("T1", stops: [
            ("S1", now.addingTimeInterval(12 * 60)),
            ("S2", now.addingTimeInterval(21 * 60)),
            ("S3", now.addingTimeInterval(56 * 60)),
        ], at: later), fetchedAt: later)
        let after = feed.arrivals(pierIDs: ["njb:NICE/S1", "njb:NICE/S2"], from: later.addingTimeInterval(-60 * 60),
                                  to: later.addingTimeInterval(3600), realtime: [rt2], now: later).filter { $0.id.contains("T1|") }
        XCTAssertEqual(after.map(\.stationID), ["njb:NICE/S2"])
    }

    /// A stop where the bus only lets riders off (pickup_type = 1) stays in the slice's trip: live data there still lines up
    /// and carries over to the next stop, but the stop itself isn't offered for boarding
    func testDropOffOnlyStopStillLinesUpWithLiveData() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        var f = files
        f["stops.txt"] = d("""
        stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
        S1,Hempstead Transit Center,40.7069,-73.6171,0,
        S2,Fulton St &amp; Franklin Av,40.7060,-73.6300,,
        S3,Jamaica Center,40.7020,-73.8010,0,
        S4,Hempstead Bus Terminal,40.7100,-73.6200,0,
        """)
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
        7,WK,T1,Hempstead,1,
        """)
        // From Jamaica: riders can only get off at Fulton St, get on again at Hempstead Transit Center
        f["stop_times.txt"] = d("""
        trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
        T1,11:40:00,11:40:00,S3,1,0,1
        T1,12:10:00,12:10:00,S2,2,1,0
        T1,12:14:00,12:14:00,S1,3,0,0
        T1,12:20:00,12:20:00,S4,4,1,0
        """)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: f, now: now, feed: nice), feed: nice)
        let hempstead = Coordinate(latitude: 40.7069, longitude: -73.6171)
        let feed = index.slice(near: hempstead, radiusMeters: 1500)
        let trip = try XCTUnwrap(feed.trips.first)
        XCTAssertEqual(trip.stops, ["njb:NICE/S2", "njb:NICE/S1", "njb:NICE/S4"])
        XCTAssertEqual(trip.noBoarding, [0])
        XCTAssertEqual(feed.stations(near: hempstead, radiusMeters: 1500).map(\.id), ["njb:NICE/S1"])
        // The bus is 3 minutes late at Fulton St: it shows 3 minutes late at Hempstead Transit Center, and isn't listed at Fulton St
        let rt = try nice.realtime(from: tripUpdate("T1", stops: [("S2", now.addingTimeInterval(13 * 60))]), fetchedAt: now)
        let live = try XCTUnwrap(rt.delays(for: trip, dayStart: try XCTUnwrap(Timetable.serviceDayStart(20261014, in: Timetable.timeZone))))
        XCTAssertEqual(live.known.map { $0.index }, [0])
        let arrivals = feed.arrivals(pierIDs: ["njb:NICE/S1", "njb:NICE/S2"], from: now, to: now.addingTimeInterval(3600),
                                     realtime: [rt], now: now)
        XCTAssertEqual(arrivals.map(\.stationID), ["njb:NICE/S1"])
        XCTAssertEqual(arrivals.first?.arrivalTime, now.addingTimeInterval(17 * 60))
        XCTAssertEqual(arrivals.first?.source, .realtime)
        // Near Fulton St alone nothing can be boarded: no trips, no stops
        let fulton = index.slice(near: Coordinate(latitude: 40.7060, longitude: -73.6300), radiusMeters: 300)
        XCTAssertTrue(fulton.trips.isEmpty && fulton.piers.isEmpty)
    }

    /// A loop ends where it starts: a prediction for the end isn't put on the start. A stop left without times sits between its neighbors,
    /// and a stop served twice on one trip gives two arrivals with different IDs
    func testLoopsBlankTimesAndStopsServedTwice() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        var f = files
        f["stops.txt"] = d("""
        stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
        S1,Hempstead Transit Center,40.7069,-73.6171,0,
        S2,Fulton St &amp; Franklin Av,40.7060,-73.6300,,
        S4,Hempstead Bus Terminal,40.7100,-73.6200,0,
        """)
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
        7,WK,T8,Hempstead,0,
        7,WK,T9,Hempstead,0,
        """)
        f["stop_times.txt"] = d("""
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        T8,12:00:00,12:00:00,S1,1
        T8,12:05:00,12:05:00,S2,2
        T8,12:10:00,12:10:00,S1,3
        T8,12:20:00,12:20:00,S4,4
        T9,12:10:00,12:10:00,S1,1
        T9,,,S2,2
        T9,12:30:00,12:30:00,S4,3
        T9,12:50:00,12:50:00,S1,4
        """)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: f, now: now, feed: nice), feed: nice)
        let feed = index.slice(near: Coordinate(latitude: 40.7069, longitude: -73.6171), radiusMeters: 1500)
        let loop = try XCTUnwrap(feed.trips.first { $0.id.hasSuffix("T9") })
        XCTAssertEqual(loop.stops, ["njb:NICE/S1", "njb:NICE/S2", "njb:NICE/S4", "njb:NICE/S1"])
        XCTAssertEqual(loop.times[1], 12 * 3600 + 20 * 60, "Halfway between 12:10 and 12:30")
        let dayStart = try XCTUnwrap(Timetable.serviceDayStart(20261014, in: Timetable.timeZone))
        // Only the end of the loop has a prediction (2 minutes late): the start keeps its timetable time
        let end = try nice.realtime(from: tripUpdate("T9", stops: [("S1", now.addingTimeInterval(52 * 60))]), fetchedAt: now)
        let live = try XCTUnwrap(end.delays(for: loop, dayStart: dayStart))
        XCTAssertEqual(live.known.map { $0.index }, [3])
        XCTAssertNil(live.delay(atIndex: 0))
        // Start and end both predicted: each lands on its own position
        let both = try nice.realtime(from: tripUpdate("T9", stops: [("S1", now.addingTimeInterval(11 * 60)),
                                                                    ("S1", now.addingTimeInterval(52 * 60))]), fetchedAt: now)
        XCTAssertEqual(try XCTUnwrap(both.delays(for: loop, dayStart: dayStart)).known.map { $0.index }, [0, 3])
        let arrivals = feed.arrivals(pierIDs: ["njb:NICE/S1"], from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600),
                                     realtime: [end], now: now)
        let start = try XCTUnwrap(arrivals.first { $0.id.contains("T9|") })
        XCTAssertEqual(start.arrivalTime, now.addingTimeInterval(10 * 60))
        XCTAssertEqual(start.source, .scheduled)
        // T8 boards at Hempstead Transit Center twice
        let twice = arrivals.filter { $0.id.contains("T8|") }
        XCTAssertEqual(twice.count, 2)
        XCTAssertEqual(Set(twice.map(\.id)).count, 2)
    }

    /// Before the first stop with a prediction the timetable applies; the vehicle isn't assumed late there either
    func testNoDelayBeforeTheFirstPrediction() {
        let live = FerryRealtime.Live(canceled: false, known: [(index: 2, delay: 300)], passedIndex: nil, updatedAt: nil)
        XCTAssertNil(live.delay(atIndex: 1))
        XCTAssertEqual(live.delay(atIndex: 2), 300)
        XCTAssertEqual(live.delay(atIndex: 4), 300)
        XCTAssertEqual(live.positionDelay(atIndex: 1), 0)
        let early = FerryRealtime.Live(canceled: false, known: [(index: 2, delay: -120)], passedIndex: nil, updatedAt: nil)
        XCTAssertEqual(early.positionDelay(atIndex: 0), -120)
    }

    func testBlankTimesAreFilledBetweenNeighbors() {
        let rows: [Int?] = [nil, 100, nil, nil, 400, nil]
        let filled = TimetableBuilder.fillingBlankTimes(rows, time: { $0 }) { _, t in t }
        XCTAssertEqual(filled, [100, 200, 300, 400], "A blank first or last stop is dropped")
    }

    func testFeedsWithRealtime() {
        XCTAssertEqual(RegionalBusFeed.all.filter(\.hasRealtime).map(\.code), ["", "SCT", "BXL", "CTT", "SEPTA", "POTT", "BARTA", "CECIL",
                                                                                 "LANTA", "PONY", "MBTA", "WRTA", "LRTA", "GATRA",
                                                                                 "BAT", "COAST", "PVTA", "FRTA", "WRTD"],
                       "Suffolk needs the user's own Swiftly key")
        XCTAssertTrue(RegionalBusFeed.njTransit.needsAccount)
        XCTAssertNil(RegionalBusFeed.njTransit.realtimeURL)
        XCTAssertNotNil(RegionalBusFeed.feed(code: "CTT")?.realtimeURL)
        XCTAssertNotNil(RegionalBusFeed.feed(code: "BXL")?.realtimeURL)
        // SEPTA's buses: the live data server its Metro and trains use too
        XCTAssertEqual(RegionalBusFeed.feed(code: "SEPTA")?.realtimeURL, FerryFeed.septaBusRealtimeURL)
        XCTAssertEqual(RegionalBusFeed.feed(code: "SEPTA")?.realtimeURL?.host, FerryFeed.Source.septaMetro.realtimeURL?.host)
        XCTAssertEqual(RegionalBusFeed.of(id: "njb:SEPTA/5001")?.code, "SEPTA")
        XCTAssertNil(RegionalBusFeed.feed(code: "NICE")?.realtimeURL)
        XCTAssertTrue(RegionalBusFeed.all.allSatisfy { $0.realtimeURL?.scheme.map { $0 == "https" } ?? true })

        XCTAssertEqual(RegionalBusFeed.of(id: "njb:123"), .njTransit)
        XCTAssertEqual(RegionalBusFeed.of(id: "njb:CTT/123")?.code, "CTT")
        XCTAssertNil(RegionalBusFeed.of(id: "njb:XYZ/1"))
        XCTAssertNil(RegionalBusFeed.of(id: "njr:NWK"))

        let ids = ["njb:1", "njb:CTT/2", "njb:NICE/3", "njb:BXL/4", "njb:CTT/5"]
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ids, hasAccount: false).map(\.code), ["BXL", "CTT"])
        // NJ Transit's buses are live with the account (liveWithAccount): their live data is downloaded with it only
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ids, hasAccount: true).map(\.code), ["", "BXL", "CTT"])
        XCTAssertTrue(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:NICE/3"], hasAccount: true).isEmpty)
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:SEPTA/5001", "njb:1"], hasAccount: false).map(\.code), ["SEPTA"])
    }

    /// A company whose live data failed counts as failed only while it is asked (its stops are near the place in use): moving
    /// away forgets it, so Settings doesn't keep saying "Timetable" for a company with live data. One with no live data never counts
    func testAFailureCountsOnlyWhileItsStopsAreNear() {
        XCTAssertEqual(RegionalBusFeed.failedAfterRefresh(asked: ["CTT", "BXL"], failed: ["CTT"]), ["CTT"])
        XCTAssertEqual(RegionalBusFeed.failedAfterRefresh(asked: ["CTT"], failed: []), [], "downloaded again: no longer failed")
        XCTAssertEqual(RegionalBusFeed.failedAfterRefresh(asked: [], failed: []), [], "no stop of it nearby: forgotten")
        XCTAssertEqual(RegionalBusFeed.failedAfterRefresh(asked: ["BXL"], failed: ["CTT", "BXL"]), ["BXL"], "only those asked")
        XCTAssertEqual(RegionalBusFeed.feed(code: "NICE")?.canBeLive, false)
        XCTAssertEqual(RegionalBusFeed.failedAfterRefresh(asked: ["NICE"], failed: ["NICE"]), [])
    }

    /// Live data keeps only nearby trips; errors when it isn't protobuf (text returned for a bad token)
    func testRealtimeKeepsNearbyTrips() throws {
        let ctt = try XCTUnwrap(RegionalBusFeed.feed(code: "CTT"))
        let data = tripUpdates([("T1", now), ("T9", now)])
        let all = try ctt.realtime(from: data, fetchedAt: now)
        XCTAssertEqual(Set(all.trips.keys), ["T1", "T9"])
        XCTAssertEqual(all.prefix, "njb:CTT/")
        let near = try ctt.realtime(from: data, fetchedAt: now, keep: ["njb:CTT/T1", "njb:T9"])
        XCTAssertEqual(Set(near.trips.keys), ["T1"])
        XCTAssertThrowsError(try ctt.realtime(from: Data("{}".utf8), fetchedAt: now))
    }

    /// PVTA's live data names trips by their block and the time they leave their first stop, both in hexadecimal ("t4BA-b5F-sl5"
    /// is block 95 leaving at 12:10): its trips are stored under the same two and their service, and each live trip goes to the
    /// stored ones with the same two (a weekday's and a Saturday's here; only the weekday's runs today). A trip without a block,
    /// or with the same two as an earlier one of its service, keeps its own ID; one after midnight (24:30) counts from midnight
    func testPVTALiveDataByBlockAndFirstDeparture() throws {
        XCTAssertEqual(BlockTripID.key(live: "t735-b5F-sl5"), "b95-t1845")
        XCTAssertEqual(BlockTripID.key(live: "t97E-b5F-sl5"), "b95-t30")
        XCTAssertEqual(BlockTripID.key(live: "t1E-b5F-sl5"), "b95-t30")
        XCTAssertNil(BlockTripID.key(live: "1074964"))
        XCTAssertNil(BlockTripID.key(live: "t735-sl5"))
        XCTAssertEqual(BlockTripID.stored(block: "95", firstDeparture: 18 * 3600 + 45 * 60, service: "WK"), "b95-t1845@WK")
        XCTAssertEqual(BlockTripID.stored(block: "095", firstDeparture: 24 * 3600 + 30 * 60, service: "WK"), "b95-t30@WK")
        XCTAssertNil(BlockTripID.stored(block: "", firstDeparture: 0, service: "WK"))
        XCTAssertNil(BlockTripID.stored(block: "X1", firstDeparture: 0, service: "WK"))
        XCTAssertEqual(BlockTripID.key(stored: "b95-t1845@WK"), "b95-t1845")
        XCTAssertNil(BlockTripID.key(stored: "T1"))
        XCTAssertNil(BlockTripID.key(stored: "bus@1"))

        let pvta = try XCTUnwrap(RegionalBusFeed.feed(code: "PVTA"))
        XCTAssertEqual(RegionalBusFeed.builtIn.filter(\.tripsByBlock).map(\.code), ["PVTA"])
        var f = files
        f["routes.txt"] = d("route_id,route_short_name,route_long_name,route_type\nB43,B43,Northampton-Amherst,3")
        f["stops.txt"] = d("stop_id,stop_name,stop_lat,stop_lon\nA1,Amherst Center,42.3760,-72.5190\nN1,Northampton,42.3180,-72.6300")
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,block_id
        B43,WK,1001,Northampton,0,95
        B43,SA,2001,Northampton,0,95
        B43,WK,1002,Northampton,0,
        B43,WK,1003,Northampton,0,95
        B43,WK,1004,Northampton,0,95
        """)
        f["stop_times.txt"] = d("""
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        1001,12:10:00,12:10:00,A1,1
        1001,12:40:00,12:40:00,N1,2
        2001,12:10:00,12:10:00,A1,1
        2001,12:40:00,12:40:00,N1,2
        1002,12:20:00,12:20:00,A1,1
        1002,12:50:00,12:50:00,N1,2
        1003,24:30:00,24:30:00,A1,1
        1003,25:00:00,25:00:00,N1,2
        1004,12:10:00,12:10:00,A1,1
        1004,12:45:00,12:45:00,N1,2
        """)
        f["calendar.txt"] = d("""
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        WK,1,1,1,1,1,0,0,20260901,20261231
        SA,0,0,0,0,0,1,0,20260901,20261231
        """)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: f, now: now, feed: pvta), feed: pvta)
        let slice = index.slice(near: Coordinate(latitude: 42.3760, longitude: -72.5190), radiusMeters: 500)
        let keep = Set(slice.trips.map(\.id))
        XCTAssertEqual(keep, ["njb:PVTA/b95-t1210@WK", "njb:PVTA/b95-t1210@SA", "njb:PVTA/1002", "njb:PVTA/b95-t30@WK",
                              "njb:PVTA/1004"])
        // Block 95's 12:10 is 3 minutes late at Amherst Center; the bus without a block is named by its own ID
        let rt = try pvta.realtime(from: tripUpdates([("t4BA-b5F-sl5", now.addingTimeInterval(13 * 60)),
                                                      ("1002", now.addingTimeInterval(22 * 60)),
                                                      ("t97E-b5F-sl5", now.addingTimeInterval(12.5 * 3600)),
                                                      ("t4BA-b60-sl5", now)], stop: "A1"),
                                   fetchedAt: now, keep: keep)
        XCTAssertEqual(Set(rt.trips.keys), ["b95-t1210@WK", "b95-t1210@SA", "1002", "b95-t30@WK"])
        let arrivals = slice.arrivals(pierIDs: ["njb:PVTA/A1"], from: now, to: now.addingTimeInterval(3600), realtime: [rt], now: now)
        let late = try XCTUnwrap(arrivals.first { $0.id.contains("b95-t1210@WK|") })
        XCTAssertEqual(late.source, .realtime)
        XCTAssertEqual(late.arrivalTime, now.addingTimeInterval(13 * 60))
        XCTAssertEqual(arrivals.first { $0.id.contains("1002|") }?.arrivalTime, now.addingTimeInterval(22 * 60))
        XCTAssertFalse(arrivals.contains { $0.id.contains("@SA|") })
        // Without the trips to keep there's nothing to match the blocks against
        XCTAssertEqual(Set(try pvta.realtime(from: tripUpdates([("t4BA-b5F-sl5", now), ("1002", now)]), fetchedAt: now).trips.keys),
                       ["1002"])
    }

    /// A trip leaving after midnight is at 24:xx of the day before in its timetable: live data giving it the date it leaves on (as
    /// CTtransit's does) matches it, and so does its timetable's day; any other date doesn't, nor the next date for a daytime trip
    func testTripAfterMidnightMatchesEitherStartDate() throws {
        let ctt = try XCTUnwrap(RegionalBusFeed.feed(code: "CTT"))
        var f = files
        f["routes.txt"] = d("route_id,route_short_name,route_long_name,route_type\n101,101,Asylum Hill,3")
        f["stops.txt"] = d("stop_id,stop_name,stop_lat,stop_lon\nX1,Hartford Union Station,41.7690,-72.6820\nX2,Bloomfield,41.8260,-72.7300")
        f["trips.txt"] = d("route_id,service_id,trip_id,trip_headsign,direction_id\n101,WK,N1,Bloomfield,0")
        f["stop_times.txt"] = d("""
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        N1,24:30:00,24:30:00,X1,1
        N1,24:50:00,24:50:00,X2,2
        """)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: f, now: now, feed: ctt), feed: ctt)
        let slice = index.slice(near: Coordinate(latitude: 41.7690, longitude: -72.6820), radiusMeters: 500)
        let keep = Set(slice.trips.map(\.id))
        XCTAssertEqual(keep, ["njb:CTT/N1"])
        // Thursday 00:20: N1 leaves Union Station at 00:30 (Wednesday's 24:30), predicted 4 minutes late
        let night = now.addingTimeInterval(12 * 3600 + 20 * 60)
        let predicted = night.addingTimeInterval(14 * 60)
        func shown(_ startDate: String) throws -> Arrival? {
            let rt = try ctt.realtime(from: tripUpdates([("N1", predicted)], stop: "X1", startDate: startDate, at: night),
                                      fetchedAt: night, keep: keep)
            return slice.arrivals(pierIDs: ["njb:CTT/X1"], from: night, to: night.addingTimeInterval(3600), realtime: [rt], now: night)
                .first { $0.id.hasPrefix("njb:CTT/N1|") }
        }
        for date in ["20261015", "20261014"] {
            let n1 = try XCTUnwrap(try shown(date))
            XCTAssertEqual(n1.source, .realtime, date)
            XCTAssertEqual(n1.arrivalTime, predicted, date)
        }
        for date in ["20261016", "20261013"] {
            let n1 = try XCTUnwrap(try shown(date))
            XCTAssertEqual(n1.source, .scheduled, date)
            XCTAssertEqual(n1.arrivalTime, night.addingTimeInterval(10 * 60), date)
        }
        XCTAssertTrue(FerryRealtime.startDate("20261014", matches: 20261014, firstDeparture: 12 * 3600 + 30 * 60))
        XCTAssertFalse(FerryRealtime.startDate("20261015", matches: 20261014, firstDeparture: 12 * 3600 + 30 * 60))
        XCTAssertFalse(FerryRealtime.startDate("20261015", matches: 20261014, firstDeparture: 23 * 3600 + 59 * 60))
        XCTAssertTrue(FerryRealtime.startDate("20261015", matches: 20261014, firstDeparture: 24 * 3600))
        XCTAssertFalse(FerryRealtime.startDate("20261015", matches: 20261014, firstDeparture: nil))
        XCTAssertFalse(FerryRealtime.startDate("2026-10-15", matches: 20261014, firstDeparture: 24 * 3600))
        // The day after the last of a month and of a year
        XCTAssertTrue(FerryRealtime.startDate("20261101", matches: 20261031, firstDeparture: 25 * 3600))
        XCTAssertTrue(FerryRealtime.startDate("20270101", matches: 20261231, firstDeparture: 24 * 3600 + 5 * 60))
    }

    /// Several trips' predicted times, each at several stops
    private func liveTrips(_ trips: [(id: String, stops: [(String, Date)])], at time: Date? = nil) -> Data {
        var feed = Proto()
        feed.message(1) { h in h.string(1, "2.0"); h.int(3, UInt64((time ?? now).timeIntervalSince1970)) }
        for trip in trips {
            feed.message(2) { e in
                e.string(1, trip.id)
                e.message(3) { tu in
                    tu.message(1) { t in t.string(1, trip.id) }
                    for (stop, time) in trip.stops {
                        tu.message(2) { s in
                            s.message(2) { a in a.int(2, UInt64(time.timeIntervalSince1970)) }
                            s.string(4, stop)
                        }
                    }
                }
            }
        }
        return Data(feed.bytes)
    }

    /// A small timetable like FRTA's, around a transit center in Greenfield (J): two loops leaving it (20, 21) that share its
    /// first two stops (J, A), and a route to Northampton (31), one of whose trips leaves after midnight (24:30) and one comes back
    /// to Greenfield, stopping across the street from A (A2, 24 m away). Route 20 has two trips 10 minutes apart and a third an
    /// hour later. No trip stops at N, 37 m from Northampton's stop. With `orange`, a route to Orange (32) too: its 8:00 trip
    /// stops at M on the way, its 12:00 trip doesn't
    private func frtaLike(_ code: String, orange: Bool = false) throws -> (feed: RegionalBusFeed, slice: FerryFeed) {
        let feed = try XCTUnwrap(RegionalBusFeed.feed(code: code))
        var f = files
        f["routes.txt"] = d("""
        route_id,route_short_name,route_long_name,route_type
        20,20,GreenLink,3
        21,21,Greenfield,3
        31,31,Northampton,3
        \(orange ? "32,32,Orange,3" : "")
        """)
        f["stops.txt"] = d("""
        stop_id,stop_name,stop_lat,stop_lon
        J,Transit Center,42.5876,-72.5995
        A,Main St at Federal St,42.5880,-72.6010
        A2,Main St at Federal St,42.5882,-72.6011
        B,Federal St at Silver St,42.5920,-72.6000
        C,Leyden Woods,42.6050,-72.6100
        F,Wells St,42.5800,-72.5900
        G,Community College,42.5990,-72.6220
        D,Deerfield,42.5450,-72.6060
        E,Northampton,42.3180,-72.6300
        N,Northampton,42.3183,-72.6302
        H,Shelburne Rd,42.5950,-72.6300
        M,Meadows,42.6000,-72.6400
        K,Colrain Rd,42.6100,-72.6500
        L,Orange,42.5900,-72.3100
        """)
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id
        20,WK,T20a,,0
        20,WK,T20b,,0
        20,WK,T20c,,0
        21,WK,T21a,,0
        31,WK,T31a,Northampton,0
        31,WK,T31b,Northampton,0
        31,WK,T31n,Northampton,0
        31,WK,T31r,Greenfield,1
        \(orange ? "32,WK,T32m,Orange,0\n32,WK,T32p,Orange,0" : "")
        """)
        var times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
        var stopTimes: [(String, [(String, String)])] = [
            ("T20a", [("J", "12:00"), ("A", "12:02"), ("B", "12:04"), ("C", "12:10"), ("J", "12:20")]),
            ("T20b", [("J", "12:10"), ("A", "12:12"), ("B", "12:14"), ("C", "12:20"), ("J", "12:30")]),
            ("T20c", [("J", "13:00"), ("A", "13:02"), ("B", "13:04"), ("C", "13:10"), ("J", "13:20")]),
            ("T21a", [("J", "12:00"), ("A", "12:02"), ("F", "12:06"), ("G", "12:12"), ("J", "12:25")]),
            ("T31a", [("J", "12:30"), ("A", "12:32"), ("D", "12:45"), ("E", "13:30")]),
            ("T31b", [("J", "13:30"), ("A", "13:32"), ("D", "13:45"), ("E", "14:30")]),
            ("T31n", [("J", "24:30"), ("A", "24:32"), ("D", "24:45"), ("E", "25:30")]),
            ("T31r", [("E", "14:00"), ("D", "14:45"), ("A2", "14:58"), ("J", "15:00")]),
        ]
        if orange {
            stopTimes += [("T32m", [("J", "08:00"), ("H", "08:05"), ("M", "08:10"), ("K", "08:20"), ("L", "08:30")]),
                          ("T32p", [("J", "12:00"), ("H", "12:05"), ("K", "12:20"), ("L", "12:30")])]
        }
        for (trip, stops) in stopTimes {
            for (n, (stop, time)) in stops.enumerated() { times += "\(trip),\(time):00,\(time):00,\(stop),\(n + 1)\n" }
        }
        f["stop_times.txt"] = d(times)
        let index = try NJBusIndex(data: try NJBusBuilder.build(files: f, now: now, feed: feed), feed: feed)
        return (feed, index.slice(near: Coordinate(latitude: 42.5880, longitude: -72.6010), radiusMeters: 500))
    }

    /// 12:00 plus these minutes, on the Wednesday of these tests
    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// A company whose live trips are named in ways its timetable doesn't (FRTA's) gets them matched by their stops and times:
    /// the one stored trip that day that stops at every one of a live trip's stops in its timetable (at least two), with every
    /// prediction from 5 minutes early to 15 minutes late. Stops not in its timetable don't count. Its whole timetable comes with
    /// the nearby piece for this; a company that doesn't go this way gets neither
    func testLiveTripsByStopsAndTime() throws {
        let (frta, slice) = try frtaLike("FRTA")
        let whole = try XCTUnwrap(slice.wholeTimetables?["njb:FRTA/"])
        XCTAssertEqual(whole.trips.count, 8)
        XCTAssertEqual(whole.trips.first { $0.id == "njb:FRTA/T31a" }?.stops,
                       ["njb:FRTA/J", "njb:FRTA/A", "njb:FRTA/D", "njb:FRTA/E"])
        // The nearby piece keeps only the stops near here (and the last), the whole timetable all of them
        XCTAssertEqual(slice.trips.first { $0.id == "njb:FRTA/T31a" }?.stops, ["njb:FRTA/J", "njb:FRTA/A", "njb:FRTA/E"])
        let keep = Set(slice.trips.map(\.id))
        let data = liveTrips([
            // 21's 12:00, a minute late: 20's 12:00 and 12:10 stop at J and A too, but not at F and G
            ("t_100_b_9_tn_0", [("J", at(1)), ("A", at(3)), ("F", at(7)), ("G", at(13)), ("J", at(26))]),
            // 31's 12:30, named as another copy of the timetable numbers it, with a stop only that copy has: P1
            ("1076176", [("P1", at(30)), ("A", at(33)), ("D", at(46)), ("E", at(91))]),
            // 20's 13:00 near its end: the loop's last stop is the one it started from
            ("t_300_b_9_tn_0", [("C", at(71)), ("J", at(81))]),
            // One stop of its timetable and one of the other copy's: not enough
            ("t_400_b_9_tn_0", [("J", at(5)), ("P1", at(6))]),
        ])
        let rt = try frta.realtime(from: data, fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(Set(rt.trips.keys), ["T21a", "T31a", "T20c"])
        // All three matched ones still have a stop near here ahead of them (J or A, from now on)
        XCTAssertEqual(rt.matching, LiveMatching(total: 4, byStopsAndTimeOn: true, nearby: 4, nearbyByID: 0, byID: 0,
                                                 byStopsAndTime: 3, nearbyByStopsAndTime: 3, nearbyStillToStop: 3,
                                                 unmatched: [.fewStops: 1]))
        XCTAssertEqual(rt.matching?.logLine(name: "FRTA"),
                       "live trips: FRTA 4 in the data, by trip ID 0, by stops and time 3 (3 near here, 3 still to stop here, "
                       + "0 with a stop left out), "
                       + "not matched 1: fewer than 2 stops 1")
        let arrivals = slice.arrivals(pierIDs: ["njb:FRTA/A"], from: now, to: at(60), realtime: [rt], now: now)
        let t21 = try XCTUnwrap(arrivals.first { $0.id.hasPrefix("njb:FRTA/T21a|") })
        XCTAssertEqual(t21.source, .realtime)
        XCTAssertEqual(t21.arrivalTime, at(3))
        let t31 = try XCTUnwrap(arrivals.first { $0.id.hasPrefix("njb:FRTA/T31a|") })
        XCTAssertEqual(t31.source, .realtime)
        XCTAssertEqual(t31.arrivalTime, at(33))
        // 20's 12:10 has no live trip: its timetable time
        XCTAssertEqual(arrivals.first { $0.id.hasPrefix("njb:FRTA/T20b|") }?.source, .scheduled)

        // After midnight: 31's 24:30 of Wednesday leaves at 0:30 on Thursday
        let night = at(12 * 60 + 31)
        let late = try frta.realtime(from: liveTrips([("t_500_b_9_tn_0", [("J", at(12 * 60 + 31)), ("A", at(12 * 60 + 33))])], at: night),
                                     fetchedAt: night, keep: keep, nearby: slice)
        XCTAssertEqual(Set(late.trips.keys), ["T31n"])
        let shown = slice.arrivals(pierIDs: ["njb:FRTA/A"], from: night, to: night.addingTimeInterval(3600), realtime: [late], now: night)
        XCTAssertEqual(shown.first { $0.id.hasPrefix("njb:FRTA/T31n|") }?.arrivalTime, at(12 * 60 + 33))

        // Without the nearby piece there's nothing to match against, and no count
        let alone = try frta.realtime(from: data, fetchedAt: now, keep: keep)
        XCTAssertTrue(alone.trips.isEmpty)
        XCTAssertNil(alone.matching)

        // A company whose live trips go by trip ID: no whole timetable, none matched this way. With 3 or more live trips near here
        // and none of them named by a trip ID of its timetable, the log says so
        let (wrtd, other) = try frtaLike("WRTD")
        XCTAssertNil(other.wholeTimetables)
        let byID = try wrtd.realtime(from: data, fetchedAt: now, keep: Set(other.trips.map(\.id)), nearby: other)
        XCTAssertTrue(byID.trips.isEmpty)
        XCTAssertEqual(byID.matching?.logLine(name: "WRTD"), "live trips: WRTD 4 near here, none named by a trip ID of its timetable")
        let named = try wrtd.realtime(from: liveTrips([("T21a", [("J", at(1))]), ("x1", [("A", at(2))]), ("x2", [("J", at(3))])]),
                                      fetchedAt: now, keep: Set(other.trips.map(\.id)), nearby: other)
        XCTAssertEqual(Set(named.trips.keys), ["T21a"])
        XCTAssertNil(named.matching?.logLine(name: "WRTD"))
        // Merged with another company's piece, each keeps its own whole timetable
        XCTAssertEqual(FerryFeed.combining([other, slice])?.wholeTimetables?.keys.sorted(), ["njb:FRTA/"])
    }

    /// Live trips that could be the wrong one aren't matched by stops and time: too late or too early, predictions bunched or
    /// running backwards, two stored trips fitting, one fitting with another close (10 minutes early to 25 late), a stored trip
    /// two live trips fit (or that a live trip names by its own ID), and stops no one trip stops at all of
    func testLiveTripsByStopsAndTimeLeaveOutUnsureOnes() throws {
        let (frta, slice) = try frtaLike("FRTA")
        let keep = Set(slice.trips.map(\.id))
        func result(_ trips: [(id: String, stops: [(String, Date)])]) throws -> FerryRealtime {
            try frta.realtime(from: liveTrips(trips), fetchedAt: now, keep: keep, nearby: slice)
        }
        // 16 minutes late for 20's 12:10 (and 26 for its 12:00); 6 minutes early for 21's 12:00
        var rt = try result([("late", [("B", at(30)), ("C", at(36))]), ("early", [("F", at(0)), ("G", at(6))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 2])
        // 31's 13:30: stops 13 minutes apart predicted 5 apart; 21's 12:00 predicted backwards
        rt = try result([("bunched", [("A", at(96)), ("D", at(101))]), ("backwards", [("J", at(3)), ("A", at(1))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.bunched: 2])
        // 9 minutes into 20's 12:00 is a minute before its 12:10: either could be it
        rt = try result([("either", [("J", at(9)), ("A", at(11)), ("B", at(13))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.twoFit: 1])
        // 6 minutes late for 20's 12:10 is 16 late for its 12:00 and for 21's 12:00, which stop at J and A too: too close
        rt = try result([("close", [("J", at(16)), ("A", at(18))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.closeToAnother: 1])
        // Two live trips fitting 20's 13:00
        rt = try result([("one", [("B", at(65)), ("C", at(71))]), ("other", [("J", at(61)), ("A", at(63)), ("B", at(65))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.sameTrip: 2])
        // 21's 12:00 named by its own ID keeps its live trip; another fitting it gets none
        rt = try result([("T21a", [("F", at(7))]), ("again", [("F", at(7)), ("G", at(13))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T21a"])
        XCTAssertEqual(rt.trips["T21a"]?.stopTimes.count, 1)
        XCTAssertEqual(rt.matching?.byID, 1)
        XCTAssertEqual(rt.matching?.unmatched, [.sameTrip: 1])
        // B and F: no trip stops at both
        rt = try result([("nowhere", [("B", at(4)), ("F", at(6))])])
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        XCTAssertEqual(rt.matching?.logLine(name: "FRTA"),
                       "live trips: FRTA 1 in the data, by trip ID 0, by stops and time 0 (0 near here, 0 still to stop here, "
                       + "0 with a stop left out), "
                       + "not matched 1: no trip stops at all of them 1")
        // Exactly at the edges: 5 minutes early and 15 late still fit
        rt = try result([("edge", [("F", at(1)), ("G", at(27))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T21a"])
    }

    /// Matching by stops and time, a stop within 100 m of one the trips stop at counts as that one: the live data names one stop
    /// for both directions where the timetable has one on each side of the street, or one no trip stops at. When no trip stops at
    /// all of a live trip's stops and it has 4 or more, one of them may be left out, each one in turn
    func testLiveTripsByStopsAndTimeNearbyStopsAndOneLeftOut() throws {
        let (frta, slice) = try frtaLike("FRTA")
        let whole = try XCTUnwrap(slice.wholeTimetables?["njb:FRTA/"])
        // J is 130 m from A, too far. E isn't near N, as no trip stops at N
        XCTAssertEqual(whole.nearbyStops, ["njb:FRTA/A": ["njb:FRTA/A2"], "njb:FRTA/A2": ["njb:FRTA/A"], "njb:FRTA/N": ["njb:FRTA/E"]])
        let keep = Set(slice.trips.map(\.id))
        func result(_ trips: [(id: String, stops: [(String, Date)])]) throws -> FerryRealtime {
            try frta.realtime(from: liveTrips(trips), fetchedAt: now, keep: keep, nearby: slice)
        }
        // 31's 14:00 back to Greenfield, named by N and by A across the street, a minute late
        var rt = try result([("t_600_b_9_tn_0", [("N", at(120)), ("D", at(166)), ("A", at(179)), ("J", at(181))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T31r"])
        // 21's 12:00 with B, where only 20's trips stop: left out
        rt = try result([("t_100_b_9_tn_0", [("J", at(1)), ("A", at(3)), ("B", at(5)), ("F", at(7)), ("G", at(13)), ("J", at(26))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T21a"])
        XCTAssertEqual(rt.matching?.logLine(name: "FRTA"),
                       "live trips: FRTA 1 in the data, by trip ID 0, by stops and time 1 (1 near here, 1 still to stop here, "
                       + "1 with a stop left out), "
                       + "not matched 0")
        // 31's 14:00, 4 minutes late, with Northampton's stop between D and A: it stops there, but at 14:00. Leaving out D first
        // puts E there, 50 minutes late; leaving out E is the one that fits
        rt = try result([("t_700_b_9_tn_0", [("D", at(169)), ("E", at(170)), ("A", at(182)), ("J", at(184))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T31r"])
        XCTAssertEqual(rt.matching?.leavingOneOut, 1)
        // Only 3 stops: none left out
        rt = try result([("t_800_b_9_tn_0", [("A", at(3)), ("B", at(5)), ("F", at(7))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        // Two stops off 21's 12:00: still no trip
        rt = try result([("t_900_b_9_tn_0", [("J", at(1)), ("A", at(3)), ("B", at(5)), ("C", at(6)), ("F", at(7)), ("G", at(13))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
    }

    /// The log tells the matched trips near here that still have a stop near here ahead of them (a predicted time there from now
    /// on) from those that have gone by, which no row of the board can show as live
    func testLiveTripsStillToStopHere() throws {
        let (frta, slice) = try frtaLike("FRTA")
        let keep = Set(slice.trips.map(\.id))
        func result(_ trips: [(id: String, stops: [(String, Date)])]) throws -> FerryRealtime {
            try frta.realtime(from: liveTrips(trips), fetchedAt: now, keep: keep, nearby: slice)
        }
        // 21's 12:00, a minute late, with only its stops after J and A left in the live data: it has gone by here
        var rt = try result([("t_100_b_9_tn_0", [("F", at(7)), ("G", at(13))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T21a"])
        XCTAssertEqual(rt.matching?.nearbyByStopsAndTime, 1)
        XCTAssertEqual(rt.matching?.nearbyStillToStop, 0)
        XCTAssertEqual(rt.matching?.logLine(name: "FRTA"),
                       "live trips: FRTA 1 in the data, by trip ID 0, by stops and time 1 (1 near here, 0 still to stop here, "
                       + "0 with a stop left out), not matched 0")
        // The same bus with A still ahead of it
        rt = try result([("t_100_b_9_tn_0", [("A", at(3)), ("F", at(7)), ("G", at(13))])])
        XCTAssertEqual(rt.matching?.nearbyStillToStop, 1)
        // A time at A that has already passed doesn't count
        rt = try frta.realtime(from: liveTrips([("t_100_b_9_tn_0", [("A", at(3)), ("F", at(7)), ("G", at(13))])]),
                               fetchedAt: at(4), keep: keep, nearby: slice)
        XCTAssertEqual(Set(rt.trips.keys), ["T21a"])
        XCTAssertEqual(rt.matching?.nearbyStillToStop, 0)
    }

    /// Matching by stops and time, a stop may be left out too when trips do stop at all of a live trip's stops, but only at
    /// another time of day: the live data names a stop that only some of the route's trips have. A trip that stops at all of
    /// them and could be this bus (15 minutes early to 45 late at every stop) keeps the answer it gave, so a trip late past
    /// the limit at one of its own stops isn't matched without that stop
    func testLiveTripsByStopsAndTimeOneLeftOutWhenOnlyOtherHoursStopAtAll() throws {
        let (frta, slice) = try frtaLike("FRTA", orange: true)
        let keep = Set(slice.trips.map(\.id))
        func result(_ trips: [(id: String, stops: [(String, Date)])]) throws -> FerryRealtime {
            try frta.realtime(from: liveTrips(trips), fetchedAt: now, keep: keep, nearby: slice)
        }
        // 32's 12:00, a minute late, named with M: only its 8:00 trip stops at all five, 4 hours earlier
        var rt = try result([("t_100_b_7_tn_0", [("J", at(1)), ("H", at(6)), ("M", at(11)), ("K", at(21)), ("L", at(31))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T32p"])
        XCTAssertEqual(rt.matching?.logLine(name: "FRTA"),
                       "live trips: FRTA 1 in the data, by trip ID 0, by stops and time 1 (1 near here, 1 still to stop here, "
                       + "1 with a stop left out), "
                       + "not matched 0")
        // The same with its last two stops 40 minutes late: no trip fits without M either, and the times are what's off
        rt = try result([("t_200_b_7_tn_0", [("J", at(1)), ("H", at(6)), ("M", at(11)), ("K", at(60)), ("L", at(70))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 1])
        // Only 3 stops: none left out
        rt = try result([("t_300_b_7_tn_0", [("J", at(1)), ("H", at(6)), ("M", at(11))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 1])
        // 21's 12:00 with its first stop 26 minutes late and the others 2: it could be this bus, so its first stop isn't left out
        rt = try result([("t_400_b_7_tn_0", [("J", at(26)), ("A", at(4)), ("F", at(8)), ("G", at(14)), ("J", at(27))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 1])
        XCTAssertEqual(rt.matching?.leavingOneOut, 0)
        // 45 minutes late at every stop of 32's 12:00 could still be it, a second more could not
        XCTAssertTrue(RegionalBusFeed.possibleWindow.contains(45 * 60))
        XCTAssertFalse(RegionalBusFeed.possibleWindow.contains(45 * 60 + 1))
        XCTAssertTrue(RegionalBusFeed.possibleWindow.contains(-15 * 60))
    }

    /// Matching by stops and time, a prediction earlier than the timetable at a trip's own first stop counts as on time: a bus
    /// waiting to leave is predicted there now. At any other stop, more than 5 minutes early doesn't fit
    func testLiveTripsByStopsAndTimeEarlyAtTheFirstStop() throws {
        let (frta, slice) = try frtaLike("FRTA")
        let keep = Set(slice.trips.map(\.id))
        func result(_ trips: [(id: String, stops: [(String, Date)])]) throws -> FerryRealtime {
            try frta.realtime(from: liveTrips(trips), fetchedAt: now, keep: keep, nearby: slice)
        }
        // 31's 12:30 waiting at the transit center, predicted there 19.5 minutes before it leaves; on time at its other stops
        var rt = try result([("t_100_b_5_tn_0", [("J", at(10.5)), ("A", at(32)), ("D", at(45)), ("E", at(91))])])
        XCTAssertEqual(Set(rt.trips.keys), ["T31a"])
        XCTAssertEqual(rt.matching?.leavingOneOut, 0)
        // The prediction itself stays as the live data has it
        XCTAssertEqual(rt.trips["T31a"]?.stopTimes.first?.time, at(10.5))
        // 19.5 minutes early at its second stop instead
        rt = try result([("t_200_b_5_tn_0", [("A", at(12.5)), ("D", at(45)), ("E", at(91))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 1])
        // Early at the first stop and late past the limit at another: still off
        rt = try result([("t_300_b_5_tn_0", [("J", at(10.5)), ("A", at(48)), ("D", at(61)), ("E", at(106))])])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.timesOff: 1])
    }

    // MARK: NJ Transit's buses: live trips by stop codes and schedule

    /// A small timetable like NJ Transit's, around Newark Penn Station, each stop with a code other than its ID. Routes 1 and 2 go
    /// from Broad St (code 20001) by Newark Penn (20002) to Journal Square (20005) at the same times there, by other stops in
    /// between, none of them near Newark: route 1 by Harrison (20004) and Kearny (20007), route 2 by Lincoln Hwy (20009) and
    /// Marion (20010). Route 1's trips leave Broad St at 12:10 and 13:10 (trips A1 and B1), on Sundays only at 12:50 (trip S1),
    /// and after midnight at 24:10 (trip N1); route 2's at 12:10 (trip A2). Route 3's comes back from Journal Square at 12:00
    /// (trip C3), by a stop that has no code
    private func njTransitLike(_ feed: RegionalBusFeed = .njTransit) throws -> (index: NJBusIndex, data: Data, slice: FerryFeed) {
        var f: [String: Data] = [:]
        f["routes.txt"] = d("""
        route_id,agency_id,route_short_name,route_long_name,route_type,route_color
        1,NJB,1,,3,000000
        2,NJB,2,,3,000000
        3,NJB,3,,3,000000
        """)
        f["stops.txt"] = d("""
        stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id
        101,20001,BROAD ST AT MARKET ST,,40.735600,-74.171900,1
        102,20002,NEWARK PENN STATION,,40.734500,-74.164200,1
        104,20004,HARRISON AVE AT 5TH ST,,40.745000,-74.130000,1
        105,20005,JOURNAL SQUARE TRANSPORTATION CENTER,,40.732900,-74.063600,2
        107,20007,KEARNY AVE AT BERGEN AVE,,40.760000,-74.120000,1
        108,,COMMUNIPAW AVE AT WEST SIDE AVE,,40.720000,-74.080000,2
        109,20009,LINCOLN HWY AT DUNCAN AVE,,40.730000,-74.100000,2
        110,20010,MARION,,40.731000,-74.080000,2
        """)
        f["trips.txt"] = d("""
        route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
        1,WK,A1,1 JERSEY CITY JOURNAL SQ,0,1,
        1,WK,B1,1 JERSEY CITY JOURNAL SQ,0,1,
        1,SU,S1,1 JERSEY CITY JOURNAL SQ,0,1,
        1,WK,N1,1 JERSEY CITY JOURNAL SQ,0,1,
        2,WK,A2,2 JERSEY CITY JOURNAL SQ,0,2,
        3,WK,C3,3 NEWARK BROAD ST,1,3,
        """)
        let stopTimes: [(String, [(String, String)])] = [
            ("A1", [("101", "12:10"), ("102", "12:14"), ("104", "12:22"), ("107", "12:30"), ("105", "12:40")]),
            ("B1", [("101", "13:10"), ("102", "13:14"), ("104", "13:22"), ("107", "13:30"), ("105", "13:40")]),
            ("S1", [("101", "12:50"), ("102", "12:54"), ("104", "13:02"), ("107", "13:10"), ("105", "13:20")]),
            ("N1", [("101", "24:10"), ("102", "24:14"), ("104", "24:22"), ("107", "24:30"), ("105", "24:40")]),
            ("A2", [("101", "12:10"), ("102", "12:14"), ("109", "12:24"), ("110", "12:32"), ("105", "12:40")]),
            ("C3", [("105", "12:00"), ("108", "12:15"), ("102", "12:26"), ("101", "12:30")]),
        ]
        var times = "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type\n"
        for (trip, stops) in stopTimes {
            for (n, (stop, time)) in stops.enumerated() { times += "\(trip),\(time):00,\(time):00,\(stop),\(n + 1),0,0\n" }
        }
        f["stop_times.txt"] = d(times)
        f["calendar_dates.txt"] = d("""
        service_id,date,exception_type
        WK,20261013,1
        WK,20261014,1
        WK,20261015,1
        SU,20261018,1
        """)
        let data = try NJBusBuilder.build(files: f, now: now, feed: feed)
        let index = try NJBusIndex(data: data, feed: feed)
        return (index, data, index.slice(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500))
    }

    /// A stop of a live trip as NJ Transit's bus data gives it: the stop's code (a terminal's bay: the code, a dash and the bay),
    /// and a predicted time with its delay, the same for arriving and leaving. A NO_DATA stop, or one with no time, has neither
    private struct CodedStop {
        var code: String
        var time: Date?
        var delay = 0
        var noData = false
    }

    /// Live trips as NJ Transit's bus data gives them: a trip ID of another numbering, no route and no start date, every stop
    /// by its code; updated: each trip's own time (none when nil)
    private func codedTrips(_ trips: [(id: String, stops: [CodedStop])], at header: Date? = nil, updated: Date? = nil) -> Data {
        var feed = Proto()
        feed.message(1) { h in h.string(1, "2.0"); h.int(3, UInt64((header ?? now).timeIntervalSince1970)) }
        for trip in trips {
            feed.message(2) { e in
                e.string(1, trip.id)
                e.message(3) { tu in
                    tu.message(1) { t in t.string(1, trip.id) }
                    for (n, stop) in trip.stops.enumerated() {
                        tu.message(2) { s in
                            s.int(1, UInt64(n + 1))
                            if let time = stop.time {
                                for field in [2, 3] {
                                    s.message(field) { event in
                                        event.int(1, UInt64(bitPattern: Int64(stop.delay)))
                                        event.int(2, UInt64(time.timeIntervalSince1970))
                                    }
                                }
                            }
                            s.string(4, stop.code)
                            if stop.noData { s.int(5, 2) }
                        }
                    }
                    if let updated { tu.int(4, UInt64(updated.timeIntervalSince1970)) }
                }
            }
        }
        return Data(feed.bytes)
    }

    /// Trip IDs of these arrivals
    private func tripIDs(_ arrivals: [Arrival]) -> [String] {
        arrivals.map { $0.id.components(separatedBy: "|")[0] }
    }

    /// These stops at these minutes after noon in the live trip's own timetable (off: that many seconds later than that), each
    /// predicted `late` seconds after it
    private func coded(_ stops: [(String, Double)], late: Int = 0, off: TimeInterval = 0) -> [CodedStop] {
        stops.map { CodedStop(code: $0.0, time: at($0.1).addingTimeInterval(off + TimeInterval(late)), delay: late) }
    }

    /// NJ Transit's bus live data names trips and stops as another copy of its timetable does: its trip IDs are never the stored
    /// ones, and a stop is its code. It gives every stop a predicted time and its delay. A live trip goes to the one stored trip
    /// that day with the live trip's stops on its whole list of stop codes, at those times in the live trip's own timetable (the
    /// predicted time less the delay); the predicted times land on that trip's own stops
    func testNJTransitBusLiveTripsByStopCodesAndSchedule() throws {
        let (index, _, slice) = try njTransitLike()
        XCTAssertTrue(RegionalBusFeed.njTransit.liveByStopCodes)
        XCTAssertEqual(RegionalBusFeed.all.filter(\.liveByStopCodes), [.njTransit])
        // The file keeps every stop's code, "" for the one without
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: zip(index.stopIDs, index.stopCodes)),
                       ["101": "20001", "102": "20002", "104": "20004", "105": "20005", "107": "20007", "108": "",
                        "109": "20009", "110": "20010"])
        // The nearby piece keeps each trip's stops near here and its last; its whole list of codes comes with it, with the
        // places of those stops in it. Trips with the same stops share one list
        let lists = try XCTUnwrap(slice.stopCodeLists?["njb:"])
        XCTAssertEqual(lists.lists.count, 3)
        let route1 = try XCTUnwrap(lists.listOfTrip["njb:A1"])
        XCTAssertEqual(lists.lists[route1], ["20001", "20002", "20004", "20007", "20005"])
        XCTAssertEqual(lists.kept[route1], [0, 1, 4])
        XCTAssertEqual(slice.trips.first { $0.id == "njb:A1" }?.stops, ["njb:101", "njb:102", "njb:105"])
        XCTAssertEqual(["njb:B1", "njb:S1", "njb:N1"].map { lists.listOfTrip[$0] }, [route1, route1, route1])
        let route3 = try XCTUnwrap(lists.listOfTrip["njb:C3"])
        XCTAssertEqual(lists.lists[route3], ["20005", "", "20002", "20001"])
        XCTAssertEqual(lists.kept[route3], [2, 3])
        XCTAssertEqual(Set(lists.listOfTrip.keys), Set(slice.trips.map(\.id)))

        let keep = Set(slice.trips.map(\.id))
        let updated = now.addingTimeInterval(-20)
        let data = codedTrips([
            // Route 1's 12:10, 3 minutes late, under the live data's own number for it. Newark Penn and Journal Square are bays
            // of theirs. Route 2's 12:10 has Broad St, Newark Penn and Journal Square at the same times, but not Harrison and Kearny
            ("14000001", coded([("20001", 10), ("20002-5_2", 14), ("20004", 22), ("20007", 30), ("20005-212_1", 40)], late: 180)),
            // Route 3's 12:00, 2 minutes early: the stop with no code in the timetable has one in the live data
            ("14000002", coded([("20005", 0), ("31234", 15), ("20002", 26), ("20001", 30)], late: -120)),
            // A bus elsewhere: none of its stops is kept here
            ("14000003", coded([("20009", 24), ("20010", 32)], late: 60)),
        ], updated: updated)
        let rt = try RegionalBusFeed.njTransit.realtime(from: data, fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(rt.source, .njTransitBus)
        XCTAssertEqual(rt.prefix, "njb:")
        XCTAssertEqual(Set(rt.trips.keys), ["A1", "C3"])
        // Under the stored trip's own stop IDs, only the stops kept here, on that day, with the live trip's own time
        let a1 = try XCTUnwrap(rt.trips["A1"])
        XCTAssertEqual(a1.stopTimes.map(\.stopID), ["101", "102", "105"])
        XCTAssertEqual(a1.stopTimes.map(\.time), [at(13), at(17), at(43)])
        XCTAssertEqual(a1.startDate, "20261014")
        XCTAssertEqual(a1.timestamp, updated)
        XCTAssertFalse(a1.canceled)
        XCTAssertEqual(rt.trips["C3"]?.stopTimes.map(\.stopID), ["102", "101"])
        XCTAssertEqual(rt.trips["C3"]?.stopTimes.map(\.time), [at(24), at(28)])
        // Two of the three have a time at a stop near here; both matched, both still to stop here
        XCTAssertEqual(rt.matching, LiveMatching(total: 3, nearby: 2, nearbyStillToStop: 2, byStopCodesOn: true, byStopCodes: 2))
        XCTAssertEqual(rt.matching?.logLine(name: "NJ Transit"),
                       "live trips: NJ Transit 3 in the data, 2 at stops near here, by stop codes and schedule 2 "
                       + "(2 still to stop here), not matched 0")

        let penn = slice.arrivals(pierIDs: ["njb:102"], from: now, to: at(90), realtime: [rt], now: now)
        let live1 = try XCTUnwrap(penn.first { $0.id.hasPrefix("njb:A1|") })
        XCTAssertEqual(live1.source, .realtime)
        XCTAssertEqual(live1.arrivalTime, at(17))
        // How fresh it is: the live trip's own time (old ones are marked as the other operators' are)
        XCTAssertEqual(live1.updatedAt, updated)
        let live3 = try XCTUnwrap(penn.first { $0.id.hasPrefix("njb:C3|") })
        XCTAssertEqual(live3.source, .realtime)
        XCTAssertEqual(live3.arrivalTime, at(24))
        // Route 2's 12:10 stays the timetable's: the live trip isn't its
        let timetable2 = try XCTUnwrap(penn.first { $0.id.hasPrefix("njb:A2|") })
        XCTAssertEqual(timetable2.source, .scheduled)
        XCTAssertEqual(timetable2.arrivalTime, at(14))
        XCTAssertEqual(penn.first { $0.id.hasPrefix("njb:B1|") }?.source, .scheduled)
        // The Thursday's 12:10 is another day's trip: the live trip's times apply on its own day only
        let thursday = slice.arrivals(pierIDs: ["njb:102"], from: at(24 * 60), to: at(25 * 60), realtime: [rt], now: now)
        XCTAssertEqual(thursday.first { $0.id.hasPrefix("njb:A1|") }?.source, .scheduled)
        XCTAssertEqual(thursday.first { $0.id.hasPrefix("njb:A1|") }?.arrivalTime, at(24 * 60 + 14))

        // However late: it's the trip of its timetable time, not the one leaving near its predicted time (13:10's)
        let late = try RegionalBusFeed.njTransit.realtime(
            from: codedTrips([("14000001", coded([("20001", 10), ("20002", 14), ("20004", 22), ("20007", 30), ("20005", 40)], late: 58 * 60))]),
            fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(Array(late.trips.keys), ["A1"])
        XCTAssertEqual(late.trips["A1"]?.stopTimes.first?.time, at(68))

        // The trip_id is never used. A live trip named as a stored trip is, with another trip's stops and times, is that other
        // trip; with stops elsewhere it's nothing here
        let named = try RegionalBusFeed.njTransit.realtime(
            from: codedTrips([("B1", coded([("20001", 10), ("20002", 14), ("20004", 22), ("20007", 30), ("20005", 40)], late: 60)),
                              ("N1", coded([("20009", 24), ("20010", 32)]))]),
            fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(Array(named.trips.keys), ["A1"])

        // Without the nearby piece there's nothing to match with: no trips, and nothing counted
        let alone = try RegionalBusFeed.njTransit.realtime(from: data, fetchedAt: now, keep: keep)
        XCTAssertTrue(alone.trips.isEmpty)
        XCTAssertNil(alone.matching)
        XCTAssertThrowsError(try RegionalBusFeed.njTransit.realtime(from: Data("{}".utf8), fetchedAt: now, keep: keep, nearby: slice))
    }

    /// A live trip gets a stored trip only when exactly one fits, and a stored trip only one live trip: otherwise the timetable's
    /// times stay. One of the stops a live trip lists may be missing from the stored trip's list, not two; the times in the two
    /// timetables may be a minute apart at each stop kept here, not more; and the stored trip has to run that day
    func testNJTransitBusLiveTripsLeaveOutUnsureOnes() throws {
        let slice = try njTransitLike().slice
        let keep = Set(slice.trips.map(\.id))
        func matched(_ trips: [(id: String, stops: [CodedStop])], at time: Date? = nil) throws -> FerryRealtime {
            try RegionalBusFeed.njTransit.realtime(from: codedTrips(trips, at: time), fetchedAt: time ?? now, keep: keep, nearby: slice)
        }
        let route1: [(String, Double)] = [("20001", 10), ("20002", 14), ("20004", 22), ("20007", 30), ("20005", 40)]

        // Only the stops routes 1 and 2 share, at the times both have there: either could be it, so neither gets it
        var rt = try matched([("14000001", coded([("20001", 10), ("20002", 14), ("20005", 40)], late: 60))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.twoFit: 1])
        XCTAssertEqual(rt.matching?.logLine(name: "NJ Transit"),
                       "live trips: NJ Transit 1 in the data, 1 at stops near here, by stop codes and schedule 0 "
                       + "(0 still to stop here), not matched 1: two trips fit 1")
        let penn = slice.arrivals(pierIDs: ["njb:102"], from: now, to: at(60), realtime: [rt], now: now)
        XCTAssertEqual(Set(tripIDs(penn)), ["njb:A1", "njb:A2", "njb:C3"])
        XCTAssertTrue(penn.allSatisfy { $0.source == .scheduled })
        // One stop of route 1's doesn't tell them apart either, as one stop may be missing from a stored trip's list
        rt = try matched([("14000001", coded([("20001", 10), ("20002", 14), ("20004", 22), ("20005", 40)]))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.twoFit: 1])
        // Two do
        rt = try matched([("14000001", coded(route1))])
        XCTAssertEqual(Array(rt.trips.keys), ["A1"])

        // One stop the stored trip's list doesn't have (a stop only the live data's copy of the timetable has): still that trip
        rt = try matched([("14000001", coded([("20001", 10), ("20002", 14), ("20004", 22), ("39001", 26), ("20007", 30), ("20005", 40)]))])
        XCTAssertEqual(Array(rt.trips.keys), ["A1"])
        // Two such stops: not a trip of this timetable
        rt = try matched([("14000001", coded([("20001", 10), ("39002", 12), ("20002", 14), ("20004", 22), ("39001", 26), ("20007", 30),
                                              ("20005", 40)]))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        // The stops in another order: not that trip
        rt = try matched([("14000001", coded([("20002", 14), ("20001", 10), ("20007", 30), ("20004", 22), ("20005", 40)]))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])

        // Two live trips that are the same stored trip: neither is used
        rt = try matched([("14000001", coded(route1, late: 60)), ("14000002", coded(route1, late: 300))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.sameTrip: 2])
        XCTAssertEqual(rt.matching?.nearby, 2)

        // The two timetables a minute apart at the stops kept here: the same trip. A second more at one of them: not
        rt = try matched([("14000001", coded(route1, late: 120, off: 60))])
        XCTAssertEqual(Array(rt.trips.keys), ["A1"])
        XCTAssertEqual(rt.trips["A1"]?.stopTimes.map(\.time), [at(13), at(17), at(43)])
        rt = try matched([("14000001", coded(route1, late: 120, off: -60))])
        XCTAssertEqual(Array(rt.trips.keys), ["A1"])
        rt = try matched([("14000001", coded(route1, late: 120, off: 61))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        var oneOff = coded(route1)
        oneOff[1].time = oneOff[1].time?.addingTimeInterval(61)
        rt = try matched([("14000001", oneOff)])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        // A stop that isn't kept here isn't compared: its time in the nearby piece isn't known
        var farOff = coded(route1)
        farOff[2].time = farOff[2].time?.addingTimeInterval(600)
        rt = try matched([("14000001", farOff)])
        XCTAssertEqual(Array(rt.trips.keys), ["A1"])

        // The Sunday trip's stops and times on a Wednesday: it doesn't run, so nothing. On a Sunday it's that trip
        let sunday: [(String, Double)] = [("20001", 50), ("20002", 54), ("20004", 62), ("20007", 70), ("20005", 80)]
        rt = try matched([("14000001", coded(sunday))])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching?.unmatched, [.noTrip: 1])
        let fourDays: TimeInterval = 4 * 86400
        rt = try matched([("14000001", coded(sunday, off: fourDays))], at: now.addingTimeInterval(fourDays))
        XCTAssertEqual(Array(rt.trips.keys), ["S1"])
        XCTAssertEqual(rt.trips["S1"]?.startDate, "20261018")

        // Stops with no times (as NJ Transit's light rail trips come), or all NO_DATA: nothing to go by, and not counted
        let untimed = route1.map { CodedStop(code: $0.0) }
        let noData = route1.map { CodedStop(code: $0.0, noData: true) }
        rt = try matched([("14000001", untimed), ("14000002", noData)])
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching, LiveMatching(total: 2, byStopCodesOn: true))
        XCTAssertEqual(rt.matching?.logLine(name: "NJ Transit"),
                       "live trips: NJ Transit 2 in the data, 0 at stops near here, by stop codes and schedule 0 "
                       + "(0 still to stop here), not matched 0")
    }

    /// A trip after midnight is the day before's (24:10 in its timetable); and a stop the live data has no prediction for
    /// (NO_DATA) keeps its timetable time, with the stops after it, while the stops before it are live
    func testNJTransitBusLiveTripsAfterMidnightAndNoData() throws {
        let slice = try njTransitLike().slice
        let keep = Set(slice.trips.map(\.id))
        // Thursday 0:05: the Wednesday's 24:10 leaves Broad St at 0:10, here 2 minutes late
        let night = at(12 * 60 + 5)
        let afterMidnight = coded([("20001", 730), ("20002", 734), ("20004", 742), ("20007", 750), ("20005", 760)], late: 120)
        var rt = try RegionalBusFeed.njTransit.realtime(from: codedTrips([("14000009", afterMidnight)], at: night),
                                                        fetchedAt: night, keep: keep, nearby: slice)
        XCTAssertEqual(Array(rt.trips.keys), ["N1"])
        XCTAssertEqual(rt.trips["N1"]?.startDate, "20261014")
        let broad = slice.arrivals(pierIDs: ["njb:101"], from: night, to: night.addingTimeInterval(3600), realtime: [rt], now: night)
        XCTAssertEqual(tripIDs(broad), ["njb:N1"])
        XCTAssertEqual(broad.first?.source, .realtime)
        XCTAssertEqual(broad.first?.arrivalTime, at(732))
        // The Thursday's 24:10, a day later, isn't that live trip's
        let nextNight = slice.arrivals(pierIDs: ["njb:101"], from: night.addingTimeInterval(86400),
                                       to: night.addingTimeInterval(86400 + 3600), realtime: [rt], now: night)
        XCTAssertEqual(tripIDs(nextNight), ["njb:N1"])
        XCTAssertEqual(nextNight.first?.source, .scheduled)

        // 13:10's trip, 4 minutes late at Broad St, with no prediction yet from Newark Penn on
        var stops = coded([("20001", 70)], late: 240)
        stops += ["20002", "20004", "20007", "20005"].map { CodedStop(code: $0, noData: true) }
        rt = try RegionalBusFeed.njTransit.realtime(from: codedTrips([("14000001", stops)]), fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(Array(rt.trips.keys), ["B1"])
        XCTAssertEqual(rt.trips["B1"]?.stopTimes.map(\.stopID), ["101"])
        XCTAssertEqual(rt.trips["B1"]?.noData, ["102", "105"])
        func b1(at stop: String) -> Arrival? {
            slice.arrivals(pierIDs: [stop], from: now, to: at(120), realtime: [rt], now: now).first { $0.id.hasPrefix("njb:B1|") }
        }
        // Broad St at 13:14 instead of 13:10; Newark Penn at its timetable's 13:14
        XCTAssertEqual(b1(at: "njb:101")?.source, .realtime)
        XCTAssertEqual(b1(at: "njb:101")?.arrivalTime, at(74))
        XCTAssertEqual(b1(at: "njb:102")?.source, .scheduled)
        XCTAssertEqual(b1(at: "njb:102")?.arrivalTime, at(74))
        // No prediction at the stops near here, only further on: still that trip (by its last stop, which is kept), but the
        // times here stay the timetable's, and it isn't counted as a live trip at a stop near here
        var further = [CodedStop(code: "20001", noData: true), CodedStop(code: "20002", noData: true)]
        further += coded([("20004", 82), ("20007", 90), ("20005", 100)], late: 300)
        rt = try RegionalBusFeed.njTransit.realtime(from: codedTrips([("14000001", further)]), fetchedAt: now, keep: keep, nearby: slice)
        XCTAssertEqual(Array(rt.trips.keys), ["B1"])
        XCTAssertEqual(rt.trips["B1"]?.stopTimes.map(\.stopID), ["105"])
        XCTAssertEqual(rt.matching?.nearby, 0)
        XCTAssertEqual(rt.matching?.nearbyStillToStop, 0)
        XCTAssertEqual(b1(at: "njb:101")?.source, .scheduled)
        XCTAssertEqual(b1(at: "njb:101")?.arrivalTime, at(70))
        XCTAssertEqual(b1(at: "njb:102")?.source, .scheduled)
    }

    /// The lists of stop codes come only with NJ Transit's nearby piece, and only from a file that has the codes: one stored
    /// before they were kept reads as before and matches nothing, until it's downloaded again. They stay with NJ Transit's part
    /// when the companies' pieces are put together
    func testNJTransitBusStopCodeListsComeWithItsNearbyPiece() throws {
        let (index, data, slice) = try njTransitLike()
        XCTAssertEqual(Array(data[4..<8]), [4, 0, 0, 0])
        // Another company's file keeps the codes too, but its nearby piece has no lists: its live data goes by its own IDs
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let other = try njTransitLike(nice)
        XCTAssertEqual(other.index.stopCodes, index.stopCodes)
        XCTAssertNil(other.slice.stopCodeLists)
        XCTAssertFalse(nice.liveByStopCodes)
        let merged = try XCTUnwrap(FerryFeed.combining([other.slice, slice]))
        XCTAssertEqual(merged.stopCodeLists, slice.stopCodeLists)
        XCTAssertEqual(Set(merged.stopCodeLists?.keys.map { $0 } ?? []), ["njb:"])
        // Nothing near here: no lists
        XCTAssertNil(index.slice(near: Coordinate(latitude: 39.0, longitude: -74.9), radiusMeters: 1500).stopCodeLists)

        // The codes are the file's last block. Without it and marked as the format before, it's a file written before
        let block = 4 + index.stopCodes.reduce(0) { $0 + 2 + $1.utf8.count }
        var old = Data(data.prefix(data.count - block))
        old[4] = 3
        let before = try NJBusIndex(data: old, feed: .njTransit)
        XCTAssertTrue(before.stopCodes.isEmpty)
        XCTAssertEqual(before.stopCount, index.stopCount)
        let oldSlice = before.slice(near: Coordinate(latitude: 40.7345, longitude: -74.1642), radiusMeters: 1500)
        XCTAssertNil(oldSlice.stopCodeLists)
        var withoutLists = slice
        withoutLists.stopCodeLists = nil
        XCTAssertEqual(oldSlice, withoutLists)
        // The monthly check sees the file with codes as new data
        XCTAssertFalse(NJBusIndex.sameContent(old, data))
        // With the old file every time stays the timetable's, and the log says nothing matched
        let live = codedTrips([("14000001", coded([("20001", 10), ("20002", 14), ("20004", 22), ("20007", 30), ("20005", 40)], late: 180))])
        let rt = try RegionalBusFeed.njTransit.realtime(from: live, fetchedAt: now, keep: Set(oldSlice.trips.map(\.id)), nearby: oldSlice)
        XCTAssertTrue(rt.trips.isEmpty)
        XCTAssertEqual(rt.matching, LiveMatching(total: 1, byStopCodesOn: true))
        let penn = oldSlice.arrivals(pierIDs: ["njb:102"], from: now, to: at(60), realtime: [rt], now: now)
        XCTAssertFalse(penn.isEmpty)
        XCTAssertTrue(penn.allSatisfy { $0.source == .scheduled })

        // A count of codes other than the stops', or a block cut short, makes the file unreadable (downloaded again as a damaged one)
        var miscounted = data
        miscounted[data.count - block] = UInt8(index.stopCount + 1)
        XCTAssertThrowsError(try NJBusIndex(data: miscounted))
        XCTAssertThrowsError(try NJBusIndex(data: Data(data.dropLast(1))))
    }

    /// SEPTA's live data (buses and Metro in one feed) keeps the trip IDs of its bus timetable: those go to its bus stops
    func testSEPTABusRealtime() throws {
        let septa = try XCTUnwrap(RegionalBusFeed.feed(code: RegionalBusFeed.septaCode))
        let rt = try septa.realtime(from: tripUpdates([("T1", now.addingTimeInterval(15 * 60)), ("699524", now)]), fetchedAt: now)
        XCTAssertEqual(rt.prefix, "njb:SEPTA/")
        XCTAssertEqual(Set(rt.trips.keys), ["T1", "699524"])
        let near = try septa.realtime(from: tripUpdates([("T1", now), ("699524", now)]), fetchedAt: now, keep: ["njb:SEPTA/T1"])
        XCTAssertEqual(Set(near.trips.keys), ["T1"])
    }

    /// Two operators with the same trip ID (both T1): each uses its own live data (the one with the longest prefix). NJ Transit's
    /// names its trips and stops its own way (the stop by its code, with a predicted time and its delay), and goes to its T1 by that
    func testEachCompanyUsesItsOwnRealtime() throws {
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let a = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: now, feed: nice), feed: nice)
        var coded = files
        coded["stops.txt"] = d("""
        stop_id,stop_code,stop_name,stop_lat,stop_lon,location_type,parent_station
        S1,30001,Hempstead Transit Center,40.7069,-73.6171,0,
        S2,30002,Fulton St &amp; Franklin Av,40.7060,-73.6300,,
        S3,30003,Jamaica Center,40.7020,-73.8010,0,
        P1,,Station area,40.7069,-73.6171,1,
        F1,30011,MAIN ST AT MARKET ST,41.7004,-73.9210,0,
        F2,30012,FISHKILL PLAZA,41.5300,-73.8900,0,
        X1,30021,Hartford Union Station,41.7690,-72.6820,0,
        """)
        let b = try NJBusIndex(data: try NJBusBuilder.build(files: coded, now: now), feed: .njTransit)
        let c = Coordinate(latitude: 40.7069, longitude: -73.6171)
        let merged = try XCTUnwrap(FerryFeed.combining([a.slice(near: c, radiusMeters: 1500), b.slice(near: c, radiusMeters: 1500)]))
        // T1's timetable time at S1 is 12:10
        let scheduled = now.addingTimeInterval(10 * 60)
        let niceRT = try nice.realtime(from: tripUpdates([("T1", scheduled.addingTimeInterval(300))]), fetchedAt: now)
        let njtLive = codedTrips([("T1", [CodedStop(code: "30001", time: scheduled.addingTimeInterval(120), delay: 120),
                                          CodedStop(code: "30002", time: scheduled.addingTimeInterval(6 * 60), delay: 120),
                                          CodedStop(code: "30003", time: scheduled.addingTimeInterval(42 * 60), delay: 120)])])
        let njtRT = try RegionalBusFeed.njTransit.realtime(from: njtLive, fetchedAt: now, nearby: merged)
        XCTAssertEqual(Array(njtRT.trips.keys), ["T1"])
        for order in [[niceRT, njtRT], [njtRT, niceRT]] {
            let arrivals = merged.arrivals(pierIDs: ["njb:NICE/S1", "njb:S1"], from: now, to: now.addingTimeInterval(3600),
                                           realtime: order, now: now)
                .filter { $0.id.contains("T1|") }
            let nice = try XCTUnwrap(arrivals.first { $0.stationID == "njb:NICE/S1" })
            let njt = try XCTUnwrap(arrivals.first { $0.stationID == "njb:S1" })
            XCTAssertEqual(nice.arrivalTime, scheduled.addingTimeInterval(300))
            XCTAssertEqual(njt.arrivalTime, scheduled.addingTimeInterval(120))
            XCTAssertEqual(nice.source, .realtime)
            XCTAssertEqual(njt.source, .realtime)
        }
        // The operator without live data still uses timetable times
        let onlyNice = merged.arrivals(pierIDs: ["njb:S1"], from: now, to: now.addingTimeInterval(3600), realtime: [niceRT], now: now)
            .first { $0.id.contains("T1|") }
        XCTAssertEqual(onlyNice?.arrivalTime, scheduled)
        XCTAssertEqual(onlyNice?.source, .scheduled)
        // NJ Transit's live data in the other operators' form (a trip ID of its timetable, a stop ID) isn't used: none of it matches
        let byID = try RegionalBusFeed.njTransit.realtime(from: tripUpdates([("T1", scheduled.addingTimeInterval(120))]),
                                                          fetchedAt: now, nearby: merged)
        XCTAssertTrue(byID.trips.isEmpty)
    }

    func testBusEndpoints() {
        XCTAssertEqual(NJTransitLive.Endpoints.bus.token.host, "pcsdata.njtransit.com")
        XCTAssertTrue(NJTransitLive.Endpoints.bus.token.path.hasPrefix("/api/GTFSG2/"))
        XCTAssertTrue(NJTransitLive.Endpoints.bus.tripUpdates.path.hasPrefix("/api/GTFSG2/"))
        XCTAssertEqual(NJTransitLive.Endpoints.rail.token, NJTransitLive.tokenURL)
    }

    /// Check real data on a Mac: whether live data trip IDs match the timetable.
    /// Put BXL.pb and CTT.pb (downloaded live data) in CMT_BUS_RT_DIR, and the unzipped timetables in CMT_REGIONAL_BUS_DIR (see RegionalBusTests).
    func testRealRealtimeMatchesTimetableIfAvailable() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rtDir = env["CMT_BUS_RT_DIR"], let dir = env["CMT_REGIONAL_BUS_DIR"] else {
            throw XCTSkip("CMT_BUS_RT_DIR and CMT_REGIONAL_BUS_DIR not set")
        }
        var checked = 0
        for feed in RegionalBusFeed.all where feed.realtimeURL != nil {
            let pb = URL(fileURLWithPath: rtDir).appendingPathComponent(feed.code + ".pb")
            let folder = URL(fileURLWithPath: dir).appendingPathComponent(feed.code)
            guard let rtData = try? Data(contentsOf: pb), FileManager.default.fileExists(atPath: folder.path) else { continue }
            var files: [String: Data] = [:]
            for name in ["routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt", "stop_times.txt"] {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { files[name] = data }
            }
            let index = try NJBusIndex(data: try NJBusBuilder.build(files: files, now: Date(), feed: feed), feed: feed)
            let rt = try feed.realtime(from: rtData, fetchedAt: Date())
            let known = Set(index.tripIDs)
            let matched = rt.trips.keys.filter(known.contains).count
            print("\(feed.code) realtime: \(rtData.count) bytes, \(rt.trips.count) trips, \(matched) match the timetable, e.g. \(rt.trips.keys.sorted().prefix(3)) vs \(index.tripIDs.prefix(3))")
            checked += 1
        }
        if checked == 0 { throw XCTSkip("No live data files found") }
    }
}
