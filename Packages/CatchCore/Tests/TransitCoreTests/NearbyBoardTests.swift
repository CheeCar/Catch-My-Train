import XCTest
@testable import TransitCore

/// Group trips by station (like the official MTA app): show both directions, and merge stations connected inside into one complex.
final class NearbyBoardTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func arrival(_ catalog: StationCatalog, _ stationID: String, _ route: String, _ code: String,
                 _ minutes: Double?, _ n: Int = 0, status: TripStatus = .normal) -> Arrival {
        Arrival(id: "\(stationID)-\(route)-\(code)-\(n)", stationID: stationID, route: route,
                direction: catalog.direction(stationID: stationID, route: route, code: code),
                arrivalTime: minutes.map { now.addingTimeInterval($0 * 60) },
                source: .realtime, status: status, updatedAt: now)
    }

    func routes(_ catalog: StationCatalog, _ ids: [String]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: ids.map { id in (id, catalog.entry(id: id)?.routes.map(\.route) ?? []) })
    }

    // MARK: Times Sq-42 St on the 7: both the Queens and Hudson Yards directions must show

    func testTimesSquareShowsBothDirections() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "725"))
        let user = Coordinate(latitude: 40.7614, longitude: -73.9776) // the Museum of Modern Art, about 1,080 m from Times Sq-42 St
        // A walking route of 1,180 m (an example length) → 15.7 minutes, plus 1.5 minutes to enter ≈ 17.2 minutes to the platform
        let walk = WalkEstimator.estimate(from: user, to: station, settings: .default, routeMeters: 1180)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["725": walk],
            arrivals: [arrival(catalog, "725", "7", "N", 10, 0), arrival(catalog, "725", "7", "N", 20, 1),
                       arrival(catalog, "725", "7", "S", 12, 0), arrival(catalog, "725", "7", "S", 25, 1)],
            settings: .default, now: now, routes: routes(catalog, ["725"]))

        XCTAssertEqual(board.stations.count, 1)
        let times = try XCTUnwrap(board.stations.first)
        XCTAssertEqual(times.name, "Times Sq-42 St")
        XCTAssertEqual(times.range, .extended, "15.7 minutes, a bit over the 15-minute main range")
        XCTAssertEqual(times.routes, ["7"], "7X express merged into 7")

        // Toward Queens: the platform's sign, with the terminal
        XCTAssertEqual(times.north.directions.first?.terminal, "Flushing-Main St")
        XCTAssertEqual(times.north.directions.first?.label, "Queens")
        XCTAssertEqual(times.north.trains.map(\.verdict), [.takeNext, .canTry])
        XCTAssertEqual(times.north.trains.first?.recommended?.arrival.id, "725-7-N-1")
        XCTAssertEqual(times.north.firstCatchable?.id, "725-7-N-1")

        // Toward Hudson Yards
        XCTAssertEqual(times.south.directions.first?.label, "Hudson Yards")
        XCTAssertEqual(times.south.trains.map(\.verdict), [.takeNext, .canTry])
        XCTAssertEqual(times.direction("S").code, "S")
    }

    /// A direction with nothing in the arrival window says when the next one comes, when a later departure is known
    func testAnEmptyDirectionKnowsTheNextDepartureAfterTheWindow() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        var settings = CatchSettings.default
        settings.arrivalWindowMinutes = 60
        func board(_ arrivals: [Arrival], later: [Arrival] = [], filter: Set<String>? = nil) -> BoardStation? {
            NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals, later: later,
                                     settings: settings, now: now, routes: routes(catalog, ["712"]), routeFilter: filter,
                                     clockOffset: 0).stations.first
        }
        // Nothing known after the window: no next time, in either direction
        let none = try XCTUnwrap(board([arrival(catalog, "712", "7", "S", 12)]))
        XCTAssertNil(none.north.next)
        XCTAssertNil(none.south.next, "A direction with trains says nothing")
        // The earliest of the later ones, whichever list it is in; a direction with trains still says nothing
        let later = [arrival(catalog, "712", "7", "N", 300, 1), arrival(catalog, "712", "7", "N", 200, 2),
                     arrival(catalog, "712", "7", "S", 150, 3)]
        let found = try XCTUnwrap(board([arrival(catalog, "712", "7", "S", 12), arrival(catalog, "712", "7", "N", 70, 4)], later: later))
        XCTAssertTrue(found.north.trains.isEmpty, "70 minutes is past the one-hour window")
        XCTAssertEqual(found.north.next, now.addingTimeInterval(70 * 60))
        XCTAssertNil(found.south.next)
        XCTAssertEqual(try XCTUnwrap(board([], later: later)).north.next, now.addingTimeInterval(200 * 60))
        XCTAssertEqual(try XCTUnwrap(board([], later: later)).south.next, now.addingTimeInterval(150 * 60))
        // Not a cancelled one, not one of a line filtered out, and not one inside the window that only the later list has
        let cancelled = arrival(catalog, "712", "7", "N", 90, 5, status: .cancelled)
        XCTAssertEqual(try XCTUnwrap(board([], later: [cancelled] + later)).north.next, now.addingTimeInterval(200 * 60))
        XCTAssertNil(try XCTUnwrap(board([], later: later, filter: ["E"])).north.next)
        XCTAssertNil(try XCTUnwrap(board([], later: [arrival(catalog, "712", "7", "N", 30, 6)])).north.next)
        // Not one a day or more from now: its clock time would read as today's ("Next: 4:00 PM" at 3:58 PM for tomorrow's)
        XCTAssertNil(try XCTUnwrap(board([], later: [arrival(catalog, "712", "7", "N", 24 * 60 + 2, 7)])).north.next)
        XCTAssertNil(try XCTUnwrap(board([arrival(catalog, "712", "7", "N", 24 * 60, 8)])).north.next)
        XCTAssertEqual(try XCTUnwrap(board([], later: [arrival(catalog, "712", "7", "N", 23 * 60 + 58, 9)])).north.next,
                       now.addingTimeInterval((23 * 60 + 58) * 60), "Earlier than now by the clock: tomorrow's, as it reads")
        // Older saved boards have no such time
        let json = try JSONEncoder().encode(BoardDirection(code: "N", directions: [], routes: [], trains: []))
        XCTAssertNil(try JSONDecoder().decode(BoardDirection.self, from: json).next)
    }

    /// Only the first later departure per station, line and direction is kept for it
    func testOnlyTheFirstLaterDeparturePerDirectionIsKept() throws {
        let catalog = try StationCatalog.loadBundled()
        let list = [arrival(catalog, "712", "7", "N", 300, 1), arrival(catalog, "712", "7", "N", 200, 2),
                    arrival(catalog, "712", "7", "S", 150, 3), arrival(catalog, "712", "7", "S", nil, 4),
                    arrival(catalog, "712", "7", "S", 100, 5, status: .cancelled)]
        XCTAssertEqual(Arrival.firstPerDirection(list).map(\.id), ["712-7-S-3", "712-7-N-2"])
        XCTAssertTrue(Arrival.firstPerDirection([]).isEmpty)
    }

    /// Seen in real data: the first 7 train only goes to Mets-Willets Point, the rest go to Flushing-Main St.
    /// The title lists every terminal, most frequent first, not only the first train's.
    func testDirectionTitleCoversEveryTerminal() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        func north(_ minutes: Double, _ n: Int, last: String) -> Arrival {
            Arrival(id: "712-7-N-\(n)", stationID: "712", route: "7",
                    direction: catalog.direction(stationID: "712", route: "7", code: "N", lastStationID: last),
                    arrivalTime: now.addingTimeInterval(minutes * 60), source: .realtime, updatedAt: now)
        }
        let arrivals = [north(3, 0, last: "702"), north(5, 1, last: "701"), north(7, 2, last: "701"),
                        north(9, 3, last: "701"), north(10, 4, last: "701")]
        let board = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals,
                                             settings: .default, now: now, routes: routes(catalog, ["712"]))
        let woodside = try XCTUnwrap(board.stations.first)
        XCTAssertEqual(woodside.north.trains.first?.direction.terminal, "Mets-Willets Point")
        XCTAssertEqual(woodside.north.directions.compactMap(\.terminal), ["Flushing-Main St", "Mets-Willets Point"])
        // Even when only 1 trip is shown, the title still covers later trips' terminals (main window, menu bar and widget show different trip counts, titles must match)
        let short = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals,
                                             settings: .default, now: now, routes: routes(catalog, ["712"]),
                                             maxTrainsPerDirection: 1)
        XCTAssertEqual(short.stations.first?.north.directions, woodside.north.directions)
    }

    /// When the data lists the same trip at the same stop twice, the board shows it once (each train row needs its own ID), with the newer copy
    func testSameTripListedTwiceShowsOnce() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        var older = arrival(catalog, "712", "7", "N", 12, 0)
        older.updatedAt = now.addingTimeInterval(-60)
        let newer = arrival(catalog, "712", "7", "N", 14, 0)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["712": walk],
            arrivals: [older, arrival(catalog, "712", "7", "N", 20, 1), newer],
            settings: .default, now: now, routes: routes(catalog, ["712"]))
        let trains = try XCTUnwrap(board.stations.first).north.trains
        XCTAssertEqual(trains.map(\.id), ["712-7-N-0", "712-7-N-1"])
        XCTAssertEqual(trains.first?.arrivalTime, now.addingTimeInterval(14 * 60))
    }

    func testDirectionWithoutTrainsStillExists() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["712": walk],
            arrivals: [arrival(catalog, "712", "7", "S", 12)],
            settings: .default, now: now, routes: routes(catalog, ["712"]))
        let woodside = try XCTUnwrap(board.stations.first)
        XCTAssertTrue(woodside.north.trains.isEmpty, "Directions without trips are kept too (UI shows \"no trips\")")
        XCTAssertEqual(woodside.south.trains.count, 1)
        XCTAssertEqual(woodside.routes, ["7"])
    }

    // MARK: 42 St-Bryant Park: several nearby stations and routes

    func bryantParkBoard(routeFilter: Set<String>? = nil, max: Int = 8) throws -> NearbyBoard {
        let catalog = try StationCatalog.loadBundled()
        let user = Coordinate(latitude: 40.754222, longitude: -73.984569)
        let near = catalog.stations(near: user, radiusMeters: 1600)
        var walks: [String: WalkEstimate] = [:]
        for s in near { walks[s.id] = WalkEstimator.estimate(from: user, to: s, settings: .default) }
        var arrivals: [Arrival] = []
        for (i, (id, route)) in [("D16", "B"), ("D16", "D"), ("D16", "F"), ("D16", "M"), ("724", "7"),
                                 ("127", "1"), ("127", "2"), ("127", "3"), ("725", "7"), ("R16", "N"),
                                 ("R16", "Q"), ("R16", "R"), ("R16", "W"), ("A27", "A"), ("A27", "C"),
                                 ("A27", "E"), ("902", "GS"), ("631", "4"), ("631", "5"), ("631", "6")].enumerated() {
            for code in ["N", "S"] {
                for k in 0..<3 {
                    arrivals.append(arrival(catalog, id, route, code, Double(2 + i % 5 + k * 6), k))
                }
            }
        }
        return NearbyBoardBuilder.build(stations: near, walks: walks, arrivals: arrivals, settings: .default,
                                        now: now, routes: routes(catalog, near.map(\.id)),
                                        routeFilter: routeFilter, maxTrainsPerDirection: max)
    }

    func testBryantParkGroupsComplexes() throws {
        let board = try bryantParkBoard()
        let first = try XCTUnwrap(board.stations.first)
        // Nearest complex: 42 St-Bryant Pk (B D F M) and 5 Av (7) connected inside
        XCTAssertEqual(first.name, "42 St-Bryant Pk / 5 Av")
        XCTAssertEqual(Set(first.stations.map(\.id)), ["D16", "724"])
        XCTAssertEqual(first.routes, ["7", "B", "D", "F", "M"], "MTA route order")
        XCTAssertEqual(first.range, .primary)

        // Times Sq complex (including 42 St-Port Authority) merged into one
        let times = try XCTUnwrap(board.stations.first { $0.stations.contains { $0.id == "127" } })
        XCTAssertEqual(times.name, "Times Sq-42 St")
        XCTAssertEqual(Set(times.stations.map(\.id)), ["127", "725", "902", "R16", "A27"])
        XCTAssertEqual(times.routes, ["1", "2", "3", "7", "A", "C", "E", "N", "Q", "R", "W", "GS"])

        // Each station appears once, sorted by walking time (main range first)
        let ids = board.stations.flatMap { $0.stations.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count)
        let primaryWalks = board.stations.filter { $0.range == .primary }.map(\.walk.walkSeconds)
        XCTAssertEqual(primaryWalks, primaryWalks.sorted())
        XCTAssertTrue(board.stations.contains { $0.name == "Grand Central-42 St" })
    }

    func testDirectionsAreTimeSortedAndCapped() throws {
        let board = try bryantParkBoard(max: 5)
        let first = try XCTUnwrap(board.stations.first)
        for dir in [first.north, first.south] {
            XCTAssertLessThanOrEqual(dir.trains.count, 5)
            let times = dir.trains.compactMap(\.arrivalTime)
            XCTAssertEqual(times, times.sorted())
        }
        // Northbound titles: the 7 says "Queens", B D F M say "Uptown"
        XCTAssertEqual(first.north.directions.compactMap(\.label), ["Queens", "Uptown"])
        XCTAssertEqual(first.south.directions.compactMap(\.label), ["Hudson Yards", "Downtown"])
    }

    func testRouteFilter() throws {
        let board = try bryantParkBoard(routeFilter: ["7"])
        let first = try XCTUnwrap(board.stations.first)
        XCTAssertEqual(first.routes, ["7"])
        XCTAssertTrue(first.north.trains.allSatisfy { $0.route == "7" })
        XCTAssertFalse(first.north.trains.isEmpty)
    }

    // MARK: Selected station (shared by main window, menu bar and widget)

    func testSelectionFallsBackAndCycles() throws {
        let board = try bryantParkBoard()
        let ids = board.stations.map(\.id)
        XCTAssertGreaterThan(ids.count, 3)
        // Never selected, or the selected station is no longer nearby: use the nearest
        XCTAssertEqual(BoardSelection().station(in: board)?.id, ids[0])
        XCTAssertEqual(BoardSelection(stationID: "gone").station(in: board)?.id, ids[0])
        // Cycle among the nearest 3
        var s = BoardSelection()
        s = s.moving(by: 1, in: board, limit: 3)
        XCTAssertEqual(s.stationID, ids[1])
        s = s.moving(by: 1, in: board, limit: 3).moving(by: 1, in: board, limit: 3)
        XCTAssertEqual(s.stationID, ids[0], "After the 3rd, back to the 1st")
        XCTAssertEqual(s.moving(by: -1, in: board, limit: 3).stationID, ids[2], "Cycling backward works too")
        let empty = NearbyBoard(generatedAt: now, stations: [], cancelledCount: 0, oldestDataUpdate: nil)
        XCTAssertNil(BoardSelection().moving(by: 1, in: empty).stationID)
        let data = try JSONEncoder().encode(BoardSelection(stationID: "c609"))
        XCTAssertEqual(try JSONDecoder().decode(BoardSelection.self, from: data).stationID, "c609")
    }

    // MARK: Canceled, departed, no time

    func testCancelledDepartedAndMissing() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 350, source: .route)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["712": walk],
            arrivals: [arrival(catalog, "712", "7", "S", nil, 0),
                       arrival(catalog, "712", "7", "S", -1, 1),
                       arrival(catalog, "712", "7", "S", 9, 2, status: .cancelled),
                       arrival(catalog, "712", "7", "S", 12, 3)],
            settings: .default, now: now)
        let south = try XCTUnwrap(board.stations.first).south
        XCTAssertEqual(south.trains.map(\.id), ["712-7-S-3", "712-7-S-0"], "Trips without a time go last; departed and canceled ones aren't shown")
        XCTAssertEqual(south.trains.last?.verdict, .insufficientInfo)
        XCTAssertEqual(board.cancelledCount, 1)
    }

    /// A train whose time has passed isn't listed, even a moment after: its time is the only one it has
    func testATrainWhoseTimeHasPassedIsNotListed() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 0, straightLineMeters: 0, source: .route)
        let gone = arrival(catalog, "712", "7", "S", -0.5, 0)
        let coming = arrival(catalog, "712", "7", "S", 2, 1)
        let board = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: [gone, coming],
                                             settings: .default, now: now)
        XCTAssertEqual(try XCTUnwrap(board.stations.first).south.trains.map(\.id), ["712-7-S-1"])
    }

    /// One canceled trip passing two nearby stations: counts as one
    func testCancelledTripCountedOnce() throws {
        let catalog = try StationCatalog.loadBundled()
        let a = try XCTUnwrap(catalog.station(id: "712"))
        let b = try XCTUnwrap(catalog.station(id: "713"))
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 350, source: .route)
        func cancelled(_ stationID: String) -> Arrival {
            Arrival(id: "T9|\(stationID)S", stationID: stationID, route: "7",
                    direction: catalog.direction(stationID: stationID, route: "7", code: "S"),
                    arrivalTime: now.addingTimeInterval(600), source: .realtime, status: .cancelled, updatedAt: now)
        }
        let board = NearbyBoardBuilder.build(stations: [a, b], walks: ["712": walk, "713": walk],
                                             arrivals: [cancelled("712"), cancelled("713")], settings: .default, now: now)
        XCTAssertEqual(board.cancelledCount, 1)
        XCTAssertEqual(NearbyBoardBuilder.tripKey(cancelled("712")), NearbyBoardBuilder.tripKey(cancelled("713")))
    }

    /// A station's page says only its own cancelled trips, of the lines picked: a normal station beside one with cancellations
    /// says nothing. The whole board's count stays for the empty page
    func testCancelledTripsAreCountedPerStation() throws {
        let catalog = try StationCatalog.loadBundled()
        let a = try XCTUnwrap(catalog.station(id: "712"))
        let b = try XCTUnwrap(catalog.station(id: "713"))
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 350, source: .route)
        let arrivals = [arrival(catalog, "712", "7", "S", 8, 0),
                        arrival(catalog, "713", "7", "S", 9, 1, status: .cancelled),
                        arrival(catalog, "713", "7", "N", 11, 2, status: .cancelled),
                        arrival(catalog, "713", "7", "S", 14, 3)]
        let board = NearbyBoardBuilder.build(stations: [a, b], walks: ["712": walk, "713": walk], arrivals: arrivals,
                                             settings: .default, now: now)
        let idA = try XCTUnwrap(board.stations.first { $0.stations.contains { $0.id == "712" } }).id
        let idB = try XCTUnwrap(board.stations.first { $0.stations.contains { $0.id == "713" } }).id
        XCTAssertNotEqual(idA, idB)
        XCTAssertEqual(board.cancelledCount(at: idA), 0)
        XCTAssertEqual(board.cancelledCount(at: idB), 2)
        XCTAssertEqual(board.cancelledCount, 2)
        XCTAssertEqual(board.cancelledCount(at: "nowhere"), 0)
        // Only other lines picked: none of these counts
        let other = NearbyBoardBuilder.build(stations: [a, b], walks: ["712": walk, "713": walk], arrivals: arrivals,
                                             settings: .default, now: now, routeFilter: ["N"])
        XCTAssertEqual(other.cancelledCount(at: idB), 0)
        // One cancelled trip listed at two platforms of one complex (42 St-Bryant Pk / 5 Av) counts once there
        let d16 = try XCTUnwrap(catalog.station(id: "D16"))
        let fifth = try XCTUnwrap(catalog.station(id: "724"))
        func twice(_ stationID: String) -> Arrival {
            Arrival(id: "T5|\(stationID)S", stationID: stationID, route: "7",
                    direction: catalog.direction(stationID: stationID, route: "7", code: "S"),
                    arrivalTime: now.addingTimeInterval(600), source: .realtime, status: .cancelled, updatedAt: now)
        }
        let complex = NearbyBoardBuilder.build(stations: [d16, fifth], walks: ["D16": walk, "724": walk],
                                               arrivals: [twice("D16"), twice("724"), arrival(catalog, "724", "7", "S", 12, 4)],
                                               settings: .default, now: now)
        let idC = try XCTUnwrap(complex.stations.first { $0.stations.contains { $0.id == "724" } }).id
        XCTAssertEqual(complex.cancelledCount(at: idC), 1)
    }

    /// Some data groups fail to download: successful ones are refreshed, the failed group keeps the old
    func testRealtimeMergeKeepsFailedFeeds() throws {
        let catalog = try StationCatalog.loadBundled()
        let fresh = arrival(catalog, "712", "7", "S", 5, 1)
        let oldSeven = arrival(catalog, "712", "7", "S", 6, 2)
        let oldL = arrival(catalog, "L03", "L", "S", 6, 3)
        let load = RealtimeLoad(arrivals: [fresh], statuses: [
            FeedStatus(feed: .numbered, state: .ok(feedTimestamp: now), fetchedAt: now),
            FeedStatus(feed: .l, state: .failed(message: "timeout"), fetchedAt: now),
        ])
        XCTAssertEqual(load.merged(keeping: [oldSeven, oldL]).map(\.id), [fresh.id, oldL.id])
    }

    // MARK: Arrival time window (by default only the next 2 hours)

    func testArrivalWindowHidesLaterTrains() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 350, source: .route)
        let arrivals = [arrival(catalog, "712", "7", "S", 10, 0), arrival(catalog, "712", "7", "S", 119, 1),
                        arrival(catalog, "712", "7", "S", 121, 2), arrival(catalog, "712", "7", "S", 200, 3)]
        let byDefault = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals,
                                                 settings: .default, now: now, maxTrainsPerDirection: 20)
        XCTAssertEqual(byDefault.stations.first?.south.trains.map(\.id), ["712-7-S-0", "712-7-S-1"], "2 hours by default")
        var oneHour = CatchSettings.default
        oneHour.arrivalWindowMinutes = 60
        let short = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals,
                                             settings: oneHour, now: now, maxTrainsPerDirection: 20)
        XCTAssertEqual(short.stations.first?.south.trains.map(\.id), ["712-7-S-0"])
        var fourHours = CatchSettings.default
        fourHours.arrivalWindowMinutes = 240
        let long = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: arrivals,
                                            settings: fourHours, now: now, maxTrainsPerDirection: 20)
        XCTAssertEqual(long.stations.first?.south.trains.count, 4)
    }

    /// Settings saved by an older version have no arrival time window: still readable, defaults to 2 hours, other settings are kept.
    func testOldSavedSettingsStillDecode() throws {
        let old = #"{"primaryWalkMinutes":16,"extendedWalkMinutes":22,"candidateRadiusMeters":1200,"safetyBufferMinutes":2,"walkingSpeedKmh":4.5,"detourFactor":1.25,"realtimeStaleAfterSeconds":180,"extendedBetterByMinutes":4}"#
        let s = try JSONDecoder().decode(CatchSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.primaryWalkMinutes, 16)
        XCTAssertNil(s.arrivalWindowMinutes)
        XCTAssertEqual(s.arrivalWindowSeconds, 7200)
        XCTAssertEqual(s.sanitized().arrivalWindowMinutes, 120)
        XCTAssertEqual(CatchSettings.default.arrivalWindowMinutes, 120)
        var odd = CatchSettings.default
        odd.arrivalWindowMinutes = 5000
        XCTAssertEqual(odd.sanitized().arrivalWindowMinutes, 720)
    }

    func testOutOfRangeStationsAreLeftOut() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let far = WalkEstimate(walkSeconds: 30 * 60, straightLineMeters: 2200, source: .route)
        let board = NearbyBoardBuilder.build(stations: [station], walks: ["712": far],
                                             arrivals: [arrival(catalog, "712", "7", "S", 40)],
                                             settings: .default, now: now)
        XCTAssertTrue(board.stations.isEmpty)
    }

    func testSnapshotBoardUsesStationRoutes() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        let snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [station], walks: ["712": walk],
                                   arrivals: [], settings: .default, languageCode: "zh-Hans", unitsCode: "us",
                                   stationRoutes: routes(catalog, ["712"]))
        let decoded = try TransitSnapshot.decode(snap.encoded())
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.board(at: now).stations.first?.routes, ["7"])
        XCTAssertEqual(decoded.languageCode, "zh-Hans")
    }

    /// The widget downloads departures only for the stations its board can show: out of walking range, or with no walk, it has nothing to download
    func testBoardStationIDsMatchBoard() throws {
        let catalog = try StationCatalog.loadBundled()
        let stations = try ["712", "710", "709"].map { try XCTUnwrap(catalog.station(id: $0)) }
        let near = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        let far = WalkEstimate(walkSeconds: 5000, straightLineMeters: 4000, source: .route)
        var snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: stations, walks: ["712": near, "710": far],
                                   arrivals: [arrival(catalog, "710", "7", "S", 10)], settings: .default,
                                   stationRoutes: routes(catalog, ["712", "710", "709"]))
        XCTAssertEqual(snap.boardStationIDs(), ["712"])
        XCTAssertEqual(snap.boardStationIDs(), Set(snap.board(at: now).stations.flatMap { $0.stations.map(\.id) }))
        // Settings passed in win over the snapshot's (the widget's own range)
        let short = CatchSettings(primaryWalkMinutes: 5, extendedWalkMinutes: 5)
        XCTAssertEqual(snap.boardStationIDs(settings: short), [])
        XCTAssertTrue(snap.board(at: now, settings: short).stations.isEmpty)
        snap.walks = ["712": far, "710": far, "709": far]
        XCTAssertEqual(snap.boardStationIDs(), [])
        XCTAssertTrue(snap.board(at: now).stations.isEmpty)
    }

    /// The widget's "Updated" time matches the main window: uses the dataTime recorded by the main app; only old snapshots fall back to the oldest trip time.
    func testSnapshotUpdateTimeMatchesApp() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        var old = arrival(catalog, "712", "7", "S", 10, 0)
        old.updatedAt = now.addingTimeInterval(-300)
        let fresh = arrival(catalog, "712", "7", "S", 14, 1)
        var snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [station], walks: [:],
                                   arrivals: [old, fresh], settings: .default)
        XCTAssertNil(snap.dataTime)
        XCTAssertEqual(snap.updateTime, now.addingTimeInterval(-300))
        snap.dataTime = now.addingTimeInterval(-20)
        XCTAssertEqual(snap.updateTime, now.addingTimeInterval(-20))
        let decoded = try TransitSnapshot.decode(snap.encoded())
        XCTAssertEqual(decoded.dataTime, now.addingTimeInterval(-20))
        // Snapshots saved by older versions have no dataTime
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.encoded()) as? [String: Any])
        json.removeValue(forKey: "dataTime")
        let legacy = try TransitSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.dataTime)
        XCTAssertEqual(legacy.updateTime, now.addingTimeInterval(-300))
    }

    /// The widget lists departures only when their times read the same on this Mac's clock: an area in another zone (or a Mac set to
    /// one) gets the hint instead; a zone keeping the same time (Detroit) doesn't count, nor outside the service area or an older
    /// snapshot (no zone)
    func testWidgetTimesInAnotherZone() throws {
        let newYork = MetroArea.newYork.timeZone
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let detroit = try XCTUnwrap(TimeZone(identifier: "America/Detroit"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        var snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [], walks: [:], arrivals: [], settings: .default)
        XCTAssertFalse(snap.timesInAnotherZone(mac: losAngeles, at: now), "older snapshot or outside the service area")
        snap.timeZone = newYork.identifier
        XCTAssertFalse(snap.timesInAnotherZone(mac: newYork, at: now))
        XCTAssertFalse(snap.timesInAnotherZone(mac: detroit, at: now))
        XCTAssertTrue(snap.timesInAnotherZone(mac: losAngeles, at: now))
        XCTAssertTrue(snap.timesInAnotherZone(mac: tokyo, at: now))
        snap.timeZone = tokyo.identifier
        XCTAssertTrue(snap.timesInAnotherZone(mac: newYork, at: now))
        XCTAssertFalse(snap.timesInAnotherZone(mac: tokyo, at: now))
        let decoded = try TransitSnapshot.decode(snap.encoded())
        XCTAssertEqual(decoded.timeZone, tokyo.identifier)
        snap.timeZone = "Not/AZone"
        XCTAssertFalse(snap.timesInAnotherZone(mac: newYork, at: now))
    }

    /// The line under the place's name (how approximate the position is) travels with the snapshot; an older snapshot without it
    /// still decodes, with no line
    func testSnapshotPlaceNote() throws {
        var snap = TransitSnapshot(createdAt: now, placeName: "Current location", stations: [], walks: [:], arrivals: [], settings: .default)
        XCTAssertNil(snap.placeNote)
        snap.placeNote = "Your location is approximate, within about 1,500 m."
        XCTAssertEqual(try TransitSnapshot.decode(snap.encoded()).placeNote, snap.placeNote)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.encoded()) as? [String: Any])
        json["placeNote"] = nil
        let older = try TransitSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.placeNote)
        XCTAssertEqual(older.placeName, "Current location")
    }

    /// The widget keeps live data fresh for 10 minutes, unless the running app said its data was already out of date when it saved
    /// (e.g. downloads failing): then it says "Not sure" after the app's own setting, as the main window does
    func testWidgetFollowsTheAppWhenItsDataWasStale() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        var a = arrival(catalog, "712", "7", "S", 15, 0)
        a.updatedAt = now.addingTimeInterval(-240)
        let walk = WalkEstimate(walkSeconds: 120, straightLineMeters: 150, source: .estimated)
        var snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [station], walks: ["712": walk],
                                   arrivals: [a], settings: .default)
        XCTAssertEqual(snap.widgetStaleAfterSeconds(appRunning: true), 600)
        func verdict(_ appRunning: Bool) -> CatchVerdict? {
            snap.board(at: now, settings: snap.widgetSettings(appRunning: appRunning)).stations.first.map { ($0.north.trains + $0.south.trains).first?.verdict } ?? nil
        }
        XCTAssertEqual(verdict(true), .canTry, "4 minutes old: still fresh on the widget")
        snap.staleWhenSaved = true
        XCTAssertEqual(snap.widgetStaleAfterSeconds(appRunning: true), 180)
        XCTAssertEqual(verdict(true), .insufficientInfo, "the app said its data was out of date: Not sure, as in the main window")
        XCTAssertEqual(snap.widgetStaleAfterSeconds(appRunning: false), 600, "once the app has quit, the widget's own rule")
        // Older snapshots have no such field
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.encoded()) as? [String: Any])
        XCTAssertEqual(json["staleWhenSaved"] as? Bool, true)
        json.removeValue(forKey: "staleWhenSaved")
        let legacy = try TransitSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.staleWhenSaved)
        XCTAssertEqual(legacy.widgetStaleAfterSeconds(appRunning: true), 600)
    }

    /// The sidebar's line under a station: each direction's first train you can catch (subway), or the earliest of both;
    /// a direction whose trains are all too soon shows that there is none
    func testCatchSummaryForTheSidebar() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 240, straightLineMeters: 300, source: .route)
        func board(_ arrivals: [Arrival]) throws -> BoardStation {
            let snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [station], walks: ["712": walk],
                                       arrivals: arrivals, settings: .default)
            return try XCTUnwrap(snap.board(at: now, settings: .default).stations.first)
        }
        let b = try board([arrival(catalog, "712", "7", "S", 2, 0), arrival(catalog, "712", "7", "S", 14, 1),
                           arrival(catalog, "712", "7", "N", 9, 2)])
        let byDirection = b.catchSummary(byDirection: true)
        XCTAssertEqual(byDirection.map(\.direction), ["N", "S"])
        XCTAssertEqual(byDirection.map { $0.train?.arrivalTime }, [now.addingTimeInterval(9 * 60), now.addingTimeInterval(14 * 60)],
                       "the too-soon 2-minute train is skipped")
        XCTAssertEqual(byDirection.map { $0.train?.id }, [b.north.firstCatchable?.id, b.south.firstCatchable?.id],
                       "the same train as the bar on the station page")
        let earliest = b.catchSummary(byDirection: false)
        XCTAssertEqual(earliest.count, 1)
        XCTAssertNil(earliest.first?.direction)
        XCTAssertEqual(earliest.first?.train?.arrivalTime, now.addingTimeInterval(9 * 60))
        // Only a train that's too soon going north: that direction is there, with no train to catch; nothing at all without one
        let none = try board([arrival(catalog, "712", "7", "N", 1, 0)])
        XCTAssertEqual(none.catchSummary(byDirection: true).map(\.direction), ["N"])
        XCTAssertNil(none.catchSummary(byDirection: true).first?.train)
        XCTAssertTrue(none.catchSummary(byDirection: false).isEmpty)
    }

    func testFeedDataTimeUsesOldestSuccessfulFeed() {
        let statuses = [
            FeedStatus(feed: .numbered, state: .ok(feedTimestamp: now.addingTimeInterval(-40)), fetchedAt: now),
            FeedStatus(feed: .nqrw, state: .ok(feedTimestamp: nil), fetchedAt: now.addingTimeInterval(-5)),
            FeedStatus(feed: .l, state: .failed(message: "timeout"), fetchedAt: now.addingTimeInterval(-900)),
        ]
        XCTAssertEqual(FeedStatus.dataTime(statuses), now.addingTimeInterval(-40))
        XCTAssertNil(FeedStatus.dataTime([statuses[2]]), "No update time when everything failed")
        XCTAssertNil(FeedStatus.dataTime([]))
    }

    // MARK: Trains too soon to catch

    /// A long walk and trains every 30 seconds: trains too soon to catch must not push out every train worth trying
    func testTooSoonTrainsDontFillTheList() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 900, straightLineMeters: 1000, source: .route)
        let arrivals = (1...40).map { arrival(catalog, "712", "7", "S", Double($0) / 2, $0) }
        func south(_ kept: Int?, _ list: [Arrival]) throws -> [BoardTrain] {
            let board = NearbyBoardBuilder.build(stations: [station], walks: ["712": walk], arrivals: list, settings: .default,
                                                 now: now, maxTrainsPerDirection: 24, tooSoonKept: kept)
            return try XCTUnwrap(board.stations.first).south.trains
        }
        // At the platform after 16.5 minutes: the 32 trains before that are too soon
        let all = try south(nil, arrivals)
        XCTAssertEqual(all.count, 24)
        XCTAssertTrue(all.allSatisfy { $0.verdict == .takeNext }, "Without skipping, only trains too soon to catch fit")
        let one = try south(1, arrivals)
        XCTAssertEqual(one.first?.id, "712-7-S-32")
        XCTAssertEqual(one.first?.verdict, .takeNext)
        XCTAssertEqual(one.dropFirst().first?.verdict, .tight)
        XCTAssertEqual(one.count, 9)
        let none = try south(0, arrivals)
        XCTAssertEqual(none.first?.id, "712-7-S-33")
        XCTAssertEqual(none.count, 8)
        // Every train too soon: the first ones still show
        let soon = try south(0, Array(arrivals.prefix(10)))
        XCTAssertEqual(soon.first?.id, "712-7-S-1")
        XCTAssertEqual(soon.count, 10)
    }

    /// Only cancellations among the trains the board would show count: not ones that already left, nor ones beyond the time window
    func testCancelledCountUsesTheShownWindow() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 350, source: .route)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["712": walk],
            arrivals: [arrival(catalog, "712", "7", "S", -5, 0, status: .cancelled),
                       arrival(catalog, "712", "7", "S", 200, 1, status: .cancelled),
                       arrival(catalog, "712", "7", "S", 30, 2, status: .cancelled),
                       arrival(catalog, "712", "7", "S", 12, 3)],
            settings: .default, now: now)
        XCTAssertEqual(board.cancelledCount, 1)
    }

    /// The station shown isn't among the nearest (picked further down the list): next goes to the nearest, previous to the last of them
    func testMovingFromAStationOutsideTheNearest() throws {
        let board = try bryantParkBoard()
        let ids = board.stations.map(\.id)
        XCTAssertGreaterThan(ids.count, 4)
        let far = BoardSelection(stationID: ids[4])
        XCTAssertEqual(far.moving(by: 1, in: board, limit: 3).stationID, ids[0])
        XCTAssertEqual(far.moving(by: -1, in: board, limit: 3).stationID, ids[2])
    }

    /// A snapshot the widget can't update by itself is used up once its last departure has passed, or 15 minutes after it was saved
    func testSnapshotIsUsedUp() throws {
        let catalog = try StationCatalog.loadBundled()
        let station = try XCTUnwrap(catalog.station(id: "712"))
        var a = arrival(catalog, "712", "7", "S", 30, 0)
        a.source = .scheduled
        let snap = TransitSnapshot(createdAt: now, placeName: "Home", stations: [station], walks: [:], arrivals: [a], settings: .default)
        func used(_ s: TransitSnapshot, _ minutes: Double, appRunning: Bool = false, canUpdateItself: Bool = false,
                  isLive: Bool = false) -> Bool {
            s.isUsedUp(at: now.addingTimeInterval(minutes * 60), appRunning: appRunning, canUpdateItself: canUpdateItself, isLive: isLive)
        }
        XCTAssertFalse(used(snap, 10))
        XCTAssertTrue(used(snap, 16), "15 minutes after saving, later departures are missing")
        XCTAssertFalse(used(snap, 16, appRunning: true))
        XCTAssertFalse(used(snap, 16, canUpdateItself: true))
        XCTAssertFalse(used(snap, 16, isLive: true))
        var early = snap
        early.arrivals = [arrival(catalog, "712", "7", "S", 5, 1)]
        XCTAssertTrue(used(early, 6), "The last departure has passed")
        var demo = snap
        demo.arrivals[0].source = .mock
        XCTAssertFalse(used(demo, 60))
    }
}

/// The data status names whose live data is shown, and says Timetable when nothing shown is live
final class LiveSourceTests: XCTestCase {

    func a(_ route: String, _ source: ArrivalSource = .realtime, assigned: Bool? = nil) -> Arrival {
        Arrival(id: route, stationID: "S", route: route, direction: Direction(code: "N", name: "N"),
                arrivalTime: Date(timeIntervalSince1970: 1_800_000_000), source: source,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000), isAssigned: assigned)
    }

    /// With the network turned off in Settings, working the board out again from saved timetables isn't an update: "Updated"
    /// shows only the time of live data downloaded before, and there is no "Last refresh"
    func testWithTheNetworkOffOnlyDownloadedLiveDataHasAnUpdateTime() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let now = base.addingTimeInterval(600)
        func at(_ source: ArrivalSource, _ seconds: TimeInterval) -> Arrival {
            var arrival = a("7", source)
            arrival.updatedAt = base.addingTimeInterval(seconds)
            return arrival
        }
        let timetable = [at(.scheduled, 600), at(.scheduled, 600)]
        let mixed = timetable + [at(.realtime, 30), at(.realtime, 90)]
        // The network on: the board's own time, whatever it lists
        XCTAssertEqual(BoardTimes.updated(networkAllowed: true, dataTime: now, arrivals: timetable), now)
        XCTAssertNil(BoardTimes.updated(networkAllowed: true, dataTime: nil, arrivals: mixed))
        XCTAssertEqual(BoardTimes.refreshed(networkAllowed: true, lastAttempt: now), now)
        // Off: timetables alone have no update time, though the board was worked out just now
        XCTAssertNil(BoardTimes.updated(networkAllowed: false, dataTime: now, arrivals: timetable))
        XCTAssertNil(BoardTimes.updated(networkAllowed: false, dataTime: now, arrivals: []))
        // Live times kept from before: the newest of theirs
        XCTAssertEqual(BoardTimes.updated(networkAllowed: false, dataTime: now, arrivals: mixed), base.addingTimeInterval(90))
        XCTAssertNil(BoardTimes.refreshed(networkAllowed: false, lastAttempt: now))
    }

    func testSourceFollowsTheShownDepartures() {
        XCTAssertEqual(LiveSource.of([], system: .subway), .one("MTA"), "Subway and MTA buses before anything arrives")
        XCTAssertEqual(LiveSource.of([], system: .bus), .one("MTA"))
        XCTAssertEqual(LiveSource.of([], system: .train), .timetable)
        XCTAssertEqual(LiveSource.of([a("L")], system: .subway), .one("MTA"))
        XCTAssertEqual(LiveSource.of([a("LIRR-BAB"), a("MNR-HUD")], system: .train), .one("MTA"), "LIRR and Metro-North are MTA's")
        XCTAssertEqual(LiveSource.of([a("L", assigned: false)], system: .subway), .timetable,
                       "No train assigned yet: still the timetable's time")
        XCTAssertFalse(LiveSource.timetable.isLive)
        XCTAssertEqual(LiveSource.of([a("L", .scheduled), a("PATH-NWK-WTC")], system: .subway), .one("PATH"))
        XCTAssertEqual(LiveSource.of([a("NYF-ER")], system: .ferry), .one("NYC Ferry"))
        XCTAssertEqual(LiveSource.of([a("NYW")], system: .ferry), .one("NY Waterway"))
        XCTAssertEqual(LiveSource.of([a("NYF-ER"), a("NYW")], system: .ferry), .ferries)
        XCTAssertEqual(LiveSource.of([a("L"), a("PATH-NWK-WTC")], system: .subway), .several)
        XCTAssertEqual(LiveSource.of([a("NYF-ER", .scheduled), a("SIF", .scheduled)], system: .ferry), .timetable)
        XCTAssertTrue(LiveSource.several.isLive)
        // Every area's operators by the same rule, with the short name where the credit is long
        XCTAssertEqual(LiveSource.of([a("NJT-NEC")], system: .train), .one("NJ Transit"))
        XCTAssertEqual(LiveSource.of([a("SRR-PAO"), a("SMT-L1")], system: .train), .one("SEPTA"))
        XCTAssertEqual(LiveSource.of([a("MBS-Red"), a("MBR-CR-Worcester")], system: .subway), .one("MBTA"))
        XCTAssertEqual(LiveSource.of([a("NJB-BXL/60")], system: .bus), .one("Bee-Line"))
        XCTAssertEqual(LiveSource.of([a("NJB-SCT/S92")], system: .bus), .one("SCT"))
        XCTAssertEqual(LiveSource.of([a("M104"), a("NJB-107")], system: .bus), .several, "MTA's and NJ Transit's buses")
    }

    /// The menu bar panel and the widget show one station at a time: only its own departures say whose live data it is, not those
    /// of a station of another operator nearby (Times Sq-42 St's subway beside a PATH station said "Live")
    func testSourceOfOneStationIsItsOwn() {
        func at(_ route: String, _ stationID: String, _ source: ArrivalSource = .realtime) -> Arrival {
            var arrival = a(route, source)
            arrival.id = route + stationID
            arrival.stationID = stationID
            return arrival
        }
        func station(_ ids: [String], routes: [String] = []) -> BoardStation {
            let members = ids.map { Station(id: $0, name: $0, coordinate: Coordinate(latitude: 40.75, longitude: -73.99), entrances: [],
                                            entranceToPlatformSeconds: 0) }
            let empty = BoardDirection(code: "N", directions: [], routes: [], trains: [])
            // A complex's ID isn't one of its stations
            return BoardStation(id: "complex " + ids.joined(separator: " "), name: ids[0], stations: members,
                                walk: WalkEstimate(walkSeconds: 300, straightLineMeters: 400, source: .estimated), range: .primary,
                                routes: routes, north: empty, south: empty)
        }
        let nearby = [at("1", "127"), at("7", "725"), at("PATH-NWK-WTC", "PATH:33S"), at("PATH-JSQ-33S", "PATH:33S")]
        XCTAssertEqual(LiveSource.of(nearby, system: .subway), .several)
        XCTAssertEqual(LiveSource.of(nearby, at: nil, system: .subway), .several)
        XCTAssertEqual(LiveSource.of(nearby, at: station(["127", "725"]), system: .subway), .one("MTA"))
        XCTAssertEqual(LiveSource.of(nearby, at: station(["PATH:33S"]), system: .subway), .one("PATH"))
        XCTAssertEqual(LiveSource.of(nearby + [at("2", "128", .scheduled)], at: station(["128"]), system: .subway), .timetable)
        // A station with nothing yet: all of them, as before
        XCTAssertEqual(LiveSource.of(nearby, at: station(["631"]), system: .subway), .several)
        XCTAssertEqual(LiveSource.of(nearby, at: station(["631"], routes: ["4", "5"]), system: .subway), .several)
        // Unless none of its lines can be live: a stop of ShortLine Hudson and Suburban Transit only, with no bus in the window,
        // beside MTA's live buses
        let buses = [at("M7", "401234"), at("M20", "401234")]
        XCTAssertEqual(LiveSource.of(buses, at: station(["njb:42-7"], routes: ["NJB-SLH/200", "NJB-SUBT/300"]), system: .bus), .timetable)
        XCTAssertEqual(LiveSource.of(buses, at: station(["njb:42-7"], routes: ["NJB-SLH/200", "M7"]), system: .bus), .one("MTA"))
        XCTAssertEqual(LiveSource.of(buses, at: station(["njb:42-7"], routes: ["NJB-BXL/60"]), system: .bus), .one("MTA"),
                       "Bee-Line's can be live: all of them, as before")
        XCTAssertTrue(LiveSource.canBeLive(route: "NJT-NEC"), "NJ Transit Rail with the user's account")
        XCTAssertFalse(LiveSource.canBeLive(route: "AMK-NER"))
    }

    /// Every operator that can have live times has a name for "%@ live" that fits the widget's status line (about as long as
    /// "NY Waterway"): areas.json's "short" where its credit or own name is longer. A new area's operators are checked too
    func testEveryLiveOperatorHasAShortName() {
        var ids = [ModeCoverage.subwayID, ModeCoverage.mtaBusID]
        ids += FerryFeed.Source.allCases.filter { $0.hasRealtime || $0.liveWithAccount }.map(\.rawValue)
        ids += RegionalBusFeed.builtIn.filter(\.canBeLive).map { $0.code.isEmpty ? FerryFeed.Source.njTransitBus.rawValue
            : MetroArea.busOperatorID($0.code) }
        XCTAssertGreaterThan(ids.count, 20)
        for id in ids {
            let name = ModeCoverage.liveName(ofOperator: id)
            XCTAssertNotNil(name, id)
            XCTAssertLessThanOrEqual(name?.count ?? 0, 14, "\(id): \(name ?? "")")
        }
    }
}

/// The widget's notices: only the shown station's providers, and a passing problem is dropped once nobody has retried it for a while
final class SnapshotNoticeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ system: TransitSystem) -> TransitSnapshot {
        TransitSnapshot(createdAt: t0, placeName: "Home", stations: [], walks: [:], arrivals: [], settings: .default,
                        system: system.rawValue)
    }

    func testPassingProblemsExpireButMonthlyOnesLast() {
        var snap = snapshot(.subway)
        let passing = NetworkReach.Notice(provider: "MTA", problem: .noResponse, since: t0)
        let monthly = NetworkReach.Notice(provider: "PATH", problem: .notFound, since: t0, lasting: true)
        snap.reach = [passing, monthly]
        XCTAssertEqual(snap.reachNotices(at: t0.addingTimeInterval(60)), [passing, monthly])
        let later = t0.addingTimeInterval(NetworkReach.forgetAfter + 1)
        XCTAssertEqual(snap.reachNotices(at: later), [monthly], "The app quit long ago: whether MTA is still unreachable isn't known")
        // Seen by the widget itself just now, on an older snapshot
        snap.reachAt = later
        XCTAssertEqual(snap.reachNotices(at: later.addingTimeInterval(60)), [passing, monthly])
        // Offline is a passing problem too
        snap.reachAt = nil
        snap.reach = [NetworkReach.Notice(provider: "", problem: .offline, since: t0)]
        XCTAssertTrue(snap.reachNotices(at: later).isEmpty)
    }

    /// While the app runs it keeps trying and reloads the widget once its notices change: a timeline made then keeps them
    /// to its end, even past forgetAfter
    func testRunningAppsNoticesStayOnTheTimeline() {
        var snap = snapshot(.subway)
        let passing = NetworkReach.Notice(provider: "MTA", problem: .noResponse, since: t0)
        snap.reach = [passing]
        let later = t0.addingTimeInterval(NetworkReach.forgetAfter + 300)
        XCTAssertEqual(snap.reachNotices(at: later, appRunning: true), [passing])
        XCTAssertTrue(snap.reachNotices(at: later, appRunning: false).isEmpty)
        XCTAssertTrue(snap.reachNotices(at: later, stationIDs: ["path:33S"], appRunning: true).isEmpty, "still only this station's")
    }

    /// "Downloading…" or "Loading…" isn't repeated once the app has quit: only the running app gets past it
    func testEmptyTextNeedingTheAppHoldsOnlyWhileItRuns() throws {
        var snap = snapshot(.subway)
        snap.emptyText = "Downloading"
        XCTAssertTrue(snap.emptyTextHolds(appRunning: false), "older snapshots, and reasons that last, are shown as they are")
        snap.emptyTextNeedsApp = true
        XCTAssertTrue(snap.emptyTextHolds(appRunning: true))
        XCTAssertFalse(snap.emptyTextHolds(appRunning: false))
        XCTAssertEqual(try TransitSnapshot.decode(snap.encoded()), snap)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.encoded()) as? [String: Any])
        json.removeValue(forKey: "emptyTextNeedsApp")
        let legacy = try TransitSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.emptyTextNeedsApp)
        XCTAssertTrue(legacy.emptyTextHolds(appRunning: false))
    }

    func testOnlyTheShownStationsProviders() throws {
        var snap = snapshot(.subway)
        let rail = RateLimit.Notice(provider: "NJ Transit rail", until: t0.addingTimeInterval(600))
        let bus = RateLimit.Notice(provider: "NJ Transit bus", until: t0.addingTimeInterval(600))
        snap.rateLimits = [bus, rail]
        XCTAssertEqual(snap.rateLimits(at: t0), [rail], "An older snapshot's other modes are left out too")
        XCTAssertEqual(snap.rateLimits(at: t0, stationIDs: ["njl:39472"]), [rail])
        XCTAssertTrue(snap.rateLimits(at: t0, stationIDs: ["R16"]).isEmpty)
        XCTAssertTrue(snap.rateLimits(at: t0.addingTimeInterval(601)).isEmpty, "The pause is over")
        snap.reach = [NetworkReach.Notice(provider: "PATH", problem: .noDNS, since: t0)]
        XCTAssertEqual(snap.reachNotices(at: t0, stationIDs: ["path:33S"]).map(\.provider), ["PATH"])
        XCTAssertTrue(snap.reachNotices(at: t0, stationIDs: ["R16"]).isEmpty)
        // The new fields round-trip, and older snapshots without them still decode
        snap.reachAt = t0
        snap.emptyText = "Downloading"
        snap.later = [Arrival(id: "later", stationID: "R16", route: "N", direction: Direction(code: "N", name: "Uptown"),
                              arrivalTime: t0.addingTimeInterval(5 * 3600), source: .scheduled, updatedAt: t0)]
        XCTAssertEqual(try TransitSnapshot.decode(snap.encoded()), snap)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snap.encoded()) as? [String: Any])
        json.removeValue(forKey: "reachAt")
        json.removeValue(forKey: "emptyText")
        json.removeValue(forKey: "later")
        let legacy = try TransitSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.reachAt)
        XCTAssertNil(legacy.emptyText)
        XCTAssertNil(legacy.later)
    }
}

/// Why the board is empty, in order: outside the area, network off, timetables missing, an error, loading, nothing nearby
final class EmptyBoardReasonTests: XCTestCase {
    func reason(_ mode: TransitSystem, place: Bool = true, tooApproximate: Bool = false, outsideArea: Bool = false,
                networkAllowed: Bool = true, missing: Bool = false, failed: Bool = false, active: Bool = true, stations: Bool = false,
                error: Bool = false, refreshing: Bool = false) -> EmptyBoardReason {
        EmptyBoardReason.of(mode: mode, hasStartingPlace: place, locationTooApproximate: tooApproximate, outsideArea: outsideArea,
                            networkAllowed: networkAllowed, timetableMissing: missing, downloadFailed: failed, isActive: active,
                            hasStations: stations, hasError: error, isRefreshing: refreshing)
    }

    /// With no place to walk from, that is the reason, whatever else is going on; the next step is choosing one
    func testNoStartingPlaceComesFirst() {
        XCTAssertEqual(reason(.subway, place: false), .noStartingPlace)
        XCTAssertEqual(reason(.ferry, place: false, networkAllowed: false, missing: true, failed: true), .noStartingPlace)
        XCTAssertEqual(reason(.bus, place: false, error: true, refreshing: true), .noStartingPlace)
        XCTAssertEqual(EmptyBoardReason.noStartingPlace.actions, [.choosePlace])
        XCTAssertFalse(EmptyBoardReason.noStartingPlace.needsRunningApp, "The widget says it too once the app has quit")
    }

    /// The empty page's bold line is the reason itself, except "No trains worth catching nearby" (which says it) and no place
    /// (its bold line names what's missing); of several lines only the first is bold, the rest stay under it
    func testTheReasonIsTheBoldLine() {
        let own: [EmptyBoardReason] = [.locationTooApproximate, .outsideArea, .networkOff, .downloading, .downloadFailed,
                                       .downloadsOnStart, .error, .loading]
        XCTAssertTrue(own.allSatisfy(\.isTheBoldLine))
        XCTAssertFalse(EmptyBoardReason.noStationNearby.isTheBoldLine)
        XCTAssertFalse(EmptyBoardReason.noStartingPlace.isTheBoldLine)
        let one = "Couldn't download the ferry timetables. Check your network."
        XCTAssertEqual(EmptyBoardReason.boldLine(of: one).bold, one)
        XCTAssertNil(EmptyBoardReason.boldLine(of: one).rest)
        let two = "Couldn't download the bus timetables. Check your network.\nCan't get data from NJ Transit: its server keeps returning errors."
        XCTAssertEqual(EmptyBoardReason.boldLine(of: two).bold, "Couldn't download the bus timetables. Check your network.")
        XCTAssertEqual(EmptyBoardReason.boldLine(of: two).rest, "Can't get data from NJ Transit: its server keeps returning errors.")
        XCTAssertEqual(EmptyBoardReason.boldLine(of: "A\nB\nC").rest, "B\nC")
        XCTAssertNil(EmptyBoardReason.boldLine(of: "A\n").rest)
    }

    /// A position too far off comes right after having no place at all: nothing else can be known without a place, and the
    /// next step is choosing one. The widget says it too
    func testTooApproximateComesRightAfterNoPlace() {
        XCTAssertEqual(reason(.subway, tooApproximate: true), .locationTooApproximate)
        XCTAssertEqual(reason(.subway, place: false, tooApproximate: true), .noStartingPlace)
        XCTAssertEqual(reason(.ferry, tooApproximate: true, outsideArea: true, networkAllowed: false, missing: true, failed: true),
                       .locationTooApproximate)
        XCTAssertEqual(reason(.bus, tooApproximate: true, stations: true, error: true, refreshing: true), .locationTooApproximate)
        XCTAssertEqual(EmptyBoardReason.locationTooApproximate.actions, [.choosePlace])
        XCTAssertFalse(EmptyBoardReason.locationTooApproximate.needsRunningApp)
    }

    /// Every empty page that has a next step offers it as a button; none while something is on its way
    func testEmptyPagesOfferANextStep() {
        // The sentence says to choose another place or widen the range in Settings: a button for each, after the range for now
        XCTAssertEqual(EmptyBoardReason.noStationNearby.actions, [.extendRange, .choosePlace, .rangeSettings])
        XCTAssertEqual(EmptyBoardReason.outsideArea.actions, [.choosePlace, .showServiceArea])
        XCTAssertEqual(EmptyBoardReason.networkOff.actions, [.openSettings])
        XCTAssertEqual(EmptyBoardReason.downloadFailed.actions, [.refresh])
        XCTAssertEqual(EmptyBoardReason.error.actions, [.refresh])
        XCTAssertEqual(EmptyBoardReason.downloadsOnStart.actions, [.start])
        XCTAssertEqual(EmptyBoardReason.downloading.actions, [])
        XCTAssertEqual(EmptyBoardReason.loading.actions, [])
    }

    /// Jersey City in Subway mode on a new install: PATH and light rail data still downloading, then failed; never "nothing nearby"
    func testSubwayPathAndLightRailData() {
        XCTAssertEqual(reason(.subway, missing: true), .downloading)
        XCTAssertEqual(reason(.subway, missing: true, failed: true), .downloadFailed)
        XCTAssertEqual(reason(.subway, missing: true, failed: true, error: true), .downloadFailed)
        XCTAssertEqual(reason(.subway, missing: false), .noStationNearby)
        // On standby, like the other modes: downloaded once the app is on (not "nothing nearby")
        XCTAssertEqual(reason(.subway, missing: true, active: false), .downloadsOnStart)
        XCTAssertEqual(reason(.subway, missing: true, active: false, error: true), .downloadsOnStart)
        // With subway stations nearby, the missing data isn't why nothing shows
        XCTAssertEqual(reason(.subway, missing: true, active: false, stations: true), .noStationNearby)
    }

    func testNetworkOffComesBeforeDownloads() {
        XCTAssertEqual(reason(.subway, networkAllowed: false, missing: true, failed: true), .networkOff)
        XCTAssertEqual(reason(.ferry, networkAllowed: false, missing: true, failed: true), .networkOff)
        XCTAssertEqual(reason(.train, networkAllowed: false, missing: true, active: false), .networkOff)
        XCTAssertEqual(reason(.ferry, outsideArea: true, networkAllowed: false, missing: true), .outsideArea)
    }

    /// With the data on this Mac, the network being off doesn't explain an empty board: turning it on brings no station nearby
    func testNetworkOffOnlyExplainsMissingData() {
        XCTAssertEqual(reason(.subway, networkAllowed: false), .noStationNearby)
        XCTAssertEqual(reason(.train, networkAllowed: false), .noStationNearby)
        XCTAssertEqual(reason(.ferry, networkAllowed: false, refreshing: true), .loading)
        XCTAssertEqual(reason(.subway, networkAllowed: false, missing: true, active: false), .networkOff)
        XCTAssertEqual(reason(.bus, networkAllowed: false, missing: true, stations: true), .noStationNearby)
    }

    /// Downloads and loading happen only in the running app: the widget doesn't repeat them once it has quit
    func testOnlyTheRunningAppGetsPastDownloadsAndLoading() {
        XCTAssertEqual([EmptyBoardReason.noStartingPlace, .locationTooApproximate, .outsideArea, .networkOff, .downloading, .downloadFailed,
                        .downloadsOnStart, .error, .loading, .noStationNearby].filter(\.needsRunningApp),
                       [.downloading, .downloadsOnStart, .loading])
    }

    func testTimetableModes() {
        XCTAssertEqual(reason(.train, missing: true), .downloading)
        XCTAssertEqual(reason(.ferry, missing: true, failed: true), .downloadFailed)
        XCTAssertEqual(reason(.ferry, missing: true, active: false), .downloadsOnStart)
        // Bus has MTA stops too: only when none is nearby
        XCTAssertEqual(reason(.bus, missing: true, active: false), .downloadsOnStart)
        XCTAssertEqual(reason(.bus, missing: true, stations: true), .noStationNearby)
    }

    func testErrorThenLoadingThenNothingNearby() {
        XCTAssertEqual(reason(.subway, error: true, refreshing: true), .error)
        XCTAssertEqual(reason(.subway, refreshing: true), .loading)
        XCTAssertEqual(reason(.bus), .noStationNearby)
    }
}

// MARK: - Stations without times

/// Stations and piers whose operators publish no times the app can use (NoTimesStations): listed with a link to the operator's
/// website, after the stations with departures in their range, never grouped with them, and left out of the menu bar and widgets
final class NoTimesStationsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheList() {
        XCTAssertEqual(NoTimesStations.all.count, 58)
        XCTAssertEqual(NoTimesStations.stations(for: .subway).count, 9)
        XCTAssertEqual(NoTimesStations.stations(for: .ferry).count, 49)
        XCTAssertTrue(NoTimesStations.stations(for: .train).isEmpty)
        XCTAssertTrue(NoTimesStations.stations(for: .bus).isEmpty)
        let ids = NoTimesStations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "IDs are unique")
        XCTAssertEqual(Set(NoTimesStations.agencies.map(\.key)).count, NoTimesStations.agencies.count)
        XCTAssertEqual(Set(NoTimesStations.agencies.map(\.name)).count, NoTimesStations.agencies.count)
        for place in NoTimesStations.all {
            XCTAssertTrue(place.id.hasPrefix(NoTimesStations.idPrefix + place.agency.key + ":"), place.id)
            XCTAssertTrue(NoTimesStations.isNoTimes(place.id))
            XCTAssertEqual(NoTimesStations.station(id: place.id), place)
            XCTAssertTrue(NoTimesStations.agencies.contains(place.agency), place.id)
            XCTAssertFalse(place.name.isEmpty)
            XCTAssertTrue(ServiceArea.contains(place.coordinate), "\(place.name) is outside the service area")
            XCTAssertEqual(place.website.scheme, "https", place.id)
            XCTAssertFalse(place.website.host?.isEmpty ?? true, place.id)
            // As a station of the nearby list: its own ID, and nothing to group it with another
            XCTAssertEqual(place.station.id, place.id)
            XCTAssertNil(place.station.complexID)
            // No data source claims the ID
            XCTAssertFalse(FerryFeed.Source.allCases.contains { $0.owns(id: place.id) }, place.id)
            XCTAssertFalse(RooseveltIslandTram.isTramStation(place.id))
        }
        for agency in NoTimesStations.agencies {
            let names = NoTimesStations.all.filter { $0.agency == agency }.map(\.name)
            XCTAssertFalse(names.isEmpty, agency.name)
            XCTAssertEqual(Set(names).count, names.count, "\(agency.name): two stations with one name")
            if let headway = agency.headwayMinutes {
                XCTAssertGreaterThan(headway.lowerBound, 0, agency.name)
                XCTAssertLessThan(headway.lowerBound, headway.upperBound, agency.name)
            }
        }
        // The headways their websites give
        XCTAssertEqual(NoTimesStations.airTrainJFK.headwayMinutes, 5...15)
        XCTAssertEqual(NoTimesStations.northFerry.headwayMinutes, 8...15)
        XCTAssertEqual(NoTimesStations.southFerry.headwayMinutes, 10...15)
        XCTAssertEqual(NoTimesStations.governorsIslandFerry.headwayMinutes, 15...30)
        XCTAssertEqual(NoTimesStations.agencies.filter { $0.headwayMinutes != nil }.count, 4)
        XCTAssertFalse(NoTimesStations.isNoTimes("G06"))
        XCTAssertNil(NoTimesStations.station(id: "notimes:airtrain-jfk:terminal-2"))
    }

    /// Each one is a place of its own: at least 50 m from every other one of its operator and from every subway and tram station
    /// (the nearest is AirTrain's Howard Beach, 85 m from the subway's). Two operators can share a pier, each with its own
    /// station there: Cross Sound Ferry's and Block Island Express's New London, City Cruises' and Captain John's Provincetown
    func testStationsDontSitOnOtherStations() throws {
        let catalog = try StationCatalog.loadBundled()
        for place in NoTimesStations.all {
            for other in NoTimesStations.all where other.id != place.id && other.agency == place.agency {
                XCTAssertGreaterThanOrEqual(WalkEstimator.distanceMeters(place.coordinate, other.coordinate), 50,
                                            "\(place.id) and \(other.id)")
            }
            XCTAssertTrue(catalog.stations(near: place.coordinate, radiusMeters: 50).isEmpty, place.id)
            XCTAssertTrue(RooseveltIslandTram.stations(near: place.coordinate, radiusMeters: 50).isEmpty, place.id)
        }
    }

    /// A pier two operators use is a row for each, side by side, nearest first and then by ID, each opening its own operator's page;
    /// each row's ID is its own, so a list holding both shows both
    func testASharedPierIsARowForEachOperator() throws {
        let pairs: [(String, String)] = [
            ("notimes:block-island-express:new-london", "notimes:cross-sound-ferry:new-london"),
            ("notimes:captain-john:provincetown", "notimes:city-cruises-provincetown:provincetown"),
        ]
        for (a, b) in pairs {
            let first = try XCTUnwrap(NoTimesStations.station(id: a)), second = try XCTUnwrap(NoTimesStations.station(id: b))
            XCTAssertEqual(first.name, second.name)
            XCTAssertEqual(first.coordinate, second.coordinate)
            XCTAssertNotEqual(first.agency, second.agency)
            XCTAssertNotEqual(first.website, second.website)
            let here = NoTimesStations.stations(.ferry, near: first.coordinate, radiusMeters: 30).map(\.id)
            XCTAssertEqual(here, [a, b])
        }
        // The new operators' piers, each in its metro area
        let areas: [(String, MetroArea)] = [
            ("notimes:jamestown-newport-ferry:jamestown", .greaterBoston), ("notimes:jamestown-newport-ferry:perrotti-park", .greaterBoston),
            ("notimes:prudence-ferry:bristol", .greaterBoston), ("notimes:prudence-ferry:prudence-island", .greaterBoston),
            ("notimes:chappy-ferry:edgartown", .greaterBoston), ("notimes:captain-john:plymouth", .greaterBoston),
            ("notimes:block-island-express:old-harbor", .greaterBoston), ("notimes:viking-fleet:new-harbor", .greaterBoston),
            ("notimes:block-island-express:new-london", .newYork), ("notimes:viking-fleet:montauk", .newYork),
        ]
        for (id, area) in areas {
            XCTAssertEqual(NoTimesStations.station(id: id).flatMap { MetroArea.of($0.coordinate) }, area, id)
        }
    }

    func testNearbyAreTheModesOwnNearestFirst() {
        // Between AirTrain's Howard Beach and Lefferts Blvd stations
        let between = Coordinate(latitude: 40.6614, longitude: -73.8262)
        XCTAssertEqual(NoTimesStations.stations(.subway, near: between, radiusMeters: 600).map(\.name), ["Lefferts Blvd", "Howard Beach"])
        XCTAssertTrue(NoTimesStations.stations(.ferry, near: between, radiusMeters: 600).isEmpty)
        XCTAssertTrue(NoTimesStations.stations(.train, near: between, radiusMeters: 5000).isEmpty)
        // Bay Shore's pier is Ferry's only
        let bayShore = Coordinate(latitude: 40.7150, longitude: -73.2430)
        XCTAssertEqual(NoTimesStations.stations(.ferry, near: bayShore, radiusMeters: 500).map(\.name), ["Bay Shore"])
        XCTAssertTrue(NoTimesStations.stations(.subway, near: bayShore, radiusMeters: 500).isEmpty)
        XCTAssertTrue(NoTimesStations.stations(.bus, near: bayShore, radiusMeters: 500).isEmpty)
    }

    /// A crossing (North Ferry, South Ferry, the Governors Island ferry): only the terminal on the place's side of the water is
    /// listed, though the other one is within walking range in a straight line. Other operators keep every pier in range
    func testOnlyTheNearerEndOfACrossing() throws {
        XCTAssertEqual(NoTimesStations.agencies.filter(\.crossesWater),
                       [NoTimesStations.northFerry, NoTimesStations.southFerry, NoTimesStations.governorsIslandFerry])
        for agency in NoTimesStations.agencies where agency.crossesWater {
            let ends = NoTimesStations.all.filter { $0.agency == agency }
            XCTAssertEqual(ends.count, 2, agency.name)
            // Within range of each other in a straight line (Soissons Landing is 888 m from the Battery Maritime Building,
            // Shelter Island 555 m from North Haven, Shelter Island Heights 1,461 m from Greenport)
            XCTAssertLessThan(WalkEstimator.distanceMeters(ends[0].coordinate, ends[1].coordinate), 1500, agency.name)
            for end in ends {
                XCTAssertEqual(NoTimesStations.stations(.ferry, near: end.coordinate, radiusMeters: 1600).map(\.id), [end.id], end.name)
            }
        }
        // From the Brooklyn side the island's end is the nearer one, so it's still listed (a known limit: which side of the water a
        // place is on isn't known)
        let atlanticBasin = Coordinate(latitude: 40.6834, longitude: -74.0128)
        XCTAssertEqual(NoTimesStations.stations(.ferry, near: atlanticBasin, radiusMeters: 1600).map(\.name), ["Soissons Landing"])
        // Fire Island: its piers are walked between along the island, so Ocean Beach's neighbours stay
        let oceanBeach = try XCTUnwrap(NoTimesStations.station(id: "notimes:fire-island-ferries:ocean-beach"))
        XCTAssertEqual(NoTimesStations.stations(.ferry, near: oceanBeach.coordinate, radiusMeters: 1600).map(\.name),
                       ["Ocean Beach", "Seaview", "Ocean Bay Park"])
    }

    /// No walking route is asked for a station without times, so a long detour from Apple Maps can't put one out of range.
    /// From the subway's Howard Beach-JFK Airport (85 m away), AirTrain's Howard Beach comes second, in the primary range,
    /// with an estimated walk
    func testNoWalkingRouteIsAskedForThem() throws {
        let catalog = try StationCatalog.loadBundled()
        let subway = try XCTUnwrap(catalog.station(id: "H03"))
        let airTrain = try XCTUnwrap(NoTimesStations.station(id: "notimes:airtrain-jfk:howard-beach"))
        let lefferts = try XCTUnwrap(NoTimesStations.station(id: "notimes:airtrain-jfk:lefferts-blvd"))
        XCTAssertTrue(WalkEstimator.asksForRoute(to: subway))
        for place in NoTimesStations.all {
            XCTAssertFalse(WalkEstimator.asksForRoute(to: place.station), place.id)
        }
        // The main window's requests go to the stations with times, though AirTrain's are as near or nearer
        let here = subway.coordinate
        let stations = [airTrain.station, lefferts.station, subway]
        var book = WalkRouteBook()
        XCTAssertEqual(book.next(from: here, stations: stations, limit: 1, now: now).targets.map(\.id), [subway.id])
        XCTAssertTrue(book.next(from: here, stations: stations, limit: 5, now: now).targets.isEmpty)
        XCTAssertTrue(book.received([subway.id: 0], for: [subway], from: here, now: now))
        XCTAssertTrue(book.next(from: here, stations: stations, limit: 5, now: now.addingTimeInterval(600)).targets.isEmpty,
                      "Not asked later either")
        // So their walks are the straight-line estimate
        let settings = CatchSettings()
        let routes = book.routeMeters(from: here)
        var walks: [String: WalkEstimate] = [:]
        for s in stations {
            walks[s.id] = WalkEstimator.estimate(from: here, to: s, settings: settings, routeMeters: routes[s.id])
        }
        XCTAssertEqual(walks[subway.id]?.source, .route)
        XCTAssertEqual(walks[airTrain.id]?.source, .estimated)
        XCTAssertEqual(walks[lefferts.id]?.source, .estimated)
        XCTAssertEqual(try XCTUnwrap(walks[airTrain.id]).walkSeconds, 85 * settings.detourFactor / settings.walkingSpeedMetersPerSecond,
                       accuracy: 3)
        let board = NearbyBoardBuilder.build(stations: stations, walks: walks, arrivals: [], settings: settings, now: now)
        XCTAssertEqual(board.stations.map(\.name), ["Howard Beach-JFK Airport", "Howard Beach", "Lefferts Blvd"])
        XCTAssertEqual(board.stations.map(\.range), [.primary, .primary, .primary])
    }

    /// At Jamaica: the subway's Sutphin Blvd-Archer Av and Jamaica-Van Wyck, AirTrain's Jamaica (the nearest), and Sutphin Blvd
    /// in the extended range
    private func jamaicaBoard() throws -> (board: NearbyBoard, ids: [String], airTrain: NoTimesStation) {
        let catalog = try StationCatalog.loadBundled()
        let sutphin = try XCTUnwrap(catalog.station(id: "G06"))
        let vanWyck = try XCTUnwrap(catalog.station(id: "G07"))
        let farther = try XCTUnwrap(catalog.station(id: "F04"))
        let airTrain = try XCTUnwrap(NoTimesStations.station(id: "notimes:airtrain-jfk:jamaica"))
        let walks: [String: WalkEstimate] = [
            sutphin.id: WalkEstimate(walkSeconds: 4 * 60, straightLineMeters: 300, source: .route),
            vanWyck.id: WalkEstimate(walkSeconds: 9 * 60, straightLineMeters: 700, source: .route),
            farther.id: WalkEstimate(walkSeconds: 17 * 60, straightLineMeters: 1100, source: .route),
            airTrain.id: WalkEstimate(walkSeconds: 3 * 60, straightLineMeters: 200, source: .route),
        ]
        let board = NearbyBoardBuilder.build(stations: [airTrain.station, sutphin, vanWyck, farther], walks: walks, arrivals: [],
                                             settings: .default, now: now,
                                             routes: [sutphin.id: ["E", "J", "Z"], vanWyck.id: ["E"], farther.id: ["F"]])
        return (board, [sutphin.id, vanWyck.id, farther.id], airTrain)
    }

    func testListedAfterTheStationsWithTimesInTheirRange() throws {
        let (board, ids, airTrain) = try jamaicaBoard()
        // Nearer than the subway, but after it in the primary range, and before the extended range
        XCTAssertEqual(board.stations.map { $0.stations.map(\.id) }, [[ids[0]], [ids[1]], [airTrain.id], [ids[2]]])
        XCTAssertEqual(board.stations.map(\.range), [.primary, .primary, .primary, .extended])
        let row = try XCTUnwrap(board.station(id: airTrain.id))
        XCTAssertEqual(row.noTimes, airTrain)
        XCTAssertEqual(row.name, "Jamaica")
        XCTAssertEqual(row.stations.map(\.id), [airTrain.id], "not grouped with the subway station next to it")
        XCTAssertTrue(row.routes.isEmpty)
        XCTAssertTrue(row.north.trains.isEmpty && row.south.trains.isEmpty)
        XCTAssertEqual(row.walk.walkSeconds, 3 * 60)
        XCTAssertNil(board.stations[0].noTimes)
    }

    /// The menu bar panel and the widgets show departures only: a station without times selected in the main window shows the
    /// nearest one with times there, and the arrows move among the ones with times
    func testMenuBarAndWidgetsSkipThem() throws {
        let (board, _, airTrain) = try jamaicaBoard()
        let rows = board.stations.map(\.id)
        XCTAssertEqual(rows.count, 4)
        let timed = board.withoutNoTimesStations()
        XCTAssertEqual(timed.stations.map(\.id), [rows[0], rows[1], rows[3]])
        XCTAssertEqual(timed.generatedAt, board.generatedAt)
        let selected = BoardSelection(stationID: airTrain.id)
        XCTAssertEqual(selected.station(in: board)?.id, airTrain.id, "the main window shows it")
        XCTAssertEqual(selected.station(in: timed)?.id, rows[0])
        XCTAssertEqual(selected.moving(by: 1, in: timed, limit: timed.stations.count).stationID, rows[1])
        XCTAssertEqual(selected.moving(by: -1, in: timed, limit: timed.stations.count).stationID, rows[3])
        // Only stations without times nearby: nothing for the menu bar and the widgets
        let alone = NearbyBoardBuilder.build(stations: [airTrain.station],
                                             walks: [airTrain.id: WalkEstimate(walkSeconds: 180, straightLineMeters: 200, source: .route)],
                                             arrivals: [], settings: .default, now: now)
        XCTAssertEqual(alone.stations.count, 1)
        XCTAssertTrue(alone.withoutNoTimesStations().stations.isEmpty)
        XCTAssertNil(selected.station(in: alone.withoutNoTimesStations()))
    }
}


/// The palette's own colors are readable in both looks, and the ones shown together stay apart with color blindness
/// (the palette is in Shared/UIText.swift and uses PaletteHex)
final class PaletteTests: XCTestCase {
    let white: UInt32 = 0xFFFFFF
    let dark = PaletteHex.DarkSystem.windowBackground

    /// Text needs 4.5:1, icons and lines 3:1 (WCAG 2)
    func testColorsAreReadableInBothLooks() {
        // Text
        for c in [PaletteHex.noticeOrangeLight, PaletteHex.noticeRedLight, PaletteHex.noticeGreenLight, PaletteHex.metroNameLight] {
            XCTAssertGreaterThanOrEqual(ColorVision.contrast(c, white), 4.5, String(c, radix: 16))
        }
        XCTAssertGreaterThanOrEqual(ColorVision.contrast(PaletteHex.DarkSystem.purple, dark), 4.5, "metro names in dark mode")
        // Icons: the favorite star, the place pin, the in-range check
        for c in [PaletteHex.favoriteStarLight, PaletteHex.noticeRedLight, PaletteHex.noticeGreenLight, PaletteHex.walkRangeLight] {
            XCTAssertGreaterThanOrEqual(ColorVision.contrast(c, white), 3, String(c, radix: 16))
        }
        for c in [PaletteHex.DarkSystem.yellow, PaletteHex.DarkSystem.red, PaletteHex.DarkSystem.green, PaletteHex.DarkSystem.mint] {
            XCTAssertGreaterThanOrEqual(ColorVision.contrast(c, dark), 3, String(c, radix: 16))
        }
        // Why the light-mode ones were replaced: the system colors aren't enough on white
        XCTAssertLessThan(ColorVision.contrast(0xFFCC00, white), 3, "system yellow star")
        XCTAssertLessThan(ColorVision.contrast(0x34C759, white), 3, "system green check")
        XCTAssertLessThan(ColorVision.contrast(0xAF52DE, white), 4.5, "system purple text")
    }

    /// Colors drawn on the same map must stay apart with every kind of color blindness (more than 20, like the bus tags)
    func testMapColorsStayApartWithColorBlindness() {
        let pairs: [(String, UInt32, UInt32)] = [
            ("place pin / walking range", PaletteHex.noticeRedLight, PaletteHex.walkRangeLight),
            ("metro name / walking range", PaletteHex.metroNameLight, PaletteHex.walkRangeLight),
            ("dark: place pin / walking range", PaletteHex.DarkSystem.red, PaletteHex.DarkSystem.mint),
            ("dark: metro name / walking range", PaletteHex.DarkSystem.purple, PaletteHex.DarkSystem.mint),
        ]
        for (name, a, b) in pairs {
            XCTAssertGreaterThan(ColorVision.worstDifference(a, b), 20, name)
        }
    }

    /// The simulation itself: the same color is no different, and red and green, far apart with normal vision, come close with
    /// red-green color blindness (the reason verdicts always have an icon and words besides their color)
    func testColorBlindnessSimulation() {
        XCTAssertEqual(ColorVision.difference(PaletteHex.noticeRedLight, PaletteHex.noticeRedLight, seenWith: .deutan), 0, accuracy: 1e-9)
        let red: UInt32 = 0xD03030, green: UInt32 = 0x509030
        XCTAssertGreaterThan(ColorVision.difference(red, green), 60)
        XCTAssertLessThan(ColorVision.difference(red, green, seenWith: .deutan), ColorVision.difference(red, green) / 2)
        XCTAssertEqual(ColorVision.contrast(white, 0x000000), 21, accuracy: 0.01)
    }
}
