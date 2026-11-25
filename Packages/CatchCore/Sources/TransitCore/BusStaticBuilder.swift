import Foundation

// MARK: - Regenerating the bus stop catalog from bus GTFS
//
// Same method as tools/generate_bus.py uses for bus_stops.json; the output is byte-for-byte identical to the script's
// (the bus map half is BusMapBuilder). The 6 feeds are processed one at a time: beginFeed → each stop_times row → endFeed,
// dropping each feed's trip table when done; stop_times.txt is passed in line by line, never held in memory whole.
// Feed order must match BusMap.sourceURLs (bx, b, m, q, si, busco): route order and "first seen wins on a tie" both depend on it.

/// The part of generate_bus.py that produces bus_stops.json.
public final class BusStaticBuilder {
    static let source = "MTA bus static GTFS (rrgtfsfeeds gtfs_bx/b/m/q/si/busco.zip)"

    private struct Route {
        var name: String
        var color: String
        var express: Bool
        var agency: String
    }

    private struct Stop {
        var name: String
        var lat: Double
        var lon: Double
    }

    private struct RouteDirection: Hashable {
        var route: String
        var direction: String
    }

    /// Routes in order of first appearance (also the output order); for the same route, the first appearance wins
    private var routeOrder: [String] = []
    private var routes: [String: Route] = [:]
    /// For the same stop, the first appearance wins
    private var stops: [String: Stop] = [:]
    /// (route, direction) → index
    private var rdIndex: [RouteDirection: Int32] = [:]
    private var rds: [RouteDirection] = []
    /// Per (route, direction) index: how many times each terminal spelling appears (across all feeds)
    private var headsignTallies: [Tally<String>] = []
    /// Current feed: trip_id → (route, direction) index
    private var tripRD: [String: Int32] = [:]
    private var lastTripID: String?
    private var lastRD: Int32?
    /// Stop → (route, direction) indexes passing through it
    private var stopRDs: [String: Set<Int32>] = [:]
    /// Newest version among the feeds
    public private(set) var feedVersion = ""

    public init() {}

    /// Starts a feed: routes.txt, stops.txt, trips.txt, with feed_info.txt optional.
    public func beginFeed(routes routesData: Data, stops stopsData: Data, trips tripsData: Data, feedInfo: Data?) throws {
        endFeed()
        try TimetableBuilder.forEachRow(routesData) { col in
            guard let id = col("route_id"), self.routes[id] == nil else { return }
            let short = col("route_short_name") ?? ""
            let color = col("route_color") ?? ""
            self.routes[id] = Route(name: short.isEmpty ? id : short,
                                    color: (color.isEmpty ? "0039A6" : color).uppercased(),
                                    express: Self.isExpress(id, short), agency: col("agency_id") ?? "")
            self.routeOrder.append(id)
        }
        try TimetableBuilder.forEachRow(stopsData) { col in
            guard let id = col("stop_id") else { return }
            // Generic nodes and boarding areas (location_type 3, 4) aren't stops and may have no coordinates; rows whose coordinates
            // can't be read are skipped too, so one bad row doesn't fail the whole monthly rebuild (the script does the same)
            let type = Py.strip(col("location_type") ?? "")
            guard type != "3", type != "4" else { return }
            guard let lat = col("stop_lat").flatMap(Py.float), let lon = col("stop_lon").flatMap(Py.float) else { return }
            if self.stops[id] == nil {
                self.stops[id] = Stop(name: Self.nice(col("stop_name") ?? ""), lat: Py.round(lat, 5), lon: Py.round(lon, 5))
            }
        }
        var cleaned: [String: String] = [:]
        try TimetableBuilder.forEachRow(tripsData) { col in
            guard let trip = col("trip_id") else { return }
            let direction = col("direction_id") ?? ""
            let rd = self.routeDirection(col("route_id") ?? "", direction.isEmpty ? "0" : direction)
            self.tripRD[trip] = rd
            let raw = col("trip_headsign") ?? ""
            let h: String
            if let known = cleaned[raw] {
                h = known
            } else {
                h = Self.headsign(raw)
                cleaned[raw] = h
            }
            self.headsignTallies[Int(rd)].add(h)
        }
        if let feedInfo {
            var first = true
            try TimetableBuilder.forEachRow(feedInfo) { col in
                guard first else { return }
                first = false
                if let v = col("feed_version"), Py.less(self.feedVersion, v) { self.feedVersion = v }
            }
        }
    }

    private func routeDirection(_ route: String, _ direction: String) -> Int32 {
        let key = RouteDirection(route: route, direction: direction)
        if let i = rdIndex[key] { return i }
        let i = Int32(rds.count)
        rds.append(key)
        rdIndex[key] = i
        headsignTallies.append(Tally())
        return i
    }

    public func addStopTime(tripID: String, stopID: String) {
        if tripID != lastTripID {
            lastTripID = tripID
            lastRD = tripRD[tripID]
        }
        guard let rd = lastRD else { return }
        stopRDs[stopID, default: []].insert(rd)
    }

    /// One row of stop_times.txt (uses trip_id, stop_id).
    public func addStopTimeRow(_ column: (String) -> String?) {
        guard let trip = column("trip_id"), let stop = column("stop_id") else { return }
        addStopTime(tripID: trip, stopID: stop)
    }

    /// This feed is done: drop its trip table.
    public func endFeed() {
        tripRD = [:]
        lastTripID = nil
        lastRD = nil
    }

    /// bus_stops.json
    public func stopsJSON() throws -> Data {
        var json = PyJSON()
        json.raw("{\"source\":"); json.string(Self.source)
        json.raw(",\"feedVersion\":"); json.string(feedVersion)
        json.raw(",\"routes\":{")
        // Drop routes with no trips in either direction (no terminal)
        var kept = Set<String>()
        for id in routeOrder {
            let headsigns = ["0", "1"].compactMap { d -> (String, String)? in
                guard let i = rdIndex[RouteDirection(route: id, direction: d)],
                      let top = headsignTallies[Int(i)].mostCommon else { return nil }
                return (d, top)
            }
            guard !headsigns.isEmpty, let r = routes[id] else { continue }
            if !kept.isEmpty { json.raw(",") }
            kept.insert(id)
            json.string(id)
            json.raw(":{\"name\":"); json.string(r.name)
            json.raw(",\"color\":"); json.string(r.color)
            json.raw(",\"express\":"); json.bool(r.express)
            json.raw(",\"agency\":"); json.string(r.agency)
            json.raw(",\"headsigns\":{")
            for (k, (d, h)) in headsigns.enumerated() {
                if k > 0 { json.raw(",") }
                json.string(d)
                json.raw(":")
                json.string(h)
            }
            json.raw("}}")
        }
        json.raw("},\"stops\":[")
        // Stops sorted by ID; drop stops not served by any kept route
        var first = true
        for id in stopRDs.keys.sorted(by: Py.less) {
            guard let s = stops[id] else { continue }
            let list = stopRDs[id]!.map { rds[Int($0)] }.filter { kept.contains($0.route) }
                .map { $0.route + "|" + $0.direction }.sorted(by: Py.less)
            guard !list.isEmpty else { continue }
            if !first { json.raw(",") }
            first = false
            json.raw("["); json.string(id)
            json.raw(","); json.string(s.name)
            json.raw(","); json.number(s.lat)
            json.raw(","); json.number(s.lon)
            json.raw(",[")
            for (k, rd) in list.enumerated() {
                if k > 0 { json.raw(",") }
                json.string(rd)
            }
            json.raw("]]")
        }
        json.raw("]}")
        return json.data
    }

    // MARK: Name cleanup (same as nice, headsign, is_express in the script)

    static let keepUpper: Set<String> = ["SBS", "JFK", "LIRR", "CUNY", "NYC", "MTA", "US", "VA", "LGA", "PATH",
                                         "II", "III", "IV", "SI", "UPS"]
    static let small: Set<String> = ["of", "and", "via", "to", "the", "at"]

    /// nice(): 'WILLIS AV/E 138 ST' → 'Willis Av / E 138 St'
    static func nice(_ raw: String) -> String {
        let s = Array(Py.strip(raw).unicodeScalars)
        // re.sub(r"\s*/\s*", " / ", …)
        var spaced: [Unicode.Scalar] = []
        spaced.reserveCapacity(s.count + 4)
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count, Py.isSpace(s[j]) { j += 1 }
            if j < s.count, s[j] == "/" {
                spaced += [" ", "/", " "]
                j += 1
                while j < s.count, Py.isSpace(s[j]) { j += 1 }
                i = j
            } else if j > i {
                spaced += s[i..<j]
                i = j
            } else {
                spaced.append(s[i])
                i += 1
            }
        }
        // split() splits on whitespace
        var words: [[Unicode.Scalar]] = []
        var word: [Unicode.Scalar] = []
        for u in spaced {
            if Py.isSpace(u) {
                if !word.isEmpty { words.append(word); word = [] }
            } else {
                word.append(u)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.enumerated().map { niceWord($1, index: $0) }.joined(separator: " ")
    }

    private static func niceWord(_ w: [Unicode.Scalar], index: Int) -> String {
        let text = Py.string(w)
        let upper = text.uppercased()
        if keepUpper.contains(upper) { return upper }
        if isOrdinal(w) { return text.lowercased() }
        let lower = text.lowercased()
        if index > 0, small.contains(lower) { return lower }
        // Each part (split by -) gets an uppercase first letter, the rest lowercase
        return w.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            guard let first = part.first else { return "" }
            return String(first).uppercased() + Py.string(part.dropFirst()).lowercased()
        }.joined(separator: "-")
    }

    /// re.match(r"^\d+(ST|ND|RD|TH)$", w, re.I): 138TH, 2nd
    private static func isOrdinal(_ w: [Unicode.Scalar]) -> Bool {
        var k = 0
        while k < w.count, Py.isDigit(w[k]) { k += 1 }
        guard k > 0, w.count - k == 2 else { return false }
        return ["ST", "ND", "RD", "TH"].contains { Py.hasPrefixIgnoringCase(w, at: k, $0) }
    }

    /// headsign(): strips a leading "SELECT BUS" "LIMITED" "EXPRESS" and a trailing "via …", then cleans up with nice().
    static func headsign(_ raw: String) -> String {
        var s = Array(Py.strip(raw).unicodeScalars)
        // re.sub(r"^\+?\s*(SELECT BUS|LIMITED|LTD|EXPRESS)\s+", "", …, flags=re.I)
        var i = 0
        if i < s.count, s[i] == "+" { i += 1 }
        while i < s.count, Py.isSpace(s[i]) { i += 1 }
        for prefix in ["SELECT BUS", "LIMITED", "LTD", "EXPRESS"] where Py.hasPrefixIgnoringCase(s, at: i, prefix) {
            var j = i + prefix.unicodeScalars.count
            if j < s.count, Py.isSpace(s[j]) {
                while j < s.count, Py.isSpace(s[j]) { j += 1 }
                s.removeFirst(j)
            }
            break
        }
        // re.split(r"\s+via\s+", …, flags=re.I)[0]
        var k = 0
        while k < s.count {
            guard Py.isSpace(s[k]) else { k += 1; continue }
            var j = k
            while j < s.count, Py.isSpace(s[j]) { j += 1 }
            if Py.hasPrefixIgnoringCase(s, at: j, "via"), j + 3 < s.count, Py.isSpace(s[j + 3]) {
                s.removeSubrange(k...)
                break
            }
            k = j
        }
        return nice(Py.string(s))
    }

    /// is_express(): route number has "+", short name contains SBS, or starts with BxM, BM, QM, SIM, X followed by a digit.
    static func isExpress(_ routeID: String, _ short: String) -> Bool {
        if routeID.unicodeScalars.last == "+" || Py.contains(short.uppercased(), "SBS") { return true }
        let u = Array(routeID.uppercased().unicodeScalars)
        for prefix in ["BXM", "BM", "QM", "SIM", "X"] {
            let p = Array(prefix.unicodeScalars)
            if u.count > p.count, Array(u[..<p.count]) == p, Py.isDigit(u[p.count]) { return true }
        }
        return false
    }
}
