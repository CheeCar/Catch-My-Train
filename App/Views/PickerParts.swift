import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// A card in the place picker's lists. The same place can be in both lists, so the card says which list it is in
enum PickerRow: Hashable {
    case favorite(UserPlace)
    case recent(UserPlace)

    var place: UserPlace {
        switch self {
        case .favorite(let p), .recent(let p): return p
        }
    }

    var isFavorite: Bool {
        if case .favorite = self { return true }
        return false
    }
}

/// Where a card sits among the cards: its line from the top (favorites first, then recent places) and its column (0: the first)
struct CardPosition {
    let row: PickerRow
    let line: Int
    let column: Int
}

/// What is selected in the place picker
/// A place just taken out of the favorites or the recent places, and where it was in that list, so Undo can put it back there. A
/// class: the window's undo list files each undo under an object
final class RemovedPlace {
    let place: UserPlace
    let favorite: Bool
    let index: Int

    init(place: UserPlace, favorite: Bool, index: Int) {
        self.place = place
        self.favorite = favorite
        self.index = index
    }
}

enum PickerChoice: Equatable {
    /// A card in the lists
    case row(PickerRow)
    /// A search suggestion whose coordinates are still being looked up (its title)
    case finding(String)
    /// A search suggestion, found
    case found(UserPlace)
    /// A pin dropped on the map; no name while its address is being found
    case pin(Coordinate, String?)
    /// My current location
    case current

    var isRow: Bool {
        if case .row = self { return true }
        return false
    }

    /// From the search field: keeps the lookup of the suggestion running
    var isSearch: Bool {
        switch self {
        case .finding, .found: return true
        case .row, .pin, .current: return false
        }
    }
}

/// A suggestion under the search field: Apple Maps' (its coordinates looked up once it's clicked), or one of Demo mode's places
struct PickerSuggestion {
    var title: String
    var subtitle: String
    var completion: MKLocalSearchCompletion?
    var place: UserPlace?
    /// A station's routes, for their badges
    var routes: [String] = []
}

/// What Use This Place uses
enum PickerUse {
    case place(UserPlace)
    case current
}

/// Where the map moves to; count tells two moves to the same place apart (the second one still moves the map back there)
struct PickerFocus: Equatable {
    let coordinate: Coordinate
    let count: Int
}

/// The map's marker: a pin with the place's name, or (no name) the current location
struct PickerMarker {
    var name: String?
    var coordinate: Coordinate
    /// The current location while the app is running: MapKit's own location dot
    var live = false
}

