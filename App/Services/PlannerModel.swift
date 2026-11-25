import Foundation
import MapKit
import TransitCore

/// Trip planner: enter a place and departure time to see in advance whether you can catch trains near there.
///
/// Separate from the main view: the main view always uses your current location; nothing here changes it.
/// - Address search uses Apple Maps (MapKit, no key needed), searching only around New York.
/// - Leaving within 30 minutes: realtime data where an operator has it, for the whole time range; leaving later: timetables only
///   (UI labels it "scheduled"). Light rail always uses its timetable here.
/// - Searched places stay in memory only and aren't saved.
/// - Its own walk (walkMinutes, the walk menu next to the time range): every station within it is listed, nearest first. Settings stay
///   the same, and the choice isn't saved.
/// - Demo mode has its own: its places in Manhattan and made-up times, nothing online (see updateDemo).
@MainActor
final class PlannerModel: NSObject, ObservableObject {

    struct Place: Equatable {
        var name: String
        var subtitle: String
        var coordinate: Coordinate
        /// A demo subway station's lines, so the line under its name is said in the UI language (UIText.demoPlaceDetail)
        var lines: [String] = []
    }

    enum DataKind: Equatable {
        case realtime
        /// mta: the MTA timetable was used (subway; false when no MTA station is near the place, so it wasn't downloaded)
        case scheduled(validUntil: Date?, mta: Bool = true)
    }

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(Note)
    }

    /// What the results say went wrong or is missing, kept as how to say it: it's put into words when shown, so switching the
    /// language says it in the new one (text made when the results came would stay in the language of then). Two notes are the
    /// same when they say the same in English.
    struct Note: Equatable {
        let words: (UIText) -> String
        private let english: String
        /// What the results offer under the note to put it right: nil when nothing there would help
        private(set) var action: Action?

        init(_ words: @escaping (UIText) -> String) {
            self.words = words
            english = words(UIText(language: .english))
        }

        /// The same note with this action under it
        func offering(_ action: Action?) -> Note {
            var note = self
            note.action = action
            return note
        }

        static func == (a: Note, b: Note) -> Bool { a.english == b.english && a.action == b.action }
    }

    /// The button under a note: Start (the app is on standby, so nothing is asked online), Refresh (asking online failed), or
    /// Settings… at the place the note names (SettingsJump)
    enum Action: Equatable {
        case start
        case refresh
        case settings(SettingsJump.Target)
    }

    /// A note about something that needs the network (live times, a download): with networking turned off in Settings, the main
    /// window's sentence for that instead, as checking the network or turning the app on wouldn't help; otherwise the note as it is.
    /// Notes that have nothing to do with the network (no timetable for that day yet, no key, a stop list that can't be read) don't
    /// come here. The switch stays apart from whether the app is on (allowNetwork): folded into it, the notes would say "Turn the
    /// app on", which is just as wrong
    /// The note offers Start when it asks to turn the app on (the app is on standby, so asking again wouldn't help), else Refresh;
    /// with networking off in Settings, neither would help: Settings… at Privacy and permissions, where it's turned on
    nonisolated static func needingNetwork(_ note: Note, networkOff: Bool) -> Note {
        if networkOff {
            return Note { $0.t("Network is off in Settings, so only timetables saved on this Mac are shown.") }.offering(.settings(.privacy))
        }
        return note.offering(asksToTurnOn(note) ? .start : .refresh)
    }

    /// Whether the note asks to turn the app on: the notes for live times and downloads while the app is on standby
    nonisolated static func asksToTurnOn(_ note: Note) -> Bool {
        let turnOn = [
            Note { $0.t("Turn the app on to get live times.") },
            Note { $0.t("Turn the app on to get PATH live times.") },
            Note { $0.t("Turn the app on to download the MTA timetable.") },
            Note { $0.t("Bus timetables are downloaded the first time you turn the app on.") },
            Note { $0.t("Train timetables are downloaded the first time you turn the app on.") },
            Note { $0.t("Ferry timetables are downloaded the first time you turn the app on.") },
        ]
        return turnOn.contains(note.offering(nil))
    }

    /// Use realtime data when leaving within this time from now (seconds); the choice covers the whole time range
    nonisolated static let realtimeHorizon: TimeInterval = 30 * 60
    // How far after departure to look for departures: same as the main view, using the arrival time window from Settings (CatchSettings.arrivalWindowSeconds)

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            // After a suggestion is selected the field shows its name: don't search that name again (otherwise the suggestion list pops back up and needs selecting twice)
            if let pickedText, query == pickedText { return }
            pickedText = nil
            // Editing the search text drops the address lookup of a suggestion chosen before (see choose)
            addressLookup.drop()
            retry.reset()
            // Don't search when the network is turned off in Settings; a search still running for the earlier text stops too.
            // Demo mode never asks Apple Maps: the trip planner lists its own places (DemoData.search)
            if inDemo || !USAddress.isSearchable(query) || !NetworkSwitch.isAllowed {
                completer?.cancel()
                suggestions = []
                nothingFound = false
            } else {
                searchCompleter().queryFragment = query
            }
        }
    }
    @Published var suggestions: [MKLocalSearchCompletion] = []
    /// Name of the item just selected (the text in the field): hide the suggestion list until the user edits the field again
    @Published var pickedText: String?
    /// Apple Maps found no place in the US for the text (see USAddress.saysNothingFound): a line under the field says so, and suggests a station name
    @Published var nothingFound = false
    @Published var place: Place? {
        didSet { if place?.coordinate != oldValue?.coordinate { placeArea = place.flatMap { MetroArea.of($0.coordinate) } } }
    }
    /// The metro area the place is in (nil outside the service area): its times are shown in the area's time zone
    private(set) var placeArea: MetroArea?
    @Published var leaveAt: Date = PlannerModel.defaultLeaveTime()
    /// A departure time was chosen (a quick choice, the calendar or the time): kept until it's past. Without one, leaveAt is the
    /// default, worked out again from the time the trip planner opens (refreshLeaveTimeIfPast), not from when the app started
    private(set) var leaveChosen = false

    /// The departure time chosen in the trip planner
    func chooseLeaveTime(_ time: Date) {
        leaveChosen = true
        leaveAt = time
    }
    /// How far after departure to look for departures: the trip planner's own setting (a button changes it, default 2 hours); doesn't affect the main view
    @Published var windowSeconds: TimeInterval = 2 * 3600
    /// How far to walk, in minutes: the trip planner's own choice from its walk menu (CatchSettings.plannerWalkChoices), nil = the
    /// longer walk in Settings. In memory only; Settings and the main view don't change
    @Published var walkMinutes: Double?
    @Published var status: Status = .idle {
        didSet {
            guard status != .loading else { return }
            refreshing = false
            if status == .ready { computedAt = BoardClock.now() }
        }
    }
    /// When the shown results were last computed ("Updated …" under live times; see refreshLive)
    @Published private(set) var computedAt: Date?
    /// Live times being fetched again on the refresh interval (refreshLive): the results shown stay until the new ones are in,
    /// instead of the loading line
    @Published var refreshing = false
    /// The address lookup of the chosen suggestion: another choice, clearing the place or editing the search text makes it stale (see choose).
    /// Closing the trip planner doesn't: the place picked last still arrives, and is computed when the trip planner is shown again (see resume).
    @Published var addressLookup = PlaceLookupGate()
    /// The status the results show: loading while a chosen suggestion's address is being looked up (the last place's results stay below)
    var shownStatus: Status {
        if addressLookup.isPending { return .loading }
        return refreshing && status == .loading ? .ready : status
    }
    @Published var dataKind: DataKind?

    @Published var stations: [Station] = [] { didSet { dataVersion &+= 1 } }
    @Published var walks: [String: WalkEstimate] = [:] { didSet { dataVersion &+= 1 } }
    @Published var arrivals: [Arrival] = [] { didSet { dataVersion &+= 1; arrivalsReceivedAt = Date() } }
    /// When the arrivals came in: live data is judged stale against this, not against the (later) departure time
    var arrivalsReceivedAt = Date()
    /// Departure time used for this query (catchability is judged against this time)
    @Published var computedLeaveAt: Date? { didSet { dataVersion &+= 1 } }

    /// Incremented when the data the departure board uses changes; the board is cached by it, so redraws and typing in the search field don't recompute every time
    var dataVersion = 0
    struct BoardKey: Equatable {
        var version: Int
        var window: TimeInterval
        var settings: CatchSettings
        var boardInputs: Int
    }
    var boardCache: (key: BoardKey, board: NearbyBoard?)?

    /// How long to wait before this computation goes online (see update)
    var startDelay: TimeInterval = 0
    /// The trip planner is on screen (set in resume, cleared in release): a lookup that lands while it's closed only sets the place
    var isShown = false
    /// Closing the trip planner stopped a computation, or a lookup landed while it was closed, and nothing has computed since (see resume)
    var stopped = false
    /// What the shown results were computed with: online (started) or only what's on this Mac (standby), for which transit system,
    /// and whether in Demo mode (see resume)
    var computedWith: (active: Bool, system: TransitSystem, demo: Bool)?
    /// Last MTA bus realtime data: don't query the same set of stops again within 60 seconds (same as the main window's bus refresh interval)
    var lastBusLoad: (stations: [String], at: Date, load: BusLoad)?

    /// Address search: created only on first input (Apple Maps' search service uses a fair amount of memory), released when not in use.
    var completer: MKLocalSearchCompleter?
    /// The simpler text asked when the text as typed found nothing (see SearchRetry)
    var retry = SearchRetry()
    var task: Task<Void, Never>?
    /// Finding the address of a point used from the large map (see choose(mapPoint:))
    var naming: Task<Void, Never>?
    /// New Jersey buses: the trip planner's place may be far from the main view's, so routes through each stop come from the chunk fetched here (see updateFerry)
    var feedRoutes: [String: [String]]? { didSet { dataVersion &+= 1 } }
    /// The place and search are Demo mode's (see setDemo): its search never asks Apple Maps
    var inDemo = false

    private func searchCompleter() -> MKLocalSearchCompleter {
        if let completer { return completer }
        let c = AddressSearch.makeCompleter(delegate: self)
        completer = c
        return c
    }

    /// Now in the trains' time (the servers' clock, see ClockSkew): what Plan a Trip's times are picked in and worked out from. A
    /// time picked is a time on the clock, as the trains' times are, not this Mac's own when its clock is off
    nonisolated static func trainTimeNow() -> Date { ClockSkew.now(BoardClock.now()) }

    /// Default departure time: one hour from now, rounded to 5 minutes.
    static func defaultLeaveTime(now: Date = PlannerModel.trainTimeNow()) -> Date {
        leaveTime(in: 60, now: now)
    }

    /// Leaving in this many minutes, rounded up to 5 minutes (the departure time's quick choices: in 15, 30 or 60 min)
    static func leaveTime(in minutes: Double, now: Date = PlannerModel.trainTimeNow()) -> Date {
        let t = now.addingTimeInterval(minutes * 60).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 300).rounded(.up) * 300)
    }

    /// The Settings the results are computed with: the ranges come from the walk chosen here (walkMinutes)
    func walkSettings(_ transit: TransitModel) -> CatchSettings {
        transit.settings.walking(upTo: walkMinutes)
    }

    /// The walk the results cover, in seconds (the longer range), for the planner's own "no station within" sentence
    func walkSeconds(_ transit: TransitModel) -> TimeInterval {
        walkSettings(transit).extendedWalkSeconds
    }

    /// The departure time actually used: never earlier than now. A time left in the past (the window stayed open, or "Now"
    /// was tapped a while ago) would add the time already gone to every margin, or look for trains that have left.
    nonisolated static func effectiveLeave(_ leaveAt: Date, now: Date = PlannerModel.trainTimeNow()) -> Date { max(leaveAt, now) }

    /// Whether departures at this time come from realtime data: from now (a minute of leeway) to `realtimeHorizon` ahead
    nonisolated static func usesRealtime(leave: Date, now: Date = PlannerModel.trainTimeNow()) -> Bool {
        let ahead = leave.timeIntervalSince(now)
        return ahead >= -60 && ahead < realtimeHorizon
    }

    /// The regional bus operators among `codes` whose live times didn't download, by the names the UI uses. An operator-side
    /// outage like Bee-Line's is named only where its buses stop (as in the main window, see TransitModel.listsDownFeed).
    nonisolated static func failedBusOperators(_ codes: [String], routes: [String]) -> [String] {
        RegionalBusFeed.all.filter { codes.contains($0.code) && TransitModel.listsDownFeed(code: $0.code, routes: routes) }
            .map { $0.needsAccount ? "NJ Transit" : $0.name }
    }

    /// Entering the trip planner with no departure time chosen, or one already past: start again from the default (an hour from now)
    func refreshLeaveTimeIfPast(now: Date = PlannerModel.trainTimeNow()) {
        guard !leaveChosen || leaveAt < now.addingTimeInterval(-60) else { return }
        leaveChosen = false
        let time = Self.defaultLeaveTime(now: now)
        if time != leaveAt { leaveAt = time }
    }
}

extension PlannerModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let (results, nothing, fragment) = AddressSearch.results(of: completer)
        Task { @MainActor in
            // Only results for the text the field shows now: an edit, Clear, a pick or turning the network off since then makes them stale
            guard self.pickedText == nil, NetworkSwitch.isAllowed,
                  self.retry.isCurrent(fragment: fragment, query: self.query) else { return }
            // Nothing in the US for the text as typed: ask once more with a simpler one before saying so
            if results.isEmpty, let simpler = self.retry.next(after: fragment, query: self.query) {
                self.searchCompleter().queryFragment = simpler
                return
            }
            self.suggestions = self.retry.listed(results, text: AddressSearch.said)
            self.nothingFound = nothing
        }
    }

    /// Apple Maps couldn't search (it can't be reached, or found nothing at all): no suggestions, and for a long enough text the
    /// same sentence as for no place found
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let fragment = completer.queryFragment
        Task { @MainActor in
            self.suggestions = []
            guard self.pickedText == nil, NetworkSwitch.isAllowed,
                  self.retry.isCurrent(fragment: fragment, query: self.query) else { return }
            if let simpler = self.retry.next(after: fragment, query: self.query) {
                self.searchCompleter().queryFragment = simpler
                return
            }
            self.nothingFound = USAddress.saysNothingFound(kept: 0, found: 0, for: fragment)
        }
    }
}
