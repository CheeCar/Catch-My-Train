import Foundation

/// Who the transit data comes from: every operator by its full name, in one list. The app's own credits are made per metro area
/// from areas.json (About and How It Works name the start place's area's operators, ModeCoverage.credits(in:); the station footers
/// a station's; Settings' data source every area's), with the hosts below. This list is the one docs/data-sources.md is checked
/// against: when a source is added or removed, update it together with docs/data-sources.md (every operator) and README.md;
/// DataCreditsTests checks it against the feeds and those pages. The pages in docs/data-sources/ split it by area.
/// Operator names are the same in every language.
public enum DataCredits {
    /// The subway stations, subway map and MTA bus stops that ship inside the app are made from MTA open data (the stations without
    /// times, also inside it, come from public federal and Port Authority data, see NoTimesStations).
    public static let bundled = ["MTA"]

    /// Every operator whose public data the app downloads.
    public static let downloaded = [
        "MTA (New York City Transit, MTA Bus, LIRR, Metro-North)",
        "NJ Transit",
        "Port Authority (PATH)",
        "Amtrak",
        "Maryland Transit Administration (MARC)",
        "SEPTA",
        "Delaware River Port Authority (PATCO)",
        "Connecticut DOT (CTtransit, CTrail Hartford Line, CTrail Shore Line East)",
        "Greater Bridgeport Transit",
        "Norwalk Transit District",
        "River Valley Transit",
        "Southeast Area Transit",
        "NICE",
        "Suffolk County Transit",
        "Westchester County Bee-Line",
        "Hudson Link",
        "Clarkstown Mini-Trans",
        "Putnam Transit",
        "Dutchess County Public Transit",
        "Leprechaun Lines",
        "Ulster County Area Transit",
        "Sullivan County Transit",
        "Huntington HART",
        "Long Beach Bus",
        "Philadelphia Visitors Center Corporation (PHLASH)",
        "Pottstown Area Rapid Transit",
        "Transportation Management Association of Chester County (TMACC ChescoBus)",
        "Greater Valley Forge TMA (Upper Merion Rambler)",
        "BARTA",
        "Cecil Transit",
        "Cross County Connection (BurLINK)",
        "Gloucester County (Gloucester County Shuttle)",
        "Atlantic County (Atlantic County Shuttles)",
        "Cumberland County Division of Employment and Training (Cumberland County Shuttles)",
        "South Jersey Transportation Authority (SJTA)",
        "Lehigh and Northampton Transportation Authority (LANta)",
        "Monroe County Transit Authority (Pocono Pony)",
        "Warren County (Warren County Transportation)",
        "Trans-Bridge Lines",
        "Coach USA (ShortLine Hudson, Suburban Transit, Rockland Coaches, Community Coach, Newark Airport Express, Orange Westchester Link)",
        "Lakeland Bus Lines",
        "Hunterdon County (Hunterdon County LINK)",
        "Academy Bus",
        "Somerset County (Somerset County Transportation)",
        "Sussex County (Sussex County Skylands Ride)",
        "Massachusetts Department of Transportation (MBTA, CapeFLYER)",
        "Rhode Island Public Transit Authority (RIPTA)",
        "Worcester Regional Transit Authority (WRTA)",
        "Lowell Regional Transit Authority (LRTA)",
        "Greater Attleboro Taunton Regional Transit Authority (GATRA)",
        "Southeastern Regional Transit Authority (SRTA)",
        "Brockton Area Transit Authority (BAT)",
        "Cape Cod Regional Transit Authority (CCRTA)",
        "Montachusett Regional Transit Authority (MART)",
        "Merrimack Valley Regional Transit Authority (MeVa Transit)",
        "Cape Ann Transportation Authority (CATA)",
        "MetroWest Regional Transit Authority (MWRTA)",
        "Massport (Massachusetts Port Authority)",
        "Manchester Transit Authority",
        "Nashua Transit System",
        "Cooperative Alliance for Seacoast Transportation (COAST)",
        "Martha's Vineyard Transit Authority (VTA)",
        "Nantucket Regional Transit Authority (The WAVE)",
        "Pioneer Valley Transit Authority (PVTA)",
        "Franklin Regional Transit Authority (FRTA)",
        "Berkshire Regional Transit Authority (BRTA)",
        "Northeastern Connecticut Transit District (NECTD)",
        "Windham Region Transit District (WRTD)",
        "Northwestern Connecticut Transit District (NWCTD)",
        "NYC Ferry",
        "NY Waterway",
        "NYC DOT (Staten Island Ferry)",
        "Seastreak",
        "National Park Service (Statue of Liberty Ferry, Boston Harbor Islands Ferry, Cathleen Stone Island Ferry)",
        "Delaware River and Bay Authority (Cape May–Lewes Ferry)",
        "Hy-Line Cruises",
        "Bay State Cruise Company",
        "Block Island Ferry",
        "Cuttyhunk Ferry Company (Cuttyhunk Ferry)",
        "Patriot Party Boats",
        "Freedom Cruise Line",
        "Vineyard Fast Ferry",
        "RIOC (Roosevelt Island Tram)",
    ]

    /// Services that host some of the operators' feeds (National RTAP: PATCO's, the Upper Merion Rambler's, Manchester's and
    /// Nashua's timetables; Trillium: several around Boston and in western Massachusetts, Massport's and the ferries' to the islands
    /// among them; Modeshift: TMACC's; Passio: Cecil Transit's, BAT's, COAST's, FRTA's live data and WRTD's; Arcadis: NECTD's and
    /// NWCTD's timetables).
    public static let hosts = ["511NY", "Trillium", "National RTAP", "Modeshift", "Passio", "Arcadis"]

    /// Bus data, for the bus station footer: MTA plus every regional bus feed, so a new feed is credited automatically.
    public static var bus: [String] { ["MTA"] + RegionalBusFeed.all.map(\.name) }
}
