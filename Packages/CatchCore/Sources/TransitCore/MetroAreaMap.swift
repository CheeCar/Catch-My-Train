import Foundation

// MARK: - The metro areas on the map
//
// The map's dashed service-area line is drawn as one ring per metro area, with one line where two meet.
// The rings follow MetroSubRegion.of, the same code that names the region in the title bar (by county, see areas.json and CountyMap),
// worked out on a grid of small cells, so a place and the ring it's drawn in agree (to about a kilometer). Whole Map frames only the starting point's metro area (see
// SubwayMap.wholeMapPoints).

/// The service area's outline split by metro area: the outer edges of the areas, and the lines where two meet (drawn once)
public struct MetroOutline: Sendable, Equatable {
    /// Lines along the service area's edge (each a list of points, not closed: together with `shared` they make each area's ring)
    public var outer: [[Coordinate]]
    /// Where two metro areas meet (New York's and Philadelphia's from Bucks County down the Delaware River past Trenton, then along
    /// South Jersey's county line to the sea; the Lehigh Valley's along its counties' lines)
    public var shared: [[Coordinate]]
    /// Where each metro area's name is written on the map: the middle of the area (see labelCell), worked out from the same cells
    /// as the rings
    public var labels: [MetroArea: Coordinate]

    /// The outline for the service area and regions in this version (worked out once, on first use: about 180,000 cells)
    public static let current = MetroOutline.make(cell: 0.01)

    /// A name on one line, with the room kept around it, is about this many times as wide as it is high: the shape of the box
    /// labelCell looks for room for
    static let nameShape = 5.5

    /// Where a metro area's name is written on the map: the middle of the area, by one rule for every area, so a new area
    /// needs no spot picked for it. The name may cover stations: when it shows, the map is zoomed out too far to read them
    public static func labelPoint(_ area: MetroArea) -> Coordinate {
        // Every area has cells, so each has its point (MetroAreaMapTests checks that each is inside its own area); a name is never
        // written at the other value, which is outside the service area (see nameFits)
        current.labels[area] ?? Coordinate(latitude: 0, longitude: 0)
    }

    /// A name on two lines, for a map zoomed out too far for one: broken at the space nearest its middle. Nil for a name
    /// without a space (those are short)
    public static func twoLines(_ name: String) -> [String]? {
        let characters = Array(name)
        let spaces = characters.indices.filter { characters[$0] == " " && $0 > 0 && $0 < characters.count - 1 }
        guard let cut = spaces.min(by: { abs($0 * 2 - characters.count) < abs($1 * 2 - characters.count) }) else { return nil }
        return [String(characters[..<cut]), String(characters[(cut + 1)...])]
    }

    /// The cell a metro area's name is centered on, the same rule for every area: the middle of the area (the mean position
    /// of its cells). An oddly shaped area, whose middle is outside it or has less than half the room of its roomiest spot, takes
    /// that spot instead (the one nearest the middle among equals). "Room" is the biggest box of a name's shape (`columnsPerRow`
    /// columns wide for each row high) centered on the cell that lies inside the area. Nil for an area without cells
    static func labelCell(grid: [UInt8], rows: Int, cols: Int, area: UInt8, columnsPerRow: Double) -> (row: Int, col: Int)? {
        guard rows > 0, cols > 0, grid.count == rows * cols else { return nil }
        // The area's cells below and to the left of each grid point, so a box's cells are counted in one step
        let width = cols + 1
        var sums = [Int32](repeating: 0, count: (rows + 1) * width)
        var count = 0, rowSum = 0, colSum = 0
        for r in 0..<rows {
            var run: Int32 = 0
            for c in 0..<cols {
                if grid[r * cols + c] == area {
                    run += 1
                    count += 1
                    rowSum += r
                    colSum += c
                }
                sums[(r + 1) * width + c + 1] = sums[r * width + c + 1] + run
            }
        }
        guard count > 0 else { return nil }
        // Half the height, in rows, of the biggest such box around a cell; -1 for a cell outside the area. A smaller box lies
        // inside a bigger one, so the answer is found by halving
        func room(_ r: Int, _ c: Int) -> Int {
            guard grid[r * cols + c] == area else { return -1 }
            var low = 0, high = rows
            while low < high {
                let n = (low + high + 1) / 2
                let m = Int((Double(n) * columnsPerRow).rounded(.up))
                let r1 = r - n, r2 = r + n + 1, c1 = c - m, c2 = c + m + 1
                var inside = r1 >= 0 && c1 >= 0 && r2 <= rows && c2 <= cols
                if inside {
                    let cells = sums[r2 * width + c2] - sums[r1 * width + c2] - sums[r2 * width + c1] + sums[r1 * width + c1]
                    inside = Int(cells) == (r2 - r1) * (c2 - c1)
                }
                if inside { low = n } else { high = n - 1 }
            }
            return low
        }
        let middle = (row: Int((Double(rowSum) / Double(count)).rounded()), col: Int((Double(colSum) / Double(count)).rounded()))
        var best = (row: 0, col: 0, room: -1, distance: Int.max)
        for r in 0..<rows {
            for c in 0..<cols where grid[r * cols + c] == area {
                let n = room(r, c)
                let d = (r - middle.row) * (r - middle.row) + (c - middle.col) * (c - middle.col)
                if n > best.room || (n == best.room && d < best.distance) { best = (row: r, col: c, room: n, distance: d) }
            }
        }
        let atMiddle = room(middle.row, middle.col)
        if atMiddle >= 0, atMiddle * 2 >= best.room { return middle }
        return (row: best.row, col: best.col)
    }

    /// Whether a box this many meters wide and high, centered on the area's label point (or `northMeters` north of it, south when
    /// less than 0: a name moved to keep clear of the favorite stars, see nameShift), lies inside the area's ring: the maps write
    /// an area's name only then. Zooming out, a smaller area's name goes first, and two names can't cover each other however
    /// many areas there are. Checked along the box's edges and across its middle, every half a cell of the outline (the areas have
    /// no holes), corners first, so a box far too big is known at once
    public static func nameFits(_ area: MetroArea, widthMeters: Double, heightMeters: Double, northMeters: Double = 0) -> Bool {
        let point = labelPoint(area)
        let center = Coordinate(latitude: point.latitude + northMeters / 111_320, longitude: point.longitude)
        let metersPerDegree = 111_320.0
        let halfLat = heightMeters / 2 / metersPerDegree
        let halfLon = widthMeters / 2 / (metersPerDegree * cos(center.latitude * .pi / 180))
        // Bigger than any metro area (or not a size at all)
        guard halfLat >= 0, halfLon >= 0, halfLat < 3, halfLon < 3 else { return false }
        func inside(_ lat: Double, _ lon: Double) -> Bool {
            strictArea(Coordinate(latitude: lat, longitude: lon)) == area
        }
        let south = center.latitude - halfLat, north = center.latitude + halfLat
        let west = center.longitude - halfLon, east = center.longitude + halfLon
        guard inside(south, west), inside(south, east), inside(north, west), inside(north, east) else { return false }
        let step = 0.005
        let columns = max(1, Int(((east - west) / step).rounded(.up)))
        let rows = max(1, Int(((north - south) / step).rounded(.up)))
        for i in 0...columns {
            let lon = west + (east - west) * Double(i) / Double(columns)
            guard inside(south, lon), inside(center.latitude, lon), inside(north, lon) else { return false }
        }
        for i in 0...rows {
            let lat = south + (north - south) * Double(i) / Double(rows)
            guard inside(lat, west), inside(lat, center.longitude), inside(lat, east) else { return false }
        }
        return true
    }

    /// How far a metro area's name is moved up or down on the view (points, up less than 0, as on screen) to keep clear of the
    /// favorite stars (`stars`, their boxes on the view): not at all when it can stay; else up a little, down, further up, further
    /// down, the first move that keeps clear and still fits inside its ring (`fits`, given the move). Nil when none does: the name
    /// isn't written then, as when it doesn't fit (zooming in makes room). `name` is the name's box where it's written now
    public static func nameShift(name: MapLabelLayout.Box, stars: [MapLabelLayout.Box], fits: (Double) -> Bool) -> Double? {
        let step = name.height + nameShiftSpacing
        for shift in [0, -step, step, -2 * step, 2 * step] {
            let moved = MapLabelLayout.Box(x: name.x, y: name.y + shift, width: name.width, height: name.height)
            guard !stars.contains(where: { $0.touches(moved, spacing: nameStarSpacing) }) else { continue }
            if shift == 0 || fits(shift) { return shift }
        }
        return nil
    }

    /// Room between a name's box and the next place it can be moved to, and between a name and a star (points)
    static let nameShiftSpacing: Double = 6
    static let nameStarSpacing: Double = 3

    /// The metro area of a place in the service area, without the margin a user's own location gets (MetroArea.of has it); nil
    /// outside the service area. The same as ServiceArea.contains and MetroArea.of together, with one county lookup
    static func strictArea(_ p: Coordinate) -> MetroArea? {
        ServiceArea.county(p).flatMap { AreaCatalog.shared.region(ofCounty: $0) }.flatMap { MetroSubRegion(rawValue: $0.id)?.metroArea }
    }

    /// Works the outline out on a grid of cells `cell` degrees wide: each cell takes the metro area of its middle (none outside the
    /// service area); edges between cells of different areas are joined into lines, then thinned out (points closer than about a
    /// kilometer to the line between their neighbors are dropped; the edges of the service area's boxes, all straight, keep their corners)
    static func make(cell: Double) -> MetroOutline {
        guard let cells = Cells(cell: cell) else { return MetroOutline(outer: [], shared: [], labels: [:]) }
        let grid = cells.grid, rows = cells.rows, cols = cells.cols, lat0 = cells.lat0, lon0 = cells.lon0
        let areas = MetroArea.allCases
        func at(_ r: Int, _ c: Int) -> UInt8 { cells.at(r, c) }

        // Grid points (row, column); the edges around each area's cells go counterclockwise (the area on the left), each marked
        // with what is on the right: another area (a shared edge) or 0 (the service area's edge)
        struct P: Hashable { var r: Int; var c: Int }
        var outer: [[Coordinate]] = []
        var shared: [[Coordinate]] = []
        func point(_ p: P) -> Coordinate {
            Coordinate(latitude: ((lat0 + Double(p.r) * cell) * 1e4).rounded() / 1e4, longitude: ((lon0 + Double(p.c) * cell) * 1e4).rounded() / 1e4)
        }
        for (index, _) in areas.enumerated() {
            let me = UInt8(index + 1)
            var next: [P: [(to: P, other: UInt8)]] = [:]
            for r in 0...rows {
                for c in 0..<cols {
                    let below = at(r - 1, c), above = at(r, c)
                    if above == me, below != me { next[P(r: r, c: c), default: []].append((P(r: r, c: c + 1), below)) }
                    if below == me, above != me { next[P(r: r, c: c + 1), default: []].append((P(r: r, c: c), above)) }
                }
            }
            for c in 0...cols {
                for r in 0..<rows {
                    let left = at(r, c - 1), right = at(r, c)
                    if left == me, right != me { next[P(r: r, c: c), default: []].append((P(r: r + 1, c: c), right)) }
                    if right == me, left != me { next[P(r: r + 1, c: c), default: []].append((P(r: r, c: c), left)) }
                }
            }
            // Join the edges into rings, then cut each ring where what is on the other side changes: the service area's edge, or
            // the line shared with one area or another
            while let start = next.first(where: { !$0.value.isEmpty })?.key {
                var ring: [(at: P, other: UInt8)] = []
                var at = start
                while var list = next[at], let step = list.popLast() {
                    next[at] = list
                    ring.append((at, step.other))
                    at = step.to
                    if at == start { break }
                }
                guard ring.count >= 4 else { continue }
                // Start at a change, so no run is split in two by the ring's start
                if let change = ring.indices.first(where: { ring[$0].other != ring[($0 + ring.count - 1) % ring.count].other }) {
                    ring = Array(ring[change...] + ring[..<change])
                }
                var runs: [(other: UInt8, points: [P])] = []
                for (i, e) in ring.enumerated() {
                    if runs.last?.other == e.other {
                        runs[runs.count - 1].points.append(e.at)
                    } else {
                        if !runs.isEmpty { runs[runs.count - 1].points.append(e.at) }
                        runs.append((e.other, [e.at]))
                    }
                    if i == ring.count - 1 { runs[runs.count - 1].points.append(ring[0].at) }
                }
                for run in runs {
                    let line = run.points.map(point)
                    if run.other == 0 {
                        outer.append(thinned(line, meters: 300))
                    } else if run.other > me {
                        // Both areas trace the line they share: keep it once, from the one that comes first in MetroArea.allCases
                        // (every pair of areas, not only those with the first area)
                        shared.append(thinned(line, meters: 1100))
                    }
                }
            }
        }
        // Each area's name goes in its middle; the box's shape in cells (a degree east is shorter than a degree north)
        var labels: [MetroArea: Coordinate] = [:]
        let columnsPerRow = nameShape / cos((lat0 + Double(rows) * cell / 2) * .pi / 180)
        for (index, area) in areas.enumerated() {
            guard let spot = labelCell(grid: grid, rows: rows, cols: cols, area: UInt8(index + 1), columnsPerRow: columnsPerRow) else { continue }
            labels[area] = Coordinate(latitude: ((lat0 + (Double(spot.row) + 0.5) * cell) * 1e4).rounded() / 1e4,
                                      longitude: ((lon0 + (Double(spot.col) + 0.5) * cell) * 1e4).rounded() / 1e4)
        }
        return MetroOutline(outer: outer, shared: shared, labels: labels)
    }

    /// The cells `make` works on, `cell` degrees wide, row by row from the south-west corner of the service area's boxes, with one
    /// empty cell of margin all around (so every edge has a cell outside it): 0 outside the service area, else 1 + the index in
    /// MetroArea.allCases of the metro area of the cell's middle
    struct Cells {
        var grid: [UInt8]
        var rows: Int, cols: Int
        var lat0: Double, lon0: Double

        init?(cell: Double) {
            let boxes = ServiceArea.boxes
            guard let minLat = boxes.map(\.lat.lowerBound).min(), let maxLat = boxes.map(\.lat.upperBound).max(),
                  let minLon = boxes.map(\.lon.lowerBound).min(), let maxLon = boxes.map(\.lon.upperBound).max() else { return nil }
            lat0 = minLat - cell
            lon0 = minLon - cell
            rows = Int(((maxLat - minLat) / cell).rounded(.up)) + 2
            cols = Int(((maxLon - minLon) / cell).rounded(.up)) + 2
            grid = [UInt8](repeating: 0, count: rows * cols)
            let areas = MetroArea.allCases
            for r in 0..<rows {
                let lat = lat0 + (Double(r) + 0.5) * cell
                for c in 0..<cols {
                    let p = Coordinate(latitude: lat, longitude: lon0 + (Double(c) + 0.5) * cell)
                    guard let area = strictArea(p), let i = areas.firstIndex(of: area) else { continue }
                    grid[r * cols + c] = UInt8(i + 1)
                }
            }
        }

        func at(_ r: Int, _ c: Int) -> UInt8 { r >= 0 && r < rows && c >= 0 && c < cols ? grid[r * cols + c] : 0 }
    }

    /// How many separate pieces each metro area's cells make, counting cells that touch only at a corner as joined (a county line
    /// that turns inside a cell can leave one cell joined to the rest only at a corner). Each area is one piece, so it has one ring
    /// on the map: islands are joined to the mainland by the water between them (see ServiceArea.boxes)
    static func pieces(cell: Double) -> [MetroArea: Int] {
        guard let cells = Cells(cell: cell) else { return [:] }
        return pieces(of: cells.grid, rows: cells.rows, cols: cells.cols)
    }

    /// The same for a grid of cells like Cells's (row by row; 0 outside, else 1 + index in MetroArea.allCases)
    static func pieces(of grid: [UInt8], rows: Int, cols: Int) -> [MetroArea: Int] {
        let areas = MetroArea.allCases
        func at(_ r: Int, _ c: Int) -> UInt8 { r >= 0 && r < rows && c >= 0 && c < cols ? grid[r * cols + c] : 0 }
        var seen = [Bool](repeating: false, count: grid.count)
        var pieces: [MetroArea: Int] = [:]
        for start in grid.indices where grid[start] != 0 && !seen[start] {
            let me = grid[start]
            pieces[areas[Int(me) - 1], default: 0] += 1
            seen[start] = true
            var stack = [start]
            while let i = stack.popLast() {
                let r = i / cols, c = i % cols
                for dr in -1...1 {
                    for dc in -1...1 where at(r + dr, c + dc) == me {
                        let j = (r + dr) * cols + c + dc
                        if !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
        }
        return pieces
    }

    /// Drops points closer than `meters` to the line between the points kept around them (Douglas–Peucker); keeps both ends.
    /// A closed line (a whole ring on the service area's edge, such as an island's, which ends where it starts) is cut at its point
    /// farthest from the start and each half thinned: measured against a line from the start back to itself, every point would
    /// look close enough to drop
    static func thinned(_ points: [Coordinate], meters: Double) -> [Coordinate] {
        guard points.count > 2 else { return points }
        let k = cos(40.3 * .pi / 180)
        let xy = points.map { (x: $0.longitude * 111_320 * k, y: $0.latitude * 110_540) }
        if points[0] == points[points.count - 1] {
            let far = xy.indices.max(by: {
                (xy[$0].x - xy[0].x) * (xy[$0].x - xy[0].x) + (xy[$0].y - xy[0].y) * (xy[$0].y - xy[0].y)
                    < (xy[$1].x - xy[0].x) * (xy[$1].x - xy[0].x) + (xy[$1].y - xy[0].y) * (xy[$1].y - xy[0].y)
            }) ?? 0
            // Every point in the same place: nothing to thin
            guard xy[far].x != xy[0].x || xy[far].y != xy[0].y else { return points }
            return thinned(Array(points[...far]), meters: meters) + thinned(Array(points[far...]), meters: meters).dropFirst()
        }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            let dx = xy[b].x - xy[a].x, dy = xy[b].y - xy[a].y
            let length = max((dx * dx + dy * dy).squareRoot(), 1e-9)
            var best = -1.0, bestIndex = -1
            for i in (a + 1)..<b {
                let d = abs(dy * (xy[i].x - xy[a].x) - dx * (xy[i].y - xy[a].y)) / length
                if d > best { best = d; bestIndex = i }
            }
            if bestIndex > 0, best > meters {
                keep[bestIndex] = true
                stack.append((a, bestIndex))
                stack.append((bestIndex, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

extension SubwayMap {
    /// The points Whole Map frames when the starting point is in `area`: for Subway and Bus (`byLine`), every line that
    /// mostly runs in that area, whole (the River LINE counts as Philadelphia's, Trenton end too, so New York's Whole Map isn't pulled
    /// down to Trenton); for Train and Ferry, the stations in that area (an Amtrak line runs from Connecticut to Maryland, so no side is
    /// its own). Empty when the area has none: the caller then frames the whole map
    public func wholeMapPoints(in area: MetroArea, byLine: Bool) -> [[Double]] {
        if byLine {
            var result: [[Double]] = []
            for route in routes {
                let points = route.lines.flatMap { $0 }.filter { $0.count == 2 }
                guard !points.isEmpty else { continue }
                // A long bus line has thousands of points: a few hundred, evenly spread, are enough to tell where it mostly runs
                let step = max(1, points.count / 300)
                var counts: [MetroArea: Int] = [:]
                for i in stride(from: 0, to: points.count, by: step) {
                    if let a = MetroArea.of(Coordinate(latitude: points[i][0], longitude: points[i][1])) { counts[a, default: 0] += 1 }
                }
                let mine = counts[area] ?? 0
                guard mine > 0, mine * 2 > counts.values.reduce(0, +) else { continue }
                result += points
            }
            return result
        }
        return stations.filter { MetroArea.of(Coordinate(latitude: $0.lat, longitude: $0.lon)) == area }.map { [$0.lat, $0.lon] }
    }
}
