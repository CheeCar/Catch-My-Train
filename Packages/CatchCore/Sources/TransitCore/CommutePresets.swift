import Foundation

/// A commute preset: a name, where walking starts from, and a transit mode. One click switches both.
/// Saved with the app's own settings, on this Mac. Don't rename the saved keys (id, name, fromCurrentLocation, place,
/// forgottenPlace, system): presets saved by older versions must still load (see CommutePresetsTests).
public struct CommutePreset: Codable, Hashable, Sendable, Identifiable {
    /// Made when the preset is created; never shown
    public var id: String
    public var name: String
    /// Walks from "My current location"
    public var fromCurrentLocation: Bool
    /// The favorite place it walks from, as it was when chosen. Nil with the current location, and once that place was forgotten
    public var place: UserPlace?
    /// The name of the favorite it walked from, kept when the place itself was forgotten, to say which one is missing
    public var forgottenPlace: String?
    /// The transit mode, by its saved name. Kept as text, so a mode this version doesn't know (saved by a later one) is still
    /// there after this version saves
    public var system: String

    /// `place` nil: from the current location
    public init(id: String = UUID().uuidString, name: String, place: UserPlace?, system: TransitSystem) {
        self.id = id
        self.name = name
        self.fromCurrentLocation = place == nil
        self.place = place
        self.forgottenPlace = nil
        self.system = system.mode.rawValue
    }

    /// The mode it switches to: one of the four in the title bar (a name saved before modes were merged reads as the merged
    /// one). Nil for a name this version doesn't know
    public var mode: TransitSystem? {
        guard let mode = TransitSystem(rawValue: system)?.mode, TransitSystem.modes.contains(mode) else { return nil }
        return mode
    }

    /// The name of the place it walks or walked from; nil with the current location
    public var placeName: String? { fromCurrentLocation ? nil : (place?.name ?? forgottenPlace) }

    /// Where it walks from, as Settings chooses it
    public enum Start: Hashable, Sendable {
        case currentLocation
        /// A favorite, as it was when chosen
        case favorite(UserPlace)
        /// The favorite it walked from was removed and no other was chosen since: only that one's name is kept (may be empty)
        case missing(String)
    }

    public var start: Start {
        if fromCurrentLocation { return .currentLocation }
        if let place { return .favorite(place) }
        return .missing(forgottenPlace ?? "")
    }

    /// The preset as Settings saves it after a change: the id stays, and so do the parts a later version saved (the store keeps
    /// them). The name is used as it is given (CommutePresets.cleanName makes it)
    public func with(name: String, start: Start, system: TransitSystem) -> CommutePreset {
        var changed = self
        changed.name = name
        switch start {
        case .currentLocation:
            changed.fromCurrentLocation = true
            changed.place = nil
            changed.forgottenPlace = nil
        case .favorite(let place):
            changed.fromCurrentLocation = false
            changed.place = place
            changed.forgottenPlace = nil
        case .missing(let name):
            changed.fromCurrentLocation = false
            changed.place = nil
            changed.forgottenPlace = name.isEmpty ? nil : name
        }
        changed.system = system.mode.rawValue
        return changed
    }

    public enum State: Equatable, Sendable {
        case ready
        /// Its place isn't among the favorites (removed, or not readable now): shown gray, not clickable, until a place is
        /// chosen for it again or the favorite is back
        case placeMissing
        /// It walks from the current location, and location is turned off in Settings ("Use my location"): shown gray until
        /// that is on again. Switching to it would only fall back to some chosen place
        case locationOff
        /// Its transit mode is one this version doesn't know: shown gray until a mode is chosen for it again
        case modeUnknown
    }

    /// Nothing is ever removed or changed here: a preset that can't be used says so and stays
    public func state(favorites: [UserPlace], locationAllowed: Bool = true) -> State {
        if !fromCurrentLocation, favorite(in: favorites) == nil { return .placeMissing }
        if fromCurrentLocation, !locationAllowed { return .locationOff }
        return mode == nil ? .modeUnknown : .ready
    }

    /// What one click switches to
    public struct Switch: Equatable, Sendable {
        /// The place to walk from; nil: the current location
        public var place: UserPlace?
        public var system: TransitSystem
    }

    /// Nil unless the preset is ready. The place is the favorite as it is saved now
    public func switched(favorites: [UserPlace], locationAllowed: Bool = true) -> Switch? {
        guard let mode else { return nil }
        if fromCurrentLocation { return locationAllowed ? Switch(place: nil, system: mode) : nil }
        guard let favorite = favorite(in: favorites) else { return nil }
        return Switch(place: favorite, system: mode)
    }

    private func favorite(in favorites: [UserPlace]) -> UserPlace? {
        guard let place else { return nil }
        return favorites.first { PlaceLists.sameFavorite($0, place) }
    }
}

/// The rules for the list of presets
public enum CommutePresets {
    /// The most presets there can be: they sit in one row under the starting place
    public static let limit = 4
    /// The longest name, in characters
    public static let nameLimit = 24

    /// A name as it is saved: no spaces around it, on one line, no longer than `nameLimit`. Nil when nothing is left (a preset
    /// needs a name)
    public static func cleanName(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let name = String(words.joined(separator: " ").prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    public static func canAdd(to presets: [CommutePreset]) -> Bool { presets.count < limit }

    /// The ones that get a button. More than `limit` can be saved (by a later version that allows more): they stay saved
    public static func shown(_ presets: [CommutePreset]) -> [CommutePreset] { Array(presets.prefix(limit)) }

    /// A favorite was removed: the presets walking from it forget where it is and keep only its name, so the place is gone
    /// from this Mac as removing it asks. They stay, gray, until a place is chosen for them again.
    public static func forgetting(_ removed: UserPlace, in presets: [CommutePreset]) -> [CommutePreset] {
        presets.map { preset in
            guard let place = preset.place, PlaceLists.sameFavorite(place, removed) else { return preset }
            var changed = preset
            changed.place = nil
            changed.forgottenPlace = place.name
            return changed
        }
    }

    /// The presets walking from this favorite, by id: the ones `forgetting` changes when it is removed
    public static func ids(startingFrom favorite: UserPlace, in presets: [CommutePreset]) -> Set<String> {
        Set(presets.filter { preset in preset.place.map { PlaceLists.sameFavorite($0, favorite) } ?? false }.map(\.id))
    }

    /// Undo put a removed favorite back: the presets that forgot it when it was removed (`ids`) walk from it again, as before.
    /// Not one that walks from somewhere else by now (another place or the current location was chosen for it since)
    public static func remembering(_ favorite: UserPlace, ids: Set<String>, in presets: [CommutePreset]) -> [CommutePreset] {
        presets.map { preset in
            guard ids.contains(preset.id), !preset.fromCurrentLocation, preset.place == nil else { return preset }
            var changed = preset
            changed.place = favorite
            changed.forgottenPlace = nil
            return changed
        }
    }

    /// A favorite was added: the presets that forgot a place of that very name (taken out, and Undo missed) walk from it again.
    /// The name is all they kept of it, so one of another name never takes its place
    public static func reconnecting(_ added: UserPlace, in presets: [CommutePreset]) -> [CommutePreset] {
        presets.map { preset in
            guard !preset.fromCurrentLocation, preset.place == nil, preset.forgottenPlace == added.name else { return preset }
            var changed = preset
            changed.place = added
            changed.forgottenPlace = nil
            return changed
        }
    }

    /// The preset that is on now (its button is marked): the first one with this starting place and this mode. Nil when the
    /// place or the mode was changed by hand to something no preset has
    public static func active(_ presets: [CommutePreset], fromCurrentLocation: Bool, place: UserPlace?,
                              system: TransitSystem) -> CommutePreset? {
        presets.first { preset in
            guard preset.mode == system.mode, preset.fromCurrentLocation == fromCurrentLocation else { return false }
            if fromCurrentLocation { return true }
            guard let place, let own = preset.place else { return false }
            return PlaceLists.sameFavorite(own, place)
        }
    }

    /// One place up (-1) or down (+1) in the order; unchanged at either end or for an id that isn't there
    public static func moved(_ presets: [CommutePreset], id: String, by offset: Int) -> [CommutePreset] {
        guard let from = presets.firstIndex(where: { $0.id == id }) else { return presets }
        let to = from + offset
        guard presets.indices.contains(to), to != from else { return presets }
        var list = presets
        list.insert(list.remove(at: from), at: to)
        return list
    }
}

/// The presets as saved in a UserDefaults (the app's own settings in the app, a temporary one in tests).
///
/// Nothing saved is lost: a saved preset this version can't read (saved by a later version, or damaged) stays in the saved
/// list as it is, after the ones that can be read, and so do the parts of a preset this version doesn't know. Saved data that
/// isn't a list at all is kept once as `<key>.unreadable` before it is written over. With nothing saved (every version before
/// presets) there are no presets.
public struct CommutePresetStore {
    public static let key = "commutePresets"
    static let copyKey = key + ".unreadable"
    /// The parts of a saved preset this version writes; any other part is a later version's and is left as it is
    static let ownKeys: Set<String> = ["id", "name", "fromCurrentLocation", "place", "forgottenPlace", "system"]

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The presets this version can read, in their order
    public var presets: [CommutePreset] {
        get { read().presets }
        nonmutating set { write(newValue) }
    }

    /// How many saved presets this version can't read. They are kept
    public var unreadableCount: Int { read().others.count }

    /// Saved data that isn't a list of presets at all is there (or was, and its copy is kept)
    public var hasUnreadableCopy: Bool {
        defaults.data(forKey: Self.copyKey) != nil || (defaults.data(forKey: Self.key) != nil && read().items == nil)
    }

    private struct Saved {
        /// The saved list as it is; nil when what is saved isn't a list
        var items: [Any]?
        var presets: [CommutePreset] = []
        /// The saved form of each preset that could be read, by its id
        var forms: [String: [String: Any]] = [:]
        /// The items that couldn't be read, as they are
        var others: [Any] = []
    }

    private func read() -> Saved {
        guard let data = defaults.data(forKey: Self.key) else { return Saved(items: []) }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return Saved(items: nil) }
        var saved = Saved(items: items)
        for item in items {
            if let form = item as? [String: Any], let one = try? JSONSerialization.data(withJSONObject: form),
               let preset = try? JSONDecoder().decode(CommutePreset.self, from: one), saved.forms[preset.id] == nil {
                saved.presets.append(preset)
                saved.forms[preset.id] = form
            } else {
                saved.others.append(item)
            }
        }
        return saved
    }

    private func write(_ list: [CommutePreset]) {
        let saved = read()
        if saved.items == nil, defaults.data(forKey: Self.copyKey) == nil, let data = defaults.data(forKey: Self.key) {
            defaults.set(data, forKey: Self.copyKey)
        }
        var items: [Any] = []
        for preset in list {
            guard let data = try? JSONEncoder().encode(preset),
                  let form = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var kept = (saved.forms[preset.id] ?? [:]).filter { !Self.ownKeys.contains($0.key) }
            kept.merge(form) { _, new in new }
            items.append(kept)
        }
        items += saved.others
        if items.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
