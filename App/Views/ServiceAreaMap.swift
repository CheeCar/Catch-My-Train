import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// A short horizontal line in the legend.
private struct DashSample: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

enum ServiceAreaMap {
    /// Only if the service area's outline were missing (it comes with the app)
    private static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -73.95),
        span: MKCoordinateSpan(latitudeDelta: 0.42, longitudeDelta: 0.42))

    /// The service area's edge and the lines between its metro areas: purple dashed lines, all the same
    static let color = Color.serviceAreaLine
    static let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [8, 6])

    /// The lines of the metro areas' rings: the service area's edge, and once each line where two areas meet (see MetroOutline)
    static let lines: [[CLLocationCoordinate2D]] = {
        let outline = MetroOutline.current
        return (outline.outer + outline.shared).map { $0.map(\.clCoordinate) }
    }()

    /// The rings, and the names of the metro areas in `names` (see names(_:width:l:)), each in the middle of its ring, on as many
    /// lines as `names` says, or moved up or down by `shifts` to keep clear of the favorites' stars (keepNamesClear). The
    /// names are map labels, so they keep their size on screen. On the main actor: MapKit's ForEach for map content is (macOS 27 SDK)
    @MainActor @MapContentBuilder
    static func content(_ l: UIText, names: [MetroArea: Int], shifts: [MetroArea: CGFloat] = [:]) -> some MapContent {
        ForEach(lines.indices, id: \.self) { i in
            MapPolyline(coordinates: lines[i])
                .stroke(color, style: stroke)
        }
        ForEach(MetroArea.allCases.filter { names[$0] != nil }, id: \.self) { area in
            Annotation("", coordinate: MetroOutline.labelPoint(area).clCoordinate,
                       anchor: nameAnchor(area, l: l, lines: names[area] ?? 1, shift: shifts[area] ?? 0)) {
                // A label of its own: bold purple on a light, see-through box with a thin purple edge, so it reads over
                // bus lines and map labels alike (the material turns dark in Dark Mode). Round ends on one line, a rounded box
                // on two. Its size is worked out in labelSize
                Text(nameLines(l.t(area.nameKey), count: names[area] ?? 1).joined(separator: "\n"))
                    .font(.scaled(.subheadline).weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.metroName)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: nameCorner))
                    .overlay(RoundedRectangle(cornerRadius: nameCorner).strokeBorder(color, lineWidth: 1))
                    .fixedSize()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The corners of a name's box: half the height of one line, so a name on one line has round ends
    static var nameCorner: CGFloat { 10 * TextScale.factor }

    /// A metro area's name as the lines it is written on: one, or two when `count` is 2 and the name can be broken
    static func nameLines(_ name: String, count: Int) -> [String] {
        count == 2 ? MetroOutline.twoLines(name) ?? [name] : [name]
    }

    /// Room kept between a metro area's name and its ring, on each side, in points
    static let nameRoom: CGFloat = 8

    /// The metro areas whose names a map writes, and on how many lines, for the area the map last reported (`rect`) on a view
    /// `width` points wide: on one line while the name, with some room around it, fits inside its own ring at this zoom
    /// (MetroOutline.nameFits); on two when only that fits; not at all when neither does. Like the map's own place
    /// names: zoomed out, a small area's name goes before a big one's, and far out (the whole country) there are none, only the
    /// rings, so names never pile up, however many areas there are
    static func names(_ rect: MKMapRect, width: CGFloat, l: UIText) -> [MetroArea: Int] {
        guard width > 0, rect.size.width > 0 else { return [:] }
        // Map points per point of the view
        let scale = rect.size.width / Double(width)
        var result: [MetroArea: Int] = [:]
        for area in MetroArea.allCases {
            // Meters per point at the name (a map point is fewer meters the farther it is from the equator)
            let metersPerPoint = MKMetersPerMapPointAtLatitude(MetroOutline.labelPoint(area).latitude) * scale
            let name = l.t(area.nameKey)
            if nameFits(area, lines: [name], metersPerPoint: metersPerPoint) {
                result[area] = 1
            } else if let two = MetroOutline.twoLines(name), nameFits(area, lines: two, metersPerPoint: metersPerPoint) {
                result[area] = 2
            }
        }
        return result
    }

    /// Whether a metro area's name on these lines, with the room around it, fits inside the area's ring at this zoom (moved
    /// `northPoints` up the view, down when less than 0). Zooms less than 2 percent apart get the same answer (NameFitCache)
    static func nameFits(_ area: MetroArea, lines: [String], metersPerPoint: Double, northPoints: Double = 0) -> Bool {
        let size = labelSize(lines)
        return fitCache.fits(area, widthPoints: Double(size.width + 2 * nameRoom), heightPoints: Double(size.height + 2 * nameRoom),
                             metersPerPoint: metersPerPoint, northPoints: northPoints)
    }

    /// The answers by zoom step (NameFitCache): a map being zoomed asks for every area at each of its stops
    private static let fitCache = NameFitCache()

    /// The names in `names` (that fit at the zoom of the area the map shows, `rect`, on a view `width` points wide), each kept clear
    /// of the favorites' stars (`stars`, on the view): moved up or down a little where one covers it, as long as it still fits
    /// inside its ring (MetroOutline.nameShift), else left out, as when it doesn't fit. `point`: where a place is on the view (nil:
    /// not known, the name stays where it is). With no stars, the names as they are
    @MainActor
    static func keepNamesClear(_ names: [MetroArea: Int], rect: MKMapRect?, width: CGFloat, l: UIText, stars: [CGRect],
                               point: (Coordinate) -> CGPoint?) -> (names: [MetroArea: Int], shifts: [MetroArea: CGFloat]) {
        guard !stars.isEmpty, let rect, width > 0, rect.size.width > 0 else { return (names, [:]) }
        // Map points per point of the view
        let scale = rect.size.width / Double(width)
        let boxes = stars.map { MapLabelLayout.Box(x: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height)) }
        var kept: [MetroArea: Int] = [:]
        var shifts: [MetroArea: CGFloat] = [:]
        for (area, count) in names {
            let lines = nameLines(l.t(area.nameKey), count: count)
            guard let p = point(MetroOutline.labelPoint(area)) else {
                kept[area] = count
                continue
            }
            let size = labelSize(lines)
            let box = MapLabelLayout.Box(x: Double(p.x - size.width / 2), y: Double(p.y - size.height / 2),
                                         width: Double(size.width), height: Double(size.height))
            let metersPerPoint = MKMetersPerMapPointAtLatitude(MetroOutline.labelPoint(area).latitude) * scale
            // Down the view is south
            guard let shift = MetroOutline.nameShift(name: box, stars: boxes, fits: {
                nameFits(area, lines: lines, metersPerPoint: metersPerPoint, northPoints: -$0)
            }) else { continue }
            kept[area] = count
            if shift != 0 { shifts[area] = CGFloat(shift) }
        }
        return (kept, shifts)
    }

    /// Where a name is pinned to its area's label point: its middle, or, moved by `shift` points (up when less than 0), as far
    /// below or above it
    @MainActor
    static func nameAnchor(_ area: MetroArea, l: UIText, lines: Int, shift: CGFloat) -> UnitPoint {
        guard shift != 0 else { return .center }
        let height = labelSize(nameLines(l.t(area.nameKey), count: lines)).height
        guard height > 0 else { return .center }
        return UnitPoint(x: 0.5, y: 0.5 - shift / height)
    }

    /// The size of a metro area's name on the map (content), on one line or more: the text in bold at the app's text size (as wide
    /// as its widest line, as high as its lines together), with the padding around it
    static func labelSize(_ lines: [String]) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11 * TextScale.factor, weight: .bold)
        let sizes = lines.map { ($0 as NSString).size(withAttributes: [.font: font]) }
        return CGSize(width: ceil(sizes.map(\.width).max() ?? 0) + 16, height: ceil(sizes.map(\.height).reduce(0, +)) + 6)
    }

    /// The points of the metro areas' rings, which Service Area fits on the map
    static let ringPoints: [Coordinate] = (MetroOutline.current.outer + MetroOutline.current.shared).flatMap { $0 }

    /// Where Service Area puts the map: the area to ask MapKit for (`rect`), on a MapKit view of `size` whose top `hiddenTop`
    /// points are under the toolbar, so that the rings fill `place` (in the points of MapKit's view, from its top left)
    struct Fit {
        let rect: MKMapRect
        let place: CGRect
        let size: CGSize
        let hiddenTop: CGFloat

        /// The same place on a view of the same size: the window and the panel didn't change
        func samePlace(as other: Fit) -> Bool { size == other.size && hiddenTop == other.hiddenTop && place == other.place }
    }

    /// The whole service area on a map whose MapKit view is `size`, the top `hiddenTop` points of it under the toolbar, clear of the
    /// buttons' panel (`panel`, in the coordinates of the map below the toolbar) and of a margin all round: below the panel, or
    /// beside it when that shows the map at least 15% larger. Below, the rings are as wide as they are high in a place much wider,
    /// so there's room on both sides if MapKit draws them a little larger than asked; beside, the place is just as wide as they
    /// are, and they were cut at the far side (see SubwayMapView.measureServiceArea). Nil before the map has a size
    static func fit(size: CGSize, hiddenTop: CGFloat, panel: CGRect?) -> Fit? {
        let margin: CGFloat = 16, gap: CGFloat = 8
        let open = CGRect(x: margin, y: hiddenTop + margin, width: size.width - 2 * margin, height: size.height - hiddenTop - 2 * margin)
        var places = [open]
        if let panel = panel?.offsetBy(dx: 0, dy: hiddenTop), panel.intersects(open) {
            let below = CGRect(x: open.minX, y: panel.maxY + gap, width: open.width, height: open.maxY - panel.maxY - gap)
            // The panel is on the trailing side: on the right, or on the left right to left
            let beside = panel.midX > size.width / 2
                ? CGRect(x: open.minX, y: open.minY, width: panel.minX - gap - open.minX, height: open.height)
                : CGRect(x: panel.maxX + gap, y: open.minY, width: open.maxX - panel.maxX - gap, height: open.height)
            places = [below, beside].filter { $0.width > 0 && $0.height > 0 }
        }
        let fits: [(place: CGRect, area: (x: Double, y: Double, width: Double, height: Double))] = places.compactMap { place in
            ServiceArea.frame(ringPoints, view: (Double(size.width), Double(size.height)),
                              visible: (Double(place.minX), Double(place.minY), Double(place.width), Double(place.height)))
                .map { (place: place, area: $0) }
        }
        // The first place (below the panel, or the open map when there's no panel), unless another shows the map at least 15%
        // larger: one that takes in less than 1 / 1.15 as much of the world
        guard var best = fits.first else { return nil }
        for other in fits.dropFirst() where other.area.width * 1.15 <= best.area.width { best = other }
        let world = MKMapRect.world
        return Fit(rect: MKMapRect(x: best.area.x * world.width, y: best.area.y * world.height,
                                   width: best.area.width * world.width, height: best.area.height * world.height),
                   place: best.place, size: size, hiddenTop: hiddenTop)
    }

    /// Map region showing the whole service area: where there's no map size to fit it to (the place picker's map)
    static let region: MKCoordinateRegion = {
        let all = ServiceArea.outline.flatMap { $0 }
        guard let minLat = all.map(\.latitude).min(), let maxLat = all.map(\.latitude).max(),
              let minLon = all.map(\.longitude).min(), let maxLon = all.map(\.longitude).max() else { return fallback }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.1, longitudeDelta: (maxLon - minLon) * 1.1))
    }()

    /// Whole Map: this mode's stations in the starting point's metro area (`area`; outside them all the nearest one):
    /// Subway and Bus by whole lines, Train and Ferry by stations (see SubwayMap.wholeMapPoints). When that area has none of them, or
    /// there's no area yet, every station. Shows the whole service area when there's no map data.
    static func wholeRegion(_ map: SubwayMap?, system: TransitSystem, area: MetroArea?) -> MKCoordinateRegion {
        let byLine = system.mode == .subway || system.mode == .bus
        var points = area.flatMap { map?.wholeMapPoints(in: $0, byLine: byLine) } ?? []
        if points.isEmpty { points = (map?.stations ?? []).map { [$0.lat, $0.lon] } }
        // The bus map has no stop dots: use points on the routes
        if points.isEmpty, system.mode == .bus { points = (map?.routes ?? []).flatMap { $0.lines.flatMap { $0 } } }
        let lats = points.compactMap(\.first), lons = points.compactMap { $0.count > 1 ? $0[1] : nil }
        guard lats.count > 1, let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return region }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.15), longitudeDelta: max(0.02, (maxLon - minLon) * 1.15)))
    }
}

/// Legend under the top-right buttons, on the same panel (mapPanel): the purple dashed line is the service area. The walking-range
/// circles come first (solid teal = primary, dashed teal = extended), unless they're hidden.
struct ServiceAreaLegend: View {
    let l: UIText
    /// The walking-range rows (nil: none)
    var range: WalkRangeLegend? = nil
    /// The favorites' row: while the map has favorites' stars
    var favorites = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let range {
                row(Color.walkRange, StrokeStyle(lineWidth: 2, lineCap: .round), range.primary)
                HStack(spacing: 5) {
                    row(Color.walkRange, StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]), range.extended)
                    if let extra = range.extra {
                        // Same tag as in the legend above the station list (RangeLegend)
                        Text(extra)
                            .font(.scaled(.caption2).weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(OutlineColor(), lineWidth: 1))
                            .fixedSize()
                    }
                }
            }
            row(ServiceAreaMap.color, StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]), l.t("Service area"))
            if favorites {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.favoriteStar)
                        .frame(width: 22)
                    Text(l.t("Favorite places"))
                        .lineLimit(2)
                }
            }
        }
        .font(.scaled(.caption))
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    /// A short line drawn like the one on the map, then what it means
    private func row(_ color: Color, _ style: StrokeStyle, _ text: String) -> some View {
        HStack(spacing: 6) {
            DashSample().stroke(color, style: style)
                .frame(width: 22, height: 2)
            Text(text)
                .lineLimit(2)
        }
    }
}
