import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// Choose the walking origin (or a place for Plan a Trip). Two columns: on the left the search field, then the favorite places and
/// recent places as cards, two to a row; on the right a map, "Use My Current Location" and "Open Larger Map". Clicking a card, a
/// search suggestion, the map or "Use My Current Location" only selects a place (the map moves there); Use This Place (or Return)
/// uses it and closes the window, a double click uses a card at once, and Cancel (or Esc) changes nothing. Open Larger Map puts a
/// large map in the middle of the window instead of the two columns, until Back.
struct PlacePickerSheet: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismissWindow) var dismissWindow
    /// The window's own undo list: ⌘Z (Edit → Undo) puts back a place taken out of a list
    @Environment(\.undoManager) var undoManager

    @StateObject var address = AddressSearch()
    @State var addressError: String?
    /// The search text a suggestion was clicked for: the suggestions stay hidden until the text changes
    @State var suggestionsHiddenFor: String?
    /// The suggestion lit up, by its place in the list: moved with ↓ / ↑, or the one under the mouse; Return picks it. Typing clears it
    @State var highlighted: Int?
    @State var recent = SharedStore.recentPlaces
    @State var favorites = SharedStore.favoritePlaces
    /// What Use This Place would use. Nothing at first: the place in use only changes with Use This Place
    @State var choice: PickerChoice?
    /// Where the map moves when something is selected (a pin dropped on the map doesn't move it)
    @State var focus: PickerFocus?
    @State var focusCount = 0
    /// Finding the address of a pin dropped on the map
    @State var naming: Task<Void, Never>?
    /// Saving the current location as a favorite: its address is found first, to name it
    @State var savingCurrent: Task<Void, Never>?
    /// The favorite just saved from the current location, while that is selected (its star is then filled)
    @State var currentSaved: UserPlace?
    /// The large map is shown instead of the two columns (Open Larger Map, until Back)
    @State var largeMap = false
    /// The card the arrow keys (or a star under the map) selected last: the lists scroll to show it
    @State var shownCard: PickerRow?
    /// The favorite card picked up and moving with the pointer (see favoritesGrid)
    @State var lift: FavoriteLift?
    /// A card was just dragged: the mouse-up that ends the drag doesn't also select, star or remove a place
    @State var justDragged = false
    /// Width of the favorites grid, for working out where each card sits while dragging
    @State var favoritesWidth: CGFloat = 0
    /// Clear next to Recent places asks first
    @State var confirmClear = false
    /// Saved places that couldn't be read were kept, and the user hasn't been asked about them yet (see askAboutKeptPlaces)
    @State var keptPlaces: PlaceLists.Restore?
    /// Demo mode: the map was clicked outside Manhattan, where it has no times (said under the map until the next selection)
    @State var demoOutside = false
    /// The place just taken out of a list, for the note with Undo at the bottom (10 seconds; see noteRemoved)
    @State var removed: RemovedPlace?
    /// Undo couldn't put this favorite back: the favorites filled up since it was taken out. The bottom says so for 10 seconds
    /// (see putBack)
    @State var fullOnUndo: RemovedPlace?
    /// The removals since this opening of the window that ⌘Z may still undo: dropped when it starts over
    @State var undoable: [RemovedPlace] = []
    /// True while a favorite is being dragged; going back to false also ends a drag that the system cancelled without an "ended" call
    @GestureState var draggingFavorite = false
    @FocusState var searchFocused: Bool
    /// The cards have the keyboard focus (once one is clicked): the arrow keys move the selection
    @FocusState var cardsFocused: Bool

    /// The search text while the window is closed, in memory only, until a place is used. The window keeps its contents while closed
    /// anyway; this also brings the text back when its view is made anew (as when the text size changes)
    @MainActor static var keptSearch = ""
    /// The kept text was typed in Demo mode: it isn't brought back in the other mode (nor what was typed for real into the demo)
    @MainActor static var keptSearchInDemo = false
    /// A card's height, which grows with the text size (PlacePickerWindow.cardHeight)
    static var cardHeight: CGFloat { PlacePickerWindow.cardHeight(TextScale.factor) }
    static let favoritesBoxID = "favoritesBox"

    var body: some View {
        let l = transit.l10n
        VStack(spacing: 0) {
            // The title is in the window's title bar; the traffic lights are the window's own
            Divider()
            originLine(l)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            // One tree for the two columns and the large map: the map stays where it is and only grows, so it is never taken away
            // and made anew (a map view taken away isn't always let go of)
            GeometryReader { g in
                HStack(spacing: 0) {
                    if !showsLargeMap {
                        leftColumn(l)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                    }
                    rightColumn(l)
                        .frame(width: showsLargeMap ? nil : PlacePickerWindow.mapColumnWidth(g.size.width))
                        .frame(maxWidth: showsLargeMap ? .infinity : nil, maxHeight: .infinity)
                }
            }
            Divider()
            footer(l)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(minWidth: PlacePickerWindow.minSize.width, idealWidth: PlacePickerWindow.defaultSize.width, maxWidth: .infinity,
               minHeight: PlacePickerWindow.minSize.height, idealHeight: PlacePickerWindow.defaultSize.height, maxHeight: .infinity)
        .onExitCommand { dismiss() }
        // The keyboard starts in the search field, here and at every open below: with every control taking the keyboard (as with a
        // screen reader) it started on the map's Recenter button
        .defaultFocus($searchFocused, true)
        // The window title changes when picking for trip planning (it's not the walking origin being picked)
        .navigationTitle(transit.pickerForPlanner ? l.t("Choose a place for your trip") : l.t("Choose where to walk from"))
        // Every open starts over: nothing selected, the two columns, the lists read again; the search field keeps its text until a
        // place is used. Also when opened from somewhere else while already open (an address lookup for the other purpose is dropped)
        .onAppear {
            reset()
            askAboutKeptPlaces()
            searchFocused = true
            // A screen reader taken into this window as it first opens doesn't find the search field's group (see the function)
            askScreenReadersToLookAgainSoon()
        }
        .onChange(of: transit.pickerForPlanner) { _, _ in reset() }
        // Demo mode turned on or off while open: the other lists and search
        .onChange(of: transit.isDemo) { _, _ in reset() }
        .onChange(of: transit.pickerOpenCount) { _, _ in
            reset()
            askAboutKeptPlaces()
            searchFocused = true
        }
        // The lists changed in another window (e.g. recent places cleared in Settings): show what is saved now, so nothing
        // already gone is shown or written back
        .onReceive(NotificationCenter.default.publisher(for: SharedStore.placesChanged)) { _ in
            reload()
            reselect()
        }
        .onReceive(NotificationCenter.default.publisher(for: SharedStore.recentPlacesCleared)) { _ in forgetRemovedRecents() }
        // Saved places that couldn't be read were kept: asked once (see askAboutKeptPlaces)
        .alert(l.t("Some saved places couldn't be read."), isPresented: keptPlacesAsked, presenting: keptPlaces) { kept in
            if kept.count > 0 {
                Button(l.t("Restore")) { SharedStore.restoreKeptPlaces() }
                Button(l.t("Not Now"), role: .cancel) { SharedStore.dismissPlacesRestore() }
            } else {
                Button(l.t("OK"), role: .cancel) { SharedStore.dismissPlacesRestore() }
            }
        } message: { kept in
            Text(kept.count > 0 ? l.t("A copy was kept. Restore the places that can still be read?")
                                : l.t("A copy was kept in case a later version can read it."))
        }
        .onChange(of: address.query) { _, query in
            // New text, new suggestions: none is lit up
            highlighted = nil
            // The search text was edited while a suggestion was being looked up: that lookup is dropped (see AddressSearch.query),
            // so nothing is selected any more
            if case .finding(let title)? = choice, query != title { choice = nil }
            // "Couldn't find that place." was about the suggestion picked before: it goes once the text changes
            addressError = nil
            if keepsPlaces {
                Self.keptSearch = query
                Self.keptSearchInDemo = transit.isDemo
            }
        }
        // Networking turned off in Settings: no map, so back to the two columns
        .onChange(of: transit.networkAllowed) { _, allowed in
            if !allowed { largeMap = false }
        }
        // Picking for Plan a Trip ends when the window closes (where the window is made, outside its .id)
        .onDisappear { reset() }
    }

    // MARK: Top line

    /// Where walking times are measured from now, in the same words as the menu bar and the sidebar; for Plan a Trip, what the
    /// place is for
    private func originLine(_ l: UIText) -> some View {
        let line = originText(l)
        return Label(line.text, systemImage: line.icon)
            .font(.scaled(line.muted ? .body : .headline))
            .foregroundStyle(line.warning ? Color.noticeOrange : line.muted ? Color.secondary : Color.primary)
            // A warning may take a second line (the position too far off to use says why)
            .lineLimit(line.warning ? 2 : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(line.text)
    }

    private func originText(_ l: UIText) -> (icon: String, text: String, muted: Bool, warning: Bool) {
        if transit.pickerForPlanner {
            return ("map", l.t("Choose the place on a map. Your main screen doesn't change."), true, false)
        }
        if transit.needsPlace {
            return (transit.missingPlaceSymbol, transit.missingPlaceText, true, false)
        }
        if transit.locationMode == .manual {
            return ("figure.walk", l.f("Walking from %@", transit.place.name), false, false)
        }
        // Demo mode's current location is Times Square
        if transit.isDemo {
            return ("theatermasks", l.f("Demo: walking from %@", DemoData.home.name), true, false)
        }
        guard let origin = transit.origin else {
            if transit.locationTooApproximate {
                return ("location.slash", transit.locationTooApproximateText, false, true)
            }
            // Nothing is located on standby, so don't say it's being found (as in the sidebar)
            return ("location", transit.isActive ? l.t("Finding your location…") : l.t("Current location"), true, false)
        }
        if origin.kind == .manualFallback {
            return ("location.slash", l.f("Location unavailable. Walking from %@", origin.name), false, true)
        }
        // An approximate position says how approximate (as under the name in the sidebar)
        return ("location.fill", transit.locationAccuracyNote ?? l.t("Current location"), false, false)
    }

    // MARK: Bottom

    private func footer(_ l: UIText) -> some View {
        // Return uses the selected place, except while typing in the search field (there it picks the first suggestion first)
        let useKey: KeyboardShortcut? = searchFocused ? nil : .defaultAction
        return HStack(spacing: 10) {
            // From the large map back to the two columns, the selection unchanged
            if showsLargeMap {
                Button {
                    largeMap = false
                } label: {
                    Label(l.t("Back"), systemImage: "chevron.backward")
                }
                .appButtonStyle()
            }
            // A place just taken out of a list: its name and Undo, for 10 seconds
            if let removed {
                removedNote(removed, l)
            } else if fullOnUndo != nil {
                fullOnUndoNote(l)
            }
            Spacer()
            // Changed my mind: close the window, walking origin unchanged
            Button(l.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .appButtonStyle()
                .help(l.t("Close without changing the place"))
            Button(l.t("Use This Place")) { use() }
                .keyboardShortcut(useKey)
                .appButtonStyle(.prominent)
                .disabled(usable == nil)
        }
    }

    /// After a place was taken out of a list: "Removed" and its name, and Undo, which puts it back where it was (⌘Z does the same).
    /// The name is shortened in the middle when the window is narrow; Undo looks like the small buttons in the sidebar
    private func removedNote(_ r: RemovedPlace, _ l: UIText) -> some View {
        HStack(spacing: 8) {
            Text(l.f("Removed %@", r.place.name))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Button(l.t("Undo")) {
                undoManager?.removeAllActions(withTarget: r)
                putBack(r)
            }
            .buttonStyle(SmallBezelButtonStyle())
            .lineLimit(1)
            .fixedSize()
        }
        .font(.scaled(.subheadline))
        .padding(.vertical, 4)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .transition(.opacity)
    }

    /// Undo found the favorites full: why the place didn't come back, in the place of the "Removed" note
    private func fullOnUndoNote(_ l: UIText) -> some View {
        Text(fullText(l))
            .font(.scaled(.subheadline))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(fullText(l))
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .transition(.opacity)
    }
}

/// The place picker window (shared by the main window, Settings and the menu bar).
enum PlacePickerWindow {
    static let id = "placePicker"
    /// Content size: the default, and the smallest it can be made
    static let defaultSize = CGSize(width: 860, height: 580)
    static let minSize = CGSize(width: 660, height: 440)

    /// The map column: 40% of the window's width, at least 280 and at most 420 points; the lists get the rest
    static func mapColumnWidth(_ width: CGFloat) -> CGFloat { min(max(width * 0.4, 280), 420) }

    /// A place card's height at a text size (TextScale.factor), whatever its name: the favorites grid and dragging work out where
    /// each card is from it. A name too long for one line takes two lines of a smaller text style instead (PlaceCard)
    static func cardHeight(_ factor: CGFloat) -> CGFloat { (34 * factor).rounded() }

    /// forPlanner: picking a place for "Plan a Trip" (the main screen doesn't change); otherwise picking the walking origin
    @MainActor static func open(with openWindow: OpenWindowAction, transit: TransitModel, forPlanner: Bool = false) {
        transit.pickerForPlanner = forPlanner
        transit.pickerOpenCount &+= 1
        openWindow(id: id)
        NSApp.activate()
    }
}
