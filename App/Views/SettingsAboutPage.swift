import AppKit
import CatchText
import Combine
import SwiftUI
import TransitCore

/// Settings, About page: the version and checking for updates, then How It Works.
struct AboutSettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let l = transit.l10n
        SettingsPageForm(.about) {
            // Check for updates (notify only, no auto-install; auto-check is off by default, monthly once on)
            UpdateSettings()

            // At the very bottom: how the app decides; clicking opens a dialog
            Section {
                Button {
                    HowItWorksWindow.open(with: openWindow)
                } label: {
                    Label(l.t("How It Works"), systemImage: "info.circle")
                        .labelStyle(IconColumnLabelStyle())
                }
                .appButtonStyle()
            }
        }
    }
}

/// "Updates" in Settings: current version, auto-check toggle, check-now button, and a download button when a new version exists
struct UpdateSettings: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        Section {
            Toggle(isOn: $transit.autoCheckUpdates) {
                Label(l.t("Check for updates automatically"), systemImage: "arrow.down.circle")
                    .labelStyle(IconColumnLabelStyle())
            }
            Text(l.t("Once a month, Catch My Train asks GitHub for the latest version. It sends nothing about you; GitHub sees only the request, as with any website. It only tells you about a new version; you download and install it yourself."))
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SourceRow(icon: "app.badge", name: l.f("Version %@", transit.appVersion),
                      detail: UpdateText.lines([UpdateText.status(transit, l),
                                                transit.availableUpdate == nil ? transit.checkOnlineReason : nil]),
                      detailColor: transit.availableUpdate != nil ? .noticeOrange : .secondary) {
                if transit.updateState == .checking {
                    ProgressView().controlSize(.small)
                } else if let update = transit.availableUpdate {
                    Link(destination: update.page) {
                        Label(l.t("Download"), systemImage: "arrow.up.right.square")
                    }
                } else {
                    CheckOrStartButton(title: l.t("Check Now")) { transit.checkForUpdates() }
                }
            }
        } header: {
            // "Check for Updates…" (the app menu, and an operator's long problem) opens Settings here (SettingsJump)
            Text(l.t("Updates"))
                .settingsSectionTitle()
                .id(SettingsJump.Target.updates.id)
        }
    }
}

/// A "Check … Now" button: grayed out, with the reason in its hover text, when it can't go online; on standby (outside Demo mode,
/// with the network allowed) a Start button in its place, which turns the app on like the switch in the main window. Once on,
/// the check button is back. The reason is written beside it by each place that has one (checkOnlineReason)
struct CheckOrStartButton: View {
    @EnvironmentObject var transit: TransitModel
    let title: String
    var small = false
    let action: () -> Void

    var body: some View {
        Group {
            if transit.startsToCheck {
                Button(transit.l10n.t("Start")) { transit.start() }
            } else {
                Button(title, action: action)
                    .disabled(!transit.canCheckOnline)
                    .help(transit.checkOnlineHelp)
            }
        }
        .appButtonStyle()
        .controlSize(small ? .small : .regular)
    }
}

/// Row shown when a new version exists: clicking opens the download page (main window sidebar and menu bar panel). Shows nothing when there is no new version.
struct UpdateAvailableLink: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        if let update = transit.availableUpdate {
            let l = transit.l10n
            Link(destination: update.page) {
                Label(l.f("Version %@ is available", update.version), systemImage: "arrow.down.circle.fill")
                    .lineLimit(1)
            }
            .font(.scaled(.caption))
            .help(l.t("Opens the download page. Download it and drag it into Applications."))
        }
    }
}

/// Status text for update checks (same in Settings and the menu bar)
enum UpdateText {
    /// The lines under the version, each once: on standby or in Demo mode the status and the reason the button is gray are the
    /// same sentence
    static func lines(_ texts: [String?]) -> String {
        var seen = Set<String>()
        return texts.compactMap { $0 }.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    @MainActor static func status(_ transit: TransitModel, _ l: UIText) -> String {
        switch transit.updateState {
        case .available(let r): return l.f("Version %@ is available. Download it and drag it into Applications.", r.version)
        case .checking: return l.t("Checking…")
        case .upToDate: return l.t("You have the latest version.") + checked(transit, l)
        case .noRelease: return l.t("No version has been published yet.") + checked(transit, l)
        case .failed: return l.t("Couldn't check for updates. Check your network.")
        case .idle:
            if transit.isDemo { return l.t("Not available in Demo mode.") }
            if !transit.isActive { return l.t("Turn Catch My Train on to check.") }
            return transit.lastUpdateCheck.map { l.f("Last checked %@", l.day($0, timeZone: l.macZone)) } ?? l.t("Not checked yet.")
        }
    }

    @MainActor private static func checked(_ transit: TransitModel, _ l: UIText) -> String {
        transit.lastUpdateCheck.map { " " + l.f("Last checked %@", l.day($0, timeZone: l.macZone)) } ?? ""
    }
}
