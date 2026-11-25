import Foundation
import os
import SwiftUI
import TransitCore

/// Subway map and station lists (line paths, station directory, express data).
///
/// The app ships with a copy of MTA's official data, so it works offline. Keyed to the 1st of each month: the first time the subway is used after the 1st
/// (using the subway while the app is on, or opening the subway map), it downloads gtfs_subway.zip from MTA (about 6 MB, free, no key) to check for new data:
/// it regenerates the map, station directory and express data, replacing the old files if anything changed (the old ones are deleted); if nothing changed, nothing is touched.
/// The station directory and express data are stored in the folder shared with the widget (see StaticData), so the main window, menu bar and widget all use the new ones.
/// Only goes online while the app is on, never in standby.
///
/// Buses work the same way (to match the subway): the first time buses are used after the 1st of each month,
/// it downloads 6 bus data packages from MTA (about 60 MB total, free, no key), processes them one at a time, and generates a new bus map and bus stop directory.
///
/// Train and ferry maps come from the same data as their schedules and are checked together in FerryStore.
actor SubwayMapStore {
    enum Kind: Sendable {
        case subway, bus, train, ferry, path, lightRail, njBus

        init(_ system: TransitSystem) {
            switch system {
            case .subway: self = .subway
            case .bus: self = .bus
            case .train, .njTrain: self = .train
            case .ferry, .njFerry: self = .ferry
            case .path: self = .path
            case .lightRail: self = .lightRail
            case .njBus: self = .njBus
            }
        }

        /// Other maps drawn together with this one: bus map = MTA buses + NJ Transit and a few others (buses cover the whole metro area);
        /// subway map = MTA subway and tram + PATH + light rail (PATH and light rail count as subway)
        var companions: [Kind] {
            switch self {
            case .bus: return [.njBus]
            case .subway: return [.path, .lightRail]
            default: return []
            }
        }

        /// For logging
        var name: String {
            switch self {
            case .subway: return "subway"
            case .bus: return "bus"
            case .train: return "train"
            case .ferry: return "ferry"
            case .path: return "path"
            case .lightRail: return "lightrail"
            case .njBus: return "njbus"
            }
        }

        /// Trains and ferries: the map comes from the schedule data in FerryStore
        var usesFeed: Bool { self != .subway && self != .bus }

        /// Train, PATH or ferry data
        var feedStore: FerryStore {
            switch self {
            case .train: return FerryStore.train
            case .path: return FerryStore.path
            case .lightRail: return FerryStore.lightRail
            case .njBus: return FerryStore.njBus
            default: return FerryStore.shared
            }
        }
    }

    static let shared = SubwayMapStore(kind: .subway)
    static let bus = SubwayMapStore(kind: .bus)
    static let train = SubwayMapStore(kind: .train)
    static let ferry = SubwayMapStore(kind: .ferry)
    static let path = SubwayMapStore(kind: .path)
    static let lightRail = SubwayMapStore(kind: .lightRail)
    static let njBus = SubwayMapStore(kind: .njBus)

    static func store(_ kind: Kind) -> SubwayMapStore {
        switch kind {
        case .subway: return shared
        case .bus: return bus
        case .train: return train
        case .ferry: return ferry
        case .path: return path
        case .lightRail: return lightRail
        case .njBus: return njBus
        }
    }

    static var sourceURL: URL { TimetableStore.sourceURL }
    let kind: Kind
    private let lastCheckedKey: String
    /// Which data the last check generated (see contentVersion)
    private let contentKey: String

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .subway: lastCheckedKey = "subwayMap.lastChecked"
        case .bus: lastCheckedKey = "busMap.lastChecked"
        // The train (ferry) map and schedule are the same data, checked together
        case .train: lastCheckedKey = FerryStore.trainLastCheckedKey
        case .ferry: lastCheckedKey = FerryStore.ferryLastCheckedKey
        case .path: lastCheckedKey = FerryStore.pathLastCheckedKey
        case .lightRail: lastCheckedKey = FerryStore.lightRailLastCheckedKey
        case .njBus: lastCheckedKey = FerryStore.njBusLastCheckedKey
        }
        contentKey = lastCheckedKey + ".content"
    }

    /// Which data each check generates: 2 = map and station lists, 3 = plus Roosevelt Island Tram operating hours.
    /// Installs that only checked the map before check again after updating, without waiting for next month's 1st. When a check starts generating more data, bump this number.
    private static let contentVersion = 3

    /// After a failed check, wait at least this long (seconds) before retrying, so it doesn't download every time when offline
    private static let retryAfter: TimeInterval = 3600

    enum CheckResult: Equatable {
        case notDue
        case unchanged
        case updated
    }

    private var lastFailure: Date?
    /// The check in progress: when the map window and main window both need a check, download only once; standby stops it (see cancelChecks)
    private var running = SharedDownload<SubwayMap, Error>()

    private static let log = Logger(subsystem: "com.cheecar.catchmytrain", category: "StaticData")

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("CatchMyTrain", isDirectory: true)
            .appendingPathComponent(kind == .bus ? "bus_map.json" : "subway_map.json")   // trains and ferries don't use this file
    }

    private func bundled() -> SubwayMap? {
        switch kind {
        case .subway: return try? SubwayMap.loadBundled()
        case .bus: return try? BusMap.loadBundled()
        case .train, .ferry, .path, .lightRail, .njBus: return nil
        }
    }

    /// When the last update check happened (only successful online checks count).
    nonisolated var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
    }

    /// A check is due: not yet checked since this month's 1st, or the last check didn't generate station lists yet (see contentVersion),
    /// or its new station list wasn't taken and a day has passed (see DataUpdateGate; trains and ferries wait in FerryStore, see MonthlyCheck.held).
    nonisolated func isDue(now: Date = Date()) -> Bool {
        if SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now) { return true }
        if let key = listKey, DataChangeLog.load(now: now).entries[key]?.wantsRecheck(now: now) == true { return true }
        return !kind.usesFeed && UserDefaults.standard.integer(forKey: contentKey) < Self.contentVersion
    }

    /// The key of this store's station list in DataChangeLog (only the subway's and the city buses' are made by this store)
    private nonisolated var listKey: String? {
        switch kind {
        case .subway: return DataChangeLog.subwayKey
        case .bus: return DataChangeLog.cityBusKey
        case .train, .ferry, .path, .lightRail, .njBus: return nil
        }
    }

    /// The map in use: the downloaded one if new data was downloaded, otherwise the built-in one.
    func load() async -> SubwayMap? {
        // Trains, ferries: don't draw operators whose schedules have run out (e.g. the Statue of Liberty ferry between seasons)
        if kind.usesFeed { return await kind.feedStore.map() }
        return savedMap().map(withTram)
    }

    /// The map as saved (without the tram): the downloaded one, otherwise the built-in one
    private func savedMap() -> SubwayMap? {
        if let url = fileURL, let data = try? Data(contentsOf: url), let map = try? SubwayMap.decode(data) { return map }
        return bundled()
    }

    /// Adds the Roosevelt Island Tram to the subway map (the subway data has no tram)
    private func withTram(_ map: SubwayMap) -> SubwayMap {
        kind == .subway ? RooseveltIslandTram.adding(to: map) : map
    }

    /// Checks online when a check is due (see isDue). Checks immediately when `force` is true.
    /// If a check is already running (e.g. the map was opened after the main window started one), don't download again; wait for that check's result.
    func checkForUpdate(current: SubwayMap?, force: Bool = false, now: Date = Date()) async throws -> (CheckResult, SubwayMap?) {
        if kind.usesFeed {
            // Trains, ferries: the data is in FerryStore (if never downloaded, opening the map downloads it).
            // Opening the map waits like the main window does after a failed operator (see FerryStore.ensure); the button checks every operator
            if !force, current != nil, !SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now) { return (.notDue, nil) }
            let store = kind.feedStore
            if force {
                _ = try await store.update(now: now)
            } else {
                _ = try await store.ensure(allowNetwork: true, now: now)
            }
            let map: SubwayMap? = await store.map(now: now)
            let changed = map != nil && map != current
            // An operator still couldn't be downloaded: the map isn't up to date
            if !changed, await store.hasFailedOperators { throw URLError(.cannotLoadFromNetwork) }
            if changed { return (.updated, map) }
            return (.unchanged, nil)
        }
        // MTA's data is downloaded only while New York's area is kept (see AreaData); otherwise the app's own copy is used
        guard PlacesInUse.keeps(.newYork) else { return (.notDue, nil) }
        if running.task == nil, !force {
            guard isDue(now: now) else { return (.notDue, nil) }
            if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryAfter { return (.notDue, nil) }
        }
        let task = try check(now: now)
        defer { running.finished(task) }
        let fresh = withTram(try await task.value)
        if fresh == current { return (.unchanged, nil) }
        return (.updated, fresh)
    }

    /// Standby: stop the checks that started before it (no network in standby; one that a quick Start began is left alone, see DownloadGate).
    static func cancelChecks(before period: Int) async {
        await shared.cancelCheck(before: period)
        await bus.cancelCheck(before: period)
    }

    private func cancelCheck(before period: Int) {
        running.cancel(before: period)
    }

    /// Checks online once: downloads, generates the map and station lists, and swaps them in if anything changed.
    /// On standby, throws CancellationError without downloading (see DownloadGate).
    private func check(now: Date) throws -> Task<SubwayMap, Error> {
        let period = try DownloadGate.shared.begin()
        return running.join(period: period) { stopped in
            Task { () async throws -> SubwayMap in
                // Standby stopped a check that was still processing and it finished: it already saved this map, don't download it again
                if let done = try? await stopped?.value { return done }
                do {
                    let fresh: SubwayMap
                    if let made = try await self.download() {
                        try self.save(made)
                        fresh = made
                    } else {
                        // Its station lists were held back: the map in use stays, and is checked again with them (wantsRecheck)
                        guard let kept = self.savedMap() else { throw URLError(.cannotDecodeContentData) }
                        fresh = kept
                    }
                    self.lastFailure = nil
                    UserDefaults.standard.set(now, forKey: self.lastCheckedKey)
                    UserDefaults.standard.set(Self.contentVersion, forKey: self.contentKey)
                    return fresh
                } catch {
                    // Stops due to standby or quitting, or the network turned off in Settings, don't count as failures; retry right away next time
                    if !(error is CancellationError), (error as? URLError)?.code != .cancelled, NetworkSwitch.isAllowed { self.lastFailure = now }
                    let name = self.kind.name, reason = AppLog.reason(error)
                    Self.log.error("\(name, privacy: .public) check failed: \(reason, privacy: .public)")
                    throw error
                }
            }
        }
    }

    /// Subway: downloads gtfs_subway.zip, generates the map, and regenerates the station directory and express data.
    /// nil: the station lists were held back (they look wrong, see StaticData.SaveResult.implausible), so neither the map nor the
    /// timetable from the same download is used either: the three change together, once the data is taken (DataUpdateGate)
    private func download() async throws -> SubwayMap? {
        if kind == .bus { return try await downloadBus() }
        let zip = try await Self.fetch(Self.sourceURL, timeout: 60)
        try Task.checkCancellation()
        let result = try StaticRefresh.subway(zip: zip, labelsFrom: StationCatalog.labelSource(current: try? StationCatalog.loadCurrent()))
        if result.skipped > 0 {
            Self.log.notice("subway station lists: skipped \(result.skipped, privacy: .public) unreadable rows or stations")
        }
        let lists = saveLists { try StaticData.saveSubway(stations: result.stations, express: result.express) }
        if lists == .implausible {
            Self.log.notice("subway map and timetable: kept as they are, as the station lists were held back")
            await checkTram()
            return nil
        }
        // The "trip lookup" schedule also comes from this file: generate it too, no need to download again
        await TimetableStore.shared.ingest(zip: zip)
        await checkTram()
        return result.map
    }

    /// Buses: download and process the 6 data packages one at a time, discarding each when done (the large stop_times.txt is read while unzipping, using little memory).
    /// Like the tram check, a failure is only logged: the built-in map and stop list stay in use, no departure depends on them,
    /// and its host would record it as "MTA", the subway's monthly data, shown at subway stations for weeks (see NoticeScope.parts)
    private func downloadBus() async throws -> SubwayMap? {
        let refresh = StaticRefresh.Bus()
        for url in BusMap.sourceURLs {
            try Task.checkCancellation()
            let zip = try await Self.fetch(url, timeout: 120, recordsReach: false)
            try refresh.add(zip: zip)
        }
        try Task.checkCancellation()
        let (map, stops) = try refresh.finish()
        // Its stop list held back: the map in use stays too (see download)
        if saveLists({ try StaticData.saveBus(stops: stops) }) == .implausible {
            Self.log.notice("bus map: kept as it is, as the stop list was held back")
            return nil
        }
        return map
    }

    /// Roosevelt Island Tram: checks operating hours monthly along with the subway (headways per the RIOC website, see RooseveltIslandTram).
    /// If it can't download or the data looks wrong, only log it and keep the current one (the built-in one has the RIOC website's operating hours):
    /// the download isn't recorded in NetworkReach, so it never becomes a notice.
    private func checkTram() async {
        do {
            let zip = try await Self.fetch(RooseveltIslandTram.sourceURL, timeout: 60, recordsReach: false)
            let hours = try StaticRefresh.tramHours(zip: zip)
            let changed = try RooseveltIslandTram.saveHours(hours)
            let text = "\(hours.source), plausible \(hours.isPlausible), changed \(changed)"
            Self.log.notice("tram hours: \(text, privacy: .public)")
            if changed { Task { @MainActor in NotificationCenter.default.post(name: .staticDataDidChange, object: nil) } }
        } catch {
            if NetworkReach.isCancellation(error) { return }
            let reason = AppLog.reason(error)
            Self.log.error("tram check failed: \(reason, privacy: .public)")
        }
    }

    /// - Parameter recordsReach: false for a download whose problems are only logged (see checkTram, downloadBus)
    private static func fetch(_ url: URL, timeout: TimeInterval, recordsReach: Bool = true) async throws -> Data {
        // No Accept header: some servers answer "Accept: application/zip" with 406 (NYC Ferry does)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let result: (Data, URLResponse)
        if recordsReach {
            // Monthly data downloads: if something goes wrong, keep warning until the next success (URL changed, a web page came back, etc.)
            result = try await URLSession.noCache.reachData(for: request, lasting: true)
        } else {
            try NetworkSwitch.check()
            result = try await URLSession.noCache.limitedData(for: request, limit: DownloadLimit.package)
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Saves newly generated station lists (see StaticData.saveSubway). If saving fails (e.g. the shared folder is unavailable), only log it; the map is unaffected;
    /// when new ones are swapped in (or reverted to the built-in ones), notify the main window to reload. Returns what saving did
    /// (nil when it failed)
    @discardableResult
    private func saveLists(_ body: () throws -> StaticData.SaveResult) -> StaticData.SaveResult? {
        let name = kind.name
        do {
            let result = try body()
            let text = String(describing: result)
            Self.log.notice("\(name, privacy: .public) station lists: \(text, privacy: .public)")
            if result == .saved || result == .notNewer {
                Task { @MainActor in NotificationCenter.default.post(name: .staticDataDidChange, object: nil) }
            }
            return result
        } catch {
            let reason = AppLog.reason(error)
            Self.log.error("\(name, privacy: .public) station lists not saved: \(reason, privacy: .public)")
            return nil
        }
    }

    /// Replaces the old file with the new map: writes a temp file and swaps it in whole, deleting the old one, so no half-written file is left.
    /// When the new data matches the built-in data, delete the downloaded file and use the built-in one.
    private func save(_ map: SubwayMap) throws {
        guard let url = fileURL else { return }
        if let bundled = bundled(), bundled == map {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try map.encoded().write(to: url, options: .atomic)
    }
}

extension Notification.Name {
    /// The monthly check changed station lists (subway station directory, express data or bus stop directory): the main window reloads.
    static let staticDataDidChange = Notification.Name("CatchMyTrain.staticDataDidChange")
    /// A data check wrote its entry in the log of data checks (DataChangeLog): Settings reads it again
    static let dataChangesDidChange = Notification.Name("CatchMyTrain.dataChangesDidChange")
}

/// Ferry map (works like the subway): data comes from FerryStore (official data from NYC Ferry, Staten Island Ferry, NY Waterway, Seastreak,
/// and the Statue of Liberty ferry).

/// State for the map window. Released when the map window closes, to save memory. Another transit mode is shown on the same map
/// (show(kind:)): a map view taken away isn't always let go of, so the window keeps one map
@MainActor
final class SubwayMapModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updated
        case failed
    }

    @Published private(set) var map: SubwayMap? {
        didSet { lines = MapLines.make(map) }
    }
    /// Polylines drawn on the map (regenerated only when the map data changes)
    @Published private(set) var lines: [MapLines] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    /// The day this map's data is up to date as of: the earliest of its parts' (each timetable's earliest operator, see
    /// FerryStore.upToDate; MTA's data downloads whole, so its last check). nil while a part never got through
    @Published private(set) var upToDate: Date?

    private var task: Task<Void, Never>?
    private(set) var kind: SubwayMapStore.Kind
    /// Reads a mode's map with the ones drawn with it (loadAll). Tests read slowly or quickly here
    var readMap: (SubwayMapStore.Kind) async -> SubwayMap? = { await SubwayMapModel.loadAll($0) }
    private var store: SubwayMapStore { SubwayMapStore.store(kind) }

    init(kind: SubwayMapStore.Kind = .subway) {
        self.kind = kind
    }

    /// Called when opening the map: reads the map, and checks for updates when needed (first time after the 1st of each month, see SubwayMapStore.isDue).
    /// - Parameter allowNetwork: true only while the app is on (no network in standby).
    func open(allowNetwork: Bool) {
        task?.cancel()
        task = Task {
            let store = store
            if map == nil {
                let loaded = await loadAll()
                // Released or another transit mode meanwhile: what was read is the old one's
                guard !Task.isCancelled else { return }
                map = loaded
            }
            lastChecked = store.lastChecked
            noteUpToDate()
            // If ferry data has never been downloaded, opening the map downloads it
            let companionDue = kind.companions.contains { SubwayMapStore.store($0).isDue() }
            guard allowNetwork, store.isDue() || companionDue || map == nil else { return }
            await check(force: false)
        }
    }

    /// This map, plus the others drawn with it (buses: MTA + NJ Transit and a few others; subway: MTA + PATH + light rail)
    private func loadAll() async -> SubwayMap? {
        await readMap(kind)
    }

    /// Reads only this map (plus the ones drawn with it) from disk, without checking for updates. Also used by the location picker map's "Whole Map" button.
    static func loadAll(_ kind: SubwayMapStore.Kind) async -> SubwayMap? {
        var result = await SubwayMapStore.store(kind).load()
        for companion in kind.companions {
            guard let other = await SubwayMapStore.store(companion).load() else { continue }
            result = result.map { $0.merged(with: other) } ?? other
        }
        return result
    }

    /// Checks for updates now (the "Check for Updates" button).
    func checkNow() {
        task?.cancel()
        task = Task { await check(force: true) }
    }

    private func check(force: Bool) async {
        status = .checking
        var results: [SubwayMapStore.CheckResult] = []
        var failed = false
        for k in [kind] + kind.companions {
            do {
                let store = SubwayMapStore.store(k)
                let (result, _) = try await store.checkForUpdate(current: await store.load(), force: force)
                results.append(result)
            } catch {
                // Stopped by standby (or refused there): not a failed check
                if !NetworkReach.isCancellation(error) { failed = true }
            }
            if Task.isCancelled { return }
        }
        if results.contains(.updated) || (map == nil && !results.isEmpty) {
            let loaded = await loadAll()
            if Task.isCancelled { return }
            map = loaded
        }
        if Task.isCancelled { return }
        // A part that failed is said even when another part was updated (that part's new data is shown all the same): "updated"
        // alone would hide that the failed part is still the old one
        if failed {
            status = .failed
        } else if results.contains(.updated) {
            status = .updated
        } else if results.contains(.unchanged) {
            status = .upToDate
        } else {
            status = .idle
        }
        lastChecked = store.lastChecked
        noteUpToDate()
    }

    private func noteUpToDate() {
        let parts = ([kind] + kind.companions).map { k in k.usesFeed ? k.feedStore.upToDate : SubwayMapStore.store(k).lastChecked }
        upToDate = parts.contains { $0 == nil } ? nil : parts.compactMap { $0 }.min()
    }

    func release() {
        task?.cancel()
        task = nil
        map = nil
        if status == .checking { status = .idle }
    }

    /// Another transit mode on the same map: what was read or is being read for the one before goes, and nothing is known yet
    /// about the new one. open(allowNetwork:) reads it
    func show(kind new: SubwayMapStore.Kind) {
        guard new != kind else { return }
        release()
        kind = new
        status = .idle
        lastChecked = nil
        upToDate = nil
    }
}

// MARK: - The source list

/// Where each operator's data is downloaded from, and the stations without times (see SourceList). The copy saved from the repository
/// is put in use at launch, before any data is read. The repository's copy is asked for once a month, and once a day while an
/// operator's data can't be downloaded for a reason on its side (its new address may be in the list by then); only while the app is
/// on, not in Demo mode, with the network allowed (see TransitModel.checkSourceListIfDue). It sends nothing about the user. The widget
/// keeps the list in code: it can't read this app's folder
enum SourceListStore {
    /// When the repository was last asked, whatever came back; and when it last gave a list that passed every check
    static let lastTriedKey = "sourceList.lastTried"
    static let lastCheckedKey = "sourceList.lastChecked"
    /// Since when operators' own problems have lasted (see NetworkReach.keepHistory)
    static let historyKey = "networkReach.history"
    /// After a network failure, asked again this much later. An answer from GitHub (a 404 while the repository is private too) or a
    /// list that didn't pass the checks waits until it's due again: it isn't shown, and doesn't make the app ask more often
    static let networkRetry: TimeInterval = 3600

    enum Result: Equatable {
        case unchanged
        /// A newer list is in use
        case changed
        case networkFailed
        /// The list came but couldn't be saved: used in memory when newer (changed), not marked as checked, asked again like after
        /// a network failure (otherwise a failed save would wait a month unnoticed)
        case notSaved(changed: Bool)

        /// A newer list is in use now
        var listChanged: Bool { self == .changed || self == .notSaved(changed: true) }
        /// Ask again after SourceListStore.networkRetry
        var retrySoon: Bool {
            switch self {
            case .networkFailed, .notSaved: return true
            case .unchanged, .changed: return false
            }
        }
    }

    private static let log = Logger(subsystem: "com.cheecar.catchmytrain", category: "StaticData")

    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CatchMyTrain", isDirectory: true)
            .appendingPathComponent(SourceList.fileName)
    }

    /// When the repository last gave a list that passed every check (nil: not yet)
    static var lastChecked: Date? { UserDefaults.standard.object(forKey: lastCheckedKey) as? Date }

    /// The saved copy (nil when there is none, or it doesn't pass this version's checks)
    static func saved() -> SourceList? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? SourceList.checked(data)
    }

    /// At launch, before any data is read: the newer of the saved list and the one that came with the app (a newer version's copy can
    /// be newer than one saved before the update), and since when operators' problems have lasted. The tests' host keeps the list in
    /// code and saves nothing
    static func launch() {
        guard !TransitModel.isTestHost else { return }
        if let list = SourceList.newest([saved(), SourceList.bundled()]) { SourceList.use(list) }
        let history = UserDefaults.standard.data(forKey: historyKey)
            .flatMap { try? JSONDecoder().decode([String: NetworkReach.History].self, from: $0) } ?? [:]
        NetworkReach.keepHistory(history) { kept in
            if kept.isEmpty {
                UserDefaults.standard.removeObject(forKey: SourceListStore.historyKey)
            } else if let data = try? JSONEncoder().encode(kept) {
                UserDefaults.standard.set(data, forKey: SourceListStore.historyKey)
            }
        }
    }

    /// Due once a month, and once a day while an operator's own problem lasts (not the developer-only ones, see TransitModel)
    static func isDue(now: Date = Date()) -> Bool {
        let lastTried = UserDefaults.standard.object(forKey: lastTriedKey) as? Date
        let problem = NetworkReach.problemHistory.keys.contains { !TransitModel.developerOnlyProviders.contains($0) }
        return SourceList.isDue(lastTried: lastTried, operatorProblem: problem, now: now)
    }

    /// Asks the repository for its list (the caller decides when, see isDue), saves it, and puts it in use when it's newer than the
    /// copy that came with the app
    static func check(repository: String, now: Date = Date()) async -> Result {
        let defaults = UserDefaults.standard
        do {
            let (list, data) = try await SourceList.fetch(repository: repository)
            var saved = true
            if let url = fileURL {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    saved = false
                    let reason = AppLog.reason(error)
                    log.error("source list not saved, asked again later: \(reason, privacy: .public)")
                }
            }
            // Marked as checked only once it's saved
            if saved {
                defaults.set(now, forKey: lastTriedKey)
                defaults.set(now, forKey: lastCheckedKey)
            }
            guard let newest = SourceList.newest([list, SourceList.bundled()]), newest != SourceList.current.list else {
                return saved ? .unchanged : .notSaved(changed: false)
            }
            SourceList.use(newest)
            let updated = newest.updated
            log.notice("source list of \(updated, privacy: .public) in use")
            return saved ? .changed : .notSaved(changed: true)
        } catch {
            // Stopped by standby: asked again on the next Start
            if NetworkReach.isCancellation(error) { return .unchanged }
            let reason = AppLog.reason(error)
            log.notice("source list not checked: \(reason, privacy: .public)")
            if error is URLError { return .networkFailed }
            defaults.set(now, forKey: lastTriedKey)
            return .unchanged
        }
    }
}
