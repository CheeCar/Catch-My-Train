import Foundation

/// The "Start / Standby" switch.
///
/// Start: the main app and widgets download and show nearby departures, refreshing on a timer.
/// Standby: no refreshing, no network, no location; widgets show only a "Start" button.
/// After starting, it can return to standby automatically after a while (30 minutes by default), so forgetting to stop won't refresh forever.
///
/// The main app and widgets share this state through the same file in their shared folder; switching on either side takes effect.
public struct ActivityState: Codable, Hashable, Sendable {
    /// Whether it's on (started).
    public var isOn: Bool
    /// Returns to standby automatically at this time. nil means no auto-standby.
    public var activeUntil: Date?
    /// Minutes after starting before auto-standby. nil means no auto-standby.
    public var autoStandbyMinutes: Double?
    /// When it was last switched.
    public var changedAt: Date
    /// Kept on past activeUntil until this time: a leave-by reminder is still to come, and it follows its train only while the
    /// app refreshes. nil: nothing holds it (and nothing is written to the file, which then reads as it always did).
    /// It only ever puts auto-standby off: standby chosen by hand, and "no auto-standby", are as they were
    public var heldUntil: Date?

    public init(isOn: Bool, activeUntil: Date? = nil,
                autoStandbyMinutes: Double? = ActivityState.defaultAutoStandbyMinutes,
                changedAt: Date, heldUntil: Date? = nil) {
        self.isOn = isOn
        self.activeUntil = activeUntil
        self.autoStandbyMinutes = autoStandbyMinutes
        self.changedAt = changedAt
        self.heldUntil = heldUntil
    }

    /// By default, auto-standby 30 minutes after starting.
    public static let defaultAutoStandbyMinutes: Double? = 30

    /// Auto-standby durations selectable in Settings (minutes); nil is "no auto-standby".
    public static let autoStandbyChoices: [Double?] = [15, 30, 60, 120, nil]

    /// Started, with the default auto-standby: what a widget assumes while the app has saved nothing yet.
    public static func firstLaunch(at now: Date) -> ActivityState {
        ActivityState(isOn: false, changedAt: now).started(at: now)
    }

    /// A new install: on standby until its setup window is finished, so nothing is located, downloaded or refreshed behind that
    /// window. Finishing it starts the app.
    public static func newInstall(at now: Date) -> ActivityState {
        firstLaunch(at: now).stopped(at: now)
    }

    /// Whether it's in the "Start" state at a given time (accounting for auto-standby).
    public func isActive(at date: Date) -> Bool {
        guard isOn else { return false }
        if let standbyAt { return date < standbyAt }
        return true
    }

    /// When it goes on standby by itself: the auto-standby time, or later while a reminder holds it. nil: it doesn't
    public var standbyAt: Date? {
        guard isOn, let activeUntil else { return nil }
        return max(activeUntil, heldUntil ?? activeUntil)
    }

    /// It would be on standby by now, and is on only for a reminder still to come
    public func isHeld(at date: Date) -> Bool {
        guard isOn, let activeUntil else { return false }
        return date >= activeUntil && isActive(at: date)
    }

    /// Reminders were set, moved or cancelled: stay on until `until` (LeaveReminders.holdUntil), or nil for no longer than usual
    public func holding(until: Date?) -> ActivityState {
        var s = self
        s.heldUntil = until
        return s
    }

    /// Tap "Start": recompute the auto-standby time from now.
    public func started(at now: Date) -> ActivityState {
        var s = self
        s.isOn = true
        s.activeUntil = autoStandbyMinutes.map { now.addingTimeInterval(max($0, 1) * 60) }
        s.changedAt = now
        return s
    }

    /// Tap "Standby".
    public func stopped(at now: Date) -> ActivityState {
        var s = self
        s.isOn = false
        s.activeUntil = nil
        s.heldUntil = nil
        s.changedAt = now
        return s
    }

    /// Change the auto-standby duration. If running, recompute from now with the new duration.
    public func withAutoStandby(minutes: Double?, now: Date) -> ActivityState {
        var s = self
        s.autoStandbyMinutes = minutes
        if isActive(at: now) {
            s.activeUntil = minutes.map { now.addingTimeInterval(max($0, 1) * 60) }
        }
        return s
    }

    /// The app read the shared file back. Its own copy counts instead when the file never got the app's last change (writing it
    /// failed: `fileBehind`) and nothing newer was written there since: a Start or Standby on a widget afterwards is newer and
    /// counts. Without a failed write the file always counts, even one that looks older (the Mac's clock was set back). When
    /// the copy counts, the app writes the file again
    public static func ownCopyCounts(_ own: ActivityState?, over file: ActivityState, fileBehind: Bool) -> Bool {
        guard fileBehind, let own, own != file else { return false }
        return own.changedAt >= file.changedAt
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> ActivityState {
        try JSONDecoder().decode(ActivityState.self, from: data)
    }
}

/// When the app asks Location Services for a position: only while on (started), walking from "My current location",
/// outside Demo mode (it walks from Times Square or a place chosen in it) and with "Use my location" on in Settings.
/// Permission changes follow the same rule: macOS reports one right at launch, which must not locate on standby or with a chosen place.
public enum LocationNeed {
    public static func isNeeded(active: Bool, currentLocation: Bool, demo: Bool, allowed: Bool) -> Bool {
        active && currentLocation && !demo && allowed
    }

    /// What a report that location is allowed for the app leads to (see onPermissionGranted)
    public enum PermissionStep: Equatable, Sendable {
        /// Fetch the position once
        case locate
        /// Not wanted now: a lookup or a denial shown before goes back to idle
        case settle
        /// Not wanted now, with nothing shown to undo: only pass the change on
        case report
        /// Wanted, and the position is already known: nothing to do
        case keep
    }

    /// macOS reports the permission right at launch too, so a position is fetched only while one is wanted (isNeeded).
    /// - Parameters:
    ///   - wanted: a position is wanted now (isNeeded)
    ///   - locating, denied: what the app shows now
    ///   - hasPosition: a position is already known
    public static func onPermissionGranted(wanted: Bool, locating: Bool, denied: Bool, hasPosition: Bool) -> PermissionStep {
        guard wanted else { return locating || denied ? .settle : .report }
        return locating || denied || !hasPosition ? .locate : .keep
    }
}

/// Whether a launch is the automatic one at login, which keeps the main window closed.
public enum LoginLaunch {
    /// How long after login a launch that says nothing about itself still counts as the automatic one
    public static let graceSeconds: TimeInterval = 20

    /// - Parameters:
    ///   - markedAsLoginItem: macOS says the app was launched as a login item
    ///   - hasLaunchEvent: the launch came with an event (opened from Finder, the Dock, a widget or a link)
    ///   - loginItemEnabled: "Open at login" is on
    ///   - secondsSinceLogin: how long ago this login started (nil: unknown)
    public static func isAutomatic(markedAsLoginItem: Bool, hasLaunchEvent: Bool, loginItemEnabled: Bool,
                                   secondsSinceLogin: TimeInterval?) -> Bool {
        if markedAsLoginItem { return true }
        // An event without the mark: someone opened the app
        if hasLaunchEvent { return false }
        // No event at all: macOS sometimes leaves the mark out for the automatic launch, which comes right after login
        guard loginItemEnabled, let secondsSinceLogin else { return false }
        return secondsSinceLogin >= 0 && secondsSinceLogin < graceSeconds
    }
}

/// When the timed check (every 15 seconds while started) starts a new refresh.
/// A new refresh stops the one before it, so a refresh still running is given time to finish: otherwise one slow server
/// (each request may take a 15-second timeout, a short wait and a retry) would have every refresh cut off by the next, and nothing would update.
public enum RefreshSchedule {
    /// How long a running refresh may take before the timed check starts over anyway (at least 90 seconds)
    public static func patience(interval: TimeInterval) -> TimeInterval { max(2 * interval, 90) }

    /// - Parameters:
    ///   - lastStart: when the last refresh started (nil: never)
    ///   - interval: the refresh interval
    ///   - running: that refresh is still downloading
    public static func isDue(now: Date, lastStart: Date?, interval: TimeInterval, running: Bool) -> Bool {
        let since = now.timeIntervalSince(lastStart ?? .distantPast)
        guard since >= interval - 1 else { return false }
        return !running || since >= patience(interval: interval)
    }
}

/// Standby uses no network: the timetable and map downloads already running stop, and no new ones start until the next Start.
///
/// Each standby begins a new period. A download remembers the period it started in, and standby stops only the ones from earlier periods,
/// so a download that a quick Start began right after isn't stopped when the stop arrives late (it runs on each store's own actor).
/// Thread-safe: the main app pauses and resumes it on the main thread while the stores ask it from their actors.
public final class DownloadGate: @unchecked Sendable {
    /// The main app's gate (each process has its own; the widget never pauses it)
    public static let shared = DownloadGate()

    private let lock = NSLock()
    private var period = 0
    private var paused = false

    public init() {}

    /// Standby: refuse new downloads. Returns the new period; the downloads that started before it are the ones to stop (see SharedDownload.cancel(before:)).
    @discardableResult
    public func pause() -> Int {
        lock.lock(); defer { lock.unlock() }
        period += 1
        paused = true
        return period
    }

    /// Start: downloads may begin again
    public func resume() {
        lock.lock(); defer { lock.unlock() }
        paused = false
    }

    /// Before a download starts: the period it belongs to. On standby, throws CancellationError, which isn't a failure (see NetworkReach.isCancellation).
    public func begin() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if paused { throw CancellationError() }
        return period
    }

    /// Before a download that nobody shares starts: on standby, throws CancellationError (see begin)
    public func check() throws {
        _ = try begin()
    }
}

/// The download in progress that later callers wait for instead of downloading again, with the period it started in (see DownloadGate).
/// Not thread-safe by itself: kept inside the actor that owns the download.
public struct SharedDownload<Success: Sendable, Failure: Error> {
    /// The download in progress (nil when none)
    public private(set) var task: Task<Success, Failure>?
    /// The download standby stopped, until its caller is done with it. Processing a file can't stop midway,
    /// so the next download is given it to wait for and keep what it got instead of downloading that again (see join)
    public private(set) var draining: Task<Success, Failure>?
    private var period = 0

    public init() {}

    /// The task to wait for: the one in progress, otherwise a new one from start, which is given the download standby stopped (if it's still running).
    /// One from before a standby whose stop hasn't arrived yet (Start came first) is kept too: it moves to this period, so the late stop leaves it alone.
    public mutating func join(period: Int, start: (_ stopped: Task<Success, Failure>?) -> Task<Success, Failure>) -> Task<Success, Failure> {
        self.period = period
        if let task { return task }
        let fresh = start(draining)
        task = fresh
        return fresh
    }

    /// Standby (see DownloadGate.pause): cancel the download if it started before this period, and forget it so the next Start can download again right away
    public mutating func cancel(before period: Int) {
        guard let task, self.period < period else { return }
        task.cancel()
        draining = task
        self.task = nil
    }

    /// A caller is done waiting: forget the task, unless a newer one has taken its place
    public mutating func finished(_ task: Task<Success, Failure>) {
        if self.task == task { self.task = nil }
        if draining == task { draining = nil }
    }
}
