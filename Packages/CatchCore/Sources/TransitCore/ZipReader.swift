import Foundation
#if canImport(Compression)
import Compression
#endif

/// Reads ZIP archives (MTA's timetable is gtfs_subway.zip). Only plain ZIPs are supported: stored or deflate-compressed, under 4 GB.
/// Decompressed with macOS's built-in Compression framework, no third-party library needed.
public enum ZipReader {

    public enum ZipError: Error, Equatable {
        case notZip
        case unsupported(String)
        case corrupt(String)
    }
}

#if canImport(Compression)
extension ZipReader {
    /// Extract the needed files (file name → contents). Extracts everything when `names` is nil.
    /// Reading the directory and decompressing share the same code as read / stream (see GTFSStream.swift).
    public static func extract(_ zip: Data, names: Set<String>? = nil) throws -> [String: Data] {
        try zip.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let wanted = try members(in: raw).filter { names?.contains($0.key) ?? true }
            try checkWholeTotal(Array(wanted.values))
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
}
#endif
