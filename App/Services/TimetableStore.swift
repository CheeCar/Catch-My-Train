import Foundation
import TransitCore

/// Manages the MTA scheduled timetable file (used by the trip planner).
///
/// The first time the trip planner is used, downloads gtfs_subway.zip from MTA (about 6 MB, free, no key needed),
/// and compresses it into a small ~4 MB file in this app's own folder. After that it reads that file directly.
/// Like other non-realtime data, checks for updates as of the 1st of each month: during the monthly subway map check
/// it regenerates from the same downloaded gtfs_subway.zip (no second download, see ingest); if missing or expired, downloads on first use of the trip planner.
/// Also re-downloads when the timetable doesn't cover the requested date (MTA publishes a new one every few months or so),
/// but not again within 12 hours of building one. If a download fails, keeps using the old one and doesn't retry for 10 minutes,
/// with or without an old one (see TimetableRefresh).
actor TimetableStore {
    static let shared = TimetableStore()

    /// MTA's subway data (the source list can move it, see SourceList)
    static var sourceURL: URL { SubwayMap.sourceURL }

    private var cached: Timetable?
    private var lastFailure: Date?

    private var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("CatchMyTrain", isDirectory: true).appendingPathComponent("timetable.bin")
    }

    /// Gets a timetable covering this date. Downloads when needed; if the download fails but the old file still works, uses the old one.
    /// allowNetwork = false (standby), or network turned off in Settings: only use what's already on this Mac, don't download.
    func timetable(for date: Date, now: Date = Date(), allowNetwork: Bool = true) async throws -> Timetable {
        if cached == nil, let url = fileURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            cached = try? Timetable(data: data)
        }
        guard allowNetwork, NetworkSwitch.isAllowed else {
            if let t = cached, t.covers(date) { return t }
            throw URLError(.notConnectedToInternet)
        }
        switch TimetableRefresh.decide(covers: cached.map { $0.covers(date) }, builtAt: cached?.builtAt,
                                       lastFailure: lastFailure, now: now) {
        case .useCached:
            if let t = cached { return t }
        case .wait:
            throw URLError(.notConnectedToInternet)
        case .download:
            break
        }
        do {
            // Standby that came after the caller checked: don't start (a cancellation, not a failure, see DownloadGate)
            try DownloadGate.shared.check()
            let fresh = try await download(now: now)
            cached = fresh
            lastFailure = nil
            return fresh
        } catch {
            // A cancelled download (the planner asked again) isn't a failure and mustn't hold off the next one
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled { lastFailure = now }
            if let t = cached, t.covers(date) { return t }
            throw error
        }
    }

    /// Frees memory when the trip planner isn't in use.
    func release() {
        cached = nil
    }

    private func download(now: Date) async throws -> Timetable {
        // No Accept header (see SubwayMapStore.download)
        let request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let (zip, response) = try await URLSession.noCache.reachData(for: request, provider: "MTA", lasting: true)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        return try NetworkReach.reading(Self.sourceURL, provider: "MTA", lasting: true) { try build(zip: zip, now: now) }
    }

    /// The gtfs_subway.zip downloaded during the monthly subway map check, reused to build the timetable (same file, no second download).
    /// Skips if already built this month. On failure just records it; doesn't affect the map.
    func ingest(zip: Data, now: Date = Date()) {
        if let t = cached ?? fileURL.flatMap({ try? Data(contentsOf: $0, options: .mappedIfSafe) }).flatMap({ try? Timetable(data: $0) }),
           !SubwayMapSchedule.isDue(lastChecked: t.builtAt, now: now) { return }
        do {
            let fresh = try build(zip: zip, now: now)
            if cached != nil { cached = fresh }
            lastFailure = nil
        } catch {
            AppLog.data.error("Timetable rebuild from the map download failed: \(AppLog.reason(error), privacy: .public)")
        }
    }

    /// The huge stop_times.txt is read while unzipping, never fully extracted.
    private func build(zip: Data, now: Date) throws -> Timetable {
        let files = try ZipReader.read(zip, names: ["calendar.txt", "calendar_dates.txt", "trips.txt"])
        let data = try TimetableBuilder.build(files: files,
                                              stopTimes: { body in try ZipReader.forEachRow(zip, name: "stop_times.txt", body) },
                                              builtAt: now)
        let timetable = try Timetable(data: data)
        if let url = fileURL {
            // Not being able to save it loses nothing now: the times are in use, and the next launch builds them again. The log says why
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLog.data.error("The timetable built from the download couldn't be saved: \(AppLog.reason(error), privacy: .public)")
            }
        }
        return timetable
    }
}
