import AppIntents
import Foundation
import os
import TransitCore
import WidgetKit

// Buttons on the widget. When tapped they run directly in the widget, then the system redraws the widget.
// The toggle state and selected station live in the folder shared with the app; after a change a signal is sent (SharedSignal),
// and the main app (including when running only in the menu bar) follows immediately.

/// Start: recompute the auto-standby time and download departures once right away (the main app downloads while it's running).
struct StartTrainsIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Catch My Train"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let now = Date()
        let state = (SharedStore.loadActivity() ?? ActivityState.firstLaunch(at: now)).started(at: now)
        SharedStore.saveActivity(state)
        AppLog.widget.notice("widget intent Start")
        await WidgetRefresher.refreshNow(now: now)
        return .result()
    }
}

/// Standby: stop refreshing and downloading.
struct StandbyTrainsIntent: AppIntent {
    static let title: LocalizedStringResource = "Put Catch My Train on standby"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let now = Date()
        let state = (SharedStore.loadActivity() ?? ActivityState.firstLaunch(at: now)).stopped(at: now)
        SharedStore.saveActivity(state)
        AppLog.widget.notice("widget intent Standby")
        SharedSignal.post()
        return .result()
    }
}

/// Refresh: re-download departures immediately (the main app downloads while it's running). No download on standby.
struct RefreshTrainsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh trains"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let now = Date()
        if SharedStore.loadActivity()?.isActive(at: now) ?? true {
            await WidgetRefresher.refreshNow(now: now)
        }
        return .result()
    }
}

/// Switch to the next nearby station (cycling through the nearest 5).
struct NextStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Next station"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        guard let snap = SharedStore.loadSnapshot() else { return .result() }
        let board = snap.board(at: Date())
        SharedStore.saveSelection(SharedStore.loadSelection().moving(by: 1, in: board))
        SharedSignal.post()
        return .result()
    }
}

/// Large widget: tap another nearby station to show it instead.
struct SelectStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Show station"
    static let isDiscoverable = false

    @Parameter(title: "Station")
    var stationID: String

    init() {}

    init(stationID: String) {
        self.stationID = stationID
    }

    func perform() async throws -> some IntentResult {
        var selection = SharedStore.loadSelection()
        selection.stationID = stationID
        SharedStore.saveSelection(selection)
        SharedSignal.post()
        return .result()
    }
}
