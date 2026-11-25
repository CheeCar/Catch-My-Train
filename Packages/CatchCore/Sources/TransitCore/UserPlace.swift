import Foundation

/// A place the user picked (favorites, recent places, a manually chosen walking origin). Stores only the name and coordinates, on this Mac.
/// Don't rename the saved keys (name, latitude, longitude); places saved by older versions must still load (see SavedDataTests).
public struct UserPlace: Codable, Hashable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(name: String, coordinate: Coordinate) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    public init(_ preset: MockTransitData.Place) {
        self.init(name: preset.name, coordinate: preset.coordinate)
    }

    public static let `default` = UserPlace(MockTransitData.defaultPlace)

    /// The area this app covers, used to sanity-check picked places and manually entered coordinates: the New York metro area (see ServiceArea).
    public static func isInServiceArea(_ c: Coordinate) -> Bool {
        ServiceArea.containsWithMargin(c)
    }
}

/// Where walking starts from. A place nobody chose is never made up: with no chosen place and no position there is none, and the
/// app asks for a place instead of showing departures (Demo mode always has one: Times Square, or a place chosen in it).
public enum StartingPlace: Equatable, Sendable {
    /// The current location
    case current
    /// The chosen place
    case chosen
    /// The current location is wanted but can't be had (denied or failed): the chosen place for now
    case chosenFallback
    /// The current location is wanted and still being found
    case locating
    /// No place was ever chosen and there is no position to use
    case missing
    /// The current location is wanted, but the position is too far off to find the stations nearby (LocationAccuracy.tooApproximate):
    /// nothing nearby until it gets better or a place is chosen. Not the chosen place instead: that may be far from here
    case tooApproximate

    /// - Parameters:
    ///   - usesCurrentLocation: walking from "My current location" (not "A place I choose")
    ///   - hasPosition: a position is known
    ///   - positionTooApproximate: that position is too far off to use (LocationAccuracy.tooApproximate)
    ///   - locationFailed: location is denied or failed (also while it's tried again after a failure)
    ///   - hasChosenPlace: a place was chosen at some point
    public static func of(usesCurrentLocation: Bool, hasPosition: Bool, positionTooApproximate: Bool = false, locationFailed: Bool,
                          hasChosenPlace: Bool) -> StartingPlace {
        guard usesCurrentLocation else { return hasChosenPlace ? .chosen : .missing }
        if hasPosition { return positionTooApproximate ? .tooApproximate : .current }
        guard locationFailed else { return .locating }
        return hasChosenPlace ? .chosenFallback : .missing
    }

    /// Why there is no starting place (missing), for the few words shown where its name would be
    public enum MissingReason: Equatable, Sendable {
        /// Walking from "A place I choose", and none was ever chosen
        case notChosen
        /// The current location is wanted, but location access is off for the app
        case locationOff
        /// The current location is wanted and was tried, but no position came
        case locationFailed
    }

    /// With the current location wanted, what's missing is the location, not a choice: saying "no place chosen yet" there
    /// read as if the app had never tried. The way out is the same either way (choosing a place).
    public static func missingReason(usesCurrentLocation: Bool, locationDenied: Bool) -> MissingReason {
        guard usesCurrentLocation else { return .notChosen }
        return locationDenied ? .locationOff : .locationFailed
    }

    /// Whether the place picker opens by itself: with "A place I choose" and no place chosen yet, only choosing one helps.
    /// With the current location wanted it doesn't (location may still come back): the empty page has the button.
    public static func opensPicker(usesCurrentLocation: Bool, hasChosenPlace: Bool) -> Bool {
        !usesCurrentLocation && !hasChosenPlace
    }
}

/// How exact the current position is, from what macOS says (its horizontal accuracy, in meters). A Mac finds itself from the Wi‑Fi
/// networks around it, usually within some tens of meters; on a wired network only, or where that data is wrong, it can be kilometers
/// off, while the walking range is 10 to 20 minutes. The app and the widget go by the same steps
public enum LocationAccuracy: Equatable, Sendable {
    case fine
    /// Said under the place's name ("within about …"); the stations are listed as usual
    case approximate
    /// Too far off to find the stations nearby: the position isn't used (as when it can't be had), and the app says so
    case tooApproximate

    /// Worse than this (meters): approximate
    public static let approximateFrom: Double = 300
    /// Worse than this (meters): too approximate
    public static let tooApproximateFrom: Double = 3000

    /// nil or negative (macOS doesn't know): taken as fine, as before accuracy was looked at
    public static func of(meters: Double?) -> LocationAccuracy {
        guard let meters, meters >= 0 else { return .fine }
        if meters > tooApproximateFrom { return .tooApproximate }
        if meters > approximateFrom { return .approximate }
        return .fine
    }
}

/// A station's name and place, for finding it by name without the network (the place picker and Plan a Trip; see StationNames)
public struct StationName: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    /// Its routes, for their badges
    public var routes: [String]

    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }

    public init(id: String, name: String, coordinate: Coordinate, routes: [String]) {
        self.id = id
        self.name = name
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
        self.routes = routes
    }
}

/// The app's own station names, found by name without the network: the NYC Subway's, built in, and those of the timetables on
/// this Mac. Each timetable's are kept in a small list beside it, so a search reads no timetable
public enum StationNames {
    /// The fewest characters searched for
    public static let shortestSearch = 2

    /// A timetable's stations where a trip can be boarded, one for each station (piers that are one station, see pierGroups, under
    /// their shared name and the routes of them all), in the timetable's order
    public static func of(_ feed: FerryFeed) -> [StationName] {
        let routes = feed.routesByPier()
        let groups = feed.pierGroups()
        var result: [StationName] = []
        var groupAt: [String: Int] = [:]
        for pier in feed.piers {
            guard let pierRoutes = routes[pier.id] else { continue }
            guard let group = groups[pier.id] else {
                result.append(StationName(id: pier.id, name: pier.name, coordinate: pier.coordinate, routes: pierRoutes))
                continue
            }
            if let i = groupAt[group.group] {
                result[i].routes = Array(Set(result[i].routes).union(pierRoutes)).sorted()
            } else {
                groupAt[group.group] = result.count
                result.append(StationName(id: pier.id, name: group.name, coordinate: pier.coordinate, routes: pierRoutes))
            }
        }
        return result
    }

    /// The NYC Subway's built-in stations
    public static func of(_ catalog: StationCatalog) -> [StationName] {
        catalog.entries.map { StationName(id: $0.id, name: $0.name, coordinate: $0.coordinate, routes: $0.routes.map(\.route)) }
    }

    /// The ones with the text in their name (shortestSearch characters at least; case and accents aside): the names starting with
    /// it first, then the others, each in name order (numbers by their value); at most `limit`
    public static func matching(_ query: String, in names: [StationName], limit: Int) -> [StationName] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= shortestSearch else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var starting: [StationName] = []
        var containing: [StationName] = []
        for station in names {
            guard let range = station.name.range(of: text, options: options) else { continue }
            if range.lowerBound == station.name.startIndex { starting.append(station) } else { containing.append(station) }
        }
        let inOrder: (StationName, StationName) -> Bool = {
            let order = $0.name.compare($1.name, options: [.caseInsensitive, .numeric])
            return order != .orderedSame ? order == .orderedAscending : $0.id < $1.id
        }
        return Array((starting.sorted(by: inOrder) + containing.sorted(by: inOrder)).prefix(limit))
    }
}

/// Text checks for place search suggestions (search covers the US only).
public enum USAddress {
    /// The 50 states and DC
    public static let stateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC",
    ]

    /// A suggestion that looks like a US place: it says "United States" or has a state code after a comma (e.g. "Pickerington, OH 43147").
    /// Two capital letters alone aren't enough ("London, UK"). Ones with no subtitle (e.g. "Search Nearby") are kept;
    /// once one is chosen, its coordinates decide whether it's in the service area.
    public static func looksLikeUS(title: String, subtitle: String) -> Bool {
        let text = title + ", " + subtitle
        if text.contains("United States") { return true }
        if ["Canada", "Mexico", "Puerto Rico"].contains(where: { text.contains($0) }) { return false }
        if stateCode(in: text) { return true }
        return subtitle.isEmpty
    }

    /// ", XX" where XX is a state code followed by the end of the text or a non-letter
    static func stateCode(in text: String) -> Bool {
        let chars = Array(text)
        var i = 0
        while i + 3 < chars.count {
            if chars[i] == ",", chars[i + 1] == " " {
                let code = String(chars[(i + 2)...(i + 3)])
                let endsWord = i + 4 >= chars.count || !chars[i + 4].isLetter
                if endsWord, stateCodes.contains(code) { return true }
            }
            i += 1
        }
        return false
    }

    /// Search text long enough to ask Apple Maps for suggestions (shorter text shows none)
    public static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// Suggestions Apple Maps returned for `fragment` still fit a search field showing `query`: an edit or Clear since then makes them stale
    public static func suggestionsAreCurrent(fragment: String, query: String) -> Bool {
        fragment == query && isSearchable(query)
    }

    /// The text from which finding nothing is said (shorter ones are still being typed)
    public static let nothingFoundFrom = 3

    /// Whether to say no place in the US was found: none of the `found` results is kept (`kept`, the ones in the US), and either
    /// there were results (all elsewhere) or the text is long enough. It goes by the results only, never by where the Mac is
    public static func saysNothingFound(kept: Int, found: Int, for text: String) -> Bool {
        kept == 0 && (found > 0 || text.trimmingCharacters(in: .whitespaces).count >= nothingFoundFrom)
    }
}

/// Keeps a slow address lookup (Apple Maps) from replacing a newer choice.
/// Each lookup gets a number when it starts. A newer lookup makes the older ones stale, and so does `drop`, called when the user
/// chooses something else, clears the place, edits the search text, cancels or closes the window.
/// A stale result is ignored whether it found the place or not: no place change, nothing saved, no error.
public struct PlaceLookupGate: Equatable, Sendable {
    private var last = 0
    private var pending: Int?

    public init() {}

    /// A lookup is in flight and its result is still wanted
    public var isPending: Bool { pending != nil }

    /// Starts a lookup and returns its number (for `finish`). Any lookup still in flight becomes stale.
    public mutating func start() -> Int {
        last &+= 1
        pending = last
        return last
    }

    /// The user changed their choice: the lookup in flight, if any, becomes stale
    public mutating func drop() {
        pending = nil
    }

    /// Lookup `id` came back: true if its result is to be used (it's then no longer in flight), false if it's stale
    public mutating func finish(_ id: Int) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }

    /// The results screen opened again and still says loading, because closing it stopped the computation: start over,
    /// unless a lookup still in flight will start the computation itself when it lands.
    public func needsRestart(hasPlace: Bool, loading: Bool) -> Bool {
        hasPlace && loading && !isPending
    }
}
