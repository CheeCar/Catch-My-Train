import XCTest
@testable import TransitCore

/// The log of the last data updates (DataChangeLog) and the gate an update goes through (DataUpdateGate)
final class DataChangeLogTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let limits = DataJudgement.Limits(kept: 0.70, countChange: 0.30, slack: 2)

    /// Ten stops on two lines: A serves s0...s4, B serves s5...s9
    func listing(stops: Int = 10, renamed: [Int: String] = [:]) -> DataListing {
        var l = DataListing()
        for i in 0..<stops {
            l.stops["s\(i)"] = renamed[i] ?? "Stop \(i)"
            l.routeStops[i < 5 ? "A" : "B", default: []].insert("s\(i)")
        }
        l.routes = ["A": "Line A", "B": "Line B"].filter { route, _ in l.routeStops[route] != nil }
        return l
    }

    func testTheSameDataIsTakenAndLoggedAsSame() {
        let d = DataUpdateGate.decide(key: "f", old: listing(), new: listing(), limits: limits, previous: nil, now: now)
        XCTAssertTrue(d.take)
        XCTAssertEqual(d.entry?.outcome, .same)
        XCTAssertEqual(d.entry?.count, 0)
        XCTAssertEqual(d.entry?.key, "f")
        XCTAssertEqual(d.entry?.checkedAt, now)
    }

    func testAChangeIsTakenWithItsChanges() {
        let d = DataUpdateGate.decide(key: "f", old: listing(), new: listing(renamed: [3: "Main St"]), limits: limits, previous: nil, now: now)
        XCTAssertTrue(d.take)
        XCTAssertEqual(d.entry?.outcome, .changed)
        XCTAssertEqual(d.entry?.changes.renamedStops, [DataChanges.Rename(id: "s3", from: "Stop 3", to: "Main St")])
        XCTAssertEqual(d.entry?.count, 1)
        XCTAssertNil(d.entry?.reason)
    }

    /// The first data there is, and data with no stops at all
    func testNothingToCompareWith() {
        let first = DataUpdateGate.decide(key: "f", old: nil, new: listing(), limits: limits, previous: nil, now: now)
        XCTAssertTrue(first.take)
        XCTAssertNil(first.entry)
        let fromEmpty = DataUpdateGate.decide(key: "f", old: DataListing(), new: listing(), limits: limits, previous: nil, now: now)
        XCTAssertTrue(fromEmpty.take)
        XCTAssertNil(fromEmpty.entry)
        let empty = DataUpdateGate.decide(key: "f", old: listing(), new: DataListing(), limits: limits, previous: nil, now: now)
        XCTAssertFalse(empty.take)
        XCTAssertEqual(empty.entry?.outcome, .kept)
        XCTAssertEqual(empty.entry?.reason, .empty)
    }

    /// Half the stops gone (a file cut short) isn't taken; the log says what it would have changed, and since when
    func testDataThatLooksWrongIsKeptOut() {
        let d = DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 5), limits: limits, previous: nil, now: now)
        XCTAssertFalse(d.take)
        XCTAssertEqual(d.entry?.outcome, .kept)
        XCTAssertEqual(d.entry?.reason, .stopsGone)
        XCTAssertEqual(d.entry?.changes.removedRoutes.map(\.route.id), ["B"])
        XCTAssertEqual(d.entry?.count, 6)
        XCTAssertEqual(d.entry?.waitingSince, now)
        XCTAssertEqual(d.entry?.waitingFingerprint, listing(stops: 5).fingerprint)
    }

    /// The very same data that looked wrong, coming for a week, is meant: it's taken then. Other data starts the wait again
    func testTheSameDataForAWeekIsTaken() throws {
        let cut = listing(stops: 5)
        let first = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: nil, now: now).entry)
        let day = 86_400.0
        let sixDays = DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: first,
                                            now: now.addingTimeInterval(6 * day))
        XCTAssertFalse(sixDays.take)
        XCTAssertEqual(sixDays.entry?.waitingSince, now, "the wait goes on from the first day")
        let week = DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: sixDays.entry,
                                         now: now.addingTimeInterval(7 * day))
        XCTAssertTrue(week.take)
        XCTAssertEqual(week.entry?.outcome, .takenAfterWaiting)
        XCTAssertEqual(week.entry?.reason, .stopsGone)
        XCTAssertEqual(week.entry?.changes.removedRoutes.map(\.route.id), ["B"])
        XCTAssertNil(week.entry?.waitingSince)
        // Different data that also looks wrong waits a week of its own
        let other = DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 4), limits: limits, previous: sixDays.entry,
                                          now: now.addingTimeInterval(7 * day))
        XCTAssertFalse(other.take)
        XCTAssertEqual(other.entry?.waitingSince, now.addingTimeInterval(7 * day))
        // After a good update in between, the wait starts again too
        let good = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(), limits: limits, previous: sixDays.entry,
                                                       now: now.addingTimeInterval(6.5 * day)).entry)
        XCTAssertFalse(DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: good,
                                             now: now.addingTimeInterval(7 * day)).take)
        // Data with no stops is never taken, however long it comes
        let none = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: DataListing(), limits: limits, previous: nil,
                                                       now: now).entry)
        let weekOfNone = DataUpdateGate.decide(key: "f", old: listing(), new: DataListing(), limits: limits, previous: none,
                                               now: now.addingTimeInterval(8 * day))
        XCTAssertFalse(weekOfNone.take)
        XCTAssertEqual(weekOfNone.entry?.reason, .empty)
    }

    /// Data kept out is downloaded again the next day, not the next month
    func testKeptDataIsCheckedAgainTheNextDay() {
        let kept = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .countJump)
        XCTAssertFalse(kept.wantsRecheck(now: now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(kept.wantsRecheck(now: now.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .changed).wantsRecheck(now: now.addingTimeInterval(48 * 3600)))
    }

    /// The lists are cut to keep the file small; the counts are of everything
    func testLongListsAreCut() {
        var old = DataListing(), new = DataListing()
        for i in 0..<200 { old.stops["s\(i)"] = "Stop \(i)"; new.stops["s\(i)"] = "Stop \(i)" }
        for i in 0..<60 { new.stops["n\(i)"] = "New \(i)" }
        let entry = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .changed, changes: DataChanges.between(old: old, new: new))
        XCTAssertEqual(entry.changes.addedStops.count, DataChangeLog.listLimit)
        XCTAssertEqual(entry.count, 60)
        XCTAssertEqual(entry.lines, 60)
    }

    func testFingerprintIsTheListings() {
        XCTAssertEqual(listing().fingerprint, listing().fingerprint)
        XCTAssertNotEqual(listing().fingerprint, listing(renamed: [0: "Other"]).fingerprint)
        XCTAssertNotEqual(listing().fingerprint, listing(stops: 9).fingerprint)
        var moved = listing()
        moved.routeStops["A"]?.remove("s4")
        moved.routeStops["B"]?.insert("s4")
        XCTAssertNotEqual(listing().fingerprint, moved.fingerprint)
        // The same on every launch: a fixed value for a fixed listing
        XCTAssertEqual(DataListing(stops: ["a": "A"]).fingerprint, DataListing(stops: ["a": "A"]).fingerprint)
        XCTAssertFalse(DataListing().fingerprint.isEmpty)
    }

    /// Kept for 90 days; read back as written; a broken file is an empty log
    func testTheFile() throws {
        let changed = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .changed,
                                          changes: DataChanges.between(old: listing(), new: listing(renamed: [1: "X"])))
        let kept = DataChangeLog.Entry(key: "g", checkedAt: now.addingTimeInterval(-91 * 86_400), outcome: .kept, reason: .empty)
        let log = DataChangeLog(entries: ["f": changed, "g": kept])
        XCTAssertEqual(DataChangeLog.decode(try log.encoded()), log)
        XCTAssertEqual(log.pruned(now: now).entries.keys.sorted(), ["f"])
        XCTAssertEqual(log.kept.map(\.key), ["g"])
        XCTAssertEqual(DataChangeLog.decode(Data("not json".utf8)), DataChangeLog())
        XCTAssertEqual(DataChangeLog.decode(nil), DataChangeLog())
    }

    func testRecordKeepsTheOtherOperators() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmt-log-\(UUID().uuidString)")
        let saved = StaticData.directory
        StaticData.directory = dir
        defer {
            StaticData.directory = saved
            try? FileManager.default.removeItem(at: dir)
        }
        DataChangeLog.record(DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .same), for: "f", now: now)
        DataChangeLog.record(DataChangeLog.Entry(key: "g", checkedAt: now, outcome: .kept, reason: .stopsGone), for: "g", now: now)
        XCTAssertEqual(DataChangeLog.load(now: now).entries.keys.sorted(), ["f", "g"])
        DataChangeLog.record(nil, for: "f", now: now)
        XCTAssertEqual(DataChangeLog.load(now: now).entries.keys.sorted(), ["g"])
        XCTAssertEqual(DataChangeLog.load(now: now.addingTimeInterval(91 * 86_400)).entries, [:])
    }

    /// A store's file holds several operators: each is checked on its own; the one whose new data looks wrong keeps its old data,
    /// the others take the new
    func testEachOperatorOfAStoreIsCheckedOnItsOwn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmt-log-\(UUID().uuidString)")
        let saved = StaticData.directory
        StaticData.directory = dir
        defer {
            StaticData.directory = saved
            try? FileManager.default.removeItem(at: dir)
        }
        func pier(_ id: String, _ name: String) -> FerryFeed.Pier { FerryFeed.Pier(id: id, name: name, lat: 40.7, lon: -74.0) }
        func trip(_ id: String, _ route: String, _ stops: [String]) -> FerryFeed.Trip {
            FerryFeed.Trip(id: id, route: route, service: "s", direction: "N", stops: stops, times: stops.indices.map { 25_200 + $0 * 120 })
        }
        let nyfPiers = (1...8).map { pier("nyf:\($0)", "Pier \($0)") }
        let old = FerryFeed(versions: ["nyf": "20261101", "nyw": "20261101"],
                            routes: [.init(id: "NYF-ER", name: "East River", color: "0077C8", realtime: true),
                                     .init(id: "NYW", name: "NY Waterway", color: "C8102E", realtime: true)],
                            piers: nyfPiers + [pier("nyw:1", "Hoboken"), pier("nyw:2", "Weehawken")],
                            trips: [trip("nyf:t1", "NYF-ER", nyfPiers.map(\.id)), trip("nyw:t1", "NYW", ["nyw:1", "nyw:2"])],
                            services: [:], shapes: [:])
        // NYC Ferry's new file has two of its eight piers left (cut short); NY Waterway renamed a pier
        var new = old
        new.versions = ["nyf": "20261201", "nyw": "20261201"]
        new.piers = Array(nyfPiers.prefix(2)) + [pier("nyw:1", "Hoboken Terminal"), pier("nyw:2", "Weehawken")]
        new.trips = [trip("nyf:t1", "NYF-ER", ["nyf:1", "nyf:2"]), trip("nyw:t1", "NYW", ["nyw:1", "nyw:2"])]
        let heard = Heard()
        DataChangeLog.observer = { entry in heard.add(entry.summary) }
        defer { DataChangeLog.observer = nil }
        let kept = FerryFeed.sourcesKeptOut(new: new, old: old, sources: [.nycFerry, .nyWaterway], now: now)
        XCTAssertEqual(kept, [.nycFerry])
        let log = DataChangeLog.load(now: now)
        XCTAssertEqual(log.entries["nyf"]?.outcome, .kept)
        XCTAssertEqual(log.entries["nyf"]?.reason, .stopsGone)
        XCTAssertEqual(log.entries["nyw"]?.outcome, .changed)
        XCTAssertEqual(log.entries["nyw"]?.changes.renamedStops.map(\.to), ["Hoboken Terminal"])
        let told = heard.lines
        XCTAssertEqual(told.count, 2)
        XCTAssertTrue(told.contains { $0.hasPrefix("nyf kept (stopsGone), 6 changes in 6 lines") }, "\(told)")
        // What the store keeps: NYC Ferry's old data, NY Waterway's new
        let stored = new.removing(kept).filling(missingSourcesFrom: old)
        XCTAssertEqual(Set(stored.piers.filter { $0.id.hasPrefix("nyf:") }.map(\.id)), Set(nyfPiers.map(\.id)))
        XCTAssertEqual(stored.versions, ["nyf": "20261101", "nyw": "20261201"])
        XCTAssertTrue(stored.piers.contains { $0.name == "Hoboken Terminal" })
        // An operator not in the new data (its download failed) isn't checked; the first data there is is taken
        var onlyNYW = new.removing([.nycFerry])
        onlyNYW.versions["nyw"] = "20261202"
        XCTAssertEqual(FerryFeed.sourcesKeptOut(new: onlyNYW, old: old, sources: [.nycFerry, .nyWaterway], now: now), [])
        XCTAssertEqual(FerryFeed.sourcesKeptOut(new: new, old: nil, sources: [.nycFerry, .nyWaterway], now: now), [])
        XCTAssertEqual(FerryFeed.sourcesKeptOut(new: new, old: old.removing([.nycFerry]), sources: [.nycFerry], now: now), [])
    }

    /// A regional bus operator's data: its stops, its lines by their short names, the stops of each line
    func testARegionalBusListing() throws {
        func d(_ s: String) -> Data { Data(s.utf8) }
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,route_short_name,route_long_name,route_type,route_color
            7,n6,Hempstead - Jamaica,3,00539B
            8,n4,Freeport - Jamaica,3,00539B
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
            S1,Hempstead Transit Center,40.7069,-73.6171,0,
            S2,Franklin Av,40.7060,-73.6300,,
            S3,Jamaica Center,40.7020,-73.8010,0,
            S4,Freeport,40.6576,-73.5832,0,
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            7,WK,T1,Jamaica,0,
            8,WK,T2,Jamaica,0,
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            T1,12:10:00,12:10:00,S1,1
            T1,12:14:00,12:14:00,S2,2
            T1,12:50:00,12:50:00,S3,3
            T2,12:00:00,12:00:00,S4,1
            T2,12:40:00,12:40:00,S3,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            WK,1,1,1,1,1,0,0,20260901,20261231
            """),
        ]
        let nice = try XCTUnwrap(RegionalBusFeed.feed(code: "NICE"))
        let built = Date(timeIntervalSince1970: 1_791_993_600)
        let file = try NJBusBuilder.build(files: files, now: built, feed: nice)
        let index = try NJBusIndex(data: file, feed: nice)
        let listing = DataListing(index)
        // The stored file read for its listing only reads the same, and a file cut short isn't read
        XCTAssertEqual(try DataListing(busFile: file), listing)
        XCTAssertThrowsError(try DataListing(busFile: file.prefix(40)))
        XCTAssertThrowsError(try DataListing(busFile: Data("CMNX".utf8) + file.dropFirst(4)))
        XCTAssertEqual(Set(listing.stops.values), ["Hempstead Transit Center", "Franklin Av", "Jamaica Center", "Freeport"])
        XCTAssertEqual(Set(listing.routes.values), ["n6", "n4"])
        XCTAssertEqual(listing.routeStops["n6"]?.count, 3)
        XCTAssertEqual(listing.routeStops["n4"]?.count, 2)
        XCTAssertEqual(listing.routeStops["n6"]?.intersection(listing.routeStops["n4"] ?? []).count, 1, "Jamaica Center on both")
        XCTAssertEqual(listing.places.count, 4)
    }

    /// The same data downloaded again doesn't hide the last changes; anything else takes the entry's place
    func testTheLastChangesStayUntilTheDataChangesAgain() {
        let changed = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .changed, changes: DataChanges.between(old: listing(), new: listing(stops: 9)))
        let log = DataChangeLog(entries: ["f": changed])
        let same = DataChangeLog.Entry(key: "f", checkedAt: now.addingTimeInterval(3600), outcome: .same)
        XCTAssertFalse(log.keeps(same, for: "f"))
        XCTAssertTrue(log.keeps(same, for: "g"), "another operator")
        XCTAssertTrue(log.keeps(DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .changed), for: "f"))
        XCTAssertTrue(log.keeps(DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .stopsGone), for: "f"))
        XCTAssertTrue(log.keeps(nil, for: "f"))
        let kept = DataChangeLog(entries: ["f": DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .countJump)])
        XCTAssertTrue(kept.keeps(same, for: "f"), "good data again: the problem is gone")
        let waited = DataChangeLog(entries: ["f": DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .takenAfterWaiting, reason: .stopsGone)])
        XCTAssertFalse(waited.keeps(same, for: "f"))
    }

    /// What Settings tells of one mode: the latest update, its changes, and the operators held back
    func testTheNewsOfAMode() {
        let day = 86_400.0
        let log = DataChangeLog(entries: [
            "a": DataChangeLog.Entry(key: "a", checkedAt: now, outcome: .same),
            "b": DataChangeLog.Entry(key: "b", checkedAt: now.addingTimeInterval(-day), outcome: .changed,
                                     changes: DataChanges.between(old: listing(), new: listing(stops: 9))),
            "c": DataChangeLog.Entry(key: "c", checkedAt: now.addingTimeInterval(day), outcome: .kept, reason: .stopsGone),
            "d": DataChangeLog.Entry(key: "d", checkedAt: now.addingTimeInterval(-2 * day), outcome: .takenAfterWaiting,
                                     reason: .countJump, changes: DataChanges.between(old: listing(), new: listing(stops: 4))),
            "other": DataChangeLog.Entry(key: "other", checkedAt: now.addingTimeInterval(2 * day), outcome: .changed),
        ])
        let news = log.news(of: ["a", "b", "c", "d"])
        XCTAssertEqual(news.latest, now, "a kept update isn't an update, and other modes don't count")
        XCTAssertEqual(news.changed.map(\.key), ["b", "d"])
        XCTAssertEqual(news.count, 1 + 7)
        XCTAssertEqual(news.kept.map(\.key), ["c"])
        XCTAssertEqual(log.news(of: ["c"]).latest, nil)
        XCTAssertEqual(DataChangeLog().news(of: ["a"]), DataChangeLog.News(latest: nil, changed: [], count: 0, kept: []))
    }

    /// Report an Issue…: the release repository's new issue page, with the versions, the operator, the problem and the day,
    /// an operator's "&" kept in its text, and nothing else
    func testTheIssuePage() throws {
        let entry = DataChangeLog.Entry(key: "bus:", checkedAt: now, outcome: .kept, reason: .stopsGone,
                                        changes: DataChanges.between(old: listing(), new: listing(stops: 3)),
                                        waitingSince: now.addingTimeInterval(-2 * 86_400))
        let url = IssueReport.dataProblem(entry, appVersion: "2.1.0", macOS: "27.2.1")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "github.com")
        XCTAssertEqual(parts.path, "/" + UpdateCheck.Channel.release.repository + "/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(items.keys), ["title", "body"])
        XCTAssertEqual(items["title"], "Data problem: NJ Transit")
        XCTAssertEqual(items["body"], """
            App version: 2.1.0
            macOS: 27.2.1
            Operator: NJ Transit (bus:)
            Problem: the new data looks incomplete (most stops gone)
            Since: 2027-01-13
            Changes the new data would make: 8

            """)
        // With the live data still showing served what it leaves out
        var seen = entry
        seen.missing = DataWitness.Missing(stops: ["s4"], routes: [], liveSeenAt: now.addingTimeInterval(-86_400))
        let withLive = try XCTUnwrap(URLComponents(url: IssueReport.dataProblem(seen, appVersion: "2.1.0", macOS: "27.2.1"),
                                                   resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(withLive.hasSuffix("""
            Changes the new data would make: 8
            Live data: still shows trips at stops or lines missing from the new data (last seen 2027-01-14)

            """), withLive)
        XCTAssertEqual(IssueReport.encoded("Prudence & Bay+Islands = 1/2?"), "Prudence%20%26%20Bay%2BIslands%20%3D%201%2F2%3F")
        XCTAssertLessThan(url.absoluteString.count, 1000)
        XCTAssertEqual(DataChangeLog.operatorName(of: "subway"), "MTA subway")
        XCTAssertEqual(DataChangeLog.operatorName(of: "nyf"), FerryFeed.Source.nycFerry.name)
        XCTAssertEqual(DataChangeLog.operatorName(of: "bus:NICE"), RegionalBusFeed.feed(code: "NICE")?.name)
        XCTAssertEqual(DataChangeLog.operatorName(of: "unknown"), "unknown")
    }

    /// An entry is kept 90 days after its check, then dropped
    func testOldEntriesAreDropped() {
        let log = DataChangeLog(entries: [
            "old": DataChangeLog.Entry(key: "old", checkedAt: now.addingTimeInterval(-91 * 86_400), outcome: .same),
            "recent": DataChangeLog.Entry(key: "recent", checkedAt: now.addingTimeInterval(-89 * 86_400), outcome: .changed),
        ])
        XCTAssertEqual(log.pruned(now: now).entries.keys.sorted(), ["recent"])
    }

    /// An operator whose new data wasn't taken waits a day (not 10 minutes) before it's downloaded again, isn't counted as a failed
    /// download, and the month isn't checked for it yet
    func testAHeldOperatorIsDownloadedAgainTheNextDay() {
        var check = MonthlyCheck()
        let all: Set<String> = ["nyf", "nyw"]
        XCTAssertFalse(check.refreshed(["nyw"], of: all, lastChecked: nil, now: now))
        check.held(["nyf"], now: now)
        XCTAssertFalse(check.hasFailures)
        XCTAssertEqual(check.remaining(of: all, lastChecked: nil, now: now.addingTimeInterval(3600)), [])
        XCTAssertEqual(check.remaining(of: all, lastChecked: nil, now: now.addingTimeInterval(23 * 3600)), [])
        XCTAssertEqual(check.remaining(of: all, lastChecked: nil, now: now.addingTimeInterval(24 * 3600)), ["nyf"])
        // A failed download still counts as one, and waits 10 minutes
        check.failed(["nyw"], now: now)
        XCTAssertTrue(check.hasFailures)
        XCTAssertFalse(check.canRetry("nyw", now: now.addingTimeInterval(599)))
        XCTAssertTrue(check.canRetry("nyw", now: now.addingTimeInterval(600)))
        // Taken the next day: the month is checked
        XCTAssertTrue(check.refreshed(["nyf", "nyw"], of: all, lastChecked: nil, now: now.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(check.hasFailures)
    }

    // MARK: The live data as a witness (DataWitness)

    func departure(_ station: String, _ route: String, source: ArrivalSource = .realtime, status: TripStatus = .normal,
                   assigned: Bool? = nil) -> Arrival {
        Arrival(id: station + route, stationID: station, route: route, direction: Direction(code: "N", name: "North"),
                arrivalTime: now, source: source, status: status, updatedAt: now, isAssigned: assigned)
    }

    /// Kept data's entry notes what it leaves out, all of it (its lists are cut at 50): the stops gone alone and with their
    /// line, and the lines gone
    func testKeptDataNotesAllItLeavesOut() throws {
        var old = DataListing(), new = DataListing()
        for i in 0..<200 {
            old.stops["s\(i)"] = "Stop \(i)"
            old.routeStops[i < 100 ? "A" : "B", default: []].insert("s\(i)")
            if i < 60 { new.stops["s\(i)"] = "Stop \(i)"; new.routeStops["A", default: []].insert("s\(i)") }
        }
        old.routes = ["A": "Line A", "B": "Line B"]
        new.routes = ["A": "Line A"]
        let entry = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: old, new: new, limits: limits, previous: nil, now: now).entry)
        XCTAssertEqual(entry.outcome, .kept)
        let missing = try XCTUnwrap(entry.missing)
        XCTAssertEqual(missing.stops.count, 140)
        XCTAssertEqual(Set(missing.stops), Set((60..<200).map { "s\($0)" }))
        XCTAssertEqual(missing.routes, ["B"])
        XCTAssertNil(missing.liveSeenAt)
        XCTAssertEqual(entry.changes.removedStops.count, 40)
        XCTAssertEqual(entry.changes.removedRoutes.first?.stops.count, DataChangeLog.listLimit, "the entry's own lists are still cut")
        // Taken or the same: nothing is left out
        XCTAssertNil(DataUpdateGate.decide(key: "f", old: old, new: old, limits: limits, previous: nil, now: now).entry?.missing)
        // At most missingLimit stops
        var many = DataChanges()
        many.removedStops = (0..<(DataWitness.missingLimit + 5)).map { DataChanges.Item(id: "x\($0)", name: "X") }
        XCTAssertEqual(DataWitness.Missing(many).stops.count, DataWitness.missingLimit)
    }

    /// Live data showing served what the same data leaves out keeps it out after its week, until the live data has been quiet
    /// for quietDays; live data that showed nothing leaves the week alone to decide; other data starts with nothing seen
    func testLiveDataStillShowingItServedKeepsItOut() throws {
        let cut = listing(stops: 5)
        let day = 86_400.0
        let first = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: nil, now: now).entry)
        // Seen served on day 6
        let log = try XCTUnwrap(DataChangeLog(entries: ["f": first]).notingLive(for: "f", fingerprint: cut.fingerprint,
                                                                                    now: now.addingTimeInterval(6 * day)))
        let seen = try XCTUnwrap(log.entries["f"])
        XCTAssertEqual(seen.missing?.liveSeenAt, now.addingTimeInterval(6 * day))
        let week = DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: seen,
                                         now: now.addingTimeInterval(7 * day))
        XCTAssertFalse(week.take, "seen a day ago")
        XCTAssertEqual(week.entry?.outcome, .kept)
        XCTAssertEqual(week.entry?.waitingSince, now)
        XCTAssertEqual(week.entry?.missing?.liveSeenAt, now.addingTimeInterval(6 * day), "carried over")
        let eightDays = DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: week.entry,
                                              now: now.addingTimeInterval(8.99 * day))
        XCTAssertFalse(eightDays.take, "seen a little less than three days ago")
        let nineDays = DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: eightDays.entry,
                                             now: now.addingTimeInterval(9 * day))
        XCTAssertTrue(nineDays.take, "quiet for three days")
        XCTAssertEqual(nineDays.entry?.outcome, .takenAfterWaiting)
        XCTAssertNil(nineDays.entry?.missing)
        // Other data that looks wrong starts with nothing seen
        let other = DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 4), limits: limits, previous: week.entry,
                                          now: now.addingTimeInterval(7 * day))
        XCTAssertFalse(other.take)
        XCTAssertNil(other.entry?.missing?.liveSeenAt)
        XCTAssertEqual(other.entry?.waitingSince, now.addingTimeInterval(7 * day))
        XCTAssertTrue(DataWitness.stillServed(lastSeen: now, now: now.addingTimeInterval(3 * day - 1)))
        XCTAssertFalse(DataWitness.stillServed(lastSeen: now, now: now.addingTimeInterval(3 * day)))
        XCTAssertFalse(DataWitness.stillServed(lastSeen: nil, now: now))
    }

    /// A sighting is noted only on the entry kept out for that same data, and at most hourly
    func testASightingIsNotedOnlyOnItsOwnData() throws {
        let cut = listing(stops: 5)
        let first = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: cut, limits: limits, previous: nil, now: now).entry)
        let log = DataChangeLog(entries: ["f": first, "g": DataChangeLog.Entry(key: "g", checkedAt: now, outcome: .changed)])
        XCTAssertNil(log.notingLive(for: "f", fingerprint: listing(stops: 4).fingerprint, now: now), "other data")
        XCTAssertNil(log.notingLive(for: "g", fingerprint: cut.fingerprint, now: now), "not kept out")
        XCTAssertNil(log.notingLive(for: "h", fingerprint: cut.fingerprint, now: now), "no entry")
        let noted = try XCTUnwrap(log.notingLive(for: "f", fingerprint: cut.fingerprint, now: now))
        XCTAssertEqual(noted.entries["g"], log.entries["g"], "the others stay")
        XCTAssertNil(noted.notingLive(for: "f", fingerprint: cut.fingerprint, now: now.addingTimeInterval(3599)))
        let later = try XCTUnwrap(noted.notingLive(for: "f", fingerprint: cut.fingerprint, now: now.addingTimeInterval(3600)))
        XCTAssertEqual(later.entries["f"]?.missing?.liveSeenAt, now.addingTimeInterval(3600))
        // Kept out with no list of what it leaves out (written before there was one): nothing to note
        XCTAssertNil(DataChangeLog(entries: ["f": DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .stopsGone,
                                                                       waitingFingerprint: cut.fingerprint)])
            .notingLive(for: "f", fingerprint: cut.fingerprint, now: now))
    }

    /// The file: written before the list existed it reads with none; with it, it reads back the same
    func testTheFileWithWhatIsLeftOut() throws {
        let entry = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .stopsGone, waitingSince: now,
                                        waitingFingerprint: "abc",
                                        missing: DataWitness.Missing(stops: ["s1"], routes: ["B"], liveSeenAt: now))
        let log = DataChangeLog(entries: ["f": entry])
        XCTAssertEqual(DataChangeLog.decode(try log.encoded()), log)
        var plain = entry
        plain.missing = nil
        let old = String(decoding: try DataChangeLog(entries: ["f": plain]).encoded(), as: UTF8.self)
        XCTAssertFalse(old.contains("missing"))
        XCTAssertEqual(DataChangeLog.decode(Data(old.utf8)).entries["f"], plain)
        XCTAssertTrue(entry.summary.hasSuffix(", live data showed it served 2027-01-15T08:00:00Z"), entry.summary)
    }

    /// Whose live departure it is, by the ids of its operator's data
    func testWhoseDepartureItIs() throws {
        let subway = try XCTUnwrap(DataWitness.owner(of: departure("635", "6X"), mode: .subway))
        XCTAssertEqual(subway.key, "subway")
        XCTAssertEqual(subway.stop, "635")
        XCTAssertEqual(subway.route, "6")
        let cityBus = try XCTUnwrap(DataWitness.owner(of: departure("308209", "B63"), mode: .bus))
        XCTAssertEqual([cityBus.key, cityBus.stop, cityBus.route], ["bus", "308209", "B63"])
        let njt = try XCTUnwrap(DataWitness.owner(of: departure("njb:31858", "NJB-107"), mode: .bus))
        XCTAssertEqual([njt.key, njt.stop, njt.route], ["bus:", "31858", "107"])
        let ctt = try XCTUnwrap(DataWitness.owner(of: departure("njb:CTT/1234", "NJB-CTT/41"), mode: .bus))
        XCTAssertEqual([ctt.key, ctt.stop, ctt.route], ["bus:CTT", "1234", "41"])
        let ferry = try XCTUnwrap(DataWitness.owner(of: departure("nyf:87", "nyf:ER"), mode: .ferry))
        XCTAssertEqual([ferry.key, ferry.stop, ferry.route], ["nyf", "nyf:87", "nyf:ER"])
        let lirr = try XCTUnwrap(DataWitness.owner(of: departure("lirr:102", "LIRR-1"), mode: .train))
        XCTAssertEqual([lirr.key, lirr.stop, lirr.route], ["lirr", "lirr:102", "LIRR-1"])
        XCTAssertNil(DataWitness.owner(of: departure("RIT", "TRAM"), mode: .train))
        // The live ones only: not the timetable's, not a trip without a train yet, not cancelled
        let seen = DataWitness.seen(in: [
            departure("635", "6X", assigned: true), departure("631", "4", source: .scheduled),
            departure("629", "6", assigned: false), departure("640", "5", status: .cancelled), departure("A27", "A"),
            departure("x", "Q", source: .mock), departure("njb:CTT/1234", "NJB-CTT/41"),
        ], mode: .subway)
        XCTAssertEqual(seen["subway"], DataWitness.Seen(stops: ["635", "A27"], routes: ["6", "A"]))
        XCTAssertEqual(seen["bus:CTT"], DataWitness.Seen(stops: ["1234"], routes: ["41"]))
        XCTAssertEqual(seen.count, 2)
    }

    /// Only live departures still fresh are a sighting, at the time they were updated: the same old ones shown again after
    /// downloads failed don't move the time on; new ones do. Data times are the trains' (ClockSkew)
    func testOldDeparturesShownAgainAreNotANewSighting() throws {
        func live(_ station: String, updated: Date) -> Arrival {
            Arrival(id: station, stationID: station, route: "A", direction: Direction(code: "N", name: "North"),
                    arrivalTime: updated, source: .realtime, status: .normal, updatedAt: updated)
        }
        let shown = [live("A27", updated: now), live("A28", updated: now - 50)]
        let first = try XCTUnwrap(DataWitness.sighting(in: shown, mode: .subway, staleAfter: 120, clockOffset: 0, now: now + 10))
        XCTAssertEqual(first.at, now)
        XCTAssertEqual(first.seen["subway"], DataWitness.Seen(stops: ["A27", "A28"], routes: ["A"]))
        // Shown again a minute later: the same time; past staleAfter, none
        XCTAssertEqual(DataWitness.sighting(in: shown, mode: .subway, staleAfter: 120, clockOffset: 0, now: now + 60)?.at, now)
        XCTAssertEqual(DataWitness.sighting(in: shown, mode: .subway, staleAfter: 120, clockOffset: 0, now: now + 100)?.seen["subway"]?.stops,
                       ["A27"])
        XCTAssertNil(DataWitness.sighting(in: shown, mode: .subway, staleAfter: 120, clockOffset: 0, now: now + 121))
        // Two hours of the same old ones: never noted again; new ones are
        let log = try XCTUnwrap(DataChangeLog(entries: ["subway": DataChangeLog.Entry(
            key: "subway", checkedAt: now, outcome: .kept, reason: .stopsGone, waitingFingerprint: "p",
            missing: DataWitness.Missing(stops: ["A27"], routes: []))]).notingLive(for: "subway", fingerprint: "p", now: first.at))
        let replayed = DataWitness.sighting(in: shown, mode: .subway, staleAfter: 120, clockOffset: 0, now: now + 7200)
        XCTAssertNil(replayed)
        let fresh = try XCTUnwrap(DataWitness.sighting(in: [live("A27", updated: now + 7190)], mode: .subway, staleAfter: 120,
                                                       clockOffset: 0, now: now + 7200))
        XCTAssertEqual(fresh.at, now + 7190)
        XCTAssertEqual(log.notingLive(for: "subway", fingerprint: "p", now: fresh.at)?.entries["subway"]?.missing?.liveSeenAt, now + 7190)
        // The trains' clock 60 seconds ahead of this Mac: fresh by the trains' time, noted in this Mac's; never later than now
        let ahead = try XCTUnwrap(DataWitness.sighting(in: [live("A27", updated: now + 60)], mode: .subway, staleAfter: 120,
                                                       clockOffset: 60, now: now + 5))
        XCTAssertEqual(ahead.at, now)
        XCTAssertEqual(DataWitness.sighting(in: [live("A27", updated: now + 30)], mode: .subway, staleAfter: 120, clockOffset: 0,
                                            now: now)?.at, now)
        // Not live: none
        XCTAssertNil(DataWitness.sighting(in: [departure("A27", "A", source: .scheduled)], mode: .subway, staleAfter: 120,
                                          clockOffset: 0, now: now))
    }

    /// How much of what's left out the live data shows served: stops and lines; the subway's lines by their live name
    func testWhatTheLiveDataShows() {
        func kept(_ key: String, stops: [String], routes: [String]) -> DataChangeLog.Entry {
            DataChangeLog.Entry(key: key, checkedAt: now, outcome: .kept, reason: .stopsGone,
                                missing: DataWitness.Missing(stops: stops, routes: routes))
        }
        let seen = DataWitness.Seen(stops: ["s1", "s2", "s9"], routes: ["6", "B"])
        XCTAssertEqual(DataWitness.match(kept("f", stops: ["s1", "s2", "s3"], routes: ["C"]), seen), DataWitness.Match(stops: 2, routes: 0))
        XCTAssertEqual(DataWitness.match(kept("f", stops: ["s4"], routes: ["B"]), seen), DataWitness.Match(stops: 0, routes: 1))
        XCTAssertFalse(DataWitness.match(kept("f", stops: ["s4"], routes: ["C"]), seen).any)
        XCTAssertTrue(DataWitness.match(kept("subway", stops: [], routes: ["6X"]), seen).any)
        XCTAssertFalse(DataWitness.match(kept("f", stops: [], routes: ["6X"]), seen).any)
        XCTAssertFalse(DataWitness.match(DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept), seen).any)
    }

    /// While new data isn't used: since when (on through other data that also looks wrong), when the data in use was taken and
    /// how many stops each has; the day the data in use was taken goes on through the checks after it
    func testWhatIsInUseAndSinceWhenTheNewDataIsnt() throws {
        let day = 86_400.0
        let taken = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(renamed: [3: "Main St"]), limits: limits,
                                                        previous: nil, now: now).entry)
        XCTAssertEqual(taken.inUseSince, now)
        let kept = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 5), limits: limits, previous: taken,
                                                       now: now + day).entry)
        XCTAssertEqual(kept.outcome, .kept)
        XCTAssertEqual(kept.inUseSince, now)
        XCTAssertEqual(kept.heldSince, now + day)
        XCTAssertEqual(kept.stopsInUse, 10)
        XCTAssertEqual(kept.stopsNew, 5)
        // Other data that looks wrong too: its own week starts, the day the new data stopped being used stays
        let other = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 4), limits: limits, previous: kept,
                                                        now: now + 2 * day).entry)
        XCTAssertEqual(other.waitingSince, now + 2 * day)
        XCTAssertEqual(other.notUsedSince, now + day)
        XCTAssertEqual(other.inUseSince, now)
        XCTAssertEqual(other.stopsNew, 4)
        XCTAssertTrue(other.summary.contains(", not used since 2027-01-16T08:00:00Z, stops 10 in use, 4 new"), other.summary)
        // 14 days on, its stations say so too
        XCTAssertFalse(other.isHeldLong(now: now + 14.9 * day))
        XCTAssertTrue(other.isHeldLong(now: now + 15 * day))
        XCTAssertFalse(taken.isHeldLong(now: now + 30 * day))
        // The same data as in use again: nothing new is used, and it was taken the day it was
        let same = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(), limits: limits, previous: other,
                                                       now: now + 3 * day).entry)
        XCTAssertEqual(same.outcome, .same)
        XCTAssertEqual(same.inUseSince, now)
        XCTAssertNil(same.heldSince)
        // After it, new data that looks wrong starts a new count
        let again = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 5), limits: limits, previous: same,
                                                        now: now + 4 * day).entry)
        XCTAssertEqual(again.heldSince, now + 4 * day)
        XCTAssertEqual(again.inUseSince, now)
        // Taken after its week: taken that day
        let week = DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 5), limits: limits, previous: again,
                                         now: now + 11 * day)
        XCTAssertTrue(week.take)
        XCTAssertEqual(week.entry?.inUseSince, now + 11 * day)
        // A log written before these were kept: an entry that took data tells the day, one that found the same doesn't
        var old = taken
        old.inUseSince = nil
        XCTAssertEqual(DataUpdateGate.inUseSince(after: old), now)
        XCTAssertNil(DataUpdateGate.inUseSince(after: DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .same)))
        XCTAssertNil(DataUpdateGate.inUseSince(after: nil))
        let none = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: listing(stops: 5), limits: limits, previous: old,
                                                       now: now + day).entry)
        XCTAssertEqual(none.inUseSince, now)
        // Data with no stops: none new
        let empty = try XCTUnwrap(DataUpdateGate.decide(key: "f", old: listing(), new: DataListing(), limits: limits, previous: kept,
                                                        now: now + 2 * day).entry)
        XCTAssertEqual(empty.stopsNew, 0)
        XCTAssertEqual(empty.notUsedSince, now + day)
        // Kept in the file; a file written before has none of them
        let log = DataChangeLog(entries: ["f": other])
        XCTAssertEqual(DataChangeLog.decode(try log.encoded()).entries["f"], other)
        var plain = other
        plain.heldSince = nil; plain.inUseSince = nil; plain.stopsInUse = nil; plain.stopsNew = nil
        let written = String(decoding: try DataChangeLog(entries: ["f": plain]).encoded(), as: UTF8.self)
        XCTAssertFalse(written.contains("heldSince") || written.contains("inUseSince") || written.contains("stopsNew"))
        XCTAssertEqual(DataChangeLog.decode(Data(written.utf8)).entries["f"]?.notUsedSince, now + 2 * day)
    }

    /// The issue page says how many stops the data in use (and since when) and the new data have
    func testTheIssuePageTellsTheStops() throws {
        let entry = DataChangeLog.Entry(key: "nyf", checkedAt: now, outcome: .kept, reason: .stopsGone, waitingSince: now,
                                        heldSince: now - 2 * 86_400, inUseSince: now - 30 * 86_400, stopsInUse: 10, stopsNew: 3)
        let body = try XCTUnwrap(URLComponents(url: IssueReport.dataProblem(entry, appVersion: "2.1.0", macOS: "27.2.1"),
                                               resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("Since: 2027-01-13\n"), body)
        XCTAssertTrue(body.hasSuffix("""
            Changes the new data would make: 0
            Stops: 10 in the data in use (from 2026-12-16), 3 in the new data

            """), body)
        var unknownDay = entry
        unknownDay.inUseSince = nil
        let withoutDay = try XCTUnwrap(URLComponents(url: IssueReport.dataProblem(unknownDay, appVersion: "x", macOS: "y"),
                                                     resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(withoutDay.contains("Stops: 10 in the data in use, 3 in the new data\n"), withoutDay)
    }

    /// Which operator's data a station is in, by its key in the log
    func testWhoseStationItIs() {
        XCTAssertEqual(DataChangeLog.key(station: "635", mode: .subway), "subway")
        XCTAssertEqual(DataChangeLog.key(station: "308209", mode: .bus), "bus")
        XCTAssertEqual(DataChangeLog.key(station: "njb:31858", mode: .bus), "bus:")
        XCTAssertEqual(DataChangeLog.key(station: "njb:CTT/1234", mode: .bus), "bus:CTT")
        XCTAssertEqual(DataChangeLog.key(station: "nyf:87", mode: .ferry), "nyf")
        XCTAssertEqual(DataChangeLog.key(station: FerryFeed.Source.path.rawValue + ":26722", mode: .subway), FerryFeed.Source.path.rawValue)
        XCTAssertEqual(DataChangeLog.key(station: "lirr:102", mode: .train), "lirr")
        XCTAssertNil(DataChangeLog.key(station: "RIT", mode: .train))
        XCTAssertNil(DataChangeLog.key(station: "635", mode: .ferry))
    }

    /// What the data in use has that this version doesn't know: PATH stations the live data can't be matched to, line badges
    /// not in the table, subway stations the app's own list doesn't have
    func testWhatThisVersionDoesntKnow() throws {
        let path = FerryFeed.Source.path.rawValue
        func pier(_ id: String, _ name: String) -> FerryFeed.Pier { FerryFeed.Pier(id: id, name: name, lat: 40.7, lon: -74.0) }
        func route(_ id: String) -> FerryFeed.Route { FerryFeed.Route(id: id, name: id, color: "000000", realtime: true) }
        var feed = FerryFeed(versions: [:], routes: [], piers: [pier(path + ":1", "Hoboken"), pier(path + ":2", "Newark")],
                             trips: [], services: [:], shapes: [:])
        XCTAssertNil(UnknownData.path(feed: feed))
        XCTAssertNil(UnknownData.path(feed: feed, liveCodes: ["HOB", "NWK"]))
        feed.piers.append(pier(path + ":3", "Harrison Station"))
        feed.piers.append(pier("nyf:1", "Harrison Station"))
        XCTAssertEqual(UnknownData.path(feed: feed, liveCodes: ["HOB", "HRS"]),
                       UnknownData.Finding(key: path, kind: .stations, ids: ["HRS", path + ":3"]))
        XCTAssertEqual(UnknownData.path(feed: nil, liveCodes: ["XYZ"])?.ids, ["XYZ"])
        // Lines: the table's are known; Amtrak's go by their initials, Shore Line East and the CapeFLYER have their own names;
        // ferries' aren't in the table
        feed.routes = [route("LIRR-BAB"), route("LIRR-12"), route("LIRR-9"), route("AMK-DOW"), route(FerryFeed.shoreLineEastRoute),
                       route(FerryFeed.mbtaCapeFlyerRoute), route("NYF-ER"), route("PATH-NWK-WTC"), route("PATH-JSQ-XX")]
        XCTAssertEqual(UnknownData.lines(feed: feed), [
            UnknownData.Finding(key: "lirr", kind: .lines, ids: ["LIRR-12", "LIRR-9"]),
            UnknownData.Finding(key: path, kind: .lines, ids: ["PATH-JSQ-XX"]),
        ].sorted { $0.key < $1.key })
        XCTAssertEqual(UnknownData.lines(feed: nil), [])
        // Subway stations the app's own list doesn't have
        func station(_ id: String) -> StationCatalog.Entry { StationCatalog.Entry(id: id, name: id, lat: 40.7, lon: -74.0, routes: []) }
        let own = StationCatalog(entries: [station("101"), station("102")])
        XCTAssertNil(UnknownData.subway(inUse: StationCatalog(entries: [station("101")]), own: own))
        XCTAssertEqual(UnknownData.subway(inUse: StationCatalog(entries: [station("101"), station("901"), station("900")]), own: own),
                       UnknownData.Finding(key: "subway", kind: .directions, ids: ["900", "901"]))
        XCTAssertNil(UnknownData.subway(inUse: nil, own: own))
        let finding = try XCTUnwrap(UnknownData.lines(feed: feed).first { $0.key == "lirr" })
        XCTAssertEqual(UnknownData.summary(finding), "lirr lines 2 (LIRR-12,LIRR-9)")
    }

    /// Report an Issue… for data this version doesn't know: the operators, the kinds, the counts and the first few ids
    func testTheIssuePageOfWhatIsntKnown() throws {
        let findings = [UnknownData.Finding(key: "path", kind: .stations, ids: ["HRS"]),
                        UnknownData.Finding(key: "lirr", kind: .lines, ids: (1...7).map { "LIRR-\($0)" })]
        let url = IssueReport.unknownData(findings, appVersion: "2.1.0", macOS: "27.2.1")
        let items = Dictionary(uniqueKeysWithValues: (try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems))
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["title"], "Data new to this version: PATH, Long Island Rail Road")
        XCTAssertEqual(items["body"], """
            App version: 2.1.0
            macOS: 27.2.1
            Operator: PATH (path)
            New to this version: 1 stations whose live trains can't be shown (HRS)
            Operator: Long Island Rail Road (lirr)
            New to this version: 7 lines shown with the operator's own codes (LIRR-1, LIRR-2, LIRR-3, LIRR-4, LIRR-5, …)

            """)
        XCTAssertLessThan(url.absoluteString.count, 1000)
    }

    /// Status names the lines new data leaves out when they are three at most; more are only counted, all of them, also past
    /// the entry's cut list
    func testTheLinesNewDataLeavesOut() {
        func kept(leavingOut gone: Int, missing: Int? = nil) -> DataChangeLog.Entry {
            let all = DataListing(routes: Dictionary(uniqueKeysWithValues: (1...9).map { ("r\($0)", "Line \($0)") }))
            var left = all
            for i in 1...gone { left.routes["r\(i)"] = nil }
            return DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept, reason: .stopsGone,
                                       changes: DataChanges.between(old: all, new: left),
                                       missing: missing.map { n in DataWitness.Missing(stops: [], routes: (1...n).map { "r\($0)" }) })
        }
        XCTAssertEqual(DataChangeLog.namedLines, 3)
        let none = DataChangeLog.Entry(key: "f", checkedAt: now, outcome: .kept).linesGone
        XCTAssertEqual(none.names, [])
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(Set(kept(leavingOut: 1).linesGone.names), ["Line 1"])
        let three = kept(leavingOut: 3).linesGone
        XCTAssertEqual(Set(three.names), ["Line 1", "Line 2", "Line 3"])
        XCTAssertEqual(three.count, 3)
        let four = kept(leavingOut: 4).linesGone
        XCTAssertEqual(four.names, [])
        XCTAssertEqual(four.count, 4)
        // The entry keeps only the first of a long list: the others are counted too
        let many = kept(leavingOut: 2, missing: 80).linesGone
        XCTAssertEqual(many.names, [])
        XCTAssertEqual(many.count, 80)
    }
}

/// The log lines the observer was told
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var told: [String] = []
    func add(_ line: String) { lock.lock(); told.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return told }
}
