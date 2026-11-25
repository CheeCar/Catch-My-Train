import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TransitCore

/// Fake POST: returns prepared responses by URL and records how many times it was called
final class FakePoster: FormPosting, @unchecked Sendable {
    private let lock = NSLock()
    var replies: [String: [Result<Data, Error>]]
    private(set) var calls: [(String, [(String, String)])] = []

    init(replies: [String: [Result<Data, Error>]]) { self.replies = replies }

    func post(_ url: URL, fields: [(String, String)]) async throws -> Data {
        let result: Result<Data, Error> = lock.withLock {
            calls.append((url.lastPathComponent, fields))
            var list = replies[url.lastPathComponent] ?? []
            let r = list.isEmpty ? .failure(URLError(.badServerResponse)) : list.removeFirst()
            replies[url.lastPathComponent] = list
            return r
        }
        return try result.get()
    }

    func count(_ name: String) -> Int { lock.withLock { calls.filter { $0.0 == name }.count } }
}

final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ v: String?) { value = v }
    var token: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Fake NJ Transit that answers trip updates with protobuf only for the token it handed out last; sign-ins are slow so refreshes overlap.
/// tokensWork false: even its newest token gets an error message (no access to the feed, or maintenance).
final class TokenServer: FormPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    let protobuf: Data
    let tokensWork: Bool
    init(protobuf: Data, tokensWork: Bool = true) {
        self.protobuf = protobuf
        self.tokensWork = tokensWork
    }

    var signIns: Int { lock.withLock { issued } }

    func post(_ url: URL, fields: [(String, String)]) async throws -> Data {
        if url.lastPathComponent == "getToken" {
            try await Task.sleep(nanoseconds: 50_000_000)
            let n = lock.withLock { issued += 1; return issued }
            return Data(#"{"Authenticated":"True","UserToken":"t\#(n)"}"#.utf8)
        }
        let current = lock.withLock { "t\(issued)" }
        return tokensWork && fields.first?.1 == current ? protobuf : Data(#"{"errorMessage":"Invalid token."}"#.utf8)
    }
}

/// Fake NJ Transit whose sign-ins wait until the test answers them, so a test can remove or switch the account while one is still running.
/// Like a slow server, it ignores the client giving up on a request. Trip updates work only with the tokens in `accepted`.
final class GatedPoster: FormPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var users: [String] = []
    private var waiting: [Int: CheckedContinuation<Data, Error>] = [:]
    private var sent: [String] = []
    private let protobuf: Data
    private let accepted: Set<String>

    init(protobuf: Data, accepted: Set<String>) {
        self.protobuf = protobuf
        self.accepted = accepted
    }

    /// Usernames that asked for a token, in order
    var signIns: [String] { lock.withLock { users } }
    /// Tokens sent to download trip updates, in order
    var tokensSent: [String] { lock.withLock { sent } }

    func post(_ url: URL, fields: [(String, String)]) async throws -> Data {
        if url.lastPathComponent == "getToken" {
            let user = fields.first { $0.0 == "username" }?.1 ?? ""
            return try await withCheckedThrowingContinuation { continuation in
                let n: Int = lock.withLock {
                    users.append(user)
                    waiting[users.count - 1] = continuation
                    return users.count - 1
                }
                // A sign-in the test never answers times out, so a client that signs in when it shouldn't fails the test instead of hanging it
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.reply(n, with: .failure(URLError(.timedOut)))
                }
            }
        }
        let token = fields.first?.1 ?? ""
        lock.withLock { sent.append(token) }
        return accepted.contains(token) ? protobuf : Data(#"{"errorMessage":"Invalid token."}"#.utf8)
    }

    private func reply(_ n: Int, with result: Result<Data, Error>) {
        let waiter = lock.withLock { waiting.removeValue(forKey: n) }
        waiter?.resume(with: result)
    }

    /// Waits until this many sign-ins have been sent
    func waitForSignIns(_ count: Int) async {
        for _ in 0..<5000 {
            if lock.withLock({ users.count }) >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("expected \(count) sign-ins, got \(signIns)")
    }

    /// Waits until this user's sign-in is waiting, then answers it
    func answer(_ user: String, with json: String) async {
        for _ in 0..<5000 {
            let n: Int? = lock.withLock { waiting.keys.sorted().first { users[$0] == user } }
            if let n {
                reply(n, with: .success(Data(json.utf8)))
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("no sign-in from \(user) to answer")
    }
}

/// Fake POST that answers with a closure and records the endpoints called, in order
final class ClosurePoster: FormPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private let answer: @Sendable (String, [(String, String)]) async throws -> Data

    init(_ answer: @escaping @Sendable (String, [(String, String)]) async throws -> Data) { self.answer = answer }

    var calls: [String] { lock.withLock { names } }

    func post(_ url: URL, fields: [(String, String)]) async throws -> Data {
        lock.withLock { names.append(url.lastPathComponent) }
        return try await answer(url.lastPathComponent, fields)
    }
}

/// The lines a client wrote for the app's log, in order
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Where the app keeps the renewal pace between launches
final class PaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NJTransitClient.RenewalPace?
    private(set) var writes = 0
    init(_ pace: NJTransitClient.RenewalPace? = nil) { stored = pace }
    var value: NJTransitClient.RenewalPace? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue; writes += 1 } }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

final class NJTransitLiveTests: XCTestCase {
    let account = NJTransitClient.Account(username: "me", password: "secret")
    /// A minimal GTFS-Realtime message (header only)
    let protobuf = Data([0x0A, 0x05, 0x0A, 0x03, 0x32, 0x2E, 0x30])

    func testToken() throws {
        XCTAssertEqual(try NJTransitLive.token(from: Data(#"{"Authenticated":"True","UserToken":"abc"}"#.utf8)), "abc")
        XCTAssertEqual(try NJTransitLive.token(from: Data(#"{"authenticated":true,"userToken":"xyz"}"#.utf8)), "xyz")
        XCTAssertThrowsError(try NJTransitLive.token(from: Data(#"{"Authenticated":"False","UserToken":""}"#.utf8))) {
            XCTAssertEqual($0 as? NJTransitLive.LiveError, .rejected)
        }
        XCTAssertThrowsError(try NJTransitLive.token(from: Data("<html>".utf8))) {
            XCTAssertEqual($0 as? NJTransitLive.LiveError, .badResponse)
        }
    }

    func testLooksLikeProtobuf() {
        XCTAssertTrue(NJTransitLive.looksLikeProtobuf(protobuf))
        XCTAssertFalse(NJTransitLive.looksLikeProtobuf(Data(#" {"errorMessage":"Invalid token."}"#.utf8)))
        XCTAssertFalse(NJTransitLive.looksLikeProtobuf(Data("<html></html>".utf8)))
        XCTAssertFalse(NJTransitLive.looksLikeProtobuf(Data()))
    }

    /// The rail live data is read for the trains only: the light rail isn't in it (FerryFeed.Source.liveWithAccount)
    func testRealtimeOnlyForTheTrains() throws {
        let rt = try NJTransitLive.realtime(from: protobuf, fetchedAt: Date(), sources: [.njTransitRail, .njTransitLightRail, .lirr])
        XCTAssertEqual(rt.map(\.source), [.njTransitRail])
        XCTAssertTrue(try NJTransitLive.realtime(from: protobuf, fetchedAt: Date(), sources: [.njTransitLightRail]).isEmpty)
        XCTAssertThrowsError(try NJTransitLive.realtime(from: Data("{}".utf8), fetchedAt: Date(), sources: [.njTransitRail]))
    }

    func testFormBody() {
        let body = String(decoding: NJTransitLive.formBody([("username", "me"), ("password", "p w")], boundary: "B"), as: UTF8.self)
        XCTAssertEqual(body, "--B\r\nContent-Disposition: form-data; name=\"username\"\r\n\r\nme\r\n"
                       + "--B\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\np w\r\n--B--\r\n")
    }

    func testAccountSources() {
        XCTAssertTrue(FerryFeed.Source.njTransitRail.needsAccount)
        XCTAssertTrue(FerryFeed.Source.njTransitLightRail.needsAccount)
        XCTAssertFalse(FerryFeed.Source.lirr.needsAccount)
        XCTAssertFalse(FerryFeed.Source.njTransitBus.needsAccount)
        let routes = ["NJT-NEC", "LIRR-BAB"]
        XCTAssertEqual(FerryFeed.realtimeSources(routes: routes), [.lirr])
        XCTAssertEqual(FerryFeed.realtimeSources(routes: routes, accounts: [.njTransitRail, .njTransitLightRail]),
                       FerryFeed.Source.allCases.filter { $0 == .lirr || $0 == .njTransitRail })
        let feed = FerryFeed(versions: [:], routes: [.init(id: "NJT-NEC", name: "Northeast Corridor", color: "F7505E", realtime: false)],
                             piers: [], trips: [], services: [:], shapes: [:])
        XCTAssertFalse(feed.hasRealtime(route: "NJT-NEC"))
        XCTAssertFalse(feed.hasRealtime(route: "NJT-NEC", accounts: []))
        XCTAssertTrue(feed.hasRealtime(route: "NJT-NEC", accounts: [.njTransitRail]))
    }

    /// The saved token works: don't fetch a new one (NJ Transit limits how many times a day you can get one)
    func testReusesSavedToken() async throws {
        let poster = FakePoster(replies: ["getTripUpdates": [.success(protobuf)]])
        let box = TokenBox("saved")
        let client = NJTransitClient(poster: poster, loadToken: { box.token }, saveToken: { box.token = $0 })
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 0)
        XCTAssertEqual(poster.calls.first?.1.first?.1, "saved")
    }

    /// The token doesn't work: get a new token once and retry, and save the new token
    func testRefreshesTokenOnce() async throws {
        let poster = FakePoster(replies: [
            "getTripUpdates": [.success(Data(#"{"errorMessage":"Invalid token."}"#.utf8)), .success(protobuf)],
            "getToken": [.success(Data(#"{"Authenticated":"True","UserToken":"new"}"#.utf8))],
        ])
        let box = TokenBox("old")
        let client = NJTransitClient(poster: poster, loadToken: { box.token }, saveToken: { box.token = $0 })
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(box.token, "new")
        // Refresh again: uses the new token, no new exchange
        poster.replies["getTripUpdates"] = [.success(protobuf)]
        _ = try await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
    }

    /// Wrong account: throws rejected, no endless retries
    func testRejectedAccount() async {
        let poster = FakePoster(replies: [
            "getToken": [.success(Data(#"{"Authenticated":"False"}"#.utf8))],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in })
        do {
            _ = try await client.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(poster.count("getTripUpdates"), 0)
    }

    /// One live download tells the three states Settings shows for a saved account: its data came (works, with no sign-in while
    /// the saved token works), NJ Transit refused it, or it couldn't be told (offline: nothing is signed in for, nothing is refused)
    func testOneDownloadTellsWhetherTheAccountWorks() async {
        func outcome(_ poster: FakePoster, token: String?) async -> Bool? {
            let client = NJTransitClient(poster: poster, loadToken: { token }, saveToken: { _ in })
            do {
                _ = try await client.tripUpdates(account: account)
                return true
            } catch NJTransitLive.LiveError.rejected {
                return false
            } catch {
                return nil
            }
        }
        let working = FakePoster(replies: ["getTripUpdates": [.success(protobuf)]])
        let works = await outcome(working, token: "saved")
        XCTAssertEqual(works, true)
        XCTAssertEqual(working.count("getToken"), 0)

        let refusing = FakePoster(replies: [
            "getTripUpdates": [.success(Data(#"{"errorMessage":"Invalid token."}"#.utf8))],
            "getToken": [.success(Data(#"{"Authenticated":"False"}"#.utf8))],
        ])
        let refused = await outcome(refusing, token: "old")
        XCTAssertEqual(refused, false)
        XCTAssertEqual(refusing.count("getToken"), 1)

        let offline = FakePoster(replies: ["getTripUpdates": [.failure(URLError(.notConnectedToInternet))]])
        let unknown = await outcome(offline, token: "saved")
        XCTAssertNil(unknown)
        XCTAssertEqual(offline.count("getToken"), 0)

        let failing = FakePoster(replies: [
            "getTripUpdates": [.failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(#"{"errorMessage":"GTFS error"}"#)))],
        ])
        let alsoUnknown = await outcome(failing, token: "saved")
        XCTAssertNil(alsoUnknown)
        XCTAssertEqual(failing.count("getToken"), 0)
    }

    /// When NJ Transit refuses the account, its own message is kept (without the username or any token) so the app can show it
    func testRefusalMessageIsKept() async {
        let poster = FakePoster(replies: [
            "getToken": [.success(Data(#"{"Authenticated":"False","UserToken":"x1","errorMessage":"User me is not authorized for GTFSRT"}"#.utf8))],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in })
        do {
            try await client.signIn(account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
        }
        let message = await client.lastRefusal
        XCTAssertEqual(message, "Authenticated: False; errorMessage: User … is not authorized for GTFSRT")
        XCTAssertNil(NJTransitLive.serverMessage(from: Data()))
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data("Service Unavailable".utf8)), "Service Unavailable")
        // Settings shows NJ Transit's words only when they say more than "not accepted"
        XCTAssertFalse(NJTransitLive.saysOnlyRefused(message ?? ""))
        let bare = try? XCTUnwrap(NJTransitLive.serverMessage(from: Data(#"{"Authenticated":"False","UserToken":""}"#.utf8)))
        XCTAssertEqual(bare, "Authenticated: False")
        XCTAssertTrue(NJTransitLive.saysOnlyRefused(bare ?? ""))
        XCTAssertTrue(NJTransitLive.saysOnlyRefused("authenticated: false; "))
        XCTAssertFalse(NJTransitLive.saysOnlyRefused(""))
        XCTAssertFalse(NJTransitLive.saysOnlyRefused("Service Unavailable"))
    }

    /// Bus uses another endpoint (pcsdata's GTFSG2): getting a token is called authenticateUser
    func testBusEndpointsSignIn() async throws {
        let poster = FakePoster(replies: [
            "authenticateUser": [.success(Data(#"{"Authenticated":"True","UserToken":"bus"}"#.utf8))],
            "getTripUpdates": [.success(protobuf)],
        ])
        let box = TokenBox(nil)
        let client = NJTransitClient(poster: poster, endpoints: .bus, loadToken: { box.token }, saveToken: { box.token = $0 })
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("authenticateUser"), 1)
        XCTAssertEqual(poster.count("getToken"), 0)
        XCTAssertEqual(box.token, "bus")
    }

    /// Today's token exchanges are used up: counts as rate limiting, not a wrong account
    func testTokenLimitIsRateLimit() {
        XCTAssertThrowsError(try NJTransitLive.token(from: Data(#"{"Authenticated":"False","errorMessage":"Daily token limit exceeded"}"#.utf8))) {
            XCTAssertEqual($0 as? NJTransitLive.LiveError, .rateLimited)
        }
    }

    /// NJ Transit says the token is invalid on every refresh: the token is renewed once, then not again for a while. The new token
    /// is called invalid too, so the wait is twice minRenewalGap, and it isn't sent again before then.
    func testRenewalIsThrottled() async {
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        let poster = FakePoster(replies: [
            "getTripUpdates": Array(repeating: .success(junk), count: 10),
            "getToken": Array(repeating: .success(Data(#"{"Authenticated":"True","UserToken":"new"}"#.utf8)), count: 3),
        ])
        let clock = TestClock()
        let client = NJTransitClient(poster: poster, loadToken: { "old" }, saveToken: { _ in }, now: { clock.now })
        for _ in 0..<3 {
            do {
                _ = try await client.tripUpdates(account: account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? NJTransitLive.LiveError, .badResponse)
            }
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(poster.count("getTripUpdates"), 2, "the old token and the new one, each once")
        clock.advance(NJTransitClient.minRenewalGap + 1)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(poster.count("getTripUpdates"), 2)
        clock.advance(NJTransitClient.minRenewalGap)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 2)
    }

    /// While renewals are paused, a refused account still reports as refused (Settings keeps showing why)
    func testThrottledRenewalKeepsRefusal() async {
        let poster = FakePoster(replies: [
            "getToken": Array(repeating: .success(Data(#"{"Authenticated":"False"}"#.utf8)), count: 3),
        ])
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in })
        for _ in 0..<2 {
            do {
                _ = try await client.tripUpdates(account: account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
            }
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        // Signing in from Settings is never throttled
        try? await client.signIn(account)
        XCTAssertEqual(poster.count("getToken"), 2)
    }

    /// A renewal that got no answer (timeout) is tried again after a short wait, not the full gap. Meanwhile the token NJ Transit
    /// called invalid isn't sent again; after the wait it's tried once more before signing in.
    func testRenewalRetriesSoonAfterConnectionFailure() async throws {
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        let poster = FakePoster(replies: [
            "getTripUpdates": [.success(junk), .success(junk), .success(protobuf)],
            "getToken": [.failure(URLError(.timedOut)), .success(Data(#"{"Authenticated":"True","UserToken":"new"}"#.utf8))],
        ])
        let clock = TestClock()
        let client = NJTransitClient(poster: poster, loadToken: { "old" }, saveToken: { _ in }, now: { clock.now })
        for _ in 0..<2 {
            do {
                _ = try await client.tripUpdates(account: account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
            }
            clock.advance(60)
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(poster.count("getTripUpdates"), 1)
        clock.advance(NJTransitClient.retryGap)
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 2)
        XCTAssertEqual(poster.count("getTripUpdates"), 3)
        XCTAssertLessThan(NJTransitClient.retryGap, NJTransitClient.minRenewalGap)
    }

    /// Renewals that keep getting no answer wait longer each time (2, 4, 8 … minutes, past the usual gap up to a day); an answer resets it
    func testUnansweredRenewalsBackOff() async throws {
        XCTAssertEqual(NJTransitClient.retryWait(afterUnanswered: 1), NJTransitClient.retryGap)
        XCTAssertEqual(NJTransitClient.retryWait(afterUnanswered: 2), 2 * NJTransitClient.retryGap)
        XCTAssertEqual(NJTransitClient.retryWait(afterUnanswered: 3), 4 * NJTransitClient.retryGap)
        XCTAssertGreaterThan(NJTransitClient.retryWait(afterUnanswered: 6), NJTransitClient.minRenewalGap)
        XCTAssertEqual(NJTransitClient.retryWait(afterUnanswered: 1000), NJTransitClient.maxRenewalGap)
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        // The token NJ Transit called invalid is sent once before each sign-in, not while waiting
        let poster = FakePoster(replies: [
            "getTripUpdates": Array(repeating: Result<Data, Error>.success(junk), count: 4) + [.success(protobuf)],
            "getToken": [.failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .failure(URLError(.timedOut)),
                         .success(Data(#"{"Authenticated":"True","UserToken":"new"}"#.utf8))],
        ])
        let clock = TestClock()
        let client = NJTransitClient(poster: poster, loadToken: { "old" }, saveToken: { _ in }, now: { clock.now })
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
        clock.advance(NJTransitClient.retryGap)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 2)
        // The second one waits twice as long
        clock.advance(NJTransitClient.retryGap)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 2)
        clock.advance(NJTransitClient.retryGap)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 3)
        clock.advance(4 * NJTransitClient.retryGap)
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 4)
        XCTAssertEqual(poster.count("getTripUpdates"), 5)
    }

    /// A whole day in which the token is refused and the sign-in never answers (refreshing every minute) uses about ten sign-ins,
    /// not one every half hour; the refused token is sent once before each of them, not every minute
    func testDayLongOutageUsesFewSignIns() async {
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        // No getToken replies: every sign-in fails as if NJ Transit didn't answer
        let poster = FakePoster(replies: ["getTripUpdates": Array(repeating: .success(junk), count: 24 * 60 + 1)])
        let clock = TestClock()
        let client = NJTransitClient(poster: poster, loadToken: { "old" }, saveToken: { _ in }, now: { clock.now })
        for _ in 0...(24 * 60) {
            _ = try? await client.tripUpdates(account: account)
            clock.advance(60)
        }
        XCTAssertEqual(poster.count("getTripUpdates"), poster.count("getToken"))
        XCTAssertLessThanOrEqual(poster.count("getToken"), 10)
        XCTAssertGreaterThan(poster.count("getToken"), 5)
    }

    /// Two refreshes find the token expired at the same time: one sign-in between them
    func testConcurrentRefreshesShareOneRenewal() async throws {
        let server = TokenServer(protobuf: protobuf)
        let client = NJTransitClient(poster: server, loadToken: { "expired" }, saveToken: { _ in })
        async let a = client.tripUpdates(account: account)
        async let b = client.tripUpdates(account: account)
        let (da, db) = try await (a, b)
        XCTAssertEqual(da, protobuf)
        XCTAssertEqual(db, protobuf)
        XCTAssertEqual(server.signIns, 1)
    }

    // MARK: Removing or switching the account while a sign-in runs

    let old = NJTransitClient.Account(username: "old", password: "p1")
    let new = NJTransitClient.Account(username: "new", password: "p2")

    static func tokenJSON(_ token: String) -> String { #"{"Authenticated":"True","UserToken":""# + token + #""}"# }

    /// The account is removed while its sign-in is still running: the token that comes back afterwards is neither saved nor used
    func testSignInFromBeforeForgetIsDropped() async {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-old"])
        let box = TokenBox(nil)
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let refresh = Task { [old] in try await client.tripUpdates(account: old) }
        await server.waitForSignIns(1)
        await client.forget()
        await server.answer("old", with: Self.tokenJSON("t-old"))
        let result = await refresh.result
        XCTAssertThrowsError(try result.get())
        XCTAssertNil(box.token)
        let token = await client.token
        XCTAssertNil(token)
        XCTAssertEqual(server.tokensSent, [])
    }

    /// After the account is removed, the next account signs in at once: not joined to the old sign-in still running, and the old
    /// account's late refusal is not shown as the new account's. Later refreshes still share the new account's sign-in.
    func testNextAccountDoesNotWaitForForgottenSignIn() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-new"])
        let box = TokenBox(nil)
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let oldRefresh = Task { [old] in try await client.tripUpdates(account: old) }
        await server.waitForSignIns(1)
        await client.forget()
        let newRefresh = Task { [new] in try await client.tripUpdates(account: new) }
        await server.waitForSignIns(2)
        await server.answer("old", with: #"{"Authenticated":"False","errorMessage":"Unknown user"}"#)
        _ = await oldRefresh.result
        let refusal = await client.lastRefusal
        XCTAssertNil(refusal)
        let another = Task { [new] in try await client.tripUpdates(account: new) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(server.signIns, ["old", "new"])
        await server.answer("new", with: Self.tokenJSON("t-new"))
        let first = try await newRefresh.value
        let second = try await another.value
        XCTAssertEqual(first, protobuf)
        XCTAssertEqual(second, protobuf)
        XCTAssertEqual(box.token, "t-new")
        XCTAssertEqual(server.signIns, ["old", "new"])
    }

    /// Trying an account NJ Transit refuses changes nothing: the old account keeps its token, and refreshes meanwhile use it without signing in
    func testRefusedNewAccountKeepsTheOldOne() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-old"])
        let box = TokenBox("t-old")
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let trying = Task { [new] in await client.tryAccount(new) }
        await server.waitForSignIns(1)
        let during = try await client.tripUpdates(account: old)
        XCTAssertEqual(during, protobuf)
        await server.answer("new", with: #"{"Authenticated":"False"}"#)
        let trial = await trying.value
        XCTAssertEqual(trial.works, false)
        XCTAssertNotNil(trial.refusal)
        await client.endTrial()
        XCTAssertEqual(box.token, "t-old")
        let after = try await client.tripUpdates(account: old)
        XCTAssertEqual(after, protobuf)
        XCTAssertEqual(server.signIns, ["new"])
        XCTAssertEqual(server.tokensSent, ["t-old", "t-old"])
        let refusal = await client.lastRefusal
        XCTAssertNil(refusal)
    }

    /// While a new account is being tried, a refresh whose token stopped working doesn't sign in with the old account (it's about to be
    /// replaced, and every sign-in counts against its daily limit). Once the new account is saved, its trial's token is used: no second sign-in.
    func testNoOldAccountSignInWhileTryingNewOne() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-new"])
        let box = TokenBox("expired")
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let trying = Task { [new] in await client.tryAccount(new) }
        await server.waitForSignIns(1)
        do {
            _ = try await client.tripUpdates(account: old)
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(server.signIns, ["new"])
        await server.answer("new", with: Self.tokenJSON("t-new"))
        let trial = await trying.value
        XCTAssertEqual(trial.works, true)
        // Only adopt hands the token over
        XCTAssertEqual(box.token, "expired")
        await client.adopt(trial)
        XCTAssertEqual(box.token, "t-new")
        let data = try await client.tripUpdates(account: new)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(server.signIns, ["new"])
        XCTAssertEqual(server.tokensSent, ["expired", "t-new"])
    }

    /// A saved account NJ Transit refused still reports the refusal while another account is tried (not a stopped refresh), without signing in again
    func testRefusedAccountStaysRefusedWhileTryingNewOne() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: [])
        let box = TokenBox("expired")
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let refused = Task { [old] in try await client.tripUpdates(account: old) }
        await server.waitForSignIns(1)
        await server.answer("old", with: #"{"Authenticated":"False"}"#)
        _ = await refused.result
        let trying = Task { [new] in await client.tryAccount(new) }
        await server.waitForSignIns(2)
        do {
            _ = try await client.tripUpdates(account: old)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
        }
        await server.answer("new", with: #"{"Authenticated":"False"}"#)
        let trial = await trying.value
        XCTAssertEqual(trial.works, false)
        await client.endTrial()
        XCTAssertEqual(server.signIns, ["old", "new"])
    }

    /// A sign-in for the old account that was already running when the new account is adopted can't overwrite the new token
    func testAdoptDropsOldAccountSignIn() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-old", "t-new"])
        let box = TokenBox(nil)
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let oldRefresh = Task { [old] in try await client.tripUpdates(account: old) }
        await server.waitForSignIns(1)
        let trying = Task { [new] in await client.tryAccount(new) }
        await server.waitForSignIns(2)
        await server.answer("new", with: Self.tokenJSON("t-new"))
        let trial = await trying.value
        await client.adopt(trial)
        await server.answer("old", with: Self.tokenJSON("t-old"))
        _ = await oldRefresh.result
        XCTAssertEqual(box.token, "t-new")
        let data = try await client.tripUpdates(account: new)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(server.tokensSent, ["t-new"])
        XCTAssertEqual(server.signIns, ["old", "new"])
    }

    /// The new account was saved although this API refused it (the other API took it): the trial counts as its renewal,
    /// so the next refresh reports the refusal without asking NJ Transit again until the usual gap has passed
    func testAdoptedRefusalWaitsBeforeAskingAgain() async throws {
        let poster = FakePoster(replies: [
            "getToken": [.success(Data(#"{"Authenticated":"False"}"#.utf8)),
                         .success(Data(#"{"Authenticated":"True","UserToken":"later"}"#.utf8))],
            "getTripUpdates": [.success(protobuf)],
        ])
        let clock = TestClock()
        let box = TokenBox("old")
        let client = NJTransitClient(poster: poster, loadToken: { box.token }, saveToken: { box.token = $0 }, now: { clock.now })
        let trial = await client.tryAccount(new)
        XCTAssertEqual(trial.works, false)
        await client.adopt(trial)
        XCTAssertNil(box.token)
        do {
            _ = try await client.tripUpdates(account: new)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        let refusal = await client.lastRefusal
        XCTAssertEqual(refusal, trial.refusal)
        clock.advance(NJTransitClient.minRenewalGap + 1)
        let data = try await client.tripUpdates(account: new)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 2)
        XCTAssertEqual(box.token, "later")
    }

    // MARK: Protecting the daily sign-in limit

    /// New tokens that NJ Transit calls invalid too are kept, and each such renewal doubles the wait before the next: 1 h, then 2 h, …
    /// instead of a sign-in every half hour. A token that works brings the usual pace back.
    func testUnprovenRenewalsBackOff() async throws {
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        let poster = FakePoster(replies: [
            "getTripUpdates": Array(repeating: .success(junk), count: 30),
            "getToken": (1...6).map { Result<Data, Error>.success(Data(Self.tokenJSON("t\($0)").utf8)) },
        ])
        let clock = TestClock()
        let box = TokenBox("stored")
        let client = NJTransitClient(poster: poster, loadToken: { box.token }, saveToken: { box.token = $0 }, now: { clock.now })
        func refresh() async { _ = try? await client.tripUpdates(account: account) }
        // The stored token may simply have expired: renewed at once
        await refresh()
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(box.token, "t1")
        for (renewals, wait) in [(1, 3600.0), (2, 7200.0), (3, 14_400.0)] {
            clock.advance(wait - 60)
            await refresh()
            XCTAssertEqual(poster.count("getToken"), renewals, "still waiting")
            clock.advance(61)
            await refresh()
            XCTAssertEqual(poster.count("getToken"), renewals + 1)
        }
        XCTAssertEqual(box.token, "t4")
        // After the wait t4 is tried once more before signing in, and works after all; when it stops working later, it's renewed
        // after the usual gap
        clock.advance(NJTransitClient.renewalGap(afterUnproven: 4) + 1)
        poster.replies["getTripUpdates"] = [.success(protobuf), .success(junk), .success(protobuf)]
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        clock.advance(NJTransitClient.minRenewalGap + 1)
        let renewed = try await client.tripUpdates(account: account)
        XCTAssertEqual(renewed, protobuf)
        XCTAssertEqual(poster.count("getToken"), 5)
        XCTAssertEqual(box.token, "t5")
    }

    func testRenewalGapDoublesUpToADay() {
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 0), NJTransitClient.minRenewalGap)
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 1), 3600)
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 2), 7200)
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 5), 16 * 3600)
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 6), 24 * 3600)
        XCTAssertEqual(NJTransitClient.renewalGap(afterUnproven: 1000), NJTransitClient.maxRenewalGap)
    }

    /// Two refreshes share a renewal whose new token doesn't work: that's one failed renewal, so the next one waits 1 h, not 2 h
    func testSharedRenewalBacksOffOnce() async {
        let server = TokenServer(protobuf: protobuf, tokensWork: false)
        let clock = TestClock()
        let client = NJTransitClient(poster: server, loadToken: { "expired" }, saveToken: { _ in }, now: { clock.now })
        let a = Task { [account] in try? await client.tripUpdates(account: account) }
        let b = Task { [account] in try? await client.tripUpdates(account: account) }
        _ = await (a.value, b.value)
        XCTAssertEqual(server.signIns, 1)
        clock.advance(NJTransitClient.renewalGap(afterUnproven: 1) + 1)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(server.signIns, 2)
    }

    /// The daily sign-in limit is recognized with or without Authenticated, from specific phrases in message fields only;
    /// a token that came back is always used
    func testTokenLimitPhrases() {
        func outcome(_ json: String) -> NJTransitLive.LiveError? {
            do {
                _ = try NJTransitLive.token(from: Data(json.utf8))
                return nil
            } catch {
                return error as? NJTransitLive.LiveError
            }
        }
        XCTAssertEqual(outcome(#"{"errorMessage":"Daily limit exceeded"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"Message":"TOO MANY REQUESTS"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"Authenticated":"True","error":"Token limit exceeded for today"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"Authenticated":"False","errorMessage":"Your daily limit of tokens is used up"}"#), .rateLimited)
        // A bare "limit" is not the daily cap
        XCTAssertEqual(outcome(#"{"Authenticated":"False","errorMessage":"Account locked after the attempt limit"}"#), .rejected)
        XCTAssertEqual(outcome(#"{"errorMessage":"Unlimited plan required"}"#), .rejected)
        // Only message fields are read
        XCTAssertEqual(outcome(#"{"Authenticated":"False","Plan":"daily limit exceeded"}"#), .rejected)
        XCTAssertEqual(try? NJTransitLive.token(from: Data(#"{"Authenticated":"True","UserToken":"abc","message":"Daily limit: 5"}"#.utf8)), "abc")
    }

    /// The limit worded other ways is still a limit: taking it for a refusal would make Settings drop a working account
    func testTokenLimitInOtherWordings() {
        func outcome(_ json: String) -> NJTransitLive.LiveError? {
            do {
                _ = try NJTransitLive.token(from: Data(json.utf8))
                return nil
            } catch {
                return error as? NJTransitLive.LiveError
            }
        }
        XCTAssertEqual(outcome(#"{"errorMessage":"Daily token limit has been exceeded"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"errorMessage":"Maximum token requests exceeded for today"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"Authenticated":"False","message":"Token limit reached"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"errorMessage":"Too many sign-ins today. Try again tomorrow."}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"errorMessage":"Quota exceeded"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"Authenticated":"False","errorMessage":"You have reached your daily token limit"}"#), .rateLimited)
        XCTAssertEqual(outcome(#"{"detail":"Maximum number of tokens reached for today"}"#), .rateLimited)
        // Status and detail fields hold an explanation too
        XCTAssertEqual(outcome(#"{"Authenticated":"False","Status":"Daily limit exceeded"}"#), .rateLimited)
        // "Exceeded" or "reached" about something else is a refusal
        XCTAssertEqual(outcome(#"{"Authenticated":"False","errorMessage":"Login attempt exceeded the allowed time"}"#), .rejected)
        XCTAssertEqual(outcome(#"{"Authenticated":"False","errorMessage":"Unknown user: the directory was reached"}"#), .rejected)
    }

    /// A sign-in that hits the daily limit pauses the real service for an hour and leaves a new account "couldn't tell" (never
    /// "refused", which would make Settings drop it); the test-system probe pauses nothing
    func testDailyLimitPausesOnlyTheRealService() async throws {
        let limit = Data(#"{"errorMessage":"Daily limit exceeded"}"#.utf8)
        let real = try XCTUnwrap(NJTransitLive.Endpoints.rail.token.host)
        let test = try XCTUnwrap(NJTransitLive.Endpoints.railTest.token.host)
        RateLimit.cleared(host: real)
        RateLimit.cleared(host: test)
        defer {
            RateLimit.cleared(host: real)
            RateLimit.cleared(host: test)
        }
        let probe = NJTransitClient(poster: FakePoster(replies: ["getToken": [.success(limit)]]), endpoints: .railTest,
                                    loadToken: { nil }, saveToken: { _ in })
        do {
            try await probe.signIn(account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rateLimited)
        }
        XCTAssertNil(RateLimit.pausedUntil(host: test))
        let client = NJTransitClient(poster: FakePoster(replies: ["getToken": [.success(limit)]]), loadToken: { nil }, saveToken: { _ in })
        let trial = await client.tryAccount(account)
        XCTAssertNil(trial.works)
        XCTAssertNotNil(RateLimit.pausedUntil(host: real))
    }

    /// The test-system probe records no rate limit and no connection problem: they would show as the real "NJ Transit rail" / "NJ Transit bus"
    func testTestSystemsRecordNothing() throws {
        XCTAssertFalse(NJTransitClient.defaultPoster(for: .railTest).recordsReach)
        XCTAssertFalse(NJTransitClient.defaultPoster(for: .busTest).recordsReach)
        XCTAssertTrue(NJTransitClient.defaultPoster(for: .rail).recordsReach)
        XCTAssertTrue(NJTransitClient.defaultPoster(for: .bus).recordsReach)
        NetworkReach.reset()
        defer { NetworkReach.reset() }
        let url = NJTransitLive.Endpoints.railTest.token
        let host = try XCTUnwrap(url.host)
        RateLimit.cleared(host: host)
        defer { RateLimit.cleared(host: host) }
        func answer(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        }
        let quiet = URLSessionFormPoster(recordsReach: false)
        XCTAssertThrowsError(try quiet.check(answer(429), from: url))
        XCTAssertThrowsError(try quiet.check(answer(451), from: url))
        quiet.noteFailure(URLError(.notConnectedToInternet), url: url)
        XCTAssertNil(RateLimit.pausedUntil(host: host))
        XCTAssertEqual(NetworkReach.notices(), [])
        // The real service's poster notes the same answers
        let recording = URLSessionFormPoster()
        XCTAssertThrowsError(try recording.check(answer(429), from: url))
        XCTAssertNotNil(RateLimit.pausedUntil(host: host))
        XCTAssertThrowsError(try recording.check(answer(451), from: url))
        XCTAssertFalse(NetworkReach.notices().isEmpty)
    }

    /// Answers that aren't one JSON object are read the same way: lists and nested objects lose the fields that may hold
    /// the account or a token, a value the server escaped is hidden as parsed, and a web page's escaped forms are hidden too
    func testRefusalInOtherShapesHidesTheAccount() {
        let list = #"[{"UserToken":"t","errorMessage":"Denied for jsmith"},{"detail":{"password":"p&ss","message":"Check p\u0026ss"}}]"#
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data(list.utf8), hiding: ["JSmith", "p&ss"]),
                       "errorMessage: Denied for …; message: Check …")
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data(#""Bad password p\u0026ss""#.utf8), hiding: ["p&ss"]), "Bad password …")
        let page = "<p>User jsmith, password p&amp;s&lt;s&#39;: not authorized</p>"
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data(page.utf8), hiding: ["jsmith", "p&s<s'"]), "<p>User …, password …: not authorized</p>")
        XCTAssertEqual(NJTransitLive.htmlEscaped("plain"), [])
        XCTAssertEqual(NJTransitLive.htmlEscaped("a&b"), ["a&amp;b"])
    }

    /// A refusal shown to the user leaves out fields that may hold the account or a token, and hides the username and
    /// the password in any letter case, the longer one first
    func testRefusalHidesTheAccount() async {
        let json = #"{"Authenticated":"False","UserName":"JSmith","Password":"x","pwdHint":"y","ClientSecret":"z","UserToken":"t","errorMessage":"Login failed for jsmith"}"#
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data(json.utf8), hiding: ["JSmith", "Hunter2"]),
                       "Authenticated: False; errorMessage: Login failed for …")
        XCTAssertEqual(NJTransitLive.redacting(["bob", "bob123"], in: "BOB123 or bob"), "… or …")
        XCTAssertEqual(NJTransitLive.redacting(["", "pw"], in: "no PW here"), "no … here")
        XCTAssertEqual(NJTransitLive.serverMessage(from: Data("Denied: JSMITH / hunter2".utf8), hiding: ["jsmith", "Hunter2"]), "Denied: … / …")
        let mixed = NJTransitClient.Account(username: "JSmith", password: "Hunter2")
        let poster = FakePoster(replies: [
            "getToken": [.success(Data(#"{"Authenticated":"False","errorMessage":"User jsmith with password HUNTER2 is not authorized"}"#.utf8))],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in })
        try? await client.signIn(mixed)
        let refusal = await client.lastRefusal
        XCTAssertEqual(refusal, "Authenticated: False; errorMessage: User … with password … is not authorized")
    }

    /// The account and the token are never sent on to another server: a redirect is followed only on the same host over HTTPS,
    /// and one that wasn't followed is an unreadable answer (not a reason to sign in again)
    func testRedirectsStayOnTheSameHost() throws {
        let url = NJTransitLive.Endpoints.rail.token
        let moved = "https://raildata.njtransit.com/api/GTFSRT/v2/getToken"
        XCTAssertTrue(NJTransitLive.followsRedirect(from: url, to: URL(string: "https://RAILDATA.njtransit.com/api/GTFSRT/v2/getToken")))
        XCTAssertFalse(NJTransitLive.followsRedirect(from: url, to: URL(string: "https://example.com/getToken")))
        XCTAssertFalse(NJTransitLive.followsRedirect(from: url, to: URL(string: "http://raildata.njtransit.com/api/GTFSRT/getToken")))
        XCTAssertFalse(NJTransitLive.followsRedirect(from: url, to: URL(string: "https://testraildata.njtransit.com/api/GTFSRT/getToken")))
        XCTAssertFalse(NJTransitLive.followsRedirect(from: nil, to: url))
        // The same port: 443 written or not is the same; another port isn't followed
        XCTAssertTrue(NJTransitLive.followsRedirect(from: url, to: URL(string: "https://raildata.njtransit.com:443/api/GTFSRT/v2/getToken")))
        XCTAssertFalse(NJTransitLive.followsRedirect(from: url, to: URL(string: "https://raildata.njtransit.com:8443/api/GTFSRT/v2/getToken")))
        // The session's delegate applies it
        let task = URLSession.shared.dataTask(with: URLRequest(url: url))
        let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        var followed: [URL?] = []
        for target in ["https://example.com/getToken", moved] {
            SameHostRedirects().urlSession(.shared, task: task, willPerformHTTPRedirection: redirect,
                                           newRequest: URLRequest(url: URL(string: target)!)) { followed.append($0?.url) }
        }
        XCTAssertEqual(followed, [nil, URL(string: moved)])
        XCTAssertThrowsError(try URLSessionFormPoster(recordsReach: false).check(redirect, from: url)) {
            XCTAssertEqual($0 as? NJTransitLive.LiveError, .badResponse)
        }
    }

    /// Downloads with the user's own key use the session that stays on the same server too: MTA Bus Time's key is in the address,
    /// Swiftly's in the Authorization header. Downloads without a key don't
    func testKeyedDownloadsStayOnTheSameHost() throws {
        let busTime = try XCTUnwrap(URL(string: "https://bustime.mta.info/api/siri/stop-monitoring.json?key=abc&MonitoringRef=1"))
        XCTAssertTrue(URLSessionFetcher.carriesKey(URLRequest(url: busTime)))
        var swiftly = URLRequest(url: try XCTUnwrap(URL(string: "https://api.goswift.ly/real-time/suffolk-county-transit/gtfs-rt-trip-updates")))
        XCTAssertFalse(URLSessionFetcher.carriesKey(swiftly))
        swiftly.setValue("key", forHTTPHeaderField: "Authorization")
        XCTAssertTrue(URLSessionFetcher.carriesKey(swiftly))
        let subway = try XCTUnwrap(URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-ace"))
        XCTAssertFalse(URLSessionFetcher.carriesKey(URLRequest(url: subway)))
        let monkey = try XCTUnwrap(URL(string: "https://example.com/feed?monkey=1&keys=2"))
        XCTAssertFalse(URLSessionFetcher.carriesKey(URLRequest(url: monkey)))
    }

    /// A refresh stopped (standby) while NJ Transit answers the sign-in downloads nothing more; the new token is still saved for the next refresh
    func testStoppedRefreshDoesNotDownloadAfterRenewal() async throws {
        let server = GatedPoster(protobuf: protobuf, accepted: ["t-new"])
        let box = TokenBox("expired")
        let client = NJTransitClient(poster: server, loadToken: { box.token }, saveToken: { box.token = $0 })
        let refresh = Task { [account] in try await client.tripUpdates(account: account) }
        await server.waitForSignIns(1)
        refresh.cancel()
        await server.answer("me", with: Self.tokenJSON("t-new"))
        let result = await refresh.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(server.tokensSent, ["expired"])
        XCTAssertEqual(box.token, "t-new")
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(server.signIns, ["me"])
    }

    /// A refresh stopped while its stored token was being tried doesn't sign in (each sign-in counts against the daily limit),
    /// and one stopped before it starts sends nothing
    func testStoppedRefreshDoesNotSignIn() async {
        let poster = ClosurePoster { name, _ in
            // Standby stops the refresh while NJ Transit answers that the token doesn't work
            if name == "getTripUpdates" { withUnsafeCurrentTask { $0?.cancel() } }
            return Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        }
        let client = NJTransitClient(poster: poster, loadToken: { "expired" }, saveToken: { _ in })
        let refresh = Task { [account] in try await client.tripUpdates(account: account) }
        let result = await refresh.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(poster.calls, ["getTripUpdates"])
        let early = Task { [account] () -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.tripUpdates(account: account)
        }
        _ = await early.result
        XCTAssertEqual(poster.calls, ["getTripUpdates"])
    }

    // MARK: Renewal pace across launches

    /// A client as the app makes it at launch: token and renewal pace come from what the last run saved
    func launch(_ poster: FormPosting, tokens: TokenBox, pace: PaceBox, clock: TestClock) -> NJTransitClient {
        NJTransitClient(poster: poster, loadToken: { tokens.token }, saveToken: { tokens.token = $0 }, now: { clock.now },
                        loadPace: { pace.value }, savePace: { pace.value = $0 })
    }

    /// New tokens that NJ Transit calls invalid: after a relaunch the stored token is tried, but the renewal still waits out the
    /// saved backoff, and the next wait keeps doubling instead of starting over
    func testRenewalPaceSurvivesRelaunch() async {
        let junk = Data(#"{"errorMessage":"Invalid token."}"#.utf8)
        let poster = FakePoster(replies: [
            "getTripUpdates": Array(repeating: .success(junk), count: 10),
            "getToken": (1...3).map { Result<Data, Error>.success(Data(Self.tokenJSON("t\($0)").utf8)) },
        ])
        let clock = TestClock()
        let t0 = clock.now
        let tokens = TokenBox(nil)
        let pace = PaceBox()
        let first = launch(poster, tokens: tokens, pace: pace, clock: clock)
        _ = try? await first.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(tokens.token, "t1")
        XCTAssertEqual(pace.value?.unproven, 1)
        XCTAssertEqual(pace.value?.backoffUntil, t0.addingTimeInterval(3600))
        // Relaunched half an hour later
        clock.advance(1800)
        let second = launch(poster, tokens: tokens, pace: pace, clock: clock)
        _ = try? await second.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1, "Still waiting")
        XCTAssertEqual(poster.count("getTripUpdates"), 2, "The stored token is still tried")
        clock.advance(1801)
        _ = try? await second.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 2)
        XCTAssertEqual(pace.value?.unproven, 2)
        XCTAssertEqual(pace.value?.backoffUntil, clock.now.addingTimeInterval(7200), "The wait keeps doubling")
        // A refresh that changes nothing doesn't write the pace again
        let writes = pace.writes
        _ = try? await second.tripUpdates(account: account)
        XCTAssertEqual(pace.writes, writes)
    }

    /// Sign-ins NJ Transit didn't answer: the short wait after them goes on after a relaunch
    func testUnansweredPaceSurvivesRelaunch() async {
        // No getToken replies: every sign-in fails as if NJ Transit didn't answer
        let poster = FakePoster(replies: [:])
        let clock = TestClock()
        let tokens = TokenBox(nil)
        let pace = PaceBox()
        _ = try? await launch(poster, tokens: tokens, pace: pace, clock: clock).tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(pace.value?.unanswered, 1)
        clock.advance(60)
        let second = launch(poster, tokens: tokens, pace: pace, clock: clock)
        _ = try? await second.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 1)
        clock.advance(61)
        _ = try? await second.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 2)
        XCTAssertEqual(pace.value?.unanswered, 2)
        XCTAssertEqual(pace.value?.nextRenewal, clock.now.addingTimeInterval(2 * NJTransitClient.retryGap))
    }

    /// A saved wait is never longer than a day from launch (clock changes, bad data)
    func testSavedPaceWaitsAtMostADay() async {
        let clock = TestClock()
        var saved = NJTransitClient.RenewalPace()
        saved.backoffUntil = clock.now.addingTimeInterval(10 * 24 * 3600)
        saved.unproven = 5
        let poster = FakePoster(replies: ["getToken": [.success(Data(Self.tokenJSON("t1").utf8))],
                                          "getTripUpdates": [.success(protobuf)]])
        let client = launch(poster, tokens: TokenBox(nil), pace: PaceBox(saved), clock: clock)
        _ = try? await client.tripUpdates(account: account)
        clock.advance(NJTransitClient.maxRenewalGap - 1)
        _ = try? await client.tripUpdates(account: account)
        XCTAssertEqual(poster.count("getToken"), 0)
        clock.advance(2)
        let data = try? await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 1)
    }

    /// A refusal saved by the last run is reported without asking NJ Transit until its wait is over
    func testSavedRefusalIsReportedWithoutAsking() async throws {
        let clock = TestClock()
        var saved = NJTransitClient.RenewalPace()
        saved.nextRenewal = clock.now.addingTimeInterval(600)
        saved.refused = true
        let poster = FakePoster(replies: ["getToken": [.success(Data(Self.tokenJSON("t1").utf8))],
                                          "getTripUpdates": [.success(protobuf)]])
        let pace = PaceBox(saved)
        let client = launch(poster, tokens: TokenBox(nil), pace: pace, clock: clock)
        do {
            _ = try await client.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
        }
        XCTAssertTrue(poster.calls.isEmpty)
        clock.advance(601)
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(pace.value?.refused, false)
        XCTAssertEqual(pace.value?.nextRenewal, clock.now.addingTimeInterval(NJTransitClient.minRenewalGap))
    }

    /// Removing or saving an account resets the saved pace, even on a client that never read it
    func testResetReplacesSavedPace() async {
        let clock = TestClock()
        var saved = NJTransitClient.RenewalPace()
        saved.backoffUntil = clock.now.addingTimeInterval(3600)
        saved.unproven = 3
        let pace = PaceBox(saved)
        let poster = FakePoster(replies: ["getToken": [.success(Data(#"{"Authenticated":"False"}"#.utf8)),
                                                       .success(Data(Self.tokenJSON("t2").utf8))]])
        await launch(poster, tokens: TokenBox("old"), pace: pace, clock: clock).forget()
        XCTAssertNil(pace.value)
        // A refused account saved anyway waits the usual gap, also after a relaunch
        pace.value = saved
        let client = launch(poster, tokens: TokenBox("old"), pace: pace, clock: clock)
        let refused = await client.tryAccount(new)
        await client.adopt(refused)
        XCTAssertEqual(pace.value?.refused, true)
        XCTAssertEqual(pace.value?.unproven, 0)
        XCTAssertNil(pace.value?.backoffUntil)
        XCTAssertEqual(pace.value?.nextRenewal, clock.now.addingTimeInterval(NJTransitClient.minRenewalGap))
        let works = await client.tryAccount(new)
        await client.adopt(works)
        XCTAssertEqual(works.works, true)
        XCTAssertNil(pace.value)
    }

    // MARK: NJ Transit's own answers (the wordings of its documentation)

    private func body(_ text: String) -> Data { Data(text.utf8) }
    private let usageLimit = #"{"errorMessage":"Daily usage limit:10. Your current daily usage: 11"}"#

    /// What a live data answer says decides what happens: only "Invalid token" (in either system's wording) means a new token,
    /// the daily limit means waiting, and anything else (Null, "GTFS error", a web page, nothing) is a problem on NJ Transit's
    /// side. Only its message fields are read
    func testReplyKinds() {
        XCTAssertEqual(NJTransitLive.reply(to: protobuf), .feed)
        XCTAssertEqual(NJTransitLive.reply(to: body(#"{"errorMessage":"Invalid token."}"#)), .invalidToken)
        XCTAssertEqual(NJTransitLive.reply(to: body(#"{"errorMessage":"Invalid Token.  Please authenticate user."}"#)), .invalidToken)
        XCTAssertEqual(NJTransitLive.reply(to: body(#"{"errorMessage":" INVALID TOKEN"}"#)), .invalidToken)
        XCTAssertEqual(NJTransitLive.reply(to: body(usageLimit)), .limitReached)
        XCTAssertEqual(NJTransitLive.reply(to: body(#"{"errorMessage":"GTFS error"}"#)), .other)
        XCTAssertEqual(NJTransitLive.reply(to: body("Null")), .other)
        XCTAssertEqual(NJTransitLive.reply(to: body("<html><body>Service Unavailable</body></html>")), .other)
        XCTAssertEqual(NJTransitLive.reply(to: Data()), .other)
        XCTAssertEqual(NJTransitLive.reply(to: body(#"{"UserToken":"Invalid token"}"#)), .other)
    }

    /// An error status whose body is NJ Transit's own answer (JSON or Null) is handed on to be read; with a web page or nothing
    /// it stays an HTTP error. 429, 401 and 403 mean what they did before, whatever the body says
    func testErrorStatusAnswersAreHandedOn() throws {
        let url = NJTransitLive.Endpoints.railTest.tripUpdates
        let quiet = URLSessionFormPoster(recordsReach: false)
        func answer(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        }
        let invalid = body(#"{"errorMessage":"Invalid token."}"#)
        XCTAssertThrowsError(try quiet.check(answer(500), data: invalid, from: url)) {
            XCTAssertEqual($0 as? NJTransitLive.ErrorStatusAnswer, NJTransitLive.ErrorStatusAnswer(status: 500, body: invalid))
        }
        XCTAssertThrowsError(try quiet.check(answer(500), data: body("Null"), from: url)) {
            XCTAssertEqual(($0 as? NJTransitLive.ErrorStatusAnswer)?.status, 500)
        }
        XCTAssertThrowsError(try quiet.check(answer(503), data: body("<html>Down for maintenance</html>"), from: url)) {
            XCTAssertEqual($0 as? FeedFetchError, .httpStatus(503))
        }
        XCTAssertThrowsError(try quiet.check(answer(500), from: url)) {
            XCTAssertEqual($0 as? FeedFetchError, .httpStatus(500))
        }
        XCTAssertThrowsError(try quiet.check(answer(429), data: invalid, from: url)) {
            XCTAssertEqual($0 as? FeedFetchError, .httpStatus(429))
        }
        XCTAssertThrowsError(try quiet.check(answer(401), data: invalid, from: url)) {
            XCTAssertEqual($0 as? NJTransitLive.LiveError, .rejected)
        }
        XCTAssertNoThrow(try quiet.check(answer(200), data: invalid, from: url))
    }

    /// An expired token comes back as HTTP 500 with "Invalid token.": it's renewed and the new one is used
    func testInvalidTokenWithErrorStatusIsRenewed() async throws {
        let invalid = NJTransitLive.ErrorStatusAnswer(status: 500, body: body(#"{"errorMessage":"Invalid Token.  Please authenticate user."}"#))
        let poster = FakePoster(replies: [
            "getTripUpdates": [.failure(invalid), .success(protobuf)],
            "getToken": [.success(Data(Self.tokenJSON("new").utf8))],
        ])
        let box = TokenBox("old")
        let client = NJTransitClient(poster: poster, loadToken: { box.token }, saveToken: { box.token = $0 })
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 1)
        XCTAssertEqual(box.token, "new")
        let said = await client.lastSaid
        XCTAssertNil(said)
    }

    /// Anything else NJ Transit answers instead of data is its own problem: the timetable is used this time, nobody signs in, and
    /// the next refresh asks again with the same token. What it said is kept for the log until data comes again
    func testOtherAnswersDoNotSignIn() async throws {
        let poster = FakePoster(replies: [
            "getTripUpdates": [
                .failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(#"{"errorMessage":"GTFS error"}"#))),
                .success(body("Null")),
                .success(body("<html><body>Service Unavailable</body></html>")),
                .success(Data()),
                .success(protobuf),
            ],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { "tok" }, saveToken: { _ in })
        var said: [String?] = []
        for _ in 0..<4 {
            do {
                _ = try await client.tripUpdates(account: account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? NJTransitLive.LiveError, .badResponse)
            }
            said.append(await client.lastSaid)
        }
        XCTAssertEqual(said, ["HTTP 500, errorMessage: GTFS error", "Null", "<html><body>Service Unavailable</body></html>", "empty answer"])
        XCTAssertEqual(poster.count("getToken"), 0)
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getTripUpdates"), 5)
        let after = await client.lastSaid
        XCTAssertNil(after)
    }

    /// A download or sign-in that gets no answer at all (the network) has nothing NJ Transit said: the log line doesn't repeat
    /// an earlier answer's words
    func testNoAnswerSaysNothing() async {
        let poster = FakePoster(replies: [
            "getTripUpdates": [
                .failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(#"{"errorMessage":"GTFS error"}"#))),
                .failure(URLError(.notConnectedToInternet)),
                .success(body(#"{"errorMessage":"Invalid token."}"#)),
            ],
            "getToken": [.failure(URLError(.timedOut))],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { "tok" }, saveToken: { _ in })
        var said: [String?] = []
        for _ in 0..<3 {
            _ = try? await client.tripUpdates(account: account)
            said.append(await client.lastSaid)
        }
        XCTAssertEqual(said, ["HTTP 500, errorMessage: GTFS error", nil, nil])
        XCTAssertEqual(poster.count("getTripUpdates"), 3)
        XCTAssertEqual(poster.count("getToken"), 1, "the token NJ Transit said doesn't work is renewed")
    }

    /// The daily limit while downloading is a wait, not a reason to sign in
    func testLimitWhileDownloadingDoesNotSignIn() async {
        let poster = FakePoster(replies: [
            "getTripUpdates": [.failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(usageLimit)))],
        ])
        let client = NJTransitClient(poster: poster, loadToken: { "tok" }, saveToken: { _ in })
        do {
            _ = try await client.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rateLimited)
        }
        XCTAssertEqual(poster.count("getToken"), 0)
    }

    /// What NJ Transit said goes to the log without the account or the token, wherever they appear in it
    func testSaidHidesTheAccountAndToken() async {
        let account = NJTransitClient.Account(username: "JSmith", password: "Hunter2")
        let poster = FakePoster(replies: ["getTripUpdates": [
            .success(body(#"{"errorMessage":"Token tok-123 for jsmith (password hunter2) is suspended","UserToken":"tok-123"}"#)),
        ]])
        let client = NJTransitClient(poster: poster, loadToken: { "tok-123" }, saveToken: { _ in })
        _ = try? await client.tripUpdates(account: account)
        let said = await client.lastSaid
        XCTAssertEqual(said, "errorMessage: Token … for … (password …) is suspended")
    }

    /// A sign-in answered with Null (NJ Transit's documentation: the username, the password or the account is missing) is a
    /// refusal, also with an error status; an error status with other words is a problem on NJ Transit's side
    func testNullSignInIsARefusal() async {
        let poster = FakePoster(replies: ["getToken": [
            .success(body("Null")),
            .failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body("null"))),
            .failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(#"{"errorMessage":"GTFS error"}"#))),
        ]])
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in })
        for _ in 0..<2 {
            do {
                try await client.signIn(account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
            }
            let refusal = await client.lastRefusal
            XCTAssertEqual(refusal, "Null")
        }
        let refusedSaid = await client.lastSaid
        XCTAssertEqual(refusedSaid, "HTTP 500, Null")
        do {
            try await client.signIn(account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? FeedFetchError, .httpStatus(500))
        }
        let said = await client.lastSaid
        XCTAssertEqual(said, "HTTP 500, errorMessage: GTFS error")
    }

    /// Refused automatic sign-ins wait longer each time: 30 minutes, 1, 2, 4, 8 hours, then a day. A whole day of refreshes
    /// every minute uses 6 of NJ Transit's 10 daily sign-ins
    func testRefusalsWaitLongerEachTime() async {
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 1), 30 * 60)
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 2), 3600)
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 3), 2 * 3600)
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 5), 8 * 3600)
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 6), 24 * 3600)
        XCTAssertEqual(NJTransitClient.refusalGap(afterRefusals: 1000), 24 * 3600)
        let poster = FakePoster(replies: ["getToken": Array(repeating: .success(body(#"{"Authenticated":"False"}"#)), count: 20)])
        let clock = TestClock()
        let pace = PaceBox()
        let client = launch(poster, tokens: TokenBox(nil), pace: pace, clock: clock)
        for _ in 0..<(24 * 60) {
            do {
                _ = try await client.tripUpdates(account: account)
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(error as? NJTransitLive.LiveError, .rejected)
            }
            clock.advance(60)
        }
        XCTAssertEqual(poster.count("getToken"), 6)
        XCTAssertEqual(pace.value?.refusals, 6)
        XCTAssertEqual(pace.value?.refused, true)
    }

    /// A sign-in that finds today's sign-ins used up waits until they come back after midnight in New York, also after a
    /// relaunch, and keeps saying why meanwhile
    func testDailyLimitWaitsUntilMidnight() async throws {
        let host = try XCTUnwrap(NJTransitLive.Endpoints.rail.token.host)
        RateLimit.cleared(host: host)
        defer { RateLimit.cleared(host: host) }
        let poster = FakePoster(replies: [
            "getToken": [.failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: body(usageLimit))),
                         .success(Data(Self.tokenJSON("t1").utf8))],
            "getTripUpdates": [.success(protobuf)],
        ])
        let clock = TestClock()
        let pace = PaceBox()
        let first = launch(poster, tokens: TokenBox(nil), pace: pace, clock: clock)
        do {
            _ = try await first.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rateLimited)
        }
        let reset = NJTransitClient.dailyLimitReset(after: clock.now)
        XCTAssertEqual(pace.value?.nextRenewal, reset)
        XCTAssertEqual(pace.value?.limited, true)
        // Relaunched a minute before
        clock.advance(reset.timeIntervalSince(clock.now) - 60)
        let second = launch(poster, tokens: TokenBox(nil), pace: pace, clock: clock)
        do {
            _ = try await second.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rateLimited)
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        clock.advance(61)
        let data = try await second.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 2)
        XCTAssertEqual(pace.value?.limited, false)
    }

    /// An account tried in Settings when today's sign-ins are used up can't be checked; saved anyway, it isn't signed in with
    /// before they come back
    func testAccountSavedAtTheDailyLimitWaitsForMidnight() async throws {
        let host = try XCTUnwrap(NJTransitLive.Endpoints.rail.token.host)
        RateLimit.cleared(host: host)
        defer { RateLimit.cleared(host: host) }
        let poster = FakePoster(replies: [
            "getToken": [.success(body(usageLimit)), .success(Data(Self.tokenJSON("t1").utf8))],
            "getTripUpdates": [.success(protobuf)],
        ])
        let clock = TestClock()
        let client = NJTransitClient(poster: poster, loadToken: { nil }, saveToken: { _ in }, now: { clock.now })
        let trial = await client.tryAccount(account)
        XCTAssertNil(trial.works)
        XCTAssertTrue(trial.limitReached)
        await client.adopt(trial)
        do {
            _ = try await client.tripUpdates(account: account)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NJTransitLive.LiveError, .rateLimited)
        }
        XCTAssertEqual(poster.count("getToken"), 1)
        clock.advance(NJTransitClient.dailyLimitReset(after: clock.now).timeIntervalSince(clock.now) + 1)
        let data = try await client.tripUpdates(account: account)
        XCTAssertEqual(data, protobuf)
        XCTAssertEqual(poster.count("getToken"), 2)
    }

    /// When today's sign-ins come back: the next midnight in New York plus a minute, through daylight saving changes and the
    /// year's end
    func testDailyLimitResetIsNextMidnightInNewYork() throws {
        func utc(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }
        func reset(_ text: String) throws -> Date { NJTransitClient.dailyLimitReset(after: try utc(text)) }
        // 7:30 PM on a November evening (UTC-5)
        XCTAssertEqual(try reset("2026-11-14T00:30:00Z"), try utc("2026-11-14T05:01:00Z"))
        // Just after midnight: the next one
        XCTAssertEqual(try reset("2026-11-14T05:00:30Z"), try utc("2026-11-15T05:01:00Z"))
        // The day the clocks go back (the first Sunday in November), and the day before it
        XCTAssertEqual(try reset("2026-11-01T16:00:00Z"), try utc("2026-11-02T05:01:00Z"))
        XCTAssertEqual(try reset("2026-10-31T16:00:00Z"), try utc("2026-11-01T04:01:00Z"))
        // The day the clocks go forward (the second Sunday in March)
        XCTAssertEqual(try reset("2027-03-14T16:00:00Z"), try utc("2027-03-15T04:01:00Z"))
        // A minute before the new year
        XCTAssertEqual(try reset("2027-01-01T04:59:00Z"), try utc("2027-01-01T05:01:00Z"))
    }

    /// A pace saved by the version before (without the newer fields) still reads, with those at their starting values
    func testOlderSavedPaceStillReads() throws {
        let old = #"{"nextRenewal":800000000,"unproven":2,"unanswered":1,"refused":true}"#
        let pace = try JSONDecoder().decode(NJTransitClient.RenewalPace.self, from: body(old))
        XCTAssertEqual(pace.nextRenewal, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(pace.unproven, 2)
        XCTAssertEqual(pace.unanswered, 1)
        XCTAssertTrue(pace.refused)
        XCTAssertEqual(pace.refusals, 0)
        XCTAssertFalse(pace.limited)
        var current = NJTransitClient.RenewalPace()
        current.refusals = 3
        current.limited = true
        XCTAssertEqual(try JSONDecoder().decode(NJTransitClient.RenewalPace.self, from: try JSONEncoder().encode(current)), current)
    }

    // MARK: Lines for the app's log

    /// On which routes live data has trips: numbers in number order, then other IDs, then trips that name no route; a long list
    /// goes on more lines
    func testRouteSummary() {
        XCTAssertEqual(FerryRealtime.routeSummary(["10": 2, "2": 8, "HBLR": 3, "": 1, "1": 5], name: "NJ Transit rail"),
                       ["NJ Transit rail live data: 19 trips, by route: 1 5, 2 8, 10 2, HBLR 3, (none) 1"])
        XCTAssertEqual(FerryRealtime.routeSummary([:], name: "NJ Transit bus"), ["NJ Transit bus live data: 0 trips"])
        XCTAssertEqual(FerryRealtime.routeSummary(["1": 1, "2": 2, "3": 3], name: "NJ Transit bus", perLine: 2),
                       ["NJ Transit bus live data: 6 trips on 3 routes, by route (1 of 2): 1 1, 2 2",
                        "NJ Transit bus live data: 6 trips on 3 routes, by route (2 of 2): 3 3"])
    }

    /// What a live download says about the account comes only from NJ Transit's own answer: another railroad's live data in
    /// the same download doesn't show that the account works
    func testAccountEvidenceComesOnlyFromNJTransitsOwnData() {
        let asked: [FerryFeed.Source] = [.lirr, .metroNorth, .njTransitRail]
        // LIRR's and Metro-North's came and NJ Transit's didn't: nothing is known about the account
        XCTAssertNil(NJTransitLive.accountEvidence(asked: asked, received: [.lirr, .metroNorth], rejected: false))
        XCTAssertNil(NJTransitLive.accountEvidence(asked: asked, received: [], rejected: false))
        XCTAssertEqual(NJTransitLive.accountEvidence(asked: asked, received: [.lirr, .njTransitRail], rejected: false), true)
        XCTAssertEqual(NJTransitLive.accountEvidence(asked: asked, received: [.njTransitRail], rejected: false), true)
        // Refused: that's NJ Transit's own answer, whatever else came
        XCTAssertEqual(NJTransitLive.accountEvidence(asked: asked, received: [.lirr, .metroNorth], rejected: true), false)
        // NJ Transit wasn't asked: nothing either way
        XCTAssertNil(NJTransitLive.accountEvidence(asked: [.lirr], received: [.lirr], rejected: false))
        XCTAssertNil(NJTransitLive.accountEvidence(asked: [.lirr], received: [.lirr], rejected: true))
        XCTAssertNil(NJTransitLive.accountEvidence(asked: [], received: [], rejected: false))
    }

    /// Each sign-in writes one line for the app's log: which API and how it ended. Nothing of the account or the token is in it
    func testEachSignInWritesOneLogLine() async throws {
        let railHost = try XCTUnwrap(NJTransitLive.Endpoints.rail.token.host)
        RateLimit.cleared(host: railHost)
        defer { RateLimit.cleared(host: railHost) }
        XCTAssertTrue(NetworkSwitch.isAllowed)
        let lines = LogLines()
        let me = account
        func signIn(_ reply: Result<Data, Error>, _ endpoints: NJTransitLive.Endpoints = .rail) async {
            let poster = FakePoster(replies: [endpoints.token.lastPathComponent: [reply]])
            let client = NJTransitClient(poster: poster, endpoints: endpoints, loadToken: { nil }, saveToken: { _ in },
                                         log: { lines.add($0) })
            try? await client.signIn(me)
        }
        await signIn(.success(Data(#"{"Authenticated":"True","UserToken":"tok-123"}"#.utf8)))
        await signIn(.success(Data(#"{"Authenticated":"False","UserToken":""}"#.utf8)), .bus)
        await signIn(.success(Data("<html>Service unavailable</html>".utf8)))
        await signIn(.failure(FeedFetchError.httpStatus(503)), .busTest)
        await signIn(.failure(URLError(.timedOut)))
        await signIn(.failure(CancellationError()), .railTest)
        let limit = Data(#"{"errorMessage":"Daily usage limit:10. Your current daily usage: 11"}"#.utf8)
        await signIn(.failure(NJTransitLive.ErrorStatusAnswer(status: 500, body: limit)))
        XCTAssertEqual(lines.all, [
            "NJ Transit sign-in (rail): accepted",
            "NJ Transit sign-in (bus): refused",
            "NJ Transit sign-in (rail): answer not understood",
            "NJ Transit sign-in (bus test system): answer not understood",
            "NJ Transit sign-in (rail): no answer",
            "NJ Transit sign-in (rail test system): stopped before the answer was used",
            "NJ Transit sign-in (rail): daily limit reached",
        ])
        // After the limit the rail server is left alone for an hour: a sign-in meanwhile isn't sent, and the line says so
        XCTAssertNotNil(RateLimit.pausedUntil(host: railHost))
        await signIn(.failure(FeedFetchError.httpStatus(429)))
        XCTAssertEqual(lines.all.last, "NJ Transit sign-in (rail): not sent")
        RateLimit.cleared(host: railHost)
        // Trying a new account in Settings signs in on a client of its own: its line is written too
        let trying = NJTransitClient(poster: FakePoster(replies: ["getToken": [.success(Data(#"{"Authenticated":"True","UserToken":"tok-456"}"#.utf8))]]),
                                     loadToken: { nil }, saveToken: { _ in }, log: { lines.add($0) })
        let trial = await trying.tryAccount(account)
        XCTAssertEqual(trial.works, true)
        XCTAssertEqual(lines.all.last, "NJ Transit sign-in (rail): accepted")
        XCTAssertEqual(lines.all.count, 9)
        // A client given no log writes none, and works the same
        let quiet = NJTransitClient(poster: FakePoster(replies: ["getToken": [.success(Data(#"{"Authenticated":"True","UserToken":"tok-789"}"#.utf8))]]),
                                    loadToken: { nil }, saveToken: { _ in })
        try await quiet.signIn(account)
        XCTAssertEqual(lines.all.count, 9)
        for line in lines.all {
            XCTAssertFalse(line.contains("secret"), line)
            XCTAssertFalse(line.contains("tok-"), line)
        }
        // Another server's sign-in is named by its host
        let other = NJTransitLive.Endpoints(token: URL(string: "https://signin.example/api/getToken")!,
                                            tripUpdates: URL(string: "https://signin.example/api/getTripUpdates")!)
        XCTAssertEqual(NJTransitLive.signInLogLine(other, .accepted), "NJ Transit sign-in (signin.example): accepted")
    }

    /// Live data read for rail and for light rail: each counts its own timetable trips and how many of them it has (the light
    /// rail's by trip_id, the trains' by train number only), and both count every trip in the data by route
    func testMatchedTripsCountsItsOwnTrips() {
        func trip(_ id: String, number: String? = nil) -> FerryFeed.Trip {
            FerryFeed.Trip(id: id, route: "R", service: "S", direction: "N", stops: ["a", "b"], times: [0, 60], number: number)
        }
        let feed = FerryFeed(versions: [:], routes: [], piers: [],
                             trips: [trip("njl:L1"), trip("njl:L2"), trip("njl:L3"), trip("njr:T1", number: "0101"), trip("njr:T2", number: "0202")],
                             services: [:], shapes: [:])
        func entity(_ id: String, route: String) -> GTFSRealtimeFeed.TripUpdate {
            .init(entityID: id, tripID: id, routeID: route, startDate: "", isCanceled: false, timestamp: nil, stopTimeUpdates: [])
        }
        // The trains' entries are named by train number; "T1" as a trip_id alone doesn't make a train live
        let data = GTFSRealtimeFeed(timestamp: Date(), tripUpdates: [entity("L2", route: "HBLR"), entity("0101", route: "NEC"),
                                                                     entity("202", route: "NEC"), entity("T1", route: "")])
        let light = FerryRealtime(feed: data, fetchedAt: Date(), source: .njTransitLightRail)
        XCTAssertEqual(light.matchedTrips(in: feed).trips, 3)
        XCTAssertEqual(light.matchedTrips(in: feed).live, 1)
        let rail = FerryRealtime(feed: data, fetchedAt: Date(), source: .njTransitRail)
        XCTAssertEqual(rail.matchedTrips(in: feed).trips, 2)
        XCTAssertEqual(rail.matchedTrips(in: feed).live, 2)
        XCTAssertEqual(light.routes, ["HBLR": 1, "NEC": 2, "": 1])
        XCTAssertEqual(rail.routes, light.routes)
    }
}
