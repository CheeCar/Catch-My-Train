import Foundation

/// The large water areas of the service area: rivers, bays, the sea and canals of 0.1 km² or more, and lakes of 1 km² or more,
/// from the US Census Bureau's TIGER/Line AREAWATER (public domain), outlines simplified to about 15 m (water.bin, made by
/// tools/generate_water.py). Tells how much of the straight line from the starting place to a station runs over water: a
/// straight-line walk estimate across a river can be far too short (the real walk goes round by a bridge), see WalkEstimator.
public final class WaterMap: Sendable {
    /// This much water or more on the straight line counts as crossing water. Less is a bit of shore the simplified outline
    /// cuts off, a pond's corner, or the narrowest creek
    public static let crossingMeters: Double = 50
    /// A stretch of water at either end of the line counts this much less: a ferry pier reaching into the river, or a starting
    /// place on a pier, isn't across the water (crossing to a pier on the other side still is)
    public static let endAllowanceMeters: Double = 250
    /// Edges per box: the boxes let a line skip most of a long outline
    static let chunkEdges = 32

    /// The bundled water areas; nil only if water.bin is missing or damaged, and then nothing counts as across the water
    public static let shared: WaterMap? = {
        guard let url = Bundle.module.url(forResource: "water", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WaterMap(data: data)
    }()

    struct Box: Sendable {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        mutating func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        func overlaps(_ o: Box) -> Bool { minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY }
    }
    /// A run of up to chunkEdges edges of one ring: the edges start at points first..<end (each goes to the next point)
    struct Chunk: Sendable {
        let box: Box
        let first: Int
        let end: Int
    }
    struct Shape: Sendable {
        let box: Box
        let chunks: Range<Int>
    }

    /// Longitudes and latitudes of all points, ring after ring
    let xs: [Double]
    let ys: [Double]
    let chunks: [Chunk]
    let shapes: [Shape]

    /// How many shapes and points there are (for tests)
    public var shapeCount: Int { shapes.count }
    public var pointCount: Int { xs.count }

    /// Reads water.bin (format: tools/generate_water.py); nil if it isn't one
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 5, Array(bytes[0..<4]) == Array("CMTW".utf8), bytes[4] == 1 else { return nil }
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
        guard let shapeCount = number(), shapeCount < 1_000_000 else { return nil }
        var xs: [Double] = [], ys: [Double] = [], chunks: [Chunk] = [], shapes: [Shape] = []
        for _ in 0..<shapeCount {
            guard let ringCount = number(), ringCount < 1_000_000 else { return nil }
            var shapeBox = Box()
            let firstChunk = chunks.count
            for _ in 0..<ringCount {
                guard let pointCount = number(), pointCount < 10_000_000 else { return nil }
                let start = xs.count
                var x: Int64 = 0, y: Int64 = 0
                for _ in 0..<pointCount {
                    guard let dx = signed(), let dy = signed() else { return nil }
                    x += dx
                    y += dy
                    xs.append(Double(x) / 100_000)
                    ys.append(Double(y) / 100_000)
                }
                // Edges start at every point but the last (the ring is closed: the last point is the first again)
                var first = start
                while first < xs.count - 1 {
                    let end = min(first + Self.chunkEdges, xs.count - 1)
                    var box = Box()
                    for i in first...end { box.add(xs[i], ys[i]) }
                    chunks.append(Chunk(box: box, first: first, end: end))
                    shapeBox.add(box.minX, box.minY)
                    shapeBox.add(box.maxX, box.maxY)
                    first = end
                }
            }
            if chunks.count > firstChunk { shapes.append(Shape(box: shapeBox, chunks: firstChunk..<chunks.count)) }
        }
        guard pos == bytes.count else { return nil }
        self.xs = xs
        self.ys = ys
        self.chunks = chunks
        self.shapes = shapes
    }

    /// Whether the straight line from `a` to `b` crosses water (see crossingMeters, endAllowanceMeters)
    public func crosses(_ a: Coordinate, _ b: Coordinate) -> Bool {
        overWaterMeters(a, b) >= Self.crossingMeters
    }

    /// How many meters of the straight line from `a` to `b` run over water, each stretch that reaches an end counting
    /// endAllowanceMeters less (never below 0)
    public func overWaterMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let length = WalkEstimator.distanceMeters(a, b)
        guard length > 0 else { return 0 }
        // Over a few km, longitude and latitude can be treated as a flat plane: where along the line it meets an edge (t, 0 to 1)
        // is the same as in meters
        let ax = a.longitude, ay = a.latitude
        let dx = b.longitude - ax, dy = b.latitude - ay
        var line = Box()
        line.add(ax, ay)
        line.add(b.longitude, b.latitude)
        var stretches: [(Double, Double)] = []
        for shape in shapes where shape.box.overlaps(line) {
            var ts: [Double] = [0, 1]
            for c in chunks[shape.chunks] where c.box.overlaps(line) {
                for i in c.first..<c.end {
                    let ex = xs[i + 1] - xs[i], ey = ys[i + 1] - ys[i]
                    let den = dx * ey - dy * ex
                    guard den != 0 else { continue }
                    let qx = xs[i] - ax, qy = ys[i] - ay
                    let t = (qx * ey - qy * ex) / den
                    let u = (qx * dy - qy * dx) / den
                    if t >= 0, t <= 1, u >= 0, u <= 1 { ts.append(t) }
                }
            }
            ts.sort()
            for k in 0..<(ts.count - 1) where ts[k + 1] > ts[k] {
                let m = (ts[k] + ts[k + 1]) / 2
                if inside(shape, ax + m * dx, ay + m * dy) { stretches.append((ts[k], ts[k + 1])) }
            }
        }
        guard !stretches.isEmpty else { return 0 }
        // Join the stretches that touch (one river is often several shapes, cut at county lines), then add them up
        stretches.sort { $0.0 < $1.0 }
        let joinGap = 1 / length   // 1 m
        var joined: [(Double, Double)] = [stretches[0]]
        for s in stretches.dropFirst() {
            if s.0 <= joined[joined.count - 1].1 + joinGap {
                joined[joined.count - 1].1 = max(joined[joined.count - 1].1, s.1)
            } else {
                joined.append(s)
            }
        }
        let atEnd = 1e-9
        return joined.reduce(0) { total, s in
            var meters = (s.1 - s.0) * length
            if s.0 <= atEnd { meters -= Self.endAllowanceMeters }
            if s.1 >= 1 - atEnd { meters -= Self.endAllowanceMeters }
            return total + max(0, meters)
        }
    }

    /// Whether a point is inside a shape: a ray to the east crosses its rings an odd number of times (holes are islands)
    func inside(_ shape: Shape, _ x: Double, _ y: Double) -> Bool {
        var odd = false
        for c in chunks[shape.chunks] where c.box.minY <= y && c.box.maxY >= y && c.box.maxX >= x {
            for i in c.first..<c.end {
                let y1 = ys[i], y2 = ys[i + 1]
                guard (y1 > y) != (y2 > y) else { continue }
                if x < xs[i] + (y - y1) * (xs[i + 1] - xs[i]) / (y2 - y1) { odd.toggle() }
            }
        }
        return odd
    }
}
