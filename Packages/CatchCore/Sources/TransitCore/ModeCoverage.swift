import Foundation

/// Which operators each mode includes, one metro area at a time: the line under the sidebar title (the kinds of vehicles the mode
/// has in the start place's metro area), the title bar button tooltips (the same line) and the sidebar header's popover (that area's
/// operators, and whether each is live) are generated from here.
///
/// To keep these in sync when data sources are added or removed, this uses the source lists the app actually downloads where possible
/// (FerryFeed.Source, RegionalBusFeed.all); only the bundled ones (subway, Staten Island Railway, tram) are written here. Where an
/// operator runs and which kinds of vehicles it runs there is said once per operator (MetroArea.areas(of:), MetroArea.kinds(of:in:)).
/// ModeCoverageTests checks: every source is in its areas' lists, none of them names a source that no longer exists, and How It Works' own sentences name operators that run there.
public enum ModeCoverage {
    /// One row of the sidebar header's popover: an operator, or a few that go together; may have a group name before them ("MTA")
    public struct Operator: Equatable, Sendable {
        public var group: String?
        public var names: [String]
        /// The kinds of vehicles it runs in the area asked for. None for a row that isn't about departures (the stations without
        /// times, the note on what isn't included)
        public var kinds: [VehicleKind]
        /// Where its times come from now: live data (true) or the timetable (false). Nil for a row without times
        public var live: Bool?
        public init(group: String? = nil, names: [String], kinds: [VehicleKind] = [], live: Bool? = nil) {
            self.group = group
            self.names = names
            self.kinds = kinds
            self.live = live
        }
    }

    /// What decides who is live now besides the free live data: the user's own keys and account, and the bus companies whose live
    /// data isn't downloading
    public struct LiveAccess: Equatable, Sendable {
        public var mtaBusKey: Bool
        public var njTransitAccount: Bool
        public var suffolkKey: Bool
        /// RegionalBusFeed codes
        public var failedBuses: Set<String>
        public init(mtaBusKey: Bool = false, njTransitAccount: Bool = false, suffolkKey: Bool = false, failedBuses: Set<String> = []) {
            self.mtaBusKey = mtaBusKey
            self.njTransitAccount = njTransitAccount
            self.suffolkKey = suffolkKey
            self.failedBuses = failedBuses
        }
    }

    /// Bundled, not downloaded from a source list
    public static let subwayLines = ["NYC Subway"]
    public static let statenIslandRailway = "Staten Island Railway"
    public static let tram = "Roosevelt Island Tram"
    /// The areas.json ids of the ones that ship inside the app, and of Shore Line East
    public static let subwayID = "subway", statenIslandRailwayID = "sir", tramID = "tram", mtaBusID = "mtaBus", shoreLineEastID = "sle"
    /// NJ Transit's three light rail lines (same source, njTransitLightRail)
    public static let lightRailLines = ["Hudson-Bergen Light Rail", "Newark Light Rail", "River LINE"]
    /// The metro areas a light rail line has stops in (areas.json; the River LINE runs from Trenton, in New York's area, to Camden)
    public static func areas(ofLightRail line: String) -> [MetroArea] {
        let ids = AreaCatalog.shared.operator(FerryFeed.Source.njTransitLightRail.rawValue)?.lines[line] ?? []
        return MetroArea.allCases.filter { ids.contains($0.rawValue) }
    }
    /// CTrail's Shore Line East: a line of its own, though its timetable comes in Amtrak's package (see FerryFeed.shoreLineEast)
    public static let shoreLineEast = "CTrail " + FerryFeed.shoreLineEast.name
    /// The areas.json operators whose data comes in another operator's package: turned off with it
    static let comesWith: [String: FerryFeed.Source] = [shoreLineEastID: .amtrakNY]

    /// Whether Shore Line East gets a row of its own under the train sources of this area (Settings → Data source), as it does
    /// in the lists of operators (How It Works, the sidebar's popover). Nil: every area
    public static func listsShoreLineEast(in area: MetroArea?) -> Bool {
        !isTurnedOff(shoreLineEastID) && (area.map { MetroArea.areas(ofOperator: shoreLineEastID).contains($0) } ?? true)
    }

    /// Whether the source list in use turned an operator off (SourceList), by its areas.json id: one downloaded on its own, a bus
    /// company, or one that comes in a package turned off (comesWith). What ships inside the app can't be turned off
    static func isTurnedOff(_ id: String) -> Bool {
        if let package = comesWith[id] { return package.isTurnedOff }
        let busPrefix = MetroArea.busOperatorID("")
        if id.hasPrefix(busPrefix) {
            let code = String(id.dropFirst(busPrefix.count))
            return RegionalBusFeed.builtIn.first { $0.code == code }.map { SourceList.isTurnedOff($0.listID) } ?? false
        }
        return SourceList.isTurnedOff(id)
    }
    /// The four MTA bus types (labels in the UI)
    public static let mtaBusKinds = ["Local", "Limited", "Select Bus Service", "Express"]
    /// The group of the line naming the operators whose stations are listed without times (NoTimesStations)
    public static let withoutTimesGroup = "Without times"
    /// The last line of the bus list: the private commuter buses aren't in the app at all (no stops are listed)
    public static let privateCommuterBuses = "Not included: private commuter buses whose times aren't published in a form Catch My Train can use."

    /// Sources for this mode (excluding NJ Transit buses, which are listed separately by region, and any the source list turned off)
    public static func sources(for mode: TransitSystem) -> [FerryFeed.Source] {
        FerryFeed.Source.allCases.filter { $0 != .njTransitBus && $0.system.mode == mode.mode && !$0.isTurnedOff }
    }

    /// Local buses (excluding NJ Transit), in RegionalBusFeed.all order
    public static var localBuses: [RegionalBusFeed] { RegionalBusFeed.all.filter { !$0.code.isEmpty } }

    /// The rows of the sidebar header's popover: this mode's operators with stops in a metro area (nil: in any area), then the
    /// operators whose stations there are listed without times, as one row ("Without times: …"), and for buses the note on what
    /// isn't included. An operator in two areas is in both lists, as in Settings
    public static func operators(for mode: TransitSystem, in area: MetroArea?, access: LiveAccess = LiveAccess()) -> [Operator] {
        var out = running(for: mode, in: area, access: access)
        let stations = NoTimesStations.stations(for: mode)
        let withoutTimes = NoTimesStations.agencies(for: mode).filter { agency in
            stations.contains { $0.agency == agency && (area == nil || MetroArea.of($0.coordinate) == area) }
        }
        if !withoutTimes.isEmpty { out.append(Operator(group: withoutTimesGroup, names: withoutTimes.map(\.name))) }
        if mode.mode == .bus { out.append(Operator(names: [privateCommuterBuses])) }
        return out
    }

    /// The kinds of vehicles this mode has in a metro area, in VehicleKind's order: the line under the sidebar title. Nil: all the
    /// areas together (a start place outside them all). Empty when the mode has nothing in the area
    public static func kinds(for mode: TransitSystem, in area: MetroArea?) -> [VehicleKind] {
        let found = Set(running(for: mode, in: area, access: LiveAccess()).flatMap(\.kinds))
        return VehicleKind.allCases.filter { found.contains($0) }
    }

    /// The operators of this mode with departures in a metro area (nil: in any), one row each; the local bus companies share two
    /// rows, the ones live now and the rest, so the list stays short however many there are. Ordered by kind of vehicle as in
    /// VehicleKind, and within a kind as the source lists have them
    static func running(for mode: TransitSystem, in area: MetroArea?, access: LiveAccess) -> [Operator] {
        let areas = area.map { [$0] } ?? MetroArea.allCases
        func here(_ its: [MetroArea]) -> Bool { its.contains { areas.contains($0) } }
        func kindsHere(_ source: FerryFeed.Source) -> [VehicleKind] {
            let found = Set(MetroArea.areas(of: source).filter { areas.contains($0) }.flatMap { MetroArea.kinds(of: source, in: $0) })
            return VehicleKind.allCases.filter { found.contains($0) }
        }
        // With the account, only an operator whose times it makes live (FerryFeed.Source.liveWithAccount: NJ Transit's trains)
        func sourceLive(_ source: FerryFeed.Source) -> Bool { source.hasRealtime || (source.liveWithAccount && access.njTransitAccount) }
        func busLive(_ feed: RegionalBusFeed) -> Bool {
            feed.canGetRealtime(hasAccount: access.njTransitAccount, hasSuffolkKey: access.suffolkKey) && !access.failedBuses.contains(feed.code)
        }
        func at(_ id: String) -> Bool { !isTurnedOff(id) && here(MetroArea.areas(ofOperator: id)) }
        func kindsOf(_ id: String) -> [VehicleKind] {
            let found = Set(areas.flatMap { MetroArea.kinds(ofOperator: id, in: $0) })
            return VehicleKind.allCases.filter { found.contains($0) }
        }
        var out: [Operator] = []
        switch mode.mode {
        case .subway:
            if at(subwayID) { out.append(Operator(names: subwayLines, kinds: kindsOf(subwayID), live: true)) }
            if at(statenIslandRailwayID) { out.append(Operator(names: [statenIslandRailway], kinds: kindsOf(statenIslandRailwayID), live: true)) }
            for source in sources(for: .subway) where here(MetroArea.areas(of: source)) {
                // The light rail lines by name, each in the areas it stops in
                let names = source == .njTransitLightRail ? lightRailLines.filter { here(ModeCoverage.areas(ofLightRail: $0)) } : [source.name]
                if !names.isEmpty { out.append(Operator(names: names, kinds: kindsHere(source), live: sourceLive(source))) }
            }
            // The tram's times are worked out from its hours and intervals
            if at(tramID) { out.append(Operator(names: [tram], kinds: kindsOf(tramID), live: false)) }
        case .bus:
            // MTA's buses have live times only, with the user's own key: no tag without one
            if at(mtaBusID) {
                out.append(Operator(group: "MTA", names: mtaBusKinds, kinds: kindsOf(mtaBusID), live: access.mtaBusKey ? true : nil))
            }
            let njTransit = RegionalBusFeed.njTransit
            if !FerryFeed.Source.njTransitBus.isTurnedOff, here(MetroArea.areas(ofBus: njTransit)) {
                out.append(Operator(names: [njTransit.name], kinds: kindsHere(.njTransitBus), live: busLive(njTransit)))
            }
            let local = localBuses.filter { here(MetroArea.areas(ofBus: $0)) }
            for live in [true, false] {
                let names = local.filter { busLive($0) == live }.map(\.name)
                if !names.isEmpty { out.append(Operator(names: names, kinds: [.localBus], live: live)) }
            }
        default:
            for source in sources(for: mode) where here(MetroArea.areas(of: source)) {
                out.append(Operator(names: [source.name], kinds: kindsHere(source), live: sourceLive(source)))
            }
            if mode.mode == .train, at(shoreLineEastID) { out.append(Operator(names: [shoreLineEast], kinds: kindsOf(shoreLineEastID), live: false)) }
        }
        func rank(_ row: Operator) -> Int { row.kinds.compactMap { VehicleKind.allCases.firstIndex(of: $0) }.min() ?? Int.max }
        return out.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Where an operator's times come from now, for the footer's live data line: its names are grouped by this, in this order
    public enum LiveState: Int, CaseIterable, Sendable {
        case live
        /// It has live data, with a key or account the user hasn't added (or that was refused)
        case needsKey
        /// It has live data, but it isn't downloading now: its times come from the timetable
        case notNow
        case timetable
        /// Worked out from its hours and how often it runs (the tram)
        case estimated
    }

    public struct LiveName: Equatable, Sendable {
        public var name: String
        public var state: LiveState
        /// The RegionalBusFeed code of a bus company whose live data isn't downloading (NJ Transit's is "")
        public var busCode: String?
    }

    /// This mode's operators in a metro area (nil: in all of them), each with where its times come from now: the footer's live data
    /// line is made from it, so it names only the start place's area and follows areas.json. MTA's buses are one name, "MTA"
    public static func liveNames(for mode: TransitSystem, in area: MetroArea?, access: LiveAccess = LiveAccess()) -> [LiveName] {
        running(for: mode, in: area, access: access).flatMap { row -> [LiveName] in
            // MTA's buses have live times only, with the user's own key
            if let group = row.group { return [LiveName(name: group, state: row.live == true ? .live : .needsKey)] }
            return row.names.map { name in
                if name == tram { return LiveName(name: name, state: .estimated) }
                if row.live == true { return LiveName(name: name, state: .live) }
                if mode.mode == .bus, let feed = ([RegionalBusFeed.njTransit] + localBuses).first(where: { $0.name == name }) {
                    if feed.canGetRealtime(hasAccount: access.njTransitAccount, hasSuffolkKey: access.suffolkKey) {
                        return LiveName(name: name, state: .notNow, busCode: feed.code)
                    }
                    return LiveName(name: name, state: feed.canBeLive ? .needsKey : .timetable)
                }
                // A key or account is asked for only where it would give live times (liveWithAccount): NJ Transit's light rail and
                // buses are timetable operators with or without the account
                let source = lightRailLines.contains(name) ? .njTransitLightRail : sources(for: mode).first { $0.name == name }
                return LiveName(name: name, state: source?.liveWithAccount == true ? .needsKey : .timetable)
            }
        }
    }

    /// Who this mode's data in a metro area (nil: in all of them) is credited to, each once (the station footer's "Data: …" line and
    /// the map window's source line): areas.json's "credit", in its order; the bus companies under their own names, in the source list's
    public static func credits(for mode: TransitSystem, in area: MetroArea?) -> [String] {
        let areas = area.map { [$0] } ?? MetroArea.allCases
        var out: [String] = []
        for op in AreaCatalog.shared.operators where !op.id.hasPrefix(MetroArea.busOperatorID("")) {
            guard self.mode(ofOperator: op.id) == mode.mode, areas.contains(where: { op.kinds[$0.rawValue] != nil }),
                  !isTurnedOff(op.id) else { continue }
            let credit = op.credit ?? op.id
            if !out.contains(credit) { out.append(credit) }
        }
        if mode.mode == .bus {
            // Under areas.json's credit when it has one (the MBTA's, with MassDOT, as its terms ask)
            for feed in localBuses where MetroArea.areas(ofBus: feed).contains(where: areas.contains) {
                let credit = AreaCatalog.shared.operator(MetroArea.busOperatorID(feed.code))?.credit ?? feed.name
                if !out.contains(credit) { out.append(credit) }
            }
        }
        return out
    }

    // MARK: Who runs the vehicles at a station

    /// The areas.json ids of the operators whose vehicles stop at these stations, with the routes there (one station of the board:
    /// a complex or a stop group, all its members). Where each station's data comes from says it: a downloaded operator's stations
    /// by their ID (FerryFeed.Source.owns(id:)), the bus companies' stops and routes by their company (RegionalBusFeed), a station
    /// without times by its agency ("notimes:" and its key), the rest are the ones that come with the app (NYC Subway, Staten Island
    /// Railway, MTA's buses, the tram). Shore Line East by its route, as it comes in Amtrak's package. Each once, in the order found
    public static func operatorIDs(atStations ids: [String], routes: [String], mode: TransitSystem) -> [String] {
        var out: [String] = []
        func add(_ id: String) { if !out.contains(id) { out.append(id) } }
        func addBus(_ feed: RegionalBusFeed) {
            add(feed.code.isEmpty ? FerryFeed.Source.njTransitBus.rawValue : MetroArea.busOperatorID(feed.code))
        }
        for id in ids {
            if RooseveltIslandTram.isTramStation(id) {
                add(tramID)
            } else if NoTimesStations.isNoTimes(id) {
                if let agency = NoTimesStations.station(id: id)?.agency { add(NoTimesStations.idPrefix + agency.key) }
            } else if FerryFeed.Source.njTransitBus.owns(id: id) {
                addBus(RegionalBusFeed.of(id: id) ?? .njTransit)
            } else if let source = FerryFeed.Source.allCases.first(where: { $0.owns(id: id) }) {
                let own = routes.filter { source.owns(route: $0) }
                if source.isAmtrak, own.contains(where: FerryFeed.isShoreLineEast) {
                    if own.contains(where: { !FerryFeed.isShoreLineEast($0) }) { add(source.rawValue) }
                    add(shoreLineEastID)
                } else {
                    add(source.rawValue)
                }
            } else if mode.mode == .bus {
                add(mtaBusID)
            } else if mode.mode == .subway {
                // Staten Island Railway's stations are in the MTA's subway data, with its own route
                let sir = routes.contains(statenIslandRailwayRoute)
                if !sir || routes.contains(where: { $0 != statenIslandRailwayRoute && !FerryFeed.isFeedRoute($0) }) { add(subwayID) }
                if sir { add(statenIslandRailwayID) }
            }
        }
        // A stop can be served by another company's buses: their routes say so
        for route in routes where FerryFeed.Source.njTransitBus.owns(route: route) {
            addBus(RegionalBusFeed.of(route: route) ?? .njTransit)
        }
        return out
    }

    /// The same for Plan a Trip's results: each departure's station with its route
    public static func operatorIDs(of arrivals: [Arrival], mode: TransitSystem) -> [String] {
        var routes: [String: [String]] = [:]
        var order: [String] = []
        for a in arrivals {
            if routes[a.stationID] == nil { order.append(a.stationID) }
            if !(routes[a.stationID]?.contains(a.route) ?? false) { routes[a.stationID, default: []].append(a.route) }
        }
        var out: [String] = []
        for id in order {
            for op in operatorIDs(atStations: [id], routes: routes[id] ?? [], mode: mode) where !out.contains(op) { out.append(op) }
        }
        return out
    }

    /// Staten Island Railway's route in the MTA's subway data
    static let statenIslandRailwayRoute = "SI"

    /// The live data line for these operators only (operatorIDs): the footer's for the selected station, Plan a Trip's for its
    /// results. A light rail station names its own line, by its routes
    public static func liveNames(for mode: TransitSystem, operators ids: [String], routes: [String],
                                 access: LiveAccess = LiveAccess()) -> [LiveName] {
        let wanted = Set(ids.flatMap { names(ofOperator: $0, routes: routes) })
        return liveNames(for: mode, in: nil, access: access).filter { wanted.contains($0.name) }
    }

    /// Who the data of these operators only (operatorIDs) is credited to, each once: the footer's "Data: …" line for the selected
    /// station. The stations without times have no credit of their own
    public static func credits(for mode: TransitSystem, operators ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids {
            guard self.mode(ofOperator: id) == mode.mode, let op = AreaCatalog.shared.operator(id), !isTurnedOff(id) else { continue }
            let credit = op.credit ?? names(ofOperator: id, routes: []).first ?? id
            if !out.contains(credit) { out.append(credit) }
        }
        return out
    }

    /// The few words naming an operator where its live times are shown (LiveSource): areas.json's "short", else its "credit",
    /// else its own name (a bus company). Nil for an id areas.json doesn't know
    public static func liveName(ofOperator id: String) -> String? {
        let op = AreaCatalog.shared.operator(id)
        return op?.short ?? op?.credit ?? names(ofOperator: id, routes: []).first
    }

    /// An operator's names in the sidebar header's popover and the live data line (MTA's buses: "MTA"); a light rail station's
    /// own line by its routes, all three without them
    static func names(ofOperator id: String, routes: [String]) -> [String] {
        switch id {
        case subwayID: return subwayLines
        case statenIslandRailwayID: return [statenIslandRailway]
        case tramID: return [tram]
        case mtaBusID: return ["MTA"]
        case shoreLineEastID: return [shoreLineEast]
        default: break
        }
        let busPrefix = MetroArea.busOperatorID("")
        if id.hasPrefix(busPrefix) { return RegionalBusFeed.feed(code: String(id.dropFirst(busPrefix.count))).map { [$0.name] } ?? [] }
        if NoTimesStations.isNoTimes(id) {
            let key = String(id.dropFirst(NoTimesStations.idPrefix.count))
            return NoTimesStations.agencies.first { $0.key == key }.map { [$0.name] } ?? []
        }
        guard let source = FerryFeed.Source(rawValue: id) else { return [] }
        switch source {
        case .njTransitBus:
            return [RegionalBusFeed.njTransit.name]
        case .njTransitLightRail:
            let codes = Set(routes.filter { source.owns(route: $0) }.map(FerryFeed.badge))
            let lines = (FerryFeed.railLines[source] ?? []).filter { codes.contains($0.code) }.map(\.name)
            return lines.isEmpty ? lightRailLines : lines
        default:
            return [source.name]
        }
    }

    /// The mode of an operator in areas.json
    static func mode(ofOperator id: String) -> TransitSystem? {
        if let source = FerryFeed.Source(rawValue: id) { return source.system.mode }
        switch id {
        case subwayID, statenIslandRailwayID, tramID: return .subway
        case mtaBusID: return .bus
        case shoreLineEastID: return .train
        default: return id.hasPrefix(MetroArea.busOperatorID("")) ? .bus : nil
        }
    }

    /// How many operators a mode has in all, each counted once (the README's data table counts them): the bundled ones, the
    /// downloaded ones (the light rail lines are one operator's), MTA and NJ Transit with the local buses, Shore Line East with the trains
    public static func operatorCount(for mode: TransitSystem) -> Int {
        switch mode.mode {
        case .subway: return subwayLines.count + 2 + sources(for: .subway).count
        case .bus: return 2 + localBuses.count
        case .train: return sources(for: mode).count + 1
        default: return sources(for: mode).count
        }
    }

    /// The boats around Greater Boston and to the islands, all timetable only: their pier names are tidied the same way
    /// (FerryBuilder.pierName)
    public static let ferriesListedTogether: [FerryFeed.Source] = [.hyLine, .bayState, .blockIsland, .cuttyhunk, .patriot, .freedom,
                                                                   .vineyardFastFerry, .harborIslands, .cathleenStone]

    // MARK: How It Works and About

    /// The operators How It Works has a sentence of their own for, under their mode's generated lines (liveNames), for what they do
    /// differently from the rest: where their data comes from, how far ahead it goes, which part of them is in the area. In the
    /// order shown. Each is shown only in the metro areas it runs in, so a new area changes no sentence; every other operator is
    /// named only in the generated lines
    public static let ownSentence: [String] = [subwayID, FerryFeed.Source.path.rawValue, tramID, mtaBusID, MetroArea.busOperatorID("SCT"),
                                               FerryFeed.Source.marc.rawValue, FerryFeed.Source.capeMayLewes.rawValue,
                                               FerryFeed.Source.statueOfLiberty.rawValue]

    /// The operators of this mode in a metro area that have a sentence of their own in How It Works (ownSentence), in its order;
    /// none that the source list turned off
    public static func ownSentences(for mode: TransitSystem, in area: MetroArea) -> [String] {
        ownSentence.filter { id in
            self.mode(ofOperator: id) == mode.mode && MetroArea.areas(ofOperator: id).contains(area) && !isTurnedOff(id)
        }
    }

    /// Who the downloaded data in a metro area is credited to, each once, for About and How It Works' license section: the station
    /// footer's credits (credits(for:in:)) of the subway, bus, train and ferry in turn. Every area's are in Settings' data source
    public static func credits(in area: MetroArea) -> [String] {
        var out: [String] = []
        for mode in TransitSystem.modes {
            for credit in credits(for: mode, in: area) where !out.contains(credit) { out.append(credit) }
        }
        return out
    }
}
