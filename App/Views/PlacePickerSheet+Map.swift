import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

extension PlacePickerSheet {
    // MARK: Right: map, the selected place, current location, the large map

    /// The large map is shown instead of the two columns (Open Larger Map until Back; never with networking turned off)
    var showsLargeMap: Bool { largeMap && transit.networkAllowed }

    /// The right column, or the large map: the same map in both (it grows into the large one), with the selected place under it.
    /// The rest of the column only in the two columns
    func rightColumn(_ l: UIText) -> some View {
        let large = showsLargeMap
        return VStack(alignment: .leading, spacing: 10) {
            if transit.networkAllowed {
                pickerMap(l, large: large)
            } else {
                // Networking turned off in Settings: no map (it needs the network). The lists still work
                NetworkOffNote(l: l, large: true)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(OutlineColor(), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            chosenRow(l)
            if !large {
                useCurrentLocationButton(l)
                // Demo mode uses no location
                if transit.isDemo {
                    EmptyView()
                } else if !transit.locationAllowed {
                    LocationOffNote(l: l)
                } else if transit.locationAccessOff {
                    LocationAccessNotice(compact: true)
                } else if !currentLocationUsable {
                    // For Plan a Trip the location must be known already (it's found only while the app is on and walks from there):
                    // why the button is grayed out, under it
                    Label(l.t("Your current location is known only while the app is on and walking times are from “My current location”."),
                          systemImage: "location")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                openLargeMapButton(l)
            }
        }
        .padding(.horizontal, large ? 20 : 16)
        .padding(.vertical, 14)
    }

    /// The map: the small one in the right column, or the large one
    private func pickerMap(_ l: UIText, large: Bool) -> some View {
        // The same map on every open (either purpose), moved back to this purpose's place (PickerMap's opened): a map view taken
        // away isn't always let go of, and a new one for each open stayed in memory
        PickerMap(l: l, large: large, system: transit.system, start: mapStart, focus: focus, selected: selectedCoordinate,
                  marker: mapMarker(l), hint: transit.pickerForPlanner ? nil : l.t("Click the map to choose where to walk from."),
                  opened: transit.pickerOpenCount, onTap: { dropPin($0, l) })
    }

    /// Where the map opens: for Plan a Trip at the place it has already, else where walking times are measured from now
    /// nil with no location and no place chosen yet: the map opens on the whole service area
    private var mapStart: Coordinate? {
        if transit.pickerForPlanner, let c = transit.plannerMapStart { return c }
        return transit.origin?.coordinate ?? (transit.hasPlace ? transit.place.coordinate : nil)
    }

    /// Where the selection is, for Recenter
    private var selectedCoordinate: Coordinate? {
        switch choice {
        case .row(let row)?: return row.place.coordinate
        case .found(let p)?: return p.coordinate
        case .pin(let c, _)?: return c
        case .current?: return currentSpot
        case .finding?, nil: return nil
        }
    }

    /// What the map marks: the selection; with nothing selected, where walking times are measured from now (not for Plan a Trip).
    /// The current location is MapKit's own dot while the app is running (like the transit map), else a plain marker
    private func mapMarker(_ l: UIText) -> PickerMarker? {
        let live = transit.isActive && transit.locationAllowed && !transit.locationAccessOff
        switch choice {
        case .row(let row)?: return PickerMarker(name: row.place.name, coordinate: row.place.coordinate)
        case .found(let p)?: return PickerMarker(name: p.name, coordinate: p.coordinate)
        case .pin(let c, let name)?: return PickerMarker(name: name ?? l.t("Place on the map"), coordinate: c)
        case .finding?: return nil
        // Demo mode's current location is Times Square, marked with its name (never the Mac's own location)
        case .current? where transit.isDemo: return PickerMarker(name: DemoData.home.name, coordinate: DemoData.home.coordinate)
        case .current?: return transit.currentCoordinate.map { PickerMarker(name: nil, coordinate: $0, live: live) }
        case nil:
            guard !transit.pickerForPlanner, let origin = transit.origin else { return nil }
            if origin.kind == .current { return PickerMarker(name: nil, coordinate: origin.coordinate, live: live) }
            return PickerMarker(name: origin.name, coordinate: origin.coordinate)
        }
    }

    /// Under the map: the selected place with its star (add to or remove from favorites), or what's still being found; in Demo mode,
    /// after a click outside Manhattan, that it has times only there (the selection stays as it was)
    private func chosenRow(_ l: UIText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            chosenPlaceRow(l)
            if demoOutside {
                Label(l.t("This demo has times only for Manhattan. Click a place in Manhattan."), systemImage: "exclamationmark.triangle")
                    .font(.scaled(.caption))
                    .foregroundStyle(Color.noticeOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chosenPlaceRow(_ l: UIText) -> some View {
        HStack(spacing: 8) {
            switch choice {
            // Nothing selected yet (so each time the window opens): what to do next, and why Use This Place is grayed out
            case nil:
                Text(l.t("Select a place, or click the map.")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .finding?, .pin(_, .none)?:
                Image(systemName: "mappin").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(l.t("Finding the address…")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .current?:
                Image(systemName: "location.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(l.t("Current location")).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                currentStar(l)
            default:
                if let p = chosenPlace {
                    Image(systemName: "mappin").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(p.name).fontWeight(.semibold).lineLimit(1).truncationMode(.tail).help(p.name)
                    Spacer(minLength: 4)
                    chosenStar(p, l)
                }
            }
        }
        // Only the space after the name stretches, so the star sits at the end of the row
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private func chosenStar(_ p: UserPlace, _ l: UIText) -> some View {
        let isFavorite = favorites.contains { SharedStore.samePlace($0, p) }
        let help = isFavorite ? l.t("Remove from favorites") : favoritesFull ? fullText(l) : l.t("Add to favorites")
        return StarButton(isFavorite: isFavorite, enabled: isFavorite || !favoritesFull, help: help,
                          label: isFavorite || favoritesFull ? help : l.f("Add %@ to favorites", p.name)) {
            starChosen(p)
        }
    }

    /// The current location's star: saves the spot as a favorite, named by its address; again removes that favorite. In Demo mode
    /// the spot is Times Square, filled while it's a favorite
    private func currentStar(_ l: UIText) -> some View {
        let saved = (currentSaved ?? (transit.isDemo ? DemoData.home : nil)).flatMap { s in favorites.first { SharedStore.samePlace($0, s) } }
        let help = saved != nil ? l.t("Remove from favorites") : favoritesFull ? fullText(l) : l.t("Add to favorites")
        let enabled = saved != nil || (!favoritesFull && currentSpot != nil && savingCurrent == nil)
        return StarButton(isFavorite: saved != nil, enabled: enabled, help: help, label: help) {
            if let saved {
                toggleFavorite(saved)
                currentSaved = nil
            } else {
                saveCurrent(l)
            }
        }
    }

    private func useCurrentLocationButton(_ l: UIText) -> some View {
        Button {
            select(.current)
        } label: {
            // Two lines when the app draws it at a larger text size, rather than cut short
            Label(l.t("Use My Current Location"), systemImage: "location.fill")
                .lineLimit(TextScale.factor == 1 ? 1 : 2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .appButtonStyle(.bordered)
        .disabled(!currentLocationUsable)
    }

    /// The current location can be used: "Use my location" on in Settings and allowed by macOS; for Plan a Trip it must be known already.
    /// Always in Demo mode (Times Square)
    var currentLocationUsable: Bool {
        if transit.isDemo { return true }
        return transit.locationAllowed && !transit.locationAccessOff && (!transit.pickerForPlanner || transit.currentCoordinate != nil)
    }

    /// The large map instead of the two columns, in the same window (Back returns). Grayed out with networking turned off in Settings
    private func openLargeMapButton(_ l: UIText) -> some View {
        Button {
            // The search field goes away with the two columns: Return then uses the selected place
            searchFocused = false
            largeMap = true
        } label: {
            Label(l.t("Open Larger Map"), systemImage: "arrow.up.left.and.arrow.down.right")
                .lineLimit(TextScale.factor == 1 ? 1 : 2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .appButtonStyle(.bordered)
        .disabled(!transit.networkAllowed)
    }
}
