import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

extension PlacePickerSheet {
    // MARK: Selecting and using

    /// The selected place as it would be used (nil while nothing is selected, while a search result or a pin's address is still
    /// being found, and for the current location)
    var chosenPlace: UserPlace? {
        switch choice {
        case .row(let row)?: return row.place
        case .found(let p)?: return p
        case .pin(let c, let name?)?: return UserPlace(name: name, coordinate: c)
        default: return nil
        }
    }

    /// What Use This Place uses now (nil: nothing ready yet)
    var usable: PickerUse? {
        if case .current? = choice { return currentLocationUsable ? .current : nil }
        return chosenPlace.map { PickerUse.place($0) }
    }

    /// Select a place; nothing is used until Use This Place. A lookup still running for an earlier selection is dropped. The search
    /// field keeps its text (it's emptied once a place is used)
    func select(_ new: PickerChoice) {
        naming?.cancel()
        naming = nil
        savingCurrent?.cancel()
        savingCurrent = nil
        currentSaved = nil
        addressError = nil
        demoOutside = false
        if !new.isSearch {
            address.cancelLookup()
        }
        choice = new
        let target: Coordinate?
        switch new {
        case .row(let row): target = row.place.coordinate
        case .found(let p): target = p.coordinate
        case .current: target = currentSpot
        // A pin stays where it was clicked; a search result moves the map once it's found
        case .pin, .finding: target = nil
        }
        if let target {
            focusCount &+= 1
            focus = PickerFocus(coordinate: target, count: focusCount)
        }
    }

    /// Use This Place, Return, a double click or "Use" in a card's menu
    func use() {
        guard let usable else { return }
        if transit.pickerForPlanner {
            // For trip planning: the main screen's walking origin is unchanged, and the place isn't saved (Plan a Trip keeps it in memory only)
            switch usable {
            case .place(let p):
                transit.plannerPick = p
            case .current:
                if let c = currentSpot {
                    transit.plannerPick = UserPlace(name: transit.l10n.t("My current location"), coordinate: c)
                }
            }
        } else {
            switch usable {
            case .place(let p):
                transit.walk(from: p, remember: keepsPlaces)
            case .current:
                transit.locationMode = .current
            }
        }
        // A place was used: the next open starts with an empty search field
        address.cancelLookup()
        address.clear()
        Self.keptSearch = ""
        dismiss()
    }

    /// Return in the search field: pick the suggestion lit up (or else the first), or with none, use the selected place
    func submitSearch(_ l: UIText) {
        let suggestions = shownSuggestions
        if !suggestions.isEmpty {
            chooseSuggestion(suggestions[min(highlighted ?? 0, suggestions.count - 1)], l)
        } else {
            use()
        }
    }

    /// ↓ / ↑ in the search field: the next or the previous suggestion lights up (from none, the first or the last). Left to the field
    /// while there are none, and to the input method while it's choosing characters (Chinese, Japanese, Korean)
    func moveHighlight(_ step: Int, _ l: UIText) -> KeyPress.Result {
        let suggestions = shownSuggestions
        let count = suggestions.count
        guard count > 0, !textIsBeingComposed() else { return .ignored }
        let next: Int
        if let i = highlighted {
            next = min(max(i + step, 0), count - 1)
        } else {
            next = step > 0 ? 0 : count - 1
        }
        highlighted = next
        // The keyboard stays in the field, so nothing else tells screen readers which suggestion lit up: said as its row says it
        let s = suggestions[next]
        announceToScreenReaders(RouteBullets.spoken(name: s.title, routes: NearbyBoardBuilder.sortRoutes(s.routes),
                                                    detail: s.subtitle, l))
        return .handled
    }

    /// Select a suggestion: its coordinates are looked up, then the map moves there. A newer lookup, another selection, editing the
    /// search text, Cancel, closing the window or switching what it's choosing for drops the lookup (see AddressSearch.lookUp):
    /// a slow answer then changes nothing and shows no error. One of Demo mode's places is selected at once.
    func chooseSuggestion(_ suggestion: PickerSuggestion, _ l: UIText) {
        let title = suggestion.title
        // The field shows the place picked. Set before the lookup starts: changing the text drops a lookup already running
        address.query = title
        suggestionsHiddenFor = title
        if let place = suggestion.place {
            select(.found(place))
            return
        }
        guard let completion = suggestion.completion else { return }
        select(.finding(title))
        address.lookUp(completion) { found in
            guard choice == .finding(title) else { return }
            guard let c = found else {
                addressError = l.t("Couldn't find that place.")
                choice = nil
                return
            }
            // Places outside the service area can be chosen too (so the "outside the service area" behavior can be seen); the main screen says so clearly
            choice = .found(UserPlace(name: title, coordinate: c))
            focusCount &+= 1
            focus = PickerFocus(coordinate: c, count: focusCount)
        }
    }

    /// A click on the map drops a pin there, then its address is found with Apple Maps (e.g. "123 Main St"); if none is found
    /// it's called "Place on the map"
    func dropPin(_ c: Coordinate, _ l: UIText) {
        if transit.isDemo {
            // Demo mode has times only in Manhattan: a pin goes only there, named without looking up its address
            guard DemoArea.contains(c) else {
                demoOutside = true
                return
            }
            select(.pin(c, l.t("Place on the map")))
            return
        }
        select(.pin(c, nil))
        naming = Task {
            // Networking turned off in Settings: don't look up the address
            var mark: CLPlacemark?
            if NetworkSwitch.isAllowed {
                // Another selection, Cancel or closing the window cancels this task, and with it the lookup (see MapsRequest)
                mark = await MapsRequest.placemark(of: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
            guard !Task.isCancelled, choice == .pin(c, nil) else { return }
            naming = nil
            choice = .pin(c, mark?.name ?? mark?.thoroughfare ?? l.t("Place on the map"))
        }
    }

    /// Save the current location as a favorite, named by its address (as a pin is); it stays selected as the current location
    func saveCurrent(_ l: UIText) {
        guard let c = currentSpot, !favoritesFull else { return }
        if transit.isDemo {
            // Demo mode's current location has its name already: no address to look up
            let place = DemoData.home
            if !favorites.contains(where: { SharedStore.samePlace($0, place) }) { toggleFavorite(place) }
            if favorites.contains(where: { SharedStore.samePlace($0, place) }) { currentSaved = place }
            return
        }
        savingCurrent?.cancel()
        savingCurrent = Task {
            var mark: CLPlacemark?
            if NetworkSwitch.isAllowed {
                mark = await MapsRequest.placemark(of: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
            guard !Task.isCancelled else { return }
            savingCurrent = nil
            let place = UserPlace(name: mark?.name ?? mark?.thoroughfare ?? l.t("Place on the map"), coordinate: c)
            if !favorites.contains(where: { SharedStore.samePlace($0, place) }) { toggleFavorite(place) }
            if favorites.contains(where: { SharedStore.samePlace($0, place) }) { currentSaved = place }
        }
    }

    /// The star under the map. A search result or pin becomes a favorite and stays selected, as its new card (scrolled into view)
    func starChosen(_ p: UserPlace) {
        let fromList = choice?.isRow == true
        toggleFavorite(p)
        if !fromList, let added = favorites.first(where: { SharedStore.samePlace($0, p) }) {
            choice = .row(.favorite(added))
            shownCard = .favorite(added)
        }
    }
}
