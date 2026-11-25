import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension PlannerView {
    // MARK: Place

    /// The main view isn't affected by the trip planner: describe it by the place the main view uses now (nothing while it has none)
    func mainScreenText(_ l: UIText) -> String {
        if transit.needsPlace { return "" }
        return transit.locationMode == .manual
            ? l.f("Your main screen keeps using %@.", transit.place.name)
            : l.t("Your main screen keeps using your current location.")
    }

    /// Take the place picked for the trip planner in the place picker window
    func takePick() {
        guard let p = transit.plannerPick else { return }
        transit.plannerPick = nil
        planner.choose(place: p, transit: transit)
        searchFocused = false
    }

    /// Uses the same place picker window as "A place I choose": all the favorites and recent places, and its map.
    /// There's only one window: opened from elsewhere it switches to that purpose and its title follows; a place picked here doesn't change the main view's walking origin.
    /// The map starts at the trip planner's place, else where the main window walks from (in Demo mode its own, never the Mac's location)
    private func openMap() {
        transit.plannerMapStart = planner.place?.coordinate ?? walkingFrom
        PlacePickerWindow.open(with: openWindow, transit: transit, forPlanner: true)
    }

    /// Where the maps open before a place is chosen: where the main window walks from (the Mac's location or its place; in Demo
    /// mode the demo's place)
    /// nil with neither (no location, no place chosen yet): the maps then show the whole service area
    var walkingFrom: Coordinate? {
        transit.isDemo ? transit.origin?.coordinate ?? DemoData.home.coordinate
            : transit.currentCoordinate ?? (transit.hasPlace ? transit.place.coordinate : nil)
    }

    /// The chosen place, as the field shows it while it isn't being edited: nil while typing, or once the text was changed
    private var shownPlace: PlannerModel.Place? {
        guard let place = planner.place, planner.pickedText != nil, !searchFocused else { return nil }
        return place
    }

    func clear() {
        closeLargeMap()
        planner.query = ""
        planner.clearPlace()
        listClosed = false
        searchFocused = true
    }

    /// The place field: a pin, then the text being typed, or the chosen place (its name, then where it is in small gray text; a click
    /// edits the text again), and a button that clears it. The suggestions hang below it, over the results
    func placeField(_ l: UIText) -> some View {
        let chosen = shownPlace
        let shape = RoundedRectangle(cornerRadius: 6)
        return HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                // The hint, drawn here so that in a narrow field it ends with "…" (the text field's own would just be cut off)
                if chosen == nil, planner.query.isEmpty {
                    Text(l.t("Address, place or station name"))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $planner.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(l.t("Address, place or station name"))
                    .focused($searchFocused)
                    .onExitCommand { listClosed = true }
                    // The keyboard alone can pick a suggestion: ↓ / ↑ light one up, Return picks it (or the first), as in the place picker
                    .onSubmit { pickHighlighted() }
                    .onKeyPress(.downArrow) { moveHighlight(1, l) }
                    .onKeyPress(.upArrow) { moveHighlight(-1, l) }
                    .opacity(chosen == nil ? 1 : 0)
                if let chosen {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chosen.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if !chosen.subtitle.isEmpty {
                            Text(l.demoPlaceDetail(chosen.subtitle, lines: chosen.lines))
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { searchFocused = true }
                    // Screen readers read the place, and pressing it edits the text again
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { searchFocused = true }
                }
            }
            if planner.place != nil || !planner.query.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l.t("Clear"))
                .accessibilityLabel(l.t("Clear"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(shape.fill(Color(nsColor: .textBackgroundColor)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        .overlay {
            // The focus ring, outside the edge like the system's
            if searchFocused {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5), lineWidth: 3).padding(-2)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if changed(fieldWidth, size.width) { fieldWidth = size.width }
            if changed(fieldHeight, size.height) { fieldHeight = size.height }
        }
        .overlay(alignment: .topLeading) {
            if showsList {
                suggestionList(l)
                    .frame(width: max(fieldWidth, 360))
                    // Hangs from the field's bottom edge: moved down by the field's height (aligning its top to the field's bottom
                    // with an alignment guide left it going up, over the window's title)
                    .offset(y: fieldHeight + 4)
                    .transition(.opacity)
            }
        }
        // The field, its clear button and the suggestions, one after the other for screen readers: they go by where things are in
        // the window, and the row's other controls came between the field and its suggestions (as in the place picker's search)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l.t("Address, place or station name"))
        .animation(Motion.ease(0.15), value: showsList)
        // The suggestions come beside the field: screen readers are asked to look at the window again (see the function)
        .onChange(of: showsList) { _, shows in
            if shows { askScreenReadersToLookAgainSoon() }
        }
    }

    /// The suggestion list is shown while typing: until something is picked, Escape or a click on the results closes it, or the text is
    /// cleared. With a place already chosen, only once there are places to suggest, saved or looked up (its results stay in view
    /// until then)
    var showsList: Bool {
        guard !listClosed else { return false }
        if planner.query.isEmpty { return false }
        guard planner.pickedText == nil, planner.place == nil || hasPlaceSuggestions || hasSavedMatches else { return false }
        return hasSavedMatches || !matchingStations.isEmpty || planner.nothingFound || networkOffNote || !planner.suggestions.isEmpty
            || !demoPlaces.isEmpty || demoFoundNothing
    }

    /// The suggestions in a box of their own over the results, scrolling when they're taller than the room under the field
    private func suggestionList(_ l: UIText) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ScrollViewReader { proxy in
            ScrollView {
                suggestionRows(l)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if changed(listHeight, h) { listHeight = h }
                    }
            }
            .frame(height: min(max(listHeight, 1), max(120, resultsHeight - 16)))
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .contrastBorder(cornerRadius: 8)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            // A suggestion lit up below the part in view (with ↓) comes into view
            .onChange(of: highlighted) { _, i in
                if let i { proxy.scrollTo(i) }
            }
        }
    }

    /// The suggestions in the order they're listed, each with what picking it does: saved places (favorites, then recent ones), subway
    /// stations, then places (Apple Maps', or Demo mode's). ↓ / ↑ and Return go through these; none while the list isn't shown
    private var suggestionPicks: [() -> Void] {
        guard showsList else { return [] }
        let found = matchingSaved
        let saved: [() -> Void] = (found.favorites + found.recents).map { p in { pick(saved: p) } }
        let stations: [() -> Void] = matchingStations.map { e in { pick(station: e) } }
        let places: [() -> Void] = planner.suggestions.map { s in { pick(s) } }
        let demo: [() -> Void] = demoPlaces.map { p in { pick(demo: p) } }
        return saved + stations + places + demo
    }

    /// ↓ / ↑ in the place field: the next or the previous suggestion lights up (from none, the first or the last). Left to the field
    /// while there's no list, and to the input method while it's choosing characters (Chinese, Japanese, Korean)
    private func moveHighlight(_ step: Int, _ l: UIText) -> KeyPress.Result {
        let count = suggestionPicks.count
        guard count > 0, !textIsBeingComposed() else { return .ignored }
        let next: Int
        if let i = highlighted {
            next = min(max(i + step, 0), count - 1)
        } else {
            next = step > 0 ? 0 : count - 1
        }
        highlighted = next
        // The keyboard stays in the field, so nothing else tells screen readers which suggestion lit up
        if let spoken = spokenSuggestion(next, l) { announceToScreenReaders(spoken) }
        return .handled
    }

    /// What screen readers hear when the arrow keys light up the suggestion at `index` of suggestionPicks: its name, then its
    /// lines or where it is, as its row says them. In the order of suggestionPicks
    private func spokenSuggestion(_ index: Int, _ l: UIText) -> String? {
        let found = matchingSaved
        let saved = found.favorites + found.recents
        if index < saved.count { return saved[index].name }
        var i = index - saved.count
        let stations = matchingStations
        if i < stations.count {
            return RouteBullets.spoken(name: stations[i].name, routes: NearbyBoardBuilder.sortRoutes(stations[i].routes), l)
        }
        i -= stations.count
        let places = planner.suggestions
        if i < places.count { return RouteBullets.spoken(name: places[i].title, routes: [], detail: places[i].subtitle, l) }
        i -= places.count
        let demo = demoPlaces
        guard i < demo.count else { return nil }
        return RouteBullets.spoken(name: demo[i].name, routes: [], detail: l.demoPlaceDetail(demo[i]), l)
    }

    /// Return in the place field: picks the suggestion lit up, or else the first. Nothing while there are none (still looking)
    private func pickHighlighted() {
        let picks = suggestionPicks
        guard !picks.isEmpty else { return }
        picks[min(highlighted ?? 0, picks.count - 1)]()
    }

    func pick(station e: StationName) {
        planner.query = e.name
        planner.choose(station: e, transit: transit)
        searchFocused = false
    }

    func pick(_ s: MKLocalSearchCompletion) {
        planner.query = s.title
        planner.choose(s, transit: transit)
        searchFocused = false
    }

    func pick(demo p: DemoData.Place) {
        planner.query = p.name
        planner.choose(demo: p, transit: transit)
        searchFocused = false
    }

    /// A favorite or recent place among the suggestions: like picking it in the ★ popover
    func pick(saved p: UserPlace) {
        planner.choose(place: p, transit: transit)
        searchFocused = false
    }

    /// One suggestion row, `index` its place in suggestionPicks: lit up when it's the highlighted one, and the mouse lights it up too.
    /// spoken: what screen readers say for it, when not its text in order (a station: its name before its lines)
    private func suggestion<Content: View>(_ index: Int, spoken: String? = nil, action: @escaping () -> Void,
                                           @ViewBuilder content: () -> Content) -> some View {
        SuggestionRow(highlighted: highlighted == index,
                      hover: { inside in
                          if inside { highlighted = index } else if highlighted == index { highlighted = nil }
                      },
                      spoken: spoken, action: action, content: content)
            .id(index)
    }

    /// Search suggestions: the favorites and recent places with the text in their name first, then the mode's stations (the app's
    /// own names, no network needed; none for bus, see StationSearch) and Apple Maps addresses.
    /// Demo mode lists its own places instead of Apple Maps' (no network needed), and says what it knows when it finds nothing.
    /// Picking one ends the typing: the field shows the place
    private func suggestionRows(_ l: UIText) -> some View {
        let saved = matchingSaved
        let savedCount = saved.favorites.count + saved.recents.count
        let stations = matchingStations
        let places = planner.suggestions
        let demoPlaces = self.demoPlaces
        return VStack(alignment: .leading, spacing: 0) {
            if !saved.favorites.isEmpty {
                listHeader(l.t("Favorite places"))
                ForEach(Array(saved.favorites.enumerated()), id: \.offset) { i, p in
                    suggestion(i) { pick(saved: p) } content: { savedPlaceLabel(p, favorite: true) }
                }
            }
            if !saved.recents.isEmpty {
                listHeader(l.t("Recent places"))
                ForEach(Array(saved.recents.enumerated()), id: \.offset) { i, p in
                    suggestion(saved.favorites.count + i) { pick(saved: p) } content: { savedPlaceLabel(p, favorite: false) }
                }
            }
            if !stations.isEmpty {
                // Bus mode lists none (see matchingStations)
                listHeader(transit.system.mode == .train ? l.t("Train stations")
                           : transit.system.mode == .ferry ? l.t("Piers") : l.t("Subway stations"))
                ForEach(Array(stations.enumerated()), id: \.offset) { i, e in
                    let routes = NearbyBoardBuilder.sortRoutes(e.routes)
                    suggestion(savedCount + i, spoken: RouteBullets.spoken(name: e.name, routes: routes, l)) { pick(station: e) } content: {
                        HStack(spacing: 8) {
                            RouteBullets(routes: routes, size: 14, limit: 6)
                                .fixedSize()
                            Text(e.name)
                        }
                    }
                }
            }
            if planner.nothingFound {
                Text(l.t("No places in the United States were found for this search. Try a station name or a different search."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            }
            if networkOffNote {
                NetworkOffNote(l: l).padding(.horizontal, 10).padding(.vertical, 6)
            }
            if !places.isEmpty {
                listHeader(l.t("Places"))
                ForEach(Array(places.enumerated()), id: \.offset) { i, s in
                    suggestion(savedCount + stations.count + i) { pick(s) } content: {
                        placeSuggestion(s.title, s.subtitle)
                    }
                }
            }
            if !demoPlaces.isEmpty {
                listHeader(l.t("Places"))
                ForEach(Array(demoPlaces.enumerated()), id: \.element.id) { i, p in
                    suggestion(savedCount + stations.count + places.count + i) { pick(demo: p) } content: {
                        placeSuggestion(p.name, l.demoPlaceDetail(p))
                    }
                }
            }
            // Demo mode found nothing for the text: say what it knows, as the demo page does (it looks broken otherwise)
            if demoFoundNothing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "theatermasks")
                        .accessibilityHidden(true)
                    Text(l.t("This demo knows only some famous places and the subway stations in Manhattan. Try Times Square, or choose a place on the map."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.scaled(.caption)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.vertical, 5)
    }

    /// The ★ button's popover: the first favorites, then the newest recent places, few enough to need no scrolling. When some aren't
    /// listed, one line under the lists (under the favorites when there are no recent places) says how many it lists of each and how
    /// to choose which favorites come first; it doesn't say how many there are (no "6 of 14": in All Places that form means how many
    /// of the most there can be). With none at all (a new install) only All Places and Map, which stays at the bottom
    func placesPopover(_ l: UIText) -> some View {
        let saved = savedPlaces
        let pick = PlaceLists.quickPick(favorites: saved.favorites, recents: saved.recents)
        // The lists scroll only on a screen too short for them (the popover hangs under the ★ button, near the window's top)
        let tallest = max(230, (NSScreen.main?.visibleFrame.height ?? 800) - 220)
        return VStack(alignment: .leading, spacing: 0) {
            if !pick.favorites.isEmpty || !pick.recents.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !pick.favorites.isEmpty {
                            listHeader(l.t("Favorite places"))
                            ForEach(Array(pick.favorites.enumerated()), id: \.offset) { _, p in
                                savedPlaceRow(p, favorite: true)
                            }
                        }
                        if !pick.recents.isEmpty {
                            listHeader(l.t("Recent places"))
                            ForEach(Array(pick.recents.enumerated()), id: \.offset) { _, p in
                                savedPlaceRow(p, favorite: false)
                            }
                        }
                        if pick.hasMore {
                            // Under the last list's names, past their icons. The numbers are in the sentence itself
                            // (PlaceLists.quickFavorites and quickRecents; a test keeps them the same)
                            Text(l.t("Up to 6 favorites and the 4 most recent places are shown here. To change the order of favorites, drag them in All Places."))
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 34)
                                .padding(.trailing, 10)
                                .padding(.vertical, 3)
                        }
                    }
                    .padding(.vertical, 5)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if changed(placesHeight, h) { placesHeight = h }
                    }
                }
                .frame(height: min(max(placesHeight, 1), tallest))
            }
            if hasSavedPlaces { Divider() }
            PopoverRow {
                placesOpen = false
                openMap()
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "map")
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.t("All Places and Map") + "…")
                        // With networking turned off in Settings it still opens (all the favorites and recent places are there, and
                        // need no network), and says here that its map and address search won't work
                        if !transit.networkAllowed {
                            Text(l.t("Maps and address search need the network. Turn on “Allow network” in Settings → Privacy."))
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 300)
    }

    /// A favorite (star) or recent place (clock) in the ★ popover: picking it is like using it in the place picker
    private func savedPlaceRow(_ p: UserPlace, favorite: Bool) -> some View {
        PopoverRow {
            placesOpen = false
            planner.choose(place: p, transit: transit)
            searchFocused = false
        } content: {
            savedPlaceLabel(p, favorite: favorite)
        }
    }

    /// A saved place as a row shows it, in the ★ popover and among the suggestions: a star or a clock, then its name
    private func savedPlaceLabel(_ p: UserPlace, favorite: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: favorite ? "star.fill" : "clock")
                .modifier(FavoriteStarStyle(favorite: favorite))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(p.name)
                .lineLimit(1)
        }
    }

    /// The place picker's favorites and recent places with the typed text in their name, suggested first (PlaceLists.matching).
    /// None once a place is picked
    private var matchingSaved: (favorites: [UserPlace], recents: [UserPlace]) {
        guard planner.pickedText == nil else { return ([], []) }
        let saved = savedPlaces
        return PlaceLists.matching(planner.query, favorites: saved.favorites, recents: saved.recents)
    }

    private var hasSavedMatches: Bool {
        let found = matchingSaved
        return !found.favorites.isEmpty || !found.recents.isEmpty
    }

    /// The place picker's favorites and recent places (Demo mode's own in Demo mode)
    private var savedPlaces: (favorites: [UserPlace], recents: [UserPlace]) {
        return (SharedStore.favoritePlaces, SharedStore.recentPlaces)
    }

    private var hasSavedPlaces: Bool {
        let saved = savedPlaces
        return !saved.favorites.isEmpty || !saved.recents.isEmpty
    }

    private func listHeader(_ title: String) -> some View {
        Text(title)
            .font(.scaled(.caption).bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    /// A place among the suggestions: its name, and where it is under it
    private func placeSuggestion(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if !subtitle.isEmpty {
                Text(subtitle).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The network is off in Settings and nothing can be looked up (Demo mode needs no network)
    private var networkOffNote: Bool {
        !transit.networkAllowed && !transit.isDemo && !planner.query.isEmpty && planner.place == nil
    }

    /// Demo mode found nothing for the text typed
    private var demoFoundNothing: Bool {
        transit.isDemo && matchingStations.isEmpty && demoPlaces.isEmpty && !hasSavedMatches
            && !planner.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The mode's stations with the text in their name (StationSearch: the app's own names, no network needed): another mode's would
    /// read as stops of this one, and bus mode lists none (Apple Maps finds stops by name too). Demo mode lists only its area's
    /// subway stations
    private var matchingStations: [StationName] {
        if transit.isDemo {
            guard transit.system == .subway else { return [] }
            return DemoData.stationSearch(planner.query, catalog: transit.catalog).map {
                StationName(id: $0.id, name: $0.name, coordinate: $0.coordinate, routes: $0.routes.map(\.route))
            }
        }
        return StationSearch.matching(planner.query, system: transit.system, catalog: transit.catalog, limit: StationSearch.shownAtMost)
    }

    /// Demo mode's places for the search text, standing in for Apple Maps' (DemoData.search): its famous places, and in the other
    /// modes its subway stations as places too (subway mode lists them by themselves, above). None once one is chosen
    private var demoPlaces: [DemoData.Place] {
        guard transit.isDemo, planner.pickedText == nil else { return [] }
        return DemoData.search(planner.query, catalog: transit.catalog, stations: transit.system != .subway)
    }

    /// The search has places to suggest (Apple Maps', or Demo mode's): the list then covers the chosen place's results
    private var hasPlaceSuggestions: Bool {
        transit.isDemo ? !demoPlaces.isEmpty : !planner.suggestions.isEmpty
    }
}
/// One suggestion in the list under Plan a Trip's place field, highlighted like a menu item: blue with white text when it's the one
/// lit up, by the arrow keys or the mouse (only one at a time: PlannerView.highlighted), which screen readers hear as selected
private struct SuggestionRow<Content: View>: View {
    let highlighted: Bool
    /// The mouse came onto the row (true) or left it
    let hover: (Bool) -> Void
    /// What screen readers say for the row, when not its text in order
    var spoken: String? = nil
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if let spoken {
            row.accessibilityLabel(Text(spoken))
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // White on the highlight; the gray lines in it (secondary) are a lighter white then
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .environment(\.rowHighlighted, highlighted)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).padding(.horizontal, 5)
            }
        }
        .onHover(perform: hover)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// A row of the ★ popover (All Places and Map, a favorite or recent place): lit up like a suggestion, by the mouse only (the
/// arrow keys move in the place field's suggestions, not here)
private struct PopoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        SuggestionRow(highlighted: hovering, hover: { hovering = $0 }, action: action) {
            content
        }
    }
}

/// A text field is in the middle of composing (a Chinese, Japanese or Korean input method choosing characters): the arrow keys
/// and Return are the input method's then (Plan a Trip's place field, the place picker's search)
@MainActor func textIsBeingComposed() -> Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
}

/// Says a line to screen readers that nothing on screen makes them read: the suggestion the arrow keys lit up, while the
/// keyboard stays in the text field (Plan a Trip's place field, the place picker's search)
@MainActor func announceToScreenReaders(_ text: String) {
    // Posted to the window in use, as Apple's example in Swift for this notification does. Its example in Objective-C posts it
    // to the app: heard with VoiceOver, one posted to the app wasn't said in the first window after an install had opened the
    // app (whether the window helps there is still to be heard on a Mac). To the app when it has no such window
    let element: Any
    if let window = NSApp.keyWindow ?? NSApp.mainWindow { element = window } else { element = NSApplication.shared }
    NSAccessibility.post(element: element, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

/// Asks screen readers to look at the key window's contents again, a moment from now (once what just appeared is in place), and
/// half a second later tells them where the keyboard is, so that their cursor comes to the text field as it is in what they
/// have just looked at (Plan a Trip and the place picker, as they open and as their suggestions appear).
/// Heard with VoiceOver: taken into a window as it first opens after the app starts, with the keyboard already in a text field,
/// it takes the field as standing alone, not in its group, and never finds the clear button and the suggestions beside it;
/// closing the window and opening it again puts that right. Asked to look again, it finds the group, but its cursor stays on
/// the field as it knew it, and the next item from there is the window's close button; told where the keyboard is without
/// being asked to look, nothing changes. So both, in this order (whether the cursor then follows is still to be heard on a Mac)
@MainActor func askScreenReadersToLookAgainSoon() {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        guard let window = NSApp.keyWindow else { return }
        var changed: [Any] = [window]
        if let content = window.contentView { changed.append(content) }
        NSAccessibility.post(element: window, notification: .layoutChanged, userInfo: [.uiElements: changed])
        try? await Task.sleep(for: .milliseconds(500))
        // Only while the keyboard is still in a text field of that window: it is in the window's field editor then, whose
        // delegate is the field
        guard NSApp.keyWindow === window, let editor = window.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField else { return }
        NSAccessibility.post(element: field, notification: .focusedUIElementChanged)
    }
}
