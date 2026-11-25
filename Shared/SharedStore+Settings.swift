import CatchText
import Foundation
import os
import TransitCore

extension SharedStore {
    // MARK: Language and units

    static let languageKey = WidgetHandoff.Key.language
    static let unitsKey = WidgetHandoff.Key.units

    /// UI language. When the language menu is off (AppLanguage.otherLanguagesEnabled is false), always returns English; unrecognized old values (e.g. removed languages) also use English.
    static var language: AppLanguage {
        get {
            guard AppLanguage.otherLanguagesEnabled else { return .english }
            return AppLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .default
        }
        set {
            defaults.set(newValue.rawValue, forKey: languageKey)
            exportWidgetSettings()
        }
    }

    /// A language has been saved (chosen in Settings, or picked from the Mac's languages on a new install)
    static var hasSavedLanguage: Bool { defaults.string(forKey: languageKey) != nil }

    static let languageFollowsMacKey = "appLanguageFollowsMac"
    /// "System Language" is chosen in Settings: the app picks the Mac's language again at each launch and saves it as `language`,
    /// which the widget is handed. False when nothing is saved (a Mac updating from a version without it keeps its language).
    static var languageFollowsMac: Bool {
        get { defaults.bool(forKey: languageFollowsMacKey) }
        set { defaults.set(newValue, forKey: languageFollowsMacKey) }
    }

    static var units: DistanceUnit {
        get { DistanceUnit(rawValue: defaults.string(forKey: unitsKey) ?? "") ?? .default }
        set {
            defaults.set(newValue.rawValue, forKey: unitsKey)
            exportWidgetSettings()
        }
    }

    static let clockKey = WidgetHandoff.Key.clock
    /// 12 / 24-hour clock (default 12-hour)
    static var clock: ClockStyle {
        get { ClockStyle(rawValue: defaults.string(forKey: clockKey) ?? "") ?? .default }
        set {
            defaults.set(newValue.rawValue, forKey: clockKey)
            exportWidgetSettings()
        }
    }

    /// UI strings for the current language, units and clock format.
    static var text: AppText { AppText(language: language, units: units, clock: clock) }

    /// UI strings for widgets: prefers the language and units recorded in the snapshot (over the settings the app handed the widget).
    static func text(for snapshot: TransitSnapshot?) -> AppText {
        let lang = AppLanguage.otherLanguagesEnabled
            ? snapshot?.languageCode.flatMap(AppLanguage.init(rawValue:)) ?? language : .english
        let unit = snapshot?.unitsCode.flatMap(DistanceUnit.init(rawValue:)) ?? units
        let clockStyle = snapshot?.clockCode.flatMap(ClockStyle.init(rawValue:)) ?? clock
        // Times in the starting place's metro area's zone, as in the app (outside the service area and in older snapshots, this Mac's)
        let zone = snapshot?.timeZone.flatMap(TimeZone.init(identifier:))
        return AppText(language: lang, units: unit, clock: clockStyle, timeZone: zone ?? .autoupdatingCurrent, timeZoneIsArea: zone != nil,
                       macTimeZone: .autoupdatingCurrent)
    }

    // MARK: Appearance

    static let appearanceKey = "appearance"

    /// System / light / dark. Light when none is saved: a new install saves System at its first launch (TransitModel.launchAppearance).
    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: appearanceKey) ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: appearanceKey) }
    }

    /// An appearance has been saved (chosen in Settings or the View menu, or saved at the first launch of this version)
    static var hasSavedAppearance: Bool { defaults.string(forKey: appearanceKey) != nil }

    // MARK: Transit systems

    static let systemKey = "transitSystem"

    /// The transit mode chosen next to the main window title; default subway.
    static var system: TransitSystem {
        // Older saved values like "New Jersey trains" are mapped to the merged modes (each mode covers both New York and New Jersey)
        get { TransitSystem(rawValue: defaults.string(forKey: systemKey) ?? "")?.mode ?? .subway }
        set { defaults.set(newValue.rawValue, forKey: systemKey) }
    }

    static let systemBeforeDemoKey = "transitSystemBeforeDemo"

    /// The transit mode when Demo mode was turned on, while it's on (nil otherwise): turning it off goes back to it. Saved, so it
    /// is still known when the app is quit in Demo mode
    static var systemBeforeDemo: TransitSystem? {
        get { defaults.string(forKey: systemBeforeDemoKey).flatMap(TransitSystem.init(rawValue:))?.mode }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: systemBeforeDemoKey) } else { defaults.removeObject(forKey: systemBeforeDemoKey) }
        }
    }

    // MARK: Refresh interval

    static let refreshIntervalKey = WidgetHandoff.Key.refreshInterval
    /// Refresh intervals (seconds) selectable in Settings. MTA realtime data updates about every 30 seconds, so the minimum is 30 seconds.
    static let refreshIntervalChoices: [TimeInterval] = [30, 60, 120, 300]
    static let defaultRefreshInterval: TimeInterval = 30

    /// How often new trips are downloaded while "started" (default 30 seconds). Widgets use this interval too, never downloading more often than the main app.
    static var refreshIntervalSeconds: TimeInterval {
        get {
            let v = defaults.double(forKey: refreshIntervalKey)
            return refreshIntervalChoices.contains(v) ? v : defaultRefreshInterval
        }
        set {
            defaults.set(newValue, forKey: refreshIntervalKey)
            exportWidgetSettings()
        }
    }

    // MARK: Leave-by reminders

    static let reminderLeadKey = "reminderLeadMinutes"

    /// How many minutes before the latest time to set off a leave-by reminder comes (Settings, Reminders). Nil when none was ever
    /// chosen: LeaveReminders.leadMinutes then gives the default. The app's only (widgets set no reminders); the reminders
    /// themselves aren't saved here or anywhere by the app: the system holds them (LeaveReminderCenter)
    static var reminderLeadMinutes: Int? {
        get { defaults.object(forKey: reminderLeadKey) as? Int }
        set {
            if let newValue { defaults.set(newValue, forKey: reminderLeadKey) } else { defaults.removeObject(forKey: reminderLeadKey) }
        }
    }

    // MARK: Directions

    static let directionsMapKey = "directionsMap"

    /// The map app "Directions" opens (Settings, Privacy). Apple Maps when none was ever chosen, and when the stored value is one this
    /// version doesn't know (DirectionsMap(stored:)). The app's only: widgets have no Directions
    static var directionsMap: DirectionsMap {
        get { DirectionsMap(stored: defaults.string(forKey: directionsMapKey)) }
        set { defaults.set(newValue.rawValue, forKey: directionsMapKey) }
    }

    // MARK: Location

    static let locationModeKey = "locationMode"

    /// Where walk times are measured from: current location (default) or a manually chosen place. Demo mode's own while it's on.
    static var locationMode: LocationMode {
        get { demoPlaces?.locationMode ?? LocationMode(rawValue: defaults.string(forKey: locationModeKey) ?? "") ?? .current }
        set {
            if demoPlaces != nil { demoPlaces?.locationMode = newValue; return }
            defaults.set(newValue.rawValue, forKey: locationModeKey)
        }
    }

    /// Bus agencies (codes) whose last realtime download failed: saved so that next launch Settings and the main window footer still say "timetable",
    /// instead of showing live when opened elsewhere. Removed from here after one success, or once none of its stops is near the
    /// place in use (RegionalBusFeed.failedAfterRefresh).
    static var busRealtimeFailed: Set<String> {
        get { Set(defaults.stringArray(forKey: "busRealtimeFailed") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "busRealtimeFailed") }
    }

    /// Whether a place was ever chosen (one is saved and can be read; Demo mode's own while it's on). If not, there is nothing to
    /// walk from without a position (see StartingPlace), and "A place I choose" opens the place picker first. A saved one that
    /// can't be read counts as none: the app asks for a place instead of walking from the built-in default one
    static var hasChosenPlace: Bool {
        if let demoPlaces { return demoPlaces.place != nil }
        return savedPlace != nil
    }

    /// The saved place, nil when there is none or it can't be read
    private static var savedPlace: UserPlace? {
        defaults.data(forKey: placeKey).flatMap { try? JSONDecoder().decode(UserPlace.self, from: $0) }
    }

    /// "Allow network" in Settings: when off, neither the main app nor widgets go online (see NetworkSwitch; the widget is handed
    /// the value right away, before the widgets are told to draw again)
    static var networkAllowed: Bool {
        get { NetworkSwitch.isAllowed }
        set {
            NetworkSwitch.setAllowed(newValue)
            exportWidgetSettings()
        }
    }

    /// "Use my location" in Settings: when off, no location lookup, only the chosen place is used
    static var locationAllowed: Bool {
        get { defaults.object(forKey: "locationAllowed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "locationAllowed") }
    }

    /// The location chosen manually by the user (used when not using location services). The current location from location services is never saved.
    /// Demo mode's own while it's on (its starting place, Times Square, until one is chosen).
    static var place: UserPlace {
        get {
            if let demoPlaces { return demoPlaces.place ?? DemoData.home }
            return savedPlace ?? .default
        }
        set {
            if demoPlaces != nil { demoPlaces?.place = newValue; return }
            // One that can't be read is kept once as it was before it is written over
            if let data = defaults.data(forKey: placeKey), savedPlace == nil { keepCopy(data, of: placeKey) }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: placeKey) }
        }
    }

    // MARK: Catch settings

    static var catchSettings: CatchSettings {
        get {
            guard let data = defaults.data(forKey: settingsKey),
                  let s = try? JSONDecoder().decode(CatchSettings.self, from: data) else { return .default }
            return s.sanitized()
        }
        set {
            if let data = defaults.data(forKey: settingsKey), (try? JSONDecoder().decode(CatchSettings.self, from: data)) == nil {
                keepCopy(data, of: settingsKey)
            }
            if let data = try? JSONEncoder().encode(newValue.sanitized()) { defaults.set(data, forKey: settingsKey) }
        }
    }

    /// On app launch and when it quits, writes one line of counts to the system log: number of favorites, number of recent places, whether settings were read,
    /// and last the number of the user's own commute presets (versions before them don't write it). No place names, preset names or coordinates.
    /// During installs, compare before and after an update with `log show --predicate 'subsystem == "com.cheecar.catchmytrain"'`.
    static func logSavedCounts() {
        let saved = defaults.data(forKey: settingsKey)
        let settingsSaved = saved != nil
        let settingsRead = saved.map { (try? JSONDecoder().decode(CatchSettings.self, from: $0)) != nil } ?? false
        let presetStore = CommutePresetStore(defaults: defaults)
        let presetsUnreadable = presetStore.unreadableCount > 0 || presetStore.hasUnreadableCopy
        let kept = [settingsKey, placeKey].filter { defaults.data(forKey: $0 + ".unreadable") != nil }.count
        let unreadable = lists.copyCount + kept + (presetsUnreadable ? 1 : 0)
        let favorites = favoritePlaces.count
        let recents = recentPlaces.count
        let presets = presetStore.presets.count
        let settings = settingsRead ? "read" : (settingsSaved ? "unreadable" : "default")
        AppLog.data.notice("Saved data: favorites=\(favorites, privacy: .public) recents=\(recents, privacy: .public) settings=\(settings, privacy: .public) unreadableCopies=\(unreadable, privacy: .public) presets=\(presets, privacy: .public)")
    }

    private static func keepCopy(_ data: Data, of key: String) {
        let backupKey = key + ".unreadable"
        guard defaults.data(forKey: backupKey) == nil else { return }
        defaults.set(data, forKey: backupKey)
        AppLog.data.error("Saved data for \(key, privacy: .public) could not be read; kept a copy before writing")
    }
}
