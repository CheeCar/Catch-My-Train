import Foundation

/// Keyboard shortcuts in the menu bar at the top of the screen (Settings lists all shortcuts and they can be changed or removed, but
/// only to ⌘ plus one other key). Only the app's features have one: How It Works is an explanation, not a feature, so it has none.
/// A key saved for it by an older version is dropped when the map is read (see ShortcutMap.decode)
public enum AppShortcut: String, CaseIterable, Codable, Sendable {
    case subway, bus, train, ferry
    case nearby, planTrip, map
    case startStandby, refresh, choosePlace

    /// Default keys (all ⌘ plus this key). Nearby and Start / Standby have none: ⌘N and ⌘S are New and Save in most Mac apps,
    /// so they're free for whoever wants them
    public var defaultKey: String? {
        switch self {
        case .subway: return "1"
        case .bus: return "2"
        case .train: return "3"
        case .ferry: return "4"
        case .nearby: return nil
        case .planTrip: return "t"
        case .map: return "k"
        case .startStandby: return nil
        case .refresh: return "r"
        case .choosePlace: return "l"
        }
    }

    /// The default keys of earlier versions, when Nearby had ⌘N and Start / Standby ⌘S: kept for someone who had turned shortcuts
    /// on and used them (see ShortcutMap.keepEarlierDefaults)
    public var earlierDefaultKey: String? {
        switch self {
        case .nearby: return "n"
        case .startStandby: return "s"
        default: return defaultKey
        }
    }

    /// ⌘ shortcuts macOS and text editing need, which can't be used:
    /// Quit, Close Window, Hide, Minimize, Settings, switch windows, Copy, Paste, Cut, Select All, Undo, Redo (⌘⇧Z is also Z).
    public static let reserved: Set<String> = ["q", "w", "h", "m", ",", "`", "c", "v", "x", "a", "z"]

    /// Allowed keys: letters, digits and a few common symbols (no Shift needed with ⌘).
    public static let allowed: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789-=[];'\\./".map { String($0) })

    /// The key a key press records in Settings: the character the key gives on its own, or, when that isn't a plain Latin letter,
    /// digit or symbol (a Cyrillic or Hebrew letter, say), the one it gives with ⌘ held, which most keyboard layouts for other
    /// scripts make Latin (the menus find their shortcuts the same way). Lowercased; nil when neither is one printable ASCII
    /// character (a function or arrow key, for example). Whether the key can be used is checked after (ShortcutMap.problem)
    public static func recordedKey(plain: String?, withCommand: String?) -> String? {
        for text in [plain, withCommand] {
            guard let key = text?.lowercased(), key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
                  scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F else { continue }
            return key
        }
        return nil
    }

    public enum Problem: Equatable, Sendable {
        /// Not ⌘ plus one letter, digit or symbol
        case notAllowed
        /// Used by macOS itself
        case reserved
        /// Already assigned to another item
        case usedBy(AppShortcut)
    }
}

/// Which key each item uses now. Only changed ones are stored; unchanged ones use the default key (or have none, as their default).
public struct ShortcutMap: Codable, Equatable, Sendable {
    /// The changed items: their key, or "" for an item whose default key was removed
    public private(set) var custom: [String: String] = [:]

    public init() {}

    /// The item's key now; nil when it has none
    public func key(for s: AppShortcut) -> String? {
        guard let k = custom[s.rawValue] else { return s.defaultKey }
        return k.isEmpty ? nil : k
    }

    /// Check before changing an item to this key. nil = allowed.
    public func problem(with key: String, for s: AppShortcut) -> AppShortcut.Problem? {
        let k = key.lowercased()
        guard AppShortcut.allowed.contains(k) else { return .notAllowed }
        if AppShortcut.reserved.contains(k) { return .reserved }
        if let other = AppShortcut.allCases.first(where: { $0 != s && self.key(for: $0) == k }) { return .usedBy(other) }
        return nil
    }

    /// Change the key. If not allowed, leaves it unchanged and returns the problem.
    @discardableResult
    public mutating func set(_ key: String, for s: AppShortcut) -> AppShortcut.Problem? {
        if let p = problem(with: key, for: s) { return p }
        let k = key.lowercased()
        custom[s.rawValue] = k == s.defaultKey ? nil : k
        return nil
    }

    /// Remove the item's key: it has none until one is set again (an item whose default is none just goes back to its default)
    public mutating func removeKey(for s: AppShortcut) {
        custom[s.rawValue] = s.defaultKey == nil ? nil : ""
    }

    public var isDefault: Bool { custom.isEmpty }

    public mutating func restoreDefaults() { custom = [:] }

    /// For someone who had turned shortcuts on while Nearby and Start / Standby still had ⌘N and ⌘S by default: each of them that
    /// wasn't changed keeps that key, as long as no other item uses it now. Items changed before stay as they were. Done once, on
    /// the first launch of a version without those defaults (see TransitModel)
    public mutating func keepEarlierDefaults() {
        for s in AppShortcut.allCases where custom[s.rawValue] == nil {
            guard let earlier = s.earlierDefaultKey, earlier != s.defaultKey,
                  !AppShortcut.allCases.contains(where: { $0 != s && key(for: $0) == earlier }) else { continue }
            custom[s.rawValue] = earlier
        }
    }

    /// Read from stored data. The saved map is checked as a whole, not item by item against defaults that are about to be
    /// replaced, so a swap made in Settings (Subway ⌘2, Bus ⌘1) comes back after relaunch. Bad data and disallowed keys are
    /// dropped; changed items that end up sharing a key go back to their default keys. A removed key ("") stays removed.
    public static func decode(_ data: Data?) -> ShortcutMap {
        guard let data, let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return ShortcutMap() }
        var map = ShortcutMap()
        for s in AppShortcut.allCases {
            guard let k = raw[s.rawValue]?.lowercased() else { continue }
            if k.isEmpty {
                // Removed; an item whose default is none has no key anyway
                if s.defaultKey != nil { map.custom[s.rawValue] = "" }
                continue
            }
            guard AppShortcut.allowed.contains(k), !AppShortcut.reserved.contains(k) else { continue }
            if k != s.defaultKey { map.custom[s.rawValue] = k }
        }
        // Defaults never clash with each other, so every clash has a changed item in it and the loop ends. Items with no key
        // don't clash
        var clashing: [AppShortcut]
        repeat {
            let keyed = AppShortcut.allCases.compactMap { s in map.key(for: s).map { (item: s, key: $0) } }
            let byKey = Dictionary(grouping: keyed, by: \.key)
            clashing = byKey.values.filter { $0.count > 1 }.flatMap { $0.map(\.item) }.filter { map.custom[$0.rawValue] != nil }
            for s in clashing { map.custom[s.rawValue] = nil }
        } while !clashing.isEmpty
        return map
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(custom)) ?? Data() }
}
