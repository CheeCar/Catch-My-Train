import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MTA subway realtime data comes in several groups (one URL each). Free, no API key needed.
/// URL format: see the MTA developer page: https://www.mta.info/developers
public enum MTAFeed: String, CaseIterable, Codable, Hashable, Sendable {
    case numbered = "nyct%2Fgtfs"        // 1 2 3 4 5 6 7 and the 42 St Shuttle S
    case ace = "nyct%2Fgtfs-ace"          // A C E, Rockaway Shuttle H, Franklin Shuttle FS
    case bdfm = "nyct%2Fgtfs-bdfm"        // B D F M
    case g = "nyct%2Fgtfs-g"
    case jz = "nyct%2Fgtfs-jz"
    case nqrw = "nyct%2Fgtfs-nqrw"
    case l = "nyct%2Fgtfs-l"
    case sir = "nyct%2Fgtfs-si"           // Staten Island Railway

    public static let baseURL = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/"

    /// The address: the source list's, or the one in code
    public var url: URL { SourceList.realtimeURL(for: listID) ?? builtInURL }

    /// The address in code
    public var builtInURL: URL { URL(string: Self.baseURL + rawValue)! }

    /// Its ID in the source list, e.g. "mta-subway-ace"
    var listID: String { "mta-subway-" + displayName.lowercased() }

    /// Which data group a route belongs to.
    public static func feed(forRoute route: String) -> MTAFeed? {
        switch MTARoute.normalize(route) {
        case "1", "2", "3", "4", "5", "6", "7", "GS": return .numbered
        case "A", "C", "E", "H", "FS": return .ace
        case "B", "D", "F", "M": return .bdfm
        case "G": return .g
        case "J", "Z": return .jz
        case "N", "Q", "R", "W": return .nqrw
        case "L": return .l
        case "SI": return .sir
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .numbered: return "1-7"
        case .ace: return "ACE"
        case .bdfm: return "BDFM"
        case .g: return "G"
        case .jz: return "JZ"
        case .nqrw: return "NQRW"
        case .l: return "L"
        case .sir: return "SIR"
        }
    }
}

/// Converts GTFS-Realtime data into the `Arrival` used by the decision module.
public enum GTFSRealtimeMapper {

    /// - Parameters:
    ///   - stationIDs: keep only trips at these stations (parent station IDs, e.g. "635").
    ///   - direction: builds the direction name from (station, route, N/S).
    ///   - fallbackUpdatedAt: the "updated at" time used when the data has no timestamp (usually the download time).
    public static func arrivals(
        from feed: GTFSRealtimeFeed,
        stationIDs: Set<String>,
        fallbackUpdatedAt: Date,
        direction: (_ stationID: String, _ route: String, _ code: String) -> Direction
    ) -> [Arrival] {
        arrivals(from: feed, stationIDs: stationIDs, fallbackUpdatedAt: fallbackUpdatedAt) { id, route, code, _ in
            direction(id, route, code)
        }
    }

    /// Same as above, and also passes this trip's last stop (parent station ID) to `direction`,
    /// so branches and short turns can show their real terminal (e.g. whether an A train goes to Lefferts Blvd or Far Rockaway).
    /// - Parameter terminatesHere: when given, trips that end at a station are left out there (the train goes no further, so it can't be ridden).
    ///   Each trip's own stops decide: a trip listing stops after this station goes on, one whose listed stops end here doesn't
    ///   (the feed lists only the stops still ahead, so a train on its last leg lists just its terminal).
    ///   Only a trip whose last stop can't be read is decided by this function (see StationCatalog.terminates).
    public static func arrivals(
        from feed: GTFSRealtimeFeed,
        stationIDs: Set<String>,
        fallbackUpdatedAt: Date,
        express: ExpressStops? = nil,
        terminatesHere: ((_ stationID: String, _ route: String, _ code: String) -> Bool)? = nil,
        direction: (_ stationID: String, _ route: String, _ code: String, _ lastStationID: String?) -> Direction
    ) -> [Arrival] {
        var result: [Arrival] = []
        for trip in feed.tripUpdates {
            let route = MTARoute.normalize(trip.routeID)
            guard !route.isEmpty else { continue }
            // Prefer the trip's own timestamp, then the timestamp of the whole feed.
            let updatedAt = trip.timestamp ?? feed.timestamp ?? fallbackUpdatedAt
            let lastStation = trip.stopTimeUpdates.last.flatMap { splitStopID($0.stopID)?.0 }
            for (index, stu) in trip.stopTimeUpdates.enumerated() {
                guard let (stationID, code) = splitStopID(stu.stopID), stationIDs.contains(stationID) else { continue }
                if let terminatesHere, ends(at: stationID, lastStation: lastStation,
                                            orElse: { terminatesHere(stationID, route, code) }) { continue }
                // The stops this trip will actually make next, used to tell express from local
                let next = trip.stopTimeUpdates[(index + 1)...]
                    .lazy.filter { !$0.isSkipped }
                    .compactMap { splitStopID($0.stopID)?.0 }
                    .prefix(ExpressStops.lookAhead)
                // The trip's one time here is its arrival (its departure only when the data gives no arrival). A later departure
                // isn't used: the data can say a train stops for minutes where it doesn't, and you'd be told to leave too late
                let time: Date? = stu.hasNoData ? nil : (stu.arrivalTime ?? stu.departureTime)
                let status: TripStatus = (trip.isCanceled || stu.isSkipped) ? .cancelled : .normal
                // The same trip ID can also be another day's train (e.g. one still running after midnight): the start date tells them apart
                let tripKey = (trip.tripID.isEmpty ? trip.entityID : trip.tripID) + (trip.startDate.isEmpty ? "" : "@\(trip.startDate)")
                result.append(Arrival(
                    id: "\(tripKey)|\(stu.stopID)",
                    stationID: stationID,
                    route: route,
                    direction: direction(stationID, route, code, lastStation),
                    arrivalTime: time,
                    source: .realtime,
                    status: status,
                    updatedAt: updatedAt,
                    isExpress: express?.isExpress(rawRoute: trip.routeID, stationID: stationID, code: code,
                                                  nextStations: Array(next)),
                    isAssigned: trip.isAssigned
                ))
            }
        }
        return result
    }

    /// Whether a trip whose last listed stop is `lastStation` ends at the station; `orElse` decides only when that stop can't be read
    static func ends(at stationID: String, lastStation: String?, orElse: () -> Bool) -> Bool {
        guard let lastStation else { return orElse() }
        return lastStation == stationID
    }

    /// "635N" → ("635", "N"). Returns nil for platform IDs not ending in N/S.
    public static func splitStopID(_ stopID: String) -> (String, String)? {
        guard let last = stopID.last, last == "N" || last == "S", stopID.count > 1 else { return nil }
        return (String(stopID.dropLast()), String(last))
    }
}

/// Download result for each data group.
public struct FeedStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Success; feedTimestamp is when the data itself was generated
        case ok(feedTimestamp: Date?)
        /// Failure (network error, server error, or unparsable data)
        case failed(message: String)
    }

    public var feed: MTAFeed
    public var state: State
    public var fetchedAt: Date

    public var isOK: Bool { if case .ok = state { return true } else { return false } }

    /// Data update time: the oldest timestamp among the successfully downloaded groups (download time if no timestamp). nil if all failed.
    /// Used by both the main window's "Data updated" and the widget's "Updated", so both show the same time.
    public static func dataTime(_ statuses: [FeedStatus]) -> Date? {
        statuses.compactMap { s -> Date? in
            if case let .ok(ts) = s.state { return ts ?? s.fetchedAt }
            return nil
        }.min()
    }
}

/// Result of one realtime data refresh.
public struct RealtimeLoad: Sendable {
    public var arrivals: [Arrival]
    public var statuses: [FeedStatus]
    /// All needed data groups failed to download
    public var allFailed: Bool { !statuses.isEmpty && statuses.allSatisfy { !$0.isOK } }
    public var failedFeeds: [MTAFeed] { statuses.filter { !$0.isOK }.map(\.feed) }

    /// Trips on partial failure: successful groups switch to new data, failed groups keep the last trips (which expire naturally over time).
    /// Shared by the main app and the widget.
    /// - Parameter old: the last MTA subway trips (excluding PATH, light rail and the tram)
    public func merged(keeping old: [Arrival]) -> [Arrival] {
        let failed = Set(failedFeeds)
        guard !failed.isEmpty else { return arrivals }
        return arrivals + old.filter { MTAFeed.feed(forRoute: $0.route).map(failed.contains) ?? false }
    }
}

/// Downloads the realtime data needed for nearby stations and converts it into `Arrival`.
public struct MTARealtimeLoader: Sendable {
    public var fetcher: DataFetching
    public var catalog: StationCatalog
    /// Data for express/local decisions (bundled with the app, or regenerated after the monthly check, see StaticData)
    public var express: ExpressStops?

    /// - Parameter express: express data matching catalog (the app reads one copy and keeps using it; if omitted, reads the one in use)
    public init(catalog: StationCatalog, fetcher: DataFetching = URLSessionFetcher(),
                express: ExpressStops? = try? ExpressStops.loadCurrent()) {
        self.catalog = catalog
        self.fetcher = fetcher
        self.express = express
    }

    /// One data group's answer and when it came
    private struct FeedAnswer: Sendable {
        var result: Result<GTFSRealtimeFeed, Error>
        var fetchedAt: Date
    }

    /// Data groups to download (only those used by nearby stations, to save bandwidth).
    public func feeds(forStations ids: [String]) -> [MTAFeed] {
        let feeds = Set(catalog.routes(atStations: ids).compactMap(MTAFeed.feed(forRoute:)))
        return MTAFeed.allCases.filter(feeds.contains)
    }

    public func load(stationIDs: [String], now: @escaping @Sendable () -> Date = { Date() }) async -> RealtimeLoad {
        let wanted = Set(stationIDs)
        let feeds = feeds(forStations: stationIDs)
        let catalog = self.catalog
        let fetcher = self.fetcher
        let express = self.express

        // Every data group at once, each answer kept under its own group (see Together)
        let results = await Together.each(feeds) { feed -> FeedAnswer in
            do {
                let data = try await fetcher.fetch(feed.url)
                return FeedAnswer(result: .success(try GTFSRealtimeFeed.decode(data, from: feed.url)), fetchedAt: now())
            } catch {
                return FeedAnswer(result: .failure(error), fetchedAt: now())
            }
        }

        var arrivals: [Arrival] = []
        var statuses: [FeedStatus] = []
        for feed in feeds.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let answer = results[feed] else { continue }
            let fetchedAt = answer.fetchedAt
            switch answer.result {
            case .success(let parsed):
                // Trips terminating at this station can't be ridden (the train goes no further); don't show them.
                // Each trip's own last stop decides, so trains that go on past a station where most of them end still show.
                arrivals += GTFSRealtimeMapper.arrivals(
                    from: parsed, stationIDs: wanted, fallbackUpdatedAt: fetchedAt,
                    express: express,
                    terminatesHere: { catalog.terminates(stationID: $0, route: $1, code: $2) },
                    direction: { catalog.direction(stationID: $0, route: $1, code: $2, lastStationID: $3) })
                statuses.append(FeedStatus(feed: feed, state: .ok(feedTimestamp: parsed.timestamp), fetchedAt: fetchedAt))
            case .failure(let error):
                statuses.append(FeedStatus(feed: feed, state: .failed(message: String(describing: error)), fetchedAt: fetchedAt))
            }
        }
        return RealtimeLoad(arrivals: arrivals, statuses: statuses)
    }
}
