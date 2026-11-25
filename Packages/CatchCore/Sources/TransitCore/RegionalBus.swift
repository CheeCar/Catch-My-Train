import Foundation

// MARK: - Regional buses (NJ Transit and operators on Long Island, in the Hudson Valley, Connecticut, around Philadelphia and in the Lehigh Valley)
//
// Covers all public transit in the NYC metro area (e.g. Long Island buses). Every agency publishes its timetable (free, no login)
// in the same format as NJ Transit (GTFS), so each one is stored in a compact file with NJBusIndex; at use time the nearby piece of each is taken and merged,
// all counted as Bus (shown together with MTA buses). Some also have live data (realtime / keyedRealtime below; NJ Transit's comes through NJTransitLive).
// The data URLs were tested on a Mac and all download directly.
//
// IDs all live under FerryFeed.Source.njTransitBus ("njb"), with a code per agency so route numbers don't collide (several have a route "1"):
// NJ Transit has none (route "NJB-107", stop "njb:12345"); others are route "NJB-NICE/n6", stop "njb:NICE/123".

public struct RegionalBusFeed: Sendable, Hashable, Identifiable {
    /// Code (empty for NJ Transit)
    public let code: String
    /// Agency name, e.g. "NICE", "Suffolk County Transit"
    public let name: String
    /// Its timetable's address in code (see url)
    public let builtInURL: URL
    /// Color for route badges and the map (each agency's main color)
    public let color: String
    /// Lines with a color of their own, by the badge's name, where the lines are known by their colors (NECTD's "Green" and
    /// "Orange", from its data's route_color). A line not listed (a new one), or one whose routes have different colors in the
    /// data (WRTD's 674D and 674E, a few trips at the start and end of a term), has the agency's color. Empty: none
    public let lineColors: [String: String]
    /// For a package several companies share (Coach USA's, with ten across the country): the one company this is, by its
    /// agency_id, or by its agency_name when no company of the package has that id (the id changed). Only its routes are read,
    /// and only the stops they stop at are kept, so its file and its bounds are its own. Nil: the whole package
    public let agency: Agency?
    /// Keep only stops within the service area: CTtransit's data covers all of Connecticut. All of the state is in the area,
    /// so this only leaves out stops its data may have beyond it
    public let onlyServiceArea: Bool
    /// The data's headsigns name the route, not where each trip goes (Norwalk's "Route 3" and "Coastal Link"; River Valley's
    /// "Washington Street" both ways), so each trip's terminal is shown instead
    public let headsignsNameRoutes: Bool
    /// Words its routes' names start with that the badge leaves out (PHLASH's long names, as it has no short ones: "PHLASH Downtown
    /// Loop" is "Downtown Loop"; MWRTA's short names: "RT206" is "206", its "Route 206"); nil: none
    public let routeNamePrefix: String?
    /// Its data has no short route names and a route per trip, named "first place-last place" and the direction (Trans-Bridge's
    /// "Allentown-Clinton Eastbound"): routes with the same first place are one route, its badge that place ("Allentown")
    public let routesByFirstPlace: Bool
    /// Its data's short route names are the company's name (Coach USA's: "ShortLine Hudson" on every route, the number in the
    /// long name, "300 - NYC - Middletown"): they're left out, and the badges come from the long names
    public let shortNamesNameCompany: Bool
    /// Its data gives every trip the same direction_id (Hunterdon County LINK's 1), which can't tell the two ways apart: each
    /// trip's direction is worked out from where it goes, as for data without one
    public let directionsFromStops: Bool
    /// Routes whose route_desc is one of these get that badge instead of their own name, all as one route (the MBTA's shuttle buses
    /// that run in place of trains or the subway for a few days, "Rail Replacement Bus", each named after its line: "Shuttle");
    /// empty: none
    public let badgesByDescription: [String: String]
    /// Badges by routes' long names, for routes without short names whose long names don't start with a route number and whose
    /// first words aren't one per route (Cape Cod's "Hyannis Area Trolley" and "Hyannis Crosstown": "Trolley", "Crosstown"), or
    /// with a short name that is a whole name (MeVa's "Amesbury Town Park", its "30 Amesbury Town Park": "30"). A route the operator
    /// renames gets its own name back as its badge, so it still shows. A route with no long name goes by its short name (NECTD's
    /// "Red-Purple Shuttle": "Red-Purple"); empty: none
    public let badgesByLongName: [String: String]
    /// Badges by how routes' long names start, for routes without short names whose long names end with something that changes,
    /// like the term (WRTD's campus routes: "Purple A Fall 2026", "Yellow Line A Counter Clockwise Fall 2026": "Purple A",
    /// "Yellow A"). A long name matches a start it equals or that is followed by a space; the longest start that matches counts.
    /// Empty: none
    public let badgesByLongNameStart: [String: String]
    /// Routes left out, by the badge's name: one that two companies' data both have (the Link413's 904, in PVTA's and in BRTA's:
    /// BRTA's is kept, so it shows wherever BRTA's data is downloaded, Pittsfield too). Empty: none
    public let leftOutRoutes: Set<String>
    /// Free, keyless realtime data (GTFS-Realtime trip updates) in code; nil when there is none (see realtimeURL)
    public let builtInRealtimeURL: URL?
    /// Realtime data that needs the user's own key to download (Suffolk County Transit's Swiftly API, key in the Authorization header)
    public let keyedRealtimeURL: URL?
    /// Its live data names trips by their block and the time they leave their first stop, not by the timetable's trip_id (PVTA's
    /// InfoPoint server): its trips are stored under those two numbers, so the two match (see BlockTripID)
    public let tripsByBlock: Bool
    /// Its live data names its trips in ways its timetable doesn't (FRTA's mixes the numbers of two other copies of its timetable)
    /// and its stops mostly as the timetable does: a live trip whose trip_id isn't one of its stored trips goes to the one stored
    /// trip its stops and times fit (see matchedByStopsAndTime). Its whole timetable is kept with the nearby piece for that
    /// (WholeTimetable)
    public let liveByStopsAndTime: Bool
    /// Its live data names its trips by another copy of its timetable's numbers and its stops by their codes (the number on the
    /// stop's sign, GTFS stop_code), and gives each stop's predicted time with its delay, so also the time its own timetable has
    /// there: a live trip goes to the one stored trip with those stops at those times (see matchedByStopCodes). Each trip's whole
    /// list of stop codes is kept with the nearby piece for that (StopCodeLists). NJ Transit's buses
    public let liveByStopCodes: Bool
    /// Where its data is of use, for one that's downloaded only for places there (see DownloadArea); nil: downloaded for everyone
    public let downloadArea: DownloadArea?
    /// How this version turns this company's downloaded package into stored data. Raise it when an update changes what is kept from
    /// a package the app already downloads: a stored copy read with a lower number is downloaded and read again once, the first
    /// time it's used online (see outdated(stored:readWith:)); until then the old copy is used. 0: never changed.
    /// CTtransit, 1: Greater Hartford's boxes (its stops are cut to the service area, so Hartford's and New Britain's are kept now).
    /// PVTA, 1: its trips stored by block (tripsByBlock) and its 904 left out. FRTA, 1: Passio's timetable; 2: Trillium's again,
    /// whose stops its live data names (liveByStopsAndTime). WRTD, 1: badges for the campus routes without short names
    /// (badgesByLongNameStart). NJ Transit, 1: its stops' codes, which its live data names stops by (liveByStopCodes).
    /// NECTD and NWCTD, 1: each line's own color on the map (lineColors). WRTD, 2: the same.
    public let readingVersion: Int
    /// Realtime data needs the user's own developer account (NJ Transit, see NJTransitLive)
    public var needsAccount: Bool { code.isEmpty }
    /// Whether its times are live once the account is entered: only where NJ Transit's live data was checked, on real data, to
    /// match this timetable's trips (see FerryFeed.Source.liveWithAccount, the same fact for its trains and light rail). Its
    /// buses: yes. Their live data names trips and stops as another copy of the timetable does, so they're matched by stop codes
    /// and schedule (liveByStopCodes); a live trip that fits no stored trip, or more than one, leaves the timetable's times
    public var liveWithAccount: Bool { needsAccount && liveByStopCodes }
    /// Realtime data needs the user's own key (Suffolk, see keyedRealtimeURL)
    public var needsKey: Bool { keyedRealtimeURL != nil }
    /// Whether there is realtime data (free, or after entering an account or key)
    public var hasRealtime: Bool { builtInRealtimeURL != nil || needsAccount || needsKey }

    /// Whether its data is downloaded now: one of its metro areas is kept, and for one with a DownloadArea, a place in use is inside
    /// it (see PlacesInUse). One that isn't keeps what it downloaded before, without updates, until it's wanted again or its areas'
    /// data is removed (see AreaData)
    public var isWanted: Bool { PlacesInUse.wants(areas: MetroArea.areas(ofBus: self), box: downloadArea) }

    /// Whether realtime data can be downloaded now: free ones always can; ones needing an account or key only after the user enters it,
    /// and with an account only where that gives live times (liveWithAccount)
    public func canGetRealtime(hasAccount: Bool, hasSuffolkKey: Bool) -> Bool {
        builtInRealtimeURL != nil || (liveWithAccount && hasAccount) || (needsKey && hasSuffolkKey)
    }

    /// Whether its times can be live at all: free live data, or with a key, or with the account where that gives live times.
    /// One that can't is a timetable company in the sidebar's popover and the footer, whatever keys the user has
    public var canBeLive: Bool { builtInRealtimeURL != nil || needsKey || liveWithAccount }

    public var id: String { code }

    /// One company of a package several share: its agency_id and its agency_name there
    public struct Agency: Sendable, Hashable {
        public let id: String
        public let name: String
    }

    /// Its ID in the source list: NJ Transit's is its timetable operator's ("njb"), the others' "bus-" and the code
    public var listID: String { code.isEmpty ? FerryFeed.Source.njTransitBus.rawValue : "bus-" + code.lowercased() }

    /// Its timetable's address: the source list's, or the one in code
    public var url: URL { SourceList.timetableURL(for: listID) ?? builtInURL }

    /// Its free live data's address: the source list's, or the one in code (nil when it has none)
    public var realtimeURL: URL? { builtInRealtimeURL.map { SourceList.realtimeURL(for: listID) ?? $0 } }

    init(code: String, name: String, url: String, color: String, lineColors: [String: String] = [:], agency: Agency? = nil,
         onlyServiceArea: Bool = false, headsignsNameRoutes: Bool = false,
         routeNamePrefix: String? = nil, routesByFirstPlace: Bool = false, shortNamesNameCompany: Bool = false,
         directionsFromStops: Bool = false, badgesByDescription: [String: String] = [:],
         badgesByLongName: [String: String] = [:], badgesByLongNameStart: [String: String] = [:], leftOutRoutes: Set<String> = [],
         realtime: String? = nil, keyedRealtime: String? = nil, tripsByBlock: Bool = false, liveByStopsAndTime: Bool = false,
         liveByStopCodes: Bool = false, downloadArea: DownloadArea? = nil, readingVersion: Int = 0) {
        self.code = code
        self.name = name
        self.builtInURL = URL(string: url)!
        self.color = color
        self.lineColors = lineColors
        self.agency = agency
        self.onlyServiceArea = onlyServiceArea
        self.headsignsNameRoutes = headsignsNameRoutes
        self.routeNamePrefix = routeNamePrefix
        self.routesByFirstPlace = routesByFirstPlace
        self.shortNamesNameCompany = shortNamesNameCompany
        self.directionsFromStops = directionsFromStops
        self.badgesByDescription = badgesByDescription
        self.badgesByLongName = badgesByLongName
        self.badgesByLongNameStart = badgesByLongNameStart
        self.leftOutRoutes = leftOutRoutes
        self.builtInRealtimeURL = realtime.flatMap(URL.init(string:))
        self.keyedRealtimeURL = keyedRealtime.flatMap(URL.init(string:))
        self.tripsByBlock = tripsByBlock
        self.liveByStopsAndTime = liveByStopsAndTime
        self.liveByStopCodes = liveByStopCodes
        self.downloadArea = downloadArea
        self.readingVersion = readingVersion
    }

    /// The badge for a route's long name by how it starts (see badgesByLongNameStart); nil when no start matches
    func badge(longNameStart name: String) -> String? {
        badgesByLongNameStart.filter { name == $0.key || name.hasPrefix($0.key + " ") }.max { $0.key.count < $1.key.count }?.value
    }

    /// The companies among `stored` (the codes with a stored copy) whose copy was read with an older way than this version's:
    /// `readWith` is each one's mark from its last good download (none counts as 0, as for copies stored before marks were kept)
    public static func outdated(stored: Set<String>, readWith: [String: Int], feeds: [RegionalBusFeed] = all) -> Set<String> {
        Set(feeds.filter { stored.contains($0.code) && (readWith[$0.code] ?? 0) < $0.readingVersion }.map(\.code))
    }

    /// The marks to keep after these companies downloaded fine: each one's readingVersion. 0 isn't written, so nothing is kept
    /// for companies whose reading never changed
    public static func marking(_ readWith: [String: Int], read codes: Set<String>, feeds: [RegionalBusFeed] = all) -> [String: Int] {
        var marks = readWith
        for feed in feeds where codes.contains(feed.code) && feed.readingVersion > 0 { marks[feed.code] = feed.readingVersion }
        return marks
    }

    public static let njTransit = RegionalBusFeed(code: "", name: "NJ Transit", url: NJBusIndex.builtInURL.absoluteString,
                                                  color: NJBusIndex.color, liveByStopCodes: true, readingVersion: 1)

    /// All agencies (display order), less the ones the source list turned off (see SourceList)
    public static var all: [RegionalBusFeed] { SourceList.current.buses }

    /// The order a check downloads companies in: as listed, but a company whose package is at the address of an earlier one's
    /// comes right after it (Coach USA's six), so one download serves them all
    public static func downloadOrder(_ feeds: [RegionalBusFeed]) -> [RegionalBusFeed] {
        var order: [RegionalBusFeed] = []
        var placed = Set<String>()
        for feed in feeds where !placed.contains(feed.code) {
            for same in feeds where same.url == feed.url && placed.insert(same.code).inserted { order.append(same) }
        }
        return order
    }

    /// The name the notices of Passio's live data server go by: one server (passio3.com) for the live data of several operators
    /// (Cecil Transit, BAT, COAST, FRTA and WRTD), so a notice from it is about all of them (NoticeScope.parts); where it shows,
    /// it names only the ones that concern what's shown (NoticeScope.naming)
    public static let passioProvider = passioFeeds.map(\.name).joined(separator: " / ")
    /// The operators whose live data comes from Passio's server
    static var passioFeeds: [RegionalBusFeed] { builtIn.filter { $0.builtInRealtimeURL?.host == "passio3.com" } }

    /// Where Trillium, which publishes many small operators' timetables, keeps them
    static let trillium = "https://data.trilliumtransit.com/gtfs/"

    /// Where NJ Transit's website keeps the county shuttles' timetables (njtransit.com's own links lead here)
    static let njTransitSite = "https://content.njtransit.com/sites/default/files/developers-resources/"

    /// Coach USA's package: ten companies' timetables, six of them around New York (see agency)
    static let coachUSA = "https://api.prod.coachusa.com/gtfs"

    /// SEPTA's code: its buses share a package and a live data server with its Metro, and the server with its trains too
    public static let septaCode = "SEPTA"
    /// The MBTA's code: its buses share a package and a live data file with its subway, trains and ferries
    public static let mbtaCode = "MBTA"

    public static func feed(code: String) -> RegionalBusFeed? { all.first { $0.code == code } }

    /// A package a bus company shares with a timetable operator outside the buses (SEPTA's buses and Metro; the MBTA's buses, subway,
    /// trains and ferries): the app downloads it once for all of them. An address moved by the source list counts as its new one. NJ Transit's buses are in both operator lists, but only
    /// the buses read their package
    public static func isSharedPackage(_ url: URL) -> Bool {
        all.contains { $0.url == url }
            && FerryFeed.Source.allCases.contains { $0.system != .njBus && !$0.isTurnedOff && $0.url == url }
    }

    /// Which agency a stop (trip) ID belongs to ("njb:CTT/123" → CTtransit, "njb:123" → NJ Transit)
    public static func of(id: String) -> RegionalBusFeed? {
        let prefix = FerryFeed.Source.njTransitBus.rawValue + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return njTransit }
        return feed(code: String(rest[..<slash]))
    }

    /// Agencies with realtime data among these nearby stops (IDs). NJ Transit counts only after the user enters an account and where
    /// that gives live times (liveWithAccount), Suffolk only after a key.
    public static func realtimeFeeds(stationIDs: [String], hasAccount: Bool, hasSuffolkKey: Bool = false) -> [RegionalBusFeed] {
        var codes = Set<String>()
        for id in stationIDs { if let f = of(id: id) { codes.insert(f.code) } }
        return all.filter { codes.contains($0.code) && $0.canGetRealtime(hasAccount: hasAccount, hasSuffolkKey: hasSuffolkKey) }
    }

    /// The companies whose live data counts as not downloaded after a refresh of the bus stops nearby (codes): those asked this
    /// time (`asked`) whose download failed (`failed`). A company not asked has no stop near the place in use, so a failure kept
    /// from a place left behind would mark it "Timetable" in Settings and the mode's header with nothing to say why, until the
    /// user went back there. A company that is never live never counts, whatever an earlier refresh saved.
    public static func failedAfterRefresh(asked: Set<String>, failed: Set<String>) -> Set<String> {
        failed.intersection(asked).subtracting(all.filter { !$0.canBeLive }.map(\.code))
    }

    /// File name stored on this Mac (NJ Transit is still the old njbus.bin)
    public var fileName: String { code.isEmpty ? "njbus.bin" : "bus-\(code.lowercased()).bin" }

    /// Prefix for stop, trip and calendar IDs: "njb:" (NJ Transit) or "njb:NICE/"
    public var idPrefix: String { FerryFeed.Source.njTransitBus.rawValue + ":" + (code.isEmpty ? "" : code + "/") }
    /// Prefix for route IDs: "NJB-" (NJ Transit) or "NJB-NICE/"
    var routePrefix: String { FerryFeed.Source.njTransitBus.routePrefix + (code.isEmpty ? "" : code + "/") }

    /// Which agency a route belongs to ("NJB-NICE/n6" → NICE, "NJB-107" → NJ Transit)
    public static func of(route: String) -> RegionalBusFeed? {
        let prefix = FerryFeed.Source.njTransitBus.routePrefix
        guard route.hasPrefix(prefix) else { return nil }
        let rest = route.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return njTransit }
        return feed(code: String(rest[..<slash]))
    }

    /// Text on the route badge: "NJB-NICE/n6" → "n6", "NJB-107" → "107"
    public static func badge(_ route: String) -> String {
        let rest = route.dropFirst(FerryFeed.Source.njTransitBus.routePrefix.count)
        if let slash = rest.firstIndex(of: "/") { return String(rest[rest.index(after: slash)...]) }
        return String(rest)
    }

    /// The color of the line with this badge: its own where it has one (lineColors), else the agency's
    public func color(badge: String) -> String { lineColors[badge] ?? color }

    /// Route badge color: the line's own where it has one, else its agency's main color
    public static func color(route: String) -> String { of(route: route)?.color(badge: badge(route)) ?? NJBusIndex.color }

    /// Whether the badge's text is dark. White on every agency's main color (each was chosen for white text to read on it); on a
    /// line's own color, which is the operator's choice, whichever of black and white reads better (always 4.5:1 or more)
    public static func darkText(route: String) -> Bool {
        guard let hex = of(route: route)?.lineColors[badge(route)], let color = UInt32(hex, radix: 16) else { return false }
        return ColorVision.contrast(color, 0x000000) > ColorVision.contrast(color, 0xFFFFFF)
    }
}

/// Trip IDs for live data that names trips by their block and the time they leave their first stop (PVTA's InfoPoint server, see
/// RegionalBusFeed.tripsByBlock): "t735-b5F-sl5" is block 95's trip leaving its first stop at 18:45, both numbers in hexadecimal.
/// The timetable's trips are stored as "b95-t1845@" and their service ID: the block and the time are the key both sides share, the
/// service keeps apart trips of different days. A time after midnight counts from it on both sides (GTFS's 24:30 is 0:30)
public enum BlockTripID {
    /// A stored trip's ID, from its block, the time it leaves its first stop (seconds after midnight of its service day) and its
    /// service ID; nil when the block isn't a number (the trip keeps the timetable's trip_id)
    public static func stored(block: String, firstDeparture seconds: Int, service: String) -> String? {
        guard let number = Int(block), number >= 0, seconds >= 0 else { return nil }
        return key(block: number, time: seconds / 3600 * 100 + seconds % 3600 / 60) + "@" + service
    }

    /// The key of a live trip ID ("t735-b5F-sl5" → "b95-t1845"); nil when it isn't named this way
    public static func key(live id: String) -> String? {
        var block: Int?
        var time: Int?
        for part in id.split(separator: "-") where part.count > 1 {
            let value = Int(part.dropFirst(), radix: 16)
            switch part.first {
            case "b": block = value
            case "t": time = value
            default: break
            }
        }
        guard let block, let time, block >= 0, time >= 0 else { return nil }
        return key(block: block, time: time)
    }

    /// The key of a stored trip ID ("b95-t1845@WKDY" → "b95-t1845"); nil when it isn't one of these
    public static func key(stored id: String) -> String? {
        guard let at = id.firstIndex(of: "@") else { return nil }
        let parts = id[..<at].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].first == "b", parts[1].first == "t",
              let block = Int(parts[0].dropFirst()), let time = Int(parts[1].dropFirst()) else { return nil }
        return key(block: block, time: time)
    }

    /// "b95-t1845": the block and the time as hours and minutes (after midnight from 0)
    static func key(block: Int, time: Int) -> String { "b\(block)-t\(time % 2400)" }
}

/// Each trip's whole list of stop codes, kept with a nearby piece for a bus company whose live data names stops by their codes
/// (see RegionalBusFeed.liveByStopCodes). A nearby piece's trips keep only their stops near here and their last; trips with
/// the same stops in the same order share one list
public struct StopCodeLists: Codable, Sendable, Equatable {
    /// Each list: the code of every stop of a trip, in order ("" for a stop without one)
    public var lists: [[String]] = []
    /// For each list, the places in it of the stops its trips keep in the nearby piece, in the order of those trips' stops
    public var kept: [[Int]] = []
    /// Each trip's list: its place in lists, by the trip's prefixed ID
    public var listOfTrip: [String: Int] = [:]

    public init() {}
}

/// A bus company's whole timetable, kept with its nearby piece when its live trips go by stops and time (see
/// RegionalBusFeed.liveByStopsAndTime): every trip with every stop, and their services
public struct WholeTimetable: Codable, Sendable, Equatable {
    public var trips: [FerryFeed.Trip]
    public var services: [String: FerryFeed.Service]
    /// For each stop (prefixed ID), the stops trips stop at within RegionalBusFeed.sameStopDistance of it, other than itself;
    /// only those with any
    public var nearbyStops: [String: [String]] = [:]
}

/// Why a live trip wasn't matched to a stored one by stops and time (see RegionalBusFeed.matchedByStopsAndTime), as the app's
/// log says it
public enum LiveMatchFailure: String, Sendable, CaseIterable {
    case fewStops = "fewer than 2 stops"
    case noTrip = "no trip stops at all of them"
    case timesOff = "times off"
    case bunched = "predictions bunched"
    case twoFit = "two trips fit"
    case closeToAnother = "another trip close"
    case sameTrip = "same trip twice"
}

/// How a bus company's live trips matched its timetable this time, for the app's log (see RegionalBusFeed.realtime)
public struct LiveMatching: Sendable, Equatable {
    /// Trips in its live data
    public var total = 0
    /// Its live trips go by stops and time where their trip_id isn't a stored one (RegionalBusFeed.liveByStopsAndTime)
    public var byStopsAndTimeOn = false
    /// Live trips naming a stop near here where one can board its buses, and of them those named by a nearby trip's ID (by block
    /// and first departure for PVTA)
    public var nearby = 0
    public var nearbyByID = 0
    /// By stops and time only: live trips named by a stored trip's own ID, those matched by stops and time, the matched ones near
    /// here, the matched ones with one of their stops left out, and why the others weren't
    public var byID = 0
    public var byStopsAndTime = 0
    public var nearbyByStopsAndTime = 0
    /// Of the matched ones near here, those still to stop here: a predicted time at a stop near here, now or later (the others
    /// have gone by, so none of the board's rows can show them as live)
    public var nearbyStillToStop = 0
    public var leavingOneOut = 0
    public var unmatched: [LiveMatchFailure: Int] = [:]
    /// Its live trips go by stop codes and schedule (RegionalBusFeed.liveByStopCodes): nearby counts those with a time at a
    /// stop near here where one can board, byStopCodes those matched to a nearby stored trip, nearbyStillToStop the matched
    /// ones still to stop at such a stop, unmatched why the others near here weren't
    public var byStopCodesOn = false
    public var byStopCodes = 0

    /// Its line in the app's log (company names and counts only): for a company whose live trips go by stop codes and schedule,
    /// or by stops and time, how they matched; for another, only when 3 or more of its live trips are near here and none of them is named by a nearby trip's ID,
    /// which says its live data has started naming trips in ways its timetable doesn't. Nil: nothing to say
    public func logLine(name: String) -> String? {
        if byStopCodesOn {
            let missed = unmatched.values.reduce(0, +)
            let why = LiveMatchFailure.allCases.compactMap { reason in unmatched[reason].map { "\(reason.rawValue) \($0)" } }
            return "live trips: \(name) \(total) in the data, \(nearby) at stops near here, by stop codes and schedule \(byStopCodes) "
                + "(\(nearbyStillToStop) still to stop here), not matched \(missed)"
                + (why.isEmpty ? "" : ": " + why.joined(separator: ", "))
        }
        if byStopsAndTimeOn {
            let missed = unmatched.values.reduce(0, +)
            let why = LiveMatchFailure.allCases.compactMap { reason in unmatched[reason].map { "\(reason.rawValue) \($0)" } }
            return "live trips: \(name) \(total) in the data, by trip ID \(byID), by stops and time \(byStopsAndTime) "
                + "(\(nearbyByStopsAndTime) near here, \(nearbyStillToStop) still to stop here, \(leavingOneOut) with a stop left out), "
                + "not matched \(missed)"
                + (why.isEmpty ? "" : ": " + why.joined(separator: ", "))
        }
        guard nearby >= 3, nearbyByID == 0 else { return nil }
        return "live trips: \(name) \(nearby) near here, none named by a trip ID of its timetable"
    }
}

extension FerryFeed {
    /// Merges each agency's nearby piece (the timetable-only agencies among buses)
    public static func combining(_ feeds: [FerryFeed]) -> FerryFeed? {
        guard var result = feeds.first else { return nil }
        for f in feeds.dropFirst() {
            result.routes += f.routes
            result.piers += f.piers
            result.trips += f.trips
            result.services.merge(f.services) { a, _ in a }
            result.shapes.merge(f.shapes) { a, _ in a }
            for (k, v) in f.versions { result.versions[k] = result.versions[k].map { $0 + "+" + v } ?? v }
            if let zones = f.zones { result.zones = (result.zones ?? [:]).merging(zones) { a, _ in a } }
            if let whole = f.wholeTimetables {
                result.wholeTimetables = (result.wholeTimetables ?? [:]).merging(whole) { a, _ in a }
            }
            if let lists = f.stopCodeLists {
                result.stopCodeLists = (result.stopCodeLists ?? [:]).merging(lists) { a, _ in a }
            }
        }
        return result
    }
}
