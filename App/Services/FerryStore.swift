import Foundation
import TransitCore

/// Ferry data (NYC Ferry, Staten Island Ferry, NY Waterway, Seastreak, and Statue of Liberty ferry timetables, piers and routes)
/// and train data (LIRR and Metro-North timetables, stations and lines): one instance per system (FerryStore.shared and FerryStore.train),
/// same format and algorithm (see FerryFeed).
///
/// The app doesn't ship this data: the first time the user switches to ferry (or train), it downloads each operator's feed on this Mac (ferries total ~100 KB,
/// trains about 6 MB, all free, no key needed), processes it and stores it in Application Support.
/// Keyed to the 1st of each month: the first use (or map open) after the 1st checks for new data and replaces the old files if there is any.
/// If one operator's timetable runs out (e.g. the Statue of Liberty ferry season ends before the new one is published), the train timetable is about to run out
/// (LIRR data only goes a few weeks ahead), or an operator's timetable ends within the next week: don't wait for next month, check again daily,
/// so a new one is in use before the old one ends.
/// Only goes online while the app is active, never while idle.
/// Each operator downloads separately: if one fails, the others still show (the missing one uses the last saved copy),
/// and only the failed one is tried again, after a wait that grows with each failure (see MonthlyCheck).
actor FerryStore {
    static let shared = FerryStore(system: .ferry)
    static let train = FerryStore(system: .train)
    /// PATH: stations, lines and map (the timetable is expired; trips use only realtime data, see PathLive)
    static let path = FerryStore(system: .path)
    /// Light rail (NJ Transit's three lines; same feed as NJ Transit rail, stored separately). NJ Transit rail lives in train
    /// (there is no New York vs New Jersey split; trains cover the whole metro area).
    static let lightRail = FerryStore(system: .lightRail)
    /// Timetable-only bus operators (NJ Transit etc.): the data is large, stored as a compact binary file (NJBusIndex), and only the nearby chunk is loaded when used
    static let njBus = FerryStore(system: .njBus)

    /// This mode's timetable data (for bus, its timetable part; subway never uses it)
    static func store(for system: TransitSystem) -> FerryStore {
        switch system.timetableSystem {
        case .train: return train
        case .path: return path
        case .lightRail: return lightRail
        case .njBus: return njBus
        default: return shared
        }
    }

    /// This mode's timetable part (for subway, two parts: PATH and light rail, see TransitSystem.timetableSystems)
    static func stores(for system: TransitSystem) -> [FerryStore] {
        system.timetableSystems.map { store(for: $0) }
    }

    /// Timetable part of subway: PATH and light rail (grouped with subway), merged together.
    /// With allowNetwork, download any not yet downloaded or due for the monthly check; otherwise read only what's stored.
    /// failed: one part is missing and can't be downloaded. An operator whose timetable ran out doesn't count (see FerryFeed.active).
    /// missing: the parts (.path, .lightRail) with no data on this Mac, or, with `near`, without an operator whose data is downloaded
    /// only for places in its area, `near` among them (see lacksOperators).
    static func subwayPart(allowNetwork: Bool, now: Date, near: Coordinate? = nil)
        async -> (feed: FerryFeed?, failed: Bool, missing: [TransitSystem]) {
        var feeds: [FerryFeed] = []
        var failed = false
        var missing: [TransitSystem] = []
        var key: [String] = [String(Int(now.timeIntervalSince1970 / 86400))]
        for store in [path, lightRail] {
            var feed: FerryFeed?
            var stopped = false
            if allowNetwork {
                do {
                    feed = try await store.ensure(allowNetwork: true, now: now)
                } catch {
                    // Stopped by standby: not a failed download
                    stopped = NetworkReach.isCancellation(error)
                    feed = await store.load()
                }
            } else {
                feed = await store.load()
            }
            key.append("\(store.system.rawValue):\(await store.generation):\(feed == nil ? 0 : 1)")
            var lacking = false
            if let near { lacking = await store.lacksOperators(at: near) }
            if let feed { feeds.append(feed) }
            // A part with no data none of whose operators is downloaded for the places in use (PATH while every place is in
            // Greater Boston) has nothing to download: not missing, and not a failed download
            let unused = feed == nil && store.wantedSources.isEmpty
            if (feed == nil && !unused) || lacking {
                missing.append(store.system)
                if allowNetwork, !stopped { failed = true }
            }
        }
        // Data unchanged and still the same day: reuse the last merged copy instead of re-merging on every refresh (each merge costs another copy in memory)
        if let cached = await subwayCache.get(key) { return (cached, failed, missing) }
        let combined = FerryFeed.combining(feeds.map { $0.active(from: now) })
        await subwayCache.set(key, combined)
        return (combined, failed, missing)
    }

    /// PATH and light rail merged for subway (see subwayPart)
    private static let subwayCache = CombinedCache()

    /// The last merged data and which data it was merged from
    private actor CombinedCache {
        private var key: [String]?
        private var feed: FerryFeed?
        func get(_ key: [String]) -> FerryFeed?? { key == self.key ? .some(feed) : nil }
        func set(_ key: [String], _ feed: FerryFeed?) { self.key = key; self.feed = feed }
        func clear() { key = nil; feed = nil }
    }

    /// Release the merged PATH and light rail when subway isn't in use
    static func releaseSubwayPart() async {
        await subwayCache.clear()
        for store in [path, lightRail] { await store.release() }
    }

    /// The separate New Jersey rail file older versions kept (that data is in train.json): delete it to save space
    static func removeLegacyFiles() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CatchMyTrain", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("njtrain.json"))
        UserDefaults.standard.removeObject(forKey: "njTrainData.lastChecked")
        // Data files of bus operators no longer used (when one is removed from the code later): delete them, keep no stale data.
        // One the source list turned off keeps its file (it isn't read meanwhile, see SourceList)
        let current = Set(RegionalBusFeed.builtIn.map(\.fileName))
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasPrefix("bus-") && name.hasSuffix(".bin") && !current.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        // Earlier versions downloaded the monthly data through the shared system download cache, which may still hold old zips: clear it once (downloads don't use the cache)
        if !UserDefaults.standard.bool(forKey: "clearedURLCacheOnce") {
            URLCache.shared.removeAllCachedResponses()
            UserDefaults.standard.set(true, forKey: "clearedURLCacheOnce")
        }
        // Temporary zips left behind by quitting mid-download
        let tmp = FileManager.default.temporaryDirectory
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            for name in names where name.hasPrefix("cmt-bus-") && name.hasSuffix(".zip") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
        SharedPackage.removeOld()
    }

    static let ferryLastCheckedKey = "ferryData.lastChecked"
    static let trainLastCheckedKey = "trainData.lastChecked"
    static let pathLastCheckedKey = "pathData.lastChecked"
    static let lightRailLastCheckedKey = "lightRailData.lastChecked"
    static let njBusLastCheckedKey = "njBusData.lastChecked"
    /// After a failed check, wait at least this long before retrying (seconds)
    static let retryAfter: TimeInterval = MonthlyCheck.firstRetry
    /// When an operator's timetable has run out, check this often for a new one (seconds)
    static let idleRecheckAfter: TimeInterval = 24 * 3600

    nonisolated let system: TransitSystem
    /// The operators in this system, without the ones the source list turned off (see SourceList)
    nonisolated var sources: [FerryFeed.Source] { FerryFeed.Source.cases(for: system) }
    /// The ones downloaded now: an operator downloaded only for places in its area (SEPTA Metro) waits until one is in use, and
    /// meanwhile what it downloaded before stays, without updates (see FerryFeed.Source.isWanted)
    nonisolated var wantedSources: [FerryFeed.Source] { sources.filter(\.isWanted) }
    nonisolated let lastCheckedKey: String
    let fileName: String

    /// In-memory data: no map shapes, not needed for computing trips; the map is read from file (see map)
    var feed: FerryFeed?
    /// How many times the data has changed (incremented on each new download), used to tell whether merged data is still valid (see subwayPart)
    var generation = 0
    var lastFailure: Date?
    /// Time of the last check that found nothing to download: for a while after (notDueRecheck) use stored data directly instead of scanning the whole dataset every refresh
    var notDueAt: Date?
    static let notDueRecheck: TimeInterval = 15 * 60
    /// Last time only the operators whose "timetable is about to run out" were checked (at most once a day)
    var idleCheckedAt: Date?
    /// This month's check per operator (bus operator codes, or train and ferry operator names): which ones are done, and when to retry a failed one
    var monthlyCheck = MonthlyCheck()
    /// Operators downloaded and read since the app started, so read with this version's way of reading the packages: a copy built by an older
    /// version counts as current once every operator in it has been read again (see FerryFeed.contentVersion)
    var readThisRun: Set<FerryFeed.Source> = []
    /// When each operator (train and ferry operators; bus company codes) was last downloaded, read and saved by this store in this
    /// run. A check that waited its turn for a large package (OneAtATime) while another check of the same store did the same work
    /// isn't done again: the refresh every 30 seconds and a package handed over (handOver) could queue the same build two or three times
    private var builtAt: [String: Date] = [:]
    /// The chunk for trip planning (near another place): reused when the same place is queried again
    var detached: (key: String, feed: FerryFeed?)?
    /// The download in progress (with the operators it asked for), shared by everyone who asks meanwhile; standby stops it (see cancelDownloads)
    var running = SharedDownload<(feed: FerryFeed, requested: Set<FerryFeed.Source>), Error>()

    // Timetable-only bus operators (NJ Transit, NICE, Suffolk..., see RegionalBusFeed): one full dataset per operator (NJBusIndex),
    // the chunk in use now (feed, nearby stops of all operators merged) and its center and size
    /// Loaded only to cut a chunk, check for updates or draw the map, then released (the full data is large; normally only the nearby chunk is kept)
    var busIndexes: [String: NJBusIndex]?
    /// Each operator's service days (tiny, always kept): to tell which operator is missing or running out without loading the full data
    var busServiceDays: [String: Set<Int>]?
    /// Each operator's stop lat/lon bounds (tiny, always kept): when leaving the current chunk, reload only the operators in reach, not all 13
    var busBounds: [String: NJBusIndex.Bounds] = [:]

    /// One line in the log for each operator whose timetable couldn't be downloaded or read: its code and the error's kind and code
    /// (see AppLog.reason), never a place. Standby stopping a download isn't a failure and isn't logged
    static func logFailed(_ code: String, _ error: Error) {
        if NetworkReach.isCancellation(error) { return }
        if isBadData(error) {
            AppLog.data.notice("data unreadable: \(code, privacy: .public) \(AppLog.reason(error), privacy: .public)")
        } else {
            AppLog.data.notice("download failed: \(code, privacy: .public) \(AppLog.reason(error), privacy: .public)")
        }
    }

    /// The package came but can't be read (damaged, too large, a file missing, not GTFS): not a failed download. NetworkReach
    /// notes it as unreadable data (see NetworkReach.reading), so the stations say it's on the operator's side, not the network
    static func isBadData(_ error: Error) -> Bool {
        if error is ZipReader.ZipError || error is TimetableError || error is ProtobufError || error is DecodingError { return true }
        switch error as? FeedFetchError {
        case .tooLarge?, .webPage?: return true
        default: return false
        }
    }

    var sliceCenter: Coordinate?
    /// The chunk used before the location is known (empty, carrying only operator names): computed once and kept instead of loading the full data every refresh
    var emptySlice: FerryFeed?
    var sliceRadius: Double = 0
    var busRunning = SharedDownload<[String: Result<Data, Error>], Never>()
    /// Data is stored as NJBusIndex (New Jersey buses), and a chunk is cut when used
    nonisolated var isIndexed: Bool { system == .njBus }

    init(system: TransitSystem) {
        self.system = system
        switch system {
        case .train:
            lastCheckedKey = Self.trainLastCheckedKey
            fileName = "train.json"
        case .path:
            lastCheckedKey = Self.pathLastCheckedKey
            fileName = "path.json"
        case .lightRail:
            lastCheckedKey = Self.lightRailLastCheckedKey
            fileName = "lightrail.json"
        case .njBus:
            lastCheckedKey = Self.njBusLastCheckedKey
            fileName = "njbus.bin"
        default:
            lastCheckedKey = Self.ferryLastCheckedKey
            fileName = "ferry.json"
        }
    }

    nonisolated var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
    }

    /// The last download of some operator failed (the map window then doesn't say the data is up to date)
    var hasFailedOperators: Bool { monthlyCheck.hasFailures }

    /// The operators whose downloads count (for this month's check, and for the day the data is up to date as of): the ones wanted now
    nonisolated var operatorKeys: Set<String> {
        isIndexed ? Set(RegionalBusFeed.all.filter(\.isWanted).map(\.code)) : Set(wantedSources.map(\.rawValue))
    }

    /// The names its operators' download problems are noted under (see NetworkReach and TransitModel.timetableNotices)
    nonisolated var providerNames: Set<String> {
        isIndexed ? Set(RegionalBusFeed.all.map(\.name)) : Set(sources.map(\.name))
    }

    // MARK: The day the timetables are up to date as of

    nonisolated var operatorDatesKey: String { lastCheckedKey + ".operators" }

    /// The time each operator last downloaded fine. Updating from a version that kept only the store's last check, every operator
    /// starts from that one (see DownloadDates.starting)
    nonisolated var operatorDates: [String: Date] {
        if let saved = UserDefaults.standard.dictionary(forKey: operatorDatesKey) as? [String: Date] { return saved }
        return DownloadDates.starting(lastChecked: lastChecked, operators: operatorKeys)
    }

    /// The day this data is up to date as of: the earliest of its operators' last good downloads, so it stops at an operator that
    /// keeps failing. nil while an operator never got through
    nonisolated var upToDate: Date? {
        DownloadDates.upToDate(operatorDates, of: operatorKeys)
    }

    /// This store's operators at a station: train and ferry operators by its station IDs, bus companies by its routes
    nonisolated func operatorKeys(stationIDs: [String], routes: [String]) -> Set<String> {
        if isIndexed { return Set(routes.compactMap { RegionalBusFeed.of(route: $0)?.code }).intersection(operatorKeys) }
        return Set(wantedSources.filter { source in stationIDs.contains { source.owns(id: $0) } }.map(\.rawValue))
    }

    /// The day the data of these operators (from operatorKeys(stationIDs:routes:)) is up to date as of: nil while one of them
    /// never got through
    nonisolated func upToDate(of keys: Set<String>) -> Date? {
        DownloadDates.upToDate(operatorDates, of: keys)
    }

    /// These operators downloaded fine just now (bus operator codes, or train and ferry operator IDs)
    /// These operators were downloaded, read and saved just now (see builtAt)
    func noteBuilt(_ keys: [String]) {
        let now = Date()
        for key in keys { builtAt[key] = now }
    }

    /// Every one of these operators was downloaded, read and saved since `asked` (none: false)
    func built(_ keys: [String], since asked: Date) -> Bool {
        !keys.isEmpty && keys.allSatisfy { (builtAt[$0] ?? .distantPast) >= asked }
    }

    func noteDownloaded(_ keys: Set<String>, now: Date) {
        guard !keys.isEmpty else { return }
        var dates = operatorDates
        for key in keys { dates[key] = now }
        UserDefaults.standard.set(dates, forKey: operatorDatesKey)
    }

    /// The source list changed what this data is made of: an operator turned off or on, or an address moved. The data is read again
    /// on next use, without the operators turned off, and an operator that failed is tried again right away (its address may have moved)
    func listChanged() {
        release()
        monthlyCheck.forgetFailures()
        lastFailure = nil
        generation += 1
        UserDefaults.standard.removeObject(forKey: coverageKey)
        forgetUnknown()
        // The names follow the operators turned on: written again from the data the next time it's read
        if let url = namesURL { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CatchMyTrain", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: Station names for the place search

    /// The small list of its station names beside the timetable (e.g. train.names.json; see StationNames): the place search reads
    /// it instead of the timetable. Written with the timetable, and from it when it's read and the list isn't there yet
    nonisolated var namesURL: URL? {
        fileURL.map { $0.deletingPathExtension().appendingPathExtension("names.json") }
    }

    /// The station names of the timetable on this Mac, without reading it; none for New Jersey buses (bus stops aren't listed: too
    /// many, with names alike) or while there is no list
    nonisolated func stationNames() -> [StationName] {
        guard !isIndexed, let url = namesURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StationName].self, from: data)) ?? []
    }

    /// Writes the names of this data (without the operators the source list turned off)
    func saveNames(_ feed: FerryFeed) {
        guard !isIndexed, let url = namesURL else { return }
        do {
            try JSONEncoder().encode(StationNames.of(feed.withoutTurnedOff())).write(to: url, options: .atomic)
        } catch {
            AppLog.data.error("Saving the station names of \(self.fileName, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
        }
    }

    /// Already downloaded data (nil if none; no network).
    /// For New Jersey buses, only the chunk within radius meters of near (uses the last place if near isn't given).
    func load(near: Coordinate? = nil, radius: Double = 3000) -> FerryFeed? {
        if isIndexed { return busSlice(near: near, radius: radius) }
        if let feed { return feed }
        // An operator the source list turned off is as if the app didn't have it
        feed = readFile()?.withoutShapes().withoutTurnedOff()
        if let feed {
            saveCoverage(feed)
            noteUnknown(feed)
            // Data saved before its names were kept beside it, or by a source list since changed: from what was just read
            if let url = namesURL, !FileManager.default.fileExists(atPath: url.path) { saveNames(feed) }
        }
        return feed
    }

    /// An operator downloaded only for places in its area (see DownloadArea) with no data on this Mac, though this place is in its
    /// area: right after such a place comes into use, until its download is done, or when that failed. An empty board then says the
    /// timetables are downloading (or couldn't be downloaded), not that nothing is nearby
    func lacksOperators(at place: Coordinate) -> Bool {
        if isIndexed {
            let local = RegionalBusFeed.all.filter { $0.downloadArea?.contains(place) == true }
            guard !local.isEmpty else { return false }
            let have = busDays() ?? [:]
            return local.contains { have[$0.code] == nil }
        }
        let local = sources.filter { $0.downloadArea?.contains(place) == true }
        guard !local.isEmpty else { return false }
        let have = load()?.sources ?? []
        return local.contains { !have.contains($0) }
    }

    // MARK: Which operators' timetables have run out (shown in Settings)

    var coverageKey: String { "coverage." + fileName }

    /// Which days each operator has service: computed directly when the data is in memory; otherwise use the small saved result instead of loading the whole timetable
    /// nil if neither exists or the saved one is too old.
    func coverage(now: Date = Date()) -> FerryFeed.Coverage? {
        if let feed { return feed.coverage(from: now) }
        guard let data = UserDefaults.standard.data(forKey: coverageKey),
              let saved = try? JSONDecoder().decode(FerryFeed.Coverage.self, from: data),
              saved.isUsable(from: now) else { return nil }
        return saved
    }

    // MARK: What its data has that this version doesn't know (shown in Settings)

    /// Where what this store's data has that this version doesn't know is kept (UnknownData), beside its coverage
    nonisolated var unknownKey: String { "unknown." + lastCheckedKey }

    /// Notes what this data has that this version doesn't know (UnknownData: train lines and the like not in the line table,
    /// PATH stations its live data can't be matched to), as it's read or saved, so Settings tells it without loading the data.
    /// Settings is told when it changed
    func noteUnknown(_ feed: FerryFeed) {
        guard !isIndexed else { return }
        var found = UnknownData.lines(feed: feed)
        if let path = UnknownData.path(feed: feed) { found.append(path) }
        let data = try? JSONEncoder().encode(found)
        guard UserDefaults.standard.data(forKey: unknownKey) != data else { return }
        UserDefaults.standard.set(data, forKey: unknownKey)
        Task { @MainActor in NotificationCenter.default.post(name: .dataChangesDidChange, object: nil) }
    }

    /// The data changed without being read (operators removed or turned off): noted again the next time it's read
    func forgetUnknown() {
        guard UserDefaults.standard.data(forKey: unknownKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: unknownKey)
        Task { @MainActor in NotificationCenter.default.post(name: .dataChangesDidChange, object: nil) }
    }

    /// What the timetables' data in use has that this version doesn't know, as their stores last noted it
    nonisolated static func savedUnknownData() -> [UnknownData.Finding] {
        [shared, train, path, lightRail].flatMap { store -> [UnknownData.Finding] in
            guard let data = UserDefaults.standard.data(forKey: store.unknownKey),
                  let found = try? JSONDecoder().decode([UnknownData.Finding].self, from: data) else { return [] }
            return found
        }
    }

    func saveCoverage(_ feed: FerryFeed, now: Date = Date()) {
        if let data = try? JSONEncoder().encode(feed.coverage(from: now)) {
            UserDefaults.standard.set(data, forKey: coverageKey)
        }
    }

    /// Separate file for map shapes: normal timetable reads don't have to decode and discard tens of MB of coordinates;
    /// only read when drawing the map.
    var shapesURL: URL? {
        fileURL.map { $0.deletingPathExtension().appendingPathExtension("shapes.json") }
    }

    /// Stored timetable (without map shapes). Earlier versions kept the shapes in the same file: split it into two files the first time it's read.
    private func readFile() -> FerryFeed? {
        guard let url = fileURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let stored = try? FerryFeed.decode(data) else { return nil }
        guard !stored.shapes.isEmpty else { return stored }
        do {
            try save(stored)
        } catch {
            AppLog.data.error("Splitting the map lines out of \(self.fileName, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
        }
        return stored.withoutShapes()
    }

    /// The full data with map shapes (for drawing the map and filling in a missing operator)
    func readFileWithShapes() -> FerryFeed? {
        guard var feed = readFile() else { return nil }
        if let url = shapesURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let shapes = try? JSONDecoder().decode([String: [[[Double]]]].self, from: data) {
            feed.shapes = shapes
        }
        return feed
    }

    // MARK: Each operator's data on this Mac (Settings' Downloaded data, see DownloadedData)

    /// Each operator's part of the system's file, from the size of its own data in it: worked out again after the file changed
    var shares: (changed: Date?, weights: [String: Int])?
}
