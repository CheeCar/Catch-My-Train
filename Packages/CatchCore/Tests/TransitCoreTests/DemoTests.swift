import XCTest
@testable import TransitCore

/// Demo mode: its area (Manhattan, as the interactive demo page draws it), its places and search, its stations, and the times it
/// makes up, which follow the page's rules.
final class DemoTests: XCTestCase {

    static let catalog = try? StationCatalog.loadBundled()
    static let buses = try? BusCatalog.loadBundled()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// The app's straight-line pre-filter with the default settings (TransitModel.computeStations)
    let radius = CatchSettings.default.sanitized().extendedCandidateRadiusMeters + 100

    func stations(_ system: TransitSystem, near c: Coordinate, radius: Double? = nil) -> [Station] {
        MockTransitData.demoStations(system, near: c, radiusMeters: radius ?? self.radius, catalog: Self.catalog, buses: Self.buses)
    }

    func arrivals(_ system: TransitSystem, at stations: [Station], seed: Int = 0) -> [Arrival] {
        MockTransitData.demoArrivals(at: stations, system: system, catalog: Self.catalog, buses: Self.buses, now: now, seed: seed)
    }

    /// Minutes from now to each departure of one line one way, in order
    func minutes(_ arrivals: [Arrival], station: String, route: String, code: String) -> [Double] {
        arrivals.filter { $0.stationID == station && $0.route == route && $0.direction.code == code }
            .compactMap { $0.arrivalTime?.timeIntervalSince(now) }.map { ($0 / 6).rounded() / 10 }.sorted()
    }

    func place(_ name: String) -> Coordinate {
        DemoData.places.first { $0.name == name }!.coordinate
    }

    // MARK: Area and places

    /// The places Demo mode starts with or finds are on Manhattan as drawn, all the way up to Inwood; the land and water around it
    /// aren't, nor the other islands and Marble Hill
    /// The made-up first departures stay in their range, and a gap of 0 (not in the data, but possible after an edit) doesn't crash
    func testFirstDeparturesWithAnyGap() {
        for key in ["A", "Times Sq-42 St 1", "M15 SBS"] {
            for every in [2.0, 4.5, 8, 30] {
                let first = MockTransitData.demoFirst(key, every: every)
                XCTAssertGreaterThanOrEqual(first, 0.6)
                XCTAssertLessThan(first, 0.6 + every)
                let bus = MockTransitData.demoBusFirst(key, every: every)
                XCTAssertGreaterThanOrEqual(bus, 0.8)
                XCTAssertLessThanOrEqual(bus, 0.8 + every)
            }
            for every in [0.0, -1, .nan, .infinity] {
                XCTAssertEqual(MockTransitData.demoFirst(key, every: every), 0.6)
                XCTAssertEqual(MockTransitData.demoBusFirst(key, every: every), 0.8)
            }
        }
    }

    func testAreaHasThePlacesAndNotTheShoresAcross() {
        XCTAssertEqual(DemoData.places.count, 35)
        for p in DemoData.places { XCTAssertTrue(DemoArea.contains(p.coordinate), p.name) }
        for p in DemoData.recents + [DemoData.home] { XCTAssertTrue(DemoArea.contains(p.coordinate), p.name) }
        XCTAssertTrue(ServiceArea.contains(DemoData.home.coordinate))
        XCTAssertEqual(MetroSubRegion.of(DemoData.home.coordinate), .newYorkCity)
        let outside: [(String, Double, Double)] = [
            ("Hoboken", 40.7359, -74.0303), ("Jersey City", 40.7178, -74.0431), ("Weehawken", 40.7695, -74.0204),
            ("Dumbo", 40.7033, -73.9881), ("Williamsburg", 40.7081, -73.9571), ("Long Island City", 40.7447, -73.9485),
            ("Roosevelt Island", 40.7618, -73.9505), ("Governors Island", 40.6895, -74.0168), ("Hudson River", 40.7500, -74.0200),
            ("East River", 40.7300, -73.9650), ("Upper Bay", 40.6900, -74.0300), ("Fort Lee", 40.8509, -73.9701),
            ("Hudson River at 125 St", 40.8200, -73.9700), ("Harlem River at 155 St", 40.8300, -73.9320), ("Yankee Stadium", 40.8296, -73.9262),
            ("Highbridge", 40.8400, -73.9260), ("Marble Hill", 40.8760, -73.9100), ("Spuyten Duyvil", 40.8790, -73.9180),
            ("Randalls Island", 40.7932, -73.9212),
        ]
        for (name, lat, lon) in outside {
            XCTAssertFalse(DemoArea.contains(Coordinate(latitude: lat, longitude: lon)), name)
        }
        let north: [(String, Double, Double)] = [
            ("Morningside Heights", 40.8060, -73.9600), ("Harlem", 40.8045, -73.9480), ("East Harlem", 40.7990, -73.9400),
            ("Washington Heights", 40.8417, -73.9394), ("Inwood", 40.8677, -73.9212), ("Inwood Hill Park", 40.8720, -73.9250),
        ]
        for (name, lat, lon) in north {
            XCTAssertTrue(DemoArea.contains(Coordinate(latitude: lat, longitude: lon)), name)
        }
    }

    /// The favorites are the first ten places; the recent places are subway stations, named as in the station list
    func testFavoritesAndRecents() throws {
        let catalog = try XCTUnwrap(Self.catalog)
        XCTAssertEqual(DemoData.favorites.map(\.name), [
            "Times Square", "Grand Central Terminal", "Empire State Building", "Rockefeller Center", "Bryant Park",
            "Madison Square Garden", "Union Square", "One World Trade Center", "South Street Seaport", "Battery Park",
        ])
        XCTAssertEqual(DemoData.recents.map(\.name), ["D17", "A24", "A32", "A38"].map { catalog.entry(id: $0)?.name ?? "" })
        XCTAssertEqual(Set(DemoData.places.map(\.id)).count, DemoData.places.count)
    }

    /// The commute presets: one from "My current location" and two from favorites, each a different mode, all usable, named as
    /// saved (in English; AppText.demoPresets translates them), with room left for one more; each has stations of its mode near
    /// where it walks from
    func testPresets() throws {
        let presets = DemoData.presets
        XCTAssertEqual(presets.map(\.name), ["Work", "Home", "Weekend"])
        XCTAssertEqual(presets.map(\.mode), [.subway, .train, .ferry])
        XCTAssertEqual(presets.map(\.fromCurrentLocation), [true, false, false])
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertTrue(CommutePresets.canAdd(to: presets))
        for preset in presets {
            XCTAssertEqual(CommutePresets.cleanName(preset.name), preset.name)
            XCTAssertEqual(preset.state(favorites: DemoData.favorites), .ready, preset.name)
            let change = try XCTUnwrap(preset.switched(favorites: DemoData.favorites))
            let from = change.place?.coordinate ?? DemoData.home.coordinate
            XCTAssertFalse(stations(change.system, near: from).isEmpty, preset.name)
        }
    }

    /// The search finds the famous places and the recent stations by name or by the line under it, then from two letters on the
    /// subway stations of the area by name, each once with every line there; five at most. (Expected results are the page's.)
    func testSearchIsThePages() throws {
        func found(_ text: String) -> [String] { DemoData.search(text, catalog: Self.catalog).map { "\($0.name) | \($0.detail)" } }
        XCTAssertEqual(found("times"), ["Times Square | Midtown, New York, NY",
                                        "Times Sq-42 St | Subway station (1, 2, 3, 7, N, Q, R, W, S), New York, NY"])
        XCTAssertEqual(found("Fulton"), ["Fulton St | Subway station (2, 3, 4, 5, A, C, J, Z), New York, NY"])
        XCTAssertEqual(found("42"), ["Times Sq-42 St | Subway station (1, 2, 3, 7, N, Q, R, W, S), New York, NY",
                                     "Grand Central-42 St | Subway station (4, 5, 6, 7, S), New York, NY",
                                     "42 St-Port Authority Bus Terminal | Subway station (A, C, E), New York, NY",
                                     "42 St-Bryant Pk | Subway station (B, D, F, M), New York, NY"])
        XCTAssertEqual(found("t").map { $0.components(separatedBy: " | ")[0] },
                       ["Times Square", "Grand Central Terminal", "Empire State Building", "Rockefeller Center", "Bryant Park"])
        XCTAssertEqual(found(" w 4 "), ["W 4 St-Wash Sq | Subway station (A, C, E, B, D, F, M), New York, NY"])
        XCTAssertEqual(found("columbus"), ["59 St-Columbus Circle | Subway station (1, 2, A, C, B, D), New York, NY"])
        XCTAssertEqual(found("chambers"), ["Chambers St | Subway station (1, 2, 3), New York, NY",
                                           "Chambers St | Subway station (A, C), New York, NY",
                                           "Chambers St | Subway station (J, Z), New York, NY"])
        XCTAssertEqual(found("96"), ["96 St | Subway station (1, 2, 3), New York, NY", "96 St | Subway station (4, 6), New York, NY",
                                     "96 St | Subway station (A, C, B), New York, NY", "96 St | Subway station (N, Q, R), New York, NY"])
        XCTAssertEqual(found("Subway").count, 4)
        XCTAssertEqual(found("Cloisters"), ["The Met Cloisters | Fort Tryon Park, New York, NY"])
        XCTAssertEqual(found("inwood"), ["Inwood-207 St | Subway station (A), New York, NY"])
        XCTAssertEqual(found(""), [])
        XCTAssertEqual(found("zzz"), [])
        // Every place found is one Demo mode can walk from
        for text in ["st", "av", "sq", "park", "e", "1"] {
            for p in DemoData.search(text, catalog: Self.catalog) { XCTAssertTrue(DemoArea.contains(p.coordinate), p.name) }
        }
    }

    // MARK: Stations

    /// The area has the page's subway stations, all in Manhattan, and every one of them has lines in the daytime that really stop
    /// there; the demo's own stations are in the area too
    func testStationsOfTheArea() throws {
        let catalog = try XCTUnwrap(Self.catalog)
        let area = catalog.entries.filter { DemoArea.includesStation($0.coordinate) }
        XCTAssertEqual(area.count, 151)
        XCTAssertTrue(area.allSatisfy { $0.borough == "M" })
        XCTAssertEqual(Set(area.map(\.id)), Set(DemoData.subwayLines.keys))
        for entry in area {
            let lines = try XCTUnwrap(DemoData.subwayLines[entry.id])
            XCTAssertFalse(lines.isEmpty, entry.id)
            XCTAssertEqual(Set(lines).count, lines.count, entry.id)
            for line in lines {
                let route = entry.routes.first { MTARoute.normalize($0.route) == MTARoute.normalize(line.route) }
                XCTAssertNotNil(route, "\(entry.id) \(line.route)")
                XCTAssertNotNil(line.code == "N" ? route?.north : route?.south, "\(entry.id) \(line.route) \(line.code)")
                XCTAssertFalse(catalog.terminates(stationID: entry.id, route: line.route, code: line.code), "\(entry.id) \(line.route)")
            }
        }
        let own = DemoData.trainStops + DemoData.pathStops + DemoData.ferryStops
        XCTAssertEqual(own.count, 4 + 6 + 10)
        XCTAssertEqual(Set(own.map(\.station.id)).count, own.count)
        for stop in own {
            XCTAssertTrue(DemoArea.includesStation(stop.station.coordinate), stop.station.name)
            XCTAssertFalse(stop.lines.isEmpty, stop.station.name)
            XCTAssertTrue(stop.lines.allSatisfy { ($0.north != nil || $0.south != nil) && $0.every > 0 }, stop.station.name)
        }
        XCTAssertTrue(DemoData.trainStops.flatMap(\.lines).allSatisfy { FerryFeed.isRailRoute($0.route) })
        XCTAssertTrue(DemoData.ferryStops.flatMap(\.lines).allSatisfy { FerryFeed.isFerryRoute($0.route) })
        XCTAssertTrue(DemoData.pathStops.flatMap(\.lines).allSatisfy { $0.route.hasPrefix("PATH-") })
        XCTAssertTrue(FerryFeed.isRailRoute("LIRR-RON"))
        XCTAssertTrue(FerryFeed.isFerryRoute("NYF-ER"))
        XCTAssertTrue(BusCatalog.isBusRoute("M104"))
    }

    /// Near the shores no station across the water shows: not Brooklyn's, Queens', New Jersey's or Roosevelt Island's
    func testStationsStayInTheArea() {
        let shores = ["City Hall Park", "Chelsea Market", "United Nations Headquarters", "Battery Park", "Wall Street", "Hudson Yards"]
        for name in shores {
            for system in TransitSystem.modes {
                let found = stations(system, near: place(name), radius: 2500)
                XCTAssertTrue(found.allSatisfy { DemoArea.includesStation($0.coordinate) }, "\(name) \(system)")
                XCTAssertFalse(found.contains { $0.id == RooseveltIslandTram.islandStationID }, "\(name) \(system)")
            }
        }
        // The tram's Manhattan station is a subway station of the demo, and PATH's are too
        let midtownEast = stations(.subway, near: place("United Nations Headquarters"), radius: 2500).map(\.id)
        XCTAssertTrue(midtownEast.contains(RooseveltIslandTram.manhattanStationID))
        XCTAssertTrue(stations(.subway, near: DemoData.home.coordinate).contains { $0.id == "path-33" })
        // Bus stops are picked from the area's only: Roosevelt Island has MTA stops within reach of the tram station
        let tram = RooseveltIslandTram.station(id: RooseveltIslandTram.manhattanStationID)!.coordinate
        let all = Self.buses?.stations(near: tram, radiusMeters: 1500, limit: 1000) ?? []
        XCTAssertTrue(all.contains { !DemoArea.includesStation($0.coordinate) })
        let area = Self.buses?.stations(near: tram, radiusMeters: 1500, limit: 1000, where: DemoArea.includesStation) ?? []
        XCTAssertFalse(area.isEmpty)
        XCTAssertTrue(area.allSatisfy { DemoArea.includesStation($0.coordinate) })
        XCTAssertEqual(Set(area.map(\.id)).count, area.count)
        XCTAssertEqual(stations(.bus, near: tram, radius: 1500).count, 30)
        XCTAssertTrue(stations(.bus, near: tram, radius: 1500).allSatisfy { DemoArea.includesStation($0.coordinate) })
    }

    // MARK: Times

    /// At Times Square every mode but ferries has stations to catch in the primary range, all with made-up times; the nearest pier
    /// is too far ("No ferries worth catching nearby", as it is for real), and South Street Seaport has Pier 11 close by
    func testTimesSquareHasEveryModeButFerries() throws {
        func board(_ system: TransitSystem, from c: Coordinate) -> NearbyBoard {
            let found = stations(system, near: c)
            var walks: [String: WalkEstimate] = [:]
            for s in found { walks[s.id] = WalkEstimator.estimate(from: c, to: s, settings: .default) }
            let routes = Dictionary(found.map { s in
                (s.id, DemoData.stop(id: s.id)?.routes
                    ?? (system == .bus ? Self.buses?.routes(atStop: s.id) : Self.catalog?.entry(id: s.id)?.routes.map(\.route)) ?? [])
            }, uniquingKeysWith: { a, _ in a })
            let all = arrivals(system, at: found)
            for a in all { XCTAssertTrue(routes[a.stationID]?.contains(a.route) == true, "\(system) \(a.stationID) \(a.route)") }
            return NearbyBoardBuilder.build(stations: found, walks: walks, arrivals: all, settings: .default, now: now, routes: routes)
        }
        for system in [TransitSystem.subway, .bus, .train] {
            let b = board(system, from: DemoData.home.coordinate)
            let primary = b.stations.filter { $0.range == .primary }
            XCTAssertFalse(primary.isEmpty, "\(system)")
            let trains = b.stations.flatMap { $0.north.trains + $0.south.trains }
            XCTAssertFalse(trains.isEmpty, "\(system)")
            XCTAssertTrue(trains.allSatisfy { $0.evaluation.notes.contains(.mockData) }, "\(system)")
        }
        XCTAssertFalse(board(.ferry, from: DemoData.home.coordinate).stations.contains { $0.range == .primary })
        let seaport = board(.ferry, from: place("South Street Seaport"))
        XCTAssertTrue(seaport.stations.contains { $0.range == .primary && $0.stations.contains { $0.id == "ferry-pier11" } })
    }

    /// Subway times follow the page: the first departure staggered by station and line (the page's hash), the other way half a gap
    /// later, every so many minutes for about 2 hours; express where most trains skip stations; the second train of the station's
    /// first line late; each refresh half a minute on, three steps round
    func testSubwayTimesFollowThePage() throws {
        let catalog = try XCTUnwrap(Self.catalog)
        let times = try XCTUnwrap(catalog.station(id: "127"))
        let a = arrivals(.subway, at: [times])
        XCTAssertEqual(Set(a.map(\.route)), ["1", "2", "3"])
        // The page's hash: "1271" → 1509563, 1509563 % 60 = 23 → 0.6 + 2.3 minutes; "1272" → 1509564 % 80 = 44 → 5.0
        XCTAssertEqual(MockTransitData.demoHash("1271"), 1_509_563)
        XCTAssertEqual(minutes(a, station: "127", route: "1", code: "N").prefix(3), [2.9, 8.9, 14.9])
        XCTAssertEqual(minutes(a, station: "127", route: "1", code: "S").first, 5.9)
        XCTAssertEqual(minutes(a, station: "127", route: "2", code: "N").first, 5.0)
        XCTAssertEqual(minutes(a, station: "127", route: "2", code: "S").first, 9.0)
        XCTAssertTrue(a.allSatisfy { ($0.arrivalTime?.timeIntervalSince(now) ?? 0) <= 125 * 60 })
        XCTAssertEqual(a.filter { $0.route == "1" }.map(\.isExpress), Array(repeating: false, count: a.filter { $0.route == "1" }.count))
        XCTAssertTrue(a.filter { $0.route != "1" }.allSatisfy { $0.isExpress == true })
        XCTAssertEqual(a.filter { $0.status == .delayed }.map(\.id), ["demo-127-1-N-0-1"])
        XCTAssertTrue(a.allSatisfy { $0.source == .mock && !$0.isTimetableTime })
        XCTAssertEqual(a.first { $0.route == "1" && $0.direction.code == "N" }?.direction,
                       catalog.direction(stationID: "127", route: "1", code: "N"))
        // Each refresh moves them half a minute, back after three
        XCTAssertEqual(minutes(arrivals(.subway, at: [times], seed: 1), station: "127", route: "1", code: "N").first, 3.4)
        XCTAssertEqual(minutes(arrivals(.subway, at: [times], seed: 2), station: "127", route: "1", code: "N").first, 3.9)
        XCTAssertEqual(arrivals(.subway, at: [times], seed: 3), a)
        // A line that ends at the station goes one way only (South Ferry); the shuttle at Times Square only to Grand Central
        let southFerry = try XCTUnwrap(catalog.station(id: "142"))
        XCTAssertEqual(Set(arrivals(.subway, at: [southFerry]).map(\.direction.code)), ["N"])
        let shuttle = try XCTUnwrap(catalog.station(id: "902"))
        XCTAssertEqual(Set(arrivals(.subway, at: [shuttle]).map { "\($0.route) \($0.direction.code)" }), ["GS S"])
        // Every subway station of the area has trains both ways or the one way its lines go
        for id in DemoData.subwayLines.keys {
            XCTAssertFalse(arrivals(.subway, at: [try XCTUnwrap(catalog.station(id: id))]).isEmpty, id)
        }
    }

    /// Bus times are the page's own: its stops at Times Square have these first departures, destinations and sides
    func testBusTimesAreThePages() throws {
        let found = stations(.bus, near: DemoData.home.coordinate)
        let a = arrivals(.bus, at: found)
        func first(_ stop: String, _ route: String) -> String? {
            guard let x = a.filter({ $0.stationID == stop && $0.route == route }).min(by: { $0.arrivalTime! < $1.arrivalTime! })
            else { return nil }
            return "\(x.direction.code) \(x.direction.terminal ?? "") \(((x.arrivalTime!.timeIntervalSince(now)) / 6).rounded() / 10)"
        }
        XCTAssertEqual(first("404153", "M104"), "N 41 St 3.8")
        XCTAssertEqual(first("450045", "M7"), "N 14 St 2.5")
        XCTAssertEqual(first("450045", "M20"), "N South Ferry 9.6")
        XCTAssertEqual(first("450045", "BXM2"), "N West Midtown Penn Sta-34 St 8.0")
        XCTAssertEqual(minutes(a, station: "450045", route: "BXM2", code: "N").prefix(3), [8.0, 38.0, 68.0])
        XCTAssertEqual(a.first { $0.route == "BXM2" }?.busService, .express)
        XCTAssertEqual(a.first { $0.route == "M7" }?.busService, .local)
        XCTAssertEqual(MockTransitData.demoBusEvery("M34+"), 7)
        XCTAssertEqual(MockTransitData.demoBusEvery("M86+"), 8)
        XCTAssertEqual(MockTransitData.demoBusEvery("SIM22"), 30)
        XCTAssertEqual(MockTransitData.demoBusEvery("M101"), 12)
        XCTAssertEqual(MockTransitData.demoBusEvery("B39"), 15)
        // Every MTA bus stop of the area has buses to catch
        for stop in Self.buses?.stops ?? [] where DemoArea.includesStation(stop.coordinate) {
            let station = Station(id: stop.id, name: stop.name, coordinate: stop.coordinate, entranceToPlatformSeconds: 0)
            XCTAssertFalse(arrivals(.bus, at: [station]).isEmpty, stop.id)
        }
    }

    /// The demo's own stations: their lines where they go, timetable lines with the timetable mark and never late, the rest live
    func testOwnStationTimes() throws {
        let penn = try XCTUnwrap(DemoData.stop(id: "rail-penn"))
        let a = arrivals(.train, at: [penn.station])
        XCTAssertTrue(a.filter { $0.route.hasPrefix("AMK-") || $0.route.hasPrefix("NJT-") }.allSatisfy {
            $0.isTimetableTime && $0.source == .mock && $0.status == .normal
        })
        XCTAssertTrue(a.filter { $0.route.hasPrefix("LIRR-") }.allSatisfy { !$0.isTimetableTime })
        XCTAssertTrue(a.contains { $0.route == "NJT-NEC" && $0.direction.code == "S" && $0.direction.terminal == "Trenton Transit Center" })
        XCTAssertFalse(a.contains { $0.route.hasPrefix("LIRR-") && $0.direction.code == "S" })
        for stop in DemoData.trainStops + DemoData.pathStops + DemoData.ferryStops {
            let times = arrivals(.train, at: [stop.station])
            XCTAssertTrue(times.allSatisfy { a in stop.routes.contains(a.route) }, stop.station.id)
            // A line that runs at least every two hours has times; both ways when it goes both ways
            for line in stop.lines where line.every <= 120 {
                XCTAssertEqual(Set(times.filter { $0.route == line.route }.map(\.direction.code)),
                               Set([line.north.map { _ in "N" }, line.south.map { _ in "S" }].compactMap { $0 }),
                               "\(stop.station.id) \(line.route)")
            }
        }
    }
    // MARK: Plan a Trip

    /// Plan a Trip in Demo mode from `c`, leaving that many minutes from now (live within 30 minutes, as PlannerModel.usesRealtime),
    /// with the main window's service made at `base` with `seed`
    func plan(_ system: TransitSystem, at c: Coordinate = DemoData.home.coordinate, leaveIn minutes: Double, active: Bool = true,
              radius: Double? = nil, base: Date? = nil, seed: Int = 0) -> MockTransitData.DemoPlan {
        MockTransitData.demoPlan(system, near: c, radiusMeters: radius ?? self.radius, leave: now.addingTimeInterval(minutes * 60),
                                 window: 2 * 3600, live: minutes < 30, active: active, catalog: Self.catalog, buses: Self.buses,
                                 base: base ?? now, seed: seed, now: now)
    }

    /// The search finds only the famous places when the stations are listed by themselves (Plan a Trip in subway mode), and those
    /// are the area's stations whose names have the text, from two letters on, by name, four at most; "JFK" finds nothing
    func testPlanATripSearch() throws {
        func names(_ text: String, stations: Bool) -> [String] {
            DemoData.search(text, catalog: Self.catalog, stations: stations).map(\.name)
        }
        XCTAssertEqual(names("times", stations: false), ["Times Square"])
        XCTAssertEqual(names("Fulton", stations: false), [])
        XCTAssertEqual(names("t", stations: false), names("t", stations: true))
        XCTAssertEqual(names("JFK", stations: false), [])
        XCTAssertEqual(names("JFK", stations: true), [])
        func stations(_ text: String) -> [String] { DemoData.stationSearch(text, catalog: Self.catalog).map { "\($0.id) \($0.name)" } }
        XCTAssertEqual(stations("42"), ["D16 42 St-Bryant Pk", "A27 42 St-Port Authority Bus Terminal", "631 Grand Central-42 St",
                                        "723 Grand Central-42 St"])
        XCTAssertEqual(stations(" fulton "), ["229 Fulton St", "418 Fulton St", "A38 Fulton St", "M22 Fulton St"])
        XCTAssertEqual(stations("t"), [])
        XCTAssertEqual(stations("JFK"), [])
        // Not the stations outside the area (Jamaica is in Queens)
        XCTAssertEqual(stations("Jamaica"), [])
        XCTAssertFalse(Self.catalog?.entries.filter { $0.name.contains("Jamaica") }.isEmpty ?? true)
    }

    /// Leaving within 30 minutes with the app on, Plan a Trip has the main window's times at the same stations (made from its last
    /// refresh, the late one too), from when you leave to the end of the range, all live; nothing to say
    func testPlanATripHasTheMainWindowsTimes() throws {
        let base = now.addingTimeInterval(-40)
        let p = plan(.subway, leaveIn: 10, base: base, seed: 4)
        let leave = now.addingTimeInterval(600)
        XCTAssertTrue(p.live)
        XCTAssertNil(p.note)
        XCTAssertTrue(p.stations.contains { $0.id == "127" })
        XCTAssertTrue(p.stations.contains { $0.id == "path-33" })
        XCTAssertFalse(p.arrivals.isEmpty)
        XCTAssertTrue(p.arrivals.allSatisfy { a in
            guard let t = a.arrivalTime else { return false }
            return t >= leave && t <= leave.addingTimeInterval(2 * 3600)
        })
        XCTAssertTrue(p.arrivals.allSatisfy { !$0.isTimetableTime && $0.source == .mock })
        XCTAssertTrue(p.arrivals.contains { $0.stationID == "path-33" })
        // The main window's, made 40 seconds ago at the same stations
        let main = MockTransitData.demoArrivals(at: p.stations, system: .subway, catalog: Self.catalog, buses: Self.buses,
                                                now: base, seed: 4)
        let byID = Dictionary(main.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shared = p.arrivals.filter { ($0.arrivalTime ?? .distantFuture) <= base.addingTimeInterval(125 * 60) }
        XCTAssertGreaterThan(shared.count, 100)
        for a in shared {
            let same = try XCTUnwrap(byID[a.id], a.id)
            XCTAssertEqual(a.arrivalTime, same.arrivalTime, a.id)
            XCTAssertEqual(a.status, same.status, a.id)
            XCTAssertEqual(a.direction, same.direction, a.id)
        }
        XCTAssertEqual(Set(main.filter { ($0.arrivalTime ?? now) >= leave }.map(\.id)), Set(shared.map(\.id)))
        // Their age is counted from when the plan is made, so none is old
        XCTAssertTrue(p.arrivals.allSatisfy { $0.updatedAt == now.addingTimeInterval(-30) })
        // Later than the main window's 2 hours, the service goes on
        XCTAssertTrue(p.arrivals.contains { ($0.arrivalTime ?? now) > base.addingTimeInterval(125 * 60) })
    }

    /// Leaving later, the subway times are the timetable's (marked so, none late), on standby too; PATH has none and says so
    func testPlanATripLaterIsTheTimetables() throws {
        for active in [true, false] {
            let p = plan(.subway, leaveIn: 180, active: active)
            XCTAssertFalse(p.live)
            XCTAssertEqual(p.note, .pathLiveOnly)
            XCTAssertFalse(p.arrivals.isEmpty)
            XCTAssertTrue(p.arrivals.allSatisfy { $0.isTimetableTime && $0.status == .normal && $0.updatedAt == now })
            XCTAssertFalse(p.arrivals.contains { $0.stationID.hasPrefix("path-") })
            XCTAssertTrue(p.arrivals.allSatisfy { ($0.arrivalTime ?? now) >= now.addingTimeInterval(180 * 60) })
        }
    }

    /// On standby, leaving within 30 minutes: no subway times, PATH's timetable, and "turn the app on"; with only PATH near, its own note
    func testPlanATripOnStandby() throws {
        let p = plan(.subway, leaveIn: 10, active: false)
        XCTAssertTrue(p.live)
        XCTAssertEqual(p.note, .turnOnForLiveTimes)
        XCTAssertFalse(p.arrivals.isEmpty)
        XCTAssertTrue(p.arrivals.allSatisfy { $0.stationID.hasPrefix("path-") && $0.isTimetableTime })
        let ninth = try XCTUnwrap(DemoData.stop(id: "path-9")).station.coordinate
        let pathOnly = plan(.subway, at: ninth, leaveIn: 10, active: false, radius: 50)
        XCTAssertEqual(pathOnly.stations.map(\.id), ["path-9"])
        XCTAssertEqual(pathOnly.note, .turnOnForPathLiveTimes)
        XCTAssertTrue(pathOnly.arrivals.allSatisfy(\.isTimetableTime))
        XCTAssertFalse(pathOnly.arrivals.isEmpty)
        XCTAssertEqual(plan(.subway, at: ninth, leaveIn: 10, radius: 50).note, nil)
        XCTAssertEqual(plan(.subway, at: ninth, leaveIn: 60, radius: 50).note, .pathLiveOnly)
        XCTAssertTrue(plan(.subway, at: ninth, leaveIn: 60, radius: 50).arrivals.isEmpty)
    }

    /// MTA buses have live times only: with the app on, leaving within 30 minutes; otherwise none, their stops aren't listed
    /// (as in the real Plan a Trip), and the note says why
    func testPlanATripBuses() throws {
        let on = plan(.bus, leaveIn: 10)
        XCTAssertTrue(on.live)
        XCTAssertNil(on.note)
        XCTAssertFalse(on.arrivals.isEmpty)
        XCTAssertFalse(on.stations.isEmpty)
        XCTAssertTrue(on.arrivals.allSatisfy { !$0.isTimetableTime })
        let standby = plan(.bus, leaveIn: 10, active: false)
        XCTAssertFalse(standby.live)
        XCTAssertEqual(standby.note, .turnOnForLiveTimes)
        XCTAssertTrue(standby.arrivals.isEmpty)
        XCTAssertTrue(standby.stations.isEmpty)
        let later = plan(.bus, leaveIn: 120)
        XCTAssertFalse(later.live)
        XCTAssertEqual(later.note, .mtaBusLiveOnly)
        XCTAssertTrue(later.arrivals.isEmpty)
        XCTAssertTrue(later.stations.isEmpty)
        // Nowhere near a stop: no note either
        XCTAssertNil(plan(.bus, at: Coordinate(latitude: 40.0, longitude: -73.0), leaveIn: 120).note)
    }

    /// Trains and ferries: live where the operator has live data and the app is on, the timetables otherwise; on standby "turn the
    /// app on" where there would be live times
    func testPlanATripTrainsAndFerries() throws {
        let penn = place("Madison Square Garden")
        let on = plan(.train, at: penn, leaveIn: 10)
        XCTAssertTrue(on.live)
        XCTAssertNil(on.note)
        XCTAssertTrue(on.arrivals.filter { $0.route.hasPrefix("LIRR-") }.allSatisfy { !$0.isTimetableTime })
        XCTAssertTrue(on.arrivals.contains { $0.route.hasPrefix("LIRR-") })
        XCTAssertTrue(on.arrivals.filter { $0.route.hasPrefix("AMK-") || $0.route.hasPrefix("NJT-") }.allSatisfy(\.isTimetableTime))
        let standby = plan(.train, at: penn, leaveIn: 10, active: false)
        XCTAssertFalse(standby.live)
        XCTAssertEqual(standby.note, .turnOnForLiveTimes)
        XCTAssertTrue(standby.arrivals.allSatisfy { $0.isTimetableTime && $0.status == .normal })
        XCTAssertFalse(standby.arrivals.isEmpty)
        for active in [true, false] {
            let later = plan(.train, at: penn, leaveIn: 90, active: active)
            XCTAssertFalse(later.live)
            XCTAssertNil(later.note)
            XCTAssertTrue(later.arrivals.allSatisfy(\.isTimetableTime))
            XCTAssertFalse(later.arrivals.isEmpty)
        }
        let seaport = place("South Street Seaport")
        let ferry = plan(.ferry, at: seaport, leaveIn: 10)
        XCTAssertTrue(ferry.live)
        XCTAssertTrue(ferry.arrivals.contains { $0.stationID == "ferry-pier11" && !$0.isTimetableTime })
        XCTAssertEqual(plan(.ferry, at: seaport, leaveIn: 10, active: false).note, .turnOnForLiveTimes)
        XCTAssertNil(plan(.ferry, at: seaport, leaveIn: 45).note)
    }

    // MARK: Made-up times don't go stale

    /// Demo mode on standby doesn't refresh: its made-up times, made 5 minutes ago, are still judged (not "Not sure" for being out
    /// of date, as real live data would be after 3 minutes)
    func testMadeUpTimesDontGoStale() throws {
        let times = Coordinate(latitude: 40.7557, longitude: -73.9871)
        let list = arrivals(.subway, at: stations(.subway, near: times))
        let walk = WalkEstimate(walkSeconds: 120, straightLineMeters: 150, source: .estimated)
        let later = now.addingTimeInterval(5 * 60)
        let ahead = try XCTUnwrap(list.first { ($0.arrivalTime ?? now) > later.addingTimeInterval(20 * 60) })
        let e = CatchEvaluator.evaluate(arrival: ahead, walk: walk, entranceToPlatformSeconds: 60, settings: .default, now: later)
        XCTAssertEqual(e.verdict, .canTry)
        XCTAssertFalse(e.notes.contains(.staleRealtime))
        // Real live data of the same age is out of date
        var live = ahead
        live.source = .realtime
        let real = CatchEvaluator.evaluate(arrival: live, walk: walk, entranceToPlatformSeconds: 60, settings: .default, now: later)
        XCTAssertEqual(real.verdict, .insufficientInfo)
    }
}
