import Foundation

// MARK: - What the data in use has that this version doesn't know
//
// A few things the data doesn't carry are written in the app, in tables only an app update changes: the codes PATH's live data
// names its stations by, matched to its timetable's station names (PathLive.stationNames); the short names on train line badges
// (FerryFeed.railLines); the subway's signage direction names, which come with the app's own station list (StationCatalog.
// labelSource). Data with something these tables don't have is used all the same, and only that part shows less. This finds it,
// so Settings can say that a newer version may know it. It looks at the data in use, not at what an update changed, so it goes
// by itself once the app knows it.

public enum UnknownData {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// PATH stations whose live trains can't be shown: their timetable name or their live data code isn't in the table
        case stations
        /// Train lines whose name isn't in the table: their badges show the operator's own code
        case lines
        /// Subway stations the app's own list doesn't have: their directions say only where the trains end
        case directions
    }

    /// One operator's data with things of one kind this version doesn't know
    public struct Finding: Codable, Equatable, Hashable, Sendable {
        /// The operator, by its key in the log of data checks (DataChangeLog)
        public var key: String
        public var kind: Kind
        /// What isn't known, by the data's own ids (stations, lines, live data codes), sorted
        public var ids: [String]

        public init(key: String, kind: Kind, ids: [String]) {
            self.key = key
            self.kind = kind
            self.ids = ids
        }
    }

    /// PATH: its timetable's stations whose name no live data code stands for, and the live data's codes the table doesn't have
    public static func path(feed: FerryFeed?, liveCodes: Set<String> = []) -> Finding? {
        let named = Set(PathLive.stationNames.values)
        var ids = Set((feed?.piers ?? []).filter { FerryFeed.Source.path.owns(id: $0.id) && !named.contains($0.name) }.map(\.id))
        ids.formUnion(liveCodes.filter { PathLive.stationNames[$0] == nil })
        guard !ids.isEmpty else { return nil }
        return Finding(key: FerryFeed.Source.path.rawValue, kind: .stations, ids: ids.sorted())
    }

    /// The operators whose line badges come from the table (FerryFeed.railLines), but not Amtrak's: its dozens of lines not in
    /// the table get the initials of their names, as meant
    static let badgedSources = FerryFeed.railLines.keys.filter { $0 != .amtrakNY }

    /// Train lines (and the other lines named by the table) whose badge isn't in the table: the operator's own code shows
    public static func lines(feed: FerryFeed?) -> [Finding] {
        guard let feed else { return [] }
        var found: [FerryFeed.Source: Set<String>] = [:]
        for route in feed.routes {
            guard let source = FerryFeed.Source.of(route: route.id), badgedSources.contains(source),
                  !FerryFeed.isShoreLineEast(route.id), route.id != FerryFeed.mbtaCapeFlyerRoute else { continue }
            let code = FerryFeed.badge(route.id)
            if !(FerryFeed.railLines[source] ?? []).contains(where: { $0.code == code }) {
                found[source, default: []].insert(route.id)
            }
        }
        return found.map { Finding(key: $0.key.rawValue, kind: .lines, ids: $0.value.sorted()) }.sorted { $0.key < $1.key }
    }

    /// Subway stations in the list in use that the app's own list doesn't have: no signage direction names for them
    public static func subway(inUse: StationCatalog?, own: StationCatalog?) -> Finding? {
        guard let inUse, let own else { return nil }
        let ids = inUse.entries.map(\.id).filter { own.entry(id: $0) == nil }
        guard !ids.isEmpty else { return nil }
        return Finding(key: DataChangeLog.subwayKey, kind: .directions, ids: Array(Set(ids)).sorted())
    }

    /// One line for a log: the operator, the kind, how many and the first few ids (codes and ids only, no names)
    public static func summary(_ finding: Finding) -> String {
        let first = finding.ids.prefix(3).joined(separator: ",")
        return "\(finding.key) \(finding.kind.rawValue) \(finding.ids.count)" + (first.isEmpty ? "" : " (\(first))")
    }
}
