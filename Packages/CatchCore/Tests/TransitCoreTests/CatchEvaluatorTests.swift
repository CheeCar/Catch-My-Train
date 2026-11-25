import XCTest
@testable import TransitCore

/// Boundary tests for the catch evaluation.
/// Convention: slack = train arrival time − expected time at the platform (positive = I get there first).
final class CatchEvaluatorTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = CatchSettings.default // buffer 2 minutes = 120 seconds
    let dir = Direction(code: "N", name: "Uptown")

    /// Uses a real route (.route) to rule out estimate uncertainty and test only the core boundaries.
    func walk(_ seconds: TimeInterval, source: WalkSource = .route) -> WalkEstimate {
        WalkEstimate(walkSeconds: seconds, straightLineMeters: 300, source: source)
    }

    func arrival(inSeconds: TimeInterval?, source: ArrivalSource = .realtime, updatedAgo: TimeInterval = 10, status: TripStatus = .normal) -> Arrival {
        Arrival(id: "a", stationID: "S", route: "L", direction: dir,
                arrivalTime: inSeconds.map { now.addingTimeInterval($0) },
                source: source, status: status, updatedAt: now.addingTimeInterval(-updatedAgo))
    }

    func evaluate(_ a: Arrival, walk w: WalkEstimate, entry: TimeInterval = 60) -> CatchEvaluation {
        CatchEvaluator.evaluate(arrival: a, walk: w, entranceToPlatformSeconds: entry, settings: settings, now: now, clockOffset: 0)
    }

    /// The clock offset is an input: a measured offset elsewhere in the process doesn't change a result computed with 0
    func testClockOffsetIsAParameter() {
        defer { ClockSkew.set(0) }
        let a = arrival(inSeconds: 600)
        let plain = evaluate(a, walk: walk(300))
        ClockSkew.set(600)
        let withZero = evaluate(a, walk: walk(300))
        XCTAssertEqual(withZero.slackSeconds, plain.slackSeconds)
        XCTAssertEqual(withZero.verdict, plain.verdict)
        let shifted = CatchEvaluator.evaluate(arrival: a, walk: walk(300), entranceToPlatformSeconds: 60, settings: settings,
                                              now: now, clockOffset: 120)
        XCTAssertEqual(shifted.slackSeconds, plain.slackSeconds.map { $0 - 120 })
        let board = NearbyBoardBuilder.build(stations: [Station(id: "S", name: "S", coordinate: Coordinate(latitude: 0, longitude: 0),
                                                                entranceToPlatformSeconds: 60)],
                                             walks: ["S": walk(300)], arrivals: [a], settings: settings, now: now, clockOffset: 0)
        XCTAssertEqual(board.stations.first?.north.trains.first?.evaluation.slackSeconds, plain.slackSeconds)
    }

    // Walk 300 s + entry 60 s = at the platform after 360 s.

    func testPlatformArrivalFormula() {
        let e = evaluate(arrival(inSeconds: 600), walk: walk(300))
        XCTAssertEqual(e.platformArrivalTime, now.addingTimeInterval(360))
        XCTAssertEqual(e.slackSeconds, 240)
        XCTAssertEqual(e.totalAccessSeconds, 360)
    }

    func testSlackSignIsPositiveWhenEarly() {
        let e = evaluate(arrival(inSeconds: 600), walk: walk(300))
        XCTAssertGreaterThan(e.slackSeconds!, 0)
        XCTAssertEqual(e.verdict, .canTry)
    }

    func testExactlyBufferIsCanTry() {
        // slack = 480 − 360 = 120 = buffer → can try (boundary inclusive)
        let e = evaluate(arrival(inSeconds: 480), walk: walk(300))
        XCTAssertEqual(e.slackSeconds, 120)
        XCTAssertEqual(e.verdict, .canTry)
    }

    func testOneSecondUnderBufferIsTight() {
        let e = evaluate(arrival(inSeconds: 479), walk: walk(300))
        XCTAssertEqual(e.slackSeconds, 119)
        XCTAssertEqual(e.verdict, .tight)
    }

    func testZeroSlackIsTight() {
        let e = evaluate(arrival(inSeconds: 360), walk: walk(300))
        XCTAssertEqual(e.slackSeconds, 0)
        XCTAssertEqual(e.verdict, .tight)
    }

    func testNegativeSlackIsTakeNext() {
        let e = evaluate(arrival(inSeconds: 359), walk: walk(300))
        XCTAssertEqual(e.slackSeconds, -1)
        XCTAssertEqual(e.verdict, .takeNext)
    }

    func testTrainArrivingSoonButFarAwayIsTakeNext() {
        // The train arrives in 3 minutes but I need 10 minutes to walk: can't just look at "minutes until arrival".
        let e = evaluate(arrival(inSeconds: 180), walk: walk(600))
        XCTAssertEqual(e.verdict, .takeNext)
    }

    func testEntranceTimeMatters() {
        // Train arrives in 450 s, walk is 300 s. Without entry time: slack 150 s → can try;
        // 2-minute entry: slack 30 s → tight; 3-minute entry: slack −30 s → too late.
        let withoutEntry = evaluate(arrival(inSeconds: 450), walk: walk(300), entry: 0)
        let twoMinEntry = evaluate(arrival(inSeconds: 450), walk: walk(300), entry: 120)
        let threeMinEntry = evaluate(arrival(inSeconds: 450), walk: walk(300), entry: 180)
        XCTAssertEqual(withoutEntry.verdict, .canTry)
        XCTAssertEqual(twoMinEntry.verdict, .tight)
        XCTAssertEqual(threeMinEntry.verdict, .takeNext)
    }

    func testMissingPredictionIsInsufficientInfo() {
        let e = evaluate(arrival(inSeconds: nil), walk: walk(300))
        XCTAssertEqual(e.verdict, .insufficientInfo)
        XCTAssertTrue(e.notes.contains(.missingPrediction))
        XCTAssertNil(e.slackSeconds)
        XCTAssertEqual(e.confidence, .low)
    }

    func testStaleRealtimeIsInsufficientInfo() {
        let fresh = evaluate(arrival(inSeconds: 900, updatedAgo: 180), walk: walk(300))
        let stale = evaluate(arrival(inSeconds: 900, updatedAgo: 181), walk: walk(300))
        XCTAssertEqual(fresh.verdict, .canTry)
        XCTAssertEqual(stale.verdict, .insufficientInfo)
        XCTAssertTrue(stale.notes.contains(.staleRealtime))
    }

    /// Leaving later than the data was read (Plan a Trip): freshness is judged when the data was read, not at departure
    func testLaterDepartureJudgesFreshnessWhenDataWasRead() {
        func evaluate(_ a: Arrival, leavingIn later: TimeInterval, observedAt: Date?) -> CatchEvaluation {
            CatchEvaluator.evaluate(arrival: a, walk: walk(300), entranceToPlatformSeconds: 60, settings: settings,
                                    now: now.addingTimeInterval(later), clockOffset: 0, observedAt: observedAt)
        }
        let fresh = arrival(inSeconds: 3600, updatedAgo: 30)
        for later in [120.0, 600, 1740] {
            let e = evaluate(fresh, leavingIn: later, observedAt: now)
            XCTAssertFalse(e.notes.contains(.staleRealtime), "leaving \(later) s later")
            XCTAssertEqual(e.verdict, .canTry, "leaving \(later) s later")
            XCTAssertEqual(e.slackSeconds, 3600 - later - 360)
        }
        // Data that was already old when read is still stale
        XCTAssertTrue(evaluate(arrival(inSeconds: 3600, updatedAgo: 400), leavingIn: 600, observedAt: now).notes.contains(.staleRealtime))
        // Without observedAt the departure time is also the reading time (the widget's future timeline entries)
        XCTAssertTrue(evaluate(fresh, leavingIn: 600, observedAt: nil).notes.contains(.staleRealtime))

        let station = Station(id: "S", name: "S", coordinate: Coordinate(latitude: 0, longitude: 0), entranceToPlatformSeconds: 60)
        func board(observedAt: Date?) -> [BoardTrain] {
            NearbyBoardBuilder.build(stations: [station], walks: ["S": walk(300)], arrivals: [fresh], settings: settings,
                                     now: now.addingTimeInterval(600), clockOffset: 0, observedAt: observedAt)
                .stations.flatMap { $0.north.trains }
        }
        XCTAssertEqual(board(observedAt: now).map(\.evaluation.verdict), [.canTry])
        XCTAssertEqual(board(observedAt: nil).map(\.evaluation.verdict), [.insufficientInfo])
    }

    func testScheduledOnlyAddsUncertaintyAndIsLabelled() {
        // With realtime data slack=150 ≥ 120 can try; the scheduled timetable requires 120+60=180, so it only counts as tight.
        let rt = evaluate(arrival(inSeconds: 510), walk: walk(300))
        let sch = evaluate(arrival(inSeconds: 510, source: .scheduled, updatedAgo: 99_999), walk: walk(300))
        XCTAssertEqual(rt.verdict, .canTry)
        XCTAssertEqual(sch.verdict, .tight)
        XCTAssertTrue(sch.notes.contains(.scheduledOnly))
        XCTAssertEqual(sch.confidence, .medium)
        XCTAssertFalse(sch.notes.contains(.staleRealtime), "A scheduled timetable should not be flagged as stale realtime")
    }

    func testEstimatedWalkAddsUncertainty() {
        // Estimated walk 300 s → extra 45 s required, 165 s total.
        let e1 = evaluate(arrival(inSeconds: 525), walk: walk(300, source: .estimated))
        let e2 = evaluate(arrival(inSeconds: 524), walk: walk(300, source: .estimated))
        XCTAssertEqual(e1.requiredSlackSeconds, 165, accuracy: 0.001)
        XCTAssertEqual(e1.verdict, .canTry)
        XCTAssertEqual(e2.verdict, .tight)
        XCTAssertTrue(e1.notes.contains(.walkEstimated))
    }

    func testBoardingTimeIsLaterOfTrainAndMe() {
        let early = evaluate(arrival(inSeconds: 600), walk: walk(300))
        XCTAssertEqual(early.boardingTime, now.addingTimeInterval(600))
        let late = evaluate(arrival(inSeconds: 100), walk: walk(300))
        XCTAssertEqual(late.boardingTime, now.addingTimeInterval(360))
    }

    func testCustomBuffer() {
        var s = settings
        s.safetyBufferMinutes = 0
        let e = CatchEvaluator.evaluate(arrival: arrival(inSeconds: 360), walk: walk(300), entranceToPlatformSeconds: 60, settings: s, now: now)
        XCTAssertEqual(e.verdict, .canTry)
    }

    /// A trip has one time: the one shown is the one whether it can be caught goes by. A second time (a departure, a boarding
    /// limit) would let the two differ, as a later departure did at Times Sq, where "Leave by" came after the train
    func testATripHasOneTime() {
        let a = arrival(inSeconds: 300)
        let times = Mirror(reflecting: a).children
            .filter { type(of: $0.value) == Date.self || type(of: $0.value) == Date?.self }.compactMap(\.label)
        XCTAssertEqual(Set(times), ["arrivalTime", "updatedAt"], "updatedAt is when the data was made, not a time of the trip")
        let e = evaluate(a, walk: walk(240))   // at the platform after 300 s
        XCTAssertEqual(e.slackSeconds, 0)
        XCTAssertEqual(e.secondsUntilTrain ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(e.verdict, .tight)
    }

    /// "Leave by": how much later you could set off and still have "can try", only for "can try", rounded down to the minute;
    /// setting off then is still "can try", a second later isn't
    func testLatestLeaveKeepsCanTry() throws {
        // A timetable time 26 min away, a 15 min walk + 1 min to the platform: 10 min of slack, 3 needed (2 + 1 for the timetable)
        let a = arrival(inSeconds: 1560, source: .scheduled)
        let e = evaluate(a, walk: walk(900))
        XCTAssertEqual(e.verdict, .canTry)
        XCTAssertEqual(e.leewaySeconds, 420)
        XCTAssertEqual(e.latestLeave, now.addingTimeInterval(420))
        func verdict(leaving leave: Date) -> CatchVerdict {
            CatchEvaluator.evaluate(arrival: a, walk: walk(900), entranceToPlatformSeconds: 60, settings: settings, now: leave,
                                    clockOffset: 0).verdict
        }
        XCTAssertEqual(verdict(leaving: try XCTUnwrap(e.latestLeave)), .canTry)
        XCTAssertEqual(verdict(leaving: now.addingTimeInterval(421)), .tight)
        // Half a minute more slack: still the same minute
        XCTAssertEqual(evaluate(arrival(inSeconds: 1590, source: .scheduled), walk: walk(900)).latestLeave, now.addingTimeInterval(420))
        // Exactly the slack needed: leave now
        XCTAssertEqual(evaluate(arrival(inSeconds: 1140, source: .scheduled), walk: walk(900)).latestLeave, now)
        // Only for "can try"
        let tight = evaluate(arrival(inSeconds: 1139, source: .scheduled), walk: walk(900))
        XCTAssertEqual(tight.verdict, .tight)
        XCTAssertNil(tight.leewaySeconds)
        XCTAssertNil(tight.latestLeave)
        XCTAssertNil(evaluate(arrival(inSeconds: 600), walk: walk(900)).latestLeave)
        XCTAssertNil(evaluate(arrival(inSeconds: nil), walk: walk(900)).latestLeave)
        // A live time needs 2 min, not 3
        XCTAssertEqual(evaluate(arrival(inSeconds: 1560), walk: walk(900)).latestLeave, now.addingTimeInterval(480))
    }

    /// In the realtime data but no train assigned yet: judged like a timetable time, and it still goes stale
    func testUnassignedTripIsJudgedLikeTheTimetable() {
        var a = arrival(inSeconds: 510)
        a.isAssigned = false
        let e = evaluate(a, walk: walk(300))
        XCTAssertEqual(e.verdict, .tight, "Slack 150 s is less than 120 + 60 s")
        XCTAssertTrue(e.notes.contains(.scheduledOnly))
        XCTAssertEqual(e.confidence, .medium)
        XCTAssertTrue(a.isTimetableTime)
        var old = a
        old.updatedAt = now.addingTimeInterval(-99_999)
        XCTAssertTrue(evaluate(old, walk: walk(300)).notes.contains(.staleRealtime))
        var assigned = arrival(inSeconds: 510)
        assigned.isAssigned = true
        XCTAssertEqual(evaluate(assigned, walk: walk(300)).verdict, .canTry)
        XCTAssertFalse(assigned.isTimetableTime)
        XCTAssertTrue(arrival(inSeconds: 510, source: .scheduled).isTimetableTime)
    }
}
