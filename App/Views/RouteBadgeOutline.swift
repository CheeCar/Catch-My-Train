import SwiftUI
import TransitCore

extension RouteBadge {
    /// The outline of a route's badge, `margin` points outside it: a ring drawn around the badge follows the badge's own shape
    /// (a circle for the subway's round badges, a pill for ferries and the tram, a rounded rectangle for the wide ones) instead
    /// of a circle that only shows above and below a wide badge. `size` is the badge's, before the text size setting
    static func outline(of route: String, size: CGFloat, margin: CGFloat) -> AnyShape {
        if isSubway(route) { return AnyShape(Circle()) }
        if RooseveltIslandTram.isTram(route: route) || FerryFeed.isFerryRoute(route) { return AnyShape(Capsule()) }
        // The badges' own corners (see RailRouteBadge, PathRouteBadge and BusRouteBadge)
        let wide = FerryFeed.isPathRoute(route) || FerryFeed.isRailRoute(route) || FerryFeed.isNJBusRoute(route)
        let corner = size * TextScale.factor * (wide ? 0.12 : 0.18)
        return AnyShape(RoundedRectangle(cornerRadius: corner + margin))
    }
}
