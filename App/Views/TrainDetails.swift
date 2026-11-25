import AppKit
import CatchText
import SwiftUI
import TransitCore

/// A train's details, shown below its row when the row is clicked (or with Space when it has the keyboard): the numbers
/// behind its verdict, a few lines, too many for a hover text, then its leave-by reminder.
/// It watches the reminders, not the main model: what it needs of the train comes with the row.
struct TrainDetailsPopover: ViewModifier {
    var train: BoardTrain
    var l: UIText
    @Binding var isPresented: Bool
    @ObservedObject var reminders: LeaveReminderCenter
    // A popover is a window of its own: it gets the language and the direction of the window its row is in
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    /// "Directions" to the train's own station (set on the station page; nil elsewhere, and with no button)
    @Environment(\.directions) private var directions
    /// The stations whose walking route Apple Maps is being asked for now (set on the station page)
    @Environment(\.walkRoutesComing) private var walkRoutesComing

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
            let e = train.evaluation
            let station = train.station.name
            let route = FerryFeed.spokenRouteName(train.route)
            let target = train.station.coordinate
            let walk = directions.flatMap { d in d.offers(target) ? d : nil }
            TrainDetailsCard(
                lines: TrainDetails.lines(train, l),
                leaveBy: e.latestLeave, timeZone: e.arrival.stationTimeZone,
                reminder: reminders.details(for: e, stationName: station, routeName: route,
                                            walkComing: e.walk.source != .route && walkRoutesComing.contains(train.station.id)),
                l: l,
                set: { reminders.set(for: e, stationName: station, routeName: route, l: l) },
                cancel: { reminders.cancel($0) },
                directions: walk.map { d in { d.open(to: target, name: station) } },
                mapName: walk?.mapName ?? "")
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
        }
    }
}

private struct WalkRoutesComingKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    /// The stations whose walking route Apple Maps is being asked for now (TransitModel.routesAsked): set by the main window,
    /// empty anywhere else. Until it comes or can't, a train there can't have a reminder yet (LeaveReminders.Refusal.walkComing)
    var walkRoutesComing: Set<String> {
        get { self[WalkRoutesComingKey.self] }
        set { self[WalkRoutesComingKey.self] = newValue }
    }
}

enum TrainDetails {
    /// The numbers behind a train's verdict, one to a line
    static func lines(_ train: BoardTrain, _ l: UIText) -> String {
        let e = train.evaluation
        let w = e.walk
        var lines = [
            l.f("Walk: %1$@, %2$@ (%3$@)", l.minutes(w.walkSeconds), l.distance(w.routeMeters ?? w.straightLineMeters),
                l.walkSource(w.source)),
            l.f("Spare time: %1$@ (needs %2$@)", l.slack(e.slackSeconds), l.minutes(e.requiredSlackSeconds)),
            l.f("Prediction updated at %@", l.timeWithSeconds(e.arrival.updatedAt)),
        ]
        // The time from reaching the stop to boarding, which the spare time counts: so the lines add up (none for MTA's buses)
        if let boarding = l.boardingLine(seconds: train.station.entranceToPlatformSeconds, routes: [train.route]) { lines.insert(boarding, at: 1) }
        if !e.notes.isEmpty { lines.append(e.notes.map(l.note).sorted().joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

/// What the details show, from values only.
/// Below the numbers, under a line: the reminder (ReminderBlock), with "Directions" beside its button.
struct TrainDetailsCard: View {
    var lines: String
    /// The latest time to set off, for a train that says "Can try" (nil for the others), and the station's own time zone
    /// when it has one
    var leaveBy: Date?
    var timeZone: TimeZone?
    var reminder: LeaveReminders.Details
    var l: UIText
    var set: () -> Void = {}
    var cancel: (LeaveReminder) -> Void = { _ in }
    /// Opens the walk to the train's station in a map (DirectionsAction); nil: no "Directions" button
    var directions: (() -> Void)? = nil
    /// The map it opens in, for the button's hover text
    var mapName = ""

    var body: some View {
        // As wide as its widest line wants, up to 360 points at standard text size (wider with larger text, like the list of
        // reminders); a longer sentence wraps, and the card is as tall as the wrapped lines
        UpToWidth(maxWidth: (360 * TextScale.factor).rounded()) {
            VStack(alignment: .leading, spacing: 10) {
                Text(lines)
                    .font(.scaled(.callout))
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ReminderBlock(leaveBy: leaveBy, timeZone: timeZone, reminder: reminder, l: l, set: set, cancel: cancel,
                              directions: directions, mapName: mapName)
            }
        }
        .padding(12)
    }
}

/// The reminder part of a train's details (LeaveReminders.Details): when to leave by, then the button that sets a reminder,
/// or the reminder that is set with the button that cancels it, or a sentence that says why there can't be one.
/// "Directions", for any train, sits beside the reminder's button (under it when the two don't fit side by side), or on its
/// own at the end when there's no such button.
/// A time is kept on one line where it is shown and given plainly to a screen reader (the marks that keep it whole sit
/// between its characters).
struct ReminderBlock: View {
    var leaveBy: Date?
    var timeZone: TimeZone?
    var reminder: LeaveReminders.Details
    var l: UIText
    var set: () -> Void
    var cancel: (LeaveReminder) -> Void
    var directions: (() -> Void)? = nil
    var mapName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch reminder {
            case .canSet(let r, let failed):
                leaveByLine(r)
                withDirections {
                    Button(action: set) {
                        Label(l.remindMeAt(r), systemImage: "bell")
                    }
                    .appButtonStyle(.prominent)
                    .accessibilityLabel(Text(l.remindMeAt(r, spoken: true)))
                }
                note(l.reminderLead(r))
                if failed { warning(l.t("Couldn't set the reminder. Try again.")) }
            case .isSet(let r, let notificationsOff):
                leaveByLine(r)
                Label(l.reminderAt(r), systemImage: "bell.fill")
                    .font(.scaled(.callout).weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(l.reminderAt(r, spoken: true)))
                if notificationsOff { notificationsOffLines }
                withDirections {
                    Button(l.t("Cancel Reminder")) { cancel(r) }
                        .appButtonStyle(.bordered)
                }
            case .asking(let r):
                leaveByLine(r)
                // Where macOS asks, and where its Allow is: inside Options
                note(l.t("macOS is asking whether Catch My Train may send notifications. At the top right of the screen, move the pointer over the notification, then click Options and Allow."))
                directionsAlone
            case .notificationsOff(let r):
                leaveByLine(r)
                notificationsOffLines
                directionsAlone
            case .refused(let why):
                // A "Can try" train that can't have one now: the button is there, and can't be clicked
                if let leaveBy {
                    Text(l.leaveBy(at: leaveBy, timeZone: timeZone))
                        .font(.scaled(.callout).weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(l.f("Leave by %@", l.time(leaveBy, timeZone: timeZone))))
                    withDirections {
                        Button(action: {}) {
                            Label(l.t("Remind Me"), systemImage: "bell")
                        }
                        .appButtonStyle(.bordered)
                        .disabled(true)
                    }
                }
                if let text = l.reminderRefusal(why) { note(text) }
                if leaveBy == nil { directionsAlone }
            }
        }
    }

    /// The block's button with "Directions" beside it, or under it when the two don't fit side by side
    @ViewBuilder private func withDirections<B: View>(@ViewBuilder _ button: () -> B) -> some View {
        let main = button()
        if let directions {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { main; DirectionsButton(l: l, mapName: mapName, action: directions) }
                VStack(alignment: .leading, spacing: 6) { main; DirectionsButton(l: l, mapName: mapName, action: directions) }
            }
        } else {
            main
        }
    }

    /// "Directions" on its own, when the block has no button for it to go beside
    @ViewBuilder private var directionsAlone: some View {
        if let directions { DirectionsButton(l: l, mapName: mapName, action: directions) }
    }

    private func leaveByLine(_ r: LeaveReminder) -> some View {
        Text(l.reminderLeaveBy(r))
            .font(.scaled(.callout).weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(l.reminderLeaveBy(r, spoken: true)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.scaled(.caption))
            .foregroundStyle(Color.noticeOrange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Notifications are off for the app in System Settings: says so, with the way there
    @ViewBuilder private var notificationsOffLines: some View {
        warning(l.t("Notifications are off for Catch My Train."))
        Button(l.t("Open Notification Settings")) { SystemSettingsPage.notifications.open() }
            .appButtonStyle(.bordered)
    }
}
