import XCTest
@testable import TransitCore

/// Commute presets: a name, a starting place and a transit mode, switched with one click.
final class CommutePresetsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: CommutePresetStore!

    private let home = UserPlace(name: "Grand Central", coordinate: Coordinate(latitude: 40.7527, longitude: -73.9772))
    private let office = UserPlace(name: "Hoboken Terminal", coordinate: Coordinate(latitude: 40.7359, longitude: -74.0291))
    private let gym = UserPlace(name: "Stamford Station", coordinate: Coordinate(latitude: 41.0466, longitude: -73.5419))

    override func setUpWithError() throws {
        suite = "CatchCoreTests.presets.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = CommutePresetStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func saved() throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: CommutePresetStore.key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: One preset

    func testAPresetSwitchesThePlaceAndTheMode() {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        XCTAssertFalse(toWork.fromCurrentLocation)
        XCTAssertEqual(toWork.placeName, "Grand Central")
        XCTAssertEqual(toWork.mode, .subway)
        XCTAssertEqual(toWork.state(favorites: [office, home]), .ready)
        XCTAssertEqual(toWork.switched(favorites: [office, home]), .init(place: home, system: .subway))

        let fromHere = CommutePreset(name: "From here", place: nil, system: .ferry)
        XCTAssertTrue(fromHere.fromCurrentLocation)
        XCTAssertNil(fromHere.placeName)
        // The current location needs no favorite
        XCTAssertEqual(fromHere.state(favorites: []), .ready)
        XCTAssertEqual(fromHere.switched(favorites: []), .init(place: nil, system: .ferry))
        // Each new one has its own id
        XCTAssertNotEqual(toWork.id, fromHere.id)
        XCTAssertFalse(toWork.id.isEmpty)
    }

    /// The favorite is the one saved now: the same name within 30 m, as favorites are told apart everywhere else
    func testThePlaceIsTheFavoriteAsItIsNow() {
        let preset = CommutePreset(name: "To work", place: home, system: .train)
        let nudged = UserPlace(name: "Grand Central", coordinate: Coordinate(latitude: 40.75275, longitude: -73.97722))
        XCTAssertEqual(preset.switched(favorites: [nudged])?.place, nudged)
        // Another name on the same spot, or the same name somewhere else, is another favorite
        let renamed = UserPlace(name: "Station", coordinate: home.coordinate)
        let elsewhere = UserPlace(name: "Grand Central", coordinate: gym.coordinate)
        XCTAssertEqual(preset.state(favorites: [renamed, elsewhere]), .placeMissing)
    }

    /// "Use my location" turned off in Settings: a preset from the current location can't be switched to, and says so
    func testFromTheCurrentLocationNeedsLocationOn() {
        let here = CommutePreset(name: "Here", place: nil, system: .bus)
        XCTAssertEqual(here.state(favorites: [], locationAllowed: false), .locationOff)
        XCTAssertNil(here.switched(favorites: [], locationAllowed: false))
        XCTAssertEqual(here.state(favorites: [], locationAllowed: true), .ready)
        XCTAssertEqual(here.switched(favorites: [], locationAllowed: true), .init(place: nil, system: .bus))
        // One from a favorite doesn't need it
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        XCTAssertEqual(toWork.state(favorites: [home], locationAllowed: false), .ready)
        XCTAssertEqual(toWork.switched(favorites: [home], locationAllowed: false), .init(place: home, system: .subway))
        // Said before a mode that isn't known
        var both = here
        both.system = "hovercraft"
        XCTAssertEqual(both.state(favorites: [], locationAllowed: false), .locationOff)
    }

    func testAPresetWhoseFavoriteIsGoneStaysAndSaysSo() {
        let preset = CommutePreset(name: "To work", place: home, system: .subway)
        XCTAssertEqual(preset.state(favorites: [office]), .placeMissing)
        XCTAssertNil(preset.switched(favorites: [office]))
        XCTAssertEqual(preset.placeName, "Grand Central", "It still says which place it was")
        // Nothing was changed in it: with the favorite back it works again
        XCTAssertEqual(preset.state(favorites: [office, home]), .ready)
    }

    func testRemovingAFavoriteForgetsWhereItIs() throws {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        let alsoHome = CommutePreset(name: "Weekend", place: home, system: .ferry)
        let back = CommutePreset(name: "Back", place: office, system: .train)
        let here = CommutePreset(name: "Here", place: nil, system: .bus)
        let after = CommutePresets.forgetting(home, in: [toWork, back, alsoHome, here])
        XCTAssertEqual(after.map(\.id), [toWork.id, back.id, alsoHome.id, here.id], "None is removed and the order stays")
        XCTAssertEqual(after.map(\.name), ["To work", "Back", "Weekend", "Here"])
        XCTAssertNil(after[0].place)
        XCTAssertNil(after[2].place)
        XCTAssertEqual(after[0].placeName, "Grand Central")
        XCTAssertEqual(after[0].state(favorites: [home, office]), .placeMissing, "Even with a favorite of that name back: it was forgotten")
        XCTAssertNil(after[0].switched(favorites: [home, office]))
        XCTAssertEqual(after[1], back)
        XCTAssertEqual(after[3], here)
        // What is saved no longer holds where the place was
        store.presets = after
        let first = try XCTUnwrap(saved().first)
        XCTAssertNil(first["place"])
        XCTAssertEqual(first["forgottenPlace"] as? String, "Grand Central")
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: CommutePresetStore.key)), as: UTF8.self).contains("40.7527"))
    }

    /// Undo, after a favorite was taken out: the presets that forgot it walk from it again, and only those
    func testUndoGivesTheForgottenPresetsTheirPlaceBack() {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        let back = CommutePreset(name: "Back", place: office, system: .train)
        let here = CommutePreset(name: "Here", place: nil, system: .bus)
        let before = [toWork, back, here]
        let ids = CommutePresets.ids(startingFrom: home, in: before)
        XCTAssertEqual(ids, [toWork.id])
        let forgotten = CommutePresets.forgetting(home, in: before)
        XCTAssertEqual(CommutePresets.remembering(home, ids: ids, in: forgotten), before)
        // Another preset that has no place isn't given this one
        let gymAlone = CommutePresets.forgetting(gym, in: [CommutePreset(name: "Gym", place: gym, system: .ferry)])
        XCTAssertNil(CommutePresets.remembering(home, ids: ids, in: gymAlone)[0].place)
        XCTAssertEqual(CommutePresets.remembering(home, ids: ids, in: gymAlone)[0].placeName, "Stamford Station")
    }

    /// Undo missed: a favorite of the same name added again gives the presets that forgot it their place back, and only those
    func testAFavoriteOfTheSameNameAddedAgainIsTheirsAgain() {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        let back = CommutePreset(name: "Back", place: office, system: .train)
        let here = CommutePreset(name: "Here", place: nil, system: .bus)
        let forgotten = CommutePresets.forgetting(home, in: [toWork, back, here])
        let again = CommutePresets.reconnecting(home, in: forgotten)
        XCTAssertEqual(again, [toWork, back, here])
        XCTAssertEqual(again[0].state(favorites: [home]), .ready)
        // Not by a favorite of another name, wherever it is
        XCTAssertEqual(CommutePresets.reconnecting(gym, in: forgotten), forgotten)
        let moved = UserPlace(name: home.name, coordinate: gym.coordinate)
        XCTAssertEqual(CommutePresets.reconnecting(moved, in: forgotten)[0].place, moved, "The name is all it kept")
        // One that walks from somewhere else by now, or from the current location, keeps that
        let elsewhere = forgotten[0].with(name: "To work", start: .favorite(office), system: .subway)
        XCTAssertEqual(CommutePresets.reconnecting(home, in: [elsewhere, here]), [elsewhere, here])
    }

    /// One that walks from somewhere else by now keeps that
    func testUndoLeavesAPresetChangedSince() {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        let ids = CommutePresets.ids(startingFrom: home, in: [toWork])
        let forgotten = CommutePresets.forgetting(home, in: [toWork])[0]
        let elsewhere = forgotten.with(name: "To work", start: .favorite(office), system: .subway)
        let here = forgotten.with(name: "To work", start: .currentLocation, system: .subway)
        XCTAssertEqual(CommutePresets.remembering(home, ids: ids, in: [elsewhere]), [elsewhere])
        XCTAssertEqual(CommutePresets.remembering(home, ids: ids, in: [here]), [here])
    }

    /// Settings changes the name, the starting place and the mode; the id stays
    func testChangingAPresetKeepsItsId() {
        let preset = CommutePreset(name: "To work", place: home, system: .subway)
        XCTAssertEqual(preset.start, .favorite(home))
        let changed = preset.with(name: "Gym", start: .favorite(gym), system: .ferry)
        XCTAssertEqual(changed.id, preset.id)
        XCTAssertEqual(changed.name, "Gym")
        XCTAssertEqual(changed.start, .favorite(gym))
        XCTAssertEqual(changed.mode, .ferry)
        let here = changed.with(name: "Here", start: .currentLocation, system: .path)
        XCTAssertTrue(here.fromCurrentLocation)
        XCTAssertNil(here.place)
        XCTAssertEqual(here.start, .currentLocation)
        XCTAssertEqual(here.system, "subway", "Saved as the mode it shows as")
        // A missing place stays missing, with its name, when only the name or the mode is changed
        let forgotten = CommutePresets.forgetting(home, in: [preset])[0]
        XCTAssertEqual(forgotten.start, .missing("Grand Central"))
        let renamed = forgotten.with(name: "Work", start: forgotten.start, system: .bus)
        XCTAssertEqual(renamed.start, .missing("Grand Central"))
        XCTAssertEqual(renamed.state(favorites: [home]), .placeMissing)
        // Choosing a place again drops the name kept of the missing one
        XCTAssertNil(forgotten.with(name: "Work", start: .favorite(office), system: .bus).forgottenPlace)
        XCTAssertNil(forgotten.with(name: "Work", start: .missing(""), system: .bus).forgottenPlace)
    }

    func testTheModeIsOneOfTheFourOrUnknown() {
        var preset = CommutePreset(name: "A", place: nil, system: .train)
        XCTAssertEqual(preset.system, "train")
        // Names saved before the modes were merged read as the merged ones, as the mode setting itself does
        for (name, mode) in [("subway", TransitSystem.subway), ("bus", .bus), ("train", .train), ("ferry", .ferry), ("njTrain", .train),
                             ("njFerry", .ferry), ("njBus", .bus), ("path", .subway), ("lightRail", .subway)] {
            preset.system = name
            XCTAssertEqual(preset.mode, mode, name)
            XCTAssertEqual(preset.state(favorites: []), .ready, name)
        }
        // Made from a mode that isn't in the title bar: saved as the one it shows as
        XCTAssertEqual(CommutePreset(name: "B", place: nil, system: .path).system, "subway")
        // A mode only a later version knows: gray, not a crash, not another mode instead
        preset.system = "hovercraft"
        XCTAssertNil(preset.mode)
        XCTAssertEqual(preset.state(favorites: []), .modeUnknown)
        XCTAssertNil(preset.switched(favorites: []))
        // A missing place is said first: it is the one that needs choosing again either way
        var both = CommutePreset(name: "C", place: home, system: .bus)
        both.system = "hovercraft"
        XCTAssertEqual(both.state(favorites: []), .placeMissing)
        XCTAssertEqual(both.state(favorites: [home]), .modeUnknown)
    }

    // MARK: The list

    func testNames() {
        XCTAssertEqual(CommutePresets.cleanName("  To work \n"), "To work")
        XCTAssertEqual(CommutePresets.cleanName("To\nwork\t today"), "To work today")
        XCTAssertNil(CommutePresets.cleanName(""))
        XCTAssertNil(CommutePresets.cleanName("  \n "))
        let long = String(repeating: "abcde ", count: 10)
        let cut = CommutePresets.cleanName(long)
        XCTAssertEqual(cut, "abcde abcde abcde abcde")
        XCTAssertLessThanOrEqual(cut?.count ?? 0, CommutePresets.nameLimit)
        // Counted in characters as people see them, not in bytes
        XCTAssertEqual(CommutePresets.cleanName(String(repeating: "\u{5BB6}", count: 30))?.count, CommutePresets.nameLimit)
        XCTAssertEqual(CommutePresets.cleanName(String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 30))?.count,
                       CommutePresets.nameLimit)
        // Two presets may have the same name: that is theirs to choose
        XCTAssertEqual(CommutePresets.cleanName("Home"), CommutePresets.cleanName(" Home "))
    }

    func testAtMostFourGetAButton() {
        var list: [CommutePreset] = []
        for i in 1...CommutePresets.limit {
            XCTAssertTrue(CommutePresets.canAdd(to: list))
            list.append(CommutePreset(name: "P\(i)", place: nil, system: .subway))
        }
        XCTAssertEqual(CommutePresets.limit, 4)
        XCTAssertFalse(CommutePresets.canAdd(to: list))
        // One more saved by a version that allows more: it gets no button here, and it isn't dropped
        list.append(CommutePreset(name: "P5", place: nil, system: .bus))
        XCTAssertEqual(CommutePresets.shown(list).map(\.name), ["P1", "P2", "P3", "P4"])
        store.presets = list
        XCTAssertEqual(store.presets.map(\.name), ["P1", "P2", "P3", "P4", "P5"])
    }

    func testWhichPresetIsOn() {
        let toWork = CommutePreset(name: "To work", place: home, system: .subway)
        let back = CommutePreset(name: "Back", place: office, system: .train)
        let here = CommutePreset(name: "Here", place: nil, system: .bus)
        let list = [toWork, back, here]
        XCTAssertEqual(CommutePresets.active(list, fromCurrentLocation: false, place: home, system: .subway)?.id, toWork.id)
        XCTAssertEqual(CommutePresets.active(list, fromCurrentLocation: false, place: office, system: .train)?.id, back.id)
        XCTAssertEqual(CommutePresets.active(list, fromCurrentLocation: true, place: home, system: .bus)?.id, here.id)
        // The mode or the place changed by hand to something no preset has: none is on
        XCTAssertNil(CommutePresets.active(list, fromCurrentLocation: false, place: home, system: .train))
        XCTAssertNil(CommutePresets.active(list, fromCurrentLocation: false, place: gym, system: .subway))
        XCTAssertNil(CommutePresets.active(list, fromCurrentLocation: true, place: home, system: .subway))
        XCTAssertNil(CommutePresets.active(list, fromCurrentLocation: false, place: nil, system: .subway))
        XCTAssertNil(CommutePresets.active([], fromCurrentLocation: true, place: nil, system: .subway))
        // Two the same: the first
        let twin = CommutePreset(name: "Twin", place: home, system: .subway)
        XCTAssertEqual(CommutePresets.active([twin, toWork], fromCurrentLocation: false, place: home, system: .subway)?.id, twin.id)
        // One whose place was forgotten is never on
        let forgotten = CommutePresets.forgetting(home, in: [toWork])
        XCTAssertNil(CommutePresets.active(forgotten, fromCurrentLocation: false, place: home, system: .subway))
    }

    func testMovingOneUpOrDown() {
        let list = ["A", "B", "C"].map { CommutePreset(id: $0, name: $0, place: nil, system: .subway) }
        XCTAssertEqual(CommutePresets.moved(list, id: "C", by: -1).map(\.id), ["A", "C", "B"])
        XCTAssertEqual(CommutePresets.moved(list, id: "A", by: 1).map(\.id), ["B", "A", "C"])
        XCTAssertEqual(CommutePresets.moved(list, id: "A", by: -1).map(\.id), ["A", "B", "C"])
        XCTAssertEqual(CommutePresets.moved(list, id: "C", by: 1).map(\.id), ["A", "B", "C"])
        XCTAssertEqual(CommutePresets.moved(list, id: "X", by: 1).map(\.id), ["A", "B", "C"])
        XCTAssertEqual(CommutePresets.moved(list, id: "B", by: 0).map(\.id), ["A", "B", "C"])
    }

    // MARK: Saved

    /// Every version before presets saved nothing under this key: no presets, and nothing is written by looking
    func testNothingSavedIsNoPresets() {
        XCTAssertEqual(store.presets, [])
        XCTAssertEqual(store.unreadableCount, 0)
        XCTAssertFalse(store.hasUnreadableCopy)
        XCTAssertNil(defaults.object(forKey: CommutePresetStore.key))
    }

    func testPresetsAreSavedAndReadBack() throws {
        let toWork = CommutePreset(id: "one", name: "To work", place: home, system: .subway)
        let here = CommutePreset(id: "two", name: "Here", place: nil, system: .ferry)
        store.presets = [toWork, here]
        XCTAssertEqual(CommutePresetStore(defaults: defaults).presets, [toWork, here])
        // The saved names of the parts: renaming one would lose presets people made
        XCTAssertEqual(CommutePresetStore.key, "commutePresets")
        let items = try saved()
        XCTAssertEqual(Set(items[0].keys), ["id", "name", "fromCurrentLocation", "place", "system"])
        XCTAssertEqual(Set(items[1].keys), ["id", "name", "fromCurrentLocation", "system"])
        XCTAssertEqual(items[0]["system"] as? String, "subway")
        XCTAssertEqual(items[1]["fromCurrentLocation"] as? Bool, true)
        XCTAssertEqual(Set(try XCTUnwrap(items[0]["place"] as? [String: Any]).keys), ["name", "latitude", "longitude"])
        XCTAssertEqual(CommutePresetStore.ownKeys, ["id", "name", "fromCurrentLocation", "place", "forgottenPlace", "system"])
        // The last one deleted: nothing is left saved
        store.presets = []
        XCTAssertNil(defaults.object(forKey: CommutePresetStore.key))
    }

    /// The format the first version with presets writes. Every later version must still read this
    func testTheSavedFormatIsRead() {
        let json = #"""
        [{"fromCurrentLocation":false,"id":"one","name":"To work","place":{"latitude":40.7527,"longitude":-73.9772,"name":"Grand Central"},"system":"subway"},
         {"fromCurrentLocation":true,"id":"two","name":"Here","system":"ferry"},
         {"forgottenPlace":"Old Office","fromCurrentLocation":false,"id":"three","name":"Back","system":"train"}]
        """#
        defaults.set(Data(json.utf8), forKey: CommutePresetStore.key)
        let presets = store.presets
        XCTAssertEqual(presets.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(presets[0].place, home)
        XCTAssertEqual(presets[1].switched(favorites: []), .init(place: nil, system: .ferry))
        XCTAssertEqual(presets[2].placeName, "Old Office")
        XCTAssertEqual(presets[2].state(favorites: [home]), .placeMissing)
        XCTAssertEqual(store.unreadableCount, 0)
    }

    /// A preset this version can't read (a later version's, or damaged) stays saved as it is when the others are changed
    func testAPresetThatCantBeReadIsKept() throws {
        let json = #"""
        [{"fromCurrentLocation":true,"id":"one","name":"Here","system":"bus"},
         {"id":"later","name":"Newer kind","start":{"station":"X1"}},
         "not a preset",
         {"fromCurrentLocation":false,"id":"two","name":"To work","place":{"latitude":40.7527,"longitude":-73.9772,"name":"Grand Central"},"system":"subway"}]
        """#
        defaults.set(Data(json.utf8), forKey: CommutePresetStore.key)
        XCTAssertEqual(store.presets.map(\.id), ["one", "two"])
        XCTAssertEqual(store.unreadableCount, 2)
        XCTAssertFalse(store.hasUnreadableCopy, "It is a list: nothing needs a copy, the items stay where they are saved")
        // Change the readable ones: rename one, delete the other
        var list = store.presets
        list[0].name = "From here"
        list.removeLast()
        store.presets = list
        XCTAssertEqual(store.presets.map(\.name), ["From here"])
        XCTAssertEqual(store.unreadableCount, 2)
        let data = try XCTUnwrap(defaults.data(forKey: CommutePresetStore.key))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual((items[1] as? [String: Any])?["name"] as? String, "Newer kind")
        XCTAssertEqual(((items[1] as? [String: Any])?["start"] as? [String: Any])?["station"] as? String, "X1")
        XCTAssertEqual(items[2] as? String, "not a preset")
        // Every readable one deleted: the others are still saved
        store.presets = []
        XCTAssertEqual(store.unreadableCount, 2)
        XCTAssertNotNil(defaults.data(forKey: CommutePresetStore.key))
    }

    /// A later version may save more about a preset. Changing it here keeps what this version doesn't know
    func testPartsThisVersionDoesntKnowAreKept() throws {
        let json = #"[{"fromCurrentLocation":true,"id":"one","name":"Here","system":"bus","shortcut":"1","station":{"id":"A12"}}]"#
        defaults.set(Data(json.utf8), forKey: CommutePresetStore.key)
        var list = store.presets
        XCTAssertEqual(list.map(\.name), ["Here"])
        list[0].name = "Bus from here"
        list[0].fromCurrentLocation = false
        list[0].place = home
        list.append(CommutePreset(id: "two", name: "New", place: nil, system: .train))
        store.presets = list
        let items = try saved()
        XCTAssertEqual(items[0]["name"] as? String, "Bus from here")
        XCTAssertEqual(items[0]["shortcut"] as? String, "1")
        XCTAssertEqual((items[0]["station"] as? [String: Any])?["id"] as? String, "A12")
        XCTAssertNotNil(items[0]["place"])
        XCTAssertNil(items[1]["shortcut"])
        // A part of this version's own that is no longer set goes: the place, once forgotten
        store.presets = CommutePresets.forgetting(home, in: store.presets)
        let after = try saved()
        XCTAssertNil(after[0]["place"])
        XCTAssertEqual(after[0]["forgottenPlace"] as? String, "Grand Central")
        XCTAssertEqual(after[0]["shortcut"] as? String, "1")
    }

    func testTwoSavedWithTheSameIdAreNotMixedUp() throws {
        let json = #"""
        [{"fromCurrentLocation":true,"id":"same","name":"First","system":"bus"},
         {"fromCurrentLocation":true,"id":"same","name":"Second","system":"train"}]
        """#
        defaults.set(Data(json.utf8), forKey: CommutePresetStore.key)
        XCTAssertEqual(store.presets.map(\.name), ["First"])
        XCTAssertEqual(store.unreadableCount, 1)
        store.presets = store.presets
        XCTAssertEqual(try saved().map { $0["name"] as? String }, ["First", "Second"])
    }

    /// Saved data that isn't a list at all: no presets, and one copy of it is kept before anything is written over it
    func testDataThatIsNotAListIsKeptOnce() throws {
        defaults.set(Data(#"{"presets":"something else"}"#.utf8), forKey: CommutePresetStore.key)
        XCTAssertEqual(store.presets, [])
        XCTAssertEqual(store.unreadableCount, 0)
        XCTAssertTrue(store.hasUnreadableCopy)
        XCTAssertNil(defaults.data(forKey: CommutePresetStore.copyKey), "Looking writes nothing")
        store.presets = [CommutePreset(id: "one", name: "Here", place: nil, system: .bus)]
        XCTAssertEqual(store.presets.map(\.id), ["one"])
        let copy = try XCTUnwrap(defaults.data(forKey: CommutePresetStore.copyKey))
        XCTAssertEqual(String(decoding: copy, as: UTF8.self), #"{"presets":"something else"}"#)
        XCTAssertTrue(store.hasUnreadableCopy)
        // The first copy is the one kept
        defaults.set(Data("again not a list".utf8), forKey: CommutePresetStore.key)
        store.presets = []
        XCTAssertEqual(String(decoding: try XCTUnwrap(defaults.data(forKey: CommutePresetStore.copyKey)), as: UTF8.self),
                       #"{"presets":"something else"}"#)
    }
}
