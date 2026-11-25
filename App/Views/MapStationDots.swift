import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

// MARK: Station dots and walking-time labels (transit map only)

/// The white dots of the stations on the transit map. A station in walking range is bigger, with a blue ring: solid in the primary range,
/// dashed in the extended range, like the ◎ and ◌ beside the station list, so the range isn't told by color alone
enum StationDot {
    /// Radius in meters, so the dot grows and shrinks with the map (zoomed in close a station in range is drawn at a fixed size instead,
    /// see MapDotSize): a station in range, and any other
    static let nearbyRadius: Double = 45
    static let radius: Double = 30

    static func ring(_ range: SearchRange?) -> StrokeStyle {
        switch range {
        case .primary?: return StrokeStyle(lineWidth: 3)
        case .extended?: return StrokeStyle(lineWidth: 3, dash: [4, 3])
        case nil: return StrokeStyle(lineWidth: 1.5)
        }
    }
}

/// A station in walking range on the transit map zoomed in close (MapDotSize): the same white dot with a blue ring as further out, but
/// a fixed size on screen. Selected, it gets the blue dot in the middle that marks a selected station. Clicking it selects the station
struct FixedStationDot: View {
    let name: String
    let range: SearchRange?
    let selected: Bool
    /// A station without times (NoTimesStations): a gray dot
    var gray = false
    /// Drawn outside the map as it's shown: not given to screen readers (MapAccessibility)
    var offMap = false
    let select: () -> Void

    var body: some View {
        let size = CGFloat(MapDotSize.fixedDiameter(StationDot.nearbyRadius))
        Button(action: select) {
            ZStack {
                Circle().fill(gray ? Color.noTimesDot : Color.white)
                Circle().stroke(Color.accentColor, style: StationDot.ring(range))
                if selected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            .frame(width: size, height: size)
            // Room for the ring, which is drawn half outside the dot (as on the dots in meters)
            .padding(2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // No tooltip: the map shows the name under the dot while the mouse is over it (MapHover), and the system's tooltip closed
        // again at once
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHidden(offMap)
    }
}

/// A favorite place's star on the transit map, where it's drawn now (FavoriteMarks): one favorite's, a small one on its station's
/// dot, or one standing for several close together, with how many
struct FavoriteStarSpot: Identifiable, Equatable {
    /// The favorites it stands for, in the list's order
    let places: [UserPlace]
    let coordinate: Coordinate
    /// Where its point is on the map's view (a small star on a station's dot is up and to the right of it)
    let center: CGPoint
    /// One favorite that is a station of the map: drawn small, on the station's dot, which still shows and can be clicked
    let onStation: Bool
    /// Its size on the view: round for one favorite, longer with the number for several (measured with its font)
    let size: CGSize
    /// How far it's moved sideways (points, more than 0 to the right) to keep clear of the starting point's pin or the current
    /// location's dot (FavoriteMarks.offsets)
    var shift: CGFloat = 0

    /// A star's size across
    static let diameter: CGFloat = 22
    /// A small star's on a station's dot, and how far its middle is from the dot's, right and up
    static let badgeDiameter: CGFloat = 16
    static let badgeOffset: CGFloat = 9
    /// Room each side of the number on a star for several
    static let numberPadding: CGFloat = 7

    @MainActor init(places: [UserPlace], coordinate: Coordinate, center: CGPoint, onStation: Bool, l: UIText) {
        self.places = places
        self.coordinate = coordinate
        self.center = center
        self.onStation = onStation
        if places.count > 1 {
            size = CGSize(width: Self.width(number: l.number(Double(places.count))), height: Self.diameter)
        } else {
            let d = onStation ? Self.badgeDiameter : Self.diameter
            size = CGSize(width: d, height: d)
        }
    }

    var id: String { places.map { "\($0.name) \($0.latitude) \($0.longitude)" }.joined(separator: "|") }
    var count: Int { places.count }

    /// Where it is on the map's view (for clicks, the mouse, and what keeps clear of it)
    var frame: CGRect { Self.frame(center: center, size: size, onStation: onStation, shift: shift) }

    /// The point of the star pinned to its place (where it's drawn: the same as `frame`)
    var anchor: UnitPoint { Self.anchor(size: size, onStation: onStation, shift: shift) }

    /// A star's frame on the map's view from its place's point there: around the point, or up and to the right of a station's
    /// dot (a small star), and `shift` to the side when it's moved aside
    static func frame(center: CGPoint, size: CGSize, onStation: Bool, shift: CGFloat) -> CGRect {
        let corner = onStation ? badgeOffset : 0
        return CGRect(x: center.x + corner + shift - size.width / 2, y: center.y - corner - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The point of a star pinned to its place, so the star is drawn where `frame` says: its middle, or a small star's corner
    /// beside the station's dot, `shift` farther to the side when it's moved aside
    static func anchor(size: CGSize, onStation: Bool, shift: CGFloat) -> UnitPoint {
        let corner = onStation ? badgeOffset : 0
        return UnitPoint(x: 0.5 - (corner + shift) / size.width, y: 0.5 + corner / size.height)
    }

    /// What shows under it while the mouse is over it: the favorite's name, or "Favorite places: 5"
    func title(_ l: UIText) -> String {
        count == 1 ? places.first?.name ?? "" : l.f("Favorite places: %@", l.number(Double(count)))
    }

    /// The width of a star for several: the star and the number, measured with their fonts (FavoriteStarView)
    @MainActor static func width(number: String, scale: CGFloat = TextScale.factor) -> CGFloat {
        let pointSize = scale == 1 ? NSFont.preferredFont(forTextStyle: .caption2).pointSize : 10 * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .bold)
        let text = ceil((number as NSString).size(withAttributes: [.font: font]).width)
        return max(diameter, ceil(11 + 2 + text + 2 * numberPadding))
    }
}

/// A favorite place's star on the transit map (FavoriteStarSpot): a gold star on a small round patch of the window's color, with a
/// thin edge and a little shadow, as the walking-time labels; with the number of favorites beside it when it stands for several.
/// A blue edge while its card is open. Clicking it opens the favorite's card, or zooms in to the favorites it stands for
struct FavoriteStarView: View {
    let l: UIText
    let spot: FavoriteStarSpot
    /// Its card is open
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: spot.onStation ? 9 : 11, weight: .semibold))
                    .foregroundStyle(Color.favoriteStar)
                if spot.count > 1 {
                    Text(l.number(Double(spot.count)))
                        .font(.scaled(.caption2).weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: spot.size.width, height: spot.size.height)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule()
                .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(OutlineColor()), lineWidth: selected ? 2 : 0.5))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // No tooltip: the map shows the name under the star while the mouse is over it (MapHover), as under a station's dot
        .accessibilityLabel(Text(spot.count == 1 ? [spot.title(l), l.t("Favorite places")].joined(separator: ". ") : spot.title(l)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A card at the bottom of the transit map other than a station's (SubwayMapView.placeCard)
enum MapPlaceCard: Equatable {
    /// A favorite's: its star clicked
    case favorite(UserPlace)
    /// The starting point's: its pin, or the current location's dot, clicked
    case origin
    /// A spot clicked on the empty map: its address once it's found (nil while it's looked up)
    case pin(Coordinate, String?)
    /// The favorites at one spot, too close together to come apart
    case list([UserPlace])
    /// Demo mode, a click outside Manhattan: the demo has times only there
    case demoOutside
}


/// A walking-time label placed on the transit map (MapLabelLayout): what it says and where it goes
struct WalkLabelSpot: Identifiable, Equatable {
    let placement: MapLabelLayout.Placement
    let name: String
    /// Walking minutes as in the station list ("9 min")
    let minutes: String
    let extended: Bool
    /// The station the label sits beside: the complex's nearest one
    let coordinate: Coordinate
    /// That station's dot on the map: clicking the label selects it
    let dot: SubwayMap.Station

    var id: String { placement.id }
    /// The point of the label pinned to the station
    var anchor: UnitPoint { UnitPoint(x: placement.anchorX, y: placement.anchorY) }
    var size: CGSize { CGSize(width: placement.box.width, height: placement.box.height) }
    /// Where the label is, in the map's own points (for clicks)
    var frame: CGRect { CGRect(x: placement.box.x, y: placement.box.y, width: placement.box.width, height: placement.box.height) }

    /// Where the label is while it's open (WalkTimeLabel.opens), in the map's own points: the bigger box with the name, grown away from
    /// the station (to the left when the station is right of the label's middle, upward when it's below), so it still covers the box
    /// of the minutes only and stays clear of the station's dot. Pinned at the station by `anchor(open: true)`
    @MainActor func openedFrame(scale: CGFloat = TextScale.factor) -> CGRect {
        guard placement.compact else { return frame }
        let full = WalkTimeLabel.size(minutes: minutes, name: name, scale: scale)
        let width = max(frame.width, CGFloat(full.width)), height = max(frame.height, CGFloat(full.height))
        return CGRect(x: CGFloat(placement.anchorX) > 0.5 ? frame.maxX - width : frame.minX,
                      y: CGFloat(placement.anchorY) > 0.5 ? frame.maxY - height : frame.minY,
                      width: width, height: height)
    }

    /// The point of the label pinned to the station, open or not. Pinned with the same point, the open label grew by a share of
    /// its new size on each side: with the station beside the label (a point outside 0...1) it moved away from where it was
    @MainActor func anchor(open: Bool) -> UnitPoint {
        guard open else { return anchor }
        let box = openedFrame()
        let station = CGPoint(x: frame.minX + CGFloat(placement.anchorX) * frame.width, y: frame.minY + CGFloat(placement.anchorY) * frame.height)
        return UnitPoint(x: (station.x - box.minX) / box.width, y: (station.y - box.minY) / box.height)
    }

    /// The label the mouse is over, the point in the map's own points: the open one with the whole of its open box (so moving onto
    /// the name keeps it open), the others with their own
    @MainActor static func under(_ point: CGPoint, in labels: [WalkLabelSpot], open: String?) -> String? {
        if let open, let spot = labels.first(where: { $0.id == open }), spot.openedFrame().contains(point) { return open }
        return labels.first { $0.frame.contains(point) }?.id
    }
}

/// The label beside a station in walking range: the walking minutes (after the ◎ or ◌ of the station list) over the station's name,
/// or the minutes only when the name has no room. Clicking it selects the station, like clicking its dot.
/// It's drawn at the size the layout measured (WalkTimeLabel.size), so the layout knows where it ends. A label with the minutes only
/// opens to show the name too while the mouse is over it or its station is selected, at once rather than after the tooltip's wait:
/// drawn bigger from the same point, over what is next to it, and the layout doesn't change, so nothing else moves
struct WalkTimeLabel: View {
    let l: UIText
    let spot: WalkLabelSpot
    let selected: Bool
    /// The mouse is over it: followed by the map (WalkLabelSpot.under), which also pins it open (WalkLabelSpot.anchor(open:))
    var hovered = false
    let select: () -> Void

    /// Shows the name it has no room for (see above)
    static func opens(_ spot: WalkLabelSpot, hovered: Bool, selected: Bool) -> Bool {
        spot.placement.compact && (hovered || selected)
    }

    private var opened: Bool { Self.opens(spot, hovered: hovered, selected: selected) }

    static let paddingH: CGFloat = 6
    static let paddingV: CGFloat = 3
    static let iconSpacing: CGFloat = 3
    /// Names longer than this end in "…" (the station card shows them whole)
    static let maxNameWidth: CGFloat = 150

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Self.iconSpacing) {
                    Image(systemName: spot.extended ? "circle.dashed" : "circle.circle")
                        .font(.scaled(.caption2))
                        .foregroundStyle(.secondary)
                    Text(spot.minutes)
                        .font(.scaled(.caption).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if !spot.placement.compact || opened {
                    Text(spot.name)
                        .font(.scaled(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Self.paddingH)
            .padding(.vertical, Self.paddingV)
            .frame(width: shownSize.width, height: shownSize.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(OutlineColor()), lineWidth: selected ? 2 : 0.5))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(spot.name)
        .accessibilityLabel(Text([spot.name, l.f("%@ walk", spot.minutes), spot.extended ? l.t("Extended range") : ""]
            .filter { !$0.isEmpty }.joined(separator: ". ")))
    }

    /// The size it's drawn at: the layout's, or opened, the size with the name
    private var shownSize: CGSize {
        opened ? spot.openedFrame().size : spot.size
    }

    /// The label's size, measured with the fonts it's drawn with (Font.scaled: the system caption sizes at the normal text size,
    /// 10 points times the text size otherwise) and a little room to spare. `name` nil: the minutes only
    static func size(minutes: String, name: String?, scale: CGFloat) -> MapLabelLayout.Size {
        let minutesSize = scale == 1 ? NSFont.preferredFont(forTextStyle: .caption1).pointSize : 10 * scale
        let minutesFont = NSFont.monospacedDigitSystemFont(ofSize: minutesSize, weight: .semibold)
        let nameFont = scale == 1 ? NSFont.preferredFont(forTextStyle: .caption2) : NSFont.systemFont(ofSize: 10 * scale)
        // The ring symbol is about as wide as the text is high
        var width = ceil(lineHeight(nameFont)) + iconSpacing + textWidth(minutes, minutesFont)
        var height = lineHeight(minutesFont)
        if let name {
            width = max(width, min(maxNameWidth * scale, textWidth(name, nameFont)))
            height += lineHeight(nameFont)
        }
        return MapLabelLayout.Size(width: Double(ceil(width + 2 * paddingH + 4)), height: Double(ceil(height + 2 * paddingV + 1)))
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
