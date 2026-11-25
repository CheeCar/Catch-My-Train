import XCTest
@testable import TransitCore
#if canImport(Compression)
import Compression
#endif

/// Static data that updates itself monthly: read GTFS in chunks, generate files the same way as the Python scripts in tools/, and prefer the downloaded copy when loading.
final class StaticDataTests: XCTestCase {

    // MARK: Chunked reading

    /// BOM, CRLF, commas inside quotes, multibyte UTF-8, a combining character after a comma, blank lines, rows with fewer columns, no newline on the last row
    static let messyCSV = Data(([
        "\u{FEFF}stop_id,stop_name,note\r\n",
        "1,\"Caf\u{E9}, Plaza\",ok\r\n",
        "2,\u{8ECA}\u{7AD9} \u{1F687},\"a \"\"quoted\"\" one\"\r\n",
        "\r\n",
        "\n",
        "3,plain,\r\n",
        "4,\"x,y,z\",last\n",
        "5,\u{E9},\u{301}combining\n",
        "6,\u{600},prepend\n",
        "7,short\r\n",
        "8,a\rb,c\r\n",
        "9,\u{FC}n\u{EF}c\u{F6}d\u{E9},\u{F1}\r\n",
        "10,end,cr only\r",
    ] as [String]).joined().utf8)

    static let columns = ["stop_id", "stop_name", "note", "missing"]

    func testRowReaderMatchesForEachRowAtEveryBoundary() throws {
        let data = Self.messyCSV
        var expected: [[String?]] = []
        try TimetableBuilder.forEachRow(data) { col in expected.append(Self.columns.map(col)) }
        XCTAssertEqual(expected.count, 10)
        XCTAssertEqual(expected.first?[1], "Caf\u{E9}, Plaza")

        // Split at every position (including inside multibyte characters and between \r and \n)
        for cut in 0...data.count {
            var got: [[String?]] = []
            let reader = GTFSRowReader { col in got.append(Self.columns.map(col)) }
            try reader.feed(data[data.startIndex..<(data.startIndex + cut)])
            try reader.feed(data[(data.startIndex + cut)...])
            try reader.finish()
            XCTAssertEqual(got, expected, "cut at \(cut)")
        }
        // One byte at a time; 3 bytes at a time
        for size in [1, 3, 7] {
            var got: [[String?]] = []
            let reader = GTFSRowReader { col in got.append(Self.columns.map(col)) }
            var p = 0
            while p < data.count {
                try reader.feed(data.subdata(in: p..<min(p + size, data.count)))
                p += size
            }
            try reader.finish()
            XCTAssertEqual(got, expected, "chunks of \(size)")
        }
    }

    func testRowReaderStopsOnError() {
        struct Stop: Error {}
        let reader = GTFSRowReader { col in if col("stop_id") == "2" { throw Stop() } }
        XCTAssertThrowsError(try reader.feed(Self.messyCSV))
    }

    // MARK: Subway

    static let labels = StationCatalog(entries: [
        .init(id: "701", name: "Flushing-Main St", lat: 0, lon: 0, routes: [],
              complex: "447", borough: "Q", northLabel: "Last Stop", southLabel: "Manhattan"),
        .init(id: "712", name: "61 St-Woodside", lat: 0, lon: 0, routes: [],
              complex: "456", borough: "Q", northLabel: "Flushing", southLabel: "Manhattan"),
    ])

    static func subwayBuilder(stopTimes: String = subwayStopTimes) throws -> SubwayStaticBuilder {
        let b = try SubwayStaticBuilder(stops: Data(subwayStops.utf8), trips: Data(subwayTrips.utf8),
                                        feedInfo: Data(subwayFeedInfo.utf8), labelsFrom: labels)
        // Feed stop_times in small chunks
        let reader = GTFSRowReader { b.addStopTimeRow($0) }
        let data = Data(stopTimes.utf8)
        var p = 0
        while p < data.count {
            try reader.feed(data.subdata(in: p..<min(p + 100, data.count)))
            p += 100
        }
        try reader.finish()
        return b
    }

    /// Byte-for-byte identical to the output of tools/generate_stations.py (FILL looked up per station) and generate_express.py.
    func testSubwayBuilderMatchesScripts() throws {
        let b = try Self.subwayBuilder()
        XCTAssertEqual(b.feedVersion, "20260901-X-test")
        XCTAssertEqual(String(decoding: try b.stationsJSON(), as: UTF8.self), Self.expectedStations)
        XCTAssertEqual(String(decoding: try b.expressJSON(), as: UTF8.self), Self.expectedExpress)
        // T7 northbound (direction_id 0) but stopping at A24S: skipped
        XCTAssertEqual(b.mismatched, 1)

        let c = try StationCatalog.decode(b.stationsJSON())
        XCTAssertEqual(c.feedVersion, "20260901-X-test")
        XCTAssertEqual(c.entries.map(\.id), ["701", "710", "712", "726", "A24"], "Sorted by ID; stations with no trips are dropped")
        // 7 line 52 St (710) has no northbound trips: filled from FILL; stations not in FILL aren't filled
        XCTAssertEqual(c.entry(id: "710")?.routes.map(\.north), ["Flushing-Main St", "Flushing-Main St"])
        XCTAssertNil(c.entry(id: "701")?.routes.first { $0.route == "7X" }?.north)
        // On a tie the first one wins: 712 northbound has "Flushing-Main St" and "Flushing, Main St" once each
        XCTAssertEqual(c.entry(id: "712")?.routes.first?.north, "Flushing-Main St")
        XCTAssertEqual(c.entry(id: "A24")?.routes.first?.south, "Far Rockaway")
        // The more frequent one wins: 710 southbound has 34 St-Hudson Yards twice, 61 St-Woodside once
        XCTAssertEqual(c.entry(id: "710")?.routes.first?.south, "34 St-Hudson Yards")
        // Python's round: exact halves round to even
        XCTAssertEqual(c.entry(id: "710")?.lat, 40.007812)
        XCTAssertEqual(c.entry(id: "710")?.lon, -73.007812)
        // Station complexes and direction names come from the catalog in use; stations not in the catalog get none
        XCTAssertEqual(c.entry(id: "701")?.complex, "447")
        XCTAssertEqual(c.entry(id: "712")?.northLabel, "Flushing")
        XCTAssertNil(c.entry(id: "710")?.complex)
        XCTAssertNil(c.entry(id: "A24")?.northLabel)
        XCTAssertEqual(c.entry(id: "A24")?.name, "59 St–Columbus C\u{ED}rcle \\ x")

        let e = try ExpressStops.decode(b.expressJSON())
        XCTAssertTrue(e.skips(from: "101", direction: "S", to: "104"))
        XCTAssertFalse(e.skips(from: "104", direction: "S", to: "106"))
        XCTAssertTrue(e.skips(from: "104", direction: "N", to: "101"))
        // Same stop_sequence: ordered by platform ID (202N before 203N)
        XCTAssertTrue(e.skips(from: "201", direction: "N", to: "203"))
        XCTAssertTrue(e.skips(from: "\u{C4}1", direction: "S", to: "\u{C4}3"))
    }

    /// When rows aren't ordered by trip (a trip's rows scattered across the file), the express result is unchanged.
    func testExpressWithUngroupedRows() throws {
        let lines = Self.subwayStopTimes.split(separator: "\n").map(String.init)
        let header = lines[0]
        let rows = Array(lines.dropFirst())
        // Reverse, then interleave the two halves
        let reversed = Array(rows.reversed())
        let half = reversed.count / 2
        var mixed: [String] = []
        for i in 0..<half {
            mixed.append(reversed[i])
            mixed.append(reversed[half + i])
        }
        mixed += reversed[(2 * half)...]
        for order in [reversed, mixed] {
            let b = try Self.subwayBuilder(stopTimes: ([header] + order).joined(separator: "\n"))
            XCTAssertEqual(String(decoding: try b.expressJSON(), as: UTF8.self), Self.expectedExpress)
            // A different one appears first now: A24 southbound Lefferts Blvd appears first
            let c = try StationCatalog.decode(b.stationsJSON())
            XCTAssertEqual(c.entry(id: "A24")?.routes.first?.south, "Lefferts Blvd")
        }
        // Add rows directly one by one
        let b = try SubwayStaticBuilder(stops: Data(Self.subwayStops.utf8), trips: Data(Self.subwayTrips.utf8),
                                        feedInfo: nil, labelsFrom: nil)
        for row in mixed {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            b.addStopTime(tripID: f[0], stopID: f[1], sequence: Int(f[4])!)
        }
        XCTAssertEqual(String(decoding: try b.expressJSON(), as: UTF8.self), Self.expectedExpress)
        XCTAssertEqual(b.feedVersion, "")
    }

    func testExpressRefusesBadSequence() throws {
        let b = try Self.subwayBuilder(stopTimes: Self.subwayStopTimes + "\nT1,701N,08:30:00,08:30:00,x\n")
        XCTAssertThrowsError(try b.expressJSON())
        XCTAssertNoThrow(try b.stationsJSON(), "generate_stations.py doesn't read stop_sequence")
    }

    /// One unreadable row or station in a hundred is skipped (counted), like the scripts do; more and nothing is made
    func testSkipsAFewBadRows() throws {
        XCTAssertFalse(SubwayStaticBuilder.tooMany(bad: 1, of: 100))
        XCTAssertTrue(SubwayStaticBuilder.tooMany(bad: 1, of: 99))
        XCTAssertTrue(SubwayStaticBuilder.tooMany(bad: 2, of: 100))
        XCTAssertFalse(SubwayStaticBuilder.tooMany(bad: 0, of: 0))

        // 120 one-stop trips (no express pattern, no trip in trips.txt) make the bad row one in more than a hundred
        let filler = (0..<120).map { "TX\($0),701N,08:30:00,08:30:00,1" }.joined(separator: "\n")
        let b = try Self.subwayBuilder(stopTimes: Self.subwayStopTimes + "\n" + filler + "\nT1,701N,08:30:00,08:30:00,x\n")
        XCTAssertEqual(String(decoding: try b.expressJSON(), as: UTF8.self), Self.expectedExpress)
        XCTAssertEqual(b.badSequences, 1)
        XCTAssertEqual(String(decoding: try b.stationsJSON(), as: UTF8.self), Self.expectedStations)

        // A station whose position isn't a number: left out, but here it is one of a handful, so nothing is made
        let stops = Self.subwayStops.replacingOccurrences(of: "712,61 St-Woodside,40.74563,-73.902984,1,",
                                                          with: "712,61 St-Woodside,north,-73.902984,1,")
        let c = try SubwayStaticBuilder(stops: Data(stops.utf8), trips: Data(Self.subwayTrips.utf8),
                                        feedInfo: Data(Self.subwayFeedInfo.utf8), labelsFrom: Self.labels)
        let reader = GTFSRowReader { c.addStopTimeRow($0) }
        try reader.feed(Data(Self.subwayStopTimes.utf8))
        try reader.finish()
        XCTAssertThrowsError(try c.stationsJSON())
        XCTAssertEqual(c.badStations, 1)
    }

    // MARK: Bus

    static func addBusFeed(_ b: BusStaticBuilder, _ files: [String], crlf: Bool) throws {
        func data(_ s: String) -> Data { Data((crlf ? s.replacingOccurrences(of: "\n", with: "\r\n") : s).utf8) }
        try b.beginFeed(routes: data(files[0]), stops: data(files[1]), trips: data(files[2]), feedInfo: data(files[4]))
        let reader = GTFSRowReader { b.addStopTimeRow($0) }
        try reader.feed(data(files[3]))
        try reader.finish()
        b.endFeed()
    }

    /// Byte-for-byte identical to the bus_stops.json generated by tools/generate_bus.py (two feeds, the second with CRLF).
    func testBusBuilderMatchesScript() throws {
        let b = BusStaticBuilder()
        try Self.addBusFeed(b, [Self.bus1Routes, Self.bus1Stops, Self.bus1Trips, Self.bus1StopTimes, Self.bus1FeedInfo], crlf: false)
        try Self.addBusFeed(b, [Self.bus2Routes, Self.bus2Stops, Self.bus2Trips, Self.bus2StopTimes, Self.bus2FeedInfo], crlf: true)
        XCTAssertEqual(b.feedVersion, "20260813", "The highest version among the feeds")
        XCTAssertEqual(String(decoding: try b.stopsJSON(), as: UTF8.self), Self.expectedBus)

        let c = try BusCatalog.decode(b.stopsJSON())
        XCTAssertNil(c.routes["Q99"], "Routes with no trips are dropped")
        XCTAssertNil(c.stop(id: "105"), "Stops with no trips are dropped")
        XCTAssertNil(c.stop(id: "106"), "Served only by routes missing from routes.txt: dropped")
        XCTAssertNil(c.stop(id: "107"), "Not a stop (location_type 3): skipped, the rebuild doesn't fail")
        XCTAssertNil(c.stop(id: "108"), "Coordinates can't be read: skipped")
        XCTAssertEqual(c.routes["BX1"]?.color, "00AEEF", "For the same route, the first feed wins")
        XCTAssertEqual(c.routes["BX1"]?.headsigns, ["0": "Mott Haven 138 St", "1": "Riverdale"], "Counts are combined across both feeds")
        XCTAssertEqual(c.routes["B44"]?.name, "B44")
        XCTAssertEqual(c.routes["BXM2"]?.headsigns, ["0": ""])
        XCTAssertEqual(c.routes["Q53+"]?.headsigns["1"], "Rockaway Park B 116 St")
        XCTAssertEqual(c.routes.filter { $0.value.express }.keys.sorted(), ["BXM2", "M15+", "Q53+", "X27"])
        let s = try XCTUnwrap(c.stop(id: "100"))
        XCTAssertEqual(s.name, "Willis Av / E 138 St", "For the same stop, the first feed wins")
        XCTAssertEqual(s.lat, 40.01562)
        XCTAssertEqual(s.lon, -73.95312)
        XCTAssertEqual(c.stop(id: "102")?.routeDirections.map(\.route), ["BX1", "BXM2", "X27"])
    }

    func testBusNameCleanup() {
        let nice: [(String, String)] = [
            ("WILLIS AV/E 138 ST", "Willis Av / E 138 St"),
            ("  AV OF THE AMERICAS/W 4TH ST ", "Av of the Americas / W 4th St"),
            ("OF THE BRONX", "Of the Bronx"),
            ("JFK / LIRR\tSTA", "JFK / LIRR Sta"),
            ("A//B", "A / / B"),
            ("A/ /B", "A / / B"),
            ("BED-STUY", "Bed-Stuy"),
            ("W 125TH ST/ADAM C POWELL BL", "W 125th St / Adam C Powell Bl"),
            ("ST. GEORGE FERRY/S BAY", "St. George Ferry / S Bay"),
            ("MAIN ST - 2ND", "Main St - 2nd"),
            ("THE PATH AT 33 ST", "The PATH at 33 St"),
            ("\u{A0}NBSP\u{A0}START", "Nbsp Start"),
            ("21ST-23RD ST", "21st-23rd St"),
            ("\u{DF}TRASSE", "SStrasse"),
        ]
        for (raw, want) in nice { XCTAssertEqual(BusStaticBuilder.nice(raw), want, raw) }
        let headsigns: [(String, String)] = [
            ("+ SELECT BUS EAST HARLEM 126 ST", "East Harlem 126 St"),
            ("limited  FORDHAM  via  WEBSTER", "Fordham"),
            ("LTD ROCKAWAY PARK", "Rockaway Park"),
            ("LTDROCKAWAY", "Ltdrockaway"),
            ("SELECT BUSES", "Select Buses"),
            ("VIA VERDE", "Via Verde"),
            ("FOO VIA", "Foo via"),
            ("EXPRESS", "Express"),
            ("EXPRESS  ", "Express"),
            ("+LIMITED X", "X"),
            ("+ X", "+ X"),
            ("  express   MIDTOWN 57 ST VIA 5 AV", "Midtown 57 St"),
            ("SELECT BUS\tFOO", "Foo"),
            ("\u{17F}elect bus foo", "Foo"),
            ("l\u{131}m\u{131}ted bar", "Bar"),
            ("A\tvia\tB", "A"),
        ]
        for (raw, want) in headsigns { XCTAssertEqual(BusStaticBuilder.headsign(raw), want, raw) }
        let express: [(String, String, Bool)] = [
            ("M15+", "M15-SBS", true), ("Q70", "Q70-SBS", true), ("BxM2", "BxM2", true), ("X27", "X27", true),
            ("BX1", "Bx1", false), ("SIM", "SIM", false), ("SIM1C", "SIM1C", true), ("QM", "QM", false),
            ("B44", "B44-sbs", true), ("bm5", "", true),
        ]
        for (route, short, want) in express { XCTAssertEqual(BusStaticBuilder.isExpress(route, short), want, route) }
    }

    // MARK: Writing the same way as Python

    func testPythonRoundAndRepr() {
        XCTAssertEqual(Py.round(40.0078125, 6), 40.007812)
        XCTAssertEqual(Py.round(40.015625, 5), 40.01562)
        XCTAssertEqual(Py.round(-73.953125, 5), -73.95312)
        XCTAssertEqual(Py.round(2.675, 2), 2.67)
        XCTAssertEqual(Py.round(0.125, 2), 0.12)
        XCTAssertEqual(Py.round(0.375, 2), 0.38)
        XCTAssertEqual(Py.round(40.745630, 5), 40.74563)
        XCTAssertEqual(Py.round(-73.902984, 5), -73.90298)
        XCTAssertEqual(Py.round(-0.000001, 5), 0)
        XCTAssertEqual(Py.round(-0.000001, 5).sign, .minus)
        let reprs: [(Double, String)] = [
            (40.0, "40.0"), (-73.90298, "-73.90298"), (1e-05, "1e-05"), (0.0001, "0.0001"), (1e16, "1e+16"),
            (1e15, "1000000000000000.0"), (123456789012345678.0, "1.2345678901234568e+17"), (-0.0, "-0.0"),
            (1.5e-7, "1.5e-07"), (0.1, "0.1"), (100.0, "100.0"), (1234.5, "1234.5"), (.nan, "NaN"), (-Double.infinity, "-Infinity"),
        ]
        for (x, want) in reprs { XCTAssertEqual(Py.repr(x), want) }
    }

    func testJSONStrings() {
        var j = PyJSON()
        j.string("a\"b\\c\nd\u{1}\t\u{E9}\u{1F600}\u{7F}\u{2028}\u{8}\u{C}\r")
        XCTAssertEqual(j.text, "\"a\\\"b\\\\c\\nd\\u0001\\t\u{E9}\u{1F600}\u{7F}\u{2028}\\b\\f\\r\"")
        var a = PyJSON(asciiOnly: true)
        a.string("a\"b\\c\nd\u{1}\t\u{E9}\u{1F600}\u{7F}\u{2028}\u{8}\u{C}\r")
        XCTAssertEqual(a.text, #""a\"b\\c\nd\u0001\t\u00e9\ud83d\ude00\u007f\u2028\b\f\r""#)
        var n = PyJSON()
        n.string(nil as String?)
        n.bool(true)
        XCTAssertEqual(n.text, "nulltrue")
    }

    // MARK: Versions and checks

    func testIsNewer() {
        XCTAssertTrue(StaticData.isNewer("20260826-X-long-term-supplement-trip-ids", than: "20260813"))
        XCTAssertFalse(StaticData.isNewer("20260813", than: "20260826-X-long-term-supplement-trip-ids"))
        XCTAssertTrue(StaticData.isNewer("20261001", than: "20260826-X-long-term-supplement-trip-ids"))
        XCTAssertTrue(StaticData.isNewer("20260826-Y", than: "20260826-X"), "Same date: compare as strings")
        XCTAssertTrue(StaticData.isNewer("20260826-X-2", than: "20260826-X"))
        XCTAssertFalse(StaticData.isNewer("20260826-X", than: "20260826-X"))
        XCTAssertTrue(StaticData.isNewer("20260826", than: ""))
        XCTAssertFalse(StaticData.isNewer("", than: "20260826"))
        XCTAssertFalse(StaticData.isNewer("zzz", than: "20260826"), "A version not starting with a date is older than one with a date")
        XCTAssertTrue(StaticData.isNewer("20270101", than: "zzz"))
    }

    func testPlausibleStations() throws {
        let old = try StationCatalog.loadBundled()
        let n = old.entries.count
        func catalog(_ entries: [StationCatalog.Entry]) -> StationCatalog { StationCatalog(entries: entries) }
        func renamed(_ e: StationCatalog.Entry, _ i: Int) -> StationCatalog.Entry {
            var e = e
            e.id = "NEW\(i)"
            return e
        }
        XCTAssertTrue(StaticData.plausible(new: old, old: old))
        XCTAssertTrue(StaticData.plausible(new: catalog(Array(old.entries.dropLast(n * 4 / 100))), old: old))
        XCTAssertFalse(StaticData.plausible(new: catalog(Array(old.entries.dropLast(n * 6 / 100))), old: old),
                       "Fewer than 95% of station IDs remain")
        let extra = old.entries.prefix(n * 12 / 100).enumerated().map { renamed($1, $0) }
        XCTAssertFalse(StaticData.plausible(new: catalog(old.entries + extra), old: old), "12% more")
        XCTAssertTrue(StaticData.plausible(new: catalog(old.entries + extra.prefix(n * 8 / 100)), old: old))
        // Same count, but 10% of the IDs changed: with their names and places, the same stations numbered again (kept)
        let swapped = old.entries.enumerated().map { $0 < n / 10 ? renamed($1, $0) : $1 }
        XCTAssertTrue(StaticData.plausible(new: catalog(swapped), old: old))
        // with other names too, other stations
        let replaced = old.entries.enumerated().map { i, e -> StationCatalog.Entry in
            guard i < n / 10 else { return e }
            var e = renamed(e, i)
            e.name = "Other \(i)"
            return e
        }
        XCTAssertFalse(StaticData.plausible(new: catalog(replaced), old: old))
        XCTAssertFalse(StaticData.plausible(new: catalog([]), old: old))
    }

    func testPlausibleBus() throws {
        let old = try BusCatalog.loadBundled()
        let n = old.stops.count
        func catalog(_ stops: [BusCatalog.Stop]) -> BusCatalog { BusCatalog(feedVersion: "", routes: old.routes, stops: stops) }
        XCTAssertTrue(StaticData.plausible(new: old, old: old))
        XCTAssertTrue(StaticData.plausible(new: catalog(Array(old.stops.dropLast(n * 20 / 100))), old: old))
        XCTAssertFalse(StaticData.plausible(new: catalog(Array(old.stops.dropLast(n * 27 / 100))), old: old))
        // Same count, but 35% of the stops changed IDs: with their names and places, numbered again (kept); with other names, not
        let swapped = old.stops.enumerated().map { i, s -> BusCatalog.Stop in
            var s = s
            if i < n * 35 / 100 { s.id = "X\(i)" }
            return s
        }
        XCTAssertTrue(StaticData.plausible(new: catalog(swapped), old: old))
        let replaced = swapped.enumerated().map { i, s -> BusCatalog.Stop in
            var s = s
            if i < n * 35 / 100 { s.name = "Other \(i)" }
            return s
        }
        XCTAssertFalse(StaticData.plausible(new: catalog(replaced), old: old))
        XCTAssertFalse(StaticData.plausible(new: catalog([]), old: old))
    }

    // MARK: Which copy to use when loading

    /// Replaces "feedVersion":"…" in the JSON with another version
    static func withVersion(_ data: Data, _ old: String, _ new: String) -> Data {
        Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"feedVersion\":\"\(old)\"", with: "\"feedVersion\":\"\(new)\"").utf8)
    }

    func useTemporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmt-static-\(UUID().uuidString)")
        StaticData.directory = dir
        addTeardownBlock {
            StaticData.directory = nil
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    func testTramHoursSaveOnlyWhenTheHoursChange() throws {
        _ = useTemporaryDirectory()
        let built = RooseveltIslandTram.builtInHours
        // The bundled hours again, with nothing downloaded: unchanged
        XCTAssertFalse(try RooseveltIslandTram.saveHours(RooseveltIslandTram.Hours(days: built.days, source: "GTFS 1")))
        var later = built.days
        later[0][RooseveltIslandTram.Way.toManhattan.rawValue] = RooseveltIslandTram.Span(first: 6 * 3600, last: 24 * 3600)
        XCTAssertTrue(try RooseveltIslandTram.saveHours(RooseveltIslandTram.Hours(days: later, source: "GTFS 1")))
        XCTAssertEqual(RooseveltIslandTram.loadCurrentHours().days, later)
        // Same hours from a newer data version: unchanged
        XCTAssertFalse(try RooseveltIslandTram.saveHours(RooseveltIslandTram.Hours(days: later, source: "GTFS 2")))
        // Back to the bundled hours: changed once, then unchanged
        XCTAssertTrue(try RooseveltIslandTram.saveHours(built))
        XCTAssertEqual(RooseveltIslandTram.loadCurrentHours().days, built.days)
        XCTAssertFalse(try RooseveltIslandTram.saveHours(built))
    }

    /// Hoyt-Schermerhorn Sts: the southbound "Queens" sign is for the A; the C and G stay in Brooklyn and say where they go
    func testStationLabelsFitTheRoute() throws {
        let c = try StationCatalog.loadBundled()
        XCTAssertEqual(c.direction(stationID: "A42", route: "A", code: "S").name, "Queens")
        XCTAssertEqual(c.direction(stationID: "A42", route: "C", code: "S").name, "To Euclid Av")
        XCTAssertEqual(c.direction(stationID: "A42", route: "G", code: "S").name, "To Church Av")
    }

    /// The monthly rebuild takes labels from the app's own list first, and from the list in use only for stations the app doesn't have
    func testRebuildTakesLabelsFromTheAppFirst() throws {
        let bundled = try StationCatalog.loadBundled()
        var old = try XCTUnwrap(bundled.entry(id: "A42"))
        old.southLabel = "Brooklyn"
        let added = StationCatalog.Entry(id: "Z99", name: "New Station", lat: 40.7, lon: -73.9, routes: [], northLabel: "Uptown")
        let current = StationCatalog(entries: [old, added])
        let source = try XCTUnwrap(StationCatalog.labelSource(current: current))
        XCTAssertEqual(source.entry(id: "A42")?.southLabel, "Queens")
        XCTAssertEqual(source.entry(id: "Z99")?.northLabel, "Uptown")
        XCTAssertEqual(StationCatalog.labelSource(current: nil)?.entries.count, bundled.entries.count)
    }

    func testSaveNeedsDirectory() throws {
        StaticData.directory = nil
        XCTAssertThrowsError(try StaticData.save(Data("{}".utf8), as: StaticData.stationsFile))
        let dir = useTemporaryDirectory()
        try StaticData.save(Data("{}".utf8), as: StaticData.stationsFile)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(StaticData.stationsFile)), Data("{}".utf8))
    }

    func testStationsLoadCurrent() throws {
        _ = useTemporaryDirectory()
        let bundled = try StationCatalog.loadBundled()
        let json = try XCTUnwrap(StaticData.bundledData("subway_stations"))
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, bundled.feedVersion, "No downloaded file")

        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20200101-old"), as: StaticData.stationsFile)
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, bundled.feedVersion, "Downloaded is older than bundled")

        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20991231-new"), as: StaticData.stationsFile)
        let current = try StationCatalog.loadCurrent()
        XCTAssertEqual(current.feedVersion, "20991231-new", "Downloaded is newer")
        XCTAssertEqual(current.entries, bundled.entries)

        try StaticData.save(Data("{\"feedVersion\":\"20991231\",".utf8), as: StaticData.stationsFile)
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, bundled.feedVersion, "Downloaded file is corrupt")
    }

    func testExpressFollowsStations() throws {
        _ = useTemporaryDirectory()
        let bundled = try StationCatalog.loadBundled()
        let json = try XCTUnwrap(StaticData.bundledData("subway_stations"))
        try StaticData.save(Data(#"{"712N":["999"]}"#.utf8), as: StaticData.expressFile)
        func usesDownloaded() throws -> Bool {
            let e = try ExpressStops.loadCurrent()
            XCTAssertNotEqual(e.skips(from: "712", direction: "N", to: "999"), e.skips(from: "712", direction: "N", to: "707"))
            return e.skips(from: "712", direction: "N", to: "999")
        }
        XCTAssertFalse(try usesDownloaded(), "No downloaded station catalog")
        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20200101-old"), as: StaticData.stationsFile)
        XCTAssertFalse(try usesDownloaded(), "Downloaded station catalog is older than bundled")
        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20991231-new"), as: StaticData.stationsFile)
        XCTAssertTrue(try usesDownloaded(), "Using the downloaded station catalog")
        try StaticData.save(Data("[1,2".utf8), as: StaticData.expressFile)
        XCTAssertFalse(try usesDownloaded(), "Downloaded express data is corrupt")
        try StaticData.save(Data("garbage".utf8), as: StaticData.stationsFile)
        try StaticData.save(Data(#"{"712N":["999"]}"#.utf8), as: StaticData.expressFile)
        XCTAssertFalse(try usesDownloaded(), "Downloaded station catalog is corrupt")
    }

    func testBusLoadCurrent() throws {
        _ = useTemporaryDirectory()
        let bundled = try BusCatalog.loadBundled()
        let json = try XCTUnwrap(StaticData.bundledData("bus_stops"))
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, bundled.feedVersion)
        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20200101"), as: StaticData.busStopsFile)
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, bundled.feedVersion, "Downloaded is older than bundled")
        try StaticData.save(Self.withVersion(json, bundled.feedVersion, "20991231"), as: StaticData.busStopsFile)
        let current = try BusCatalog.loadCurrent()
        XCTAssertEqual(current.feedVersion, "20991231", "Downloaded is newer")
        XCTAssertEqual(current.stops.count, bundled.stops.count)
        try StaticData.save(Data("{\"routes\":".utf8), as: StaticData.busStopsFile)
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, bundled.feedVersion, "Downloaded file is corrupt")
    }

    // MARK: Saving after the monthly check

    /// Keeps only the first `keep` items of a list in the JSON (e.g. many stations missing)
    static func truncated(_ data: Data, list key: String, keep: (Int) -> Int) throws -> Data {
        var doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(doc[key] as? [Any])
        doc[key] = Array(items.prefix(keep(items.count)))
        return try JSONSerialization.data(withJSONObject: doc)
    }

    func testSaveSubwayRules() throws {
        let dir = useTemporaryDirectory()
        let fm = FileManager.default
        let stationsPath = dir.appendingPathComponent(StaticData.stationsFile).path
        let expressPath = dir.appendingPathComponent(StaticData.expressFile).path
        let bundled = try StationCatalog.loadBundled()
        let json = try XCTUnwrap(StaticData.bundledData("subway_stations"))
        let express = try XCTUnwrap(StaticData.bundledData("express_stops"))

        // Same version as the bundled one: don't save
        XCTAssertEqual(try StaticData.saveSubway(stations: json, express: express), .notNewer)
        XCTAssertFalse(fm.fileExists(atPath: stationsPath))
        XCTAssertFalse(fm.fileExists(atPath: expressPath))

        // MTA has a new version: switch to it; express data follows the station catalog
        let newer = Self.withVersion(json, bundled.feedVersion, "20991231-new")
        let newExpress = Data(#"{"712N":["999"]}"#.utf8)
        XCTAssertEqual(try StaticData.saveSubway(stations: newer, express: newExpress), .saved)
        let current = try StationCatalog.loadCurrent()
        XCTAssertEqual(current.feedVersion, "20991231-new")
        XCTAssertTrue(try ExpressStops.loadCurrent(for: current).skips(from: "712", direction: "N", to: "999"))
        XCTAssertTrue(try ExpressStops.loadCurrent().skips(from: "712", direction: "N", to: "999"))
        XCTAssertFalse(try ExpressStops.loadCurrent(for: bundled).skips(from: "712", direction: "N", to: "999"),
                       "Bundled station catalog pairs with bundled express data")

        // Next month it's still the same copy
        XCTAssertEqual(try StaticData.saveSubway(stations: newer, express: newExpress), .unchanged)

        // Many stations missing (a download or MTA data problem): don't switch
        let fewer = try Self.truncated(Self.withVersion(json, bundled.feedVersion, "20991231-z"), list: "stations") { $0 * 8 / 10 }
        XCTAssertEqual(try StaticData.saveSubway(stations: fewer, express: newExpress), .implausible)
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, "20991231-new")

        // Bad data: don't save
        XCTAssertThrowsError(try StaticData.saveSubway(stations: Data("{".utf8), express: express))
        XCTAssertThrowsError(try StaticData.saveSubway(stations: Self.withVersion(json, bundled.feedVersion, "20991231-zz"),
                                                       express: Data("[".utf8)))
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, "20991231-new")

        // A version that doesn't start with a date can't be compared: nothing saved, the newer download stays in use
        XCTAssertEqual(try StaticData.saveSubway(stations: Self.withVersion(json, bundled.feedVersion, "v2-spring"), express: express),
                       .unknownVersion)
        XCTAssertTrue(fm.fileExists(atPath: stationsPath))
        XCTAssertTrue(fm.fileExists(atPath: expressPath))
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, "20991231-new")

        // MTA's data isn't newer than the bundled data (e.g. a new app version with updated data was installed): delete the download and use the bundled data
        XCTAssertEqual(try StaticData.saveSubway(stations: Self.withVersion(json, bundled.feedVersion, "20200101-old"),
                                                 express: express), .notNewer)
        XCTAssertFalse(fm.fileExists(atPath: stationsPath))
        XCTAssertFalse(fm.fileExists(atPath: expressPath))
        XCTAssertEqual(try StationCatalog.loadCurrent().feedVersion, bundled.feedVersion)

        // No shared folder (it can't be used): can't save
        StaticData.directory = nil
        XCTAssertThrowsError(try StaticData.saveSubway(stations: newer, express: newExpress))
    }

    func testSaveBusRules() throws {
        let dir = useTemporaryDirectory()
        let path = dir.appendingPathComponent(StaticData.busStopsFile).path
        let bundled = try BusCatalog.loadBundled()
        let json = try XCTUnwrap(StaticData.bundledData("bus_stops"))

        XCTAssertEqual(try StaticData.saveBus(stops: json), .notNewer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        let newer = Self.withVersion(json, bundled.feedVersion, "20991231")
        XCTAssertEqual(try StaticData.saveBus(stops: newer), .saved)
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, "20991231")
        XCTAssertEqual(try StaticData.saveBus(stops: newer), .unchanged)
        XCTAssertEqual(try StaticData.saveBus(stops: Self.withVersion(json, bundled.feedVersion, "spring")), .unknownVersion)
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, "20991231")

        let half = try Self.truncated(Self.withVersion(json, bundled.feedVersion, "20991232"), list: "stops") { $0 / 2 }
        XCTAssertEqual(try StaticData.saveBus(stops: half), .implausible)
        XCTAssertEqual(try BusCatalog.loadCurrent().stops.count, bundled.stops.count)

        XCTAssertThrowsError(try StaticData.saveBus(stops: Data("[]".utf8)))
        XCTAssertEqual(try StaticData.saveBus(stops: Self.withVersion(json, bundled.feedVersion, "20200101")), .notNewer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try BusCatalog.loadCurrent().feedVersion, bundled.feedVersion)
    }

    // MARK: Reading inside a zip while decompressing (macOS only)

    #if canImport(Compression)
    /// Builds a ZIP (method 0 stored, 8 deflate), with each file's CRC-32 (ZipReader checks it).
    static func makeZip(_ files: [(String, Data)], method: Int) throws -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int, _ d: inout Data) { u16(v & 0xFFFF, &d); u16((v >> 16) & 0xFFFF, &d) }
        for (name, content) in files {
            var body = content
            if method == 8 {
                var dst = [UInt8](repeating: 0, count: content.count + 1024)
                let src = [UInt8](content)
                let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
                XCTAssertGreaterThan(n, 0)
                body = Data(dst.prefix(n))
            }
            var checksum = ZipReader.Checksum()
            checksum.add(content)
            let crc = Int(checksum.value)
            let nameBytes = Data(name.utf8)
            let offset = out.count
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(method, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(body.count, &out); u32(content.count, &out); u16(nameBytes.count, &out); u16(0, &out)
            out.append(nameBytes)
            out.append(body)
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(method, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central); u32(body.count, &central); u32(content.count, &central)
            u16(nameBytes.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central.append(nameBytes)
        }
        let cdOffset = out.count
        out.append(central)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(central.count, &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }
    #endif

    func testZipStreamMatchesExtract() throws {
        #if canImport(Compression)
        let zip = try XCTUnwrap(Data(base64Encoded: ZipReaderTests.fixture))
        let all = try ZipReader.extract(zip)
        for name in ["calendar.txt", "trips.txt", "stored.txt"] {
            var streamed = Data()
            try ZipReader.stream(zip, name: name) { streamed.append($0) }
            XCTAssertEqual(streamed, all[name], name)
        }
        XCTAssertThrowsError(try ZipReader.stream(zip, name: "missing.txt") { _ in }) { error in
            XCTAssertEqual(error as? TimetableError, .missingFile("missing.txt"))
        }
        var rows: [String?] = []
        try ZipReader.forEachRow(zip, name: "trips.txt") { col in rows.append(col("trip_id")) }
        XCTAssertEqual(rows, ["T1"])

        // Large file: decompresses into several chunks, with rows split across chunks
        let count = 150_000
        var text = "trip_id,stop_id,stop_sequence\r\n"
        for i in 0..<count { text += "T\(i / 40)-Weekday,\(100 + i % 40)N,\(i % 40 + 1)\r\n" }
        let big = Data(text.utf8)
        for method in [0, 8] {
            let z = try Self.makeZip([("readme.txt", Data("x".utf8)), ("gtfs/stop_times.txt", big)], method: method)
            XCTAssertEqual(try ZipReader.extract(z)["stop_times.txt"], big)
            var chunks: [Data] = []
            try ZipReader.stream(z, name: "stop_times.txt") { chunks.append($0) }
            XCTAssertGreaterThan(chunks.count, 2)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= 1 << 20 })
            XCTAssertEqual(chunks.reduce(Data(), +), big)
            var n = 0
            try ZipReader.forEachRow(z, name: "stop_times.txt") { col in
                if col("trip_id") != "T\(n / 40)-Weekday" || col("stop_id") != "\(100 + n % 40)N"
                    || col("stop_sequence") != "\(n % 40 + 1)" { XCTFail("row \(n)") }
                n += 1
            }
            XCTAssertEqual(n, count)
        }
        // Incomplete data
        let z = try Self.makeZip([("stop_times.txt", big)], method: 8)
        var cut = z
        cut.replaceSubrange(40..<80, with: Data(repeating: 0xFF, count: 40))
        XCTAssertThrowsError(try ZipReader.stream(cut, name: "stop_times.txt") { _ in })
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    func testZipReadMatchesExtract() throws {
        #if canImport(Compression)
        let zip = try XCTUnwrap(Data(base64Encoded: ZipReaderTests.fixture))
        let all = try ZipReader.extract(zip)
        let read = try ZipReader.read(zip, names: ["calendar.txt", "stored.txt", "missing.txt", "trips.txt"])
        XCTAssertEqual(Set(read.keys), ["calendar.txt", "stored.txt", "trips.txt"], "Missing files aren't put in the result")
        for (name, data) in read { XCTAssertEqual(data, all[name], name) }
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    /// The subway map needs northbound (.N) shapes
    static let refreshRoutes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color
    7,MTA NYCT,7,Flushing Local,1,B933AD
    A,MTA NYCT,A,8 Avenue Express,1,0039A6

    """
    static let refreshShapes = """
    shape_id,shape_pt_sequence,shape_pt_lat,shape_pt_lon
    7..N1,0,40.755882,-74.00191
    7..N1,1,40.74563,-73.902984
    7..N1,2,40.7596,-73.83003
    7..S1,0,40.7596,-73.83003
    7..S1,1,40.755882,-74.00191

    """

    /// What the app generates from the zip during the monthly check (StaticRefresh) matches what's generated from the unzipped files.
    func testSubwayRefreshFromZip() throws {
        #if canImport(Compression)
        let trips = Self.subwayTrips
            .replacingOccurrences(of: "7,T1,W,Flushing-Main St,0,s", with: "7,T1,W,Flushing-Main St,0,7..N1")
            .replacingOccurrences(of: "7,T2,W,34 St-Hudson Yards,1,s", with: "7,T2,W,34 St-Hudson Yards,1,7..S1")
        let files: [(String, Data)] = [
            ("routes.txt", Data(Self.refreshRoutes.utf8)), ("trips.txt", Data(trips.utf8)),
            ("shapes.txt", Data(Self.refreshShapes.utf8)), ("stops.txt", Data(Self.subwayStops.utf8)),
            ("stop_times.txt", Data(Self.subwayStopTimes.utf8)), ("feed_info.txt", Data(Self.subwayFeedInfo.utf8)),
        ]
        let expectedMap = try SubwayMapBuilder.build(files: Dictionary(uniqueKeysWithValues: files))
        XCTAssertEqual(expectedMap.routes.map(\.route), ["7"])
        for method in [0, 8] {
            // In MTA's zip the files are at the top level; they can also be read inside a folder
            let zip = try Self.makeZip(files.map { ("gtfs_subway/" + $0.0, $0.1) }, method: method)
            let r = try StaticRefresh.subway(zip: zip, labelsFrom: Self.labels)
            XCTAssertEqual(r.map, expectedMap)
            XCTAssertEqual(String(decoding: r.stations, as: UTF8.self), Self.expectedStations)
            XCTAssertEqual(String(decoding: r.express, as: UTF8.self), Self.expectedExpress)
        }
        // Missing file: error (never generates partial data)
        for missing in ["stop_times.txt", "stops.txt", "shapes.txt"] {
            let zip = try Self.makeZip(files.filter { $0.0 != missing }, method: 8)
            XCTAssertThrowsError(try StaticRefresh.subway(zip: zip, labelsFrom: Self.labels), missing)
        }
        XCTAssertThrowsError(try StaticRefresh.subway(zip: Data("not a zip".utf8), labelsFrom: nil))
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    func testBusRefreshFromZips() throws {
        #if canImport(Compression)
        func files(_ list: [String], shapes: String, crlf: Bool) -> [(String, Data)] {
            func data(_ s: String) -> Data { Data((crlf ? s.replacingOccurrences(of: "\n", with: "\r\n") : s).utf8) }
            return zip(["routes.txt", "stops.txt", "trips.txt", "stop_times.txt", "feed_info.txt"], list).map { ($0, data($1)) }
                + [("shapes.txt", data(shapes))]
        }
        let trips1 = Self.bus1Trips.replacingOccurrences(of: "BX1,S,t1,MOTT HAVEN 138 ST via 3 AV,0,,",
                                                         with: "BX1,S,t1,MOTT HAVEN 138 ST via 3 AV,0,,BX10001")
        let feed1 = files([Self.bus1Routes, Self.bus1Stops, trips1, Self.bus1StopTimes, Self.bus1FeedInfo],
                          shapes: "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nBX10001,40.8,-73.9,1\nBX10001,40.9,-73.9,2\n",
                          crlf: false)
        let feed2 = files([Self.bus2Routes, Self.bus2Stops, Self.bus2Trips, Self.bus2StopTimes, Self.bus2FeedInfo],
                          shapes: "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n", crlf: true)
        var expectedMap = BusMapBuilder()
        try expectedMap.add(files: Dictionary(uniqueKeysWithValues: feed1))
        try expectedMap.add(files: Dictionary(uniqueKeysWithValues: feed2))

        let refresh = StaticRefresh.Bus()
        try refresh.add(zip: Self.makeZip(feed1, method: 8))
        try refresh.add(zip: Self.makeZip(feed2, method: 0))
        let (map, stops) = try refresh.finish()
        XCTAssertEqual(map, try expectedMap.build())
        XCTAssertEqual(map.routes.map(\.route), ["BX1"])
        XCTAssertEqual(String(decoding: stops, as: UTF8.self), Self.expectedBus)

        // Missing stop_times.txt: error
        XCTAssertThrowsError(try StaticRefresh.Bus().add(zip: Self.makeZip(feed1.filter { $0.0 != "stop_times.txt" }, method: 8)))
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    // MARK: Generate from full MTA data and compare with the bundled files

    /// Reads files in chunks (1 MB at a time), like the app reading from a zip while decompressing.
    static func feedFile(_ url: URL, into reader: GTFSRowReader) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try reader.feed(chunk) }
        try reader.finish()
    }

    /// CMT_GTFS_DIR: the unzipped gtfs_subway, the same version as the bundled files (feedVersion in subway_stations.json).
    func testSubwayFeedMatchesBundledFiles() throws {
        guard let path = ProcessInfo.processInfo.environment["CMT_GTFS_DIR"] else {
            throw XCTSkip("CMT_GTFS_DIR is not set")
        }
        let dir = URL(fileURLWithPath: path)
        let bundled = try StationCatalog.loadBundled()
        let start = Date()
        let b = try SubwayStaticBuilder(stops: Data(contentsOf: dir.appendingPathComponent("stops.txt")),
                                        trips: Data(contentsOf: dir.appendingPathComponent("trips.txt")),
                                        feedInfo: try? Data(contentsOf: dir.appendingPathComponent("feed_info.txt")),
                                        labelsFrom: bundled)
        try Self.feedFile(dir.appendingPathComponent("stop_times.txt"), into: GTFSRowReader { b.addStopTimeRow($0) })
        let stations = try b.stationsJSON()
        let express = try b.expressJSON()
        print("subway static build seconds:", Date().timeIntervalSince(start))

        XCTAssertEqual(b.feedVersion, bundled.feedVersion)
        let built = try StationCatalog.decode(stations)
        XCTAssertEqual(built.feedVersion, bundled.feedVersion)
        XCTAssertEqual(built.entries.count, bundled.entries.count)
        XCTAssertEqual(built.entries, bundled.entries)
        for (a, e) in zip(built.entries, bundled.entries) where a != e { XCTFail("station \(a.id) differs") }
        let decode = { (d: Data) in try JSONDecoder().decode([String: [String]].self, from: d) }
        XCTAssertEqual(try decode(express), try decode(XCTUnwrap(StaticData.bundledData("express_stops"))))
        // Byte-for-byte identical
        XCTAssertEqual(stations, StaticData.bundledData("subway_stations"))
        XCTAssertEqual(express, StaticData.bundledData("express_stops"))
    }

    /// CMT_BUS_GTFS_DIR: one subfolder per feed (bx, b, m, q, si, busco), containing the unzipped files.
    func testBusFeedsMatchBundledFile() throws {
        guard let path = ProcessInfo.processInfo.environment["CMT_BUS_GTFS_DIR"] else {
            throw XCTSkip("CMT_BUS_GTFS_DIR is not set")
        }
        let root = URL(fileURLWithPath: path)
        // Same order as BusMap.sourceURLs
        let feeds = BusMap.sourceURLs.map { $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "gtfs_", with: "") }
        XCTAssertEqual(feeds, ["bx", "b", "m", "q", "si", "busco"])
        let start = Date()
        let b = BusStaticBuilder()
        for feed in feeds {
            let dir = root.appendingPathComponent(feed)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("stop_times.txt").path) else {
                throw XCTSkip("\(feed) is missing from CMT_BUS_GTFS_DIR")
            }
            try b.beginFeed(routes: Data(contentsOf: dir.appendingPathComponent("routes.txt")),
                            stops: Data(contentsOf: dir.appendingPathComponent("stops.txt")),
                            trips: Data(contentsOf: dir.appendingPathComponent("trips.txt")),
                            feedInfo: try? Data(contentsOf: dir.appendingPathComponent("feed_info.txt")))
            try Self.feedFile(dir.appendingPathComponent("stop_times.txt"), into: GTFSRowReader { b.addStopTimeRow($0) })
            b.endFeed()
        }
        let data = try b.stopsJSON()
        print("bus static build seconds:", Date().timeIntervalSince(start))

        let built = try BusCatalog.decode(data)
        let bundled = try BusCatalog.loadBundled()
        XCTAssertEqual(built.feedVersion, bundled.feedVersion)
        XCTAssertEqual(built.routes, bundled.routes)
        XCTAssertEqual(built.stops.count, bundled.stops.count)
        for (a, e) in zip(built.stops, bundled.stops) {
            guard a.id == e.id, a.name == e.name, a.routeDirections == e.routeDirections,
                  abs(a.lat - e.lat) <= 1e-9, abs(a.lon - e.lon) <= 1e-9 else {
                XCTFail("stop \(a.id) / \(e.id) differs")
                break
            }
        }
        XCTAssertEqual(data, StaticData.bundledData("bus_stops"), "Byte-for-byte identical")
    }

    /// CMT_ZIP_DIR: gtfs_subway.zip and the 6 bus feeds (gtfs_bx.zip …) downloaded from MTA, not unzipped.
    /// Generates from the zips like the app's monthly check (reading while decompressing): the result must match generating from fully unzipped files;
    /// when MTA's version matches the bundled one, it must also be byte-for-byte identical to the bundled files.
    func testRefreshFromRealZips() throws {
        #if canImport(Compression)
        guard let path = ProcessInfo.processInfo.environment["CMT_ZIP_DIR"] else {
            throw XCTSkip("CMT_ZIP_DIR is not set")
        }
        let dir = URL(fileURLWithPath: path)
        let bundled = try StationCatalog.loadBundled()
        let zip = try Data(contentsOf: dir.appendingPathComponent("gtfs_subway.zip"))
        var start = Date()
        let r = try StaticRefresh.subway(zip: zip, labelsFrom: bundled)
        print("subway refresh seconds:", Date().timeIntervalSince(start))
        let files = try ZipReader.extract(zip, names: ["routes.txt", "trips.txt", "shapes.txt", "stops.txt",
                                                       "feed_info.txt", "stop_times.txt"])
        XCTAssertEqual(r.map, try SubwayMapBuilder.build(files: files))
        let b = try SubwayStaticBuilder(stops: try XCTUnwrap(files["stops.txt"]), trips: try XCTUnwrap(files["trips.txt"]),
                                        feedInfo: files["feed_info.txt"], labelsFrom: bundled)
        try TimetableBuilder.forEachRow(try XCTUnwrap(files["stop_times.txt"])) { b.addStopTimeRow($0) }
        XCTAssertEqual(r.stations, try b.stationsJSON())
        XCTAssertEqual(r.express, try b.expressJSON())
        let stations = try StationCatalog.decode(r.stations)
        XCTAssertTrue(StaticData.plausible(new: stations, old: bundled))
        _ = try ExpressStops.decode(r.express)
        print("subway feed:", stations.feedVersion, "stations:", stations.entries.count, "built-in:", bundled.feedVersion)
        if stations.feedVersion == bundled.feedVersion {
            XCTAssertEqual(r.stations, StaticData.bundledData("subway_stations"), "Byte-for-byte identical")
            XCTAssertEqual(r.express, StaticData.bundledData("express_stops"), "Byte-for-byte identical")
            Self.assertSameMap(r.map, try SubwayMap.loadBundled())
        }

        start = Date()
        let refresh = StaticRefresh.Bus()
        for url in BusMap.sourceURLs {
            try refresh.add(zip: Data(contentsOf: dir.appendingPathComponent(url.lastPathComponent)))
        }
        let (busMap, stops) = try refresh.finish()
        print("bus refresh seconds:", Date().timeIntervalSince(start))
        let bus = try BusCatalog.decode(stops)
        let bundledBus = try BusCatalog.loadBundled()
        XCTAssertTrue(StaticData.plausible(new: bus, old: bundledBus))
        print("bus feed:", bus.feedVersion, "stops:", bus.stops.count, "built-in:", bundledBus.feedVersion)
        if bus.feedVersion == bundledBus.feedVersion {
            XCTAssertEqual(stops, StaticData.bundledData("bus_stops"), "Byte-for-byte identical")
            Self.assertSameMap(busMap, try BusMap.loadBundled())
        }
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    /// Map matches the bundled one: Python and Swift round the 5th decimal slightly differently, so coordinates may differ by 0.00001
    /// (same as SubwayMapTests.testBuilderMatchesBundledFile).
    static func assertSameMap(_ built: SubwayMap, _ bundled: SubwayMap, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(built.feedVersion, bundled.feedVersion, file: file, line: line)
        XCTAssertEqual(built.stations.map(\.id), bundled.stations.map(\.id), file: file, line: line)
        for (a, b) in zip(built.stations, bundled.stations) {
            XCTAssertEqual(a.lat, b.lat, accuracy: 0.0000101, file: file, line: line)
            XCTAssertEqual(a.lon, b.lon, accuracy: 0.0000101, file: file, line: line)
        }
        XCTAssertEqual(built.routes.map(\.route), bundled.routes.map(\.route), file: file, line: line)
        XCTAssertEqual(built.routes.map(\.color), bundled.routes.map(\.color), file: file, line: line)
        XCTAssertEqual(built.routes.map { $0.lines.map(\.count) }, bundled.routes.map { $0.lines.map(\.count) },
                       file: file, line: line)
        var worst = 0.0
        for (a, b) in zip(built.routes, bundled.routes) {
            for (la, lb) in zip(a.lines, b.lines) {
                for (pa, pb) in zip(la, lb) {
                    for (x, y) in zip(pa, pb) { worst = max(worst, abs(x - y)) }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.0000101, "Route coordinates", file: file, line: line)
    }

    /// The bundled subway data is only a fallback (the app downloads new data each month), but a new version should not ship with
    /// data that has already ended. Reported as a skip, so a build still installs; refresh it with tools/generate_stations.py.
    func testBundledSubwayDataHasNotEnded() throws {
        let json = try XCTUnwrap(StaticData.bundledData("subway_stations"))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let end = try XCTUnwrap(doc["feedEndDate"] as? String)
        XCTAssertEqual(end.count, 8)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyyMMdd"
        let today = f.string(from: Date())
        if end < today { throw XCTSkip("The bundled subway data ended on \(end); refresh it before publishing a version") }
    }
}

extension StaticDataTests {
    // MARK: Fixtures
    // expected… are the files the scripts in tools/ generate for the same input (generate_stations.py's FILL looked up by station ID).


    static let subwayStops = #"""
    stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
    701,Flushing-Main St,40.7596,-73.83003,1,
    701N,Flushing-Main St,40.7596,-73.83003,,701
    701S,Flushing-Main St,40.7596,-73.83003,,701
    710,52 St,40.0078125,-73.0078125,1,
    710N,52 St,40.744149,-73.912549,,710
    710S,52 St,40.744149,-73.912549,,710
    712,61 St-Woodside,40.74563,-73.902984,1,
    712N,61 St-Woodside,40.74563,-73.902984,,712
    712S,61 St-Woodside,40.74563,-73.902984,,712
    726,34 St-Hudson Yards,40.755882,-74.00191,1,
    726N,34 St-Hudson Yards,40.755882,-74.00191,,726
    726S,34 St-Hudson Yards,40.755882,-74.00191,,726
    A24,59 St–Columbus C\#u{ED}rcle \ x,40.768296,-73.981736,1,
    A24N,59 St–Columbus C\#u{ED}rcle \ x,40.768296,-73.981736,,A24
    A24S,59 St–Columbus C\#u{ED}rcle \ x,40.768296,-73.981736,,A24
    999,Ghost,40.1,-73.1,1,
    """#

    static let subwayTrips = #"""
    route_id,trip_id,service_id,trip_headsign,direction_id,shape_id
    7,T1,W,Flushing-Main St,0,s
    7,T2,W,34 St-Hudson Yards,1,s
    7,T3,W,"Flushing, Main St",0,s
    7X,T4,W,34 St-Hudson Yards,1,s
    7,T5,W,61 St-Woodside,1,s
    7,T6,W,34 St-Hudson Yards,1,s
    A,T7,W,Inwood-207 St,0,s
    A,T8,W,Far Rockaway,1,s
    A,T9,W,Lefferts Blvd,1,s
    """#

    static let subwayStopTimes = #"""
    trip_id,stop_id,arrival_time,departure_time,stop_sequence
    T1,726N,08:00:00,08:00:00,1
    T1,712N,08:10:00,08:10:00,2
    T1,701N,08:20:00,08:20:00,3
    T2,701S,08:00:00,08:00:00,1
    T2,710S,08:08:00,08:08:00,2
    T2,712S,08:10:00,08:10:00,3
    T2,726S,08:30:00,08:30:00,4
    T3,726N,09:00:00,09:00:00,1
    T3,712N,09:10:00,09:10:00,2
    T3,701N,09:20:00,09:20:00,3
    T4,701S,08:05:00,08:05:00,1
    T4,710S,08:12:00,08:12:00,2
    T4,726S,08:30:00,08:30:00,3
    T5,701S,09:00:00,09:00:00,1
    T5,710S,09:08:00,09:08:00,2
    T5,712S,09:10:00,09:10:00,3
    T6,701S,10:00:00,10:00:00,1
    T6,710S,10:08:00,10:08:00,2
    T6,712S,10:10:00,10:10:00,3
    T6,726S,10:30:00,10:30:00,4
    T7,A24S,08:00:00,08:00:00,1
    T7,A24N,08:01:00,08:01:00,2
    T8,A24S,08:00:00,08:00:00,1
    T9,A24S,08:10:00,08:10:00,1
    T8,701,08:20:00,08:20:00,2
    TX,712N,08:00:00,08:00:00,1
    E1,101S,08:00:00,08:00:00,1
    E1,104S,08:05:00,08:05:00,2
    E1,106S,08:07:00,08:07:00,3
    L1,101S,08:00:00,08:00:00,1
    L1,103S,08:02:00,08:02:00,2
    L1,104S,08:05:00,08:05:00,3
    L1,106S,08:07:00,08:07:00,4
    L2,106N,08:00:00,08:00:00,1
    L2,104N,08:02:00,08:02:00,2
    L2,103N,08:05:00,08:05:00,3
    L2,101N,08:07:00,08:07:00,4
    E2,106N,08:00:00,08:00:00,1
    E2,104N,08:02:00,08:02:00,2
    E2,101N,08:07:00,08:07:00,3
    E3,106S,08:07:00,08:07:00,3
    E3,101S,08:00:00,08:00:00,1
    E3,104S,08:05:00,08:05:00,2
    Q1,201N,08:00:00,08:00:00,1
    Q1,203N,08:02:00,08:02:00,2
    Q1,202N,08:02:00,08:02:00,2
    Q2,201N,08:00:00,08:00:00,1
    Q2,203N,08:02:00,08:02:00,2
    U1,\#u{C4}1S,08:00:00,08:00:00,1
    U1,\#u{C4}3S,08:02:00,08:02:00,2
    U2,\#u{C4}1S,08:00:00,08:00:00,1
    U2,\#u{C4}2S,08:01:00,08:01:00,2
    U2,\#u{C4}3S,08:02:00,08:02:00,3
    """#

    static let subwayFeedInfo = #"""
    feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version
    MTA New York City Transit,https://www.mta.info/,EN,20261001,20261231,20260901-X-test
    """#

    static let bus1Routes = #"""
    route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_color,route_text_color
    BX1,MTA NYCT,Bx1,Riverdale - Mott Haven,,3,00aeef,FFFFFF
    M15+,MTA NYCT,M15-SBS,"East Harlem - South Ferry",,3,,FFFFFF
    X27,MTA NYCT,X27,Bay Ridge - Midtown,,3,EE352E,FFFFFF
    Q99,MTA NYCT,Q99,No Trips,,3,123456,FFFFFF
    B44,MTA NYCT,,Bed-Stuy,,3,,FFFFFF
    BXM2,MTA NYCT,BxM2,Riverdale - Midtown,,3,,FFFFFF
    """#

    static let bus1Stops = #"""
    stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station
    100,"WILLIS AV/E 138 ST",,  40.015625, -73.953125,,,0,
    101,"AV OF THE AMERICAS/W 4TH ST",,40.7311,-73.99993,,,0,
    102,"JFK AIRPORT TERMINAL 4 / LIRR STA",,40.6447,-73.7822,,,0,
    103,"BED-STUY  /  FULTON ST - NOSTRAND AV",,40.6811,-73.9503,,,0,
    104,"OF THE BRONX",,40.80001,-73.90001,,,0,
    105,UNUSED STOP,,40.5,-73.5,,,0,
    106,"ONLY ZZ9",,40.6,-73.6,,,0,
    107,"ENTRANCE NODE",,,,,,3,
    108,"BAD COORDINATES",,north,-73.5,,,0,
    """#

    static let bus1Trips = #"""
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    BX1,S,t1,MOTT HAVEN 138 ST via 3 AV,0,,
    BX1,S,t2,LIMITED MOTT HAVEN 138 ST,0,,
    BX1,S,t3,RIVERDALE W 263 ST,1,,
    BX1,S,t4,"RIVERDALE  VIA  BROADWAY",1,,
    M15+,S,t5,SELECT BUS SOUTH FERRY via 2 AV,0,,
    M15+,S,t6,+ SELECT BUS EAST HARLEM 126 ST,1,,
    X27,S,t7,EXPRESS MIDTOWN via 57 ST,,,
    X27,S,t8,BAY RIDGE,1,,
    B44,S,t9,select bus williamsburg,0,,
    ZZ9,S,t10,NOWHERE,0,,
    BXM2,S,t11,,0,,
    """#

    static let bus1StopTimes = #"""
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,timepoint
    t1,08:00:00,08:00:00,100,1,0,0,1
    t1,08:01:00,08:01:00,101,2,0,0,1
    t2,08:00:00,08:00:00,100,1,0,0,1
    t3,08:00:00,08:00:00,101,1,0,0,1
    t3,08:01:00,08:01:00,100,2,0,0,1
    t4,08:00:00,08:00:00,102,1,0,0,1
    t5,08:00:00,08:00:00,101,1,0,0,1
    t5,08:01:00,08:01:00,103,2,0,0,1
    t6,08:00:00,08:00:00,103,1,0,0,1
    t7,08:00:00,08:00:00,102,1,0,0,1
    t8,08:00:00,08:00:00,104,1,0,0,1
    t9,08:00:00,08:00:00,104,1,0,0,1
    t10,08:00:00,08:00:00,106,1,0,0,1
    t11,08:00:00,08:00:00,102,1,0,0,1
    tX,08:00:00,08:00:00,105,1,0,0,1
    t1,08:02:00,08:02:00,107,3,0,0,1
    """#

    static let bus1FeedInfo = #"""
    feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version,feed_contact_url
    MTA New York City Transit,https://www.mta.info/,en,20260906,20270102,20260813,https://example.com
    """#

    static let bus2Routes = #"""
    route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_url,route_color,route_text_color
    BX1,MTABC,BX1-dup,Dup,"",3,,000000,FFFFFF
    Q53+,MTABC,Q53-SBS,"Woodside - Rockaway Park","",3,,6cbe45,FFFFFF
    """#

    static let bus2Stops = #"""
    stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id,stop_url,location_type,parent_station
    100,"SOMETHING ELSE",,41.0,-74.0,,,0,
    200,"WOODSIDE 61 ST STA",,40.745630,-73.902984,,,0,
    """#

    static let bus2Trips = #"""
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    BX1,S2,u1,RIVERDALE,1,,
    Q53+,S2,u2,SELECT BUS WOODSIDE 61 ST STA,0,,
    Q53+,S2,u3,LTD ROCKAWAY PARK B 116 ST,1,,
    """#

    static let bus2StopTimes = #"""
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type,timepoint
    u1,08:00:00,08:00:00,100,1,0,0,1
    u1,08:01:00,08:01:00,200,2,0,0,1
    u2,08:00:00,08:00:00,200,1,0,0,1
    u3,08:00:00,08:00:00,200,1,0,0,1
    t1,08:00:00,08:00:00,103,1,0,0,1
    """#

    static let bus2FeedInfo = #"""
    feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date,feed_version,feed_contact_url
    MTA Bus Company,https://www.mta.info/,en,20260906,20270102,20260801,https://example.com
    """#

    static let expectedStations = #"""
    {"source":"MTA New York City Transit static GTFS (https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip)","feedVersion":"20260901-X-test","feedStartDate":"20261001","feedEndDate":"20261231","stations":[{"id":"701","name":"Flushing-Main St","lat":40.7596,"lon":-73.83003,"routes":[{"route":"7","north":"Flushing-Main St","south":"34 St-Hudson Yards"},{"route":"7X","north":null,"south":"34 St-Hudson Yards"}],"complex":"447","borough":"Q","northLabel":"Last Stop","southLabel":"Manhattan"},{"id":"710","name":"52 St","lat":40.007812,"lon":-73.007812,"routes":[{"route":"7","north":"Flushing-Main St","south":"34 St-Hudson Yards"},{"route":"7X","north":"Flushing-Main St","south":"34 St-Hudson Yards"}]},{"id":"712","name":"61 St-Woodside","lat":40.74563,"lon":-73.902984,"routes":[{"route":"7","north":"Flushing-Main St","south":"34 St-Hudson Yards"}],"complex":"456","borough":"Q","northLabel":"Flushing","southLabel":"Manhattan"},{"id":"726","name":"34 St-Hudson Yards","lat":40.755882,"lon":-74.00191,"routes":[{"route":"7","north":"Flushing-Main St","south":"34 St-Hudson Yards"},{"route":"7X","north":null,"south":"34 St-Hudson Yards"}]},{"id":"A24","name":"59 St–Columbus C\#u{ED}rcle \\ x","lat":40.768296,"lon":-73.981736,"routes":[{"route":"A","north":"Inwood-207 St","south":"Far Rockaway"}]}]}
    """#

    static let expectedExpress = #"""
    {"101S":["104"],"104N":["101"],"201N":["203"],"710S":["726"],"\u00c41S":["\u00c43"]}
    """#

    static let expectedBus = #"""
    {"source":"MTA bus static GTFS (rrgtfsfeeds gtfs_bx/b/m/q/si/busco.zip)","feedVersion":"20260813","routes":{"BX1":{"name":"Bx1","color":"00AEEF","express":false,"agency":"MTA NYCT","headsigns":{"0":"Mott Haven 138 St","1":"Riverdale"}},"M15+":{"name":"M15-SBS","color":"0039A6","express":true,"agency":"MTA NYCT","headsigns":{"0":"South Ferry","1":"East Harlem 126 St"}},"X27":{"name":"X27","color":"EE352E","express":true,"agency":"MTA NYCT","headsigns":{"0":"Midtown","1":"Bay Ridge"}},"B44":{"name":"B44","color":"0039A6","express":false,"agency":"MTA NYCT","headsigns":{"0":"Williamsburg"}},"BXM2":{"name":"BxM2","color":"0039A6","express":true,"agency":"MTA NYCT","headsigns":{"0":""}},"Q53+":{"name":"Q53-SBS","color":"6CBE45","express":true,"agency":"MTABC","headsigns":{"0":"Woodside 61 St Sta","1":"Rockaway Park B 116 St"}}},"stops":[["100","Willis Av / E 138 St",40.01562,-73.95312,["BX1|0","BX1|1"]],["101","Av of the Americas / W 4th St",40.7311,-73.99993,["BX1|0","BX1|1","M15+|0"]],["102","JFK Airport Terminal 4 / LIRR Sta",40.6447,-73.7822,["BX1|1","BXM2|0","X27|0"]],["103","Bed-Stuy / Fulton St - Nostrand Av",40.6811,-73.9503,["M15+|0","M15+|1"]],["104","Of the Bronx",40.80001,-73.90001,["B44|0","X27|1"]],["200","Woodside 61 St Sta",40.74563,-73.90298,["BX1|1","Q53+|0","Q53+|1"]]]}
    """#
}
