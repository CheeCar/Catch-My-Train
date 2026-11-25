import Foundation

// MARK: - Downloaded only where of use

/// A box inside a metro area whose operators' data is downloaded only once a place in use is inside it, not for every place in the area
/// (see PlacesInUse.wants): their package is large and of no use anywhere else. SEPTA's has all its buses and its Metro in one 26 MB file, which nobody using only New York has a need for
public enum DownloadArea: String, CaseIterable, Sendable {
    /// Where SEPTA's buses and Metro stop (Claymont DE to Doylestown, Coatesville to Trenton), with a long walk's margin all around.
    /// Pottstown's and Upper Merion's buses are inside it too
    case philadelphia
    /// Reading and Berks County, where BARTA's buses run, with the same margin
    case reading
    /// Chester County from West Chester west, and Cecil County, MD: TMACC's and Cecil Transit's buses (Cecil Transit's line to Newark, DE
    /// too), with the same margin
    case chesterAndCecil
    /// South Jersey, from Pennsauken and Logan Township to Atlantic City and Bridgeton: the county shuttles' and SJTA's buses, with the
    /// same margin
    case southJersey
    /// The Lehigh Valley, from Carbon County and Allentown to the Pocono Pony's stops in Monroe County and Warren County's shuttles from
    /// Phillipsburg to Hackettstown: LANta's, the Pocono Pony's and Warren County's buses, with the same margin
    case lehighValley
    /// Cape May, where the Cape May–Lewes Ferry leaves, with the same margin
    case capeMay
    /// Greater Boston, from Worcester County, Rhode Island and Cape Cod to southern New Hampshire: the MBTA's subway, trains, buses
    /// and ferries (one 22 MB package), with the same margin
    case greaterBoston
    // Around Greater Boston, one per operator: where its stops are, with about 4 km more all around
    /// RIPTA: all of Rhode Island
    case rhodeIsland
    /// WRTA: Worcester and its neighbors
    case worcester
    /// LRTA: Lowell and its neighbors
    case lowell
    /// GATRA: Attleboro, Taunton, Wareham and the towns between
    case attleboroAndTaunton
    /// SRTA: Fall River, New Bedford and the towns between
    case fallRiverAndNewBedford
    /// BAT: Brockton and its neighbors, to Ashmont in Boston
    case brockton
    /// CCRTA: Cape Cod, from Bourne and Woods Hole to Provincetown
    case capeCod
    /// MART: Fitchburg, Leominster, Gardner and Athol, with its shuttles to Worcester, Concord and Boston
    case montachusett
    /// MeVa: Lawrence, Haverhill, Newburyport and Salisbury Beach, to Lowell
    case merrimackValley
    /// CATA: Gloucester and Rockport, to the Northshore Mall in Peabody
    case capeAnn
    /// MWRTA: Framingham, Natick and their neighbors
    case metroWest
    /// Massport: the Logan Express buses from Back Bay, Braintree, Danvers, Framingham and Woburn, and the shuttles at the airport
    case loganExpress
    /// Manchester Transit Authority: Manchester, with its express buses to Concord, Nashua and Salem, NH
    case manchester
    /// Nashua Transit System: Nashua
    case nashua
    /// COAST: Portsmouth, Dover and Rochester, NH, and Berwick, South Berwick, Eliot and Kittery, ME
    case seacoast
    /// VTA: Martha's Vineyard
    case marthasVineyard
    /// The WAVE: Nantucket
    case nantucket
    // Greater Hartford and Western Massachusetts, one per operator, the same way (CTtransit, the Hartford Line and Amtrak are
    // downloaded for everyone in their areas)
    /// PVTA: Springfield, Holyoke, Westfield, Northampton and Amherst, to Ware, Palmer, Enfield, the Brookfields and Worcester
    case pioneerValley
    /// FRTA: Greenfield and Franklin County, to Northampton and Athol
    case franklinCounty
    /// BRTA: the Berkshires, with the Link413 buses to Greenfield and Northampton
    case berkshires
    /// NECTD: Putnam, Killingly, Brooklyn and Plainfield, to Jewett City
    case northeasternConnecticut
    /// WRTD: Willimantic and Storrs, to Norwich and Danielson
    case windham
    /// NWCTD: Torrington and Winsted, to Canaan
    case northwestHills
    // New Jersey and the Hudson Valley, one per operator, the same way. The coaches that stop at Port Authority Bus Terminal
    // (Newark Airport Express at Grand Central too) are downloaded for Manhattan as well: a ride home from there
    /// ShortLine Hudson: Manhattan to Orange and Sullivan Counties, Binghamton, Honesdale and Bergen County
    case shortLine
    /// Suburban Transit: Princeton, New Brunswick and East Brunswick to Manhattan
    case suburbanTransit
    /// Rockland Coaches: Rockland County and Bergen County to Manhattan
    case rocklandCoaches
    /// Community Coach: Livingston and West Orange to Manhattan
    case communityCoach
    /// Newark Airport Express: Newark Airport to Port Authority Bus Terminal and Grand Central
    case newarkAirportExpress
    /// Orange Westchester Link: Middletown to White Plains
    case orangeWestchester
    /// Lakeland Bus Lines: Dover and Bernardsville to Manhattan
    case lakeland
    /// Hunterdon County LINK: Hunterdon County, to Somerville
    case hunterdon
    /// Academy Bus: Monmouth, Ocean and Burlington Counties to Manhattan
    case academy
    /// Somerset County Transportation: Somerset County, to New Brunswick
    case somerset
    /// Sussex County Skylands Ride: Sussex County, to Netcong
    case sussex

    /// One latitude/longitude box (north latitude, longitude)
    var box: (lat: ClosedRange<Double>, lon: ClosedRange<Double>) {
        switch self {
        case .philadelphia: return (39.75...40.39, -75.90 ... -74.69)
        case .reading: return (40.18...40.62, -76.27 ... -75.51)
        case .chesterAndCecil: return (39.50...40.12, -76.17 ... -75.55)
        case .southJersey: return (39.31...40.15, -75.40 ... -74.38)
        case .lehighValley: return (40.47...41.27, -75.95 ... -74.77)
        case .capeMay: return (38.85...39.13, -75.10 ... -74.75)
        case .greaterBoston: return (41.10...43.85, -72.40 ... -69.85)
        case .rhodeIsland: return (41.33...42.06, -71.87 ... -71.11)
        case .worcester: return (41.99...42.40, -72.14 ... -71.60)
        case .lowell: return (42.44...42.74, -71.51 ... -71.13)
        case .attleboroAndTaunton: return (41.60...42.19, -71.45 ... -70.50)
        case .fallRiverAndNewBedford: return (41.56...41.80, -71.26 ... -70.62)
        case .brockton: return (41.66...42.33, -71.20 ... -70.87)
        case .capeCod: return (41.48...42.12, -70.71 ... -69.92)
        case .montachusett: return (42.22...42.73, -72.36 ... -71.23)
        case .merrimackValley: return (42.60...42.90, -71.36 ... -70.78)
        case .capeAnn: return (42.50...42.73, -70.99 ... -70.56)
        case .metroWest: return (42.05...42.50, -71.66 ... -71.20)
        case .loganExpress: return (42.18...42.60, -71.44 ... -70.90)
        case .manchester: return (42.72...43.26, -71.58 ... -71.17)
        case .nashua: return (42.66...42.85, -71.62 ... -71.40)
        case .seacoast: return (42.98...43.44, -71.13 ... -70.70)
        case .marthasVineyard: return (41.28...41.52, -70.89 ... -70.46)
        case .nantucket: return (41.20...41.34, -70.25 ... -69.91)
        case .pioneerValley: return (41.98...42.52, -72.85 ... -71.75)
        case .franklinCounty: return (42.28...42.67, -72.93 ... -72.21)
        case .berkshires: return (42.13...42.76, -73.43 ... -72.55)
        case .northeasternConnecticut: return (41.55...42.02, -72.04 ... -71.81)
        case .windham: return (41.43...41.92, -72.40 ... -71.80)
        case .northwestHills: return (41.69...42.06, -73.38 ... -73.00)
        case .shortLine: return (40.67...42.14, -75.96 ... -73.88)
        case .suburbanTransit: return (40.23...40.80, -74.71 ... -73.92)
        case .rocklandCoaches: return (40.72...41.26, -74.12 ... -73.86)
        case .communityCoach: return (40.71...40.84, -74.41 ... -73.92)
        case .newarkAirportExpress: return (40.64...40.80, -74.24 ... -73.92)
        case .orangeWestchester: return (40.97...41.49, -74.47 ... -73.66)
        case .lakeland: return (40.60...41.08, -74.77 ... -73.94)
        case .hunterdon: return (40.32...40.75, -75.15 ... -74.56)
        case .academy: return (39.91...40.80, -74.94 ... -73.92)
        case .somerset: return (40.45...40.69, -74.74 ... -74.38)
        case .sussex: return (40.86...41.25, -74.82 ... -74.52)
        }
    }

    public func contains(_ c: Coordinate) -> Bool { box.lat.contains(c.latitude) && box.lon.contains(c.longitude) }
}

/// The places the app is using now, which decide which metro areas' data is downloaded (see AreaData): the main window's starting
/// point, the favorites and Plan a Trip's places. Recent places don't count (with up to ten of them, a trip across the country would
/// keep ten areas); choosing one makes it the starting point. Favorites in an area the user removed don't count either, until a place
/// there is chosen. Each part sets its own, so one doesn't clear the other's. Kept in memory only, never saved; until a part sets
/// them, it has none
public enum PlacesInUse {
    public enum Part: Sendable { case start, favorites, planner }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var places: [Part: [Coordinate]] = [:]
    nonisolated(unsafe) private static var removed: Set<MetroArea> = []
    /// Worked out again whenever a part or the removed areas change: asked for every operator on every refresh
    nonisolated(unsafe) private static var known: (counting: [Coordinate], kept: Set<MetroArea>) = ([], [])

    public static func set(_ part: Part, _ coordinates: [Coordinate]) {
        lock.lock(); defer { lock.unlock() }
        places[part] = coordinates
        workOut()
    }

    /// The areas the user removed (AreaData.removed): their favorites don't keep them
    public static func setRemoved(_ areas: Set<MetroArea>) {
        lock.lock(); defer { lock.unlock() }
        removed = areas
        workOut()
    }

    private static func workOut() {
        let favorites = (places[.favorites] ?? []).filter { c in MetroArea.of(c).map { !removed.contains($0) } ?? true }
        let counting = (places[.start] ?? []) + (places[.planner] ?? []) + favorites
        known = (counting, Set(counting.compactMap(MetroArea.of)))
    }

    /// The metro areas whose data is downloaded and kept up to date now: one of the places that count is in each
    public static var keptAreas: Set<MetroArea> {
        lock.lock(); defer { lock.unlock() }
        return known.kept
    }

    public static func keeps(_ area: MetroArea) -> Bool { keptAreas.contains(area) }

    /// The metro areas of one part's places, favorites in removed areas too (for Settings' Downloaded data, see AreaData.reason)
    public static func areas(_ part: Part) -> Set<MetroArea> {
        lock.lock(); defer { lock.unlock() }
        return Set((places[part] ?? []).compactMap(MetroArea.of))
    }

    /// Whether one of the places that count is inside this box
    public static func any(in area: DownloadArea) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return known.counting.contains(where: area.contains)
    }

    /// Whether the data of an operator with stops in these areas is downloaded now: one of them is kept, and for one downloaded only
    /// near its stops (box), one of the places that count is inside its box. SEPTA's buses also reach Trenton, in New York's area:
    /// without the box, everyone using New York would download them
    public static func wants(areas: [MetroArea], box: DownloadArea?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard areas.contains(where: known.kept.contains) else { return false }
        return box.map { b in known.counting.contains(where: b.contains) } ?? true
    }

    /// For tests: no places in use, no area removed
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        places = [:]
        removed = []
        workOut()
    }
}

// MARK: - Which areas' data stays

/// Which metro areas' downloaded data stays on this Mac. An area is kept, its data downloaded and checked for updates, while the
/// starting point, a Plan a Trip place or a favorite is in it (PlacesInUse). Another area's data stays, without updates, until
/// keepDays after it was last used (AreaUsage), and is then removed; downloaded again when a place there is used. An area the user
/// removed (Settings' Remove…) is removed now, and its favorites don't download it again until a place there is chosen as the starting
/// point or in Plan a Trip. An operator with stops in several areas (NJ Transit, Amtrak…) stays while one of its areas does
public enum AreaData {
    public static let keepDays = 30
    /// The settings key of the areas the user removed (area ids)
    public static let removedKey = "areas.removedByYou"
    /// The settings key saying the dates of use were started (see startingDates)
    public static let datesStartedKey = "areas.datesStarted"

    /// Why an area's data is on this Mac, or that the user removed it (Settings' Downloaded data)
    public enum Reason: Equatable, Sendable {
        case start, planner, favorites
        /// Not kept: removed on `until` unless used again
        case unused(since: Date, until: Date)
        /// Removed by the user, with favorites in it
        case removedByYou

        /// Whether its data stays
        public var keepsData: Bool { self != .removedByYou }
        /// Whether Settings' Remove… can remove it (not while the starting point or a Plan a Trip place is in it)
        public var canRemove: Bool { self != .start && self != .planner && self != .removedByYou }
    }

    /// The day an area last used at `lastUsed` is removed, if not used again
    public static func removalDate(lastUsed: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: keepDays, to: lastUsed) ?? lastUsed.addingTimeInterval(Double(keepDays) * 86_400)
    }

    /// Why this area's data stays (or that the user removed it); nil: no reason, its data goes (or it was never used)
    public static func reason(for area: MetroArea, start: MetroArea?, planner: Set<MetroArea>, favorites: Set<MetroArea>,
                              removed: Set<MetroArea>, lastUsed: Date?, now: Date, calendar: Calendar = .current) -> Reason? {
        if area == start { return .start }
        if planner.contains(area) { return .planner }
        if removed.contains(area) { return favorites.contains(area) ? .removedByYou : nil }
        if favorites.contains(area) { return .favorites }
        guard let lastUsed else { return nil }
        let until = removalDate(lastUsed: lastUsed, calendar: calendar)
        return now < until ? .unused(since: lastUsed, until: until) : nil
    }

    /// Settings' Downloaded data: what each area's own operators take, what those in several areas (or in none known) take
    /// together, and the total, which the two add up to. Each operator's areas with its size
    public static func split(_ sizes: [(areas: [MetroArea], size: Int64)]) -> (own: [MetroArea: Int64], shared: Int64, total: Int64) {
        var own: [MetroArea: Int64] = [:]
        var shared: Int64 = 0
        for item in sizes {
            if item.areas.count == 1 { own[item.areas[0], default: 0] += item.size } else { shared += item.size }
        }
        return (own, shared, own.values.reduce(0, +) + shared)
    }

    /// Whether an operator's data stays: one of its areas' data does. One with no known area is never removed
    public static func keeps(operatorIn areas: [MetroArea], keeping: Set<MetroArea>) -> Bool {
        areas.isEmpty || areas.contains(where: keeping.contains)
    }

    /// The removed areas after a place in one came into use as the starting point or in Plan a Trip: that one is no longer removed
    public static func removedMarks(_ removed: Set<MetroArea>, start: MetroArea?, planner: Set<MetroArea>) -> Set<MetroArea> {
        removed.subtracting(planner).subtracting(start.map { [$0] } ?? [])
    }

    /// The removed areas saved in `defaults` (the app's own settings, kept only on this Mac); ids of areas that no longer exist are
    /// left out
    public static func removed(in defaults: UserDefaults = .standard) -> Set<MetroArea> {
        Set(((defaults.array(forKey: removedKey) as? [String]) ?? []).compactMap(MetroArea.init(rawValue:)))
    }

    public static func saveRemoved(_ areas: Set<MetroArea>, in defaults: UserDefaults = .standard) {
        if areas.isEmpty { defaults.removeObject(forKey: removedKey) } else { defaults.set(areas.map(\.rawValue).sorted(), forKey: removedKey) }
    }

    /// The first time this version runs: an area with data on this Mac but no date of last use (the dates started in the version
    /// before) gets `now`, so nothing is removed for keepDays after the update. The dates to save; nil when none is missing
    public static func startingDates(_ dates: [MetroArea: Date], withData: Set<MetroArea>, now: Date) -> [MetroArea: Date]? {
        let missing = withData.filter { dates[$0] == nil }
        guard !missing.isEmpty else { return nil }
        var out = dates
        for area in missing { out[area] = now }
        return out
    }
}
