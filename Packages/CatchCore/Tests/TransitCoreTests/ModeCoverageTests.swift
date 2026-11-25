import XCTest
@testable import TransitCore

/// When data sources are added or removed, the transit mode descriptions must be updated too. This checks that the descriptions match
/// the sources the app actually downloads, one metro area at a time: the sidebar header's popover lists the start place's area only.
final class ModeCoverageTests: XCTestCase {
    private func names(_ mode: TransitSystem, _ area: MetroArea?) -> [String] {
        ModeCoverage.operators(for: mode, in: area).flatMap(\.names)
    }

    /// Every source is listed in each metro area it has stops in and in no other, with the kinds of vehicles it runs there, and
    /// as live when its live data is free
    func testEverySourceIsListedInItsAreas() {
        for s in FerryFeed.Source.allCases where s != .njTransitBus {
            XCTAssertFalse(MetroArea.areas(of: s).isEmpty, s.name)
            for area in MetroArea.allCases {
                let rows = ModeCoverage.operators(for: s.system.mode, in: area)
                let inArea = MetroArea.areas(of: s).contains(area)
                // The light rail lines are listed by name, each where it stops
                let expected = s == .njTransitLightRail ? ModeCoverage.lightRailLines.filter { ModeCoverage.areas(ofLightRail: $0).contains(area) }
                    : inArea ? [s.name] : []
                XCTAssertEqual(rows.flatMap(\.names).contains(s.name), inArea && s != .njTransitLightRail, "\(s.name), \(area)")
                for name in expected {
                    guard let row = rows.first(where: { $0.names.contains(name) }) else {
                        XCTFail("\(name) is missing from the \(s.system.mode) list of \(area)")
                        continue
                    }
                    XCTAssertEqual(row.kinds, MetroArea.kinds(of: s, in: area), "\(name), \(area)")
                    XCTAssertFalse(row.kinds.isEmpty, name)
                    XCTAssertEqual(row.live, s.hasRealtime, "\(name), \(area)")
                }
            }
        }
        // Each light rail line has its areas, all of them the light rail's own, and together they are all of them
        let lines = AreaCatalog.shared.operator(FerryFeed.Source.njTransitLightRail.rawValue)?.lines ?? [:]
        XCTAssertEqual(Set(lines.keys), Set(ModeCoverage.lightRailLines))
        XCTAssertEqual(Set(ModeCoverage.lightRailLines.flatMap(ModeCoverage.areas(ofLightRail:))), Set(MetroArea.areas(of: .njTransitLightRail)))
        // The River LINE's Trenton end is in New York's area
        XCTAssertEqual(MetroArea.of(Coordinate(latitude: 40.2180, longitude: -74.7550)), .newYork)
        for feed in RegionalBusFeed.all {
            XCTAssertFalse(MetroArea.areas(ofBus: feed).isEmpty, feed.name)
            for area in MetroArea.allCases {
                XCTAssertEqual(names(.bus, area).contains(feed.name), MetroArea.areas(ofBus: feed).contains(area), "\(feed.name), \(area)")
            }
        }
    }

    /// areas.json lists every operator once, each with at least one area that exists and kinds in each; every source, bus company
    /// and bundled operator the app has is there, and nothing that isn't
    func testEveryOperatorIsInTheAreaList() {
        let catalog = AreaCatalog.shared
        let ids = catalog.operators.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "an operator is listed twice in areas.json")
        let areaIDs = Set(MetroArea.allCases.map(\.rawValue))
        for op in catalog.operators {
            XCTAssertFalse(op.kinds.isEmpty, op.id)
            for (area, kinds) in op.kinds {
                XCTAssertTrue(areaIDs.contains(area), "\(op.id): no metro area \(area)")
                XCTAssertFalse(kinds.isEmpty, "\(op.id) in \(area): no kinds (or one that isn't a VehicleKind)")
            }
            for (_, areas) in op.lines { XCTAssertTrue(Set(areas).isSubset(of: Set(op.kinds.keys)), op.id) }
        }
        let expected = FerryFeed.Source.allCases.map(\.rawValue) + ModeCoverage.localBuses.map { MetroArea.busOperatorID($0.code) }
            + [ModeCoverage.subwayID, ModeCoverage.statenIslandRailwayID, ModeCoverage.tramID, ModeCoverage.mtaBusID, ModeCoverage.shoreLineEastID]
        for id in expected { XCTAssertNotNil(catalog.operator(id), "\(id) was added: list it in areas.json's operators") }
        for id in ids { XCTAssertTrue(expected.contains(id), "\(id) is no longer an operator: remove it from areas.json") }
    }

    /// The footer's live data line: every operator of the area once, grouped by where its times come from now, following
    /// the keys and account the user added and the bus companies whose live data isn't downloading
    func testLiveNamesFollowTheAreaAndTheKeys() {
        func states(_ mode: TransitSystem, _ area: MetroArea, _ access: ModeCoverage.LiveAccess = .init()) -> [String: ModeCoverage.LiveState] {
            Dictionary(ModeCoverage.liveNames(for: mode, in: area, access: access).map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
        }
        for mode in TransitSystem.modes {
            for area in MetroArea.allCases {
                let names = ModeCoverage.liveNames(for: mode, in: area).map(\.name)
                XCTAssertEqual(names.count, Set(names).count, "\(mode), \(area): a name twice")
                let rows = ModeCoverage.operators(for: mode, in: area).filter { !$0.kinds.isEmpty }
                XCTAssertEqual(Set(names), Set(rows.flatMap { $0.group.map { [$0] } ?? $0.names }), "\(mode), \(area)")
            }
        }
        let subway = states(.subway, .newYork)
        XCTAssertEqual(subway["NYC Subway"], .live)
        // NJ Transit's light rail isn't live with the account (liveWithAccount), so no account is asked for it; its buses are
        XCTAssertEqual(subway["Hudson-Bergen Light Rail"], .timetable)
        XCTAssertEqual(subway[ModeCoverage.tram], .estimated)
        XCTAssertNil(subway["PATCO"])
        XCTAssertEqual(states(.subway, .newYork, .init(njTransitAccount: true))["River LINE"], .timetable)
        XCTAssertEqual(states(.subway, .philadelphia)["PATCO"], .timetable)
        let bus = states(.bus, .newYork)
        XCTAssertEqual(bus["MTA"], .needsKey)
        XCTAssertEqual(bus["NJ Transit"], .needsKey)
        XCTAssertEqual(bus["Suffolk County Transit"], .needsKey)
        XCTAssertEqual(bus["Bee-Line"], .live)
        XCTAssertEqual(bus["NICE"], .timetable)
        let keyed = states(.bus, .newYork, .init(mtaBusKey: true, njTransitAccount: true, suffolkKey: true, failedBuses: ["BXL"]))
        XCTAssertEqual(keyed["MTA"], .live)
        XCTAssertEqual(keyed["NJ Transit"], .live)
        XCTAssertEqual(keyed["Suffolk County Transit"], .live)
        XCTAssertEqual(keyed["Bee-Line"], .notNow)
        XCTAssertEqual(ModeCoverage.liveNames(for: .bus, in: .newYork, access: .init(failedBuses: ["BXL"])).first { $0.name == "Bee-Line" }?.busCode, "BXL")
        XCTAssertNil(states(.bus, .philadelphia)["NICE"])
        XCTAssertEqual(states(.train, .newYork)["NJ Transit Rail"], .needsKey)
        XCTAssertEqual(states(.train, .newYork, .init(njTransitAccount: true))["NJ Transit Rail"], .live)
        XCTAssertEqual(states(.ferry, .philadelphia).count, 1)
    }

    /// Who the data is credited to, one metro area at a time: areas.json's credits in its order, each once; the bus companies by name
    func testCreditsFollowTheArea() {
        XCTAssertEqual(ModeCoverage.credits(for: .subway, in: .newYork),
                       ["MTA", "Port Authority of New York and New Jersey (PATH)", "NJ Transit", "RIOC"])
        XCTAssertEqual(ModeCoverage.credits(for: .subway, in: .philadelphia), ["NJ Transit", "SEPTA", "PATCO"])
        XCTAssertEqual(ModeCoverage.credits(for: .train, in: .newYork), ["MTA", "NJ Transit", "SEPTA", "CTrail", "Amtrak"])
        XCTAssertEqual(ModeCoverage.credits(for: .train, in: .philadelphia),
                       ["NJ Transit", "SEPTA", "Maryland Transit Administration (MARC)", "Amtrak"])
        XCTAssertEqual(ModeCoverage.credits(for: .ferry, in: .philadelphia), ["Delaware River and Bay Authority"])
        XCTAssertEqual(ModeCoverage.credits(for: .ferry, in: .newYork), ["NYC Ferry", "NYC DOT", "NY Waterway", "Seastreak", "National Park Service"])
        let bus = ModeCoverage.credits(for: .bus, in: .newYork)
        XCTAssertEqual(Array(bus.prefix(2)), ["MTA", "NJ Transit"])
        XCTAssertTrue(bus.contains("NICE") && bus.contains("SEPTA") && !bus.contains("BARTA"))
        let all = ModeCoverage.credits(for: .bus, in: nil)
        XCTAssertEqual(all.count, Set(all).count)
        // The bus companies under their own names, or areas.json's credit (the MBTA's names MassDOT, as its terms ask)
        XCTAssertEqual(Set(all), Set(["MTA", "NJ Transit"] + ModeCoverage.localBuses.map {
            AreaCatalog.shared.operator(MetroArea.busOperatorID($0.code))?.credit ?? $0.name
        }))
        XCTAssertEqual(ModeCoverage.credits(for: .bus, in: .greaterBoston),
                       ["MBTA (MassDOT)", "RIPTA", "WRTA", "LRTA", "GATRA", "SRTA", "BAT", "CCRTA", "MART", "MeVa Transit", "CATA", "MWRTA",
                        "Massport", "Manchester Transit Authority", "Nashua Transit System", "COAST", "VTA", "The WAVE", "PVTA", "FRTA"])
        // Greater Hartford and Western Massachusetts: the train operators of each (the Hartford Line's and Amtrak's), no subway or
        // ferry, and the bus companies with stops there (PVTA's reach Enfield, MART's Orange)
        for area in [MetroArea.greaterHartford, .westernMassachusetts] {
            XCTAssertEqual(ModeCoverage.credits(for: .train, in: area), ["CTrail", "Amtrak"], area.rawValue)
            XCTAssertEqual(ModeCoverage.credits(for: .subway, in: area), [], area.rawValue)
            XCTAssertEqual(ModeCoverage.credits(for: .ferry, in: area), [], area.rawValue)
        }
        XCTAssertEqual(ModeCoverage.credits(for: .bus, in: .greaterHartford), ["CTtransit", "PVTA", "NECTD", "WRTD", "NWCTD"])
        XCTAssertEqual(ModeCoverage.credits(for: .bus, in: .westernMassachusetts), ["MART", "PVTA", "FRTA", "BRTA"])
        // The boats around Boston and to the islands, after the MBTA's; the National Park Service once for its two
        XCTAssertEqual(ModeCoverage.credits(for: .ferry, in: .greaterBoston),
                       ["MBTA (MassDOT)", "Hy-Line Cruises", "Bay State Cruise Company", "Block Island Ferry", "Cuttyhunk Ferry Company",
                        "Patriot Party Boats", "Freedom Cruise Line", "Vineyard Fast Ferry", "National Park Service"])
        for mode in [TransitSystem.subway, .train, .ferry] {
            XCTAssertEqual(ModeCoverage.credits(for: mode, in: .greaterBoston).first, "MBTA (MassDOT)", "\(mode)")
        }
        XCTAssertEqual(ModeCoverage.credits(for: .train, in: .greaterBoston), ["MBTA (MassDOT)", "Amtrak"])
        // Every operator's credit is named in the full list of credits (DataCredits, which the docs are checked against)
        for op in AreaCatalog.shared.operators {
            guard let credit = op.credit else { continue }
            let short = credit.components(separatedBy: " (").first ?? credit
            XCTAssertTrue(DataCredits.downloaded.contains { $0.contains(short) } || DataCredits.bundled.contains(short)
                          || short == "Port Authority of New York and New Jersey" || short == "CTrail", "\(op.id): \(credit)")
        }
    }

    /// How It Works' own sentences (ModeCoverage.ownSentence): each is an operator in areas.json, of one mode, and shown only in the
    /// areas it runs in; the rest of each area's operators are only in the generated lines
    func testOwnSentencesOnlyWhereTheOperatorRuns() {
        XCTAssertEqual(Set(ModeCoverage.ownSentence).count, ModeCoverage.ownSentence.count)
        for id in ModeCoverage.ownSentence {
            XCTAssertNotNil(AreaCatalog.shared.operator(id), id)
            XCTAssertFalse(MetroArea.areas(ofOperator: id).isEmpty, id)
        }
        var shown: [String] = []
        for area in MetroArea.allCases {
            for mode in TransitSystem.modes {
                for id in ModeCoverage.ownSentences(for: mode, in: area) {
                    XCTAssertTrue(MetroArea.areas(ofOperator: id).contains(area), "\(id) in \(area.rawValue)")
                    shown.append(id)
                }
            }
        }
        // Every one is shown somewhere, once per area it runs in and under its own mode only
        XCTAssertEqual(Set(shown), Set(ModeCoverage.ownSentence.filter { !ModeCoverage.isTurnedOff($0) }))
        XCTAssertEqual(ModeCoverage.ownSentences(for: .subway, in: .newYork), ["subway", "path", "tram"])
        XCTAssertEqual(ModeCoverage.ownSentences(for: .bus, in: .newYork), ["mtaBus", "bus:SCT"])
        XCTAssertEqual(ModeCoverage.ownSentences(for: .train, in: .philadelphia), ["marc"])
        XCTAssertEqual(ModeCoverage.ownSentences(for: .ferry, in: .philadelphia), ["cml"])
        XCTAssertEqual(ModeCoverage.ownSentences(for: .ferry, in: .newYork), ["sol"])
        for mode in TransitSystem.modes {
            XCTAssertEqual(ModeCoverage.ownSentences(for: mode, in: .greaterBoston), [], "\(mode)")
        }
    }

    /// About's and How It Works' credits for one area: the station footer's credits of every mode there, each once, in mode order;
    /// every operator with a credit in areas.json is named in each area it runs in, and nowhere else
    func testCreditsInAnAreaAreItsOperators() {
        for area in MetroArea.allCases {
            let credits = ModeCoverage.credits(in: area)
            XCTAssertEqual(Set(credits).count, credits.count, area.rawValue)
            XCTAssertFalse(credits.isEmpty, area.rawValue)
            var expected: [String] = []
            for mode in TransitSystem.modes {
                for credit in ModeCoverage.credits(for: mode, in: area) where !expected.contains(credit) { expected.append(credit) }
            }
            XCTAssertEqual(credits, expected, area.rawValue)
            for op in AreaCatalog.shared.operators {
                guard let credit = op.credit, !op.id.hasPrefix(MetroArea.busOperatorID("")) else { continue }
                if ModeCoverage.isTurnedOff(op.id) { continue }
                if op.kinds[area.rawValue] != nil { XCTAssertTrue(credits.contains(credit), "\(op.id) in \(area.rawValue)") }
            }
        }
        // Together the areas name every operator's credit
        let all = Set(MetroArea.allCases.flatMap(ModeCoverage.credits(in:)))
        for op in AreaCatalog.shared.operators {
            if ModeCoverage.isTurnedOff(op.id) { continue }
            XCTAssertTrue(op.credit.map(all.contains) ?? true, op.id)
        }
        XCTAssertEqual(ModeCoverage.credits(in: .lehighValley), ["NJ Transit", "LANta", "Pocono Pony", "Warren County Transportation",
                                                                 "Trans-Bridge Lines"])
        // New York's start with the subway's: MTA's lines, PATH, NJ Transit's light rail, the tram
        XCTAssertEqual(ModeCoverage.credits(in: .newYork).prefix(4), ["MTA", "Port Authority of New York and New Jersey (PATH)", "NJ Transit",
                                                                      "RIOC"])
    }

    /// The line under the sidebar title: the kinds of vehicles a mode has in the start place's metro area, always in one order;
    /// all areas together for a place outside them. The popover's rows are in the same order
    func testKindsFollowTheMetroArea() {
        XCTAssertEqual(ModeCoverage.kinds(for: .subway, in: .newYork), [.subway, .lightRail, .tram])
        XCTAssertEqual(ModeCoverage.kinds(for: .subway, in: .philadelphia), [.subway, .trolley, .lightRail])
        XCTAssertEqual(ModeCoverage.kinds(for: .bus, in: .newYork), [.localBus, .expressBus])
        XCTAssertEqual(ModeCoverage.kinds(for: .bus, in: .philadelphia), [.localBus])
        XCTAssertEqual(ModeCoverage.kinds(for: .train, in: .newYork), [.commuterRail, .intercityRail])
        XCTAssertEqual(ModeCoverage.kinds(for: .train, in: .philadelphia), [.commuterRail, .intercityRail])
        XCTAssertEqual(ModeCoverage.kinds(for: .ferry, in: .newYork), [.passengerFerry])
        XCTAssertEqual(ModeCoverage.kinds(for: .ferry, in: .philadelphia), [.carFerry])
        XCTAssertEqual(ModeCoverage.kinds(for: .subway, in: .greaterBoston), [.subway, .trolley, .lightRail])
        XCTAssertEqual(ModeCoverage.kinds(for: .train, in: .greaterBoston), [.commuterRail, .intercityRail])
        // Block Island Ferry takes cars
        XCTAssertEqual(ModeCoverage.kinds(for: .ferry, in: .greaterBoston), [.passengerFerry, .carFerry])
        for mode in TransitSystem.modes {
            let together = ModeCoverage.kinds(for: mode, in: nil)
            XCTAssertEqual(Set(together), Set(MetroArea.allCases.flatMap { ModeCoverage.kinds(for: mode, in: $0) }), "\(mode)")
            XCTAssertEqual(together, VehicleKind.allCases.filter { together.contains($0) }, "\(mode)")
            for area in MetroArea.allCases {
                let ranks = ModeCoverage.running(for: mode, in: area, access: ModeCoverage.LiveAccess())
                    .map { row in row.kinds.compactMap { VehicleKind.allCases.firstIndex(of: $0) }.min() ?? -1 }
                XCTAssertEqual(ranks, ranks.sorted(), "\(mode), \(area)")
                XCTAssertFalse(ranks.contains(-1), "\(mode), \(area): an operator without a kind of vehicle")
            }
        }
        XCTAssertEqual(names(.subway, .newYork).prefix(3), ["NYC Subway", "Staten Island Railway", "PATH"])
        XCTAssertEqual(names(.subway, .philadelphia), ["SEPTA Metro", "PATCO", "River LINE"])
        XCTAssertEqual(names(.train, .philadelphia).last, "Amtrak")
        XCTAssertEqual(names(.ferry, .philadelphia), ["Cape May\u{2013}Lewes Ferry"])
        // README's data table counts each operator once
        XCTAssertEqual(ModeCoverage.operatorCount(for: .bus), 2 + ModeCoverage.localBuses.count)
        XCTAssertEqual(ModeCoverage.operatorCount(for: .train), names(.train, nil).count)
        XCTAssertEqual(ModeCoverage.operatorCount(for: .ferry), names(.ferry, nil).count - NoTimesStations.agencies(for: .ferry).count)
    }

    /// Shore Line East comes in Amtrak's package but is a line of its own: one row in New York's train list
    func testShoreLineEastIsATrainLine() {
        XCTAssertEqual(names(.train, .newYork).filter { $0 == "CTrail Shore Line East" }.count, 1)
        XCTAssertFalse(names(.train, .philadelphia).contains(ModeCoverage.shoreLineEast))
        XCTAssertFalse(names(.bus, nil).contains(ModeCoverage.shoreLineEast))
        // And a row of its own under New York's train sources in Settings, not Philadelphia's
        XCTAssertTrue(ModeCoverage.listsShoreLineEast(in: .newYork))
        XCTAssertFalse(ModeCoverage.listsShoreLineEast(in: .philadelphia))
        XCTAssertTrue(ModeCoverage.listsShoreLineEast(in: nil))
    }

    func testNothingStaleIsDescribed() {
        let known = Set(FerryFeed.Source.allCases.map(\.name) + RegionalBusFeed.all.map(\.name)
                        + ModeCoverage.subwayLines + ModeCoverage.lightRailLines + ModeCoverage.mtaBusKinds
                        + [ModeCoverage.statenIslandRailway, ModeCoverage.tram, ModeCoverage.shoreLineEast]
                        + NoTimesStations.agencies.map(\.name) + [ModeCoverage.privateCommuterBuses])
        for mode in TransitSystem.modes {
            for name in names(mode, nil) {
                XCTAssertTrue(known.contains(name), "\(name) in the description is not a current source")
            }
            XCTAssertFalse(ModeCoverage.kinds(for: mode, in: nil).isEmpty)
        }
    }

    /// The popover's row after the operators names the ones whose stations are listed without times, the same ones as the station
    /// list, in its order, and only those with a station in the metro area: AirTrain JFK with New York's Subway, the boat
    /// operators with New York's and Greater Boston's Ferry, none with Train. Bus ends with the private commuter buses, which aren't in the app at all.
    /// Neither row has a "Live" or "Timetable" tag
    func testWithoutTimesRowsMatchTheStationList() {
        for mode in TransitSystem.modes {
            let agencies = NoTimesStations.agencies(for: mode)
            let stations = NoTimesStations.stations(for: mode)
            XCTAssertEqual(Set(agencies), Set(stations.map(\.agency)), "\(mode)")
            let all = ModeCoverage.operators(for: mode, in: nil).filter { $0.group == ModeCoverage.withoutTimesGroup }
            XCTAssertEqual(all, agencies.isEmpty ? [] : [ModeCoverage.Operator(group: ModeCoverage.withoutTimesGroup, names: agencies.map(\.name))], "\(mode)")
            var listed = Set<String>()
            for area in MetroArea.allCases {
                let rows = ModeCoverage.operators(for: mode, in: area)
                let here = rows.first { $0.group == ModeCoverage.withoutTimesGroup }
                let expected = agencies.filter { agency in stations.contains { $0.agency == agency && MetroArea.of($0.coordinate) == area } }.map(\.name)
                XCTAssertEqual(here?.names ?? [], expected, "\(mode), \(area)")
                XCTAssertNil(here?.live)
                if mode.mode != .bus, let here { XCTAssertEqual(rows.last, here, "\(mode), \(area)") }
                listed.formUnion(expected)
            }
            XCTAssertEqual(listed, Set(agencies.map(\.name)), "\(mode): a station without times is outside every metro area")
        }
        XCTAssertEqual(NoTimesStations.agencies(for: .subway).map(\.name), ["AirTrain JFK"])
        XCTAssertEqual(NoTimesStations.agencies(for: .ferry).map(\.name),
                       ["Fire Island Ferries", "Sayville Ferry Service", "Davis Park Ferry", "Cross Sound Ferry",
                        "Bridgeport & Port Jefferson Ferry", "North Ferry", "South Ferry", "Governors Island Ferry",
                        "Steamship Authority", "Island Queen", "City Cruises Provincetown Ferry", "Jamestown Newport Ferry",
                        "Prudence & Bay Islands Transport", "Chappy Ferry", "Captain John Boats", "Block Island Express", "Viking Fleet"])
        XCTAssertEqual(ModeCoverage.operators(for: .ferry, in: .greaterBoston).last?.names,
                       ["Steamship Authority", "Island Queen", "City Cruises Provincetown Ferry", "Jamestown Newport Ferry",
                        "Prudence & Bay Islands Transport", "Chappy Ferry", "Captain John Boats", "Block Island Express", "Viking Fleet"])
        // The boats to Block Island leave from New London and Montauk, in the New York area, and get in at Block Island, in Greater Boston's
        XCTAssertEqual(ModeCoverage.operators(for: .ferry, in: .newYork).last?.names,
                       ["Fire Island Ferries", "Sayville Ferry Service", "Davis Park Ferry", "Cross Sound Ferry",
                        "Bridgeport & Port Jefferson Ferry", "North Ferry", "South Ferry", "Governors Island Ferry",
                        "Block Island Express", "Viking Fleet"])
        XCTAssertTrue(NoTimesStations.agencies(for: .train).isEmpty)
        XCTAssertTrue(NoTimesStations.agencies(for: .bus).isEmpty)
        XCTAssertFalse(names(.subway, .philadelphia).contains("AirTrain JFK"))
        for area in MetroArea.allCases {
            XCTAssertEqual(ModeCoverage.operators(for: .bus, in: area).last, ModeCoverage.Operator(names: [ModeCoverage.privateCommuterBuses]))
        }
    }

    /// One fact for each NJ Transit operator says whether the account makes its times live (liveWithAccount). The sidebar
    /// popover's marks, the footer's line and what's downloaded all follow it: with the account, without it, and with one NJ
    /// Transit refused (the app then passes "no account")
    func testNJTransitLiveFollowsOneFactPerOperator() {
        let rail = FerryFeed.Source.njTransitRail, light = FerryFeed.Source.njTransitLightRail, bus = RegionalBusFeed.njTransit
        XCTAssertTrue(rail.liveWithAccount)
        XCTAssertFalse(light.liveWithAccount)
        XCTAssertTrue(bus.liveWithAccount)
        // All three still use the account (their rows in Settings point to the NJ Transit account), and no one else does
        XCTAssertTrue(rail.needsAccount && light.needsAccount && bus.needsAccount)
        XCTAssertEqual(FerryFeed.Source.allCases.filter(\.liveWithAccount), [.njTransitRail])
        XCTAssertEqual(RegionalBusFeed.all.filter(\.liveWithAccount), [bus])
        func popover(_ mode: TransitSystem, _ area: MetroArea, _ name: String, _ access: ModeCoverage.LiveAccess) -> Bool? {
            ModeCoverage.operators(for: mode, in: area, access: access).first { $0.names.contains(name) }?.live
        }
        func footer(_ mode: TransitSystem, _ area: MetroArea, _ name: String, _ access: ModeCoverage.LiveAccess) -> ModeCoverage.LiveState? {
            ModeCoverage.liveNames(for: mode, in: area, access: access).first { $0.name == name }?.state
        }
        let rows: [(mode: TransitSystem, area: MetroArea, name: String, live: Bool)] = [
            (.train, .newYork, "NJ Transit Rail", rail.liveWithAccount),
            (.train, .philadelphia, "NJ Transit Rail", rail.liveWithAccount),
            (.subway, .newYork, "Hudson-Bergen Light Rail", light.liveWithAccount),
            (.subway, .newYork, "Newark Light Rail", light.liveWithAccount),
            (.subway, .philadelphia, "River LINE", light.liveWithAccount),
            (.bus, .newYork, "NJ Transit", bus.liveWithAccount),
            (.bus, .philadelphia, "NJ Transit", bus.liveWithAccount),
        ]
        let with = ModeCoverage.LiveAccess(njTransitAccount: true)
        // No account, or one NJ Transit refused: the app passes the same
        let without = ModeCoverage.LiveAccess()
        for row in rows {
            let name = "\(row.name), \(row.area)"
            XCTAssertEqual(popover(row.mode, row.area, row.name, with), row.live, name)
            XCTAssertEqual(footer(row.mode, row.area, row.name, with), row.live ? .live : .timetable, name)
            XCTAssertEqual(popover(row.mode, row.area, row.name, without), false, name)
            // The footer asks for the account only where it would give live times
            XCTAssertEqual(footer(row.mode, row.area, row.name, without), row.live ? .needsKey : .timetable, name)
        }
        // An account the bus API refused (the app then lists NJ Transit among the buses not downloading): live data that isn't
        // coming now, as for any bus company whose live data fails
        let refusedForBuses = ModeCoverage.LiveAccess(njTransitAccount: true, failedBuses: [bus.code])
        XCTAssertEqual(footer(.bus, .newYork, "NJ Transit", refusedForBuses), .notNow)
        XCTAssertEqual(popover(.bus, .newYork, "NJ Transit", refusedForBuses), false)
        // What's downloaded follows the same fact: live data only for an operator the account makes live, and only with the account
        XCTAssertEqual(bus.canGetRealtime(hasAccount: true, hasSuffolkKey: true), bus.liveWithAccount)
        XCTAssertTrue(bus.canGetRealtime(hasAccount: true, hasSuffolkKey: false))
        XCTAssertFalse(bus.canGetRealtime(hasAccount: false, hasSuffolkKey: true))
        XCTAssertTrue(bus.canBeLive)
        XCTAssertEqual(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:1"], hasAccount: true, hasSuffolkKey: true), [bus])
        XCTAssertTrue(RegionalBusFeed.realtimeFeeds(stationIDs: ["njb:1"], hasAccount: false, hasSuffolkKey: true).isEmpty)
        // NJ Transit's buses keep their own row in Settings: they aren't one of the companies that publish no live data
        XCTAssertTrue(bus.hasRealtime)
        // Every company with live data (free, with a key or with the account) can be live
        XCTAssertEqual(RegionalBusFeed.all.filter { $0.canBeLive != $0.hasRealtime }.map(\.code), [])
    }

    /// "Live" or "Timetable" after an operator says where its times come from now: the user's own keys and account count, and a
    /// bus company whose live data isn't downloading goes with the timetable ones
    func testLiveFollowsKeysAndAccount() {
        func live(_ mode: TransitSystem, _ area: MetroArea, _ name: String, _ access: ModeCoverage.LiveAccess = ModeCoverage.LiveAccess()) -> Bool? {
            ModeCoverage.operators(for: mode, in: area, access: access).first { $0.names.contains(name) || $0.group == name }?.live
        }
        let account = ModeCoverage.LiveAccess(njTransitAccount: true)
        XCTAssertEqual(live(.subway, .newYork, "NYC Subway"), true)
        XCTAssertEqual(live(.subway, .newYork, ModeCoverage.tram), false)
        XCTAssertEqual(live(.subway, .newYork, "Newark Light Rail"), false)
        // The account makes NJ Transit's trains and buses live (liveWithAccount): its light rail stays the timetable's
        XCTAssertEqual(live(.subway, .newYork, "Newark Light Rail", account), false)
        XCTAssertEqual(live(.subway, .philadelphia, "River LINE", account), false)
        XCTAssertEqual(live(.subway, .philadelphia, "PATCO", account), false)
        XCTAssertEqual(live(.train, .newYork, "NJ Transit Rail"), false)
        XCTAssertEqual(live(.train, .newYork, "NJ Transit Rail", account), true)
        XCTAssertEqual(live(.train, .newYork, ModeCoverage.shoreLineEast, account), false)
        // MTA's buses have no timetable: no tag without the user's key
        XCTAssertNil(live(.bus, .newYork, "MTA"))
        XCTAssertEqual(live(.bus, .newYork, "MTA", ModeCoverage.LiveAccess(mtaBusKey: true)), true)
        XCTAssertEqual(live(.bus, .philadelphia, "NJ Transit"), false)
        XCTAssertEqual(live(.bus, .philadelphia, "NJ Transit", account), true)
        XCTAssertEqual(live(.bus, .newYork, "Suffolk County Transit"), false)
        XCTAssertEqual(live(.bus, .newYork, "Suffolk County Transit", ModeCoverage.LiveAccess(suffolkKey: true)), true)
        let beeLine = RegionalBusFeed.all.first { $0.name == "Bee-Line" }
        XCTAssertEqual(live(.bus, .newYork, "Bee-Line"), true)
        XCTAssertEqual(live(.bus, .newYork, "Bee-Line", ModeCoverage.LiveAccess(failedBuses: [beeLine?.code ?? ""])), false)
        // The local bus companies share two rows however many there are
        for area in MetroArea.allCases {
            let local = ModeCoverage.operators(for: .bus, in: area).filter { $0.kinds == [.localBus] && $0.names != [RegionalBusFeed.njTransit.name] }
            XCTAssertEqual(local.map(\.live), [true, false], "\(area)")
        }
    }

    /// The footer and Plan a Trip name only the operators of the station or results in front of you: found from the stations'
    /// own IDs and routes, each once, in the order found
    func testOperatorsAtTheStations() {
        let subway = ModeCoverage.subwayID, sir = ModeCoverage.statenIslandRailwayID
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["127"], routes: ["1", "2", "3"], mode: .subway), [subway])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["S31"], routes: ["SI"], mode: .subway), [sir])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["127", "path:26722"], routes: ["1", "PATH-859"], mode: .subway),
                       [subway, FerryFeed.Source.path.rawValue])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: [RooseveltIslandTram.islandStationID], routes: [], mode: .subway),
                       [ModeCoverage.tramID])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["400001"], routes: ["M15"], mode: .bus), [ModeCoverage.mtaBusID])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["mbs:place-pktrm"], routes: ["mbs:Red"], mode: .subway),
                       [FerryFeed.Source.mbtaSubway.rawValue])
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: ["127", "128"], routes: ["1"], mode: .subway), [subway], "Each once")
        XCTAssertEqual(ModeCoverage.operatorIDs(atStations: [], routes: [], mode: .train), [])
    }

    /// The live data line and the credits for those operators only, from the same lists as the whole area's
    func testLiveNamesAndCreditsForTheOperatorsInFront() {
        let subway = ModeCoverage.subwayID, path = FerryFeed.Source.path.rawValue
        XCTAssertEqual(ModeCoverage.liveNames(for: .subway, operators: [subway], routes: []).map(\.name), ["NYC Subway"])
        XCTAssertEqual(Set(ModeCoverage.liveNames(for: .subway, operators: [subway, path], routes: []).map(\.name)), ["NYC Subway", "PATH"])
        XCTAssertEqual(ModeCoverage.liveNames(for: .bus, operators: [ModeCoverage.mtaBusID], routes: []).map(\.name), ["MTA"])
        XCTAssertEqual(ModeCoverage.credits(for: .subway, operators: [subway]), ["MTA"])
        XCTAssertEqual(ModeCoverage.credits(for: .subway, operators: [subway, ModeCoverage.statenIslandRailwayID]), ["MTA"], "Each once")
        XCTAssertEqual(ModeCoverage.credits(for: .subway, operators: [subway, path]),
                       ["MTA", "Port Authority of New York and New Jersey (PATH)"])
        XCTAssertEqual(ModeCoverage.credits(for: .bus, operators: [subway]), [], "Another mode's operator isn't credited")
    }

    /// Outside every area, Settings' data source page and the map's Whole Map open at the area of the nearest county
    func testNearestArea() {
        XCTAssertEqual(MetroArea.nearest(to: Coordinate(latitude: 40.7580, longitude: -73.9855)), .newYork)
        XCTAssertEqual(MetroArea.nearest(to: Coordinate(latitude: 42.3551, longitude: -71.0656)), .greaterBoston)
        // At sea south of Long Island: no area, the nearest county is New York's
        let atSea = Coordinate(latitude: 40.30, longitude: -72.50)
        XCTAssertNil(MetroArea.of(atSea))
        XCTAssertEqual(MetroArea.nearest(to: atSea), .newYork)
    }

    /// An operator the source list can turn off (SourceList), as areas.json and the popover know it, before it is turned off: its
    /// id, then those of the ones that come in its package (ModeCoverage.comesWith), and all their names
    private func operatorToTurnOff(_ listID: String) -> (ids: [String], mode: TransitSystem, names: [String])? {
        if let source = FerryFeed.Source(rawValue: listID) {
            let ids = [listID] + ModeCoverage.comesWith.filter { $0.value == source }.keys.sorted()
            return (ids, source.system.mode, ids.flatMap { ModeCoverage.names(ofOperator: $0, routes: []) })
        }
        guard let feed = RegionalBusFeed.builtIn.first(where: { $0.listID == listID }) else { return nil }
        return ([MetroArea.busOperatorID(feed.code)], .bus, [feed.name])
    }

    /// The built-in list with these operators turned off, put in use
    private func turnOff(_ listIDs: [String]) {
        var list = SourceList.builtIn
        for id in listIDs {
            guard let i = list.operators.firstIndex(where: { $0.id == id }) else { return XCTFail("\(id) isn't in the list") }
            list.operators[i].enabled = false
        }
        XCTAssertNoThrow(try list.validate(), "\(listIDs)")
        XCTAssertTrue(SourceList.use(list), "\(listIDs)")
    }

    /// The rows of a mode's popover that are about departures (not the stations without times, not the note on what isn't included)
    private func departureRows(_ mode: TransitSystem, _ area: MetroArea?) -> [ModeCoverage.Operator] {
        ModeCoverage.operators(for: mode, in: area).filter { !$0.kinds.isEmpty }
    }

    /// An operator the source list turns off is gone from all that is made from the data, and the rest is made as before: the
    /// sidebar header's popover and the line under the title, the station footer's live data and "Data: …" lines, Settings' data
    /// source rows, How It Works' own sentences and About's credits; no row is left empty. Each one that can be turned off, one at
    /// a time; then, where a metro area has few enough of a mode, all of them, so the area has none of it
    func testAnOperatorTurnedOffIsLeftOut() throws {
        defer { SourceList.reset() }
        // Every operator in areas.json has a download of its own (one the list can turn off), ships inside the app, or comes in
        // another one's package: Shore Line East's trains are in Amtrak's
        let insideTheApp = [ModeCoverage.subwayID, ModeCoverage.statenIslandRailwayID, ModeCoverage.tramID, ModeCoverage.mtaBusID]
        for op in AreaCatalog.shared.operators {
            let own = FerryFeed.Source(rawValue: op.id) != nil || op.id.hasPrefix(MetroArea.busOperatorID("")) || insideTheApp.contains(op.id)
            XCTAssertNotEqual(own, ModeCoverage.comesWith[op.id] != nil, op.id)
        }
        XCTAssertEqual(ModeCoverage.comesWith[ModeCoverage.shoreLineEastID], .amtrakNY)
        XCTAssertTrue(FerryFeed.Source.amtrakNY.wants(agency: FerryFeed.shoreLineEast.agency))
        let canTurnOff = SourceList.known.filter(\.canTurnOff).map(\.id)
        XCTAssertGreaterThan(canTurnOff.count, 10)
        let areas: [MetroArea?] = MetroArea.allCases + [nil]
        for listID in canTurnOff {
            SourceList.reset()
            let op = try XCTUnwrap(operatorToTurnOff(listID), listID)
            let kindsBefore = areas.map { ModeCoverage.kinds(for: op.mode, in: $0) }
            // Its credit, when no other operator goes by it
            let credit = AreaCatalog.shared.operator(op.ids[0])?.credit ?? op.names.first
            let creditShared = AreaCatalog.shared.operators.contains { !op.ids.contains($0.id) && ($0.credit ?? $0.id) == credit }
                || RegionalBusFeed.builtIn.contains { !op.ids.contains(MetroArea.busOperatorID($0.code)) && $0.name == credit }
            let ownCredit = creditShared ? nil : credit
            turnOff([listID])
            for (area, before) in zip(areas, kindsBefore) {
                let at = "\(listID) turned off, \(area?.rawValue ?? "all areas")"
                let rows = ModeCoverage.operators(for: op.mode, in: area)
                XCTAssertFalse(rows.contains { $0.names.isEmpty }, at)
                XCTAssertFalse(rows.contains { $0.group != ModeCoverage.withoutTimesGroup && $0.names.contains(where: op.names.contains) }, at)
                XCTAssertFalse(ModeCoverage.liveNames(for: op.mode, in: area).contains { op.names.contains($0.name) }, at)
                let kinds = ModeCoverage.kinds(for: op.mode, in: area)
                XCTAssertTrue(Set(kinds).isSubset(of: before), at)
                XCTAssertEqual(kinds.isEmpty, departureRows(op.mode, area).isEmpty, at)
                let credits = ModeCoverage.credits(for: op.mode, in: area)
                XCTAssertFalse(credits.contains(""), at)
                XCTAssertEqual(Set(credits).count, credits.count, at)
                if let ownCredit { XCTAssertFalse(credits.contains(ownCredit), at) }
                if let area {
                    XCTAssertFalse(ModeCoverage.ownSentences(for: op.mode, in: area).contains(where: op.ids.contains), at)
                    if let ownCredit { XCTAssertFalse(ModeCoverage.credits(in: area).contains(ownCredit), at) }
                }
            }
            // The footer of a station of its own, were one still shown
            XCTAssertEqual(ModeCoverage.credits(for: op.mode, operators: op.ids), [], listID)
            XCTAssertEqual(ModeCoverage.liveNames(for: op.mode, operators: op.ids, routes: []), [], listID)
            // Settings' data source rows
            XCTAssertFalse(TransitSystem.allCases.flatMap { FerryFeed.Source.cases(for: $0) }.contains { $0.rawValue == listID }, listID)
            XCTAssertFalse(RegionalBusFeed.all.contains { $0.listID == listID }, listID)
        }

        // A metro area left with none of a mode: the first where every operator of the mode can be turned off, as many as a list
        // may turn off at once
        SourceList.reset()
        let all = canTurnOff.compactMap { id in operatorToTurnOff(id).map { (listID: id, op: $0) } }
        var emptied: (mode: TransitSystem, area: MetroArea, listIDs: [String])?
        search: for area in MetroArea.allCases {
            for mode in TransitSystem.modes where !departureRows(mode, area).isEmpty {
                let here = AreaCatalog.shared.operators.filter { ModeCoverage.mode(ofOperator: $0.id) == mode && $0.kinds[area.rawValue] != nil }
                let off = all.filter { turnable in turnable.op.mode == mode && here.contains { turnable.op.ids.contains($0.id) } }
                guard here.allSatisfy({ h in off.contains { $0.op.ids.contains(h.id) } }), off.count <= SourceList.maxTurnedOff else { continue }
                emptied = (mode, area, off.map(\.listID))
                break search
            }
        }
        let (mode, area, listIDs) = try XCTUnwrap(emptied)
        turnOff(listIDs)
        let at = "\(listIDs) turned off, \(area.rawValue)"
        XCTAssertEqual(departureRows(mode, area), [], at)
        XCTAssertFalse(ModeCoverage.operators(for: mode, in: area).contains { $0.names.isEmpty }, at)
        XCTAssertEqual(ModeCoverage.kinds(for: mode, in: area), [], at)
        XCTAssertEqual(ModeCoverage.liveNames(for: mode, in: area), [], at)
        XCTAssertEqual(ModeCoverage.credits(for: mode, in: area), [], at)
        XCTAssertEqual(ModeCoverage.ownSentences(for: mode, in: area), [], at)
        // The other modes there are as they were
        for other in TransitSystem.modes where other != mode {
            let rows = ModeCoverage.operators(for: other, in: area)
            SourceList.reset()
            XCTAssertEqual(rows, ModeCoverage.operators(for: other, in: area), "\(other), \(area.rawValue)")
            turnOff(listIDs)
        }
    }
}
