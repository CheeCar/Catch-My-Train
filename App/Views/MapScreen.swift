import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// Where places are on a map's view, for its walking-time labels and the size of its station dots (the transit map's and Plan a
/// Trip's). Worked out with MapProjection from the area the map last reported; asking MapKit instead (MapProxy.convert) makes SwiftUI
/// bring the whole window up to date first, and that has more than once never finished: the app hung, the map blank, with the map
/// window open while what it showed was all replaced (another transit mode, Demo mode turned off), asked from a view's action
/// (onChange) and also from a task a moment later. So the transit map never asks MapKit: it has no MapReader. Where the projection
/// can't be used (before the map has reported an area that fits the view, or while it's turned or tilted) it waits for the map's next
/// report, and while it's turned or tilted it shows no labels and takes clicks on its own buttons only (SubwayMapView.layoutLabels).
/// Plan a Trip's map still asks, askLaterMilliseconds after a view's action and only while it can be seen: there the projection came
/// out 76 points off where MapKit draws the stations (PlannerMapView.mapScreen)
@MainActor struct MapScreen {
    /// How long after a view's action Plan a Trip's map lays its labels out, asking MapKit (see above)
    static let askLaterMilliseconds = 200

    /// What it's worked out with (nil: MapKit is asked)
    let projection: MapProjection?
    private let proxy: MapProxy?
    /// Meters per point across the middle of the view (0 if MapKit couldn't say)
    let metersPerPoint: Double

    init(_ projection: MapProjection) {
        self.projection = projection
        proxy = nil
        metersPerPoint = projection.metersPerPoint
    }

    init(asking proxy: MapProxy, size: CGSize) {
        projection = nil
        self.proxy = proxy
        metersPerPoint = MapScreen.metersPerPoint(asking: proxy, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// Where a place is on the view, in the view's own points (nil if MapKit couldn't say)
    func point(_ c: Coordinate) -> CGPoint? {
        if let projection {
            let p = projection.point(c)
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        return proxy?.convert(c.clCoordinate, to: .local)
    }

    /// The place at a point of the view (a click), worked out with the projection: nil when MapKit was asked instead
    func coordinate(at p: CGPoint) -> Coordinate? {
        projection?.coordinate(atX: Double(p.x), y: Double(p.y))
    }

    /// Whether the map last reported an area that fits the view's size now but is turned or tilted: the projection can't be used
    /// until it faces north and is flat again
    static func isTurned(_ visible: MapVisibleRect?, size: CGSize) -> Bool {
        guard let visible, abs(visible.size.width - size.width) <= 0.5, abs(visible.size.height - size.height) <= 0.5 else { return false }
        return !MapProjection.facesNorthFlat(heading: visible.heading, pitch: visible.pitch)
    }

    /// The projection for the area a map last reported and the view's size now: nil before the map has reported an area, when the
    /// view's size has changed since (the area is an old one until the map reports again), or when the projection can't be used
    static func projection(_ visible: MapVisibleRect?, size: CGSize) -> MapProjection? {
        guard let visible, abs(visible.size.width - size.width) <= 0.5, abs(visible.size.height - size.height) <= 0.5 else { return nil }
        let rect = visible.rect
        return MapProjection(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height,
                             viewWidth: Double(size.width), viewHeight: Double(size.height),
                             heading: visible.heading, pitch: visible.pitch)
    }

    /// Meters per point at a point of the view, asked of MapKit: the distance to the point 10 points to its right, over 10
    static func metersPerPoint(asking proxy: MapProxy, at point: CGPoint) -> Double {
        guard let a = proxy.convert(point, from: .local),
              let b = proxy.convert(CGPoint(x: point.x + 10, y: point.y), from: .local) else { return 0 }
        return WalkEstimator.distanceMeters(Coordinate(latitude: a.latitude, longitude: a.longitude),
                                            Coordinate(latitude: b.latitude, longitude: b.longitude)) / 10
    }
}

/// The area a map showed after its last move (onMapCameraChange), with which way it faced, how far it was tilted and the view's
/// size then (MapScreen)
struct MapVisibleRect {
    let rect: MKMapRect
    let heading: Double
    let pitch: Double
    let size: CGSize
}


/// Drawing the map again when it comes back in sight (SubwayMapView). The guess behind it: with its window covered or the app in the
/// background, macOS or Apple Maps stops drawing the map, which can then stay blank (beige, only the labels and pins) until it's moved
enum MapRedraw {
    /// Out of sight at least this long (seconds): shorter, the map is drawn again by itself
    static let afterHidden: TimeInterval = 2
    /// How many times since launch
    @MainActor static var count = 0
    /// The map counts as still once it hasn't moved for this long: the metro areas' names and the labels are worked out then
    static let stillMilliseconds = 200

    /// Whether the map has been still long enough (a little short of the whole wait counts: the wait itself is that long)
    static func isStill(since moved: Date, now: Date) -> Bool {
        now.timeIntervalSince(moved) * 1000 >= Double(stillMilliseconds) - 20
    }
}
