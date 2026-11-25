import CoreLocation
import Foundation
import MapKit
import TransitCore

/// Uses MapKit to compute real walking route lengths to each station.
///
/// Only the route length is used, to estimate walking time more accurately; this app does no navigation.
/// The route length is converted to time using the walking speed in Settings (see WalkEstimator).
/// When no route is available (no network, MapKit unavailable) it returns nothing, and the app falls back to a straight-line estimate labeled "estimated".
/// Stations without times are never asked (WalkEstimator.asksForRoute): theirs is always the straight-line estimate.
struct WalkRouter {

    /// Maximum number of stations computed at once (MapKit is rate-limited).
    static let maxStations = 10

    /// The stations to ask about: the nearest `maxStations` in a straight line (when subway, PATH and bus stops are mixed, can't
    /// just take the front of the list), of those a route is asked for (never a station without times)
    static func targets(from origin: Coordinate, among stations: [Station]) -> [Station] {
        Array(stations
            .filter(WalkEstimator.asksForRoute(to:))
            .sorted { WalkEstimator.distanceMeters(origin, $0.coordinate) < WalkEstimator.distanceMeters(origin, $1.coordinate) }
            .prefix(maxStations))
    }

    func walkingDistances(from origin: Coordinate, to stations: [Station]) async -> [String: Double] {
        // Stopped before it began (standby, the origin moved): ask Apple Maps nothing
        guard !Task.isCancelled else { return [:] }
        let targets = Self.targets(from: origin, among: stations)
        let places = Dictionary(targets.map { ($0.id, $0.coordinate) }, uniquingKeysWith: { first, _ in first })
        // Every station at once, each one's route length kept under its own id (see Together)
        let meters = await Together.each(targets.map(\.id)) { id -> Double? in
            guard let target = places[id] else { return nil }
            return await Self.routeMeters(from: origin, to: target)
        }
        return meters.compactMapValues { $0 }
    }

    @MainActor
    private static func routeMeters(from a: Coordinate, to b: Coordinate) async -> Double? {
        // Network access is turned off in Settings: don't ask Apple Maps, estimate walking by straight line
        guard NetworkSwitch.isAllowed, !Task.isCancelled else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        return await MapsRequest.route(request)?.routes.map(\.distance).min()
    }
}

/// Apple Maps requests (walking routes, place search, place names) that stop when the task waiting for them is cancelled
/// (standby, starting over, another choice): nothing is sent once the task is cancelled, a request already sent is cancelled,
/// and the wait ends right away whether or not Apple Maps still answers.
@MainActor
enum MapsRequest {
    static func route(_ request: MKDirections.Request) async -> MKDirections.Response? {
        guard !Task.isCancelled else { return nil }
        let directions = MKDirections(request: request)
        return await answer(stop: { directions.cancel() }) { (wait: MapsAnswer<MKDirections.Response>) in
            directions.calculate { response, _ in wait.finish(response) }
        }
    }

    static func search(_ request: MKLocalSearch.Request) async -> MKLocalSearch.Response? {
        guard !Task.isCancelled else { return nil }
        let lookup = MKLocalSearch(request: request)
        return await answer(stop: { lookup.cancel() }) { (wait: MapsAnswer<MKLocalSearch.Response>) in
            lookup.start { response, _ in wait.finish(response) }
        }
    }

    static func placemark(of location: CLLocation, locale: Locale? = nil) async -> CLPlacemark? {
        guard !Task.isCancelled else { return nil }
        let geocoder = CLGeocoder()
        let marks = await answer(stop: { geocoder.cancelGeocode() }) { (wait: MapsAnswer<[CLPlacemark]>) in
            geocoder.reverseGeocodeLocation(location, preferredLocale: locale) { found, _ in wait.finish(found) }
        }
        return marks?.first
    }

    /// Starts a request with `start`, which hands its answer to `finish`. Cancelling the task calls `stop` (on the main thread)
    /// and returns nil at once; a task already cancelled never starts the request.
    static func answer<Value>(stop: @escaping () -> Void, start: (MapsAnswer<Value>) -> Void) async -> Value? {
        let wait = MapsAnswer<Value>(stop: stop)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                if wait.begin(continuation) { start(wait) }
            }
        } onCancel: {
            wait.cancel()
        }
    }
}

/// The wait for one Apple Maps answer (see MapsRequest.answer): resumed exactly once, by the answer or by cancellation, whichever comes first.
/// Cancellation can arrive on any thread, even before the wait begins, so the state is behind a lock.
final class MapsAnswer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var cancelled = false
    private let stop: () -> Void

    init(stop: @escaping () -> Void) { self.stop = stop }

    /// Returns false (and ends the wait with nil) when the task was cancelled already: then the request isn't started
    func begin(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ value: Value?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: nil)
        // The request objects were made on the main thread: cancel them there
        DispatchQueue.main.async { self.stop() }
    }
}

/// Looks up a place name for a location (e.g. "Albany, New York") using macOS's built-in Apple Maps, without uploading the location elsewhere.
/// Used in two places: the place name in the title bar when outside the service area (place), and in the sidebar for "My current location" (nearbyName).
/// separator is the locale's comma (the Arabic comma U+060C in Arabic and Urdu).
enum PlaceNamer {
    /// The place's name and the time zone Apple Maps gives with it (where you are outside the service area keeps its time in it)
    static func place(of c: Coordinate, locale: Locale? = nil, separator: String = ", ") async -> (name: String?, timeZone: TimeZone?)? {
        guard NetworkSwitch.isAllowed else { return nil }
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let mark = await MapsRequest.placemark(of: location, locale: locale) else { return nil }
        let parts = [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea ?? mark.country]
            .compactMap { $0 }
        return (parts.isEmpty ? nil : parts.joined(separator: separator), mark.timeZone)
    }

    /// Nearby place name, a bit finer than place(of:): neighborhood or street + city (e.g. "Hunters Point, Queens").
    static func nearbyName(of c: Coordinate, locale: Locale? = nil, separator: String = ", ") async -> String? {
        guard NetworkSwitch.isAllowed else { return nil }
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let mark = await MapsRequest.placemark(of: location, locale: locale) else { return nil }
        var parts = [mark.subLocality ?? mark.thoroughfare, mark.locality ?? mark.subAdministrativeArea].compactMap { $0 }
        if parts.count == 2, parts[0] == parts[1] { parts.removeLast() }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }
}
