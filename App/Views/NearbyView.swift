import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// The one clock for everything that shows countdowns from the board (the sidebar, the station page, the menu bar panel): every
/// 15 seconds, on the quarter minutes, so all of them work the board out at the same moment and show the same minutes.
enum BoardClock {
    static var schedule: PeriodicTimelineSchedule { .periodic(from: Timetable.minuteStart(Date()), by: 15) }

    /// The moment the app's times are shown and worked out from: `real` (by default the clock's)
    static func now(_ real: Date = Date()) -> Date {
        return real
    }

}

/// Main window (switching modeled on the official MTA app):
/// On the left, nearby stations, with connected in-station stations merged into one (e.g. "42 St-Bryant Pk / 5 Av"), sorted by walk time;
/// on the right, trips for the selected station: filter by route at the top, switch directions with a segmented control, both directions side by side by default.
/// Each row's most prominent item is when the train arrives; below it in small text: how long it takes to walk there from your location and whether you can catch it.
struct NearbyView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @State private var showPlacePicker = false
    /// Direction: both / northbound only (N) / southbound only (S). Kept when changing stations; also kept after closing the window or relaunching the app.
    @AppStorage("mainDirectionMode") private var directionMode: DirectionMode = .both

    var body: some View {
        let l = transit.l10n
        // Recompute from existing data every 15 seconds so countdowns and evaluations change over time (without re-downloading).
        // Every 5 seconds would lay out the whole window again each time, about 3% CPU even when idle.
        // Countdowns are only minute-accurate and data refreshes every 30 seconds (redrawn right away when new data arrives), so 15 seconds is enough.
        // The right side always shows the station page (or standby): the map and Plan a Trip open in their own windows (MapWindowView, PlannerWindowView)
        let modeOrder = TransitSystem.modes.firstIndex(of: transit.system) ?? 0
        NavigationSplitView {
            TimelineView(BoardClock.schedule) { context in
                StationSidebar(board: transit.board(at: BoardClock.now(context.date)), showPlacePicker: $showPlacePicker)
            }
            // After switching transit mode the list fades in quickly (not with "Reduce motion"). It isn't pushed in like the right side:
            // the list is an AppKit table, which doesn't slide smoothly and would scroll back to the top
            .phaseAnimator(Motion.ease(0.2) == nil ? [true] : [true, false], trigger: transit.system) { list, shown in
                list.opacity(shown ? 1 : 0.3)
            } animation: { shown in
                shown ? Motion.ease(0.2) : nil
            }
            .navigationSplitViewColumnWidth(min: StationSidebar.minWidth, ideal: 260, max: 360)
        } detail: {
            ZStack {
                TimelineView(BoardClock.schedule) { context in
                    let board = transit.board(at: BoardClock.now(context.date))
                    ZStack {
                        if !transit.isActive || transit.waitsForSetup {
                            StandbyView()
                                .transition(.opacity)
                        } else if let station = transit.selection.station(in: board) {
                            StationDetail(stationID: station.id, now: BoardClock.now(context.date), directionMode: $directionMode)
                                // "Directions" in each departure's details, whose rows don't watch the main model
                                .environment(\.directions, transit.directionsAction)
                                .environment(\.walkRoutesComing, transit.routesAsked)
                                .id(station.id)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)),
                                                        removal: .opacity))
                        } else {
                            EmptyBoardView(now: BoardClock.now(context.date))
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                // After switching transit mode, the new mode's page comes in from the side of its button
                .pushIn(transit.system, order: modeOrder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            // Title CatchMyTrain on the left; on the right first the current place and the transit mode switch, then how many reminders
            // are set (only while there are some), refresh, toggle, settings.
            // Split into blocks, each with its own border; the place text has a fixed width and shrinks or truncates when too long, so the settings button and toggle aren't pushed into the "»" menu
            // The place block is left out while it has nothing to say (see AreaLabel.hasText): an empty box looked like something was missing
            if AreaLabel.hasText(transit) {
                ToolbarItem(placement: .primaryAction) {
                    AreaLabel()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SystemSwitcher()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // In this group rather than an item of its own: with no reminders it is nothing, and an item of its own would leave an
                // empty box (it watches the reminders, which this view doesn't)
                ReminderCountButton(reminders: transit.reminders, l: l) { transit.showReminderStation($0) }
                // While times or walks are loading, the button's arrow turns into a spinner in the same place: a spinner of its own
                // beside it made the toolbar wider while loading, and with larger text in a narrower window that pushed the
                // settings button out
                Button {
                    transit.refresh()
                } label: {
                    Label {
                        Text(l.t("Refresh"))
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                            .opacity(transit.isRefreshing || transit.isRouting ? 0 : 1)
                            .overlay {
                                if transit.isRefreshing || transit.isRouting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .help(transit.isActive ? l.t("Get the latest times now") : l.t("Turn on Catch My Train to refresh"))
                .disabled(!transit.isActive)
                ActivitySwitch()
                SettingsLink {
                    Label(l.t("Settings"), systemImage: "gearshape")
                }
                .help(l.t("Open Settings: refresh, walking, keys, data sources and more"))
            }
        }
        // Choose place: a real window that can be moved and resized freely. This only opens it.
        .onChange(of: showPlacePicker) { _, show in
            guard show else { return }
            showPlacePicker = false
            PlacePickerWindow.open(with: openWindow, transit: transit)
        }
        .onAppear {
            handleMenuRequest()
            askForPlaceIfNeeded()
        }
        .onChange(of: transit.menuRequest) { _, _ in handleMenuRequest() }
    }

    /// Asked once per launch (askForPlaceIfNeeded)
    private static var askedForPlace = false

    /// Opened with "A place I choose" and no place ever chosen: the place picker opens by itself, once per launch
    /// (closing it without a place leaves the empty page, whose button opens it again)
    private func askForPlaceIfNeeded() {
        guard !Self.askedForPlace, transit.opensPickerForPlace else { return }
        Self.askedForPlace = true
        showPlacePicker = true
    }

    /// Chosen from the menu bar at the top of the screen: open the place picker.
    private func handleMenuRequest() {
        guard let request = transit.menuRequest else { return }
        transit.menuRequest = nil
        switch request {
        case .choosePlace:
            // Only open the window; switch to "A place I choose" once a place is actually chosen, and Cancel leaves things as they were
            // (in Demo mode too: its own places, in Manhattan)
            showPlacePicker = true
        }
    }
}

enum DirectionMode: String, Hashable {
    case both, north, south

    /// Position in the direction switch (DirectionSwitcher)
    var order: Int {
        switch self {
        case .both: return 0
        case .north: return 1
        case .south: return 2
        }
    }

    /// Whether the station page shows the other direction under this chosen one: when the chosen one has no departures and the
    /// other has some, so the choice (one for every station) never hides the departures a station has. With both shown, never
    func showsOtherDirection(chosenIsEmpty: Bool, otherIsEmpty: Bool) -> Bool {
        self != .both && chosenIsEmpty && !otherIsEmpty
    }
}
