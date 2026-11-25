import Foundation
import TransitCore

/// The words of leave-by reminders (LeaveReminder): the lines next to a train and in its details, and the notifications.
/// A notification's texts are fixed when it is scheduled and shown later by the system, perhaps with the app on standby or
/// not running: so each one says when the train's time was last checked, and names the train in full.
extension AppText {
    /// A notification's two texts
    public struct ReminderNotice: Equatable, Sendable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// Which notification a reminder sends
    public enum ReminderNoticeKind: Equatable, Sendable {
        /// The reminder itself, scheduled for its lead before the latest time to set off
        case leave
        /// The same, sent at once because less than the lead is left (the train comes earlier, or the lead was made longer).
        /// timeChanged: the train's time moved
        case leaveNow(timeChanged: Bool)
        /// No longer "Can try", though setting off at once may still work: the reminder is over
        case tight
        /// No longer "Can try" and too late: the reminder is over. next: the next one that can be caught, when known
        case tooSoon(next: Date?)
        /// The train is cancelled: the reminder is over
        case cancelled
        /// The train is no longer in the data while the one after it still is: the reminder is over
        case notListed
    }

    /// "Reminder at 12:03 PM": on the train's row and in its details, the time kept on one line.
    /// spoken: for a screen reader, the time written plainly (the marks that keep it on one line sit between its characters)
    public func reminderAt(_ reminder: LeaveReminder, spoken: Bool = false) -> String {
        f("Reminder at %@", reminderTime(reminder.remindAt, of: reminder, spoken: spoken))
    }

    /// The button that sets this reminder: "Remind Me at 12:03 PM"
    public func remindMeAt(_ reminder: LeaveReminder, spoken: Bool = false) -> String {
        f("Remind Me at %@", reminderTime(reminder.remindAt, of: reminder, spoken: spoken))
    }

    /// "Leave by 12:05 PM" in the details of a train that has a reminder or can have one
    public func reminderLeaveBy(_ reminder: LeaveReminder, spoken: Bool = false) -> String {
        f("Leave by %@", reminderTime(reminder.leaveBy, of: reminder, spoken: spoken))
    }

    private func reminderTime(_ date: Date, of reminder: LeaveReminder, spoken: Bool) -> String {
        let text = time(date, timeZone: reminder.stationTimeZone)
        return spoken ? text : unbroken(text)
    }

    /// A reminder in the lists (the count's list, Settings): "Reminder at 12:03 PM · Leave by 12:05 PM"
    public func reminderTimes(_ reminder: LeaveReminder, spoken: Bool = false) -> String {
        dotted([reminderAt(reminder, spoken: spoken), reminderLeaveBy(reminder, spoken: spoken)])
    }

    /// Under that button: "2 min before you have to leave"
    public func reminderLead(_ reminder: LeaveReminder) -> String {
        f("%@ before you have to leave", minutes(reminder.leadSeconds))
    }

    /// Why a train can't have a reminder, in a sentence. Nil for a train that has one already (its details show that one), and
    /// while its walking route is still coming: a moment only, then the button can be clicked
    public func reminderRefusal(_ why: LeaveReminders.Refusal) -> String? {
        switch why {
        case .demo: return t("Not available in Demo mode.")
        case .notCanTry: return t("A reminder can be set only when it says “Can try”.")
        case .full:
            return f("There are already %@ reminders. Cancel one to set another.", number(Double(LeaveReminders.maxCount)))
        case .leaveNow: return t("Too close for a reminder. Leave now to try for it.")
        case .alreadySet, .walkComing: return nil
        }
    }

    /// The reminder's train on one line, as the lists show a train: "12:11 PM · Times Sq-42 St · To Bay Ridge-95 St"
    public func reminderTrainLine(_ reminder: LeaveReminder) -> String {
        dotted([time(reminder.trainTime, timeZone: reminder.stationTimeZone), reminder.stationName,
                terminal(reminder.direction) ?? direction(reminder.direction)])
    }

    /// The texts of a reminder's notification. `now`: the trains' time when it is sent (for a notification sent at once: how
    /// long is left). Times are written plainly, without the marks that keep them on one line in the app's own windows.
    /// The title says what to do and for which line ("Leave in 2 min · R": the line's name can be a long one, so it stands
    /// apart instead of inside a sentence); the first line of the body names the train, the rest says the times to go by.
    public func reminderNotice(_ reminder: LeaveReminder, _ kind: ReminderNoticeKind, now: Date) -> ReminderNotice {
        let zone = reminder.stationTimeZone
        let train = reminderTrainLine(reminder)
        func titled(_ words: String) -> String { dotted([words, reminder.routeName]) }
        func lines(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n") }
        let leaveBy = f("Leave by %@", time(reminder.leaveBy, timeZone: zone))
        let checked = f("Last checked at %@", time(reminder.checkedAt, timeZone: zone))
        let over = t("This reminder is over.")
        switch kind {
        case .leave:
            return ReminderNotice(title: titled(f("Leave in %@", minutes(reminder.leadSeconds))),
                                  body: lines([train, dotted([leaveBy, checked])]))
        case .leaveNow(let timeChanged):
            // Whole minutes still left, rounded down: "Leave in 1 min" is never said with less than a minute to go
            let left = (reminder.leaveBy.timeIntervalSince(now) / 60).rounded(.down) * 60
            let words = left >= 60 ? f("Leave in %@", minutes(left)) : t("Leave now")
            return ReminderNotice(title: titled(words),
                                  body: lines([train, dotted([leaveBy] + (timeChanged ? [t("Time changed")] : []) + [checked])]))
        case .tight:
            return ReminderNotice(title: titled(t("Now tight")),
                                  body: lines([train, sentences([t("Leave right away to try for it."), over])]))
        case .tooSoon(let next):
            let nextLine = next.map { f("Next one you can catch: %@", time($0, timeZone: zone)) } ?? ""
            return ReminderNotice(title: titled(t("Too soon to catch")), body: lines([train, nextLine, over]))
        case .cancelled:
            return ReminderNotice(title: titled(t("Cancelled")), body: lines([train, over]))
        case .notListed:
            return ReminderNotice(title: titled(t("No longer listed")), body: lines([train, over]))
        }
    }
}
