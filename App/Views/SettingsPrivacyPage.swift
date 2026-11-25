import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, Privacy page: where walking starts, then what the app may use and what it keeps (PrivacySettings).
struct PrivacySettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @State private var showPlacePicker = false
    /// Clicks on "My current location" while "Use my location" is off (see LocationOffNote)
    @State private var offClicks = 0

    var body: some View {
        let l = transit.l10n
        SettingsPageForm(.privacy) {
            SettingsSection(l.t("Location")) {
                // Same rules as the sidebar and the menu bar (see TransitModel.requestLocationMode); in Demo mode they change its own
                // place in memory. When the click doesn't switch ("My current location" with "Use my location" off, or no place chosen
                // yet), the blue stays put
                SettingSegments(title: l.t("Walk from"), selection: Binding(
                    get: { transit.locationMode },
                    set: { mode in
                        if mode == .current, !transit.locationAllowed, !transit.isDemo { offClicks &+= 1 }
                        transit.requestLocationMode(mode) { showPlacePicker = true }
                    }
                ), choices: [
                    SettingChoice(LocationMode.current, l.t("My current location")),
                    SettingChoice(LocationMode.manual, l.t("A place I choose")),
                ])
                // Demo mode uses no location
                // A click on "My current location" that can't switch blinks this line: it says why
                if !transit.locationAllowed && !transit.isDemo {
                    LocationOffNote(l: l, blink: offClicks)
                }
                HStack {
                    Text(locationStatus(l))
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                    Spacer()
                    // After choosing "A place I choose", open the place picker here (search an address or station, or pick on the map;
                    // in Demo mode its own places in Manhattan)
                    Button(l.t("Choose a Place…")) { showPlacePicker = true }
                        .appButtonStyle()
                }
                Text(l.t("Your location is used to work out walking times. It's sent only to Apple Maps, for walking routes and place names, and nowhere else, unless you choose Google Maps for Directions. Nearby stations and walking times are kept on this Mac for the widget."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                // Which map "Directions" opens (on the station page and in a departure's details); here, beside what's said about
                // where the starting point goes, since Google Maps is sent it
                SettingSegments(title: l.t("Open Directions in"), selection: $transit.directionsMap, choices: [
                    SettingChoice(DirectionsMap.appleMaps, l.mapName(.appleMaps)),
                    SettingChoice(DirectionsMap.googleMaps, l.mapName(.googleMaps)),
                ])
                Text(l.t("Directions opens the walking route from your starting point to a station. Google Maps opens in your default browser, and your starting point and the station are sent to Google."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
            }

            PrivacySettings()
        }
        .onChange(of: showPlacePicker) { _, show in
            guard show else { return }
            showPlacePicker = false
            PlacePickerWindow.open(with: openWindow, transit: transit)
        }
    }

    private func locationStatus(_ l: UIText) -> String {
        // No place was ever chosen and there is no position (a denied location says more below)
        if transit.needsPlace, transit.locationMode == .manual || transit.locationState != .denied {
            return transit.missingPlaceText
        }
        switch transit.locationMode {
        case .manual:
            return l.f("Walking from %@", transit.place.name)
        case .current:
            // Demo mode's current location is Times Square, and it uses no location (as in the place picker)
            if transit.isDemo { return l.f("Demo: walking from %@", DemoData.home.name) }
            switch transit.locationState {
            // How exact it is, when it isn't (the same lines as the main window)
            case .located:
                if transit.locationTooApproximate { return transit.locationTooApproximateText }
                return transit.locationAccuracyNote ?? l.t("Location found.")
            // On standby nothing is located (the sidebar row reads the same)
            case .idle, .locating: return transit.isActive ? l.t("Finding your location…") : l.t("Current location")
            case .denied: return l.t("Location access is off for Catch My Train, so “My current location” can't be used. Choose a place instead, or turn location on in System Settings.")
            case .failed: return l.f("Location unavailable. Walking from %@", transit.place.name)
            }
        }
    }
}

/// A few System Settings pages: buttons in Settings open them directly so users don't have to find them
enum SystemSettingsPage: String {
    case location = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    case loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    case notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    func open() {
        // Notifications: this app's own row there, by its identifier
        var address = rawValue
        if self == .notifications, let id = Bundle.main.bundleIdentifier { address += "?id=" + id }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// "Privacy and permissions" in Settings (foolproofing, so location and network can be turned off inside the app
/// without hunting through System Settings). A sandboxed app can't change system permissions, so the toggles only affect CatchMyTrain itself, and the buttons next to them open System Settings.
/// Automatic update checks stay in "Updates"; no duplicate toggle here.
struct PrivacySettings: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    @State private var recentCount = SharedStore.recentPlaces.count
    @State private var confirmClear = false

    var body: some View {
        let l = transit.l10n
        Section {
            Toggle(isOn: $transit.locationAllowed) {
                // Icons in a column of one width, so these titles line up with the other settings that have an icon
                Label(l.t("Use my location"), systemImage: "location")
                    .labelStyle(IconColumnLabelStyle())
            }
            // Turned off with no place ever chosen: nothing is left to walk from, so the place picker opens
            .onChange(of: transit.locationAllowed) { _, allowed in
                if !allowed, transit.opensPickerForPlace { PlacePickerWindow.open(with: openWindow, transit: transit) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(l.t("When this is off, Catch My Train never asks where you are and walks from a place you choose."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(l.t("Open Location Settings")) { SystemSettingsPage.location.open() }
                    .buttonStyle(.link)
                    .font(.scaled(.caption))
            }
            Toggle(isOn: $transit.networkAllowed) {
                Label(l.t("Allow network"), systemImage: "network")
                    .labelStyle(IconColumnLabelStyle())
            }
            Text(l.t("When this is off, the app and widget never go online and show only timetables saved on this Mac: no live times, walks are estimated in a straight line, and maps and address search don't work."))
                .font(.scaled(.caption)).foregroundStyle(transit.networkAllowed ? Color.secondary : Color.noticeOrange)
                .fixedSize(horizontal: false, vertical: true)
            Button(l.t("Clear Recent Places…")) { confirmClear = true }
                .appButtonStyle(.bordered)
                .disabled(recentCount == 0)
            // Deleting downloaded data moved to its own section (DownloadedDataSettings): where to find it
            Text(l.t("Downloaded timetables and maps are listed in Data source, under Downloaded data."))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(l.t("Keys and accounts are kept only in the Keychain. Remove them in Data source."))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // What the notifications permission is for; it is shown and changed on the Reminders page
            Text(l.t("Notifications are used only for leave-by reminders. They're made on this Mac and nothing is sent anywhere."))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The first-launch setup window: permissions with what each is for
            Button(l.t("Show Setup Again")) { SetupWindow.open(with: openWindow) }
                .appButtonStyle()
        } header: {
            // "Location is off in Settings → Privacy" and the like open Settings here (SettingsJump)
            Text(l.t("Privacy and permissions"))
                .settingsSectionTitle()
                .id(SettingsJump.Target.privacy.id)
        }
        .onAppear { recentCount = SharedStore.recentPlaces.count }
        // Counted again when the list may have changed while Settings stayed open: a place chosen (it goes into the recent places),
        // Demo mode turned on or off (it has a list of its own), or this window back in front after another (the place picker
        // can remove one)
        .onChange(of: transit.place) { _, _ in recentCount = SharedStore.recentPlaces.count }
        .onChange(of: transit.dataSource) { _, _ in recentCount = SharedStore.recentPlaces.count }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recentCount = SharedStore.recentPlaces.count
        }
        .alert(l.t("Clear recent places?"), isPresented: $confirmClear) {
            Button(l.t("Cancel"), role: .cancel) {}
            Button(l.t("Clear"), role: .destructive) {
                SharedStore.clearRecentPlaces()
                recentCount = 0
            }
        } message: {
            Text(l.t("Favorites are kept."))
        }
    }
}
