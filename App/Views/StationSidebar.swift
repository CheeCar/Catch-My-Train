import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

// MARK: - Left side: nearby stations

struct StationSidebar: View {
    /// Name of the map item (shared by the sidebar and the menu bar at the top of the screen).
    static func mapName(_ system: TransitSystem, _ l: UIText) -> String {
        l.pick(system, train: l.t("Subway map"), bus: l.t("Bus map"), ferry: l.t("Ferry map"), rail: l.t("Train map"))
    }

    @EnvironmentObject var transit: TransitModel
    @Environment(\.openWindow) private var openWindow
    var board: NearbyBoard
    @Binding var showPlacePicker: Bool
    /// The list has keyboard focus: its selected row is blue (gray without focus)
    @FocusState private var listFocused: Bool

    static let standbyTag = "__standby"
    /// The narrowest the sidebar can be dragged (NearbyView)
    static let minWidth: CGFloat = 220

    var body: some View {
        let l = transit.l10n
        List(selection: Binding<String?>.afterViewUpdate(
            get: {
                if !transit.isActive { return Self.standbyTag }
                return transit.selection.station(in: board)?.id
            },
            set: { tag in
                // List selection is reported by AppKit in the middle of a view update, so use afterViewUpdate.
                // Animate the switch a little (the right side fades and slides in gently) instead of jumping.
                // No station (a click beside the rows, or the standby row): the selection stays as it is
                guard let tag, tag != Self.standbyTag else { return }
                withAnimation(Motion.ease(0.25)) { transit.selectStation(tag) }
            }
        )) {
            // The mode's name and the line under it, made a new row whenever their words change: the line takes up to four lines
            // in a narrow sidebar with larger text or a long translation, and a list row's height doesn't follow its content
            ForEach([ModeHeader.words(of: transit)], id: \.self) { _ in
                ModeHeader()
                    .selectionDisabled()
            }

            // Each opens its own window, or brings it to the front: buttons, not selectable rows. Side by side, the same width, when
            // both fit; one above the other when they don't (narrow sidebar, larger text, long translations). One list row: a list row's
            // height doesn't follow its content, but this one's content only changes with the sidebar's width, which the list measures
            SidebarWindowButtons(
                planner: SidebarWindowRow(title: l.t("Plan a Trip"), systemImage: "magnifyingglass") {
                    PlannerWindow.open(with: openWindow)
                },
                map: SidebarWindowRow(title: Self.mapName(transit.system, l), systemImage: "map") {
                    MapWindow.open(with: openWindow)
                })
            .selectionDisabled()

            // Walking origin: My current location / A place I choose (same toggle as in Settings).
            // Choosing "A place I choose" opens the place picker window right away.
            // Demo mode has its own (Times Square as the current location, places chosen in Manhattan), kept in memory only: turning
            // it off returns to the user's own choice.
            // A new row whenever its words change: they decide whether the two segments fit side by side or go one above the other,
            // and a list row's height doesn't follow its content. Not when the choice changes: a segment is as wide whichever is chosen
            let currentOff = !transit.locationAllowed && !transit.isDemo
            ForEach([LocationModeSwitch.words(l, currentOff: currentOff)], id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    // A custom two-segment toggle instead of the system segmented control: the system one sizes to the full text width and won't shrink,
                    // so longer translations such as Italian push the whole sidebar out of the window, clipping the left side.
                    LocationModeSwitch(selection: transit.locationMode, l: l, currentOff: currentOff) { mode in
                        // Open the place picker automatically only if no place has been picked yet; otherwise use the last place.
                        // If none picked yet, don't switch until one is chosen; Cancel stays in the previous mode instead of using the built-in default place
                        transit.requestLocationMode(mode) { showPlacePicker = true }
                    }
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            // The place in use: its own row in the sidebar list, present in both modes ("My current location" shows the place too, like
            // "A place I choose"). One line, or more when the name and the button don't fit side by side (the name itself on two at
            // most), and one more saying how approximate the current position is when it is (LocationPlaceRow). A list row's
            // height doesn't follow a change of its content, so the row is a new one whenever its text changes and the list measures it again
            ForEach([LocationPlaceRow.content(of: transit)], id: \.self) { _ in
                LocationPlaceRow(showPlacePicker: $showPlacePicker)
                    .selectionDisabled()
            }
            // Location-off notice: add a whole row when needed instead of adding content to the row above (its height wouldn't follow, and text would overlap)
            if !transit.isDemo, transit.locationAccessOff, transit.locationMode == .current {
                LocationAccessNotice(compact: true)
                    .selectionDisabled()
            }
            // The commute presets, a click switching the place and the mode together: a row of its own, only while there are some
            PresetSidebarRow(presets: transit.presetCenter)

            if transit.isActive {
                // The range legend sits above the station list so it's visible at a glance. Its own row, made new when its words
                // change: it takes more lines when its pieces don't all fit on one (a list row's height doesn't follow its content)
                ForEach([RangeLegend.words(of: transit)], id: \.self) { _ in
                    RangeLegend()
                        .selectionDisabled()
                }
                Section(l.pick(transit.system, train: l.t("Nearby stations"), bus: l.t("Nearby bus stops"), ferry: l.t("Nearby piers"))) {
                    // New rows whenever the order or the set of stations changes, so the table never moves rows (see SidebarStationRow).
                    // Tagged with the plain station ID: the list looks for tags of its selection's value type (String), not optional ones
                    let shownID = transit.selection.station(in: board)?.id
                    ForEach(SidebarStationRow.rows(board.stations, byDirection: transit.system.mode == .subway)) { row in
                        StationListRow(station: row.station, l: l, selected: row.station.id == shownID)
                            .tag(row.station.id)
                    }
                    // Nothing nearby: a sentence saying why, instead of an empty space (the page on the right has the buttons).
                    // Its own row, made new when its text changes (a row's height doesn't follow its content). Its own line limit:
                    // the sidebar's rows keep text to one line unless told otherwise, and the sentence was cut off after a few words
                    if board.stations.isEmpty, !transit.isLocating {
                        ForEach([transit.emptyStateText(short: true)], id: \.self) { text in
                            Text(text)
                                .font(.scaled(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(SidebarText.sentenceLines)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 4)
                                .selectionDisabled()
                        }
                    }
                }
            } else {
                // In standby this row replaces the station list, selected like the station the right side shows.
                // A plain String tag, like the station rows: the list only matches tags of its selection's value type, not optional ones
                Label(l.t("Standby"), systemImage: "moon.zzz")
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.white)
                    .modifier(SidebarCard(selected: true))
                    .padding(.vertical, 2)
                    .tag(Self.standbyTag)
            }
        }
        .listStyle(.sidebar)
        // When the list gets shorter while scrolled down, don't leave it scrolled past its end (SidebarScrollClamp)
        .background(SidebarScrollClamp())
        .focused($listFocused)
        // The keyboard starts in the list, so its selected row is blue: with every control taking the keyboard (as with a screen
        // reader) it started on the station page's Directions button, where Return opens the map
        .defaultFocus($listFocused, true)
        .onAppear { listFocused = true }
        // Start and standby swap the standby row and the station rows: the row that had the keyboard is gone, and the keyboard
        // would go on to the toolbar's first button. It stays in the list
        .onChange(of: transit.isActive) { _, _ in listFocused = true }
        // "Show trains" in the map window: the main window comes to the front with that station selected, and the list takes the
        // keyboard focus so the selected row is blue, not gray
        .onChange(of: transit.cardBounce) { _, request in
            if request != nil { listFocused = true }
        }
        // A bar at the bottom only when there is something to say; otherwise the list reaches the bottom of the window
        .modifier(SidebarNoticeBarPlacement())
    }
}

/// "Plan a Trip" and the transit map at the top of the sidebar: a click opens its own window, or brings it to the front.
/// The icon at the end shows that a window opens; light gray on hover, like the sidebar header. Never selected: the right side of the
/// main window stays on the station page.
struct SidebarWindowRow: View {
    let title: String
    let systemImage: String
    let open: () -> Void
    @State private var hovering = false

    /// The title's words one per line: as wide as its longest word, which the button measures to see whether its arrow still fits
    static func wordLines(_ title: String) -> String {
        title.split(separator: " ").joined(separator: "\n")
    }

    private func label(_ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.scaled(.body).weight(.semibold))
            .foregroundStyle(Color.primary)
            .tint(Color.accentColor)
    }

    private func row(arrow: Bool) -> some View {
        HStack(spacing: 6) {
            label(title)
                .lineLimit(2)
            Spacer(minLength: 4)
            if arrow {
                Image(systemName: "arrow.up.forward.app")
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        Button(action: open) {
            // The arrow at the end says the button opens a window. When the title's longest word with the icon and the arrow is
            // wider than the button (the narrowest sidebar with larger text, a long word), the arrow is left out rather than the
            // word broken; decided while laid out, from a hidden copy with the words one per line. The outer hidden copy (the
            // whole title on one line) is the button's ideal width, which decides whether the two buttons go side by side
            IdealWidthFromSecond {
                ViewThatFits(in: .horizontal) {
                    IdealWidthFromSecond {
                        row(arrow: true)
                        HStack(spacing: 6) {
                            label(Self.wordLines(title))
                            Color.clear.frame(width: 4, height: 0)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.scaled(.caption))
                        }
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                    }
                    row(arrow: false)
                }
                row(arrow: true)
                    .fixedSize()
                    .hidden()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            .contrastBorder(cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// The Plan a Trip and map buttons at the top of the sidebar: side by side and the same width when both fit at the width of the wider
/// one, otherwise one above the other at full width (SidebarWindowPairLayout).
struct SidebarWindowButtons: View {
    var planner: SidebarWindowRow
    var map: SidebarWindowRow

    var body: some View {
        SidebarWindowPairLayout(spacing: 6) {
            planner
            map
        }
        .padding(.vertical, 2)
    }
}

/// Two views side by side, each as wide as half the space, when the wider one's ideal width fits in that half; otherwise stacked, each
/// at the full width. The choice depends only on the width offered and the two views' ideal widths, so it's the same each time.
/// Views whose text shrinks a little before it is truncated (the Walk from switch's segments) say how far (`shrink`) and how much
/// of their width doesn't shrink with it (`inset`, their padding): they fit their halves when their text does, shrunk that far
struct SidebarWindowPairLayout: Layout {
    var spacing: CGFloat
    /// The least scale the views' text shrinks to before it is truncated (1: it doesn't shrink)
    var shrink: CGFloat = 1
    /// The part of each view's width that doesn't shrink with its text
    var inset: CGFloat = 0

    static func sideBySide(width: CGFloat, ideals: [CGFloat], spacing: CGFloat, shrink: CGFloat = 1, inset: CGFloat = 0) -> Bool {
        guard let widest = ideals.max() else { return true }
        // The least the widest one can take: its text shrunk as far as it goes, the rest as it is
        let least = max(0, widest - inset) * shrink + inset
        return least * CGFloat(ideals.count) + spacing * CGFloat(max(0, ideals.count - 1)) <= width
    }

    private func ideals(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = ideals(subviews)
        let width = proposal.width ?? (ideal.max() ?? 0) * CGFloat(subviews.count) + spacing
        if Self.sideBySide(width: width, ideals: ideal, spacing: spacing, shrink: shrink, inset: inset) {
            let half = (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(max(1, subviews.count))
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: half, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = ideals(subviews)
        if Self.sideBySide(width: bounds.width, ideals: ideal, spacing: spacing, shrink: shrink, inset: inset) {
            let half = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(max(1, subviews.count))
            let height = bounds.height
            // Leading to trailing: placing at minX in a right-to-left layout is mirrored by the system
            for (i, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (half + spacing), y: bounds.minY),
                           proposal: ProposedViewSize(width: half, height: height))
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let h = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}

/// The bar at the bottom of the sidebar, only when there is something to say: a new version is available, location failed and a
/// fallback place is in use, or Demo mode is on. The place itself, with its Change or Choose a New Place button, is in the
/// place row at the top of the sidebar. With nothing to say there is no bar, so the list reaches the bottom of the window and its
/// last row isn't covered.
struct SidebarNoticeBar: View {
    @EnvironmentObject var transit: TransitModel

    var body: some View {
        let l = transit.l10n
        let note = footerNote(l)
        if note != nil || transit.availableUpdate != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                // When a new version is available (auto check or Check in Settings)
                UpdateAvailableLink()
                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: note.icon)
                            .accessibilityHidden(true)
                        Text(note.text)
                            .foregroundStyle(note.warning ? Color.noticeOrange : Color.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            // The bar must not be wider than the sidebar: if it is, the whole sidebar gets pushed left out of the window
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .font(.scaled(.caption))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .modifier(NoticeBarBackground())
        }
    }
}

/// Where the notice bar goes: at the bottom of the list. From macOS 26 as a bar of the list (safeAreaBar), so the list blurs what
/// scrolls under it (NoticeBarBackground); up to macOS 15 as an inset with a background of its own
private struct SidebarNoticeBarPlacement: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.safeAreaBar(edge: .bottom) { SidebarNoticeBar() }
        } else {
            content.safeAreaInset(edge: .bottom) { SidebarNoticeBar() }
        }
    }
}

/// The notice bar's background. Up to macOS 15 a bar's own background, as the sidebar reaches the window's edges there. From macOS 26
/// the sidebar floats with rounded corners and the list blurs what scrolls under the bar by itself: a background of its own would
/// stick out past those corners, so there is none
private struct NoticeBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.background(.bar)
        }
    }
}

extension SidebarNoticeBar {
    /// Notes for the bar: only for a fallback place after location failed, and Demo mode, whichever place it walks from (the place
    /// row already says which), so it's always clear the times are made up
    func footerNote(_ l: UIText) -> (icon: String, text: String, warning: Bool)? {
        if transit.isDemo { return ("theatermasks", l.t("Demo data only"), false) }
        guard let origin = transit.origin else { return nil }
        switch origin.kind {
        case .manualFallback:
            return ("location.slash", l.f("Location unavailable. Walking from %@", origin.name), true)
        case .current, .manual, .demoCurrent:
            return nil
        }
    }
}
