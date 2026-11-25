import Foundation

// MARK: - Where places are on a map view, without asking the map

/// Where a place is on a map view, worked out the way the map draws it: the Web Mercator projection of Apple's maps (and most web
/// maps), from the area the view shows and the view's size. The maps lay their walking-time labels out with this instead of asking
/// MapKit for every station: asking makes SwiftUI finish every pending update of the window first, and that update has more than
/// once never finished. The transit map finds where a click is with it too (`coordinate(atX:y:)`), and never asks MapKit. Only for
/// a map that faces north and isn't tilted, and only while the area matches the view's shape (right after the window changes size
/// the map may still report its old area): `init` gives nil otherwise.
public struct MapProjection: Equatable, Sendable {
    /// The width and height of the whole world in map points (MapKit's MKMapSize.world): x grows east from the 180th meridian,
    /// y grows south from the top of the map
    public static let worldSize: Double = 268_435_456
    /// Meters per map point at the equator: the equator's length (WGS 84: 2 × pi × 6,378,137 m) over the world's width
    public static let metersPerMapPointAtEquator: Double = 2 * Double.pi * 6_378_137 / worldSize
    /// How far apart the shapes of the area and the view may be before the area counts as an old one
    public static let shapeTolerance: Double = 0.01
    /// Turned or tilted by less than this many degrees still counts as facing north, flat
    public static let angleTolerance: Double = 0.01

    /// The area shown, in map points
    public let x: Double, y: Double, width: Double, height: Double
    /// The view's size in points
    public let viewWidth: Double, viewHeight: Double

    /// - Parameters:
    ///   - x, y, width, height: the area the map shows (MKMapRect), in map points
    ///   - viewWidth, viewHeight: the map view's size in points
    ///   - heading: which way the map faces, in degrees (0 = north up)
    ///   - pitch: how far it's tilted, in degrees (0 = looking straight down)
    public init?(x: Double, y: Double, width: Double, height: Double, viewWidth: Double, viewHeight: Double,
                 heading: Double = 0, pitch: Double = 0) {
        guard width > 0, height > 0, viewWidth > 0, viewHeight > 0,
              [x, y, width, height, viewWidth, viewHeight, heading, pitch].allSatisfy(\.isFinite) else { return nil }
        guard Self.facesNorthFlat(heading: heading, pitch: pitch) else { return nil }
        guard Self.sameShape(width: width, height: height, viewWidth: viewWidth, viewHeight: viewHeight) else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// Whether a map facing this way (degrees, 0 = north up) and tilted this far (degrees, 0 = looking straight down) counts as
    /// facing north and flat, as the projection needs (within angleTolerance)
    public static func facesNorthFlat(heading: Double, pitch: Double) -> Bool {
        guard heading.isFinite, pitch.isFinite else { return false }
        let turned = heading.truncatingRemainder(dividingBy: 360)
        return min(abs(turned), 360 - abs(turned)) < angleTolerance && abs(pitch) < angleTolerance
    }

    /// Whether an area of this shape fills a view of that shape (within shapeTolerance)
    public static func sameShape(width: Double, height: Double, viewWidth: Double, viewHeight: Double) -> Bool {
        guard width > 0, height > 0, viewWidth > 0, viewHeight > 0 else { return false }
        return abs((width / height) / (viewWidth / viewHeight) - 1) <= shapeTolerance
    }

    /// Where a place is on the whole world's map, in map points (MapKit's MKMapPoint)
    public static func mapPoint(_ c: Coordinate) -> (x: Double, y: Double) {
        // The map stops short of the poles, where Mercator goes on forever
        let latitude = min(max(c.latitude, -85.05112878), 85.05112878) * Double.pi / 180
        let s = sin(latitude)
        let x = (c.longitude + 180) / 360 * worldSize
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * Double.pi)) * worldSize
        return (x, y)
    }

    /// The latitude, in degrees, at this height on the whole world's map
    public static func latitude(atMapY y: Double) -> Double {
        let n = Double.pi * (1 - 2 * y / worldSize)
        return atan(sinh(n)) * 180 / Double.pi
    }

    /// Where a place is on the view, in points from its top left corner (also in right-to-left languages, as MapKit gives them)
    public func point(_ c: Coordinate) -> (x: Double, y: Double) {
        var p = Self.mapPoint(c)
        // An area across the 180th meridian goes on past the world's right edge
        if p.x < x, x + width > Self.worldSize { p.x += Self.worldSize }
        return ((p.x - x) / width * viewWidth, (p.y - y) / height * viewHeight)
    }

    /// The place at a point of the view (points from its top left corner): the other way round from `point`, for a click on the map
    public func coordinate(atX px: Double, y py: Double) -> Coordinate {
        var mx = x + px / viewWidth * width
        // Past the world's right edge (an area across the 180th meridian): on the world's left again
        if mx >= Self.worldSize { mx -= Self.worldSize }
        let my = y + py / viewHeight * height
        return Coordinate(latitude: Self.latitude(atMapY: my), longitude: mx / Self.worldSize * 360 - 180)
    }

    /// Meters per point across the middle of the view (east to west, where the map's scale is measured)
    public var metersPerPoint: Double {
        let latitude = Self.latitude(atMapY: y + height / 2) * Double.pi / 180
        return Self.metersPerMapPointAtEquator * cos(latitude) * width / viewWidth
    }
}
