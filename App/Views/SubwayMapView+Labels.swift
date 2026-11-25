import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension SubwayMapView {
    // MARK: Drawing the map again when it comes back in sight

    /// The map's own window (there's only one)
    static func isMapWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MapWindow.id) == true
    }

    /// The map can be seen: its window open and not covered, and the app active
    private var mapInSight: Bool {
        NSApp.isActive && NSApp.windows.contains { Self.isMapWindow($0) && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Notes when the map goes out of sight. Back in sight after at least MapRedraw.afterHidden, it's drawn again: out of sight macOS
    /// may stop drawing it, and it can stay blank (the base map, lines and dots gone, the labels still there; a guess, see MapRedraw)
    func sightChanged() {
        guard mapInSight else {
            sight.redraw?.cancel()
            if sight.hiddenSince == nil { sight.hiddenSince = Date() }
            return
        }
        // Labels that couldn't be laid out while the map was out of sight are laid out now
        if sight.layoutWaiting { relayout &+= 1 }
        guard let since = sight.hiddenSince else { return }
        sight.hiddenSince = nil
        let seconds = Date().timeIntervalSince(since)
        guard seconds >= MapRedraw.afterHidden else { return }
        sight.redraw?.cancel()
        sight.redraw = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            redraw(afterHidden: seconds)
        }
    }

    /// Draws the map again after it was out of sight (nudge)
    func redraw(afterHidden seconds: TimeInterval) {
        guard nudge() else { return }
        MapRedraw.count += 1
        AppLog.ui.notice("Map drawn again after \(Int(seconds), privacy: .public) s out of sight")
    }

    /// Moves the map a thousandth closer, or back again the next time: too little to see, but it's drawn again and reports its area
    /// (onMapCameraChange). Not while it's being moved (it's drawn anyway, and a drag or zoom isn't cut short), nor before it has
    /// reported where it is. False when it wasn't moved
    @discardableResult func nudge() -> Bool {
        guard let camera = sight.camera, Date().timeIntervalSince(sight.movedAt) >= 0.5 else { return false }
        sight.nudgedOut.toggle()
        position = .camera(MapCamera(centerCoordinate: camera.centerCoordinate,
                                     distance: camera.distance * (sight.nudgedOut ? 1.001 : 1 / 1.001),
                                     heading: camera.heading, pitch: camera.pitch))
        return true
    }

    /// Stops drawn on the bus map: nearby bus stops (drawing all ten thousand-plus citywide is too cluttered and uses memory).
    private var busStops: [SubwayMap.Station] {
        board.stations.flatMap(\.stations).map {
            SubwayMap.Station(id: $0.id, name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
        }
    }

    /// The stations without times of this map's mode (NoTimesStations), drawn as gray dots. None on the bus map, and none in
    /// Demo mode, which shows only its own stations
    private var noTimesDots: [SubwayMap.Station] {
        guard !bus, !transit.isDemo else { return [] }
        return NoTimesStations.stations(for: system).map {
            SubwayMap.Station(id: $0.id, name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
        }
    }

    /// The dot nearest a click: one of the map's own stations or a gray one, whichever is nearer
    func nearestDot(to c: Coordinate) -> (station: SubwayMap.Station, meters: Double)? {
        let gray = noTimesDots
            .map { ($0, WalkEstimator.distanceMeters(c, Coordinate(latitude: $0.lat, longitude: $0.lon))) }
            .min { $0.1 < $1.1 }
            .map { (station: $0.0, meters: $0.1) }
        return [model.map?.nearestStation(to: c), gray].compactMap { $0 }.min { $0.meters < $1.meters }
    }

    func nearestBusStop(to c: Coordinate) -> (station: SubwayMap.Station, meters: Double)? {
        // MTA bus stops (station catalog), plus stops from the nearby slice of NJ Transit and the other operators; take the nearest
        let mta = transit.busCatalog?.stops
            .map { ($0, WalkEstimator.distanceMeters(c, $0.coordinate)) }
            .min { $0.1 < $1.1 }
            .map { (station: SubwayMap.Station(id: $0.0.id, name: $0.0.name, lat: $0.0.lat, lon: $0.0.lon), meters: $0.1) }
        let other = transit.ferryFeed?.piers
            .map { ($0, WalkEstimator.distanceMeters(c, $0.coordinate)) }
            .min { $0.1 < $1.1 }
            .map { (station: SubwayMap.Station(id: $0.0.id, name: $0.0.name, lat: $0.0.lat, lon: $0.0.lon), meters: $0.1) }
        return [mta, other].compactMap { $0 }.min { $0.meters < $1.meters }
    }

    /// The legend's walking-range rows, in the words of the sidebar's legend (RangeLegend); none while the circles aren't drawn
    func rangeLegend(_ l: UIText) -> WalkRangeLegend? {
        guard showsRange, transit.origin != nil else { return nil }
        let s = transit.effectiveSettings.sanitized()
        return WalkRangeLegend(primary: l.f("Primary: %@ walk", l.minutes(s.primaryWalkSeconds)),
                               extended: l.f("Extended: %@ walk", l.minutes(s.extendedWalkSeconds)),
                               extra: transit.tempExtraMinutes > 0 ? l.f("+%@ for now", l.minutes(transit.tempExtraMinutes * 60)) : nil)
    }

    /// Changes when the walking origin moves to another place: a newly chosen place, the other Walk from, the first location found,
    /// a fallback place after location failed. Not when the current location moves as you walk: the map isn't pulled back to you
    /// while you look around it
    var originPlaceKey: String {
        guard let origin = transit.origin else { return "none" }
        switch origin.kind {
        case .current: return "current"
        case .manual, .manualFallback, .demoCurrent: return "place \(origin.coordinate.latitude) \(origin.coordinate.longitude)"
        }
    }

    /// Whole Map's metro area: the start place's, or outside them all the nearest one; none before there's a place (all of them)
    var wholeMapArea: MetroArea? {
        transit.areaRegion?.metroArea ?? transit.origin.flatMap { MetroArea.nearest(to: $0.coordinate) }
    }

    var startRegion: MKCoordinateRegion {
        guard let origin = transit.origin else { return ServiceAreaMap.region }
        return MKCoordinateRegion(center: origin.coordinate.clCoordinate,
                                  span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))
    }

    // MARK: Walking-time labels

    /// Walking range of each station in the station list, by station ID (each station of a complex gets the complex's range)
    var stationRanges: [String: SearchRange] {
        var result: [String: SearchRange] = [:]
        for b in board.stations {
            for s in b.stations where result[s.id] == nil { result[s.id] = b.range }
        }
        return result
    }

    /// The stations that get a label: every station in range, but on the bus map only the nearest few (there are often dozens)
    private var labelStations: [BoardStation] {
        bus ? Array(board.stations.prefix(MapLabelLayout.busLabelLimit)) : board.stations
    }

    /// What the labels say: they're laid out again when it changes
    var labelKeys: [String] {
        let l = transit.l10n
        return labelStations.map { "\($0.id) \(l.minutes($0.walk.walkSeconds)) \($0.range.rawValue)" }
    }

    /// Where places are on the map's view now (MapScreen): worked out from the area the map last reported. nil: nothing to go by
    /// (the map hasn't reported an area at this size yet, or it's turned or tilted). MapKit is never asked (see MapScreen)
    func mapScreen(size: CGSize) -> MapScreen? {
        MapScreen.projection(sight.visible, size: size).map { MapScreen($0) }
    }

    /// Works out which labels fit where (MapLabelLayout), from where the stations are on screen now, and whether the stations in
    /// range are drawn at their fixed size; before them, where the favorites' stars go (FavoriteMarks), and the metro areas' names
    /// kept clear of the stars. All from the area the map last reported (mapScreen). When there isn't one for the view's size yet
    /// (a new map, another transit mode, a new window size), the map's next report lays them out (onMapCameraChange), and one that
    /// doesn't come is asked for (askForArea); out of sight they wait until the map can be seen (sightChanged).
    /// Turned or tilted, where the stations are on screen isn't worked out: no labels until the map faces north and is flat again
    /// (the compass turns it back), clicks on the map itself do nothing, and the legend says so. The stars stay as they were laid out
    func layoutLabels(size: CGSize) {
        if MapScreen.isTurned(sight.visible, size: size) {
            sight.areaAsk?.cancel()
            sight.areaAsk = nil
            sight.layoutWaiting = false
            if !mapTurned { mapTurned = true }
            if !labels.isEmpty { labels = [] }
            if !dotSpots.isEmpty { dotSpots = [] }
            if sight.names != metroNames { metroNames = sight.names }
            return
        }
        guard let screen = mapScreen(size: size) else {
            sight.layoutWaiting = true
            // The names still follow the zoom, as they are (where the stars are is worked out with the labels)
            if sight.names != metroNames { metroNames = sight.names }
            askForArea(size: size)
            return
        }
        sight.areaAsk?.cancel()
        sight.areaAsk = nil
        sight.layoutWaiting = false
        if mapTurned { mapTurned = false }
        // Only the dots of the stations in range change, and only when the zoom passes where they become fixed (unchanged while the
        // map's scale isn't known)
        if screen.metersPerPoint > 0 {
            let fixed = MapDotSize.isFixed(metersPerPoint: screen.metersPerPoint)
            if fixed != dotsFixed { dotsFixed = fixed }
        }
        // The favorites' stars first: the metro areas' names (those that fit at this zoom, worked out when the map stopped) and the
        // labels keep clear of them
        let starSpots = favoriteStars(screen, size: size)
        if starSpots != stars { stars = starSpots }
        let names = ServiceAreaMap.keepNamesClear(sight.names, rect: sight.visible?.rect, width: size.width, l: transit.l10n,
                                                  stars: starSpots.map(\.frame), point: { screen.point($0) })
        if names.names != metroNames { metroNames = names.names }
        if names.shifts != metroShifts { metroShifts = names.shifts }
        let spots = labelSpots(screen, size: size, stars: starSpots)
        // Drawn at a fixed size now (the value just stored above may not read back yet)
        let fixedNow = screen.metersPerPoint > 0 ? MapDotSize.isFixed(metersPerPoint: screen.metersPerPoint) : dotsFixed
        let dots = fixedNow ? fixedDotSpots(screen) : []
        if dots != dotSpots { dotSpots = dots }
        if spots != labels { labels = spots }
    }

    /// The map hasn't reported an area that fits its view: it does when it first shows, stops moving or takes on a new size, and that
    /// report lays the labels out. If none has come a second from now while the map can be seen, it's moved a thousandth (nudge), which
    /// makes it report. One at a time: a newer one takes the place of the one waiting
    private func askForArea(size: CGSize) {
        sight.areaAsk?.cancel()
        sight.areaAsk = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            sight.areaAsk = nil
            guard mapInSight, mapScreen(size: size) == nil, !MapScreen.isTurned(sight.visible, size: size), nudge() else { return }
            AppLog.ui.notice("Map moved a thousandth: no area reported for its size")
        }
    }

    /// Where the dots of the stations in range are while they're drawn at a fixed size (FixedStationDot), for the mouse (MapHover)
    private func fixedDotSpots(_ screen: MapScreen) -> [MapDotSpot] {
        let ranges = stationRanges
        let diameter = CGFloat(MapDotSize.fixedDiameter(StationDot.nearbyRadius)) + 4
        return dotLists(ranges).all.compactMap { s in
            guard ranges[s.id] != nil, let p = screen.point(Coordinate(latitude: s.lat, longitude: s.lon)) else { return nil }
            return MapDotSpot(id: s.id, center: p, diameter: diameter)
        }
    }

    private func labelSpots(_ screen: MapScreen, size: CGSize, stars: [FavoriteStarSpot]) -> [WalkLabelSpot] {
        let stations = labelStations
        guard showsRange, !stations.isEmpty, size.width > 40, size.height > 40 else { return [] }
        // None when zoomed out so far that the range is small on screen (Whole Map, Service Area)
        let mpp = screen.metersPerPoint
        let range = transit.effectiveSettings.sanitized()
        guard mpp > 0, MapLabelLayout.showsLabels(rangeRadius: range.extendedRangeRadiusMeters / mpp) else { return [] }
        func point(_ c: Coordinate) -> CGPoint? { screen.point(c) }
        func box(around p: CGPoint, width: Double, height: Double, up: Double) -> MapLabelLayout.Box {
            MapLabelLayout.Box(x: Double(p.x) - width / 2, y: Double(p.y) - height / 2 - up, width: width, height: height)
        }
        // Where the dots are: this map's own place for each station, which can be a little apart from the timetable's stop (as at
        // Penn Station), so the labels stand beside the dots you see
        let drawn = drawnStations
        func dotCoordinate(_ s: Station) -> Coordinate {
            drawn[s.id].map { Coordinate(latitude: $0.lat, longitude: $0.lon) } ?? s.coordinate
        }
        // The station a label stands beside: the complex's nearest one that has a dot on this map
        func anchor(_ b: BoardStation) -> Station? {
            b.stations.first { drawn[$0.id] != nil } ?? b.stations.first
        }
        // The dots of the stations in range, by the label they belong to: a label doesn't cover another station in range
        let dot = max(10, MapDotSize.diameter(StationDot.nearbyRadius, metersPerPoint: mpp) + 4)
        var dots: [String: [MapLabelLayout.Box]] = [:]
        for b in board.stations {
            dots[b.id] = b.stations.map(dotCoordinate).compactMap(point).map { box(around: $0, width: dot, height: dot, up: 0) }
        }
        // Keep clear of the buttons, legend and card; where you are (the dot, or the pin standing above its point); the selected
        // station's marker; the favorites' stars; and the map's zoom buttons and compass in the bottom corner
        var clear = overlayFrames.map {
            MapLabelLayout.Box(x: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height))
        }
        if let origin = transit.origin, let p = point(origin.coordinate) {
            clear.append(box(around: p, width: 32, height: 60, up: 14))
        }
        if let s = selected, let p = point(Coordinate(latitude: s.lat, longitude: s.lon)) {
            clear.append(box(around: p, width: 18, height: 18, up: 0))
        }
        clear += stars.map {
            MapLabelLayout.Box(x: Double($0.frame.minX), y: Double($0.frame.minY), width: Double($0.frame.width), height: Double($0.frame.height))
        }
        // The compass and + − in the bottom corner (MapCornerControls; which corner follows the language)
        let rightToLeft = layoutDirection == .rightToLeft
        let corner = MapCornerControls.room(layoutDirection)
        clear.append(MapLabelLayout.Box(x: rightToLeft ? 0 : Double(size.width - corner.width), y: Double(size.height - corner.height),
                                        width: Double(corner.width), height: Double(corner.height)))
        // Each label at the complex's nearest station, measured with its fonts
        let l = transit.l10n
        let scale = TextScale.factor
        var items: [MapLabelLayout.Item] = []
        for b in stations {
            guard let first = anchor(b), let p = point(dotCoordinate(first)) else { continue }
            let minutes = l.minutes(b.walk.walkSeconds)
            items.append(MapLabelLayout.Item(id: b.id, x: Double(p.x), y: Double(p.y),
                                             full: WalkTimeLabel.size(minutes: minutes, name: b.name, scale: scale),
                                             compact: WalkTimeLabel.size(minutes: minutes, name: nil, scale: scale)))
        }
        let bounds = MapLabelLayout.Box(x: 4, y: 4, width: Double(size.width) - 8, height: Double(size.height) - 8)
        let placed = MapLabelLayout.place(items, in: bounds, keepClear: clear, dots: dots,
                                          gap: max(12, dot / 2 + 3), rightToLeft: rightToLeft)
        let byID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return placed.compactMap { p in
            guard let b = byID[p.id], let first = anchor(b) else { return nil }
            return WalkLabelSpot(placement: p, name: b.name, minutes: l.minutes(b.walk.walkSeconds), extended: b.range == .extended,
                                 coordinate: dotCoordinate(first), dot: drawn[first.id] ?? dotStation(first))
        }
    }

    /// The station dots this map draws, by station ID. The bus map draws the stops of the station list where they are, so none here
    var drawnStations: [String: SubwayMap.Station] {
        dotLists(stationRanges).baseByID
    }

    /// The dots this map draws (StationDotLists): its own stations and the gray ones without times, or on the bus map the stops
    /// of the station list. Kept in `sight` from one redraw to the next, and made again only when the stations, the ones in
    /// range or the way they're drawn change, so drawing the view again doesn't compare hundreds of stations one by one
    func dotLists(_ ranges: [String: SearchRange]) -> StationDotLists {
        sight.dots.update(base: bus ? [] : model.map?.stations ?? [], extra: bus ? busStops : noTimesDots,
                          inRange: Set(ranges.keys), fixed: dotsFixed)
        return sight.dots
    }

    /// The station's dot on this map: clicking its label is the same as clicking it
    func dotStation(_ s: Station) -> SubwayMap.Station {
        model.map?.stations.first { $0.id == s.id }
            ?? SubwayMap.Station(id: s.id, name: s.name, lat: s.coordinate.latitude, lon: s.coordinate.longitude)
    }
}
