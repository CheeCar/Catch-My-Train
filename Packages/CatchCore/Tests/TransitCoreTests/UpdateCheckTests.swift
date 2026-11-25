import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TransitCore

/// Checks for a new version (notify only, no automatic install)
final class UpdateCheckTests: XCTestCase {
    struct FakeFetcher: DataFetching {
        var result: Result<Data, Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    func testComparesVersions() {
        XCTAssertTrue(UpdateCheck.isNewer("2.1.1", than: "2.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("2.1", than: "2.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v2.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("2.1.0", than: "2.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("2.0.0", than: "2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.9.0", than: "1.10.0"), "compare numerically, not as text")
        XCTAssertFalse(UpdateCheck.isNewer("", than: "2.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0-rc.1", than: "1.0.0"), "the same version with a suffix is not an update")
    }

    func testParsesLatestRelease() throws {
        let json = #"{"tag_name":"v2.1.0","html_url":"https://github.com/CheeCar/Catch-My-Train/releases/tag/v2.1.0","draft":false,"prerelease":false}"#
        let r = try UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(r.version, "2.1.0")
        XCTAssertEqual(r.page.absoluteString, "https://github.com/CheeCar/Catch-My-Train/releases/tag/v2.1.0")
        XCTAssertThrowsError(try UpdateCheck.parse(Data(#"{"tag_name":"v1.0.0-rc.1","prerelease":true}"#.utf8))) {
            XCTAssertEqual($0 as? UpdateCheck.CheckError, .noRelease)
        }
        XCTAssertThrowsError(try UpdateCheck.parse(Data("not json".utf8)))
        XCTAssertEqual(UpdateCheck.Channel.release.api.absoluteString, "https://api.github.com/repos/CheeCar/Catch-My-Train/releases/latest")
    }

    /// The download link must be this repo's page on github.com; any other address opens the releases page instead
    func testDownloadLinkMustBeTheRepoOnGitHub() throws {
        for link in ["https://example.com/CheeCar/Catch-My-Train/releases/tag/v2.1.0",
                     "http://github.com/CheeCar/Catch-My-Train/releases/tag/v2.1.0",
                     "https://github.com.example.com/CheeCar/Catch-My-Train/releases",
                     "https://github.com/someone-else/Catch-My-Train/releases/tag/v2.1.0",
                     "https://github.com/CheeCar/Catch-My-Train-Copy/releases/tag/v2.1.0"] {
            let json = #"{"tag_name":"v2.1.0","html_url":"\#(link)","draft":false,"prerelease":false}"#
            XCTAssertEqual(try UpdateCheck.parse(Data(json.utf8)).page, UpdateCheck.Channel.release.releasesPage, link)
        }
    }

    /// GitHub refusing or rate-limiting the update check (common on shared networks) isn't a transit data problem:
    /// nothing is recorded for the notices at the stations
    func testUpdateCheckRecordsNoNotices() throws {
        XCTAssertFalse(UpdateCheck.fetcher.recordsReach)
        XCTAssertTrue(URLSessionFetcher().recordsReach)
        let url = UpdateCheck.Channel.release.api
        let host = try XCTUnwrap(url.host)
        NetworkReach.reset()
        RateLimit.cleared(host: host)
        defer {
            NetworkReach.reset()
            RateLimit.cleared(host: host)
        }
        func answer(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        }
        for quiet in [true, false] {
            URLSessionFetcher.note(nil, error: URLError(.cannotFindHost), url: url, lastTry: true, recordsReach: !quiet)
            URLSessionFetcher.note(try answer(429), error: nil, url: url, lastTry: true, recordsReach: !quiet)
            // A refusal shows the first time
            URLSessionFetcher.note(try answer(403), error: nil, url: url, lastTry: true, recordsReach: !quiet)
            if quiet {
                XCTAssertNil(RateLimit.pausedUntil(host: host))
                XCTAssertEqual(NetworkReach.notices(), [])
            } else {
                // A fetcher for transit data records the same answers
                XCTAssertNotNil(RateLimit.pausedUntil(host: host))
                XCTAssertFalse(NetworkReach.notices().isEmpty)
            }
        }
    }

    func testNoReleaseYet() async {
        // Repo not public yet, no Release yet: GitHub returns 404
        do {
            _ = try await UpdateCheck.fetchLatest(fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(404))))
            XCTFail("should say no version has been released yet")
        } catch {
            XCTAssertEqual(error as? UpdateCheck.CheckError, .noRelease)
        }
    }

    func testChecksOnceAMonth() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let oct16 = c.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        let oct30 = c.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        let nov1 = c.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: oct16))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: oct16, now: oct30))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: oct16, now: nov1))
    }

    /// A failed automatic check waits a day, instead of asking GitHub again at every refresh
    func testWaitsADayAfterAFailure() {
        let nov1 = Date(timeIntervalSince1970: 1_793_534_400)
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: nil, lastFailed: nov1, now: nov1.addingTimeInterval(60)))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: nil, lastFailed: nov1, now: nov1.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, lastFailed: nov1, now: nov1.addingTimeInterval(24 * 3600)))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, lastFailed: nov1, now: nov1.addingTimeInterval(-60)), "Clock set back")
        // Still once a month after the day is over
        let oct = nov1.addingTimeInterval(-3 * 86_400)
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: nov1, lastFailed: oct, now: nov1.addingTimeInterval(2 * 86_400)))
    }
}

/// The source list: where each operator's data is downloaded from, and the stations without times (see SourceList)
final class SourceListTests: XCTestCase {
    override func tearDown() { SourceList.reset() }

    private func bundled() throws -> SourceList { try XCTUnwrap(SourceList.bundled(), "The copy that comes with the app must pass every check") }

    private func data(_ list: SourceList) throws -> Data { try JSONEncoder().encode(list) }

    /// The file that comes with the app (and is the repository's copy) says exactly what the code says: change both together
    func testBundledListIsTheOneInCode() throws {
        XCTAssertEqual(try bundled(), SourceList.builtIn,
                       "Resources/source-list.json and the addresses in code differ: change both, with the file's \"updated\" day")
        XCTAssertNoThrow(try SourceList.builtIn.validate())
    }

    /// Every download the app makes is in it, and every station without times
    func testBundledListNamesEveryDownload() throws {
        let ids = Set(try bundled().operators.map(\.id))
        for source in FerryFeed.Source.allCases { XCTAssertTrue(ids.contains(source.rawValue), source.name) }
        for feed in RegionalBusFeed.builtIn { XCTAssertTrue(ids.contains(feed.listID), feed.name) }
        for feed in MTAFeed.allCases { XCTAssertTrue(ids.contains(feed.listID), feed.displayName) }
        for part in BusMap.parts { XCTAssertTrue(ids.contains(BusMap.listID(part.code)), part.name) }
        XCTAssertTrue(ids.contains("mta-subway"))
        XCTAssertTrue(ids.contains(RooseveltIslandTram.listID))
        XCTAssertEqual(try bundled().stationsWithoutTimes?.stations.count, NoTimesStations.builtInStations.count)
        // Nothing that needs the user's own key or account
        let all = try bundled().operators.flatMap { [$0.timetable, $0.realtime] }.compactMap { $0 }
        XCTAssertFalse(all.contains { $0.contains("bustime") || $0.contains("goswift") || $0.contains("raildata") || $0.contains("pcsdata") })
    }

    /// With the copy that comes with the app in use, every address is the one in code: moving them into the list changed none
    func testAddressesStayTheSameWithTheBundledList() throws {
        SourceList.use(try bundled())
        for source in FerryFeed.Source.allCases {
            XCTAssertEqual(source.url, source.builtInURL, source.name)
            XCTAssertEqual(source.realtimeURL, source.builtInRealtimeURL, source.name)
            XCTAssertFalse(source.isTurnedOff)
        }
        XCTAssertEqual(RegionalBusFeed.all.map(\.code), RegionalBusFeed.builtIn.map(\.code))
        for feed in RegionalBusFeed.all {
            XCTAssertEqual(feed.url, feed.builtInURL, feed.name)
            XCTAssertEqual(feed.realtimeURL, feed.builtInRealtimeURL, feed.name)
        }
        for feed in MTAFeed.allCases { XCTAssertEqual(feed.url, feed.builtInURL) }
        XCTAssertEqual(BusMap.sourceURLs, BusMap.builtInSourceURLs)
        XCTAssertEqual(RooseveltIslandTram.sourceURL, RooseveltIslandTram.builtInSourceURL)
        XCTAssertEqual(PathLive.url, PathLive.builtInURL)
        XCTAssertEqual(NJBusIndex.url, NJBusIndex.builtInURL)
        XCTAssertEqual(SubwayMap.sourceURL, SubwayMap.builtInSourceURL)
        XCTAssertEqual(NoTimesStations.all, NoTimesStations.builtInStations)
        XCTAssertEqual(NoTimesStations.agencies, NoTimesStations.builtInAgencies)
        // A few written out, as they were in code before the list
        XCTAssertEqual(FerryFeed.Source.amtrakNY.url.absoluteString, "https://content.amtrak.com/content/gtfs/GTFS.zip")
        XCTAssertEqual(FerryFeed.Source.njTransitBus.url.absoluteString, "https://www.njtransit.com/bus_data.zip")
        XCTAssertEqual(MTAFeed.sir.url.absoluteString, "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-si")
        XCTAssertNil(FerryFeed.Source.path.realtimeURL, "PATH's live data isn't GTFS-Realtime (see PathLive)")
        XCTAssertEqual(PathLive.url.absoluteString, "https://www.panynj.gov/bin/portauthority/ridepath.json")
    }

    private func edited(_ change: (inout SourceList) -> Void) -> SourceList {
        var list = SourceList.builtIn
        change(&list)
        return list
    }

    private func setOperator(_ list: inout SourceList, _ id: String, _ change: (inout SourceList.Operator) -> Void) {
        guard let i = list.operators.firstIndex(where: { $0.id == id }) else { return XCTFail("no \(id)") }
        change(&list.operators[i])
    }

    /// A moved address is used right away, live data's notices keep its operator's name, and the list in code comes back after
    func testAListMovesAnAddress() throws {
        let list = edited { list in
            setOperator(&list, "nyf") { $0.timetable = "https://nycferry.connexionz.net/rtt/public/resource/gtfs-2.zip" }
            setOperator(&list, "bus-bxl") { $0.realtime = "https://Westchester.GMV.com/gtfsrtapi/api/v2/tripupdates" }
        }
        XCTAssertNoThrow(try list.validate())
        XCTAssertFalse(SourceList.use(list), "Only addresses changed: nothing loaded has to be read again")
        XCTAssertEqual(FerryFeed.Source.nycFerry.url.absoluteString, "https://nycferry.connexionz.net/rtt/public/resource/gtfs-2.zip")
        XCTAssertEqual(RegionalBusFeed.feed(code: "BXL")?.realtimeURL?.absoluteString, "https://Westchester.GMV.com/gtfsrtapi/api/v2/tripupdates")
        XCTAssertEqual(RateLimit.provider(forHost: "westchester.gmv.com"), "Bee-Line")
        XCTAssertEqual(FerryFeed.Source.seastreak.url, FerryFeed.Source.seastreak.builtInURL)
        SourceList.reset()
        XCTAssertEqual(FerryFeed.Source.nycFerry.url, FerryFeed.Source.nycFerry.builtInURL)
    }

    /// A list can move an address, not give an operator data the code has never read
    func testAListCantAddLiveData() throws {
        let list = edited { list in
            setOperator(&list, "sif") { $0.realtime = "https://example.org/sif.pb" }
            setOperator(&list, "mta-subway-ace") { $0.timetable = "https://example.org/ace.zip" }
            setOperator(&list, "bus-nice") { $0.realtime = "https://example.org/nice.pb" }
        }
        SourceList.use(list)
        XCTAssertNil(FerryFeed.Source.statenIsland.realtimeURL)
        XCTAssertNil(SourceList.timetableURL(for: "mta-subway-ace"))
        XCTAssertNil(RegionalBusFeed.feed(code: "NICE")?.realtimeURL)
        XCTAssertFalse(RegionalBusFeed.feed(code: "NICE")?.hasRealtime ?? true)
    }

    /// An ID the app doesn't know (a newer version's operator) is skipped; a download the list leaves out keeps the address in code
    func testUnknownIDsAreSkippedAndMissingOnesKeepTheCode() throws {
        let list = edited { list in
            list.operators.removeAll { $0.id == "amk" }
            list.operators.append(.init(id: "septa-rail", name: "SEPTA Regional Rail", timetable: "https://example.org/septa.zip", enabled: false))
        }
        XCTAssertNoThrow(try list.validate())
        SourceList.use(list)
        XCTAssertEqual(FerryFeed.Source.amtrakNY.url, FerryFeed.Source.amtrakNY.builtInURL)
        XCTAssertTrue(SourceList.current.turnedOff.isEmpty)
    }

    /// An operator turned off is as if the app didn't have it: not among its mode's operators, its stops and piers left out
    func testTurningOperatorsOff() throws {
        let list = edited { list in
            setOperator(&list, "sst") { $0.enabled = false }
            setOperator(&list, "bus-nice") { $0.enabled = false }
            if let i = list.stationsWithoutTimes?.operators.firstIndex(where: { $0.key == "north-ferry" }) {
                list.stationsWithoutTimes?.operators[i].enabled = false
            }
        }
        XCTAssertNoThrow(try list.validate())
        XCTAssertTrue(SourceList.use(list), "What's turned off changed: the data loaded has to be read again")
        XCTAssertFalse(FerryFeed.Source.cases(for: .ferry).contains(.seastreak))
        XCTAssertTrue(FerryFeed.Source.cases(for: .ferry).contains(.nyWaterway))
        XCTAssertFalse(ModeCoverage.sources(for: .ferry).contains(.seastreak))
        XCTAssertNil(RegionalBusFeed.feed(code: "NICE"))
        XCTAssertEqual(RegionalBusFeed.all.count, RegionalBusFeed.builtIn.count - 1)
        XCTAssertFalse(NoTimesStations.agencies.contains { $0.key == "north-ferry" })
        XCTAssertFalse(NoTimesStations.all.contains { $0.agency.key == "north-ferry" })
        XCTAssertNil(NoTimesStations.station(id: "notimes:north-ferry:greenport"))
        XCTAssertNotNil(NoTimesStations.station(id: "notimes:south-ferry:shelter-island"))
        // A copy saved before keeps the operator's data: it's left out when read
        var feed = FerryFeed.empty
        feed.versions = ["sst": "1", "nyw": "2"]
        feed.piers = [FerryFeed.Pier(id: "sst:1", name: "Highlands", lat: 40.40, lon: -73.98),
                      FerryFeed.Pier(id: "nyw:2", name: "Hoboken", lat: 40.73, lon: -74.03)]
        XCTAssertEqual(feed.withoutTurnedOff().piers.map(\.id), ["nyw:2"])
        XCTAssertEqual(feed.withoutTurnedOff().sources, [.nyWaterway])
        SourceList.reset()
        XCTAssertEqual(feed.withoutTurnedOff(), feed)
    }

    /// A stop added to the list shows up, with the ID favorites keep
    func testAListAddsAStationWithoutTimes() throws {
        let list = edited { list in
            list.stationsWithoutTimes?.stations.append(.init(agency: "governors-island-ferry", id: "pier-101", name: "Pier 101",
                                                             latitude: 40.6887, longitude: -74.0005, website: "https://www.govisland.com/plan-your-visit/ferry"))
        }
        XCTAssertNoThrow(try list.validate())
        XCTAssertTrue(SourceList.use(list))
        let pier = try XCTUnwrap(NoTimesStations.station(id: "notimes:governors-island-ferry:pier-101"))
        XCTAssertEqual(pier.agency.name, "Governors Island Ferry")
        XCTAssertTrue(pier.agency.crossesWater)
        XCTAssertEqual(NoTimesStations.all.count, NoTimesStations.builtInStations.count + 1)
    }

    /// Each rule: one wrong field and the whole list isn't used
    func testRejectsABadList() throws {
        func rejected(_ change: (inout SourceList) -> Void) -> SourceList.Rejection? {
            do {
                _ = try SourceList.checked(try data(edited(change)))
                return nil
            } catch {
                return error as? SourceList.Rejection
            }
        }
        XCTAssertNil(rejected { _ in })
        XCTAssertEqual(rejected { $0.format = 2 }, .newerFormat)
        XCTAssertEqual(rejected { $0.format = 0 }, .badField("format"))
        XCTAssertEqual(rejected { $0.updated = "2026-02-30" }, .badField("updated"))
        XCTAssertEqual(rejected { $0.updated = "Nov 4" }, .badField("updated"))
        XCTAssertEqual(rejected { $0.operators = [] }, .badField("operators"))
        XCTAssertEqual(rejected { self.setOperator(&$0, "amk") { $0.timetable = "http://content.amtrak.com/content/gtfs/GTFS.zip" } },
                       .badField("operators[\(SourceList.builtIn.operators.firstIndex { $0.id == "amk" }!)].timetable"))
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.timetable = "https://user:pass@example.org/a.zip" } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.timetable = "not an address" } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "nyf") { $0.realtime = "ftp://example.org/a.pb" } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.name = " " } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.name = "Amtrak\nnew" } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.name = String(repeating: "A", count: 81) } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.id = "nyf" } }, "Two entries with one ID")
        XCTAssertNotNil(rejected { self.setOperator(&$0, "amk") { $0.id = "Amtrak" } })
        XCTAssertNotNil(rejected { self.setOperator(&$0, "mta-subway") { $0.enabled = false } }, "The subway can't be turned off")
        XCTAssertEqual(rejected { list in
            for id in ["nyf", "sif", "nyw", "sst", "sol", "amk"] { self.setOperator(&list, id) { $0.enabled = false } }
        }, .turnsOffTooMany)
        XCTAssertEqual(rejected { list in
            for id in ["nyf", "sif", "nyw", "sst"] { self.setOperator(&list, id) { $0.enabled = false } }
            for i in 0..<2 { list.stationsWithoutTimes?.operators[i].enabled = false }
        }, .turnsOffTooMany, "Operators of stations without times count too")
        XCTAssertEqual(rejected { $0.stationsWithoutTimes?.stations[0].latitude = 42.65 }, .badField("stationsWithoutTimes.stations[0].position"))
        var notANumber = SourceList.builtIn
        notANumber.stationsWithoutTimes?.stations[0].latitude = .nan
        XCTAssertThrowsError(try notANumber.validate(), "JSON can't say NaN, but a list made in code is checked the same way")
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.stations[0].agency = "someone-else" })
        XCTAssertNotNil(rejected { list in
            let first = list.stationsWithoutTimes?.stations[0].id ?? ""
            list.stationsWithoutTimes?.stations[1].id = first
        })
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.stations[0].website = "http://www.jfkairport.com/" })
        XCTAssertNil(rejected { $0.stationsWithoutTimes?.stations[0].website = "https://WWW.JFKAirport.com/to-from-airport" },
                     "Another page of a website in code")
        XCTAssertEqual(rejected { $0.stationsWithoutTimes?.stations[0].website = "https://www.example.org/" },
                       .otherServer("stationsWithoutTimes.stations[0].website"))
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.stations[0].website = "https://www.jfkairport.com.example.org/" })
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.stations[0].website = "https://www.jfkairport.com:8443/" })
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.operators[0].mode = "bus" })
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.operators[0].headwayMinutes = [15, 5] })
        XCTAssertNotNil(rejected { $0.stationsWithoutTimes?.operators[0].headwayMinutes = [5] })
        XCTAssertEqual(rejected { $0.stationsWithoutTimes?.stations.removeAll { $0.agency == "south-ferry" } },
                       .badField("stationsWithoutTimes.operators"), "An operator left without stations is a list cut short")
        XCTAssertEqual(rejected { $0.stationsWithoutTimes?.stations = [] }, .badField("stationsWithoutTimes.stations"))
        // Not a list at all, or far too big
        XCTAssertThrowsError(try SourceList.checked(Data("<html>Not Found</html>".utf8))) {
            XCTAssertEqual($0 as? SourceList.Rejection, .unreadable)
        }
        var big = try data(SourceList.builtIn)
        big.append(Data(repeating: 0x20, count: SourceList.maxBytes))
        XCTAssertThrowsError(try SourceList.checked(big)) { XCTAssertEqual($0 as? SourceList.Rejection, .tooLarge) }
        // A field a newer version added is no reason to refuse it
        var json = try XCTUnwrap(String(data: try data(SourceList.builtIn), encoding: .utf8))
        json = "{\"note\":\"added later\"," + json.dropFirst()
        XCTAssertNoThrow(try SourceList.checked(Data(json.utf8)))
    }

    /// Whoever can change the list can't send the app to another server: an address moves only within the server and first
    /// folder of the one in code, or anywhere on the server when the one in code is at its top
    func testAListKeepsEachAddressOnItsServer() throws {
        func rejected(_ id: String, timetable: String? = nil, realtime: String? = nil) -> SourceList.Rejection? {
            let list = edited { list in
                self.setOperator(&list, id) {
                    if let timetable { $0.timetable = timetable }
                    if let realtime { $0.realtime = realtime }
                }
            }
            do {
                try list.validate()
                return nil
            } catch {
                return error as? SourceList.Rejection
            }
        }
        // Amtrak's is in a folder: "content.amtrak.com/content/gtfs/GTFS.zip"
        XCTAssertNil(rejected("amk", timetable: "https://content.amtrak.com/content/gtfs/2027/GTFS.zip"))
        XCTAssertNil(rejected("amk", timetable: "https://CONTENT.Amtrak.com/content/GTFS.zip?v=2"))
        XCTAssertEqual(rejected("amk", timetable: "https://example.org/content/gtfs/GTFS.zip"), .otherServer("amk.timetable"))
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com.example.org/content/gtfs/GTFS.zip"))
        XCTAssertNotNil(rejected("amk", timetable: "https://amtrak.com/content/gtfs/GTFS.zip"))
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com:8443/content/gtfs/GTFS.zip"))
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/other/gtfs/GTFS.zip"), "Another folder")
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/Content/gtfs/GTFS.zip"), "Folders keep their case")
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/content"), "The folder itself")
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com//content/gtfs/GTFS.zip"))
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/content/../other/GTFS.zip"), "Back up a folder")
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/content/%2E%2E/other/GTFS.zip"))
        XCTAssertNotNil(rejected("amk", timetable: "https://content.amtrak.com/content/./GTFS.zip"))
        // A bucket on a shared server: only within that bucket
        XCTAssertNil(rejected("bus-bxl", timetable: "https://s3.amazonaws.com/datatools-511ny/public/Bee-Line.zip"))
        XCTAssertNotNil(rejected("bus-bxl", timetable: "https://s3.amazonaws.com/someone-else/public/Westchester_County_Bee-Line_System.zip"))
        // Live data, the same way
        XCTAssertNil(rejected("bus-bxl", realtime: "https://westchester.gmv.com/gtfsrtapi/api/v2/tripupdates"))
        XCTAssertEqual(rejected("bus-bxl", realtime: "https://westchester.example.org/gtfsrtapi/api/tripupdates"), .otherServer("bus-bxl.realtime"))
        // MTA's subway timetable is at the server's top: anywhere on that server, nowhere else
        XCTAssertNil(rejected("mta-subway", timetable: "https://rrgtfsfeeds.s3.amazonaws.com/2027/gtfs_subway.zip"))
        XCTAssertNotNil(rejected("mta-subway", timetable: "https://s3.amazonaws.com/rrgtfsfeeds/gtfs_subway.zip"))
        // An address for a kind of data the code has none for isn't used, so it isn't compared (see testAListCantAddLiveData)
        XCTAssertNil(rejected("sif", realtime: "https://example.org/sif.pb"))
        // Every address in code passes, each written as it is
        for known in SourceList.known {
            for url in [known.timetable, known.realtime].compactMap({ $0 }) {
                XCTAssertTrue(SourceList.isMove(url.absoluteString, from: url), url.absoluteString)
            }
        }
        for station in NoTimesStations.builtInStations { XCTAssertTrue(SourceList.isWebsite(station.website.absoluteString)) }
    }

    /// Of the saved list and the copy in the app, the one changed last (a newer app version's copy can be newer than a list saved before)
    func testNewestListWins() {
        let older = edited { $0.updated = "2026-10-01" }
        let newer = edited { $0.updated = "2026-12-01" }
        XCTAssertEqual(SourceList.newest([older, newer])?.updated, "2026-12-01")
        XCTAssertEqual(SourceList.newest([newer, older])?.updated, "2026-12-01")
        XCTAssertEqual(SourceList.newest([nil, older])?.updated, "2026-10-01")
        XCTAssertNil(SourceList.newest([nil, nil]))
        var saved = SourceList.builtIn
        saved.operators[0].name = "Saved"
        XCTAssertEqual(SourceList.newest([saved, SourceList.builtIn])?.operators[0].name, "Saved", "The same day: the saved one")
    }

    /// GitHub: the repository's file through the API; 404 while the repository is private is only an error to the caller, never a notice
    func testDownloadsFromTheRepository() async throws {
        XCTAssertEqual(SourceList.remoteURL(repository: "CheeCar/Catch-My-Train").absoluteString,
                       "https://api.github.com/repos/CheeCar/Catch-My-Train/contents/Packages/CatchCore/Sources/TransitCore/Resources/source-list.json?ref=main")
        XCTAssertFalse(SourceList.fetcher.recordsReach)
        let file = try data(SourceList.builtIn)
        let got = try await SourceList.fetch(repository: "a/b", fetcher: UpdateCheckTests.FakeFetcher(result: .success(file)))
        XCTAssertEqual(got.list, SourceList.builtIn)
        XCTAssertEqual(got.data, file)
        NetworkReach.reset()
        do {
            _ = try await SourceList.fetch(repository: "a/b", fetcher: UpdateCheckTests.FakeFetcher(result: .failure(FeedFetchError.httpStatus(404))))
            XCTFail("404 must throw")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .httpStatus(404))
        }
        XCTAssertTrue(NetworkReach.notices().isEmpty)
        do {
            _ = try await SourceList.fetch(repository: "a/b", fetcher: UpdateCheckTests.FakeFetcher(result: .success(Data("{}".utf8))))
            XCTFail("A broken list must throw")
        } catch {
            XCTAssertEqual(error as? SourceList.Rejection, .unreadable)
        }
    }

    /// Monthly, like the timetables; while an operator's own problem lasts, at most daily
    func testWhenTheListIsChecked() {
        let ny = SubwayMapSchedule.calendar
        let nov3 = ny.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        let oct30 = ny.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
        XCTAssertTrue(SourceList.isDue(lastTried: nil, operatorProblem: false, now: nov3))
        XCTAssertTrue(SourceList.isDue(lastTried: oct30, operatorProblem: false, now: nov3), "A new month")
        XCTAssertFalse(SourceList.isDue(lastTried: nov3, operatorProblem: false, now: nov3.addingTimeInterval(3 * 86_400)))
        XCTAssertFalse(SourceList.isDue(lastTried: nov3, operatorProblem: true, now: nov3.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(SourceList.isDue(lastTried: nov3, operatorProblem: true, now: nov3.addingTimeInterval(24 * 3600)))
    }

    /// The list's day is a calendar day: shown as the same day in the time zone it's shown in (this Mac's), wherever that is
    func testListDay() throws {
        for id in ["America/New_York", "America/Los_Angeles", "Asia/Tokyo", "Australia/Sydney", "Pacific/Honolulu"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let day = try XCTUnwrap(SourceList.day("2026-11-04", in: zone))
            XCTAssertEqual(Timetable.calendar(in: zone).dateComponents([.year, .month, .day], from: day),
                           DateComponents(year: 2026, month: 11, day: 4), id)
        }
        for bad in ["2026-13-01", "2026-02-29", "26-11-04", "2026-1-04", "2026-11-04T00", ""] { XCTAssertNil(SourceList.day(bad), bad) }
        XCTAssertNotNil(SourceList.day("2028-02-29"))
    }
}
