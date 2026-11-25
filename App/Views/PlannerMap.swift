import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// Plan a Trip's map: the chosen place, its two walking circles, the stations of the list as dots with their walking minutes
/// beside them (as on the transit map: WalkTimeLabel, MapLabelLayout) and the service area's rings. No lines: it's there to show where
/// things are.
///
/// Small (the column beside the list): clicking a station's dot or label selects it, as clicking its card in the list does, and a
/// dotted line runs from the place to it. A click anywhere else does nothing, so dragging the map never changes the place.
/// Large (Open Larger Map, filling the window under the controls): a click drops a pending pin with the walking circles around it; the
/// place changes only with Use This Place (PlannerView), so nothing is computed again for a pin that is only being tried.
struct PlannerMapView: View {
    let l: UIText
    let large: Bool
    /// The place in use: nil on the large map opened before a place was chosen (no pin, no circles until a click drops one)
    let place: PlannerModel.Place?
    /// Where the map opens without a place: where the main window walks from
    /// nil: no place and no location yet, the map shows the whole service area
    let start: Coordinate?
    /// The stations of the list, nearest first (none while computing)
    let stations: [BoardStation]
    /// The walk chosen in Plan a Trip: the circles' sizes
    let settings: CatchSettings
    @Binding var selected: String?
    /// Shown, not kept hidden (Plan a Trip keeps its two maps, hiding the one not in use): a hidden map lays no labels out, so it
    /// never asks MapKit; they're laid out when it's shown again
    let shown: Bool
    /// Large map only: the pin clicked but not used yet. The circles stand around it, and the minutes (which belong to the place in use) aren't shown
    let pending: Coordinate?
    let onPick: ((Coordinate) -> Void)?

    @State private var position: MapCameraPosition = .automatic
    @State private var labels: [WalkLabelSpot] = []
    /// What the mouse is over (MapHover): a label opens to show the name, a dot without a label shows it under the dot
    @State private var hover = MapHover()
    /// Where the stations' dots are (laid out with the labels): followed by the mouse
    @State private var dotSpots: [MapDotSpot] = []
    /// Ties Apple's compass and + − in the map's bottom corner to the map (MapCornerControls)
    @Namespace private var mapScope
    /// What the map keeps that isn't drawn: the area it showed after its last move, and whether the labels wait for it to be seen
    @State private var sight = PlannerMapSight()
    /// The metro areas whose names fit on the map at its zoom now, and on how many lines (ServiceAreaMap.names): set when the map
    /// stops moving
    @State private var metroNames: [MetroArea: Int] = [:]
    /// Counts up to lay the labels out once the window is back in sight, when they had to wait (see layoutLabels)
    @State private var relayout = 0
    @Environment(\.layoutDirection) private var layoutDirection

    init(l: UIText, large: Bool, place: PlannerModel.Place?, start: Coordinate? = nil, stations: [BoardStation], settings: CatchSettings,
         selected: Binding<String?>, shown: Bool = true, pending: Coordinate? = nil, onPick: ((Coordinate) -> Void)? = nil) {
        // Kept hidden: given nothing to draw (HiddenMapStyle.empty). A hidden map with a place and stations on it was measured
        // drawing all the time, unseen; with none on it, it wasn't. Shown again, it's framed and labeled as a new map would be, so
        // where it opens still follows the place
        let emptied = !shown && HiddenMapStyle.current == .empty
        self.l = l
        self.large = large
        self.place = emptied ? nil : place
        self.start = place?.coordinate ?? start
        self.stations = emptied ? [] : stations
        self.settings = settings
        _selected = selected
        self.shown = shown
        self.pending = emptied ? nil : pending
        self.onPick = onPick
    }

    /// Where each station's dot is: the complex's nearest station
    private func coordinate(_ b: BoardStation) -> Coordinate? { b.stations.first?.coordinate }

    var body: some View {
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $position, scope: mapScope) {
                    if let center = pending ?? place?.coordinate {
                        PlannerMapView.circles(around: center, settings: settings)
                    }
                    ServiceAreaMap.content(l, names: metroNames)
                    // From the place to the selected station, dotted: which way it is, not the walking route
                    if !large, let place, let s = selectedStation, let c = coordinate(s) {
                        MapPolyline(coordinates: [place.coordinate.clCoordinate, c.clCoordinate])
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 6]))
                    }
                    ForEach(stations) { s in
                        if let c = coordinate(s) {
                            Annotation(s.name, coordinate: c.clCoordinate, anchor: .center) {
                                FixedStationDot(name: s.name, range: s.range, selected: !large && selected == s.id, gray: s.noTimes != nil) {
                                    withAnimation(Motion.ease(0.2)) { selected = s.id }
                                }
                                // On the large map a click anywhere drops the pin, on a dot too
                                .allowsHitTesting(!large)
                            }
                            // Under the mouse, a station without a label shows its name under the dot (MapHover)
                            .annotationTitles(hover.dot == s.id ? .automatic : .hidden)
                        }
                    }
                    if pending == nil {
                        ForEach(labels) { spot in
                            let isSelected = !large && selected == spot.id
                            let hovered = hover.label == spot.id
                            Annotation(spot.name, coordinate: spot.coordinate.clCoordinate,
                                       anchor: spot.anchor(open: WalkTimeLabel.opens(spot, hovered: hovered, selected: isSelected))) {
                                WalkTimeLabel(l: l, spot: spot, selected: isSelected, hovered: hovered) {
                                    withAnimation(Motion.ease(0.2)) { selected = spot.id }
                                }
                                .allowsHitTesting(!large)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    // The place in use; paler while a pending pin stands elsewhere
                    if let place {
                        Marker(place.name, systemImage: "mappin", coordinate: place.coordinate.clCoordinate)
                            .tint(pending == nil ? Color.placePin : Color.placePin.opacity(0.4))
                    }
                    if let pending {
                        Marker(l.t("Place on the map"), systemImage: "mappin", coordinate: pending.clCoordinate)
                            .tint(Color.accentColor)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                // Only the scale is placed by MapKit: the compass and + − are placed by the app (MapCornerControls)
                .mapControls {
                    MapScaleView()
                        .mapControlVisibility(large ? .automatic : .hidden)
                }
                // Kept hidden: its AppKit view hidden too (HiddenMapStyle.appkit), and shown again when it's in use
                .background {
                    if HiddenMapStyle.current == .appkit { MapViewHider(hidden: !shown) }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    guard large, let onPick, let c = proxy.convert(point, from: .local) else { return }
                    onPick(Coordinate(latitude: c.latitude, longitude: c.longitude))
                }
                // The mouse wheel zooms gently. It also says when the map moves, so a label or name open under the mouse closes: with a
                // second onMapCameraChange(frequency: .continuous) on this map, only one of the two was called
                .gentleWheelZoom($position) {
                    if hover != MapHover() { hover = MapHover() }
                }
                // Apple's compass and + − in the bottom corner (MapCornerControls); the labels keep clear of them (labelSpots)
                .overlay(alignment: .bottomTrailing) {
                    MapCornerControls(scope: mapScope)
                }
                .mapScope(mapScope)
                // The label or dot under the mouse, followed over the whole map (MapHover, as on the transit map); none while a
                // pending pin hides the labels
                .onContinuousHover(coordinateSpace: .local) { phase in
                    let over: MapHover
                    switch phase {
                    case .active(let point):
                        over = pending == nil ? MapHover.at(point, labels: labels, dots: dotSpots, open: hover.label) : MapHover()
                    case .ended: over = MapHover()
                    }
                    if over != hover { hover = over }
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    sight.visible = MapVisibleRect(rect: context.rect, heading: context.camera.heading,
                                                   pitch: context.camera.pitch, size: geo.size)
                    layoutLabels(proxy, size: geo.size)
                    let names = ServiceAreaMap.names(context.rect, width: geo.size.width, l: l)
                    if names != metroNames { metroNames = names }
                }
                .onChange(of: frameKey, initial: true) { _, _ in
                    // Hidden: not moved (a hidden map would still load what it moves to); framed when shown again (onChange of shown)
                    guard shown else { return }
                    withAnimation(Motion.ease(0.3)) { position = .region(startRegion) }
                }
                .onChange(of: labelKeys) { _, _ in layoutLabels(proxy, size: geo.size) }
                .onChange(of: selected) { _, _ in layoutLabels(proxy, size: geo.size) }
                .onChange(of: layoutDirection) { _, _ in layoutLabels(proxy, size: geo.size) }
                .onChange(of: relayout) { _, _ in layoutLabels(proxy, size: geo.size) }
                // Shown again: framed as a new map would be (the place, or where the main window walks from), then labeled.
                // Hidden: a layout waiting to run is dropped (it was asked for while the map could be seen, and would ask MapKit
                // about a hidden map), and so are the labels, so it shows none of the place before when it's shown again
                .onChange(of: shown) { _, now in
                    guard now else {
                        sight.layoutSoon?.cancel()
                        sight.layoutSoon = nil
                        labels = []
                        dotSpots = []
                        hover = MapHover()
                        return
                    }
                    position = .region(startRegion)
                    layoutLabels(proxy, size: geo.size)
                }
            }
        }
        // Out of sight and back: the window covered or not, the app in the background or not
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window = note.object as? NSWindow, Self.isPlannerWindow(window) { sightChanged() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sightChanged() }
        .onDisappear { sight.layoutSoon?.cancel() }
    }

    /// Plan a Trip's window (there's only one)
    private static func isPlannerWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(PlannerWindow.id) == true
    }

    /// The map can be seen: Plan a Trip's window open and not covered, and the app active
    private static var inSight: Bool {
        NSApp.isActive && NSApp.windows.contains { isPlannerWindow($0) && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Back in sight: labels that couldn't be laid out while the window was out of sight are laid out now
    private func sightChanged() {
        guard Self.inSight else { return }
        if sight.layoutWaiting { relayout &+= 1 }
    }

    /// The two walking circles, as on the transit map (WalkRangeMap). On the main actor: MapKit's map content is (macOS 27 SDK)
    @MainActor @MapContentBuilder
    static func circles(around center: Coordinate, settings: CatchSettings) -> some MapContent {
        MapCircle(center: center.clCoordinate, radius: settings.extendedRangeRadiusMeters)
            .foregroundStyle(WalkRangeMap.fill)
            .stroke(Color.walkRange, style: WalkRangeMap.extendedStroke)
            .mapOverlayLevel(level: .aboveRoads)
        MapCircle(center: center.clCoordinate, radius: settings.primaryRangeRadiusMeters)
            .foregroundStyle(WalkRangeMap.fill)
            .stroke(Color.walkRange, style: WalkRangeMap.primaryStroke)
            .mapOverlayLevel(level: .aboveRoads)
    }

    private var selectedStation: BoardStation? {
        stations.first { $0.id == selected }
    }

    /// Changes when the map should frame things again: another place, another walk, another set of stations
    private var frameKey: String {
        (start.map { "\($0.latitude) \($0.longitude)" } ?? "none") + " \(settings.extendedRangeRadiusMeters) "
            + stations.map(\.id).joined(separator: ",")
    }

    /// The outer circle and every station (PlannerMapFrame)
    /// With no place and no location yet, the whole service area (as Service Area shows it)
    private var startRegion: MKCoordinateRegion {
        guard let start else { return ServiceAreaMap.region }
        let r = PlannerMapFrame.region(place: start, radiusMeters: settings.extendedRangeRadiusMeters,
                                       stations: stations.compactMap(coordinate(_:)))
        return MKCoordinateRegion(center: r.center.clCoordinate,
                                  span: MKCoordinateSpan(latitudeDelta: r.latitudeSpan, longitudeDelta: r.longitudeSpan))
    }

    // MARK: Walking-time labels

    /// What the labels say: laid out again when it changes
    private var labelKeys: [String] {
        stations.map { "\($0.id) \(l.minutes($0.walk.walkSeconds)) \($0.range.rawValue)" }
    }

    /// Where places are on the map's view now: asked of MapKit while the window can be seen; out of sight worked out from the area
    /// the map last reported (MapScreen), and nil when there's nothing to go by. Not the projection first, as on the transit map: on
    /// this map, below the controls, the projection came out 76 points off where MapKit draws the stations, while clicks MapKit
    /// turned into places landed right
    private func mapScreen(_ proxy: MapProxy, size: CGSize) -> MapScreen? {
        if Self.inSight { return MapScreen(asking: proxy, size: size) }
        return MapScreen.projection(sight.visible, size: size).map { MapScreen($0) }
    }

    /// Lays the labels out a moment from now (layoutNow), when SwiftUI has finished updating the view: this is called from the map's
    /// actions (onChange, onMapCameraChange), which run while SwiftUI is updating it, and this map asks MapKit while it can be seen,
    /// which isn't done from there (see MapScreen). One at a time: a newer one takes the place of the one waiting
    private func layoutLabels(_ proxy: MapProxy, size: CGSize) {
        sight.layoutSoon?.cancel()
        sight.layoutSoon = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(MapScreen.askLaterMilliseconds))
            guard !Task.isCancelled else { return }
            layoutNow(proxy, size: size)
        }
    }

    /// Lays the labels out from where the stations are on screen now. Out of sight with nothing to go by, it waits until the window
    /// can be seen (sightChanged)
    private func layoutNow(_ proxy: MapProxy, size: CGSize) {
        // Hidden: laid out when shown again (onChange of shown)
        guard shown else { return }
        guard let screen = mapScreen(proxy, size: size) else {
            sight.layoutWaiting = true
            return
        }
        sight.layoutWaiting = false
        let spots = labelSpots(screen, size: size)
        let diameter = CGFloat(MapDotSize.fixedDiameter(StationDot.nearbyRadius)) + 4
        let dots = stations.compactMap { s in
            coordinate(s).flatMap { screen.point($0) }.map { MapDotSpot(id: s.id, center: $0, diameter: diameter) }
        }
        if dots != dotSpots { dotSpots = dots }
        if spots != labels { labels = spots }
    }

    /// Which labels fit where, as on the transit map (SubwayMapView.labelSpots): beside each station with times, minutes and name,
    /// or the minutes only, or none when there's no room; never over another station, the place's pin or the map's own buttons
    private func labelSpots(_ screen: MapScreen, size: CGSize) -> [WalkLabelSpot] {
        let shown = stations.filter { $0.noTimes == nil }
        guard !shown.isEmpty, size.width > 40, size.height > 40 else { return [] }
        let mpp = screen.metersPerPoint
        guard mpp > 0, MapLabelLayout.showsLabels(rangeRadius: settings.extendedRangeRadiusMeters / mpp) else { return [] }
        func point(_ c: Coordinate) -> CGPoint? { screen.point(c) }
        func box(around p: CGPoint, width: Double, height: Double, up: Double) -> MapLabelLayout.Box {
            MapLabelLayout.Box(x: Double(p.x) - width / 2, y: Double(p.y) - height / 2 - up, width: width, height: height)
        }
        let dot = MapDotSize.fixedDiameter(StationDot.nearbyRadius) + 4
        var dots: [String: [MapLabelLayout.Box]] = [:]
        for s in stations {
            dots[s.id] = s.stations.prefix(1).map(\.coordinate).compactMap(point).map { box(around: $0, width: dot, height: dot, up: 0) }
        }
        var clear: [MapLabelLayout.Box] = []
        if let place, let p = point(place.coordinate) { clear.append(box(around: p, width: 32, height: 60, up: 14)) }
        let rightToLeft = layoutDirection == .rightToLeft
        // The compass and + − in the bottom corner (MapCornerControls; which corner follows the language)
        let corner = MapCornerControls.room(layoutDirection)
        clear.append(MapLabelLayout.Box(x: rightToLeft ? 0 : Double(size.width - corner.width), y: Double(size.height - corner.height),
                                        width: Double(corner.width), height: Double(corner.height)))
        let scale = TextScale.factor
        var items: [MapLabelLayout.Item] = []
        for s in shown {
            guard let c = coordinate(s), let p = point(c) else { continue }
            let minutes = l.minutes(s.walk.walkSeconds)
            items.append(MapLabelLayout.Item(id: s.id, x: Double(p.x), y: Double(p.y),
                                             full: WalkTimeLabel.size(minutes: minutes, name: s.name, scale: scale),
                                             compact: WalkTimeLabel.size(minutes: minutes, name: nil, scale: scale)))
        }
        let bounds = MapLabelLayout.Box(x: 4, y: 4, width: Double(size.width) - 8, height: Double(size.height) - 8)
        let placed = MapLabelLayout.place(items, in: bounds, keepClear: clear, dots: dots, gap: max(12, dot / 2 + 3), rightToLeft: rightToLeft)
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return placed.compactMap { p in
            guard let s = byID[p.id], let c = coordinate(s) else { return nil }
            return WalkLabelSpot(placement: p, name: s.name, minutes: l.minutes(s.walk.walkSeconds), extended: s.range == .extended,
                                 coordinate: c, dot: SubwayMap.Station(id: s.id, name: s.name, lat: c.latitude, lon: c.longitude))
        }
    }
}

/// What PlannerMapView keeps that isn't drawn, so changing it doesn't draw the view again
private final class PlannerMapSight {
    /// The area the map showed after its last move: where the stations are on screen is worked out from it (MapScreen)
    var visible: MapVisibleRect?
    /// The labels couldn't be laid out (out of sight, with nothing to go by): laid out when the window can be seen again
    var layoutWaiting = false
    /// Laying the labels out a moment after SwiftUI's update, when MapKit may be asked (PlannerMapView.layoutLabels)
    var layoutSoon: Task<Void, Never>?
}

/// How Plan a Trip keeps the map it doesn't show (PlannerView.keptHidden: transparent, not clicked, not reached by the Tab key or a
/// screen reader), and what more is done so it doesn't go on drawing: it's emptied (.empty)
enum HiddenMapStyle: String {
    /// Only kept as above: a map with a place and stations on it went on drawing them
    case opacity
    /// Also given nothing to draw: no place, stations or pin (PlannerMapView.init)
    case empty
    /// Also its AppKit view hidden (MapViewHider)
    case appkit

    static let current: HiddenMapStyle = {
        return .empty
    }()
}

/// How the stack holding Plan a Trip's small map is hidden from a screen reader (PlannerView+Map.swift): the plain stack is hidden
enum HiddenMapGroup: String {
    /// The plain stack, hidden as it is
    case plain
    /// The stack made an accessibility element holding the map (.accessibilityElement(children: .contain)), then hidden
    case contain

    static let current: HiddenMapGroup = {
        return .plain
    }()
}

/// Behind a map: hides the map's AppKit view while the map is kept hidden, and shows it again on every update when it isn't
/// (a map left hidden by mistake would be a blank where a map should be). It looks only around itself: up from itself to the first
/// view holding a map, and there takes the map covering the same part of the window (Plan a Trip's window holds two). The map may
/// not be made yet on the first update: looked for again a few times. Not found: the map is left as it is, and that's logged
private struct MapViewHider: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.wantsHidden = hidden
        probe.apply()
    }

    final class Probe: NSView {
        /// Whether the map should be hidden now (not NSView's own isHidden: this view is never hidden)
        var wantsHidden = false
        private weak var map: MKMapView?
        private var tries = 0

        /// Never takes a click: the map in front of it gets them
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            if let map {
                if map.isHidden != wantsHidden { map.isHidden = wantsHidden }
                return
            }
            // Never hidden by this yet: nothing to show again
            guard wantsHidden, window != nil else { return }
            if let found = Self.ownMap(of: self) {
                map = found
                found.isHidden = true
                return
            }
            guard tries < 5 else {
                if tries == 5 {
                    tries += 1
                    AppLog.ui.notice("Hidden map: its view wasn't found, left as it is")
                }
                return
            }
            tries += 1
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.apply()
            }
        }

        /// Up from the probe to the first view holding a map; of the maps there, the one covering most nearly the same part of the
        /// window as the probe (the part they share, against all they cover together), and only if that's more than half
        static func ownMap(of probe: NSView) -> MKMapView? {
            let mine = probe.convert(probe.bounds, to: nil)
            guard mine.width > 0, mine.height > 0 else { return nil }
            var view = probe.superview
            while let holder = view {
                let maps = mapViews(in: holder)
                if !maps.isEmpty {
                    let best = maps.map { ($0, overlap($0.convert($0.bounds, to: nil), mine)) }.max { $0.1 < $1.1 }
                    guard let best, best.1 > 0.5 else { return nil }
                    return best.0
                }
                view = holder.superview
            }
            return nil
        }

        private static func mapViews(in view: NSView) -> [MKMapView] {
            view.subviews.flatMap { sub -> [MKMapView] in
                if let map = sub as? MKMapView { return [map] }
                return mapViews(in: sub)
            }
        }

        private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let shared = a.intersection(b)
            guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
            let both = shared.width * shared.height
            return both / (a.width * a.height + b.width * b.height - both)
        }
    }
}
