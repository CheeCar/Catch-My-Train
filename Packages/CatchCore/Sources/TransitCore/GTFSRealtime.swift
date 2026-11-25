import Foundation

// MARK: - GTFS-Realtime parsing
//
// MTA realtime data is in GTFS-Realtime format (Protocol Buffers binary).
// To avoid third-party dependencies, this is a small hand-written parser that reads only the needed fields.
// Field numbers come from the official gtfs-realtime.proto definition:
//   FeedMessage     { 1 header; 2 entity (repeated) }
//   FeedHeader      { 1 gtfs_realtime_version; 2 incrementality; 3 timestamp }
//   FeedEntity      { 1 id; 2 is_deleted; 3 trip_update; 4 vehicle; 5 alert }
//   TripUpdate      { 1 trip; 2 stop_time_update (repeated); 3 vehicle; 4 timestamp; 5 delay }
//   TripDescriptor  { 1 trip_id; 2 start_time; 3 start_date; 4 schedule_relationship; 5 route_id; 6 direction_id }
//   StopTimeUpdate  { 1 stop_sequence; 2 arrival; 3 departure; 4 stop_id; 5 schedule_relationship }
//   StopTimeEvent   { 1 delay; 2 time; 3 uncertainty }
// MTA's NYCT extension of TripDescriptor (field 1001): { 1 train_id; 2 is_assigned; 3 direction }; only is_assigned is read.
// Unknown fields (including the NYCT extension of the header) are skipped safely.

public enum ProtobufError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
    case lengthOutOfRange
    /// More trips, or more stops in one trip, than any real feed has (see GTFSRealtimeFeed.maxEntities)
    case tooMany
    /// Nothing in it: no header and no trip. An empty answer is not a feed (a feed with no train still has its header)
    case empty
}

/// A minimal Protocol Buffers reader.
struct ProtobufReader {
    private let data: [UInt8]
    private(set) var index: Int
    private let end: Int

    init(_ bytes: [UInt8]) {
        self.data = bytes
        self.index = 0
        self.end = bytes.count
    }

    private init(data: [UInt8], start: Int, end: Int) {
        self.data = data
        self.index = start
        self.end = end
    }

    var isAtEnd: Bool { index >= end }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < end else { throw ProtobufError.truncated }
            let byte = data[index]
            index += 1
            if shift == 63 && byte > 1 { throw ProtobufError.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtobufError.malformedVarint }
        }
    }

    /// Reads a field tag, returning (field number, wire type).
    mutating func readTag() throws -> (field: Int, wireType: Int) {
        let key = try readVarint()
        return (Int(truncatingIfNeeded: key >> 3), Int(key & 0x7))
    }

    /// Reads a length-prefixed field, returning a sub-reader covering only that field.
    mutating func readLengthDelimited() throws -> ProtobufReader {
        let length = try readVarint()
        guard length <= UInt64(end - index) else { throw ProtobufError.lengthOutOfRange }
        let start = index
        index += Int(length)
        return ProtobufReader(data: data, start: start, end: index)
    }

    mutating func readString() throws -> String {
        let sub = try readLengthDelimited()
        return String(decoding: data[sub.index..<sub.end], as: UTF8.self)
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: try advance(8)
        case 2: _ = try readLengthDelimited()
        case 5: try advance(4)
        default: throw ProtobufError.unsupportedWireType(wireType)
        }
    }

    private mutating func advance(_ n: Int) throws {
        guard end - index >= n else { throw ProtobufError.truncated }
        index += n
    }
}

/// Parsed GTFS-Realtime data (only the fields this app needs).
public struct GTFSRealtimeFeed: Hashable, Sendable {
    /// When the source generated this data (FeedHeader.timestamp).
    public var timestamp: Date?
    public var tripUpdates: [TripUpdate]

    public struct TripUpdate: Hashable, Sendable {
        public var entityID: String
        public var tripID: String
        public var routeID: String
        public var startDate: String
        public var isCanceled: Bool
        public var timestamp: Date?
        public var stopTimeUpdates: [StopTimeUpdate]
        /// Vehicle label (VehicleDescriptor.label): trains often put the train number here
        public var vehicleLabel: String = ""
        /// MTA subway only (NYCT extension): false while no train is assigned to the trip yet, so its times are still the timetable's.
        /// nil when the data doesn't say (other providers).
        public var isAssigned: Bool? = nil
    }

    public struct StopTimeUpdate: Hashable, Sendable {
        public var stopID: String
        public var arrivalTime: Date?
        public var departureTime: Date?
        /// This stop is skipped (SKIPPED)
        public var isSkipped: Bool
        /// No data for this stop (NO_DATA)
        public var hasNoData: Bool
        /// The delay when only a delay in seconds is given, without a time (StopTimeEvent.delay; arrival first, then departure)
        public var delaySeconds: Int? = nil
        /// The stop's stop_sequence in the timetable, when given (SEPTA's trains give only this, without stop_id)
        public var stopSequence: Int? = nil
    }

    /// Reads downloaded data, also noting whether it parsed and whether it's stuck at an old time (warn even when the problem is on the official side)
    /// Recorded once per read, with the feed's time: recording "readable" first would clear the "not updating" count every time.
    public static func decode(_ data: Data, from url: URL, provider: String? = nil, now: Date = Date()) throws -> GTFSRealtimeFeed {
        let feed: GTFSRealtimeFeed
        do {
            feed = try decode(data)
        } catch {
            if !(error is CancellationError) { NetworkReach.recordBadData(url: url, provider: provider, now: now) }
            throw error
        }
        NetworkReach.recordGoodData(url: url, provider: provider, timestamp: feed.timestamp,
                                    hasTrips: !feed.tripUpdates.isEmpty, now: now)
        return feed
    }

    /// Most entities in one feed, and most stops in one trip. Real feeds have at most a few thousand trips, each with up to about a
    /// hundred stops; within the download size limit a broken or hostile server could otherwise send millions of tiny ones
    public static let maxEntities = 50_000
    public static let maxStopsPerTrip = 1_000

    /// An answer with neither a header nor a trip (an empty body most of all) throws: taken as a feed it would be "no train now",
    /// and every train of this feed would vanish as if just updated. A header with no trip is a real feed with no train
    public static func decode(_ data: Data) throws -> GTFSRealtimeFeed {
        var reader = ProtobufReader([UInt8](data))
        var feed = GTFSRealtimeFeed(timestamp: nil, tripUpdates: [])
        var entities = 0
        var sawHeader = false
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                sawHeader = true
                var sub = try reader.readLengthDelimited()
                feed.timestamp = try decodeHeaderTimestamp(&sub)
            case (2, 2):
                entities += 1
                guard entities <= maxEntities else { throw ProtobufError.tooMany }
                var sub = try reader.readLengthDelimited()
                if let update = try decodeEntity(&sub) { feed.tripUpdates.append(update) }
            default:
                try reader.skip(wireType: wire)
            }
        }
        guard sawHeader || entities > 0 else { throw ProtobufError.empty }
        return feed
    }

    private static func date(_ raw: UInt64) -> Date? {
        let seconds = Int64(bitPattern: raw)
        return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    private static func decodeHeaderTimestamp(_ r: inout ProtobufReader) throws -> Date? {
        var ts: Date?
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            if field == 3 && wire == 0 { ts = date(try r.readVarint()) } else { try r.skip(wireType: wire) }
        }
        return ts
    }

    private static func decodeEntity(_ r: inout ProtobufReader) throws -> TripUpdate? {
        var id = ""
        var deleted = false
        var update: TripUpdate?
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, 2): id = try r.readString()
            case (2, 0): deleted = try r.readVarint() != 0
            case (3, 2):
                var sub = try r.readLengthDelimited()
                update = try decodeTripUpdate(&sub)
            default: try r.skip(wireType: wire)
            }
        }
        guard !deleted, var u = update else { return nil }
        u.entityID = id
        return u
    }

    private static func decodeTripUpdate(_ r: inout ProtobufReader) throws -> TripUpdate {
        var u = TripUpdate(entityID: "", tripID: "", routeID: "", startDate: "", isCanceled: false, timestamp: nil, stopTimeUpdates: [])
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (1, 2):
                var sub = try r.readLengthDelimited()
                while !sub.isAtEnd {
                    let (f, w) = try sub.readTag()
                    switch (f, w) {
                    case (1, 2): u.tripID = try sub.readString()
                    case (3, 2): u.startDate = try sub.readString()
                    // CANCELED = 3, DELETED = 7 (added in newer versions of the spec; also means not running)
                    case (4, 0):
                        let relationship = try sub.readVarint()
                        u.isCanceled = relationship == 3 || relationship == 7
                    case (5, 2): u.routeID = try sub.readString()
                    case (1001, 2):
                        var nyct = try sub.readLengthDelimited()
                        while !nyct.isAtEnd {
                            let (nf, nw) = try nyct.readTag()
                            if nf == 2 && nw == 0 { u.isAssigned = try nyct.readVarint() != 0 } else { try nyct.skip(wireType: nw) }
                        }
                    default: try sub.skip(wireType: w)
                    }
                }
            case (2, 2):
                guard u.stopTimeUpdates.count < maxStopsPerTrip else { throw ProtobufError.tooMany }
                var sub = try r.readLengthDelimited()
                u.stopTimeUpdates.append(try decodeStopTimeUpdate(&sub))
            case (3, 2):
                var sub = try r.readLengthDelimited()
                while !sub.isAtEnd {
                    let (f, w) = try sub.readTag()
                    if f == 2 && w == 2 { u.vehicleLabel = try sub.readString() } else { try sub.skip(wireType: w) }
                }
            case (4, 0):
                u.timestamp = date(try r.readVarint())
            default:
                try r.skip(wireType: wire)
            }
        }
        return u
    }

    private static func decodeStopTimeUpdate(_ r: inout ProtobufReader) throws -> StopTimeUpdate {
        var s = StopTimeUpdate(stopID: "", arrivalTime: nil, departureTime: nil, isSkipped: false, hasNoData: false)
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch (field, wire) {
            case (2, 2):
                var sub = try r.readLengthDelimited()
                let e = try decodeEventTime(&sub)
                s.arrivalTime = e.time
                if let d = e.delay { s.delaySeconds = d }
            case (3, 2):
                var sub = try r.readLengthDelimited()
                let e = try decodeEventTime(&sub)
                s.departureTime = e.time
                if s.delaySeconds == nil, let d = e.delay { s.delaySeconds = d }
            case (1, 0):
                s.stopSequence = Int(exactly: try r.readVarint())
            case (4, 2):
                s.stopID = try r.readString()
            case (5, 0):
                let rel = try r.readVarint()
                s.isSkipped = rel == 1
                s.hasNoData = rel == 2
            default:
                try r.skip(wireType: wire)
            }
        }
        return s
    }

    /// StopTimeEvent: time (field 2) and delay (field 1, int32; negatives encoded as 64-bit two's complement).
    private static func decodeEventTime(_ r: inout ProtobufReader) throws -> (time: Date?, delay: Int?) {
        var t: Date?
        var d: Int?
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            if field == 2 && wire == 0 {
                t = date(try r.readVarint())
            } else if field == 1 && wire == 0 {
                d = Int(Int32(truncatingIfNeeded: Int64(bitPattern: try r.readVarint())))
            } else {
                try r.skip(wireType: wire)
            }
        }
        return (t, d)
    }
}
