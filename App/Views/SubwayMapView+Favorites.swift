import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension SubwayMapView {
    // MARK: Favorite places

    /// The starting point as a place, when it's a chosen one (not the current location): a favorite there gets no star of its
    /// own, as its pin is there
    private var originPlace: UserPlace? {
        guard let origin = transit.origin, origin.kind != .current else { return nil }
        return UserPlace(name: origin.name, coordinate: origin.coordinate)
    }

    /// Changes to the favorites are saved
    private var keepsPlaces: Bool {
        return true
    }

    func reloadFavorites() {
        let saved = SharedStore.favoritePlaces
        if saved != favorites { favorites = saved }
    }

    /// Favorites are full (50)
    private var favoritesFull: Bool { favorites.count >= SharedStore.maxFavorites }

    private func fullText(_ l: UIText) -> String {
        l.f("Favorites are full (%@). Remove one to add another.", "\(SharedStore.maxFavorites)")
    }

    /// The favorites' stars where the map is now (FavoriteMarks): each favorite's own, a small one on its station's dot, or one for
    /// several close together. None for the starting point
    func favoriteStars(_ screen: MapScreen, size: CGSize) -> [FavoriteStarSpot] {
        let list = favorites
        guard !list.isEmpty, size.width > 40, size.height > 40 else { return [] }
        let lists = dotLists(stationRanges)
        let onStations = FavoriteMarks.stations(of: list, on: lists.all)
        let byID = lists.byID
        let points: [FavoriteMarks.Point] = FavoriteMarks.drawn(list, origin: originPlace).compactMap { i in
            // A station's favorite stands on the station's dot
            let c = onStations[i].flatMap { byID[$0] }.map { Coordinate(latitude: $0.lat, longitude: $0.lon) } ?? list[i].coordinate
            guard let p = screen.point(c) else { return nil }
            return FavoriteMarks.Point(index: i, coordinate: c, x: Double(p.x), y: Double(p.y))
        }
        let l = transit.l10n
        var spots = FavoriteMarks.marks(points).map { mark in
            FavoriteStarSpot(places: mark.members.map { list[$0] }, coordinate: mark.coordinate, center: CGPoint(x: mark.x, y: mark.y),
                             onStation: mark.count == 1 && onStations[mark.members[0]] != nil, l: l)
        }
        // A star the starting point's pin (or the current location's dot) would cover goes just beside it, so the pin's head opens
        // the starting point's card: to the right, or the left (right-to-left: the left first, as the labels)
        if let origin = transit.origin, let p = screen.point(origin.coordinate) {
            func box(_ r: CGRect) -> FavoriteMarks.Box {
                FavoriteMarks.Box(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
            }
            let shifts = FavoriteMarks.offsets(spots.map { box($0.frame) }, clearOf: box(Self.originFrame(at: p, dot: originIsDot)),
                                               viewWidth: Double(size.width), rightToLeft: layoutDirection == .rightToLeft)
            for (i, shift) in shifts.enumerated() { spots[i].shift = CGFloat(shift) }
        }
        return spots
    }

    /// A star clicked: one favorite's opens its card; one for several zooms in until they come apart, or lists them when they
    /// can't (FavoriteMarks.zoom)
    func clickStar(_ spot: FavoriteStarSpot, size: CGSize) {
        guard spot.count > 1 else {
            if let place = spot.places.first { openCard(.favorite(place)) }
            return
        }
        switch FavoriteMarks.zoom(spot.places.map(\.coordinate), viewWidth: Double(size.width), viewHeight: Double(size.height)) {
        case .area(let x, let y, let width, let height):
            closeCards()
            withAnimation(Motion.ease(0.4)) { position = .rect(MKMapRect(x: x, y: y, width: width, height: height)) }
        case .list:
            openCard(.list(spot.places))
        }
    }

    /// The star's card is open: its favorite's, or the list of the favorites it stands for
    func isOpen(_ spot: FavoriteStarSpot) -> Bool {
        switch placeCard {
        case .favorite(let p)?: return spot.count == 1 && spot.places.first.map { SharedStore.samePlace($0, p) } == true
        case .list(let places)?: return places == spot.places
        default: return false
        }
    }

    /// The spot clicked on the empty map, while its card is open
    var pinSpot: (coordinate: Coordinate, name: String?)? {
        guard case .pin(let c, let name)? = placeCard else { return nil }
        return (c, name)
    }

    /// Where the starting point's pin, or the current location's dot, is on the map's view, for a click on it
    func originFrame(_ screen: MapScreen) -> CGRect? {
        guard let origin = transit.origin, let p = screen.point(origin.coordinate) else { return nil }
        return Self.originFrame(at: p, dot: originIsDot)
    }

    /// The starting point's mark around its point on the view: the pin stands above it, the current location's dot is round on it
    static func originFrame(at p: CGPoint, dot: Bool) -> CGRect {
        dot ? CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24) : CGRect(x: p.x - 16, y: p.y - 42, width: 32, height: 46)
    }

    /// The starting point shows as the current location's dot (MapKit's), not a pin: the current location, while not on standby
    var originIsDot: Bool {
        transit.origin?.kind == .current && transit.isActive
    }

    /// The bottom of originFrame where a station's dot under the starting point gets the click first: the pin's point, the lower
    /// half of the current location's dot
    static let originPointHeight: CGFloat = 12

    /// Opens a card other than a station's, in place of the one open
    func openCard(_ card: MapPlaceCard) {
        naming?.cancel()
        naming = nil
        withAnimation(Motion.ease(0.2)) {
            selected = nil
            placeCard = card
        }
    }

    func closeCards() {
        naming?.cancel()
        naming = nil
        withAnimation(Motion.ease(0.2)) {
            selected = nil
            placeCard = nil
        }
    }

    /// The click count of the mouse click being handled (2: a double click); 1 for anything else, as in the place picker
    @MainActor static var clickCount: Int {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp else { return 1 }
        return event.clickCount
    }

    /// A station's card opened
    func closePlaceCard() {
        naming?.cancel()
        naming = nil
        placeCard = nil
    }

    /// A click on the empty map with no card open: a pin there and its card, which looks the address up with Apple Maps (e.g.
    /// "W 40th St"; "Place on the map" when none is found), as the place picker does. Demo mode: only in Manhattan, named without
    /// looking it up
    func dropPin(_ c: Coordinate) {
        let l = transit.l10n
        if transit.isDemo {
            openCard(DemoArea.contains(c) ? .pin(c, l.t("Place on the map")) : .demoOutside)
            return
        }
        openCard(.pin(c, nil))
        naming = Task {
            var mark: CLPlacemark?
            // Networking turned off in Settings (the map isn't shown then): don't look the address up
            if NetworkSwitch.isAllowed {
                // Another card, or closing this one, cancels this task, and with it the lookup (see MapsRequest)
                mark = await MapsRequest.placemark(of: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
            guard !Task.isCancelled, placeCard == .pin(c, nil) else { return }
            naming = nil
            placeCard = .pin(c, mark?.name ?? mark?.thoroughfare ?? l.t("Place on the map"))
        }
    }

    /// Adds a place to the favorites (the same list as the place picker's) or takes it out. Taken out, "Removed …" and Undo show on
    /// its card, and ⌘Z puts it back
    private func toggleFavorite(_ place: UserPlace) {
        guard keepsPlaces else { return }
        let before = SharedStore.favoritePlaces
        SharedStore.toggleFavorite(place)
        reloadFavorites()
        if let index = before.firstIndex(where: { SharedStore.samePlace($0, place) }) {
            noteRemoved(RemovedPlace(place: before[index], favorite: true, index: index))
        } else if let r = removed, SharedStore.samePlace(r.place, place) {
            // Added again with its star: nothing to undo any more
            undoManager?.removeAllActions(withTarget: r)
            withAnimation(Motion.ease(0.2)) { removed = nil }
        }
    }

    /// After a favorite was taken out on a card: the note with Undo on the card for 10 seconds (a newer one takes its place), and
    /// an undo for ⌘Z. Either puts it back where it was in the list, as in the place picker
    private func noteRemoved(_ r: RemovedPlace) {
        undoManager?.registerUndo(withTarget: r) { r in putBack(r) }
        withAnimation(Motion.ease(0.2)) { removed = r }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if removed === r { withAnimation(Motion.ease(0.2)) { removed = nil } }
        }
    }

    /// Undo: the favorite goes back to where it was in the list, unless it's there again already or the favorites have filled up
    private func putBack(_ r: RemovedPlace) {
        if removed === r { withAnimation(Motion.ease(0.2)) { removed = nil } }
        guard keepsPlaces else { return }
        var list = SharedStore.favoritePlaces
        guard !list.contains(where: { SharedStore.samePlace($0, r.place) }), list.count < SharedStore.maxFavorites else { return }
        list.insert(r.place, at: min(r.index, list.count))
        SharedStore.favoritePlaces = list
        // The commute presets that walked from it do again
        SharedStore.favoritePutBack(r.place)
        reloadFavorites()
    }

    /// A card's star: filled for a favorite (clicking takes it out, with Undo), empty otherwise (clicking adds it; gray while the
    /// favorites are full)
    func starButton(_ place: UserPlace, l: UIText) -> some View {
        let isFavorite = favorites.contains { SharedStore.samePlace($0, place) }
        let help = isFavorite ? l.t("Remove from favorites") : favoritesFull ? fullText(l) : l.t("Add to favorites")
        return StarButton(isFavorite: isFavorite, enabled: isFavorite || !favoritesFull, help: help,
                          label: isFavorite || favoritesFull ? help : l.f("Add %@ to favorites", place.name)) {
            toggleFavorite(place)
        }
    }

    /// The current location's star: saves the spot as a favorite named by its address, as the place picker does; again takes that
    /// favorite out
    private func currentStar(_ l: UIText) -> some View {
        let saved = currentSaved.flatMap { s in favorites.first { SharedStore.samePlace($0, s) } }
        let help = saved != nil ? l.t("Remove from favorites") : favoritesFull ? fullText(l) : l.t("Add to favorites")
        let enabled = saved != nil || (!favoritesFull && naming == nil && transit.origin != nil)
        return StarButton(isFavorite: saved != nil, enabled: enabled, help: help, label: help) {
            if let saved {
                toggleFavorite(saved)
            } else {
                saveCurrent(l)
            }
        }
    }

    /// Saves the current location as a favorite, named by its address (or "Place on the map" when none is found)
    private func saveCurrent(_ l: UIText) {
        guard let c = transit.origin?.coordinate, !favoritesFull, keepsPlaces else { return }
        naming?.cancel()
        naming = Task {
            var mark: CLPlacemark?
            if NetworkSwitch.isAllowed {
                mark = await MapsRequest.placemark(of: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
            guard !Task.isCancelled else { return }
            naming = nil
            let place = UserPlace(name: mark?.name ?? mark?.thoroughfare ?? l.t("Place on the map"), coordinate: c)
            if !favorites.contains(where: { SharedStore.samePlace($0, place) }) { toggleFavorite(place) }
            if SharedStore.favoritePlaces.contains(where: { SharedStore.samePlace($0, place) }) { currentSaved = place }
        }
    }

    /// Use This Place: walks from the place from now on, as the place picker's button does (into the recent places too). The main
    /// window follows, and the map moves there unless it was moved by hand. A clicked spot's card becomes the starting point's
    private func useButton(_ place: UserPlace, l: UIText) -> some View {
        Button(l.t("Use This Place")) {
            transit.walk(from: place, remember: keepsPlaces)
            if pinSpot != nil { openCard(.origin) }
        }
        .appButtonStyle(.prominent)
        .lineLimit(1)
        .fixedSize()
    }

    /// On the card of the place just taken out of the favorites: "Removed" and its name, and Undo, which puts it back where it was
    /// (⌘Z does the same), as in the place picker
    @ViewBuilder
    func removedNote(for place: UserPlace, l: UIText) -> some View {
        if let r = removed, SharedStore.samePlace(r.place, place) {
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
        }
    }

    /// A card other than a station's: the same size, in the same place
    @ViewBuilder
    func placeCardView(_ card: MapPlaceCard, l: UIText) -> some View {
        switch card {
        case .favorite(let place): favoriteCard(place, l: l)
        case .origin: originCard(l)
        case .pin(let c, let name): pinCard(c, name: name, l: l)
        case .list(let places): listCard(places, l: l)
        case .demoOutside: demoOutsideCard(l)
        }
    }

    /// A favorite's card (its star clicked): its star, its name, and Use This Place, or "Your starting point" when it's that already
    private func favoriteCard(_ place: UserPlace, l: UIText) -> some View {
        let isStart = originPlace.map { SharedStore.samePlace($0, place) } ?? false
        return mapCard {
            HStack(spacing: 10) {
                starButton(place, l: l)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.scaled(.headline))
                        .lineLimit(2)
                        .help(place.name)
                    if isStart {
                        Text(l.t("Your starting point"))
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !isStart { useButton(place, l: l) }
                closeButton(l)
            }
            removedNote(for: place, l: l)
        }
    }

    /// The starting point's card (its pin, or the current location's dot, clicked): its name ("Current location" for that), "Your
    /// starting point", and its star
    private func originCard(_ l: UIText) -> some View {
        let start = originPlace
        let name = transit.origin?.name ?? l.t("Current location")
        return mapCard {
            HStack(spacing: 10) {
                if let start {
                    starButton(start, l: l)
                } else {
                    currentStar(l)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.scaled(.headline))
                        .lineLimit(2)
                        .help(name)
                    Text(l.t("Your starting point"))
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                closeButton(l)
            }
            if let place = start ?? currentSaved { removedNote(for: place, l: l) }
        }
    }

    /// A clicked spot's card: its address once it's found ("Finding the address…" until then), its star and Use This Place
    private func pinCard(_ c: Coordinate, name: String?, l: UIText) -> some View {
        let place = name.map { UserPlace(name: $0, coordinate: c) }
        return mapCard {
            HStack(spacing: 10) {
                Image(systemName: "mappin")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let name {
                    Text(name)
                        .font(.scaled(.headline))
                        .lineLimit(2)
                        .help(name)
                } else {
                    Text(l.t("Finding the address…"))
                        .font(.scaled(.headline))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let place {
                    starButton(place, l: l)
                    useButton(place, l: l)
                } else {
                    // Nothing to save or use until it has a name
                    StarButton(isFavorite: false, enabled: false, help: l.t("Add to favorites"), label: l.t("Add to favorites")) {}
                    Button(l.t("Use This Place")) {}
                        .appButtonStyle(.prominent)
                        .lineLimit(1)
                        .fixedSize()
                        .disabled(true)
                }
                closeButton(l)
            }
            if let place { removedNote(for: place, l: l) }
        }
    }

    /// The favorites at one spot, too close together to come apart however far the map zooms in: their names, each opening its card
    private func listCard(_ places: [UserPlace], l: UIText) -> some View {
        mapCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l.f("Favorite places: %@", l.number(Double(places.count))))
                        .font(.scaled(.headline))
                    // A long list scrolls (fifty at one spot can be saved, if hardly ever)
                    if places.count > 6 {
                        ScrollView { listRows(places) }
                            .frame(height: 150)
                    } else {
                        listRows(places)
                    }
                }
                Spacer(minLength: 8)
                closeButton(l)
            }
        }
    }

    private func listRows(_ places: [UserPlace]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(places, id: \.self) { p in
                Button(p.name) { openCard(.favorite(p)) }
                    .buttonStyle(SmallBezelButtonStyle())
                    .lineLimit(1)
                    .help(p.name)
            }
        }
    }

    /// Demo mode, a click outside Manhattan: the demo has times only there (as in the place picker)
    private func demoOutsideCard(_ l: UIText) -> some View {
        mapCard {
            HStack(spacing: 10) {
                Label(l.t("This demo has times only for Manhattan. Click a place in Manhattan."), systemImage: "exclamationmark.triangle")
                    .font(.scaled(.caption))
                    .foregroundStyle(Color.noticeOrange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                closeButton(l)
            }
        }
    }

}
