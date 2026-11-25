import Foundation
#if canImport(Compression)
import Compression
#endif

// MARK: - Reading GTFS text in chunks
//
// Bus stop_times.txt is 155 MB unzipped and can't fit in memory whole. The data is handed to GTFSRowReader chunk by chunk
// (read while unzipping from the archive, or read from a file in chunks); it assembles complete lines and passes them to body,
// with results exactly the same as TimetableBuilder.forEachRow reading the whole file.

/// CSV (GTFS text) read in chunks. The data may break anywhere: in the middle of a multi-byte UTF-8 character or between \r and \n.
/// The first line is the header, and body looks up values by column name; BOM, CRLF and commas inside quotes are handled the same as TimetableBuilder.forEachRow.
public final class GTFSRowReader {
    private let body: (_ column: (String) -> String?) throws -> Void
    /// Column name → column index. nil until the first line is read.
    private var header: [String: Int]?
    /// The partial line left unfinished at the end of the previous chunk
    private var pending: [UInt8] = []
    /// Comma positions in the current line (for the fast path)
    private var commas: [Int] = []
    /// Longest line accepted. Real GTFS lines are a few hundred bytes; a feed with no newlines would otherwise grow `pending` without limit.
    public static let maxLineBytes = 1 << 20

    public init(_ body: @escaping (_ column: (String) -> String?) throws -> Void) {
        self.body = body
    }

    /// Feed the next chunk of data. Complete lines go to body immediately; the last incomplete line waits for the next chunk.
    public func feed(_ chunk: Data) throws {
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var start = 0
            while start < n, let hit = memchr(base + start, 0x0A, n - start) {
                let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                if pending.isEmpty {
                    try line(UnsafeBufferPointer(start: base + start, count: end - start))
                } else {
                    try appendPending(base + start, end - start)
                    try flushPending()
                }
                start = end + 1
            }
            if start < n {
                try appendPending(base + start, n - start)
            }
        }
    }

    /// Data is finished: if the last line has no newline, hand it to body here.
    public func finish() throws {
        guard !pending.isEmpty else { return }
        try flushPending()
    }

    private func appendPending(_ bytes: UnsafePointer<UInt8>, _ count: Int) throws {
        guard pending.count + count <= Self.maxLineBytes else { throw TimetableError.badFormat }
        pending.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
    }

    private func flushPending() throws {
        defer { pending.removeAll(keepingCapacity: true) }
        try pending.withUnsafeBufferPointer { try line($0) }
    }

    /// One line (without \n). Same as forEachRow: strip one trailing \r, skip empty lines, the first line is the header (BOM removed).
    private func line(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        // The same limit as for a line split between chunks (appendPending), so where the data breaks doesn't change the answer
        guard bytes.count <= Self.maxLineBytes else { throw TimetableError.badFormat }
        guard let base = bytes.baseAddress else { return }
        var n = bytes.count
        if n > 0, base[n - 1] == 0x0D { n -= 1 }
        guard n > 0 else { return }
        guard let header else {
            var text = String(decoding: UnsafeBufferPointer(start: base, count: n), as: UTF8.self)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            var h: [String: Int] = [:]
            for (k, f) in TimetableBuilder.splitCSV(text).enumerated() { h[f.trimmingCharacters(in: .whitespaces)] = k }
            header = h
            return
        }
        if splitSimple(base, n) {
            // Only build a column's string when that column is used
            let count = commas.count + 1
            try commas.withUnsafeBufferPointer { cs in
                try body { name in
                    guard let k = header[name], k < count else { return nil }
                    let s = k == 0 ? 0 : cs[k - 1] + 1
                    let e = k < cs.count ? cs[k] : n
                    return String(decoding: UnsafeBufferPointer(start: base + s, count: e - s), as: UTF8.self)
                }
            }
        } else {
            let fields = TimetableBuilder.splitCSV(String(decoding: UnsafeBufferPointer(start: base, count: n), as: UTF8.self))
            try body { name in
                guard let k = header[name], k < fields.count else { return nil }
                return fields[k]
            }
        }
    }

    /// Lines with no quotes and ASCII on both sides of every comma: splitting by bytes gives the same result as splitCSV splitting by characters
    /// (a comma only stops being a separator when it combines with an adjacent non-ASCII character into one character). Records comma positions.
    private func splitSimple(_ base: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        commas.removeAll(keepingCapacity: true)
        if memchr(base, 0x22, n) != nil { return false }
        var p = 0
        while p < n, let hit = memchr(base + p, 0x2C, n - p) {
            let i = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            if i > 0, base[i - 1] >= 0x80 { return false }
            if i + 1 < n, base[i + 1] >= 0x80 { return false }
            commas.append(i)
            p = i + 1
        }
        return true
    }
}

// MARK: - Reading a ZIP's directory, its limits and checksums (no unzipping: also built and tested on Linux)

extension ZipReader {
    /// Size of each piece handed to chunk (unzipped)
    static let streamChunkSize = 1 << 20
    /// Largest unzipped file accepted. The biggest real file is about 155 MB (bus stop_times.txt); a broken or hostile
    /// server could otherwise declare gigabytes and run the app or the widget out of memory.
    static let maxEntrySize = 400 << 20
    /// Most unzipped bytes read whole into memory from one archive at a time (read and extract; a file read while unzipping,
    /// line by line, doesn't count: it is never held whole)
    static let maxWholeTotal = 400 << 20
    /// Most files in one archive (a GTFS package has about 10 to 20)
    static let maxEntries = 1_000
    /// Highest unzipped/zipped ratio accepted (real GTFS text compresses about 5 to 15 times), for files over ratioCheckedAbove:
    /// tiny files can compress further and don't matter
    static let maxCompressionRatio = 200
    static let ratioCheckedAbove = 1 << 20
    /// Most bytes reserved up front for one extracted file; the header's size is not trusted for the allocation
    static let maxPreallocation = 16 << 20

    static func checkLimits(_ m: Member) throws {
        guard m.size <= maxEntrySize else { throw ZipError.unsupported("entry too large: \(m.size)") }
        if m.size > ratioCheckedAbove, m.size / max(m.compressedSize, 1) > maxCompressionRatio {
            throw ZipError.unsupported("compression ratio too high")
        }
        // A stored (uncompressed) file is as long as it says
        if m.method == 0, m.compressedSize != m.size { throw ZipError.corrupt("stored size") }
    }

    /// The files about to be read whole, together, aren't more than maxWholeTotal
    static func checkWholeTotal(_ members: [Member]) throws {
        let total = members.reduce(0) { $0 + $1.size }
        guard total <= maxWholeTotal else { throw ZipError.unsupported("files too large together: \(total)") }
    }

    struct Member {
        var method: Int
        /// Start of the compressed data in the zip
        var start: Int
        var compressedSize: Int
        var size: Int
        /// The CRC-32 the archive gives for the unzipped file
        var crc: UInt32
    }

    /// Find a file in the central directory.
    static func member(named name: String, in bytes: UnsafeRawBufferPointer) throws -> Member {
        guard let found = try members(in: bytes)[name] else { throw TimetableError.missingFile(name) }
        return found
    }

    /// All files in the central directory (names by last path component; with several of the same name, the last one is used).
    static func members(in bytes: UnsafeRawBufferPointer) throws -> [String: Member] {
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }

        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var p = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while p >= lowest {
            if u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        guard count <= maxEntries else { throw ZipError.unsupported("too many files: \(count)") }
        var cd = u32(eocd + 16)

        var found: [String: Member] = [:]
        for _ in 0..<count {
            guard cd + 46 <= bytes.count, u32(cd) == 0x0201_4b50 else { throw ZipError.corrupt("central directory") }
            let method = u16(cd + 10)
            let crc = UInt32(u32(cd + 16))
            let compressedSize = u32(cd + 20)
            let size = u32(cd + 24)
            let nameLength = u16(cd + 28)
            let extraLength = u16(cd + 30)
            let commentLength = u16(cd + 32)
            let localOffset = u32(cd + 42)
            guard cd + 46 + nameLength <= bytes.count else { throw ZipError.corrupt("name") }
            let fullName = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(cd + 46)..<(cd + 46 + nameLength)]),
                                  as: UTF8.self)
            cd += 46 + nameLength + extraLength + commentLength

            let short = fullName.split(separator: "/").last.map(String.init) ?? fullName
            if fullName.hasSuffix("/") { continue }

            guard localOffset + 30 <= bytes.count, u32(localOffset) == 0x0403_4b50 else { throw ZipError.corrupt("local header") }
            let start = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
            guard start + compressedSize <= bytes.count else { throw ZipError.corrupt("data") }
            found[short] = Member(method: method, start: start, compressedSize: compressedSize, size: size, crc: crc)
        }
        return found
    }

    /// The ZIP format's CRC-32 of the unzipped bytes, worked out piece by piece while a file is read, so a damaged file is
    /// caught even where unzipping itself doesn't notice (a stored file, or a flipped byte the deflate data still decodes)
    struct Checksum {
        private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
        private var state: UInt32 = 0xFFFF_FFFF

        mutating func add(_ data: Data) {
            let before = state
            state = Self.table.withUnsafeBufferPointer { table in
                data.withUnsafeBytes { Self.update(before, $0, table) }
            }
        }

        /// Optimized also in Debug builds, as a 155 MB file goes through here
        @_optimize(speed)
        private static func update(_ start: UInt32, _ bytes: UnsafeRawBufferPointer, _ table: UnsafeBufferPointer<UInt32>) -> UInt32 {
            var c = start
            var i = 0
            while i < bytes.count {
                c = table[Int((c ^ UInt32(bytes[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
            return c
        }

        var value: UInt32 { state ^ 0xFFFF_FFFF }
    }
}

#if canImport(Compression)
extension ZipReader {
    /// Read a file while unzipping, handing about 1 MB to chunk at a time, without putting the whole file (e.g. the 155 MB bus stop_times.txt) in memory.
    /// File names are compared by last path component like extract; with several of the same name, the last one is used (same as extract). Throws if not found.
    public static func stream(_ zip: Data, name: String, _ chunk: (Data) throws -> Void) throws {
        try zip.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try stream(member(named: name, in: raw), in: raw, chunk)
        }
    }

    /// Hand an already-found file to chunk while unzipping (read / extract read the directory once, then use this, so the directory isn't reread for each file).
    /// The file's CRC-32 is checked at the end: a mismatch throws after the last piece, so whatever was built from the pieces
    /// must be thrown away by the caller (every caller builds into memory and keeps the old data when this throws)
    static func stream(_ m: Member, in raw: UnsafeRawBufferPointer, _ chunk: (Data) throws -> Void) throws {
        try checkLimits(m)
        let compressed = UnsafeRawBufferPointer(rebasing: raw[m.start..<(m.start + m.compressedSize)])
        var checksum = Checksum()
        switch m.method {
        case 0:
            var p = 0
            while p < compressed.count {
                let n = min(streamChunkSize, compressed.count - p)
                let piece = Data(bytes: compressed.baseAddress! + p, count: n)
                checksum.add(piece)
                try chunk(piece)
                p += n
            }
        case 8:
            try inflateStream(compressed, size: m.size) { piece in
                checksum.add(piece)
                try chunk(piece)
            }
        default:
            throw ZipError.unsupported("method \(m.method)")
        }
        guard checksum.value == m.crc else { throw ZipError.corrupt("checksum") }
    }

    /// Every line of a file (read while unzipping, used the same way as TimetableBuilder.forEachRow).
    public static func forEachRow(_ zip: Data, name: String,
                                  _ body: @escaping (_ column: (String) -> String?) throws -> Void) throws {
        let reader = GTFSRowReader(body)
        try stream(zip, name: name) { try reader.feed($0) }
        try reader.finish()
    }

    /// Whether the archive contains this file (some bus operators' data has no shapes.txt)
    public static func contains(_ zip: Data, name: String) -> Bool {
        (try? zip.withUnsafeBytes { try member(named: name, in: $0) }) != nil
    }

    /// Unzip several files (file name → contents), same result as extract, but without first copying the whole archive like extract does
    /// (the bus data archive is 20 MB). Files not in the archive are left out of the result.
    public static func read(_ zip: Data, names: [String]) throws -> [String: Data] {
        try zip.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let all = try members(in: raw)
            let wanted = Set(names).compactMap { name in all[name].map { (name, $0) } }
            try checkWholeTotal(wanted.map { $0.1 })
            var result: [String: Data] = [:]
            for (name, m) in wanted {
                try checkLimits(m)
                var data = Data(capacity: min(m.size, maxPreallocation))
                try stream(m, in: raw) { data.append($0) }
                result[name] = data
            }
            return result
        }
    }

    /// Chunked deflate decompression: input is given all at once, output is handed off every time 1 MB fills up.
    static func inflateStream(_ input: UnsafeRawBufferPointer, size: Int, _ chunk: (Data) throws -> Void) throws {
        if size == 0 { return }
        guard let src = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw ZipError.corrupt("inflate") }
        let capacity = streamChunkSize
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }

        var stream = compression_stream(dst_ptr: dst, dst_size: capacity, src_ptr: src, src_size: input.count, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("inflate init")
        }
        defer { _ = compression_stream_destroy(&stream) }
        stream.src_ptr = src
        stream.src_size = input.count
        stream.dst_ptr = dst
        stream.dst_size = capacity

        var total = 0
        while true {
            let before = stream.src_size
            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = capacity - stream.dst_size
            if produced > 0 {
                total += produced
                guard total <= size else { throw ZipError.corrupt("inflate \(total)/\(size)") }
                try chunk(Data(bytes: dst, count: produced))
                stream.dst_ptr = dst
                stream.dst_size = capacity
            }
            if status == COMPRESSION_STATUS_END { break }
            // Error, or neither produced output nor consumed input (incomplete data)
            guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < before else {
                throw ZipError.corrupt("inflate \(total)/\(size)")
            }
        }
        guard total == size else { throw ZipError.corrupt("inflate \(total)/\(size)") }
    }
}
#endif

/// Large packages are read, built and saved one at a time, first come first served: each holds its own working copy while it's
/// built, so several at once add up (the MBTA's one package feeds four modes, and a Mac measured over 1 GB with all four at once).
/// enter() waits for the turn; every enter() needs one leave(), also when the work throws. A wait isn't cancelled: the work checks
/// for cancellation once it's its turn
public actor OneAtATime {
    public static let largePackages = OneAtATime()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// The next one waiting gets the turn (busy stays set), or no one has it
    public func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
