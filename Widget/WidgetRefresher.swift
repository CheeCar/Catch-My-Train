import Foundation
import TransitCore
import WidgetKit

/// The widget downloads MTA realtime data itself, so it updates even when the main app is closed.
///
/// While the main app is running (including menu-bar-only), the widget doesn't download: the main app downloads, saves a snapshot, then tells the widget to redraw.
/// That way the widget and main app show the same data with the same update time.
/// The walking origin and walk times still come from the main app's last saved snapshot (the widget can't get a location itself);
/// the widget only re-downloads trips for those stations and writes the new trips back to the snapshot.
enum WidgetRefresher {

    /// When data is older than this (seconds), the widget re-downloads when refreshing its timeline. At least 60 seconds; follows the Settings refresh interval when that's longer.
    static var refetchAfterSeconds: TimeInterval { max(60, SharedStore.refreshIntervalSeconds) }


    /// Reads the snapshot; if the data is old, re-downloads trips and writes them back. Keeps the old trips if the download fails.
    static func currentSnapshot(now: Date = Date(), force: Bool = false) async -> TransitSnapshot? {
        // The app's settings as they are now: whether the network is allowed, Demo mode and the refresh interval are read below
        SharedStore.adoptAppSettings()
        let modified = SharedStore.snapshotModifiedAt()
        guard let snap = SharedStore.loadSnapshot() else { return nil }
        // Demo mode: downloads nothing, and real departures must not get mixed into the demo's (even when the demo has none to show)
        guard SharedStore.dataSource != .mock else { return snap }
        // Don't download in standby.
        if let activity = SharedStore.loadActivity(), !activity.isActive(at: now) { return snap }
        // Main app is running: use the data it saved (it downloads at the refresh interval and notifies the widget on changes), so both match.
        if SharedStore.isAppRunning(now: now) { return snap }
        // Network turned off in Settings: don't download
        guard NetworkSwitch.isAllowed else { return snap }
        // No station within walking range (the widget has nothing to suggest): nothing worth downloading
        guard !snap.boardStationIDs(settings: widgetSettings(snap, now: now)).isEmpty else { return snap }
        let age = (snap.updateTime == nil ? now : ClockSkew.now(now)).timeIntervalSince(snap.updateTime ?? snap.createdAt)
        // Also no need to download if the main app just saved (it's running and downloading at the refresh interval).
        let justSaved = now.timeIntervalSince(snap.createdAt) < refetchAfterSeconds
        guard force || (age > refetchAfterSeconds && !justSaved) else { return snap }
        guard var fresh = await refreshed(snap, now: now) else {
            // Download failed: also show why it couldn't connect (possibly a network restriction); trips stay as before.
            // Only this mode's providers (see NoticeScope); seen now, though the snapshot itself is older
            var shown = snap
            let reach = NoticeScope.filter(NetworkReach.notices(now: Date()), mode: snap.transitSystem)
            if !reach.isEmpty {
                shown.reach = reach
                shown.reachAt = Date()
            }
            return shown
        }
        // Rate limiting while the widget downloads itself is also noted in the snapshot (only reached when the main app isn't running)
        let limits = NoticeScope.filter(RateLimit.notices(now: Date()), mode: fresh.transitSystem)
        fresh.rateLimits = limits.isEmpty ? nil : limits
        let reach = NoticeScope.filter(NetworkReach.notices(now: Date()), mode: fresh.transitSystem)
        fresh.reach = reach.isEmpty ? nil : reach
        fresh.reachAt = nil
        // The main app may have opened and saved a new snapshot during the download (e.g. changed location), so don't overwrite it:
        // before writing, check again whether the main app is running and whether the snapshot is still the pre-download one.
        if SharedStore.isAppRunning(now: Date()) || SharedStore.snapshotModifiedAt() != modified {
            return SharedStore.loadSnapshot() ?? fresh
        }
        do {
            try SharedStore.saveSnapshot(fresh)
        } catch {
            AppLog.widget.error("Saving the widget snapshot failed: \(AppLog.reason(error), privacy: .public)")
        }
        return fresh
    }

    /// "Refresh" or "Start" tapped on the widget.
    /// Main app running: ask it to download now (both use the same data), wait a few seconds at most for it to save new data, then redraw the widget.
    /// Main app not running: the widget downloads itself.
    static func refreshNow(now: Date = Date()) async {
        if SharedStore.isAppRunning(now: now) {
            SharedStore.refreshRequestedAt = now
            SharedSignal.post()
            await waitForAppSnapshot(newerThan: now, timeout: 8)
        } else {
            _ = await currentSnapshot(now: now, force: true)
        }
    }

    /// Waits for the main app to save a snapshot newer than `date` (at most `timeout` seconds). Only checks the file's modification time, without reading the whole snapshot each time.
    private static func waitForAppSnapshot(newerThan date: Date, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = SharedStore.snapshotModifiedAt(), m > date { return }
            // Cancelled (the system no longer wants the timeline): stop waiting at once
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        }
    }

    /// Which trips the widget can update on its own when the main app isn't running: only the MTA subway (free, no key).
    /// Buses need the key in the Keychain; trains, ferries, PATH and light rail need schedules downloaded by the main app, which don't fit in the widget.
    enum SelfUpdate { case all, some, none }

    /// Stations like PATH and light rail whose trips the main app computes from schedules (not MTA realtime data)
    private static func isFeedStation(_ id: String) -> Bool {
        FerryFeed.Source.allCases.contains { $0.owns(id: id) }
    }

    /// All: only NYC Subway stations (and the tram), whose times it gets itself; none: none of them (another area's subway, or
    /// only PATH and light rail); some: both
    static func canUpdate(_ snap: TransitSnapshot) -> SelfUpdate {
        guard !snap.containsMockData, snap.transitSystem == .subway else { return .none }
        let fromFeeds = snap.stations.filter { isFeedStation($0.id) }.count
        return fromFeeds == 0 ? .all : fromFeeds == snap.stations.count ? .none : .some
    }

    /// Re-downloads trips for the snapshot's stations the widget can show (within walking range). Returns nil for mock data, no such stations,
    /// or when every download fails.
    static func refreshed(_ snap: TransitSnapshot, now: Date) async -> TransitSnapshot? {
        // Station directory: the built-in one, or the one updated by the main app's monthly check (in the shared folder)
        SharedStore.useStaticDataFolder()
        // Stations too far to walk to are never on the widget, so their trips aren't downloaded
        let shown = snap.boardStationIDs(settings: widgetSettings(snap, now: now))
        // Bus realtime data needs the key in the Keychain, which the widget can't read, so the main app refreshes it; ferries are refreshed by the main app too.
        guard !snap.containsMockData, snap.transitSystem == .subway, !shown.isEmpty,
              let catalog = try? StationCatalog.loadCurrent() else { return nil }
        let ids = snap.stations.map(\.id).filter(shown.contains)
        // Roosevelt Island Tram has no realtime data: recompute from the RIOC website's operating hours and headways (same as the main app)
        let tramIDs = ids.filter(RooseveltIslandTram.isTramStation)
        let window = snap.settings.sanitized().arrivalWindowSeconds + 15 * 60
        // The tram's times and their update time are in the trains' time (see ClockSkew), as in the app
        let trainNow = ClockSkew.now(now)
        let tram = RooseveltIslandTram.arrivals(stationIDs: tramIDs, from: trainNow.addingTimeInterval(-60),
                                                to: trainNow.addingTimeInterval(window),
                                                hours: RooseveltIslandTram.loadCurrentHours(), now: trainNow)
        // PATH and light rail stations (the schedule part of the subway) are computed by the main app; only the MTA subway is updated here, those stations' trips stay as is
        let feedArrivals = snap.arrivals.filter { isFeedStation($0.stationID) }
        let subwayIDs = ids.filter { !RooseveltIslandTram.isTramStation($0) && !isFeedStation($0) }
        var fresh = snap
        fresh.createdAt = now
        // The widget's own download: no longer what the app said about its data
        fresh.staleWhenSaved = nil
        guard !subwayIDs.isEmpty else {
            guard !tram.isEmpty || !tramIDs.isEmpty else { return nil }
            fresh.arrivals = tram + feedArrivals
            fresh.dataTime = trainNow
            return fresh
        }
        let loader = MTARealtimeLoader(catalog: catalog, fetcher: URLSessionFetcher(timeout: 10),
                                       express: try? ExpressStops.loadCurrent(for: catalog))
        let load = await loader.load(stationIDs: subwayIDs)
        guard !load.allFailed else { return nil }
        // Partial failure: the failed groups keep their old trips (they expire naturally over time).
        let oldSubway = snap.arrivals.filter { !isFeedStation($0.stationID) && !RooseveltIslandTram.isTramStation($0.stationID) }
        fresh.arrivals = load.merged(keeping: oldSubway) + tram + feedArrivals
        // Same algorithm as the main window's "Data updated"
        fresh.dataTime = FeedStatus.dataTime(load.statuses) ?? fresh.arrivals.map(\.updatedAt).max()
        return fresh
    }

    /// Settings used for widget calculations: staleness relaxed to 10 minutes, unless the running app said its data was already out
    /// of date (see TransitSnapshot.widgetStaleAfterSeconds).
    static func widgetSettings(_ snapshot: TransitSnapshot, now: Date = Date()) -> CatchSettings {
        snapshot.widgetSettings(appRunning: SharedStore.isAppRunning(now: now))
    }
}
