import Foundation

/// Data for telling express from local trains (generated from MTA static GTFS by `tools/generate_express.py`).
///
/// The table maps "station ID + direction → next stop that indicates a skip": going from this station to that next stop,
/// other trains in the timetable make extra stops in between, so a train going straight there is express.
/// Realtime data lists each train's upcoming stops, which we look up in the table:
/// if any segment between this station and the next few stops is a skip, the train is express; if it stops everywhere, it is local.
/// This way trains that run local at night or on weekends also show correctly as local.
public struct ExpressStops: Sendable {
    /// "712N" → ["707"]
    private let skips: [String: Set<String>]

    /// How many stops ahead to look (express trains often start skipping one or two stops after this one, e.g. the 2/3 southbound at Times Sq).
    public static let lookAhead = 3

    public init(skips: [String: [String]]) {
        self.skips = skips.mapValues(Set.init)
    }

    public static func decode(_ data: Data) throws -> ExpressStops {
        ExpressStops(skips: try JSONDecoder().decode([String: [String]].self, from: data))
    }

    public static func loadBundled() throws -> ExpressStops {
        guard let url = Bundle.module.url(forResource: "express_stops", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    /// Whether going from `from` to next stop `to` (direction N or S) is a skip.
    public func skips(from: String, direction code: String, to: String) -> Bool {
        skips[from + code]?.contains(to) ?? false
    }

    /// Decides whether a train is express or local at this station.
    /// - Parameters:
    ///   - rawRoute: route ID in the realtime data. 6X, 7X and FX are the official diamond expresses.
    ///   - stationID: this station
    ///   - code: direction N / S
    ///   - nextStations: this train's upcoming stops (in order, excluding this station)
    /// - Returns: true for express, false for local; nil when there is no info on later stops (e.g. this is the last stop before the terminal).
    public func isExpress(rawRoute: String, stationID: String, code: String, nextStations: [String]) -> Bool? {
        if MTARoute.isDiamondExpress(rawRoute) { return true }
        guard !nextStations.isEmpty else { return nil }
        let path = [stationID] + nextStations.prefix(Self.lookAhead)
        for (a, b) in zip(path, path.dropFirst()) where skips(from: a, direction: code, to: b) {
            return true
        }
        return false
    }
}

extension MTARoute {
    /// Official diamond express (e.g. <7>).
    public static func isDiamondExpress(_ route: String) -> Bool {
        route == "6X" || route == "7X" || route == "FX"
    }
}
