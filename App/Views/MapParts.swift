import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// A polyline segment of a line on the map.
struct MapLines: Identifiable {
    let id: Int
    let color: Color
    let coordinates: [CLLocationCoordinate2D]

    static func make(_ map: SubwayMap?) -> [MapLines] {
        guard let map else { return [] }
        var result: [MapLines] = []
        for route in map.routes {
            let color = Color(hex: route.color) ?? RouteColor.color(for: route.route)
            for line in route.lines {
                result.append(MapLines(id: result.count, color: color,
                                       coordinates: line.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }))
            }
        }
        return result
    }
}

extension Color {
    /// A six-digit hex color like "0062CF".
    init?(hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: Data source for each mode (one sentence listing every source), shared by the map footer and Settings → Data source
// What each operator provides, live or timetable, and how often it updates is written in How It Works.

enum DataSources {
    /// The short sentence over Settings' data sources: how often the data is checked; the providers are the rows below it
    static func settingsSummary(_ system: TransitSystem, _ l: UIText) -> String {
        switch system.mode {
        case .subway: return l.t("Map and stations are checked for updates on the 1st of each month.")
        case .bus: return l.t("Map and stops are checked for updates on the 1st of each month.")
        default: return l.t("Map and timetables are checked for updates on the 1st of each month.")
        }
    }

    /// Who the map's data is from: the transit operators, named in Settings → Data source (a list here would only grow with the
    /// areas), then how often it's checked
    static func summary(_ system: TransitSystem, _ l: UIText) -> String {
        l.sentences([l.t("Data from the transit operators listed in Settings → Data source."), settingsSummary(system, l)])
    }
}

// MARK: Map parts: service area dashed line, legend, the top-right buttons
// The place picker's map draws the service area line too. The legend, the top-right buttons, the walking-range circles,
// their legend rows and the Hide Range button are only on the transit map.

/// The walking-range circles on the transit map: teal (Color.walkRange), a faint fill, solid for the primary range and dashed for the extended range,
/// like the ◎ and ◌ icons beside the station list. The extended circle's fill lies under the primary one's too, so the primary range looks a little darker.
enum WalkRangeMap {
    static let fill = Color.walkRange.opacity(0.07)
    static let primaryStroke = StrokeStyle(lineWidth: 2)
    static let extendedStroke = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5])
}

/// The walking-range rows of the map legend, already in the app's language: "Primary: 15 min walk", "Extended: 20 min walk",
/// and "+5 min for now" while the range is extended for now
struct WalkRangeLegend {
    var primary: String
    var extended: String
    var extra: String?
}

/// The panel the map's buttons and legend stand on (MapCameraButtons, ServiceAreaLegend): solid, like the walking-time labels
/// (WalkTimeLabel), so the map's place names, lines and station dots don't show through and make the words hard to read (a
/// see-through background let them). The window's background color, so it turns dark in Dark Mode
struct MapPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(6)
            // Fully solid: a little see-through, the large street names still showed faintly
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OutlineColor(), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .padding(10)
    }
}

/// Apple's compass and + − for a map, in its bottom corner, the same in both layout directions. Placed by the app, not by MapKit
/// (`mapControls`): in a right-to-left language MapKit put them over its own Legal link, which it keeps in the bottom left there, so
/// there they stand higher, clear of it. The compass always shows: dragging it turns the map, a click turns it north up again. Tied
/// to the map by its scope: `Map(position:scope:)` and `mapScope(_:)` on a view holding both
struct MapCornerControls: View {
    let scope: Namespace.ID
    @Environment(\.layoutDirection) private var layoutDirection

    /// How far above the map's bottom edge they stand: higher in a right-to-left language, clear of the Legal link under them
    static func bottomSpace(_ direction: LayoutDirection) -> CGFloat { direction == .rightToLeft ? 32 : 10 }
    /// About how much of the corner they take with their space around them, for the map's labels to keep clear of
    static func room(_ direction: LayoutDirection) -> CGSize { CGSize(width: 100, height: 90 + bottomSpace(direction)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            MapCompass(scope: scope)
                .mapControlVisibility(.visible)
            MapZoomStepper(scope: scope)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, Self.bottomSpace(layoutDirection))
    }
}

extension View {
    /// On the map's solid panel (MapPanel)
    func mapPanel() -> some View { modifier(MapPanel()) }
}

/// A station's dot drawn at a fixed size (FixedStationDot), where it is in the map's own points: the map follows the mouse over it
/// (MapHover)
struct MapDotSpot: Equatable {
    let id: String
    let frame: CGRect

    init(id: String, center: CGPoint, diameter: CGFloat) {
        self.id = id
        frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }
}

/// What the mouse is over on a map with walking-time labels, followed by the whole map: MapKit sized a label's view again when it
/// opened, so the label lost the mouse and closed at once, and the system's tooltip on a dot closed again at once too. A label
/// opens (WalkTimeLabel.opens); a dot whose station has a label opens that one; a dot without one shows the station's name under it
struct MapHover: Equatable {
    var label: String?
    var dot: String?
    /// A favorite's star (FavoriteStarSpot.id): its name shows under it
    var star: String?

    @MainActor static func at(_ point: CGPoint, labels: [WalkLabelSpot], dots: [MapDotSpot], stars: [FavoriteStarSpot] = [],
                              open: String?) -> MapHover {
        // The stars are drawn over the labels and dots
        if let star = stars.last(where: { $0.frame.contains(point) }) { return MapHover(star: star.id) }
        if let label = WalkLabelSpot.under(point, in: labels, open: open) { return MapHover(label: label) }
        guard let dot = dots.first(where: { $0.frame.contains(point) })?.id else { return MapHover() }
        if let label = labels.first(where: { $0.dot.id == dot })?.id { return MapHover(label: label) }
        return MapHover(dot: dot)
    }
}

/// Top right of the transit map: Hide Range / Show Range, then back to start / whole map / whole service area.
/// Shows icons only when the map is narrow or text is large (hover for a tooltip). On the map's solid panel with the legend (mapPanel)
struct MapCameraButtons: View {
    let l: UIText
    /// Whether the walking-range circles are shown (nil: no button for them)
    var showsRange: Binding<Bool>? = nil
    let recenter: () -> Void
    let wholeMap: () -> Void
    let serviceArea: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showTitles: true)
            row(showTitles: false)
        }
        .appButtonStyle(.bordered)
        .controlSize(.small)
    }

    /// The buttons the same size (EqualWidthButtons)
    private func row(showTitles: Bool) -> some View {
        EqualWidthButtons(spacing: 6) {
            if let showsRange {
                // Says what a click does, and the icon changes with it (crossed-out eye, then eye), so it isn't told by color alone
                let shown = showsRange.wrappedValue
                button(shown ? l.t("Hide Range") : l.t("Show Range"), symbol: shown ? "eye.slash" : "eye", showTitle: showTitles) {
                    showsRange.wrappedValue = !shown
                }
            }
            button(l.t("Recenter"), symbol: "location", showTitle: showTitles, action: recenter)
            button(l.t("Whole Map"), symbol: "map", showTitle: showTitles, action: wholeMap)
            button(l.t("Service Area"), symbol: "square.dashed", showTitle: showTitles, action: serviceArea)
        }
    }

    private func button(_ title: String, symbol: String, showTitle: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.ease(0.4)) { action() }
        } label: {
            Group {
                if showTitle {
                    Label(title, systemImage: symbol)
                } else {
                    Label(title, systemImage: symbol).labelStyle(.iconOnly)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .help(title)
        .accessibilityLabel(Text(title))
    }
}
