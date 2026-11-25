import Foundation

extension FerryFeed {
    /// Train lines: line name in the data (route_long_name) → short and full name on the line badge. Full names don't fit the badge, so use 2–3 letters.
    public struct RailLine: Sendable {
        public var dataName: String
        public var code: String
        public var name: String
    }

    public static let railLines: [Source: [RailLine]] = [
        .hartfordLine: [.init(dataName: "Hartford Line", code: "HL", name: "Hartford Line")],
        // MARC: only the Penn Line reaches Perryville; the others are listed so their trains keep their own badges if ever kept
        .marc: [
            .init(dataName: "PENN - WASHINGTON", code: "PEN", name: "Penn Line"),
            .init(dataName: "CAMDEN - WASHINGTON", code: "CAM", name: "Camden Line"),
            .init(dataName: "BRUNSWICK - WASHINGTON", code: "BRU", name: "Brunswick Line"),
        ],
        .lirr: [
            .init(dataName: "Babylon Branch", code: "BAB", name: "Babylon Branch"),
            .init(dataName: "Hempstead Branch", code: "HEM", name: "Hempstead Branch"),
            .init(dataName: "Oyster Bay Branch", code: "OB", name: "Oyster Bay Branch"),
            .init(dataName: "Ronkonkoma Branch", code: "RON", name: "Ronkonkoma Branch"),
            .init(dataName: "Montauk Branch", code: "MTK", name: "Montauk Branch"),
            .init(dataName: "Long Beach Branch", code: "LB", name: "Long Beach Branch"),
            .init(dataName: "Far Rockaway Branch", code: "FR", name: "Far Rockaway Branch"),
            .init(dataName: "West Hempstead Branch", code: "WH", name: "West Hempstead Branch"),
            .init(dataName: "Port Washington Branch", code: "PW", name: "Port Washington Branch"),
            .init(dataName: "Port Jefferson Branch", code: "PJ", name: "Port Jefferson Branch"),
            .init(dataName: "Belmont Park", code: "BEL", name: "Belmont Park"),
            .init(dataName: "City Terminal Zone", code: "CTZ", name: "City Terminal Zone"),
            .init(dataName: "Greenport Service", code: "GP", name: "Greenport"),
        ],
        .metroNorth: [
            .init(dataName: "Hudson", code: "HUD", name: "Hudson Line"),
            .init(dataName: "Harlem", code: "HAR", name: "Harlem Line"),
            .init(dataName: "New Haven", code: "NH", name: "New Haven Line"),
            .init(dataName: "New Canaan", code: "NC", name: "New Canaan Branch"),
            .init(dataName: "Danbury", code: "DAN", name: "Danbury Branch"),
            .init(dataName: "Waterbury", code: "WTB", name: "Waterbury Branch"),
        ],
        // PATH: line names give the two terminal stations (badges read like "NWK-WTC")
        .path: [
            .init(dataName: "Newark - World Trade Center", code: "NWK-WTC", name: "Newark–World Trade Center"),
            .init(dataName: "Hoboken - World Trade Center", code: "HOB-WTC", name: "Hoboken–World Trade Center"),
            .init(dataName: "Journal Square - 33rd Street", code: "JSQ-33", name: "Journal Square–33rd Street"),
            .init(dataName: "Hoboken - 33rd Street", code: "HOB-33", name: "Hoboken–33rd Street"),
            .init(dataName: "Journal Square - 33rd Street (via Hoboken)", code: "JSQ-HOB-33",
                  name: "Journal Square–33rd Street via Hoboken"),
            .init(dataName: "Newark - Harrison Shuttle Train", code: "NWK-HAR", name: "Newark–Harrison Shuttle"),
            .init(dataName: "World Trade Center - 33rd Street", code: "WTC-33", name: "World Trade Center–33rd Street"),
        ],
        // NJ Transit: lines with two route_ids in the data (e.g. Montclair-Boonton, North Jersey Coast) are merged into one
        .njTransitRail: [
            .init(dataName: "Atlantic City Rail Line", code: "ACL", name: "Atlantic City Rail Line"),
            .init(dataName: "Montclair-Boonton Line", code: "MOB", name: "Montclair-Boonton Line"),
            .init(dataName: "Main/Bergen County Line", code: "MBL", name: "Main/Bergen County Line"),
            .init(dataName: "Port Jervis Line", code: "PJL", name: "Port Jervis Line"),
            .init(dataName: "Morris & Essex Line", code: "M&E", name: "Morris & Essex Line"),
            .init(dataName: "Gladstone Branch", code: "GLA", name: "Gladstone Branch"),
            .init(dataName: "Meadowlands Rail Line", code: "MRL", name: "Meadowlands Rail Line"),
            .init(dataName: "Northeast Corridor", code: "NEC", name: "Northeast Corridor"),
            .init(dataName: "North Jersey Coast Line", code: "NJC", name: "North Jersey Coast Line"),
            .init(dataName: "Pascack Valley Line", code: "PVL", name: "Pascack Valley Line"),
            .init(dataName: "Princeton Shuttle", code: "PRI", name: "Princeton Shuttle (Dinky)"),
            .init(dataName: "Raritan Valley Line", code: "RVL", name: "Raritan Valley Line"),
        ],
        .amtrakNY: [
            .init(dataName: "Acela", code: "ACE", name: "Acela"),
            .init(dataName: "Northeast Regional", code: "NER", name: "Northeast Regional"),
            .init(dataName: "Keystone Service", code: "KEY", name: "Keystone Service"),
            .init(dataName: "Empire Service", code: "EMP", name: "Empire Service"),
            .init(dataName: "Adirondack", code: "ADK", name: "Adirondack"),
            .init(dataName: "Ethan Allen Express", code: "EAE", name: "Ethan Allen Express"),
            .init(dataName: "Lake Shore Limited", code: "LSL", name: "Lake Shore Limited"),
            .init(dataName: "Maple Leaf", code: "ML", name: "Maple Leaf"),
            .init(dataName: "Vermonter", code: "VT", name: "Vermonter"),
            .init(dataName: "Amtrak Hartford Line", code: "HFL", name: "Hartford Line"),
            // Found by its agency, not by this name (see shoreLineEast)
            .init(dataName: "Shore Line East", code: "SLE", name: "Shore Line East"),
            .init(dataName: "Valley Flyer", code: "VF", name: "Valley Flyer"),
            .init(dataName: "Berkshire Flyer", code: "BF", name: "Berkshire Flyer"),
            .init(dataName: "Pennsylvanian", code: "PEN", name: "Pennsylvanian"),
            .init(dataName: "Cardinal", code: "CDL", name: "Cardinal"),
            .init(dataName: "Carolinian", code: "CAR", name: "Carolinian"),
            .init(dataName: "Crescent", code: "CRE", name: "Crescent"),
            .init(dataName: "Palmetto", code: "PAL", name: "Palmetto"),
            .init(dataName: "Silver Meteor", code: "SM", name: "Silver Meteor"),
            .init(dataName: "Silver Star", code: "SS", name: "Silver Star"),
            .init(dataName: "Piedmont", code: "PIE", name: "Piedmont"),
        ],
        // SEPTA: its own three-letter line codes (the data's route_id and route_short_name)
        .septaRail: [
            .init(dataName: "Airport Line", code: "AIR", name: "Airport Line"),
            .init(dataName: "Chestnut Hill East Line", code: "CHE", name: "Chestnut Hill East Line"),
            .init(dataName: "Chestnut Hill West Line", code: "CHW", name: "Chestnut Hill West Line"),
            .init(dataName: "Cynwyd Line", code: "CYN", name: "Cynwyd Line"),
            .init(dataName: "Fox Chase Line", code: "FOX", name: "Fox Chase Line"),
            .init(dataName: "Lansdale/Doylestown Line", code: "LAN", name: "Lansdale/Doylestown Line"),
            .init(dataName: "Manayunk/Norristown Line", code: "NOR", name: "Manayunk/Norristown Line"),
            .init(dataName: "Media/Wawa Line", code: "MED", name: "Media/Wawa Line"),
            .init(dataName: "Paoli/Thorndale Line", code: "PAO", name: "Paoli/Thorndale Line"),
            .init(dataName: "Trenton Line", code: "TRE", name: "Trenton Line"),
            .init(dataName: "Warminster Line", code: "WAR", name: "Warminster Line"),
            .init(dataName: "West Trenton Line", code: "WTR", name: "West Trenton Line"),
            .init(dataName: "Wilmington/Newark Line", code: "WIL", name: "Wilmington/Newark Line"),
        ],
        .njTransitLightRail: [
            .init(dataName: "Hudson-Bergen Light Rail", code: "HBL", name: "Hudson-Bergen Light Rail"),
            .init(dataName: "Newark Light Rail", code: "NLR", name: "Newark Light Rail"),
            .init(dataName: "Riverline Light Rail", code: "RL", name: "River LINE"),
        ],
        // SEPTA Metro: found by their route_id, the line code (see Source.routeID). The names keep the code the badge shows; the
        // T trolleys are named after the avenues they run along
        .septaMetro: [
            .init(dataName: "L1", code: "L1", name: "L1 Market-Frankford Line"),
            .init(dataName: "B1", code: "B1", name: "B1 Broad Street Line Local"),
            .init(dataName: "B2", code: "B2", name: "B2 Broad Street Line Express"),
            .init(dataName: "B3", code: "B3", name: "B3 Broad-Ridge Spur"),
            .init(dataName: "M1", code: "M1", name: "M1 Norristown High Speed Line"),
            .init(dataName: "T1", code: "T1", name: "T1 Lancaster Avenue Trolley"),
            .init(dataName: "T2", code: "T2", name: "T2 Baltimore Avenue Trolley"),
            .init(dataName: "T3", code: "T3", name: "T3 Chester Avenue Trolley"),
            .init(dataName: "T4", code: "T4", name: "T4 Woodland Avenue Trolley"),
            .init(dataName: "T5", code: "T5", name: "T5 Elmwood Avenue Trolley"),
            .init(dataName: "G1", code: "G1", name: "G1 Girard Avenue Trolley"),
            .init(dataName: "D1", code: "D1", name: "D1 Media Line"),
            .init(dataName: "D2", code: "D2", name: "D2 Sharon Hill Line"),
        ],
        .patco: [.init(dataName: "High Speed Line", code: "PATCO", name: "Speedline")],
        // The MBTA's subway: the badges the MBTA's own maps and signs use (RL, OL, BL, M), the Green Line's branches by their letters
        .mbtaSubway: [
            .init(dataName: "Red Line", code: "RL", name: "Red Line"),
            .init(dataName: "Orange Line", code: "OL", name: "Orange Line"),
            .init(dataName: "Blue Line", code: "BL", name: "Blue Line"),
            .init(dataName: "Green Line B", code: "B", name: "Green Line B"),
            .init(dataName: "Green Line C", code: "C", name: "Green Line C"),
            .init(dataName: "Green Line D", code: "D", name: "Green Line D"),
            .init(dataName: "Green Line E", code: "E", name: "Green Line E"),
            .init(dataName: "Mattapan Line", code: "M", name: "Mattapan Line"),
        ],
        // MBTA Commuter Rail: three letters from each line's name. The CapeFLYER (Boston to Hyannis in summer) comes in the same
        // package, though it's the Cape Cod Regional Transit Authority's (see routeName)
        .mbtaRail: [
            .init(dataName: "Fairmount Line", code: "FMT", name: "Fairmount Line"),
            .init(dataName: "Fall River/New Bedford Line", code: "NBD", name: "Fall River/New Bedford Line"),
            .init(dataName: "Fitchburg Line", code: "FBG", name: "Fitchburg Line"),
            .init(dataName: "Framingham/Worcester Line", code: "WOR", name: "Framingham/Worcester Line"),
            .init(dataName: "Franklin/Foxboro Line", code: "FRK", name: "Franklin/Foxboro Line"),
            .init(dataName: "Greenbush Line", code: "GRB", name: "Greenbush Line"),
            .init(dataName: "Haverhill Line", code: "HVL", name: "Haverhill Line"),
            .init(dataName: "Kingston Line", code: "KNG", name: "Kingston Line"),
            .init(dataName: "Lowell Line", code: "LWL", name: "Lowell Line"),
            .init(dataName: "Needham Line", code: "NDM", name: "Needham Line"),
            .init(dataName: "Newburyport/Rockport Line", code: "NBP", name: "Newburyport/Rockport Line"),
            .init(dataName: "Providence/Stoughton Line", code: "PVD", name: "Providence/Stoughton Line"),
            .init(dataName: "Foxboro Event Service", code: "FOX", name: "Foxboro Event Service"),
            .init(dataName: "CapeFLYER", code: "CF", name: "CapeFLYER"),
        ],
        // MBTA ferries: the MBTA's own route numbers (F1, F2H…); the two without one by their places
        .mbtaFerry: [
            .init(dataName: "Hingham Ferry", code: "F1", name: "Hingham Ferry"),
            .init(dataName: "Hingham/Hull Ferry", code: "F2H", name: "Hingham/Hull Ferry"),
            .init(dataName: "Charlestown Ferry", code: "F4", name: "Charlestown Ferry"),
            .init(dataName: "Winthrop Ferry", code: "F6", name: "Winthrop Ferry"),
            .init(dataName: "Quincy Ferry", code: "F7", name: "Quincy Ferry"),
            .init(dataName: "Winthrop/Quincy Ferry", code: "F8", name: "Winthrop/Quincy Ferry"),
            .init(dataName: "Harbor Loop Ferry", code: "F10", name: "Harbor Loop Ferry"),
            .init(dataName: "East Boston Ferry", code: "EB", name: "East Boston Ferry"),
            .init(dataName: "Lynn Ferry", code: "LYN", name: "Lynn Ferry"),
        ],
    ]
}
