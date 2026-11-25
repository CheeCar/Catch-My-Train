import Foundation
import TransitCore

/// The words of "Directions" (WalkingDirections): the map app it opens, by name.
extension AppText {
    /// The map "Directions" opens, by the name its maker gives it in this language (Tests/names.json)
    public func mapName(_ map: DirectionsMap) -> String {
        switch map {
        case .appleMaps: return t("Apple Maps")
        case .googleMaps: return t("Google Maps")
        }
    }
}
