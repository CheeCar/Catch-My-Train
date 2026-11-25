import Foundation

/// Demo mode's area: the island of Manhattan, from the Battery up to Inwood, in three sketches: the interactive demo page's Midtown and
/// Lower Manhattan ones, and the north above them. The shapes are in meters east (x) and south (y) of Times Square, the page's own
/// units, so the app and the page agree on where a place can be chosen and which stations are shown.
public enum DemoArea {

    typealias Point = (x: Double, y: Double)

    /// Times Square, the point the page measures from
    static let origin = Coordinate(latitude: 40.7557, longitude: -73.9871)
    static let metersPerDegreeLongitude = 84_354.0
    static let metersPerDegreeLatitude = 110_990.0

    /// Manhattan north of the seam (the page's Midtown sketch): up to about 96 St on the west side and 110 St on the east side
    static let northLand: [Point] = [
        (-2353, 4517), (-2100, 3518), (-2016, 2519), (-1890, 1521), (-1805, 855), (-1884, 614), (-1491, -95), (-1181, -654), (-784, -1349),
        (-388, -2044), (27, -2729), (177, -3363), (683, -4362), (4564, -4362), (3804, -2697), (3298, -1698), (2961, -1032), (2497, -366),
        (1949, 300), (1738, 755), (1442, 1132), (1291, 1465), (1147, 2131), (1232, 2741), (1316, 3296), (1105, 4184), (599, 5072),
        (-1088, 5627)
    ]
    /// Manhattan south of the seam (the page's Lower Manhattan sketch), and Pier 11's pier
    static let southLand: [[Point]] = [
        [
            (-2016, 2297), (1105, 2297), (1274, 3407), (1063, 4295), (852, 4739), (430, 4906), (-76, 5017), (-666, 5128), (-962, 5350),
            (-1173, 5538), (-1426, 5683), (-1662, 5760), (-1805, 5849), (-1932, 5960), (-2033, 6049), (-2143, 6149), (-2252, 6093),
            (-2421, 6027), (-2564, 5905), (-2674, 5672), (-2691, 5294), (-2649, 4850), (-2480, 4351), (-2269, 3962), (-2143, 3296)
        ],
        [(-1645, 5738), (-1451, 5894), (-1485, 5927), (-1687, 5783)]
    ]
    /// Manhattan north of the Midtown sketch, up to Inwood (a sketch like the other two): it starts and ends at the Midtown sketch's
    /// top corners, so the two join along its top edge
    static let upperLand: [Point] = [
        (683, -4362), (835, -4806), (1122, -5361), (1442, -5916), (1780, -6471), (2050, -6915), (2303, -7303), (2413, -7581), (2607, -8136),
        (2792, -8358), (3045, -8802), (3231, -9356), (3315, -9911), (3366, -10466), (3534, -10799), (3804, -11243), (4100, -11687),
        (4395, -12131), (4665, -12575), (4859, -13019), (5087, -13408), (5238, -13552), (5475, -13463), (5728, -13330), (5972, -13197),
        (6208, -13086), (6402, -12986), (6546, -12819), (6462, -12464), (6293, -12131), (6166, -11798), (5913, -11465), (5660, -11132),
        (5340, -10688), (5137, -10244), (4943, -9800), (4774, -9356), (4631, -8912), (4547, -8469), (4521, -7914), (4521, -7359),
        (4521, -6804), (4547, -6249), (4631, -5805), (4817, -5416), (4943, -5139), (4901, -4750), (4564, -4362)
    ]
    /// Where the north sketch meets the Midtown one: points north of this line belong to the north
    static let upperEdge = -4362.0
    /// Water the page cuts out of its land (Newtown Creek, across the East River): outside Manhattan, kept so the test is the page's own
    static let water: [[Point]] = [
        [
            (2075, 2053), (2623, 1909), (3298, 1987), (3973, 1798), (4015, 1909), (3340, 2098), (2666, 2053), (2100, 2187)
        ]
    ]
    /// The two sketches join along a street line near Houston Street: points past it, at this angle and offset, belong to the north
    static let seamDegrees = 29.0
    static let seamOffset = -3360.0

    /// Where a coordinate is on the page's drawing, in meters east and south of Times Square
    static func point(_ c: Coordinate) -> Point {
        ((c.longitude - origin.longitude) * metersPerDegreeLongitude, (origin.latitude - c.latitude) * metersPerDegreeLatitude)
    }

    /// A place Demo mode can walk from: on Manhattan's land as drawn, in its sketch, and not in the river (a pin, or one of the demo's
    /// places)
    public static func contains(_ c: Coordinate) -> Bool {
        let q = point(c)
        let land = q.y < upperEdge ? [upperLand] : northOfSeam(q) ? [northLand] : southLand
        return land.contains { inside($0, q) } && !water.contains { inside($0, q) }
    }

    /// A station Demo mode shows: on Manhattan as drawn or within 150 m of its shore, so it's in walking range of some place that can be
    /// chosen (not the Bronx across the Harlem River, nor Marble Hill or Roosevelt Island)
    public static func includesStation(_ c: Coordinate) -> Bool {
        near(point(c), within: 150)
    }

    static func near(_ q: Point, within meters: Double) -> Bool {
        ([northLand, upperLand] + southLand).contains { inside($0, q) || distance($0, q) <= meters }
    }

    static func northOfSeam(_ q: Point) -> Bool {
        let a = seamDegrees * .pi / 180
        return q.x * sin(a) - q.y * cos(a) > seamOffset
    }

    /// Even-odd test, as the page does it
    static func inside(_ polygon: [Point], _ q: Point) -> Bool {
        var result = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > q.y) != (b.y > q.y), q.x < a.x + (q.y - a.y) * (b.x - a.x) / (b.y - a.y) { result.toggle() }
            j = i
        }
        return result
    }

    /// Distance from a point to a polygon's outline (meters)
    static func distance(_ polygon: [Point], _ q: Point) -> Double {
        var best = Double.infinity
        var j = polygon.count - 1
        for i in polygon.indices {
            let ax = polygon[j].x - q.x, ay = polygon[j].y - q.y
            let dx = polygon[i].x - polygon[j].x, dy = polygon[i].y - polygon[j].y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / length))
            best = min(best, hypot(ax + t * dx, ay + t * dy))
            j = i
        }
        return best
    }
}
