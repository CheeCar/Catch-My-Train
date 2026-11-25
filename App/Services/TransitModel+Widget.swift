import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    // MARK: - Widget snapshot

    /// - Parameters:
    ///   - widgetsNow: reload widgets right away (for actions like changing settings or switching systems).
    ///   - refreshDone: a refresh finished (new data downloaded, or confirmed nothing to download).
    ///     When refresh or start was tapped on a widget, the widget is reloaded only at this point (redrawn once the data arrives).
    ///   - immediate: reload widgets without waiting for the interval (see reloadWidgets)
    /// - Returns: whether the snapshot was saved and widgets reloaded (not while the location is still unknown, nor when writing it failed)
    @discardableResult
    func saveSnapshot(widgetsNow: Bool = false, refreshDone: Bool = false, immediate: Bool = false) -> Bool {
        // Every refresh ends here: the leave-by reminders follow the times just loaded, whether or not the widget's data is saved,
        // and a reminder's station clicked on standby is selected once it's on the board
        if refreshDone {
            reconcileReminders()
            selectPendingReminderStation()
        }
        // The tests' host leaves the widget's data alone (see isTestHost)
        guard !Self.isTestHost else { return false }
        // Don't overwrite widget data while the location is still being found (otherwise the widget goes blank).
        guard dataSource == .mock || !isLocating else { return false }
        updateLaterDepartures()
        let shared = effectiveSettings.sanitized()
        // Widgets show departures only: the stations without times stay in the app (NoTimesStations)
        var snapshot = TransitSnapshot(
            createdAt: Date(),
            placeName: origin?.name ?? (needsPlace ? missingPlaceText
                                        : locationTooApproximate ? l10n.t("Current location") : l10n.t("Finding your location…")),
            stations: timedStations, walks: TransitSnapshot.sharedWalks(walks, settings: shared), arrivals: arrivals, settings: shared,
            languageCode: language.rawValue, unitsCode: units.rawValue, stationRoutes: stationRoutes,
            system: system.rawValue, directionTitles: emptyDirectionTitles()
        )
        snapshot.walkOrder = TransitSnapshot.walkOrder(walks)
        snapshot.placeNote = locationAccuracyNote
        snapshot.areaName = areaName
        snapshot.outsideArea = isOutsideArea
        // The widget lists times only when they read the same on this Mac's clock (TransitSnapshot.timesInAnotherZone). Demo mode's
        // made-up trains are listed in any zone, on this Mac's clock: they're there to be tried
        snapshot.timeZone = isDemo ? nil : areaRegion?.metroArea.timeZone.identifier
        snapshot.clockCode = clock.rawValue
        snapshot.clockSkew = ClockSkew.current
        // Only the current mode's notices (see updateRateLimits); the widget picks the ones for the station it shows
        updateRateLimits(now: Date())
        snapshot.rateLimits = rateLimits.isEmpty ? nil : rateLimits
        snapshot.reach = reachNotices.isEmpty ? nil : reachNotices
        snapshot.later = laterArrivals.isEmpty ? nil : laterArrivals
        snapshot.updateAvailable = availableUpdate?.version
        // The "updated" time on widgets uses the same time as "Data updated" in the main window
        snapshot.dataTime = dataUpdatedAt
        // Live data already out of date by the app's setting (downloads failing): the widget says "Not sure" as the main window does
        let stale = isStale(now: Date())
        snapshot.staleWhenSaved = stale ? true : nil
        // With no station nearby, the widget gives the same reason as the main window (e.g. timetables still downloading),
        // and knows when it's one only the running app gets past (it asks for the app once that has quit)
        if timedStations.isEmpty, !isLocating {
            snapshot.emptyText = emptyStateText(short: true)
            snapshot.emptyTextNeedsApp = emptyBoardReason().needsRunningApp ? true : nil
        }
        do {
            try SharedStore.saveSnapshot(snapshot)
        } catch {
            // Not shown at the stations: it's no problem with their data. The Widget connection row in Settings warns
            // after several failures in a row (SharedStore.snapshotWriteFailures)
            AppLog.data.error("Saving the widget snapshot failed: \(AppLog.reason(error), privacy: .public)")
            // The widgets still have the last snapshot written: nothing new to reload them for. The next save that works
            // reloads them whatever it holds (what they last got isn't known any more), and a refresh tapped on a widget still
            // waits for it
            lastWidgetSignature = nil
            return false
        }
        var force = widgetsNow
        if refreshDone, forceNextWidgetReload {
            force = true
            forceNextWidgetReload = false
        }
        // The data just turned out of date, or fresh again: the widgets change their verdicts with the main window, not minutes
        // later when they'd count it out of date themselves
        if let last = lastSnapshotStale, last != stale { force = true }
        lastSnapshotStale = stale
        reloadWidgets(force: force, immediate: immediate)
        return true
    }

    /// Each station's two direction titles as they read with no trips (for widgets). Saved for both directions, not only the empty ones,
    /// so a direction whose last trip leaves after the snapshot keeps its title on the widget and says nothing is coming, as the main window does.
    private func emptyDirectionTitles() -> [String: String] {
        var result: [String: String] = [:]
        for station in board(at: Date()).withoutNoTimesStations().stations {
            for dir in [station.north, station.south] {
                let empty = BoardDirection(code: dir.code, directions: [], routes: [], trains: [])
                let title = directionTitle(empty, in: station)
                if !title.isEmpty { result[station.id + "|" + dir.code] = title }
            }
        }
        return result
    }

    /// Makes desktop widgets re-read the data, so they show the same thing as the main app.
    /// - Reloads only when something shown on widgets changes (see widgetSignature); countdowns and evaluations update per minute in the widget itself.
    /// - While the main app is in the foreground: reload right away on any change (doesn't use up the system's widget refresh budget).
    /// - When running only in the menu bar: the system limits daily widget reloads (macOS ignores ones over the limit), so there is at least
    ///   5 minutes between reloads; countdown widgets compute per minute themselves, not via reloads.
    ///   Changes in between are caught up automatically when the time comes, so nothing is missed.
    /// - Actions like toggling, switching stations, changing settings or tapping refresh on a widget take effect right away (force).
    static let backgroundWidgetReloadSeconds: TimeInterval = 300

    /// Minimum interval (seconds) between reloads, "immediate" ones included: when changing several settings in a row or toggling back and forth,
    /// widgets don't recompute all 15 minutes of frames every time (without this, the widget process CPU reached 80% while changing settings).
    /// The first one loads right away, later changes are merged into one, and the last change always loads.
    /// macOS only lets widgets reload once every 5 seconds even when the app is in the foreground, and defers extras (found in chronod logs:
    /// "Throttling additional refresh request while foreground", 5.0s). So regular reloads are also spaced 5+ seconds apart,
    /// leaving room for actions like tapping "Start / Standby" whose change must show right away (immediate isn't subject to this limit).
    static let minWidgetReloadGap: TimeInterval = 5.5

    /// - Parameter immediate: start / standby: reload right away without waiting for the interval (otherwise the medium widget lags a step after tapping standby)
    func reloadWidgets(force: Bool = false, immediate: Bool = false) {
        let now = Date()
        let signature = widgetSignature(at: now)
        let force = force || immediate || pendingWidgetForce
        if !force, signature == lastWidgetSignature { return }
        let minInterval: TimeInterval = force || NSApp.isActive ? Self.minWidgetReloadGap : Self.backgroundWidgetReloadSeconds
        if !immediate, let last = lastWidgetReload, now.timeIntervalSince(last) < minInterval {
            if force {
                // Replace the queued background one (that would wait a few minutes) with this immediate one
                pendingWidgetForce = true
                pendingWidgetReload?.cancel()
                pendingWidgetReload = nil
            }
            if pendingWidgetReload == nil {
                let wait = minInterval - now.timeIntervalSince(last) + (force ? 0.05 : 1)
                pendingWidgetReload = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.pendingWidgetReload = nil
                    self.reloadWidgets()
                }
            }
            return
        }
        pendingWidgetReload?.cancel()
        pendingWidgetReload = nil
        pendingWidgetForce = false
        lastWidgetReload = now
        lastWidgetSignature = signature
        AppLog.widget.notice("reloadAllTimelines force=\(force, privacy: .public) immediate=\(immediate, privacy: .public) active=\(self.activity.isActive(at: now), privacy: .public)")
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Data shown on widgets: the toggle, the selected station and 3 other nearby stations, walk times, direction titles, these stations' trips
    /// (arrival times by minute), update time (by minute), language, units, transit systems and settings; also the status line's notices
    /// (rate limits, can't connect, a new version, network off) and the area line.
    /// Excludes time-varying parts: countdowns and catchability are computed per minute by the widget itself (see Widget/CatchMyTrainWidget.swift).
    /// When none of these change, widgets don't need reloading.
    private func widgetSignature(at now: Date) -> Int {
        var h = Hasher()
        h.combine(activity.isActive(at: now))
        h.combine(activity.standbyAt)
        h.combine(selection.stationID)
        h.combine(language.rawValue)
        h.combine(units.rawValue)
        h.combine(system.rawValue)
        h.combine(dataSource.rawValue)
        h.combine(effectiveSettings.sanitized())
        h.combine(origin?.name)
        h.combine(locationAccuracyNote)
        h.combine(dataUpdatedAt.map { Int($0.timeIntervalSince1970 / 60) })
        h.combine(isStale(now: now))
        for n in rateLimits {
            h.combine(n.provider)
            h.combine(Int(n.until.timeIntervalSince1970))
        }
        for n in reachNotices {
            h.combine(n.provider)
            h.combine(n.problem)
        }
        h.combine(availableUpdate?.version)
        h.combine(areaName)
        h.combine(isOutsideArea)
        h.combine(areaRegion?.metroArea)
        h.combine(networkAllowed)
        if timedStations.isEmpty, !isLocating { h.combine(emptyStateText(short: true)) }
        // Same source as emptyDirectionTitles (board is cached, no need to recompute), and like the widgets without the stations without times
        let b = board(at: now).withoutNoTimesStations()
        h.combine(b.stations.count)
        let selected = selection.station(in: b)
        let shown = (selected.map { [$0] } ?? []) + b.stations.filter { $0.id != selected?.id }.prefix(3)
        for station in shown {
            h.combine(station.id)
            h.combine(Int(station.walk.walkSeconds / 60))
            h.combine(station.range)
            h.combine(station.routes)
            h.combine(directionTitle(station.north, in: station))
            h.combine(directionTitle(station.south, in: station))
            h.combine(station.north.next.map { Int($0.timeIntervalSince1970 / 60) })
            h.combine(station.south.next.map { Int($0.timeIntervalSince1970 / 60) })
            let members = Set(station.stations.map(\.id))
            for a in arrivals.filter({ members.contains($0.stationID) }).sorted(by: { $0.id < $1.id }) {
                h.combine(a.id)
                h.combine(a.arrivalTime.map { Int($0.timeIntervalSince1970 / 60) })
                h.combine(a.status)
                h.combine(a.source)
                h.combine(a.isAssigned)
                h.combine(a.isExpress)
            }
        }
        return h.finalize()
    }

    /// While the app runs (including menu-bar-only), refresh at the interval in Settings (default 30 seconds; MTA data updates about every 30 seconds).
    /// After the app fully quits, widgets download trips themselves (see Widget/WidgetRefresher.swift).
    ///
    /// When "started", check the toggle every 15 seconds (it may have been switched on a widget, or auto-standby may be due) and refresh at the refresh interval.
    /// On standby, check every 40 seconds, reading only a tiny file (tapping start on a widget sends a signal right away, no waiting).
    func startAutoRefresh() {
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds: UInt64 = (self?.wasActive ?? false) ? 15 : 40
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.syncActivity(now: Date(), heartbeat: true)
            }
        }
    }
}
