import AppKit
import CatchText
import MapKit
import SwiftUI
import TransitCore

/// The line under a station in the sidebar: each direction's first train you can catch (subway, with ↑ ↓), or the earliest one of
/// both (bus, train, ferry): its route, the minutes until it comes, and its verdict's icon in its color (Can try or Tight). A direction
/// with trains but none to catch shows "—". When the whole line doesn't fit, only the minutes and the icon stay. Updates with the board.
struct CatchSummaryLine: View {
    var items: [CatchSummaryItem]
    var l: UIText
    /// The row is selected (white text on the accent color): the verdict icons keep their color there, with a white edge
    var selected = false

    var body: some View {
        // No clock of its own: the minutes come from the sidebar's board, which is worked out on the same ticks as the station page
        // (BoardClock), so the two always show the same minutes
        ViewThatFits(in: .horizontal) {
            line(full: true)
            line(full: false)
        }
        .font(.scaled(.caption))
        .accessibilityHidden(true)
    }

    private func line(full: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 3) {
                    if let code = item.direction {
                        Image(systemName: code == "S" ? "arrow.down" : "arrow.up")
                            .font(.scaled(.caption2).weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    if let train = item.train {
                        if full { RouteBadge(route: train.route, size: 13) }
                        Text(Self.minutes(train, l: l))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if selected {
                            EdgedVerdictIcon(symbol: train.verdict.symbol, color: train.verdict.color)
                        } else {
                            Image(systemName: train.verdict.symbol)
                                .foregroundStyle(train.verdict.color)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    /// Minutes until it comes, like the rest of the sidebar ("4 min"); "0 min" when it's arriving. Counted from when the board was
    /// worked out and rounded down, exactly like the station page's "in 3 min" (UIText.countdown)
    static func minutes(_ train: BoardTrain, l: UIText) -> String {
        guard let s = train.evaluation.secondsUntilTrain else { return "—" }
        return l.minutes(max(0, (s / 60).rounded(.down)) * 60)
    }

    /// For screen readers, read with the rest of the row: "1, in 4 min, Can try". By direction (subway), each item starts with its
    /// train's direction as the station page names it ("Uptown, 1, in 4 min, Can try; Downtown, 2, in 6 min, Tight"): the arrows
    /// that tell the two apart on screen are icons, hidden from screen readers. A direction with trains but none to catch ("—" on
    /// screen) reads its first train with its verdict ("Downtown, 2, in 1 min, Too soon") rather than nothing
    static func spoken(_ items: [CatchSummaryItem], in station: BoardStation, l: UIText) -> String {
        items.compactMap { item -> String? in
            guard let train = item.train ?? item.direction.flatMap({ station.direction($0).trains.first }) else { return nil }
            let time = train.evaluation.secondsUntilTrain.map { l.countdown($0) } ?? ""
            let way = item.direction == nil ? "" : l.direction(train.direction)
            return [way, FerryFeed.spokenRouteName(train.route), time, l.verdict(train.verdict)]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "; ")
    }
}

/// A verdict's icon on the selected card. It keeps its color, which is what tells "Can try" from "Tight" at a glance, and
/// gets a white edge: its colors on the accent color alone are about 1.2:1, and the accent color can be the icon's own (an orange
/// accent). The edge is the icon's shape in white, drawn eight times a point off in every direction under the icon, so it is as
/// wide all around whatever the shape; the mark inside the icon (check, exclamation mark) is white
struct EdgedVerdictIcon: View {
    var symbol: String
    var color: Color

    private static let offsets: [CGSize] = [
        CGSize(width: -1, height: -1), CGSize(width: 0, height: -1), CGSize(width: 1, height: -1),
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: -1, height: 1), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
    ]

    var body: some View {
        ZStack {
            ForEach(Self.offsets.indices, id: \.self) { i in
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white)
                    .offset(Self.offsets[i])
            }
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, color)
        }
        // The edge is drawn a point outside the icon: this much room keeps it clear of the minutes before it
        .padding(.horizontal, 1)
    }
}

/// A small box saying what kind of station this is ("Subway", "Tram", "LIRR"; for a station without times, its operator).
/// The station list, the station page, the map's card and the trip planner draw it alike
struct KindBox: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.scaled(.caption2).weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(OutlineColor(), lineWidth: 1))
    }
}

/// The gray tag on a station whose operator publishes no times the app can use (NoTimesStations), after its walking time.
/// On the selected (blue) card its text is the card's own white: gray of gray there was too faint to read
struct NoTimesTag: View {
    var l: UIText
    var selected = false

    var body: some View {
        Text(l.t("No times"))
            .font(.scaled(.caption2).weight(.medium))
            .foregroundStyle(selected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            // Like the extended range tag: shortened rather than widening the sidebar
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(Capsule().stroke(OutlineColor(), lineWidth: 1))
            .help(l.t("Catch My Train has no departure times for this station."))
    }
}

/// "Extended range" small tag (shared by the sidebar station list and Plan a Trip): informational only, not clickable,
/// so like the "Subway" and other tags in the top right it has a gray outline, not blue (blue is only for clickable things).
/// On the selected (blue) card of the station list its text is the card's own white, as NoTimesTag's
struct ExtendedRangeTag: View {
    var l: UIText
    var selected = false

    var body: some View {
        Label(l.t("Extended range"), systemImage: "circle.dashed")
            .labelStyle(.titleOnly)
            .font(.scaled(.caption2).weight(.medium))
            .foregroundStyle(selected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            // No fixedSize: truncate when the translation is long and the sidebar narrow, rather than widening the sidebar.
            // No further shrinking: caption2 is already 10 pt, and shrinking would go below 10 pt
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay(Capsule().stroke(OutlineColor(), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .help(l.t("This station is in the extended range: a longer walk than your primary range."))
    }
}
