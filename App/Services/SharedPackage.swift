import Foundation
import TransitCore

// MARK: One package for two stores

/// SEPTA's buses (bus store) and its Metro (light rail store) come in one package (26 MB), and the MBTA's buses, subway, trains and
/// ferries (four stores) in another (22 MB): each is downloaded once for all its readers. A download already running for one
/// store is waited for by the others, and what one store downloaded is kept a few hours in the temporary folder for the others:
/// read right away when a store is in use (see FerryStore.handOver), otherwise on its first use. Each reader takes the copy once
/// (a small "taken" file next to it says so), and the copy is removed when every other reader has taken it. A store never reuses
/// its own kept copy or one it took, so its next check still goes online.
enum SharedPackage {
    static let keepFor: TimeInterval = 6 * 3600
    private static let prefix = "cmt-shared-"
    private struct Running {
        let task: Task<Data, Error>
        /// The stores waiting for it and not stopped
        var waiting: Set<UUID>
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [URL: Running] = [:]

    /// An address read by both a bus company and a timetable operator of another store (see RegionalBusFeed.isSharedPackage)
    static func isShared(_ url: URL) -> Bool { RegionalBusFeed.isSharedPackage(url) }

    /// The names the readers of this address go under: its bus companies and its timetable operators
    static func readers(_ url: URL) -> Set<String> {
        Set(RegionalBusFeed.all.filter { $0.url == url }.map(\.name)
            + FerryFeed.Source.allCases.filter { $0.system != .njBus && !$0.isTurnedOff && $0.url == url }.map(\.name))
    }

    /// This store's copy is still kept for the others: not taken by all of them yet, and fresh
    static func isKept(_ url: URL, by provider: String, now: Date = Date()) -> Bool {
        isFresh(file(url, by: provider), now: now)
    }

    /// A fresh copy another store kept that this one hasn't taken yet (see takeKept)
    static func hasKept(_ url: URL, for provider: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !keptFor(url, provider, now: now).isEmpty
    }

    /// The package at this address: another store's kept copy, another store's download already running, or a new download.
    /// provider: the name this store's problems go under (see NetworkReach)
    static func zip(_ url: URL, provider: String, now: Date, download: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let kept = takeKept(url, provider: provider, now: now) { return kept }
        let me = UUID()
        let (task, started) = join(url, me) {
            Task {
                let data = try await download()
                keep(data, for: url, by: provider)
                return data
            }
        }
        defer { leave(url, task, me) }
        do {
            // Stopped (standby, or the caller moved on) and no other store waits for it: the download stops too
            let data = try await withTaskCancellationHandler { try await task.value } onCancel: { leave(url, task, me, stopping: true) }
            // Another store's download: the copy it kept is taken by this store now
            if !started { markTaken(url, by: provider) }
            return data
        } catch {
            if !started { noteFailure(error, url: url, provider: provider) }
            throw error
        }
    }

    /// Kept copies older than keepFor, and "taken" files whose copy is gone
    static func removeOld(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let tmp = FileManager.default.temporaryDirectory
        for name in keptNames() {
            let file = tmp.appendingPathComponent(name)
            if !isFresh(file, now: now) { remove(file) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(takenSuffix) {
            let copy = String(name.dropLast(takenSuffix.count).prefix(while: { $0 != "~" })) + ".zip"
            if !FileManager.default.fileExists(atPath: tmp.appendingPathComponent(copy).path) {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }

    /// Every kept copy and "taken" file (Delete Downloaded Data)
    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private static func join(_ url: URL, _ me: UUID, start: () -> Task<Data, Error>) -> (Task<Data, Error>, started: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if var run = running[url] {
            run.waiting.insert(me)
            running[url] = run
            return (run.task, false)
        }
        let task = start()
        running[url] = Running(task: task, waiting: [me])
        return (task, true)
    }

    /// Done waiting. stopping: this store was stopped; when no store waits any more, the download stops (a store asking after
    /// this starts a new one)
    private static func leave(_ url: URL, _ task: Task<Data, Error>, _ me: UUID, stopping: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard var run = running[url], run.task == task, run.waiting.remove(me) != nil else { return }
        running[url] = run.waiting.isEmpty ? nil : run
        if stopping, run.waiting.isEmpty { task.cancel() }
    }

    /// Another reader's download failed (another store's, or another bus company's of a package several share): say so under this
    /// reader's name too (that one's own download recorded it under its name)
    static func noteFailure(_ error: Error, url: URL, provider: String) {
        switch error as? FeedFetchError {
        case .httpStatus(let status): NetworkReach.record(status: status, url: url, provider: provider, lasting: true)
        case .webPage: NetworkReach.recordBadData(url: url, provider: provider, lasting: true, webPage: true)
        case .tooLarge: NetworkReach.recordBadData(url: url, provider: provider, lasting: true)
        case .noData: break
        case nil: NetworkReach.record(error: error, url: url, provider: provider, lasting: true)
        }
    }

    /// A new copy: no reader has taken it yet
    private static func keep(_ data: Data, for url: URL, by provider: String) {
        lock.lock()
        defer { lock.unlock() }
        let copy = file(url, by: provider)
        remove(copy)
        // Not kept when it can't be written: the other store then downloads its own copy. The log says why
        do {
            try data.write(to: copy, options: .atomic)
        } catch {
            AppLog.data.error("A downloaded copy for \(provider, privacy: .public) couldn't be kept: \(AppLog.reason(error), privacy: .public)")
        }
    }

    /// A fresh copy kept by another store and not taken by this one yet: read (memory-mapped) and marked taken by this store
    private static func takeKept(_ url: URL, provider: String, now: Date) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        for copy in keptFor(url, provider, now: now) {
            guard let data = try? Data(contentsOf: copy, options: .alwaysMapped) else { continue }
            taken(copy, by: provider, url: url)
            return data
        }
        return nil
    }

    /// Every copy another store kept is taken by this store (it used that store's download as it ran)
    private static func markTaken(_ url: URL, by provider: String) {
        lock.lock()
        defer { lock.unlock() }
        let tmp = FileManager.default.temporaryDirectory
        let own = file(url, by: provider).lastPathComponent
        for name in keptNames(url) where name != own {
            taken(tmp.appendingPathComponent(name), by: provider, url: url)
        }
    }

    /// The fresh copies other stores kept at this address that this one hasn't taken (call with the lock held)
    private static func keptFor(_ url: URL, _ provider: String, now: Date) -> [URL] {
        let tmp = FileManager.default.temporaryDirectory
        let own = file(url, by: provider).lastPathComponent
        return keptNames(url).filter { $0 != own }.map { tmp.appendingPathComponent($0) }.filter { copy in
            isFresh(copy, now: now) && !FileManager.default.fileExists(atPath: takenFile(copy, by: provider).path)
        }
    }

    /// Notes that this reader took the copy; once every reader but the one that kept it has, the copy is removed (call with the
    /// lock held). A copy mapped into memory stays readable after its file is removed
    private static func taken(_ copy: URL, by provider: String, url: URL) {
        FileManager.default.createFile(atPath: takenFile(copy, by: provider).path, contents: nil)
        let keeper = readers(url).first { file(url, by: $0) == copy }
        let others = readers(url).filter { $0 != keeper }
        if others.allSatisfy({ FileManager.default.fileExists(atPath: takenFile(copy, by: $0).path) }) { remove(copy) }
    }

    /// A copy and its "taken" files (call with the lock held)
    private static func remove(_ copy: URL) {
        let tmp = FileManager.default.temporaryDirectory
        let start = copy.deletingPathExtension().lastPathComponent + "~"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(start) && name.hasSuffix(takenSuffix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: copy)
    }

    private static let takenSuffix = ".taken"

    /// "cmt-shared-ADDRESS-KEEPER~READER.taken", next to the copy "cmt-shared-ADDRESS-KEEPER.zip"
    private static func takenFile(_ copy: URL, by provider: String) -> URL {
        copy.deletingLastPathComponent().appendingPathComponent(copy.deletingPathExtension().lastPathComponent + "~" + plain(provider) + takenSuffix)
    }

    private static func isFresh(_ file: URL, now: Date) -> Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(date) < keepFor && date <= now.addingTimeInterval(60)
    }

    /// The kept copies' file names (of this address only, with url)
    private static func keptNames(_ url: URL? = nil) -> [String] {
        let start = url.map { prefix + plain($0.absoluteString) + "-" } ?? prefix
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(start) && $0.hasSuffix(".zip") }
    }

    private static func file(_ url: URL, by provider: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(prefix + plain(url.absoluteString) + "-" + plain(provider) + ".zip")
    }

    /// Letters and digits only, for a file name
    private static func plain(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
