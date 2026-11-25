import Foundation

// MARK: - MTA Bus Time live arrivals (SIRI StopMonitoring)
//
// Bus live data comes from MTA Bus Time (https://bustime.mta.info/developers) and needs a free personal key,
// entered by the user in Settings (stored only in this Mac's Keychain, never in code). Each refresh queries only the few selected nearby bus stops,
// one tiny request per stop: stop-monitoring.json?key=…&MonitoringRef=<stop ID>.

public enum BusTimeError: Error, Equatable, Sendable {
    /// No key entered
    case missingKey
    /// Key invalid or refused (HTTP 401/403, or Bus Time's error description mentions the key)
    case invalidKey
    case httpStatus(Int)
    /// Error description returned by Bus Time
    case service(String)
    /// The answer was JSON but not Bus Time's SIRI format (e.g. a proxy or maintenance page), so it says nothing about the key
    case unexpectedResponse
}

/// Result of one bus live data download.
public struct BusLoad: Sendable {
    public var arrivals: [Arrival]
    /// Result per stop: nil on success
    public var errors: [String: BusTimeError]
    public var fetchedAt: Date
    /// Data time returned by Bus Time (the oldest of the ResponseTimestamps)
    public var responseTime: Date?

    public var allFailed: Bool { !errors.isEmpty && arrivals.isEmpty && errors.count >= requested }
    public var requested: Int

    public init(arrivals: [Arrival], errors: [String: BusTimeError], fetchedAt: Date, responseTime: Date?, requested: Int) {
        self.arrivals = arrivals
        self.errors = errors
        self.fetchedAt = fetchedAt
        self.responseTime = responseTime
        self.requested = requested
    }

    /// The main error (key problems first), nil when there's no error.
    public var mainError: BusTimeError? {
        if errors.values.contains(.invalidKey) { return .invalidKey }
        if errors.values.contains(.missingKey) { return .missingKey }
        return errors.values.first
    }
}

public enum BusTimeParser {

    /// Result of parsing stop-monitoring.json.
    /// - Parameters:
    ///   - stopID: the stop ID queried
    ///   - side: which side of the stop group this stop belongs to ("N"/"S", see BusCatalog.side)
    public static func arrivals(from data: Data, stopID: String, side: String, catalog: BusCatalog?,
                                fallbackTime: Date) throws -> (arrivals: [Arrival], responseTime: Date?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siri = root["Siri"] as? [String: Any],
              let delivery = siri["ServiceDelivery"] as? [String: Any] else {
            throw BusTimeError.unexpectedResponse
        }
        let responseTime = parseDate(delivery["ResponseTimestamp"])
        let smd = (delivery["StopMonitoringDelivery"] as? [[String: Any]])?.first ?? [:]
        if let condition = smd["ErrorCondition"] as? [String: Any] ?? delivery["ErrorCondition"] as? [String: Any] {
            let text = describe(condition)
            if text.lowercased().contains("key") { throw BusTimeError.invalidKey }
            throw BusTimeError.service(text)
        }
        let visits = smd["MonitoredStopVisit"] as? [[String: Any]] ?? []
        var result: [Arrival] = []
        for visit in visits {
            guard let mvj = visit["MonitoredVehicleJourney"] as? [String: Any] else { continue }
            let lineRef = string(mvj["LineRef"]) ?? ""
            // "MTA NYCT_B63" / "MTABC_Q53+" → "B63" / "Q53+"
            let route = lineRef.split(separator: "_", maxSplits: 1).last.map(String.init) ?? lineRef
            guard !route.isEmpty else { continue }
            let call = mvj["MonitoredCall"] as? [String: Any] ?? [:]
            let time = parseDate(call["ExpectedArrivalTime"]) ?? parseDate(call["ExpectedDepartureTime"])
            guard let time else { continue }   // Trips without a live position yet aren't shown
            let rawDestination = string(mvj["DestinationName"])
            let dirRef = string(mvj["DirectionRef"]) ?? "0"
            let destination = rawDestination.map(BusCatalog.cleanDestination)
                ?? catalog?.headsign(route: route, direction: dirRef)
            // Without a trip number, use vehicle + route, or else route + scheduled time, which stays the same between refreshes
            // (the expected time changes with each one and would make the row look new; it's used only when there's no scheduled time)
            let scheduled = parseDate(call["AimedArrivalTime"]) ?? parseDate(call["AimedDepartureTime"]) ?? time
            let journey = (mvj["FramedVehicleJourneyRef"] as? [String: Any]).flatMap { string($0["DatedVehicleJourneyRef"]) }
                ?? string(mvj["VehicleRef"]).map { "\($0)|\(route)" }
                ?? "\(route)|\(dirRef)|\(Int(scheduled.timeIntervalSince1970))"
            // Data time is taken from Bus Time's response time (RecordedAtTime is the vehicle position time, possibly older)
            let recorded = responseTime ?? parseDate(visit["RecordedAtTime"]) ?? fallbackTime
            let service = BusCatalog.service(route: route, destination: rawDestination)
            result.append(Arrival(
                id: "\(journey)|\(stopID)",
                stationID: stopID,
                route: route,
                direction: Direction(code: side, name: destination.map { "To \($0)" } ?? route,
                                     terminal: destination),
                arrivalTime: time,
                source: .realtime,
                status: .normal,
                updatedAt: recorded,
                isExpress: service != .local,
                busService: service
            ))
        }
        return (result, responseTime)
    }

    /// In SIRI 2 JSON some fields are arrays (["B63"]) and some are strings; take the first string either way.
    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let a = value as? [Any] { return a.lazy.compactMap { $0 as? String }.first }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func describe(_ condition: [String: Any]) -> String {
        if let d = string(condition["Description"]) { return d }
        for value in condition.values {
            if let dict = value as? [String: Any], let d = string(dict["ErrorText"]) ?? string(dict["Description"]) { return d }
        }
        return "Bus Time error"
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let s = string(value) else { return nil }
        return DateParsers.parse(s)
    }

    /// ISO8601DateFormatter isn't cheap to create, so it's created only once here (locked, since it isn't guaranteed thread-safe).
    private enum DateParsers {
        private static let lock = NSLock()
        private static let fractional = LockedBox<ISO8601DateFormatter>({
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }())
        private static let plain = LockedBox<ISO8601DateFormatter>({
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }())

        static func parse(_ s: String) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return fractional.value.date(from: s) ?? plain.value.date(from: s)
        }
    }
}

/// After Bus Time returns 429 (too many requests), pause requests for a while instead of retrying at the original rate.
/// Recorded in RateLimit (like other data providers); the UI and widget show a notice based on it.
public enum BusTimeBackoff {
    static var host: String { BusTimeLoader.endpoint.host ?? "bustime.mta.info" }

    public static func isPaused(now: Date) -> Bool { RateLimit.pausedUntil(host: host, now: now) != nil }

    /// When rate-limited repeatedly, pause 1, 2, 4… minutes, at most 15 minutes.
    static func rateLimited(now: Date) { RateLimit.hit(host: host, now: now) }

    static func succeeded(now: Date) { RateLimit.succeeded(host: host, now: now) }

    /// When the key is changed or deleted: forget the rate limit record
    public static func forget() { RateLimit.cleared(host: host) }
}

/// Download live arrivals for nearby bus stops.
public struct BusTimeLoader: Sendable {
    public static let endpoint = URL(string: "https://bustime.mta.info/api/siri/stop-monitoring.json")!
    /// Bus Time answers in JSON (not GTFS-Realtime): asked for that first, any other type after it, as the live data fetcher's
    /// default does (see URLSessionFetcher.defaultAccept)
    public static let accept = "application/json, */*;q=0.8"

    public var key: String
    public var catalog: BusCatalog
    public var fetcher: DataFetching

    public init(key: String, catalog: BusCatalog, fetcher: DataFetching = URLSessionFetcher(accept: BusTimeLoader.accept)) {
        self.key = key
        self.catalog = catalog
        self.fetcher = fetcher
    }

    public static func url(key: String, stopID: String) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "OperatorRef", value: "MTA"),
            URLQueryItem(name: "MonitoringRef", value: stopID),
            URLQueryItem(name: "StopMonitoringDetailLevel", value: "normal"),
            URLQueryItem(name: "MaximumStopVisits", value: "30"),
        ]
        return c.url!
    }

    /// Maximum concurrent requests per refresh
    public static let maxConcurrent = 4
    /// Maximum stops queried per refresh (taken nearest first)
    public static let maxStops = 24

    /// One stop's answer: its buses and the time Bus Time gave with them
    private struct StopAnswer: Sendable {
        var arrivals: [Arrival]
        var responseTime: Date?
    }

    /// The same error for every stop (a stop listed twice is kept once instead of crashing)
    static func errors(_ error: BusTimeError, for stations: [Station]) -> [String: BusTimeError] {
        Dictionary(stations.map { ($0.id, error) }, uniquingKeysWith: { first, _ in first })
    }

    /// - Parameter stations: nearby bus stops (with stop group IDs, used to split directions), sorted nearest first.
    public func load(stations allStations: [Station], now: @escaping @Sendable () -> Date = { Date() }) async -> BusLoad {
        let stations = Array(allStations.prefix(Self.maxStops))
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BusLoad(arrivals: [], errors: Self.errors(.missingKey, for: stations),
                           fetchedAt: now(), responseTime: nil, requested: stations.count)
        }
        if BusTimeBackoff.isPaused(now: now()) {
            return BusLoad(arrivals: [], errors: Self.errors(.httpStatus(429), for: stations),
                           fetchedAt: now(), responseTime: nil, requested: stations.count)
        }
        // Which side of the stop group each stop belongs to
        var groups: [String: [String]] = [:]
        for s in stations { groups[s.complexID ?? s.id, default: []].append(s.id) }
        let catalog = self.catalog
        let fetcher = self.fetcher
        let jobs = stations.map { s in (s.id, catalog.side(ofStop: s.id, among: groups[s.complexID ?? s.id] ?? [s.id])) }

        // At most maxConcurrent requests at once. Each stop's answer is kept under its place in the list (see Together)
        let results = await Together.each(Array(jobs.indices), limit: Self.maxConcurrent) { index -> Result<StopAnswer, BusTimeError> in
            let (stopID, side) = jobs[index]
            do {
                let data = try await fetcher.fetch(Self.url(key: trimmed, stopID: stopID))
                let parsed = try BusTimeParser.arrivals(from: data, stopID: stopID, side: side,
                                                        catalog: catalog, fallbackTime: now())
                return .success(StopAnswer(arrivals: parsed.arrivals, responseTime: parsed.responseTime))
            } catch let e as BusTimeError {
                return .failure(e)
            } catch FeedFetchError.httpStatus(let code) {
                return .failure(code == 401 || code == 403 ? .invalidKey : .httpStatus(code))
            } catch {
                return .failure(.service(error.localizedDescription))
            }
        }
        var arrivals: [Arrival] = []
        var errors: [String: BusTimeError] = [:]
        var times: [Date] = []
        for (index, job) in jobs.enumerated() {
            switch results[index] {
            case .success(let answer)?:
                arrivals += answer.arrivals
                if let t = answer.responseTime { times.append(t) }
            case .failure(let e)?:
                errors[job.0] = e
            case nil:
                break
            }
        }
        if errors.values.contains(.httpStatus(429)) { BusTimeBackoff.rateLimited(now: now()) }
        else if !arrivals.isEmpty || errors.isEmpty { BusTimeBackoff.succeeded(now: now()) }
        return BusLoad(arrivals: arrivals, errors: errors, fetchedAt: now(), responseTime: times.min(),
                       requested: stations.count)
    }
}

/// The last MTA Bus Time answer, reused for the same stops for a little under a minute (TransitModel.refreshBus): a refresh every
/// 30 seconds, a manual refresh, a small move or new timetable data doesn't ask Bus Time again with the user's key (each stop's
/// request is also limited on its own, see KeyedRequests). A refresh a minute or more later asks again.
public struct BusLoadMemo: Sendable {
    public static let reuseFor: TimeInterval = 55

    private var stops: Set<String> = []
    private var startedAt: Date?
    private var load: BusLoad?

    public init() {}

    /// Keeps `load` for `stops` (the ones asked, nearest first); an answer where every stop failed isn't kept and drops the earlier one.
    /// - Parameter startedAt: when the refresh that downloaded `load` started
    public mutating func keep(_ load: BusLoad, stops: [String], startedAt: Date) {
        guard !load.allFailed else { self = BusLoadMemo(); return }
        self.stops = Set(stops.prefix(BusTimeLoader.maxStops))
        self.startedAt = startedAt
        self.load = load
    }

    /// The kept answer when it was asked for the same stops (in any order) less than `reuseFor` before `now`
    public func reusable(stops: [String], now: Date) -> BusLoad? {
        guard let load, let startedAt, Set(stops.prefix(BusTimeLoader.maxStops)) == self.stops else { return nil }
        let age = now.timeIntervalSince(startedAt)
        return age >= 0 && age < Self.reuseFor ? load : nil
    }
}
