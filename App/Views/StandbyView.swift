import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

// MARK: - Start / Standby

/// Toggle and status, e.g. "On until 8:45 PM [toggle]". Shared by the main window toolbar and the menu bar.
struct ActivitySwitch: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        // Only the toggle goes in the title bar (saves space); "on until when" goes in the hover tooltip
        HStack(spacing: 6) {
            Toggle(l.t("Start"), isOn: Binding.afterViewUpdate(
                get: { transit.isActive },
                set: { on in on ? transit.start() : transit.standby() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            // Screen readers say "Start" and the hover text's status ("On until 4:37 AM", "Standby"), not only on or off
            .accessibilityValue(Text(l.activityStatus(transit.activity, now: Date())))
        }
        .help(l.activityStatus(transit.activity, now: Date()))
    }
}

/// The main window on standby: no refreshing, downloading or locating, just a "Start" button.
struct StandbyView: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if transit.waitsForSetup {
            setupWait
        } else {
            standby
        }
    }

    /// A new install before its setup window is finished: nothing has started yet. Start works here too, as in the menu bar
    /// panel (any Start ends the wait); the other button brings that window back to the front
    private var setupWait: some View {
        let l = transit.l10n
        return VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Not fixedSize(vertical): the window's minimum height is worked out at a very narrow width, where this sentence would
            // take a line for every letter and make the whole window's content taller than the window (see BusKeyPrompt)
            Text(l.t("Finish the setup window to see departures."))
                .font(.scaled(.title3).weight(.semibold))
                .multilineTextAlignment(.center)
            // Side by side; one under the other when the page is too narrow for both
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { setupWaitButtons(l) }
                    .fixedSize()
                VStack(spacing: 8) { setupWaitButtons(l) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func setupWaitButtons(_ l: UIText) -> some View {
        Button {
            transit.start()
        } label: {
            Label(l.t("Start"), systemImage: "play.fill")
                .frame(minWidth: 120)
        }
        .appButtonStyle(.prominent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        Button(l.t("Show Setup Again")) { SetupWindow.open(with: openWindow) }
            .appButtonStyle()
            .controlSize(.large)
    }

    private var standby: some View {
        let l = transit.l10n
        return VStack(spacing: 14) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(l.t("Standby")).font(.scaled(.title2).bold())
            Text(l.t("Nothing is refreshed or downloaded on standby."))
                .foregroundStyle(.secondary)
            Button {
                transit.start()
            } label: {
                Label(l.t("Start"), systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .appButtonStyle(.prominent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            if let minutes = transit.activity.autoStandbyMinutes {
                Text(l.f("Goes back to standby after %@.", l.minutes(minutes * 60)))
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Demo mode notice: the trips are made up; turn it off in Settings. Plan a Trip says its own (`text`).
struct DemoBanner: View {
    @EnvironmentObject var transit: TransitModel
    var text: String?

    var body: some View {
        let l = transit.l10n
        let text = self.text ?? l.t("Demo data only. These times are made up. Turn off Demo mode in Settings to see real times.")
        HStack(spacing: 8) {
            Label(text, systemImage: "theatermasks")
                .frame(maxWidth: .infinity, alignment: .leading)
            // The main window's notice says to turn it off in Settings: the button for it. Plan a Trip's says no such thing
            if self.text == nil {
                OpenSettingsButton(l: l, target: .demo)
            }
        }
        .font(.scaled(.callout))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.demoBackground))
        .contrastBorder(cornerRadius: 8)
        // Can't use fixedSize(vertical): when computing the window's minimum height it measures at a very narrow width, making this text very tall,
        // and the whole window content gets pushed under the title bar. At most 3 lines, with an ellipsis if it doesn't fit.
        .lineLimit(3)
        .help(text)
    }
}

/// Notice when there's no location permission: explain that "My current location" can't be used, with a button to open System Settings.
/// When network is turned off in Settings, this line is shown in place of the map and address search.
/// large: the transit map window, filling the map area.
struct NetworkOffNote: View {
    var l: UIText
    var large = false

    var body: some View {
        // It says to go to Settings, so it has the button for it
        VStack(alignment: large ? .center : .leading, spacing: 6) {
            Label(l.t("Maps and address search need the network. Turn on “Allow network” in Settings → Privacy."),
                  systemImage: "wifi.slash")
                .font(.scaled(large ? .callout : .caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OpenSettingsButton(l: l, target: .privacy)
        }
        .frame(maxWidth: large ? .infinity : nil, maxHeight: large ? .infinity : nil)
        .padding(large ? 20 : 0)
    }
}

/// "Settings…" beside a note that says to change something in Settings: opens the Settings window at the place the note names
/// (SettingsJump), or where it was last when there's none
struct OpenSettingsButton: View {
    var l: UIText
    var target: SettingsJump.Target?
    /// Closes the window it's in first (the menu bar panel)
    var before: () -> Void = {}
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(l.t("Settings…")) {
            before()
            if let target { SettingsJump.to(target) }
            NSApp.activate()
            openSettings()
        }
        .appButtonStyle()
        .controlSize(.small)
    }
}

/// Explanation when "Use my location" is turned off in Settings (separate from LocationAccessNotice for location turned off in System Settings)
struct LocationOffNote: View {
    var l: UIText
    /// Counts the clicks on a grayed-out "My current location": each one blinks the line once (not with "Reduce motion")
    var blink = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(l.t("Location is off in Settings → Privacy."), systemImage: "location.slash")
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .phaseAnimator(Motion.ease(0.2) == nil ? [false] : [false, true], trigger: blink) { line, dimmed in
                    line.opacity(dimmed ? 0.25 : 1)
                } animation: { _ in
                    Motion.ease(0.2)
                }
            OpenSettingsButton(l: l, target: .privacy)
        }
    }
}

struct LocationAccessNotice: View {
    @EnvironmentObject var transit: TransitModel
    var compact = false

    var body: some View {
        let l = transit.l10n
        VStack(alignment: .leading, spacing: 4) {
            Label(compact ? l.t("Location access is off, so “My current location” can't be used.")
                          : l.t("Location access is off for Catch My Train, so “My current location” can't be used. Choose a place instead, or turn location on in System Settings."),
                  systemImage: "location.slash")
                .font(.scaled(.caption))
                .foregroundStyle(Color.noticeOrange)
                // Its own line limit: in the sidebar (compact) a row's text is kept to one line unless told otherwise
                .lineLimit(SidebarText.sentenceLines)
                .fixedSize(horizontal: false, vertical: true)
            // A small button like the sidebar's Change, not a link; on two lines when one is too narrow for it
            Button(l.t("Open Location Settings")) { SystemSettingsPage.location.open() }
                .buttonStyle(SmallBezelButtonStyle())
                .font(.scaled(.caption))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}
