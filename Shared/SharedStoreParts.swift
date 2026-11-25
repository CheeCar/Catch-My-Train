import CatchText
import Foundation
import os
import TransitCore

/// The widget's most recent run record. Shown on the Settings page to confirm the desktop widget is the new version and is updating.
struct WidgetHeartbeat: Codable, Hashable {
    var ranAt: Date
    /// Widget version number (CFBundleVersion)
    var build: String
}

/// Appearance: follows the Mac (the default of a new install), light (the default of a Mac updating from a version without System) or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    /// Follows the Mac's appearance, its automatic light and dark too
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// Starting point for walk times.
enum LocationMode: String, CaseIterable, Identifiable {
    /// Current location from macOS location services
    case current
    /// A place chosen manually by the user
    case manual

    var id: String { rawValue }

    /// Whether to open the place picker first when switching to this mode (shared by the sidebar and menu):
    /// if no place has been chosen yet, open the picker and switch only once one is chosen; Cancel stays in the old mode instead of using the built-in default place.
    func needsPicker(hasChosenPlace: Bool) -> Bool {
        self == .manual && !hasChosenPlace
    }
}

enum SharedStoreError: LocalizedError {
    case sharedFolderUnavailable

    var errorDescription: String? {
        // Written only to the system log; the UI shows the translated explanation from TransitModel
        "Catch My Train can't use the folder it shares with the widget."
    }
}

/// Transit data source.
enum TransitDataSource: String, CaseIterable, Identifiable {
    /// Official MTA realtime data (free, no key needed, requires network)
    case mtaRealtime = "mta"
    /// Mock data (Demo mode)
    case mock

    var id: String { rawValue }
}

// UserPlace lives in TransitCore (UserPlace.swift), so tests can check that data saved by older versions still reads.

/// Link that opens the matching page of the main app when a widget is clicked.
enum DeepLink: String {
    case nearby
    case settings

    static let scheme = "catchmytrain"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let link = DeepLink(rawValue: host) else { return nil }
        self = link
    }
}

/// Instant notifications between the main app and widgets (Darwin notifications: just a "shared data changed" signal, carrying no data).
/// After toggling start / standby, switching stations or tapping refresh on a widget, a signal is sent and the main app reads the shared files right away, without waiting for its next timed check.
/// If a signal is missed, the main app still checks every 15 seconds while started and every 40 seconds on standby.
enum SharedSignal {
    static var name: String { (SharedStore.appGroupIdentifier ?? "com.cheecar.catchmytrain.shared") + ".changed" }

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// For the main app: calls handler on the main thread when SharedSignal arrives, at most once a second (see SignalThrottle).
/// Just release it when no longer needed.
final class SharedSignalObserver {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = SignalThrottle(interval: 1, handler: handler).fire
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                // Only the handler is carried to the main thread (this closure retains it); not the observer itself, so a released observer is never touched
                let handler = Unmanaged<SharedSignalObserver>.fromOpaque(observer).takeUnretainedValue().handler
                DispatchQueue.main.async { handler() }
            },
            SharedSignal.name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
    }
}

/// Any process on this Mac can post SharedSignal, so a flood of signals must not make the app reread its files over and over.
/// The first signal is handled at once; the ones in the next `interval` are handled together once it's over, so the last change
/// is never missed. Main thread only.
final class SignalThrottle {
    private let interval: TimeInterval
    private let handler: () -> Void
    private var lastRun: DispatchTime?
    private var waiting = false

    init(interval: TimeInterval, handler: @escaping () -> Void) {
        self.interval = interval
        self.handler = handler
    }

    func fire() {
        guard !waiting else { return }
        let now = DispatchTime.now()
        if let lastRun, now < lastRun + interval {
            waiting = true
            DispatchQueue.main.asyncAfter(deadline: lastRun + interval) { [self] in
                waiting = false
                run()
            }
            return
        }
        run()
    }

    private func run() {
        lastRun = .now()
        handler()
    }
}
