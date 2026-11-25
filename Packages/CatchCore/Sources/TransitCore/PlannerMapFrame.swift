import Foundation

/// Plan a Trip's map column: when the window is wide enough to have one, how wide it is, and what part of the map it shows.
/// Kept apart from the view so it can be tested.
public enum PlannerMapFrame {
    /// Narrower than this (the window's content width, in points) the map column is folded away and the list has the whole width
    public static let collapseBelow: Double = 860
    /// The column takes this share of the width, but never less than `minColumn` nor more than `maxColumn` points
    public static let share: Double = 0.4
    public static let minColumn: Double = 280
    public static let maxColumn: Double = 400

    public static func showsColumn(windowWidth: Double) -> Bool {
        windowWidth >= collapseBelow
    }

    public static func columnWidth(windowWidth: Double) -> Double {
        min(maxColumn, max(minColumn, (windowWidth * share).rounded()))
    }

    /// A part of the map: its middle and how far it reaches north–south and east–west, in degrees
    public struct Region: Equatable, Sendable {
        public var center: Coordinate
        public var latitudeSpan: Double
        public var longitudeSpan: Double

        public init(center: Coordinate, latitudeSpan: Double, longitudeSpan: Double) {
            self.center = center
            self.latitudeSpan = latitudeSpan
            self.longitudeSpan = longitudeSpan
        }

        /// Whether a point is inside
        public func contains(_ c: Coordinate) -> Bool {
            abs(c.latitude - center.latitude) <= latitudeSpan / 2 && abs(c.longitude - center.longitude) <= longitudeSpan / 2
        }
    }

    /// Meters in one degree of latitude
    static let metersPerDegree = 111_320.0

    /// What the map shows at first: the outer walking circle around the place and every station listed, with `margin` of the width
    /// left free on each side (so the dots and the circle aren't on the edge)
    public static func region(place: Coordinate, radiusMeters: Double, stations: [Coordinate], margin: Double = 0.12) -> Region {
        let radius = max(radiusMeters, 100)
        let dLat = radius / metersPerDegree
        let dLon = radius / (metersPerDegree * max(cos(place.latitude * .pi / 180), 0.01))
        var minLat = place.latitude - dLat, maxLat = place.latitude + dLat
        var minLon = place.longitude - dLon, maxLon = place.longitude + dLon
        for s in stations {
            minLat = min(minLat, s.latitude)
            maxLat = max(maxLat, s.latitude)
            minLon = min(minLon, s.longitude)
            maxLon = max(maxLon, s.longitude)
        }
        let grow = 1 + 2 * max(margin, 0)
        return Region(center: Coordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                      latitudeSpan: (maxLat - minLat) * grow, longitudeSpan: (maxLon - minLon) * grow)
    }
}
