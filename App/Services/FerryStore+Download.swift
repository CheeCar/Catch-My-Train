import Foundation
import TransitCore

extension FerryStore {
    /// One operator's downloaded feed: small files already extracted; the train stop_times.txt is large, stays in the zip and is read while decompressing during processing.
    private struct Download: Sendable {
        var files: [String: Data]
        var zip: Data?
        /// The package's size, or what was taken out of it when the package itself isn't kept
        var bytes: Int { zip?.count ?? files.values.reduce(0) { $0 + $1.count } }
    }

    /// The downloads came back under other names than the operators asked for (see download)
    private struct MixedUp: Error {}

    /// Download these operators at once. Fails only if all fail; the operators missing from the result (see FerryFeed.sources) failed.
    static func download(_ sources: [FerryFeed.Source], now: Date) async throws -> FerryFeed {
        // Each operator's package is kept under its own name (see Together)
        let results = await Together.each(sources) { source -> Result<Download, Error> in
            do {
                return .success(try await fetchZip(source))
            } catch {
                return .failure(error)
            }
        }
        // An answer for every operator asked for and for no other: anything else would build one operator's timetable under
        // another's name, so nothing is built from it
        guard Set(results.keys) == Set(sources) else {
            let asked = sources.map(\.rawValue).sorted().joined(separator: " ")
            let got = results.keys.map(\.rawValue).sorted().joined(separator: " ")
            AppLog.data.error("timetable downloads mixed up: asked \(asked, privacy: .public), got \(got, privacy: .public)")
            throw MixedUp()
        }
        var downloads: [FerryFeed.Source: Download] = [:]
        var firstError: Error?
        for source in sources {
            switch results[source] {
            case .success(let f)?: downloads[source] = f
            case .failure(let error)?:
                logFailed(source.rawValue, error)
                firstError = firstError ?? error
            case nil: break
            }
        }
        if downloads.isEmpty { throw firstError ?? URLError(.cannotLoadFromNetwork) }
        // Stopped by standby before every operator downloaded: don't process a result that won't be saved (see update). A complete download is still processed
        if downloads.count < sources.count { try Task.checkCancellation() }
        var stopTimes: [FerryFeed.Source: FerryBuilder.RowSource] = [:]
        // Read while building: a damaged stop_times.txt is noted as that operator's unreadable data, like the files read above
        for (source, d) in downloads {
            if let zip = d.zip {
                stopTimes[source] = { body in
                    try NetworkReach.reading(source.url, provider: source.name, lasting: true) {
                        try ZipReader.forEachRow(zip, name: "stop_times.txt", body)
                    }
                }
            }
        }
        // The large stop_times.txt are read while building: the whole build gets its own line, small packages' too, with the
        // operators the built timetable holds
        let building = Date()
        let bytes = downloads.values.reduce(0) { $0 + $1.bytes }
        var left: Set<FerryFeed.Source> = []
        do {
            let feed = try FerryBuilder.build(downloads.mapValues(\.files), stopTimes: stopTimes, now: now) { source, error in
                // Left out of the timetable, the others are built as usual: logged, and noted as that operator's unreadable data
                left.insert(source)
                noteUnreadable(source, error)
            }
            let names = sources.filter(feed.sources.contains).map(\.name).joined(separator: ", ")
            logLarge("built", provider: names, bytes: bytes, since: building, always: true)
            return feed
        } catch {
            // Nothing could be built: the packages came, so it's their data, not the network (see isBadData)
            let names = sources.filter { downloads[$0] != nil }.map(\.name).joined(separator: ", ")
            if !NetworkReach.isCancellation(error) {
                AppLog.data.notice("timetable build failed: \(names, privacy: .public) \(AppLog.reason(error), privacy: .public)")
            }
            if isBadData(error) {
                for source in downloads.keys where !left.contains(source) {
                    NetworkReach.recordBadData(url: source.url, provider: source.name, lasting: true)
                }
            }
            throw error
        }
    }

    /// An operator whose package came but can't be built from: one line in the log (see logFailed), and its unreadable data noted so
    /// the stations say it's on the operator's side, not the network
    private static func noteUnreadable(_ source: FerryFeed.Source, _ error: Error) {
        logFailed(source.rawValue, error)
        if isBadData(error) { NetworkReach.recordBadData(url: source.url, provider: source.name, lasting: true) }
    }

    private static func fetchZip(_ source: FerryFeed.Source) async throws -> Download {
        let zip: Data
        let started = Date()
        let shared = SharedPackage.isShared(source.url)
        if shared {
            // One package with a bus company's data (SEPTA's Metro and buses, 26 MB; the MBTA's subway, trains, ferries and buses,
            // 22 MB): downloaded once for all of them
            zip = try await SharedPackage.zip(source.url, provider: source.name, now: Date()) { try await fetchData(source, timeout: 120) }
        } else {
            zip = try await fetchData(source, timeout: 60)
        }
        logLarge("downloaded", provider: source.name, bytes: zip.count, since: started)
        let reading = Date()
        defer { logLarge("read", provider: source.name, bytes: zip.count, since: reading) }
        return try NetworkReach.reading(source.url, provider: source.name, lasting: true) {
            if source.isRail || shared {
                // Metro-North's stop_times.txt is 27 MB uncompressed, the MBTA's (with its buses) 130 MB: don't extract it in full
                return Download(files: try ZipReader.read(zip, names: Array(FerryFeed.neededFiles.subtracting(["stop_times.txt"]))),
                                zip: zip)
            }
            return Download(files: try ZipReader.extract(zip, names: FerryFeed.neededFiles))
        }
    }

    /// Packages at least this big get a log line when downloaded and when read: which operator, how big, how long (never a place)
    static let largePackageBytes = 5_000_000

    /// - Parameter always: a line for small packages too (a finished build: which operators it holds)
    static func logLarge(_ step: String, provider: String, bytes: Int, since start: Date, always: Bool = false) {
        guard always || bytes >= largePackageBytes else { return }
        let mb = String(format: bytes >= 100_000 ? "%.1f" : "%.3f", Double(bytes) / 1_000_000)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        AppLog.data.notice("timetable package \(step, privacy: .public): \(provider, privacy: .public) \(mb, privacy: .public) MB in \(seconds, privacy: .public) s")
    }


    /// Don't add "Accept: application/zip": the NYC Ferry server returns 406 (Not Acceptable) when it sees it.
    /// The default request works for all operators (tested on a Mac). Downloaded in a turn of the shared slots (DownloadSlots)
    private static func fetchData(_ source: FerryFeed.Source, timeout: TimeInterval) async throws -> Data {
        let request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (zip, response) = try await DownloadSlots.download {
            try await URLSession.noCache.reachData(for: request, provider: source.name, lasting: true)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        return zip
    }

    /// Write a temp file first then replace atomically, removing the old file. Map shapes go into a separate file (see shapesURL), written first,
    /// so the shapes are always in place once the timetable file is written.
    func save(_ feed: FerryFeed) throws {
        // No folder to save in: a failure, not a quiet success (the check would count as done)
        guard let url = fileURL, let shapesURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(feed.shapes).write(to: shapesURL, options: .atomic)
        try feed.withoutShapes().encoded().write(to: url, options: .atomic)
        saveNames(feed)
    }

    // MARK: A package another store reads too

    /// After this store downloaded a package another store reads too (see SharedPackage) and kept a copy for it: that store reads
    /// the copy now, while it's there, instead of downloading the package again on its own turn, and both have the same day's data
    func handOver(_ packages: [(url: URL, provider: String)]) {
        for (url, provider) in packages where SharedPackage.isShared(url) && SharedPackage.isKept(url, by: provider) {
            for reader in Self.readers(of: url) where reader !== self {
                Task { await reader.readKept(url) }
            }
        }
    }

    /// The stores reading the package at this address
    private static func readers(of url: URL) -> [FerryStore] {
        var readers: [FerryStore] = []
        if RegionalBusFeed.all.contains(where: { $0.url == url }) { readers.append(njBus) }
        for source in FerryFeed.Source.allCases where !source.isTurnedOff && source.url == url {
            let reader = store(for: source.system)
            if !readers.contains(where: { $0 === reader }) { readers.append(reader) }
        }
        return readers
    }

    /// Read the copy another store just kept for this one (see handOver): its operators wanted now, and only once this store has data
    /// on this Mac (on its first use it takes the copy itself, see SharedPackage) and while the copy is there, so nothing is downloaded
    func readKept(_ url: URL) async {
        if isIndexed {
            let feeds = RegionalBusFeed.all.filter { $0.url == url && $0.isWanted }
            let hasData = RegionalBusFeed.all.contains { busFileURL($0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
            guard let name = feeds.first?.name, hasData, SharedPackage.hasKept(url, for: name) else { return }
            _ = try? await updateBus(now: Date(), only: Set(feeds.map(\.code)))
        } else {
            let wanted = wantedSources.filter { $0.url == url }
            let hasData = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard let name = wanted.first?.name, hasData, SharedPackage.hasKept(url, for: name) else { return }
            // Saved, but kept in memory only if it already was (only the mode in use keeps its data there, see release)
            let inMemory = feed != nil
            _ = try? await updateSources(Set(wanted), now: Date())
            if !inMemory { feed = nil }
        }
    }
}
