import Foundation

/// The map app "Directions" opens the walk to a station in. The user's choice in Settings
public enum DirectionsMap: String, CaseIterable, Codable, Sendable {
    /// The Mac's own Maps app. The default: the app asks Apple Maps for its walking routes already, so nothing goes anywhere new
    case appleMaps
    /// Google Maps, in the browser: the starting point and the station go to Google
    case googleMaps

    public static let `default` = DirectionsMap.appleMaps

    /// The choice as it was stored. Nothing stored yet, or a map this version doesn't know (stored by a later one): the default
    public init(stored: String?) {
        self = stored.flatMap(DirectionsMap.init(rawValue:)) ?? .default
    }
}

/// "Directions": the walk from the app's starting point to a station, opened in a map app.
/// The walk always starts at the app's starting point: the minutes shown next to the button are for that walk, and a map left to
/// choose the start itself begins where the Mac is, which may be somewhere else (the starting point can be any chosen place) and
/// would also make the map look the Mac's position up.
public enum WalkingDirections {
    /// The button is there: the network may be used (opening a map is going online) and both ends of the walk are known
    public static func isOffered(networkAllowed: Bool, origin: Coordinate?, destination: Coordinate?) -> Bool {
        guard networkAllowed, let origin, let destination else { return false }
        return usable(origin) && usable(destination)
    }

    /// Google Maps' documented address for directions ("Maps URLs", api=1), walking, from `origin` to `destination`.
    /// It needs no key and opens in the browser. Nil when a position can't be used.
    public static func googleMapsURL(from origin: Coordinate, to destination: Coordinate) -> URL? {
        guard usable(origin), usable(destination) else { return nil }
        // The comma between latitude and longitude is written %2C, as Google's own examples do
        return URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(pair(origin, comma: "%2C"))"
                   + "&destination=\(pair(destination, comma: "%2C"))&travelmode=walking")
    }

    /// Apple's documented map link for directions (saddr, daddr, dirflg=w for walking), which the Mac opens in Maps.
    /// The app's own way is the system call that opens Maps with both places named; this is the other way to the same route,
    /// should that call not do. Nil when a position can't be used.
    public static func appleMapsURL(from origin: Coordinate, to destination: Coordinate) -> URL? {
        guard usable(origin), usable(destination) else { return nil }
        return URL(string: "https://maps.apple.com/?saddr=\(pair(origin, comma: ","))&daddr=\(pair(destination, comma: ","))&dirflg=w")
    }

    private static func usable(_ c: Coordinate) -> Bool {
        Coordinate.isUsable(latitude: c.latitude, longitude: c.longitude)
    }

    private static func pair(_ c: Coordinate, comma: String) -> String {
        decimal(c.latitude) + comma + decimal(c.longitude)
    }

    /// A position's number with 5 decimals (about 1 m: as exact as a walk needs, and no more of the place than that), always
    /// with "." and plain digits whatever the Mac's region is. Worked out in whole numbers, so no formatter's settings come in
    static func decimal(_ value: Double) -> String {
        let scaled = Int((abs(value) * 100_000).rounded())
        let fraction = String(scaled % 100_000)
        let digits = String(repeating: "0", count: 5 - fraction.count) + fraction
        return (value < 0 && scaled != 0 ? "-" : "") + String(scaled / 100_000) + "." + digits
    }
}
