import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Checks for a new version (notify only, no automatic install).
///
/// Asks GitHub for the latest release (public API, no account or key, and no personal info sent); if it's newer than the current one, shows a notice,
/// and the user taps a button to open the download page and install it themselves. Automatic checks are off by default and, when on, run at most monthly; "Check Now" in Settings works anytime.
/// Only works once the repo is public and has a Release; otherwise GitHub returns 404 and the UI says no version has been released yet.
public enum UpdateCheck {
    /// Which repo a build checks (and downloads the source list from): the release repo
    public enum Channel: Sendable {
        /// The releases: CheeCar/Catch-My-Train, prereleases ignored
        case release

        public var repository: String {
            switch self {
            case .release: return "CheeCar/Catch-My-Train"
            }
        }
        /// Asks for the latest full release
        public var api: URL {
            switch self {
            case .release: return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            }
        }
        public var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    }

    public struct Release: Codable, Equatable, Sendable {
        /// Version number, e.g. "2.1.0" (leading v removed)
        public var version: String
        /// Download page for this version
        public var page: URL
        public init(version: String, page: URL) {
            self.version = version
            self.page = page
        }
    }

    public enum CheckError: Error, Equatable, Sendable {
        /// No version released yet (or the repo isn't public yet)
        case noRelease
        /// Couldn't understand the response
        case badResponse
    }

    private struct Body: Decodable {
        var tag_name: String
        var html_url: URL?
        var draft: Bool?
        var prerelease: Bool?
    }

    /// Reads GitHub's response for the channel: releases/latest, drafts and prereleases don't count.
    public static func parse(_ data: Data, channel: Channel = .release) throws -> Release {
        switch channel {
        case .release:
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw CheckError.badResponse }
            if body.draft == true || body.prerelease == true { throw CheckError.noRelease }
            return try release(body, channel: channel)
        }
    }

    private static func release(_ body: Body, channel: Channel) throws -> Release {
        let version = clean(body.tag_name)
        guard !numbers(version).isEmpty else { throw CheckError.badResponse }
        return Release(version: version, page: body.html_url.flatMap { isReleasePage($0, of: channel) ? $0 : nil } ?? channel.releasesPage)
    }

    /// Only a page of this channel's own repo on github.com is opened from the notice; anything else falls back to the releases page.
    static func isReleasePage(_ url: URL, of channel: Channel) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.path.lowercased().hasPrefix("/\(channel.repository.lowercased())/")
    }

    /// "v2.1.0" → "2.1.0"
    static func clean(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return s
    }

    /// "1.10.0" → [1, 10, 0]; anything trailing like "-rc.1" is ignored
    static func numbers(_ version: String) -> [Int] {
        var out: [Int] = []
        for part in clean(version).split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            guard let n = Int(digits) else { break }
            out.append(n)
            if digits.count < part.count { break }
        }
        return out
    }

    /// Is a newer than b (compared numerically segment by segment, missing segments count as 0: "2.0" == "2.0.0")
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// After an automatic check fails, wait this long before the next automatic one
    public static let retryAfterFailure: TimeInterval = 24 * 60 * 60

    /// Automatic check: once a month (like the schedules, check again once the next month comes).
    /// After a failed one (lastFailed), not again for a day: otherwise every refresh would ask GitHub again.
    public static func isDue(lastChecked: Date?, lastFailed: Date? = nil, now: Date = Date()) -> Bool {
        if let lastFailed, now.timeIntervalSince(lastFailed) < retryAfterFailure, now >= lastFailed { return false }
        guard let lastChecked else { return true }
        return SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now)
    }

    /// Downloads for the update check. They aren't transit data: GitHub's rate limit (403 / 429, common on shared networks)
    /// or a failed connection isn't recorded for the notices at the stations (the update check says so itself)
    static let fetcher = URLSessionFetcher(timeout: 20, accept: "application/vnd.github+json", recordsReach: false)

    /// Asks GitHub for the latest version on the channel (fetcher: nil for the usual one)
    public static func fetchLatest(channel: Channel = .release, fetcher: DataFetching? = nil) async throws -> Release {
        do {
            return try parse(try await (fetcher ?? Self.fetcher).fetch(channel.api), channel: channel)
        } catch FeedFetchError.httpStatus(404) {
            throw CheckError.noRelease
        }
    }
}
