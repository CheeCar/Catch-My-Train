import AppKit
import CatchText
import Foundation
import Network
import SwiftUI
import TransitCore
import WidgetKit

/// Restarting to switch language: when the old instance quits it doesn't write "main app gone", so it won't overwrite the "running" the new one just wrote
enum AppRelaunch {
    static var inProgress = false
}

/// Temporarily extended range (minutes): "My current location" and "A place I choose" each keep their own;
/// can't be set while on standby. Pulled out on its own so it can be tested.
struct TemporaryRange: Equatable {
    private(set) var byMode: [LocationMode: Double] = [:]

    func minutes(for mode: LocationMode) -> Double { byMode[mode] ?? 0 }

    /// Whether any mode is currently extended
    var isExtended: Bool { byMode.values.contains { $0 > 0 } }

    /// Set to this many minutes (0 = back to normal). Unchanged, or trying to extend while on standby: no change, returns false.
    mutating func set(_ minutes: Double, for mode: LocationMode, active: Bool) -> Bool {
        guard minutes != self.minutes(for: mode), active || minutes == 0 else { return false }
        byMode[mode] = minutes
        return true
    }
}

/// Transit data state of the main app.
///
/// Data source (switchable in Settings):
/// - MTA live data (default): each refresh downloads only the few GTFS-Realtime feeds used by nearby stations;
/// - Mock data: for Demo mode, clearly labeled in the UI.
/// Walking origin: the current location from macOS Location Services by default; the manual place when location isn't allowed or a manual place is chosen.
/// Walking time: prefer the MapKit walking route length; fall back to a straight-line estimate when unavailable.
/// Start / Standby: only download, locate and refresh when "Start"ed; do nothing on standby (see ActivityState).
@MainActor
final class TransitModel: ObservableObject {

    @Published var settings: CatchSettings = TransitModel.initialSettings() {
        didSet {
            // Store the value actually used: the Settings field also shows the actual number (e.g. when the extended range is set smaller than the main range).
            // Assigning again inside didSet doesn't trigger didSet again
            let clean = settings.sanitized()
            if clean != settings { settings = clean }
            boardInputs &+= 1
            if persistsSettings { SharedStore.catchSettings = settings }
            // Only re-download when the range changed and the nearby stations changed too; otherwise just recompute.
            // On standby nothing downloads: recompute and save the widget data (the else branch)
            if isActive, oldValue.extendedCandidateRadiusMeters != settings.extendedCandidateRadiusMeters,
               Set(currentStations().map(\.id)) != Set(stations.map(\.id)) {
                refresh()
            } else if system.hasTimetablePart, isActive, oldValue.arrivalWindowSeconds != settings.arrivalWindowSeconds {
                // Train and ferry departures are computed from the timetable by arrival time range: recompute when the range changes
                refresh()
            } else {
                updateWalks()
                saveSnapshot(widgetsNow: true)
            }
        }
    }
    /// Temporarily extended range (minutes, 0 = not extended). Not saved to settings; resets automatically on standby or quit.
    /// "My current location" and "A place I choose" each keep their own; switching modes doesn't affect the other.
    @Published var tempRange = TemporaryRange()

    @Published var dataSource: TransitDataSource = SharedStore.dataSource {
        didSet {
            if persistsSettings { SharedStore.dataSource = dataSource }
            // Demo mode's own places in memory, or back to the saved ones (see useDemoPlaces)
            if isDemo != (oldValue == .mock) {
                useDemoPlaces(isDemo)
                keepMode(acrossDemo: isDemo)
            }
            // Demo mode uses no location: stop a lookup in flight; turning it off lets the refresh below locate again
            updateLocationNeed()
            arrivals = []
            feedStatuses = []
            refresh()
            // Demo mode never goes online for data: stop a key test still running; leaving it tests the keys that still need it
            if isDemo { stopCredentialTest() } else { verifyUntestedCredentials() }
        }
    }

    /// This time the place picker window is choosing a place for "Plan a Trip" (so trip planning can pick a place on the map too);
    /// the chosen place goes to trip planning (plannerPick) and doesn't change the main walking origin.
    @Published var pickerForPlanner = false
    /// Incremented each time the place picker is asked to open: even if it's already open (e.g. on the map), it goes back to the start
    @Published var pickerOpenCount = 0
    /// Place chosen for trip planning in the place picker; cleared once trip planning takes it
    @Published var plannerPick: UserPlace?
    /// Where the map starts when picking a place for trip planning (the place trip planning already has)
    var plannerMapStart: Coordinate?
    /// Manually chosen place (used when location mode is "manual" or location is unavailable).
    @Published var place: UserPlace = SharedStore.place {
        didSet {
            // In Demo mode only into its places in memory (SharedStore.demoPlaces)
            if persistsSettings { SharedStore.place = place }
            hasPlace = true
            updateArea()
            refresh()
        }
    }
    /// Whether `place` is a place someone chose (Demo mode's own count). While none was ever chosen, `place` only holds the built-in
    /// default, which is never walked from or named (see startingPlace).
    var hasPlace: Bool = SharedStore.hasChosenPlace
    @Published var locationMode: LocationMode = SharedStore.locationMode {
        didSet {
            // "Use my location" is off in Settings: only the user's chosen place can be used (Demo mode's current location is Times Square)
            if locationMode == .current, !locationAllowed, !isDemo { locationMode = .manual }
            if persistsSettings { SharedStore.locationMode = locationMode }
            updateLocationNeed()
            if locationMode == .current, isActive, !isDemo { location.request() }
            updateArea()
            // The two modes have separate temporary range extensions: switching modes switches the range too
            boardInputs &+= 1
            refresh()
        }
    }

    /// "Use my location" in Settings (Privacy and permissions). When off: no locating, forget the location already obtained, use the chosen place instead.
    /// The app can't change system permission settings for the user, so the app just stops using it; to turn it off fully, use the button next to it to open System Settings.
    @Published var locationAllowed: Bool = SharedStore.locationAllowed {
        didSet {
            guard locationAllowed != oldValue else { return }
            SharedStore.locationAllowed = locationAllowed
            location.allowed = locationAllowed
            updateLocationNeed()
            if locationAllowed {
                if locationMode == .current, isActive, !isDemo { location.request() }
                return
            }
            // A place name lookup still in flight must not bring the name back
            currentNameTask?.cancel()
            currentNameTask = nil
            currentNameCoordinate = nil
            currentCoordinate = nil
            currentAccuracy = nil
            currentPlaceName = nil
            // Demo mode's "My current location" is a made-up place that needs no location (OriginKind.demoCurrent): it stays.
            // Leaving Demo mode puts the user's own choice right (useDemoPlaces)
            if locationMode == .current, !isDemo { locationMode = .manual }
        }
    }
    /// "Allow network" in Settings (Privacy and permissions). When off, neither the main app nor the widget goes online;
    /// only timetables already saved on this Mac are used (see NetworkSwitch).
    @Published var networkAllowed: Bool = SharedStore.networkAllowed {
        didSet {
            guard networkAllowed != oldValue else { return }
            SharedStore.networkAllowed = networkAllowed
            // A shared live data file still downloading stops (the others are checked before they go online)
            if !networkAllowed { SharedLive.cancelAll() }
            updateRateLimits(now: Date())
            // Walking routes that failed while the network was off are asked again with this refresh
            if networkAllowed { routeBook.retryFailed() }
            if isActive { refresh() } else { saveSnapshot(widgetsNow: true) }
        }
    }

    @Published var language: AppLanguage = TransitModel.launchLanguage {
        didSet {
            if persistsSettings { SharedStore.language = language; Self.saveLayoutDirection(rightToLeft: language.isRightToLeft) }
            // Place names outside the service area are looked up per language; look them up again after a language change
            if isOutsideArea { updateArea(force: true) }
            if currentPlaceName != nil { updateCurrentPlaceName(force: true) }
            // Error messages are stored already written in a language: refresh once after a language change so they follow the new language
            if lastError != nil || !stationNotices.isEmpty, isActive { refresh() }
            saveSnapshot(widgetsNow: true)
            // The reminders' notifications were written in the old language
            if language != oldValue { reminders.rewrite(l: l10n) }
            // So were Demo mode's presets: those it still names as it named them take the new language's names (in memory only)
            if language != oldValue, SharedStore.demoPlaces != nil {
                let renamed = l10n.demoPresetsRenamed(SharedStore.commutePresets, from: UIText(language: oldValue))
                if renamed != SharedStore.commutePresets { SharedStore.commutePresets = renamed }
            }
        }
    }
    /// "System Language" is chosen in Settings: the language follows the Mac's, picked again at each launch (see launchSetting)
    @Published var languageFollowsMac: Bool = TransitModel.launchSetting.followsMac {
        didSet { if persistsSettings { SharedStore.languageFollowsMac = languageFollowsMac } }
    }

    /// Whether changes to the language, units, clock, text size, appearance, mode, walking origin, place, selected station, Demo mode,
    /// the catch settings and the refresh interval are saved.
    /// Off in the tests' host: changes there apply in memory only.
    var persistsSettings: Bool = {
        #if DEBUG
        return !TransitModel.isTestHost
        #else
        return true
        #endif
    }()
    /// Left-to-right or right-to-left. Decided only at app launch from the language then: flipping the whole window to right-to-left mid-run,
    /// AppKit's window layout keeps recomputing until it crashes. A language with a different direction takes effect next launch.
    let layoutDirection: LayoutDirection = TransitModel.launchLanguage.isRightToLeft ? .rightToLeft : .leftToRight
    /// A language with a different layout direction was chosen in Settings (left-to-right ↔ right-to-left, either way); waiting for the user to confirm a restart.
    /// Not switched right away: if the text changes first and the window direction only after a restart, text and direction mismatch in between and the layout is broken.
    @Published var pendingLanguage: AppLanguage?
    /// The pending language was chosen as "System Language" (it then follows the Mac after the restart too)
    var pendingFollowsMac = false

    /// Shown under Settings' Delete Downloaded Data… and Remove… when a file couldn't be deleted
    @Published var deleteError: String?

    /// Message shown when the restart failed (under the language in Settings)
    @Published var relaunchError: String?

    @Published var units: DistanceUnit = SharedStore.units {
        didSet {
            if persistsSettings { SharedStore.units = units }
            saveSnapshot(widgetsNow: true)
        }
    }
    /// 12 / 24-hour clock, shared by the main window, menu bar panel and widget
    @Published var clock: ClockStyle = SharedStore.clock {
        didSet {
            if persistsSettings { SharedStore.clock = clock }
            saveSnapshot(widgetsNow: true)
        }
    }
    /// Text size in the app (main window, Settings, place picker and menu bar panel). The widget follows macOS.
    @Published var textSize: AppTextSize = AppTextSize(rawValue: UserDefaults.standard.string(forKey: "textSize") ?? "") ?? .standard {
        didSet {
            if persistsSettings { UserDefaults.standard.set(textSize.rawValue, forKey: "textSize") }
            TextScale.factor = textSize.factor
        }
    }
    /// Request from the top-of-screen menu bar to the main window (so every feature is also available from the menu bar). Cleared once the main window handles it.
    enum MenuRequest: Equatable { case choosePlace }
    @Published var menuRequest: MenuRequest?
    /// "Show trains" in the map window asks the station's card in the sidebar for its small bounce (see showStationFromMap)
    @Published var cardBounce: CardBounce?
    /// Menu bar shortcuts (⌘ plus a key), changeable in Settings, stored only on this Mac.
    @Published var shortcuts = TransitModel.loadShortcuts() {
        didSet { UserDefaults.standard.set(shortcuts.encoded(), forKey: "keyboardShortcuts") }
    }

    /// Automatically check for new versions (off by default; when on, checks at most once a month, see UpdateCheck)
    @Published var autoCheckUpdates = UserDefaults.standard.bool(forKey: "autoCheckUpdates") {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates")
            if autoCheckUpdates { checkForUpdatesIfDue() }
        }
    }
    /// Main switch for shortcuts, on by default: saved only once it's switched, so someone who never switched it follows the
    /// default, and someone who turned it off keeps it off. When off the menus have no such shortcuts (macOS built-ins like ⌘,
    /// ⌘W ⌘Q still work).
    @Published var shortcutsEnabled = UserDefaults.standard.object(forKey: "keyboardShortcutsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shortcutsEnabled, forKey: "keyboardShortcutsEnabled") }
    }

    /// System / light / dark (see launchAppearance), switched for the whole app: main window, Settings and menu bar panel.
    @Published var appearance: AppAppearance = TransitModel.launchAppearance {
        didSet {
            if persistsSettings { SharedStore.appearance = appearance }
            appearance.apply()
        }
    }
    /// Transit mode (chosen next to the main window title): Subway (with light rail), Bus, Train, Ferry, the same four in every metro
    /// area, each covering the whole of the start place's area (its states are not split). Modes are shown separately, never mixed.
    @Published var system: TransitSystem = SharedStore.system {
        didSet {
            // Not one of the four (e.g. .path): switch to the one it belongs to, then carry on as usual (changing itself in didSet doesn't trigger didSet again,
            // so don't return here: the cleanup and refresh below must still run)
            if system != system.mode { system = system.mode }
            guard system != oldValue else { return }
            boardInputs &+= 1
            if persistsSettings { SharedStore.system = system }
            // Switching systems: clear the other system's stations and departures, then re-download
            arrivals = []
            feedStatuses = []
            busError = nil
            busFetchedAt = nil
            busResponseTime = nil
            lastError = nil
            stationNotices = []
            stations = []
            walks = [:]
            // Release the bus stop catalog when not using buses, to save memory
            if system != .bus { busCatalogStorage = nil } else { ensureBusCatalogLoaded() }
            // Also drop the nearby stations, departure tables and walking route lengths computed for the previous mode
            stationsMemo = nil
            boardCache = [:]
            routeBook.reset()
            // Rate limits and connection notices of the new mode only (see NoticeScope)
            updateRateLimits(now: Date())
            if oldValue.hasTimetablePart {
                // Release train data when not using trains (ferries, the timetable part of buses) (the files stay)
                ferryFeed = nil
                activeMemo = nil
                busActiveMemo = nil
                ferryDownloadFailed = false
                subwayPartsMissing = []
                busOperatorsMissing = false
                ferryUpdatedAt = nil
                ferryRealtimeAt = nil
                subwayDownloadTask?.cancel()
                subwayDownloadTask = nil
                // Keep only the selected transit mode's data in memory
                let old = FerryStore.stores(for: oldValue)
                let wasSubway = oldValue == .subway
                Task {
                    for store in old { await store.release() }
                    if wasSubway { await FerryStore.releaseSubwayPart() }
                }
            }
            refresh()
            saveSnapshot(widgetsNow: true)
            MemoryRelief.soon()
        }
    }

    /// Train or ferry data (depending on the selected system; downloaded on this Mac on first use, see FerryStore).
    @Published var ferryFeed: FerryFeed? {
        didSet {
            boardInputs &+= 1
            busTripKeep = nil
            ferryRoutesByPier = ferryFeed?.routesByPier() ?? [:]
            let groups = ferryFeed?.pierGroups() ?? [:]
            var byGroup: [String: [String]] = [:]
            for (id, g) in groups { byGroup[g.group, default: []].append(id) }
            ferrySamePier = groups.mapValues { (byGroup[$0.group] ?? []).sorted() }
            terminalsByPier = [:]
            stationInputs += 1
        }
    }
    /// Destinations per direction for each pier (station): computed once and kept (the UI needs it on every redraw; scanning all departures each time costs too much CPU)
    private var terminalsByPier: [String: [(route: String, direction: String, terminal: String)]] = [:]
    func terminals(atPier id: String, in feed: FerryFeed) -> [(route: String, direction: String, terminal: String)] {
        if let t = terminalsByPier[id] { return t }
        let t = feed.terminals(atPier: id)
        terminalsByPier[id] = t
        return t
    }
    /// How many times the nearby-station inputs (timetable data, station catalog) changed: if unchanged and location and range are the same, no need to re-pick nearby stations each refresh
    var stationInputs = 0
    var stationsMemo: (key: String, value: [Station])?
    /// Train and ferry data with the operators whose timetables have run out removed (see refreshFerry)
    var activeMemo: (key: String, feed: FerryFeed?)?
    /// IDs of nearby bus trips (live data keeps only these); recomputed when the nearby area changes
    var busTripKeep: Set<String>?
    /// Timetable part of buses with run-out operators removed: same day and unchanged nearby area reuses last time's (comparison is fast when the arrays haven't changed)
    var busActiveMemo: (day: Int, input: FerryFeed, output: FerryFeed)?
    /// The last MTA Bus Time answer, reused for the same stops for a little under a minute (see refreshBus); dropped when the key changes
    var busLoadMemo = BusLoadMemo()
    var ferryRoutesByPier: [String: [String]] = [:]
    /// Operators at the same pier (pier ID → all pier IDs in the same group, e.g. NYC Ferry, NY Waterway, Seastreak at Pier 11)
    var ferrySamePier: [String: [String]] = [:]
    /// Ferry data couldn't be downloaded (first use, no network).
    @Published var ferryDownloadFailed = false
    /// Subway: the parts of its timetable data (PATH, light rail) not on this Mac yet (see FerryStore.subwayPart)
    @Published var subwayPartsMissing: [TransitSystem] = []
    /// Bus: a company downloaded only for places in its area (SEPTA) isn't on this Mac yet, though the starting point is in that area
    /// (see FerryStore.lacksOperators)
    @Published var busOperatorsMissing = false
    /// Time ferry departures were last organized
    @Published var ferryUpdatedAt: Date?
    /// Time of the latest ferry live data (the oldest when there are several operators; nil when the download failed or no nearby ferry has live data)
    @Published var ferryRealtimeAt: Date?

    /// Whether an MTA Bus Time key is entered in Settings (the key itself is only stored in the Keychain).
    /// The Keychain is read in the background at launch (it may take a moment; the main window shouldn't hang); keysLoaded is false until done.
    var busKeyCache: String?? {
        // A changed or removed key never reuses an answer the old key got
        didSet { if busKeyCache != oldValue { busLoadMemo = BusLoadMemo() } }
    }
    @Published var hasBusKey = false
    /// The Bus Time key that was read (in memory only; "Plan a Trip" uses this too instead of reading the Keychain again)
    var busTimeKey: String? { busKeyCache ?? nil }
    @Published var keysLoaded = false
    /// The latest bus data download problem (no key entered, invalid key, etc.).
    @Published var busError: BusTimeError?
    /// NJ Transit developer account entered (live data for trains and light rail)
    @Published var hasNJTransitAccount = false
    /// Swiftly key for Suffolk County Transit (live data, the user applies for it). Read in the background like the Bus Time key, kept only in memory.
    var suffolkKeyCache: String??
    @Published var hasSuffolkKey = false
    var suffolkKey: String? { suffolkKeyCache ?? nil }
    /// Swiftly doesn't accept the stored key (or hasn't approved Suffolk data yet)
    @Published var suffolkKeyRejected = false
    /// The Keychain couldn't read the Bus Time key, the Swiftly key or the NJ Transit account (a denied or cancelled prompt, a locked keychain).
    /// It may well still be saved, so it's neither cached as missing nor shown as removed; Settings offers to read it again (see retryKeychainRead)
    @Published var busKeyUnreadable = false
    @Published var suffolkKeyUnreadable = false
    @Published var njTransitAccountUnreadable = false
    /// That retry is reading the Keychain
    @Published var retryingKeychainRead = false
    /// Bus operators near the place in use whose live data download failed last time (codes, e.g. Bee-Line's server returning 503):
    /// Settings states timetables are used for now
    @Published var busRealtimeFailed: Set<String> = SharedStore.busRealtimeFailed {
        didSet { SharedStore.busRealtimeFailed = busRealtimeFailed }
    }
    /// The NJ Transit account was saved or deleted in Settings after launch (an old result read in the background must not override it)
    var accountTouched = false
    /// NJ Transit doesn't accept the stored account
    @Published var njTransitRejected = false
    /// NJ Transit's bus API doesn't accept this account (buses use a different API that may need separate activation)
    @Published var njTransitBusRejected = false
    /// Removing the account, or undoing a save that failed halfway, left its username or password (or both) in the Keychain: what's left is never used,
    /// and Settings keeps the Remove Account button so the rest can be removed (saved, so this still holds after a relaunch; a successful save clears it)
    @Published var njTransitPartlyRemoved = UserDefaults.standard.bool(forKey: TransitModel.njTransitPartlyRemovedKey) {
        didSet {
            if njTransitPartlyRemoved != oldValue { UserDefaults.standard.set(njTransitPartlyRemoved, forKey: Self.njTransitPartlyRemovedKey) }
        }
    }
    static let njTransitPartlyRemovedKey = "njTransitPartlyRemoved"
    /// The same for the Bus Time key and the Swiftly key: removing it left it in the Keychain. It's never used, and Settings keeps the
    /// Remove Key button (saved, so this still holds after a relaunch; saving a key clears it)
    @Published var busKeyLeftover = UserDefaults.standard.bool(forKey: TransitModel.busKeyLeftoverKey) {
        didSet { if busKeyLeftover != oldValue { UserDefaults.standard.set(busKeyLeftover, forKey: Self.busKeyLeftoverKey) } }
    }
    @Published var suffolkKeyLeftover = UserDefaults.standard.bool(forKey: TransitModel.suffolkKeyLeftoverKey) {
        didSet { if suffolkKeyLeftover != oldValue { UserDefaults.standard.set(suffolkKeyLeftover, forKey: Self.suffolkKeyLeftoverKey) } }
    }
    static let busKeyLeftoverKey = "busKeyLeftover"
    static let suffolkKeyLeftoverKey = "suffolkKeyLeftover"
    /// A key or account is being tested and saved: every copy of its Settings window waits (Remove and Save stay off), so a removal
    /// can't happen during the save and two tests can't overlap
    @Published var savingBusKey = false
    @Published var savingNJTransitAccount = false
    @Published var savingSuffolkKey = false
    /// Whether each key or account was tested and works ("Live" is shown only after it worked). Only these results are saved, never the keys.
    @Published var credentialChecks: [Credential: CredentialCheck] = TransitModel.savedCredentialChecks() {
        didSet { if credentialChecks != oldValue { Self.saveCredentialChecks(credentialChecks) } }
    }
    /// What NJ Transit said the last time it refused the account (shown in Settings to help find the cause)
    @Published var njTransitRefusal: String?
    /// What NJ Transit said about an account tried in Settings and not saved because it was refused (the saved account's stays in njTransitRefusal)
    var njTransitTriedRefusal: String?
    /// The account tried and refused is the saved one, and it works only on NJ Transit's test system (njTransitTestOnly is about the saved account)
    var njTransitTriedTestOnly = false
    /// What Swiftly answered when the Suffolk key test couldn't tell whether the key works (shown in Settings)
    @Published var suffolkCheckNote: String?
    /// After NJ Transit refused the account: whether the same account works on NJ Transit's test system (true means production access
    /// isn't turned on yet). Checked at most once a day, because NJ Transit limits sign-ins.
    @Published var njTransitTestOnly: Bool? = TransitModel.savedNJTransitTestProbe()?.works
    /// When keys that couldn't be confirmed were last tested again (at most every 10 minutes)
    var lastCredentialRetest: Date?
    /// The NJ Transit test-system check is running
    var probingNJTransitTest = false
    /// A test of saved keys is running (see verifyUntestedCredentials)
    var verifyingCredentials = false
    /// That test in progress (standby and Demo mode stop it, see stopCredentialTest)
    var credentialVerifyTask: Task<Void, Never>?
    /// The keys that test shows as "Checking…", each with what its row showed before (put back when the test can't tell or is stopped)
    var checksBeforeRetest: [Credential: CredentialCheck?] = [:]
    /// Operators whose times are live with the account the user entered, so their live data is downloaded (see liveWithAccount)
    var accountSources: Set<FerryFeed.Source> {
        hasNJTransitAccount ? Set(FerryFeed.Source.allCases.filter(\.liveWithAccount)) : []
    }
    /// What the last data updates changed, and the operators whose new data isn't in use (DataChangeLog), as Settings' Data
    /// source page tells it: read when the app starts, after each data check and when that page shows
    @Published private(set) var dataChanges = DataChangeLog()
    /// When the live departures last showed served what an operator's kept-out data leaves out, by its key (noteLiveWitness):
    /// so a file that couldn't be written isn't tried again every half minute
    var witnessTried: [String: Date] = [:]
    /// What the data in use has that this version doesn't know (UnknownData), as Settings' Data source page tells it: the
    /// timetables' (noted by their stores as they read or save them), the subway's station list and PATH's live data
    @Published private(set) var unknownData: [UnknownData.Finding] = []
    /// PATH's live data codes this version doesn't know (PathLive.stationNames), from its last download
    var pathLiveUnknown: Set<String> = [] {
        didSet { if pathLiveUnknown != oldValue { reloadUnknownData() } }
    }
    /// unknownData was logged once since launch (then only when it changes)
    var unknownDataLogged = false
    @Published var busFetchedAt: Date?
    @Published var busResponseTime: Date?

    /// The map app "Directions" opens the walk to a station in (Settings, Privacy; TransitModel+Directions)
    @Published var directionsMap: DirectionsMap = SharedStore.directionsMap {
        didSet { if persistsSettings { SharedStore.directionsMap = directionsMap } }
    }

    /// How often to refresh when "Start"ed (seconds), changeable in Settings, 30 seconds by default.
    @Published var refreshInterval: TimeInterval = SharedStore.refreshIntervalSeconds {
        didSet { if persistsSettings { SharedStore.refreshIntervalSeconds = refreshInterval }; boardInputs &+= 1 }
    }

    /// Stations currently used in the calculation.
    @Published var stations: [Station] = [] {
        didSet { boardInputs &+= 1 }
    }
    @Published var arrivals: [Arrival] = [] {
        didSet {
            boardInputs &+= 1
            noteLiveWitness()
        }
    }
    /// The first departure after the arrival window at the stations where a direction has nothing in it, read from the timetables
    /// on this Mac (see updateLaterDepartures): there the board says when the next one comes (BoardDirection.next)
    @Published var laterArrivals: [Arrival] = [] {
        didSet { boardInputs &+= 1 }
    }
    /// What laterArrivals was looked up for (the stations, the window and a ten-minute slot), and the lookup still running
    var laterKey = ""
    var laterTask: Task<Void, Never>?
    /// Walking time from the origin to each station.
    @Published var walks: [String: WalkEstimate] = [:] {
        didSet { boardInputs &+= 1 }
    }
    /// Time of the latest refresh attempt (successful or not).
    @Published var lastAttempt: Date?
    /// Download status of each MTA feed (live mode only).
    @Published var feedStatuses: [FeedStatus] = []
    @Published var lastError: String?
    /// Live-data problems that concern only some stations (one MTA subway feed, PATH, one rail or ferry company, some bus stops):
    /// shown only at the stations they affect, never over every station. lastError is for problems that affect all of them.
    @Published var stationNotices: [StationNotice] = []
    /// Data providers currently rate-limiting us (too many requests), noted in the UI and widget
    @Published var rateLimits: [RateLimit.Notice] = []
    /// Data providers we can't reach (offline, server not found, no response, secure connection failed, refused); the UI and widget explain why
    @Published var reachNotices: [NetworkReach.Notice] = []
    /// How far off this Mac's clock is, when that's worth saying (ClockSkew.noticeOffset), rounded to the minute: the main window's
    /// top and Settings say so. The menu bar and the widget don't: their times already go by the servers' time. Set with the notices
    /// above (updateRateLimits, in TransitModel+Board)
    @Published var clockOffset: TimeInterval?
    /// Data providers that aren't shown to the user, only logged for the developer (their own problem, timetables available). See updateRateLimits
    nonisolated static let developerOnlyProviders: Set<String> = ["Bee-Line"]
    /// Same as above, by bus operator code (Bee-Line = BXL)
    nonisolated static var developerOnlyFeedCodes: Set<String> {
        Set(RegionalBusFeed.all.filter { developerOnlyProviders.contains($0.name) }.map(\.code))
    }
    /// Already logged during this run (once per provider)
    var loggedDeveloperNotices: Set<String> = []
    @Published var isRefreshing = false
    @Published var isRouting = false
    /// The stations whose walking route Apple Maps is being asked for now (requestRoutesIfNeeded): until it comes or can't, a
    /// train there can't have a reminder yet, so none is set with the straight line's shorter walk
    @Published var routesAsked: Set<String> = []
    @Published var locationState: LocationService.State = .idle
    /// Location permission for this app is turned off in System Settings
    @Published var locationAccessOff = false
    /// Current location from Location Services (in memory only, not saved).
    @Published var currentCoordinate: Coordinate?
    /// How far off it may be, in meters, as macOS says (nil when it doesn't); in memory only, like the position
    @Published var currentAccuracy: Double?
    /// Start / Standby. Shares the same file in the shared folder with the widget.
    @Published var activity: ActivityState
    /// Selected station and the direction shown in the widget. Shared with the widget (changing station or direction on the widget changes it here too).
    @Published var selection: BoardSelection = SharedStore.loadSelection()

    /// Station catalog: the built-in one, or one regenerated after the monthly check that's newer than the built-in (see StaticData). Reloaded when the check swaps in a new one.
    @Published var catalog: StationCatalog? {
        didSet { stationInputs += 1; boardInputs &+= 1; reloadUnknownData() }
    }
    var catalogError: String?
    /// Express data that goes with the station catalog (read once and kept, not re-read every refresh)
    var express: ExpressStops?
    /// Roosevelt Island Tram operating hours (checked monthly with the subway, see SubwayMapStore); departures estimated from the headways on RIOC's website
    /// (read in init once the data folder is set, see SharedStore.useStaticDataFolder)
    var tramHours = RooseveltIslandTram.builtInHours

    /// Bus stop catalog (built-in or updated after the monthly check): read only the first time bus mode is used, released when switching back to subway.
    var busCatalogStorage: BusCatalog? {
        didSet { stationInputs += 1; boardInputs &+= 1 }
    }
    /// The bus stop catalog, nil until loaded. Reading it has no side effects (views read it while drawing); loading starts with ensureBusCatalogLoaded.
    var busCatalog: BusCatalog? { busCatalogStorage }

    /// The bus stop catalog couldn't be read (see busCatalog)
    var busCatalogFailed = false
    /// Loading the bus stop catalog in the background (first switch to bus mode, off the main thread so the UI doesn't stutter)
    var busCatalogTask: Task<Void, Never>?
    /// The monthly check in progress (see checkStaticDataIfDue)
    var staticCheckTask: Task<Void, Never>?
    /// Asking the repository for the source list (see checkSourceListIfDue); true when the list in use changed
    var sourceListTask: Task<Bool, Never>?
    /// The last time asking for it failed for the network (asked again an hour later, see SourceListStore.networkRetry)
    var sourceListNetworkFailedAt: Date?

    let location = LocationService()
    let router = WalkRouter()
    /// MapKit route lengths (meters) from the current origin to each station, and which stations to ask next.
    var routeBook = WalkRouteBook()
    /// The stations whose straight-line estimate crosses water (WalkEstimate.isAcrossWater), shown or waited for: their routes are
    /// asked first and again after a minute (WalkRouteBook)
    var acrossWaterIDs: Set<String> = []

    var refreshCount = 0
    /// When Demo mode's times were last made, and their seed: Plan a Trip makes its own from the same, so a station shows the same
    /// times in both (MockTransitData.demoPlan)
    var demoTimesBase: (at: Date, seed: Int)?
    var refreshTask: Task<Void, Never>?
    /// Walking route requests in progress, each removed when it finishes. Several can run at once (new stations appear while one is
    /// still asking), so all of them stop on standby or when the origin moves (see requestRoutesIfNeeded)
    var routeTasks: [UUID: Task<Void, Never>] = [:]
    /// The stations each of those asks about (routesAsked is all of them)
    var routeTaskStations: [UUID: Set<String>] = [:]
    var autoRefreshTask: Task<Void, Never>?
    /// Whether it was "Start"ed at the last check (used to detect auto-standby or a toggle on the widget).
    var wasActive = false
    /// Time the widget was last reloaded and what the widget would show then (see reloadWidgets).
    var lastWidgetReload: Date?
    var lastWidgetSignature: Int?
    /// When the next refresh finishes and the snapshot is saved, reload the widget immediately (refresh or start was tapped on the widget).
    var forceNextWidgetReload = false
    /// Whether the last snapshot saved had out-of-date data (nil before the first): when that changes, widgets reload at once
    var lastSnapshotStale: Bool?
    /// Waits until the reminders' lead chosen in Settings has stood still, then moves the reminders that wait (setReminderLead)
    var reminderLeadTask: Task<Void, Never>?
    /// A reminder's station clicked on standby, to select once a refresh has it on the board, and when (showReminderStation)
    var pendingReminderStation: (id: String, at: Date)?
    /// When "Start"ed, don't let macOS nap the app (App Nap), so it refreshes on time even running only in the menu bar and the widget keeps up.
    var keepAwake: NSObjectProtocol?
    /// In the background, keep a minimum gap between reloads; if something changes in between, do one more when the time comes.
    /// Whether the pending reload is "take effect now" (load regardless of whether the widget data changed)
    var pendingWidgetForce = false
    var pendingWidgetReload: Task<Void, Never>?
    /// "Shared data changed" signal from the widget (see SharedSignal).
    private var signalObserver: SharedSignalObserver?
    private var becomeActiveObserver: NSObjectProtocol?
    private var staticDataObserver: NSObjectProtocol?
    private var dataChangesObserver: NSObjectProtocol?

    /// Whether the main window is open. When closed the app runs only in the menu bar: still updates data every 30 seconds (the widget needs it),
    /// but locates less often.
    var isWindowOpen = true
    /// Whether the map window is open. Its walking range is drawn around where you are, so while it's open the app locates as often as
    /// with the main window open, even when the main window is closed.
    var isMapWindowOpen = false

    init() {
        TextScale.factor = (AppTextSize(rawValue: UserDefaults.standard.string(forKey: "textSize") ?? "") ?? .standard).factor
        // The station list updated by the monthly check lives in the shared folder (the widget reads the same copy)
        SharedStore.useStaticDataFolder()
        // Each time new data is held against the old (see DataUpdateGate), the log says how it went: counts only, no stop's name
        // Settings reads the log again then (Data source tells what came of the last updates)
        DataChangeLog.observer = { entry in
            AppLog.data.notice("data check: \(entry.summary, privacy: .public)")
            Task { @MainActor in NotificationCenter.default.post(name: .dataChangesDidChange, object: nil) }
        }
        tramHours = RooseveltIslandTram.loadCurrentHours()
        // The maps' metro-area rings are worked out once, from the region code (MetroOutline): start now, off the main thread, so a
        // map opened later doesn't wait for it
        Task.detached(priority: .utility) { _ = MetroOutline.current }
        // "Use my location" is off in Settings but "My current location" is stored: switch to the chosen place
        if !SharedStore.locationAllowed, SharedStore.locationMode == .current {
            if !TransitModel.isTestHost { SharedStore.locationMode = .manual }
            locationMode = .manual
        }
        // A new install starts with no favorites and no recent places: with many metro areas, sample places in one of them would only
        // be in the way (and a favorite keeps its area's timetables downloaded). Demo mode has its own places
        // Only write the counts (no place names or coordinates); compare before and after installing a new version to confirm favorites etc. weren't lost
        SharedStore.logSavedCounts()
        // Opened in Demo mode: its own places from the start (the saved ones were counted above and stay as they are)
        // (set here directly, without the observers, so nothing is saved). Read from SharedStore, the data source's starting value:
        // reading a property of the model itself has to wait until all of them have their first values (activity is set below)
        if SharedStore.dataSource == .mock {
            SharedStore.demoPlaces = SharedStore.DemoPlaces(presets: UIText(language: Self.launchLanguage).demoPresets)
            place = SharedStore.place
            hasPlace = true
            locationMode = SharedStore.locationMode
            CommutePresetCenter.shared.reload()
        }
        if !TransitModel.isTestHost {
            FerryStore.removeLegacyFiles()
            // Before anything downloads, saves or removes data: the dates the 30 days count from, and the areas the user removed
            DownloadedData.startDatesOnce()
        }
        PlacesInUse.setRemoved(AreaData.removed())
        let subway = TransitModel.loadSubwayData()
        _catalog = Published(initialValue: subway.catalog)
        catalogError = subway.error
        express = subway.express
        let now = Date()
        if TransitModel.isTestHost {
            // The tests' host stays on standby and stops here: the heartbeat, signals, location, downloads and Keychain reads below
            // aren't for it, and the saved state stays this Mac's own
            activity = (SharedStore.loadActivity() ?? ActivityState.firstLaunch(at: now)).stopped(at: now)
            DownloadGate.shared.pause()
            return
        }
        if let saved = SharedStore.loadActivity() {
            activity = saved
        } else {
            // Never run on this Mac before (an update from an older version already has a saved state): on standby until the
            // setup window is finished
            activity = ActivityState.newInstall(at: now)
            SharedStore.saveActivity(activity)
            SetupWindow.isPending = true
        }
        wasActive = activity.isActive(at: now)
        // Setup not finished (a new install, or one that quit halfway): wait for it. Started some other way since (a widget's
        // Start while the app wasn't running): nothing to wait for
        if SetupWindow.isPending {
            if wasActive { SetupWindow.isPending = false } else { waitsForSetup = true }
        }
        SetupWindow.finish = { [weak self] in self?.finishSetup() }
        // A reminder set, moved or cancelled: how long the app stays on for them
        reminders.onChange = { [weak self] in self?.holdForReminders() }
        SharedStore.appAliveAt = now
        location.onUpdate = { [weak self] in self?.locationDidUpdate() }
        // Before macOS reports the permission (it does right at launch): on standby, with a chosen place or in the demo that report doesn't locate
        updateLocationNeed()
        // Toggling, changing station or tapping refresh on the widget: follow immediately (no waiting for the 15-second check)
        signalObserver = SharedSignalObserver { [weak self] in
            Task { @MainActor in self?.syncActivity(now: Date()) }
        }
        // When switching back to the main app, let the widget catch up with the main app's latest data right away
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadWidgets() }
        }
        // The monthly check swapped the station list (checked when the map opened or by checkStaticDataIfDue): reload
        staticDataObserver = NotificationCenter.default.addObserver(
            forName: .staticDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadStaticData() }
        }
        // A data check wrote its entry in the log (DataUpdateGate): Settings' Data source tells it
        dataChangesObserver = NotificationCenter.default.addObserver(
            forName: .dataChangesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadDataChanges() }
        }
        reloadDataChanges()
        // Quitting the app: save once more for the widget with the normal range instead of the temporary extension. Must finish before quitting, so do it directly on the main thread
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreNormalRangeBeforeQuit() }
            // The counts once more, so an install that quits the app first can read them right then (the launch line is gone from
            // the log after a few days of running)
            SharedStore.logSavedCounts()
        }
        // Refresh right after waking from sleep (no waiting for the next 15-second check), and get the current location again
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterInterruption() }
        }
        // This Mac's clock was set: the offsets measured before no longer say anything (see ClockSkew)
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { _ in
            ClockSkew.forgetReadings()
        }
        // This Mac's time zone was changed: the views are drawn again, so the note saying whose time the times are (TimeZoneNoteLine)
        // comes or goes right then (it waited for the next refresh)
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        // Refresh right away when the network reconnects (refreshes failed while it was down)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "CatchMyTrain.network"))
        if wasActive {
            updateKeepAwake(active: true)
            if locationMode == .current, dataSource == .mtaRealtime { location.request() }
            refresh()
        } else {
            // Launched on standby: no timetable or map downloads until Start (see DownloadGate)
            DownloadGate.shared.pause()
            updateArea()
        }
        startAutoRefresh()
        loadKeys()
    }

    private var wakeObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private let networkMonitor = NWPathMonitor()
    /// Last known network state (nil = not known yet)
    var isOnline: Bool?

    // The following are used when refreshing and organizing departures (methods in TransitModel+Refresh.swift, TransitModel+Board.swift)
    /// PATH and light rail data: if never downloaded or the monthly check is due, download in the background and refresh once more when done.
    /// Separate from each refresh (a refresh cancels the previous refresh), so refreshing doesn't interrupt the download.
    /// Whoever cancels it also clears it: a cancelled task leaves the handle alone, since it may already belong to a newer download.
    var subwayDownloadTask: Task<Void, Never>?

    /// Timetables of several bus operators: when a check is due (or never downloaded), download in the background and refresh once more when done.
    /// Separate from each refresh (a refresh cancels the previous refresh), so refreshing doesn't interrupt the download.
    /// Whoever cancels it also clears it (see subwayDownloadTask).
    var busDownloadTask: Task<Void, Never>?

    static let boardBucketSeconds: TimeInterval = 5
    /// How many times stations, departures, walking times, settings etc. (data used by board) changed
    var boardInputs = 0
    /// For the trip planning departure table cache: whether the lines through each station, settings etc. changed
    var boardInputsVersion: Int { boardInputs }
    var boardCacheStamp: (inputs: Int, bucket: Int) = (-1, -1)
    var boardCache: [BoardKey: NearbyBoard] = [:]
    struct BoardKey: Hashable {
        var routeFilter: Set<String>?
        var maxTrains: Int
    }

    /// A new install is waiting, on standby, for its setup window (SetupWindow) to be finished: until then macOS isn't asked for
    /// location and nothing is downloaded or refreshed. Any Start ends the wait.
    @Published var waitsForSetup = false

    @Published var areaRegion: MetroSubRegion?
    @Published var outsideAreaName: String?
    /// The time zone of where you are outside the service area, from the place name lookup (see placeTimeZone); nil if not looked up
    @Published var outsideTimeZone: TimeZone?
    /// The origin is outside the service area
    @Published var isOutsideArea = false
    var areaCoordinate: Coordinate?
    /// The place name is the place's name used first on standby; look it up again after start
    var areaNameIsFallback = false
    var areaTask: Task<Void, Never>?

    /// Place name of the current location (shown in the sidebar like a chosen place).
    /// Looked up with the Mac's built-in Apple Maps (as for walking routes), only again after moving over 150 meters, not on standby.
    @Published var currentPlaceName: String? = nil
    var currentNameCoordinate: Coordinate?
    var currentNameTask: Task<Void, Never>?
    var currentNameFailedAt: Date?
    static let placeNameRetrySeconds: TimeInterval = 5 * 60

    @Published var updateState: UpdateState = .idle
    /// Time of the last check (success or "no released version yet" both count as checked)
    @Published var lastUpdateCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    /// When the last check failed (memory only), so the automatic check waits a day (UpdateCheck.retryAfterFailure)
    var lastUpdateCheckFailed: Date?
    var updateTask: Task<Void, Never>?

    /// Reads the log of data checks again (DataChangeLog)
    func reloadDataChanges() {
        dataChanges = DataChangeLog.load()
        reloadUnknownData()
    }

    /// The app's own subway station list, read once: the station list in use is held against it (UnknownData.subway)
    nonisolated static let ownCatalog = try? StationCatalog.loadBundled()

    /// Gathers what the data in use has that this version doesn't know (UnknownData), and logs it when it changed (operator
    /// codes, kinds, counts and the data's own ids, no names)
    func reloadUnknownData() {
        var found = FerryStore.savedUnknownData()
        if let subway = UnknownData.subway(inUse: catalog, own: Self.ownCatalog) { found.append(subway) }
        if !pathLiveUnknown.isEmpty {
            let path = FerryFeed.Source.path.rawValue
            if let i = found.firstIndex(where: { $0.key == path && $0.kind == .stations }) {
                found[i].ids = Array(Set(found[i].ids).union(pathLiveUnknown)).sorted()
            } else if let live = UnknownData.path(feed: nil, liveCodes: pathLiveUnknown) {
                found.append(live)
            }
        }
        found.sort { ($0.key, $0.kind.rawValue) < ($1.key, $1.kind.rawValue) }
        guard found != unknownData || !unknownDataLogged else { return }
        unknownData = found
        unknownDataLogged = true
        AppLog.data.notice("data unknown: \(found.isEmpty ? "none" : found.map(UnknownData.summary).joined(separator: "; "), privacy: .public)")
    }

    /// New data that looked wrong and was kept out (dataChanges.kept): whether the live departures just shown have a vehicle at
    /// a stop or on a line it leaves out (DataWitness), counting only live ones still fresh. Then its entry in the log notes the
    /// time they were updated, at most hourly for each operator, and that data isn't taken after its week while the live data keeps showing them (DataUpdateGate). Nothing is
    /// downloaded for it. Not in the tests' host (persistsSettings), nor for Demo
    /// mode's made-up departures (not live)
    func noteLiveWitness() {
        guard persistsSettings, !arrivals.isEmpty, !dataChanges.kept.isEmpty else { return }
        let now = Date()
        let due = dataChanges.kept.filter { entry in
            entry.missing != nil && entry.waitingFingerprint != nil
                && DataWitness.wantsNote(lastSeen: entry.missing?.liveSeenAt, now: now)
                && DataWitness.wantsNote(lastSeen: witnessTried[entry.key], now: now)
        }
        guard !due.isEmpty, let sighting = DataWitness.sighting(in: arrivals, mode: system,
                                                                staleAfter: effectiveSettings.realtimeStaleAfterSeconds,
                                                                clockOffset: ClockSkew.current, now: now) else { return }
        let seenAt = sighting.at
        for entry in due {
            guard let shown = sighting.seen[entry.key], let print = entry.waitingFingerprint else { continue }
            let match = DataWitness.match(entry, shown)
            guard match.any else { continue }
            witnessTried[entry.key] = now
            let key = entry.key
            AppLog.data.notice("data witness: \(key, privacy: .public) live at \(match.stops, privacy: .public) stops and on \(match.routes, privacy: .public) lines its kept-out data leaves out")
            Task { [weak self] in
                let written = await offMain { DataChangeLog.noteLive(for: key, fingerprint: print, now: seenAt) }
                if written { self?.reloadDataChanges() }
            }
        }
    }
}
