import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    /// Woke from sleep or network restored: if "Start"ed, refresh once right away. Do nothing on standby.
    func resumeAfterInterruption() {
        let now = Date()
        syncActivity(now: now)
        guard isActive else { return }
        routeBook.retryFailed()
        // Waking and network restore often arrive back to back: skip if refreshed within the last 10 seconds
        if let last = lastAttempt, BoardClock.now(now).timeIntervalSince(last) < 10 { return }
        if locationMode == .current, dataSource == .mtaRealtime { location.request() }
        refresh()
        verifyUntestedCredentials()
    }

    func networkChanged(online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        // Only refresh when it "went down and came back"; the first notification at launch doesn't count
        if online, wasOnline == false { resumeAfterInterruption() }
        // Gone offline: the stations across the water waiting for their routes show now, "Not sure" at best
        if !online, wasOnline != false, !acrossWaterIDs.isEmpty {
            updateWalks()
            saveSnapshot(widgetsNow: true)
        }
    }

    // MARK: - Start / Standby

    /// Whether currently "Start"ed.
    var isActive: Bool { activity.isActive(at: Date()) }

    /// The setup window was finished ("Start Using…", or closed): a new install that waited for it starts now
    func finishSetup() {
        guard waitsForSetup else { return }
        start()
    }

    private func endSetupWait() {
        if waitsForSetup { waitsForSetup = false }
        if SetupWindow.isPending { SetupWindow.isPending = false }
    }


    /// Start: download nearby departures, then refresh every 30 seconds, and go to standby automatically when time is up.
    func start() {
        endSetupWait()
        activity = (SharedStore.loadActivity() ?? activity).started(at: Date())
        SharedStore.saveActivity(activity)
        // Reminders still to come keep it on past the new auto-standby time too (none is held on standby)
        holdForReminders()
        wasActive = true
        DownloadGate.shared.resume()
        updateKeepAwake(active: true)
        updateLocationNeed()
        if locationMode == .current, dataSource == .mtaRealtime { location.request() }
        refresh()
        // A key test that standby stopped runs again now (see stopCredentialTest)
        verifyUntestedCredentials()
        // Same as tapping "Start" on the widget: after downloading, have the widget redraw immediately once
        forceNextWidgetReload = true
        reloadWidgets(immediate: true)
    }

    /// Standby: stop refreshing, downloading and locating.
    func standby() {
        activity = (SharedStore.loadActivity() ?? activity).stopped(at: Date())
        SharedStore.saveActivity(activity)
        enterStandby()
        MemoryRelief.soon()
    }

    /// Change the auto-standby duration (nil = no auto-standby).
    func setAutoStandby(minutes: Double?) {
        // Take the shared file as truth (the widget may have just toggled), then handle the toggle change right away.
        let now = Date()
        activity = (SharedStore.loadActivity() ?? activity).withAutoStandby(minutes: minutes, now: now)
        SharedStore.saveActivity(activity)
        syncActivity(now: now)
        reloadWidgets(force: true)
    }

    // MARK: - Selected station

    /// Select a station (stop group ID) in the main window or menu bar.
    func selectStation(_ id: String?) {
        guard let id, id != selection.stationID else { return }
        var s = selection
        s.stationID = id
        setSelection(s)
    }

    /// "Show trains" in the map window (which also brings the main window to the front): on standby start first, so the main window
    /// shows the station's trains rather than the standby page; then select the station, and have its card in the sidebar give its
    /// small bounce, even when it was selected already
    func showStationFromMap(_ id: String) {
        if !isActive { start() }
        selectStation(id)
        cardBounce = CardBounce(station: id, at: Date())
    }

    /// ‹ › in the menu bar: switch to the previous / next nearby station.
    func moveStation(by step: Int, in board: NearbyBoard) {
        setSelection(selection.moving(by: step, in: board, limit: board.stations.count))
    }

    func setSelection(_ s: BoardSelection) {
        guard s != selection else { return }
        selection = s
        if persistsSettings { SharedStore.saveSelection(s) }
        reloadWidgets(force: true)
    }

    private func enterStandby() {
        wasActive = false
        updateKeepAwake(active: false)
        // No location on standby: stop a lookup in flight, and permission changes from now on don't locate
        updateLocationNeed()
        let wasExtended = tempRange.isExtended
        tempRange = TemporaryRange()
        boardInputs &+= 1
        refreshTask?.cancel()
        cancelRouteTasks()
        routeBook.stopped()
        busDownloadTask?.cancel()
        busDownloadTask = nil
        subwayDownloadTask?.cancel()
        subwayDownloadTask = nil
        // No network on standby: an unfinished monthly check is redone on the next start
        staticCheckTask?.cancel()
        staticCheckTask = nil
        sourceListTask?.cancel()
        sourceListTask = nil
        // Nor Apple Maps place names: a name cut short is looked up again after the next start
        if let task = currentNameTask {
            task.cancel()
            currentNameTask = nil
            currentNameCoordinate = nil
        }
        areaTask?.cancel()
        // An outside-the-area name that hadn't arrived: show the standby name (the chosen place's) meanwhile, as updateArea does on standby
        if isOutsideArea, outsideAreaName == nil { updateArea(force: true) }
        // An update check still running stops too (Check for Updates is off on standby)
        updateTask?.cancel()
        updateTask = nil
        if updateState == .checking { updateState = .idle }
        // So does the key test; a stopped one runs again on the next Start (see stopCredentialTest)
        stopCredentialTest()
        // Stop the timetable and map downloads still running and refuse new ones until the next Start. Only the ones from before this standby stop,
        // so a download that a quick Start begins isn't hit by a late stop; the two kinds of store stop separately, neither waiting for the other (see DownloadGate)
        let period = DownloadGate.shared.pause()
        Task { await FerryStore.cancelAllDownloads(before: period) }
        Task { await SubwayMapStore.cancelChecks(before: period) }
        // A live data file several operators share is downloaded apart from the refresh that asked for it: it stops too
        SharedLive.cancelAll()
        isRefreshing = false
        isRouting = false
        // The widget fetches by itself once the app quits: after an extended range, give it the normal range again
        // (as restoreNormalRangeBeforeQuit does). Saved before the departures are cleared below, so the widget keeps them
        // as it does after a normal standby. Saving reloads the widgets right away too
        let savedSnapshot = wasExtended && saveSnapshot(immediate: true)
        // Don't keep departures on standby (they go stale and use memory); stations and walking times stay so the next start is faster.
        arrivals = []
        feedStatuses = []
        lastError = nil
        stationNotices = []
        if !savedSnapshot { reloadWidgets(immediate: true) }
    }

    /// Read the toggle state the widget may have changed, and handle auto-standby.
    /// Also tells the widget "main app is running": the widget then doesn't download itself and only shows the data the main app saved, so both match.
    /// - Parameter heartbeat: a timed check (not a signal from the widget). On standby only looks at the toggle, doesn't read other files.
    func syncActivity(now: Date, heartbeat: Bool = false) {
        SharedStore.appAliveAt = now
        // The settings the widget needs are written when one changes; here once more in case their file is gone (it's only read
        // and compared when nothing changed)
        SharedStore.exportWidgetSettings()
        updateRateLimits(now: now)
        if let saved = SharedStore.loadActivity(), saved != activity { activity = saved }
        // Standby and the toggle unchanged: changing station or tapping refresh on the widget sends a signal, so no need to read those files on every timed check
        if heartbeat, !wasActive, !activity.isActive(at: now) { return }
        // While the selection isn't saved (see persistsSettings), the saved one isn't read back over it either
        if persistsSettings, SharedStore.hasSavedSelection {
            let savedSelection = SharedStore.loadSelection()
            if savedSelection != selection { selection = savedSelection }
        }
        // "Refresh" was tapped on the widget (the main app downloads while it's running)
        var refreshRequested = false
        if let requested = SharedStore.refreshRequestedAt {
            SharedStore.refreshRequestedAt = nil
            refreshRequested = now.timeIntervalSince(requested) < 120
        }
        let active = activity.isActive(at: now)
        if active && !wasActive {
            // "Start" was tapped on the widget
            // Diagnostics: whether the main app goes back to standby after "Start" is tapped on the widget (to re-check)
            AppLog.widget.notice("activity on from shared store (widget Start)")
            endSetupWait()
            holdForReminders(now: now)
            wasActive = true
            DownloadGate.shared.resume()
            updateKeepAwake(active: true)
            forceNextWidgetReload = true
            updateLocationNeed()
            if locationMode == .current, dataSource == .mtaRealtime { location.request() }
            refresh()
            verifyUntestedCredentials()
        } else if !active && wasActive {
            let timedOut = activity.isOn
            AppLog.widget.notice("activity off from shared store reason=\(timedOut ? "auto standby" : "standby tapped", privacy: .public)")
            enterStandby()
        } else if active, refreshRequested
                    || RefreshSchedule.isDue(now: BoardClock.now(now), lastStart: lastAttempt, interval: effectiveRefreshInterval, running: isRefreshing) {
            // A timed refresh waits for one still running (a slow server would otherwise have every refresh cut off by the next);
            // "Refresh" tapped on the widget starts over right away, like the other actions that call refresh()
            if refreshRequested { forceNextWidgetReload = true }
            refresh()
        }
    }

    /// Start: tell macOS this is work the user wants, don't nap the app (the system can still sleep); Standby: release it.
    func updateKeepAwake(active: Bool) {
        if active, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keeping nearby times and the widget up to date")
        } else if !active, let token = keepAwake {
            ProcessInfo.processInfo.endActivity(token)
            keepAwake = nil
        }
    }
}
