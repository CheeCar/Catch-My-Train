import Foundation

// Where things are saved, and how the widget gets what it shows.
//
// - What belongs to the user (favorites, recent places, the chosen place, every setting) is saved in the program's own settings
//   (SharedDefaults.current), which macOS keeps in that program's container: other apps can't read it.
// - What the app and the widget both use (the snapshot the widget shows, the selected station, start / standby and a few more
//   small files) is in one plain folder in the user's Library (SharedFolder). Everything in it can be made again.
// - The few settings the widget needs travel in that folder as a small file (WidgetHandoff).
//
// An App Group would hold all of this in one place, but macOS only lets a build signed with a developer team use one. A build
// without one (the ad-hoc builds this app is given out as) gets a folder path and then can't save anything in it. So every build
// works the same way, the one way that works for all of them.

/// The plain folder the app and its widget share: Library/Application Support/com.cheecar.CatchMyTrain in the user's home folder.
/// Both are sandboxed; each is allowed into this one folder by an exception in its entitlements, which names `homeRelativePath`.
public enum SharedFolder {
    public static let name = "com.cheecar.CatchMyTrain"

    /// The folder as the entitlements name it: relative to the home folder, with the slash at the end that makes it mean
    /// "this folder and what's in it"
    public static let homeRelativePath = "/Library/Application Support/" + name + "/"

    /// The entitlement both the app and the widget carry for it
    public static let entitlement = "com.apple.security.temporary-exception.files.home-relative-path.read-write"

    public static func url(inHome home: URL) -> URL {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The user's real home folder. In a sandboxed program NSHomeDirectory() is the program's own container, so the account's
    /// record is asked instead
    public static var realHome: URL {
        var home = NSHomeDirectory()
        if let record = getpwuid(getuid()), let dir = record.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    static let checkFileName = "folder-check"
    static let checkBytes = Data("ok".utf8)

    public enum CheckError: Error, Equatable {
        /// The small file was written, but reading it back gave something else
        case readBackDiffers
    }

    /// Whether the folder can really be used: makes it when it isn't there, writes a small file into it and reads it back.
    /// Throws what went wrong. (That the system hands out a path says nothing: an App Group's path comes back too, in a build
    /// that can't save anything there.)
    public static func check(_ folder: URL) throws {
        try make(folder)
        let url = folder.appendingPathComponent(checkFileName)
        try checkBytes.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == checkBytes else { throw CheckError.readBackDiffers }
    }

    /// Makes the folder, for this user only
    public static func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// The few settings the widget needs from the app. The widget can't read the app's settings (each program has its own), so the
/// app writes these into the shared folder whenever one changes, and the widget takes them into its own settings before it draws
/// or downloads. The rest of the widget's code then reads them as if they had been saved there.
public struct WidgetHandoff: Codable, Equatable {
    public static let fileName = "app-settings.json"

    /// The names these settings are saved under, in the app's settings and in the widget's
    public enum Key {
        public static let refreshInterval = "refreshIntervalSeconds"
        public static let dataSource = "dataSource"
        public static let language = "appLanguage"
        public static let units = "distanceUnit"
        public static let clock = "clockStyle"
    }

    /// "Allow network" in Settings (NetworkSwitch)
    public var networkAllowed: Bool
    /// The others as they are saved; nil where nothing is saved (the default applies)
    public var refreshIntervalSeconds: Double?
    public var dataSource: String?
    public var appLanguage: String?
    public var distanceUnit: String?
    public var clockStyle: String?

    public init(networkAllowed: Bool, refreshIntervalSeconds: Double? = nil, dataSource: String? = nil, appLanguage: String? = nil,
                distanceUnit: String? = nil, clockStyle: String? = nil) {
        self.networkAllowed = networkAllowed
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.dataSource = dataSource
        self.appLanguage = appLanguage
        self.distanceUnit = distanceUnit
        self.clockStyle = clockStyle
    }

    /// What `defaults` (the app's settings) has now
    public init(in defaults: UserDefaults) {
        networkAllowed = NetworkSwitch.isAllowed(in: defaults)
        refreshIntervalSeconds = defaults.object(forKey: Key.refreshInterval) == nil ? nil : defaults.double(forKey: Key.refreshInterval)
        dataSource = defaults.string(forKey: Key.dataSource)
        appLanguage = defaults.string(forKey: Key.language)
        distanceUnit = defaults.string(forKey: Key.units)
        clockStyle = defaults.string(forKey: Key.clock)
    }

    /// Puts a handoff into `defaults` (the widget's own settings), saving only what differs. A setting the app hasn't saved is
    /// removed, so the widget uses the same default as the app.
    /// With no handoff (the app hasn't written one yet, or it can't be read) only the network switch changes: it goes off,
    /// because the widget can't know that the user allows the network.
    public static func adopt(_ handoff: WidgetHandoff?, into defaults: UserDefaults) {
        guard let handoff else {
            if NetworkSwitch.isAllowed(in: defaults) { NetworkSwitch.setAllowed(false, in: defaults) }
            return
        }
        if NetworkSwitch.isAllowed(in: defaults) != handoff.networkAllowed { NetworkSwitch.setAllowed(handoff.networkAllowed, in: defaults) }
        let saved = defaults.object(forKey: Key.refreshInterval) == nil ? nil : defaults.double(forKey: Key.refreshInterval)
        if saved != handoff.refreshIntervalSeconds {
            if let seconds = handoff.refreshIntervalSeconds {
                defaults.set(seconds, forKey: Key.refreshInterval)
            } else {
                defaults.removeObject(forKey: Key.refreshInterval)
            }
        }
        put(handoff.dataSource, Key.dataSource, in: defaults)
        put(handoff.appLanguage, Key.language, in: defaults)
        put(handoff.distanceUnit, Key.units, in: defaults)
        put(handoff.clockStyle, Key.clock, in: defaults)
    }

    private static func put(_ value: String?, _ key: String, in defaults: UserDefaults) {
        guard defaults.string(forKey: key) != value else { return }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Reads the handoff file in `folder`; nil when it isn't there or can't be read
    public static func read(in folder: URL) -> WidgetHandoff? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetHandoff.self, from: data)
    }
}
