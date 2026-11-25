import Foundation

// MARK: - What the last data updates changed, and the ones not taken
//
// Each time an operator's data is downloaded again and differs from the data in use, the two are compared (DataChanges) and
// judged (DataJudgement) before the new data takes the old's place (DataUpdateGate). What came of it is kept here, one entry
// per operator: the last comparison only, for a while (DataChangeLog.keepDays). An update that looks wrong isn't taken: the
// operator goes on with its last good data, and every other operator is updated as usual. Nothing here is needed to show
// departures: a lost or unreadable file is an empty log, and the next update writes it again.

public struct DataChangeLog: Codable, Equatable, Sendable {
    /// The file in the shared folder (StaticData.directory)
    public static let fileName = "data-changes.json"
    /// How long an entry is kept after its check (a month's update is told until the next one, and a while after)
    public static let keepDays = 90
    /// How many stops or lines each list of an entry keeps (the counts are of all of them)
    public static let listLimit = 50
    /// New data that looked wrong is taken all the same once the very same data has come for this many days: the operator
    /// meant it (a line really closed), it wasn't a file cut short. Unless the live data still shows what it leaves out served
    /// (DataWitness.quietDays)
    public static let sameDataDays = 7
    /// New data that looked wrong is downloaded again after this long, not a month later: operators often fix a bad file within days
    public static let recheckHours = 24
    /// New data not in use this long is said at the operator's stations too, as an operator's own problem is (NetworkReach.longProblem)
    public static let longHeldDays = 14
    /// Status names the lines new data leaves out up to this many; more are only counted (Entry.linesGone)
    public static let namedLines = 3

    public struct Entry: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            /// Downloaded again, and nothing a rider would see changed
            case same
            /// Taken, with the changes listed
            case changed
            /// Not taken: it looked wrong (reason); the operator's last good data is in use
            case kept
            /// Taken although it looked wrong, because the same data came for `sameDataDays` days
            case takenAfterWaiting
        }

        /// The operator: "subway", "bus" (the city buses' stops), a train or ferry source, or "bus:" and a regional bus code
        public var key: String
        public var checkedAt: Date
        public var outcome: Outcome
        /// Why it was not taken (kept), or why it looked wrong (takenAfterWaiting)
        public var reason: DataJudgement.Reason?
        /// The changes, each list cut to `listLimit` (for kept: what the new data would have changed)
        public var changes: DataChanges
        /// How many things changed, and how many lines a list of them has, before the lists were cut
        public var count: Int
        public var lines: Int
        /// While new data looks wrong: since when this same data has come, and what tells it apart (DataListing.fingerprint)
        public var waitingSince: Date?
        public var waitingFingerprint: String?
        /// While new data looks wrong: what it leaves out, all of it, and when the live data last showed it served (DataWitness)
        public var missing: DataWitness.Missing?
        /// While new data isn't in use: since when none of the operator's new data has been, whatever came meanwhile (waitingSince
        /// starts again with other data). Nil in a log written before it was kept
        public var heldSince: Date?
        /// When the data in use was taken; nil when not known (the first data, or a log written before it was kept)
        public var inUseSince: Date?
        /// While new data isn't in use: how many stops the data in use has, and the new data
        public var stopsInUse: Int?
        public var stopsNew: Int?

        public init(key: String, checkedAt: Date, outcome: Outcome, reason: DataJudgement.Reason? = nil,
                    changes: DataChanges = DataChanges(), waitingSince: Date? = nil, waitingFingerprint: String? = nil,
                    missing: DataWitness.Missing? = nil, heldSince: Date? = nil, inUseSince: Date? = nil,
                    stopsInUse: Int? = nil, stopsNew: Int? = nil) {
            self.key = key
            self.checkedAt = checkedAt
            self.outcome = outcome
            self.reason = reason
            self.changes = changes.capped(to: DataChangeLog.listLimit)
            self.count = changes.count
            self.lines = changes.lines
            self.waitingSince = waitingSince
            self.waitingFingerprint = waitingFingerprint
            self.missing = missing
            self.heldSince = heldSince
            self.inUseSince = inUseSince
            self.stopsInUse = stopsInUse
            self.stopsNew = stopsNew
        }

        /// Since when the operator's new data hasn't been used (for kept)
        public var notUsedSince: Date { heldSince ?? waitingSince ?? checkedAt }

        /// The operator's new data hasn't been used for `longHeldDays`: its stations say so too
        public func isHeldLong(now: Date) -> Bool {
            outcome == .kept && now.timeIntervalSince(notUsedSince) >= Double(DataChangeLog.longHeldDays) * 86_400
        }

        /// The lines the new data leaves out, as Status tells them: by name when they are `namedLines` at most, otherwise only
        /// how many (no names: a status line doesn't name the first few and "N more"). All of them are counted, also past the
        /// cut list in `changes`
        public var linesGone: (names: [String], count: Int) {
            let names = changes.removedRoutes.map(\.route.name)
            let count = max(missing?.routes.count ?? 0, names.count)
            return count > DataChangeLog.namedLines ? ([], count) : (names, count)
        }

        /// The operator's new data isn't in use, and it's time to download it again
        public func wantsRecheck(now: Date) -> Bool {
            outcome == .kept && now.timeIntervalSince(checkedAt) >= Double(DataChangeLog.recheckHours) * 3600
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// Entries older than `keepDays` dropped
    public func pruned(now: Date) -> DataChangeLog {
        let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        return DataChangeLog(entries: entries.filter { $0.value.checkedAt >= oldest })
    }

    /// The operators whose new data isn't in use now (outcome kept), by key
    public var kept: [Entry] {
        entries.values.filter { $0.outcome == .kept }.sorted { $0.key < $1.key }
    }

    /// Whether this entry takes the place of the operator's entry: the same data downloaded again doesn't hide the last changes
    /// (Check Timetables Now right after an update); they're told until the data changes again, or for `keepDays`
    public func keeps(_ entry: Entry?, for key: String) -> Bool {
        guard let entry, entry.outcome == .same, let previous = entries[key] else { return true }
        return previous.outcome != .changed && previous.outcome != .takenAfterWaiting
    }

    /// What Settings tells of these operators' last updates (one mode's): the day of the latest, the changes, and the
    /// operators whose new data isn't in use
    public func news(of keys: Set<String>) -> News {
        let mine = entries.filter { keys.contains($0.key) }.map(\.value)
        let told = mine.filter { $0.outcome == .changed || $0.outcome == .takenAfterWaiting }
            .sorted { ($0.checkedAt, $0.key) > ($1.checkedAt, $1.key) }
        return News(latest: mine.filter { $0.outcome != .kept }.map(\.checkedAt).max(), changed: told,
                    count: told.reduce(0) { $0 + $1.count }, kept: mine.filter { $0.outcome == .kept }.sorted { $0.key < $1.key })
    }

    public struct News: Equatable, Sendable {
        /// When the latest of them was downloaded and taken (or found the same); nil: none was yet
        public var latest: Date?
        /// The entries with changes, the latest first
        public var changed: [Entry]
        /// How many changes they have in all (also those cut from the lists)
        public var count: Int
        /// The operators whose new data isn't in use
        public var kept: [Entry]
    }

    // MARK: Reading and writing

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    /// A file that can't be read is an empty log (it can be made again)
    public static func decode(_ data: Data?) -> DataChangeLog {
        guard let data, let log = try? decoder.decode(DataChangeLog.self, from: data) else { return DataChangeLog() }
        return log
    }

    /// The log in the shared folder, without entries past `keepDays`
    public static func load(now: Date = Date()) -> DataChangeLog {
        decode(StaticData.downloaded(fileName)).pruned(now: now)
    }

    /// Writes one operator's entry (or removes it with nil), leaving the others. The app and the widget never write it at the same
    /// time: only the app's updates do, one at a time (see `lock`)
    public static func record(_ entry: Entry?, for key: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var log = load(now: now)
        guard log.keeps(entry, for: key) else { return }
        log.entries[key] = entry
        guard let data = try? log.encoded() else { return }
        try? StaticData.save(data, as: fileName)
    }

    /// The live data just showed served what an operator's new data leaves out (DataWitness): its entry notes the time, if it's
    /// still the one kept out for this same data (its fingerprint) and wasn't noted within `DataWitness.noteEvery`. Returns
    /// whether the file was written
    @discardableResult
    public static func noteLive(for key: String, fingerprint: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let log = load(now: now).notingLive(for: key, fingerprint: fingerprint, now: now),
              let data = try? log.encoded() else { return false }
        return (try? StaticData.save(data, as: fileName)) != nil
    }

    /// The log with that time noted (see noteLive); nil: nothing to note
    public func notingLive(for key: String, fingerprint: String, now: Date) -> DataChangeLog? {
        guard var entry = entries[key], entry.outcome == .kept, entry.waitingFingerprint == fingerprint,
              var missing = entry.missing, DataWitness.wantsNote(lastSeen: missing.liveSeenAt, now: now) else { return nil }
        missing.liveSeenAt = now
        entry.missing = missing
        var log = self
        log.entries[key] = entry
        return log
    }

    private static let lock = NSLock()
}

extension DataListing {
    /// What tells one data apart from another as far as the listing goes, the same on every launch: two downloads with the same
    /// stops, lines and stops of each line have the same fingerprint
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for (id, name) in stops.sorted(by: { $0.key < $1.key }) { add("s" + id); add(name) }
        for (id, name) in routes.sorted(by: { $0.key < $1.key }) { add("r" + id); add(name) }
        for (route, served) in routeStops.sorted(by: { $0.key < $1.key }) { add("l" + route); for stop in served.sorted() { add(stop) } }
        return String(hash, radix: 16)
    }
}

/// Whether an operator's new data takes the old's place, and what to log: the comparison and the judgement, with the rule that
/// the same data that looked wrong for `sameDataDays` days is taken after all, unless the live data still shows served what it
/// leaves out (DataWitness)
public enum DataUpdateGate {
    public struct Decision: Equatable, Sendable {
        /// Take the new data (false: keep the old one, the operator's last good data)
        public var take: Bool
        /// What to log for the operator; nil: nothing (the first data there is has nothing to be compared with)
        public var entry: DataChangeLog.Entry?
    }

    /// `old` is the listing of the data in use (nil when there is none yet), `previous` the operator's entry in the log
    public static func decide(key: String, old: DataListing?, new: DataListing, limits: DataJudgement.Limits,
                              previous: DataChangeLog.Entry?, now: Date) -> Decision {
        // The data in use goes on: when it was taken, and since when new data hasn't been used
        let inUse = inUseSince(after: previous)
        let held = previous?.outcome == .kept ? previous?.notUsedSince ?? now : now
        guard let old, !old.stops.isEmpty else {
            // Nothing to hold it against: taken, like before the comparison existed (new data with no stops at all is still refused)
            if new.stops.isEmpty, old != nil {
                return Decision(take: false, entry: DataChangeLog.Entry(key: key, checkedAt: now, outcome: .kept, reason: .empty,
                                                                        heldSince: held, inUseSince: inUse, stopsInUse: 0, stopsNew: 0))
            }
            return Decision(take: true, entry: nil)
        }
        let changes = DataChanges.between(old: old, new: new)
        switch DataJudgement.of(old: old, new: new, limits: limits) {
        case .same:
            return Decision(take: true, entry: DataChangeLog.Entry(key: key, checkedAt: now, outcome: .same, inUseSince: inUse))
        case .changed:
            return Decision(take: true, entry: DataChangeLog.Entry(key: key, checkedAt: now, outcome: .changed, changes: changes,
                                                                   inUseSince: now))
        case .tooDifferent(let reason):
            let print = new.fingerprint
            let again = previous?.outcome == .kept && previous?.waitingFingerprint == print
            let since = again ? previous?.waitingSince ?? now : now
            // When the live data last showed served what this same data leaves out (other data starts with none seen)
            let liveSeenAt = again ? previous?.missing?.liveSeenAt : nil
            // Data with no stops at all is never meant, however long it comes; stops and lines the live data still showed served
            // lately aren't gone, whatever the data says
            if reason != .empty, now.timeIntervalSince(since) >= Double(DataChangeLog.sameDataDays) * 86_400,
               !DataWitness.stillServed(lastSeen: liveSeenAt, now: now) {
                return Decision(take: true, entry: DataChangeLog.Entry(key: key, checkedAt: now, outcome: .takenAfterWaiting,
                                                                       reason: reason, changes: changes, inUseSince: now))
            }
            return Decision(take: false, entry: DataChangeLog.Entry(key: key, checkedAt: now, outcome: .kept, reason: reason,
                                                                    changes: changes, waitingSince: since, waitingFingerprint: print,
                                                                    missing: DataWitness.Missing(changes, liveSeenAt: liveSeenAt),
                                                                    heldSince: held, inUseSince: inUse,
                                                                    stopsInUse: old.stops.count, stopsNew: new.stops.count))
        }
    }

    /// When the data in use was taken, as the operator's last entry tells: its own note of it, or the day it took data (a log
    /// written before the note was kept); nil when it doesn't tell
    static func inUseSince(after previous: DataChangeLog.Entry?) -> Date? {
        guard let previous else { return nil }
        if let since = previous.inUseSince { return since }
        return previous.outcome == .changed || previous.outcome == .takenAfterWaiting ? previous.checkedAt : nil
    }
}

// MARK: - Where the gate is used

extension DataChangeLog {
    /// The keys of the two station lists the monthly check makes again (StaticData.saveSubway, saveBus)
    public static let subwayKey = "subway"
    public static let cityBusKey = "bus"

    /// The key of a regional bus operator's data
    public static func key(bus code: String) -> String { "bus:" + code }

    /// The key of the operator whose data has this station, shown in this mode: the stations of trains, ferries, PATH and light
    /// rail and a regional bus operator's stops have their operator's prefix; the MTA's subway stations and city bus stops have
    /// none, and the mode tells them apart. Nil: one the log doesn't have (the Roosevelt Island Tram, Demo mode's)
    public static func key(station id: String, mode: TransitSystem) -> String? {
        if let bus = RegionalBusFeed.of(id: id) { return key(bus: bus.code) }
        if let source = FerryFeed.Source.allCases.first(where: { $0.owns(id: id) }) { return source.rawValue }
        switch mode {
        case .subway: return subwayKey
        case .bus: return cityBusKey
        default: return nil
        }
    }

    /// Told each entry as it's written (the app writes it to its log); nil: nobody is told
    nonisolated(unsafe) public static var observer: (@Sendable (Entry) -> Void)?
}

extension DataChangeLog.Entry {
    /// One line for a log: the operator, what came of it, why, and how many changes (no names)
    public var summary: String {
        var text = "\(key) \(outcome.rawValue)"
        if let reason { text += " (\(reason.rawValue))" }
        text += ", \(count) changes in \(lines) lines"
        if count > 0 {
            let c = changes
            text += " [stops +\(c.addedStops.count) -\(c.removedStops.count) renamed \(c.renamedStops.count); lines +\(c.addedRoutes.count) "
                + "-\(c.removedRoutes.count) renamed \(c.renamedRoutes.count)]"
        }
        if let waitingSince { text += ", waiting since \(ISO8601DateFormatter().string(from: waitingSince))" }
        if outcome == .kept, let heldSince, heldSince != waitingSince { text += ", not used since \(ISO8601DateFormatter().string(from: heldSince))" }
        if let stopsInUse, let stopsNew { text += ", stops \(stopsInUse) in use, \(stopsNew) new" }
        if let seen = missing?.liveSeenAt { text += ", live data showed it served \(ISO8601DateFormatter().string(from: seen))" }
        return text
    }
}

extension DataJudgement.Limits {
    /// The subway's station list: a tenth in number, 95 in 100 kept (as before the comparison existed)
    public static let subwayStations = DataJudgement.Limits(kept: 0.95, countChange: 0.10, slack: 2)
    /// The city buses' stop list: a quarter in number, 70 in 100 kept
    public static let cityBusStops = DataJudgement.Limits(kept: 0.70, countChange: 0.25, slack: 2)
    /// A timetable (trains, ferries, PATH, light rail, regional buses): 70 in 100 stops kept, the number within 30 in 100; two
    /// stops may always go or come, so an operator with a few piers isn't held up by one
    public static let timetables = DataJudgement.Limits(kept: 0.70, countChange: 0.30, slack: 2)
}

extension DataUpdateGate {
    /// Decides (against the operator's entry in the log) and writes the entry: whether the new data takes the old's place
    public static func check(key: String, old: DataListing?, new: DataListing, limits: DataJudgement.Limits,
                             now: Date = Date()) -> Bool {
        let decision = decide(key: key, old: old, new: new, limits: limits, previous: DataChangeLog.load(now: now).entries[key], now: now)
        if let entry = decision.entry {
            DataChangeLog.record(entry, for: key, now: now)
            DataChangeLog.observer?(entry)
        }
        return decision.take
    }
}

extension DataListing {
    /// One operator's part of a timetable that holds several (a store's file: trains, ferries, light rail)
    public init(_ feed: FerryFeed, source: FerryFeed.Source) {
        self.init()
        for pier in feed.piers where source.owns(id: pier.id) && stops[pier.id] == nil {
            stops[pier.id] = pier.name
            places[pier.id] = Coordinate(latitude: pier.lat, longitude: pier.lon)
        }
        for route in feed.routes where source.owns(route: route.id) && routes[route.id] == nil { routes[route.id] = route.name }
        for trip in feed.trips where source.owns(id: trip.id) { routeStops[trip.route, default: []].formUnion(trip.stops) }
    }

    /// A regional bus operator's data: its stops, its lines (by their short names) and the stops of each line's patterns
    public init(_ index: NJBusIndex) {
        self.init()
        for (i, id) in index.stopIDs.enumerated() where stops[id] == nil {
            stops[id] = index.stopNames[i]
            places[id] = Coordinate(latitude: index.stopLat[i], longitude: index.stopLon[i])
        }
        for name in index.routeNames { routes[name] = name }
        for pattern in index.patterns where index.routeNames.indices.contains(pattern.route) {
            let ids = pattern.stops.compactMap { index.stopIDs.indices.contains(Int($0)) ? index.stopIDs[Int($0)] : nil }
            routeStops[index.routeNames[pattern.route], default: []].formUnion(ids)
        }
    }
}

extension DataListing {
    /// A regional bus operator's stored file read for its listing only (the same as DataListing(NJBusIndex) of it): its stops, its
    /// lines and their patterns' stops, without the trips and times, so the old file costs little memory beside the new data
    public init(busFile data: Data) throws {
        self.init()
        var r = ByteReader(data: data)
        guard try r.bytes(4) == NJBusIndex.magic else { throw TimetableError.badFormat }
        let format = try r.u32()
        guard (1...NJBusIndex.formatVersion).contains(format) else { throw TimetableError.badFormat }
        _ = try r.u32()
        _ = try NJBusIndex.string(&r)
        let stopCount = Int(try r.u32())
        var ids: [String] = []
        ids.reserveCapacity(r.room(for: stopCount, minSize: 12))
        for _ in 0..<stopCount {
            let id = try NJBusIndex.string(&r)
            let name = try NJBusIndex.string(&r)
            let lat = Double(Int32(bitPattern: try r.u32())) / 1_000_000
            let lon = Double(Int32(bitPattern: try r.u32())) / 1_000_000
            ids.append(id)
            if stops[id] == nil {
                stops[id] = name
                places[id] = Coordinate(latitude: lat, longitude: lon)
            }
        }
        var lines: [String] = []
        for _ in 0..<Int(try r.u32()) { lines.append(try NJBusIndex.string(&r)) }
        for name in lines { routes[name] = name }
        // The services' days, not needed here
        for _ in 0..<Int(try r.u32()) {
            _ = try NJBusIndex.string(&r)
            _ = try r.range(Int(try r.u16()) * 4)
        }
        for _ in 0..<Int(try r.u32()) {
            let route = Int(try r.u16())
            _ = try r.u8()
            _ = try NJBusIndex.string(&r)
            var served: [String] = []
            for _ in 0..<Int(try r.u16()) {
                let stop = Int(try r.u16())
                guard stop < ids.count else { throw TimetableError.badFormat }
                served.append(ids[stop])
            }
            if format >= 2 { _ = try r.range(Int(try r.u16()) * 2) }
            guard route < lines.count else { throw TimetableError.badFormat }
            routeStops[lines[route], default: []].formUnion(served)
        }
    }
}

extension FerryFeed {
    /// Checks each of these operators' new data against its old data (DataUpdateGate, logged by the operator's source name) and
    /// returns the ones whose new data looks wrong: those keep their old data, the others take the new. An operator missing
    /// from the new data (its download failed) isn't checked
    public static func sourcesKeptOut(new: FerryFeed, old: FerryFeed?, sources: Set<Source>, now: Date = Date()) -> Set<Source> {
        var kept: Set<Source> = []
        for source in Source.allCases where sources.contains(source) && new.sources.contains(source) {
            let before = old.flatMap { $0.sources.contains(source) ? DataListing($0, source: source) : nil }
            if !DataUpdateGate.check(key: source.rawValue, old: before, new: DataListing(new, source: source), limits: .timetables, now: now) {
                kept.insert(source)
            }
        }
        return kept
    }
}
