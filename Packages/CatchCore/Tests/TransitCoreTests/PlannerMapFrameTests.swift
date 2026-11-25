import XCTest
@testable import TransitCore

/// Plan a Trip's map column: when it shows, how wide, and what part of the map it frames
final class PlannerMapFrameTests: XCTestCase {
    private let timesSquare = Coordinate(latitude: 40.7580, longitude: -73.9855)

    func testColumnFoldsAwayWhenNarrow() {
        XCTAssertTrue(PlannerMapFrame.showsColumn(windowWidth: 1000))
        XCTAssertTrue(PlannerMapFrame.showsColumn(windowWidth: 860))
        XCTAssertFalse(PlannerMapFrame.showsColumn(windowWidth: 859))
        XCTAssertFalse(PlannerMapFrame.showsColumn(windowWidth: 600))
    }

    func testColumnWidth() {
        // Four tenths of the width, from 280 to 400 points
        XCTAssertEqual(PlannerMapFrame.columnWidth(windowWidth: 860), 344)
        XCTAssertEqual(PlannerMapFrame.columnWidth(windowWidth: 1000), 400)
        XCTAssertEqual(PlannerMapFrame.columnWidth(windowWidth: 1600), 400)
        XCTAssertEqual(PlannerMapFrame.columnWidth(windowWidth: 600), 280)
        // The list keeps at least 460 points next to the column
        for w in stride(from: 860.0, through: 2000, by: 10) {
            XCTAssertGreaterThanOrEqual(w - PlannerMapFrame.columnWidth(windowWidth: w), 460)
        }
    }

    func testRegionHoldsTheCircleAndEveryStation() {
        let radius = 1_300.0
        let far = Coordinate(latitude: 40.7505, longitude: -73.9934)   // Penn Station, inside 1.3 km
        let outside = Coordinate(latitude: 40.7740, longitude: -73.9820)   // a station listed though past the circle
        let region = PlannerMapFrame.region(place: timesSquare, radiusMeters: radius, stations: [far, outside])
        XCTAssertTrue(region.contains(timesSquare))
        XCTAssertTrue(region.contains(far))
        XCTAssertTrue(region.contains(outside))
        // The circle's edge in all four directions, with room to spare
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * cos(timesSquare.latitude * .pi / 180))
        for c in [Coordinate(latitude: timesSquare.latitude + dLat, longitude: timesSquare.longitude),
                  Coordinate(latitude: timesSquare.latitude - dLat, longitude: timesSquare.longitude),
                  Coordinate(latitude: timesSquare.latitude, longitude: timesSquare.longitude + dLon),
                  Coordinate(latitude: timesSquare.latitude, longitude: timesSquare.longitude - dLon)] {
            XCTAssertTrue(region.contains(c), "\(c)")
        }
        XCTAssertFalse(region.contains(Coordinate(latitude: 40.80, longitude: -73.95)))
    }

    func testRegionWithoutStationsIsTheCircle() {
        let region = PlannerMapFrame.region(place: timesSquare, radiusMeters: 1_000, stations: [], margin: 0)
        XCTAssertEqual(region.center.latitude, timesSquare.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, timesSquare.longitude, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeSpan, 2 * 1_000 / 111_320, accuracy: 1e-9)
        // East–west the degrees are shorter here, so the span in degrees is wider
        XCTAssertGreaterThan(region.longitudeSpan, region.latitudeSpan)
        // A margin widens it on both sides
        let wider = PlannerMapFrame.region(place: timesSquare, radiusMeters: 1_000, stations: [], margin: 0.12)
        XCTAssertEqual(wider.latitudeSpan, region.latitudeSpan * 1.24, accuracy: 1e-9)
    }
}

/// Names under a row of icons (the menu bar panel's bottom row): whether each fits its column on up to two lines
final class LabelFitTests: XCTestCase {
    /// Every character 6 wide (a space 3), so widths can be counted by hand
    private func pieces(_ name: String) -> [LabelFit.Piece] {
        LabelFit.pieces(of: name) { $0 == " " ? 3 : Double($0.count) * 6 }
    }

    func testWordsAreKeptWholeAndCharactersOfUnspacedScriptsAreNot() {
        XCTAssertEqual(pieces("Plan a Trip"), [.init(width: 24, gap: 3), .init(width: 6, gap: 3), .init(width: 24, gap: 3)])
        XCTAssertEqual(pieces("Einstellungen"), [.init(width: 78, gap: 3)])
        XCTAssertEqual(pieces(""), [])
        // Two Han characters, then a word in kana after a space: every character its own piece, the space before the first only
        let han = "\u{73ED}\u{6B21}"
        XCTAssertEqual(pieces(han), [.init(width: 6, gap: 3), .init(width: 6, gap: 0)])
        XCTAssertEqual(pieces(han + " \u{30DE}\u{30C3}\u{30D7}").map(\.gap), [3, 0, 3, 0, 0])
        // Hangul is written with spaces: its words stay whole
        XCTAssertEqual(pieces("\u{CD9C}\u{BC1C} \u{C815}\u{BCF4}").count, 2)
    }

    func testNamesFitOnUpToTwoLines() {
        XCTAssertTrue(LabelFit.fits(pieces("Plan a Trip"), width: 62), "one line: 24 + 3 + 6 + 3 + 24")
        XCTAssertTrue(LabelFit.fits(pieces("Plan a Trip"), width: 36), "two lines: Plan a / Trip")
        XCTAssertFalse(LabelFit.fits(pieces("Plan a Trip"), width: 30), "three lines")
        XCTAssertTrue(LabelFit.fits(pieces("Plan a Trip"), width: 30, lines: 3))
        XCTAssertFalse(LabelFit.fits(pieces("Einstellungen"), width: 62), "one word wider than a line is never broken")
        XCTAssertTrue(LabelFit.fits(pieces("Einstellungen"), width: 78))
        XCTAssertTrue(LabelFit.fits([], width: 10), "nothing to show fits")
        // Seven characters of a script without spaces, 42 wide: broken anywhere, so two lines of 24 hold them; one doesn't
        let seven = String(repeating: "\u{3042}", count: 7)
        XCTAssertTrue(LabelFit.fits(pieces(seven), width: 24))
        XCTAssertFalse(LabelFit.fits(pieces(seven), width: 24, lines: 1))
        XCTAssertFalse(LabelFit.fits(pieces(seven), width: 18), "three lines of three")
    }

    // The lines a name takes: the row under the icons keeps that many for every name, so none is pressed onto fewer
    func testLinesANameTakes() {
        XCTAssertEqual(LabelFit.lines(pieces("Plan a Trip"), width: 62), 1)
        XCTAssertEqual(LabelFit.lines(pieces("Plan a Trip"), width: 36), 2)
        XCTAssertEqual(LabelFit.lines(pieces("Plan a Trip"), width: 30), 3)
        XCTAssertNil(LabelFit.lines(pieces("Einstellungen"), width: 62), "one word wider than a line")
        XCTAssertEqual(LabelFit.lines([], width: 10), 0)
        XCTAssertEqual(LabelFit.lines(pieces(String(repeating: "\u{3042}", count: 7)), width: 24), 2)
    }
}
