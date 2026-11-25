import Foundation

/// Whether a key or account the user entered actually works (it is tested when it's added,
/// "Live" shows only after it worked, and the app says so when it doesn't).
public enum CredentialCheck: String, Codable, Sendable {
    /// A test request is running
    case checking
    /// The operator accepted it
    case works
    /// The operator refused it
    case rejected
    /// Saved, but not tested yet (the app was on standby, offline, or the operator's server failed)
    case unconfirmed

    /// Result of one test request: true works, false refused, nil couldn't tell.
    public init(_ result: Bool?) {
        switch result {
        case true?: self = .works
        case false?: self = .rejected
        case nil: self = .unconfirmed
        }
    }

    /// Shortest time between two retests of keys whose test couldn't tell, however often Settings opens or the Mac wakes
    public static let retestInterval: TimeInterval = 10 * 60

    /// Whether a saved key with this result is tested again now: never tested (nil), couldn't tell, or a test that was stopped,
    /// at most once every `interval`. A key that worked or was refused isn't tested again here.
    public static func needsRetest(_ check: CredentialCheck?, lastRetest: Date?, now: Date,
                                   interval: TimeInterval = retestInterval) -> Bool {
        switch check {
        case nil, .unconfirmed?, .checking?:
            return lastRetest.map { now.timeIntervalSince($0) >= interval } ?? true
        case .works?, .rejected?:
            return false
        }
    }

    /// What a key row shows once a background retest of it ends (it showed `checking` meanwhile): the result, or what it showed
    /// before the test when the test couldn't tell, was stopped or didn't run. A row that something else changed meanwhile
    /// (a new key saved, a download that showed the key works) keeps that.
    public static func afterRetest(_ result: Bool?, before: CredentialCheck?, now current: CredentialCheck?) -> CredentialCheck? {
        guard current == .checking else { return current }
        return result.map { CredentialCheck($0) } ?? before
    }
}

/// Keys and accounts the app can test.
public enum Credential: String, CaseIterable, Codable, Sendable {
    case busTime
    case suffolk
    case njTransitRail
    case njTransitBus
}

/// A key or account the user enters for live times, as Settings lists them under Keys and accounts: one row each, in this order.
/// NJ Transit's one account is tested on two servers (two Credentials). Which metro areas need one follows from the operators that
/// use it and where they have stops (areas.json), so a new area or operator needs nothing written here
public enum AccountKey: String, CaseIterable, Sendable {
    /// MTA Bus Time: MTA's buses
    case busTime
    /// NJ Transit's developer account: its trains, light rail and buses
    case njTransit
    /// Swiftly: Suffolk County Transit's live data
    case suffolk

    /// The tests behind it
    public var credentials: [Credential] {
        switch self {
        case .busTime: return [.busTime]
        case .njTransit: return [.njTransitRail, .njTransitBus]
        case .suffolk: return [.suffolk]
        }
    }

    /// The timetable sources whose live times need it, in their order
    public var sources: [FerryFeed.Source] {
        self == .njTransit ? FerryFeed.Source.allCases.filter(\.needsAccount) : []
    }

    /// The bus companies whose live times need it, in RegionalBusFeed.all's order (NJ Transit's buses for the account)
    public var buses: [RegionalBusFeed] {
        switch self {
        case .busTime: return []
        case .njTransit: return RegionalBusFeed.all.filter(\.needsAccount)
        case .suffolk: return RegionalBusFeed.all.filter(\.needsKey)
        }
    }

    /// The metro areas where an operator's live times need it, in MetroArea's order
    public var areas: [MetroArea] {
        var found = Set(sources.flatMap { MetroArea.areas(of: $0) } + buses.flatMap { MetroArea.areas(ofBus: $0) })
        if self == .busTime { found.formUnion(MetroArea.areas(ofOperator: ModeCoverage.mtaBusID)) }
        return MetroArea.allCases.filter(found.contains)
    }

    /// The keys and accounts a metro area needs, in this enum's order; empty when it needs none
    public static func needed(in area: MetroArea) -> [AccountKey] { allCases.filter { $0.areas.contains(area) } }

    /// The other metro areas that need it too ("Also used in …"), in MetroArea's order
    public func otherAreas(than area: MetroArea) -> [MetroArea] { areas.filter { $0 != area } }

    /// How many other areas are named in "Also used in …"; more than this are counted instead ("Also used in 3 other areas."), so
    /// the line stays short however many areas share one key
    public static let namedOtherAreas = 2
}

/// What is left after removing a key or account from the Keychain. Removing always stops its use at once, whatever is left.
/// A delete can fail, for example when the Keychain prompt is denied or cancelled, or for a copy a differently signed build left
/// in the older keychain; the item is then still on this Mac, so Settings must not show it as removed.
public enum KeychainRemoval: Equatable, Sendable {
    /// Every part is gone
    case removed
    /// Some or all of it is still on this Mac: it's never used again, even when it can still be read as a whole (after a relaunch too),
    /// and Settings says it couldn't be removed and keeps the Remove button so it can be tried again. Saving a new one ends this.
    /// Nothing removes such leftovers on its own: one failed read at launch would otherwise delete a good account.
    case leftover

    /// deleted: every delete succeeded. stillReadable: the key or account can still be read afterwards.
    public init(deleted: Bool, stillReadable: Bool) {
        self = deleted && !stillReadable ? .removed : .leftover
    }
}

/// One small test request per key: true works, false refused, nil couldn't tell (offline, rate-limited, server error).
public enum CredentialTester {
    /// A Bus Time stop used only to test a key (any stop works: a valid key gets an answer, a bad one is refused).
    public static let busTimeTestStop = "MTA_308209"

    public static func busTime(key: String, fetcher: DataFetching = URLSessionFetcher(accept: BusTimeLoader.accept)) async -> Bool? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let data = try await fetcher.fetch(BusTimeLoader.url(key: trimmed, stopID: busTimeTestStop))
            _ = try BusTimeParser.arrivals(from: data, stopID: busTimeTestStop, side: "N", catalog: nil, fallbackTime: Date())
            return true
        } catch BusTimeError.invalidKey {
            return false
        } catch BusTimeError.unexpectedResponse {
            // Not Bus Time's format: can't tell whether the key works
            return nil
        } catch BusTimeError.service {
            // Bus Time answered with an error that isn't about the key (e.g. about the stop): the key was accepted
            return true
        } catch FeedFetchError.httpStatus(let code) where code == 401 || code == 403 {
            return false
        } catch {
            return nil
        }
    }

    /// A feed that takes the key in the Authorization header (Suffolk County Transit through Swiftly).
    public static func keyedFeed(_ feed: RegionalBusFeed, key: String, fetcher: DataFetching? = nil) async -> Bool? {
        await keyedFeedCheck(feed, key: key, fetcher: fetcher).works
    }

    /// Same as keyedFeed, plus what the server answered when the result is unclear (e.g. "HTTP 404"), so Settings can show why it wasn't confirmed.
    public static func keyedFeedCheck(_ feed: RegionalBusFeed, key: String, fetcher: DataFetching? = nil) async -> (works: Bool?, said: String?) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = feed.keyedRealtimeURL else { return (nil, nil) }
        guard !trimmed.isEmpty else { return (false, nil) }
        do {
            let data = try await (fetcher ?? URLSessionFetcher(authorization: trimmed)).fetch(url)
            do {
                _ = try feed.realtime(from: data, fetchedAt: Date())
                return (true, nil)
            } catch {
                // An answer that isn't GTFS-Realtime: keep the start of it (text only; never contains the key, which is sent only in a header)
                let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, text.isEmpty ? "empty response" : text)
            }
        } catch FeedFetchError.httpStatus(let code) where code == 401 || code == 403 {
            return (false, "HTTP \(code)")
        } catch FeedFetchError.httpStatus(let code) {
            return (nil, "HTTP \(code)")
        } catch FeedFetchError.noData {
            return (nil, "empty response")
        } catch FeedFetchError.webPage {
            return (nil, "a web page instead of data")
        } catch {
            return (nil, (error as NSError).localizedDescription)
        }
    }
}
