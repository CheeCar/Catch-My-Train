import AppKit
import CatchText
import Combine
import MapKit
import SwiftUI
import TransitCore

extension PlannerView {
    // MARK: Map column and large map

    var showsMapColumn: Bool {
        PlannerMapFrame.showsColumn(windowWidth: Double(windowWidth))
    }

    /// The large map is shown in place of the list and the map column (Open Larger Map, until Back or Use This Place)
    var showsLargeMap: Bool {
        showsMapColumn && largeMap && transit.networkAllowed
    }

    /// The list, with the map column beside it when the window is wide enough; or the large map in place of both. The large map is
    /// made the first time it's opened, and from then on hidden rather than taken away, as the list and column are while it shows: a
    /// map view taken away isn't always let go of. Two maps, each kept at its own size (not one map made larger): this map asks
    /// MapKit where things are, and asking a map just made larger is what made the transit map hang
    @ViewBuilder
    func mainArea(_ l: UIText) -> some View {
        let large = showsLargeMap
        ZStack {
            Group {
                if showsMapColumn {
                    HStack(spacing: 0) {
                        resultsArea(l)
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        mapColumn(l, shown: !large)
                            .frame(width: CGFloat(PlannerMapFrame.columnWidth(windowWidth: Double(windowWidth))))
                    }
                } else {
                    resultsArea(l)
                }
            }
            .keptHidden(large)
            // Networking turned off in Settings: taken away (Apple Maps mustn't load anything then)
            if showsMapColumn, transit.networkAllowed, large || largeMapMade {
                largeMapArea(l, place: planner.place, shown: large)
                    .keptHidden(!large)
                    .onAppear { largeMapMade = true }
            }
        }
    }

    /// The stations the map shows: the list's, none while computing (a new search's stations have no walks yet)
    private func mapStations() -> [BoardStation] {
        guard planner.shownStatus != .loading else { return [] }
        return planner.board(transit: transit)?.stations ?? []
    }

    /// A selection made on the map: the list scrolls to its card
    private var mapSelection: Binding<String?> {
        Binding(get: { selectedStation }, set: {
            selectedStation = $0
            mapSelections &+= 1
        })
    }

    /// The small map beside the list, Open Larger Map under it. No place yet: the map's place is left blank, and Open Larger Map opens
    /// the large map where the main window walks from, to click a place (rather than grayed out without saying why). The map is made
    /// with the first place and kept: with no place again (cleared, or Demo mode turned on or off) it's hidden under the blank rather
    /// than taken away. Networking turned off in Settings: the sentence the other maps show, and Open Larger Map grayed out (the
    /// sentence says why)
    private func mapColumn(_ l: UIText, shown: Bool) -> some View {
        let stations = mapStations()
        let place = planner.place
        return VStack(spacing: 0) {
            if !transit.networkAllowed {
                NetworkOffNote(l: l, large: true)
            } else if place != nil || smallMapMade {
                // Hidden in a stack of its own, as the large map is (largeMapArea): hidden right on the map, a screen reader still
                // found its buttons and area names
                VStack(spacing: 0) {
                    PlannerMapView(l: l, large: false, place: place, stations: stations, settings: planner.walkSettings(transit),
                                   selected: mapSelection, shown: shown && place != nil)
                }
                .smallMapGroup()
                .keptHidden(place == nil)
                .background {
                    if place == nil { Color(nsColor: .underPageBackgroundColor) }
                }
                .onAppear { smallMapMade = true }
            } else {
                Color(nsColor: .underPageBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Button {
                searchFocused = false
                pendingPin = nil
                demoOutside = false
                largeMap = true
            } label: {
                Label(l.t("Open Larger Map"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .lineLimit(TextScale.factor == 1 ? 1 : 2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .appButtonStyle(.bordered)
            .disabled(!transit.networkAllowed)
            .padding(10)
        }
        // The nearest station is selected at first, and again when the one selected is no longer listed
        .onChange(of: stations.map(\.id), initial: true) { _, ids in
            if selectedStation.map({ !ids.contains($0) }) ?? true { selectedStation = ids.first }
        }
    }

    /// The large map in place of the list and the column: at the top what a click does, at the bottom Back and Use This Place
    private func largeMapArea(_ l: UIText, place: PlannerModel.Place?, shown: Bool) -> some View {
        VStack(spacing: 0) {
            PlannerMapView(l: l, large: true, place: place, start: walkingFrom, stations: mapStations(), settings: planner.walkSettings(transit),
                           selected: $selectedStation, shown: shown, pending: pendingPin, onPick: { dropPin($0) })
                .overlay(alignment: .top) {
                    VStack(spacing: 6) {
                        mapNote(l.t("Click the map to choose a place."), icon: nil)
                        if demoOutside {
                            mapNote(l.t("This demo has times only for Manhattan. Click a place in Manhattan."), icon: "exclamationmark.triangle")
                        }
                    }
                    .padding(10)
                }
            Divider()
            HStack(spacing: 10) {
                Button {
                    closeLargeMap()
                } label: {
                    Label(l.t("Back"), systemImage: "chevron.backward")
                }
                .keyboardShortcut(.cancelAction)
                .appButtonStyle()
                Spacer(minLength: 10)
                Button(l.t("Use This Place")) { usePin(l) }
                    .appButtonStyle(.prominent)
                    .keyboardShortcut(searchFocused ? nil : KeyboardShortcut.defaultAction)
                    .disabled(pendingPin == nil)
            }
            .padding(10)
        }
    }

    private func mapNote(_ text: String, icon: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.scaled(.caption))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// A click on the large map: the pin goes there, with the walking circles around it; nothing is computed yet. Demo mode has
    /// times only in Manhattan: a click elsewhere says so and drops nothing
    private func dropPin(_ c: Coordinate) {
        if transit.isDemo, !DemoArea.contains(c) {
            demoOutside = true
            return
        }
        demoOutside = false
        pendingPin = c
    }

    /// Use This Place: the pin becomes the place ("Place on the map", then its address), computed now, and the list comes back
    private func usePin(_ l: UIText) {
        guard let c = pendingPin else { return }
        planner.choose(mapPoint: c, name: l.t("Place on the map"), transit: transit)
        searchFocused = false
        closeLargeMap()
    }

    /// Back to the list: a pin not used is dropped
    func closeLargeMap() {
        largeMap = false
        pendingPin = nil
        demoOutside = false
    }

    /// The maps were taken away (no room for the column, or networking turned off): the column's map is made again with a place,
    /// the large one when it's opened
    func forgetMaps() {
        smallMapMade = false
        largeMapMade = false
    }
}

private extension View {
    /// The small map's stack, made an accessibility element of its own when HiddenMapGroup says so. Decided once at launch, so
    /// the map in it is never made anew for it
    @ViewBuilder
    func smallMapGroup() -> some View {
        if HiddenMapGroup.current == .contain {
            accessibilityElement(children: .contain)
        } else {
            self
        }
    }

    /// A page or map kept but not shown: not seen, not clicked, not reached with the Tab key or a screen reader, and its buttons'
    /// keyboard shortcuts (Return, Esc) don't work. Put on a stack holding the map, not on the map itself. A hidden map is also
    /// given nothing to draw (PlannerMapView, HiddenMapStyle)
    func keptHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .disabled(hidden)
            .accessibilityHidden(hidden)
    }
}
