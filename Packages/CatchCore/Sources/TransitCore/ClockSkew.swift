import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How far this Mac's clock is from the servers' clocks (server time − local time).
///
/// When downloading, the server time is read from the HTTP response's Date header (only from the servers in `source(of:)`). When
/// the local clock is more than 30 seconds fast or slow, "can I make it" uses server time, otherwise every countdown and decision
/// would be off. Differences under 30 seconds count as 0 (the Date header is only accurate to the second, plus network latency).
///
/// One server's clock can be off too, and a cache in between may hand back an old response without an Age header. So the latest
/// reading of each source (from the last 24 hours) is kept, and the offset is the one at least two sources agree on (within 30
/// seconds), up to 12 hours. Without two that agree, the MTA's alone still counts, up to 15 minutes.
public enum ClockSkew {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: TimeInterval = 0
    nonisolated(unsafe) private static var readings: [String: Reading] = [:]

    /// One source's latest reading, and when it was taken (local time)
    struct Reading: Equatable {
        var offset: TimeInterval
        var at: Date
    }

    /// Differences up to this count as none, and two readings this close agree
    public static let threshold: TimeInterval = 30
    /// The MTA's reading alone is followed up to this
    public static let singleLimit: TimeInterval = 15 * 60
    /// Two or more sources that agree are followed up to this
    public static let agreedLimit: TimeInterval = 12 * 3600
    /// How long a source's reading is used
    public static let readingsLast: TimeInterval = 24 * 3600
    /// From this offset on, the main window and Settings say the clock is off (see noticeOffset)
    public static let noticeAfter: TimeInterval = 2 * 60
    /// The source whose reading counts alone
    static let soloSource = "MTA"
    /// The offset the main app worked out, as the widget's reading (see adopt)
    static let appSource = "app"

    /// Current clock offset (seconds).
    public static var current: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// The offset to tell the user about: the app goes by the servers' time and the clock is at least noticeAfter off; nil otherwise
    public static var noticeOffset: TimeInterval? {
        let v = current
        return abs(v) >= noticeAfter ? v : nil
    }

    /// Whose clock a server's Date header tells, by host: the MTA's, MBTA's and SEPTA's own servers and GitHub's API (update check,
    /// source list). nil: not used, as other servers' clocks may be off or caches in between may leave out the Age header
    public static func source(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if under("mta.info") { return "MTA" }
        if under("mbta.com") { return "MBTA" }
        if under("septa.org") { return "SEPTA" }
        if host == "api.github.com" { return "GitHub" }
        return nil
    }

    /// Whether this server's time is used
    public static func trusts(_ url: URL) -> Bool { source(of: url) != nil }

    /// Corrected "now".
    public static func now(_ local: Date = Date()) -> Date { local.addingTimeInterval(current) }

    /// Sets the offset directly, as one source would (tests): up to singleLimit, anything else counts as no offset
    public static func set(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        readings = [:]
        value = bounded(seconds, limit: singleLimit)
    }

    /// The widget: the offset the main app worked out (it may rest on several sources, so up to agreedLimit). The widget's own
    /// readings from then on are weighed with it
    public static func adopt(_ seconds: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        readings = [appSource: Reading(offset: seconds, at: now)]
        value = decide(readings, now: now)
    }

    /// This Mac's clock was changed: the readings taken before no longer say anything
    public static func forgetReadings() {
        lock.lock(); defer { lock.unlock() }
        readings = [:]
        value = 0
    }

    static func record(from response: HTTPURLResponse, url: URL, local: Date = Date()) {
        // An Age header means an old cached response; Date isn't the current server time
        guard let source = source(of: url), (200..<300).contains(response.statusCode),
              response.value(forHTTPHeaderField: "Age") == nil,
              let header = response.value(forHTTPHeaderField: "Date"), let server = parse(header) else { return }
        note(server.timeIntervalSince(local), from: source, at: local)
    }

    /// One source's reading: the offset is worked out again from the latest of each source
    static func note(_ offset: TimeInterval, from source: String, at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        readings[source] = Reading(offset: offset, at: time)
        readings = readings.filter { abs(time.timeIntervalSince($0.value.at)) < readingsLast }
        value = decide(readings, now: time)
    }

    /// The offset from these readings: the largest group of two or more sources within threshold of each other (the one nearer
    /// no offset when two are as large) gives its middle value, up to agreedLimit. Without such a group: the MTA's alone up to
    /// singleLimit, then the main app's (the widget). Anything else counts as no offset
    static func decide(_ readings: [String: Reading], now: Date) -> TimeInterval {
        let recent = readings.filter { abs(now.timeIntervalSince($0.value.at)) < readingsLast }
        let offsets = recent.values.map(\.offset)
        var best: [TimeInterval] = []
        for center in offsets {
            let group = offsets.filter { abs($0 - center) <= threshold }.sorted()
            if group.count > best.count || (group.count == best.count && abs(middle(group)) < abs(middle(best))) { best = group }
        }
        if best.count >= 2 { return bounded(middle(best), limit: agreedLimit) }
        if let solo = recent[soloSource]?.offset, abs(solo) < singleLimit { return bounded(solo, limit: singleLimit) }
        if let app = recent[appSource]?.offset { return bounded(app, limit: agreedLimit) }
        return 0
    }

    private static func middle(_ sorted: [TimeInterval]) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let i = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[i] : (sorted[i - 1] + sorted[i]) / 2
    }

    private static func bounded(_ seconds: TimeInterval, limit: TimeInterval) -> TimeInterval {
        abs(seconds) > threshold && abs(seconds) < limit ? seconds : 0
    }

    /// HTTP Date header format: "Fri, 16 Oct 2026 01:57:03 GMT"
    static func parse(_ header: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.value.date(from: header)
    }

    private static let formatter = LockedBox<DateFormatter>({
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }())
}
