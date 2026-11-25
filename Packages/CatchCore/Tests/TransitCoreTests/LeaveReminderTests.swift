import XCTest
@testable import TransitCore

/// Leave-by reminders: when one can be set, and what happens to it when the train's time changes.
/// Walk 300 s + entry 60 s = 360 s to the platform; buffer 120 s. So for a realtime train at T the latest time to set off is
/// T − 480 s, and with the default lead (2 minutes) the notification comes at T − 600 s.
final class LeaveReminderTests: XCTestCase {

    /// A whole minute, so the rounding to the minute is easy to follow
    let now = Date(timeIntervalSinceReferenceDate: 800_000_040)
    let settings = CatchSettings.default
    let dir = Direction(code: "N", name: "Uptown")
    let stale: TimeInterval = 180

    /// A train `seconds` after `now`. Its data was updated `updatedAgo` before `seen` (seconds after `now`): a check made later
    /// than `now` passes when it looks, so the data is as fresh as it would be then
    func train(_ id: String = "a", in seconds: TimeInterval?, source: ArrivalSource = .realtime, seen: TimeInterval = 0,
               updatedAgo: TimeInterval = 10, status: TripStatus = .normal, station: String = "S", route: String = "L",
               code: String = "N", assigned: Bool? = nil) -> Arrival {
        Arrival(id: id, stationID: station, route: route, direction: Direction(code: code, name: "Uptown"),
                arrivalTime: seconds.map { now.addingTimeInterval($0) }, source: source, status: status,
                updatedAt: now.addingTimeInterval(seen - updatedAgo), isAssigned: assigned)
    }

    func evaluation(_ a: Arrival, walk: TimeInterval = 300, walkSource: WalkSource = .route,
                    offset: TimeInterval = 0) -> CatchEvaluation {
        CatchEvaluator.evaluate(arrival: a, walk: WalkEstimate(walkSeconds: walk, straightLineMeters: 300, source: walkSource),
                                entranceToPlatformSeconds: 60, settings: settings, now: now, clockOffset: offset)
    }

    func make(_ a: Arrival, lead: Int = 2, existing: [LeaveReminder] = [], offset: TimeInterval = 0,
              walkSource: WalkSource = .route) -> Result<LeaveReminder, LeaveReminders.Refusal> {
        LeaveReminders.make(from: evaluation(a, walkSource: walkSource, offset: offset), stationName: "Bedford Av",
                            routeName: "L", leadMinutes: lead, existing: existing, now: now, clockOffset: offset)
    }

    /// A reminder on a realtime train 1,200 s from now: leave by now + 720 s, notification at now + 600 s
    func reminder(lead: Int = 2) throws -> LeaveReminder {
        try make(train(in: 1200), lead: lead).get()
    }

    func check(_ r: LeaveReminder, _ arrivals: [Arrival], lead: Int = 2, after seconds: TimeInterval = 30,
               offset: TimeInterval = 0) -> LeaveReminders.Change {
        LeaveReminders.reconcile(r, arrivals: arrivals, leadMinutes: lead, staleAfter: stale,
                                 now: now.addingTimeInterval(seconds), clockOffset: offset)
    }

    // MARK: Setting one

    func testTimesOfANewReminder() throws {
        let a = train(in: 1200)
        let r = try make(a).get()
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(720))
        XCTAssertEqual(r.leaveBy, evaluation(a).latestLeave)
        XCTAssertEqual(r.fireAt, now.addingTimeInterval(600))
        XCTAssertEqual(r.leadSeconds, 120)
        XCTAssertEqual(r.trainTime, a.arrivalTime)
        XCTAssertEqual(r.accessSeconds, 360)
        XCTAssertEqual(r.baseSlackSeconds, 120)
        XCTAssertEqual(r.checkedAt, now)
        XCTAssertEqual(r.id, "a")
        XCTAssertEqual(r.stationName, "Bedford Av")
        XCTAssertNil(r.followingID)
    }

    /// Whatever the train, the walk and the kind of data: "leave by" is the evaluation's own
    func testLeaveByIsTheEvaluationsLatestLeave() throws {
        for seconds in stride(from: 700.0, through: 4000, by: 137) {
            for source in [ArrivalSource.realtime, .scheduled] {
                for walkSource in [WalkSource.route, .estimated] {
                    for assigned in [nil, false] as [Bool?] {
                        let a = train(in: seconds, source: source, assigned: assigned)
                        let e = evaluation(a, walkSource: walkSource)
                        guard case .success(let r) = make(a, lead: 1, walkSource: walkSource) else { continue }
                        XCTAssertEqual(r.leaveBy, e.latestLeave, "\(seconds) \(source) \(walkSource)")
                        // Checked right away against the same train, nothing moves
                        let change = check(r, [a], lead: 1, after: 0)
                        XCTAssertEqual(change, .keep, "\(seconds) \(source) \(walkSource)")
                    }
                }
            }
        }
    }

    func testLeaveByIsRoundedDownToTheMinute() throws {
        // Latest time to set off = now + 759 s: shown as now + 720 s
        let r = try make(train(in: 1239)).get()
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(720))
        XCTAssertEqual(r.fireAt, now.addingTimeInterval(600))
    }

    /// A pending reminder set by an older version, which also wrote a second time ("boardBy"), still reads: that part is left out
    func testAnOlderVersionsReminderStillReads() throws {
        let r = try reminder()
        let text = try XCTUnwrap(r.encoded)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        object["boardBy"] = object["trainTime"]
        let older = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        XCTAssertEqual(LeaveReminder(encoded: older), r)
    }

    func testOnlyCanTryTrainsCanHaveOne() {
        // 360 s to the platform, train in 420 s: slack 60 s, under the buffer
        XCTAssertEqual(evaluation(train(in: 420)).verdict, .tight)
        XCTAssertThrowsError(try make(train(in: 420)).get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .notCanTry) }
        XCTAssertThrowsError(try make(train(in: 100)).get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .notCanTry) }
        XCTAssertThrowsError(try make(train(in: nil)).get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .notCanTry) }
        // Stale realtime data: "Not sure"
        XCTAssertThrowsError(try make(train(in: 1200, updatedAgo: 400)).get()) {
            XCTAssertEqual($0 as? LeaveReminders.Refusal, .notCanTry)
        }
    }

    func testDemoTrainsCantHaveOne() {
        XCTAssertThrowsError(try make(train(in: 1200, source: .mock)).get()) {
            XCTAssertEqual($0 as? LeaveReminders.Refusal, .demo)
        }
    }

    func testLessThanTheLeadLeftSaysLeaveNow() throws {
        // Leave by now + 120 s: with a lead of 2 minutes the notification would be for this very moment
        XCTAssertThrowsError(try make(train(in: 600)).get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .leaveNow) }
        XCTAssertThrowsError(try make(train(in: 540)).get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .leaveNow) }
        XCTAssertEqual(try make(train(in: 660)).get().fireAt, now.addingTimeInterval(60))
        // With a lead of 1 minute it can be set
        XCTAssertEqual(try make(train(in: 600), lead: 1).get().fireAt, now.addingTimeInterval(60))
        // Lead 30 minutes: a train 38 minutes away is too near (leave by in 30 minutes), one 45 minutes away isn't
        XCTAssertThrowsError(try make(train(in: 2280), lead: 30).get()) {
            XCTAssertEqual($0 as? LeaveReminders.Refusal, .leaveNow)
        }
        XCTAssertEqual(try make(train(in: 2700), lead: 30).get().fireAt, now.addingTimeInterval(420))
    }

    func testTheVerdictMayBeOutOfDateByTheTimeItIsSet() {
        // Worked out at `now` as "Can try" with 60 s to spare; set 90 s later
        let e = evaluation(train(in: 540))
        XCTAssertEqual(e.verdict, .canTry)
        let late = LeaveReminders.make(from: e, stationName: "", routeName: "", leadMinutes: 1, existing: [],
                                       now: now.addingTimeInterval(90), clockOffset: 0)
        XCTAssertThrowsError(try late.get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .leaveNow) }
    }

    func testRemindAtIsTheLeadBeforeLeaveBy() throws {
        let r = try reminder(lead: 5)
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(720))
        XCTAssertEqual(r.remindAt, now.addingTimeInterval(420))
        // In the trains' time, whatever this Mac's clock says
        let skewed = try make(train(in: 1200 + 120), lead: 5, offset: 120).get()
        XCTAssertEqual(skewed.remindAt, now.addingTimeInterval(120 + 420))
        XCTAssertEqual(skewed.fireAt, now.addingTimeInterval(420))
    }

    func testStationTimeZone() throws {
        var r = try reminder()
        XCTAssertNil(r.stationTimeZone)
        r.timeZone = "America/Chicago"
        XCTAssertEqual(r.stationTimeZone?.identifier, "America/Chicago")
        r.timeZone = "not a zone"
        XCTAssertNil(r.stationTimeZone)
    }

    // MARK: What the details offer

    func offer(_ a: Arrival, lead: Int = 2, existing: [LeaveReminder] = []) -> LeaveReminders.Offer {
        LeaveReminders.offer(for: evaluation(a), stationName: "Bedford Av", routeName: "L", leadMinutes: lead,
                             existing: existing, now: now, clockOffset: 0)
    }

    func testOfferOfATrainThatCanHaveOne() throws {
        let made = try make(train(in: 1200)).get()
        XCTAssertEqual(offer(train(in: 1200)), .canSet(made))
        // Another train's reminder doesn't change that
        let other = try make(train("b", in: 1500)).get()
        XCTAssertEqual(offer(train(in: 1200), existing: [other]), .canSet(made))
    }

    func testOfferOfATrainThatHasOne() throws {
        let mine = try reminder(lead: 5)
        let other = try make(train("b", in: 1500)).get()
        // Its own reminder as it is, also when the lead changed since or the train couldn't have a new one any more
        XCTAssertEqual(offer(train(in: 1200), existing: [other, mine]), .isSet(mine))
        XCTAssertEqual(offer(train(in: 420), existing: [mine]), .isSet(mine))
        XCTAssertEqual(offer(train(in: 1200, source: .mock), existing: [mine]), .isSet(mine))
    }

    func testOfferSaysWhyNot() throws {
        XCTAssertEqual(offer(train(in: 420)), .refused(.notCanTry))
        XCTAssertEqual(offer(train(in: 600)), .refused(.leaveNow))
        XCTAssertEqual(offer(train(in: 1200, source: .mock)), .refused(.demo))
        let ten = try (0..<10).map { try make(train("t\($0)", in: 1200)).get() }
        XCTAssertEqual(offer(train(in: 1200), existing: ten), .refused(.full))
    }

    /// While Apple Maps is still asked for the walking route to its station, a train can't have one yet: the straight line's
    /// walk may be shorter, and a reminder keeps the walk it was set with. Why else it can't comes first
    func testNoneWhileTheWalkingRouteIsComing() throws {
        let coming = LeaveReminders.make(from: evaluation(train(in: 1200), walkSource: .estimated), stationName: "Bedford Av",
                                         routeName: "L", leadMinutes: 2, existing: [], now: now, clockOffset: 0, walkComing: true)
        XCTAssertThrowsError(try coming.get()) { XCTAssertEqual($0 as? LeaveReminders.Refusal, .walkComing) }
        XCTAssertEqual(LeaveReminders.offer(for: evaluation(train(in: 1200), walkSource: .estimated), stationName: "Bedford Av",
                                            routeName: "L", leadMinutes: 2, existing: [], now: now, clockOffset: 0, walkComing: true),
                       .refused(.walkComing))
        for (a, why) in [(train(in: 420), LeaveReminders.Refusal.notCanTry), (train(in: 600), .leaveNow),
                         (train(in: 1200, source: .mock), .demo)] {
            XCTAssertEqual(LeaveReminders.offer(for: evaluation(a, walkSource: .estimated), stationName: "Bedford Av", routeName: "L",
                                                leadMinutes: 2, existing: [], now: now, clockOffset: 0, walkComing: true), .refused(why))
        }
        // Its own reminder stays shown; once the route came (or can't), it can have one
        let mine = try reminder()
        XCTAssertEqual(LeaveReminders.offer(for: evaluation(train(in: 1200)), stationName: "Bedford Av", routeName: "L",
                                            leadMinutes: 2, existing: [mine], now: now, clockOffset: 0, walkComing: true), .isSet(mine))
        XCTAssertNoThrow(try make(train(in: 1200), walkSource: .estimated).get())
    }

    func testOnePerTrainAndTenAtMost() throws {
        let first = try reminder()
        XCTAssertThrowsError(try make(train(in: 1200), existing: [first]).get()) {
            XCTAssertEqual($0 as? LeaveReminders.Refusal, .alreadySet)
        }
        let nine = try (0..<9).map { try make(train("t\($0)", in: 1200)).get() }
        XCTAssertNoThrow(try make(train(in: 1200), existing: nine).get())
        let ten = nine + [try make(train("t9", in: 1200)).get()]
        XCTAssertEqual(ten.count, LeaveReminders.maxCount)
        XCTAssertThrowsError(try make(train(in: 1200), existing: ten).get()) {
            XCTAssertEqual($0 as? LeaveReminders.Refusal, .full)
        }
    }

    func testLeadStaysInItsRange() {
        XCTAssertEqual(LeaveReminders.leadMinutes(nil), 2)
        XCTAssertEqual(LeaveReminders.leadMinutes(0), 1)
        XCTAssertEqual(LeaveReminders.leadMinutes(-5), 1)
        XCTAssertEqual(LeaveReminders.leadMinutes(7), 7)
        XCTAssertEqual(LeaveReminders.leadMinutes(31), 30)
        // A lead out of range is brought into it when setting too
        XCTAssertEqual(try make(train(in: 3600), lead: 99).get().leadSeconds, 1800)
    }

    func testClockOffsetMovesOnlyTheFireTime() throws {
        // This Mac's clock is 120 s behind the servers': the train times are the servers'
        let a = train(in: 1200 + 120)
        let r = try make(a, offset: 120).get()
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(120 + 720))
        XCTAssertEqual(r.leaveBy, evaluation(a, offset: 120).latestLeave)
        // On this Mac's clock that is 600 s from now, as without an offset
        XCTAssertEqual(r.fireAt, now.addingTimeInterval(600))
        XCTAssertEqual(r.checkedAt, now.addingTimeInterval(120))
    }

    func testWritesAndReadsBack() throws {
        var r = try reminder()
        r.followingID = "b"
        r.timeZone = "America/New_York"
        let text = try XCTUnwrap(r.encoded)
        XCTAssertEqual(LeaveReminder(encoded: text), r)
        XCTAssertNil(LeaveReminder(encoded: ""))
        XCTAssertNil(LeaveReminder(encoded: "{\"id\":\"a\"}"))
        XCTAssertNil(LeaveReminder(encoded: "not a reminder"))
    }

    // MARK: After a refresh

    func testNothingChangedKeeps() throws {
        let r = try reminder()
        XCTAssertEqual(check(r, [train(in: 1200)]), .keep)
    }

    /// Realtime times move by a few seconds with every refresh: the pending notification isn't replaced for that
    func testSecondsOfJitterKeep() throws {
        let r = try reminder()
        for jitter in [1.0, 20, 59] {
            XCTAssertEqual(check(r, [train(in: 1200 + jitter)]), .keep, "\(jitter)")
        }
    }

    func testFollowingTrainIsRemembered() throws {
        let r = try reminder()
        let list = [train(in: 1200), train("c", in: 2400), train("b", in: 1800), train("z", in: 600),
                    train("other", in: 1500, route: "G"), train("south", in: 1500, code: "S"),
                    train("elsewhere", in: 1500, station: "T"), train("x", in: 1300, status: .cancelled)]
        guard case .reschedule(let next) = check(r, list) else { return XCTFail("\(check(r, list))") }
        XCTAssertEqual(next.followingID, "b")
        XCTAssertEqual(next.fireAt, r.fireAt)
        XCTAssertEqual(next.leaveBy, r.leaveBy)
        XCTAssertEqual(check(next, list, after: 60), .keep)
        // Much later the same list is stale: nothing is known, and the reminder stays
        XCTAssertEqual(check(next, list, after: 400), .keep)
    }

    func testCheckedAtIsBroughtUpToDateEveryTwoMinutes() throws {
        let r = try reminder()
        XCTAssertEqual(check(r, [train(in: 1200, seen: 119)], after: 119), .keep)
        guard case .reschedule(let next) = check(r, [train(in: 1200, seen: 120)], after: 120) else { return XCTFail() }
        XCTAssertEqual(next.checkedAt, now.addingTimeInterval(120))
        XCTAssertEqual(next.fireAt, r.fireAt)
        XCTAssertEqual(next.leaveBy, r.leaveBy)
        XCTAssertEqual(next.trainTime, r.trainTime)
    }

    func testLaterTrainMovesTheReminderLater() throws {
        let r = try reminder()
        guard case .reschedule(let next) = check(r, [train(in: 1500)]) else { return XCTFail() }
        XCTAssertEqual(next.trainTime, now.addingTimeInterval(1500))
        XCTAssertEqual(next.leaveBy, now.addingTimeInterval(1020))
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(900))
        XCTAssertEqual(next.checkedAt, now.addingTimeInterval(30))
    }

    func testEarlierTrainWithTimeLeftMovesTheReminderEarlier() throws {
        let r = try reminder()
        guard case .reschedule(let next) = check(r, [train(in: 900)]) else { return XCTFail() }
        XCTAssertEqual(next.leaveBy, now.addingTimeInterval(420))
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(300))
    }

    func testEarlierTrainWithLessThanTheLeadLeftFiresNow() throws {
        let r = try reminder()
        // Leave by now + 120 s, and it is now + 30 s: less than the 2 minutes of lead
        guard case .fireNow(let next) = check(r, [train(in: 600)]) else { return XCTFail() }
        XCTAssertEqual(next.leaveBy, now.addingTimeInterval(120))
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(30))
        XCTAssertEqual(next.trainTime, now.addingTimeInterval(600))
        // From then on it's the system's: the next refresh leaves it alone, whatever the train does
        XCTAssertEqual(check(next, [train(in: 600, seen: 45)], after: 45), .keep)
        XCTAssertEqual(check(next, [train(in: 300, seen: 45)], after: 45), .keep)
        XCTAssertEqual(check(next, [], after: 45), .keep)
    }

    func testFiresNowExactlyAtTheLead() throws {
        let r = try reminder()
        // Checked at now + 60 s; leave by now + 180 s is exactly the lead away
        guard case .fireNow = check(r, [train(in: 660, seen: 60)], after: 60) else { return XCTFail() }
        guard case .reschedule(let next) = check(r, [train(in: 720, seen: 60)], after: 60) else { return XCTFail() }
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(120))
    }

    func testTooLate() throws {
        let r = try reminder()
        // Checked at now + 30 s. Train in 500 s: at the platform 110 s before it, under the 120 s of buffer: tight
        func tooLate(in seconds: TimeInterval) -> Bool? {
            guard case .tooLate(let told, let tight) = check(r, [train(in: seconds)]) else { return nil }
            // What it tells has the train's time as just read; the rest is as it was
            XCTAssertEqual(told.trainTime, now.addingTimeInterval(seconds))
            XCTAssertEqual(told.checkedAt, now.addingTimeInterval(30))
            XCTAssertEqual(told.id, r.id)
            XCTAssertEqual(told.leaveBy, r.leaveBy)
            XCTAssertEqual(told.fireAt, r.fireAt)
            return tight
        }
        XCTAssertEqual(tooLate(in: 500), true)
        XCTAssertEqual(tooLate(in: 390), true)
        // At the platform after it has left
        XCTAssertEqual(tooLate(in: 389), false)
        XCTAssertEqual(tooLate(in: 100), false)
        // Still "Can try" setting off this second: fires now instead
        guard case .fireNow = check(r, [train(in: 510)]) else { return XCTFail() }
    }

    func testTooLateTellsTheTrainThatTookItsPlace() throws {
        // With a lead of 1 minute the notification comes at now + 660 s
        let r = try reminder(lead: 1)
        // At now + 620 s the data has changed its ids, and the same train (within two minutes of it) comes 2 minutes earlier:
        // leave by now + 600 s, which is over
        let early = train("b", in: 1080, seen: 620)
        guard case .tooLate(let told, let tight) = check(r, [early], lead: 1, after: 620) else { return XCTFail() }
        XCTAssertTrue(tight)
        XCTAssertEqual(told.id, "b")
        XCTAssertEqual(told.trainTime, now.addingTimeInterval(1080))
        XCTAssertEqual(told.checkedAt, now.addingTimeInterval(620))
    }

    func testDetailsOfATrainThatCanHaveOne() throws {
        let r = try reminder()
        typealias R = LeaveReminders
        XCTAssertEqual(R.details(.canSet(r), permission: .allowed, asking: false, failed: false), .canSet(r, failed: false))
        // Not asked yet, or not read yet: the button is there, and clicking it asks
        XCTAssertEqual(R.details(.canSet(r), permission: .notAsked, asking: false, failed: false), .canSet(r, failed: false))
        XCTAssertEqual(R.details(.canSet(r), permission: .unknown, asking: false, failed: false), .canSet(r, failed: false))
        XCTAssertEqual(R.details(.canSet(r), permission: .allowed, asking: false, failed: true), .canSet(r, failed: true))
        // While macOS asks, nothing else is offered
        XCTAssertEqual(R.details(.canSet(r), permission: .notAsked, asking: true, failed: true), .asking(r))
        // Off in System Settings: says so instead of a button that would do nothing
        XCTAssertEqual(R.details(.canSet(r), permission: .off, asking: false, failed: false), .notificationsOff(r))
        XCTAssertEqual(R.details(.canSet(r), permission: .off, asking: false, failed: true), .notificationsOff(r))
    }

    func testDetailsOfATrainThatHasOneOrCantHaveOne() throws {
        let r = try reminder()
        typealias R = LeaveReminders
        XCTAssertEqual(R.details(.isSet(r), permission: .allowed, asking: false, failed: false), .isSet(r, notificationsOff: false))
        XCTAssertEqual(R.details(.isSet(r), permission: .unknown, asking: true, failed: true), .isSet(r, notificationsOff: false))
        // Set, then notifications were turned off: it can still be cancelled, and it says it won't be shown
        XCTAssertEqual(R.details(.isSet(r), permission: .off, asking: false, failed: false), .isSet(r, notificationsOff: true))
        for why in [R.Refusal.demo, .notCanTry, .full, .leaveNow, .walkComing] {
            XCTAssertEqual(R.details(.refused(why), permission: .off, asking: true, failed: true), .refused(why))
            XCTAssertEqual(R.details(.refused(why), permission: .allowed, asking: false, failed: false), .refused(why))
        }
    }

    func testTimeChangedGoesByTheMinutesShown() throws {
        let r = try reminder()
        var same = r
        same.trainTime = r.trainTime.addingTimeInterval(20)
        same.checkedAt = r.checkedAt.addingTimeInterval(300)
        same.fireAt = r.fireAt.addingTimeInterval(5)
        XCTAssertFalse(LeaveReminders.timeChanged(from: r, to: same))
        var later = r
        later.trainTime = r.trainTime.addingTimeInterval(60)
        XCTAssertTrue(LeaveReminders.timeChanged(from: r, to: later))
        var leave = r
        leave.leaveBy = r.leaveBy.addingTimeInterval(-60)
        XCTAssertTrue(LeaveReminders.timeChanged(from: r, to: leave))
    }

    func testWaitingAreTheOnesNotYetFiredSoonestFirst() throws {
        let first = try reminder()
        let second = try make(train("b", in: 1500), existing: [first]).get()
        let third = try make(train("c", in: 1500), existing: [first, second]).get()
        XCTAssertEqual(LeaveReminders.waiting([third, second, first], now: now).map(\.id), ["a", "b", "c"])
        // At the moment it fires it is no longer waiting
        XCTAssertEqual(LeaveReminders.waiting([second, first], now: first.fireAt).map(\.id), ["b"])
        XCTAssertEqual(LeaveReminders.waiting([second, first], now: first.fireAt.addingTimeInterval(-1)).map(\.id), ["a", "b"])
        XCTAssertEqual(LeaveReminders.waiting([first], now: now.addingTimeInterval(3600)), [])
        // By when each rings, not when its train leaves: a later train with a longer lead time rings first, and is listed first
        // (the popover and Settings, Reminders both list them so)
        let early = try make(train("e", in: 1500), lead: 10, existing: [first]).get()
        XCTAssertLessThan(early.fireAt, first.fireAt)
        XCTAssertGreaterThan(early.trainTime, first.trainTime)
        XCTAssertEqual(LeaveReminders.waiting([first, early], now: now).map(\.id), ["e", "a"])
    }

    func testTheAppStaysOnUntilTheLastOneHasToLeave() throws {
        let first = try reminder()
        let second = try make(train("b", in: 1500), existing: [first]).get()
        XCTAssertNil(LeaveReminders.holdUntil([], now: now, clockOffset: 0))
        XCTAssertEqual(LeaveReminders.holdUntil([first], now: now, clockOffset: 0), first.leaveBy)
        XCTAssertEqual(LeaveReminders.holdUntil([second, first], now: now, clockOffset: 0), second.leaveBy)
        XCTAssertGreaterThan(second.leaveBy, first.leaveBy)
        // One that has fired still counts until its time to leave: a click on its notification finds fresh times
        XCTAssertEqual(LeaveReminders.holdUntil([first], now: first.fireAt.addingTimeInterval(30), clockOffset: 0), first.leaveBy)
        // Past the time to leave there is nothing to stay on for
        XCTAssertNil(LeaveReminders.holdUntil([first], now: first.leaveBy, clockOffset: 0))
        XCTAssertEqual(LeaveReminders.holdUntil([first, second], now: first.leaveBy, clockOffset: 0), second.leaveBy)
        XCTAssertNil(LeaveReminders.holdUntil([first, second], now: second.leaveBy.addingTimeInterval(1), clockOffset: 0))
        // In this Mac's time: when its clock is 10 minutes slow (the servers 600 s ahead) the app stays on until 10 minutes
        // earlier by that clock, when it's fast until later; past that, nothing
        XCTAssertEqual(LeaveReminders.holdUntil([first], now: now, clockOffset: 600), first.leaveBy.addingTimeInterval(-600))
        XCTAssertEqual(LeaveReminders.holdUntil([first], now: now, clockOffset: -600), first.leaveBy.addingTimeInterval(600))
        XCTAssertNil(LeaveReminders.holdUntil([first], now: first.leaveBy.addingTimeInterval(-600), clockOffset: 600))
        XCTAssertNotNil(LeaveReminders.holdUntil([first], now: first.leaveBy, clockOffset: -600))
    }

    func testNotificationNamesAreApart() throws {
        let r = try reminder()
        XCTAssertEqual(r.notificationID, "leave-reminder.a")
        XCTAssertEqual(r.noticeID, "leave-notice.a")
        XCTAssertFalse(r.noticeID.hasPrefix(LeaveReminder.notificationPrefix))
        XCTAssertFalse(r.notificationID.hasPrefix(LeaveReminder.noticePrefix))
    }

    func testCancelledTrainIsGone() throws {
        let r = try reminder()
        XCTAssertEqual(check(r, [train(in: 1200, status: .cancelled)]), .gone(cancelled: true))
        // Stale word of a cancellation isn't followed
        XCTAssertEqual(check(r, [train(in: 1200, updatedAgo: 400, status: .cancelled)]), .keep)
    }

    func testNotListedWhileTheFollowingTrainIsMeansGone() throws {
        var r = try reminder()
        r.followingID = "b"
        XCTAssertEqual(check(r, [train("b", in: 1800)]), .gone(cancelled: false))
        // Even with another train right at its time: the ids didn't change, so that is another train
        XCTAssertEqual(check(r, [train("n", in: 1210), train("b", in: 1800)]), .gone(cancelled: false))
        // The following train's data is stale: nothing is known
        XCTAssertEqual(check(r, [train("b", in: 1800, updatedAgo: 400)]), .keep)
        // The following train is at another station's list only
        XCTAssertEqual(check(r, [train("b", in: 1800, station: "T")]), .keep)
    }

    func testNothingKnownKeeps() throws {
        var r = try reminder()
        XCTAssertEqual(check(r, []), .keep)
        // No following train was known: later trains alone don't show this one is gone
        XCTAssertEqual(check(r, [train("c", in: 1800)]), .keep)
        r.followingID = "b"
        XCTAssertEqual(check(r, []), .keep)
        XCTAssertEqual(check(r, [train("c", in: 1800)]), .keep)
        XCTAssertEqual(check(r, [train("other", in: 1200, station: "T")]), .keep)
        // The train's own data is stale, or has no time: its time stays as it was
        XCTAssertEqual(check(r, [train(in: 300, updatedAgo: 400)]), .keep)
        XCTAssertEqual(check(r, [train(in: nil), train("b", in: 1800)]), .keep)
    }

    /// The timetable and realtime give one train different ids: when neither the train nor the one after it is listed,
    /// the nearest train of the same service within 2 minutes is the same train
    func testIdsChanged() throws {
        var r = try make(train("sched-1", in: 1200, source: .scheduled)).get()
        // A timetable time needs 60 s more slack: leave by now + 660 s
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(660))
        r.followingID = "sched-2"
        let live = [train("rt-0", in: 700), train("rt-1", in: 1290), train("rt-2", in: 1900)]
        guard case .reschedule(let next) = check(r, live) else { return XCTFail("\(check(r, live))") }
        XCTAssertEqual(next.id, "rt-1")
        XCTAssertEqual(next.source, .realtime)
        XCTAssertEqual(next.trainTime, now.addingTimeInterval(1290))
        // Realtime now: latest = now + 1290 − 480 = now + 810, shown as now + 780
        XCTAssertEqual(next.leaveBy, now.addingTimeInterval(780))
        XCTAssertEqual(next.followingID, "rt-2")
        // Exactly 2 minutes away still is
        guard case .reschedule(let edge) = check(r, [train("rt-1", in: 1320), train("rt-2", in: 1900)]) else { return XCTFail() }
        XCTAssertEqual(edge.id, "rt-1")
        // More than 2 minutes away: not taken as the same train, and nothing is known
        XCTAssertEqual(check(r, [train("rt-1", in: 1321), train("rt-2", in: 1900)]), .keep)
        XCTAssertEqual(check(r, [train("rt-1", in: 1079)]), .keep)
        // Another route or direction is never taken
        XCTAssertEqual(check(r, [train("rt-1", in: 1200, route: "G"), train("rt-3", in: 1200, code: "S")]), .keep)
        // A cancelled one neither
        XCTAssertEqual(check(r, [train("rt-1", in: 1200, status: .cancelled)]), .keep)
    }

    func testSameIdTurningRealtimeNeedsLessSlack() throws {
        // Ferries, trains: the id stays when realtime times come in
        let r = try make(train(in: 1200, source: .scheduled)).get()
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(660))
        XCTAssertEqual(r.baseSlackSeconds, 120)
        guard case .reschedule(let next) = check(r, [train(in: 1200)]) else { return XCTFail() }
        XCTAssertEqual(next.leaveBy, now.addingTimeInterval(720))
        XCTAssertEqual(next.source, .realtime)
        // A subway train with no train assigned yet counts as a timetable time
        XCTAssertEqual(check(r, [train(in: 1200, assigned: false)]), .keep)
    }

    func testEstimatedWalkKeepsItsUncertainty() throws {
        let a = train(in: 1200)
        let r = try make(a, walkSource: .estimated).get()
        // 15% of the 300 s walk on top of the buffer
        XCTAssertEqual(r.baseSlackSeconds, 165)
        XCTAssertEqual(r.leaveBy, evaluation(a, walkSource: .estimated).latestLeave)
        XCTAssertEqual(check(r, [a]), .keep)
    }

    func testChangingTheLead() throws {
        let r = try reminder()
        guard case .reschedule(let next) = check(r, [train(in: 1200)], lead: 5) else { return XCTFail() }
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(420))
        XCTAssertEqual(next.leadSeconds, 300)
        XCTAssertEqual(next.leaveBy, r.leaveBy)
        // Without word of the train the lead is followed all the same
        guard case .reschedule(let blind) = check(r, [], lead: 5) else { return XCTFail() }
        XCTAssertEqual(blind.fireAt, now.addingTimeInterval(420))
        XCTAssertEqual(blind.checkedAt, r.checkedAt)
        // A lead longer than what is left: now
        guard case .fireNow(let soon) = check(r, [], lead: 12) else { return XCTFail() }
        XCTAssertEqual(soon.fireAt, now.addingTimeInterval(30))
        XCTAssertEqual(soon.checkedAt, r.checkedAt)
    }

    func testChangingClockOffset() throws {
        let r = try reminder()
        // The servers turn out to be 120 s ahead of this Mac: the train (same server time) is nearer than it looked
        guard case .reschedule(let next) = check(r, [train(in: 1200)], offset: 120) else { return XCTFail() }
        XCTAssertEqual(next.leaveBy, r.leaveBy)
        XCTAssertEqual(next.fireAt, now.addingTimeInterval(480))
        guard case .reschedule(let blind) = check(r, [], offset: 120) else { return XCTFail() }
        XCTAssertEqual(blind.fireAt, now.addingTimeInterval(480))
    }

    func testAboutToFireIsLeftAlone() throws {
        let r = try reminder()
        // Fires at now + 600 s
        guard case .reschedule = check(r, [train(in: 1500, seen: 584)], after: 584) else { return XCTFail() }
        XCTAssertEqual(check(r, [train(in: 1500, seen: 585)], after: 585), .keep)
        XCTAssertEqual(check(r, [train(in: 1500, seen: 600)], after: 600), .keep)
        XCTAssertEqual(check(r, [train(in: 300, seen: 700)], after: 700), .keep)
        XCTAssertEqual(check(r, [train(in: 1200, seen: 590, status: .cancelled)], after: 590), .keep)
        // The same cancellation a little earlier is followed
        XCTAssertEqual(check(r, [train(in: 1200, seen: 580, status: .cancelled)], after: 580), .gone(cancelled: true))
    }

    /// A train's time going back and forth: each change replaces the one pending notification, and it never fires more than once
    func testBackAndForth() throws {
        var r = try reminder()
        var fired = 0
        var t: TimeInterval = 0
        for seconds in [1500.0, 1200, 1500, 1200, 1210, 1200, 900, 1200] {
            t += 30
            switch check(r, [train(in: seconds, seen: t)], after: t) {
            case .reschedule(let next): r = next
            case .fireNow(let next): r = next; fired += 1
            case .keep: break
            case let other: XCTFail("\(other)")
            }
            XCTAssertEqual(r.fireAt, now.addingTimeInterval(LeaveReminders.minute(now.addingTimeInterval(seconds - 480))
                .timeIntervalSince(now) - 120), "\(seconds)")
        }
        XCTAssertEqual(fired, 0)
    }

    // MARK: The bell's count, the lead while the arrows are pressed

    /// The count of reminders still to come drops when the soonest one's notification comes: that's when it's redrawn
    func testNextFireIsTheSoonestStillToCome() throws {
        let first = try make(train("a", in: 1200)).get()
        let second = try make(train("b", in: 1500), existing: [first]).get()
        XCTAssertEqual(LeaveReminders.nextFire([second, first], now: now), first.fireAt)
        XCTAssertEqual(LeaveReminders.nextFire([second, first], now: first.fireAt), second.fireAt, "one that has come is over")
        XCTAssertNil(LeaveReminders.nextFire([second, first], now: second.fireAt))
        XCTAssertNil(LeaveReminders.nextFire([], now: now))
    }

    /// The lead the waiting reminders follow changes only once the choice has stood still: the values passed on the way don't
    /// count; leaving the page applies it at once; going back to the one in use leaves nothing waiting
    func testTheLeadAppliesOnceItStandsStill() {
        var lead = ReminderLead(2)
        lead.choose(3, now: now)
        lead.choose(20, now: now.addingTimeInterval(0.5))
        XCTAssertEqual(lead.chosen, 20)
        XCTAssertEqual(lead.applied, 2)
        XCTAssertEqual(lead.dueAt, now.addingTimeInterval(0.5 + ReminderLead.settleSeconds))
        XCTAssertFalse(lead.apply(now: now.addingTimeInterval(1.5)), "still pressing")
        lead.choose(4, now: now.addingTimeInterval(1))
        XCTAssertFalse(lead.apply(now: now.addingTimeInterval(2)))
        XCTAssertTrue(lead.apply(now: now.addingTimeInterval(1 + ReminderLead.settleSeconds)))
        XCTAssertEqual(lead.applied, 4)
        XCTAssertNil(lead.dueAt)
        XCTAssertFalse(lead.apply(now: nil), "nothing waits")
        // Leaving the page: at once
        lead.choose(6, now: now.addingTimeInterval(10))
        XCTAssertTrue(lead.apply(now: nil))
        XCTAssertEqual(lead.applied, 6)
        // There and back: nothing to apply
        lead.choose(9, now: now.addingTimeInterval(20))
        lead.choose(6, now: now.addingTimeInterval(20.5))
        XCTAssertNil(lead.dueAt)
        XCTAssertFalse(lead.apply(now: now.addingTimeInterval(30)))
        XCTAssertEqual(lead.applied, 6)
    }
}
