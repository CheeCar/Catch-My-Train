import Foundation
import TransitCore

extension FerryStore {
    // MARK: Realtime data

    /// PATH realtime data (ridepath.json used by the official PATH app, free, no key needed). nil if the download fails.
    static func fetchPathLive(fetcher: DataFetching = URLSessionFetcher(accept: "application/json")) async -> PathLive? {
        do {
            let data = try await fetcher.fetch(PathLive.url)
            let live = try NetworkReach.reading(PathLive.url) { try PathLive.decode(data, fetchedAt: Date()) }
            LiveFailureLog.succeeded(FerryFeed.Source.path.name)
            return live
        } catch {
            if !NetworkReach.isCancellation(error) { LiveFailureLog.failed(FerryFeed.Source.path.name, error) }
            return nil
        }
    }

    /// NJ Transit realtime data: the token is stored in the Keychain and used until it stops working (see NJTransitClient).
    /// A token the Keychain couldn't read counts as none: the next download signs in again and saves the new token over it
    /// (a token is only ever replaced; the account itself is never touched for it).
    /// The pace of its automatic sign-ins is kept in the app's own defaults, so a relaunch doesn't use another of the day's few sign-ins.
    static let njTransit = NJTransitClient(
        loadToken: { KeychainStore.read(KeychainStore.njTransitToken).value },
        saveToken: { FerryStore.storeToken($0, for: KeychainStore.njTransitToken) },
        loadPace: { FerryStore.loadPace(key: FerryStore.njTransitPaceKey) },
        savePace: { FerryStore.storePace($0, key: FerryStore.njTransitPaceKey) },
        log: { FerryStore.noteSignIn($0) })

    /// NJ Transit bus realtime data: same account, different endpoint, token and sign-in pace
    static let njTransitBus = NJTransitClient(
        endpoints: .bus,
        loadToken: { KeychainStore.read(KeychainStore.njTransitBusToken).value },
        saveToken: { FerryStore.storeToken($0, for: KeychainStore.njTransitBusToken) },
        loadPace: { FerryStore.loadPace(key: FerryStore.njTransitBusPaceKey) },
        savePace: { FerryStore.storePace($0, key: FerryStore.njTransitBusPaceKey) },
        log: { FerryStore.noteSignIn($0) })

    /// One line in the app's log for each sign-in to NJ Transit, which allows only a few a day: which API and how it ended
    /// (NJTransitLive.signInLogLine). Never the account, the password or the token
    static func noteSignIn(_ line: String) { AppLog.data.notice("\(line, privacy: .public)") }

    private static let njTransitPaceKey = "njTransitRenewalPace"
    private static let njTransitBusPaceKey = "njTransitBusRenewalPace"

    /// The saved sign-in pace of one NJ Transit client (nil when none is saved or it can't be read). Only the app signs in to NJ Transit,
    /// never the widget, so it lives in the app's standard defaults.
    private static func loadPace(key: String) -> NJTransitClient.RenewalPace? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NJTransitClient.RenewalPace.self, from: data)
    }

    /// Saves the sign-in pace, or removes it (nil: nothing to wait for)
    private static func storePace(_ pace: NJTransitClient.RenewalPace?, key: String) {
        if let pace, let data = try? JSONEncoder().encode(pace) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Saves a new token, or deletes it (nil). A token the Keychain couldn't delete is logged (KeychainStore.delete logs every failed delete):
    /// it's useless without the account, and the next saved account's token replaces it.
    private static func storeToken(_ token: String?, for item: String) {
        if let token {
            _ = KeychainStore.save(token, for: item)
        } else {
            _ = KeychainStore.delete(item)
        }
    }

    /// Realtime data for nearby bus operators, downloaded together: CTtransit and Bee-Line are free; NJ Transit needs the user's developer account;
    /// Suffolk needs the user's own Swiftly key (suffolkKey, already read, kept only in memory).
    /// keep: trips at nearby stops (prefixed IDs); keep only these to save memory.
    /// nearby: the nearby piece those trips are from, for matching live trips by stops and time where a company's go that way and
    /// for the log's line on how they matched (see RegionalBusFeed.realtime, LiveMatchLog).
    /// Returns the operators (codes) downloaded and not downloaded, whether NJ Transit rejected the account, and whether Swiftly rejected the key.
    static func fetchBusRealtime(_ feeds: [RegionalBusFeed], keep: Set<String>, nearby: FerryFeed? = nil, suffolkKey: String? = nil,
                                 fetcher: DataFetching = URLSessionFetcher())
        async -> (realtime: [FerryRealtime], failed: [String], rejected: Bool, keyRejected: Bool) {
        // Every company at once, each one's answer kept under its own name (see Together)
        let answers = await Together.each(feeds) { feed -> BusLive in
            do {
                let data: Data
                if feed.needsAccount {
                    guard let account = KeychainStore.njTransitAccount else {
                        LiveFailureLog.failed(feed.name, reason: "no account in the Keychain")
                        return BusLive()
                    }
                    data = try await DownloadSlots.download { try await njTransitBus.tripUpdates(account: account) }
                } else if feed.needsKey, let url = feed.keyedRealtimeURL {
                    guard let suffolkKey else {
                        LiveFailureLog.failed(feed.name, reason: "no key")
                        return BusLive()
                    }
                    do {
                        data = try await DownloadSlots.download {
                            try await URLSessionFetcher(authorization: suffolkKey).fetch(url)
                        }
                    } catch FeedFetchError.httpStatus(let code) where code == 401 || code == 403 {
                        // Swiftly doesn't accept this key (or hasn't approved this agency yet)
                        LiveFailureLog.failed(feed.name, reason: "key not accepted, HTTP \(code)")
                        return BusLive(keyRejected: true)
                    }
                } else if let url = feed.realtimeURL {
                    data = try await DownloadSlots.download { try await fetcher.fetch(url) }
                } else {
                    return BusLive()
                }
                // Free and keyed feeds: warn when they can't be parsed (the provider may have changed the format).
                // NJ Transit uses an account; a parse failure is usually an account problem, which is reported separately.
                let live: FerryRealtime
                if !feed.needsAccount, let url = feed.realtimeURL ?? feed.keyedRealtimeURL {
                    live = try NetworkReach.reading(url) { try feed.realtime(from: data, fetchedAt: Date(), keep: keep, nearby: nearby) }
                } else {
                    live = try feed.realtime(from: data, fetchedAt: Date(), keep: keep, nearby: nearby)
                }
                if let line = live.matching?.logLine(name: feed.name) { LiveMatchLog.note(feed.name, line) }
                // Which routes NJ Transit's bus data has trips on (light rail too?), once a launch: hundreds of routes
                if feed.needsAccount {
                    LiveMatchLog.note(feed.name + " routes", every: nil) { FerryRealtime.routeSummary(live.routes, name: feed.name) }
                }
                return BusLive(live: live)
            } catch NJTransitLive.LiveError.rejected {
                // Only NJ Transit's account is refused this way
                LiveFailureLog.failed(feed.name, NJTransitLive.LiveError.rejected, said: await njTransitBus.lastSaid)
                return BusLive(rejected: true)
            } catch let error where NetworkReach.isCancellation(error) {
                return BusLive(skipped: true)
            } catch {
                var said: String?
                if feed.needsAccount { said = await njTransitBus.lastSaid }
                LiveFailureLog.failed(feed.name, error, said: said)
                return BusLive()
            }
        }
        var realtime: [FerryRealtime] = []
        var failed: [String] = []
        var rejected = false
        var keyRejected = false
        for (feed, answer) in answers {
            if answer.live != nil, let known = RegionalBusFeed.feed(code: feed.code) { LiveFailureLog.succeeded(known.name) }
            if let live = answer.live { realtime.append(live) } else if !answer.skipped { failed.append(feed.code) }
            rejected = rejected || answer.rejected
            keyRejected = keyRejected || answer.keyRejected
        }
        return (realtime.sorted { $0.prefix < $1.prefix }, failed.sorted(), rejected, keyRejected)
    }

    /// One bus company's live data from one refresh
    private struct BusLive: Sendable {
        /// nil if not downloaded
        var live: FerryRealtime?
        /// NJ Transit refused the account
        var rejected = false
        /// Swiftly refused the key
        var keyRejected = false
        /// Stopped (e.g. while a new NJ Transit account is being tried): not a failure, see NetworkReach.isCancellation
        var skipped = false
    }

    /// NJ Transit rail and light rail (when the user has entered an account): one download, one copy for each.
    /// rejected: NJ Transit doesn't accept this account (shown in Settings).
    /// skipped: stopped (e.g. while a new account is being tried), which isn't a failure (see NetworkReach.isCancellation).
    static func fetchNJTransit(_ sources: [FerryFeed.Source]) async -> (realtime: [FerryRealtime], rejected: Bool, skipped: Bool) {
        guard !sources.isEmpty else { return ([], false, false) }
        let name = FerryFeed.Source.njTransitRail.name
        guard let account = KeychainStore.njTransitAccount else {
            LiveFailureLog.failed(name, reason: "no account in the Keychain")
            return ([], false, false)
        }
        do {
            let data = try await njTransit.tripUpdates(account: account)
            let realtime = try NJTransitLive.realtime(from: data, fetchedAt: Date(), sources: sources)
            LiveFailureLog.succeeded(name)
            // Which routes the rail data has trips on (light rail too?): the first download after launch, then at most every 10 minutes.
            // Each copy counts the whole download's routes
            if let all = realtime.first {
                LiveMatchLog.note(name + " routes", every: 10 * 60) { FerryRealtime.routeSummary(all.routes, name: name) }
            }
            return (realtime, false, false)
        } catch NJTransitLive.LiveError.rejected {
            LiveFailureLog.failed(name, NJTransitLive.LiveError.rejected, said: await njTransit.lastSaid)
            return ([], true, false)
        } catch let error where NetworkReach.isCancellation(error) {
            return ([], false, true)
        } catch {
            LiveFailureLog.failed(name, error, said: await njTransit.lastSaid)
            return ([], false, false)
        }
    }

    /// Realtime data for these operators (downloaded on each refresh, small), all at once. For ferries, only NYC Ferry and NY Waterway have realtime data;
    /// both train operators do.
    /// Returns what was downloaded and the operators that weren't (shown in the UI; those fall back to the timetable).
    static func fetchRealtime(_ sources: [FerryFeed.Source], fetcher: DataFetching = URLSessionFetcher())
        async -> (realtime: [FerryRealtime], failed: [FerryFeed.Source], rejected: Bool) {
        let njt = sources.filter(\.needsAccount)
        async let njtResult = fetchNJTransit(njt)
        let others = await fetchPublicRealtime(sources.filter { !$0.needsAccount }, fetcher: fetcher)
        let n = await njtResult
        let failedNJT = n.realtime.isEmpty && !n.skipped ? njt : []
        let order = FerryFeed.Source.allCases
        return ((others.realtime + n.realtime).sorted { order.firstIndex(of: $0.source)! < order.firstIndex(of: $1.source)! },
                (others.failed + failedNJT).sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! },
                n.rejected)
    }

    private static func fetchPublicRealtime(_ sources: [FerryFeed.Source], fetcher: DataFetching)
        async -> (realtime: [FerryRealtime], failed: [FerryFeed.Source]) {
        // An operator without live data isn't asked, and isn't a failure
        let asked = sources.filter { $0.realtimeURL != nil }
        // Every operator at once, each one's answer kept under its own name (see Together)
        let answers = await Together.each(asked) { source -> FerryRealtime? in
            guard let url = source.realtimeURL else { return nil }
            do {
                let data = try await DownloadSlots.download { try await fetcher.fetch(url) }
                let realtime = try FerryRealtime.decode(data, from: url, fetchedAt: Date(), source: source)
                LiveFailureLog.succeeded(source.name)
                return realtime
            } catch {
                if !NetworkReach.isCancellation(error) { LiveFailureLog.failed(source.name, error) }
                return nil
            }
        }
        var realtime: [FerryRealtime] = []
        var failed: [FerryFeed.Source] = []
        for (source, answer) in answers {
            if let answer { realtime.append(answer) } else { failed.append(source) }
        }
        let order = FerryFeed.Source.allCases
        return (realtime.sorted { order.firstIndex(of: $0.source)! < order.firstIndex(of: $1.source)! },
                failed.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }
}
// MARK: Live data that can't be had

/// A line in the app's log when an operator's live data can't be had this refresh, and one when it comes back: which operator and
/// why (a network error's code, an HTTP status, data that can't be read, an account not accepted). Once per change, so a refresh
/// every 30 seconds doesn't repeat it; the station shows its own notice meanwhile
enum LiveFailureLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: [String: String] = [:]

    static func failed(_ name: String, _ error: Error) { failed(name, reason: AppLog.reason(error)) }

    /// NJ Transit's downloads: the reason, then what NJ Transit said with its answer when it said something (secrets and the account
    /// already left out, see NJTransitLive.said): "NJ Transit Rail badResponse, said: errorMessage: GTFS error"
    static func failed(_ name: String, _ error: Error, said: String?) {
        failed(name, reason: AppLog.reason(error) + (said.map { ", said: " + $0 } ?? ""))
    }

    static func failed(_ name: String, reason: String) {
        lock.lock()
        let changed = last[name] != reason
        last[name] = reason
        lock.unlock()
        if changed { AppLog.data.notice("live data failed: \(name, privacy: .public) \(reason, privacy: .public)") }
    }

    static func succeeded(_ name: String) {
        lock.lock()
        let was = last.removeValue(forKey: name)
        lock.unlock()
        if was != nil { AppLog.data.notice("live data back: \(name, privacy: .public)") }
    }
}

// MARK: How live trips matched

/// A line in the app's log on how a bus company's live trips matched its timetable (see LiveMatching.logLine: company names and
/// counts only). At most one per company every 10 minutes, so a refresh every 30 seconds doesn't repeat it. The same for NJ Transit's
/// route counts and light rail matches (route IDs and counts only)
enum LiveMatchLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: [String: Date] = [:]

    static func note(_ name: String, _ line: String, now: Date = Date()) { note(name, every: 10 * 60, now: now) { [line] } }

    /// Lines written under one name: the first time, then again only once `every` seconds have passed (nil: once a launch).
    /// The lines are made only when they're written
    static func note(_ name: String, every: TimeInterval?, now: Date = Date(), _ lines: () -> [String]) {
        lock.lock()
        let due: Bool
        if let previous = last[name] {
            due = every.map { now.timeIntervalSince(previous) >= $0 } ?? false
        } else {
            due = true
        }
        if due { last[name] = now }
        lock.unlock()
        guard due else { return }
        for line in lines() { AppLog.data.notice("\(line, privacy: .public)") }
    }
}
