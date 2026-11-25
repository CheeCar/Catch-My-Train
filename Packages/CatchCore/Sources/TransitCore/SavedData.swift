import Foundation

/// Reads data saved on this Mac (favorites, recent places, etc.). Data saved by older versions must still be readable after an app update
/// (favorites and the like must not be lost when the user updates): if one item in a list can't be read, only that item is skipped and the rest are kept.
public enum SavedData {
    /// Reads a saved list. Returns nil if it isn't a list (the whole thing can't be read); callers must not overwrite it with an empty list.
    public static func list<T: Decodable>(_ type: T.Type, from data: Data) -> [T]? {
        guard let items = try? JSONDecoder().decode([Lenient<T>].self, from: data) else { return nil }
        return items.compactMap(\.value)
    }

    /// Reads a saved list item by item: nil in the place of each item that can't be read. Returns nil if it isn't a list.
    public static func entries<T: Decodable>(_ type: T.Type, from data: Data) -> [T?]? {
        guard let items = try? JSONDecoder().decode([Lenient<T>].self, from: data) else { return nil }
        return items.map(\.value)
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
