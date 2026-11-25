import AppKit
import CatchText
import SwiftUI
import TransitCore
import WidgetKit

/// "Timetable" tag: this boat (or train) has no live data; the time comes from the timetable.
struct TimetableTag: View {
    var l: UIText

    var body: some View {
        Label(l.t("Timetable"), systemImage: "calendar")
            .labelStyle(.titleAndIcon)
            .font(.scaled(.caption2).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(OutlineColor(), lineWidth: 1))
            .fixedSize()
            .help(l.t("No live data for this one. The time is from the timetable."))
    }
}

/// Express / local tag. Every transit mode uses the same style: filled capsule, white text, and the same service type is the same color everywhere
///  (so Express and Local look the same in every mode). Local is gray, Express orange (same for subway and bus),
/// Limited magenta, SBS uses MTA's SBS blue. Buses are shown by MTA's categories: Local / Limited / SBS / Express.
struct ServiceTag: View {
    var express: Bool
    var bus: BusService? = nil
    var l: UIText
    /// When the widget strips color, filled tags become white blocks: use outlines throughout then
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var filled: Bool { renderingMode == .fullColor }

    var body: some View {
        if let bus {
            switch bus {
            case .local:
                tag(l.t("Local"), color: .localGray, help: l.t("Local bus: stops at every bus stop."))
            case .limited:
                tag(l.t("Limited"), color: .limitedPurple, help: l.t("Limited-Stop: stops only at major stops."))
            case .selectBus:
                tag(l.t("SBS"), color: BusRouteBadge.color(.selectBus),
                    help: l.t("Select Bus Service: fewer stops. Pay at the machine at the stop before boarding."))
            case .express:
                tag(l.t("Express"), color: .expressOrange, help: l.t("Express bus: few stops, higher fare."))
            }
        } else if express {
            tag(l.t("Express"), color: .expressOrange, help: l.t("Express: skips some stations after this one."))
        } else {
            tag(l.t("Local"), color: .localGray, help: l.t("Local: stops at every station."))
        }
    }

    private func tag(_ title: String, color: Color, help: String) -> some View {
        Text(title)
            .font(.scaled(.caption2).weight(.semibold))
            .foregroundStyle(filled ? Color.white : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(filled ? color : Color.clear))
            .overlay(Capsule().stroke(filled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(OutlineColor()), lineWidth: 1))
            .fixedSize()
            .help(help)
    }
}

/// A row of round line badges, e.g. 7 B D F M. Beyond `limit` items the last one shows "+3".
struct RouteBullets: View {
    var routes: [String]
    var size: CGFloat = 16
    var limit: Int = 8
    /// Onto more lines when they don't fit on one, each badge at its full width (FlowLayout); otherwise one line, where badges
    /// left too little room get narrower than their text
    var wraps = false

    /// A station's row as screen readers say it: its name first, then all its lines (on screen the badges come before the name, and
    /// read in that order a station with five lines was named last)
    static func spoken(name: String, routes: [String], detail: String = "", _ l: UIText) -> String {
        [name, l.commaList(routes.map(FerryFeed.spokenRouteName)), detail].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    var body: some View {
        if wraps {
            FlowLayout(spacing: 2, lineSpacing: 2) { badges }
        } else {
            HStack(spacing: 2) { badges }
        }
    }

    @ViewBuilder private var badges: some View {
        ForEach(routes.prefix(limit), id: \.self) { RouteBadge(route: $0, size: size) }
        // The count of the rest, always whole on one line: where room is short the badges before it get narrower, rather than
        // the count breaking onto a second line or being squeezed out. Kept left to right (LRI…PDI), so right-to-left languages
        // show "+4", not "4+"
        if routes.count > limit {
            Text("\u{2066}+\(routes.count - limit)\u{2069}")
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Views left to right, each at its full (ideal) size, onto a new line when the next one doesn't fit on this one, and centered on
/// its line: route badges that are never squeezed (a badge's text is as wide as it is, and in a squeezed badge it ran out of the
/// badge and over the next one). Each line starts at the left, or with `trailing` ends at the right (a station card's kind boxes
/// under its name). Placed from the left: in a right-to-left layout the system mirrors it, so a trailing line ends at the left there
struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 2
    /// Each line ends at the end of the bounds instead of starting at their start
    var trailing = false
    /// A view wider than the whole width is offered only that width, so its text is shortened with "…" instead of the view
    /// widening whatever it is in (a kind box on the narrowest sidebar with the largest text)
    var fitsWidth = false

    /// Where each view goes, from the top left, in this width (nil: all on one line), and the size of them all. A view wider than
    /// the width gets a line of its own, at its full size, or with fitsWidth as wide as the width. Up to a point over the width still
    /// fits: the width a line was measured at can come back a little smaller, rounded to the screen's pixels. With trailing, each line
    /// ends at the end of the width (of the widest line when there is none); a line wider than that still starts at the left
    static func positions(sizes ideal: [CGSize], width: CGFloat?, spacing: CGFloat, lineSpacing: CGFloat, trailing: Bool = false,
                          fitsWidth: Bool = false) -> (points: [CGPoint], size: CGSize) {
        let sizes = ideal.map { offered($0, width: width, fitsWidth: fitsWidth) }
        var lines: [[Int]] = []
        var x: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            if lines.isEmpty || (x > 0 && width.map { x + size.width > $0 + 1 } == true) {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(i)
            x += size.width + spacing
        }
        var points = Array(repeating: CGPoint.zero, count: sizes.count)
        var lineWidths: [CGFloat] = []
        var y: CGFloat = 0, widest: CGFloat = 0
        for line in lines {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for i in line {
                points[i] = CGPoint(x: x, y: y + (height - sizes[i].height) / 2)
                x += sizes[i].width + spacing
            }
            lineWidths.append(x - spacing)
            widest = max(widest, x - spacing)
            y += height + lineSpacing
        }
        if trailing {
            let end = width ?? widest
            for (line, lineWidth) in zip(lines, lineWidths) {
                for i in line { points[i].x += max(0, end - lineWidth) }
            }
        }
        return (points, CGSize(width: widest, height: lines.isEmpty ? 0 : y - lineSpacing))
    }

    /// The size a view is laid out at: its full size, or with fitsWidth no wider than the width
    static func offered(_ size: CGSize, width: CGFloat?, fitsWidth: Bool) -> CGSize {
        guard fitsWidth, let width else { return size }
        return CGSize(width: min(size.width, width), height: size.height)
    }

    private func idealSizes(_ subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return Self.positions(sizes: idealSizes(subviews), width: width, spacing: spacing, lineSpacing: lineSpacing,
                              trailing: trailing, fitsWidth: fitsWidth).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = idealSizes(subviews)
        let points = Self.positions(sizes: ideal, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing,
                                    trailing: trailing, fitsWidth: fitsWidth).points
        for (i, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + points[i].x, y: bounds.minY + points[i].y),
                       proposal: ProposedViewSize(Self.offered(ideal[i], width: bounds.width, fitsWidth: fitsWidth)))
        }
    }

    /// The text baselines are the top line's (first) and the bottom line's (last), as in a stack: a station card lines the first line
    /// of its name up with its kind boxes (NameAndKindsLayout). Worked out here rather than left to how a layout merges its views'
    /// guides. Other guides keep their default values
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        let first = guide == .firstTextBaseline
        guard first || guide == .lastTextBaseline, !subviews.isEmpty else { return nil }
        let ideal = idealSizes(subviews)
        let points = Self.positions(sizes: ideal, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing,
                                    trailing: trailing, fitsWidth: fitsWidth).points
        let baselines = subviews.indices.map { i -> CGFloat in
            let size = Self.offered(ideal[i], width: bounds.width, fitsWidth: fitsWidth)
            return points[i].y + subviews[i].dimensions(in: ProposedViewSize(size))[guide]
        }
        return (first ? baselines.min() : baselines.max()).map { bounds.minY + $0 }
    }
}
