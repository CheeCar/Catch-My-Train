import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// Starts loading the bus stop catalog in the background if it isn't loaded yet (switching to bus mode, refreshing buses, the bus map, Plan a Trip),
    /// not on the main thread, so the UI doesn't stutter; refreshes once more automatically when loaded.
    func ensureBusCatalogLoaded() {
        guard busCatalogStorage == nil, !busCatalogFailed else { return }
        loadBusCatalogInBackground()
    }

    /// The bus stop catalog once loaded, starting the load if needed; nil if it can't be read or bus mode was left meanwhile.
    /// Plan a Trip waits for it: on standby nothing else loads it, so its first search after launch would miss every MTA stop.
    func loadedBusCatalog() async -> BusCatalog? {
        ensureBusCatalogLoaded()
        // The load stores the catalog in the same main-actor step that ends the task, so it's there once this returns
        _ = await busCatalogTask?.value
        return busCatalogStorage
    }

    func loadBusCatalogInBackground() {
        guard busCatalogTask == nil else { return }
        busCatalogTask = Task { [weak self] in
            let result = await offMain { Result { try BusCatalog.loadCurrent() } }
            guard let self else { return }
            self.busCatalogTask = nil
            switch result {
            case .success(let catalog):
                // Switched to another mode while loading: don't keep it (saves memory)
                if self.system == .bus { self.busCatalogStorage = catalog }
            case .failure(let error):
                // If it can't be read, say clearly the data is corrupt so people don't think there are no bus stops nearby. Not re-read again this run
                self.busCatalogFailed = true
                AppLog.data.error("Reading the bus stop list failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            if self.system == .bus { self.refresh() }
        }
    }

    // MARK: - Stations and walking

    func currentStations() -> [Station] {
        let c = origin?.coordinate
        let key = [system.rawValue, dataSource.rawValue, String(stationInputs),
                   c.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "-",
                   String(effectiveSettings.sanitized().extendedCandidateRadiusMeters)].joined(separator: "|")
        if let stationsMemo, stationsMemo.key == key { return stationsMemo.value }
        let value = computeStations()
        stationsMemo = (key, value)
        return value
    }

    private func computeStations() -> [Station] {
        // Demo mode: the stations of its area near its place (all four modes; see MockTransitData.demoStations)
        if isDemo {
            guard let origin else { return [] }
            let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
            return MockTransitData.demoStations(system, near: origin.coordinate, radiusMeters: radius, catalog: catalog, buses: busCatalog)
        }
        if system == .bus {
            // MTA bus stops (station catalog) plus bus stops of NJ Transit and others (the nearby part of timetable data), the nearest 30 of each
            guard let origin else { return [] }
            let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
            let mta = busCatalog?.stations(near: origin.coordinate, radiusMeters: radius) ?? []
            let others = Array((ferryFeed?.stations(near: origin.coordinate, radiusMeters: radius) ?? []).prefix(30))
            return mta + others
        }
        if usesTimetable {
            guard let origin else { return [] }
            let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
            // Ferry: also the piers of the operators without times (NoTimesStations), once the timetables are here. Until then
            // the list stays empty, so it says the timetables are downloading (or why they aren't)
            guard let ferryFeed else { return [] }
            return ferryFeed.stations(near: origin.coordinate, radiusMeters: radius)
                + NoTimesStations.stations(system, near: origin.coordinate, radiusMeters: radius)
        }
        guard let origin else { return [] }
        // Pre-filter by the straight-line radius of the extended range (plus 100 meters of margin; walking time decides in the end).
        let radius = effectiveSettings.sanitized().extendedCandidateRadiusMeters + 100
        // Subway stations, tram stations, plus PATH and light rail stations (nearby ones from timetable data, at most 30), and
        // the AirTrain stations without times (NoTimesStations)
        return (catalog?.stations(near: origin.coordinate, radiusMeters: radius) ?? [])
            + RooseveltIslandTram.stations(near: origin.coordinate, radiusMeters: radius)
            + Array((ferryFeed?.stations(near: origin.coordinate, radiusMeters: radius) ?? []).prefix(30))
            + NoTimesStations.stations(.subway, near: origin.coordinate, radiusMeters: radius)
    }

    /// Upcoming departures at nearby tram stations (estimated from RIOC's website headways, 15 extra minutes so the widget has departures to show between updates)
    func tramArrivals(now: Date) -> [Arrival] {
        let ids = stations.map(\.id).filter(RooseveltIslandTram.isTramStation)
        guard !ids.isEmpty else { return [] }
        let window = effectiveSettings.sanitized().arrivalWindowSeconds + 15 * 60
        return RooseveltIslandTram.arrivals(stationIDs: ids, from: now.addingTimeInterval(-60),
                                            to: now.addingTimeInterval(window), hours: tramHours, now: now)
    }

    /// The group with only the tram station (Roosevelt Island Tram)
    func isTramOnly(_ station: BoardStation) -> Bool {
        system == .subway && !station.stations.isEmpty
            && station.stations.allSatisfy { RooseveltIslandTram.isTramStation($0.id) }
    }

    func updateWalks() {
        guard let origin else {
            walks = [:]
            return
        }
        // The range in use, with the minutes "Extend Range for Now" adds: the stations it brings in are checked for water too
        let s = effectiveSettings.sanitized()
        // Only routes found from this origin: after a bigger move the book still holds the old origin's until new ones are asked for
        let routes = routeBook.routeMeters(from: origin.coordinate)
        let waits = routesCanCome
        var result: [String: WalkEstimate] = [:]
        var across: Set<String> = []
        for station in stations {
            let walk = WalkEstimator.estimate(from: origin.coordinate, to: station, settings: s, routeMeters: routes[station.id])
            if walk.isAcrossWater {
                across.insert(station.id)
                // A straight line across the river may be far too short: while Apple Maps' route may still come, the station
                // waits for it instead of showing in range on the straight line. Without a route it shows, "Not sure" at best
                if waits, routeBook.awaitsRoute(for: station, from: origin.coordinate) { continue }
            }
            result[station.id] = walk
        }
        acrossWaterIDs = across
        walks = result
    }

    /// Whether walking routes can come now: Apple Maps is asked (Start, not Demo mode), the network is on in Settings and the Mac
    /// isn't known to be offline
    private var routesCanCome: Bool {
        isActive && dataSource == .mtaRealtime && networkAllowed && isOnline != false
    }

    /// When the origin changes or new stations appear, compute walking route lengths with MapKit (only for the nearest few stations).
    /// Stations whose route couldn't be found are asked again later (see WalkRouteBook).
    func requestRoutesIfNeeded() {
        guard isActive, let origin, dataSource == .mtaRealtime else { return }
        let from = origin.coordinate
        let (targets, startedOver) = routeBook.next(from: from, stations: stations, limit: WalkRouter.maxStations, now: Date(),
                                                    acrossWater: acrossWaterIDs)
        if startedOver { cancelRouteTasks() }
        guard !targets.isEmpty else { return }

        let router = router
        isRouting = true
        let id = UUID()
        routeTaskStations[id] = Set(targets.map(\.id))
        routesAsked = Set(routeTaskStations.values.joined())
        // The task starts only after this method returns (both on the main actor), so it's in the list before it can remove itself
        routeTasks[id] = Task { [weak self] in
            let distances = await router.walkingDistances(from: from, to: targets)
            // Cancelled: whoever cancelled it already emptied the list
            guard let self, !Task.isCancelled else { return }
            self.routeTasks[id] = nil
            self.routeTaskStations[id] = nil
            self.routesAsked = Set(self.routeTaskStations.values.joined())
            self.isRouting = !self.routeTasks.isEmpty
            // The origin changed during the calculation: discard the result.
            guard self.routeBook.received(distances, for: targets, from: from, now: Date()) else { return }
            self.updateWalks()
            self.saveSnapshot()
        }
    }

    /// Standby, or the origin moved: stop every walking route request still running (each stops its Apple Maps requests too, see WalkRouter)
    func cancelRouteTasks() {
        for task in routeTasks.values { task.cancel() }
        routeTasks = [:]
        routeTaskStations = [:]
        routesAsked = []
        isRouting = false
    }
}
