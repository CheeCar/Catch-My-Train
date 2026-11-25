import Foundation

extension FerryFeed {
    // MARK: Operators whose schedules have run out

    /// Service day numbers for several days starting from (and including) this day in that time zone (`zone`, the operator's, as in
    /// arrivals; the subway's by default)
    static func days(from date: Date, count: Int, in zone: TimeZone = Timetable.timeZone) -> [Int] {
        var result: [Int] = []
        var d = Timetable.dayNumber(date, in: zone)
        while result.count < count {
            result.append(d)
            d = Timetable.nextDay(d)
        }
        return result
    }

    /// Service days with trips for each operator (small enough to save): when Settings shows which operators' schedules have or will soon run out,
    /// the whole schedule needn't be loaded into memory for it. Results match idleSources / endingSources.
    public struct Coverage: Codable, Sendable, Equatable {
        /// When it was computed and how many days ahead: too old can't be used (see isUsable)
        public var computedAt: Date
        public var horizonDays: Int
        /// Operators with trips: which service days have trips
        public var runDays: [String: Set<Int>]
        /// All operators in this data (some may have no trips at all)
        public var listed: Set<String>

        /// Whether days days from date are still within the computed range
        public func isUsable(from date: Date, days: Int = 7) -> Bool {
            date >= computedAt.addingTimeInterval(-3600)
                && date.addingTimeInterval(Double(days + 1) * 86_400) <= computedAt.addingTimeInterval(Double(horizonDays) * 86_400)
        }

        public func idleSources(from date: Date, days: Int = 7) -> Set<Source> {
            let list = FerryFeed.days(from: date, count: days)
            return Set(runDays.compactMap { key, run in
                guard let s = Source(rawValue: key), !s.keepsPatterns, !list.contains(where: run.contains) else { return nil }
                return s
            })
        }

        public func endingSources(from date: Date, days: Int = 3) -> Set<Source> {
            let list = FerryFeed.days(from: date, count: days)
            return Set(listed.compactMap { key in
                guard let s = Source(rawValue: key), s.isRail else { return nil }
                let run = runDays[key] ?? []
                return list.allSatisfy(run.contains) ? nil : s
            })
        }

        /// Same as FerryFeed.endingSoonSources. None when those days reach past the computed range (they aren't known then)
        public func endingSoonSources(from date: Date, days: Int = FerryFeed.endingSoonDays) -> Set<Source> {
            guard isUsable(from: date, days: days + FerryFeed.endingSoonLookAhead) else { return [] }
            let later = FerryFeed.daysAfter(date, skipping: days)
            return Set(runDays.compactMap { key, run in
                guard let s = Source(rawValue: key), !s.keepsPatterns, !later.contains(where: run.contains) else { return nil }
                return s
            })
        }
    }

    public func coverage(from date: Date, days: Int = 45) -> Coverage {
        let dayList = Self.days(from: date, count: days)
        // First compute which days each service (hundreds) runs, then combine by operator (there are tens of thousands of trips, no need to check each)
        var serviceDays: [String: Set<Int>] = [:]
        for (id, service) in services { serviceDays[id] = Set(dayList.filter { service.runs(on: $0) }) }
        var servicesBySource: [String: Set<String>] = [:]
        for trip in trips {
            guard let source = Source.allCases.first(where: { $0.owns(id: trip.id) }) else { continue }
            servicesBySource[source.rawValue, default: []].insert(trip.service)
        }
        let runDays = servicesBySource.mapValues { ids in
            ids.reduce(into: Set<Int>()) { $0.formUnion(serviceDays[$1] ?? []) }
        }
        return Coverage(computedAt: date, horizonDays: days, runDays: runDays, listed: Set(sources.map(\.rawValue)))
    }

    /// Operators with no boats at all in the next `days` days (including today): the schedule ran out and no new one is out yet
    /// (e.g. the Statue of Liberty ferry between seasons), or service is suspended. Only operators with trips count.
    public func idleSources(from date: Date, days: Int = 7) -> Set<Source> {
        let dayList = Self.days(from: date, count: days)
        var hasTrips = Set<Source>()
        var running = Set<Source>()
        for trip in trips {
            guard let source = Source.allCases.first(where: { $0.owns(id: trip.id) }), !source.keepsPatterns else { continue }
            hasTrips.insert(source)
            guard !running.contains(source), let service = services[trip.service] else { continue }
            if dayList.contains(where: { service.runs(on: $0) }) { running.insert(source) }
        }
        return hasTrips.subtracting(running)
    }

    /// Train operators with at least one day with no trains in the next `days` days (including today): the schedule is nearly used up (LIRR data only runs a few weeks ahead),
    /// so the app checks daily for a new one (see the app's FerryStore). Trains run every day, so a day with none means the data has run short.
    public func endingSources(from date: Date, days: Int = 3) -> Set<Source> {
        let dayList = Self.days(from: date, count: days)
        var result = Set<Source>()
        for source in Source.allCases where source.isRail && sources.contains(source) {
            let services = Set(trips.filter { source.owns(id: $0.id) }.map(\.service)).compactMap { self.services[$0] }
            if dayList.contains(where: { day in !services.contains { $0.runs(on: day) } }) { result.insert(source) }
        }
        return result
    }

    /// How many days before an operator's timetable runs out the app starts checking for a new one every day, until one is out, so the
    /// new one is in use before the old one ends (see the app's FerryStore). The same for every operator
    public static let endingSoonDays = 7

    /// How far past those days it looks: an operator with no trips at all in this many days after them has its timetable end within them
    /// (an operator that doesn't run every day still runs at least once in two weeks)
    public static let endingSoonLookAhead = 14

    /// The days after the first `skipping` days from this day, `endingSoonLookAhead` of them (see endingSoonDays)
    static func daysAfter(_ date: Date, skipping: Int) -> [Int] {
        Array(days(from: date, count: skipping + endingSoonLookAhead).dropFirst(skipping))
    }

    /// Operators whose timetable ends within the next `days` days (with trips in them or not): no trips in the two weeks after them.
    /// Trains keep only 45 days of trips from their last download (see Source.keepDays): while the monthly check works, those still
    /// reach past this, so only a timetable that really ends counts
    public func endingSoonSources(from date: Date, days: Int = FerryFeed.endingSoonDays) -> Set<Source> {
        let later = Self.daysAfter(date, skipping: days)
        var hasTrips = Set<Source>()
        var running = Set<Source>()
        // Hundreds of calendars for tens of thousands of trips: work out each calendar once
        var runsLater: [String: Bool] = [:]
        for trip in trips {
            guard let source = Source.allCases.first(where: { $0.owns(id: trip.id) }), !source.keepsPatterns else { continue }
            hasTrips.insert(source)
            guard !running.contains(source) else { continue }
            let runs: Bool
            if let known = runsLater[trip.service] {
                runs = known
            } else {
                runs = services[trip.service].map { service in later.contains { service.runs(on: $0) } } ?? false
                runsLater[trip.service] = runs
            }
            if runs { running.insert(source) }
        }
        return hasTrips.subtracting(running)
    }

    /// Remove operators with no boats in the next few days: their piers, routes and map are hidden, so no empty piers without boats appear
    /// (e.g. the Statue of Liberty ferry is hidden when it has no schedule). Returned unchanged when all are running.
    /// New Jersey ferries: same data as the New York ferries, keeping only the two operators with New Jersey piers (NY Waterway, Seastreak). Other systems are returned unchanged.
    public func filtered(for system: TransitSystem) -> FerryFeed {
        guard system == .njFerry else { return self }
        return removing(Set(Source.allCases).subtracting([.nyWaterway, .seastreak]))
    }

    /// Without the operators the source list turned off (their data may still be in a copy saved before). Unchanged when none is off
    public func withoutTurnedOff() -> FerryFeed {
        let off = Set(Source.allCases.filter(\.isTurnedOff))
        return off.isEmpty ? self : removing(off)
    }

    /// Without these operators (their areas' data was removed, see AreaData)
    public func removing(_ drop: Set<Source>) -> FerryFeed {
        var result = self
        result.routes.removeAll { r in drop.contains { $0.owns(route: r.id) } }
        result.piers.removeAll { p in drop.contains { $0.owns(id: p.id) } }
        result.trips.removeAll { t in drop.contains { $0.owns(id: t.id) } }
        result.services = services.filter { item in !drop.contains { $0.owns(id: item.key) } }
        result.shapes = shapes.filter { item in !drop.contains { $0.owns(route: item.key) } }
        result.versions = versions.filter { item in !drop.contains { $0.rawValue == item.key } }
        result.zones = zones?.filter { item in !drop.contains { $0.rawValue + ":" == item.key } }
        return result
    }

    /// An empty copy (when no bus operators are nearby, see FerryStore; the app layer can't see the synthesized initializer)
    public static let empty = FerryFeed(versions: [:], routes: [], piers: [], trips: [], services: [:], shapes: [:])

    /// A copy without map shapes: computing trips doesn't need route shapes, and shapes take the most memory (keep only needed data in memory).
    /// The map is read from a file separately.
    public func withoutShapes() -> FerryFeed {
        guard !shapes.isEmpty else { return self }
        var result = self
        result.shapes = [:]
        return result
    }

    public func active(from date: Date, days: Int = 7) -> FerryFeed {
        let idle = idleSources(from: date, days: days)
        guard !idle.isEmpty else { return self }
        var result = self
        result.routes.removeAll { r in idle.contains { $0.owns(route: r.id) } }
        result.piers.removeAll { p in idle.contains { $0.owns(id: p.id) } }
        result.trips.removeAll { t in idle.contains { $0.owns(id: t.id) } }
        result.services = services.filter { item in !idle.contains { $0.owns(id: item.key) } }
        result.shapes = shapes.filter { item in !idle.contains { $0.owns(route: item.key) } }
        result.versions = versions.filter { item in !idle.contains { $0.rawValue == item.key } }
        result.wholeTimetables = wholeTimetables?.filter { item in !idle.contains { $0.owns(id: item.key) } }
        result.stopCodeLists = stopCodeLists?.filter { item in !idle.contains { $0.owns(id: item.key) } }
        return result
    }
}
