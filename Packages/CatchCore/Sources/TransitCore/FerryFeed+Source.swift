import Foundation

extension FerryFeed {
    /// Data sources: one official GTFS per ferry operator.
    public enum Source: String, CaseIterable, Codable, Sendable {
        /// NYC Ferry (has realtime data)
        case nycFerry = "nyf"
        /// Staten Island Ferry (NYC DOT, schedule only)
        case statenIsland = "sif"
        /// NY Waterway (has realtime data)
        case nyWaterway = "nyw"
        /// Seastreak (schedule only)
        case seastreak = "sst"
        /// Statue of Liberty ferry (data from the National Park Service, NPS; schedule only)
        case statueOfLiberty = "sol"
        /// Cape May–Lewes Ferry (Delaware River and Bay Authority; Cape May NJ ↔ Lewes DE, schedule only): only its Cape May terminal is
        /// in the service area; Lewes is cut off like Amtrak's stations outside it, and the boats still say "Lewes"
        case capeMayLewes = "cml"
        /// MBTA's ferries in Boston Harbor (schedule, has realtime data). In MBTA's one package with its subway, trains and buses, split
        /// by route_type (see mbtaSubway)
        case mbtaFerry = "mbf"
        // The ferries around Greater Boston and to its islands, each merged into one line, all schedule only (no realtime data
        // published) and downloaded only for places in Greater Boston. The ones that run only in summer have no trips in winter, and
        // their piers are hidden until a timetable with trips comes (see active(from:)), like the Statue of Liberty ferry's.
        /// Hy-Line Cruises: Hyannis ↔ Nantucket and Oak Bluffs, and between the islands in summer (Trillium)
        case hyLine = "hyl"
        /// Bay State Cruise Company: Boston (World Trade Center pier) ↔ Provincetown, in summer (Trillium)
        case bayState = "bsc"
        /// Block Island Ferry: Point Judith and Newport ↔ Block Island (Trillium)
        case blockIsland = "bif"
        /// Cuttyhunk Ferry: New Bedford ↔ Cuttyhunk, in the Elizabeth Islands (Trillium)
        case cuttyhunk = "cut"
        /// Patriot Party Boats: Falmouth ↔ Oak Bluffs (Trillium)
        case patriot = "ppb"
        /// Freedom Cruise Line: Harwich Port ↔ Nantucket, in summer (Trillium)
        case freedom = "fcl"
        /// Vineyard Fast Ferry: Quonset Point, Rhode Island ↔ Oak Bluffs, in summer (Trillium; its data's shuttle bus is left out)
        case vineyardFastFerry = "vff"
        /// The Boston Harbor Islands ferry: Long Wharf and Hingham ↔ Georges, Spectacle and Peddocks Island, in summer (National Park
        /// Service, like the Statue of Liberty ferry's)
        case harborIslands = "bhi"
        /// The ferry from South Boston to Cathleen Stone Island (the former Thompson Island), on summer weekends (National Park Service)
        case cathleenStone = "csi"
        /// Long Island Rail Road, LIRR (train, has realtime data)
        case lirr = "lirr"
        /// Metro-North Railroad (train, has realtime data)
        case metroNorth = "mnr"
        /// PATH (New Jersey ↔ Manhattan subway; realtime data in Path.swift)
        case path = "path"
        /// NJ Transit trains (schedule; in the same package as light rail, split by route_type)
        case njTransitRail = "njr"
        /// NJ Transit light rail: Hudson-Bergen, Newark Light Rail, River LINE (schedule)
        case njTransitLightRail = "njl"
        /// MBTA Commuter Rail (Boston's commuter trains, to Providence, Worcester and New Hampshire's border, and the CapeFLYER in summer;
        /// schedule, has realtime data). In MBTA's one package (see mbtaSubway). Before Amtrak, so the stations they share in Boston and
        /// Providence keep MBTA's names (see pierGroups)
        case mbtaRail = "mbr"
        /// SEPTA Metro: Philadelphia's subway, high-speed and trolley lines (schedule, has realtime data). In SEPTA's bus package, split by route_type.
        /// After NJ Transit's light rail, so a station they share keeps NJ Transit's name (see pierGroups)
        case septaMetro = "smt"
        /// PATCO (Philadelphia ↔ Lindenwold, schedule). After SEPTA Metro, so the station they share at 8th and Market keeps SEPTA's name
        case patco = "pat"
        /// The MBTA's subway: the Red, Orange and Blue Lines, the Green Line's four branches and the Mattapan Line (schedule, has realtime
        /// data). MBTA publishes one package for its subway, trains, buses and ferries (22 MB) and one realtime file for all of them;
        /// each part is read from it by route_type, and it's downloaded once for all four (see RegionalBusFeed.isSharedPackage)
        case mbtaSubway = "mbs"
        /// Amtrak (schedule): only stations in the NYC metro area (and Philadelphia) (see ServiceArea)
        case amtrakNY = "amk"
        /// SEPTA Regional Rail (Philadelphia's commuter trains, to Trenton, Wilmington and Newark DE; schedule, has realtime data).
        /// After NJ Transit and Amtrak, so a station they share keeps their name (see pierGroups); before the Hartford Line, so CTrail's two lines stay together in lists
        case septaRail = "srr"
        /// CTrail Hartford Line (New Haven ↔ Hartford ↔ Springfield, CTDOT, schedule): only stations in the service area (New Haven to Berlin)
        case hartfordLine = "ctr"
        /// MARC (Maryland Transit Administration; Perryville to Baltimore and Washington, schedule with free realtime data): only Perryville
        /// is in the service area, the other stations are cut off like Amtrak's, and the trains still say where they go
        case marc = "marc"
        /// NJ Transit buses (schedule). The data is large, so it skips FerryBuilder and is stored as NJBusIndex; only a nearby chunk is loaded on use (see NJBus.swift)
        case njTransitBus = "njb"

        /// Which transit system it belongs to: trains (LIRR, Metro-North) or ferries (the others)
        public var system: TransitSystem {
            switch self {
            case .lirr, .metroNorth, .njTransitRail, .amtrakNY, .hartfordLine, .septaRail, .marc, .mbtaRail: return .train
            case .path: return .path
            case .njTransitLightRail, .septaMetro, .patco, .mbtaSubway: return .lightRail
            case .njTransitBus: return .njBus
            case .nycFerry, .statenIsland, .nyWaterway, .seastreak, .statueOfLiberty, .capeMayLewes, .mbtaFerry: return .ferry
            case .hyLine, .bayState, .blockIsland, .cuttyhunk, .patriot, .freedom, .vineyardFastFerry, .harborIslands, .cathleenStone: return .ferry
            }
        }

        /// Whether it's a train
        public var isRail: Bool { system.family == .rail }

        /// NJ Transit (train or light rail)
        public var isNJTransit: Bool { self == .njTransitRail || self == .njTransitLightRail }

        public var isAmtrak: Bool { self == .amtrakNY }

        /// Runs beyond the service area (Amtrak, Hartford Line, MARC, the Cape May–Lewes Ferry): keep only stations in the area; the destination
        /// is still the trip's real terminal
        var clipsToServiceArea: Bool { self == .amtrakNY || self == .hartfordLine || self == .marc || self == .capeMayLewes }

        /// Which area's stations to keep (Amtrak runs nationwide; keep all for the others)
        func keepsStop(lat: Double, lon: Double) -> Bool {
            switch self {
            case .amtrakNY, .hartfordLine, .marc, .capeMayLewes:
                // Same as the app's service area: NYC metro area, plus Philadelphia
                return ServiceArea.contains(Coordinate(latitude: lat, longitude: lon))
            default:
                return true
            }
        }

        /// Which agency's routes to keep (the Amtrak package also has intercity buses and other railroads; Amtrak is 51). CTrail's
        /// Shore Line East is in the same package too, and kept as a line of its own (see FerryFeed.shoreLineEast)
        func wants(agency: String) -> Bool { !isAmtrak || agency.isEmpty || agency == "51" || agency == FerryFeed.shoreLineEast.agency }

        /// The operators in this transit system (in display and processing order); one the source list turned off isn't among them
        public static func cases(for system: TransitSystem) -> [Source] {
            allCases.filter { $0.system == system.dataSystem && !$0.isTurnedOff }
        }

        /// Turned off by the source list in use: nothing of it is downloaded or shown (see SourceList)
        public var isTurnedOff: Bool { SourceList.isTurnedOff(rawValue) }

        /// Its timetable's address: the source list's, or the one in code
        public var url: URL { SourceList.timetableURL(for: rawValue) ?? builtInURL }

        /// The address in code
        var builtInURL: URL {
            switch self {
            case .nycFerry: return FerryFeed.nycFerryURL
            case .statenIsland: return FerryFeed.statenIslandURL
            case .nyWaterway: return FerryFeed.nyWaterwayURL
            case .seastreak: return FerryFeed.seastreakURL
            case .statueOfLiberty: return FerryFeed.statueOfLibertyURL
            case .lirr: return FerryFeed.lirrURL
            case .metroNorth: return FerryFeed.metroNorthURL
            case .path: return FerryFeed.pathURL
            case .njTransitRail, .njTransitLightRail: return FerryFeed.njTransitRailURL
            case .amtrakNY: return FerryFeed.amtrakURL
            case .hartfordLine: return FerryFeed.hartfordLineURL
            case .septaRail: return FerryFeed.septaRailURL
            case .marc: return FerryFeed.marcURL
            case .capeMayLewes: return FerryFeed.capeMayLewesURL
            case .septaMetro: return FerryFeed.septaBusURL
            case .patco: return FerryFeed.patcoURL
            case .mbtaSubway, .mbtaRail, .mbtaFerry: return FerryFeed.mbtaURL
            case .hyLine: return FerryFeed.trilliumURL("hylinecruises-ma-us")
            case .bayState: return FerryFeed.trilliumURL("baystatecruisecompany-ma-us")
            case .blockIsland: return FerryFeed.trilliumURL("blockislandferry-ri-us")
            case .cuttyhunk: return FerryFeed.trilliumURL("cuttyhunkferryco-ma-us")
            case .patriot: return FerryFeed.trilliumURL("patriotpartyboats-ma-us")
            case .freedom: return FerryFeed.trilliumURL("freedomcruiseline-ma-us")
            case .vineyardFastFerry: return FerryFeed.trilliumURL("vineyardfastferry-ri-us")
            case .harborIslands: return FerryFeed.harborIslandsURL
            case .cathleenStone: return FerryFeed.cathleenStoneURL
            case .njTransitBus: return NJBusIndex.builtInURL
            }
        }

        /// Realtime data URL (nil if there's no realtime data): the source list's, or the one in code
        public var realtimeURL: URL? {
            builtInRealtimeURL.map { SourceList.realtimeURL(for: rawValue) ?? $0 }
        }

        /// The realtime address in code
        var builtInRealtimeURL: URL? {
            switch self {
            case .nycFerry: return FerryFeed.realtimeURL
            case .nyWaterway: return FerryFeed.nyWaterwayRealtimeURL
            case .lirr: return FerryFeed.lirrRealtimeURL
            case .metroNorth: return FerryFeed.metroNorthRealtimeURL
            case .statenIsland, .seastreak, .statueOfLiberty: return nil
            // PATH realtime data isn't GTFS-Realtime and is downloaded separately (see PathLive)
            case .path: return nil
            // NJ Transit realtime data needs a developer account; only the schedule is used for now
            case .njTransitRail, .njTransitLightRail: return nil
            // Amtrak has no public realtime data
            case .amtrakNY: return nil
            // Hartford Line has no public realtime data
            case .hartfordLine: return nil
            case .septaRail: return FerryFeed.septaRailRealtimeURL
            // MARC's live trip_ids are its timetable's ("Train494"; checked on a Mac): free, no key
            case .marc: return FerryFeed.marcRealtimeURL
            // The Cape May–Lewes Ferry publishes no realtime data
            case .capeMayLewes: return nil
            case .septaMetro: return FerryFeed.septaBusRealtimeURL
            // PATCO publishes no realtime data
            case .patco: return nil
            // One file for all of MBTA's modes (see SharedLive)
            case .mbtaSubway, .mbtaRail, .mbtaFerry: return FerryFeed.mbtaRealtimeURL
            // None of the ferries around Boston publishes realtime data
            case .hyLine, .bayState, .blockIsland, .cuttyhunk, .patriot, .freedom, .vineyardFastFerry, .harborIslands, .cathleenStone: return nil
            case .njTransitBus: return nil
            }
        }

        /// Whether it has realtime data
        public var hasRealtime: Bool { realtimeURL != nil || self == .path }

        /// Realtime data needs the user's own developer account (NJ Transit trains and light rail; like MTA Bus Time,
        /// use realtime data when an account is entered, otherwise the schedule). The account is stored in the Keychain, not in code.
        public var needsAccount: Bool { isNJTransit }

        /// Whether its times are live once the account is entered: only where NJ Transit's live data was checked, on real data, to
        /// match this timetable's trips. Its trains: yes, by train number (see liveByTrainNumber). Its light rail: no (the live data
        /// has no predictions for it), so its times are the timetable's and no live data is downloaded for it. The marks in
        /// Settings, the sidebar's popover and the footer all follow this one fact (the buses': RegionalBusFeed.liveWithAccount)
        public var liveWithAccount: Bool { self == .njTransitRail }

        /// Its live trips are matched to the timetable's by train number only (NJ Transit's trains). The live data names trips as
        /// another copy of the timetable does (the one its API gives), so its trip_ids name other trips in the public one the app
        /// reads. The train number is the same in both: the live entry's id, and the public timetable's block_id (which has no
        /// trip_short_name). Stops are named alike in both
        var liveByTrainNumber: Bool { self == .njTransitRail }

        /// Light rail with free live data, no account (SEPTA Metro, the MBTA's subway): the subway's refresh and Plan a Trip
        /// download it for their stations
        public static var freeLiveLightRail: [Source] {
            allCases.filter { $0.system == .lightRail && $0.realtimeURL != nil && !$0.needsAccount && !$0.isTurnedOff }
        }

        /// Operator name (brand name, same in every language)
        public var name: String {
            switch self {
            case .nycFerry: return "NYC Ferry"
            case .statenIsland: return "Staten Island Ferry"
            case .nyWaterway: return "NY Waterway"
            case .seastreak: return "Seastreak"
            case .statueOfLiberty: return "Statue of Liberty Ferry"
            case .lirr: return "Long Island Rail Road"
            case .metroNorth: return "Metro-North Railroad"
            case .path: return "PATH"
            case .njTransitRail: return "NJ Transit Rail"
            case .njTransitLightRail: return "NJ Transit Light Rail"
            case .amtrakNY: return "Amtrak"
            case .hartfordLine: return "CTrail Hartford Line"
            case .septaRail: return "SEPTA Regional Rail"
            case .marc: return "MARC Train"
            case .capeMayLewes: return "Cape May–Lewes Ferry"
            case .septaMetro: return "SEPTA Metro"
            case .patco: return "PATCO"
            case .mbtaSubway: return "MBTA Subway"
            case .mbtaRail: return "MBTA Commuter Rail"
            case .mbtaFerry: return "MBTA Ferry"
            case .hyLine: return "Hy-Line Cruises"
            case .bayState: return "Bay State Cruise Company"
            case .blockIsland: return "Block Island Ferry"
            case .cuttyhunk: return "Cuttyhunk Ferry"
            case .patriot: return "Patriot Party Boats"
            case .freedom: return "Freedom Cruise Line"
            case .vineyardFastFerry: return "Vineyard Fast Ferry"
            case .harborIslands: return "Boston Harbor Islands Ferry"
            case .cathleenStone: return "Cathleen Stone Island Ferry"
            case .njTransitBus: return "NJ Transit Bus"
            }
        }

        /// Short name prefixed to the full route name ("LIRR Babylon Branch", "Metro-North Hudson Line")
        public var shortName: String {
            switch self {
            case .lirr: return "LIRR"
            case .metroNorth: return "Metro-North"
            case .njTransitRail, .njTransitLightRail, .njTransitBus: return "NJ Transit"
            case .hartfordLine: return "CTrail"
            case .septaRail, .septaMetro: return "SEPTA"
            case .marc: return "MARC"
            case .mbtaSubway, .mbtaRail, .mbtaFerry: return "MBTA"
            default: return name
            }
        }

        /// Route ID when the whole operator is merged into one route (nil for NYC Ferry, whose routes are separate)
        public var singleRouteID: String? {
            switch self {
            case .nycFerry: return nil
            case .statenIsland: return "SIF"
            case .nyWaterway: return "NYW"
            case .seastreak: return "SST"
            case .statueOfLiberty: return "SOL"
            case .capeMayLewes: return "CML"
            case .hyLine: return "HYL"
            case .bayState: return "BSC"
            case .blockIsland: return "BIF"
            case .cuttyhunk: return "CUT"
            case .patriot: return "PPB"
            case .freedom: return "FCL"
            case .vineyardFastFerry: return "VFF"
            case .harborIslands: return "BHI"
            case .cathleenStone: return "CSI"
            case .lirr, .metroNorth, .path, .njTransitRail, .njTransitLightRail, .amtrakNY, .njTransitBus, .hartfordLine, .septaRail,
                 .septaMetro, .patco, .marc, .mbtaSubway, .mbtaRail, .mbtaFerry:
                return nil
            }
        }

        /// Prefix added to route IDs for operators that keep routes separate
        var routePrefix: String {
            switch self {
            case .lirr: return "LIRR-"
            case .metroNorth: return "MNR-"
            case .path: return "PATH-"
            case .njTransitRail: return "NJT-"
            case .njTransitLightRail: return "NJL-"
            case .amtrakNY: return "AMK-"
            case .njTransitBus: return "NJB-"
            case .hartfordLine: return "CTR-"
            case .septaRail: return "SRR-"
            case .marc: return "MARC-"
            case .septaMetro: return "SMT-"
            case .patco: return "PAT-"
            case .mbtaSubway: return "MBS-"
            case .mbtaRail: return "MBR-"
            case .mbtaFerry: return "MBF-"
            default: return "NYF-"
            }
        }

        /// This operator's route ID: "NYF-ER", "SIF", "NYW", "SST"; trains use the line's short name ("LIRR-BAB", see FerryFeed.railLines),
        /// and unknown line names use the raw route_id.
        func routeID(_ raw: String, name: String = "", agency: String = "") -> String {
            if let single = singleRouteID { return single }
            // Hartford Line has only one line (its route_id is "HART", same as Huntington's HART bus, so use its own short name)
            if self == .hartfordLine { return routePrefix + "HL" }
            // PATCO has one line too (its route_id is a number): its own name
            if self == .patco { return routePrefix + "PATCO" }
            // SEPTA Metro's route_ids are its line codes ("L1", "T3"), which riders know the lines by
            if self == .septaMetro { return routePrefix + raw }
            // Shore Line East's one route is called just "Commuter Rail" in the Amtrak package: known by its agency instead
            if isAmtrak, agency == FerryFeed.shoreLineEast.agency { return routePrefix + FerryFeed.shoreLineEast.code }
            if let code = FerryFeed.railLines[self]?.first(where: { $0.dataName == name })?.code {
                return routePrefix + code
            }
            // Unknown Amtrak lines (dozens in the real data, with long numeric route_ids): use the name's initials as the short name, merging lines with the same name
            if isAmtrak, let code = Self.amtrakCode(name) { return routePrefix + code }
            return routePrefix + raw
        }

        /// "Downeaster" → "DOW", "Lincoln Service" → "LS", "Montreal Express" → "ME"; at most 3 letters
        static func amtrakCode(_ name: String) -> String? {
            let skip: Set<String> = ["AND", "THE", "OF", "AMTRAK"]
            let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !skip.contains($0) }
            guard let first = words.first else { return nil }
            let code = words.count == 1 ? String(first.prefix(3)) : String(words.compactMap(\.first).prefix(3))
            return code.isEmpty ? nil : code
        }

        /// Whether this route ID belongs to this operator
        public func owns(route id: String) -> Bool {
            if let single = singleRouteID { return id == single }
            return id.hasPrefix(routePrefix)
        }

        /// Whether this pier, trip or calendar ID ("nyf:…") belongs to this operator
        public func owns(id: String) -> Bool { id.hasPrefix(rawValue + ":") }

        /// Which operator this route belongs to
        public static func of(route id: String) -> Source? { allCases.first { $0.owns(route: id) } }

        /// Route color. NY Waterway, Seastreak and the Statue of Liberty ferry are merged into one line each, with a fixed color (same on the map and the route badge):
        /// NY Waterway routes all differ in color, so use red; Seastreak's official data uses 013067 for every route;
        /// the Statue of Liberty ferry data has no color, so use the statue's verdigris green. Others use the official color, falling back to this one.
        var fixedColor: String? {
            switch self {
            case .nyWaterway: return "C8102E"
            case .seastreak: return "013067"
            case .statueOfLiberty: return "2E8B57"
            // MARC's data uses its bright orange (FF8000): darker, so white text on the badge can be read (4.5:1)
            case .marc: return "B35900"
            // Amtrak data uses a very light blue for every line; use Amtrak's dark blue
            case .amtrakNY: return "00537E"
            // NJ Transit bus data colors are all black; use NJ Transit blue
            case .njTransitBus: return NJBusIndex.color
            // The ferries around Boston: most of their data has no color, or one white text can't be read on (Cuttyhunk's and
            // Patriot's 4CD975), and the Harbor Islands' four routes have four. Each gets one dark color white text reads on
            // (4.5:1), told apart from the others at the same pier (Oak Bluffs: Hy-Line, Patriot, Vineyard Fast Ferry; Nantucket:
            // Hy-Line, Freedom); Freedom's and Cathleen Stone's are their data's own
            case .hyLine: return "1F3A68"
            case .bayState: return "0057A8"
            case .blockIsland: return "00697A"
            case .cuttyhunk: return "2E7D32"
            case .patriot: return "8B1E2D"
            case .freedom: return "215AA9"
            case .vineyardFastFerry: return "005A70"
            case .harborIslands: return "BF5700"
            case .cathleenStone: return "224483"
            case .hartfordLine, .nycFerry, .statenIsland, .lirr, .metroNorth, .path, .njTransitRail, .njTransitLightRail, .septaRail,
                 .septaMetro, .patco, .capeMayLewes, .mbtaSubway, .mbtaRail, .mbtaFerry: return nil
            }
        }

        /// Whether to keep loops (trips that start and end at the same pier). The Statue of Liberty ferry's main route is a loop;
        /// the other operators' loops aren't for riders (e.g. Staten Island Ferry positioning trips at St. George), so drop them.
        var keepsLoops: Bool { self == .statueOfLiberty }

        /// Tickets and security screening before boarding (Statue of Liberty ferry): the UI warns, and catch checks allow extra time.
        public var needsSecurityCheck: Bool { self == .statueOfLiberty }

        /// How long (seconds) from reaching the pier (station) to being able to board: usually 1 minute; train stations need finding the platform and going down, so 2 minutes;
        /// with security screening (Statue of Liberty ferry), 30 minutes.
        /// PATH stations are underground: 1.5 minutes for stairs and fare gates (same as the subway).
        /// Light rail stops are mostly at street level: 1.5 minutes (a few Newark stops are underground); SEPTA Metro's and PATCO's
        /// stations, underground, raised or at the curb, the same as the subway's.
        public var boardingSeconds: TimeInterval {
            needsSecurityCheck ? 30 * 60 : self == .path || system == .lightRail ? 90 : isRail ? 120 : 60
        }

        var defaultColor: String { fixedColor ?? (self == .statenIsland ? "FF8330" : isRail || self == .path ? "0039A6" : "0077C8") }

        /// Which GTFS route_type to keep: ferries 4 (or extended 1200), trains and PATH 2 (or extended 100–117; PATH may also be listed as subway 1). Unspecified ones are kept too.
        func wants(routeType type: String) -> Bool {
            if type.isEmpty { return true }
            // Light rail is 0 (tram/light rail), in the same package as trains, kept separately
            if self == .njTransitLightRail { return type == "0" || type == "900" }
            // SEPTA Metro's trolleys are 0 and its subway and high-speed lines 1, in the same package as SEPTA's buses (3 and 11); PATCO is 1.
            // The MBTA's Green Line and Mattapan Line are 0 and its Red, Orange and Blue Lines 1, in one package with its trains (2),
            // buses (3) and ferries (4)
            if self == .septaMetro || self == .patco || self == .mbtaSubway {
                return type == "0" || type == "1" || (Int(type).map { (400...404).contains($0) || (900...906).contains($0) } ?? false)
            }
            if isRail || self == .path {
                return type == "2" || (self == .path && type == "1") || (Int(type).map { (100...117).contains($0) } ?? false)
            }
            // Vineyard Fast Ferry's data has its boats back from Oak Bluffs to Quonset Point as a route of their own marked as a
            // bus (3); it runs no buses, so that route is its boats too
            if self == .vineyardFastFerry { return type == "4" || type == "1200" || type == "3" }
            return type == "4" || type == "1200"
        }

        /// Only keep trips for the next few days (number of days; nil keeps all). Train schedules cover months, too big to keep whole.
        var keepDays: Int? { isRail || self == .path ? 45 : nil }

        /// The destination shown is each trip's headsign where it differs from the last stop's name: SEPTA Metro's headsigns are what
        /// riders see ("NRG", "63rd-Girard"), its last stops have longer names ("NRG Station", "Girard Av & 63rd St"); PATCO's say "Philadelphia"
        var usesHeadsigns: Bool { self == .septaMetro || self == .patco }

        /// SEPTA's train live data names each stop only by its stop_sequence (no stop_id), so its trips keep the data's stop_sequence
        var liveStopsBySequence: Bool { self == .septaRail }

        /// Where its data is of use, for one that's downloaded only for places there (see DownloadArea); nil: downloaded for everyone
        public var downloadArea: DownloadArea? {
            switch self {
            case .septaMetro: return .philadelphia
            // Only Perryville, in Cecil County
            case .marc: return .chesterAndCecil
            case .capeMayLewes: return .capeMay
            case .mbtaSubway, .mbtaRail, .mbtaFerry: return .greaterBoston
            case .hyLine, .bayState, .blockIsland, .cuttyhunk, .patriot, .freedom, .vineyardFastFerry, .harborIslands, .cathleenStone: return .greaterBoston
            default: return nil
            }
        }

        /// Whether its data is downloaded now: one of its metro areas is kept, and for one with a DownloadArea, a place in use is inside
        /// it (see PlacesInUse). One that isn't keeps what it downloaded before, without updates, until it's wanted again or its areas'
        /// data is removed (see AreaData)
        public var isWanted: Bool { PlacesInUse.wants(areas: MetroArea.areas(of: self), box: downloadArea) }

        /// Show stations, lines and the map even when the schedule has expired (PATH: realtime only):
        /// keep one trip per stop pattern among those not running in the next few days, so stations don't disappear for lack of trips.
        public var keepsPatterns: Bool { self == .path }
    }
}
