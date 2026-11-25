import CatchText
import Foundation
import os
import TransitCore

/// Errors go to the system log (visible in the Console app by filtering on com.cheecar.catchmytrain) to help troubleshooting. Locations and keys are never logged.
enum AppLog {
    static let data = Logger(subsystem: "com.cheecar.catchmytrain", category: "Data")
    static let refresh = Logger(subsystem: "com.cheecar.catchmytrain", category: "Refresh")
    static let widget = Logger(subsystem: "com.cheecar.catchmytrain", category: "Widget")
    static let ui = Logger(subsystem: "com.cheecar.catchmytrain", category: "UI")

    /// Error reason written to the log: network errors give only the code and host (the full address can hold a key, e.g. Bus Time's);
    /// this app's own errors and decoding errors (see describesItself) are logged in full to help troubleshooting; any other error
    /// gives only its domain and code, because its text may hold a /Users/<username>/… path or an address.
    static func reason(_ error: Error) -> String {
        if let u = error as? URLError {
            return "URLError \(u.code.rawValue) host=\(u.failingURL?.host ?? "-")"
        }
        if describesItself(error) { return String(describing: error) }
        let e = error as NSError
        if e.domain == NSURLErrorDomain { return "URLError \(e.code)" }
        return "\(e.domain) \(e.code)"
    }

    /// Errors whose full text is safe to log: they name what went wrong (a case, a status code, a file inside a download, a JSON key)
    /// and never a path on this Mac, a full address or a value that was being saved (which EncodingError would show, so it isn't here)
    static func describesItself(_ error: Error) -> Bool {
        error is ZipReader.ZipError || error is TimetableError || error is FeedFetchError || error is BusTimeError
            || error is NJTransitLive.LiveError || error is ProtobufError || error is UpdateCheck.CheckError
            || error is SharedStoreError || error is DecodingError || error is CancellationError || error is SourceList.Rejection
    }
}

/// What the app saves, and what it shares with its widgets.
///
/// Settings, favorites and recent places are in the program's own settings (`defaults`, see SharedDefaults in TransitCore).
/// The files the app and the widget both use (the snapshot, the selected station, start / standby and a few more) are in one
/// plain folder in the user's Library (`sharedFolder`, see SharedFolder in TransitCore, which says why it isn't an App Group).
/// The widget can't read the app's settings: the few it needs are written into that folder for it (exportWidgetSettings).
enum SharedStore {

    static let snapshotFileName = "transit-snapshot.json"
    /// What Settings' Delete Downloaded Data… deletes in the shared folder besides the station lists: the last snapshot, the rate
    /// limits and the widget's status (made again as the app and widget run)
    static var downloadedStateFiles: [String] { [snapshotFileName, rateLimitsFile, widgetHeartbeatFileName] }
    static let settingsKey = "catchSettings"
    static let rangeDefaultsUpgradedKey = "rangeDefaultsUpgradedV2"
    /// One-time upgrade: a search radius still at the earlier 1,200 m default becomes the 4,000 ft default
    static let radiusDefaultUpgradedKey = "radiusDefault4000ftV1"

    /// The name in Info.plist under "AppGroupIdentifier" (`$(TeamIdentifierPrefix)com.cheecar.catchmytrain.shared`; Xcode puts the
    /// development team's ID in at build time, nothing in a build without a team). No App Group is used: it only names the signal
    /// between the app and the widget (SharedSignal), and both read it the same way.
    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    }

    // MARK: The shared folder

    /// This program is the widget (an app extension), not the app
    static let isWidget = Bundle.main.bundleURL.pathExtension == "appex"

    static let staticDataFolderName = "StaticData"

    private static let folderLock = NSLock()
    nonisolated(unsafe) private static var usableFolder: URL?
    nonisolated(unsafe) private static var folderCheckedAt: Date?

    /// The folder the app and the widget share (SharedFolder), or nil while it can't be used. That is found out by writing a small
    /// file there and reading it back, once per process when it works: this is read about twenty times a minute. While it doesn't
    /// work, it's tried again after a minute at the earliest.
    static var sharedFolder: URL? {
        folderLock.lock()
        defer { folderLock.unlock() }
        if let usableFolder { return usableFolder }
        let now = Date()
        if let folderCheckedAt, now.timeIntervalSince(folderCheckedAt) < 60 { return nil }
        folderCheckedAt = now
        let folder = SharedFolder.url(inHome: SharedFolder.realHome)
        if SharedDefaults.isTestRun {
            // The tests' host makes and changes nothing there: it uses the folder only when this Mac's own app has made it
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            usableFolder = folder
            return folder
        }
        do {
            try SharedFolder.check(folder)
        } catch {
            AppLog.data.error("The folder shared with the widget can't be used: \(AppLog.reason(error), privacy: .public)")
            return nil
        }
        if !isWidget { prepare(folder) }
        usableFolder = folder
        return folder
    }

    /// Whether the app and the widget can share data (shown on the Settings page and on the widget to help troubleshooting).
    static var isSharedFolderUsable: Bool { sharedFolder != nil }

    /// The app, the first time the folder works in this launch (called while `sharedFolder` is being found, so it's handed the
    /// folder): the settings the widget needs go in first, so the widget never finds a snapshot without them.
    private static func prepare(_ folder: URL) {
        exportWidgetSettings(to: folder)
    }

    /// Station lists regenerated after the monthly check (subway station catalog, express data, bus stop catalog) live in the shared folder's StaticData folder,
    /// and the main app and widgets read the same copy (see StaticData in TransitCore). Call this before the main app or widgets read station lists.
    static func useStaticDataFolder() {
        StaticData.directory = sharedFolder?.appendingPathComponent(staticDataFolderName, isDirectory: true)
        setUpRateLimitsOnce()
    }

    // MARK: Rate-limit records

    /// Which data providers are rate-limiting and until when we pause, stored in the shared folder: remembered across app restarts, and the same for widgets and the app
    private static let rateLimitsFile = "rate-limits.json"

    static func setUpRateLimitsOnce() { _ = rateLimitsSetUp }

    /// Runs once per process: a static let is initialized lazily and thread-safely (widgets of several sizes can get here at the same time).
    /// Without the shared folder the pauses are kept in memory only, until the process ends.
    private static let rateLimitsSetUp: Void = {
        guard let dir = sharedFolder else { return }
        let url = dir.appendingPathComponent(rateLimitsFile)
        let saved = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: RateLimit.Entry].self, from: $0) } ?? [:]
        RateLimit.restore(saved) { entries in
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(entries) {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    AppLog.data.error("Saving rate limits failed: \(AppLog.reason(error), privacy: .public)")
                }
            }
        }
    }()

    /// This program's own settings: the app's hold the favorites, recent places and every setting; the widget's only what the app
    /// hands it (adoptAppSettings). The same one the "Allow network" check before downloads reads (see SharedDefaults).
    static var defaults: UserDefaults {
        #if DEBUG
        if let testDefaults { return testDefaults }
        #endif
        return SharedDefaults.current
    }

    #if DEBUG
    /// App tests put a temporary store here, so they never read or change the saved data of the app they run in
    nonisolated(unsafe) static var testDefaults: UserDefaults?
    #endif

    /// The saved favorites and recent places (see PlaceLists)
    static var lists: PlaceLists { PlaceLists(defaults: defaults) }

    // MARK: Transit snapshot

    /// How many snapshot writes in a row have failed (reset on one success). Counted apart from writeFailures: the small files
    /// written every few seconds can still succeed (and reset that count) while the much larger snapshot keeps failing,
    /// e.g. on a nearly full disk. The Widget connection row in Settings warns based on both
    nonisolated(unsafe) private(set) static var snapshotWriteFailures = 0

    static func saveSnapshot(_ snapshot: TransitSnapshot) throws {
        guard let dir = sharedFolder else { throw SharedStoreError.sharedFolderUnavailable }
        do {
            try writeRemakingFolder(snapshot.encoded(), to: dir.appendingPathComponent(snapshotFileName))
            snapshotWriteFailures = 0
        } catch {
            snapshotWriteFailures += 1
            throw error
        }
    }

    /// When the snapshot file was last written (reads only file info, not contents).
    static func snapshotModifiedAt() -> Date? {
        guard let dir = sharedFolder else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(snapshotFileName).path)
        return attributes?[.modificationDate] as? Date
    }

    static func loadSnapshot() -> TransitSnapshot? {
        guard let dir = sharedFolder,
              let data = try? Data(contentsOf: dir.appendingPathComponent(snapshotFileName)) else { return nil }
        guard let snapshot = try? TransitSnapshot.decode(data) else { return nil }
        // Widgets may not have downloaded data themselves: use the clock offset the main app worked out (see ClockSkew.adopt)
        if let skew = snapshot.clockSkew { ClockSkew.adopt(skew) }
        return snapshot
    }

    // MARK: Writing files

    /// How many writes in a row have failed (reset on one success). The Widget connection row in Settings warns based on it
    nonisolated(unsafe) private(set) static var writeFailures = 0

    /// Writes into the shared folder. On failure, logs one line to the system log (error code only, no path). Returns whether
    /// it was written
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try writeRemakingFolder(data, to: url)
            writeFailures = 0
            return true
        } catch {
            writeFailures += 1
            let e = error as NSError
            AppLog.data.error("Saving \(url.lastPathComponent, privacy: .public) failed: \(e.domain, privacy: .public) \(e.code, privacy: .public)")
            return false
        }
    }

    /// Writes a file in the shared folder. Everything in that folder can be made again, so when the write fails because the
    /// folder is gone (a cleanup tool removed it while the app ran), the folder is made again, with the settings the widget needs
    /// first (see prepare), and the write tried once more.
    private static func writeRemakingFolder(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let folder = url.deletingLastPathComponent()
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw error }
            try SharedFolder.make(folder)
            if !isWidget, url.lastPathComponent != WidgetHandoff.fileName { exportWidgetSettings(to: folder) }
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: Start / Standby

    static let activityFileName = "activity.json"
    /// The app's own copy of the state below, in its settings
    static let activityCopyKey = "activityState"
    /// Set while that copy holds a change the shared file didn't get (writing it failed, or the folder couldn't be used)
    static let activityFileBehindKey = "activityFileBehind"

    /// Whether this program keeps that copy: the app; not the widget (it would go stale there), nor the tests' host outside a test
    private static var keepsActivityCopy: Bool {
        #if DEBUG
        if SharedDefaults.isTestRun, testDefaults == nil { return false }
        #endif
        return !isWidget
    }

    /// The "Start / Standby" state. Stored as a small file in the shared folder, read and written by both the main app and widgets.
    /// Returns nil if it has never been saved (first launch).
    /// The app also keeps a copy in its own settings and falls back to it: with the file gone or the folder unusable, the app
    /// must not take itself for a new install (the setup window would open at every launch).
    /// When the file never got the app's last change, an older state still in it doesn't count over that copy (see
    /// ActivityState.ownCopyCounts): the copy counts, and the file is written again.
    static func loadActivity() -> ActivityState? {
        let copyData = keepsActivityCopy ? defaults.data(forKey: activityCopyKey) : nil
        let copy = copyData.flatMap { try? ActivityState.decode($0) }
        if let dir = sharedFolder, let data = try? Data(contentsOf: dir.appendingPathComponent(activityFileName)),
           let state = try? ActivityState.decode(data) {
            if keepsActivityCopy {
                if ActivityState.ownCopyCounts(copy, over: state, fileBehind: defaults.bool(forKey: activityFileBehindKey)),
                   let copy {
                    saveActivity(copy)
                    return copy
                }
                if copyData != data { defaults.set(data, forKey: activityCopyKey) }
                if defaults.bool(forKey: activityFileBehindKey) { defaults.removeObject(forKey: activityFileBehindKey) }
            }
            return state
        }
        return copy
    }

    static func saveActivity(_ state: ActivityState) {
        guard let data = try? state.encoded() else { return }
        if keepsActivityCopy { defaults.set(data, forKey: activityCopyKey) }
        let written = sharedFolder.map { write(data, to: $0.appendingPathComponent(activityFileName)) } ?? false
        guard keepsActivityCopy else { return }
        if written {
            defaults.removeObject(forKey: activityFileBehindKey)
        } else {
            defaults.set(true, forKey: activityFileBehindKey)
        }
    }

    // MARK: Selected station and direction

    static let selectionFileName = "selection.json"

    /// Shared by the main window, menu bar and widgets: which station is selected.
    static func loadSelection() -> BoardSelection {
        guard let dir = sharedFolder,
              let data = try? Data(contentsOf: dir.appendingPathComponent(selectionFileName)),
              let s = try? JSONDecoder().decode(BoardSelection.self, from: data) else { return BoardSelection() }
        return s
    }

    /// Whether a selected station has been saved (false when the shared folder is unavailable; then don't overwrite the UI selection with the file value).
    static var hasSavedSelection: Bool {
        guard let dir = sharedFolder else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(selectionFileName).path)
    }

    static func saveSelection(_ selection: BoardSelection) {
        guard let dir = sharedFolder, let data = try? JSONEncoder().encode(selection) else { return }
        write(data, to: dir.appendingPathComponent(selectionFileName))
    }

    // MARK: Widget run record

    static let widgetHeartbeatFileName = "widget-status.json"

    static func loadWidgetHeartbeat() -> WidgetHeartbeat? {
        guard let dir = sharedFolder,
              let data = try? Data(contentsOf: dir.appendingPathComponent(widgetHeartbeatFileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetHeartbeat.self, from: data)
    }

    static func saveWidgetHeartbeat(_ heartbeat: WidgetHeartbeat) {
        guard let dir = sharedFolder, let data = try? JSONEncoder().encode(heartbeat) else { return }
        write(data, to: dir.appendingPathComponent(widgetHeartbeatFileName))
    }

    /// Version number of the current program (main app or widget).
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    // MARK: Data source

    static let dataSourceKey = WidgetHandoff.Key.dataSource
    static let placeKey = "userPlace"

    static var dataSource: TransitDataSource {
        get { TransitDataSource(rawValue: defaults.string(forKey: dataSourceKey) ?? "") ?? .mtaRealtime }
        set {
            defaults.set(newValue.rawValue, forKey: dataSourceKey)
            exportWidgetSettings()
        }
    }

    // MARK: The settings the widget needs

    /// The app: writes the few settings the widget needs (WidgetHandoff: "Allow network", the refresh interval, the data source,
    /// language, units and clock) into the shared folder, when they aren't what the file there says. Called when one of them is
    /// saved, when the app opens and at its timed checks. Never by the widget, nor by the tests' host.
    static func exportWidgetSettings() {
        guard !isWidget, let dir = sharedFolder else { return }
        exportWidgetSettings(to: dir)
    }

    static func exportWidgetSettings(to dir: URL) {
        guard !SharedDefaults.isTestRun else { return }
        let settings = WidgetHandoff(in: SharedDefaults.current)
        guard WidgetHandoff.read(in: dir) != settings, let data = try? JSONEncoder().encode(settings) else { return }
        write(data, to: dir.appendingPathComponent(WidgetHandoff.fileName))
    }

    /// The widget, before it draws or downloads: takes the settings the app wrote for it into its own settings, where the rest of
    /// its code reads them. With no readable file the widget stays offline (see WidgetHandoff.adopt).
    static func adoptAppSettings() {
        guard isWidget else { return }
        WidgetHandoff.adopt(sharedFolder.flatMap { WidgetHandoff.read(in: $0) }, into: SharedDefaults.current)
    }

    // MARK: Sync between the main app and widgets
    // Stored as small files in the shared folder like the toggle state: both programs always read the latest value.

    static let appAliveFileName = "app-alive.json"
    static let refreshRequestFileName = "refresh-request.json"

    /// When the main app last reported "I'm running" (written every 15 seconds when started, every 40 seconds on standby, cleared on quit).
    static var appAliveAt: Date? {
        get { readTime(appAliveFileName) }
        set { writeTime(newValue, appAliveFileName) }
    }

    /// Whether the main app is running (including menu-bar-only).
    /// While running, the main app downloads, computes and notifies widgets, and widgets only show the data it saved, so both sides match;
    /// widgets download on their own only when the main app isn't running.
    static func isAppRunning(now: Date = Date()) -> Bool {
        guard let t = appAliveAt else { return false }
        return now.timeIntervalSince(t) < 100
    }

    /// "Refresh" tapped on a widget while the main app is running: record the time and notify the main app, which refreshes right away.
    static var refreshRequestedAt: Date? {
        get { readTime(refreshRequestFileName) }
        set { writeTime(newValue, refreshRequestFileName) }
    }

    private static func readTime(_ name: String) -> Date? {
        guard let dir = sharedFolder,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let seconds = try? JSONDecoder().decode(Double.self, from: data) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Deletes the file when nil.
    private static func writeTime(_ date: Date?, _ name: String) {
        guard let dir = sharedFolder else { return }
        let url = dir.appendingPathComponent(name)
        if let date, let data = try? JSONEncoder().encode(date.timeIntervalSince1970) {
            write(data, to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension SharedStore {
    /// One-time upgrade: if the saved ranges are still the old defaults (8 / 12 minutes, 800 m), switch to the new defaults (15 / 20 minutes, 4,000 ft).
    /// Ranges the user changed are left alone.
    static func upgradeRangeDefaultsIfNeeded() {
        if !defaults.bool(forKey: rangeDefaultsUpgradedKey) {
            if let data = defaults.data(forKey: settingsKey),
               let saved = try? JSONDecoder().decode(CatchSettings.self, from: data) {
                catchSettings = saved.upgradingLegacyRangeDefaults()
            }
            // Marked done only after the change: quitting in between runs it again next launch (it only changes old defaults)
            defaults.set(true, forKey: rangeDefaultsUpgradedKey)
        }
        // Radius still at the old default of 1200 m: switch to the new default of 4,000 ft (user changes are left alone)
        if !defaults.bool(forKey: radiusDefaultUpgradedKey) {
            if let data = defaults.data(forKey: settingsKey),
               let saved = try? JSONDecoder().decode(CatchSettings.self, from: data) {
                catchSettings = saved.upgradingPreviousRadiusDefault()
            }
            // Marked done only after the change: quitting in between runs it again next launch (it only changes old defaults)
            defaults.set(true, forKey: radiusDefaultUpgradedKey)
        }
    }
}
