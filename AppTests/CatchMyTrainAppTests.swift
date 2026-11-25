import MapKit
import Security
import SwiftUI
import XCTest
@testable import CatchMyTrain

/// App-layer tests: rules of the app itself, which CatchCore's tests can't reach.
/// Run with Xcode on the Mac (xcodebuild test -scheme CatchMyTrain); the app launches once during testing.
final class CatchMyTrainAppTests: XCTestCase {
    private var suite = ""
    // Four real places for the tests that need saved places (the demo's recent stations; any places would do)
    private let places = SharedStore.DemoPlaces().recents

    // Every test reads and writes a temporary store, never the saved data of the app it runs in
    override func setUpWithError() throws {
        suite = "CatchMyTrainAppTests.\(UUID().uuidString)"
        SharedStore.testDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        SharedStore.testDefaults?.removePersistentDomain(forName: suite)
        SharedStore.testDefaults = nil
    }

    // When no place has been chosen yet, switching to "A place I choose" opens the window first instead of switching (cancelling won't use the built-in default place)
    func testChoosingAPlaceOpensPickerOnlyBeforeFirstChoice() {
        XCTAssertTrue(LocationMode.manual.needsPicker(hasChosenPlace: false))
        XCTAssertFalse(LocationMode.manual.needsPicker(hasChosenPlace: true))
        XCTAssertFalse(LocationMode.current.needsPicker(hasChosenPlace: false))
        XCTAssertFalse(LocationMode.current.needsPicker(hasChosenPlace: true))
    }

    // In standby (offline), the trip lookup subway schedule only uses what's already on this Mac; if it doesn't cover that day, report an error instead of downloading
    func testPlannerTimetableDoesNotDownloadOnStandby() async {
        let farFuture = Date(timeIntervalSince1970: 4_102_444_800)   // 2100-01-01
        do {
            _ = try await TimetableStore.shared.timetable(for: farFuture, allowNetwork: false)
            XCTFail("offline, there shouldn't be a schedule covering the year 2100")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // Light-mode warning orange and warning red have at least 4.5:1 contrast on white (WCAG AA for small text)
    func testNoticeColorsAreReadableOnWhite() {
        XCTAssertGreaterThanOrEqual(Color.contrast(Color.noticeOrangeLight, 0xFFFFFF), 4.5)
        XCTAssertGreaterThanOrEqual(Color.contrast(Color.noticeRedLight, 0xFFFFFF), 4.5)
        // Green text must be enough on both white and the "Live" badge's light green (15% green over white)
        XCTAssertGreaterThanOrEqual(Color.contrast(Color.noticeGreenLight, 0xFFFFFF), 4.5)
        XCTAssertGreaterThanOrEqual(Color.contrast(Color.noticeGreenLight, 0xDDE9E0), 4.5)
        XCTAssertLessThan(Color.contrast(0x34C759, 0xFFFFFF), 4.5)
        // For comparison: the system orange text isn't enough on white (which is why it's being replaced)
        XCTAssertLessThan(Color.contrast(0xFF9500, 0xFFFFFF), 4.5)
    }

    // The walking-range circles are graphics (3:1 needed): the light-mode teal is about 5.2:1 on white,
    // which leaves room for the map's land color, a little darker than white (about 4.7:1)
    func testWalkRangeColorStandsOutOnTheMap() {
        XCTAssertGreaterThanOrEqual(Color.contrast(Color.walkRangeLight, 0xFFFFFF), 4.5)
    }

    // Bus operators whose realtime data failed are saved, so it's still known next launch (in the temporary store)
    func testBusRealtimeFailuresAreRemembered() {
        SharedStore.busRealtimeFailed = ["BXL"]
        XCTAssertEqual(SharedStore.busRealtimeFailed, ["BXL"])
        SharedStore.busRealtimeFailed = []
        XCTAssertEqual(SharedStore.busRealtimeFailed, [])
    }

    // File read/write errors in the log record only the error code, not local paths
    func testLogReasonHidesFilePaths() {
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/someone/Library/Group Containers/x/activity.json"])
        let reason = AppLog.reason(error)
        XCTAssertFalse(reason.contains("/Users/"))
        XCTAssertTrue(reason.contains(String(CocoaError.fileWriteNoPermission.rawValue)))
        // Network errors keep their code, to help debugging
        XCTAssertTrue(AppLog.reason(URLError(.timedOut)).contains("-1001"))
    }

    // Network errors in the log keep the code and host but never the full address (it can hold a key)
    func testLogReasonHidesURLQuery() {
        let url = URL(string: "https://bustime.mta.info/api/siri/stop-monitoring.json?key=SECRETKEY123&MonitoringRef=1")!
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        let reason = AppLog.reason(error)
        XCTAssertFalse(reason.contains("SECRETKEY123"))
        XCTAssertTrue(reason.contains("-1001"))
        XCTAssertTrue(reason.contains("bustime.mta.info"))
        let bridged = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        XCTAssertFalse(AppLog.reason(bridged).contains("SECRETKEY123"))
    }

    // Only this app's own errors and decoding errors are logged in full; any other error gives only its domain and code,
    // since its text may name a file on this Mac
    func testLogReasonDescribesOnlyKnownErrors() {
        XCTAssertEqual(AppLog.reason(SharedStoreError.sharedFolderUnavailable), "sharedFolderUnavailable")
        do {
            _ = try JSONDecoder().decode([String: Int].self, from: Data(#"{"count":"x"}"#.utf8))
            XCTFail("a string isn't a number")
        } catch {
            XCTAssertTrue(AppLog.reason(error).contains("typeMismatch"))
        }
        struct FileError: Error, CustomStringConvertible {
            var description: String { "couldn't open /Users/someone/Library/Containers/activity.json" }
        }
        let reason = AppLog.reason(FileError())
        XCTAssertFalse(reason.contains("/Users/"))
        XCTAssertTrue(reason.contains("FileError"), "the domain names the type")
        let other = NSError(domain: "SomeKit", code: 7, userInfo: [NSLocalizedDescriptionKey: "couldn't read /Users/someone/notes.txt"])
        XCTAssertEqual(AppLog.reason(other), "SomeKit 7")
    }

    // Temporary range expansion is tracked separately for each location mode, and can't expand in standby
    func testTemporaryRangeIsPerModeAndOnlyWhenActive() {
        var range = TemporaryRange()
        var changed = range.set(10, for: .current, active: false)
        XCTAssertFalse(changed, "can't expand in standby")
        XCTAssertFalse(range.isExtended)
        changed = range.set(10, for: .current, active: true)
        XCTAssertTrue(changed)
        XCTAssertEqual(range.minutes(for: .current), 10)
        XCTAssertEqual(range.minutes(for: .manual), 0, "the other mode is unaffected")
        changed = range.set(5, for: .manual, active: true)
        XCTAssertTrue(changed)
        XCTAssertEqual(range.minutes(for: .current), 10)
        changed = range.set(5, for: .manual, active: true)
        XCTAssertFalse(changed, "unchanged")
        changed = range.set(0, for: .current, active: false)
        XCTAssertTrue(changed, "can return to normal in standby")
        XCTAssertTrue(range.isExtended)
        changed = range.set(0, for: .manual, active: true)
        XCTAssertTrue(changed)
        XCTAssertFalse(range.isExtended)
    }

    // The tests' store is a temporary one, apart from the app's own
    func testTestsUseATemporaryStore() {
        XCTAssertTrue(SharedStore.defaults === SharedStore.testDefaults)
        SharedStore.favoritePlaces = places
        XCTAssertEqual(SharedStore.favoritePlaces, places)
    }

    // A change to the lists tells open windows to read them again; clearing the recent places also says so
    func testChangingThePlacesIsAnnounced() {
        let changed = expectation(forNotification: SharedStore.placesChanged, object: nil)
        changed.expectedFulfillmentCount = 2
        let cleared = expectation(forNotification: SharedStore.recentPlacesCleared, object: nil)
        SharedStore.remember(places[1])
        SharedStore.clearRecentPlaces()
        wait(for: [changed, cleared], timeout: 1)
        XCTAssertEqual(SharedStore.recentPlaces, [])
    }

    // Clearing the recent places also deletes the copy kept of any that couldn't be read
    func testClearingRecentPlacesDeletesTheKeptCopy() {
        SharedStore.defaults.set(Data(#"[{"name":"Broken"}]"#.utf8), forKey: SharedStore.recentPlacesKey)
        XCTAssertEqual(SharedStore.pendingPlacesRestore()?.count, 0)
        XCTAssertNotNil(SharedStore.defaults.data(forKey: SharedStore.recentPlacesKey + ".unreadable"))
        SharedStore.clearRecentPlaces()
        XCTAssertNil(SharedStore.defaults.data(forKey: SharedStore.recentPlacesKey + ".unreadable"))
        XCTAssertNil(SharedStore.pendingPlacesRestore())
    }

    // A saved place that can't be read counts as none (the app asks for one instead of walking from the built-in default one),
    // and is kept once as it was when another is chosen; one saved by an older version counts
    func testAnUnreadablePlaceCountsAsNone() {
        XCTAssertFalse(SharedStore.hasChosenPlace)
        let broken = Data(#"{"name":"Broken"}"#.utf8)
        SharedStore.defaults.set(broken, forKey: SharedStore.placeKey)
        XCTAssertFalse(SharedStore.hasChosenPlace)
        XCTAssertEqual(SharedStore.place, .default)
        let chosen = places[0]
        SharedStore.place = chosen
        XCTAssertTrue(SharedStore.hasChosenPlace)
        XCTAssertEqual(SharedStore.place, chosen)
        XCTAssertEqual(SharedStore.defaults.data(forKey: SharedStore.placeKey + ".unreadable"), broken)
        let older = Data(#"{"name":"Hoboken Terminal","latitude":40.7359,"longitude":-74.0291}"#.utf8)
        SharedStore.defaults.set(older, forKey: SharedStore.placeKey)
        XCTAssertTrue(SharedStore.hasChosenPlace)
        XCTAssertEqual(SharedStore.place.name, "Hoboken Terminal")
    }

    // Demo mode's places stay in memory: nothing is saved, nothing is asked
    func testDemoPlacesAreNotSaved() {
        SharedStore.favoritePlaces = [places[0]]
        SharedStore.demoPlaces = SharedStore.DemoPlaces()
        defer { SharedStore.demoPlaces = nil }
        SharedStore.clearRecentPlaces()
        SharedStore.toggleFavorite(places[0])
        XCTAssertNil(SharedStore.pendingPlacesRestore())
        SharedStore.demoPlaces = nil
        XCTAssertEqual(SharedStore.favoritePlaces, [places[0]])
    }

    // Demo mode's presets start as the demo's each time it's turned on; changing them there saves nothing
    func testDemoPresetsAreTheDemosAndNotSaved() {
        let saved = SharedStore.commutePresets
        SharedStore.demoPlaces = SharedStore.DemoPlaces()
        defer { SharedStore.demoPlaces = nil }
        let demos = SharedStore.commutePresets
        XCTAssertFalse(demos.isEmpty)
        XCTAssertNotEqual(demos, saved)
        SharedStore.commutePresets = []
        XCTAssertTrue(SharedStore.commutePresets.isEmpty)
        SharedStore.demoPlaces = nil
        XCTAssertEqual(SharedStore.commutePresets, saved)
        SharedStore.demoPlaces = SharedStore.DemoPlaces()
        XCTAssertEqual(SharedStore.commutePresets, demos)
    }

    // Languages with the same layout direction switch directly; a different direction (either way) needs confirmation and a restart
    func testLanguageNeedsRestartOnlyWhenDirectionChanges() {
        // The test uses only language codes (the test target doesn't link CatchText directly)
        XCTAssertEqual(TransitModel.languageCodesNeedingRestart(rightToLeftNow: false).sorted(), ["ar", "he", "ur", "yi"])
        let fromRightToLeft = TransitModel.languageCodesNeedingRestart(rightToLeftNow: true)
        XCTAssertTrue(fromRightToLeft.contains("en"))
        XCTAssertFalse(fromRightToLeft.contains("ar"))
    }

    // A chosen direction with no departures doesn't hide the other's: the other direction shows under it. Not when both are
    // empty, not when the chosen one has departures, and not when both directions are shown already
    func testEmptyChosenDirectionShowsTheOtherUnderIt() {
        XCTAssertTrue(DirectionMode.north.showsOtherDirection(chosenIsEmpty: true, otherIsEmpty: false))
        XCTAssertTrue(DirectionMode.south.showsOtherDirection(chosenIsEmpty: true, otherIsEmpty: false))
        XCTAssertFalse(DirectionMode.north.showsOtherDirection(chosenIsEmpty: true, otherIsEmpty: true))
        XCTAssertFalse(DirectionMode.south.showsOtherDirection(chosenIsEmpty: false, otherIsEmpty: false))
        XCTAssertFalse(DirectionMode.north.showsOtherDirection(chosenIsEmpty: false, otherIsEmpty: true))
        XCTAssertFalse(DirectionMode.both.showsOtherDirection(chosenIsEmpty: true, otherIsEmpty: false))
    }

    // In the bottom data notes, Bee-Line is listed only when this station really has its buses; other broken operators are listed as usual
    func testBeeLineIsListedOnlyAtItsStops() {
        XCTAssertTrue(TransitModel.developerOnlyFeedCodes.contains("BXL"))
        XCTAssertFalse(TransitModel.listsDownFeed(code: "BXL", routes: ["M104"]))
        XCTAssertFalse(TransitModel.listsDownFeed(code: "BXL", routes: nil), "not listed in trip lookup")
        XCTAssertTrue(TransitModel.listsDownFeed(code: "BXL", routes: ["M104", "NJB-BXL/60"]))
        XCTAssertTrue(TransitModel.listsDownFeed(code: "CTT", routes: ["M104"]))
        XCTAssertTrue(TransitModel.listsDownFeed(code: "CTT", routes: nil))
    }

    // A Keychain delete counts only when neither the new nor the older keychain still holds the item: a denied or cancelled prompt
    // leaves it on this Mac, and Settings must say so. Only the status check is tested; nothing here touches the real Keychain.
    func testKeychainDeleteSucceedsOnlyWhenNothingIsLeft() {
        XCTAssertTrue(KeychainStore.deleteSucceeded(modern: errSecSuccess, legacy: errSecItemNotFound))
        XCTAssertTrue(KeychainStore.deleteSucceeded(modern: errSecItemNotFound, legacy: errSecSuccess))
        XCTAssertTrue(KeychainStore.deleteSucceeded(modern: errSecItemNotFound, legacy: errSecItemNotFound))
        XCTAssertTrue(KeychainStore.deleteSucceeded(modern: errSecMissingEntitlement, legacy: errSecSuccess), "a build without the new keychain")
        XCTAssertFalse(KeychainStore.deleteSucceeded(modern: errSecSuccess, legacy: errSecUserCanceled), "the older copy is still there")
        XCTAssertFalse(KeychainStore.deleteSucceeded(modern: errSecSuccess, legacy: errSecAuthFailed))
        XCTAssertFalse(KeychainStore.deleteSucceeded(modern: errSecInteractionNotAllowed, legacy: errSecItemNotFound))
    }

    // Only "no such item" means a key isn't saved (in the data protection keychain, so does a build that can't use it: the older keychain
    // is read then). A denied or cancelled prompt or a locked keychain is a failure, never a missing key. Nothing here touches the real Keychain.
    func testKeychainReadTellsMissingFromUnreadable() {
        let data = Data("abc".utf8)
        XCTAssertEqual(KeychainStore.lookup(status: errSecSuccess, data: data, modern: true), .found("abc"))
        XCTAssertEqual(KeychainStore.lookup(status: errSecSuccess, data: data, modern: false), .found("abc"))
        XCTAssertEqual(KeychainStore.lookup(status: errSecSuccess, data: Data(), modern: true), .notFound, "an empty value counts as none")
        XCTAssertEqual(KeychainStore.lookup(status: errSecItemNotFound, data: nil, modern: true), .notFound)
        XCTAssertEqual(KeychainStore.lookup(status: errSecItemNotFound, data: nil, modern: false), .notFound)
        XCTAssertEqual(KeychainStore.lookup(status: errSecMissingEntitlement, data: nil, modern: true), .notFound)
        XCTAssertEqual(KeychainStore.lookup(status: errSecMissingEntitlement, data: nil, modern: false), .failed(errSecMissingEntitlement))
        XCTAssertEqual(KeychainStore.lookup(status: errSecUserCanceled, data: nil, modern: false), .failed(errSecUserCanceled))
        XCTAssertEqual(KeychainStore.lookup(status: errSecAuthFailed, data: nil, modern: false), .failed(errSecAuthFailed))
        XCTAssertEqual(KeychainStore.lookup(status: errSecInteractionNotAllowed, data: nil, modern: true), .failed(errSecInteractionNotAllowed))
        let denied = KeychainStore.lookup(status: errSecAuthFailed, data: nil, modern: true)
        XCTAssertTrue(denied.isFailure)
        XCTAssertNil(denied.value)
        XCTAssertFalse(KeychainStore.lookup(status: errSecItemNotFound, data: nil, modern: true).isFailure)
    }

    // Plan a Trip never plans from a time already gone, and only departures from now to 30 minutes ahead use live data
    func testPlannerNeverLeavesInThePast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(PlannerModel.effectiveLeave(now.addingTimeInterval(-20 * 60), now: now), now)
        XCTAssertEqual(PlannerModel.effectiveLeave(now.addingTimeInterval(600), now: now), now.addingTimeInterval(600))
        XCTAssertTrue(PlannerModel.usesRealtime(leave: now, now: now))
        XCTAssertTrue(PlannerModel.usesRealtime(leave: now.addingTimeInterval(29 * 60), now: now))
        XCTAssertFalse(PlannerModel.usesRealtime(leave: now.addingTimeInterval(30 * 60), now: now))
        XCTAssertFalse(PlannerModel.usesRealtime(leave: now.addingTimeInterval(-3 * 3600), now: now), "Long gone isn't now")
    }

    // Every "Walk from" switch (sidebar, menu bar, Settings) follows one rule: nothing changes for "My current location" with "Use my
    // location" off, and "A place I choose" before any place was chosen opens the place picker first. Demo mode follows it for its own
    // places in memory (hasChosenPlace is then whether a place was chosen in the demo), except that its current location, Times Square,
    // needs no location
    func testWalkFromSwitchesFollowOneRule() {
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: false, locationAllowed: true, hasChosenPlace: false), .openPicker)
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: false, locationAllowed: true, hasChosenPlace: true), .switchMode)
        XCTAssertEqual(TransitModel.locationModeChange(to: .current, isDemo: false, locationAllowed: true, hasChosenPlace: false), .switchMode)
        XCTAssertEqual(TransitModel.locationModeChange(to: .current, isDemo: false, locationAllowed: false, hasChosenPlace: true), .keep)
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: false, locationAllowed: false, hasChosenPlace: true), .switchMode)
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: true, locationAllowed: true, hasChosenPlace: false), .openPicker)
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: true, locationAllowed: true, hasChosenPlace: true), .switchMode)
        XCTAssertEqual(TransitModel.locationModeChange(to: .manual, isDemo: true, locationAllowed: false, hasChosenPlace: false), .openPicker)
        XCTAssertEqual(TransitModel.locationModeChange(to: .current, isDemo: true, locationAllowed: true, hasChosenPlace: true), .switchMode)
        XCTAssertEqual(TransitModel.locationModeChange(to: .current, isDemo: true, locationAllowed: false, hasChosenPlace: false), .switchMode,
                       "Demo mode's current location is Times Square")
    }

    // An Apple Maps request whose task is cancelled (standby, starting over) ends the wait at once and is told to stop,
    // even when Apple Maps never answers. Nothing here goes online: the request is a stand-in that never answers.
    func testMapsRequestStopsWhenItsTaskIsCancelled() async {
        let stopped = expectation(description: "the request is cancelled")
        let task = Task { await MapsRequest.answer(stop: { stopped.fulfill() }) { (_: MapsAnswer<Int>) in } }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        await fulfillment(of: [stopped], timeout: 2)
    }

    // A task cancelled before its request starts never sends it; an answer that does come is returned as is
    func testMapsRequestIsNotSentOnceCancelled() async {
        let started = expectation(description: "the request is sent")
        started.isInverted = true
        let task = Task {
            // Ask only once cancelled (sleeping ends right away then)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return await MapsRequest.answer(stop: {}) { (_: MapsAnswer<Int>) in started.fulfill() }
        }
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        await fulfillment(of: [started], timeout: 0.5)
        let answered = await MapsRequest.answer(stop: {}) { (wait: MapsAnswer<Int>) in wait.finish(7) }
        XCTAssertEqual(answered, 7)
    }

    // Plan a Trip names the bus operators whose live times didn't download (Bee-Line's server-side outage only where its buses stop)
    func testPlannerNamesFailedBusOperators() {
        XCTAssertEqual(PlannerModel.failedBusOperators(["CTT"], routes: []), ["CTtransit"])
        XCTAssertEqual(PlannerModel.failedBusOperators(["CTT", ""], routes: []), ["NJ Transit", "CTtransit"])
        XCTAssertEqual(PlannerModel.failedBusOperators(["BXL"], routes: ["M104"]), [])
        XCTAssertEqual(PlannerModel.failedBusOperators(["BXL"], routes: ["NJB-BXL/60"]), ["Bee-Line"])
        XCTAssertEqual(PlannerModel.failedBusOperators([], routes: []), [])
    }

    // With networking turned off in Settings, Plan a Trip's notes about live times or downloads give the main window's sentence
    // with Settings… under it, at Privacy and permissions (checking the network or turning the app on wouldn't help, turning
    // networking on would); with networking on they keep their words
    // and offer Start when they ask to turn the app on, else Refresh. Notes are equal when their English words and their buttons
    // are, so they're made here from the English words alone (the test target doesn't link CatchText directly)
    @MainActor func testPlannerSaysNetworkIsOffInsteadOfNetworkNotes() {
        let off = PlannerModel.Note { _ in "Network is off in Settings, so only timetables saved on this Mac are shown." }.offering(.settings(.privacy))
        let notes: [(words: String, action: PlannerModel.Action)] = [
            ("Turn the app on to get live times.", .start),
            ("Turn the app on to get PATH live times.", .start),
            ("Turn the app on to download the MTA timetable.", .start),
            ("Couldn't get MTA real-time data. Check your network. Showing the last data received.", .refresh),
            ("Couldn't get PATH live data. Check your network.", .refresh),
            ("Couldn't get MTA live data. Check your network.", .refresh),
            ("Couldn't get MTA Bus Time data. Check your network. Showing the last data received.", .refresh),
            ("Bus timetables are downloaded the first time you turn the app on.", .start),
            ("Train timetables are downloaded the first time you turn the app on.", .start),
            ("Ferry timetables are downloaded the first time you turn the app on.", .start),
        ]
        for (words, action) in notes {
            let note = PlannerModel.Note { _ in words }
            XCTAssertNotEqual(note, off)
            XCTAssertEqual(PlannerModel.needingNetwork(note, networkOff: true), off, words)
            XCTAssertEqual(PlannerModel.needingNetwork(note, networkOff: true).action, .settings(.privacy), words)
            XCTAssertEqual(PlannerModel.needingNetwork(note, networkOff: false), note.offering(action), words)
            XCTAssertEqual(PlannerModel.needingNetwork(note, networkOff: false).action, action, words)
        }
    }

    // A station card's kind boxes stay beside the name (which wraps there) unless they'd leave it less than about half the line;
    // a name that fits beside them on one line always keeps them there
    @MainActor func testCardKindBoxesStayBesideTheNameUnlessTooWide() {
        // One short box ("Subway") and a long name: the name wraps beside it
        XCTAssertTrue(NameAndKindsLayout.beside(width: 224, name: 230, boxes: 46, spacing: 6))
        // Three operators' boxes and a name that doesn't fit beside them: the boxes go under the name
        XCTAssertFalse(NameAndKindsLayout.beside(width: 224, name: 100, boxes: 134, spacing: 6))
        // A short name stays on one line beside even wide boxes
        XCTAssertTrue(NameAndKindsLayout.beside(width: 224, name: 70, boxes: 134, spacing: 6))
        // No room at all: under the name
        XCTAssertFalse(NameAndKindsLayout.beside(width: 0, name: 70, boxes: 40, spacing: 6))
    }

    // A station card's lines and walk share a line only when both fit at their full widths; otherwise the badges wrap onto more
    // lines, each at its full width and centered on its line, and are never squeezed over each other
    @MainActor func testCardLinesWrapRatherThanSqueeze() {
        XCTAssertTrue(RoutesAndWalkLayout.oneLine(width: 240, routes: 150, walk: 70, spacing: 12))
        XCTAssertTrue(RoutesAndWalkLayout.oneLine(width: 232, routes: 150, walk: 70, spacing: 12))
        XCTAssertFalse(RoutesAndWalkLayout.oneLine(width: 231, routes: 150, walk: 70, spacing: 12))
        let badges = [CGSize(width: 30, height: 13), CGSize(width: 30, height: 13), CGSize(width: 30, height: 13), CGSize(width: 12, height: 10)]
        let one = FlowLayout.positions(sizes: badges, width: nil, spacing: 2, lineSpacing: 2)
        XCTAssertEqual(one.points.map(\.x), [0, 32, 64, 96])
        XCTAssertEqual(one.points[3].y, 1.5, accuracy: 0.001)
        XCTAssertEqual(one.size, CGSize(width: 108, height: 13))
        let two = FlowLayout.positions(sizes: badges, width: 70, spacing: 2, lineSpacing: 2)
        XCTAssertEqual(two.points, [CGPoint(x: 0, y: 0), CGPoint(x: 32, y: 0), CGPoint(x: 0, y: 15), CGPoint(x: 32, y: 16.5)])
        XCTAssertEqual(two.size, CGSize(width: 62, height: 28))
        // One wider than the line gets a line of its own, at its full width
        let wide = FlowLayout.positions(sizes: [CGSize(width: 90, height: 13), CGSize(width: 30, height: 13)], width: 70, spacing: 2,
                                        lineSpacing: 2)
        XCTAssertEqual(wide.points, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15)])
        XCTAssertEqual(wide.size, CGSize(width: 90, height: 28))
        // A line given a little less than it was measured at (rounded to the screen's pixels) keeps its badges
        let rounded = FlowLayout.positions(sizes: [CGSize(width: 33.3, height: 13), CGSize(width: 33.3, height: 13)], width: 68.4,
                                           spacing: 2, lineSpacing: 2)
        XCTAssertEqual(rounded.points[1].y, 0)
    }

    // Apple's compass and + − stand in the bottom corner in both directions: higher in a right-to-left one, clear of MapKit's Legal
    // link there, and Plan a Trip's labels keep clear of all of it
    /// The map window keeps one map for every transit mode: another mode drops what was known of the one before
    @MainActor func testMapModelShowsAnotherModeOnTheSameModel() {
        let model = SubwayMapModel(kind: .subway)
        model.show(kind: .bus)
        XCTAssertEqual(model.kind, .bus)
        XCTAssertNil(model.map)
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.lastChecked)
        XCTAssertNil(model.upToDate)
        model.show(kind: .ferry)
        XCTAssertEqual(model.kind, .ferry)
    }

    /// An old mode's read that ends after another mode was shown is dropped: what stays is the mode shown now, and it isn't left
    /// checking
    @MainActor func testMapModelDropsALateReadOfTheModeBefore() async {
        func sample<T: Decodable>(_ source: String) -> T? {
            try? JSONDecoder().decode(T.self, from: Data("{\"source\":\"\(source)\",\"stations\":[],\"routes\":[]}".utf8))
        }
        let model = SubwayMapModel(kind: .subway)
        model.readMap = { kind in
            // The old mode's read is slow and isn't stopped with the task, so it comes back after the new mode's
            if kind == .subway { await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value }
            return sample(kind == .subway ? "old" : "new")
        }
        model.open(allowNetwork: false)
        try? await Task.sleep(for: .milliseconds(50))
        model.show(kind: .bus)
        model.open(allowNetwork: false)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.kind, .bus)
        XCTAssertNotNil(model.map)
        XCTAssertEqual(model.map, sample("new"))
        XCTAssertNotEqual(model.status, .checking)
    }

    @MainActor func testMapCornerControlsStandClearOfLegalRightToLeft() {
        XCTAssertGreaterThan(MapCornerControls.bottomSpace(.rightToLeft), MapCornerControls.bottomSpace(.leftToRight))
        XCTAssertEqual(MapCornerControls.room(.rightToLeft).height - MapCornerControls.room(.leftToRight).height,
                       MapCornerControls.bottomSpace(.rightToLeft) - MapCornerControls.bottomSpace(.leftToRight), accuracy: 0.001)
        XCTAssertEqual(MapCornerControls.room(.rightToLeft).width, MapCornerControls.room(.leftToRight).width, accuracy: 0.001)
    }

    // Over a station's dot with no label, the mouse shows the dot's name; elsewhere nothing
    @MainActor func testMapHoverFindsTheDotUnderTheMouse() {
        let dots = [MapDotSpot(id: "127", center: CGPoint(x: 100, y: 100), diameter: 20)]
        XCTAssertEqual(MapHover.at(CGPoint(x: 105, y: 96), labels: [], dots: dots, open: nil), MapHover(dot: "127"))
        XCTAssertEqual(MapHover.at(CGPoint(x: 130, y: 100), labels: [], dots: dots, open: nil), MapHover())
    }

    // The app these tests run in knows it's only their host, so it doesn't locate, download or save anything this Mac's own app uses
    func testTestHostIsRecognized() {
        XCTAssertTrue(TransitModel.isTestHost)
    }

    // An NJ Transit operator's row in Settings says "Timetable" where the account doesn't make its times live, whatever the
    // account's state; where it does, the mark follows the account ("Not checked yet" until a download has shown that it works)
    func testNJTransitRowBadgeFollowsWhetherTheAccountMakesItLive() {
        for has in [false, true] {
            for refused in [false, true] {
                XCTAssertEqual(SourceBadge.njTransit(liveWithAccount: false, has: has, refused: refused, check: nil), .timetable)
            }
        }
        XCTAssertEqual(SourceBadge.njTransit(liveWithAccount: true, has: false, refused: false, check: nil), .timetable)
        XCTAssertEqual(SourceBadge.njTransit(liveWithAccount: true, has: true, refused: true, check: nil), .timetable)
        XCTAssertEqual(SourceBadge.njTransit(liveWithAccount: true, has: true, refused: false, check: nil), .notChecked)
    }

    // A flood of "shared data changed" signals rereads the shared files at most once per interval: the first signal at once,
    // the others together once the interval is over, and a signal after a quiet interval at once again
    func testSignalsAreHandledAtMostOncePerInterval() {
        var runs = 0
        let second = expectation(description: "the merged signals are handled")
        let throttle = SignalThrottle(interval: 0.2) {
            runs += 1
            if runs == 2 { second.fulfill() }
        }
        for _ in 0..<5 { throttle.fire() }
        XCTAssertEqual(runs, 1)
        wait(for: [second], timeout: 2)
        // A quiet interval after that run (a timer never fires early)
        let quiet = expectation(description: "a quiet interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(runs, 2)
        throttle.fire()
        XCTAssertEqual(runs, 3)
    }

    // Sidebar station rows keep their identities while the order stays; a new order, or a station more or less, gives every row a new one,
    // so the table removes and inserts the rows instead of moving them
    func testSidebarRowsAreNewWhenTheOrderChanges() {
        let keys = SidebarStationRow.keys(["1", "2", "3"])
        XCTAssertEqual(keys, SidebarStationRow.keys(["1", "2", "3"]))
        XCTAssertEqual(Set(keys).count, 3)
        for other in [["2", "1", "3"], ["1", "2", "3", "4"], ["1", "3"]] {
            XCTAssertTrue(Set(keys).isDisjoint(with: SidebarStationRow.keys(other)), "\(other)")
        }
    }

    // Windows are found by their scene ID at the start of the window's identifier (the main window at launch):
    // no window's ID may start with another one's
    func testWindowIDsDontStartWithEachOther() {
        let ids = [MainWindow.id, MapWindow.id, PlannerWindow.id, PlacePickerWindow.id, HowItWorksWindow.id, SetupWindow.id]
        XCTAssertEqual(Set(ids).count, ids.count)
        for a in ids {
            for b in ids where a != b {
                XCTAssertFalse(a.hasPrefix(b), "\(a) starts with \(b)")
            }
        }
    }

    // The place picker's map column is 40% of the window, kept between 280 and 420 points, so the lists keep most of the width;
    // the smallest window still leaves the lists more room than the map
    func testPlacePickerMapColumnStaysInItsRange() {
        XCTAssertEqual(PlacePickerWindow.mapColumnWidth(PlacePickerWindow.minSize.width), 280, accuracy: 0.01)
        XCTAssertEqual(PlacePickerWindow.mapColumnWidth(PlacePickerWindow.defaultSize.width), 344, accuracy: 0.01)
        XCTAssertEqual(PlacePickerWindow.mapColumnWidth(1600), 420, accuracy: 0.01)
        XCTAssertGreaterThan(PlacePickerWindow.minSize.width - PlacePickerWindow.mapColumnWidth(PlacePickerWindow.minSize.width), 280)
        XCTAssertGreaterThanOrEqual(PlacePickerWindow.defaultSize.width, PlacePickerWindow.minSize.width)
        XCTAssertGreaterThanOrEqual(PlacePickerWindow.defaultSize.height, PlacePickerWindow.minSize.height)
    }

    // "Show trains" in the map window asks only that station's card for its bounce, and only for a few seconds:
    // a card that appears later doesn't bounce for it
    func testCardBounceAsksOneStationForAFewSeconds() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let ask = CardBounce(station: "A", at: at)
        XCTAssertTrue(ask.asks("A", now: at))
        XCTAssertTrue(ask.asks("A", now: at.addingTimeInterval(2)))
        XCTAssertFalse(ask.asks("B", now: at.addingTimeInterval(1)))
        XCTAssertFalse(ask.asks("A", now: at.addingTimeInterval(3)))
    }

    // The maps work out where their stations are from the area the map last reported (MapScreen), only while the view still has the
    // size it had then and the map faces north, flat; otherwise the transit map waits for the map's new area (turned or tilted, it
    // shows no labels), and Plan a Trip's asks MapKit while it can be seen. A click is placed the same way back
    @MainActor func testMapProjectionOnlyForTheReportedSize() throws {
        let size = CGSize(width: 800, height: 500)
        let rect = MKMapRect(x: 77_000_000, y: 98_000_000, width: 80_000, height: 50_000)
        let visible = MapVisibleRect(rect: rect, heading: 0, pitch: 0, size: size)
        let projection = try XCTUnwrap(MapScreen.projection(visible, size: size))
        XCTAssertNotNil(MapScreen.projection(visible, size: CGSize(width: 800.3, height: 500)))
        // A new size of the same shape: the area is an old one
        XCTAssertNil(MapScreen.projection(visible, size: CGSize(width: 960, height: 600)))
        XCTAssertNil(MapScreen.projection(nil, size: size))
        XCTAssertNil(MapScreen.projection(MapVisibleRect(rect: rect, heading: 45, pitch: 0, size: size), size: size))
        XCTAssertNil(MapScreen.projection(MapVisibleRect(rect: rect, heading: 0, pitch: 30, size: size), size: size))
        let screen = MapScreen(projection)
        XCTAssertNotNil(screen.projection)
        XCTAssertGreaterThan(screen.metersPerPoint, 0)
        // A click on the view: the place there, which is drawn at that point again
        let place = try XCTUnwrap(screen.coordinate(at: CGPoint(x: 200, y: 125)))
        let back = try XCTUnwrap(screen.point(place))
        XCTAssertEqual(back.x, 200, accuracy: 0.01)
        XCTAssertEqual(back.y, 125, accuracy: 0.01)
        // Turned or tilted only counts for an area at the view's size: an old area is just waited for
        XCTAssertFalse(MapScreen.isTurned(visible, size: size))
        XCTAssertTrue(MapScreen.isTurned(MapVisibleRect(rect: rect, heading: 45, pitch: 0, size: size), size: size))
        XCTAssertTrue(MapScreen.isTurned(MapVisibleRect(rect: rect, heading: 0, pitch: 30, size: size), size: size))
        XCTAssertFalse(MapScreen.isTurned(MapVisibleRect(rect: rect, heading: 45, pitch: 0, size: size), size: CGSize(width: 960, height: 600)))
        XCTAssertFalse(MapScreen.isTurned(nil, size: size))
        // A heading of 359.995° is north (within MapProjection.angleTolerance)
        XCTAssertFalse(MapScreen.isTurned(MapVisibleRect(rect: rect, heading: 359.995, pitch: 0, size: size), size: size))
    }

    // The Walk from switch keeps its two segments side by side while the wider one's text fits its half shrunk to 85% (its padding
    // doesn't shrink), and puts them one above the other when it doesn't. Without shrink and inset (the two window buttons above it)
    // the wider one's full width decides
    @MainActor func testWalkFromSwitchStacksOnlyWhenItsShrunkTextDoesNotFit() {
        let shrink = LocationModeSwitch.shrink, inset = LocationModeSwitch.inset
        XCTAssertEqual(shrink, 0.85, accuracy: 0.001)
        XCTAssertEqual(inset, 8, accuracy: 0.001)
        // Halves of 100: a text 108 wide shrinks to 91.8, plus 8 of padding
        XCTAssertTrue(SidebarWindowPairLayout.sideBySide(width: 202, ideals: [116, 90], spacing: 2, shrink: shrink, inset: inset))
        XCTAssertFalse(SidebarWindowPairLayout.sideBySide(width: 202, ideals: [117, 90], spacing: 2, shrink: shrink, inset: inset))
        // The padding doesn't shrink: the same width with none fits
        XCTAssertTrue(SidebarWindowPairLayout.sideBySide(width: 202, ideals: [117, 90], spacing: 2, shrink: shrink, inset: 0))
        // Defaults: the wider one at its full width
        XCTAssertTrue(SidebarWindowPairLayout.sideBySide(width: 202, ideals: [100, 90], spacing: 2))
        XCTAssertFalse(SidebarWindowPairLayout.sideBySide(width: 201.9, ideals: [100, 90], spacing: 2))
        XCTAssertEqual(SidebarWindowPairLayout.sideBySide(width: 201.9, ideals: [100, 90], spacing: 2, shrink: 1, inset: 0),
                       SidebarWindowPairLayout.sideBySide(width: 201.9, ideals: [100, 90], spacing: 2))
        XCTAssertTrue(SidebarWindowPairLayout.sideBySide(width: 0, ideals: [], spacing: 2))
    }

    // A station card's kind boxes under its name wrap like the route badges, each line ending at the trailing side, and a box wider
    // than the whole line is given only the line's width (its text shortened with "…") rather than widening the card. Without
    // trailing and fitsWidth each line starts at the leading side and a box keeps its full width
    @MainActor func testKindBoxesWrapWithEachLineEndingAtTheTrailingSide() {
        let boxes = [CGSize(width: 40, height: 14), CGSize(width: 30, height: 14), CGSize(width: 50, height: 14)]
        let trailing = FlowLayout.positions(sizes: boxes, width: 80, spacing: 3, lineSpacing: 3, trailing: true, fitsWidth: true)
        XCTAssertEqual(trailing.points, [CGPoint(x: 7, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 30, y: 17)])
        XCTAssertEqual(trailing.size, CGSize(width: 73, height: 31))
        let leading = FlowLayout.positions(sizes: boxes, width: 80, spacing: 3, lineSpacing: 3)
        XCTAssertEqual(leading.points, [CGPoint(x: 0, y: 0), CGPoint(x: 43, y: 0), CGPoint(x: 0, y: 17)])
        XCTAssertEqual(leading.size, trailing.size)
        // With no width, all on one line, which ends where it starts anyway
        let one = FlowLayout.positions(sizes: boxes, width: nil, spacing: 3, lineSpacing: 3, trailing: true, fitsWidth: true)
        XCTAssertEqual(one.points, [CGPoint(x: 0, y: 0), CGPoint(x: 43, y: 0), CGPoint(x: 76, y: 0)])
        XCTAssertEqual(one.size, CGSize(width: 126, height: 14))
        // A box wider than the line: as wide as the line with fitsWidth, at its full width without; either way on a line of its own
        let wide = [CGSize(width: 120, height: 14), CGSize(width: 30, height: 14)]
        let fitted = FlowLayout.positions(sizes: wide, width: 80, spacing: 3, lineSpacing: 3, trailing: true, fitsWidth: true)
        XCTAssertEqual(fitted.points, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 17)])
        XCTAssertEqual(fitted.size, CGSize(width: 80, height: 31))
        let full = FlowLayout.positions(sizes: wide, width: 80, spacing: 3, lineSpacing: 3, trailing: true)
        XCTAssertEqual(full.points, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 17)])
        XCTAssertEqual(full.size, CGSize(width: 120, height: 31))
        XCTAssertEqual(FlowLayout.offered(wide[0], width: 80, fitsWidth: true), CGSize(width: 80, height: 14))
        XCTAssertEqual(FlowLayout.offered(wide[0], width: 80, fitsWidth: false), wide[0])
        XCTAssertEqual(FlowLayout.offered(wide[0], width: nil, fitsWidth: true), wide[0])
        // A line a little wider than the width it was measured at (rounded to the screen's pixels) still starts at the leading side
        let rounded = FlowLayout.positions(sizes: [CGSize(width: 33.3, height: 13), CGSize(width: 33.3, height: 13)], width: 68.4,
                                           spacing: 2, lineSpacing: 2, trailing: true)
        XCTAssertEqual(rounded.points[0], .zero)
        XCTAssertEqual(rounded.points[1].x, 35.3, accuracy: 0.001)
        XCTAssertEqual(rounded.points[1].y, 0)
    }

    // The direction switch keeps "Both directions" at the width it needs; the two directions share the rest equally when both names
    // fit in half, otherwise the longer one gets what it needs (or all the shorter one leaves it, and wraps there)
    @MainActor func testDirectionSegmentsShareTheRestAfterBothDirections() {
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 120, 150], in: 600, spacing: 2), [130, 233, 233])
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 120, 300], in: 600, spacing: 2), [130, 166, 300])
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 400, 200], in: 600, spacing: 2), [130, 266, 200])
        // Neither name fits in half: half each, and both wrap
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 300, 400], in: 600, spacing: 2), [130, 233, 233])
        // Narrower than "Both directions" itself: it still keeps its width
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 120, 150], in: 100, spacing: 2), [130, 0, 0])
        // Asked for its ideal size: each as wide as it needs
        XCTAssertEqual(DirectionSegmentsLayout.widths([130, 120, 150], in: nil, spacing: 2), [130, 120, 150])
    }

    // The direction switch is as tall as its tallest segment, with a little room above and below once a name wraps onto a second
    // line; names that fit on one line keep it at that height, also in a script whose lines are taller
    @MainActor func testDirectionSwitchAddsRoomOnlyWhenANameWraps() {
        XCTAssertEqual(DirectionSegmentsLayout.height([26, 26, 26], oneLine: [26, 26, 26], room: 6), 26)
        XCTAssertEqual(DirectionSegmentsLayout.height([26, 30, 26], oneLine: [26, 26, 26], room: 6), 36)
        XCTAssertEqual(DirectionSegmentsLayout.height([29, 26, 26], oneLine: [29, 26, 26], room: 6), 29)
        // A hair taller at its width than on one line (rounding) isn't a wrap
        XCTAssertEqual(DirectionSegmentsLayout.height([26, 26.3, 26], oneLine: [26, 26, 26], room: 6), 26.3, accuracy: 0.001)
    }

    // A place card's height grows with the text size and never with its name: a name too long for one line takes up to two lines
    // one text style smaller, and two such lines fit in the card at every text size
    @MainActor func testPlaceCardHasRoomForTwoLinesOfALongName() {
        XCTAssertEqual(AppTextSize.allCases.map { PlacePickerWindow.cardHeight($0.factor) }, [34, 39, 44])
        let factor = TextScale.factor
        defer { TextScale.factor = factor }
        for size in AppTextSize.allCases {
            TextScale.factor = size.factor
            let name = NSHostingController(rootView: Text(verbatim: "Jamaica Center-\nParsons/Archer").font(.scaled(.callout)))
            XCTAssertLessThanOrEqual(name.sizeThatFits(in: CGSize(width: 1000, height: 1000)).height,
                                     PlacePickerWindow.cardHeight(size.factor), "\(size)")
        }
    }

    // A favorite's star moved aside off the starting point's pin is drawn where clicks and the mouse find it: the point pinned to
    // its place stays on the place's point however far the star moves, for one favorite's star, one for several and a small one
    // beside a station's dot. The pin stands above its point, the current location's dot is round on it
    @MainActor func testMovedStarIsDrawnWhereClicksFindIt() {
        let center = CGPoint(x: 205, y: 125)
        let stars = [(CGSize(width: FavoriteStarSpot.diameter, height: FavoriteStarSpot.diameter), false),
                     (CGSize(width: 40, height: FavoriteStarSpot.diameter), false),
                     (CGSize(width: FavoriteStarSpot.badgeDiameter, height: FavoriteStarSpot.badgeDiameter), true)]
        for (size, onStation) in stars {
            let still = FavoriteStarSpot.frame(center: center, size: size, onStation: onStation, shift: 0)
            for shift: CGFloat in [0, 17, -23.5] {
                let frame = FavoriteStarSpot.frame(center: center, size: size, onStation: onStation, shift: shift)
                let anchor = FavoriteStarSpot.anchor(size: size, onStation: onStation, shift: shift)
                XCTAssertEqual(frame.minX + anchor.x * size.width, center.x, accuracy: 0.001)
                XCTAssertEqual(frame.minY + anchor.y * size.height, center.y, accuracy: 0.001)
                XCTAssertEqual(frame.minX - still.minX, shift, accuracy: 0.001)
                XCTAssertEqual(frame.minY, still.minY, accuracy: 0.001)
            }
        }
        XCTAssertEqual(SubwayMapView.originFrame(at: CGPoint(x: 100, y: 100), dot: false), CGRect(x: 84, y: 58, width: 32, height: 46))
        XCTAssertEqual(SubwayMapView.originFrame(at: CGPoint(x: 100, y: 100), dot: true), CGRect(x: 88, y: 88, width: 24, height: 24))
    }

    // The sidebar header's line can let only its last kind wrap between its words: the kinds before it, their dots and the
    // no-break spaces in them stay as they are, and the hidden copy that measures it is that last kind alone
    @MainActor func testHeaderLineLoosensOnlyItsLastKind() {
        let parts = "Light\u{00A0}Rail\u{00A0}· Commuter\u{00A0}Rail\u{00A0}· Intercity\u{00A0}Rail"
        XCTAssertEqual(ModeHeader.loosenedLastKind(parts), "Light\u{00A0}Rail\u{00A0}· Commuter\u{00A0}Rail\u{00A0}· Intercity Rail")
        XCTAssertEqual(ModeHeader.lastKind(of: parts), "Intercity\u{00A0}Rail")
        // A last kind of one word: nothing to loosen
        let oneWord = "Commuter\u{00A0}Rail\u{00A0}· Subway"
        XCTAssertEqual(ModeHeader.loosenedLastKind(oneWord), oneWord)
        XCTAssertEqual(ModeHeader.lastKind(of: oneWord), "Subway")
    }

    // With one kind, that kind is the last one: all of its words can wrap, and it is measured whole. The line for no data has
    // ordinary spaces and stays as it is
    @MainActor func testHeaderLineWithOneKindLoosensThatKind() {
        let parts = "Passenger\u{00A0}Ferry"
        XCTAssertEqual(ModeHeader.loosenedLastKind(parts), "Passenger Ferry")
        XCTAssertEqual(ModeHeader.lastKind(of: parts), parts)
        let none = "No data for this transit system in this area yet."
        XCTAssertEqual(ModeHeader.loosenedLastKind(none), none)
        XCTAssertEqual(ModeHeader.lastKind(of: none), none)
    }

    // The menu bar panel grows with the text size: 400 points at the standard size, 460 and 520 with larger text
    @MainActor func testMenuBarPanelWidensWithTheTextSize() {
        XCTAssertEqual(MenuBarPanel.width(for: .standard), 400)
        XCTAssertEqual(MenuBarPanel.width(for: .large), 460)
        XCTAssertEqual(MenuBarPanel.width(for: .larger), 520)
    }

    // Settings' Delete Downloaded Data… stays at the end of its text's line while the text keeps about half the row, and goes
    // under the text otherwise (the layout of a card's kind boxes)
    @MainActor func testDeleteDataButtonGoesUnderItsTextOnlyWhenTight() {
        // A short language at the standard size: the text fits beside the button
        XCTAssertTrue(NameAndKindsLayout.beside(width: 440, name: 185, boxes: 170, spacing: 12))
        // A long language with the largest text: beside the button the text would keep a third of the row
        XCTAssertFalse(NameAndKindsLayout.beside(width: 440, name: 290, boxes: 285, spacing: 12))
    }

    // A sidebar window button measures its title one word per line, so its arrow is left out only when a single word with the
    // icon and the arrow is too wide
    @MainActor func testWindowButtonMeasuresItsTitleOneWordPerLine() {
        XCTAssertEqual(SidebarWindowRow.wordLines("Plan a Trip"), "Plan\na\nTrip")
        XCTAssertEqual(SidebarWindowRow.wordLines("Subway  map"), "Subway\nmap")
        XCTAssertEqual(SidebarWindowRow.wordLines("Map"), "Map")
    }

    // The setup window grows when it opens to show all of its content, keeping its top edge: never taller than the screen's
    // visible area (moved up when its bottom would go below it), and never shorter, so a size that already fits stays
    func testSetupWindowGrowsToFitItsContentWithinTheScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let window = CGRect(x: 400, y: 200, width: 560, height: 680)
        XCTAssertEqual(SetupWindow.grownFrame(window, content: 820, room: 700, visible: visible),
                       CGRect(x: 400, y: 80, width: 560, height: 800))
        // Fits, or over by less than a point (rounding): as it is
        XCTAssertEqual(SetupWindow.grownFrame(window, content: 700.4, room: 700, visible: visible), window)
        XCTAssertEqual(SetupWindow.grownFrame(window, content: 300, room: 700, visible: visible), window)
        // More missing than the screen has room for: as tall as the visible area
        XCTAssertEqual(SetupWindow.grownFrame(window, content: 1000, room: 700, visible: visible),
                       CGRect(x: 400, y: 40, width: 560, height: 860))
        // Its bottom would go below the visible area: moved up
        let low = CGRect(x: 400, y: 100, width: 560, height: 680)
        XCTAssertEqual(SetupWindow.grownFrame(low, content: 850, room: 700, visible: visible),
                       CGRect(x: 400, y: 40, width: 560, height: 830))
        // As tall as the visible area already: as it is
        let tall = CGRect(x: 400, y: 40, width: 560, height: 860)
        XCTAssertEqual(SetupWindow.grownFrame(tall, content: 1000, room: 700, visible: visible), tall)
    }

    // A number typed into a Settings field is kept within its range and on its step; the row says "Changed to" only when that
    // changed what was typed, not for a rounding error (4.5 + 0.1 from the +/- buttons is 4.6000000000000005)
    func testNumberFieldSaysChangedOnlyWhenTheNumberChanged() {
        func fit(_ typed: Double, _ range: ClosedRange<Double>, _ step: Double) -> (kept: Double, changed: Bool) {
            let kept = NumberFit.kept(typed, range: range, step: step)
            return (kept, NumberFit.changed(typed, to: kept, step: step))
        }
        // Outside the range: the nearest end
        XCTAssertEqual(fit(45, 3...30, 1).kept, 30)
        XCTAssertTrue(fit(45, 3...30, 1).changed)
        XCTAssertEqual(fit(1, 3...30, 1).kept, 3)
        XCTAssertTrue(fit(1, 3...30, 1).changed)
        // Between two steps: the nearest step
        XCTAssertEqual(fit(200, 120...600, 30).kept, 210)
        XCTAssertTrue(fit(200, 120...600, 30).changed)
        XCTAssertEqual(fit(4.54, 2...7, 0.1).kept, 4.5, accuracy: 0.000001)
        XCTAssertTrue(fit(4.54, 2...7, 0.1).changed)
        // Allowed as it is, and the +/- buttons' sums: no change
        XCTAssertFalse(fit(15, 3...30, 1).changed)
        XCTAssertFalse(fit(30, 3...30, 1).changed)
        XCTAssertFalse(fit(240, 120...600, 30).changed)
        XCTAssertFalse(fit(4.5 + 0.1, 2...7, 0.1).changed)
        XCTAssertFalse(fit(4.6, 2...7, 0.1).changed)
        XCTAssertFalse(fit(0.1 + 0.2, 0...1, 0.1).changed)
    }

    // On standby a "Check … Now" button is a Start button, except in Demo mode or with the network off (where starting
    // wouldn't let it check either)
    func testCheckButtonsAreStartOnlyOnStandbyWithTheNetworkOn() {
        XCTAssertTrue(TransitModel.startsToCheck(active: false, demo: false, networkAllowed: true))
        XCTAssertFalse(TransitModel.startsToCheck(active: true, demo: false, networkAllowed: true))
        XCTAssertFalse(TransitModel.startsToCheck(active: false, demo: true, networkAllowed: true))
        XCTAssertFalse(TransitModel.startsToCheck(active: false, demo: false, networkAllowed: false))
        XCTAssertFalse(TransitModel.startsToCheck(active: true, demo: true, networkAllowed: false))
    }

    // The Updates row's lines under the version say each sentence once: on standby the status and the reason its button is
    // gray are the same sentence
    func testUpdateLinesSayEachSentenceOnce() {
        XCTAssertEqual(UpdateText.lines(["Turn it on to check.", "Turn it on to check."]), "Turn it on to check.")
        XCTAssertEqual(UpdateText.lines(["You have the latest version.", nil]), "You have the latest version.")
        XCTAssertEqual(UpdateText.lines(["Checking\u{2026}", "Turn it on to check."]), "Checking\u{2026}\nTurn it on to check.")
        XCTAssertEqual(UpdateText.lines([nil, nil]), "")
    }

    // A departure's details count the time from reaching the stop to boarding, so they say which it is and the lines add up: at a
    // pier or a bus stop boarding, the Statue of Liberty ferry's 30 minutes of tickets and security, at a station the way to the
    // platform. MTA's bus stops have none
    func testBoardingLineSaysWhatItsMinutesAreFor() {
        let l = UIText(language: .english)
        XCTAssertEqual(l.boardingLine(seconds: 1800, routes: ["SOL"]), "Ticket and security check: 30 min")
        XCTAssertEqual(l.boardingLine(seconds: 60, routes: ["NYF-ER", "NYW"]), "Time to board: 1 min")
        XCTAssertEqual(l.boardingLine(seconds: 60, routes: ["NJB-107"]), "Time to board: 1 min")
        XCTAssertEqual(l.boardingLine(seconds: 120, routes: ["LIRR-BAB"]), "Station entrance to platform: 2 min")
        XCTAssertEqual(l.boardingLine(seconds: 120, routes: ["L"]), "Station entrance to platform: 2 min")
        XCTAssertNil(l.boardingLine(seconds: 0, routes: ["M104"]))
    }

    // Whose live data it is, by the name areas.json gives the operator, and the note when it couldn't be had at all
    func testLiveDataIsNamedFromTheData() {
        let l = UIText(language: .english)
        XCTAssertEqual(l.liveSource(.subway, arrivals: []).text, "MTA live")
        XCTAssertEqual(l.liveDataFailed(ofOperator: "path"), "Couldn't get PATH live data. Check your network.")
        XCTAssertEqual(l.liveDataFailed(ofOperator: "mbs"), "Couldn't get MBTA live data. Check your network.")
    }

    // Every operator with a How It Works sentence of its own (ModeCoverage.ownSentence: the few that do something differently)
    // has that sentence; the rest of each area's operators are named in the lines made from the data
    func testHowItWorksHasEveryOwnSentence() {
        XCTAssertEqual(HowItWorksView.withoutOwnSentence, [])
    }

    // A button elsewhere opens Settings at a place: the window shows the page that place is on. The pages each have a name
    // and an icon of their own, and the column is as wide as its longest name needs
    func testSettingsPlacesAreOnTheirPages() {
        typealias Target = SettingsJump.Target
        XCTAssertEqual([Target.dataSource, .keys, .downloadedData, .downloadedTotal, .demo].map(\.page),
                       Array(repeating: SettingsPage.dataSource, count: 5))
        XCTAssertEqual(Target.privacy.page, .privacy)
        XCTAssertEqual(Target.searchRange.page, .searchRange)
        XCTAssertEqual(Target.updates.page, .about)
        XCTAssertEqual(Set(Target.allCases.map(\.id)).count, Target.allCases.count)
        let l = UIText(language: .english)
        XCTAssertEqual(SettingsPage.allCases.map { $0.name(l) }, ["General", "Running", "Privacy", "Search range", "Data source", "Reminders", "About"])
        XCTAssertEqual(Set(SettingsPage.allCases.map(\.symbol)).count, SettingsPage.allCases.count)
        // The longest of these names is Russian's: the column is wider for it, and the window's smallest width follows
        let russian = UIText(language: .russian)
        XCTAssertGreaterThanOrEqual(SettingsColumn.width(l), SettingsColumn.minWidth)
        XCTAssertGreaterThan(SettingsColumn.width(russian), SettingsColumn.width(l))
        XCTAssertEqual(SettingsColumn.windowMinWidth(russian), SettingsColumn.width(russian) + 1 + SettingsColumn.pageMinWidth)
    }
}
