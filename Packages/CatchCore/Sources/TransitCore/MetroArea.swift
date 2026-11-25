import Foundation

// MARK: - Metro areas

/// The metro areas the app covers (areas.json). Settings lists each one's data sources on its own; the title bar's regions belong to
/// one each (MetroSubRegion.metroArea)
public enum MetroArea: String, CaseIterable, Sendable {
    case newYork, philadelphia, lehighValley, greaterBoston, greaterHartford, westernMassachusetts

    /// English name (UI translation key), from areas.json
    public var nameKey: String { AreaCatalog.shared.area(rawValue)?.name ?? rawValue }

    /// The area's own time zone, from areas.json (the only place the app names one): its timetables' days are counted in it and
    /// its times are shown in it. MetroAreaMapTests checks that every area's is a real one; GMT would only be a last resort
    public var timeZone: TimeZone { Self.timeZones[self] ?? TimeZone(secondsFromGMT: 0)! }
    /// Read once: the text and the timetables ask for it many times a second
    private static let timeZones: [MetroArea: TimeZone] = Dictionary(uniqueKeysWithValues: allCases.compactMap { area in
        AreaCatalog.shared.area(area.rawValue).flatMap { TimeZone(identifier: $0.timeZone) }.map { (area, $0) }
    })

    /// This area's regions, in areas.json's order
    public var regions: [MetroSubRegion] {
        AreaCatalog.shared.area(rawValue)?.regions.compactMap { MetroSubRegion(rawValue: $0.id) } ?? []
    }

    /// The states this area is in, by their English names (UI translation keys), the one with the most of its counties first:
    /// worked out from its counties (areas.json), so a new area needs nothing written here
    public var stateKeys: [String] { Self.statesByArea[self] ?? [] }
    /// Read once: a list shows them in every row
    private static let statesByArea: [MetroArea: [String]] = Dictionary(uniqueKeysWithValues: allCases.map { area in
        (area, AreaCatalog.shared.area(area.rawValue).map(AreaCatalog.shared.stateNames(of:)) ?? [])
    })

    /// The names the full list's search finds this area by: its own, its regions' and its states', each as `translated` gives
    /// it (the app's language) and in English
    public func searchNames(_ translated: (String) -> String) -> [String] {
        var seen = Set<String>()
        return ([nameKey] + regions.map(\.nameKey) + stateKeys).flatMap { [translated($0), $0] }.filter { seen.insert($0).inserted }
    }

    /// The time zone a place's times are shown in: its metro area's; outside the service area, this Mac's own (`mac`, the
    /// system's by default)
    public static func timeZone(at place: Coordinate?, mac: TimeZone = .current) -> TimeZone {
        place.flatMap { of($0) }?.timeZone ?? mac
    }

    /// The metro area of a place; nil outside the service area
    public static func of(_ c: Coordinate) -> MetroArea? { MetroSubRegion.of(c)?.metroArea }

    /// The metro area of a place, or outside them all the one with the nearest county: Settings' data source page and the map's
    /// Whole Map open there, rather than in any one area. Nil only without the county outlines
    public static func nearest(to c: Coordinate) -> MetroArea? {
        if let area = of(c) { return area }
        guard let county = CountyMap.shared?.countedCounty(near: c)?.code,
              let region = AreaCatalog.shared.region(ofCounty: county) else { return nil }
        return MetroArea(rawValue: region.area)
    }

    /// The metro areas an operator has stops in (areas.json's "operators"; an operator in two is listed in both), in this enum's order
    public static func areas(ofOperator id: String) -> [MetroArea] {
        guard let op = AreaCatalog.shared.operator(id) else { return [] }
        return allCases.filter { op.kinds[$0.rawValue] != nil }
    }

    /// The metro areas a timetable source has stops in. MARC's only station kept is Perryville (Cecil County); the Cape May–Lewes
    /// Ferry's only pier kept is Cape May; NJ Transit, Amtrak and SEPTA's trains stop in both (Trenton is in Mercer County)
    public static func areas(of source: FerryFeed.Source) -> [MetroArea] { areas(ofOperator: source.rawValue) }

    /// The metro areas a bus company has stops in (NJ Transit's: see its FerryFeed.Source; SEPTA's route 127 reaches Trenton). One
    /// areas.json doesn't list yet (a company the source list added) is taken to be New York's
    public static func areas(ofBus feed: RegionalBusFeed) -> [MetroArea] {
        if feed.needsAccount { return areas(of: .njTransitBus) }
        let found = areas(ofOperator: busOperatorID(feed.code))
        return found.isEmpty ? [.newYork] : found
    }

    /// A bus company's id in areas.json
    public static func busOperatorID(_ code: String) -> String { "bus:" + code }

    /// The kinds of vehicles an operator runs in a metro area, from areas.json: an operator can run several kinds, and not the
    /// same ones in every area (NJ Transit's express buses are the ones to and from New York). The line under the sidebar title is
    /// made from it
    public static func kinds(ofOperator id: String, in area: MetroArea) -> [VehicleKind] {
        AreaCatalog.shared.operator(id)?.kinds[area.rawValue] ?? []
    }

    public static func kinds(of source: FerryFeed.Source, in area: MetroArea) -> [VehicleKind] { kinds(ofOperator: source.rawValue, in: area) }
}

/// A kind of vehicle, by the name riders know it by. The line under the sidebar title says which kinds a transit mode has in the
/// start place's metro area, in this order; which kinds an operator runs is said with the operator (MetroArea.kinds(of:in:),
/// ModeCoverage), so the line follows the data when an operator or a metro area is added
public enum VehicleKind: String, CaseIterable, Sendable {
    case subway, trolley, lightRail, tram, localBus, expressBus, commuterRail, intercityRail, passengerFerry, carFerry

    /// English name (UI translation key)
    public var nameKey: String {
        switch self {
        case .subway: return "Subway"
        case .trolley: return "Trolley"
        case .lightRail: return "Light Rail"
        case .tram: return "Tram"
        case .localBus: return "Local Bus"
        case .expressBus: return "Express Bus"
        case .commuterRail: return "Commuter Rail"
        case .intercityRail: return "Intercity Rail"
        case .passengerFerry: return "Passenger Ferry"
        case .carFerry: return "Car Ferry"
        }
    }
}

// MARK: - Metro areas in use

/// When each metro area was last used: the starting point was in it, or a Plan a Trip place. Settings' area menu puts the ones used
/// most recently first (MetroArea.menuOrder). Saved in the app's settings as area id → seconds since 1970; a day is precise enough,
/// so a date is written again only an hour after the last one (the main window refreshes every half minute)
public enum AreaUsage {
    /// The settings key
    public static let key = "areas.lastUsed"
    /// Shortest time between two writes of one area's date
    public static let rewriteAfter: TimeInterval = 60 * 60

    /// The dates as saved, read leniently: ids of areas that no longer exist and values of another type are left out
    public static func dates(from saved: Any?) -> [MetroArea: Date] {
        guard let saved = saved as? [String: Any] else { return [:] }
        var out: [MetroArea: Date] = [:]
        for (id, value) in saved {
            guard let area = MetroArea(rawValue: id), let seconds = (value as? Double) ?? (value as? Int).map(Double.init) else { continue }
            out[area] = Date(timeIntervalSince1970: seconds)
        }
        return out
    }

    /// What to save after `area` was used at `now`: the saved dates with this one changed. Nil when nothing needs writing (written
    /// less than rewriteAfter ago)
    public static func noting(_ area: MetroArea, at now: Date, in saved: Any?) -> [String: Double]? {
        let dates = dates(from: saved)
        if let last = dates[area], abs(now.timeIntervalSince(last)) < rewriteAfter { return nil }
        var out = Dictionary(uniqueKeysWithValues: dates.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
        out[area.rawValue] = now.timeIntervalSince1970
        return out
    }

    /// The dates saved in `defaults` (the app's own settings, kept only on this Mac)
    public static func dates(in defaults: UserDefaults = .standard) -> [MetroArea: Date] { dates(from: defaults.object(forKey: key)) }

    /// Saves these dates in `defaults` as they are (AreaData.startingDates)
    public static func save(_ dates: [MetroArea: Date], in defaults: UserDefaults = .standard) {
        defaults.set(Dictionary(uniqueKeysWithValues: dates.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }), forKey: key)
    }

    /// Saves in `defaults` that `area` was used at `now` (nil: a place outside every area, nothing to save)
    public static func note(_ area: MetroArea?, in defaults: UserDefaults = .standard, now: Date = Date()) {
        guard let area, let new = noting(area, at: now, in: defaults.object(forKey: key)) else { return }
        defaults.set(new, forKey: key)
    }
}

extension MetroArea {
    /// The order of Settings' area menu, which lists every area: the starting point's area first, then the others used before, the
    /// most recently used first, then those never used, by `name` (the names in the app's language)
    public static func menuOrder(start: MetroArea?, lastUsed: [MetroArea: Date], name: (MetroArea) -> String) -> [MetroArea] {
        let others = allCases.filter { $0 != start }
        func index(_ a: MetroArea) -> Int { allCases.firstIndex(of: a) ?? 0 }
        let used = others.filter { lastUsed[$0] != nil }.sorted { a, b in
            let da = lastUsed[a]!, db = lastUsed[b]!
            return da != db ? da > db : index(a) < index(b)
        }
        let unused = others.filter { lastUsed[$0] == nil }.sorted { a, b in
            let order = name(a).localizedCaseInsensitiveCompare(name(b))
            return order != .orderedSame ? order == .orderedAscending : index(a) < index(b)
        }
        return (start.map { [$0] } ?? []) + used + unused
    }
}

// MARK: - Lists of many areas

/// Settings lists the metro areas in two places: Downloaded data and Data source's area menu. With more areas than shownAtOnce,
/// each shows only the ones that matter to this user and leaves the others to a full list with a search field, so neither grows
/// with the number of areas. The rules are here, for any number of areas (`ID` is an area, or anything else in a test)
public enum AreaList {
    /// How many areas a place that lists them shows before the others go to the full list
    public static let shownAtOnce = 5

    /// An area in Downloaded data: why its data is on this Mac, and what its own operators' data takes (nil: none, or removed
    /// by the user)
    public struct Stored<ID: Hashable>: Equatable {
        public var id: ID
        public var reason: AreaData.Reason?
        public var size: Int64?
        public init(id: ID, reason: AreaData.Reason?, size: Int64?) {
            self.id = id
            self.reason = reason
            self.size = size
        }
    }

    /// Downloaded data's full list: the starting point's area, Plan a Trip's, then the others with the most data first (with
    /// as much: as they came), the ones the user removed last. So the areas taking the most room are at the top
    public static func bySize<ID>(_ areas: [Stored<ID>]) -> [Stored<ID>] {
        func rank(_ reason: AreaData.Reason?) -> Int {
            switch reason {
            case .start?: return 0
            case .planner?: return 1
            case .removedByYou?: return 3
            default: return 2
            }
        }
        return areas.enumerated().sorted { a, b in
            let ra = rank(a.element.reason), rb = rank(b.element.reason)
            if ra != rb { return ra < rb }
            let sa = a.element.size ?? 0, sb = b.element.size ?? 0
            if ra == 2, sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Downloaded data's rows. Up to `limit` areas: all of them, as they came. More: the first `limit` of the full list (bySize)
    /// that the user didn't remove, and the others, which share one row and are listed in the full list
    public static func folded<ID>(_ areas: [Stored<ID>], limit: Int = shownAtOnce) -> (listed: [Stored<ID>], others: [Stored<ID>]) {
        guard areas.count > limit else { return (areas, []) }
        var listed: [Stored<ID>] = [], others: [Stored<ID>] = []
        for area in bySize(areas) {
            if listed.count < limit, area.reason != .removedByYou { listed.append(area) } else { others.append(area) }
        }
        return (listed, others)
    }

    /// The area menu's items. Up to `limit` areas: all of them, in `order` (MetroArea.menuOrder: the starting point's first,
    /// then by when they were last used). More: the first `limit` of them in use (the starting point's, Plan a Trip's, the
    /// favorites' and those used in the last AreaData.keepDays days), the one shown taking the last place when it isn't one of
    /// those, so there are never more than `limit`. `all`: whether areas were left out, so the menu ends with an item that
    /// opens the full list
    public static func menu<ID: Hashable>(order: [ID], inUse: Set<ID>, shown: ID?, limit: Int = shownAtOnce) -> (listed: [ID], all: Bool) {
        guard order.count > limit else { return (order, false) }
        var listed = Array(order.filter(inUse.contains).prefix(limit))
        if let shown, order.contains(shown), !listed.contains(shown) {
            if listed.count >= max(limit, 1) { listed.removeLast() }
            listed.append(shown)
        }
        return (listed, listed.count < order.count)
    }

    /// The full list where an area is chosen: by name, as `locale`'s language orders them (without case or accents, a number
    /// by its value); areas with one name as they came
    public static func byName<ID>(_ areas: [ID], locale: Locale?, name: (ID) -> String) -> [ID] {
        areas.enumerated().map { (offset: $0.offset, area: $0.element, name: name($0.element)) }.sorted { a, b in
            let order = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: locale)
            return order != .orderedSame ? order == .orderedAscending : a.offset < b.offset
        }.map(\.area)
    }

    /// What a search compares: without case, accents or width, one space between words and none at the ends
    public static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether a search finds what has these names: its text is part of one of them (see searchKey). An empty search finds
    /// everything
    public static func matches(_ search: String, names: [String]) -> Bool {
        let key = searchKey(search)
        return key.isEmpty || names.contains { searchKey($0).contains(key) }
    }
}
