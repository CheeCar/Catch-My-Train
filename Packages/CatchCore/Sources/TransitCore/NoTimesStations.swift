import Foundation

// MARK: - Stations without times
//
// Some operators inside the service area publish no timetable or live data the app can use (no GTFS, only web pages or none),
// so there are no departures to show. Their stations and piers are still listed, with a gray "No times" tag, a sentence saying why,
// and a button that opens the operator's own page for the station: the user learns the station is there and where to look.
//
// Where the positions come from (no map service's positions are used):
// - Piers: the ferry terminal data of the US Bureau of Transportation Statistics (National Transportation Atlas Database,
//   public domain). It notes that some points are an operator's address rather than the landing itself, so a pier can be
//   off by a block or two; walking times are estimates anyway.
// - The piers that aren't in that data (the two at Patchogue, Edgartown's Chappy Ferry slip, Plymouth's State Pier and Viking
//   Fleet's Montauk dock): their street addresses on the operator's website, looked up with the US Census Bureau's address
//   search (public domain). Montauk's address has three matches up to 500 m apart; the one on the street the website names
//   (W Lake Dr) is used.
// - AirTrain JFK: the station positions in the Port Authority's AirTrain timetable data once published through 511NY (only the
//   positions are used; the stations haven't moved). Terminal 6 is served by the Terminal 5 and Terminal 7 stations.
// An operator whose data can't give its times is listed here too: the Steamship Authority's has every boat leaving and never
// arriving (each trip is its first pier, repeated), so where and when it gets in isn't known and nothing is made up.
// When an operator starts publishing its times, its stations move to a real data source and leave this list.

/// An operator whose stations are listed without times
public struct NoTimesAgency: Hashable, Sendable {
    /// Its part of its stations' IDs ("notimes:<key>:<station>"): stays the same when a name changes
    public let key: String
    /// The operator's own name: the sentence on the station page and the sidebar popover's "Without times" line say it
    public let name: String
    /// The name in the small box on its stations (shorter where the full name is long)
    public let shortName: String
    /// The mode whose lists show its stations: AirTrain with Subway, the boats with Ferry
    public let mode: TransitSystem
    /// How often it runs, in minutes, where its own website says so (nil where it doesn't)
    public let headwayMinutes: ClosedRange<Int>?
    /// Two terminals facing each other across the water, with no way to walk from one to the other (North Ferry, South Ferry,
    /// the Governors Island ferry): a nearby list shows only the terminal nearer the place, the one on its side of the water
    public let crossesWater: Bool

    public init(key: String, name: String, shortName: String, mode: TransitSystem, headwayMinutes: ClosedRange<Int>? = nil,
                crossesWater: Bool = false) {
        self.key = key
        self.name = name
        self.shortName = shortName
        self.mode = mode
        self.headwayMinutes = headwayMinutes
        self.crossesWater = crossesWater
    }
}

/// A station or pier of such an operator
public struct NoTimesStation: Hashable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let agency: NoTimesAgency
    /// The operator's own page for this station: its timetable, or the main page where the times are on it
    public let website: URL

    /// As a station of the nearby list: its walk is always the straight-line estimate (Apple Maps isn't asked, see
    /// WalkEstimator.asksForRoute), and it's never grouped with a station that has times (no complex)
    public var station: Station { Station(id: id, name: name, coordinate: coordinate) }
}

public enum NoTimesStations {
    /// Every station without times has an ID starting with this, so it's told apart from every data source's own IDs
    public static let idPrefix = "notimes:"

    public static func isNoTimes(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    // Operators. The headways are what their websites say: AirTrain JFK "every 5-15 minutes", North Ferry "every 8 to 15 minutes",
    // South Ferry "every 10-15 minutes", and the Governors Island ferry every 30 minutes, every 15 at busy times on weekends.
    public static let airTrainJFK = NoTimesAgency(key: "airtrain-jfk", name: "AirTrain JFK", shortName: "AirTrain JFK",
                                                  mode: .subway, headwayMinutes: 5...15)
    public static let fireIslandFerries = NoTimesAgency(key: "fire-island-ferries", name: "Fire Island Ferries",
                                                        shortName: "Fire Island Ferries", mode: .ferry)
    public static let sayvilleFerry = NoTimesAgency(key: "sayville-ferry", name: "Sayville Ferry Service", shortName: "Sayville Ferry",
                                                    mode: .ferry)
    public static let davisParkFerry = NoTimesAgency(key: "davis-park-ferry", name: "Davis Park Ferry", shortName: "Davis Park Ferry",
                                                     mode: .ferry)
    public static let crossSoundFerry = NoTimesAgency(key: "cross-sound-ferry", name: "Cross Sound Ferry", shortName: "Cross Sound Ferry",
                                                      mode: .ferry)
    public static let portJeffersonFerry = NoTimesAgency(key: "port-jefferson-ferry", name: "Bridgeport & Port Jefferson Ferry",
                                                         shortName: "Port Jefferson Ferry", mode: .ferry)
    public static let northFerry = NoTimesAgency(key: "north-ferry", name: "North Ferry", shortName: "North Ferry", mode: .ferry,
                                                 headwayMinutes: 8...15, crossesWater: true)
    public static let southFerry = NoTimesAgency(key: "south-ferry", name: "South Ferry", shortName: "South Ferry", mode: .ferry,
                                                 headwayMinutes: 10...15, crossesWater: true)
    public static let governorsIslandFerry = NoTimesAgency(key: "governors-island-ferry", name: "Governors Island Ferry",
                                                           shortName: "Governors Island Ferry", mode: .ferry, headwayMinutes: 15...30,
                                                           crossesWater: true)
    // Around Greater Boston: the Steamship Authority (Woods Hole to Martha's Vineyard, Hyannis to Nantucket), the Island Queen
    // (Falmouth to Oak Bluffs, in summer) and the summer boat from Boston to Provincetown
    public static let steamshipAuthority = NoTimesAgency(key: "steamship-authority", name: "Steamship Authority",
                                                         shortName: "Steamship Authority", mode: .ferry)
    public static let islandQueen = NoTimesAgency(key: "island-queen", name: "Island Queen", shortName: "Island Queen", mode: .ferry)
    public static let cityCruisesProvincetown = NoTimesAgency(key: "city-cruises-provincetown", name: "City Cruises Provincetown Ferry",
                                                              shortName: "City Cruises", mode: .ferry)
    // Around Narragansett Bay, Martha's Vineyard, Plymouth and Block Island: the Jamestown Newport Ferry (in summer), the boat from
    // Bristol to Prudence Island, the Chappy Ferry (Edgartown to Chappaquiddick), Captain John's summer boat from Plymouth to
    // Provincetown, and the summer boats to Block Island from New London and Montauk. Where two operators use one pier (New
    // London, Provincetown), each has a station of its own there, with its own website
    public static let jamestownNewportFerry = NoTimesAgency(key: "jamestown-newport-ferry", name: "Jamestown Newport Ferry",
                                                            shortName: "Jamestown Newport Ferry", mode: .ferry)
    public static let prudenceFerry = NoTimesAgency(key: "prudence-ferry", name: "Prudence & Bay Islands Transport",
                                                    shortName: "Prudence Ferry", mode: .ferry)
    public static let chappyFerry = NoTimesAgency(key: "chappy-ferry", name: "Chappy Ferry", shortName: "Chappy Ferry", mode: .ferry)
    public static let captainJohn = NoTimesAgency(key: "captain-john", name: "Captain John Boats", shortName: "Captain John",
                                                  mode: .ferry)
    public static let blockIslandExpress = NoTimesAgency(key: "block-island-express", name: "Block Island Express",
                                                         shortName: "Block Island Express", mode: .ferry)
    public static let vikingFleet = NoTimesAgency(key: "viking-fleet", name: "Viking Fleet", shortName: "Viking Fleet", mode: .ferry)

    /// The operators in the source list in use (see SourceList), in the order the sidebar popover lists them; one turned off isn't among them
    public static var agencies: [NoTimesAgency] { SourceList.current.noTimesAgencies }

    /// The operators in code, in the popover's order
    public static let builtInAgencies: [NoTimesAgency] = [
        airTrainJFK, fireIslandFerries, sayvilleFerry, davisParkFerry, crossSoundFerry, portJeffersonFerry, northFerry, southFerry,
        governorsIslandFerry, steamshipAuthority, islandQueen, cityCruisesProvincetown, jamestownNewportFerry, prudenceFerry,
        chappyFerry, captainJohn, blockIslandExpress, vikingFleet,
    ]

    private static func place(_ agency: NoTimesAgency, _ slug: String, _ name: String, _ latitude: Double, _ longitude: Double,
                              _ website: String) -> NoTimesStation {
        NoTimesStation(id: idPrefix + agency.key + ":" + slug, name: name,
                       coordinate: Coordinate(latitude: latitude, longitude: longitude), agency: agency,
                       website: URL(string: website)!)
    }

    private static let airTrainPage = "https://www.jfkairport.com/transportation/airtrain"
    private static let crossSoundPage = "https://www.longislandferry.com/Schedules/Schedules.aspx"
    private static let portJeffersonPage = "https://www.88844ferry.com/schedule"
    private static let northFerryPage = "https://www.northferry.com/schedule.html"
    private static let southFerryPage = "https://southferry.com/"
    private static let governorsIslandPage = "https://www.govisland.com/plan-your-visit/ferry"
    private static let steamshipPage = "https://www.steamshipauthority.com/schedules"
    private static let islandQueenPage = "https://islandqueen.com/schedule/"
    private static let cityCruisesProvincetownPage = "https://citycruises.com/tickets/boston/bostons-provincetown-cape-cod-fast-ferry"
    private static let jamestownNewportPage = "https://www.jamestownnewportferry.com/"
    private static let prudencePage = "https://www.prudenceferry.com/"
    private static let chappyPage = "https://chappyferry.com/chappy-ferry-schedule/"
    private static let captainJohnPage = "https://www.captjohn.com/"
    private static let blockIslandExpressPage = "https://www.goblockisland.com/"
    private static let vikingFleetPage = "https://vikingfleet.com/schedule-fares/montauk-to-block-island-ferry/"

    /// The stations in the source list in use, less those of an operator turned off
    public static var all: [NoTimesStation] { SourceList.current.noTimesStations }

    /// The stations in code
    public static let builtInStations: [NoTimesStation] = [
        place(airTrainJFK, "jamaica", "Jamaica", 40.698942, -73.808416, airTrainPage),
        place(airTrainJFK, "howard-beach", "Howard Beach", 40.661051, -73.829638, airTrainPage),
        place(airTrainJFK, "lefferts-blvd", "Lefferts Blvd", 40.661767, -73.824456, airTrainPage),
        place(airTrainJFK, "federal-circle", "Federal Circle", 40.659814, -73.803502, airTrainPage),
        place(airTrainJFK, "terminal-1", "Terminal 1", 40.643616, -73.789437, airTrainPage),
        place(airTrainJFK, "terminal-4", "Terminal 4", 40.644072, -73.782367, airTrainPage),
        place(airTrainJFK, "terminal-5", "Terminal 5", 40.646900, -73.780067, airTrainPage),
        place(airTrainJFK, "terminal-7", "Terminal 7", 40.648207, -73.783171, airTrainPage),
        place(airTrainJFK, "terminal-8", "Terminal 8", 40.646734, -73.788997, airTrainPage),

        place(fireIslandFerries, "bay-shore", "Bay Shore", 40.715592, -73.242443, "https://fireislandferries.com/schedules"),
        place(fireIslandFerries, "kismet", "Kismet", 40.638267, -73.204684, "https://fireislandferries.com/schedules/kismet"),
        place(fireIslandFerries, "saltaire", "Saltaire", 40.641517, -73.199432, "https://fireislandferries.com/schedules/saltaire"),
        place(fireIslandFerries, "fair-harbor", "Fair Harbor", 40.641155, -73.186283, "https://fireislandferries.com/schedules/fair-harbor"),
        place(fireIslandFerries, "dunewood", "Dunewood", 40.641941, -73.180193, "https://fireislandferries.com/schedules/dunewood"),
        place(fireIslandFerries, "atlantique", "Atlantique", 40.642968, -73.173702, "https://fireislandferries.com/schedules/atlantique"),
        place(fireIslandFerries, "ocean-beach", "Ocean Beach", 40.649272, -73.156519, "https://fireislandferries.com/schedules/ocean-beach"),
        place(fireIslandFerries, "seaview", "Seaview", 40.648951, -73.150414, "https://fireislandferries.com/schedules/seaview"),
        place(fireIslandFerries, "ocean-bay-park", "Ocean Bay Park", 40.651276, -73.139885,
              "https://fireislandferries.com/schedules/ocean-bay-park"),

        place(sayvilleFerry, "sayville", "Sayville", 40.72718, -73.071548, "https://www.sayvilleferry.com/"),
        place(sayvilleFerry, "cherry-grove", "Cherry Grove", 40.660753, -73.090023, "https://www.sayvilleferry.com/cherry-grove"),
        place(sayvilleFerry, "fire-island-pines", "Fire Island Pines", 40.665469, -73.069307, "https://www.sayvilleferry.com/fire-island-pines"),
        place(sayvilleFerry, "sailors-haven", "Sailors Haven", 40.657216, -73.104672, "https://www.sayvilleferry.com/sailors-haven"),
        place(sayvilleFerry, "water-island", "Water Island", 40.673995, -73.042212, "https://www.sayvilleferry.com/water-island"),

        place(davisParkFerry, "patchogue-sandspit-marina", "Patchogue \u{2013} Sandspit Marina", 40.750443, -73.016169,
              "https://www.davisparkferry.com/dp-schedule"),
        place(davisParkFerry, "patchogue-watch-hill-terminal", "Patchogue \u{2013} Watch Hill Terminal", 40.759174, -73.017018,
              "https://www.davisparkferry.com/wh-schedule"),

        place(crossSoundFerry, "new-london", "New London", 41.355833, -72.092575, crossSoundPage),
        place(crossSoundFerry, "orient-point", "Orient Point", 41.154151, -72.240463, crossSoundPage),

        place(portJeffersonFerry, "bridgeport", "Bridgeport", 41.17534738, -73.185381, portJeffersonPage),
        place(portJeffersonFerry, "port-jefferson", "Port Jefferson", 40.948155, -73.070359, portJeffersonPage),

        place(northFerry, "greenport", "Greenport", 41.100237, -72.361733, northFerryPage),
        place(northFerry, "shelter-island-heights", "Shelter Island Heights", 41.087382, -72.358132, northFerryPage),

        place(southFerry, "shelter-island", "Shelter Island", 41.044519, -72.31722, southFerryPage),
        place(southFerry, "north-haven", "North Haven", 41.039725, -72.315369, southFerryPage),

        place(governorsIslandFerry, "battery-maritime-building", "Battery Maritime Building", 40.700767, -74.011666, governorsIslandPage),
        place(governorsIslandFerry, "soissons-landing", "Soissons Landing", 40.693205, -74.01504, governorsIslandPage),

        place(steamshipAuthority, "woods-hole", "Woods Hole", 41.522294, -70.670169, steamshipPage),
        place(steamshipAuthority, "vineyard-haven", "Vineyard Haven", 41.455758, -70.600193, steamshipPage),
        place(steamshipAuthority, "oak-bluffs", "Oak Bluffs", 41.458609, -70.554466, steamshipPage),
        place(steamshipAuthority, "hyannis", "Hyannis", 41.650914, -70.276963, steamshipPage),
        place(steamshipAuthority, "nantucket", "Nantucket", 41.286193, -70.096106, steamshipPage),

        place(islandQueen, "falmouth", "Falmouth", 41.550807, -70.600513, islandQueenPage),
        place(islandQueen, "oak-bluffs", "Oak Bluffs", 41.459968, -70.557834, islandQueenPage),

        place(cityCruisesProvincetown, "long-wharf", "Long Wharf", 42.359945, -71.048073, cityCruisesProvincetownPage),
        place(cityCruisesProvincetown, "provincetown", "Provincetown", 42.049221, -70.181432, cityCruisesProvincetownPage),

        place(jamestownNewportFerry, "jamestown", "Jamestown", 41.49645, -71.365645, jamestownNewportPage),
        place(jamestownNewportFerry, "rose-island", "Rose Island", 41.49521, -71.341588, jamestownNewportPage),
        place(jamestownNewportFerry, "fort-adams", "Fort Adams", 41.478077, -71.334883, jamestownNewportPage),
        place(jamestownNewportFerry, "ann-street-pier", "Ann Street Pier", 41.483356, -71.316159, jamestownNewportPage),
        place(jamestownNewportFerry, "perrotti-park", "Perrotti Park", 41.489276, -71.317683, jamestownNewportPage),

        place(prudenceFerry, "bristol", "Bristol", 41.668323, -71.278762, prudencePage),
        place(prudenceFerry, "prudence-island", "Prudence Island", 41.618955, -71.304125, prudencePage),

        place(chappyFerry, "edgartown", "Edgartown", 41.389327, -70.510821, chappyPage),

        place(captainJohn, "plymouth", "Plymouth", 41.955445, -70.661566, captainJohnPage),
        place(captainJohn, "provincetown", "Provincetown", 42.049221, -70.181432, captainJohnPage),

        place(blockIslandExpress, "new-london", "New London", 41.355833, -72.092575, blockIslandExpressPage),
        place(blockIslandExpress, "old-harbor", "Block Island – Old Harbor", 41.173521, -71.557314, blockIslandExpressPage),

        place(vikingFleet, "montauk", "Montauk", 41.071599, -71.941629, vikingFleetPage),
        place(vikingFleet, "new-harbor", "Block Island – New Harbor", 41.184289, -71.581288, vikingFleetPage),
    ]

    static let builtInByID: [String: NoTimesStation] = Dictionary(builtInStations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func station(id: String) -> NoTimesStation? { SourceList.current.noTimesByID[id] }

    /// The operators of this mode (Subway: AirTrain JFK; Ferry: the boats), in the popover's order
    public static func agencies(for mode: TransitSystem) -> [NoTimesAgency] {
        agencies.filter { $0.mode == mode.mode }
    }

    /// The stations of this mode
    public static func stations(for mode: TransitSystem) -> [NoTimesStation] {
        all.filter { $0.agency.mode == mode.mode }
    }

    /// The stations of this mode near a place, nearest first (like the tram's). Of an operator that crosses the water
    /// (`crossesWater`), only the terminal nearer the place: the other one is across the water, reached by its boat and not on
    /// foot, though a straight line makes it look a short walk away (Soissons Landing is 890 m from the Battery Maritime Building)
    public static func stations(_ mode: TransitSystem, near coordinate: Coordinate, radiusMeters: Double) -> [Station] {
        let byDistance = stations(for: mode)
            .map { ($0, WalkEstimator.distanceMeters(coordinate, $0.coordinate)) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
        var crossings = Set<String>()
        var result: [Station] = []
        for (place, meters) in byDistance {
            // The nearer terminal comes first, so a second one of the same crossing is on the far side
            if place.agency.crossesWater, !crossings.insert(place.agency.key).inserted { continue }
            if meters <= radiusMeters { result.append(place.station) }
        }
        return result
    }
}

extension BoardStation {
    /// The station without times this row is (NoTimesStations); nil for every station with departures
    public var noTimes: NoTimesStation? {
        stations.count == 1 ? NoTimesStations.station(id: stations[0].id) : nil
    }
}

extension NearbyBoard {
    /// The board without the stations that have no times: the menu bar panel and the widgets show departures only, so they pick
    /// from the stations with times (a station without times selected in the main window shows the nearest one with times there)
    public func withoutNoTimesStations() -> NearbyBoard {
        var board = self
        board.stations.removeAll { $0.noTimes != nil }
        return board
    }
}
