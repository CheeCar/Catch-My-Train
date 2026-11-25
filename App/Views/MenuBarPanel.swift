import AppKit
import CatchText
import SwiftUI
import TransitCore

/// The small panel that pops up from the menu bar icon: Start / Standby switch, the next few trains in both directions at the selected station,
/// ‹ › and the station's name (a menu of the nearby stations) to change stations, the mode line (a menu of the modes) with the commute
/// presets under it (PresetButtons), and at the bottom a row of buttons for the main window, Plan a Trip, the map, Refresh, Settings
/// and More (PanelBottomBar).
struct MenuBarPanel: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    /// The panel's width: 400 points at the standard text size, wider in step with larger text, so the direction titles keep to
    /// their two lines, the route badges keep their "+N" and the name stays beside the time
    static func width(for size: AppTextSize) -> CGFloat { (400 * size.factor).rounded() }

    /// The room around the panel's content, inside its edge
    static let padding: CGFloat = 14

    /// Top row: icon, name, how many reminders are set (only while there are some), current time (with its zone) and the
    /// Start / Standby switch
    private func header(showsName: Bool) -> some View {
        HStack(spacing: 8) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .accessibilityHidden(true)
            if showsName {
                Text("Catch My Train").font(.scaled(.headline)).fixedSize()
            }
            Spacer()
            ReminderCountButton(reminders: transit.reminders, l: transit.l10n) { reminder in
                dismiss()
                transit.showReminderStation(reminder)
                MainWindow.open(with: openWindow)
            }
            CurrentTimeLabel(font: .scaled(.callout).weight(.semibold).monospacedDigit())
            ActivitySwitch()
        }
    }

    var body: some View {
        let l = transit.l10n
        VStack(alignment: .leading, spacing: 10) {
            // With larger text and a long time (12-hour clock and zone), the name gives way rather than wrapping;
            // the time and the switch always show whole
            ViewThatFits(in: .horizontal) {
                header(showsName: true)
                header(showsName: false)
            }
            // Current transit mode and region, a menu of the modes (explained in orange when outside the service area)
            HStack(spacing: 5) {
                PanelModeMenu(l: l)
                if transit.isOutsideArea {
                    Text("· " + l.t("Outside the service area")).foregroundStyle(Color.noticeOrange)
                }
            }
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // The commute presets under it, only while there are some (the same buttons as in the main window's sidebar)
            PresetButtons(presets: transit.presetCenter)
            // Taller when it doesn't fit on one line, as the other notes here
            TimeZoneNoteLine().fixedSize(horizontal: false, vertical: true)

            Divider()

            if transit.isActive {
                // While the panel is open, recompute countdowns every 15 seconds (no re-download; same as the main window, see NearbyView).
                // Departures only: the stations without times are left out, as on the widgets
                TimelineView(BoardClock.schedule) { context in
                    MenuBarBoard(board: transit.board(at: BoardClock.now(context.date), maxTrainsPerDirection: 30).withoutNoTimesStations(),
                                 now: BoardClock.now(context.date))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // A new install before its setup window is finished says so (as the main window does)
                    Text(transit.waitsForSetup ? l.t("Finish the setup window to see departures.")
                         : l.t("Nothing is refreshed or downloaded on standby."))
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                    Button {
                        transit.start()
                    } label: {
                        Label(l.t("Start"), systemImage: "play.fill")
                    }
                    .appButtonStyle(.prominent)
                }
            }

            // When a new version is available (same as the main window sidebar and Settings)
            if transit.availableUpdate != nil {
                UpdateAvailableLink()
            }

            Divider()

            PanelBottomBar()
        }
        .padding(Self.padding)
        .frame(width: Self.width(for: transit.textSize))
    }
}

/// Departures in the panel: the selected station, with the two directions in left and right columns.
struct MenuBarBoard: View {
    @EnvironmentObject var transit: TransitModel
    /// Closes the panel before a Settings… button opens Settings
    @Environment(\.dismiss) private var dismiss
    var board: NearbyBoard
    var now: Date
    /// The two directions side by side: the natural height of each title, the taller of the two (PairHeights, as on the station page)
    @State private var pairHeights: [String: CGFloat] = [:]

    var body: some View {
        let l = transit.l10n
        if let station = transit.selection.station(in: board) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        transit.moveStation(by: -1, in: board)
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(Text(l.t("Previous station")))
                    .disabled(board.stations.count < 2)
                    VStack(alignment: .leading, spacing: 2) {
                        PanelStationMenu(station: station, board: board, l: l)
                        HStack(spacing: 6) {
                            RouteBullets(routes: station.routes, size: 14, limit: 8)
                            Text(l.f("%@ walk", l.minutes(station.walk.walkSeconds)))
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                        }
                        // Say so when the walking time isn't from the current location.
                        if let o = transit.origin, o.kind == .manualFallback {
                            Text(l.f("Location unavailable. Walking from %@", o.name))
                                .font(.scaled(.caption2)).foregroundStyle(Color.noticeOrange).lineLimit(1)
                        } else if let o = transit.origin, o.kind == .manual || o.kind == .demoCurrent {
                            Text(l.f("Walking from %@", o.name))
                                .font(.scaled(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        transit.moveStation(by: 1, in: board)
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .accessibilityLabel(Text(l.t("Next station")))
                    .disabled(board.stations.count < 2)
                }
                .buttonStyle(.borderless)

                // A bus stop on only one side of the street has only one direction. With both, the two titles are as tall as
                // each other, so the trains of both columns start on the same line when one title takes two lines (PairedHeight)
                let hasNorth = transit.hasDirection(station.north, in: station)
                let hasSouth = transit.hasDirection(station.south, in: station)
                let paired = hasNorth && hasSouth ? pairHeights : nil
                HStack(alignment: .top, spacing: 12) {
                    if hasNorth {
                        MenuBarDirection(direction: station.north, station: station, l: l, pairHeights: paired)
                    }
                    if hasSouth {
                        MenuBarDirection(direction: station.south, station: station, l: l, pairHeights: paired)
                    }
                }
                .onPreferenceChange(PairHeights.self) { h in
                    if PairHeights.differs(h, pairHeights) { pairHeights = h }
                }

                DataFreshnessLine(now: now, station: station)
                // Each notice below wraps onto as many lines as it needs: never cut off in the middle of a sentence
                // Mention each cause only once: when rate-limited, only mention the rate limit (same as the main window).
                // Only the notices about this station's providers; with none, the station's own notice shows
                let limits = transit.rateLimits(at: station)
                let reach = transit.reachNotices(at: station)
                if !limits.isEmpty || !reach.isEmpty {
                    ForEach(limits, id: \.provider) { n in
                        Label(transit.rateLimitShortText(n), systemImage: "hourglass")
                            .font(.scaled(.caption2)).foregroundStyle(Color.noticeOrange).fixedSize(horizontal: false, vertical: true)
                    }
                    // Can't connect (maybe a network restriction): combine several providers into one sentence, otherwise one per line (same as the main window)
                    if let summary = transit.l10n.reachShortSummary(reach) {
                        Label(summary, systemImage: "wifi.exclamationmark")
                            .font(.scaled(.caption2)).foregroundStyle(Color.noticeOrange).fixedSize(horizontal: false, vertical: true)
                    }
                    // Problems on the provider's side, one provider per line
                    ForEach(transit.l10n.reachSeparate(reach), id: \.self) { n in
                        Label(transit.l10n.reachShortText(n), systemImage: transit.l10n.reachSymbol(n))
                            .font(.scaled(.caption2)).foregroundStyle(Color.noticeOrange).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let err = transit.notice(for: station) {
                    Text(err).font(.scaled(.caption2)).foregroundStyle(Color.noticeRed).fixedSize(horizontal: false, vertical: true)
                }
                if transit.needsBusKey(at: station) {
                    if transit.busKeyUnreadable {
                        // The key may well still be saved: offer to read it again, not to add one
                        KeychainRetryLine(credential: .busTime)
                            .font(.scaled(.caption2))
                    } else {
                        Text(l.t("Add your free MTA Bus Time key in Settings to see live bus times."))
                            .font(.scaled(.caption2)).foregroundStyle(Color.noticeOrange).fixedSize(horizontal: false, vertical: true)
                        OpenSettingsButton(l: l, target: .keys) { dismiss() }
                    }
                }
                if transit.isScheduleOnly(station), let note = transit.scheduleOnlyNote(station) {
                    Text(note)
                        .font(.scaled(.caption2)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // A note about a key or account: the button opens Settings at Keys and accounts
                    if transit.scheduleOnlyNoteAsksForKey(station) {
                        OpenSettingsButton(l: l, target: .keys) { dismiss() }
                    }
                }
                // Timetable data that couldn't be downloaded, at any station (same as the main window's footer): no station on the
                // board comes from that data (with the PATH data missing, a PATH stop isn't there to note it at)
                if let note = transit.missingTimetableNote(short: true) {
                    Text(note).font(.scaled(.caption2)).foregroundStyle(Color.noticeRed).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if transit.isLocating {
                    Text(l.t("Finding your location…"))
                } else {
                    // Same explanations as the main window (see TransitModel.emptyStateText), an operator's problem in its short form
                    Text(transit.emptyStateText(short: true))
                }
            }
            .font(.scaled(.callout))
            .foregroundStyle(.secondary)
        }
    }
}

/// A menu's button in the panel: its words and a small ⌄, with a light background under the pointer only (the panel stays as it
/// was; the name and the mode line keep their place)
private struct PanelMenuLabel<Content: View>: View {
    var hovering: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
            Image(systemName: "chevron.down")
                .font(.scaled(.caption2).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .padding(.horizontal, -4)
        .padding(.vertical, -1)
    }
}

/// The station's name in the panel. With more than one station, a menu of the stations ‹ › go through (nearest first, each with its
/// walk, the extended range's marked), the one shown ticked: picking one selects it as clicking its card in the main window does
private struct PanelStationMenu: View {
    @EnvironmentObject var transit: TransitModel
    var station: BoardStation
    var board: NearbyBoard
    var l: UIText
    @State private var hovering = false

    var body: some View {
        if board.stations.count > 1 {
            let title = l.pick(transit.system, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"), ferry: l.t("Nearby piers"))
            Menu {
                Text(title)
                // One switch per station, the current one on: the menu's own check mark (a check mark image in a Label isn't
                // drawn in Mac menus), and screen readers say which one is chosen. Choosing the current one again does the same as before
                ForEach(board.stations) { s in
                    Toggle(s.menuText(l), isOn: .afterViewUpdate(get: { s.id == station.id }, set: { _ in transit.selectStation(s.id) }))
                }
            } label: {
                PanelMenuLabel(hovering: hovering) {
                    name
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hovering = $0 }
            .help(title)
            .accessibilityLabel(Text(station.name))
            .accessibilityHint(Text(title))
        } else {
            name
        }
    }

    private var name: some View {
        Text(station.name).font(.scaled(.subheadline).bold()).lineLimit(1)
    }
}

extension BoardStation {
    /// A nearby station in a menu: "Times Sq-42 St · 4 min walk", and "· Extended range" for one in the extended range (the menu bar
    /// panel's station menu and the transit map's Nearby stations)
    func menuText(_ l: UIText) -> String {
        l.dotted([name, l.f("%@ walk", l.minutes(walk.walkSeconds))] + (range == .extended ? [l.t("Extended range")] : []))
    }
}

/// The mode and metro area line in the panel: a menu of the four modes, the one in use ticked (the same switch as the row of mode
/// buttons in the main window)
private struct PanelModeMenu: View {
    @EnvironmentObject var transit: TransitModel
    var l: UIText
    @State private var hovering = false

    var body: some View {
        let line = l.dotted([SystemSwitcher.name(transit.system, l), transit.areaName].compactMap { $0 })
        Menu {
            Text(l.t("Transit system"))
            // The menu's own check mark on the mode in use, as in the station menu
            ForEach(TransitSystem.modes) { sys in
                Toggle(l.modeName(sys), isOn: .afterViewUpdate(get: { sys == transit.system }, set: { _ in transit.system = sys }))
            }
        } label: {
            PanelMenuLabel(hovering: hovering) {
                HStack(spacing: 5) {
                    Image(systemName: transit.system.symbol)
                        .accessibilityHidden(true)
                    Text(line)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .help(l.t("Transit system"))
        .accessibilityLabel(Text(line))
        .accessibilityHint(Text(l.t("Transit system")))
    }
}

/// One direction in the panel: title and the next few trains.
struct MenuBarDirection: View {
    @EnvironmentObject var transit: TransitModel
    var direction: BoardDirection
    var station: BoardStation
    var l: UIText
    /// Side by side with the other direction: the title height to line up with (nil when it stands alone)
    var pairHeights: [String: CGFloat]? = nil

    /// Shows 3 trains: of the uncatchable ones ("Too soon") keep only the last, followed by ones worth trying.
    private var rows: [BoardTrain] {
        let trains = direction.trains
        guard let firstUseful = trains.firstIndex(where: { $0.verdict != .takeNext }) else {
            return Array(trains.prefix(3))
        }
        return Array(trains[max(0, firstUseful - 1)...].prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let title = transit.directionTitle(direction, in: station)
            Text(title)
                .font(.scaled(.caption).bold())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                // Its own height, as on the station page: a long title takes its second line instead of being cut to one
                .fixedSize(horizontal: false, vertical: true)
                .help(title)
                .accessibilityAddTraits(.isHeader)
                .modifier(PairedHeight(key: "title", heights: pairHeights))
            if direction.trains.isEmpty {
                Text(transit.isRefreshing && transit.arrivals.isEmpty
                     ? l.pick(transit.system, train: l.t("Loading train times…"), bus: l.t("Loading bus times…"), ferry: l.t("Loading ferry times…"))
                     : l.noArrivals(transit.system, within: transit.effectiveSettings.sanitized().arrivalWindowSeconds,
                                    next: direction.next))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            let first = direction.firstCatchable?.id
            ForEach(rows) { train in
                let e = train.evaluation
                HStack(alignment: .top, spacing: 6) {
                    RouteBadge(route: train.route, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(l.arrivalTime(e))
                                .font(.scaled(.headline).monospacedDigit())
                                .lineLimit(1)
                                .foregroundStyle(e.verdict == .takeNext ? Color.secondary : Color.primary)
                                .layoutPriority(2)
                            // How soon, right after the time as in the main window. Where the column is too narrow for it (a
                            // language with long words, larger text), its short form ("6 min", "Now"); left out only when even
                            // that doesn't fit
                            ViewThatFits(in: .horizontal) {
                                Text(l.countdown(e.secondsUntilTrain))
                                    .font(.scaled(.caption).monospacedDigit())
                                    .lineLimit(1)
                                Text(l.shortCountdown(e.secondsUntilTrain) ?? "")
                                    .font(.scaled(.caption).monospacedDigit())
                                    .lineLimit(1)
                                Color.clear.frame(width: 0, height: 0)
                            }
                            // Same mark as the widget: the time comes from the timetable
                            if e.arrival.isTimetableTime {
                                Image(systemName: "calendar")
                                    .font(.scaled(.caption2).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(Text(l.t("Timetable")))
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            e.verdict.line(l.shortCatchLine(e))
                            e.verdict.line(l.tinyCatchLine(e))
                        }
                        .font(.scaled(.caption).weight(.medium))
                        .foregroundStyle(e.verdict.color)
                        .lineLimit(1)
                    }
                }
                .padding(.leading, 6)
                .padding(.vertical, 2)
                .modifier(FirstCatchableMark(verdict: train.id == first ? train.verdict : nil, inset: 2))
                // Read as one sentence, as in the main window (AppText.spokenDeparture)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(l.spokenDeparture(train, station: train.station.name != station.name ? train.station.name : nil)))
                // Same as the main window: uncatchable ones only gray out the time; the line bullet color stays
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // One group per direction, as in the main window
        .accessibilityElement(children: .contain)
    }
}

/// When the data was updated (the MTA data's own time, not when the UI redrew); marked when stale.
struct DataFreshnessLine: View {
    @EnvironmentObject var transit: TransitModel
    var now: Date
    /// The station shown: whose live data it is says only its departures (LiveSource)
    var station: BoardStation?

    var body: some View {
        let l = transit.l10n
        // Same as the widget: for ferries, say whose realtime data it is, or Timetable
        let source = l.liveSource(transit.system, arrivals: transit.arrivals, station: station)
        HStack(spacing: 4) {
            // The icons say what the words beside them say: not read by screen readers
            if transit.isStale(now: now) {
                Image(systemName: "exclamationmark.arrow.circlepath").accessibilityHidden(true)
                Text(l.t("Stale"))
            } else if transit.isDemo {
                // Demo mode (all four transit modes use made-up departures)
                Image(systemName: "theatermasks").accessibilityHidden(true)
                Text(l.t("Demo data only"))
            } else {
                Image(systemName: source.symbol).accessibilityHidden(true)
                Text(source.text)
            }
            if let t = transit.shownDataTime {
                // Only there to set the two apart on screen: VoiceOver read it as an item of its own
                Text("·").accessibilityHidden(true)
                Text(l.f("Updated %@", l.timeWithSeconds(t)))
            }
            if transit.isRefreshing { ProgressView().controlSize(.mini) }
        }
        .font(.scaled(.caption2))
        .foregroundStyle(transit.isStale(now: now) ? Color.noticeOrange : Color.secondary)
        .lineLimit(1)
    }
}

/// Right-click menu for the menu bar icon (basic actions,
/// such as opening the main window and quitting fully). Left click still opens the panel above.
///
/// SwiftUI's MenuBarExtra has no right-click menu, so this app watches for right clicks on its own menu bar icon
/// (or Control-clicks) and pops up a regular menu below the icon. Other apps' menu bar icons are unaffected.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()

    private var monitor: Any?
    private weak var model: TransitModel?
    private var openMain: (() -> Void)?
    private var openSettings: (() -> Void)?

    func install(model: TransitModel, openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        self.openSettings = openSettings
        acceptPresses()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // Only handle right / Control clicks on the menu bar icon; let other clicks through unchanged
            let handled = MainActor.assumeIsolated { StatusItemMenu.shared.handle(event) }
            return handled ? nil : event
        }
    }

    /// The icon's button that got the press below (set once per button)
    private weak var pressButton: NSButton?

    /// Lets screen readers open the panel. SwiftUI's MenuBarExtra opens it on the mouse alone: the icon's button has no action,
    /// so VoiceOver's press (VO-Space) did nothing, while VO-Shift-Space, a click, worked; a click made inside the app doesn't
    /// open it either. The button gets an action that, for a press that isn't a click, shows the same panel in a small window
    /// under the icon. The icon comes a moment after this is first called: look again a few times.
    private func acceptPresses(tries: Int = 10) {
        guard let window = NSApp.windows.first(where: { Self.isStatusBarWindow($0) }),
              let button = window.contentView.flatMap({ Self.button(in: $0) }) else {
            guard tries > 1 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.acceptPresses(tries: tries - 1)
            }
            return
        }
        // An action of SwiftUI's own is left alone: then a press already goes where a click goes
        guard button !== pressButton, button.action == nil else { return }
        button.target = self
        button.action = #selector(pressed(_:))
        pressButton = button
    }

    /// The icon's button was pressed. By a click (the event being handled is a mouse event on the icon, just now), SwiftUI has
    /// opened or closed the panel already: nothing more. By anything else (VoiceOver, Switch Control, a press in code), show the
    /// panel in its window, or close that window when it's open.
    @objc private func pressed(_ sender: NSButton) {
        if let event = NSApp.currentEvent, event.window === sender.window,
           ProcessInfo.processInfo.systemUptime - event.timestamp < 1 {
            return
        }
        AppLog.ui.notice("menu bar icon pressed without a click: panel in a window")
        // After the press has finished, not inside it
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            self.togglePanelWindow(below: sender)
        }
    }

    /// The panel's window for presses that aren't clicks (one at a time)
    private var panelWindow: PanelWindow?

    /// Shows the panel in a small window right under the icon and gives it the keyboard (so a screen reader goes into it), or
    /// closes it when it is already showing. Like the menu bar's panel, it closes as soon as another window takes the keyboard.
    /// The window takes the keyboard without bringing the app to the front: another app may be in front, and it doesn't have to
    /// let this one come forward for a press made with a screen reader (then the keys went on to that app).
    private func togglePanelWindow(below button: NSButton) {
        if let open = panelWindow, open.isVisible {
            open.close()
            return
        }
        guard let model else { return }
        let host = NSHostingView(rootView: Self.panelContent(model))
        // The window follows the panel's size as its times and notices come and go, as the menu bar's does
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        let window = PanelWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                 styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        // The title stays for screen readers and window lists; the panel's first line already shows the name
        window.title = "Catch My Train"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.level = .floating
        window.contentView = host
        // Under the icon, kept on its screen
        if let icon = button.window, let screen = icon.screen ?? NSScreen.main {
            let room = screen.visibleFrame
            let width = window.frame.width
            let left = min(max(icon.frame.midX - width / 2, room.minX + 8), room.maxX - width - 8)
            window.setFrameTopLeftPoint(NSPoint(x: left, y: min(icon.frame.minY, room.maxY) - 4))
        }
        panelWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// The panel as the menu bar shows it (the same text size, language and direction)
    static func panelContent(_ model: TransitModel) -> some View {
        MenuBarPanel()
            .id(model.textSize)
            .font(.scaled(.body))
            .environmentObject(model)
            .environment(\.locale, model.language.locale)
            .environment(\.layoutDirection, model.layoutDirection)
    }

    /// For a right click (or Control-click) on this app's menu bar icon, pops up the menu and returns true.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, Self.isStatusBarWindow(window),
              event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        else { return false }
        show(in: window)
        return true
    }

    /// Whether this is the menu bar icon's window. Checks the system's internal class name first; if macOS renames it later,
    /// checks whether it sits entirely in the menu bar at the top of the screen and contains a status bar button.
    /// This monitor only receives clicks in this app's own windows, so the window in the menu bar must be this app's icon.
    static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        if String(describing: type(of: window)).contains("StatusBarWindow") { return true }
        guard let screen = window.screen ?? NSScreen.main, let view = window.contentView,
              button(in: view) != nil else { return false }
        return window.frame.minY >= screen.visibleFrame.maxY - 1
    }

    /// Pops up the menu right below the menu bar icon; the icon stays highlighted while the menu is open.
    private func show(in window: NSWindow) {
        guard let view = window.contentView else { return }
        let menu = makeMenu()
        // Popped up in the menu bar, the menu would take the menu bar's look (dark over a dark desktop picture);
        // use the app's appearance instead, like the app's windows (white with Light)
        menu.appearance = NSApp.effectiveAppearance
        let button = Self.button(in: view)
        button?.highlight(true)
        let below = view.isFlipped ? NSPoint(x: 0, y: view.bounds.maxY + 5) : NSPoint(x: 0, y: view.bounds.minY - 5)
        _ = menu.popUp(positioning: nil, at: below, in: view)
        button?.highlight(false)
    }

    /// The same menu below a view in the menu bar panel (its "⋯" button)
    func popUp(below view: NSView?) {
        guard let view else { return }
        let menu = makeMenu()
        menu.appearance = view.effectiveAppearance
        let below = view.isFlipped ? NSPoint(x: 0, y: view.bounds.maxY + 4) : NSPoint(x: 0, y: view.bounds.minY - 4)
        _ = menu.popUp(positioning: nil, at: below, in: view)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let model else { return menu }
        let l = model.l10n
        // First line (gray): whether it's on or in standby, e.g. "On until 1:30 PM"
        let status = NSMenuItem(title: l.activityStatus(model.activity, now: Date()), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(ClosureMenuItem(title: model.isActive ? l.t("Standby") : l.t("Start")) { [weak model] in
            guard let model else { return }
            if model.isActive { model.standby() } else { model.start() }
        })
        let refresh = ClosureMenuItem(title: l.t("Refresh")) { [weak model] in model?.refresh() }
        refresh.isEnabled = model.isActive
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: l.t("Open Catch My Train")) { [weak self] in self?.openMain?() })
        menu.addItem(ClosureMenuItem(title: l.t("Settings…")) { [weak self] in self?.openSettings?() })
        menu.addItem(.separator())
        // Quit fully: the menu bar icon disappears too, and widgets download departures themselves
        let quit = ClosureMenuItem(title: l.t("Quit Catch My Train")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    /// The button inside the menu bar icon (used to show the pressed state).
    static func button(in view: NSView) -> NSButton? {
        if let found = view as? NSButton { return found }
        for sub in view.subviews {
            if let found = Self.button(in: sub) { return found }
        }
        return nil
    }
}

/// A menu item that runs a block of code when clicked.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() { handler() }
}

/// The window that shows the menu bar's panel when the icon is pressed without a click (StatusItemMenu): a panel, so the app's
/// Dock icon and window list leave it out. Escape closes it, and it closes once another window takes the keyboard, as the
/// menu bar's panel does.
final class PanelWindow: NSPanel {
    /// Escape closes the window with the first press, whichever control in it has the keyboard (a control kept the first
    /// press for itself). Not while one of the panel's menus is open: a menu takes its keys before the window sees them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1B}",
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            AppLog.ui.notice("menu bar panel window: Escape")
            close()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        close()
    }
}
