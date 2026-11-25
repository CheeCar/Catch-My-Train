import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

extension PlacePickerSheet {
    // MARK: Left: search, favorites, recent places

    func leftColumn(_ l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            searchArea(l)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    placeCards(l)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
                }
                // The arrow keys moved to a card: bring it into view (a favorite: its box, which then scrolls to the card itself)
                .onChange(of: shownCard) { _, row in
                    guard let row else { return }
                    withAnimation(Motion.ease(0.2)) {
                        switch row {
                        case .favorite: scroller.scrollTo(Self.favoritesBoxID)
                        case .recent(let p): scroller.scrollTo(p)
                        }
                    }
                }
            }
        }
    }

    private func searchArea(_ l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Any address, place or station (Apple Maps search). Return picks the first suggestion, or then uses the selected place.
            // With networking turned off in Settings the field still finds the mode's stations by name (the app's own names, as in
            // Plan a Trip); Apple Maps isn't asked (see AddressSearch.query), and the note about that is on the right, where the map
            // would be. Demo mode searches its own places instead, without the network (DemoData.search)
            TextField(l.t("Address, place or station name"), text: $address.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel(Text(l.t("Search an address or place")))
                .onSubmit { submitSearch(l) }
                // ↓ / ↑ light a suggestion up, as in Plan a Trip's place field
                .onKeyPress(.downArrow) { moveHighlight(1, l) }
                .onKeyPress(.upArrow) { moveHighlight(-1, l) }
            // Not once a suggestion was picked (the field shows its name)
            if address.nothingFound, !transit.isDemo, address.query != suggestionsHiddenFor {
                Text(l.t("No places in the United States were found for this search. Try a station name or a different search."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let suggestions = shownSuggestions
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                        Button {
                            chooseSuggestion(s, l)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                // A station of the app's own names: its route badges beside it, as in Plan a Trip
                                HStack(spacing: 6) {
                                    if !s.routes.isEmpty {
                                        RouteBullets(routes: NearbyBoardBuilder.sortRoutes(s.routes), size: 13, limit: 6)
                                            .fixedSize()
                                    }
                                    Text(s.title).lineLimit(1)
                                }
                                if !s.subtitle.isEmpty {
                                    Text(s.subtitle).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        // A station's name is said before its lines
                        .accessibilityLabel(Text(RouteBullets.spoken(name: s.title, routes: NearbyBoardBuilder.sortRoutes(s.routes),
                                                                     detail: s.subtitle, l)))
                        // Lit up as in Plan a Trip: blue with white text (its gray line a lighter white), by the arrow keys or the
                        // mouse, one at a time; screen readers hear it as selected
                        .foregroundStyle(highlighted == i ? Color.white : Color.primary)
                        .background {
                            if highlighted == i {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).padding(.horizontal, 3)
                            }
                        }
                        .onHover { inside in
                            if inside { highlighted = i } else if highlighted == i { highlighted = nil }
                        }
                        .accessibilityAddTraits(highlighted == i ? .isSelected : [])
                    }
                }
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
                .contrastBorder(cornerRadius: 8)
                // The suggestions come under the field: screen readers are asked to look at the window again, as in Plan a Trip
                // (see the function)
                .onAppear { askScreenReadersToLookAgainSoon() }
            } else if transit.isDemo, !address.query.trimmingCharacters(in: .whitespaces).isEmpty, address.query != suggestionsHiddenFor {
                // Demo mode found nothing for the text: say what it knows, as the demo page does (it looks broken otherwise)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "theatermasks")
                        .accessibilityHidden(true)
                    Text(l.t("This demo knows only some famous places and the subway stations in Manhattan. Or click a place on the map."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
            }
            if let addressError {
                Text(addressError).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The field and what it found, one after the other for screen readers: they go by where things are in the window, and the
        // map's Recenter, across from the field, came between the field and its suggestions
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(l.t("Search an address or place")))
    }

    /// The suggestions under the search field: at most 5, so the lists stay in view; none once one is clicked, until the text changes.
    /// First the mode's stations with the text in their name (the app's own names, no network needed; at most 3, see StationSearch),
    /// then Apple Maps' places. Demo mode's are its own places: famous places in Manhattan and its subway stations
    var shownSuggestions: [PickerSuggestion] {
        guard address.query != suggestionsHiddenFor else { return [] }
        if transit.isDemo {
            let l = transit.l10n
            return DemoData.search(address.query, catalog: transit.catalog).map {
                PickerSuggestion(title: $0.name, subtitle: l.demoPlaceDetail($0), place: $0.userPlace)
            }
        }
        let stations = StationSearch.matching(address.query, system: transit.system, catalog: transit.catalog, limit: 3).map {
            PickerSuggestion(title: $0.name, subtitle: "", place: UserPlace(name: $0.name, coordinate: $0.coordinate), routes: $0.routes)
        }
        // Networking turned off in Settings: the stations only (Apple Maps' places need the network)
        guard transit.networkAllowed else { return stations }
        let places = address.suggestions.prefix(5 - stations.count).map {
            PickerSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        return stations + places
    }

    /// Favorites (at most 50, in the order they were dragged into) and the 10 most recently used places, all stored only on this
    /// Mac, as cards two to a row. Click a card to select it, double-click to use it at once; then the arrow keys move the selection.
    private func placeCards(_ l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            favoritesHeader(l)
            if favorites.isEmpty {
                // None (all removed, or a Mac that never had any): say how to add one
                Text(l.t("No favorites yet. Search for an address or use your current location, then click the star to save a place."))
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                favoritesBox(l)
                    .id(Self.favoritesBoxID)
            }
            if !recent.isEmpty {
                recentsHeader(l)
                    .padding(.top, 8)
                recentGrid(l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A click on a card gives the cards the keyboard focus (without a ring): the arrow keys then move the selection, Return uses it
        .focusable()
        .focused($cardsFocused)
        .focusEffectDisabled()
        // ⌥⌘← ⌥⌘→: the selected favorite moves left or right (its menu's Move Left and Move Right)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.contains(.command), press.modifiers.contains(.option),
                  case .row(.favorite(let p))? = choice,
                  let move = favoriteMove(p, left: press.key == .leftArrow) else { return .ignored }
            move()
            return .handled
        }
        .onMoveCommand { moveSelection($0) }
    }

    /// The favorites' title and count; with two or more, a line saying they can be dragged into order, beside the count or,
    /// where the column is too narrow for that, under the title
    private func favoritesHeader(_ l: UIText) -> some View {
        let reorder = favorites.count > 1
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                favoritesTitle(l)
                if reorder {
                    Text("·")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    reorderHint(l)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                favoritesTitle(l)
                if reorder {
                    reorderHint(l)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func favoritesTitle(_ l: UIText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(l.t("Favorite places")).font(.scaled(.headline))
            // The count next to the title (none while there are none), orange when full
            if !favorites.isEmpty {
                Text(l.f("%@ of %@", "\(favorites.count)", "\(SharedStore.maxFavorites)"))
                    .font(.scaled(.caption))
                    .foregroundStyle(favoritesFull ? Color.noticeOrange : Color.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func reorderHint(_ l: UIText) -> some View {
        Text(l.t("Drag to reorder"))
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
    }

    private func recentsHeader(_ l: UIText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(l.t("Recent places")).font(.scaled(.headline))
            Text(l.f("%@ of %@", "\(recent.count)", "\(SharedStore.recentPlacesLimit)"))
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            // A small button like Undo below and the sidebar's Change, not a link
            Button(l.t("Clear")) { confirmClear = true }
                .buttonStyle(SmallBezelButtonStyle())
                .font(.scaled(.caption))
                .lineLimit(1)
                .fixedSize()
                // The same question as for "Clear Recent Places…" in Settings
                .alert(l.t("Clear recent places?"), isPresented: $confirmClear) {
                    Button(l.t("Cancel"), role: .cancel) {}
                    Button(l.t("Clear"), role: .destructive) { clearRecents() }
                } message: {
                    Text(l.t("Favorites are kept."))
                }
        }
    }

    /// Favorite places in one box, two to a row. The box shows at most 5 rows (10 cards) and scrolls inside when there are more; with
    /// fewer rows it is shorter. Scrolling on over the box once it's at its end doesn't move the column around it (ScrollStaysInside).
    private func favoritesBox(_ l: UIText) -> some View {
        let rowHeight = Self.cardHeight, spacing: CGFloat = 8, inset: CGFloat = 8
        let rows = min(5, (favorites.count + 1) / 2)
        let height = CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * spacing + inset * 2
        return ScrollViewReader { scroller in
            ScrollView(.vertical) {
                favoritesGrid(l, rowHeight: rowHeight, spacing: spacing, scroller: scroller)
                    .padding(inset)
            }
            .scrollIndicators(favorites.count > 10 ? .automatic : .never)
            .frame(height: height)
            .background(ScrollStaysInside())
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .contrastBorder(cornerRadius: 10)
            // The arrow keys moved to a favorite: bring its card into view inside the box
            .onChange(of: shownCard) { _, row in
                guard case .favorite(let p)? = row else { return }
                withAnimation(Motion.ease(0.2)) { scroller.scrollTo(FavoriteSlot.place(p)) }
            }
        }
    }

    /// Favorites in two columns. Drag a card to move it, like an app icon on a phone's home screen: the card itself is picked up and follows
    /// the pointer, the others slide out of its way, and the new order is saved (recent places stay newest first). The grid is laid out left
    /// to right with each row's order set by FavoriteGrid, so the drag works out positions the same way in right-to-left languages;
    /// each card's own contents still follow the language.
    private func favoritesGrid(_ l: UIText, rowHeight: CGFloat, spacing: CGFloat, scroller: ScrollViewProxy) -> some View {
        let grid = FavoriteGrid(count: favorites.count, rightToLeft: transit.layoutDirection == .rightToLeft,
                                rowHeight: rowHeight, spacing: spacing, width: favoritesWidth)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)],
                         alignment: .leading, spacing: spacing) {
            ForEach(grid.slots(favorites), id: \.self) { slot in
                switch slot {
                case .place(let p):
                    favoriteCard(p, l, height: rowHeight, grid: grid, scroller: scroller)
                case .gap:
                    Color.clear.frame(height: rowHeight)
                }
            }
        }
        // Screen readers go through the cards in the favorites' order, also when a right-to-left row is reversed (see favoriteCard)
        .accessibilityElement(children: .contain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FavoritesWidth.self, value: g.size.width)
        })
        // Store only a real change: storing redraws the grid, which reports its width again
        .onPreferenceChange(FavoritesWidth.self) { w in
            if abs(w - favoritesWidth) > 0.5 { favoritesWidth = w }
        }
        .overlay(alignment: .topLeading) {
            if let lift {
                liftedCard(lift, l, height: rowHeight, width: grid.cellWidth)
            }
        }
        .onChange(of: draggingFavorite) { _, dragging in
            if !dragging { drop(grid) }
        }
        .coordinateSpace(name: FavoriteGrid.space)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func favoriteCard(_ p: UserPlace, _ l: UIText, height: CGFloat, grid: FavoriteGrid,
                              scroller: ScrollViewProxy) -> some View {
        placeCard(.favorite(p), l, height: height)
            .environment(\.layoutDirection, transit.layoutDirection)
            .accessibilitySortPriority(Double(favorites.count - (favorites.firstIndex(of: p) ?? 0)))
            // While picked up, the card is drawn above the grid (liftedCard) and its place here stays empty
            .opacity(lift?.place == p ? 0 : 1)
            // Alongside the card's own buttons: a click still selects, stars or removes; moving the mouse while pressed picks the card up
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(FavoriteGrid.space))
                    .updating($draggingFavorite) { _, dragging, _ in dragging = true }
                    .onChanged { drag(p, $0, grid, scroller) }
                    .onEnded { _ in drop(grid) }
            )
    }

    /// The picked-up card: a little larger, with a shadow, and solid so the cards under it don't show through.
    /// The lift fits in the box's 8 pt margin, so the box's edge doesn't cut it.
    private func liftedCard(_ lift: FavoriteLift, _ l: UIText, height: CGFloat, width: CGFloat) -> some View {
        PlaceCard(place: lift.place, isFavorite: true, favoriteRow: true, inUse: inUse(lift.place),
                  selected: choice == .row(.favorite(lift.place)), height: height, l: l)
            .environment(\.layoutDirection, transit.layoutDirection)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .scaleEffect(lift.settling ? 1 : 1.03)
            .shadow(color: .black.opacity(lift.settling ? 0 : 0.2), radius: 4, y: 2)
            .offset(x: lift.origin.x, y: lift.origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Pick a favorite up and move it with the pointer, within the grid. Once the middle of the card is over another card's place, that one
    /// and the ones between move along to make room; the order is saved at each step, so it stays even if the window closes during the drag.
    private func drag(_ place: UserPlace, _ value: DragGesture.Value, _ grid: FavoriteGrid, _ scroller: ScrollViewProxy) {
        guard grid.width > 0, let from = favorites.firstIndex(of: place) else { return }
        if lift?.place != place || lift?.settling == true {
            let origin = grid.origin(of: from)
            lift = FavoriteLift(place: place,
                                grab: CGSize(width: value.startLocation.x - origin.x, height: value.startLocation.y - origin.y),
                                origin: origin)
            justDragged = true
            NSCursor.closedHand.set()
        }
        guard let grab = lift?.grab else { return }
        let origin = grid.liftOrigin(pointer: value.location, grab: grab)
        lift?.origin = origin
        let to = grid.index(at: CGPoint(x: origin.x + grid.cellWidth / 2, y: origin.y + grid.rowHeight / 2))
        guard to != from else { return }
        withAnimation(Motion.ease(0.2)) {
            favorites.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        if keepsPlaces { SharedStore.reorderFavorites(favorites) }
        // With more favorites than the box shows, bring the card's new row into view (after the grid has moved it there)
        Task { @MainActor in
            withAnimation(Motion.ease(0.2)) { scroller.scrollTo(FavoriteSlot.place(place)) }
        }
    }

    /// Let go: the card glides into its new place, then shows in the grid again. Called both when the drag ends and when it stops
    /// being active, so the second call does nothing.
    private func drop(_ grid: FavoriteGrid) {
        guard lift?.settling != true else { return }
        NSCursor.arrow.set()
        guard let current = lift, let index = favorites.firstIndex(of: current.place) else {
            lift = nil
            justDragged = false
            return
        }
        withAnimation(Motion.ease(0.15)) {
            lift?.origin = grid.origin(of: index)
            lift?.settling = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            // Another card may have been picked up in the meantime
            guard lift == nil || lift?.settling == true else { return }
            lift = nil
            justDragged = false
        }
    }

    /// Recent places (at most 10, newest first): the same cards, two to a row, without a box and without dragging
    private func recentGrid(_ l: UIText) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(recent, id: \.self) { p in
                placeCard(.recent(p), l, height: Self.cardHeight)
            }
        }
    }

    /// A card in either list. The same place can be in both: each has its own card, and the card says which list it is in
    private func placeCard(_ row: PickerRow, _ l: UIText, height: CGFloat) -> some View {
        let p = row.place
        return PlaceCard(place: p, isFavorite: row.isFavorite || favorites.contains { SharedStore.samePlace($0, p) },
                         favoriteRow: row.isFavorite, canAddFavorite: !favoritesFull, inUse: inUse(p), selected: choice == .row(row), height: height,
                         l: l,
                         click: { clickCard(row, count: $0) },
                         use: {
                             guard !justDragged else { return }
                             select(.row(row))
                             self.use()
                         },
                         toggleFavorite: { if !justDragged { toggleFavorite(p) } },
                         remove: { if !justDragged { removeCard(row) } },
                         moveLeft: row.isFavorite ? favoriteMove(p, left: true) : nil,
                         moveRight: row.isFavorite ? favoriteMove(p, left: false) : nil)
    }

    /// Moving a favorite one place left or right on screen, for the keyboard and screen readers (dragging needs a mouse): earlier or
    /// later in the order, the other way around in a right-to-left language (the first card of a line is on the right there). nil when
    /// it can't go that way (the first or last card)
    private func favoriteMove(_ p: UserPlace, left: Bool) -> (() -> Void)? {
        guard let i = favorites.firstIndex(of: p) else { return nil }
        let step = left == (transit.layoutDirection == .rightToLeft) ? 1 : -1
        guard favorites.indices.contains(i + step) else { return nil }
        return { moveFavorite(p, by: step) }
    }

    /// Moves a favorite one place on in the order (step 1) or back (-1), saved at once as after a drag; the card stays selected and
    /// in view
    private func moveFavorite(_ p: UserPlace, by step: Int) {
        guard !justDragged, let i = favorites.firstIndex(of: p), favorites.indices.contains(i + step) else { return }
        withAnimation(Motion.ease(0.2)) {
            favorites.move(fromOffsets: IndexSet(integer: i), toOffset: step > 0 ? i + 2 : i - 1)
        }
        if keepsPlaces { SharedStore.reorderFavorites(favorites) }
        shownCard = .favorite(p)
    }

    /// A click on a card selects it (the map moves there, also when it was selected already); a double click uses it at once. Either
    /// way the cards get the keyboard focus, so the arrow keys move the selection from there
    private func clickCard(_ row: PickerRow, count: Int) {
        guard !justDragged else { return }
        cardsFocused = true
        if count < 2 || choice != .row(row) { select(.row(row)) }
        if count >= 2 { use() }
    }

    /// Remove on a card (× on a recent place, the menu on either): a favorite leaves the favorites, a recent place leaves the recent
    /// places
    private func removeCard(_ row: PickerRow) {
        switch row {
        case .favorite(let p): toggleFavorite(p)
        case .recent(let p): removeRecent(p)
        }
    }

    /// The cards in order (favorites, then recent places), each with its line from the top and its column (0: the first in its line)
    private var cardPositions: [CardPosition] {
        var cards: [CardPosition] = []
        for (i, p) in favorites.enumerated() {
            cards.append(CardPosition(row: .favorite(p), line: i / 2, column: i % 2))
        }
        let favoriteLines = (favorites.count + 1) / 2
        for (i, p) in recent.enumerated() {
            cards.append(CardPosition(row: .recent(p), line: favoriteLines + i / 2, column: i % 2))
        }
        return cards
    }

    /// The arrow keys, once a card was clicked: up and down go to the card above or below (from the favorites on to the recent
    /// places), left and right to the card before or after it (the other way around in a right-to-left language, where the first card
    /// of a line is on the right). With no card selected, the first card gets selected.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let cards = cardPositions
        guard !cards.isEmpty else { return }
        guard case .row(let current)? = choice, let i = cards.firstIndex(where: { $0.row == current }) else {
            show(cards[0].row)
            return
        }
        let here = cards[i]
        var target: Int?
        if direction == .up || direction == .down {
            let line = here.line + (direction == .up ? -1 : 1)
            let inLine = cards.indices.filter { cards[$0].line == line }
            target = inLine.first { cards[$0].column == here.column } ?? inLine.last
        } else if direction == .left || direction == .right {
            let forward = (direction == .right) != (transit.layoutDirection == .rightToLeft)
            let j = forward ? i + 1 : i - 1
            target = cards.indices.contains(j) ? j : nil
        }
        if let target { show(cards[target].row) }
    }

    /// Select a card and scroll the lists to it
    private func show(_ row: PickerRow) {
        select(.row(row))
        shownCard = row
    }

    /// Where walking times are measured from now: its cards get a check (not for Plan a Trip or the current location)
    private func inUse(_ p: UserPlace) -> Bool {
        !transit.pickerForPlanner && transit.locationMode == .manual && transit.hasPlace && SharedStore.samePlace(p, transit.place)
    }

    /// Where "Use My Current Location" is: the Mac's location, or in Demo mode Times Square
    var currentSpot: Coordinate? {
        transit.isDemo ? DemoData.home.coordinate : transit.currentCoordinate
    }
}
