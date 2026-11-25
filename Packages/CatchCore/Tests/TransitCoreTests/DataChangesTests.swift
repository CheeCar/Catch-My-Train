import XCTest
@testable import TransitCore

/// New data held against the old before it takes its place: what changed, and whether it is taken at all.
final class DataChangesTests: XCTestCase {
    typealias Item = DataChanges.Item

    /// A small operator: three lines, six stops. "x" is where A and B meet
    let old = DataListing(
        stops: ["a1": "Alder St", "a2": "Birch Av", "x": "Center Sq", "b1": "Dune Rd", "b2": "Elm Pl", "c1": "Ferry Landing"],
        routes: ["A": "Line A", "B": "Line B", "C": "Line C"],
        routeStops: ["A": ["a1", "a2", "x"], "B": ["x", "b1", "b2"], "C": ["c1", "b2"]])

    let loose = DataJudgement.Limits(kept: 0.70, countChange: 0.30, slack: 2)

    func testNothingChanged() {
        let changes = DataChanges.between(old: old, new: old)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.count, 0)
        XCTAssertEqual(changes.lines, 0)
        XCTAssertEqual(changes.renumbered, 0)
        XCTAssertEqual(DataJudgement.of(old: old, new: old, limits: loose), .same)
    }

    func testStopsAndLinesThatCameWentOrWereRenamed() {
        var new = old
        new.stops["a3"] = "Aspen Ct"
        new.stops["a0"] = "Zinc Way"
        new.stops["c1"] = nil
        new.routeStops["C"] = ["b2"]
        new.stops["b1"] = "Dune Road"
        new.routes["D"] = "Line D"
        new.routes["B"] = "Blue Line"
        let changes = DataChanges.between(old: old, new: new)
        // In the order of the names, whatever order the data came in
        XCTAssertEqual(changes.addedStops, [Item(id: "a3", name: "Aspen Ct"), Item(id: "a0", name: "Zinc Way")])
        XCTAssertEqual(changes.removedStops, [Item(id: "c1", name: "Ferry Landing")])
        XCTAssertEqual(changes.renamedStops, [DataChanges.Rename(id: "b1", from: "Dune Rd", to: "Dune Road")])
        XCTAssertEqual(changes.addedRoutes, [Item(id: "D", name: "Line D")])
        XCTAssertEqual(changes.renamedRoutes, [DataChanges.Rename(id: "B", from: "Line B", to: "Blue Line")])
        XCTAssertEqual(changes.removedRoutes, [])
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(changes.count, 6)
        XCTAssertEqual(changes.lines, 6)
        XCTAssertEqual(DataJudgement.of(old: old, new: new, limits: loose), .changed)
        // The same change again reads the same
        XCTAssertEqual(DataChanges.between(old: old, new: new), changes)
    }

    func testCapitalsAndSpacesAreNotANewName() {
        var new = old
        new.stops["a1"] = "ALDER  ST"
        new.stops["a2"] = " Birch Av "
        new.routes["A"] = "line a"
        XCTAssertTrue(DataChanges.between(old: old, new: new).isEmpty)
        XCTAssertEqual(DataChanges.key("  Center\tSq "), "center sq")
        new.stops["x"] = "Centre Sq"
        XCTAssertEqual(DataChanges.between(old: old, new: new).renamedStops.map(\.id), ["x"])
    }

    /// An operator that renumbers its data: every id new, every name the same. Nothing a rider sees changed
    func testNewIdsAloneAreNoChange() {
        let new = DataListing(
            stops: Dictionary(uniqueKeysWithValues: old.stops.map { ("n-" + $0.key, $0.value) }),
            routes: Dictionary(uniqueKeysWithValues: old.routes.map { ("n-" + $0.key, $0.value) }),
            routeStops: [:])
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.renumbered, 9)
        XCTAssertEqual(DataJudgement.of(old: old, new: new, limits: loose), .same)
        // Even held to the strictest limits: all the stops are still there
        XCTAssertEqual(DataJudgement.of(old: old, new: new, limits: .init(kept: 1, countChange: 0, slack: 0)), .same)
    }

    /// Stops on the two sides of a street share a name: one with a new id pairs with one of them, not with both
    func testStopsThatShareAName() {
        let before = DataListing(stops: ["e": "Main St", "w": "Main St", "k": "King St"])
        let renumberedOne = DataListing(stops: ["e": "Main St", "w2": "Main St", "k": "King St"])
        var changes = DataChanges.between(old: before, new: renumberedOne)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.renumbered, 1)
        // One of the two is gone and the other got a new id
        let oneLeft = DataListing(stops: ["m": "Main St", "k": "King St"])
        changes = DataChanges.between(old: before, new: oneLeft)
        XCTAssertEqual(changes.renumbered, 1)
        XCTAssertEqual(changes.removedStops.map(\.name), ["Main St"])
        XCTAssertEqual(changes.addedStops, [])
        // One more with the same name came
        let third = DataListing(stops: ["e": "Main St", "w": "Main St", "n": "Main St", "k": "King St"])
        changes = DataChanges.between(old: before, new: third)
        XCTAssertEqual(changes.addedStops, [Item(id: "n", name: "Main St")])
        XCTAssertEqual(changes.removedStops, [])
        XCTAssertEqual(changes.renumbered, 0)
    }

    /// Where the stops are is known: one of the same name far away is another stop, not this one with a new id
    func testAStopOfTheSameNameSomewhereElseIsAnotherStop() {
        let here = Coordinate(latitude: 40.7500, longitude: -73.9900)
        let acrossTheStreet = Coordinate(latitude: 40.7502, longitude: -73.9901)
        let alongTheBlock = Coordinate(latitude: 40.7520, longitude: -73.9900)
        let nextTown = Coordinate(latitude: 40.9000, longitude: -74.1000)
        XCTAssertLessThan(WalkEstimator.distanceMeters(here, alongTheBlock), DataChanges.sameStopWithin)
        XCTAssertGreaterThan(WalkEstimator.distanceMeters(here, nextTown), DataChanges.sameStopWithin)
        let before = DataListing(stops: ["m1": "Main St", "k": "King St"], places: ["m1": here])
        // A new id, moved along its block: the same stop
        var after = DataListing(stops: ["m2": "Main St", "k": "King St"], places: ["m2": alongTheBlock])
        var changes = DataChanges.between(old: before, new: after)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.renumbered, 1)
        // The one here gone and one of that name new in the next town: two changes
        after = DataListing(stops: ["m2": "Main St", "k": "King St"], places: ["m2": nextTown])
        changes = DataChanges.between(old: before, new: after)
        XCTAssertEqual(changes.removedStops, [Item(id: "m1", name: "Main St")])
        XCTAssertEqual(changes.addedStops, [Item(id: "m2", name: "Main St")])
        XCTAssertEqual(changes.renumbered, 0)
        // Two new ones of that name: the near one is this stop, the far one is new, whichever comes first by id
        for (near, far) in [("m2", "m3"), ("m3", "m2")] {
            after = DataListing(stops: [near: "Main St", far: "Main St", "k": "King St"], places: [near: acrossTheStreet, far: nextTown])
            changes = DataChanges.between(old: before, new: after)
            XCTAssertEqual(changes.addedStops, [Item(id: far, name: "Main St")])
            XCTAssertEqual(changes.removedStops, [])
            XCTAssertEqual(changes.renumbered, 1)
        }
        // Two new ones both near enough: this stop is the nearer one, the other is new, whichever comes first by id
        for (nearer, other) in [("m2", "m3"), ("m3", "m2")] {
            after = DataListing(stops: [nearer: "Main St", other: "Main St", "k": "King St"],
                                places: [nearer: acrossTheStreet, other: alongTheBlock])
            changes = DataChanges.between(old: before, new: after)
            XCTAssertEqual(changes.addedStops, [Item(id: other, name: "Main St")])
            XCTAssertEqual(changes.renumbered, 1)
        }
        // Not known where the new one is: the name alone decides, as without positions
        after = DataListing(stops: ["m2": "Main St", "k": "King St"])
        XCTAssertTrue(DataChanges.between(old: before, new: after).isEmpty)
        // A stop that keeps its id is the same stop wherever it now is
        after = DataListing(stops: ["m1": "Main St", "k": "King St"], places: ["m1": nextTown])
        XCTAssertTrue(DataChanges.between(old: before, new: after).isEmpty)
        // All ids new in a town with a "Main St" in each of its two parts: each pairs with its own, none is lost or new
        let two = DataListing(stops: ["a": "Main St", "b": "Main St"], places: ["a": here, "b": nextTown])
        let renumbered = DataListing(stops: ["y": "Main St", "x": "Main St"], places: ["y": acrossTheStreet, "x": nextTown])
        changes = DataChanges.between(old: two, new: renumbered)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.renumbered, 2)
    }

    /// A line that is gone takes the stops only it served with it, told as one thing
    func testALineGoneWithItsStops() {
        var new = old
        new.routes["A"] = nil
        new.routeStops["A"] = nil
        new.stops["a1"] = nil
        new.stops["a2"] = nil
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertEqual(changes.removedRoutes, [DataChanges.LostRoute(
            route: Item(id: "A", name: "Line A"), stops: [Item(id: "a1", name: "Alder St"), Item(id: "a2", name: "Birch Av")])])
        XCTAssertEqual(changes.removedStops, [], "They are told with their line, not again on their own")
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.lines, 1)
        // "x" stays: Line B still stops there
        XCTAssertNotNil(new.stops["x"])
        XCTAssertEqual(DataJudgement.of(old: old, new: new, limits: loose), .changed)
    }

    func testAStopGoneWhoseOtherLineStaysIsToldOnItsOwn() {
        var new = old
        new.routes["A"] = nil
        new.stops["a1"] = nil
        new.stops["a2"] = nil
        new.stops["x"] = nil
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertEqual(changes.removedRoutes.map(\.stops.count), [2])
        XCTAssertEqual(changes.removedStops, [Item(id: "x", name: "Center Sq")], "Line B is still there, so this isn't Line A's doing alone")
    }

    func testTwoLinesGoneShareAStopOnce() {
        var new = old
        new.routes["A"] = nil
        new.routes["B"] = nil
        for stop in ["a1", "a2", "x", "b1"] { new.stops[stop] = nil }
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertEqual(changes.removedRoutes.map(\.route.id), ["A", "B"])
        XCTAssertEqual(changes.removedRoutes.map { $0.stops.map(\.id) }, [["a1", "a2", "x"], ["b1"]])
        XCTAssertEqual(changes.removedStops, [])
        XCTAssertEqual(changes.count, 6, "Two lines and four stops, the shared one counted once")
        // "b2" stays with Line C
        XCTAssertNotNil(new.stops["b2"])
    }

    func testALineGoneWithNoStopsKnownIsStillTold() {
        let before = DataListing(stops: ["a": "A St", "b": "B St"], routes: ["R": "Red", "G": "Green"])
        let after = DataListing(stops: ["a": "A St", "b": "B St"], routes: ["G": "Green"])
        let changes = DataChanges.between(old: before, new: after)
        XCTAssertEqual(changes.removedRoutes, [DataChanges.LostRoute(route: Item(id: "R", name: "Red"), stops: [])])
        XCTAssertEqual(changes.lines, 1)
    }

    func testDataThatLooksWrongIsNotTaken() {
        // Nothing in it
        XCTAssertEqual(DataJudgement.of(old: old, new: DataListing(), limits: loose), .tooDifferent(.empty))
        XCTAssertEqual(DataJudgement.of(old: DataListing(), new: DataListing(), limits: loose), .tooDifferent(.empty))
        // The first data there is has nothing to be held against
        XCTAssertEqual(DataJudgement.of(old: DataListing(), new: old, limits: loose), .changed)
        // A file cut short: most stops gone
        var cut = old
        for stop in ["a1", "a2", "x", "b1"] { cut.stops[stop] = nil }
        XCTAssertEqual(DataJudgement.of(old: old, new: cut, limits: loose), .tooDifferent(.stopsGone))
        // Two lines gone and their stops with them: stops that went with a line count as gone like any other
        var twoLinesLess = cut
        twoLinesLess.routes["A"] = nil
        twoLinesLess.routes["B"] = nil
        XCTAssertEqual(DataChanges.between(old: old, new: twoLinesLess).removedStops, [])
        XCTAssertEqual(DataJudgement.of(old: old, new: twoLinesLess, limits: loose), .tooDifferent(.stopsGone))
        // The same number of stops, every one another: all gone, however much slack
        let other = DataListing(stops: ["p": "P", "q": "Q", "r": "R", "s": "S", "t": "T", "u": "U"])
        XCTAssertEqual(DataJudgement.of(old: old, new: other, limits: .init(kept: 0, countChange: 1, slack: 100)), .tooDifferent(.stopsGone))
        // Twice the stops all at once
        var doubled = old
        for i in 0..<6 { doubled.stops["new\(i)"] = "New Stop \(i)" }
        XCTAssertEqual(DataJudgement.of(old: old, new: doubled, limits: loose), .tooDifferent(.countJump))
    }

    /// With five piers one gone is a fifth of them: a few may always go, by number, not by share
    func testASmallOperatorMayLoseAFewStops() {
        let piers = DataListing(stops: ["1": "North", "2": "East", "3": "South", "4": "West", "5": "Middle"])
        func without(_ ids: String...) -> DataListing {
            var l = piers
            for id in ids { l.stops[id] = nil }
            return l
        }
        let strict = DataJudgement.Limits(kept: 0.95, countChange: 0.10, slack: 2)
        XCTAssertEqual(DataJudgement.of(old: piers, new: without("1"), limits: strict), .changed)
        XCTAssertEqual(DataJudgement.of(old: piers, new: without("1", "2"), limits: strict), .changed)
        XCTAssertEqual(DataJudgement.of(old: piers, new: without("1", "2", "3"), limits: strict), .tooDifferent(.stopsGone))
        // Without the slack the share alone decides, as for the subway's stations now
        let noSlack = DataJudgement.Limits(kept: 0.95, countChange: 0.10, slack: 0)
        XCTAssertEqual(DataJudgement.of(old: piers, new: without("1"), limits: noSlack), .tooDifferent(.stopsGone))
        // Two piers, one gone and one come: the last one left is never "a few"
        let two = DataListing(stops: ["1": "North", "2": "South"])
        XCTAssertEqual(DataJudgement.of(old: two, new: DataListing(stops: ["1": "North", "3": "Harbor"]), limits: strict), .changed)
        XCTAssertEqual(DataJudgement.of(old: two, new: DataListing(stops: ["3": "Harbor", "4": "Bay"]), limits: strict),
                       .tooDifferent(.stopsGone))
    }

    /// The limits the subway's stations have now (StaticData.plausible): a tenth in number, 95 in 100 kept
    func testALargeOperatorGoesByShare() {
        var stations: [String: String] = [:]
        for i in 0..<100 { stations["s\(i)"] = "Station \(i)" }
        let big = DataListing(stops: stations)
        let limits = DataJudgement.Limits(kept: 0.95, countChange: 0.10, slack: 2)
        func gone(_ n: Int) -> DataListing {
            var l = big
            for i in 0..<n { l.stops["s\(i)"] = nil }
            return l
        }
        XCTAssertEqual(DataJudgement.of(old: big, new: gone(5), limits: limits), .changed)
        XCTAssertEqual(DataJudgement.of(old: big, new: gone(6), limits: limits), .tooDifferent(.stopsGone))
        var more = big
        for i in 0..<10 { more.stops["n\(i)"] = "New \(i)" }
        XCTAssertEqual(DataJudgement.of(old: big, new: more, limits: limits), .changed)
        more.stops["n10"] = "New 10"
        XCTAssertEqual(DataJudgement.of(old: big, new: more, limits: limits), .tooDifferent(.countJump))
        // Half as many, with limits that let any number of the old ones go: still a jump, down as well as up
        XCTAssertEqual(DataJudgement.of(old: big, new: gone(50), limits: .init(kept: 0, countChange: 0.10, slack: 0)),
                       .tooDifferent(.countJump))
    }

    func testCappedKeepsTheFirstOfEachList() {
        var new = old
        for i in 0..<8 { new.stops["n\(i)"] = "New \(i)" }
        new.routes["A"] = nil
        new.stops["a1"] = nil
        new.stops["a2"] = nil
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertEqual(changes.addedStops.count, 8)
        let short = changes.capped(to: 3)
        XCTAssertEqual(short.addedStops.map(\.name), ["New 0", "New 1", "New 2"])
        XCTAssertEqual(short.removedRoutes.map(\.stops.count), [2])
        XCTAssertEqual(changes.capped(to: 1).removedRoutes.map(\.stops.count), [1])
        XCTAssertTrue(changes.capped(to: 0).isEmpty)
        XCTAssertEqual(changes.capped(to: 100), changes)
        // What is stored reads back the same
        let data = try? JSONEncoder().encode(short)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(DataChanges.self, from: $0) }, short)
    }

    func testATimetablesListing() {
        func pier(_ id: String, _ name: String) -> FerryFeed.Pier { FerryFeed.Pier(id: id, name: name, lat: 40.7, lon: -74.0) }
        func trip(_ id: String, _ route: String, _ stops: [String]) -> FerryFeed.Trip {
            FerryFeed.Trip(id: id, route: route, service: "s", direction: "N", stops: stops, times: stops.indices.map { 25_200 + $0 * 120 })
        }
        let feed = FerryFeed(versions: ["x": "20261101"],
                             routes: [.init(id: "R1", name: "River", color: "0077C8", realtime: false),
                                      .init(id: "R2", name: "Bay", color: "C8102E", realtime: false)],
                             piers: [pier("a", "Pier A"), pier("b", "Pier B"), pier("c", "Pier C")],
                             trips: [trip("1", "R1", ["a", "b"]), trip("2", "R1", ["b", "a"]), trip("3", "R2", ["b", "c"])],
                             services: [:], shapes: [:])
        let listing = DataListing(feed)
        XCTAssertEqual(listing.stops, ["a": "Pier A", "b": "Pier B", "c": "Pier C"])
        XCTAssertEqual(listing.routes, ["R1": "River", "R2": "Bay"])
        XCTAssertEqual(listing.routeStops, ["R1": ["a", "b"], "R2": ["b", "c"]])
        XCTAssertEqual(listing.places["c"], Coordinate(latitude: 40.7, longitude: -74.0))
        // The Bay line is gone from the next one, and Pier C with it
        var next = feed
        next.routes.removeLast()
        next.piers.removeLast()
        next.trips.removeLast()
        let changes = DataChanges.between(old: listing, new: DataListing(next))
        XCTAssertEqual(changes.removedRoutes.map(\.route.name), ["Bay"])
        XCTAssertEqual(changes.removedRoutes.first?.stops.map(\.name), ["Pier C"])
        XCTAssertEqual(changes.lines, 1)
    }

    func testTheSubwaysAndTheCityBusesListings() {
        func line(_ id: String) -> StationCatalog.RouteDirections { .init(route: id, north: nil, south: nil) }
        let stations = StationCatalog(entries: [
            .init(id: "101", name: "First Av", lat: 40.73, lon: -73.98, routes: [line("L")]),
            .init(id: "102", name: "Union Sq", lat: 40.735, lon: -73.99, routes: [line("L"), line("4")]),
            .init(id: "103", name: "Grand Central", lat: 40.752, lon: -73.977, routes: [line("4")])])
        let subway = DataListing(stations)
        XCTAssertEqual(subway.stops, ["101": "First Av", "102": "Union Sq", "103": "Grand Central"])
        XCTAssertEqual(subway.routes, ["L": "L", "4": "4"])
        XCTAssertEqual(subway.routeStops, ["L": ["101", "102"], "4": ["102", "103"]])
        XCTAssertEqual(subway.places["103"], Coordinate(latitude: 40.752, longitude: -73.977))
        // The L gone from the next list, and the station only it had with it
        let next = DataListing(StationCatalog(entries: Array(stations.entries.dropFirst()).map {
            var station = $0
            station.routes.removeAll { $0.route == "L" }
            return station
        }))
        let changes = DataChanges.between(old: subway, new: next)
        XCTAssertEqual(changes.removedRoutes, [DataChanges.LostRoute(route: Item(id: "L", name: "L"), stops: [Item(id: "101", name: "First Av")])])
        XCTAssertEqual(changes.removedStops, [])

        let route = BusCatalog.Route(name: "M15-SBS", color: "B933AD", express: true, agency: "MTA NYCT", headsigns: [:])
        let buses = BusCatalog(feedVersion: "", routes: ["M15+": route], stops: [
            .init(id: "401", name: "1 Av/E 14 St", lat: 40.731, lon: -73.982, routeDirections: [.init(route: "M15+", direction: "0")]),
            .init(id: "402", name: "2 Av/E 14 St", lat: 40.732, lon: -73.985,
                  routeDirections: [.init(route: "M15+", direction: "1"), .init(route: "M14A", direction: "0")])])
        let bus = DataListing(buses)
        XCTAssertEqual(bus.stops, ["401": "1 Av/E 14 St", "402": "2 Av/E 14 St"])
        XCTAssertEqual(bus.routes, ["M15+": "M15-SBS"])
        XCTAssertEqual(bus.routeStops, ["M15+": ["401", "402"], "M14A": ["402"]])
        XCTAssertEqual(bus.places.count, 2)
    }

    /// Where each stop told is, and the changes near the user's own places: a stop gone where it was, a new or renamed one where
    /// it is now, a line gone with its stops near them; a stop whose place isn't known is never near
    func testTheChangesNearAPlace() throws {
        let home = Coordinate(latitude: 40.7500, longitude: -73.9900)
        let nearHome = Coordinate(latitude: 40.7510, longitude: -73.9900)
        let farAway = Coordinate(latitude: 40.9000, longitude: -74.1000)
        // About 800 m north of home: near within a kilometer, not within 500 m
        let beyond = Coordinate(latitude: 40.7572, longitude: -73.9900)
        let old = DataListing(stops: ["g": "Gone Near", "f": "Gone Far", "b": "Gone Beyond", "r": "Old Name", "l1": "Line Stop",
                                      "k": "Kept"],
                              routes: ["A": "Line A", "B": "Line B"],
                              routeStops: ["A": ["l1"], "B": ["g", "f", "b", "r", "k"]],
                              places: ["g": nearHome, "f": farAway, "b": beyond, "r": farAway, "l1": nearHome, "k": home])
        let new = DataListing(stops: ["n": "New Near", "u": "New Unknown", "r": "New Name", "k": "Kept"],
                              routes: ["B": "Line B"], routeStops: ["B": ["n", "u", "r", "k"]],
                              places: ["n": nearHome, "r": nearHome, "k": home])
        let changes = DataChanges.between(old: old, new: new)
        XCTAssertEqual(changes.places?["g"], nearHome, "gone: where it was")
        XCTAssertEqual(changes.places?["r"], nearHome, "renamed: where it is now")
        XCTAssertNil(changes.places?["u"])
        XCTAssertNil(changes.places?["k"], "only the stops told")
        let near = changes.near([home], within: 500)
        XCTAssertEqual(near.addedStops.map(\.id), ["n"])
        XCTAssertEqual(near.removedStops.map(\.id), ["g"])
        XCTAssertEqual(near.renamedStops.map(\.id), ["r"])
        XCTAssertEqual(near.removedRoutes.map(\.route.id), ["A"])
        XCTAssertEqual(near.removedRoutes.first?.stops.map(\.id), ["l1"])
        XCTAssertEqual(Set(near.places?.keys ?? [:].keys), ["n", "g", "r", "l1"])
        XCTAssertTrue(changes.near([], within: 500).isEmpty)
        XCTAssertTrue(changes.near([farAway], within: 50).removedStops.map(\.id) == ["f"])
        XCTAssertEqual(changes.near([home], within: 1_000).removedStops.map(\.id), ["b", "g"])
        // Cut lists keep only the places of what is left, and a log written before places were kept still reads
        XCTAssertEqual(Set(changes.capped(to: 0).places?.keys ?? [:].keys), [])
        var old0 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changes)) as? [String: Any] ?? [:]
        old0["places"] = nil
        let read = try JSONDecoder().decode(DataChanges.self, from: JSONSerialization.data(withJSONObject: old0))
        XCTAssertNil(read.places)
        XCTAssertEqual(read.addedStops, changes.addedStops)
        XCTAssertTrue(read.near([home], within: 500).isEmpty)
    }
}
