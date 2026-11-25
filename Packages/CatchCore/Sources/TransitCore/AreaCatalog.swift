import Foundation

/// The metro areas and their regions and counties (Resources/areas.json). The app and tools/generate_areas.py both read it;
/// adding an area is adding it there, its counties' outlines (generate_areas.py) and a case in MetroArea
public struct AreaCatalog: Sendable {
    public struct Region: Sendable, Equatable {
        public let id: String
        public let name: String
        public let area: String
        public let counties: [Int]
    }
    public struct Area: Sendable, Equatable {
        public let id: String
        public let name: String
        /// The area's own time zone (IANA name): its timetables' days and the times shown for it are in it
        public let timeZone: String
        public let regions: [Region]
    }
    /// An operator: the areas it has stops in, with the kinds of vehicles it runs in each, and who its data is credited to
    public struct Operator: Sendable, Equatable {
        /// A FerryFeed.Source's raw value, "bus:" and a RegionalBusFeed code, or one that ships inside the app (subway, sir, tram, mtaBus, sle)
        public let id: String
        public let kinds: [String: [VehicleKind]]
        /// Nil: credited under its own name (the bus companies)
        public let credit: String?
        /// NJ Transit's light rail lines, each with the areas it stops in
        public let lines: [String: [String]]
        /// A shorter name where the credit or a bus company's own name is long ("PATH", "MBTA"): the few words naming whose live
        /// times are shown (LiveSource). Nil: the credit, else the company's name
        public var short: String? = nil
    }
    public let areas: [Area]
    public let operators: [Operator]
    /// The counties of no area that the service area's boxes reach into ("outside"): CountyMap has their outlines too, so a place
    /// in one is known to be outside the service area
    public let outside: [Int]
    /// The states the areas' counties are in ("states"): a state's code (the first two digits of its counties' codes) with its
    /// English name (a UI translation key). The full list of areas says which states each area is in and finds it by them
    public let states: [Int: String]
    let regionsByID: [String: Region]
    let regionByCounty: [Int: Region]
    let operatorsByID: [String: Operator]

    public static let shared: AreaCatalog = {
        guard let url = Bundle.module.url(forResource: "areas", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = AreaCatalog(data: data) else { return AreaCatalog(areas: []) }
        return catalog
    }()

    init(areas: [Area], operators: [Operator] = [], outside: [Int] = [], states: [Int: String] = [:]) {
        self.areas = areas
        self.operators = operators
        self.outside = outside
        self.states = states
        operatorsByID = Dictionary(operators.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byID: [String: Region] = [:], byCounty: [Int: Region] = [:]
        for region in areas.flatMap(\.regions) {
            byID[region.id] = region
            for county in region.counties { byCounty[county] = region }
        }
        regionsByID = byID
        regionByCounty = byCounty
    }

    /// Reads areas.json; nil if it isn't one
    public init?(data: Data) {
        struct FileRegion: Decodable { let id: String; let name: String; let counties: [String] }
        struct FileArea: Decodable { let id: String; let name: String; let timeZone: String; let regions: [FileRegion] }
        struct FileOperator: Decodable { let id: String; let areas: [String: [String]]; let credit: String?; let short: String?; let lines: [String: [String]]? }
        struct File: Decodable {
            let format: Int; let areas: [FileArea]; let operators: [FileOperator]?; let outside: [String]?; let states: [String: String]?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1 else { return nil }
        self.init(areas: file.areas.map { area in
            Area(id: area.id, name: area.name, timeZone: area.timeZone, regions: area.regions.map {
                Region(id: $0.id, name: $0.name, area: area.id, counties: $0.counties.compactMap { Int($0) })
            })
        }, operators: (file.operators ?? []).map { op in
            Operator(id: op.id, kinds: op.areas.mapValues { $0.compactMap(VehicleKind.init(rawValue:)) }, credit: op.credit, lines: op.lines ?? [:], short: op.short)
        }, outside: (file.outside ?? []).compactMap { Int($0) },
           states: Dictionary((file.states ?? [:]).compactMap { code, name in Int(code).map { ($0, name) } }, uniquingKeysWith: { a, _ in a }))
    }

    public func `operator`(_ id: String) -> Operator? { operatorsByID[id] }

    public func region(_ id: String) -> Region? { regionsByID[id] }
    public func region(ofCounty county: Int) -> Region? { regionByCounty[county] }
    public func area(_ id: String) -> Area? { areas.first { $0.id == id } }
    /// Every county of every area
    public var counties: [Int] { areas.flatMap { $0.regions.flatMap(\.counties) } }
    /// The state a county is in, by its code
    public static func state(ofCounty county: Int) -> Int { county / 1000 }
    /// The English names of the states an area's counties are in, the state with the most of them first (states with as many:
    /// in the order of their codes). A state "states" doesn't name is left out; MetroAreaMapTests checks that every one is named
    public func stateNames(of area: Area) -> [String] {
        var count: [Int: Int] = [:]
        for county in area.regions.flatMap(\.counties) { count[Self.state(ofCounty: county), default: 0] += 1 }
        return count.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.compactMap { states[$0.key] }
    }
}

/// The outlines of the areas' counties and of the counties next to them that the service area's boxes reach into (areas.json's
/// "outside"), from Resources/area_counties.bin, made by tools/generate_areas.py from the US Census Bureau's 2023 cartographic
/// boundary file, public domain; simplified to about 20 m
public final class CountyMap: @unchecked Sendable {
    struct Ring: Sendable {
        let xs: [Double]
        let ys: [Double]
        let minX: Double, maxX: Double, minY: Double, maxY: Double
    }
    struct County: Sendable {
        let code: Int
        let rings: [Ring]
        let minX: Double, maxX: Double, minY: Double, maxY: Double
    }
    let counties: [County]
    /// The counties of the metro areas; the others have outlines only so that a place in one, or on the water nearest one, is
    /// known to be outside the service area. Nil: every county is one of the areas'
    let counted: Set<Int>?
    /// An outline's segment, for county(near:)
    struct Segment: Sendable {
        let county: Int
        let ax: Double, ay: Double, bx: Double, by: Double
    }
    /// A grid over the outlines (cellSize degrees, with a margin), so a lookup reads only what is near the point: per cell, the
    /// counties whose box touches it and the segments that pass through it. The map's service area outline looks up some 180,000
    /// points, most of them on the water, so this keeps it about as fast as before counties were used
    static let cellSize = 0.05
    let gridX: Double, gridY: Double, cols: Int, rows: Int
    let cellCounties: [[Int]]
    let cellSegments: [[Int]]
    let segments: [Segment]
    /// What a cell no outline passes through is in, worked out the first time a point in it is looked up: a county (all of it is
    /// in that county), or the water (nothing; county(near:) gives the county nearest its middle for every point in it, so the
    /// water's split between counties is off by up to a cell, out where there are no stations). Guarded by `lock`: the only
    /// state that changes, which is why this class is @unchecked Sendable
    enum Whole { case land(Int), water(Int?) }
    private var wholeCells: [Int: Whole] = [:]
    private let lock = NSLock()

    public static let shared: CountyMap? = {
        guard let url = Bundle.module.url(forResource: "area_counties", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        let counties = AreaCatalog.shared.counties
        return CountyMap(data: data, counted: counties.isEmpty ? nil : Set(counties))
    }()

    /// Whether a county is one of the metro areas' (not one of those next to them)
    public func isCounted(_ code: Int) -> Bool { counted?.contains(code) ?? true }

    /// The county codes there are outlines for (for tests)
    public var codes: [Int] { counties.map(\.code) }

    /// Reads area_counties.bin (format: tools/generate_areas.py); nil if it isn't one. `counted`: the metro areas' counties (nil:
    /// all of them)
    public init?(data: Data, counted: Set<Int>? = nil) {
        self.counted = counted
        let bytes = [UInt8](data)
        guard bytes.count > 5, Array(bytes[0..<4]) == Array("CMTC".utf8), bytes[4] == 1 else { return nil }
        var pos = 5
        func number() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while pos < bytes.count, shift < 64 {
                let b = bytes[pos]
                pos += 1
                value |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        func signed() -> Int64? { number().map { Int64(bitPattern: ($0 >> 1) ^ (0 &- ($0 & 1))) } }
        guard let count = number(), count < 100_000 else { return nil }
        var counties: [County] = []
        for _ in 0..<count {
            guard let code = number(), let ringCount = number(), ringCount < 100_000 else { return nil }
            var rings: [Ring] = []
            for _ in 0..<ringCount {
                guard let pointCount = number(), pointCount < 10_000_000 else { return nil }
                var xs: [Double] = [], ys: [Double] = []
                xs.reserveCapacity(Int(pointCount)); ys.reserveCapacity(Int(pointCount))
                var x: Int64 = 0, y: Int64 = 0
                for _ in 0..<pointCount {
                    guard let dx = signed(), let dy = signed() else { return nil }
                    x += dx; y += dy
                    xs.append(Double(x) / 100_000); ys.append(Double(y) / 100_000)
                }
                guard xs.count >= 4 else { continue }
                rings.append(Ring(xs: xs, ys: ys, minX: xs.min()!, maxX: xs.max()!, minY: ys.min()!, maxY: ys.max()!))
            }
            guard !rings.isEmpty else { continue }
            counties.append(County(code: Int(code), rings: rings, minX: rings.map(\.minX).min()!, maxX: rings.map(\.maxX).max()!,
                                   minY: rings.map(\.minY).min()!, maxY: rings.map(\.maxY).max()!))
        }
        guard pos == bytes.count, !counties.isEmpty else { return nil }
        self.counties = counties
        let size = Self.cellSize
        let x0 = counties.map(\.minX).min()! - 0.3, y0 = counties.map(\.minY).min()! - 0.3
        let cols = Int((counties.map(\.maxX).max()! + 0.3 - x0) / size) + 1
        let rows = Int((counties.map(\.maxY).max()! + 0.3 - y0) / size) + 1
        func cell(_ x: Double, _ y: Double) -> (c: Int, r: Int) {
            (min(max(Int((x - x0) / size), 0), cols - 1), min(max(Int((y - y0) / size), 0), rows - 1))
        }
        var cellCounties = [[Int]](repeating: [], count: cols * rows)
        var cellSegments = [[Int]](repeating: [], count: cols * rows)
        var segments: [Segment] = []
        for (index, county) in counties.enumerated() {
            let lo = cell(county.minX, county.minY), hi = cell(county.maxX, county.maxY)
            for r in lo.r...hi.r { for c in lo.c...hi.c { cellCounties[r * cols + c].append(index) } }
            for ring in county.rings {
                var j = ring.xs.count - 1
                for i in ring.xs.indices {
                    let seg = Segment(county: county.code, ax: ring.xs[j], ay: ring.ys[j], bx: ring.xs[i], by: ring.ys[i])
                    let a = cell(min(seg.ax, seg.bx), min(seg.ay, seg.by)), b = cell(max(seg.ax, seg.bx), max(seg.ay, seg.by))
                    for r in a.r...b.r { for c in a.c...b.c { cellSegments[r * cols + c].append(segments.count) } }
                    segments.append(seg)
                    j = i
                }
            }
        }
        (gridX, gridY, self.cols, self.rows) = (x0, y0, cols, rows)
        self.cellCounties = cellCounties
        self.cellSegments = cellSegments
        self.segments = segments
    }

    /// What a cell no outline passes through is in (nil for a cell an outline passes through)
    func whole(_ col: Int, _ row: Int) -> Whole? {
        let index = row * cols + col
        guard cellSegments[index].isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = wholeCells[index] { return known }
        let middle = Coordinate(latitude: gridY + (Double(row) + 0.5) * Self.cellSize, longitude: gridX + (Double(col) + 0.5) * Self.cellSize)
        let answer: Whole
        if let code = Self.county(at: middle, among: cellCounties[index], in: counties) {
            answer = .land(code)
        } else {
            answer = .water(Self.nearest(to: middle, from: (col, row), kx: cos(middle.latitude * .pi / 180), cols: cols, rows: rows,
                                         cellSegments: cellSegments, segments: segments)?.code)
        }
        wholeCells[index] = answer
        return answer
    }

    /// The nearest segment to a point, searching the grid's cells in rings around the point's own until a ring can't hold
    /// anything nearer (every segment in ring n is at least n - 1 cells away): its county and squared distance. `among`: only
    /// these counties' outlines (nil: all)
    static func nearest(to c: Coordinate, from start: (c: Int, r: Int), kx: Double, cols: Int, rows: Int,
                        cellSegments: [[Int]], segments: [Segment], among: Set<Int>? = nil) -> (code: Int, d: Double)? {
        var best: (code: Int, d: Double)?
        for n in 0...max(cols, rows) {
            if let best, n > 0, Double(n - 1) * cellSize * kx * Double(n - 1) * cellSize * kx >= best.d { break }
            for r in (start.r - n)...(start.r + n) where r >= 0 && r < rows {
                for col in (start.c - n)...(start.c + n) where col >= 0 && col < cols {
                    guard max(abs(r - start.r), abs(col - start.c)) == n else { continue }
                    // A segment in two cells is measured twice: cheaper than remembering which were
                    for index in cellSegments[r * cols + col] {
                        let seg = segments[index]
                        if let among, !among.contains(seg.county) { continue }
                        let d = segmentDistance2(c, seg.ax, seg.ay, seg.bx, seg.by, kx)
                        if best == nil || d < best!.d { best = (seg.county, d) }
                    }
                }
            }
        }
        return best
    }

    /// The grid cell a point is in, nil outside the grid
    func cell(of c: Coordinate) -> (c: Int, r: Int)? {
        let col = Int(((c.longitude - gridX) / Self.cellSize).rounded(.down)), row = Int(((c.latitude - gridY) / Self.cellSize).rounded(.down))
        return col >= 0 && col < cols && row >= 0 && row < rows ? (col, row) : nil
    }

    /// The county the point is in (even-odd over all its rings), nil if none
    public func county(at c: Coordinate) -> Int? {
        guard let cell = cell(of: c) else { return nil }
        switch whole(cell.c, cell.r) {
        case .land(let code): return code
        case .water: return nil
        case nil: return Self.county(at: c, among: cellCounties[cell.r * cols + cell.c], in: counties)
        }
    }

    static func county(at c: Coordinate, among candidates: [Int], in counties: [County]) -> Int? {
        let x = c.longitude, y = c.latitude
        for index in candidates {
            let county = counties[index]
            guard x >= county.minX && x <= county.maxX && y >= county.minY && y <= county.maxY else { continue }
            var inside = false
            for ring in county.rings where x >= ring.minX && x <= ring.maxX && y >= ring.minY && y <= ring.maxY {
                var j = ring.xs.count - 1
                for i in ring.xs.indices {
                    let yi = ring.ys[i], yj = ring.ys[j]
                    if (yi > y) != (yj > y), x < ring.xs[i] + (y - yi) / (yj - yi) * (ring.xs[j] - ring.xs[i]) {
                        inside.toggle()
                    }
                    j = i
                }
            }
            if inside { return county.code }
        }
        return nil
    }

    /// The county the point is in, or else the county whose outline is nearest (on the water, or just outside the counties
    /// there are outlines for), whether it is one of the areas' or not. Nil only when there are no outlines
    public func county(near c: Coordinate) -> Int? {
        if let code = county(at: c) { return code }
        if let start = cell(of: c) {
            // All on the water: the cell's own answer
            if case .water(let code) = whole(start.c, start.r) { return code }
            return Self.nearest(to: c, from: start, kx: cos(c.latitude * .pi / 180), cols: cols, rows: rows, cellSegments: cellSegments,
                                segments: segments)?.code
        }
        return scanNearest(c, among: nil)?.code
    }

    /// The county of a metro area the point is in, or else the one whose outline is nearest, and how far that is in km (0 inside
    /// it): for a place in a county next to the areas, or on the water nearest one. Nil only when there are no outlines
    public func countedCounty(near c: Coordinate) -> (code: Int, km: Double)? {
        if let code = county(at: c), isCounted(code) { return (code, 0) }
        let best: (code: Int, d: Double)?
        if let start = cell(of: c) {
            best = Self.nearest(to: c, from: start, kx: cos(c.latitude * .pi / 180), cols: cols, rows: rows, cellSegments: cellSegments,
                                segments: segments, among: counted)
        } else {
            best = scanNearest(c, among: counted)
        }
        // Degrees of latitude: about 111.2 km each
        return best.map { ($0.code, $0.d.squareRoot() * 111.2) }
    }

    /// The nearest outline to a point outside the grid, looking at every county (of `among`, if given): its county and squared distance
    func scanNearest(_ c: Coordinate, among: Set<Int>?) -> (code: Int, d: Double)? {
        let kx = cos(c.latitude * .pi / 180)
        var best: (code: Int, d: Double)?
        for county in counties where among?.contains(county.code) ?? true {
            // A box's distance is no more than any of its points': skip counties whose box is already farther than the best
            let bx = max(county.minX - c.longitude, 0, c.longitude - county.maxX) * kx
            let by = max(county.minY - c.latitude, 0, c.latitude - county.maxY)
            if let best, bx * bx + by * by >= best.d { continue }
            for ring in county.rings {
                var j = ring.xs.count - 1
                for i in ring.xs.indices {
                    let d = Self.segmentDistance2(c, ring.xs[j], ring.ys[j], ring.xs[i], ring.ys[i], kx)
                    if best == nil || d < best!.d { best = (county.code, d) }
                    j = i
                }
            }
        }
        return best
    }

    /// Squared distance from the point to a segment, in degrees of latitude (longitudes scaled by kx)
    static func segmentDistance2(_ c: Coordinate, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ kx: Double) -> Double {
        let px = (c.longitude - ax) * kx, py = c.latitude - ay
        let dx = (bx - ax) * kx, dy = by - ay
        let len = dx * dx + dy * dy
        let t = len > 0 ? min(max((px * dx + py * dy) / len, 0), 1) : 0
        let ex = px - t * dx, ey = py - t * dy
        return ex * ex + ey * ey
    }
}
