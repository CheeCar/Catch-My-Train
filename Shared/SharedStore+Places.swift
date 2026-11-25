import CatchText
import Foundation
import os
import TransitCore

extension SharedStore {
    static let recentPlacesKey = PlaceLists.Kind.recents.key
    static let recentPlacesLimit = PlaceLists.recentLimit

    /// Posted in the app when the favorites or recent places change, in any window, so a list on screen reads them again
    static let placesChanged = Notification.Name("CatchMyTrain.placesChanged")
    /// Posted in the app when the recent places are cleared: what was removed before can't be put back any more
    static let recentPlacesCleared = Notification.Name("CatchMyTrain.recentPlacesCleared")

    private static func notePlacesChanged() {
        NotificationCenter.default.post(name: placesChanged, object: nil)
    }

    /// The 10 most recently chosen places, stored only on this Mac and clearable in the place picker. Demo mode's own while it's on.
    static var recentPlaces: [UserPlace] {
        get {
            if let demoPlaces { return Array(demoPlaces.recents.prefix(recentPlacesLimit)) }
            return lists.recents
        }
        set {
            if demoPlaces != nil {
                demoPlaces?.recents = Array(newValue.prefix(recentPlacesLimit))
            } else {
                lists.recents = newValue
            }
            notePlacesChanged()
        }
    }

    /// Clears the recent places (and the copy kept of any that couldn't be read). Demo mode's own while it's on.
    static func clearRecentPlaces() {
        if demoPlaces != nil {
            demoPlaces?.recents = []
        } else {
            lists.clearRecents()
        }
        NotificationCenter.default.post(name: recentPlacesCleared, object: nil)
        notePlacesChanged()
    }

    static let favoritePlacesKey = PlaceLists.Kind.favorites.key

    /// Favorite places: never disappear automatically, stored only on this Mac. Demo mode's own while it's on.
    static var favoritePlaces: [UserPlace] {
        get {
            if let demoPlaces { return demoPlaces.favorites }
            return lists.favorites
        }
        set {
            if demoPlaces != nil {
                demoPlaces?.favorites = newValue
            } else {
                lists.favorites = newValue
            }
            notePlacesChanged()
        }
    }

    /// Maximum number of favorite places. When full, no more can be added; existing ones are never removed automatically.
    static let maxFavorites = PlaceLists.maxFavorites

    static var favoritesFull: Bool { favoritePlaces.count >= maxFavorites }

    static func isFavorite(_ place: UserPlace) -> Bool {
        favoritePlaces.contains { samePlace($0, place) }
    }

    /// Favorite / unfavorite. When favorites are full (maxFavorites), nothing is added and false is returned (the button is already grayed out in the UI).
    /// Taken out, the commute presets walking from it forget where it is (forgetInPresets; Undo gives it back with favoritePutBack).
    /// Added, the presets that forgot a place of its name walk from it again (reconnectPresets).
    @discardableResult
    static func toggleFavorite(_ place: UserPlace) -> Bool {
        var list = favoritePlaces
        if let saved = list.first(where: { samePlace($0, place) }) {
            list.removeAll { samePlace($0, place) }
            favoritePlaces = list
            forgetInPresets(saved)
            return true
        }
        guard list.count < maxFavorites else { return false }
        list.append(place)
        favoritePlaces = list
        reconnectPresets(to: place)
        return true
    }

    /// Save a new order for the favorites (dragging a row in the place picker). Only the order changes: nothing is added or removed,
    /// and a saved favorite that `order` leaves out stays, at the end.
    static func reorderFavorites(_ order: [UserPlace]) {
        if demoPlaces != nil {
            let saved = favoritePlaces
            var rest = saved
            var list: [UserPlace] = []
            for place in order {
                if let i = rest.firstIndex(where: { samePlace($0, place) }) { list.append(rest.remove(at: i)) }
            }
            list += rest
            if list != saved { favoritePlaces = list }
        } else {
            lists.reorderFavorites(order)
            notePlacesChanged()
        }
    }

    // MARK: Places that couldn't be read

    /// Something to ask the user about once, when the place picker opens: places that couldn't be read were kept (nil: nothing to ask;
    /// never in Demo mode)
    static func pendingPlacesRestore() -> PlaceLists.Restore? {
        demoPlaces == nil ? lists.pendingRestore() : nil
    }

    /// Puts back the kept places that can be read now; returns how many
    @discardableResult
    static func restoreKeptPlaces() -> Int {
        guard demoPlaces == nil else { return 0 }
        let restored = lists.restore()
        AppLog.data.notice("Restored kept places: \(restored, privacy: .public)")
        notePlacesChanged()
        return restored
    }

    static func dismissPlacesRestore() {
        guard demoPlaces == nil else { return }
        lists.dismissRestore()
    }

    // MARK: Demo mode's places

    /// Demo mode's places, kept only in the app's memory while it's on (the widget never has any): whether it walks from "My current
    /// location" (Times Square in the demo) or a place chosen, that place, and its own favorites, recent places and commute presets,
    /// which start as the demo's (DemoData; TransitModel gives the presets their names in the app's language). While there are some, the place settings above (and the presets,
    /// SharedStore+Presets) read and change them instead of the saved ones, so nothing done in Demo mode is saved and the user's own
    /// places are as they were when it's turned off (TransitModel makes them and drops them).
    struct DemoPlaces: Equatable {
        var locationMode: LocationMode = .current
        var place: UserPlace?
        var favorites: [UserPlace] = DemoData.favorites
        var recents: [UserPlace] = DemoData.recents
        var presets: [CommutePreset] = DemoData.presets
    }
    static var demoPlaces: DemoPlaces?


    /// Two favorites are the same place: same name and within 30 m (PlaceLists.sameFavorite)
    static func samePlace(_ a: UserPlace, _ b: UserPlace) -> Bool {
        PlaceLists.sameFavorite(a, b)
    }

    /// Two recent places are the same place: within 30 m, whatever their names (PlaceLists.sameRecent)
    static func sameRecent(_ a: UserPlace, _ b: UserPlace) -> Bool {
        PlaceLists.sameRecent(a, b)
    }

    /// Records a just-chosen place: put it first and drop an older entry for the same spot.
    static func remember(_ place: UserPlace) {
        var list = recentPlaces.filter { !sameRecent($0, place) }
        list.insert(place, at: 0)
        recentPlaces = list
    }
}
