import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The most one download may bring: a server sending far more than any real data of its kind (by mistake, or on purpose) is
/// stopped instead of filling memory or the disk. Over it counts as unreadable data, like a web page; the data saved before stays,
/// and the next download is tried as usual
public enum DownloadLimit {
    /// Live data and the small answers of web services (GTFS-Realtime, Bus Time, PATH, NJ Transit, the source list, the update
    /// check): real ones are well under a few MB
    public static let live: Int64 = 20 * 1024 * 1024
    /// Timetable and map packages (zip files)
    public static let package: Int64 = 300 * 1024 * 1024
    /// How often a running download's size is looked at (nanoseconds)
    static let lookEvery: UInt64 = 250_000_000
    /// Most downloads of ferries' and regional buses' timetable packages and live data running at once (see DownloadSlots):
    /// with many operators nearby there were about 30
    public static let atOnce = 6

    /// Whether what the server said it sends (Content-Length; unknown is negative) or what came so far is over the limit
    static func isOver(expected: Int64, received: Int64, limit: Int64) -> Bool {
        expected > limit || received > limit
    }
}

/// Watches one running download and stops it once it's over its limit (see DownloadLimit): the size the server said, as soon as it
/// said it, and what came so far, a few times a second
final class SizeWatch: @unchecked Sendable {
    let limit: Int64
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var looking: Task<Void, Never>?
    private var over = false

    init(limit: Int64) { self.limit = limit }

    /// Before the task is resumed
    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
        let looking = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: DownloadLimit.lookEvery)
                guard !Task.isCancelled, look() else { return }
            }
        }
        lock.lock()
        self.looking = looking
        lock.unlock()
    }

    /// false once there's nothing more to look at
    private func look() -> Bool {
        lock.lock()
        let task = self.task
        lock.unlock()
        guard let task, task.state == .running || task.state == .suspended else { return false }
        guard DownloadLimit.isOver(expected: task.countOfBytesExpectedToReceive, received: task.countOfBytesReceived, limit: limit) else {
            return true
        }
        lock.lock()
        over = true
        lock.unlock()
        task.cancel()
        return false
    }

    /// In the task's completion handler: stops watching. Whether the download was over its limit, also when it ended before the
    /// last look (`received`: the size of what came)
    func finish(received: Int64 = 0) -> Bool {
        lock.lock()
        let looking = self.looking
        let counted = task?.countOfBytesReceived ?? 0
        self.looking = nil
        task = nil
        if max(received, counted) > limit { over = true }
        let result = over
        lock.unlock()
        looking?.cancel()
        return result
    }
}

extension URLSession {
    /// data(for:), with a limit: an answer over `limit` bytes is stopped and throws FeedFetchError.tooLarge (see SizeWatch).
    /// Cancelling the Swift task stops the download instead of letting it finish and throwing the data away
    public func limitedData(for request: URLRequest, limit: Int64) async throws -> (Data, URLResponse) {
        let box = CancellableTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let watch = SizeWatch(limit: limit)
                let task = dataTask(with: request) { data, response, error in
                    if watch.finish(received: Int64(data?.count ?? 0)) {
                        continuation.resume(throwing: FeedFetchError.tooLarge)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: FeedFetchError.noData)
                    }
                }
                watch.start(task)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// download(for:), with a limit, the same way: the file is moved to this app's temporary folder for the caller to move or remove
    public func limitedDownload(for request: URLRequest, limit: Int64) async throws -> (URL, URLResponse) {
        let box = CancellableTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let watch = SizeWatch(limit: limit)
                let task = downloadTask(with: request) { file, response, error in
                    // The system removes its file once this handler returns
                    let size = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init) ?? 0
                    if watch.finish(received: size) {
                        continuation.resume(throwing: FeedFetchError.tooLarge)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if let file, let response {
                        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).tmp")
                        do {
                            try FileManager.default.moveItem(at: file, to: kept)
                            continuation.resume(returning: (kept, response))
                        } catch {
                            continuation.resume(throwing: URLError(.cannotMoveFile))
                        }
                    } else {
                        continuation.resume(throwing: FeedFetchError.noData)
                    }
                }
                watch.start(task)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

#if canImport(Darwin)
extension URLSession {
    /// Download (data kept in memory), recording network problems in NetworkReach. provider: the name shown in the UI (guessed from the host name if not given).
    /// lasting: monthly downloaded data (problems shown until the next successful download). When a web page comes back, or more
    /// than `limit` (see DownloadLimit), records "unreadable" and throws FeedFetchError.webPage or .tooLarge.
    public func reachData(for request: URLRequest, provider: String? = nil, lasting: Bool = false,
                          limit: Int64 = DownloadLimit.package) async throws -> (Data, URLResponse) {
        try NetworkSwitch.check()
        guard let url = request.url else { return try await limitedData(for: request, limit: limit) }
        do {
            let (data, response) = try await limitedData(for: request, limit: limit)
            if let http = response as? HTTPURLResponse {
                NetworkReach.record(status: http.statusCode, url: url, provider: provider, lasting: lasting)
            }
            if NetworkReach.isWebPage(response, accept: request.value(forHTTPHeaderField: "Accept")) {
                NetworkReach.recordBadData(url: url, provider: provider, lasting: lasting, webPage: true)
                throw FeedFetchError.webPage
            }
            return (data, response)
        } catch FeedFetchError.tooLarge {
            NetworkReach.recordBadData(url: url, provider: provider, lasting: lasting)
            throw FeedFetchError.tooLarge
        } catch let error as FeedFetchError {
            throw error
        } catch {
            NetworkReach.record(error: error, url: url, provider: provider, lasting: lasting)
            throw error
        }
    }

    /// Download to a temporary file, recording network problems in NetworkReach, the same way
    public func reachDownload(for request: URLRequest, provider: String? = nil, lasting: Bool = false,
                              limit: Int64 = DownloadLimit.package) async throws -> (URL, URLResponse) {
        try NetworkSwitch.check()
        guard let url = request.url else { return try await limitedDownload(for: request, limit: limit) }
        do {
            let (file, response) = try await limitedDownload(for: request, limit: limit)
            if let http = response as? HTTPURLResponse {
                NetworkReach.record(status: http.statusCode, url: url, provider: provider, lasting: lasting)
            }
            if NetworkReach.isWebPage(response, accept: request.value(forHTTPHeaderField: "Accept")) {
                try? FileManager.default.removeItem(at: file)
                NetworkReach.recordBadData(url: url, provider: provider, lasting: lasting, webPage: true)
                throw FeedFetchError.webPage
            }
            return (file, response)
        } catch FeedFetchError.tooLarge {
            NetworkReach.recordBadData(url: url, provider: provider, lasting: lasting)
            throw FeedFetchError.tooLarge
        } catch let error as FeedFetchError {
            throw error
        } catch {
            NetworkReach.record(error: error, url: url, provider: provider, lasting: lasting)
            throw error
        }
    }
}
#endif

extension URLSession {
    /// Session for the monthly static data downloads: no caching. The app saves downloaded files itself, new replacing old,
    /// so the system download cache doesn't keep another copy and the app's disk usage doesn't keep growing.
    public static let noCache: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
