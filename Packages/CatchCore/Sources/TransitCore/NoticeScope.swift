import Foundation

// MARK: - Which modes and stations a notice is about

/// A notice recorded per data provider name (rate limits, can't-connect and data problems)
public protocol ProviderNotice {
    /// The provider's name; NoticeScope.naming narrows a name shared by several bus companies to the ones that concern what's shown
    var provider: String { get set }
    /// About the monthly downloaded data (see NetworkReach.Notice.lasting)
    var isLasting: Bool { get }
}

extension RateLimit.Notice: ProviderNotice {
    /// Rate limits only come from live data servers
    public var isLasting: Bool { false }
}

extension NetworkReach.Notice: ProviderNotice {
    public var isLasting: Bool { lasting == true }
}

/// Rate limits and connection notices are recorded per provider name: the name RateLimit.provider(forHost:) gives a host,
/// or the operator name a timetable download passes in (FerryFeed.Source.name, RegionalBusFeed.name, "MTA").
/// This maps a name back to the stations it serves, so a notice shows only in the mode, and at the stations, it affects:
/// an NJ Transit bus rate limit isn't shown in Ferry mode, and NJ Transit rail's (one account for trains and light rail)
/// shows in Train mode and at light rail stops in Subway mode, not at subway stations.
public enum NoticeScope {
    /// One group of stations a provider serves
    public enum Part: Hashable, Sendable {
        /// MTA subway and Staten Island Railway stations (the built-in station catalog)
        case subway
        /// MTA bus stops
        case mtaBus
        /// Roosevelt Island Tram
        case tram
        /// One timetable operator's stations or piers (IDs like "nyf:…")
        case source(FerryFeed.Source)
        /// One timetable bus company's stops (its RegionalBusFeed code; NJ Transit's is empty)
        case bus(String)

        /// The mode these stations show in
        public var mode: TransitSystem {
            switch self {
            case .subway, .tram: return .subway
            case .mtaBus, .bus: return .bus
            case .source(let s): return s.system.mode
            }
        }
    }

    /// What this provider serves; nil for a name it doesn't know (offline has no name), whose notice shows everywhere rather than nowhere.
    /// - Parameter lasting: about the monthly downloaded data. "MTA" names both kinds: its monthly data is the subway GTFS
    ///   (the bus GTFS, only for the bus map and stop list, isn't recorded: see SubwayMapStore.downloadBus),
    ///   its live data the subway and the LIRR and Metro-North feeds (their monthly timetables go by the railroads' own names).
    public static func parts(provider: String, lasting: Bool) -> Set<Part>? {
        switch provider {
        case "MTA": return lasting ? [.subway] : [.subway, .source(.lirr), .source(.metroNorth)]
        case "MTA Bus Time": return [.mtaBus]
        case "NJ Transit rail": return [.source(.njTransitRail), .source(.njTransitLightRail)]
        case "NJ Transit bus": return [.bus(RegionalBusFeed.njTransit.code)]
        // Live data: one server for SEPTA's trains, Metro and buses. A timetable: its bus timetable, the only download recorded
        // under that name (its trains and Metro go by their own names)
        case "SEPTA":
            let bus = NoticeScope.Part.bus(RegionalBusFeed.septaCode)
            return lasting ? [bus] : [.source(.septaRail), .source(.septaMetro), bus]
        // Live data: one file for the MBTA's subway, trains, buses and ferries. A timetable: its bus timetable, the only download
        // recorded under that name (the others go by their own names)
        case "MBTA":
            let bus = NoticeScope.Part.bus(RegionalBusFeed.mbtaCode)
            return lasting ? [bus] : [.source(.mbtaSubway), .source(.mbtaRail), .source(.mbtaFerry), bus]
        case ModeCoverage.tram: return [.tram]
        default: break
        }
        // Live data: one server for several bus operators (Passio's), named after all of them, or after some (see naming)
        if let feeds = busCompanies(named: provider) { return Set(feeds.map { .bus($0.code) }) }
        if let source = FerryFeed.Source.allCases.first(where: { $0.name == provider }) {
            return [source == .njTransitBus ? .bus(RegionalBusFeed.njTransit.code) : .source(source)]
        }
        // Also "NJ Transit": the only download recorded under that name is its bus timetable
        if let feed = RegionalBusFeed.all.first(where: { $0.name == provider }) { return [.bus(feed.code)] }
        return nil
    }

    /// Which group a station (stop, pier) belongs to; IDs without an operator prefix are MTA stations, bus stops in Bus mode
    public static func part(ofStation id: String, mode: TransitSystem) -> Part {
        if RooseveltIslandTram.isTramStation(id) { return .tram }
        if FerryFeed.Source.njTransitBus.owns(id: id) { return .bus(RegionalBusFeed.of(id: id)?.code ?? RegionalBusFeed.njTransit.code) }
        if let source = FerryFeed.Source.allCases.first(where: { $0.owns(id: id) }) { return .source(source) }
        return mode.mode == .bus ? .mtaBus : .subway
    }

    /// Whether this notice belongs in this mode (with stationIDs: at a station with these members, e.g. a station complex or a stop group)
    public static func applies(_ notice: some ProviderNotice, mode: TransitSystem, stationIDs: [String]? = nil) -> Bool {
        guard let parts = parts(provider: notice.provider, lasting: notice.isLasting) else { return true }
        guard let stationIDs else { return parts.contains { $0.mode == mode.mode } }
        return stationIDs.contains { parts.contains(part(ofStation: $0, mode: mode)) }
    }

    /// The notices that belong in this mode (with stationIDs: at that station, named as naming(_:stationIDs:) names them there)
    public static func filter<N: ProviderNotice>(_ notices: [N], mode: TransitSystem, stationIDs: [String]? = nil) -> [N] {
        let kept = notices.filter { applies($0, mode: mode, stationIDs: stationIDs) }
        return stationIDs == nil ? kept : naming(kept, stationIDs: stationIDs)
    }

    /// The bus companies a name joining several with " / " stands for (Passio's server, RegionalBusFeed.passioProvider, or some of
    /// them); nil for any other name
    static func busCompanies(named provider: String) -> [RegionalBusFeed]? {
        let names = provider.components(separatedBy: " / ")
        guard names.count > 1 else { return nil }
        let feeds = names.compactMap { name in RegionalBusFeed.builtIn.first { $0.name == name } }
        return feeds.count == names.count ? feeds : nil
    }

    /// A notice about a server several bus companies share names only the ones that concern what's shown: at a station (stationIDs),
    /// those stopping there; elsewhere, those whose data is downloaded now (RegionalBusFeed.isWanted). With none of them, or all,
    /// the name stays. Only for showing: the notices kept for later stay under the server's own name, so every station it serves
    /// still finds its notice
    public static func naming<N: ProviderNotice>(_ notices: [N], stationIDs: [String]? = nil) -> [N] {
        notices.map { notice in
            guard let feeds = busCompanies(named: notice.provider) else { return notice }
            let shown: [RegionalBusFeed]
            if let stationIDs {
                let codes = Set(stationIDs.compactMap { RegionalBusFeed.of(id: $0)?.code })
                shown = feeds.filter { codes.contains($0.code) }
            } else {
                shown = feeds.filter(\.isWanted)
            }
            guard !shown.isEmpty, shown.count < feeds.count else { return notice }
            var named = notice
            named.provider = shown.map(\.name).joined(separator: " / ")
            return named
        }
    }
}
