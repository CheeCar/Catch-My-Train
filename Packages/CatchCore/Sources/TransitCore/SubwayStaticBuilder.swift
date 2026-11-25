import Foundation

// MARK: - Regenerate the station catalog and express data from GTFS
//
// Same approach as tools/generate_stations.py and tools/generate_express.py; the generated files are byte-for-byte identical to the scripts' output.
// Both scripts read stop_times.txt (36 MB): here it's read only once, handed to addStopTimeRow line by line, without loading it all into memory.

/// generate_stations.py + generate_express.py.
public final class SubwayStaticBuilder {
    static let source = "MTA New York City Transit static GTFS (https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip)"

    /// Static GTFS occasionally lacks departures for a station in one direction (e.g. 7 line 52 St, 69 St northbound); fill in the terminal manually (FILL in the script).
    static func fill(station: String, route: String, code: String) -> String? {
        guard code == "N", ["710", "711", "713"].contains(station), ["7", "7X"].contains(route) else { return nil }
        return "Flushing-Main St"
    }

    private struct Stop {
        var name: String
        var lat: String
        var lon: String
        /// location_type == "1"
        var isStation: Bool
        var parent: String
    }

    private struct Trip {
        var route: String
        /// direction_id == "0": northbound (platform ID suffix N)
        var north: Bool
        /// Index of the terminal in headsigns; -1 means this row has no trip_headsign (None in the script, written as null)
        var headsign: Int32
    }

    private struct HeadKey: Hashable {
        var station: String
        var route: String
        var north: Bool
    }

    private struct SeqStop: Hashable {
        var seq: Int
        /// Index of the platform in platformIDs
        var stop: Int32
    }

    private let catalog: StationCatalog?
    private var stops: [String: Stop] = [:]
    private var trips: [String: Trip] = [:]
    private var headsigns: [String] = []
    private var headsignIndex: [String: Int32] = [:]
    private var feedStart = ""
    private var feedEnd = ""
    public private(set) var feedVersion = ""

    // Station catalog (generate_stations.py)
    /// (station, route, direction) → count of each terminal
    private var heads: [HeadKey: Tally<Int32>] = [:]
    private var lastTripID: String?
    private var lastTrip: Trip?
    /// Number of rows skipped because direction_id and the platform suffix N/S disagree (the script's warning)
    private(set) var mismatched = 0

    // Express (generate_express.py)
    /// Platform ID (with N/S) → index
    private var platformIndex: [String: Int32] = [:]
    private var platformIDs: [String] = []
    /// The trip being read (rows of the same trip are contiguous in the file; when the next trip starts, finish this one)
    private var currentTrip: String?
    private var currentStops: [SeqStop] = []
    /// Finished trips → index of the stop list
    private var finishedTrips: [String: Int] = [:]
    /// Deduplicated stop lists (sorted by stop_sequence) and the number of trips using each
    private var lists: [[SeqStop]] = []
    private var listUses: [Int] = []
    private var listIndex: [[SeqStop]: Int] = [:]
    /// When rows aren't grouped by trip, trips that reappear later go here and are processed after everything is read
    private var reopened: [String: [SeqStop]] = [:]
    /// Platform rows of stop_times.txt, and those of them whose stop_sequence isn't an integer: skipped, like the script does;
    /// more than badShare of them and the express data isn't made (see expressJSON)
    private(set) var platformRows = 0
    private(set) var badSequences = 0
    /// Stations whose stop_lat or stop_lon isn't a number: left out, like the script does (see stationsJSON)
    private(set) var badStations = 0
    /// One bad row or station in a hundred is skipped; more means the data is broken and nothing is made (the script stops too)
    static func tooMany(bad: Int, of all: Int) -> Bool { bad * 100 > all }

    /// - Parameter catalog: stop groups, boroughs and signage direction names come from the station catalog in use (GTFS doesn't have them);
    ///   stations not in the catalog don't get this info (same as when the script can't find the row in the MTA table).
    public init(stops: Data, trips: Data, feedInfo: Data?, labelsFrom catalog: StationCatalog?) throws {
        self.catalog = catalog
        try TimetableBuilder.forEachRow(stops) { col in
            guard let id = col("stop_id") else { return }
            self.stops[id] = Stop(name: col("stop_name") ?? "", lat: col("stop_lat") ?? "", lon: col("stop_lon") ?? "",
                                  isStation: col("location_type") == "1", parent: col("parent_station") ?? "")
        }
        try TimetableBuilder.forEachRow(trips) { col in
            guard let id = col("trip_id") else { return }
            self.trips[id] = Trip(route: col("route_id") ?? "", north: col("direction_id") == "0",
                                  headsign: col("trip_headsign").map { self.intern($0) } ?? -1)
        }
        if let feedInfo {
            var first = true
            try TimetableBuilder.forEachRow(feedInfo) { col in
                guard first else { return }
                first = false
                self.feedVersion = col("feed_version") ?? ""
                self.feedStart = col("feed_start_date") ?? ""
                self.feedEnd = col("feed_end_date") ?? ""
            }
        }
    }

    private func intern(_ headsign: String) -> Int32 {
        if let i = headsignIndex[headsign] { return i }
        let i = Int32(headsigns.count)
        headsigns.append(headsign)
        headsignIndex[headsign] = i
        return i
    }

    // MARK: stop_times.txt

    public func addStopTime(tripID: String, stopID: String, sequence: Int) {
        countHeadsign(tripID: tripID, stopID: stopID)
        if Self.isPlatform(stopID) { addToPattern(tripID: tripID, stopID: stopID, sequence: sequence) }
    }

    /// One row of stop_times.txt (uses trip_id, stop_id, stop_sequence).
    public func addStopTimeRow(_ column: (String) -> String?) {
        guard let trip = column("trip_id"), let stop = column("stop_id") else { return }
        countHeadsign(tripID: trip, stopID: stop)
        guard Self.isPlatform(stop) else { return }
        platformRows += 1
        guard let seq = column("stop_sequence").flatMap(Py.int) else { badSequences += 1; return }
        addToPattern(tripID: trip, stopID: stop, sequence: seq)
    }

    /// Platform ID ends in N or S
    static func isPlatform(_ stopID: String) -> Bool {
        let last = stopID.unicodeScalars.last
        return last == "N" || last == "S"
    }

    /// Station catalog: terminal counts per (station, route, direction).
    private func countHeadsign(tripID: String, stopID: String) {
        if tripID != lastTripID {
            lastTripID = tripID
            lastTrip = trips[tripID]
        }
        guard let trip = lastTrip, let stop = stops[stopID], !stop.parent.isEmpty else { return }
        let expected: Unicode.Scalar = trip.north ? "N" : "S"
        guard stopID.unicodeScalars.last == expected else { mismatched += 1; return }
        heads[HeadKey(station: stop.parent, route: trip.route, north: trip.north), default: Tally()].add(trip.headsign)
    }

    /// Express: stop order of each trip.
    private func addToPattern(tripID: String, stopID: String, sequence: Int) {
        let entry = SeqStop(seq: sequence, stop: platform(stopID))
        if tripID == currentTrip {
            currentStops.append(entry)
            return
        }
        if reopened[tripID] != nil {
            reopened[tripID]!.append(entry)
            return
        }
        finishCurrentTrip()
        if let id = finishedTrips.removeValue(forKey: tripID) {
            // This trip appeared earlier (rows not grouped by trip): append to the earlier rows, process after everything is read
            reopened[tripID] = lists[id] + [entry]
            release(id)
            return
        }
        currentTrip = tripID
        currentStops = [entry]
    }

    private func platform(_ id: String) -> Int32 {
        if let i = platformIndex[id] { return i }
        let i = Int32(platformIDs.count)
        platformIDs.append(id)
        platformIndex[id] = i
        return i
    }

    /// Finished reading a trip: sort, merge with identical stop lists, record only the index.
    private func finishCurrentTrip() {
        guard let trip = currentTrip else { return }
        let list = sortedStops(currentStops)
        let id: Int
        if let existing = listIndex[list] {
            id = existing
            listUses[id] += 1
        } else {
            id = lists.count
            lists.append(list)
            listUses.append(1)
            listIndex[list] = id
        }
        finishedTrips[trip] = id
        currentTrip = nil
        currentStops.removeAll(keepingCapacity: true)
    }

    private func release(_ id: Int) {
        listUses[id] -= 1
        if listUses[id] == 0 {
            listIndex[lists[id]] = nil
            lists[id] = []
        }
    }

    /// Sort by (stop_sequence, platform ID) (same as sorting tuples in the script).
    private func sortedStops(_ list: [SeqStop]) -> [SeqStop] {
        list.sorted { a, b in
            a.seq != b.seq ? a.seq < b.seq : Py.less(platformIDs[Int(a.stop)], platformIDs[Int(b.stop)])
        }
    }

    // MARK: Output

    /// subway_stations.json
    public func stationsJSON() throws -> Data {
        // Station → route → most common terminal for both directions (nil: no departures in that direction)
        struct Ends { var north: Int32?; var south: Int32? }
        var byStation: [String: [String: Ends]] = [:]
        for (key, tally) in heads {
            guard let top = tally.mostCommon else { continue }
            if key.north {
                byStation[key.station, default: [:]][key.route, default: Ends()].north = top
            } else {
                byStation[key.station, default: [:]][key.route, default: Ends()].south = top
            }
        }
        func name(_ i: Int32) -> String? { i < 0 ? nil : headsigns[Int(i)] }

        var json = PyJSON()
        json.raw("{\"source\":"); json.string(Self.source)
        json.raw(",\"feedVersion\":"); json.string(feedVersion)
        json.raw(",\"feedStartDate\":"); json.string(feedStart)
        json.raw(",\"feedEndDate\":"); json.string(feedEnd)
        json.raw(",\"stations\":[")
        let all = stops.keys.filter { stops[$0]!.isStation && byStation[$0] != nil }.sorted(by: Py.less)
        // A station whose position isn't a number is left out (counted in badStations)
        var ids: [(id: String, lat: Double, lon: Double)] = []
        for sid in all {
            if let lat = Py.float(stops[sid]!.lat), let lon = Py.float(stops[sid]!.lon) { ids.append((sid, lat, lon)) }
        }
        badStations = all.count - ids.count
        guard !Self.tooMany(bad: badStations, of: all.count) else { throw TimetableError.badFormat }
        for (k, (sid, lat, lon)) in ids.enumerated() {
            let s = stops[sid]!
            if k > 0 { json.raw(",") }
            json.raw("{\"id\":"); json.string(sid)
            json.raw(",\"name\":"); json.string(s.name)
            json.raw(",\"lat\":"); json.number(Py.round(lat, 6))
            json.raw(",\"lon\":"); json.number(Py.round(lon, 6))
            json.raw(",\"routes\":[")
            let routes = byStation[sid]!.sorted { Py.less($0.key, $1.key) }
            for (m, (route, ends)) in routes.enumerated() {
                let north = ends.north != nil ? name(ends.north!) : Self.fill(station: sid, route: route, code: "N")
                let south = ends.south != nil ? name(ends.south!) : Self.fill(station: sid, route: route, code: "S")
                if m > 0 { json.raw(",") }
                json.raw("{\"route\":"); json.string(route)
                json.raw(",\"north\":"); json.string(north)
                json.raw(",\"south\":"); json.string(south)
                json.raw("}")
            }
            json.raw("]")
            if let e = catalog?.entry(id: sid) {
                if let v = e.complex { json.raw(",\"complex\":"); json.string(v) }
                if let v = e.borough { json.raw(",\"borough\":"); json.string(v) }
                if let v = e.northLabel { json.raw(",\"northLabel\":"); json.string(v) }
                if let v = e.southLabel { json.raw(",\"southLabel\":"); json.string(v) }
            }
            json.raw("}")
        }
        json.raw("]}")
        return json.data
    }

    /// express_stops.json
    public func expressJSON() throws -> Data {
        guard !Self.tooMany(bad: badSequences, of: platformRows) else { throw TimetableError.badFormat }
        // All distinct stop sequences
        var patterns = Set<[Int32]>()
        for (i, list) in lists.enumerated() where listUses[i] > 0 { patterns.insert(list.map(\.stop)) }
        if currentTrip != nil { patterns.insert(sortedStops(currentStops).map(\.stop)) }
        for list in reopened.values { patterns.insert(sortedStops(list).map(\.stop)) }

        // Platform → station and direction
        var stationOf: [Int32] = [], northOf: [Bool] = []
        var stationIndex: [String: Int32] = [:], stationIDs: [String] = []
        for id in platformIDs {
            var u = id.unicodeScalars
            let code = u.removeLast()
            let station = String(u)
            let i: Int32
            if let known = stationIndex[station] {
                i = known
            } else {
                i = Int32(stationIDs.count)
                stationIDs.append(station)
                stationIndex[station] = i
            }
            stationOf.append(i)
            northOf.append(code == "N")
        }

        // (A, direction, B) going directly to the next stop, and (A, direction, B) where another train after A reaches B later: having both means a skipped stop
        struct Skip: Hashable { var from: Int32; var north: Bool; var to: Int32 }
        var direct = Set<Skip>(), later = Set<Skip>()
        for p in patterns {
            let n = p.count
            for i in 0..<n {
                let a = stationOf[Int(p[i])], d = northOf[Int(p[i])]
                if i + 1 < n, northOf[Int(p[i + 1])] == d {
                    direct.insert(Skip(from: a, north: d, to: stationOf[Int(p[i + 1])]))
                }
                var j = i + 2
                while j < n {
                    let b = stationOf[Int(p[j])]
                    if northOf[Int(p[j])] == d, b != a { later.insert(Skip(from: a, north: d, to: b)) }
                    j += 1
                }
            }
        }
        let skips = direct.intersection(later).sorted { x, y in
            if x.from != y.from { return Py.less(stationIDs[Int(x.from)], stationIDs[Int(y.from)]) }
            if x.north != y.north { return x.north }
            return Py.less(stationIDs[Int(x.to)], stationIDs[Int(y.to)])
        }
        var result: [String: [String]] = [:]
        for s in skips {
            result[stationIDs[Int(s.from)] + (s.north ? "N" : "S"), default: []].append(stationIDs[Int(s.to)])
        }

        var json = PyJSON(asciiOnly: true)
        json.raw("{")
        for (k, key) in result.keys.sorted(by: Py.less).enumerated() {
            if k > 0 { json.raw(",") }
            json.string(key)
            json.raw(":[")
            for (m, b) in result[key]!.enumerated() {
                if m > 0 { json.raw(",") }
                json.string(b)
            }
            json.raw("]")
        }
        json.raw("}")
        return json.data
    }
}
