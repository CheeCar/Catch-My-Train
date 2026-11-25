import Foundation

/// Data snapshot the main app saves in the shared folder (SharedFolder) for the widgets to read.
///
/// It stores "raw data + walking times", not precomputed conclusions.
/// That way the widget can re-evaluate at any point in time with `board(at:)` (the same `NearbyBoardBuilder` as the main app),
/// so countdowns and catchability update correctly over time without the main app running in the background.
public struct TransitSnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// When the snapshot was made (the main app's last refresh).
    public var createdAt: Date
    public var placeName: String
    /// A line under the place's name, already localized: how approximate the current position is ("within about …"). nil when there
    /// is nothing to say, and in older snapshots
    public var placeNote: String?
    public var stations: [Station]
    public var walks: [String: WalkEstimate]
    /// Position of each station by exact walking time. The walks above are rounded (see sharedWalks), so this breaks
    /// their ties and the widget lists stations in the same order as the main app. nil in older snapshots.
    public var walkOrder: [String: Int]?
    public var arrivals: [Arrival]
    public var settings: CatchSettings
    /// UI language and units chosen in the main app (e.g. "zh-Hans", "us").
    /// Widgets prefer these values over shared UserDefaults. nil in older snapshots.
    public var languageCode: String?
    public var unitsCode: String?
    /// 12- / 24-hour clock chosen in the main app ("12" / "24"). nil in older snapshots.
    public var clockCode: String?
    /// Lines serving each station (from the station catalog), so lines with no departures still show. nil in older snapshots.
    public var stationRoutes: [String: [String]]?
    /// Transit system chosen in the main window ("subway" / "bus"). nil in older snapshots, meaning subway.
    public var system: String?
    /// Titles for directions with no departures right now ("complex ID|N" → "To Jamaica"), computed by the main app,
    /// so the widget doesn't show a generic "Northbound" either.
    public var directionTitles: [String: String]?
    /// Data update time shown in the UI, computed the same way as the main window's "Data updated" (for realtime data, MTA's own timestamp).
    /// Widgets write it the same way when they download themselves. nil in older snapshots.
    public var dataTime: Date?
    /// Region of the origin (e.g. "Long Island"), or a place name when outside the service area (e.g. "Albany, New York"), already localized. nil in older snapshots.
    public var areaName: String?
    /// The origin is outside the service area. nil in older snapshots.
    public var outsideArea: Bool?
    /// The time zone the departures' times are shown in: the origin's metro area's (MetroArea.timeZone). nil outside the service
    /// area and in older snapshots
    public var timeZone: String?
    /// Clock offset measured by the main app (server time − local time, seconds, see ClockSkew). nil in older snapshots.
    public var clockSkew: Double?
    /// Data providers currently rate-limiting us (see RateLimit), noted on the widget. nil if none.
    /// Only the ones for this mode (see NoticeScope); the widget picks the ones for the station it shows.
    public var rateLimits: [RateLimit.Notice]?
    /// Data providers that can't be reached (see NetworkReach), noted on the widget. nil if none. Only the ones for this mode, like rateLimits.
    public var reach: [NetworkReach.Notice]?
    /// When reach was taken, if not when the snapshot was made (the widget notes what it saw itself on a snapshot it doesn't save).
    /// nil in older snapshots and when it's createdAt.
    public var reachAt: Date?
    /// Why there are no stations to show, already localized, the same as the main window says (e.g. still downloading the timetables).
    /// nil when there are stations, and in older snapshots (the widget then says nothing is within walking range).
    public var emptyText: String?
    /// emptyText tells of something only the running app gets past (see EmptyBoardReason.needsRunningApp). nil otherwise and in older snapshots.
    public var emptyTextNeedsApp: Bool?
    /// The next departure after the arrival window where a direction has nothing in it, from the timetables on this Mac (see
    /// NearbyBoardBuilder.build's `later`). nil if none, and in older snapshots.
    public var later: [Arrival]?
    /// Version number when a new version is available (see UpdateCheck), mentioned on the widget. nil if none.
    public var updateAvailable: String?
    /// The running app saved this while its live data was already out of date by its own setting ("Real-time data expires after"),
    /// e.g. downloads failing: its main window says "Not sure", so the widget does too (see widgetStaleAfterSeconds). nil otherwise
    /// and in older snapshots.
    public var staleWhenSaved: Bool?

    /// How long live data counts as fresh on the widget: 10 minutes, looser than the app (the widget is redrawn only every few
    /// minutes, and a shorter time would turn "Not sure" and back between redraws); the app's own setting while the app runs and
    /// said its data was already out of date when it saved this, so the widget and the main window agree (staleWhenSaved)
    public static let widgetStaleAfterSeconds: TimeInterval = 600

    public func widgetStaleAfterSeconds(appRunning: Bool) -> TimeInterval {
        if appRunning, staleWhenSaved == true { return settings.realtimeStaleAfterSeconds }
        return max(settings.realtimeStaleAfterSeconds, Self.widgetStaleAfterSeconds)
    }

    /// The settings the widget judges departures with (see widgetStaleAfterSeconds)
    public func widgetSettings(appRunning: Bool) -> CatchSettings {
        var s = settings
        s.realtimeStaleAfterSeconds = widgetStaleAfterSeconds(appRunning: appRunning)
        return s
    }

    /// Whether the departures' times read differently on this Mac's clock (`mac`) at that moment: the widget then lists none and says
    /// to open the app, which names the zone with each time (AppText.showsZone). A zone that keeps the same time as the Mac's doesn't
    /// count
    public func timesInAnotherZone(mac: TimeZone, at date: Date) -> Bool {
        guard let zone = timeZone.flatMap(TimeZone.init(identifier:)) else { return false }
        return zone.secondsFromGMT(for: date) != mac.secondsFromGMT(for: date)
    }

    /// Whether this is a bus snapshot (widgets can't download bus data themselves, since it needs a key from the Keychain).
    public var isBus: Bool { system == TransitSystem.bus.rawValue }
    public var isFerry: Bool { transitSystem.family == .ferry }
    public var transitSystem: TransitSystem { system.flatMap(TransitSystem.init(rawValue:)) ?? .subway }

    public init(
        createdAt: Date,
        placeName: String,
        stations: [Station],
        walks: [String: WalkEstimate],
        arrivals: [Arrival],
        settings: CatchSettings,
        languageCode: String? = nil,
        unitsCode: String? = nil,
        stationRoutes: [String: [String]]? = nil,
        system: String? = nil,
        directionTitles: [String: String]? = nil,
        dataTime: Date? = nil
    ) {
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.placeName = placeName
        self.stations = stations
        self.walks = walks
        self.arrivals = arrivals
        self.settings = settings
        self.languageCode = languageCode
        self.unitsCode = unitsCode
        self.stationRoutes = stationRoutes
        self.system = system
        self.directionTitles = directionTitles
        self.dataTime = dataTime
    }

    /// Group departures by station at any point in time (for widgets).
    /// - Parameter tooSoonKept: trains too soon to catch kept before the first one worth trying (see NearbyBoardBuilder.build).
    public func board(at date: Date, settings override: CatchSettings? = nil,
                      maxTrainsPerDirection: Int = NearbyBoardBuilder.defaultMaxTrainsPerDirection,
                      tooSoonKept: Int? = nil) -> NearbyBoard {
        var board = NearbyBoardBuilder.build(stations: stations, walks: walks, arrivals: arrivals, later: later ?? [],
                                             settings: override ?? settings, now: date, routes: stationRoutes ?? [:],
                                             walkOrder: walkOrder, maxTrainsPerDirection: maxTrainsPerDirection,
                                             tooSoonKept: tooSoonKept)
        if let titles = directionTitles, !titles.isEmpty {
            for i in board.stations.indices {
                let id = board.stations[i].id
                if board.stations[i].north.directions.isEmpty, let t = titles[id + "|N"] {
                    board.stations[i].north.directions = [Direction(code: "N", name: t)]
                }
                if board.stations[i].south.directions.isEmpty, let t = titles[id + "|S"] {
                    board.stations[i].south.directions = [Direction(code: "S", name: t)]
                }
            }
        }
        return board
    }

    /// IDs of the stations board(at:) can show: those within walking range (see Recommender.classify). Doesn't depend on the time,
    /// so the widget downloads departures only for these.
    public func boardStationIDs(settings override: CatchSettings? = nil) -> Set<String> {
        let s = (override ?? settings).sanitized()
        return Set(stations.filter { station in
            walks[station.id].flatMap { Recommender.classify(walk: $0, settings: s) } != nil
        }.map(\.id))
    }

    /// Snapshot age (seconds).
    public func age(at date: Date) -> TimeInterval { date.timeIntervalSince(createdAt) }

    /// Oldest update time of the data itself (for realtime data, MTA's timestamp). nil when there are no departures.
    public var dataUpdatedAt: Date? { arrivals.map(\.updatedAt).min() }

    /// The "Updated" time shown on widgets: the same dataTime as the main window; for older snapshots without it, the oldest time among departures.
    public var updateTime: Date? { dataTime ?? dataUpdatedAt }

    /// Data source: counts as simulated if any entry is simulated (the UI must label it).
    public var containsMockData: Bool { arrivals.contains { $0.source == .mock } }

    /// The last departure's time in the snapshot; after this the snapshot has nothing left to show.
    public var lastLeavingTime: Date? { arrivals.compactMap(\.arrivalTime).max() }

    /// How long a snapshot the widget can't update by itself counts as complete: it holds the departures in the arrival time window
    /// from when it was saved plus 15 minutes, so after that the later part of the window is missing
    public static let usedUpAfter: TimeInterval = 15 * 60

    /// The widget has used up this snapshot: the main app isn't running to save a new one, the widget can't download these departures
    /// itself, they aren't live data (live data has its own staleness check), and either the last departure in it has passed
    /// or it's older than `usedUpAfter`. The widget then asks for the app instead of saying nothing is coming.
    public func isUsedUp(at date: Date, appRunning: Bool, canUpdateItself: Bool, isLive: Bool) -> Bool {
        guard !appRunning, !canUpdateItself, !isLive, !containsMockData else { return false }
        if let last = lastLeavingTime, date >= last { return true }
        return date.timeIntervalSince(createdAt) > Self.usedUpAfter
    }

    /// Rate limits the widget notes at this time: still paused, for this mode, and with stationIDs (a station's members) for that station
    public func rateLimits(at date: Date, stationIDs: [String]? = nil) -> [RateLimit.Notice] {
        NoticeScope.filter((rateLimits ?? []).filter { $0.until > date }, mode: transitSystem, stationIDs: stationIDs)
    }

    /// Connection notices the widget notes at this time, for this mode (and station, like rateLimits(at:stationIDs:)).
    /// When the app isn't running, a passing problem is dropped once it was seen longer than NetworkReach.forgetAfter ago: nothing
    /// has tried that provider since, so whether it still applies isn't known. While it runs (appRunning, when the widget's timeline
    /// was made), they're kept: the app keeps trying and reloads the widget once its notices change. The monthly data's problems last.
    public func reachNotices(at date: Date, stationIDs: [String]? = nil, appRunning: Bool = false) -> [NetworkReach.Notice] {
        let seenAt = reachAt ?? createdAt
        let current = (reach ?? []).filter {
            appRunning || $0.lasting == true || date.timeIntervalSince(seenAt) < NetworkReach.forgetAfter
        }
        return NoticeScope.filter(current, mode: transitSystem, stationIDs: stationIDs)
    }

    /// Whether the widget can show emptyText as it is: what only the running app gets past (downloading, loading) doesn't
    /// happen while it isn't running, so the widget asks for the app instead
    public func emptyTextHolds(appRunning: Bool) -> Bool {
        appRunning || emptyTextNeedsApp != true
    }

    public func encoded() throws -> Data {
        // Use the default date encoding (seconds) to keep precision, so values match exactly after a round trip.
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> TransitSnapshot {
        try JSONDecoder().decode(TransitSnapshot.self, from: data)
    }
}

extension TransitSnapshot {
    /// Walking data as written to the folder shared with the widget. Exact distances to several stations with known coordinates
    /// would let any program that can read the container work out the user's position, so the snapshot only gets
    /// rounded values (see WalkEstimate.coarsenedForSharing). The main app keeps the exact values in memory.
    /// This doesn't hide the position completely: the widget needs each station's walking time and their order, and with
    /// many stations nearby these still narrow it down to about a block. SECURITY.md says so.
    public static func sharedWalks(_ walks: [String: WalkEstimate], settings: CatchSettings) -> [String: WalkEstimate] {
        let meters = [settings.candidateRadiusMeters, settings.extendedCandidateRadiusMeters]
        let seconds = [settings.primaryWalkSeconds, settings.extendedWalkSeconds]
        return walks.mapValues { $0.coarsenedForSharing(meterLimits: meters, secondLimits: seconds) }
    }

    /// Stations sorted by exact walking time, ties by ID (the order NearbyBoardBuilder uses), as station ID → position.
    public static func walkOrder(_ walks: [String: WalkEstimate]) -> [String: Int] {
        let sorted = walks.sorted { a, b in
            a.value.walkSeconds != b.value.walkSeconds ? a.value.walkSeconds < b.value.walkSeconds : a.key < b.key
        }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.key, $0.offset) })
    }
}

extension WalkEstimate {
    public static let sharedMetersStep = 100.0
    public static let sharedSecondsStep: TimeInterval = 30

    /// Straight-line distance rounded up to 100 m, walking time rounded up to 30 s, route length and entrance name dropped.
    /// A value is never rounded past a limit it was within, so every station stays in the same primary / extended range.
    /// Walking minutes on screen are rounded up to whole minutes, so they don't change; the catch verdict can only get more cautious.
    public func coarsenedForSharing(meterLimits: [Double], secondLimits: [TimeInterval]) -> WalkEstimate {
        var c = self
        c.straightLineMeters = Self.roundUp(straightLineMeters, step: Self.sharedMetersStep, keepingWithin: meterLimits)
        c.walkSeconds = Self.roundUp(walkSeconds, step: Self.sharedSecondsStep, keepingWithin: secondLimits)
        c.routeMeters = nil
        c.entranceName = nil
        return c
    }

    static func roundUp(_ value: Double, step: Double, keepingWithin limits: [Double]) -> Double {
        guard value.isFinite, value >= 0 else { return value }
        let up = (value / step).rounded(.up) * step
        guard let limit = limits.filter({ $0 >= value }).min() else { return up }
        return min(up, limit)
    }
}
