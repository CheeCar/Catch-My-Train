import Foundation

/// Manages the token: use the stored one if there is one; when it stops working, get a new one with the account.
/// Automatic renewals are limited (see minRenewalGap) and shared by concurrent refreshes, so the daily quota isn't used up;
/// a new token that doesn't work either makes the next renewal wait longer (see renewalGap(afterUnproven:)).
/// That pace is kept through loadPace and savePace (see RenewalPace), so a relaunch waits as long as the last run would have.
/// Removing or switching the account starts a new generation: a sign-in that started before can't save its token or its refusal afterwards.
public actor NJTransitClient {
    public struct Account: Sendable, Equatable {
        public var username: String
        public var password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// What tryAccount found out about an account. The token it got stays inside TransitCore until adopt(_:) hands it over.
    public struct AccountTrial: Sendable {
        /// true works, false refused, nil couldn't tell (network down, NJ Transit temporarily failing, today's sign-ins used up)
        public let works: Bool?
        /// What NJ Transit said when it refused the account
        public let refusal: String?
        let token: String?
        /// Today's sign-ins were used up: an account saved anyway isn't signed in with before they come back
        var limitReached = false
    }

    /// What paces automatic renewals, saved by the app (FerryStore.njTransit) so a relaunch doesn't start over and use another of the day's few sign-ins
    public struct RenewalPace: Codable, Sendable, Equatable {
        public var nextRenewal: Date?
        public var backoffUntil: Date?
        public var unproven = 0
        public var unanswered = 0
        /// The last automatic renewal was refused (still reported as refused while renewals wait)
        public var refused = false
        /// Automatic renewals refused in a row (see refusalGap(afterRefusals:))
        public var refusals = 0
        /// The last automatic renewal found today's sign-ins used up (still reported so until they come back)
        public var limited = false
        public init() {}

        enum CodingKeys: String, CodingKey { case nextRenewal, backoffUntil, unproven, unanswered, refused, refusals, limited }

        /// A pace saved by an older version, without the newer fields, reads with those at their starting values
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nextRenewal = try c.decodeIfPresent(Date.self, forKey: .nextRenewal)
            backoffUntil = try c.decodeIfPresent(Date.self, forKey: .backoffUntil)
            unproven = try c.decodeIfPresent(Int.self, forKey: .unproven) ?? 0
            unanswered = try c.decodeIfPresent(Int.self, forKey: .unanswered) ?? 0
            refused = try c.decodeIfPresent(Bool.self, forKey: .refused) ?? false
            refusals = try c.decodeIfPresent(Int.self, forKey: .refusals) ?? 0
            limited = try c.decodeIfPresent(Bool.self, forKey: .limited) ?? false
        }
    }

    private let poster: FormPosting
    private let endpoints: NJTransitLive.Endpoints
    private let loadToken: @Sendable () -> String?
    private let saveToken: @Sendable (String?) -> Void
    private let loadPace: @Sendable () -> RenewalPace?
    private let savePace: @Sendable (RenewalPace?) -> Void
    /// Gets a line for the app's log each time this client signs in (see NJTransitLive.signInLogLine)
    private let log: @Sendable (String) -> Void
    /// The saved pace was read (or replaced by forget() or adopt(_:), which must not read an older one afterwards)
    private var paceLoaded = false
    /// The pace as last saved, so an unchanged one isn't written again
    private var savedPace = RenewalPace()
    private(set) var token: String?
    private var tokenLoaded = false
    /// What NJ Transit said the last time it refused the account (nil once it accepts it)
    public private(set) var lastRefusal: String?
    /// What NJ Transit said with its last answer that wasn't data or a token (see NJTransitLive.said), for the app's log; nil
    /// once data comes again
    public private(set) var lastSaid: String?
    /// A token NJ Transit said doesn't work: not sent again while no new one may be asked for (see tripUpdates(account:))
    private var failedToken: String?
    /// Automatic renewals refused in a row (see refusalGap(afterRefusals:))
    private var refusals = 0
    private let now: @Sendable () -> Date
    /// Automatic renewal in progress: refreshes that find the token not working at the same time wait for this one
    private var renewing: Task<Void, Error>?
    /// Earliest time the next automatic renewal may start
    private var nextRenewal: Date?
    /// How the last automatic renewal failed (repeated while renewals are paused, so a refused account keeps showing as refused)
    private var lastRenewalError: Error?
    /// Goes up when the account is forgotten or replaced; a sign-in from an older generation is dropped when it returns
    private var generation = 0
    /// A new account is being tried (tryAccount): the old one is still saved, but automatic renewals don't sign in with it,
    /// because it's about to be replaced and each sign-in counts against its daily limit
    private var tryingAccount = false
    /// The current token has downloaded GTFS-Realtime at least once
    private var tokenProven = false
    /// The current token was just issued and no download has used it yet
    private var tokenUntested = false
    /// Renewals in a row whose new token got no GTFS-Realtime on its first download
    private var unprovenRenewals = 0
    /// Renewals in a row that got no answer from NJ Transit (no network, timeout, server error)
    private var unansweredRenewals = 0
    /// No automatic renewal before this, after a new token didn't work (see renewalGap(afterUnproven:)); lifted once a token works
    private var renewalBackoff: Date?

    /// Least time between automatic renewals. A server that keeps answering with something other than GTFS-Realtime
    /// (an error page, maintenance) would otherwise trigger a renewal on every refresh. signIn from Settings is not limited.
    public static let minRenewalGap: TimeInterval = 30 * 60
    /// Shorter wait after a renewal that got no answer from NJ Transit (no network, timeout, server error),
    /// so live data comes back soon after a short outage
    public static let retryGap: TimeInterval = 2 * 60
    /// Longest wait between automatic renewals while new tokens keep failing or NJ Transit doesn't answer
    public static let maxRenewalGap: TimeInterval = 24 * 3600

    /// Wait before the next automatic renewal after n renewals in a row got no answer: 2, 4, 8 … minutes, on past minRenewalGap
    /// up to a day. NJ Transit may have counted a sign-in it didn't answer in time against the daily limit, so a long outage doesn't
    /// use them up (about ten in its first day, then one a day); each wait is about as long as NJ Transit has failed so far
    public static func retryWait(afterUnanswered n: Int) -> TimeInterval {
        min(retryGap * pow(2, Double(min(max(n - 1, 0), 16))), maxRenewalGap)
    }

    /// Wait before the next automatic renewal after n renewals in a row whose new token didn't work: 1 h, 2 h, 4 h … up to a day
    /// (n = 0: the usual minRenewalGap)
    public static func renewalGap(afterUnproven n: Int) -> TimeInterval {
        min(minRenewalGap * pow(2, Double(min(max(n, 0), 16))), maxRenewalGap)
    }

    /// Wait before the next automatic sign-in after n refused ones in a row: 30 minutes, 1, 2, 4, 8 hours, then a day. NJ Transit
    /// allows 10 sign-ins a day, so a refused account doesn't use them all up (saving the account in Settings starts over)
    public static func refusalGap(afterRefusals n: Int) -> TimeInterval {
        n >= 6 ? maxRenewalGap : minRenewalGap * pow(2, Double(max(n - 1, 0)))
    }

    /// When today's sign-ins come back after the daily limit was reached: NJ Transit resets them after midnight, taken as its own
    /// time (its area's, the New York area's), and a minute is added
    public static func dailyLimitReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MetroArea.newYork.timeZone
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(24 * 3600)
        return next.addingTimeInterval(60)
    }

    /// The poster used when none is given: for the test systems it records nothing (see Endpoints.recordsReach)
    static func defaultPoster(for endpoints: NJTransitLive.Endpoints) -> URLSessionFormPoster {
        URLSessionFormPoster(recordsReach: endpoints.recordsReach)
    }

    public init(poster: FormPosting? = nil, endpoints: NJTransitLive.Endpoints = .rail,
                loadToken: @escaping @Sendable () -> String?,
                saveToken: @escaping @Sendable (String?) -> Void,
                now: @escaping @Sendable () -> Date = { Date() },
                loadPace: @escaping @Sendable () -> RenewalPace? = { nil },
                savePace: @escaping @Sendable (RenewalPace?) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.poster = poster ?? NJTransitClient.defaultPoster(for: endpoints)
        self.endpoints = endpoints
        self.loadToken = loadToken
        self.saveToken = saveToken
        self.now = now
        self.loadPace = loadPace
        self.savePace = savePace
        self.log = log
    }

    /// Reads the saved pace once. Its waits are cut to at most maxRenewalGap from now, so a clock change or bad data can't block
    /// sign-ins for more than a day.
    private func loadPaceOnce() {
        guard !paceLoaded else { return }
        paceLoaded = true
        guard let pace = loadPace() else { return }
        let latest = now().addingTimeInterval(Self.maxRenewalGap)
        nextRenewal = pace.nextRenewal.map { min($0, latest) }
        renewalBackoff = pace.backoffUntil.map { min($0, latest) }
        unprovenRenewals = max(pace.unproven, 0)
        unansweredRenewals = max(pace.unanswered, 0)
        refusals = max(pace.refusals, 0)
        lastRenewalError = pace.refused ? NJTransitLive.LiveError.rejected : pace.limited ? NJTransitLive.LiveError.rateLimited : nil
        savedPace = pace
    }

    /// Saves the pace when it changed (force: always, so a reset replaces a saved pace that was never read); nil when there's nothing to wait for
    private func persistPace(force: Bool = false) {
        var pace = RenewalPace()
        pace.nextRenewal = nextRenewal
        pace.backoffUntil = renewalBackoff
        pace.unproven = unprovenRenewals
        pace.unanswered = unansweredRenewals
        pace.refused = (lastRenewalError as? NJTransitLive.LiveError) == .rejected
        pace.refusals = refusals
        pace.limited = (lastRenewalError as? NJTransitLive.LiveError) == .rateLimited
        guard force || pace != savedPace else { return }
        savedPace = pace
        savePace(pace == RenewalPace() ? nil : pace)
    }

    /// Exchange the account for a token (also used to check whether the account is valid).
    public func signIn(_ account: Account) async throws {
        try await signIn(account, generation: generation)
    }

    /// gen: the generation the sign-in started in. If the account was forgotten or replaced while NJ Transit answered,
    /// the answer is dropped (no token saved, no refusal kept) and CancellationError is thrown.
    /// Each sign-in writes one line to the app's log, saying which API and how it ended.
    private func signIn(_ account: Account, generation gen: Int) async throws {
        // Looked at before asking: with the network turned off, or the server left alone after a rate limit, nothing is sent
        let held = !NetworkSwitch.isAllowed || endpoints.token.host.map { RateLimit.pausedUntil(host: $0) != nil } == true
        do {
            try await askForToken(account, generation: gen)
            log(NJTransitLive.signInLogLine(endpoints, .accepted))
        } catch {
            let result = NJTransitLive.SignInResult(error)
            log(NJTransitLive.signInLogLine(endpoints, held && (result == .noAnswer || result == .notUnderstood) ? .notSent : result))
            throw error
        }
    }

    private func askForToken(_ account: Account, generation gen: Int) async throws {
        let secrets = [account.username, account.password]
        let data: Data
        var status: Int?
        do {
            data = try await poster.post(endpoints.token,
                                         fields: [("username", account.username), ("password", account.password)])
        } catch NJTransitLive.LiveError.rejected {
            guard gen == generation else { throw CancellationError() }
            lastRefusal = "HTTP 401/403"
            lastSaid = lastRefusal
            throw NJTransitLive.LiveError.rejected
        } catch let answer as NJTransitLive.ErrorStatusAnswer {
            // NJ Transit's own words with an error status: read like any other answer below
            data = answer.body
            status = answer.status
        } catch {
            // No answer (the network, a timeout): nothing NJ Transit said goes with this failure
            if gen == generation { lastSaid = nil }
            throw error
        }
        guard gen == generation else { throw CancellationError() }
        let new: String
        do {
            if let status {
                // The daily limit and a refusal mean the same with any status; other words are a problem on NJ Transit's side
                if NJTransitLive.reply(to: data) == .limitReached { throw NJTransitLive.LiveError.rateLimited }
                if NJTransitLive.saysRefused(data) { throw NJTransitLive.LiveError.rejected }
                throw FeedFetchError.httpStatus(status)
            }
            new = try NJTransitLive.token(from: data)
        } catch NJTransitLive.LiveError.rejected {
            lastRefusal = NJTransitLive.serverMessage(from: data, hiding: secrets) ?? (NJTransitLive.isNull(data) ? "Null" : nil)
            lastSaid = NJTransitLive.said(data, status: status, hiding: secrets)
            throw NJTransitLive.LiveError.rejected
        } catch NJTransitLive.LiveError.rateLimited {
            lastSaid = NJTransitLive.said(data, status: status, hiding: secrets)
            // Today's token renewals are used up: the host is paused for an hour, and automatic renewals wait until the next day's
            // come back (see renewToken). A test system is only probed: nothing to pause or show
            if endpoints.recordsReach, let host = endpoints.token.host { RateLimit.hit(host: host, retryAfter: 3600) }
            throw NJTransitLive.LiveError.rateLimited
        } catch {
            lastSaid = NJTransitLive.said(data, status: status, hiding: secrets)
            throw error
        }
        token = new
        tokenLoaded = true
        tokenProven = false
        tokenUntested = true
        lastRefusal = nil
        saveToken(new)
    }

    /// Forget the token (when deleting the account, or switching to one that wasn't tried). A sign-in still running is stopped,
    /// and its answer is dropped if it comes anyway.
    public func forget() {
        paceLoaded = true
        generation &+= 1
        renewing?.cancel()
        renewing = nil
        tryingAccount = false
        token = nil
        tokenLoaded = true
        nextRenewal = nil
        lastRenewalError = nil
        lastSaid = nil
        startAccountTrust(newToken: false)
        saveToken(nil)
        persistPace(force: true)
    }

    /// Another account (or none): what earlier tokens showed doesn't apply to it
    private func startAccountTrust(newToken: Bool) {
        tokenProven = false
        tokenUntested = newToken
        unprovenRenewals = 0
        unansweredRenewals = 0
        renewalBackoff = nil
        failedToken = nil
        refusals = 0
    }

    /// Switching accounts: sign the new account in on a separate client, so this one keeps the old account's token until the new account
    /// is saved, and a refused account changes nothing. Until adopt(_:) or endTrial(), automatic renewals don't sign in with the old account.
    public func tryAccount(_ account: Account) async -> AccountTrial {
        tryingAccount = true
        let trial = NJTransitClient(poster: poster, endpoints: endpoints, loadToken: { nil }, saveToken: { _ in }, now: now, log: log)
        do {
            try await trial.signIn(account)
            return AccountTrial(works: true, refusal: nil, token: await trial.token)
        } catch NJTransitLive.LiveError.rejected {
            return AccountTrial(works: false, refusal: await trial.lastRefusal, token: nil)
        } catch NJTransitLive.LiveError.rateLimited {
            return AccountTrial(works: nil, refusal: nil, token: nil, limitReached: true)
        } catch {
            return AccountTrial(works: nil, refusal: nil, token: nil)
        }
    }

    /// The tried account is saved: use the token its trial got (none if it was refused or couldn't be checked; then the next refresh
    /// signs in with the new account). Sign-ins for the old account still running are dropped when they return.
    public func adopt(_ trial: AccountTrial) {
        paceLoaded = true
        generation &+= 1
        renewing?.cancel()
        renewing = nil
        tryingAccount = false
        token = trial.token
        tokenLoaded = true
        startAccountTrust(newToken: trial.token != nil)
        lastRefusal = trial.refusal
        lastSaid = nil
        if trial.works == false {
            // The trial was this account's renewal: a refused account isn't asked again before the usual gap, and its first
            // automatic refusal counts as the second in a row
            lastRenewalError = NJTransitLive.LiveError.rejected
            refusals = 1
            nextRenewal = now().addingTimeInterval(Self.refusalGap(afterRefusals: 1))
        } else if trial.limitReached {
            // Today's sign-ins are used up: none before they come back
            lastRenewalError = NJTransitLive.LiveError.rateLimited
            nextRenewal = Self.dailyLimitReset(after: now())
        } else {
            lastRenewalError = nil
            nextRenewal = nil
        }
        saveToken(trial.token)
        persistPace(force: true)
    }

    /// The tried account wasn't saved: keep the old one, whose renewals may run again
    public func endTrial() {
        tryingAccount = false
    }

    /// Download trip updates. If the token doesn't work, renew it once and retry; throws LiveError.rejected if the account is wrong.
    public func tripUpdates(account: Account) async throws -> Data {
        loadPaceOnce()
        if !tokenLoaded {
            token = loadToken()
            tokenLoaded = true
        }
        // Only renew when NJ Transit says the token doesn't work; on network failure or a temporary NJ Transit problem, fail directly
        // (don't waste the daily renewals)
        let used = token
        if let used {
            try Task.checkCancellation()
            if used == failedToken, renewing == nil, renewalWaitActive {
                // NJ Transit said this token doesn't work and no new one may be asked for yet: asking with it again would only get
                // the same answer, so nothing is sent until the wait is over (then it's tried once more before signing in)
                throw lastRenewalError ?? NJTransitLive.LiveError.badResponse
            }
            // While another refresh renews it, this one waits for that renewal instead
            if used != failedToken || renewing == nil {
                if let data = try await fetch(token: used, account: account) { return data }
            }
        }
        // Another refresh may have renewed the token while this one was downloading: use that token instead of renewing again
        if token == used { try await renewToken(account) }
        // Stopped (standby) while NJ Transit answered the sign-in: the renewal still counts (its token is saved), but nothing more is downloaded
        try Task.checkCancellation()
        guard let token, let data = try await fetch(token: token, account: account) else { throw NJTransitLive.LiveError.badResponse }
        return data
    }

    /// No automatic renewal may start yet (see renewToken)
    private var renewalWaitActive: Bool {
        guard let until = [nextRenewal, renewalBackoff].compactMap({ $0 }).max() else { return false }
        return now() < until
    }

    /// Automatic renewal: at most once per minRenewalGap (sooner after a few failed connections, see retryWait), and concurrent callers share one sign-in.
    private func renewToken(_ account: Account) async throws {
        if let renewing { return try await renewing.value }
        // A refused or throttled account still says so while another account is tried
        if let next = [nextRenewal, renewalBackoff].compactMap({ $0 }).max(), now() < next {
            throw lastRenewalError ?? (NJTransitLive.LiveError.badResponse as Error)
        }
        if tryingAccount { throw CancellationError() }
        // A stopped refresh doesn't start a sign-in: each one counts against the daily limit
        try Task.checkCancellation()
        nextRenewal = now().addingTimeInterval(Self.minRenewalGap)
        // Saved before NJ Transit answers: quitting during the sign-in still keeps the gap
        persistPace()
        // Taken before the task starts: forget() or adopt(_:) may run while it waits for NJ Transit
        let gen = generation
        let task = Task { try await signIn(account, generation: gen) }
        renewing = task
        // A renewal from an older generation leaves the newer state alone (a newer renewal stays shared)
        defer { if gen == generation { renewing = nil } }
        do {
            try await task.value
            if gen == generation {
                lastRenewalError = nil
                unansweredRenewals = 0
                refusals = 0
                persistPace()
            }
        } catch {
            if gen == generation {
                lastRenewalError = error
                switch error {
                case NJTransitLive.LiveError.rejected:
                    // Refused again: each refusal in a row waits longer (see refusalGap(afterRefusals:))
                    unansweredRenewals = 0
                    refusals += 1
                    nextRenewal = now().addingTimeInterval(Self.refusalGap(afterRefusals: refusals))
                case NJTransitLive.LiveError.rateLimited:
                    // Today's sign-ins are used up: none before they come back
                    unansweredRenewals = 0
                    nextRenewal = Self.dailyLimitReset(after: now())
                case is NJTransitLive.LiveError:
                    // Another real answer from NJ Transit (unreadable) waits the full gap
                    unansweredRenewals = 0
                default:
                    unansweredRenewals += 1
                    nextRenewal = now().addingTimeInterval(Self.retryWait(afterUnanswered: unansweredRenewals))
                }
                persistPace()
            }
            throw error
        }
    }

    /// Downloads trip updates with this token. Returns nil when NJ Transit says the token doesn't work (HTTP 401 or 403, or
    /// "Invalid token"): then it's renewed. Anything else that isn't data throws without renewing (see NJTransitLive.reply(to:))
    private func fetch(token: String, account: Account) async throws -> Data? {
        let answer: Data
        var status: Int?
        do {
            answer = try await poster.post(endpoints.tripUpdates, fields: [("token", token)])
        } catch NJTransitLive.LiveError.rejected {
            lastSaid = "HTTP 401/403"
            return tokenFailed(token)
        } catch let error as NJTransitLive.ErrorStatusAnswer {
            answer = error.body
            status = error.status
        } catch {
            // No answer (the network, a timeout): nothing NJ Transit said goes with this failure
            lastSaid = nil
            throw error
        }
        let reply = NJTransitLive.reply(to: answer)
        if reply == .feed {
            // Only the token still in use is judged: another refresh may have renewed it during the download
            if token == self.token { judgeToken(worked: true) }
            if failedToken == token { failedToken = nil }
            lastSaid = nil
            return answer
        }
        lastSaid = NJTransitLive.said(answer, status: status, hiding: [token, account.username, account.password])
        switch reply {
        case .invalidToken: return tokenFailed(token)
        case .limitReached: throw NJTransitLive.LiveError.rateLimited
        default: throw NJTransitLive.LiveError.badResponse
        }
    }

    /// NJ Transit said this token doesn't work: it's renewed, and not sent again while renewals wait
    private func tokenFailed(_ token: String) -> Data? {
        failedToken = token
        if token == self.token { judgeToken(worked: false) }
        return nil
    }

    /// What a download showed about the current token
    private func judgeToken(worked: Bool) {
        defer { tokenUntested = false }
        if worked {
            guard !tokenProven else { return }
            tokenProven = true
            // A token works: renewals go back to the usual pace
            unprovenRenewals = 0
            renewalBackoff = nil
        } else if tokenUntested {
            // A token NJ Transit just issued got no GTFS-Realtime either, so the token isn't the problem (no access to this feed yet,
            // or an error page instead of data). It's kept, and each such renewal doubles the wait before the next, sparing today's sign-ins.
            unprovenRenewals += 1
            renewalBackoff = now().addingTimeInterval(Self.renewalGap(afterUnproven: unprovenRenewals))
        }
        persistPace()
    }
}
