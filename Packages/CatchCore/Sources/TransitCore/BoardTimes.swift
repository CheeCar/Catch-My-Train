import Foundation

/// The times written under the board and in the menu bar panel ("Updated", "Last refresh").
public enum BoardTimes {
    /// The time written after "Updated". `dataTime` is the board's own: the live data's time, or the moment the board was worked
    /// out from timetables. With the network turned off in Settings nothing is downloaded, so working the board out again from
    /// the timetables on this Mac isn't an update: only live times downloaded earlier and still listed have a time (the newest
    /// of theirs; nil without any)
    public static func updated(networkAllowed: Bool, dataTime: Date?, arrivals: [Arrival]) -> Date? {
        guard !networkAllowed else { return dataTime }
        return arrivals.filter { $0.source == .realtime }.map(\.updatedAt).max()
    }

    /// The time written after "Last refresh": none while the network is off (a refresh then downloads nothing)
    public static func refreshed(networkAllowed: Bool, lastAttempt: Date?) -> Date? {
        networkAllowed ? lastAttempt : nil
    }
}
