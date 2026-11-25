import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// NJ Transit rail (and light rail) realtime data (GTFS-Realtime).
///
/// Needs the user's own NJ Transit developer account (like MTA Bus Time, use realtime data when an account is entered, the timetable otherwise).
/// The account is stored only in this Mac's Keychain, never in code, settings files or shared data.
///
/// Endpoints (GTFSRT at raildata.njtransit.com):
/// 1. Exchange the username and password for a token (getToken). NJ Transit limits how many times per day this can be done, so the token is stored and reused,
///    and only renewed when it stops working (expired or rejected).
/// 2. Use the token to download trip updates (getTripUpdates), which returns GTFS-Realtime (protobuf).
/// Both endpoints are POST, with parameters in a form (multipart/form-data).
public enum NJTransitLive {
    public static let baseURL = URL(string: "https://raildata.njtransit.com/api/GTFSRT/")!
    public static var tokenURL: URL { baseURL.appendingPathComponent("getToken") }
    public static var tripUpdatesURL: URL { baseURL.appendingPathComponent("getTripUpdates") }

    /// Two sets of endpoints: rail (raildata) and bus (pcsdata's GTFSG2). Same NJ Transit developer account, separate tokens.
    public struct Endpoints: Sendable, Equatable {
        public var token: URL
        public var tripUpdates: URL
        /// Whether rate limits and connection problems here are recorded for the notices the user sees. Off for the test systems:
        /// they're only probed, and their problems would otherwise show as the real service's ("NJ Transit rail" / "NJ Transit bus").
        public var recordsReach = true
        public static let rail = Endpoints(token: NJTransitLive.tokenURL, tripUpdates: NJTransitLive.tripUpdatesURL)
        public static let bus = Endpoints(
            token: URL(string: "https://pcsdata.njtransit.com/api/GTFSG2/authenticateUser")!,
            tripUpdates: URL(string: "https://pcsdata.njtransit.com/api/GTFSG2/getTripUpdates")!)
        /// NJ Transit's test systems (same paths on testraildata / testpcsdata). Only used to check whether a refused account
        /// works there, which means production access isn't turned on yet; their data is never shown as live times.
        public static let railTest = Endpoints(
            token: URL(string: "https://testraildata.njtransit.com/api/GTFSRT/getToken")!,
            tripUpdates: URL(string: "https://testraildata.njtransit.com/api/GTFSRT/getTripUpdates")!, recordsReach: false)
        public static let busTest = Endpoints(
            token: URL(string: "https://testpcsdata.njtransit.com/api/GTFSG2/authenticateUser")!,
            tripUpdates: URL(string: "https://testpcsdata.njtransit.com/api/GTFSG2/getTripUpdates")!, recordsReach: false)

        /// Which of NJ Transit's APIs this is, for the app's log
        var logName: String {
            if self == .rail { return "rail" }
            if self == .bus { return "bus" }
            if self == .railTest { return "rail test system" }
            if self == .busTest { return "bus test system" }
            return token.host ?? "other"
        }
    }
    /// Page for signing up for a developer account
    public static let signUpURL = URL(string: "https://developer.njtransit.com/registration")!

    public enum LiveError: Error, Equatable, Sendable {
        /// NJ Transit doesn't accept this username and password
        case rejected
        /// The response isn't understandable data (the endpoint changed, or NJ Transit has a temporary problem)
        case badResponse
        /// Too many requests (HTTP 429, or today's token renewals are used up)
        case rateLimited
    }

    /// NJ Transit answered with an error status (HTTP 500 and the like) and its own explanation in the body (a JSON object or
    /// list, or Null): what the body says decides what to do. An expired token comes back as HTTP 500 with "Invalid token.", and
    /// that one is renewed; other words aren't (see reply(to:)). Thrown by URLSessionFormPoster, read by NJTransitClient.
    public struct ErrorStatusAnswer: Error, Equatable, Sendable {
        public let status: Int
        public let body: Data
        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    /// What an answer to a live data request says (official wordings: "Invalid token." for trains, "Invalid Token.  Please
    /// authenticate user." for buses, "Daily usage limit:10. Your current daily usage: 11", "GTFS error", Null)
    enum Reply: Equatable {
        /// GTFS-Realtime data
        case feed
        /// The token doesn't work (expired or never valid): renew it
        case invalidToken
        /// The daily limit is reached: wait, don't sign in
        case limitReached
        /// Anything else (Null, "GTFS error", a web page, nothing): a problem on NJ Transit's side, tried again on the next refresh
        case other
    }

    static func reply(to data: Data) -> Reply {
        if looksLikeProtobuf(data) { return .feed }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .other }
        let says = object.compactMap { key, value -> String? in
            messageFieldParts.contains(where: key.lowercased().contains) ? value as? String : nil
        }
        if says.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("invalid token") }) {
            return .invalidToken
        }
        return saysLimitReached(object) ? .limitReached : .other
    }

    /// The answer is NJ Transit's Null (its sign-in says this when the username, the password or the account is missing)
    static func isNull(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.caseInsensitiveCompare("null") == .orderedSame
    }

    /// The body of an error status is NJ Transit's own explanation: Null, or JSON (a web page or nothing isn't)
    static func isOwnAnswer(_ data: Data) -> Bool {
        isNull(data) || (data.count <= 65_536 && (try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    /// A sign-in answer saying the account wasn't accepted: Null, or Authenticated False
    static func saysRefused(_ data: Data) -> Bool {
        if isNull(data) { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object.first(where: { $0.key.caseInsensitiveCompare("Authenticated") == .orderedSame })?.value else { return false }
        return (value as? Bool) == false || (value as? String)?.lowercased() == "false"
    }

    /// What NJ Transit said with an answer that wasn't data or a token, for the app's log: its own words (see serverMessage,
    /// which leaves out the account and the token), after the status when it wasn't 2xx ("HTTP 500, errorMessage: GTFS error")
    public static func said(_ data: Data, status: Int? = nil, hiding secrets: [String]) -> String {
        let words = serverMessage(from: data, hiding: secrets) ?? (isNull(data) ? "Null" : "empty answer")
        return status.map { "HTTP \($0), " + words } ?? words
    }

    /// Token response: {"Authenticated":"True","UserToken":"…"}. With a wrong account, Authenticated is False or there's no token;
    /// Null means the username, the password or the account is missing (NJ Transit's documentation), so it's a refusal too.
    public static func token(from data: Data) throws -> String {
        if isNull(data) { throw LiveError.rejected }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveError.badResponse
        }
        func value(_ key: String) -> Any? {
            object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        let authenticated = value("Authenticated").map { ($0 as? Bool) ?? (($0 as? String)?.lowercased() == "true") }
        // A token that came back is used: the sign-in has already counted against today's limit
        if authenticated != false, let token = value("UserToken") as? String, !token.isEmpty { return token }
        // Sign-ins have a daily cap: an answer saying it's used up means "try later", not a wrong account, with or without Authenticated
        if saysLimitReached(object) { throw LiveError.rateLimited }
        throw LiveError.rejected
    }

    /// Phrases that mean today's sign-ins are used up. A bare "limit" doesn't count: a refusal can mention a limit of another kind
    /// (attempts before a lockout, what the account may use), and taking a wrong account for a wait would hide the refusal.
    /// Taking the limit for a refusal is worse (Settings would drop a working account), so the wordings are broad. NJ Transit's own:
    /// "Daily usage limit:10. Your current daily usage: 11"
    static let limitPhrases = ["daily limit", "usage limit", "limit exceeded", "limit reached", "too many"]
    /// "Exceeded" says the limit is used up when it's about one of these ("Daily token limit has been exceeded")
    static let exceededWords = ["limit", "quota", "maximum", "token", "request"]
    /// "Reached" says it with these, wherever they are ("You have reached your daily token limit")
    static let reachedWords = ["limit", "quota", "maximum"]

    /// Whether this text from NJ Transit says the sign-in limit is reached, in any letter case
    static func saysLimitReached(_ text: String) -> Bool {
        let text = text.lowercased()
        return limitPhrases.contains(where: text.contains)
            || (text.contains("exceed") && exceededWords.contains(where: text.contains))
            || (text.contains("reached") && reachedWords.contains(where: text.contains))
    }

    /// Names of the fields that hold NJ Transit's explanation (errorMessage, message, error, Status, detail…)
    static let messageFieldParts = ["message", "error", "msg", "status", "detail"]

    /// Whether a message field says the sign-in limit is reached.
    /// Other fields aren't read: their values (a username, a plan name) aren't NJ Transit's explanation.
    static func saysLimitReached(_ object: [String: Any]) -> Bool {
        object.contains { key, value in
            let name = key.lowercased()
            guard messageFieldParts.contains(where: name.contains), let text = value as? String else { return false }
            return saysLimitReached(text)
        }
    }

    /// Fields whose names contain these may hold the account or a token: never shown
    static let hiddenFieldParts = ["pass", "pwd", "user", "token", "secret"]

    /// What NJ Transit said when it refused the account (its own words), to show the user and help find the cause.
    /// Fields that may hold the account or a token are left out, and the username and password (hiding) become "…" in any letter case.
    public static func serverMessage(from data: Data, hiding secrets: [String] = []) -> String? {
        let text: String
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            // Any JSON, also a list or nested objects: read as parsed, so a value the server escaped (\u0026 for "&") is hidden too
            text = describe(json, hiding: secrets).joined(separator: "; ")
        } else {
            // Hidden before shortening, so a username cut off at the end isn't left partly shown.
            // A web page may show a secret with its characters escaped ("&amp;" for "&"): those forms are hidden too
            text = redacting(secrets + secrets.flatMap(htmlEscaped), in: String(decoding: data.prefix(4096), as: UTF8.self))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    /// Whether NJ Transit's words (see serverMessage) only say the account wasn't accepted ("Authenticated: False", or its Null),
    /// which the line above them in Settings already says in plain words: then they aren't shown there, only kept in the log.
    /// Anything more (an errorMessage, a status) is shown, so the user can pass it on
    public static func saysOnlyRefused(_ said: String) -> Bool {
        let parts = said.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy { $0 == "authenticated: false" || $0 == "null" }
    }

    /// "field: value" for each text or true/false value, in field name order, going into lists and nested objects.
    /// Fields that may hold the account or a token are left out with everything in them
    static func describe(_ json: Any, hiding secrets: [String]) -> [String] {
        switch json {
        case let object as [String: Any]:
            return object.filter { key, _ in !hiddenFieldParts.contains(where: key.lowercased().contains) }
                .sorted { $0.key < $1.key }
                .flatMap { key, value -> [String] in
                    // Only the values: the field names are NJ Transit's own, and a short username would garble them
                    if let text = (value as? String) ?? (value as? Bool).map({ "\($0)" }) { return ["\(key): \(redacting(secrets, in: text))"] }
                    return describe(value, hiding: secrets)
                }
        case let list as [Any]:
            return list.flatMap { describe($0, hiding: secrets) }
        case let text as String:
            return [redacting(secrets, in: text)]
        default:
            return []
        }
    }

    /// How a web page may write this secret: with &, <, >, " and ' as character references (only when it has any of them)
    static func htmlEscaped(_ secret: String) -> [String] {
        guard secret.contains(where: { "&<>\"'".contains($0) }) else { return [] }
        let base = secret.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        guard secret.contains("'") else { return [base] }
        return ["&#39;", "&#x27;", "&apos;"].map { base.replacingOccurrences(of: "'", with: $0) }
    }

    /// Replaces each secret with "…" in any letter case, the longest first, so a password that contains the username isn't left partly shown
    static func redacting(_ secrets: [String], in text: String) -> String {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "…", options: .caseInsensitive)
        }
    }

    /// A POST to NJ Transit follows a redirect only on the same host and port over HTTPS: a 307 / 308 redirect to another server
    /// would send it the form too (the account, or the token). No port written is HTTPS's 443
    static func followsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target, let from = original.host?.lowercased(), let to = target.host?.lowercased() else { return false }
        return from == to && target.scheme?.lowercased() == "https" && (original.port ?? 443) == (target.port ?? 443)
    }

    /// Whether the download is GTFS-Realtime (protobuf): with a bad token the endpoint returns JSON or HTML text.
    /// GTFS-Realtime always starts with the header (field 1, byte 0x0A); text starts with "{", "<" or whitespace.
    public static func looksLikeProtobuf(_ data: Data) -> Bool {
        data.first == 0x0A
    }

    /// The rail live data, read for each of these operators whose times are live with the account (FerryFeed.Source.liveWithAccount):
    /// the trains. The light rail isn't in it, so none is made for the light rail.
    public static func realtime(from data: Data, fetchedAt: Date, sources: [FerryFeed.Source]) throws -> [FerryRealtime] {
        guard looksLikeProtobuf(data) else { throw LiveError.badResponse }
        let feed = try GTFSRealtimeFeed.decode(data)
        return sources.filter(\.liveWithAccount).map { FerryRealtime(feed: feed, fetchedAt: fetchedAt, source: $0) }
    }

    /// What a live download says about the account, for Settings: false when NJ Transit refused it, true when NJ Transit's own
    /// live data came, nil when it says nothing either way (NJ Transit wasn't asked, or nothing of its came: another operator's
    /// data in the same download isn't a sign that the account works).
    /// - Parameters:
    ///   - asked: the operators whose live data was asked for
    ///   - received: the operators whose live data came
    public static func accountEvidence(asked: [FerryFeed.Source], received: [FerryFeed.Source], rejected: Bool) -> Bool? {
        guard asked.contains(where: \.needsAccount) else { return nil }
        if rejected { return false }
        return received.contains(where: \.needsAccount) ? true : nil
    }

    /// How a sign-in to NJ Transit ended, for the app's log. NJ Transit allows only a few sign-ins a day, so each is written down
    public enum SignInResult: String, Sendable, Equatable {
        case accepted
        case refused
        case limitReached = "daily limit reached"
        /// An answer that's neither a token, a refusal nor the limit (an error status, a web page, a redirect)
        case notUnderstood = "answer not understood"
        /// No answer came (no network, a timeout)
        case noAnswer = "no answer"
        /// Nothing was sent: the network is turned off, or the server is being left alone after a rate limit
        case notSent = "not sent"
        /// The account was removed or replaced, or the refresh was stopped, while NJ Transit answered: the answer wasn't used
        case stopped = "stopped before the answer was used"

        init(_ error: Error) {
            switch error {
            case LiveError.rejected: self = .refused
            case LiveError.rateLimited: self = .limitReached
            case is LiveError, is FeedFetchError, is ErrorStatusAnswer: self = .notUnderstood
            default: self = NetworkReach.isCancellation(error) ? .stopped : .noAnswer
            }
        }
    }

    /// A line for the app's log each time the app signs in to NJ Transit: which API and how it ended ("NJ Transit sign-in (rail):
    /// accepted"). Never the account, the password or the token
    public static func signInLogLine(_ endpoints: Endpoints, _ result: SignInResult) -> String {
        "NJ Transit sign-in (\(endpoints.logName)): \(result.rawValue)"
    }

    /// multipart/form-data body.
    public static func formBody(_ fields: [(String, String)], boundary: String) -> Data {
        var body = ""
        for (name, value) in fields {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        body += "--\(boundary)--\r\n"
        return Data(body.utf8)
    }
}

/// Sends POST forms (replaced with a fake in tests).
public protocol FormPosting: Sendable {
    func post(_ url: URL, fields: [(String, String)]) async throws -> Data
}

public struct URLSessionFormPoster: FormPosting {
    public var timeout: TimeInterval
    /// false: rate limits and connection problems aren't recorded (RateLimit, NetworkReach). For NJ Transit's test systems
    /// (see Endpoints.recordsReach), whose problems aren't the real service's.
    public var recordsReach: Bool

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The form holds the account or a token: redirects to another server aren't followed
        return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    public init(timeout: TimeInterval = 20, recordsReach: Bool = true) {
        self.timeout = timeout
        self.recordsReach = recordsReach
    }

    public func post(_ url: URL, fields: [(String, String)]) async throws -> Data {
        // Live data asked for with the account's token: at most once a minute (see KeyedRequests). Signing in is never answered
        // again from memory: how often to renew the token is worked out from each real answer
        if let token = fields.first(where: { $0.0 == "token" })?.1 {
            try NetworkSwitch.check()
            try RateLimit.checkNotPaused(url)
            return try await KeyedRequests.answer(for: KeyedRequests.key(url, token)) { try await send(url, fields: fields) }
        }
        return try await send(url, fields: fields)
    }

    private func send(_ url: URL, fields: [(String, String)]) async throws -> Data {
        let boundary = "CatchMyTrain-" + UUID().uuidString
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = NJTransitLive.formBody(fields, boundary: boundary)
        try NetworkSwitch.check()
        try RateLimit.checkNotPaused(url)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.limitedData(for: request, limit: DownloadLimit.live)
        } catch FeedFetchError.tooLarge {
            if recordsReach { NetworkReach.recordBadData(url: url) }
            throw FeedFetchError.tooLarge
        } catch {
            noteFailure(error, url: url)
            throw error
        }
        try check(response, data: data, from: url)
        return data
    }

    /// The request got no answer: record a network problem (unless recordsReach is off)
    func noteFailure(_ error: Error, url: URL) {
        if recordsReach { NetworkReach.record(error: error, url: url) }
    }

    /// Records the answer (unless recordsReach is off) and turns statuses that carry no data into errors. Another error status
    /// whose body is NJ Transit's own explanation is handed on with it (ErrorStatusAnswer): its words decide what to do
    func check(_ response: URLResponse, data: Data = Data(), from url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if recordsReach {
            RateLimit.record(http, url: url)
            NetworkReach.record(status: http.statusCode, url: url)
        }
        // A redirect that wasn't followed (see SameHostRedirects): not NJ Transit's answer, and not a reason to sign in again
        if (300..<400).contains(http.statusCode) { throw NJTransitLive.LiveError.badResponse }
        // 401, 403: bad token or account; let the caller renew the token or show a notice
        if http.statusCode == 401 || http.statusCode == 403 { throw NJTransitLive.LiveError.rejected }
        guard !(200..<300).contains(http.statusCode) else { return }
        // Too many requests is a wait whatever the body says (see RateLimit)
        if http.statusCode != 429, NJTransitLive.isOwnAnswer(data) {
            throw NJTransitLive.ErrorStatusAnswer(status: http.statusCode, body: data)
        }
        throw FeedFetchError.httpStatus(http.statusCode)
    }
}

/// Refuses redirects to another server or away from HTTPS, so the account and the token only go to the NJ Transit host they were meant for
/// (and a key only to its own server: URLSessionFetcher uses it for downloads that carry one). The request then ends with the redirect
/// itself, which URLSessionFormPoster.check reports as an unreadable answer.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url ?? response.url
        completionHandler(NJTransitLive.followsRedirect(from: original, to: request.url) ? request : nil)
    }
}
