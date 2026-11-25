import Foundation

// MARK: - Realtime data (NYC Ferry, NY Waterway, LIRR, Metro-North)

/// One operator's GTFS-Realtime.
/// - NYC Ferry and NY Waterway are the same system with the same format: each trip gives only the actual departure at the previous stop and the predicted time at the next (absolute times).
/// - LIRR and Metro-North (MTA): each train gives predicted times at later stops (some only a delay in seconds), and may mark skipped stops.
public struct FerryRealtime: Sendable, Equatable {
    public struct StopTime: Sendable, Equatable {
        public var stopID: String
        /// Predicted time (absolute); nil when only a delay in seconds is given
        public var time: Date?
        /// The delay, when only a delay in seconds is given
        public var delay: TimeInterval?
        /// The stop's stop_sequence in the timetable, when given: SEPTA's trains name stops only by it (stopID is empty)
        public var sequence: Int?
        public init(stopID: String, time: Date, sequence: Int? = nil) {
            self.stopID = stopID
            self.time = time
            self.sequence = sequence
        }
        public init(stopID: String, delay: TimeInterval, sequence: Int? = nil) {
            self.stopID = stopID
            self.delay = delay
            self.sequence = sequence
        }
    }

    public struct TripUpdate: Sendable, Equatable {
        public var stopTimes: [StopTime]
        public var canceled: Bool
        public var timestamp: Date?
        /// Which day this trip starts ("20261014", GTFS start_date); empty when absent
        public var startDate: String = ""
        /// Skipped stops (raw stop_id): this trip doesn't stop there
        public var skipped: Set<String> = []
        /// Stops marked NO_DATA (raw stop_id): no prediction from here on, until the next stop that has one
        public var noData: Set<String> = []
        public init(stopTimes: [StopTime], canceled: Bool = false, timestamp: Date? = nil,
                    startDate: String = "", skipped: Set<String> = [], noData: Set<String> = []) {
            self.stopTimes = stopTimes
            self.canceled = canceled
            self.timestamp = timestamp
            self.startDate = startDate
            self.skipped = skipped
            self.noData = noData
        }
    }

    public var timestamp: Date?
    /// Raw trip_id (without prefix) → realtime info
    public var trips: [String: TripUpdate]
    /// Trains: train number → realtime info, used when trip_id doesn't match. The number is in the vehicle label; Metro-North puts it in the entity id
    /// (its realtime trip_id is a different numbering that doesn't match the schedule; checked on a Mac). NJ Transit's trains are
    /// here only, under trainNumber's form of the entity id (see Source.liveByTrainNumber).
    public var numbers: [String: TripUpdate] = [:]
    public var fetchedAt: Date
    /// Which operator's realtime data
    public var source: FerryFeed.Source
    /// Prefix for trip and stop IDs (differs per operator for buses, e.g. "njb:CTT/"); uses the source's ("njr:") when absent
    public var idPrefix: String?
    /// A bus company's: how its live trips matched its timetable, for the app's log (see RegionalBusFeed.realtime)
    public var matching: LiveMatching?
    /// How many trips the live data has on each route (its route_id; "" for trips that name none), all of them, before any are
    /// left out: for the app's log (see routeSummary)
    public var routes: [String: Int] = [:]
    /// ID prefix for this realtime data
    public var prefix: String { idPrefix ?? source.rawValue + ":" }

    public init(timestamp: Date?, trips: [String: TripUpdate], fetchedAt: Date, source: FerryFeed.Source = .nycFerry,
                numbers: [String: TripUpdate] = [:]) {
        self.timestamp = timestamp
        self.trips = trips
        self.fetchedAt = fetchedAt
        self.source = source
        self.numbers = numbers
    }

    public init(feed: GTFSRealtimeFeed, fetchedAt: Date, source: FerryFeed.Source = .nycFerry) {
        var trips: [String: TripUpdate] = [:]
        var numbers: [String: TripUpdate] = [:]
        var routes: [String: Int] = [:]
        for t in feed.tripUpdates { routes[t.routeID, default: 0] += 1 }
        // NJ Transit's trains go by the entry's id alone, the train number (see Source.liveByTrainNumber)
        let byNumber = source.liveByTrainNumber
        for t in feed.tripUpdates where byNumber || !t.tripID.isEmpty || !t.vehicleLabel.isEmpty {
            let times = t.stopTimeUpdates.compactMap { u -> StopTime? in
                guard !u.isSkipped, !u.hasNoData else { return nil }
                if let time = u.departureTime ?? u.arrivalTime { return StopTime(stopID: u.stopID, time: time, sequence: u.stopSequence) }
                if let d = u.delaySeconds { return StopTime(stopID: u.stopID, delay: TimeInterval(d), sequence: u.stopSequence) }
                return nil
            }
            let skipped = Set(t.stopTimeUpdates.filter(\.isSkipped).map(\.stopID))
            let noData = Set(t.stopTimeUpdates.filter(\.hasNoData).map(\.stopID))
            let update = TripUpdate(stopTimes: times, canceled: t.isCanceled, timestamp: t.timestamp ?? feed.timestamp,
                                    startDate: t.startDate, skipped: skipped, noData: noData)
            if byNumber {
                // Never by trip_id: it names another trip in the timetable the app has. An entry whose id isn't a number is a bus
                // standing in for trains ("PJBUS"), one name for several trips and no stops, so it says nothing about any one of
                // them: left out, with its "cancelled". A number listed more than once (the same train, the same times): the first
                if let number = Self.trainNumber(t.entityID), numbers[number] == nil { numbers[number] = update }
                continue
            }
            if !t.tripID.isEmpty { trips[t.tripID] = update }
            if source.isRail, !t.vehicleLabel.isEmpty { numbers[t.vehicleLabel] = update }
            if source == .metroNorth, !t.entityID.isEmpty, numbers[t.entityID] == nil { numbers[t.entityID] = update }
        }
        self.init(timestamp: feed.timestamp, trips: trips, fetchedAt: fetchedAt, source: source, numbers: numbers)
        self.routes = routes
    }

    /// Lines for the app's log on which routes live data has trips on (route IDs and counts only): "NJ Transit rail live data:
    /// 85 trips, by route: 1 10, 2 8, 13 3, (none) 2", routes in number order where they're numbers, at most perLine routes on a
    /// line, the rest on more lines ("… by route (2 of 3): …")
    public static func routeSummary(_ routes: [String: Int], name: String, perLine: Int = 60) -> [String] {
        let total = routes.values.reduce(0, +)
        // Numbers first in number order, then other IDs in text order, then trips that name no route
        func order(_ id: String) -> (Int, Int, String) { (id.isEmpty ? 2 : Int(id) == nil ? 1 : 0, Int(id) ?? 0, id) }
        let ids = routes.keys.sorted { order($0) < order($1) }
        let parts = ids.map { "\($0.isEmpty ? "(none)" : $0) \(routes[$0] ?? 0)" }
        let size = max(perLine, 1)
        let chunks = stride(from: 0, to: parts.count, by: size).map { Array(parts[$0..<min($0 + size, parts.count)]) }
        guard chunks.count > 1 else {
            return ["\(name) live data: \(total) trips" + (parts.isEmpty ? "" : ", by route: " + parts.joined(separator: ", "))]
        }
        return chunks.enumerated().map { i, chunk in
            "\(name) live data: \(total) trips on \(parts.count) routes, by route (\(i + 1) of \(chunks.count)): " + chunk.joined(separator: ", ")
        }
    }

    /// For the app's log: how many of a timetable's trips are this realtime data's operator's (its prefix), and how many of them
    /// the live data has (see update(for:)), on any day
    public func matchedTrips(in feed: FerryFeed) -> (trips: Int, live: Int) {
        var trips = 0, live = 0
        for trip in feed.trips where trip.id.hasPrefix(prefix) {
            trips += 1
            if update(for: trip) != nil { live += 1 }
        }
        return (trips, live)
    }

    /// Reads downloaded data, also noting whether it parsed and whether it's stuck at an old time (see NetworkReach)
    public static func decode(_ data: Data, from url: URL, fetchedAt: Date, source: FerryFeed.Source) throws -> FerryRealtime {
        FerryRealtime(feed: try GTFSRealtimeFeed.decode(data, from: url, now: fetchedAt), fetchedAt: fetchedAt, source: source)
    }

    public static func decode(_ data: Data, fetchedAt: Date, source: FerryFeed.Source = .nycFerry) throws -> FerryRealtime {
        FerryRealtime(feed: try GTFSRealtimeFeed.decode(data), fetchedAt: fetchedAt, source: source)
    }

    /// Realtime status of one trip (on a given day).
    struct Live {
        var canceled: Bool
        /// Position of a pier with known time → delay (seconds)
        var known: [(index: Int, delay: TimeInterval)]
        /// The last pier position the realtime data says the boat has departed
        var passedIndex: Int?
        var updatedAt: Date?
        /// Positions of stops this trip skips (realtime data says skipped)
        var skipped: Set<Int> = []
        /// Positions of NO_DATA stops, in order
        var noDataFrom: [Int] = []

        /// Delay to show at this pier: the delay of the nearest known pier at or before it, carried forward,
        /// but not past a NO_DATA stop (from there the timetable applies until the next known pier).
        /// Before the first known pier the timetable applies too: a delay further along says nothing about the stops before it.
        func delay(atIndex i: Int) -> TimeInterval? {
            guard let last = known.last(where: { $0.index <= i }) else { return nil }
            if let gap = noDataFrom.last(where: { $0 <= i }), gap > last.index { return nil }
            return last.delay
        }

        /// Best guess of where the vehicle is: the delay carried forward regardless of NO_DATA. Only for working out which
        /// stops are already departed; a NO_DATA stop's timetable time can be past while an earlier, late stop is still ahead.
        /// Before the first known pier, no later than the timetable (an early vehicle has already gone by; a late one isn't assumed late there).
        func positionDelay(atIndex i: Int) -> TimeInterval? {
            if let last = known.last(where: { $0.index <= i }) { return last.delay }
            return known.first.map { min(0, $0.delay) }
        }
    }

    /// A train number in the form NJ Transit's trains are matched by: all digits (nil otherwise: "PJBUS" and "MNBN BUS" are buses
    /// standing in for trains), without leading zeros, so "0065" and "65" are the same train
    static func trainNumber(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let significant = text.drop { $0 == "0" }
        return significant.isEmpty ? "0" : String(significant)
    }

    /// Realtime info for this trip: look up by trip_id first; for trains try the train number, then part of the trip_id (Metro-North schedule trip_ids are
    /// "calendar + number + direction"). A train number runs once a day, so also check the realtime start date (see delays).
    /// NJ Transit's trains: by the train number only (see Source.liveByTrainNumber).
    func update(for trip: FerryFeed.Trip) -> TripUpdate? {
        guard trip.id.hasPrefix(prefix) else { return nil }
        if source.liveByTrainNumber { return trip.number.flatMap(Self.trainNumber).flatMap { numbers[$0] } }
        let raw = String(trip.id.dropFirst(prefix.count))
        if let u = trips[raw] { return u }
        guard source.isRail else { return nil }
        if let number = trip.number, let u = numbers[number] { return u }
        let parts = raw.split(separator: "+").map(String.init)
        if parts.count == 3, let u = trips[parts[1]] { return u }
        return nil
    }

    /// Whether a realtime start date (YYYYMMDD) is this trip's on this service day: the day itself, or, for a trip leaving its
    /// first stop after midnight (at 24:00 or later in its timetable, which counts it on the day before), also the date it leaves
    /// on, which some realtime data gives instead (CTtransit's). The same trip ID a day before or after is a day off in its times
    /// as well, and a time that far off isn't used (see delays)
    static func startDate(_ date: String, matches day: Int, firstDeparture: Int?) -> Bool {
        guard let date = Int(date) else { return false }
        if date == day { return true }
        guard let first = firstDeparture, first >= 24 * 3600 else { return false }
        return date == Timetable.nextDay(day)
    }

    /// This trip's realtime status on this day; nil when the realtime data doesn't match the day (off by over 3 hours, or the start
    /// date of another day, see startDate(_:matches:firstDeparture:)).
    /// - Parameters:
    ///   - day: service day (yyyymmdd); checked against the start date when the realtime data has one
    ///   - stopCodes: station code → prefixed station ID (train realtime data may use codes, see FerryFeed.Pier.code)
    func delays(for trip: FerryFeed.Trip, dayStart: Date, day: Int? = nil,
                stopCodes: [String: String] = [:]) -> Live? {
        guard let update = update(for: trip) else { return nil }
        if let day, !update.startDate.isEmpty,
           !Self.startDate(update.startDate, matches: day, firstDeparture: trip.times.first) { return nil }
        func index(_ stopID: String) -> Int? {
            trip.stops.firstIndex(of: prefix + stopID) ?? stopCodes[stopID].flatMap { trip.stops.firstIndex(of: $0) }
        }
        // A stop named only by its stop_sequence (SEPTA's trains): that pier's position. SEPTA numbers the stops along a train's whole
        // run, which can go on from one line to the next, so a trip may start at any number. One before the trip's first (0 for a train
        // it has no position for yet, or a stop the train makes before this trip starts) counts from the first pier: the delay is the
        // train's, from its start. So does a prediction naming no stop at all (SEPTA leaves out both for a few trains). Only a delay
        // counts that way: a time would be some other stop's. One after the trip's last is a stop of the train's next trip, so this
        // trip's stops are behind it: left out
        func position(_ st: StopTime) -> Int? {
            guard let sequences = trip.sequences, let start = sequences.first else { return nil }
            if let sequence = st.sequence, let i = sequences.firstIndex(of: sequence) { return i }
            guard st.time == nil else { return nil }
            guard let sequence = st.sequence else { return st.stopID.isEmpty ? 0 : nil }
            return sequence < start ? 0 : nil
        }
        func scheduled(_ i: Int) -> Date { dayStart.addingTimeInterval(TimeInterval(trip.times[i])) }
        var known: [(Int, TimeInterval)] = []
        // Position matched for the previous prediction: predictions come in trip order
        var previous = -1
        for st in update.stopTimes {
            let byID = st.stopID.isEmpty ? nil : index(st.stopID)
            guard let first = byID ?? position(st) else { continue }
            var i = first
            // A loop (or a route serving a stop twice) lists the stop more than once: take a position after the previous prediction's,
            // and of those the one whose timetable time is closest to the predicted time (a loop's last stop is the same as its first)
            if byID != nil, trip.stops.lastIndex(of: trip.stops[first]) != first {
                let all = trip.stops.indices.filter { trip.stops[$0] == trip.stops[first] }
                let options = all.contains { $0 > previous } ? all.filter { $0 > previous } : all
                if let time = st.time {
                    i = options.min { abs(time.timeIntervalSince(scheduled($0))) < abs(time.timeIntervalSince(scheduled($1))) } ?? first
                } else {
                    i = options[0]
                }
            }
            previous = max(previous, i)
            guard let delay = st.time.map({ $0.timeIntervalSince(scheduled(i)) }) ?? st.delay else { continue }
            guard abs(delay) < 3 * 3600 else { return nil }
            known.append((i, delay))
        }
        if known.isEmpty && !update.canceled { return nil }
        known.sort { $0.0 < $1.0 }
        let reference = timestamp ?? fetchedAt
        // How fresh this is: the trip's own time, else the data's. LIRR's own time on a trip is when its prediction last changed, not
        // when it was checked (a train still at its first station keeps one from hours before while the data is seconds old): the
        // data's time there
        let updatedAt = source == .lirr ? reference : (update.timestamp ?? reference)
        var live = Live(canceled: update.canceled, known: known.map { (index: $0.0, delay: $0.1) },
                        passedIndex: nil, updatedAt: updatedAt,
                        skipped: Set(update.skipped.compactMap(index)), noDataFrom: update.noData.compactMap(index).sorted())
        if source.isRail || source == .njTransitBus {
            // Train and bus realtime data list later stops: by predicted time, stops more than 1 minute in the past count as departed
            // (buses keep only a few nearby stops, so the ferry rule below, "second-to-last known stop counts as departed", can't be used)
            for i in trip.stops.indices {
                let est = dayStart.addingTimeInterval(TimeInterval(trip.times[i]) + (live.positionDelay(atIndex: i) ?? 0))
                if est < reference.addingTimeInterval(-60) { live.passedIndex = i }
            }
            return live
        }
        // With two times, the first is "the previous stop already departed"; with only one time that has passed, it also counts as departed
        var passed: Int?
        if known.count >= 2 { passed = known[known.count - 2].0 }
        if let last = known.last,
           dayStart.addingTimeInterval(TimeInterval(trip.times[last.0]) + last.1) < reference.addingTimeInterval(-60) {
            passed = max(passed ?? -1, last.0)
        }
        live.passedIndex = passed
        return live
    }
}
