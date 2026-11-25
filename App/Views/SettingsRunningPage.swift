import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, Running page: standby, refreshing (with when live data counts as old) and opening at login, then the widget's rows.
struct RunningSettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    @State private var openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
    @State private var loginError: String?
    /// Open at login is on but still has to be allowed in System Settings (kept apart from loginError, so the notice follows a language change)
    @State private var loginNeedsApproval = LoginItem.needsApproval
    /// A number typed into a field that was changed to fit (outside the range, or between two steps): the field's title and the
    /// value kept, said under that field until the next change (see numberRow)
    @State private var adjusted: (title: String, value: Double)?
    /// How many times each field's typed number was changed to fit: the field is made again then, so it shows the value kept
    /// even when that's the value it had before
    @State private var fitCounts: [String: Int] = [:]

    var body: some View {
        let l = transit.l10n
        SettingsPageForm(.running) {
            SettingsSection(l.t("Running")) {
                AppMenuPicker(l.t("Go on standby after"), selection: autoStandbyBinding,
                              valueText: autoStandbyName(ActivityState.autoStandbyChoices[autoStandbyBinding.wrappedValue], l), plain: true) {
                    ForEach(ActivityState.autoStandbyChoices.indices, id: \.self) { i in
                        Text(autoStandbyName(ActivityState.autoStandbyChoices[i], l)).tag(i)
                    }
                }
                AppMenuPicker(l.t("Refresh every"), selection: $transit.refreshInterval,
                              valueText: refreshIntervalName(transit.refreshInterval, l), plain: true) {
                    ForEach(SharedStore.refreshIntervalChoices, id: \.self) { seconds in
                        Text(refreshIntervalName(seconds, l)).tag(seconds)
                    }
                }
                .help(l.t("How often to download new times while on."))
                if transit.refreshInterval < KeyedRequests.minimumInterval {
                    Text(l.t("Live times that need your own key or account refresh at most once a minute, so they don't get limited."))
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                // When realtime data counts as stale, under the refresh interval it goes by: the field shows the value used, which is
                // at least a minute more than the refresh interval (between two refreshes data isn't stale); the saved value stays as set
                let minimum = CatchSettings.realtimeStaleMinimum(refreshInterval: transit.effectiveRefreshInterval)
                numberRow(l.t("Real-time data expires after (s)"), value: Binding(
                    get: { transit.settings.realtimeStale(refreshInterval: transit.effectiveRefreshInterval) },
                    set: { transit.settings.realtimeStaleAfterSeconds = $0 }
                ), range: minimum...CatchSettings.realtimeStaleRange.upperBound, step: 30, l: l,
                          note: l.t("At least the refresh interval plus 1 minute")) { l.f("%@ sec", $0) }
                Text(l.t("Departures whose real-time data is older than this show “Not sure”."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(l.t("Open at login"), isOn: Binding(
                    get: { openAtLogin },
                    set: { on in
                        do {
                            try LoginItem.set(on)
                            loginError = nil
                        } catch {
                            loginError = l.t("Couldn't change this. Check System Settings → General → Login Items.")
                        }
                        syncLoginItem()
                    }
                ))
                // Read again whenever the app comes back to the front: it may have just been allowed (or turned off) in System Settings
                .onAppear { syncLoginItem() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in syncLoginItem() }
                // Only when macOS wants something from the user (the change failed, or the app still has to be allowed there): what
                // it is and, under it in the same row, a button that opens Login Items in System Settings, so users don't have to
                // find it themselves. While the switch just works there is no such row (a link always shown in a row of its own
                // looked out of place)
                if loginError != nil || loginNeedsApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loginError ?? l.t("Allow Catch My Train in System Settings → General → Login Items."))
                            .font(.scaled(.caption)).foregroundStyle(Color.noticeRed)
                        Button(l.t("Open Login Items Settings")) { SystemSettingsPage.loginItems.open() }
                            .appButtonStyle()
                    }
                }
                Text(l.t("After you close the window, Catch My Train keeps running in the menu bar so the widget stays up to date. On standby it downloads nothing."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                // Restore defaults: auto-standby time, refresh interval and when realtime data counts as stale (like the other
                // sections, this one has its own reset). "Open at login" is a Login Item in System Settings and isn't reset here.
                Button(l.f("Reset to defaults (%@)", runningDefaultsSummary(l))) {
                    transit.setAutoStandby(minutes: ActivityState.defaultAutoStandbyMinutes)
                    transit.refreshInterval = SharedStore.defaultRefreshInterval
                    var s = transit.settings
                    s.resetAdvanced()
                    transit.settings = s
                }
                .disabled(transit.activity.autoStandbyMinutes == ActivityState.defaultAutoStandbyMinutes
                          && transit.refreshInterval == SharedStore.defaultRefreshInterval
                          && transit.settings.isAdvancedDefault)
                .appButtonStyle()
            }

            // The desktop widget's own rows: whether it can read the app's data, and when it last ran. What the data sources are
            // doing is on the Data source page (DataStatusSettings)
            SettingsSection(l.t("Widget")) {
                StatusRow(icon: "rectangle.on.rectangle", title: l.t("Widget connection")) {
                    if SharedStore.isSharedFolderUsable {
                        Label(l.t("Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.noticeGreen)
                    } else {
                        Label(l.t("Not connected"), systemImage: "xmark.octagon.fill").foregroundStyle(Color.noticeRed)
                    }
                } detail: {
                    if !SharedStore.isSharedFolderUsable {
                        Text(l.t("The widget can't read Catch My Train's data. Try reinstalling Catch My Train."))
                    } else if SharedStore.writeFailures >= 3 || SharedStore.snapshotWriteFailures >= 2 {
                        // Several writes in a row to the shared folder failed (the snapshot is written only about once a refresh,
                        // so two in a row already say it)
                        Text(l.t("Couldn't save the latest data for the widget, so it may show older times. Check that your Mac has free disk space."))
                            .foregroundStyle(Color.noticeOrange)
                    } else {
                        Text(l.t("The widget can read the app's data."))
                    }
                }
                // The widget's last run time and version, to confirm the desktop widget is the new version and is updating.
                StatusRow(icon: "clock.arrow.circlepath", title: l.t("Widget")) {
                    if let hb = SharedStore.loadWidgetHeartbeat() {
                        let ranAt = l.timeWithSeconds(hb.ranAt, timeZone: l.macZone)
                        // Screen readers: what the time is comes before it ("Last updated, 9:30:36 PM"); the line
                        // under the name, which says that for the eye, is left out for them
                        Text(ranAt)
                            .accessibilityLabel(Text(hb.build != SharedStore.buildNumber
                                                     ? ranAt : l.t("Last updated") + l.comma + ranAt))
                    } else {
                        Text(l.t("Hasn't run yet"))
                    }
                } detail: {
                    if let hb = SharedStore.loadWidgetHeartbeat() {
                        if hb.build != SharedStore.buildNumber {
                            // Restarted since it last ran and still not run: restarting again won't help, it may be off the desktop
                            Text(Self.restarted(since: hb.ranAt)
                                 ? l.t("The widget hasn't run since your Mac restarted. If it's gone from your desktop, add it again.")
                                 : l.t("The widget is still using an older version. To switch it to this version, log out and back in, or restart your Mac."))
                                .foregroundStyle(Color.noticeOrange)
                        } else {
                            Text(l.t("Last updated"))
                                .accessibilityHidden(true)
                        }
                    }
                    // How often widgets update, so users know
                    Text(l.t("While Catch My Train is in front, the widget updates with every refresh. When the app is in the background, it updates about every 5 minutes, and macOS may wait longer to save energy. When the app is quit, the widget can update only NYC Subway, Staten Island Railway and Roosevelt Island Tram times by itself; other times update when you open Catch My Train again."))
                }
            }
        }
    }

    /// Whether this Mac has started up since `time` (by the clock, sleep included); false when that can't be read
    static func restarted(since time: Date) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var started = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &started, &size, nil, 0) == 0, started.tv_sec > 0 else { return false }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec)) > time
    }

    /// A numeric setting row of this page (SettingNumberRow): the note about a number changed to fit is this page's
    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           l: UIText, note: String? = nil, unit: @escaping (String) -> String) -> some View {
        SettingNumberRow(title: title, value: value, range: range, step: step, l: l, note: note,
                         adjusted: $adjusted, fitCounts: $fitCounts, unit: unit)
    }

    /// The Open at login toggle and its approval notice as macOS has them now
    private func syncLoginItem() {
        openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        loginNeedsApproval = LoginItem.needsApproval
    }

    /// Choice of auto-standby duration (by index, because Double? can't be a Picker tag directly).
    private var autoStandbyBinding: Binding<Int> {
        Binding(
            get: {
                ActivityState.autoStandbyChoices.firstIndex { $0 == transit.activity.autoStandbyMinutes } ?? 1
            },
            set: { transit.setAutoStandby(minutes: ActivityState.autoStandbyChoices[$0]) }
        )
    }

    private func refreshIntervalName(_ seconds: TimeInterval, _ l: UIText) -> String {
        seconds < 60 ? l.f("%@ sec", l.number(seconds)) : l.minutes(seconds)
    }

    private func autoStandbyName(_ minutes: Double?, _ l: UIText) -> String {
        guard let minutes else { return l.t("Never") }
        return l.minutes(minutes * 60)
    }

    private func runningDefaultsSummary(_ l: UIText) -> String {
        autoStandbyName(ActivityState.defaultAutoStandbyMinutes, l) + l.comma + refreshIntervalName(SharedStore.defaultRefreshInterval, l)
            + l.comma + l.f("%@ sec", l.number(CatchSettings.default.realtimeStaleAfterSeconds))
    }
}

/// A status row in Settings (the widget's on the Running page, the data sources' on Data source): icon and title on the left (with small explanatory text below, which wraps to as many lines as it needs), value on the right.
/// The text takes the width the value leaves (the value keeps its own), so a long explanation isn't wrapped into a narrow column
/// beside empty space at larger text
struct StatusRow<Value: View, Detail: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var value: Value
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            value
                .lineLimit(1)
                .monospacedDigit()
                .fixedSize()
                .padding(.leading, 12)
        }
    }
}
