import Foundation
import MapKit
import TransitCore

extension PlannerModel {
    // MARK: Place

    /// Selects a search suggestion: look up its coordinates with Apple Maps.
    /// The answer is used only if the user hasn't chosen another place, cleared it or edited the search since (otherwise a slow answer would replace the newer choice).
    func choose(_ completion: MKLocalSearchCompletion, transit: TransitModel) {
        picked()
        // Demo mode never asks Apple Maps (its suggestions are its own places, see choose(demo:))
        guard NetworkSwitch.isAllowed, !transit.isDemo else { return }
        let request = MKLocalSearch.Request(completion: completion)
        let lookup = addressLookup.start()
        Task {
            let response = await MapsRequest.search(request)
            // Stale: ignore it, found or not (no error either for a place the user no longer wants)
            guard addressLookup.finish(lookup) else { return }
            guard let item = response?.mapItems.first else {
                status = .failed(Note { $0.t("Couldn't find that place.") })
                return
            }
            let c = item.placemark.coordinate
            let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
            place = Place(name: completion.title, subtitle: completion.subtitle, coordinate: coordinate)
            suggestions = []
            // Closed meanwhile: nothing would stop the computation (standby included); it starts when the trip planner is shown again (see resume)
            guard isShown else {
                status = .loading
                stopped = true
                return
            }
            update(transit: transit)
        }
    }

    /// A subway station can also be picked directly (no online search).
    func choose(station entry: StationName, transit: TransitModel) {
        picked()
        place = Place(name: entry.name, subtitle: "", coordinate: entry.coordinate)
        suggestions = []
        update(transit: transit)
    }

    /// One of Demo mode's places, from its search (no online lookup: it knows where it is)
    func choose(demo found: DemoData.Place, transit: TransitModel) {
        picked()
        place = Place(name: found.name, subtitle: found.detail, coordinate: found.coordinate, lines: found.lines)
        suggestions = []
        update(transit: transit)
    }

    /// A place picked in the place picker window (map, favorites or recents). In Demo mode one of its places, in Manhattan
    func choose(place picked: UserPlace, transit: TransitModel) {
        setDemo(transit.isDemo)
        query = picked.name
        self.picked()
        place = Place(name: picked.name, subtitle: "", coordinate: picked.coordinate)
        update(transit: transit)
    }

    /// A point clicked on Plan a Trip's large map and used (Use This Place): called `name` ("Place on the map") at once and
    /// computed, then renamed by its address when Apple Maps finds one, as a pin in the place picker is. The address only renames it:
    /// nothing is computed again. Demo mode and networking turned off look nothing up
    func choose(mapPoint c: Coordinate, name: String, transit: TransitModel) {
        choose(place: UserPlace(name: name, coordinate: c), transit: transit)
        naming?.cancel()
        guard NetworkSwitch.isAllowed, !transit.isDemo else { return }
        naming = Task {
            let mark = await MapsRequest.placemark(of: CLLocation(latitude: c.latitude, longitude: c.longitude))
            // Another place chosen meanwhile, or the field edited: leave it
            guard !Task.isCancelled, place?.coordinate == c, pickedText == name,
                  let found = mark?.name ?? mark?.thoroughfare else { return }
            place?.name = found
            place?.subtitle = mark?.locality ?? ""
            // The field shows the new name; set as picked first, so it isn't searched for (see query)
            pickedText = found
            query = found
        }
    }

    /// An item was selected: collapse the suggestion list right away and drop any search results and address lookup still pending
    private func picked() {
        pickedText = query
        completer?.cancel()
        retry.reset()
        addressLookup.drop()
        suggestions = []
        nothingFound = false
    }

    func clearPlace() {
        task?.cancel()
        naming?.cancel()
        PlacesInUse.set(.planner, [])
        addressLookup.drop()
        computedWith = nil
        place = nil
        stations = []
        walks = [:]
        arrivals = []
        status = .idle
        dataKind = nil
    }

    /// Demo mode turned on or off (seen when it happens, or when the trip planner is shown again): the place and the search text
    /// are cleared, so a place looked up for real never shows in Demo mode (often shown to others) and a demo place doesn't stay
    /// once it's off. The departure time and the time range stay
    func setDemo(_ on: Bool) {
        guard on != inDemo else { return }
        inDemo = on
        completer?.cancel()
        pickedText = nil
        query = ""
        clearPlace()
    }
}
