import XCTest
@testable import TransitCore

/// Catch recommendations (which trips you can catch, and which to recommend when you can't): checked through `NearbyBoardBuilder`, used by both the main app and the widget.
final class RecommenderTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// These range tests use fixed 8 / 12 minute and 800 m ranges that don't follow the defaults.
    let settings = CatchSettings(primaryWalkMinutes: 8, extendedWalkMinutes: 12, candidateRadiusMeters: 800)
    let up = Direction(code: "N", name: "Uptown")

    func station(_ id: String, entry: TimeInterval = 0) -> Station {
        Station(id: id, name: id, coordinate: Coordinate(latitude: 0, longitude: 0), entranceToPlatformSeconds: entry)
    }

    func walk(minutes: Double, meters: Double = 300) -> WalkEstimate {
        WalkEstimate(walkSeconds: minutes * 60, straightLineMeters: meters, source: .route)
    }

    func arr(_ station: String, _ route: String = "L", min: Double?, k: Int = 0, status: TripStatus = .normal) -> Arrival {
        Arrival(id: "\(station)-\(route)-\(k)", stationID: station, route: route, direction: up,
                arrivalTime: min.map { now.addingTimeInterval($0 * 60) },
                source: .realtime, status: status, updatedAt: now)
    }

    func board(_ stations: [Station], _ walks: [String: WalkEstimate], _ arrivals: [Arrival]) -> NearbyBoard {
        NearbyBoardBuilder.build(stations: stations, walks: walks, arrivals: arrivals, settings: settings, now: now, clockOffset: 0)
    }

    func testEarliestTrainIsNotAutomaticallyFirst() throws {
        // A: train in 2 minutes, but a 5-minute walk → can't catch. B: train in 6 minutes, 2-minute walk → can catch.
        let b = board([station("A"), station("B")], ["A": walk(minutes: 5), "B": walk(minutes: 2)],
                      [arr("A", min: 2), arr("A", min: 12, k: 1), arr("B", min: 6)])
        XCTAssertEqual(b.stations.map(\.id), ["B", "A"], "stations sorted by walk time")
        let nearB = try XCTUnwrap(b.station(id: "B")).north
        XCTAssertEqual(nearB.trains.first?.verdict, .canTry)
        XCTAssertEqual(nearB.firstCatchable?.id, "B-L-0")
        let a = try XCTUnwrap(b.station(id: "A")).north
        XCTAssertEqual(a.trains.map(\.id), ["A-L-0", "A-L-1"])
        XCTAssertEqual(a.trains.first?.verdict, .takeNext)
        XCTAssertEqual(a.trains.first?.recommended?.arrival.id, "A-L-1", "should recommend the next feasible train")
        XCTAssertEqual(a.firstCatchable?.id, "A-L-1", "the earliest train can't be caught, so it doesn't count as catchable")
    }

    /// "Next one you can catch" names the same train as the first-catchable mark: a tight one counts, not only "can try"
    func testNextCatchableCountsTightOnes() throws {
        let b = board([station("A")], ["A": walk(minutes: 5)],
                      [arr("A", min: 2), arr("A", min: 5.5, k: 1), arr("A", min: 15, k: 2)])
        let a = try XCTUnwrap(b.station(id: "A")).north
        XCTAssertEqual(a.trains.map(\.verdict), [.takeNext, .tight, .canTry])
        XCTAssertEqual(a.trains.first?.recommended?.arrival.id, "A-L-1", "the tight one comes first")
        XCTAssertEqual(a.firstCatchable?.id, a.trains.first?.recommended?.arrival.id, "same train as the mark")
        // Only too soon ones: nothing to recommend
        let none = board([station("A")], ["A": walk(minutes: 5)], [arr("A", min: 2), arr("A", min: 3, k: 1)])
        XCTAssertNil(try XCTUnwrap(none.station(id: "A")).north.trains.first?.recommended)
    }

    func testCancelledAndDepartedAreExcluded() {
        let b = board([station("A")], ["A": walk(minutes: 2)],
                      [arr("A", min: -1), arr("A", min: 6, k: 1, status: .cancelled), arr("A", min: 9, k: 2)])
        XCTAssertEqual(b.cancelledCount, 1)
        XCTAssertEqual(b.stations.first?.north.trains.map(\.id), ["A-L-2"])
    }

    func testOutOfRangeStationIgnored() {
        let b = board([station("FAR")], ["FAR": walk(minutes: 12.5, meters: 850)], [arr("FAR", min: 30)])
        XCTAssertTrue(b.stations.isEmpty)
    }

    /// Plan a Trip's own walk: it is the farthest walk (the extended range), the primary range is cut to it, and the choices add
    /// the extended range from Settings
    func testPlannerWalk() {
        let d = CatchSettings.default
        XCTAssertEqual(d.plannerWalkChoices(), [10, 15, 20, 30, 45])
        var mine = d
        mine.extendedWalkMinutes = 25
        XCTAssertEqual(mine.plannerWalkChoices(), [10, 15, 20, 25, 30, 45])
        XCTAssertEqual(d.walking(upTo: nil), d.sanitized())
        let far = d.walking(upTo: 30)
        XCTAssertEqual(far.primaryWalkMinutes, 15)
        XCTAssertEqual(far.extendedWalkMinutes, 30)
        XCTAssertEqual(far.extendedCandidateRadiusMeters, 2250, accuracy: 0.001, "30 min × 75 m a minute")
        XCTAssertEqual(far.sanitized(), far)
        let near = d.walking(upTo: 10)
        XCTAssertEqual(near.primaryWalkMinutes, 10)
        XCTAssertEqual(near.extendedWalkMinutes, 10)
        // Never past what Settings allow; a value that isn't a number keeps Settings
        XCTAssertEqual(d.walking(upTo: 90).extendedWalkMinutes, CatchSettings.extendedWalkMax)
        XCTAssertEqual(d.walking(upTo: .nan), d.sanitized())
        // A station 25 minutes away on foot: out of the range from Settings, in the extended range with a 30-minute walk
        let walk25 = WalkEstimate(walkSeconds: 25 * 60, straightLineMeters: 1500, source: .route)
        XCTAssertNil(Recommender.classify(walk: walk25, settings: d.sanitized()))
        XCTAssertEqual(Recommender.classify(walk: walk25, settings: far), .extended)
        XCTAssertNil(Recommender.classify(walk: WalkEstimate(walkSeconds: 11 * 60, straightLineMeters: 600, source: .route), settings: near))
    }

    func testRangeClassificationBoundaries() {
        XCTAssertEqual(Recommender.classify(walk: walk(minutes: 8, meters: 800), settings: settings), .primary)
        XCTAssertEqual(Recommender.classify(walk: walk(minutes: 8.01, meters: 500), settings: settings), .extended)
        XCTAssertEqual(Recommender.classify(walk: walk(minutes: 7, meters: 801), settings: settings), .extended, "beyond the 800 m prefilter radius, it's not in the primary range")
        XCTAssertEqual(Recommender.classify(walk: walk(minutes: 12, meters: 900), settings: settings), .extended)
        XCTAssertNil(Recommender.classify(walk: walk(minutes: 12.01, meters: 500), settings: settings))
        XCTAssertNil(Recommender.classify(walk: walk(minutes: 10, meters: 901), settings: settings))
    }

    // The walking-range circles on the map: the radius is where an estimated walk (no route) reaches the range's walk time,
    // so a station just inside a circle is in that range and one just outside isn't, the same as in the station list
    func testRangeCircleRadius() {
        let d = CatchSettings.default
        XCTAssertEqual(d.primaryRangeRadiusMeters, 900, accuracy: 0.001, "15 minutes at 4.5 km/h, detour factor 1.25")
        XCTAssertEqual(d.extendedRangeRadiusMeters, 1200, accuracy: 0.001, "20 minutes")
        let origin = Coordinate(latitude: 40.7557, longitude: -73.9871)
        // Due north of the origin: one degree of latitude is 111,194.93 m on WalkEstimator's sphere (radius 6,371 km)
        func range(_ meters: Double, _ s: CatchSettings) -> SearchRange? {
            let place = Coordinate(latitude: origin.latitude + meters / 111_194.93, longitude: origin.longitude)
            let walk = WalkEstimator.estimate(from: origin, to: Station(id: "S", name: "S", coordinate: place), settings: s)
            return Recommender.classify(walk: walk, settings: s)
        }
        XCTAssertEqual(range(d.primaryRangeRadiusMeters - 1, d), .primary)
        XCTAssertEqual(range(d.primaryRangeRadiusMeters + 1, d), .extended)
        XCTAssertEqual(range(d.extendedRangeRadiusMeters - 1, d), .extended)
        XCTAssertNil(range(d.extendedRangeRadiusMeters + 1, d))
        // A smaller search radius limits the primary circle, as it limits the station list
        let small = CatchSettings(candidateRadiusMeters: 600)
        XCTAssertEqual(small.primaryRangeRadiusMeters, 600, accuracy: 0.001)
        XCTAssertEqual(range(599, small), .primary)
        XCTAssertEqual(range(601, small), .extended)
        // Walking speed and detour factor change it as they change walk times: 3.6 km/h is 1 m/s, so 15 minutes ÷ 1.5 is 600 m
        XCTAssertEqual(CatchSettings(walkingSpeedKmh: 3.6, detourFactor: 1.5).primaryRangeRadiusMeters, 600, accuracy: 0.001)
        // Extending the range for now adds minutes to the extended range (TransitModel.effectiveSettings): the dashed circle grows, the solid one stays
        var extended = d
        extended.extendedWalkMinutes += 10
        XCTAssertEqual(extended.extendedRangeRadiusMeters, 1800, accuracy: 0.001)
        XCTAssertEqual(extended.primaryRangeRadiusMeters, d.primaryRangeRadiusMeters, accuracy: 0.001)
        XCTAssertEqual(range(1799, extended), .extended)
        XCTAssertNil(range(1801, extended))
    }

    func testExtendedStationsAreListedAfterPrimary() {
        // Y is only a 2-minute walk, but 850 m in a straight line exceeds the primary range's 800 m prefilter radius, so it's in the extended range.
        let b = board([station("P"), station("X"), station("Y")],
                      ["P": walk(minutes: 3), "X": walk(minutes: 10, meters: 850), "Y": walk(minutes: 2, meters: 850)],
                      [arr("P", min: 25), arr("X", min: 14), arr("Y", min: 14)])
        XCTAssertTrue(b.usedExtendedRange)
        XCTAssertEqual(b.stations.map(\.id), ["P", "Y", "X"], "extended range after primary, sorted by walk time within a range")
        XCTAssertEqual(b.stations.map(\.range), [.primary, .extended, .extended])
    }

    func testMissingPredictionIsInsufficientInfo() throws {
        let b = board([station("A")], ["A": walk(minutes: 2)], [arr("A", min: nil)])
        let north = try XCTUnwrap(b.stations.first).north
        let train = try XCTUnwrap(north.trains.first)
        XCTAssertEqual(train.verdict, .insufficientInfo)
        XCTAssertTrue(train.evaluation.notes.contains(.missingPrediction))
        XCTAssertNil(train.recommended)
        XCTAssertNil(north.firstCatchable, "no catchable trains")
    }

    func testSnapshotRoundTripAndTimeProgression() throws {
        let snap = TransitSnapshot(
            createdAt: now, placeName: "Test",
            stations: [station("A")], walks: ["A": walk(minutes: 2)],
            arrivals: [arr("A", min: 6), arr("A", min: 12, k: 1)],
            settings: settings)
        let decoded = try TransitSnapshot.decode(try snap.encoded())
        XCTAssertEqual(decoded, snap)
        // The first train the widget sees after `seconds` seconds
        func first(_ s: TransitSnapshot, after seconds: TimeInterval) -> BoardTrain? {
            s.board(at: now.addingTimeInterval(seconds)).stations.first?.north.trains.first
        }

        // Now: train in 6 minutes, 2-minute walk → can try.
        XCTAssertEqual(first(decoded, after: 0)?.verdict, .canTry)
        // 3 minutes later: 3 minutes left, 2-minute walk, 60 seconds of slack → tight.
        XCTAssertEqual(first(decoded, after: 180)?.verdict, .tight)
        // 4.5 minutes later: realtime data hasn't updated for over 3 minutes → honestly show "not enough info".
        let stale = first(decoded, after: 270)
        XCTAssertEqual(stale?.verdict, .insufficientInfo)
        XCTAssertTrue(stale?.evaluation.notes.contains(.staleRealtime) ?? false)

        // If the staleness threshold is relaxed to 10 minutes: can't catch it, recommend the 12-minute one.
        var relaxed = decoded
        relaxed.settings.realtimeStaleAfterSeconds = 600
        let later = first(relaxed, after: 270)
        XCTAssertEqual(later?.verdict, .takeNext)
        XCTAssertEqual(later?.recommended?.arrival.id, "A-L-1")
    }

    /// Rounded walks can tie; the saved order keeps the widget's stations and nearest entrances in the main app's order
    func testSharedWalksKeepTheAppsOrder() throws {
        func walk(_ seconds: TimeInterval) -> WalkEstimate {
            WalkEstimate(walkSeconds: seconds, straightLineMeters: 300, source: .route)
        }
        let stations = [station("A1"), station("Z1"),
                        Station(id: "B2", name: "B", coordinate: Coordinate(latitude: 0, longitude: 0), complexID: "9"),
                        Station(id: "B1", name: "B", coordinate: Coordinate(latitude: 0, longitude: 0), complexID: "9")]
        let exact = ["Z1": walk(301), "A1": walk(320), "B2": walk(335), "B1": walk(355)]
        let app = board(stations, exact, [])
        XCTAssertEqual(app.stations.map(\.id), ["Z1", "A1", "c9"])
        XCTAssertEqual(app.stations.last?.stations.map(\.id), ["B2", "B1"])

        let shared = TransitSnapshot.sharedWalks(exact, settings: settings)
        XCTAssertEqual(shared["Z1"]?.walkSeconds, shared["A1"]?.walkSeconds)
        XCTAssertEqual(shared["B2"]?.walkSeconds, shared["B1"]?.walkSeconds)
        var snap = TransitSnapshot(createdAt: now, placeName: "", stations: stations, walks: shared, arrivals: [], settings: settings)
        snap.walkOrder = TransitSnapshot.walkOrder(exact)
        let widget = snap.board(at: now)
        XCTAssertEqual(widget.stations.map(\.id), app.stations.map(\.id))
        XCTAssertEqual(widget.stations.last?.stations.map(\.id), ["B2", "B1"])
        XCTAssertEqual(try TransitSnapshot.decode(snap.encoded()).walkOrder, snap.walkOrder)

        // Older snapshots without the order still work (ties fall back to IDs)
        snap.walkOrder = nil
        XCTAssertEqual(snap.board(at: now).stations.map(\.id), ["A1", "Z1", "c9"])
        XCTAssertNil(try TransitSnapshot.decode(snap.encoded()).walkOrder)
    }
}

final class WalkEstimatorTests: XCTestCase {

    /// Walking routes: answered stations aren't asked again, failed ones are after 5 minutes or when the network is back,
    /// and moving 30 m, another mode or a stopped request asks again
    func testWalkRouteBookAsksAgainAfterFailures() {
        let here = Coordinate(latitude: 40.75, longitude: -73.99)
        // Stations 100, 200, 300 m north
        let stations = (1...3).map { i in
            Station(id: "S\(i)", name: "S\(i)", coordinate: Coordinate(latitude: 40.75 + Double(i) * 100 / 111_195, longitude: -73.99))
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var book = WalkRouteBook()
        var ask = book.next(from: here, stations: stations, limit: 2, now: t0)
        XCTAssertTrue(ask.startedOver)
        XCTAssertEqual(ask.targets.map(\.id), ["S1", "S2"], "Nearest first, at most the limit")
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 2, now: t0).targets.map(\.id), ["S3"], "Being asked: not again")
        // S1 has a route, S2 failed
        XCTAssertTrue(book.received(["S1": 140], for: Array(stations[0...1]), from: here, now: t0))
        XCTAssertEqual(book.meters, ["S1": 140])
        XCTAssertTrue(book.next(from: here, stations: stations, limit: 2, now: t0.addingTimeInterval(299)).targets.isEmpty)
        ask = book.next(from: here, stations: stations, limit: 2, now: t0.addingTimeInterval(300))
        XCTAssertFalse(ask.startedOver)
        XCTAssertEqual(ask.targets.map(\.id), ["S2"], "Failed: asked again after 5 minutes; answered: never")
        // A stopped request (standby): what's being asked is asked again, routes found are kept
        book.stopped()
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 5, now: t0).targets.map(\.id), ["S2", "S3"])
        XCTAssertEqual(book.meters, ["S1": 140])
        // Network back: failed ones at once, ones being asked not twice
        book.received([:], for: [stations[1]], from: here, now: t0)
        book.retryFailed()
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 5, now: t0).targets.map(\.id), ["S2"])
        // Asked from a few meters away (under resetDistance): the answer counts, so a failure there is retried too
        let near = Coordinate(latitude: 40.75 + 5 / 111_195, longitude: -73.99)
        XCTAssertFalse(book.next(from: near, stations: stations, limit: 5, now: t0).startedOver, "Moved about 5 m")
        XCTAssertTrue(book.received([:], for: [stations[1]], from: near, now: t0))
        XCTAssertEqual(book.next(from: near, stations: stations, limit: 5, now: t0.addingTimeInterval(300)).targets.map(\.id), ["S2"])
        // An answer for an earlier origin changes nothing
        let moved = Coordinate(latitude: 40.75, longitude: -73.99 + 40 / 84_400)
        ask = book.next(from: moved, stations: stations, limit: 5, now: t0)
        XCTAssertTrue(ask.startedOver, "Moved about 40 m")
        XCTAssertTrue(book.meters.isEmpty)
        XCTAssertEqual(ask.targets.count, 3)
        XCTAssertFalse(book.received(["S3": 300], for: [stations[2]], from: here, now: t0))
        XCTAssertTrue(book.meters.isEmpty)
        // Another mode: starts over at the same place
        book.reset()
        XCTAssertNil(book.origin)
        XCTAssertTrue(book.next(from: moved, stations: stations, limit: 5, now: t0).startedOver)
    }

    /// Route lengths count only from the place they were found from: after a move of 30 m or more, walks are estimated
    /// until `next` starts over, even though the book still holds the old routes
    func testRouteMetersBelongToTheirOrigin() {
        let here = Coordinate(latitude: 40.75, longitude: -73.99)
        let stations = (1...2).map { i in
            Station(id: "S\(i)", name: "S\(i)", coordinate: Coordinate(latitude: 40.75 + Double(i) * 100 / 111_195, longitude: -73.99))
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var book = WalkRouteBook()
        XCTAssertTrue(book.routeMeters(from: here).isEmpty, "No origin yet")
        _ = book.next(from: here, stations: stations, limit: 2, now: t0)
        XCTAssertTrue(book.received(["S1": 140], for: stations, from: here, now: t0))
        XCTAssertEqual(book.routeMeters(from: here), ["S1": 140])
        let near = Coordinate(latitude: 40.75 + 5 / 111_195, longitude: -73.99)
        XCTAssertEqual(book.routeMeters(from: near), ["S1": 140], "Moved about 5 m")
        let moved = Coordinate(latitude: 40.75, longitude: -73.99 + 40 / 84_400)
        XCTAssertEqual(book.routeMeters(from: moved), [:], "Moved about 40 m")
        XCTAssertEqual(book.meters, ["S1": 140], "Kept until next starts over")
        book.reset()
        XCTAssertEqual(book.routeMeters(from: here), [:])
    }

    func testDistanceOfOneDegreeLatitude() {
        let d = WalkEstimator.distanceMeters(Coordinate(latitude: 40, longitude: -74), Coordinate(latitude: 41, longitude: -74))
        XCTAssertEqual(d, 111_195, accuracy: 200)
    }

    func testEstimatedWalkUsesDetourAndSpeed() {
        let s = CatchSettings.default
        // About 375 m: 375 × 1.25 ÷ 1.25 m/s = 375 seconds
        let user = Coordinate(latitude: 40.0, longitude: -74.0)
        let st = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 40.0 + 375.0 / 111_195.0, longitude: -74.0))
        let w = WalkEstimator.estimate(from: user, to: st, settings: s)
        XCTAssertEqual(w.source, .estimated)
        XCTAssertEqual(w.straightLineMeters, 375, accuracy: 1)
        XCTAssertEqual(w.walkSeconds, 375, accuracy: 2)
    }

    func testRouteTimeIsPreferred() {
        let user = Coordinate(latitude: 40.0, longitude: -74.0)
        let st = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 40.001, longitude: -74.0))
        let w = WalkEstimator.estimate(from: user, to: st, settings: .default, routeSeconds: 200)
        XCTAssertEqual(w.source, .route)
        XCTAssertEqual(w.walkSeconds, 200)
    }

    func testNearestEntranceIsUsed() {
        let user = Coordinate(latitude: 40.0, longitude: -74.0)
        let st = Station(id: "S", name: "S",
                         coordinate: Coordinate(latitude: 40.005, longitude: -74.0),
                         entrances: [
                            StationEntrance(name: "far", coordinate: Coordinate(latitude: 40.006, longitude: -74.0)),
                            StationEntrance(name: "near", coordinate: Coordinate(latitude: 40.002, longitude: -74.0)),
                         ])
        let w = WalkEstimator.estimate(from: user, to: st, settings: .default)
        XCTAssertEqual(w.entranceName, "near")
    }

    func testSettingsSanitize() {
        var s = CatchSettings.default
        s.walkingSpeedKmh = 0
        s.extendedWalkMinutes = 3
        s.safetyBufferMinutes = -5
        s.realtimeStaleAfterSeconds = 3600
        let c = s.sanitized()
        XCTAssertEqual(c.walkingSpeedKmh, 2)
        XCTAssertEqual(c.extendedWalkMinutes, c.primaryWalkMinutes)
        var big = CatchSettings.default
        big.primaryWalkMinutes = 500
        big.extendedWalkMinutes = 500
        big.candidateRadiusMeters = 99_999
        big.safetyBufferMinutes = 99
        big.walkingSpeedKmh = 50
        let b = big.sanitized()
        XCTAssertEqual(b.primaryWalkMinutes, 30)
        XCTAssertEqual(b.extendedWalkMinutes, 45)
        XCTAssertEqual(b.candidateRadiusMeters, 3000)
        XCTAssertEqual(b.safetyBufferMinutes, 10)
        XCTAssertEqual(b.walkingSpeedKmh, 7)
        var tiny = CatchSettings.default
        tiny.primaryWalkMinutes = 0
        tiny.candidateRadiusMeters = 5
        XCTAssertEqual(tiny.sanitized().primaryWalkMinutes, 3)
        XCTAssertEqual(tiny.sanitized().candidateRadiusMeters, 300)
        XCTAssertEqual(c.safetyBufferMinutes, 0)
        XCTAssertEqual(c.realtimeStaleAfterSeconds, 600, "an hour-old prediction can't count as fresh; at most 10 minutes")
    }

    // A value that isn't a finite number becomes that setting's default, instead of passing through (NaN) or crashing the ranges built from it
    func testNonFiniteSettingsBecomeDefaults() {
        let d = CatchSettings.default
        for bad in [Double.nan, .infinity, -.infinity] {
            let s = CatchSettings(primaryWalkMinutes: bad, extendedWalkMinutes: bad, candidateRadiusMeters: bad, safetyBufferMinutes: bad,
                                  walkingSpeedKmh: bad, detourFactor: bad, realtimeStaleAfterSeconds: bad, arrivalWindowMinutes: bad).sanitized()
            XCTAssertEqual(s.primaryWalkMinutes, d.primaryWalkMinutes, "\(bad)")
            XCTAssertEqual(s.extendedWalkMinutes, d.extendedWalkMinutes, "\(bad)")
            XCTAssertEqual(s.candidateRadiusMeters, d.candidateRadiusMeters, "\(bad)")
            XCTAssertEqual(s.safetyBufferMinutes, d.safetyBufferMinutes, "\(bad)")
            XCTAssertEqual(s.walkingSpeedKmh, d.walkingSpeedKmh, "\(bad)")
            XCTAssertEqual(s.detourFactor, d.detourFactor, "\(bad)")
            XCTAssertEqual(s.realtimeStaleAfterSeconds, d.realtimeStaleAfterSeconds, "\(bad)")
            XCTAssertEqual(s.arrivalWindowSeconds, d.arrivalWindowSeconds, "\(bad)")
        }
        // Only the broken one changes
        var one = CatchSettings.default
        one.primaryWalkMinutes = 10
        one.extendedWalkMinutes = .nan
        let fixed = one.sanitized()
        XCTAssertEqual(fixed.primaryWalkMinutes, 10)
        XCTAssertEqual(fixed.extendedWalkMinutes, d.extendedWalkMinutes)
    }

    func testDefaultsMatchProductSpec() {
        // The default ranges were raised to 15 / 20 minutes and 1200 m; buffer and speed unchanged.
        let s = CatchSettings.default
        XCTAssertEqual(s.primaryWalkMinutes, 15)
        XCTAssertEqual(s.extendedWalkMinutes, 20)
        XCTAssertEqual(s.candidateRadiusMeters, 1219.2, accuracy: 0.001, "4,000 ft (2026-10-16)")
        XCTAssertEqual(s.safetyBufferMinutes, 2)
        XCTAssertEqual(s.walkingSpeedKmh, 4.5)
        XCTAssertEqual(s.extendedCandidateRadiusMeters, 1500, accuracy: 0.001)
    }

    func testLegacyRangeDefaultsAreUpgraded() {
        var old = CatchSettings(primaryWalkMinutes: 8, extendedWalkMinutes: 12, candidateRadiusMeters: 800)
        old.safetyBufferMinutes = 3
        let upgraded = old.upgradingLegacyRangeDefaults()
        XCTAssertEqual(upgraded.primaryWalkMinutes, 15)
        XCTAssertEqual(upgraded.extendedWalkMinutes, 20)
        XCTAssertEqual(upgraded.candidateRadiusMeters, 1219.2, accuracy: 0.001)
        XCTAssertEqual(upgraded.safetyBufferMinutes, 3, "other settings stay the same")

        let custom = CatchSettings(primaryWalkMinutes: 10, extendedWalkMinutes: 12, candidateRadiusMeters: 800)
        XCTAssertEqual(custom.upgradingLegacyRangeDefaults(), custom, "ranges the user changed are left alone")
    }

    func testPreviousRadiusDefaultIsUpgradedTo4000Feet() {
        let old = CatchSettings(candidateRadiusMeters: 1200)
        XCTAssertEqual(old.upgradingPreviousRadiusDefault().candidateRadiusMeters, 1219.2, accuracy: 0.001)
        let custom = CatchSettings(candidateRadiusMeters: 1500)
        XCTAssertEqual(custom.upgradingPreviousRadiusDefault(), custom, "a radius the user changed is left alone")
    }

    func testRouteMetersUseWalkingSpeed() {
        let user = Coordinate(latitude: 40.0, longitude: -74.0)
        let st = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 40.008, longitude: -74.0))
        let w = WalkEstimator.estimate(from: user, to: st, settings: .default, routeMeters: 1050)
        XCTAssertEqual(w.source, .route)
        XCTAssertEqual(w.routeMeters, 1050)
        XCTAssertEqual(w.walkSeconds, 840, accuracy: 0.001, "1050 m ÷ 1.25 m/s = 840 seconds")
    }

    /// A route far too long for a station a few steps away isn't used (Secaucus Junction: 2 m away, a 4,995 m route came back):
    /// the walk is the straight-line estimate, marked estimated. Only under 50 m away with a route over 1,000 m
    func testRouteFarTooLongForAStationAFewStepsAwayIsNotUsed() {
        let user = Coordinate(latitude: 40.0, longitude: -74.0)
        func walk(_ straight: Double, route: Double, seconds: TimeInterval? = nil) -> WalkEstimate {
            let station = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 40.0 + straight / 111_195.0, longitude: -74.0))
            return WalkEstimator.estimate(from: user, to: station, settings: .default, routeSeconds: seconds, routeMeters: route)
        }
        let secaucus = walk(2, route: 4995)
        XCTAssertEqual(secaucus.source, .estimated)
        XCTAssertNil(secaucus.routeMeters)
        XCTAssertEqual(secaucus.straightLineMeters, 2, accuracy: 0.1)
        XCTAssertEqual(secaucus.walkSeconds, 2, accuracy: 0.1, "2 m × 1.25 ÷ 1.25 m/s")
        XCTAssertFalse(secaucus.isAcrossWater)
        // A route time that came with it isn't used either
        XCTAssertEqual(walk(2, route: 4995, seconds: 4000).source, .estimated)
        XCTAssertEqual(walk(49, route: 1001).source, .estimated)
        // 50 m away with 999 m by route: used. So is any route up to 1,000 m, however near
        let short = walk(50, route: 999)
        XCTAssertEqual(short.source, .route)
        XCTAssertEqual(short.routeMeters, 999)
        XCTAssertEqual(walk(2, route: 1000).source, .route)
        XCTAssertEqual(walk(2, route: 40).source, .route)
        // 51 m away with 5,000 m by route: used. From 50 m away a long way around is believable
        let around = walk(51, route: 5000)
        XCTAssertEqual(around.source, .route)
        XCTAssertEqual(around.walkSeconds, 4000, accuracy: 0.001, "5000 m ÷ 1.25 m/s")
        // The rule at its edges; a line across water keeps its route
        XCTAssertTrue(WalkEstimator.routeNotUsed(straightMeters: 49.9, routeMeters: 1000.1, acrossWater: false))
        XCTAssertFalse(WalkEstimator.routeNotUsed(straightMeters: 50, routeMeters: 5000, acrossWater: false))
        XCTAssertFalse(WalkEstimator.routeNotUsed(straightMeters: 2, routeMeters: 1000, acrossWater: false))
        XCTAssertFalse(WalkEstimator.routeNotUsed(straightMeters: 2, routeMeters: 4995, acrossWater: true))
        // No route yet: the estimate, as before
        let station = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 40.0 + 2 / 111_195.0, longitude: -74.0))
        XCTAssertEqual(WalkEstimator.estimate(from: user, to: station, settings: .default).source, .estimated)
    }

    func testMockDataProducesLabelledResults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let place = MockTransitData.previewPlace
        var walks: [String: WalkEstimate] = [:]
        for s in MockTransitData.stations {
            walks[s.id] = WalkEstimator.estimate(from: place.coordinate, to: s, settings: .default)
        }
        let board = NearbyBoardBuilder.build(stations: MockTransitData.stations, walks: walks,
                                             arrivals: MockTransitData.arrivals(now: now), settings: .default, now: now)
        let trains = board.stations.flatMap { $0.north.trains + $0.south.trains }
        XCTAssertFalse(trains.isEmpty)
        XCTAssertTrue(trains.allSatisfy { $0.evaluation.notes.contains(.mockData) })
    }

    // The widget gallery preview's made-up data: real stations around Times Square, named and grouped as the station list has them

    func testThePreviewsStationsAreTheStationLists() throws {
        let catalog = try StationCatalog.loadBundled()
        for s in MockTransitData.stations {
            let e = try XCTUnwrap(catalog.entry(id: s.id), s.id)
            XCTAssertEqual(s.name, e.name, s.id)
            XCTAssertEqual(s.complexID, e.complex, s.id)
            XCTAssertEqual(s.coordinate.latitude, e.lat, accuracy: 0.000_001, s.id)
            XCTAssertEqual(s.coordinate.longitude, e.lon, accuracy: 0.000_001, s.id)
        }
    }

    /// Each trip's line stops at its station, and its direction is named as the app names it there
    func testThePreviewsTripsGoTheWayTheStationListSays() throws {
        let catalog = try StationCatalog.loadBundled()
        let ids = Set(MockTransitData.stations.map(\.id))
        for (station, route, direction, _, _) in MockTransitData.plan {
            XCTAssertTrue(ids.contains(station), station)
            XCTAssertTrue(catalog.routes(atStations: [station]).contains(route), "\(route) at \(station)")
            XCTAssertEqual(catalog.direction(stationID: station, route: route, code: direction.code), direction,
                           "\(route) \(direction.code) at \(station)")
        }
    }

    /// Times Sq-42 St comes first, every station shown has trains, and all of them say they're mock data
    func testThePreviewShowsTimesSquareFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let place = MockTransitData.previewPlace
        var walks: [String: WalkEstimate] = [:]
        for s in MockTransitData.stations {
            walks[s.id] = WalkEstimator.estimate(from: place.coordinate, to: s, settings: .default)
        }
        let board = NearbyBoardBuilder.build(stations: MockTransitData.stations, walks: walks,
                                             arrivals: MockTransitData.arrivals(now: now), settings: .default, now: now)
        XCTAssertEqual(board.stations.first?.id, "c611")
        XCTAssertTrue(board.stations.first?.name.hasPrefix("Times Sq-42 St") == true, board.stations.first?.name ?? "none")
        XCTAssertEqual(Set(board.stations.map(\.id)), ["c611", "c609", "c10", "c225", "c316"])
        for b in board.stations {
            XCTAssertFalse((b.north.trains + b.south.trains).isEmpty, b.name)
        }
        XCTAssertTrue(board.stations.flatMap { $0.north.trains + $0.south.trains }.allSatisfy { $0.evaluation.notes.contains(.mockData) })
    }

    /// Changing the preview doesn't change the app's place before one is chosen
    func testThePlaceBeforeOneIsChosenIsNotThePreviews() {
        XCTAssertEqual(UserPlace.default.name, "Union Square Park")
        XCTAssertNotEqual(MockTransitData.previewPlace.name, UserPlace.default.name)
    }

    /// Walking data for the shared snapshot is rounded (no exact distances), but every station keeps its range
    /// and the walking minutes shown stay the same
    func testSharedWalksAreCoarseButKeepRanges() {
        let s = CatchSettings(primaryWalkMinutes: 8, extendedWalkMinutes: 12, candidateRadiusMeters: 1219.2)
        var walks: [String: WalkEstimate] = [:]
        var k = 0
        for meters in stride(from: 0.0, through: 2000, by: 37.3) {
            for seconds in stride(from: 0.0, through: 900, by: 13.7) {
                walks["s\(k)"] = WalkEstimate(walkSeconds: seconds, straightLineMeters: meters, source: .route,
                                               entranceName: "Northeast corner", routeMeters: meters * 1.3)
                k += 1
            }
        }
        let shared = TransitSnapshot.sharedWalks(walks, settings: s)
        let limits = [s.candidateRadiusMeters, s.extendedCandidateRadiusMeters]
        for (id, exact) in walks {
            let c = shared[id]!
            XCTAssertNil(c.routeMeters)
            XCTAssertNil(c.entranceName)
            XCTAssertGreaterThanOrEqual(c.straightLineMeters, exact.straightLineMeters)
            XCTAssertGreaterThanOrEqual(c.walkSeconds, exact.walkSeconds)
            XCTAssertTrue(c.straightLineMeters.truncatingRemainder(dividingBy: 100) == 0 || limits.contains(c.straightLineMeters))
            XCTAssertEqual(Recommender.classify(walk: c, settings: s), Recommender.classify(walk: exact, settings: s), id)
            XCTAssertEqual((c.walkSeconds / 60).rounded(.up), (exact.walkSeconds / 60).rounded(.up), id)
        }
        XCTAssertEqual(shared.count, walks.count)
    }
}

/// The water areas (WaterMap): a straight line across a river or a bay counts as crossing water; a walk along the shore or out to a
/// pier on the same side doesn't. Places are public: stations, piers and street corners (longitude, latitude)
final class WaterMapTests: XCTestCase {
    func c(_ lon: Double, _ lat: Double) -> Coordinate { Coordinate(latitude: lat, longitude: lon) }

    func testTheBundledFileReads() throws {
        let water = try XCTUnwrap(WaterMap.shared, "water.bin is missing or damaged")
        // With Greater Hartford's and Western Massachusetts' counties (the Connecticut River, the Westfield River)
        XCTAssertEqual(water.shapeCount, 1733)
        XCTAssertEqual(water.pointCount, 236_041)
        XCTAssertNil(WaterMap(data: Data("CMTW".utf8)), "Too short")
        XCTAssertNil(WaterMap(data: Data([0x43, 0x4D, 0x54, 0x57, 0x02, 0x00])), "Another version")
    }

    func testCrossings() throws {
        let water = try XCTUnwrap(WaterMap.shared)
        let across: [(String, Coordinate, Coordinate)] = [
            ("Wall St to York St (Dumbo), the East River", c(-74.0080, 40.7040), c(-73.9866, 40.7014)),
            ("Hoboken to Christopher St, the Hudson", c(-74.0273, 40.7353), c(-74.0073, 40.7331)),
            ("Roosevelt Island to Lexington Av/63 St", c(-73.9517, 40.7590), c(-73.9660, 40.7646)),
            ("East 125 St to 3 Av-138 St, the Harlem River", c(-73.9375, 40.8040), c(-73.9260, 40.8104)),
            ("Greenpoint to Vernon Blvd, Newtown Creek", c(-73.9510, 40.7310), c(-73.9530, 40.7425)),
            ("Brooklyn to the East 34th Street ferry pier", c(-73.9570, 40.7270), c(-73.9711, 40.7434)),
            ("Exchange Place to the World Trade Center", c(-74.0330, 40.7163), c(-74.0110, 40.7116)),
            // The Lehigh Valley's western part and the upper Perkiomen Valley, added to the service area later
            ("Beltzville State Park, across the lake", c(-75.6300, 40.8700), c(-75.6250, 40.8450)),
            ("Green Lane, across the reservoir", c(-75.5100, 40.3500), c(-75.4800, 40.3450)),
            // Greater Boston
            ("Kendall/MIT to Charles/MGH, the Charles River", c(-71.0862, 42.3625), c(-71.0707, 42.3612)),
            ("Aquarium to Maverick, Boston Harbor", c(-71.0517, 42.3598), c(-71.0396, 42.3691)),
            ("Newport to Jamestown, Narragansett Bay", c(-71.3165, 41.4890), c(-71.3657, 41.4979)),
            // Greater Hartford and Western Massachusetts: the Connecticut River
            ("Downtown Hartford to East Hartford", c(-72.6731, 41.7665), c(-72.6510, 41.7615)),
            ("Union Station in Springfield to West Springfield", c(-72.5932, 42.1066), c(-72.6260, 42.1070)),
            ("Northampton to Hadley", c(-72.6290, 42.3250), c(-72.5900, 42.3420)),
        ]
        for (name, a, b) in across {
            XCTAssertTrue(water.crosses(a, b), name)
            XCTAssertTrue(water.crosses(b, a), name + ", the other way")
        }
        let notAcross: [(String, Coordinate, Coordinate)] = [
            ("South St to the Pier 11 ferry", c(-74.0070, 40.7045), c(-74.0055, 40.7032)),
            ("Wall St to Fulton St", c(-74.0090, 40.7068), c(-74.0076, 40.7102)),
            ("Central Park, past the reservoir (a lake under 1 km² isn't kept)", c(-73.9690, 40.7850), c(-73.9560, 40.7840)),
            ("To the Battery Park City ferry", c(-74.0130, 40.7150), c(-74.0181, 40.7148)),
            ("11 Av to the West 39th Street ferry", c(-73.9990, 40.7585), c(-74.0045, 40.7590)),
            ("Hudson St to the Hoboken 14th Street ferry", c(-74.0285, 40.7520), c(-74.0233, 40.7535)),
            ("1 Av to the East 34th Street ferry", c(-73.9745, 40.7445), c(-73.9711, 40.7434)),
            ("Center Blvd to the Hunters Point South ferry", c(-73.9555, 40.7440), c(-73.9590, 40.7428)),
            ("Allentown, along Hamilton St", c(-75.4800, 40.6005), c(-75.4680, 40.6030)),
            ("Arlington to Copley, along Boylston St", c(-71.0705, 42.3519), c(-71.0776, 42.3500)),
            ("Union Station to the Old State House in Hartford", c(-72.6818, 41.7688), c(-72.6731, 41.7665)),
            ("Union Station to Court Square in Springfield", c(-72.5932, 42.1066), c(-72.5913, 42.1013)),
        ]
        for (name, a, b) in notAcross {
            XCTAssertFalse(water.crosses(a, b), name)
            XCTAssertFalse(water.crosses(b, a), name + ", the other way")
        }
        XCTAssertEqual(water.overWaterMeters(c(-74.0080, 40.7040), c(-74.0080, 40.7040)), 0, "No line")
    }

    /// Fast enough for every refresh: 400 stations within about 2 km of a place by the East River, all checked
    func testManyStationsAreQuick() throws {
        let water = try XCTUnwrap(WaterMap.shared)
        let here = c(-73.9950, 40.7100)
        let start = Date()
        var across = 0
        for i in 0..<20 {
            for j in 0..<20 {
                if water.crosses(here, c(-74.0150 + Double(i) * 0.002, 40.6950 + Double(j) * 0.0015)) { across += 1 }
            }
        }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(across, 50, "Brooklyn is across the river")
        XCTAssertLessThan(across, 350, "Most of lower Manhattan isn't")
        XCTAssertLessThan(seconds, 1, "400 checks took \(seconds) s")
        print("WaterMap: 400 checks in \(Int(seconds * 1000)) ms, \(across) across")
    }

    /// Only an estimate near enough to be in range is checked; a route is never across the water
    func testTheEstimateIsMarked() {
        let s = CatchSettings.default
        let dumbo = Station(id: "F18", name: "York St", coordinate: Coordinate(latitude: 40.7014, longitude: -73.9866))
        let wall = Coordinate(latitude: 40.7040, longitude: -74.0080)
        var wide = s
        wide.extendedWalkMinutes = 30
        let estimate = WalkEstimator.estimate(from: wall, to: dumbo, settings: wide)
        XCTAssertTrue(estimate.isAcrossWater)
        XCTAssertFalse(WalkEstimator.estimate(from: wall, to: dumbo, settings: wide, routeMeters: 3200).isAcrossWater)
        let far = Coordinate(latitude: 40.75, longitude: -74.05)
        XCTAssertNil(WalkEstimator.estimate(from: far, to: dumbo, settings: s).acrossWater, "Out of range: not checked")
        let fulton = Station(id: "A38", name: "Fulton St", coordinate: Coordinate(latitude: 40.7102, longitude: -74.0076))
        XCTAssertNil(WalkEstimator.estimate(from: wall, to: fulton, settings: s).acrossWater)
    }

    /// At most "Not sure" across the water; "take the next one" stays
    func testTheVerdictIsNotSureAtBest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = { (seconds: TimeInterval) in
            Arrival(id: "a", stationID: "S", route: "F", direction: Direction(code: "N", name: "Uptown"),
                    arrivalTime: now.addingTimeInterval(seconds), source: .realtime, status: .normal, updatedAt: now)
        }
        let across = WalkEstimate(walkSeconds: 300, straightLineMeters: 1800, source: .estimated, acrossWater: true)
        let plain = WalkEstimate(walkSeconds: 300, straightLineMeters: 1800, source: .estimated)
        let s = CatchSettings.default
        func verdict(_ w: WalkEstimate, _ seconds: TimeInterval) -> CatchEvaluation {
            CatchEvaluator.evaluate(arrival: a(seconds), walk: w, entranceToPlatformSeconds: 60, settings: s, now: now, clockOffset: 0)
        }
        XCTAssertEqual(verdict(plain, 1200).verdict, .canTry)
        XCTAssertEqual(verdict(across, 1200).verdict, .insufficientInfo)
        XCTAssertTrue(verdict(across, 1200).notes.contains(.acrossWater))
        XCTAssertFalse(verdict(plain, 1200).notes.contains(.acrossWater))
        XCTAssertEqual(verdict(plain, 400).verdict, .tight)
        XCTAssertEqual(verdict(across, 400).verdict, .insufficientInfo)
        XCTAssertEqual(verdict(across, 100).verdict, .takeNext)
        // A route marked across the water by mistake still counts as a route
        var route = across
        route.source = .route
        XCTAssertEqual(verdict(route, 1200).verdict, .canTry)
    }

    /// Walks saved before the mark existed still read, as not across the water; the mark is saved and read back
    func testSavedWalksStillRead() throws {
        let old = #"{"walkSeconds":300,"straightLineMeters":400,"source":"estimated"}"#
        let w = try JSONDecoder().decode(WalkEstimate.self, from: Data(old.utf8))
        XCTAssertFalse(w.isAcrossWater)
        let marked = WalkEstimate(walkSeconds: 300, straightLineMeters: 400, source: .estimated, acrossWater: true)
        let back = try JSONDecoder().decode(WalkEstimate.self, from: JSONEncoder().encode(marked))
        XCTAssertTrue(back.isAcrossWater)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("acrossWater"), "Not written when not across")
    }

    /// Across the water: asked first, asked again after a minute, and waited for while a route may still come
    func testTheRouteBookWaitsForAcrossWater() {
        let here = Coordinate(latitude: 40.75, longitude: -73.99)
        let stations = (1...3).map { i in
            Station(id: "S\(i)", name: "S\(i)", coordinate: Coordinate(latitude: 40.75 + Double(i) * 100 / 111_195, longitude: -73.99))
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var book = WalkRouteBook()
        XCTAssertTrue(book.awaitsRoute(for: stations[2], from: here), "No origin yet: it may come")
        let ask = book.next(from: here, stations: stations, limit: 2, now: t0, acrossWater: ["S3"])
        XCTAssertEqual(ask.targets.map(\.id), ["S3", "S1"], "Across the water first, then the nearest")
        XCTAssertTrue(book.awaitsRoute(for: stations[2], from: here), "Being asked")
        book.received([:], for: ask.targets, from: here, now: t0)
        XCTAssertFalse(book.awaitsRoute(for: stations[2], from: here), "Failed: shown as it is until asked again")
        XCTAssertTrue(book.awaitsRoute(for: stations[1], from: here), "Not asked yet")
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 5, now: t0.addingTimeInterval(59), acrossWater: ["S3"])
            .targets.map(\.id), ["S2"])
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 5, now: t0.addingTimeInterval(60), acrossWater: ["S3"])
            .targets.map(\.id), ["S3"], "Across the water: again after a minute; S1 waits 5 minutes")
        book.received(["S3": 900], for: [stations[2]], from: here, now: t0)
        XCTAssertFalse(book.awaitsRoute(for: stations[2], from: here), "Has its route")
        let moved = Coordinate(latitude: 40.75, longitude: -73.99 + 40 / 84_400)
        XCTAssertTrue(book.awaitsRoute(for: stations[0], from: moved), "Moved: every station is asked again")
    }
}
