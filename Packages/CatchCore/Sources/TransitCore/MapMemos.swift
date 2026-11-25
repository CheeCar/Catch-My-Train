import Foundation

/// Remembers whether a metro area's name fits inside its ring (MetroOutline.nameFits), by zoom step. The check walks along the
/// name's box asking which county each point is in, and a map being zoomed asked it again for every area at each of the many
/// stops a zoom makes on its way. Zooms less than 2 percent apart are one step and get one answer, worked out for the step's own
/// scale (not for the zoom that happened to ask first), so a name shows from the same zoom every time.
public final class NameFitCache: @unchecked Sendable {
    private struct Key: Hashable {
        var area: MetroArea
        var step: Int
        /// The box's size in half points, and how far it is moved north in points
        var width: Int
        var height: Int
        var north: Int
    }

    private var answers: [Key: Bool] = [:]
    private var count = 0
    private let lock = NSLock()

    public init() {}

    /// One step is this factor of the map's scale
    public static let stepFactor = 1.02
    /// Past this many answers they are dropped and worked out again as asked (they are small; this only keeps them from adding up
    /// over days of use)
    static let kept = 20_000

    /// The step a scale (meters per point of the view) is in
    public static func step(metersPerPoint: Double) -> Int {
        Int((log(metersPerPoint) / log(stepFactor)).rounded())
    }

    /// The scale every zoom of a step is answered for
    public static func scale(ofStep step: Int) -> Double {
        pow(stepFactor, Double(step))
    }

    /// How many answers were worked out, not found remembered (for tests)
    public var workedOut: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Whether a box `widthPoints` by `heightPoints` on a view showing `metersPerPoint`, centered on the area's label point (or
    /// `northPoints` up the view from it, down when less than 0), lies inside the area's ring
    public func fits(_ area: MetroArea, widthPoints: Double, heightPoints: Double, metersPerPoint: Double,
                     northPoints: Double = 0) -> Bool {
        guard metersPerPoint > 0, metersPerPoint.isFinite, widthPoints.isFinite, heightPoints.isFinite, northPoints.isFinite,
              abs(widthPoints) < 100_000, abs(heightPoints) < 100_000, abs(northPoints) < 100_000 else { return false }
        let step = Self.step(metersPerPoint: metersPerPoint)
        let key = Key(area: area, step: step, width: Int((widthPoints * 2).rounded()), height: Int((heightPoints * 2).rounded()),
                      north: Int(northPoints.rounded()))
        lock.lock()
        defer { lock.unlock() }
        if let known = answers[key] { return known }
        if answers.count >= Self.kept { answers.removeAll(keepingCapacity: true) }
        let scale = Self.scale(ofStep: step)
        let answer = MetroOutline.nameFits(area, widthMeters: Double(key.width) / 2 * scale, heightMeters: Double(key.height) / 2 * scale,
                                           northMeters: Double(key.north) * scale)
        answers[key] = answer
        count += 1
        return answer
    }
}

/// The station dots a map draws, as lists that stay the very same arrays from one redraw of the map's view to the next while
/// nothing they are made from changes. The view is drawn again for every small thing (the mouse over a label, a label laid out
/// after a zoom), and lists made anew each time were compared station by station, several hundred of them, on every redraw:
/// an array that is the same one is known to be equal at once.
public struct StationDotLists: Sendable {
    private var base: [SubwayMap.Station] = []
    private var extra: [SubwayMap.Station] = []
    private var inRange: Set<String> = []
    private var fixed = false

    /// Every dot: the map's own stations, then the ones added to them
    public private(set) var all: [SubwayMap.Station] = []
    /// Every dot by station ID (the first of two with the same ID)
    public private(set) var byID: [String: SubwayMap.Station] = [:]
    /// The map's own stations by ID
    public private(set) var baseByID: [String: SubwayMap.Station] = [:]
    /// The dots sized in meters: all of them, or, while the stations in range are drawn at a fixed size, only the others
    public private(set) var circles: [SubwayMap.Station] = []
    /// The dots drawn at a fixed size on screen: the stations in range while zoomed in close, none otherwise
    public private(set) var fixedDots: [SubwayMap.Station] = []
    /// How many times the lists were made (for tests)
    public private(set) var made = 0

    public init() {}

    /// Makes the lists again only when something changed.
    /// - base: the map's own stations. Pass the stored array itself each time: an unchanged one is then known at once
    /// - extra: the few stations added to them (the ones without times), or the bus map's stops
    /// - inRange: the IDs of the stations in walking range
    /// - fixed: the stations in range are drawn at a fixed size (zoomed in close)
    public mutating func update(base: [SubwayMap.Station], extra: [SubwayMap.Station], inRange: Set<String>, fixed: Bool) {
        let sameStations = made > 0 && base == self.base && extra == self.extra
        if sameStations, fixed == self.fixed, !fixed || inRange == self.inRange { return }
        if !sameStations {
            self.base = base
            self.extra = extra
            all = extra.isEmpty ? base : base + extra
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            baseByID = extra.isEmpty ? byID : Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        self.inRange = inRange
        self.fixed = fixed
        circles = fixed ? all.filter { !inRange.contains($0.id) } : all
        fixedDots = fixed ? all.filter { inRange.contains($0.id) } : []
        made += 1
    }
}
