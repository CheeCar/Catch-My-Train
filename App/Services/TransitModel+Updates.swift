import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    // MARK: - Monthly station list check

    /// Read the station catalog and its express data (use the version updated by the monthly check when it's newer than the built-in one).
    static func loadSubwayData() -> (catalog: StationCatalog?, express: ExpressStops?, error: String?) {
        do {
            let catalog = try StationCatalog.loadCurrent()
            return (catalog, try? ExpressStops.loadCurrent(for: catalog), nil)
        } catch {
            return (nil, nil, AppLog.reason(error))
        }
    }

    /// The first time the subway (or bus) is used after the 1st of each month, check online whether MTA has new data: regenerate the map and station list together,
    /// and swap in the station list if it changed (see SubwayMapStore). Only checks when "Start"ed; retries after a while on failure.
    // MARK: - Check for new versions (plan A: notify only, no auto-install)

    enum UpdateState: Equatable {
        case idle
        case checking
        /// Already up to date
        case upToDate
        /// A new version is available
        case available(UpdateCheck.Release)
        /// No released version yet (repository not public yet, or no Release published)
        case noRelease
        /// Check failed (network problem etc.)
        case failed
    }

    /// Current version number (from Info.plist, e.g. "2.1.0")
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Which releases this build checks, and where it downloads the source list from (UpdateCheck.Channel)
    var updateChannel: UpdateCheck.Channel { .release }

    /// The new version when there is one (noted in the menu bar, Settings and widget)
    var availableUpdate: UpdateCheck.Release? {
        if case .available(let r) = updateState { return r }
        return nil
    }

    /// Automatic check: only when enabled, running (not on standby), not in Demo mode, and due (once a month)
    func checkForUpdatesIfDue() {
        guard autoCheckUpdates, isActive, !isDemo, networkAllowed, updateTask == nil,
              UpdateCheck.isDue(lastChecked: lastUpdateCheck, lastFailed: lastUpdateCheckFailed) else { return }
        checkForUpdates()
    }

    /// Check now (button in Settings, "Check for Updates…" in the menu). No network on standby or in Demo mode.
    func checkForUpdates() {
        guard isActive, !isDemo, updateTask == nil else { return }
        updateState = .checking
        let current = appVersion
        let channel = updateChannel
        updateTask = Task { [weak self] in
            let result: UpdateState
            do {
                let latest = try await UpdateCheck.fetchLatest(channel: channel)
                result = UpdateCheck.isNewer(latest.version, than: current) ? .available(latest) : .upToDate
            } catch UpdateCheck.CheckError.noRelease {
                result = .noRelease
            } catch {
                result = .failed
            }
            // Stopped by standby, which already cleared the handle (it may belong to a newer check by now)
            guard !Task.isCancelled, let self else { return }
            self.updateState = result
            if result != .failed {
                let now = Date()
                self.lastUpdateCheck = now
                self.lastUpdateCheckFailed = nil
                UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
            } else {
                self.lastUpdateCheckFailed = Date()   // In memory only: a relaunch may try once more
            }
            self.updateTask = nil
            self.saveSnapshot()
        }
    }

    func checkStaticDataIfDue() {
        guard staticCheckTask == nil, !isDemo, networkAllowed else { return }   // No network in Demo mode, or when it's off in Settings
        let store: SubwayMapStore
        switch system {
        case .subway:
            store = SubwayMapStore.shared
        case .bus:
            store = SubwayMapStore.bus
        case .train, .ferry, .path, .njTrain, .lightRail, .njBus, .njFerry:
            return   // Train, PATH and ferry data are checked by FerryStore (see refreshFerry); the timetable part of buses, see refreshBus
        }
        guard store.isDue() else { return }
        staticCheckTask = Task { [weak self] in
            _ = try? await store.checkForUpdate(current: nil)
            // Cancelled by standby: standby already cleared the handle, which may belong to a newer check by now
            guard !Task.isCancelled else { return }
            self?.staticCheckTask = nil
        }
    }

    /// The source list (see SourceListStore): asked for with the monthly check, and daily while an operator's data can't be downloaded
    /// for a reason on its side. Only when "Start"ed, not in Demo mode, with the network allowed
    func checkSourceListIfDue(now: Date = Date()) {
        guard sourceListTask == nil, isActive, !isDemo, networkAllowed, SourceListStore.isDue(now: now),
              sourceListNetworkFailedAt.map({ now.timeIntervalSince($0) >= SourceListStore.networkRetry }) ?? true else { return }
        startSourceListCheck(now: now)
    }

    /// Check Timetables Now asks for the list first, so a moved address is used by the check right after (waits for one already running)
    func checkSourceListNow() async {
        guard isActive, !isDemo, networkAllowed else { return }
        let task: Task<Bool, Never>
        if let running = sourceListTask { task = running } else { task = startSourceListCheck(now: Date()) }
        _ = await task.value
    }

    @discardableResult
    private func startSourceListCheck(now: Date) -> Task<Bool, Never> {
        let repository = updateChannel.repository
        let task = Task { [weak self] () async -> Bool in
            let result = await SourceListStore.check(repository: repository, now: now)
            // Stopped by standby, which already cleared the handle (it may belong to a newer check by now)
            guard !Task.isCancelled, let self else { return false }
            self.sourceListTask = nil
            self.sourceListNetworkFailedAt = result.retrySoon ? now : nil
            guard result.listChanged else { return false }
            await self.sourceListChanged()
            return true
        }
        sourceListTask = task
        return task
    }

    /// A new source list is in use: the data read with the old one is read again (an operator turned off or on, the stations without
    /// times), and an operator that failed is tried again right away (see FerryStore.listChanged)
    private func sourceListChanged() async {
        let stores: [FerryStore] = [.shared, .train, .path, .lightRail, .njBus]
        for store in stores { await store.listChanged() }
        activeMemo = nil
        stationInputs += 1
        refresh()
    }

    /// The monthly check swapped the station list: reload, and update nearby stations, lines and direction names (the widget reads the new one when downloading itself too).
    func reloadStaticData() {
        let subway = Self.loadSubwayData()
        if subway.catalog != nil {
            catalog = subway.catalog
            express = subway.express
            catalogError = nil
        }
        busCatalogFailed = false
        if busCatalogStorage != nil { busCatalogStorage = try? BusCatalog.loadCurrent() }
        tramHours = RooseveltIslandTram.loadCurrentHours()
        refresh()
    }
}
