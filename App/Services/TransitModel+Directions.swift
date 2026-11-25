import AppKit
import CatchText
import CoreLocation
import MapKit
import TransitCore

extension TransitModel {
    /// "Directions" on the station page and in a train's details: nil when there is no button (networking turned off in
    /// Settings, since opening a map is going online; no starting point yet). The walk starts at the app's starting point, the
    /// one the walk times are worked out from (in Demo mode its own place, never where the Mac is), under its name in the app;
    /// the Mac's own current location goes as the map's own (no name)
    var directionsAction: DirectionsAction? {
        guard networkAllowed, let from = origin else { return nil }
        return DirectionsAction(origin: from.coordinate, originName: from.kind == .current ? nil : from.name,
                                map: directionsMap, mapName: l10n.mapName(directionsMap))
    }
}

/// What "Directions" opens: the walk from `origin` to a station, in the map app chosen in Settings. Handed down from the main window
/// to its station page (environment value `directions`), so a departure's details, which don't watch the main model, have it too
struct DirectionsAction {
    var origin: Coordinate
    /// The starting point's name as the app shows it (a chosen place, Demo mode's place); nil when it is where the Mac is
    var originName: String?
    var map: DirectionsMap
    /// The map app's name in the app's language, for the button's hover text
    var mapName: String

    /// A button for the walk to `destination`
    func offers(_ destination: Coordinate) -> Bool {
        WalkingDirections.isOffered(networkAllowed: true, origin: origin, destination: destination)
    }

    /// Apple Maps: the Mac's own Maps app, given both places, walking, each under its name (the station's; a chosen place's,
    /// which came from the map's own search; where the Mac is goes as the map's own current location). Should that not open,
    /// Apple's map link does the same, with the two positions only. Google Maps: its directions address with the two positions
    /// only, opened by macOS in the default browser
    @MainActor
    func open(to destination: Coordinate, name: String) {
        guard offers(destination), NetworkSwitch.isAllowed else { return }
        switch map {
        case .appleMaps:
            let start: MKMapItem
            if let originName {
                start = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(origin)))
                if !originName.isEmpty { start.name = originName }
            } else {
                start = MKMapItem.forCurrentLocation()
            }
            let end = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(destination)))
            end.name = name
            let opened = MKMapItem.openMaps(with: [start, end],
                                            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            if !opened, let url = WalkingDirections.appleMapsURL(from: origin, to: destination) { NSWorkspace.shared.open(url) }
        case .googleMaps:
            if let url = WalkingDirections.googleMapsURL(from: origin, to: destination) { NSWorkspace.shared.open(url) }
        }
    }

    private static func location(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }
}
