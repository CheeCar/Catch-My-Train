import Foundation
import TransitCore

extension TransitModel {
    /// The time the main window's footer and the menu bar panel write after "Updated" (see BoardTimes.updated). Whether the
    /// data counts as out of date still goes by dataUpdatedAt, and so does the widget
    var shownDataTime: Date? {
        isDemo ? dataUpdatedAt : BoardTimes.updated(networkAllowed: networkAllowed, dataTime: dataUpdatedAt, arrivals: arrivals)
    }

    /// The time the footer writes after "Last refresh" (see BoardTimes.refreshed)
    var shownRefreshTime: Date? {
        isDemo ? lastAttempt : BoardTimes.refreshed(networkAllowed: networkAllowed, lastAttempt: lastAttempt)
    }
}
