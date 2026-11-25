import CatchText
import Foundation
import TransitCore

extension TransitModel {
    /// The leave-by reminders: one object for the whole app (LeaveReminderCenter)
    var reminders: LeaveReminderCenter { .shared }

    /// A refresh finished (saveSnapshot), or the lead was changed in Settings: each waiting reminder follows its train's time
    /// as just loaded. On standby nothing refreshes, so the reminders stay as they were set and fire by the times of then
    func reconcileReminders(now: Date = Date()) {
        reminders.reconcile(arrivals: arrivals, staleAfter: effectiveSettings.realtimeStaleAfterSeconds, l: l10n, now: now) { reminder in
            nextCatchable(after: reminder)
        }
    }

    /// When the next one that can be caught comes after this reminder's train, as its row says under "Too soon": the first later
    /// "Can try" at the same station, line and direction. Nil when the row isn't on the board or names none
    private func nextCatchable(after reminder: LeaveReminder) -> Date? {
        for station in board(at: BoardClock.now()).stations {
            for direction in [station.north, station.south] {
                if let train = direction.trains.first(where: { $0.id == reminder.id }) {
                    return train.recommended?.arrival.arrivalTime
                }
            }
        }
        return nil
    }

    /// A reminder still to come keeps the app on past its auto-standby time, until the last one's latest time to leave
    /// (ActivityState.holding, LeaveReminders.holdUntil): a reminder follows its train only while the app refreshes. It never
    /// starts the app: on standby nothing is held (Start works it out again), and standby chosen by hand drops the hold. Written to
    /// the shared file only when that time changes; going on standby once it is over is the timed check's (syncActivity)
    func holdForReminders(now: Date = Date()) {
        guard !reminders.sampling else { return }
        let current = SharedStore.loadActivity() ?? activity
        let until = LeaveReminders.holdUntil(reminders.reminders, now: now)
        guard current.heldUntil != until, until == nil || current.isActive(at: now) else { return }
        activity = current.holding(until: until)
        SharedStore.saveActivity(activity)
        reloadWidgets(force: true)
    }

    /// A reminder in a list was clicked: the main window is to show its station. It is selected when it is one of the nearby
    /// stations of the mode shown now; the mode isn't changed (another mode's stations come only after its download). On standby
    /// it starts first, as "Show trains" on the map does. The caller opens the main window
    func showReminderStation(_ reminder: LeaveReminder) {
        let wasActive = isActive
        if !wasActive { start() }
        pendingReminderStation = nil
        if selectReminderStation(reminder.stationID) { return }
        // Started from standby before its station was on the board (none worked out yet): selected once a refresh finds it
        if !wasActive { pendingReminderStation = (reminder.stationID, Date()) }
    }

    /// After a refresh: the station of a reminder clicked on standby (showReminderStation), now that it may be on the board.
    /// Tried for a minute at most: the place or the mode may have changed meanwhile
    func selectPendingReminderStation(now: Date = Date()) {
        guard let pending = pendingReminderStation else { return }
        guard now.timeIntervalSince(pending.at) < 60 else {
            pendingReminderStation = nil
            return
        }
        if selectReminderStation(pending.id) { pendingReminderStation = nil }
    }

    /// Selects the group with this station (a reminder's station is one platform), giving its card the small bounce; false when
    /// it isn't among the nearby stations of the mode shown now
    private func selectReminderStation(_ stationID: String) -> Bool {
        let stations = board(at: BoardClock.now()).stations
        guard let station = stations.first(where: { group in
            group.id == stationID || group.stations.contains { $0.id == stationID }
        }) else { return false }
        selectStation(station.id)
        cardBounce = CardBounce(station: station.id, at: Date())
        return true
    }

    /// The lead chosen in Settings, Reminders: saved like the other settings at once. The reminders that wait move to it once the
    /// arrows have stood still a moment, or when the page is left (applyReminderLeadNow): see ReminderLead
    func setReminderLead(_ minutes: Int) {
        reminders.setLead(minutes, save: persistsSettings)
        scheduleReminderLead()
    }

    /// Leaving Settings' Reminders page: the lead chosen applies at once
    func applyReminderLeadNow() {
        reminderLeadTask?.cancel()
        reminderLeadTask = nil
        if reminders.applyLead(now: nil) { reconcileReminders() }
    }

    private func scheduleReminderLead() {
        reminderLeadTask?.cancel()
        reminderLeadTask = nil
        guard let due = reminders.leadDueAt else { return }
        reminderLeadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.reminderLeadTask = nil
            if self.reminders.applyLead() { self.reconcileReminders() } else { self.scheduleReminderLead() }
        }
    }
}
