import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether the app was opened automatically at login ("Open at login"). If so, don't show the main window; stay in the menu bar.
    /// Only applies to windows the system restores in the first few seconds after launch: always cleared after a few seconds, so a main window the user opens later is not closed
    /// (clearing it only when the main window appears would close the window from the first "Open Catch My Train" click).
    static var launchedAtLogin = false

    /// A main window that appears within this many seconds of launch counts as "auto-opened at login"
    static let loginWindowGrace: TimeInterval = 5
    private static var launchStartedAt = Date()

    /// Still within the few seconds after an automatic login launch
    static var inLoginLaunchGrace: Bool {
        launchedAtLogin && Date().timeIntervalSince(launchStartedAt) < loginWindowGrace
    }

    /// The app was opened automatically at login, for the map and Plan a Trip windows: kept apart from launchedAtLogin, which the main
    /// window clears when it closes itself, so whichever window appears first, the others still see it
    private static var startedAtLogin = false

    /// Within the few seconds after an automatic login launch: a map or Plan a Trip window the system restores now closes again
    /// (MapWindowView, PlannerWindowView)
    static var inLoginRestoreGrace: Bool {
        startedAtLogin && Date().timeIntervalSince(launchStartedAt) < loginWindowGrace
    }

    /// The main window has appeared since this launch (if the user closes it later, don't reopen it automatically)
    static var mainWindowShown = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        TransitModel.launchAppearance.apply()
        // Leave-by reminders: the app answers for its notifications from here on (shown with the app in front too; a click opens
        // the main window)
        LeaveReminderCenter.listen()
        Self.launchStartedAt = Date()
        // The launch event says "as a login item" when macOS opens the app at login. The new-style login item (SMAppService)
        // sometimes comes without it: LoginLaunch then goes by how long ago this login (loginwindow's start) was. A launch with an
        // event that doesn't say so is someone opening the app, however soon after login
        let event = NSAppleEventManager.shared().currentAppleEvent
        let marked = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let sinceLogin = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.loginwindow" })?.launchDate
            .map { Date().timeIntervalSince($0) }
        Self.launchedAtLogin = LoginLaunch.isAutomatic(markedAsLoginItem: marked, hasLaunchEvent: event != nil,
                                                       loginItemEnabled: LoginItem.isEnabled, secondsSinceLogin: sinceLogin)
        Self.startedAtLogin = Self.launchedAtLogin
        // How it was decided, to look up when a login launch shows the main window after all, or a launch by hand hides it
        let hasEvent = event != nil
        let seconds = sinceLogin.map { Int($0) } ?? -1
        let atLogin = Self.launchedAtLogin
        AppLog.ui.notice("launch marked=\(marked, privacy: .public) event=\(hasEvent, privacy: .public) sinceLogin=\(seconds, privacy: .public) atLogin=\(atLogin, privacy: .public)")
    }

    /// When the app is opened directly (not at login), always show the main window. If it last quit with the window closed, SwiftUI won't open it by itself
    /// (a direct launch would show only the menu bar icon).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // MainWindow.reopen only exists after the menu bar icon appears, so try once at 1 second and once at 3 seconds
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.showMainWindowIfNeeded()
                Self.showSetupIfNeeded()
            }
        }
        // The few seconds of automatic login launch are over: any main window opened from now on is the user's own
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginWindowGrace) { Self.launchedAtLogin = false }
        // Also show the Dock icon and the top-of-screen menu when another window opens (map, Plan a Trip, Settings, location picker, How It Works);
        // only the menu bar icon remains once all are closed
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, MainWindow.isAppWindow(window) { MainWindow.showInDock() }
                // The setup window came to the front: the main window's sidebar behind it is looked at again (SidebarScrollClamp)
                if window?.identifier?.rawValue.hasPrefix(SetupWindow.id) == true {
                    SidebarScrollClamp.ClampView.checkAll("setup window in front")
                }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                // The setup window closed, by "Start Using…" or its close button: a new install that waited for it starts now
                if window.identifier?.rawValue.hasPrefix(SetupWindow.id) == true {
                    SetupWindow.finish?()
                    SidebarScrollClamp.ClampView.checkAll("setup window closed")
                }
                guard MainWindow.isAppWindow(window) else { return }
                MainWindow.hideFromDockIfNoWindows(closing: window)
            }
        }
    }

    private static func showMainWindowIfNeeded() {
        // Already appeared (the user closed it within 3 seconds): don't open it again
        guard !launchedAtLogin, !mainWindowShown, let reopen = MainWindow.reopen else { return }
        let mainVisible = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }
        guard !mainVisible else { return }
        MainWindow.showInDock()
        reopen()
        NSApp.activate()
    }

    /// New install whose setup isn't finished: open the setup window in front of the main window, once per launch
    private static func showSetupIfNeeded() {
        guard SetupWindow.isPending, !SetupWindow.autoShown else { return }
        // Opened at login: "Open at login" was turned on in the setup window, so it has been seen, and nothing waits for it any longer
        if startedAtLogin {
            SetupWindow.finish?()
            return
        }
        guard let open = SetupWindow.openAction else { return }
        SetupWindow.autoShown = true
        MainWindow.showInDock()
        open()
        NSApp.activate()
    }

    /// Don't quit when the last window closes; keep running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// On quit, tell the widget "the main app is gone": from now on the widget downloads departures itself.
    func applicationWillTerminate(_ notification: Notification) {
        // When relaunching for a language change, the new instance has already written "running", so don't overwrite it;
        // the tests' host never wrote it (see TransitModel.isTestHost)
        guard !AppRelaunch.inProgress, !TransitModel.isTestHost else { return }
        SharedStore.appAliveAt = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A link from the widget: clicking the widget opens the main window (the stations nearby), even when it was closed; its note
    /// that needs Settings opens Settings
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch DeepLink(url: url) {
            case .nearby:
                MainWindow.showInDock()
                MainWindow.reopen?()
                NSApp.activate()
            case .settings:
                MainWindow.settings?()
            case nil:
                break
            }
        }
    }

    /// The app was opened again while already running in the menu bar: show the main window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindow.showInDock()
            MainWindow.reopen?()
            NSApp.activate()
        }
        return true
    }
}

/// Top-of-screen menu bar (the menus at the top left are complete while the app is open).
/// CatchMyTrain menu: About, Settings (⌘,), Quit (built in);
/// View: Nearby stations (the main window), Plan a Trip and the map (each in its own window), the appearance (System, Light, Dark); Transit: the four modes, Start / Standby, Refresh, temporarily widen the range, walking start point;
/// Shortcuts are all ⌘ plus one key (on by default; Nearby and Start / Standby have none until given one) and can be changed or
/// removed in Settings (see AppShortcuts).
/// Window: built in (including the CatchMyTrain main window); Help: How It Works. The unused New item is removed.
struct AppCommands: Commands {
    @ObservedObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        let l = transit.l10n
        CommandGroup(replacing: .newItem) {}

        CommandGroup(before: .sidebar) {
            Button(l.pick(transit.system, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"), ferry: l.t("Nearby piers"))) {
                MainWindow.open(with: openWindow)
            }
            .keyboardShortcut(transit.keyboardShortcut(.nearby))
            Button(l.t("Plan a Trip")) { PlannerWindow.open(with: openWindow) }
                .keyboardShortcut(transit.keyboardShortcut(.planTrip))
            Button(StationSidebar.mapName(transit.system, l)) { MapWindow.open(with: openWindow) }
                .keyboardShortcut(transit.keyboardShortcut(.map))
            Divider()
            Picker(l.t("Appearance"), selection: $transit.appearance) {
                Text(l.t("System")).tag(AppAppearance.system)
                Text(l.t("Light")).tag(AppAppearance.light)
                Text(l.t("Dark")).tag(AppAppearance.dark)
            }
            Divider()
        }

        CommandMenu(l.t("Transit")) {
            ForEach(TransitSystem.modes, id: \.self) { mode in
                Toggle(l.modeName(mode), isOn: Binding(
                    get: { transit.system == mode },
                    set: { if $0 { transit.system = mode } }))
                    .keyboardShortcut(transit.keyboardShortcut(AppShortcuts.mode(mode)))
            }
            Divider()
            Button(transit.isActive ? l.t("Standby") : l.t("Start")) {
                transit.isActive ? transit.standby() : transit.start()
            }
            .keyboardShortcut(transit.keyboardShortcut(.startStandby))
            Button(l.t("Refresh")) { transit.refresh() }
                .keyboardShortcut(transit.keyboardShortcut(.refresh))
                .disabled(!transit.isActive)
            // Can't widen in standby: then an item of the same name, greyed out like Refresh. Greying out the submenu itself
            // doesn't work (macOS still opens it, with every item in it greyed out)
            if transit.isActive {
                Menu(l.t("Extend Range for Now")) {
                    ForEach(TransitModel.tempExtraChoices, id: \.self) { m in
                        Toggle(l.f("+%@ for now", l.minutes(m * 60)), isOn: Binding(
                            get: { transit.tempExtraMinutes == m },
                            // Unticking the ticked one = back to the normal range
                            set: { transit.tempExtraMinutes = $0 ? m : 0 }))
                    }
                    Divider()
                    Button(l.t("Back to Normal Range")) { transit.tempExtraMinutes = 0 }
                        .disabled(transit.tempExtraMinutes == 0)
                }
            } else {
                Button(l.t("Extend Range for Now")) {}
                    .disabled(true)
            }
            Divider()
            // In Demo mode these change its own place, in memory only (see the sidebar)
            Picker(l.t("Walk from"), selection: Binding(
                get: { transit.locationMode },
                set: { mode in
                    // Same as the sidebar: switch directly if a location has been chosen; otherwise open the window and switch only once one is chosen
                    transit.requestLocationMode(mode) { show(.choosePlace) }
                })) {
                Text(l.t("My current location")).tag(LocationMode.current)
                Text(l.t("A place I choose")).tag(LocationMode.manual)
            }
            Button(l.t("Choose a Place…")) { show(.choosePlace) }
                .keyboardShortcut(transit.keyboardShortcut(.choosePlace))
        }

        // "About Catch My Train": copyright and license (PolyForm Noncommercial).
        // The license requires that anyone who receives the software also receives the terms or their URL, plus the "Required Notice" line.
        // Check for a new version (same as the button in Settings), then open Settings at Updates to show the result
        CommandGroup(replacing: .appInfo) {
            Button(l.t("About Catch My Train")) { AboutPanel.show(l, area: transit.sourcesArea) }
            // When greyed out, put the reason in the title (greyed-out menu items have no tooltip)
            Button(transit.isDemo ? l.t("Check for Updates (turn off demo mode first)")
                   : !transit.networkAllowed ? l.t("Check for Updates (network is off in Settings)")
                   : !transit.isActive ? l.t("Check for Updates (start the app first)") : l.t("Check for Updates…")) {
                transit.checkForUpdates()
                SettingsJump.to(.updates)
                NSApp.activate()
                openSettings()
            }
            .disabled(!transit.isActive || transit.isDemo || !transit.networkAllowed)
        }

        CommandGroup(replacing: .help) {
            // How It Works opens in its own window, without opening Settings first
            // No keyboard shortcut: it's an explanation, not a feature
            Button(l.t("How It Works")) { HowItWorksWindow.open(with: openWindow) }
        }
    }

    /// Open the main window first, then have it open the location picker.
    private func show(_ request: TransitModel.MenuRequest) {
        MainWindow.open(with: openWindow)
        transit.menuRequest = request
    }
}

/// Shortcut names (same in the menu and Settings) and the item each transit mode maps to.
/// The window hosting Settings: resizable by dragging its edges, has a minimum size, and remembers its position and size (it reopens where it was).
/// If the remembered position is on a display that has been unplugged, move it back onto the current screen.
struct WindowSetup: NSViewRepresentable {
    var autosaveName: String
    var minSize: NSSize

    func makeNSView(context: Context) -> Hook { Hook(autosaveName: autosaveName, minSize: minSize) }
    func updateNSView(_ nsView: Hook, context: Context) { nsView.setMinSize(minSize) }

    final class Hook: NSView {
        let autosaveName: String
        private(set) var minSize: NSSize
        init(autosaveName: String, minSize: NSSize) {
            self.autosaveName = autosaveName
            self.minSize = minSize
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        /// A smallest size that changed while the window is open (the Settings window's follows the language)
        func setMinSize(_ size: NSSize) {
            guard size != minSize else { return }
            minSize = size
            guard let window else { return }
            window.minSize = size
            window.contentMinSize = size
        }

        /// SwiftUI sometimes turns "resizable" off again, so check on every layout pass
        override func layout() {
            super.layout()
            if let window, !window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen) {
                window.styleMask.insert(.resizable)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [autosaveName, minSize] in
                // macOS doesn't make SwiftUI's Settings window resizable, so turn it on directly here
                window.styleMask.insert(.resizable)
                window.minSize = minSize
                window.contentMinSize = minSize
                window.maxSize = NSSize(width: 100_000, height: 100_000)
                window.contentMaxSize = NSSize(width: 100_000, height: 100_000)
                if window.frameAutosaveName != autosaveName {
                    window.setFrameUsingName(autosaveName)
                    window.setFrameAutosaveName(autosaveName)
                }
                Self.keepOnScreen(window)
            }
            // Also check "resizable" every time the window becomes key
            if keyObserver == nil {
                keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { note in
                    MainActor.assumeIsolated {
                        guard let w = note.object as? NSWindow, !w.styleMask.contains(.fullScreen) else { return }
                        w.styleMask.insert(.resizable)
                    }
                }
            }
        }

        private var keyObserver: NSObjectProtocol?

        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }

        /// When the window isn't on any screen, put it back in the middle of the main screen; if it's bigger than the screen, shrink it to fit
        static func keepOnScreen(_ window: NSWindow) {
            guard window.styleMask.contains(.fullScreen) == false else { return }
            let frame = window.frame
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 100 && $0.visibleFrame.intersection(frame).height >= 60 }
            guard !onScreen, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let area = screen.visibleFrame
            let w = min(frame.width, area.width), h = min(frame.height, area.height)
            window.setFrame(NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h), display: true)
        }
    }
}
