import XCTest
@testable import TransitCore

/// Scheduled timetable (for the trip planner): build a small file from GTFS text, then look up departures by station and time.
final class TimetableTests: XCTestCase {

    /// A small GTFS sample in real format: a few 7 trains each way at 61 St-Woodside (712),
    /// one at 0:30 after midnight (24:30 of the previous day), one not running on holidays.
    func sampleFiles() -> [String: Data] {
        let calendar = """
        service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
        Weekday,1,1,1,1,1,0,0,20261001,20261031
        Saturday,0,0,0,0,0,1,0,20261001,20261031
        """
        let dates = """
        service_id,date,exception_type
        Weekday,20261012,2
        Saturday,20261012,1
        """
        let trips = """
        route_id,trip_id,service_id,trip_headsign,direction_id,shape_id
        7,T1,Weekday,"Flushing, Main St",0,s
        7,T2,Weekday,34 St-Hudson Yards,1,s
        7,T3,Weekday,Flushing-Main St,0,s
        7,T4,Saturday,Flushing-Main St,0,s
        7,T5,Weekday,61 St-Woodside,1,s
        """
        let stopTimes = """
        trip_id,stop_id,arrival_time,departure_time,stop_sequence
        T1,726N,18:00:00,18:00:00,1
        T1,712N,18:20:00,18:20:00,2
        T1,701N,18:40:00,18:40:00,3
        T2,701S,17:40:00,17:40:00,1
        T2,712S,18:05:30,18:05:30,2
        T2,726S,18:25:00,18:25:00,3
        T3,712N,24:30:00,24:30:00,1
        T3,701N,24:50:00,24:50:00,2
        T4,712N,18:22:00,18:22:00,1
        T4,701N,18:42:00,18:42:00,2
        T5,701S,17:50:00,17:50:00,1
        T5,712S,18:10:00,18:10:00,2
        """
        return ["calendar.txt": Data(calendar.utf8), "calendar_dates.txt": Data(dates.utf8),
                "trips.txt": Data(trips.utf8), "stop_times.txt": Data(stopTimes.utf8)]
    }

    func nyc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Timetable.calendar(in: Timetable.timeZone).date(from: c)!
    }

    func testBuildAndQueryBothDirections() throws {
        let catalog = try StationCatalog.loadBundled()
        let built = Date(timeIntervalSince1970: 1_800_000_000)
        let tt = try Timetable(data: TimetableBuilder.build(files: sampleFiles(), builtAt: built))
        XCTAssertEqual(tt.feedStart, 20261001)
        XCTAssertEqual(tt.feedEnd, 20261031)
        XCTAssertEqual(tt.builtAt, built)
        // Shown as "valid until": the last day itself, not the midnight after it
        XCTAssertEqual(tt.validUntil.map { Timetable.dayNumber($0, in: Timetable.timeZone) }, 20261031)

        // 2026-10-13 is a Tuesday
        let from = nyc(2026, 10, 13, 18, 0)
        let list = tt.arrivals(stationIDs: ["712"], from: from, to: from.addingTimeInterval(3600), catalog: catalog)
        XCTAssertEqual(list.map(\.arrivalTime), [nyc(2026, 10, 13, 18, 5).addingTimeInterval(30), nyc(2026, 10, 13, 18, 20)],
                       "Saturday trains don't run; T5, which terminates here, doesn't count")
        XCTAssertTrue(list.allSatisfy { $0.source == .scheduled })
        let north = try XCTUnwrap(list.first { $0.direction.code == "N" })
        XCTAssertEqual(north.direction.terminal, "Flushing-Main St", "The terminal comes from the trip's last stop")
        let south = try XCTUnwrap(list.first { $0.direction.code == "S" })
        XCTAssertEqual(south.direction.label, "Manhattan")
    }

    /// A trip's rows don't have to be next to each other or in stop_sequence order: the result is the same as for the grouped file
    func testTripRowsNeedNotBeContiguous() throws {
        let catalog = try StationCatalog.loadBundled()
        var files = sampleFiles()
        files["stop_times.txt"] = Data("""
        trip_id,stop_id,arrival_time,departure_time,stop_sequence
        T1,712N,18:20:00,18:20:00,2
        T2,701S,17:40:00,17:40:00,1
        T1,726N,18:00:00,18:00:00,1
        T3,712N,24:30:00,24:30:00,1
        T2,712S,18:05:30,18:05:30,2
        T4,712N,18:22:00,18:22:00,1
        T5,701S,17:50:00,17:50:00,1
        T3,701N,24:50:00,24:50:00,2
        T2,726S,18:25:00,18:25:00,3
        T5,712S,18:10:00,18:10:00,2
        T4,701N,18:42:00,18:42:00,2
        T1,701N,18:40:00,18:40:00,3
        """.utf8)
        let built = Date(timeIntervalSince1970: 1_800_000_000)
        let mixed = try TimetableBuilder.build(files: files, builtAt: built)
        XCTAssertEqual(mixed, try TimetableBuilder.build(files: sampleFiles(), builtAt: built))
        let tt = try Timetable(data: mixed)
        let from = nyc(2026, 10, 13, 18, 0)
        let list = tt.arrivals(stationIDs: ["712"], from: from, to: from.addingTimeInterval(3600), catalog: catalog)
        XCTAssertEqual(list.map(\.arrivalTime), [nyc(2026, 10, 13, 18, 5).addingTimeInterval(30), nyc(2026, 10, 13, 18, 20)])
        XCTAssertEqual(list.first { $0.direction.code == "N" }?.direction.terminal, "Flushing-Main St")
    }

    /// When Plan a Trip downloads the timetable again: never in a loop, also when there is no timetable or it doesn't reach the date
    func testRefreshDecision() {
        let now = nyc(2026, 10, 20, 12, 0)
        let minute: TimeInterval = 60
        func decide(_ covers: Bool?, built: Date? = nil, failed: Date? = nil) -> TimetableRefresh.Decision {
            TimetableRefresh.decide(covers: covers, builtAt: built, lastFailure: failed, now: now)
        }
        let thisMonth = nyc(2026, 10, 5, 12, 0), lastMonth = nyc(2026, 9, 15, 12, 0)
        // No timetable
        XCTAssertEqual(decide(nil), .download)
        XCTAssertEqual(decide(nil, failed: now.addingTimeInterval(-minute)), .wait)
        XCTAssertEqual(decide(nil, failed: now.addingTimeInterval(-11 * minute)), .download)
        // A timetable that doesn't reach the date
        XCTAssertEqual(decide(false, built: lastMonth, failed: now.addingTimeInterval(-minute)), .wait)
        XCTAssertEqual(decide(false, built: now.addingTimeInterval(-minute)), .useCached, "Just built from MTA's newest")
        XCTAssertEqual(decide(false, built: now.addingTimeInterval(-13 * 3600)), .download)
        XCTAssertEqual(decide(false, built: lastMonth), .download)
        // A timetable that covers the date
        XCTAssertEqual(decide(true, built: thisMonth), .useCached)
        XCTAssertEqual(decide(true, built: lastMonth), .download, "Monthly check due")
        XCTAssertEqual(decide(true, built: lastMonth, failed: now.addingTimeInterval(-minute)), .useCached)
    }

    /// Added service days listed only in calendar_dates.txt count toward the validity period too (some feeds don't use calendar.txt date ranges)
    func testCalendarDatesExtendTheValidRange() throws {
        var files = sampleFiles()
        files["calendar_dates.txt"] = Data("""
        service_id,date,exception_type
        Saturday,20261107,1
        """.utf8)
        let t = try Timetable(data: try TimetableBuilder.build(files: files, builtAt: Date()))
        XCTAssertTrue(t.covers(nyc(2026, 11, 7, 12, 0)), "November 7 is only in calendar_dates.txt")
        XCTAssertFalse(t.covers(nyc(2026, 11, 8, 12, 0)))
    }

    /// 00:30 on the Monday after clocks spring forward in March 2027: the day before is Sunday, though 24 hours back is Saturday
    /// A calendar is kept by its zone's name, always as the fixed zone of that name: asked for with this Mac's updating zone, it
    /// keeps the zone the Mac had then, and the name's calendar stays that zone's
    func testCalendarKeepsAFixedZone() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(Timetable.calendar(in: losAngeles).timeZone, losAngeles)
        let mac = Timetable.calendar(in: .autoupdatingCurrent)
        XCTAssertEqual(mac.timeZone.identifier, TimeZone.current.identifier)
        XCTAssertEqual(mac.timeZone, TimeZone(identifier: TimeZone.current.identifier))
    }

    func testPreviousDayAfterSpringForward() {
        let mondayEarly = Date(timeIntervalSince1970: 1_805_085_000)
        XCTAssertEqual(Timetable.dayNumber(mondayEarly, in: Timetable.timeZone), 20270315)
        XCTAssertEqual(Timetable.dayNumber(mondayEarly.addingTimeInterval(-24 * 3600), in: Timetable.timeZone), 20270313)
        XCTAssertEqual(Timetable.previousDay(mondayEarly, in: Timetable.timeZone), 20270314)
    }

    func testAfterMidnightTripsBelongToPreviousDay() throws {
        let catalog = try StationCatalog.loadBundled()
        let tt = try Timetable(data: TimetableBuilder.build(files: sampleFiles(), builtAt: Date()))
        // Tuesday 24:30 = Wednesday 0:30
        let from = nyc(2026, 10, 14, 0, 15)
        let list = tt.arrivals(stationIDs: ["712"], from: from, to: from.addingTimeInterval(1800), catalog: catalog)
        XCTAssertEqual(list.map(\.arrivalTime), [nyc(2026, 10, 14, 0, 30)])
    }

    func testHolidayExceptions() throws {
        let catalog = try StationCatalog.loadBundled()
        let tt = try Timetable(data: TimetableBuilder.build(files: sampleFiles(), builtAt: Date()))
        // 2026-10-12 is a Monday, but runs on the Saturday schedule
        let from = nyc(2026, 10, 12, 18, 0)
        let list = tt.arrivals(stationIDs: ["712"], from: from, to: from.addingTimeInterval(3600), catalog: catalog)
        XCTAssertEqual(list.map(\.arrivalTime), [nyc(2026, 10, 12, 18, 22)])
        XCTAssertTrue(tt.covers(from))
        XCTAssertFalse(tt.covers(nyc(2026, 11, 2, 12, 0)), "Must re-download after it expires")
    }

    func testWorksWithTheBoard() throws {
        let catalog = try StationCatalog.loadBundled()
        let tt = try Timetable(data: TimetableBuilder.build(files: sampleFiles(), builtAt: Date()))
        let station = try XCTUnwrap(catalog.station(id: "712"))
        let leave = nyc(2026, 10, 13, 18, 0)
        let walk = WalkEstimate(walkSeconds: 600, straightLineMeters: 700, source: .route)
        let board = NearbyBoardBuilder.build(
            stations: [station], walks: ["712": walk],
            arrivals: tt.arrivals(stationIDs: ["712"], from: leave, to: leave.addingTimeInterval(5400), catalog: catalog),
            settings: .default, now: leave)
        let s = try XCTUnwrap(board.stations.first)
        // 10 min walk + 1.5 min to enter the station + 2 min buffer: the 18:05 is too soon, the 18:20 is worth trying
        XCTAssertEqual(s.south.trains.first?.verdict, .takeNext)
        XCTAssertEqual(s.north.trains.first?.verdict, .canTry)
        XCTAssertTrue(s.north.trains.first?.evaluation.notes.contains(.scheduledOnly) ?? false)
    }

    func testRejectsGarbage() throws {
        XCTAssertThrowsError(try Timetable(data: Data("hello".utf8)))
        XCTAssertThrowsError(try TimetableBuilder.build(files: [:], builtAt: Date()))
        // Not one departure: stop_times only its header, or only trips that aren't in trips.txt. Nothing is built (the old one stays)
        var none = sampleFiles()
        none["stop_times.txt"] = Data("trip_id,stop_id,arrival_time,departure_time,stop_sequence\n".utf8)
        XCTAssertThrowsError(try TimetableBuilder.build(files: none, builtAt: Date()))
        none["stop_times.txt"] = Data("trip_id,stop_id,arrival_time,departure_time,stop_sequence\nX9,712N,18:00:00,18:00:00,1\n".utf8)
        XCTAssertThrowsError(try TimetableBuilder.build(files: none, builtAt: Date()))
        XCTAssertEqual(TimetableBuilder.parseTime("25:07:30"), 25 * 3600 + 7 * 60 + 30)
        // Invalid times (minutes or seconds over 59, absurdly large hours) aren't treated as departures (they would give odd times or overflow)
        XCTAssertNil(TimetableBuilder.parseTime("18:75:00"))
        XCTAssertNil(TimetableBuilder.parseTime("18:00:61"))
        XCTAssertNil(TimetableBuilder.parseTime("999999999:00:00"))
        // Truncated file: throws, never reads past the end
        let good = try TimetableBuilder.build(files: sampleFiles(), builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        for cut in [12, good.count / 2, good.count - 3] {
            XCTAssertThrowsError(try Timetable(data: good.prefix(cut)), "Truncated at \(cut) bytes")
        }
        XCTAssertEqual(TimetableBuilder.splitCSV(#"a,"b, c",d"#), ["a", "b, c", "d"])
        XCTAssertEqual(TimetableBuilder.splitCSV(#"1,"5 ""A"" Av",x"#), ["1", #"5 "A" Av"#, "x"])
        XCTAssertEqual(TimetableBuilder.splitCSV("\"\"\"\","), ["\"", ""])
    }

    /// Runs against the full MTA timetable (only when the CMT_GTFS_DIR environment variable points to the unzipped gtfs_subway folder).
    /// The time it looks up must be inside that feed's dates (feed_info.txt): change it when the feed changes.
    func testFullFeedIfAvailable() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMT_GTFS_DIR"] else {
            throw XCTSkip("CMT_GTFS_DIR is not set")
        }
        var files: [String: Data] = [:]
        for name in ["calendar.txt", "calendar_dates.txt", "trips.txt", "stop_times.txt"] {
            files[name] = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let start = Date()
        let data = try TimetableBuilder.build(files: files, builtAt: Date())
        print("timetable bytes:", data.count, "build seconds:", Date().timeIntervalSince(start))
        let tt = try Timetable(data: data)
        let catalog = try StationCatalog.loadBundled()
        let from = nyc(2026, 11, 18, 18, 0)  // Wednesday evening
        let list = tt.arrivals(stationIDs: ["712", "D16", "724"], from: from, to: from.addingTimeInterval(1800), catalog: catalog)
        print("arrivals:", list.count, list.prefix(6).map { "\($0.stationID) \($0.route) \($0.direction.code) \($0.arrivalTime!) \($0.direction.terminal ?? "-")" })
        XCTAssertGreaterThan(list.count, 20)
        XCTAssertTrue(list.contains { $0.stationID == "712" && $0.direction.code == "S" })
        XCTAssertTrue(list.contains { $0.stationID == "712" && $0.direction.code == "N" })
        XCTAssertLessThan(data.count, 8_000_000)
    }

    /// Two trips at the same station, route and direction at the same minute still get different IDs
    func testSameTimeTripsGetDifferentIDs() throws {
        let catalog = try StationCatalog.loadBundled()
        var files = sampleFiles()
        files["trips.txt"] = Data((String(decoding: files["trips.txt"]!, as: UTF8.self) + "\n7,T6,Weekday,Flushing-Main St,0,s").utf8)
        files["stop_times.txt"] = Data((String(decoding: files["stop_times.txt"]!, as: UTF8.self)
                                        + "\nT6,712N,18:20:00,18:20:00,1\nT6,701N,18:40:00,18:40:00,2").utf8)
        let tt = try Timetable(data: TimetableBuilder.build(files: files, builtAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let from = nyc(2026, 10, 13, 18, 0)
        let list = tt.arrivals(stationIDs: ["712"], from: from, to: from.addingTimeInterval(3600), catalog: catalog)
        let same = list.filter { $0.direction.code == "N" && $0.arrivalTime == nyc(2026, 10, 13, 18, 20) }
        XCTAssertEqual(same.count, 2)
        XCTAssertEqual(Set(same.map(\.id)).count, 2)
    }
}

/// On DST changeover days (2 AM falls back to 1 AM on November 1, 2026; 2 AM jumps to 3 AM on March 8) timetable times must not be off by an hour.
/// GTFS counts times from "noon minus 12 hours" of the service day, so on those two days the start isn't midnight.
final class DaylightSavingTests: XCTestCase {
    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testServiceDayStartAroundDST() {
        // November 1: noon is Eastern Standard Time (UTC-5), start = 05:00Z (local midnight is still DST, 04:00Z)
        XCTAssertEqual(Timetable.serviceDayStart(20261101, in: Timetable.timeZone), utc("2026-11-01T05:00:00Z"))
        // The day before and after both start at local midnight
        XCTAssertEqual(Timetable.serviceDayStart(20261031, in: Timetable.timeZone), utc("2026-10-31T04:00:00Z"))
        XCTAssertEqual(Timetable.serviceDayStart(20261102, in: Timetable.timeZone), utc("2026-11-02T05:00:00Z"))
        // March 8: noon is DST (UTC-4), start = 04:00Z (11 PM standard time the night before)
        XCTAssertEqual(Timetable.serviceDayStart(20260308, in: Timetable.timeZone), utc("2026-03-08T04:00:00Z"))
    }

    /// The app's clock ticks every 60 seconds from the start of a minute: when clocks fall back it goes 1:59 EDT, 1:00 EST, 1:01 EST,
    /// and when they spring forward 1:59 EST, 3:00 EDT (the system's every-minute schedule was seen standing at 1:59 EDT after clocks fell back)
    func testClockMinutesAcrossDST() {
        let start = Timetable.minuteStart(utc("2026-11-01T05:59:30Z"))
        XCTAssertEqual(start, utc("2026-11-01T05:59:00Z"))
        let back = (0..<3).map { start.addingTimeInterval(Double($0) * 60) }
        XCTAssertEqual(back.map { Timetable.calendar(in: Timetable.timeZone).component(.hour, from: $0) }, [1, 1, 1])
        XCTAssertEqual(back.map { Timetable.calendar(in: Timetable.timeZone).component(.minute, from: $0) }, [59, 0, 1])
        XCTAssertEqual(back.map { Timetable.timeZone.isDaylightSavingTime(for: $0) }, [true, false, false])
        // A time on the full minute is its own start
        XCTAssertEqual(Timetable.minuteStart(utc("2026-11-01T06:00:00Z")), utc("2026-11-01T06:00:00Z"))
        // March 14, 2027: 2 AM jumps to 3 AM
        let spring = Timetable.minuteStart(utc("2027-03-14T06:59:45Z"))
        let forward = [spring, spring.addingTimeInterval(60)]
        XCTAssertEqual(forward.map { Timetable.calendar(in: Timetable.timeZone).component(.hour, from: $0) }, [1, 3])
        XCTAssertEqual(forward.map { Timetable.calendar(in: Timetable.timeZone).component(.minute, from: $0) }, [59, 0])
    }

    /// Widgets of different sizes start their timelines at different seconds, but all tick on the clock's minutes after that
    func testTimelineMomentsTickOnWholeMinutes() {
        let a = Timetable.timelineMoments(from: utc("2026-11-20T17:00:07Z"), count: 4)
        XCTAssertEqual(a, [utc("2026-11-20T17:00:07Z"), utc("2026-11-20T17:01:00Z"), utc("2026-11-20T17:02:00Z"), utc("2026-11-20T17:03:00Z")])
        // Another size, asked 46 seconds later: the same moments from the next minute on
        let b = Timetable.timelineMoments(from: utc("2026-11-20T17:00:53Z"), count: 4)
        XCTAssertEqual(Array(b.dropFirst()), Array(a.dropFirst()))
        // Asked on the full minute: no moment twice
        let c = Timetable.timelineMoments(from: utc("2026-11-20T17:00:00Z"), count: 3)
        XCTAssertEqual(c, [utc("2026-11-20T17:00:00Z"), utc("2026-11-20T17:01:00Z"), utc("2026-11-20T17:02:00Z")])
        // Always in order, the first one the moment asked, never more than a minute apart
        let d = Timetable.timelineMoments(from: utc("2026-11-20T17:00:59Z").addingTimeInterval(0.9), count: 15)
        XCTAssertEqual(d.count, 15)
        XCTAssertEqual(d, d.sorted())
        XCTAssertEqual(Set(d).count, 15)
        XCTAssertTrue(zip(d, d.dropFirst()).allSatisfy { $1.timeIntervalSince($0) <= 60 })
        XCTAssertEqual(Timetable.timelineMoments(from: utc("2026-11-20T17:00:07Z"), count: 1), [utc("2026-11-20T17:00:07Z")])
        XCTAssertEqual(Timetable.timelineMoments(from: utc("2026-11-20T17:00:07Z"), count: 0), [])
    }

    func testScheduledTimesOnDSTDays() {
        // A train at 08:00:00 in the timetable is 8 AM local on November 1 (13:00Z standard time), not 7 or 9
        let nov1 = Timetable.serviceDayStart(20261101, in: Timetable.timeZone)!.addingTimeInterval(8 * 3600)
        XCTAssertEqual(nov1, utc("2026-11-01T13:00:00Z"))
        let c = Timetable.calendar(in: Timetable.timeZone).dateComponents([.hour, .minute], from: nov1)
        XCTAssertEqual(c.hour, 8)
        XCTAssertEqual(c.minute, 0)
        // March 8 08:00 is 12:00Z in DST
        let mar8 = Timetable.serviceDayStart(20260308, in: Timetable.timeZone)!.addingTimeInterval(8 * 3600)
        XCTAssertEqual(Timetable.calendar(in: Timetable.timeZone).component(.hour, from: mar8), 8)
        XCTAssertEqual(mar8, utc("2026-03-08T12:00:00Z"))
        // Trains past midnight (25:30:00 = 1:30 the next day): October 31's trip lands at 1:30 AM on November 1 (the DST occurrence)
        let late = Timetable.serviceDayStart(20261031, in: Timetable.timeZone)!.addingTimeInterval(25.5 * 3600)
        XCTAssertEqual(late, utc("2026-11-01T05:30:00Z"))
    }

    func testDayNumberAndWeekdayAroundDST() {
        // 1:30 AM occurs twice (DST first, then standard time); both count as November 1
        XCTAssertEqual(Timetable.dayNumber(utc("2026-11-01T05:30:00Z"), in: Timetable.timeZone), 20261101)
        XCTAssertEqual(Timetable.dayNumber(utc("2026-11-01T06:30:00Z"), in: Timetable.timeZone), 20261101)
        // 11:30 PM standard time on November 1 is still November 1
        XCTAssertEqual(Timetable.dayNumber(utc("2026-11-02T04:30:00Z"), in: Timetable.timeZone), 20261101)
        XCTAssertEqual(Timetable.weekday(20261101), 6)   // Sunday
        XCTAssertEqual(Timetable.weekday(20260308), 6)
        XCTAssertEqual(Timetable.weekday(20261102), 0)   // Monday
    }

    /// The same day math in other time zones (an area or an operator elsewhere): Los Angeles, Tokyo (no daylight saving time) and
    /// Sydney (summer time from October to April, the other way round from New York's)
    func testDaysInOtherTimeZones() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let sydney = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        // Los Angeles falls back on November 1 too, three hours later than New York
        XCTAssertEqual(Timetable.serviceDayStart(20261101, in: losAngeles), utc("2026-11-01T08:00:00Z"))
        XCTAssertEqual(Timetable.serviceDayStart(20261031, in: losAngeles), utc("2026-10-31T07:00:00Z"))
        // Tokyo: every day starts at midnight, nine hours ahead
        XCTAssertEqual(Timetable.serviceDayStart(20261101, in: tokyo), utc("2026-10-31T15:00:00Z"))
        XCTAssertEqual(Timetable.serviceDayStart(20270314, in: tokyo), utc("2027-03-13T15:00:00Z"))
        // Sydney springs forward on October 4, 2026 (noon is summer time, so the day starts at 11 PM the night before) and falls back
        // on April 4, 2027 (the day starts at 1 AM summer time)
        XCTAssertEqual(Timetable.serviceDayStart(20261004, in: sydney), utc("2026-10-03T13:00:00Z"))
        XCTAssertEqual(Timetable.serviceDayStart(20270404, in: sydney), utc("2027-04-03T14:00:00Z"))
        // A boat at 25:30:00 on Saturday April 3 leaves at 1:30 AM summer time on Sunday; Sunday's at 1:30 AM standard time on Monday
        let saturday = try XCTUnwrap(Timetable.serviceDayStart(20270403, in: sydney)).addingTimeInterval(25.5 * 3600)
        XCTAssertEqual(saturday, utc("2027-04-03T14:30:00Z"))
        XCTAssertEqual(Timetable.dayNumber(saturday, in: sydney), 20270404)
        XCTAssertEqual(Timetable.previousDay(saturday, in: sydney), 20270403)
        let sunday = try XCTUnwrap(Timetable.serviceDayStart(20270404, in: sydney)).addingTimeInterval(25.5 * 3600)
        XCTAssertEqual(sunday, utc("2027-04-04T15:30:00Z"))

        // One moment, three dates: 4 PM UTC on October 31 is November 1 in Tokyo and Sydney, still October 31 in New York and Los Angeles
        let moment = utc("2026-10-31T16:00:00Z")
        XCTAssertEqual(Timetable.dayNumber(moment, in: tokyo), 20261101)
        XCTAssertEqual(Timetable.dayNumber(moment, in: sydney), 20261101)
        XCTAssertEqual(Timetable.dayNumber(moment, in: Timetable.timeZone), 20261031)
        XCTAssertEqual(Timetable.dayNumber(moment, in: losAngeles), 20261031)
        XCTAssertEqual(Timetable.previousDay(moment, in: tokyo), 20261031)
        // A date's next day and weekday are the same everywhere
        XCTAssertEqual(Timetable.nextDay(20261231), 20270101)
        XCTAssertEqual(Timetable.nextDay(20270228), 20270301)
        XCTAssertEqual(Timetable.nextDay(20280228), 20280229)
        XCTAssertEqual(Timetable.weekday(20270404), 6)   // Sunday
    }
}
