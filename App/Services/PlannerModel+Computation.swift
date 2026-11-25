import Foundation
import MapKit
import TransitCore

extension PlannerModel {
    // MARK: Computation

    /// Recomputes for the selected place and departure time.
    /// delay: when the departure time changes, wait until the user stops before querying (holding the arrow keys won't go online on every press)
    func update(transit: TransitModel, delay: TimeInterval = 0) {
        startDelay = delay
        stopped = false
        computedWith = (transit.isActive, transit.system, transit.isDemo)
        if transit.isDemo {
            updateDemo(transit: transit)
            return
        }
        // Its metro area's data is downloaded and kept while this place is in use (see AreaData), also an area the user removed, and
        // counts as used now (AreaUsage: the order of Settings' area menu, and when an unused area's data goes)
        let area = place.flatMap { MetroArea.of($0.coordinate) }
        PlacesInUse.set(.planner, place.map { [$0.coordinate] } ?? [])
        if let area { DownloadedData.noteChosen([area]) }
        AreaUsage.note(area)
        // Places outside the service area can be picked too; we just explain they're unsupported and don't look up departures
        if let place, !UserPlace.isInServiceArea(place.coordinate) {
            task?.cancel()
            stations = []
            walks = [:]
            arrivals = []
            dataKind = nil
            computedLeaveAt = nil
            status = .failed(Note { $0.t("This place is outside the areas the app covers, so there are no departures to show here.") })
            return
        }
        if transit.isBus {
            updateBus(transit: transit)
            return
        }
        if transit.usesTimetable {
            updateFerry(transit: transit)
            return
        }
        // Stop the previous computation first, also when the station list isn't ready yet
        task?.cancel()
        guard let place, let catalog = transit.catalog else { return }
        let express = transit.express
        let settings = walkSettings(transit)
        let leave = Self.effectiveLeave(leaveAt)
        let window = windowSeconds
        let radius = settings.extendedCandidateRadiusMeters + 100
        // Roosevelt Island Tram counts as subway too (departures estimated from RIOC's website headways, queryable at any time)
        let near = catalog.stations(near: place.coordinate, radiusMeters: radius)
            + RooseveltIslandTram.stations(near: place.coordinate, radiusMeters: radius)
        stations = near
        walks = Self.estimate(from: place.coordinate, stations: near, settings: settings, routes: [:])
        // PATH trains have no trip number: their IDs follow the last computation's (see PathLive.arrivals)
        let lastPath = arrivals.filter { $0.source == .realtime && FerryFeed.isPathRoute($0.route) }
        arrivals = []
        computedLeaveAt = leave
        status = .loading
        let tram = RooseveltIslandTram.arrivals(stationIDs: near.map(\.id), from: leave,
                                                to: leave.addingTimeInterval(window),
                                                hours: transit.tramHours, now: Date())

        let allowNetwork = transit.isActive
        let networkOff = !transit.networkAllowed && !transit.isDemo
        let live = Self.usesRealtime(leave: leave)

        let delay = startDelay
        task = Task { [weak self] in
            guard await Self.settle(delay) else { return }
            // PATH and light rail count as subway too: timetables are already on this Mac (if missing, download first while started)
            let subway = await FerryStore.subwayPart(allowNetwork: allowNetwork, now: Date(), near: place.coordinate)
            let part = subway.feed
            let feed = await offMain { part?.active(from: leave) }
            guard !Task.isCancelled else { return }
            let piers = feed?.stations(near: place.coordinate, radiusMeters: radius) ?? []
            // The AirTrain stations without times too (NoTimesStations): listed after the others, with nothing to download
            let all = near + piers + NoTimesStations.stations(.subway, near: place.coordinate, radiusMeters: radius)
            // Fetch the walking route (Apple Maps) and departures at the same time
            async let routeMeters = Self.walkRoutes(allowNetwork, from: place.coordinate, to: all)
            var kind: DataKind
            var list: [Arrival] = []
            var failure: Note?
            let ids = near.map(\.id).filter { !RooseveltIslandTram.isTramStation($0) }
            if live {
                kind = .realtime
                if !ids.isEmpty, !allowNetwork {
                    // Standby = no network
                    failure = Self.needingNetwork(Note { $0.t("Turn the app on to get live times.") }, networkOff: networkOff)
                } else if !ids.isEmpty {
                    let load = await MTARealtimeLoader(catalog: catalog, express: express).load(stationIDs: ids)
                    list = load.arrivals
                    if load.allFailed {
                        // Nothing earlier is kept here (each computation starts empty), so the note doesn't say it shows any
                        failure = Self.needingNetwork(Note { $0.liveDataFailed(ofOperator: ModeCoverage.subwayID) },
                                                      networkOff: networkOff)
                    }
                }
            } else if ids.isEmpty {
                // No MTA station near the place: the MTA timetable (about 6 MB) isn't needed, so it isn't downloaded
                kind = .scheduled(validUntil: nil, mta: false)
            } else {
                do {
                    let timetable = try await TimetableStore.shared.timetable(for: leave, allowNetwork: allowNetwork)
                    kind = .scheduled(validUntil: timetable.validUntil)
                    if timetable.covers(leave) {
                        list = await offMain {
                            timetable.arrivals(stationIDs: ids, from: leave, to: leave.addingTimeInterval(window), catalog: catalog)
                        }
                    } else {
                        failure = Note { $0.t("The MTA timetable doesn't cover that date yet.") }
                    }
                } catch {
                    kind = .scheduled(validUntil: nil)
                    // An operator's own problem says so instead of asking to check the network (see downloadFailedText)
                    failure = Self.needingNetwork(
                        allowNetwork ? Note { $0.downloadFailedText($0.t("Couldn't download the MTA timetable. Check your network."),
                                                                    problems: TransitModel.timetableNotices(providers: ["MTA"])) }
                            : Note { $0.t("Turn the app on to download the MTA timetable.") },
                        networkOff: networkOff)
                }
            }
            // PATH has only realtime data (within 30 minutes); light rail uses the timetable, and SEPTA Metro and the MBTA's subway
            // their free live data when leaving now
            var feedArrivals: [Arrival] = []
            if let feed, !piers.isEmpty {
                let from = leave.addingTimeInterval(-60), to = leave.addingTimeInterval(window)
                let pierIDs = piers.map(\.id)
                let freeLive = FerryFeed.Source.freeLiveLightRail.filter { source in pierIDs.contains { source.owns(id: $0) } }
                var lightRailLive: [FerryRealtime] = []
                if live, !freeLive.isEmpty {
                    if allowNetwork {
                        let result = await FerryStore.fetchRealtime(freeLive)
                        lightRailLive = result.realtime
                        if let failed = result.failed.first {
                            failure = failure ?? Self.needingNetwork(Note { $0.realtimeError(.subway, failed: [failed]) ?? "" },
                                                                     networkOff: networkOff)
                        }
                    } else {
                        failure = failure ?? Self.needingNetwork(Note { $0.t("Turn the app on to get live times.") }, networkOff: networkOff)
                    }
                }
                let liveTimes = lightRailLive
                let timetable = await offMain { feed.arrivals(pierIDs: pierIDs, from: from, to: to, realtime: liveTimes, now: Date()) }
                feedArrivals = timetable.filter { !FerryFeed.isPathRoute($0.route) }
                let hasPath = piers.contains { FerryFeed.Source.path.owns(id: $0.id) }
                if hasPath, !live {
                    failure = failure ?? Note {
                        $0.t("For PATH, only live times are available, so Plan a Trip works only when you leave within the next 30 minutes.")
                    }
                } else if hasPath {
                    var pathLive: PathLive?
                    if allowNetwork { pathLive = await FerryStore.fetchPathLive() }
                    let liveArrivals = pathLive?.arrivals(feed: feed, pierIDs: piers.map(\.id), from: from, to: to, previous: lastPath) ?? []
                    feedArrivals += PathLive.merge(live: liveArrivals,
                                                   timetable: timetable.filter { FerryFeed.isPathRoute($0.route) }, feed: feed)
                    if pathLive == nil {
                        failure = failure ?? Self.needingNetwork(allowNetwork ? Note { $0.liveDataFailed(ofOperator: FerryFeed.Source.path.rawValue) }
                                                                     : Note { $0.t("Turn the app on to get PATH live times.") },
                                                                 networkOff: networkOff)
                    }
                }
            }
            // PATH's or light rail's data (with SEPTA Metro's or the MBTA subway's, for a place in its area) missing and not downloadable
            if subway.failed {
                let missing = subway.missing
                failure = failure ?? Self.needingNetwork(Note {
                    $0.downloadFailedText($0.t("Couldn't download the subway and light rail data. Check your network."),
                                          problems: TransitModel.timetableNotices(missing))
                }, networkOff: networkOff)
            }
            let meters = await routeMeters
            guard let self, !Task.isCancelled else { return }
            self.feedRoutes = feed?.routesByPier()
            self.stations = all
            self.walks = Self.estimate(from: place.coordinate, stations: all, settings: settings, routes: meters)
            self.arrivals = list + tram + feedArrivals
            self.dataKind = kind
            self.status = failure.map { .failed($0) } ?? .ready
        }
    }

    /// Demo mode: its own stations near the place in Manhattan, with made-up times from the same service as the main window's (the
    /// same station shows the same times at the same moment), live or the timetables' as for real, with the note the real trip
    /// planner gives then (MockTransitData.demoPlan). Nothing goes online: no timetables, no live data, no walking routes (the
    /// walks are straight-line estimates, as in the main window)
    private func updateDemo(transit: TransitModel) {
        task?.cancel()
        guard let place else { return }
        let settings = walkSettings(transit)
        let leave = Self.effectiveLeave(leaveAt)
        let window = windowSeconds
        let radius = settings.extendedCandidateRadiusMeters + 100
        let system = transit.system
        let active = transit.isActive
        let live = Self.usesRealtime(leave: leave)
        // The service the main window's times were last made from (none yet: from now on)
        let base = transit.demoTimesBase ?? (at: BoardClock.now(), seed: transit.refreshCount)
        let hours = transit.tramHours
        feedRoutes = nil
        arrivals = []
        computedLeaveAt = leave
        dataKind = nil
        status = .loading
        let delay = startDelay
        task = Task { [weak self] in
            guard await Self.settle(delay) else { return }
            // Bus stops are picked from the bus stop list, which may still be loading
            var buses = transit.busCatalog
            if system.mode == .bus { buses = await transit.loadedBusCatalog() }
            guard let self, !Task.isCancelled else { return }
            let now = BoardClock.now()
            let plan = MockTransitData.demoPlan(system, near: place.coordinate, radiusMeters: radius, leave: leave, window: window,
                                                live: live, active: active, catalog: transit.catalog, buses: buses,
                                                base: base.at, seed: base.seed, now: now)
            // The tram's times are estimated from its hours, as always
            let tram = RooseveltIslandTram.arrivals(stationIDs: plan.stations.map(\.id), from: leave,
                                                    to: leave.addingTimeInterval(window), hours: hours, now: now)
            self.stations = plan.stations
            self.walks = Self.estimate(from: place.coordinate, stations: plan.stations, settings: settings, routes: [:])
            self.arrivals = plan.arrivals + tram
            self.dataKind = plan.live ? .realtime : .scheduled(validUntil: nil)
            if let note = plan.note {
                self.status = .failed(Self.demoNote(note))
            } else {
                self.status = .ready
            }
        }
    }

    /// Demo mode's notes, in the real trip planner's words
    private static func demoNote(_ note: MockTransitData.DemoPlanNote) -> Note {
        switch note {
        case .turnOnForLiveTimes:
            return Note { $0.t("Turn the app on to get live times.") }.offering(.start)
        case .pathLiveOnly:
            return Note { $0.t("For PATH, only live times are available, so Plan a Trip works only when you leave within the next 30 minutes.") }
        case .turnOnForPathLiveTimes:
            return Note { $0.t("Turn the app on to get PATH live times.") }.offering(.start)
        case .mtaBusLiveOnly:
            return Note { $0.t("For MTA buses, only live times are available, so they appear only when you leave within the next 30 minutes.") }
        }
    }

    /// Bus: two parts combined.
    /// - MTA bus: MTA doesn't provide a conveniently downloadable bus timetable for this app (the feeds are huge), so only realtime data is used,
    ///   queryable only for departures within 30 minutes (needs a Bus Time key). Only the stops Bus Time answered for are listed (it's asked
    ///   about the nearest BusTimeLoader.maxStops): a stop it wasn't asked about would look as if no bus came. When it can't be asked, the
    ///   note says why;
    /// - NJ Transit and the other agencies: timetables are already on this Mac (only the chunk near this place), queryable at any time. Of the
    ///   many stops along a street, the nearest one for each route and direction is listed (FerryFeed.nearestPerRouteDirection).
    private func updateBus(transit: TransitModel) {
        guard let place else { return }
        transit.ensureBusCatalogLoaded()
        task?.cancel()
        let settings = walkSettings(transit)
        let leave = Self.effectiveLeave(leaveAt)
        let window = windowSeconds
        let radius = settings.extendedCandidateRadiusMeters + 100
        let live = Self.usesRealtime(leave: leave)
        let key = transit.busTimeKey
        let allowNetwork = transit.isActive
        let networkOff = !transit.networkAllowed && !transit.isDemo
        let hasAccount = transit.hasNJTransitAccount
        let suffolkKey = transit.suffolkKey
        // Nothing is listed until the stops are known (the results show that they're loading)
        stations = []
        walks = [:]
        arrivals = []
        computedLeaveAt = leave
        // On standby nothing goes online, so even departures leaving now are from the timetables
        dataKind = live && allowNetwork ? .realtime : .scheduled(validUntil: nil)
        status = .loading
        let delay = startDelay
        let lastBus = lastBusLoad
        // A refresh of the live times shown (refreshLive), and how long live data counts as fresh (as in the main window)
        let isRefresh = refreshing
        let staleAfter = transit.effectiveSettings.realtimeStaleAfterSeconds
        task = Task { [weak self] in
            guard await Self.settle(delay) else { return }
            // The bus stop catalog may still be loading (the first search after a launch on standby): wait for it, or every MTA stop is missing
            let busCatalog = await transit.loadedBusCatalog()
            let catalogFailed = transit.busCatalogFailed
            // The stops Bus Time is asked about, nearest first
            let mtaNear = Array((busCatalog?.stations(near: place.coordinate, radiusMeters: radius) ?? []).prefix(BusTimeLoader.maxStops))
            var feed: FerryFeed?
            // Make sure data exists first (download if needed), then take the chunk near this place (without replacing the main view's chunk)
            _ = try? await FerryStore.njBus.ensure(allowNetwork: allowNetwork)
            let slice = await FerryStore.njBus.detachedSlice(near: place.coordinate, radius: radius)
            // A company downloaded only for places in its area (SEPTA) and still not on this Mac for this place
            let lacking = await FerryStore.njBus.lacksOperators(at: place.coordinate)
            feed = await offMain { slice?.active(from: leave) }
            guard let self, !Task.isCancelled else { return }
            let piers = feed.map { $0.nearestPerRouteDirection($0.stations(near: place.coordinate, radiusMeters: radius)) } ?? []
            self.feedRoutes = feed?.routesByPier()
            // Walking routes (Apple Maps) at the same time as the times, to the stops expected to be listed
            let asksBusTime = live && allowNetwork && key != nil && busCatalog != nil
            async let routeMeters = Self.walkRoutes(allowNetwork, from: place.coordinate, to: (asksBusTime ? mtaNear : []) + piers)
            // Departing now: realtime data from CTtransit, Bee-Line, NJ Transit (account set) and Suffolk (key set)
            let realtimeFeeds = live && allowNetwork
                ? RegionalBusFeed.realtimeFeeds(stationIDs: piers.map(\.id), hasAccount: hasAccount, hasSuffolkKey: suffolkKey != nil) : []
            let keep: Set<String> = realtimeFeeds.isEmpty ? [] : Set(feed?.trips.map(\.id) ?? [])
            let nearby = feed
            async let busRealtime = FerryStore.fetchBusRealtime(realtimeFeeds, keep: keep, nearby: nearby, suffolkKey: suffolkKey)
            var load: BusLoad?
            var fetchedBus = false
            let mtaIDs = mtaNear.map(\.id)
            if live, allowNetwork, let key, let busCatalog, !mtaNear.isEmpty {
                // If the same set of stops was queried within 60 seconds, reuse it (so changing the departure time doesn't query with your key every time)
                if let lastBus, lastBus.stations == mtaIDs, Date().timeIntervalSince(lastBus.at) < 60 {
                    load = lastBus.load
                } else {
                    load = await BusTimeLoader(key: key, catalog: busCatalog).load(stations: mtaNear)
                    fetchedBus = true
                }
            }
            guard !Task.isCancelled else { return }
            if fetchedBus, let load, !load.allFailed { self.lastBusLoad = (mtaIDs, Date(), load) }
            // A refresh that couldn't reach Bus Time at all keeps the buses it got last for these stops while they're still fresh,
            // as the main window does: the note below says so ("Showing the last data received"). A refused key doesn't
            var shown = load
            if isRefresh, let failed = load, failed.allFailed, failed.mainError != .invalidKey, let lastBus,
               lastBus.stations == mtaIDs, Date().timeIntervalSince(lastBus.at) < staleAfter {
                shown = lastBus.load
            }
            // MTA stops only where Bus Time answered (none when it wasn't asked: the note below says why)
            let answered = shown.map { load in mtaNear.filter { load.errors[$0.id] == nil } } ?? []
            let near = answered + piers
            self.stations = near
            self.walks = Self.estimate(from: place.coordinate, stations: near, settings: settings, routes: [:])
            let meters = await routeMeters
            let rt = await busRealtime
            guard !Task.isCancelled else { return }
            self.walks = Self.estimate(from: place.coordinate, stations: near, settings: settings, routes: meters)
            let from = leave.addingTimeInterval(-60), to = leave.addingTimeInterval(window)
            let busFeed = feed, pierIDs = piers.map(\.id), liveTimes = rt.realtime
            let timetable = await offMain { busFeed?.arrivals(pierIDs: pierIDs, from: from, to: to, realtime: liveTimes, now: Date()) ?? [] }
            guard !Task.isCancelled else { return }
            self.arrivals = (shown?.arrivals ?? []) + timetable
            // Nothing live came in (a failed download, no key, or only timetable operators nearby): the times are the timetable's.
            // A Bus Time answer with no buses in the window is still live data.
            if shown.map({ $0.allFailed }) ?? true, rt.realtime.isEmpty { self.dataKind = .scheduled(validUntil: nil) }
            let busRoutes = piers.flatMap { self.feedRoutes?[$0.id] ?? [] }
            let failedOperators = Self.failedBusOperators(rt.failed, routes: busRoutes)
            // When MTA bus can't be queried, explain why (the timetable agencies still show)
            if !mtaNear.isEmpty, !live {
                self.status = .failed(Note {
                    $0.t("For MTA buses, only live times are available, so they appear only when you leave within the next 30 minutes.")
                })
            } else if !mtaNear.isEmpty, !allowNetwork {
                self.status = .failed(Self.needingNetwork(Note { $0.t("Turn the app on to get live times.") }, networkOff: networkOff))
            } else if !mtaNear.isEmpty, key == nil {
                self.status = .failed(Note { $0.t("Add your free MTA Bus Time key in Settings to see live bus times.") }.offering(.settings(.keys)))
            } else if let load, load.allFailed {
                // "Showing the last data received" only when the buses got last are shown (a refresh, see `shown` above)
                let keptLast = shown.map { !$0.allFailed } ?? false
                self.status = .failed(load.mainError == .invalidKey
                    ? Note { $0.t("MTA Bus Time didn't accept your key. Check it in Settings.") }.offering(.settings(.keys))
                    : Self.needingNetwork(keptLast
                        ? Note { $0.t("Couldn't get MTA Bus Time data. Check your network. Showing the last data received.") }
                        : Note { $0.liveDataFailed(ofOperator: ModeCoverage.mtaBusID) },
                                          networkOff: networkOff))
            } else if catalogFailed {
                // Same as the main view: without the list no MTA stop can be shown, which isn't the same as none nearby
                self.status = .failed(Note { $0.t("Couldn't load the bus stop list. Try reinstalling Catch My Train.") })
            } else if (feed == nil && mtaNear.isEmpty) || lacking {
                // On standby nothing downloads, so missing data isn't a network problem (same wording as the main view)
                self.status = .failed(Self.needingNetwork(
                    allowNetwork ? Note { $0.downloadFailedText($0.t("Couldn't download the bus timetables. Check your network."),
                                                                problems: TransitModel.timetableNotices([.njBus])) }
                        : Note { $0.t("Bus timetables are downloaded the first time you turn the app on.") },
                    networkOff: networkOff))
            } else if !failedOperators.isEmpty {
                // Those operators' times are the timetable's
                self.status = .failed(Self.needingNetwork(
                    Note { $0.f("Couldn't get %@ live data. Showing timetable times for now.", $0.joinedList(failedOperators)) },
                    networkOff: networkOff))
            } else {
                self.status = .ready
            }
        }
    }

    /// Ferry (train too): queryable at any time (timetables are already on this Mac; trains only cover the next few weeks).
    /// Within 30 minutes, also add realtime data from NYC Ferry and NY Waterway (LIRR, Metro-North).
    /// Staten Island Ferry, Seastreak and the Statue of Liberty ferry are always timetable-only.
    private func updateFerry(transit: TransitModel) {
        guard let place else { return }
        task?.cancel()
        let settings = walkSettings(transit)
        let leave = Self.effectiveLeave(leaveAt)
        let window = windowSeconds
        let radius = settings.extendedCandidateRadiusMeters + 100
        let live = Self.usesRealtime(leave: leave)
        let allowNetwork = transit.isActive
        arrivals = []
        computedLeaveAt = leave
        // On standby nothing goes online, so even departures leaving now are from the timetables
        dataKind = live && allowNetwork ? .realtime : .scheduled(validUntil: nil)
        status = .loading
        let store = FerryStore.store(for: transit.system)
        let system = transit.system
        let accounts = transit.accountSources
        // On standby nothing downloads, so missing data isn't a network problem (same wording as the main view); an operator's own
        // problem says so instead of asking to check the network (read when shown, after the download)
        let parts = system.timetableSystems
        let networkOff = !transit.networkAllowed && !transit.isDemo
        let failure = Self.needingNetwork(transit.isTrain
            ? (allowNetwork ? Note { $0.downloadFailedText($0.t("Couldn't download the train timetables. Check your network."),
                                                           problems: TransitModel.timetableNotices(parts)) }
               : Note { $0.t("Train timetables are downloaded the first time you turn the app on.") })
            : (allowNetwork ? Note { $0.downloadFailedText($0.t("Couldn't download the ferry timetables. Check your network."),
                                                           problems: TransitModel.timetableNotices(parts)) }
               : Note { $0.t("Ferry timetables are downloaded the first time you turn the app on.") }),
            networkOff: networkOff)
        let delay = startDelay
        task = Task { [weak self] in
            guard await Self.settle(delay) else { return }
            var feed: FerryFeed?
            // New Jersey buses: take only the chunk near this place
            do {
                feed = try await store.ensure(allowNetwork: allowNetwork, near: place.coordinate, radius: radius)
            } catch {
                feed = await store.load(near: place.coordinate, radius: radius)
            }
            // Don't show an operator with no sailings at all on the departure days (its timetable has run out)
            let loaded = feed
            feed = await offMain { loaded?.active(from: leave).filtered(for: system) }
            guard let self, !Task.isCancelled else { return }
            guard let feed else {
                self.stations = []
                self.status = .failed(failure)
                return
            }
            let near = feed.stations(near: place.coordinate, radiusMeters: radius)
            // Ferry: the piers without times too (NoTimesStations), which have nothing to download
            let shown = near + NoTimesStations.stations(system, near: place.coordinate, radiusMeters: radius)
            self.feedRoutes = nil
            self.stations = shown
            self.walks = Self.estimate(from: place.coordinate, stations: shown, settings: settings, routes: [:])
            async let routeMeters = Self.walkRoutes(allowNetwork, from: place.coordinate, to: shown)
            var realtime: [FerryRealtime] = []
            var realtimeFailed: [FerryFeed.Source] = []
            // The operators nearby that have live data
            let byPier = feed.routesByPier()
            let liveRoutes = near.flatMap { byPier[$0.id] ?? [] }.filter { feed.hasRealtime(route: $0, accounts: accounts) }
            let sources = FerryFeed.realtimeSources(routes: liveRoutes, accounts: accounts)
            if live, allowNetwork, !sources.isEmpty {
                let result = await FerryStore.fetchRealtime(sources)
                realtime = result.realtime
                realtimeFailed = result.failed
            }
            let meters = await routeMeters
            guard !Task.isCancelled else { return }
            self.walks = Self.estimate(from: place.coordinate, stations: shown, settings: settings, routes: meters)
            let from = leave.addingTimeInterval(-60), to = leave.addingTimeInterval(window)
            let nearIDs = near.map(\.id), liveTimes = realtime
            let timetable = await offMain { feed.arrivals(pierIDs: nearIDs, from: from, to: to, realtime: liveTimes, now: Date()) }
            guard !Task.isCancelled else { return }
            self.arrivals = timetable
            // Nothing live came in (standby, a failed download, or operators without live data): the times are the timetable's
            if realtime.isEmpty { self.dataKind = .scheduled(validUntil: nil) }
            if live, !allowNetwork, !sources.isEmpty {
                // Standby: nearby lines with live data show the timetable's times until the app is turned on
                self.status = .failed(Self.needingNetwork(Note { $0.t("Turn the app on to get live times.") }, networkOff: networkOff))
                return
            }
            if !realtimeFailed.isEmpty {
                // Some live data didn't download: those times are the timetable's, and the note says so (UIText.realtimeError)
                let failed = realtimeFailed
                self.status = .failed(Self.needingNetwork(Note { $0.realtimeError(system, failed: failed) ?? "" }, networkOff: networkOff))
                return
            }
            self.status = .ready
        }
    }

    /// Arranges departures by departure time into the same board as the main view, with the ranges of the walk chosen here.
    func board(transit: TransitModel) -> NearbyBoard? {
        guard place != nil, let leave = computedLeaveAt else { return nil }
        var settings = walkSettings(transit)
        settings.arrivalWindowMinutes = windowSeconds / 60
        // The departure time is fixed (not "now"), so the result doesn't change while data and settings stay the same
        let key = BoardKey(version: dataVersion, window: windowSeconds, settings: settings, boardInputs: transit.boardInputsVersion)
        if let cache = boardCache, cache.key == key || (refreshing && status == .loading) { return cache.board }
        var routes: [String: [String]] = [:]
        for s in stations { routes[s.id] = feedRoutes?[s.id] ?? transit.routes(atStation: s.id) }
        // Like the main window: of the trains too soon to catch at the front, only the last one is kept before the list is cut.
        // The time to leave is already in the trains' time (trainTimeNow), so no clock offset is added to it; when the times came
        // is this Mac's, so it is put in the trains' time too
        let board = NearbyBoardBuilder.build(stations: stations, walks: walks, arrivals: arrivals,
                                             settings: settings, now: leave, routes: routes,
                                             maxTrainsPerDirection: 6, clockOffset: 0,
                                             observedAt: arrivalsReceivedAt.addingTimeInterval(ClockSkew.current), tooSoonKept: 1)
        boardCache = (key, board)
        return board
    }

    /// Live times left on screen get old: on each refresh interval, while the trip planner is shown and the app is started, fetch
    /// them again for the same place and time, keeping the results shown until the new ones are in. Only while live times are
    /// shown (a timetable's don't change), also beside a note that some didn't come; nothing on standby (no network)
    func refreshLive(transit: TransitModel) {
        // Also when a note says some live data didn't come (one operator's download failed): the live times shown with it still
        // get old, and the next try may get the rest
        let resultsShown: Bool
        switch status {
        case .ready, .failed: resultsShown = true
        case .idle, .loading: resultsShown = false
        }
        guard isShown, transit.isActive, place != nil, resultsShown, dataKind == .realtime, !addressLookup.isPending,
              computedWith.map({ $0.active == transit.isActive && $0.system == transit.system && $0.demo == transit.isDemo }) == true
        else { return }
        refreshing = true
        update(transit: transit)
    }

    /// Frees the timetable memory when the trip planner isn't in use.
    /// An address lookup still in flight is kept: dropping it would leave the chosen name in the field with nothing to show for it.
    func release() {
        isShown = false
        if status == .loading { stopped = true }
        task?.cancel()
        // Its place no longer keeps an area's data downloading (see DownloadArea); shown again, it's in use again (resume)
        PlacesInUse.set(.planner, [])
        completer?.cancel()
        completer = nil
        Task {
            await TimetableStore.shared.release()
            await FerryStore.njBus.releaseDetached()
        }
    }

    /// The trip planner is shown again (see release), or its search text was edited: a computation that closing it stopped, or a place whose
    /// lookup landed while it was closed, starts now, otherwise its spinner never stops. An address lookup still in flight starts the computation
    /// itself when it lands; editing the search text drops it, which is when the stopped one starts.
    func resume(transit: TransitModel) {
        isShown = true
        if !transit.isDemo { PlacesInUse.set(.planner, place.map { [$0.coordinate] } ?? []) }
        // Start, standby or another transit system while the trip planner was closed (its onChange handlers weren't there to see it)
        let switched = place != nil && !addressLookup.isPending
            && computedWith.map { $0.active != transit.isActive || $0.system != transit.system || $0.demo != transit.isDemo } == true
        guard switched || (stopped && addressLookup.needsRestart(hasPlace: place != nil, loading: status == .loading)) else { return }
        update(transit: transit)
    }

    /// Waits until the user stops (see update's delay); if it changes again while waiting, skip the query
    nonisolated private static func settle(_ delay: TimeInterval) async -> Bool {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return !Task.isCancelled
    }

    /// Walking route: in standby, don't ask Apple Maps (standby = no network); estimate from straight-line distance
    nonisolated private static func walkRoutes(_ allowNetwork: Bool, from origin: Coordinate, to stations: [Station]) async -> [String: Double] {
        guard allowNetwork else { return [:] }
        return await WalkRouter().walkingDistances(from: origin, to: stations)
    }

    private static func estimate(from origin: Coordinate, stations: [Station], settings: CatchSettings,
                                 routes: [String: Double]) -> [String: WalkEstimate] {
        var result: [String: WalkEstimate] = [:]
        for s in stations {
            result[s.id] = WalkEstimator.estimate(from: origin, to: s, settings: settings, routeMeters: routes[s.id])
        }
        return result
    }
}
