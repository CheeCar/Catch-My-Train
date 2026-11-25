import XCTest
@testable import TransitCore

final class ActivityStateTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstLaunchStartsWithThirtyMinutes() {
        let s = ActivityState.firstLaunch(at: now)
        XCTAssertTrue(s.isActive(at: now))
        XCTAssertEqual(s.autoStandbyMinutes, 30)
        XCTAssertEqual(s.activeUntil, now.addingTimeInterval(30 * 60))
        XCTAssertTrue(s.isActive(at: now.addingTimeInterval(29 * 60 + 59)))
        XCTAssertFalse(s.isActive(at: now.addingTimeInterval(30 * 60)), "Goes to standby automatically after 30 minutes")
    }

    /// Behind a new install's setup window nothing runs: on standby, so no location is asked for; finishing it starts as usual
    func testANewInstallStaysOnStandbyUntilSetupIsFinished() {
        let s = ActivityState.newInstall(at: now)
        XCTAssertFalse(s.isActive(at: now))
        XCTAssertFalse(s.isActive(at: now.addingTimeInterval(3600)))
        XCTAssertFalse(LocationNeed.isNeeded(active: s.isActive(at: now), currentLocation: true, demo: false, allowed: true))
        XCTAssertEqual(s.autoStandbyMinutes, ActivityState.defaultAutoStandbyMinutes)
        let later = now.addingTimeInterval(600)
        let started = s.started(at: later)
        XCTAssertTrue(started.isActive(at: later))
        XCTAssertEqual(started.activeUntil, later.addingTimeInterval(30 * 60), "The auto-standby time counts from the start")
    }

    func testStopAndStart() {
        let on = ActivityState.firstLaunch(at: now)
        let off = on.stopped(at: now.addingTimeInterval(60))
        XCTAssertFalse(off.isActive(at: now.addingTimeInterval(61)))
        XCTAssertNil(off.activeUntil)
        // Starting again restarts the timer from that moment
        let later = now.addingTimeInterval(3600)
        let again = off.started(at: later)
        XCTAssertTrue(again.isActive(at: later.addingTimeInterval(10 * 60)))
        XCTAssertEqual(again.activeUntil, later.addingTimeInterval(30 * 60))
    }

    func testNeverAutoStandby() {
        let s = ActivityState(isOn: false, autoStandbyMinutes: nil, changedAt: now).started(at: now)
        XCTAssertNil(s.activeUntil)
        XCTAssertTrue(s.isActive(at: now.addingTimeInterval(24 * 3600)))
    }

    func testChangingDurationWhileActiveRestartsTheClock() {
        let s = ActivityState.firstLaunch(at: now)
        let t = now.addingTimeInterval(20 * 60)
        let hour = s.withAutoStandby(minutes: 60, now: t)
        XCTAssertEqual(hour.activeUntil, t.addingTimeInterval(3600))
        // Changing the duration while on standby doesn't start it
        let off = s.stopped(at: t).withAutoStandby(minutes: 15, now: t)
        XCTAssertFalse(off.isActive(at: t))
        XCTAssertEqual(off.started(at: t).activeUntil, t.addingTimeInterval(15 * 60))
    }

    func testRoundTrip() throws {
        let s = ActivityState.firstLaunch(at: now)
        XCTAssertEqual(try ActivityState.decode(s.encoded()), s)
        XCTAssertTrue(ActivityState.autoStandbyChoices.contains(where: { $0 == nil }))
    }

    /// A reminder still to come puts auto-standby off until it is over, and nothing else changes
    func testAReminderHoldsOffAutoStandby() {
        let s = ActivityState.firstLaunch(at: now)
        let due = now.addingTimeInterval(30 * 60)
        XCTAssertEqual(s.standbyAt, due)
        XCTAssertFalse(s.isHeld(at: due))
        // Held until 12 minutes after the usual time
        let until = due.addingTimeInterval(12 * 60)
        let held = s.holding(until: until)
        XCTAssertEqual(held.activeUntil, due, "The auto-standby time itself stays as it was")
        XCTAssertEqual(held.standbyAt, until)
        XCTAssertTrue(held.isActive(at: due))
        XCTAssertTrue(held.isActive(at: until.addingTimeInterval(-1)))
        XCTAssertFalse(held.isActive(at: until), "Goes to standby once the reminder is over")
        // "Held" is only the time it wouldn't have been on otherwise
        XCTAssertFalse(held.isHeld(at: due.addingTimeInterval(-1)))
        XCTAssertTrue(held.isHeld(at: due))
        XCTAssertTrue(held.isHeld(at: until.addingTimeInterval(-1)))
        XCTAssertFalse(held.isHeld(at: until))
        // A reminder that is over before the usual time changes nothing
        let early = s.holding(until: due.addingTimeInterval(-600))
        XCTAssertEqual(early.standbyAt, due)
        XCTAssertFalse(early.isActive(at: due))
        XCTAssertFalse(early.isHeld(at: due.addingTimeInterval(-300)))
        // The reminders are cancelled: back to the usual time
        XCTAssertEqual(held.holding(until: nil).standbyAt, due)
        XCTAssertEqual(held.holding(until: nil), s)
    }

    func testAHoldNeverUndoesStandbyChosenByHand() {
        let until = now.addingTimeInterval(3600)
        let held = ActivityState.firstLaunch(at: now).holding(until: until)
        // Standby by hand: on standby at once, and the hold is dropped with it
        let stopped = held.stopped(at: now.addingTimeInterval(60))
        XCTAssertFalse(stopped.isActive(at: now.addingTimeInterval(61)))
        XCTAssertNil(stopped.heldUntil)
        XCTAssertNil(stopped.standbyAt)
        XCTAssertFalse(stopped.isHeld(at: now.addingTimeInterval(61)))
        // A hold put on a state that is on standby doesn't start it
        let quiet = ActivityState(isOn: false, changedAt: now).holding(until: until)
        XCTAssertFalse(quiet.isActive(at: now))
        XCTAssertNil(quiet.standbyAt)
        XCTAssertFalse(quiet.isHeld(at: now))
        // "No auto-standby" has no time to put off
        let always = ActivityState(isOn: true, activeUntil: nil, autoStandbyMinutes: nil, changedAt: now).holding(until: until)
        XCTAssertNil(always.standbyAt)
        XCTAssertTrue(always.isActive(at: until.addingTimeInterval(86_400)))
        XCTAssertFalse(always.isHeld(at: until))
        // Start again while held: the usual time counts from now, the hold stays
        let again = held.started(at: now.addingTimeInterval(600))
        XCTAssertEqual(again.activeUntil, now.addingTimeInterval(600 + 30 * 60))
        XCTAssertEqual(again.standbyAt, until)
        // A shorter auto-standby while held: the hold still stands
        let shorter = held.withAutoStandby(minutes: 15, now: now)
        XCTAssertEqual(shorter.activeUntil, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(shorter.standbyAt, until)
    }

    /// The file the app and the widget share reads the same in both directions between versions: nothing is written while
    /// nothing holds, a file from before the hold reads as "no hold", and a version from before it reads a file with one
    func testAHoldInTheSharedFile() throws {
        let s = ActivityState.firstLaunch(at: now)
        let plain = try XCTUnwrap(String(data: s.encoded(), encoding: .utf8))
        XCTAssertFalse(plain.contains("heldUntil"))
        let old = Data(#"{"isOn":true,"activeUntil":1800001800,"autoStandbyMinutes":30,"changedAt":1800000000}"#.utf8)
        let read = try JSONDecoder().decode(ActivityState.self, from: old)
        XCTAssertNil(read.heldUntil)
        XCTAssertTrue(read.isOn)
        XCTAssertEqual(read.standbyAt, read.activeUntil)
        let held = s.holding(until: now.addingTimeInterval(3600))
        let written = try held.encoded()
        XCTAssertTrue(try XCTUnwrap(String(data: written, encoding: .utf8)).contains("heldUntil"))
        XCTAssertEqual(try ActivityState.decode(written), held)
        // What a version from before the hold keeps of it: the four values it knows
        struct Before: Codable { var isOn: Bool; var activeUntil: Date?; var autoStandbyMinutes: Double?; var changedAt: Date }
        let before = try JSONDecoder().decode(Before.self, from: written)
        XCTAssertEqual(before.activeUntil, s.activeUntil)
        XCTAssertTrue(before.isOn)
    }

    /// Standby was chosen in the app but writing the shared file failed: the old "on" still there doesn't start the app again.
    /// A widget's later Start does, and so does the file whenever no write failed
    func testAFailedWriteDoesNotBringBackTheOldState() {
        let on = ActivityState.firstLaunch(at: now)
        let standby = on.stopped(at: now.addingTimeInterval(60))
        XCTAssertTrue(ActivityState.ownCopyCounts(standby, over: on, fileBehind: true))
        XCTAssertFalse(ActivityState.ownCopyCounts(standby, over: on, fileBehind: false))
        // The widget's Start after that standby
        let widgetStart = standby.started(at: now.addingTimeInterval(120))
        XCTAssertFalse(ActivityState.ownCopyCounts(standby, over: widgetStart, fileBehind: true))
        // A changed auto-standby keeps its time of change, and a hold too: the app's copy still counts
        let longer = on.withAutoStandby(minutes: 120, now: now.addingTimeInterval(30))
        XCTAssertEqual(longer.changedAt, on.changedAt)
        XCTAssertTrue(ActivityState.ownCopyCounts(longer, over: on, fileBehind: true))
        XCTAssertTrue(ActivityState.ownCopyCounts(on.holding(until: now.addingTimeInterval(3600)), over: on, fileBehind: true))
        // Nothing of its own, or the same as the file: the file
        XCTAssertFalse(ActivityState.ownCopyCounts(nil, over: on, fileBehind: true))
        XCTAssertFalse(ActivityState.ownCopyCounts(on, over: on, fileBehind: true))
        // The Mac's clock set back: a widget's Start looks older than the app's last change, and counts while no write failed
        let earlierStart = standby.started(at: now.addingTimeInterval(-3600))
        XCTAssertFalse(ActivityState.ownCopyCounts(standby, over: earlierStart, fileBehind: false))
    }

    /// A timed refresh lets one still downloading finish unless it has run far too long; one not running starts when due
    func testRefreshScheduleLetsARunningRefreshFinish() {
        XCTAssertEqual(RefreshSchedule.patience(interval: 30), 90)
        XCTAssertEqual(RefreshSchedule.patience(interval: 60), 120)
        XCTAssertTrue(RefreshSchedule.isDue(now: now, lastStart: nil, interval: 30, running: false))
        XCTAssertFalse(RefreshSchedule.isDue(now: now, lastStart: now.addingTimeInterval(-20), interval: 30, running: false))
        XCTAssertTrue(RefreshSchedule.isDue(now: now, lastStart: now.addingTimeInterval(-30), interval: 30, running: false))
        XCTAssertFalse(RefreshSchedule.isDue(now: now, lastStart: now.addingTimeInterval(-45), interval: 30, running: true),
                       "Still downloading: let it finish")
        XCTAssertFalse(RefreshSchedule.isDue(now: now, lastStart: now.addingTimeInterval(-89), interval: 30, running: true))
        XCTAssertTrue(RefreshSchedule.isDue(now: now, lastStart: now.addingTimeInterval(-90), interval: 30, running: true),
                      "Stuck: start over")
    }

    /// A position is asked for only while on, with "My current location", outside the demo and with "Use my location" on
    func testLocationIsNeededOnlyWhenOnWithCurrentLocation() {
        XCTAssertTrue(LocationNeed.isNeeded(active: true, currentLocation: true, demo: false, allowed: true))
        XCTAssertFalse(LocationNeed.isNeeded(active: false, currentLocation: true, demo: false, allowed: true), "standby uses no location")
        XCTAssertFalse(LocationNeed.isNeeded(active: true, currentLocation: false, demo: false, allowed: true), "a chosen place needs none")
        XCTAssertFalse(LocationNeed.isNeeded(active: true, currentLocation: true, demo: true, allowed: true), "the demo walks from its fixed place")
        XCTAssertFalse(LocationNeed.isNeeded(active: true, currentLocation: true, demo: false, allowed: false), "Use my location is off")
    }

    /// macOS reports the permission at launch too: on standby, with a chosen place or in the demo that doesn't locate
    func testPermissionReportLocatesOnlyWhenWanted() {
        func step(wanted: Bool, locating: Bool = false, denied: Bool = false, hasPosition: Bool = false) -> LocationNeed.PermissionStep {
            LocationNeed.onPermissionGranted(wanted: wanted, locating: locating, denied: denied, hasPosition: hasPosition)
        }
        XCTAssertEqual(step(wanted: false), .report, "the launch report on standby fetches nothing")
        XCTAssertEqual(step(wanted: false, denied: true), .settle, "a denial lifted on standby no longer shows")
        XCTAssertEqual(step(wanted: false, locating: true), .settle)
        XCTAssertEqual(step(wanted: true), .locate, "just got permission while on: fetch once")
        XCTAssertEqual(step(wanted: true, denied: true, hasPosition: true), .locate)
        XCTAssertEqual(step(wanted: true, hasPosition: true), .keep)
    }
}

/// Standby stops the timetable downloads already running and starts no new ones; a download begun by the next Start isn't stopped
/// The automatic launch at login keeps the main window closed; opening the app oneself right after login doesn't
final class LoginLaunchTests: XCTestCase {
    func automatic(marked: Bool = false, event: Bool = false, loginItem: Bool = true, since: TimeInterval? = 5) -> Bool {
        LoginLaunch.isAutomatic(markedAsLoginItem: marked, hasLaunchEvent: event, loginItemEnabled: loginItem, secondsSinceLogin: since)
    }

    func testAMarkedLaunchIsAlwaysAutomatic() {
        XCTAssertTrue(automatic(marked: true, event: true, loginItem: false, since: nil))
        XCTAssertTrue(automatic(marked: true, event: true, since: 600))
    }

    func testOpeningTheAppOneselfIsNeverAutomatic() {
        XCTAssertFalse(automatic(event: true, since: 3), "Opened from the Dock a few seconds after login")
        XCTAssertFalse(automatic(event: true, since: 90))
    }

    func testAnUnmarkedLaunchCountsOnlyRightAfterLogin() {
        XCTAssertTrue(automatic(since: 0))
        XCTAssertTrue(automatic(since: 19.9))
        XCTAssertFalse(automatic(since: 20))
        XCTAssertFalse(automatic(since: 119), "Two minutes used to count")
        XCTAssertFalse(automatic(since: nil))
        XCTAssertFalse(automatic(since: -5))
        XCTAssertFalse(automatic(loginItem: false, since: 5), "\"Open at login\" is off")
    }
}

final class DownloadGateTests: XCTestCase {
    /// A download that runs until it's cancelled (true) or for 30 seconds at most (false)
    private static func download() -> Task<Bool, Never> {
        Task { (try? await Task.sleep(nanoseconds: 30_000_000_000)) == nil }
    }

    func testStandbyRefusesNewDownloadsUntilStart() throws {
        let gate = DownloadGate()
        XCTAssertEqual(try gate.begin(), 0)
        let standby = gate.pause()
        XCTAssertThrowsError(try gate.begin()) { error in
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(NetworkReach.isCancellation(error), "Refused on standby, not failed")
        }
        XCTAssertThrowsError(try gate.check())
        gate.resume()
        XCTAssertEqual(try gate.begin(), standby, "Downloads after Start belong to the period standby began")
        XCTAssertNoThrow(try gate.check())
        XCTAssertEqual(gate.pause(), standby + 1)
    }

    func testCallersInOnePeriodShareOneDownload() async {
        var shared = SharedDownload<Int, Never>()
        var started = 0
        let first = shared.join(period: 0) { _ in started += 1; return Task { 1 } }
        let second = shared.join(period: 0) { _ in started += 1; return Task { 2 } }
        XCTAssertEqual(started, 1)
        XCTAssertEqual(first, second)
        let value = await second.value
        XCTAssertEqual(value, 1)
        shared.finished(first)
        XCTAssertNil(shared.task)
        // The other waiter finishing too changes nothing
        shared.finished(second)
        XCTAssertNil(shared.task)
    }

    func testStandbyStopsTheDownloadAndForgetsIt() async throws {
        let gate = DownloadGate()
        var shared = SharedDownload<Bool, Never>()
        let running = shared.join(period: try gate.begin()) { _ in Self.download() }
        shared.cancel(before: gate.pause())
        XCTAssertNil(shared.task, "The next Start can download again right away")
        XCTAssertEqual(shared.draining, running)
        let stopped = await running.value
        XCTAssertTrue(stopped)
        gate.resume()
        var given: Task<Bool, Never>?
        let next = shared.join(period: try gate.begin()) { stopped in given = stopped; return Self.download() }
        XCTAssertNotEqual(next, running)
        XCTAssertEqual(given, running, "The new download gets the stopped one, to keep what it got")
        // The stopped download's waiter coming back late doesn't drop the new download
        shared.finished(running)
        XCTAssertEqual(shared.task, next)
        XCTAssertNil(shared.draining)
        XCTAssertFalse(next.isCancelled)
        // Nothing stopped is left to hand on
        shared.finished(next)
        var later: Task<Bool, Never>?
        let third = shared.join(period: try gate.begin()) { stopped in later = stopped; return Self.download() }
        XCTAssertNil(later)
        next.cancel()
        third.cancel()
    }

    func testLateStopLeavesTheDownloadAfterStartAlone() async throws {
        let gate = DownloadGate()
        var shared = SharedDownload<Bool, Never>()
        let old = shared.join(period: try gate.begin()) { _ in Self.download() }
        let standby = gate.pause()
        // A quick Start asks for the download again before the stop for the old one arrives: it keeps the old one instead of starting a second
        gate.resume()
        let fresh = shared.join(period: try gate.begin()) { _ in Self.download() }
        XCTAssertEqual(fresh, old)
        XCTAssertFalse(old.isCancelled)
        shared.cancel(before: standby)
        XCTAssertFalse(old.isCancelled, "The late stop leaves it alone")
        XCTAssertEqual(shared.task, old)
        XCTAssertNil(shared.draining)
        // The next standby does stop it
        shared.cancel(before: gate.pause())
        XCTAssertNil(shared.task)
        let stopped = await old.value
        XCTAssertTrue(stopped)
    }
}

/// Menu bar shortcuts: only ⌘ plus one key, not clashing with macOS's own or with other items.
final class ShortcutTests: XCTestCase {
    func testDefaultsAreUniqueAndAllowed() {
        let keys = AppShortcut.allCases.compactMap(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        let empty = ShortcutMap()
        for s in AppShortcut.allCases {
            guard let key = s.defaultKey else { continue }
            XCTAssertTrue(AppShortcut.allowed.contains(key), s.rawValue)
            XCTAssertFalse(AppShortcut.reserved.contains(key), s.rawValue)
            XCTAssertNil(empty.problem(with: key, for: s), s.rawValue)
        }
        // ⌘N and ⌘S are New and Save in most Mac apps: Nearby and Start / Standby have no key by default, and the two keys are free
        XCTAssertEqual(keys.count, 8)
        XCTAssertNil(AppShortcut.nearby.defaultKey)
        XCTAssertNil(AppShortcut.startStandby.defaultKey)
        XCTAssertNil(empty.key(for: .nearby))
        XCTAssertNil(empty.key(for: .startStandby))
        XCTAssertFalse(keys.contains("n") || keys.contains("s"))
        XCTAssertNil(empty.problem(with: "n", for: .map))
        XCTAssertNil(empty.problem(with: "s", for: .refresh))
        // The earlier defaults are the same but for those two
        for s in AppShortcut.allCases where s != .nearby && s != .startStandby {
            XCTAssertEqual(s.earlierDefaultKey, s.defaultKey, s.rawValue)
        }
        XCTAssertEqual(AppShortcut.nearby.earlierDefaultKey, "n")
        XCTAssertEqual(AppShortcut.startStandby.earlierDefaultKey, "s")
    }

    /// An item's key can be removed, and given one again; Restore Defaults puts back the default keys (none where that's the default)
    func testRemoveKey() {
        var map = ShortcutMap()
        map.removeKey(for: .map)
        XCTAssertNil(map.key(for: .map))
        XCTAssertFalse(map.isDefault)
        // Its key is free for another item now
        XCTAssertNil(map.problem(with: "k", for: .refresh))
        XCTAssertEqual(ShortcutMap.decode(map.encoded()), map)
        XCTAssertNil(ShortcutMap.decode(map.encoded()).key(for: .map))
        // Removing a key from an item whose default is none leaves it as it was
        map.removeKey(for: .nearby)
        XCTAssertNil(map.key(for: .nearby))
        XCTAssertEqual(map.custom, ["map": ""])
        // A key given to it, then removed again
        XCTAssertNil(map.set("n", for: .nearby))
        XCTAssertEqual(map.key(for: .nearby), "n")
        XCTAssertEqual(ShortcutMap.decode(map.encoded()).key(for: .nearby), "n")
        map.removeKey(for: .nearby)
        XCTAssertNil(map.key(for: .nearby))
        XCTAssertNil(map.set("k", for: .map))
        XCTAssertTrue(map.isDefault)
        map.removeKey(for: .refresh)
        map.restoreDefaults()
        XCTAssertEqual(map.key(for: .refresh), "r")
        // A removed key saved for an item whose default is none is dropped when read
        let raw = try! JSONEncoder().encode(["nearby": "", "bus": ""])
        XCTAssertEqual(ShortcutMap.decode(raw).custom, ["bus": ""])
        XCTAssertNil(ShortcutMap.decode(raw).key(for: .bus))
    }

    /// Someone who had turned shortcuts on keeps ⌘N and ⌘S on the two items that lost them as defaults, unless they changed
    /// those items or another item uses the key now; everything else stays as it was
    func testKeepEarlierDefaults() throws {
        var untouched = ShortcutMap()
        untouched.keepEarlierDefaults()
        XCTAssertEqual(untouched.key(for: .nearby), "n")
        XCTAssertEqual(untouched.key(for: .startStandby), "s")
        XCTAssertEqual(untouched.key(for: .map), "k")
        XCTAssertEqual(ShortcutMap.decode(untouched.encoded()), untouched)
        // Changed before (saved by an earlier version): stays as it was
        var changed = ShortcutMap.decode(try JSONEncoder().encode(["nearby": "j", "map": "g"]))
        changed.keepEarlierDefaults()
        XCTAssertEqual(changed.key(for: .nearby), "j")
        XCTAssertEqual(changed.key(for: .startStandby), "s")
        XCTAssertEqual(changed.key(for: .map), "g")
        // Another item has "s" now: Start / Standby gets nothing rather than a clash
        var taken = ShortcutMap.decode(try JSONEncoder().encode(["refresh": "s"]))
        taken.keepEarlierDefaults()
        XCTAssertNil(taken.key(for: .startStandby))
        XCTAssertEqual(taken.key(for: .refresh), "s")
        XCTAssertEqual(taken.key(for: .nearby), "n")
        // Done again it changes nothing
        let once = untouched
        untouched.keepEarlierDefaults()
        XCTAssertEqual(untouched, once)
    }

    /// The key a press records: the plain character, or with ⌘ held when the plain one isn't Latin (keyboard layouts for other scripts)
    func testRecordedKeyOnOtherKeyboardLayouts() {
        XCTAssertEqual(AppShortcut.recordedKey(plain: "g", withCommand: "g"), "g")
        XCTAssertEqual(AppShortcut.recordedKey(plain: "G", withCommand: nil), "g")
        // Russian: the key that is N on an English keyboard gives a Cyrillic "te", and "n" with ⌘ held
        XCTAssertEqual(AppShortcut.recordedKey(plain: "\u{0442}", withCommand: "n"), "n")
        // Hebrew: "lamed" on the K key
        XCTAssertEqual(AppShortcut.recordedKey(plain: "\u{05DC}", withCommand: "k"), "k")
        // Neither Latin, an arrow key (private use area), nothing, two characters: nothing to record
        XCTAssertNil(AppShortcut.recordedKey(plain: "\u{0442}", withCommand: "\u{0442}"))
        XCTAssertNil(AppShortcut.recordedKey(plain: "\u{F700}", withCommand: "\u{F700}"))
        XCTAssertNil(AppShortcut.recordedKey(plain: nil, withCommand: nil))
        XCTAssertNil(AppShortcut.recordedKey(plain: "ab", withCommand: ""))
        XCTAssertNil(AppShortcut.recordedKey(plain: " ", withCommand: " "))
        // A symbol is recorded as it is; whether it can be used is checked after
        XCTAssertEqual(AppShortcut.recordedKey(plain: ",", withCommand: ","), ",")
        XCTAssertEqual(ShortcutMap().problem(with: ",", for: .map), .notAllowed)
        XCTAssertEqual(ShortcutMap().problem(with: "q", for: .map), .reserved)
    }

    func testChangeAndConflicts() {
        var map = ShortcutMap()
        XCTAssertEqual(map.set("q", for: .map), .reserved)
        XCTAssertEqual(map.set(" ", for: .map), .notAllowed)
        XCTAssertEqual(map.set("ab", for: .map), .notAllowed)
        XCTAssertEqual(map.set("r", for: .map), .usedBy(.refresh))
        XCTAssertEqual(map.key(for: .map), "k")
        XCTAssertNil(map.set("G", for: .map))
        XCTAssertEqual(map.key(for: .map), "g")
        XCTAssertFalse(map.isDefault)
        // Changing back to the default key no longer counts as "changed"
        XCTAssertNil(map.set("k", for: .map))
        XCTAssertTrue(map.isDefault)
        // Swapping two items: move one away first, then the other can use its old key
        XCTAssertNil(map.set("9", for: .refresh))
        XCTAssertNil(map.set("r", for: .map))
        XCTAssertEqual(map.key(for: .map), "r")
        map.restoreDefaults()
        XCTAssertEqual(map.key(for: .refresh), "r")
    }

    func testSaveAndLoad() {
        var map = ShortcutMap()
        map.set("g", for: .map)
        map.set("0", for: .choosePlace)
        XCTAssertEqual(ShortcutMap.decode(map.encoded()), map)
        // A key an earlier version saved for How It Works, which has no shortcut, is dropped, and "/" is free for other items
        let old = try! JSONEncoder().encode(["howItWorks": "0", "map": "g"])
        XCTAssertEqual(ShortcutMap.decode(old).key(for: .map), "g")
        XCTAssertEqual(ShortcutMap.decode(old).custom, ["map": "g"])
        XCTAssertFalse(AppShortcut.allCases.map(\.rawValue).contains("howItWorks"))
        XCTAssertNil(ShortcutMap().problem(with: "/", for: .refresh))
        XCTAssertEqual(ShortcutMap.decode(nil), ShortcutMap())
        XCTAssertEqual(ShortcutMap.decode(Data("junk".utf8)), ShortcutMap())
        // Bad data: drop unusable keys and duplicate keys
        let bad = try! JSONEncoder().encode(["map": "q", "refresh": "g", "planTrip": "g", "nope": "x"])
        let loaded = ShortcutMap.decode(bad)
        XCTAssertEqual(loaded.key(for: .map), "k")
        XCTAssertEqual(loaded.key(for: .refresh), "r")
        XCTAssertEqual(loaded.key(for: .planTrip), "t")
        XCTAssertEqual(Set([loaded.key(for: .refresh), loaded.key(for: .planTrip)]).count, 2)
    }

    /// Keys that items swapped in Settings come back after relaunch exactly as saved
    func testSwapSurvivesRelaunch() {
        func roundTrip(_ map: ShortcutMap, _ label: String) {
            XCTAssertEqual(ShortcutMap.decode(map.encoded()), map, label)
        }
        // Swap two items through a free key
        var swap = ShortcutMap()
        XCTAssertNil(swap.set("5", for: .subway))
        XCTAssertNil(swap.set("1", for: .bus))
        XCTAssertNil(swap.set("2", for: .subway))
        XCTAssertEqual(ShortcutMap.decode(swap.encoded()).key(for: .subway), "2")
        XCTAssertEqual(ShortcutMap.decode(swap.encoded()).key(for: .bus), "1")
        roundTrip(swap, "subway/bus")
        // An earlier item takes the default key of a later one
        var mapRefresh = ShortcutMap()
        XCTAssertNil(mapRefresh.set("9", for: .refresh))
        XCTAssertNil(mapRefresh.set("r", for: .map))
        roundTrip(mapRefresh, "map/refresh")
        // Three items in a cycle
        var cycle = ShortcutMap()
        for (key, item) in [("9", AppShortcut.subway), ("1", .train), ("3", .bus), ("2", .subway)] {
            XCTAssertNil(cycle.set(key, for: item))
        }
        roundTrip(cycle, "cycle")
        // Every pair of items with default keys swapped
        for a in AppShortcut.allCases {
            for b in AppShortcut.allCases where b != a {
                guard let keyA = a.defaultKey, let keyB = b.defaultKey else { continue }
                var m = ShortcutMap()
                XCTAssertNil(m.set("9", for: a))
                XCTAssertNil(m.set(keyA, for: b))
                XCTAssertNil(m.set(keyB, for: a))
                roundTrip(m, "\(a) and \(b)")
            }
        }
        // An item with no default key takes another's default key, which gets ⌘N
        var noDefault = ShortcutMap()
        XCTAssertNil(noDefault.set("n", for: .map))
        XCTAssertNil(noDefault.set("k", for: .startStandby))
        roundTrip(noDefault, "start/standby and map")
    }

    /// Clashes in stored data (Settings never saves these) go back to defaults the same way every time
    func testClashingStoredKeysGoBackToDefaults() throws {
        func load(_ raw: [String: String]) throws -> ShortcutMap { ShortcutMap.decode(try JSONEncoder().encode(raw)) }
        // Bus was never moved, so Subway can't have its key
        XCTAssertTrue(try load(["subway": "2"]).isDefault)
        // Subway and Train both on 9 go back; then Bus on 1 clashes with Subway's default and goes back too
        XCTAssertTrue(try load(["subway": "9", "train": "9", "bus": "1"]).isDefault)
        XCTAssertEqual(try load(["map": "G"]).key(for: .map), "g")
        XCTAssertTrue(try load(["map": "k"]).isDefault)
    }
}
