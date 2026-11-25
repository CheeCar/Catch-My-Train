import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TransitCore

/// Classifying and reporting failures to reach data providers (explain why when network restrictions prevent service)
final class NetworkReachTests: XCTestCase {
    let mta = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs")!
    let ferry = URL(string: "https://nycferry.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate")!
    let busTime = URL(string: "https://bustime.mta.info/api/siri/stop-monitoring.json")!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() { NetworkReach.reset() }
    override func tearDown() { NetworkReach.reset() }

    /// Certificates out of date at several servers at once: this Mac's date or time, said once without a provider's name and not
    /// counted with the unreachable servers. One server alone keeps its own notice (its certificate may really be out of date)
    func testCertificateDatesAtSeveralServersAreThisMacsClock() {
        for _ in 0..<2 { NetworkReach.record(error: URLError(.serverCertificateHasBadDate), url: mta, now: t0) }
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.secureConnection], "One server: its own notice")
        for _ in 0..<2 { NetworkReach.record(error: URLError(.serverCertificateNotYetValid), url: ferry, now: t0.addingTimeInterval(10)) }
        let n = NetworkReach.notices(now: t0.addingTimeInterval(11))
        XCTAssertEqual(n, [NetworkReach.Notice(provider: "", problem: .clock, since: t0)])
        XCTAssertTrue(n[0].problem.isGeneral)
        XCTAssertFalse(NetworkReach.looksRestricted(n), "It says its own reason")
        // Other secure connection failures stay each provider's, and several of them look like the network
        NetworkReach.reset()
        for url in [mta, ferry] { for _ in 0..<2 { NetworkReach.record(error: URLError(.secureConnectionFailed), url: url, now: t0) } }
        let plain = NetworkReach.notices(now: t0)
        XCTAssertEqual(plain.map(\.problem), [.secureConnection, .secureConnection])
        XCTAssertTrue(NetworkReach.looksRestricted(plain))
    }

    /// A web page instead of the data at several servers at once: this network's own page, such as a sign-in page. A format change
    /// isn't a web page, and one server alone keeps its own notice
    func testWebPagesAtSeveralServersAreTheNetworksPage() {
        for _ in 0..<2 { NetworkReach.recordBadData(url: mta, webPage: true, now: t0) }
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.badData], "One server: its own notice")
        for _ in 0..<2 { NetworkReach.recordBadData(url: ferry, webPage: true, now: t0.addingTimeInterval(5)) }
        XCTAssertEqual(NetworkReach.notices(now: t0.addingTimeInterval(6)), [NetworkReach.Notice(provider: "", problem: .signIn, since: t0)])
        NetworkReach.reset()
        for url in [mta, ferry] { for _ in 0..<2 { NetworkReach.recordBadData(url: url, now: t0) } }
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.badData, .badData])
    }

    /// A proxy asking for a sign-in (407) is a refusal on this network, even at a server that needs a key; a server sending the app
    /// on to an address without encryption has moved its data
    func testProxySignInAndUnencryptedAddresses() {
        NetworkReach.record(status: 407, url: busTime, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.refused])
        XCTAssertEqual(NetworkReach.problem(for: URLError(.appTransportSecurityRequiresSecureConnection)), .notFound)
        XCTAssertEqual(NetworkReach.cause(for: URLError(.serverCertificateHasBadDate)), .certificateDate)
        XCTAssertEqual(NetworkReach.cause(for: URLError(.serverCertificateNotYetValid)), .certificateDate)
        XCTAssertNil(NetworkReach.cause(for: URLError(.serverCertificateUntrusted)))
        XCTAssertNil(NetworkReach.cause(for: URLError(.timedOut)))
    }

    func testClassifiesURLErrors() {
        XCTAssertEqual(NetworkReach.problem(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(NetworkReach.problem(for: URLError(.cannotFindHost)), .noDNS)
        XCTAssertEqual(NetworkReach.problem(for: URLError(.timedOut)), .noResponse)
        XCTAssertEqual(NetworkReach.problem(for: URLError(.networkConnectionLost)), .noResponse)
        XCTAssertEqual(NetworkReach.problem(for: URLError(.secureConnectionFailed)), .secureConnection)
        XCTAssertNil(NetworkReach.problem(for: URLError(.cancelled)), "Cancellation isn't a network problem")
        XCTAssertNil(NetworkReach.problem(for: FeedFetchError.noData))
    }

    /// A download stopped by standby (or by its caller) is never treated as failed
    func testCancellationIsNotAFailure() {
        XCTAssertTrue(NetworkReach.isCancellation(CancellationError()))
        XCTAssertTrue(NetworkReach.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(NetworkReach.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(NetworkReach.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(NetworkReach.isCancellation(FeedFetchError.noData))
    }

    func testOneTimeoutIsNotShownTwoAre() {
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty, "An occasional single timeout isn't reported")
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0.addingTimeInterval(30))
        let n = NetworkReach.notices(now: t0.addingTimeInterval(31))
        XCTAssertEqual(n, [NetworkReach.Notice(provider: "MTA", problem: .noResponse, since: t0)])
    }

    func testSuccessClears() {
        NetworkReach.record(error: URLError(.cannotFindHost), url: mta, now: t0)
        NetworkReach.record(error: URLError(.cannotFindHost), url: mta, now: t0)
        NetworkReach.record(status: 200, url: mta, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    func testRefusedShowsAtOnceButNotForKeyedHosts() {
        NetworkReach.record(status: 451, url: ferry, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.refused])
        NetworkReach.reset()
        NetworkReach.record(status: 403, url: ferry, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.provider), ["NYC Ferry"])
        NetworkReach.reset()
        // A 403 from a server that needs a key is a key problem (reported separately there), not a network one
        NetworkReach.record(status: 403, url: busTime, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
        // 503 (server temporarily unavailable) isn't a network restriction
        NetworkReach.record(status: 503, url: ferry, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    /// Only the key and account API servers count a 403 as a key problem: NJ Transit's free timetable download being refused is shown
    func testRefusedTimetableDownloadIsShownOnNJTransitsWebsite() {
        XCTAssertTrue(NetworkReach.needsKey(host: "bustime.mta.info"))
        XCTAssertTrue(NetworkReach.needsKey(host: "raildata.njtransit.com"))
        XCTAssertTrue(NetworkReach.needsKey(host: "testpcsdata.njtransit.com"))
        XCTAssertTrue(NetworkReach.needsKey(host: "api.goswift.ly"))
        XCTAssertFalse(NetworkReach.needsKey(host: "www.njtransit.com"))
        NetworkReach.record(status: 403, url: FerryFeed.njTransitRailURL, provider: FerryFeed.Source.njTransitRail.name, lasting: true, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.refused])
        NetworkReach.reset()
        NetworkReach.record(status: 403, url: NJTransitLive.tripUpdatesURL, now: t0)
        NetworkReach.record(status: 403, url: NJTransitLive.Endpoints.bus.tripUpdates, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty, "An account problem, noted elsewhere")
    }

    /// One kind of problem that isn't due to be shown (a single timeout, an unreadable feed once, a forgotten one) doesn't hide another kind's notice
    func testAProblemNotShownYetDoesNotHideAnother() {
        let zip = URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip")!
        NetworkReach.record(status: 404, url: zip, provider: "MTA", lasting: true, now: t0)
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0)
        NetworkReach.recordBadData(url: mta, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.notFound])
        // Due to be shown now: unreachable comes first
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0.addingTimeInterval(30))
        XCTAssertEqual(NetworkReach.notices(now: t0.addingTimeInterval(31)).map(\.problem), [.noResponse])
        // Not retried for long (e.g. switched to another mode): forgotten, and the monthly data's problem shows again
        let later = t0.addingTimeInterval(NetworkReach.forgetAfter + 60)
        XCTAssertEqual(NetworkReach.notices(now: later).map(\.problem), [.notFound])
        XCTAssertEqual(NetworkReach.notices(now: later).first?.lasting, true)
    }

    func testOfflineIsOneNoticeAndASuccessClearsIt() {
        NetworkReach.record(error: URLError(.notConnectedToInternet), url: mta, now: t0)
        NetworkReach.record(error: URLError(.timedOut), url: ferry, now: t0)
        NetworkReach.record(error: URLError(.timedOut), url: ferry, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0), [NetworkReach.Notice(provider: "", problem: .offline, since: t0)])
        NetworkReach.record(status: 200, url: mta, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.provider), ["NYC Ferry"])
    }

    func testOldNoticesAreForgotten() {
        NetworkReach.record(status: 451, url: ferry, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0.addingTimeInterval(NetworkReach.forgetAfter + 1)).isEmpty)
    }

    func testSeveralProvidersLookRestricted() {
        NetworkReach.record(status: 451, url: ferry, now: t0)
        XCTAssertFalse(NetworkReach.looksRestricted(NetworkReach.notices(now: t0)), "Only one provider: maybe just its server has a problem")
        NetworkReach.record(error: URLError(.cannotFindHost), url: mta, now: t0)
        NetworkReach.record(error: URLError(.cannotFindHost), url: mta, now: t0)
        XCTAssertTrue(NetworkReach.looksRestricted(NetworkReach.notices(now: t0)))
    }

    func testProviderNameCanBeGiven() {
        let s3 = URL(string: "https://s3.amazonaws.com/datatools-511ny/public/Westchester_County_Bee-Line_System.zip")!
        NetworkReach.record(status: 451, url: s3, provider: "Bee-Line", now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.provider), ["Bee-Line"])
    }

    func testSuffolkNeedsAKey() throws {
        let sct = try XCTUnwrap(RegionalBusFeed.feed(code: "SCT"))
        XCTAssertTrue(sct.needsKey)
        XCTAssertTrue(sct.hasRealtime)
        XCTAssertFalse(sct.canGetRealtime(hasAccount: true, hasSuffolkKey: false))
        XCTAssertTrue(sct.canGetRealtime(hasAccount: false, hasSuffolkKey: true))
        XCTAssertNil(sct.realtimeURL, "Not free realtime data")
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:SCT/1"], hasAccount: false).map(\.code), [])
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:SCT/1"], hasAccount: false, hasSuffolkKey: true).map(\.code), ["SCT"])
        XCTAssertEqual(RateLimit.provider(forHost: "api.goswift.ly"), "Suffolk County Transit")
    }

    // MARK: Problems on the provider's side (also warn when servers migrate or URLs or formats change)

    func testNotFoundAndServerErrors() {
        NetworkReach.record(status: 404, url: ferry, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty, "A single 404 isn't reported yet")
        NetworkReach.record(status: 404, url: ferry, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.notFound])
        XCTAssertFalse(NetworkReach.Problem.notFound.isNetwork)
        NetworkReach.reset()
        NetworkReach.record(status: 503, url: ferry, now: t0)
        NetworkReach.record(status: 503, url: ferry, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty, "Occasional server errors aren't reported")
        NetworkReach.record(status: 502, url: ferry, now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.serverError])
        NetworkReach.record(status: 200, url: ferry, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    func testBadDataStaysUntilReadable() throws {
        // Downloaded fine (200) but unparsable: a 200 doesn't clear it
        for _ in 0..<2 {
            NetworkReach.record(status: 200, url: mta, now: t0)
            XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data("<html>moved</html>".utf8), from: mta, now: t0))
        }
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.badData])
        XCTAssertFalse(NetworkReach.looksRestricted(NetworkReach.notices(now: t0)), "Not a network problem")
        // Cleared once it parses (a header with no train); an empty answer doesn't clear it
        XCTAssertThrowsError(try GTFSRealtimeFeed.decode(Data(), from: mta, now: t0))
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.badData])
        _ = try GTFSRealtimeFeed.decode(Data([0x0A, 0x00]), from: mta, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    func testStaleLiveData() {
        let old = t0.addingTimeInterval(-NetworkReach.staleAfter - 60)
        NetworkReach.recordGoodData(url: mta, timestamp: old, now: t0)
        NetworkReach.recordGoodData(url: mta, timestamp: old, now: t0.addingTimeInterval(30))
        let n = NetworkReach.notices(now: t0.addingTimeInterval(31))
        XCTAssertEqual(n.map(\.problem), [.stale])
        XCTAssertEqual(n.first?.since, old, "Counted from when the data stopped")
        NetworkReach.recordGoodData(url: mta, timestamp: t0, now: t0.addingTimeInterval(60))
        XCTAssertTrue(NetworkReach.notices(now: t0.addingTimeInterval(61)).isEmpty)
        // No trips (overnight shutdown) doesn't count
        NetworkReach.recordGoodData(url: mta, timestamp: old, hasTrips: false, now: t0)
        NetworkReach.recordGoodData(url: mta, timestamp: old, hasTrips: false, now: t0)
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    func testMonthlyDownloadProblemsLastUntilNextSuccess() {
        let zip = URL(string: "http://web.mta.info/developers/data/nyct/subway/google_transit.zip")!
        NetworkReach.record(status: 404, url: zip, provider: "MTA", lasting: true, now: t0)
        var n = NetworkReach.notices(now: t0.addingTimeInterval(24 * 3600))
        XCTAssertEqual(n.map(\.problem), [.notFound], "Reported after one failure, until the next success")
        XCTAssertEqual(n.first?.lasting, true)
        // A successful realtime download from the same provider doesn't clear the monthly data problem
        NetworkReach.record(status: 200, url: mta, provider: "MTA", now: t0)
        XCTAssertEqual(NetworkReach.notices(now: t0).map(\.problem), [.notFound])
        // Monthly data downloads but can't be parsed: switches to "can't parse"
        NetworkReach.record(status: 200, url: zip, provider: "MTA", lasting: true, now: t0)
        XCTAssertThrows { _ = try NetworkReach.reading(zip, provider: "MTA", lasting: true, now: t0) { () throws -> Int in throw FeedFetchError.noData } }
        n = NetworkReach.notices(now: t0)
        XCTAssertEqual(n.map(\.problem), [.badData])
        _ = try? NetworkReach.reading(zip, provider: "MTA", lasting: true, now: t0) { 1 }
        XCTAssertTrue(NetworkReach.notices(now: t0).isEmpty)
    }

    func testWebPageInsteadOfData() {
        let page = HTTPURLResponse(url: mta, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])
        XCTAssertTrue(NetworkReach.isWebPage(page, accept: "application/x-protobuf"))
        XCTAssertTrue(NetworkReach.isWebPage(page, accept: nil))
        XCTAssertFalse(NetworkReach.isWebPage(page, accept: "text/html"))
        let data = HTTPURLResponse(url: mta, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])
        XCTAssertFalse(NetworkReach.isWebPage(data, accept: nil))
        // The default Accept header asks for GTFS-Realtime first and allows any type (CTtransit's server answers 406 otherwise);
        // a web page still isn't data
        let accept = URLSessionFetcher().accept
        XCTAssertEqual(accept, URLSessionFetcher.defaultAccept)
        XCTAssertTrue(accept.hasPrefix("application/x-protobuf,"))
        XCTAssertTrue(accept.contains("*/*"))
        XCTAssertTrue(NetworkReach.isWebPage(page, accept: accept))
    }

    private func XCTAssertThrows(_ body: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line)
    }
}

/// Rate limits and connection notices show only in the mode, and at the stations, their provider serves
final class NoticeScopeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func reach(_ provider: String, lasting: Bool = false) -> NetworkReach.Notice {
        NetworkReach.Notice(provider: provider, problem: .noResponse, since: t0, lasting: lasting ? true : nil)
    }

    /// NJ Transit's bus token is used up: noted in Bus mode at its stops, not in Subway mode (away from light rail too) or at other stops
    func testNJTransitBusRateLimitStaysInBusMode() throws {
        let host = "pcsdata.njtransit.com"
        RateLimit.cleared(host: host)
        defer { RateLimit.cleared(host: host) }
        RateLimit.hit(host: host, retryAfter: 3600, now: t0)
        let limits = RateLimit.notices(now: t0).filter { $0.provider == "NJ Transit bus" }
        XCTAssertEqual(limits.count, 1)
        XCTAssertTrue(NoticeScope.filter(limits, mode: .subway).isEmpty)
        XCTAssertTrue(NoticeScope.filter(limits, mode: .subway, stationIDs: ["R16", "path:33S", "njl:39472"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(limits, mode: .ferry).isEmpty)
        XCTAssertTrue(NoticeScope.filter(limits, mode: .train).isEmpty)
        XCTAssertEqual(NoticeScope.filter(limits, mode: .bus), limits)
        XCTAssertEqual(NoticeScope.filter(limits, mode: .bus, stationIDs: ["njb:12345"]), limits)
        XCTAssertTrue(NoticeScope.filter(limits, mode: .bus, stationIDs: ["400123", "njb:NICE/77"]).isEmpty,
                      "An MTA stop and a NICE stop don't use NJ Transit's token")
        // A stop group with an NJ Transit stop among others
        XCTAssertEqual(NoticeScope.filter(limits, mode: .bus, stationIDs: ["400123", "njb:12345"]), limits)
    }

    /// One NJ Transit rail account serves trains and light rail: Train mode, and light rail stops in Subway mode, but not subway stations
    func testNJTransitRailCoversTrainsAndLightRail() {
        let n = [reach("NJ Transit rail")]
        XCTAssertEqual(NoticeScope.filter(n, mode: .train), n)
        XCTAssertEqual(NoticeScope.filter(n, mode: .subway), n)
        XCTAssertEqual(NoticeScope.filter(n, mode: .train, stationIDs: ["njr:105"]), n)
        XCTAssertTrue(NoticeScope.filter(n, mode: .train, stationIDs: ["lirr:237", "mnr:1"]).isEmpty)
        XCTAssertEqual(NoticeScope.filter(n, mode: .subway, stationIDs: ["njl:39472"]), n)
        XCTAssertTrue(NoticeScope.filter(n, mode: .subway, stationIDs: ["R16", "path:33S", RooseveltIslandTram.islandStationID]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(n, mode: .bus).isEmpty)
        XCTAssertTrue(NoticeScope.filter(n, mode: .ferry).isEmpty)
    }

    /// "MTA" names its live data (subway, LIRR and Metro-North feeds) and its monthly data (subway and bus GTFS)
    func testMTANoticesDependOnTheKindOfData() {
        let live = [reach("MTA")]
        XCTAssertEqual(NoticeScope.filter(live, mode: .subway, stationIDs: ["R16"]), live)
        XCTAssertEqual(NoticeScope.filter(live, mode: .train, stationIDs: ["lirr:237"]), live)
        XCTAssertTrue(NoticeScope.filter(live, mode: .train, stationIDs: ["njr:105", "amk:NYP"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(live, mode: .bus).isEmpty)
        XCTAssertTrue(NoticeScope.filter(live, mode: .subway, stationIDs: ["path:33S"]).isEmpty)
        // The monthly data recorded as "MTA" is the subway GTFS: not shown at bus stops
        let monthly = [reach("MTA", lasting: true)]
        XCTAssertEqual(NoticeScope.filter(monthly, mode: .subway), monthly)
        XCTAssertEqual(NoticeScope.filter(monthly, mode: .subway, stationIDs: ["R16"]), monthly)
        XCTAssertTrue(NoticeScope.filter(monthly, mode: .bus, stationIDs: ["400123"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(monthly, mode: .bus, stationIDs: ["njb:12345"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(monthly, mode: .train).isEmpty)
        // MTA Bus Time is only MTA's bus stops
        let busTime = [reach("MTA Bus Time")]
        XCTAssertEqual(NoticeScope.filter(busTime, mode: .bus, stationIDs: ["400123"]), busTime)
        XCTAssertTrue(NoticeScope.filter(busTime, mode: .subway).isEmpty)
    }

    /// Timetable operators go by their own names: a train timetable problem isn't shown in Subway or Ferry mode
    func testTimetableOperatorsStayInTheirMode() {
        let amtrak = [reach(FerryFeed.Source.amtrakNY.name, lasting: true)]
        XCTAssertEqual(NoticeScope.filter(amtrak, mode: .train, stationIDs: ["amk:NYP"]), amtrak)
        XCTAssertTrue(NoticeScope.filter(amtrak, mode: .train, stationIDs: ["lirr:237"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(amtrak, mode: .subway).isEmpty)
        let ferry = [reach("NYC Ferry")]
        XCTAssertEqual(NoticeScope.filter(ferry, mode: .ferry, stationIDs: ["nyf:87", "nyw:1"]), ferry)
        XCTAssertTrue(NoticeScope.filter(ferry, mode: .ferry, stationIDs: ["sif:1"]).isEmpty)
        let path = [reach("PATH")]
        XCTAssertEqual(NoticeScope.filter(path, mode: .subway, stationIDs: ["path:33S"]), path)
        XCTAssertTrue(NoticeScope.filter(path, mode: .subway, stationIDs: ["R16"]).isEmpty)
        let cttransit = [reach("CTtransit")]
        XCTAssertEqual(NoticeScope.filter(cttransit, mode: .bus, stationIDs: ["njb:CTT/123"]), cttransit)
        XCTAssertTrue(NoticeScope.filter(cttransit, mode: .bus, stationIDs: ["njb:123"]).isEmpty)
    }

    /// Passio's server has the live data of several bus companies in different areas: a notice from it is about all of them, and
    /// where it shows it names only the ones that concern what's shown
    func testPassioNoticeNamesOnlyTheCompaniesShown() {
        PlacesInUse.reset()
        defer { PlacesInUse.reset() }
        let all = RegionalBusFeed.passioProvider
        XCTAssertEqual(all, "Cecil Transit / BAT / COAST / FRTA / WRTD")
        XCTAssertEqual(RateLimit.provider(forHost: "passio3.com"), all)
        let n = [reach(all)]
        // Every one of its companies' stops, in Bus mode only
        XCTAssertEqual(NoticeScope.parts(provider: all, lasting: false),
                       [.bus("CECIL"), .bus("BAT"), .bus("COAST"), .bus("FRTA"), .bus("WRTD")])
        XCTAssertTrue(NoticeScope.filter(n, mode: .train).isEmpty)
        XCTAssertTrue(NoticeScope.filter(n, mode: .subway).isEmpty)
        // At a stop: named after the companies stopping there, in the server's order; not shown at other companies' stops
        XCTAssertEqual(NoticeScope.filter(n, mode: .bus, stationIDs: ["njb:FRTA/12"]).map(\.provider), ["FRTA"])
        XCTAssertEqual(NoticeScope.filter(n, mode: .bus, stationIDs: ["njb:BAT/7", "njb:MBTA/70"]).map(\.provider), ["BAT"])
        XCTAssertEqual(NoticeScope.filter(n, mode: .bus, stationIDs: ["njb:WRTD/3", "njb:FRTA/12", "njb:PVTA/5"]).map(\.provider), ["FRTA / WRTD"])
        XCTAssertTrue(NoticeScope.filter(n, mode: .bus, stationIDs: ["njb:PVTA/5", "njb:CTT/123", "njb:12345", "400123"]).isEmpty)
        // Everything else about the notice stays
        let named = NoticeScope.naming(n, stationIDs: ["njb:COAST/1"])
        XCTAssertEqual(named.map(\.provider), ["COAST"])
        XCTAssertEqual(named.first?.problem, .noResponse)
        XCTAssertEqual(named.first?.since, t0)
        // A narrowed name still stands for those companies; one name alone, or with a name that isn't a company's, doesn't
        XCTAssertEqual(NoticeScope.parts(provider: "FRTA / WRTD", lasting: false), [.bus("FRTA"), .bus("WRTD")])
        XCTAssertEqual(NoticeScope.busCompanies(named: "BAT / COAST")?.map(\.code), ["BAT", "COAST"])
        XCTAssertNil(NoticeScope.busCompanies(named: "FRTA"))
        XCTAssertNil(NoticeScope.busCompanies(named: "FRTA / Somewhere Else"))
        // Away from a station: the companies whose data is downloaded now. With none (nothing in use yet) the whole name stays
        XCTAssertEqual(NoticeScope.naming(n).map(\.provider), [all])
        // Starting in Greenfield: FRTA's
        PlacesInUse.set(.start, [Coordinate(latitude: 42.5854, longitude: -72.6006)])
        XCTAssertEqual(NoticeScope.naming(n).map(\.provider), ["FRTA"])
        XCTAssertEqual(NoticeScope.filter(n, mode: .bus).map(\.provider), [all], "kept under the server's name; named where it shows")
        // With a favorite in Brockton and one in Willimantic: BAT's and WRTD's too
        PlacesInUse.set(.favorites, [Coordinate(latitude: 42.0834, longitude: -71.0184), Coordinate(latitude: 41.7107, longitude: -72.2081)])
        XCTAssertEqual(NoticeScope.naming(n).map(\.provider), ["BAT / FRTA / WRTD"])
        // A notice about anything else keeps its name
        let others = [reach("MBTA"), reach("CTtransit"), reach("")]
        XCTAssertEqual(NoticeScope.naming(others), others)
        XCTAssertEqual(NoticeScope.naming(others, stationIDs: ["njb:FRTA/12"]), others)
    }

    /// its Metro's as "SEPTA Metro" and PATCO's under PATCO's name
    func testSEPTANoticesStayWithSEPTA() {
        XCTAssertEqual(RateLimit.provider(forHost: "www3.septa.org"), "SEPTA")
        let live = [reach("SEPTA")]
        XCTAssertEqual(NoticeScope.filter(live, mode: .train, stationIDs: ["srr:90004"]), live)
        XCTAssertEqual(NoticeScope.filter(live, mode: .subway, stationIDs: ["smt:2457"]), live)
        XCTAssertEqual(NoticeScope.filter(live, mode: .bus, stationIDs: ["njb:SEPTA/5001"]), live)
        XCTAssertTrue(NoticeScope.filter(live, mode: .subway, stationIDs: ["R16", "pat:11", "njl:38307"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(live, mode: .bus, stationIDs: ["njb:CTT/123", "njb:12345"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(live, mode: .ferry).isEmpty)
        let busTimetable = [reach("SEPTA", lasting: true)]
        XCTAssertEqual(NoticeScope.filter(busTimetable, mode: .bus, stationIDs: ["njb:SEPTA/5001"]), busTimetable)
        XCTAssertTrue(NoticeScope.filter(busTimetable, mode: .subway).isEmpty)
        XCTAssertTrue(NoticeScope.filter(busTimetable, mode: .train).isEmpty)
        let metroTimetable = [reach(FerryFeed.Source.septaMetro.name, lasting: true)]
        XCTAssertEqual(NoticeScope.filter(metroTimetable, mode: .subway, stationIDs: ["smt:2457", "pat:11"]), metroTimetable)
        XCTAssertTrue(NoticeScope.filter(metroTimetable, mode: .subway, stationIDs: ["pat:11"]).isEmpty)
        XCTAssertTrue(NoticeScope.filter(metroTimetable, mode: .bus).isEmpty)
        let patco = [reach(FerryFeed.Source.patco.name, lasting: true)]
        XCTAssertEqual(NoticeScope.filter(patco, mode: .subway, stationIDs: ["pat:11"]), patco)
        XCTAssertTrue(NoticeScope.filter(patco, mode: .subway, stationIDs: ["smt:2457"]).isEmpty)
    }

    /// Offline is about this Mac, and a name the scope doesn't know can't be placed: both show everywhere
    func testOfflineAndUnknownProvidersShowEverywhere() {
        let offline = [NetworkReach.Notice(provider: "", problem: .offline, since: t0)]
        let unknown = [reach("example.org")]
        for mode in TransitSystem.modes {
            XCTAssertEqual(NoticeScope.filter(offline, mode: mode), offline)
            XCTAssertEqual(NoticeScope.filter(offline, mode: mode, stationIDs: ["R16"]), offline)
            XCTAssertEqual(NoticeScope.filter(unknown, mode: mode, stationIDs: ["nyf:87"]), unknown)
        }
    }

    /// Every name a download can record is known, and covers that download's own stations
    func testEveryRecordedProviderIsKnown() throws {
        func parts(host url: URL?, lasting: Bool = false) throws -> Set<NoticeScope.Part> {
            let host = try XCTUnwrap(try XCTUnwrap(url).host)
            return try XCTUnwrap(NoticeScope.parts(provider: RateLimit.provider(forHost: host), lasting: lasting), host)
        }
        // Timetables are recorded under the operator's own name
        for source in FerryFeed.Source.allCases {
            let p = try XCTUnwrap(NoticeScope.parts(provider: source.name, lasting: true), source.name)
            XCTAssertTrue(p.contains(source == .njTransitBus ? .bus("") : .source(source)), source.name)
            if source.realtimeURL != nil {
                XCTAssertTrue(try parts(host: source.realtimeURL).contains(.source(source)), source.name)
            }
        }
        for feed in RegionalBusFeed.all {
            XCTAssertEqual(NoticeScope.parts(provider: feed.name, lasting: true), [.bus(feed.code)], feed.name)
            if let url = feed.realtimeURL ?? feed.keyedRealtimeURL {
                XCTAssertTrue(try parts(host: url).contains(.bus(feed.code)), feed.name)
            }
        }
        // Live data is recorded by host
        XCTAssertTrue(try parts(host: PathLive.url).contains(.source(.path)))
        XCTAssertEqual(try parts(host: BusTimeLoader.endpoint), [.mtaBus])
        for feed in MTAFeed.allCases { XCTAssertTrue(try parts(host: feed.url).contains(.subway)) }
        XCTAssertTrue(try parts(host: NJTransitLive.tripUpdatesURL).contains(.source(.njTransitLightRail)))
        XCTAssertEqual(try parts(host: NJTransitLive.Endpoints.bus.tripUpdates), [.bus("")])
        // The monthly MTA subway GTFS is recorded as "MTA", the name its host gets: the subway's monthly data.
        // The bus GTFS on the same host isn't recorded (only the bus map and stop list use it)
        for url in BusMap.sourceURLs { XCTAssertEqual(try parts(host: url, lasting: true), [.subway]) }
    }

    func testStationsBelongToTheirOperator() {
        XCTAssertEqual(NoticeScope.part(ofStation: "R16", mode: .subway), .subway)
        XCTAssertEqual(NoticeScope.part(ofStation: "400123", mode: .bus), .mtaBus)
        XCTAssertEqual(NoticeScope.part(ofStation: RooseveltIslandTram.manhattanStationID, mode: .subway), .tram)
        XCTAssertEqual(NoticeScope.part(ofStation: "path:33S", mode: .subway), .source(.path))
        XCTAssertEqual(NoticeScope.part(ofStation: "njb:12345", mode: .bus), .bus(""))
        XCTAssertEqual(NoticeScope.part(ofStation: "njb:SCT/9", mode: .bus), .bus("SCT"))
        XCTAssertEqual(NoticeScope.Part.source(.njTransitLightRail).mode, .subway)
        XCTAssertEqual(NoticeScope.Part.source(.hartfordLine).mode, .train)
    }
}

final class FetchRetryTests: XCTestCase {
    func testRetriesOnlyFlakyNetworkErrors() {
        XCTAssertTrue(URLSessionFetcher.worthRetry(URLError(.timedOut)))
        XCTAssertTrue(URLSessionFetcher.worthRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(URLSessionFetcher.worthRetry(URLError(.dnsLookupFailed)))
        XCTAssertFalse(URLSessionFetcher.worthRetry(URLError(.notConnectedToInternet)))
        XCTAssertFalse(URLSessionFetcher.worthRetry(URLError(.cancelled)))
        XCTAssertFalse(URLSessionFetcher.worthRetry(URLError(.badURL)))
    }

    /// The one retry after a flaky failure checks again first: turned off meanwhile (the network switch, a pause), it doesn't go
    /// online a second time; otherwise it does, once
    func testTheRetryChecksAgainBeforeGoingOnline() async throws {
        let tries = KeyedRequestsTests.Counter()
        let checks = KeyedRequestsTests.Counter()
        func flaky(_ lastTry: Bool) throws -> Int {
            _ = tries.next()
            if !lastTry { throw URLError(.timedOut) }
            return 7
        }
        let got = try await URLSessionFetcher.retrying(delay: 0, check: { _ = checks.next() }) { try flaky($0) }
        XCTAssertEqual(got, 7)
        XCTAssertEqual(tries.count, 2)
        XCTAssertEqual(checks.count, 1)
        let off = KeyedRequestsTests.Counter()
        do {
            // What the switch says when it's off (NetworkSwitch.check)
            _ = try await URLSessionFetcher.retrying(delay: 0, check: { throw URLError(.notConnectedToInternet) }) { _ -> Int in
                _ = off.next()
                throw URLError(.timedOut)
            }
            XCTFail("the switch was off")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(off.count, 1, "no second try")
        // A failure not worth a retry isn't checked or tried again
        let once = KeyedRequestsTests.Counter()
        let notChecked = KeyedRequestsTests.Counter()
        do {
            _ = try await URLSessionFetcher.retrying(delay: 0, check: { _ = notChecked.next() }) { _ -> Int in
                _ = once.next()
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("not connected")
        } catch {}
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(notChecked.count, 0)
    }

    /// Standby or the switch turned off stops the shared download for every operator waiting for it, and keeps nothing: the
    /// next ask downloads again
    func testStoppingTheSharedDownloadsCancelsThemForEveryone() async throws {
        SharedLive.reset()
        defer { SharedLive.reset() }
        let url = URL(string: "https://example.com/shared-test.pb")!
        let started = expectation(description: "started")
        started.expectedFulfillmentCount = 1
        let downloads = KeyedRequestsTests.Counter()
        func waiter() -> Task<Data, Error> {
            Task {
                try await SharedLive.data(url) {
                    if downloads.next() == 1 { started.fulfill() }
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return Data("late".utf8)
                }
            }
        }
        let first = waiter()
        await fulfillment(of: [started], timeout: 5)
        let second = waiter()
        try await Task.sleep(nanoseconds: 50_000_000)
        SharedLive.cancelAll()
        // Asked again at once, before the stopped ones are through: a new download, not the stopped one
        let next = try await SharedLive.data(url) { Data("fresh".utf8) }
        XCTAssertEqual(next, Data("fresh".utf8))
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        XCTAssertEqual(downloads.count, 1, "downloaded once for both")
        // The stopped ones, when through, leave the new one as it is
        let again = try await SharedLive.data(url) { Data("other".utf8) }
        XCTAssertEqual(again, Data("fresh".utf8))
    }

    /// A pause after "too many requests" belongs to the key that got it: testing a different Bus Time key still goes online,
    /// but the network switch in Settings still stops it
    func testKeyTestCanSkipTheRateLimitPause() throws {
        let host = "bustime.mta.info"
        UserDefaults.standard.removeObject(forKey: NetworkSwitch.defaultsKey)
        RateLimit.cleared(host: host)
        defer {
            RateLimit.cleared(host: host)
            UserDefaults.standard.removeObject(forKey: NetworkSwitch.defaultsKey)
        }
        XCTAssertTrue(URLSessionFetcher().checksPause)
        XCTAssertFalse(URLSessionFetcher(checksPause: false).checksPause)
        let url = BusTimeLoader.url(key: "k", stopID: CredentialTester.busTimeTestStop)
        XCTAssertNoThrow(try URLSessionFetcher.precheck(url, checksPause: true))
        RateLimit.hit(host: host)
        XCTAssertThrowsError(try URLSessionFetcher.precheck(url, checksPause: true)) { error in
            XCTAssertEqual(error as? FeedFetchError, .httpStatus(429))
        }
        XCTAssertNoThrow(try URLSessionFetcher.precheck(url, checksPause: false))
        UserDefaults.standard.set(false, forKey: NetworkSwitch.defaultsKey)
        XCTAssertThrowsError(try URLSessionFetcher.precheck(url, checksPause: false)) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    /// Bus Time answers in JSON: it's asked for that, not for GTFS-Realtime, also when a key is tested
    func testBusTimeAsksForJSON() {
        let catalog = BusCatalog(feedVersion: "", routes: [:], stops: [])
        XCTAssertEqual((BusTimeLoader(key: "k", catalog: catalog).fetcher as? URLSessionFetcher)?.accept, BusTimeLoader.accept)
        XCTAssertTrue(BusTimeLoader.accept.hasPrefix("application/json"))
        XCTAssertFalse(BusTimeLoader.accept.contains("protobuf"))
        XCTAssertFalse(BusTimeLoader.accept.contains("html"), "A web page still counts as bad data (see NetworkReach.isWebPage)")
    }
}

/// A download bigger than any real data of its kind is stopped (see DownloadLimit)
final class DownloadLimitTests: XCTestCase {
    /// At most `limit` downloads run at once; the others wait their turn and all of them finish, also the ones that throw
    func testDownloadsTakeTurns() async throws {
        let slots = DownloadSlots(limit: 3)
        struct Failed: Error {}
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for i in 0..<20 {
                group.addTask {
                    do {
                        return try await slots.run { () async throws -> Bool in
                            try await Task.sleep(nanoseconds: 5_000_000)
                            if i % 5 == 0 { throw Failed() }
                            return true
                        }
                    } catch {
                        return false
                    }
                }
            }
            var all: [Bool] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertEqual(results.filter { $0 }.count, 16)
        let most = await slots.most
        XCTAssertEqual(most, 3)
        // Every turn was given back: three more run at once right away
        await slots.take(); await slots.take(); await slots.take()
        await slots.give(); await slots.give(); await slots.give()
    }

    // MARK: The same work for several items at once (Together)

    /// A little wait that differs from item to item, so the results come in another order than the items were given in
    private static func wait(_ n: Int) async { try? await Task.sleep(nanoseconds: UInt64(1_000_000 * (n * 7 % 5))) }

    /// Every item's result comes back under that item, whatever it looks like: a success or a failure, nothing, several values
    /// together. This is what an optimized build got wrong with results handed back by the group itself (see Together), so the
    /// shapes here are the app's own
    func testTogetherKeepsEachResultUnderItsOwnItem() async {
        struct Package: Sendable, Equatable {
            var files: [String: Data]
            var zip: Data?
        }
        struct Failed: Error, Equatable { var code: String }
        struct Live: Sendable, Equatable {
            var prefix: String
            var trips: [String: Int]
        }
        struct Answer: Sendable, Equatable {
            var live: Live?
            var rejected = false
            var keyRejected = false
            var skipped = false
        }
        for sources in [[FerryFeed.Source.lirr, .metroNorth, .njTransitRail, .amtrakNY, .hartfordLine, .septaRail], [.njTransitLightRail], [.nycFerry]] {
            let codes = sources.map(\.rawValue)
            // A timetable package or an error for each operator
            let packages = await Together.each(sources) { source -> Result<Package, Error> in
                await Self.wait(source.rawValue.count)
                if source == .amtrakNY { return .failure(Failed(code: source.rawValue)) }
                return .success(Package(files: ["id": Data(source.rawValue.utf8)], zip: Data(repeating: 1, count: 100 * source.rawValue.count)))
            }
            XCTAssertEqual(Set(packages.keys), Set(sources))
            for source in sources {
                switch packages[source] {
                case .success(let package)?:
                    XCTAssertNotEqual(source, .amtrakNY)
                    XCTAssertEqual(package.files, ["id": Data(source.rawValue.utf8)], source.rawValue)
                    XCTAssertEqual(package.zip?.count, 100 * source.rawValue.count, source.rawValue)
                case .failure(let error)?:
                    XCTAssertEqual(source, .amtrakNY)
                    XCTAssertEqual(error as? Failed, Failed(code: source.rawValue))
                case nil:
                    XCTFail("No answer for \(source.rawValue)")
                }
            }
            // Live data or nothing for each operator
            let live = await Together.each(sources) { source -> Live? in
                await Self.wait(source.rawValue.count)
                return source == .metroNorth ? nil : Live(prefix: source.rawValue, trips: ["n": source.rawValue.count])
            }
            XCTAssertEqual(Set(live.keys), Set(sources))
            for source in sources {
                let expected = source == .metroNorth ? nil : Live(prefix: source.rawValue, trips: ["n": source.rawValue.count])
                XCTAssertEqual(live[source] ?? nil, expected, source.rawValue)
            }
            // Several values for each bus company, by its code
            let answers = await Together.each(codes) { code -> Answer in
                await Self.wait(code.count)
                return Answer(live: code == "amk" ? nil : Live(prefix: code, trips: [:]), rejected: code == "mnr", skipped: code == "amk")
            }
            XCTAssertEqual(Set(answers.keys), Set(codes))
            for code in codes {
                XCTAssertEqual(answers[code], Answer(live: code == "amk" ? nil : Live(prefix: code, trips: [:]), rejected: code == "mnr",
                                                     keyRejected: false, skipped: code == "amk"), code)
            }
            // A route length or nothing for each station, by its id
            let meters = await Together.each(codes) { code -> Double? in
                await Self.wait(code.count)
                return code == "srr" ? nil : Double(code.count)
            }
            XCTAssertEqual(meters.compactMapValues { $0 }, Dictionary(uniqueKeysWithValues: codes.filter { $0 != "srr" }.map { ($0, Double($0.count)) }))
            XCTAssertEqual(meters.count, codes.count)
            // A stop's buses and time or an error for each place in a list
            let stops = await Together.each(Array(sources.indices)) { index -> Result<Live, BusTimeError> in
                await Self.wait(index)
                return index == 1 ? .failure(.httpStatus(500)) : .success(Live(prefix: codes[index], trips: ["i": index]))
            }
            XCTAssertEqual(stops.count, sources.count)
            for index in sources.indices {
                switch stops[index] {
                case .success(let stop)?: XCTAssertEqual(stop, Live(prefix: codes[index], trips: ["i": index]))
                case .failure(let error)?: XCTAssertEqual(index, 1); XCTAssertEqual(error, .httpStatus(500))
                case nil: XCTFail("No answer for stop \(index)")
                }
            }
        }
    }

    /// At most `limit` at once and every one done; an item listed twice is done once; no items, no results
    func testTogetherTakesTurnsAndDoesEachItemOnce() async {
        actor Count {
            private var now = 0
            private(set) var most = 0
            private(set) var calls: [Int: Int] = [:]
            func enter(_ item: Int) { now += 1; most = max(most, now); calls[item, default: 0] += 1 }
            func leave() { now -= 1 }
        }
        let count = Count()
        let squares = await Together.each(Array(0..<20) + [3, 7, 7], limit: 4) { i -> Int in
            await count.enter(i)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await count.leave()
            return i * i
        }
        XCTAssertEqual(squares, Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, $0 * $0) }))
        let calls = await count.calls
        XCTAssertEqual(calls, Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, 1) }))
        let most = await count.most
        XCTAssertLessThanOrEqual(most, 4)
        XCTAssertGreaterThan(most, 1, "They run at once, not one after another")
        // A limit below one is one at a time
        let one = Count()
        let same = await Together.each([1, 2, 3], limit: 0) { i -> Int in
            await one.enter(i)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await one.leave()
            return i
        }
        XCTAssertEqual(same, [1: 1, 2: 2, 3: 3])
        let mostOfOne = await one.most
        XCTAssertEqual(mostOfOne, 1)
        let none = await Together.each([Int]()) { $0 }
        XCTAssertEqual(none, [:])
    }

    /// Stopping the task that asked (standby) stops each piece of work, and each still hands in its result
    func testTogetherPassesStoppingOn() async {
        let task = Task {
            await Together.each([1, 2, 3]) { _ -> Bool in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return Task.isCancelled
            }
        }
        task.cancel()
        let stopped = await task.value
        XCTAssertEqual(stopped, [1: true, 2: true, 3: true])
    }

    func testWhatCountsAsOver() {
        XCTAssertTrue(DownloadLimit.isOver(expected: 21, received: 0, limit: 20), "The size the server said, before any of it came")
        XCTAssertTrue(DownloadLimit.isOver(expected: -1, received: 21, limit: 20), "What came so far, the size not said")
        XCTAssertFalse(DownloadLimit.isOver(expected: -1, received: 20, limit: 20))
        XCTAssertFalse(DownloadLimit.isOver(expected: 20, received: 20, limit: 20))
        XCTAssertLessThan(DownloadLimit.live, DownloadLimit.package)
        XCTAssertEqual(URLSessionFetcher().limit, DownloadLimit.live)
        // Ended before the last look: what came decides
        XCTAssertTrue(SizeWatch(limit: 10).finish(received: 11))
        XCTAssertFalse(SizeWatch(limit: 10).finish(received: 10))
        XCTAssertFalse(SizeWatch(limit: 10).finish())
    }

    /// A data: address is answered without the network: under the limit the answer comes as before, over it the download throws
    func testAnswerOverTheLimitIsStopped() async throws {
        let url = try XCTUnwrap(URL(string: "data:text/plain," + String(repeating: "a", count: 2_000)))
        let (data, _) = try await URLSession.shared.limitedData(for: URLRequest(url: url), limit: 2_000)
        XCTAssertEqual(data.count, 2_000)
        do {
            _ = try await URLSession.shared.limitedData(for: URLRequest(url: url), limit: 1_999)
            XCTFail("Over the limit")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .tooLarge)
        }
        UserDefaults.standard.removeObject(forKey: NetworkSwitch.defaultsKey)
        let fetched = try await URLSessionFetcher(limit: 2_000).fetch(url)
        XCTAssertEqual(fetched.count, 2_000)
        do {
            _ = try await URLSessionFetcher(limit: 1_000).fetch(url)
            XCTFail("Over the limit")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .tooLarge, "Not retried, not a network problem")
        }
    }

    #if canImport(Darwin)
    /// The same for a download to a file, which is kept for the caller to move (Linux's URLSession doesn't download data:
    /// addresses to a file; the app's downloads to a file run on macOS only)
    func testDownloadToAFileOverTheLimitIsStopped() async throws {
        let url = try XCTUnwrap(URL(string: "data:text/plain," + String(repeating: "b", count: 3_000)))
        let (file, _) = try await URLSession.shared.limitedDownload(for: URLRequest(url: url), limit: 3_000)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file).count, 3_000)
        do {
            _ = try await URLSession.shared.limitedDownload(for: URLRequest(url: url), limit: 2_999)
            XCTFail("Over the limit")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .tooLarge)
        }
    }
    #endif
}

/// The clock offset is read only from the servers whose time is used: the MTA's, MBTA's and SEPTA's own and GitHub's API
final class ClockSkewSourceTests: XCTestCase {
    func testOnlyKnownServersAreTrusted() {
        func source(_ s: String) -> String? { ClockSkew.source(of: URL(string: s)!) }
        XCTAssertEqual(source("https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs"), "MTA")
        XCTAssertEqual(source("https://bustime.mta.info/api/siri/stop-monitoring.json"), "MTA")
        XCTAssertEqual(source("https://cdn.mbta.com/realtime/TripUpdates.pb"), "MBTA")
        XCTAssertEqual(source("https://www3.septa.org/gtfsrt/septa-pa-us/Trip/print.php"), "SEPTA")
        XCTAssertEqual(source("https://api.github.com/repos/x/y/releases/latest"), "GitHub")
        XCTAssertNil(source("https://raw.githubusercontent.com/x/y/main/source-list.json"))
        XCTAssertNil(source("https://westchester-gmv.itoworld.com/production/tripupdates.pb"))
        XCTAssertNil(source("https://notmta.info.example.com/x"))
        XCTAssertNil(source("https://evilmta.info/x"))
        XCTAssertNil(source("https://mbta.com.example.org/x"))
        XCTAssertNil(source("https://notsepta.org/x"))
        XCTAssertTrue(ClockSkew.trusts(URL(string: "https://cdn.mbta.com/x")!))
        XCTAssertFalse(ClockSkew.trusts(URL(string: "https://evilmta.info/x")!))
    }
}

/// The offset is the one at least two servers agree on (up to 12 hours); one server alone counts only when it is the MTA's, up to
/// 15 minutes. So one server whose clock is off, or an old cached answer, doesn't move every countdown
final class ClockSkewDecisionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() { ClockSkew.forgetReadings() }
    override func tearDown() { ClockSkew.forgetReadings() }

    func testTwoServersThatAgreeAreFollowed() {
        ClockSkew.note(600, from: "MBTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 0, "One server other than the MTA's isn't followed alone")
        ClockSkew.note(610, from: "SEPTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 605, "The middle of the two")
        ClockSkew.note(5 * 3600, from: "MBTA", at: t0)
        ClockSkew.note(5 * 3600 + 10, from: "SEPTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 5 * 3600 + 5, "Hours off, when two agree")
        ClockSkew.note(13 * 3600, from: "MBTA", at: t0)
        ClockSkew.note(13 * 3600, from: "SEPTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 0, "More than 12 hours isn't followed")
    }

    func testOneServerThatDisagreesIsLeftOut() {
        ClockSkew.note(300, from: "MTA", at: t0)
        ClockSkew.note(305, from: "MBTA", at: t0)
        ClockSkew.note(-4000, from: "GitHub", at: t0)
        XCTAssertEqual(ClockSkew.current, 302.5)
        // Two pairs: the one nearer no offset
        ClockSkew.note(-1000, from: "SEPTA", at: t0)
        ClockSkew.note(-1010, from: "GitHub", at: t0)
        XCTAssertEqual(ClockSkew.current, 302.5)
    }

    func testWithoutAgreementOnlyTheMTAsCountsAlone() {
        ClockSkew.note(200, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 200)
        ClockSkew.note(-500, from: "SEPTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 200, "SEPTA disagrees: the MTA's alone")
        ClockSkew.note(1200, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 0, "The MTA's alone isn't followed beyond 15 minutes")
        ClockSkew.note(20, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 0, "Under 30 seconds counts as none")
    }

    func testReadingsOlderThanADayAreLeftOut() {
        ClockSkew.note(600, from: "MBTA", at: t0)
        ClockSkew.note(600, from: "SEPTA", at: t0.addingTimeInterval(25 * 3600))
        XCTAssertEqual(ClockSkew.current, 0, "The MBTA's reading is a day old")
    }

    /// The widget starts from the main app's offset (it may rest on several servers) and weighs its own readings with it
    func testTheWidgetAdoptsTheAppsOffset() {
        ClockSkew.adopt(2 * 3600, now: t0)
        XCTAssertEqual(ClockSkew.current, 2 * 3600)
        ClockSkew.note(2 * 3600 + 5, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 2 * 3600 + 2.5)
        ClockSkew.forgetReadings()
        XCTAssertEqual(ClockSkew.current, 0, "The Mac's clock was changed")
    }

    /// The main window and Settings say so from two minutes off
    func testTheNoticeStartsAtTwoMinutes() {
        ClockSkew.note(100, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.current, 100)
        XCTAssertNil(ClockSkew.noticeOffset)
        ClockSkew.note(-150, from: "MTA", at: t0)
        XCTAssertEqual(ClockSkew.noticeOffset, -150)
    }

    /// Read from a successful answer's Date header, only from the servers whose time is used and never from a cached answer
    func testReadFromTheDateHeader() throws {
        let local = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T02:00:00Z"))
        func response(_ url: String, status: Int = 200, age: Bool = false) -> HTTPURLResponse {
            var fields = ["Date": "Fri, 16 Oct 2026 02:05:00 GMT"]
            if age { fields["Age"] = "120" }
            return HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: fields)!
        }
        ClockSkew.record(from: response("https://evilmta.info/x"), url: URL(string: "https://evilmta.info/x")!, local: local)
        XCTAssertEqual(ClockSkew.current, 0)
        ClockSkew.record(from: response("https://cdn.mbta.com/x", age: true), url: URL(string: "https://cdn.mbta.com/x")!, local: local)
        ClockSkew.record(from: response("https://www3.septa.org/x", status: 500), url: URL(string: "https://www3.septa.org/x")!, local: local)
        ClockSkew.record(from: response("https://api-endpoint.mta.info/x"), url: URL(string: "https://api-endpoint.mta.info/x")!, local: local)
        XCTAssertEqual(ClockSkew.current, 300, "Only the MTA's reading counted")
    }
}

/// Live data asked for with the user's own key or account: at most once a minute, the last answer (or failure) given again in
/// between, so the provider doesn't limit the key
final class KeyedRequestsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let url = URL(string: "https://bustime.mta.info/api/siri/stop-monitoring.json?key=K&MonitoringRef=400001")!
    override func setUp() { KeyedRequests.reset() }
    override func tearDown() { KeyedRequests.reset() }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            n += 1
            return n
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return n
        }
    }

    func testTheSameRequestIsAskedOnceAMinute() async throws {
        let calls = Counter()
        let key = KeyedRequests.key(url, nil)
        func ask(_ seconds: TimeInterval, _ key: Int) async throws -> Data {
            try await KeyedRequests.answer(for: key, now: t0.addingTimeInterval(seconds)) { Data("\(calls.next())".utf8) }
        }
        let first = try await ask(0, key)
        let every30 = try await ask(30, key)
        let early = try await ask(54, key)
        let next = try await ask(56, key)
        XCTAssertEqual([first, every30, early, next].map { String(decoding: $0, as: UTF8.self) }, ["1", "1", "1", "2"],
                       "A refresh every 30 seconds gets the same answer; one due every minute may come a few seconds early")
        // Another address or another key is another request
        XCTAssertNotEqual(KeyedRequests.key(url, "Bearer x"), key)
        let other = try await ask(57, KeyedRequests.key(URL(string: "https://bustime.mta.info/x?key=K&MonitoringRef=400002")!, nil))
        XCTAssertEqual(String(decoding: other, as: UTF8.self), "3")
        XCTAssertEqual(calls.count, 3)
    }

    func testAFailureIsGivenAgainButAStoppedRequestIsNot() async {
        let calls = Counter()
        let key = KeyedRequests.key(url, nil)
        do {
            _ = try await KeyedRequests.answer(for: key, now: t0) { _ = calls.next(); throw URLError(.timedOut) }
            XCTFail("expected the failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        do {
            _ = try await KeyedRequests.answer(for: key, now: t0.addingTimeInterval(10)) { _ = calls.next(); return Data() }
            XCTFail("expected the same failure again")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(calls.count, 1, "Not asked again within the minute")
        // Stopped (standby, or the caller moved on): not kept, so the next one asks
        let stopped = KeyedRequests.key(url, "Bearer token")
        do {
            _ = try await KeyedRequests.answer(for: stopped, now: t0) { _ = calls.next(); throw CancellationError() }
            XCTFail("expected the cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let data = try? await KeyedRequests.answer(for: stopped, now: t0.addingTimeInterval(1)) { _ = calls.next(); return Data("ok".utf8) }
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(calls.count, 3)
    }

    /// Decided by the request itself: a key in the address or a sign-in header, not by a list of companies
    func testWhichRequestsCarryAKey() {
        XCTAssertTrue(URLSessionFetcher.carriesKey(url: url, authorization: nil))
        XCTAssertTrue(URLSessionFetcher.carriesKey(url: URL(string: "https://api.goswift.ly/real-time/x/gtfs-rt-trip-updates")!,
                                                   authorization: "my-key"))
        XCTAssertFalse(URLSessionFetcher.carriesKey(url: URL(string: "https://cdn.mbta.com/realtime/TripUpdates.pb")!, authorization: nil))
        XCTAssertFalse(URLSessionFetcher.carriesKey(url: URL(string: "https://example.com/x?monkey=1")!, authorization: nil))
    }
}

/// After turning off "Allow network" in Settings, no downloads are sent
final class NetworkSwitchTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: NetworkSwitch.defaultsKey)
        super.tearDown()
    }

    func testAllowedByDefault() {
        UserDefaults.standard.removeObject(forKey: NetworkSwitch.defaultsKey)
        XCTAssertTrue(NetworkSwitch.isAllowed)
        XCTAssertNoThrow(try NetworkSwitch.check())
    }

    func testOffStopsEveryDownload() async {
        UserDefaults.standard.set(false, forKey: NetworkSwitch.defaultsKey)
        XCTAssertFalse(NetworkSwitch.isAllowed)
        // The address is deliberately unusable: if actually sent, the error would be something other than notConnectedToInternet
        let url = URL(string: "https://invalid.invalid/feed")!
        do {
            _ = try await URLSessionFetcher(timeout: 1).fetch(url)
            XCTFail("fetch should not run")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        #if canImport(Darwin)
        do {
            _ = try await URLSession.shared.reachData(for: URLRequest(url: url))
            XCTFail("reachData should not run")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        #endif
    }

    // The app and the widget each save in their own settings, under one name; anything else (these tests) uses the standard
    // UserDefaults. The app's settings and the check before downloads use the same one, so turning the switch off stops every download
    func testSettingsAndTheCheckBeforeDownloadsShareOneStore() {
        XCTAssertTrue(SharedDefaults.own(bundleIdentifier: nil) === UserDefaults.standard)
        XCTAssertTrue(SharedDefaults.own(bundleIdentifier: "com.example.SomethingElse") === UserDefaults.standard)
        XCTAssertFalse(SharedDefaults.own(bundleIdentifier: "com.cheecar.CatchMyTrain") === UserDefaults.standard)
        XCTAssertFalse(SharedDefaults.own(bundleIdentifier: "com.cheecar.CatchMyTrain.Widget") === UserDefaults.standard)
        // These tests are neither the app nor the widget
        XCTAssertTrue(SharedDefaults.current === UserDefaults.standard)
        NetworkSwitch.setAllowed(false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: NetworkSwitch.defaultsKey) as? Bool, false)
        XCTAssertThrowsError(try NetworkSwitch.check())
        NetworkSwitch.setAllowed(true)
        XCTAssertNoThrow(try NetworkSwitch.check())
    }

    // The switch is read from the store it was saved in, and only there
    func testSwitchReadsTheStoreItWasSavedIn() throws {
        let suite = "CatchCoreTests.networkSwitch"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NetworkSwitch.isAllowed(in: store))
        NetworkSwitch.setAllowed(false, in: store)
        XCTAssertFalse(NetworkSwitch.isAllowed(in: store))
        XCTAssertTrue(NetworkSwitch.isAllowed, "the shared store is untouched")
    }
}

/// Since when an operator-side problem has lasted, kept across launches (the "Not working since" line after 14 days)
extension NetworkReachTests {
    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: NetworkReach.History] = [:]
        private var count = 0
        var history: [String: NetworkReach.History] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        /// How many times it was saved
        var saves: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func save(_ h: [String: NetworkReach.History]) {
            lock.lock(); defer { lock.unlock() }
            value = h
            count += 1
        }
    }

    private var amtrak: URL { FerryFeed.Source.amtrakNY.url }
    private var day: TimeInterval { 86_400 }

    func testProblemHistorySurvivesARelaunch() {
        let saved = Saved()
        NetworkReach.keepHistory([:], save: { saved.save($0) })
        NetworkReach.record(status: 404, url: amtrak, provider: "Amtrak", lasting: true, now: t0)
        XCTAssertEqual(saved.history["Amtrak"]?.since, t0)
        // The app quits; the next launch restores it, and the in-memory notices are empty until the next try
        NetworkReach.reset()
        NetworkReach.keepHistory(saved.history, save: { saved.save($0) })
        XCTAssertTrue(NetworkReach.notices(now: t0.addingTimeInterval(day)).isEmpty)
        NetworkReach.record(status: 404, url: amtrak, provider: "Amtrak", lasting: true, now: t0.addingTimeInterval(2 * day))
        XCTAssertEqual(NetworkReach.problemHistory["Amtrak"]?.since, t0)
        XCTAssertNil(NetworkReach.longProblemSince("Amtrak", now: t0.addingTimeInterval(13 * day)))
        XCTAssertEqual(NetworkReach.longProblemSince("Amtrak", now: t0.addingTimeInterval(14 * day)), t0)
    }

    func testProblemHistoryEndsWhenItWorksAgain() {
        let saved = Saved()
        NetworkReach.keepHistory([:], save: { saved.save($0) })
        // A web page comes back instead of the timetable, day after day: the address answers, but the data isn't there
        for d in 0..<3 {
            let now = t0.addingTimeInterval(Double(d) * day)
            NetworkReach.record(status: 200, url: amtrak, provider: "Amtrak", lasting: true, now: now)
            NetworkReach.recordBadData(url: amtrak, provider: "Amtrak", lasting: true, now: now)
        }
        XCTAssertEqual(saved.history["Amtrak"]?.since, t0)
        NetworkReach.record(status: 200, url: amtrak, provider: "Amtrak", lasting: true, now: t0.addingTimeInterval(3 * day))
        XCTAssertEqual(saved.history["Amtrak"]?.since, t0, "Downloaded, not read yet")
        NetworkReach.recordGoodData(url: amtrak, provider: "Amtrak", lasting: true, now: t0.addingTimeInterval(3 * day))
        XCTAssertNil(saved.history["Amtrak"])
        XCTAssertNil(NetworkReach.longProblemSince("Amtrak", now: t0.addingTimeInterval(20 * day)))
        // Server errors end with the next download that gets through
        NetworkReach.record(status: 503, url: amtrak, provider: "Amtrak", lasting: true, now: t0.addingTimeInterval(4 * day))
        XCTAssertEqual(saved.history["Amtrak"]?.since, t0.addingTimeInterval(4 * day))
        NetworkReach.record(status: 200, url: amtrak, provider: "Amtrak", lasting: true, now: t0.addingTimeInterval(5 * day))
        XCTAssertNil(saved.history["Amtrak"])
    }

    /// Days without a try (standby, the app closed) start the count again: the day said is never earlier than what was seen
    func testProblemHistoryRestartsAfterAGap() {
        NetworkReach.keepHistory([:], save: { _ in })
        NetworkReach.record(status: 503, url: ferry, provider: "NYC Ferry", now: t0)
        NetworkReach.record(status: 503, url: ferry, provider: "NYC Ferry", now: t0.addingTimeInterval(3 * day))
        XCTAssertEqual(NetworkReach.problemHistory["NYC Ferry"]?.since, t0)
        NetworkReach.record(status: 503, url: ferry, provider: "NYC Ferry", now: t0.addingTimeInterval(6 * day + 1))
        XCTAssertEqual(NetworkReach.problemHistory["NYC Ferry"]?.since, t0.addingTimeInterval(6 * day + 1))
    }

    /// Only problems on the operator's side count; the network's don't, and they don't end it either
    func testNetworkProblemsAreNotInTheHistory() {
        NetworkReach.keepHistory([:], save: { _ in })
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0)
        NetworkReach.record(status: 403, url: mta, now: t0)
        XCTAssertTrue(NetworkReach.problemHistory.isEmpty)
        NetworkReach.recordGoodData(url: mta, timestamp: t0.addingTimeInterval(-3600), now: t0)
        XCTAssertEqual(NetworkReach.problemHistory["MTA"]?.since, t0, "Live data not updating is the operator's side")
        NetworkReach.record(error: URLError(.timedOut), url: mta, now: t0.addingTimeInterval(60))
        XCTAssertEqual(NetworkReach.problemHistory["MTA"]?.since, t0)
        NetworkReach.recordGoodData(url: mta, timestamp: t0.addingTimeInterval(120), now: t0.addingTimeInterval(120))
        XCTAssertNil(NetworkReach.problemHistory["MTA"])
    }

    /// The time of the last failure is saved at most hourly; a new problem at once
    func testProblemHistoryIsNotSavedOnEveryFailure() {
        let saved = Saved()
        NetworkReach.keepHistory([:], save: { saved.save($0) })
        for minute in 0..<30 {
            NetworkReach.record(status: 503, url: ferry, provider: "NYC Ferry", now: t0.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertEqual(saved.saves, 1)
        NetworkReach.record(status: 503, url: ferry, provider: "NYC Ferry", now: t0.addingTimeInterval(3601))
        XCTAssertEqual(saved.saves, 2)
        XCTAssertEqual(saved.history["NYC Ferry"]?.last, t0.addingTimeInterval(3601))
    }
}
