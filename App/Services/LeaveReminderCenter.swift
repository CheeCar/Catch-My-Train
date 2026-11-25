import AppKit
import CatchText
import Combine
import Foundation
import TransitCore
import UserNotifications

/// Leave-by reminders on this Mac. The rules are LeaveReminders (TransitCore) and the words AppText.reminderNotice (CatchText);
/// this is the part that talks to the system.
///
/// The system's pending notifications are the reminders: each carries its reminder in its own data (LeaveReminder.encoded), and
/// the app saves nothing of them. So they stay through quitting and updates, and fire on standby or with the app not running.
/// They are read from the system once, at launch; from then on the list here is kept in step with every change the app makes
/// (only the app changes them; one the system has shown is over, see LeaveReminders.waiting).
/// One for the whole app, as the system's notification center is. The views that show reminders watch this object, which
/// changes only when a reminder or the permission does, not the main model (a train's row doesn't watch that one).
@MainActor
final class LeaveReminderCenter: ObservableObject {
    static let shared = LeaveReminderCenter()

    /// The reminders the system holds, as far as the app knows; `waiting` leaves out the ones whose time has come
    @Published private(set) var reminders: [LeaveReminder] = [] {
        didSet {
            if reminders != oldValue, !sampling { onChange?() }
            watchNextFire()
        }
    }
    /// Called after the list changed: the model keeps the app on for the reminders still to come (TransitModel.holdForReminders)
    var onChange: (() -> Void)?
    /// Whether the system lets the app send notifications
    @Published private(set) var permission: LeaveReminders.Permission = .unknown
    /// macOS's question whether the app may send notifications is open (the first reminder is being set)
    @Published private(set) var asking = false
    /// The train whose reminder the system didn't take, until the next try
    @Published private(set) var failedID: String?
    /// How many minutes before the latest time to set off a reminder comes (Settings, Reminders): the one chosen. The reminders
    /// that wait follow it once the arrows have stood still a moment (lead, ReminderLead)
    @Published private(set) var leadMinutes: Int
    private var lead: ReminderLead

    /// The pending notifications were read from the system: until then nothing is checked or changed
    private var loaded = false
    /// Waits for the soonest reminder's notification (watchNextFire)
    private var fireTask: Task<Void, Never>?
    /// A reminder is being set (the permission, then the system taking it): a second click waits for the first
    private var setting = false
    private var activeObserver: NSObjectProtocol?

    /// Under which name a notification carries its reminder
    private static let dataKey = "reminder"

    /// The tests' host asks the system nothing and sets no reminders (TransitModel.isTestHost)
    private static var inert: Bool { TransitModel.isTestHost }


    /// Always false: the reminders listed are the system's
    var sampling: Bool {
        return false
    }

    private init() {
        let minutes = LeaveReminders.leadMinutes(SharedStore.reminderLeadMinutes)
        leadMinutes = minutes
        lead = ReminderLead(minutes)
        guard !Self.inert else { return }
        Task { await load() }
        // Back in front: the permission may have been changed in System Settings meanwhile
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.readPermission() }
        }
    }

    /// Before launch finishes (AppDelegate): the system wants to know by then who answers for the app's notifications
    static func listen() {
        guard !inert else { return }
        UNUserNotificationCenter.current().delegate = ReminderNotificationDelegate.shared
    }

    /// The reminders still to come at `now`, soonest first
    func waiting(now: Date = Date()) -> [LeaveReminder] {
        LeaveReminders.waiting(reminders, now: now)
    }

    /// When the soonest reminder's notification comes, the views that count or list the reminders still to come are told to
    /// redraw: nothing else would then (on standby nothing refreshes), and the toolbar's count stayed one too many
    private func watchNextFire() {
        fireTask?.cancel()
        fireTask = nil
        let now = Date()
        guard let next = LeaveReminders.nextFire(reminders, now: now) else { return }
        fireTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.watchNextFire()
        }
    }

    /// This train's reminder, while it is still to come (its row and its details show it)
    func reminder(for trainID: String, now: Date = Date()) -> LeaveReminder? {
        reminders.first { $0.id == trainID && $0.fireAt > now }
    }

    /// What this train's details show about its reminder (LeaveReminders.details). walkComing: Apple Maps is still being asked
    /// for the walk to its station (TransitModel.routesAsked), so it can't have one yet
    func details(for evaluation: CatchEvaluation, stationName: String, routeName: String, walkComing: Bool = false,
                 now: Date = Date()) -> LeaveReminders.Details {
        let offer = LeaveReminders.offer(for: evaluation, stationName: stationName, routeName: routeName, leadMinutes: leadMinutes,
                                         existing: waiting(now: now), now: now, walkComing: walkComing)
        return LeaveReminders.details(offer, permission: permission, asking: asking, failed: failedID == evaluation.arrival.id)
    }

    // MARK: - Reading the system's state

    /// The permission and the pending reminders, as the system has them
    func load() async {
        guard !Self.inert else { return }
        await readPermission()
        let found = await Self.pendingReminders()
        // Another version's notification that can't be read is left alone: it isn't listed, and Cancel All takes it away too
        let now = Date()
        var byID: [String: LeaveReminder] = [:]
        for reminder in found.compactMap(LeaveReminder.init(encoded:)) { byID[reminder.id] = reminder }
        let list = LeaveReminders.waiting(Array(byID.values), now: now)
        if list != reminders, !sampling { reminders = list }
        loaded = true
    }

    /// The permission as the system has it now
    func readPermission() async {
        guard !Self.inert else { return }
        let read = await Self.systemPermission()
        // While macOS's question is open the answer comes from there (see set)
        if !asking, read != permission { permission = read }
    }

    private static func systemPermission() async -> LeaveReminders.Permission {
        let status = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                done.resume(returning: settings.authorizationStatus.rawValue)
            }
        }
        // Allowed, or allowed for a while or without asking (the system's other answers): notifications can be sent
        if status == UNAuthorizationStatus.notDetermined.rawValue { return .notAsked }
        if status == UNAuthorizationStatus.denied.rawValue { return .off }
        return .allowed
    }

    /// The reminders the pending notifications carry, each as its string
    private static func pendingReminders() async -> [String] {
        let key = dataKey
        return await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                done.resume(returning: requests.compactMap { $0.content.userInfo[key] as? String })
            }
        }
    }

    /// macOS's own question, answered by the person at the Mac; it asks only the first time
    private static func askPermission() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                done.resume(returning: granted)
            }
        }
    }

    // MARK: - Setting and cancelling

    /// Sets a reminder on this train (the button in its details). The first time macOS asks whether the app may send
    /// notifications. What comes of it shows in the details: the reminder, or why there is none (LeaveReminders.details)
    func set(for evaluation: CatchEvaluation, stationName: String, routeName: String, l: UIText) {
        guard !Self.inert, !setting, !sampling else { return }
        setting = true
        failedID = nil
        Task {
            defer { setting = false }
            var state = await Self.systemPermission()
            if state == .notAsked {
                asking = true
                let allowed = await Self.askPermission()
                asking = false
                state = allowed ? .allowed : await Self.systemPermission()
            }
            if state != permission { permission = state }
            guard state == .allowed else { return }
            // Worked out again now: answering macOS's question can take a while, and the train doesn't wait
            let now = Date()
            let made = LeaveReminders.make(from: evaluation, stationName: stationName, routeName: routeName, leadMinutes: leadMinutes,
                                           existing: waiting(now: now), now: now)
            guard case .success(let reminder) = made else { return }
            let request = Self.request(reminder, .leave, id: reminder.notificationID, fireAt: reminder.fireAt, l: l, now: now)
            if await Self.add(request) {
                reminders = LeaveReminders.waiting(reminders.filter { $0.id != reminder.id } + [reminder], now: Date())
            } else {
                failedID = reminder.id
            }
        }
    }

    func cancel(_ reminder: LeaveReminder) {
        guard !Self.inert, !sampling else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])
        reminders.removeAll { $0.id == reminder.id }
        if failedID == reminder.id { failedID = nil }
    }

    /// Every pending notification of the app is a reminder, also one written by another version that the list can't show
    func cancelAll() {
        guard !Self.inert, !sampling else { return }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        if !reminders.isEmpty { reminders = [] }
        failedID = nil
    }

    /// The lead chosen in Settings, saved at once. The reminders that wait follow it once it has stood still a moment
    /// (applyLead; TransitModel.setReminderLead waits for that). save: false while settings apply in memory only
    /// (TransitModel.persistsSettings)
    func setLead(_ minutes: Int, save: Bool, now: Date = Date()) {
        let value = LeaveReminders.leadMinutes(minutes)
        guard value != leadMinutes else { return }
        leadMinutes = value
        lead.choose(value, now: now)
        if save { SharedStore.reminderLeadMinutes = value }
    }

    /// When the lead chosen is due to apply to the reminders that wait; nil when they follow it already
    var leadDueAt: Date? { lead.dueAt }

    /// The lead chosen applies to the reminders that wait, when it has stood still long enough at `now`, or at once with nil.
    /// Whether they now follow another lead (they're then checked again: TransitModel.reconcileReminders)
    func applyLead(now: Date? = Date()) -> Bool { lead.apply(now: now) }

    // MARK: - Following the trains

    /// After a refresh: each waiting reminder is checked against the trains just loaded (LeaveReminders.reconcile), and the
    /// system's notifications are changed to match: moved without a sound, sent at once, or taken away with one notification
    /// that says why. Nothing here waits for the system, so a click that cancels or sets one can't come in between.
    /// - Parameter nextCatchable: when the next one that can be caught comes, for the notification that says this one can't be
    func reconcile(arrivals: [Arrival], staleAfter: TimeInterval, l: UIText, now: Date = Date(),
                   nextCatchable: (LeaveReminder) -> Date?) {
        guard !Self.inert, loaded, !sampling else { return }
        let system = UNUserNotificationCenter.current()
        var kept: [LeaveReminder] = []
        for reminder in waiting(now: now) {
            let change = LeaveReminders.reconcile(reminder, arrivals: arrivals, leadMinutes: lead.applied, staleAfter: staleAfter, now: now)
            switch change {
            case .keep:
                kept.append(reminder)
            case .reschedule(let updated):
                // One with the same name takes the pending one's place in a single step. When the data gave the train
                // another id the name is another too: then the old one is taken away once the system has taken the new one
                // (if it doesn't, the old one stays and still rings)
                let old = updated.notificationID != reminder.notificationID ? reminder.notificationID : nil
                Self.addQuietly(Self.request(updated, .leave, id: updated.notificationID, fireAt: updated.fireAt, l: l, now: now),
                                replacing: old)
                kept.append(updated)
            case .fireNow(let updated):
                system.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])
                let timeChanged = LeaveReminders.timeChanged(from: reminder, to: updated)
                Self.addQuietly(Self.request(updated, .leaveNow(timeChanged: timeChanged), id: updated.noticeID, fireAt: nil, l: l, now: now))
            case .tooLate(let told, let tight):
                system.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])
                let kind: UIText.ReminderNoticeKind = tight ? .tight : .tooSoon(next: nextCatchable(told))
                Self.addQuietly(Self.request(told, kind, id: told.noticeID, fireAt: nil, l: l, now: now))
            case .gone(let cancelled):
                system.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])
                Self.addQuietly(Self.request(reminder, cancelled ? .cancelled : .notListed, id: reminder.noticeID, fireAt: nil, l: l, now: now))
            }
        }
        if kept != reminders { reminders = kept }
        if let failed = failedID, !arrivals.contains(where: { $0.id == failed }) { failedID = nil }
    }

    /// The app's language changed: each reminder still to come gets its notification written again in the new one, at the same
    /// time (one with the same name takes its place). One about to come is left to the system (LeaveReminders.handsOffSeconds)
    func rewrite(l: UIText, now: Date = Date()) {
        guard !Self.inert, loaded, !sampling else { return }
        for reminder in waiting(now: now) where reminder.fireAt.timeIntervalSince(now) > LeaveReminders.handsOffSeconds {
            Self.addQuietly(Self.request(reminder, .leave, id: reminder.notificationID, fireAt: reminder.fireAt, l: l, now: now))
        }
    }

    // MARK: - The system's notifications

    /// A notification for this reminder. fireAt: when it comes, on this Mac's clock (it then carries the reminder, and is the
    /// reminder as far as the system goes); nil: at once, and it carries nothing (it only tells).
    /// Its words are fixed here, in the app's language of now.
    private static func request(_ reminder: LeaveReminder, _ kind: UIText.ReminderNoticeKind, id: String, fireAt: Date?, l: UIText,
                                now: Date) -> UNNotificationRequest {
        let notice = l.reminderNotice(reminder, kind, now: ClockSkew.now(now))
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let fireAt {
            if let encoded = reminder.encoded { content.userInfo = [dataKey: encoded] }
            // Counted from now, not a date on the calendar: a change of this Mac's time zone doesn't move it
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt.timeIntervalSince(now)), repeats: false)
        }
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    /// Hands the system a notification and says whether it took it
    private static func add(_ request: UNNotificationRequest) async -> Bool {
        let problem = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            UNUserNotificationCenter.current().add(request) { error in
                done.resume(returning: error.map { AppLog.reason($0) })
            }
        }
        if let problem { AppLog.data.error("Leave-by reminder: the system didn't take a notification: \(problem, privacy: .public)") }
        return problem == nil
    }

    /// The same without waiting for the answer (after a refresh). If the system didn't take it, the list here may no longer be
    /// the system's: it is read again. `old`: a pending notification this one replaces, taken away only once the system has
    /// taken this one
    private static func addQuietly(_ request: UNNotificationRequest, replacing old: String? = nil) {
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else {
                if let old { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [old]) }
                return
            }
            let problem = AppLog.reason(error)
            AppLog.data.error("Leave-by reminder: the system didn't take a changed notification: \(problem, privacy: .public)")
            Task { @MainActor in await LeaveReminderCenter.shared.load() }
        }
    }
}

/// What the system asks the app about its notifications. One object for the whole run: the system keeps no hold on it
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationDelegate()

    /// With the app in front the system shows no notification unless told to: a reminder is to be seen and heard there too
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click on a notification opens the main window, as a click on the widget does (closing the notification opens nothing)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                MainWindow.showInDock()
                MainWindow.reopen?()
                NSApp.activate()
            }
        }
        completionHandler()
    }
}
