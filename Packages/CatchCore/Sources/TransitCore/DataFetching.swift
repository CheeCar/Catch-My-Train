import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Download

/// Download interface (can be swapped for a fake in tests).
public protocol DataFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public enum FeedFetchError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case noData
    /// Got a web page back, not data (most likely the address changed and redirected to the website)
    case webPage
    /// The answer was bigger than any real data of its kind and was stopped (see DownloadLimit)
    case tooLarge
}

/// Downloads with URLSession.
public struct URLSessionFetcher: DataFetching {
    public var timeout: TimeInterval
    /// Accept header: GTFS-Realtime by default (see defaultAccept); PATH's ridepath.json uses "application/json"
    public var accept: String
    /// Authorization header (the Swiftly key goes here directly); nil when unused. Kept only in memory, never logged.
    public var authorization: String?
    /// false: rate limits and connection problems aren't recorded (RateLimit, NetworkReach), for downloads that aren't transit data
    /// (the update check), whose problems would otherwise show at the stations
    public var recordsReach: Bool
    /// false: a rate-limit pause doesn't stop this request (testing a different key in Settings: the pause belongs to the key that got it);
    /// a 429 it gets is still recorded
    public var checksPause: Bool
    /// The most an answer may bring (see DownloadLimit): more counts as unreadable data
    public var limit: Int64

    /// Dedicated download session: no caching (always wants fresh data), so downloaded data doesn't linger in memory or on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// The same, for downloads that carry a key (see carriesKey): a redirect to another server or away from HTTPS isn't followed,
    /// so the key only goes to the server it was meant for (see SameHostRedirects). The request then ends with the redirect,
    /// which counts as a failed download
    private static let keyedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// Whether a request carries the user's own key: Swiftly's in the Authorization header, MTA Bus Time's in the address ("key=")
    static func carriesKey(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return request.value(forHTTPHeaderField: "Authorization") != nil }
        return carriesKey(url: url, authorization: request.value(forHTTPHeaderField: "Authorization"))
    }

    static func carriesKey(url: URL, authorization: String?) -> Bool {
        if authorization != nil { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name.lowercased() == "key" }
    }

    /// The Accept header sent by default: GTFS-Realtime (protobuf) first, any other type after it. Some servers answer 406 (not
    /// acceptable) unless the header allows any type, whatever they send (CTtransit's does). A web page still counts as
    /// bad data (see NetworkReach.isWebPage)
    public static let defaultAccept = "application/x-protobuf, application/octet-stream;q=0.9, */*;q=0.8"

    public init(timeout: TimeInterval = 15, accept: String = URLSessionFetcher.defaultAccept, authorization: String? = nil,
                recordsReach: Bool = true, checksPause: Bool = true, limit: Int64 = DownloadLimit.live) {
        self.timeout = timeout
        self.accept = accept
        self.authorization = authorization
        self.recordsReach = recordsReach
        self.checksPause = checksPause
        self.limit = limit
    }

    public func fetch(_ url: URL) async throws -> Data {
        // One live data file several operators read (see SharedLive): downloaded once for all of them
        if authorization == nil, SharedLive.isShared(url) {
            return try await SharedLive.data(url) { try await fetchFresh(url) }
        }
        return try await fetchFresh(url)
    }

    private func fetchFresh(_ url: URL) async throws -> Data {
        try Self.precheck(url, checksPause: checksPause)
        // With the user's own key: asked at most once a minute, whatever the refresh interval (see KeyedRequests)
        if Self.carriesKey(url: url, authorization: authorization) {
            return try await KeyedRequests.answer(for: KeyedRequests.key(url, authorization)) { try await fetchRetrying(url) }
        }
        return try await fetchRetrying(url)
    }

    private func fetchRetrying(_ url: URL) async throws -> Data {
        let checksPause = checksPause
        return try await Self.retrying(check: { try Self.precheck(url, checksPause: checksPause) }) { lastTry in
            try await fetchOnce(url, lastTry: lastTry)
        }
    }

    /// On a poor network (weak signal, just switched networks) often only this one attempt failed: wait a moment and retry once,
    /// only then count it as a failure. Before the retry, going online is checked again (`check`): the network switch may have
    /// been turned off, or a pause begun, during the wait; standby cancels the wait
    static func retrying<T>(delay: TimeInterval = retryDelay, check: () throws -> Void,
                            attempt: (_ lastTry: Bool) async throws -> T) async throws -> T {
        do {
            return try await attempt(false)
        } catch let error as URLError where worthRetry(error) {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try check()
            return try await attempt(true)
        }
    }

    /// Before going online: the network switch in Settings, then (when checksPause is on) a rate-limit pause for this host, which counts as a 429
    static func precheck(_ url: URL, checksPause: Bool) throws {
        try NetworkSwitch.check()
        if checksPause { try RateLimit.checkNotPaused(url) }
    }

    /// Wait before retrying (seconds)
    static let retryDelay: TimeInterval = 2

    /// Whether this failure is worth an immediate retry: flaky network, timeout, connection dropped mid-way. No network, cancelled, or bad URL are not retried.
    public static func worthRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Download once. When lastTry is false, connection failures aren't recorded (a retry is coming), to avoid briefly flashing "network restricted".
    /// On cancel (standby, new refresh) the download actually stops instead of finishing and being discarded (see limitedData)
    private func fetchOnce(_ url: URL, lastTry: Bool) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let session = Self.carriesKey(request) ? Self.keyedSession : Self.session
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.limitedData(for: request, limit: limit)
        } catch FeedFetchError.tooLarge {
            if recordsReach { NetworkReach.recordBadData(url: url) }
            throw FeedFetchError.tooLarge
        } catch {
            Self.note(nil, error: error, url: url, lastTry: lastTry, recordsReach: recordsReach)
            throw error
        }
        Self.note(response, error: nil, url: url, lastTry: lastTry, recordsReach: recordsReach)
        if NetworkReach.isWebPage(response, accept: request.value(forHTTPHeaderField: "Accept")) {
            if recordsReach { NetworkReach.recordBadData(url: url, webPage: true) }
            throw FeedFetchError.webPage
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Records what came back (rate limits and connection problems only when recordsReach is on).
    /// When lastTry is false, a connection failure worth retrying isn't recorded: the retry decides
    static func note(_ response: URLResponse?, error: Error?, url: URL, lastTry: Bool, recordsReach: Bool) {
        if error == nil, let http = response as? HTTPURLResponse {
            // The clock offset: only from the servers whose time is used (see ClockSkew.source)
            ClockSkew.record(from: http, url: url)
            if recordsReach {
                RateLimit.record(http, url: url)
                NetworkReach.record(status: http.statusCode, url: url)
            }
        }
        // On connection failure, record which kind of failure (possibly a network restriction)
        if recordsReach, let error, lastTry || !((error as? URLError).map(worthRetry) ?? false) {
            NetworkReach.record(error: error, url: url)
        }
    }
}

/// Live data that needs the user's own key or account (MTA Bus Time, Suffolk County Transit, NJ Transit) is asked for at most
/// about once a minute, whatever the refresh interval, so the provider doesn't limit the key. Within that minute the last answer,
/// or failure, is given again. Decided by the request itself (it carries a key or an account's token), not by a list of companies
public enum KeyedRequests {
    /// The shortest time between two of the same requests
    public static let minimumInterval: TimeInterval = 60
    /// The last answer is given again while younger than this: a few seconds under the minute, as a refresh due every minute
    /// comes a moment early or late
    static let reuseFor: TimeInterval = minimumInterval - 5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [Int: (at: Date, result: Result<Data, Error>)] = [:]

    /// Which request: the address and what it carries (kept in this process's memory only, as a hash)
    static func key(_ url: URL, _ credential: String?) -> Int {
        var h = Hasher()
        h.combine(url)
        h.combine(credential)
        return h.finalize()
    }

    /// The last answer to this request when it's recent enough, otherwise `fetch`'s (kept for the next one; a stopped request isn't)
    static func answer(for key: Int, now: Date = Date(), _ fetch: @Sendable () async throws -> Data) async throws -> Data {
        if let kept = recent(key, now: now) { return try kept.get() }
        do {
            let data = try await fetch()
            keep(.success(data), for: key, at: now)
            return data
        } catch {
            if !NetworkReach.isCancellation(error) { keep(.failure(error), for: key, at: now) }
            throw error
        }
    }

    private static func recent(_ key: Int, now: Date) -> Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard let a = answers[key] else { return nil }
        let age = now.timeIntervalSince(a.at)
        return age >= 0 && age < reuseFor ? a.result : nil
    }

    private static func keep(_ result: Result<Data, Error>, for key: Int, at time: Date) {
        lock.lock(); defer { lock.unlock() }
        answers = answers.filter { abs(time.timeIntervalSince($0.value.at)) < minimumInterval }
        answers[key] = (time, result)
    }

    /// For tests: forget every answer
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        answers = [:]
    }
}

/// Live data files several operators read: the MBTA's one file for its subway, trains, buses and ferries, and SEPTA's for its buses
/// and Metro. Each of them asks for it on a refresh, side by side; it's downloaded once: a download already running is waited for, and
/// what it got is used by the others for reuseFor seconds. A failed download isn't reused, so the next ask goes online again
public enum SharedLive {
    /// Long enough for one refresh's operators, well under the shortest refresh interval (60 s)
    public static let reuseFor: TimeInterval = 30
    private struct Entry { let task: Task<Data, Error>; let started: Date }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [URL: Entry] = [:]

    /// Whether more than one operator reads the live data at this address (a timetable operator or a bus company)
    public static func isShared(_ url: URL) -> Bool {
        let sources = FerryFeed.Source.allCases.filter { !$0.isTurnedOff && $0.realtimeURL == url }.count
        let buses = RegionalBusFeed.all.filter { $0.realtimeURL == url }.count
        return sources + buses > 1
    }

    /// The file at this address: one downloaded or being downloaded less than reuseFor seconds ago, or a new download
    public static func data(_ url: URL, now: Date = Date(), download: @escaping @Sendable () async throws -> Data) async throws -> Data {
        // withLock, not lock() / unlock(): those can't be used in an async function (an error in Swift 6)
        let task: Task<Data, Error> = lock.withLock {
            if let entry = entries[url], now.timeIntervalSince(entry.started) < reuseFor, now >= entry.started {
                return entry.task
            }
            let task = Task { try await download() }
            entries[url] = Entry(task: task, started: now)
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.withLock {
                if entries[url]?.task == task { entries[url] = nil }
            }
            throw error
        }
    }

    /// Standby, or the network switch turned off: the downloads running stop (each operator waiting for one gets a cancellation,
    /// which isn't a failure), and nothing is kept for the next ask
    public static func cancelAll() {
        let running = lock.withLock { () -> [Task<Data, Error>] in
            let tasks = entries.values.map(\.task)
            entries = [:]
            return tasks
        }
        running.forEach { $0.cancel() }
    }

    /// For tests: nothing kept
    public static func reset() {
        lock.withLock { entries = [:] }
    }
}

/// Holds a non-thread-safe object (e.g. a date formatter), used only while holding the lock.
final class LockedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Holds the in-flight download for cancellation. Cancellation can come before the download starts, so "cancelled" is remembered.
final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}
