import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// "Subway map", in its own window (MapWindowView; opened from the item below "Plan a Trip" in the sidebar or the View menu):
/// draws MTA's official subway lines and stations on Apple Maps.
/// Click a station to see its lines; stations within walking range can jump straight to their departures.
/// The data checks for updates on the first open after the 1st of each month (see SubwayMapStore).
/// In ferry mode it's the "ferry map": NYC Ferry routes, Staten Island Ferry, NY Waterway and Seastreak, with piers drawn as dots.
/// In bus mode it's the "bus map": draws bus routes, nearby bus stops as small dots; click the map to pick the nearest bus stop.
/// Every mode's map shows the walking range around the origin as two teal circles (solid = primary, dashed = extended), and beside each
/// station in range (on the bus map the nearest few) its walking minutes and name, as in the station list; Hide Range hides them all.
/// Every mode's map shows the favorite places as gold stars too (FavoriteMarks): a station, the starting point or a clicked spot can
/// be made a favorite on its card, and a favorite's card walks from it (Use This Place).
struct SubwayMapView: View {
    @EnvironmentObject var transit: TransitModel
    @StateObject var model: SubwayMapModel
    var board: NearbyBoard
    /// "Show trains": the map window brings the main window to the front with this station selected
    var showStation: (String) -> Void
    let system: TransitSystem
    /// Bus map (MTA plus NJ Transit and a few others): the map has only routes, and draws just the nearby stops
    var bus: Bool { system.mode == .bus }

    init(board: NearbyBoard, system: TransitSystem = .subway, showStation: @escaping (String) -> Void) {
        self.board = board
        self.system = system
        self.showStation = showStation
        _model = StateObject(wrappedValue: SubwayMapModel(kind: .init(system)))
    }

    @State var position: MapCameraPosition = .automatic
    @State var selected: SubwayMap.Station?
    /// Hide Range / Show Range: remembered for next time, the same for every mode's map
    @AppStorage("mapShowsWalkingRange") var showsRange = true
    /// The walking-time labels drawn now: laid out again when the map stops moving (layoutLabels)
    @State var labels: [WalkLabelSpot] = []
    /// What the mouse is over (MapHover): a label opens to show the name, a dot without a label shows it under the dot
    @State private var hover = MapHover()
    /// The dots of the stations in range drawn at a fixed size, where they are (laid out with the labels): followed by the mouse
    @State var dotSpots: [MapDotSpot] = []
    /// Ties Apple's compass and + − in the map's bottom corner to the map (MapCornerControls)
    @Namespace private var mapScope
    /// Where the buttons, legend and station card are over the map, in its own points: labels keep clear of them
    @State var overlayFrames: [CGRect] = []
    /// The map's frame in the window (its top is the toolbar's height when the map runs on under the toolbar), for Service Area
    @State var mapFrame: CGRect = .zero
    /// The last place Service Area put the map: while the map is still there, a new size or panel fits the service area again
    @State var serviceAreaShown: MapCameraPosition?
    /// Where Service Area last fitted the rings: to tell whether the window or the panel changed since
    @State var serviceAreaFitted: ServiceAreaMap.Fit?
    /// Whether the map's stops are still measured against that fit (measureServiceArea)
    @State var serviceAreaMeasuring = false
    /// The area Service Area last asked MapKit for: the fit's, or a correction of it
    @State var serviceAreaAsked: MKMapRect?
    /// How many times Service Area asked again since it was fitted (see measureServiceArea)
    @State var serviceAreaCorrections = 0
    /// Fitting the service area again once the window and the panel have stopped changing (fitServiceAreaAgain)
    @State var serviceAreaRefit: Task<Void, Never>?
    /// Zoomed in close: the stations in walking range are drawn at a fixed size on screen, not in meters (MapDotSize)
    @State var dotsFixed = false
    /// What the map keeps that isn't drawn: where it is, when it went out of sight, and the waits for it to be still
    @State var sight = MapSight()
    /// The metro areas whose names fit on the map at its zoom now, and on how many lines (ServiceAreaMap.names): set when the map
    /// stops moving
    @State var metroNames: [MetroArea: Int] = [:]
    /// Laying the labels out again once the window has finished changing size (see onChange(of: geo.size))
    @State private var resizeLayout: Task<Void, Never>?
    /// Counts up to lay the labels out once the map is back in sight, when they had to wait (see layoutLabels)
    @State var relayout = 0
    /// The map is turned or tilted: no walking-time labels, clicks on the map itself do nothing, and the legend says so (layoutLabels)
    @State var mapTurned = false
    /// How far each metro area's name is moved up or down to keep clear of the favorites' stars (ServiceAreaMap.keepNamesClear)
    @State var metroShifts: [MetroArea: CGFloat] = [:]
    /// The favorite places, as the place picker lists them: read again when they change, here or in another window
    @State var favorites: [UserPlace] = []
    /// The favorites' stars where they're drawn now (FavoriteMarks): laid out with the labels, which keep clear of them
    @State var stars: [FavoriteStarSpot] = []
    /// The card at the bottom when it isn't a station's: a favorite's, the starting point's, a clicked spot's, or the favorites at
    /// one spot. One card at a time: a station's closes it, and it closes a station's
    @State var placeCard: MapPlaceCard?
    /// A favorite just taken out on a card: "Removed …" with Undo on the card for 10 seconds (⌘Z puts it back too)
    @State var removed: RemovedPlace?
    /// The current location saved as a favorite on its card, named by its address: its star is filled while that favorite is kept
    @State var currentSaved: UserPlace?
    /// Looking up the address of a clicked spot, or of the current location to save it
    @State var naming: Task<Void, Never>?
    @Environment(\.layoutDirection) var layoutDirection
    @Environment(\.undoManager) var undoManager

    var body: some View {
        let l = transit.l10n
        let ranges = stationRanges
        let labeledDots = Set(labels.map(\.dot.id))
        VStack(spacing: 0) {
            // Networking turned off in Settings: don't show Apple Maps (the map itself needs the network)
            if transit.networkAllowed {
                GeometryReader { geo in
                    Map(position: $position, scope: mapScope) {
                        // Walking range around the origin (none before the first location; on standby the last origin), drawn first so the lines,
                        // stations and street names stay on top. The same sizes the station list uses, from the range settings (CatchSettings)
                        if showsRange, let origin = transit.origin {
                            let range = transit.effectiveSettings.sanitized()
                            MapCircle(center: origin.coordinate.clCoordinate, radius: range.extendedRangeRadiusMeters)
                                .foregroundStyle(WalkRangeMap.fill)
                                .stroke(Color.walkRange, style: WalkRangeMap.extendedStroke)
                                .mapOverlayLevel(level: .aboveRoads)
                            MapCircle(center: origin.coordinate.clCoordinate, radius: range.primaryRangeRadiusMeters)
                                .foregroundStyle(WalkRangeMap.fill)
                                .stroke(Color.walkRange, style: WalkRangeMap.primaryStroke)
                                .mapOverlayLevel(level: .aboveRoads)
                        }
                        // The service area, one dashed ring per metro area, and their names where they fit
                        ServiceAreaMap.content(l, names: metroNames, shifts: metroShifts)
                        ForEach(model.lines) { line in
                            MapPolyline(coordinates: line.coordinates)
                                .stroke(line.color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        }
                        // Stations in walking range are bigger, with a blue ring: solid in the primary range, dashed in the extended range.
                        // Sized in meters, so they grow and shrink with the map; zoomed in close the ones in range are drawn at a fixed
                        // size on screen instead (FixedStationDot). No dot changes size as the map zooms (that made zooming slow)
                        // Stations without times (NoTimesStations) are gray dots among them
                        // The lists are the same arrays from one redraw to the next while nothing changes (dotLists)
                        let dots = dotLists(ranges)
                        ForEach(dots.circles, id: \.id) { s in
                            let range = ranges[s.id]
                            MapCircle(center: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                                      radius: range == nil ? StationDot.radius : StationDot.nearbyRadius)
                                .foregroundStyle(NoTimesStations.isNoTimes(s.id) ? Color.noTimesDot : Color.white)
                                .stroke(range == nil ? Color.black.opacity(0.75) : Color.accentColor, style: StationDot.ring(range))
                        }
                        if dotsFixed {
                            let onMap = Set(dotSpots.filter { MapAccessibility.isOnMap($0.frame, size: geo.size) }.map(\.id))
                            ForEach(dots.fixedDots, id: \.id) { s in
                                let isSelected = selected?.id == s.id
                                // Selected or under the mouse, and without a label, the name shows under it, as under the
                                // selected marker below
                                let showsTitle = (isSelected || hover.dot == s.id) && !labeledDots.contains(s.id)
                                Annotation(showsTitle ? s.name : String(), coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon),
                                           anchor: .center) {
                                    FixedStationDot(name: s.name, range: ranges[s.id], selected: isSelected,
                                                    gray: NoTimesStations.isNoTimes(s.id),
                                                    offMap: !dotSpots.isEmpty && !onMap.contains(s.id)) {
                                        withAnimation(Motion.ease(0.2)) { selected = s }
                                    }
                                }
                                .annotationTitles(showsTitle ? .automatic : .hidden)
                            }
                        }
                        // Beside the stations in range: the walking minutes and the name, as in the station list (WalkTimeLabel)
                        ForEach(labels) { spot in
                            let isSelected = selected?.id == spot.dot.id
                            let hovered = hover.label == spot.id
                            // No title: it's never shown, and screen readers would read the name once more beside the label's own
                            Annotation(String(), coordinate: spot.coordinate.clCoordinate,
                                       anchor: spot.anchor(open: WalkTimeLabel.opens(spot, hovered: hovered, selected: isSelected))) {
                                WalkTimeLabel(l: l, spot: spot, selected: isSelected, hovered: hovered) {
                                    withAnimation(Motion.ease(0.2)) { selected = spot.dot }
                                }
                            }
                            .annotationTitles(.hidden)
                        }
                        // The favorite places: a gold star each, a small one on its station's dot, one with how many for several
                        // close together (FavoriteMarks). Over the lines, the dots and the labels, which keep clear of them.
                        // Only the ones on the map as it was laid out: MapKit gives screen readers an unnamed element for each
                        // annotation, also one drawn outside the window. One brought onto the map shows when the map stops, as
                        // the labels do
                        ForEach(stars.filter { MapAccessibility.isOnMap($0.frame, size: geo.size) }) { spot in
                            // Its name under it while the mouse is over it, as under a station's dot without a label. Only then a
                            // title: screen readers would read the name once more beside the star's own (MapAccessibility)
                            let showsTitle = hover.star == spot.id
                            Annotation(showsTitle ? spot.title(l) : String(), coordinate: spot.coordinate.clCoordinate, anchor: spot.anchor) {
                                FavoriteStarView(l: l, spot: spot, selected: isOpen(spot)) {
                                    clickStar(spot, size: geo.size)
                                }
                            }
                            .annotationTitles(showsTitle ? .automatic : .hidden)
                        }
                        // A spot clicked on the empty map, while its card is open: blue, as a place not used yet (as on Plan a
                        // Trip's larger map). Not saved
                        if let pin = pinSpot {
                            Marker(pin.name ?? "", systemImage: "mappin", coordinate: pin.coordinate.clCoordinate)
                                .tint(Color.accentColor)
                        }
                        // The selected station's marker (a station in range drawn at the fixed size marks it itself)
                        if let s = selected, !(dotsFixed && ranges[s.id] != nil) {
                            Annotation(s.name, coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), anchor: .center) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                            // A station with a label has its name there already
                            .annotationTitles(labeledDots.contains(s.id) ? .hidden : .automatic)
                        }
                        if let origin = transit.origin {
                            // The "my location" marker may turn on Location Services, which standby never uses:
                            // on standby the last position walking times were measured from gets a plain pin instead
                            if origin.kind == .current, transit.isActive {
                                UserAnnotation()
                            } else {
                                // Demo mode's current location (Times Square) is a plain marker too, never the Mac's own location
                                Marker(origin.name, systemImage: origin.kind == .current || origin.kind == .demoCurrent ? "location" : "mappin",
                                       coordinate: origin.coordinate.clCoordinate)
                            }
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    // Only the scale is placed by MapKit: the compass and + − are placed by the app (MapCornerControls)
                    .mapControls {
                        MapScaleView()
                    }
                    .onTapGesture(coordinateSpace: .local) { point in
                        // The second click of a double click only zooms in, as MapKit does: the first click did what a click
                        // does (without this, a pin dropped by the first click would go again at once)
                        guard Self.clickCount < 2 else { return }
                        // Where the click is on the map comes from the area the map last reported (MapScreen; MapKit is never
                        // asked). Nothing to go by (turned or tilted, as the legend says, or a new map that hasn't reported yet):
                        // the click does nothing here, and the buttons on the map (a star, a station's dot) still do their own
                        guard let screen = mapScreen(size: geo.size) else { return }
                        // What's drawn on top first: a favorite's star, a label (it picks its station), the starting point's pin.
                        // Their own buttons may get the click instead: both do the same
                        if let star = stars.last(where: { $0.frame.contains(point) }) {
                            clickStar(star, size: geo.size)
                            return
                        }
                        if let spot = labels.first(where: { $0.frame.contains(point) }) {
                            withAnimation(Motion.ease(0.2)) { selected = spot.dot }
                            return
                        }
                        // The pin's round top (the upper half of the current location's dot) opens the starting point's card. Its
                        // point is where a station's dot can be too: the station first there
                        let origin = originFrame(screen)
                        if let origin, origin.contains(point), point.y < origin.maxY - Self.originPointHeight {
                            openCard(.origin)
                            return
                        }
                        guard let tapped = screen.coordinate(at: point) else { return }
                        let hit = bus ? nearestBusStop(to: tapped) : nearestDot(to: tapped)
                        // Only counts as selected when clicking near a station (within about 20 pixels at the current zoom)
                        let tolerance = (screen.metersPerPoint > 0 ? screen.metersPerPoint : 10) * 20
                        if let station = hit.flatMap({ $0.meters <= max(tolerance, 60) ? $0.station : nil }) {
                            withAnimation(Motion.ease(0.2)) { selected = station }
                        } else if origin?.contains(point) == true {
                            openCard(.origin)
                        } else if selected != nil || placeCard != nil {
                            // Away from the stations with a card open: only closes it
                            closeCards()
                        } else {
                            // Nothing open: a pin there, with its card (its address, a star and Use This Place)
                            dropPin(tapped)
                        }
                    }
                    // The label or dot under the mouse, followed here over the whole map, not by the label or dot itself (MapHover)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        let over: MapHover
                        switch phase {
                        // Turned or tilted, where things are on screen isn't known: nothing opens under the mouse
                        case .active(let point):
                            over = mapTurned ? MapHover() : MapHover.at(point, labels: labels, dots: dotSpots, stars: stars, open: hover.label)
                        case .ended: over = MapHover()
                        }
                        if over != hover { hover = over }
                    }
                    // The labels are laid out when the map first shows and again when it stops moving, and when what they say or keep clear of changes
                    .onMapCameraChange(frequency: .onEnd) { context in
                        sight.camera = context.camera
                        sight.visible = MapVisibleRect(rect: context.rect, heading: context.camera.heading,
                                                       pitch: context.camera.pitch, size: geo.size)
                        // Service Area: each stop is measured and the map asked again while the rings aren't in place
                        if !measureServiceArea(mapScreen(size: geo.size)) {
                        }
                        // The metro areas' names and the labels wait until the map has been still for a moment: a zoom with
                        // the scroll wheel or the trackpad stops many times on its way, and working them out at each stop
                        // (and drawing the view again for it) made zooming lag. A new stop takes the place of the wait
                        // before it; one that finds the map moved again waits on
                        let rect = context.rect, size = geo.size
                        sight.settle?.cancel()
                        sight.settle = Task { @MainActor in
                            repeat {
                                try? await Task.sleep(for: .milliseconds(MapRedraw.stillMilliseconds))
                                guard !Task.isCancelled else { return }
                            } while !MapRedraw.isStill(since: sight.movedAt, now: Date())
                            sight.names = ServiceAreaMap.names(rect, width: size.width, l: l)
                            layoutLabels(size: size)
                        }
                    }
                    // Only noted, not drawn: drawing the map again when it comes back in sight waits until it's still
                    // A label open under the mouse closes while the map moves (the labels are laid out again after)
                    .onMapCameraChange(frequency: .continuous) { _ in
                        sight.movedAt = Date()
                        if hover != MapHover() { hover = MapHover() }
                    }
                    .onChange(of: labelKeys, initial: true) { _, _ in layoutLabels(size: geo.size) }
                    // The map's own stations read (on opening, or after another transit mode): the labels stand beside its dots
                    .onChange(of: model.map == nil) { _, _ in layoutLabels(size: geo.size) }
                    .onChange(of: transit.origin?.coordinate) { _, _ in layoutLabels(size: geo.size) }
                    .onChange(of: originIsDot) { _, _ in layoutLabels(size: geo.size) }
                    // The walking origin moved to another place: bring the map there, unless it was moved by hand since it was
                    // last placed (when the window opened, by Recenter, Whole Map or Service Area, or by an earlier move like this)
                    .onChange(of: originPlaceKey) { _, _ in
                        guard !position.positionedByUser else { return }
                        withAnimation(Motion.ease(0.4)) { position = .region(startRegion) }
                    }
                    .onChange(of: showsRange) { _, _ in layoutLabels(size: geo.size) }
                    .onChange(of: overlayFrames) { _, _ in layoutLabels(size: geo.size) }
                    // A new window size: wait a moment for the window to stop changing (it changes many times a second while it's
                    // dragged). The labels then wait for the map to report its area at the new size (layoutLabels)
                    .onChange(of: geo.size) { _, size in
                        resizeLayout?.cancel()
                        resizeLayout = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            layoutLabels(size: size)
                        }
                    }
                    .onChange(of: selected?.id) { _, id in
                        // One card at a time: a station's closes any other
                        if id != nil, placeCard != nil { closePlaceCard() }
                        layoutLabels(size: geo.size)
                    }
                    .onChange(of: favorites) { _, _ in layoutLabels(size: geo.size) }
                    .onAppear {
                        mapFrame = geo.frame(in: .global)
                        showServiceAreaIfAsked()
                    }
                    .onChange(of: geo.frame(in: .global)) { _, frame in
                        mapFrame = frame
                        fitServiceAreaAgain()
                    }
                    .onChange(of: layoutDirection) { _, _ in layoutLabels(size: geo.size) }
                    .onChange(of: relayout) { _, _ in layoutLabels(size: geo.size) }
                }
                .overlay(alignment: .topTrailing) {
                    // The legend under the buttons, from the same edge, on one panel: as wide as its widest part, not the map
                    MapPanelColumn {
                        // The stations in range, to pick one with the keyboard or a screen reader too (the dots and labels are
                        // for the mouse)
                        if !board.stations.isEmpty {
                            MapStationMenu(stations: board.stations, selectedID: selected?.id,
                                           title: l.pick(system, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"),
                                                         ferry: l.t("Nearby piers")),
                                           l: l) { selectFromMenu($0) }
                                .padding(.bottom, 6)
                                .layoutValue(key: FillsPanelWidth.self, value: true)
                        }
                        MapCameraButtons(l: l,
                                         showsRange: $showsRange,
                                         recenter: { position = .region(startRegion) },
                                         wholeMap: { position = .region(ServiceAreaMap.wholeRegion(model.map, system: system,
                                                                                                    area: wholeMapArea)) },
                                         serviceArea: { showServiceArea() })
                        ServiceAreaLegend(l: l, range: rangeLegend(l), favorites: !stars.isEmpty)
                        // Turned or tilted: what doesn't work until the map faces north again (layoutLabels). It wraps to the
                        // panel's width rather than widening it
                        if mapTurned {
                            MapTurnedNote(l: l)
                                .layoutValue(key: WrapsToPanelWidth.self, value: true)
                        }
                    }
                    .mapPanel()
                    .background(MapOverlayFrame())
                }
                // Apple's compass and + − in the bottom corner (the labels keep clear of them: labelSpots), under the station card
                .overlay(alignment: .bottomTrailing) {
                    MapCornerControls(scope: mapScope)
                }
                .overlay(alignment: .bottom) {
                    if let s = selected {
                        stationCard(s, l: l)
                            .background(MapOverlayFrame())
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let card = placeCard {
                        placeCardView(card, l: l)
                            .background(MapOverlayFrame())
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // The compass and + − above work this map (Map(scope:))
                .mapScope(mapScope)
                .coordinateSpace(name: MapOverlayFrame.space)
                // Store only a real change: storing lays the labels out again
                .onPreferenceChange(MapOverlayFrames.self) { frames in
                    if frames != overlayFrames {
                        overlayFrames = frames
                        showServiceAreaIfAsked()
                        fitServiceAreaAgain()
                    }
                }
            } else {
                NetworkOffNote(l: l, large: true)
            }

            Divider()
            footer(l)
        }
        .onAppear {
            reloadFavorites()
            if transit.isBus { transit.ensureBusCatalogLoaded() }
            // The mode now, also when it changed while the window was closed (showMode may not have run before this)
            model.show(kind: .init(system))
            model.open(allowNetwork: transit.isActive && !transit.isDemo && transit.networkAllowed)   // Demo mode downloads nothing
            // Not over the service area the empty page asked for: the map and its panel can report their places before this runs,
            // and the service area is then shown already
            if serviceAreaShown == nil { position = .region(startRegion) }
            showServiceAreaIfAsked()
            // The window may open covered, or with the app not active
            sightChanged()
        }
        // Another transit mode, on this same map
        .onChange(of: system) { _, new in showMode(new) }
        // The empty page's "Service Area" button while this window is already open
        .onReceive(NotificationCenter.default.publisher(for: MapWindow.serviceAreaRequested)) { _ in showServiceAreaIfAsked() }
        // The favorites changed here or in another window (the place picker, Plan a Trip's ★ popover)
        .onReceive(NotificationCenter.default.publisher(for: SharedStore.placesChanged)) { _ in reloadFavorites() }
        // Started from standby with this window open: check for map updates now, as opening the window would have. On standby the
        // map doesn't go online, and a map never downloaded would otherwise stay empty until the window was opened again
        .onChange(of: transit.isActive) { _, active in
            if active { model.open(allowNetwork: !transit.isDemo && transit.networkAllowed) }
        }
        .onDisappear {
            resizeLayout?.cancel()
            sight.redraw?.cancel()
            sight.settle?.cancel()
            sight.areaAsk?.cancel()
            sight.areaAsk = nil
            naming?.cancel()
            model.release()
        }
        // Out of sight and back: the window covered or not, the app in the background or not
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window = note.object as? NSWindow, Self.isMapWindow(window) { sightChanged() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sightChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in sightChanged() }
    }

    /// Another transit mode on this map (MapWindowView keeps one map for every mode): what belonged to the mode before goes, as it
    /// would with a new map, and the map goes back to the starting point. The map view stays, and so do where it is, the area it
    /// last reported and the metro areas' names (`sight`): its size hasn't changed, so the labels are laid out from that area at
    /// once (relayout), and again when the new mode's stations have been read (onChange of model.map). A wait for the map to be still
    /// goes on too (the names are of where the map stopped, whatever the mode). With the window closed the new mode's map is read
    /// when it opens (onAppear)
    func showMode(_ new: TransitSystem) {
        naming?.cancel()
        naming = nil
        selected = nil
        placeCard = nil
        hover = MapHover()
        labels = []
        dotSpots = []
        sight.dots = StationDotLists()
        resizeLayout?.cancel()
        resizeLayout = nil
        sight.areaAsk?.cancel()
        sight.areaAsk = nil
        serviceAreaRefit?.cancel()
        serviceAreaRefit = nil
        serviceAreaShown = nil
        serviceAreaFitted = nil
        serviceAreaMeasuring = false
        serviceAreaAsked = nil
        serviceAreaCorrections = 0
        model.show(kind: .init(new))
        if transit.isMapWindowOpen {
            if transit.isBus { transit.ensureBusCatalogLoaded() }
            model.open(allowNetwork: transit.isActive && !transit.isDemo && transit.networkAllowed)   // Demo mode downloads nothing
        }
        position = .region(startRegion)
        relayout &+= 1
    }
}

/// What SubwayMapView keeps that isn't drawn, so changing it doesn't draw the view again
final class MapSight {
    /// Where the map is, from its last move: the map is moved back near there to draw it again
    var camera: MapCamera?
    /// The area the map showed after its last move: where the stations are on screen is worked out from it (MapScreen)
    var visible: MapVisibleRect?
    /// The metro areas whose names fit at the zoom of its last stop, and on how many lines (ServiceAreaMap.names): drawn kept clear
    /// of the favorites' stars (ServiceAreaMap.keepNamesClear)
    var names: [MetroArea: Int] = [:]
    /// The labels couldn't be laid out (out of sight, with nothing to go by): laid out when the map can be seen again
    var layoutWaiting = false
    /// When it last moved (a drag or a zoom, the user's or the app's)
    var movedAt = Date.distantPast
    /// Since when the map has been out of sight: nil while it can be seen
    var hiddenSince: Date?
    /// Which way the last nudge went: the next one goes back
    var nudgedOut = false
    var redraw: Task<Void, Never>?
    /// Waiting for the map to be still before the metro areas' names and the labels are worked out (see onMapCameraChange)
    var settle: Task<Void, Never>?
    /// Waiting for the map to report an area that fits its view; moved a thousandth if it doesn't (SubwayMapView.askForArea)
    var areaAsk: Task<Void, Never>?
    /// The dots the map draws, kept between redraws (see SubwayMapView.dotLists)
    var dots = StationDotLists()
}

/// Frames of what's drawn over the transit map (the buttons and legend, the station card), in the map's own points: labels keep clear
private struct MapOverlayFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Reports the frame of the view it's the background of (MapOverlayFrames)
private struct MapOverlayFrame: View {
    static let space = "transitMap"

    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: MapOverlayFrames.self, value: [g.frame(in: .named(Self.space))])
        }
    }
}

/// The map's top-corner panel: its parts one under the other from the leading edge, as wide as the widest of them would be on its
/// own. A part marked FillsPanelWidth (the Nearby stations menu) is drawn that wide too, and can make the panel wider only up to its
/// own width and never wider than the map. In a VStack that part would be offered the whole map's width and take it, and the panel
/// with it. A part marked WrapsToPanelWidth (the note while the map is turned) doesn't count toward the width: it wraps to it.
/// It places the parts itself, from the right in right-to-left languages, as EqualWidthButtons does
private struct MapPanelColumn<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        MapPanelLayout(rightToLeft: direction == .rightToLeft) {
            content.environment(\.layoutDirection, direction)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// A part of the map's corner panel that fills the panel's width rather than setting it (MapPanelColumn)
private struct FillsPanelWidth: LayoutValueKey {
    static let defaultValue = false
}

/// A part of the map's corner panel that wraps to the panel's width and never sets it (MapTurnedNote)
private struct WrapsToPanelWidth: LayoutValueKey {
    static let defaultValue = false
}

/// Under the legend while the transit map is turned or tilted: the walking-time labels are hidden and clicks on the map itself do
/// nothing until it faces north and is flat again (SubwayMapView.layoutLabels). In orange, as the time zone's note (TimeZoneNoteText)
private struct MapTurnedNote: View {
    let l: UIText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "location.north.line").accessibilityHidden(true)
            Text(l.t("While the map is turned or tilted, walking times are hidden, and clicking the map doesn't pick a station or drop a pin."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.scaled(.caption).weight(.medium))
        .foregroundStyle(Color.noticeOrange)
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }
}

private struct MapPanelLayout: Layout {
    var rightToLeft = false

    /// The panel's width: the widest of the other parts at the width offered (as a VStack measures them, so the buttons still
    /// turn into icons when the map is narrow), or the filling part's own width when that is wider, within the width offered
    private func panelWidth(for proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let offered = ProposedViewSize(width: proposal.width, height: nil)
        var parts: CGFloat = 0, filling: CGFloat = 0
        for view in subviews where !view[WrapsToPanelWidth.self] {
            if view[FillsPanelWidth.self] {
                filling = max(filling, view.sizeThatFits(.unspecified).width)
            } else {
                parts = max(parts, view.sizeThatFits(offered).width)
            }
        }
        let wanted = max(parts, filling)
        guard let limit = proposal.width else { return wanted }
        return min(wanted, max(limit, parts))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = panelWidth(for: proposal, subviews)
        let offer = ProposedViewSize(width: width, height: nil)
        return CGSize(width: width, height: subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(offer).height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offer = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for view in subviews {
            let size = view.sizeThatFits(offer)
            let x = rightToLeft ? bounds.maxX - size.width : bounds.minX
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            y += size.height
        }
    }
}

/// "Nearby stations" at the top of the transit map's buttons: the stations in walking range, written as in the menu bar panel's
/// station menu, the one selected on the map ticked. Choosing one does what a click on its dot does, so the keyboard (Tab, Space,
/// the arrow keys) and screen readers can pick a station on the map too
private struct MapStationMenu: View {
    var stations: [BoardStation]
    /// The station selected on the map (SubwayMap.Station's ID: one of a complex's stations)
    var selectedID: String?
    /// "Nearby stations", "Nearby bus stops" or "Nearby piers"
    var title: String
    var l: UIText
    var select: (BoardStation) -> Void

    private func isSelected(_ s: BoardStation) -> Bool {
        guard let selectedID else { return false }
        return s.stations.contains { $0.id == selectedID }
    }

    var body: some View {
        Menu {
            Text(title)
            // The menu's own check mark on the selected one, as in the menu bar panel's station menu
            ForEach(stations) { s in
                Toggle(s.menuText(l), isOn: .afterViewUpdate(get: { isSelected(s) }, set: { _ in select(s) }))
            }
        } label: {
            // Drawn like the buttons under it (AppBezel, at every text size), as wide as they are together
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // The small arrow says that it opens a list of choices
                Image(systemName: "chevron.down")
                    .font(.scaled(.caption2).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .modifier(AppBezel())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

/// What the transit map gives screen readers, and how far Nearby stations zooms in
enum MapAccessibility {
    /// A map wider than this (meters) is too far out to tell the stations in range apart: a station chosen in Nearby stations is
    /// shown closer
    static let closeEnoughMeters = 10_000.0

    /// Whether any of a frame (in the map's own points) is on the map as it's shown. What's drawn outside it isn't given to screen
    /// readers: they'd read it, and pressing it would click the empty map
    static func isOnMap(_ frame: CGRect, size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).intersects(frame)
    }
}
