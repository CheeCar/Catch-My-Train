import XCTest
@testable import TransitCore

/// ZIP extraction exists only on macOS (uses the system Compression framework); skipped on Linux.
final class ZipReaderTests: XCTestCase {
    /// Generated with Python zipfile: deflate-compressed calendar.txt, trips.txt in a subfolder, uncompressed stored.txt
    static let fixture = "UEsDBBQAAAAIADi1TV2zFqHvIwAAADACAAAMAAAAY2FsZW5kYXIudHh0K04tKstMTo3PTNHJzc9LSazkCk9NzQbSOoZcxaNyo3JocgBQSwMEFAAAAAgAOLVNXT0p2RQWAAAAFgAAABAAAABmb2xkZXIvdHJpcHMudHh0K8ovLUmNz0zRKSnKLADSXOY6IYZcAFBLAwQUAAAAAAA4tU1dwkEkNQMAAAADAAAACgAAAHN0b3JlZC50eHRhYmNQSwECFAMUAAAACAA4tU1dsxah7yMAAAAwAgAADAAAAAAAAAAAAAAAgAEAAAAAY2FsZW5kYXIudHh0UEsBAhQDFAAAAAgAOLVNXT0p2RQWAAAAFgAAABAAAAAAAAAAAAAAAIABTQAAAGZvbGRlci90cmlwcy50eHRQSwECFAMUAAAAAAA4tU1dwkEkNQMAAAADAAAACgAAAAAAAAAAAAAAgAGRAAAAc3RvcmVkLnR4dFBLBQYAAAAAAwADALAAAAC8AAAAAAA="

    func testExtract() throws {
        #if canImport(Compression)
        let zip = try XCTUnwrap(Data(base64Encoded: Self.fixture))
        let all = try ZipReader.extract(zip)
        XCTAssertEqual(String(decoding: all["calendar.txt"]!, as: UTF8.self),
                       String(repeating: "service_id,monday\nWeekday,1\n", count: 20))
        XCTAssertEqual(String(decoding: all["trips.txt"]!, as: UTF8.self), "route_id,trip_id\n7,T1\n")
        XCTAssertEqual(String(decoding: all["stored.txt"]!, as: UTF8.self), "abc")
        XCTAssertEqual(Set(try ZipReader.extract(zip, names: ["trips.txt"]).keys), ["trips.txt"])
        XCTAssertThrowsError(try ZipReader.extract(Data("not a zip".utf8)))
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    /// A one-file zip whose headers declare `size` unzipped bytes and hold `payload` as the file's data (crc: the checksum
    /// written in the headers; by default the right one for a stored file's payload)
    static func zip(name: String, method: UInt16, size: UInt32, payload: [UInt8], crc: UInt32? = nil) -> Data {
        zip([(name, method, size, payload, crc)])
    }

    /// A zip with these files, each as in zip(name:method:size:payload:crc:)
    static func zip(_ files: [(name: String, method: UInt16, size: UInt32, payload: [UInt8], crc: UInt32?)]) -> Data {
        var out: [UInt8] = []
        func u16(_ v: UInt16) { out += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
        func checksum(_ f: (name: String, method: UInt16, size: UInt32, payload: [UInt8], crc: UInt32?)) -> UInt32 {
            if let crc = f.crc { return crc }
            var c = ZipReader.Checksum()
            c.add(Data(f.payload))
            return f.method == 0 ? c.value : 0
        }
        var offsets: [UInt32] = []
        for f in files {
            let n = Array(f.name.utf8)
            offsets.append(UInt32(out.count))
            // Local file header
            u32(0x0403_4b50); u16(20); u16(0); u16(f.method); u16(0); u16(0); u32(checksum(f))
            u32(UInt32(f.payload.count)); u32(f.size); u16(UInt16(n.count)); u16(0)
            out += n
            out += f.payload
        }
        // Central directory
        let cd = out.count
        for (f, offset) in Swift.zip(files, offsets) {
            let n = Array(f.name.utf8)
            u32(0x0201_4b50); u16(20); u16(20); u16(0); u16(f.method); u16(0); u16(0); u32(checksum(f))
            u32(UInt32(f.payload.count)); u32(f.size); u16(UInt16(n.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(offset)
            out += n
        }
        let cdSize = out.count - cd
        // End of central directory
        u32(0x0605_4b50); u16(0); u16(0); u16(UInt16(files.count)); u16(UInt16(files.count)); u32(UInt32(cdSize)); u32(UInt32(cd)); u16(0)
        return Data(out)
    }

    /// The checksum is the ZIP format's CRC-32, the same however the file is cut into pieces
    func testChecksumIsTheZipFormatsCRC32() {
        func crc(_ pieces: [String]) -> UInt32 {
            var c = ZipReader.Checksum()
            for p in pieces { c.add(Data(p.utf8)) }
            return c.value
        }
        XCTAssertEqual(crc([]), 0)
        XCTAssertEqual(crc(["123456789"]), 0xCBF4_3926)
        XCTAssertEqual(crc(["1234", "", "56789"]), 0xCBF4_3926)
        XCTAssertEqual(crc(["abc"]), 0x3524_41C2)
    }

    /// The archive's directory and the limits read from it, before anything is unzipped (also on Linux)
    func testDirectoryLimits() throws {
        func members(_ zip: Data) throws -> [String: ZipReader.Member] {
            try zip.withUnsafeBytes { try ZipReader.members(in: $0) }
        }
        // The helper's zip is read right: names by their last part, and the checksum the headers give
        let two = Self.zip([("folder/stops.txt", 0, 3, Array("abc".utf8), nil), ("trips.txt", 0, 2, Array("xy".utf8), nil)])
        let found = try members(two)
        XCTAssertEqual(Set(found.keys), ["stops.txt", "trips.txt"])
        XCTAssertEqual(found["stops.txt"]?.crc, 0x3524_41C2)
        XCTAssertEqual(found["stops.txt"]?.size, 3)

        // More files than any GTFS package has
        let many = Self.zip((0...ZipReader.maxEntries).map { ("f\($0).txt", 0, 1, [0x41], nil) })
        XCTAssertThrowsError(try members(many)) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .unsupported("too many files: \(ZipReader.maxEntries + 1)"))
        }
        let most = Self.zip((1...ZipReader.maxEntries).map { ("f\($0).txt", 0, 1, [0x41], nil) })
        XCTAssertEqual(try members(most).count, ZipReader.maxEntries)

        // A stored file must be as long as it says
        let short = try XCTUnwrap(members(Self.zip(name: "stops.txt", method: 0, size: 5, payload: Array("abc".utf8)))["stops.txt"])
        XCTAssertThrowsError(try ZipReader.checkLimits(short)) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .corrupt("stored size"))
        }

        // The compression ratio counts from 1 MB: 2 MB from 1 KB is refused, half a megabyte from 1 KB isn't
        func deflated(_ size: Int) throws -> ZipReader.Member {
            try XCTUnwrap(members(Self.zip(name: "shapes.txt", method: 8, size: UInt32(size), payload: [UInt8](repeating: 0, count: 1024)))["shapes.txt"])
        }
        XCTAssertThrowsError(try ZipReader.checkLimits(deflated(2 << 20))) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .unsupported("compression ratio too high"))
        }
        XCTAssertNoThrow(try ZipReader.checkLimits(deflated(512 << 10)))

        // Files read whole from one archive: at most maxWholeTotal together, though each is under the limit for one
        let big = try deflated(1)
        var each = big
        each.size = 150 << 20
        XCTAssertNoThrow(try ZipReader.checkWholeTotal([each, each]))
        XCTAssertThrowsError(try ZipReader.checkWholeTotal([each, each, each])) { error in
            guard case ZipReader.ZipError.unsupported = error else { return XCTFail("\(error)") }
        }
    }

    /// A file whose bytes don't match the checksum in the archive is refused, whole or read line by line
    func testRejectsAWrongChecksum() throws {
        #if canImport(Compression)
        let good = Self.zip(name: "stops.txt", method: 0, size: 3, payload: Array("abc".utf8))
        XCTAssertEqual(try ZipReader.read(good, names: ["stops.txt"])["stops.txt"], Data("abc".utf8))
        let bad = Self.zip(name: "stops.txt", method: 0, size: 3, payload: Array("abc".utf8), crc: 0x1234_5678)
        XCTAssertThrowsError(try ZipReader.extract(bad)) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .corrupt("checksum"))
        }
        XCTAssertThrowsError(try ZipReader.read(bad, names: ["stops.txt"]))
        XCTAssertThrowsError(try ZipReader.forEachRow(bad, name: "stops.txt") { _ in })
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    func testRejectsOversizedAndOvercompressedEntries() throws {
        #if canImport(Compression)
        // The helper makes a valid zip
        let plain = Self.zip(name: "stops.txt", method: 0, size: 3, payload: Array("abc".utf8))
        XCTAssertEqual(try ZipReader.extract(plain)["stops.txt"], Data("abc".utf8))

        // Declared size above the limit: refused before anything is allocated or unzipped
        let huge = Self.zip(name: "stop_times.txt", method: 0, size: 500 << 20, payload: Array("abc".utf8))
        XCTAssertThrowsError(try ZipReader.extract(huge)) { error in
            guard case ZipReader.ZipError.unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ZipReader.forEachRow(huge, name: "stop_times.txt") { _ in })

        // 20 MB claimed from 1 KB of deflate data: ratio far above any real feed
        let bomb = Self.zip(name: "shapes.txt", method: 8, size: 20 << 20, payload: [UInt8](repeating: 0, count: 1024))
        XCTAssertThrowsError(try ZipReader.read(bomb, names: ["shapes.txt"])) { error in
            guard case ZipReader.ZipError.unsupported = error else { return XCTFail("\(error)") }
        }
        #else
        throw XCTSkip("The Compression framework is only available on Apple platforms")
        #endif
    }

    func testRejectsEndlessLine() throws {
        let reader = GTFSRowReader { _ in }
        try reader.feed(Data("stop_id,stop_name\n".utf8))
        let chunk = Data(repeating: 0x41, count: 512 << 10)
        try reader.feed(chunk)
        XCTAssertThrowsError(try { for _ in 0..<4 { try reader.feed(chunk) } }()) { error in
            XCTAssertEqual(error as? TimetableError, .badFormat)
        }
        // The same line in one chunk or split in two: the same answer. One just at the limit is read, one byte more isn't
        let limit = GTFSRowReader.maxLineBytes
        for length in [limit, limit + 1] {
            let data = Data("stop_id\n".utf8) + Data(repeating: 0x41, count: length) + Data("\n".utf8)
            for cut in [nil, 8 + length / 2] as [Int?] {
                var rows = 0
                let r = GTFSRowReader { _ in rows += 1 }
                let read = Result {
                    if let cut {
                        try r.feed(data.prefix(cut))
                        try r.feed(data.dropFirst(cut))
                    } else {
                        try r.feed(data)
                    }
                    try r.finish()
                }
                let how = cut == nil ? "whole" : "split"
                if length == limit {
                    XCTAssertNoThrow(try read.get(), how)
                    XCTAssertEqual(rows, 1, how)
                } else {
                    XCTAssertThrowsError(try read.get(), how) { XCTAssertEqual($0 as? TimetableError, .badFormat) }
                }
            }
        }
    }
}
