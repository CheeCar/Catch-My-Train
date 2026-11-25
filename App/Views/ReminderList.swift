import AppKit
import CatchText
import SwiftUI
import TransitCore

/// How many leave-by reminders are set, as a bell and a number, in the menu bar panel's top row and the main window's toolbar,
/// only while there are some. No sentence around the number, so nothing is put in the plural in 23 languages; the
/// hover text and screen readers say "Reminders set" with it. A click lists them (ReminderList).
/// It watches the reminders, not the main model, which doesn't publish their changes.
struct ReminderCountButton: View {
    @ObservedObject var reminders: LeaveReminderCenter
    var l: UIText
    /// A click on one reminder of the list: its station (TransitModel.showReminderStation, and the main window)
    var open: (LeaveReminder) -> Void
    @State private var showsList = false
    // A popover is a window of its own: it gets the language and the direction of the window the button is in
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let count = reminders.waiting().count
        if count > 0 {
            Button {
                showsList.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                    Text(l.number(Double(count)))
                }
                .font(.scaled(.callout).weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help(l.t("Reminders set"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(l.t("Reminders set")))
            .accessibilityValue(Text(l.number(Double(count))))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showsList.toggle() }
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                ReminderList(reminders: reminders, l: l, open: { reminder in
                    showsList = false
                    open(reminder)
                })
                .padding(12)
                .frame(width: (340 * TextScale.factor).rounded())
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
            }
        }
    }
}

/// The reminders still to come, soonest first, with "Cancel All Reminders…" above them: the count's popover. Settings, Reminders
/// shows the same rows (ReminderRows) in its own box
struct ReminderList: View {
    @ObservedObject var reminders: LeaveReminderCenter
    var l: UIText
    var open: ((LeaveReminder) -> Void)?

    var body: some View {
        // The rows scroll only on a screen too short for them (up to 10 reminders, the largest text): the popover hangs under the
        // count, near the screen's top
        ReminderListContent(list: reminders.waiting(), l: l, open: open,
                            cancel: { reminders.cancel($0) }, cancelAll: { reminders.cancelAll() },
                            tallestRows: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 220))
    }
}

/// What ReminderList shows, from values only
struct ReminderListContent: View {
    var list: [LeaveReminder]
    var l: UIText
    var open: ((LeaveReminder) -> Void)?
    var cancel: (LeaveReminder) -> Void = { _ in }
    var cancelAll: () -> Void = {}
    /// The tallest the rows may be before they scroll (the popover); nil shows them all
    var tallestRows: CGFloat?
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The button beside the title; where both don't fit (its words are long in some languages), under it: never cut off
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    cancelAllButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    cancelAllButton
                }
            }
            if let tallestRows, !list.isEmpty {
                ScrollView {
                    ReminderRowsContent(list: list, l: l, open: open, cancel: cancel)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            if abs(h - rowsHeight) > 0.5 { rowsHeight = h }
                        }
                }
                .frame(height: min(max(rowsHeight, 1), tallestRows))
            } else {
                ReminderRowsContent(list: list, l: l, open: open, cancel: cancel)
            }
        }
    }
}

extension ReminderListContent {
    private var title: some View {
        Text(l.t("Reminders"))
            .font(.scaled(.headline))
    }

    private var cancelAllButton: some View {
        CancelAllRemindersButton(l: l, cancelAll: cancelAll)
            .disabled(list.isEmpty)
    }
}

/// "Cancel All Reminders…": asks first, as "Clear Recent Places…" does, since it can't be undone (the popover and Settings,
/// Reminders)
struct CancelAllRemindersButton: View {
    var l: UIText
    var cancelAll: () -> Void
    @State private var asking = false

    var body: some View {
        Button(l.t("Cancel All Reminders…")) { asking = true }
            .appButtonStyle(.bordered)
            .alert(l.t("Cancel all reminders?"), isPresented: $asking) {
                Button(l.t("Keep Reminders"), role: .cancel) {}
                Button(l.t("Cancel All"), role: .destructive) { cancelAll() }
            }
    }
}

/// One row for each reminder still to come, soonest first; "No reminders set." when there is none
struct ReminderRows: View {
    @ObservedObject var reminders: LeaveReminderCenter
    var l: UIText
    var open: ((LeaveReminder) -> Void)?

    var body: some View {
        ReminderRowsContent(list: reminders.waiting(), l: l, open: open, cancel: { reminders.cancel($0) })
    }
}

struct ReminderRowsContent: View {
    var list: [LeaveReminder]
    var l: UIText
    var open: ((LeaveReminder) -> Void)?
    var cancel: (LeaveReminder) -> Void

    var body: some View {
        if list.isEmpty {
            Text(l.t("No reminders set."))
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { Divider() }
                    ReminderRow(reminder: reminder, l: l,
                                open: open.map { open in { open(reminder) } },
                                cancel: { cancel(reminder) })
                }
            }
        }
    }
}

/// A reminder: its line's badge, its train ("12:11 PM · Times Sq-42 St · To Bay Ridge-95 St"), then in blue when its
/// notification comes and the latest time to leave; at the end a button that cancels it (no question first, as Cancel All).
/// A click on the rest shows its station (open)
struct ReminderRow: View {
    var reminder: LeaveReminder
    var l: UIText
    var open: (() -> Void)?
    var cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let open {
                // A button, so the keyboard reaches it too, not only the mouse and screen readers. Said as one: the train, then
                // the times written plainly
                Button(action: open) {
                    train.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(l.reminderTrainLine(reminder)))
                .accessibilityValue(Text(l.reminderTimes(reminder, spoken: true)))
            } else {
                train
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(l.reminderTrainLine(reminder)))
                    .accessibilityValue(Text(l.reminderTimes(reminder, spoken: true)))
            }
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.scaled(.body))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(l.t("Cancel Reminder"))
            .accessibilityLabel(Text(l.t("Cancel Reminder")))
        }
        .padding(.vertical, 6)
    }

    /// Its line's badge, the train, and when the notification comes
    private var train: some View {
        HStack(alignment: .top, spacing: 8) {
            RouteBadge(route: reminder.route, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.reminderTrainLine(reminder))
                    .font(.scaled(.callout).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Label(l.reminderTimes(reminder), systemImage: "bell.fill")
                    .font(.scaled(.caption).weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
