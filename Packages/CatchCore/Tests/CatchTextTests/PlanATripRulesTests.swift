import XCTest

/// Rules read from the app's source for Plan a Trip's window: what stops its search, and how it keeps the map it doesn't show
final class PlanATripRulesTests: XCTestCase {
    /// Plan a Trip's search stops only when its window closes, not when a new Text size makes the window's contents anew: the new
    /// contents appear before the old ones disappear, so stopping it as they disappear left the open window's search stopped
    /// ("Loading train times…" until the window was closed and opened). release() is called once, outside the window's .id
    func testPlanATripStopsOnlyWhenItsWindowCloses() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Views").path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        func code(_ line: Substring) -> Bool { !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        var found: [String] = []
        let walker = FileManager.default.enumerator(atPath: app.path)
        while let path = walker?.nextObject() as? String {
            guard path.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where code(line) && line.contains("planner.release()") {
                found.append("App/\(path):\(number + 1)")
            }
        }
        XCTAssertEqual(found, ["App/CatchMyTrainApp.swift:\(try lineOfRelease(app))"],
                       "Plan a Trip's search is stopped in one place only, where its window closes: \(found)")
        let appFile = try String(contentsOf: app.appendingPathComponent("CatchMyTrainApp.swift"), encoding: .utf8)
        let start = try XCTUnwrap(appFile.range(of: "PlannerWindowView(planner: planner)"), "Plan a Trip's window wasn't found")
        let rest = appFile[start.lowerBound...]
        let window = rest[..<(rest.range(of: "\n        }\n")?.upperBound ?? rest.endIndex)]
        let id = try XCTUnwrap(window.range(of: ".id(transit.textSize)"), "Plan a Trip's window has no .id(transit.textSize) any more")
        let release = try XCTUnwrap(window.range(of: ".onDisappear { planner.release() }"),
                                    "Plan a Trip's search isn't stopped where its window closes")
        XCTAssertLessThan(id.lowerBound, release.lowerBound, "Plan a Trip's search is stopped outside the window's .id, not inside it")
    }

    /// The line of CatchMyTrainApp.swift that stops Plan a Trip's search (for the message above)
    private func lineOfRelease(_ app: URL) throws -> Int {
        let text = try String(contentsOf: app.appendingPathComponent("CatchMyTrainApp.swift"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.firstIndex { $0.contains("planner.release()") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") } ?? -1) + 1
    }

    /// A map Plan a Trip keeps hidden is given nothing to draw in release builds (one with a place and stations on it went on
    /// drawing them, unseen), and it's hidden in a stack holding it, not right on the map (there a screen reader still found the
    /// hidden map's buttons and area names)
    func testPlanATripsHiddenMapsDrawNothing() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let views = root.appendingPathComponent("App/Views")
        guard FileManager.default.fileExists(atPath: views.path) else {
            throw XCTSkip("Main app source not found (CatchCore package copied alone), skipping")
        }
        let map = try String(contentsOf: views.appendingPathComponent("PlannerMap.swift"), encoding: .utf8)
        // Whole lines: a condition added to them would leave some hidden maps drawing
        for part in ["\n        let emptied = !shown && HiddenMapStyle.current == .empty\n", "\n        self.place = emptied ? nil : place\n",
                     "\n        self.stations = emptied ? [] : stations\n", "\n        self.pending = emptied ? nil : pending\n"] {
            XCTAssertTrue(map.contains(part), "a hidden map is given nothing to draw: \(part)")
        }
        for (start, release) in [("static let current: HiddenMapStyle = {", "\n        return .empty\n"),
                                 ("static let current: HiddenMapGroup = {", "\n        return .plain\n")] {
            let found = try XCTUnwrap(map.range(of: start), "\(start) wasn't found")
            let rest = map[found.upperBound...]
            let body = rest[..<(rest.range(of: "}()")?.lowerBound ?? rest.endIndex)]
            XCTAssertTrue(body.contains(release), "release builds: \(start) \(release) (\(body))")
        }
        // Where the maps are made: each is told whether it's shown, and the one not shown is the one hidden (a map told it's shown
        // while hidden would go on drawing, unseen)
        let planner = try String(contentsOf: views.appendingPathComponent("PlannerView+Map.swift"), encoding: .utf8)
        for call in ["mapColumn(l, shown: !large)", ".keptHidden(large)\n", "largeMapArea(l, place: planner.place, shown: large)\n",
                     ".keptHidden(!large)\n", "selected: mapSelection, shown: shown && place != nil)\n", ".keptHidden(place == nil)\n",
                     "selected: $selectedStation, shown: shown, pending: pendingPin, onPick:"] {
            XCTAssertEqual(planner.components(separatedBy: call).count, 2, "Plan a Trip's maps are told whether they're shown: \(call)")
        }
        // Each map made in Plan a Trip's file: the keptHidden after it stands left of it (on the stack holding it), never under it
        let lines = planner.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var checked = 0
        for (i, line) in lines.enumerated() where line.contains("PlannerMapView(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            guard let next = lines[(i + 1)...].firstIndex(where: { $0.contains(".keptHidden(") || $0.contains("PlannerMapView(")
                                                                    || $0.contains("func ") }),
                  lines[next].contains(".keptHidden(") else { continue }
            checked += 1
            XCTAssertLessThan(indent(lines[next]), indent(line),
                              "Plan a Trip's map is hidden on a stack holding it, not right on the map: line \(next + 1)")
        }
        XCTAssertEqual(checked, 1, "the small map's keptHidden wasn't found after it")
    }
}
