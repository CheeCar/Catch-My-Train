import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Help → How It Works and the button at the bottom of Settings: a separate explanation window (vertical, resizable, can be open alongside the Settings window).
enum HowItWorksWindow {
    static let id = "how-it-works"
    static let defaultSize = CGSize(width: 520, height: 680)

    @MainActor static func open(with openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate()
    }
}

/// Contents of the explanation window: how the app decides and where the data comes from.
/// The legend at the top of How It Works: what the icons and colors on a departure mean (the four verdicts, each with its icon and
/// color as on the station page, and the bar on the first one you can catch), the two walking ranges with the minutes set in
/// Settings, and the Timetable tag. Only in the app's window: the sections below are the text the tests check
private struct HowItWorksLegend: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        // The ranges as set (not extended for now)
        let s = transit.settings.sanitized()
        VStack(alignment: .leading, spacing: 8) {
            Text(l.t("What the icons and colors mean"))
                .font(.scaled(.headline))
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(CatchVerdict.allCases, id: \.self) { v in
                    GridRow {
                        v.line(l.verdict(v))
                            .fontWeight(.medium)
                            .foregroundStyle(v.color)
                            .fixedSize()
                            .accessibilityLabel(Text(l.verdict(v)))
                        meaning(l.verdictMeaning(v))
                    }
                }
                GridRow {
                    // The bar and light wash on the first one you can catch (FirstCatchableMark), on a blank strip
                    Color.clear
                        .frame(width: 44, height: 16)
                        .modifier(FirstCatchableMark(verdict: .canTry, inset: 0))
                        .accessibilityHidden(true)
                    meaning(l.t("A bar marks the first one in each direction you can catch."))
                }
                GridRow {
                    Image(systemName: "circle.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    meaning(l.f("Primary: %@ walk", l.minutes(s.primaryWalkSeconds)))
                }
                GridRow {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    meaning(l.f("Extended: %@ walk", l.minutes(s.extendedWalkSeconds)))
                }
                GridRow {
                    TimetableTag(l: l)
                    meaning(l.t("No live data for this one. The time is from the timetable."))
                }
            }
        }
        .padding(.top, 4)
    }

    private func meaning(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .gridColumnAlignment(.leading)
    }
}

struct HowItWorksView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let l = transit.l10n
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(l.t("How It Works"), systemImage: "info.circle")
                    .font(.scaled(.title2).bold())
                // First what a departure's icons and colors mean, then how it's all worked out
                HowItWorksLegend()
                ForEach(Self.sections(l, area: transit.sourcesArea), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.scaled(.headline))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.items, id: \.self) { text in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if section.bullets { Text("•").accessibilityHidden(true) }
                                Text(text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        // Settings' data source, at the same area: every area's sources are there
                        if section.dataSourceButton {
                            Button(l.t("Data Source…")) {
                                SettingsJump.toDataSource()
                                NSApp.activate()
                                openSettings()
                            }
                            .appButtonStyle()
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PageKeys())
        }
        // Set here, not only on the scene (read once at launch), so the window title follows a language change
        .navigationTitle(l.t("How It Works"))
    }

    /// Lets the page be read from the keyboard: it takes the keys when the window opens (with no focus ring: there's nothing to type
    /// into) and scrolls the page around it: Page Down / Page Up and Space / Shift-Space a page, Home / End to the top and the end,
    /// Down / Up arrow a little. Other keys go on as before. Placed in the page's background, so it finds the page's scroll view
    private struct PageKeys: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { KeysView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class KeysView: NSView {
            override var acceptsFirstResponder: Bool { true }
            override var focusRingType: NSFocusRingType {
                get { .none }
                set {}
            }
            // Never in the mouse's way: clicks reach the text as before
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                // Once the window is up, unless a text field has the keys
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, !(window.firstResponder is NSTextView) else { return }
                    window.makeFirstResponder(self)
                }
            }

            override func keyDown(with event: NSEvent) {
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let move = Self.move(for: event), let scrollView = enclosingScrollView else {
                    super.keyDown(with: event)
                    return
                }
                Self.scroll(scrollView, move)
            }

            private enum Move { case pages(CGFloat), lines(CGFloat), top, end }

            private static func move(for event: NSEvent) -> Move? {
                if let key = event.specialKey {
                    switch key {
                    case .pageDown: return .pages(1)
                    case .pageUp: return .pages(-1)
                    case .home: return .top
                    case .end: return .end
                    case .downArrow: return .lines(1)
                    case .upArrow: return .lines(-1)
                    default: return nil
                    }
                }
                guard event.charactersIgnoringModifiers == " " else { return nil }
                return .pages(event.modifierFlags.contains(.shift) ? -1 : 1)
            }

            /// How far a line goes, in points (about two lines of text)
            private static let line: CGFloat = 40

            private static func scroll(_ scrollView: NSScrollView, _ move: Move) {
                guard let page = scrollView.documentView else { return }
                let clip = scrollView.contentView
                let insets = clip.contentInsets
                // Where the visible part can start: from the top of the page (under the title bar) to its end. Down the page is up
                // the y axis in a flipped view (as SwiftUI's are) and down it otherwise
                let low = -(page.isFlipped ? insets.top : insets.bottom)
                let high = max(low, page.frame.height - clip.bounds.height + (page.isFlipped ? insets.bottom : insets.top))
                let down: CGFloat = page.isFlipped ? 1 : -1
                // A page keeps a line of the last one in view
                let pageStep = max(clip.bounds.height - insets.top - insets.bottom - line, line)
                var y = clip.bounds.origin.y
                switch move {
                case .pages(let n): y += down * n * pageStep
                case .lines(let n): y += down * n * line
                case .top: y = page.isFlipped ? low : high
                case .end: y = page.isFlipped ? high : low
                }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, low), high)))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    /// One section of the explanation: a title and a few paragraphs (bulleted in the data source sections). The area's section
    /// ends with a button to Settings' data source
    struct Section {
        let title: String
        let items: [String]
        var bullets = false
        var dataSourceButton = false
    }

    /// Explanation sections: first how catchability is decided, then where the data comes from in one metro area (the one Settings'
    /// data source opens at: the start place's), made from the data so that a new area changes no sentence, then problems with the
    /// sources, service area, widgets, the license and privacy.
    static func sections(_ l: UIText, area: MetroArea) -> [Section] {
        return [
            Section(title: l.t("How times are worked out"), items: [
                l.t("Walk time is the Apple Maps walking route from your starting point to the station, divided by your walking speed, plus time from the entrance to the platform: 1.5 min for the subway, PATH and light rail, 2 min for trains, 1 min for ferries, the tram and buses outside MTA, none at MTA bus stops, and 30 min for the Statue of Liberty ferry's security check. Without a route, the straight-line distance × 1.25 is used and marked “estimated”."),
                l.t("Spare time is when the train reaches the station minus when you reach the platform. With at least the safety buffer (more when the data is less certain), it says “Can try”. With less, it's “Tight”. If the train leaves before you get there, it's “Too soon” and the app shows the next one you can catch. Old or missing data shows “Not sure”."),
                l.t("On the NYC Subway, whether a train is express or local comes from the live data: its next stops are compared with the MTA timetable, and a train that skips stations other trains stop at is express."),
                l.t("Plan a Trip uses live data where available when you leave within the next 30 minutes, for the whole time range, and timetables only when you leave later. Its NJ Transit light rail and PATCO times always come from the timetable."),
                l.t("“Live” means the operator's real-time data. “Timetable” means the published schedule, used when an operator has no live data, or until you add the account it needs."),
                l.t("Leave-by reminders: the notification comes a few minutes (you choose how many) before the latest time to leave, and moves when the train's time changes."),
                l.t("Commute presets: each one switches your starting place and transit mode in one click. Make them in Settings → General."),
            ]),
            // The area by name, and where every area's sources are
            Section(title: l.metroAreaName(area), items: [
                l.t("Below are the sources in the area of your starting point (or the area nearest to it). Every area's sources are in Settings → Data source."),
            ], dataSourceButton: true),
        ] + TransitSystem.modes.map { sourcesSection($0, l, area: area) } + [
            // The keys and accounts this area's live times need, if any (the same as Settings shows for it)
            Section(title: l.t("Keys and accounts"), items: (AccountKey.needed(in: area).isEmpty
                ? [l.t("No key or account needed in this area.")]
                : [l.t("Some live times in this area need your own free key or account. Each one is kept only in this Mac's Keychain."),
                   l.t("They're free and each person uses their own; add them in Settings → Data source. Without one, times come from the timetable where the operator has one, marked “Timetable”.")]) + [
                l.t("If a data provider says the app is asking too often, Catch My Train stops asking it for a while (1 minute at first, longer if it happens again, up to 15 minutes, or as long as the provider says; this is remembered when the app is reopened), and the app, the menu bar and the widget say so. Until then, times come from the timetable or the last update."),
            ]),
            Section(title: l.t("When a data source can't be reached or has a problem"), items: [
                l.t("If a data server can't be reached, the app, the menu bar, Settings and the widget say which one and what was seen: this network can't find the server, the server isn't responding, a secure connection couldn't be made, or the server refuses the connection. If this Mac isn't connected to the internet at all, they say that instead."),
                l.t("The app can't tell for sure why a server can't be reached. When several fail at once while the internet works, your network may be blocking them, or they may refuse connections from certain countries, regions or networks. Try a different network or different connection settings. Until then, times come from the timetable or the last update."),
                // Problems on the provider's side
                l.t("Problems can also come from the operators themselves, for example when they move a server, change a web address or change their data format. The app tells you when a source's data is no longer at its usual address, when its server keeps returning errors, when its data can't be read, or when its live data has stopped updating. These aren't caused by your network. Until they're fixed, the app uses the timetable or the data it downloaded earlier, and keeps trying. If one doesn't clear up, an app update may be needed."),
                // The source list (see SourceList) and the 14-day notice
                l.t("Once a month the app also downloads a short list from this project's page on GitHub: where to download each operator's data, and the stations without times. A moved address can then be fixed without an app update. It sends nothing about you. If an operator's data still can't be downloaded after 14 days, the notice says since when and offers to check for a new version."),
            ]),
            // Each metro area and its regions, from areas.json, so adding an area changes no sentence
            Section(title: l.t("Service area"), items: [
                l.t("The app covers the metro areas below. The title bar shows which metro area and which part of it you're in, or says when you're outside them."),
            ] + MetroArea.allCases.map { area -> String in
                let regions = (AreaCatalog.shared.area(area.rawValue)?.regions ?? []).compactMap { MetroSubRegion(rawValue: $0.id) }
                return l.f("%1$@: %2$@.", l.metroAreaName(area), l.joinedList(regions.map(l.subRegionName)))
            } + [
                // Downloaded only where of use (DownloadArea)
                l.t("To keep downloads small, an area's timetables are downloaded only once your starting point, a favorite or a Plan a Trip place is in it. An area you haven't used for 30 days is removed (Settings → Data source → Downloaded data)."),
            ]),
            Section(title: l.t("Widget"), items: [
                l.t("The widget shows the same data as the app. While Catch My Train is in front, it updates with every refresh. When the app is in the background, it updates about every 5 minutes, and macOS may wait longer to save energy. When the app is quit, the widget can update only NYC Subway, Staten Island Railway and Roosevelt Island Tram times by itself (they're free and need no key); other times update when you open Catch My Train again, and the widget says so. The departure times on it are clock times, so they stay correct in between."),
            ]),
            // License (PolyForm Noncommercial)
            Section(title: l.t("License"), items: [
                l.t("Catch My Train is free and non-profit. It's licensed under the PolyForm Noncommercial License 1.0.0: you may use, copy and change it, but not for commercial purposes. The full terms are at polyformproject.org/licenses/noncommercial/1.0.0 and in the LICENSE file that comes with the source. Required Notice: Copyright (c) 2026 CheeCar."),
                l.t("Transit data, route names and route symbols belong to their operators. Catch My Train isn't made or endorsed by any of them."),
                // The area's operators by name, the same sentence as About (every area's are in Settings' data source)
                AboutPanel.dataCredits(l, in: area),
            ]),
            Section(title: l.t("Privacy"), items: [
                l.t("Your location is used to work out walk times. It's sent only to Apple Maps, for walking routes and place names, and to no one else, unless you choose Google Maps for Directions. The transit data downloads don't include your location, though MTA Bus Time does see which nearby bus stops the app asks about. Nearby stations and walking times are kept on this Mac so the widget can show them, and the places you choose are saved only on this Mac."),
                l.t("Transit times come from the operators and can be wrong, so allow extra time."),
            ]),
        ]
    }

    /// One mode's sources in a metro area: a line for each kind of times, made from the data (the same as the station footer's live
    /// data line, whatever keys the user has added: this says how it works, not how it stands now), the sentences of the operators
    /// there that do something differently (ModeCoverage.ownSentence), and how often this mode's data is checked. A mode the area
    /// has nothing of says so, as the sidebar does
    static func sourcesSection(_ mode: TransitSystem, _ l: UIText, area: MetroArea) -> Section {
        let title: String
        let checked: String
        switch mode.mode {
        case .subway:
            title = l.t("Subway sources")
            checked = l.t("Map and stations are checked for updates on the 1st of each month.")
        case .bus:
            title = l.t("Bus sources")
            checked = l.t("All bus timetables are free, downloaded on this Mac and checked for updates on the 1st of each month, and every day from a week before one runs out until a new one is out. They're kept as a compact copy and the app reads only the stops near the place you're looking at, so it stays light on memory.")
        case .train:
            title = l.t("Train sources")
            checked = l.t("All train timetables are downloaded on this Mac the first time you use trains and checked for updates on the 1st of each month, and every day from a week before one runs out until a new one is out.")
        default:
            title = l.t("Ferry sources")
            checked = l.f("All ferry timetables are downloaded on this Mac the first time you use ferries and checked for updates on the 1st of each month, and every day from a week before one runs out until a new one is out. Piers less than %@ apart are shown as one.",
                        l.distance(FerryFeed.samePierMeters))
        }
        let names = ModeCoverage.liveNames(for: mode, in: area)
        guard !names.isEmpty else { return Section(title: title, items: [l.t("No data for this transit system in this area yet.")], bullets: true) }
        let lines = ModeCoverage.LiveState.allCases.compactMap { state -> String? in
            let these = names.filter { $0.state == state }
            return these.isEmpty ? nil : l.liveDataLine(these)
        }
        let own = ModeCoverage.ownSentences(for: mode, in: area).compactMap { ownSentence($0, l) }
        return Section(title: title, items: lines + own + [checked], bullets: true)
    }

    /// The operators in ModeCoverage.ownSentence without a sentence below (AppTests checks there are none: one added there needs
    /// its sentence here too, or How It Works would leave it out)
    static var withoutOwnSentence: [String] {
        let l = UIText(language: .english)
        return ModeCoverage.ownSentence.filter { ownSentence($0, l) == nil }
    }

    /// The sentence of an operator that does something differently from the rest (ModeCoverage.ownSentence), shown only in the
    /// areas it runs in; nil for any other operator
    static func ownSentence(_ id: String, _ l: UIText) -> String? {
        switch id {
        case ModeCoverage.subwayID:
            return l.t("MTA subway and Staten Island Railway: live times from MTA's official real-time feeds (free, no key). The app downloads only the lines that stop near you, at the refresh interval you set. Stations, directions, the map and timetables come from MTA's GTFS data, built into the app and checked for updates on the 1st of each month.")
        case FerryFeed.Source.path.rawValue:
            return l.t("PATH (Port Authority of New York and New Jersey): live times from the data used by the official PATH app (free, no key). It gives the next few trains at each station, so only those are shown, and Plan a Trip works only for the next 30 minutes. PATH publishes no current timetable, so stations, lines and the map come from its last public timetable, downloaded on this Mac and checked for updates on the 1st of each month.")
        case ModeCoverage.tramID:
            return l.t("Roosevelt Island Tram (RIOC): RIOC publishes no live data or exact timetable, only its hours and how often it runs (every 7.5 min at weekday rush hours, every 15 min otherwise). The app works out departures from these, so tram times are estimates marked “Timetable”. The hours are checked on the 1st of each month.")
        case ModeCoverage.mtaBusID:
            return l.t("MTA buses: live times from MTA Bus Time (free, needs your own key, entered in Settings and kept in this Mac's Keychain). The app asks only about the bus stops nearest you (up to 24), a few at a time and at most once a minute. Stops and the map come from MTA's GTFS data, built into the app and checked for updates on the 1st of each month. Bus types follow MTA: Local, Limited-Stop, Select Bus Service (SBS) and Express.")
        case MetroArea.busOperatorID("SCT"):
            return l.t("Suffolk County Transit: timetables, free. Live times with your own free key from Swiftly, which runs Suffolk's live data; you ask for it with Swiftly's request form, and Swiftly reviews each request.")
        case FerryFeed.Source.marc.rawValue:
            return l.t("MARC (Maryland): timetables and live times, free, no key. Only its Perryville station is in the area.")
        case FerryFeed.Source.capeMayLewes.rawValue:
            return l.t("Cape May–Lewes Ferry: timetable only. Only its Cape May terminal is in the area.")
        case FerryFeed.Source.statueOfLiberty.rawValue:
            return l.t("Statue of Liberty ferry (National Park Service): timetable only, published one season at a time. Between seasons its piers are hidden.")
        default:
            return nil
        }
    }
}
