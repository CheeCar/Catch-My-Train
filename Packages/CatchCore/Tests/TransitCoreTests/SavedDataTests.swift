import XCTest
@testable import TransitCore

/// After an app update, favorites, recent places and settings saved by older versions must still load (updates must not lose data).
/// The JSON below is the format that earlier versions actually wrote.
final class SavedDataTests: XCTestCase {

    /// Favorites / recent places saved by an earlier version
    private let savedPlaces = #"""
    [{"name":"Times Sq-42 St","latitude":40.7557,"longitude":-73.9871},
     {"name":"Hoboken Terminal","latitude":40.7359,"longitude":-74.0291},
     {"name":"Milford, PA","latitude":41.3223,"longitude":-74.8024}]
    """#

    func testOldFavoritesAreRead() throws {
        let list = try XCTUnwrap(SavedData.list(UserPlace.self, from: Data(savedPlaces.utf8)))
        XCTAssertEqual(list.map(\.name), ["Times Sq-42 St", "Hoboken Terminal", "Milford, PA"])
        XCTAssertEqual(list[1].latitude, 40.7359)
        XCTAssertEqual(list[1].longitude, -74.0291)
    }

    func testOneUnreadablePlaceDoesNotDropTheOthers() throws {
        let json = #"[{"name":"Grand Central","latitude":40.7527,"longitude":-73.9772},{"name":"Broken"},{"name":"Stamford Station","latitude":41.0466,"longitude":-73.5419}]"#
        let list = try XCTUnwrap(SavedData.list(UserPlace.self, from: Data(json.utf8)))
        XCTAssertEqual(list.map(\.name), ["Grand Central", "Stamford Station"])
    }

    func testDataThatIsNotAListIsReportedAsUnreadable() {
        XCTAssertNil(SavedData.list(UserPlace.self, from: Data(#"{"name":"x"}"#.utf8)))
        XCTAssertNil(SavedData.list(UserPlace.self, from: Data("not json".utf8)))
    }

    /// The saved keys must not be renamed: old versions can read what new versions write, and vice versa
    func testPlaceKeepsItsSavedFormat() throws {
        let place = UserPlace(name: "Hicksville Station", coordinate: Coordinate(latitude: 40.7676, longitude: -73.5283))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(place)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["name", "latitude", "longitude"])
        XCTAssertEqual(try JSONDecoder().decode(UserPlace.self, from: JSONEncoder().encode(place)), place)
    }

    /// A very early version: still has the obsolete extendedBetterByMinutes, no arrivalWindowMinutes
    func testOldSettingsKeepTheUsersValues() throws {
        let json = #"{"primaryWalkMinutes":12,"extendedWalkMinutes":25,"candidateRadiusMeters":2000,"safetyBufferMinutes":4,"walkingSpeedKmh":5.5,"detourFactor":1.25,"realtimeStaleAfterSeconds":240,"extendedBetterByMinutes":3}"#
        let s = try JSONDecoder().decode(CatchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.primaryWalkMinutes, 12)
        XCTAssertEqual(s.extendedWalkMinutes, 25)
        XCTAssertEqual(s.candidateRadiusMeters, 2000)
        XCTAssertEqual(s.safetyBufferMinutes, 4)
        XCTAssertEqual(s.walkingSpeedKmh, 5.5)
        XCTAssertEqual(s.realtimeStaleAfterSeconds, 240)
        XCTAssertEqual(s.arrivalWindowSeconds, CatchSettings.defaultArrivalWindowMinutes * 60)
    }

    /// One key missing (e.g. a later version added a new setting, then downgraded): only that key uses the default, the rest stay as they were
    func testMissingSettingFallsBackOnlyForThatSetting() throws {
        let json = #"{"primaryWalkMinutes":10,"extendedWalkMinutes":30,"candidateRadiusMeters":1500,"safetyBufferMinutes":1,"realtimeStaleAfterSeconds":120,"arrivalWindowMinutes":60}"#
        let s = try JSONDecoder().decode(CatchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.primaryWalkMinutes, 10)
        XCTAssertEqual(s.extendedWalkMinutes, 30)
        XCTAssertEqual(s.walkingSpeedKmh, CatchSettings.default.walkingSpeedKmh)
        XCTAssertEqual(s.detourFactor, CatchSettings.default.detourFactor)
        XCTAssertEqual(s.arrivalWindowMinutes, 60)
    }

    func testSettingsRoundTrip() throws {
        let s = CatchSettings(primaryWalkMinutes: 9, extendedWalkMinutes: 18, safetyBufferMinutes: 3, arrivalWindowMinutes: 90)
        XCTAssertEqual(try JSONDecoder().decode(CatchSettings.self, from: JSONEncoder().encode(s)), s)
    }
}

/// Each of the two Settings sections resets to defaults on its own, changing only its own keys
final class SettingsSectionResetTests: XCTestCase {
    func testSearchRangeResetLeavesCatchJudgment() {
        var s = CatchSettings.default
        s.primaryWalkMinutes = 25; s.candidateRadiusMeters = 2000; s.arrivalWindowMinutes = 60
        s.safetyBufferMinutes = 5; s.walkingSpeedKmh = 6
        XCTAssertFalse(s.isSearchRangeDefault)
        s.resetSearchRange()
        XCTAssertTrue(s.isSearchRangeDefault)
        XCTAssertEqual(s.safetyBufferMinutes, 5)
        XCTAssertEqual(s.walkingSpeedKmh, 6)
    }

    func testCatchJudgmentResetLeavesSearchRange() {
        var s = CatchSettings.default
        s.primaryWalkMinutes = 25; s.safetyBufferMinutes = 5; s.walkingSpeedKmh = 6; s.realtimeStaleAfterSeconds = 300
        XCTAssertFalse(s.isCatchJudgmentDefault)
        s.resetCatchJudgment()
        XCTAssertTrue(s.isCatchJudgmentDefault)
        XCTAssertEqual(s.safetyBufferMinutes, CatchSettings.default.safetyBufferMinutes)
        XCTAssertEqual(s.walkingSpeedKmh, CatchSettings.default.walkingSpeedKmh)
        XCTAssertEqual(s.primaryWalkMinutes, 25)
        // "Real-time data expires after" is in Advanced now, with its own reset
        XCTAssertEqual(s.realtimeStaleAfterSeconds, 300)
        XCTAssertTrue(CatchSettings.default.isSearchRangeDefault && CatchSettings.default.isCatchJudgmentDefault
                      && CatchSettings.default.isAdvancedDefault)
    }

    func testAdvancedResetLeavesTheOthers() {
        var s = CatchSettings.default
        s.realtimeStaleAfterSeconds = 300; s.safetyBufferMinutes = 5; s.primaryWalkMinutes = 25
        XCTAssertFalse(s.isAdvancedDefault)
        XCTAssertTrue(CatchSettings(realtimeStaleAfterSeconds: 300).isCatchJudgmentDefault)
        s.resetAdvanced()
        XCTAssertTrue(s.isAdvancedDefault)
        XCTAssertEqual(s.realtimeStaleAfterSeconds, CatchSettings.default.realtimeStaleAfterSeconds)
        XCTAssertEqual(s.safetyBufferMinutes, 5)
        XCTAssertEqual(s.primaryWalkMinutes, 25)
    }

    /// The radius shows rounded to 10 m: the default 4,000 ft (1,219.2 m) shows as 1,220 m, and 1,220 m set by hand counts as the default
    func testRadiusWithinAMeterOfTheDefaultIsTheDefault() {
        var s = CatchSettings.default
        s.candidateRadiusMeters = 1220
        XCTAssertTrue(s.isSearchRangeDefault)
        s.candidateRadiusMeters = 1210
        XCTAssertFalse(s.isSearchRangeDefault)
        s.candidateRadiusMeters = 1219.2 + 30.48   // 4,100 ft
        XCTAssertFalse(s.isSearchRangeDefault)
        s.candidateRadiusMeters = .nan
        XCTAssertFalse(s.isSearchRangeDefault)
        // The radius close to the default doesn't hide another change
        s = CatchSettings.default
        s.candidateRadiusMeters = 1220; s.primaryWalkMinutes = 20
        XCTAssertFalse(s.isSearchRangeDefault)
    }

    /// The walking speed shows rounded to 0.1: 2.8 mph typed in (4.506 km/h) shows as the default in either unit, so it counts as
    /// the default; 2.9 mph and 4.6 km/h don't
    func testWalkingSpeedThatShowsAsTheDefaultIsTheDefault() {
        let mile = 1.609344
        var s = CatchSettings.default
        s.walkingSpeedKmh = 2.8 * mile
        XCTAssertTrue(s.isCatchJudgmentDefault)
        s.walkingSpeedKmh = 2.9 * mile
        XCTAssertFalse(s.isCatchJudgmentDefault)
        s.walkingSpeedKmh = 4.6
        XCTAssertFalse(s.isCatchJudgmentDefault)
        s.walkingSpeedKmh = 4.44
        XCTAssertFalse(s.isCatchJudgmentDefault)
        s.walkingSpeedKmh = .nan
        XCTAssertFalse(s.isCatchJudgmentDefault)
        // The speed close to the default doesn't hide another change, and Reset puts back the exact default
        s = CatchSettings.default
        s.walkingSpeedKmh = 2.8 * mile; s.safetyBufferMinutes = 3
        XCTAssertFalse(s.isCatchJudgmentDefault)
        s.resetCatchJudgment()
        XCTAssertEqual(s.walkingSpeedKmh, CatchSettings.default.walkingSpeedKmh)
    }
}

/// "Real-time data expires after": a minute more than the refresh interval at least, as the app has always used it; Settings
/// shows the value used and keeps the saved one as it was set
final class RealtimeStaleTests: XCTestCase {
    func testMinimumFollowsTheRefreshInterval() {
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 30), 90)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 60), 120)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 120), 180)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 300), 360)
        // In steps of 30 seconds, within the setting's range
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 45), 120)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 0), 60)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: 3600), 600)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: .nan), 60)
        XCTAssertEqual(CatchSettings.realtimeStaleMinimum(refreshInterval: -5), 60)
    }

    /// The value used is the one the app used before this was shown in Settings: the larger of the setting and the refresh
    /// interval plus 60 seconds, within the setting's range
    func testValueUsedIsTheSameAsBefore() {
        for interval: TimeInterval in [30, 60, 120, 300] {
            for saved: Double in [30, 60, 90, 120, 150, 180, 240, 330, 360, 390, 600, 900] {
                let s = CatchSettings(realtimeStaleAfterSeconds: saved)
                var before = s
                before.realtimeStaleAfterSeconds = max(s.realtimeStaleAfterSeconds, interval + 60)
                XCTAssertEqual(s.realtimeStale(refreshInterval: interval), before.sanitized().realtimeStaleAfterSeconds,
                               "saved \(saved), refresh \(interval)")
            }
        }
        // The saved value isn't changed by it
        let s = CatchSettings(realtimeStaleAfterSeconds: 120)
        XCTAssertEqual(s.realtimeStale(refreshInterval: 300), 360)
        XCTAssertEqual(s.realtimeStaleAfterSeconds, 120)
        XCTAssertEqual(s.realtimeStale(refreshInterval: 30), 120)
    }
}

/// Favorites and recent places in a temporary store: reading and writing, the same-place rules, and the copy kept of places that
/// can't be read (never the real saved data).
final class PlaceListsTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!
    private var lists: PlaceLists!

    private let a = UserPlace(name: "Grand Central", coordinate: Coordinate(latitude: 40.7527, longitude: -73.9772))
    private let b = UserPlace(name: "Stamford Station", coordinate: Coordinate(latitude: 41.0466, longitude: -73.5419))
    private let c = UserPlace(name: "Hoboken Terminal", coordinate: Coordinate(latitude: 40.7359, longitude: -74.0291))
    /// A list with one item an older or newer version wrote differently (no coordinates), between two good ones
    private let oneBroken = #"[{"name":"Grand Central","latitude":40.7527,"longitude":-73.9772},{"name":"Broken"},{"name":"Stamford Station","latitude":41.0466,"longitude":-73.5419}]"#

    override func setUpWithError() throws {
        suite = "CatchCoreTests.placeLists.\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suite))
        lists = PlaceLists(defaults: store)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    private func save(_ json: String, _ kind: PlaceLists.Kind) {
        store.set(Data(json.utf8), forKey: kind.key)
    }

    func testListsAreSavedUnderTheOldKeysInTheOldFormat() throws {
        lists.favorites = [a, b]
        lists.recents = [c]
        XCTAssertEqual(lists.favorites, [a, b])
        XCTAssertEqual(lists.recents, [c])
        let saved = try XCTUnwrap(store.data(forKey: "favoritePlaces"))
        XCTAssertEqual(SavedData.list(UserPlace.self, from: saved), [a, b])
        XCTAssertNotNil(store.data(forKey: "recentPlaces"))
        lists.recents = []
        XCTAssertNil(store.data(forKey: "recentPlaces"), "an empty list is removed, as before")
    }

    func testRecentPlacesKeepTheNewestTen() {
        let places = (0..<12).map { UserPlace(name: "P\($0)", coordinate: Coordinate(latitude: 40 + Double($0) * 0.01, longitude: -74)) }
        for p in places { lists.remember(p) }
        XCTAssertEqual(lists.recents.map(\.name), places.reversed().prefix(10).map(\.name))
    }

    func testARecentPlaceIsTheSameSpotWhateverItsName() {
        lists.remember(a)
        lists.remember(b)
        let renamed = UserPlace(name: "Home", coordinate: Coordinate(latitude: 40.7528, longitude: -73.9772))
        lists.remember(renamed)
        XCTAssertEqual(lists.recents, [renamed, b], "the older entry 11 m away goes")
        let sameName = UserPlace(name: "Home", coordinate: Coordinate(latitude: 40.80, longitude: -73.95))
        lists.remember(sameName)
        XCTAssertEqual(lists.recents, [sameName, renamed, b], "the same name somewhere else is another place")
    }

    func testFavoritesKeepTheirOwnRule() {
        let renamed = UserPlace(name: "Home", coordinate: a.coordinate)
        XCTAssertTrue(lists.toggleFavorite(a))
        XCTAssertTrue(lists.toggleFavorite(renamed))
        XCTAssertEqual(lists.favorites, [a, renamed], "two names for one spot are two favorites")
        XCTAssertTrue(lists.isFavorite(a))
        lists.toggleFavorite(a)
        XCTAssertEqual(lists.favorites, [renamed])
        XCTAssertTrue(PlaceLists.sameFavorite(a, a))
        XCTAssertFalse(PlaceLists.sameFavorite(a, renamed))
        XCTAssertTrue(PlaceLists.sameRecent(a, renamed))
    }

    func testFavoritesStopAtFifty() {
        lists.favorites = (0..<50).map { UserPlace(name: "P\($0)", coordinate: Coordinate(latitude: 40 + Double($0) * 0.01, longitude: -74)) }
        XCTAssertFalse(lists.toggleFavorite(a))
        XCTAssertEqual(lists.favorites.count, 50)
    }

    func testReorderingOnlyChangesTheOrder() {
        lists.favorites = [a, b, c]
        let removedElsewhere = UserPlace(name: "Gone", coordinate: Coordinate(latitude: 40.1, longitude: -74.1))
        lists.reorderFavorites([c, removedElsewhere, a])
        XCTAssertEqual(lists.favorites, [c, a, b], "a stale place isn't written back; one left out stays at the end")
    }

    // MARK: Places that can't be read

    func testNormalDataKeepsNoCopyAndAsksNothing() {
        lists.favorites = [a, b]
        lists.toggleFavorite(c)
        lists.remember(a)
        XCTAssertNil(lists.pendingRestore())
        XCTAssertEqual(lists.copyCount, 0)
    }

    func testOneUnreadablePlaceIsKeptBeforeTheListIsWritten() throws {
        save(oneBroken, .favorites)
        XCTAssertEqual(lists.favorites, [a, b])
        lists.toggleFavorite(c)
        XCTAssertEqual(lists.favorites, [a, b, c])
        let copy = try XCTUnwrap(store.data(forKey: "favoritePlaces.unreadable"))
        XCTAssertEqual(String(decoding: copy, as: UTF8.self), oneBroken, "kept exactly as it was")
        lists.toggleFavorite(a)
        XCTAssertEqual(String(decoding: try XCTUnwrap(store.data(forKey: "favoritePlaces.unreadable")), as: UTF8.self), oneBroken,
                       "the first copy isn't written over")
    }

    func testAWholeUnreadableListIsKeptAndNotWrittenOverSilently() throws {
        save(#"{"places":"a newer format"}"#, .recents)
        XCTAssertEqual(lists.recents, [])
        lists.remember(a)
        XCTAssertEqual(lists.recents, [a])
        XCTAssertNotNil(store.data(forKey: "recentPlaces.unreadable"))
        XCTAssertEqual(lists.pendingRestore(), PlaceLists.Restore(count: 0), "asked once, with nothing to restore yet")
        lists.dismissRestore()
        XCTAssertNil(lists.pendingRestore(), "not asked again")
        XCTAssertTrue(lists.hasCopy(of: .recents), "the copy stays")
    }

    func testTheCopyIsMadeBeforeAskingEvenWithoutAWrite() {
        save(oneBroken, .favorites)
        XCTAssertEqual(lists.pendingRestore(), PlaceLists.Restore(count: 0))
        XCTAssertTrue(lists.hasCopy(of: .favorites))
        XCTAssertEqual(lists.favorites, [a, b], "the list itself is untouched")
    }

    func testPlacesALaterVersionCanReadAreRestored() throws {
        // A copy made by a version that couldn't read item 1, which this version reads
        let copy = #"[{"name":"Grand Central","latitude":40.7527,"longitude":-73.9772},{"name":"Hoboken Terminal","latitude":40.7359,"longitude":-74.0291}]"#
        store.set(Data(copy.utf8), forKey: "favoritePlaces.unreadable")
        store.set([1], forKey: "favoritePlaces.unreadable.lost")
        store.set(0, forKey: "favoritePlaces.unreadable.asked")
        lists.favorites = [a, b]
        XCTAssertEqual(lists.restorable(.favorites), [c], "only the lost place, not the ones still in the list")
        XCTAssertEqual(lists.pendingRestore(), PlaceLists.Restore(count: 1), "asked again: now there's something to restore")
        XCTAssertEqual(lists.restore(), 1)
        XCTAssertEqual(lists.favorites, [a, b, c])
        XCTAssertFalse(lists.hasCopy(of: .favorites), "deleted after the restore")
        XCTAssertNil(lists.pendingRestore())
    }

    func testAPlaceTheUserRemovedIsNotOfferedBack() {
        save(oneBroken, .favorites)
        _ = lists.pendingRestore()
        lists.dismissRestore()
        lists.toggleFavorite(a)
        XCTAssertEqual(lists.restorable(.favorites), [], "a removed place that was readable all along isn't restorable")
        XCTAssertNil(lists.pendingRestore())
    }

    func testRestoringIntoFullFavoritesKeepsTheRest() {
        let copy = #"[{"name":"Grand Central","latitude":40.7527,"longitude":-73.9772},{"name":"Hoboken Terminal","latitude":40.7359,"longitude":-74.0291}]"#
        store.set(Data(copy.utf8), forKey: "favoritePlaces.unreadable")
        lists.favorites = (0..<49).map { UserPlace(name: "P\($0)", coordinate: Coordinate(latitude: 40 + Double($0) * 0.01, longitude: -74)) }
        XCTAssertEqual(lists.restore(), 1)
        XCTAssertEqual(lists.favorites.count, 50)
        XCTAssertTrue(lists.hasCopy(of: .favorites), "what didn't fit stays in the copy")
        XCTAssertNil(lists.pendingRestore(), "and isn't asked about again while the favorites are full")
        // A favorite removed: there is room, so it is asked about again, and goes back
        lists.toggleFavorite(lists.favorites[0])
        XCTAssertEqual(lists.pendingRestore(), PlaceLists.Restore(count: 1))
        XCTAssertEqual(lists.restore(), 1)
        XCTAssertEqual(lists.favorites.count, 50)
        XCTAssertFalse(lists.hasCopy(of: .favorites))
        XCTAssertNil(lists.pendingRestore())
    }

    func testFullFavoritesAndSayingNoAreToldApart() {
        let copy = #"[{"name":"Grand Central","latitude":40.7527,"longitude":-73.9772},{"name":"Hoboken Terminal","latitude":40.7359,"longitude":-74.0291}]"#
        store.set(Data(copy.utf8), forKey: "favoritePlaces.unreadable")
        lists.favorites = (0..<50).map { UserPlace(name: "P\($0)", coordinate: Coordinate(latitude: 40 + Double($0) * 0.01, longitude: -74)) }
        XCTAssertEqual(lists.restore(), 0, "no room")
        XCTAssertNil(lists.pendingRestore())
        lists.toggleFavorite(lists.favorites[0])
        XCTAssertEqual(lists.pendingRestore(), PlaceLists.Restore(count: 2), "room for one: asked again")
        lists.dismissRestore()
        XCTAssertNil(lists.pendingRestore(), "turned down: not asked again")
        lists.toggleFavorite(lists.favorites[0])
        XCTAssertNil(lists.pendingRestore(), "not even with more room")
        XCTAssertTrue(lists.hasCopy(of: .favorites), "the copy stays")
    }

    func testRestoringKeepsACopyThatStillHasUnreadablePlaces() {
        store.set(Data(oneBroken.utf8), forKey: "recentPlaces.unreadable")
        lists.recents = [b]
        XCTAssertEqual(lists.restore(), 1, "Grand Central goes back; Stamford Station is there already")
        XCTAssertEqual(lists.recents, [b, a])
        XCTAssertTrue(lists.hasCopy(of: .recents), "the place that still can't be read is kept")
        XCTAssertNil(lists.pendingRestore())
    }

    func testClearingRecentPlacesDeletesTheirCopy() {
        save(oneBroken, .recents)
        lists.remember(c)
        XCTAssertTrue(lists.hasCopy(of: .recents))
        lists.clearRecents()
        XCTAssertEqual(lists.recents, [])
        XCTAssertEqual(lists.copyCount, 0)
        XCTAssertNil(store.object(forKey: "recentPlaces.unreadable.lost"))
        XCTAssertNil(lists.pendingRestore())
    }

    // MARK: The star popover's short lists, and the saved places matching typed text

    private func places(_ n: Int, _ prefix: String, from latitude: Double = 40) -> [UserPlace] {
        (0..<n).map { UserPlace(name: "\(prefix)\($0)", coordinate: Coordinate(latitude: latitude + Double($0) * 0.01, longitude: -74)) }
    }

    func testThePopoverListsTheFirstSixFavoritesAndTheNewestFourRecentPlaces() {
        let pick = PlaceLists.quickPick(favorites: places(23, "F"), recents: places(10, "R", from: 41))
        XCTAssertEqual(pick.favorites.map(\.name), ["F0", "F1", "F2", "F3", "F4", "F5"])
        XCTAssertEqual(pick.recents.map(\.name), ["R0", "R1", "R2", "R3"])
        XCTAssertTrue(pick.hasMore, "more than listed: the line saying how many are listed is shown")
    }

    func testThePopoverSaysHowManyItListsOnlyWhenSomeAreLeftOut() {
        XCTAssertFalse(PlaceLists.quickPick(favorites: places(6, "F"), recents: places(4, "R", from: 41)).hasMore, "all listed")
        XCTAssertTrue(PlaceLists.quickPick(favorites: places(7, "F"), recents: []).hasMore, "a favorite left out")
        XCTAssertTrue(PlaceLists.quickPick(favorites: places(2, "F"), recents: places(5, "R", from: 41)).hasMore, "a recent place left out")
        let none = PlaceLists.quickPick(favorites: [], recents: places(2, "R"))
        XCTAssertEqual(none.favorites, [])
        XCTAssertEqual(none.recents.count, 2)
        XCTAssertFalse(none.hasMore)
        // A new install: both lists empty, nothing to say
        let empty = PlaceLists.quickPick(favorites: [], recents: [])
        XCTAssertEqual(empty, PlaceLists.QuickPick(favorites: [], recents: [], hasMore: false))
    }

    func testTypedTextFindsSavedPlacesWhateverTheCapitalsAndAccents() {
        let cafe = UserPlace(name: "Caf\u{E9} Reggio", coordinate: Coordinate(latitude: 40.7303, longitude: -74.0003))
        let found = PlaceLists.matching("  CAFE r", favorites: [a, cafe, b], recents: [c])
        XCTAssertEqual(found.favorites, [cafe])
        XCTAssertEqual(found.recents, [])
        XCTAssertEqual(PlaceLists.matching("sta", favorites: [a, b], recents: [c]).favorites, [b], "in the middle of the name too")
        XCTAssertEqual(PlaceLists.matching("h", favorites: [a], recents: [c]).recents, [c], "from the first letter on")
        XCTAssertEqual(PlaceLists.matching("zzz", favorites: [a, b], recents: [c]).favorites, [])
        let nothing = PlaceLists.matching("   ", favorites: [a, b], recents: [c])
        XCTAssertTrue(nothing.favorites.isEmpty && nothing.recents.isEmpty, "nothing typed, nothing suggested")
        // Full-width letters, as typed with an East Asian input method
        XCTAssertEqual(PlaceLists.matching("\u{FF27}\u{FF52}\u{FF41}\u{FF4E}\u{FF44}", favorites: [a, b], recents: []).favorites, [a])
    }

    func testTypedMatchesListFavoritesFirstAndEachSpotOnce() {
        let again = UserPlace(name: "Grand Central Terminal", coordinate: Coordinate(latitude: 40.7528, longitude: -73.9772))
        let plaza = UserPlace(name: "Grand Army Plaza", coordinate: Coordinate(latitude: 40.6752, longitude: -73.9710))
        let found = PlaceLists.matching("grand", favorites: [a], recents: [again, plaza, plaza])
        XCTAssertEqual(found.favorites, [a])
        XCTAssertEqual(found.recents, [plaza], "the recent place 11 m from the favorite isn't listed again, and a spot is listed once")
    }

    func testTypedMatchesAreAtMostFive() {
        let some = PlaceLists.matching("p", favorites: places(4, "P"), recents: places(10, "PR", from: 41))
        XCTAssertEqual(some.favorites.count, 4)
        XCTAssertEqual(some.recents.map(\.name), ["PR0"], "favorites first, then recent places up to five in all")
        let many = PlaceLists.matching("p", favorites: places(7, "P"), recents: places(10, "PR", from: 41))
        XCTAssertEqual(many.favorites.map(\.name), ["P0", "P1", "P2", "P3", "P4"])
        XCTAssertEqual(many.recents, [])
    }

    func testThePresetsListOfFavoritesFindsEveryWordAnywhere() {
        let philly = UserPlace(name: "Philadelphia 30th Street Station", coordinate: Coordinate(latitude: 39.9557, longitude: -75.1820))
        let cafe = UserPlace(name: "Caf\u{E9} Grumpy", coordinate: Coordinate(latitude: 40.7420, longitude: -74.0040))
        let all = [a, b, philly, cafe] + places(50, "P")
        XCTAssertEqual(PlaceLists.search("", in: all), all, "nothing typed: all of them, in the user's order")
        XCTAssertEqual(PlaceLists.search("  ", in: all), all)
        XCTAssertEqual(PlaceLists.search("30th phil", in: all), [philly], "every word, anywhere, in any order")
        XCTAssertEqual(PlaceLists.search("street", in: all), [philly], "not only the name's start")
        XCTAssertEqual(PlaceLists.search("30th boston", in: all), [], "a word not in the name: not found")
        XCTAssertEqual(PlaceLists.search("CAFE", in: all), [cafe], "capitals and accents don't matter")
        XCTAssertEqual(PlaceLists.search("p49", in: all).map(\.name), ["P49"], "the 50th favorite is found too")
        XCTAssertEqual(PlaceLists.search("\u{FF27}\u{FF52}\u{FF41}\u{FF4E}\u{FF44}", in: [a, b]), [a], "full-width letters")
    }
}

/// The files the app and the widget share are in one plain folder (SharedFolder); the widget gets the few settings it needs as a
/// small file in it (WidgetHandoff).
final class SharedFolderTests: XCTestCase {
    private var names: [String] = []
    private var folders: [URL] = []

    private func store(_ label: String) throws -> UserDefaults {
        let name = "CatchCoreTests.move.\(label).\(UUID().uuidString)"
        names.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func folder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CatchCoreTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    override func tearDown() {
        for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
        for url in folders { try? FileManager.default.removeItem(at: url) }
    }

    private let home = UserPlace(name: "Grand Central", coordinate: Coordinate(latitude: 40.7527, longitude: -73.9772))
    private let work = UserPlace(name: "Hoboken Terminal", coordinate: Coordinate(latitude: 40.7359, longitude: -74.0291))

    /// The app's settings with something of every kind saved: favorites, recent places, the catch settings and settings of each
    /// kind of value
    private func fill(_ old: UserDefaults) throws {
        let lists = PlaceLists(defaults: old)
        lists.favorites = [home, work]
        lists.recents = [work]
        old.set(try JSONEncoder().encode(CatchSettings.default), forKey: "catchSettings")
        old.set(try JSONEncoder().encode(home), forKey: "userPlace")
        old.set("es", forKey: "appLanguage")
        old.set(120.0, forKey: "refreshIntervalSeconds")
        old.set(false, forKey: "networkAllowed")
        old.set(true, forKey: "rangeDefaultsUpgradedV2")
        old.set(["NJB"], forKey: "busRealtimeFailed")
    }

    // MARK: The shared folder

    func testTheSharedFolderIsInTheUsersLibrary() {
        let url = SharedFolder.url(inHome: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        XCTAssertEqual(url.path, "/Users/someone/Library/Application Support/com.cheecar.CatchMyTrain")
        XCTAssertEqual("/Users/someone" + SharedFolder.homeRelativePath, url.path + "/", "the entitlements name the same folder")
        XCTAssertFalse(SharedFolder.realHome.path.isEmpty)
    }

    func testTheFolderCheckWritesAndReadsBack() throws {
        let base = try folder("check")
        let inside = base.appendingPathComponent("a/b", isDirectory: true)
        XCTAssertNoThrow(try SharedFolder.check(inside), "made when it isn't there")
        XCTAssertEqual(try Data(contentsOf: inside.appendingPathComponent(SharedFolder.checkFileName)), Data("ok".utf8))
        XCTAssertNoThrow(try SharedFolder.check(inside), "and again")
        // A path that can't be a folder (a file is in the way): it says so, where a path alone would have looked fine
        let file = base.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try SharedFolder.check(file.appendingPathComponent("under", isDirectory: true)))
    }

    // MARK: The settings the widget needs

    func testTheWidgetGetsTheAppsSettings() throws {
        let app = try store("app")
        let widget = try store("widget")
        try fill(app)
        app.set("mock", forKey: "dataSource")
        app.set("metric", forKey: "distanceUnit")
        app.set("h24", forKey: "clockStyle")
        let handoff = WidgetHandoff(in: app)
        XCTAssertEqual(handoff, WidgetHandoff(networkAllowed: false, refreshIntervalSeconds: 120, dataSource: "mock", appLanguage: "es",
                                              distanceUnit: "metric", clockStyle: "h24"))
        // Through the file, as the widget gets it
        let dir = try folder("handoff")
        try JSONEncoder().encode(handoff).write(to: dir.appendingPathComponent(WidgetHandoff.fileName))
        let read = try XCTUnwrap(WidgetHandoff.read(in: dir))
        XCTAssertEqual(read, handoff)
        WidgetHandoff.adopt(read, into: widget)
        XCTAssertFalse(NetworkSwitch.isAllowed(in: widget), "network off in the app: the widget doesn't go online either")
        XCTAssertEqual(widget.double(forKey: "refreshIntervalSeconds"), 120)
        XCTAssertEqual(widget.string(forKey: "dataSource"), "mock")
        XCTAssertEqual(widget.string(forKey: "appLanguage"), "es")
        XCTAssertEqual(widget.string(forKey: "distanceUnit"), "metric")
        XCTAssertEqual(widget.string(forKey: "clockStyle"), "h24")
        XCTAssertEqual(WidgetHandoff(in: widget), handoff)
        XCTAssertNil(widget.object(forKey: "favoritePlaces"), "nothing else of the app's reaches the widget")
        XCTAssertNil(widget.object(forKey: "userPlace"))
        // The network turned back on, and a setting put back to its default (nothing saved): the widget follows both
        app.set(true, forKey: "networkAllowed")
        app.removeObject(forKey: "refreshIntervalSeconds")
        app.removeObject(forKey: "dataSource")
        WidgetHandoff.adopt(WidgetHandoff(in: app), into: widget)
        XCTAssertTrue(NetworkSwitch.isAllowed(in: widget))
        XCTAssertNil(widget.object(forKey: "refreshIntervalSeconds"))
        XCTAssertNil(widget.object(forKey: "dataSource"))
        XCTAssertEqual(widget.string(forKey: "appLanguage"), "es")
    }

    func testWithoutTheAppsSettingsTheWidgetStaysOffline() throws {
        let widget = try store("widget")
        XCTAssertTrue(NetworkSwitch.isAllowed(in: widget), "a store nothing was saved in reads as allowed")
        // No file yet
        let dir = try folder("handoff")
        XCTAssertNil(WidgetHandoff.read(in: dir))
        WidgetHandoff.adopt(nil, into: widget)
        XCTAssertFalse(NetworkSwitch.isAllowed(in: widget))
        // A file that can't be read, or one that doesn't say whether the network is allowed
        for text in ["not json", #"{"appLanguage":"es"}"#] {
            try Data(text.utf8).write(to: dir.appendingPathComponent(WidgetHandoff.fileName))
            XCTAssertNil(WidgetHandoff.read(in: dir), text)
        }
        // The other settings the widget took in before stay as they were
        widget.set("es", forKey: "appLanguage")
        WidgetHandoff.adopt(nil, into: widget)
        XCTAssertEqual(widget.string(forKey: "appLanguage"), "es")
        XCTAssertFalse(NetworkSwitch.isAllowed(in: widget))
        // Once the app has written its settings, the widget follows them again; a newer app's extra entries are ignored
        try Data(#"{"networkAllowed":true,"somethingNewer":1}"#.utf8).write(to: dir.appendingPathComponent(WidgetHandoff.fileName))
        WidgetHandoff.adopt(WidgetHandoff.read(in: dir), into: widget)
        XCTAssertTrue(NetworkSwitch.isAllowed(in: widget))
        XCTAssertNil(widget.object(forKey: "appLanguage"), "the app has none saved now")
    }
}
