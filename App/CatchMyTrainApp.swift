import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// Starts the app: first works out this launch's appearance and language, while a new install has saved nothing yet
/// (TransitModel.isFirstLaunch), and saves this launch's layout direction (see TransitModel.applyLaunchLayoutDirection), before anything of
/// the app is created, so the window, sidebar, menus and SwiftUI lay out in the same direction from the first launch on.
@main
@MainActor
enum CatchMyTrainLaunch {
    static func main() {
        _ = TransitModel.launchAppearance
        TransitModel.applyLaunchLayoutDirection()
        // Before any data is read: the source list saved last time, and since when operators' problems have lasted
        SourceListStore.launch()
        CatchMyTrainApp.main()
    }
}

/// The app's scenes, started by CatchMyTrainLaunch: a main window, the transit map and Plan a Trip windows, a Settings window (⌘,),
/// and a menu bar icon.
///
/// After the main window is closed, the app keeps running in the menu bar (the Dock icon is hidden).
/// While "Start" is on it still updates data every 30 seconds and the desktop widget follows; in standby nothing is downloaded.
/// Left-clicking the menu bar icon opens a small panel (Start / Standby, change station, open window, quit);
/// right-clicking shows a plain menu: Start / Standby, Refresh, Open Main Window, Settings, Quit completely.
struct CatchMyTrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var transit = TransitModel()
    /// Plan a Trip's place, time and results: kept here, not in its window, so they stay when the window closes, until the app quits
    @StateObject private var planner = PlannerModel()

    var body: some Scene {
        Window("Catch My Train", id: MainWindow.id) {
            ContentView()
                .environmentObject(transit)
                // Make system controls (number fields, etc.) use the selected language's formatting too.
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                .frame(minWidth: 960, minHeight: 560)
                // Remember window position and size; move back onto the current screen after a display is unplugged
                .background(WindowSetup(autosaveName: "CatchMyTrainMainWindow", minSize: NSSize(width: 960, height: 560)))
                .onAppear {
                    transit.isWindowOpen = true
                    AppDelegate.mainWindowShown = true
                    MainWindow.showInDock()
                }
                .onDisappear {
                    transit.isWindowOpen = false
                    // While another window of the app is still open (map, Plan a Trip, Settings, location picker, How It Works),
                    // keep the Dock icon and the menu at the top of the screen
                    MainWindow.hideFromDockIfNoWindows()
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands { AppCommands(transit: transit) }

        // Transit map window (the sidebar item below "Plan a Trip", or the View menu): only one, its title and map follow the transit mode
        Window(StationSidebar.mapName(transit.system, transit.l10n), id: MapWindow.id) {
            MapWindowView()
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                .background(WindowSetup(autosaveName: "CatchMyTrainMapWindow", minSize: MapWindow.minSize))
                // Noted here, outside the .id above: a new Text size makes new contents (the old ones disappear, the new ones
                // appear), and noted inside them, the order of the two could leave the window marked closed while it is open
                .onAppear { transit.isMapWindowOpen = true }
                .onDisappear { transit.isMapWindowOpen = false }
        }
        .defaultSize(MapWindow.defaultSize)
        .windowResizability(.contentMinSize)
        // The View menu opens it, under the transit mode's name: the Window menu doesn't list it a second time
        .commandsRemoved()

        // Plan a Trip window (the sidebar's top item, or the View menu): only one
        Window(transit.l10n.t("Plan a Trip"), id: PlannerWindow.id) {
            PlannerWindowView(planner: planner)
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                // A new name for its saved frame: it opens once at the new, larger default size instead of the size saved before
                .background(WindowSetup(autosaveName: "CatchMyTrainPlannerV3", minSize: PlannerWindow.minSize))
                // The window closed: its search stops and its memory is freed. Here, outside the .id above, as for the map window: a
                // new Text size makes new contents, and the new ones appear before the old ones disappear, so stopping it as the old
                // contents disappear left the open window's search stopped ("Loading train times…" until it was closed and opened)
                .onDisappear { planner.release() }
        }
        .defaultSize(PlannerWindow.defaultSize)
        .windowResizability(.contentMinSize)
        // The View menu opens it: the Window menu doesn't list it a second time
        .commandsRemoved()

        Settings {
            // The column of pages is as wide as its longest name at the text size now, and the page beside it keeps its
            // smallest width: so the window's smallest width follows the language and the text size
            let minWidth = SettingsColumn.windowMinWidth(transit.l10n)
            SettingsView()
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                // Default 720×660; freely resizable, can shrink on small screens, each page scrolls
                .frame(minWidth: minWidth, idealWidth: max(minWidth, SettingsColumn.defaultSize.width), maxWidth: .infinity,
                       minHeight: SettingsColumn.windowMinHeight, idealHeight: SettingsColumn.defaultSize.height, maxHeight: .infinity)
                // macOS doesn't make SwiftUI's Settings window resizable, so we turn it on directly here. The frame is saved
                // under a name of its own: the one-page window before was narrower
                .background(WindowSetup(autosaveName: "CatchMyTrainSettingsV3",
                                        minSize: NSSize(width: minWidth, height: SettingsColumn.windowMinHeight)))
        }
        .defaultSize(SettingsColumn.defaultSize)
        .windowResizability(.contentMinSize)

        // Location picker window: two columns (the lists, and a map), freely movable and resizable, default 860×580
        Window(transit.l10n.t("Choose where to walk from"), id: PlacePickerWindow.id) {
            PlacePickerSheet()
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                // A new name for its saved frame: it opens once at the new, wider default size instead of the old narrow frame
                .background(WindowSetup(autosaveName: "CatchMyTrainPlacePickerV2", minSize: PlacePickerWindow.minSize))
                // Closing the window ends picking for Plan a Trip. Here, outside the .id above: new contents for a new Text size
                // must keep it, or a place chosen next would change the walking origin instead of going to Plan a Trip
                .onDisappear { transit.pickerForPlanner = false }
        }
        .defaultSize(PlacePickerWindow.defaultSize)
        .windowResizability(.contentMinSize)

        // Explainer window (Help → How It Works; the button at the bottom of Settings also opens it): portrait, resizable
        Window(transit.l10n.t("How It Works"), id: HowItWorksWindow.id) {
            HowItWorksView()
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                .background(WindowSetup(autosaveName: "CatchMyTrainHowItWorks", minSize: NSSize(width: 380, height: 320)))
        }
        .defaultSize(HowItWorksWindow.defaultSize)
        .windowResizability(.contentMinSize)

        // First-launch setup window: location, open at login and the widget; Settings → Privacy opens it again
        Window(transit.l10n.t("Ready to Go"), id: SetupWindow.id) {
            SetupView()
                .id(transit.textSize)
                .font(.scaled(.body))
                .environmentObject(transit)
                .environment(\.locale, transit.language.locale)
                .environment(\.layoutDirection, transit.layoutDirection)
                .background(WindowSetup(autosaveName: "CatchMyTrainSetup", minSize: NSSize(width: 460, height: 420)))
        }
        .defaultSize(width: 560, height: 680)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            StatusItemMenu.panelContent(transit)
        } label: {
            MenuBarLabel(active: transit.isActive, status: transit.l10n.activityStatus(transit.activity, now: Date()), transit: transit)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon: the app icon's train on its track (the same filled icon when started and in standby).
struct MenuBarLabel: View {
    var active: Bool
    /// Whether the app is on, as the Start switch's tooltip says it ("On until 4:37 PM", "Standby"), for screen readers
    var status: String
    /// Used by the right-click menu (the icon itself only looks at active)
    let transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            // The icon has no words of its own: its name for screen readers is whether the app is on ("Standby"). VoiceOver says the
            // app's name before it by itself ("Catch My Train Standby"): with the app's name in it too, it said the name twice.
            // The menu bar item takes only the name: whether it's on, given as the value, VoiceOver never said
            .accessibilityLabel(Text(status))
            .onAppear {
                // Let AppDelegate reopen the main window even when it is closed (e.g. opening the app again from Applications).
                MainWindow.reopen = { openWindow(id: MainWindow.id) }
                MainWindow.settings = {
                    NSApp.activate()
                    openSettings()
                }
                SetupWindow.openAction = { openWindow(id: SetupWindow.id) }
                // Right-click menu: opening the main window and Settings need SwiftUI actions, so hand them over from here.
                StatusItemMenu.shared.install(
                    model: transit,
                    openMain: { MainWindow.open(with: openWindow) },
                    openSettings: {
                        NSApp.activate()
                        openSettings()
                    })
            }
    }
}

/// When windows open or close, toggle the Dock icon: while any of this app's windows is open (main, map, Plan a Trip, Settings, location picker,
/// How It Works) behave like a normal app,
/// with a Dock icon, the menu at the top of the screen and ⌘Tab switching; once all are closed, keep only the menu bar icon.
enum MainWindow {
    static let id = "main"

    /// Opens the main window (set by the menu bar icon).
    @MainActor static var reopen: (() -> Void)?
    /// Opens Settings (set by the menu bar icon, for links from the widget).
    @MainActor static var settings: (() -> Void)?

    @MainActor static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// This app's own normal windows (with a title bar; not the menu bar icon or its small panel)
    @MainActor static func isAppWindow(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && !(w is NSPanel) && w.level == .normal
    }

    /// Hide the Dock icon only when no other window is open. `closing`: the window currently closing (it still counts as "visible" while closing).
    @MainActor static func hideFromDockIfNoWindows(closing: NSWindow? = nil) {
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && isAppWindow($0) }
        if !others, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    /// Open the main window from the menu bar and bring it to the front.
    @MainActor static func open(with openWindow: OpenWindowAction) {
        showInDock()
        openWindow(id: id)
        NSApp.activate()
    }
}

/// The transit map's own window (the sidebar item below "Plan a Trip", or the View menu). There's only one; it follows the transit mode.
/// Its scene ID must not start with another window's: windows are found by the start of their identifier (see AppDelegate)
enum MapWindow {
    static let id = "map"
    /// Content size: the default, and the smallest it can be made (the buttons at the top right of the map show only icons when narrow)
    static let defaultSize = CGSize(width: 900, height: 640)
    static let minSize = CGSize(width: 640, height: 480)

    /// Opens the map window, or brings it to the front; showingServiceArea: framing the whole service area (the empty page's
    /// "Service Area" button, for a place outside it)
    @MainActor static func open(with openWindow: OpenWindowAction, showingServiceArea: Bool = false) {
        if showingServiceArea { serviceAreaPending = true }
        MainWindow.showInDock()
        openWindow(id: id)
        NSApp.activate()
        if showingServiceArea { NotificationCenter.default.post(name: serviceAreaRequested, object: nil) }
    }

    /// The map was asked to show the whole service area, and hasn't yet: it waits here, as the window may only just be opening
    @MainActor static var serviceAreaPending = false
    static let serviceAreaRequested = Notification.Name("CatchMyTrainMapServiceArea")
}

/// The Plan a Trip window (the sidebar's top item, or the View menu). There's only one.
enum PlannerWindow {
    static let id = "planner"
    /// Content size: the default, wide enough for the map column beside the list (PlannerMapFrame), and the smallest it can be made
    /// (when narrow, the map column folds away, its controls take two or three rows and the directions' names go above their
    /// departures: PlannerView)
    static let defaultSize = CGSize(width: 1000, height: 660)
    static let minSize = CGSize(width: 600, height: 480)

    /// Opens the Plan a Trip window, or brings it to the front
    @MainActor static func open(with openWindow: OpenWindowAction) {
        MainWindow.showInDock()
        openWindow(id: id)
        NSApp.activate()
    }
}

/// UI animation. When "Reduce motion" is on in System Settings, don't animate (switch instantly).
enum Motion {
    static func ease(_ duration: Double) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: duration)
    }

    /// How the selection moves in the app's segmented switches (title bar modes, Walk from, directions, the segmented settings)
    static var segments: Animation? { ease(0.25) }

    /// How the new content comes in from the side after switching transit mode or direction (pushIn)
    static var push: Animation? { ease(0.3) }

    /// The brief light on a station card in the sidebar when "Show trains" in the map window selects it (StationListRow): on at
    /// once, then fading back, 0.4 s in all
    static func cardBounce(down: Bool) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: down ? 0.05 : 0.35)
    }

    /// A quick fade, slowing down at the end: the station page's own scroll bar under a long row of line badges (StationDetailView)
    static var fade: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)
    }
}

extension View {
    /// Marks one segment of the app's segmented switches with its value, so the switch's blue (segmentThumb) can take its place
    func segmentSlot<ID: Hashable>(_ id: ID, in space: Namespace.ID) -> some View {
        background(Color.clear.matchedGeometryEffect(id: id, in: space))
    }

    /// The blue of the app's segmented switches: one shape behind all segments that takes the frame of the selected one (segmentSlot),
    /// so when the selection changes it slides over as one piece (Motion.segments). Goes on the row of segments and animates the whole switch.
    /// Only its own selection animates it. A switch that comes in with new content under another animation (the direction switch on a new
    /// station page, after a click on a station card, "Show trains" in the map window, or another mode) shows its blue on the chosen
    /// segment from the start: under that animation the blue began as wide as the whole switch and shrank onto it.
    func segmentThumb<ID: Hashable>(_ selection: ID, in space: Namespace.ID, cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: selection, in: space, isSource: false)
        }
        .animation(Motion.segments, value: selection)
        // Outside the line above, so it acts first: drops whatever animation comes from around the switch
        .transaction { $0.animation = nil }
    }

    /// Content that a switch replaces (PushIn): `value` is what the switch chose, `order` its segment's position in the switch
    func pushIn<Value: Hashable>(_ value: Value, order: Int) -> some View {
        modifier(PushIn(value: value, order: order))
    }
}

/// When the switch's value changes, the new content comes in from the side of the newly chosen segment (the trailing side when it's after
/// the old one, so from the left in right-to-left languages), and the old content fades out where it is. Instant with "Reduce motion" (Motion.push).
struct PushIn<Value: Hashable>: ViewModifier {
    let value: Value
    let order: Int
    /// The order of the content on screen until this change is done: decides the side the new content comes from
    @State private var shownOrder: Int?

    func body(content: Content) -> some View {
        let edge: Edge = order >= (shownOrder ?? order) ? .trailing : .leading
        ZStack {
            content
                .id(value)
                .transition(.asymmetric(insertion: .move(edge: edge), removal: .opacity))
        }
        .clipped()
        .animation(Motion.push, value: value)
        .onChange(of: order, initial: true) { _, new in shownOrder = new }
    }
}

enum AppShortcuts {
    static func mode(_ m: TransitSystem) -> AppShortcut {
        switch m.mode {
        case .bus: return .bus
        case .train: return .train
        case .ferry: return .ferry
        default: return .subway
        }
    }

    @MainActor static func name(_ s: AppShortcut, _ transit: TransitModel) -> String {
        let l = transit.l10n
        switch s {
        case .subway: return l.modeName(.subway)
        case .bus: return l.modeName(.bus)
        case .train: return l.modeName(.train)
        case .ferry: return l.modeName(.ferry)
        case .nearby: return l.pick(transit.system, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"), ferry: l.t("Nearby piers"))
        case .planTrip: return l.t("Plan a Trip")
        case .map: return StationSidebar.mapName(transit.system, l)
        case .startStandby: return l.t("Start / Standby")
        case .refresh: return l.t("Refresh")
        case .choosePlace: return l.t("Choose a Place…")
        }
    }

    /// Key display: uppercase letters
    /// Shortcut text like "⌘1". Wrapped in left-to-right isolates (LRI…PDI) so right-to-left languages don't render it as "1⌘"
    static func display(_ key: String) -> String { "\u{2066}⌘" + key.uppercased() + "\u{2069}" }
}

/// Main window. Clicking the widget opens links like catchmytrain://nearby.
struct ContentView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        // Redraw everything when the text size changes (Font.scaled reads TextScale.factor)
        NearbyView()
            .id(transit.textSize)
            // Text without an explicit font (buttons, row labels in Settings, etc.) scales up too
            .font(.scaled(.body))
            .onAppear {
                // When opened automatically at login, don't show the window; just run in the menu bar.
                if AppDelegate.inLoginLaunchGrace {
                    AppDelegate.launchedAtLogin = false
                    dismissWindow(id: MainWindow.id)
                }
            }
            // Links from the widget are handled by AppDelegate.application(_:open:), also when this window is closed
    }
}

/// The map window's contents: the map of the transit mode in use, with the transit mode switch in the title bar (the same switch as
/// in the main window: the whole app changes mode). "Show trains" brings the main window to the front, opening it when it's closed,
/// with that station selected; the map window stays open.
struct MapWindowView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SubwayMapView(board: transit.board(at: BoardClock.now()), system: transit.system) { id in
            MainWindow.open(with: openWindow)
            withAnimation(Motion.ease(0.25)) { transit.showStationFromMap(id) }
        }
        // Another transit mode is drawn on the same map, in place, as Plan a Trip searches again in place (SubwayMapView.showMode).
        // Not a new map for each mode: a map view taken away isn't always let go of, and each stayed in memory
        .frame(minWidth: MapWindow.minSize.width, maxWidth: .infinity, minHeight: MapWindow.minSize.height, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SystemSwitcher()
            }
        }
        // Set here, not only on the scene (read once at launch), so the title follows the transit mode and the language
        .navigationTitle(StationSidebar.mapName(transit.system, transit.l10n))
        // Restored by the system at an automatic login launch: close again, like the main window (ContentView), and stay in the menu bar.
        // Whether the window is open is noted where the window is made (outside its .id)
        .onAppear {
            if AppDelegate.inLoginRestoreGrace { dismissWindow(id: MapWindow.id) }
        }
    }
}

/// The Plan a Trip window's contents, with the transit mode switch in the title bar (the same switch as in the main window).
/// Another transit mode searches again in place, without coming in from the side: what has been typed stays where it is.
struct PlannerWindowView: View {
    @EnvironmentObject var transit: TransitModel
    /// The app's planner (CatchMyTrainApp), so closing this window keeps what's in it
    let planner: PlannerModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        PlannerView(planner: planner)
            .frame(minWidth: PlannerWindow.minSize.width, maxWidth: .infinity,
                   minHeight: PlannerWindow.minSize.height, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SystemSwitcher()
                }
            }
            // Set here, not only on the scene (read once at launch), so the title follows a language change
            .navigationTitle(transit.l10n.t("Plan a Trip"))
            // Restored by the system at an automatic login launch: close again, like the main window (ContentView), and stay in the menu bar
            .onAppear {
                if AppDelegate.inLoginRestoreGrace { dismissWindow(id: PlannerWindow.id) }
            }
    }
}

extension AppAppearance {
    /// Make the whole app use this appearance: System follows the Mac's (its automatic light and dark too), Light and Dark stay so.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The system "About" window, with copyright, license (clickable) and data attribution added below: the operators of one metro
/// area (the start place's), with where every area's are.
enum AboutPanel {
    static let licenseURL = URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")!
    static let requiredNotice = "Required Notice: Copyright (c) 2026 CheeCar"

    @MainActor static func show(_ l: UIText, area: MetroArea) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        let text = NSMutableAttributedString(string: requiredNotice + "\n\n", attributes: base)
        var link = base
        link[.link] = licenseURL
        text.append(NSAttributedString(string: l.t("PolyForm Noncommercial License 1.0.0"), attributes: link))
        text.append(NSAttributedString(string: "\n\n" + l.t("Catch My Train is free and non-profit. You may use, copy and change it, but not for commercial purposes.")
                                       + "\n\n" + l.t("Transit data, route names and route symbols belong to their operators. Catch My Train isn't made or endorsed by any of them.")
                                       + "\n\n" + dataCredits(l, in: area),
                                       attributes: base))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text, .version: ""])
    }

    /// Who the data comes from, for About and How It Works' license section: what ships with the app, the services some of it
    /// comes through, and the operators in one metro area by name (the station footer's credits, ModeCoverage.credits(in:)).
    /// Every area's are in Settings' data source, so this stays as long as one area's list however many areas there are
    static func dataCredits(_ l: UIText, in area: MetroArea) -> String {
        l.f("The subway stations, subway map and MTA bus stops that come with the app are made from MTA open data; the stations without times come from public federal and Port Authority data. Everything else is downloaded from each operator's public data, some of it through %1$@. Operators in this area (%2$@): %3$@. Every area's operators are listed in Settings → Data source. This data belongs to those operators and is used under their terms.",
            l.joinedList(DataCredits.hosts), l.metroAreaName(area), l.commaList(ModeCoverage.credits(in: area)))
    }
}
