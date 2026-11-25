import Foundation

// MARK: - Transit modes
//
// The whole app covers one region: the New York metro area (New York Metropolitan Area),
// not split into New York and New Jersey. The title bar only picks a transit mode, and each mode covers the whole metro area (merged by mode):
// Subway (including Staten Island Railway, Roosevelt Island Tram, PATH, New Jersey's three light rail lines, and SEPTA Metro and PATCO in Philadelphia),
// Bus (MTA buses + NJ Transit and other operators),
// Train (LIRR, Metro-North, NJ Transit, Amtrak...), Ferry (all ferries).
// Nearby stations are found by distance anyway, so near the state line (e.g. Hoboken, Port Authority) service from both sides shows together.

public enum TransitSystem: String, CaseIterable, Codable, Sendable, Identifiable {
    case subway
    /// Bus: MTA buses (live data, needs a Bus Time key) plus the regional operators (timetables, some with live data; see njBus)
    case bus
    /// Train (commuter rail): LIRR, Metro-North, SEPTA Regional Rail (live data), NJ Transit (timetable, live with the user's account), Amtrak (timetable)
    case train
    /// Ferry: NYC Ferry, NY Waterway (live data), Staten Island Ferry, Seastreak, Statue of Liberty ferry (timetables)
    case ferry
    /// PATH (New Jersey ↔ Manhattan), live data only (see PathLive); stations and lines come from PATH's timetable data
    case path
    /// Light rail: Hudson-Bergen Light Rail, Newark Light Rail, River LINE (NJ Transit timetables, live with the user's account where NJ Transit has it),
    /// with SEPTA Metro (live data) and PATCO (timetable) in Philadelphia, which are stored with them
    case lightRail
    /// The regional bus operators (NJ Transit, etc.): not shown separately, part of Bus (data stored together; only the nearby slice is used, see NJBusIndex)
    case njBus
    /// The former "New Jersey trains" and "New Jersey ferries": already merged into Train and Ferry, kept only to read previously saved settings
    case njTrain
    case njFerry

    public var id: String { rawValue }

    /// Transit modes selectable in the title bar (in display order). Just these four; PATH, light rail and the tram count as subway
    public static let modes: [TransitSystem] = [.subway, .bus, .train, .ferry]

    /// Which transit mode it displays as (previously saved "New Jersey trains", PATH, light rail, etc. map to the merged ones)
    public var mode: TransitSystem {
        switch self {
        case .njTrain: return .train
        case .njBus: return .bus
        case .njFerry: return .ferry
        case .path, .lightRail: return .subway
        default: return self
        }
    }

    /// Systems of the same kind (light rail counts as train)
    public enum Family: Sendable { case subway, bus, rail, ferry, path }

    public var family: Family {
        switch self {
        case .subway: return .subway
        case .bus, .njBus: return .bus
        case .train, .njTrain, .lightRail: return .rail
        case .ferry, .njFerry: return .ferry
        case .path: return .path
        }
    }

    /// Which system the timetable data is stored under (the former New Jersey trains and ferries use the merged data)
    public var dataSystem: TransitSystem {
        switch self {
        case .njTrain: return .train
        case .njFerry: return .ferry
        default: return self
        }
    }

    /// English name (UI translation key)
    public var nameKey: String {
        switch mode {
        case .subway: return "Subway"
        case .bus: return "Bus"
        case .ferry: return "Ferry"
        case .path: return "PATH"
        case .lightRail: return "Light Rail"
        default: return "Train"
        }
    }

    /// SF Symbols icon
    public var symbol: String {
        switch mode {
        case .subway: return "tram.fill"
        case .bus: return "bus.fill"
        case .ferry: return "ferry.fill"
        case .path: return "tram.tunnel.fill"
        case .lightRail: return "lightrail.fill"
        default: return "train.side.front.car"
        }
    }

    /// Departures all come from several operators' timetables (plus live data for some of them), downloaded on this Mac (see FerryFeed and the app's FerryStore):
    /// train, light rail, PATH and ferry. Subway uses MTA live data and the built-in station catalog;
    /// bus is half and half: MTA buses use live data, the other operators use timetables (see hasTimetablePart).
    public var usesTimetableFeed: Bool { family == .rail || family == .ferry || family == .path || self == .njBus }

    /// Whether some stations and departures come from timetables (FerryFeed): the timetable-based modes, plus bus (NJ Transit and a few others)
    /// and subway (PATH, light rail; grouped with the subway)
    public var hasTimetablePart: Bool { usesTimetableFeed || self == .bus || self == .subway }

    /// Which system the timetable data lives under (bus's timetable part is njBus)
    public var timetableSystem: TransitSystem { self == .bus ? .njBus : dataSystem }

    /// Which systems the timetable data is split across: subway has two (PATH and light rail), the others one
    public var timetableSystems: [TransitSystem] { self == .subway ? [.path, .lightRail] : [timetableSystem] }
}

// MARK: - Service area

/// The area this app covers: the metro areas' counties (areas.json), where they are inside the boxes below, drawn around the
/// stations with a few km of margin, so the far parts of large rural counties are left out. Where a part of an area's counties
/// lies between two parts of the service area, the boxes take it in too, with no stop nearby, so the service area has no holes
/// (tools/generate_areas.py checks). A place in a county of no area (one
/// the boxes reach into, areas.json's "outside") is outside; on the water or a pier, which are in no county, the nearest county
/// decides (see CountyMap). On launch, tell the user from their location whether they're inside this area; manually picked
/// locations must also be inside it.
public enum ServiceArea {
    /// Several lat/lon boxes (north latitude, longitude), each with a few km of margin all around. tools/generate_areas.py checks
    /// that every county they reach into is in an area or in areas.json's "outside"
    static let boxes: [(lat: ClosedRange<Double>, lon: ClosedRange<Double>)] = [
        // New York City, northern and central New Jersey, Westchester, Rockland, Orange, Putnam, Pike County PA
        (39.85...41.62, -75.35 ... -73.40),
        // Northern Hudson Valley: Dutchess (Poughkeepsie, Metro-North's Wassaic)
        (41.40...42.10, -74.30 ... -73.45),
        // Ulster (Kingston) and Sullivan (Monticello): the New York-Newark metro area (CSA) defined by the US government (OMB 2023) includes these two counties too
        (41.40...42.20, -75.20 ... -73.90),
        // Long Island (to Montauk)
        (40.50...41.20, -73.45 ... -71.80),
        // Southwestern Connecticut to New Haven, plus Shore Line East to New London and the bus lines east of it (Groton, Mystic, Foxwoods),
        // stopping short of Rhode Island (Westerly is at about -71.83)
        (40.95...41.62, -73.75 ... -71.84),
        // Southern New Jersey and Philadelphia (NJ Transit trains and buses run here)
        (38.85...39.90, -75.65 ... -73.85),
        // Philadelphia's western suburbs and northern Delaware (to Coatesville, Pottstown, Newark DE and Middletown DE), where the
        // trains and buses serving Philadelphia and Wilmington run
        (39.35...40.30, -75.90 ... -75.35),
        // Reading and the rest of Berks County, PA (part of the Philadelphia metro area): where BARTA's buses run. It reaches down
        // to the top of the box below, so no strip of the county is left between the two
        (40.20...40.60, -76.25 ... -75.53),
        // Western Chester County, PA (Oxford, Parkesburg) and Cecil County, MD (Elkton, North East, Perryville), also part of the
        // Philadelphia metro area: where TMACC's and Cecil Transit's buses run, and MARC's trains end (Perryville)
        (39.52...40.20, -76.15 ... -75.90),
        // The Lehigh Valley west of the first box, where LANta's and the Pocono Pony's buses run: Allentown, Bethlehem and the rest
        // of Lehigh County, Carbon County (Jim Thorpe, Palmerton) and western Northampton County; it reaches down to the top of the
        // western suburbs' box, so the upper Perkiomen Valley (Red Hill, Green Lane) between it and Berks County is in too. Then
        // western Monroe County (Mount Pocono) above it, in a box of its own so the first stops short of Wilkes-Barre
        (40.30...41.17, -76.04 ... -75.30),
        (41.10...41.29, -75.69 ... -75.30),
        // Greater Boston: Massachusetts east of Springfield's county and southern New Hampshire up to Portsmouth, north of the
        // Connecticut line. Its west edge takes in all of Worcester County, and the east edges of Hampden, Hampshire and Franklin
        // Counties (Palmer, Ware, Orange), which are Western Massachusetts'
        (42.00...43.10, -72.36 ... -70.55),
        // Rhode Island with Block Island, stopping short of Putnam, Connecticut; then southeastern Massachusetts (Fall River, New
        // Bedford, Plymouth), stopping short of Martha's Vineyard (in its own box below)
        (41.12...42.05, -71.87 ... -71.10),
        (41.48...42.05, -71.20 ... -70.60),
        // Cape Cod, to Provincetown and Chatham
        (41.52...42.10, -70.70 ... -69.90),
        // The islands south of Cape Cod, in one box with the water between them and the mainland, so Greater Boston is one piece
        // with straight edges: Dukes County (Martha's Vineyard with Chappaquiddick, Noman's Land, and the Elizabeth Islands out
        // to Cuttyhunk, their north end in the box above) and Nantucket County (Nantucket to Great Point, Tuckernuck, Muskeget).
        // Its south edge is Rhode Island's, its west edge meets Rhode Island's box and its east edge is Cape Cod's
        (41.12...41.52, -71.10 ... -69.90),
        // New Hampshire north of the first: Manchester's county, Concord, Laconia and Dover, and in Maine the part of York County
        // near COAST's stops (Berwick, South Berwick, Eliot; Kittery is in the first box). North of Berwick the east edge steps
        // west with the state line, keeping all of Strafford County, NH (it reaches -70.90 at 43.30° N and -70.957 at 43.52° N;
        // the strip of Maine left between the line and the edge is at most about 3 km wide), and from where Strafford County ends
        // it stays west of Maine, so the rest of York County is out, with the Downeaster's stations from Wells on
        (43.05...43.30, -72.25 ... -70.70),
        (43.30...43.35, -72.25 ... -70.90),
        (43.35...43.55, -72.25 ... -70.95),
        (43.55...43.80, -72.25 ... -71.00),
        // Greater Hartford: northern Connecticut from Bristol and Avon to Putnam and Killingly, between New York's box along the
        // coast and Massachusetts, with Storrs, Willimantic and Danielson (Bristol's and Willimantic's planning regions are New
        // York's). Then the Northwest Hills: Torrington, Winsted, New Hartford and the local buses' stops up to Canaan, with
        // Thomaston, where CTtransit's buses from Waterbury stop; it reaches west to New York, so Salisbury and Lakeville, with
        // no stops, are in too (left out, they'd be a hole between New York's area and the Berkshires)
        (41.55...42.05, -72.97 ... -71.80),
        (41.60...42.06, -73.55 ... -72.97),
        // Western Massachusetts: the Pioneer Valley, from Springfield, Holyoke and Westfield to Northampton, Amherst and Greenfield,
        // and on up to Vermont and New Hampshire, so Northfield, Bernardston, Colrain and Rowe, with no stops, are in too (left
        // out, they'd be a notch between the Berkshires and Greater Boston); then the Berkshires, from Great Barrington to
        // Pittsfield, North Adams and Williamstown, out to New York and down to Connecticut, so Sheffield, New Marlborough and
        // Sandisfield, with no stops, are in too (and Tolland, the Pioneer Valley's): left out, they'd be a hole between Great
        // Barrington and the Northwest Hills
        (42.00...42.75, -73.00 ... -72.20),
        (42.00...42.75, -73.52 ... -73.00),
    ]

    /// Inside the boxes and in a county of a metro area (or on the water nearest one)
    public static func contains(_ c: Coordinate) -> Bool {
        CountyMap.shared == nil ? inBoxes(c) : county(c) != nil
    }

    /// The county of a metro area a place in the service area is in (on the water, the nearest county); nil outside the service
    /// area, or when there are no county outlines
    static func county(_ c: Coordinate) -> Int? {
        guard inBoxes(c), let map = CountyMap.shared, let county = map.county(near: c), map.isCounted(county) else { return nil }
        return county
    }

    /// Inside the boxes, whatever county it is in
    static func inBoxes(_ c: Coordinate) -> Bool {
        boxes.contains { $0.lat.contains(c.latitude) && $0.lon.contains(c.longitude) }
    }

    /// The smallest lat/lon box holding all the boxes above: address search looks there first, so places anywhere in the service area rank alike
    public static let bounds: (lat: ClosedRange<Double>, lon: ClosedRange<Double>) = (
        boxes.map(\.lat.lowerBound).min()! ... boxes.map(\.lat.upperBound).max()!,
        boxes.map(\.lon.lowerBound).min()! ... boxes.map(\.lon.upperBound).max()!
    )

    /// Where a map shows these points (the metro areas' rings) so that none is hidden: the map's view is `view` points, of which only
    /// `visible` can be seen (the map runs on under the window's toolbar, and the buttons' panel covers a corner). The points' box is
    /// made as large as fits in `visible` and centered in it. Returns the part of the world to show in the whole view, in Web
    /// Mercator (0...1 each way, y down: MapKit's MKMapRect divided by the world's size); nil when there's nothing to fit or no room
    public static func frame(_ points: [Coordinate], view: (width: Double, height: Double),
                             visible: (x: Double, y: Double, width: Double, height: Double))
        -> (x: Double, y: Double, width: Double, height: Double)? {
        guard !points.isEmpty, view.width > 0, view.height > 0, visible.width > 0, visible.height > 0 else { return nil }
        let xs = points.map { mercatorX($0.longitude) }, ys = points.map { mercatorY($0.latitude) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        // The world per point of the view
        let scale = max((maxX - minX) / visible.width, (maxY - minY) / visible.height)
        guard scale > 0 else { return nil }
        let centerX = visible.x + visible.width / 2, centerY = visible.y + visible.height / 2
        return ((minX + maxX) / 2 - centerX * scale, (minY + maxY) / 2 - centerY * scale, view.width * scale, view.height * scale)
    }

    /// A box: in the view's points from its top left, or in Web Mercator (as frame returns)
    public struct Box: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
        public var text: String { String(format: "%.0fx%.0f at (%.0f, %.0f)", width, height, x, y) }
    }

    /// How far the points' box may be from where frame means it to be and still be in place: its middle, in points each way,
    /// and its size, as a share either way. A point or so is what the map's own rounding gives; a few points more don't show
    public static let fitCenterSlack = 8.0, fitSizeSlack = 0.03

    /// How a map drew these points after it was asked for an area (see check)
    public struct FitCheck: Equatable, Sendable {
        /// The points' box as drawn, and where frame means it to be: in the view's points
        public let drawn: Box, target: Box
        /// Whether it is in place: inside the part that can be seen (half a point either way), its middle at most fitCenterSlack
        /// points from the target's and its size within fitSizeSlack of it
        public let inPlace: Bool
        /// The area to ask the map for next (Web Mercator); nil when it's in place, or too far off to be the map's own way of
        /// showing what it was asked for (the map moved by hand, say)
        public let next: Box?
        /// The middle's distance from the target's, in points (drawn minus target), and the size against the target's (1: the same)
        public var offX: Double { drawn.midX - target.midX }
        public var offY: Double { drawn.midY - target.midY }
        public var size: Double { (drawn.width / target.width + drawn.height / target.height) / 2 }
        public var text: String {
            "rings \(drawn.text), should be \(target.text): " + String(format: "off x %.0f, y %.0f pt, size %.1f%%", offX, offY, size * 100)
        }
    }

    /// Where a map drew these points after it was asked for `asked` (Web Mercator, as frame returns), at `drawn` (the same points,
    /// in the view's points from its top left), against where frame means them to be: as large as fits in `visible` and centered
    /// in it. A map doesn't always show an area exactly as asked (it can come out a few percent larger, or moved), so when they
    /// aren't in place, `next` is `asked` put right by how far off they are on the screen: as much larger or smaller as they were
    /// drawn larger or smaller, and moved by as many points as they are off, at the scale they are drawn at now. It goes only by
    /// the two boxes on the screen, not by what the map seems to have shown, so a stop measured before the map took the last ask
    /// makes one correction too many or too few, which the next stop puts right; a size and a place both off take two. Nil when
    /// there's nothing to go by
    public static func check(_ points: [Coordinate], asked: Box, drawn: [(x: Double, y: Double)], view: (width: Double, height: Double),
                             visible: (x: Double, y: Double, width: Double, height: Double)) -> FitCheck? {
        guard points.count == drawn.count, points.count > 1, asked.width > 0, asked.height > 0,
              let target = frame(points, view: view, visible: visible) else { return nil }
        let xs = points.map { mercatorX($0.longitude) }, ys = points.map { mercatorY($0.latitude) }
        let dxs = drawn.map(\.x), dys = drawn.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              let dx0 = dxs.min(), let dx1 = dxs.max(), let dy0 = dys.min(), let dy1 = dys.max(), dx1 > dx0, dy1 > dy0 else { return nil }
        // Where frame means the box to be: the world per point of the view is the target's width over the view's
        let per = target.width / view.width
        let goal = Box(x: (x0 - target.x) / per, y: (y0 - target.y) / per, width: (x1 - x0) / per, height: (y1 - y0) / per)
        let box = Box(x: dx0, y: dy0, width: dx1 - dx0, height: dy1 - dy0)
        // Half a point either way is the same place
        let slack = 0.5
        let inside = dx0 >= visible.x - slack && dx1 <= visible.x + visible.width + slack && dy0 >= visible.y - slack
            && dy1 <= visible.y + visible.height + slack
        let inPlace = inside && abs(box.midX - goal.midX) <= fitCenterSlack && abs(box.midY - goal.midY) <= fitCenterSlack
            && abs(box.width / goal.width - 1) <= fitSizeSlack && abs(box.height / goal.height - 1) <= fitSizeSlack
        let check = FitCheck(drawn: box, target: goal, inPlace: inPlace, next: nil)
        guard !inPlace else { return check }
        // A map shows an area it is asked for, give or take a little: more than that is something else (the map moved by hand)
        guard (0.5...2).contains(check.size), abs(check.offX) < view.width / 2, abs(check.offY) < view.height / 2 else { return check }
        // The world per point of the view as drawn now; the area as many times larger as the box was drawn, around its middle,
        // and moved the way that brings the box back (an area further left shows the box further right)
        let now = (x1 - x0 + y1 - y0) / (box.width + box.height)
        let width = asked.width * check.size, height = asked.height * check.size
        let next = Box(x: asked.midX + check.offX * now - width / 2, y: asked.midY + check.offY * now - height / 2,
                       width: width, height: height)
        return FitCheck(drawn: box, target: goal, inPlace: false, next: next)
    }

    /// Web Mercator, as MapKit's map points: 0 at 180° W, 1 at 180° E
    public static func mercatorX(_ longitude: Double) -> Double { (longitude + 180) / 360 }

    /// Web Mercator, as MapKit's map points: 0 at the top (about 85° N), 0.5 at the equator, y down
    public static func mercatorY(_ latitude: Double) -> Double {
        let s = sin(latitude * .pi / 180)
        return 0.5 - log((1 + s) / (1 - s)) / (4 * .pi)
    }

    /// The basis for the area: all counties of the New York-Newark, NY-NJ-CT-PA metro area (Combined Statistical Area) defined by the US government (OMB, 2023),
    /// plus New Haven, Philadelphia and New London, where trains from these places run, and the bus and train operators around Philadelphia,
    /// Wilmington and New London, so that every operator with public data in the area is covered without cutting its lines, and all counties
    /// of the Allentown-Bethlehem-East Stroudsburg, PA-NJ metro area (Combined Statistical Area, OMB 2023), the Lehigh Valley, and
    /// of the Boston-Worcester-Providence, MA-RI-NH metro area (Combined Statistical Area, OMB 2023), Greater Boston.
    /// When checking whether the user is in the service area, add another 15 km all around (just in case, so places on the edge aren't wrongly judged outside).
    /// There's no official standard for 15 km: it's roughly the drive to a suburban park-and-ride station.
    /// Only used for the user's location and picked locations; trimming stations during download still uses contains.
    public static let userMarginKm: Double = 15

    /// Outer ring of the service area (for drawing a dashed line on the map): the outline of the boxes above combined,
    /// the same area used for "is it in the service area" (without the extra 15 km for the user's location).
    /// Each ring is a closed loop of points (the last point doesn't repeat the first).
    public static let outline: [[Coordinate]] = outline(of: boxes)

    /// Outline of several merged rectangles: cut lat/lon into small cells, find edges between an "inside" cell and an "outside" cell, then join them into rings.
    static func outline(of boxes: [(lat: ClosedRange<Double>, lon: ClosedRange<Double>)]) -> [[Coordinate]] {
        let lats = Array(Set(boxes.flatMap { [$0.lat.lowerBound, $0.lat.upperBound] })).sorted()
        let lons = Array(Set(boxes.flatMap { [$0.lon.lowerBound, $0.lon.upperBound] })).sorted()
        guard lats.count > 1, lons.count > 1 else { return [] }
        let rows = lats.count - 1, cols = lons.count - 1
        var inside = Array(repeating: Array(repeating: false, count: cols), count: rows)
        for r in 0..<rows {
            let lat = (lats[r] + lats[r + 1]) / 2
            for c in 0..<cols {
                let lon = (lons[c] + lons[c + 1]) / 2
                inside[r][c] = boxes.contains { $0.lat.contains(lat) && $0.lon.contains(lon) }
            }
        }
        func isIn(_ r: Int, _ c: Int) -> Bool { r >= 0 && r < rows && c >= 0 && c < cols && inside[r][c] }
        // Grid points (row, col); each edge is stored counterclockwise (inside on the left), and the next edge is found from its start
        struct P: Hashable { var r: Int; var c: Int }
        var next: [P: [P]] = [:]
        for r in 0...rows {
            for c in 0..<cols {
                // Horizontal edge: between cells (r-1, c) and (r, c)
                let below = isIn(r - 1, c), above = isIn(r, c)
                if above && !below { next[P(r: r, c: c), default: []].append(P(r: r, c: c + 1)) }
                if below && !above { next[P(r: r, c: c + 1), default: []].append(P(r: r, c: c)) }
            }
        }
        for c in 0...cols {
            for r in 0..<rows {
                // Vertical edge: between cells (r, c-1) and (r, c)
                let left = isIn(r, c - 1), right = isIn(r, c)
                if left && !right { next[P(r: r, c: c), default: []].append(P(r: r + 1, c: c)) }
                if right && !left { next[P(r: r + 1, c: c), default: []].append(P(r: r, c: c)) }
            }
        }
        var loops: [[Coordinate]] = []
        while let start = next.first(where: { !$0.value.isEmpty })?.key {
            var loop: [P] = [start]
            var at = start
            while let to = next[at]?.popLast() {
                if to == start { break }
                loop.append(to)
                at = to
            }
            // Drop points in the middle of a straight line
            let n = loop.count
            let corners = loop.indices.filter { i in
                let a = loop[(i + n - 1) % n], b = loop[i], d = loop[(i + 1) % n]
                return !((a.r == b.r && b.r == d.r) || (a.c == b.c && b.c == d.c))
            }.map { loop[$0] }
            if corners.count >= 4 {
                loops.append(corners.map { Coordinate(latitude: lats[$0.r], longitude: lons[$0.c]) })
            }
        }
        return loops
    }

    /// The service area with userMarginKm more all around: inside the boxes widened by it, and in a county of a metro area or
    /// no farther than that from one (so a place just over a county line, or just outside a box, is still in)
    public static func containsWithMargin(_ c: Coordinate) -> Bool {
        county(withMargin: c) != nil || (inBoxesWithMargin(c) && CountyMap.shared == nil)
    }

    /// The county of a metro area a place counts in, with the margin a user's own location gets: the county it is in (on the
    /// water, the nearest), or one no farther than userMarginKm away; nil outside the boxes widened by that much
    static func county(withMargin c: Coordinate) -> Int? {
        guard inBoxesWithMargin(c), let map = CountyMap.shared, let county = map.county(near: c) else { return nil }
        if map.isCounted(county) { return county }
        guard let nearest = map.countedCounty(near: c), nearest.km <= userMarginKm else { return nil }
        return nearest.code
    }

    static func inBoxesWithMargin(_ c: Coordinate) -> Bool {
        let dLat = userMarginKm / 111.0
        let dLon = userMarginKm / (111.0 * cos(c.latitude * .pi / 180))
        return boxes.contains {
            c.latitude >= $0.lat.lowerBound - dLat && c.latitude <= $0.lat.upperBound + dLat
                && c.longitude >= $0.lon.lowerBound - dLon && c.longitude <= $0.lon.upperBound + dLon
        }
    }
}

// MARK: - Regions within the metro area

/// The title bar shows "New York Metropolitan Area · region · in or out of the service area". A region is a group of counties
/// (areas.json), so it follows the real county lines; the metro area is the one the region belongs to
public enum MetroSubRegion: String, CaseIterable, Sendable {
    case newYorkCity, longIsland, hudsonValley, northernNewJersey, centralNewJersey, southJersey, philadelphia, delaware, connecticut, pikeCounty,
         berksCounty, cecilCounty, lehighCounty, northamptonCounty, carbonCounty, monroeCounty, warrenCounty,
         boston, northShore, southShore, centralMassachusetts, bristolCounty, capeCod, dukesCounty, nantucketCounty, rhodeIsland, newHampshire,
         yorkCounty, hartford, northeasternConnecticut, northwestHills, pioneerValley, berkshires

    /// English name (UI translation key), from areas.json
    public var nameKey: String { AreaCatalog.shared.region(rawValue)?.name ?? rawValue }

    /// The metro area this region belongs to (areas.json)
    public var metroArea: MetroArea {
        AreaCatalog.shared.region(rawValue).flatMap { MetroArea(rawValue: $0.area) } ?? .newYork
    }

    /// Which region this location is in; nil when outside the service area (with the margin a user's own location gets). Inside
    /// it, the county the place is in, or on the water the nearest county (the county outlines follow the shore, so a pier or a
    /// ferry's route is in no county); at the edges, just over the line from an area's county, that county
    public static func of(_ c: Coordinate) -> MetroSubRegion? {
        guard let county = ServiceArea.county(withMargin: c), let region = AreaCatalog.shared.region(ofCounty: county) else { return nil }
        return MetroSubRegion(rawValue: region.id)
    }
}
