import XCTest
@testable import TransitCore

/// PATH: the timetable has expired (only stations, lines and stop patterns remain), so departures come only from live data (ridepath.json).
/// The sample has the same format as real data; for real data see testRealPathDataIfAvailable.
final class PathTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    /// 2026-10-14 (Wednesday), noon in New York
    private let now = Date(timeIntervalSince1970: 1_791_993_600)   // 2026-10-14 16:00 UTC

    /// Same as Trillium's PATH data: platforms (location_type 0) have a parent station (1) and entrances (2), and one station has several platforms;
    /// every line's route_short_name is "PATH", with the name in route_long_name. Swap `calendar` to simulate a new timetable.
    private func files(calendar: String = "EXP,1,1,1,1,1,1,1,20250601,20260601") -> [String: Data] {
        [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
            859,151,PATH,Hoboken - 33rd Street,2,4d92fb,ffffff
            860,151,PATH,Hoboken - World Trade Center,2,65c100,ffffff
            861,151,PATH,Journal Square - 33rd Street,1,ff9900,000000
            862,151,PATH,Newark - World Trade Center,2,d93a30,ffffff
            1024,151,PATH,Journal Square - 33rd Street (via Hoboken),2,ff9900,000000
            74320,151,PATH,Newark - Harrison Shuttle Train,2,8c3c96,ffffff
            77285,151,PATH,World Trade Center - 33rd Street,2,65c100,ffffff
            """),
            "stops.txt": d("""
            stop_id,stop_code,platform_code,stop_name,stop_lat,stop_lon,location_type,parent_station
            26733,,,Newark,40.73454,-74.16375,1,
            781718,,,Newark,40.73454,-74.16375,0,26733
            781719,,,Newark,40.73454,-74.16375,0,26733
            900001,,,Newark entrance,40.7346,-74.1638,2,26733
            781720,,,Harrison,40.73942,-74.15587,0,26729
            781722,,,Journal Square,40.73301,-74.06289,0,26731
            781723,,,Journal Square,40.73301,-74.06289,0,26731
            781726,,,Grove Street,40.71966,-74.04324,0,
            781730,,,Exchange Place,40.71676,-74.03238,0,
            794724,,,World Trade Center,40.71271,-74.01193,0,
            781715,,,Hoboken,40.73586,-74.02922,0,26730
            781716,,,Hoboken,40.73586,-74.02922,0,26730
            781717,,,Hoboken,40.73586,-74.02922,0,26730
            781740,,,Newport,40.72699,-74.03383,0,
            781750,,,Christopher Street,40.73301,-74.00707,0,
            781760,,,14th Street,40.73735,-73.99684,0,
            781770,,,33rd Street,40.74884,-73.98837,0,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            862,EXP,t1,World Trade Center,1,
            862,EXP,t2,World Trade Center,1,
            862,EXP,t3,Newark,0,
            860,EXP,t4,World Trade Center,1,
            860,EXP,t5,Hoboken,0,
            859,EXP,t6,33rd Street,1,
            861,EXP,t7,33rd Street,1,
            1024,EXP,t8,33rd Street,1,
            74320,EXP,t9,Harrison,1,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
            t1,07:20:00,07:20:00,781718,1,0,0
            t1,07:22:00,07:22:00,781720,2,0,0
            t1,07:31:00,07:31:00,781722,3,0,0
            t1,07:35:00,07:35:00,781726,4,0,0
            t1,07:38:00,07:38:00,781730,5,0,0
            t1,07:42:00,07:42:00,794724,6,0,0
            t2,10:20:00,10:20:00,781718,1,0,0
            t2,10:22:00,10:22:00,781720,2,0,0
            t2,10:31:00,10:31:00,781722,3,0,0
            t2,10:35:00,10:35:00,781726,4,0,0
            t2,10:38:00,10:38:00,781730,5,0,0
            t2,10:42:00,10:42:00,794724,6,0,0
            t3,08:00:00,08:00:00,794724,1,0,0
            t3,08:04:00,08:04:00,781730,2,0,0
            t3,08:07:00,08:07:00,781726,3,0,0
            t3,08:11:00,08:11:00,781723,4,0,0
            t3,08:20:00,08:20:00,781720,5,0,0
            t3,08:22:00,08:22:00,781719,6,0,0
            t4,09:00:00,09:00:00,781715,1,0,0
            t4,09:03:00,09:03:00,781740,2,0,0
            t4,09:06:00,09:06:00,781730,3,0,0
            t4,09:10:00,09:10:00,794724,4,0,0
            t5,09:30:00,09:30:00,794724,1,0,0
            t5,09:34:00,09:34:00,781730,2,0,0
            t5,09:37:00,09:37:00,781740,3,0,0
            t5,09:40:00,09:40:00,781716,4,0,0
            t6,09:00:00,09:00:00,781717,1,0,0
            t6,09:05:00,09:05:00,781750,2,0,0
            t6,09:08:00,09:08:00,781760,3,0,0
            t6,09:14:00,09:14:00,781770,4,0,0
            t7,09:00:00,09:00:00,781722,1,0,0
            t7,09:04:00,09:04:00,781726,2,0,0
            t7,09:07:00,09:07:00,781740,3,0,0
            t7,09:13:00,09:13:00,781750,4,0,0
            t7,09:16:00,09:16:00,781760,5,0,0
            t7,09:22:00,09:22:00,781770,6,0,0
            t8,23:00:00,23:00:00,781722,1,0,0
            t8,23:04:00,23:04:00,781726,2,0,0
            t8,23:07:00,23:07:00,781740,3,0,0
            t8,23:11:00,23:11:00,781717,4,0,0
            t8,23:16:00,23:16:00,781750,5,0,0
            t8,23:19:00,23:19:00,781760,6,0,0
            t8,23:25:00,23:25:00,781770,7,0,0
            t9,01:00:00,01:00:00,781718,1,0,0
            t9,01:03:00,01:03:00,781720,2,0,0
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            \(calendar)
            """),
            "feed_info.txt": d("""
            feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
            Trillium Solutions,http://www.trilliumtransit.com,en,20250601,20260601,UTC: 06-Jun-2025 17:34
            """),
        ]
    }

    private func expiredFeed() throws -> FerryFeed { try FerryBuilder.build([.path: files()], now: now) }

    // MARK: Expired timetable

    /// Timetable expired: stations, lines, directions and terminals are all there (map and "nearby stations" work as usual), but no departures can be computed.
    func testExpiredTimetableKeepsStationsAndLines() throws {
        let feed = try expiredFeed()
        let ids = Set(feed.routes.map(\.id))
        for code in ["NWK-WTC", "HOB-WTC", "JSQ-33", "HOB-33", "JSQ-HOB-33", "NWK-HAR", "WTC-33"] {
            XCTAssertTrue(ids.contains("PATH-" + code), code)
        }
        XCTAssertEqual(feed.route("PATH-NWK-WTC")?.name, "PATH Newark–World Trade Center")
        XCTAssertEqual(feed.route("PATH-NWK-WTC")?.color, "D93A30")
        XCTAssertTrue(FerryFeed.isPathRoute("PATH-HOB-33"))
        XCTAssertEqual(FerryFeed.Source.of(route: "PATH-HOB-33")?.system, .path)

        // Keep only one of each stop pattern (t1 and t2 are the same), with a nonexistent calendar; the Newark–Harrison shuttle is kept too
        XCTAssertEqual(feed.trips.count, 8)
        XCTAssertTrue(feed.trips.allSatisfy { $0.service == "path:pattern" })
        XCTAssertTrue(feed.services.isEmpty)
        XCTAssertTrue(feed.trips.contains { $0.route == "PATH-NWK-HAR" })
        // Toward New York (direction_id 1) is "S"
        XCTAssertEqual(feed.trips.first { $0.id == "path:t1" }?.direction, "S")
        XCTAssertEqual(feed.trips.first { $0.id == "path:t3" }?.direction, "N")

        // Only boarding platforms; no parent stations or entrances
        XCTAssertNil(feed.pier(id: "path:26733"))
        XCTAssertNil(feed.pier(id: "path:900001"))
        XCTAssertNotNil(feed.pier(id: "path:781719"))

        // Not hidden even when the timetable expires (only a ferry operator whose timetable ran out is hidden), and no daily check needed
        XCTAssertFalse(feed.idleSources(from: now).contains(.path))
        XCTAssertFalse(feed.endingSources(from: now).contains(.path))
        XCTAssertEqual(feed.active(from: now).piers.count, feed.piers.count)

        // Nearby station: Newark, 1.5 minutes to enter the station
        let near = feed.stations(near: Coordinate(latitude: 40.7350, longitude: -74.1640), radiusMeters: 400)
        XCTAssertFalse(near.isEmpty)
        XCTAssertTrue(near.allSatisfy { $0.name == "Newark" })
        XCTAssertEqual(near.first?.entranceToPlatformSeconds, 90)

        // No departures
        let arrivals = feed.arrivals(pierIDs: feed.piers.map(\.id), from: now, to: now.addingTimeInterval(4 * 3600),
                                     realtime: [], now: now)
        XCTAssertTrue(arrivals.isEmpty)

        // Direction title with no trains: toward World Trade Center
        let terminals = feed.terminals(atPier: "path:781718")
        XCTAssertTrue(terminals.contains { $0.route == "PATH-NWK-WTC" && $0.direction == "S" && $0.terminal == "World Trade Center" })
        // The map has lines and stations
        XCTAssertFalse(feed.map().stations.isEmpty)
    }

    /// With a new timetable (calendar includes today): used automatically, departures can be computed, and it no longer keeps only stop patterns.
    func testNewTimetableIsUsedAutomatically() throws {
        let feed = try FerryBuilder.build([.path: files(calendar: "EXP,1,1,1,1,1,1,1,20261001,20270101")], now: now)
        XCTAssertEqual(feed.trips.count, 9)
        XCTAssertTrue(feed.trips.allSatisfy { $0.service == "path:EXP" })
        XCTAssertNotNil(feed.services["path:EXP"])
        // After noon: the 23:00 from Journal Square via Hoboken to 33rd Street
        let arrivals = feed.arrivals(pierIDs: ["path:781722"], from: now, to: now.addingTimeInterval(12 * 3600),
                                     realtime: [], now: now)
        XCTAssertTrue(arrivals.contains { $0.route == "PATH-JSQ-HOB-33" && $0.source == .scheduled })
    }

    /// PATH live data isn't GTFS-Realtime: it's not part of the ferry/train live download pipeline.
    func testRealtimeSources() throws {
        XCTAssertTrue(FerryFeed.Source.path.hasRealtime)
        XCTAssertNil(FerryFeed.Source.path.realtimeURL)
        XCTAssertTrue(FerryFeed.realtimeSources(routes: ["PATH-NWK-WTC", "PATH-HOB-33"]).isEmpty)
        XCTAssertEqual(TransitSystem.path.mode, .subway)
        XCTAssertEqual(FerryFeed.Source.cases(for: .path), [.path])
    }

    // MARK: Live data

    private let sampleJSON = """
    {"results":[
     {"consideredStation":"NWK","destinations":[
       {"label":"ToNY","messages":[
         {"target":"WTC","secondsToArrival":"554","arrivalTimeMessage":"9 min","lineColor":"D93A30","headSign":"World Trade Center","lastUpdated":"2026-10-14T11:59:30.940598-04:00"},
         {"target":"WTC","arrivalTimeMessage":"?","lineColor":"D93A30","headSign":"World Trade Center","lastUpdated":"2026-10-14T11:59:30-04:00"}]}]},
     {"consideredStation":"HOB","destinations":[
       {"label":"ToNY","messages":[
         {"target":"33S","secondsToArrival":"120","lineColor":"4D92FB","headSign":"33rd Street","lastUpdated":"2026-10-14T11:59:30.9-04:00"},
         {"target":"WTC","secondsToArrival":"300","lineColor":"65C100","headSign":"World Trade Center","lastUpdated":"2026-10-14T11:59:30.9-04:00"}]}]},
     {"consideredStation":"JSQ","destinations":[
       {"label":"ToNY","messages":[
         {"target":"33S","secondsToArrival":"60","lineColor":"FF9900,4D92FB","headSign":"33rd Street via Hoboken","lastUpdated":"2026-10-14T11:59:30.12-04:00"},
         {"target":"33S","secondsToArrival":"400","lineColor":"ff9900","headSign":"33rd Street","lastUpdated":"2026-10-14T11:59:30.12-04:00"}]}]},
     {"consideredStation":"WTC","destinations":[
       {"label":"ToNJ","messages":[
         {"target":"NWK","secondsToArrival":"200","lineColor":"D93A30","headSign":"Newark","lastUpdated":"2026-10-14T12:05:00-04:00"}]}]},
     {"consideredStation":"XXX","destinations":[
       {"label":"ToNY","messages":[
         {"target":"WTC","secondsToArrival":"100","lineColor":"D93A30","headSign":"World Trade Center","lastUpdated":"2026-10-14T11:59:30-04:00"}]}]}
    ]}
    """

    func testDecode() throws {
        let live = try PathLive.decode(d(sampleJSON), fetchedAt: now)
        // Drop those without secondsToArrival
        XCTAssertEqual(live.trains.count, 7)
        let nwk = try XCTUnwrap(live.trains.first { $0.station == "NWK" })
        XCTAssertTrue(nwk.toNY)
        XCTAssertEqual(nwk.updatedAt, now.addingTimeInterval(-30))
        XCTAssertEqual(nwk.time, now.addingTimeInterval(-30 + 554))
        // The two colors are kept separate; lowercase becomes uppercase
        XCTAssertEqual(live.trains.first { $0.station == "JSQ" }?.colors, ["FF9900", "4D92FB"])
        XCTAssertEqual(live.trains.last { $0.station == "JSQ" }?.colors, ["FF9900"])
        // Data time newer than download time (clocks out of sync): use the download time
        let wtc = try XCTUnwrap(live.trains.first { $0.station == "WTC" })
        XCTAssertFalse(wtc.toNY)
        XCTAssertEqual(wtc.updatedAt, now)
        XCTAssertEqual(wtc.time, now.addingTimeInterval(200))
        XCTAssertEqual(live.updatedAt, now)
        XCTAssertThrowsError(try PathLive.decode(d("not json"), fetchedAt: now))
    }

    func testParseDate() {
        XCTAssertEqual(PathLive.parseDate("2026-10-14T12:00:00.940598-04:00"), now)
        XCTAssertEqual(PathLive.parseDate("2026-10-14T12:00:00-04:00"), now)
        XCTAssertEqual(PathLive.parseDate("2026-10-14T16:00:00.5Z"), now)
        XCTAssertNil(PathLive.parseDate("soon"))
    }

    /// Stations are matched by name (with several platforms, the smallest ID), lines by color and terminal; the direction toward New York is "S".
    func testArrivalsMapping() throws {
        let feed = try expiredFeed()
        let live = try PathLive.decode(d(sampleJSON), fetchedAt: now)
        let all = live.arrivals(feed: feed, pierIDs: feed.piers.map(\.id), from: now.addingTimeInterval(-60),
                                to: now.addingTimeInterval(3600))
        // XXX doesn't match a station
        XCTAssertEqual(all.count, 6)
        XCTAssertTrue(all.allSatisfy { $0.source == .realtime })
        XCTAssertEqual(all.map(\.arrivalTime), all.map(\.arrivalTime).sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) })

        let nwk = try XCTUnwrap(all.first { $0.stationID == "path:781718" })
        XCTAssertEqual(nwk.route, "PATH-NWK-WTC")
        XCTAssertEqual(nwk.direction.code, "S")
        XCTAssertEqual(nwk.direction.name, "To World Trade Center")
        XCTAssertEqual(nwk.direction.terminal, "World Trade Center")
        XCTAssertFalse(all.contains { $0.stationID == "path:781719" })

        let hob = all.filter { $0.stationID == "path:781715" }
        XCTAssertEqual(Set(hob.map(\.route)), ["PATH-HOB-33", "PATH-HOB-WTC"])
        let jsq = all.filter { $0.stationID == "path:781722" }
        XCTAssertEqual(jsq.map(\.route), ["PATH-JSQ-HOB-33", "PATH-JSQ-33"])

        let wtc = try XCTUnwrap(all.first { $0.stationID == "path:794724" })
        XCTAssertEqual(wtc.route, "PATH-NWK-WTC")
        XCTAssertEqual(wtc.direction.code, "N")
        XCTAssertEqual(wtc.direction.name, "To Newark")

        // Only the requested stations; drop those outside the time window
        let onlyHob = live.arrivals(feed: feed, pierIDs: ["path:781716", "path:781717"], from: now, to: now.addingTimeInterval(3600))
        XCTAssertEqual(onlyHob.count, 2)
        XCTAssertTrue(onlyHob.allSatisfy { $0.stationID == "path:781716" })
        let soon = live.arrivals(feed: feed, pierIDs: feed.piers.map(\.id), from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(Set(soon.map(\.stationID)), ["path:781722"])
        // Ignore stations that aren't PATH
        XCTAssertTrue(live.arrivals(feed: feed, pierIDs: ["nyf:1"], from: now, to: now.addingTimeInterval(3600)).isEmpty)
    }

    /// Merged: for the same station (any platform) and direction, drop timetable departures before the last live train (plus 1 minute).
    func testMergeLiveWithTimetable() throws {
        let feed = try expiredFeed()
        let toNY = Direction(code: "S", name: "To 33rd Street", terminal: "33rd Street")
        let toNJ = Direction(code: "N", name: "To Hoboken", terminal: "Hoboken")
        func a(_ id: String, _ pier: String, _ minutes: Double, _ dir: Direction, _ source: ArrivalSource) -> Arrival {
            Arrival(id: id, stationID: pier, route: "PATH-HOB-33", direction: dir,
                    arrivalTime: now.addingTimeInterval(minutes * 60), source: source, updatedAt: now)
        }
        let live = [a("l1", "path:781715", 2, toNY, .realtime), a("l2", "path:781715", 10, toNY, .realtime)]
        let timetable = [
            a("s1", "path:781717", 3, toNY, .scheduled),    // live data already has it
            a("s2", "path:781717", 10.5, toNY, .scheduled), // this is that live train
            a("s3", "path:781717", 15, toNY, .scheduled),   // after the live data
            a("s4", "path:781716", 4, toNJ, .scheduled),    // no live data in the other direction
            a("s5", "path:781750", 5, toNY, .scheduled),    // another station
        ]
        let merged = PathLive.merge(live: live, timetable: timetable, feed: feed)
        XCTAssertEqual(merged.map(\.id), ["l1", "s4", "s5", "l2", "s3"])
        // Only live ones (timetable expired)
        XCTAssertEqual(PathLive.merge(live: live, timetable: [], feed: feed).map(\.id), ["l1", "l2"])
    }

    /// Two trains to the same place from the same station get different IDs, and each keeps its ID when the predictions change
    func testIDsAreUniqueAndStable() throws {
        let feed = try expiredFeed()
        func json(_ first: Int, _ second: Int) -> String {
            let message = { (seconds: Int) in
                "{\"target\":\"33S\",\"secondsToArrival\":\"\(seconds)\",\"lineColor\":\"FF9900\",\"headSign\":\"33rd Street\","
                    + "\"lastUpdated\":\"2026-10-14T11:59:30-04:00\"}"
            }
            return "{\"results\":[{\"consideredStation\":\"JSQ\",\"destinations\":[{\"label\":\"ToNY\",\"messages\":["
                + message(first) + "," + message(second) + "]}]}]}"
        }
        func ids(_ s: String) throws -> [String] {
            try PathLive.decode(d(s), fetchedAt: now)
                .arrivals(feed: feed, pierIDs: feed.piers.map(\.id), from: now.addingTimeInterval(-60), to: now.addingTimeInterval(3600))
                .map(\.id)
        }
        let before = try ids(json(120, 600))
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before).count, 2)
        XCTAssertEqual(try ids(json(90, 560)), before, "Updated predictions keep the IDs")
    }

    /// When the first train leaves, the ones behind it keep their IDs (matched with the last refresh), and a train coming into view
    /// gets an ID none of the earlier ones had, so it never takes over the row of the train that left
    func testIDsFollowTheTrainsBetweenRefreshes() throws {
        let feed = try expiredFeed()
        func arrivals(_ seconds: [Int], previous: [Arrival]) throws -> [Arrival] {
            let messages = seconds.map {
                "{\"target\":\"33S\",\"secondsToArrival\":\"\($0)\",\"lineColor\":\"FF9900\",\"headSign\":\"33rd Street\","
                    + "\"lastUpdated\":\"2026-10-14T11:59:30-04:00\"}"
            }
            let text = "{\"results\":[{\"consideredStation\":\"JSQ\",\"destinations\":[{\"label\":\"ToNY\",\"messages\":["
                + messages.joined(separator: ",") + "]}]}]}"
            return try PathLive.decode(d(text), fetchedAt: now)
                .arrivals(feed: feed, pierIDs: feed.piers.map(\.id), from: now.addingTimeInterval(-600), to: now.addingTimeInterval(3600),
                          previous: previous)
        }
        let first = try arrivals([60, 480, 900], previous: [])
        XCTAssertEqual(Set(first.map(\.id)).count, 3)
        // A minute later: the first train left, the other two moved a little, and a new one shows up at the end
        let second = try arrivals([440, 870, 1500], previous: first)
        XCTAssertEqual(Array(second.map(\.id).prefix(2)), Array(first.map(\.id).suffix(2)))
        XCTAssertFalse(first.map(\.id).contains(second[2].id))
        XCTAssertEqual(Set(second.map(\.id)).count, 3)
        // A train whose prediction jumped by more than 3 minutes counts as another train; other kinds of arrivals are ignored
        let other = Arrival(id: "x|1", stationID: "path:781722", route: "PATH-JSQ-33", direction: second[0].direction,
                            arrivalTime: now, source: .realtime, updatedAt: now)
        let third = try arrivals([440 + 200, 870, 1500], previous: second + [other])
        XCTAssertFalse(second.map(\.id).contains(third[0].id))
        XCTAssertEqual(Array(third.map(\.id).suffix(2)), Array(second.map(\.id).suffix(2)))
        // Without the last refresh (e.g. the first one after launch), trains are numbered from 1 in time order
        XCTAssertEqual(first.map { $0.id.split(separator: "|").last }, ["1", "2", "3"])
    }

    // MARK: Real data (Mac only)

    /// CMT_PATH_ZIP points to the downloaded path-nj-us.zip, CMT_PATH_JSON to the downloaded ridepath.json.
    func testRealPathDataIfAvailable() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CMT_PATH_ZIP"] != nil || env["CMT_PATH_JSON"] != nil else { throw XCTSkip("CMT_PATH_ZIP / CMT_PATH_JSON not set") }
        var feed: FerryFeed?
        if let path = env["CMT_PATH_ZIP"] {
            #if canImport(Compression)
            let zip = try Data(contentsOf: URL(fileURLWithPath: path))
            let files = try ZipReader.read(zip, names: Array(FerryFeed.neededFiles))
            let built = try FerryBuilder.build([.path: files], now: Date())
            feed = built
            let names = Set(built.piers.map(\.name))
            print("path: \(built.routes.count) routes \(built.routes.map { "\($0.id) \($0.color)" }), \(built.piers.count) platforms, \(names.count) stations, \(built.trips.count) trips, services \(built.services.keys.sorted())")
            print("path: stations \(names.sorted())")
            print("path: map json \(try JSONEncoder().encode(built.map()).count) bytes, feed json \(try built.encoded().count) bytes")
            XCTAssertGreaterThanOrEqual(built.routes.count, 6)
            XCTAssertEqual(names.count, 13)
            for name in PathLive.stationNames.values { XCTAssertTrue(names.contains(name), "\(name) is missing from the timetable") }
            XCTAssertFalse(built.idleSources(from: Date()).contains(.path))
            for pier in ["Newark", "Hoboken", "33rd Street", "World Trade Center"] {
                guard let id = built.piers.first(where: { $0.name == pier })?.id else { continue }
                print("path: terminals at \(pier): \(built.terminals(atPier: id).map { "\($0.route) \($0.direction) \($0.terminal)" })")
            }
            #else
            throw XCTSkip("The Compression framework is only available on Apple platforms")
            #endif
        }
        if let path = env["CMT_PATH_JSON"] {
            let fetched = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            let live = try PathLive.decode(try Data(contentsOf: URL(fileURLWithPath: path)), fetchedAt: fetched)
            print("path live: \(live.trains.count) trains, updated \(live.updatedAt.map { "\($0)" } ?? "-"), stations \(Set(live.trains.map(\.station)).sorted()), colors \(Set(live.trains.flatMap(\.colors)).sorted())")
            XCTAssertFalse(live.trains.isEmpty)
            XCTAssertTrue(live.trains.allSatisfy { PathLive.stationNames[$0.station] != nil }, "Unknown station code")
            if let feed {
                let known = live.trains.filter { PathLive.stationNames[$0.station] != nil }
                let from = known.map(\.time).min() ?? Date(), to = known.map(\.time).max() ?? Date()
                let arrivals = live.arrivals(feed: feed, pierIDs: feed.piers.map(\.id), from: from, to: to)
                for a in arrivals.prefix(40) {
                    print("path live: \(feed.pier(id: a.stationID)?.name ?? a.stationID) \(a.direction.code) \(a.route) \(a.direction.name) in \(Int((a.arrivalTime ?? from).timeIntervalSince(fetched)))s")
                }
                XCTAssertEqual(arrivals.count, known.count)
            }
        }
    }
}
