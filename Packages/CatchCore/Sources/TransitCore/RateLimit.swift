import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// When a data provider says "too many requests" (HTTP 429, or NJ Transit says today's token renewals are used up), stop requesting from it for a while
/// and tell the user (a notice is shown when rate-limited, for all related data, including NJ Transit once an account is added).
/// Tracked per URL host: MTA Bus Time rate limits don't affect the subway. While paused, no network; treated directly as 429.
public enum RateLimit {
    public struct Notice: Codable, Sendable, Hashable {
        /// Data provider name (English, UI translation key), e.g. "MTA Bus Time"
        public var provider: String
        /// Retry at this time
        public var until: Date
        public init(provider: String, until: Date) {
            self.provider = provider
            self.until = until
        }
    }

    /// Per-host state: paused until when, how many consecutive rate limits, and the time of the last one. Stored in the shared folder so the app and widgets remember across relaunches.
    public struct Entry: Codable, Sendable, Equatable {
        public var until: Date
        public var strikes: Int
        public var lastHit: Date
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    /// Called after the state changes (the app and widget use it to save state to the shared folder)
    nonisolated(unsafe) private static var onChange: (@Sendable ([String: Entry]) -> Void)?
    /// After the last rate limit, only once it has been normal this long is the "consecutive rate limits" count reset
    public static let calmPeriod: TimeInterval = 10 * 60

    /// Read back the saved state (at launch), and set how to save future state changes
    public static func restore(_ saved: [String: Entry], onChange: @escaping @Sendable ([String: Entry]) -> Void) {
        lock.lock()
        for (host, e) in saved {
            // When both have one (e.g. the widget just recorded one), keep the one paused longer
            if let mine = entries[host], mine.until >= e.until { continue }
            entries[host] = e
        }
        Self.onChange = onChange
        lock.unlock()
    }

    /// Saves run one at a time, in the order of the changes (on a concurrent queue an older state could be written last)
    private static let saveQueue = DispatchQueue(label: "com.cheecar.catchmytrain.ratelimit-save", qos: .utility)

    private static func changed() {
        // Called while holding the lock, so saves are queued in the same order as the changes
        let snapshot = entries, callback = onChange
        saveQueue.async { callback?(snapshot) }
    }

    /// For tests: wait until queued saves have run
    static func waitForSaves() { saveQueue.sync {} }

    /// Rate-limited once: follow the server's Retry-After if given (30 s to 2 h), otherwise on consecutive limits pause 1, 2, 4... minutes, up to 15 minutes.
    /// Requests already in a pause (several sent in the same refresh) don't add to the count again.
    public static func hit(host: String, retryAfter: TimeInterval? = nil, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[host] ?? Entry(until: .distantPast, strikes: 0, lastHit: .distantPast)
        if now < e.until, retryAfter == nil { return }
        // The last rate limit was long ago: start again from 1 minute
        if now.timeIntervalSince(e.lastHit) > calmPeriod { e.strikes = 0 }
        e.strikes = min(e.strikes + 1, 5)
        e.lastHit = now
        let wait = retryAfter.map { min(max($0, 30), 2 * 3600) } ?? min(60 * pow(2, Double(e.strikes - 1)), 15 * 60)
        e.until = max(e.until, now.addingTimeInterval(wait))
        entries[host] = e
        changed()
    }

    /// The request succeeded. A success received during a pause (a request sent before the pause) doesn't lift the pause:
    /// in one refresh some requests can be rate-limited while others succeed, and those successes must not clear the pause.
    /// The record is removed only after it stays normal for longer than calmPeriod after the pause ends.
    public static func succeeded(host: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[host], now >= e.until, now.timeIntervalSince(e.lastHit) > calmPeriod else { return }
        entries[host] = nil
        changed()
    }

    /// When the user deletes the key or switches account: forget this provider's record
    public static func cleared(host: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries[host] != nil else { return }
        entries[host] = nil
        changed()
    }

    /// When the pause ends; nil if not paused
    public static func pausedUntil(host: String, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[host], now < e.until else { return nil }
        return e.until
    }

    /// Data providers currently paused (only the latest per name), for the UI and widgets.
    public static func notices(now: Date = Date()) -> [Notice] {
        lock.lock(); defer { lock.unlock() }
        var byName: [String: Date] = [:]
        for (host, e) in entries where now < e.until {
            let name = provider(forHost: host)
            byName[name] = max(byName[name] ?? e.until, e.until)
        }
        return byName.map { Notice(provider: $0.key, until: $0.value) }.sorted { $0.provider < $1.provider }
    }

    /// For tests: clear
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        onChange = nil
    }

    /// Data provider name for a host
    public static func provider(forHost host: String) -> String {
        let h = host.lowercased()
        if h.contains("bustime") { return "MTA Bus Time" }
        if h.contains("raildata.njtransit") { return "NJ Transit rail" }
        if h.contains("pcsdata.njtransit") { return "NJ Transit bus" }
        if h.contains("njtransit") { return "NJ Transit" }
        if h.contains("mta.info") { return "MTA" }
        if h.contains("ctttrpcloud") || h.contains("cttransit") { return "CTtransit" }
        if h.contains("westchester") { return "Bee-Line" }
        // One server for the live data of SEPTA's trains, Metro and buses
        if h.contains("septa") { return "SEPTA" }
        // One file for the live data of the MBTA's subway, trains, buses and ferries
        if h.contains("mbta") { return "MBTA" }
        if h.contains("goswift") || h.contains("suffolkcounty") { return "Suffolk County Transit" }
        if h.contains("rrgtfsfeeds") { return "MTA" }
        if h.contains("ridepath") || h.contains("panynj") { return "PATH" }
        if h.contains("nycferry") || h.contains("ferry.nyc") { return "NYC Ferry" }
        if h.contains("nywaterway") { return "NY Waterway" }
        // One server for the live data of several bus operators
        if h == "passio3.com" { return RegionalBusFeed.passioProvider }
        // A live data address the source list moved to a server not named above
        if let name = SourceList.provider(forHost: h) { return name }
        return host
    }

    /// Read the Retry-After header (seconds; date format not used)
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Run every response through: record 429s, clear on success
    static func record(_ response: HTTPURLResponse, url: URL, now: Date = Date()) {
        guard let host = url.host else { return }
        if response.statusCode == 429 { hit(host: host, retryAfter: retryAfter(response), now: now) }
        else if (200..<300).contains(response.statusCode) { succeeded(host: host, now: now) }
    }

    /// While paused, don't go online; treat it directly as 429
    static func checkNotPaused(_ url: URL) throws {
        if let host = url.host, pausedUntil(host: host) != nil { throw FeedFetchError.httpStatus(429) }
    }
}
