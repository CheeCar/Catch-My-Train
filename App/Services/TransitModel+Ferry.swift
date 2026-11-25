import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    // MARK: - Ferry

    /// Ferry (trains too): first make sure there's a timetable (checked online on first use or after the 1st of each month), then download the live data nearby piers (stations) use
    /// (NYC Ferry, NY Waterway; LIRR, Metro-North), and finally compute the boats (trains) within the arrival time range from timetable + live data.
    /// Staten Island Ferry, Seastreak and the Statue of Liberty ferry only have timetables.
    func refreshFerry(now: Date) {
        feedStatuses = []
        isRefreshing = true
        let system = system
        // For New Jersey buses take only the nearby area (see FerryStore.load(near:radius:))
        let near = origin?.coordinate
        let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
        // The day goes by the start place's area (outside them all, this Mac's), as its times do
        let zone = l10n.timeZone
        refreshTask = Task { [weak self] in
            let store = FerryStore.store(for: system)
            var feed: FerryFeed?
            var failed = false
            do {
                feed = try await store.ensure(allowNetwork: true, now: now, near: near, radius: radius)
            } catch {
                feed = await store.load(near: near, radius: radius)
                // Stopped by standby: not a failed download
                failed = feed == nil && !NetworkReach.isCancellation(error)
            }
            // Operators whose timetables have run out (e.g. the Statue of Liberty ferry between seasons) are hidden for now, so no empty piers without boats appear.
            // Same day and unchanged data: reuse last time's result (it scans all departures, and trains have tens of thousands)
            let activeKey = "\(system.rawValue)|\(Timetable.dayNumber(now, in: zone))|\(await store.generation)|\(feed == nil)"
            guard let self, !Task.isCancelled, self.system == system else { return }
            if let memo = self.activeMemo, memo.key == activeKey {
                feed = memo.feed
            } else {
                // Scanning all departures (trains have tens of thousands): compute on a background thread
                let loaded = feed
                feed = await offMain { loaded?.active(from: now).filtered(for: system) }
                guard !Task.isCancelled, self.system == system else { return }
                self.activeMemo = (activeKey, feed)
            }
            self.ferryDownloadFailed = failed
            guard let feed else {
                self.isRefreshing = false
                self.arrivals = []
                self.saveSnapshot(refreshDone: true)
                return
            }
            if self.ferryFeed != feed {
                self.ferryFeed = feed
                // Now that pier data is available, re-pick the nearby piers
                self.stations = self.currentStations()
                self.updateWalks()
                self.requestRoutesIfNeeded()
            }
            // The piers without times have nothing to download
            let piers = self.timedStations.map(\.id)
            let accounts = self.accountSources
            let routes = piers.flatMap { self.ferryRoutesByPier[$0] ?? [] }.filter { feed.hasRealtime(route: $0, accounts: accounts) }
            var realtime: [FerryRealtime] = []
            var realtimeFailed: [FerryFeed.Source] = []
            let sources = FerryFeed.realtimeSources(routes: routes, accounts: accounts)
            if !sources.isEmpty {
                let result = await FerryStore.fetchRealtime(sources)
                realtime = result.realtime
                realtimeFailed = result.failed
                self.noteNJTransit(asked: sources, result: result)
            }
            guard !Task.isCancelled, self.system == system else { return }
            // In the trains' time (the servers' clock, see ClockSkew), as the times it is compared with: on a Mac whose clock is
            // off, its own time would look in the wrong stretch of the timetable and make the data look older or newer than it is
            let t = ClockSkew.now()
            // Compute by the arrival time range in Settings (15 extra minutes so the widget has boats to show between updates)
            let window = self.effectiveSettings.sanitized().arrivalWindowSeconds + 15 * 60
            let from = t.addingTimeInterval(-60), to = t.addingTimeInterval(window)
            let live = realtime
            let computed: [Arrival] = await offMain {
                // For the log: how many trains NJ Transit's live data has and how many of them matched the timetable's trips by
                // train number, the first time after launch and then at most every 10 minutes
                if let njt = live.first(where: { $0.source == .njTransitRail }) {
                    LiveMatchLog.note(FerryFeed.Source.njTransitRail.name + " trains", every: 10 * 60) {
                        [feed.liveTrainsLogLine(njt, now: t)]
                    }
                }
                return feed.arrivals(pierIDs: piers, from: from, to: to, realtime: live, now: t)
            }
            guard !Task.isCancelled, self.system == system else { return }
            self.arrivals = computed
            self.ferryUpdatedAt = t
            self.ferryRealtimeAt = realtime.map { $0.timestamp ?? $0.fetchedAt }.min()
            self.isRefreshing = false
            // A refused NJ Transit account is noted only at stations NJ Transit serves (scheduleOnlyText), not over every station
            self.lastError = self.networkOffNote
            // A company whose live data failed is noted only at its own stations or piers
            self.stationNotices = self.l10n.realtimeError(system, failed: realtimeFailed).map { text in
                [StationNotice(text: text, stationIDs: Set(piers.filter { id in realtimeFailed.contains { $0.owns(id: id) } }))]
            } ?? []
            self.saveSnapshot(refreshDone: true)
        }
    }

    /// Whether this pier only has timetables (e.g. Staten Island Ferry): the UI must say clearly there's no live data.
    func isScheduleOnly(_ station: BoardStation) -> Bool {
        if isTramOnly(station) { return true }
        guard station.stations.allSatisfy({ isTimetableStation($0.id) }), ferryFeed != nil else { return false }
        let routes = station.stations.flatMap { ferryRoutesByPier[$0.id] ?? [] }
        guard !routes.isEmpty else { return false }
        // A bus company at this stop whose live data failed this time: its times are from the timetable
        if !failedBusFeeds(routes: routes).isEmpty { return true }
        guard routes.contains(where: { givesLiveData(route: $0) }) else { return true }
        // Light rail and buses: live data isn't guaranteed (the trip may not be in the live data); without live departures, still note the times come from the timetable
        if routes.allSatisfy({ FerryFeed.Source.of(route: $0) == .njTransitLightRail || RegionalBusFeed.of(route: $0) != nil }) {
            let ids = Set(station.stations.map(\.id))
            return !arrivals.contains { ids.contains($0.stationID) && $0.source == .realtime }
        }
        return false
    }

    /// Whether this route's company gives live data now. Buses: CTtransit, Bee-Line, NJ Transit (with an account) and Suffolk
    /// (with a key) have live data, the others only have timetables. A refused account or key gives none, and neither does a
    /// company whose download failed this time, so those stations say their times are from the timetable
    private func givesLiveData(route: String) -> Bool {
        if let bus = RegionalBusFeed.of(route: route) {
            if busRealtimeFailed.contains(bus.code) { return false }
            return bus.canGetRealtime(hasAccount: hasNJTransitAccount && !njTransitBusRejected, hasSuffolkKey: hasSuffolkKey && !suffolkKeyRejected)
        }
        return ferryFeed?.hasRealtime(route: route, accounts: njTransitRejected ? [] : accountSources) ?? false
    }

    /// Bus companies serving these routes whose live data failed to download on the last refresh
    func failedBusFeeds(routes: [String]) -> Set<String> {
        guard isBus, !busRealtimeFailed.isEmpty else { return [] }
        return Set(routes.compactMap { RegionalBusFeed.of(route: $0)?.code }).intersection(busRealtimeFailed)
    }

    /// The timetable note for a station, or nil when the red notice above it already says the same thing (otherwise it is shown twice).
    func scheduleOnlyNote(_ station: BoardStation) -> String? {
        let text = scheduleOnlyText(station)
        return text == notice(for: station) ? nil : text
    }

    /// Whether the station's timetable note is about a key or account: it says where in Settings, and has a button to there
    func scheduleOnlyNoteAsksForKey(_ station: BoardStation) -> Bool {
        keyNote(station) != nil && scheduleOnlyNote(station) != nil
    }

    /// Note when only timetables exist: the tram states times are estimates from headways; ferries state times come from the timetable.
    func scheduleOnlyText(_ station: BoardStation) -> String {
        if let note = keyNote(station) { return note }
        return otherScheduleOnlyText(station)
    }

    /// The timetable note of a station whose live times need a key or account the user hasn't added, or that was refused; nil otherwise
    private func keyNote(_ station: BoardStation) -> String? {
        // NJ Transit stations without an account yet: tell the user that entering an account gives live data. Only where it does
        // (liveWithAccount): the other NJ Transit stations say their times are from the timetable, as stations without live data do
        let njt = station.stations.contains { s in
            (ferryRoutesByPier[s.id] ?? []).contains {
                FerryFeed.Source.of(route: $0)?.liveWithAccount == true || RegionalBusFeed.of(route: $0)?.liveWithAccount == true
            }
        }
        if njt && !hasNJTransitAccount {
            return l10n.t("Times are from the timetable. For live NJ Transit times, add your NJ Transit developer account in Settings → Data source.")
        }
        if njt && (isBus ? njTransitBusRejected : njTransitRejected) {
            return l10n.t("NJ Transit didn't accept your developer account, so NJ Transit times are from the timetable. Check it in Settings → Data source.")
        }
        // Suffolk County Transit: live data needs a Swiftly key the user applies for
        let suffolk = station.stations.contains { s in
            (ferryRoutesByPier[s.id] ?? []).contains { RegionalBusFeed.of(route: $0)?.needsKey == true }
        }
        if suffolk && !hasSuffolkKey {
            return l10n.t("Times are from the timetable. For live Suffolk County Transit times, add your own Swiftly key in Settings → Data source.")
        }
        if suffolk && suffolkKeyRejected {
            return l10n.t("Swiftly didn't accept your Suffolk County Transit key, so Suffolk times are from the timetable. Check it in Settings → Data source.")
        }
        return nil
    }

    private func otherScheduleOnlyText(_ station: BoardStation) -> String {
        let routes = station.stations.flatMap { ferryRoutesByPier[$0.id] ?? [] }
        // A bus company here whose live data couldn't be downloaded (e.g. its server is down)
        if isBus, !failedBusFeeds(routes: routes).isEmpty {
            return l10n.t("Couldn't get live data for some buses. Their times are from the timetable.")
        }
        // A bus company here has live data, and none of this stop's departures is live right now (e.g. at a route's first stop,
        // which NJ Transit gives no predictions for): the note doesn't say there's no live data for these buses
        if isBus, routes.contains(where: { givesLiveData(route: $0) }) {
            return l10n.t("No live times right now. Times are from the timetable.")
        }
        // PATCO's stations (in subway): it runs trains, not light rail
        let patco = system == .subway && !routes.isEmpty && routes.allSatisfy { FerryFeed.Source.of(route: $0) == .patco }
        return isTramOnly(station)
            ? l10n.t("No live data is available for the tram. It runs about every 15 min (every 7.5 min at weekday rush hours), so times are estimates.")
            : system == .subway && !patco ? l10n.t("No live data is available for the light rail. Times are from the timetable.")
            : isTrain || patco ? l10n.t("No live data is available for this train. Times are from the timetable.")
            : isBus ? l10n.t("No live data is available for this bus. Times are from the timetable.")
            : l10n.t("No live data is available for this ferry. Times are from the timetable.")
    }

    /// Whether this pier has boats requiring tickets and security screening (the Statue of Liberty ferry): the UI warns, and 30 extra minutes are already allowed (see FerryFeed.Source.boardingSeconds).
    func needsSecurityCheck(_ station: BoardStation) -> Bool {
        guard isFerry else { return false }
        return station.stations.contains { s in
            (ferryRoutesByPier[s.id] ?? []).contains { FerryFeed.Source.of(route: $0)?.needsSecurityCheck == true }
        }
    }
}
