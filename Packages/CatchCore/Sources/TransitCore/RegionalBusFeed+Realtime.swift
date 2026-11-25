import Foundation

extension RegionalBusFeed {
    /// This agency's realtime data (trip IDs prefixed with this agency's prefix).
    /// keep: keep only these trips (prefixed IDs, for nearby stops). Statewide realtime data is large, so keep only what's needed nearby to save memory.
    /// nearby: the nearby piece those trips are from. With it, how the live trips matched is counted for the app's log (matching),
    /// and for a company whose live trips go by stops and time (liveByStopsAndTime) its whole timetable kept there is used
    public func realtime(from data: Data, fetchedAt: Date, keep: Set<String>? = nil, nearby: FerryFeed? = nil) throws -> FerryRealtime {
        guard NJTransitLive.looksLikeProtobuf(data) else { throw NJTransitLive.LiveError.badResponse }
        if liveByStopCodes { return try realtimeByStopCodes(from: data, fetchedAt: fetchedAt, keep: keep, nearby: nearby) }
        var rt = try FerryRealtime.decode(data, fetchedAt: fetchedAt, source: .njTransitBus)
        let prefix = idPrefix
        rt.idPrefix = prefix
        var matching = LiveMatching(total: rt.trips.count, byStopsAndTimeOn: liveByStopsAndTime)
        if tripsByBlock { rt.trips = Self.byBlock(rt.trips, prefix: prefix, keep: keep) }
        // Stops near here where one can board this company's buses
        var stops = Set<String>()
        if let nearby {
            // Live trips naming one of them, and those named by a nearby trip's ID
            for trip in nearby.trips where trip.id.hasPrefix(prefix) { stops.formUnion(trip.boardingStops) }
            let near = rt.trips.filter { $0.value.stopTimes.contains { stops.contains(prefix + $0.stopID) } }
            matching.nearby = near.count
            matching.nearbyByID = near.keys.filter { keep?.contains(prefix + $0) ?? false }.count
        }
        if liveByStopsAndTime, let nearby, let whole = nearby.wholeTimetables?[prefix] {
            let match = Self.matchedByStopsAndTime(rt.trips, prefix: prefix, whole: whole, zone: nearby.timeZone(ofTrip: prefix))
            rt.trips = match.trips
            matching.byID = match.byID
            matching.byStopsAndTime = match.matched.count
            let near = match.matched.filter { keep?.contains(prefix + $0) ?? false }
            matching.nearbyByStopsAndTime = near.count
            // Of those, the ones whose bus still has a stop near here ahead of it (a predicted time there from now on); a stop
            // across the street from one counts as that one, as in the matching
            let here = stops.union(stops.flatMap { whole.nearbyStops[$0] ?? [] })
            matching.nearbyStillToStop = near.filter { id in
                match.trips[id]?.stopTimes.contains { here.contains(prefix + $0.stopID) && ($0.time.map { $0 >= fetchedAt } ?? false) } ?? false
            }.count
            matching.leavingOneOut = match.leavingOneOut
            matching.unmatched = match.unmatched
        }
        if let keep { rt.trips = rt.trips.filter { keep.contains(prefix + $0.key) } }
        if nearby != nil { rt.matching = matching }
        return rt
    }

    /// The live data of a company whose live trips go by stop codes and schedule (liveByStopCodes): its live trips under the IDs
    /// of the nearby stored trips they are, their stops under those trips' own stop IDs. The others are left out: their trip
    /// and stop IDs are another timetable's, so none of them says anything about a stored trip. Without a nearby piece, or
    /// with one that has no stop codes (a copy stored before they were kept), there's nothing to match: no trips
    func realtimeByStopCodes(from data: Data, fetchedAt: Date, keep: Set<String>?, nearby: FerryFeed?) throws -> FerryRealtime {
        let feed = try GTFSRealtimeFeed.decode(data)
        let prefix = idPrefix
        var rt = FerryRealtime(timestamp: feed.timestamp, trips: [:], fetchedAt: fetchedAt, source: .njTransitBus)
        rt.idPrefix = prefix
        for update in feed.tripUpdates { rt.routes[update.routeID, default: 0] += 1 }
        guard let nearby else { return rt }
        var matching = LiveMatching(total: feed.tripUpdates.count)
        matching.byStopCodesOn = true
        if let lists = nearby.stopCodeLists?[prefix] {
            let match = Self.matchedByStopCodes(feed.tripUpdates, prefix: prefix, nearby: nearby, lists: lists,
                                                zone: nearby.timeZone(ofTrip: prefix), dataTime: feed.timestamp ?? fetchedAt)
            rt.trips = match.trips
            matching.nearby = match.nearby
            matching.byStopCodes = match.trips.count
            matching.nearbyStillToStop = match.stillToStop
            matching.unmatched = match.unmatched
        }
        if let keep { rt.trips = rt.trips.filter { keep.contains(prefix + $0.key) } }
        rt.matching = matching
        return rt
    }

    /// How far the time a live trip's own timetable has at a stop (its predicted time less its delay) may be from the stored
    /// trip's time there for the two to be the same trip: the two copies of the timetable round a stop's time differently
    static let scheduleTolerance: TimeInterval = 60
    /// How many of the stops a live trip lists may be missing from a stored trip's stops for the two to be the same trip: a stop
    /// only one of the two copies of the timetable has
    static let stopsNotListed = 1

    /// The stop code a live stop ID stands for: a bay of a terminal is the terminal's code, a dash and the bay ("26229-212_1"
    /// is the stop with code 26229); any other is the code itself
    static func stopCode(live id: String) -> String {
        guard let dash = id.firstIndex(of: "-"), dash != id.startIndex else { return id }
        return String(id[..<dash])
    }

    /// What matching live trips by stop codes and schedule gave (see matchedByStopCodes)
    struct StopCodesMatch {
        /// The matched live trips, under their stored trips' IDs (without prefix), their stops under those trips' stop IDs
        var trips: [String: FerryRealtime.TripUpdate] = [:]
        /// Live trips with a time at a stop near here where one can board the company's buses
        var nearby = 0
        /// The matched ones with a predicted time, now or later, at such a stop
        var stillToStop = 0
        /// The live trips near here that got no stored trip, by why
        var unmatched: [LiveMatchFailure: Int] = [:]
    }

    /// Live trips of a company whose live data goes by stop codes and schedule (see liveByStopCodes), as the nearby stored trips
    /// they are. A live trip lists its stops by code, in order; a stop with a predicted time and a delay has the time the live
    /// trip's own timetable gives it (the predicted time less the delay). A stored trip fits when it runs that day (the day
    /// that time is on, or the day before for a trip after midnight), the stops the live trip lists are on its whole list of
    /// stop codes in the same order (all but stopsNotListed of them at most), and at every stop it keeps in the nearby piece
    /// for which the live trip has such a time, its own time is within scheduleTolerance of it, with at least one such stop.
    /// The live trip's trip_id is never used: it's another timetable's. Only a live trip that exactly one stored trip fits
    /// gets it; a stored trip two live trips fit gets neither. The predicted times go to the stored trip's own stops, on that
    /// day only (the update's start date)
    static func matchedByStopCodes(_ updates: [GTFSRealtimeFeed.TripUpdate], prefix: String, nearby: FerryFeed,
                                   lists: StopCodeLists, zone: TimeZone, dataTime: Date) -> StopCodesMatch {
        /// The nearby trips with one list of stop codes: their places in nearby.trips and their times at the stops they keep,
        /// one row of `width` times for each trip
        struct Table {
            var trips: [Int] = []
            var times: [Int] = []
            var width: Int
        }
        var tables: [Int: Table] = [:]
        for (i, trip) in nearby.trips.enumerated() {
            guard let list = lists.listOfTrip[trip.id], lists.lists.indices.contains(list), lists.kept.indices.contains(list),
                  lists.kept[list].count == trip.stops.count, trip.times.count == trip.stops.count else { continue }
            tables[list, default: Table(width: trip.stops.count)].trips.append(i)
            tables[list]?.times.append(contentsOf: trip.times)
        }
        /// For each code, the lists whose trips keep a stop with it here: the list and the stop's place among the kept stops.
        /// For each list, each kept stop's place among the kept stops by its place in the list
        struct Place {
            var list: Int
            var kept: Int
        }
        var places: [String: [Place]] = [:]
        var keptAt: [Int: [Int: Int]] = [:]
        // The codes of the stops near here where one can board: kept stops other than a trip's last
        var boarding = Set<String>()
        for list in tables.keys.sorted() {
            let codes = lists.lists[list]
            var at: [Int: Int] = [:]
            for (k, position) in lists.kept[list].enumerated() where codes.indices.contains(position) {
                at[position] = k
                guard !codes[position].isEmpty else { continue }
                places[codes[position], default: []].append(Place(list: list, kept: k))
                if k < lists.kept[list].count - 1 { boarding.insert(codes[position]) }
            }
            keptAt[list] = at
        }

        /// A stop a live trip lists: its code, the time the live trip's own timetable has there, and its predicted time
        struct Listed {
            var code: String
            var scheduled: Date?
            var time: Date?
            var noData: Bool
            var skipped: Bool
        }
        /// A stored trip on a service day
        struct Candidate: Hashable {
            var trip: Int
            var day: Int
        }
        var dayStarts: [Int: Date?] = [:]
        func start(of day: Int) -> Date? {
            if let known = dayStarts[day] { return known }
            let start = Timetable.serviceDayStart(day, in: zone)
            dayStarts[day] = start
            return start
        }

        // The place among a stored trip's kept stops of each stop the live trip lists (nil for one that isn't kept, or isn't on
        // the trip's list after the one before), when the stored trip fits the live trip on this day; nil when it doesn't
        func fit(_ stops: [Listed], _ candidate: Candidate) -> [Int?]? {
            let trip = nearby.trips[candidate.trip]
            guard let list = lists.listOfTrip[trip.id], let at = keptAt[list], let dayStart = start(of: candidate.day) else { return nil }
            let codes = lists.lists[list]
            var result: [Int?] = []
            result.reserveCapacity(stops.count)
            var next = 0
            var missing = 0
            var timed = 0
            for stop in stops {
                guard !stop.code.isEmpty, let position = codes[next...].firstIndex(of: stop.code) else {
                    missing += 1
                    guard missing <= stopsNotListed else { return nil }
                    result.append(nil)
                    continue
                }
                next = position + 1
                guard let k = at[position] else {
                    result.append(nil)
                    continue
                }
                result.append(k)
                guard let scheduled = stop.scheduled else { continue }
                let time = dayStart.addingTimeInterval(TimeInterval(trip.times[k]))
                guard abs(scheduled.timeIntervalSince(time)) <= scheduleTolerance else { return nil }
                timed += 1
            }
            return timed >= 1 ? result : nil
        }

        var result = StopCodesMatch()
        /// The live trips that exactly one stored trip fits, by that trip's place in nearby.trips
        var claims: [Int: [(update: GTFSRealtimeFeed.TripUpdate, stops: [Listed], kept: [Int?], day: Int, near: Bool)]] = [:]
        for update in updates {
            // Most live trips are elsewhere: none of their stops is kept here
            guard update.stopTimeUpdates.contains(where: { places[Self.stopCode(live: $0.stopID)] != nil }) else { continue }
            let stops = update.stopTimeUpdates.map { u -> Listed in
                let usable = !u.isSkipped && !u.hasNoData
                let time = usable ? (u.departureTime ?? u.arrivalTime) : nil
                let scheduled = time.flatMap { t in u.delaySeconds.map { t.addingTimeInterval(-TimeInterval($0)) } }
                return Listed(code: Self.stopCode(live: u.stopID), scheduled: scheduled, time: time, noData: u.hasNoData,
                              skipped: u.isSkipped)
            }
            let near = stops.contains { $0.scheduled != nil && boarding.contains($0.code) }
            if near { result.nearby += 1 }
            // The stored trips with one of its stops at that stop's time, on a day they run
            var candidates = Set<Candidate>()
            for stop in stops {
                guard let scheduled = stop.scheduled, let at = places[stop.code] else { continue }
                for day in [Timetable.previousDay(scheduled, in: zone), Timetable.dayNumber(scheduled, in: zone)] {
                    guard let dayStart = start(of: day) else { continue }
                    let seconds = Int(scheduled.timeIntervalSince(dayStart).rounded())
                    let tolerance = Int(scheduleTolerance)
                    for place in at {
                        guard let table = tables[place.list] else { continue }
                        for row in table.trips.indices where abs(table.times[row * table.width + place.kept] - seconds) <= tolerance {
                            let i = table.trips[row]
                            guard nearby.services[nearby.trips[i].service]?.runs(on: day) == true else { continue }
                            candidates.insert(Candidate(trip: i, day: day))
                        }
                    }
                }
            }
            let fitting = candidates.sorted { ($0.trip, $0.day) < ($1.trip, $1.day) }.compactMap { candidate in
                fit(stops, candidate).map { (candidate: candidate, kept: $0) }
            }
            if fitting.count == 1, let only = fitting.first {
                claims[only.candidate.trip, default: []].append((update, stops, only.kept, only.candidate.day, near))
            } else if near {
                result.unmatched[fitting.isEmpty ? .noTrip : .twoFit, default: 0] += 1
            }
        }
        for (i, live) in claims {
            guard live.count == 1, let only = live.first else {
                let near = live.filter { $0.near }.count
                if near > 0 { result.unmatched[.sameTrip, default: 0] += near }
                continue
            }
            let trip = nearby.trips[i]
            var stopTimes: [FerryRealtime.StopTime] = []
            var noData = Set<String>()
            var skipped = Set<String>()
            var stillToStop = false
            for (stop, k) in zip(only.stops, only.kept) {
                guard let k else { continue }
                let id = String(trip.stops[k].dropFirst(prefix.count))
                if let time = stop.time {
                    stopTimes.append(FerryRealtime.StopTime(stopID: id, time: time))
                    if time >= dataTime, trip.canBoard(at: k) { stillToStop = true }
                } else if stop.noData {
                    noData.insert(id)
                } else if stop.skipped {
                    skipped.insert(id)
                }
            }
            result.trips[String(trip.id.dropFirst(prefix.count))] = FerryRealtime.TripUpdate(
                stopTimes: stopTimes, canceled: only.update.isCanceled, timestamp: only.update.timestamp ?? dataTime,
                startDate: String(only.day), skipped: skipped, noData: noData)
            if stillToStop { result.stillToStop += 1 }
        }
        return result
    }

    /// How early and how late a prediction may be for a live trip to fit a stored one by stops and time, and how early and late
    /// another stored trip may be for the live trip to be too close to it as well
    static let fitWindow: ClosedRange<TimeInterval> = -5 * 60...15 * 60
    static let closeWindow: ClosedRange<TimeInterval> = -10 * 60...25 * 60
    /// How early and how late a prediction may be for a stored trip to be one the bus could be on, running early or late: with
    /// such a trip stopping at all of a live trip's stops, none of them is left out
    static let possibleWindow: ClosedRange<TimeInterval> = -15 * 60...45 * 60
    /// How far apart two stops may be to count as one when live trips are matched by stops and time: a place with a stop on each
    /// side of the street, one for each direction, whose live data names one of them for both (13 to 54 m apart in FRTA's)
    static let sameStopDistance: Double = 100

    /// What matching live trips by stops and time gave (see matchedByStopsAndTime)
    struct StopsAndTimeMatch {
        /// The live trips: the matched ones under their stored trips' IDs (without prefix), the others under their own
        var trips: [String: FerryRealtime.TripUpdate] = [:]
        /// Live trips named by a stored trip's own ID
        var byID = 0
        /// The stored trips (IDs without prefix) given a live trip by its stops and times
        var matched: [String] = []
        /// How many of those with one of the live trip's stops left out
        var leavingOneOut = 0
        /// The live trips that got none, by why
        var unmatched: [LiveMatchFailure: Int] = [:]
    }

    /// Live trips whose trip_id isn't one of the stored trips' (see liveByStopsAndTime), under the ID of the one stored trip they
    /// fit. The live trip's stops that have a predicted time and that the timetable's trips stop at count, at least two of them; a
    /// stop within sameStopDistance of one they stop at counts as that one. A stored trip fits when it stops at every one of them in
    /// the same order and runs that day (the service day of the first prediction, or the day before for a trip after midnight),
    /// every prediction is from 5 minutes early to 15 minutes late, and the predictions don't run backwards or bunch up (stops 6
    /// minutes or more apart in the timetable predicted less than half as far apart, as when a dozen stops are predicted within a
    /// minute). A prediction earlier than the timetable at the stored trip's own first stop counts as on time: a bus waiting to
    /// leave is predicted there now. When no trip that runs that day stops at all of them and there are 4 or more, one of them
    /// may be left out: a stop the live data names on a trip whose timetable doesn't have it. Each one is left out in turn, so a
    /// trip that passes the stop elsewhere still fits. One may be left out too when the trips stopping at all of them are all
    /// of another time of day (none has every prediction within possibleWindow) and a trip fits without it; with a trip the
    /// bus could be on, only too late or too early to fit, none is left out, as that would get around how late a trip may be.
    /// Only one that exactly one stored trip fits, with no other stored trip close (from 10 minutes early to 25 minutes late:
    /// two routes' trips into the same terminal on the same streets), gets it; a stored trip two live trips fit gets none of
    /// them, and one a live trip names by its own ID keeps that one. The others keep their own IDs (no stored trip has them)
    static func matchedByStopsAndTime(_ trips: [String: FerryRealtime.TripUpdate], prefix: String, whole: WholeTimetable,
                                      zone: TimeZone) -> StopsAndTimeMatch {
        var stored: [String: Int] = [:]
        var tripsAtStop: [String: Set<Int>] = [:]
        for (i, trip) in whole.trips.enumerated() {
            stored[String(trip.id.dropFirst(prefix.count))] = i
            for stop in trip.stops { tripsAtStop[stop, default: []].insert(i) }
        }
        var result = StopsAndTimeMatch()
        var named = Set<Int>()
        var others: [(id: String, update: FerryRealtime.TripUpdate)] = []
        for (id, update) in trips {
            if let i = stored[id] {
                named.insert(i)
                result.byID += 1
                result.trips[id] = update
            } else {
                others.append((id, update))
            }
        }

        /// A live trip's stop that counts: the stops it stands for (itself and those trips stop at near it), the stored trips
        /// that stop at one of them, and its predicted time
        struct Known {
            var stops: Set<String>
            var trips: Set<Int>
            var time: Date
        }
        /// How a live trip's predictions fit the stored trips stopping at its stops
        struct Outcome {
            var fitting = Set<Int>()
            var close = Set<Int>()
            var runs = false
            var bunched = false
            /// Whether one of them is a trip the bus could be on (see possibleWindow)
            var possible = false
        }

        // The stored trips that stop at all of these stops in the same order (or all but one, each one left out in turn), each
        // with its position at each stop (a stop it serves twice: the first time after the stop before), and how they fit
        func outcome(_ known: [Known], leavingOneOut: Bool, startDate: String) -> Outcome {
            var count: [Int: Int] = [:]
            for k in known {
                for i in k.trips { count[i, default: 0] += 1 }
            }
            let needed = known.count - (leavingOneOut ? 1 : 0)
            let days = [Timetable.previousDay(known[0].time, in: zone), Timetable.dayNumber(known[0].time, in: zone)]
            var found = Outcome()
            for i in count.keys.sorted() where count[i, default: 0] >= needed {
                let trip = whole.trips[i]
                for leftOut in leavingOneOut ? Array(known.indices) : [-1] {
                    var positions: [Int?] = []
                    var after = -1
                    for (j, k) in known.enumerated() {
                        if j == leftOut {
                            positions.append(nil)
                            continue
                        }
                        guard let p = trip.stops.indices.first(where: { $0 > after && k.stops.contains(trip.stops[$0]) }) else { break }
                        positions.append(p)
                        after = p
                    }
                    guard positions.count == known.count else { continue }
                    for day in days {
                        guard whole.services[trip.service]?.runs(on: day) == true,
                              startDate.isEmpty || FerryRealtime.startDate(startDate, matches: day, firstDeparture: trip.times.first),
                              let dayStart = Timetable.serviceDayStart(day, in: zone) else { continue }
                        found.runs = true
                        var predicted: [Date] = []
                        var scheduled: [Date] = []
                        var offsets: [TimeInterval] = []
                        for (k, position) in zip(known, positions) {
                            guard let position else { continue }
                            let time = dayStart.addingTimeInterval(TimeInterval(trip.times[position]))
                            predicted.append(k.time)
                            scheduled.append(time)
                            // Early at the trip's own first stop: waiting there to leave on time
                            let offset = k.time.timeIntervalSince(time)
                            offsets.append(position == 0 ? max(offset, 0) : offset)
                        }
                        if offsets.allSatisfy(possibleWindow.contains) { found.possible = true }
                        if offsets.allSatisfy(closeWindow.contains) { found.close.insert(i) }
                        guard offsets.allSatisfy(fitWindow.contains), let start = scheduled.first, let end = scheduled.last,
                              let firstTime = predicted.first, let lastTime = predicted.last else { continue }
                        let span = end.timeIntervalSince(start)
                        let backwards = zip(predicted, predicted.dropFirst()).contains { $1 < $0.addingTimeInterval(-60) }
                        if backwards || (span >= 6 * 60 && lastTime.timeIntervalSince(firstTime) < span / 2) {
                            found.bunched = true
                            continue
                        }
                        found.fitting.insert(i)
                    }
                }
            }
            return found
        }

        // The one stored trip this live trip fits, or why there's none, and whether one of its stops was left out
        func fit(_ update: FerryRealtime.TripUpdate) -> (trip: Int?, failure: LiveMatchFailure?, leftOut: Bool) {
            let known = update.stopTimes.compactMap { st -> Known? in
                guard let time = st.time, !st.stopID.isEmpty else { return nil }
                let stop = prefix + st.stopID
                let stops = Set([stop] + (whole.nearbyStops[stop] ?? []))
                var at = Set<Int>()
                for s in stops { at.formUnion(tripsAtStop[s] ?? []) }
                return at.isEmpty ? nil : Known(stops: stops, trips: at, time: time)
            }
            guard known.count >= 2 else { return (nil, .fewStops, false) }
            var found = outcome(known, leavingOneOut: false, startDate: update.startDate)
            var leftOut = false
            if known.count >= 4, !found.runs || (found.fitting.isEmpty && !found.possible) {
                // No trip stops at all of them, or only trips of another time of day do: with one left out. In the second
                // case only a trip that fits that way counts; without one, what all the stops gave stands
                let without = outcome(known, leavingOneOut: true, startDate: update.startDate)
                if !found.runs || !without.fitting.isEmpty {
                    found = without
                    leftOut = true
                }
            }
            if found.fitting.count == 1, let only = found.fitting.first {
                return found.close.subtracting([only]).isEmpty ? (only, nil, leftOut) : (nil, .closeToAnother, leftOut)
            }
            if found.fitting.count > 1 { return (nil, .twoFit, leftOut) }
            if !found.runs { return (nil, .noTrip, leftOut) }
            return (nil, found.bunched ? .bunched : .timesOff, leftOut)
        }

        var fitted: [Int: [(id: String, update: FerryRealtime.TripUpdate, leftOut: Bool)]] = [:]
        for other in others {
            let (trip, failure, leftOut) = fit(other.update)
            if let trip {
                fitted[trip, default: []].append((other.id, other.update, leftOut))
            } else {
                result.unmatched[failure ?? .noTrip, default: 0] += 1
                result.trips[other.id] = other.update
            }
        }
        for (i, live) in fitted {
            guard live.count == 1, !named.contains(i), let only = live.first else {
                result.unmatched[.sameTrip, default: 0] += live.count
                for other in live { result.trips[other.id] = other.update }
                continue
            }
            let raw = String(whole.trips[i].id.dropFirst(prefix.count))
            result.trips[raw] = only.update
            result.matched.append(raw)
            if only.leftOut { result.leavingOneOut += 1 }
        }
        result.matched.sort()
        return result
    }

    /// Live trips named by block and first departure (see tripsByBlock) under the IDs of the stored trips with the same two among
    /// `keep`: several when trips of different days share them (only one of them runs on a day). One named any other way keeps
    /// its ID. Without `keep` there's nothing to match: only those others stay
    static func byBlock(_ trips: [String: FerryRealtime.TripUpdate], prefix: String,
                        keep: Set<String>?) -> [String: FerryRealtime.TripUpdate] {
        var stored: [String: [String]] = [:]
        for id in keep ?? [] where id.hasPrefix(prefix) {
            let raw = String(id.dropFirst(prefix.count))
            if let key = BlockTripID.key(stored: raw) { stored[key, default: []].append(raw) }
        }
        var result: [String: FerryRealtime.TripUpdate] = [:]
        for (id, update) in trips {
            guard let key = BlockTripID.key(live: id) else {
                result[id] = update
                continue
            }
            for raw in stored[key] ?? [] { result[raw] = update }
        }
        return result
    }
}
