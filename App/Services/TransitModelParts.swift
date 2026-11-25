import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

/// Compute on a background thread (work that takes a while, like organizing timetables and merging live data), then come back.
/// The main thread with the main window doesn't wait, so the UI won't hang.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

/// Text size (large text support).
enum AppTextSize: String, CaseIterable, Identifiable {
    case standard, large, larger

    var id: String { rawValue }

    /// Font scale factor (macOS doesn't follow SwiftUI Dynamic Type, tested on a Mac, so scale it ourselves)
    var factor: CGFloat {
        switch self {
        case .standard: return 1
        case .large: return 1.15
        case .larger: return 1.3
        }
    }
}

/// Return memory that's been freed but still counted against the app back to the system (otherwise memory doesn't drop after switching transit modes).
/// After releasing big chunks, the freed memory is scattered between data still in use and the system won't reclaim it on its own; this asks it to reclaim fully empty pages.
/// During consecutive actions, done only once, 8 seconds after the last one, so it doesn't get in the way.
enum MemoryRelief {
    @MainActor private static var pending: DispatchWorkItem?

    @MainActor static func soon(after delay: TimeInterval = 8) {
        pending?.cancel()
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// A live-data problem shown only at the stations it concerns
struct StationNotice: Equatable {
    var text: String
    /// Station, pier or stop IDs it concerns
    var stationIDs: Set<String> = []
    /// MTA subway feeds that failed: every station served by one of their lines
    var feeds: Set<MTAFeed> = []

    func applies(to station: BoardStation) -> Bool {
        station.stations.contains { stationIDs.contains($0.id) }
            || station.routes.contains { MTAFeed.feed(forRoute: $0).map(feeds.contains) ?? false }
    }
}

extension TransitModel {
    /// The red notice for one station: a problem that affects every station first, otherwise one that concerns this station
    func notice(for station: BoardStation) -> String? {
        lastError ?? stationNotices.first { $0.applies(to: station) }?.text
    }
}
