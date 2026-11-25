import Foundation

/// A leave-by reminder set on one train: a notification a few minutes before the latest time to set off for it.
///
/// Only a "Can try" train can have one. Every time here is in the trains' time (server time, see ClockSkew), except `fireAt`,
/// which is on this Mac's clock, as the system fires notifications by it.
/// The walk is the one of the moment the reminder was set: changing the place afterwards doesn't move the reminder.
/// The system keeps the pending notifications; the app keeps nothing of its own (see `encoded`).
public struct LeaveReminder: Codable, Hashable, Identifiable, Sendable {
    /// The train's id at this station (Arrival.id): the same between refreshes
    public var id: String
    public var stationID: String
    /// The station's and the route's names as shown when the reminder was set, for the notification
    public var stationName: String
    public var route: String
    public var routeName: String
    public var direction: Direction
    /// The train's time at the station: the one shown, and the one the latest time to set off is counted back from
    public var trainTime: Date
    /// Whether that time is a realtime prediction or the timetable's
    public var source: ArrivalSource
    /// The station's own time zone when it has one (Arrival.timeZone)
    public var timeZone: String?
    /// Walk + station entry time (seconds), as when the reminder was set
    public var accessSeconds: TimeInterval
    /// The slack "Can try" needs without the timetable's part: safety buffer + the walk's uncertainty, as when the reminder was set
    public var baseSlackSeconds: TimeInterval
    /// The latest time to set off, rounded down to the minute (the same as CatchEvaluation.latestLeave)
    public var leaveBy: Date
    /// How long before `leaveBy` the notification comes (seconds)
    public var leadSeconds: TimeInterval
    /// When the notification fires, on this Mac's clock
    public var fireAt: Date
    /// When the train's time was last checked against fresh data
    public var checkedAt: Date
    /// The next train of the same route and direction at this station when last checked. While that one is still listed and
    /// this one isn't, this one is gone; when neither is, the data may only have changed its ids (see LeaveReminders.train)
    public var followingID: String?

    /// When the notification comes, in the trains' time: what the app shows next to the train ("Reminder at …")
    public var remindAt: Date { leaveBy.addingTimeInterval(-leadSeconds) }

    /// The station's own time zone, when it has one
    public var stationTimeZone: TimeZone? { timeZone.flatMap(TimeZone.init(identifier:)) }

    /// The name the system knows this reminder's pending notification by
    public var notificationID: String { Self.notificationPrefix + id }
    /// The name of the one notification that says this reminder is over (too late, cancelled, no longer listed) or that is
    /// sent at once in its place: apart from `notificationID`, so taking the pending one away never takes this one with it
    public var noticeID: String { Self.noticePrefix + id }
    public static let notificationPrefix = "leave-reminder."
    public static let noticePrefix = "leave-notice."

    /// As one string, for the pending notification's own data; nil if it can't be written
    public var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// From `encoded`; nil if it isn't one (another version's, or not a reminder): such a notification is left alone
    public init?(encoded: String) {
        guard let data = encoded.data(using: .utf8), let value = try? JSONDecoder().decode(LeaveReminder.self, from: data) else {
            return nil
        }
        self = value
    }

    init(id: String, stationID: String, stationName: String, route: String, routeName: String, direction: Direction,
         trainTime: Date, source: ArrivalSource, timeZone: String?, accessSeconds: TimeInterval,
         baseSlackSeconds: TimeInterval, leaveBy: Date, leadSeconds: TimeInterval, fireAt: Date, checkedAt: Date,
         followingID: String? = nil) {
        self.id = id
        self.stationID = stationID
        self.stationName = stationName
        self.route = route
        self.routeName = routeName
        self.direction = direction
        self.trainTime = trainTime
        self.source = source
        self.timeZone = timeZone
        self.accessSeconds = accessSeconds
        self.baseSlackSeconds = baseSlackSeconds
        self.leaveBy = leaveBy
        self.leadSeconds = leadSeconds
        self.fireAt = fireAt
        self.checkedAt = checkedAt
        self.followingID = followingID
    }
}

/// The rules of leave-by reminders. Pure functions: the same input always gives the same output.
/// `now` is this Mac's clock; the clock offset is an input (callers that leave it out get the app's measured one).
public enum LeaveReminders {
    /// At most this many reminders at a time
    public static let maxCount = 10
    /// How many minutes before the latest time to set off the notification comes: the range and the default
    public static let leadRange = 1...30
    public static let defaultLeadMinutes = 2
    /// A reminder this close to firing (or past it) is left to the system: nothing about it is changed any more
    public static let handsOffSeconds: TimeInterval = 15
    /// "Checked at" in a pending notification is brought up to date once it is this old
    static let stampEverySeconds: TimeInterval = 120
    /// When the data changed its ids (say between the timetable and realtime, which give one train different ids), a train of
    /// the same route and direction at the same station within this much of the reminder's train is taken as the same train
    static let sameTrainSeconds: TimeInterval = 120

    /// The saved lead, within the range; the default when nothing is saved yet
    public static func leadMinutes(_ saved: Int?) -> Int {
        guard let saved else { return defaultLeadMinutes }
        return min(max(saved, leadRange.lowerBound), leadRange.upperBound)
    }

    /// Why a reminder can't be set on a train
    public enum Refusal: Error, Equatable, Sendable {
        /// Demo mode's made-up trains
        case demo
        /// Not "Can try" (or no longer, by now)
        case notCanTry
        /// This train already has one
        case alreadySet
        /// There are `maxCount` already
        case full
        /// Less than the lead is left before the latest time to set off (or that time has just passed): the answer is "leave now"
        case leaveNow
        /// Apple Maps is still being asked for the walking route to its station: the walk so far is the straight line's guess,
        /// often shorter, and a reminder keeps the walk it was set with. A moment only, until the route comes or can't
        case walkComing
    }

    /// A reminder for this train, or why it can't have one.
    public static func make(from evaluation: CatchEvaluation, stationName: String, routeName: String, leadMinutes: Int,
                            existing: [LeaveReminder], now localNow: Date, clockOffset: TimeInterval = ClockSkew.current,
                            walkComing: Bool = false) -> Result<LeaveReminder, Refusal> {
        let arrival = evaluation.arrival
        guard arrival.source != .mock else { return .failure(.demo) }
        guard evaluation.verdict == .canTry, let trainTime = arrival.arrivalTime else { return .failure(.notCanTry) }
        guard !existing.contains(where: { $0.id == arrival.id }) else { return .failure(.alreadySet) }
        guard existing.count < maxCount else { return .failure(.full) }
        let now = localNow.addingTimeInterval(clockOffset)
        let access = evaluation.totalAccessSeconds
        let base = evaluation.requiredSlackSeconds - timetableSlack(arrival)
        let latest = trainTime.addingTimeInterval(-access - evaluation.requiredSlackSeconds)
        // The verdict was worked out a moment ago: by now it may be too late. The list will say so at its next look;
        // until then the answer is the one of a train with no time left for a reminder
        guard latest >= now else { return .failure(.leaveNow) }
        let lead = TimeInterval(self.leadMinutes(leadMinutes)) * 60
        let leaveBy = minute(latest)
        let fire = leaveBy.addingTimeInterval(-lead)
        guard fire > now else { return .failure(.leaveNow) }
        guard !walkComing else { return .failure(.walkComing) }
        return .success(LeaveReminder(
            id: arrival.id, stationID: arrival.stationID, stationName: stationName, route: arrival.route, routeName: routeName,
            direction: arrival.direction, trainTime: trainTime, source: arrival.source,
            timeZone: arrival.timeZone, accessSeconds: access, baseSlackSeconds: base, leaveBy: leaveBy, leadSeconds: lead,
            fireAt: fire.addingTimeInterval(-clockOffset), checkedAt: now))
    }

    /// What a train's details say about a reminder
    public enum Offer: Equatable, Sendable {
        /// It has this one
        case isSet(LeaveReminder)
        /// It can have this one
        case canSet(LeaveReminder)
        /// It can't have one: why (never alreadySet)
        case refused(Refusal)
    }

    /// The train's own reminder if it has one; otherwise the one it would get, or why it can't have one
    public static func offer(for evaluation: CatchEvaluation, stationName: String, routeName: String, leadMinutes: Int,
                             existing: [LeaveReminder], now localNow: Date, clockOffset: TimeInterval = ClockSkew.current,
                             walkComing: Bool = false) -> Offer {
        if let mine = existing.first(where: { $0.id == evaluation.arrival.id }) { return .isSet(mine) }
        switch make(from: evaluation, stationName: stationName, routeName: routeName, leadMinutes: leadMinutes,
                    existing: existing, now: localNow, clockOffset: clockOffset, walkComing: walkComing) {
        case .success(let reminder): return .canSet(reminder)
        case .failure(let why): return .refused(why)
        }
    }

    /// What to do with a pending reminder after a refresh
    public enum Change: Equatable, Sendable {
        /// Nothing
        case keep
        /// Replace the pending notification with this one, silently: the train's time, the lead or the clock offset changed,
        /// or only what the reminder remembers ("checked at", the train after it) is brought up to date
        case reschedule(LeaveReminder)
        /// The train is earlier and less than the lead is left: replace the pending notification with this one, which fires now
        case fireNow(LeaveReminder)
        /// Setting off now is no longer "Can try": tell once and remove the reminder. The reminder given has the train's time
        /// as just read (it is why it's too late; its leave-by and notification times are the old ones and no longer hold).
        /// tight: it may still just work
        case tooLate(LeaveReminder, tight: Bool)
        /// The train is cancelled, or no longer listed while the one after it still is: tell once and remove the reminder
        case gone(cancelled: Bool)
    }

    /// Checks one pending reminder against the trains just loaded (any stations; the ones of other stations are ignored).
    ///
    /// Without fresh word of its train (its station isn't loaded, the data is stale, or neither the train nor the one after it
    /// is listed) the train's time stays as it was, and only the lead and the clock offset are followed.
    public static func reconcile(_ reminder: LeaveReminder, arrivals: [Arrival], leadMinutes: Int, staleAfter: TimeInterval,
                                 now localNow: Date, clockOffset: TimeInterval = ClockSkew.current) -> Change {
        // About to fire, or fired already: it's the system's now. Changing it here could fire it twice or not at all
        guard reminder.fireAt.timeIntervalSince(localNow) > handsOffSeconds else { return .keep }
        let now = localNow.addingTimeInterval(clockOffset)
        let lead = TimeInterval(self.leadMinutes(leadMinutes)) * 60
        // Fresh trains of this reminder's route and direction at its station
        let service = arrivals.filter {
            $0.stationID == reminder.stationID && $0.route == reminder.route && $0.direction.code == reminder.direction.code
                && $0.source != .mock && ($0.source != .realtime || now.timeIntervalSince($0.updatedAt) <= staleAfter)
        }

        var updated = reminder
        var fresh = false
        if let train = train(of: reminder, in: service) {
            if train.status == .cancelled { return .gone(cancelled: true) }
            if let time = train.arrivalTime {
                let required = reminder.baseSlackSeconds + timetableSlack(train)
                let latest = time.addingTimeInterval(-reminder.accessSeconds - required)
                updated.id = train.id
                updated.trainTime = time
                updated.source = train.source
                if latest < now {
                    updated.checkedAt = now
                    return .tooLate(updated, tight: time.addingTimeInterval(-reminder.accessSeconds) >= now)
                }
                updated.leaveBy = minute(latest)
                updated.followingID = service
                    .filter { $0.id != train.id && $0.status != .cancelled && ($0.arrivalTime ?? .distantPast) >= time }
                    .min { ($0.arrivalTime ?? .distantFuture, $0.id) < ($1.arrivalTime ?? .distantFuture, $1.id) }?.id
                fresh = true
            }
        } else if let following = reminder.followingID, service.contains(where: { $0.id == following }) {
            return .gone(cancelled: false)
        }

        updated.leadSeconds = lead
        if fresh { updated.checkedAt = now }
        let fire = updated.leaveBy.addingTimeInterval(-lead)
        if fire <= now {
            updated.fireAt = localNow
            return .fireNow(updated)
        }
        updated.fireAt = fire.addingTimeInterval(-clockOffset)
        // Realtime times move by seconds with every refresh: only a change the notification would show counts
        let moved = abs(updated.fireAt.timeIntervalSince(reminder.fireAt)) >= 1
            || updated.id != reminder.id
            || updated.followingID != reminder.followingID
            || minute(updated.trainTime) != minute(reminder.trainTime)
            || updated.leaveBy != reminder.leaveBy
        if moved { return .reschedule(updated) }
        if fresh, now.timeIntervalSince(reminder.checkedAt) >= stampEverySeconds {
            var stamped = reminder
            stamped.checkedAt = now
            return .reschedule(stamped)
        }
        return .keep
    }

    /// Whether the system lets the app send notifications
    public enum Permission: Equatable, Sendable {
        /// Not read from the system yet
        case unknown
        /// macOS hasn't asked the person yet: it asks the first time a reminder is set
        case notAsked
        /// Off for the app in System Settings
        case off
        case allowed
    }

    /// What a train's details show about its reminder
    public enum Details: Equatable, Sendable {
        /// The train has this one: its times, and the button that cancels it. notificationsOff: as things are the system
        /// won't show it
        case isSet(LeaveReminder, notificationsOff: Bool)
        /// It can have this one: the button that sets it. failed: the last try to set it wasn't taken by the system
        case canSet(LeaveReminder, failed: Bool)
        /// It could have this one, but macOS's question whether the app may send notifications is open: answer that first
        case asking(LeaveReminder)
        /// It could have this one, but notifications are off for the app: says so, with a button that opens their settings
        case notificationsOff(LeaveReminder)
        /// It can't have one: why
        case refused(Refusal)
    }

    /// What the details show, from what the train could have (`offer`) and the state of notifications on this Mac.
    /// - Parameters:
    ///   - asking: macOS's question is on screen
    ///   - failed: the last try to set this train's reminder wasn't taken by the system
    public static func details(_ offer: Offer, permission: Permission, asking: Bool, failed: Bool) -> Details {
        switch offer {
        case .isSet(let reminder):
            return .isSet(reminder, notificationsOff: permission == .off)
        case .refused(let why):
            return .refused(why)
        case .canSet(let reminder):
            if asking { return .asking(reminder) }
            if permission == .off { return .notificationsOff(reminder) }
            return .canSet(reminder, failed: failed)
        }
    }

    /// Whether the train's time, as a notification shows it, moved between two states of one reminder: its minute, or the
    /// minute to leave by
    public static func timeChanged(from old: LeaveReminder, to new: LeaveReminder) -> Bool {
        minute(old.trainTime) != minute(new.trainTime) || old.leaveBy != new.leaveBy
    }

    /// The reminders still waiting to fire, soonest first: a notification the system has already shown is no reminder any more
    public static func waiting(_ reminders: [LeaveReminder], now localNow: Date) -> [LeaveReminder] {
        reminders.filter { $0.fireAt > localNow }.sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
    }

    /// When the reminders still to come next become one fewer (the soonest one's notification comes), on this Mac's clock; nil
    /// when none is still to come. What counts or lists them is redrawn then (LeaveReminderCenter)
    public static func nextFire(_ reminders: [LeaveReminder], now localNow: Date) -> Date? {
        reminders.map(\.fireAt).filter { $0 > localNow }.min()
    }

    /// How long the app stays on for these reminders instead of going on standby by itself (ActivityState.holding): until the
    /// last of them has to leave. Until then a reminder follows its train, and a click on its notification finds the app with
    /// times still fresh. nil when none is left to leave for. In this Mac's time, as ActivityState goes by: a reminder's leaveBy
    /// is the trains' time, clockOffset (ClockSkew) ahead of it
    public static func holdUntil(_ reminders: [LeaveReminder], now localNow: Date,
                                 clockOffset: TimeInterval = ClockSkew.current) -> Date? {
        reminders.map { $0.leaveBy.addingTimeInterval(-clockOffset) }.filter { $0 > localNow }.max()
    }

    /// The reminder's train among the fresh trains of its service: by its id. When neither it nor the train after it is
    /// listed, the data may have changed its ids (the timetable and realtime give one train different ids; a new timetable may
    /// too): then the nearest train within sameTrainSeconds is taken as the same one. While the train after it is still
    /// listed the ids didn't change, and no other train is taken: that would move the reminder to another train
    private static func train(of reminder: LeaveReminder, in service: [Arrival]) -> Arrival? {
        if let same = service.first(where: { $0.id == reminder.id }) { return same }
        if let following = reminder.followingID, service.contains(where: { $0.id == following }) { return nil }
        func gap(_ a: Arrival) -> TimeInterval {
            a.arrivalTime.map { abs($0.timeIntervalSince(reminder.trainTime)) } ?? .infinity
        }
        guard let nearest = service.filter({ $0.status != .cancelled }).min(by: { (gap($0), $0.id) < (gap($1), $1.id) }),
              gap(nearest) <= sameTrainSeconds else { return nil }
        return nearest
    }

    /// The extra slack a timetable time needs (the same as CatchEvaluator adds)
    static func timetableSlack(_ arrival: Arrival) -> TimeInterval {
        arrival.isTimetableTime ? CatchEvaluator.scheduledUncertaintySeconds : 0
    }

    /// Rounded down to the minute, so setting off at the minute shown is never too late
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// The lead the waiting reminders follow, apart from the one chosen in Settings: a new choice counts once the arrows have stood still
/// for `settleSeconds`, or at once when the page is left. Each value passed on the way would count otherwise, and one longer than the
/// time a reminder has left sends its notification at once (LeaveReminders.reconcile), which going back can't undo. New reminders
/// take the chosen lead as before
public struct ReminderLead: Equatable, Sendable {
    public static let settleSeconds: TimeInterval = 1.5

    /// The one chosen (shown in Settings)
    public private(set) var chosen: Int
    /// The one the waiting reminders follow
    public private(set) var applied: Int
    /// When the choice last changed, while it waits to apply
    private var changedAt: Date?

    public init(_ minutes: Int) {
        chosen = minutes
        applied = minutes
    }

    /// A new choice at `now`. Going back to the one that applies leaves nothing waiting
    public mutating func choose(_ minutes: Int, now: Date) {
        chosen = minutes
        changedAt = minutes == applied ? nil : now
    }

    /// When the choice is due to apply; nil when nothing waits
    public var dueAt: Date? { changedAt.map { $0.addingTimeInterval(Self.settleSeconds) } }

    /// Applies the choice when it has stood still long enough at `now`, or at once with nil. Returns whether `applied` changed
    public mutating func apply(now: Date?) -> Bool {
        guard let due = dueAt else { return false }
        if let now, now < due { return false }
        changedAt = nil
        guard applied != chosen else { return false }
        applied = chosen
        return true
    }
}
