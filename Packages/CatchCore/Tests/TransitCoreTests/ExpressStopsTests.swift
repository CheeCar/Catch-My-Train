import XCTest
@testable import TransitCore

final class ExpressStopsTests: XCTestCase {

    func testBundledData() throws {
        let e = try ExpressStops.loadBundled()
        // 61 St-Woodside toward Flushing: next stop Junction Blvd is express, 69 St is local
        XCTAssertTrue(e.skips(from: "712", direction: "N", to: "707"))
        XCTAssertFalse(e.skips(from: "712", direction: "N", to: "711"))
        // 96 St southbound: next stop 72 St is express (skips 86 St, 79 St)
        XCTAssertTrue(e.skips(from: "120", direction: "S", to: "123"))
    }

    func testExpressAndLocal() throws {
        let e = try ExpressStops.loadBundled()
        XCTAssertEqual(e.isExpress(rawRoute: "7", stationID: "712", code: "N", nextStations: ["711", "710"]), false)
        XCTAssertEqual(e.isExpress(rawRoute: "7X", stationID: "712", code: "N", nextStations: ["707"]), true)
        // 2 train southbound at Times Sq: next stop 34 St is the same as local, but the one after goes straight to 14 St, so it's express
        XCTAssertEqual(e.isExpress(rawRoute: "2", stationID: "127", code: "S", nextStations: ["128", "132"]), true)
        XCTAssertEqual(e.isExpress(rawRoute: "1", stationID: "127", code: "S", nextStations: ["128", "129", "130"]), false)
        // No info on later stops: unknown
        XCTAssertNil(e.isExpress(rawRoute: "1", stationID: "127", code: "S", nextStations: []))
        // Diamond express (official <7>)
        XCTAssertEqual(e.isExpress(rawRoute: "7X", stationID: "712", code: "S", nextStations: ["713"]), true)
    }

    func testMapperUsesNextStops() throws {
        let e = ExpressStops(skips: ["712N": ["707"]])
        func stop(_ id: String, _ t: Double) -> GTFSRealtimeFeed.StopTimeUpdate {
            .init(stopID: id, arrivalTime: Date(timeIntervalSince1970: t), departureTime: nil, isSkipped: false, hasNoData: false)
        }
        func trip(_ id: String, _ stops: [GTFSRealtimeFeed.StopTimeUpdate]) -> GTFSRealtimeFeed.TripUpdate {
            .init(entityID: id, tripID: id, routeID: "7", startDate: "", isCanceled: false, timestamp: nil, stopTimeUpdates: stops)
        }
        let feed = GTFSRealtimeFeed(timestamp: Date(timeIntervalSince1970: 1000), tripUpdates: [
            trip("t1", [stop("712N", 1100), stop("707N", 1400)]),
            trip("t2", [stop("712N", 1200), stop("711N", 1300)]),
            trip("t3", [stop("712N", 1250)]),
        ])
        let arrivals = GTFSRealtimeMapper.arrivals(from: feed, stationIDs: ["712"], fallbackUpdatedAt: Date(),
                                                   express: e) { _, _, code, _ in
            Direction(code: code, name: code)
        }
        XCTAssertEqual(arrivals.map(\.isExpress), [true, false, nil])
    }
}
