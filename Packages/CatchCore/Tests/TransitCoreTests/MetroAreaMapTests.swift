import XCTest
@testable import TransitCore

/// MARC to Perryville, the Cape May–Lewes Ferry, and the map's two metro-area rings and Whole Map by metro area
final class MetroAreaMapTests: XCTestCase {

    /// Service Area: every ring point lands inside the part of the view that can be seen (here as the map window measured it: a
    /// 900 x 578 view, the top 52 points under the toolbar, a margin of 16), and the rings fill it one way or the other
    func testServiceAreaFrameFitsTheVisiblePart() throws {
        let points = (MetroOutline.current.outer + MetroOutline.current.shared).flatMap { $0 }
        let view = (width: 900.0, height: 578.0), visible = (x: 16.0, y: 68.0, width: 868.0, height: 494.0)
        let frame = try XCTUnwrap(ServiceArea.frame(points, view: view, visible: visible))
        let scale = frame.width / view.width
        XCTAssertEqual(frame.height / view.height, scale, accuracy: 1e-12, "Same scale both ways")
        var xs: [Double] = [], ys: [Double] = []
        for p in points {
            xs.append((ServiceArea.mercatorX(p.longitude) - frame.x) / scale)
            ys.append((ServiceArea.mercatorY(p.latitude) - frame.y) / scale)
        }
        let eps = 1e-6
        XCTAssertGreaterThanOrEqual(xs.min()!, visible.x - eps)
        XCTAssertLessThanOrEqual(xs.max()!, visible.x + visible.width + eps)
        XCTAssertGreaterThanOrEqual(ys.min()!, visible.y - eps)
        XCTAssertLessThanOrEqual(ys.max()!, visible.y + visible.height + eps)
        let filled = max((xs.max()! - xs.min()!) / visible.width, (ys.max()! - ys.min()!) / visible.height)
        XCTAssertEqual(filled, 1, accuracy: 1e-9)
        // North up: the northernmost point is nearest the top
        let north = try XCTUnwrap(points.max { $0.latitude < $1.latitude })
        XCTAssertEqual((ServiceArea.mercatorY(north.latitude) - frame.y) / scale, ys.min()!, accuracy: 1e-9)
        XCTAssertNil(ServiceArea.frame([], view: view, visible: visible))
        XCTAssertNil(ServiceArea.frame(points, view: view, visible: (x: 0, y: 0, width: 0, height: 10)))
    }

    /// Service Area measures each stop of the map. Drawn as asked, or a few points off, the rings are in place and nothing more is
    /// asked. A map that shows an area about 6.5% larger than asked (as one did), or moved (as one did: 128 pt left, 44 pt up), is
    /// asked again until they are in place, within 3 corrections (SubwayMapView.maxServiceAreaCorrections), and a first stop measured
    /// before the map took the ask (it still showed an older area) too. Too far off to be the map's own way (moved by hand, say),
    /// nothing is asked; with nothing to go by, no check
    func testServiceAreaCheckTakesTheMapsOwnWay() throws {
        let points = (MetroOutline.current.outer + MetroOutline.current.shared).flatMap { $0 }
        let view = (width: 900.0, height: 578.0), visible = (x: 16.0, y: 52.0 + 105.0 + 8.0, width: 868.0, height: 578.0 - 165.0 - 16.0)
        let frame = try XCTUnwrap(ServiceArea.frame(points, view: view, visible: visible))
        let asked = ServiceArea.Box(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        // A map that shows `area` zoomed by `zoom` around its middle and moved by `shift` view points: where it draws the points
        func drawn(_ area: ServiceArea.Box, zoom: Double, shift: (Double, Double)) -> [(x: Double, y: Double)] {
            let shown = (width: area.width / zoom, height: area.height / zoom)
            let x = area.x + (area.width - shown.width) / 2 - shift.0 * shown.width / view.width
            let y = area.y + (area.height - shown.height) / 2 - shift.1 * shown.height / view.height
            return points.map { ((ServiceArea.mercatorX($0.longitude) - x) / shown.width * view.width,
                                 (ServiceArea.mercatorY($0.latitude) - y) / shown.height * view.height) }
        }
        func check(_ asked: ServiceArea.Box, _ drawn: [(x: Double, y: Double)]) -> ServiceArea.FitCheck? {
            ServiceArea.check(points, asked: asked, drawn: drawn, view: view, visible: visible)
        }
        func inside(_ d: [(x: Double, y: Double)]) -> Bool {
            d.allSatisfy { $0.x >= visible.x - 0.5 && $0.x <= visible.x + visible.width + 0.5
                && $0.y >= visible.y - 0.5 && $0.y <= visible.y + visible.height + 0.5 }
        }
        // Drawn as asked: in place, as large as fits and centered
        let exact = try XCTUnwrap(check(asked, drawn(asked, zoom: 1, shift: (0, 0))))
        XCTAssertTrue(exact.inPlace)
        XCTAssertNil(exact.next)
        XCTAssertEqual(exact.offX, 0, accuracy: 1e-6)
        XCTAssertEqual(exact.offY, 0, accuracy: 1e-6)
        XCTAssertEqual(exact.size, 1, accuracy: 1e-9)
        XCTAssertEqual(exact.target.midX, visible.x + visible.width / 2, accuracy: 1e-6)
        XCTAssertEqual(exact.target.midY, visible.y + visible.height / 2, accuracy: 1e-6)
        XCTAssertEqual(max(exact.target.width / visible.width, exact.target.height / visible.height), 1, accuracy: 1e-9)
        // A few points to the side, where there's room: still in place
        let near = try XCTUnwrap(check(asked, drawn(asked, zoom: 1, shift: (5, 0))))
        XCTAssertTrue(near.inPlace)
        XCTAssertEqual(near.offX, 5, accuracy: 1e-6)
        XCTAssertTrue(near.text.contains("off x 5, y 0 pt, size 100.0%"), near.text)
        // Stop after stop, as SubwayMapView does: the corrections it takes until the rings are in place (nil: not within 3)
        func corrections(zoom: Double, shift: (Double, Double), firstShows: ServiceArea.Box? = nil) throws -> Int? {
            var ask = asked, shows = firstShows ?? asked
            for count in 0...3 {
                let stop = try XCTUnwrap(check(ask, drawn(shows, zoom: zoom, shift: shift)), "\(zoom), \(shift)")
                if stop.inPlace {
                    XCTAssertTrue(inside(drawn(shows, zoom: zoom, shift: shift)), "\(zoom), \(shift)")
                    return count
                }
                ask = try XCTUnwrap(stop.next, stop.text)
                shows = ask
            }
            return nil
        }
        XCTAssertEqual(try corrections(zoom: 1, shift: (0, 0)), 0)
        for (zoom, shift) in [(1.065, (0.0, 0.0)), (1.065, (12.0, -20.0)), (0.97, (-30.0, 26.0)), (1.2, (0.0, 0.0)), (1.0, (-128.0, -44.0)),
                              (1.065, (-128.0, -44.0))] {
            let count = try XCTUnwrap(try corrections(zoom: zoom, shift: shift), "\(zoom), \(shift): not in place after 3 corrections")
            XCTAssertGreaterThan(count, 0, "\(zoom), \(shift)")
        }
        // Moved only: one correction is enough
        XCTAssertEqual(try corrections(zoom: 1, shift: (-128, -44)), 1)
        // The first stop still showed an older area (the one fitted before the window changed, say), with the map's own way on top
        let older = ServiceArea.Box(x: asked.x + asked.width * 0.12, y: asked.y + asked.height * 0.06,
                                    width: asked.width * 1.25, height: asked.height * 1.25)
        XCTAssertNotNil(try corrections(zoom: 1.065, shift: (12, -20), firstShows: older), "not in place after 3 corrections")
        // Too far off to be the map's own way (moved by hand, say): not in place, nothing asked
        for (zoom, shift) in [(3.0, (0.0, 0.0)), (1.0, (600.0, 0.0))] {
            let far = try XCTUnwrap(check(asked, drawn(asked, zoom: zoom, shift: shift)))
            XCTAssertFalse(far.inPlace)
            XCTAssertNil(far.next)
        }
        XCTAssertNil(check(asked, []))
    }
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private let now = Date(timeIntervalSince1970: 1_791_993_600)

    private let perryville = Coordinate(latitude: 39.5561, longitude: -76.0727)
    private let capeMay = Coordinate(latitude: 38.9686, longitude: -74.9603)

    // MARK: MARC

    func testMarcKeepsOnlyPerryville() throws {
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type,route_color
            11705,MTA,,PENN - WASHINGTON,2,
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            PER,PERRYVILLE MARC,39.5561,-76.0727
            ABE,ABERDEEN MARC,39.5097,-76.1640
            BAL,BALTIMORE PENN STATION MARC,39.3076,-76.6157
            WAS,WASHINGTON UNION STATION MARC,38.8973,-77.0063
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            11705,ALL,S1,,0
            11705,ALL,N1,,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            S1,00:00:00,00:00:00,PER,1
            S1,00:12:00,00:12:00,ABE,2
            S1,00:45:00,00:45:00,BAL,3
            S1,01:30:00,01:30:00,WAS,4
            N1,22:00:00,22:00:00,WAS,1
            N1,22:45:00,22:45:00,BAL,2
            N1,23:15:00,23:15:00,ABE,3
            N1,23:30:00,23:30:00,PER,4
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            ALL,1,1,1,1,1,1,1,20200101,20991231
            """),
        ]
        XCTAssertEqual(FerryFeed.Source.marc.system, .train)
        XCTAssertTrue(FerryFeed.Source.marc.hasRealtime)
        XCTAssertTrue(ServiceArea.contains(perryville))
        let feed = try FerryBuilder.build([.marc: files], now: now)
        // Only Perryville is in the area: the line's other stations and the trains that end there are dropped
        XCTAssertEqual(feed.piers.map(\.name), ["Perryville"])
        XCTAssertEqual(feed.routes.map(\.id), ["MARC-PEN"])
        XCTAssertEqual(FerryFeed.routeName("MARC-PEN"), "MARC Penn Line")
        XCTAssertTrue(FerryFeed.isRailRoute("MARC-PEN"))
        XCTAssertEqual(feed.route("MARC-PEN")?.color.uppercased(), "B35900")
        let pier = try XCTUnwrap(feed.piers.first?.id)
        let arrivals = feed.arrivals(pierIDs: [pier], from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(2 * 86_400),
                                     realtime: [], now: now)
        XCTAssertFalse(arrivals.isEmpty)
        // Every train leaving Perryville goes toward Washington: the headsign is the trip's real last stop, though it's outside the area
        XCTAssertTrue(arrivals.allSatisfy { ($0.direction.terminal ?? "").contains("Washington") }, "\(arrivals.map(\.direction))")
    }

    // MARK: Cape May–Lewes Ferry

    func testCapeMayLewesKeepsOnlyCapeMay() throws {
        let files: [String: Data] = [
            "routes.txt": d("""
            route_id,agency_id,route_short_name,route_long_name,route_type
            1,DRBA,CMLF,Cape May - Lewes Ferry,4
            """),
            "stops.txt": d("""
            stop_id,stop_name,stop_lat,stop_lon
            CM,Cape May Terminal,38.9686,-74.9603
            LW,Lewes Terminal,38.7843,-75.1306
            """),
            "trips.txt": d("""
            route_id,service_id,trip_id,trip_headsign,direction_id
            1,ALL,A,,0
            1,ALL,B,,1
            """),
            "stop_times.txt": d("""
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            A,00:00:00,00:00:00,CM,1
            A,01:25:00,01:25:00,LW,2
            B,22:00:00,22:00:00,LW,1
            B,23:25:00,23:25:00,CM,2
            """),
            "calendar.txt": d("""
            service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
            ALL,1,1,1,1,1,1,1,20200101,20991231
            """),
        ]
        XCTAssertEqual(FerryFeed.Source.capeMayLewes.system, .ferry)
        XCTAssertFalse(FerryFeed.Source.capeMayLewes.hasRealtime)
        XCTAssertTrue(ServiceArea.contains(capeMay))
        XCTAssertFalse(ServiceArea.contains(Coordinate(latitude: 38.7843, longitude: -75.1306)))
        let feed = try FerryBuilder.build([.capeMayLewes: files], now: now)
        XCTAssertEqual(feed.piers.map(\.name), ["Cape May Terminal"])
        XCTAssertEqual(feed.routes.map(\.id), ["CML"])
        let pier = try XCTUnwrap(feed.piers.first?.id)
        let arrivals = feed.arrivals(pierIDs: [pier], from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(2 * 86_400),
                                     realtime: [], now: now)
        XCTAssertFalse(arrivals.isEmpty)
        XCTAssertTrue(arrivals.allSatisfy { ($0.direction.terminal ?? "").contains("Lewes") }, "\(arrivals.map(\.direction))")
    }

    // MARK: Downloaded only where of use

    func testDownloadAreas() {
        XCTAssertEqual(FerryFeed.Source.marc.downloadArea, .chesterAndCecil)
        XCTAssertEqual(FerryFeed.Source.capeMayLewes.downloadArea, .capeMay)
        XCTAssertEqual(FerryFeed.Source.septaMetro.downloadArea, .philadelphia)
        XCTAssertNil(FerryFeed.Source.lirr.downloadArea)
        XCTAssertTrue(DownloadArea.chesterAndCecil.contains(perryville))
        XCTAssertTrue(DownloadArea.capeMay.contains(capeMay))
        // A place in Manhattan downloads only the companies that stop at the Port Authority Bus Terminal (Newark Airport
        // Express's at Grand Central too), for the ride home from there; Queens, Long Island and Connecticut none of the new ones
        let timesSquare = Coordinate(latitude: 40.7580, longitude: -73.9855)
        XCTAssertEqual(DownloadArea.allCases.filter { $0.contains(timesSquare) },
                       [.shortLine, .suburbanTransit, .rocklandCoaches, .communityCoach, .newarkAirportExpress, .lakeland, .academy])
        let newYorkCompanies: [DownloadArea] = [.shortLine, .suburbanTransit, .rocklandCoaches, .communityCoach, .newarkAirportExpress,
                                                .orangeWestchester, .lakeland, .hunterdon, .academy, .somerset, .sussex]
        for place in [Coordinate(latitude: 40.7020, longitude: -73.8080), Coordinate(latitude: 40.7684, longitude: -73.5251),
                      Coordinate(latitude: 41.0534, longitude: -73.5387)] {
            XCTAssertTrue(newYorkCompanies.allSatisfy { !$0.contains(place) }, "\(place)")
        }
        XCTAssertEqual(MetroArea.of(perryville), .philadelphia)
        XCTAssertEqual(MetroArea.of(capeMay), .philadelphia)
    }

    // MARK: The rings

    func testOutlineHasEveryAreaAndTheLinesBetweenThem() {
        let outline = MetroOutline.current
        XCTAssertFalse(outline.outer.isEmpty)
        XCTAssertFalse(outline.shared.isEmpty)
        // Thinned: a few hundred points at most, not the grid's thousands
        let points = (outline.outer + outline.shared).map(\.count).reduce(0, +)
        XCTAssertLessThan(points, 3000)
        // Every point is on the service area's edge or between the two areas: inside the boxes' span, give or take a cell
        let boxes = ServiceArea.boxes
        let lat = (boxes.map(\.lat.lowerBound).min()! - 0.02)...(boxes.map(\.lat.upperBound).max()! + 0.02)
        let lon = (boxes.map(\.lon.lowerBound).min()! - 0.02)...(boxes.map(\.lon.upperBound).max()! + 0.02)
        for line in outline.outer + outline.shared {
            XCTAssertGreaterThanOrEqual(line.count, 2)
            for p in line { XCTAssertTrue(lat.contains(p.latitude) && lon.contains(p.longitude), "\(p)") }
        }
        // A shared line runs between two areas: two are close to each of its points (three where the Lehigh Valley meets both)
        for p in outline.shared.flatMap({ $0 }) {
            var seen = Set<MetroArea>()
            for dLat in stride(from: -0.05, through: 0.05, by: 0.025) {
                for dLon in stride(from: -0.05, through: 0.05, by: 0.025) {
                    if let a = MetroArea.of(Coordinate(latitude: p.latitude + dLat, longitude: p.longitude + dLon)) { seen.insert(a) }
                }
            }
            XCTAssertGreaterThanOrEqual(seen.count, 2, "\(p)")
        }
        // Wherever two areas meet inside the service area there is a line between them, whichever two they are (not only the
        // first area and another): places a step apart in different areas are close to a shared line
        let step = 0.05
        var pairs = Set<[String]>()
        var segments: [(Coordinate, Coordinate)] = []
        for line in outline.shared { for i in 1..<line.count { segments.append((line[i - 1], line[i])) } }
        func distance(_ p: Coordinate, _ s: (Coordinate, Coordinate)) -> Double {
            let dx = s.1.longitude - s.0.longitude, dy = s.1.latitude - s.0.latitude
            let t = max(0, min(1, ((p.longitude - s.0.longitude) * dx + (p.latitude - s.0.latitude) * dy) / max(dx * dx + dy * dy, 1e-12)))
            let x = s.0.longitude + t * dx - p.longitude, y = s.0.latitude + t * dy - p.latitude
            return (x * x + y * y).squareRoot()
        }
        for la in stride(from: lat.lowerBound, through: lat.upperBound, by: step) {
            for lo in stride(from: lon.lowerBound, through: lon.upperBound, by: step) {
                let here = Coordinate(latitude: la, longitude: lo)
                guard ServiceArea.contains(here), let a = MetroArea.of(here) else { continue }
                for next in [Coordinate(latitude: la + step, longitude: lo), Coordinate(latitude: la, longitude: lo + step)] {
                    guard ServiceArea.contains(next), let b = MetroArea.of(next), b != a else { continue }
                    pairs.insert([a.rawValue, b.rawValue].sorted())
                    let middle = Coordinate(latitude: (la + next.latitude) / 2, longitude: (lo + next.longitude) / 2)
                    XCTAssertLessThan(segments.map { distance(middle, $0) }.min() ?? .infinity, 0.08, "\(a) and \(b) at \(middle)")
                }
            }
        }
        XCTAssertTrue(pairs.contains([MetroArea.lehighValley.rawValue, MetroArea.philadelphia.rawValue].sorted()),
                      "The Lehigh Valley meets the Philadelphia area along Berks, Montgomery and Bucks Counties")
        // The service area's edge is drawn all the way round: places a step apart, one in the service area and one outside it,
        // are close to an outer line, and no outer line is a single point
        var edges: [(Coordinate, Coordinate)] = []
        for line in outline.outer {
            XCTAssertGreaterThanOrEqual(Set(line).count, 2, "\(line)")
            for i in 1..<line.count { edges.append((line[i - 1], line[i])) }
        }
        for la in stride(from: lat.lowerBound, through: lat.upperBound, by: step) {
            for lo in stride(from: lon.lowerBound, through: lon.upperBound, by: step) {
                let here = Coordinate(latitude: la, longitude: lo)
                for next in [Coordinate(latitude: la + step, longitude: lo), Coordinate(latitude: la, longitude: lo + step)] {
                    guard (MetroOutline.strictArea(here) == nil) != (MetroOutline.strictArea(next) == nil) else { continue }
                    let middle = Coordinate(latitude: (la + next.latitude) / 2, longitude: (lo + next.longitude) / 2)
                    XCTAssertLessThan(edges.map { distance(middle, $0) }.min() ?? .infinity, 0.08, "edge at \(middle)")
                }
            }
        }
        // Each name has its point, inside its own area
        for area in MetroArea.allCases {
            XCTAssertNotNil(outline.labels[area], "\(area)")
            XCTAssertEqual(MetroArea.of(MetroOutline.labelPoint(area)), area)
        }
    }

    /// Each metro area is one piece on the map, with one ring: its islands are joined to the mainland by the water between them
    /// (docs/metro-areas.md, "One piece"). Cells that touch only at a corner count as joined (see MetroOutline.pieces)
    func testEachMetroAreaIsOnePiece() {
        let pieces = MetroOutline.pieces(cell: 0.01)
        for area in MetroArea.allCases { XCTAssertEqual(pieces[area], 1, "\(area)") }
        // The check itself: two blocks of cells apart are two pieces, joined at a corner they are one
        XCTAssertEqual(MetroOutline.pieces(of: [1, 1, 0, 0,
                                                1, 1, 0, 1], rows: 2, cols: 4), [MetroArea.allCases[0]: 2])
        XCTAssertEqual(MetroOutline.pieces(of: [1, 0, 0,
                                                0, 1, 2], rows: 2, cols: 3), [MetroArea.allCases[0]: 1, MetroArea.allCases[1]: 1])
    }

    /// A name goes in the middle of its area, by one rule for every area; an oddly shaped area, whose middle is outside it
    /// or has little room, takes its roomiest spot instead
    func testNameGoesInTheMiddleOrTheRoomiestSpot() {
        // A block of 9 by 21 cells: its middle cell
        var block = [UInt8](repeating: 0, count: 11 * 23)
        for r in 1...9 { for c in 1...21 { block[r * 23 + c] = 1 } }
        let middle = MetroOutline.labelCell(grid: block, rows: 11, cols: 23, area: 1, columnsPerRow: 2)
        XCTAssertEqual(middle?.row, 5)
        XCTAssertEqual(middle?.col, 11)
        // A "C" (bars 5 cells thick on the left, top and bottom): its middle is in the hollow, so the name goes to the roomiest
        // cell nearest to it, the middle of the left bar
        var hollow = [UInt8](repeating: 0, count: 21 * 21)
        for r in 0..<21 { for c in 0..<21 where c < 5 || r < 5 || r >= 16 { hollow[r * 21 + c] = 1 } }
        let inBar = MetroOutline.labelCell(grid: hollow, rows: 21, cols: 21, area: 1, columnsPerRow: 1)
        XCTAssertEqual(inBar?.row, 10)
        XCTAssertEqual(inBar?.col, 2)
        // Two blocks joined by a corridor one cell wide: the middle is in the corridor, with less than half the room of a block
        var joined = [UInt8](repeating: 0, count: 9 * 31)
        for r in 0..<9 { for c in 0..<31 where c < 9 || c >= 22 || r == 4 { joined[r * 31 + c] = 1 } }
        let inBlock = MetroOutline.labelCell(grid: joined, rows: 9, cols: 31, area: 1, columnsPerRow: 1)
        XCTAssertEqual(inBlock?.row, 4)
        XCTAssertEqual(inBlock?.col, 4)
        // An area without cells has no spot
        XCTAssertNil(MetroOutline.labelCell(grid: hollow, rows: 21, cols: 21, area: 2, columnsPerRow: 1))
    }

    /// Zoomed out too far for one line, a name is written on two, broken at the space nearest its middle; a name without a
    /// space stays on one
    func testNameOnTwoLines() {
        XCTAssertEqual(MetroOutline.twoLines("New York Metropolitan Area"), ["New York", "Metropolitan Area"])
        XCTAssertEqual(MetroOutline.twoLines("Philadelphia Metropolitan Area"), ["Philadelphia", "Metropolitan Area"])
        // A name written without spaces (as in Chinese or Japanese)
        XCTAssertNil(MetroOutline.twoLines("\u{7EBD}\u{7EA6}\u{90FD}\u{4F1A}\u{533A}"))
        XCTAssertNil(MetroOutline.twoLines(""))
    }

    /// A metro area's name is written only while its box fits inside the area: a small box fits in every area, one the size
    /// of the country in none
    func testNameFitsOnlyInsideItsOwnArea() {
        for area in MetroArea.allCases {
            XCTAssertTrue(MetroOutline.nameFits(area, widthMeters: 20_000, heightMeters: 4_000), "\(area)")
            XCTAssertFalse(MetroOutline.nameFits(area, widthMeters: 2_000_000, heightMeters: 300_000), "\(area)")
            XCTAssertFalse(MetroOutline.nameFits(area, widthMeters: -1, heightMeters: 4_000), "\(area)")
        }
        // A smaller box fits wherever a bigger one does, so a name that went while zooming out comes back zooming in
        for area in MetroArea.allCases {
            var fitted = true
            for width in stride(from: 10_000.0, through: 200_000, by: 10_000) {
                let fits = MetroOutline.nameFits(area, widthMeters: width, heightMeters: width / 6)
                XCTAssertFalse(fits && !fitted, "\(area) \(width)")
                fitted = fits
            }
        }
    }

    /// An area's name moves up or down to keep clear of the favorite stars, as long as it still fits inside its ring, and isn't
    /// written when it can't: with no stars, or none in the way, it stays where it was
    func testNameKeepsClearOfTheStars() {
        let name = MapLabelLayout.Box(x: 100, y: 100, width: 120, height: 20)
        let always: (Double) -> Bool = { _ in true }
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [], fits: always), 0)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [MapLabelLayout.Box(x: 300, y: 100, width: 22, height: 22)], fits: always), 0)
        // A star on it: up a little (a step is the name's height and 6 points), or down when that wouldn't fit inside the ring
        let onIt = MapLabelLayout.Box(x: 150, y: 99, width: 22, height: 22)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [onIt], fits: always), -26)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [onIt], fits: { $0 > 0 }), 26)
        // Stars just above and below too: two steps up
        let above = MapLabelLayout.Box(x: 120, y: 74, width: 22, height: 22), below = MapLabelLayout.Box(x: 160, y: 124, width: 22, height: 22)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [onIt, above, below], fits: always), -52)
        // Nowhere to go: not written
        XCTAssertNil(MetroOutline.nameShift(name: name, stars: [onIt], fits: { _ in false }))
        let column = (0..<12).map { MapLabelLayout.Box(x: 150, y: Double(30 + 15 * $0), width: 22, height: 22) }
        XCTAssertNil(MetroOutline.nameShift(name: name, stars: column, fits: always))
        // A star only 2 points off still counts as in the way (3 points are kept between them)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [MapLabelLayout.Box(x: 222, y: 100, width: 22, height: 22)], fits: always), -26)
        XCTAssertEqual(MetroOutline.nameShift(name: name, stars: [MapLabelLayout.Box(x: 223, y: 100, width: 22, height: 22)], fits: always), 0)
    }

    /// A name moved north or south must still fit inside its own ring: unmoved, the same as before; moved far, it doesn't
    func testMovedNameStillInsideItsRing() {
        for area in MetroArea.allCases {
            XCTAssertEqual(MetroOutline.nameFits(area, widthMeters: 20_000, heightMeters: 4_000, northMeters: 0),
                           MetroOutline.nameFits(area, widthMeters: 20_000, heightMeters: 4_000), "\(area)")
            XCTAssertTrue(MetroOutline.nameFits(area, widthMeters: 2_000, heightMeters: 400, northMeters: 500), "\(area)")
            XCTAssertTrue(MetroOutline.nameFits(area, widthMeters: 2_000, heightMeters: 400, northMeters: -500), "\(area)")
            XCTAssertFalse(MetroOutline.nameFits(area, widthMeters: 2_000, heightMeters: 400, northMeters: 600_000), "\(area)")
            XCTAssertFalse(MetroOutline.nameFits(area, widthMeters: 2_000, heightMeters: 400, northMeters: -600_000), "\(area)")
        }
    }

    /// Zooms less than 2 percent apart are one step: an area's answer is worked out once for the step, is the outline's own
    /// answer at the step's scale, and is the same whichever zoom of the step asks first
    func testNameFitIsRememberedByZoomStep() {
        let cache = NameFitCache()
        let step = NameFitCache.step(metersPerPoint: 150)
        let scale = NameFitCache.scale(ofStep: step)
        XCTAssertEqual(scale, 150, accuracy: 150 * 0.011)
        XCTAssertEqual(NameFitCache.step(metersPerPoint: scale * 1.009), step)
        XCTAssertEqual(NameFitCache.step(metersPerPoint: scale / 1.009), step)
        XCTAssertEqual(NameFitCache.step(metersPerPoint: scale * 1.03), step + 1)
        for area in MetroArea.allCases {
            let first = cache.fits(area, widthPoints: 120, heightPoints: 26, metersPerPoint: scale * 1.009)
            XCTAssertEqual(first, MetroOutline.nameFits(area, widthMeters: 120 * scale, heightMeters: 26 * scale), "\(area)")
            XCTAssertEqual(cache.fits(area, widthPoints: 120, heightPoints: 26, metersPerPoint: scale / 1.009), first, "\(area)")
            XCTAssertEqual(cache.fits(area, widthPoints: 120, heightPoints: 26, metersPerPoint: scale), first, "\(area)")
        }
        XCTAssertEqual(cache.workedOut, MetroArea.allCases.count, "Once per area for the whole step")
        // Another step, another size and a moved name are other answers
        _ = cache.fits(.newYork, widthPoints: 120, heightPoints: 26, metersPerPoint: scale * 1.05)
        _ = cache.fits(.newYork, widthPoints: 90, heightPoints: 40, metersPerPoint: scale)
        _ = cache.fits(.newYork, widthPoints: 120, heightPoints: 26, metersPerPoint: scale, northPoints: 26)
        XCTAssertEqual(cache.workedOut, MetroArea.allCases.count + 3)
        XCTAssertEqual(cache.fits(.newYork, widthPoints: 120, heightPoints: 26, metersPerPoint: scale, northPoints: 26),
                       MetroOutline.nameFits(.newYork, widthMeters: 120 * scale, heightMeters: 26 * scale, northMeters: 26 * scale))
        // Across the zooms a map goes through: the outline's answer at each step's scale
        for area in MetroArea.allCases {
            for metersPerPoint in stride(from: 20.0, through: 4_000, by: 97) {
                let at = NameFitCache.scale(ofStep: NameFitCache.step(metersPerPoint: metersPerPoint))
                XCTAssertEqual(at, metersPerPoint, accuracy: metersPerPoint * 0.011)
                XCTAssertEqual(cache.fits(area, widthPoints: 120, heightPoints: 26, metersPerPoint: metersPerPoint),
                               MetroOutline.nameFits(area, widthMeters: 120 * at, heightMeters: 26 * at), "\(area) \(metersPerPoint)")
            }
        }
        // No scale or no size: no
        XCTAssertFalse(cache.fits(.newYork, widthPoints: 120, heightPoints: 26, metersPerPoint: 0))
        XCTAssertFalse(cache.fits(.newYork, widthPoints: 120, heightPoints: 26, metersPerPoint: .infinity))
        XCTAssertFalse(cache.fits(.newYork, widthPoints: .nan, heightPoints: 26, metersPerPoint: 100))
    }

    func testThinningKeepsCornersAndEnds() {
        let straight = (0...10).map { Coordinate(latitude: 40, longitude: -75 + Double($0) * 0.01) }
        XCTAssertEqual(MetroOutline.thinned(straight, meters: 300), [straight[0], straight[10]])
        let corner = straight + (1...10).map { Coordinate(latitude: 40 + Double($0) * 0.01, longitude: -74.9) }
        XCTAssertEqual(MetroOutline.thinned(corner, meters: 300), [corner[0], straight[10], corner[corner.count - 1]])
        // A closed ring (an island's) keeps its corners, not only its start
        let side = (0..<10).map { Double($0) * 0.01 }
        let square = side.map { Coordinate(latitude: 41, longitude: -70 + $0) } + side.map { Coordinate(latitude: 41 + $0, longitude: -69.9) }
            + side.map { Coordinate(latitude: 41.1, longitude: -69.9 - $0) } + side.map { Coordinate(latitude: 41.1 - $0, longitude: -70) }
            + [Coordinate(latitude: 41, longitude: -70)]
        XCTAssertEqual(MetroOutline.thinned(square, meters: 300), [square[0], square[10], square[20], square[30], square[40]])
    }

    // MARK: Whole Map by metro area

    func testWholeMapPointsByArea() {
        let manhattan = [[40.70, -74.01], [40.75, -73.99], [40.80, -73.96]]
        // Mostly in Philadelphia, ending in Trenton (Central New Jersey, New York's area)
        let toTrenton = [[39.95, -75.16], [40.00, -75.10], [40.05, -75.00], [40.10, -74.90], [40.2171, -74.7429]]
        let map = SubwayMap(source: "x", feedVersion: "1",
                            stations: [SubwayMap.Station(id: "a", name: "Times Sq", lat: 40.7580, lon: -73.9855),
                                       SubwayMap.Station(id: "b", name: "City Hall", lat: 39.9524, lon: -75.1636),
                                       SubwayMap.Station(id: "c", name: "Trenton", lat: 40.2171, lon: -74.7429)],
                            routes: [SubwayMap.Route(route: "A", color: "0062CF", lines: [manhattan]),
                                     SubwayMap.Route(route: "B", color: "F00000", lines: [toTrenton])])
        // By line: a line counts for the area it mostly runs in, whole
        XCTAssertEqual(map.wholeMapPoints(in: .newYork, byLine: true), manhattan)
        XCTAssertEqual(map.wholeMapPoints(in: .philadelphia, byLine: true), toTrenton)
        // By station: each station by where it is
        XCTAssertEqual(map.wholeMapPoints(in: .newYork, byLine: false), [[40.7580, -73.9855], [40.2171, -74.7429]])
        XCTAssertEqual(map.wholeMapPoints(in: .philadelphia, byLine: false), [[39.9524, -75.1636]])
        // An area with nothing: empty (the caller then frames the whole map)
        let empty = SubwayMap(source: "x", feedVersion: "1", stations: [], routes: [SubwayMap.Route(route: "A", color: "0062CF", lines: [manhattan])])
        XCTAssertTrue(empty.wholeMapPoints(in: .philadelphia, byLine: true).isEmpty)
    }

    // MARK: Areas by county (areas.json, area_counties.bin)

    /// Every area and region in areas.json is a case of the app's enums and the other way round, each region has counties, no
    /// county is in two regions, and every county has its outline, as does every county of "outside" (and no other)
    func testAreaCatalogMatchesEnumsAndOutlines() throws {
        let catalog = AreaCatalog.shared
        XCTAssertEqual(Set(catalog.areas.map(\.id)), Set(MetroArea.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(catalog.areas.flatMap { $0.regions.map(\.id) }), Set(MetroSubRegion.allCases.map(\.rawValue)))
        for region in catalog.areas.flatMap(\.regions) { XCTAssertFalse(region.counties.isEmpty, region.id) }
        XCTAssertEqual(catalog.counties.count, Set(catalog.counties).count, "a county is in two regions")
        let map = try XCTUnwrap(CountyMap.shared)
        XCTAssertEqual(Set(map.codes), Set(catalog.counties).union(catalog.outside))
        XCTAssertEqual(catalog.outside.count, Set(catalog.outside).count, "a county is in \"outside\" twice")
        XCTAssertTrue(Set(catalog.counties).isDisjoint(with: catalog.outside), "a county is in an area and in \"outside\"")
        for code in catalog.counties { XCTAssertTrue(map.isCounted(code), "\(code)") }
        for code in catalog.outside { XCTAssertFalse(map.isCounted(code), "\(code)") }
        // Taken out of the areas: no station of the app's operators is in them (Wayne County, PA; Sussex County, DE). Next to
        // the boxes of the Berkshires and the Pioneer Valley and in no area: Rensselaer County, NY, and Bennington and Windham
        // Counties, VT
        for code in [42127, 10005, 36083, 50003, 50025] { XCTAssertTrue(catalog.outside.contains(code), "\(code)") }
        // Northwest Hills, CT, is Greater Hartford's: CTtransit's and NWCTD's stops in Torrington and Winsted
        XCTAssertEqual(catalog.region(ofCounty: 9160)?.id, MetroSubRegion.northwestHills.rawValue)
        // Names follow English Wikipedia's article: "New York Metropolitan Area", but "Lehigh Valley", "Greater Boston", "Greater
        // Hartford" and "Western Massachusetts"
        XCTAssertEqual(MetroArea.allCases.map(\.nameKey),
                       ["New York Metropolitan Area", "Philadelphia Metropolitan Area", "Lehigh Valley", "Greater Boston", "Greater Hartford",
                        "Western Massachusetts"])
    }

    /// Every area names a real time zone in areas.json (the only place the app names one); a place takes its area's, and a place in no
    /// area (or none) the Mac's
    func testEveryAreaHasItsTimeZone() throws {
        for area in MetroArea.allCases {
            let named = try XCTUnwrap(AreaCatalog.shared.area(area.rawValue)?.timeZone, area.rawValue)
            XCTAssertNotNil(TimeZone(identifier: named), "\(area.rawValue): \(named)")
            XCTAssertEqual(area.timeZone.identifier, named)
        }
        XCTAssertEqual(Timetable.timeZone, MetroArea.newYork.timeZone, "the subway's timetable counts in New York's area's")
        let mac = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(MetroArea.timeZone(at: Coordinate(latitude: 42.3519, longitude: -71.0552), mac: mac), MetroArea.greaterBoston.timeZone)
        XCTAssertEqual(MetroArea.timeZone(at: Coordinate(latitude: 40.6020, longitude: -75.4714), mac: mac), MetroArea.lehighValley.timeZone)
        XCTAssertEqual(MetroArea.timeZone(at: Coordinate(latitude: 41.8781, longitude: -87.6298), mac: mac), mac, "outside the service area")
        XCTAssertEqual(MetroArea.timeZone(at: nil, mac: mac), mac, "no place")
    }

    /// Places on either side of a county or state line, and on the water, are in the region of the county they're in or nearest
    func testRegionsFollowCountyLines() {
        func r(_ lat: Double, _ lon: Double) -> MetroSubRegion? { MetroSubRegion.of(Coordinate(latitude: lat, longitude: lon)) }
        XCTAssertEqual(r(40.6937, -75.1902), .warrenCounty)       // Phillipsburg, NJ
        XCTAssertEqual(r(40.6884, -75.2207), .northamptonCounty)  // Easton, PA, across the Delaware
        // Greater Boston's regions
        XCTAssertEqual(r(42.3554, -71.0605), .boston)               // Boston
        XCTAssertEqual(r(42.3736, -71.1097), .boston)               // Cambridge (Middlesex County)
        XCTAssertEqual(r(42.2529, -71.0023), .boston)               // Quincy (Norfolk County)
        XCTAssertEqual(r(42.6334, -71.3162), .boston)               // Lowell (Middlesex County too)
        XCTAssertEqual(r(42.5195, -70.8967), .northShore)           // Salem
        XCTAssertEqual(r(42.0834, -71.0184), .southShore)           // Brockton (Plymouth County)
        XCTAssertEqual(r(42.2626, -71.8023), .centralMassachusetts) // Worcester
        XCTAssertEqual(r(41.7015, -71.1550), .bristolCounty)        // Fall River
        XCTAssertEqual(r(41.6362, -70.9342), .bristolCounty)        // New Bedford
        XCTAssertEqual(r(41.6532, -70.2827), .capeCod)              // Hyannis
        XCTAssertEqual(r(42.0584, -70.1787), .capeCod)              // Provincetown
        XCTAssertEqual(r(41.8240, -71.4128), .rhodeIsland)          // Providence
        XCTAssertEqual(r(41.3776, -71.8273), .rhodeIsland)          // Westerly
        XCTAssertEqual(r(41.3557, -71.9665), .connecticut)          // Mystic, CT, across the Pawcatuck: New York's
        XCTAssertEqual(r(42.9956, -71.4548), .newHampshire)         // Manchester
        XCTAssertEqual(r(43.0718, -70.7626), .newHampshire)         // Portsmouth
        XCTAssertEqual(r(43.2081, -71.5376), .newHampshire)         // Concord
        XCTAssertEqual(r(43.5279, -71.4704), .newHampshire)         // Laconia
        XCTAssertEqual(r(43.1979, -70.8737), .newHampshire)         // Dover
        // York County, Maine, across the Piscataqua and the Salmon Falls River from Portsmouth and Dover: where COAST runs
        XCTAssertEqual(r(43.0881, -70.7364), .yorkCounty)           // Kittery
        XCTAssertEqual(r(43.1534, -70.8003), .yorkCounty)           // Eliot
        XCTAssertEqual(r(43.2343, -70.8095), .yorkCounty)           // South Berwick
        XCTAssertEqual(r(43.2667, -70.8500), .yorkCounty)           // Berwick
        XCTAssertEqual(MetroSubRegion.yorkCounty.metroArea, .greaterBoston)
        XCTAssertEqual(MetroSubRegion.boston.metroArea, .greaterBoston)
        // The rest of York County is outside the boxes (a user's own location there still counts within 15 km: Sanford's does)
        for (name, lat, lon) in [("Sanford", 43.4393, -70.7742), ("Lebanon", 43.3945, -70.9203), ("Acton", 43.5343, -70.9095),
                                 ("York", 43.1617, -70.6484), ("Ogunquit", 43.2490, -70.5990)] {
            let c = Coordinate(latitude: lat, longitude: lon)
            XCTAssertFalse(ServiceArea.contains(c), name)
            XCTAssertEqual(CountyMap.shared?.county(at: c), 23031, name)
        }
        // Outside: Portland, Maine
        XCTAssertNil(r(43.6591, -70.2568))
        // Greater Hartford's regions: the Capitol planning region, Northeastern Connecticut and the Northwest Hills
        XCTAssertEqual(r(41.7658, -72.6734), .hartford)                // Hartford
        XCTAssertEqual(r(41.6612, -72.7795), .hartford)                // New Britain
        XCTAssertEqual(r(41.7621, -72.7420), .hartford)                // West Hartford
        XCTAssertEqual(r(41.9762, -72.5918), .hartford)                // Enfield
        XCTAssertEqual(r(41.8084, -72.2495), .hartford)                // Storrs
        XCTAssertEqual(r(41.6362, -72.7652), .hartford)                // Berlin's station
        XCTAssertEqual(r(41.9151, -71.9087), .northeasternConnecticut) // Putnam
        XCTAssertEqual(r(41.8023, -71.8859), .northeasternConnecticut) // Danielson
        XCTAssertEqual(r(41.8007, -73.1212), .northwestHills)          // Torrington
        XCTAssertEqual(r(41.9212, -73.0601), .northwestHills)          // Winsted
        XCTAssertEqual(r(41.5560, -73.3090), .northwestHills)          // Roxbury, in New York's box
        // Western Massachusetts' regions: Hampden, Hampshire and Franklin Counties, and Berkshire County
        XCTAssertEqual(r(42.1015, -72.5898), .pioneerValley)           // Springfield
        XCTAssertEqual(r(42.2043, -72.6162), .pioneerValley)           // Holyoke
        XCTAssertEqual(r(42.1251, -72.7495), .pioneerValley)           // Westfield
        XCTAssertEqual(r(42.3251, -72.6412), .pioneerValley)           // Northampton
        XCTAssertEqual(r(42.3732, -72.5199), .pioneerValley)           // Amherst
        XCTAssertEqual(r(42.5876, -72.5995), .pioneerValley)           // Greenfield
        XCTAssertEqual(r(42.5918, -72.3152), .pioneerValley)           // Orange, where MART's buses come
        XCTAssertEqual(r(42.4501, -73.2454), .berkshires)              // Pittsfield
        XCTAssertEqual(r(42.7009, -73.1087), .berkshires)              // North Adams
        XCTAssertEqual(r(42.1959, -73.3621), .berkshires)              // Great Barrington
        // No holes (rule 6): the parts of the areas' counties between the Northwest Hills, the Berkshires and New York's area,
        // with no stop nearby, are in the service area themselves, not only within a user's margin, each in its county's region;
        // over the state line, in a county of no area, a place inside the boxes is still out
        func inArea(_ lat: Double, _ lon: Double) -> MetroSubRegion? {
            ServiceArea.county(Coordinate(latitude: lat, longitude: lon))
                .flatMap { AreaCatalog.shared.region(ofCounty: $0) }.flatMap { MetroSubRegion(rawValue: $0.id) }
        }
        XCTAssertEqual(inArea(41.983, -73.421), .northwestHills)       // Salisbury
        XCTAssertEqual(inArea(41.958, -73.440), .northwestHills)       // Lakeville
        XCTAssertEqual(inArea(41.650, -73.420), .connecticut)          // New Milford's north end
        XCTAssertEqual(inArea(42.110, -73.355), .berkshires)           // Sheffield
        XCTAssertEqual(inArea(42.122, -73.229), .berkshires)           // New Marlborough
        XCTAssertEqual(inArea(42.110, -73.130), .berkshires)           // Sandisfield
        XCTAssertEqual(inArea(42.087, -73.013), .pioneerValley)        // Tolland
        XCTAssertEqual(inArea(42.6965, -72.4529), .pioneerValley)      // Northfield, up to the state line
        XCTAssertEqual(inArea(42.6948, -72.9254), .pioneerValley)      // Rowe, up to the Vermont line
        XCTAssertTrue(ServiceArea.inBoxes(Coordinate(latitude: 42.745, longitude: -72.550)))
        XCTAssertNil(inArea(42.745, -72.550))                          // Windham County, VT, by the Massachusetts line
        XCTAssertTrue(ServiceArea.inBoxes(Coordinate(latitude: 42.120, longitude: -73.510)))
        XCTAssertNil(inArea(42.120, -73.510))                          // Columbia County, NY, by the Massachusetts line
        for region in [MetroSubRegion.hartford, .northeasternConnecticut, .northwestHills] { XCTAssertEqual(region.metroArea, .greaterHartford) }
        for region in [MetroSubRegion.pioneerValley, .berkshires] { XCTAssertEqual(region.metroArea, .westernMassachusetts) }
        // Connecticut's other planning regions stay New York's: Willimantic (Southeastern) and Bristol and Thomaston (Naugatuck
        // Valley), now inside the boxes too
        XCTAssertEqual(r(41.7107, -72.2081), .connecticut)             // Willimantic
        XCTAssertEqual(r(41.6718, -72.9493), .connecticut)             // Bristol
        XCTAssertEqual(r(41.6740, -73.0732), .connecticut)             // Thomaston
        // Athol and Worcester stay Greater Boston's
        XCTAssertEqual(r(42.5959, -72.2268), .centralMassachusetts)    // Athol
        // Brattleboro, VT, is about 14 km from the Massachusetts line, which the Pioneer Valley reaches: a user there counts in
        // it, as one in Hinsdale, NH, does. Outside: Putney, VT, and Hudson, NY, more than 15 km from an area's county
        XCTAssertEqual(r(42.8509, -72.5579), .pioneerValley)
        XCTAssertNil(r(42.9748, -72.5218))
        XCTAssertNil(r(42.2529, -73.7910))
        // The islands the boats from Greater Boston reach (rule 4): Martha's Vineyard, Chappaquiddick and the Elizabeth Islands
        // are Dukes County, Nantucket its own county; Block Island is Rhode Island's. Woods Hole, across the sound, stays Cape Cod's
        XCTAssertEqual(r(41.3890, -70.5134), .dukesCounty)          // Edgartown
        XCTAssertEqual(r(41.4543, -70.6036), .dukesCounty)          // Vineyard Haven's pier
        XCTAssertEqual(r(41.4588, -70.5544), .dukesCounty)          // Oak Bluffs' pier
        XCTAssertEqual(r(41.3466, -70.8365), .dukesCounty)          // Aquinnah
        XCTAssertEqual(r(41.4242, -70.9230), .dukesCounty)          // Cuttyhunk's pier
        XCTAssertEqual(r(41.2847, -70.0927), .nantucketCounty)      // Nantucket's Straight Wharf
        XCTAssertEqual(r(41.2653, -69.9638), .nantucketCounty)      // Sconset
        XCTAssertEqual(r(41.1737, -71.5567), .rhodeIsland)          // Block Island's pier
        XCTAssertEqual(r(41.5226, -70.6703), .capeCod)              // Woods Hole's pier
        XCTAssertEqual(MetroSubRegion.dukesCounty.metroArea, .greaterBoston)
        XCTAssertEqual(MetroSubRegion.nantucketCounty.metroArea, .greaterBoston)
        XCTAssertEqual(r(40.2171, -74.7429), .centralNewJersey)   // Trenton
        XCTAssertEqual(r(40.2115, -74.7882), .philadelphia)       // Morrisville, PA, across the river
        XCTAssertEqual(r(40.7013, -74.0132), .newYorkCity)        // Whitehall Terminal, on the water's edge
        XCTAssertEqual(r(40.7357, -74.0291), .northernNewJersey)  // Hoboken Terminal
        XCTAssertEqual(r(40.9584, -73.8204), .hudsonValley)       // Westchester, north of the Bronx
        XCTAssertEqual(r(41.0534, -73.5387), .connecticut)        // Stamford
        XCTAssertEqual(r(40.5800, -73.6600), .longIsland)         // Long Beach
        XCTAssertNil(r(42.6526, -73.7562))                        // Albany, outside the service area
        XCTAssertEqual(r(40.9000, -73.0000), .longIsland)         // Long Island Sound off Port Jefferson: the nearest county
    }

    /// The service area is the areas' counties inside the boxes: a place in a county of no area that the boxes reach into is
    /// outside it. A user's own location there still counts within 15 km of an area's county, in that county's region. On the
    /// water, the nearest county decides
    func testServiceAreaFollowsCounties() throws {
        let map = try XCTUnwrap(CountyMap.shared)
        let outside: [(String, Double, Double, Int)] = [
            ("Keene, NH", 42.9337, -72.2781, 33005), ("Hazleton, PA", 40.9584, -75.9746, 42079),
            ("Honesdale, PA", 41.5768, -75.2588, 42127),
            ("Gap, PA (Lancaster County)", 40.0068, -76.0202, 42071), ("Berlin, NY", 42.6926, -73.3721, 36083),
            ("Milford, DE, south of the Mispillion", 38.9126, -75.4277, 10005), ("Havre de Grace, MD", 39.5493, -76.0916, 24025),
            ("Windham County, VT, by the Massachusetts line", 42.7450, -72.5500, 50025),
        ]
        for (name, lat, lon, county) in outside {
            let c = Coordinate(latitude: lat, longitude: lon)
            XCTAssertTrue(ServiceArea.inBoxes(c), name)
            XCTAssertEqual(map.county(at: c), county, name)
            XCTAssertFalse(ServiceArea.contains(c), name)
            XCTAssertNil(MetroOutline.strictArea(c), name)
        }
        let near: [(String, Double, Double, MetroSubRegion)] = [
            ("Hazleton, PA", 40.9584, -75.9746, .carbonCounty), ("Sanford, ME", 43.4393, -70.7742, .yorkCounty),
            ("Honesdale, PA", 41.5768, -75.2588, .pikeCounty), ("Hinsdale, NH", 42.7862, -72.4862, .pioneerValley),
            ("Berlin, NY", 42.6926, -73.3721, .berkshires), ("Brattleboro, VT", 42.8509, -72.5579, .pioneerValley),
            ("Havre de Grace, MD", 39.5493, -76.0916, .cecilCounty),
        ]
        for (name, lat, lon, region) in near {
            let c = Coordinate(latitude: lat, longitude: lon)
            XCTAssertTrue(ServiceArea.containsWithMargin(c), name)
            XCTAssertEqual(MetroSubRegion.of(c), region, name)
        }
        // More than 15 km from an area's county
        for (name, lat, lon) in [("Keene, NH", 42.9337, -72.2781), ("Lewes, DE", 38.7843, -75.1306)] {
            let c = Coordinate(latitude: lat, longitude: lon)
            XCTAssertFalse(ServiceArea.containsWithMargin(c), name)
            XCTAssertNil(MetroSubRegion.of(c), name)
        }
        // How far: Keene is about 18 km from Hillsborough County, NH
        let keene = try XCTUnwrap(map.countedCounty(near: Coordinate(latitude: 42.9337, longitude: -72.2781)))
        XCTAssertEqual(keene.code, 33011)
        XCTAssertEqual(keene.km, 17.6, accuracy: 0.5)
        XCTAssertEqual(map.countedCounty(near: Coordinate(latitude: 42.3554, longitude: -71.0605))?.km, 0)
        // The middle of Long Island Sound: no county, New York's either way
        let sound = Coordinate(latitude: 41.0500, longitude: -73.0000)
        XCTAssertNil(map.county(at: sound))
        XCTAssertTrue(ServiceArea.contains(sound))
        XCTAssertEqual(MetroArea.of(sound), .newYork)
        XCTAssertEqual(MetroOutline.strictArea(sound), .newYork)
    }

    // MARK: Keys and accounts, and the area menu

    /// Each area lists the keys its operators' live times need, worked out from where the operators have stops: MTA Bus Time and
    /// Swiftly in New York only, NJ Transit's account in all three (its trains reach Philadelphia's area and Hackettstown, its buses
    /// Phillipsburg). "Also used in" names the others
    func testKeysAndAccountsByArea() {
        XCTAssertEqual(AccountKey.needed(in: .newYork), [.busTime, .njTransit, .suffolk])
        XCTAssertEqual(AccountKey.needed(in: .philadelphia), [.njTransit])
        XCTAssertEqual(AccountKey.needed(in: .lehighValley), [.njTransit])
        XCTAssertEqual(AccountKey.njTransit.otherAreas(than: .philadelphia), [.newYork, .lehighValley])
        XCTAssertEqual(AccountKey.busTime.otherAreas(than: .newYork), [])
        XCTAssertEqual(AccountKey.njTransit.credentials, [.njTransitRail, .njTransitBus])
        // Every operator that needs a key or account is behind one of them
        let sources = FerryFeed.Source.allCases.filter(\.needsAccount)
        XCTAssertEqual(Set(AccountKey.allCases.flatMap(\.sources)), Set(sources))
        let buses = RegionalBusFeed.all.filter { $0.needsAccount || $0.needsKey }.map(\.code)
        XCTAssertEqual(Set(AccountKey.allCases.flatMap(\.buses).map(\.code)), Set(buses))
        // Every area needing a key has an operator there that uses it
        for key in AccountKey.allCases {
            for area in key.areas {
                let used = key.sources.contains { MetroArea.areas(of: $0).contains(area) }
                    || key.buses.contains { MetroArea.areas(ofBus: $0).contains(area) }
                    || (key == .busTime && MetroArea.areas(ofOperator: ModeCoverage.mtaBusID).contains(area))
                XCTAssertTrue(used, "\(key) in \(area)")
            }
        }
    }

    /// The area menu: the starting point's area first, then the ones used, the latest first, then the rest by name. A date is
    /// written again only an hour after the last one
    func testAreaUsageAndMenuOrder() throws {
        let name: (MetroArea) -> String = { $0.nameKey }
        XCTAssertEqual(MetroArea.menuOrder(start: nil, lastUsed: [:], name: name),
                       [.greaterBoston, .greaterHartford, .lehighValley, .newYork, .philadelphia, .westernMassachusetts])
        XCTAssertEqual(MetroArea.menuOrder(start: .philadelphia, lastUsed: [:], name: name),
                       [.philadelphia, .greaterBoston, .greaterHartford, .lehighValley, .newYork, .westernMassachusetts])
        let dates: [MetroArea: Date] = [.newYork: now, .lehighValley: now.addingTimeInterval(-86_400)]
        XCTAssertEqual(MetroArea.menuOrder(start: .philadelphia, lastUsed: dates, name: name),
                       [.philadelphia, .newYork, .lehighValley, .greaterBoston, .greaterHartford, .westernMassachusetts])
        XCTAssertEqual(MetroArea.menuOrder(start: .newYork, lastUsed: dates, name: name),
                       [.newYork, .lehighValley, .greaterBoston, .greaterHartford, .philadelphia, .westernMassachusetts])
        // Every area once, whatever is saved
        XCTAssertEqual(Set(MetroArea.menuOrder(start: .lehighValley, lastUsed: dates, name: name)), Set(MetroArea.allCases))

        let first = try XCTUnwrap(AreaUsage.noting(.newYork, at: now, in: nil))
        XCTAssertEqual(AreaUsage.dates(from: first), [.newYork: now])
        XCTAssertNil(AreaUsage.noting(.newYork, at: now.addingTimeInterval(600), in: first), "Written ten minutes ago")
        let later = try XCTUnwrap(AreaUsage.noting(.newYork, at: now.addingTimeInterval(7200), in: first))
        XCTAssertEqual(AreaUsage.dates(from: later), [.newYork: now.addingTimeInterval(7200)])
        let both = try XCTUnwrap(AreaUsage.noting(.lehighValley, at: now, in: later))
        XCTAssertEqual(AreaUsage.dates(from: both).count, 2)
        // Read leniently: an area that no longer exists, or a value of another type, is left out
        XCTAssertEqual(AreaUsage.dates(from: ["gone": 1.0, "philadelphia": "x", "newYork": 5]), [.newYork: Date(timeIntervalSince1970: 5)])
        XCTAssertEqual(AreaUsage.dates(from: "nonsense"), [:])
    }

    /// Which areas' data is downloaded: the starting point's, Plan a Trip's and the favorites' areas (not recent places); an operator
    /// in several areas while one of them is; one with a box only for a place inside it. Favorites in an area the user removed don't
    /// count
    func testPlacesInUseKeepAreas() throws {
        PlacesInUse.reset()
        defer { PlacesInUse.reset() }
        let timesSquare = Coordinate(latitude: 40.7580, longitude: -73.9855)
        let cityHall = Coordinate(latitude: 39.9524, longitude: -75.1636)
        let atlanticCity = Coordinate(latitude: 39.3643, longitude: -74.4229)
        let allentown = Coordinate(latitude: 40.6023, longitude: -75.4714)
        XCTAssertEqual(MetroArea.of(atlanticCity), .philadelphia)
        let septaBus = try XCTUnwrap(RegionalBusFeed.feed(code: RegionalBusFeed.septaCode))
        let lanta = try XCTUnwrap(RegionalBusFeed.feed(code: "LANTA"))
        // Nothing in use yet (a new install before the starting point is known): nothing is downloaded, New York's neither
        XCTAssertEqual(PlacesInUse.keptAreas, [])
        XCTAssertFalse(FerryFeed.Source.lirr.isWanted)
        XCTAssertFalse(RegionalBusFeed.njTransit.isWanted)

        PlacesInUse.set(.start, [timesSquare])
        XCTAssertEqual(PlacesInUse.keptAreas, [.newYork])
        XCTAssertTrue(FerryFeed.Source.lirr.isWanted)
        XCTAssertTrue(FerryFeed.Source.njTransitRail.isWanted, "NJ Transit is in all three areas")
        XCTAssertFalse(FerryFeed.Source.patco.isWanted, "Philadelphia's only")
        XCTAssertFalse(lanta.isWanted)
        XCTAssertFalse(septaBus.isWanted, "SEPTA's buses reach Trenton, in New York's area, but their box is around Philadelphia")

        // A favorite in Atlantic City: Philadelphia's area is kept, SEPTA's box isn't reached
        PlacesInUse.set(.favorites, [atlanticCity])
        XCTAssertEqual(PlacesInUse.keptAreas, [.newYork, .philadelphia])
        XCTAssertTrue(FerryFeed.Source.patco.isWanted)
        XCTAssertFalse(septaBus.isWanted)
        PlacesInUse.set(.favorites, [atlanticCity, cityHall])
        XCTAssertTrue(septaBus.isWanted)
        XCTAssertTrue(FerryFeed.Source.septaMetro.isWanted)

        // Philadelphia removed by the user: its favorites don't count
        PlacesInUse.setRemoved([.philadelphia])
        XCTAssertEqual(PlacesInUse.keptAreas, [.newYork])
        XCTAssertFalse(septaBus.isWanted)
        // ...until a place there is in Plan a Trip
        PlacesInUse.set(.planner, [cityHall])
        XCTAssertTrue(septaBus.isWanted)
        PlacesInUse.set(.planner, [allentown])
        XCTAssertTrue(lanta.isWanted)
        XCTAssertEqual(PlacesInUse.keptAreas, [.newYork, .lehighValley])
    }

    /// Why an area's data stays, and when it goes: the starting point's and Plan a Trip's areas can't be removed; favorites keep an
    /// area until the user removes it; another area goes 30 days after it was last used
    func testAreaDataReasons() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day: TimeInterval = 86_400
        func reason(_ area: MetroArea, start: MetroArea? = .newYork, planner: Set<MetroArea> = [], favorites: Set<MetroArea> = [],
                    removed: Set<MetroArea> = [], lastUsed: Date? = nil) -> AreaData.Reason? {
            AreaData.reason(for: area, start: start, planner: planner, favorites: favorites, removed: removed, lastUsed: lastUsed,
                            now: now, calendar: calendar)
        }
        XCTAssertEqual(reason(.newYork, favorites: [.newYork], removed: [.newYork]), .start)
        XCTAssertEqual(reason(.philadelphia, planner: [.philadelphia], removed: [.philadelphia]), .planner)
        XCTAssertEqual(reason(.philadelphia, favorites: [.philadelphia]), .favorites)
        XCTAssertEqual(reason(.philadelphia, favorites: [.philadelphia], removed: [.philadelphia]), .removedByYou)
        XCTAssertNil(reason(.philadelphia, removed: [.philadelphia], lastUsed: now), "Removed, no favorites: nothing to show")
        XCTAssertNil(reason(.philadelphia), "Never used")
        let used = now.addingTimeInterval(-10 * day)
        XCTAssertEqual(reason(.lehighValley, lastUsed: used), .unused(since: used, until: used.addingTimeInterval(30 * day)))
        XCTAssertNil(reason(.lehighValley, lastUsed: now.addingTimeInterval(-31 * day)))
        XCTAssertEqual(AreaData.removalDate(lastUsed: used, calendar: calendar), used.addingTimeInterval(30 * day))

        XCTAssertFalse(AreaData.Reason.start.canRemove)
        XCTAssertFalse(AreaData.Reason.planner.canRemove)
        XCTAssertTrue(AreaData.Reason.favorites.canRemove)
        XCTAssertTrue(AreaData.Reason.unused(since: used, until: now).canRemove)
        XCTAssertFalse(AreaData.Reason.removedByYou.keepsData)

        // An operator in several areas stays while one of them does
        XCTAssertTrue(AreaData.keeps(operatorIn: MetroArea.areas(of: .njTransitRail), keeping: [.lehighValley]))
        XCTAssertFalse(AreaData.keeps(operatorIn: MetroArea.areas(of: .patco), keeping: [.newYork, .lehighValley]))
        XCTAssertTrue(AreaData.keeps(operatorIn: [], keeping: []))

        // Sizes: an area's own operators on its row, those in several areas together, and the two add up to the total
        let split = AreaData.split([(MetroArea.areas(of: .septaMetro), 7), (MetroArea.areas(of: .patco), 2), (MetroArea.areas(of: .lirr), 40),
                                    (MetroArea.areas(of: .njTransitRail), 30), (MetroArea.areas(of: .amtrakNY), 3)])
        XCTAssertEqual(split.own, [.philadelphia: 9, .newYork: 40])
        XCTAssertEqual(split.shared, 33)
        XCTAssertEqual(split.total, 82)

        // The mark goes once a place there is the starting point or in Plan a Trip, not for a favorite
        XCTAssertEqual(AreaData.removedMarks([.philadelphia, .lehighValley], start: .philadelphia, planner: []), [.lehighValley])
        XCTAssertEqual(AreaData.removedMarks([.philadelphia, .lehighValley], start: .newYork, planner: [.lehighValley]), [.philadelphia])

        // Saved leniently
        let defaults = UserDefaults(suiteName: "AreaDataTests")!
        defer { defaults.removePersistentDomain(forName: "AreaDataTests") }
        AreaData.saveRemoved([.philadelphia], in: defaults)
        XCTAssertEqual(AreaData.removed(in: defaults), [.philadelphia])
        defaults.set(["gone", "lehighValley"], forKey: AreaData.removedKey)
        XCTAssertEqual(AreaData.removed(in: defaults), [.lehighValley])
        AreaData.saveRemoved([], in: defaults)
        XCTAssertNil(defaults.object(forKey: AreaData.removedKey))
    }

    /// The update to the version that removes areas: an area with data but no date of last use gets the day of the update, so
    /// nothing is removed in the 30 days after it
    func testStartingDatesAfterTheUpdate() {
        let before = now.addingTimeInterval(-5 * 86_400)
        let dates = AreaData.startingDates([.newYork: before], withData: [.newYork, .philadelphia], now: now)
        XCTAssertEqual(dates, [.newYork: before, .philadelphia: now])
        XCTAssertNil(AreaData.startingDates([.newYork: before], withData: [.newYork], now: now))
        let defaults = UserDefaults(suiteName: "AreaUsageSave")!
        defer { defaults.removePersistentDomain(forName: "AreaUsageSave") }
        AreaUsage.save([.philadelphia: now], in: defaults)
        XCTAssertEqual(AreaUsage.dates(in: defaults), [.philadelphia: now])
    }

    // MARK: Lists of many areas

    /// The states an area is in come from its counties: areas.json names the state of every county ("states") and no other, and
    /// an area's states are in the order of how many of its counties each has
    func testAreasStatesFollowTheirCounties() {
        let catalog = AreaCatalog.shared
        for county in catalog.counties {
            XCTAssertNotNil(catalog.states[AreaCatalog.state(ofCounty: county)],
                            "areas.json's \"states\" doesn't name the state of county \(county)")
        }
        XCTAssertEqual(Set(catalog.states.keys), Set(catalog.counties.map(AreaCatalog.state(ofCounty:))), "a state no area is in")
        XCTAssertEqual(catalog.states.count, Set(catalog.states.values).count, "two states with one name")
        XCTAssertEqual(MetroArea.newYork.stateKeys, ["New York", "New Jersey", "Connecticut", "Pennsylvania"])
        XCTAssertEqual(MetroArea.philadelphia.stateKeys, ["New Jersey", "Pennsylvania", "Delaware", "Maryland"])
        XCTAssertEqual(MetroArea.lehighValley.stateKeys, ["Pennsylvania", "New Jersey"])
        // New Hampshire and Rhode Island have 5 each: in the order of their codes
        XCTAssertEqual(MetroArea.greaterBoston.stateKeys, ["Massachusetts", "New Hampshire", "Rhode Island", "Maine"])
        XCTAssertEqual(MetroArea.greaterHartford.stateKeys, ["Connecticut"])
        XCTAssertEqual(MetroArea.westernMassachusetts.stateKeys, ["Massachusetts"])
        for area in MetroArea.allCases {
            XCTAssertFalse(area.stateKeys.isEmpty, area.rawValue)
            XCTAssertEqual(Set(area.regions), Set(MetroSubRegion.allCases.filter { $0.metroArea == area }), area.rawValue)
            XCTAssertEqual(area.regions.count, Set(area.regions).count, area.rawValue)
        }
        XCTAssertEqual(MetroArea.westernMassachusetts.regions, [.pioneerValley, .berkshires])
    }

    /// Downloaded data with many areas: up to 5 are listed as they came. With more, 5 are: the starting point's, Plan a Trip's
    /// and the ones with the most data; the others share one row. The full list has the most data first and the removed last
    func testDownloadedDataRowsWithManyAreas() {
        typealias Row = AreaList.Stored<Int>
        let unused = AreaData.Reason.unused(since: now, until: now.addingTimeInterval(86_400))
        let five = [Row(id: 1, reason: unused, size: 1), Row(id: 2, reason: .start, size: 10), Row(id: 3, reason: .favorites, size: 50),
                    Row(id: 4, reason: nil, size: 7), Row(id: 5, reason: .removedByYou, size: nil)]
        XCTAssertEqual(AreaList.folded(five).listed, five)
        XCTAssertTrue(AreaList.folded(five).others.isEmpty)
        XCTAssertEqual(AreaList.bySize(five).map(\.id), [2, 3, 4, 1, 5])

        // 50 areas, each taking as much as its number
        var many = (1...50).map { Row(id: $0, reason: unused, size: Int64($0)) }
        many[9].reason = .start
        many[19].reason = .planner
        many[29].reason = .favorites
        for removed in [2, 48] {
            many[removed].reason = .removedByYou
            many[removed].size = nil
        }
        let folded = AreaList.folded(many)
        XCTAssertEqual(folded.listed.map(\.id), [10, 20, 50, 48, 47])
        XCTAssertEqual(folded.others.count, 45)
        XCTAssertEqual(folded.others.prefix(3).map(\.id), [46, 45, 44])
        XCTAssertTrue(folded.others.contains { $0.id == 30 }, "favorites don't take a row by themselves")
        XCTAssertEqual(folded.others.suffix(2).map(\.id), [3, 49], "the removed ones last, as they came")
        XCTAssertEqual(folded.others.compactMap(\.size).reduce(0, +), 1048)
        XCTAssertEqual(AreaList.bySize(many).map(\.id), (folded.listed + folded.others).map(\.id))
        // Two Plan a Trip areas: both after the starting point's, as they came
        many[39].reason = .planner
        XCTAssertEqual(AreaList.folded(many).listed.map(\.id), [10, 20, 40, 50, 48])
        // With as much data: as they came
        let same = (1...7).map { Row(id: $0, reason: unused, size: 5) }
        XCTAssertEqual(AreaList.folded(same).listed.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(AreaList.folded(same).others.map(\.id), [6, 7])
        // A removed area never takes one of the rows
        let six = five + [Row(id: 6, reason: .removedByYou, size: nil)]
        XCTAssertEqual(AreaList.folded(six).listed.map(\.id), [2, 3, 4, 1])
        XCTAssertEqual(AreaList.folded(six).others.map(\.id), [5, 6])
        // Another limit
        XCTAssertEqual(AreaList.folded(five, limit: 2).listed.map(\.id), [2, 3])
    }

    /// The area menu with many areas: up to 5, all of them. With more, the ones in use in the menu's order, 5 at most, the one
    /// shown taking the last place if it isn't one of them (never 6); and whether areas were left out
    func testAreaMenuWithManyAreas() {
        var menu = AreaList.menu(order: [3, 1, 2], inUse: [1], shown: 2)
        XCTAssertEqual(menu.listed, [3, 1, 2])
        XCTAssertFalse(menu.all)
        let order = Array(1...50)
        menu = AreaList.menu(order: order, inUse: [40, 2, 4], shown: 4)
        XCTAssertEqual(menu.listed, [2, 4, 40])
        XCTAssertTrue(menu.all)
        XCTAssertEqual(AreaList.menu(order: order, inUse: [40, 2, 4], shown: 7).listed, [2, 4, 40, 7])
        // 5 in use already: the one shown takes the 5th place instead of making a 6th
        XCTAssertEqual(AreaList.menu(order: order, inUse: Set(1...9), shown: 9).listed, [1, 2, 3, 4, 9])
        XCTAssertEqual(AreaList.menu(order: order, inUse: Set(1...9), shown: 3).listed, [1, 2, 3, 4, 5])
        XCTAssertEqual(AreaList.menu(order: order, inUse: [], shown: nil).listed, [])
        XCTAssertEqual(AreaList.menu(order: order, inUse: [], shown: 99).listed, [], "one that isn't an area")
        XCTAssertTrue(AreaList.menu(order: order, inUse: [], shown: nil).all)

        // The app's own areas: the starting point's first, then by when they were last used
        let dates: [MetroArea: Date] = [.newYork: now, .lehighValley: now.addingTimeInterval(-86_400)]
        let six = MetroArea.menuOrder(start: .philadelphia, lastUsed: dates) { $0.nameKey }
        let some = AreaList.menu(order: six, inUse: [.lehighValley, .philadelphia, .newYork], shown: .philadelphia, limit: 5)
        XCTAssertEqual(some.listed, [.philadelphia, .newYork, .lehighValley])
        XCTAssertTrue(some.all)
        XCTAssertEqual(AreaList.menu(order: six, inUse: [.philadelphia], shown: .greaterHartford, limit: 5).listed,
                       [.philadelphia, .greaterHartford])
        // All six in use and the last one shown: it takes the 5th place, so the 5th in use is left to the full list
        let all = AreaList.menu(order: six, inUse: Set(six), shown: six.last, limit: 5)
        XCTAssertEqual(all.listed, Array(six.prefix(4)) + [six[5]])
        XCTAssertTrue(all.all)
        XCTAssertLessThanOrEqual(all.listed.count, AreaList.shownAtOnce)
    }

    /// The full list where an area is chosen is in the order of the names, whatever the case and the accents
    func testAreasByName() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(AreaList.byName(MetroArea.allCases, locale: english) { $0.nameKey },
                       [.greaterBoston, .greaterHartford, .lehighValley, .newYork, .philadelphia, .westernMassachusetts])
        XCTAssertEqual(AreaList.byName(["b", "\u{C9}cole", "a", "Area 10", "area 9", "eagle", "B"], locale: english) { $0 },
                       ["a", "area 9", "Area 10", "b", "B", "eagle", "\u{C9}cole"])
        XCTAssertEqual(AreaList.byName([3, 1, 2], locale: nil) { _ in "same" }, [3, 1, 2])
        XCTAssertEqual(AreaList.byName([Int](), locale: nil) { String($0) }, [])
    }

    /// The full list's search: part of a name, whatever the case, the accents and the spaces; an area is found by its own name,
    /// its regions' and its states'. An empty search finds everything
    func testAreaSearch() {
        XCTAssertEqual(AreaList.searchKey("  Long   ISLAND "), "long island")
        XCTAssertEqual(AreaList.searchKey("Montr\u{E9}al"), "montreal")
        XCTAssertEqual(AreaList.searchKey("\u{FF2E}\u{FF39}"), "ny", "full-width letters")
        XCTAssertTrue(AreaList.matches("", names: []))
        XCTAssertTrue(AreaList.matches("   ", names: ["x"]))
        XCTAssertFalse(AreaList.matches("y", names: ["x"]))
        XCTAssertTrue(AreaList.matches("r\u{E9}al", names: ["Montreal"]))
        func found(_ search: String) -> [MetroArea] {
            MetroArea.allCases.filter { AreaList.matches(search, names: $0.searchNames { $0 }) }
        }
        XCTAssertEqual(found(""), MetroArea.allCases)
        XCTAssertEqual(found("new york"), [.newYork])
        XCTAssertEqual(found("NEW JERSEY"), [.newYork, .philadelphia, .lehighValley])
        XCTAssertEqual(found("long is"), [.newYork])
        XCTAssertEqual(found("massachusetts"), [.greaterBoston, .westernMassachusetts])
        XCTAssertEqual(found("connecticut"), [.newYork, .greaterHartford])
        XCTAssertEqual(found("valley"), [.newYork, .lehighValley, .westernMassachusetts])
        XCTAssertEqual(found("berkshires"), [.westernMassachusetts])
        XCTAssertEqual(found("zzz"), [])
        // Each name once: Connecticut is a region's name and a state's in New York's area
        XCTAssertEqual(MetroArea.greaterHartford.searchNames { $0 },
                       ["Greater Hartford", "Hartford", "Northeastern Connecticut", "Northwest Hills", "Connecticut"])
        XCTAssertEqual(MetroArea.newYork.searchNames { $0 }.filter { $0 == "Connecticut" }.count, 1)
        // In the app's language and in English
        XCTAssertEqual(Array(MetroArea.westernMassachusetts.searchNames { "<" + $0 + ">" }.prefix(4)),
                       ["<Western Massachusetts>", "Western Massachusetts", "<Pioneer Valley>", "Pioneer Valley"])
    }
}
