import Foundation

/// Walk time estimation.
///
/// Rules:
/// 1. If there's a real walking route (route length or route time from MapKit), use it first, marked `.route`.
///    Route length is converted to time with the user's walking speed setting, so the "walking speed" setting applies to real routes too.
/// 2. Otherwise estimate with "straight-line distance × detour factor ÷ walking speed", marked `.estimated`; when the straight line
///    crosses a river or a bay (WaterMap) the estimate is marked across the water too.
/// Straight-line distance is only for prefiltering and can't be the sole basis for the final verdict.
/// A station without times (NoTimesStations) always gets the estimate: no route is asked for it (see asksForRoute).
/// A route far too long for a station a few steps away isn't used either (see routeNotUsed): that walk is the estimate too.
public enum WalkEstimator {
    /// A station nearer than this in a straight line, with a route longer than routeTooLongMeters, gets the estimate (see routeNotUsed)
    public static let veryNearMeters: Double = 50
    public static let routeTooLongMeters: Double = 1_000

    /// Whether a walking route from Apple Maps is left out and the walk estimated from the straight line instead: the station is
    /// under veryNearMeters away, the route is over routeTooLongMeters, and the straight line doesn't cross water. Standing next to
    /// a station whose point is inside the building, between tracks and roads (Secaucus Junction), Apple Maps moves each end to the
    /// nearest road, and those two roads may not connect: 2 m away came back as a 4,995 m route, which put the station out of
    /// range. A walk that really is that long from that near could only be around water, and then the route is kept. (WaterMap
    /// counts water from 50 m across, so today no line this short crosses any; the check is there in case that changes.)
    public static func routeNotUsed(straightMeters: Double, routeMeters: Double, acrossWater: @autoclosure () -> Bool) -> Bool {
        straightMeters < veryNearMeters && routeMeters > routeTooLongMeters && !acrossWater()
    }

    /// Whether to ask Apple Maps for a walking route to this station. Not for a station without times (NoTimesStations): Apple Maps
    /// can send a walk to an AirTrain platform on a long detour (it doesn't know the way through the station next to it), which
    /// puts the station out of range, so its walk is always the straight-line estimate, marked "estimated". The requests, a few
    /// at a time, go to the stations with times instead.
    public static func asksForRoute(to station: Station) -> Bool { !NoTimesStations.isNoTimes(station.id) }

    /// Great-circle straight-line distance between two points (meters), Haversine formula.
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Finds the entrance nearest the user; uses the station's coordinate when there's no entrance data.
    public static func nearestEntrance(from user: Coordinate, to station: Station) -> (name: String?, coordinate: Coordinate) {
        guard let best = station.entrances.min(by: {
            distanceMeters(user, $0.coordinate) < distanceMeters(user, $1.coordinate)
        }) else {
            return (nil, station.coordinate)
        }
        return (best.name, best.coordinate)
    }

    /// Estimates walk time to a station entrance.
    /// - Parameters:
    ///   - routeSeconds: real route walk time (if any).
    ///   - routeMeters: real walking route length (meters, if any), converted with the walking speed setting.
    public static func estimate(
        from user: Coordinate,
        to station: Station,
        settings: CatchSettings,
        routeSeconds: TimeInterval? = nil,
        routeMeters: Double? = nil
    ) -> WalkEstimate {
        let entrance = nearestEntrance(from: user, to: station)
        let straight = distanceMeters(user, entrance.coordinate)
        let speed = settings.walkingSpeedMetersPerSecond
        // A route far too long for a station a few steps away isn't used, in either form: the walk is the estimate below
        let unused = routeMeters.map {
            routeNotUsed(straightMeters: straight, routeMeters: $0, acrossWater: crossesWater(from: user, to: entrance.coordinate))
        } ?? false
        if let routeMeters, routeMeters >= 0, speed > 0, !unused {
            return WalkEstimate(walkSeconds: routeMeters / speed, straightLineMeters: straight, source: .route,
                                entranceName: entrance.name, routeMeters: routeMeters)
        }
        if let routeSeconds, routeSeconds >= 0, !unused {
            return WalkEstimate(walkSeconds: routeSeconds, straightLineMeters: straight, source: .route, entranceName: entrance.name)
        }
        let seconds = speed > 0 ? straight * settings.detourFactor / speed : .infinity
        // Only a station near enough to be in range is checked: one farther away is left out anyway (Recommender.classify)
        let across = straight <= settings.extendedCandidateRadiusMeters && crossesWater(from: user, to: entrance.coordinate)
        return WalkEstimate(walkSeconds: seconds, straightLineMeters: straight, source: .estimated, entranceName: entrance.name,
                            acrossWater: across)
    }

    /// Whether the straight line crosses a river or a bay (WaterMap), when the straight-line estimate may be far too short
    public static func crossesWater(from a: Coordinate, to b: Coordinate) -> Bool {
        WaterMap.shared?.crosses(a, b) ?? false
    }
}

/// Bookkeeping for walking routes from the current origin (asked from MapKit a few stations at a time, see TransitModel):
/// which stations have a route, which are being asked, and which to ask next.
/// A station whose route couldn't be found is asked again after `retryAfter` (or at once when the network comes back);
/// moving `resetDistance` or more starts over.
public struct WalkRouteBook: Sendable {
    public static let resetDistance: Double = 30
    public static let retryAfter: TimeInterval = 5 * 60
    /// A station across the water is asked again sooner: until its route comes, its walk can't be trusted
    public static let acrossWaterRetryAfter: TimeInterval = 60

    /// Route length (meters) per station ID
    public private(set) var meters: [String: Double] = [:]
    public private(set) var origin: Coordinate?
    /// Asked and not failed: being asked, or answered with a route
    private var asked: Set<String> = []
    /// Asked but no route came back, and when
    private var failedAt: [String: Date] = [:]

    public init() {}

    /// Route lengths only when they were found from `here` (within `resetDistance` of the book's origin); none after a bigger
    /// move that `next` hasn't started over for yet, so a walk is never worked out from the old origin's routes
    public func routeMeters(from here: Coordinate) -> [String: Double] {
        guard let origin, WalkEstimator.distanceMeters(origin, here) < Self.resetDistance else { return [:] }
        return meters
    }

    /// Whether a route to this station may still come from `here`: one is asked for it, and it hasn't been asked and failed
    /// (asked again later, see retryAfter). After a bigger move every station starts over, so it may
    public func awaitsRoute(for station: Station, from here: Coordinate) -> Bool {
        guard WalkEstimator.asksForRoute(to: station) else { return false }
        guard let origin, WalkEstimator.distanceMeters(origin, here) < Self.resetDistance else { return true }
        return meters[station.id] == nil && failedAt[station.id] == nil
    }

    /// Start over (another mode's stations): the next call to `next` begins from scratch
    public mutating func reset() { self = WalkRouteBook() }

    /// The nearest `limit` stations not asked yet, now marked as asked. `startedOver` is true when there was no origin or it
    /// moved `resetDistance` or more, so every earlier route was dropped (a request still running for the old origin should stop).
    /// Only stations a route is asked for (WalkEstimator.asksForRoute): never one without times.
    /// The stations in `acrossWater` (their straight line crosses water) go first, and are asked again after acrossWaterRetryAfter.
    public mutating func next(from here: Coordinate, stations: [Station], limit: Int, now: Date,
                              acrossWater: Set<String> = []) -> (targets: [Station], startedOver: Bool) {
        var startedOver = false
        if let origin, WalkEstimator.distanceMeters(origin, here) < Self.resetDistance {
            for (id, at) in failedAt where now.timeIntervalSince(at)
                >= (acrossWater.contains(id) ? Self.acrossWaterRetryAfter : Self.retryAfter) { failedAt[id] = nil }
        } else {
            self = WalkRouteBook()
            origin = here
            startedOver = true
        }
        let targets = Array(stations
            .filter { WalkEstimator.asksForRoute(to: $0) && !asked.contains($0.id) && failedAt[$0.id] == nil }
            .map { (station: $0, first: acrossWater.contains($0.id), meters: WalkEstimator.distanceMeters(here, $0.coordinate)) }
            .sorted { $0.first != $1.first ? $0.first : $0.meters < $1.meters }
            .map(\.station)
            .prefix(limit))
        for t in targets { asked.insert(t.id) }
        return (targets, startedOver)
    }

    /// The answer for `targets`, asked from `from`. Returns false and changes nothing when the book started over since
    /// (reset, or `from` is `resetDistance` or more from the origin), the same rule `next` uses.
    @discardableResult
    public mutating func received(_ distances: [String: Double], for targets: [Station], from: Coordinate, now: Date) -> Bool {
        guard let origin, WalkEstimator.distanceMeters(origin, from) < Self.resetDistance else { return false }
        meters.merge(distances) { _, new in new }
        for t in targets where distances[t.id] == nil {
            asked.remove(t.id)
            failedAt[t.id] = now
        }
        return true
    }

    /// The request was stopped (standby): stations without a route are asked again next time
    public mutating func stopped() {
        asked = Set(meters.keys)
        failedAt = [:]
    }

    /// The network is back: stations that failed may be asked right away (ones being asked now stay as they are)
    public mutating func retryFailed() {
        failedAt = [:]
    }
}
