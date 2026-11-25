import Foundation

/// The user's favorite and recent places as saved in a UserDefaults (the app's own settings in the app, a temporary one in tests).
/// The keys and the format are the ones every earlier version wrote: don't change them (see SavedDataTests).
///
/// Nothing the user saved is lost without a copy: before a list is written over, saved data with items this version can't read
/// (the whole list or some items) is kept once as `<key>.unreadable`. A place picker can then offer to restore what can be read
/// again (`pendingRestore`, `restore`). The copy is deleted after a restore and when the recent places are cleared.
public struct PlaceLists {
    public enum Kind: CaseIterable, Sendable {
        case favorites, recents

        public var key: String {
            switch self {
            case .favorites: return "favoritePlaces"
            case .recents: return "recentPlaces"
            }
        }
    }

    public static let recentLimit = 10
    public static let maxFavorites = 50

    /// Places closer than this are the same place
    public static let sameDistanceMeters = 30.0

    /// Plan a Trip's star popover lists this many favorites (the first in the user's order) and recent places (the newest), so it
    /// needs no scrolling; all of them are in the place picker
    public static let quickFavorites = 6
    public static let quickRecents = 4
    /// The most saved places suggested while typing in Plan a Trip's place field
    public static let typedLimit = 5

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: The two lists

    public var favorites: [UserPlace] {
        get { read(.favorites) }
        nonmutating set { write(newValue, to: .favorites) }
    }

    /// The most recently chosen places, newest first, at most `recentLimit`
    public var recents: [UserPlace] {
        get { Array(read(.recents).prefix(Self.recentLimit)) }
        nonmutating set { write(Array(newValue.prefix(Self.recentLimit)), to: .recents) }
    }

    public func list(_ kind: Kind) -> [UserPlace] {
        kind == .favorites ? favorites : recents
    }

    private func read(_ kind: Kind) -> [UserPlace] {
        guard let data = defaults.data(forKey: kind.key) else { return [] }
        return SavedData.list(UserPlace.self, from: data) ?? []
    }

    private func write(_ list: [UserPlace], to kind: Kind) {
        keepUnreadableCopy(of: kind)
        if list.isEmpty {
            defaults.removeObject(forKey: kind.key)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: kind.key)
        }
    }

    // MARK: Same place

    /// Two favorites are the same place when they have the same name and are within 30 m: two names for one spot are two favorites
    public static func sameFavorite(_ a: UserPlace, _ b: UserPlace) -> Bool {
        a.name == b.name && WalkEstimator.distanceMeters(a.coordinate, b.coordinate) <= sameDistanceMeters
    }

    /// Two recent places are the same place when they're within 30 m, whatever their names: one spot is listed once
    public static func sameRecent(_ a: UserPlace, _ b: UserPlace) -> Bool {
        WalkEstimator.distanceMeters(a.coordinate, b.coordinate) <= sameDistanceMeters
    }

    public static func same(_ kind: Kind) -> (UserPlace, UserPlace) -> Bool {
        kind == .favorites ? sameFavorite : sameRecent
    }

    // MARK: The short lists

    /// What Plan a Trip's star popover lists
    public struct QuickPick: Equatable, Sendable {
        public var favorites: [UserPlace]
        public var recents: [UserPlace]
        /// Some favorites or recent places aren't listed (more than quickFavorites or quickRecents): the popover then says how many
        /// it lists and how to change the order. It doesn't say how many there are
        public var hasMore: Bool
    }

    public static func quickPick(favorites: [UserPlace], recents: [UserPlace]) -> QuickPick {
        QuickPick(favorites: Array(favorites.prefix(quickFavorites)), recents: Array(recents.prefix(quickRecents)),
                  hasMore: favorites.count > quickFavorites || recents.count > quickRecents)
    }

    /// The saved places whose name has the typed text in it (capitals, accents and character width don't matter): favorites in the
    /// user's order, then recent places that aren't one of those favorites (the same spot, see sameRecent), at most `limit` in all
    public static func matching(_ text: String, favorites: [UserPlace], recents: [UserPlace],
                                limit: Int = typedLimit) -> (favorites: [UserPlace], recents: [UserPlace]) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, limit > 0 else { return ([], []) }
        func matches(_ p: UserPlace) -> Bool {
            p.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
        let found = Array(favorites.filter(matches).prefix(limit))
        var rest: [UserPlace] = []
        for p in recents where matches(p) {
            guard found.count + rest.count < limit else { break }
            if found.contains(where: { sameRecent($0, p) }) || rest.contains(where: { sameRecent($0, p) }) { continue }
            rest.append(p)
        }
        return (found, rest)
    }

    /// The favorites whose name has every word typed in it, anywhere and in any order (capitals, accents and character width
    /// don't matter), in the user's order: the search of a commute preset's list of places to walk from. All of them when
    /// nothing is typed
    public static func search(_ text: String, in places: [UserPlace]) -> [UserPlace] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return places }
        return places.filter { place in
            words.allSatisfy { place.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
    }

    // MARK: Changing the lists

    public func isFavorite(_ place: UserPlace) -> Bool {
        favorites.contains { Self.sameFavorite($0, place) }
    }

    /// Favorite / unfavorite. When the favorites are full nothing is added and false is returned.
    @discardableResult
    public func toggleFavorite(_ place: UserPlace) -> Bool {
        var list = favorites
        if list.contains(where: { Self.sameFavorite($0, place) }) {
            list.removeAll { Self.sameFavorite($0, place) }
        } else {
            guard list.count < Self.maxFavorites else { return false }
            list.append(place)
        }
        favorites = list
        return true
    }

    /// A new order for the favorites. Only the order changes: nothing is added or removed, and a saved favorite that `order` leaves
    /// out stays, at the end.
    public func reorderFavorites(_ order: [UserPlace]) {
        let saved = favorites
        var rest = saved
        var list: [UserPlace] = []
        for place in order {
            if let i = rest.firstIndex(where: { Self.sameFavorite($0, place) }) { list.append(rest.remove(at: i)) }
        }
        list += rest
        if list != saved { favorites = list }
    }

    /// A just-chosen place goes first; an older entry for the same spot goes
    public func remember(_ place: UserPlace) {
        var list = recents.filter { !Self.sameRecent($0, place) }
        list.insert(place, at: 0)
        recents = list
    }

    /// Clears the recent places, and the copy of any that couldn't be read
    public func clearRecents() {
        recents = []
        deleteCopy(of: .recents)
    }

    // MARK: Places that couldn't be read

    private static func copyKey(_ kind: Kind) -> String { kind.key + ".unreadable" }
    /// Which items of the copy couldn't be read when it was made; missing when the whole list couldn't be read
    private static func lostKey(_ kind: Kind) -> String { kind.key + ".unreadable.lost" }
    /// How many places could be restored when the user was last asked; missing until then
    private static func askedKey(_ kind: Kind) -> String { kind.key + ".unreadable.asked" }
    /// Set when some places didn't fit as they were put back (the list was full), cleared when the user says no: then they are
    /// asked about again once the list has room. Saying no and having no room are told apart
    private static func fullKey(_ kind: Kind) -> String { kind.key + ".unreadable.full" }

    private static func limit(_ kind: Kind) -> Int { kind == .favorites ? maxFavorites : recentLimit }

    public func hasCopy(of kind: Kind) -> Bool {
        defaults.data(forKey: Self.copyKey(kind)) != nil
    }

    /// Before saved data with items that can't be read is written over, keep it once as it is (the first copy is kept: it holds what
    /// was lost first). Also called on its own, so a copy is there before the user is asked.
    public func keepUnreadableCopy(of kind: Kind) {
        guard !hasCopy(of: kind), let data = defaults.data(forKey: kind.key) else { return }
        if let entries = SavedData.entries(UserPlace.self, from: data) {
            let lost = entries.indices.filter { entries[$0] == nil }
            guard !lost.isEmpty else { return }
            defaults.set(lost, forKey: Self.lostKey(kind))
        } else {
            defaults.removeObject(forKey: Self.lostKey(kind))
        }
        defaults.removeObject(forKey: Self.askedKey(kind))
        defaults.removeObject(forKey: Self.fullKey(kind))
        defaults.set(data, forKey: Self.copyKey(kind))
    }

    /// The places in the copy that were lost and can be read now (by a later version), and aren't in the list already
    public func restorable(_ kind: Kind) -> [UserPlace] {
        guard let data = defaults.data(forKey: Self.copyKey(kind)),
              let entries = SavedData.entries(UserPlace.self, from: data) else { return [] }
        let lost = (defaults.array(forKey: Self.lostKey(kind)) as? [Int]).map(Set.init) ?? Set(entries.indices)
        let current = list(kind)
        let same = Self.same(kind)
        var found: [UserPlace] = []
        for (i, entry) in entries.enumerated() where lost.contains(i) {
            guard let place = entry, !current.contains(where: { same($0, place) }), !found.contains(where: { same($0, place) }) else { continue }
            found.append(place)
        }
        return found
    }

    /// What to ask the user about, once per copy: nil when there's nothing to ask. Asked again only if more places can be restored
    /// than when it was last asked (a later version reads what this one couldn't), or if some didn't fit then and there is room now.
    public struct Restore: Equatable, Sendable {
        /// Places that can be put back, in both lists; 0 means a copy was kept but nothing in it can be read yet
        public var count: Int
    }

    public func pendingRestore() -> Restore? {
        var ask = false
        var count = 0
        for kind in Kind.allCases {
            keepUnreadableCopy(of: kind)
            guard hasCopy(of: kind) else { continue }
            let n = restorable(kind).count
            count += n
            if let asked = defaults.object(forKey: Self.askedKey(kind)) as? Int {
                let roomNow = defaults.bool(forKey: Self.fullKey(kind)) && list(kind).count < Self.limit(kind)
                if n > asked || (n > 0 && roomNow) { ask = true }
            } else {
                ask = true
            }
        }
        return ask ? Restore(count: count) : nil
    }

    /// The user answered without restoring: don't ask about these copies again
    public func dismissRestore() {
        for kind in Kind.allCases where hasCopy(of: kind) {
            defaults.set(restorable(kind).count, forKey: Self.askedKey(kind))
            defaults.removeObject(forKey: Self.fullKey(kind))
        }
    }

    /// Puts back what can be read: at the end of the favorites (up to the limit) and after the recent places. A copy whose lost places
    /// all went back is deleted; one with places that didn't fit, or that still can't be read, is kept and not asked about again until
    /// more can be read, or, for places that didn't fit, until the list has room. Returns how many went back.
    @discardableResult
    public func restore() -> Int {
        var restored = 0
        for kind in Kind.allCases where hasCopy(of: kind) {
            let found = restorable(kind)
            var list = self.list(kind)
            let room = max(0, Self.limit(kind) - list.count)
            list += found.prefix(room)
            restored += min(room, found.count)
            if kind == .favorites { favorites = list } else { recents = list }
            if found.count <= room && !hasUnreadableLeft(kind) {
                deleteCopy(of: kind)
            } else {
                defaults.set(restorable(kind).count, forKey: Self.askedKey(kind))
                if found.count > room {
                    defaults.set(true, forKey: Self.fullKey(kind))
                } else {
                    defaults.removeObject(forKey: Self.fullKey(kind))
                }
            }
        }
        return restored
    }

    /// Whether some lost places in the copy still can't be read
    private func hasUnreadableLeft(_ kind: Kind) -> Bool {
        guard let data = defaults.data(forKey: Self.copyKey(kind)),
              let entries = SavedData.entries(UserPlace.self, from: data) else { return true }
        let lost = (defaults.array(forKey: Self.lostKey(kind)) as? [Int]) ?? Array(entries.indices)
        return lost.contains { !entries.indices.contains($0) || entries[$0] == nil }
    }

    public func deleteCopy(of kind: Kind) {
        for key in [Self.copyKey(kind), Self.lostKey(kind), Self.askedKey(kind), Self.fullKey(kind)] { defaults.removeObject(forKey: key) }
    }

    /// How many lists have a copy (for the counts line in the log; no contents)
    public var copyCount: Int { Kind.allCases.filter(hasCopy).count }
}
