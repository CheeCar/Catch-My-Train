import Foundation
import TransitCore

/// Text for a station whose operator publishes no times the app can use (NoTimesStations): the station page, the map's card and
/// the trip planner say the same, with only the operator's name and its headway changing.
extension AppText {
    /// Why there are no departures, and where to look instead
    public func noTimesReason(_ place: NoTimesStation) -> String {
        f("%@ doesn't publish its times in a form Catch My Train can use, so departures can't be shown here. Check the operator's website or an online map before you go.",
          place.agency.name)
    }

    /// How often it runs ("every 5–15 minutes"), only where the operator's own website says so: "trains" for AirTrain, "boats" for the ferries
    public func noTimesHeadway(_ place: NoTimesStation) -> String? {
        guard let range = place.agency.headwayMinutes else { return nil }
        let minutes = number(Double(range.lowerBound)) + "\u{2013}" + number(Double(range.upperBound))
        return place.agency.mode == .ferry ? f("Its website says boats run every %@ minutes.", minutes)
            : f("Its website says trains run every %@ minutes.", minutes)
    }
}
