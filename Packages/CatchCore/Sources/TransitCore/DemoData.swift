import Foundation

/// Demo mode's own data, the same as the interactive demo page's: where its "My current location" is, its places (the favorites,
/// the recent stations and the famous places its search finds), its train stations, piers and PATH stations with their lines, and
/// which subway lines stop at each station of its area in the daytime. Names, lines and where they go are the operators', from
/// their public timetables as the app reads them; the times Demo mode shows are made up (MockTransitData).
public enum DemoData {

    /// A place of the demo: its name, the line under the name in the place searches (in English, as the search reads it), and where
    /// it is. A subway station also keeps its lines, so the line under its name can be said in the UI language (AppText.demoPlaceDetail)
    public struct Place: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var detail: String
        public var coordinate: Coordinate
        /// A subway station's lines, as their badges show them ("B", "D", "6X"); none for the famous places
        public var lines: [String]

        public init(_ id: String, _ name: String, _ detail: String, _ latitude: Double, _ longitude: Double, lines: [String] = []) {
            self.id = id
            self.name = name
            self.detail = detail
            coordinate = Coordinate(latitude: latitude, longitude: longitude)
            self.lines = lines
        }

        public var userPlace: UserPlace { UserPlace(name: name, coordinate: coordinate) }
    }

    /// Demo mode's "My current location"
    public static let home = UserPlace(name: "Times Square, Manhattan", coordinate: Coordinate(latitude: 40.7557, longitude: -73.9871))

    /// Famous places in Manhattan: the first ten are the demo's favorites, and its search finds all of them
    public static let places: [Place] = [
        Place("times-square", "Times Square", "Midtown, New York, NY", 40.758, -73.9855),
        Place("grand-central", "Grand Central Terminal", "Midtown, New York, NY", 40.7527, -73.9772),
        Place("empire-state", "Empire State Building", "Midtown, New York, NY", 40.7484, -73.9857),
        Place("rockefeller", "Rockefeller Center", "Midtown, New York, NY", 40.7587, -73.9787),
        Place("bryant-park", "Bryant Park", "Midtown, New York, NY", 40.7536, -73.9832),
        Place("msg", "Madison Square Garden", "Midtown, New York, NY", 40.7505, -73.9934),
        Place("union-square", "Union Square", "Union Square, New York, NY", 40.7359, -73.9906),
        Place("one-wtc", "One World Trade Center", "Financial District, New York, NY", 40.7127, -74.0134),
        Place("seaport", "South Street Seaport", "Financial District, New York, NY", 40.7063, -74.0036),
        Place("battery-park", "Battery Park", "Financial District, New York, NY", 40.7036, -74.0154),
        Place("flatiron", "Flatiron Building", "Flatiron District, New York, NY", 40.7411, -73.9897),
        Place("washington-sq", "Washington Square Park", "Greenwich Village, New York, NY", 40.7308, -73.9973),
        Place("chelsea-market", "Chelsea Market", "Chelsea, New York, NY", 40.7424, -74.006),
        Place("hudson-yards", "Hudson Yards", "Hudson Yards, New York, NY", 40.7538, -74.002),
        Place("lincoln-center", "Lincoln Center", "Upper West Side, New York, NY", 40.7725, -73.9835),
        Place("carnegie-hall", "Carnegie Hall", "Midtown, New York, NY", 40.7651, -73.9799),
        Place("moma", "Museum of Modern Art", "Midtown, New York, NY", 40.7614, -73.9776),
        Place("nypl", "New York Public Library", "Midtown, New York, NY", 40.7532, -73.9822),
        Place("chrysler", "Chrysler Building", "Midtown, New York, NY", 40.7516, -73.9755),
        Place("un", "United Nations Headquarters", "Turtle Bay, New York, NY", 40.7489, -73.968),
        Place("saint-patricks", "St. Patrick's Cathedral", "Midtown, New York, NY", 40.7585, -73.976),
        Place("port-authority", "Port Authority Bus Terminal", "Midtown, New York, NY", 40.757, -73.9903),
        Place("penn", "Penn Station", "Midtown, New York, NY", 40.7506, -73.9935),
        Place("central-park-zoo", "Central Park Zoo", "Central Park, New York, NY", 40.7678, -73.9718),
        Place("met", "The Metropolitan Museum of Art", "Upper East Side, New York, NY", 40.7794, -73.9632),
        Place("amnh", "American Museum of Natural History", "Upper West Side, New York, NY", 40.7813, -73.974),
        Place("whitney", "Whitney Museum of American Art", "Meatpacking District, New York, NY", 40.7396, -74.0089),
        Place("city-hall", "City Hall Park", "Civic Center, New York, NY", 40.7126, -74.0066),
        Place("wall-street", "Wall Street", "Financial District, New York, NY", 40.706, -74.0088),
        Place("chinatown", "Chinatown", "Chinatown, New York, NY", 40.7158, -73.997),
        Place("soho", "SoHo", "SoHo, New York, NY", 40.7233, -74.003),
        Place("columbia", "Columbia University", "Morningside Heights, New York, NY", 40.8075, -73.9626),
        Place("apollo", "Apollo Theater", "Harlem, New York, NY", 40.81, -73.95),
        Place("st-john-divine", "Cathedral of St. John the Divine", "Morningside Heights, New York, NY", 40.8038, -73.9619),
        Place("cloisters", "The Met Cloisters", "Fort Tryon Park, New York, NY", 40.8649, -73.9318),
    ]

    /// The demo's favorites, in their order
    public static let favorites: [UserPlace] = places.prefix(10).map(\.userPlace)

    /// The commute presets Demo mode starts with, named as a user would name theirs: "Work" from its "My current location"
    /// (Times Square) by subway, "Home" from its favorite Grand Central Terminal by train, "Weekend" from its favorite Battery
    /// Park by ferry. The names are as written in English: the app shows them in its language (AppText.demoPresets). Fewer than
    /// the most there can be (CommutePresets.limit), so one can still be added in Demo mode
    public static let presets: [CommutePreset] = {
        func favorite(_ id: String) -> UserPlace? { places.first { $0.id == id }?.userPlace }
        return [
            CommutePreset(id: "demo-work", name: "Work", place: nil, system: .subway),
            CommutePreset(id: "demo-home", name: "Home", place: favorite("grand-central"), system: .train),
            CommutePreset(id: "demo-weekend", name: "Weekend", place: favorite("battery-park"), system: .ferry),
        ]
    }()

    /// The demo's recent places, newest first: four subway stations
    public static let recents: [UserPlace] = [
        UserPlace(name: "34 St-Herald Sq", coordinate: Coordinate(latitude: 40.749719, longitude: -73.987823)),
        UserPlace(name: "59 St-Columbus Circle", coordinate: Coordinate(latitude: 40.768296, longitude: -73.981736)),
        UserPlace(name: "W 4 St-Wash Sq", coordinate: Coordinate(latitude: 40.732338, longitude: -74.000495)),
        UserPlace(name: "Fulton St", coordinate: Coordinate(latitude: 40.710197, longitude: -74.007691)),
    ]

    // MARK: Search

    /// The demo's place search, standing in for Apple Maps: the famous places and the recent stations whose name or the line under
    /// it has the text, then, from two letters on, the subway stations of the demo's area whose names have it; five at most.
    /// A subway station is found once for each name in its complex ("Times Sq-42 St" once, with every line there).
    /// Without `stations`, only the famous places: Plan a Trip in subway mode lists the stations by themselves (stationSearch).
    public static func search(_ text: String, catalog: StationCatalog?, stations: Bool = true) -> [Place] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        func matches(_ p: Place) -> Bool { p.name.lowercased().contains(query) || p.detail.lowercased().contains(query) }
        guard stations else { return Array(places.filter(matches).prefix(5)) }
        let stationPlaces = StationPlaces(catalog: catalog)
        var found = (places + stationPlaces.recents).filter(matches)
        if query.count >= 2 {
            for entry in stationPlaces.entries where entry.name.lowercased().contains(query) {
                if let p = stationPlaces.place(of: entry.id), !found.contains(p) { found.append(p) }
            }
        }
        return Array(found.prefix(5))
    }

    /// Plan a Trip's subway stations for the text in subway mode, as for real but only the demo's area: from two letters on, the
    /// stations whose names have it, by name, four at most (each station of a complex by itself, as the station list has them)
    public static func stationSearch(_ text: String, catalog: StationCatalog?) -> [StationCatalog.Entry] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2, let catalog else { return [] }
        let found = catalog.entries.filter { DemoArea.includesStation($0.coordinate) && $0.name.lowercased().contains(query) }
        return Array(found.sorted { ($0.name, $0.id) < ($1.name, $1.id) }.prefix(4))
    }

    /// The subway stations of the demo's area as places: one for each complex and name, with every line of its stations
    /// ("Subway station (B, D, F, M, N, Q, R, W), New York, NY"), found by the ID of any of them
    struct StationPlaces {
        let entries: [StationCatalog.Entry]
        private var byID: [String: Place] = [:]
        private let recentIDs = ["D17", "A24", "A32", "A38"]

        init(catalog: StationCatalog?) {
            let area = (catalog?.entries ?? []).filter { DemoArea.includesStation($0.coordinate) }.sorted { $0.id < $1.id }
            entries = area
            let byStation = Dictionary(area.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // The recent stations first, so each names its own place
            let order = recentIDs.compactMap { byStation[$0] } + area
            var groups: [String: (first: StationCatalog.Entry, routes: [String])] = [:]
            var keyOf: [String: String] = [:]
            for entry in order {
                let key = (entry.complex ?? entry.id) + "|" + entry.name
                keyOf[entry.id] = key
                var group = groups[key] ?? (entry, [])
                group.routes += entry.routes.map(\.route)
                groups[key] = group
            }
            var places: [String: Place] = [:]
            for (key, group) in groups {
                let lines = NearbyBoardBuilder.sortRoutes(group.routes).map(MTARoute.badge)
                places[key] = Place("st-" + group.first.id, group.first.name,
                                    "Subway station (\(lines.joined(separator: ", "))), New York, NY",
                                    group.first.lat, group.first.lon, lines: lines)
            }
            for (id, key) in keyOf { byID[id] = places[key] }
        }

        /// The recent stations, as the search finds them
        var recents: [Place] { recentIDs.compactMap { byID[$0] } }

        func place(of stationID: String) -> Place? { byID[stationID] }
    }

    // MARK: Train stations, piers and PATH

    /// One of the demo's own train stations, piers or PATH stations, and its lines
    public struct Stop: Sendable {
        public var station: Station
        public var lines: [Line]

        /// Its routes, each once, in its lines' order
        public var routes: [String] {
            var result: [String] = []
            for line in lines where !result.contains(line.route) { result.append(line.route) }
            return result
        }
    }

    /// A line at one of the demo's own stations: where it goes each way from there (north is the station page's upper side, south
    /// the lower; nil: none that way), how many minutes apart it leaves, and whether its operator has only a timetable (its times
    /// then show the timetable mark, as they do for real)
    public struct Line: Sendable {
        public var route: String
        public var north: String?
        public var south: String?
        public var every: Double
        public var timetable: Bool
    }

    static func stop(_ id: String, _ name: String, _ latitude: Double, _ longitude: Double, platform: TimeInterval,
                     _ lines: [Line]) -> Stop {
        Stop(station: Station(id: id, name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude),
                              entranceToPlatformSeconds: platform), lines: lines)
    }

    static func line(_ route: String, north: String? = nil, south: String? = nil, every: Double, timetable: Bool = false) -> Line {
        Line(route: route, north: north, south: south, every: every, timetable: timetable)
    }

    /// Train stations in Manhattan. Amtrak and NJ Transit have only timetables (as when no NJ Transit account is entered).
    /// Amtrak's long-distance trains (really about one a day) are given four hours apart, so they seldom are among the next trains
    public static let trainStops: [Stop] = [
        stop("rail-penn", "Penn Station", 40.75059, -73.99358, platform: 120, [
            line("AMK-ACE", north: "Boston", south: "Washington", every: 60, timetable: true),
            line("AMK-ADK", north: "Montreal", every: 240, timetable: true),
            line("AMK-CAR", south: "Charlotte", every: 240, timetable: true),
            line("AMK-CDL", south: "Chicago", every: 240, timetable: true),
            line("AMK-CRE", south: "New Orleans", every: 240, timetable: true),
            line("AMK-EAE", north: "Burlington", every: 240, timetable: true),
            line("AMK-EMP", north: "Rensselaer", every: 60, timetable: true),
            line("AMK-KEY", south: "Harrisburg", every: 60, timetable: true),
            line("AMK-LSL", north: "Chicago", every: 240, timetable: true),
            line("AMK-ML", north: "Toronto", every: 240, timetable: true),
            line("AMK-NER", north: "Boston", south: "Washington", every: 30, timetable: true),
            line("AMK-PAL", south: "Savannah", every: 240, timetable: true),
            line("AMK-PEN", south: "Pittsburgh", every: 240, timetable: true),
            line("AMK-SM", south: "Miami", every: 240, timetable: true),
            line("AMK-VT", north: "St Albans", south: "Washington", every: 240, timetable: true),
            line("LIRR-BAB", north: "Babylon", every: 30),
            line("LIRR-CTZ", north: "Jamaica", every: 60),
            line("LIRR-FR", north: "Far Rockaway", every: 30),
            line("LIRR-HEM", north: "Hempstead", every: 30),
            line("LIRR-LB", north: "Long Beach", every: 30),
            line("LIRR-MTK", north: "Montauk", every: 120),
            line("LIRR-OB", north: "Oyster Bay", every: 60),
            line("LIRR-PJ", north: "Huntington", every: 30),
            line("LIRR-PW", north: "Port Washington", every: 30),
            line("LIRR-RON", north: "Ronkonkoma", every: 30),
            line("LIRR-WH", north: "West Hempstead", every: 60),
            line("NJT-GLA", south: "Gladstone", every: 60, timetable: true),
            line("NJT-M&E", south: "Dover", every: 30, timetable: true),
            line("NJT-MOB", south: "MSU", every: 60, timetable: true),
            line("NJT-NEC", south: "Trenton Transit Center", every: 20, timetable: true),
            line("NJT-NJC", south: "Long Branch", every: 30, timetable: true),
            line("NJT-RVL", south: "High Bridge", every: 60, timetable: true),
        ]),
        stop("rail-gct", "Grand Central", 40.753, -73.97706, platform: 120, [
            line("MNR-DAN", north: "Danbury", every: 120),
            line("MNR-HAR", north: "North White Plains", every: 30),
            line("MNR-HUD", north: "Croton-Harmon", every: 30),
            line("MNR-NC", north: "New Canaan", every: 60),
            line("MNR-NH", north: "New Haven", every: 30),
        ]),
        stop("rail-gcm", "Grand Central Madison", 40.75516, -73.97546, platform: 120, [
            line("LIRR-BAB", north: "Babylon", every: 30),
            line("LIRR-CTZ", north: "Jamaica", every: 60),
            line("LIRR-FR", north: "Far Rockaway", every: 60),
            line("LIRR-HEM", north: "Hempstead", every: 60),
            line("LIRR-LB", north: "Long Beach", every: 60),
            line("LIRR-PJ", north: "Huntington", every: 60),
            line("LIRR-PW", north: "Port Washington", every: 30),
            line("LIRR-RON", north: "Ronkonkoma", every: 60),
            line("LIRR-WH", north: "West Hempstead", every: 60),
        ]),
        stop("rail-125", "Harlem-125 St", 40.80516, -73.93915, platform: 120, [
            line("MNR-DAN", north: "Danbury", every: 120),
            line("MNR-HAR", north: "North White Plains", south: "Grand Central", every: 30),
            line("MNR-HUD", north: "Croton-Harmon", south: "Grand Central", every: 30),
            line("MNR-NC", north: "New Canaan", every: 60),
            line("MNR-NH", north: "New Haven", every: 30),
        ]),
    ]

    /// PATH stations in Manhattan, shown with the subway: the weekday daytime lines
    public static let pathStops: [Stop] = [
        stop("path-33", "33rd Street", 40.74912, -73.98827, platform: 90, [
            line("PATH-HOB-33", north: "Hoboken", every: 10),
            line("PATH-JSQ-33", north: "Journal Square", every: 10),
        ]),
        stop("path-23", "23rd Street", 40.7429, -73.99278, platform: 90, [
            line("PATH-HOB-33", north: "Hoboken", south: "33rd Street", every: 10),
            line("PATH-JSQ-33", north: "Journal Square", south: "33rd Street", every: 10),
        ]),
        stop("path-14", "14th Street", 40.73735, -73.99684, platform: 90, [
            line("PATH-HOB-33", north: "Hoboken", south: "33rd Street", every: 10),
            line("PATH-JSQ-33", north: "Journal Square", south: "33rd Street", every: 10),
        ]),
        stop("path-9", "9th Street", 40.73424, -73.9991, platform: 90, [
            line("PATH-HOB-33", north: "Hoboken", south: "33rd Street", every: 10),
            line("PATH-JSQ-33", north: "Journal Square", south: "33rd Street", every: 10),
        ]),
        stop("path-chr", "Christopher Street", 40.73295, -74.00707, platform: 90, [
            line("PATH-HOB-33", north: "Hoboken", south: "33rd Street", every: 10),
            line("PATH-JSQ-33", north: "Journal Square", south: "33rd Street", every: 10),
        ]),
        stop("path-wtc", "World Trade Center", 40.71271, -74.01193, platform: 90, [
            line("PATH-HOB-WTC", north: "Hoboken", every: 10),
            line("PATH-NWK-WTC", north: "Newark", every: 10),
        ]),
    ]

    /// Piers in Manhattan (the Statue of Liberty ferry's boarding time includes its security check)
    public static let ferryStops: [Stop] = [
        stop("ferry-pier11", "Wall St/Pier 11", 40.70316, -74.00614, platform: 60, [
            line("NYF-AS", south: "East 90th St", every: 30),
            line("NYF-ER", south: "East 34th Street", every: 20),
            line("NYF-RS", north: "Rockaway", south: "Ferry Point Park", every: 45),
            line("NYF-SB", north: "Red Hook/Atlantic Basin", south: "East 34th Street", every: 30),
            line("NYF-SG", south: "Midtown West 39th St-Pier 79", every: 40),
            line("NYW", north: "Belford / Harbor Way", south: "Hoboken / NJ Transit Terminal", every: 20),
        ]),
        stop("ferry-bmb", "Battery Maritime Building Slip 5", 40.70089, -74.01161, platform: 60, [
            line("SST", south: "Highlands, NJ", every: 60, timetable: true),
        ]),
        stop("ferry-whitehall", "Whitehall Ferry Terminal", 40.70136, -74.01267, platform: 60, [
            line("SIF", north: "St. George Ferry Terminal", every: 20, timetable: true),
        ]),
        stop("ferry-battery", "Battery Park", 40.7033, -74.017, platform: 1800, [
            line("SOL", south: "Liberty Island", every: 25, timetable: true),
        ]),
        stop("ferry-bpc", "Battery Park City/Vesey St.", 40.71503, -74.01778, platform: 60, [
            line("NYF-SG", north: "Wall St/Pier 11", south: "Midtown West 39th St-Pier 79", every: 40),
            line("NYW", north: "Paulus Hook", south: "Hoboken / NJ Transit Terminal", every: 20),
            line("SST", south: "Belford, NJ", every: 60, timetable: true),
        ]),
        stop("ferry-corlears", "Corlears Hook", 40.71016, -73.97924, platform: 60, [
            line("NYF-SB", north: "Red Hook/Atlantic Basin", south: "East 34th Street", every: 30),
        ]),
        stop("ferry-stuy", "Stuyvesant Cove", 40.73198, -73.97292, platform: 60, [
            line("NYF-RS", north: "Rockaway", south: "Ferry Point Park", every: 45),
        ]),
        stop("ferry-e34", "East 34th Street", 40.74391, -73.97073, platform: 60, [
            line("NYF-AS", north: "Wall St/Pier 11", south: "East 90th St", every: 30),
            line("NYF-ER", north: "Wall St/Pier 11", every: 20),
            line("NYF-RS", north: "Rockaway", south: "Ferry Point Park", every: 45),
            line("NYF-SB", north: "Red Hook/Atlantic Basin", every: 30),
            line("SST", south: "Highlands, NJ", every: 60, timetable: true),
        ]),
        stop("ferry-e90", "East 90th St", 40.77748, -73.94217, platform: 60, [
            line("NYF-AS", north: "Wall St/Pier 11", every: 30),
            line("NYF-RS", north: "Rockaway", south: "Ferry Point Park", every: 45),
        ]),
        stop("ferry-w39", "Midtown West 39th St-Pier 79", 40.76028, -74.00359, platform: 60, [
            line("NYF-SG", north: "Wall St/Pier 11", every: 40),
            line("NYW", north: "Hoboken 14th Street", south: "Port Imperial / Weehawken", every: 15),
            line("SST", south: "Belford, NJ", every: 60, timetable: true),
        ]),
    ]

    /// One of the demo's own stations, by its ID
    public static func stop(id: String) -> Stop? { stopsByID[id] }

    private static let stopsByID: [String: Stop] = Dictionary(
        (trainStops + pathStops + ferryStops).map { ($0.station.id, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: Subway lines in the daytime

    /// A subway line at a station in the daytime: its route, which way (N / S), and whether most of its trains run express there
    public struct SubwayLine: Hashable, Sendable {
        public var route: String
        public var code: String
        public var express: Bool
    }

    /// The subway lines of each station in the demo's area that stop there on weekdays between 7:00 and 21:00, by direction, from
    /// the MTA timetable the app has: "127:1=NS,2=ns" is the 1 both ways and the 2 both ways, the 2 running express there (lower case:
    /// most of those trains skip a station within the next few stops, as ExpressStops tells). Lines that stop only late at night, on
    /// weekends or in rush hours aren't listed (the Z, the N on Second Avenue), nor the way a line ends at the station.
    static let subwayDaytime = """
    107:1=NS
    108:1=NS
    109:1=NS
    110:1=NS
    111:1=NS
    112:1=NS
    113:1=NS
    114:1=NS
    115:1=NS
    116:1=NS
    117:1=NS
    118:1=NS
    119:1=NS
    120:1=NS,2=Ns,3=Ns
    121:1=NS
    122:1=NS
    123:1=NS,2=ns,3=ns
    124:1=NS
    125:1=NS
    126:1=NS
    127:1=NS,2=ns,3=ns
    128:1=NS,2=ns,3=ns
    129:1=NS
    130:1=NS
    131:1=NS
    132:1=NS,2=ns,3=ns
    133:1=NS
    134:1=NS
    135:1=NS
    136:1=NS
    137:1=NS,2=nS,3=nS
    138:1=NS
    139:1=NS
    142:1=N
    224:2=NS,3=NS
    225:2=NS,3=NS
    226:2=Ns,3=Ns
    227:2=Ns,3=Ns
    228:2=nS,3=nS
    229:2=nS,3=nS
    230:2=NS,3=NS
    301:3=S
    302:3=NS
    418:4=nS,5=nS
    419:4=nS,5=nS
    420:4=NS,5=N
    621:4=Ns,5=Ns,6=NS
    622:6=NS
    623:6=NS
    624:6=NS
    625:6=NS
    626:4=ns,5=ns,6=NS
    627:6=NS
    628:6=NS
    629:4=ns,5=ns,6=NS
    630:6=NS
    631:4=ns,5=ns,6=NS
    632:6=NS
    633:6=NS
    634:6=NS
    635:4=ns,5=ns,6=NS
    636:6=NS
    637:6=NS
    638:6=NS
    639:6=NS
    640:4=nS,5=nS,6=N
    723:7=NS
    724:7=NS
    725:7=NS
    726:7=N
    901:GS=N
    902:GS=S
    A02:A=S
    A03:A=NS
    A05:A=NS
    A06:A=Ns
    A07:A=Ns
    A09:A=Ns,C=S
    A10:C=NS
    A11:C=NS
    A12:A=ns,C=NS
    A14:B=NS,C=NS
    A15:A=ns,B=NS,C=NS,D=ns
    A16:B=NS,C=NS
    A17:B=NS,C=NS
    A18:B=NS,C=NS
    A19:B=NS,C=NS
    A20:B=NS,C=NS
    A21:B=NS,C=NS
    A22:B=NS,C=NS
    A24:A=ns,B=NS,C=NS,D=nS
    A25:C=NS,E=NS
    A27:A=ns,C=NS,E=NS
    A28:A=ns,C=NS,E=NS
    A30:C=NS,E=NS
    A31:A=ns,C=NS,E=NS
    A32:A=ns,C=NS,E=NS
    A33:C=NS,E=NS
    A34:A=nS,C=NS,E=NS
    A36:A=nS,C=NS
    A38:A=nS,C=NS
    B08:M=NS,Q=Ns
    B10:M=NS
    D12:B=NS,D=Ns
    D13:B=NS,D=Ns
    D14:B=NS,D=nS,E=NS
    D15:B=Ns,D=ns,F=NS,M=NS
    D16:B=Ns,D=Ns,F=NS,M=NS
    D17:B=Ns,D=Ns,F=NS,M=NS
    D18:F=NS,M=NS
    D19:F=NS,M=NS
    D20:B=nS,D=ns,F=NS,M=NS
    D21:B=nS,D=ns,F=NS,M=NS
    D22:B=nS,D=ns
    E01:E=N
    F11:E=nS,F=nS
    F12:E=NS,F=NS
    F14:F=NS
    F15:F=NS
    F16:F=NS
    L01:L=S
    L02:L=NS
    L03:L=NS
    L05:L=NS
    L06:L=NS
    M18:J=NS,M=S
    M19:J=NS
    M20:J=NS
    M21:J=NS
    M22:J=NS
    M23:J=N
    Q01:N=ns,Q=nS
    Q03:Q=Ns
    Q04:Q=NS
    Q05:Q=S
    R11:N=NS,R=NS,W=NS
    R13:N=NS,R=NS,W=NS
    R14:N=NS,Q=Ns,R=NS,W=NS
    R15:N=Ns,R=NS,W=NS
    R16:N=Ns,Q=ns,R=NS,W=NS
    R17:N=Ns,Q=ns,R=NS,W=NS
    R18:R=NS,W=NS
    R19:R=NS,W=NS
    R20:N=ns,Q=ns,R=NS,W=NS
    R21:R=NS,W=NS
    R22:R=NS,W=NS
    R23:R=NS,W=NS
    R24:R=NS,W=NS
    R25:R=NS,W=NS
    R26:R=NS,W=NS
    R27:R=NS,W=N
    """

    /// Station ID → its daytime subway lines, in the station list's order
    public static let subwayLines: [String: [SubwayLine]] = {
        var result: [String: [SubwayLine]] = [:]
        for row in subwayDaytime.split(separator: "\n") {
            let parts = row.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var lines: [SubwayLine] = []
            for item in parts[1].split(separator: ",") {
                let pair = item.split(separator: "=")
                guard pair.count == 2 else { continue }
                for c in pair[1] {
                    lines.append(SubwayLine(route: String(pair[0]), code: String(c).uppercased(), express: c.isLowercase))
                }
            }
            result[String(parts[0])] = lines
        }
        return result
    }()
}
