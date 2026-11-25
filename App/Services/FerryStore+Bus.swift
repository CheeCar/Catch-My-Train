import Foundation
import TransitCore

extension FerryStore {
    // MARK: Timetable-only bus operators (NJ Transit and several on Long Island, the Hudson Valley and in Connecticut)

    func busFileURL(_ feed: RegionalBusFeed) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CatchMyTrain", isDirectory: true)
            .appendingPathComponent(feed.fileName)
    }

    /// Stored operators (unreadable ones, e.g. damaged or in a newer format, count as missing and are redownloaded at the next check;
    /// older formats still read, see NJBusIndex.formatVersion)
    func loadBusIndexes() -> [String: NJBusIndex]? {
        if let busIndexes { return busIndexes }
        var result: [String: NJBusIndex] = [:]
        for feed in RegionalBusFeed.all {
            if let index = readBusIndex(feed) { result[feed.code] = index }
        }
        busIndexes = result
        busServiceDays = result.mapValues(\.allServiceDays)
        return result.isEmpty ? nil : result
    }

    /// Read one operator's data: the file is memory-mapped (not copied in whole), and the largest block, trip times, uses the mapped memory directly
    private func readBusIndex(_ feed: RegionalBusFeed) -> NJBusIndex? {
        guard let url = busFileURL(feed), let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let index = try? NJBusIndex(data: data, feed: feed) else { return nil }
        busBounds[feed.code] = index.bounds
        return index
    }

    /// The operators needed nearby: when each one's bounds are known, read only those in reach; when not yet known (first time), read all
    private func nearbyBusIndexes(near center: Coordinate, radius: Double) -> [NJBusIndex]? {
        if busIndexes == nil, !busBounds.isEmpty {
            let reach = RegionalBusFeed.all.filter { busBounds[$0.code]?.reaches(center, radiusMeters: radius) ?? true }
            return reach.compactMap { readBusIndex($0) }
        }
        guard let indexes = loadBusIndexes() else { return nil }
        return RegionalBusFeed.all.compactMap { indexes[$0.code] }
    }

    /// Empty chunk when no operator is nearby (not nil: nil means no data downloaded yet)
    private static let noBusSlice = FerryFeed.empty

    /// Each operator's service days (when not yet known, read the full data once and release it afterward)
    func busDays() -> [String: Set<Int>]? {
        if let busServiceDays { return busServiceDays.isEmpty ? nil : busServiceDays }
        let had = busIndexes != nil
        _ = loadBusIndexes()
        if !had { busIndexes = nil }
        return busServiceDays?.isEmpty == false ? busServiceDays : nil
    }

    /// For trip planning: a chunk near another place, without replacing the chunk the main screen is using
    /// (otherwise trip planning and the main screen would take turns rereading the full data on every refresh).
    /// Release that chunk when trip planning closes
    func releaseDetached() { detached = nil }

    func detachedSlice(near center: Coordinate, radius: Double) -> FerryFeed? {
        let key = String(format: "%.4f,%.4f,%.0f,%d", center.latitude, center.longitude, radius, generation)
        if let detached, detached.key == key { return detached.feed }
        let result = makeDetachedSlice(near: center, radius: radius)
        detached = (key, result)
        return result
    }

    private func makeDetachedSlice(near center: Coordinate, radius: Double) -> FerryFeed? {
        let had = busIndexes != nil
        defer { if !had { busIndexes = nil } }
        let r = radius + 1000
        guard let indexes = nearbyBusIndexes(near: center, radius: r) else { return nil }
        return FerryFeed.combining(indexes.map { $0.slice(near: center, radiusMeters: r) }) ?? Self.noBusSlice
    }

    /// Operators wanted now (see RegionalBusFeed.isWanted) not downloaded yet (e.g. ones added in an app update). Ones that failed
    /// only count once it's time to retry (see MonthlyCheck)
    func missingBusCodes(now: Date) -> Set<String> {
        let have = busDays() ?? [:]
        return Set(RegionalBusFeed.all.filter(\.isWanted).map(\.code).filter { have[$0] == nil && monthlyCheck.canRetry($0, now: now) })
    }

    private nonisolated var busReadWithKey: String { lastCheckedKey + ".readWith" }

    /// Each bus company's mark from its last good download: which way of reading its package built its stored copy
    /// (see RegionalBusFeed.readingVersion). None for copies stored before marks were kept
    private nonisolated var busReadWith: [String: Int] {
        UserDefaults.standard.dictionary(forKey: busReadWithKey) as? [String: Int] ?? [:]
    }

    /// Bus companies wanted now whose stored copy an older version read differently. Ones that failed only count once it's time
    /// to retry (see MonthlyCheck)
    func outdatedBusCodes(now: Date) -> Set<String> {
        let stored = Set((busDays() ?? [:]).keys)
        let wanted = Set(RegionalBusFeed.all.filter(\.isWanted).map(\.code))
        return RegionalBusFeed.outdated(stored: stored.intersection(wanted), readWith: busReadWith)
            .filter { monthlyCheck.canRetry($0, now: now) }
    }

    /// Operators downloaded only for places in their area (see DownloadArea), wanted now, last downloaded before this month while this
    /// month's check is done: none of their places was in use when it ran, so it went without them. Checked now rather than next
    /// month; a failed one once its wait is over
    func behindKeys(now: Date) -> Set<String> {
        guard !SubwayMapSchedule.isDue(lastChecked: lastChecked, now: now) else { return [] }
        let local = isIndexed ? RegionalBusFeed.all.filter { $0.downloadArea != nil && $0.isWanted }.map(\.code)
            : wantedSources.filter { $0.downloadArea != nil }.map(\.rawValue)
        guard !local.isEmpty else { return [] }
        let start = SubwayMapSchedule.startOfMonth(now)
        let dates = operatorDates
        return Set(local.filter { key in dates[key].map { $0 < start } ?? false }).filter { monthlyCheck.canRetry($0, now: now) }
    }

    /// Operators wanted now with no trips in the next few days (timetable ran out), or whose timetable ends within the next week
    func endingBusCodes(now: Date) -> Set<String> {
        let wanted = Set(RegionalBusFeed.all.filter(\.isWanted).map(\.code))
        return Set((busDays() ?? [:]).filter { wanted.contains($0.key) && NJBusIndex.runsOut($0.value, from: now) }.keys)
    }

    /// Nearby chunk: reuse it while still inside the last chunk, otherwise cut a new one centered here (1 km extra so walking a bit doesn't need a new cut).
    /// One chunk per operator, merged together.
    /// Release the full data afterward (keep only needed data in memory), and read the file again when leaving this chunk.
    func busSlice(near: Coordinate?, radius: Double) -> FerryFeed? {
        // No location given (update checks etc.): use the current chunk, don't recut
        if near == nil, let feed, sliceCenter != nil { return feed }
        if let feed, let c = sliceCenter, let center = near ?? sliceCenter,
           WalkEstimator.distanceMeters(c, center) + radius <= sliceRadius {
            return feed
        }
        if near == nil, sliceCenter == nil, let emptySlice { return emptySlice }
        let had = busIndexes != nil
        defer { if !had { busIndexes = nil } }
        guard let center = near ?? sliceCenter else {
            guard let indexes = loadBusIndexes() else { return nil }
            let ordered = RegionalBusFeed.all.compactMap { indexes[$0.code] }
            emptySlice = FerryFeed.combining(ordered.map { $0.slice(near: Coordinate(latitude: 0, longitude: 0), radiusMeters: 0) })
            return emptySlice
        }
        let r = radius + 1000
        guard let ordered = nearbyBusIndexes(near: center, radius: r) else { return nil }
        let slice = FerryFeed.combining(ordered.map { $0.slice(near: center, radiusMeters: r) }) ?? Self.noBusSlice
        feed = slice
        sliceCenter = center
        sliceRadius = r
        return slice
    }

    /// Download the operators' feeds (NJ Transit about 50 MB, the others a few MB each), and store each one processed into an NJBusIndex.
    /// If one fails, the others still switch to new data, and only the failed one is retried, after a wait that grows with each failure (see MonthlyCheck).
    /// Standby stops it after the operator in progress (see cancelDownloads): the operators already done are kept, then it throws CancellationError, which isn't a failure.
    /// The month counts as checked once every operator has been refreshed, also across runs that standby stopped.
    @discardableResult
    func updateBus(now: Date, only: Set<String>? = nil) async throws -> SubwayMapStore.CheckResult {
        try NetworkSwitch.check()
        let asked = Date()
        let due = lastChecked
        let period = try DownloadGate.shared.begin()
        let task = busRunning.join(period: period) { stopped in
            Task {
                // Standby stopped a download that may still be processing an operator: wait for it (one at a time),
                // and keep the operators it got instead of downloading them again
                let kept = (await stopped?.value ?? [:]).filter { (try? $0.value.get()) != nil }
                let rest = (only ?? Set(RegionalBusFeed.all.filter(\.isWanted).map(\.code))).subtracting(kept.keys)
                return kept.merging(await Self.downloadBuses(now: now, only: rest, done: { await self.built([$0], since: asked) },
                                                                    got: { await self.noteBuilt([$0]) })) { $1 }
            }
        }
        defer { busRunning.finished(task) }
        let results = await task.value
        var stopped = task.isCancelled
        // Read only the old data of the operators downloaded this time for comparison, not the whole dataset
        var days = busDays() ?? [:]
        var changed = false
        var firstError: Error?
        // The operators this check got new data for, and the ones that failed
        var refreshed: Set<String> = []
        var failed: Set<String> = []
        // The ones whose new data wasn't taken
        var held: Set<String> = []
        for feed in RegionalBusFeed.all {
            switch results[feed.code] {
            case .success(let data)?:
                // Its areas' data was removed while it downloaded (Settings' Remove…): it stays removed
                if !DownloadedData.keeps(.bus(feed.code)) { continue }
                do {
                    let index = try NJBusIndex(data: data, feed: feed)
                    // Compare old files byte by byte first (memory-mapped, not read in whole or parsed); only a changed one is
                    // read, for its stops and lines alone
                    let old = busFileURL(feed).flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
                    let same = old.map { NJBusIndex.sameContent($0, data) } ?? false
                    // New data that looks far from the old isn't taken (DataUpdateGate): the old stays, its days and bounds with it,
                    // and the operator is downloaded again the next day, not counted as read or as a failed download. Old data that
                    // can't be read has nothing to hold the new against
                    if !same, !DataUpdateGate.check(key: DataChangeLog.key(bus: feed.code),
                                                     old: old.flatMap { try? DataListing(busFile: $0) },
                                                     new: DataListing(index), limits: .timetables, now: now) {
                        held.insert(feed.code)
                        continue
                    }
                    if !same, let url = busFileURL(feed) {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                    }
                    if !same { changed = true }
                    days[feed.code] = index.allServiceDays
                    busBounds[feed.code] = index.bounds
                    refreshed.insert(feed.code)
                } catch {
                    Self.logFailed(feed.code, error)
                    firstError = firstError ?? error
                    failed.insert(feed.code)
                }
            case .failure(let error)?:
                if NetworkReach.isCancellation(error) {
                    // Stopped by standby: not a failure
                    stopped = true
                } else {
                    firstError = firstError ?? error
                    failed.insert(feed.code)
                }
            case nil:
                break
            }
        }
        // Turning the network off in Settings partway isn't a failed download
        let networkOn = NetworkSwitch.isAllowed
        if networkOn { monthlyCheck.failed(failed, now: now) }
        if !held.isEmpty { monthlyCheck.held(held, now: now) }
        // Operators downloaded earlier this month count only while this month's check is due (see updateSources)
        let dates = SubwayMapSchedule.isDue(lastChecked: due, now: now) ? operatorDates : [:]
        if monthlyCheck.refreshed(refreshed, of: operatorKeys, lastChecked: due, now: now, downloaded: dates) {
            UserDefaults.standard.set(now, forKey: lastCheckedKey)
        }
        noteDownloaded(refreshed, now: now)
        noteBuilt(Array(refreshed))
        // What was read just now was read this version's way (see RegionalBusFeed.readingVersion)
        let marks = RegionalBusFeed.marking(busReadWith, read: refreshed)
        if marks != busReadWith {
            UserDefaults.standard.set(marks, forKey: busReadWithKey)
            let names = marks.keys.sorted().map { $0.isEmpty ? RegionalBusFeed.njTransit.name : $0 }.joined(separator: ", ")
            AppLog.data.notice("\(self.system.rawValue, privacy: .public) data built again with this version's reading: \(names, privacy: .public)")
        }
        if !stopped {
            if days.isEmpty, let firstError {
                if networkOn { lastFailure = now }
                throw firstError
            }
            lastFailure = firstError == nil || !networkOn ? nil : now
        }
        busServiceDays = days
        if changed {
            // New data: recut the nearby chunk from it (only now is the full data loaded, released once cut)
            busIndexes = nil
            feed = nil
            emptySlice = nil
            detached = nil
            generation += 1
            if let center = sliceCenter { _ = busSlice(near: center, radius: max(0, sliceRadius - 1000)) }
        }
        // Now that this store is done reading, so the two don't read a large package at the same time
        handOver(RegionalBusFeed.all.filter { refreshed.contains($0.code) }.map { (url: $0.url, provider: $0.name) })
        // Stopped by standby: the operators done so far stay, and the rest are checked on the next Start
        if stopped { throw CancellationError() }
        return changed ? .updated : .unchanged
    }

    /// Download the operators one at a time (downloading together would hold several large files in memory at once), recording each result separately.
    /// A package several companies share (Coach USA's six, one after another in downloadOrder) is downloaded once: the next of
    /// them read the same package, or have the same failure without asking again. Each company's notices stay its own: what the
    /// download ran into, or that it went fine, is noted under each one's name, as if each had downloaded it (as SharedPackage
    /// does for the stores sharing a package).
    /// done: whether another check of this store already got a company since this check was asked (left out: see builtAt); got: a
    /// company was downloaded and read, noted before the next check waiting its turn goes on
    private static func downloadBuses(now: Date, only: Set<String>?, done: @escaping @Sendable (String) async -> Bool,
                                      got: @escaping @Sendable (String) async -> Void) async -> [String: Result<Data, Error>] {
        var results: [String: Result<Data, Error>] = [:]
        // The package just downloaded and its address, while the next company's is the same
        var package: (url: URL, zip: Result<Data, Error>)?
        for feed in RegionalBusFeed.downloadOrder(RegionalBusFeed.all) where only?.contains(feed.code) ?? true {
            if Task.isCancelled { break }
            // One large package at a time, also with the other stores (see OneAtATime)
            await OneAtATime.largePackages.enter()
            if await done(feed.code) {
                await OneAtATime.largePackages.leave()
                AppLog.data.notice("bus: \(feed.name, privacy: .public) read while waiting, not read again")
                continue
            }
            do {
                let zip: Data
                if let shared = package, shared.url == feed.url {
                    AppLog.data.notice("bus: \(feed.name, privacy: .public) from the package just downloaded, not downloaded again")
                    switch shared.zip {
                    case .success(let data):
                        NetworkReach.record(status: 200, url: feed.url, provider: feed.name, lasting: true)
                        zip = data
                    case .failure(let error):
                        SharedPackage.noteFailure(error, url: feed.url, provider: feed.name)
                        throw error
                    }
                } else {
                    package = nil
                    do {
                        zip = try await downloadBusZip(feed)
                        package = (feed.url, .success(zip))
                    } catch {
                        // Stopped by standby: the next company still asks for itself
                        if !NetworkReach.isCancellation(error) { package = (feed.url, .failure(error)) }
                        throw error
                    }
                }
                results[feed.code] = .success(try readBus(feed, zip: zip, now: now))
                await got(feed.code)
            } catch {
                logFailed(feed.code, error)
                results[feed.code] = .failure(error)
            }
            await OneAtATime.largePackages.leave()
        }
        return results
    }

    /// A company's package: downloaded, or for one it shares with another store, that store's (see SharedPackage). Mapped into
    /// memory, so it stays readable after its temporary file is removed
    private static func downloadBusZip(_ feed: RegionalBusFeed) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmt-bus-\(feed.code)-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: file) }
        let zip: Data
        let started = Date()
        if SharedPackage.isShared(feed.url) {
            // One package with a timetable operator's data (SEPTA's buses and Metro): downloaded once for both. Its kept copy is
            // checked against the time now, not the check's start: the operators before it may have taken minutes
            zip = try await SharedPackage.zip(feed.url, provider: feed.name, now: Date()) { try await fetchBusZip(feed, to: file) }
        } else {
            zip = try await fetchBusZip(feed, to: file)
        }
        logLarge("downloaded", provider: feed.name, bytes: zip.count, since: started)
        return zip
    }

    /// A company's timetable from its package (of a package several share, its own part), as stored
    private static func readBus(_ feed: RegionalBusFeed, zip: Data, now: Date) throws -> Data {
        let reading = Date()
        defer { logLarge("read", provider: feed.name, bytes: zip.count, since: reading) }
        // Warn when it can't be parsed (format changed): under its own name, as it's its own part that can't be read
        return try NetworkReach.reading(feed.url, provider: feed.name, lasting: true) {
            // stop_times.txt and shapes.txt are large (NJ Transit's are 77 MB and 125 MB), read while decompressing, never fully extracted
            // agency.txt: the company's time zone, which its days and times count in, and a shared package's companies
            let small = try ZipReader.read(zip, names: ["agency.txt", "routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt"])
            let hasShapes = ZipReader.contains(zip, name: "shapes.txt")
            return try NJBusBuilder.build(files: small,
                                          stopTimes: { body in try ZipReader.forEachRow(zip, name: "stop_times.txt", body) },
                                          shapes: hasShapes ? { body in try ZipReader.forEachRow(zip, name: "shapes.txt", body) } : nil,
                                          now: now, feed: feed)
        }
    }

    /// Download to a temp file then memory-map it (NJ Transit's zip is about 50 MB), without keeping a full copy in memory.
    /// Monthly data: on a problem, keep showing the warning until the next success (lasting), and use previously downloaded data meanwhile
    /// Downloaded in a turn of the shared slots (DownloadSlots): many operators' packages don't all download at once
    private static func fetchBusZip(_ feed: RegionalBusFeed, to file: URL) async throws -> Data {
        let request = URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        let (downloaded, response) = try await DownloadSlots.download {
            try await URLSession.noCache.reachDownload(for: request, provider: feed.name, lasting: true)
        }
        try FileManager.default.moveItem(at: downloaded, to: file)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        return try Data(contentsOf: file, options: .alwaysMapped)
    }
}
