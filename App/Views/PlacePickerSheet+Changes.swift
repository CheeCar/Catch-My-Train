import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

extension PlacePickerSheet {
    // MARK: Changing the lists

    func toggleFavorite(_ p: UserPlace) {
        guard keepsPlaces else { return }
        let before = SharedStore.favoritePlaces
        SharedStore.toggleFavorite(p)
        favorites = SharedStore.favoritePlaces
        // Taken out, not added: it can be put back
        if let index = before.firstIndex(where: { SharedStore.samePlace($0, p) }) {
            noteRemoved(RemovedPlace(place: before[index], favorite: true, index: index))
        }
        reselect()
    }

    func removeRecent(_ p: UserPlace) {
        guard keepsPlaces else { return }
        let before = SharedStore.recentPlaces
        SharedStore.recentPlaces = before.filter { !SharedStore.sameRecent($0, p) }
        recent = SharedStore.recentPlaces
        if let index = before.firstIndex(where: { SharedStore.sameRecent($0, p) }) {
            noteRemoved(RemovedPlace(place: before[index], favorite: false, index: index))
        }
        reselect()
    }

    /// After a place was taken out of a list: the note with Undo at the bottom for 10 seconds (a newer one takes its place), and an
    /// undo for ⌘Z. Either puts the place back where it was
    private func noteRemoved(_ r: RemovedPlace) {
        undoManager?.registerUndo(withTarget: r) { r in putBack(r) }
        undoable.append(r)
        withAnimation(Motion.ease(0.2)) {
            removed = r
            fullOnUndo = nil
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if removed === r { withAnimation(Motion.ease(0.2)) { removed = nil } }
        }
    }

    /// Undo: the place goes back to where it was in its list, unless it is in that list again already (nothing to say), or the
    /// favorites have filled up since (the bottom says they are full)
    func putBack(_ r: RemovedPlace) {
        if removed === r { withAnimation(Motion.ease(0.2)) { removed = nil } }
        guard keepsPlaces else { return }
        if r.favorite {
            var list = SharedStore.favoritePlaces
            guard !list.contains(where: { SharedStore.samePlace($0, r.place) }) else { return }
            guard list.count < SharedStore.maxFavorites else {
                noteFullOnUndo(r)
                return
            }
            list.insert(r.place, at: min(r.index, list.count))
            SharedStore.favoritePlaces = list
            // The commute presets that walked from it do again
            SharedStore.favoritePutBack(r.place)
            favorites = SharedStore.favoritePlaces
        } else {
            var list = SharedStore.recentPlaces
            guard !list.contains(where: { SharedStore.sameRecent($0, r.place) }) else { return }
            list.insert(r.place, at: min(r.index, list.count))
            SharedStore.recentPlaces = Array(list.prefix(SharedStore.recentPlacesLimit))
            recent = SharedStore.recentPlaces
        }
    }

    /// The favorites were full when Undo tried to put this one back: said at the bottom for 10 seconds (the "Removed" note it
    /// came from is gone already; a newer removal takes its place)
    private func noteFullOnUndo(_ r: RemovedPlace) {
        withAnimation(Motion.ease(0.2)) {
            removed = nil
            fullOnUndo = r
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if fullOnUndo === r { withAnimation(Motion.ease(0.2)) { fullOnUndo = nil } }
        }
    }

    func clearRecents() {
        guard keepsPlaces else { return }
        SharedStore.clearRecentPlaces()
        recent = []
        reselect()
    }

    /// After the recent places were cleared (here or in Settings): the recent places taken out before can't be put back any more
    func forgetRemovedRecents() {
        for r in undoable where !r.favorite { undoManager?.removeAllActions(withTarget: r) }
        undoable.removeAll { !$0.favorite }
        if let r = removed, !r.favorite { withAnimation(Motion.ease(0.2)) { removed = nil } }
    }

    /// Saved places that couldn't be read were kept: ask once whether to restore the ones that can be read now (or, when none can
    /// yet, just say a copy was kept). Not for Demo mode's places
    func askAboutKeptPlaces() {
        guard keepsPlaces, !transit.isDemo else { return }
        keptPlaces = SharedStore.pendingPlacesRestore()
    }

    var keptPlacesAsked: Binding<Bool> {
        Binding(get: { keptPlaces != nil }, set: { if !$0 { keptPlaces = nil } })
    }

    /// After the lists change: a selected card whose place left its list moves to that place's card in the other list, or the
    /// selection goes
    func reselect() {
        guard case .row(let row)? = choice else { return }
        switch row {
        case .favorite(let p):
            guard !favorites.contains(p) else { return }
            if let other = recent.first(where: { SharedStore.samePlace($0, p) }) {
                choice = .row(.recent(other))
            } else {
                choice = nil
            }
        case .recent(let p):
            guard !recent.contains(p) else { return }
            if let other = favorites.first(where: { SharedStore.samePlace($0, p) }) {
                choice = .row(.favorite(other))
            } else {
                choice = nil
            }
        }
    }

    /// Favorites are full (50)
    var favoritesFull: Bool { favorites.count >= SharedStore.maxFavorites }

    func fullText(_ l: UIText) -> String {
        l.f("Favorites are full (%@). Remove one to add another.", "\(SharedStore.maxFavorites)")
    }

    func reload() {
        favorites = SharedStore.favoritePlaces
        recent = SharedStore.recentPlaces
    }

    /// Changes to the favorites and recent places are saved, and the search text is kept
    var keepsPlaces: Bool {
        return true
    }

    /// Start over, as on every open (the window keeps its contents while closed): nothing selected, the two columns, the lists read
    /// again. The search field keeps its text and suggestions until a place is used
    func reset() {
        // A new start: what was taken out before can't be put back any more
        confirmClear = false
        removed = nil
        fullOnUndo = nil
        for r in undoable { undoManager?.removeAllActions(withTarget: r) }
        undoable = []
        naming?.cancel()
        naming = nil
        savingCurrent?.cancel()
        savingCurrent = nil
        currentSaved = nil
        demoOutside = false
        // Demo mode searches its own places, never Apple Maps; text typed in the other mode isn't brought back
        address.usesAppleMaps = !transit.isDemo
        if Self.keptSearchInDemo != transit.isDemo {
            Self.keptSearch = ""
            Self.keptSearchInDemo = transit.isDemo
        }
        address.cancelLookup()
        if !keepsPlaces {
            // An empty search field, whatever was typed before
            address.clear()
        } else if address.query != Self.keptSearch {
            address.query = Self.keptSearch
        }
        addressError = nil
        suggestionsHiddenFor = nil
        choice = nil
        focus = nil
        shownCard = nil
        largeMap = false
        if lift != nil { NSCursor.arrow.set() }
        lift = nil
        justDragged = false
        reload()
    }

    /// Close the window once a place is used, or on Cancel; a lookup still in flight is dropped, so it can't change anything afterwards
    func dismiss() {
        reset()
        dismissWindow(id: PlacePickerWindow.id)
    }
}
