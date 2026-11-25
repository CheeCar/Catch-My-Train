import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// The map in the place picker: drag and zoom it, click it to drop a pin. It moves to each place selected on the left; Recenter
/// brings it back to the selection (with nothing selected, to where it opened). Like the transit maps, it shows the dashed service
/// area outline. The large one (Open Larger Map) also has the transit map's Whole Map and Service Area buttons, its legend and a scale.
struct PickerMap: View {
    let l: UIText
    let large: Bool
    /// The transit mode in use: Whole Map shows all of its map
    let system: TransitSystem
    /// Where it opens; nil: no location and no place yet, the whole service area
    let start: Coordinate?
    let focus: PickerFocus?
    let selected: Coordinate?
    let marker: PickerMarker?
    /// The line at the top of the map (none for Plan a Trip, whose window says it at the top)
    let hint: String?
    /// How many times the window has been opened: on each open the map goes back to where it opens (the window keeps this map)
    let opened: Int
    let onTap: (Coordinate) -> Void

    @State private var position: MapCameraPosition
    /// Extent for Whole Map: worked out from the map data on the first press, then reused
    @State private var wholeRegion: MKCoordinateRegion?
    /// The map data is being read for the first Whole Map: another press meanwhile doesn't read it again
    @State private var loadingWholeMap = false
    /// That read: stopped when the window opens again
    @State private var wholeMapRead: Task<Void, Never>?
    /// The metro areas whose names fit on the map at its zoom now, and on how many lines (ServiceAreaMap.names): set when the map
    /// stops moving
    @State private var metroNames: [MetroArea: Int] = [:]
    /// Ties Apple's compass and + − in the map's bottom corner to the map (MapCornerControls)
    @Namespace private var mapScope

    init(l: UIText, large: Bool, system: TransitSystem, start: Coordinate?, focus: PickerFocus?, selected: Coordinate?,
         marker: PickerMarker?, hint: String?, opened: Int, onTap: @escaping (Coordinate) -> Void) {
        self.l = l
        self.large = large
        self.system = system
        self.start = start
        self.focus = focus
        self.selected = selected
        self.marker = marker
        self.hint = hint
        self.opened = opened
        self.onTap = onTap
        // At the selection (also one made on the other map, small or large), else where the map last moved to, else where it opens
        _position = State(initialValue: .region(Self.opening(selected ?? focus?.coordinate ?? start, large: large)))
    }

    /// Around a place; with none, the whole service area (Service Area's)
    private static func opening(_ c: Coordinate?, large: Bool) -> MKCoordinateRegion {
        c.map { region(around: $0, large: large) } ?? ServiceAreaMap.region
    }

    /// The streets around a place: about 2 km across on the small map, 3 km on the large one
    private static func region(around c: Coordinate, large: Bool) -> MKCoordinateRegion {
        let span = large ? 0.03 : 0.02
        return MKCoordinateRegion(center: c.clCoordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    var body: some View {
        // The view's width: the metro areas' names are fitted with it (ServiceAreaMap.names)
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $position, scope: mapScope) {
                    // Service area outline, same as on the transit maps: one ring per metro area, with their names where they fit
                    ServiceAreaMap.content(l, names: metroNames)
                    if let marker {
                        if let name = marker.name {
                            Marker(name, coordinate: marker.coordinate.clCoordinate)
                        } else if marker.live {
                            // May turn on Location Services, so only while the app is running (see mapMarker)
                            UserAnnotation()
                        } else {
                            Marker(l.t("Current location"), systemImage: "location", coordinate: marker.coordinate.clCoordinate)
                        }
                    }
                }
                // Only the scale is placed by MapKit, on the large map only (the small one has little room): the compass and + − are
                // placed by the app (MapCornerControls)
                .mapControls {
                    MapScaleView()
                        .mapControlVisibility(large ? .automatic : .hidden)
                }
                .onTapGesture { point in
                    guard let c = proxy.convert(point, from: .local) else { return }
                    onTap(Coordinate(latitude: c.latitude, longitude: c.longitude))
                }
                // Slow down mouse wheel zoom (the wheel is too sensitive when picking a place)
                .gentleWheelZoom($position)
                .onMapCameraChange(frequency: .onEnd) { context in
                    let names = ServiceAreaMap.names(context.rect, width: geo.size.width, l: l)
                    if names != metroNames { metroNames = names }
                }
            }
        }
        // Along the top: the line saying what a click does, and across from it Recenter (on the large map the transit map's buttons and
        // legend); they swap sides in a right-to-left language. In the bottom corners MapKit's logo and Legal, and Apple's compass and
        // + − (MapCornerControls); which is which follows the language
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                if let hint {
                    Text(hint)
                        .font(.scaled(.caption))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        // Solid, like the panel of the map's buttons (MapPanel): the map's place names showed through a see-through one
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OutlineColor(), lineWidth: 0.5))
                        .allowsHitTesting(false)
                        // On the large map: in line with the buttons across from it, and not squeezed into a narrow column by them
                        .padding(large ? 10 : 0)
                        .frame(minWidth: large ? 160 : nil, alignment: .leading)
                }
                Spacer(minLength: 0)
                if large {
                    // The legend under the buttons, from the same edge, on one panel
                    VStack(alignment: .leading, spacing: 0) {
                        MapCameraButtons(l: l, recenter: recenter, wholeMap: showWholeMap,
                                         serviceArea: { position = .region(ServiceAreaMap.region) })
                        ServiceAreaLegend(l: l)
                    }
                    .mapPanel()
                    .layoutPriority(1)
                } else {
                    Button {
                        withAnimation(Motion.ease(0.4)) { recenter() }
                    } label: {
                        Label(l.t("Recenter"), systemImage: "location")
                    }
                    .appButtonStyle(.bordered)
                    .controlSize(.small)
                    // On one line, as wide as its words: the line beside it wraps instead (German at larger text broke the word)
                    .fixedSize()
                    .help(l.t("Recenter"))
                }
            }
            .padding(large ? 0 : 8)
        }
        .overlay(alignment: .bottomTrailing) {
            MapCornerControls(scope: mapScope)
        }
        // The compass and + − above work this map (Map(scope:))
        .mapScope(mapScope)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: large ? 200 : 150)
        .onChange(of: focus) { _, new in
            guard let new else { return }
            withAnimation(Motion.ease(0.4)) { position = .region(Self.region(around: new.coordinate, large: large)) }
        }
        // Opened again, as a new map would: where this purpose's map opens (nothing is selected yet; a place selected as it opens
        // moves the map there, onChange of focus), and Whole Map worked out again (the transit mode may have changed)
        .onChange(of: opened) { _, _ in
            wholeMapRead?.cancel()
            wholeMapRead = nil
            loadingWholeMap = false
            wholeRegion = nil
            position = .region(Self.opening(start, large: large))
        }
        // The two columns' map grown into the large one, or back: the same map, moved where a new one would open (the selection,
        // else where the map last moved to, else where it opens; streets about 3 km across on the large one, 2 km on the small)
        .onChange(of: large) { _, new in
            position = .region(Self.opening(selected ?? focus?.coordinate ?? start, large: new))
        }
        // The transit mode changed while open (in the main window): Whole Map is the new mode's, worked out again on the next press
        .onChange(of: system) { _, _ in
            wholeMapRead?.cancel()
            wholeMapRead = nil
            loadingWholeMap = false
            wholeRegion = nil
        }
    }

    /// Back to the selection; with nothing selected, to where the map opened
    private func recenter() {
        position = .region(Self.opening(selected ?? start, large: large))
    }

    /// Whole Map: the same as this mode's map window (its map data read from disk only on the first press, not kept afterwards;
    /// a press while it is still being read does nothing more, the map moves once it's read)
    private func showWholeMap() {
        if let wholeRegion {
            position = .region(wholeRegion)
            return
        }
        guard !loadingWholeMap else { return }
        loadingWholeMap = true
        let kind = SubwayMapStore.Kind(system)
        let system = system
        // The metro area of the place it opened at (or the one chosen), as the transit map uses the starting point's; outside them
        // all the nearest one
        let area = (selected ?? start).flatMap { MetroArea.nearest(to: $0) }
        wholeMapRead = Task { @MainActor in
            let map = await SubwayMapModel.loadAll(kind)
            // The window opened again meanwhile: this was for the time before
            guard !Task.isCancelled else { return }
            let region = ServiceAreaMap.wholeRegion(map, system: system, area: area)
            wholeRegion = region
            loadingWholeMap = false
            wholeMapRead = nil
            withAnimation(Motion.ease(0.4)) { position = .region(region) }
        }
    }
}

/// Slow down mouse wheel zoom on the map: by default one wheel notch zooms too much.
/// Only handles the mouse wheel; trackpad two-finger scrolling (panning) and pinching are still handled by the system.
struct GentleWheelZoom: ViewModifier {
    @Binding var position: MapCameraPosition
    /// Called while the map moves (the map follows its moves here; with a second onMapCameraChange(frequency: .continuous) on the
    /// same map, only one of the two was called)
    var onMove: (() -> Void)? = nil
    @State private var state = WheelZoomState()
    /// Off while the map is kept hidden (Plan a Trip's map not in use is disabled): the wheel then scrolls what's shown, even with
    /// the mouse still where the hidden map is
    @Environment(\.isEnabled) private var isEnabled

    /// Zoom factor per wheel notch (closer to 1 is slower)
    static let stepFactor = 1.18

    func body(content: Content) -> some View {
        content
            .onMapCameraChange(frequency: .continuous) { context in
                state.camera = context.camera
                onMove?()
            }
            .onHover { state.hovering = $0 }
            .onChange(of: isEnabled, initial: true) { _, enabled in state.enabled = enabled }
            .onAppear {
                guard state.monitor == nil else { return }
                let box = state
                let binding = $position
                box.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    // Ignore trackpads (precise scrolling); also ignore when the mouse isn't over this map
                    guard box.enabled, box.hovering, !event.hasPreciseScrollingDeltas, let camera = box.camera,
                          event.scrollingDeltaY != 0 else { return event }
                    let steps = max(-3, min(3, Double(event.scrollingDeltaY)))
                    let distance = min(max(camera.distance * pow(Self.stepFactor, -steps), 150), 3_000_000)
                    binding.wrappedValue = .camera(MapCamera(centerCoordinate: camera.centerCoordinate, distance: distance,
                                                             heading: camera.heading, pitch: camera.pitch))
                    return nil
                }
            }
            .onDisappear {
                if let m = state.monitor { NSEvent.removeMonitor(m) }
                state.monitor = nil
            }
    }
}

/// Latest state the wheel monitor reads (kept in an object so the monitor closure always reads the current value)
final class WheelZoomState {
    var camera: MapCamera?
    var hovering = false
    /// The map can be used (not kept hidden)
    var enabled = true
    var monitor: Any?
}

extension View {
    func gentleWheelZoom(_ position: Binding<MapCameraPosition>, onMove: (() -> Void)? = nil) -> some View {
        modifier(GentleWheelZoom(position: position, onMove: onMove))
    }
}
