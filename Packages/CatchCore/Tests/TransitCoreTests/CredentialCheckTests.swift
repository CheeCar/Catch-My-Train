import XCTest
@testable import TransitCore

/// A key or account is tested once when it's added; "Live" is shown only after it worked.
final class CredentialCheckTests: XCTestCase {
    struct FakeFetcher: DataFetching {
        var result: Result<Data, Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private func fetcher(_ json: String) -> FakeFetcher { FakeFetcher(result: .success(Data(json.utf8))) }

    func testBusTimeKeyThatWorks() async {
        let ok = #"{"Siri":{"ServiceDelivery":{"ResponseTimestamp":"2026-10-24T12:00:00.000-04:00","StopMonitoringDelivery":[{"MonitoredStopVisit":[]}]}}}"#
        let result = await CredentialTester.busTime(key: "abc", fetcher: fetcher(ok))
        XCTAssertEqual(result, true)
    }

    func testBusTimeKeyRefused() async {
        let refused = #"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"ErrorCondition":{"Description":"API key is not authorized."}}]}}}"#
        let byMessage = await CredentialTester.busTime(key: "abc", fetcher: fetcher(refused))
        XCTAssertEqual(byMessage, false)
        let byStatus = await CredentialTester.busTime(key: "abc", fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(403))))
        XCTAssertEqual(byStatus, false)
        let empty = await CredentialTester.busTime(key: "  ", fetcher: fetcher(refused))
        XCTAssertEqual(empty, false)
    }

    func testBusTimeErrorNotAboutTheKeyMeansTheKeyWorks() async {
        let other = #"{"Siri":{"ServiceDelivery":{"StopMonitoringDelivery":[{"ErrorCondition":{"Description":"No such stop: MTA_308209"}}]}}}"#
        let result = await CredentialTester.busTime(key: "abc", fetcher: fetcher(other))
        XCTAssertEqual(result, true)
    }

    /// JSON that isn't Bus Time's format (a proxy or maintenance page) says nothing about the key
    func testBusTimeUnexpectedAnswerCantTell() async {
        let result = await CredentialTester.busTime(key: "abc", fetcher: fetcher(#"{"status":"maintenance"}"#))
        XCTAssertNil(result)
    }

    func testCantTellWhenOfflineOrServerFails() async {
        let offline = await CredentialTester.busTime(key: "abc", fetcher: FakeFetcher(result: .failure(URLError(.notConnectedToInternet))))
        XCTAssertNil(offline)
        let server = await CredentialTester.busTime(key: "abc", fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(503))))
        XCTAssertNil(server)
    }

    func testSwiftlyKey() async throws {
        let suffolk = try XCTUnwrap(RegionalBusFeed.all.first(where: \.needsKey))
        let refused = await CredentialTester.keyedFeed(suffolk, key: "abc", fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(401))))
        XCTAssertEqual(refused, false)
        let server = await CredentialTester.keyedFeed(suffolk, key: "abc", fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(500))))
        XCTAssertNil(server)
        let empty = await CredentialTester.keyedFeed(suffolk, key: "", fetcher: FakeFetcher(result: .failure(FeedFetchError.httpStatus(500))))
        XCTAssertEqual(empty, false)
    }

    func testCheckFromResult() {
        XCTAssertEqual(CredentialCheck(true), .works)
        XCTAssertEqual(CredentialCheck(false), .rejected)
        XCTAssertEqual(CredentialCheck(nil), .unconfirmed)
    }

    /// Keys never tested, or whose test couldn't tell or was stopped, are tested again at most every 10 minutes; a result that tells isn't retested
    func testRetestOnlyUnclearResultsAtMostEveryTenMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CredentialCheck.retestInterval, 600)
        let unclear: [CredentialCheck?] = [nil, .unconfirmed, .checking]
        for check in unclear {
            XCTAssertTrue(CredentialCheck.needsRetest(check, lastRetest: nil, now: t0), "\(String(describing: check))")
            XCTAssertFalse(CredentialCheck.needsRetest(check, lastRetest: t0.addingTimeInterval(-599), now: t0))
            XCTAssertTrue(CredentialCheck.needsRetest(check, lastRetest: t0.addingTimeInterval(-600), now: t0))
            XCTAssertTrue(CredentialCheck.needsRetest(check, lastRetest: t0.addingTimeInterval(-60), now: t0, interval: 60))
        }
        for check in [CredentialCheck.works, .rejected] {
            XCTAssertFalse(CredentialCheck.needsRetest(check, lastRetest: nil, now: t0))
            XCTAssertFalse(CredentialCheck.needsRetest(check, lastRetest: t0.addingTimeInterval(-3600), now: t0))
        }
    }

    /// A background retest shows "Checking…" only while it runs: then the result, or the earlier state when it couldn't tell or was
    /// stopped; whatever changed the row meanwhile stays
    func testRetestEndsWithResultOrEarlierState() {
        XCTAssertEqual(CredentialCheck.afterRetest(true, before: .unconfirmed, now: .checking), .works)
        XCTAssertEqual(CredentialCheck.afterRetest(false, before: nil, now: .checking), .rejected)
        XCTAssertEqual(CredentialCheck.afterRetest(nil, before: .unconfirmed, now: .checking), .unconfirmed, "couldn't tell")
        XCTAssertNil(CredentialCheck.afterRetest(nil, before: nil, now: .checking), "stopped before a never-tested key's result")
        XCTAssertEqual(CredentialCheck.afterRetest(nil, before: .unconfirmed, now: .works), .works, "a download showed it works meanwhile")
        XCTAssertEqual(CredentialCheck.afterRetest(true, before: .unconfirmed, now: .unconfirmed), .unconfirmed,
                       "a new key saved meanwhile keeps its own result")
        XCTAssertNil(CredentialCheck.afterRetest(true, before: .unconfirmed, now: nil), "removed meanwhile")
    }

    /// After removing a key or account, Settings shows it as removed only when every delete worked and nothing can be read any more.
    /// Anything left, even a whole account that can still be read, is a leftover: never used again, and Settings keeps the Remove button.
    func testKeychainRemoval() {
        XCTAssertEqual(KeychainRemoval(deleted: true, stillReadable: false), .removed)
        // A delete failed but it can still be read: no longer kept in use, removing always stops it
        XCTAssertEqual(KeychainRemoval(deleted: false, stillReadable: true), .leftover)
        XCTAssertEqual(KeychainRemoval(deleted: false, stillReadable: false), .leftover)
        // Reported deleted but still readable: something is still there, so it's a leftover too
        XCTAssertEqual(KeychainRemoval(deleted: true, stillReadable: true), .leftover)
    }
}
