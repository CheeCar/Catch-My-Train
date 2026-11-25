import XCTest
@testable import TransitCore

/// Reference trip, an example with public places: walking from the Museum of Modern Art to Times Sq-42 St (the 7 line's platform,
/// GTFS station 725), about 1,080 m in a straight line. The walking route is taken as 1,180 m, an example length. A walk a little
/// over the 15-minute main range shows in the 20-minute extended one; under the old 8 / 12 minute ranges it never showed.
final class ReferenceTripTests: XCTestCase {

    let user = Coordinate(latitude: 40.7614, longitude: -73.9776)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func timesSquare() throws -> Station {
        try XCTUnwrap(StationCatalog.loadBundled().station(id: "725"))
    }

    func testStationIsACandidate() throws {
        let catalog = try StationCatalog.loadBundled()
        let radius = CatchSettings.default.extendedCandidateRadiusMeters + 100
        let near = catalog.stations(near: user, radiusMeters: radius)
        XCTAssertTrue(near.contains { $0.id == "725" && $0.name == "Times Sq-42 St" })
        XCTAssertEqual(WalkEstimator.distanceMeters(user, try timesSquare().coordinate), 1080, accuracy: 5)
    }

    func testEstimatedWalkIsInExtendedRange() throws {
        let walk = WalkEstimator.estimate(from: user, to: try timesSquare(), settings: .default)
        XCTAssertEqual(walk.source, .estimated)
        XCTAssertEqual(walk.walkSeconds / 60, 18.0, accuracy: 0.1)
        XCTAssertEqual(Recommender.classify(walk: walk, settings: .default), .extended)
        let legacy = CatchSettings(primaryWalkMinutes: 8, extendedWalkMinutes: 12, candidateRadiusMeters: 800)
        XCTAssertNil(Recommender.classify(walk: walk, settings: legacy), "This station doesn't show under the old default ranges")
    }

    func testWalkingRouteIsInExtendedRange() throws {
        // Walking route 1,180 m ÷ 1.25 m/s ≈ 15.7 minutes: a bit over the 15-minute main range, within the 20-minute extended range.
        let walk = WalkEstimator.estimate(from: user, to: try timesSquare(), settings: .default, routeMeters: 1180)
        XCTAssertEqual(walk.source, .route)
        XCTAssertEqual(walk.walkSeconds / 60, 15.7, accuracy: 0.05)
        XCTAssertEqual(Recommender.classify(walk: walk, settings: .default), .extended)
        // With the main range set to 16 minutes, it counts as main range.
        var sixteen = CatchSettings.default
        sixteen.primaryWalkMinutes = 16
        XCTAssertEqual(Recommender.classify(walk: walk, settings: sixteen), .primary)
    }

    func testTrainsAreRecommended() throws {
        let station = try timesSquare()
        let catalog = try StationCatalog.loadBundled()
        let dir = catalog.direction(stationID: "725", route: "7", code: "N")
        func arrival(_ minutes: Double, _ k: Int) -> Arrival {
            Arrival(id: "7-\(k)", stationID: "725", route: "7", direction: dir,
                    arrivalTime: now.addingTimeInterval(minutes * 60), source: .realtime, updatedAt: now)
        }
        let walk = WalkEstimator.estimate(from: user, to: station, settings: .default, routeMeters: 1180)
        let board = NearbyBoardBuilder.build(stations: [station], walks: ["725": walk],
                                             arrivals: [arrival(10, 0), arrival(20, 1)],
                                             settings: .default, now: now)
        XCTAssertEqual(board.stations.count, 1)
        let top = try XCTUnwrap(board.stations.first)
        XCTAssertEqual(top.stations.map(\.id), ["725"])
        XCTAssertEqual(top.range, .extended)
        XCTAssertTrue(board.usedExtendedRange, "No main-range stations nearby, so the extended-range Times Sq-42 St still shows")
        let first = try XCTUnwrap(top.north.trains.first)
        XCTAssertEqual(first.direction.terminal, "Flushing-Main St")
        // The trip in 10 minutes: 15.7 min walk + 1.5 min to enter, can't make it → recommend the trip in 20 minutes (2.8 minutes to spare).
        XCTAssertEqual(first.verdict, .takeNext)
        XCTAssertEqual(first.recommended?.arrival.id, "7-1")
        XCTAssertEqual(first.recommended?.verdict, .canTry)
        XCTAssertEqual(top.north.firstCatchable?.id, "7-1")
    }
}
