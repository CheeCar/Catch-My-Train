import Foundation

// MARK: - MTA scheduled timetable (for "trip lookup")
//
// Realtime data only covers about the next hour. To look up later trains in advance, use the official MTA static GTFS timetable
// (https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip, free, no account or key needed).
// The raw stop_times.txt is 36 MB; here it is packed into a small binary file (about 4 MB),
// and queries read only the stations needed, so memory use is small. The timetable updates every few months, and the app re-downloads it before it expires.

/// Compressed timetable.
public struct Timetable: Sendable {
    public static let magic: [UInt8] = Array("CMTT".utf8)
    public static let formatVersion: UInt32 = 1
    /// The subway's time zone: New York's metro area's (all GTFS times are local)
    public static var timeZone: TimeZone { MetroArea.newYork.timeZone }

    /// Timetable validity period (yyyymmdd)
    public let feedStart: Int
    public let feedEnd: Int
    /// When this file was generated
    public let builtAt: Date

    struct Service: Sendable {
        var weekdays: UInt8      // bit0 = Monday … bit6 = Sunday
        var start: Int
        var end: Int
        var added: Set<Int>
        var removed: Set<Int>

        func runs(on day: Int, weekday: Int) -> Bool {
            if removed.contains(day) { return false }
            if added.contains(day) { return true }
            return day >= start && day <= end && weekdays & (1 << UInt8(weekday)) != 0
        }
    }

    struct Group: Sendable {
        var offset: Int
        var count: Int
    }

    let strings: [String]
    let services: [Service]
    /// "stationID|route|N" → position of this group's trips
    let groups: [String: Group]
    let data: Data
    let entriesStart: Int

    static let entrySize = 8

    // MARK: Reading

    public init(data: Data) throws {
        var r = ByteReader(data: data)
        guard try r.bytes(4) == Self.magic else { throw TimetableError.badFormat }
        guard try r.u32() == Self.formatVersion else { throw TimetableError.badFormat }
        feedStart = Int(try r.u32())
        feedEnd = Int(try r.u32())
        builtAt = Date(timeIntervalSince1970: TimeInterval(try r.u32()))

        var strings: [String] = []
        let stringCount = Int(try r.u32())
        strings.reserveCapacity(r.room(for: stringCount, minSize: 2))
        for _ in 0..<stringCount {
            let n = Int(try r.u16())
            strings.append(String(decoding: r.data[try r.range(n)], as: UTF8.self))
        }

        var services: [Service] = []
        for _ in 0..<Int(try r.u32()) {
            _ = try r.u16()  // name (only for troubleshooting)
            let mask = try r.u8()
            let start = Int(try r.u32())
            let end = Int(try r.u32())
            var added = Set<Int>(), removed = Set<Int>()
            for _ in 0..<Int(try r.u16()) {
                let day = Int(try r.u32())
                if try r.u8() == 1 { added.insert(day) } else { removed.insert(day) }
            }
            services.append(Service(weekdays: mask, start: start, end: end, added: added, removed: removed))
        }

        var groups: [String: Group] = [:]
        let groupCount = Int(try r.u32())
        for _ in 0..<groupCount {
            let station = Int(try r.u16())
            let route = Int(try r.u16())
            let dir = try r.u8()
            let offset = Int(try r.u32())
            let count = Int(try r.u32())
            guard station < strings.count, route < strings.count else { throw TimetableError.badFormat }
            let key = Self.key(strings[station], strings[route], dir == UInt8(ascii: "S") ? "S" : "N")
            groups[key] = Group(offset: offset, count: count)
        }
        let entryCount = Int(try r.u32())
        guard r.position + entryCount * Self.entrySize <= data.count else { throw TimetableError.badFormat }
        // Throw when the file is corrupt (e.g. only half written) instead of reading past the end during queries
        guard groups.values.allSatisfy({ $0.offset + $0.count <= entryCount }) else { throw TimetableError.badFormat }

        self.strings = strings
        self.services = services
        self.groups = groups
        self.data = data
        self.entriesStart = r.position
    }

    static func key(_ station: String, _ route: String, _ dir: String) -> String {
        "\(station)|\(route)|\(dir)"
    }

    /// Whether a day (the subway's time) is within the timetable's validity period.
    public func covers(_ date: Date) -> Bool {
        let day = Self.dayNumber(date, in: Self.timeZone)
        return day >= feedStart && day <= feedEnd
    }

    /// Last day of the validity period, for showing its date: noon of that day in the subway's time.
    /// Not the midnight after it, which reads as the next day.
    public var validUntil: Date? {
        Self.serviceDayStart(feedEnd, in: Self.timeZone).map { $0.addingTimeInterval(12 * 3600) }
    }

    // MARK: Queries

    /// Scheduled trips at these stations between `from` and `to`. Trains terminating at this station are excluded.
    public func arrivals(stationIDs: [String], from: Date, to: Date, catalog: StationCatalog) -> [Arrival] {
        var result: [Arrival] = []
        let zone = Self.timeZone
        let today = Self.dayNumber(from, in: zone)
        // GTFS times can go past 24:00 (trips belonging to the previous day), so the previous day is checked too.
        let days = Array(Set([Self.previousDay(from, in: zone), today, Self.dayNumber(to, in: zone)])).sorted()
        for stationID in stationIDs {
            guard let stationEntry = catalog.entry(id: stationID) else { continue }
            for route in Set(stationEntry.routes.map(\.route)) {
                for code in ["N", "S"] {
                    guard let g = groups[Self.key(stationID, route, code)] else { continue }
                    for day in days {
                        guard let dayStart = Self.serviceDayStart(day, in: zone) else { continue }
                        let weekday = Self.weekday(day)
                        let lo = from.timeIntervalSince(dayStart)
                        let hi = to.timeIntervalSince(dayStart)
                        guard hi >= 0 else { continue }
                        var i = lowerBound(g, seconds: max(0, lo))
                        while i < g.offset + g.count {
                            let (sec, svc, term) = entry(at: i)
                            if Double(sec) > hi { break }
                            // Two trips can share a station, route, direction and time: the entry's position keeps their IDs apart
                            let index = i
                            i += 1
                            guard Int(svc) < services.count, services[Int(svc)].runs(on: day, weekday: weekday) else { continue }
                            let terminal = Int(term) < strings.count ? strings[Int(term)] : nil
                            if terminal == stationID { continue }
                            let time = dayStart.addingTimeInterval(TimeInterval(sec))
                            let direction = catalog.direction(stationID: stationID, route: route, code: code,
                                                              lastStationID: terminal)
                            result.append(Arrival(
                                id: "sched-\(stationID)-\(route)-\(code)-\(day)-\(sec)-\(index)",
                                stationID: stationID, route: route, direction: direction,
                                arrivalTime: time, source: .scheduled, updatedAt: builtAt))
                        }
                    }
                }
            }
        }
        return result.sorted { ($0.arrivalTime ?? .distantFuture, $0.id) < ($1.arrivalTime ?? .distantFuture, $1.id) }
    }

    private func entry(at index: Int) -> (UInt32, UInt16, UInt16) {
        let p = entriesStart + index * Self.entrySize
        return data.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: p, as: UInt32.self).littleEndian,
             raw.loadUnaligned(fromByteOffset: p + 4, as: UInt16.self).littleEndian,
             raw.loadUnaligned(fromByteOffset: p + 6, as: UInt16.self).littleEndian)
        }
    }

    /// A group of trips sorted by time; binary search for the first position not earlier than seconds.
    private func lowerBound(_ g: Group, seconds: Double) -> Int {
        var lo = g.offset, hi = g.offset + g.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Double(entry(at: mid).0) < seconds { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Dates

    /// Made once per time zone: date math runs in loops over every trip, and creating a calendar each time is costly.
    /// Also for the app's own day checks, so they count days the way the timetables do. A timetable's days are counted in its
    /// operator's zone (GTFS agency_timezone), a metro area's in the area's (MetroArea.timeZone)
    public static func calendar(in zone: TimeZone) -> Calendar {
        calendarLock.lock(); defer { calendarLock.unlock() }
        if let c = calendars[zone.identifier] { return c }
        var c = Calendar(identifier: .gregorian)
        // Kept by the zone's name, so always the fixed zone of that name: an updating one (this Mac's) would follow the Mac to
        // another zone and take that name's calendar with it
        c.timeZone = TimeZone(identifier: zone.identifier) ?? zone
        calendars[zone.identifier] = c
        return c
    }
    private static let calendarLock = NSLock()
    nonisolated(unsafe) private static var calendars: [String: Calendar] = [:]

    /// The date in that time zone, e.g. 20261013.
    public static func dayNumber(_ date: Date, in zone: TimeZone) -> Int {
        let c = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// The start of this moment's minute, counted in seconds: a clock ticking from it every 60 seconds never stands still when the clocks
    /// change, as one going by the clock's reading can (every time zone's offset is whole minutes, so these are full minutes on its clocks too)
    public static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// The moments a widget's timeline shows: `now`, then the start of each minute after it. The widget's sizes are asked to redraw
    /// at different seconds; counting every 60 seconds from each one's own start, one size could say "Tight" while another still
    /// said "Can try" for the same train. Ticking on the clock's minutes, they all change together.
    public static func timelineMoments(from now: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        let first = minuteStart(now)
        return [now] + (1..<count).map { first.addingTimeInterval(Double($0) * 60) }
    }

    /// The calendar day before this moment's day, in that time zone. Not 24 hours earlier: the day clocks spring forward has only 23 hours,
    /// so early on the Monday after, 24 hours back lands on Saturday and Sunday's late trips would be missed.
    public static func previousDay(_ date: Date, in zone: TimeZone) -> Int {
        dayNumber(calendar(in: zone).date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-24 * 3600), in: zone)
    }

    /// Per GTFS, times count from "noon minus 12 hours" of the day in the operator's time zone (on DST changeover days this differs
    /// from midnight by an hour).
    static func serviceDayStart(_ day: Int, in zone: TimeZone) -> Date? {
        var c = DateComponents()
        c.year = day / 10000
        c.month = day / 100 % 100
        c.day = day % 100
        c.hour = 12
        return calendar(in: zone).date(from: c)?.addingTimeInterval(-12 * 3600)
    }

    /// The day after this one (a date, the same in every time zone)
    static func nextDay(_ day: Int) -> Int {
        var c = DateComponents()
        c.year = day / 10000
        c.month = day / 100 % 100
        c.day = day % 100 + 1
        c.hour = 12
        guard let d = utc.date(from: c) else { return day + 1 }
        return dayNumber(d, in: utc.timeZone)
    }

    /// 0 = Monday … 6 = Sunday. A date's weekday is the same in every time zone
    static func weekday(_ day: Int) -> Int {
        var c = DateComponents()
        c.year = day / 10000
        c.month = day / 100 % 100
        c.day = day % 100
        c.hour = 12
        guard let d = utc.date(from: c) else { return 0 }
        return (utc.component(.weekday, from: d) + 5) % 7
    }
    private static let utc = calendar(in: TimeZone(secondsFromGMT: 0)!)
}

public enum TimetableError: Error, Equatable {
    case badFormat
    case missingFile(String)
}

struct ByteReader {
    let data: Data
    var position = 0

    /// How many of `count` records of at least `minSize` bytes can still be in the data: for reserving memory from a count
    /// written in the file without trusting it (a damaged count would otherwise ask for gigabytes before reading fails)
    func room(for count: Int, minSize: Int) -> Int {
        max(0, min(count, (data.count - position) / minSize))
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, position + n <= data.count else { throw TimetableError.badFormat }
        let start = data.startIndex + position
        position += n
        return Array(data[start..<start + n])
    }

    /// Skips n bytes and returns their range in data (no copy: a small array per number read would mean millions of allocations
    /// per bus dataset and badly fragmented memory)
    mutating func range(_ n: Int) throws -> Range<Data.Index> {
        guard n >= 0, position + n <= data.count else { throw TimetableError.badFormat }
        let start = data.startIndex + position
        position += n
        return start..<start + n
    }

    mutating func u8() throws -> UInt8 { data[try range(1).lowerBound] }

    mutating func u16() throws -> UInt16 {
        let i = try range(2).lowerBound
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let i = try range(4).lowerBound
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    /// A string of a length (u16) plus UTF-8 bytes, decoded directly from data
    mutating func string16() throws -> String {
        String(decoding: data[try range(Int(try u16()))], as: UTF8.self)
    }
}

// MARK: - Building the timetable file from GTFS text

public enum TimetableBuilder {

    /// - Parameter files: file name → contents (calendar.txt, calendar_dates.txt, trips.txt, stop_times.txt).
    public static func build(files: [String: Data], builtAt: Date) throws -> Data {
        guard let stopTimesData = files["stop_times.txt"] else { throw TimetableError.missingFile("stop_times.txt") }
        return try build(files: files, stopTimes: { body in try forEachRow(stopTimesData, body) }, builtAt: builtAt)
    }

    /// Same as above, but stop_times.txt is passed in line by line (the app reads while unzipping, without holding the whole 36 MB file in memory).
    public static func build(files: [String: Data],
                             stopTimes: (_ body: @escaping (_ column: (String) -> String?) throws -> Void) throws -> Void,
                             builtAt: Date) throws -> Data {
        guard let calendarData = files["calendar.txt"] else { throw TimetableError.missingFile("calendar.txt") }
        guard let tripsData = files["trips.txt"] else { throw TimetableError.missingFile("trips.txt") }

        var strings: [String] = []
        var stringIndex: [String: UInt16] = [:]
        func intern(_ s: String) -> UInt16 {
            if let i = stringIndex[s] { return i }
            let i = UInt16(truncatingIfNeeded: strings.count)
            strings.append(s)
            stringIndex[s] = i
            return i
        }

        // 1. Service days (weekday / Saturday / Sunday / holidays)
        struct Svc { var name: UInt16; var mask: UInt8; var start: UInt32; var end: UInt32; var exceptions: [(UInt32, UInt8)] }
        var services: [Svc] = []
        var serviceIndex: [String: UInt16] = [:]
        var feedStart = Int.max, feedEnd = 0
        // Throw instead of crashing when the source is bad (non-numeric dates, more than 65535 service days)
        try forEachRow(calendarData) { col in
            guard let id = col("service_id"), let start = col("start_date").flatMap({ UInt32($0) }),
                  let end = col("end_date").flatMap({ UInt32($0) }) else { return }
            var mask: UInt8 = 0
            for (i, name) in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].enumerated()
            where col(name) == "1" { mask |= 1 << UInt8(i) }
            guard services.count < Int(UInt16.max) else { throw TimetableError.badFormat }
            serviceIndex[id] = UInt16(services.count)
            services.append(Svc(name: intern(id), mask: mask, start: start, end: end, exceptions: []))
            feedStart = min(feedStart, Int(start))
            feedEnd = max(feedEnd, Int(end))
        }
        if let dates = files["calendar_dates.txt"] {
            try forEachRow(dates) { col in
                guard let id = col("service_id"), let day = col("date").flatMap({ UInt32($0) }),
                      let type = col("exception_type").flatMap({ UInt8($0) }) else { return }
                if serviceIndex[id] == nil {
                    guard services.count < Int(UInt16.max) else { throw TimetableError.badFormat }
                    serviceIndex[id] = UInt16(services.count)
                    services.append(Svc(name: intern(id), mask: 0, start: day, end: day, exceptions: []))
                }
                services[Int(serviceIndex[id]!)].exceptions.append((day, type))
                // Extra service days listed only in calendar_dates.txt also count toward the validity period (some sources use only that file)
                if type == 1 {
                    feedStart = min(feedStart, Int(day))
                    feedEnd = max(feedEnd, Int(day))
                }
            }
        }
        guard !services.isEmpty else { throw TimetableError.badFormat }

        // 2. Trips: route and service day
        var trips: [String: (route: String, service: UInt16)] = [:]
        try forEachRow(tripsData) { col in
            guard let trip = col("trip_id"), let route = col("route_id"), let svc = col("service_id"),
                  let s = serviceIndex[svc] else { return }
            trips[trip] = (route, s)
        }

        // 3. Stop times. A trip's rows may be anywhere in the file, so its terminal (the stop with the highest stop_sequence;
        // the first one on a tie) is known only after the last row. Terminals are interned in the order trips first appear.
        struct TripState { var route: String; var service: UInt16; var last: (sequence: Int, stop: String)?; var rows = 0 }
        var states: [TripState] = []
        var stateIndex: [String: Int] = [:]
        var pending: [String: [(UInt32, UInt16, UInt32)]] = [:]
        try stopTimes { col in
            guard let trip = col("trip_id"), let stop = col("stop_id") else { return }
            guard let t = col("arrival_time").flatMap(parseTime) ?? col("departure_time").flatMap(parseTime) else { return }
            let i: Int
            if let known = stateIndex[trip] {
                i = known
            } else {
                guard let info = trips[trip] else { return }
                i = states.count
                stateIndex[trip] = i
                states.append(TripState(route: info.route, service: info.service))
            }
            let sequence = col("stop_sequence").flatMap { Int($0) } ?? states[i].rows
            states[i].rows += 1
            if states[i].last.map({ sequence > $0.sequence }) ?? true { states[i].last = (sequence, stop) }
            guard let dir = stop.last, dir == "N" || dir == "S" else { return }
            let key = Timetable.key(String(stop.dropLast()), states[i].route, String(dir))
            pending[key, default: []].append((t, states[i].service, UInt32(i)))
        }
        // Not one departure (stop_times only its header, or none of its trips in trips.txt): no timetable, so the one in use stays
        guard !pending.isEmpty else { throw TimetableError.missingFile("stop_times.txt") }
        let terminals = states.map { intern(String(($0.last?.stop ?? "").dropLast())) }
        let groups = pending.mapValues { list in list.map { ($0.0, $0.1, terminals[Int($0.2)]) } }

        // 4. Write the file
        var w = ByteWriter()
        w.bytes(Timetable.magic)
        w.u32(Timetable.formatVersion)
        w.u32(UInt32(feedStart == Int.max ? 0 : feedStart))
        w.u32(UInt32(feedEnd))
        w.u32(UInt32(max(0, builtAt.timeIntervalSince1970)))

        let sortedKeys = groups.keys.sorted()
        var groupRecords: [(UInt16, UInt16, UInt8, UInt32, UInt32)] = []
        var allEntries: [(UInt32, UInt16, UInt16)] = []
        for key in sortedKeys {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let list = groups[key]!.sorted { $0.0 < $1.0 }
            groupRecords.append((intern(parts[0]), intern(parts[1]), parts[2] == "S" ? UInt8(ascii: "S") : UInt8(ascii: "N"),
                                 UInt32(allEntries.count), UInt32(list.count)))
            allEntries += list
        }
        guard strings.count < Int(UInt16.max) else { throw TimetableError.badFormat }

        w.u32(UInt32(strings.count))
        for s in strings {
            let b = Array(s.utf8.prefix(Int(UInt16.max)))
            w.u16(UInt16(b.count))
            w.bytes(b)
        }
        w.u32(UInt32(services.count))
        for s in services {
            w.u16(s.name)
            w.u8(s.mask)
            w.u32(s.start)
            w.u32(s.end)
            w.u16(UInt16(min(s.exceptions.count, Int(UInt16.max))))
            for (day, type) in s.exceptions.prefix(Int(UInt16.max)) {
                w.u32(day)
                w.u8(type)
            }
        }
        w.u32(UInt32(groupRecords.count))
        for g in groupRecords {
            w.u16(g.0); w.u16(g.1); w.u8(g.2); w.u32(g.3); w.u32(g.4)
        }
        w.u32(UInt32(allEntries.count))
        for e in allEntries {
            w.u32(e.0); w.u16(e.1); w.u16(e.2)
        }
        return w.data
    }

    /// Stops a timetable leaves without times (GTFS allows it for stops that aren't timepoints) get times spread evenly, by stop order,
    /// between the nearest timed stops before and after. A blank first or last stop can't be worked out and is dropped.
    /// - Parameter rows: one trip's stops, in stop order
    public static func fillingBlankTimes<Row>(_ rows: [Row], time: (Row) -> Int?, setting: (Row, Int) -> Row) -> [Row] {
        guard rows.contains(where: { time($0) == nil }) else { return rows }
        let timed = rows.indices.filter { time(rows[$0]) != nil }
        var result: [Row] = []
        for (k, row) in rows.enumerated() {
            if time(row) != nil {
                result.append(row)
                continue
            }
            guard let before = timed.last(where: { $0 < k }), let after = timed.first(where: { $0 > k }),
                  let t0 = time(rows[before]), let t1 = time(rows[after]) else { continue }
            let t = Double(t0) + Double(t1 - t0) * Double(k - before) / Double(after - before)
            result.append(setting(row, Int(t.rounded())))
        }
        return result
    }

    /// "25:07:30" → seconds. Returns nil for things that don't look like times (e.g. absurdly large hours) instead of overflowing and crashing.
    static func parseTime(_ s: String) -> UInt32? {
        let p = s.split(separator: ":")
        guard p.count == 3, let h = UInt32(p[0].trimmingCharacters(in: .whitespaces)),
              let m = UInt32(p[1]), let sec = UInt32(p[2]), h < 240, m < 60, sec < 60 else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Reads CSV line by line (supports commas inside double quotes). `body` gets values by column name.
    /// Hands off to GTFSRowReader just like reading while unzipping (there is only one set of CSV-reading code).
    static func forEachRow(_ data: Data, _ body: (_ column: (String) -> String?) throws -> Void) throws {
        try withoutActuallyEscaping(body) { body in
            let reader = GTFSRowReader(body)
            try reader.feed(data)
            try reader.finish()
        }
    }

    static func splitCSV(_ line: String) -> [String] {
        guard line.contains("\"") else { return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        var fields: [String] = []
        var cur = ""
        var quoted = false
        var it = line.makeIterator()
        var next = it.next()
        while let ch = next {
            next = it.next()
            if ch == "\"" {
                // RFC 4180 (and Python's csv module): inside quotes, "" stands for one literal quote
                if quoted, next == "\"" {
                    cur.append("\"")
                    next = it.next()
                    continue
                }
                quoted.toggle()
            } else if ch == "," && !quoted {
                fields.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        fields.append(cur)
        return fields
    }
}

struct ByteWriter {
    var data = Data()
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8(v >> 24))
    }
}

// MARK: - When to download the timetable again

/// Whether Plan a Trip uses the timetable it has, downloads MTA's again or waits (see TimetableStore). Pure, so it can be tested.
public enum TimetableRefresh {
    public enum Decision: Equatable, Sendable { case useCached, download, wait }

    /// After a failed download, how long before trying again
    public static let retryAfter: TimeInterval = 10 * 60
    /// A timetable built this recently is MTA's newest: a date it doesn't reach won't be in another download either
    public static let notCoveredRecheck: TimeInterval = 12 * 3600

    /// - Parameters:
    ///   - covers: whether the timetable on this Mac covers the date; nil when there is none
    ///   - builtAt: when that timetable was built
    ///   - lastFailure: when the last download failed (cancelled downloads don't count)
    public static func decide(covers: Bool?, builtAt: Date?, lastFailure: Date?, now: Date) -> Decision {
        let waiting = lastFailure.map { now.timeIntervalSince($0) < retryAfter } ?? false
        if covers == true {
            return !SubwayMapSchedule.isDue(lastChecked: builtAt, now: now) || waiting ? .useCached : .download
        }
        if waiting { return .wait }
        if covers == false, let builtAt, abs(now.timeIntervalSince(builtAt)) < notCoveredRecheck { return .useCached }
        return .download
    }
}
