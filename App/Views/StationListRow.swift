import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// A station card's lines and its walk: on one line when both fit there at their full widths, the walk at the end of it; otherwise
/// the lines take the whole width, onto more lines when they need them (RouteBullets.wraps), and the walk goes on a line of its own
/// under them, still at the end, so the walks of all the cards stay in one column. Decided from the width the card has each time it
/// is laid out: with long route badges ("Purple A", "Yellow B") the system's own choice of the two (ViewThatFits) kept them on one
/// line where they didn't fit, and the badges were squeezed and ran over each other. Placed from the left: in a right-to-left
/// layout the system mirrors it
struct RoutesAndWalkLayout: Layout {
    /// The least room between the last badge and the walk
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 3

    static func oneLine(width: CGFloat, routes: CGFloat, walk: CGFloat, spacing: CGFloat) -> Bool {
        routes + spacing + walk <= width
    }

    /// Where the lines (first view) and the walk (second view) go, from the top left, the size each is offered, and the size of both
    private struct Placement {
        var routes: CGPoint
        var routesSize: CGSize
        var walk: CGPoint
        var walkSize: CGSize
        var size: CGSize
    }

    private func placement(width offered: CGFloat?, subviews: Subviews) -> Placement? {
        guard subviews.count == 2 else { return nil }
        let routes = subviews[0].sizeThatFits(.unspecified), walk = subviews[1].sizeThatFits(.unspecified)
        // Asked for its ideal size (nil or an endless width): both on one line
        let width = offered.flatMap { $0.isFinite ? $0 : nil } ?? routes.width + spacing + walk.width
        if Self.oneLine(width: width, routes: routes.width, walk: walk.width, spacing: spacing) {
            // Both centered on the line, as in a row
            let height = max(routes.height, walk.height)
            return Placement(routes: CGPoint(x: 0, y: (height - routes.height) / 2), routesSize: routes,
                             walk: CGPoint(x: width - walk.width, y: (height - walk.height) / 2), walkSize: walk,
                             size: CGSize(width: width, height: height))
        }
        let lines = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        // Not wider than the line: on the narrowest sidebar with the largest text the walk is shortened with "…"
        let walkWidth = min(walk.width, width)
        return Placement(routes: .zero, routesSize: CGSize(width: width, height: lines.height),
                         walk: CGPoint(x: width - walkWidth, y: lines.height + lineSpacing),
                         walkSize: CGSize(width: walkWidth, height: walk.height),
                         size: CGSize(width: width, height: lines.height + lineSpacing + walk.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placement(width: proposal.width, subviews: subviews)?.size ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let p = placement(width: bounds.width, subviews: subviews) else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX + p.routes.x, y: bounds.minY + p.routes.y), proposal: ProposedViewSize(p.routesSize))
        subviews[1].place(at: CGPoint(x: bounds.minX + p.walk.x, y: bounds.minY + p.walk.y), proposal: ProposedViewSize(p.walkSize))
    }
}

/// A station card's first line: the name, with the kind boxes at the top right beside it (a long name wraps there, two lines at most),
/// so the boxes are in the same place on every card. Only when the boxes would leave the name less than about half the line (a station
/// of several operators, a long operator's name, a narrow sidebar) do they go on a line of their own under the name, still on the right,
/// and onto more lines when they don't fit on one (FlowLayout, each line ending on the right).
/// The choice depends only on the width offered and the two views' sizes, so a station looks the same each time. Placed from the left:
/// in a right-to-left layout the system mirrors it, and the boxes are at the top left
struct NameAndKindsLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 3
    /// The least share of the line the name keeps beside the boxes when it has to wrap there
    static let nameShare: CGFloat = 0.55

    static func beside(width: CGFloat, name: CGFloat, boxes: CGFloat, spacing: CGFloat) -> Bool {
        let rest = width - boxes - spacing
        return name <= rest || (rest > 0 && rest >= width * nameShare)
    }

    /// Where the name (first view) and the boxes (second view) go, from the top left, and the width each is offered
    private struct Placement {
        var name: CGPoint
        var nameWidth: CGFloat
        var boxes: CGPoint
        var boxesWidth: CGFloat
        var size: CGSize
    }

    private func placement(width offered: CGFloat?, subviews: Subviews) -> Placement? {
        guard subviews.count == 2 else { return nil }
        let name = subviews[0], boxes = subviews[1]
        let nameIdeal = name.sizeThatFits(.unspecified)
        let boxesIdeal = boxes.sizeThatFits(.unspecified)
        // Asked for its ideal size (nil or an endless width): both on one line
        let width = offered.flatMap { $0.isFinite ? $0 : nil } ?? nameIdeal.width + spacing + boxesIdeal.width
        if Self.beside(width: width, name: nameIdeal.width, boxes: boxesIdeal.width, spacing: spacing) {
            let rest = max(0, width - boxesIdeal.width - spacing)
            let nameProposal = ProposedViewSize(width: rest, height: nil)
            let nameSize = name.sizeThatFits(nameProposal)
            // The first lines of the two on one baseline, as in a row of text
            let nameBaseline = name.dimensions(in: nameProposal)[VerticalAlignment.firstTextBaseline]
            let boxesBaseline = boxes.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
            let nameY = max(0, boxesBaseline - nameBaseline)
            let boxesY = max(0, nameBaseline - boxesBaseline)
            return Placement(name: CGPoint(x: 0, y: nameY), nameWidth: rest,
                             boxes: CGPoint(x: width - boxesIdeal.width, y: boxesY), boxesWidth: boxesIdeal.width,
                             size: CGSize(width: width, height: max(nameY + nameSize.height, boxesY + boxesIdeal.height)))
        }
        let nameHeight = name.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        // As many lines as the boxes need at this width, never wider than the line: only a box too wide even for a line of its own
        // (the narrowest sidebar with the largest text) has its words shortened with "…"
        let boxesSize = boxes.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let boxesWidth = min(boxesSize.width, width)
        return Placement(name: .zero, nameWidth: width,
                         boxes: CGPoint(x: width - boxesWidth, y: nameHeight + lineSpacing), boxesWidth: boxesWidth,
                         size: CGSize(width: width, height: nameHeight + lineSpacing + boxesSize.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placement(width: proposal.width, subviews: subviews)?.size ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let p = placement(width: bounds.width, subviews: subviews) else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX + p.name.x, y: bounds.minY + p.name.y),
                          proposal: ProposedViewSize(width: p.nameWidth, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + p.boxes.x, y: bounds.minY + p.boxes.y),
                          proposal: ProposedViewSize(width: p.boxesWidth, height: nil))
    }
}

/// A station row of the sidebar list. It is identified by the order of the whole list together with its own station, so when the order or the
/// set of stations changes (for example when walking routes replace the straight-line estimates), no row keeps its identity and the table
/// removes the old rows and inserts the new ones. Identified by the station alone, the rows would be moved, and one table update that moves rows
/// and also inserts or removes some makes AppKit warn about a reentrant row-height update (removing and inserting never did).
/// A `.id` on the rows doesn't do this: the list still matches the rows by their station. The selection follows the station tags, so it stays.
/// The rows need those tags: without a tag of the selection's type, the list falls back to this ID, which isn't a station ID, and no row can be selected.
struct SidebarStationRow: Identifiable {
    /// The order of the whole list and this row's station
    struct Key: Hashable {
        var order: [String]
        var station: String
        /// Whether the row has its line with the first train you can catch: the row's height doesn't follow its content, so
        /// the row is a new one when that line comes or goes (its text changing within the line keeps the row)
        var summary = false
    }

    var id: Key
    var station: BoardStation

    /// One key per station ID, in this order
    static func keys(_ ids: [String], summaries: [Bool]? = nil) -> [Key] {
        ids.enumerated().map { pair in Key(order: ids, station: pair.element, summary: summaries?[pair.offset] ?? false) }
    }

    /// byDirection: the summary line is by direction (subway), see BoardStation.catchSummary
    static func rows(_ stations: [BoardStation], byDirection: Bool = false) -> [SidebarStationRow] {
        let summaries = stations.map { !$0.catchSummary(byDirection: byDirection).isEmpty }
        return zip(keys(stations.map(\.id), summaries: summaries), stations).map { SidebarStationRow(id: $0, station: $1) }
    }
}

/// "Show trains" in the map window asks the station's card in the sidebar for its small bounce (TransitModel.showStationFromMap).
/// The card takes it within a few seconds and clears it; a card that appears later doesn't bounce for it.
struct CardBounce: Equatable {
    var station: String
    var at: Date

    /// Whether this asks the card of `id` now
    func asks(_ id: String, now: Date = Date()) -> Bool {
        station == id && now.timeIntervalSince(at) < 3
    }
}

/// One row on the left: station name, lines, walking time.
struct StationListRow: View {
    @EnvironmentObject var transit: TransitModel
    var station: BoardStation
    var l: UIText
    /// This station is the one shown on the right: its card is the blue one
    var selected = false
    /// Counts the times "Show trains" in the map window asked this card to light up briefly
    @State private var bounces = 0
    /// When the last one started: one click in the map window lights the card once, not twice
    @State private var bouncedAt = Date.distantPast

    var body: some View {
        // Lines a little closer together than before the cards: the card holds them together now, and each row stays about as
        // tall as before (more stations in sight in a small window)
        VStack(alignment: .leading, spacing: 3) {
            let kinds = self.kinds
            // The kind boxes at the top right beside the name on every card (a long name wraps beside them), so they're in the same
            // place on each; under the name, still on the right, only when they'd leave the name too little of the line
            NameAndKindsLayout {
                nameText
                kindBoxes(kinds)
            }
            // A station without times has no routes: its operator's box above says what it is
            if station.noTimes == nil {
                // The lines and the walk on one line when both fit, the walk at the end, under the kind boxes: a card is a line
                // shorter then, and more stations are in sight. When they don't fit (a station with many lines or long badges, a
                // narrow sidebar, large text), the walk goes under the lines, still at the end: the walks of all the cards stay in
                // one column (RoutesAndWalkLayout)
                RoutesAndWalkLayout {
                    RouteBullets(routes: station.routes, size: 16, limit: 8, wraps: true)
                    walkLine
                }
            } else {
                walkLine
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if station.walk.isAcrossWater {
                AcrossWaterNote(l: l)
                    .font(.scaled(.caption))
            }
            let summary = station.catchSummary(byDirection: transit.system.mode == .subway)
            if !summary.isEmpty {
                CatchSummaryLine(items: summary, l: l, selected: selected)
            }
        }
        // One card per station, so a station's lines read as one group (they ran together without them). The selected card
        // is blue with white text, drawn here: the list's own highlight is off (SidebarScrollClamp), so it can't sit around the
        // card a little bigger or smaller, and it stays blue whether or not the list has the keyboard focus
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
        .modifier(SidebarCard(selected: selected))
        // Getting selected switches the row's colors at once, the card's too, without the selection animation: the tag
        // outlines blended over it showed as solid white partway (see OutlineColor)
        .transaction { $0.animation = nil }
        // Screen readers read the whole row as one sentence. It also spares accessibility from querying each small subview in the row:
        // the "AttributeGraph cycle" warnings at launch all came from accessibility queries on sidebar list rows
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(rowLabel))
        // A button that shows the station (without it, screen readers didn't say what the row is). The one shown is the list's
        // selected row, and the list says "selected" itself: marked selected here too, VoiceOver said it twice
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { withAnimation(Motion.ease(0.25)) { transit.selectStation(station.id) } }
        // Clicked in the list or chosen with the arrow keys, the card just turns blue, as in the system's own sidebars: the page
        // on the right fading in says it worked (a card of four lines shrinking looked odd, and going down the list with the arrow
        // keys every card moved). "Show trains" in the map window, where your eyes aren't on the list, lights the card up briefly
        // and back, without changing its size: also when this card was selected already or the main window has only just opened
        // (a new row). Never with "Reduce motion"
        .onChange(of: transit.cardBounce) { _, _ in bounceIfAsked() }
        .onAppear { bounceIfAsked() }
        .phaseAnimator(Motion.cardBounce(down: true) == nil ? [false] : [false, true], trigger: bounces) { row, lit in
            row.overlay {
                RoundedRectangle(cornerRadius: SidebarCard.cornerRadius)
                    .fill(Color.white.opacity(lit ? 0.35 : 0))
                    .allowsHitTesting(false)
            }
        } animation: { lit in
            Motion.cardBounce(down: lit)
        }
        // The gap between cards
        .padding(.vertical, 2)
    }

    private var nameText: some View {
        Text(station.name)
            .font(.scaled(.body).weight(.semibold))
            .lineLimit(2)
    }

    /// The walk to the station, after the range's icon, with the tags that go with it (extended range, no times)
    private var walkLine: some View {
        HStack(spacing: 6) {
            // Matches the legend above the station list: ◎ main range, ◌ extended range
            Image(systemName: station.range == .extended ? "circle.dashed" : "circle.circle")
                .help(station.range == .extended ? l.t("Extended range") : l.f("Primary: %@ walk", l.minutes(transit.effectiveSettings.primaryWalkSeconds)))
            // The walk is what the choice rests on: body color, not gray like the rest
            Text(l.f("%@ walk", l.minutes(station.walk.walkSeconds)))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if station.range == .extended {
                ExtendedRangeTag(l: l, selected: selected)
            }
            if station.noTimes != nil {
                NoTimesTag(l: l, selected: selected)
            }
        }
        .font(.scaled(.caption))
        .foregroundStyle(.secondary)
    }

    /// Small boxes saying what kind of station this is (Subway, Tram, PATH, LIRR...). When they don't fit on one line under the name,
    /// they go onto more, each box at its text's width and each line ending at the trailing side, like the route badges, rather than
    /// being cut short ("NJ Tran…"). Only a box too wide even for a line of its own (the narrowest sidebar with the largest text) has
    /// its text shortened with "…", rather than widening the sidebar
    private func kindBoxes(_ kinds: [String]) -> some View {
        FlowLayout(spacing: 3, lineSpacing: 3, trailing: true, fitsWidth: true) {
            ForEach(kinds, id: \.self) { kind in
                KindBox(text: kind)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// What the boxes say: the kinds of its lines, or for a station without times its operator ("AirTrain JFK")
    private var kinds: [String] {
        station.noTimes.map { [$0.agency.shortName] } ?? l.stationKinds(station.routes, system: transit.system)
    }

    private func bounce() {
        let now = Date()
        guard now.timeIntervalSince(bouncedAt) > 0.5 else { return }
        bouncedAt = now
        bounces += 1
    }

    /// The map window asked this card for its bounce a moment ago: give it, once
    private func bounceIfAsked() {
        guard let ask = transit.cardBounce, ask.asks(station.id) else { return }
        transit.cardBounce = nil
        bounce()
    }

    private var rowLabel: String {
        [station.name,
         l.commaList(kinds),
         l.commaList(station.routes.map(FerryFeed.spokenRouteName)),
         l.f("%@ walk", l.minutes(station.walk.walkSeconds)),
         station.range == .extended ? l.t("Extended range") : "",
         station.noTimes != nil ? l.t("No times") : "",
         station.walk.isAcrossWater ? l.note(.acrossWater) : "",
         CatchSummaryLine.spoken(station.catchSummary(byDirection: transit.system.mode == .subway), in: station, l: l)]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// Whole sentences in the sidebar's rows. The sidebar keeps a row's text to one line unless the text has a line limit of its own,
/// so a sentence without one is cut off after a few words, whatever else is done to let it wrap
enum SidebarText {
    /// Enough lines for any of the sidebar's sentences in the longest translation, at the narrowest sidebar and the largest text
    static let sentenceLines = 12
}

/// Under the walk of a station whose straight line crosses a river or a bay and has no route yet (WalkEstimate.isAcrossWater):
/// the real walk may be much longer, which is also why its verdicts are "Not sure" at best. Sidebar, station page and Plan a Trip
struct AcrossWaterNote: View {
    var l: UIText

    var body: some View {
        Label(l.note(.acrossWater), systemImage: "water.waves")
            .foregroundStyle(.secondary)
            // Its own line limit: the sidebar's rows keep text to one line unless told otherwise, and cut off there the sentence
            // lost its point ("may be much longer")
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A station's card in the sidebar (StationListRow; the standby row is a blue one too): a little lighter than the sidebar with a
/// thin line around it, so it doesn't run together with the buttons above, which are a little darker; the selected one is blue.
/// With "Increase contrast" every card gets a clear border
struct SidebarCard: ViewModifier {
    static let cornerRadius: CGFloat = 8
    var selected: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.stationCard)))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color.stationSeparator, lineWidth: 1)
                }
            }
            .contrastBorder(cornerRadius: Self.cornerRadius)
    }
}
