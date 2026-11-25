import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    // MARK: - Refresh

    /// Refresh: update location → pick nearby stations → compute walking → download departures → save a snapshot for widgets.
    func refresh() {
        notePlacesInUse()
        // In standby, don't download or locate.
        guard isActive else { return }
        updateLocationNeed()
        checkStaticDataIfDue()
        checkSourceListIfDue()
        checkForUpdatesIfDue()
        refreshTask?.cancel()
        // A cancelled previous refresh won't turn "refreshing" off by itself; the branches below that download turn it back on
        isRefreshing = false
        // The clock's time (BoardClock)
        let now = BoardClock.now()
        lastAttempt = now
        if locationMode == .current, dataSource == .mtaRealtime {
            location.requestIfStale(maxAge: (isWindowOpen || isMapWindowOpen) ? 60 : 300)
        }

        // Location not known yet (first fix in progress): keep the last stations and widget data and wait for the location.
        // No starting place at all, or a position too far off to use: nothing is nearby, in the app and on the widget, until a
        // place is chosen (or the position gets better).
        if dataSource == .mtaRealtime, origin == nil {
            if needsPlace || locationTooApproximate {
                updateArea()
                if !stations.isEmpty { stations = [] }
                if !arrivals.isEmpty { arrivals = [] }
                updateWalks()
                saveSnapshot()
            }
            return
        }

        updateArea()
        // Demo mode's current location is Times Square: no place name lookup with Apple Maps
        if locationMode == .current, !isDemo { updateCurrentPlaceName() }
        let newStations = currentStations()
        let ids = Set(newStations.map(\.id))
        arrivals = arrivals.filter { ids.contains($0.stationID) }
        stations = newStations
        updateWalks()
        requestRoutesIfNeeded()

        // Demo mode: all four transit modes use made-up departures (the tram's are worked out as always), no network
        if isDemo {
            if system == .bus { ensureBusCatalogLoaded() }
            refreshCount += 1
            demoTimesBase = (at: now, seed: refreshCount)
            arrivals = MockTransitData.demoArrivals(at: stations, system: system, catalog: catalog, buses: busCatalog,
                                                    now: now, seed: refreshCount) + tramArrivals(now: now)
            feedStatuses = []
            lastError = nil
            stationNotices = []
            busError = nil
            saveSnapshot(refreshDone: true)
            return
        }

        if system == .bus {
            refreshBus(now: now)
            return
        }
        if usesTimetable {
            refreshFerry(now: now)
            return
        }
        refreshSubway(now: now)
    }

    /// Where the app is used now: the starting point and the favorites, whose metro areas' data is downloaded and kept (see AreaData;
    /// the trip planner adds its place, recent places don't count). The starting point's area also counts as used now (AreaUsage: the
    /// order of Settings' area menu, and when an unused area's data goes), isn't removed any more if the user removed it, and once it's
    /// known, the data no area keeps any more is removed, once a day
    func notePlacesInUse() {
        PlacesInUse.set(.start, origin.map { [$0.coordinate] } ?? [])
        PlacesInUse.set(.favorites, SharedStore.favoritePlaces.map(\.coordinate))
        guard !isDemo, let origin else { return }
        let area = MetroArea.of(origin.coordinate)
        if let area { DownloadedData.noteChosen([area]) }
        AreaUsage.note(area)
        if !TransitModel.isTestHost { DownloadedData.cleanUpIfDue() }
    }

    /// Subway: refreshes several parts together (PATH, light rail and the tram all count as subway, grouped together).
    /// 1. MTA subway: the realtime feeds used by nearby stations;
    /// 2. Roosevelt Island Tram: estimated from the headways on RIOC's website;
    /// 3. PATH (realtime only, stations from its timetable data) and light rail (timetable): use stored data first (no network),
    ///    download in the background if never downloaded or the monthly check is due, then refresh again when done (no waiting; MTA departures show first).
    private func refreshSubway(now: Date) {
        guard let catalog else {
            // Detailed reasons go to the system log; the UI uses wording ordinary users understand
            AppLog.data.error("Reading the subway station list failed: \(self.catalogError ?? "", privacy: .public)")
            lastError = l10n.t("Couldn't load the subway station list. Try reinstalling Catch My Train.")
            return
        }
        isRefreshing = true
        let loader = MTARealtimeLoader(catalog: catalog, express: express)
        // A starting point in Philadelphia or Greater Boston whose SEPTA Metro or MBTA subway isn't on this Mac yet counts as missing
        // data (see FerryStore.subwayPart)
        let near = origin?.coordinate
        refreshTask = Task { [weak self] in
            let part = await FerryStore.subwayPart(allowNetwork: false, now: now, near: near)
            guard let self, !Task.isCancelled, self.system == .subway else { return }
            if self.subwayPartsMissing != part.missing { self.subwayPartsMissing = part.missing }
            self.downloadSubwayPartIfDue(now: now, before: part.feed, near: near)
            if self.ferryFeed != part.feed {
                self.ferryFeed = part.feed
                // Now that PATH and light rail stations are available, pick nearby stations again
                self.stations = self.currentStations()
                self.updateWalks()
                self.requestRoutesIfNeeded()
            }
            // The stations without times have nothing to download
            let ids = self.timedStations.map(\.id)
            let piers = ids.filter { self.isTimetableStation($0) }
            let subwayIDs = ids.filter { !RooseveltIslandTram.isTramStation($0) && !self.isTimetableStation($0) }
            let hasPath = piers.contains { FerryFeed.Source.path.owns(id: $0) }
            // NJ Transit's light rail: live data is downloaded only where the account makes its times live (liveWithAccount). Its
            // live data has no light rail predictions today, so nothing is downloaded for it
            let wantsLightRail = FerryFeed.Source.njTransitLightRail.liveWithAccount && self.hasNJTransitAccount
                && piers.contains { FerryFeed.Source.njTransitLightRail.owns(id: $0) }
            // SEPTA Metro and the MBTA's subway: free live data (each in one feed with its company's buses)
            let freeLive = FerryFeed.Source.freeLiveLightRail.filter { source in piers.contains { source.owns(id: $0) } }
            // MTA, PATH and light rail download side by side, so one slow server doesn't hold up the others
            async let mtaLoad = Self.realtimeLoad(loader, stationIDs: subwayIDs)
            async let pathFetch = Self.pathLive(wanted: hasPath)
            async let lightRailFetch = Self.lightRailLive(wanted: wantsLightRail)
            async let freeLiveFetch = Self.freeLightRailLive(freeLive)
            let load = await mtaLoad
            let pathLive = await pathFetch
            var lightRailLive: [FerryRealtime] = []
            if let result = await lightRailFetch {
                lightRailLive = result.realtime
                self.noteNJTransit(asked: [.njTransitLightRail], result: result)
            }
            var freeLiveFailed: [FerryFeed.Source] = []
            if let result = await freeLiveFetch {
                lightRailLive += result.realtime
                freeLiveFailed = result.failed
            }
            guard !Task.isCancelled, self.system == .subway else { return }
            // In the trains' time (see ClockSkew), as the ferries' refresh does
            let t = ClockSkew.now()
            // Use the arrival time window from Settings (plus 15 minutes, so widgets have trains to show between updates)
            let window = self.effectiveSettings.sanitized().arrivalWindowSeconds + 15 * 60
            let from = t.addingTimeInterval(-60), to = t.addingTimeInterval(window)
            var notices: [StationNotice] = []

            // PATH and light rail (timetable computation and merging with realtime data scan the departures, so do it on a background thread)
            var timetable: [Arrival] = []
            if let feed = part.feed, !piers.isEmpty {
                // The last realtime PATH departures: new ones take their IDs (PATH trains have no trip number, see PathLive.arrivals);
                // when PATH realtime data failed to download, they are kept (they turn into "not enough info" over time)
                let lastPath = hasPath ? self.arrivals.filter { $0.source == .realtime && FerryFeed.isPathRoute($0.route) } : []
                let oldPath = pathLive == nil ? lastPath : []
                if hasPath, pathLive == nil, let e = self.l10n.realtimeError(.subway, failed: [.path]) {
                    notices.append(StationNotice(text: e, stationIDs: Set(piers.filter { FerryFeed.Source.path.owns(id: $0) })))
                }
                // SEPTA Metro's or the MBTA subway's live data didn't download: its times are the timetable's, noted at its stations
                for source in freeLiveFailed {
                    if let e = self.l10n.realtimeError(.subway, failed: [source]) {
                        notices.append(StationNotice(text: e, stationIDs: Set(piers.filter { source.owns(id: $0) })))
                    }
                }
                // PATH's live data names every station: the codes this version doesn't know (UnknownData), for Settings
                if let pathLive {
                    self.pathLiveUnknown = Set(pathLive.trains.map(\.station).filter { PathLive.stationNames[$0] == nil })
                }
                let live = pathLive, lightRail = lightRailLive
                timetable = await offMain {
                    // For the log: how many of the timetable's NJ Transit light rail trips (all days) the rail live data has, the first
                    // time after launch and then at most every 10 minutes, to tell whether that data covers light rail at all
                    if let njl = lightRail.first(where: { $0.source == .njTransitLightRail }) {
                        let name = FerryFeed.Source.njTransitLightRail.name
                        LiveMatchLog.note(name + " trips", every: 10 * 60) {
                            let matched = njl.matchedTrips(in: feed)
                            return ["\(name): \(matched.live) of the timetable's \(matched.trips) trips (all days) are in "
                                    + "\(FerryFeed.Source.njTransitRail.name) live data"]
                        }
                    }
                    let all = feed.arrivals(pierIDs: piers, from: from, to: to, realtime: lightRail, now: t)
                    let pathTimetable = all.filter { FerryFeed.isPathRoute($0.route) }
                    var path = pathTimetable
                    if hasPath {
                        let current = live.map { $0.arrivals(feed: feed, pierIDs: piers, from: from, to: to, previous: lastPath) } ?? oldPath
                        path = PathLive.merge(live: current, timetable: pathTimetable, feed: feed)
                    }
                    return path + all.filter { !FerryFeed.isPathRoute($0.route) }
                }
                guard !Task.isCancelled, self.system == .subway else { return }
            }

            // MTA subway
            var mtaArrivals: [Arrival] = []
            if let load {
                self.feedStatuses = load.statuses
                if load.allFailed {
                    // All failed: keep the old data (it turns into "not enough info" over time)
                    mtaArrivals = self.arrivals.filter {
                        !self.isTimetableStation($0.stationID) && !RooseveltIslandTram.isTramStation($0.stationID)
                    }
                    notices.insert(StationNotice(text: self.l10n.t("Couldn't get MTA real-time data. Check your network. Showing the last data received."),
                                                 stationIDs: Set(subwayIDs)), at: 0)
                } else {
                    // Partly failed: replace the feeds that succeeded, keep the old data for failed feeds (it expires naturally)
                    let oldSubway = self.arrivals.filter {
                        !self.isTimetableStation($0.stationID) && !RooseveltIslandTram.isTramStation($0.stationID)
                    }
                    mtaArrivals = load.merged(keeping: oldSubway)
                    if !load.failedFeeds.isEmpty {
                        notices.insert(StationNotice(text: self.l10n.f("Some feeds failed to load: %@", self.l10n.commaList(load.failedFeeds.map(\.displayName))),
                                                     feeds: Set(load.failedFeeds)), at: 0)
                    }
                }
            } else {
                self.feedStatuses = []
            }
            // PATH or light rail data missing and not downloadable: no station comes from it to note it at,
            // so it's noted once at the bottom of the board (missingTimetableNote) or in the empty state

            self.arrivals = mtaArrivals + self.tramArrivals(now: t) + timetable
            // When only PATH is nearby, "Data updated" uses the PATH realtime data's time
            if hasPath {
                self.ferryUpdatedAt = pathLive?.updatedAt ?? pathLive?.fetchedAt ?? self.ferryUpdatedAt ?? t
            } else {
                self.ferryUpdatedAt = piers.isEmpty ? nil : t
            }
            self.isRefreshing = false
            // Network turned off in Settings: write only "Network is off…", not the various connection failures
            self.lastError = self.networkOffNote
            self.stationNotices = notices
            self.saveSnapshot(refreshDone: true)
        }
    }


    /// The parts of a subway refresh, each one only when it's needed (nil otherwise), so they can run side by side
    nonisolated private static func realtimeLoad(_ loader: MTARealtimeLoader, stationIDs: [String]) async -> RealtimeLoad? {
        stationIDs.isEmpty ? nil : await loader.load(stationIDs: stationIDs)
    }

    nonisolated private static func pathLive(wanted: Bool) async -> PathLive? {
        wanted ? await FerryStore.fetchPathLive() : nil
    }

    nonisolated private static func lightRailLive(wanted: Bool)
        async -> (realtime: [FerryRealtime], failed: [FerryFeed.Source], rejected: Bool)? {
        wanted ? await FerryStore.fetchRealtime([.njTransitLightRail]) : nil
    }

    nonisolated private static func freeLightRailLive(_ sources: [FerryFeed.Source])
        async -> (realtime: [FerryRealtime], failed: [FerryFeed.Source], rejected: Bool)? {
        sources.isEmpty ? nil : await FerryStore.fetchRealtime(sources)
    }

    /// - Parameter before: The stored data just read during refresh (no need to read it again)
    /// - Parameter near: the starting point (see FerryStore.subwayPart)
    private func downloadSubwayPartIfDue(now: Date, before: FerryFeed?, near: Coordinate?) {
        guard subwayDownloadTask == nil else { return }
        subwayDownloadTask = Task { [weak self] in
            let after = await FerryStore.subwayPart(allowNetwork: true, now: now, near: near)
            // Cancelled (standby, or a switch to another mode): whoever cancelled it cleared the handle, which may belong to a newer download by now
            guard let self, !Task.isCancelled else { return }
            self.subwayDownloadTask = nil
            guard self.isActive, self.system == .subway else { return }
            let failedBefore = self.ferryDownloadFailed
            self.ferryDownloadFailed = after.failed
            // What's missing for the starting point it downloaded for: one chosen meanwhile had its own refresh, which said so already
            if self.origin?.coordinate == near, self.subwayPartsMissing != after.missing { self.subwayPartsMissing = after.missing }
            // Refresh with the new data, and also right after a download fails (the widget then says so too); a failure
            // that's still the same doesn't refresh again (within its retry wait the store fails at once, see FerryStore.ensure)
            if after.feed?.versions != before?.versions || after.failed != failedBefore { self.refresh() }
        }
    }

    /// Bus: refreshes two parts together (buses cover the whole metro area).
    /// 1. NJ Transit and the other timetable-only agencies: make sure data exists first (checked online on first use or after the 1st of each month), take just the nearby chunk, compute departures from the timetable;
    /// 2. MTA bus stops: query MTA Bus Time once per nearby stop (needs the key entered in Settings).
    /// When only one kind is nearby, the other does nothing.
    func refreshBus(now: Date) {
        feedStatuses = []
        isRefreshing = true
        // Bus stop catalog not loaded yet: load it in the background first (see ensureBusCatalogLoaded); it refreshes again once loaded
        if busCatalogStorage == nil, !busCatalogFailed {
            ensureBusCatalogLoaded()
            return
        }
        let near = origin?.coordinate
        let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
        // Keys are read once in the background at launch and kept (see loadKeys); updated when keys are saved or deleted. Skip MTA bus until they're loaded
        let key = busKeyCache ?? nil
        // The day goes by the start place's area (outside them all, this Mac's), as its times do
        let zone = l10n.timeZone
        refreshTask = Task { [weak self] in
            let store = FerryStore.njBus
            // Use stored timetables first (no network), so MTA bus realtime data doesn't wait for the agencies' timetables to download (tens of MB the first time)
            let slice = await store.load(near: near, radius: radius)
            // A company downloaded only for places in its area (SEPTA) and not on this Mac yet, though the starting point is there
            var lacking = false
            if let near { lacking = await store.lacksOperators(at: near) }
            guard let self, !Task.isCancelled, self.system == .bus else { return }
            if self.busOperatorsMissing != lacking { self.busOperatorsMissing = lacking }
            let day = Timetable.dayNumber(now, in: zone)
            var feed: FerryFeed?
            if let slice {
                if let memo = self.busActiveMemo, memo.day == day, memo.input == slice {
                    feed = memo.output
                } else {
                    let output = await offMain { slice.active(from: now) }
                    guard !Task.isCancelled, self.system == .bus else { return }
                    self.busActiveMemo = (day, slice, output)
                    feed = output
                }
            } else {
                self.busActiveMemo = nil
            }
            self.downloadBusTimetablesIfDue(near: near, radius: radius, now: now, before: slice)
            if self.ferryFeed != feed {
                self.ferryFeed = feed
                // Now that the timetable agencies' stops are available, pick nearby stops again
                self.stations = self.currentStations()
                self.updateWalks()
                self.requestRoutesIfNeeded()
            }
            let mta = self.stations.filter { !self.isTimetableStation($0.id) }
            let piers = self.stations.map(\.id).filter { self.isTimetableStation($0) }
            // Nearby stops from CTtransit, Bee-Line (free), NJ Transit (account set) or Suffolk (key set): download their realtime data along with MTA's
            let suffolkKey = self.suffolkKey
            let realtimeFeeds = feed == nil ? [] : RegionalBusFeed.realtimeFeeds(stationIDs: piers, hasAccount: self.hasNJTransitAccount,
                                                                                 hasSuffolkKey: suffolkKey != nil)
            if !realtimeFeeds.isEmpty, self.busTripKeep == nil { self.busTripKeep = Set(feed?.trips.map(\.id) ?? []) }
            let keep = self.busTripKeep ?? []
            let nearby = feed
            async let busRealtime = FerryStore.fetchBusRealtime(realtimeFeeds, keep: keep, nearby: nearby,
                                                                suffolkKey: suffolkKey)   // returns immediately when there are none
            var load: BusLoad?
            var fetched = false
            let stopIDs = mta.map(\.id)
            if let key, !mta.isEmpty, let busCatalog = self.busCatalog {
                // Asked for the same stops less than a minute ago (a refresh every 30 seconds, a Refresh button, a small move, new
                // timetable data): reuse that answer, so Bus Time gets at most about one round of requests a minute with the user's key
                if let kept = self.busLoadMemo.reusable(stops: stopIDs, now: now) {
                    load = kept
                } else {
                    load = await BusTimeLoader(key: key, catalog: busCatalog).load(stations: mta)
                    fetched = true
                }
            }
            let rt = await busRealtime
            guard !Task.isCancelled, self.system == .bus else { return }
            // Only an answer from a refresh that wasn't stopped (a stopped one may hold stops that failed because of the stop),
            // and only for the key still in use. Its age counts from this refresh's start, as the timed refreshes do
            if fetched, let load, self.busTimeKey == key { self.busLoadMemo.keep(load, stops: stopIDs, startedAt: now) }
            // In the trains' time (see ClockSkew), as the ferries' refresh does
            let t = ClockSkew.now()
            let window = self.effectiveSettings.sanitized().arrivalWindowSeconds + 15 * 60
            let busFeed = feed, live = rt.realtime
            let timetable = await offMain {
                busFeed.map {
                    $0.arrivals(pierIDs: piers, from: t.addingTimeInterval(-60), to: t.addingTimeInterval(window), realtime: live, now: t)
                } ?? []
            }
            guard !Task.isCancelled, self.system == .bus else { return }
            self.ferryUpdatedAt = feed == nil ? nil : t
            var note: String?
            if realtimeFeeds.contains(where: \.needsAccount) {
                if rt.rejected {
                    self.njTransitBusRejected = true
                    self.noteCheck(.njTransitBus, .rejected)
                    if !self.njTransitRejected { self.noteNJTransitRefusal(from: FerryStore.njTransitBus) }
                } else if rt.realtime.contains(where: { $0.prefix == RegionalBusFeed.njTransit.idPrefix }) {
                    self.njTransitBusRejected = false
                    self.noteCheck(.njTransitBus, .works)
                }
            }
            // Only the companies asked this time: one with no stop near here is forgotten (see failedAfterRefresh)
            let failedNow = RegionalBusFeed.failedAfterRefresh(asked: Set(realtimeFeeds.map(\.code)), failed: Set(rt.failed))
            if failedNow != self.busRealtimeFailed { self.busRealtimeFailed = failedNow }
            if realtimeFeeds.contains(where: \.needsKey) {
                if rt.keyRejected {
                    self.suffolkKeyRejected = true
                    self.noteCheck(.suffolk, .rejected)
                } else if rt.realtime.contains(where: { $0.prefix == RegionalBusFeed.feed(code: "SCT")?.idPrefix }) {
                    self.suffolkKeyRejected = false
                    self.noteCheck(.suffolk, .works)
                }
            }
            // A bus company whose live data failed (or whose account or key was refused) is noted only at the stops it serves
            // (scheduleOnlyText via busRealtimeFailed), never over every stop: a stop with only MTA buses shows no such notice
            if self.busCatalogFailed {
                note = self.l10n.t("Couldn't load the bus stop list. Try reinstalling Catch My Train.")
            }
            self.applyBus(load, mtaStops: stopIDs, hasKey: key != nil, timetable: timetable, realtimeNote: note)
        }
    }


    /// - Parameter before: The nearby chunk just read during refresh (no need to read it again)
    private func downloadBusTimetablesIfDue(near: Coordinate?, radius: Double, now: Date, before: FerryFeed?) {
        guard busDownloadTask == nil else { return }
        busDownloadTask = Task { [weak self] in
            let store = FerryStore.njBus
            var failed = false
            var stopped = false
            var after: FerryFeed?
            do {
                after = try await store.ensure(allowNetwork: true, now: now, near: near, radius: radius)
            } catch {
                // Stopped by standby: not a failed download
                stopped = NetworkReach.isCancellation(error)
                failed = before == nil && !stopped
            }
            // A company downloaded only for places in its area (SEPTA) still missing for the starting point: its download failed
            var lacking = false
            if let near { lacking = await store.lacksOperators(at: near) }
            if lacking, !stopped { failed = true }
            // Cancelled by standby: standby cleared the handle, which may belong to a newer download by now
            guard let self, !Task.isCancelled else { return }
            self.busDownloadTask = nil
            guard self.isActive, self.system == .bus else { return }
            let failedBefore = self.ferryDownloadFailed
            self.ferryDownloadFailed = failed
            // For the starting point it downloaded for: one chosen meanwhile had its own refresh, which said so already
            if self.origin?.coordinate == near, self.busOperatorsMissing != lacking { self.busOperatorsMissing = lacking }
            // Refresh with the new data, and right after a download fails (see downloadSubwayPartIfDue)
            if let after, after != before { self.refresh() } else if failed != failedBefore { self.refresh() }
        }
    }

    /// Problems with MTA Bus Time are noted only at MTA stops; missing timetables of the other companies once at the bottom (missingTimetableNote)
    private func applyBus(_ load: BusLoad?, mtaStops: [String], hasKey: Bool, timetable: [Arrival], realtimeNote: String? = nil) {
        isRefreshing = false
        // Last MTA departures (failed stops are kept and expire naturally)
        let oldMTA = arrivals.filter { !isTimetableStation($0.stationID) }
        var mtaArrivals: [Arrival] = []
        var error: String?
        var notices: [StationNotice] = []
        func note(_ text: String, at stops: [String]) { notices.append(StationNotice(text: text, stationIDs: Set(stops))) }
        if mtaStops.isEmpty {
            busError = nil
            busFetchedAt = nil
            busResponseTime = nil
        } else if !hasKey {
            // The main view has a dedicated notice and an "Add Key" button at the top (no notice while the Keychain isn't read yet)
            busError = keysLoaded ? .missingKey : nil
        } else if let load {
            busError = load.mainError
            // What this download showed about the key ("Live" only once it worked)
            if load.allFailed, load.mainError == .invalidKey { noteCheck(.busTime, .rejected) }
            else if !load.arrivals.isEmpty || load.errors.isEmpty { noteCheck(.busTime, .works) }
            if load.allFailed {
                mtaArrivals = oldMTA
                switch load.mainError {
                case .invalidKey?:
                    note(l10n.t("MTA Bus Time didn't accept your key. Check it in Settings."), at: mtaStops)
                case .missingKey?:
                    break
                default:
                    note(l10n.t("Couldn't get MTA Bus Time data. Check your network. Showing the last data received."), at: mtaStops)
                }
            } else {
                // Failed stops keep their old departures (they expire naturally); successful stops get new ones
                let failed = Set(load.errors.keys)
                mtaArrivals = load.arrivals + oldMTA.filter { failed.contains($0.stationID) }
                busFetchedAt = load.fetchedAt
                busResponseTime = load.responseTime ?? load.fetchedAt
                if !failed.isEmpty {
                    note(l10n.t("Some bus stops couldn't be loaded. Showing the last data received for them."), at: Array(failed))
                }
            }
        } else {
            // Couldn't read the MTA bus stop catalog
            error = l10n.t("Couldn't load the bus stop list. Try reinstalling Catch My Train.")
        }
        // Timetables missing and not downloadable: none of the other companies' stops is known to note it at, so it's noted once
        // at the bottom of the board (missingTimetableNote), or in the empty state when no stop is nearby
        arrivals = mtaArrivals + timetable
        lastError = networkOffNote ?? error ?? realtimeNote
        stationNotices = notices
        saveSnapshot(refreshDone: true)
    }
}
