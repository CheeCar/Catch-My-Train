import XCTest
@testable import CatchText
import TransitCore

/// What leave-by reminders say: next to a train, in its details and in their notifications.
/// The reminder used: a realtime train 20 minutes from `now`, 6 minutes to the platform, 2 minutes of buffer. So leave by
/// now + 12 min, and with the default lead the notification comes at now + 10 min.
final class ReminderTextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let newYork = TimeZone(identifier: "America/New_York")!
    var l: AppText { AppText(timeZone: newYork) }

    func reminder(lead: Int = 2, route: String = "L") throws -> LeaveReminder {
        let arrival = Arrival(id: "a", stationID: "S", route: route, direction: Direction(code: "N", name: "Uptown"),
                              arrivalTime: now.addingTimeInterval(1200), source: .realtime, updatedAt: now)
        let walk = WalkEstimate(walkSeconds: 300, straightLineMeters: 300, source: .route)
        let evaluation = CatchEvaluator.evaluate(arrival: arrival, walk: walk, entranceToPlatformSeconds: 60, settings: .default,
                                                 now: now, clockOffset: 0)
        return try LeaveReminders.make(from: evaluation, stationName: "Bedford Av", routeName: route, leadMinutes: lead,
                                       existing: [], now: now, clockOffset: 0).get()
    }

    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{2060}", with: "") }

    func testLinesNextToATrain() throws {
        let r = try reminder()
        XCTAssertEqual(r.leaveBy, now.addingTimeInterval(720))
        XCTAssertEqual(plain(l.reminderAt(r)), "Reminder at " + l.time(now.addingTimeInterval(600)))
        XCTAssertEqual(plain(l.remindMeAt(r)), "Remind Me at " + l.time(now.addingTimeInterval(600)))
        XCTAssertEqual(l.reminderLead(r), "2 min before you have to leave")
        XCTAssertEqual(l.reminderLead(try reminder(lead: 10)), "10 min before you have to leave")
        XCTAssertEqual(plain(l.reminderLeaveBy(r)), "Leave by " + l.time(now.addingTimeInterval(720)))
        XCTAssertEqual(l.reminderLeaveBy(r), l.leaveBy(at: r.leaveBy))
        // In the app's own windows a time stays on one line; a screen reader gets it plainly
        for (shown, spoken) in [(l.reminderAt(r), l.reminderAt(r, spoken: true)),
                                (l.remindMeAt(r), l.remindMeAt(r, spoken: true)),
                                (l.reminderLeaveBy(r), l.reminderLeaveBy(r, spoken: true))] {
            XCTAssertTrue(shown.contains("\u{2060}"))
            XCTAssertFalse(spoken.contains("\u{2060}"))
            XCTAssertEqual(plain(shown), spoken)
        }
    }

    /// A reminder in the lists: when its notification comes, then the latest time to leave, each time kept whole on screen
    func testTheTimesInTheLists() throws {
        let r = try reminder()
        XCTAssertEqual(plain(l.reminderTimes(r)), "Reminder at " + l.time(now.addingTimeInterval(600)) + " · Leave by "
                       + l.time(now.addingTimeInterval(720)))
        XCTAssertEqual(l.reminderTimes(r), l.reminderAt(r) + " · " + l.reminderLeaveBy(r))
        XCTAssertEqual(l.reminderTimes(r, spoken: true), plain(l.reminderTimes(r)))
        XCTAssertFalse(l.reminderTimes(r, spoken: true).contains("\u{2060}"))
        // In another language the words come from its table
        let fr = AppText(language: .french, timeZone: newYork)
        XCTAssertTrue(fr.reminderTimes(r, spoken: true).hasPrefix("Rappel \u{00E0} "))
    }

    func testWhyATrainCantHaveOne() {
        XCTAssertEqual(l.reminderRefusal(.demo), "Not available in Demo mode.")
        XCTAssertEqual(l.reminderRefusal(.notCanTry), "A reminder can be set only when it says \u{201C}Can try\u{201D}.")
        XCTAssertEqual(l.reminderRefusal(.full), "There are already 10 reminders. Cancel one to set another.")
        XCTAssertEqual(l.reminderRefusal(.leaveNow), "Too close for a reminder. Leave now to try for it.")
        XCTAssertNil(l.reminderRefusal(.alreadySet))
        XCTAssertNil(l.reminderRefusal(.walkComing))
    }

    func testTheReminderItself() throws {
        let r = try reminder()
        let train = l.time(now.addingTimeInterval(1200)) + " · Bedford Av · " + l.direction(r.direction)
        XCTAssertEqual(l.reminderTrainLine(r), train)
        let notice = l.reminderNotice(r, .leave, now: now)
        XCTAssertEqual(notice.title, "Leave in 2 min · L")
        XCTAssertEqual(notice.body, train + "\nLeave by " + l.time(now.addingTimeInterval(720))
                       + " · Last checked at " + l.time(now))
        XCTAssertEqual(l.reminderNotice(try reminder(lead: 10), .leave, now: now).title, "Leave in 10 min · L")
        // A line with a long name
        XCTAssertEqual(l.reminderNotice(try reminder(route: "NJ Transit Northeast Corridor"), .leave, now: now).title,
                       "Leave in 2 min · NJ Transit Northeast Corridor")
    }

    func testSentAtOnceCountsTheWholeMinutesLeft() throws {
        let r = try reminder()
        func title(left seconds: TimeInterval) -> String {
            l.reminderNotice(r, .leaveNow(timeChanged: false), now: r.leaveBy.addingTimeInterval(-seconds)).title
        }
        XCTAssertEqual(title(left: 180), "Leave in 3 min · L")
        XCTAssertEqual(title(left: 119), "Leave in 1 min · L")
        XCTAssertEqual(title(left: 60), "Leave in 1 min · L")
        XCTAssertEqual(title(left: 59), "Leave now · L")
        XCTAssertEqual(title(left: 0), "Leave now · L")
        XCTAssertEqual(title(left: -30), "Leave now · L")
        let train = l.reminderTrainLine(r)
        let leaveBy = "Leave by " + l.time(now.addingTimeInterval(720))
        let checked = "Last checked at " + l.time(now)
        XCTAssertEqual(l.reminderNotice(r, .leaveNow(timeChanged: false), now: now).body, train + "\n" + leaveBy + " · " + checked)
        XCTAssertEqual(l.reminderNotice(r, .leaveNow(timeChanged: true), now: now).body,
                       train + "\n" + leaveBy + " · Time changed · " + checked)
    }

    func testWhenTheReminderIsOver() throws {
        let r = try reminder()
        let train = l.reminderTrainLine(r)
        XCTAssertEqual(l.reminderNotice(r, .tight, now: now),
                       AppText.ReminderNotice(title: "Now tight · L",
                                              body: train + "\nLeave right away to try for it. This reminder is over."))
        let next = now.addingTimeInterval(1500)
        XCTAssertEqual(l.reminderNotice(r, .tooSoon(next: next), now: now),
                       AppText.ReminderNotice(title: "Too soon to catch · L",
                                              body: train + "\nNext one you can catch: " + l.time(next) + "\nThis reminder is over."))
        XCTAssertEqual(l.reminderNotice(r, .tooSoon(next: nil), now: now).body, train + "\nThis reminder is over.")
        XCTAssertEqual(l.reminderNotice(r, .cancelled, now: now),
                       AppText.ReminderNotice(title: "Cancelled · L", body: train + "\nThis reminder is over."))
        XCTAssertEqual(l.reminderNotice(r, .notListed, now: now),
                       AppText.ReminderNotice(title: "No longer listed · L", body: train + "\nThis reminder is over."))
    }

    func testTimesAreTheStationsOwn() throws {
        var r = try reminder()
        r.timeZone = "America/Chicago"
        let chicago = TimeZone(identifier: "America/Chicago")!
        let notice = l.reminderNotice(r, .leave, now: now)
        XCTAssertTrue(notice.body.hasPrefix(l.time(now.addingTimeInterval(1200), timeZone: chicago) + " · "), notice.body)
        XCTAssertTrue(notice.body.contains("Leave by " + l.time(now.addingTimeInterval(720), timeZone: chicago)), notice.body)
        XCTAssertNotEqual(l.time(now, timeZone: chicago), l.time(now))
        XCTAssertEqual(plain(l.reminderAt(r)), "Reminder at " + l.time(now.addingTimeInterval(600), timeZone: chicago))
    }

    /// The system lays a notification out itself: no marks that keep a time on one line, and nothing left to fill in
    func testNotificationsInEveryLanguage() throws {
        let r = try reminder()
        let kinds: [AppText.ReminderNoticeKind] = [.leave, .leaveNow(timeChanged: true), .leaveNow(timeChanged: false), .tight,
                                                   .tooSoon(next: now.addingTimeInterval(1500)), .tooSoon(next: nil), .cancelled,
                                                   .notListed]
        for language in AppLanguage.allCases {
            let shown = AppText(language: language, timeZone: newYork)
            var titles = Set<String>()
            for kind in kinds {
                let notice = shown.reminderNotice(r, kind, now: now)
                for text in [notice.title, notice.body] {
                    XCTAssertFalse(text.contains("\u{2060}"), "\(language.rawValue) \(kind)")
                    XCTAssertFalse(text.contains("%"), "\(language.rawValue) \(kind): \(text)")
                    XCTAssertFalse(text.hasSuffix("\n"), "\(language.rawValue) \(kind)")
                }
                XCTAssertTrue(notice.title.contains("L"), "\(language.rawValue) \(kind)")
                XCTAssertTrue(notice.body.contains("Bedford Av"), "\(language.rawValue) \(kind)")
                XCTAssertTrue(notice.body.contains(shown.time(now.addingTimeInterval(1200))), "\(language.rawValue) \(kind)")
                titles.insert(notice.title)
            }
            // Six different things to say (the reminder sent at once says "Leave now" either way; too soon the same with and
            // without a next one)
            XCTAssertEqual(titles.count, 6, "\(language.rawValue): \(titles.sorted())")
            // The reminder itself and the one sent at once both say when to leave by and when that was checked
            for kind in kinds.prefix(3) {
                let body = shown.reminderNotice(r, kind, now: now).body
                XCTAssertTrue(body.contains(shown.time(now.addingTimeInterval(720))), "\(language.rawValue) \(kind)")
                XCTAssertTrue(body.contains(shown.time(now)), "\(language.rawValue) \(kind)")
            }
        }
    }
}
