import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

/// The trip planner, in its own window (PlannerWindowView; opened from the top of the main window's sidebar or the View menu): search a place,
/// pick a departure time and how far to walk, and see whether you can catch the trains near there.
/// The main view still uses your current location; nothing here changes it.
///
/// Laid out unlike the main window and the place picker, so the windows aren't taken for one another: one row of controls at the top
/// (two or three when it doesn't fit), then every station within the walk as a card, each direction a row of small blocks (PlannerChip).
/// A wide window has a map column beside the cards (PlannerMapView): selecting a station on either side marks it on both, and
/// Open Larger Map shows a large map in its place, where a click drops a pin that Use This Place makes the place. Narrower than
/// PlannerMapFrame.collapseBelow, the column is folded away.
struct PlannerView: View {
    @EnvironmentObject var transit: TransitModel
    @ObservedObject var planner: PlannerModel
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettings
    /// When the trip planner opens, focus goes straight to the search field so you can type right away.
    @FocusState var searchFocused: Bool
    /// The departure time's popover: quick choices, a calendar and the time
    @State var choosingTime = false
    /// Escape, or a click on the results, closed the suggestion list; editing the text shows it again
    @State var listClosed = false
    /// The suggestion lit up, by its place in the list (suggestionPicks): moved with ↓ / ↑, or the one under the mouse; Return picks
    /// it. Typing clears it
    @State var highlighted: Int?
    /// The ★ button's popover: the first favorites, the newest recent places, and All Places and Map
    @State var placesOpen = false
    @State var placesHeight: CGFloat = 0
    /// The block the mouse is on, for its hover text (PlannerTipLayer). Kept here but not watched (State, not StateObject): only the
    /// blocks and the text redraw when the mouse moves on, not the whole window
    @State var hover = PlannerHover()
    /// A block that shows its hover text as if the mouse were on it (PlannerTipSample); nil: none
    @State var tipSample: PlannerTipSample?
    // Measured sizes (stored only when they really change, see changed): the room for the controls and their parts (how many rows,
    // see controlRows), the place field (the suggestion list is at least as wide), the results (how many blocks fit, how tall the
    // list may be), the list's contents, and one block (see chipSample)
    @State var controlsWidth: CGFloat = 0
    @State var mapButtonWidth: CGFloat = 0
    @State var leavePartWidth: CGFloat = 0
    @State var rangePartWidth: CGFloat = 0
    @State var clockWidth: CGFloat = 0
    @State var fieldWidth: CGFloat = 0
    @State var fieldHeight: CGFloat = 0
    @State var resultsWidth: CGFloat = 0
    @State var resultsHeight: CGFloat = 0
    @State var listHeight: CGFloat = 0
    @State var chipWidth: CGFloat = 0
    /// The window's content width: whether there's room for the map column, and how wide it is (PlannerMapFrame)
    @State var windowWidth: CGFloat = 0
    /// The station selected in the list or on the map (its card's ID): marked on both, with a dotted line to it on the map
    @State var selectedStation: String?
    /// Counts selections made on the map: the list then scrolls to that station's card
    @State var mapSelections = 0
    /// The large map is shown in place of the list and the map column (Open Larger Map, until Back or Use This Place)
    @State var largeMap = false
    /// The pin clicked on the large map, not used yet: only Use This Place makes it the place (nothing is computed for it before)
    @State var pendingPin: Coordinate?
    /// Demo mode: the large map was clicked outside Manhattan, where it has no times (said at the top until the next click)
    @State var demoOutside = false
    /// The column's map and the large map, once made, are kept (hidden while not in use): see mainArea
    @State var smallMapMade = false
    @State var largeMapMade = false

    /// The place field on one row: from its narrowest to its usual width (the room left over is before the clock)
    static let fieldMin: CGFloat = 180
    static let fieldUsual: CGFloat = 330
    static let controlSpacing: CGFloat = 8

    /// Plan a Trip's text: times in its place's metro area's time zone, each naming it where this Mac's clock reads differently;
    /// outside the service area this Mac's; with no place yet, the main window's
    private var plannerText: UIText {
        let l = transit.l10n
        guard planner.place != nil else { return l }
        return planner.placeArea.map { l.inTimeZone($0.timeZone, area: true) } ?? l.inTimeZone(l.macZone, area: false)
    }

    var body: some View {
        let l = plannerText
        // From the leading edge: should a part ever be wider than the window, only its own end is cut off, nothing else moves over
        VStack(alignment: .leading, spacing: 0) {
            controls(l)
                // Above the results: the suggestion list hangs over them
                .zIndex(1)
            Divider()
            mainArea(l)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if changed(resultsHeight, h) { resultsHeight = h }
                }
                // A click on the results closes the suggestion list hanging over them, as Escape does (the clicks still reach them)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    if showsList { listClosed = true }
                })
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if changed(windowWidth, w) { windowWidth = w }
        }
        // No room for the map column, or no map (networking turned off): back from the large map, the pin not used. The maps are
        // taken away then, and made again only when they're needed again (not at once, hidden, as the window widens)
        .onChange(of: showsMapColumn) { _, shows in
            if !shows { closeLargeMap(); forgetMaps() }
        }
        .onChange(of: transit.networkAllowed) { _, allowed in
            if !allowed { closeLargeMap(); forgetMaps() }
        }
        // A place chosen another way (the field, the place picker): a pin left on the large map is dropped
        .onChange(of: planner.place?.coordinate) { _, _ in
            pendingPin = nil
            demoOutside = false
        }
        // The text of the block the mouse is on, over everything in the window (PlannerTipSource marks the block)
        .overlayPreferenceValue(PlannerTipAnchor.self) { anchor in
            PlannerTipLayer(hover: hover, anchor: anchor)
        }
        .modifier(PlannerSampleHook(choosingTime: $choosingTime, placesOpen: $placesOpen, tipSample: $tipSample, largeMap: $largeMap,
                                     pendingPin: $pendingPin, setText: { text in
                                         planner.query = text
                                         listClosed = false
                                     }))
        .onChange(of: tipSample) { _, sample in
            if sample == nil { hover.clear() }
        }
        .onAppear {
            // A departure time left in the past (the window stayed open) starts again from the default
            planner.refreshLeaveTimeIfPast()
            // Demo mode turned on or off while the trip planner was closed: its place and search are cleared (see PlannerModel.setDemo)
            planner.setDemo(transit.isDemo)
            // Start over a computation that closing the trip planner stopped
            planner.resume(transit: transit)
            takePick()
            if planner.place == nil { searchFocused = true }
            // A screen reader taken into this window as it first opens doesn't find the place field's group (see the function)
            askScreenReadersToLookAgainSoon()
        }
        // A place for the trip planner was picked in the place picker window
        .onChange(of: transit.plannerPick) { _, _ in takePick() }
        // The search is stopped when the window closes (CatchMyTrainApp, outside the window's .id), not here: a new Text size
        // replaces these contents while the window stays open
        .onDisappear { hover.clear() }
        // Subway / bus switched next to the title: search again with the new transit system
        .onChange(of: transit.system) { _, _ in planner.update(transit: transit) }
        // Start or standby: search again, online or with only what's on this Mac (standby stops the search in progress, so it uses no network)
        .onChange(of: transit.isActive) { _, _ in planner.update(transit: transit) }
        // Demo mode turned on or off: the place and the search text are cleared, so the two never mix (see PlannerModel.setDemo)
        .onChange(of: transit.isDemo) { _, demo in planner.setDemo(demo) }
        // Clicking into the field again after Escape closed the list shows it again
        .onChange(of: searchFocused) { _, focused in
            if focused { listClosed = false }
        }
        // Editing the search text drops a pending lookup: start the computation that closing the trip planner stopped meanwhile (see resume).
        // It also shows the suggestion list again after Escape closed it
        .onChange(of: planner.query) { _, _ in
            listClosed = false
            highlighted = nil
            planner.resume(transit: transit)
        }
        // Wait about 1 second after the user stops changing the time before searching
        .onChange(of: planner.leaveAt) { _, _ in planner.update(transit: transit, delay: 1) }
        .onChange(of: planner.windowSeconds) { _, _ in planner.update(transit: transit) }
        .onChange(of: planner.walkMinutes) { _, _ in planner.update(transit: transit) }
        // Live times get old while the window stays open: fetched again on the refresh interval while it can be seen and the app is
        // started (see PlannerModel.refreshLive); nothing on standby
        .task(id: transit.isActive) { await refreshLiveTimes() }
    }

    /// See the .task above: runs while started, until the app goes on standby or the window closes
    private func refreshLiveTimes() async {
        guard transit.isActive else { return }
        while !Task.isCancelled {
            let seconds: TimeInterval = max(60, transit.refreshInterval)
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            if Self.plannerWindowVisible() { planner.refreshLive(transit: transit) }
        }
    }

    /// Whether the trip planner's window can be seen now (not hidden behind others, minimized or on another Space)
    private static func plannerWindowVisible() -> Bool {
        for window in NSApp.windows {
            guard let id = window.identifier?.rawValue, id.hasPrefix(PlannerWindow.id) else { continue }
            return window.occlusionState.contains(NSWindow.OcclusionState.visible)
        }
        return false
    }

    /// A measured size worth storing: one redraw less for changes under half a point
    func changed(_ old: CGFloat, _ new: CGFloat) -> Bool { abs(old - new) > 0.5 }
}

/// Leaves the view as it is
private struct PlannerSampleHook: ViewModifier {
    @Binding var choosingTime: Bool
    @Binding var placesOpen: Bool
    @Binding var tipSample: PlannerTipSample?
    @Binding var largeMap: Bool
    @Binding var pendingPin: Coordinate?
    /// Sets the place field's text
    let setText: (String) -> Void
    @State private var typed = false

    func body(content: Content) -> some View {
        content
    }

}

