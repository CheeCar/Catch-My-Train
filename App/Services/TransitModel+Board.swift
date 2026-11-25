import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// Group departures by station at a given time (the UI calls this every few seconds so countdowns and verdicts update over time).
    /// This only recomputes from existing data and doesn't download again, so the "data updated" time doesn't change.
    /// - Parameter routeFilter: only these routes (nil means all).
    /// Several places in the UI (main window, menu bar panel, widget snapshot) use this on every redraw: if the data hasn't changed and the time differs by under 5 seconds, reuse the computed result
    /// instead of regrouping all departures each time.
    /// Of the trains too soon to catch at the front of each direction, only the last one is kept (like the menu bar panel), before the list is cut.
    func board(at now: Date, routeFilter: Set<String>? = nil, maxTrainsPerDirection: Int = 60) -> NearbyBoard {
        let bucket = Int((now.timeIntervalSince1970 / Self.boardBucketSeconds).rounded(.down))
        if boardCacheStamp != (boardInputs, bucket) {
            boardCache = [:]
            boardCacheStamp = (boardInputs, bucket)
        }
        let key = BoardKey(routeFilter: routeFilter, maxTrains: maxTrainsPerDirection)
        if let cached = boardCache[key] { return cached }
        // Within the same 5 seconds compute with the same time, so the result doesn't depend on call order
        let at = Date(timeIntervalSince1970: Double(bucket) * Self.boardBucketSeconds)
        let value = NearbyBoardBuilder.build(stations: stations, walks: walks, arrivals: arrivals, later: laterArrivals,
                                             settings: effectiveSettings, now: at,
                                             routes: stationRoutes, routeFilter: routeFilter,
                                             maxTrainsPerDirection: maxTrainsPerDirection, tooSoonKept: 1)
        boardCache[key] = value
        return value
    }


    /// Looks up when the next one comes in each direction that has nothing in the arrival window ("Next: 6:05 AM"). Only what
    /// is on this Mac is read, never anything online: the operators' timetables and the tram's hours, less than a day from now
    /// (NearbyBoardBuilder.nextWithin, the window included), off the
    /// main thread, and only for the stations with such a direction. Asked again when those stations or the window change, and
    /// every ten minutes. Not in Demo mode (its times are made up) and not on standby.
    func updateLaterDepartures(now: Date = Date()) {
        guard !isDemo else {
            laterKey = ""
            laterTask?.cancel()
            if !laterArrivals.isEmpty { laterArrivals = [] }
            return
        }
        guard isActive else { return }
        let empty = board(at: now).stations.filter { $0.north.trains.isEmpty || $0.south.trains.isEmpty }
        let ids = empty.flatMap { $0.stations.map(\.id) }
        let piers = ids.filter { isTimetableStation($0) }.sorted()
        let tram = ids.filter { RooseveltIslandTram.isTramStation($0) }.sorted()
        let window = effectiveSettings.sanitized().arrivalWindowSeconds
        let slot = Int(now.timeIntervalSince1970 / 600)
        let key = piers.isEmpty && tram.isEmpty ? ""
            : "\(system.rawValue)|\(Int(window))|\(slot)|\(ferryFeed == nil)|" + (piers + tram).joined(separator: ",")
        guard key != laterKey else { return }
        laterKey = key
        laterTask?.cancel()
        guard !key.isEmpty else {
            if !laterArrivals.isEmpty { laterArrivals = [] }
            return
        }
        // The timetables are read in the trains' time (see ClockSkew), as the board's own departures are
        let trainNow = ClockSkew.now(now)
        let after = trainNow.addingTimeInterval(window)
        let ahead = max(0, NearbyBoardBuilder.nextWithin - window)
        let tramNext = Arrival.firstPerDirection(RooseveltIslandTram.arrivals(
            stationIDs: tram, from: after, to: after.addingTimeInterval(ahead), hours: tramHours, now: trainNow))
        let feed = ferryFeed
        laterTask = Task { [weak self] in
            let found = await offMain { feed?.nextDepartures(pierIDs: piers, after: after, within: ahead, now: trainNow) ?? [] }
            guard let self, !Task.isCancelled, self.laterKey == key else { return }
            let all = found + tramNext
            if all != self.laterArrivals { self.laterArrivals = all }
        }
    }

    /// Direction title (e.g. "Manhattan", "To Flushing-Main St"). When this direction has no departures for now, use the direction name from the station catalog,
    /// rather than showing "Northbound" first and then jumping to something else.
    /// - Parameter fromCatalog: subway stations always use the direction name from the station catalog (when trip planning uses timetables, departures lack the terminal name,
    ///   and just "Uptown" isn't clear enough)
    func directionTitle(_ dir: BoardDirection, in station: BoardStation, fromCatalog: Bool = false) -> String {
        guard let named = titledDirection(dir, in: station, fromCatalog: fromCatalog) else {
            // A direction with departures always gets a title, never an empty heading
            return dir.trains.isEmpty ? "" : l10n.t("Destination not listed")
        }
        return l10n.directionTitle(named)
    }

    /// Every terminal the direction title names, also those past the first ones it writes out (AppText.toPlaces): the station
    /// page lists them when the title says "and N more"
    func directionTerminals(_ dir: BoardDirection, in station: BoardStation) -> [String] {
        titledDirection(dir, in: station).map(l10n.directionTerminals) ?? []
    }

    /// The directions a direction's title is written from: its departures', or with none (or `fromCatalog`), where its routes go
    /// from the station catalog, the bus timetable or the ferry timetable. nil: no title (no routes go that way)
    private func titledDirection(_ dir: BoardDirection, in station: BoardStation, fromCatalog: Bool = false) -> BoardDirection? {
        if station.stations.contains(where: { isTimetableStation($0.id) || isDemoStop($0.id) }) { return ferryDirection(dir, in: station) }
        if system == .bus { return busDirection(dir, in: station) }
        // Tram stations only run in one direction: the other direction has no title (and isn't shown)
        if dir.directions.isEmpty, isTramOnly(station) { return nil }
        guard dir.directions.isEmpty || fromCatalog, let catalog else { return dir }
        var directions: [Direction] = []
        for member in station.stations {
            for route in catalog.entry(id: member.id)?.routes ?? [] {
                guard (dir.code == "S" ? route.south : route.north) != nil,
                      !catalog.terminates(stationID: member.id, route: route.route, code: dir.code) else { continue }
                directions.append(catalog.direction(stationID: member.id, route: route.route, code: dir.code))
            }
        }
        return BoardDirection(code: dir.code, directions: directions, routes: dir.routes, trains: [])
    }

    /// Bus direction title: when this direction has no buses for now, use the terminals of each route in this direction from the timetable (e.g. "To Jamaica").
    /// Whether to show this direction: subway always shows both; a bus stop is usually on one side of the street, so the other side isn't shown when it has no buses and no terminal.
    func hasDirection(_ dir: BoardDirection, in station: BoardStation) -> Bool {
        // Subway stations show both directions (PATH, light rail and tram stations within subway work like bus and ferry: a direction with no service can be hidden)
        if system == .subway, !isTramOnly(station),
           !station.stations.contains(where: { isTimetableStation($0.id) || isDemoStop($0.id) }) { return true }
        guard system.hasTimetablePart || isTramOnly(station) else { return true }
        return !dir.trains.isEmpty || !directionTitle(dir, in: station).isEmpty
    }

    /// Bus direction title. None when this direction has no routes at all (rather than a generic "Northbound").
    private func busDirection(_ dir: BoardDirection, in station: BoardStation) -> BoardDirection? {
        guard dir.directions.isEmpty else { return dir }
        guard let busCatalog else { return nil }
        let ids = station.stations.map(\.id)
        var directions: [Direction] = []
        var seen = Set<String>()
        for member in station.stations where busCatalog.side(ofStop: member.id, among: ids) == dir.code {
            for rd in busCatalog.stop(id: member.id)?.routeDirections ?? [] {
                guard let h = busCatalog.headsign(route: rd.route, direction: rd.direction),
                      seen.insert(h).inserted else { continue }
                directions.append(Direction(code: dir.code, name: "To " + h, terminal: h))
            }
        }
        if directions.isEmpty { return nil }
        return BoardDirection(code: dir.code, directions: directions, routes: dir.routes, trains: [])
    }

    /// Ferry direction title: when this direction has no boats for now, use the most common terminal from the timetable (e.g. "To Wall St/Pier 11").
    private func ferryDirection(_ dir: BoardDirection, in station: BoardStation) -> BoardDirection? {
        guard dir.directions.isEmpty else { return dir }
        if isDemo {
            // Demo mode's own stations: where their lines go that way (none: no title, and the way isn't shown)
            var terminals: [String] = []
            for member in station.stations {
                for line in DemoData.stop(id: member.id)?.lines ?? [] {
                    if let t = dir.code == "S" ? line.south : line.north, !terminals.contains(t) { terminals.append(t) }
                }
            }
            if terminals.isEmpty { return nil }
            let directions = terminals.map { Direction(code: dir.code, name: "To " + $0, terminal: $0) }
            return BoardDirection(code: dir.code, directions: directions, routes: dir.routes, trains: [])
        }
        guard let ferryFeed else { return nil }
        var directions: [Direction] = []
        var seen = Set<String>()
        for member in station.stations {
            for t in terminals(atPier: member.id, in: ferryFeed) where t.direction == dir.code && seen.insert(t.terminal).inserted {
                directions.append(Direction(code: dir.code, name: "To " + t.terminal, terminal: t.terminal))
            }
        }
        if directions.isEmpty { return nil }
        return BoardDirection(code: dir.code, directions: directions, routes: dir.routes, trains: [])
    }

    /// Routes serving a station (or bus stop, or pier).
    func routes(atStation id: String) -> [String] {
        // Demo mode's own stations have their own lines; its subway stations and bus stops are the real ones
        if isDemo, let stop = DemoData.stop(id: id) { return stop.routes }
        if isTimetableStation(id) {
            // Count all operators at the same pier together (the map draws only one dot per pier)
            let ids = ferrySamePier[id] ?? [id]
            return Array(Set(ids.flatMap { ferryRoutesByPier[$0] ?? [] })).sorted()
        }
        if system == .bus { return busCatalog?.routes(atStop: id) ?? [] }
        if RooseveltIslandTram.isTramStation(id) { return [RooseveltIslandTram.route] }
        return catalog?.entry(id: id)?.routes.map(\.route) ?? []
    }

    /// Routes serving each nearby station (from the station catalog), so routes with no departures for now still show.
    var stationRoutes: [String: [String]] {
        if isDemo { return Dictionary(stations.map { ($0.id, routes(atStation: $0.id)) }, uniquingKeysWith: { a, _ in a }) }
        if system == .bus {
            return Dictionary(stations.map { s in
                (s.id, isTimetableStation(s.id) ? ferryRoutesByPier[s.id] ?? [] : busCatalog?.routes(atStop: s.id) ?? [])
            }, uniquingKeysWith: { a, _ in a })
        }
        if usesTimetable {
            return Dictionary(stations.map { ($0.id, ferryRoutesByPier[$0.id] ?? []) }, uniquingKeysWith: { a, _ in a })
        }
        guard let catalog else { return [:] }
        var result: [String: [String]] = [:]
        for s in stations {
            if let entry = catalog.entry(id: s.id) { result[s.id] = entry.routes.map(\.route) }
            if RooseveltIslandTram.isTramStation(s.id) { result[s.id] = [RooseveltIslandTram.route] }
            if isTimetableStation(s.id) { result[s.id] = ferryRoutesByPier[s.id] ?? [] }
        }
        return result
    }

    /// The oldest update time among the data used (in live mode, from the MTA data's own timestamp).
    var dataUpdatedAt: Date? {
        if isDemo { return arrivals.map(\.updatedAt).max() }
        if system == .bus { return busResponseTime ?? ferryUpdatedAt ?? arrivals.map(\.updatedAt).max() }
        if usesTimetable { return ferryUpdatedAt }
        switch dataSource {
        case .mock:
            return arrivals.map(\.updatedAt).max()
        case .mtaRealtime:
            // The widget uses the same algorithm when it downloads on its own (see WidgetRefresher), so both show the same update time
            return FeedStatus.dataTime(feedStatuses) ?? ferryUpdatedAt ?? arrivals.map(\.updatedAt).max()
        }
    }

    /// The day this mode's timetables are up to date as of (the main window's footer; see FerryStore.upToDate): nil in Demo mode, for a
    /// mode without timetables, and before every one of its operators got through once
    var timetablesUpToDate: Date? {
        guard !isDemo, system.hasTimetablePart else { return nil }
        var dates = FerryStore.stores(for: system).map { $0.upToDate }
        // Subway's own timetable is built from the MTA data the subway map check downloads (as the map window counts it)
        if system == .subway { dates.append(SubwayMapStore.store(.subway).lastChecked) }
        guard !dates.contains(where: { $0 == nil }) else { return nil }
        return dates.compactMap { $0 }.min()
    }

    /// The day the timetables of this station's own operators are up to date as of (the station page's footer): a Boston pier
    /// shows the MBTA's day, not the earliest of every ferry operator's. The whole mode's (timetablesUpToDate) for no station
    func timetablesUpToDate(at station: BoardStation?) -> Date? {
        guard !isDemo, system.hasTimetablePart else { return nil }
        guard let station else { return timetablesUpToDate }
        let ids = station.stations.map(\.id)
        var dates: [Date?] = []
        for store in FerryStore.stores(for: system) {
            let keys = store.operatorKeys(stationIDs: ids, routes: station.routes)
            if !keys.isEmpty { dates.append(store.upToDate(of: keys)) }
        }
        // The MTA's own subway stations (no operator prefix): from the MTA data the subway map check downloads
        if system == .subway, ids.contains(where: { id in !FerryFeed.Source.allCases.contains { $0.owns(id: id) } }) {
            dates.append(SubwayMapStore.store(.subway).lastChecked)
        }
        guard !dates.isEmpty else { return timetablesUpToDate }
        guard !dates.contains(where: { $0 == nil }) else { return nil }
        return dates.compactMap { $0 }.min()
    }

    /// What the timetable downloads of these parts ran into (see AppText.downloadFailedText): the notices of the operators they
    /// download, without the developer-only ones
    nonisolated static func timetableNotices(_ systems: [TransitSystem], now: Date = Date()) -> [NetworkReach.Notice] {
        timetableNotices(providers: Set(systems.flatMap { FerryStore.store(for: $0).providerNames }), now: now)
    }

    /// The same for downloads noted under these names (the MTA timetable: "MTA"). With them the notices about this Mac or its
    /// network as a whole that say why instead of the network (its clock, a sign-in page): those downloads' own notices are in them
    nonisolated static func timetableNotices(providers: Set<String>, now: Date = Date()) -> [NetworkReach.Notice] {
        NetworkReach.notices(now: now).filter {
            ($0.problem.isGeneral && $0.problem != .offline)
                || ($0.lasting == true && providers.contains($0.provider) && !developerOnlyProviders.contains($0.provider))
        }
    }

    /// Operators' own problems (moved, server errors, unreadable, live data not updating) by name, every mode's, for their rows in
    /// Settings. None in Demo mode or with the network off, as at the stations; the developer-only ones stay in the log
    func operatorProblems(now: Date = Date()) -> [String: NetworkReach.Notice] {
        guard !isDemo, networkAllowed else { return [:] }
        let own = NetworkReach.notices(now: now).filter { !$0.problem.isNetwork && !Self.developerOnlyProviders.contains($0.provider) }
        return Dictionary(own.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Which have live data and which only timetables, only for the operators at the selected station (the bottom of the main
    /// window) or in the results (Plan a Trip). With an NJ Transit account entered, NJ Transit counts as live too.
    /// - Parameters:
    ///   - stationIDs: the station's members (or the results' stations); empty: no line
    ///   - routes: routes there. Operator-side problems like Bee-Line's are only mentioned when its buses really stop there
    ///     (so they aren't shown at stations Bee-Line doesn't serve)
    func liveDataSummary(stationIDs: [String], routes: [String]) -> String {
        liveDataSummaryText(operators: ModeCoverage.operatorIDs(atStations: stationIDs, routes: routes, mode: system), routes: routes)
    }

    /// The same for Plan a Trip's departures: their stations and routes
    func liveDataSummary(of arrivals: [Arrival]) -> String {
        liveDataSummaryText(operators: ModeCoverage.operatorIDs(of: arrivals, mode: system), routes: arrivals.map(\.route))
    }

    /// Whether to mention a bus operator whose live data is broken: normally yes; for operator-side problems like Bee-Line's, only when this station really has its buses
    nonisolated static func listsDownFeed(code: String, routes: [String]?) -> Bool {
        guard developerOnlyFeedCodes.contains(code) else { return true }
        return routes?.contains { RegionalBusFeed.of(route: $0)?.code == code } ?? false
    }

    /// These operators of this mode, grouped by where their times come from now. A bus company whose live data isn't
    /// downloading is said to be so; one with an operator-side problem like Bee-Line's only where its buses stop, and otherwise
    /// counted with the timetable ones
    private func liveDataSummaryText(operators: [String], routes: [String]) -> String {
        var names = ModeCoverage.liveNames(for: system, operators: operators, routes: routes, access: liveAccess)
        for i in names.indices where names[i].state == .notNow {
            if let code = names[i].busCode, !Self.listsDownFeed(code: code, routes: routes) { names[i].state = .timetable }
        }
        return l10n.liveDataLine(names)
    }

    /// Check which data providers are currently rate-limiting (drop the notice once the pause time has passed).
    /// Only the providers of the current mode are kept (see NoticeScope): an NJ Transit bus rate limit isn't shown in Ferry mode.
    func updateRateLimits(now: Date) {
        // Demo mode downloads nothing, so no rate-limit or can't-connect notice
        let current = isDemo ? [] : NoticeScope.filter(RateLimit.notices(now: now), mode: system)
        if current != rateLimits { rateLimits = current }
        // Networking turned off in Settings: no can't-connect notice (the main window just says "Network is off...")
        let all = isDemo || !networkAllowed ? [] : NetworkReach.notices(now: now)
        // Clearly the provider's own problem with a timetable available (Bee-Line's server keeps returning 503): don't notify the user,
        // just log it to the system log to remind the developer to handle it later; meanwhile show the timetable as usual, which is good enough
        let hidden = all.filter { Self.developerOnlyProviders.contains($0.provider) }
        let reach = NoticeScope.filter(all.filter { !Self.developerOnlyProviders.contains($0.provider) }, mode: system)
        for n in hidden where !loggedDeveloperNotices.contains(n.provider) {
            loggedDeveloperNotices.insert(n.provider)
            AppLog.data.notice("developer note: \(n.provider, privacy: .public) live data unavailable (\(n.problem.rawValue, privacy: .public)); showing timetable, notice hidden from users")
        }
        if reach != reachNotices { reachNotices = reach }
        // This Mac's clock: none in Demo mode or with the network off either (nothing is downloaded, so nothing is measured)
        let measured = isDemo || !networkAllowed ? nil : ClockSkew.noticeOffset
        let offset = measured
        // To the minute, so the sentence doesn't change with every reading
        let shown = offset.map { ($0 / 60).rounded() * 60 }
        if shown != clockOffset { clockOffset = shown }
    }

    /// The rate limits that concern this station (nil: all of the current mode's), to show: a server several bus companies share
    /// is named after the ones there (nil: the ones in use, see NoticeScope.naming)
    func rateLimits(at station: BoardStation?) -> [RateLimit.Notice] {
        guard let station else { return NoticeScope.naming(rateLimits) }
        return NoticeScope.filter(rateLimits, mode: system, stationIDs: station.stations.map(\.id))
    }

    /// The can't-connect and data notices that concern this station (nil: all of the current mode's), to show, named like rateLimits(at:)
    func reachNotices(at station: BoardStation?) -> [NetworkReach.Notice] {
        guard let station else { return NoticeScope.naming(reachNotices) }
        return NoticeScope.filter(reachNotices, mode: system, stationIDs: station.stations.map(\.id))
    }

    /// Can't-connect notice (main window, Settings): which provider, and what kind of failure was seen
    func reachText(_ n: NetworkReach.Notice) -> String {
        l10n.reachText(n)
    }

    /// Explanation after the can't-connect notice: when several providers fail at once, say the network may be blocking; with only one, mention both possibilities
    func reachExplanation() -> String? {
        l10n.reachExplanation(reachNotices)
    }

    /// Rate-limit notice (main window, Settings): which provider, paused until when, and what's shown meanwhile
    func rateLimitText(_ n: RateLimit.Notice) -> String {
        let l = l10n
        return l.f("%@ says Catch My Train is asking too often, so live times from it are paused until %@. Until then, times are from the timetable or the last update.",
                   l.t(n.provider), l.time(n.until))
    }

    /// Short rate-limit notice (menu bar panel)
    func rateLimitShortText(_ n: RateLimit.Notice) -> String {
        l10n.f("%@: too many requests, paused until %@", l10n.t(n.provider), l10n.time(n.until))
    }

    /// Explanation when there are no nearby stations to show (same in the main window, menu bar panel and widget).
    /// Not used while the first position is still being found (isLocating): each shows "Locating" on its own. The order is in EmptyBoardReason.
    /// short: the menu bar panel's and widget's form of an operator's problem (see downloadFailedText)
    func emptyStateText(short: Bool = false) -> String {
        let l = l10n
        switch emptyBoardReason() {
        case .noStartingPlace:
            return l.t("There's no starting place yet. Choose a place to see departures.")
        case .locationTooApproximate:
            return locationTooApproximateText
        case .outsideArea:
            // Starting point isn't in any metro area the app covers (the "Service Area" button shows them on the map)
            return l.t("This place is outside the areas the app covers, so there is nothing nearby to show. Choose a place inside them to see departures.")
        case .networkOff:
            return l.t("Network is off in Settings, so only timetables saved on this Mac are shown.")
        case .downloading:
            // First use of the mode: its timetables aren't downloaded yet (bus processing takes a while)
            switch system.mode {
            case .train: return l.t("Downloading train timetables…")
            case .bus: return l.t("Downloading bus timetables…")
            case .ferry: return l.t("Downloading ferry timetables…")
            default: return l.t("Downloading subway and light rail data…")
            }
        case .downloadFailed:
            let network: String
            switch system.mode {
            case .train: network = l.t("Couldn't download the train timetables. Check your network.")
            case .bus: network = l.t("Couldn't download the bus timetables. Check your network.")
            case .ferry: network = l.t("Couldn't download the ferry timetables. Check your network.")
            default: network = l.t("Couldn't download the subway and light rail data. Check your network.")
            }
            // An operator's own problem says so instead of asking to check the network
            return l.downloadFailedText(network, problems: Self.timetableNotices(system.timetableSystems), short: short)
        case .downloadsOnStart:
            switch system.mode {
            case .train: return l.t("Train timetables are downloaded the first time you turn the app on.")
            case .bus: return l.t("Bus timetables are downloaded the first time you turn the app on.")
            case .ferry: return l.t("Ferry timetables are downloaded the first time you turn the app on.")
            // The PATH and light rail data (the same line as the standby views)
            default: return l.t("Nothing is refreshed or downloaded on standby.")
            }
        case .error:
            return lastError ?? l.noStationNearby(system)
        case .loading:
            return l.pick(system, train: l.t("Loading train times…"), bus: l.t("Loading bus times…"), ferry: l.t("Loading ferry times…"))
        case .noStationNearby:
            return l.noStationNearby(system)
        }
    }

    /// The few words shown where the starting place's name would be while there is none (needsPlace): with the current location
    /// wanted they say what's wrong with the location, otherwise that no place was chosen. The button beside them chooses a place
    /// either way
    var missingPlaceText: String {
        switch StartingPlace.missingReason(usesCurrentLocation: locationMode == .current, locationDenied: locationState == .denied) {
        case .notChosen: return l10n.t("No place chosen yet")
        case .locationOff: return l10n.t("Location access is off")
        case .locationFailed: return l10n.t("Couldn't find your location")
        }
    }

    /// Its icon: a pin for a place not chosen, the location arrow for a location that can't be had
    var missingPlaceSymbol: String { locationMode == .current ? "location.slash" : "mappin.slash" }

    /// Why there are no nearby stations to show (see emptyStateText). The note that the network is off isn't an error that
    /// explains it: lastError is that note whenever the network is off, also with the data on this Mac
    func emptyBoardReason() -> EmptyBoardReason {
        // Only the stations with departures count: the menu bar panel and widgets, which leave out the ones without times,
        // give the reason when only those are nearby (the main window lists them, so it has no empty state then)
        EmptyBoardReason.of(mode: system, hasStartingPlace: !needsPlace, locationTooApproximate: locationTooApproximate,
                            outsideArea: isOutsideArea, networkAllowed: networkAllowed,
                            timetableMissing: timetableMissing, downloadFailed: ferryDownloadFailed, isActive: isActive,
                            hasStations: !timedStations.isEmpty, hasError: lastError != nil && lastError != networkOffNote,
                            isRefreshing: isRefreshing)
    }

    /// The nearby stations with departures: all but the ones without times (NoTimesStations), which only the main window,
    /// the map and the trip planner show
    var timedStations: [Station] { stations.filter { !NoTimesStations.isNoTimes($0.id) } }

    /// This mode's timetable data isn't on this Mac (Train and Ferry: none; Bus: the other companies' timetables, or the ones for the
    /// starting point's area; Subway: PATH or light rail)
    var timetableMissing: Bool {
        guard !isDemo, system.hasTimetablePart else { return false }
        if system == .subway { return !subwayPartsMissing.isEmpty }
        return ferryFeed == nil || (system == .bus && busOperatorsMissing)
    }

    /// Timetable data that's missing and couldn't be downloaded. No station comes from it, so there's no station to note it at:
    /// it's noted once at the bottom of the board instead (main window footer, menu bar panel). With nothing nearby, emptyStateText says it.
    /// Train and ferry stations all come from their timetables, so those modes only have the empty state.
    /// short: the menu bar panel's form of an operator's problem (see downloadFailedText)
    func missingTimetableNote(short: Bool = false) -> String? {
        guard ferryDownloadFailed, timetableMissing, networkAllowed else { return nil }
        let network: String
        switch system {
        case .subway: network = l10n.t("Couldn't download the subway and light rail data. Check your network.")
        case .bus: network = l10n.t("Couldn't download the bus timetables. Check your network.")
        default: return nil
        }
        // Subway: only the missing part's operators (PATH's or light rail's)
        let parts = system == .subway ? subwayPartsMissing : system.timetableSystems
        return l10n.downloadFailedText(network, problems: Self.timetableNotices(parts), short: short)
    }

    /// Whether the data is stale (for UI notices).
    func isStale(now: Date) -> Bool {
        // Demo mode's departures are made anew on every refresh, so they never count as stale; stations without times have none
        guard !timedStations.isEmpty, !isDemo else { return false }
        // No bus key yet: that's not stale data; the UI prompts to add a key
        if needsBusKey, !stations.contains(where: { isTimetableStation($0.id) }) { return false }
        guard let t = dataUpdatedAt else { return !isRefreshing }
        // When the refresh interval is lengthened, data between refreshes doesn't count as stale. Data times are the server's, so compare against server time (see ClockSkew)
        return ClockSkew.now(now).timeIntervalSince(t) > effectiveSettings.realtimeStaleAfterSeconds
    }
}
