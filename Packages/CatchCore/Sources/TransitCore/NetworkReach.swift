import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// When a data provider can't be reached, record the visible way it failed so the UI and widget can explain why.
///
/// Some networks block some servers, and some servers refuse connections from certain countries, regions or networks (phones on
/// international roaming too, whose data still goes through the home network). When that stops the service from working, show why
/// it can't work. The app can't prove the real cause (a broken server and network blocking look the same), so it only says what it
/// saw, never where the user might be; only when several are unreachable at once while the network itself works does it say
/// "your network may be blocking these servers".
///
/// The official side can break too (server migrations, changed URLs or formats); warn when data can't be obtained, separately from network problems:
/// address not found (404 / 410, or moved to an address without encryption), server keeps erroring (5xx), data unreadable (format
/// changed, or a web page came back), live data stuck at an old time.
///
/// What several providers show at once is said once, about this Mac or its network: certificates out of date for all of them
/// (this Mac's date or time is wrong), or a web page from all of them (the network shows its own page, such as a sign-in page).
///
/// Recorded separately per data provider name (like RateLimit). In memory only: the main app writes the notices into the snapshot for the widget;
/// the widget uses its own records when it downloads itself.
public enum NetworkReach {
    /// The visible way it failed
    public enum Problem: String, Codable, Sendable, Hashable {
        /// This Mac isn't online (or international roaming / cellular data is off)
        case offline
        /// Server not found (DNS failure): common on blocked networks
        case noDNS
        /// Server not responding: timeout, can't connect, connection dropped
        case noResponse
        /// Secure connection (HTTPS) can't be established: wrong certificate or interfered connection
        case secureConnection
        /// The server refused this network or region (HTTP 403 / 451), or this network's proxy asks for a sign-in (HTTP 407)
        case refused
        /// This Mac's date or time looks wrong: secure connections to several servers failed on their certificates' dates.
        /// About this Mac, so it has no provider name
        case clock
        /// Several servers sent back a web page instead of their data: this network most likely shows a page of its own, such as
        /// a sign-in page. About the network, so it has no provider name
        case signIn
        // The following are problems on the data provider's side, not the network
        /// No data at the address anymore (HTTP 404 / 410): may have moved or changed URL
        case notFound
        /// The server keeps erroring (HTTP 5xx)
        case serverError
        /// Downloaded but unreadable: the format changed, or a web page came back instead of data
        case badData
        /// Live data stuck long ago (the generation time written in the data itself), not updating
        case stale

        /// A problem with this Mac or its network (not on the data provider's side)
        public var isNetwork: Bool {
            switch self {
            case .offline, .noDNS, .noResponse, .secureConnection, .refused, .clock, .signIn: return true
            case .notFound, .serverError, .badData, .stale: return false
            }
        }

        /// About this Mac or its network as a whole, not one provider: the notice has no provider name, and it's never counted
        /// with the unreachable servers (see looksRestricted)
        public var isGeneral: Bool {
            self == .offline || self == .clock || self == .signIn
        }
    }

    public struct Notice: Codable, Sendable, Hashable {
        /// The data provider's name (English, a UI translation key), e.g. "MTA". Empty when offline.
        public var provider: String
        public var problem: Problem
        /// Since when it's been unreachable
        public var since: Date
        /// Problems with the monthly downloaded timetables and stop data: shown until the next successful download (previously downloaded data is used meanwhile).
        /// Optional: older snapshots don't have this field.
        public var lasting: Bool?
        public init(provider: String, problem: Problem, since: Date, lasting: Bool? = nil) {
            self.provider = provider
            self.problem = problem
            self.since = since
            self.lasting = lasting
        }
    }

    /// What was seen besides the kind of failure, for the notices about this Mac or its network as a whole
    enum Cause: Equatable {
        /// A web page came back instead of the data
        case webPage
        /// The secure connection failed on the certificate's date
        case certificateDate
    }

    struct Entry: Equatable {
        var problem: Problem
        var failures: Int
        var since: Date
        var last: Date
        var lasting = false
        var cause: Cause?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    /// Problems with the data itself (unreadable, not updating): a successful download doesn't resolve it; cleared only once it's readable and fresh
    nonisolated(unsafe) private static var dataIssues: [String: Entry] = [:]
    /// Problems with the monthly downloaded data: recorded separately, a successful live data download doesn't clear it; wait for its own next successful download
    nonisolated(unsafe) private static var staticIssues: [String: Entry] = [:]
    nonisolated(unsafe) private static var offlineSince: Date?
    nonisolated(unsafe) private static var offlineLast: Date?

    /// Notify only after this many consecutive failures (an occasional timeout doesn't count). Refusals (403 / 451) and being offline notify the first time.
    public static let failuresBeforeNotice = 2
    /// If not retried for this long (e.g. on standby), drop the notice: we don't know whether it still applies
    public static let forgetAfter: TimeInterval = 15 * 60
    /// With this many unreachable at once, say "your network may be blocking these servers"
    public static let providersForRestriction = 2
    /// Notify server errors (5xx) only after this many in a row: occasional errors are common
    public static let serverErrorsBeforeNotice = 3
    /// If the generation time written in live data is this much older than now, it counts as not updating
    public static let staleAfter: TimeInterval = 30 * 60

    /// Servers that need the user's own key or account: their 401 / 403 are key or account problems, not the network (noted elsewhere).
    /// Only the API servers: NJ Transit's free timetable downloads (www.njtransit.com) need no account, so a 403 there is a refusal.
    static func needsKey(host: String) -> Bool {
        let h = host.lowercased()
        return h.hasPrefix("bustime.") || h.contains("raildata.njtransit") || h.contains("pcsdata.njtransit") || h.contains("goswift")
    }

    /// The way it failed; nil when not a network problem (e.g. cancelled, bad data format)
    public static func problem(for error: Error) -> Problem? {
        guard let e = error as? URLError else { return nil }
        switch e.code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .noDNS
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .resourceUnavailable:
            return .noResponse
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnection
        // The server sent the app on to an address without encryption, which macOS doesn't follow: the operator moved its data,
        // nothing on this network
        case .appTransportSecurityRequiresSecureConnection:
            return .notFound
        default:
            return nil
        }
    }

    /// What else the failure says: a certificate out of date, which for several servers at once means this Mac's date or time
    static func cause(for error: Error) -> Cause? {
        guard let e = error as? URLError else { return nil }
        switch e.code {
        case .serverCertificateHasBadDate, .serverCertificateNotYetValid: return .certificateDate
        default: return nil
        }
    }

    /// Stopped on purpose (standby, or the caller moved on), not failed: never shown or counted as a failure, and doesn't hold off the next try
    public static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Response status code: 451 always means refused for legal or regional reasons; 403 counts as refusal on servers that need no key;
    /// 407 is this network's proxy asking for a sign-in, a refusal on this network too; 404 / 410 means no data at the address anymore;
    /// 5xx is a server error (429 rate limiting is noted separately). Success clears the record.
    /// lasting: monthly downloaded data (see Notice.lasting)
    public static func record(status: Int, url: URL, provider: String? = nil, lasting: Bool = false, now: Date = Date()) {
        guard let host = url.host else { return }
        let name = provider ?? RateLimit.provider(forHost: host)
        if (200..<400).contains(status) {
            succeeded(name: name, lasting: lasting)
        } else if status == 451 || status == 407 || (status == 403 && !needsKey(host: host)) {
            failed(.refused, name: name, lasting: lasting, now: now)
        } else if status == 404 || status == 410 {
            failed(.notFound, name: name, lasting: lasting, now: now)
        } else if (500..<600).contains(status) {
            failed(.serverError, name: name, lasting: lasting, now: now)
        }
    }

    /// The download failed: record it if it's a network problem
    public static func record(error: Error, url: URL, provider: String? = nil, lasting: Bool = false, now: Date = Date()) {
        guard let problem = problem(for: error), let host = url.host else { return }
        failed(problem, name: provider ?? RateLimit.provider(forHost: host), lasting: lasting, now: now, cause: cause(for: error))
    }

    private static func failed(_ problem: Problem, name: String, lasting: Bool, now: Date, cause: Cause? = nil) {
        lock.lock()
        if problem == .offline {
            if offlineSince == nil { offlineSince = now }
            offlineLast = now
            lock.unlock()
            return
        }
        if lasting {
            staticIssues[name] = bumped(staticIssues[name], problem, lasting: true, now: now, cause: cause)
        } else {
            entries[name] = bumped(entries[name], problem, lasting: false, now: now, cause: cause)
        }
        let save = problem.isNetwork ? nil : historyNoting(name, now: now)
        lock.unlock()
        save?()
    }

    /// cause: what the latest failure showed besides its kind (see Cause); a failure that showed nothing more clears it
    private static func bumped(_ old: Entry?, _ problem: Problem, lasting: Bool, now: Date, cause: Cause? = nil) -> Entry {
        var e = old ?? Entry(problem: problem, failures: 0, since: now, last: now)
        if e.problem != problem { e.failures = 0 }
        e.failures += 1
        e.problem = problem
        e.last = now
        e.lasting = e.lasting || lasting
        e.cause = cause
        return e
    }

    private static func name(_ url: URL, _ provider: String?) -> String? {
        provider ?? url.host.map(RateLimit.provider(forHost:))
    }

    /// The downloaded data is unreadable (format changed, or a web page came back: webPage)
    public static func recordBadData(url: URL, provider: String? = nil, lasting: Bool = false, webPage: Bool = false,
                                     now: Date = Date()) {
        guard let name = name(url, provider) else { return }
        lock.lock()
        let cause: Cause? = webPage ? .webPage : nil
        if lasting {
            staticIssues[name] = bumped(staticIssues[name], .badData, lasting: true, now: now, cause: cause)
        } else {
            dataIssues[name] = bumped(dataIssues[name], .badData, lasting: false, now: now, cause: cause)
        }
        let save = historyNoting(name, now: now)
        lock.unlock()
        save?()
    }

    /// Readable: clear "unreadable". timestamp: the generation time written in live data; if too old, record "not updating"
    /// (data without departures doesn't count: at night when service stops, some sources stop updating the time). Compared with the
    /// servers' time (see ClockSkew), so a Mac clock that is fast doesn't make every provider look stuck
    public static func recordGoodData(url: URL, provider: String? = nil, timestamp: Date? = nil, hasTrips: Bool = true,
                                      lasting: Bool = false, now: Date = Date()) {
        guard let name = name(url, provider) else { return }
        lock.lock()
        let save: (() -> Void)?
        if lasting {
            staticIssues[name] = nil
            save = historyClearing(name)
        } else if let timestamp, hasTrips, ClockSkew.now(now).timeIntervalSince(timestamp) > staleAfter {
            var e = dataIssues[name] ?? Entry(problem: .stale, failures: 0, since: timestamp, last: now)
            if e.problem != .stale { e = Entry(problem: .stale, failures: 0, since: timestamp, last: now) }
            e.failures += 1
            e.last = now
            dataIssues[name] = e
            save = historyNoting(name, now: now)
        } else {
            dataIssues[name] = nil
            save = historyClearing(name)
        }
        lock.unlock()
        save?()
    }

    /// Reading data: record it if unreadable (cancellation doesn't count), clear it if readable
    public static func reading<T>(_ url: URL, provider: String? = nil, lasting: Bool = false, now: Date = Date(),
                                  _ body: () throws -> T) throws -> T {
        do {
            let value = try body()
            recordGoodData(url: url, provider: provider, lasting: lasting, now: now)
            return value
        } catch {
            if !(error is CancellationError) { recordBadData(url: url, provider: provider, lasting: lasting, now: now) }
            throw error
        }
    }

    /// The response is a web page when a web page wasn't wanted: most likely the URL changed and got redirected to the homepage
    public static func isWebPage(_ response: URLResponse?, accept: String?) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              type.contains("text/html") else { return false }
        return !(accept?.lowercased().contains("html") ?? false)
    }

    private static func succeeded(name: String, lasting: Bool) {
        lock.lock()
        // One provider can download, so this Mac is online
        offlineSince = nil
        offlineLast = nil
        // Monthly downloaded data: a successful download still needs to be readable to count as fine (see reading); only clear network and server problems here
        if lasting {
            if let e = staticIssues[name], e.problem != .badData { staticIssues[name] = nil }
        } else {
            entries[name] = nil
        }
        let save = historyClearing(name)
        lock.unlock()
        save?()
    }

    /// What to show: when offline, only say offline (every provider is unreachable then, no need to list them one by one); otherwise list the unreachable ones (sorted by name).
    public static func notices(now: Date = Date()) -> [Notice] {
        lock.lock(); defer { lock.unlock() }
        if let since = offlineSince, let last = offlineLast, now.timeIntervalSince(last) < forgetAfter {
            return [Notice(provider: "", problem: .offline, since: since)]
        }
        // Each kind keeps only what's due to be shown first, so one timeout (not shown yet) or a forgotten problem doesn't hide another kind's notice
        func shown(_ kind: [String: Entry]) -> [String: Entry] {
            kind.filter { _, e in (e.lasting || now.timeIntervalSince(e.last) < forgetAfter) && e.failures >= threshold(e) }
        }
        // When the same provider is both unreachable and has data problems, only mention unreachable (whether data problems remain is only known once it can download)
        var all = shown(staticIssues)
        for (name, e) in shown(dataIssues) { all[name] = e }
        for (name, e) in shown(entries) { all[name] = e }
        let general = generalNotices(&all)
        return general + all.map { name, e in
            Notice(provider: name, problem: e.problem, since: e.since, lasting: e.lasting ? true : nil)
        }.sorted { $0.provider < $1.provider }
    }

    /// What several providers show at once is about this Mac or its network, not each of them: their certificates out of date
    /// (this Mac's date or time), or a web page instead of their data (the network's own page, such as a sign-in page). Those
    /// providers' notices become one, and leave `all`
    static func generalNotices(_ all: inout [String: Entry]) -> [Notice] {
        var general: [Notice] = []
        for (cause, problem) in [(Cause.certificateDate, Problem.clock), (.webPage, .signIn)] {
            let names = all.filter { $0.value.cause == cause }.map(\.key)
            guard names.count >= providersForRestriction else { continue }
            let since = names.compactMap { all[$0]?.since }.min() ?? Date()
            for name in names { all[name] = nil }
            general.append(Notice(provider: "", problem: problem, since: since))
        }
        return general
    }

    /// How many failures before notifying. Monthly downloaded data notifies on the first (the next try is a long way off).
    private static func threshold(_ e: Entry) -> Int {
        if e.lasting { return 1 }
        switch e.problem {
        case .refused: return 1
        case .serverError: return serverErrorsBeforeNotice
        default: return failuresBeforeNotice
        }
    }

    /// Several unreachable at once (while online): most likely the network is blocking, not one provider's server being broken.
    /// The notices about this Mac or its network as a whole (offline, its clock, a sign-in page) say their own reason, so they don't count
    public static func looksRestricted(_ notices: [Notice]) -> Bool {
        notices.filter { $0.problem.isNetwork && !$0.problem.isGeneral }.count >= providersForRestriction
    }

    /// For tests: clear (also the problems' history, which is then no longer saved)
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        dataIssues = [:]
        staticIssues = [:]
        offlineSince = nil
        offlineLast = nil
        history = [:]
        saveHistory = nil
        historySavedAt = nil
    }

    // MARK: Since when an operator-side problem has lasted

    /// An operator-side problem (moved, server errors, unreadable, live data not updating), by provider name: since when, and when it
    /// was last seen. Kept across launches: the app restores and saves it (see keepHistory); the widget doesn't
    public struct History: Codable, Sendable, Equatable {
        public var since: Date
        public var last: Date

        public init(since: Date, last: Date) {
            self.since = since
            self.last = last
        }
    }

    /// A gap longer than this between two failures starts the count again: while the app is on standby or closed nothing is tried,
    /// and whether it got better meanwhile isn't known, so the day said is never earlier than what was seen
    public static let historyGap: TimeInterval = 3 * 24 * 3600
    /// After this long, the notice also says since when, and offers to check for a new version (see longProblemSince)
    public static let longProblem: TimeInterval = 14 * 24 * 3600
    /// The time of the last failure is saved at most this often (the gap above is days)
    static let historySaveEvery: TimeInterval = 3600

    nonisolated(unsafe) private static var history: [String: History] = [:]
    nonisolated(unsafe) private static var saveHistory: (@Sendable ([String: History]) -> Void)?
    nonisolated(unsafe) private static var historySavedAt: Date?

    /// The app at launch: the history saved last time, and where to save it from now on
    public static func keepHistory(_ saved: [String: History], save: @escaping @Sendable ([String: History]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        history = saved
        saveHistory = save
        historySavedAt = nil
    }

    /// The history as it is now
    public static var problemHistory: [String: History] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    /// Since when this provider's operator-side problem has lasted, once it has lasted `longProblem`; nil before, and with none
    public static func longProblemSince(_ provider: String, now: Date = Date()) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let h = history[provider], now.timeIntervalSince(h.since) >= longProblem else { return nil }
        return h.since
    }

    /// Some kind of problem on the provider's side is still recorded for it (call with the lock held)
    private static func hasProviderProblem(_ name: String) -> Bool {
        [entries[name], dataIssues[name], staticIssues[name]].contains { $0.map { !$0.problem.isNetwork } ?? false }
    }

    /// An operator-side failure now (call with the lock held). Returns the save to make once the lock is released, if one is due
    private static func historyNoting(_ name: String, now: Date) -> (() -> Void)? {
        let old = history[name]
        var h = old ?? History(since: now, last: now)
        if now.timeIntervalSince(h.last) > historyGap { h = History(since: now, last: now) }
        h.last = max(h.last, now)
        history[name] = h
        let due = old?.since != h.since || historySavedAt.map { now.timeIntervalSince($0) >= historySaveEvery } ?? true
        guard due, let save = saveHistory else { return nil }
        historySavedAt = now
        let copy = history
        return { save(copy) }
    }

    /// The provider got through (call with the lock held): its history goes once no problem on its side is left
    private static func historyClearing(_ name: String) -> (() -> Void)? {
        guard history[name] != nil, !hasProviderProblem(name) else { return nil }
        history[name] = nil
        guard let save = saveHistory else { return nil }
        let copy = history
        return { save(copy) }
    }
}

/// Where a program saves its settings: its own UserDefaults, which macOS keeps in that program's container. The app's hold the
/// user's favorites, recent places and every setting; the widget's hold only the few settings the app hands it (WidgetHandoff).
/// Settings in the app (SharedStore) and the "Allow network" check before every download both use `current`, so a value is
/// always read from where it was saved.
public enum SharedDefaults {
    /// The name the app's settings are saved under, and separately the widget's (the two don't see each other's)
    public static let ownName = "com.cheecar.CatchMyTrain.settings"

    /// The app's and the widget's bundle identifiers start with this
    static let bundlePrefix = "com.cheecar.CatchMyTrain"

    /// The settings of the program with this bundle identifier: the app's or the widget's own; for anything else (the package's
    /// tests) the standard ones
    public static func own(bundleIdentifier: String?) -> UserDefaults {
        guard let bundleIdentifier, bundleIdentifier.hasPrefix(bundlePrefix), let own = UserDefaults(suiteName: ownName) else { return .standard }
        return own
    }

    /// Running under Xcode's test runner, which is what sets these variables (debug builds only: in a release build they change
    /// nothing). The app the tests run in makes and writes nothing in the folder shared with the widget
    public static let isTestRun: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
        #else
        return false
        #endif
    }()

    /// Chosen once per process.
    public static let current: UserDefaults = own(bundleIdentifier: Bundle.main.bundleIdentifier)
}

/// The "Allow network" toggle in Settings (foolproofing: no need to go to the Mac's System Settings).
/// When off, neither the main app nor the widget goes online: every download stops before sending a request, treated as no network (not recorded in NetworkReach).
/// The value lives in SharedDefaults: the app saves it in its own settings and hands it to the widget, which keeps it in its own
/// (WidgetHandoff); on when never stored.
public enum NetworkSwitch {
    public static let defaultsKey = "networkAllowed"

    public static var isAllowed: Bool { isAllowed(in: SharedDefaults.current) }

    public static func isAllowed(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setAllowed(_ allowed: Bool, in defaults: UserDefaults = SharedDefaults.current) {
        defaults.set(allowed, forKey: defaultsKey)
    }

    /// Throws "no network" when off
    public static func check() throws {
        guard isAllowed else { throw URLError(.notConnectedToInternet) }
    }
}

/// Does the same work for several items at once and gives back each item's result under that item.
///
/// Each piece of work puts its own result away (Shelf), and the group the pieces run in hands nothing back. A group whose pieces
/// hand back a pair, an item with its result, isn't written anywhere in the app: an optimized build can get such pairs back
/// damaged, every result under the first item's name. RepositoryHygieneTests keeps such groups out of the source, and the
/// package's tests are also run in an optimized build
public enum Together {
    /// - Parameters:
    ///   - items: what the work is done for; one listed twice is done once
    ///   - limit: at most this many pieces of work run at once (nil: all of them)
    /// - Returns: every item's result
    public static func each<Item: Hashable & Sendable, Value: Sendable>(
        _ items: [Item], limit: Int? = nil, _ work: @escaping @Sendable (Item) async -> Value
    ) async -> [Item: Value] {
        var seen: Set<Item> = []
        let unique = items.filter { seen.insert($0).inserted }
        let shelf = Shelf<Item, Value>()
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in unique.enumerated() {
                // Full: wait for one to finish first
                if let limit, index >= max(1, limit) { await group.next() }
                group.addTask { await shelf.put(await work(item), for: item) }
            }
        }
        return await shelf.values
    }

    /// Where the pieces of work put their results
    private actor Shelf<Item: Hashable & Sendable, Value: Sendable> {
        private(set) var values: [Item: Value] = [:]
        func put(_ value: Value, for item: Item) { values[item] = value }
    }
}

/// Turns for downloads: at most `limit` run at once, the others wait in order of arrival. A download holds its turn only while it
/// downloads (not while its data is read), and never asks for a second one, so turns can't wait on each other
public actor DownloadSlots {
    /// Ferries' and regional buses' timetable packages and live data share these (DownloadLimit.atOnce)
    public static let shared = DownloadSlots(limit: DownloadLimit.atOnce)
    private let limit: Int
    private var used = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The most that ran at once, for the tests
    private(set) var most = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Waits for a turn. Every take() needs one give(), also when the download throws
    public func take() async {
        if used < limit {
            used += 1
            most = max(most, used)
            return
        }
        // The turn is handed over by give(): used stays the same
        await withCheckedContinuation { waiting.append($0) }
    }

    public func give() {
        if waiting.isEmpty {
            used -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Runs one download in a turn of the shared slots. A download stopped while it waited (standby) doesn't start
    public static func download<T>(_ body: () async throws -> T) async throws -> T {
        try await shared.run(body)
    }

    nonisolated func run<T>(_ body: () async throws -> T) async throws -> T {
        await take()
        do {
            try Task.checkCancellation()
            let value = try await body()
            await give()
            return value
        } catch {
            await give()
            throw error
        }
    }
}
