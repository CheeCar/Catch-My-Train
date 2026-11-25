import XCTest
@testable import TransitCore

/// Trains (LIRR, Metro-North): tested with small samples in the same format as the real data; for real data see testRealRailFeedsIfAvailable.
final class RailTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)   // 2026-10-14 16:00 UTC

    /// LIRR sample: like the real data, quoted, no calendar.txt (only calendar_dates.txt), with train numbers (trip_short_name);
    /// adds a bus route (to be filtered out), a station entrance (location_type 2, to be filtered out) and a departure starting 50 days out (not kept).
    private var lirrFiles: [String: Data] {
        [
            "routes.txt": d("""
            "route_id","route_long_name","route_type","route_color","route_text_color"
            "1","Babylon Branch","2","00985F","FFFFFF"
            "9","Port Washington Branch","2","C60C30","FFFFFF"
            "99","Substitute Bus","3","000000","FFFFFF"
            """),
            "stops.txt": d("""
            "stop_id","stop_code","stop_name","stop_lat","stop_lon","location_type"
            "237","NYK","Penn Station","40.75058844","-73.99358408","0"
            "214","WDD","Woodside","40.74585067","-73.90297516","0"
            "349","GCT","Grand Central","40.755162","-73.975455",""
            "27","BTA","Babylon","40.70068","-73.32405","0"
            "52","PWS","Port Washington","40.82903","-73.68733","0"
            "999","","Woodside entrance","40.7459","-73.9030","2"
            """),
            "trips.txt": d("""
            "route_id","service_id","trip_id","trip_headsign","trip_short_name","direction_id","shape_id"
            "1","S1","GO1_1","Babylon","1001","0",""
            "9","S1","GO1_2","Penn Station","1002","1",""
            "9","S1","GO1_3","Grand Central","1003","1",""
            "9","FAR","GO1_4","Penn Station","1004","1",""
            "99","S1","GO1_5","Bus","9001","0",""
            """),
            "stop_times.txt": d("""
            "trip_id","arrival_time","departure_time","stop_id","stop_sequence","pickup_type","drop_off_type"
            "GO1_1","12:10:00","12:10:00","237","1","0","0"
            "GO1_1","12:20:00","12:20:00","214","2","0","0"
            "GO1_1","13:10:00","13:10:00","27","3","0","0"
            "GO1_2","12:00:00","12:00:00","52","1","0","0"
            "GO1_2","12:40:00","12:40:00","214","2","0","0"
            "GO1_2","12:55:00","12:55:00","237","3","0","0"
            "GO1_3","12:30:00","12:30:00","52","1","0","0"
            "GO1_3","13:10:00","13:10:00","214","2","0","0"
            "GO1_3","13:25:00","13:25:00","349","3","0","0"
            "GO1_4","12:00:00","12:00:00","52","1","0","0"
            "GO1_4","12:40:00","12:40:00","237","2","0","0"
            "GO1_5","12:00:00","12:00:00","237","1","0","0"
            "GO1_5","12:30:00","12:30:00","214","2","0","0"
            """),
            "calendar_dates.txt": d("""
            "service_id","date","exception_type"
            "S1","20261013","1"
            "S1","20261014","1"
            "S1","20261015","1"
            "S1","20270301","1"
            "FAR","20261210","1"
            """),
            "feed_info.txt": d("""
            "feed_publisher_name","feed_publisher_url","feed_timezone","feed_lang","feed_version"
            "Long Island Rail Road","http://web.mta.info/lirr","America/New York","en","GO202_26"
            """),
        ]
    }

    /// Metro-North sample: trip_id is "calendar + number + direction", like the real data.
    private var mnrFiles: [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
            1,1,,Hudson,,2,,009B3A,FFFFFF
            """),
            "stops.txt": d("""
            stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station,wheelchair_boarding
            1,0NY,Grand Central,,40.752998,-73.977056,,,0,,1
            4,0HL,Harlem-125 St,,40.805157,-73.939149,,,0,,1
            622,0YS,Yankees-E 153 St,,40.8253,-73.9299,,,0,,1
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,peak_offpeak
            1,111,111+2380929+0,Yankees-E 153 St,1229,0,,,1,0
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,track,note_id
            111+2380929+0,12:00:00,12:00:00,1,1,0,0,3,
            111+2380929+0,12:10:00,12:10:00,4,2,0,0,,
            111+2380929+0,12:20:00,12:20:00,622,3,0,0,,
            """),
            "calendar_dates.txt": d("""
            service_id,date,exception_type
            111,20261014,1
            """),
        ]
    }

    private func build() throws -> FerryFeed {
        try FerryBuilder.build([.lirr: lirrFiles, .metroNorth: mnrFiles], now: now)
    }

    func testBuildRoutesStationsAndWindow() throws {
        let f = try build()
        XCTAssertEqual(f.routes.map(\.id).sorted(), ["LIRR-BAB", "LIRR-PW", "MNR-HUD"])
        XCTAssertEqual(f.route("LIRR-PW")?.name, "LIRR Port Washington Branch")
        XCTAssertEqual(f.route("MNR-HUD")?.name, "Metro-North Hudson Line")
        XCTAssertEqual(f.route("LIRR-BAB")?.color, "00985F")
        XCTAssertTrue(f.hasRealtime(route: "LIRR-BAB"))
        // No buses, and no departures starting 50 days out
        XCTAssertEqual(f.trips.map(\.id).sorted(), ["lirr:GO1_1", "lirr:GO1_2", "lirr:GO1_3", "mnr:111+2380929+0"])
        XCTAssertNil(f.services["lirr:FAR"])
        // The calendar keeps only dates within these 45 days
        XCTAssertEqual(f.services["lirr:S1"]?.added, [20261013, 20261014, 20261015])
        // Train numbers, station codes, Grand Central Madison, no station entrances
        XCTAssertEqual(f.trips.first { $0.id == "lirr:GO1_1" }?.number, "1001")
        XCTAssertEqual(f.pier(id: "lirr:237")?.code, "NYK")
        XCTAssertEqual(f.pier(id: "lirr:349")?.name, "Grand Central Madison")
        XCTAssertEqual(f.pier(id: "mnr:1")?.name, "Grand Central")
        XCTAssertNil(f.pier(id: "lirr:999"))
        XCTAssertEqual(f.versions["lirr"], "GO202_26")
        XCTAssertEqual(f.sources, [.lirr, .metroNorth])
    }

    func testBadgesNamesAndSystems() {
        XCTAssertEqual(FerryFeed.badge("LIRR-BAB"), "BAB")
        XCTAssertEqual(FerryFeed.badge("MNR-NH"), "NH")
        XCTAssertEqual(FerryFeed.routeName("MNR-NH"), "Metro-North New Haven Line")
        XCTAssertTrue(FerryFeed.isRailRoute("LIRR-PW"))
        XCTAssertFalse(FerryFeed.isFerryRoute("LIRR-PW"))
        XCTAssertTrue(FerryFeed.isFerryRoute("NYF-ER"))
        XCTAssertTrue(FerryFeed.isFeedRoute("MNR-HUD"))
        XCTAssertFalse(FerryFeed.isFeedRoute("7"))
        XCTAssertEqual(FerryFeed.Source.cases(for: .train),
                       [.lirr, .metroNorth, .njTransitRail, .mbtaRail, .amtrakNY, .septaRail, .hartfordLine, .marc])
        XCTAssertFalse(FerryFeed.Source.cases(for: .ferry).contains(.lirr))
        XCTAssertEqual(FerryFeed.Source.lirr.boardingSeconds, 120)
        XCTAssertTrue(TransitSystem.train.usesTimetableFeed)
        XCTAssertFalse(TransitSystem.bus.usesTimetableFeed)
    }

    func testScheduledArrivalsAndTerminals() throws {
        let f = try build()
        let a = f.arrivals(pierIDs: ["lirr:214"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [], now: now)
        XCTAssertEqual(a.map(\.id), ["lirr:GO1_1|20261014|lirr:214", "lirr:GO1_2|20261014|lirr:214", "lirr:GO1_3|20261014|lirr:214"])
        XCTAssertEqual(a.map { $0.direction.terminal }, ["Babylon", "Penn Station", "Grand Central Madison"])
        XCTAssertTrue(a.allSatisfy { $0.source == .scheduled })
        // Both terminals are listed for the inbound direction
        let inbound = f.terminals(atPier: "lirr:214").filter { $0.direction == "S" }.map(\.terminal)
        XCTAssertEqual(Set(inbound), ["Penn Station", "Grand Central Madison"])
        // Nearby stations: train stations allow 2 minutes to board
        let near = f.stations(near: Coordinate(latitude: 40.7456, longitude: -73.9030), radiusMeters: 500)
        XCTAssertEqual(near.map(\.id), ["lirr:214"])
        XCTAssertEqual(near.first?.entranceToPlatformSeconds, 120)
    }

    /// Live data lists the following stops: delays carry forward; stops already passed aren't shown; skipped stops aren't shown.
    func testRailRealtimeFullStopList() throws {
        let f = try build()
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        func at(_ s: Int) -> Date { dayStart.addingTimeInterval(TimeInterval(s)) }
        // GO1_1: leaves Penn 12:10, 5 minutes late; GO1_2: Woodside skipped; GO1_3 only gives the delay in seconds
        let rt = FerryRealtime(timestamp: now, trips: [
            "GO1_1": .init(stopTimes: [.init(stopID: "214", time: at(12 * 3600 + 25 * 60)),
                                       .init(stopID: "27", time: at(13 * 3600 + 15 * 60))], startDate: "20261014"),
            "GO1_2": .init(stopTimes: [.init(stopID: "237", time: at(12 * 3600 + 55 * 60))], skipped: ["214"]),
            "GO1_3": .init(stopTimes: [.init(stopID: "214", delay: 120)]),
        ], fetchedAt: now, source: .lirr)
        let a = f.arrivals(pierIDs: ["lirr:214", "lirr:237"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [rt], now: now)
        let byID = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:214"]?.arrivalTime, at(12 * 3600 + 25 * 60))
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:214"]?.source, .realtime)
        // Penn Station 12:10 + 5 minutes = 12:15, not yet reached (now 12:00), so shown
        XCTAssertNotNil(byID["lirr:GO1_1|20261014|lirr:237"])
        XCTAssertNil(byID["lirr:GO1_2|20261014|lirr:214"], "Skipped stops aren't shown")
        XCTAssertEqual(byID["lirr:GO1_3|20261014|lirr:214"]?.arrivalTime, at(13 * 3600 + 12 * 60))
    }

    /// NO_DATA: the last known delay stops there; later stops use the timetable until the next stop with a prediction.
    func testNoDataStopsTheCarriedDelay() throws {
        let f = try build()
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        func at(_ s: Int) -> Date { dayStart.addingTimeInterval(TimeInterval(s)) }
        func update(_ stopID: String, at time: Date? = nil, noData: Bool = false) -> GTFSRealtimeFeed.StopTimeUpdate {
            .init(stopID: stopID, arrivalTime: time, departureTime: nil, isSkipped: false, hasNoData: noData)
        }
        // GO1_1: Penn 12:10 → 12:15 (5 minutes late), Woodside NO_DATA, Babylon NO_DATA
        let entity = GTFSRealtimeFeed.TripUpdate(entityID: "e1", tripID: "GO1_1", routeID: "1", startDate: "20261014",
                                                 isCanceled: false, timestamp: nil,
                                                 stopTimeUpdates: [update("237", at: at(12 * 3600 + 15 * 60)),
                                                                   update("214", noData: true), update("27", noData: true)])
        let rt = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: [entity]), fetchedAt: now, source: .lirr)
        XCTAssertEqual(rt.trips["GO1_1"]?.noData, ["214", "27"])
        let a = f.arrivals(pierIDs: ["lirr:214", "lirr:237"], from: now, to: now.addingTimeInterval(2 * 3600), realtime: [rt], now: now)
        let byID = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:237"]?.arrivalTime, at(12 * 3600 + 15 * 60))
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:237"]?.source, .realtime)
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:214"]?.arrivalTime, at(12 * 3600 + 20 * 60), "No carried delay past NO_DATA")
        XCTAssertEqual(byID["lirr:GO1_1|20261014|lirr:214"]?.source, .scheduled)

        // At 12:22 Woodside's timetable time (12:20) has passed, but the train is 15 minutes late and hasn't reached Penn yet
        let later = at(12 * 3600 + 22 * 60)
        var late = entity
        late.stopTimeUpdates[0] = update("237", at: at(12 * 3600 + 25 * 60))
        let rtLater = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: later, tripUpdates: [late]), fetchedAt: later, source: .lirr)
        let b = f.arrivals(pierIDs: ["lirr:237"], from: later, to: later.addingTimeInterval(3600), realtime: [rtLater], now: later)
        XCTAssertEqual(b.first { $0.id == "lirr:GO1_1|20261014|lirr:237" }?.arrivalTime, at(12 * 3600 + 25 * 60))

        // Delays known at 0 and 3, NO_DATA at 1: 0 is live, 1 and 2 follow the timetable, 3 and later are live again
        let live = FerryRealtime.Live(canceled: false, known: [(index: 0, delay: 300), (index: 3, delay: 120)],
                                      passedIndex: nil, updatedAt: now, noDataFrom: [1])
        XCTAssertEqual((0...4).map { live.delay(atIndex: $0) }, [300, nil, nil, 120, 120])
        XCTAssertEqual((0...4).map { live.positionDelay(atIndex: $0) }, [300, 300, 300, 120, 120])
    }

    func testRailPassedStopsByTime() throws {
        let f = try build()
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let later = dayStart.addingTimeInterval(TimeInterval(12 * 3600 + 30 * 60))   // 12:30
        // GO1_1 is 2 minutes late: Penn 12:12 and Woodside 12:22 have passed, Babylon not yet
        let rt = FerryRealtime(timestamp: later, trips: [
            "GO1_1": .init(stopTimes: [.init(stopID: "27", delay: 120)]),
        ], fetchedAt: later, source: .lirr)
        let trip = f.trips.first { $0.id == "lirr:GO1_1" }!
        let live = rt.delays(for: trip, dayStart: dayStart, day: 20261014)
        XCTAssertEqual(live?.passedIndex, 1)
        // A different start date is given: not this day's train
        let other = FerryRealtime(timestamp: later, trips: [
            "GO1_1": .init(stopTimes: [.init(stopID: "27", delay: 120)], startDate: "20261013"),
        ], fetchedAt: later, source: .lirr)
        XCTAssertNil(other.delays(for: trip, dayStart: dayStart, day: 20261014))
    }

    /// Metro-North: live data matches even when trip_id is only a number, only the train number is given, or stations use codes.
    func testRailRealtimeMatching() throws {
        let f = try build()
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let trip = f.trips.first { $0.id == "mnr:111+2380929+0" }!
        let update = FerryRealtime.TripUpdate(stopTimes: [.init(stopID: "4", delay: 180)])
        let byKey = FerryRealtime(timestamp: now, trips: ["2380929": update], fetchedAt: now, source: .metroNorth)
        XCTAssertEqual(byKey.delays(for: trip, dayStart: dayStart)?.known.first?.delay, 180)
        let byNumber = FerryRealtime(timestamp: now, trips: [:], fetchedAt: now, source: .metroNorth, numbers: ["1229": update])
        XCTAssertEqual(byNumber.delays(for: trip, dayStart: dayStart)?.known.first?.index, 1)
        let byCode = FerryRealtime(timestamp: now, trips: ["2380929": .init(stopTimes: [.init(stopID: "0HL", delay: 60)])],
                                   fetchedAt: now, source: .metroNorth)
        XCTAssertEqual(byCode.delays(for: trip, dayStart: dayStart, stopCodes: ["0HL": "mnr:4"])?.known.first?.index, 1)
        // Metro-North's real format: trip_id is a different numbering ("3233051"), the train number is in the entity id ("1229")
        var entity = GTFSRealtimeFeed.TripUpdate(entityID: "1229", tripID: "3233051", routeID: "1", startDate: "20261014",
                                                 isCanceled: false, timestamp: nil, stopTimeUpdates: [])
        entity.stopTimeUpdates = [.init(stopID: "4", arrivalTime: dayStart.addingTimeInterval(12 * 3600 + 12 * 60),
                                        departureTime: nil, isSkipped: false, hasNoData: false)]
        let mnr = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: [entity]), fetchedAt: now, source: .metroNorth)
        XCTAssertEqual(mnr.delays(for: trip, dayStart: dayStart, day: 20261014)?.known.first?.delay, 120)
        XCTAssertNil(mnr.delays(for: trip, dayStart: dayStart, day: 20261015), "The same train number on another day doesn't count")
        // LIRR doesn't use the entity id as the train number
        let lirr = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: [entity]), fetchedAt: now, source: .lirr)
        XCTAssertTrue(lirr.numbers.isEmpty)
        // Ferries don't match by train number
        let ferry = FerryRealtime(timestamp: now, trips: [:], fetchedAt: now, source: .nycFerry, numbers: ["1229": update])
        XCTAssertTrue(ferry.numbers.keys.contains("1229"))
        XCTAssertNil(ferry.update(for: trip))
    }

    /// How fresh live data is: LIRR's own time on a trip is when its prediction last changed (a train still at its first station keeps
    /// one from long before while the data is seconds old), so the data's time counts there; other operators' trips keep their own
    func testLirrFreshnessFromTheData() throws {
        let f = try build()
        let dayStart = Timetable.serviceDayStart(20261014, in: Timetable.timeZone)!
        let hourBefore = now.addingTimeInterval(-3600)
        // GO1_1 waits at Penn Station (12:10, on time): its own time is from an hour before, the data's is now
        let waiting = GTFSRealtimeFeed.TripUpdate(entityID: "e1", tripID: "GO1_1", routeID: "1", startDate: "20261014",
                                                  isCanceled: false, timestamp: hourBefore,
                                                  stopTimeUpdates: [.init(stopID: "237", arrivalTime: nil,
                                                                          departureTime: dayStart.addingTimeInterval(12 * 3600 + 10 * 60),
                                                                          isSkipped: false, hasNoData: false)])
        let lirr = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: [waiting]), fetchedAt: now, source: .lirr)
        let a = f.arrivals(pierIDs: ["lirr:237"], from: now, to: now.addingTimeInterval(3600), realtime: [lirr], now: now)
        let penn = try XCTUnwrap(a.first { $0.id == "lirr:GO1_1|20261014|lirr:237" })
        XCTAssertEqual(penn.source, .realtime)
        XCTAssertEqual(penn.updatedAt, now, "The data's time, not the trip's own")
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 300, source: .route)
        let fresh = CatchEvaluator.evaluate(arrival: penn, walk: walk, entranceToPlatformSeconds: 60, settings: .default, now: now,
                                            clockOffset: 0)
        XCTAssertFalse(fresh.notes.contains(.staleRealtime))
        XCTAssertEqual(fresh.verdict, .canTry)
        // Old data is still stale: the same trip in data from 10 minutes before
        let before = now.addingTimeInterval(-600)
        let old = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: before, tripUpdates: [waiting]), fetchedAt: before, source: .lirr)
        let b = f.arrivals(pierIDs: ["lirr:237"], from: now, to: now.addingTimeInterval(3600), realtime: [old], now: now)
        let oldPenn = try XCTUnwrap(b.first { $0.id == "lirr:GO1_1|20261014|lirr:237" })
        let stale = CatchEvaluator.evaluate(arrival: oldPenn, walk: walk, entranceToPlatformSeconds: 60, settings: .default, now: now,
                                            clockOffset: 0)
        XCTAssertTrue(stale.notes.contains(.staleRealtime))
        XCTAssertEqual(stale.verdict, .insufficientInfo)
        // Another operator's trip keeps its own time (Metro-North's real data gives none; here one is given)
        let mnrTrip = try XCTUnwrap(f.trips.first { $0.id == "mnr:111+2380929+0" })
        let given = GTFSRealtimeFeed.TripUpdate(entityID: "1229", tripID: "3233051", routeID: "1", startDate: "20261014",
                                                isCanceled: false, timestamp: hourBefore,
                                                stopTimeUpdates: [.init(stopID: "4", arrivalTime: dayStart.addingTimeInterval(12 * 3600 + 12 * 60),
                                                                        departureTime: nil, isSkipped: false, hasNoData: false)])
        let mnr = FerryRealtime(feed: GTFSRealtimeFeed(timestamp: now, tripUpdates: [given]), fetchedAt: now, source: .metroNorth)
        XCTAssertEqual(mnr.delays(for: mnrTrip, dayStart: dayStart, day: 20261014)?.updatedAt, hourBefore)
    }

    /// Reading from GTFS-Realtime: the vehicle label is recorded as the train number; stops with only a delay in seconds are kept too; skipped stops are recorded.
    func testRealtimeDecodeVehicleLabelAndDelays() throws {
        // A tiny hand-written protobuf: one TripUpdate, trip_id "2380929", vehicle label "1229",
        // one stop with only delay = -60, one stop SKIPPED
        func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
            return out
        }
        func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
        func string(_ n: Int, _ s: String) -> [UInt8] { field(n, Array(s.utf8)) }
        func number(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
        let trip = string(1, "2380929") + string(3, "20261014")
        let vehicle = string(2, "1229")
        let stop1 = field(2, number(1, UInt64(bitPattern: -60))) + string(4, "4")
        let stop2 = string(4, "622") + number(5, 1)
        let update = field(1, trip) + field(3, vehicle) + field(2, stop1) + field(2, stop2)
        let entity = string(1, "e1") + field(3, update)
        let header = string(1, "2.0") + number(3, 1_791_993_600)
        let data = Data(field(1, header) + field(2, entity))
        let rt = try FerryRealtime.decode(data, fetchedAt: now, source: .metroNorth)
        let u = try XCTUnwrap(rt.trips["2380929"])
        XCTAssertEqual(u.stopTimes.first?.delay, -60)
        XCTAssertEqual(u.skipped, ["622"])
        XCTAssertEqual(u.startDate, "20261014")
        XCTAssertEqual(rt.numbers["1229"], u)
    }

    func testEndingSourcesAskForDailyCheck() throws {
        let f = try build()
        // In the sample LIRR is only scheduled through 10/15 and Metro-North only has 10/14: the next 3 days include days without trains
        XCTAssertEqual(f.endingSources(from: now), [.lirr, .metroNorth])
        XCTAssertEqual(f.coverage(from: now).endingSources(from: now), [.lirr, .metroNorth])
        // Ferries don't count
        let ferry = try FerryBuilder.build([.statenIsland: [
            "routes.txt": d("route_id,route_type\nSI,4\n"),
            "stops.txt": d("stop_id,stop_name,stop_lat,stop_lon\nwhitehall,Whitehall,40.7013,-74.013\nstgeorge,St. George,40.6437,-74.0736\n"),
            "trips.txt": d("route_id,service_id,trip_id\nSI,X,t1\n"),
            "stop_times.txt": d("trip_id,arrival_time,departure_time,stop_id,stop_sequence\nt1,10:00:00,10:00:00,whitehall,1\nt1,10:25:00,10:25:00,stgeorge,2\n"),
            "calendar_dates.txt": d("service_id,date,exception_type\nX,20261014,1\n"),
        ]], now: now)
        XCTAssertTrue(ferry.endingSources(from: now).isEmpty)
    }

    /// From a week before an operator's timetable runs out, the app checks for a new one every day, so the new one is in use before the
    /// old one ends (see FerryFeed.endingSoonDays)
    func testEndingSoonSourcesAskForDailyCheckAWeekAhead() throws {
        let f = try build()
        // Both samples have their last trains within the next 7 days
        XCTAssertEqual(f.endingSoonSources(from: now), [.lirr, .metroNorth])
        XCTAssertEqual(f.coverage(from: now).endingSoonSources(from: now), [.lirr, .metroNorth])
        // The saved summary can't tell once those days reach past what it covers
        XCTAssertEqual(f.coverage(from: now, days: 20).endingSoonSources(from: now), [])
        // A timetable running for months: the 45 days kept reach past the next three weeks
        var files = lirrFiles
        files["calendar.txt"] = d("""
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        S1,1,1,1,1,1,1,1,20261001,20270331
        """)
        let running = try FerryBuilder.build([.lirr: files], now: now)
        XCTAssertEqual(running.endingSoonSources(from: now), [])
        XCTAssertEqual(running.coverage(from: now).endingSoonSources(from: now), [])
        XCTAssertEqual(running.endingSoonSources(from: now.addingTimeInterval(37 * 86_400)), [],
                       "Its last kept day, 11/27, is the 7th day from 11/20")
        XCTAssertEqual(running.endingSoonSources(from: now.addingTimeInterval(38 * 86_400)), [.lirr],
                       "Without a newer copy for over a month the kept days run short too, and it's checked daily")
        // An operator that doesn't run every day isn't counted while it runs in the two weeks after those days
        files["calendar.txt"] = d("""
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        S1,0,0,0,0,0,1,0,20261001,20270331
        """)
        files["calendar_dates.txt"] = d("service_id,date,exception_type\n")
        XCTAssertEqual(try FerryBuilder.build([.lirr: files], now: now).endingSoonSources(from: now), [])
    }

    /// When stop_times.txt isn't in the files, read from stopTimes (the app reads the big train files while unzipping), same result.
    func testStopTimesFromRowSource() throws {
        var files = lirrFiles
        let stopTimes = files.removeValue(forKey: "stop_times.txt")!
        let streamed = try FerryBuilder.build([.lirr: files],
                                              stopTimes: [.lirr: { body in try TimetableBuilder.forEachRow(stopTimes, body) }],
                                              now: now)
        let whole = try FerryBuilder.build([.lirr: lirrFiles], now: now)
        XCTAssertEqual(streamed, whole)
        XCTAssertThrowsError(try FerryBuilder.build([.lirr: files], now: now))
    }

    /// Real data (zip files only on a Mac): put gtfslirr.zip, gtfsmnr.zip in CMT_RAIL_DIR
    /// (or the unzipped lirr/ and mnr/ folders), optionally with live data rt-lirr.pb, rt-mnr.pb.
    func testRealRailFeedsIfAvailable() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMT_RAIL_DIR"] else { throw XCTSkip("CMT_RAIL_DIR not set") }
        let base = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        var files: [FerryFeed.Source: [String: Data]] = [:]
        var stopTimes: [FerryFeed.Source: FerryBuilder.RowSource] = [:]
        for (source, zipName, folder) in [(FerryFeed.Source.lirr, "gtfslirr.zip", "lirr"), (.metroNorth, "gtfsmnr.zip", "mnr")] {
            let folderURL = base.appendingPathComponent(folder)
            if fm.fileExists(atPath: folderURL.path) {
                var f: [String: Data] = [:]
                for name in FerryFeed.neededFiles {
                    if let data = try? Data(contentsOf: folderURL.appendingPathComponent(name)) { f[name] = data }
                }
                files[source] = f
                continue
            }
            #if canImport(Compression)
            if let zip = try? Data(contentsOf: base.appendingPathComponent(zipName)) {
                files[source] = try ZipReader.read(zip, names: Array(FerryFeed.neededFiles.subtracting(["stop_times.txt"])))
                stopTimes[source] = { body in try ZipReader.forEachRow(zip, name: "stop_times.txt", body) }
            }
            #endif
        }
        guard !files.isEmpty else { throw XCTSkip("No train data in CMT_RAIL_DIR") }
        let clock = Date()
        let feed = try FerryBuilder.build(files, stopTimes: stopTimes, now: Date())
        let seconds = Date().timeIntervalSince(clock)
        let json = try feed.encoded()
        let map = feed.map()
        print("rail: built in \(String(format: "%.2f", seconds)) s, \(feed.routes.count) routes, \(feed.piers.count) stations, \(feed.trips.count) trips, json \(json.count) bytes, map json \(try JSONEncoder().encode(map).count) bytes, versions \(feed.versions)")
        for source in FerryFeed.Source.cases(for: .train) where feed.sources.contains(source) {
            let trips = feed.trips.filter { source.owns(id: $0.id) }
            print("rail \(source.rawValue): \(trips.count) trips, routes \(feed.routes.filter { source.owns(route: $0.id) }.map { "\($0.id) \($0.name)" })")
            XCTAssertGreaterThan(trips.count, 500)
        }
        XCTAssertTrue(feed.routes.allSatisfy { FerryFeed.badge($0.id).count <= 3 }, "Route badges are all short names")
        print("rail: ending soon (checked daily): \(feed.endingSources(from: Date()).map(\.rawValue).sorted())")
        print("rail: same station groups: \(Set(feed.pierGroups().values.map(\.name)).sorted())")

        var realtime: [FerryRealtime] = []
        for (source, name) in [(FerryFeed.Source.lirr, "rt-lirr.pb"), (.metroNorth, "rt-mnr.pb")] {
            if let pb = try? Data(contentsOf: base.appendingPathComponent(name)) {
                let rt = try FerryRealtime.decode(pb, fetchedAt: Date(), source: source)
                realtime.append(rt)
                // How many live data trips match the timetable (printed, for a quick look)
                let ownTrips = feed.trips.filter { source.owns(id: $0.id) }
                let matched = ownTrips.filter { rt.update(for: $0) != nil }.count
                let stopIDs = Set(rt.trips.values.flatMap { $0.stopTimes.map(\.stopID) })
                let known = stopIDs.filter { id in feed.pier(id: source.rawValue + ":" + id) != nil || feed.piers.contains { $0.code == id } }
                print("rail realtime \(source.rawValue): \(rt.trips.count) trip updates, \(rt.numbers.count) labels, sample trip ids \(Array(rt.trips.keys.sorted().prefix(3))), sample labels \(Array(rt.numbers.keys.sorted().prefix(3))), timetable trips matched \(matched), stop ids known \(known.count)/\(stopIDs.count)")
            }
        }
        // The Woodside station (near 61 St-Woodside), and two big stations in Manhattan
        let checks: [(String, Coordinate)] = [("Woodside", Coordinate(latitude: 40.7456, longitude: -73.9030)),
                                              ("Penn Station", Coordinate(latitude: 40.7506, longitude: -73.9936)),
                                              ("Grand Central", Coordinate(latitude: 40.7540, longitude: -73.9765))]
        let t = Date()
        for (label, c) in checks {
            let near = feed.stations(near: c, radiusMeters: 400)
            let arrivals = feed.arrivals(pierIDs: near.map(\.id), from: t, to: t.addingTimeInterval(2 * 3600), realtime: realtime, now: t)
            let terminals = near.flatMap { s in feed.terminals(atPier: s.id).map { "\($0.route)/\($0.direction) → \($0.terminal)" } }
            print("rail near \(label): \(near.map { "\($0.id) \($0.name)" }), next 2 h: \(arrivals.count) trains, live \(arrivals.filter { $0.source == .realtime }.count)")
            print("rail terminals at \(label): \(Set(terminals).sorted())")
            for a in arrivals.prefix(4) {
                print("  \(a.route) \(a.direction.name) \(a.arrivalTime.map { ISO8601DateFormatter().string(from: $0) } ?? "-") \(a.source)")
            }
        }
        let woodside = feed.stations(near: checks[0].1, radiusMeters: 400)
        XCTAssertTrue(woodside.contains { $0.name == "Woodside" })
    }
}
