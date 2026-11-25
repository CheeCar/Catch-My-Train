import CatchText
import SwiftUI
import TransitCore

/// Settings, Reminders page (leave-by reminders): how long before the latest time to set off the notification comes, whether
/// macOS lets the app send notifications, and the reminders set (the same rows as the count's list, ReminderRows), with the
/// button that cancels them all. A reminder is set in its train's details (TrainDetailsPopover), and cancelled there or here.
struct RemindersSettingsPage: View {
    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The form watches the reminders: the main model doesn't publish their changes
        RemindersSettingsForm(reminders: transit.reminders, l: transit.l10n, setLead: { transit.setReminderLead($0) },
                              open: { reminder in
                                  transit.showReminderStation(reminder)
                                  MainWindow.open(with: openWindow)
                              })
        // Another page, or Settings closed: a lead still waiting for the arrows to stand still applies now
        .onDisappear { transit.applyReminderLeadNow() }
    }
}

struct RemindersSettingsForm: View {
    @ObservedObject var reminders: LeaveReminderCenter
    var l: UIText
    /// The lead chosen (the model saves it and moves the reminders that wait)
    var setLead: (Int) -> Void
    /// A click on a reminder: its station in the main window
    var open: ((LeaveReminder) -> Void)?
    /// A number typed into the lead's field that was changed to fit (a fraction, or outside 1 to 30), said under it until the
    /// next change, as on the Search range page (SettingNumberRow)
    @State private var adjusted: (title: String, value: Double)?
    @State private var fitCounts: [String: Int] = [:]

    var body: some View {
        let count = reminders.waiting().count
        SettingsPageForm(.reminders) {
            SettingsSection(l.t("Reminders")) {
                // Whole minutes, 1 to 30: a number and the up and down arrows, as on the Search range page; a fraction or a number
                // outside the range typed in becomes the nearest whole minute that can be used, and the row says so
                SettingNumberRow(title: l.t("Remind me before I have to leave (min)"),
                                 value: Binding(get: { Double(reminders.leadMinutes) }, set: { setLead(Int($0.rounded())) }),
                                 range: Double(LeaveReminders.leadRange.lowerBound)...Double(LeaveReminders.leadRange.upperBound),
                                 step: 1, l: l, note: nil, adjusted: $adjusted, fitCounts: $fitCounts) { l.f("%@ min", $0) }
                Text(l.t("To set a reminder, click a departure that says “Can try”. The notification comes this long before the latest time to leave."))
                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StatusRow(icon: "bell.badge", title: l.t("Notifications")) {
                    switch reminders.permission {
                    case .allowed:
                        Label(l.t("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.noticeGreen)
                    case .off:
                        Label(l.t("Off"), systemImage: "bell.slash.fill").foregroundStyle(Color.noticeOrange)
                    case .notAsked:
                        Text(l.t("Not asked yet"))
                    case .unknown:
                        // Not read from the system yet: a moment at most
                        EmptyView()
                    }
                } detail: {
                    switch reminders.permission {
                    case .off:
                        Text(l.t("Notifications are off for Catch My Train."))
                            .foregroundStyle(Color.noticeOrange)
                    case .notAsked:
                        Text(l.t("macOS asks the first time you set a reminder."))
                    case .allowed:
                        // A Focus can keep the banner from showing: where to change that
                        Text(l.t("A Focus can hide the banner. To always see it, allow Catch My Train in that Focus in System Settings."))
                    case .unknown:
                        EmptyView()
                    }
                }
                if reminders.permission == .off {
                    Button(l.t("Open Notification Settings")) { SystemSettingsPage.notifications.open() }
                        .appButtonStyle(.bordered)
                }
            }
            // Each one, soonest first: a click shows its station, its button cancels it; "No reminders set." when there is none
            SettingsSection(l.t("Reminders set")) {
                ReminderRows(reminders: reminders, l: l, open: open)
                if count > 0 {
                    CancelAllRemindersButton(l: l) { reminders.cancelAll() }
                }
            }
        }
        // The permission may have been changed in System Settings since it was last read
        .task { await reminders.readPermission() }
    }
}
