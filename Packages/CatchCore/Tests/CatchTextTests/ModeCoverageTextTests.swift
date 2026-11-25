import XCTest
@testable import CatchText
import TransitCore

/// The station footer's lines, the map window's source line, How It Works' service area and source sections and the credits in
/// About are made from areas.json (see ModeCoverageTests), so no sentence names the areas or lists the operators. How It
/// Works keeps a sentence of their own only for the few operators that do something differently (ModeCoverage.ownSentence).
final class ModeCoverageTextTests: XCTestCase {
    private func includes(_ prefix: String) -> String {
        AppText.allKeys.first { $0.hasPrefix(prefix) } ?? ""
    }

    /// How It Works' source sections name each area's operators from the data, in the station footer's lines (one per kind of
    /// times): every operator is named in each area it runs in, the sentences that named one operator after another are gone, and
    /// the sentences of the few with one of their own are keys translated in every language
    func testHowItWorksNamesEachAreasOperatorsFromTheData() {
        for area in MetroArea.allCases {
            for mode in TransitSystem.modes {
                let named = Set(ModeCoverage.liveNames(for: mode, in: area).map(\.name))
                for row in ModeCoverage.operators(for: mode, in: area) where !row.kinds.isEmpty {
                    let names = row.group.map { [$0] } ?? row.names
                    for name in names {
                        XCTAssertTrue(named.contains(name), "\(area.rawValue) \(mode.rawValue): \(name) isn't named")
                    }
                }
                // The kinds of vehicles and the operators go together: an area has a mode's lines exactly when it has its vehicles
                XCTAssertEqual(named.isEmpty, ModeCoverage.kinds(for: mode, in: area).isEmpty, "\(area.rawValue) \(mode.rawValue)")
            }
        }
        for key in ["Live data: %@.", "Live once you add your key or account: %@.", "Timetable only: %@.", "Estimated from its hours: %@.",
                    "No data for this transit system in this area yet.", "Map and stations are checked for updates on the 1st of each month.",
                    "No key or account needed in this area.", "Data Source…"] {
            XCTAssertTrue(AppText.allKeys.contains(key), key)
        }
        // The sentences that went through the operators one by one, for every area at once
        for gone in ["SEPTA Metro (Philadelphia's subway", "PATCO (Philadelphia and South Jersey)", "MBTA subway (Boston's",
                     "NJ Transit light rail (Hudson-Bergen", "NJ Transit buses: timetables", "%@: timetables plus free live data",
                     "NICE (Nassau)", "Long Island Rail Road and Metro-North Railroad (MTA)", "SEPTA Regional Rail (Philadelphia)",
                     "MBTA Commuter Rail (Boston)", "NJ Transit Rail: timetables", "Amtrak, the CTrail Hartford Line",
                     "NYC Ferry: timetables", "NY Waterway: timetables", "Staten Island Ferry (NYC DOT)", "Seastreak: timetable",
                     "MBTA ferries (Boston Harbor)", "The MTA Bus Time key, the NJ Transit developer account",
                     "Everything else is downloaded from each operator's public data: %@."] {
            XCTAssertFalse(AppText.allKeys.contains { $0.contains(gone) }, gone)
        }
        // The credits name the area and its operators, and where every area's are
        XCTAssertTrue(AppText.allKeys.contains { $0.contains("Operators in this area (%2$@): %3$@.") })
        for language in AppLanguage.allCases where language != .english {
            let table = Translations.table(for: language)
            for key in AppText.allKeys where key.hasPrefix("The subway stations, subway map") || key.hasPrefix("Below are the sources")
                || key.hasPrefix("They're free and each person uses their own") {
                let text = table[key] ?? ""
                XCTAssertFalse(text.isEmpty, "\(language.rawValue): \(key)")
                for placeholder in ["%1$@", "%2$@", "%3$@"] where key.contains(placeholder) {
                    XCTAssertEqual(text.components(separatedBy: placeholder).count, 2, "\(language.rawValue): \(placeholder) in \(key)")
                }
            }
        }
    }

    /// No sentence names a metro area's operators or lists the areas: the old ones are gone, and the generated lines' parts are keys
    /// with every language's translation keeping their placeholders
    func testNoSentenceListsTheAreas() {
        for key in AppText.allKeys {
            XCTAssertFalse(key.contains("New York and Philadelphia"), key)
            XCTAssertFalse(key.hasPrefix("Includes ") || key.hasPrefix("Area: "), key)
        }
        for key in ["%1$@: %2$@.", "Live data: %@.", "Live once you add your key or account: %@.", "Timetable only: %@.",
                    "Estimated from its hours: %@.", "%@: timetable (live data isn't available right now).",
                    "Data: %@. This app is not affiliated with them.", "Data from the transit operators listed in Settings → Data source."] {
            XCTAssertTrue(AppText.allKeys.contains(key), key)
        }
        // Lists name only what's in front of you, all of it: no "and N more", and the map names no operators
        for key in ["%1$@ and %2$@ more", "Data from %@.", "Lines not in the new data: %1$@ and %2$@ more."] {
            XCTAssertFalse(AppText.allKeys.contains(key), key)
        }
        // Status counts the lines new data leaves out when they are more than a few (DataChangeLog.Entry.linesGone)
        XCTAssertTrue(AppText.allKeys.contains("Not in the new data: %@ lines."))
    }

    /// Shore Line East and the Hartford Line are both CTrail's timetable-only lines: no sentence names them by hand any more, and
    /// How It Works names them together, from the data, in the same line wherever both run
    func testShoreLineEastIsNamedWithTheHartfordLine() {
        XCTAssertTrue(AppText.allKeys.filter { $0.contains("Hartford Line") || $0.contains(FerryFeed.shoreLineEast.name) }.isEmpty)
        var both = 0
        for area in MetroArea.allCases {
            let names = ModeCoverage.liveNames(for: .train, in: area)
            guard let shoreLine = names.first(where: { $0.name == ModeCoverage.shoreLineEast }) else { continue }
            let hartford = names.first { $0.name.hasSuffix("Hartford Line") }
            XCTAssertEqual(shoreLine.state, .timetable, area.rawValue)
            XCTAssertEqual(hartford?.state, .timetable, area.rawValue)
            both += 1
        }
        XCTAssertGreaterThan(both, 0)
    }

    /// The sidebar header's popover passes every name and group through t(): each one is a key (so it's translated) or an operator's
    /// own name, which stays in English in every language. The line under the sidebar title is made of the kinds of vehicles: each
    /// is a key, translated in every language
    func testCoverageNamesAreKeysOrOperatorNames() {
        let keys = Set(AppText.allKeys)
        var operatorNames = Set(FerryFeed.Source.allCases.flatMap { [$0.name, $0.shortName] })
        operatorNames.formUnion(RegionalBusFeed.all.map(\.name))
        operatorNames.formUnion(ModeCoverage.lightRailLines)
        operatorNames.formUnion([ModeCoverage.statenIslandRailway, ModeCoverage.tram, "MTA", "Select Bus Service", "Hartford Line",
                                 FerryFeed.shoreLineEast.name, ModeCoverage.shoreLineEast])
        // The operators whose stations are listed without times keep their own names too
        operatorNames.formUnion(NoTimesStations.agencies.flatMap { [$0.name, $0.shortName] })
        for mode in TransitSystem.modes {
            var names: [String] = []
            for row in ModeCoverage.operators(for: mode, in: nil) {
                names += row.names
                if let group = row.group { names.append(group) }
            }
            for name in names {
                XCTAssertTrue(keys.contains(name) || operatorNames.contains(name), "\(mode): \"\(name)\" is neither a key nor an operator's name")
            }
        }
        for kind in VehicleKind.allCases {
            XCTAssertTrue(keys.contains(kind.nameKey), "\(kind) has no text")
            for language in AppLanguage.allCases where language != .english {
                XCTAssertNotNil(Translations.table(for: language)[kind.nameKey], "\(language.rawValue): \(kind.nameKey)")
            }
        }
        let zh = AppText(language: .chineseSimplified)
        XCTAssertNotEqual(zh.t("NYC Subway"), "NYC Subway")
        XCTAssertNotEqual(zh.t("Commuter Rail"), "Commuter Rail")
        XCTAssertNotEqual(zh.t(ModeCoverage.withoutTimesGroup), ModeCoverage.withoutTimesGroup)
        XCTAssertNotEqual(zh.t(ModeCoverage.privateCommuterBuses), ModeCoverage.privateCommuterBuses)
    }

    /// A station without times: the same sentence with only the operator's name changed, and how often it runs only where the
    /// operator's website says so ("boats" for the ferries). Every language keeps the operator's name and the numbers as they are
    func testStationsWithoutTimesText() throws {
        let en = AppText(language: .english)
        let jamaica = try XCTUnwrap(NoTimesStations.station(id: "notimes:airtrain-jfk:jamaica"))
        let greenport = try XCTUnwrap(NoTimesStations.station(id: "notimes:north-ferry:greenport"))
        let bayShore = try XCTUnwrap(NoTimesStations.station(id: "notimes:fire-island-ferries:bay-shore"))
        XCTAssertEqual(en.noTimesHeadway(jamaica), "Its website says trains run every 5\u{2013}15 minutes.")
        XCTAssertEqual(en.noTimesHeadway(greenport), "Its website says boats run every 8\u{2013}15 minutes.")
        XCTAssertNil(en.noTimesHeadway(bayShore))
        XCTAssertEqual(en.noTimesReason(bayShore),
                       "Fire Island Ferries doesn't publish its times in a form Catch My Train can use, so departures can't be shown here. "
                       + "Check the operator's website or an online map before you go.")
        for language in AppLanguage.allCases {
            let l = AppText(language: language)
            XCTAssertTrue(l.noTimesReason(jamaica).contains("AirTrain JFK"), language.rawValue)
            XCTAssertTrue(l.noTimesHeadway(jamaica)?.contains("5\u{2013}15") == true, language.rawValue)
            XCTAssertNotEqual(l.t("Its website says trains run every %@ minutes."), l.t("Its website says boats run every %@ minutes."),
                              language.rawValue)
        }
    }
}
