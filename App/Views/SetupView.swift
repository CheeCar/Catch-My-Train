import AppKit
import CatchText
import Combine
import SwiftUI

/// "Ready to Go" window: shown on a new install, and again from Settings → Privacy → Show Setup Again.
/// Lists what the app asks for (location, open at login), what each is for and what happens without it, plus a tip about the desktop widget.
/// Nothing here is required: "Start Using Catch My Train" works whatever is allowed.
/// A new install waits for it on standby (TransitModel.waitsForSetup): macOS asks for location only from the button here, and
/// nothing is downloaded or refreshed until the window is finished ("Start Using…" or closed).
enum SetupWindow {
    static let id = "setup"
    private static let pendingKey = "setupPending"

    /// A new install's setup isn't finished yet (set at the first launch by TransitModel, an update from an older version never
    /// has it). Saved, so quitting halfway shows the window again at the next launch.
    @MainActor static var isPending: Bool {
        get { UserDefaults.standard.bool(forKey: pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
    }
    /// Opened by itself in this launch already (once per launch)
    @MainActor static var autoShown = false
    /// Opens this window (set by the menu bar icon, like MainWindow.reopen)
    @MainActor static var openAction: (() -> Void)?
    /// Ends the wait for this window and starts the app (set by TransitModel; does nothing when nothing waits)
    @MainActor static var finish: (() -> Void)?

    @MainActor static func open(with openWindow: OpenWindowAction) {
        MainWindow.showInDock()
        openWindow(id: id)
        NSApp.activate()
    }

    /// The window's frame once it has grown, when it opens, to show all of its content: taller by what the content needs beyond
    /// the room its scroll area gives it, but no taller than the screen's visible area, keeping its top edge (moved up when its
    /// bottom would go below the visible area). Never shorter: a size that already fits stays as it is
    static func grownFrame(_ frame: CGRect, content: CGFloat, room: CGFloat, visible: CGRect) -> CGRect {
        guard content - room > 0.5, frame.height < visible.height else { return frame }
        let height = min(frame.height + (content - room).rounded(.up), visible.height)
        return CGRect(x: frame.minX, y: max(frame.maxY - height, visible.minY), width: frame.width, height: height)
    }
}

/// What macOS says about a permission, as the setup window shows it
private enum SetupStatus: Equatable {
    case allowed
    /// Not asked yet (or turned off inside the app): the button asks
    case notAsked
    /// Turned off in System Settings, or needs approval there: the button opens System Settings
    case needsSettings
}

/// The explanation card shown before System Settings opens
private enum SetupGuide: String, Identifiable {
    case location, loginItems
    var id: String { rawValue }
}

struct SetupView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var location: SetupStatus = .notAsked
    @State private var login: SetupStatus = .notAsked
    @State private var loginError: String?
    @State private var guide: SetupGuide?
    @State private var showWidgetSteps = false
    /// Width of the widest button or status on the right of the rows: they all get it, so they line up as one column
    @State private var controlWidth: CGFloat = 0
    /// The scroll area behind the rows (its scroll bar, and the window it's in)
    @State private var scroller = EnclosingScrollView()
    /// The rows' own height, the room the scroll area gives them, and where their bottom is in it now (below the room while
    /// there's more under what's in sight)
    @State private var contentHeight: CGFloat = 0
    @State private var scrollRoom: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    /// Checks again every second while open, so answers given in a system prompt or in System Settings show up right away
    private let recheckTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let l = transit.l10n
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.t("Ready to Go"))
                                .font(.scaled(.title).bold())
                            Text(l.t("Catch My Train works best with these. Each one is optional."))
                                .font(.scaled(.callout))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SetupRow(icon: "location.fill", title: l.t("Location"),
                             purpose: l.t("Finds stations near you and works out how long the walk takes. Your location is sent only to Apple Maps, unless you choose Google Maps for Directions."),
                             without: l.f("Without it, choose a place yourself with “%@”. Everything else works.", l.t("A place I choose")),
                             controlWidth: controlWidth) {
                        statusControl(location, allowedText: l.t("Allowed"), askText: l.t("Allow"), l: l) {
                            askLocation()
                        } settings: {
                            guide = .location
                        }
                    }
                    SetupRow(icon: "power", title: l.t("Open at login"),
                             purpose: l.t("Starts Catch My Train in the menu bar when you log in. The widget updates only after you press Start, and not on standby, including automatic standby."),
                             without: l.t("Without it, open the app yourself. Until then, the widget may show older times."),
                             controlWidth: controlWidth) {
                        statusControl(login, allowedText: l.t("Allowed"), askText: l.t("Turn On"), l: l) {
                            turnOnLogin(l)
                        } settings: {
                            guide = .loginItems
                        }
                    }
                    if let loginError {
                        Text(loginError).font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                    }
                    SetupRow(icon: "square.grid.2x2", title: l.t("Desktop Widget"),
                             purpose: l.t("See your next departures on the desktop without opening the app."),
                             without: l.sentences([l.t("This isn't a permission. Add it whenever you like."),
                                                   l.t("After each update, restart your Mac, and add the widget again if it's gone.")]),
                             controlWidth: controlWidth) {
                        if !showWidgetSteps {
                            Button { showWidgetSteps = true } label: {
                                Text(l.t("Show Me How")).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    if showWidgetSteps {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.t("1. Right-click an empty spot on the desktop and choose Edit Widgets."))
                            Text(l.t("2. Search for Catch My Train."))
                            Text(l.t("3. Drag the size you want onto the desktop."))
                        }
                        .font(.scaled(.callout))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 44)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Store only a real change: storing redraws the rows, which report their widths again
                .onPreferenceChange(SetupControlWidth.self) { w in
                    if abs(w - controlWidth) > 0.5 { controlWidth = w }
                }
                // How tall the rows are, and where their bottom is while they scroll: the window grows to fit them when it opens,
                // and the scroll bar and the fade at the bottom show only while there's more than fits
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - contentHeight) > 0.5 { contentHeight = h }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: { bottom in
                    if abs(bottom - contentBottom) >= 1 { contentBottom = bottom }
                }
                .background(EnclosingScrollViewFinder(holder: scroller))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if abs(h - scrollRoom) > 0.5 { scrollRoom = h }
            }
            // More below what's in sight: the rows fade out over their last points above the bottom bar, beside the scroll bar
            .overlay(alignment: .bottom) {
                if moreBelow {
                    LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .padding(.trailing, 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: overflows) { _, now in showScrollBar(now) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                // The button text is always whole (at the smallest window its end was cut off in Tagalog):
                // the note sits beside it when there's room for a few words a line, otherwise below it
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        startButton(l)
                        changeLaterNote(l)
                            .frame(minWidth: 160, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        startButton(l)
                        changeLaterNote(l)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 460, minHeight: 420)
        // Set here, not only on the scene (read once at launch), so the window title follows a language change
        .navigationTitle(l.t("Ready to Go"))
        .onAppear { recheck() }
        .task { await fitWindow() }
        .onReceive(recheckTimer) { _ in recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck() }
        .onDisappear { LoginItemsHelper.close() }
        .sheet(item: $guide) { guide in
            SetupGuideCard(guide: guide) {
                self.guide = nil
            } open: {
                self.guide = nil
                openSettings(for: guide)
            }
            .environmentObject(transit)
        }
    }

    /// The rows are taller than the room the scroll area gives them
    private var overflows: Bool { scrollRoom > 0 && contentHeight > scrollRoom + 0.5 }

    /// Part of the rows is below what's in sight
    private var moreBelow: Bool { overflows && contentBottom > scrollRoom + 2 }

    /// When it opens (and again with another text size, which makes the window's content anew), the window grows to show all of
    /// the rows when they need more room (SetupWindow.grownFrame), once they've been measured: their buttons' column takes a
    /// layout pass or two to settle. Only then, so a size set by hand afterwards stays as it's set
    private func fitWindow() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let window = scroller.view?.window, !window.styleMask.contains(.fullScreen),
              contentHeight > 0, scrollRoom > 0 else { return }
        let content = contentHeight, room = scrollRoom, old = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? old
        let frame = SetupWindow.grownFrame(old, content: content, room: room, visible: visible)
        if frame != old { window.setFrame(frame, display: true) }
        // The scroll area is found only after the first layout: from here on the scroll bar follows the rows as they change
        showScrollBar(content > room + frame.height - old.height + 0.5)
    }

    /// While the rows don't fit, the scroll bar stays in sight, so it shows there's more below: the usual overlay scroll bars
    /// show only while scrolling, so the scroll area takes the kind that always shows, and the system's own kind again once
    /// everything fits
    private func showScrollBar(_ show: Bool) {
        guard let view = scroller.view else { return }
        let style: NSScroller.Style = show ? .legacy : NSScroller.preferredScrollerStyle
        if view.scrollerStyle != style { view.scrollerStyle = style }
    }

    private func startButton(_ l: UIText) -> some View {
        Button { start() } label: {
            Text(l.t("Start Using Catch My Train →"))
                .padding(.horizontal, 6)
                .fixedSize()
        }
        .appButtonStyle(.prominent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func changeLaterNote(_ l: UIText) -> some View {
        Text(l.t("You can change these later in Settings."))
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Right side of a row: a green "Allowed" when done, otherwise the button that asks or opens System Settings
    @ViewBuilder
    private func statusControl(_ status: SetupStatus, allowedText: String, askText: String, l: UIText,
                               ask: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        switch status {
        case .allowed:
            Label(allowedText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.noticeGreen)
                .font(.scaled(.callout).bold())
        case .notAsked:
            Button(action: ask) { Text(askText).frame(maxWidth: .infinity) }
        case .needsSettings:
            Button(action: settings) { Text(l.t("Open System Settings")).frame(maxWidth: .infinity) }
        }
    }

    private func recheck() {
        let newLocation: SetupStatus
        if !transit.locationAllowed {
            newLocation = .notAsked
        } else {
            switch transit.location.permission {
            case true?: newLocation = .allowed
            case false?: newLocation = .needsSettings
            case nil: newLocation = .notAsked
            }
        }
        if newLocation != location { location = newLocation }
        let newLogin: SetupStatus = LoginItem.isEnabled ? .allowed : LoginItem.needsApproval ? .needsSettings : .notAsked
        if newLogin != login {
            login = newLogin
            if newLogin == .allowed {
                loginError = nil
                LoginItemsHelper.close()
            }
        }
    }

    /// "Use my location" turned off inside the app is turned back on first; then macOS asks (only the first time)
    private func askLocation() {
        if !transit.locationAllowed { transit.locationAllowed = true }
        if transit.location.permission == false {
            guide = .location
        } else {
            transit.location.request()
        }
        recheck()
    }

    private func turnOnLogin(_ l: UIText) {
        do {
            try LoginItem.set(true)
            loginError = nil
        } catch {
            loginError = l.t("Couldn't change this. Check System Settings → General → Login Items.")
        }
        recheck()
        if LoginItem.needsApproval { guide = .loginItems }
    }

    private func openSettings(for guide: SetupGuide) {
        switch guide {
        case .location:
            SystemSettingsPage.location.open()
        case .loginItems:
            SystemSettingsPage.loginItems.open()
            LoginItemsHelper.show(transit: transit)
        }
    }

    /// "Start Using…" also starts the app (when it's on standby: a new install waiting for this window, or the guide opened again
    /// from Settings)
    private func start() {
        if !transit.isActive { transit.start() }
        LoginItemsHelper.close()
        MainWindow.open(with: openWindow)
        dismissWindow(id: SetupWindow.id)
    }
}

/// The widest button or status on the right of the setup rows
private struct SetupControlWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One item: icon, name, what it's for, what happens without it, and its button on the trailing side.
/// The buttons of all rows are as wide as the widest button or status (controlWidth), and every control ends at the same trailing edge.
private struct SetupRow<Control: View>: View {
    let icon: String
    let title: String
    let purpose: String
    let without: String
    var controlWidth: CGFloat = 0
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Gray: blue is only for what can be clicked
            Image(systemName: icon)
                .font(.scaled(.title3))
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.scaled(.headline))
                Text(purpose)
                    .font(.scaled(.callout))
                    .fixedSize(horizontal: false, vertical: true)
                Text(without)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
                .appButtonStyle(.bordered)
                // Buttons fill the column; a status ("Allowed") is narrower and sits on the trailing side, so the column's trailing edge lines up
                .frame(width: controlWidth > 0 ? controlWidth : nil, alignment: .trailing)
                // Measured at its own size (a hidden copy), so the column can take the widest one
                .background {
                    control()
                        .appButtonStyle(.bordered)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: SetupControlWidth.self, value: g.size.width)
                        })
                }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

/// Small card before System Settings opens: which page, and which switch to turn on
private struct SetupGuideCard: View {
    @EnvironmentObject var transit: TransitModel
    let guide: SetupGuide
    let skip: () -> Void
    let open: () -> Void

    var body: some View {
        let l = transit.l10n
        VStack(alignment: .leading, spacing: 14) {
            Label(guide == .location ? l.t("Turn On Location") : l.t("Allow Catch My Train at Login"),
                  systemImage: guide == .location ? "location.fill" : "power")
                .font(.scaled(.title3).bold())
            Text(guide == .location
                 ? l.t("System Settings opens to Privacy & Security → Location Services. Turn on the switch next to Catch My Train.")
                 : l.t("System Settings opens to General → Login Items. Turn on Catch My Train there. If it isn't in the list, a helper at the bottom of the screen shows how to add it."))
                .font(.scaled(.callout))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l.t("Skip"), action: skip)
                    .keyboardShortcut(.cancelAction)
                    .appButtonStyle()
                Button(l.t("Open System Settings →"), action: open)
                    .keyboardShortcut(.defaultAction)
                    .appButtonStyle(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .environment(\.locale, transit.language.locale)
        .environment(\.layoutDirection, transit.layoutDirection)
    }
}

/// Floating helper at the bottom of the screen while System Settings shows Login Items: the app icon can be dragged into the list from here.
/// It doesn't take focus from System Settings, and closes when Catch My Train comes back to the front or open at login is on.
@MainActor
enum LoginItemsHelper {
    private static var panel: NSPanel?
    private static var observer: NSObjectProtocol?

    static func show(transit: TransitModel) {
        close()
        let content = LoginItemsHelperView { close() }
            .environmentObject(transit)
            .environment(\.locale, transit.language.locale)
            .environment(\.layoutDirection, transit.layoutDirection)
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        // Opening System Settings moves Catch My Train to the back; coming back to it means the helper is done
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    static func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.close()
        panel = nil
    }
}

private struct LoginItemsHelperView: View {
    @EnvironmentObject var transit: TransitModel
    let close: () -> Void

    var body: some View {
        let l = transit.l10n
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            Text(l.t("Can't find Catch My Train? Drag its icon into the list, or click + below the list and choose it."))
                .font(.scaled(.callout))
                .fixedSize(horizontal: false, vertical: true)
            Button(l.t("Done"), action: close)
                .appButtonStyle()
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(width: 480)
    }
}
