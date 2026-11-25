import CoreLocation
import Foundation
import TransitCore

/// macOS location: gets the current position once, only when needed.
///
/// Privacy: only the latest position is kept in memory; nothing is written to disk, uploaded or kept as history.
/// On first use macOS asks for permission; if denied, the app uses a manually chosen location instead.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {

    enum State: Equatable {
        case idle
        case locating
        case located
        case denied
        case failed
    }

    private(set) var state: State = .idle
    private(set) var coordinate: Coordinate?
    /// How far off the position may be, in meters, as macOS says (nil when it doesn't); see LocationAccuracy
    private(set) var accuracy: Double?
    private(set) var fixedAt: Date?
    /// Time of the most recent location failure (no repeat requests within 2 minutes of a failure).
    private(set) var failedAt: Date?
    /// Notifies TransitModel when status or position changes.
    var onUpdate: (() -> Void)?

    private let manager = CLLocationManager()
    private var locatingTimeout: Task<Void, Never>?

    /// Location isn't allowed for this app in System Settings (then the app shows that "My current location" can't be used)
    var accessOff: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// What macOS says for this app: nil = hasn't asked yet, true = allowed, false = turned off in System Settings (setup window)
    var permission: Bool? {
        switch manager.authorizationStatus {
        case .notDetermined: return nil
        case .denied, .restricted: return false
        default: return true
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// "Use my location" turned off in Settings: stop locating
    /// When turned off, also forget the position already obtained.
    var allowed = SharedStore.locationAllowed {
        didSet {
            guard !allowed else { return }
            locatingTimeout?.cancel()
            manager.stopUpdatingLocation()
            coordinate = nil
            accuracy = nil
            fixedAt = nil
            state = .idle
        }
    }

    /// Whether the app wants a position now: on, "My current location", not Demo mode, "Use my location" on (see LocationNeed).
    /// TransitModel keeps it up to date. Only then does a request or a permission change fetch a position; otherwise only the state changes.
    var needed = false {
        didSet {
            guard oldValue, !needed, state == .locating else { return }
            // No longer wanted (standby, a chosen place, the demo): stop the lookup in flight
            locatingTimeout?.cancel()
            manager.stopUpdatingLocation()
            update(.idle)
        }
    }

    /// Request the current position once (the first time shows the system permission prompt).
    /// The prompt can be shown any time (the setup window asks for it); the position itself is fetched only while needed.
    func request() {
        guard allowed else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if needed { update(.locating) }
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            update(.denied)
        default:
            guard needed else { return }
            update(.locating)
            manager.requestLocation()
        }
    }

    /// Fetch again when the position hasn't updated for more than maxAge seconds.
    func requestIfStale(maxAge: TimeInterval) {
        if state == .locating || state == .denied { return }
        if let fixedAt, Date().timeIntervalSince(fixedAt) < maxAge { return }
        if state == .failed, let failedAt, Date().timeIntervalSince(failedAt) < 120 { return }
        request()
    }

    private func update(_ newState: State) {
        state = newState
        if newState == .locating {
            // When the system never answers (e.g. the permission prompt didn't appear), don't keep showing "Finding your location..."
            locatingTimeout?.cancel()
            locatingTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.state == .locating else { return }
                self.failedAt = Date()
                self.update(self.accessOff ? .denied : .failed)
            }
        }
        onUpdate?()
    }

    private func authorizationChanged() {
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            update(.denied)
        default:
            // macOS also calls this right at launch. Not wanted now (standby, a chosen place, the demo): only the state changes,
            // so a denial lifted meanwhile no longer shows; the position is fetched on the next Start or switch to "My current location"
            switch LocationNeed.onPermissionGranted(wanted: allowed && needed, locating: state == .locating,
                                                    denied: state == .denied, hasPosition: coordinate != nil) {
            case .locate:
                // Just got permission: fetch the position once.
                update(.locating)
                manager.requestLocation()
            case .settle:
                update(.idle)
            case .report:
                onUpdate?()
            case .keep:
                break
            }
        }
    }

    // MARK: CLLocationManagerDelegate (the system calls back on the main thread; hop back to MainActor here)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let c = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let time = location.timestamp
        // Negative: macOS doesn't know how exact it is
        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        Task { @MainActor in
            // A position that arrives after it stopped being wanted (standby, a chosen place, the demo) isn't kept
            guard self.allowed, self.needed else { return }
            self.coordinate = c
            self.accuracy = accuracy
            self.fixedAt = time
            self.failedAt = nil
            self.update(.located)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            if denied {
                self.update(.denied)
            } else if !self.needed {
                // The lookup was stopped because the position is no longer wanted: nothing failed
                return
            } else if self.coordinate != nil {
                // Can't get a new position for now: keep using the last one.
                self.update(.located)
            } else {
                self.failedAt = Date()
                self.update(.failed)
            }
        }
    }
}
