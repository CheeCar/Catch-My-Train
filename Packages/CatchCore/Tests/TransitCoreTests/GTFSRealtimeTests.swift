import XCTest
@testable import TransitCore

/// Minimal Protocol Buffers encoder for tests, used to build GTFS-Realtime test data.
private struct PB {
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

    mutating func int(_ field: Int, _ v: UInt64) {
        bytes += PB.varint(UInt64(field << 3 | 0)) + PB.varint(v)
    }

    mutating func int64(_ field: Int, _ v: Int64) { int(field, UInt64(bitPattern: v)) }

    mutating func bytes(_ field: Int, _ b: [UInt8]) {
        bytes += PB.varint(UInt64(field << 3 | 2)) + PB.varint(UInt64(b.count)) + b
    }

    mutating func string(_ field: Int, _ s: String) { bytes(field, Array(s.utf8)) }

    mutating func message(_ field: Int, _ build: (inout PB) -> Void) {
        var sub = PB()
        build(&sub)
        bytes(field, sub.bytes)
    }

    mutating func fixed32(_ field: Int, _ v: UInt32) {
        bytes += PB.varint(UInt64(field << 3 | 5))
        bytes += withUnsafeBytes(of: v.littleEndian, Array.init)
    }

    mutating func fixed64(_ field: Int, _ v: UInt64) {
        bytes += PB.varint(UInt64(field << 3 | 1))
        bytes += withUnsafeBytes(of: v.littleEndian, Array.init)
    }
}

final class GTFSRealtimeTests: XCTestCase {

    let t0: Int64 = 1_800_000_000

    override func setUp() { NetworkReach.reset() }
    override func tearDown() { NetworkReach.reset() }

    /// Build a feed with two trips: a normal L trip, a canceled 6 trip, and various MTA extension fields.
    func sampleFeed() -> Data {
        var feed = PB()
        feed.message(1) { h in
            h.string(1, "1.0")
            h.int(2, 0)
            h.int(3, UInt64(t0))
            h.message(1001) { ext in ext.string(1, "1.0") } // NYCT extension: should be skipped
        }
        // Trip 1: L line, 3 stops
        feed.message(2) { e in
            e.string(1, "000001L")
            e.message(3) { tu in
                tu.message(1) { trip in
                    trip.string(1, "123456_L..N")
                    trip.string(3, "20261013")
                    trip.string(5, "L")
                    trip.message(1001) { x in x.string(1, "1L 0123+ RPY/8AV"); x.int(2, 1) }
                }
                tu.message(2) { s in // has both arrival and departure times
                    s.message(2) { a in a.int64(2, t0 + 120) }
                    s.message(3) { d in d.int64(2, t0 + 150) }
                    s.string(4, "L03N")
                }
                tu.message(2) { s in // departure time only (origin)
                    s.message(3) { d in d.int64(2, t0 + 300) }
                    s.string(4, "L02N")
                }
                tu.message(2) { s in // skips this stop
                    s.message(2) { a in a.int64(2, t0 + 400) }
                    s.string(4, "L01N")
                    s.int(5, 1) // SKIPPED
                }
                tu.int(4, UInt64(t0 - 10))
            }
        }
        // Trip 2: 6 line, entire trip canceled
        feed.message(2) { e in
            e.string(1, "000002")
            e.message(3) { tu in
                tu.message(1) { trip in
                    trip.string(1, "654321_6..S")
                    trip.int(4, 3) // CANCELED
                    trip.string(5, "6X") // express marker, should be merged into 6
                }
                tu.message(2) { s in
                    s.message(2) { a in a.int64(2, t0 + 200) }
                    s.string(4, "635S")
                }
            }
        }
        // Deleted entity: should be ignored
        feed.message(2) { e in
            e.string(1, "000003")
            e.int(2, 1)
            e.message(3) { tu in
                tu.message(1) { trip in trip.string(5, "L") }
                tu.message(2) { s in s.message(2) { a in a.int64(2, t0 + 60) }; s.string(4, "L03S") }
            }
        }
        // Vehicle position entity (field 4): should be ignored
        feed.message(2) { e in
            e.string(1, "000004")
            e.message(4) { v in v.int(1, 7); v.fixed32(9, 12345); v.fixed64(10, 99) }
        }
        return Data(feed.bytes)
    }

    func testDecodeHeaderAndTrips() throws {
        let feed = try GTFSRealtimeFeed.decode(sampleFeed())
        XCTAssertEqual(feed.timestamp, Date(timeIntervalSince1970: TimeInterval(t0)))
        XCTAssertEqual(feed.tripUpdates.count, 2, "Deleted entities and vehicle position entities should be ignored")

        let l = feed.tripUpdates[0]
        XCTAssertEqual(l.entityID, "000001L")
        XCTAssertEqual(l.tripID, "123456_L..N")
        XCTAssertEqual(l.routeID, "L")
        XCTAssertEqual(l.startDate, "20261013")
        XCTAssertFalse(l.isCanceled)
        XCTAssertEqual(l.timestamp, Date(timeIntervalSince1970: TimeInterval(t0 - 10)))
        XCTAssertEqual(l.stopTimeUpdates.map(\.stopID), ["L03N", "L02N", "L01N"])
        XCTAssertEqual(l.stopTimeUpdates[0].arrivalTime, Date(timeIntervalSince1970: TimeInterval(t0 + 120)))
        XCTAssertEqual(l.stopTimeUpdates[0].departureTime, Date(timeIntervalSince1970: TimeInterval(t0 + 150)))
        XCTAssertNil(l.stopTimeUpdates[1].arrivalTime)
        XCTAssertTrue(l.stopTimeUpdates[2].isSkipped)

        XCTAssertTrue(feed.tripUpdates[1].isCanceled)
    }

    /// A feed stuck at an old time: two reads in a row show "not updating", counted from the feed's time; fresh data clears it
    /// SEPTA's trains: each stop only by its stop_sequence, with a delay and its uncertainty (no stop_id, no time, no start_date);
    /// a canceled train lists no stops
    func testStopSequenceWithoutStopID() throws {
        var pb = PB()
        pb.message(1) { h in h.string(1, "2.0"); h.int(2, 0); h.int(3, UInt64(t0)) }
        pb.message(2) { e in
            e.string(1, "1")
            e.message(3) { tu in
                tu.message(1) { trip in trip.string(1, "AIR7419_20261019_SID189798"); trip.int(4, 0); trip.string(5, "AIR"); trip.int(6, 1) }
                tu.message(2) { s in s.int(1, 12); s.message(2) { a in a.int(1, 420); a.int(3, 60) } }
            }
        }
        pb.message(2) { e in
            e.string(1, "2")
            e.message(3) { tu in
                tu.message(1) { trip in trip.string(1, "AIR416_20261019_SID189798"); trip.int(4, 3); trip.string(5, "AIR") }
            }
        }
        let feed = try GTFSRealtimeFeed.decode(Data(pb.bytes))
        XCTAssertEqual(feed.tripUpdates.count, 2)
        let running = feed.tripUpdates[0]
        XCTAssertEqual(running.startDate, "")
        XCTAssertEqual(running.stopTimeUpdates.count, 1)
        XCTAssertEqual(running.stopTimeUpdates[0].stopID, "")
        XCTAssertEqual(running.stopTimeUpdates[0].stopSequence, 12)
        XCTAssertEqual(running.stopTimeUpdates[0].delaySeconds, 420)
        XCTAssertNil(running.stopTimeUpdates[0].arrivalTime)
        XCTAssertTrue(feed.tripUpdates[1].isCanceled)
        let rt = FerryRealtime(feed: feed, fetchedAt: Date(timeIntervalSince1970: TimeInterval(t0)), source: .septaRail)
        XCTAssertEqual(rt.trips["AIR7419_20261019_SID189798"]?.stopTimes, [.init(stopID: "", delay: 420, sequence: 12)])
        XCTAssertEqual(rt.trips["AIR416_20261019_SID189798"]?.canceled, true)
        // Data that names stops by stop_id has no stop_sequence unless it gives one
        XCTAssertNil(try GTFSRealtimeFeed.decode(sampleFeed()).tripUpdates[0].stopTimeUpdates[0].stopSequence)
    }

    func testStuckFeedShowsNoticeThroughDecode() throws {
        let url = URL(string: "https://example.com/gtfs-rt")!
        let made = Date(timeIntervalSince1970: TimeInterval(t0))
        let late = made.addingTimeInterval(NetworkReach.staleAfter + 60)
        _ = try GTFSRealtimeFeed.decode(sampleFeed(), from: url, provider: "Ferry", now: late)
        XCTAssertTrue(NetworkReach.notices(now: late).isEmpty, "One old read isn't enough")
        _ = try GTFSRealtimeFeed.decode(sampleFeed(), from: url, provider: "Ferry", now: late.addingTimeInterval(30))
        let n = NetworkReach.notices(now: late.addingTimeInterval(31))
        XCTAssertEqual(n.map(\.problem), [.stale])
        XCTAssertEqual(n.first?.since, made)
        _ = try GTFSRealtimeFeed.decode(sampleFeed(), from: url, provider: "Ferry", now: made.addingTimeInterval(60))
        XCTAssertTrue(NetworkReach.notices(now: made.addingTimeInterval(61)).isEmpty)
        // Unreadable data is still recorded, and a later readable but old read replaces it
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data([0x0A, 0xFF, 0x01]), from: url, provider: "Ferry", now: late))
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data([0x0A, 0xFF, 0x01]), from: url, provider: "Ferry", now: late))
        XCTAssertEqual(NetworkReach.notices(now: late).map(\.problem), [.badData])
        _ = try GTFSRealtimeFeed.decode(sampleFeed(), from: url, provider: "Ferry", now: late)
        _ = try GTFSRealtimeFeed.decode(sampleFeed(), from: url, provider: "Ferry", now: late)
        XCTAssertEqual(NetworkReach.notices(now: late).map(\.problem), [.stale])
    }

    /// GTFS-Realtime's newer DELETED (7) counts as canceled, same as CANCELED (3)
    func testDeletedTripCountsAsCancelled() throws {
        var feed = PB()
        feed.message(1) { h in h.string(1, "2.0"); h.int(3, UInt64(t0)) }
        feed.message(2) { e in
            e.string(1, "del")
            e.message(3) { tu in
                tu.message(1) { trip in trip.string(1, "999_7..N"); trip.int(4, 7); trip.string(5, "7") }
                tu.message(2) { s in s.message(2) { a in a.int64(2, t0 + 60) }; s.string(4, "712N") }
            }
        }
        let decoded = try GTFSRealtimeFeed.decode(Data(feed.bytes))
        XCTAssertTrue(try XCTUnwrap(decoded.tripUpdates.first).isCanceled)
    }

    /// When the local clock is far off from the server, decisions use server time (HTTP Date header)
    func testClockSkew() throws {
        defer { ClockSkew.set(0) }
        let header = "Fri, 16 Oct 2026 02:00:00 GMT"
        let server = try XCTUnwrap(ClockSkew.parse(header))
        XCTAssertEqual(server, ISO8601DateFormatter().date(from: "2026-10-16T02:00:00Z"))
        ClockSkew.set(10)
        XCTAssertEqual(ClockSkew.current, 0, "Under 30 seconds counts as no offset")
        ClockSkew.set(-200)
        XCTAssertEqual(ClockSkew.current, -200)
        ClockSkew.set(3 * 3600)
        XCTAssertEqual(ClockSkew.current, 0, "Absurd offsets (e.g. an old cached response) are not used")
        // Local clock 4 minutes fast: the data looks 4 minutes old but is actually fresh
        ClockSkew.set(-240)
        let local = Date(timeIntervalSince1970: TimeInterval(t0) + 240)
        let arrival = Arrival(id: "a", stationID: "712", route: "7", direction: Direction(code: "N", name: "To Flushing-Main St"),
                              arrivalTime: Date(timeIntervalSince1970: TimeInterval(t0) + 900), source: .realtime,
                              updatedAt: Date(timeIntervalSince1970: TimeInterval(t0)))
        let e = CatchEvaluator.evaluate(arrival: arrival, walk: WalkEstimate(walkSeconds: 300, straightLineMeters: 300, source: .route),
                                        entranceToPlatformSeconds: 90, settings: .default, now: local)
        XCTAssertFalse(e.notes.contains(.staleRealtime))
        XCTAssertEqual(e.secondsUntilTrain ?? 0, 900, accuracy: 0.001)
    }

    func testMapperFiltersStationsAndUsesBestTime() throws {
        let feed = try GTFSRealtimeFeed.decode(sampleFeed())
        let fallback = Date(timeIntervalSince1970: 1)
        let arrivals = GTFSRealtimeMapper.arrivals(
            from: feed, stationIDs: ["L03", "L02", "L01", "635"], fallbackUpdatedAt: fallback,
            direction: { _, _, code in Direction(code: code, name: code) })

        let byStop = Dictionary(uniqueKeysWithValues: arrivals.map { ($0.stationID, $0) })
        XCTAssertEqual(arrivals.count, 4)

        // Use the arrival time when there is one
        XCTAssertEqual(byStop["L03"]?.arrivalTime, Date(timeIntervalSince1970: TimeInterval(t0 + 120)))
        XCTAssertEqual(byStop["L03"]?.direction.code, "N")
        XCTAssertEqual(byStop["L03"]?.source, .realtime)
        // The trip's own timestamp takes precedence over the feed's timestamp
        XCTAssertEqual(byStop["L03"]?.updatedAt, Date(timeIntervalSince1970: TimeInterval(t0 - 10)))
        // Use the departure time when that's all there is
        XCTAssertEqual(byStop["L02"]?.arrivalTime, Date(timeIntervalSince1970: TimeInterval(t0 + 300)))
        // Skipped stop → treated as canceled
        XCTAssertEqual(byStop["L01"]?.status, .cancelled)
        // Entire trip canceled; 6X merged into 6; without a trip timestamp, use the feed's timestamp
        XCTAssertEqual(byStop["635"]?.status, .cancelled)
        XCTAssertEqual(byStop["635"]?.route, "6")
        XCTAssertEqual(byStop["635"]?.direction.code, "S")
        XCTAssertEqual(byStop["635"]?.updatedAt, Date(timeIntervalSince1970: TimeInterval(t0)))
    }

    func testMapperIgnoresOtherStations() throws {
        let feed = try GTFSRealtimeFeed.decode(sampleFeed())
        let arrivals = GTFSRealtimeMapper.arrivals(
            from: feed, stationIDs: ["L03"], fallbackUpdatedAt: Date(),
            direction: { _, _, c in Direction(code: c, name: c) })
        XCTAssertEqual(arrivals.map(\.stationID), ["L03"])
    }

    func testNoDataStopHasNoPrediction() throws {
        var feed = PB()
        feed.message(2) { e in
            e.string(1, "x")
            e.message(3) { tu in
                tu.message(1) { t in t.string(5, "Q") }
                tu.message(2) { s in s.string(4, "R20N"); s.int(5, 2) } // NO_DATA
            }
        }
        let parsed = try GTFSRealtimeFeed.decode(Data(feed.bytes))
        XCTAssertNil(parsed.timestamp)
        let fallback = Date(timeIntervalSince1970: 42)
        let a = GTFSRealtimeMapper.arrivals(from: parsed, stationIDs: ["R20"], fallbackUpdatedAt: fallback,
                                            direction: { _, _, c in Direction(code: c, name: c) })
        XCTAssertEqual(a.count, 1)
        XCTAssertNil(a[0].arrivalTime)
        XCTAssertEqual(a[0].updatedAt, fallback, "Use the download time when there is no timestamp at all")
    }

    func testSplitStopID() {
        XCTAssertEqual(GTFSRealtimeMapper.splitStopID("635N")?.0, "635")
        XCTAssertEqual(GTFSRealtimeMapper.splitStopID("635N")?.1, "N")
        XCTAssertEqual(GTFSRealtimeMapper.splitStopID("R20S")?.0, "R20")
        XCTAssertNil(GTFSRealtimeMapper.splitStopID("635"))
        XCTAssertNil(GTFSRealtimeMapper.splitStopID("N"))
        XCTAssertNil(GTFSRealtimeMapper.splitStopID(""))
    }

    func testTruncatedDataThrows() {
        let full = sampleFeed()
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(full.prefix(full.count - 3)))
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data([0x0A, 0xFF]))) // length out of range
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data([0x0B]))) // unsupported wire type 3
    }

    /// More trips, or more stops in one trip, than any real feed has: refused as unreadable instead of filling memory
    func testTooManyTripsOrStopsAreRefused() throws {
        func feed(entities: Int, stops: Int) -> Data {
            var pb = PB()
            for e in 0..<entities {
                pb.message(2) { entity in
                    entity.string(1, "e\(e)")
                    entity.message(3) { update in
                        update.message(1) { $0.string(1, "T\(e)") }
                        for s in 0..<stops { update.message(2) { $0.string(4, "S\(s)") } }
                    }
                }
            }
            return Data(pb.bytes)
        }
        XCTAssertEqual(try GTFSRealtimeFeed.decode(feed(entities: GTFSRealtimeFeed.maxEntities, stops: 1)).tripUpdates.count,
                       GTFSRealtimeFeed.maxEntities)
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(feed(entities: GTFSRealtimeFeed.maxEntities + 1, stops: 1))) { error in
            XCTAssertEqual(error as? ProtobufError, .tooMany)
        }
        XCTAssertEqual(try GTFSRealtimeFeed.decode(feed(entities: 1, stops: GTFSRealtimeFeed.maxStopsPerTrip)).tripUpdates.first?
            .stopTimeUpdates.count, GTFSRealtimeFeed.maxStopsPerTrip)
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(feed(entities: 1, stops: GTFSRealtimeFeed.maxStopsPerTrip + 1))) { error in
            XCTAssertEqual(error as? ProtobufError, .tooMany)
        }
    }

    /// An empty answer is not a feed: it throws, so the trains of the last good download stay (RealtimeLoad.merged). A header with
    /// no trip is a feed with no train now; a header with trips, the usual one
    func testEmptyDataIsNotAFeed() throws {
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data())) { XCTAssertEqual($0 as? ProtobufError, .empty) }
        var unknown = PB()
        unknown.int64(9, 1) // a field a feed doesn't have, and nothing else
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data(unknown.bytes))) { XCTAssertEqual($0 as? ProtobufError, .empty) }
        var headerOnly = PB()
        headerOnly.message(1) { h in h.int64(3, 1_800_000_000) }
        let none = try GTFSRealtimeFeed.decode(Data(headerOnly.bytes))
        XCTAssertEqual(none.timestamp, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(none.tripUpdates.isEmpty)
        XCTAssertTrue(try GTFSRealtimeFeed.decode(Data([0x0A, 0x00])).tripUpdates.isEmpty, "An empty header is still a header")
        XCTAssertFalse(try GTFSRealtimeFeed.decode(sampleFeed()).tripUpdates.isEmpty)
    }

    func testLargeVarintAndNegativeTimeAreSafe() throws {
        var feed = PB()
        feed.message(1) { h in h.int64(3, -5) } // negative timestamp: treated as missing
        let parsed = try GTFSRealtimeFeed.decode(Data(feed.bytes))
        XCTAssertNil(parsed.timestamp)

        // An 11-byte varint is invalid
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data([0x08] + Array(repeating: 0xFF, count: 10) + [0x01])))
    }

    /// NYCT's own trip fields: is_assigned says whether a train has been put on the trip yet
    func testAssignedFlagIsRead() throws {
        var pb = PB()
        for (id, assigned) in [("yes", UInt64?.some(1)), ("no", 0), ("unknown", nil)] {
            pb.message(2) { e in
                e.string(1, id)
                e.message(3) { tu in
                    tu.message(1) { t in
                        t.string(1, id)
                        t.string(5, "L")
                        if let assigned { t.message(1001) { x in x.string(1, "1L 0123+ RPY/8AV"); x.int(2, assigned); x.int(3, 1) } }
                    }
                    tu.message(2) { s in s.message(2) { a in a.int64(2, t0 + 300) }; s.string(4, "L03N") }
                }
            }
        }
        let feed = try GTFSRealtimeFeed.decode(Data(pb.bytes))
        XCTAssertEqual(feed.tripUpdates.map(\.isAssigned), [true, false, nil])
        XCTAssertEqual(try GTFSRealtimeFeed.decode(sampleFeed()).tripUpdates.first?.isAssigned, true)
        let arrivals = GTFSRealtimeMapper.arrivals(from: feed, stationIDs: ["L03"], fallbackUpdatedAt: Date(),
                                                   direction: { _, _, c in Direction(code: c, name: c) })
        XCTAssertEqual(arrivals.map(\.isAssigned), [true, false, nil])
        XCTAssertEqual(arrivals.map(\.isTimetableTime), [false, true, false])
    }

    /// The same trip ID on two service days is two trains (each keeps its own row); the same trip listed twice is one train,
    /// and the board keeps only its most recently updated copy (every train row needs its own ID)
    func testSameTripIDKeepsDaysApartAndRepeatsOnce() throws {
        func trip(_ entity: String, _ date: String, at t: Double, updated: Double) -> GTFSRealtimeFeed.TripUpdate {
            .init(entityID: entity, tripID: "074650_7..N", routeID: "7", startDate: date, isCanceled: false,
                  timestamp: Date(timeIntervalSince1970: updated),
                  stopTimeUpdates: [.init(stopID: "712N", arrivalTime: Date(timeIntervalSince1970: t), departureTime: nil,
                                          isSkipped: false, hasNoData: false)])
        }
        let feed = GTFSRealtimeFeed(timestamp: Date(timeIntervalSince1970: 1000), tripUpdates: [
            trip("a", "20261025", at: 1100, updated: 990),
            trip("b", "20261026", at: 1500, updated: 990),
            trip("c", "20261026", at: 1600, updated: 995),
        ])
        let arrivals = GTFSRealtimeMapper.arrivals(from: feed, stationIDs: ["712"], fallbackUpdatedAt: Date(),
                                                   direction: { _, _, c in Direction(code: c, name: c) })
        XCTAssertEqual(arrivals.map(\.id), ["074650_7..N@20261025|712N", "074650_7..N@20261026|712N", "074650_7..N@20261026|712N"])
        let unique = NearbyBoardBuilder.uniqueByID(arrivals)
        XCTAssertEqual(unique.map(\.arrivalTime), [Date(timeIntervalSince1970: 1100), Date(timeIntervalSince1970: 1600)])
        XCTAssertEqual(NearbyBoardBuilder.tripKey(unique[0]), "074650_7..N@20261025|7", "the trip key still drops only the stop")
    }
}

final class MTAFeedTests: XCTestCase {

    func testRouteToFeed() {
        XCTAssertEqual(MTAFeed.feed(forRoute: "1"), .numbered)
        XCTAssertEqual(MTAFeed.feed(forRoute: "6X"), .numbered)
        XCTAssertEqual(MTAFeed.feed(forRoute: "GS"), .numbered)
        XCTAssertEqual(MTAFeed.feed(forRoute: "A"), .ace)
        XCTAssertEqual(MTAFeed.feed(forRoute: "H"), .ace)
        XCTAssertEqual(MTAFeed.feed(forRoute: "FS"), .ace)
        XCTAssertEqual(MTAFeed.feed(forRoute: "FX"), .bdfm)
        XCTAssertEqual(MTAFeed.feed(forRoute: "G"), .g)
        XCTAssertEqual(MTAFeed.feed(forRoute: "Z"), .jz)
        XCTAssertEqual(MTAFeed.feed(forRoute: "W"), .nqrw)
        XCTAssertEqual(MTAFeed.feed(forRoute: "L"), .l)
        XCTAssertEqual(MTAFeed.feed(forRoute: "SI"), .sir)
        XCTAssertNil(MTAFeed.feed(forRoute: "X9"))
    }

    func testFeedURL() {
        XCTAssertEqual(MTAFeed.ace.url.absoluteString, "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-ace")
        XCTAssertEqual(MTAFeed.numbered.url.absoluteString, "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs")
    }

    func testRouteBadge() {
        XCTAssertEqual(MTARoute.badge("GS"), "S")
        XCTAssertEqual(MTARoute.badge("6X"), "6")
        XCTAssertEqual(MTARoute.badge("SI"), "SIR")
        XCTAssertEqual(MTARoute.badge("Q"), "Q")
    }
}

final class StationCatalogTests: XCTestCase {

    func testBundledCatalogLoads() throws {
        let c = try StationCatalog.loadBundled()
        XCTAssertGreaterThan(c.entries.count, 400)
        let union = try XCTUnwrap(c.entry(id: "635"))
        XCTAssertEqual(union.name, "14 St-Union Sq")
        XCTAssertEqual(union.lat, 40.7347, accuracy: 0.001)
        XCTAssertTrue(union.routes.contains { $0.route == "4" })
    }

    func testNearbyStationsAroundUnionSquare() throws {
        let c = try StationCatalog.loadBundled()
        let near = c.stations(near: Coordinate(latitude: 40.7359, longitude: -73.9906), radiusMeters: 400)
        let ids = Set(near.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["635", "L03", "R20"]), "All three Union Square GTFS stations should be within 400 m")
        // Sorted by distance
        let d = near.map { WalkEstimator.distanceMeters(Coordinate(latitude: 40.7359, longitude: -73.9906), $0.coordinate) }
        XCTAssertEqual(d, d.sorted())
    }

    func testDirectionNamesFromSignageAndTerminals() throws {
        let c = try StationCatalog.loadBundled()
        // L line at 14 St-Union Sq: signage says "West Side", terminal 8 Av
        let north = c.direction(stationID: "L03", route: "L", code: "N")
        XCTAssertEqual(north.label, "West Side")
        XCTAssertEqual(north.name, "West Side")
        XCTAssertEqual(north.terminal, "8 Av", "The UI can also use the terminal name")
        // 7 line at 61 St-Woodside: signage toward Manhattan says "Manhattan";
        // toward Flushing it only says "Outbound", so use the terminal "To Flushing-Main St" instead
        let toManhattan = c.direction(stationID: "712", route: "7", code: "S")
        XCTAssertEqual(toManhattan.label, "Manhattan")
        XCTAssertEqual(toManhattan.terminal, "34 St-Hudson Yards")
        let toFlushing = c.direction(stationID: "712", route: "7X", code: "N")
        XCTAssertNil(toFlushing.label)
        XCTAssertEqual(toFlushing.name, "To Flushing-Main St")
        XCTAssertEqual(toFlushing.terminal, "Flushing-Main St")
        // Unknown route with no signage direction name falls back to Northbound / Southbound
        let unknown = c.direction(stationID: "101", route: "Q", code: "N")
        XCTAssertEqual(unknown.name, "Northbound")
    }

    func testEveryStationHasComplexAndLabels() throws {
        let c = try StationCatalog.loadBundled()
        for e in c.entries {
            XCTAssertNotNil(e.complex, e.id)
            XCTAssertNotNil(e.borough, e.id)
            XCTAssertNotNil(e.northLabel, e.id)
            XCTAssertNotNil(e.southLabel, e.id)
        }
        XCTAssertEqual(c.station(id: "D16")?.complexID, "609")
    }

    func testComplexes() throws {
        let c = try StationCatalog.loadBundled()
        // Like the timetable, find stations in the same complex by complex key (NearbyBoardBuilder.complexKey)
        func members(_ id: String) throws -> Set<String> {
            let key = NearbyBoardBuilder.complexKey(try XCTUnwrap(c.station(id: id)))
            return Set(c.entries.compactMap { c.station(id: $0.id) }
                .filter { NearbyBoardBuilder.complexKey($0) == key }.map(\.id))
        }
        // 42 St-Bryant Pk (B D F M) and 5 Av (7) are connected inside
        XCTAssertEqual(try members("D16"), ["D16", "724"])
        // Times Sq complex: 1 2 3, 7, N Q R W, S, plus 42 St-Port Authority (A C E)
        XCTAssertEqual(try members("127"), ["127", "725", "902", "R16", "A27"])
        XCTAssertEqual(try members("712"), ["712"])
    }

    func testTrainsEndingHereAreRecognised() throws {
        let c = try StationCatalog.loadBundled()
        XCTAssertTrue(c.terminates(stationID: "726", route: "7", code: "S"), "Southbound 7 terminates at 34 St-Hudson Yards")
        XCTAssertFalse(c.terminates(stationID: "726", route: "7", code: "N"))
        XCTAssertTrue(c.terminates(stationID: "101", route: "1", code: "N"))
        XCTAssertFalse(c.terminates(stationID: "712", route: "7", code: "N"))
        XCTAssertFalse(c.terminates(stationID: "712", route: "7", code: "S"))
        XCTAssertTrue(c.terminates(stationID: "902", route: "GS", code: "N"), "Northbound 42 St Shuttle terminates at Times Sq")
    }

    func testRoutesAtStationsAreNormalized() throws {
        let c = try StationCatalog.loadBundled()
        let routes = c.routes(atStations: ["635"])
        XCTAssertTrue(routes.contains("6"))
        XCTAssertFalse(routes.contains("6X"))
    }
}

/// Fake downloader: returns preset data or errors by URL.
private struct FakeFetcher: DataFetching {
    var responses: [String: Result<Data, FeedFetchError>]
    func fetch(_ url: URL) async throws -> Data {
        guard let r = responses[url.absoluteString] else { throw FeedFetchError.httpStatus(404) }
        return try r.get()
    }
}

final class MTARealtimeLoaderTests: XCTestCase {

    func catalog() -> StationCatalog {
        StationCatalog(entries: [
            .init(id: "L03", name: "14 St-Union Sq", lat: 40.7348, lon: -73.9907,
                  routes: [.init(route: "L", north: "8 Av", south: "Canarsie-Rockaway Pkwy")]),
            .init(id: "635", name: "14 St-Union Sq", lat: 40.7347, lon: -73.9900,
                  routes: [.init(route: "6", north: "Pelham Bay Park", south: "Brooklyn Bridge-City Hall"),
                           .init(route: "6X", north: "Pelham Bay Park", south: "Brooklyn Bridge-City Hall")]),
        ])
    }

    /// One trip stopping at `stop` and then going on (to a station outside the test catalog), so it doesn't end there
    func feedData(stop: String, route: String, ts: Int64) -> Data {
        var feed = PB()
        feed.message(1) { h in h.int(3, UInt64(ts)) }
        feed.message(2) { e in
            e.string(1, "1")
            e.message(3) { tu in
                tu.message(1) { t in t.string(1, "trip-\(route)"); t.string(5, route) }
                tu.message(2) { s in s.message(2) { a in a.int64(2, ts + 600) }; s.string(4, stop) }
                tu.message(2) { s in s.message(2) { a in a.int64(2, ts + 720) }; s.string(4, "Z99" + String(stop.suffix(1))) }
            }
        }
        return Data(feed.bytes)
    }

    func testOnlyNeededFeedsAreRequested() {
        let loader = MTARealtimeLoader(catalog: catalog(), fetcher: FakeFetcher(responses: [:]))
        XCTAssertEqual(loader.feeds(forStations: ["L03"]), [.l])
        XCTAssertEqual(Set(loader.feeds(forStations: ["L03", "635"])), [.l, .numbered])
    }

    func testLoadMergesFeedsAndReportsFailures() async {
        let fetcher = FakeFetcher(responses: [
            MTAFeed.l.url.absoluteString: .success(feedData(stop: "L03N", route: "L", ts: 1_800_000_000)),
            MTAFeed.numbered.url.absoluteString: .failure(.httpStatus(503)),
        ])
        let loader = MTARealtimeLoader(catalog: catalog(), fetcher: fetcher)
        let load = await loader.load(stationIDs: ["L03", "635"])
        XCTAssertEqual(load.arrivals.count, 1)
        XCTAssertEqual(load.arrivals.first?.direction.name, "To 8 Av")
        XCTAssertEqual(load.failedFeeds, [.numbered])
        XCTAssertFalse(load.allFailed)
        XCTAssertEqual(load.statuses.count, 2)
    }

    func testTrainsEndingAtThisStationAreDropped() async {
        // 34 St-Hudson Yards is the 7 line terminal: southbound trains go no further here, so they can't be ridden
        let cat = StationCatalog(entries: [
            .init(id: "726", name: "34 St-Hudson Yards", lat: 40.7555, lon: -74.0022,
                  routes: [.init(route: "7", north: "Flushing-Main St", south: "34 St-Hudson Yards")]),
        ])
        var feed = PB()
        feed.message(1) { h in h.int(3, 1_800_000_000) }
        // The southbound trip ends here; the northbound one starts here and goes on to 725 (outside this catalog)
        for (n, stops) in [["726S"], ["726N", "725N"]].enumerated() {
            feed.message(2) { e in
                e.string(1, "\(n)")
                e.message(3) { tu in
                    tu.message(1) { t in t.string(1, "trip\(n)"); t.string(5, "7") }
                    for (k, stop) in stops.enumerated() {
                        tu.message(2) { s in s.message(2) { a in a.int64(2, 1_800_000_600 + Int64(k) * 120) }; s.string(4, stop) }
                    }
                }
            }
        }
        let fetcher = FakeFetcher(responses: [MTAFeed.numbered.url.absoluteString: .success(Data(feed.bytes))])
        let load = await MTARealtimeLoader(catalog: cat, fetcher: fetcher).load(stationIDs: ["726"])
        XCTAssertEqual(load.arrivals.map(\.direction.code), ["N"])
        XCTAssertEqual(load.arrivals.first?.direction.terminal, "Flushing-Main St")
    }

    func testTerminalComesFromTheTripsLastStop() async throws {
        // The A line has several terminals: use the last stop in this trip's realtime data
        let cat = StationCatalog(entries: [
            .init(id: "A27", name: "42 St-Port Authority Bus Terminal", lat: 40.757, lon: -73.989,
                  routes: [.init(route: "A", north: "Inwood-207 St", south: "Far Rockaway-Mott Av")]),
            .init(id: "A65", name: "Ozone Park-Lefferts Blvd", lat: 40.686, lon: -73.825, routes: []),
        ])
        var feed = PB()
        feed.message(1) { h in h.int(3, 1_800_000_000) }
        feed.message(2) { e in
            e.string(1, "1")
            e.message(3) { tu in
                tu.message(1) { t in t.string(1, "tripA"); t.string(5, "A") }
                tu.message(2) { s in s.message(2) { a in a.int64(2, 1_800_000_300) }; s.string(4, "A27S") }
                tu.message(2) { s in s.message(2) { a in a.int64(2, 1_800_003_000) }; s.string(4, "A65S") }
            }
        }
        let fetcher = FakeFetcher(responses: [MTAFeed.ace.url.absoluteString: .success(Data(feed.bytes))])
        let load = await MTARealtimeLoader(catalog: cat, fetcher: fetcher).load(stationIDs: ["A27"])
        let a = try XCTUnwrap(load.arrivals.first)
        XCTAssertEqual(a.direction.terminal, "Ozone Park-Lefferts Blvd")
        XCTAssertEqual(a.direction.name, "To Ozone Park-Lefferts Blvd")
    }

    func testAllFailed() async {
        let loader = MTARealtimeLoader(catalog: catalog(), fetcher: FakeFetcher(responses: [:]))
        let load = await loader.load(stationIDs: ["L03"])
        XCTAssertTrue(load.allFailed)
        XCTAssertTrue(load.arrivals.isEmpty)
    }

    func testGarbageDataIsReportedAsFailure() async {
        let fetcher = FakeFetcher(responses: [MTAFeed.l.url.absoluteString: .success(Data([0x0A, 0xFF, 0x01]))])
        let loader = MTARealtimeLoader(catalog: catalog(), fetcher: fetcher)
        let load = await loader.load(stationIDs: ["L03"])
        XCTAssertTrue(load.allFailed)
    }

    func testRealtimeArrivalsFlowIntoBoard() async throws {
        let ts: Int64 = 1_800_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(ts))
        let fetcher = FakeFetcher(responses: [MTAFeed.l.url.absoluteString: .success(feedData(stop: "L03N", route: "L", ts: ts))])
        let cat = catalog()
        let load = await MTARealtimeLoader(catalog: cat, fetcher: fetcher).load(stationIDs: ["L03"])
        let station = try XCTUnwrap(cat.station(id: "L03"))
        let walk = WalkEstimator.estimate(from: Coordinate(latitude: 40.7359, longitude: -73.9906), to: station, settings: .default)
        let board = NearbyBoardBuilder.build(stations: [station], walks: ["L03": walk], arrivals: load.arrivals,
                                             settings: .default, now: now)
        let train = try XCTUnwrap(board.stations.first?.north.trains.first)
        XCTAssertEqual(train.route, "L")
        XCTAssertEqual(train.verdict, .canTry) // arrives in 10 minutes; about 2 minutes walk + 1.5 minutes to get in
        XCTAssertFalse(train.evaluation.notes.contains(.mockData))
        XCTAssertTrue(train.evaluation.notes.contains(.walkEstimated))
    }

    /// Whether a train ends here is decided per trip: some 5 trains end at Bowling Green and others go on into Brooklyn,
    /// some 4 trains go on past Crown Hts-Utica Av, and a train taken out of service early ends where no timetable trip does.
    /// A train on its last leg lists only its terminal, and still ends there
    func testTerminalIsDecidedPerTrip() async throws {
        let cat = try StationCatalog.loadBundled()
        XCTAssertTrue(cat.terminates(stationID: "420", route: "5", code: "S"), "The usual southbound 5 ends at Bowling Green")
        XCTAssertTrue(cat.terminates(stationID: "250", route: "4", code: "S"), "The usual southbound 4 ends at Crown Hts-Utica Av")
        var feed = PB()
        feed.message(1) { h in h.int(3, 1_800_000_000) }
        let trips = [("ends", "5", ["418S", "420S"]), ("continues", "5", ["420S", "423S"]), ("short", "5", ["640S", "418S"]),
                     ("newLots", "4", ["250S", "251S"]), ("lastLeg", "5", ["418S"]), ("bowling", "5", ["420S"])]
        for (n, (trip, route, stops)) in trips.enumerated() {
            feed.message(2) { e in
                e.string(1, "\(n)")
                e.message(3) { tu in
                    tu.message(1) { t in t.string(1, trip); t.string(5, route) }
                    for (k, stop) in stops.enumerated() {
                        tu.message(2) { s in s.message(2) { a in a.int64(2, 1_800_000_300 + Int64(k) * 120) }; s.string(4, stop) }
                    }
                }
            }
        }
        let fetcher = FakeFetcher(responses: [MTAFeed.numbered.url.absoluteString: .success(Data(feed.bytes))])
        let load = await MTARealtimeLoader(catalog: cat, fetcher: fetcher).load(stationIDs: ["418", "420", "640", "250"])
        XCTAssertEqual(Set(load.arrivals.map(\.id)), ["ends|418S", "continues|420S", "short|640S", "newLots|250S"])
    }

    /// Many changes in a row: the state saved last is the newest one
    func testRateLimitSavesKeepOrder() {
        final class Saved: @unchecked Sendable {
            let lock = NSLock()
            var last: [String: RateLimit.Entry]?
        }
        let saved = Saved()
        let host = "order.example.com"
        RateLimit.restore([:]) { entries in saved.lock.withLock { saved.last = entries } }
        defer { RateLimit.restore([:]) { _ in } }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for k in 0..<50 {
            RateLimit.hit(host: host, retryAfter: 60 + Double(k), now: t0.addingTimeInterval(Double(k)))
        }
        RateLimit.waitForSaves()
        let until = saved.lock.withLock { saved.last?[host]?.until }
        XCTAssertEqual(until, RateLimit.pausedUntil(host: host, now: t0))
        RateLimit.cleared(host: host)
        RateLimit.waitForSaves()
        XCTAssertNil(saved.lock.withLock { saved.last?[host] })
    }

    /// Too many requests (429): pause 1, 2, 4... minutes, Retry-After takes precedence; simultaneous requests count once; cleared after success
    func testRateLimitPausesAndClears() {
        let host = "test-ratelimit.example"
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        RateLimit.cleared(host: host)
        RateLimit.hit(host: host, now: t0)
        RateLimit.hit(host: host, now: t0.addingTimeInterval(1)) // another request in the same refresh
        XCTAssertEqual(RateLimit.pausedUntil(host: host, now: t0), t0.addingTimeInterval(60))
        XCTAssertNil(RateLimit.pausedUntil(host: host, now: t0.addingTimeInterval(61)))
        RateLimit.hit(host: host, now: t0.addingTimeInterval(61))
        XCTAssertEqual(RateLimit.pausedUntil(host: host, now: t0.addingTimeInterval(61)), t0.addingTimeInterval(61 + 120))
        RateLimit.hit(host: host, retryAfter: 600, now: t0.addingTimeInterval(62))
        XCTAssertEqual(RateLimit.pausedUntil(host: host, now: t0.addingTimeInterval(62)), t0.addingTimeInterval(662))
        XCTAssertTrue(RateLimit.notices(now: t0.addingTimeInterval(62)).contains { $0.provider == host })
        RateLimit.cleared(host: host)
        XCTAssertNil(RateLimit.pausedUntil(host: host, now: t0.addingTimeInterval(62)))
        XCTAssertEqual(RateLimit.provider(forHost: "bustime.mta.info"), "MTA Bus Time")
        XCTAssertEqual(RateLimit.provider(forHost: "raildata.njtransit.com"), "NJ Transit rail")
        XCTAssertEqual(RateLimit.provider(forHost: "pcsdata.njtransit.com"), "NJ Transit bus")
    }
}
