import Foundation
import TransitCore

// MARK: - Downloaded data by metro area

/// What's downloaded on this Mac, by metro area (Settings' Downloaded data). Each operator's data belongs to the metro areas it has
/// stops in (areas.json); New York's MTA data (the subway's and MTA buses' maps and station lists, the trip planner's subway timetable
/// and the tram's hours, which the app also ships a copy of) is New York's. Which areas' data stays is AreaData's rule; this applies
/// it to the files
enum DownloadedData {
    /// One operator's data, or New York's MTA data
    enum Part: Hashable, Sendable {
        case source(FerryFeed.Source)
        /// A bus company, by its code (NJ Transit's is empty)
        case bus(String)
        case mta

        var areas: [MetroArea] {
            switch self {
            case .source(let source): return MetroArea.areas(of: source)
            case .bus(let code): return RegionalBusFeed.feed(code: code).map(MetroArea.areas(ofBus:)) ?? [.newYork]
            case .mta: return [.newYork]
            }
        }
    }

    /// Why each area's data stays now, or that the user removed it (areas with neither are left out)
    static func reasons(now: Date = Date()) -> [MetroArea: AreaData.Reason] {
        let start = PlacesInUse.areas(.start).first
        let planner = PlacesInUse.areas(.planner), favorites = PlacesInUse.areas(.favorites)
        let removed = AreaData.removed(), dates = AreaUsage.dates()
        var out: [MetroArea: AreaData.Reason] = [:]
        for area in MetroArea.allCases {
            out[area] = AreaData.reason(for: area, start: start, planner: planner, favorites: favorites, removed: removed,
                                        lastUsed: dates[area], now: now)
        }
        return out
    }

    /// The areas whose data stays now
    static func keeping(now: Date = Date()) -> Set<MetroArea> { Set(reasons(now: now).filter(\.value.keepsData).keys) }

    /// Whether a part's data stays now: one of its areas' does
    static func keeps(_ part: Part, now: Date = Date()) -> Bool { AreaData.keeps(operatorIn: part.areas, keeping: keeping(now: now)) }

    // MARK: Files

    static var supportFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("CatchMyTrain", isDirectory: true)
    }

    /// New York's MTA data downloaded each month (the app ships a copy of all but the trip planner's timetable)
    static var mtaFiles: [URL] {
        var out: [URL] = []
        if let support = supportFolder { out += ["subway_map.json", "bus_map.json", "timetable.bin"].map { support.appendingPathComponent($0) } }
        if let dir = StaticData.directory {
            out += [StaticData.stationsFile, StaticData.expressFile, StaticData.busStopsFile, RooseveltIslandTram.hoursFile].map { dir.appendingPathComponent($0) }
        }
        return out
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// The parts with data on this Mac, found without reading the data: the files there, and the operators last downloaded into
    /// a system's file
    static func storedParts() -> Set<Part> {
        let fm = FileManager.default
        var out: Set<Part> = []
        if let support = supportFolder {
            let systems: [(file: String, key: String, system: TransitSystem)] = [
                ("train.json", FerryStore.trainLastCheckedKey, .train), ("path.json", FerryStore.pathLastCheckedKey, .path),
                ("lightrail.json", FerryStore.lightRailLastCheckedKey, .lightRail), ("ferry.json", FerryStore.ferryLastCheckedKey, .ferry)]
            for item in systems where fm.fileExists(atPath: support.appendingPathComponent(item.file).path) {
                // Saved since each operator's own date was kept; before that, every operator of the system counts
                let dates = UserDefaults.standard.dictionary(forKey: item.key + ".operators")
                for source in FerryFeed.Source.allCases where source.system == item.system && (dates == nil || dates?[source.rawValue] != nil) {
                    out.insert(.source(source))
                }
            }
            for feed in RegionalBusFeed.all where fm.fileExists(atPath: support.appendingPathComponent(feed.fileName).path) {
                out.insert(.bus(feed.code))
            }
        }
        if mtaFiles.contains(where: { fm.fileExists(atPath: $0.path) }) { out.insert(.mta) }
        return out
    }

    /// What each part with data on this Mac takes, in bytes
    static func sizes() async -> [Part: Int64] {
        var out: [Part: Int64] = [:]
        for store in [FerryStore.train, FerryStore.path, FerryStore.lightRail, FerryStore.shared] {
            for (key, size) in await store.sizes() {
                if let source = FerryFeed.Source(rawValue: key) { out[.source(source)] = size }
            }
        }
        for (code, size) in await FerryStore.njBus.sizes() { out[.bus(code)] = size }
        let mta = mtaFiles.compactMap(fileSize).reduce(0, +)
        if mta > 0 { out[.mta] = mta }
        return out
    }

    /// Removes these parts' data: how many were removed, and how many had a file that couldn't be written or deleted
    static func remove(_ parts: Set<Part>) async -> (removed: Int, failed: Int) {
        var failed = 0
        let sources = parts.compactMap { part -> FerryFeed.Source? in if case .source(let s) = part { return s } else { return nil } }
        for (system, group) in Dictionary(grouping: sources, by: \.system) {
            if !(await FerryStore.store(for: system).remove(Set(group.map(\.rawValue)))) { failed += group.count }
        }
        let codes = parts.compactMap { part -> String? in if case .bus(let code) = part { return code } else { return nil } }
        if !codes.isEmpty, !(await FerryStore.njBus.remove(Set(codes))) { failed += codes.count }
        if parts.contains(.mta), !(await removeMTA()) { failed += 1 }
        return (parts.count - failed, failed)
    }

    /// New York's MTA data: the app goes back to the copy it ships, and downloads it again once New York is kept again
    private static func removeMTA() async -> Bool {
        var ok = true
        for url in mtaFiles where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ok = false
                AppLog.data.error("Removing \(url.lastPathComponent, privacy: .public) failed: \(AppLog.reason(error), privacy: .public)")
            }
        }
        for key in ["subwayMap.lastChecked", "busMap.lastChecked"] {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".content")
        }
        await TimetableStore.shared.release()
        await MainActor.run { NotificationCenter.default.post(name: .staticDataDidChange, object: nil) }
        return ok
    }

    // MARK: When areas' data goes

    /// The first launch of this version: an area with data on this Mac but no date of last use gets today's (AreaData.startingDates),
    /// so nothing is removed for 30 days after the update. Called at launch, before anything is removed or saved
    static func startDatesOnce(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AreaData.datesStartedKey) else { return }
        // An area's own operators; one in several areas stays while one of them does anyway
        let withData = Set(storedParts().flatMap { $0.areas.count == 1 ? $0.areas : [] })
        let dates = AreaData.startingDates(AreaUsage.dates(in: defaults), withData: withData, now: now)
        if let dates { AreaUsage.save(dates, in: defaults) }
        defaults.set(true, forKey: AreaData.datesStartedKey)
        AppLog.data.notice("Areas with data: \(withData.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public); dates started: \(dates == nil ? "no" : "yes", privacy: .public)")
    }

    /// The settings key of the last clean-up (see cleanUpIfDue)
    static let cleanedKey = "areas.lastCleanUp"

    /// Removes the data no area keeps any more (an area not used for 30 days, or one the user removed), once a day. Only once the
    /// starting point is known: before that, its own area would look unused
    static func cleanUpIfDue(now: Date = Date()) {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: cleanedKey) as? Date, last <= now, now.timeIntervalSince(last) < 86_400 { return }
        defaults.set(now, forKey: cleanedKey)
        Task.detached(priority: .utility) { await cleanUp(now: now) }
    }

    static func cleanUp(now: Date = Date()) async {
        let reasons = Self.reasons(now: now)
        let keeping = Set(reasons.filter(\.value.keepsData).keys)
        let stored = storedParts()
        // Counts only: which areas keep their data, and why (the starting point, a favorite there…), would say where the user is
        AppLog.data.notice("Areas keeping data: \(keeping.count, privacy: .public) of \(MetroArea.allCases.count, privacy: .public); parts with data: \(stored.count, privacy: .public)")
        let gone = stored.filter { !AreaData.keeps(operatorIn: $0.areas, keeping: keeping) }
        guard !gone.isEmpty else { return }
        let result = await remove(gone)
        AppLog.data.notice("Removed the data of areas not kept: \(result.removed, privacy: .public) parts, \(result.failed, privacy: .public) couldn't be removed")
    }

    /// Settings' Remove…: the user removes an area's data (not the starting point's or Plan a Trip's area). Its favorites stay but
    /// don't download it again until a place there is chosen. False when a file couldn't be written or deleted
    static func removeArea(_ area: MetroArea, now: Date = Date()) async -> Bool {
        // Marked only with favorites there: without, nothing would download it again anyway, and a favorite added there later counts
        if PlacesInUse.areas(.favorites).contains(area) {
            var removed = AreaData.removed()
            removed.insert(area)
            AreaData.saveRemoved(removed)
            PlacesInUse.setRemoved(removed)
        }
        // Not the area itself, also while it counts as recently used
        let keeping = Self.keeping(now: now).subtracting([area])
        let gone = storedParts().filter { $0.areas.contains(area) && !AreaData.keeps(operatorIn: $0.areas, keeping: keeping) }
        let result = await remove(gone)
        AppLog.data.notice("Removed an area's data: \(area.rawValue, privacy: .public), \(result.removed, privacy: .public) parts, \(result.failed, privacy: .public) couldn't be removed")
        return result.failed == 0
    }

    /// A place in these areas was chosen (the starting point, or a Plan a Trip place): an area the user removed isn't any more
    static func noteChosen(_ areas: Set<MetroArea>) {
        let removed = AreaData.removed()
        let rest = AreaData.removedMarks(removed, start: nil, planner: areas)
        guard rest != removed else { return }
        AreaData.saveRemoved(rest)
        PlacesInUse.setRemoved(rest)
    }
}
