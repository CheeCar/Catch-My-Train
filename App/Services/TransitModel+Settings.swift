import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

extension TransitModel {
    var tempExtraMinutes: Double {
        get { tempRange.minutes(for: locationMode) }
        set {
            var range = tempRange
            guard range.set(newValue, for: locationMode, active: isActive) else { return }
            tempRange = range
            boardInputs &+= 1
            if isActive, Set(currentStations().map(\.id)) != Set(stations.map(\.id)) {
                refresh()
            } else {
                updateWalks()
                saveSnapshot(widgetsNow: true)
            }
        }
    }
    static let tempExtraChoices: [Double] = [5, 10, 15, 20]

    /// On quitting the app: if the range is temporarily extended, save data for the widget once more with the normal range.
    /// Otherwise, after quitting, the widget would keep using the extended range when it updates itself.
    func restoreNormalRangeBeforeQuit() {
        guard tempRange.isExtended else { return }
        tempRange = TemporaryRange()
        boardInputs &+= 1
        saveSnapshot(widgetsNow: true)
    }

    /// Range actually used: the range from Settings plus the temporarily extended minutes (added to the extended range).
    var effectiveSettings: CatchSettings {
        var s = settings
        if tempExtraMinutes > 0 {
            s.extendedWalkMinutes = s.sanitized().extendedWalkMinutes + tempExtraMinutes
        }
        // With a longer refresh interval, data between two refreshes doesn't count as stale (Settings shows this value)
        s.realtimeStaleAfterSeconds = s.realtimeStale(refreshInterval: effectiveRefreshInterval)
        return s
    }

    /// Every mode follows the setting. Live data that needs the user's own key or account is still asked for at most once a minute
    /// (see KeyedRequests): the other sources refresh as often as set
    var effectiveRefreshInterval: TimeInterval { refreshInterval }

    /// One sentence that replaces the various "can't connect" messages when offline
    var networkOffNote: String? {
        networkAllowed ? nil : l10n.t("Network is off in Settings, so only timetables saved on this Mac are shown.")
    }

    /// Where in Settings a station's notice sends the user, for its Settings… button: networking is turned on in Privacy and
    /// permissions, a refused MTA Bus Time key is changed in Keys and accounts. Nil for notices that say nothing about Settings
    func settingsPlace(forNotice text: String) -> SettingsJump.Target? {
        if text == networkOffNote { return .privacy }
        if text == l10n.t("MTA Bus Time didn't accept your key. Check it in Settings.") { return .keys }
        return nil
    }

    /// The "Check … Now" buttons go online, so they only work while on, with the network allowed, outside Demo mode
    var canCheckOnline: Bool { isActive && !isDemo && networkAllowed }

    /// Tooltip of a "Check … Now" button: why it's unavailable (empty when it works)
    var checkOnlineHelp: String {
        if isDemo { return l10n.t("Not available in Demo mode.") }
        if let networkOffNote { return networkOffNote }
        return isActive ? "" : l10n.t("Turn Catch My Train on to check.")
    }

    /// Why a "Check … Now" button is grayed out, written beside it (not only in its hover text); nil when it works
    var checkOnlineReason: String? {
        canCheckOnline || checkOnlineHelp.isEmpty ? nil : checkOnlineHelp
    }

    /// On standby, outside Demo mode, with the network allowed: the only thing between a "Check … Now" button and working is
    /// standby, so a Start button takes its place (CheckOrStartButton)
    var startsToCheck: Bool { Self.startsToCheck(active: isActive, demo: isDemo, networkAllowed: networkAllowed) }

    nonisolated static func startsToCheck(active: Bool, demo: Bool, networkAllowed: Bool) -> Bool {
        !active && !demo && networkAllowed
    }

    /// The menu item's shortcut; nil when shortcuts are off or the item has no key
    func keyboardShortcut(_ s: AppShortcut) -> KeyboardShortcut? {
        guard shortcutsEnabled, let key = shortcuts.key(for: s), let character = key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: .command)
    }

    /// Bus: MTA buses (live, needs a key) plus a few timetable-only operators like NJ Transit
    var isBus: Bool { system == .bus }
    var isFerry: Bool { system.family == .ferry }
    /// Train and light rail
    var isTrain: Bool { system.family == .rail }
    /// Train, light rail, PATH and ferry: departures all come from several operators' timetables (plus live data), see FerryFeed
    var usesTimetable: Bool { system.usesTimetableFeed }
    /// Demo mode: Manhattan, made-up departures for all four modes, its own places in memory only (SharedStore.DemoPlaces); no
    /// location, no downloads, keys or accounts (only the maps come from Apple Maps)
    var isDemo: Bool { dataSource == .mock }

    /// One of Demo mode's own train stations, piers or PATH stations (DemoData): like a timetable's, a way it has no line is left out
    func isDemoStop(_ id: String) -> Bool { isDemo && DemoData.stop(id: id) != nil }

    /// This station (bus stop, pier) comes from timetable data (FerryFeed, IDs with a prefix like "njb:"), not the MTA station catalog.
    /// Buses have both: MTA bus stops use Bus Time live data, stops of NJ Transit and others use timetables.
    func isTimetableStation(_ id: String) -> Bool {
        if isDemo { return false }
        if usesTimetable { return true }
        guard system.hasTimetablePart else { return false }
        return FerryFeed.Source.allCases.contains { $0.owns(id: id) }
    }

    /// There are MTA bus stops nearby (live departures need a Bus Time key)
    var hasMTABusStops: Bool { !isDemo && isBus && stations.contains { !isTimetableStation($0.id) } }
    /// Should prompt to add a Bus Time key: bus mode, MTA bus stops nearby, no key yet
    var needsBusKey: Bool { keysLoaded && hasMTABusStops && !hasBusKey }
    /// This stop (stop group) has MTA bus stops but there's no key yet
    func needsBusKey(at station: BoardStation) -> Bool {
        !isDemo && keysLoaded && isBus && !hasBusKey && station.stations.contains { !isTimetableStation($0.id) }
    }

    /// UI text for the current language and units, with times in the starting place's time zone (placeTimeZone), each naming its
    /// zone where this Mac's clock reads differently
    var l10n: UIText {
        let place = placeTimeZone
        return UIText(language: language, units: units, clock: clock, timeZone: place.zone, timeZoneIsArea: place.isArea,
                      macTimeZone: .autoupdatingCurrent)
    }

    /// The time zone times are shown in: the starting place's metro area's (isArea); outside the service area, where you are when
    /// that's known to keep another time (the time zone Apple Maps gives with the place name, for "my location" only), otherwise this
    /// Mac's own
    var placeTimeZone: (zone: TimeZone, isArea: Bool) {
        if let area = areaRegion?.metroArea { return (area.timeZone, true) }
        if isOutsideArea, startingPlace == .current, let zone = outsideTimeZone { return (zone, false) }
        return (.autoupdatingCurrent, false)
    }
}
